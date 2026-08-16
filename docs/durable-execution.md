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
`model.stream`; the model-request number is their sequence. The worker receives a versioned neutral JSON
request from `zigai.durable.payloads.model`. It returns a successful model
response encoded with `stringifyResponse`. Replayed streams emit normalized
complete-part start/delta/end events followed by usage; preserving original
chunk boundaries and partially completed streams belongs to the later stream
checkpointing layer.

The model wire document includes all declarative request fields. It excludes
process-local error observers and cancellation pointers; a registered worker
attaches its own controls. Because durable inputs are persisted, applications
must use workflow-engine encryption and avoid request-scoped secret headers or
authorization values in durable payloads.

Runs without `RunOptions.durable` retain the direct provider path. A configured
route never falls back to that path: missing handlers, persisted failures, and
suspensions are explicit errors.

Local-tool, MCP, event, retry-delay, and approval routing, a concrete workflow-
engine adapter, durable stream/approval resumption, and worker-restart recovery
tests remain tracked in `TODO.local.md`.
