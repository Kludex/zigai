//! Model Context Protocol 2026-07-28 client, server, and transports.
//!
//! The latest MCP revision is stateless: every request carries its protocol
//! version, client identity, and capabilities. The generic request/handler
//! APIs intentionally preserve unknown fields so MCP extensions work without
//! waiting for a ZigAI release.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");
const model = @import("model.zig");
const http = @import("transport.zig");
const json_limits = @import("json.zig");
const security = @import("security.zig");

/// Latest stable MCP protocol revision supported by ZigAI.
pub const protocol_version = "2026-07-28";

/// JSON-RPC and MCP error codes defined by the current specification.
pub const error_codes = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const header_mismatch = -32020;
    pub const missing_required_client_capability = -32021;
    pub const unsupported_protocol_version = -32022;
};

/// Core MCP methods. Extension methods can be passed to `Client.request`.
pub const methods = struct {
    pub const discover = "server/discover";
    pub const complete = "completion/complete";
    pub const create_message = "sampling/createMessage";
    pub const elicit = "elicitation/create";
    pub const get_prompt = "prompts/get";
    pub const list_roots = "roots/list";
    pub const list_prompts = "prompts/list";
    pub const list_resources = "resources/list";
    pub const list_resource_templates = "resources/templates/list";
    pub const read_resource = "resources/read";
    pub const listen = "subscriptions/listen";
    pub const call_tool = "tools/call";
    pub const list_tools = "tools/list";
    pub const cancelled = "notifications/cancelled";
    pub const logging_message = "notifications/message";
    pub const progress = "notifications/progress";
    pub const prompt_list_changed = "notifications/prompts/list_changed";
    pub const resource_list_changed = "notifications/resources/list_changed";
    pub const resource_updated = "notifications/resources/updated";
    pub const subscriptions_acknowledged = "notifications/subscriptions/acknowledged";
    pub const tool_list_changed = "notifications/tools/list_changed";
};

/// MCP protocol and transport failures defined by ZigAI.
pub const Error = error{
    /// A stdio transport was configured without a program command.
    EmptyCommand,
    /// An MCP header value does not match its schema annotation.
    HeaderMismatch,
    /// A server requested elicitation input but no handler supplied it.
    InputRequired,
    /// Tool header annotations are malformed or use unsupported schema shapes.
    InvalidMcpHeaderAnnotation,
    /// A received JSON-RPC message is malformed or exceeds structural rules.
    InvalidMcpMessage,
    /// A response result does not match the expected MCP method shape.
    InvalidMcpResponse,
    /// Tool arguments are not one valid bounded JSON object.
    InvalidMcpToolArguments,
    /// Streamable HTTP returned a non-success transport response.
    McpHttpRequestFailed,
    /// An MCP request, response, or event exceeded its configured byte limit.
    McpMessageTooLarge,
    /// A stdio MCP child closed before returning the matching response.
    McpProcessClosed,
    /// A JSON-RPC response ID differs from the outstanding request ID.
    McpResponseIdMismatch,
    /// The peer returned a JSON-RPC error envelope.
    McpRpcError,
    /// An MCP-backed toolset was used without its client.
    MissingMcpClient,
    /// Streamable HTTP did not provide the required SSE response stream.
    MissingMcpSseResponse,
    /// Elicitation exceeded the configured request/response round-trip limit.
    TooManyMcpRoundTrips,
    /// Discovery negotiated a protocol revision ZigAI does not support.
    UnsupportedMcpProtocolVersion,
};

/// Receives JSON-RPC notifications emitted while a request is active.
pub const EventSink = struct {
    context: *anyopaque,
    eventFn: *const fn (context: *anyopaque, message_json: []const u8) anyerror!void,

    pub fn emit(self: EventSink, message_json: []const u8) !void {
        return self.eventFn(self.context, message_json);
    }
};

/// Metadata needed by MCP transports in addition to the JSON-RPC body.
pub const WireRequest = struct {
    message: []const u8,
    method: []const u8,
    expects_response: bool = true,
    routing_name: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    events: ?EventSink = null,
};

/// Pluggable MCP JSON-RPC transport. Returned response bytes are caller-owned.
pub const Transport = struct {
    context: *anyopaque,
    sendFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: WireRequest,
    ) anyerror![]const u8,

    pub fn send(self: Transport, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        return self.sendFn(self.context, allocator, request);
    }
};

/// MCP Streamable HTTP transport for the stateless 2026-07-28 protocol.
pub const StreamableHttpTransport = struct {
    io: std.Io,
    inner: http.Transport,
    endpoint: []const u8,
    headers: []const http.Header = &.{},
    url_policy: security.UrlPolicy = .{},
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, inner: http.Transport, endpoint: []const u8) StreamableHttpTransport {
        return initWithPolicy(io, inner, endpoint, .{});
    }

    /// Initializes Streamable HTTP with an explicit endpoint policy.
    pub fn initWithPolicy(
        io: std.Io,
        inner: http.Transport,
        endpoint: []const u8,
        url_policy: security.UrlPolicy,
    ) StreamableHttpTransport {
        return .{ .io = io, .inner = inner, .endpoint = endpoint, .url_policy = url_policy };
    }

    pub fn transport(self: *StreamableHttpTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        const self: *StreamableHttpTransport = @ptrCast(@alignCast(context));
        try self.url_policy.validate(self.endpoint);
        try validateMcpMessage(allocator, request.message);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json, text/event-stream" },
            .{ .name = "mcp-protocol-version", .value = protocol_version },
            .{ .name = "mcp-method", .value = request.method },
        });
        if (request.routing_name) |name| {
            try headers.append(allocator, .{ .name = "mcp-name", .value = name });
        }
        try headers.appendSlice(allocator, request.headers);
        try headers.appendSlice(allocator, self.headers);

        const response = try self.inner.send(allocator, .{
            .method = .POST,
            .url = self.endpoint,
            .headers = headers.items,
            .body = request.message,
        });
        errdefer allocator.free(response.body);
        if (request.expects_response) {
            if (response.status != 200 and response.status != 400) return error.McpHttpRequestFailed;
        } else if (response.status != 200 and response.status != 202 and response.status != 204) {
            return error.McpHttpRequestFailed;
        }
        if (!request.expects_response or response.body.len == 0) return response.body;
        if (response.body[0] == '{' or response.body[0] == '[') {
            try validateMcpResponse(allocator, response.body);
            return response.body;
        }

        const extracted = try extractSseResponse(allocator, response.body, request.message, request.events);
        allocator.free(response.body);
        return extracted;
    }
};

/// MCP stdio transport using newline-delimited JSON-RPC messages.
pub const StdioTransport = struct {
    io: std.Io,
    child: std.process.Child,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, argv: []const []const u8) !StdioTransport {
        if (argv.len == 0) return error.EmptyCommand;
        return .{
            .io = io,
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            }),
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        if (self.child.stdin) |stdin| stdin.close(self.io);
        self.child.stdin = null;
        self.child.kill(self.io);
        self.* = undefined;
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        try validateMcpMessage(allocator, request.message);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stdin = self.child.stdin orelse return error.McpProcessClosed;
        try stdin.writeStreamingAll(self.io, request.message);
        try stdin.writeStreamingAll(self.io, "\n");
        if (!request.expects_response) return allocator.alloc(u8, 0);

        const request_id = try JsonRpcId.parse(allocator, request.message);
        defer request_id.deinit(allocator);
        while (true) {
            const line = try readLine(allocator, self.io, self.child.stdout orelse return error.McpProcessClosed);
            errdefer allocator.free(line);
            const parsed = try json_limits.parse(
                std.json.Value,
                allocator,
                line,
                json_limits.defaults.mcp_message,
                .{},
                error.InvalidMcpMessage,
            );
            defer parsed.deinit();
            const object = requiredObject(parsed.value) catch {
                allocator.free(line);
                continue;
            };
            if (object.get("method") != null) {
                if (object.get("id") != null) {
                    try rejectLegacyServerRequest(self, allocator, object.get("id").?);
                } else if (request.events) |events| {
                    try events.emit(line);
                }
                allocator.free(line);
                continue;
            }
            const response_id = object.get("id") orelse {
                allocator.free(line);
                continue;
            };
            if (request_id.matches(response_id)) return line;
            allocator.free(line);
        }
    }
};

/// Handles an MRTR input request and returns a JSON result object.
pub const InputHandler = struct {
    context: *anyopaque,
    handleFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        key: []const u8,
        request_json: []const u8,
    ) anyerror![]u8,

    pub fn handle(
        self: InputHandler,
        allocator: std.mem.Allocator,
        key: []const u8,
        request_json: []const u8,
    ) ![]u8 {
        return self.handleFn(self.context, allocator, key, request_json);
    }
};

/// Options for one client request.
pub const RequestOptions = struct {
    routing_name: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    events: ?EventSink = null,
};

/// Stateless MCP client with generic extension support and ZigAI toolset adaptation.
pub const Client = struct {
    transport: Transport,
    name: []const u8 = "zigai",
    version: []const u8 = "0.1.0",
    capabilities_json: []const u8 = "{}",
    input_handler: ?InputHandler = null,
    max_round_trips: usize = 16,
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn toolset(self: *Client) agent.Toolset {
        return .{ .context = self, .prepareFn = prepareTools };
    }

    /// Sends any core or extension request and returns its owned JSON result.
    pub fn request(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        return self.requestWithOptions(allocator, method, params_json, .{});
    }

    /// Sends a request with HTTP routing headers and a notification sink.
    pub fn requestWithOptions(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        options: RequestOptions,
    ) ![]u8 {
        var current_params: []const u8 = params_json;
        var owned_params: ?[]u8 = null;
        defer if (owned_params) |value| allocator.free(value);

        var round_trip: usize = 0;
        while (round_trip < self.max_round_trips) : (round_trip += 1) {
            const result = try self.requestOnce(allocator, method, current_params, options);
            if (!isInputRequired(allocator, result)) return result;
            const retry = answerInputRequests(allocator, current_params, result, self.input_handler) catch |failure| {
                allocator.free(result);
                return failure;
            };
            allocator.free(result);
            if (owned_params) |value| allocator.free(value);
            owned_params = retry;
            current_params = retry;
        }
        return error.TooManyMcpRoundTrips;
    }

    /// Sends a client notification.
    pub fn notify(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) !void {
        const message = try buildNotification(allocator, method, params_json);
        defer allocator.free(message);
        const response = try self.transport.send(allocator, .{
            .message = message,
            .method = method,
            .expects_response = false,
        });
        allocator.free(response);
    }

    /// Discovers server versions, capabilities, and instructions.
    pub fn discover(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return self.request(allocator, methods.discover, "{}");
    }

    pub fn listTools(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_tools, cursor);
    }

    pub fn callTool(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) ![]u8 {
        return self.callToolWithSchema(allocator, name, arguments_json, null);
    }

    pub fn listResources(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_resources, cursor);
    }

    pub fn listResourceTemplates(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_resource_templates, cursor);
    }

    pub fn readResource(self: *Client, allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
        const params = try std.json.Stringify.valueAlloc(allocator, .{ .uri = uri }, .{});
        defer allocator.free(params);
        return self.requestWithOptions(allocator, methods.read_resource, params, .{ .routing_name = uri });
    }

    pub fn listPrompts(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_prompts, cursor);
    }

    pub fn getPrompt(self: *Client, allocator: std.mem.Allocator, params_json: []const u8) ![]u8 {
        const name = try parameterString(allocator, params_json, "name");
        defer allocator.free(name);
        return self.requestWithOptions(allocator, methods.get_prompt, params_json, .{ .routing_name = name });
    }

    pub fn complete(self: *Client, allocator: std.mem.Allocator, params_json: []const u8) ![]u8 {
        return self.request(allocator, methods.complete, params_json);
    }

    pub fn listen(
        self: *Client,
        allocator: std.mem.Allocator,
        filter_json: []const u8,
        events: EventSink,
    ) ![]u8 {
        const params = try std.fmt.allocPrint(allocator, "{{\"notifications\":{s}}}", .{filter_json});
        defer allocator.free(params);
        return self.requestWithOptions(allocator, methods.listen, params, .{ .events = events });
    }

    pub fn cancel(self: *Client, allocator: std.mem.Allocator, request_id: u64, reason: ?[]const u8) !void {
        const params = if (reason) |value|
            try std.json.Stringify.valueAlloc(allocator, .{ .requestId = request_id, .reason = value }, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ .requestId = request_id }, .{});
        defer allocator.free(params);
        return self.notify(allocator, methods.cancelled, params);
    }

    fn requestOnce(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        options: RequestOptions,
    ) ![]u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const message = try buildRequest(
            allocator,
            id,
            method,
            params_json,
            self.name,
            self.version,
            self.capabilities_json,
        );
        defer allocator.free(message);
        const body = try self.transport.send(allocator, .{
            .message = message,
            .method = method,
            .routing_name = options.routing_name,
            .headers = options.headers,
            .events = options.events,
        });
        defer allocator.free(body);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try responseResult(try parseResponse(arena.allocator(), body), id);
        try validateMethodResult(method, result);
        return std.json.Stringify.valueAlloc(allocator, result, .{});
    }

    fn callToolWithSchema(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
        schema_json: ?[]const u8,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arguments = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            arguments_json,
            json_limits.defaults.tool_payload,
            .{},
            error.InvalidMcpToolArguments,
        );
        if (arguments != .object) return error.InvalidMcpToolArguments;
        const params = try std.json.Stringify.valueAlloc(allocator, .{ .name = name, .arguments = arguments }, .{});
        defer allocator.free(params);
        const headers = if (schema_json) |schema|
            try toolArgumentHeaders(arena.allocator(), schema, arguments)
        else
            &.{};
        return self.requestWithOptions(allocator, methods.call_tool, params, .{
            .routing_name = name,
            .headers = headers,
        });
    }

    fn prepareTools(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: agent.ToolsetContext,
        _: []const model.Tool,
    ) ![]const agent.ToolsetEntry {
        const self: *Client = @ptrCast(@alignCast(context orelse return error.MissingMcpClient));
        var entries: std.ArrayList(agent.ToolsetEntry) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const result_json = try self.listToolsOwnedParams(allocator, cursor);
            defer allocator.free(result_json);
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const object = try requiredObject(try parseResponse(arena.allocator(), result_json));
            const tools = switch (object.get("tools") orelse return error.InvalidMcpResponse) {
                .array => |value| value,
                else => return error.InvalidMcpResponse,
            };
            for (tools.items) |tool_value| {
                const tool = try requiredObject(tool_value);
                const name = try requiredString(tool, "name");
                const description = optionalString(tool, "description") orelse "";
                const schema_value = tool.get("inputSchema") orelse return error.InvalidMcpResponse;
                if (!validToolHeaderSchema(schema_value)) continue;
                const schema = try std.json.Stringify.valueAlloc(allocator, schema_value, .{});
                const tool_context = try allocator.create(ToolContext);
                tool_context.* = .{
                    .client = self,
                    .name = try allocator.dupe(u8, name),
                    .schema_json = schema,
                };
                try entries.append(allocator, .{ .tool = .{
                    .definition = .{
                        .name = try allocator.dupe(u8, name),
                        .description = try allocator.dupe(u8, description),
                        .parameters_json_schema = try allocator.dupe(u8, schema),
                    },
                    .context = tool_context,
                    .executeFn = executeTool,
                } });
            }
            cursor = if (optionalString(object, "nextCursor")) |next|
                try allocator.dupe(u8, next)
            else
                null;
            if (cursor == null) break;
        }
        return entries.toOwnedSlice(allocator);
    }

    fn listToolsOwnedParams(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_tools, cursor);
    }

    fn paginatedRequest(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        cursor: ?[]const u8,
    ) ![]u8 {
        const params = try paginatedParams(allocator, cursor);
        defer allocator.free(params);
        return self.request(allocator, method, params);
    }
};

const ToolContext = struct {
    client: *Client,
    name: []const u8,
    schema_json: []const u8,
};

fn executeTool(context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const tool: *ToolContext = @ptrCast(@alignCast(context));
    const result_json = try tool.client.callToolWithSchema(allocator, tool.name, arguments_json, tool.schema_json);
    defer allocator.free(result_json);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return renderToolResult(allocator, try requiredObject(try parseResponse(arena.allocator(), result_json)));
}

/// HTTP metadata supplied by an MCP server host for header validation.
pub const HttpMetadata = struct {
    headers: []const http.Header,
};

/// Application handler for all core and extension MCP methods.
pub const ServerHandler = struct {
    context: *anyopaque,
    handleFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) anyerror![]u8,

    pub fn handle(
        self: ServerHandler,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        return self.handleFn(self.context, allocator, method, params_json);
    }
};

/// Optional server callback used to validate `Mcp-Param-*` tool headers.
pub const ToolSchemaProvider = struct {
    context: *anyopaque,
    schemaFn: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,

    pub fn schema(self: ToolSchemaProvider, name: []const u8) ?[]const u8 {
        return self.schemaFn(self.context, name);
    }
};

/// Result of dispatching one MCP request in an HTTP or stdio host.
pub const ServerResponse = struct {
    status: u16,
    body: ?[]u8,

    pub fn deinit(self: ServerResponse, allocator: std.mem.Allocator) void {
        if (self.body) |body| allocator.free(body);
    }
};

/// Transport-neutral MCP server dispatcher with discovery and validation.
pub const Server = struct {
    handler: ServerHandler,
    name: []const u8 = "zigai-mcp-server",
    version: []const u8 = "0.1.0",
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    capabilities_json: []const u8 = "{}",
    discovery_ttl_ms: u64 = 60_000,
    discovery_cache_scope: []const u8 = "public",
    tool_schemas: ?ToolSchemaProvider = null,

    /// Validates and dispatches one JSON-RPC message.
    pub fn handle(
        self: *Server,
        allocator: std.mem.Allocator,
        message_json: []const u8,
        metadata: ?HttpMetadata,
    ) !ServerResponse {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            message_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.errorResponse(allocator, .null, error_codes.parse_error, "Invalid JSON", 400),
        };
        const object = requiredObject(root) catch
            return self.errorResponse(allocator, .null, error_codes.invalid_request, "Invalid JSON-RPC request", 400);
        const id = object.get("id") orelse .null;
        if (!std.mem.eql(u8, optionalString(object, "jsonrpc") orelse "", "2.0")) {
            return self.errorResponse(allocator, id, error_codes.invalid_request, "Invalid JSON-RPC version", 400);
        }
        const method = optionalString(object, "method") orelse
            return self.errorResponse(allocator, id, error_codes.invalid_request, "Missing method", 400);
        const params_value = object.get("params") orelse std.json.Value{ .object = .{} };
        const params = requiredObject(params_value) catch
            return self.errorResponse(allocator, id, error_codes.invalid_params, "Params must be an object", 400);

        const is_notification = object.get("id") == null;
        if (!is_notification) {
            const meta = params.get("_meta") orelse
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Missing request metadata", 400);
            const meta_object = requiredObject(meta) catch
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Invalid request metadata", 400);
            const requested = optionalString(meta_object, "io.modelcontextprotocol/protocolVersion") orelse "";
            if (!std.mem.eql(u8, requested, protocol_version)) {
                return self.unsupportedVersionResponse(allocator, id, requested);
            }
            if (meta_object.get("io.modelcontextprotocol/clientCapabilities") == null) {
                return self.errorResponse(
                    allocator,
                    id,
                    error_codes.invalid_params,
                    "Missing client capabilities",
                    400,
                );
            }
        }
        if (metadata) |http_metadata| {
            if (!validateStandardHeaders(http_metadata.headers, method, params)) {
                return self.errorResponse(allocator, id, error_codes.header_mismatch, "MCP headers do not match", 400);
            }
            if (self.tool_schemas) |schemas| {
                if (std.mem.eql(u8, method, methods.call_tool)) {
                    const name = optionalString(params, "name") orelse "";
                    if (schemas.schema(name)) |schema| {
                        if (!try validateToolHeaders(arena.allocator(), http_metadata.headers, schema, params)) {
                            return self.errorResponse(
                                allocator,
                                id,
                                error_codes.header_mismatch,
                                "Tool parameter headers do not match",
                                400,
                            );
                        }
                    }
                }
            }
        }

        const params_json = try std.json.Stringify.valueAlloc(allocator, params_value, .{});
        defer allocator.free(params_json);
        if (is_notification) {
            const ignored = self.handler.handle(allocator, method, params_json) catch return .{ .status = 202, .body = null };
            allocator.free(ignored);
            return .{ .status = 202, .body = null };
        }
        const result_json = if (std.mem.eql(u8, method, methods.discover))
            try self.discoveryResult(allocator)
        else
            self.handler.handle(allocator, method, params_json) catch
                return self.errorResponse(allocator, id, error_codes.internal_error, "MCP handler failed", 500);
        defer allocator.free(result_json);
        const body = try self.resultResponse(allocator, id, method, result_json);
        return .{ .status = 200, .body = body };
    }

    /// Serves newline-delimited MCP requests until the input closes.
    pub fn serveStdio(
        self: *Server,
        allocator: std.mem.Allocator,
        io: std.Io,
        input: std.Io.File,
        output: std.Io.File,
    ) !void {
        while (true) {
            const line = readLine(allocator, io, input) catch |failure| switch (failure) {
                error.EndOfStream => return,
                else => return failure,
            };
            defer allocator.free(line);
            const response = try self.handle(allocator, line, null);
            defer response.deinit(allocator);
            if (response.body) |body| {
                try output.writeStreamingAll(io, body);
                try output.writeStreamingAll(io, "\n");
            }
        }
    }

    fn discoveryResult(self: *Server, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const capabilities = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            self.capabilities_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        return std.json.Stringify.valueAlloc(allocator, .{
            .resultType = "complete",
            .ttlMs = self.discovery_ttl_ms,
            .cacheScope = self.discovery_cache_scope,
            .supportedVersions = &.{protocol_version},
            .capabilities = capabilities,
            .instructions = self.instructions,
        }, .{ .emit_null_optional_fields = false });
    }

    fn resultResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        method: []const u8,
        result_json: []const u8,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var result = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            result_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpResponse,
        );
        var object = try requiredObject(result);
        const memory = arena.allocator();
        if (object.get("resultType") == null) try object.put(memory, "resultType", .{ .string = "complete" });
        try validateMethodResult(method, .{ .object = object });
        var server_info: std.json.ObjectMap = .{};
        try server_info.put(memory, "name", .{ .string = self.name });
        try server_info.put(memory, "version", .{ .string = self.version });
        if (self.description) |description| try server_info.put(memory, "description", .{ .string = description });
        var meta = if (object.get("_meta")) |existing|
            try requiredObject(existing)
        else
            std.json.ObjectMap{};
        try meta.put(memory, "io.modelcontextprotocol/serverInfo", .{ .object = server_info });
        try object.put(memory, "_meta", .{ .object = meta });
        result = .{ .object = object };
        return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
    }

    fn unsupportedVersionResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        requested: []const u8,
    ) !ServerResponse {
        _ = self;
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{
                .code = error_codes.unsupported_protocol_version,
                .message = "Unsupported MCP protocol version",
                .data = .{ .supported = &.{protocol_version}, .requested = requested },
            },
        }, .{});
        return .{ .status = 400, .body = body };
    }

    fn errorResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        code: i32,
        message: []const u8,
        status: u16,
    ) !ServerResponse {
        _ = self;
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{ .code = code, .message = message },
        }, .{});
        return .{ .status = status, .body = body };
    }
};

fn buildRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: []const u8,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var params_value = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    var params = try requiredObject(params_value);
    const capabilities = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        capabilities_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    if (capabilities != .object) return error.InvalidMcpMessage;
    const memory = arena.allocator();
    var client_info: std.json.ObjectMap = .{};
    try client_info.put(memory, "name", .{ .string = client_name });
    try client_info.put(memory, "version", .{ .string = client_version });
    var meta = if (params.get("_meta")) |existing|
        try requiredObject(existing)
    else
        std.json.ObjectMap{};
    try meta.put(memory, "io.modelcontextprotocol/protocolVersion", .{ .string = protocol_version });
    try meta.put(memory, "io.modelcontextprotocol/clientInfo", .{ .object = client_info });
    try meta.put(memory, "io.modelcontextprotocol/clientCapabilities", capabilities);
    try params.put(memory, "_meta", .{ .object = meta });
    params_value = .{ .object = params };
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params_value,
    }, .{});
}

fn buildNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const params = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    if (params != .object) return error.InvalidMcpMessage;
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = method,
        .params = params,
    }, .{});
}

fn paginatedParams(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
    return if (cursor) |value|
        std.json.Stringify.valueAlloc(allocator, .{ .cursor = value }, .{})
    else
        allocator.dupe(u8, "{}");
}

fn parameterString(allocator: std.mem.Allocator, params_json: []const u8, key: []const u8) ![]const u8 {
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    defer parsed.deinit();
    return allocator.dupe(u8, try requiredString(try requiredObject(parsed.value), key));
}

fn isInputRequired(allocator: std.mem.Allocator, result_json: []const u8) bool {
    const parsed = json_limits.parse(
        std.json.Value,
        allocator,
        result_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpResponse,
    ) catch return false;
    defer parsed.deinit();
    const object = requiredObject(parsed.value) catch return false;
    return std.mem.eql(u8, optionalString(object, "resultType") orelse "complete", "input_required");
}

fn answerInputRequests(
    allocator: std.mem.Allocator,
    params_json: []const u8,
    result_json: []const u8,
    maybe_handler: ?InputHandler,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try requiredObject(try parseResponse(arena.allocator(), result_json));
    const memory = arena.allocator();
    var responses: std.json.ObjectMap = .{};
    if (result.get("inputRequests")) |requests_value| {
        const requests = try requiredObject(requests_value);
        const handler = maybe_handler orelse return error.InputRequired;
        var iterator = requests.iterator();
        while (iterator.next()) |entry| {
            const request_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
            defer allocator.free(request_json);
            const response_json = try handler.handle(allocator, entry.key_ptr.*, request_json);
            defer allocator.free(response_json);
            const response = try parseResponse(arena.allocator(), response_json);
            try responses.put(memory, entry.key_ptr.*, response);
        }
    }
    var params_value = try parseResponse(arena.allocator(), params_json);
    var params = try requiredObject(params_value);
    if (responses.count() > 0) try params.put(memory, "inputResponses", .{ .object = responses });
    if (optionalString(result, "requestState")) |state| {
        try params.put(memory, "requestState", .{ .string = state });
    }
    params_value = .{ .object = params };
    return std.json.Stringify.valueAlloc(allocator, params_value, .{});
}

fn extractSseResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    request: []const u8,
    events: ?EventSink,
) ![]u8 {
    const request_id = try JsonRpcId.parse(allocator, request);
    defer request_id.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (data.len == 0) continue;
        validateMcpMessage(allocator, data) catch |failure| switch (failure) {
            error.OutOfMemory, error.McpMessageTooLarge => return failure,
            else => continue,
        };
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const object = requiredObject(parsed.value) catch continue;
        if (object.get("method") != null) {
            if (events) |sink| try sink.emit(data);
            continue;
        }
        const response_id = object.get("id") orelse continue;
        if (request_id.matches(response_id)) return allocator.dupe(u8, data);
    }
    return error.MissingMcpSseResponse;
}

fn rejectLegacyServerRequest(self: *StdioTransport, allocator: std.mem.Allocator, id: std.json.Value) !void {
    const response = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = error_codes.method_not_found, .message = "Server requests use MRTR in MCP 2026-07-28" },
    }, .{});
    defer allocator.free(response);
    const stdin = self.child.stdin orelse return error.McpProcessClosed;
    try stdin.writeStreamingAll(self.io, response);
    try stdin.writeStreamingAll(self.io, "\n");
}

fn readLine(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        const read = try file.readStreaming(io, &.{byte[0..]});
        if (read == 0) return error.EndOfStream;
        if (byte[0] == '\n') return result.toOwnedSlice(allocator);
        if (byte[0] != '\r') try result.append(allocator, byte[0]);
        if (result.items.len > json_limits.defaults.mcp_message.max_document_bytes) return error.McpMessageTooLarge;
    }
}

const JsonRpcId = union(enum) {
    integer: i64,
    string: []u8,

    fn parse(allocator: std.mem.Allocator, message: []const u8) !JsonRpcId {
        const parsed = try json_limits.parse(
            std.json.Value,
            allocator,
            message,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        defer parsed.deinit();
        const value = (try requiredObject(parsed.value)).get("id") orelse return error.InvalidMcpMessage;
        return switch (value) {
            .integer => |integer| .{ .integer = integer },
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            else => error.InvalidMcpMessage,
        };
    }

    fn deinit(self: JsonRpcId, allocator: std.mem.Allocator) void {
        switch (self) {
            .integer => {},
            .string => |string| allocator.free(string),
        }
    }

    fn matches(self: JsonRpcId, actual: std.json.Value) bool {
        return switch (self) {
            .integer => |value| actual == .integer and actual.integer == value,
            .string => |value| actual == .string and std.mem.eql(u8, actual.string, value),
        };
    }
};

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !std.json.Value {
    return json_limits.parseLeaky(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.mcp_message,
        .{ .allocate = .alloc_always },
        error.InvalidMcpResponse,
    );
}

fn validateMcpMessage(allocator: std.mem.Allocator, source: []const u8) !void {
    try validateMcpDocument(allocator, source, error.InvalidMcpMessage);
}

fn validateMcpResponse(allocator: std.mem.Allocator, source: []const u8) !void {
    try validateMcpDocument(allocator, source, error.InvalidMcpResponse);
}

fn validateMcpDocument(allocator: std.mem.Allocator, source: []const u8, comptime invalid_error: anytype) !void {
    if (source.len > json_limits.defaults.mcp_message.max_document_bytes) return error.McpMessageTooLarge;
    try json_limits.validateAs(allocator, source, json_limits.defaults.mcp_message, invalid_error);
}

fn responseResult(root: std.json.Value, expected_id: u64) !std.json.Value {
    const object = try requiredObject(root);
    const actual = object.get("id") orelse return error.InvalidMcpResponse;
    if (actual != .integer or actual.integer != expected_id) return error.McpResponseIdMismatch;
    if (object.get("error") != null) return error.McpRpcError;
    return object.get("result") orelse error.InvalidMcpResponse;
}

fn validateMethodResult(method: []const u8, result: std.json.Value) !void {
    const object = try requiredObject(result);
    const result_type = if (object.get("resultType")) |value|
        switch (value) {
            .string => |string| string,
            else => return error.InvalidMcpResponse,
        }
    else
        "complete";
    if (std.mem.eql(u8, result_type, "input_required")) return validateInputRequiredResult(object);
    if (!std.mem.eql(u8, result_type, "complete")) return error.InvalidMcpResponse;

    if (std.mem.eql(u8, method, methods.discover)) {
        try requireStringArray(object, "supportedVersions", 1, null);
        _ = try requiredObject(object.get("capabilities") orelse return error.InvalidMcpResponse);
        try validateCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_tools)) {
        try requireArray(object, "tools");
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_prompts)) {
        try requireArray(object, "prompts");
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_resources)) {
        try requireArray(object, "resources");
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_resource_templates)) {
        try requireArray(object, "resourceTemplates");
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.read_resource)) {
        try requireArray(object, "contents");
        try validateCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.get_prompt)) {
        try requireArray(object, "messages");
    } else if (std.mem.eql(u8, method, methods.call_tool)) {
        try requireArray(object, "content");
    } else if (std.mem.eql(u8, method, methods.complete)) {
        const completion = try requiredObject(object.get("completion") orelse return error.InvalidMcpResponse);
        try requireStringArray(completion, "values", 0, 100);
    } else if (std.mem.eql(u8, method, methods.listen)) {
        const meta = try requiredObject(object.get("_meta") orelse return error.InvalidMcpResponse);
        const subscription_id = meta.get("io.modelcontextprotocol/subscriptionId") orelse
            return error.InvalidMcpResponse;
        if (subscription_id != .integer and subscription_id != .string) return error.InvalidMcpResponse;
    }
}

fn validateInputRequiredResult(object: std.json.ObjectMap) !void {
    var has_state = false;
    if (object.get("requestState")) |state| {
        if (state != .string) return error.InvalidMcpResponse;
        has_state = true;
    }
    var has_requests = false;
    if (object.get("inputRequests")) |requests_value| {
        const requests = try requiredObject(requests_value);
        var iterator = requests.iterator();
        while (iterator.next()) |entry| {
            has_requests = true;
            const request = try requiredObject(entry.value_ptr.*);
            const method = try requiredString(request, "method");
            if (!std.mem.eql(u8, method, methods.elicit) and
                !std.mem.eql(u8, method, methods.list_roots) and
                !std.mem.eql(u8, method, methods.create_message)) return error.InvalidMcpResponse;
            if (request.get("params")) |params| _ = try requiredObject(params);
        }
    }
    if (!has_state and !has_requests) return error.InvalidMcpResponse;
}

fn validatePaginatedCacheableResult(object: std.json.ObjectMap) !void {
    try validateCacheableResult(object);
    if (object.get("nextCursor")) |cursor| if (cursor != .string) return error.InvalidMcpResponse;
}

fn validateCacheableResult(object: std.json.ObjectMap) !void {
    const ttl = object.get("ttlMs") orelse return error.InvalidMcpResponse;
    const nonnegative = switch (ttl) {
        .integer => |value| value >= 0,
        .float => |value| value >= 0 and std.math.isFinite(value),
        else => false,
    };
    if (!nonnegative) return error.InvalidMcpResponse;
    const scope = try requiredString(object, "cacheScope");
    if (!std.mem.eql(u8, scope, "public") and !std.mem.eql(u8, scope, "private")) {
        return error.InvalidMcpResponse;
    }
}

fn requireArray(object: std.json.ObjectMap, name: []const u8) !void {
    if ((object.get(name) orelse return error.InvalidMcpResponse) != .array) return error.InvalidMcpResponse;
}

fn requireStringArray(
    object: std.json.ObjectMap,
    name: []const u8,
    minimum: usize,
    maximum: ?usize,
) !void {
    const values = switch (object.get(name) orelse return error.InvalidMcpResponse) {
        .array => |array| array,
        else => return error.InvalidMcpResponse,
    };
    if (values.items.len < minimum or if (maximum) |limit| values.items.len > limit else false) {
        return error.InvalidMcpResponse;
    }
    for (values.items) |value| if (value != .string) return error.InvalidMcpResponse;
}

fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidMcpResponse,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return optionalString(object, name) orelse error.InvalidMcpResponse;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn validateStandardHeaders(headers: []const http.Header, method: []const u8, params: std.json.ObjectMap) bool {
    const version = findHeader(headers, "mcp-protocol-version") orelse return false;
    if (!std.mem.eql(u8, version, protocol_version)) return false;
    const routed_method = findHeader(headers, "mcp-method") orelse return false;
    if (!std.mem.eql(u8, routed_method, method)) return false;
    const body_name = routingName(method, params);
    const header_name = findHeader(headers, "mcp-name");
    return if (body_name) |name| header_name != null and std.mem.eql(u8, header_name.?, name) else header_name == null;
}

fn routingName(method: []const u8, params: std.json.ObjectMap) ?[]const u8 {
    if (std.mem.eql(u8, method, methods.call_tool) or std.mem.eql(u8, method, methods.get_prompt)) {
        return optionalString(params, "name");
    }
    if (std.mem.eql(u8, method, methods.read_resource)) return optionalString(params, "uri");
    return null;
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn validToolHeaderSchema(schema_value: std.json.Value) bool {
    const schema = requiredObject(schema_value) catch return false;
    const properties_value = schema.get("properties") orelse return true;
    const properties = requiredObject(properties_value) catch return false;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        if (!validHeaderAnnotation(annotation)) return false;
        const kind = optionalString(property, "type") orelse return false;
        if (!std.mem.eql(u8, kind, "string") and !std.mem.eql(u8, kind, "integer") and
            !std.mem.eql(u8, kind, "number") and !std.mem.eql(u8, kind, "boolean")) return false;
        var duplicates = properties.iterator();
        while (duplicates.next()) |other_entry| {
            if (std.mem.eql(u8, other_entry.key_ptr.*, entry.key_ptr.*)) continue;
            const other = requiredObject(other_entry.value_ptr.*) catch continue;
            const other_annotation = optionalString(other, "x-mcp-header") orelse continue;
            if (std.ascii.eqlIgnoreCase(other_annotation, annotation)) return false;
        }
    }
    return true;
}

fn validHeaderAnnotation(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e or byte == ':') return false;
    return true;
}

fn toolArgumentHeaders(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    arguments: std.json.Value,
) ![]const http.Header {
    const schema = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        schema_json,
        json_limits.defaults.schema,
        .{ .allocate = .alloc_always },
        error.InvalidMcpHeaderAnnotation,
    );
    if (!validToolHeaderSchema(schema)) return error.InvalidMcpHeaderAnnotation;
    const properties = switch ((try requiredObject(schema)).get("properties") orelse return &.{}) {
        .object => |value| value,
        else => return error.InvalidMcpHeaderAnnotation,
    };
    const values = try requiredObject(arguments);
    var headers: std.ArrayList(http.Header) = .empty;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        const value = values.get(entry.key_ptr.*) orelse continue;
        const raw = try primitiveHeaderValue(allocator, value);
        const encoded = try encodeHeaderValue(allocator, raw);
        try headers.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "Mcp-Param-{s}", .{annotation}),
            .value = encoded,
        });
    }
    return headers.toOwnedSlice(allocator);
}

fn primitiveHeaderValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        .integer => |integer| if (integer >= -9_007_199_254_740_991 and integer <= 9_007_199_254_740_991)
            std.fmt.allocPrint(allocator, "{d}", .{integer})
        else
            error.InvalidMcpToolArguments,
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .bool => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
        else => error.InvalidMcpToolArguments,
    };
}

fn encodeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var safe = value.len > 0 and value[0] != ' ' and value[value.len - 1] != ' ';
    if (std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=")) safe = false;
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) {
        safe = false;
        break;
    };
    if (safe) return value;
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{encoded});
}

fn validateToolHeaders(
    allocator: std.mem.Allocator,
    headers: []const http.Header,
    schema_json: []const u8,
    params: std.json.ObjectMap,
) !bool {
    const arguments = params.get("arguments") orelse std.json.Value{ .object = .{} };
    const expected = toolArgumentHeaders(allocator, schema_json, arguments) catch return false;
    for (expected) |header| {
        const actual = findHeader(headers, header.name) orelse return false;
        if (!std.mem.eql(u8, actual, header.value)) return false;
    }
    const schema = try parseResponse(allocator, schema_json);
    const properties = switch ((try requiredObject(schema)).get("properties") orelse return true) {
        .object => |value| value,
        else => return false,
    };
    const values = try requiredObject(arguments);
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        if (values.get(entry.key_ptr.*) == null) {
            const name = try std.fmt.allocPrint(allocator, "Mcp-Param-{s}", .{annotation});
            if (findHeader(headers, name) != null) return false;
        }
    }
    return true;
}

fn renderToolResult(allocator: std.mem.Allocator, result: std.json.ObjectMap) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (result.get("isError")) |is_error| {
        if (is_error == .bool and is_error.bool) try output.writer.writeAll("MCP tool error: ");
    }
    var wrote_content = false;
    if (result.get("content")) |content| switch (content) {
        .array => |items| for (items.items) |item| {
            if (wrote_content) try output.writer.writeAll("\n");
            const object = requiredObject(item) catch {
                try writeJsonValue(&output.writer, item);
                wrote_content = true;
                continue;
            };
            if (optionalString(object, "text")) |text| {
                try output.writer.writeAll(text);
            } else {
                try writeJsonValue(&output.writer, item);
            }
            wrote_content = true;
        },
        else => return error.InvalidMcpResponse,
    };
    if (!wrote_content) if (result.get("structuredContent")) |structured| {
        try writeJsonValue(&output.writer, structured);
    };
    return output.toOwnedSlice();
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}

fn testValidateMethodResult(method: []const u8, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    return validateMethodResult(method, parsed.value);
}

test "method result validation covers every core result family" {
    const valid = [_]struct { []const u8, []const u8 }{
        .{ "extension/custom", "{}" },
        .{ methods.discover, "{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"resultType\":\"complete\",\"tools\":[],\"ttlMs\":1.5,\"cacheScope\":\"private\",\"nextCursor\":\"next\"}" },
        .{ methods.list_prompts, "{\"prompts\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"resources\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"resourceTemplates\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{\"messages\":[]}" },
        .{ methods.call_tool, "{\"content\":[]}" },
        .{ methods.complete, "{\"completion\":{\"values\":[\"one\"]}}" },
        .{ methods.listen, "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"listen-1\"}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"requestState\":\"state\"}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"elicitation/create\",\"params\":{}},\"b\":{\"method\":\"roots/list\"},\"c\":{\"method\":\"sampling/createMessage\"}}}" },
    };
    for (valid) |case| try testValidateMethodResult(case[0], case[1]);
}

test "method result validation rejects every structural boundary" {
    const invalid = [_]struct { []const u8, []const u8 }{
        .{ "extension/custom", "[]" },
        .{ "extension/custom", "{\"resultType\":1}" },
        .{ "extension/custom", "{\"resultType\":\"other\"}" },
        .{ methods.discover, "{\"supportedVersions\":[],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.discover, "{\"supportedVersions\":[1],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.discover, "{\"supportedVersions\":[\"v\"],\"capabilities\":[],\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"tools\":{},\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{}" },
        .{ methods.call_tool, "{}" },
        .{ methods.complete, "{}" },
        .{ methods.complete, "{\"completion\":{\"values\":[1]}}" },
        .{ methods.listen, "{}" },
        .{ methods.listen, "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":true}}" },
        .{ methods.list_tools, "{\"tools\":[],\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":\"0\",\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":-1,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":-0.5,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"shared\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\",\"nextCursor\":1}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\"}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"requestState\":1}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":[]}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":[]}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{}}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"unknown/input\"}}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"elicitation/create\",\"params\":[]}}}" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.InvalidMcpResponse, testValidateMethodResult(case[0], case[1]));
    }

    var values: std.json.Array = .init(std.testing.allocator);
    defer values.deinit();
    for (0..101) |_| try values.append(.{ .string = "value" });
    var completion: std.json.ObjectMap = .{};
    defer completion.deinit(std.testing.allocator);
    try completion.put(std.testing.allocator, "values", .{ .array = values });
    var result: std.json.ObjectMap = .{};
    defer result.deinit(std.testing.allocator);
    try result.put(std.testing.allocator, "completion", .{ .object = completion });
    try std.testing.expectError(error.InvalidMcpResponse, validateMethodResult(methods.complete, .{ .object = result }));
}

test "state-only MRTR retries without an input handler" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"requestState\":\"retry-later\"}}",
            );
            try std.testing.expect(std.mem.indexOf(u8, request.message, "\"requestState\":\"retry-later\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "inputResponses") == null);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"content\":[]}}",
            );
        }
    };
    var stub = Stub{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    const result = try client.request(std.testing.allocator, methods.call_tool, "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "client emits self-describing requests and HTTP routing headers" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try std.testing.expectEqualStrings(protocol_version, findHeader(request.headers, "mcp-protocol-version").?);
            try std.testing.expectEqualStrings(methods.call_tool, findHeader(request.headers, "mcp-method").?);
            try std.testing.expectEqualStrings("weather", findHeader(request.headers, "mcp-name").?);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body, .{});
            defer parsed.deinit();
            const params = try requiredObject((try requiredObject(parsed.value)).get("params").?);
            const meta = try requiredObject(params.get("_meta").?);
            try std.testing.expectEqualStrings(
                protocol_version,
                try requiredString(meta, "io.modelcontextprotocol/protocolVersion"),
            );
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"sunny\"}]}}"),
            };
        }
    };
    var unused: u8 = 0;
    var streamable = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &unused, .sendFn = Stub.send },
        "https://example.test/mcp",
    );
    var client = Client{ .transport = streamable.transport() };
    const result = try client.callTool(std.testing.allocator, "weather", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "sunny") != null);
}

test "Streamable HTTP validates endpoints before transport callbacks" {
    const Stub = struct {
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const called: *bool = @ptrCast(@alignCast(context));
            called.* = true;
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}") };
        }
    };
    var called = false;
    var blocked = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &called, .sendFn = Stub.send },
        "https://127.0.0.1/mcp",
    );
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
    };
    try std.testing.expectError(
        error.LocalNetworkUrlForbidden,
        blocked.transport().send(std.testing.allocator, request),
    );
    try std.testing.expect(!called);

    var allowed = StreamableHttpTransport.initWithPolicy(
        std.testing.io,
        .{ .context = &called, .sendFn = Stub.send },
        "http://127.0.0.1/mcp",
        .{ .allow_http = true, .allow_local_network = true },
    );
    const response = try allowed.transport().send(std.testing.allocator, request);
    defer std.testing.allocator.free(response);
    try std.testing.expect(called);
}

test "client bounds request response and tool-argument JSON before dispatch" {
    const State = struct {
        response: []const u8,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.response);
        }
    };
    const deep_message = "[" ** 65 ++ "0" ++ "]" ** 65;
    var state = State{ .response = deep_message }; // kcov-ignore
    var client = Client{ .transport = .{ .context = &state, .sendFn = State.send } };
    try std.testing.expectError(
        error.InvalidMcpMessage,
        client.request(std.testing.allocator, "extension/test", deep_message),
    );
    try std.testing.expectError(
        error.InvalidMcpResponse,
        client.request(std.testing.allocator, "extension/test", "{}"),
    );
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "tool", deep_message),
    );
}

test "client completes multi round-trip input requests" {
    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"confirm\":{\"method\":\"elicitation/create\",\"params\":{}}},\"requestState\":\"state\"}}",
            );
            try std.testing.expect(std.mem.indexOf(u8, request.message, "inputResponses") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "requestState") != null);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"content\":[]}}",
            );
        }
        fn input(_: *anyopaque, allocator: std.mem.Allocator, key: []const u8, request: []const u8) ![]u8 {
            try std.testing.expectEqualStrings("confirm", key);
            try std.testing.expect(std.mem.indexOf(u8, request, "elicitation/create") != null);
            return allocator.dupe(u8, "{\"action\":\"accept\",\"content\":true}");
        }
    };
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .input_handler = .{ .context = &stub, .handleFn = Stub.input },
    };
    const result = try client.callTool(std.testing.allocator, "delete", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "tool header annotations are mirrored and encoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arguments = try parseResponse(arena.allocator(), "{\"region\":\" eu-west-1 \"}");
    const headers = try toolArgumentHeaders(
        arena.allocator(),
        "{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"}}}",
        arguments,
    );
    try std.testing.expectEqualStrings("Mcp-Param-Region", headers[0].name);
    try std.testing.expect(std.mem.startsWith(u8, headers[0].value, "=?base64?"));
}

test "server discovers capabilities and validates modern envelopes" {
    const Handler = struct {
        fn handle(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, _: []const u8) ![]u8 {
            try std.testing.expectEqualStrings(methods.list_tools, method);
            return allocator.dupe(u8, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}");
        }
    };
    var unused: u8 = 0;
    var server = Server{
        .handler = .{ .context = &unused, .handleFn = Handler.handle },
        .capabilities_json = "{\"tools\":{}}",
        .instructions = "Use the tools carefully.",
    };
    const discover_request = try buildRequest(
        std.testing.allocator,
        1,
        methods.discover,
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(discover_request);
    const response = try server.handle(std.testing.allocator, discover_request, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, protocol_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "serverInfo") != null);

    const list_request = try buildRequest(
        std.testing.allocator,
        2,
        methods.list_tools,
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(list_request);
    const listed = try server.handle(std.testing.allocator, list_request, null);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), listed.status);

    const invalid = try server.handle(std.testing.allocator, discover_request, .{ .headers = &.{} });
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid.status);
    try std.testing.expect(std.mem.indexOf(u8, invalid.body.?, "-32020") != null);
}

test "server releases partial state on every allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const Handler = struct {
                fn handle(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
                    return gpa.dupe(u8, "{}");
                }
            };
            var unused: u8 = 0;
            var server = Server{ .handler = .{ .context = &unused, .handleFn = Handler.handle } }; // kcov-ignore
            const request = try buildRequest(allocator, 1, "extension/check", "{}", "client", "1", "{}");
            defer allocator.free(request);
            const response = try server.handle(allocator, request, null);
            defer response.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "streamable HTTP emits subscription notifications before the result" {
    const Events = struct {
        seen: bool = false,
        fn emit(context: *anyopaque, message: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen = std.mem.indexOf(u8, message, "subscriptions/acknowledged") != null;
        }
    };
    var events: Events = .{};
    const body =
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}\n";
    const result = try extractSseResponse(
        std.testing.allocator,
        body,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\"}",
        .{ .context = &events, .eventFn = Events.emit },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(events.seen);
}

test "stdio transport runs a modern MCP tool server child process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"echo","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}' ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"echoed"}]}}' ;;
        \\  esac
        \\done
    ;
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    var client = Client{ .transport = stdio.transport() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try client.toolset().prepare(arena.allocator(), .{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    });
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const result = try tools[0].tool.execute(std.testing.allocator, "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("echoed", result);
}

test "HTTP transport handles SSE, notifications, and status failures" {
    const Stub = struct {
        status: u16 = 200,
        body: []const u8,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
        }
    };
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var stub = Stub{ .body = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n" };
    var events: Events = .{};
    var streamable = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &stub, .sendFn = Stub.send },
        "https://example.test/mcp",
    );
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
        .events = .{ .context = &events, .eventFn = Events.emit },
    };
    const response = try streamable.transport().send(std.testing.allocator, request);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), events.count);

    stub.status = 503;
    stub.body = "unavailable";
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, request),
    );
    try std.testing.expectError(error.McpHttpRequestFailed, streamable.transport().send(
        std.testing.allocator,
        .{ .message = "{}", .method = methods.cancelled, .expects_response = false },
    ));
    stub.status = 200;
    stub.body = "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n";
    try std.testing.expectError(
        error.MissingMcpSseResponse,
        streamable.transport().send(std.testing.allocator, request),
    );

    const prefix = "data: ";
    const oversized = try std.testing.allocator.alloc(
        u8,
        prefix.len + json_limits.defaults.mcp_message.max_document_bytes + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memcpy(oversized[0..prefix.len], prefix);
    @memset(oversized[prefix.len..], '0');
    stub.body = oversized;
    try std.testing.expectError(
        error.McpMessageTooLarge,
        streamable.transport().send(std.testing.allocator, request),
    );
}

test "generic client helpers cover every core request shape" {
    const Stub = struct {
        calls: usize = 0,
        notifications: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (!request.expects_response) {
                self.notifications += 1;
                return allocator.alloc(u8, 0);
            }
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.message, .{});
            defer parsed.deinit();
            const id = (try requiredObject(parsed.value)).get("id").?;
            const result_source = if (std.mem.eql(u8, request.method, methods.discover))
                "{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}"
            else if (std.mem.eql(u8, request.method, methods.list_tools))
                "{\"resultType\":\"complete\",\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_resources))
                "{\"resultType\":\"complete\",\"resources\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_resource_templates))
                "{\"resultType\":\"complete\",\"resourceTemplates\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.read_resource))
                "{\"resultType\":\"complete\",\"contents\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_prompts))
                "{\"resultType\":\"complete\",\"prompts\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.get_prompt))
                "{\"resultType\":\"complete\",\"messages\":[]}"
            else if (std.mem.eql(u8, request.method, methods.complete))
                "{\"resultType\":\"complete\",\"completion\":{\"values\":[]}}"
            else if (std.mem.eql(u8, request.method, methods.listen))
                "{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}"
            else
                "{\"resultType\":\"complete\"}";
            const result = try std.json.parseFromSlice(std.json.Value, allocator, result_source, .{});
            defer result.deinit();
            return std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = id,
                .result = result.value,
            }, .{});
        }
        fn event(_: *anyopaque, _: []const u8) !void {}
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    const calls = [_][]u8{
        try client.discover(std.testing.allocator),
        try client.listTools(std.testing.allocator, "next"),
        try client.listResources(std.testing.allocator, null),
        try client.listResourceTemplates(std.testing.allocator, "next"),
        try client.readResource(std.testing.allocator, "file:///tmp/a"),
        try client.listPrompts(std.testing.allocator, null),
        try client.getPrompt(std.testing.allocator, "{\"name\":\"review\"}"),
        try client.complete(std.testing.allocator, "{}"),
        try client.listen(
            std.testing.allocator,
            "{\"toolsListChanged\":true}",
            .{ .context = &stub, .eventFn = Stub.event },
        ),
    };
    defer for (calls) |value| std.testing.allocator.free(value);
    try client.cancel(std.testing.allocator, 9, "done");
    try client.notify(std.testing.allocator, "com.example/changed", "{}");
    try std.testing.expectEqual(@as(usize, 2), stub.notifications);
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "bad", "[]"),
    );
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "bad", "{"),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        client.notify(std.testing.allocator, "bad", "{"),
    );
    try Stub.event(&stub, "{}");

    var no_handler = Client{ .transport = .{ .context = &stub, .sendFn = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"confirm\":{\"method\":\"elicitation/create\",\"params\":{}}}}}",
            );
        }
    }.send } };
    try std.testing.expectError(
        error.InputRequired,
        no_handler.request(std.testing.allocator, methods.call_tool, "{}"),
    );
    no_handler.max_round_trips = 0;
    try std.testing.expectError(
        error.TooManyMcpRoundTrips,
        no_handler.request(std.testing.allocator, methods.call_tool, "{}"), // kcov-ignore
    );
}

test "toolset paginates, mirrors headers, and renders rich results" {
    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return switch (self.calls) {
                1 => allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"weather\",\"description\":\"Weather\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"x-mcp-header\":\"City\"}}}}],\"nextCursor\":\"two\",\"ttlMs\":0,\"cacheScope\":\"private\"}}",
                ),
                2 => allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"invalid\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"object\",\"x-mcp-header\":\"X\"}}}}],\"ttlMs\":0,\"cacheScope\":\"private\"}}",
                ),
                3 => blk: {
                    try std.testing.expectEqualStrings("Madrid", findHeader(request.headers, "mcp-param-city").?);
                    break :blk allocator.dupe(
                        u8,
                        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"sunny\"},{\"type\":\"image\",\"data\":\"abc\"}]}}",
                    );
                },
                else => error.InvalidMcpResponse,
            };
        }
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try client.toolset().prepare(arena.allocator(), .{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    });
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const output = try tools[0].tool.execute(std.testing.allocator, "{\"city\":\"Madrid\"}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "sunny") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "image") != null);
}

test "server returns specified errors and validates tool parameter headers" {
    const Handler = struct {
        fail: bool = false,
        fn handle(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.Failed;
            return allocator.dupe(u8, "{\"content\":[]}");
        }
        fn schema(_: *anyopaque, name: []const u8) ?[]const u8 {
            if (!std.mem.eql(u8, name, "weather")) return null;
            return "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"x-mcp-header\":\"City\"}}}";
        }
    };
    var handler: Handler = .{};
    var server = Server{
        .handler = .{ .context = &handler, .handleFn = Handler.handle },
        .tool_schemas = .{ .context = &handler, .schemaFn = Handler.schema },
    };
    const invalid_json = try server.handle(std.testing.allocator, "{", null);
    defer invalid_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_json.status);
    const invalid_rpc = try server.handle(std.testing.allocator, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}", null);
    defer invalid_rpc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_rpc.status);
    const missing_meta = try server.handle(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{}}", null);
    defer missing_meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), missing_meta.status);
    const wrong_version = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"old\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
        null,
    );
    defer wrong_version.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, wrong_version.body.?, "-32022") != null);

    const call = try buildRequest(
        std.testing.allocator,
        1,
        methods.call_tool,
        "{\"name\":\"weather\",\"arguments\":{\"city\":\"Madrid\"}}",
        "test",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(call);
    const headers = [_]http.Header{
        .{ .name = "MCP-Protocol-Version", .value = protocol_version },
        .{ .name = "Mcp-Method", .value = methods.call_tool },
        .{ .name = "Mcp-Name", .value = "weather" },
        .{ .name = "Mcp-Param-City", .value = "Madrid" },
    };
    const ok = try server.handle(std.testing.allocator, call, .{ .headers = &headers });
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    const mismatch = try server.handle(std.testing.allocator, call, .{ .headers = headers[0..3] });
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), mismatch.status);

    const notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}";
    const accepted = try server.handle(std.testing.allocator, notification, null);
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
    handler.fail = true;
    const ignored_failure = try server.handle(std.testing.allocator, notification, null);
    defer ignored_failure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), ignored_failure.status);
    const failed = try server.handle(std.testing.allocator, call, null);
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 500), failed.status);
}

test "header schemas cover primitives, invalid definitions, and mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invalid_schemas = [_][]const u8{
        "{\"properties\":{\"x\":{\"type\":\"object\",\"x-mcp-header\":\"X\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"bad name\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"X\"},\"y\":{\"type\":\"string\",\"x-mcp-header\":\"x\"}}}",
    };
    for (invalid_schemas) |schema| {
        try std.testing.expect(!validToolHeaderSchema(try parseResponse(arena.allocator(), schema)));
    }
    const schema =
        "{\"properties\":{" ++
        "\"integer\":{\"type\":\"integer\",\"x-mcp-header\":\"Integer\"}," ++
        "\"number\":{\"type\":\"number\",\"x-mcp-header\":\"Number\"}," ++
        "\"boolean\":{\"type\":\"boolean\",\"x-mcp-header\":\"Boolean\"}," ++
        "\"sentinel\":{\"type\":\"string\",\"x-mcp-header\":\"Sentinel\"}}}";
    const arguments = try parseResponse(
        arena.allocator(),
        "{\"integer\":42,\"number\":1.5,\"boolean\":true,\"sentinel\":\"=?base64?x?=\"}",
    );
    const headers = try toolArgumentHeaders(arena.allocator(), schema, arguments);
    try std.testing.expectEqual(@as(usize, 4), headers.len);
    try std.testing.expect(std.mem.startsWith(u8, headers[3].value, "=?base64?"));
    const non_ascii = try encodeHeaderValue(arena.allocator(), "\x7f");
    try std.testing.expect(std.mem.startsWith(u8, non_ascii, "=?base64?"));
    const too_large = std.json.Value{ .integer = 9_007_199_254_740_992 };
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        primitiveHeaderValue(arena.allocator(), too_large),
    );

    const params = try requiredObject(try parseResponse(
        arena.allocator(),
        "{\"arguments\":{\"integer\":42,\"number\":1.5,\"boolean\":true,\"sentinel\":\"=?base64?x?=\"}}",
    ));
    try std.testing.expect(try validateToolHeaders(arena.allocator(), headers, schema, params));
    try std.testing.expect(!try validateToolHeaders(arena.allocator(), headers[0..3], schema, params));
    const absent_params = try requiredObject(try parseResponse(arena.allocator(), "{\"arguments\":{}}"));
    try std.testing.expect(!try validateToolHeaders(arena.allocator(), headers, schema, absent_params));

    try std.testing.expectEqualStrings("file:///a", routingName(
        methods.read_resource,
        try requiredObject(try parseResponse(arena.allocator(), "{\"uri\":\"file:///a\"}")),
    ).?);
    try std.testing.expect(routingName("custom/method", std.json.ObjectMap{}) == null);
    try std.testing.expect(findHeader(&.{}, "missing") == null);

    try std.testing.expectError(error.InvalidMcpMessage, buildRequest(
        std.testing.allocator,
        1,
        "x",
        "{}",
        "client",
        "1",
        "{",
    ));
}

test "JSON-RPC string ids and tool result variants are preserved" {
    const id = try JsonRpcId.parse(std.testing.allocator, "{\"id\":\"request-1\"}");
    defer id.deinit(std.testing.allocator);
    try std.testing.expect(id.matches(.{ .string = "request-1" }));
    try std.testing.expect(!id.matches(.{ .integer = 1 }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]struct { json: []const u8, expected: []const u8 }{
        .{ .json = "{\"isError\":true,\"content\":[42]}", .expected = "MCP tool error: 42" },
        .{ .json = "{\"structuredContent\":{\"ok\":true}}", .expected = "{\"ok\":true}" },
    };
    for (values) |value| {
        const rendered = try renderToolResult(
            std.testing.allocator,
            try requiredObject(try parseResponse(arena.allocator(), value.json)),
        );
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(value.expected, rendered);
    }
    try std.testing.expectError(error.InvalidMcpResponse, renderToolResult(
        std.testing.allocator,
        try requiredObject(try parseResponse(arena.allocator(), "{\"content\":false}")),
    ));
}

test "stdio transport filters interleaved modern and legacy messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\read -r line
        \\printf '%s\n' '1'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"legacy/request"}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress"}'
        \\printf '%s\n' '{}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":999,"result":{}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":"request-1","result":{}}'
        \\read -r rejection
    ;
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var events: Events = .{};
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    const response = try stdio.transport().send(std.testing.allocator, .{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":\"request-1\",\"method\":\"server/discover\"}",
        .method = methods.discover,
        .events = .{ .context = &events, .eventFn = Events.emit },
    });
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), events.count);
}

test "stdio transport releases malformed and partial messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
    };
    const malformed_script =
        \\read -r line
        \\printf '%s\n' 'not-json'
    ;
    var malformed = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", malformed_script });
    defer malformed.deinit();
    try std.testing.expectError(
        error.InvalidMcpMessage,
        malformed.transport().send(std.testing.allocator, request),
    );

    const partial_script =
        \\read -r line
        \\printf 'partial'
    ;
    var partial = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", partial_script });
    defer partial.deinit();
    try std.testing.expectError(
        error.EndOfStream,
        partial.transport().send(std.testing.allocator, request),
    );
}

fn fuzzSseAndJsonRpcFraming(_: void, smith: *std.testing.Smith) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    const response = extractSseResponse(std.testing.allocator, value, "{\"id\":1}", null) catch return;
    std.testing.allocator.free(response);
}

test "fuzz MCP SSE and JSON-RPC framing" {
    try std.testing.fuzz({}, fuzzSseAndJsonRpcFraming, .{ .corpus = &.{
        "\x1e\x00\x00\x00data: {\"jsonrpc\":\"2.0\",\"id\":1}\n",
    } });
}
