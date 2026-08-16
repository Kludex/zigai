//! AG-UI event JSON and interrupt-resume approval adapter.

const std = @import("std");
const base = @import("base.zig");
const json_limits = @import("../json.zig");

/// Encodes one AG-UI event JSON object.
pub fn encode(gpa: std.mem.Allocator, event: base.Event) ![]u8 {
    return switch (event) {
        .run_start => |value| stringify(gpa, .{
            .type = "RUN_STARTED",
            .threadId = value.thread_id,
            .runId = value.run_id,
        }),
        .run_finish => |value| stringify(gpa, .{
            .type = "RUN_FINISHED",
            .threadId = value.thread_id,
            .runId = value.run_id,
            .outcome = .{ .type = "success" },
        }),
        .run_error => |value| stringify(gpa, .{
            .type = "RUN_ERROR",
            .message = value.message,
            .code = value.code,
        }),
        .text_start => |value| stringify(gpa, .{
            .type = "TEXT_MESSAGE_START",
            .messageId = value.id,
            .role = "assistant",
        }),
        .text_delta => |value| stringify(gpa, .{
            .type = "TEXT_MESSAGE_CONTENT",
            .messageId = value.id,
            .delta = value.delta,
        }),
        .text_end => |value| stringify(gpa, .{
            .type = "TEXT_MESSAGE_END",
            .messageId = value.id,
        }),
        .reasoning_start => |value| stringify(gpa, .{
            .type = "REASONING_MESSAGE_START",
            .messageId = value.id,
            .role = "reasoning",
        }),
        .reasoning_delta => |value| stringify(gpa, .{
            .type = "REASONING_MESSAGE_CONTENT",
            .messageId = value.id,
            .delta = value.delta,
        }),
        .reasoning_end => |value| stringify(gpa, .{
            .type = "REASONING_MESSAGE_END",
            .messageId = value.id,
        }),
        .tool_input_start => |value| stringify(gpa, .{
            .type = "TOOL_CALL_START",
            .toolCallId = value.call_id,
            .toolCallName = value.name,
        }),
        .tool_input_delta => |value| stringify(gpa, .{
            .type = "TOOL_CALL_ARGS",
            .toolCallId = value.call_id,
            .delta = value.delta,
        }),
        .tool_input_end => |value| stringify(gpa, .{
            .type = "TOOL_CALL_END",
            .toolCallId = value.call_id,
        }),
        .tool_result => |value| stringify(gpa, .{
            .type = "TOOL_CALL_RESULT",
            .messageId = value.message_id,
            .toolCallId = value.call_id,
            .content = value.content_json,
            .role = "tool",
        }),
        .approval_request => |value| encodeApprovalRequest(gpa, value),
        .approval_response => |value| encodeCustom(gpa, "tool_approval_response", .{
            .approvalId = value.approval_id,
            .approved = value.approved,
            .reason = value.reason,
        }),
        .custom => |value| encodeCustomJson(gpa, value.name, value.value_json),
    };
}

fn encodeApprovalRequest(gpa: std.mem.Allocator, value: base.Event.ApprovalRequest) ![]u8 {
    const arguments = try parseValue(gpa, value.arguments_json);
    defer arguments.deinit();
    return stringify(gpa, .{
        .type = "RUN_FINISHED",
        .threadId = value.thread_id,
        .runId = value.run_id,
        .outcome = .{
            .type = "interrupt",
            .interrupts = &.{.{
                .id = value.approval_id,
                .reason = "tool_approval",
                .toolCallId = value.call_id,
                .metadata = .{ .toolName = value.tool_name, .arguments = arguments.value },
            }},
        },
    });
}

fn encodeCustom(gpa: std.mem.Allocator, name: []const u8, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("CUSTOM");
    try json.objectField("name");
    try json.write(name);
    try json.objectField("value");
    try json.write(value);
    try json.endObject();
    return output.toOwnedSlice();
}

fn encodeCustomJson(gpa: std.mem.Allocator, name: []const u8, value_json: []const u8) ![]u8 {
    const parsed = try parseValue(gpa, value_json);
    defer parsed.deinit();
    return encodeCustom(gpa, name, parsed.value);
}

/// Parses AG-UI `RunAgentInput.resume` into one approval decision.
pub fn parseApproval(
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: base.Limits,
) !base.OwnedApprovalDecision {
    const Wire = struct {
        @"resume": []const struct {
            interruptId: []const u8,
            status: []const u8,
            payload: ?std.json.Value = null,
        },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const parsed = try json_limits.parseLeaky(
        Wire,
        arena.allocator(),
        source,
        .{
            .max_document_bytes = limits.max_custom_json_bytes,
            .max_value_bytes = limits.max_custom_json_bytes,
            .max_depth = 32,
            .max_collection_items = 64,
        },
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        error.InvalidUIApproval,
    );
    if (parsed.@"resume".len != 1) return error.InvalidUIApproval;
    const resume_entry = parsed.@"resume"[0];
    if (!std.mem.eql(u8, resume_entry.status, "resolved") or
        resume_entry.payload == null or resume_entry.payload.? != .object)
        return error.InvalidUIApproval;
    const payload = resume_entry.payload.?.object;
    const approved_value = payload.get("approved") orelse return error.InvalidUIApproval;
    if (approved_value != .bool) return error.InvalidUIApproval;
    const reason = if (payload.get("reason")) |value|
        if (value == .string) value.string else return error.InvalidUIApproval
    else
        null;
    return .{ .arena = arena, .value = .{
        .approval_id = resume_entry.interruptId,
        .approved = approved_value.bool,
        .reason = reason,
    } };
}

fn stringify(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

fn parseValue(gpa: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return json_limits.parse(
        std.json.Value,
        gpa,
        source,
        json_limits.defaults.tool_payload,
        .{ .allocate = .alloc_always },
        error.InvalidUICustomEvent,
    );
}

test "AG-UI encodes every event family and parses interrupt approval" {
    const events = [_]base.Event{
        .{ .run_start = .{ .thread_id = "t", .run_id = "r" } },
        .{ .run_finish = .{ .thread_id = "t", .run_id = "r" } },
        .{ .run_error = .{ .message = "failed", .code = "Error" } },
        .{ .text_start = .{ .id = "m" } },
        .{ .text_delta = .{ .id = "m", .delta = "hi" } },
        .{ .text_end = .{ .id = "m" } },
        .{ .reasoning_start = .{ .id = "q" } },
        .{ .reasoning_delta = .{ .id = "q", .delta = "why" } },
        .{ .reasoning_end = .{ .id = "q" } },
        .{ .tool_input_start = .{ .call_id = "c", .name = "tool" } },
        .{ .tool_input_delta = .{ .call_id = "c", .delta = "{}" } },
        .{ .tool_input_end = .{ .call_id = "c", .name = "tool", .arguments_json = "{}" } },
        .{ .tool_result = .{ .message_id = "m2", .call_id = "c", .content_json = "{}" } },
        .{ .approval_request = .{
            .thread_id = "t",
            .run_id = "r",
            .approval_id = "a",
            .call_id = "c",
            .tool_name = "tool",
            .arguments_json = "{}",
        } },
        .{ .approval_response = .{ .approval_id = "a", .approved = false, .reason = "no" } },
        .{ .custom = .{ .name = "progress", .value_json = "{\"value\":1}" } },
    };
    for (events) |event| {
        const encoded = try encode(std.testing.allocator, event);
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(encoded.len > 10);
    }
    var decision = try parseApproval(
        std.testing.allocator,
        "{\"resume\":[{\"interruptId\":\"a\",\"status\":\"resolved\",\"payload\":{\"approved\":true,\"reason\":\"ok\"}}]}",
        .{},
    );
    defer decision.deinit();
    try std.testing.expect(decision.value.approved);
    try std.testing.expectEqualStrings("a", decision.value.approval_id);
}
