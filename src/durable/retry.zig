//! Durable retry-delay wire documents.

const std = @import("std");

/// Current durable retry timer wire version.
pub const format_version: u8 = 1;
/// Maximum encoded retry timer request size.
pub const max_document_bytes: usize = 64 * 1024;

/// Durable retry timer payload failures.
pub const Error = error{
    /// The timer request is malformed or violates identifier limits.
    InvalidRetryRequest,
    /// The timer request uses an unsupported schema version.
    UnsupportedRetryWireVersion,
};

const RequestDocument = struct {
    version: u8,
    delay_ms: u64,
    retry_number: usize,
    model_requests: usize,
    total_delay_ms: u64,
    error_name: []const u8,
    retry_after_seconds: ?u64,
    rate_limit_remaining_requests: ?u64,
    rate_limit_remaining_tokens: ?u64,
    provider_request_id: ?[]const u8,
};

/// Arena-owned retry timer input reconstructed by a worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    delay_ms: u64,
    retry_number: usize,
    model_requests: usize,
    total_delay_ms: u64,
    error_name: []const u8,
    retry_after_seconds: ?u64,
    rate_limit_remaining_requests: ?u64,
    rate_limit_remaining_tokens: ?u64,
    provider_request_id: ?[]const u8,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Serializes the complete deterministic retry timer decision.
pub fn stringifyRequest(
    allocator: std.mem.Allocator,
    delay_ms: u64,
    retry_number: usize,
    model_requests: usize,
    total_delay_ms: u64,
    error_name: []const u8,
    retry_after_seconds: ?u64,
    rate_limit_remaining_requests: ?u64,
    rate_limit_remaining_tokens: ?u64,
    provider_request_id: ?[]const u8,
) ![]u8 {
    if (!validName(error_name)) return Error.InvalidRetryRequest;
    const encoded = try std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .delay_ms = delay_ms,
        .retry_number = retry_number,
        .model_requests = model_requests,
        .total_delay_ms = total_delay_ms,
        .error_name = error_name,
        .retry_after_seconds = retry_after_seconds,
        .rate_limit_remaining_requests = rate_limit_remaining_requests,
        .rate_limit_remaining_tokens = rate_limit_remaining_tokens,
        .provider_request_id = provider_request_id,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidRetryRequest;
    return encoded;
}

/// Parses one durable retry timer request.
pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidRetryRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, arena.allocator(), source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidRetryRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedRetryWireVersion;
    if (!validName(parsed.error_name)) return Error.InvalidRetryRequest;
    return .{
        .arena = arena,
        .delay_ms = parsed.delay_ms,
        .retry_number = parsed.retry_number,
        .model_requests = parsed.model_requests,
        .total_delay_ms = parsed.total_delay_ms,
        .error_name = parsed.error_name,
        .retry_after_seconds = parsed.retry_after_seconds,
        .rate_limit_remaining_requests = parsed.rate_limit_remaining_requests,
        .rate_limit_remaining_tokens = parsed.rate_limit_remaining_tokens,
        .provider_request_id = parsed.provider_request_id,
    };
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

test "durable retry request round trips and rejects invalid documents" {
    const encoded = try stringifyRequest(
        std.testing.allocator,
        250,
        2,
        4,
        500,
        "ServiceUnavailable",
        1,
        10,
        100,
        "request-1",
    );
    defer std.testing.allocator.free(encoded);
    var parsed = try parseRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 250), parsed.delay_ms);
    try std.testing.expectEqual(@as(usize, 2), parsed.retry_number);
    try std.testing.expectEqualStrings("request-1", parsed.provider_request_id.?);

    try std.testing.expectError(Error.InvalidRetryRequest, stringifyRequest(
        std.testing.allocator,
        0,
        1,
        1,
        0,
        "bad/name",
        null,
        null,
        null,
        null,
    ));
    try std.testing.expectError(Error.InvalidRetryRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(
        Error.UnsupportedRetryWireVersion,
        parseRequest(std.testing.allocator, "{\"version\":2,\"delay_ms\":0,\"retry_number\":1,\"model_requests\":1,\"total_delay_ms\":0,\"error_name\":\"Failed\",\"retry_after_seconds\":null,\"rate_limit_remaining_requests\":null,\"rate_limit_remaining_tokens\":null,\"provider_request_id\":null}"),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(Error.InvalidRetryRequest, parseRequest(std.testing.allocator, oversized));

    const large_id = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(large_id);
    @memset(large_id, 'a');
    try std.testing.expectError(Error.InvalidRetryRequest, stringifyRequest(
        std.testing.allocator,
        0,
        1,
        1,
        0,
        "Failed",
        null,
        null,
        null,
        large_id,
    ));

    const valid = try stringifyRequest(
        std.testing.allocator,
        0,
        1,
        1,
        0,
        "Failed",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(valid);
    const invalid_name = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "Failed",
        "bad/name",
    );
    defer std.testing.allocator.free(invalid_name);
    try std.testing.expectError(Error.InvalidRetryRequest, parseRequest(std.testing.allocator, invalid_name));
}

fn checkAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = try stringifyRequest(allocator, 1, 1, 1, 1, "Failed", null, null, null, null);
    defer allocator.free(encoded);
    var parsed = try parseRequest(allocator, encoded);
    parsed.deinit();
}

test "durable retry payload releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailure, .{});
}
