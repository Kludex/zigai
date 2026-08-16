//! Durable standalone MCP client request and response wire documents.
//!
//! The request describes one complete high-level client operation. Registered
//! workers attach transport credentials and process-local input handlers; no
//! authentication header or callback is persisted in this document.

const std = @import("std");
const primitives = @import("../mcp/primitives.zig");
const transport = @import("../transport.zig");

/// Current standalone MCP durable wire version.
pub const format_version: u8 = 2;
/// Maximum encoded request or response document size.
pub const max_document_bytes: usize = 2 * 1024 * 1024;

/// Standalone MCP durable wire failures.
pub const Error = error{
    /// The request envelope or one embedded JSON document is invalid.
    InvalidMcpRequest,
    /// The response envelope or embedded MCP result is invalid.
    InvalidMcpResponse,
    /// A credential-like header was rejected before persistence.
    SensitiveMcpHeader,
    /// The request or response uses an unsupported schema version.
    UnsupportedMcpWireVersion,
};

const RequestDocument = struct {
    version: u8,
    payload_kind: enum { protocol_request },
    method: []const u8,
    params_json: []const u8,
    routing_name: ?[]const u8,
    headers: []const transport.Header,
    metadata: primitives.RequestMetadata,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
    max_round_trips: usize,
    deliver_events: bool,
};

/// Arena-owned request reconstructed by a registered MCP worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    method: []const u8,
    params_json: []const u8,
    routing_name: ?[]const u8,
    headers: []const transport.Header,
    metadata: primitives.RequestMetadata,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
    max_round_trips: usize,
    deliver_events: bool,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Serializes one complete standalone MCP operation for a worker. Sensitive
/// per-request headers are rejected; workers must attach credentials locally.
pub fn stringifyRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
    routing_name: ?[]const u8,
    headers: []const transport.Header,
    metadata: primitives.RequestMetadata,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
    max_round_trips: usize,
    deliver_events: bool,
) ![]u8 {
    for (headers) |header| if (header.isSensitive()) return Error.SensitiveMcpHeader;
    try validateJson(allocator, params_json, Error.InvalidMcpRequest);
    try validateJson(allocator, capabilities_json, Error.InvalidMcpRequest);
    const encoded = try std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .payload_kind = .protocol_request,
        .method = method,
        .params_json = params_json,
        .routing_name = routing_name,
        .headers = headers,
        .metadata = metadata,
        .client_name = client_name,
        .client_version = client_version,
        .capabilities_json = capabilities_json,
        .max_round_trips = max_round_trips,
        .deliver_events = deliver_events,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidMcpRequest;
    return encoded;
}

/// Parses one worker request. All slices borrow from the returned arena.
pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidMcpRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidMcpRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedMcpWireVersion;
    if (parsed.method.len == 0 or parsed.max_round_trips == 0)
        return Error.InvalidMcpRequest;
    for (parsed.headers) |header| if (header.isSensitive()) return Error.SensitiveMcpHeader;
    try validateJson(memory, parsed.params_json, Error.InvalidMcpRequest);
    try validateJson(memory, parsed.capabilities_json, Error.InvalidMcpRequest);
    return .{
        .arena = arena,
        .method = parsed.method,
        .params_json = parsed.params_json,
        .routing_name = parsed.routing_name,
        .headers = parsed.headers,
        .metadata = parsed.metadata,
        .client_name = parsed.client_name,
        .client_version = parsed.client_version,
        .capabilities_json = parsed.capabilities_json,
        .max_round_trips = parsed.max_round_trips,
        .deliver_events = parsed.deliver_events,
    };
}

const ResponseDocument = struct {
    version: u8,
    result_json: []const u8,
    events_json: []const []const u8,
};

/// Serializes the final MCP result returned after all MRTR round trips.
pub fn stringifyResponse(allocator: std.mem.Allocator, result_json: []const u8) ![]u8 {
    return stringifyResponseWithEvents(allocator, result_json, &.{});
}

/// Serializes the final MCP result and its bounded request-scoped event batch.
pub fn stringifyResponseWithEvents(
    allocator: std.mem.Allocator,
    result_json: []const u8,
    events_json: []const []const u8,
) ![]u8 {
    try validateJson(allocator, result_json, Error.InvalidMcpResponse);
    for (events_json) |event_json| try validateJson(allocator, event_json, Error.InvalidMcpResponse);
    const encoded = try std.json.Stringify.valueAlloc(allocator, ResponseDocument{
        .version = format_version,
        .result_json = result_json,
        .events_json = events_json,
    }, .{});
    errdefer allocator.free(encoded);
    if (encoded.len > max_document_bytes) return Error.InvalidMcpResponse;
    return encoded;
}

/// Arena-owned final MCP result returned by a durable runtime.
pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    result_json: []const u8,
    events_json: []const []const u8,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses one worker response and validates its embedded result document.
pub fn parseResponse(allocator: std.mem.Allocator, source: []const u8) !OwnedResponse {
    if (source.len > max_document_bytes) return Error.InvalidMcpResponse;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(ResponseDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidMcpResponse,
    };
    if (parsed.version != format_version) return Error.UnsupportedMcpWireVersion;
    try validateJson(memory, parsed.result_json, Error.InvalidMcpResponse);
    for (parsed.events_json) |event_json| try validateJson(memory, event_json, Error.InvalidMcpResponse);
    return .{
        .arena = arena,
        .result_json = parsed.result_json,
        .events_json = parsed.events_json,
    };
}

fn validateJson(allocator: std.mem.Allocator, source: []const u8, invalid: anyerror) !void {
    if (source.len > max_document_bytes) return invalid;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{
        .allocate = .alloc_if_needed,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid,
    };
    parsed.deinit();
}

test "durable MCP request and response round trip" {
    const request_json = try stringifyRequest(
        std.testing.allocator,
        "tools/list",
        "{\"cursor\":\"next\"}",
        "weather",
        &.{.{ .name = "x-schema-version", .value = "1" }},
        .{ .traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" },
        "zigai-test",
        "1.2.3",
        "{\"extensions\":{}}",
        8,
        true,
    );
    defer std.testing.allocator.free(request_json);
    var request = try parseRequest(std.testing.allocator, request_json);
    defer request.deinit();
    try std.testing.expectEqualStrings("tools/list", request.method);
    var params = try std.json.parseFromSlice(
        struct { cursor: []const u8 },
        std.testing.allocator,
        request.params_json,
        .{},
    );
    defer params.deinit();
    try std.testing.expectEqualStrings("next", params.value.cursor);
    try std.testing.expectEqual(@as(usize, 8), request.max_round_trips);
    try std.testing.expect(request.deliver_events);

    const response_json = try stringifyResponseWithEvents(
        std.testing.allocator,
        "{\"tools\":[]}",
        &.{"{\"method\":\"notifications/tools/list_changed\"}"},
    );
    defer std.testing.allocator.free(response_json);
    var response = try parseResponse(std.testing.allocator, response_json);
    defer response.deinit();
    try std.testing.expectEqualStrings("{\"tools\":[]}", response.result_json);
    try std.testing.expectEqual(@as(usize, 1), response.events_json.len);
}

test "durable MCP wire rejects secrets malformed documents and versions" {
    try std.testing.expectError(Error.SensitiveMcpHeader, stringifyRequest(
        std.testing.allocator,
        "tools/list",
        "{}",
        null,
        &.{.{ .name = "authorization", .value = "Bearer secret" }},
        .{},
        "zigai",
        "0.1.0",
        "{}",
        1,
        false,
    ));
    try std.testing.expectError(Error.InvalidMcpRequest, stringifyRequest(
        std.testing.allocator,
        "tools/list",
        "nope",
        null,
        &.{},
        .{},
        "zigai",
        "0.1.0",
        "{}",
        1,
        false,
    ));
    try std.testing.expectError(
        Error.UnsupportedMcpWireVersion,
        parseRequest(std.testing.allocator, "{\"version\":3,\"payload_kind\":\"protocol_request\",\"method\":\"x\",\"params_json\":\"{}\",\"routing_name\":null,\"headers\":[],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"{}\",\"max_round_trips\":1,\"deliver_events\":false}"),
    );
    try std.testing.expectError(
        Error.InvalidMcpResponse,
        parseResponse(std.testing.allocator, "{\"version\":2,\"result_json\":\"bad\",\"events_json\":[]}"),
    );
    try std.testing.expectError(Error.InvalidMcpRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.InvalidMcpResponse, parseResponse(std.testing.allocator, "{}"));
    try std.testing.expectError(
        Error.UnsupportedMcpWireVersion,
        parseResponse(std.testing.allocator, "{\"version\":3,\"result_json\":\"{}\",\"events_json\":[]}"),
    );
    try std.testing.expectError(Error.InvalidMcpResponse, stringifyResponse(std.testing.allocator, "bad"));
    try std.testing.expectError(
        Error.InvalidMcpResponse,
        stringifyResponseWithEvents(std.testing.allocator, "{}", &.{"bad"}),
    );
    try std.testing.expectError(
        Error.InvalidMcpResponse,
        parseResponse(std.testing.allocator, "{\"version\":2,\"result_json\":\"{}\",\"events_json\":[\"bad\"]}"),
    );

    const invalid_requests = [_][]const u8{
        "{\"version\":2,\"payload_kind\":\"protocol_request\",\"method\":\"\",\"params_json\":\"{}\",\"routing_name\":null,\"headers\":[],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"{}\",\"max_round_trips\":1,\"deliver_events\":false}",
        "{\"version\":2,\"payload_kind\":\"protocol_request\",\"method\":\"x\",\"params_json\":\"{}\",\"routing_name\":null,\"headers\":[],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"{}\",\"max_round_trips\":0,\"deliver_events\":false}",
        "{\"version\":2,\"payload_kind\":\"protocol_request\",\"method\":\"x\",\"params_json\":\"bad\",\"routing_name\":null,\"headers\":[],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"{}\",\"max_round_trips\":1,\"deliver_events\":false}",
        "{\"version\":2,\"payload_kind\":\"protocol_request\",\"method\":\"x\",\"params_json\":\"{}\",\"routing_name\":null,\"headers\":[],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"bad\",\"max_round_trips\":1,\"deliver_events\":false}",
        "{\"version\":2,\"payload_kind\":\"protocol_request\",\"method\":\"x\",\"params_json\":\"{}\",\"routing_name\":null,\"headers\":[{\"name\":\"authorization\",\"value\":\"secret\",\"sensitive\":false}],\"metadata\":{},\"client_name\":\"x\",\"client_version\":\"1\",\"capabilities_json\":\"{}\",\"max_round_trips\":1,\"deliver_events\":false}",
    };
    for (invalid_requests) |source| {
        const expected: anyerror = if (std.mem.indexOf(u8, source, "authorization") != null)
            Error.SensitiveMcpHeader
        else
            Error.InvalidMcpRequest;
        try std.testing.expectError(expected, parseRequest(std.testing.allocator, source));
    }

    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(Error.InvalidMcpRequest, parseRequest(std.testing.allocator, oversized));
    try std.testing.expectError(Error.InvalidMcpResponse, parseResponse(std.testing.allocator, oversized));

    const large_header = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(large_header);
    @memset(large_header, 'a');
    try std.testing.expectError(Error.InvalidMcpRequest, stringifyRequest(
        std.testing.allocator,
        "extension/test",
        "{}",
        null,
        &.{.{ .name = "x-large", .value = large_header }},
        .{},
        "zigai",
        "0.1.0",
        "{}",
        1,
        false,
    ));

    const large_result = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(large_result);
    large_result[0] = '"';
    @memset(large_result[1 .. large_result.len - 1], 'a');
    large_result[large_result.len - 1] = '"';
    try std.testing.expectError(
        Error.InvalidMcpResponse,
        stringifyResponse(std.testing.allocator, large_result),
    );
}

fn checkRequestAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = stringifyRequest(
        allocator,
        "tools/list",
        "{}",
        null,
        &.{.{ .name = "x-version", .value = "1" }},
        .{},
        "zigai",
        "0.1.0",
        "{}",
        4,
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
    const encoded = stringifyResponse(allocator, "{\"tools\":[]}") catch |failure| return switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        else => failure,
    };
    defer allocator.free(encoded);
    var parsed = try parseResponse(allocator, encoded);
    parsed.deinit();
}

test "durable MCP payloads release every partial allocation" {
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
