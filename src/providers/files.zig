//! Shared authenticated file operations for first-party providers.

const std = @import("std");
const model = @import("../model.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");
const json_limits = @import("../json.zig");
const common = @import("common.zig");
const http_provider = @import("http.zig");

pub const Api = enum {
    openai,
    anthropic,
};

const anthropic_headers = [_]transport.Header{
    .{ .name = "anthropic-version", .value = "2023-06-01" },
    .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
};

pub fn upload(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    input: provider_types.FileInput,
    api: Api,
) !provider_types.OwnedFile {
    if (api == .anthropic and input.purpose != null) return error.InvalidProviderFileInput;
    var multipart = try encodeMultipart(allocator, input, if (api == .openai) input.purpose orelse "user_data" else null);
    defer multipart.deinit(allocator);
    var headers: std.ArrayList(transport.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "content-type", .value = multipart.content_type });
    try headers.appendSlice(allocator, headersFor(api));
    const response = configured.provider().request(allocator, .{
        .method = .POST,
        .endpoint = "/files",
        .headers = headers.items,
        .body = multipart.body,
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);
    return parseDescriptor(allocator, response.body, configured.name, api);
}

pub fn inspect(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    file: model.UploadedFile,
    api: Api,
) !provider_types.OwnedFile {
    const endpoint = try fileEndpoint(allocator, file.id, "");
    defer allocator.free(endpoint);
    const response = configured.provider().request(allocator, .{
        .method = .GET,
        .endpoint = endpoint,
        .headers = headersFor(api),
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);
    return parseDescriptor(allocator, response.body, configured.name, api);
}

pub fn download(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    file: model.UploadedFile,
    api: Api,
) !provider_types.OwnedFileDownload {
    const endpoint = try fileEndpoint(allocator, file.id, "/content");
    defer allocator.free(endpoint);
    const response = configured.provider().request(allocator, .{
        .method = .GET,
        .endpoint = endpoint,
        .headers = headersFor(api),
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const id = try memory.dupe(u8, file.id);
    const owner = try memory.dupe(u8, configured.name);
    const media_type = if (file.media_type) |value| try memory.dupe(u8, value) else null;
    const bytes = try memory.dupe(u8, response.body);
    return .{
        .arena = arena,
        .value = .{
            .descriptor = .{ .id = id, .provider_name = owner, .media_type = media_type },
            .bytes = bytes,
        },
    };
}

pub fn delete(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    file: model.UploadedFile,
    api: Api,
) !void {
    const endpoint = try fileEndpoint(allocator, file.id, "");
    defer allocator.free(endpoint);
    const response = configured.provider().request(allocator, .{
        .method = .DELETE,
        .endpoint = endpoint,
        .headers = headersFor(api),
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);
    try validateDeleteResponse(allocator, response.body, file.id, api);
}

fn headersFor(api: Api) []const transport.Header {
    return switch (api) {
        .openai => &.{},
        .anthropic => &anthropic_headers,
    };
}

const Multipart = struct {
    body: []u8,
    content_type: []u8,

    fn deinit(self: Multipart, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

fn encodeMultipart(allocator: std.mem.Allocator, input: provider_types.FileInput, purpose: ?[]const u8) !Multipart {
    return encodeMultipartFallible(allocator, input, purpose) catch |failure| switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        else => failure,
    };
}

fn encodeMultipartFallible(allocator: std.mem.Allocator, input: provider_types.FileInput, purpose: ?[]const u8) !Multipart {
    var salt = std.hash.Wyhash.hash(0, input.bytes);
    var boundary_buffer: [48]u8 = undefined;
    const boundary = while (true) {
        const candidate = try std.fmt.bufPrint(&boundary_buffer, "zigai-{x}", .{salt});
        if (std.mem.indexOf(u8, input.bytes, candidate) == null and
            std.mem.indexOf(u8, input.filename, candidate) == null and
            (purpose == null or std.mem.indexOf(u8, purpose.?, candidate) == null)) break candidate;
        salt +%= 1;
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    if (purpose) |value| {
        try writer.writeAll("--");
        try writer.writeAll(boundary);
        try writer.writeAll("\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n");
        try writer.writeAll(value);
        try writer.writeAll("\r\n");
    }
    try writer.writeAll("--");
    try writer.writeAll(boundary);
    try writer.writeAll("\r\nContent-Disposition: form-data; name=\"file\"; filename=\"");
    for (input.filename) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeAll("\"\r\nContent-Type: ");
    try writer.writeAll(input.media_type);
    try writer.writeAll("\r\n\r\n");
    try writer.writeAll(input.bytes);
    try writer.writeAll("\r\n--");
    try writer.writeAll(boundary);
    try writer.writeAll("--\r\n");

    const body = try output.toOwnedSlice();
    errdefer allocator.free(body);
    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
    return .{ .body = body, .content_type = content_type };
}

fn fileEndpoint(allocator: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]u8 {
    return fileEndpointFallible(allocator, id, suffix) catch |failure| switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        else => failure,
    };
}

fn fileEndpointFallible(allocator: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("/files/");
    try writePathSegment(&output.writer, id);
    try output.writer.writeAll(suffix);
    return output.toOwnedSlice();
}

fn writePathSegment(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn parseDescriptor(
    allocator: std.mem.Allocator,
    body: []const u8,
    provider_name: []const u8,
    api: Api,
) !provider_types.OwnedFile {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = json_limits.parseLeaky(
        std.json.Value,
        memory,
        body,
        json_limits.defaults.provider_response,
        .{ .allocate = .alloc_always },
        error.InvalidProviderResponse,
    ) catch |failure| return common.responseDecodeError(failure);
    const object = switch (root) {
        .object => |value| value,
        else => return error.ProviderResponseDecodeError,
    };
    const id = common.objectString(object, "id") catch |failure| return common.responseDecodeError(failure);
    const filename = common.optionalObjectString(object, "filename") catch |failure| return common.responseDecodeError(failure);
    const media_type = if (api == .anthropic)
        common.optionalObjectString(object, "mime_type") catch |failure| return common.responseDecodeError(failure)
    else
        null;
    const purpose = if (api == .openai)
        common.optionalObjectString(object, "purpose") catch |failure| return common.responseDecodeError(failure)
    else
        null;
    const size_bytes = common.optionalObjectInteger(object, if (api == .openai) "bytes" else "size_bytes") catch |failure|
        return common.responseDecodeError(failure);
    const owner = try memory.dupe(u8, provider_name);
    const metadata = try std.json.Stringify.valueAlloc(memory, root, .{});
    return .{
        .arena = arena,
        .value = .{
            .id = id,
            .provider_name = owner,
            .filename = filename,
            .media_type = media_type,
            .purpose = purpose,
            .size_bytes = size_bytes,
            .metadata_json = metadata,
        },
    };
}

fn validateDeleteResponse(allocator: std.mem.Allocator, body: []const u8, expected_id: []const u8, api: Api) !void {
    const parsed = json_limits.parse(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    ) catch |failure| return common.responseDecodeError(failure);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.ProviderResponseDecodeError,
    };
    const id = common.objectString(object, "id") catch |failure| return common.responseDecodeError(failure);
    if (!std.mem.eql(u8, id, expected_id)) return error.ProviderResponseDecodeError;
    switch (api) {
        .openai => {
            const deleted = object.get("deleted") orelse return error.ProviderResponseDecodeError;
            if (deleted != .bool or !deleted.bool) return error.ProviderResponseDecodeError;
        },
        .anthropic => {
            const kind = common.objectString(object, "type") catch |failure| return common.responseDecodeError(failure);
            if (!std.mem.eql(u8, kind, "file_deleted")) return error.ProviderResponseDecodeError;
        },
    }
}

test "multipart encoding escapes filenames and avoids payload boundaries" {
    const input = provider_types.FileInput{
        .filename = "a\\\"b.txt",
        .media_type = "text/plain",
        .bytes = "zigai-deadbeef\r\ncontent",
    };
    var encoded = try encodeMultipart(std.testing.allocator, input, "user_data");
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, encoded.content_type, "multipart/form-data; boundary=zigai-"));
    try std.testing.expect(std.mem.indexOf(u8, encoded.body, "name=\"purpose\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded.body, "filename=\"a\\\\\\\"b.txt\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, encoded.body, "--\r\n"));
}

test "file endpoints percent encode identifiers" {
    const endpoint = try fileEndpoint(std.testing.allocator, "file/a b", "/content");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("/files/file%2Fa%20b/content", endpoint);
}

test "file lifecycle operations release every partial allocation" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request_value: transport.Request) !transport.Response {
            const body = if (request_value.method == .DELETE)
                "{\"id\":\"file_1\",\"deleted\":true}"
            else if (std.mem.endsWith(u8, request_value.url, "/content"))
                "hi"
            else
                "{\"id\":\"file_1\",\"filename\":\"note.txt\",\"purpose\":\"user_data\",\"bytes\":2}";
            return .{ .status = 200, .body = try allocator.dupe(u8, body) };
        }

        fn run(allocator: std.mem.Allocator) !void {
            var marker: u8 = 0;
            var configured = http_provider.Configured{
                .name = "openai",
                .base_url = "https://api.example.test/v1",
                .transport = .{ .context = &marker, .sendFn = send },
            };
            var uploaded = try upload(&configured, allocator, .{
                .filename = "note.txt",
                .media_type = "text/plain",
                .bytes = "hi",
            }, .openai);
            defer uploaded.deinit();
            const file = uploaded.value.uploadedFile();
            var inspected = try inspect(&configured, allocator, file, .openai);
            defer inspected.deinit();
            var downloaded = try download(&configured, allocator, file, .openai);
            defer downloaded.deinit();
            try delete(&configured, allocator, file, .openai);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.run, .{});
}
