# Architecture

ZigAI has four layers, and each one has one job.

## Message contract

`messages` contains the durable, provider-neutral conversation model. A
`Message` is either a `RequestMessage` or `ResponseMessage`, and each side has
its own part union so invalid role/part combinations are unrepresentable.

Messages do not know about HTTP, model settings, tools available for the next
call, or any provider wire schema. `history` serializes and processes them;
provider adapters translate them at the model boundary. `model` re-exports the
message types as compatibility aliases, but new code can use
`zigai.messages.Message` when the distinction matters.

External persistence formats stay outside this contract. The
`codecs.pydantic_ai` module validates and round-trips the PydanticAI `2.31.0`
stable-v2 JSON schema as an owned `std.json.Value` graph. It deliberately does
not coerce arbitrary JSON metadata, provider details, rich tool content, or
extended usage into narrower ZigAI runtime fields. `history` remains ZigAI's
separately versioned persistence envelope.

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

`ModelSettings` carries portable sampling, penalty, log-probability, tool,
thinking, service-tier, truncation, token, seed, stop, and request-header
controls without exposing provider field names. Settings merge in model,
agent, then run order; non-null slices remain borrowed. `ModelProfile` declares
support, including exact reasoning-effort and service-tier sets, so an
unsupported override fails before a request. Each adapter translates the
resolved settings once at its wire boundary.

Provider-only body fields use the `ProviderExtraBody` tagged union. Adapters
accept only their own tag, parse the value as a bounded JSON object, and reject
keys owned by the portable encoder. Request-scoped headers reject credentials,
HTTP framing, correlation, and adapter-version fields. This keeps the escape
hatch explicit without allowing it to mutate ZigAI's protocol invariants.

Model composition also stays behind the same contract. `models.Fallback` tries
an ordered candidate list for transient failures and exposes the intersection
of their profiles. It never falls back after a stream event has been delivered.
`models.Selector` asks application code for a concrete model on each request;
the application declares the common profile its routing policy guarantees.
Neither adapter adds a branch to the agent loop.

Capabilities are ordered feature bundles. Composition uses fixed inherited,
agent, run, nested, and subagent tiers, then declaration order within a tier.
The input order of explicit layers cannot change tier precedence. Direct agent
configuration remains the base; active capability settings override earlier
capability settings, while direct agent and run settings retain higher
precedence. Model selectors receive the model chosen so far.

Eager bundles activate during run setup. On-demand bundles contribute only
catalog metadata and the framework-owned `load_capability` tool. A load plan is
dependency-first and checked against all active and earlier planned conflicts.
Instruction resolution completes before pending state is mutated, and pending
loads commit only after execution of the complete tool batch. The next loop
generation reassembles tools, provider-managed tools, toolsets, policies,
processors, validators, settings, model selection, and callback snapshots as
one unit.

Canonical successful load traffic reconstructs `.history` capabilities on a
later invocation. `.run_end` loads are reconstructed only while resuming the
same serialized paused run. Typed load parts translate to ordinary provider
function calls at adapter boundaries, keeping the durable message vocabulary
provider-neutral.

Toolsets group static tools or prepare them again before each model step. A
preparer can inspect messages, usage, request count, and typed dependencies,
then enable or disable individual tools. Namespaces become provider-safe
`namespace__tool` names. Metadata merges from tool to toolset to prepared entry
and remains application-only. Duplicate prepared names are rejected before the
provider request.

Lifecycle hooks form one synchronous ordered stream. Direct agent hooks run
first, followed by hooks from currently active capabilities. Each provider request, tool dispatch,
tool execution, output check, and delivered stream event has explicit
start/end or before/after events plus an error event where failure is possible.
Hook payloads are borrowed. Hook failures stop the run; terminal failures emit
`run_error` before returning.

OpenTelemetry instrumentation is attached as an isolated lifecycle observer
for each run. It emits one trace with agent, model-request, and tool-call spans,
plus counters and histograms for calls, retries, latency, cached/reasoning/audio
token usage, and provider-reported or application-estimated cost. GenAI names and attributes follow the OpenTelemetry
semantic conventions. Export callbacks are synchronous and borrowed; they can
bridge to an SDK or OTLP pipeline. Prompt content is omitted unless explicitly
enabled, and exporter failures are fail-open by default.

Provider adapters produce `RequestUsage`; the agent aggregates it into
`RunUsage` and records attempts, tool calls, provider time, and run time.
Provider totals are normalized so cached and audio input are included in input,
and reasoning and audio output are included in output. Unknown integer counters
retain their provider names. Optional pricing uses immutable tables, exact
nano-USD arithmetic, and explicit snapshot versions; missing rates stay unknown.

Structured output has two layers. `OutputSpec` owns agent behavior: text,
JSON-object, native schema, native schema unions, or prompted schema output.
The run prepares that contract into the smaller provider-facing
`OutputFormat`: text, JSON-object, or one JSON Schema. Provider adapters only
encode that wire contract as `text.format` for OpenAI,
`output_config.format` for Anthropic, or `generationConfig` for Google.

Native unions become one `anyOf` schema. Prompted output appends an instruction
and uses provider JSON-object mode when available, otherwise text mode; the
agent always validates the returned JSON locally. Capability mismatches and
malformed output specifications fail before network I/O. Borrowed schemas and
templates are prepared into the run arena.

Tool output prepares one synthetic definition per choice but does not turn
those choices into ordinary application tools. The agent intercepts their
calls, validates and unwraps arguments, invokes an optional output function,
and records protocol-closing results. This separate path lets end strategy
control ordinary side effects without teaching providers about agent
finalization. Output functions return either an accepted value or an explicit
model-safe retry; thrown errors remain application failures.

`Agent.runTyped` derives that schema from a Zig output type and decodes the
final JSON into the same type. Its typed value, original JSON, and message
history share one result arena and one `deinit` ownership boundary. Buffered
and streaming typed runs use the same path. Invalid output is appended to
history with a correction request, bounded by `max_output_retries`.
Applications using `run` directly can still opt into provider-independent
local schema validation and receive the same correction behavior. Streaming
parts use stable indexes and explicit start/delta/end events. Deltas remain
provisional. The agent separately accumulates output-bearing text or tool
arguments, repairs incomplete JSON into bounded snapshots, applies only
monotonic schema assertions, and runs partial-aware output callbacks before
emitting `partial_output`. Raw model events remain available and are always
delivered first. The agent emits one `final_result` only after full validation
succeeds; structured output events include parsed JSON snapshots.

Rich message content is provider neutral too. `UserContent` covers text,
tagged text, images, audio, video, documents, arbitrary binary data, uploaded
files, and cache points. Response parts add thinking, compaction, generated
files, speech, function tools, provider-native tools, tool search, and
capability loading.

Media uses one source union for bytes, URLs, legacy provider files, or an
owner-qualified `UploadedFile`. Provider-generated parts keep IDs and opaque
structured replay details in `ProviderPart`. `ProviderDetails` carries a JSON
object graph, preserves unknown fields, and cannot contain malformed JSON; its
lifetime follows the enclosing owned message result.
Application metadata remains separate and is never sent to a model. Both kinds
survive copying and versioned ZigAI history serialization.

Profiles advertise supported content kinds. Request and response part unions
make invalid content roles unrepresentable. The agent validates URLs and all
provider-owned parts before network I/O.
Adapters base64-encode bytes only at their wire boundary. Anthropic and Google
decode and retain thinking state; Gemini output media keeps its opaque thought
signature on the neutral content part so the next request can return it
unchanged.

Provider failures keep two layers separate. Stable error categories drive agent
retry policy, while an optional synchronous observer receives the provider
name, HTTP status, parsed code/message, and raw body. The view is borrowed;
applications copy only the detail they need to retain. Raw bodies are bounded
and opt-in; configured provider credentials are always suppressed.

## Security boundary

One allocation-free `UrlPolicy` is enforced at the agent, provider, MCP, and
standard transport layers. This deliberate overlap keeps a custom transport or
direct model call from silently bypassing policy. Provider-managed file guards
are checked before requests, and HTTP redirects are never followed.

Transport callbacks are trusted application code and receive raw headers so
they can send requests. Observer and telemetry surfaces do not receive those
headers. Conventional secret names are recognized even without an explicit
sensitive flag, and diagnostic consumers use the redacted header view.

The full trust model is documented in [Security](security.md).

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
provider/model identity, response IDs, and structured provider details.

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

Tool behavior that spans executors lives in the separate `tool` policy module.
Its stable stages are preparation, arguments, approval, call, and return.
Policies compose in registration order: direct agent policies first, then each
capability's policies. Preparation runs after toolsets and controls the exact
definition visible to the provider and available for execution during that
model step. Policy-owned slices use the run arena.

Reflected tools derive both their argument schema and their return schema. The
return schema stays application-visible by default. A tool may opt into
`model_description` visibility, which appends it to the description rather
than inventing a non-portable provider field. A reflected function can return
`ToolReturn(T)` to pair its typed value with follow-up user messages. Manual
tools use `ToolOutput` for the same behavior.

The agent always appends the provider-protocol tool-return request first. It
then copies follow-up requests in original tool-call order, including after a
resumed approval. Their type permits only request parts, and the agent further
requires every part to be a user prompt. Rich-content capability and
provider-file checks are the same as for normal input.

When a model requests multiple tools, the agent uses its `Io` runtime to run
them through a bounded scheduler. Agent-wide and per-tool policies limit active
and queued calls; excess work becomes a retryable tool result without executing
the callback. A sequential tool waits for all active work and blocks later
calls until it finishes. Each accepted call races cooperative execution against its
optional timeout, the absolute run deadline, and the run cancellation token.
Every losing task is cancelled and drained before the agent continues.
Allocations into the result arena are synchronized, result parts remain in
model call order, and a fatal failure cancels outstanding work. Result and
follow-up sizes are checked before they enter history or provider encoding.
`limits.max_tool_calls` separately caps the total across every step of a run.

`RunControl` is created once per invocation from the agent and run options. It
owns the monotonic deadline and races application callbacks, model work,
streaming, retry waits, toolsets, tools, hooks, MCP calls, and output validation.
The same remaining time tightens every model request, allowing the standard
HTTP transport to interrupt DNS, connect, write, read, and streaming work.
Cancellation uses the same task-draining path. A resumed approval is a new
invocation and receives a fresh monotonic budget.

Retry policy lives in the agent, while transport metadata stays factual and
provider-neutral. Rate limits, server errors, timeouts, connections, and decode
failures are independently classifiable. Optional exponential backoff uses
full jitter, preserves server-directed `Retry-After`, shares the run's
cancellation boundary, and consumes a cumulative delay budget.

The HTTP transport accepts numeric and IMF-fixdate `Retry-After`, using the
response `Date` header to avoid wall-clock skew. Rate-limit counts remain plain
integers. Provider request IDs are copied into 256-byte inline storage before
the HTTP request closes, then exposed as borrowed views to observers and hooks.
Provider adapters normalize connection and response-decoding failures without
turning cancellation, allocation, or response-size failures into retries.
Error observers do not receive raw bodies by default. An explicit policy may
expose only a bounded prefix, while parsed messages and codes use smaller
independent caps. This policy is propagated through the provider-neutral model
request rather than implemented differently in each adapter.

Idempotency is capability-driven because generation APIs do not share a safe
header. OpenAI-compatible gateways may name an idempotency header. The agent
then generates one random key per logical model request and reuses it only for
that request's retry attempts.

Context measurement runs after history processors and step-specific toolsets,
but before lifecycle request-start hooks and provider encoding. The leaf
`context_budget` module classifies only provider-facing bytes: prompt text,
tool definitions and traffic, schemas, and media sources. It allocates nothing.
The agent executes an optional tokenizer and one overflow-compaction callback
through `RunControl`, then remeasures the returned provider view. Canonical
history is never replaced by budget compaction.

Input capacity is the smaller of an explicit input limit and total capacity
after output reservation. The resolved model `max_tokens` supplies the default
reservation. The built-in estimate is portable rather than tokenizer-exact;
applications can replace it without changing the enforcement or ownership
path.

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

## Agent specifications

`agent_spec` keeps configuration in three explicit phases. Parsing creates a
strict data-only arena. Dry-run resolution reads only allowlisted environment
names and invokes secret-free provider validation plus borrowed capability
lookup. Full resolution then constructs the model through an application
vtable and assembles an owned `Agent`.

This boundary intentionally does not import concrete providers. It avoids a
second provider abstraction inside configuration parsing and leaves client
ownership, model discovery, and application capability catalogs replaceable.
Transitive capability dependencies are resolved before registry validation;
provider construction happens only after all local checks pass.

## MCP toolsets

`mcp.Client` implements the stateless MCP `2026-07-28` envelope. Every request
carries the protocol version, client identity, and capabilities. Typed helpers
cover every core client method, while the generic JSON request path preserves
extension methods and unknown fields. The toolset adapter follows list cursors,
preserves schemas, mirrors `x-mcp-header` arguments, and renders tool content
through the normal agent loop.

The focused `mcp.primitives` module owns borrowed protocol value objects.
`ClientCapabilities` and `ServerCapabilities` serialize standardized fields,
validate object-valued experimental and extension settings, and enforce
prefixed extension identifiers. `SubscriptionFilter` gives the long-lived
listen request a typed selection of list and resource updates. These values
return caller-owned JSON documents; explicit raw JSON entry points remain the
forward-compatibility boundary for revisions ZigAI does not know yet.
`Notification` owns the common JSON-RPC framing for every standardized event,
requires subscription correlation for update streams, validates finite
progress, and parses arbitrary logging data through the bounded MCP JSON
policy before serialization.
Prompt retrieval and completion use `PromptRequest` and `CompletionRequest`;
their embedded argument maps are bounded objects and their reference union
makes prompt names distinct from resource URI templates. Explicitly named
`getPromptJson` and `completeJson` methods retain the open wire escape hatch.
Client cancellation uses the same integer-or-string `RequestId` as notification
and subscription correlation and is encoded through the typed notification
path. `RequestOptions.metadata` owns typed progress-token and log-level fields;
the latter is the deprecated per-request replacement for the removed
`logging/setLevel` RPC.

The Tasks extension lives in `mcp/tasks.zig`, outside core transport dispatch.
Its request builders borrow application data, while parsed task results own a
single arena. A tagged state union enforces the payload required by each task
status, so completed, failed, and input-required states cannot be confused.

Multi round-trip requests replace server-initiated JSON-RPC calls. When a
result requires sampling, roots, or elicitation, the configured `InputHandler`
answers each item and the client retries with `inputResponses` and opaque
`requestState`. The handler receives one borrowed `InputRequest` whose enum
identifies the validated input family. `InputResponse` provides owned builders
for elicitation actions and primitive form values, file roots, and sampling
role/content/model results; the client still validates the encoded response
against the original input method before retrying. `subscriptions/listen`
forwards request-scoped SSE or stdio notifications to an `EventSink` until the
final response closes the stream.

`StreamableHttpTransport` emits the required protocol, method, name, and tool
parameter headers. It accepts direct JSON and request-scoped SSE responses.
`StdioTransport` frames one JSON-RPC message per line and correlates response
IDs. The separate `mcp.auth` module owns transport-level authorization
contracts: bounded protected-resource and authorization-server discovery,
issuer-bound token acquisition, RFC 9207 response checks, and scope step-up.
The HTTP transport adds one sensitive Bearer header per attempt; credentials
never enter the JSON-RPC envelope.

`mcp.Server` is a transport-neutral dispatcher. It provides discovery,
per-request version checks, standard and tool-parameter header validation,
server identity metadata, core or extension method dispatch, JSON-RPC errors,
and a stdio serving loop. An HTTP application passes request headers and TLS
state to the same dispatcher. Deployment policy rejects invalid browser
Origins, Host mismatches, and unexpected cleartext before JSON parsing;
authorization policy validates the Bearer token for the canonical resource
before application dispatch and returns owned `WWW-Authenticate` headers.

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
implementation. It forwards borrowed model deltas, derived output snapshots,
completed calls, usage, tool results, and final output synchronously. Once
visible stream output has been emitted, a failed request is never retried,
preventing duplicated text or tool events.

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
