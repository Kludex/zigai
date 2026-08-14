//! Serialization and provider-facing processing for reusable agent history.

const std = @import("std");
const model = @import("model.zig");

pub const Error = error{
    InvalidHistory,
    UnsupportedVersion,
};

/// An owned history parsed from ZigAI's versioned JSON representation.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const model.Message,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Runtime state supplied to history processors before a model request.
pub const Context = struct {
    profile: model.ModelProfile,
    usage: model.Usage,
    model_requests: usize,
};

/// A built-in or application-defined transformation of provider-facing history.
pub const Processor = union(enum) {
    trim: Trim,
    compact,
    provider_valid,
    summarize: Summarize,
    custom: Custom,

    pub const Trim = struct {
        /// Maximum non-system messages retained from the end of history.
        max_messages: usize,
    };

    pub const Summarize = struct {
        context: *anyopaque,
        keep_recent_messages: usize = 8,
        summarizeFn: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const model.Message,
        ) anyerror![]const u8,
    };

    pub const Custom = struct {
        context: *anyopaque,
        processFn: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run: Context,
            messages: []const model.Message,
        ) anyerror![]const model.Message,
    };

    pub fn process(
        self: Processor,
        allocator: std.mem.Allocator,
        context: Context,
        messages: []const model.Message,
    ) ![]const model.Message {
        return switch (self) {
            .trim => |options| trim(allocator, messages, options.max_messages),
            .compact => compact(allocator, messages),
            .provider_valid => providerValid(allocator, messages),
            .summarize => |options| summarize(allocator, messages, options),
            .custom => |custom| custom.processFn(custom.context, allocator, context, messages),
        };
    }
};

/// Applies processors from left to right.
pub fn processAll(
    allocator: std.mem.Allocator,
    processors: []const Processor,
    context: Context,
    messages: []const model.Message,
) ![]const model.Message {
    var current = messages;
    for (processors) |processor| current = try processor.process(allocator, context, current);
    return current;
}

/// Encodes messages using ZigAI history JSON version 1.
pub fn stringify(allocator: std.mem.Allocator, messages: []const model.Message) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(1);
    try json.objectField("messages");
    try json.beginArray();
    for (messages) |message| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(@tagName(message.role));
        try json.objectField("parts");
        try json.beginArray();
        for (message.parts) |part| {
            try json.beginObject();
            switch (part) {
                .text => |value| {
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(value);
                },
                .image => |content| try writeContentPart(allocator, &json, "image", content),
                .audio => |content| try writeContentPart(allocator, &json, "audio", content),
                .document => |content| try writeContentPart(allocator, &json, "document", content),
                .binary => |content| try writeContentPart(allocator, &json, "binary", content),
                .thinking => |thinking| {
                    try json.objectField("type");
                    try json.write("thinking");
                    try json.objectField("content");
                    try json.write(thinking.content);
                    if (thinking.signature) |signature| {
                        try json.objectField("signature");
                        try json.write(signature);
                    }
                    if (thinking.metadata.len > 0) {
                        try json.objectField("metadata");
                        try json.write(thinking.metadata);
                    }
                },
                .tool_call => |call| {
                    try json.objectField("type");
                    try json.write("tool_call");
                    try json.objectField("id");
                    try json.write(call.id);
                    try json.objectField("name");
                    try json.write(call.name);
                    try json.objectField("arguments_json");
                    try json.write(call.arguments_json);
                    if (call.thought_signature) |signature| {
                        try json.objectField("thought_signature");
                        try json.write(signature);
                    }
                },
                .tool_result => |result| {
                    try json.objectField("type");
                    try json.write("tool_result");
                    try json.objectField("call_id");
                    try json.write(result.call_id);
                    try json.objectField("name");
                    try json.write(result.name);
                    try json.objectField("content");
                    try json.write(result.content);
                    try json.objectField("is_error");
                    try json.write(result.is_error);
                },
            }
            try json.endObject();
        }
        try json.endArray();
        if (message.metadata.len > 0) {
            try json.objectField("metadata");
            try json.write(message.metadata);
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeContentPart(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: []const u8,
    content: model.Content,
) !void {
    try json.objectField("type");
    try json.write(kind);
    try json.objectField("media_type");
    try json.write(content.media_type);
    if (content.filename) |filename| {
        try json.objectField("filename");
        try json.write(filename);
    }
    if (content.thought_signature) |signature| {
        try json.objectField("thought_signature");
        try json.write(signature);
    }
    if (content.metadata.len > 0) {
        try json.objectField("metadata");
        try json.write(content.metadata);
    }
    switch (content.source) {
        .bytes => |bytes| {
            const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            try json.objectField("source");
            try json.write("bytes");
            try json.objectField("data");
            try json.write(encoded);
        },
        .url => |url| {
            try json.objectField("source");
            try json.write("url");
            try json.objectField("url");
            try json.write(url);
        },
        .provider_file => |file| {
            try json.objectField("source");
            try json.write("provider_file");
            try json.objectField("file_id");
            try json.write(file.id);
            if (file.provider) |provider| {
                try json.objectField("provider");
                try json.write(provider);
            }
        },
    }
}

/// Parses an owned ZigAI history JSON document.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Owned {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, memory, source, .{
        .allocate = .alloc_always,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return failure,
        else => return Error.InvalidHistory,
    };
    const object = switch (root) {
        .object => |value| value,
        else => return Error.InvalidHistory,
    };
    const version = object.get("version") orelse return Error.InvalidHistory;
    const version_value = switch (version) {
        .integer => |value| value,
        else => return Error.InvalidHistory,
    };
    if (version_value != 1) return Error.UnsupportedVersion;
    const message_values = switch (object.get("messages") orelse return Error.InvalidHistory) {
        .array => |value| value.items,
        else => return Error.InvalidHistory,
    };
    const messages = try memory.alloc(model.Message, message_values.len);
    for (message_values, messages) |message_value, *message| {
        const message_object = switch (message_value) {
            .object => |value| value,
            else => return Error.InvalidHistory,
        };
        const role_name = try jsonString(message_object, "role");
        const role = std.meta.stringToEnum(model.Role, role_name) orelse return Error.InvalidHistory;
        const part_values = switch (message_object.get("parts") orelse return Error.InvalidHistory) {
            .array => |value| value.items,
            else => return Error.InvalidHistory,
        };
        const parts = try memory.alloc(model.Part, part_values.len);
        for (part_values, parts) |part_value, *part| {
            const part_object = switch (part_value) {
                .object => |value| value,
                else => return Error.InvalidHistory,
            };
            const part_type = try jsonString(part_object, "type");
            if (std.mem.eql(u8, part_type, "text")) {
                part.* = .{ .text = try jsonString(part_object, "text") };
            } else if (std.mem.eql(u8, part_type, "image")) {
                part.* = .{ .image = try parseContent(memory, part_object) };
            } else if (std.mem.eql(u8, part_type, "audio")) {
                part.* = .{ .audio = try parseContent(memory, part_object) };
            } else if (std.mem.eql(u8, part_type, "document")) {
                part.* = .{ .document = try parseContent(memory, part_object) };
            } else if (std.mem.eql(u8, part_type, "binary")) {
                part.* = .{ .binary = try parseContent(memory, part_object) };
            } else if (std.mem.eql(u8, part_type, "thinking")) {
                part.* = .{ .thinking = .{
                    .content = try jsonString(part_object, "content"),
                    .signature = try optionalJsonString(part_object, "signature"),
                    .metadata = try parseMetadata(memory, part_object.get("metadata")),
                } };
            } else if (std.mem.eql(u8, part_type, "tool_call")) {
                part.* = .{ .tool_call = .{
                    .id = try jsonString(part_object, "id"),
                    .name = try jsonString(part_object, "name"),
                    .arguments_json = try jsonString(part_object, "arguments_json"),
                    .thought_signature = try optionalJsonString(part_object, "thought_signature"),
                } };
            } else if (std.mem.eql(u8, part_type, "tool_result")) {
                const is_error = switch (part_object.get("is_error") orelse return Error.InvalidHistory) {
                    .bool => |value| value,
                    else => return Error.InvalidHistory,
                };
                part.* = .{ .tool_result = .{
                    .call_id = try jsonString(part_object, "call_id"),
                    .name = try jsonString(part_object, "name"),
                    .content = try jsonString(part_object, "content"),
                    .is_error = is_error,
                } };
            } else return Error.InvalidHistory;
        }
        message.* = .{
            .role = role,
            .parts = parts,
            .metadata = try parseMetadata(memory, message_object.get("metadata")),
        };
    }
    return .{ .arena = arena, .messages = messages };
}

fn parseContent(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model.Content {
    const source_name = try jsonString(object, "source");
    const source: model.ContentSource = if (std.mem.eql(u8, source_name, "bytes")) blk: {
        const encoded = try jsonString(object, "data");
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return Error.InvalidHistory;
        const decoded = try allocator.alloc(u8, size);
        std.base64.standard.Decoder.decode(decoded, encoded) catch return Error.InvalidHistory;
        break :blk .{ .bytes = decoded };
    } else if (std.mem.eql(u8, source_name, "url"))
        .{ .url = try jsonString(object, "url") }
    else if (std.mem.eql(u8, source_name, "provider_file"))
        .{ .provider_file = .{
            .id = try jsonString(object, "file_id"),
            .provider = try optionalJsonString(object, "provider"),
        } }
    else
        return Error.InvalidHistory;
    return .{
        .source = source,
        .media_type = try jsonString(object, "media_type"),
        .filename = try optionalJsonString(object, "filename"),
        .thought_signature = try optionalJsonString(object, "thought_signature"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    };
}

fn parseMetadata(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const model.Metadata {
    const metadata_value = value orelse return &.{};
    const values = switch (metadata_value) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    };
    const metadata = try allocator.alloc(model.Metadata, values.len);
    for (values, metadata) |item, *result| {
        const object = switch (item) {
            .object => |entry| entry,
            else => return Error.InvalidHistory,
        };
        result.* = .{
            .key = try jsonString(object, "key"),
            .value = try jsonString(object, "value"),
        };
    }
    return metadata;
}

/// Keeps system messages plus the newest `max_messages` non-system messages.
pub fn trim(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    max_messages: usize,
) ![]const model.Message {
    var non_system: usize = 0;
    for (messages) |message| if (message.role != .system) {
        non_system += 1;
    };
    const skip = non_system -| max_messages;
    var seen: usize = 0;
    var retained: std.ArrayList(model.Message) = .empty;
    for (messages) |message| {
        if (message.role == .system) {
            try retained.append(allocator, message);
        } else {
            if (seen >= skip) try retained.append(allocator, message);
            seen += 1;
        }
    }
    return providerValid(allocator, retained.items);
}

/// Merges adjacent text-only messages with the same role.
pub fn compact(allocator: std.mem.Allocator, messages: []const model.Message) ![]const model.Message {
    var result: std.ArrayList(model.Message) = .empty;
    for (messages) |message| {
        if (message.parts.len == 0) continue;
        if (result.items.len > 0 and result.items[result.items.len - 1].role == message.role and
            textOnly(result.items[result.items.len - 1]) and textOnly(message))
        {
            const previous = result.items[result.items.len - 1];
            const left = try collectText(allocator, previous.parts);
            const right = try collectText(allocator, message.parts);
            const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ left, right });
            const parts = try allocator.alloc(model.Part, 1);
            parts[0] = .{ .text = joined };
            result.items[result.items.len - 1] = .{ .role = message.role, .parts = parts };
        } else try result.append(allocator, message);
    }
    return result.toOwnedSlice(allocator);
}

/// Removes malformed and orphaned parts and repairs tool-result names.
pub fn providerValid(allocator: std.mem.Allocator, messages: []const model.Message) ![]const model.Message {
    var cleaned: std.ArrayList(model.Message) = .empty;
    for (messages) |message| {
        var parts: std.ArrayList(model.Part) = .empty;
        for (message.parts) |part| switch (part) {
            .text => if (message.role != .tool) try parts.append(allocator, part),
            .image, .audio, .document, .binary => if (message.role == .user or message.role == .assistant)
                try parts.append(allocator, part),
            .thinking => if (message.role == .assistant) try parts.append(allocator, part),
            .tool_call => |call| if (message.role == .assistant and try validJson(allocator, call.arguments_json)) {
                try parts.append(allocator, part);
            },
            .tool_result => if (message.role == .tool) try parts.append(allocator, part),
        };
        if (parts.items.len > 0) try cleaned.append(allocator, .{
            .role = message.role,
            .parts = try parts.toOwnedSlice(allocator),
            .metadata = message.metadata,
        });
    }

    var result: std.ArrayList(model.Message) = .empty;
    for (cleaned.items, 0..) |message, index| {
        if (message.role == .tool) {
            var previous = result.items.len;
            while (previous > 0 and result.items[previous - 1].role == .tool) previous -= 1;
            if (previous == 0 or result.items[previous - 1].role != .assistant) continue;
            const assistant = result.items[previous - 1];
            var results: std.ArrayList(model.Part) = .empty;
            for (message.parts) |part| switch (part) {
                .tool_result => |tool_result| if (findCall(assistant.parts, tool_result.call_id)) |call| {
                    var repaired = tool_result;
                    repaired.name = call.name;
                    try results.append(allocator, .{ .tool_result = repaired });
                },
                else => {},
            };
            if (results.items.len > 0) try result.append(allocator, .{
                .role = .tool,
                .parts = try results.toOwnedSlice(allocator),
                .metadata = message.metadata,
            });
            continue;
        }

        if (message.role == .assistant) {
            var parts: std.ArrayList(model.Part) = .empty;
            for (message.parts) |part| switch (part) {
                .tool_call => |call| {
                    var has_result = false;
                    var next = index + 1;
                    while (next < cleaned.items.len and cleaned.items[next].role == .tool) : (next += 1) {
                        if (findResult(cleaned.items[next].parts, call.id)) {
                            has_result = true;
                            break;
                        }
                    }
                    if (has_result) try parts.append(allocator, part);
                },
                else => try parts.append(allocator, part),
            };
            if (parts.items.len > 0) try result.append(allocator, .{
                .role = message.role,
                .parts = try parts.toOwnedSlice(allocator),
                .metadata = message.metadata,
            });
            continue;
        }
        try result.append(allocator, message);
    }
    return result.toOwnedSlice(allocator);
}

fn summarize(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    options: Processor.Summarize,
) ![]const model.Message {
    var non_system: usize = 0;
    for (messages) |message| if (message.role != .system) {
        non_system += 1;
    };
    if (non_system <= options.keep_recent_messages) return messages;
    const older_count = non_system - options.keep_recent_messages;
    var older: std.ArrayList(model.Message) = .empty;
    var retained: std.ArrayList(model.Message) = .empty;
    var seen: usize = 0;
    for (messages) |message| {
        if (message.role == .system) {
            try retained.append(allocator, message);
        } else if (seen < older_count) {
            try older.append(allocator, message);
            seen += 1;
        } else try retained.append(allocator, message);
    }
    const summary = try options.summarizeFn(options.context, allocator, older.items);
    const summary_parts = try allocator.alloc(model.Part, 1);
    summary_parts[0] = .{ .text = summary };
    var with_summary: std.ArrayList(model.Message) = .empty;
    var inserted = false;
    for (retained.items) |message| {
        if (!inserted and message.role != .system) {
            try with_summary.append(allocator, .{ .role = .user, .parts = summary_parts });
            inserted = true;
        }
        try with_summary.append(allocator, message);
    }
    if (!inserted) try with_summary.append(allocator, .{ .role = .user, .parts = summary_parts });
    return providerValid(allocator, try compact(allocator, with_summary.items));
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .string => |value| value,
        else => Error.InvalidHistory,
    };
}

fn optionalJsonString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => Error.InvalidHistory,
    };
}

fn validJson(allocator: std.mem.Allocator, source: []const u8) !bool {
    _ = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch |failure| switch (failure) {
        error.OutOfMemory => return failure,
        else => return false,
    };
    return true;
}

fn textOnly(message: model.Message) bool {
    if (message.metadata.len > 0) return false;
    for (message.parts) |part| if (part != .text) return false;
    return true;
}

fn collectText(allocator: std.mem.Allocator, parts: []const model.Part) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, index| switch (part) {
        .text => |value| {
            if (index > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, value);
        },
        else => {},
    };
    return text.toOwnedSlice(allocator);
}

fn findCall(parts: []const model.Part, id: []const u8) ?model.ToolCall {
    for (parts) |part| switch (part) {
        .tool_call => |call| if (std.mem.eql(u8, call.id, id)) return call,
        else => {},
    };
    return null;
}

fn findResult(parts: []const model.Part, id: []const u8) bool {
    for (parts) |part| switch (part) {
        .tool_result => |result| if (std.mem.eql(u8, result.call_id, id)) return true,
        else => {},
    };
    return false;
}

test "history JSON round trips every message part" {
    const messages = [_]model.Message{
        .{ .role = .user, .parts = &.{
            .{ .text = "hello \"Zig\"" },
            .{ .image = .{
                .source = .{ .bytes = "\x00\xff" },
                .media_type = "image/png",
                .thought_signature = "image-signed",
            } },
            .{ .audio = .{ .source = .{ .url = "https://example.test/audio.mp3" }, .media_type = "audio/mpeg" } },
            .{ .document = .{
                .source = .{ .provider_file = .{ .id = "files/one", .provider = "gcp.gen_ai" } },
                .media_type = "application/pdf",
                .filename = "guide.pdf",
                .metadata = &.{.{ .key = "source", .value = "manual" }},
            } },
            .{ .binary = .{ .source = .{ .bytes = "raw" }, .media_type = "application/octet-stream" } },
        }, .metadata = &.{.{ .key = "thread", .value = "one" }} },
        .{ .role = .assistant, .parts = &.{.{ .thinking = .{
            .content = "reasoning",
            .signature = "opaque",
            .metadata = &.{.{ .key = "kind", .value = "private" }},
        } }} },
        .{ .role = .assistant, .parts = &.{.{ .tool_call = .{
            .id = "call-1",
            .name = "lookup",
            .arguments_json = "{\"value\":1}",
            .thought_signature = "call-signed",
        } }} },
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{
            .call_id = "call-1",
            .name = "lookup",
            .content = "failed",
            .is_error = true,
        } }} },
    };
    const encoded = try stringify(std.testing.allocator, &messages);
    var decoded = try parse(std.testing.allocator, encoded);
    defer decoded.deinit();
    std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 4), decoded.messages.len);
    try std.testing.expectEqualStrings("hello \"Zig\"", decoded.messages[0].parts[0].text);
    try std.testing.expectEqualSlices(u8, "\x00\xff", decoded.messages[0].parts[1].image.source.bytes);
    try std.testing.expectEqualStrings("image-signed", decoded.messages[0].parts[1].image.thought_signature.?);
    try std.testing.expectEqualStrings("files/one", decoded.messages[0].parts[3].document.source.provider_file.id);
    try std.testing.expectEqualStrings("manual", decoded.messages[0].parts[3].document.metadata[0].value);
    try std.testing.expectEqualStrings("one", decoded.messages[0].metadata[0].value);
    try std.testing.expectEqualStrings("opaque", decoded.messages[1].parts[0].thinking.signature.?);
    try std.testing.expectEqualStrings("{\"value\":1}", decoded.messages[2].parts[0].tool_call.arguments_json);
    try std.testing.expectEqualStrings("call-signed", decoded.messages[2].parts[0].tool_call.thought_signature.?);
    try std.testing.expect(decoded.messages[3].parts[0].tool_result.is_error);
    try std.testing.expectError(Error.UnsupportedVersion, parse(std.testing.allocator, "{\"version\":2,\"messages\":[]}"));
    try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, "{}"));
}

test "provider-valid history removes orphans and repairs tool names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]model.Message{
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{
            .call_id = "orphan",
            .name = "wrong",
            .content = "ignored",
        } }} },
        .{ .role = .assistant, .parts = &.{
            .{ .thinking = .{ .content = "considering" } },
            .{ .tool_call = .{ .id = "invalid", .name = "bad", .arguments_json = "{" } },
            .{ .tool_call = .{ .id = "valid", .name = "lookup", .arguments_json = "{}" } },
        } },
        .{ .role = .tool, .parts = &.{
            .{ .tool_result = .{ .call_id = "other", .name = "ignored", .content = "ignored" } },
            .{ .tool_result = .{
                .call_id = "valid",
                .name = "stale-name",
                .content = "ok",
            } },
        } },
        .{ .role = .user, .parts = &.{
            .{ .text = "continue" },
            .{ .image = .{ .source = .{ .url = "https://example.test/image" }, .media_type = "image/png" } },
            .{ .tool_call = .{ .id = "wrong-role", .name = "bad", .arguments_json = "{}" } },
        } },
    };
    const valid = try providerValid(arena.allocator(), &messages);

    try std.testing.expectEqual(@as(usize, 3), valid.len);
    try std.testing.expectEqual(model.Role.assistant, valid[0].role);
    try std.testing.expectEqual(@as(usize, 2), valid[0].parts.len);
    try std.testing.expectEqualStrings("considering", valid[0].parts[0].thinking.content);
    try std.testing.expectEqualStrings("valid", valid[0].parts[1].tool_call.id);
    try std.testing.expectEqualStrings("lookup", valid[1].parts[0].tool_result.name);
    try std.testing.expectEqual(@as(usize, 2), valid[2].parts.len);
    try std.testing.expectEqualStrings("continue", valid[2].parts[0].text);
    try std.testing.expectEqualStrings("image/png", valid[2].parts[1].image.media_type);
    try std.testing.expect(findCall(&.{.{ .text = "not a call" }}, "missing") == null);
    try std.testing.expect(!findResult(&.{.{ .text = "not a result" }}, "missing"));
}

test "history processors trim compact and summarize in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]model.Message{
        .{ .role = .system, .parts = &.{.{ .text = "rules" }} },
        .{ .role = .user, .parts = &.{.{ .text = "one" }} },
        .{ .role = .user, .parts = &.{.{ .text = "two" }} },
        .{ .role = .assistant, .parts = &.{.{ .text = "three" }} },
        .{ .role = .user, .parts = &.{.{ .text = "four" }} },
    };
    const compacted = try compact(arena.allocator(), &messages);
    try std.testing.expectEqual(@as(usize, 4), compacted.len);
    try std.testing.expectEqualStrings("one\ntwo", compacted[1].parts[0].text);

    const Summary = struct {
        calls: usize = 0,
        fn run(context: *anyopaque, allocator: std.mem.Allocator, older: []const model.Message) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 2), older.len);
            return allocator.dupe(u8, "Earlier: one, two.");
        }
    };
    var summary: Summary = .{};
    const processors = [_]Processor{
        .{ .summarize = .{
            .context = &summary,
            .keep_recent_messages = 2,
            .summarizeFn = Summary.run,
        } },
        .provider_valid,
    };
    const processed = try processAll(arena.allocator(), &processors, .{
        .profile = .{},
        .usage = .{},
        .model_requests = 0,
    }, &messages);
    try std.testing.expectEqual(@as(usize, 4), processed.len);
    try std.testing.expectEqualStrings("Earlier: one, two.", processed[1].parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), summary.calls);

    const trimmed = try trim(arena.allocator(), &messages, 2);
    try std.testing.expectEqual(@as(usize, 3), trimmed.len);
    try std.testing.expectEqual(model.Role.system, trimmed[0].role);
    try std.testing.expectEqualStrings("three", trimmed[1].parts[0].text);

    const processor_trimmed = try (Processor{ .trim = .{ .max_messages = 1 } }).process(
        arena.allocator(),
        .{ .profile = .{}, .usage = .{}, .model_requests = 0 },
        &messages,
    );
    try std.testing.expectEqual(@as(usize, 2), processor_trimmed.len);
    const processor_compacted = try (@as(Processor, .compact)).process(
        arena.allocator(),
        .{ .profile = .{}, .usage = .{}, .model_requests = 0 },
        &messages,
    );
    try std.testing.expectEqual(@as(usize, 4), processor_compacted.len);
}

test "history rejects malformed field and metadata types" {
    const invalid = [_][]const u8{
        "{\"version\":1,\"messages\":[{\"role\":1,\"parts\":[]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"assistant\",\"parts\":[{\"type\":\"thinking\",\"content\":\"x\",\"signature\":false}]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"user\",\"parts\":[],\"metadata\":[1]}]}",
    };
    for (invalid) |source| try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, source));
}

fn checkParseAllocationFailure(allocator: std.mem.Allocator) !void {
    var owned = try parse(
        allocator,
        "{\"version\":1,\"messages\":[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]}]}",
    );
    defer owned.deinit();
}

fn checkProviderValidationAllocationFailure(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try providerValid(arena.allocator(), &.{.{
        .role = .assistant,
        .parts = &.{.{ .tool_call = .{ .id = "call", .name = "lookup", .arguments_json = "{}" } }},
    }});
}

test "history allocation failures clean up owned state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParseAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkProviderValidationAllocationFailure, .{});
}
