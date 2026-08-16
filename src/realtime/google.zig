//! Google Gemini Live protocol over a raw WebSocket channel.

const std = @import("std");
const base = @import("base.zig");
const json_limits = @import("../json.zig");
const wire = @import("wire.zig");

/// Borrowed Gemini Live connector state.
pub const Connector = struct {
    gpa: ?std.mem.Allocator = null,
    dialer: wire.Dialer,
    model_name: []const u8,
    instructions: ?[]const u8 = null,
    channel: ?wire.Channel = null,

    pub fn connector(self: *Connector) base.Connector {
        return .{ .context = self, .connect_fn = connect };
    }

    fn connect(context: *anyopaque, gpa: std.mem.Allocator) !base.Connection {
        const self: *Connector = @ptrCast(@alignCast(context));
        if (self.model_name.len == 0) return error.InvalidRealtimeConfiguration;
        self.gpa = gpa;
        self.channel = try self.dialer.open(gpa);
        if (self.channel.?.kind != .websocket) return error.UnsupportedRealtimeTransport;
        try self.sendSetup();
        return .{
            .context = self,
            .transport_kind = .websocket,
            .profile = .{
                .audio_input_sample_rate = 16_000,
                .audio_output_sample_rate = 24_000,
                .supports_image_input = true,
                .supports_session_seeding = true,
                .reconnect_restores_state = true,
            },
            .provider_name = "gcp.gen_ai",
            .model_name = self.model_name,
            .send_fn = send,
            .receive_fn = receive,
            .close_fn = close,
            .is_transport_error_fn = isTransportError,
        };
    }

    fn sendSetup(self: *Connector) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .setup = .{
                .model = self.model_name,
                .system_instruction = if (self.instructions) |text| .{
                    .parts = &.{.{ .text = text }},
                } else null,
                .generation_config = .{ .response_modalities = &.{"AUDIO"} },
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn send(context: *anyopaque, input: base.Input) !void {
        const self: *Connector = @ptrCast(@alignCast(context));
        switch (input) {
            .text => |text| try self.sendText(text),
            .audio => |audio| try self.sendMedia("audio/pcm;rate=16000", audio),
            .image => |image| {
                const bytes = switch (image.source) {
                    .bytes => |value| value,
                    else => return error.UnsupportedRealtimeContent,
                };
                try self.sendMedia(image.media_type, bytes);
            },
            .tool_result => |result| try self.sendToolResult(result),
            else => return error.UnsupportedRealtimeOperation,
        }
    }

    fn sendText(self: *Connector, text: []const u8) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .client_content = .{
                .turns = &.{.{ .role = "user", .parts = &.{.{ .text = text }} }},
                .turn_complete = true,
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendMedia(self: *Connector, mime_type: []const u8, bytes: []const u8) !void {
        const encoded = try encodeBase64(self.gpa.?, bytes);
        defer self.gpa.?.free(encoded);
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .realtime_input = .{
                .media_chunks = &.{.{ .mime_type = mime_type, .data = encoded }},
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendToolResult(self: *Connector, result: base.ToolResult) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .tool_response = .{
                .function_responses = &.{.{
                    .id = result.call_id,
                    .name = result.name,
                    .response = .{ .output = result.output },
                }},
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn receive(context: *anyopaque, gpa: std.mem.Allocator) !base.OwnedCodecEvent {
        const self: *Connector = @ptrCast(@alignCast(context));
        var frame = try self.channel.?.receive(gpa);
        defer frame.deinit();
        return switch (frame.value) {
            .text => |text| self.decode(gpa, text),
            .binary => error.InvalidRealtimeFrame,
            .closed => error.RealtimeConnectionClosed,
        };
    }

    fn decode(self: *Connector, gpa: std.mem.Allocator, source: []const u8) !base.OwnedCodecEvent {
        const parsed = try json_limits.parse(
            std.json.Value,
            gpa,
            source,
            json_limits.defaults.provider_response,
            .{ .allocate = .alloc_always },
            error.InvalidRealtimeFrame,
        );
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRealtimeFrame;
        const object = parsed.value.object;
        if (object.get("setupComplete") != null) return receive(self, gpa);
        if (object.get("usageMetadata")) |usage_value| {
            if (usage_value != .object) return error.InvalidRealtimeFrame;
            return base.OwnedCodecEvent.copy(gpa, .{ .usage = .{
                .input_tokens = integerField(usage_value.object, "promptTokenCount"),
                .output_tokens = integerField(usage_value.object, "responseTokenCount"),
            } });
        }
        if (object.get("toolCall")) |tool_value| return decodeTool(gpa, tool_value);
        if (object.get("toolCallCancellation")) |cancel_value| return decodeCancellation(gpa, cancel_value);
        if (object.get("serverContent")) |content_value| return self.decodeContent(gpa, content_value);
        if (object.get("goAway")) |_| return base.OwnedCodecEvent.copy(gpa, .{ .session_error = .{
            .code = "go_away",
            .message = "Gemini Live requested connection renewal.",
            .recoverable = true,
        } });
        if (object.get("sessionResumptionUpdate") != null) return receive(self, gpa);
        return error.UnsupportedRealtimeEvent;
    }

    fn decodeContent(
        _: *Connector,
        gpa: std.mem.Allocator,
        content_value: std.json.Value,
    ) !base.OwnedCodecEvent {
        if (content_value != .object) return error.InvalidRealtimeFrame;
        const content = content_value.object;
        if (content.get("inputTranscription")) |value| return decodeTranscript(gpa, value, .input_transcript);
        if (content.get("outputTranscription")) |value| return decodeTranscript(gpa, value, .output_transcript);
        if (booleanField(content, "interrupted"))
            return base.OwnedCodecEvent.copy(gpa, .response_interrupted);
        if (booleanField(content, "turnComplete"))
            return base.OwnedCodecEvent.copy(gpa, .{ .response_done = .{} });
        const turn_value = content.get("modelTurn") orelse return error.UnsupportedRealtimeEvent;
        if (turn_value != .object) return error.InvalidRealtimeFrame;
        const parts_value = turn_value.object.get("parts") orelse return error.InvalidRealtimeFrame;
        if (parts_value != .array or parts_value.array.items.len == 0) return error.InvalidRealtimeFrame;
        const part = parts_value.array.items[0];
        if (part != .object) return error.InvalidRealtimeFrame;
        if (part.object.get("text")) |text| {
            if (text != .string) return error.InvalidRealtimeFrame;
            return base.OwnedCodecEvent.copy(gpa, .{ .output_transcript = .{
                .text = text.string,
                .final = false,
            } });
        }
        const inline_data = part.object.get("inlineData") orelse return error.UnsupportedRealtimeEvent;
        if (inline_data != .object) return error.InvalidRealtimeFrame;
        const encoded = stringField(inline_data.object, "data") orelse return error.InvalidRealtimeFrame;
        const audio = try decodeBase64(gpa, encoded);
        defer gpa.free(audio);
        return base.OwnedCodecEvent.copy(gpa, .{ .audio_delta = .{ .bytes = audio } });
    }

    fn close(context: *anyopaque) void {
        const self: *Connector = @ptrCast(@alignCast(context));
        if (self.channel) |channel| channel.close();
        self.channel = null;
    }

    fn isTransportError(context: *anyopaque, failure: anyerror) bool {
        const self: *Connector = @ptrCast(@alignCast(context));
        if (failure == error.RealtimeConnectionClosed) return true;
        return if (self.channel) |channel| channel.isTransportError(failure) else false;
    }
};

fn decodeTranscript(
    gpa: std.mem.Allocator,
    value: std.json.Value,
    comptime tag: std.meta.Tag(base.CodecEvent),
) !base.OwnedCodecEvent {
    if (value != .object) return error.InvalidRealtimeFrame;
    const text = stringField(value.object, "text") orelse return error.InvalidRealtimeFrame;
    return switch (tag) {
        .input_transcript => base.OwnedCodecEvent.copy(gpa, .{ .input_transcript = .{ .text = text, .final = true } }),
        .output_transcript => base.OwnedCodecEvent.copy(gpa, .{ .output_transcript = .{ .text = text, .final = true } }),
        else => @compileError("transcript tag required"),
    };
}

fn decodeTool(gpa: std.mem.Allocator, value: std.json.Value) !base.OwnedCodecEvent {
    if (value != .object) return error.InvalidRealtimeFrame;
    const calls = value.object.get("functionCalls") orelse return error.InvalidRealtimeFrame;
    if (calls != .array or calls.array.items.len == 0) return error.InvalidRealtimeFrame;
    const call = calls.array.items[0];
    if (call != .object) return error.InvalidRealtimeFrame;
    const arguments = call.object.get("args") orelse return error.InvalidRealtimeFrame;
    const arguments_json = try std.json.Stringify.valueAlloc(gpa, arguments, .{});
    defer gpa.free(arguments_json);
    return base.OwnedCodecEvent.copy(gpa, .{ .tool_call = .{
        .id = stringField(call.object, "id") orelse return error.InvalidRealtimeFrame,
        .name = stringField(call.object, "name") orelse return error.InvalidRealtimeFrame,
        .arguments_json = arguments_json,
    } });
}

fn decodeCancellation(gpa: std.mem.Allocator, value: std.json.Value) !base.OwnedCodecEvent {
    if (value != .object) return error.InvalidRealtimeFrame;
    const ids = value.object.get("ids") orelse return error.InvalidRealtimeFrame;
    if (ids != .array) return error.InvalidRealtimeFrame;
    const copies = try gpa.alloc([]const u8, ids.array.items.len);
    defer gpa.free(copies);
    for (ids.array.items, copies) |item, *copy| {
        if (item != .string) return error.InvalidRealtimeFrame;
        copy.* = item.string;
    }
    return base.OwnedCodecEvent.copy(gpa, .{ .tool_cancelled = copies });
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) u64 {
    const value = object.get(name) orelse return 0;
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else 0;
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn encodeBase64(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    _ = std.base64.standard.Encoder.encode(encoded, source);
    return encoded;
}

fn decodeBase64(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(source) catch return error.InvalidRealtimeFrame;
    const decoded = try gpa.alloc(u8, size);
    errdefer gpa.free(decoded);
    std.base64.standard.Decoder.decode(decoded, source) catch return error.InvalidRealtimeFrame;
    return decoded;
}

test "Gemini Live drives audio transcripts tools turns usage and images" {
    const State = struct {
        frames: []const wire.Frame,
        index: usize = 0,
        sent: usize = 0,

        fn open(context: *anyopaque, _: std.mem.Allocator) !wire.Channel {
            return .{
                .context = context,
                .kind = .websocket,
                .send_text_fn = sendText,
                .receive_fn = receive,
                .close_fn = close,
                .is_transport_error_fn = isTransportError,
            };
        }
        fn sendText(context: *anyopaque, text: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(text.len > 2);
            self.sent += 1;
        }
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !wire.OwnedFrame {
            const self: *@This() = @ptrCast(@alignCast(context));
            const frame = self.frames[self.index];
            self.index += 1;
            return wire.OwnedFrame.copy(gpa, frame);
        }
        fn close(_: *anyopaque) void {}
        fn isTransportError(_: *anyopaque, failure: anyerror) bool {
            return failure == error.TransportDropped;
        }
        fn tool(_: ?*anyopaque, gpa: std.mem.Allocator, _: base.CodecEvent.ToolCall) ![]u8 {
            return gpa.dupe(u8, "result");
        }
    };
    const frames = [_]wire.Frame{
        .{ .text = "{\"setupComplete\":{}}" },
        .{ .text = "{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"inlineData\":{\"data\":\"AQI=\"}}]}}}" },
        .{ .text = "{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"text\":\"partial\"}]}}}" },
        .{ .text = "{\"serverContent\":{\"inputTranscription\":{\"text\":\"hi\"}}}" },
        .{ .text = "{\"serverContent\":{\"outputTranscription\":{\"text\":\"hello\"}}}" },
        .{ .text = "{\"toolCall\":{\"functionCalls\":[{\"id\":\"c1\",\"name\":\"tool\",\"args\":{}}]}}" },
        .{ .text = "{\"toolCallCancellation\":{\"ids\":[\"c2\"]}}" },
        .{ .text = "{\"usageMetadata\":{\"promptTokenCount\":2,\"responseTokenCount\":3}}" },
        .{ .text = "{\"serverContent\":{\"interrupted\":true}}" },
        .{ .text = "{\"goAway\":{}}" },
        .{ .text = "{\"sessionResumptionUpdate\":{\"newHandle\":\"h\"}}" },
        .{ .text = "{\"serverContent\":{\"turnComplete\":true}}" },
    };
    var state = State{ .frames = &frames };
    var protocol = Connector{
        .dialer = .{ .context = &state, .open_fn = State.open },
        .model_name = "models/gemini-live",
        .instructions = "Be concise.",
    };
    var session = try base.Session.init(std.testing.allocator, protocol.connector(), .{
        .tool_handler = .{ .execute_fn = State.tool },
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(u32, 16_000), session.profile().audio_input_sample_rate);
    try session.sendText("question");
    try session.sendAudio("\x00\x00");
    try session.sendImage(.{ .source = .{ .bytes = "jpeg" }, .media_type = "image/jpeg" });
    const expected = [_]std.meta.Tag(base.Event){
        .audio,
        .output_transcript,
        .input_transcript,
        .output_transcript,
        .tool,
        .session_error,
        .response_interrupted,
        .session_error,
        .turn_complete,
    };
    for (expected) |tag| {
        var event = try session.next(std.testing.allocator);
        defer event.deinit();
        try std.testing.expectEqual(tag, std.meta.activeTag(event.value));
    }
    try std.testing.expectEqual(@as(u64, 5), session.usage().totalTokens());
    try std.testing.expect(state.sent >= 5);
    try std.testing.expect(session.connection.isTransportError(error.TransportDropped));
}
