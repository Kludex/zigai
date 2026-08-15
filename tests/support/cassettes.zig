//! Deterministic HTTP cassette replay for high-level provider tests.
//!
//! The on-disk format follows Cassetter v1: YAML with typed bodies and
//! structured JSON content. Authentication headers are never recorded.

const std = @import("std");
const http = @import("zigai").transport;
const format = @import("cassettes/format.zig");

pub const Cassette = format.Cassette;
pub const Interaction = format.Interaction;
pub const RecordedRequest = format.RecordedRequest;
pub const RecordedResponse = format.RecordedResponse;

pub const BodyFilter = struct {
    context: *const anyopaque,
    filterFn: *const fn (context: *const anyopaque, allocator: std.mem.Allocator, body: []const u8) anyerror![]u8,

    pub fn apply(self: BodyFilter, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        return self.filterFn(self.context, allocator, body);
    }
};

pub const RequestFilters = struct {
    url: ?BodyFilter = null,
    body: ?BodyFilter = null,
};

pub const ResponseHeaderFilter = struct {
    context: *const anyopaque,
    filterFn: *const fn (context: *const anyopaque, header: http.Header) anyerror!?http.Header,

    pub fn apply(self: ResponseHeaderFilter, header: http.Header) !?http.Header {
        return self.filterFn(self.context, header);
    }
};

pub const HeaderRule = struct {
    name: []const u8,
    replacement: ?[]const u8 = null,
};

/// Opt-in response-header allowlist. A rule may retain a safe value or replace
/// it with a deterministic fixture value. Sensitive headers are always rejected.
pub const ResponseHeaderRules = struct {
    rules: []const HeaderRule,

    pub fn filter(self: *const ResponseHeaderRules) ResponseHeaderFilter {
        return .{ .context = self, .filterFn = apply };
    }

    fn apply(context: *const anyopaque, header: http.Header) !?http.Header {
        const self: *const ResponseHeaderRules = @ptrCast(@alignCast(context));
        for (self.rules) |rule| if (std.ascii.eqlIgnoreCase(rule.name, header.name)) {
            if (header.isSensitive()) return error.SensitiveCassetteHeader;
            return .{ .name = rule.name, .value = rule.replacement orelse header.value };
        };
        return null;
    }
};

pub const PrefixRedactionFilter = struct {
    prefix: []const u8,
    replacement: []const u8,

    pub fn bodyFilter(self: *const PrefixRedactionFilter) BodyFilter {
        return .{ .context = self, .filterFn = apply };
    }

    fn apply(context: *const anyopaque, allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        const self: *const PrefixRedactionFilter = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, if (std.mem.startsWith(u8, value, self.prefix)) self.replacement else value);
    }
};

/// Normalizes multipart boundaries and replaces the uploaded file payload.
/// It targets the standard final `name="file"` part emitted by ZigAI providers.
pub const MultipartFileFilter = struct {
    replacement: []const u8 = "[REDACTED FILE CONTENT]",

    pub fn bodyFilter(self: *const MultipartFileFilter) BodyFilter {
        return .{ .context = self, .filterFn = apply };
    }

    fn apply(context: *const anyopaque, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        const self: *const MultipartFileFilter = @ptrCast(@alignCast(context));
        if (!std.mem.startsWith(u8, body, "--")) return allocator.dupe(u8, body);
        const boundary_end = std.mem.indexOf(u8, body, "\r\n") orelse return error.InvalidMultipartCassetteBody;
        const boundary = body[2..boundary_end];
        if (boundary.len == 0) return error.InvalidMultipartCassetteBody;
        const file_marker = "Content-Disposition: form-data; name=\"file\"; filename=\"";
        const file_header = std.mem.indexOf(u8, body, file_marker) orelse return error.InvalidMultipartCassetteBody;
        const content_offset = std.mem.indexOfPos(u8, body, file_header, "\r\n\r\n") orelse return error.InvalidMultipartCassetteBody;
        const content_start = content_offset + 4;
        const closing = try std.fmt.allocPrint(allocator, "\r\n--{s}--", .{boundary});
        defer allocator.free(closing);
        const content_end = std.mem.indexOfPos(u8, body, content_start, closing) orelse return error.InvalidMultipartCassetteBody;

        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try replaceAll(&output.writer, body[0..content_start], boundary, "zigai-redacted-boundary");
        try output.writer.writeAll(self.replacement);
        try replaceAll(&output.writer, body[content_end..], boundary, "zigai-redacted-boundary");
        const redacted = try output.toOwnedSlice();
        defer allocator.free(redacted);
        var normalized: std.Io.Writer.Allocating = .init(allocator);
        defer normalized.deinit();
        try replaceAll(&normalized.writer, redacted, "\r\n", "\n");
        return normalized.toOwnedSlice();
    }
};

/// Preserves empty and JSON request bodies while replacing opaque payloads.
/// This matches two-phase APIs that send JSON metadata before raw file bytes.
pub const NonJsonBodyFilter = struct {
    replacement: []const u8 = "[REDACTED FILE CONTENT]",

    pub fn bodyFilter(self: *const NonJsonBodyFilter) BodyFilter {
        return .{ .context = self, .filterFn = apply };
    }

    fn apply(context: *const anyopaque, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        const self: *const NonJsonBodyFilter = @ptrCast(@alignCast(context));
        if (body.len == 0) return allocator.dupe(u8, body);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
            return allocator.dupe(u8, self.replacement);
        defer parsed.deinit();
        return allocator.dupe(u8, body);
    }
};

fn replaceAll(writer: *std.Io.Writer, value: []const u8, needle: []const u8, replacement: []const u8) !void {
    var remaining = value;
    while (std.mem.indexOf(u8, remaining, needle)) |index| {
        try writer.writeAll(remaining[0..index]);
        try writer.writeAll(replacement);
        remaining = remaining[index + needle.len ..];
    }
    try writer.writeAll(remaining);
}

/// Removes matching object fields recursively while preserving array order and
/// every non-matching value. The filter owns no memory and must outlive a
/// recorder that references it.
pub const JsonFieldFilter = struct {
    field_names: []const []const u8,

    pub fn bodyFilter(self: *const JsonFieldFilter) BodyFilter {
        return .{ .context = self, .filterFn = apply };
    }

    fn apply(context: *const anyopaque, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        const self: *const JsonFieldFilter = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        try writeFiltered(&json, parsed, self.field_names);
        return output.toOwnedSlice();
    }
};

fn writeFiltered(json: *std.json.Stringify, value: std.json.Value, field_names: []const []const u8) !void {
    switch (value) {
        .object => |object| {
            try json.beginObject();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (containsField(field_names, entry.key_ptr.*)) continue;
                try json.objectField(entry.key_ptr.*);
                try writeFiltered(json, entry.value_ptr.*, field_names);
            }
            try json.endObject();
        },
        .array => |array| {
            try json.beginArray();
            for (array.items) |item| try writeFiltered(json, item, field_names);
            try json.endArray();
        },
        else => try json.write(value),
    }
}

fn containsField(field_names: []const []const u8, candidate: []const u8) bool {
    for (field_names) |field| if (std.mem.eql(u8, field, candidate)) return true;
    return false;
}

pub const ReplayTransport = struct {
    parsed: format.ParsedCassette,
    next_interaction: usize = 0,
    request_filters: RequestFilters = .{},

    pub fn init(allocator: std.mem.Allocator, cassette_yaml: []const u8) !ReplayTransport {
        return .{ .parsed = try format.parse(allocator, cassette_yaml) };
    }

    pub fn initWithRequestFilters(allocator: std.mem.Allocator, cassette_yaml: []const u8, filters: RequestFilters) !ReplayTransport {
        return .{ .parsed = try format.parse(allocator, cassette_yaml), .request_filters = filters };
    }

    pub fn deinit(self: *ReplayTransport) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *ReplayTransport) http.Transport {
        return .{ .context = self, .sendFn = send, .streamLinesFn = streamLines };
    }

    pub fn remaining(self: ReplayTransport) usize {
        return self.parsed.value.interactions.len - self.next_interaction;
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *ReplayTransport = @ptrCast(@alignCast(context));
        if (self.next_interaction >= self.parsed.value.interactions.len) return error.CassetteExhausted;
        const interaction = self.parsed.value.interactions[self.next_interaction];
        const filtered_url = if (self.request_filters.url) |filter| try filter.apply(allocator, request.url) else null;
        defer if (filtered_url) |value| allocator.free(value);
        const filtered_body = if (self.request_filters.body) |filter| try filter.apply(allocator, request.body) else null;
        defer if (filtered_body) |value| allocator.free(value);
        if (interaction.request.method != request.method or
            !std.mem.eql(u8, interaction.request.url, filtered_url orelse request.url) or
            !std.mem.eql(u8, interaction.request.body, filtered_body orelse request.body))
        {
            return error.CassetteMismatch;
        }
        if (request.response_header_sink) |sink| for (interaction.response.headers) |header| try sink.header(header);
        self.next_interaction += 1;
        const status = interaction.response.status;
        return .{
            .status = status,
            .body = try allocator.dupe(u8, interaction.response.body),
            .metadata = interaction.response.metadata,
        };
    }

    fn streamLines(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request, sink: http.LineSink) !http.StreamResponse {
        const self: *ReplayTransport = @ptrCast(@alignCast(context));
        if (self.next_interaction >= self.parsed.value.interactions.len) return error.CassetteExhausted;
        const interaction = self.parsed.value.interactions[self.next_interaction];
        const filtered_url = if (self.request_filters.url) |filter| try filter.apply(allocator, request.url) else null;
        defer if (filtered_url) |value| allocator.free(value);
        const filtered_body = if (self.request_filters.body) |filter| try filter.apply(allocator, request.body) else null;
        defer if (filtered_body) |value| allocator.free(value);
        if (interaction.request.method != request.method or
            !std.mem.eql(u8, interaction.request.url, filtered_url orelse request.url) or
            !std.mem.eql(u8, interaction.request.body, filtered_body orelse request.body)) return error.CassetteMismatch;
        if (request.response_header_sink) |header_sink| for (interaction.response.headers) |header| try header_sink.header(header);
        self.next_interaction += 1;
        const result = http.StreamResponse{ .status = interaction.response.status, .metadata = interaction.response.metadata };
        try sink.start(result);
        var lines = std.mem.splitScalar(u8, interaction.response.body, '\n');
        while (lines.next()) |line| try sink.line(std.mem.trimEnd(u8, line, "\r"));
        return result;
    }
};

/// Wraps any transport and captures successful interactions in memory. Header
/// values are never copied, which keeps API keys out of cassettes by design.
pub const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    inner: http.Transport,
    interactions: std.ArrayList(Interaction) = .empty,
    request_filters: RequestFilters = .{},
    response_filter: ?BodyFilter = null,
    response_header_filter: ?ResponseHeaderFilter = null,

    pub const Options = struct {
        request_filters: RequestFilters = .{},
        response_body_filter: ?BodyFilter = null,
        response_header_filter: ?ResponseHeaderFilter = null,
    };

    pub fn init(allocator: std.mem.Allocator, inner: http.Transport) RecordingTransport {
        return .{ .allocator = allocator, .inner = inner };
    }

    pub fn initWithFilters(allocator: std.mem.Allocator, inner: http.Transport, request_filter: ?BodyFilter, response_filter: ?BodyFilter) RecordingTransport {
        return initWithOptions(allocator, inner, .{
            .request_filters = .{ .body = request_filter },
            .response_body_filter = response_filter,
        });
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, inner: http.Transport, options: Options) RecordingTransport {
        return .{
            .allocator = allocator,
            .inner = inner,
            .request_filters = options.request_filters,
            .response_filter = options.response_body_filter,
            .response_header_filter = options.response_header_filter,
        };
    }

    pub fn deinit(self: *RecordingTransport) void {
        for (self.interactions.items) |interaction| {
            self.allocator.free(interaction.request.url);
            self.allocator.free(interaction.request.body);
            self.allocator.free(interaction.response.body);
            freeHeaders(self.allocator, interaction.response.headers);
        }
        self.interactions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *RecordingTransport) http.Transport {
        return .{ .context = self, .sendFn = send, .streamLinesFn = streamLines };
    }

    pub fn cassetteYaml(self: RecordingTransport, allocator: std.mem.Allocator) ![]u8 {
        return format.stringify(allocator, Cassette{
            .version = 1,
            .interactions = self.interactions.items,
        });
    }

    /// Serializes the current recording and atomically replaces `path` only
    /// after the complete cassette has been flushed and synced.
    pub fn writeCassetteAtomic(self: RecordingTransport, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const yaml = try self.cassetteYaml(allocator);
        defer allocator.free(yaml);
        var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(yaml);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.replace(io);
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        var header_capture = ResponseHeaderCapture{
            .allocator = self.allocator,
            .downstream = request.response_header_sink,
            .filter = self.response_header_filter,
        };
        defer header_capture.deinit();
        var forwarded = request;
        forwarded.response_header_sink = header_capture.sink();
        const response = try self.inner.send(allocator, forwarded);
        errdefer allocator.free(response.body);

        const url = if (self.request_filters.url) |filter|
            try filter.apply(self.allocator, request.url)
        else
            try self.allocator.dupe(u8, request.url);
        errdefer self.allocator.free(url);
        const request_body = if (self.request_filters.body) |filter|
            try filter.apply(self.allocator, request.body)
        else
            try self.allocator.dupe(u8, request.body);
        errdefer self.allocator.free(request_body);
        const response_body = if (self.response_filter) |filter|
            try filter.apply(self.allocator, response.body)
        else
            try self.allocator.dupe(u8, response.body);
        errdefer self.allocator.free(response_body);
        const response_headers = try header_capture.take();
        errdefer freeHeaders(self.allocator, response_headers);

        try self.interactions.append(self.allocator, .{
            .request = .{
                .method = request.method,
                .url = url,
                .body = request_body,
            },
            .response = .{
                .status = response.status,
                .body = response_body,
                .metadata = response.metadata,
                .headers = response_headers,
            },
        });
        return response;
    }

    fn streamLines(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request, sink: http.LineSink) !http.StreamResponse {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        var capture = StreamCapture{ .allocator = allocator, .sink = sink };
        defer capture.body.deinit(allocator);
        var header_capture = ResponseHeaderCapture{
            .allocator = self.allocator,
            .downstream = request.response_header_sink,
            .filter = self.response_header_filter,
        };
        defer header_capture.deinit();
        var forwarded = request;
        forwarded.response_header_sink = header_capture.sink();
        const response = try self.inner.streamLines(allocator, forwarded, capture.lineSink());
        const url = if (self.request_filters.url) |filter|
            try filter.apply(self.allocator, request.url)
        else
            try self.allocator.dupe(u8, request.url);
        errdefer self.allocator.free(url);
        const request_body = if (self.request_filters.body) |filter|
            try filter.apply(self.allocator, request.body)
        else
            try self.allocator.dupe(u8, request.body);
        errdefer self.allocator.free(request_body);
        const response_body = if (self.response_filter) |filter|
            try filter.apply(self.allocator, capture.body.items)
        else
            try self.allocator.dupe(u8, capture.body.items);
        errdefer self.allocator.free(response_body);
        const response_headers = try header_capture.take();
        errdefer freeHeaders(self.allocator, response_headers);
        try self.interactions.append(self.allocator, .{
            .request = .{ .method = request.method, .url = url, .body = request_body },
            .response = .{ .status = response.status, .body = response_body, .metadata = response.metadata, .headers = response_headers },
        });
        return response;
    }
};

const ResponseHeaderCapture = struct {
    allocator: std.mem.Allocator,
    downstream: ?http.ResponseHeaderSink,
    filter: ?ResponseHeaderFilter,
    headers: std.ArrayList(http.Header) = .empty,

    fn sink(self: *ResponseHeaderCapture) http.ResponseHeaderSink {
        return .{ .context = self, .headerFn = header };
    }

    fn header(context: *anyopaque, value: http.Header) !void {
        const self: *ResponseHeaderCapture = @ptrCast(@alignCast(context));
        if (self.downstream) |downstream| try downstream.header(value);
        const filtered = if (self.filter) |filter| try filter.apply(value) else null;
        if (filtered) |recorded| {
            if (recorded.isSensitive()) return error.SensitiveCassetteHeader;
            const name = try self.allocator.dupe(u8, recorded.name);
            errdefer self.allocator.free(name);
            const header_value = try self.allocator.dupe(u8, recorded.value);
            errdefer self.allocator.free(header_value);
            try self.headers.append(self.allocator, .{ .name = name, .value = header_value });
        }
    }

    fn take(self: *ResponseHeaderCapture) ![]const http.Header {
        return self.headers.toOwnedSlice(self.allocator);
    }

    fn deinit(self: *ResponseHeaderCapture) void {
        freeHeaders(self.allocator, self.headers.items);
        self.headers.deinit(self.allocator);
    }
};

fn freeHeaders(allocator: std.mem.Allocator, headers: []const http.Header) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

const StreamCapture = struct {
    allocator: std.mem.Allocator,
    sink: http.LineSink,
    body: std.ArrayList(u8) = .empty,

    fn lineSink(self: *StreamCapture) http.LineSink {
        return .{ .context = self, .startFn = start, .lineFn = line };
    }

    fn start(context: *anyopaque, response: http.StreamResponse) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(context));
        try self.sink.start(response);
    }

    fn line(context: *anyopaque, value: []const u8) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(context));
        if (self.body.items.len > 0) try self.body.append(self.allocator, '\n');
        try self.body.appendSlice(self.allocator, value);
        try self.sink.line(value);
    }
};

test "cassette replays and verifies an interaction" {
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://example.test/v1
        \\    headers: {}
        \\    body:
        \\      type: json
        \\      content: {}
        \\  response:
        \\    status: 200
        \\    headers: {}
        \\    body:
        \\      type: json
        \\      content:
        \\        ok: true
    ;
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    const response = try replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test/v1",
        .body = "{}",
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    try std.testing.expectEqual(@as(usize, 0), replay.remaining());
    try std.testing.expectError(error.CassetteExhausted, replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test/v1",
        .body = "{}",
    }));
}

test "cassette rejects a request whose body changed" {
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://example.test
        \\    body:
        \\      type: text
        \\      content: old
        \\  response:
        \\    status: 200
        \\    body:
        \\      type: text
        \\      content: ok
    ;
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    try std.testing.expectError(error.CassetteMismatch, replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .body = "new",
    }));
}

test "cassette YAML round trips long opaque JSON strings" {
    var blob: [2048]u8 = undefined;
    @memset(&blob, 'a');
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"opaque\":\"{s}\"}}", .{&blob});
    defer std.testing.allocator.free(body);
    const yaml = try format.stringify(std.testing.allocator, .{
        .version = 1,
        .interactions = &.{.{
            .request = .{ .method = .POST, .url = "https://example.test", .body = body },
            .response = .{ .status = 200, .body = "{}" },
        }},
    });
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "|-\n") != null);
    var parsed = try format.parse(std.testing.allocator, yaml);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(body, parsed.value.interactions[0].request.body);
}

test "cassette YAML preserves retry metadata and provider request IDs" {
    const yaml = try format.stringify(std.testing.allocator, .{
        .version = 1,
        .interactions = &.{.{
            .request = .{ .method = .POST, .url = "https://example.test", .body = "{}" },
            .response = .{ .status = 429, .body = "{}", .metadata = .{
                .retry_after_seconds = 3,
                .rate_limit_remaining_requests = 0,
                .rate_limit_remaining_tokens = 12,
                .provider_request_id = http.MetadataText.init("req_123"),
            }, .headers = &.{
                .{ .name = "x-goog-upload-url", .value = "https://example.test/upload/REDACTED" },
                .{ .name = "x-extra", .value = "one" },
                .{ .name = "X-Extra", .value = "two" },
            } },
        }},
    });
    defer std.testing.allocator.free(yaml);
    var parsed = try format.parse(std.testing.allocator, yaml);
    defer parsed.deinit();
    const metadata = &parsed.value.interactions[0].response.metadata;
    try std.testing.expectEqual(@as(?u64, 3), metadata.retry_after_seconds);
    try std.testing.expectEqual(@as(?u64, 0), metadata.rate_limit_remaining_requests);
    try std.testing.expectEqual(@as(?u64, 12), metadata.rate_limit_remaining_tokens);
    try std.testing.expectEqualStrings("req_123", metadata.requestId().?);
    const headers = parsed.value.interactions[0].response.headers;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("https://example.test/upload/REDACTED", headers[0].value);
    try std.testing.expectEqualStrings("one", headers[1].value);
    try std.testing.expectEqualStrings("two", headers[2].value);
}

test "cassette response headers replay through the borrowed sink" {
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://example.test
        \\    body:
        \\      type: none
        \\  response:
        \\    status: 200
        \\    headers:
        \\      x-upload-url:
        \\      - https://example.test/upload/REDACTED
        \\    body:
        \\      type: none
    ;
    const Capture = struct {
        value: ?[]const u8 = null,
        fn header(context: *anyopaque, value: http.Header) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value = value.value;
        }
    };
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    var capture: Capture = .{};
    const response = try replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .response_header_sink = .{ .context = &capture, .headerFn = Capture.header },
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("https://example.test/upload/REDACTED", capture.value.?);
}

test "cassette streaming replay and recording preserve lines" {
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://stream.test
        \\    body:
        \\      type: text
        \\      content: request
        \\  response:
        \\    status: 200
        \\    body:
        \\      type: text
        \\      content: |+
        \\        data: one
        \\
        \\        data: two
    ;
    const Capture = struct {
        starts: usize = 0,
        lines: usize = 0,
        fn start(context: *anyopaque, response: http.StreamResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.starts += 1;
            try std.testing.expectEqual(@as(u16, 200), response.status);
        }
        fn line(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.lines += 1;
        }
    };
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    var recorder = RecordingTransport.init(std.testing.allocator, replay.transport());
    defer recorder.deinit();
    var capture: Capture = .{};
    _ = try recorder.transport().streamLines(std.testing.allocator, .{
        .method = .POST,
        .url = "https://stream.test",
        .body = "request",
    }, .{ .context = &capture, .startFn = Capture.start, .lineFn = Capture.line });
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 4), capture.lines);
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n", recorder.interactions.items[0].response.body);
}

test "recorder creates a replayable cassette without headers" {
    const SecretTransport = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try std.testing.expectEqualStrings("secret-key", request.headers[0].value);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "response"),
                .metadata = .{ .rate_limit_remaining_requests = 4 },
            };
        }
    };
    var unused: u8 = 0;
    const inner = http.Transport{ .context = &unused, .sendFn = SecretTransport.send };
    var recorder = RecordingTransport.init(std.testing.allocator, inner);
    defer recorder.deinit();

    const response = try recorder.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .headers = &.{.{ .name = "authorization", .value = "secret-key", .sensitive = true }},
        .body = "request",
    });
    defer std.testing.allocator.free(response.body);

    const cassette_yaml = try recorder.cassetteYaml(std.testing.allocator);
    defer std.testing.allocator.free(cassette_yaml);
    try std.testing.expect(std.mem.indexOf(u8, cassette_yaml, "secret-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, cassette_yaml, "type: text") != null);

    var replay = try ReplayTransport.init(std.testing.allocator, cassette_yaml);
    defer replay.deinit();
    const replayed = try replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .body = "request",
    });
    defer std.testing.allocator.free(replayed.body);
    try std.testing.expectEqualStrings("response", replayed.body);
    try std.testing.expectEqual(@as(?u64, 4), replayed.metadata.rate_limit_remaining_requests);
}

test "recorder and replay share safe file request normalization" {
    const original_url = "https://upload.test/session/private-token";
    const redacted_url = "https://upload.test/session/REDACTED";
    const multipart =
        "--private-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "private file bytes\r\n" ++
        "--private-boundary--\r\n";
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try request.response_header_sink.?.header(.{
                .name = "x-upload-url",
                .value = original_url,
            });
            return .{ .status = 200, .body = try allocator.dupe(u8, "ok") };
        }
    };
    const Capture = struct {
        value: ?[]const u8 = null,
        fn header(context: *anyopaque, value: http.Header) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value = value.value;
        }
    };
    const url_filter = PrefixRedactionFilter{
        .prefix = "https://upload.test/session/",
        .replacement = redacted_url,
    };
    const multipart_filter = MultipartFileFilter{};
    const header_rules = ResponseHeaderRules{ .rules = &.{.{
        .name = "x-upload-url",
        .replacement = redacted_url,
    }} };
    var unused: u8 = 0;
    var recorder = RecordingTransport.initWithOptions(std.testing.allocator, .{
        .context = &unused,
        .sendFn = Stub.send,
    }, .{
        .request_filters = .{
            .url = url_filter.bodyFilter(),
            .body = multipart_filter.bodyFilter(),
        },
        .response_header_filter = header_rules.filter(),
    });
    defer recorder.deinit();
    var live_capture: Capture = .{};
    const response = try recorder.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = original_url,
        .headers = &.{.{ .name = "authorization", .value = "private-api-key" }},
        .body = multipart,
        .response_header_sink = .{ .context = &live_capture, .headerFn = Capture.header },
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings(original_url, live_capture.value.?);

    const yaml = try recorder.cassetteYaml(std.testing.allocator);
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "private-api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "private-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "private file bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "private-boundary") == null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, redacted_url) != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "[REDACTED FILE CONTENT]") != null);

    var replay = try ReplayTransport.initWithRequestFilters(std.testing.allocator, yaml, .{
        .url = url_filter.bodyFilter(),
        .body = multipart_filter.bodyFilter(),
    });
    defer replay.deinit();
    var replay_capture: Capture = .{};
    const replayed = try replay.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = original_url,
        .body = multipart,
        .response_header_sink = .{ .context = &replay_capture, .headerFn = Capture.header },
    });
    defer std.testing.allocator.free(replayed.body);
    try std.testing.expectEqualStrings(redacted_url, replay_capture.value.?);
    try std.testing.expectEqual(@as(usize, 0), replay.remaining());

    const sensitive_rules = ResponseHeaderRules{ .rules = &.{.{ .name = "set-cookie" }} };
    try std.testing.expectError(
        error.SensitiveCassetteHeader,
        ResponseHeaderRules.apply(&sensitive_rules, .{ .name = "set-cookie", .value = "private" }),
    );
    try std.testing.expect((try ResponseHeaderRules.apply(
        &header_rules,
        .{ .name = "content-type", .value = "text/plain" },
    )) == null);
    const unchanged_url = try PrefixRedactionFilter.apply(&url_filter, std.testing.allocator, "https://example.test/other");
    defer std.testing.allocator.free(unchanged_url);
    try std.testing.expectEqualStrings("https://example.test/other", unchanged_url);
    const non_json_filter = NonJsonBodyFilter{};
    const retained_json = try NonJsonBodyFilter.apply(&non_json_filter, std.testing.allocator, "{\"name\":\"note.txt\"}");
    defer std.testing.allocator.free(retained_json);
    try std.testing.expectEqualStrings("{\"name\":\"note.txt\"}", retained_json);
    const retained_empty = try NonJsonBodyFilter.apply(&non_json_filter, std.testing.allocator, "");
    defer std.testing.allocator.free(retained_empty);
    try std.testing.expectEqualStrings("", retained_empty);
    const redacted_bytes = try NonJsonBodyFilter.apply(&non_json_filter, std.testing.allocator, "private bytes");
    defer std.testing.allocator.free(redacted_bytes);
    try std.testing.expectEqualStrings("[REDACTED FILE CONTENT]", redacted_bytes);
}

test "JSON field filters remove volatile fields recursively" {
    const filter = JsonFieldFilter{ .field_names = &.{ "id", "created" } };
    const filtered = try JsonFieldFilter.apply(
        &filter,
        std.testing.allocator,
        "{\"id\":\"outer\",\"created\":12,\"items\":[{\"id\":\"inner\",\"keep\":true},3,null]}",
    );
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("{\"items\":[{\"keep\":true},3,null]}", filtered);
    try std.testing.expect(containsField(filter.field_names, "id"));
    try std.testing.expect(!containsField(filter.field_names, "keep"));
}

test "recorders can filter request and response JSON without changing live data" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"id\":\"live\",\"answer\":42}") };
        }
    };
    var unused: u8 = 0;
    const filter = JsonFieldFilter{ .field_names = &.{"id"} };
    var recorder = RecordingTransport.initWithFilters(
        std.testing.allocator,
        .{ .context = &unused, .sendFn = Stub.send },
        filter.bodyFilter(),
        filter.bodyFilter(),
    );
    defer recorder.deinit();
    const response = try recorder.transport().send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .body = "{\"id\":\"request\",\"prompt\":\"hi\"}",
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("{\"id\":\"live\",\"answer\":42}", response.body);
    try std.testing.expectEqualStrings("{\"prompt\":\"hi\"}", recorder.interactions.items[0].request.body);
    try std.testing.expectEqualStrings("{\"answer\":42}", recorder.interactions.items[0].response.body);
}

test "stream recordings apply configured body filters" {
    const Replace = struct {
        replacement: []const u8,
        fn apply(context: *const anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.replacement);
        }
        fn bodyFilter(self: *const @This()) BodyFilter {
            return .{ .context = self, .filterFn = apply };
        }
    };
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://stream.test
        \\    body:
        \\      type: text
        \\      content: request
        \\  response:
        \\    status: 200
        \\    body:
        \\      type: text
        \\      content: |+
        \\        data: original
    ;
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    const request_filter = Replace{ .replacement = "stable request" };
    const response_filter = Replace{ .replacement = "stable response" };
    var recorder = RecordingTransport.initWithFilters(
        std.testing.allocator,
        replay.transport(),
        request_filter.bodyFilter(),
        response_filter.bodyFilter(),
    );
    defer recorder.deinit();
    const Sink = struct {
        fn start(_: *anyopaque, _: http.StreamResponse) !void {}
        fn line(_: *anyopaque, _: []const u8) !void {}
    };
    var unused: u8 = 0;
    _ = try recorder.transport().streamLines(std.testing.allocator, .{
        .method = .POST,
        .url = "https://stream.test",
        .body = "request",
    }, .{ .context = &unused, .startFn = Sink.start, .lineFn = Sink.line });
    try std.testing.expectEqualStrings("stable request", recorder.interactions.items[0].request.body);
    try std.testing.expectEqualStrings("stable response", recorder.interactions.items[0].response.body);
}

test "recorder atomically writes and replaces a cassette" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "response") };
        }
    };
    var unused: u8 = 0;
    var recorder = RecordingTransport.init(std.testing.allocator, .{ .context = &unused, .sendFn = Stub.send });
    defer recorder.deinit();
    const response = try recorder.transport().send(std.testing.allocator, .{ .method = .POST, .url = "https://example.test", .body = "request" });
    defer std.testing.allocator.free(response.body);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try recorder.writeCassetteAtomic(std.testing.allocator, std.testing.io, temporary.dir, "nested/cassette.yaml");
    try recorder.writeCassetteAtomic(std.testing.allocator, std.testing.io, temporary.dir, "nested/cassette.yaml");
    const written = try temporary.dir.readFileAlloc(std.testing.io, "nested/cassette.yaml", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "https://example.test") != null);
    try std.testing.expect(written[written.len - 1] == '\n');
}

test "unsupported cassette versions are rejected" {
    try std.testing.expectError(error.UnsupportedCassetteVersion, ReplayTransport.init(
        std.testing.allocator,
        "version: 2\ninteractions: []\n",
    ));
}

fn recordWithAllocator(allocator: std.mem.Allocator) !void {
    const AllocatingTransport = struct {
        fn send(_: *anyopaque, response_allocator: std.mem.Allocator, _: http.Request) !http.Response {
            return .{ .status = 200, .body = try response_allocator.dupe(u8, "response") };
        }
    };
    var unused: u8 = 0;
    var recorder = RecordingTransport.init(allocator, .{
        .context = &unused,
        .sendFn = AllocatingTransport.send,
    });
    defer recorder.deinit();
    const response = try recorder.transport().send(allocator, .{
        .method = .POST,
        .url = "https://example.test",
        .body = "request",
    });
    allocator.free(response.body);
}

test "recorder cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, recordWithAllocator, .{});
}

fn recordStreamWithAllocator(allocator: std.mem.Allocator) !void {
    const cassette =
        \\version: 1
        \\interactions:
        \\- request:
        \\    method: POST
        \\    uri: https://stream.test
        \\    body:
        \\      type: text
        \\      content: request
        \\  response:
        \\    status: 200
        \\    body:
        \\      type: text
        \\      content: |+
        \\        data: one
    ;
    var replay = try ReplayTransport.init(std.testing.allocator, cassette);
    defer replay.deinit();
    var recorder = RecordingTransport.init(allocator, replay.transport());
    defer recorder.deinit();
    var unused: u8 = 0;
    const Sink = struct {
        fn start(_: *anyopaque, _: http.StreamResponse) !void {}
        fn line(_: *anyopaque, _: []const u8) !void {}
    };
    _ = try recorder.transport().streamLines(allocator, .{
        .method = .POST,
        .url = "https://stream.test",
        .body = "request",
    }, .{ .context = &unused, .startFn = Sink.start, .lineFn = Sink.line });
}

test "stream recorder cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, recordStreamWithAllocator, .{});
}
