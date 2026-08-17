# Workflows and multi-agent

Graphs are explicit. Define the state, dependencies, input, intermediate
value, and output types once, then register named steps and decisions. The
compiler checks your workflow's types; the builder checks its routes.

## Typed graphs

```zig
const Workflow = zigai.graph.Graph(State, Deps, u64, u64, u64);

var builder: Workflow.Builder = .{};
defer builder.deinit(allocator);

try builder.setStart(.{ .run_fn = start });
try builder.setEnd(.{ .run_fn = end });
const prepare = try builder.addStep(allocator, .{
    .name = "prepare",
    .run_fn = prepareStep,
});
try builder.setEntry(prepare);
try builder.finish(allocator, prepare);

var workflow = try builder.build(allocator);
defer workflow.deinit(allocator);

const output = try workflow.run(allocator, &state, &deps, input, .{});
```

Use `workflow.iter(...)` to inspect and advance one step at a time.
Definitions reject incomplete or unreachable routes before execution. A
decision returns a typed value and one borrowed branch name registered with
`builder.branch(...)` or `builder.branchFinish(...)`; an unknown name fails
with `UnmatchedRoute`. Callback contexts, node and branch names, state, and
dependencies are borrowed; the built workflow owns only its node and routing
arrays.

## Fan-out and joins

`addFanOut(...)` adds a bounded map or broadcast fork with named branch
callbacks and a typed join. Set `RunOptions.max_concurrency` above one and
pass `std.Io` to execute branches concurrently; reduction always follows
source order. Shared state, dependencies, branch contexts, and returned
values must be safe for that concurrency level.

## Snapshots

Graph persistence is opt-in. Give the builder a stable `definition_id`,
encode typed state and frontier values with a `SnapshotCodec`, then call
`run.snapshot(...)` and `graph.resumeSnapshot(...)` between node advances.
Snapshots are bounded and fingerprinted; they never serialize dependencies,
callbacks, or in-flight parallel work.

## Visualization

Nodes and edges accept optional borrowed labels, descriptions, groups, and
source locations. `graph.visualization(allocator)` returns a versioned,
deterministic node/edge view for documentation and tooling;
`graph.renderMermaid(allocator, options)` returns a bounded Mermaid state
diagram with stable generated IDs.

## Agent nodes

Agent work remains an explicit adapter rather than a special graph mode.
`zigai.graph_agent.BufferedNode(Workflow)` prepares a prompt and per-run
agent options, then adapts the owned `Agent.Result` back into the graph's
`Value`. `TypedNode(Workflow, Output)` does the same with
`Agent.runTypedWithOptions`. Both inject the graph dependencies when the
prepared options do not override them.

Set `stream_sink` to receive borrowed agent events before the graph
transition commits. `Control` propagates a node cancellation token and a
run-wide deadline through model, tool, and callback work.

`Correlation` adds the graph run ID, node ID, and node name to agent hooks
and OpenTelemetry. Durable bindings receive a deterministic node namespace,
so two agent nodes cannot reuse one operation identity during replay.
`graph_agent.Conversation` deep-copies canonical messages and cumulative
usage for state that must survive the agent result's `deinit` boundary.

# Multi-agent

`zigai.multi_agent.Session` bounds one multi-agent execution tree and owns
its cumulative usage. A borrowed `Scope` runs explicit `delegate`, `handoff`,
or `subagent` transitions with shared or isolated dependencies and history.
The scope propagates cancellation, one absolute deadline, trace parents, and
stable run correlation. Depth, run, request, tool, token, and cost limits
prevent recursive or unexpectedly expensive trees.

# Durable execution

Durable operations, restart-safe checkpoints, and a Temporal adapter let a
run survive worker restarts without repeating side effects. Replay never
re-executes providers or tools; it replays recorded operation results. See
[durable execution](durable-execution.md) for the operation vocabulary,
record format, and adapter contract.

# Embeddings

`zigai.embeddings.Embedder` accepts query or document text through one
provider-neutral model vtable. It validates byte and dimension limits before
I/O, splits source-ordered batches, propagates cancellation and one deadline,
and applies bounded full-jitter retries. The result owns copied inputs,
vectors, model identity, and aggregate usage in one arena.

`embeddings.openai.Client` uses any OpenAI-compatible provider;
`embeddings.google.Client` uses Gemini `batchEmbedContents`.
`examples/retrieval.zig` demonstrates a complete local query/document ranking
loop.

# Realtime voice

`zigai.realtime.Session` owns a persistent provider-neutral voice session
over an explicit WebSocket or WebRTC-sideband connection. It accepts PCM16
audio, text, images, manual turn controls, and interruptions; emits owned
audio, transcript, tool, turn, reconnect, and error events; and builds
canonical message history with bounded audio retention and cumulative usage.
Protocol connectors cover OpenAI Realtime, Azure OpenAI, xAI Grok Voice, and
Gemini Live without coupling the core session to provider JSON or
credentials.

# UI protocols

`zigai.ui.Bridge` converts agent stream events into one bounded UI
vocabulary. `ui.ag_ui` emits AG-UI JSON and interrupt resumes; `ui.vercel`
emits AI SDK UI message stream v1 SSE and approval responses. Typed custom
data, strict browser message sanitization, and a bounded replay log support
safe reconnecting clients. See `examples/ui_server.zig` and
`examples/ui_browser.ts`.

# Agent Client Protocol

`zigai.acp.Client` implements Agent Client Protocol v2 sessions plus v1
filesystem/terminal compatibility. It owns initialization, capability
negotiation, session create/resume/list/delete/close, prompts, streamed
updates, permission replies, cancellation, reconnect, rooted files, terminal
handlers, and bounded stdio process framing.
