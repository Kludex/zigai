//! Vercel AI SDK UI message stream v1 SSE adapter.

const std = @import("std");
const agent_types = @import("../agent.zig");
const base = @import("base.zig");
const json_limits = @import("../json.zig");

pub const stream_header_name = "x-vercel-ai-ui-message-stream";
pub const stream_header_value = "v1";

/// Encodes one UI message chunk as an SSE `data:` record.
pub fn encode(gpa: std.mem.Allocator, event: base.Event) ![]u8 {
    const json = switch (event) {
        .run_start => |value| try stringify(gpa, .{ .type = "start", .messageId = value.run_id }),
        .run_finish => try stringify(gpa, .{ .type = "finish" }),
        .run_error => |value| try stringify(gpa, .{ .type = "error", .errorText = value.message }),
        .text_start => |value| try stringify(gpa, .{ .type = "text-start", .id = value.id }),
        .text_delta => |value| try stringify(gpa, .{ .type = "text-delta", .id = value.id, .delta = value.delta }),
        .text_end => |value| try stringify(gpa, .{ .type = "text-end", .id = value.id }),
        .reasoning_start => |value| try stringify(gpa, .{ .type = "reasoning-start", .id = value.id }),
        .reasoning_delta => |value| try stringify(gpa, .{
            .type = "reasoning-delta",
            .id = value.id,
            .delta = value.delta,
        }),
        .reasoning_end => |value| try stringify(gpa, .{ .type = "reasoning-end", .id = value.id }),
        .tool_input_start => |value| try stringify(gpa, .{
            .type = "tool-input-start",
            .toolCallId = value.call_id,
            .toolName = value.name,
        }),
        .tool_input_delta => |value| try stringify(gpa, .{
            .type = "tool-input-delta",
            .toolCallId = value.call_id,
            .inputTextDelta = value.delta,
        }),
        .tool_input_end => |value| try encodeToolInput(gpa, value),
        .tool_result => |value| try encodeToolResult(gpa, value),
        .approval_request => |value| try stringify(gpa, .{
            .type = "tool-approval-request",
            .approvalId = value.approval_id,
            .toolCallId = value.call_id,
        }),
        .approval_response => |value| try stringify(gpa, .{
            .type = "tool-approval-response",
            .approvalId = value.approval_id,
            .approved = value.approved,
            .reason = value.reason,
        }),
        .custom => |value| try encodeCustom(gpa, value),
    };
    defer gpa.free(json);
    return std.fmt.allocPrint(gpa, "data: {s}\n\n", .{json});
}

/// Encodes the terminal SSE marker.
pub fn encodeDone(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, "data: [DONE]\n\n");
}

fn encodeToolInput(gpa: std.mem.Allocator, value: base.Event.ToolEnd) ![]u8 {
    const parsed = try parseValue(gpa, value.arguments_json);
    defer parsed.deinit();
    return stringify(gpa, .{
        .type = "tool-input-available",
        .toolCallId = value.call_id,
        .toolName = value.name,
        .input = parsed.value,
    });
}

fn encodeToolResult(gpa: std.mem.Allocator, value: base.Event.ToolResult) ![]u8 {
    if (value.is_error) return stringify(gpa, .{
        .type = "tool-output-error",
        .toolCallId = value.call_id,
        .errorText = value.content_json,
    });
    const parsed = try parseValue(gpa, value.content_json);
    defer parsed.deinit();
    return stringify(gpa, .{
        .type = "tool-output-available",
        .toolCallId = value.call_id,
        .output = parsed.value,
    });
}

fn encodeCustom(gpa: std.mem.Allocator, value: base.Event.Custom) ![]u8 {
    const parsed = try parseValue(gpa, value.value_json);
    defer parsed.deinit();
    const event_type = try std.fmt.allocPrint(gpa, "data-{s}", .{value.name});
    defer gpa.free(event_type);
    return stringify(gpa, .{ .type = event_type, .data = parsed.value });
}

/// Parses a Vercel approval response chunk or SSE record.
pub fn parseApproval(
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: base.Limits,
) !base.OwnedApprovalDecision {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const json = if (std.mem.startsWith(u8, trimmed, "data:"))
        std.mem.trim(u8, trimmed[5..], " \t")
    else
        trimmed;
    const Wire = struct {
        type: []const u8,
        approvalId: []const u8,
        approved: bool,
        reason: ?[]const u8 = null,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const parsed = try json_limits.parseLeaky(
        Wire,
        arena.allocator(),
        json,
        .{
            .max_document_bytes = limits.max_custom_json_bytes,
            .max_value_bytes = limits.max_text_bytes,
            .max_depth = 16,
            .max_collection_items = 32,
        },
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        error.InvalidUIApproval,
    );
    if (!std.mem.eql(u8, parsed.type, "tool-approval-response")) return error.InvalidUIApproval;
    return .{ .arena = arena, .value = .{
        .approval_id = parsed.approvalId,
        .approved = parsed.approved,
        .reason = parsed.reason,
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

test "Vercel UI encodes event families SSE completion and approvals" {
    const events = [_]base.Event{
        .{ .run_start = .{ .thread_id = "t", .run_id = "r" } },
        .{ .run_finish = .{ .thread_id = "t", .run_id = "r" } },
        .{ .run_error = .{ .message = "failed" } },
        .{ .text_start = .{ .id = "m" } },
        .{ .text_delta = .{ .id = "m", .delta = "hi" } },
        .{ .text_end = .{ .id = "m" } },
        .{ .reasoning_start = .{ .id = "q" } },
        .{ .reasoning_delta = .{ .id = "q", .delta = "why" } },
        .{ .reasoning_end = .{ .id = "q" } },
        .{ .tool_input_start = .{ .call_id = "c", .name = "tool" } },
        .{ .tool_input_delta = .{ .call_id = "c", .delta = "{}" } },
        .{ .tool_input_end = .{ .call_id = "c", .name = "tool", .arguments_json = "{}" } },
        .{ .tool_result = .{ .message_id = "m2", .call_id = "c", .content_json = "{\"ok\":true}" } },
        .{ .tool_result = .{ .message_id = "m3", .call_id = "c2", .content_json = "failed", .is_error = true } },
        .{ .approval_request = .{
            .thread_id = "t",
            .run_id = "r",
            .approval_id = "a",
            .call_id = "c",
            .tool_name = "tool",
            .arguments_json = "{}",
        } },
        .{ .approval_response = .{ .approval_id = "a", .approved = true } },
        .{ .custom = .{ .name = "progress", .value_json = "{\"value\":1}" } },
    };
    for (events) |event| {
        const encoded = try encode(std.testing.allocator, event);
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(std.mem.startsWith(u8, encoded, "data: {"));
    }
    const done = try encodeDone(std.testing.allocator);
    defer std.testing.allocator.free(done);
    try std.testing.expectEqualStrings("data: [DONE]\n\n", done);
    var decision = try parseApproval(
        std.testing.allocator,
        "data: {\"type\":\"tool-approval-response\",\"approvalId\":\"a\",\"approved\":false,\"reason\":\"no\"}",
        .{},
    );
    defer decision.deinit();
    try std.testing.expect(!decision.value.approved);
    try std.testing.expectEqual(agent_types.ResumeAction.deny, decision.value.resumeDecision().action);
    const Support = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var parsed = try parseApproval(
                gpa,
                "{\"type\":\"tool-approval-response\",\"approvalId\":\"a\",\"approved\":true}",
                .{},
            );
            parsed.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Support.run, .{});
}
