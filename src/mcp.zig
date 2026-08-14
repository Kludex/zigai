//! Model Context Protocol clients exposed as ordinary ZigAI toolsets.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");
const model = @import("model.zig");
const http = @import("transport.zig");

pub const protocol_version = "2025-11-25";

/// MCP protocol and transport failures defined by ZigAI. Transport callback,
/// process I/O, JSON parsing, and allocation errors may also propagate.
pub const Error = error{
    EmptyCommand,
    InvalidMcpMessage,
    InvalidMcpResponse,
    InvalidMcpToolArguments,
    McpHttpRequestFailed,
    McpMessageTooLarge,
    McpProcessClosed,
    McpResponseIdMismatch,
    McpRpcError,
    MissingCursor,
    MissingMcpClient,
    MissingMcpSseResponse,
    MissingParams,
    UnexpectedMcpRequest,
    UnsupportedMcpProtocolVersion,
};

/// Pluggable JSON-RPC message transport. Returned response bytes are owned by
/// the caller. Notifications may return an empty owned slice.
pub const Transport = struct {
    context: *anyopaque,
    sendFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        message: []const u8,
        expects_response: bool,
    ) anyerror![]const u8,

    pub fn send(
        self: Transport,
        allocator: std.mem.Allocator,
        message: []const u8,
        expects_response: bool,
    ) ![]const u8 {
        return self.sendFn(self.context, allocator, message, expects_response);
    }
};

/// MCP Streamable HTTP transport over ZigAI's normal HTTP transport.
pub const StreamableHttpTransport = struct {
    io: std.Io,
    inner: http.Transport,
    endpoint: []const u8,
    headers: []const http.Header = &.{},
    session_id: ?http.ResponseMetadata.SessionId = null,
    initialized: bool = false,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, inner: http.Transport, endpoint: []const u8) StreamableHttpTransport {
        return .{ .io = io, .inner = inner, .endpoint = endpoint };
    }

    pub fn transport(self: *StreamableHttpTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        message: []const u8,
        expects_response: bool,
    ) ![]const u8 {
        const self: *StreamableHttpTransport = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var request_headers: std.ArrayList(http.Header) = .empty;
        defer request_headers.deinit(allocator);
        try request_headers.appendSlice(allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json, text/event-stream" },
        });
        if (self.initialized) {
            try request_headers.append(allocator, .{ .name = "mcp-protocol-version", .value = protocol_version });
        }
        if (self.session_id) |*session_id| {
            try request_headers.append(allocator, .{ .name = "mcp-session-id", .value = session_id.slice() });
        }
        try request_headers.appendSlice(allocator, self.headers);

        const response = try self.inner.send(allocator, .{
            .method = .POST,
            .url = self.endpoint,
            .headers = request_headers.items,
            .body = message,
        });
        errdefer allocator.free(response.body);
        if (response.metadata.mcp_session_id) |session_id| self.session_id = session_id;
        if (expects_response) {
            if (response.status != 200) return error.McpHttpRequestFailed;
        } else if (response.status != 200 and response.status != 202 and response.status != 204) {
            return error.McpHttpRequestFailed;
        }
        self.initialized = true;
        if (response.body.len == 0 or response.body[0] == '{' or response.body[0] == '[') return response.body;

        const extracted = try extractSseResponse(allocator, response.body, message);
        allocator.free(response.body);
        return extracted;
    }
};

/// MCP stdio transport. It owns a child process and exchanges newline-delimited
/// JSON-RPC messages over the child's stdin and stdout.
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

    fn send(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        message: []const u8,
        expects_response: bool,
    ) ![]const u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stdin = self.child.stdin orelse return error.McpProcessClosed;
        try stdin.writeStreamingAll(self.io, message);
        try stdin.writeStreamingAll(self.io, "\n");
        if (!expects_response) return allocator.alloc(u8, 0);

        const request_id = try JsonRpcId.parse(allocator, message);
        defer request_id.deinit(allocator);
        while (true) {
            const line = try readLine(allocator, self.io, self.child.stdout orelse return error.McpProcessClosed);
            errdefer allocator.free(line);
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                return error.InvalidMcpMessage;
            };
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |object| object,
                else => {
                    allocator.free(line);
                    continue;
                },
            };
            if (object.get("method") != null and object.get("id") != null) {
                try self.rejectServerRequest(allocator, object.get("id").?);
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

    fn rejectServerRequest(self: *StdioTransport, allocator: std.mem.Allocator, id: std.json.Value) !void {
        const response = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{ .code = -32601, .message = "Client method not supported" },
        }, .{});
        defer allocator.free(response);
        const stdin = self.child.stdin orelse return error.McpProcessClosed;
        try stdin.writeStreamingAll(self.io, response);
        try stdin.writeStreamingAll(self.io, "\n");
    }
};

/// Stateful MCP client that discovers remote tools and adapts them to a ZigAI
/// toolset. Keep the client and its transport alive for every agent run using
/// the returned toolset.
pub const Client = struct {
    transport: Transport,
    name: []const u8 = "zigai",
    version: []const u8 = "0.1.0",
    next_id: std.atomic.Value(u64) = .init(1),
    initialized: std.atomic.Value(bool) = .init(false),

    pub fn toolset(self: *Client) agent.Toolset {
        return .{ .context = self, .prepareFn = prepareTools };
    }

    fn prepareTools(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: agent.ToolsetContext,
        _: []const model.Tool,
    ) ![]const agent.ToolsetEntry {
        const self: *Client = @ptrCast(@alignCast(context orelse return error.MissingMcpClient));
        try self.ensureInitialized(allocator);

        var entries: std.ArrayList(agent.ToolsetEntry) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const response = try self.listToolsRequest(allocator, cursor);
            defer allocator.free(response.body);
            var parse_memory = std.heap.ArenaAllocator.init(allocator);
            defer parse_memory.deinit();
            const root = try parseResponse(parse_memory.allocator(), response.body);
            const result = try responseResult(root, response.id);
            const object = try requiredObject(result);
            const tools = switch (object.get("tools") orelse return error.InvalidMcpResponse) {
                .array => |array| array,
                else => return error.InvalidMcpResponse,
            };
            for (tools.items) |tool_value| {
                const tool = try requiredObject(tool_value);
                const name = try requiredString(tool, "name");
                const description = optionalString(tool, "description") orelse "";
                const schema_value = tool.get("inputSchema") orelse return error.InvalidMcpResponse;
                const schema = try std.json.Stringify.valueAlloc(allocator, schema_value, .{});
                const tool_context = try allocator.create(ToolContext);
                tool_context.* = .{
                    .client = self,
                    .name = try allocator.dupe(u8, name),
                };
                try entries.append(allocator, .{ .tool = .{
                    .definition = .{
                        .name = try allocator.dupe(u8, name),
                        .description = try allocator.dupe(u8, description),
                        .parameters_json_schema = schema,
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

    fn ensureInitialized(self: *Client, allocator: std.mem.Allocator) !void {
        if (self.initialized.load(.acquire)) return;
        const id = self.nextId();
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = "initialize",
            .params = .{
                .protocolVersion = protocol_version,
                .capabilities = .{},
                .clientInfo = .{ .name = self.name, .version = self.version },
            },
        }, .{});
        defer allocator.free(request);
        const body = try self.transport.send(allocator, request, true);
        defer allocator.free(body);
        var parse_memory = std.heap.ArenaAllocator.init(allocator);
        defer parse_memory.deinit();
        const result = try responseResult(try parseResponse(parse_memory.allocator(), body), id);
        const negotiated = try requiredString(try requiredObject(result), "protocolVersion");
        if (!std.mem.eql(u8, negotiated, protocol_version)) return error.UnsupportedMcpProtocolVersion;

        const notification = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .method = "notifications/initialized",
        }, .{});
        defer allocator.free(notification);
        const notification_response = try self.transport.send(allocator, notification, false);
        allocator.free(notification_response);
        self.initialized.store(true, .release);
    }

    fn listToolsRequest(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) !RpcResponse {
        const id = self.nextId();
        const request = if (cursor) |value|
            try std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = id,
                .method = "tools/list",
                .params = .{ .cursor = value },
            }, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = id,
                .method = "tools/list",
            }, .{});
        defer allocator.free(request);
        return .{ .id = id, .body = try self.transport.send(allocator, request, true) };
    }

    fn executeTool(context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        const tool: *ToolContext = @ptrCast(@alignCast(context));
        return tool.client.callTool(allocator, tool.name, arguments_json);
    }

    fn callTool(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) ![]u8 {
        var parse_memory = std.heap.ArenaAllocator.init(allocator);
        defer parse_memory.deinit();
        const memory = parse_memory.allocator();
        const arguments = std.json.parseFromSliceLeaky(std.json.Value, memory, arguments_json, .{}) catch
            return error.InvalidMcpToolArguments;
        if (arguments != .object) return error.InvalidMcpToolArguments;
        const id = self.nextId();
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = "tools/call",
            .params = .{ .name = name, .arguments = arguments },
        }, .{});
        defer allocator.free(request);
        const body = try self.transport.send(allocator, request, true);
        defer allocator.free(body);
        const result = try responseResult(try parseResponse(memory, body), id);
        return renderToolResult(allocator, try requiredObject(result));
    }

    fn nextId(self: *Client) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }
};

const ToolContext = struct {
    client: *Client,
    name: []const u8,
};

const RpcResponse = struct {
    id: u64,
    body: []const u8,
};

fn extractSseResponse(allocator: std.mem.Allocator, body: []const u8, request: []const u8) ![]u8 {
    const request_id = try JsonRpcId.parse(allocator, request);
    defer request_id.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (data.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const object = requiredObject(parsed.value) catch continue;
        if (object.get("method") != null) continue;
        const response_id = object.get("id") orelse continue;
        if (request_id.matches(response_id)) return allocator.dupe(u8, data);
    }
    return error.MissingMcpSseResponse;
}

fn readLine(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        _ = try file.readStreaming(io, &.{byte[0..]});
        if (byte[0] == '\n') return result.toOwnedSlice(allocator);
        if (byte[0] != '\r') try result.append(allocator, byte[0]);
        if (result.items.len > 8 * 1024 * 1024) return error.McpMessageTooLarge;
    }
}

const JsonRpcId = union(enum) {
    integer: i64,
    string: []u8,

    fn parse(allocator: std.mem.Allocator, message: []const u8) !JsonRpcId {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
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
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch error.InvalidMcpResponse;
}

fn responseResult(root: std.json.Value, expected_id: ?u64) !std.json.Value {
    const object = try requiredObject(root);
    if (expected_id) |id| {
        const actual = object.get("id") orelse return error.InvalidMcpResponse;
        if (actual != .integer or actual.integer != id) return error.McpResponseIdMismatch;
    }
    if (object.get("error") != null) return error.McpRpcError;
    return object.get("result") orelse error.InvalidMcpResponse;
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
    if (!wrote_content) {
        if (result.get("structuredContent")) |structured| {
            try writeJsonValue(&output.writer, structured);
            wrote_content = true;
        }
    }
    return output.toOwnedSlice();
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}

test "streamable HTTP extracts SSE responses and preserves sessions" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 2) {
                var found_session = false;
                for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                    found_session = std.mem.eql(u8, header.value, "session-42");
                };
                try std.testing.expect(found_session);
            }
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"),
                .metadata = .{ .mcp_session_id = try .init("session-42") },
            };
        }
    };
    var stub: Stub = .{};
    var streamable = StreamableHttpTransport.init(std.testing.io, .{ .context = &stub, .sendFn = Stub.send }, "https://example.test/mcp");
    const first = try streamable.transport().send(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", true);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", first);
    const second = try streamable.transport().send(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", true);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "streamable HTTP validates response statuses and SSE ids" {
    const Stub = struct {
        status: u16,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = self.status, .body = try allocator.dupe(u8, "error") };
        }
    };
    var stub = Stub{ .status = 202 };
    var streamable = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &stub, .sendFn = Stub.send },
        "https://example.test/mcp",
    );
    try std.testing.expectError(error.McpHttpRequestFailed, streamable.transport().send(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        true,
    ));
    stub.status = 400;
    try std.testing.expectError(error.McpHttpRequestFailed, streamable.transport().send(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        false,
    ));
    try std.testing.expectError(error.MissingMcpSseResponse, extractSseResponse(
        std.testing.allocator,
        "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
    ));
}

test "MCP client discovers paginated tools and calls them through a toolset" {
    const Stub = struct {
        step: usize = 0,

        fn send(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            message: []const u8,
            expects_response: bool,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.step += 1;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
            defer parsed.deinit();
            const object = try requiredObject(parsed.value);
            const method = try requiredString(object, "method");
            return switch (self.step) {
                1 => blk: {
                    try std.testing.expect(expects_response);
                    try std.testing.expectEqualStrings("initialize", method);
                    break :blk allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}");
                },
                2 => blk: {
                    try std.testing.expect(!expects_response);
                    try std.testing.expectEqualStrings("notifications/initialized", method);
                    break :blk allocator.alloc(u8, 0);
                },
                3 => blk: {
                    try std.testing.expectEqualStrings("tools/list", method);
                    break :blk allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"weather\",\"description\":\"Get weather\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}],\"nextCursor\":\"page-2\"}}");
                },
                4 => blk: {
                    try std.testing.expectEqualStrings("tools/list", method);
                    const params = try requiredObject(object.get("params") orelse return error.MissingCursor);
                    try std.testing.expectEqualStrings("page-2", try requiredString(params, "cursor"));
                    break :blk allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[{\"name\":\"time\",\"inputSchema\":{\"type\":\"object\"}}]}}");
                },
                5 => blk: {
                    try std.testing.expectEqualStrings("tools/call", method);
                    const params = try requiredObject(object.get("params") orelse return error.MissingParams);
                    try std.testing.expectEqualStrings("weather", try requiredString(params, "name"));
                    break :blk allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Sunny in Madrid\"}]}}");
                },
                else => error.UnexpectedMcpRequest,
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
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("weather", tools[0].tool.definition.name);
    try std.testing.expectEqualStrings("Get weather", tools[0].tool.definition.description);
    try std.testing.expectEqualStrings("time", tools[1].tool.definition.name);
    const result = try tools[0].tool.execute(std.testing.allocator, "{\"city\":\"Madrid\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Sunny in Madrid", result);
    try std.testing.expectEqual(@as(usize, 5), stub.step);
    try std.testing.expectError(error.InvalidMcpToolArguments, tools[0].tool.execute(std.testing.allocator, "{"));
}

test "MCP tool results retain non-text content and error state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"isError\":true,\"content\":[{\"type\":\"image\",\"data\":\"abc\",\"mimeType\":\"image/png\"}]}",
        .{},
    );
    const rendered = try renderToolResult(std.testing.allocator, try requiredObject(parsed));
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "MCP tool error: "));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"image\"") != null);

    const mixed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"content\":[42],\"structuredContent\":{\"ignored\":true}}",
        .{},
    );
    const mixed_rendered = try renderToolResult(std.testing.allocator, try requiredObject(mixed));
    defer std.testing.allocator.free(mixed_rendered);
    try std.testing.expectEqualStrings("42", mixed_rendered);

    const structured = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"structuredContent\":{\"answer\":42}}",
        .{},
    );
    const structured_rendered = try renderToolResult(std.testing.allocator, try requiredObject(structured));
    defer std.testing.allocator.free(structured_rendered);
    try std.testing.expectEqualStrings("{\"answer\":42}", structured_rendered);

    const invalid = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"content\":false}", .{});
    try std.testing.expectError(
        error.InvalidMcpResponse,
        renderToolResult(std.testing.allocator, try requiredObject(invalid)),
    );
}

test "JSON-RPC ids support strings and reject unsupported types" {
    const string_id = try JsonRpcId.parse(std.testing.allocator, "{\"id\":\"request-1\"}");
    defer string_id.deinit(std.testing.allocator);
    try std.testing.expect(string_id.matches(.{ .string = "request-1" }));
    try std.testing.expect(!string_id.matches(.{ .integer = 1 }));
    try std.testing.expectError(error.InvalidMcpMessage, JsonRpcId.parse(std.testing.allocator, "{\"id\":false}"));
}

test "stdio transport runs an MCP tool server child process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}' ;;
        \\    *'"method":"notifications/initialized"'*) ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '1'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"server/ping"}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress"}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":999,"result":{}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object"}}]}}'
        \\      ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"echoed"}]}}' ;;
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
    try std.testing.expectEqualStrings("echo", tools[0].tool.definition.name);
    const result = try tools[0].tool.execute(std.testing.allocator, "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("echoed", result);
}

test "stdio transport releases malformed and interrupted messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const malformed_script =
        \\read -r line
        \\printf '%s\n' 'not-json'
    ;
    var malformed = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", malformed_script });
    defer malformed.deinit();
    try std.testing.expectError(error.InvalidMcpMessage, malformed.transport().send(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
        true,
    ));

    const interrupted_script =
        \\read -r line
        \\exec 0<&-
        \\printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"server/ping"}'
        \\sleep 1
    ;
    var interrupted = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", interrupted_script });
    defer interrupted.deinit();
    if (interrupted.transport().send(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
        true,
    )) |body| {
        std.testing.allocator.free(body);
        return error.ExpectedMcpWriteFailure;
    } else |_| {}

    const partial_script =
        \\read -r line
        \\printf 'partial'
    ;
    var partial = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", partial_script });
    defer partial.deinit();
    if (partial.transport().send(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
        true,
    )) |body| {
        std.testing.allocator.free(body);
        return error.ExpectedMcpReadFailure;
    } else |_| {}
}
