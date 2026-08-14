# Architecture

ZigAI has four layers, and each one has one job.

## Model contract

`Model` is a small vtable: context, capabilities, and one request function. It
accepts provider-neutral messages and returns text or tool calls. A new
provider does not need to modify the agent.

`ModelProfile` is resolved before the agent runs. It describes model behavior
independently from the transport: tools, parallel calls, system messages,
structured JSON, and thinking. The agent rejects unsupported requested
features before sending a paid request.

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
tools and instructions, then appends each capability's contributions from left
to right. Capabilities can contribute toolsets as well. Capability settings
override earlier capabilities; direct agent and run settings remain higher
precedence. Model selectors receive the model chosen so far, and capability
lifecycle hooks run in the same stable order.

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
loop, while `Result.messages` contains only reusable conversation history.

History storage uses a versioned provider-neutral JSON format. Before each
request, agent, capability, and run-specific processors transform a borrowed
provider-facing view from left to right. Built-ins trim old messages, compact
adjacent text, summarize an older prefix through an application callback, and
remove malformed or orphaned tool parts. The canonical arena-owned conversation
is never truncated, so callers can persist or reprocess the complete result.

An agent may carry an opaque per-run dependency pointer. Contextual tools use
`ToolRunContext.dependency(T)` to recover their application type and can also
inspect cumulative token usage and model-request count. Existing simple tool
callbacks remain context-free. Invalid arguments and recoverable tool failures
become error tool results so the model can repair its call. Retry counts are
kept separately for each tool, with a per-tool override, and do not consume the
structured-output retry budget. Allocation and cancellation failures remain
fatal; custom tools can override failure classification.

When a model requests multiple tools, the agent uses its `Io` runtime to run
them concurrently. Allocations into the result arena are synchronized, result
parts remain in model call order, and a fatal failure cancels outstanding work.
Tools receive the run's `Io` and cancellation token for cooperative cleanup.
`limits.max_tool_calls` caps the total across every step of a run.

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

## MCP toolsets

`mcp.Client` adapts a Model Context Protocol server to the existing `Toolset`
contract. It performs the `2025-11-25` initialize/initialized handshake,
follows `tools/list` cursors, preserves each input schema, and maps
`tools/call` content back into a model-visible tool result. Discovery runs
through normal per-step toolset preparation, so namespaces, metadata,
duplicate-name checks, lifecycle hooks, retries, and parallel dispatch need no
MCP-specific branch in the agent.

The MCP message transport is a small JSON-RPC vtable. `StreamableHttpTransport`
uses the shared ZigAI HTTP abstraction for testability, accepts direct JSON or
SSE responses, correlates SSE messages by request ID, and retains bounded
`Mcp-Session-Id` response metadata without an extra allocation. Custom request
headers support authentication without entering recorded cassette data.

`StdioTransport` owns the server child process, frames UTF-8 JSON-RPC messages
one per line, serializes concurrent exchanges, ignores notifications while
waiting for the matching response, and rejects unsupported server-to-client
requests. Closing it closes stdin and terminates the child.

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
