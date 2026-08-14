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

Use these namespaces for the rest of the API:

| Namespace | Purpose |
| --- | --- |
| `zigai.providers` | Native and named OpenAI-compatible provider clients |
| `zigai.models` | Fallback and application-selected model routing |
| `zigai.history` | Versioned history serialization and processors |
| `zigai.evals` | Datasets, evaluators, reports, and model grading |
| `zigai.mcp` | MCP 2026 client, server, Streamable HTTP, and stdio |
| `zigai.telemetry` | OpenTelemetry-shaped hooks and metrics |
| `zigai.reflect` | Compile-time tools and JSON Schema derivation |
| `zigai.transport` | Pluggable buffered and line-streaming HTTP transport |
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
