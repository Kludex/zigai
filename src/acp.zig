//! Agent Client Protocol JSON-RPC client with v1 compatibility and v2 sessions.
//!
//! Transport messages are newline-delimited UTF-8 JSON. The client owns no
//! editor or agent implementation; filesystem, terminal, and permission calls
//! are explicit application handlers.

const std = @import("std");
const builtin = @import("builtin");
const execution = @import("execution.zig");
const json_limits = @import("json.zig");
const model_types = @import("model.zig");

pub const latest_protocol_version: u8 = 2;
pub const max_message_bytes: usize = 8 * 1024 * 1024;

/// Arena-owned transport line.
pub const OwnedLine = struct {
    bytes: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *OwnedLine) void {
        self.gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Bidirectional ACP message transport.
pub const Transport = struct {
    context: *anyopaque,
    send_fn: *const fn (context: *anyopaque, line: []const u8) anyerror!void,
    receive_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!OwnedLine,
    close_fn: *const fn (context: *anyopaque) void,
    is_transport_error_fn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    pub fn send(self: Transport, line: []const u8) !void {
        return self.send_fn(self.context, line);
    }
    pub fn receive(self: Transport, gpa: std.mem.Allocator) !OwnedLine {
        return self.receive_fn(self.context, gpa);
    }
    pub fn close(self: Transport) void {
        self.close_fn(self.context);
    }
    pub fn isTransportError(self: Transport, failure: anyerror) bool {
        const classify = self.is_transport_error_fn orelse return false;
        return classify(self.context, failure);
    }
};

/// Reconnectable ACP transport factory.
pub const Connector = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!Transport,

    pub fn open(self: Connector, gpa: std.mem.Allocator) !Transport {
        return self.open_fn(self.context, gpa);
    }
};

pub const ReconnectPolicy = struct {
    max_attempts: usize = 3,
    delay_ms: u64 = 250,
};

/// Negotiated feature summary.
pub const Capabilities = struct {
    protocol_version: u8,
    sessions: bool,
    prompt_images: bool = false,
    prompt_audio: bool = false,
    embedded_context: bool = false,
    mcp_stdio: bool = false,
    mcp_http: bool = false,
    session_delete: bool = false,
    additional_directories: bool = false,
    legacy_filesystem: bool = false,
    legacy_terminal: bool = false,
};

/// Client implementation identity sent during initialize.
pub const Implementation = struct {
    name: []const u8 = "zigai",
    title: []const u8 = "ZigAI",
    version: []const u8 = "0.1.0",
};

/// User permission request from an agent.
pub const PermissionRequest = struct {
    session_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    raw_subject_json: ?[]const u8,
    option_ids: []const []const u8,
};

/// Permission callback returns one advertised option ID.
pub const PermissionHandler = struct {
    context: ?*anyopaque = null,
    decide_fn: *const fn (
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        request: PermissionRequest,
    ) anyerror![]const u8,

    pub fn decide(self: PermissionHandler, gpa: std.mem.Allocator, request: PermissionRequest) ![]const u8 {
        return self.decide_fn(self.context, gpa, request);
    }
};

/// Legacy ACP v1 terminal handler.
pub const TerminalHandler = struct {
    context: *anyopaque,
    request_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) anyerror![]u8,

    pub fn request(
        self: TerminalHandler,
        gpa: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        return self.request_fn(self.context, gpa, method, params_json);
    }
};

/// Maps ACP absolute paths into one rooted execution environment.
pub const FilesystemHandler = struct {
    absolute_root: []const u8,
    environment: execution.Environment,

    pub fn relativePath(self: FilesystemHandler, absolute_path: []const u8) ![]const u8 {
        if (!std.fs.path.isAbsolute(absolute_path)) return error.InvalidACPPath;
        if (!std.mem.startsWith(u8, absolute_path, self.absolute_root)) return error.ACPPathOutsideRoot;
        if (absolute_path.len > self.absolute_root.len and
            absolute_path[self.absolute_root.len] != '/' and absolute_path[self.absolute_root.len] != '\\')
            return error.ACPPathOutsideRoot;
        var relative = absolute_path[self.absolute_root.len..];
        if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
        if (relative.len == 0) return error.InvalidACPPath;
        if (std.mem.indexOf(u8, relative, "..") != null) return error.ACPPathOutsideRoot;
        return relative;
    }
};

/// Borrowed session update notification.
pub const Update = struct {
    session_id: []const u8,
    kind: []const u8,
    raw_json: []const u8,
};

pub const UpdateSink = struct {
    context: ?*anyopaque = null,
    update_fn: *const fn (context: ?*anyopaque, update: Update) anyerror!void,

    pub fn emit(self: UpdateSink, update: Update) !void {
        return self.update_fn(self.context, update);
    }
};

pub const Handlers = struct {
    permission: ?PermissionHandler = null,
    filesystem: ?FilesystemHandler = null,
    terminal: ?TerminalHandler = null,
    updates: ?UpdateSink = null,
};

pub const Session = struct {
    id: []u8,
    cwd: []u8,
    mcp_servers_json: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Session) void {
        self.gpa.free(self.mcp_servers_json);
        self.gpa.free(self.cwd);
        self.gpa.free(self.id);
        self.* = undefined;
    }
};

const State = enum { connected, initialized, closed };

/// Stateful ACP client. One value owns one connection and optional active session.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    connector: Connector,
    transport: Transport,
    implementation: Implementation = .{},
    handlers: Handlers = .{},
    reconnect_policy: ?ReconnectPolicy = null,
    cancellation: ?*const model_types.CancellationToken = null,
    timeout_ms: ?u64 = null,
    state: State = .connected,
    next_id: u64 = 1,
    capabilities: ?Capabilities = null,
    session: ?Session = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, connector: Connector) !Client {
        return .{ .gpa = gpa, .io = io, .connector = connector, .transport = try connector.open(gpa) };
    }

    pub fn deinit(self: *Client) void {
        if (self.session) |*session| session.deinit();
        if (self.state != .closed) self.transport.close();
        self.* = undefined;
    }

    pub fn initialize(self: *Client) !Capabilities {
        if (self.state != .connected) return error.InvalidACPState;
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{
            .protocolVersion = latest_protocol_version,
            .capabilities = .{
                .fs = .{ .readTextFile = true, .writeTextFile = true },
                .terminal = true,
            },
            .info = self.implementation,
        }, .{});
        defer self.gpa.free(params);
        const result = try self.request("initialize", params);
        defer self.gpa.free(result);
        const capabilities = try parseCapabilities(self.gpa, result);
        if (capabilities.protocol_version != 1 and capabilities.protocol_version != latest_protocol_version)
            return error.UnsupportedACPVersion;
        self.capabilities = capabilities;
        self.state = .initialized;
        return capabilities;
    }

    pub fn newSession(
        self: *Client,
        cwd: []const u8,
        mcp_servers_json: []const u8,
    ) ![]const u8 {
        try self.requireInitialized();
        try validateAbsolutePath(cwd);
        try validateJson(self.gpa, mcp_servers_json);
        const params = buildSessionParams(self.gpa, null, cwd, mcp_servers_json, false) catch |failure| return switch (failure) {
            error.WriteFailed => error.OutOfMemory,
            else => failure,
        };
        defer self.gpa.free(params);
        const result = try self.request("session/new", params);
        defer self.gpa.free(result);
        const id = try resultString(self.gpa, result, "sessionId");
        errdefer self.gpa.free(id);
        try self.replaceSession(id, cwd, mcp_servers_json);
        return self.session.?.id;
    }

    pub fn resumeSession(
        self: *Client,
        session_id: []const u8,
        cwd: []const u8,
        mcp_servers_json: []const u8,
        replay: bool,
    ) !void {
        try self.requireInitialized();
        try validateAbsolutePath(cwd);
        try validateJson(self.gpa, mcp_servers_json);
        const params = buildSessionParams(self.gpa, session_id, cwd, mcp_servers_json, replay) catch |failure| return switch (failure) {
            error.WriteFailed => error.OutOfMemory,
            else => failure,
        };
        defer self.gpa.free(params);
        const result = try self.request("session/resume", params);
        self.gpa.free(result);
        const id = try self.gpa.dupe(u8, session_id);
        errdefer self.gpa.free(id);
        try self.replaceSession(id, cwd, mcp_servers_json);
    }

    pub fn promptText(self: *Client, text: []const u8) !void {
        const session = self.session orelse return error.ACPSessionRequired;
        if (text.len == 0 or text.len > 1024 * 1024) return error.InvalidACPPrompt;
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{
            .sessionId = session.id,
            .prompt = &.{.{ .type = "text", .text = text }},
        }, .{});
        defer self.gpa.free(params);
        const result = try self.request("session/prompt", params);
        self.gpa.free(result);
    }

    pub fn cancel(self: *Client) !void {
        const session = self.session orelse return error.ACPSessionRequired;
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{ .sessionId = session.id }, .{});
        defer self.gpa.free(params);
        try self.notify("session/cancel", params);
    }

    pub fn cancelRequest(self: *Client, request_id: u64) !void {
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{ .id = request_id }, .{});
        defer self.gpa.free(params);
        try self.notify("$/cancel_request", params);
    }

    pub fn listSessions(self: *Client) ![]u8 {
        try self.requireInitialized();
        return self.request("session/list", "{}");
    }

    pub fn deleteSession(self: *Client, session_id: []const u8) !void {
        try self.requireInitialized();
        if (self.capabilities == null or !self.capabilities.?.session_delete)
            return error.UnsupportedACPCapability;
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{ .sessionId = session_id }, .{});
        defer self.gpa.free(params);
        const result = try self.request("session/delete", params);
        self.gpa.free(result);
    }

    pub fn closeSession(self: *Client) !void {
        const session = self.session orelse return error.ACPSessionRequired;
        const params = try std.json.Stringify.valueAlloc(self.gpa, .{ .sessionId = session.id }, .{});
        defer self.gpa.free(params);
        const result = try self.request("session/close", params);
        self.gpa.free(result);
        var owned = self.session.?;
        owned.deinit();
        self.session = null;
    }

    /// Receives and dispatches one session update, reconnecting if configured.
    pub fn nextUpdate(self: *Client) !void {
        while (true) {
            var line = self.receive() catch |failure| {
                try self.reconnect(failure);
                continue;
            };
            defer line.deinit();
            if (try self.dispatchIncoming(line.bytes, null)) return;
        }
    }

    fn request(self: *Client, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id = std.math.add(u64, id, 1) catch return error.ACPRequestIdExhausted;
        const message = try buildRequest(self.gpa, id, method, params_json);
        defer self.gpa.free(message);
        try self.send(message);
        while (true) {
            var line = try self.receive();
            defer line.deinit();
            if (try self.responseResult(line.bytes, id)) |result| return result;
            _ = try self.dispatchIncoming(line.bytes, id);
        }
    }

    fn notify(self: *Client, method: []const u8, params_json: []const u8) !void {
        const message = try buildNotification(self.gpa, method, params_json);
        defer self.gpa.free(message);
        try self.send(message);
    }

    fn send(self: *Client, message: []const u8) !void {
        const control = try model_types.RunControl.init(self.io, self.cancellation, self.timeout_ms);
        return control.invoke(void, sendTransport, .{ self.transport, message });
    }

    fn receive(self: *Client) !OwnedLine {
        const control = try model_types.RunControl.init(self.io, self.cancellation, self.timeout_ms);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var line = try control.invoke(OwnedLine, receiveTransport, .{ self.transport, arena.allocator() });
        defer line.deinit();
        return .{ .bytes = try self.gpa.dupe(u8, line.bytes), .gpa = self.gpa };
    }

    fn responseResult(self: *Client, source: []const u8, expected_id: u64) !?[]u8 {
        const parsed = try parseObject(self.gpa, source);
        defer parsed.deinit();
        const object = parsed.value.object;
        if (object.get("method") != null) return null;
        const id_value = object.get("id") orelse return null;
        if (id_value != .integer or id_value.integer < 0 or @as(u64, @intCast(id_value.integer)) != expected_id)
            return null;
        if (object.get("error")) |error_value| {
            if (error_value != .object) return error.InvalidACPMessage;
            const code = integer(error_value.object, "code") orelse 0;
            if (code == -32800) return error.ACPRequestCancelled;
            return error.ACPRemoteError;
        }
        const result = object.get("result") orelse return error.InvalidACPMessage;
        return @as(?[]u8, try std.json.Stringify.valueAlloc(self.gpa, result, .{}));
    }

    /// Returns true when a session update was delivered.
    fn dispatchIncoming(self: *Client, source: []const u8, _: ?u64) !bool {
        const parsed = try parseObject(self.gpa, source);
        defer parsed.deinit();
        const object = parsed.value.object;
        const method = string(object, "method") orelse return false;
        const params = object.get("params") orelse return error.InvalidACPMessage;
        if (std.mem.eql(u8, method, "session/update")) {
            if (params != .object) return error.InvalidACPMessage;
            const session_id = string(params.object, "sessionId") orelse return error.InvalidACPMessage;
            const update = params.object.get("update") orelse return error.InvalidACPMessage;
            if (update != .object) return error.InvalidACPMessage;
            const kind = string(update.object, "sessionUpdate") orelse return error.InvalidACPMessage;
            if (self.handlers.updates) |sink| try sink.emit(.{
                .session_id = session_id,
                .kind = kind,
                .raw_json = source,
            });
            return true;
        }
        const request_id = object.get("id") orelse return false;
        if (request_id != .integer or request_id.integer < 0) return error.InvalidACPMessage;
        const result_json = try self.handleClientRequest(method, params);
        defer self.gpa.free(result_json);
        const response = try buildResponse(self.gpa, @intCast(request_id.integer), result_json);
        defer self.gpa.free(response);
        try self.send(response);
        return false;
    }

    fn handleClientRequest(self: *Client, method: []const u8, params: std.json.Value) ![]u8 {
        if (params != .object) return error.InvalidACPMessage;
        if (std.mem.eql(u8, method, "session/request_permission"))
            return self.handlePermission(params.object);
        if (std.mem.eql(u8, method, "fs/read_text_file")) return self.handleRead(params.object);
        if (std.mem.eql(u8, method, "fs/write_text_file")) return self.handleWrite(params.object);
        if (std.mem.startsWith(u8, method, "terminal/")) {
            const handler = self.handlers.terminal orelse return error.UnsupportedACPClientMethod;
            const params_json = try std.json.Stringify.valueAlloc(self.gpa, params, .{});
            defer self.gpa.free(params_json);
            return handler.request(self.gpa, method, params_json);
        }
        return error.UnsupportedACPClientMethod;
    }

    fn handlePermission(self: *Client, params: std.json.ObjectMap) ![]u8 {
        const handler = self.handlers.permission orelse return error.UnsupportedACPClientMethod;
        const options_value = params.get("options") orelse return error.InvalidACPMessage;
        if (options_value != .array or options_value.array.items.len == 0) return error.InvalidACPMessage;
        const option_ids = try self.gpa.alloc([]const u8, options_value.array.items.len);
        defer self.gpa.free(option_ids);
        for (options_value.array.items, option_ids) |option, *id| {
            if (option != .object) return error.InvalidACPMessage;
            id.* = string(option.object, "optionId") orelse return error.InvalidACPMessage;
        }
        const subject_json = if (params.get("subject")) |subject|
            try std.json.Stringify.valueAlloc(self.gpa, subject, .{})
        else
            null;
        defer if (subject_json) |json| self.gpa.free(json);
        const selected = try handler.decide(self.gpa, .{
            .session_id = string(params, "sessionId") orelse return error.InvalidACPMessage,
            .title = string(params, "title") orelse return error.InvalidACPMessage,
            .description = optionalString(params, "description"),
            .raw_subject_json = subject_json,
            .option_ids = option_ids,
        });
        var valid = false;
        for (option_ids) |option_id| {
            if (std.mem.eql(u8, option_id, selected)) valid = true;
        }
        if (!valid) return error.InvalidACPPermissionDecision;
        return std.json.Stringify.valueAlloc(self.gpa, .{
            .outcome = .{ .outcome = "selected", .optionId = selected },
        }, .{});
    }

    fn handleRead(self: *Client, params: std.json.ObjectMap) ![]u8 {
        const filesystem = self.handlers.filesystem orelse return error.UnsupportedACPClientMethod;
        const path = string(params, "path") orelse return error.InvalidACPMessage;
        const bytes = try filesystem.environment.read(self.gpa, try filesystem.relativePath(path));
        defer self.gpa.free(bytes);
        return std.json.Stringify.valueAlloc(self.gpa, .{ .content = bytes }, .{});
    }

    fn handleWrite(self: *Client, params: std.json.ObjectMap) ![]u8 {
        const filesystem = self.handlers.filesystem orelse return error.UnsupportedACPClientMethod;
        const path = string(params, "path") orelse return error.InvalidACPMessage;
        const content = string(params, "content") orelse return error.InvalidACPMessage;
        try filesystem.environment.write(try filesystem.relativePath(path), content);
        return self.gpa.dupe(u8, "{}");
    }

    fn reconnect(self: *Client, failure: anyerror) !void {
        const policy = self.reconnect_policy orelse return failure;
        if (!self.transport.isTransportError(failure)) return failure;
        const session = self.session orelse return error.ACPSessionRequired;
        self.transport.close();
        var attempt: usize = 0;
        while (attempt < policy.max_attempts) : (attempt += 1) {
            if (policy.delay_ms > 0) try sleep(self.io, policy.delay_ms);
            self.transport = self.connector.open(self.gpa) catch continue;
            self.state = .connected;
            _ = try self.initialize();
            try self.resumeSession(session.id, session.cwd, session.mcp_servers_json, false);
            return;
        }
        return error.ACPReconnectExhausted;
    }

    fn replaceSession(
        self: *Client,
        owned_id: []u8,
        cwd: []const u8,
        mcp_servers_json: []const u8,
    ) !void {
        const owned_cwd = try self.gpa.dupe(u8, cwd);
        errdefer self.gpa.free(owned_cwd);
        const owned_mcp = try self.gpa.dupe(u8, mcp_servers_json);
        errdefer self.gpa.free(owned_mcp);
        if (self.session) |*session| session.deinit();
        self.session = .{
            .id = owned_id,
            .cwd = owned_cwd,
            .mcp_servers_json = owned_mcp,
            .gpa = self.gpa,
        };
    }

    fn requireInitialized(self: Client) !void {
        if (self.state != .initialized) return error.ACPNotInitialized;
    }
};

/// ACP stdio process transport with bounded newline frames.
pub const StdioTransport = struct {
    io: std.Io,
    child: std.process.Child,
    max_line_bytes: usize = max_message_bytes,
    closed: bool = false,

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
        self.close();
        self.* = undefined;
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{
            .context = self,
            .send_fn = send,
            .receive_fn = receive,
            .close_fn = closeTransport,
            .is_transport_error_fn = isTransportError,
        };
    }

    fn send(context: *anyopaque, line: []const u8) !void {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        if (self.closed or self.child.stdin == null) return error.ACPProcessClosed;
        if (line.len == 0 or line.len > self.max_line_bytes or std.mem.indexOfScalar(u8, line, '\n') != null)
            return error.InvalidACPMessage;
        try self.child.stdin.?.writeStreamingAll(self.io, line);
        try self.child.stdin.?.writeStreamingAll(self.io, "\n");
    }

    fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedLine {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        if (self.closed or self.child.stdout == null) return error.ACPProcessClosed;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        var byte: [1]u8 = undefined;
        while (true) {
            const count = self.child.stdout.?.readStreaming(self.io, &.{&byte}) catch |failure| return switch (failure) {
                error.EndOfStream => error.ACPProcessClosed,
                else => failure,
            };
            if (count == 0) return error.ACPProcessClosed;
            if (byte[0] == '\n') break;
            if (bytes.items.len >= self.max_line_bytes) return error.ACPMessageTooLarge;
            try bytes.append(gpa, byte[0]);
        }
        if (bytes.items.len == 0) return error.InvalidACPMessage;
        return .{ .bytes = try bytes.toOwnedSlice(gpa), .gpa = gpa };
    }

    fn close(self: *StdioTransport) void {
        if (self.closed) return;
        if (self.child.stdin) |stdin| stdin.close(self.io);
        self.child.stdin = null;
        self.child.kill(self.io);
        self.closed = true;
    }

    fn closeTransport(context: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        self.close();
    }

    fn isTransportError(_: *anyopaque, failure: anyerror) bool {
        return switch (failure) {
            error.ACPProcessClosed, error.BrokenPipe, error.EndOfStream => true,
            else => false,
        };
    }
};

fn sendTransport(transport: Transport, message: []const u8) !void {
    return transport.send(message);
}
fn receiveTransport(transport: Transport, gpa: std.mem.Allocator) !OwnedLine {
    return transport.receive(gpa);
}

fn buildRequest(gpa: std.mem.Allocator, id: u64, method: []const u8, params_json: []const u8) ![]u8 {
    const params = try parseJsonValue(gpa, params_json);
    defer params.deinit();
    return std.json.Stringify.valueAlloc(gpa, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params.value }, .{});
}

fn buildNotification(gpa: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
    const params = try parseJsonValue(gpa, params_json);
    defer params.deinit();
    return std.json.Stringify.valueAlloc(gpa, .{ .jsonrpc = "2.0", .method = method, .params = params.value }, .{});
}

fn buildResponse(gpa: std.mem.Allocator, id: u64, result_json: []const u8) ![]u8 {
    const result = try parseJsonValue(gpa, result_json);
    defer result.deinit();
    return std.json.Stringify.valueAlloc(gpa, .{ .jsonrpc = "2.0", .id = id, .result = result.value }, .{});
}

fn buildSessionParams(
    gpa: std.mem.Allocator,
    session_id: ?[]const u8,
    cwd: []const u8,
    mcp_servers_json: []const u8,
    replay: bool,
) ![]u8 {
    const servers = try parseJsonValue(gpa, mcp_servers_json);
    defer servers.deinit();
    if (servers.value != .array) return error.InvalidACPMessage;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    if (session_id) |id| {
        try json.objectField("sessionId");
        try json.write(id);
    }
    try json.objectField("cwd");
    try json.write(cwd);
    try json.objectField("mcpServers");
    try json.write(servers.value);
    if (replay) {
        try json.objectField("replayFrom");
        try json.write(.{ .type = "start" });
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn parseCapabilities(gpa: std.mem.Allocator, source: []const u8) !Capabilities {
    const parsed = try parseObject(gpa, source);
    defer parsed.deinit();
    const version_value = parsed.value.object.get("protocolVersion") orelse return error.InvalidACPMessage;
    if (version_value != .integer or version_value.integer < 0) return error.InvalidACPMessage;
    const version: u8 = @intCast(version_value.integer);
    const capabilities = parsed.value.object.get("capabilities") orelse return error.InvalidACPMessage;
    if (capabilities != .object) return error.InvalidACPMessage;
    const session = capabilities.object.get("session");
    var result = Capabilities{
        .protocol_version = version,
        .sessions = session != null and session.? == .object,
        .legacy_filesystem = version == 1,
        .legacy_terminal = version == 1,
    };
    if (session) |session_value| if (session_value == .object) {
        const session_object = session_value.object;
        if (session_object.get("prompt")) |prompt| if (prompt == .object) {
            result.prompt_images = prompt.object.get("image") != null;
            result.prompt_audio = prompt.object.get("audio") != null;
            result.embedded_context = prompt.object.get("embeddedContext") != null;
        };
        if (session_object.get("mcp")) |mcp| if (mcp == .object) {
            result.mcp_stdio = mcp.object.get("stdio") != null;
            result.mcp_http = mcp.object.get("http") != null;
        };
        result.session_delete = session_object.get("delete") != null;
        result.additional_directories = session_object.get("additionalDirectories") != null;
    };
    return result;
}

fn resultString(gpa: std.mem.Allocator, source: []const u8, field: []const u8) ![]u8 {
    const parsed = try parseObject(gpa, source);
    defer parsed.deinit();
    const value = string(parsed.value.object, field) orelse return error.InvalidACPMessage;
    return gpa.dupe(u8, value);
}

fn parseObject(gpa: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try parseJsonValue(gpa, source);
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidACPMessage;
    return parsed;
}

fn parseJsonValue(gpa: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return json_limits.parse(
        std.json.Value,
        gpa,
        source,
        .{ .max_document_bytes = max_message_bytes, .max_value_bytes = max_message_bytes, .max_depth = 64, .max_collection_items = 65_536 },
        .{ .allocate = .alloc_always },
        error.InvalidACPMessage,
    );
}

fn validateJson(gpa: std.mem.Allocator, source: []const u8) !void {
    try json_limits.validateAs(
        gpa,
        source,
        .{ .max_document_bytes = max_message_bytes, .max_value_bytes = max_message_bytes, .max_depth = 64, .max_collection_items = 65_536 },
        error.InvalidACPMessage,
    );
}

fn validateAbsolutePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidACPPath;
}

fn string(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn integer(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn sleep(io: std.Io, milliseconds: u64) !void {
    return (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64)))),
        .clock = .awake,
    } }).sleep(io);
}

test "ACP v2 initializes sessions prompts updates permissions filesystem terminals and cancellation" {
    const Fake = struct {
        lines: []const []const u8,
        index: usize = 0,
        sends: usize = 0,
        updates: usize = 0,
        permissions: usize = 0,
        terminals: usize = 0,

        fn open(context: *anyopaque, _: std.mem.Allocator) !Transport {
            return .{ .context = context, .send_fn = send, .receive_fn = receive, .close_fn = close };
        }
        fn send(context: *anyopaque, line: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(std.mem.indexOf(u8, line, "\"jsonrpc\":\"2.0\"") != null);
            self.sends += 1;
        }
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            const line = self.lines[self.index];
            self.index += 1;
            return .{ .bytes = try gpa.dupe(u8, line), .gpa = gpa };
        }
        fn close(_: *anyopaque) void {}
        fn permission(context: ?*anyopaque, _: std.mem.Allocator, request: PermissionRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("Approve?", request.title);
            self.permissions += 1;
            return "allow-once";
        }
        fn terminal(context: *anyopaque, gpa: std.mem.Allocator, method: []const u8, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("terminal/create", method);
            self.terminals += 1;
            return gpa.dupe(u8, "{\"terminalId\":\"term-1\"}");
        }
        fn update(context: ?*anyopaque, notification: Update) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("agent_message_chunk", notification.kind);
            self.updates += 1;
        }
    };
    const lines = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":2,\"capabilities\":{\"session\":{\"prompt\":{\"image\":{},\"audio\":{},\"embeddedContext\":{}},\"mcp\":{\"stdio\":{},\"http\":{}},\"delete\":{},\"additionalDirectories\":{}}},\"info\":{\"name\":\"official\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"session-1\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"sessions\":[]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"fs/read_text_file\",\"params\":{\"path\":\"/workspace/file.txt\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":91,\"method\":\"fs/write_text_file\",\"params\":{\"path\":\"/workspace/out.txt\",\"content\":\"written\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":92,\"method\":\"terminal/create\",\"params\":{\"sessionId\":\"session-1\",\"command\":\"echo\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"session-1\",\"title\":\"Approve?\",\"description\":\"Review operation\",\"options\":[{\"optionId\":\"allow-once\",\"name\":\"Allow\",\"kind\":\"allow_once\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":777,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"session-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":\"m1\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{}}",
    };
    var fake = Fake{ .lines = &lines };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "content" });
    var workspace = execution.LocalWorkspace.init(std.testing.io, temporary.dir);
    defer workspace.deinit();
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .context = &fake,
        .open_fn = Fake.open,
    });
    defer client.deinit();
    client.handlers = .{
        .permission = .{ .context = &fake, .decide_fn = Fake.permission },
        .filesystem = .{ .absolute_root = "/workspace", .environment = workspace.environment() },
        .terminal = .{ .context = &fake, .request_fn = Fake.terminal },
        .updates = .{ .context = &fake, .update_fn = Fake.update },
    };
    const capabilities = try client.initialize();
    try std.testing.expect(capabilities.sessions and capabilities.prompt_images and capabilities.mcp_stdio);
    try std.testing.expectEqualStrings("session-1", try client.newSession("/workspace", "[]"));
    const sessions = try client.listSessions();
    defer std.testing.allocator.free(sessions);
    try client.deleteSession("old-session");
    try client.promptText("hello");
    try client.nextUpdate();
    try client.cancel();
    try client.cancelRequest(3);
    try client.closeSession();
    const written = try temporary.dir.readFileAlloc(
        std.testing.io,
        "out.txt",
        std.testing.allocator,
        .limited(100),
    );
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("written", written);
    try std.testing.expectEqual(@as(usize, 1), fake.permissions);
    try std.testing.expectEqual(@as(usize, 1), fake.terminals);
    try std.testing.expectEqual(@as(usize, 1), fake.updates);
    try std.testing.expect(fake.sends >= 9);
}

test "ACP stdio process follows the official initialize session and prompt fixture" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2,"capabilities":{"session":{}},"info":{"name":"fixture","version":"1"}}}' ;;
        \\    *'"method":"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fixture-session"}}' ;;
        \\    *'"method":"session/prompt"'*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'; printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture-session","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}}}' ;;
        \\  esac
        \\done
    ;
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    try std.testing.expectError(error.InvalidACPMessage, stdio.transport().send("bad\nline"));
    try std.testing.expect(stdio.transport().isTransportError(error.ACPProcessClosed));
    const ConnectorState = struct {
        transport_value: Transport,
        fn open(context: *anyopaque, _: std.mem.Allocator) !Transport {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.transport_value;
        }
    };
    const Updates = struct {
        count: usize = 0,
        fn update(context: ?*anyopaque, notification: Update) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("state_update", notification.kind);
            self.count += 1;
        }
    };
    var connector_state = ConnectorState{ .transport_value = stdio.transport() };
    var updates: Updates = .{};
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .context = &connector_state,
        .open_fn = ConnectorState.open,
    });
    defer client.deinit();
    client.handlers.updates = .{ .context = &updates, .update_fn = Updates.update };
    _ = try client.initialize();
    _ = try client.newSession("/workspace", "[]");
    try client.promptText("hello");
    try client.nextUpdate();
    try std.testing.expectEqual(@as(usize, 1), updates.count);

    var partial = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", "printf partial" });
    defer partial.deinit();
    try std.testing.expectError(
        error.ACPProcessClosed,
        partial.transport().receive(std.testing.allocator),
    );
}

test "ACP resume reconnect renegotiates and restores the active session" {
    const ReconnectState = struct {
        lines: []const []const u8,
        index: usize = 0,
        opens: usize = 0,
        drop_next: bool = false,
        fail_open: bool = false,
        updates: usize = 0,

        fn open(context: *anyopaque, _: std.mem.Allocator) !Transport {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.opens += 1;
            if (self.fail_open) return error.ConnectFailed;
            return .{
                .context = self,
                .send_fn = send,
                .receive_fn = receive,
                .close_fn = close,
                .is_transport_error_fn = isTransportError,
            };
        }
        fn send(_: *anyopaque, _: []const u8) !void {}
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.drop_next) {
                self.drop_next = false;
                return error.TransportDropped;
            }
            const line = self.lines[self.index];
            self.index += 1;
            return .{ .bytes = try gpa.dupe(u8, line), .gpa = gpa };
        }
        fn close(_: *anyopaque) void {}
        fn isTransportError(_: *anyopaque, failure: anyerror) bool {
            return failure == error.TransportDropped;
        }
        fn update(context: ?*anyopaque, _: Update) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.updates += 1;
        }
    };
    const lines = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":2,\"capabilities\":{\"session\":{}},\"info\":{\"name\":\"agent\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"protocolVersion\":2,\"capabilities\":{\"session\":{}},\"info\":{\"name\":\"agent\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"resumed\",\"update\":{\"sessionUpdate\":\"state_update\",\"state\":\"idle\"}}}",
    };
    var state = ReconnectState{ .lines = &lines };
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .context = &state,
        .open_fn = ReconnectState.open,
    });
    defer client.deinit();
    client.reconnect_policy = .{ .max_attempts = 2, .delay_ms = 1 };
    client.handlers.updates = .{ .context = &state, .update_fn = ReconnectState.update };
    _ = try client.initialize();
    try client.resumeSession("resumed", "/workspace", "[]", true);
    state.drop_next = true;
    try client.nextUpdate();
    try std.testing.expectEqual(@as(usize, 2), state.opens);
    try std.testing.expectEqual(@as(usize, 1), state.updates);
    state.drop_next = true;
    state.fail_open = true;
    try std.testing.expectError(error.ACPReconnectExhausted, client.nextUpdate());
}

test "ACP remote errors and version negotiation fail explicitly" {
    const ErrorState = struct {
        line: []const u8,
        fn open(context: *anyopaque, _: std.mem.Allocator) !Transport {
            return .{ .context = context, .send_fn = send, .receive_fn = receive, .close_fn = close };
        }
        fn send(_: *anyopaque, _: []const u8) !void {}
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .bytes = try gpa.dupe(u8, self.line), .gpa = gpa };
        }
        fn close(_: *anyopaque) void {}
    };
    var state = ErrorState{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":3,\"capabilities\":{}}}" };
    var client = try Client.init(std.testing.allocator, std.testing.io, .{ .context = &state, .open_fn = ErrorState.open });
    defer client.deinit();
    try std.testing.expectError(error.UnsupportedACPVersion, client.initialize());
    state.line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32800,\"message\":\"cancelled\"}}";
    client.state = .connected;
    client.next_id = 2;
    try std.testing.expectError(error.ACPRequestCancelled, client.initialize());
    state.line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32000,\"message\":\"failed\"}}";
    client.state = .connected;
    client.next_id = 3;
    try std.testing.expectError(error.ACPRemoteError, client.initialize());
    state.line = "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"unknown/method\",\"params\":{}}";
    client.state = .connected;
    client.next_id = 4;
    try std.testing.expectError(error.UnsupportedACPClientMethod, client.initialize());
}

fn runACPWithAllocator(gpa: std.mem.Allocator) !void {
    const AllocationState = struct {
        lines: []const []const u8,
        index: usize = 0,
        fn open(context: *anyopaque, _: std.mem.Allocator) !Transport {
            return .{ .context = context, .send_fn = send, .receive_fn = receive, .close_fn = close };
        }
        fn send(_: *anyopaque, _: []const u8) !void {}
        fn receive(context: *anyopaque, allocator: std.mem.Allocator) !OwnedLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            const line = self.lines[self.index];
            self.index += 1;
            return .{ .bytes = try allocator.dupe(u8, line), .gpa = allocator };
        }
        fn close(_: *anyopaque) void {}
    };
    const lines = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":2,\"capabilities\":{\"session\":{}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}",
    };
    var state = AllocationState{ .lines = &lines };
    var client = try Client.init(gpa, std.testing.io, .{ .context = &state, .open_fn = AllocationState.open });
    defer client.deinit();
    _ = try client.initialize();
    _ = try client.newSession("/workspace", "[]");
    try client.resumeSession("session", "/workspace", "[]", true);
}

test "ACP ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runACPWithAllocator,
        .{},
    );
}

test "ACP v1 capability compatibility path and filesystem roots fail closed" {
    const Handler = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![]u8 {
            return gpa.dupe(u8, "");
        }
        fn write(_: *anyopaque, _: []const u8, _: []const u8) !void {}
        fn remove(_: *anyopaque, _: []const u8) !void {}
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: execution.Command) !execution.CommandResult { // kcov-ignore: path-only handler
            return error.Unsupported; // kcov-ignore: path-only handler
        }
    };
    var marker: u8 = 0;
    const filesystem = FilesystemHandler{
        .absolute_root = "/workspace",
        .environment = .{
            .context = &marker,
            .profile = .{},
            .read_fn = Handler.read,
            .write_fn = Handler.write,
            .remove_fn = Handler.remove,
            .execute_fn = Handler.execute,
        },
    };
    try std.testing.expectEqualStrings("src/main.zig", try filesystem.relativePath("/workspace/src/main.zig"));
    try std.testing.expectError(error.ACPPathOutsideRoot, filesystem.relativePath("/workspace-other/file"));
    const bytes = try filesystem.environment.read(std.testing.allocator, "file");
    defer std.testing.allocator.free(bytes);
    try filesystem.environment.write("file", "value");
    try filesystem.environment.remove("file");
    try std.testing.expectError(error.InvalidACPMessage, parseCapabilities(std.testing.allocator, "[]"));
    const capabilities = try parseCapabilities(
        std.testing.allocator,
        "{\"protocolVersion\":1,\"capabilities\":{\"session\":{}}}",
    );
    try std.testing.expect(capabilities.legacy_filesystem and capabilities.legacy_terminal);
}
