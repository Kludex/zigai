//! Provider-neutral realtime session state, transport boundaries, and events.
//!
//! Connections translate provider wire frames into `CodecEvent`. A `Session`
//! owns bounded history and usage, while each event returned by `next` has an
//! independent arena and must be deinitialized by its caller.

const std = @import("std");
const json_limits = @import("../json.zig");
const message_types = @import("../messages.zig");
const model_types = @import("../model.zig");
const usage_types = @import("../usage.zig");

const Message = message_types.Message;

/// Concrete media/control channel owned by a provider connection.
pub const TransportKind = enum {
    websocket,
    webrtc_sideband,
};

/// Feature and audio-format contract for one realtime model.
pub const Profile = struct {
    audio_input_sample_rate: u32 = 24_000,
    audio_output_sample_rate: u32 = 24_000,
    supports_text_input: bool = true,
    supports_image_input: bool = false,
    supports_manual_turn_control: bool = false,
    supports_interruption: bool = true,
    supports_output_truncation: bool = false,
    supports_session_seeding: bool = false,
    reconnect_restores_state: bool = false,
};

/// Closed input vocabulary sent through a realtime connection.
pub const Input = union(enum) {
    text: []const u8,
    audio: []const u8,
    image: message_types.Content,
    tool_result: ToolResult,
    commit_audio,
    clear_audio,
    create_response,
    cancel_response,
    truncate_output_ms: u64,
};

/// String-only tool result accepted by every realtime provider.
pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    output: []const u8,
    is_error: bool = false,
};

/// Provider-normalized events produced by a connection.
pub const CodecEvent = union(enum) {
    audio_delta: AudioDelta,
    output_transcript: Transcript,
    input_transcript: Transcript,
    tool_call: ToolCall,
    tool_cancelled: []const []const u8,
    response_done: ResponseDone,
    usage: usage_types.RequestUsage,
    input_speech_start,
    input_speech_end,
    output_speech_start,
    output_speech_end,
    response_interrupted,
    session_error: SessionError,

    pub const AudioDelta = struct {
        bytes: []const u8,
        item_id: ?[]const u8 = null,
    };

    pub const Transcript = struct {
        text: []const u8,
        final: bool,
        item_id: ?[]const u8 = null,
    };

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
    };

    pub const ResponseDone = struct {
        interrupted: bool = false,
        response_id: ?[]const u8 = null,
    };

    pub const SessionError = struct {
        code: ?[]const u8 = null,
        message: []const u8,
        recoverable: bool,
    };
};

/// Arena-owned codec event returned by provider connections.
pub const OwnedCodecEvent = struct {
    arena: std.heap.ArenaAllocator,
    value: CodecEvent,

    pub fn deinit(self: *OwnedCodecEvent) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn copy(gpa: std.mem.Allocator, event: CodecEvent) !OwnedCodecEvent {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const value = try copyCodecEvent(arena.allocator(), event);
        return .{ .arena = arena, .value = value };
    }
};

/// Connected provider protocol. Implementations own socket/WebRTC resources.
pub const Connection = struct {
    context: *anyopaque,
    transport_kind: TransportKind,
    profile: Profile,
    provider_name: []const u8,
    model_name: []const u8,
    send_fn: *const fn (context: *anyopaque, input: Input) anyerror!void,
    receive_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!OwnedCodecEvent,
    close_fn: *const fn (context: *anyopaque) void,
    is_transport_error_fn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    pub fn send(self: Connection, input: Input) !void {
        return self.send_fn(self.context, input);
    }

    pub fn receive(self: Connection, gpa: std.mem.Allocator) !OwnedCodecEvent {
        return self.receive_fn(self.context, gpa);
    }

    pub fn close(self: Connection) void {
        self.close_fn(self.context);
    }

    pub fn isTransportError(self: Connection, failure: anyerror) bool {
        const classify = self.is_transport_error_fn orelse return false;
        return classify(self.context, failure);
    }
};

/// Reconnectable provider boundary. Each call returns one live connection.
pub const Connector = struct {
    context: *anyopaque,
    connect_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!Connection,

    pub fn connect(self: Connector, gpa: std.mem.Allocator) !Connection {
        return self.connect_fn(self.context, gpa);
    }
};

/// Bounded reconnect behavior for one dropped connection.
pub const ReconnectPolicy = struct {
    max_attempts: usize = 3,
    max_reconnects: usize = 50,
    initial_delay_ms: u64 = 500,
    maximum_delay_ms: u64 = 30_000,
};

/// Audio retained in canonical message history.
pub const AudioRetention = enum {
    transcript_only,
    input_audio,
    output_audio,
    all,

    fn input(self: AudioRetention) bool {
        return self == .input_audio or self == .all;
    }

    fn output(self: AudioRetention) bool {
        return self == .output_audio or self == .all;
    }
};

/// Hard session growth limits.
pub const Limits = struct {
    max_text_bytes: usize = 1024 * 1024,
    max_audio_chunk_bytes: usize = 1024 * 1024,
    max_image_bytes: usize = 16 * 1024 * 1024,
    max_history_messages: usize = 10_000,
    max_retained_audio_bytes: usize = 64 * 1024 * 1024,
    max_tool_argument_bytes: usize = 1024 * 1024,
    max_tool_result_bytes: usize = 1024 * 1024,
    max_total_tokens: ?u64 = null,
};

/// Application tool dispatcher used by realtime tool calls.
pub const ToolHandler = struct {
    context: ?*anyopaque = null,
    execute_fn: *const fn (
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        call: CodecEvent.ToolCall,
    ) anyerror![]u8,

    pub fn execute(
        self: ToolHandler,
        gpa: std.mem.Allocator,
        call: CodecEvent.ToolCall,
    ) ![]u8 {
        return self.execute_fn(self.context, gpa, call);
    }
};

/// Session construction and control policy.
pub const Options = struct {
    io: ?std.Io = null,
    cancellation: ?*const model_types.CancellationToken = null,
    timeout_ms: ?u64 = null,
    reconnect: ?ReconnectPolicy = null,
    audio_retention: AudioRetention = .transcript_only,
    limits: Limits = .{},
    tool_handler: ?ToolHandler = null,
    message_history: []const Message = &.{},
};

/// Consumer-facing realtime event. Nested slices are owned by `OwnedEvent`.
pub const Event = union(enum) {
    audio: CodecEvent.AudioDelta,
    output_transcript: CodecEvent.Transcript,
    input_transcript: CodecEvent.Transcript,
    tool: ToolEvent,
    turn_complete: TurnComplete,
    input_speech_start,
    input_speech_end,
    output_speech_start,
    output_speech_end,
    response_interrupted,
    reconnect: Reconnect,
    session_error: CodecEvent.SessionError,

    pub const ToolEvent = struct {
        call: CodecEvent.ToolCall,
        result: ToolResult,
    };

    pub const TurnComplete = struct {
        interrupted: bool,
        response_id: ?[]const u8,
    };

    pub const Reconnect = struct {
        attempt: usize,
        total: usize,
        state_restored: bool,
    };
};

/// Arena-owned public event.
pub const OwnedEvent = struct {
    arena: std.heap.ArenaAllocator,
    value: Event,

    pub fn deinit(self: *OwnedEvent) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Arena-owned copy-on-read message history.
pub const OwnedHistory = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const Message,

    pub fn deinit(self: *OwnedHistory) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Persistent realtime session. The object must remain at a stable address.
pub const Session = struct {
    gpa: std.mem.Allocator,
    connector: Connector,
    connection: Connection,
    options: Options,
    control: model_types.RunControl,
    history_arena: std.heap.ArenaAllocator,
    history: std.ArrayList(Message) = .empty,
    input_audio: std.ArrayList(u8) = .empty,
    output_audio: std.ArrayList(u8) = .empty,
    output_transcript: std.ArrayList(u8) = .empty,
    usage_total: usage_types.RunUsage = .{},
    closed: bool = false,
    response_active: bool = false,
    reconnects: usize = 0,
    pending_reconnect: ?Event.Reconnect = null,

    pub fn init(gpa: std.mem.Allocator, connector: Connector, options: Options) !Session {
        try validateOptions(options);
        const connection = try connector.connect(gpa);
        var history_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer history_arena.deinit();
        var result = Session{
            .gpa = gpa,
            .connector = connector,
            .connection = connection,
            .options = options,
            .control = try model_types.RunControl.init(options.io, options.cancellation, options.timeout_ms),
            .history_arena = history_arena,
        };
        errdefer result.deinit();
        for (options.message_history) |message| try result.appendMessage(message);
        return result;
    }

    pub fn deinit(self: *Session) void {
        if (!self.closed) self.connection.close();
        self.history.deinit(self.gpa);
        self.input_audio.deinit(self.gpa);
        self.output_audio.deinit(self.gpa);
        self.output_transcript.deinit(self.gpa);
        self.history_arena.deinit();
        self.* = undefined;
    }

    pub fn close(self: *Session) void {
        if (self.closed) return;
        self.connection.close();
        self.closed = true;
    }

    pub fn profile(self: *const Session) Profile {
        return self.connection.profile;
    }

    pub fn transportKind(self: *const Session) TransportKind {
        return self.connection.transport_kind;
    }

    pub fn usage(self: *const Session) usage_types.RunUsage {
        return self.usage_total;
    }

    pub fn allMessages(self: *const Session, gpa: std.mem.Allocator) !OwnedHistory {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const messages = try message_types.dupeMessages(arena.allocator(), self.history.items);
        return .{ .arena = arena, .messages = messages };
    }

    pub fn sendText(self: *Session, text: []const u8) !void {
        try self.ensureOpen();
        if (!self.connection.profile.supports_text_input) return error.UnsupportedRealtimeOperation;
        try validateText(text, self.options.limits.max_text_bytes);
        try self.send(.{ .text = text });
        try self.appendMessage(.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = text } }} } });
    }

    pub fn sendAudio(self: *Session, pcm16: []const u8) !void {
        try self.ensureOpen();
        if (pcm16.len == 0 or pcm16.len > self.options.limits.max_audio_chunk_bytes or pcm16.len % 2 != 0)
            return error.InvalidRealtimeAudio;
        try self.send(.{ .audio = pcm16 });
        if (self.options.audio_retention.input()) {
            try self.appendRetained(&self.input_audio, pcm16);
        }
    }

    pub fn sendImage(self: *Session, image: message_types.Content) !void {
        try self.ensureOpen();
        if (!self.connection.profile.supports_image_input) return error.UnsupportedRealtimeOperation;
        const bytes = switch (image.source) {
            .bytes => |value| value,
            else => return error.UnsupportedRealtimeContent,
        };
        if (bytes.len == 0 or bytes.len > self.options.limits.max_image_bytes)
            return error.RealtimeContentTooLarge;
        try self.send(.{ .image = image });
        try self.appendMessage(.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .image = image } }} } });
    }

    pub fn commitAudio(self: *Session) !void {
        try self.requireManualControl();
        try self.send(.commit_audio);
    }

    pub fn clearAudio(self: *Session) !void {
        try self.requireManualControl();
        try self.send(.clear_audio);
        self.input_audio.clearRetainingCapacity();
    }

    pub fn createResponse(self: *Session) !void {
        try self.requireManualControl();
        try self.send(.create_response);
        self.response_active = true;
    }

    pub fn interrupt(self: *Session, played_ms: ?u64) !void {
        try self.ensureOpen();
        if (!self.connection.profile.supports_interruption) return error.UnsupportedRealtimeOperation;
        if (played_ms) |milliseconds| {
            if (!self.connection.profile.supports_output_truncation)
                return error.UnsupportedRealtimeOperation;
            try self.send(.{ .truncate_output_ms = milliseconds });
        } else {
            try self.send(.cancel_response);
        }
        self.response_active = false;
    }

    pub fn next(self: *Session, gpa: std.mem.Allocator) !OwnedEvent {
        try self.ensureOpen();
        while (true) {
            if (self.pending_reconnect) |reconnect_event| {
                self.pending_reconnect = null;
                return ownEvent(gpa, .{ .reconnect = reconnect_event });
            }
            var codec = self.receiveControlled(gpa) catch |failure| {
                try self.reconnect(failure);
                continue;
            };
            defer codec.deinit();
            if (try self.handle(gpa, codec.value)) |event| return event;
        }
    }

    fn handle(self: *Session, gpa: std.mem.Allocator, event: CodecEvent) !?OwnedEvent {
        return switch (event) {
            .audio_delta => |audio| blk: {
                if (audio.bytes.len == 0 or audio.bytes.len > self.options.limits.max_audio_chunk_bytes)
                    return error.RealtimeContentTooLarge;
                if (self.options.audio_retention.output()) try self.appendRetained(&self.output_audio, audio.bytes);
                break :blk try ownEvent(gpa, .{ .audio = audio });
            },
            .output_transcript => |transcript| blk: {
                try validateText(transcript.text, self.options.limits.max_text_bytes);
                if (transcript.final) self.output_transcript.clearRetainingCapacity();
                try self.output_transcript.appendSlice(self.gpa, transcript.text);
                break :blk try ownEvent(gpa, .{ .output_transcript = transcript });
            },
            .input_transcript => |transcript| blk: {
                try validateText(transcript.text, self.options.limits.max_text_bytes);
                if (transcript.final) try self.finishInput(transcript.text);
                break :blk try ownEvent(gpa, .{ .input_transcript = transcript });
            },
            .tool_call => |call| try self.executeTool(gpa, call),
            .tool_cancelled => |ids| blk: {
                for (ids) |id| try self.appendToolCancellation(id);
                break :blk try ownEvent(gpa, .{ .session_error = .{
                    .code = "tool_cancelled",
                    .message = "The provider cancelled an in-flight tool call.",
                    .recoverable = true,
                } });
            },
            .response_done => |done| blk: {
                if (self.output_transcript.items.len > 0 or self.output_audio.items.len > 0) {
                    try self.finishOutput(self.output_transcript.items, done.interrupted);
                }
                self.response_active = false;
                self.output_transcript.clearRetainingCapacity();
                self.output_audio.clearRetainingCapacity();
                break :blk try ownEvent(gpa, .{ .turn_complete = .{
                    .interrupted = done.interrupted,
                    .response_id = done.response_id,
                } });
            },
            .usage => |request_usage| blk: {
                try self.usage_total.recordRequest(null);
                try self.usage_total.addRequest(self.history_arena.allocator(), request_usage);
                try self.enforceUsage();
                break :blk null;
            },
            .input_speech_start => try ownEvent(gpa, .input_speech_start),
            .input_speech_end => try ownEvent(gpa, .input_speech_end),
            .output_speech_start => try ownEvent(gpa, .output_speech_start),
            .output_speech_end => try ownEvent(gpa, .output_speech_end),
            .response_interrupted => blk: {
                self.response_active = false;
                break :blk try ownEvent(gpa, .response_interrupted);
            },
            .session_error => |session_error| try ownEvent(gpa, .{ .session_error = session_error }),
        };
    }

    fn executeTool(self: *Session, gpa: std.mem.Allocator, call: CodecEvent.ToolCall) !OwnedEvent {
        if (call.id.len == 0 or call.name.len == 0 or
            call.arguments_json.len > self.options.limits.max_tool_argument_bytes)
            return error.InvalidRealtimeToolCall;
        try json_limits.validateAs(
            gpa,
            call.arguments_json,
            json_limits.defaults.tool_payload,
            error.InvalidRealtimeToolCall,
        );
        const handler = self.options.tool_handler orelse return error.UnknownRealtimeTool;
        const output = try self.control.invoke([]u8, invokeTool, .{ handler, gpa, call });
        defer gpa.free(output);
        if (output.len > self.options.limits.max_tool_result_bytes) return error.RealtimeContentTooLarge;
        const result = ToolResult{ .call_id = call.id, .name = call.name, .output = output };
        try self.send(.{ .tool_result = result });
        try self.appendMessage(.{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments_json = call.arguments_json,
        } }} } });
        try self.appendMessage(.{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = call.id,
            .name = call.name,
            .content = output,
        } }} } });
        self.usage_total.tool_calls = std.math.add(usize, self.usage_total.tool_calls, 1) catch
            return error.UsageOverflow;
        return ownEvent(gpa, .{ .tool = .{ .call = call, .result = result } });
    }

    fn finishInput(self: *Session, transcript: []const u8) !void {
        const audio = if (self.options.audio_retention.input() and self.input_audio.items.len > 0)
            message_types.Content{
                .source = .{ .bytes = self.input_audio.items },
                .media_type = "audio/pcm",
            }
        else
            null;
        try self.appendMessage(.{ .request = .{ .parts = &.{.{ .speech = .{
            .speaker = .user,
            .transcript = transcript,
            .audio = audio,
        } }} } });
        self.input_audio.clearRetainingCapacity();
    }

    fn finishOutput(self: *Session, transcript: []const u8, interrupted: bool) !void {
        const audio = if (self.options.audio_retention.output() and self.output_audio.items.len > 0)
            message_types.Content{
                .source = .{ .bytes = self.output_audio.items },
                .media_type = "audio/pcm",
            }
        else
            null;
        try self.appendMessage(.{ .response = .{
            .parts = &.{.{ .speech = .{
                .speaker = .assistant,
                .transcript = if (transcript.len > 0) transcript else null,
                .audio = audio,
                .interrupted_at_ms = if (interrupted) 0 else null,
            } }},
            .provider_name = self.connection.provider_name,
            .model_name = self.connection.model_name,
            .state = if (interrupted) .interrupted else .complete,
        } });
    }

    fn appendToolCancellation(self: *Session, call_id: []const u8) !void {
        try self.appendMessage(.{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = call_id,
            .name = "cancelled",
            .content = "The provider cancelled this tool call.",
            .outcome = .interrupted,
        } }} } });
    }

    fn appendMessage(self: *Session, message: Message) !void {
        if (self.history.items.len >= self.options.limits.max_history_messages)
            return error.RealtimeHistoryLimitExceeded;
        try self.history.append(
            self.gpa,
            try message_types.dupeMessage(self.history_arena.allocator(), message),
        );
    }

    fn appendRetained(self: *Session, target: *std.ArrayList(u8), bytes: []const u8) !void {
        const total = std.math.add(usize, target.items.len, bytes.len) catch
            return error.RealtimeContentTooLarge;
        if (total > self.options.limits.max_retained_audio_bytes)
            return error.RealtimeContentTooLarge;
        try target.appendSlice(self.gpa, bytes);
    }

    fn send(self: *Session, input: Input) !void {
        return self.control.invoke(void, invokeSend, .{ self.connection, input });
    }

    fn receiveControlled(self: *Session, gpa: std.mem.Allocator) !OwnedCodecEvent {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var received = try self.control.invoke(
            OwnedCodecEvent,
            invokeReceive,
            .{ self.connection, scratch.allocator() },
        );
        defer received.deinit();
        return OwnedCodecEvent.copy(gpa, received.value);
    }

    fn reconnect(self: *Session, failure: anyerror) !void {
        const policy = self.options.reconnect orelse return failure;
        if (!self.connection.isTransportError(failure)) return failure;
        if (self.reconnects >= policy.max_reconnects) return error.RealtimeReconnectExhausted;
        self.connection.close();
        var attempt: usize = 0;
        while (attempt < policy.max_attempts) : (attempt += 1) {
            if (attempt > 0 or policy.initial_delay_ms > 0) {
                const io = self.options.io orelse return error.RealtimeReconnectRequiresIo;
                const delay = reconnectDelay(policy, attempt + 1);
                try self.control.invoke(void, sleep, .{ io, delay });
            }
            const replacement = self.connector.connect(self.gpa) catch continue;
            self.connection = replacement;
            self.reconnects += 1;
            self.pending_reconnect = .{
                .attempt = attempt + 1,
                .total = self.reconnects,
                .state_restored = replacement.profile.reconnect_restores_state,
            };
            return;
        }
        return error.RealtimeReconnectExhausted;
    }

    fn requireManualControl(self: *Session) !void {
        try self.ensureOpen();
        if (!self.connection.profile.supports_manual_turn_control)
            return error.UnsupportedRealtimeOperation;
    }

    fn ensureOpen(self: *const Session) !void {
        if (self.closed) return error.RealtimeSessionClosed;
        try self.control.check();
    }

    fn enforceUsage(self: *const Session) !void {
        if (self.options.limits.max_total_tokens) |maximum| {
            const total = std.math.add(
                u64,
                self.usage_total.input_tokens,
                self.usage_total.output_tokens,
            ) catch return error.UsageOverflow;
            if (total > maximum) return error.RealtimeUsageLimitExceeded;
        }
    }
};

fn validateOptions(options: Options) !void {
    const limits = options.limits;
    if (limits.max_text_bytes == 0 or limits.max_audio_chunk_bytes == 0 or
        limits.max_image_bytes == 0 or limits.max_history_messages == 0 or
        limits.max_retained_audio_bytes == 0 or limits.max_tool_argument_bytes == 0 or
        limits.max_tool_result_bytes == 0)
        return error.InvalidRealtimeLimits;
    if (options.reconnect) |policy| {
        if (policy.max_attempts == 0 or policy.max_reconnects == 0)
            return error.InvalidRealtimeLimits;
    }
}

fn validateText(text: []const u8, maximum: usize) !void {
    if (text.len == 0) return error.InvalidRealtimeContent;
    if (text.len > maximum) return error.RealtimeContentTooLarge;
}

fn invokeSend(connection: Connection, input: Input) !void {
    return connection.send(input);
}

fn invokeReceive(connection: Connection, gpa: std.mem.Allocator) !OwnedCodecEvent {
    return connection.receive(gpa);
}

fn invokeTool(handler: ToolHandler, gpa: std.mem.Allocator, call: CodecEvent.ToolCall) ![]u8 {
    return handler.execute(gpa, call);
}

fn reconnectDelay(policy: ReconnectPolicy, attempt: usize) u64 {
    var delay = @min(policy.initial_delay_ms, policy.maximum_delay_ms);
    var exponent = attempt -| 1;
    while (exponent > 0 and delay < policy.maximum_delay_ms) : (exponent -= 1) {
        delay = @min(std.math.mul(u64, delay, 2) catch std.math.maxInt(u64), policy.maximum_delay_ms);
    }
    return delay;
}

fn sleep(io: std.Io, milliseconds: u64) !void {
    return (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64)))),
        .clock = .awake,
    } }).sleep(io);
}

fn ownEvent(gpa: std.mem.Allocator, event: Event) !OwnedEvent {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = try copyEvent(arena.allocator(), event);
    return .{ .arena = arena, .value = value };
}

fn copyCodecEvent(arena: std.mem.Allocator, event: CodecEvent) !CodecEvent {
    return switch (event) {
        .audio_delta => |value| .{ .audio_delta = .{
            .bytes = try arena.dupe(u8, value.bytes),
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .output_transcript => |value| .{ .output_transcript = .{
            .text = try arena.dupe(u8, value.text),
            .final = value.final,
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .input_transcript => |value| .{ .input_transcript = .{
            .text = try arena.dupe(u8, value.text),
            .final = value.final,
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .tool_call => |value| .{ .tool_call = .{
            .id = try arena.dupe(u8, value.id),
            .name = try arena.dupe(u8, value.name),
            .arguments_json = try arena.dupe(u8, value.arguments_json),
        } },
        .tool_cancelled => |ids| cancelled: {
            const copies = try arena.alloc([]const u8, ids.len);
            for (ids, copies) |id, *copy| copy.* = try arena.dupe(u8, id);
            break :cancelled .{ .tool_cancelled = copies };
        },
        .response_done => |value| .{ .response_done = .{
            .interrupted = value.interrupted,
            .response_id = try copyOptional(arena, value.response_id),
        } },
        .usage => |value| .{ .usage = try value.dupe(arena) },
        .input_speech_start => .input_speech_start,
        .input_speech_end => .input_speech_end,
        .output_speech_start => .output_speech_start,
        .output_speech_end => .output_speech_end,
        .response_interrupted => .response_interrupted,
        .session_error => |value| .{ .session_error = .{
            .code = try copyOptional(arena, value.code),
            .message = try arena.dupe(u8, value.message),
            .recoverable = value.recoverable,
        } },
    };
}

fn copyEvent(arena: std.mem.Allocator, event: Event) !Event {
    return switch (event) {
        .audio => |value| .{ .audio = .{
            .bytes = try arena.dupe(u8, value.bytes),
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .output_transcript => |value| .{ .output_transcript = .{
            .text = try arena.dupe(u8, value.text),
            .final = value.final,
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .input_transcript => |value| .{ .input_transcript = .{
            .text = try arena.dupe(u8, value.text),
            .final = value.final,
            .item_id = try copyOptional(arena, value.item_id),
        } },
        .tool => |value| .{ .tool = .{
            .call = .{
                .id = try arena.dupe(u8, value.call.id),
                .name = try arena.dupe(u8, value.call.name),
                .arguments_json = try arena.dupe(u8, value.call.arguments_json),
            },
            .result = .{
                .call_id = try arena.dupe(u8, value.result.call_id),
                .name = try arena.dupe(u8, value.result.name),
                .output = try arena.dupe(u8, value.result.output),
                .is_error = value.result.is_error,
            },
        } },
        .turn_complete => |value| .{ .turn_complete = .{
            .interrupted = value.interrupted,
            .response_id = try copyOptional(arena, value.response_id),
        } },
        .input_speech_start => .input_speech_start,
        .input_speech_end => .input_speech_end,
        .output_speech_start => .output_speech_start,
        .output_speech_end => .output_speech_end,
        .response_interrupted => .response_interrupted,
        .reconnect => |value| .{ .reconnect = value },
        .session_error => |value| .{ .session_error = .{
            .code = try copyOptional(arena, value.code),
            .message = try arena.dupe(u8, value.message),
            .recoverable = value.recoverable,
        } },
    };
}

fn copyOptional(arena: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

test "realtime sessions stream media tools turns usage and canonical history" {
    const State = struct {
        events: []const CodecEvent,
        next_event: usize = 0,
        sent: [16]std.meta.Tag(Input) = undefined,
        sent_count: usize = 0,
        closes: usize = 0,
        connects: usize = 0,

        fn connect(context: *anyopaque, _: std.mem.Allocator) !Connection {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.connects += 1;
            return .{
                .context = self,
                .transport_kind = .websocket,
                .profile = .{
                    .supports_image_input = true,
                    .supports_manual_turn_control = true,
                    .supports_output_truncation = true,
                    .supports_session_seeding = true,
                },
                .provider_name = "test",
                .model_name = "voice",
                .send_fn = send,
                .receive_fn = receive,
                .close_fn = close,
            };
        }

        fn send(context: *anyopaque, input: Input) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sent[self.sent_count] = std.meta.activeTag(input);
            self.sent_count += 1;
            if (input == .tool_result) try std.testing.expectEqualStrings("tool-ok", input.tool_result.output);
        }

        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedCodecEvent {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.next_event >= self.events.len) return error.EndOfEvents;
            const event = self.events[self.next_event];
            self.next_event += 1;
            return OwnedCodecEvent.copy(gpa, event);
        }

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closes += 1;
        }

        fn tool(_: ?*anyopaque, gpa: std.mem.Allocator, call: CodecEvent.ToolCall) ![]u8 {
            try std.testing.expectEqualStrings("lookup", call.name);
            return gpa.dupe(u8, "tool-ok");
        }
    };
    const events = [_]CodecEvent{
        .{ .input_transcript = .{ .text = "hello", .final = true, .item_id = "user-1" } },
        .{ .audio_delta = .{ .bytes = "\x01\x00", .item_id = "assistant-1" } },
        .{ .output_transcript = .{ .text = "answer", .final = true, .item_id = "assistant-1" } },
        .{ .usage = .{ .input_tokens = 2, .output_tokens = 3 } },
        .{ .tool_call = .{ .id = "call-1", .name = "lookup", .arguments_json = "{}" } },
        .{ .response_done = .{ .response_id = "response-1" } },
        .{ .tool_cancelled = &.{"call-2"} },
        .input_speech_end,
        .output_speech_start,
        .output_speech_end,
        .response_interrupted,
        .{ .session_error = .{ .code = "notice", .message = "recoverable", .recoverable = true } },
    };
    var state = State{ .events = &events };
    var session = try Session.init(std.testing.allocator, .{
        .context = &state,
        .connect_fn = State.connect,
    }, .{
        .audio_retention = .all,
        .tool_handler = .{ .execute_fn = State.tool },
    });
    defer session.deinit();
    try std.testing.expectEqual(TransportKind.websocket, session.transportKind());
    try std.testing.expect(session.profile().supports_manual_turn_control);
    try session.sendText("question");
    try session.sendAudio("\x01\x00");
    try session.sendImage(.{ .source = .{ .bytes = "jpeg" }, .media_type = "image/jpeg" });
    try session.commitAudio();
    try session.clearAudio();
    try session.createResponse();
    try session.interrupt(null);
    try session.interrupt(20);

    const expected_tags = [_]std.meta.Tag(Event){
        .input_transcript,
        .audio,
        .output_transcript,
        .tool,
        .turn_complete,
        .session_error,
        .input_speech_end,
        .output_speech_start,
        .output_speech_end,
        .response_interrupted,
        .session_error,
    };
    for (expected_tags) |expected| {
        var event = try session.next(std.testing.allocator);
        defer event.deinit();
        try std.testing.expectEqual(expected, std.meta.activeTag(event.value));
    }
    try std.testing.expectEqual(@as(u64, 5), session.usage().totalTokens());
    try std.testing.expectEqual(@as(usize, 1), session.usage().tool_calls);
    var history = try session.allMessages(std.testing.allocator);
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 7), history.messages.len);
    try std.testing.expectEqualStrings(
        "answer",
        history.messages[5].response.parts[0].speech.transcript.?,
    );
    session.close();
    try std.testing.expectError(error.RealtimeSessionClosed, session.sendText("closed"));
    try std.testing.expectEqual(@as(usize, 1), state.closes);
}

test "realtime sessions reconnect only classified transport failures" {
    const State = struct {
        connects: usize = 0,
        receives: usize = 0,
        closes: usize = 0,
        fail_connect: bool = false,

        fn connect(context: *anyopaque, _: std.mem.Allocator) !Connection {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.connects += 1;
            if (self.fail_connect or self.connects == 2) return error.ConnectFailed;
            return .{
                .context = self,
                .transport_kind = .webrtc_sideband,
                .profile = .{ .reconnect_restores_state = true },
                .provider_name = "test",
                .model_name = "voice",
                .send_fn = send,
                .receive_fn = receive,
                .close_fn = close,
                .is_transport_error_fn = isTransportError,
            };
        }

        fn send(_: *anyopaque, _: Input) !void {}

        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedCodecEvent {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.receives += 1;
            if (self.receives == 1) return error.TransportDropped;
            return OwnedCodecEvent.copy(gpa, .input_speech_start);
        }

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closes += 1;
        }

        fn isTransportError(_: *anyopaque, failure: anyerror) bool {
            return failure == error.TransportDropped;
        }
    };
    var state: State = .{};
    var session = try Session.init(std.testing.allocator, .{
        .context = &state,
        .connect_fn = State.connect,
    }, .{
        .io = std.testing.io,
        .reconnect = .{ .initial_delay_ms = 1, .maximum_delay_ms = 2 },
    });
    defer session.deinit();
    var reconnect_event = try session.next(std.testing.allocator);
    defer reconnect_event.deinit();
    try std.testing.expectEqual(std.meta.Tag(Event).reconnect, std.meta.activeTag(reconnect_event.value));
    try std.testing.expect(reconnect_event.value.reconnect.state_restored);
    try session.sendText("after reconnect");
    var speech = try session.next(std.testing.allocator);
    defer speech.deinit();
    try std.testing.expectEqual(std.meta.Tag(Event).input_speech_start, std.meta.activeTag(speech.value));
    try std.testing.expectEqual(@as(usize, 3), state.connects);
    state.receives = 0;
    state.fail_connect = true;
    session.options.reconnect.?.initial_delay_ms = 0;
    try std.testing.expectError(error.RealtimeReconnectExhausted, session.next(std.testing.allocator));
}

test "realtime sessions reject unsupported operations and every configured limit" {
    const State = struct {
        profile_value: Profile = .{},
        events: []const CodecEvent = &.{},
        index: usize = 0,

        fn connect(context: *anyopaque, _: std.mem.Allocator) !Connection {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{
                .context = self,
                .transport_kind = .websocket,
                .profile = self.profile_value,
                .provider_name = "test",
                .model_name = "voice",
                .send_fn = send,
                .receive_fn = receive,
                .close_fn = close,
            };
        }
        fn send(_: *anyopaque, _: Input) !void {}
        fn receive(context: *anyopaque, gpa: std.mem.Allocator) !OwnedCodecEvent {
            const self: *@This() = @ptrCast(@alignCast(context));
            const event = self.events[self.index];
            self.index += 1;
            return OwnedCodecEvent.copy(gpa, event);
        }
        fn close(_: *anyopaque) void {}
    };
    var state: State = .{};
    const connector = Connector{ .context = &state, .connect_fn = State.connect };
    try std.testing.expectError(
        error.InvalidRealtimeLimits,
        Session.init(std.testing.allocator, connector, .{ .limits = .{ .max_text_bytes = 0 } }),
    );
    try std.testing.expectError(
        error.InvalidRealtimeLimits,
        Session.init(std.testing.allocator, connector, .{ .reconnect = .{ .max_attempts = 0 } }),
    );
    var session = try Session.init(std.testing.allocator, connector, .{});
    defer session.deinit();
    try std.testing.expectError(error.InvalidRealtimeContent, session.sendText(""));
    session.connection.profile.supports_text_input = false;
    try std.testing.expectError(error.UnsupportedRealtimeOperation, session.sendText("text"));
    try std.testing.expectError(error.InvalidRealtimeAudio, session.sendAudio("x"));
    try std.testing.expectError(
        error.UnsupportedRealtimeOperation,
        session.sendImage(.{ .source = .{ .bytes = "x" }, .media_type = "image/jpeg" }),
    );
    try std.testing.expectError(error.UnsupportedRealtimeOperation, session.commitAudio());
    session.connection.profile.supports_interruption = false;
    try std.testing.expectError(error.UnsupportedRealtimeOperation, session.interrupt(null));
    session.connection.profile.supports_interruption = true;
    try std.testing.expectError(error.UnsupportedRealtimeOperation, session.interrupt(1));
    session.connection.profile.supports_image_input = true;
    try std.testing.expectError(
        error.RealtimeContentTooLarge,
        session.sendImage(.{ .source = .{ .bytes = "" }, .media_type = "image/jpeg" }),
    );
    session.connection.profile.supports_text_input = true;
    session.options.limits.max_history_messages = 1;
    try session.sendText("first");
    try std.testing.expectError(error.RealtimeHistoryLimitExceeded, session.sendText("second"));
    session.options.audio_retention = .input_audio;
    session.options.limits.max_retained_audio_bytes = 2;
    try session.sendAudio("\x00\x00");
    try std.testing.expectError(error.RealtimeContentTooLarge, session.sendAudio("\x00\x00"));

    state.events = &.{
        .{ .audio_delta = .{ .bytes = "" } },
        .{ .tool_call = .{ .id = "", .name = "bad", .arguments_json = "{}" } },
        .{ .usage = .{ .input_tokens = 2 } },
    };
    try std.testing.expectError(error.RealtimeContentTooLarge, session.next(std.testing.allocator));
    try std.testing.expectError(error.InvalidRealtimeToolCall, session.next(std.testing.allocator));
    session.options.limits.max_total_tokens = 1;
    try std.testing.expectError(error.RealtimeUsageLimitExceeded, session.next(std.testing.allocator));
}

fn copyRealtimeEventWithAllocator(gpa: std.mem.Allocator) !void {
    var event = try OwnedCodecEvent.copy(gpa, .{ .session_error = .{
        .code = "code",
        .message = "message",
        .recoverable = true,
    } });
    defer event.deinit();
    try std.testing.expectEqualStrings("message", event.value.session_error.message);
}

fn runRealtimeWithAllocator(gpa: std.mem.Allocator) !void {
    const State = struct {
        fn connect(context: *anyopaque, _: std.mem.Allocator) !Connection {
            return .{
                .context = context,
                .transport_kind = .websocket,
                .profile = .{},
                .provider_name = "test",
                .model_name = "voice",
                .send_fn = send,
                .receive_fn = receive,
                .close_fn = close,
            };
        }
        fn send(_: *anyopaque, _: Input) !void {}
        fn receive(_: *anyopaque, allocator: std.mem.Allocator) !OwnedCodecEvent {
            return OwnedCodecEvent.copy(allocator, .{ .session_error = .{
                .message = "notice",
                .recoverable = true,
            } });
        }
        fn close(_: *anyopaque) void {}
    };
    var marker: u8 = 0;
    const seed = [_]Message{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "seed" } }} } }};
    var session = try Session.init(gpa, .{ .context = &marker, .connect_fn = State.connect }, .{
        .message_history = &seed,
    });
    defer session.deinit();
    try session.sendText("text");
    var event = try session.next(gpa);
    event.deinit();
    var history = try session.allMessages(gpa);
    history.deinit();
}

test "realtime event ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        copyRealtimeEventWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runRealtimeWithAllocator,
        .{},
    );
}
