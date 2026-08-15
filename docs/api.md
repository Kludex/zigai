# Public API and ownership

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

Use these namespaces for the rest of the API:

| Namespace | Purpose |
| --- | --- |
| `zigai.providers` | Native and named OpenAI-compatible provider clients |
| `zigai.models` | Fallback and application-selected model routing |
| `zigai.history` | Version-2 history serialization, version-1 migration, and processors |
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
| `evals.Report` | Owns every case and evaluation result until `deinit` |
| `transport.Response` | Caller frees `body` with the allocator passed to `send` |

`transport.HttpTransport.init` uses bounded decompressed response defaults:
16 MiB per buffered body and 1 MiB per streaming line. Pass a
`transport.Limits` value to `HttpTransport.initWithLimits` to change them.
The limit excludes the streaming newline. A body or line exactly at its limit
is accepted; the next byte returns `error.ResponseTooLarge` or
`error.StreamLineTooLarge`.

Inputs, callback events, stream events, lifecycle events, and provider error
observer values are borrowed unless their documentation says otherwise. Copy
data inside the callback if it must outlive the call. Functions such as
`history.stringify`, `stringifyResumeDecisions`, and provider request encoders
return a slice owned by the caller's allocator.

Direct `Model.request`, `Model.stream`, and provider decoder calls build nested
response data with the supplied allocator. Use an arena and release the arena
as one unit. Normal `Agent` calls already provide this ownership boundary.

## Errors

The public named error categories are:

- `Agent.Error` (also `zigai.AgentError`) for agent validation, limits, and
  lifecycle failures;
- `zigai.ProviderRequestError` for normalized rate-limit, server, and other
  non-success provider responses;
- `providers.<name>.Error` for provider encoding and decoding failures plus the
  normalized provider request errors;
- `history.Error`, `json_schema.Error`, `evals.Error`, `mcp.Error`, and
  `transport.Error` for their subsystem-defined failures.

`transport.Error.ResponseTooLarge` and `transport.Error.StreamLineTooLarge`
are stable policy failures. They apply to decompressed bytes, so compression
cannot bypass the configured allocation boundary.

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
