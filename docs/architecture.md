# Architecture

ZigAI has four layers, and each one has one job.

## Model contract

`Model` is a small vtable: context, capabilities, and one request function. It
accepts provider-neutral messages and returns text or tool calls. A new
provider does not need to modify the agent.

`ModelProfile` is resolved before the agent runs. It describes model behavior
independently from the transport: tools, parallel calls, system messages,
structured JSON, thinking, and provider-managed tools. The agent rejects
unsupported requested features before sending a paid request.

Every model response keeps a normalized finish category and the provider's raw
reason. Successful agent results expose the final reason. Truncation, content
filtering, and incomplete tool calls fail with distinct agent errors before the
generic empty-response check, so an empty successful response remains a
separate condition.

`ModelSettings` carries temperature, maximum output tokens, stop sequences,
seed, and reasoning effort without exposing provider field names. Settings
merge in model, agent, then run order. `ModelProfile` declares support,
including the exact reasoning-effort levels, so an unsupported override fails
before a request. Each adapter translates the resolved settings once at its
wire boundary.

Model composition also stays behind the same contract. `models.Fallback` tries
an ordered candidate list for transient failures and exposes the intersection
of their profiles. It never falls back after a stream event has been delivered.
`models.Selector` asks application code for a concrete model on each request;
the application declares the common profile its routing policy guarantees.
Neither adapter adds a branch to the agent loop.

Capabilities are ordered feature bundles. The agent starts with its direct
tools, provider-managed tools, and instructions, then appends each capability's
contributions from left to right. Capabilities can contribute toolsets as well.
Capability settings override earlier capabilities; direct agent and run
settings remain higher precedence. Model selectors receive the model chosen so
far, and capability lifecycle hooks run in the same stable order.

Toolsets group static tools or prepare them again before each model step. A
preparer can inspect messages, usage, request count, and typed dependencies,
then enable or disable individual tools. Namespaces become provider-safe
`namespace__tool` names. Metadata merges from tool to toolset to prepared entry
and remains application-only. Duplicate prepared names are rejected before the
provider request.

Lifecycle hooks form one synchronous ordered stream. Direct agent hooks run
first, followed by capability hooks. Each provider request, tool dispatch,
tool execution, output check, and delivered stream event has explicit
start/end or before/after events plus an error event where failure is possible.
Hook payloads are borrowed. Hook failures stop the run; terminal failures emit
`run_error` before returning.

OpenTelemetry instrumentation is attached as an isolated lifecycle observer
for each run. It emits one trace with agent, model-request, and tool-call spans,
plus counters and histograms for calls, retries, latency, token usage, and
application-estimated cost. GenAI names and attributes follow the OpenTelemetry
semantic conventions. Export callbacks are synchronous and borrowed; they can
bridge to an SDK or OTLP pipeline. Prompt content is omitted unless explicitly
enabled, and exporter failures are fail-open by default.

Structured output is provider neutral at the agent boundary. JSON-object mode
and named, strict JSON Schema mode are encoded as `text.format` for OpenAI and
`output_config.format` for Anthropic, and `generationConfig` for Google. A
profile mismatch fails before network I/O.

`Agent.runTyped` derives that schema from a Zig output type and decodes the
final JSON into the same type. Its typed value, original JSON, and message
history share one result arena and one `deinit` ownership boundary. Buffered
and streaming typed runs use the same path. Invalid output is appended to
history with a correction request, bounded by `max_output_retries`.
Applications using `run` directly can still opt into provider-independent
local schema validation and receive the same correction behavior. Streaming
deltas remain provisional, and the agent emits `final_output` only after
validation succeeds.

Rich message content is provider neutral too. `UserContent` distinguishes
text, image, audio, document, and arbitrary binary prompt content.
`ResponsePart` adds thinking and tool calls for model output. Media uses one
source union for bytes, URLs, or provider file references, with a MIME type and
optional filename. `RunOptions.prompt_parts` places rich content before the
current text prompt. Message and content metadata are application-owned and
survive copying and versioned history serialization without crossing the
provider boundary.

Profiles advertise supported content kinds. Request and response part unions
make invalid content roles unrepresentable. The agent validates optional
provider guards on file references before network I/O.
Adapters base64-encode bytes only at their wire boundary. Anthropic and Google
decode and retain thinking state; Gemini output media keeps its opaque thought
signature on the neutral content part so the next request can return it
unchanged.

Provider failures keep two layers separate. Stable error categories drive agent
retry policy, while an optional synchronous observer receives the provider
name, HTTP status, parsed code/message, and raw body. The view is borrowed;
applications copy only the detail they need to retain.

## Agent loop

`Agent.run` owns the conversation in an arena:

1. Resolve static, dynamic, and run-specific instructions.
2. Copy message history, then add the current user message.
3. Prepare the tools available for this model step.
4. Request a model response.
5. Return its text if there are no tool calls.
6. Otherwise execute every requested tool and append the results in call order.
7. Repeat until the model answers or the configured request limit is reached.

Instructions belong to the current run. Static instructions are resolved
before dynamic ones, and run-specific instructions come last. Empty values are
ignored. Providers receive the resolved list on every request in the tool
loop. The rendered instruction string is retained on the initial request for
provenance; a later run resolves its own instruction configuration.

History uses a `Message` tagged union with distinct `RequestMessage` and
`ResponseMessage` envelopes. Requests contain only system prompts, user
prompts, retries, and tool returns. Responses contain only text, media,
thinking, and tool calls. Response history retains usage, finish reason,
provider/model identity, response IDs, and raw provider details.

Version 2 serializes those envelopes with `kind` and `part_kind`
discriminators. The parser migrates version-1 role-based ZigAI histories.
Before each request, agent, capability, and run-specific processors transform
a borrowed provider-facing view from left to right. Built-ins trim old
messages, compact adjacent text, summarize an older prefix through an
application callback, and remove malformed or orphaned tool traffic. The
canonical arena-owned conversation is never truncated.

An agent may carry an opaque per-run dependency pointer. Contextual tools use
`ToolRunContext.dependency(T)` to recover their application type and can also
inspect cumulative token usage and model-request count. Existing simple tool
callbacks remain context-free. Invalid arguments and recoverable tool failures
become error tool results so the model can repair its call. Retry counts are
kept separately for each tool, with a per-tool override, and do not consume the
structured-output retry budget. Allocation and cancellation failures remain
fatal; custom tools can override failure classification.

Reflected tools derive both their argument schema and their return schema. The
return schema stays application-visible on `ToolDefinition`; provider function
definitions still receive only the argument schema. A reflected function can
return `ToolReturn(T)` to pair its typed value with follow-up user messages.
Manual tools use `ToolOutput` for the same behavior.

The agent always appends the provider-protocol tool-return request first. It
then copies follow-up requests in original tool-call order, including after a
resumed approval. Their type permits only request parts, and the agent further
requires every part to be a user prompt. Rich-content capability and
provider-file checks are the same as for normal input.

When a model requests multiple tools, the agent uses its `Io` runtime to run
them through a bounded scheduler. Agent-wide and per-tool policies limit active
and queued calls; excess work becomes a retryable tool result without executing
the callback. Each accepted call races cooperative execution against its
optional timeout and the run cancellation token, and every losing task is
cancelled and drained before the agent continues. Allocations into the result
arena are synchronized, result parts remain in model call order, and a fatal
failure cancels outstanding work. Result and follow-up sizes are checked before
they enter history or provider encoding. `limits.max_tool_calls` separately
caps the total across every step of a run.

Cancellation is checked at loop boundaries and propagated through the model
request so the standard HTTP transport can interrupt in-flight buffered and
streaming work. Per-request deadlines use the same runtime contract. Retry
decisions include timeouts. Optional exponential backoff uses the
application's `Io`, honors numeric `Retry-After`, and remains interruptible; a
fallible before-retry hook observes each planned delay and provider metadata.

The HTTP transport parses allocation-free response metadata for numeric
`Retry-After` and provider remaining-request/token headers. Provider error
observers and retry hooks receive those values without exposing transport
header storage or changing stable error categories.

The same transport bounds untrusted response allocation after content
decompression. Buffered bodies use `Limits.max_response_body_bytes`; streamed
responses allocate and release one line at a time under
`Limits.max_stream_line_bytes`. Exact-limit payloads remain valid, while the
first excess byte maps to a stable transport error before provider decoding.

Every JSON decoder then uses the shared bounded parsing API. Its preflight pass
scans syntax, decoded value length, nesting depth, and per-collection item
counts while retaining no value graph. Only a successful document reaches the
typed or dynamic parser, and both passes map invalid input to the subsystem's
stable error while preserving allocation failure. Named profiles keep history,
deferred state, provider, tool, MCP, schema, and CLI boundaries consistent
without making a leaf parser depend on an agent or provider.

## MCP toolsets

`mcp.Client` implements the stateless MCP `2026-07-28` envelope. Every request
carries the protocol version, client identity, and capabilities. Typed helpers
cover every core client method, while the generic JSON request path preserves
extension methods and unknown fields. The toolset adapter follows list cursors,
preserves schemas, mirrors `x-mcp-header` arguments, and renders tool content
through the normal agent loop.

Multi round-trip requests replace server-initiated JSON-RPC calls. When a
result requires sampling, roots, or elicitation, the configured `InputHandler`
answers each item and the client retries with `inputResponses` and opaque
`requestState`. `subscriptions/listen` forwards request-scoped SSE or stdio
notifications to an `EventSink` until the final response closes the stream.

`StreamableHttpTransport` emits the required protocol, method, name, and tool
parameter headers. It accepts direct JSON and request-scoped SSE responses.
`StdioTransport` frames one JSON-RPC message per line and correlates response
IDs. Authentication is supplied as custom HTTP headers and is outside the MCP
message layer.

`mcp.Server` is a transport-neutral dispatcher. It provides discovery,
per-request version checks, standard and tool-parameter header validation,
server identity metadata, core or extension method dispatch, JSON-RPC errors,
and a stdio serving loop. An HTTP application passes its request headers to
the same dispatcher.

## Deferred tool execution

A tool chooses `immediate`, `requires_approval`, or `external` execution.
The regular `run` API refuses to discard a required pause.
`runUntilPause` instead returns a tagged outcome before any call in that
model response executes.

The pause owns a versioned JSON state document containing canonical history,
resolved instructions, usage and request counters, output and tool retry
counters, and the calls awaiting decisions. This is application data: it can
cross a process boundary or remain in a queue indefinitely.

`resumeRun` rebuilds the provider-neutral state, prepares the current tools,
and requires exactly one decision for every deferred call. Approval executes
an approval-gated tool; denial becomes an error tool result; an external result
is appended without invoking application code. Immediate calls from the same
model response execute during resume. The next model request sees one complete
tool-result message and the original request is never replayed.

Resume decisions have their own versioned JSON wrapper for integrations that
do not share Zig memory. Dependencies and dynamic toolsets are supplied again
at resume time, while resolved instructions come from the saved state so their
meaning cannot change mid-run.
Applications should integrity-protect persisted state before accepting it back
from an untrusted boundary.

There is intentionally no graph. Applications can build orchestration on top
of this loop without paying for an abstraction when they do not need one.

`Agent.runStream` uses that exact loop rather than a parallel orchestration
implementation. It forwards borrowed model deltas, completed calls, usage,
tool results, and final output synchronously. Once visible stream output has
been emitted, a failed request is never retried, preventing duplicated text or
tool events.

## Evaluations

`evals.Dataset` runs ordinary `Agent` instances over named cases and produces
one arena-owned report. Evaluators receive a borrowed case, output, and usage
view. The built-in exact-match, contains, and valid-JSON checks are
deterministic; applications can provide the same small callback interface.

`evals.ModelGrader` is optional and is itself built from an `Agent`. It sends a
JSON-quoted task, output, expected value, and rubric to that agent, requests a
typed pass/score/reason object, and rejects non-finite or out-of-range scores.
No evaluation-specific provider path exists.

## Provider adapters

First-party adapters live under `src/providers/` and are exported through
`zigai.providers`. A provider owns authentication, endpoint selection, and
wire encoding. Its client exposes the provider-neutral `Model`; the agent does
not depend on any concrete provider.

`zopenai` maps the neutral contract to the OpenAI Responses API.
`zanthropic` maps it to the Anthropic Messages API. `zgoogle` maps it to the
Gemini GenerateContent API. All three accept the same `Transport`, so their
encoding and parsing can be tested without a socket.

The Google boundary recursively removes tool-schema keywords unsupported by
Gemini. Tool-call thought signatures remain provider-neutral metadata on the
call, are serialized with history, and are sent back unchanged so stateless
thinking-model tool loops retain their reasoning state.

`zopenai_compatible` maps the same contract to Chat Completions. Its explicit
base URL, provider label, conservative profile presets, and stream-usage toggle
cover gateways and local servers without assuming every compatible model has
the same capabilities.

The default `HttpTransport` uses only Zig's standard library.

Provider-managed tools remain a small neutral enum at the agent boundary.
OpenAI maps web search to a Responses API tool. Anthropic maps search and fetch
to its versioned server tools. Google maps them to Google Search and URL
Context. Model profiles advertise the exact supported set, so unsupported and
duplicate requests fail before transport. The provider executes these tools
inside its own request; they do not enter ZigAI's local tool dispatch loop.

## Cassettes

Cassette tooling is test support, not library code. It lives under
`tests/support/`, while recordings live under `tests/cassettes/`. The production
module graph and command-line clients do not depend on it.

`ReplayTransport` implements the normal transport interface. It loads
Cassetter-compatible YAML, matches requests in order, and returns recorded
responses. JSON bodies remain structured YAML; streamed text uses literal
blocks. Authentication headers are deliberately outside the cassette schema.

The test-only `RecordingTransport` captures successful request and response
bodies. Optional filters run only on recorded copies; the JSON field filter
recursively omits configured volatile keys.

Strict body matching is a feature. A provider wire-format change should be an
intentional cassette update, not an invisible test success.
