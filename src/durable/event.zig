//! Durable event-delivery wire documents.
//!
//! Event workers own external delivery. The workflow process never invokes a
//! process-local callback after replaying one of these persisted operations.

const std = @import("std");

/// Current durable event wire version.
pub const format_version: u8 = 1;
/// Maximum encoded event request size.
pub const max_document_bytes: usize = 2 * 1024 * 1024;

/// Durable event payload failures.
pub const Error = error{
    InvalidEventRequest,
    UnsupportedEventWireVersion,
};

/// Closed event source vocabulary understood by registered delivery workers.
pub const Source = enum {
    mcp,
};

const RequestDocument = struct {
    version: u8,
    source: Source,
    parent_sequence: u64,
    event_index: usize,
    event_json: []const u8,
};

/// Arena-owned event request reconstructed by a delivery worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    source: Source,
    parent_sequence: u64,
    event_index: usize,
    event_json: []const u8,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Serializes one event with its deterministic position in the parent result.
pub fn stringifyRequest(
    allocator: std.mem.Allocator,
    source: Source,
    parent_sequence: u64,
    event_index: usize,
    event_json: []const u8,
) ![]u8 {
    try validateEvent(allocator, event_json);
    const encoded = try std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .source = source,
        .parent_sequence = parent_sequence,
        .event_index = event_index,
        .event_json = event_json,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidEventRequest;
    return encoded;
}

/// Parses one durable event request. Its slices borrow from the returned arena.
pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidEventRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidEventRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedEventWireVersion;
    try validateEvent(memory, parsed.event_json);
    return .{
        .arena = arena,
        .source = parsed.source,
        .parent_sequence = parsed.parent_sequence,
        .event_index = parsed.event_index,
        .event_json = parsed.event_json,
    };
}

fn validateEvent(allocator: std.mem.Allocator, source: []const u8) !void {
    if (source.len > max_document_bytes) return Error.InvalidEventRequest;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{
        .allocate = .alloc_if_needed,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidEventRequest,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidEventRequest;
}

test "durable event request round trips and rejects invalid input" {
    const encoded = try stringifyRequest(
        std.testing.allocator,
        .mcp,
        7,
        2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
    );
    defer std.testing.allocator.free(encoded);
    var parsed = try parseRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(Source.mcp, parsed.source);
    try std.testing.expectEqual(@as(u64, 7), parsed.parent_sequence);
    try std.testing.expectEqual(@as(usize, 2), parsed.event_index);

    try std.testing.expectError(
        Error.InvalidEventRequest,
        stringifyRequest(std.testing.allocator, .mcp, 1, 0, "[]"),
    );
    try std.testing.expectError(Error.InvalidEventRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(
        Error.UnsupportedEventWireVersion,
        parseRequest(std.testing.allocator, "{\"version\":2,\"source\":\"mcp\",\"parent_sequence\":1,\"event_index\":0,\"event_json\":\"{}\"}"),
    );
    try std.testing.expectError(
        Error.InvalidEventRequest,
        parseRequest(std.testing.allocator, "{\"version\":1,\"source\":\"mcp\",\"parent_sequence\":1,\"event_index\":0,\"event_json\":\"bad\"}"),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(Error.InvalidEventRequest, parseRequest(std.testing.allocator, oversized));
    try std.testing.expectError(
        Error.InvalidEventRequest,
        stringifyRequest(std.testing.allocator, .mcp, 1, 0, oversized),
    );

    const large_event = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(large_event);
    @memcpy(large_event[0..6], "{\"x\":\"");
    @memset(large_event[6 .. large_event.len - 2], 'a');
    @memcpy(large_event[large_event.len - 2 ..], "\"}");
    try std.testing.expectError(
        Error.InvalidEventRequest,
        stringifyRequest(std.testing.allocator, .mcp, 1, 0, large_event),
    );
}

fn checkAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = try stringifyRequest(allocator, .mcp, 1, 0, "{\"method\":\"event\"}");
    defer allocator.free(encoded);
    var parsed = try parseRequest(allocator, encoded);
    parsed.deinit();
}

test "durable event payload releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailure,
        .{},
    );
}
