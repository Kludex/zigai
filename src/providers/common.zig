const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const json_limits = @import("../json.zig");

/// Portable function name used to replay typed capability-load messages.
pub const capability_load_tool_name = "load_capability";

const CapabilityLoadArguments = struct {
    id: []const u8,
};

/// Converts a typed capability-load call to the portable function-call form.
/// The caller owns the returned call's `arguments_json` allocation.
pub fn capabilityLoadToolCall(
    allocator: std.mem.Allocator,
    call: model_types.CapabilityLoadCall,
) !model_types.ToolCall {
    return .{
        .id = call.call_id,
        .name = capability_load_tool_name,
        .arguments_json = try std.json.Stringify.valueAlloc(
            allocator,
            CapabilityLoadArguments{ .id = call.capability_id },
            .{},
        ),
        .tool_kind = .capability_load,
    };
}

/// Converts a typed capability-load result to the portable function result.
pub fn capabilityLoadToolResult(result: model_types.CapabilityLoadResult) model_types.ToolResult {
    return .{
        .call_id = result.call_id,
        .name = capability_load_tool_name,
        .content = result.instructions orelse "",
        .tool_kind = .capability_load,
        .metadata = result.metadata,
        .timestamp_unix_ms = result.timestamp_unix_ms,
        .outcome = result.outcome,
    };
}

/// Builds the portable model-visible tool description when return-schema
/// visibility is enabled. The caller owns a non-null result.
pub fn toolDescription(
    allocator: std.mem.Allocator,
    tool: model_types.ToolDefinition,
) !?[]u8 {
    if (tool.return_schema_visibility != .model_description) return null;
    const schema = tool.return_json_schema orelse return null;
    return try std.fmt.allocPrint(
        allocator,
        "{s}\n\nReturn JSON Schema:\n{s}",
        .{ tool.description, schema },
    );
}

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
    if (failure == error.OutOfMemory) return failure;
    return error.ProviderResponseDecodeError;
}

/// Appends validated request-scoped headers without allowing callers to
/// replace authentication, framing, or adapter-owned headers.
pub fn appendRequestHeaders(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(http.Header),
    extra: ?[]const model_types.RequestHeader,
) !void {
    for (extra orelse return) |header| {
        if (reservedHeaderName(header.name)) return error.InvalidRequestEncoding;
        for (target.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, header.name)) return error.InvalidRequestEncoding;
        }
        try target.append(allocator, .{
            .name = header.name,
            .value = header.value,
            .sensitive = header.sensitive,
        });
    }
}

/// Writes a tagged, bounded JSON extension object into an active request
/// object. Adapter-owned fields cannot be shadowed by extension JSON.
pub fn writeExtraBodyFields(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    extra: ?model_types.ProviderExtraBody,
    expected: model_types.ExtraBodyKind,
    reserved_fields: []const []const u8,
) !void {
    const body = extra orelse return;
    if (body.kind() != expected) return error.InvalidRequestEncoding;
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        body.json(),
        json_limits.defaults.tool_payload,
        .{},
        error.InvalidRequestEncoding,
    );
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRequestEncoding,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        for (reserved_fields) |reserved| {
            if (std.mem.eql(u8, entry.key_ptr.*, reserved)) return error.InvalidRequestEncoding;
        }
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
}

fn reservedHeaderName(name: []const u8) bool {
    const reserved = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "content-type",
        "content-length",
        "host",
        "connection",
        "transfer-encoding",
        "x-api-key",
        "x-goog-api-key",
        "anthropic-version",
        "anthropic-beta",
        "x-client-request-id",
        "idempotency-key",
    };
    for (reserved) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return false;
}

/// Validates that a tool-choice policy refers only to available local tools.
pub fn validateToolChoice(
    tools: []const model_types.ToolDefinition,
    builtin_tool_count: usize,
    choice: ?model_types.ToolChoice,
) !void {
    const value = choice orelse return;
    switch (value) {
        .auto, .none => {},
        .required => if (tools.len == 0 and builtin_tool_count == 0) return error.InvalidRequestEncoding,
        .tool => |name| if (!containsTool(tools, name)) return error.InvalidRequestEncoding,
        .allowed => |names| for (names, 0..) |name, index| {
            if (!containsTool(tools, name)) return error.InvalidRequestEncoding;
            for (names[0..index]) |earlier| {
                if (std.mem.eql(u8, name, earlier)) return error.InvalidRequestEncoding;
            }
        },
    }
}

/// Returns whether a local tool definition survives an allow-list choice.
pub fn toolIncluded(choice: ?model_types.ToolChoice, name: []const u8) bool {
    const value = choice orelse return true;
    return switch (value) {
        .allowed => |names| included: {
            for (names) |allowed| if (std.mem.eql(u8, name, allowed)) break :included true;
            break :included false;
        },
        else => true,
    };
}

fn containsTool(tools: []const model_types.ToolDefinition, name: []const u8) bool {
    for (tools) |tool| if (std.mem.eql(u8, tool.name, name)) return true;
    return false;
}

pub fn notifyProviderError(
    allocator: std.mem.Allocator,
    observer: ?model_types.ProviderErrorObserver,
    provider: []const u8,
    status: u16,
    body: []const u8,
    metadata: http.ResponseMetadata,
    policy: model_types.ProviderErrorPolicy,
    sensitive_values: []const []const u8,
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
        observeRawProviderError(target, provider, status, body, metadata, policy, sensitive_values);
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
    const captured_body = capturedBody(body, policy);
    const provider_message = parsed.value.@"error".message orelse "Provider request failed";
    const provider_code = code orelse parsed.value.@"error".type orelse parsed.value.@"error".status;
    const safe_body = redactSensitiveValue(captured_body, sensitive_values);
    const safe_message = redactSensitiveValue(bounded(provider_message, policy.max_message_bytes), sensitive_values);
    const safe_code = if (provider_code) |value|
        redactSensitiveValue(bounded(value, policy.max_code_bytes), sensitive_values)
    else
        null;
    target.observe(.{
        .provider = provider,
        .status = status,
        .code = if (safe_code) |value| value.value else null,
        .message = safe_message.value,
        .body = safe_body.value,
        .body_truncated = policy.capture_body and captured_body.len < body.len,
        .sensitive_data_redacted = safe_body.redacted or safe_message.redacted or
            (if (safe_code) |value| value.redacted else false),
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
    policy: model_types.ProviderErrorPolicy,
    sensitive_values: []const []const u8,
) void {
    const captured_body = capturedBody(body, policy);
    const safe_body = redactSensitiveValue(captured_body, sensitive_values);
    observer.observe(.{
        .provider = provider,
        .status = status,
        .message = if (policy.capture_body)
            safe_body.value
        else
            "Provider request failed",
        .body = safe_body.value,
        .body_truncated = policy.capture_body and captured_body.len < body.len,
        .sensitive_data_redacted = safe_body.redacted,
        .request_id = metadata.requestId(),
        .retry_after_seconds = metadata.retry_after_seconds,
        .rate_limit_remaining_requests = metadata.rate_limit_remaining_requests,
        .rate_limit_remaining_tokens = metadata.rate_limit_remaining_tokens,
    });
}

const RedactedValue = struct {
    value: []const u8,
    redacted: bool,
};

fn redactSensitiveValue(value: []const u8, sensitive_values: []const []const u8) RedactedValue {
    for (sensitive_values) |sensitive| {
        if (sensitive.len > 0 and std.mem.indexOf(u8, value, sensitive) != null) {
            return .{ .value = "[REDACTED]", .redacted = true };
        }
    }
    return .{ .value = value, .redacted = false };
}

fn capturedBody(body: []const u8, policy: model_types.ProviderErrorPolicy) []const u8 {
    if (!policy.capture_body) return "";
    return bounded(body, policy.max_body_bytes);
}

fn bounded(value: []const u8, maximum: usize) []const u8 {
    return value[0..@min(value.len, maximum)];
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

/// Reads a nullable or absent non-negative integer while rejecting other JSON types.
pub fn optionalObjectInteger(object: std.json.ObjectMap, field: []const u8) !?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidProviderResponse,
        .null => null,
        else => error.InvalidProviderResponse,
    };
}

/// Reads a nullable or absent JSON number as `f64`.
pub fn optionalObjectNumber(object: std.json.ObjectMap, field: []const u8) !?f64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |number| number,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch return error.InvalidProviderResponse,
        .null => null,
        else => error.InvalidProviderResponse,
    };
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
    try std.testing.expectEqual(@as(?u64, 7), try optionalObjectInteger(values.object, "count"));
    try std.testing.expect((try optionalObjectInteger(values.object, "missing")) == null);
    try std.testing.expectError(error.InvalidProviderResponse, optionalObjectInteger(values.object, "value"));

    const numbers = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"integer\":2,\"float\":1.5,\"none\":null}",
        .{},
    );
    try std.testing.expectEqual(@as(f64, 2), (try optionalObjectNumber(numbers.object, "integer")).?);
    try std.testing.expectEqual(@as(f64, 1.5), (try optionalObjectNumber(numbers.object, "float")).?);
    try std.testing.expect((try optionalObjectNumber(numbers.object, "none")) == null);
    const lexical = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"number\":1.25}",
        .{ .parse_numbers = false },
    );
    try std.testing.expectEqual(@as(f64, 1.25), (try optionalObjectNumber(lexical.object, "number")).?);
    var invalid_number: std.json.ObjectMap = .empty;
    defer invalid_number.deinit(arena.allocator());
    try invalid_number.put(arena.allocator(), "number", .{ .number_string = "invalid" });
    try std.testing.expectError(error.InvalidProviderResponse, optionalObjectNumber(invalid_number, "number"));
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
        body_hidden: bool = false,

        fn observe(context: *anyopaque, value: model_types.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.status = value.status;
            self.saw_code = value.code != null and std.mem.eql(u8, value.code.?, "rate_limit");
            self.saw_message = std.mem.eql(u8, value.message, "slow down");
            self.saw_metadata = value.retry_after_seconds == 3 and value.rate_limit_remaining_requests == 0 and
                value.rate_limit_remaining_tokens == 12;
            self.saw_request_id = std.mem.eql(u8, value.request_id orelse "", "req_test");
            self.body_hidden = value.body.len == 0 and !value.body_truncated;
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
        .{},
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u16, 429), capture.status);
    try std.testing.expect(capture.saw_code);
    try std.testing.expect(capture.saw_message);
    try std.testing.expect(capture.saw_metadata);
    try std.testing.expect(capture.saw_request_id);
    try std.testing.expect(capture.body_hidden);

    notifyProviderError(std.testing.allocator, observer, "test", 500, "not-json", .{}, .{}, &.{});
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "provider error bodies require opt in and obey exact limits" {
    const Capture = struct {
        calls: usize = 0,
        bounded: bool = false,
        exact: bool = false,

        fn observe(context: *anyopaque, value: model_types.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) {
                self.bounded = std.mem.eql(u8, value.body, "{\"e") and value.body_truncated and
                    std.mem.eql(u8, value.message, "mes") and std.mem.eql(u8, value.code.?, "ab");
            } else {
                self.exact = std.mem.eql(u8, value.body, "raw") and !value.body_truncated and
                    std.mem.eql(u8, value.message, "raw");
            }
        }
    };
    var capture: Capture = .{};
    const observer = model_types.ProviderErrorObserver{ .context = &capture, .observeFn = Capture.observe };
    notifyProviderError(
        std.testing.allocator,
        observer,
        "test",
        400,
        "{\"error\":{\"code\":\"abcdef\",\"message\":\"message\"}}",
        .{},
        .{ .capture_body = true, .max_body_bytes = 3, .max_message_bytes = 3, .max_code_bytes = 2 },
        &.{},
    );
    notifyProviderError(
        std.testing.allocator,
        observer,
        "test",
        500,
        "raw",
        .{},
        .{ .capture_body = true, .max_body_bytes = 3 },
        &.{},
    );
    try std.testing.expect(capture.bounded);
    try std.testing.expect(capture.exact);
}

test "provider error observers suppress configured credentials" {
    const Capture = struct {
        parsed: bool = false,
        raw: bool = false,

        fn observe(context: *anyopaque, value: model_types.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const safe = std.mem.eql(u8, value.message, "[REDACTED]") and
                std.mem.eql(u8, value.body, "[REDACTED]") and
                (value.status != 401 or std.mem.eql(u8, value.code orelse "", "[REDACTED]")) and
                value.sensitive_data_redacted;
            if (value.status == 401) self.parsed = safe else self.raw = safe;
        }
    };
    var capture: Capture = .{};
    const observer = model_types.ProviderErrorObserver{ .context = &capture, .observeFn = Capture.observe };
    const secret = "api-key-private";
    notifyProviderError(
        std.testing.allocator,
        observer,
        "test",
        401,
        "{\"error\":{\"code\":\"api-key-private\",\"message\":\"api-key-private\"}}",
        .{},
        .{ .capture_body = true },
        &.{secret},
    );
    notifyProviderError(
        std.testing.allocator,
        observer,
        "test",
        500,
        "raw api-key-private response",
        .{},
        .{ .capture_body = true },
        &.{ secret, "" },
    );
    try std.testing.expect(capture.parsed);
    try std.testing.expect(capture.raw);

    const visible = redactSensitiveValue("visible", &.{ "", secret });
    try std.testing.expectEqualStrings("visible", visible.value);
    try std.testing.expect(!visible.redacted);
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
    notifyProviderError(std.testing.allocator, observer, "google", 503, "{\"error\":{\"code\":503,\"message\":\"down\"}}", .{}, .{}, &.{});
    notifyProviderError(std.testing.allocator, observer, "google", 503, "{\"error\":{\"status\":\"UNAVAILABLE\",\"message\":\"down\"}}", .{}, .{}, &.{});
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

test "request settings headers preserve safe values and reject owned names" {
    var headers: std.ArrayList(http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    try headers.append(std.testing.allocator, .{ .name = "x-existing", .value = "one" });
    try appendRequestHeaders(std.testing.allocator, &headers, &.{.{
        .name = "x-feature",
        .value = "enabled",
        .sensitive = true,
    }});
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expect(headers.items[1].sensitive);
    try std.testing.expectError(error.InvalidRequestEncoding, appendRequestHeaders(
        std.testing.allocator,
        &headers,
        &.{.{ .name = "Authorization", .value = "replacement" }},
    ));
    try std.testing.expectError(error.InvalidRequestEncoding, appendRequestHeaders(
        std.testing.allocator,
        &headers,
        &.{.{ .name = "X-Existing", .value = "replacement" }},
    ));
    try appendRequestHeaders(std.testing.allocator, &headers, null);
}

test "provider extra bodies are tagged bounded objects without owned fields" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try writeExtraBodyFields(
        std.testing.allocator,
        &json,
        .{ .openai = "{\"store\":false,\"metadata\":{\"safe\":true}}" },
        .openai,
        &.{"model"},
    );
    try writeExtraBodyFields(std.testing.allocator, &json, null, .openai, &.{});
    try json.endObject();
    const body = try output.toOwnedSlice();
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"safe\":true}") != null);

    var rejected_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rejected_output.deinit();
    var rejected_json: std.json.Stringify = .{ .writer = &rejected_output.writer };
    try rejected_json.beginObject();
    try std.testing.expectError(error.InvalidRequestEncoding, writeExtraBodyFields(
        std.testing.allocator,
        &rejected_json,
        .{ .anthropic = "{}" },
        .openai,
        &.{},
    ));
    try std.testing.expectError(error.InvalidRequestEncoding, writeExtraBodyFields(
        std.testing.allocator,
        &rejected_json,
        .{ .openai = "[]" },
        .openai,
        &.{},
    ));
    try std.testing.expectError(error.InvalidRequestEncoding, writeExtraBodyFields(
        std.testing.allocator,
        &rejected_json,
        .{ .openai = "{" },
        .openai,
        &.{},
    ));
    try std.testing.expectError(error.InvalidRequestEncoding, writeExtraBodyFields(
        std.testing.allocator,
        &rejected_json,
        .{ .openai = "{\"model\":\"shadow\"}" },
        .openai,
        &.{"model"},
    ));
}

test "provider extra body writing releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            runInner(allocator) catch |failure| switch (failure) {
                error.WriteFailed => return error.OutOfMemory,
                else => return failure,
            };
        }

        fn runInner(allocator: std.mem.Allocator) !void {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            var json: std.json.Stringify = .{ .writer = &output.writer };
            try json.beginObject();
            try writeExtraBodyFields(
                allocator,
                &json,
                .{ .google = "{\"nested\":{\"items\":[1,2,3],\"label\":\"safe\"}}" },
                .google,
                &.{},
            );
            try json.endObject();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "tool choice validates names and filters allow lists" {
    const tools = [_]model_types.ToolDefinition{
        .{ .name = "search", .description = "", .parameters_json_schema = "{}" },
        .{ .name = "fetch", .description = "", .parameters_json_schema = "{}" },
    };
    try validateToolChoice(&tools, 0, null);
    try validateToolChoice(&tools, 0, .auto);
    try validateToolChoice(&tools, 0, .none);
    try validateToolChoice(&tools, 0, .required);
    try validateToolChoice(&tools, 0, .{ .tool = "search" });
    try validateToolChoice(&tools, 0, .{ .allowed = &.{"fetch"} });
    try std.testing.expect(toolIncluded(.{ .allowed = &.{"fetch"} }, "fetch"));
    try std.testing.expect(!toolIncluded(.{ .allowed = &.{"fetch"} }, "search"));
    try std.testing.expect(toolIncluded(.auto, "search"));
    try std.testing.expectError(error.InvalidRequestEncoding, validateToolChoice(&.{}, 0, .required));
    try std.testing.expectError(error.InvalidRequestEncoding, validateToolChoice(&tools, 0, .{ .tool = "missing" }));
    try std.testing.expectError(error.InvalidRequestEncoding, validateToolChoice(
        &tools,
        0,
        .{ .allowed = &.{ "search", "search" } },
    ));
    try validateToolChoice(&.{}, 1, .required);
}

test "provider tool descriptions expose return schemas only when requested" {
    const base = model_types.ToolDefinition{
        .name = "demo",
        .description = "Demo.",
        .parameters_json_schema = "{}",
    };
    try std.testing.expect(try toolDescription(std.testing.allocator, base) == null);
    var visible = base;
    visible.return_schema_visibility = .model_description;
    try std.testing.expect(try toolDescription(std.testing.allocator, visible) == null);
    visible.return_json_schema = "{\"type\":\"string\"}";
    const description = (try toolDescription(std.testing.allocator, visible)).?;
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "Demo.\n\nReturn JSON Schema:\n{\"type\":\"string\"}",
        description,
    );
}
