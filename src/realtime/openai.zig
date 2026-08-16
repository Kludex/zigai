//! OpenAI Realtime protocol shared by OpenAI, Azure OpenAI, and xAI.

const std = @import("std");
const base = @import("base.zig");
const json_limits = @import("../json.zig");
const transport = @import("../transport.zig");
const wire = @import("wire.zig");

/// OpenAI-protocol provider dialect.
pub const Dialect = enum {
    openai,
    azure,
    xai,
};

/// Creates an OpenAI realtime connector for an authenticated raw channel.
pub fn init(dialer: wire.Dialer, model_name: []const u8) Connector {
    return .{
        .dialer = dialer,
        .dialect = .openai,
        .model_name = model_name,
    };
}

/// Borrowed connector state. One connector serves one active session at a time.
pub const Connector = struct {
    gpa: ?std.mem.Allocator = null,
    dialer: wire.Dialer,
    dialect: Dialect,
    model_name: []const u8,
    instructions: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    channel: ?wire.Channel = null,
    pending_done: ?base.CodecEvent.ResponseDone = null,
    pending_response_id: ?transport.MetadataText = null,

    pub fn connector(self: *Connector) base.Connector {
        return .{ .context = self, .connect_fn = connect };
    }

    fn connect(context: *anyopaque, gpa: std.mem.Allocator) !base.Connection {
        const self: *Connector = @ptrCast(@alignCast(context));
        if (self.model_name.len == 0) return error.InvalidRealtimeConfiguration;
        self.gpa = gpa;
        self.channel = try self.dialer.open(gpa);
        self.pending_done = null;
        try self.sendConfiguration();
        return .{
            .context = self,
            .transport_kind = self.channel.?.kind,
            .profile = switch (self.dialect) {
                .openai, .azure => .{
                    .supports_image_input = true,
                    .supports_manual_turn_control = true,
                    .supports_output_truncation = true,
                    .supports_session_seeding = true,
                },
                .xai => .{
                    .supports_manual_turn_control = true,
                    .supports_output_truncation = true,
                    .supports_session_seeding = true,
                    .reconnect_restores_state = true,
                },
            },
            .provider_name = switch (self.dialect) {
                .openai => "openai",
                .azure => "azure",
                .xai => "xai",
            },
            .model_name = self.model_name,
            .send_fn = send,
            .receive_fn = receive,
            .close_fn = close,
            .is_transport_error_fn = isTransportError,
        };
    }

    fn sendConfiguration(self: *Connector) !void {
        const gpa = self.gpa.?;
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        try json.beginObject();
        try json.objectField("type");
        try json.write("session.update");
        try json.objectField("session");
        try json.beginObject();
        try json.objectField("type");
        try json.write("realtime");
        try json.objectField("model");
        try json.write(self.model_name);
        if (self.instructions) |instructions| {
            try json.objectField("instructions");
            try json.write(instructions);
        }
        if (self.voice) |voice| {
            try json.objectField("audio");
            try json.beginObject();
            try json.objectField("output");
            try json.beginObject();
            try json.objectField("voice");
            try json.write(voice);
            try json.endObject();
            try json.endObject();
        }
        try json.endObject();
        try json.endObject();
        const message = try output.toOwnedSlice();
        defer gpa.free(message);
        try self.channel.?.sendText(message);
    }

    fn send(context: *anyopaque, input: base.Input) !void {
        const self: *Connector = @ptrCast(@alignCast(context));
        const gpa = self.gpa.?;
        switch (input) {
            .text => |text| {
                try self.sendConversationText(text);
                try self.sendSimple("response.create");
            },
            .audio => |audio| try self.sendBase64("input_audio_buffer.append", "audio", audio),
            .image => |image| {
                const bytes = switch (image.source) {
                    .bytes => |value| value,
                    else => return error.UnsupportedRealtimeContent,
                };
                const encoded = try encodeBase64(gpa, bytes);
                defer gpa.free(encoded);
                const data_url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ image.media_type, encoded });
                defer gpa.free(data_url);
                try self.sendImage(data_url);
            },
            .tool_result => |result| try self.sendToolResult(result),
            .commit_audio => try self.sendSimple("input_audio_buffer.commit"),
            .clear_audio => try self.sendSimple("input_audio_buffer.clear"),
            .create_response => try self.sendSimple("response.create"),
            .cancel_response => try self.sendSimple("response.cancel"),
            .truncate_output_ms => |milliseconds| try self.sendTruncate(milliseconds),
        }
    }

    fn sendSimple(self: *Connector, event_type: []const u8) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{ .type = event_type }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendConversationText(self: *Connector, text: []const u8) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .type = "conversation.item.create",
            .item = .{
                .type = "message",
                .role = "user",
                .content = &.{.{ .type = "input_text", .text = text }},
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendBase64(self: *Connector, event_type: []const u8, field: []const u8, bytes: []const u8) !void {
        const encoded = try encodeBase64(self.gpa.?, bytes);
        defer self.gpa.?.free(encoded);
        var output: std.Io.Writer.Allocating = .init(self.gpa.?);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        try json.beginObject();
        try json.objectField("type");
        try json.write(event_type);
        try json.objectField(field);
        try json.write(encoded);
        try json.endObject();
        const message = try output.toOwnedSlice();
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendImage(self: *Connector, data_url: []const u8) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .type = "conversation.item.create",
            .item = .{
                .type = "message",
                .role = "user",
                .content = &.{.{ .type = "input_image", .image_url = data_url }},
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendToolResult(self: *Connector, result: base.ToolResult) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .type = "conversation.item.create",
            .item = .{
                .type = "function_call_output",
                .call_id = result.call_id,
                .output = result.output,
            },
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn sendTruncate(self: *Connector, milliseconds: u64) !void {
        const message = try std.json.Stringify.valueAlloc(self.gpa.?, .{
            .type = "conversation.item.truncate",
            .content_index = 0,
            .audio_end_ms = milliseconds,
        }, .{});
        defer self.gpa.?.free(message);
        try self.channel.?.sendText(message);
    }

    fn receive(context: *anyopaque, gpa: std.mem.Allocator) !base.OwnedCodecEvent {
        const self: *Connector = @ptrCast(@alignCast(context));
        if (self.pending_done) |done| {
            self.pending_done = null;
            return base.OwnedCodecEvent.copy(gpa, .{ .response_done = done });
        }
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
        const event_type = stringField(object, "type") orelse return error.InvalidRealtimeFrame;
        if (std.mem.eql(u8, event_type, "session.created") or
            std.mem.eql(u8, event_type, "session.updated"))
            return receive(self, gpa);
        if (std.mem.eql(u8, event_type, "response.audio.delta") or
            std.mem.eql(u8, event_type, "response.output_audio.delta"))
        {
            const encoded = stringField(object, "delta") orelse return error.InvalidRealtimeFrame;
            const audio = try decodeBase64(gpa, encoded);
            defer gpa.free(audio);
            return base.OwnedCodecEvent.copy(gpa, .{ .audio_delta = .{ .bytes = audio } });
        }
        if (std.mem.eql(u8, event_type, "response.audio_transcript.delta")) return copyTranscript(
            gpa,
            .output_transcript,
            stringField(object, "delta") orelse return error.InvalidRealtimeFrame,
            false,
        );
        if (std.mem.eql(u8, event_type, "response.audio_transcript.done")) return copyTranscript(
            gpa,
            .output_transcript,
            stringField(object, "transcript") orelse return error.InvalidRealtimeFrame,
            true,
        );
        if (std.mem.eql(u8, event_type, "conversation.item.input_audio_transcription.delta")) return copyTranscript(
            gpa,
            .input_transcript,
            stringField(object, "delta") orelse return error.InvalidRealtimeFrame,
            false,
        );
        if (std.mem.eql(u8, event_type, "conversation.item.input_audio_transcription.completed")) return copyTranscript(
            gpa,
            .input_transcript,
            stringField(object, "transcript") orelse return error.InvalidRealtimeFrame,
            true,
        );
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            return base.OwnedCodecEvent.copy(gpa, .{ .tool_call = .{
                .id = stringField(object, "call_id") orelse return error.InvalidRealtimeFrame,
                .name = stringField(object, "name") orelse return error.InvalidRealtimeFrame,
                .arguments_json = stringField(object, "arguments") orelse "{}",
            } });
        }
        if (std.mem.eql(u8, event_type, "input_audio_buffer.speech_started"))
            return base.OwnedCodecEvent.copy(gpa, .input_speech_start);
        if (std.mem.eql(u8, event_type, "input_audio_buffer.speech_stopped"))
            return base.OwnedCodecEvent.copy(gpa, .input_speech_end);
        if (std.mem.eql(u8, event_type, "response.output_audio.started"))
            return base.OwnedCodecEvent.copy(gpa, .output_speech_start);
        if (std.mem.eql(u8, event_type, "response.output_audio.done"))
            return base.OwnedCodecEvent.copy(gpa, .output_speech_end);
        if (std.mem.eql(u8, event_type, "response.cancelled"))
            return base.OwnedCodecEvent.copy(gpa, .response_interrupted);
        if (std.mem.eql(u8, event_type, "error")) {
            const error_value = object.get("error") orelse parsed.value;
            const error_object = if (error_value == .object) error_value.object else object;
            return base.OwnedCodecEvent.copy(gpa, .{ .session_error = .{
                .code = stringField(error_object, "code"),
                .message = stringField(error_object, "message") orelse "Realtime provider error.",
                .recoverable = true,
            } });
        }
        if (std.mem.eql(u8, event_type, "response.done")) return self.decodeResponseDone(gpa, object);
        return error.UnsupportedRealtimeEvent;
    }

    fn decodeResponseDone(
        self: *Connector,
        gpa: std.mem.Allocator,
        object: std.json.ObjectMap,
    ) !base.OwnedCodecEvent {
        const response_value = object.get("response") orelse return error.InvalidRealtimeFrame;
        if (response_value != .object) return error.InvalidRealtimeFrame;
        const response = response_value.object;
        const response_id = stringField(response, "id");
        self.pending_response_id = if (response_id) |id| transport.MetadataText.init(id) else null;
        const interrupted = if (stringField(response, "status")) |status|
            std.mem.eql(u8, status, "cancelled")
        else
            false;
        self.pending_done = .{
            .interrupted = interrupted,
            .response_id = if (self.pending_response_id) |*id| id.slice() else null,
        };
        if (response.get("usage")) |usage_value| if (usage_value == .object) {
            const usage = usage_value.object;
            return base.OwnedCodecEvent.copy(gpa, .{ .usage = .{
                .input_tokens = integerField(usage, "input_tokens"),
                .output_tokens = integerField(usage, "output_tokens"),
            } });
        };
        const done = self.pending_done.?;
        self.pending_done = null;
        return base.OwnedCodecEvent.copy(gpa, .{ .response_done = done });
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

fn copyTranscript(
    gpa: std.mem.Allocator,
    comptime tag: std.meta.Tag(base.CodecEvent),
    text: []const u8,
    final: bool,
) !base.OwnedCodecEvent {
    return switch (tag) {
        .output_transcript => base.OwnedCodecEvent.copy(gpa, .{ .output_transcript = .{ .text = text, .final = final } }),
        .input_transcript => base.OwnedCodecEvent.copy(gpa, .{ .input_transcript = .{ .text = text, .final = final } }),
        else => @compileError("transcript tag required"),
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) u64 {
    const value = object.get(name) orelse return 0;
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else 0;
}

fn encodeBase64(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    _ = std.base64.standard.Encoder.encode(encoded, source);
    return encoded;
}

fn decodeBase64(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(source) catch return error.InvalidRealtimeFrame;
    const decoded = try gpa.alloc(u8, size);
    errdefer gpa.free(decoded); // kcov-ignore: malformed base64 cleanup is exercised through Session.next
    std.base64.standard.Decoder.decode(decoded, source) catch return error.InvalidRealtimeFrame;
    return decoded;
}

test "OpenAI protocol drives WebRTC audio transcripts tools turns and usage" {
    const State = struct {
        frames: []const wire.Frame,
        index: usize = 0,
        sent: usize = 0,
        closed: usize = 0,

        fn open(context: *anyopaque, _: std.mem.Allocator) !wire.Channel {
            return .{
                .context = context,
                .kind = .webrtc_sideband,
                .send_text_fn = sendText,
                .receive_fn = receive,
                .close_fn = close,
                .is_transport_error_fn = isTransportError,
            };
        }
        fn sendText(context: *anyopaque, text: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(std.mem.indexOf(u8, text, "\"type\"") != null);
            self.sent += 1;
        }
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !wire.OwnedFrame {
            const self: *@This() = @ptrCast(@alignCast(context));
            const frame = self.frames[self.index];
            self.index += 1;
            return wire.OwnedFrame.copy(gpa, frame);
        }
        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed += 1;
        }
        fn isTransportError(_: *anyopaque, failure: anyerror) bool {
            return failure == error.TransportDropped;
        }
        fn tool(_: ?*anyopaque, gpa: std.mem.Allocator, _: base.CodecEvent.ToolCall) ![]u8 {
            return gpa.dupe(u8, "result");
        }
    };
    const frames = [_]wire.Frame{
        .{ .text = "{\"type\":\"session.created\"}" },
        .{ .text = "{\"type\":\"response.audio.delta\",\"delta\":\"AQI=\"}" },
        .{ .text = "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"delta\":\"h\"}" },
        .{ .text = "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"transcript\":\"hi\"}" },
        .{ .text = "{\"type\":\"response.audio_transcript.delta\",\"delta\":\"hel\"}" },
        .{ .text = "{\"type\":\"response.audio_transcript.done\",\"transcript\":\"hello\"}" },
        .{ .text = "{\"type\":\"input_audio_buffer.speech_started\"}" },
        .{ .text = "{\"type\":\"input_audio_buffer.speech_stopped\"}" },
        .{ .text = "{\"type\":\"response.output_audio.started\"}" },
        .{ .text = "{\"type\":\"response.output_audio.done\"}" },
        .{ .text = "{\"type\":\"response.cancelled\"}" },
        .{ .text = "{\"type\":\"error\",\"error\":{\"code\":\"notice\",\"message\":\"retry\"}}" },
        .{ .text = "{\"type\":\"response.function_call_arguments.done\",\"call_id\":\"c1\",\"name\":\"tool\",\"arguments\":\"{}\"}" },
        .{ .text = "{\"type\":\"response.done\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}}" },
        .{ .text = "{\"type\":\"response.done\",\"response\":{\"id\":\"r2\",\"status\":\"completed\"}}" },
        .{ .text = "{\"type\":\"future.event\"}" },
        .{ .text = "{\"type\":\"response.audio.delta\",\"delta\":\"!\"}" },
    };
    var state = State{ .frames = &frames };
    var protocol = Connector{
        .dialer = .{ .context = &state, .open_fn = State.open },
        .dialect = .xai,
        .model_name = "grok-voice",
        .instructions = "Be concise.",
        .voice = "Ara",
    };
    var session = try base.Session.init(std.testing.allocator, protocol.connector(), .{
        .tool_handler = .{ .execute_fn = State.tool },
    });
    defer session.deinit();
    try std.testing.expectEqual(base.TransportKind.webrtc_sideband, session.transportKind());
    try std.testing.expect(session.profile().reconnect_restores_state);
    try session.sendText("question");
    try session.sendAudio("\x00\x00");
    try session.commitAudio();
    try session.clearAudio();
    try session.createResponse();
    try session.interrupt(null);
    try session.interrupt(10);
    const expected = [_]std.meta.Tag(base.Event){
        .audio,
        .input_transcript,
        .input_transcript,
        .output_transcript,
        .output_transcript,
        .input_speech_start,
        .input_speech_end,
        .output_speech_start,
        .output_speech_end,
        .response_interrupted,
        .session_error,
        .tool,
        .turn_complete,
    };
    for (expected) |tag| {
        var event = try session.next(std.testing.allocator);
        defer event.deinit();
        try std.testing.expectEqual(tag, std.meta.activeTag(event.value));
    }
    try std.testing.expectEqual(@as(u64, 5), session.usage().totalTokens());
    var second_turn = try session.next(std.testing.allocator);
    second_turn.deinit();
    try std.testing.expectError(error.UnsupportedRealtimeEvent, session.next(std.testing.allocator));
    try std.testing.expectError(error.InvalidRealtimeFrame, session.next(std.testing.allocator));
    try std.testing.expect(state.sent >= 9);
    try std.testing.expect(session.connection.isTransportError(error.TransportDropped));

    session.close();
    protocol.dialect = .openai;
    var image_session = try base.Session.init(std.testing.allocator, protocol.connector(), .{});
    defer image_session.deinit();
    try image_session.sendImage(.{ .source = .{ .bytes = "jpeg" }, .media_type = "image/jpeg" });
}
