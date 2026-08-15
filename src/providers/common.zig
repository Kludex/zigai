const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const json_limits = @import("../json.zig");

pub fn statusError(status: u16) model_types.ProviderRequestError {
    if (status == 429) return error.ProviderRateLimited;
    if (status >= 500) return error.ProviderServerError;
    return error.ProviderRequestFailed;
}

/// Maps transport implementation details to stable retry categories while
/// preserving failures that callers must handle directly.
pub fn transportError(failure: anyerror) anyerror {
    return switch (failure) {
        error.OutOfMemory,
        error.RequestCancelled,
        error.RequestTimedOut,
        error.ResponseTooLarge,
        error.StreamLineTooLarge,
        error.StreamingNotSupported,
        error.UnsupportedCompressionMethod,
        => failure,
        error.InvalidProviderResponse => error.ProviderResponseDecodeError,
        error.BrokenPipe,
        error.ConnectionClosed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.HostUnreachable,
        error.NameServerFailure,
        error.NetworkDown,
        error.NetworkUnreachable,
        error.NoAddressReturned,
        error.Timeout,
        => error.ProviderConnectionError,
        else => failure,
    };
}

pub fn responseDecodeError(failure: anyerror) anyerror {
    return switch (failure) {
        error.OutOfMemory => failure,
        else => error.ProviderResponseDecodeError,
    };
}

pub fn notifyProviderError(
    allocator: std.mem.Allocator,
    observer: ?model_types.ProviderErrorObserver,
    provider: []const u8,
    status: u16,
    body: []const u8,
    metadata: http.ResponseMetadata,
) void {
    const target = observer orelse return;
    const Envelope = struct {
        @"error": struct {
            message: ?[]const u8 = null,
            code: ?std.json.Value = null,
            type: ?[]const u8 = null,
            status: ?[]const u8 = null,
        },
    };
    const parsed = json_limits.parse(
        Envelope,
        allocator,
        body,
        json_limits.defaults.provider_response,
        .{ .ignore_unknown_fields = true },
        error.InvalidProviderResponse,
    ) catch {
        observeRawProviderError(target, provider, status, body, metadata);
        return;
    };
    defer parsed.deinit();
    var allocated_code: ?[]u8 = null;
    defer if (allocated_code) |value| allocator.free(value);
    const code = if (parsed.value.@"error".code) |value| switch (value) {
        .string => |string| string,
        .integer => |integer| value: {
            allocated_code = std.fmt.allocPrint(allocator, "{d}", .{integer}) catch null;
            break :value allocated_code;
        },
        else => null,
    } else null;
    target.observe(.{
        .provider = provider,
        .status = status,
        .code = code orelse parsed.value.@"error".type orelse parsed.value.@"error".status,
        .message = parsed.value.@"error".message orelse body,
        .body = body,
        .request_id = metadata.requestId(),
        .retry_after_seconds = metadata.retry_after_seconds,
        .rate_limit_remaining_requests = metadata.rate_limit_remaining_requests,
        .rate_limit_remaining_tokens = metadata.rate_limit_remaining_tokens,
    });
}

fn observeRawProviderError(
    observer: model_types.ProviderErrorObserver,
    provider: []const u8,
    status: u16,
    body: []const u8,
    metadata: http.ResponseMetadata,
) void {
    observer.observe(.{
        .provider = provider,
        .status = status,
        .message = body,
        .body = body,
        .request_id = metadata.requestId(),
        .retry_after_seconds = metadata.retry_after_seconds,
        .rate_limit_remaining_requests = metadata.rate_limit_remaining_requests,
        .rate_limit_remaining_tokens = metadata.rate_limit_remaining_tokens,
    });
}

pub fn rawJson(
    allocator: std.mem.Allocator,
    writer: *std.json.Stringify,
    value: []const u8,
    limits: json_limits.Limits,
) !void {
    try json_limits.validateAs(allocator, value, limits, error.InvalidRequestEncoding);
    try writer.beginWriteRaw();
    try writer.writer.writeAll(value);
    writer.endWriteRaw();
}

pub fn requiredObject(value: std.json.Value, field: []const u8) !std.json.ObjectMap {
    const child = switch (value) {
        .object => |object| object.get(field) orelse return error.InvalidProviderResponse,
        else => return error.InvalidProviderResponse,
    };
    return switch (child) {
        .object => |object| object,
        else => error.InvalidProviderResponse,
    };
}

pub fn requiredArray(value: std.json.Value, field: []const u8) !std.json.Array {
    const child = switch (value) {
        .object => |object| object.get(field) orelse return error.InvalidProviderResponse,
        else => return error.InvalidProviderResponse,
    };
    return switch (child) {
        .array => |array| array,
        else => error.InvalidProviderResponse,
    };
}

pub fn objectInteger(object: std.json.ObjectMap, field: []const u8) !u64 {
    const value = object.get(field) orelse return error.InvalidProviderResponse;
    if (value != .integer or value.integer < 0) return error.InvalidProviderResponse;
    return @intCast(value.integer);
}

/// Reads a nullable or absent string field while rejecting other JSON types.
pub fn optionalObjectString(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => error.InvalidProviderResponse,
    };
}

pub fn appendTextParts(writer: *std.json.Stringify, parts: []const model_types.Part) !void {
    for (parts) |part| switch (part) {
        .text => |text| try writer.write(text),
        else => {},
    };
}

test "required array rejects a non-object root" {
    try std.testing.expectError(error.InvalidProviderResponse, requiredArray(.{ .bool = false }, "items"));
    try std.testing.expectError(error.InvalidProviderResponse, requiredObject(.{ .bool = false }, "item"));
}

test "object scalar helpers accept values and reject wrong types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"text\":\"ok\",\"value\":false,\"count\":7}", .{});
    try std.testing.expectEqualStrings("ok", try objectString(values.object, "text"));
    try std.testing.expectError(error.InvalidProviderResponse, objectString(values.object, "value"));
    try std.testing.expectError(error.InvalidProviderResponse, objectInteger(values.object, "value"));
    try std.testing.expectEqual(@as(u64, 7), try objectInteger(values.object, "count"));
    const negative = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"value\":-1}", .{});
    try std.testing.expectError(error.InvalidProviderResponse, objectInteger(negative.object, "value"));
}

test "HTTP statuses map to stable provider errors" {
    try std.testing.expectEqual(error.ProviderRateLimited, statusError(429));
    try std.testing.expectEqual(error.ProviderServerError, statusError(503));
    try std.testing.expectEqual(error.ProviderRequestFailed, statusError(400));
}

test "transport and decode failures map to stable retry categories" {
    try std.testing.expectEqual(error.ProviderConnectionError, transportError(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.ApplicationSinkFailed, transportError(error.ApplicationSinkFailed));
    try std.testing.expectEqual(error.ProviderResponseDecodeError, transportError(error.InvalidProviderResponse));
    try std.testing.expectEqual(error.RequestTimedOut, transportError(error.RequestTimedOut));
    try std.testing.expectEqual(error.RequestCancelled, transportError(error.RequestCancelled));
    try std.testing.expectEqual(error.ResponseTooLarge, transportError(error.ResponseTooLarge));
    try std.testing.expectEqual(error.StreamLineTooLarge, transportError(error.StreamLineTooLarge));
    try std.testing.expectEqual(error.StreamingNotSupported, transportError(error.StreamingNotSupported));
    try std.testing.expectEqual(error.UnsupportedCompressionMethod, transportError(error.UnsupportedCompressionMethod));
    try std.testing.expectEqual(error.OutOfMemory, transportError(error.OutOfMemory));
    try std.testing.expectEqual(error.ProviderResponseDecodeError, responseDecodeError(error.InvalidProviderResponse));
    try std.testing.expectEqual(error.OutOfMemory, responseDecodeError(error.OutOfMemory));
}

test "provider error observer receives parsed and fallback details" {
    const Capture = struct {
        calls: usize = 0,
        status: u16 = 0,
        saw_code: bool = false,
        saw_message: bool = false,
        saw_metadata: bool = false,
        saw_request_id: bool = false,

        fn observe(context: *anyopaque, value: model_types.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.status = value.status;
            self.saw_code = value.code != null and std.mem.eql(u8, value.code.?, "rate_limit");
            self.saw_message = std.mem.eql(u8, value.message, "slow down");
            self.saw_metadata = value.retry_after_seconds == 3 and value.rate_limit_remaining_requests == 0 and
                value.rate_limit_remaining_tokens == 12;
            self.saw_request_id = std.mem.eql(u8, value.request_id orelse "", "req_test");
        }
    };
    var capture: Capture = .{};
    const observer = model_types.ProviderErrorObserver{ .context = &capture, .observeFn = Capture.observe };
    notifyProviderError(
        std.testing.allocator,
        observer,
        "test",
        429,
        "{\"error\":{\"type\":\"rate_limit\",\"message\":\"slow down\"}}",
        .{
            .retry_after_seconds = 3,
            .rate_limit_remaining_requests = 0,
            .rate_limit_remaining_tokens = 12,
            .provider_request_id = http.MetadataText.init("req_test"),
        },
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u16, 429), capture.status);
    try std.testing.expect(capture.saw_code);
    try std.testing.expect(capture.saw_message);
    try std.testing.expect(capture.saw_metadata);
    try std.testing.expect(capture.saw_request_id);

    notifyProviderError(std.testing.allocator, observer, "test", 500, "not-json", .{});
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "provider error observer accepts numeric codes and status names" {
    const Capture = struct {
        numeric: bool = false,
        status_name: bool = false,

        fn observe(context: *anyopaque, value: model_types.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value.code) |code| {
                self.numeric = self.numeric or std.mem.eql(u8, code, "503");
                self.status_name = self.status_name or std.mem.eql(u8, code, "UNAVAILABLE");
            }
        }
    };
    var capture: Capture = .{};
    const observer = model_types.ProviderErrorObserver{ .context = &capture, .observeFn = Capture.observe };
    notifyProviderError(std.testing.allocator, observer, "google", 503, "{\"error\":{\"code\":503,\"message\":\"down\"}}", .{});
    notifyProviderError(std.testing.allocator, observer, "google", 503, "{\"error\":{\"status\":\"UNAVAILABLE\",\"message\":\"down\"}}", .{});
    try std.testing.expect(capture.numeric);
    try std.testing.expect(capture.status_name);
}

pub fn objectString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidProviderResponse;
    if (value != .string) return error.InvalidProviderResponse;
    return value.string;
}
pub fn base64Alloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    _ = std.base64.standard.Encoder.encode(encoded, source);
    return encoded;
}

pub fn base64DecodeAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(source);
    const decoded = try allocator.alloc(u8, size);
    try std.base64.standard.Decoder.decode(decoded, source);
    return decoded;
}
