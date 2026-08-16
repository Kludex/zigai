//! Provider-neutral browser UI events, approval decisions, replay, and sanitization.
//!
//! Events are borrowed for synchronous encoding. Replay entries and sanitized
//! canonical messages own all retained data explicitly.

const std = @import("std");
const agent_types = @import("../agent.zig");
const json_limits = @import("../json.zig");
const message_types = @import("../messages.zig");
const model_types = @import("../model.zig");

/// Stable UI event vocabulary shared by AG-UI and Vercel adapters.
pub const Event = union(enum) {
    run_start: RunStart,
    run_finish: RunFinish,
    run_error: RunError,
    text_start: PartStart,
    text_delta: PartDelta,
    text_end: PartEnd,
    reasoning_start: PartStart,
    reasoning_delta: PartDelta,
    reasoning_end: PartEnd,
    tool_input_start: ToolStart,
    tool_input_delta: ToolDelta,
    tool_input_end: ToolEnd,
    tool_result: ToolResult,
    approval_request: ApprovalRequest,
    approval_response: ApprovalResponse,
    custom: Custom,

    pub const RunStart = struct { thread_id: []const u8, run_id: []const u8 };
    pub const RunFinish = struct { thread_id: []const u8, run_id: []const u8 };
    pub const RunError = struct { message: []const u8, code: ?[]const u8 = null };
    pub const PartStart = struct { id: []const u8 };
    pub const PartDelta = struct { id: []const u8, delta: []const u8 };
    pub const PartEnd = struct { id: []const u8 };
    pub const ToolStart = struct { call_id: []const u8, name: []const u8 };
    pub const ToolDelta = struct { call_id: []const u8, delta: []const u8 };
    pub const ToolEnd = struct {
        call_id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
    };
    pub const ToolResult = struct {
        message_id: []const u8,
        call_id: []const u8,
        content_json: []const u8,
        is_error: bool = false,
    };
    pub const ApprovalRequest = struct {
        thread_id: []const u8,
        run_id: []const u8,
        approval_id: []const u8,
        call_id: []const u8,
        tool_name: []const u8,
        arguments_json: []const u8,
    };
    pub const ApprovalResponse = struct {
        approval_id: []const u8,
        approved: bool,
        reason: ?[]const u8 = null,
    };
    pub const Custom = struct { name: []const u8, value_json: []const u8 };
};

/// Fallible borrowed event destination.
pub const Sink = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: Event) anyerror!void,

    pub fn emit(self: Sink, event: Event) !void {
        return self.event_fn(self.context, event);
    }
};

/// Limits shared by protocol encoders, replay, and client-message parsing.
pub const Limits = struct {
    max_identifier_bytes: usize = 256,
    max_text_bytes: usize = 1024 * 1024,
    max_custom_json_bytes: usize = 1024 * 1024,
    max_messages: usize = 1_000,
    max_replay_events: usize = 4_096,
    max_replay_bytes: usize = 16 * 1024 * 1024,
};

/// Converts agent stream events into stable UI lifecycle events.
pub const Bridge = struct {
    sink: Sink,
    thread_id: []const u8,
    run_id: []const u8,
    limits: Limits = .{},

    pub fn begin(self: *Bridge) !void {
        try validateIdentifier(self.thread_id, self.limits.max_identifier_bytes);
        try validateIdentifier(self.run_id, self.limits.max_identifier_bytes);
        try self.sink.emit(.{ .run_start = .{ .thread_id = self.thread_id, .run_id = self.run_id } });
    }

    pub fn finish(self: *Bridge) !void {
        try self.sink.emit(.{ .run_finish = .{ .thread_id = self.thread_id, .run_id = self.run_id } });
    }

    pub fn fail(self: *Bridge, failure: anyerror) !void {
        try self.sink.emit(.{ .run_error = .{ .message = @errorName(failure), .code = @errorName(failure) } });
    }

    pub fn agentSink(self: *Bridge) agent_types.AgentStreamSink {
        return .{ .context = self, .eventFn = emitAgent };
    }

    pub fn emitCustom(
        self: *Bridge,
        gpa: std.mem.Allocator,
        name: []const u8,
        value_json: []const u8,
    ) !void {
        try validateIdentifier(name, self.limits.max_identifier_bytes);
        try validateJson(gpa, value_json, self.limits.max_custom_json_bytes);
        try self.sink.emit(.{ .custom = .{ .name = name, .value_json = value_json } });
    }

    fn emitAgent(context: *anyopaque, event: agent_types.AgentStreamEvent) !void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        switch (event) {
            .model => |model_event| try self.emitModel(model_event),
            .function_tool_call => |value| try self.sink.emit(.{ .tool_input_end = .{
                .call_id = value.call.id,
                .name = value.call.name,
                .arguments_json = value.call.arguments_json,
            } }),
            .function_tool_result => |value| try self.sink.emit(.{ .tool_result = .{
                .message_id = value.result.call_id,
                .call_id = value.result.call_id,
                .content_json = value.result.content,
                .is_error = value.result.isError(),
            } }),
            .deferred_tool_requests => |value| {
                for (value.requests) |request| try self.sink.emit(.{ .approval_request = .{
                    .thread_id = self.thread_id,
                    .run_id = self.run_id,
                    .approval_id = request.call_id,
                    .call_id = request.call_id,
                    .tool_name = request.name,
                    .arguments_json = request.arguments_json,
                } });
            },
            .partial_output, .final_result, .tool_availability_delta, .deferred_tool_results, .enqueued_messages => {},
        }
    }

    fn emitModel(self: *Bridge, event: model_types.ModelStreamEvent) !void {
        switch (event) {
            .part_start => |value| {
                var id_buffer: [64]u8 = undefined;
                const id = try std.fmt.bufPrint(&id_buffer, "part-{d}", .{value.index});
                switch (value.part) {
                    .text, .text_part, .speech => try self.sink.emit(.{ .text_start = .{ .id = id } }),
                    .thinking => try self.sink.emit(.{ .reasoning_start = .{ .id = id } }),
                    .tool_call => |call| try self.sink.emit(.{ .tool_input_start = .{
                        .call_id = call.id,
                        .name = call.name,
                    } }),
                    else => {},
                }
            },
            .part_delta => |value| switch (value.delta) {
                .text => |delta| try self.emitPartDelta(value.index, delta.content_delta, false),
                .thinking => |delta| try self.emitPartDelta(value.index, delta.content_delta, true),
                .speech => |delta| if (delta.transcript_delta.len > 0)
                    try self.emitPartDelta(value.index, delta.transcript_delta, false),
                .tool_call => |delta| try self.sink.emit(.{ .tool_input_delta = .{
                    .call_id = delta.id orelse "",
                    .delta = delta.arguments_delta,
                } }),
                else => {},
            },
            .part_end => |value| {
                var id_buffer: [64]u8 = undefined;
                const id = try std.fmt.bufPrint(&id_buffer, "part-{d}", .{value.index});
                switch (value.part) {
                    .text, .text_part, .speech => try self.sink.emit(.{ .text_end = .{ .id = id } }),
                    .thinking => try self.sink.emit(.{ .reasoning_end = .{ .id = id } }),
                    .tool_call => |call| try self.sink.emit(.{ .tool_input_end = .{
                        .call_id = call.id,
                        .name = call.name,
                        .arguments_json = call.arguments_json,
                    } }),
                    else => {},
                }
            },
            .usage => {},
        }
    }

    fn emitPartDelta(self: *Bridge, index: usize, delta: []const u8, reasoning: bool) !void {
        if (delta.len == 0) return;
        if (delta.len > self.limits.max_text_bytes) return error.UIContentTooLarge;
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "part-{d}", .{index});
        if (reasoning) {
            try self.sink.emit(.{ .reasoning_delta = .{ .id = id, .delta = delta } });
        } else {
            try self.sink.emit(.{ .text_delta = .{ .id = id, .delta = delta } });
        }
    }
};

/// One browser approval response normalized for `Agent.resumeRun`.
pub const ApprovalDecision = struct {
    approval_id: []const u8,
    approved: bool,
    reason: ?[]const u8 = null,

    pub fn resumeDecision(self: ApprovalDecision) agent_types.ResumeDecision {
        return .{
            .call_id = self.approval_id,
            .action = if (self.approved) .approve else .deny,
            .content = self.reason,
        };
    }
};

/// Arena-owned approval response parsed from a browser protocol.
pub const OwnedApprovalDecision = struct {
    arena: std.heap.ArenaAllocator,
    value: ApprovalDecision,

    pub fn deinit(self: *OwnedApprovalDecision) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Creates a custom event from a typed Zig value.
pub fn customValue(
    comptime T: type,
    gpa: std.mem.Allocator,
    name: []const u8,
    value: T,
    limits: Limits,
) ![]u8 {
    try validateIdentifier(name, limits.max_identifier_bytes);
    const encoded = try std.json.Stringify.valueAlloc(gpa, value, .{});
    errdefer gpa.free(encoded);
    if (encoded.len > limits.max_custom_json_bytes) return error.UIContentTooLarge;
    return encoded;
}

/// Bounded replay log for reconnecting SSE/browser consumers.
pub const ReplayBuffer = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    entries: std.ArrayList(Entry) = .empty,
    total_bytes: usize = 0,
    next_sequence: u64 = 1,

    pub const Entry = struct {
        sequence: u64,
        bytes: []u8,
    };

    pub fn init(gpa: std.mem.Allocator, limits: Limits) ReplayBuffer {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *ReplayBuffer) void {
        for (self.entries.items) |entry| self.gpa.free(entry.bytes);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn append(self: *ReplayBuffer, bytes: []const u8) !u64 {
        if (bytes.len == 0 or bytes.len > self.limits.max_replay_bytes) return error.UIContentTooLarge;
        while (self.entries.items.len >= self.limits.max_replay_events or
            self.total_bytes + bytes.len > self.limits.max_replay_bytes)
        {
            if (self.entries.items.len == 0) return error.UIContentTooLarge;
            const removed = self.entries.orderedRemove(0);
            self.total_bytes -= removed.bytes.len;
            self.gpa.free(removed.bytes);
        }
        const sequence = self.next_sequence;
        self.next_sequence = std.math.add(u64, sequence, 1) catch return error.UISequenceExhausted;
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        try self.entries.append(self.gpa, .{ .sequence = sequence, .bytes = copy });
        self.total_bytes += copy.len;
        return sequence;
    }

    pub fn replayAfter(self: *const ReplayBuffer, sequence: u64, sink: ReplaySink) !void {
        for (self.entries.items) |entry| {
            if (entry.sequence > sequence) try sink.emit(entry.sequence, entry.bytes);
        }
    }
};

/// Synchronous replay destination.
pub const ReplaySink = struct {
    context: ?*anyopaque = null,
    emit_fn: *const fn (context: ?*anyopaque, sequence: u64, bytes: []const u8) anyerror!void,

    pub fn emit(self: ReplaySink, sequence: u64, bytes: []const u8) !void {
        return self.emit_fn(self.context, sequence, bytes);
    }
};

/// Browser-message trust policy.
pub const SanitizePolicy = struct {
    allow_assistant_history: bool = false,
};

/// Arena-owned canonical messages accepted from browser JSON.
pub const SanitizedMessages = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const message_types.Message,

    pub fn deinit(self: *SanitizedMessages) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn sanitizeMessages(
    gpa: std.mem.Allocator,
    source: []const u8,
    policy: SanitizePolicy,
    limits: Limits,
) !SanitizedMessages {
    const Wire = struct {
        messages: []const struct {
            role: []const u8,
            content: []const u8,
        },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const parsed = try json_limits.parseLeaky(
        Wire,
        arena.allocator(),
        source,
        .{
            .max_document_bytes = limits.max_text_bytes *| limits.max_messages,
            .max_value_bytes = limits.max_text_bytes,
            .max_depth = 16,
            .max_collection_items = limits.max_messages *| 2,
        },
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
        error.InvalidUIMessage,
    );
    if (parsed.messages.len > limits.max_messages) return error.TooManyUIMessages;
    const messages = try arena.allocator().alloc(message_types.Message, parsed.messages.len);
    var count: usize = 0;
    for (parsed.messages) |message| {
        try validateText(message.content, limits.max_text_bytes);
        if (std.mem.eql(u8, message.role, "user")) {
            messages[count] = .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = message.content } }} } };
        } else if (std.mem.eql(u8, message.role, "assistant") and policy.allow_assistant_history) {
            messages[count] = .{ .response = .{ .parts = &.{.{ .text = message.content }} } };
        } else {
            return error.UntrustedUIMessageRole;
        }
        count += 1;
    }
    return .{ .arena = arena, .messages = messages[0..count] };
}

fn validateIdentifier(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum) return error.InvalidUIIdentifier;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return error.InvalidUIIdentifier;
}

fn validateText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidUIMessage;
}

fn validateJson(gpa: std.mem.Allocator, value: []const u8, maximum: usize) !void {
    if (value.len > maximum) return error.UIContentTooLarge;
    try json_limits.validateAs(
        gpa,
        value,
        .{ .max_document_bytes = maximum, .max_value_bytes = maximum, .max_depth = 64, .max_collection_items = 4_096 },
        error.InvalidUICustomEvent,
    );
}

test "UI bridge maps agent text reasoning tools approvals and custom events" {
    const Capture = struct {
        tags: [32]std.meta.Tag(Event) = undefined,
        count: usize = 0,

        fn emit(context: ?*anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.tags[self.count] = std.meta.activeTag(event);
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var bridge = Bridge{
        .sink = .{ .context = &capture, .event_fn = Capture.emit },
        .thread_id = "thread-1",
        .run_id = "run-1",
    };
    try bridge.begin();
    const sink = bridge.agentSink();
    try sink.emit(.{ .model = .{ .part_start = .{ .index = 0, .part = .{ .text = "" } } } });
    try sink.emit(.{ .model = .{ .part_delta = .{ .index = 0, .delta = .{ .text = .{ .content_delta = "hi" } } } } });
    try sink.emit(.{ .model = .{ .part_end = .{ .index = 0, .part = .{ .text = "hi" } } } });
    try sink.emit(.{ .model = .{ .part_start = .{ .index = 1, .part = .{ .thinking = .{ .content = "" } } } } });
    try sink.emit(.{ .model = .{ .part_delta = .{ .index = 1, .delta = .{ .thinking = .{ .content_delta = "why" } } } } });
    try sink.emit(.{ .model = .{ .part_end = .{ .index = 1, .part = .{ .thinking = .{ .content = "why" } } } } });
    const call = message_types.ToolCall{ .id = "call-1", .name = "tool", .arguments_json = "{}" };
    try sink.emit(.{ .model = .{ .part_start = .{ .index = 2, .part = .{ .tool_call = call } } } });
    try sink.emit(.{ .model = .{ .part_delta = .{ .index = 2, .delta = .{ .tool_call = .{
        .id = "call-1",
        .arguments_delta = "{}",
    } } } } });
    try sink.emit(.{ .model = .{ .part_end = .{ .index = 2, .part = .{ .tool_call = call } } } });
    try sink.emit(.{ .model = .{ .part_delta = .{ .index = 3, .delta = .{ .speech = .{
        .transcript_delta = "spoken",
    } } } } });
    try sink.emit(.{ .function_tool_call = .{ .call = call } });
    try sink.emit(.{ .function_tool_result = .{ .result = .{
        .call_id = "call-1",
        .name = "tool",
        .content = "{\"ok\":true}",
    } } });
    try sink.emit(.{ .deferred_tool_requests = .{ .requests = &.{.{
        .call_id = "approval-1",
        .name = "delete",
        .arguments_json = "{}",
        .execution = .requires_approval,
    }} } });
    try bridge.emitCustom(std.testing.allocator, "progress", "{\"percent\":50}");
    try bridge.finish();
    try bridge.fail(error.ProviderFailed);
    try std.testing.expectEqual(std.meta.Tag(Event).run_start, capture.tags[0]);
    try std.testing.expectEqual(std.meta.Tag(Event).approval_request, capture.tags[13]);
    try std.testing.expectEqual(std.meta.Tag(Event).run_error, capture.tags[capture.count - 1]);
}

test "UI replay and sanitization are bounded and deterministic" {
    const Capture = struct {
        sequences: [4]u64 = undefined,
        count: usize = 0,
        fn emit(context: ?*anyopaque, sequence: u64, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.sequences[self.count] = sequence;
            self.count += 1;
        }
    };
    var replay = ReplayBuffer.init(std.testing.allocator, .{ .max_replay_events = 2, .max_replay_bytes = 8 });
    defer replay.deinit();
    _ = try replay.append("one");
    _ = try replay.append("two");
    const third = try replay.append("three");
    var capture: Capture = .{};
    try replay.replayAfter(1, .{ .context = &capture, .emit_fn = Capture.emit });
    try std.testing.expectEqual(@as(u64, 3), third);
    try std.testing.expectEqual(@as(usize, 2), capture.count);

    var sanitized = try sanitizeMessages(
        std.testing.allocator,
        "{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"},{\"role\":\"assistant\",\"content\":\"hi\"}]}",
        .{ .allow_assistant_history = true },
        .{},
    );
    defer sanitized.deinit();
    try std.testing.expectEqual(@as(usize, 2), sanitized.messages.len);
    try std.testing.expectError(
        error.UntrustedUIMessageRole,
        sanitizeMessages(
            std.testing.allocator,
            "{\"messages\":[{\"role\":\"system\",\"content\":\"unsafe\"}]}",
            .{},
            .{},
        ),
    );
    const custom = try customValue(struct { percent: u8 }, std.testing.allocator, "progress", .{ .percent = 50 }, .{});
    defer std.testing.allocator.free(custom);
    try std.testing.expectEqualStrings("{\"percent\":50}", custom);
    try std.testing.expectError(
        error.UIContentTooLarge,
        customValue(struct { percent: u8 }, std.testing.allocator, "progress", .{ .percent = 50 }, .{
            .max_custom_json_bytes = 1,
        }),
    );
    const decision = ApprovalDecision{ .approval_id = "call", .approved = false, .reason = "denied" };
    try std.testing.expectEqual(agent_types.ResumeAction.deny, decision.resumeDecision().action);

    const Support = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var buffer = ReplayBuffer.init(gpa, .{});
            defer buffer.deinit();
            _ = try buffer.append("owned");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Support.run, .{});
}
