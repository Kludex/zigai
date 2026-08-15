const std = @import("std");
const model_types = @import("model.zig");
const security = @import("security.zig");

/// Transport failures defined by ZigAI. Concrete transports may add their own
/// I/O, TLS, URI, callback, and allocation errors.
pub const Error = error{
    /// The decompressed buffered response exceeded the configured byte limit.
    ResponseTooLarge,
    /// Cancellation won the race with an in-flight transport request.
    RequestCancelled,
    /// The complete transport operation exceeded its request timeout.
    RequestTimedOut,
    /// One decompressed streaming line exceeded the configured byte limit.
    StreamLineTooLarge,
    /// A transport does not implement line-oriented streaming.
    StreamingNotSupported,
    /// The response selected a content encoding ZigAI cannot decompress.
    UnsupportedCompressionMethod,
    /// A redirect response was rejected before its target could receive credentials.
    RedirectRejected,
};

/// Allocation limits applied after HTTP content decompression.
pub const Limits = struct {
    /// Maximum bytes accepted by one buffered response.
    max_response_body_bytes: usize = 16 * 1024 * 1024,
    /// Maximum bytes accepted before the newline in one streaming line.
    max_stream_line_bytes: usize = 1024 * 1024,
};

/// Handling for HTTP 3xx responses. ZigAI never follows redirects implicitly.
pub const RedirectPolicy = enum {
    /// Return `error.RedirectRejected` without exposing or following `Location`.
    reject,
    /// Return the 3xx response to the caller without following it.
    return_response,
};

/// Configuration for the standard-library HTTP transport.
pub const Options = struct {
    /// Decompressed response allocation limits.
    limits: Limits = .{},
    /// Validation applied before DNS or socket work.
    url_policy: security.UrlPolicy = .{},
    /// Treatment of 3xx responses; redirects are never followed here.
    redirect_policy: RedirectPolicy = .reject,
};

pub const Method = enum {
    GET,
    POST,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,

    /// Returns whether this header must be hidden from diagnostic consumers.
    pub fn isSensitive(self: Header) bool {
        return self.sensitive or security.isSensitiveHeaderName(self.name);
    }

    /// Returns the original value for ordinary headers and a static marker for secrets.
    pub fn redactedValue(self: Header) []const u8 {
        return security.redactedHeaderValue(self.name, self.value, self.sensitive);
    }
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: ?u64 = null,
    cancellation: ?*const model_types.CancellationToken = null,
};

/// The response body is allocated by the allocator passed to `Transport.send`.
/// The caller must free it with that allocator.
pub const Response = struct {
    status: u16,
    body: []const u8,
    metadata: ResponseMetadata = .{},
};

pub const ResponseMetadata = struct {
    retry_after_seconds: ?u64 = null,
    rate_limit_remaining_requests: ?u64 = null,
    rate_limit_remaining_tokens: ?u64 = null,
    /// Bounded copy of the provider's response correlation ID.
    provider_request_id: ?MetadataText = null,

    pub fn requestId(self: *const ResponseMetadata) ?[]const u8 {
        if (self.provider_request_id) |*value| return value.slice();
        return null;
    }
};

/// Inline response metadata that remains valid after the HTTP request closes.
pub const MetadataText = struct {
    pub const max_bytes = 256;

    bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    length: u16 = 0,

    pub fn init(value: []const u8) ?MetadataText {
        if (value.len == 0 or value.len > max_bytes) return null;
        var result: MetadataText = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.length = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const MetadataText) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const Transport = struct {
    context: *anyopaque,
    sendFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, request: Request) anyerror!Response,
    streamLinesFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, request: Request, sink: LineSink) anyerror!StreamResponse = null,

    pub fn send(self: Transport, allocator: std.mem.Allocator, request_value: Request) !Response {
        return self.sendFn(self.context, allocator, request_value);
    }

    pub fn streamLines(self: Transport, allocator: std.mem.Allocator, request_value: Request, sink: LineSink) !StreamResponse {
        const stream = self.streamLinesFn orelse return error.StreamingNotSupported;
        return stream(self.context, allocator, request_value, sink);
    }
};

pub const StreamResponse = struct {
    status: u16,
    metadata: ResponseMetadata = .{},
};

pub const LineSink = struct {
    context: *anyopaque,
    startFn: *const fn (context: *anyopaque, response: StreamResponse) anyerror!void,
    lineFn: *const fn (context: *anyopaque, line: []const u8) anyerror!void,

    pub fn start(self: LineSink, response: StreamResponse) !void {
        return self.startFn(self.context, response);
    }

    pub fn line(self: LineSink, value: []const u8) !void {
        return self.lineFn(self.context, value);
    }
};

/// Dependency-free HTTP transport built on Zig's standard library.
pub const HttpTransport = struct {
    client: std.http.Client,
    limits: Limits = .{},
    url_policy: security.UrlPolicy = .{},
    redirect_policy: RedirectPolicy = .reject,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpTransport {
        return initWithOptions(allocator, io, .{});
    }

    /// Initializes an HTTP transport with explicit decompressed response limits.
    pub fn initWithLimits(allocator: std.mem.Allocator, io: std.Io, limits: Limits) HttpTransport {
        return initWithOptions(allocator, io, .{ .limits = limits });
    }

    /// Initializes an HTTP transport with explicit limits and outbound policy.
    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, options: Options) HttpTransport {
        return .{
            .client = .{ .allocator = allocator, .io = io },
            .limits = options.limits,
            .url_policy = options.url_policy,
            .redirect_policy = options.redirect_policy,
        };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .context = self, .sendFn = send, .streamLinesFn = streamLines };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request) !Response {
        if (request_value.cancellation) |token| if (token.isCancelled()) return error.RequestCancelled;
        if (request_value.timeout_ms == 0) return error.RequestTimedOut;
        if (request_value.timeout_ms == null and request_value.cancellation == null) {
            return sendDirect(context, allocator, request_value);
        }
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        return controlledSend(self.client.io, context, allocator, request_value, sendDirect);
    }

    fn sendDirect(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request) !Response {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        try self.url_policy.validate(request_value.url);
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(allocator);
        for (request_value.headers) |header| {
            try headers.append(allocator, .{ .name = header.name, .value = header.value });
        }

        const method: std.http.Method = switch (request_value.method) {
            .GET => .GET,
            .POST => .POST,
        };
        const uri = try std.Uri.parse(request_value.url);
        var request = try self.client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
        });
        defer request.deinit();
        if (request_value.body.len == 0) {
            try request.sendBodiless();
        } else {
            request.transfer_encoding = .{ .content_length = request_value.body.len };
            var request_body = try request.sendBodyUnflushed(&.{});
            try request_body.writer.writeAll(request_value.body);
            try request_body.end();
            try request.connection.?.flush();
        }
        var response = try request.receiveHead(&.{});
        const status: u16 = @intFromEnum(response.head.status);
        if (isRedirect(status) and self.redirect_policy == .reject) return error.RedirectRejected;
        const metadata = responseMetadata(response.head);

        const decompress_buffer = try decompressionBuffer(allocator, response.head.content_encoding);
        defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        const allocation_limit = self.limits.max_response_body_bytes +| 1;
        const body = reader.allocRemaining(allocator, .limited(allocation_limit)) catch |failure| switch (failure) {
            error.StreamTooLong => return error.ResponseTooLarge,
            else => |other| return other,
        };
        return .{ .status = status, .body = body, .metadata = metadata };
    }

    fn streamLines(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request, sink: LineSink) !StreamResponse {
        if (request_value.cancellation) |token| if (token.isCancelled()) return error.RequestCancelled;
        if (request_value.timeout_ms == 0) return error.RequestTimedOut;
        if (request_value.timeout_ms == null and request_value.cancellation == null) {
            return streamLinesDirect(context, allocator, request_value, sink);
        }
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        return controlledStream(self.client.io, context, allocator, request_value, sink, streamLinesDirect);
    }

    fn streamLinesDirect(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request, sink: LineSink) !StreamResponse {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        try self.url_policy.validate(request_value.url);
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(allocator);
        for (request_value.headers) |header| try headers.append(allocator, .{ .name = header.name, .value = header.value });
        const method: std.http.Method = switch (request_value.method) {
            .GET => .GET,
            .POST => .POST,
        };
        var request = try self.client.request(method, try std.Uri.parse(request_value.url), .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
        });
        defer request.deinit();
        if (request_value.body.len == 0) {
            try request.sendBodiless();
        } else {
            request.transfer_encoding = .{ .content_length = request_value.body.len };
            var request_body = try request.sendBodyUnflushed(&.{});
            try request_body.writer.writeAll(request_value.body);
            try request_body.end();
            try request.connection.?.flush();
        }
        var response = try request.receiveHead(&.{});
        const result = StreamResponse{ .status = @intFromEnum(response.head.status), .metadata = responseMetadata(response.head) };
        if (isRedirect(result.status) and self.redirect_policy == .reject) return error.RedirectRejected;
        try sink.start(result);
        const decompress_buffer = try decompressionBuffer(allocator, response.head.content_encoding);
        defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
        var transfer_buffer: [64 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        while (try streamLine(allocator, reader, self.limits.max_stream_line_bytes)) |line| {
            defer allocator.free(line);
            try sink.line(std.mem.trimEnd(u8, line, "\r"));
        }
        return result;
    }
};

fn isRedirect(status: u16) bool {
    return status >= 300 and status < 400;
}

fn streamLine(allocator: std.mem.Allocator, reader: *std.Io.Reader, maximum_bytes: usize) !?[]u8 {
    var line_writer: std.Io.Writer.Allocating = .init(allocator);
    defer line_writer.deinit();
    const delimiter_limit = maximum_bytes +| 1;
    const line_length = reader.streamDelimiterLimit(&line_writer.writer, '\n', .limited(delimiter_limit)) catch |failure| switch (failure) {
        error.StreamTooLong => return error.StreamLineTooLarge,
        else => |other| return other,
    };
    const next_byte = reader.peekByte() catch |failure| switch (failure) {
        error.EndOfStream => null,
        else => |other| return other,
    };
    if (next_byte) |byte| {
        std.debug.assert(byte == '\n');
        reader.toss(1);
    } else if (line_length == 0) {
        return null;
    }
    return try line_writer.toOwnedSlice();
}

const SendOutcome = union(enum) {
    response: anyerror!Response,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

const StreamOutcome = union(enum) {
    response: anyerror!StreamResponse,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

fn controlledSend(io: std.Io, context: *anyopaque, allocator: std.mem.Allocator, request: Request, comptime operation: anytype) !Response {
    var buffer: [3]SendOutcome = undefined;
    var select: std.Io.Select(SendOutcome) = .init(io, &buffer);
    defer drainSend(&select, allocator);
    try select.concurrent(.response, operation, .{ context, allocator, request });
    if (request.timeout_ms) |milliseconds| try select.concurrent(.timeout, waitForTimeout, .{ io, milliseconds });
    if (request.cancellation) |token| try select.concurrent(.cancelled, waitForCancellation, .{ io, token });
    return switch (try select.await()) {
        .response => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.RequestTimedOut;
        },
        .cancelled => |result| blk: {
            try result;
            break :blk error.RequestCancelled;
        },
    };
}

fn controlledStream(io: std.Io, context: *anyopaque, allocator: std.mem.Allocator, request: Request, sink: LineSink, comptime operation: anytype) !StreamResponse {
    var buffer: [3]StreamOutcome = undefined;
    var select: std.Io.Select(StreamOutcome) = .init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.response, operation, .{ context, allocator, request, sink });
    if (request.timeout_ms) |milliseconds| try select.concurrent(.timeout, waitForTimeout, .{ io, milliseconds });
    if (request.cancellation) |token| try select.concurrent(.cancelled, waitForCancellation, .{ io, token });
    return switch (try select.await()) {
        .response => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.RequestTimedOut;
        },
        .cancelled => |result| blk: {
            try result;
            break :blk error.RequestCancelled;
        },
    };
}

fn waitForTimeout(io: std.Io, milliseconds: u64) !void {
    const maximum: u64 = @intCast(std.math.maxInt(i64));
    return timeoutMilliseconds(@min(milliseconds, maximum)).sleep(io);
}

fn waitForCancellation(io: std.Io, token: *const model_types.CancellationToken) !void {
    while (!token.isCancelled()) {
        try timeoutMilliseconds(5).sleep(io);
    }
}

fn timeoutMilliseconds(milliseconds: u64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    } };
}

fn drainSend(select: *std.Io.Select(SendOutcome), allocator: std.mem.Allocator) void {
    while (select.cancel()) |outcome| switch (outcome) {
        .response => |result| freeSendResult(allocator, result),
        .timeout, .cancelled => {},
    };
}

fn freeSendResult(allocator: std.mem.Allocator, result: anyerror!Response) void {
    if (result) |response| allocator.free(response.body) else |_| {}
}

fn responseMetadata(head: std.http.Client.Response.Head) ResponseMetadata {
    var metadata: ResponseMetadata = .{};
    var retry_after: ?[]const u8 = null;
    var response_date: ?[]const u8 = null;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "date")) {
            response_date = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-request-id") or
            std.ascii.eqlIgnoreCase(header.name, "request-id") or
            std.ascii.eqlIgnoreCase(header.name, "x-goog-request-id"))
        {
            metadata.provider_request_id = MetadataText.init(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining-requests") or
            std.ascii.eqlIgnoreCase(header.name, "anthropic-ratelimit-requests-remaining"))
        {
            const value = std.fmt.parseInt(u64, header.value, 10) catch continue;
            metadata.rate_limit_remaining_requests = value; // kcov-ignore
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining-tokens") or
            std.ascii.eqlIgnoreCase(header.name, "anthropic-ratelimit-tokens-remaining"))
        {
            const value = std.fmt.parseInt(u64, header.value, 10) catch continue;
            metadata.rate_limit_remaining_tokens = value;
        }
    }
    if (retry_after) |value| metadata.retry_after_seconds = parseRetryAfter(value, response_date);
    return metadata;
}

fn parseRetryAfter(value: []const u8, response_date: ?[]const u8) ?u64 {
    if (std.fmt.parseInt(u64, value, 10)) |seconds| return seconds else |_| {}
    const retry_timestamp = parseHttpDate(value) orelse return null;
    const response_timestamp = parseHttpDate(response_date orelse return null) orelse return null;
    return retry_timestamp -| response_timestamp; // kcov-ignore
}

fn parseHttpDate(value: []const u8) ?u64 {
    if (value.len != 29 or value[3] != ',' or value[4] != ' ' or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or value[22] != ':' or
        value[25] != ' ' or !std.mem.eql(u8, value[26..], "GMT")) return null;
    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return null;
    const month = parseHttpMonth(value[8..11]) orelse return null;
    if (year < std.time.epoch.epoch_year or day == 0 or
        day > std.time.epoch.getDaysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return null;

    var days: u64 = 0;
    var current_year: u16 = std.time.epoch.epoch_year; // kcov-ignore
    while (current_year < year) : (current_year += 1) days += std.time.epoch.getDaysInYear(current_year);
    var current_month: std.time.epoch.Month = .jan;
    while (current_month != month) {
        days += std.time.epoch.getDaysInMonth(year, current_month);
        current_month = @enumFromInt(@intFromEnum(current_month) + 1);
    }
    days += day - 1;
    return days * std.time.epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}

fn parseHttpMonth(value: []const u8) ?std.time.epoch.Month {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, number| if (std.mem.eql(u8, value, name)) return @enumFromInt(number);
    return null;
}

fn decompressionBuffer(allocator: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

test "transport delegates through its vtable" {
    var called = false;
    const Stub = struct {
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
            const was_called: *bool = @ptrCast(@alignCast(context));
            was_called.* = true;
            try std.testing.expectEqual(Method.POST, request.method);
            return .{ .status = 201, .body = try allocator.dupe(u8, "created") };
        }
    };
    const value = try (Transport{ .context = &called, .sendFn = Stub.send }).send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.invalid",
    });
    defer std.testing.allocator.free(value.body);
    try std.testing.expect(called);
    try std.testing.expectEqual(@as(u16, 201), value.status);
}

test "transport reports unsupported line streaming" {
    var called = false;
    const Stub = struct {
        fn send(context: *anyopaque, _: std.mem.Allocator, _: Request) !Response {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
            return error.Unused;
        }
        fn start(context: *anyopaque, _: StreamResponse) !void {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
        }
        fn line(context: *anyopaque, _: []const u8) !void {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
        }
    };
    try Stub.start(&called, .{ .status = 200 });
    try Stub.line(&called, "");
    try std.testing.expectError(error.Unused, Stub.send(&called, std.testing.allocator, .{ .method = .GET, .url = "x" }));
    try std.testing.expect(called);
    const transport = Transport{ .context = &called, .sendFn = Stub.send };
    try std.testing.expectError(error.Unused, transport.send(std.testing.allocator, .{ .method = .GET, .url = "x" }));
    try std.testing.expectError(error.StreamingNotSupported, transport.streamLines(std.testing.allocator, .{ .method = .GET, .url = "x" }, .{
        .context = &called,
        .startFn = Stub.start,
        .lineFn = Stub.line,
    }));
}

test "headers redact conventional and explicitly marked secrets" {
    const authorization = Header{ .name = "Authorization", .value = "Bearer private" };
    try std.testing.expect(authorization.isSensitive());
    try std.testing.expectEqualStrings(security.redacted_value, authorization.redactedValue());

    const marked = Header{ .name = "x-custom", .value = "private", .sensitive = true };
    try std.testing.expect(marked.isSensitive());
    try std.testing.expectEqualStrings(security.redacted_value, marked.redactedValue());

    const content_type = Header{ .name = "content-type", .value = "application/json" };
    try std.testing.expect(!content_type.isSensitive());
    try std.testing.expectEqualStrings("application/json", content_type.redactedValue());
}

test "HTTP transport enforces its outbound URL policy before socket work" {
    var http = HttpTransport.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    try std.testing.expectError(error.UrlSchemeNotAllowed, http.transport().send(std.testing.allocator, .{
        .method = .GET,
        .url = "http://example.com",
    }));
    try std.testing.expectError(error.LocalNetworkUrlForbidden, http.transport().send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://127.0.0.1",
    }));

    var limited = HttpTransport.initWithLimits(std.testing.allocator, std.testing.io, .{
        .max_response_body_bytes = 1,
        .max_stream_line_bytes = 1,
    });
    defer limited.deinit();
    try std.testing.expectEqual(@as(usize, 1), limited.limits.max_response_body_bytes);
    try std.testing.expectEqual(@as(usize, 1), limited.limits.max_stream_line_bytes);
}

test "response metadata parses retry and provider rate-limit headers" {
    const head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 429 Too Many Requests\r\n" ++
            "retry-after: 3\r\n" ++
            "x-request-id: req_123\r\n" ++
            "x-ratelimit-remaining-requests: 0\r\n" ++
            "anthropic-ratelimit-tokens-remaining: 12\r\n" ++
            "x-ignored: not-a-number\r\n\r\n",
    );
    const metadata = responseMetadata(head);
    try std.testing.expectEqual(@as(?u64, 3), metadata.retry_after_seconds);
    try std.testing.expectEqual(@as(?u64, 0), metadata.rate_limit_remaining_requests);
    try std.testing.expectEqual(@as(?u64, 12), metadata.rate_limit_remaining_tokens);
    try std.testing.expectEqualStrings("req_123", metadata.requestId().?);
}

test "response metadata parses HTTP-date retry delays and bounds request IDs" {
    const head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 503 Service Unavailable\r\n" ++
            "date: Wed, 21 Oct 2015 07:28:00 GMT\r\n" ++
            "retry-after: Wed, 21 Oct 2015 07:28:03 GMT\r\n\r\n",
    );
    try std.testing.expectEqual(@as(?u64, 3), responseMetadata(head).retry_after_seconds);
    try std.testing.expectEqual(@as(?u64, 0), parseRetryAfter(
        "Wed, 21 Oct 2015 07:27:59 GMT",
        "Wed, 21 Oct 2015 07:28:00 GMT",
    ));
    try std.testing.expect(parseRetryAfter("not-a-date", null) == null);
    try std.testing.expect(parseHttpDate("Wed, 31 Feb 2015 07:28:00 GMT") == null);
    try std.testing.expect(parseHttpDate("Wed, 21 Oct 1969 07:28:00 GMT") == null);
    try std.testing.expect(parseHttpDate("Wed, 21 Xxx 2015 07:28:00 GMT") == null);
    try std.testing.expect(MetadataText.init("") == null);
    try std.testing.expect(MetadataText.init(&([_]u8{'x'} ** (MetadataText.max_bytes + 1))) == null);
}

test "decompression buffers cover every supported encoding" {
    try std.testing.expectEqual(@as(usize, 0), (try decompressionBuffer(std.testing.allocator, .identity)).len);
    const zstd = try decompressionBuffer(std.testing.allocator, .zstd);
    defer std.testing.allocator.free(zstd);
    const gzip = try decompressionBuffer(std.testing.allocator, .gzip);
    defer std.testing.allocator.free(gzip);
    const deflate = try decompressionBuffer(std.testing.allocator, .deflate);
    defer std.testing.allocator.free(deflate);
    try std.testing.expectError(error.UnsupportedCompressionMethod, decompressionBuffer(std.testing.allocator, .compress));
}

const ControlledTestState = struct {
    fn send(_: *anyopaque, allocator: std.mem.Allocator, _: Request) !Response {
        return .{ .status = 202, .body = try allocator.dupe(u8, "controlled") };
    }

    fn stream(_: *anyopaque, _: std.mem.Allocator, _: Request, sink: LineSink) !StreamResponse {
        const response = StreamResponse{ .status = 202 };
        try sink.start(response);
        try sink.line("controlled");
        return response;
    }
};

test "controlled buffered requests complete and clean late results" {
    var immediate: u8 = 0;
    const response = try controlledSend(std.testing.io, &immediate, std.testing.allocator, .{
        .method = .GET,
        .url = "unused",
        .timeout_ms = 50,
    }, ControlledTestState.send);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 202), response.status);

    freeSendResult(std.testing.allocator, error.ExpectedTestError);
    freeSendResult(std.testing.allocator, .{ .status = 200, .body = try std.testing.allocator.dupe(u8, "free me") });
}

test "controlled streams complete" {
    const Capture = struct {
        starts: usize = 0,
        lines: usize = 0,
        fn start(context: *anyopaque, _: StreamResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.starts += 1;
        }
        fn line(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.lines += 1;
        }
    };
    var capture: Capture = .{};
    const sink = LineSink{ .context = &capture, .startFn = Capture.start, .lineFn = Capture.line };
    var immediate: u8 = 0;
    const response = try controlledStream(std.testing.io, &immediate, std.testing.allocator, .{
        .method = .GET,
        .url = "unused",
        .timeout_ms = 50,
    }, sink, ControlledTestState.stream);
    try std.testing.expectEqual(@as(u16, 202), response.status);
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.lines);

    var http = HttpTransport.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    try std.testing.expectError(error.RequestTimedOut, http.transport().streamLines(std.testing.allocator, .{
        .method = .GET,
        .url = "invalid",
        .timeout_ms = 0,
    }, sink));
}

test "HTTP runtime controls reject expired requests before socket work" {
    var http = HttpTransport.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var token: model_types.CancellationToken = .{};
    token.cancel();
    try std.testing.expectError(error.RequestCancelled, http.transport().send(std.testing.allocator, .{
        .method = .GET,
        .url = "invalid",
        .cancellation = &token,
    }));
    try waitForTimeout(std.testing.io, 1);
}

test "stream line propagates a read failure after partial input" {
    const FailingReader = struct {
        reader: std.Io.Reader,
        reads: usize = 0,

        fn stream(reader: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("reader", reader));
            self.reads += 1;
            if (self.reads == 1) return error.EndOfStream;
            return error.ReadFailed;
        }
    };
    var buffer = [_]u8{'x'};
    var failing = FailingReader{ .reader = .{
        .vtable = &.{ .stream = FailingReader.stream },
        .buffer = &buffer,
        .seek = 0,
        .end = buffer.len,
    } };
    try std.testing.expectError(error.ReadFailed, streamLine(std.testing.allocator, &failing.reader, 8));
    try std.testing.expectEqual(@as(usize, 2), failing.reads);
}

fn fuzzHttpMetadata(_: void, smith: *std.testing.Smith) !void {
    var buffer: [1024]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    _ = parseRetryAfter(value, "Wed, 21 Oct 2015 07:28:00 GMT");
    _ = parseHttpDate(value);
}

test "fuzz HTTP metadata parsers" {
    try std.testing.fuzz({}, fuzzHttpMetadata, .{ .corpus = &.{
        "\x02\x00\x00\x0010",
        "\x1d\x00\x00\x00Wed, 21 Oct 2015 07:28:00 GMT",
    } });
}
