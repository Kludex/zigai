//! Durable paused-tool decision wire documents.

const std = @import("std");
const model_types = @import("../model.zig");

/// Current durable paused-decision wire version.
pub const format_version: u8 = 1;
/// Maximum encoded paused-decision request or response size.
pub const max_document_bytes: usize = 2 * 1024 * 1024;

/// Durable paused-decision payload failures.
pub const Error = error{
    /// The proposed decision request is malformed.
    InvalidApprovalRequest,
    /// The persisted worker decision is malformed.
    InvalidApprovalResponse,
    /// The request or response uses an unsupported schema version.
    UnsupportedApprovalWireVersion,
};

/// Actions accepted by paused approval and external-result calls.
pub const Action = enum { approve, deny, result };

/// Serializable paused-call decision independent of the agent module.
pub const Decision = struct {
    call_id: []const u8,
    action: Action,
    content: ?[]const u8 = null,
    is_error: bool = false,
};

const RequestDocument = struct {
    version: u8,
    call: model_types.ToolCall,
    execution: model_types.ToolExecution,
    arguments_json: []const u8,
    proposed: Decision,
};

/// Arena-owned paused-call decision request reconstructed by a worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    call: model_types.ToolCall,
    execution: model_types.ToolExecution,
    arguments_json: []const u8,
    proposed: Decision,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Serializes one proposed approval or external-result decision.
pub fn stringifyRequest(
    allocator: std.mem.Allocator,
    call: model_types.ToolCall,
    execution: model_types.ToolExecution,
    arguments_json: []const u8,
    proposed: Decision,
) ![]u8 {
    try validate(call, execution, arguments_json, proposed, allocator, Error.InvalidApprovalRequest);
    const encoded = try std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .call = call,
        .execution = execution,
        .arguments_json = arguments_json,
        .proposed = proposed,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidApprovalRequest;
    return encoded;
}

/// Parses one proposed durable paused-call decision.
pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidApprovalRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, arena.allocator(), source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidApprovalRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedApprovalWireVersion;
    try validate(
        parsed.call,
        parsed.execution,
        parsed.arguments_json,
        parsed.proposed,
        arena.allocator(),
        Error.InvalidApprovalRequest,
    );
    return .{
        .arena = arena,
        .call = parsed.call,
        .execution = parsed.execution,
        .arguments_json = parsed.arguments_json,
        .proposed = parsed.proposed,
    };
}

const ResponseDocument = struct {
    version: u8,
    decision: Decision,
};

/// Serializes the decision persisted by an approval worker.
pub fn stringifyResponse(allocator: std.mem.Allocator, decision: Decision) ![]u8 {
    try validateDecision(decision, Error.InvalidApprovalResponse);
    const encoded = try std.json.Stringify.valueAlloc(allocator, ResponseDocument{
        .version = format_version,
        .decision = decision,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidApprovalResponse;
    return encoded;
}

/// Arena-owned approval decision returned by a durable worker.
pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    decision: Decision,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses one persisted approval decision.
pub fn parseResponse(allocator: std.mem.Allocator, source: []const u8) !OwnedResponse {
    if (source.len > max_document_bytes) return Error.InvalidApprovalResponse;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(ResponseDocument, arena.allocator(), source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidApprovalResponse,
    };
    if (parsed.version != format_version) return Error.UnsupportedApprovalWireVersion;
    try validateDecision(parsed.decision, Error.InvalidApprovalResponse);
    return .{ .arena = arena, .decision = parsed.decision };
}

fn validate(
    call: model_types.ToolCall,
    execution: model_types.ToolExecution,
    arguments_json: []const u8,
    decision: Decision,
    allocator: std.mem.Allocator,
    invalid: anyerror,
) !void {
    if (call.id.len == 0 or call.name.len == 0 or execution == .immediate) return invalid;
    if (!std.mem.eql(u8, call.id, decision.call_id)) return invalid;
    var arguments = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid,
    };
    defer arguments.deinit();
    if (arguments.value != .object) return invalid;
    try validateDecision(decision, invalid);
}

fn validateDecision(decision: Decision, invalid: anyerror) !void {
    if (decision.call_id.len == 0) return invalid;
}

test "durable approval request and response round trip" {
    const decision = Decision{ .call_id = "call-1", .action = .approve };
    const request_json = try stringifyRequest(
        std.testing.allocator,
        .{ .id = "call-1", .name = "charge", .arguments_json = "{}" },
        .requires_approval,
        "{\"amount\":10}",
        decision,
    );
    defer std.testing.allocator.free(request_json);
    var request = try parseRequest(std.testing.allocator, request_json);
    defer request.deinit();
    try std.testing.expectEqualStrings("charge", request.call.name);

    const unsupported = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        request_json,
        "\"version\":1",
        "\"version\":2",
    );
    defer std.testing.allocator.free(unsupported);
    try std.testing.expectError(
        Error.UnsupportedApprovalWireVersion,
        parseRequest(std.testing.allocator, unsupported),
    );

    const response_json = try stringifyResponse(std.testing.allocator, decision);
    defer std.testing.allocator.free(response_json);
    var response = try parseResponse(std.testing.allocator, response_json);
    defer response.deinit();
    try std.testing.expectEqual(Action.approve, response.decision.action);
}

test "durable approval wire rejects invalid decisions and versions" {
    try std.testing.expectError(Error.InvalidApprovalRequest, stringifyRequest(
        std.testing.allocator,
        .{ .id = "call", .name = "x", .arguments_json = "{}" },
        .immediate,
        "{}",
        .{ .call_id = "call", .action = .approve },
    ));
    try std.testing.expectError(Error.InvalidApprovalResponse, stringifyResponse(
        std.testing.allocator,
        .{ .call_id = "", .action = .result },
    ));
    try std.testing.expectError(Error.InvalidApprovalRequest, stringifyRequest(
        std.testing.allocator,
        .{ .id = "call", .name = "x", .arguments_json = "{}" },
        .requires_approval,
        "[]",
        .{ .call_id = "call", .action = .approve },
    ));
    try std.testing.expectError(Error.InvalidApprovalRequest, stringifyRequest(
        std.testing.allocator,
        .{ .id = "call", .name = "x", .arguments_json = "{}" },
        .requires_approval,
        "{}",
        .{ .call_id = "other", .action = .approve },
    ));
    try std.testing.expectError(Error.InvalidApprovalRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.InvalidApprovalResponse, parseResponse(std.testing.allocator, "{}"));
    try std.testing.expectError(
        Error.UnsupportedApprovalWireVersion,
        parseResponse(std.testing.allocator, "{\"version\":2,\"decision\":{\"call_id\":\"call\",\"action\":\"approve\",\"content\":null,\"is_error\":false}}"),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(Error.InvalidApprovalRequest, parseRequest(std.testing.allocator, oversized));
    try std.testing.expectError(Error.InvalidApprovalResponse, parseResponse(std.testing.allocator, oversized));

    const large_content = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(large_content);
    @memset(large_content, 'a');
    try std.testing.expectError(Error.InvalidApprovalResponse, stringifyResponse(
        std.testing.allocator,
        .{ .call_id = "call", .action = .deny, .content = large_content },
    ));
    try std.testing.expectError(Error.InvalidApprovalRequest, stringifyRequest(
        std.testing.allocator,
        .{ .id = "call", .name = "x", .arguments_json = "{}" },
        .requires_approval,
        "{}",
        .{ .call_id = "call", .action = .deny, .content = large_content },
    ));
}

fn checkAllocationFailure(allocator: std.mem.Allocator) !void {
    const decision = Decision{ .call_id = "call", .action = .approve };
    const request_json = try stringifyRequest(
        allocator,
        .{ .id = "call", .name = "x", .arguments_json = "{}" },
        .requires_approval,
        "{}",
        decision,
    );
    defer allocator.free(request_json);
    var request = try parseRequest(allocator, request_json);
    request.deinit();
    const response_json = try stringifyResponse(allocator, decision);
    defer allocator.free(response_json);
    var response = try parseResponse(allocator, response_json);
    response.deinit();
}

test "durable approval payload releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailure, .{});
}
