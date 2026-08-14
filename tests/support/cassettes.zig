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

    pub fn init(allocator: std.mem.Allocator, cassette_yaml: []const u8) !ReplayTransport {
        return .{ .parsed = try format.parse(allocator, cassette_yaml) };
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
        if (interaction.request.method != request.method or
            !std.mem.eql(u8, interaction.request.url, request.url) or
            !std.mem.eql(u8, interaction.request.body, request.body))
        {
            return error.CassetteMismatch;
        }
        self.next_interaction += 1;
        const status = interaction.response.status;
        return .{
            .status = status,
            .body = try allocator.dupe(u8, interaction.response.body),
            .metadata = interaction.response.metadata,
        };
    }

    fn streamLines(context: *anyopaque, _: std.mem.Allocator, request: http.Request, sink: http.LineSink) !http.StreamResponse {
        const self: *ReplayTransport = @ptrCast(@alignCast(context));
        if (self.next_interaction >= self.parsed.value.interactions.len) return error.CassetteExhausted;
        const interaction = self.parsed.value.interactions[self.next_interaction];
        if (interaction.request.method != request.method or
            !std.mem.eql(u8, interaction.request.url, request.url) or
            !std.mem.eql(u8, interaction.request.body, request.body)) return error.CassetteMismatch;
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
    request_filter: ?BodyFilter = null,
    response_filter: ?BodyFilter = null,

    pub fn init(allocator: std.mem.Allocator, inner: http.Transport) RecordingTransport {
        return .{ .allocator = allocator, .inner = inner };
    }

    pub fn initWithFilters(allocator: std.mem.Allocator, inner: http.Transport, request_filter: ?BodyFilter, response_filter: ?BodyFilter) RecordingTransport {
        return .{
            .allocator = allocator,
            .inner = inner,
            .request_filter = request_filter,
            .response_filter = response_filter,
        };
    }

    pub fn deinit(self: *RecordingTransport) void {
        for (self.interactions.items) |interaction| {
            self.allocator.free(interaction.request.url);
            self.allocator.free(interaction.request.body);
            self.allocator.free(interaction.response.body);
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
        const response = try self.inner.send(allocator, request);
        errdefer allocator.free(response.body);

        const url = try self.allocator.dupe(u8, request.url);
        errdefer self.allocator.free(url);
        const request_body = if (self.request_filter) |filter|
            try filter.apply(self.allocator, request.body)
        else
            try self.allocator.dupe(u8, request.body);
        errdefer self.allocator.free(request_body);
        const response_body = if (self.response_filter) |filter|
            try filter.apply(self.allocator, response.body)
        else
            try self.allocator.dupe(u8, response.body);
        errdefer self.allocator.free(response_body);

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
            },
        });
        return response;
    }

    fn streamLines(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request, sink: http.LineSink) !http.StreamResponse {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        var capture = StreamCapture{ .allocator = allocator, .sink = sink };
        defer capture.body.deinit(allocator);
        const response = try self.inner.streamLines(allocator, request, capture.lineSink());
        const url = try self.allocator.dupe(u8, request.url);
        errdefer self.allocator.free(url);
        const request_body = if (self.request_filter) |filter|
            try filter.apply(self.allocator, request.body)
        else
            try self.allocator.dupe(u8, request.body);
        errdefer self.allocator.free(request_body);
        const response_body = if (self.response_filter) |filter|
            try filter.apply(self.allocator, capture.body.items)
        else
            try self.allocator.dupe(u8, capture.body.items);
        errdefer self.allocator.free(response_body);
        try self.interactions.append(self.allocator, .{
            .request = .{ .method = request.method, .url = url, .body = request_body },
            .response = .{ .status = response.status, .body = response_body, .metadata = response.metadata },
        });
        return response;
    }
};

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
