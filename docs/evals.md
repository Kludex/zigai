# Evaluations

Run a dataset through the same agent used by your application. Evaluations
are how you know a prompt change made things better instead of just
different.

## Datasets

```zig
const evaluators = [_]zigai.evals.Evaluator{
    zigai.evals.containsExpected(),
};

var report = try (zigai.evals.Dataset{
    .cases = &.{.{
        .name = "weather",
        .prompt = "What is the weather in Madrid?",
        .expected_output = "sunny",
    }},
    .evaluators = &evaluators,
}).run(allocator, agent);
defer report.deinit();
```

Built-ins cover exact matches, substring checks, and valid JSON. `Evaluator`
is a small callback interface for application-specific deterministic checks.
`ModelGrader` wraps another agent, requests a typed pass/score/reason result,
and validates that its score is between zero and one.

## Repetitions, retries, and concurrency

Use `runWithOptions` when an experiment needs repeated runs or retries:

```zig
var report = try dataset.runWithOptions(allocator, agent, .{
    .repetitions = 3,
    .max_concurrency = 4,
    .io = io,
    .task_retry = .{ .max_attempts = 3 },
    .evaluator_retry = .{ .max_attempts = 2 },
    .hooks = hooks,
});
defer report.deinit();
```

Task and evaluator retry budgets are independent. A retry classifier can
limit which errors are transient, while `beforeRetryFn` can apply
application-owned backoff. Lifecycle hooks receive stable zero-based case
indices, one-based repetition and attempt numbers, and every start, error,
retry outcome, and end. The plain `run` method remains a single-run,
single-attempt evaluation.

When `max_concurrency` is greater than one, ZigAI admits at most that many
case runs through the supplied `std.Io` runtime, writes them into stable
source-order slots, and aggregates usage after all work is joined. The
model, evaluators, retry callbacks, and lifecycle hooks must be thread-safe
in this mode. ZigAI serializes access to the caller allocator and the report
arena.

## Report and trace evaluators

Dataset-level `report_evaluators` run after every case and repetition has
finished. They receive a read-only `ReportView` and append named scalar
analyses with an optional assertion, unit, and reason. `Report.summary`,
`caseSummary`, and `scoreStatistics` expose pass rates plus finite-score
minimum, maximum, mean, and population standard deviation. A failed
aggregate assertion makes `Report.passed()` false.

`trace_evaluators` inspect the same `telemetry.Span` values sent to the
application exporter. Enabling them requires `Agent.telemetry`. ZigAI
installs a per-case exporter tee, deep-copies span names, attributes, IDs,
timing, and status into `CaseResult.spans`, and forwards spans and metrics
unchanged. Trace evaluators use the ordinary evaluator retry policy and add
results to the same ordered evaluation list after output evaluators.

## Online evaluation

For production sampling, `OnlineEvalSamplingPolicy` makes a stable decision
from the OpenTelemetry trace ID:

```zig
const policy = zigai.OnlineEvalSamplingPolicy{
    .trace_ratio = .{ .numerator = 1, .denominator = 100 },
};
if (try policy.includes(trace_context.trace_id)) {
    // Submit a trace-correlated OnlineEvalObservation to your evaluator path.
}
```

Online observations distinguish successful and failed runs. Evaluators
return bounded zero-to-one scores, and result sinks retain the originating
trace context. Sampling is deterministic across processes using the same
trace ID and policy.

`OnlineEvalQueue` owns sampled observations until they are processed:

```zig
var online = try zigai.OnlineEvalQueue.init(
    allocator,
    io,
    evaluators,
    result_sink,
    .{
        .sampling = policy,
        .max_pending = 128,
        .overflow = .drop_oldest,
        .metric_exporter = telemetry_exporter,
    },
);
defer online.deinit();

const agent = zigai.Agent{
    .model = model,
    .telemetry = telemetry,
    .online_evals = &online,
};
```

`Agent.online_evals` requires `Agent.telemetry`. Each invocation gets
isolated producer state and the same trace context as its OpenTelemetry run.
Successful and failed runs are sampled; paused runs create no terminal
observation.

!!! note "Admission never blocks the agent"
    Admission never invokes evaluators, result sinks, or metric exporters,
    and it never waits for the queue lock. The queue preallocates its slots,
    deep-copies bounded prompt, output, usage, and failure data, and drops on
    producer contention. `stats` and `zigai.online_eval.dropped` expose
    backpressure, allocation, contention, closure, and processing losses.

## Persistence and comparison

Persist portable datasets and complete reports with `zigai.eval_io`:

```zig
const yaml = try zigai.eval_io.stringifyDatasetYaml(allocator, dataset);
defer allocator.free(yaml);

var loaded = try zigai.eval_io.parseDatasetYaml(allocator, yaml, registry);
defer loaded.deinit();
```

Dataset files store cases and evaluator names. Loading binds those names
through an explicit `EvaluatorRegistry`; callbacks and non-default per-case
`RunOptions` are never serialized. JSON and readable YAML report files retain
usage, evaluations, analyses, and telemetry spans.

Compare a candidate report with a baseline using `zigai.eval_compare`.
Comparisons preserve stable case/repetition order, classify evaluator and
aggregate-analysis changes, calculate signed usage deltas, and expose
`regressionFree()` for gating. `stringifyCiJson` emits deterministic,
versioned JSON with a `pass` or `fail` conclusion for CI artifacts.
