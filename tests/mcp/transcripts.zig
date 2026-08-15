//! Cassetter-style YAML recording and replay for MCP JSON-RPC transcripts.

const std = @import("std");
const yaml = @import("yaml");
const zigai = @import("zigai");
const cassette_format = @import("../support/cassettes/format.zig");

pub const TransportKind = enum { stdio, http };

pub const Source = struct {
    server: []const u8,
    revision: []const u8,
};

pub const Request = struct {
    method: []const u8,
    message: []const u8,
};

pub const Interaction = struct {
    request: Request,
    events: []const []const u8 = &.{},
    response: []const u8,
};

pub const Transcript = struct {
    version: u8 = 1,
    protocol_version: []const u8,
    source: Source,
    transport: TransportKind,
    interactions: []const Interaction,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    value: Transcript,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Parsed {
    var document = try yaml.loadWithOptions(allocator, source, .{
        .schema = .core,
        .duplicate_key_behavior = .reject,
        .unknown_tag_behavior = .reject,
        .max_input_bytes = 64 * 1024 * 1024,
        .max_nesting_depth = 256,
    });
    defer document.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = try requireMapping(document.root);
    const version = try integerAs(u8, try requireField(root, "version"));
    if (version != 1) return error.UnsupportedTranscriptVersion;
    const protocol_version = try memory.dupe(u8, try requireScalar(try requireField(root, "protocol_version")));
    if (!std.mem.eql(u8, protocol_version, zigai.mcp.protocol_version)) return error.UnsupportedProtocolVersion;
    const source_value = try requireMapping(try requireField(root, "source"));
    const source_info = Source{
        .server = try memory.dupe(u8, try requireScalar(try requireField(source_value, "server"))),
        .revision = try memory.dupe(u8, try requireScalar(try requireField(source_value, "revision"))),
    };
    try validateSource(source_info);
    const transport = std.meta.stringToEnum(
        TransportKind,
        try requireScalar(try requireField(root, "transport")),
    ) orelse return error.InvalidTranscript;
    const interaction_nodes = try requireSequence(try requireField(root, "interactions"));
    if (interaction_nodes.items.len == 0) return error.EmptyTranscript;
    const interactions = try memory.alloc(Interaction, interaction_nodes.items.len);
    for (interaction_nodes.items, interactions) |node, *interaction| {
        const value = try requireMapping(node);
        const request_value = try requireMapping(try requireField(value, "request"));
        const method = try memory.dupe(u8, try requireScalar(try requireField(request_value, "method")));
        const message = try cassette_format.parseBody(memory, try requireField(request_value, "message"));
        const response = try cassette_format.parseBody(memory, try requireField(value, "response"));
        const events = if (field(value, "events")) |events_node|
            try parseEvents(memory, events_node)
        else
            &.{};
        try validateInteraction(memory, method, message, events, response);
        interaction.* = .{
            .request = .{ .method = method, .message = message },
            .events = events,
            .response = response,
        };
    }
    return .{ .arena = arena, .value = .{
        .protocol_version = protocol_version,
        .source = source_info,
        .transport = transport,
        .interactions = interactions,
    } };
}

pub fn stringify(allocator: std.mem.Allocator, transcript: Transcript) ![]u8 {
    if (transcript.version != 1) return error.UnsupportedTranscriptVersion;
    if (!std.mem.eql(u8, transcript.protocol_version, zigai.mcp.protocol_version)) {
        return error.UnsupportedProtocolVersion;
    }
    try validateSource(transcript.source);
    if (transcript.interactions.len == 0) return error.EmptyTranscript;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print("version: 1\nprotocol_version: \"{s}\"\nsource:\n  server: ", .{transcript.protocol_version});
    try writeQuoted(writer, transcript.source.server);
    try writer.writeAll("\n  revision: ");
    try writeQuoted(writer, transcript.source.revision);
    try writer.print("\ntransport: {s}\ninteractions:\n", .{@tagName(transcript.transport)});
    for (transcript.interactions) |interaction| {
        try validateInteraction(allocator, interaction.request.method, interaction.request.message, interaction.events, interaction.response);
        try writer.writeAll("- request:\n    method: ");
        try writeQuoted(writer, interaction.request.method);
        try writer.writeAll("\n    message:\n");
        try cassette_format.writeBody(allocator, writer, interaction.request.message, 6);
        if (interaction.events.len == 0) {
            try writer.writeAll("  events: []\n");
        } else {
            try writer.writeAll("  events:\n");
            for (interaction.events) |event| {
                try writer.writeAll("  -\n");
                try cassette_format.writeBody(allocator, writer, event, 4);
            }
        }
        try writer.writeAll("  response:\n");
        try cassette_format.writeBody(allocator, writer, interaction.response, 4);
    }
    return output.toOwnedSlice();
}

pub const ReplayTransport = struct {
    parsed: Parsed,
    next_interaction: usize = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !ReplayTransport {
        return .{ .parsed = try parse(allocator, source) };
    }

    pub fn deinit(self: *ReplayTransport) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *ReplayTransport) zigai.mcp.Transport {
        return .{ .context = self, .sendFn = send };
    }

    pub fn remaining(self: *const ReplayTransport) usize {
        return self.parsed.value.interactions.len - self.next_interaction;
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: zigai.mcp.WireRequest) ![]const u8 {
        const self: *ReplayTransport = @ptrCast(@alignCast(context));
        if (self.next_interaction >= self.parsed.value.interactions.len) return error.TranscriptExhausted;
        const interaction = self.parsed.value.interactions[self.next_interaction];
        if (!std.mem.eql(u8, request.method, interaction.request.method) or
            !std.mem.eql(u8, request.message, interaction.request.message))
        {
            return error.TranscriptMismatch;
        }
        if (interaction.events.len > 0 and request.events == null) return error.TranscriptEventSinkMissing;
        for (interaction.events) |event| try request.events.?.emit(event);
        self.next_interaction += 1;
        return allocator.dupe(u8, interaction.response);
    }
};

pub const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    inner: zigai.mcp.Transport,
    source: Source,
    transport_kind: TransportKind,
    interactions: std.ArrayList(OwnedInteraction) = .empty,

    const OwnedInteraction = struct {
        method: []u8,
        message: []u8,
        events: std.ArrayList([]const u8) = .empty,
        response: []u8,

        fn deinit(self: *OwnedInteraction, allocator: std.mem.Allocator) void {
            allocator.free(self.method);
            allocator.free(self.message);
            for (self.events.items) |event| allocator.free(event);
            self.events.deinit(allocator);
            allocator.free(self.response);
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        inner: zigai.mcp.Transport,
        source: Source,
        transport_kind: TransportKind,
    ) RecordingTransport {
        return .{
            .allocator = allocator,
            .inner = inner,
            .source = source,
            .transport_kind = transport_kind,
        };
    }

    pub fn deinit(self: *RecordingTransport) void {
        for (self.interactions.items) |*interaction| interaction.deinit(self.allocator);
        self.interactions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *RecordingTransport) zigai.mcp.Transport {
        return .{ .context = self, .sendFn = send };
    }

    pub fn transcriptYaml(self: *const RecordingTransport, allocator: std.mem.Allocator) ![]u8 {
        const interactions = try allocator.alloc(Interaction, self.interactions.items.len);
        defer allocator.free(interactions);
        for (self.interactions.items, interactions) |owned, *interaction| interaction.* = .{
            .request = .{ .method = owned.method, .message = owned.message },
            .events = owned.events.items,
            .response = owned.response,
        };
        return stringify(allocator, .{
            .protocol_version = zigai.mcp.protocol_version,
            .source = self.source,
            .transport = self.transport_kind,
            .interactions = interactions,
        });
    }

    pub fn writeTranscriptAtomic(
        self: *const RecordingTransport,
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        const text = try self.transcriptYaml(allocator);
        defer allocator.free(text);
        var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(text);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.replace(io);
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: zigai.mcp.WireRequest) ![]const u8 {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        var events: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (events.items) |event| self.allocator.free(event);
            events.deinit(self.allocator);
        }
        var capture = EventCapture{
            .allocator = self.allocator,
            .events = &events,
            .downstream = request.events,
        };
        var forwarded = request;
        forwarded.events = capture.eventSink();
        const response = try self.inner.send(allocator, forwarded);
        errdefer allocator.free(response);
        const method = try self.allocator.dupe(u8, request.method);
        errdefer self.allocator.free(method);
        const message = try self.allocator.dupe(u8, request.message);
        errdefer self.allocator.free(message);
        const response_copy = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(response_copy);
        try self.interactions.append(self.allocator, .{
            .method = method,
            .message = message,
            .events = events,
            .response = response_copy,
        });
        return response;
    }
};

const EventCapture = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList([]const u8),
    downstream: ?zigai.mcp.EventSink,

    fn eventSink(self: *EventCapture) zigai.mcp.EventSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, message: []const u8) !void {
        const self: *EventCapture = @ptrCast(@alignCast(context));
        if (self.downstream) |downstream| try downstream.emit(message);
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try self.events.append(self.allocator, copy);
    }
};

fn parseEvents(allocator: std.mem.Allocator, node: *const yaml.Node) ![]const []const u8 {
    const sequence = try requireSequence(node);
    const events = try allocator.alloc([]const u8, sequence.items.len);
    for (sequence.items, events) |event_node, *event| event.* = try cassette_format.parseBody(allocator, event_node);
    return events;
}

fn validateSource(source: Source) !void {
    if (source.server.len == 0 or source.revision.len != 40) return error.InvalidTranscriptSource;
    for (source.revision) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
        return error.InvalidTranscriptSource;
    };
}

fn validateInteraction(
    allocator: std.mem.Allocator,
    method: []const u8,
    message: []const u8,
    events: []const []const u8,
    response: []const u8,
) !void {
    if (method.len == 0) return error.InvalidTranscript;
    var request_json = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return error.InvalidTranscript;
    defer request_json.deinit();
    const object = switch (request_json.value) {
        .object => |value| value,
        else => return error.InvalidTranscript,
    };
    const recorded_method = switch (object.get("method") orelse return error.InvalidTranscript) {
        .string => |value| value,
        else => return error.InvalidTranscript,
    };
    if (!std.mem.eql(u8, method, recorded_method)) return error.InvalidTranscript;
    for (events) |event| try validateJson(allocator, event);
    try validateJson(allocator, response);
}

fn validateJson(allocator: std.mem.Allocator, source: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidTranscript;
    defer parsed.deinit();
}

fn requireMapping(node: *const yaml.Node) !yaml.MappingNode {
    return switch (node.*) {
        .mapping => |value| value,
        else => error.InvalidTranscript,
    };
}

fn requireSequence(node: *const yaml.Node) !yaml.SequenceNode {
    return switch (node.*) {
        .sequence => |value| value,
        else => error.InvalidTranscript,
    };
}

fn requireScalar(node: *const yaml.Node) ![]const u8 {
    return switch (node.*) {
        .scalar => |value| value.value,
        else => error.InvalidTranscript,
    };
}

fn integerAs(comptime T: type, node: *const yaml.Node) !T {
    return switch (node.*) {
        .int_value => |value| std.math.cast(T, value.value) orelse error.InvalidTranscript,
        .scalar => |value| std.fmt.parseInt(T, value.value, 10) catch error.InvalidTranscript,
        else => error.InvalidTranscript,
    };
}

fn requireField(mapping: yaml.MappingNode, name: []const u8) !*const yaml.Node {
    return field(mapping, name) orelse error.InvalidTranscript;
}

fn field(mapping: yaml.MappingNode, name: []const u8) ?*const yaml.Node {
    for (mapping.pairs) |pair| {
        const key = switch (pair.key.*) {
            .scalar => |value| value.value,
            else => continue,
        };
        if (std.mem.eql(u8, key, name)) return pair.value;
    }
    return null;
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}

test "MCP transcript YAML round trips and replays events before responses" {
    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}";
    const event = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}";
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}";
    const text = try stringify(std.testing.allocator, .{
        .protocol_version = zigai.mcp.protocol_version,
        .source = .{ .server = "typescript-todos", .revision = "0123456789abcdef0123456789abcdef01234567" },
        .transport = .stdio,
        .interactions = &.{.{
            .request = .{ .method = "tools/list", .message = request },
            .events = &.{event},
            .response = response,
        }},
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "type: json") != null);

    const Capture = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, message: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            try std.testing.expectEqualStrings(event, message);
        }
    };
    var replay = try ReplayTransport.init(std.testing.allocator, text);
    defer replay.deinit();
    var capture: Capture = .{};
    const actual = try replay.transport().send(std.testing.allocator, .{
        .method = "tools/list",
        .message = request,
        .events = .{ .context = &capture, .eventFn = Capture.emit },
    });
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(response, actual);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), replay.remaining());
}

test "MCP transcript replay rejects drift exhaustion and missing event sinks" {
    const source =
        \\version: 1
        \\protocol_version: "2026-07-28"
        \\source:
        \\  server: reference
        \\  revision: 0123456789abcdef0123456789abcdef01234567
        \\transport: http
        \\interactions:
        \\- request:
        \\    method: server/discover
        \\    message:
        \\      type: json
        \\      content: {jsonrpc: "2.0", id: 1, method: server/discover, params: {}}
        \\  events:
        \\  -
        \\    type: json
        \\    content: {jsonrpc: "2.0", method: notifications/progress, params: {progress: 1}}
        \\  response:
        \\    type: json
        \\    content: {jsonrpc: "2.0", id: 1, result: {}}
    ;
    var replay = try ReplayTransport.init(std.testing.allocator, source);
    defer replay.deinit();
    try std.testing.expectError(error.TranscriptMismatch, replay.transport().send(std.testing.allocator, .{
        .method = "tools/list",
        .message = "{}",
    }));
    try std.testing.expectError(error.TranscriptEventSinkMissing, replay.transport().send(std.testing.allocator, .{
        .method = "server/discover",
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{}}",
    }));
}

test "MCP transcript recorder captures events without requiring a downstream sink" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: zigai.mcp.WireRequest) ![]const u8 {
            try request.events.?.emit("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}");
            return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
        }
    };
    var unused: u8 = 0;
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        .{ .context = &unused, .sendFn = Stub.send },
        .{ .server = "reference", .revision = "0123456789abcdef0123456789abcdef01234567" },
        .http,
    );
    defer recorder.deinit();
    const response = try recorder.transport().send(std.testing.allocator, .{
        .method = "server/discover",
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{}}",
    });
    defer std.testing.allocator.free(response);
    const text = try recorder.transcriptYaml(std.testing.allocator);
    defer std.testing.allocator.free(text);
    var replay = try ReplayTransport.init(std.testing.allocator, text);
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.parsed.value.interactions[0].events.len);
}

test "MCP transcript recorder atomically replaces nested fixture paths" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: zigai.mcp.WireRequest) ![]const u8 {
            return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
        }
    };
    var unused: u8 = 0;
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        .{ .context = &unused, .sendFn = Stub.send },
        .{ .server = "reference", .revision = "0123456789abcdef0123456789abcdef01234567" },
        .stdio,
    );
    defer recorder.deinit();
    const response = try recorder.transport().send(std.testing.allocator, .{
        .method = "server/discover",
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{}}",
    });
    defer std.testing.allocator.free(response);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try recorder.writeTranscriptAtomic(std.testing.allocator, std.testing.io, temporary.dir, "nested/transcript.yaml");
    try recorder.writeTranscriptAtomic(std.testing.allocator, std.testing.io, temporary.dir, "nested/transcript.yaml");
    const written = try temporary.dir.readFileAlloc(
        std.testing.io,
        "nested/transcript.yaml",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "server/discover") != null);
}
