//! Durable function-tool and MCP-tool request/response wire documents.
//!
//! The payload contains replay-safe run context but excludes dependency,
//! cancellation, I/O, and deadline pointers. Registered workers attach those
//! process-local values before invoking contextual tools.

const std = @import("std");
const capability_types = @import("../capability.zig");
const history = @import("../history.zig");
const model_types = @import("../model.zig");
const usage_types = @import("../usage.zig");

pub const format_version: u8 = 1;
pub const max_document_bytes: usize = 2 * 1024 * 1024;

pub const Error = error{
    InvalidToolRequest,
    InvalidToolResponse,
    UnsupportedToolWireVersion,
};

const RequestDocument = struct {
    version: u8,
    payload_kind: enum { tool_call },
    call: model_types.ToolCall,
    arguments_json: []const u8,
    messages_json: []const u8,
    usage: usage_types.RunUsage,
    model_requests: usize,
    capabilities: capability_types.Snapshot,
    retry_number: usize,
    approved: bool,
};

/// Arena-owned input reconstructed by a registered tool worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    call: model_types.ToolCall,
    arguments_json: []const u8,
    run_context: model_types.ToolRunContext,
    retry_number: usize,
    approved: bool,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn stringifyRequest(
    allocator: std.mem.Allocator,
    call: model_types.ToolCall,
    arguments_json: []const u8,
    run_context: model_types.ToolRunContext,
    retry_number: usize,
    approved: bool,
) ![]u8 {
    const messages_json = try history.stringify(allocator, run_context.messages);
    defer allocator.free(messages_json);
    return std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .payload_kind = .tool_call,
        .call = call,
        .arguments_json = arguments_json,
        .messages_json = messages_json,
        .usage = run_context.usage,
        .model_requests = run_context.model_requests,
        .capabilities = run_context.capabilities,
        .retry_number = retry_number,
        .approved = approved,
    }, .{});
}

pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidToolRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidToolRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedToolWireVersion;
    const messages = history.parseLeaky(memory, parsed.messages_json) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidToolRequest,
    };
    return .{
        .arena = arena,
        .call = parsed.call,
        .arguments_json = parsed.arguments_json,
        .run_context = .{
            .messages = messages,
            .usage = parsed.usage,
            .model_requests = parsed.model_requests,
            .capabilities = parsed.capabilities,
        },
        .retry_number = parsed.retry_number,
        .approved = parsed.approved,
    };
}

const ResponseDocument = struct {
    version: u8,
    content: []const u8,
    follow_up_history_json: []const u8,
};

pub fn stringifyResponse(allocator: std.mem.Allocator, output: model_types.ToolOutput) ![]u8 {
    const messages = try allocator.alloc(model_types.Message, output.follow_up_messages.len);
    defer allocator.free(messages);
    for (output.follow_up_messages, messages) |message, *value| value.* = .{ .request = message };
    const follow_up_json = try history.stringify(allocator, messages);
    defer allocator.free(follow_up_json);
    return std.json.Stringify.valueAlloc(allocator, ResponseDocument{
        .version = format_version,
        .content = output.content,
        .follow_up_history_json = follow_up_json,
    }, .{});
}

/// Arena-owned tool output returned by a durable runtime success record.
pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    value: model_types.ToolOutput,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseResponse(allocator: std.mem.Allocator, source: []const u8) !OwnedResponse {
    if (source.len > max_document_bytes) return Error.InvalidToolResponse;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(ResponseDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidToolResponse,
    };
    if (parsed.version != format_version) return Error.UnsupportedToolWireVersion;
    const messages = history.parseLeaky(memory, parsed.follow_up_history_json) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidToolResponse,
    };
    const follow_ups = try memory.alloc(model_types.RequestMessage, messages.len);
    for (messages, follow_ups) |message, *follow_up| follow_up.* = switch (message) {
        .request => |request| request,
        .response => return Error.InvalidToolResponse,
    };
    return .{ .arena = arena, .value = .{
        .content = parsed.content,
        .follow_up_messages = follow_ups,
    } };
}

test "durable tool request and rich response round trip" {
    const request_json = try stringifyRequest(
        std.testing.allocator,
        .{ .id = "call-1", .name = "weather", .arguments_json = "{\"city\":\"Madrid\"}" },
        "{\"city\":\"Barcelona\"}",
        .{
            .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "weather" } }} } }},
            .usage = .{ .input_tokens = 3 },
            .model_requests = 1,
            .capabilities = .{ .available_ids = &.{"maps"} },
        },
        2,
        true,
    );
    defer std.testing.allocator.free(request_json);
    var request = try parseRequest(std.testing.allocator, request_json);
    defer request.deinit();
    try std.testing.expectEqualStrings("weather", request.call.name);
    try std.testing.expectEqualStrings("{\"city\":\"Barcelona\"}", request.arguments_json);
    try std.testing.expectEqual(@as(u64, 3), request.run_context.usage.input_tokens);
    try std.testing.expectEqualStrings("maps", request.run_context.capabilities.available_ids[0]);
    try std.testing.expect(request.approved);

    const response_json = try stringifyResponse(std.testing.allocator, .{
        .content = "sunny",
        .follow_up_messages = &.{.{ .parts = &.{.{ .user_prompt = .{ .text = "bring water" } }} }},
    });
    defer std.testing.allocator.free(response_json);
    var response = try parseResponse(std.testing.allocator, response_json);
    defer response.deinit();
    try std.testing.expectEqualStrings("sunny", response.value.content);
    try std.testing.expectEqualStrings(
        "bring water",
        response.value.follow_up_messages[0].parts[0].user_prompt.text,
    );
}

test "durable tool payloads reject malformed versions and response roles" {
    try std.testing.expectError(Error.InvalidToolRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.InvalidToolResponse, parseResponse(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.UnsupportedToolWireVersion, parseResponse(
        std.testing.allocator,
        "{\"version\":2,\"content\":\"x\",\"follow_up_history_json\":\"{\\\"version\\\":2,\\\"messages\\\":[]}\"}",
    ));
    try std.testing.expectError(Error.InvalidToolResponse, parseResponse(
        std.testing.allocator,
        "{\"version\":1,\"content\":\"x\",\"follow_up_history_json\":\"{\\\"version\\\":2,\\\"messages\\\":[{\\\"kind\\\":\\\"response\\\",\\\"parts\\\":[]}]}\"}",
    ));
    try std.testing.expectError(Error.InvalidToolResponse, parseResponse(
        std.testing.allocator,
        "{\"version\":1,\"content\":\"x\",\"follow_up_history_json\":\"{}\"}",
    ));

    const request_json = try stringifyRequest(
        std.testing.allocator,
        .{ .id = "call", .name = "tool", .arguments_json = "{}" },
        "{}",
        .{},
        0,
        false,
    );
    defer std.testing.allocator.free(request_json);
    const unsupported_request = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        request_json,
        "\"version\":1",
        "\"version\":2",
    );
    defer std.testing.allocator.free(unsupported_request);
    try std.testing.expectError(
        Error.UnsupportedToolWireVersion,
        parseRequest(std.testing.allocator, unsupported_request),
    );
    var request_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request_json, .{});
    defer request_value.deinit();
    try request_value.value.object.put(std.testing.allocator, "messages_json", .{ .string = "{}" });
    const invalid_history = try std.json.Stringify.valueAlloc(std.testing.allocator, request_value.value, .{});
    defer std.testing.allocator.free(invalid_history);
    try std.testing.expectError(Error.InvalidToolRequest, parseRequest(std.testing.allocator, invalid_history));

    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(Error.InvalidToolRequest, parseRequest(std.testing.allocator, oversized));
    try std.testing.expectError(Error.InvalidToolResponse, parseResponse(std.testing.allocator, oversized));
}

fn checkRequestAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = stringifyRequest(
        allocator,
        .{ .id = "call", .name = "tool", .arguments_json = "{}" },
        "{}",
        .{},
        0,
        false,
    ) catch |failure| return switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        else => failure,
    };
    defer allocator.free(encoded);
    var parsed = try parseRequest(allocator, encoded);
    parsed.deinit();
}

fn checkResponseAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = stringifyResponse(allocator, .{ .content = "ok" }) catch |failure| return switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        else => failure,
    };
    defer allocator.free(encoded);
    var parsed = try parseResponse(allocator, encoded);
    parsed.deinit();
}

test "durable tool payloads release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRequestAllocationFailure,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResponseAllocationFailure,
        .{},
    );
}
