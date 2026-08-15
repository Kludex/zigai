# Public API and ownership

Named framework failures are listed in the [error reference](errors.md).
Application callback, allocator, runtime, and custom transport errors propagate
alongside those named errors without wrapping.

ZigAI's supported API starts at `@import("zigai")`. Prefer its short aliases
for agent and model types, and use the named modules for larger subsystems:

```zig
const zigai = @import("zigai");

const Agent = zigai.Agent;
const Client = zigai.providers.openai.Client;
const Dataset = zigai.evals.Dataset;
```

## Supported surface

The root exposes the agent loop, its configuration and result types, message
and tool types, model settings and usage, streaming events, provider errors,
history helpers, telemetry, MCP, evaluation, and model-routing modules.

Reusable history is typed as `Message`, a union of `RequestMessage` and
`ResponseMessage`. Construct prompts and tool returns with `RequestPart`;
model implementations return `ResponsePart`. `PromptPart` is the short alias
for rich `UserContent` accepted by `RunOptions.prompt_parts`. `Part` remains a
compatibility alias for `ResponsePart`.

The vocabulary follows PydanticAI's message model while staying idiomatic in
Zig:

| Area | Types |
| --- | --- |
| Prompts | system, user, retry, instruction, speech, and tool-availability parts |
| User content | text, tagged text, image, audio, video, document, binary, uploaded file, and cache point |
| Tools | function, provider-native, tool-search, and capability-load calls and returns |
| Model output | text, thinking, compaction, files, speech, and tool parts |

`zigai.tool.Policy` is the orchestration extension point for function tools.
Its typed events cover preparation, argument validation, dynamic approval,
pre-call behavior, and return validation. `Agent.tool_policies` run first;
capability policies follow in capability order. Argument and return policies
may transform values or request a retry from the tool's own budget. Dynamic
approval is evaluated after valid arguments and persisted across pause/resume.
`Tool.sequential` provides scheduler-wide exclusivity. Return schemas are
local unless `return_schema_visibility` opts into provider descriptions.

## Capabilities

`Capability` is a borrowed implementation bundle. It can contribute local and
provider-managed tools, toolsets, instructions, lifecycle hooks, tool policies,
history processors, output validators, model settings, and a model selector.
Anonymous capabilities are eager-only. A capability needs a stable `id` when
it is on demand or declares dependencies or conflicts.

Set `loading = .on_demand` to keep the bundle out of the first provider
request. ZigAI adds a catalog instruction and a sequential `load_capability`
function instead. A successful call resolves dependencies in declaration
order, returns their instructions in dependency-first order, and activates all
contributions together before the next model request. OpenAI Responses,
OpenAI-compatible Chat Completions, Anthropic Messages, and Google Gemini replay
typed capability-load history through their ordinary function-call protocols.

Loads are atomic: a conflict, callback failure, or allocation failure cannot
leave a partial bundle active. Structural errors are detected before the first
model request. `CapabilityRegistry` exposes the same bounded validation and
dependency planning without executing an agent; `LoadResolution` owns its
arena and must be deinitialized.

`CapabilityUnloadPolicy.history` reconstructs successful loads from canonical
history. `.run_end` forgets them between independent invocations while keeping
them active through serialized pause/resume. Unsuccessful load results never
restore state.

Capabilities compose in fixed scope order: inherited, agent, run, nested, then
subagent. Direct `Agent.capabilities` occupy the agent scope and
`RunOptions.capabilities` occupy the run scope. `RunOptions.capability_layers`
adds explicit scopes; declaration order is stable within a scope regardless of
the layer slice order.

`CapabilitySnapshot` is borrowed and exposes active IDs plus the subset loaded
on demand. It is available to dynamic instructions, toolsets, tools, tool
policies, output validators, and model selectors. Nested agents can use the
snapshot to construct an inherited `CapabilityLayer`; ZigAI does not infer
subagent ownership from an opaque dependency pointer.

The short `system_prompt`, `user_prompt`, `retry_prompt`, and `text` variants
are convenient when no part metadata is needed. Their `*_part` counterparts
retain timestamps, IDs, and provider replay data. Provider-bound parts carry a
`ProviderPart`; file IDs carry their owner in `UploadedFile`.

History preserves opaque provider data as `ProviderDetails`, a structured JSON
object separate from application `Metadata`. Current adapters reject
provider-bound part IDs or details they cannot replay, and validate ownership
before encoding uploaded files. They never silently flatten fields.
Create it from a parsed object with `ProviderDetails.fromValue`; nested slices,
arrays, and object maps follow the enclosing owner's lifetime.

All slices are borrowed. `Agent.Result`, `history.Owned`, and other explicitly
owned containers define the lifetime of copied or parsed messages. The message
types themselves never allocate and never store an allocator.

The same types live under `zigai.messages`. The namespace is the canonical home
for durable conversation data; the root aliases keep common application code
short, and `zigai.model` keeps compatibility aliases for model implementers.

Use these namespaces for the rest of the API:

| Namespace | Purpose |
| --- | --- |
| `zigai.messages` | Provider-neutral request/response messages and parts |
| `zigai.capability` | Capability descriptors, scopes, diagnostics, and dependency planning |
| `zigai.agent_spec` | Strict JSON/YAML agent configuration, dry-run validation, and resolution |
| `zigai.settings` | Portable model controls and tagged provider extensions |
| `zigai.usage` | Per-request and aggregate run usage, exact costs, and native counters |
| `zigai.pricing` | Explicit versioned price tables and deterministic estimates |
| `zigai.codecs.pydantic_ai` | Lossless PydanticAI stable-v2 JSON interchange |
| `zigai.security` | Outbound URL validation and diagnostic redaction |
| `zigai.provider` | Provider identity, authenticated operations, policy, discovery, files, and profiles |
| `zigai.providers` | Native and named OpenAI-compatible provider clients |
| `zigai.providers.http` | Reusable authenticated HTTP provider for model adapters |
| `zigai.models` | Fallback and application-selected model routing |
| `zigai.history` | Version-2 ZigAI history serialization, version-1 migration, and processors |
| `zigai.evals` | Datasets, evaluators, reports, and model grading |
| `zigai.mcp` | MCP 2026 client, server, Streamable HTTP, and stdio |
| `zigai.telemetry` | OpenTelemetry-shaped hooks and metrics |
| `zigai.reflect` | Compile-time tools and JSON Schema derivation |
| `zigai.transport` | Pluggable buffered and line-streaming HTTP transport |
| `zigai.json` | Pre-allocation validation and boundary-specific JSON limits |
| `zigai.testing` | Deterministic scripted models for application tests |

Provider `Client.model()` values borrow their client. Keep the client and its
transport alive for every agent run that uses the model. The same rule applies
to model routers, MCP clients, callback contexts, dependencies, and toolsets.
`Provider` values likewise borrow their concrete provider state. Model and file
discovery results own arenas and must be released with `deinit`.

`zigai.providers.http.Configured` is the standard concrete boundary for an
HTTP-backed provider. Its API root, credential, configured headers, transport,
request policy, and optional profile callbacks are borrowed. `provider()`
returns another borrowed view; keep the `Configured` value at a stable address
until every model and in-flight request using it has finished. Model adapters
receive only relative endpoints and never receive the provider credential.

OpenAI uses that split directly. Create a stable `openai.Provider`, then pass
its borrowed interface to the Responses API client:

```zig
var provider = zigai.providers.openai.Provider.init(api_key, transport);
var client = zigai.providers.openai.Client{
    .model_name = "gpt-5-mini",
    .provider = provider.provider(),
};
```

Use `Provider.initWithOptions` for a custom API root, configured headers,
provider-wide request policy, or model profile callbacks. The provider and
transport must outlive the client and every in-flight model request.

Anthropic follows the same construction pattern with
`zigai.providers.anthropic.Provider`. Its provider owns the `x-api-key` header;
the client retains `max_tokens` and the Messages API wire behavior.

Google uses `zigai.providers.google.Provider`; it owns `x-goog-api-key` and
keeps the stable `gcp.gen_ai` provider identity. Its client builds model-bound
GenerateContent endpoints and encodes Gemini request and response bodies.

OpenAI-compatible modules follow the same rule. Each named module exports a
matching `Provider` and `Client` built from shared compile-time defaults. The
provider owns the API root, provider identity, authentication style, headers,
request policy, transport, and profile callbacks. The client owns only the
model name, model settings, Chat Completions behavior, and optional
gateway-specific idempotency header. Use
`openai_compatible.Provider.initWithOptions` when the endpoint or identity is
selected at runtime; Azure OpenAI and Bedrock expose `apiBase` helpers for
deployment-specific roots.

`agent_spec.Owned` owns parsed configuration in an arena. It is data-only and
does not read secrets or construct clients. `validateResolution` uses
application-supplied provider and capability catalogs without building a
model. `agent_spec.Resolved` owns copied configuration and the model context
allocated through its resolver; its optional cleanup callback runs before the
arena is released. Capability implementations remain borrowed. See
[Agent specifications](agent-specs.md) for the complete contract.

`ModelSettings` also borrows stop strings, tool names, request headers, and
provider-extension JSON. Those values need to live only until the model request
returns; results and reusable history do not retain them. An empty non-null
slice is an explicit override, while null inherits the lower-precedence value.

## Ownership

ZigAI follows one rule for high-level operations: a returned type with a
`deinit` method owns its complete result graph.

| Value | Ownership rule |
| --- | --- |
| `Agent.Result` | Owns output and message history until `deinit` |
| `TypedResult(T)` | Owns the decoded value, JSON, and history until `deinit` |
| `RunOutcome` / `PausedRun` | Owns completed or serialized paused state until `deinit` |
| `OwnedResumeDecisions` | Owns parsed decisions until `deinit` |
| `history.Owned` | Owns parsed history until `deinit` |
| `codecs.pydantic_ai.Owned` | Owns the complete PydanticAI JSON value graph until `deinit` |
| `capability.LoadResolution` | Owns its dependency plan and diagnostic until `deinit` |
| `evals.Report` | Owns every case and evaluation result until `deinit` |
| `transport.Response` | Caller frees `body` with the allocator passed to `send` |

`ResponseMessage.usage` is `RequestUsage`. `Agent.Result`, `PausedRun`,
`TypedResult`, and `evals.Report` expose `RunUsage`. Cached and modality fields
are inclusive subsets of the input/output totals, so `totalTokens()` is always
`input_tokens + output_tokens`. Result arenas own usage detail names and price
table version strings.

`UsageCost` stores nano-USD exactly. `PriceTable.estimate` returns null for an
unknown model or any non-empty bucket without a rate. `pricing.builtin` is an
opt-in snapshot identified by `pricing.builtin_version`; applications may
provide a different immutable table through `Agent.price_table`.

`transport.HttpTransport.init` uses bounded decompressed response defaults:
16 MiB per buffered body and 1 MiB per streaming line. Pass a
`transport.Limits` value to `HttpTransport.initWithLimits` to change them.
The limit excludes the streaming newline. A body or line exactly at its limit
is accepted; the next byte returns `error.ResponseTooLarge` or
`error.StreamLineTooLarge`.

Inputs, callback events, stream events, lifecycle events, and provider error
observer values are borrowed unless their documentation says otherwise. Copy
data inside the callback if it must outlive the call. Functions such as
`history.stringify`, `codecs.pydantic_ai.stringify`,
`stringifyResumeDecisions`, and provider request encoders return a slice owned
by the caller's allocator.

Direct `Model.request`, `Model.stream`, and provider decoder calls build nested
response data with the supplied allocator. Use an arena and release the arena
as one unit. Normal `Agent` calls already provide this ownership boundary.

## Output strategies

`Agent.output` is an `OutputSpec`, separate from the provider wire
`OutputFormat`. The concise `.json_schema` form accepts one named schema;
`.native` accepts named alternatives and combines them with `anyOf`;
`.prompted` accepts the same alternatives plus an optional template containing
one `{schema}` marker. Prompted output requires system instructions, selects
JSON-object mode when the profile supports it, and otherwise uses text mode.
Its result is always validated locally.

Specification slices are borrowed for the run. Combined schemas and rendered
instructions live in the run arena and follow the result ownership boundary.

`.tool` exposes each choice as a separate function-tool definition and requires
tool support. Non-object schemas receive a provider-facing `{ "value": ... }`
wrapper that the agent removes after local validation. `Result.output_name`
identifies the chosen branch. An `OutputFunction` receives borrowed
`OutputRunContext` state and validated JSON; returned slices must be static or
allocated with its supplied run-arena allocator. Its explicit `.retry` result
is safe to send to the model, while thrown errors stop the run.

`Agent.output_validators` runs ordered `OutputValidator` callbacks after schema
validation and after an output function. Each callback receives the selected
choice name, borrowed `OutputRunContext`, and the previous callback's output.
It returns `.output` to accept or transform the value, or `.retry` with a safe
model-visible correction message. Transformed structured output is checked
against its schema again. A thrown callback error aborts the run. Capabilities
can contribute validators through `Capability.output_validators`; agent-level
validators run first.

`Agent.end_strategy` defaults to `.graceful`: ordinary calls before the first
successful output run, later calls are closed as skipped. `.early` evaluates
output calls first and skips ordinary calls after one succeeds. `.exhaustive`
runs every emitted call and keeps the first successful output by emission
order. Deferred approval or external calls still pause before finalization.

### Local JSON Schema dialect

Every hand-written output schema is checked before the first model request.
ZigAI implements a fail-closed subset of JSON Schema Draft 2020-12: unknown
validation keywords and non-local references are rejected instead of ignored.
`zigai.json_schema.supported_dialect` contains the accepted `$schema` URI, and
`validateSchema` can preflight a schema independently of an agent run.

The supported assertions are:

- `type`, `enum`, `const`, `allOf`, `anyOf`, `oneOf`, `not`, and
  `if`/`then`/`else`;
- `$defs` with `#` or single-segment `#/$defs/...` references, including JSON
  Pointer `~0` and `~1` escapes;
- `properties`, `required`, `additionalProperties`, `propertyNames`,
  `dependentRequired`, and minimum/maximum property counts;
- `items`, `prefixItems`, `contains`, minimum/maximum contains and item counts,
  and `uniqueItems`;
- Unicode-codepoint string lengths; and
- inclusive/exclusive numeric bounds and `multipleOf`.

Standard descriptive annotations such as `title`, `description`, `default`,
`examples`, `format`, and read/write/deprecation flags are accepted but do not
change validation. Regex, remote or general JSON Pointer references, dynamic
references, and unevaluated-value keywords are currently unsupported.
Malformed supported vocabulary returns `InvalidJsonSchema`; unsupported valid
vocabulary returns `UnsupportedJsonSchema`; a valid output that misses an
assertion returns `OutputSchemaValidationFailed`.

## Streaming events

`ModelStreamEvent` represents provider response parts with `part_start`,
`part_delta`, and `part_end`; every event for a part uses the same `index`.
`ResponsePartDelta` covers text, thinking, function and native tools, native
tool returns, media, speech, and compaction. Usage is reported separately.

`AgentStreamEvent` wraps model events and adds function-tool call/result,
tool-availability, deferred request/result, enqueued-message,
`partial_output`, and `final_result` events. A `partial_output` is the complete
output accumulated so far, not the latest delta. The corresponding raw model
event is delivered first. Text snapshots are accumulated directly. Structured
snapshots are repaired into valid JSON, then checked against present types,
properties/items, forbidden extras, and maximum bounds. Assertions that later
bytes can satisfy or change, such as `required`, minimum bounds, `const`, and
numeric limits, are deferred to final validation.

Output functions and validators receive every useful partial snapshot with
`OutputRunContext.partial_output = true`; `.retry` suppresses that snapshot and
a thrown error stops the stream. They run again on the final candidate with
`partial_output = false`. Structured transformations are partially checked
again before delivery. Only `final_result` is accepted output and receives full
validation. JSON object and schema events attach a `std.json.Value` snapshot.
All values are borrowed for the callback; copy them before returning if they
must be retained.

`runUntilPauseStream` and `resumeRunStream` preserve the event flow across
approval and external-tool boundaries. Providers restart part indexes for each
model response in a multi-request agent run.

`PendingMessageQueue` is an allocator-owned, thread-safe, one-run FIFO. It
deep-copies `RequestMessage` batches and requires a `std.Io` runtime for its
mutex. Attach it through `RunOptions.pending_messages`; keep it alive until the
run returns, then call `deinit`. Accepted batches enter history only at safe
boundaries: before a model request, after tool results, or after a provisional
final response. Each insertion emits `enqueued_messages` for streaming runs.

If a run pauses, accepted messages are stored separately in the serialized
pause state and inserted immediately after deferred tool results on resume.
Cancellation or another terminal failure closes the queue and discards batches
that did not enter history. Finalization checks and closes the queue under the
same lock, so an enqueue is either accepted for another model step or rejected
with `PendingMessageQueueClosed`; it cannot disappear behind a final result.

## Errors

The public named error categories are:

- `Agent.Error` (also `zigai.AgentError`) for agent validation, limits, and
  lifecycle failures;
- `zigai.ProviderRequestError` for normalized rate-limit, server, and other
  non-success provider responses;
- `providers.<name>.Error` for provider encoding and decoding failures plus the
  normalized provider request errors;
- `history.Error`, `codecs.pydantic_ai.Error`, `json_schema.Error`,
  `evals.Error`, `mcp.Error`, and `transport.Error` for their
  subsystem-defined failures.

`transport.Error.ResponseTooLarge` and `transport.Error.StreamLineTooLarge`
are stable policy failures. They apply to decompressed bytes, so compression
cannot bypass the configured allocation boundary.

## Security policy

`zigai.UrlPolicy` is HTTPS-only and public-network-only by default. Agents apply
it to provider endpoints and rich-content URLs. MCP Streamable HTTP and the
standard HTTP transport enforce it independently, so direct and custom-model
use keeps the same boundary.

`HttpTransport.initWithOptions` configures URL, redirect, and response-size
policy together. Redirects are never followed; the explicit choices are reject
or return the 3xx response. See [Security](security.md) for local development,
allowlists, DNS limitations, credential redaction, and trust boundaries.

## JSON limits

`zigai.json.validate` scans one complete document without retaining a value
graph. It checks the encoded document size, decoded string or encoded number
size, container depth, and the number of fields or elements in each collection.
Its stable `ValidationError` distinguishes each limit from malformed JSON.
`json.parse` and `json.parseLeaky` combine that preflight with owned or
arena-owned decoding and map invalid input to a caller-selected stable error.
`json.validateAs` provides the same mapping without building a value graph,
while `json.isValid` is useful for boolean validation such as evals.

ZigAI applies these reviewed defaults before its own decoders allocate:

| Boundary | Document | Value | Depth | Items per collection |
| --- | ---: | ---: | ---: | ---: |
| History | 16 MiB | 1 MiB | 64 | 65,536 |
| Paused state | 32 MiB | 16 MiB | 64 | 65,536 |
| Resume decisions | 4 MiB | 1 MiB | 32 | 16,384 |
| Provider response | 16 MiB | 4 MiB | 128 | 65,536 |
| Tool payload | 1 MiB | 1 MiB | 64 | 4,096 |
| MCP message | 4 MiB | 1 MiB | 64 | 16,384 |
| JSON Schema | 2 MiB | 512 KiB | 64 | 16,384 |
| CLI manifest | 1 MiB | 256 KiB | 32 | 4,096 |

The named profiles live under `zigai.json.defaults`. Applications can use a
custom `json.Limits` value when validating their own untrusted JSON entry
points.

Every `Tool` execution and validation entry point requires `arguments_json` to
contain one complete JSON document within the tool-payload profile. Invalid or
oversized arguments return `error.InvalidToolArguments` before the callback is
invoked.

## Run deadlines and cancellation

`Agent.run_timeout_ms` creates one absolute monotonic deadline for an
invocation. `RunOptions.timeout_ms` may tighten that budget for one buffered,
streaming, pause, or resume call. `Agent.request_timeout_ms` is a separate
per-model-attempt ceiling; each attempt receives the smaller of that value and
the remaining run time, so retries never restart the run budget.

The run control covers model requests and streams, retry waits, dynamic
instructions, capability model selection, history processors, toolset
preparation, argument validation, local and MCP tools, output validators,
lifecycle hooks, stream sinks, and resumed tool decisions. Official HTTP
transports apply the remaining timeout to the complete operation, including
DNS, connect, write, read, and stream consumption. A timed-out or cancelled
task is cancelled and drained before the public call returns.

Deadlines require `Agent.io`. Cancellation remains cooperative without a
runtime; with `Agent.io`, ZigAI also races the token against in-flight work.
Terminal control errors are `RunTimedOut`, `Cancelled`,
`RunControlRequiresIo`, and `RunControlConcurrencyUnavailable`. Callback
contexts expose the shared `RunControl`, and `ToolRunContext` exposes its
absolute `deadline` for nested work.

Preemptive control requires the runtime to schedule the operation and each
active deadline or cancellation watcher concurrently. If it cannot,
`RunControlConcurrencyUnavailable` or `ToolConcurrencyUnavailable` is returned
instead of running a watcher inline and risking a stalled caller.

A paused run ends its invocation. `resumeRunWithOptions` starts a new monotonic
budget because a process-local monotonic timestamp cannot be serialized safely
across restarts.

## Retry policy

Retry decisions classify rate limits, server errors, request timeouts,
connection failures, and provider-response decoding independently. Optional
exponential backoff uses full jitter from the application's `Io`, honors
numeric and HTTP-date `Retry-After`, and remains interruptible. The policy's
`max_total_delay_ms` bounds cumulative backoff across the run. A fallible
before-retry hook observes the planned and cumulative delay, rate-limit values,
and the bounded provider request ID.

The HTTP transport copies provider request IDs into bounded inline storage.
Provider error observers and retry hooks receive borrowed views; copy a value
to retain it. `ProviderConnectionError` and `ProviderResponseDecodeError` are
stable retry categories.

`ProviderError.body` is empty by default. Set
`Agent.provider_error_policy.capture_body` or `ModelRequest.error_policy` to
opt in, and choose `max_body_bytes`; exact-limit bodies are complete and larger
bodies set `body_truncated`. Provider messages and codes have independent caps.
The observer is synchronous and infallible, so none of its borrowed fields may
be retained without copying.

`RunOptions.request_id` supplies provider-facing correlation. OpenAI and
OpenAI-compatible adapters send it as `x-client-request-id`. Generation APIs
do not share a portable idempotency header, so official adapters do not claim
one. A compatible gateway may configure `Client.idempotency_header`; its model
profile then requests a generated key that remains stable across one logical
request's retries. This requires `Agent.io`.

## Context budgets

`Agent.context_budget` measures the provider-facing request after history
processors and dynamic toolsets have run. Separate limits cover prompt text,
tool traffic and definitions, JSON schemas, raw media sources, estimated input
tokens, and combined input/output capacity. `reserve_output_tokens` is removed
from `max_total_tokens`; when it is null, the resolved `ModelSettings.max_tokens`
is reserved instead. Exact boundaries are accepted.

The default estimate is deliberately provider-neutral: four measured bytes per
token plus fixed message and tool framing. `TokenEstimator` receives borrowed
`ContextBudget.Input` and `ByteUsage` values for provider-specific counting.
Estimator and overflow callbacks run under the invocation's deadline and
cancellation control.

On overflow, `ContextOverflowHook` receives the measured snapshot, first failed
boundary, and borrowed request view. It may return a borrowed history subslice
or allocate replacement messages from the supplied arena. ZigAI measures the
result once more; a remaining overflow becomes `ContextPromptTooLarge`,
`ContextToolsTooLarge`, `ContextSchemaTooLarge`, `ContextMediaTooLarge`, or
`ContextTokenLimitExceeded`. Callback rejection errors pass through unchanged.
Only the provider-facing view is compacted; owned result history remains
complete. `RunOptions.context_budget` replaces the agent policy for one run.

## Tool execution limits

`Agent.tool_limits` applies `zigai.ToolLimits` to local calls. The defaults are
eight concurrent calls, a 64-call queue, a 1 MiB result, 16 follow-up messages,
and 1 MiB of aggregate follow-up strings and binary data. `Tool.limits` may
tighten that policy for one tool, including an optional `timeout_ms`; it can
never loosen the agent-wide envelope.

Parallel batches preserve provider call order while the scheduler respects
both the agent-wide and per-tool concurrency and queue limits. `ToolTimedOut`,
`ToolQueueOverflow`, `ToolResultTooLarge`, and `ToolFollowUpOverflow` are
recoverable tool failures by default and are sent to the model through the
normal bounded retry path. Run deadline failures, `ToolIsolationRequiresIo`,
cancellation, allocation failure, and unavailable runtime concurrency remain
fatal. Tools should use `ToolRunContext.io` for blocking I/O and propagate
cancellation errors instead of swallowing them.

Public operations intentionally use inferred error unions. Allocator, network,
process, application callback, tool, hook, exporter, and custom model errors
pass through unchanged, so callers can handle their own errors without ZigAI
erasing them. Match the named errors that matter and propagate the remainder.

## Compatibility imports

`zigai.providers.<name>` is the preferred provider spelling. The original
`zigai.openai`, `zigai.anthropic`, `zigai.google`, and
`zigai.openai_compatible` aliases remain supported for the 0.x series.

The package also exports standalone `zopenai`, `zanthropic`, `zgoogle`, and
`zopenai_compatible` modules. They expose the same provider constants, error
set, client, and public codec functions, and can be imported together with
`zigai` in one executable.

## Versioning

ZigAI follows semantic versioning. During 0.x, a minor release may make a
documented public API change. Patch releases preserve source compatibility for
the supported surface described here. Provider wire behavior may evolve when
an upstream API changes, with real recorded cassettes covering the supported
adapters and model families.
