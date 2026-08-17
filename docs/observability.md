# Observability

You cannot operate what you cannot see. ZigAI covers three layers:
lifecycle hooks for application logic, structured diagnostics for logs, and
OpenTelemetry for traces and metrics. All three see the same run, and none
of them receives credentials.

## Lifecycle hooks

`Agent.hooks` and capability hooks receive the same ordered event stream. It
covers run boundaries, model requests, tool validation and execution, output
validation, errors, retries, and stream events before and after delivery.

Hook values are borrowed and callbacks run synchronously. Copy only what you
need to retain. A hook error stops the run and is reported through
`run_error`.

## Structured diagnostics

`Agent.diagnostics` maps lifecycle activity to structured, leveled events. It
does not depend on a logging package; provide a `DiagnosticSink` callback
that bridges to the backend used by the application.

```zig
.diagnostics = .{
    .sink = my_diagnostic_sink,
    .minimum_level = .info,
    .sensitive_values = &.{api_token},
},
```

Prompt, output, tool arguments, and tool results are omitted unless
`capture_content = true`. String values are redacted before truncation, and
attribute counts, keys, and values have explicit byte limits. Sink failures
are fail-open by default; set `fail_open = false` when diagnostics are
required for the run to proceed. Events and attributes are borrowed for the
callback only.

## OpenTelemetry

Configure `Agent.telemetry` to export OpenTelemetry-shaped spans and metrics:

```zig
.telemetry = .{
    .io = init.io,
    .exporter = my_otel_exporter,
    .cost_estimator = my_cost_estimator,
},
```

Each run has one trace with child model-request, tool-validation,
tool-execution, and output-validation spans. Correlated lifecycle events
cover model, tool, retry, stream, deferred, and enqueued-message phases.
Metrics cover latency, request, validation, and tool counts, retries,
cached/reasoning/audio token usage, and optional cost. The exporter is a
small synchronous bridge to your OpenTelemetry SDK or OTLP pipeline.
`Exporter.eventFn` is optional for existing span-and-metric bridges.

MCP clients and servers accept `McpTelemetry`. It emits semantic
client/server operation spans and duration metrics, adds method, JSON-RPC,
protocol, transport, session, tool, prompt, resource, and task attributes,
and propagates W3C `traceparent` through `params._meta`.

### Buffered export

Keep exporter work away from the agent path with a bounded buffer:

```zig
var buffered = zigai.BufferedTelemetryExporter.init(
    allocator,
    init.io,
    my_otel_exporter,
    1_024,
);
defer buffered.deinit();
buffered.overflow = .drop_oldest;

const agent = zigai.Agent{
    .model = model,
    .telemetry = .{
        .io = init.io,
        .exporter = buffered.exporter(),
    },
};

// Run during graceful shutdown, after agent work has stopped.
_ = try buffered.shutdown();
```

The buffer deep-copies admitted signals. Choose `.drop_newest`,
`.drop_oldest`, or `.reject` for saturation. `flush` and `shutdown` serialize
downstream calls, and `stats` reports pending and dropped work. Drops also
emit the `zigai.telemetry.dropped` counter with a bounded `reason` attribute.

!!! warning "Prompt capture is opt-in"
    Prompt capture is disabled by default. Set `content.prompts` to `.raw` or
    `.redacted` only when the destination and data policy are ready. Redacted
    mode uses an application callback, and both modes enforce configured
    content and attribute-size bounds before exporter callbacks run.

Pass `RunOptions.telemetry_parent` to continue an upstream trace. Exporter
failures are fail-open by default, so telemetry does not break an agent run.

## Usage and cost

Every provider response has `RequestUsage`. Agent results have `RunUsage`,
which also includes request attempts, tool calls, provider latency, and
total run duration.

Cached and audio tokens are subsets of the input or output totals. Reasoning
tokens are a subset of output tokens. Provider counters without a portable
field stay available through `usage.details`.

Cost estimation is opt-in:

```zig
var result = try (zigai.Agent{
    .model = model,
    .price_table = zigai.pricing.builtin,
}).run(allocator, "Hello");
defer result.deinit();

if (result.usage.cost) |cost| {
    std.debug.print("estimated cost: ${d:.6}\n", .{cost.usd()});
}
```

`pricing.builtin` is generated from a pinned
[pydantic/genai-prices](https://github.com/pydantic/genai-prices) v2
snapshot. It covers provider aliases, model match rules, tiered prices,
modalities, and request-based charges without fetching prices at runtime.

Use `pricing.builtin_version` to persist its version. Unknown models and
unpriced usage produce no estimate. Pass your own `PriceTable` for negotiated
contracts, regional prices, or time-based discounts. Money is stored as
integer nano-USD.
