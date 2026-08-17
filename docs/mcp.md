# MCP

An MCP server is a normal toolset. You connect a client to a transport, and
its tools join the agent like any other tool. ZigAI implements MCP
`2026-07-28`: requests are stateless and self-describing; there is no
initialize handshake or protocol session.

## Streamable HTTP

```zig
var mcp_http = zigai.mcp.StreamableHttpTransport.init(
    init.io,
    http.transport(),
    "https://example.com/mcp",
);
var mcp_client = zigai.mcp.Client{ .transport = mcp_http.transport() };
const remote_tools = mcp_client.toolset();

const agent = zigai.Agent{
    .model = model,
    .toolsets = &.{remote_tools},
    .io = init.io,
};
```

Streamable HTTP admits up to 64 requests at once. Set
`StreamableHttpOptions.max_in_flight` with `initWithOptions` to match the
upstream server's capacity; excess requests wait at the transport boundary.
Request-scoped SSE uses bounded, standard multi-line `data:` framing. Event
callbacks run as each complete event arrives; the final correlated response
is returned normally. Event IDs and retry hints are ignored because MCP
2026-07-28 has no session resume. HTTP transports without line streaming fall
back to the same bounded buffered parser.

## Stdio

For a local server, start it over stdio and use the same client:

```zig
var stdio = try zigai.mcp.StdioTransport.init(
    init.io,
    &.{ "my-mcp-server", "--config", "server.json" },
);
defer stdio.deinit();

var mcp_client = zigai.mcp.Client{ .transport = stdio.transport() };
```

Use `initWithOptions` to discard child diagnostics, change the graceful
shutdown window, or tighten the pending-request bound. Stdio is serialized;
calls beyond that bound fail with `McpStdioBackpressure` instead of growing
an unbounded queue. Closing the transport closes stdin first, then
force-kills and reaps a child that does not exit within the grace period.

## Client capabilities

Optional client behavior must be advertised on every request. Build the
standard fields with `ClientCapabilities`; the returned JSON is owned by the
caller and stays borrowed by the client:

```zig
const capabilities_json = try (zigai.mcp.ClientCapabilities{
    .roots = true,
    .sampling = .{ .context = true, .tools = true },
    .elicitation = .{ .form = true },
}).stringifyAlloc(allocator);
defer allocator.free(capabilities_json);

mcp_client.capabilities_json = capabilities_json;
```

The raw `capabilities_json` field remains the forward-compatible escape
hatch. Multi-round-trip input that was not advertised is rejected.
`max_round_trips` and `max_pages` bound retries and tool discovery.

## Requests, subscriptions, and input

The client handles discovery, every core request, pagination, SSE
subscriptions, cancellation, and multi-round-trip sampling, roots, and
elicitation through an `InputHandler`. Its borrowed `InputRequest` carries a
typed kind, key, and validated request JSON, so handlers do not dispatch on
method strings. `InputResponse` builds validated elicitation, roots, or
sampling JSON while preserving the callback's explicit caller-owned byte
lifetime. Tool arguments marked with `x-mcp-header` are mirrored for
Streamable HTTP.

The typed helpers cover tools, prompts, resources, completion, discovery,
and subscriptions; `SubscriptionFilter` selects list and resource updates
without hand-written JSON, while `PromptRequest` and `CompletionRequest`
model their standardized parameters. Cancellation accepts the protocol's
integer-or-string `RequestId`; `RequestOptions.metadata` adds a progress
token and per-request logging opt-in.

`listenWithRecovery` can reissue a fresh stateless subscription after a
classified transport interruption. Its retry count, delay, deadline, and
cancellation are explicit; event callbacks may observe duplicates across
attempts.

## Tasks

Tasks have typed helpers; capability negotiation and the `Mcp-Name` task
route are applied automatically:

```zig
var task = try mcp_client.getTask(allocator, "task-1");
defer task.deinit();

try mcp_client.updateTask(allocator, .{
    .task_id = "task-1",
    .input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
});
try mcp_client.cancelTask(allocator, "task-1");

var terminal = try mcp_client.waitTask(allocator, "task-1", .{ .io = io });
defer terminal.deinit();
```

Task results own a single arena. `waitTask` follows server polling hints,
handles input, and cooperatively cancels when its deadline or poll budget
ends. Task subscriptions use `SubscriptionFilter.task_ids` and
`mcp.tasks.parseNotification`.

### Durable tasks

Add a store when tasks must survive a process restart:

```zig
var task_file = zigai.mcp.task_store.FileStore.init(
    io,
    std.Io.Dir.cwd(),
    ".zigai/mcp-tasks.json",
);
mcp_client.task_store = task_file.store();

var resumed = try mcp_client.resumeTasks(allocator, .{ .io = io });
defer resumed.deinit();
```

Tool-created tasks are tracked automatically. Pending input is saved before
it is sent, so recovery replays the response instead of asking twice. The
file is atomically replaced and owner-only on POSIX; use a custom
`task_store.Store` when responses need encrypted storage. If initial
persistence fails, ZigAI attempts to cancel the newly created remote task.

## Extensions

Extension settings stay as owned JSON:

```zig
const settings = try zigai.mcp.extensionSettings(
    allocator,
    capabilities_json,
    "io.modelcontextprotocol/tasks",
);
defer if (settings) |json| allocator.free(json);
```

## Servers

`zigai.mcp.Server` provides the matching transport-neutral server dispatcher,
automatic `server/discover`, protocol and HTTP header validation, extension
dispatch, result metadata, and a stdio serving loop. HTTP hosts pass their
request headers and TLS state to `Server.handle`.

Protected endpoints use `mcp.auth.ClientPolicy` and `mcp.auth.ServerPolicy`;
browser-facing hosts add a separate `mcp.auth.DeploymentPolicy` for exact
Origin and Host checks. Bearer tokens never enter MCP JSON or handler
parameters, and refresh/step-up retries are bounded. Core handlers run only
when the matching capability appears in the server's `capabilities_json`.
`mcp.Notification` produces validated, caller-owned JSON-RPC for server
progress, cancellation, logging, updates, and subscription acknowledgements.

See the [MCP conformance matrix](mcp-conformance.md) for message coverage,
compatibility boundaries, validation, and ownership. The
[security guide](security.md#mcp-http-authorization) covers OAuth discovery,
token callbacks, response headers, and deployment.
