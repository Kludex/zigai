# Production guide

How to run ZigAI agents in long-lived services: process shape, memory
ownership, thread safety, cancellation, retries, security, telemetry,
persistence, testing, and incident debugging. Each section states the
production rule and links the reference that defines the mechanism.

## Web services

Give every request its own arena and its own run. `Agent`, provider clients,
and the HTTP transport are configuration plus connection reuse; the per-request
state lives in the `Result` you get back.

```zig
const std = @import("std");
const zigai = @import("zigai");

const Service = struct {
    http: zigai.transport.HttpTransport,
    agent: zigai.Agent,

    fn handle(self: *Service, gpa: std.mem.Allocator, prompt: []const u8) ![]u8 {
        var result = try self.agent.run(gpa, prompt);
        defer result.deinit();
        return gpa.dupe(u8, result.output);
    }
};
```

Rules that keep a service healthy:

- Set `Agent.run_timeout_ms` on every service agent so one stuck provider
  cannot hold a worker forever. Set `Agent.request_timeout_ms` below it so
  each retry attempt gets a bounded slice. See
  [run deadlines](api.md#run-deadlines-and-cancellation).
- Set `Agent.context_budget` so oversized conversations fail in your process
  with a clear error instead of failing at the provider. See
  [context budgets](api.md#context-budgets).
- Keep `HttpTransport` limits at their bounded defaults (16 MiB buffered,
  1 MiB per stream line) unless a measured workload needs more.
- Copy `result.output` out before `deinit` if the response outlives the
  handler frame; the result owns its complete graph.
- Pass `RunOptions.correlation` with your request ID so logs, telemetry, and
  provider requests share one identity.

## Long-running workers

Workers that consume a queue should treat each job as one run with one arena,
and should prefer durable execution when a job spans process restarts:

- For at-most-once side effects across restarts, route runs through the
  durable runtime and a workflow engine adapter. Replay never re-executes
  providers or tools; it replays recorded operation results. See
  [durable execution](durable-execution.md).
- For resumable approval flows, persist the `PausedRun` payload and resume in
  a later process. A resumed run starts a fresh deadline because monotonic
  timestamps do not survive restarts.
- Drain in-flight work on shutdown: cancel the run token, wait for the public
  call to return, then flush telemetry exporters. Every public call drains its
  tasks before returning, so returning is the completion signal.

## Memory ownership

The single rule: **a returned type with `deinit` owns its complete result
graph**. The full table is in [ownership](api.md#ownership). In production
this means:

- One arena per request or job, released as one unit, is the intended shape
  for direct `Model.request`/`Model.stream` use. `Agent` calls already give
  you that boundary through `Result.deinit`.
- Callback and event data is borrowed for the duration of the callback unless
  documented otherwise. Copy inside the callback or lose the data.
- Never let a borrowed slice from a result, event, or observer escape into a
  queue, cache, or log buffer without duplication.
- Run allocation-failure tests (`std.testing.checkAllAllocationFailures`) on
  any composition you write around ZigAI; the library's own suites hold that
  bar and your glue code should too.

## Thread safety

ZigAI does not add hidden locks. The contracts are explicit:

- One `Agent` value may serve concurrent runs only if everything it references
  (tools, hooks, sinks, exporters, price table) is immutable or thread-safe.
- Graph fan-out and eval concurrency document their callback thread-safety
  requirements at the API; a callback that mutates shared state needs its own
  synchronization. See [typed graphs](api.md#typed-graphs) and
  [evaluations](api.md#evaluations).
- Realtime sessions are single-threaded by design: one session per concurrent
  conversation.
- `PendingMessageQueue` is the one intentionally thread-safe primitive for
  injecting messages into a live run.

## Cancellation and deadlines

Cancellation is cooperative and drained. The run control covers model
requests, retry waits, tools, MCP, hooks, and stream sinks; official
transports apply the remaining budget to DNS, connect, write, read, and stream
consumption. Terminal errors are `RunTimedOut` and `Cancelled`.

Production rules:

- Always provide `Agent.io`. Without a runtime, deadlines cannot be enforced
  preemptively and cancellation only takes effect at cooperative checkpoints.
- Treat `RunControlConcurrencyUnavailable` as a capacity signal: the runtime
  could not schedule a deadline watcher. Raise the runtime's concurrency
  limit rather than retrying blindly.
- Nested work inside tools should honor `ToolRunContext.deadline` so the
  whole tree respects one budget.

## Retries

Retry classification, full-jitter backoff, `Retry-After` handling, retry
budgets, and request-ID correlation are described in
[retry policy](api.md#retry-policy). In production:

- Bound cumulative backoff with `max_total_delay_ms`; an unbounded retry loop
  plus a queue is an outage amplifier.
- Log the provider request ID from the before-retry hook; it is the value the
  provider's support team can search for.
- Only gateways with a documented idempotency header get
  `Client.idempotency_header`. Do not invent one for a provider that does not
  claim it.

## Tool security

Tools are trusted code operating on untrusted arguments. The boundary rules
live in [security](security.md#trust-boundaries):

- Validate and authorize side effects inside the tool; schema validation
  proves shape, not authority.
- Set per-tool timeouts, result-size caps, and concurrency limits through the
  tool execution policy. See [tool execution limits](api.md#tool-execution-limits).
- Use approval gates (paused runs or dynamic approval hooks) for any tool
  whose side effect is expensive or irreversible.
- Execution environments give filesystem/shell tools explicit roots, command
  allowlists, network policy, and output caps. Never hand a tool an
  unrestricted shell. See [execution environments](api.md#execution-environments).

## MCP security

Treat every MCP server as an untrusted peer, even one you deploy:

- Prefer exact host allowlists in `UrlPolicy` for Streamable HTTP servers.
- Enable authorization for any non-loopback HTTP server and keep
  `DeploymentPolicy` origin checks on. See
  [MCP HTTP authorization](security.md#mcp-http-authorization).
- Review discovered tool descriptions before granting authority; a hostile
  server can describe a benign-sounding tool that exfiltrates context.
- Keep stdio servers' stderr policy explicit and bounded so a misbehaving
  child cannot fill your disk or block shutdown.

## Telemetry and redaction

- Prompt and tool content capture is disabled by default; enabling it makes
  every exporter a trusted sink. Configure redaction of known sensitive
  values before enabling capture.
- Attribute counts and value sizes are bounded before delivery, so telemetry
  cannot amplify a large response into a larger export.
- Exporter buffering has explicit backpressure and dropped-signal metrics;
  alert on drops instead of letting them silently hide traffic.
- `Header.redactedValue()` is the only way header values should reach logs.

## Persistence and migrations

Persisted history, paused runs, graph snapshots, eval datasets, and durable
records are versioned, bounded formats. The guarantees are queryable at
runtime:

```zig
const guarantee = zigai.compatibility.migrationGuarantee("history").?;
```

- Readers reject future versions; built-in migrations are deterministic. Plan
  a rollback window: a new writer version means old processes cannot read new
  rows until upgraded.
- Store persisted state with the same access control as the conversation it
  contains; ZigAI bounds parsing but does not encrypt at rest.
- Never persist API keys; the library keeps them out of history, paused
  state, and cassettes by construction, and your storage layer should not
  reintroduce them.

See [compatibility](compatibility.md) for the migration policy and
[durable execution](durable-execution.md) for durable record versioning.

## Testing production compositions

- Record real provider traffic into cassettes and replay it in CI; never
  hand-mock a provider response. See [testing](testing.md).
- Test failure injection at the boundary: failing transports, timed-out
  tools, cancelled runs, and allocation failures, not just happy paths.
- Run soak/stress suites for long tool loops and reconnects before shipping a
  new provider or transport configuration.
- Keep live-key suites out of ordinary CI; replay must be deterministic and
  offline.

## Incident debugging

When a production run misbehaves, in order:

1. Find the run by `zigai.run.id` (your `RunOptions.correlation` value) in
   traces and logs.
2. Check the terminal error name against the [error reference](errors.md);
   every discriminable failure has a stable named error.
3. For provider failures, pull the bounded provider request ID and, if body
   capture was enabled, the bounded error body. Escalate the request ID to
   the provider.
4. For hangs, confirm `Agent.io` was set and inspect the deadline
   configuration; a missing runtime downgrades deadlines to cooperative.
5. For memory growth, audit copies of borrowed callback data and confirm
   every `deinit` runs on error paths (`errdefer`).
6. Reproduce with a cassette: record the failing interaction shape once, then
   iterate offline.
