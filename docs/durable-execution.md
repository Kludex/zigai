# Durable execution

Durable execution is an orchestration boundary, not an alternate agent loop.
The application owns its workflow and worker lifecycle. ZigAI describes every
side-effecting unit with a stable, versioned invocation; a runtime adapter
persists and dispatches those units through its workflow engine.

This follows the same modern shape used by PydanticAI: model requests, model
streams, tool calls, MCP requests, event delivery, retry delays, and approval
resumption are a closed operation vocabulary. A runtime selects a
worker-registered handler by ID. Zig callbacks are never treated as serialized
workflow payloads.

## Stable invocation contract

`zigai.durable.Invocation` contains:

- a stable run ID and step ID;
- a monotonic sequence number within the run;
- one `OperationKind`;
- a worker-registered handler ID; and
- one complete JSON input document.

Retries must reuse all six values unchanged. `stableKey()` produces the
unambiguous `run/step/sequence` idempotency key. A SHA-256 digest binds that key
to the exact input bytes, so accidentally reusing a key with changed input is a
hard error rather than an unsafe replay.

```zig
const invocation = zigai.DurableInvocation{
    .run_id = "support-0192",
    .step_id = "model.request",
    .sequence = 4,
    .kind = .model_request,
    .handler_id = "support-agent",
    .input_json = "{\"prompt\":\"Where is my order?\"}",
};
try invocation.validate(allocator);
```

## Persisted records

`zigai.durable.Record` stores the invocation, its input digest, and exactly one
outcome:

- `success` contains a complete JSON output document;
- `failure` contains a stable error name and retryability decision; or
- `suspended` contains a reason and versioned JSON state for approval,
  external-tool, or provider-resume workflows.

`stringifyRecord()` emits stable JSON. `parseRecord()` rejects unknown fields,
unsupported versions, invalid payloads, ambiguous outcome fields, and input
digest drift. Parsed records are arena-owned and released with
`OwnedRecord.deinit()`.

## Runtime responsibilities

`zigai.DurableRuntime` is deliberately small. An adapter must:

1. deduplicate the complete invocation identity;
2. reject a matching key with different input bytes;
3. dispatch `handler_id` from worker registration;
4. persist the terminal record before acknowledging completion; and
5. return the persisted record on replay.

Workflow engines may execute an activity more than once around a worker crash.
Application-owned external side effects therefore still need an idempotency
key or an engine transaction. ZigAI's contract makes that key stable but does
not claim exactly-once semantics for an arbitrary remote system.

## Agent model routing

`RunOptions.durable` accepts an immutable `zigai.DurableBinding`. A binding
combines one run ID, runtime, and explicit worker registration IDs. Sequence
numbers are derived from deterministic agent-loop state rather than a mutable
global counter, so a replay uses the same identity even when another run is
executing concurrently.

```zig
const binding = zigai.DurableBinding{
    .runtime = workflow_runtime,
    .run_id = "support-0192",
    .handlers = .{
        .model_request = "support-model-request",
        .model_stream = "support-model-stream",
    },
};

var result = try support_agent.runWithOptions(allocator, "Where is my order?", .{
    .durable = binding,
});
defer result.deinit();
```

Buffered calls use the `model.request` step ID and streaming calls use
`model.stream`; the model-request number is their sequence. The worker receives
a versioned neutral JSON request from `zigai.durable.payloads.model`. It returns
a successful model response encoded with `stringifyResponse`. Replayed streams emit normalized
complete-part start/delta/end events followed by usage. Provider chunk
boundaries are normalized; application delivery progress belongs to the
checkpoint layer below.

The model wire document includes all declarative request fields. It excludes
process-local error observers and cancellation pointers; a registered worker
attaches its own controls. Because durable inputs are persisted, applications
must use workflow-engine encryption and avoid request-scoped secret headers or
authorization values in durable payloads.

Runs without `RunOptions.durable` retain the direct provider path. A configured
route never falls back to that path: missing handlers, persisted failures, and
suspensions are explicit errors.

## Tool routing

Application tools use `tool.call`; tools discovered from `mcp.Client.toolset()`
carry the typed `ToolOrigin.mcp` marker and use `mcp.request`. The model-visible
function-tool protocol stays identical. The runtime worker receives a
`zigai.durable.payloads.tool` request containing the call, policy-transformed
arguments, replay-safe run context, retry number, and approval state. It
returns encoded `ToolOutput`, including follow-up request messages.

Every call receives its sequence from its source position in the model
response before concurrent work is scheduled. Completion order therefore
cannot alter idempotency keys. Approved paused calls persist that sequence in
the paused state so later execution keeps the original identity.

Tool argument, call, and return policies still execute in the agent process and
must be deterministic. The durable runtime owns the actual application or MCP
tool side effect; a configured route never invokes the local tool callback.

`ToolOrigin.workflow` is reserved for deterministic orchestration that must run
inside workflow code. It bypasses durable tool workers and may be replayed, so
it must not perform network, filesystem, clock, random, or other external side
effects. ZigAI marks its internal `load_capability` tool with this origin; once
a capability loads, its application and MCP tools are preflighted before the
next model request.

## Standalone MCP requests

`mcp.RequestOptions.durable` accepts an explicit `mcp.DurableRequest` identity.
This is the concurrency-safe form: assign each identity from deterministic
workflow state before scheduling requests. A `mcp.DurableRequestSequence` can
instead be attached to `Client.durable_requests` for sequential workflow
branches, which lets typed helpers such as `discover`, paginated collection
methods, and task polling claim identities automatically.

```zig
var identities = zigai.mcp.DurableRequestSequence.init(binding, 100);
var mcp_client = zigai.mcp.Client{
    .transport = worker_local_transport,
    .durable_requests = &identities,
};

const discovery = try mcp_client.discover(allocator);
defer allocator.free(discovery);
```

One identity represents the complete high-level operation, including bounded
MRTR input round trips performed by the registered worker. The versioned
`zigai.durable.payloads.mcp` request carries the method, parameters, routing
metadata, public headers, client identity, capabilities, and round-trip bound.
It never carries transport credentials, input handlers, event sinks, or other
process-local pointers. Sensitive per-request headers are rejected; configure
authorization on the worker's transport.

Durable subscriptions use `listenDurable` or `listenJsonDurable`. Their worker
returns a bounded event batch with the final result. ZigAI validates every MCP
notification and routes it through a distinct `event_delivery` invocation whose
identity contains the parent request sequence and event index. The runtime
deduplicates each delivery independently, so retrying after event 2 fails does
not redeliver event 1. The event worker reconstructs
`zigai.durable.payloads.event`; no process-local `EventSink` is invoked.

The event handler is preflighted before the MCP request runs. Ordinary event
sinks on durable requests and durable event delivery on direct requests are
both rejected rather than silently changing semantics.

## Retry timers and paused decisions

When backoff is enabled, durable runs derive full jitter from the stable run ID,
retry number, and failed model-request number. Replaying the workflow therefore
reconstructs the same `retry_delay` input instead of drawing fresh entropy. The
timer worker receives `zigai.durable.payloads.retry`, including the chosen
delay, cumulative delay, stable error name, and bounded provider retry metadata.
The agent process never sleeps on this path.

Approval and external-result resumptions retain the original tool-call
sequence. Before executing or accepting a resumed call, ZigAI routes the
proposed decision through `approval_resume`. The worker receives the call,
policy-transformed arguments, execution kind, and proposed decision through
`zigai.durable.payloads.approval`; its persisted response is the decision the
agent applies. Missing timer and approval handlers are rejected before their
associated model or resumed-tool side effects.

## Handler preflight

Durable agent runs validate the buffered or streaming model handler, retry
timer, and every application/MCP tool family before emitting `run_start` or
calling a provider. Dynamic `Toolset` values declare their possible origins in
`durable_origins`; MCP toolsets declare `.mcp` automatically. Prepared tools are
checked again before each model request, including after capability changes.
Missing registrations fail as `Agent.Error.MissingDurableHandler`, while a
dynamic toolset without a declaration fails as
`Agent.Error.MissingDurableToolsetOrigins`.

Runs without a durable binding do not execute this preflight and retain the
ordinary provider, timer, callback, and tool paths.

## Application events and observers

`zigai.durable.deliverEvent` sends an application JSON event through the
registered `event_delivery` worker using the caller's semantic step and
deterministic sequence. Runtime replay returns the persisted record instead of
repeating the worker side effect.

Agent lifecycle hooks are intentionally not serialized business events. They
remain process-local observers for telemetry, diagnostics, and online
evaluation and may observe workflow replay. Applications that require durable
delivery must call `deliverEvent` rather than putting a business side effect in
a lifecycle hook.

## Restart checkpoints

Operation records prevent a model or tool side effect from running twice.
Checkpoints record how far application code has consumed that replay.

`zigai.durable.checkpoint.Store` loads, atomically saves, and removes records by
run ID and checkpoint ID. Revisions only move forward. Repeating an identical
write is safe; a stale revision or a changed payload at the same revision is an
error. `FileStore` is the bounded, owner-only reference implementation. Its
version-2 JSON snapshot loads version 1 and rewrites version 2 on the next save.

For streams, initialize `zigai.CheckpointedStreamSink` with a stable segment ID
and pass `sink()` to the agent. A restarted worker uses the same ID and skips
committed event ordinals. Start a new segment after an approval resume or an
incompatible event-order change.

```zig
var stream = try zigai.CheckpointedStreamSink.init(
    allocator,
    checkpoint_store,
    binding.run_id,
    "initial-stream-v1",
    application_sink,
);
var result = try agent.runStreamWithOptions(
    allocator,
    prompt,
    .{ .durable = binding },
    stream.sink(),
);
defer result.deinit();
```

The cursor is committed after the sink succeeds. A crash between those actions
may redeliver the last event, which is the at-least-once contract for a
process-local observer. Route business events through `durable.deliverEvent`
when workflow deduplication is required.

For approvals, call `PausedRun.saveCheckpoint`. A restarted process can call
`Agent.resumeCheckpoint` or `resumeCheckpointStream`; it does not need the
original in-memory `PausedRun`. The saved revision derives from the model
request number, so duplicate persistence is idempotent and divergent replay
fails closed.

## Temporal adapter

`zigai.durable_adapters.temporal` is the first concrete engine adapter. Temporal
does not publish a Zig SDK, so the adapter calls the included sidecar over HTTP;
the sidecar uses Temporal's official Python SDK. The Zig package still has no
runtime dependency on Python or Temporal.

```zig
const temporal = zigai.durable_adapters.temporal;

var adapter = try temporal.Adapter.init(allocator, http_transport, .{
    .endpoint = "https://temporal-sidecar.internal",
    .namespace = "production",
    .task_queue = "zigai-agents-v1",
    .registrations = &.{
        .{ .kind = .model_request, .handler_id = "support-model" },
        .{ .kind = .model_stream, .handler_id = "support-stream" },
        .{ .kind = .tool_call, .handler_id = "support-tools" },
    },
    .bearer_token = "Bearer worker-secret",
    .retry = .{
        .initial_interval_ms = 1_000,
        .maximum_interval_ms = 30_000,
        .maximum_attempts = 5,
    },
});

const binding = zigai.DurableBinding{
    .runtime = adapter.runtime(),
    .run_id = "support-0192",
    .handlers = .{
        .model_request = "support-model",
        .model_stream = "support-stream",
        .tool_call = "support-tools",
    },
};
```

The adapter preflights its registration table before network I/O. It sends the
sidecar token as a sensitive HTTP header, never as workflow input. Its versioned
request includes the stable workflow ID, invocation, task queue, activity
timeouts, and retry policy. The default persisted input limit is 1 MiB; the
complete gateway request is capped at 2 MiB and the returned record at 8 MiB.

The sidecar registers `zigai.operation.v1` and `zigai.execute.v1`. Each activity
dispatches a configured `(kind, handler_id)` command, writes the invocation to
its standard input, and reads a complete durable record from standard output.
Duplicate workflow starts attach to the existing workflow and return its stored
result. ZigAI then verifies that the returned invocation and input digest match,
so reusing an identity with different input fails closed.

Keep the sidecar on a private network or require
`ZIGAI_TEMPORAL_SIDECAR_TOKEN`. Deploy it with the command workers, keep an old
worker build polling until its workflows drain, and use a new handler ID or task
queue for incompatible behavior. The reference deployment lives in
[`integrations/temporal`](../integrations/temporal/).
