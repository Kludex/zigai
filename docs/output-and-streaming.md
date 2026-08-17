# Typed output

Define the result you want as a Zig type. ZigAI derives its strict JSON
Schema, asks the provider for matching JSON, and decodes the answer. You get
a typed value, not a string you have to parse and hope about.

## Typed runs

```zig
const Weather = struct {
    city: []const u8,
    temperature_c: f64,
};

var result = try agent.runTyped(Weather, allocator, "Weather in Madrid?");
defer result.deinit();

std.debug.print("{s}: {d} C\n", .{
    result.output.city,
    result.output.temperature_c,
});
```

The decoded value, original JSON in `result.output_json`, and message history
share one result arena. Keep them only until `result.deinit()`. Use
`runTypedWithOptions`, `runTypedStream`, or `runTypedStreamWithOptions` for
the corresponding run modes. Invalid output is returned to the model for up
to `max_output_retries` correction attempts.

## Output specifications

For hand-written schemas, configure `Agent.output` with an `OutputSpec`:

```zig
const choices = [_]zigai.OutputChoice{
    .{ .name = "answer", .schema = answer_schema },
    .{ .name = "refusal", .schema = refusal_schema },
};

const agent = zigai.Agent{
    .model = model,
    .output = .{ .native = .{ .name = "result", .choices = &choices } },
};
```

Three modes cover every provider capability level:

- `.native` sends one strict schema to a capable provider.
- `.prompted` appends a schema instruction and uses JSON-object mode when
  available, otherwise text. Prompted results are always checked locally and
  retried when invalid.
- `.tool` exposes one output tool per choice, so unions stay as small
  independent schemas and `result.output_name` identifies the selected
  branch. Scalar schemas are wrapped for provider tool contracts and
  unwrapped before returning.

Schemas, choices, and custom prompt templates are borrowed for the run;
prepared data lives in the result arena.

Local validation uses a documented, fail-closed Draft 2020-12 subset. Invalid
or unsupported schemas fail before network I/O; see the
[API reference](api.md#local-json-schema-dialect) for the exact vocabulary.

## Output functions and end strategy

A choice can attach an `OutputFunction`; it receives validated arguments and
may return a final value or a safe retry message. `Agent.end_strategy`
controls ordinary calls emitted beside output: `.early` skips them,
`.graceful` runs calls before the selected output, and `.exhaustive` runs
every call.

## Output validators

Add ordered `OutputValidator` callbacks for semantic or I/O-backed checks.
Validators can transform output, request a bounded model retry with a safe
message, and inspect dependencies, history, usage, and the selected choice.

!!! note "Validators also see streamed snapshots"
    Output functions and validators run for each useful streamed snapshot
    with `OutputRunContext.partial_output = true`, and once for the final
    candidate with it set to false. Keep side effects in the final branch.

# Streaming

Use `Agent.runStream` with an `AgentStreamSink`. Model output arrives as an
indexed part lifecycle:

- `part_start` - initial part snapshot;
- `part_delta` - text, thinking, tool, native-tool, media, speech, or
  compaction fragment;
- `part_end` - complete part;
- `usage` - provider token totals.

Agent events add function-tool calls/results, deferred work,
tool-availability changes, enqueued messages, accumulated `partial_output`
snapshots, and one `final_result`. Raw model deltas arrive before their
derived snapshot.

Partial structured JSON is repaired into a valid prefix snapshot and checked
against every assertion that cannot become valid through later bytes; final
validation still applies the complete schema. A validator retry suppresses
only that partial snapshot. `final_result` is emitted only after output
validation succeeds. Structured partial and final events include a borrowed
parsed JSON value.

Use `runUntilPauseStream` and `resumeRunStream` when approval or externally
executed tools must remain in the same event flow.

## Injecting messages into a live run

To add user work while a run is active, pass a one-run `PendingMessageQueue`
in `RunOptions`:

```zig
var pending = zigai.PendingMessageQueue.init(allocator, io);
defer pending.deinit();

try pending.enqueue(&.{.{
    .parts = &.{.{ .user_prompt = .{ .text = "Also compare Madrid." } }},
}});

var result = try agent.runStreamWithOptions(
    allocator,
    "Compare Lisbon.",
    .{ .pending_messages = &pending },
    sink,
);
defer result.deinit();
```

The queue copies each batch and applies batches FIFO between model/tool
steps. Messages accepted during a final response trigger another model step.
A pause stores them for resume; cancellation discards them. The queue closes
atomically before a final result or pause, so late submissions fail
explicitly.

# Retries and resilience

The same loop supports:

- cancellation with drained in-flight work;
- one run deadline plus optional per-request ceilings;
- bounded retries with full-jitter exponential backoff;
- numeric or HTTP-date `Retry-After`, rate limits, and provider request IDs;
- request and token budgets.

!!! warning "A stream is never retried after visible output"
    This prevents duplicated text and repeated tool actions. A fallback model
    is also never consulted after a stream exposed output.

`Agent.retry_policy` classifies rate limits, server errors, timeouts,
connections, and malformed provider responses separately. Its cumulative
delay budget defaults to 30 seconds. Backoff is optional and requires `io`;
server-directed delays are not jittered. `RunOptions.request_id` is forwarded
by OpenAI-style providers for tracing. OpenAI-compatible gateways can name an
`idempotency_header`; ZigAI then generates one key per logical request and
reuses it for that request's retries.

Provider error observers receive parsed, bounded messages and correlation
metadata. Raw response bodies are hidden by default. Enable
`provider_error_policy.capture_body` with an explicit `max_body_bytes` only
when an application needs bounded provider diagnostics.

## Bounded transport

HTTP response allocations are bounded after decompression. The defaults
accept up to 16 MiB for a buffered body and 1 MiB for one streaming line. Use
tighter limits for a specific deployment:

```zig
var http = zigai.transport.HttpTransport.initWithLimits(init.gpa, init.io, .{
    .max_response_body_bytes = 2 * 1024 * 1024,
    .max_stream_line_bytes = 256 * 1024,
});
defer http.deinit();
```

Oversized input returns `error.ResponseTooLarge` or
`error.StreamLineTooLarge` before it can grow the response allocation
further.

Untrusted JSON is also preflighted before decoding. History, deferred state,
provider responses, tools, MCP, schemas, and CLI manifests each use a
reviewed `zigai.json.Limits` profile for document size, value size, nesting,
and collection length.
