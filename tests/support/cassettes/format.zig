//! Cassetter-compatible YAML cassette parsing and serialization.

const std = @import("std");
const yaml = @import("yaml");
const http = @import("zigai").transport;

pub const Cassette = struct {
    version: u8,
    interactions: []const Interaction,
};

pub const Interaction = struct {
    request: RecordedRequest,
    response: RecordedResponse,
};

pub const RecordedRequest = struct {
    method: http.Method,
    url: []const u8,
    body: []const u8,
};

pub const RecordedResponse = struct {
    status: u16,
    body: []const u8,
    metadata: http.ResponseMetadata = .{},
};

pub const ParsedCassette = struct {
    arena: std.heap.ArenaAllocator,
    value: Cassette,

    pub fn deinit(self: *ParsedCassette) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParsedCassette {
    var document = try yaml.loadWithOptions(allocator, source, .{
        .schema = .core,
        .duplicate_key_behavior = .reject,
        .unknown_tag_behavior = .reject,
        .max_input_bytes = 64 * 1024 * 1024,
        .max_nesting_depth = 256,
    });
    defer document.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = try requireMapping(document.root);
    const version = try integerAs(u8, try requireField(root, "version"));
    if (version != 1) return error.UnsupportedCassetteVersion;
    const interaction_nodes = try requireSequence(try requireField(root, "interactions"));
    const interactions = try memory.alloc(Interaction, interaction_nodes.items.len);
    for (interaction_nodes.items, interactions) |node, *interaction| {
        const value = try requireMapping(node);
        interaction.* = .{
            .request = try parseRequest(memory, try requireField(value, "request")),
            .response = try parseResponse(memory, try requireField(value, "response")),
        };
    }
    return .{ .arena = arena, .value = .{ .version = version, .interactions = interactions } };
}

pub fn stringify(allocator: std.mem.Allocator, cassette: Cassette) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print("version: {d}\n", .{cassette.version});
    if (cassette.interactions.len == 0) {
        try writer.writeAll("interactions: []\n");
        return output.toOwnedSlice();
    }
    try writer.writeAll("interactions:\n");
    for (cassette.interactions) |interaction| {
        try writer.writeAll("- request:\n    method: ");
        try writer.writeAll(@tagName(interaction.request.method));
        try writer.writeAll("\n    uri: ");
        try writeQuoted(writer, interaction.request.url);
        try writer.writeAll("\n    headers: {}\n    body:\n");
        try writeBody(allocator, writer, interaction.request.body, 6);
        try writer.print("  response:\n    status: {d}\n", .{interaction.response.status});
        try writeMetadata(writer, interaction.response.metadata);
        try writer.writeAll("    body:\n");
        try writeBody(allocator, writer, interaction.response.body, 6);
    }
    return output.toOwnedSlice();
}

fn parseRequest(allocator: std.mem.Allocator, node: *const yaml.Node) !RecordedRequest {
    const request = try requireMapping(node);
    const method_name = try requireScalar(try requireField(request, "method"));
    return .{
        .method = std.meta.stringToEnum(http.Method, method_name) orelse return error.InvalidCassette,
        .url = try allocator.dupe(u8, try requireScalar(try requireField(request, "uri"))),
        .body = try parseBody(allocator, try requireField(request, "body")),
    };
}

fn parseResponse(allocator: std.mem.Allocator, node: *const yaml.Node) !RecordedResponse {
    const response = try requireMapping(node);
    return .{
        .status = try integerAs(u16, try requireField(response, "status")),
        .body = try parseBody(allocator, try requireField(response, "body")),
        .metadata = if (field(response, "headers")) |headers| try parseMetadata(headers) else .{},
    };
}

fn parseBody(allocator: std.mem.Allocator, node: *const yaml.Node) ![]const u8 {
    const body = try requireMapping(node);
    const body_type = try requireScalar(try requireField(body, "type"));
    if (std.mem.eql(u8, body_type, "none")) return allocator.dupe(u8, "");
    const content = try requireField(body, "content");
    if (std.mem.eql(u8, body_type, "text")) return allocator.dupe(u8, try requireScalar(content));
    if (std.mem.eql(u8, body_type, "binary")) return decodeHex(allocator, try requireScalar(content));
    if (!std.mem.eql(u8, body_type, "json")) return error.InvalidCassette;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeJsonNode(&json, content);
    return output.toOwnedSlice();
}

fn parseMetadata(node: *const yaml.Node) !http.ResponseMetadata {
    const headers = try requireMapping(node);
    return .{
        .retry_after_seconds = try optionalHeaderInteger(headers, "retry-after"),
        .rate_limit_remaining_requests = try optionalHeaderInteger(headers, "x-ratelimit-remaining-requests"),
        .rate_limit_remaining_tokens = try optionalHeaderInteger(headers, "x-ratelimit-remaining-tokens"),
        .provider_request_id = try optionalHeaderText(headers, "x-request-id"),
    };
}

fn optionalHeaderText(headers: yaml.MappingNode, name: []const u8) !?http.MetadataText {
    const node = field(headers, name) orelse return null;
    const values = try requireSequence(node);
    if (values.items.len != 1) return error.InvalidCassette;
    const value = try requireScalar(values.items[0]);
    return http.MetadataText.init(value) orelse error.InvalidCassette;
}

fn optionalHeaderInteger(headers: yaml.MappingNode, name: []const u8) !?u64 {
    const node = field(headers, name) orelse return null;
    const values = try requireSequence(node);
    if (values.items.len != 1) return error.InvalidCassette;
    return switch (values.items[0].*) {
        .scalar => |value| std.fmt.parseInt(u64, value.value, 10) catch return error.InvalidCassette,
        .int_value => |value| std.math.cast(u64, value.value) orelse error.InvalidCassette,
        else => error.InvalidCassette,
    };
}

fn writeMetadata(writer: *std.Io.Writer, metadata: http.ResponseMetadata) !void {
    if (metadata.retry_after_seconds == null and
        metadata.rate_limit_remaining_requests == null and
        metadata.rate_limit_remaining_tokens == null and
        metadata.provider_request_id == null)
    {
        return writer.writeAll("    headers: {}\n");
    }
    try writer.writeAll("    headers:\n");
    try writeHeader(writer, "retry-after", metadata.retry_after_seconds);
    try writeHeader(writer, "x-ratelimit-remaining-requests", metadata.rate_limit_remaining_requests);
    try writeHeader(writer, "x-ratelimit-remaining-tokens", metadata.rate_limit_remaining_tokens);
    if (metadata.requestId()) |request_id| {
        try writer.writeAll("      x-request-id:\n      - ");
        try writeQuoted(writer, request_id);
        try writer.writeByte('\n');
    }
}

fn writeHeader(writer: *std.Io.Writer, name: []const u8, value: ?u64) !void {
    if (value) |number| try writer.print("      {s}:\n      - \"{d}\"\n", .{ name, number });
}

fn writeBody(allocator: std.mem.Allocator, writer: *std.Io.Writer, body: []const u8, indentation: usize) !void {
    try writeIndent(writer, indentation);
    if (body.len == 0) return writer.writeAll("type: none\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
    if (parsed) |*json| {
        defer json.deinit();
        try writer.writeAll("type: json\n");
        try writeIndent(writer, indentation);
        try writer.writeAll("content:");
        if (isJsonCompoundEmpty(json.value)) {
            try writer.writeByte(' ');
            try writeJsonScalar(writer, json.value);
            return writer.writeByte('\n');
        }
        if (isJsonCompound(json.value)) {
            try writer.writeByte('\n');
            return writeJsonBlock(writer, json.value, indentation + 2);
        }
        try writer.writeByte(' ');
        try writeJsonScalar(writer, json.value);
        return writer.writeByte('\n');
    }

    if (std.unicode.Utf8View.init(body)) |_| {
        try writer.writeAll("type: text\n");
        try writeIndent(writer, indentation);
        try writer.writeAll("content:");
        if (std.mem.indexOfScalar(u8, body, '\n') == null) {
            try writer.writeByte(' ');
            try writeQuoted(writer, body);
            return writer.writeByte('\n');
        }
        try writer.writeAll(if (std.mem.endsWith(u8, body, "\n")) " |+\n" else " |-\n");
        const block = if (std.mem.endsWith(u8, body, "\n")) body[0 .. body.len - 1] else body;
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try writeIndent(writer, indentation + 2);
                try writer.writeAll(line);
            }
            try writer.writeByte('\n');
        }
        return;
    } else |_| {}

    try writer.writeAll("type: binary\n");
    try writeIndent(writer, indentation);
    try writer.writeAll("content: \"");
    for (body) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.writeAll("\"\n");
}

fn writeJsonBlock(writer: *std.Io.Writer, value: std.json.Value, indentation: usize) std.Io.Writer.Error!void {
    switch (value) {
        .object => |object| try writeJsonObject(writer, object, indentation, false),
        .array => |array| for (array.items) |item| {
            try writeIndent(writer, indentation);
            switch (item) {
                .object => |object| if (object.count() > 0) {
                    try writer.writeAll("- ");
                    try writeJsonObject(writer, object, indentation + 2, true);
                } else {
                    try writer.writeAll("- {}\n");
                },
                else => {
                    try writer.writeByte('-');
                    try writeJsonChild(writer, item, indentation);
                },
            }
        },
        else => unreachable,
    }
}

fn writeJsonObject(
    writer: *std.Io.Writer,
    object: std.json.ObjectMap,
    indentation: usize,
    first_is_inline: bool,
) std.Io.Writer.Error!void {
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (!first_is_inline or index > 0) try writeIndent(writer, indentation);
        try writeYamlKey(writer, entry.key_ptr.*);
        try writer.writeByte(':');
        try writeJsonChild(writer, entry.value_ptr.*, indentation);
    }
}

fn writeJsonChild(writer: *std.Io.Writer, value: std.json.Value, indentation: usize) std.Io.Writer.Error!void {
    if (isJsonCompoundEmpty(value)) {
        try writer.writeByte(' ');
        try writeJsonScalar(writer, value);
        return writer.writeByte('\n');
    }
    if (isJsonCompound(value)) {
        try writer.writeByte('\n');
        return writeJsonBlock(writer, value, indentation + 2);
    }
    if (value == .string and value.string.len > 512 and blockScalarSafe(value.string)) {
        return writeBlockScalar(writer, value.string, indentation + 2);
    }
    try writer.writeByte(' ');
    try writeJsonScalar(writer, value);
    try writer.writeByte('\n');
}

fn writeBlockScalar(writer: *std.Io.Writer, value: []const u8, indentation: usize) std.Io.Writer.Error!void {
    const trailing_newline = std.mem.endsWith(u8, value, "\n");
    try writer.writeAll(if (trailing_newline) " |+\n" else " |-\n");
    const block = if (trailing_newline) value[0 .. value.len - 1] else value;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        try writeIndent(writer, indentation);
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn blockScalarSafe(value: []const u8) bool {
    _ = std.unicode.Utf8View.init(value) catch return false;
    for (value) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\t') return false;
    }
    return true;
}

fn writeJsonScalar(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .array => |item| if (item.items.len == 0) try writer.writeAll("[]") else unreachable,
        .object => |item| if (item.count() == 0) try writer.writeAll("{}") else unreachable,
        else => {
            var json: std.json.Stringify = .{ .writer = writer };
            try json.write(value);
        },
    }
}

fn writeJsonNode(json: *std.json.Stringify, node: *const yaml.Node) !void {
    switch (node.*) {
        .null_value => try json.write(null),
        .bool_value => |value| try json.write(value.value),
        .int_value => |value| try json.write(value.value),
        .float_value => |value| try json.write(value.value),
        .scalar => |value| try json.write(value.value),
        .sequence => |sequence| {
            try json.beginArray();
            for (sequence.items) |item| try writeJsonNode(json, item);
            try json.endArray();
        },
        .mapping => |mapping| {
            try json.beginObject();
            for (mapping.pairs) |pair| {
                try json.objectField(try requireScalar(pair.key));
                try writeJsonNode(json, pair.value);
            }
            try json.endObject();
        },
        .alias => return error.InvalidCassette,
    }
}

fn decodeHex(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len % 2 != 0) return error.InvalidCassette;
    const output = try allocator.alloc(u8, source.len / 2);
    errdefer allocator.free(output);
    for (output, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(source[index * 2], 16) catch return error.InvalidCassette;
        const low = std.fmt.charToDigit(source[index * 2 + 1], 16) catch return error.InvalidCassette;
        byte.* = high * 16 + low;
    }
    return output;
}

fn requireMapping(node: *const yaml.Node) !yaml.MappingNode {
    return switch (node.*) {
        .mapping => |value| value,
        else => error.InvalidCassette,
    };
}

fn requireSequence(node: *const yaml.Node) !yaml.SequenceNode {
    return switch (node.*) {
        .sequence => |value| value,
        else => error.InvalidCassette,
    };
}

fn requireScalar(node: *const yaml.Node) ![]const u8 {
    return switch (node.*) {
        .scalar => |value| value.value,
        else => error.InvalidCassette,
    };
}

fn integerAs(comptime T: type, node: *const yaml.Node) !T {
    return switch (node.*) {
        .int_value => |value| std.math.cast(T, value.value) orelse error.InvalidCassette,
        .scalar => |value| std.fmt.parseInt(T, value.value, 10) catch error.InvalidCassette,
        else => error.InvalidCassette,
    };
}

fn requireField(mapping: yaml.MappingNode, name: []const u8) !*const yaml.Node {
    return field(mapping, name) orelse error.InvalidCassette;
}

fn field(mapping: yaml.MappingNode, name: []const u8) ?*const yaml.Node {
    for (mapping.pairs) |pair| {
        const key = switch (pair.key.*) {
            .scalar => |value| value.value,
            else => continue,
        };
        if (std.mem.eql(u8, key, name)) return pair.value;
    }
    return null;
}

fn isJsonCompound(value: std.json.Value) bool {
    return value == .array or value == .object;
}

fn isJsonCompoundEmpty(value: std.json.Value) bool {
    return switch (value) {
        .array => |array| array.items.len == 0,
        .object => |object| object.count() == 0,
        else => false,
    };
}

fn writeIndent(writer: *std.Io.Writer, amount: usize) !void {
    const indentation = try writer.writableSlice(amount);
    @memset(indentation, ' ');
}

fn writeYamlKey(writer: *std.Io.Writer, key: []const u8) !void {
    for (key) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') {
        return writeQuoted(writer, key);
    };
    if (key.len == 0) return writeQuoted(writer, key);
    try writer.writeAll(key);
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}
