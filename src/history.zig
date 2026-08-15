//! Lossless serialization and provider-facing processing for reusable agent history.
//!
//! Version 2 stores distinct request and response messages. The parser also
//! accepts version 1 role-based histories and migrates them into the new model.

const std = @import("std");
const model = @import("model.zig");
const json_limits = @import("json.zig");

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
    control: model.RunControl = .{},
};

/// A built-in or application-defined transformation of provider-facing history.
pub const Processor = union(enum) {
    trim: Trim,
    compact,
    provider_valid,
    summarize: Summarize,
    custom: Custom,

    pub const Trim = struct {
        /// Maximum number of non-system messages retained from the end.
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
            .summarize => |options| summarize(allocator, messages, options, context.control),
            .custom => |custom| context.control.invoke(
                []const model.Message,
                invokeCustomProcessor,
                .{ custom, allocator, context, messages },
            ),
        };
    }
};

fn invokeCustomProcessor(
    custom: Processor.Custom,
    allocator: std.mem.Allocator,
    context: Context,
    messages: []const model.Message,
) ![]const model.Message {
    return custom.processFn(custom.context, allocator, context, messages);
}

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

/// Encodes messages using ZigAI history JSON version 2.
pub fn stringify(allocator: std.mem.Allocator, messages: []const model.Message) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(2);
    try json.objectField("messages");
    try json.beginArray();
    for (messages) |message| switch (message) {
        .request => |request| try writeRequest(allocator, &json, request),
        .response => |response| try writeResponse(allocator, &json, response),
    };
    try json.endArray();
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeRequest(allocator: std.mem.Allocator, json: *std.json.Stringify, request: model.RequestMessage) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write("request");
    try json.objectField("parts");
    try json.beginArray();
    for (request.parts) |part| {
        try json.beginObject();
        switch (part) {
            .system_prompt => |content| try writeTextPart(json, "system-prompt", content),
            .user_prompt => |content| {
                try json.objectField("part_kind");
                try json.write("user-prompt");
                try json.objectField("content");
                try writeUserContent(allocator, json, content);
            },
            .tool_return => |result| {
                try json.objectField("part_kind");
                try json.write("tool-return");
                try writeToolReturn(json, result);
            },
            .retry_prompt => |content| try writeTextPart(json, "retry-prompt", content),
        }
        try json.endObject();
    }
    try json.endArray();
    try writeOptionalInteger(json, "timestamp_unix_ms", request.timestamp_unix_ms);
    try writeOptionalString(json, "instructions", request.instructions);
    try writeOptionalString(json, "run_id", request.run_id);
    try writeOptionalString(json, "conversation_id", request.conversation_id);
    try writeMetadata(json, request.metadata);
    if (request.state != .complete) {
        try json.objectField("state");
        try json.write(@tagName(request.state));
    }
    try json.endObject();
}

fn writeResponse(allocator: std.mem.Allocator, json: *std.json.Stringify, response: model.ResponseMessage) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write("response");
    try json.objectField("parts");
    try json.beginArray();
    for (response.parts) |part| {
        try json.beginObject();
        switch (part) {
            .text => |content| try writeTextPart(json, "text", content),
            .image => |content| try writeResponseContent(allocator, json, "image", content),
            .audio => |content| try writeResponseContent(allocator, json, "audio", content),
            .document => |content| try writeResponseContent(allocator, json, "document", content),
            .binary => |content| try writeResponseContent(allocator, json, "binary", content),
            .thinking => |thinking| {
                try json.objectField("part_kind");
                try json.write("thinking");
                try json.objectField("content");
                try json.write(thinking.content);
                try writeOptionalString(json, "signature", thinking.signature);
                try writeMetadata(json, thinking.metadata);
            },
            .tool_call => |call| {
                try json.objectField("part_kind");
                try json.write("tool-call");
                try json.objectField("tool_call_id");
                try json.write(call.id);
                try json.objectField("tool_name");
                try json.write(call.name);
                try json.objectField("args");
                try json.write(call.arguments_json);
                try writeOptionalString(json, "thought_signature", call.thought_signature);
            },
        }
        try json.endObject();
    }
    try json.endArray();
    if (response.usage.input_tokens != 0 or response.usage.output_tokens != 0) {
        try json.objectField("usage");
        try json.write(response.usage);
    }
    try writeOptionalInteger(json, "timestamp_unix_ms", response.timestamp_unix_ms);
    try writeOptionalString(json, "provider_name", response.provider_name);
    try writeOptionalString(json, "provider_url", response.provider_url);
    try writeOptionalRawJson(allocator, json, "provider_details", response.provider_details_json);
    try writeOptionalString(json, "provider_response_id", response.provider_response_id);
    try writeOptionalString(json, "model_name", response.model_name);
    if (response.finish_reason) |reason| {
        try json.objectField("finish_reason");
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(reason.kind));
        try json.objectField("raw");
        try json.write(reason.raw);
        try json.endObject();
    }
    try writeOptionalString(json, "run_id", response.run_id);
    try writeOptionalString(json, "conversation_id", response.conversation_id);
    try writeMetadata(json, response.metadata);
    try json.endObject();
}

fn writeTextPart(json: *std.json.Stringify, kind: []const u8, content: []const u8) !void {
    try json.objectField("part_kind");
    try json.write(kind);
    try json.objectField("content");
    try json.write(content);
}

fn writeToolReturn(json: *std.json.Stringify, result: model.ToolResult) !void {
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("tool_name");
    try json.write(result.name);
    try json.objectField("content");
    try json.write(result.content);
    if (result.is_error) {
        try json.objectField("is_error");
        try json.write(true);
    }
}

fn writeUserContent(allocator: std.mem.Allocator, json: *std.json.Stringify, content: model.UserContent) !void {
    try json.beginObject();
    switch (content) {
        .text => |text| {
            try json.objectField("kind");
            try json.write("text");
            try json.objectField("content");
            try json.write(text);
        },
        .image => |value| try writeContent(allocator, json, "image", value),
        .audio => |value| try writeContent(allocator, json, "audio", value),
        .document => |value| try writeContent(allocator, json, "document", value),
        .binary => |value| try writeContent(allocator, json, "binary", value),
    }
    try json.endObject();
}

fn writeResponseContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: []const u8,
    content: model.Content,
) !void {
    try json.objectField("part_kind");
    try json.write("file");
    try json.objectField("content");
    try json.beginObject();
    try writeContent(allocator, json, kind, content);
    try json.endObject();
}

fn writeContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: []const u8,
    content: model.Content,
) !void {
    try json.objectField("kind");
    try json.write(kind);
    try json.objectField("media_type");
    try json.write(content.media_type);
    try writeOptionalString(json, "filename", content.filename);
    try writeOptionalString(json, "thought_signature", content.thought_signature);
    try writeMetadata(json, content.metadata);
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
            try writeOptionalString(json, "provider", file.provider);
        },
    }
}

fn writeOptionalString(json: *std.json.Stringify, name: []const u8, value: ?[]const u8) !void {
    if (value) |string| {
        try json.objectField(name);
        try json.write(string);
    }
}

fn writeOptionalInteger(json: *std.json.Stringify, name: []const u8, value: ?i64) !void {
    if (value) |integer| {
        try json.objectField(name);
        try json.write(integer);
    }
}

fn writeOptionalRawJson(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    name: []const u8,
    source: ?[]const u8,
) !void {
    const raw = source orelse return;
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        raw,
        json_limits.defaults.history,
        .{},
        Error.InvalidHistory,
    );
    defer parsed.deinit();
    try json.objectField(name);
    try json.write(parsed.value);
}

fn writeMetadata(json: *std.json.Stringify, metadata: []const model.Metadata) !void {
    if (metadata.len == 0) return;
    try json.objectField("metadata");
    try json.write(metadata);
}

/// Parses an owned ZigAI history document, including legacy version 1.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Owned {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = try json_limits.parseLeaky(
        std.json.Value,
        memory,
        source,
        json_limits.defaults.history,
        .{ .allocate = .alloc_always },
        Error.InvalidHistory,
    );
    const object = try asObject(root);
    const version = try jsonInteger(object, "version");
    const values = try jsonArray(object, "messages");
    const messages = switch (version) {
        1 => try parseV1(memory, values),
        2 => try parseV2(memory, values),
        else => return Error.UnsupportedVersion,
    };
    return .{ .arena = arena, .messages = messages };
}

fn parseV2(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const model.Message {
    const messages = try allocator.alloc(model.Message, values.len);
    for (values, messages) |value, *message| {
        const object = try asObject(value);
        const kind = try jsonString(object, "kind");
        if (std.mem.eql(u8, kind, "request")) {
            message.* = .{ .request = try parseRequest(allocator, object) };
        } else if (std.mem.eql(u8, kind, "response")) {
            message.* = .{ .response = try parseResponse(allocator, object) };
        } else return Error.InvalidHistory;
    }
    return messages;
}

fn parseRequest(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model.RequestMessage {
    const values = try jsonArray(object, "parts");
    const parts = try allocator.alloc(model.RequestPart, values.len);
    for (values, parts) |value, *part| {
        const part_object = try asObject(value);
        const kind = try jsonString(part_object, "part_kind");
        if (std.mem.eql(u8, kind, "system-prompt")) {
            part.* = .{ .system_prompt = try jsonString(part_object, "content") };
        } else if (std.mem.eql(u8, kind, "user-prompt")) {
            part.* = .{ .user_prompt = try parseUserContent(allocator, try jsonObject(part_object, "content")) };
        } else if (std.mem.eql(u8, kind, "tool-return")) {
            part.* = .{ .tool_return = try parseToolReturn(part_object) };
        } else if (std.mem.eql(u8, kind, "retry-prompt")) {
            part.* = .{ .retry_prompt = try jsonString(part_object, "content") };
        } else return Error.InvalidHistory;
    }
    const state_name = try optionalJsonString(object, "state");
    return .{
        .parts = parts,
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .instructions = try optionalJsonString(object, "instructions"),
        .run_id = try optionalJsonString(object, "run_id"),
        .conversation_id = try optionalJsonString(object, "conversation_id"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .state = if (state_name) |name|
            std.meta.stringToEnum(model.RequestState, name) orelse return Error.InvalidHistory
        else
            .complete,
    };
}

fn parseResponse(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model.ResponseMessage {
    const values = try jsonArray(object, "parts");
    const parts = try allocator.alloc(model.ResponsePart, values.len);
    for (values, parts) |value, *part| {
        const part_object = try asObject(value);
        const kind = try jsonString(part_object, "part_kind");
        if (std.mem.eql(u8, kind, "text")) {
            part.* = .{ .text = try jsonString(part_object, "content") };
        } else if (std.mem.eql(u8, kind, "thinking")) {
            part.* = .{ .thinking = .{
                .content = try jsonString(part_object, "content"),
                .signature = try optionalJsonString(part_object, "signature"),
                .metadata = try parseMetadata(allocator, part_object.get("metadata")),
            } };
        } else if (std.mem.eql(u8, kind, "tool-call")) {
            part.* = .{ .tool_call = .{
                .id = try jsonString(part_object, "tool_call_id"),
                .name = try jsonString(part_object, "tool_name"),
                .arguments_json = try jsonString(part_object, "args"),
                .thought_signature = try optionalJsonString(part_object, "thought_signature"),
            } };
        } else if (std.mem.eql(u8, kind, "file")) {
            const content_object = try jsonObject(part_object, "content");
            const content_kind = try jsonString(content_object, "kind");
            const content = try parseContent(allocator, content_object);
            if (std.mem.eql(u8, content_kind, "image")) part.* = .{ .image = content } else if (std.mem.eql(u8, content_kind, "audio")) part.* = .{ .audio = content } else if (std.mem.eql(u8, content_kind, "document")) part.* = .{ .document = content } else if (std.mem.eql(u8, content_kind, "binary")) part.* = .{ .binary = content } else return Error.InvalidHistory;
        } else return Error.InvalidHistory;
    }
    return .{
        .parts = parts,
        .usage = try parseUsage(object.get("usage")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .provider_name = try optionalJsonString(object, "provider_name"),
        .provider_url = try optionalJsonString(object, "provider_url"),
        .provider_details_json = try optionalJsonValue(allocator, object, "provider_details"),
        .provider_response_id = try optionalJsonString(object, "provider_response_id"),
        .model_name = try optionalJsonString(object, "model_name"),
        .finish_reason = try parseFinishReason(object.get("finish_reason")),
        .run_id = try optionalJsonString(object, "run_id"),
        .conversation_id = try optionalJsonString(object, "conversation_id"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    };
}

fn parseV1(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const model.Message {
    const messages = try allocator.alloc(model.Message, values.len);
    for (values, messages) |value, *message| {
        const object = try asObject(value);
        const role = try jsonString(object, "role");
        const parts = try jsonArray(object, "parts");
        const metadata = try parseMetadata(allocator, object.get("metadata"));
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "user") or
            std.mem.eql(u8, role, "tool"))
        {
            const request_parts = try allocator.alloc(model.RequestPart, parts.len);
            for (parts, request_parts) |part_value, *part| {
                const part_object = try asObject(part_value);
                const part_kind = try jsonString(part_object, "type");
                if (std.mem.eql(u8, role, "system") and std.mem.eql(u8, part_kind, "text")) {
                    part.* = .{ .system_prompt = try jsonString(part_object, "text") };
                } else if (std.mem.eql(u8, role, "user")) {
                    part.* = .{ .user_prompt = try parseV1UserContent(allocator, part_object, part_kind) };
                } else if (std.mem.eql(u8, role, "tool") and std.mem.eql(u8, part_kind, "tool_result")) {
                    part.* = .{ .tool_return = .{
                        .call_id = try jsonString(part_object, "call_id"),
                        .name = try jsonString(part_object, "name"),
                        .content = try jsonString(part_object, "content"),
                        .is_error = try optionalJsonBool(part_object, "is_error") orelse false,
                    } };
                } else return Error.InvalidHistory;
            }
            message.* = .{ .request = .{ .parts = request_parts, .metadata = metadata } };
        } else if (std.mem.eql(u8, role, "assistant")) {
            const response_parts = try allocator.alloc(model.ResponsePart, parts.len);
            for (parts, response_parts) |part_value, *part| {
                const part_object = try asObject(part_value);
                const part_kind = try jsonString(part_object, "type");
                part.* = try parseV1ResponsePart(allocator, part_object, part_kind);
            }
            message.* = .{ .response = .{ .parts = response_parts, .metadata = metadata } };
        } else return Error.InvalidHistory;
    }
    return messages;
}

fn parseUserContent(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model.UserContent {
    const kind = try jsonString(object, "kind");
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try jsonString(object, "content") };
    const content = try parseContent(allocator, object);
    if (std.mem.eql(u8, kind, "image")) return .{ .image = content };
    if (std.mem.eql(u8, kind, "audio")) return .{ .audio = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseV1UserContent(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: []const u8,
) !model.UserContent {
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try jsonString(object, "text") };
    const content = try parseContent(allocator, object);
    if (std.mem.eql(u8, kind, "image")) return .{ .image = content };
    if (std.mem.eql(u8, kind, "audio")) return .{ .audio = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseV1ResponsePart(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: []const u8,
) !model.ResponsePart {
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try jsonString(object, "text") };
    if (std.mem.eql(u8, kind, "thinking")) return .{ .thinking = .{
        .content = try jsonString(object, "content"),
        .signature = try optionalJsonString(object, "signature"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    } };
    if (std.mem.eql(u8, kind, "tool_call")) return .{ .tool_call = .{
        .id = try jsonString(object, "id"),
        .name = try jsonString(object, "name"),
        .arguments_json = try jsonString(object, "arguments_json"),
        .thought_signature = try optionalJsonString(object, "thought_signature"),
    } };
    const content = try parseContent(allocator, object);
    if (std.mem.eql(u8, kind, "image")) return .{ .image = content };
    if (std.mem.eql(u8, kind, "audio")) return .{ .audio = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseToolReturn(object: std.json.ObjectMap) !model.ToolResult {
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .name = try jsonString(object, "tool_name"),
        .content = try jsonString(object, "content"),
        .is_error = try optionalJsonBool(object, "is_error") orelse false,
    };
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

fn parseUsage(value: ?std.json.Value) !model.Usage {
    const object = try asObject(value orelse return .{});
    return .{
        .input_tokens = @intCast(try jsonInteger(object, "input_tokens")),
        .output_tokens = @intCast(try jsonInteger(object, "output_tokens")),
    };
}

fn parseFinishReason(value: ?std.json.Value) !?model.FinishReason {
    const object = try asObject(value orelse return null);
    const kind_name = try jsonString(object, "kind");
    return .{
        .kind = std.meta.stringToEnum(model.FinishReason.Kind, kind_name) orelse return Error.InvalidHistory,
        .raw = try jsonString(object, "raw"),
    };
}

fn optionalJsonValue(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return null;
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return encoded;
}

fn parseMetadata(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const model.Metadata {
    const values = switch (value orelse return &.{}) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    };
    const metadata = try allocator.alloc(model.Metadata, values.len);
    for (values, metadata) |item, *result| {
        const object = try asObject(item);
        result.* = .{ .key = try jsonString(object, "key"), .value = try jsonString(object, "value") };
    }
    return metadata;
}

/// Keeps system-prompt requests plus the newest `max_messages` other messages.
pub fn trim(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    max_messages: usize,
) ![]const model.Message {
    var ordinary: usize = 0;
    for (messages) |message| if (!isSystemRequest(message)) {
        ordinary += 1;
    };
    const skip = ordinary -| max_messages;
    var seen: usize = 0;
    var retained: std.ArrayList(model.Message) = .empty;
    for (messages) |message| {
        if (isSystemRequest(message)) {
            try retained.append(allocator, message);
        } else {
            if (seen >= skip) try retained.append(allocator, message);
            seen += 1;
        }
    }
    return providerValid(allocator, retained.items);
}

/// Merges adjacent text-only messages of the same request/response kind.
pub fn compact(allocator: std.mem.Allocator, messages: []const model.Message) ![]const model.Message {
    var result: std.ArrayList(model.Message) = .empty;
    for (messages) |message| {
        if (messagePartsLen(message) == 0) continue;
        if (result.items.len > 0) {
            const previous = result.items[result.items.len - 1];
            if (try compactPair(allocator, previous, message)) |joined| {
                result.items[result.items.len - 1] = joined;
                continue;
            }
        }
        try result.append(allocator, message);
    }
    return result.toOwnedSlice(allocator);
}

fn compactPair(allocator: std.mem.Allocator, left: model.Message, right: model.Message) !?model.Message {
    return switch (left) {
        .request => |left_request| switch (right) {
            .request => |right_request| if (requestText(left_request)) |left_text| blk: {
                const right_text = requestText(right_request) orelse break :blk null;
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ left_text, right_text });
                const parts = try allocator.alloc(model.RequestPart, 1);
                parts[0] = .{ .user_prompt = .{ .text = joined } };
                break :blk .{ .request = .{ .parts = parts } };
            } else null,
            .response => null,
        },
        .response => |left_response| switch (right) {
            .response => |right_response| if (responseText(left_response)) |left_text| blk: {
                const right_text = responseText(right_response) orelse break :blk null;
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ left_text, right_text });
                const parts = try allocator.alloc(model.ResponsePart, 1);
                parts[0] = .{ .text = joined };
                break :blk .{ .response = .{ .parts = parts } };
            } else null,
            .request => null,
        },
    };
}

/// Removes malformed and orphaned tool traffic and repairs tool-return names.
pub fn providerValid(allocator: std.mem.Allocator, messages: []const model.Message) ![]const model.Message {
    var cleaned: std.ArrayList(model.Message) = .empty;
    for (messages) |message| switch (message) {
        .request => |request| if (request.parts.len > 0) try cleaned.append(allocator, message),
        .response => |response| {
            var parts: std.ArrayList(model.ResponsePart) = .empty;
            for (response.parts) |part| switch (part) {
                .tool_call => |call| if (try validJson(allocator, call.arguments_json)) {
                    try parts.append(allocator, part);
                },
                else => try parts.append(allocator, part),
            };
            if (parts.items.len > 0) {
                var copy = response;
                copy.parts = try parts.toOwnedSlice(allocator);
                try cleaned.append(allocator, .{ .response = copy });
            }
        },
    };

    var result: std.ArrayList(model.Message) = .empty;
    for (cleaned.items, 0..) |message, index| switch (message) {
        .request => |request| {
            const previous = lastResponse(result.items);
            var parts: std.ArrayList(model.RequestPart) = .empty;
            for (request.parts) |part| switch (part) {
                .tool_return => |tool_return| if (previous) |response| {
                    if (findCall(response.parts, tool_return.call_id)) |call| {
                        var repaired = tool_return;
                        repaired.name = call.name;
                        try parts.append(allocator, .{ .tool_return = repaired });
                    }
                },
                else => try parts.append(allocator, part),
            };
            if (parts.items.len > 0) {
                var copy = request;
                copy.parts = try parts.toOwnedSlice(allocator);
                try result.append(allocator, .{ .request = copy });
            }
        },
        .response => |response| {
            var parts: std.ArrayList(model.ResponsePart) = .empty;
            for (response.parts) |part| switch (part) {
                .tool_call => |call| if (hasFutureReturn(cleaned.items[index + 1 ..], call.id)) {
                    try parts.append(allocator, part);
                },
                else => try parts.append(allocator, part),
            };
            if (parts.items.len > 0) {
                var copy = response;
                copy.parts = try parts.toOwnedSlice(allocator);
                try result.append(allocator, .{ .response = copy });
            }
        },
    };
    return result.toOwnedSlice(allocator);
}

fn summarize(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    options: Processor.Summarize,
    control: model.RunControl,
) ![]const model.Message {
    var ordinary: usize = 0;
    for (messages) |message| {
        if (!isSystemRequest(message)) ordinary += 1;
    }
    if (ordinary <= options.keep_recent_messages) return messages;
    const older_count = ordinary - options.keep_recent_messages;
    var older: std.ArrayList(model.Message) = .empty;
    var retained: std.ArrayList(model.Message) = .empty;
    var seen: usize = 0;
    for (messages) |message| {
        if (isSystemRequest(message)) {
            try retained.append(allocator, message);
        } else if (seen < older_count) {
            try older.append(allocator, message);
            seen += 1;
        } else try retained.append(allocator, message);
    }
    const summary = try control.invoke(
        []const u8,
        invokeSummarizer,
        .{ options, allocator, older.items },
    );
    const summary_parts = try allocator.alloc(model.RequestPart, 1);
    summary_parts[0] = .{ .user_prompt = .{ .text = summary } };
    var with_summary: std.ArrayList(model.Message) = .empty;
    var inserted = false;
    for (retained.items) |message| {
        if (!inserted and !isSystemRequest(message)) {
            try with_summary.append(allocator, .{ .request = .{ .parts = summary_parts } });
            inserted = true;
        }
        try with_summary.append(allocator, message);
    }
    if (!inserted) try with_summary.append(allocator, .{ .request = .{ .parts = summary_parts } });
    return providerValid(allocator, try compact(allocator, with_summary.items));
}

fn invokeSummarizer(
    options: Processor.Summarize,
    allocator: std.mem.Allocator,
    messages: []const model.Message,
) ![]const u8 {
    return options.summarizeFn(options.context, allocator, messages);
}

fn isSystemRequest(message: model.Message) bool {
    return switch (message) {
        .response => false,
        .request => |request| blk: {
            if (request.parts.len == 0) break :blk false;
            for (request.parts) |part| if (part != .system_prompt) break :blk false;
            break :blk true;
        },
    };
}

fn messagePartsLen(message: model.Message) usize {
    return switch (message) {
        .request => |request| request.parts.len,
        .response => |response| response.parts.len,
    };
}

fn requestText(request: model.RequestMessage) ?[]const u8 {
    if (request.metadata.len > 0 or request.parts.len != 1) return null;
    return switch (request.parts[0]) {
        .user_prompt => |content| switch (content) {
            .text => |text| text,
            else => null,
        },
        else => null,
    };
}

fn responseText(response: model.ResponseMessage) ?[]const u8 {
    if (response.metadata.len > 0 or response.parts.len != 1) return null;
    return switch (response.parts[0]) {
        .text => |text| text,
        else => null,
    };
}

fn lastResponse(messages: []const model.Message) ?model.ResponseMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .response => |response| return response,
            .request => {},
        }
    }
    return null;
}

fn hasFutureReturn(messages: []const model.Message, id: []const u8) bool {
    for (messages) |message| switch (message) {
        .response => return false,
        .request => |request| for (request.parts) |part| switch (part) {
            .tool_return => |result| if (std.mem.eql(u8, result.call_id, id)) return true,
            else => {},
        },
    };
    return false;
}

fn findCall(parts: []const model.ResponsePart, id: []const u8) ?model.ToolCall {
    for (parts) |part| switch (part) {
        .tool_call => |call| if (std.mem.eql(u8, call.id, id)) return call,
        else => {},
    };
    return null;
}

fn validJson(allocator: std.mem.Allocator, source: []const u8) !bool {
    return json_limits.isValid(allocator, source, json_limits.defaults.history);
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => Error.InvalidHistory,
    };
}

fn jsonObject(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return asObject(object.get(name) orelse return Error.InvalidHistory);
}

fn jsonArray(object: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .array => |array| array.items,
        else => Error.InvalidHistory,
    };
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

fn jsonInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .integer => |integer| integer,
        else => Error.InvalidHistory,
    };
}

fn optionalJsonInteger(object: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => Error.InvalidHistory,
    };
}

fn optionalJsonBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => Error.InvalidHistory,
    };
}

test "history version 2 round trips request response parts and provenance" {
    const messages = [_]model.Message{
        .{ .request = .{
            .parts = &.{
                .{ .system_prompt = "rules" },
                .{ .user_prompt = .{ .text = "hello" } },
                .{ .user_prompt = .{ .image = .{
                    .source = .{ .bytes = "png" },
                    .media_type = "image/png",
                    .filename = "image.png",
                    .thought_signature = "image-signature",
                    .metadata = &.{.{ .key = "source", .value = "camera" }},
                } } },
                .{ .user_prompt = .{ .audio = .{
                    .source = .{ .url = "https://example.com/audio.mp3" },
                    .media_type = "audio/mpeg",
                } } },
                .{ .user_prompt = .{ .document = .{
                    .source = .{ .provider_file = .{ .id = "doc", .provider = "openai" } },
                    .media_type = "application/pdf",
                } } },
                .{ .user_prompt = .{ .binary = .{
                    .source = .{ .bytes = "data" },
                    .media_type = "application/octet-stream",
                } } },
                .{ .retry_prompt = "try again" },
                .{ .tool_return = .{ .call_id = "call", .name = "lookup", .content = "ok", .is_error = true } },
            },
            .timestamp_unix_ms = 10,
            .instructions = "be concise",
            .run_id = "run",
            .conversation_id = "conversation",
            .metadata = &.{.{ .key = "tenant", .value = "one" }},
            .state = .interrupted,
        } },
        .{ .response = .{
            .parts = &.{
                .{ .text = "answer" },
                .{ .thinking = .{ .content = "private", .signature = "signed" } },
                .{ .tool_call = .{ .id = "call", .name = "lookup", .arguments_json = "{}" } },
                .{ .image = .{
                    .source = .{ .bytes = "png" },
                    .media_type = "image/png",
                } },
                .{ .audio = .{
                    .source = .{ .url = "https://example.com/answer.mp3" },
                    .media_type = "audio/mpeg",
                } },
                .{ .document = .{
                    .source = .{ .provider_file = .{ .id = "file", .provider = "openai" } },
                    .media_type = "application/pdf",
                } },
                .{ .binary = .{
                    .source = .{ .bytes = "data" },
                    .media_type = "application/octet-stream",
                } },
            },
            .usage = .{ .input_tokens = 3, .output_tokens = 2 },
            .timestamp_unix_ms = 20,
            .provider_name = "openai",
            .provider_url = "https://api.openai.com/v1",
            .provider_details_json = "{\"cached\":true}",
            .provider_response_id = "response",
            .model_name = "gpt",
            .finish_reason = .{ .kind = .tool_calls, .raw = "tool_calls" },
            .run_id = "run",
            .conversation_id = "conversation",
            .metadata = &.{.{ .key = "trace", .value = "one" }},
        } },
    };
    const encoded = try stringify(std.testing.allocator, &messages);
    defer std.testing.allocator.free(encoded);
    var decoded = try parse(std.testing.allocator, encoded);
    defer decoded.deinit();

    const request = decoded.messages[0].request;
    try std.testing.expectEqual(@as(usize, 8), request.parts.len);
    try std.testing.expectEqualStrings("hello", request.parts[1].user_prompt.text);
    try std.testing.expectEqual(model.RequestState.interrupted, request.state);
    const response = decoded.messages[1].response;
    try std.testing.expectEqualStrings("answer", response.parts[0].text);
    try std.testing.expectEqualStrings("{\"cached\":true}", response.provider_details_json.?);
    try std.testing.expectEqual(@as(u64, 5), response.usage.totalTokens());
    try std.testing.expectEqual(model.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "history version 1 migrates role messages" {
    var decoded = try parse(
        std.testing.allocator,
        "{\"version\":1,\"messages\":[" ++
            "{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]}," ++
            "{\"role\":\"assistant\",\"parts\":[{\"type\":\"tool_call\",\"id\":\"call\",\"name\":\"lookup\",\"arguments_json\":\"{}\"}]}," ++
            "{\"role\":\"tool\",\"parts\":[{\"type\":\"tool_result\",\"call_id\":\"call\",\"name\":\"lookup\",\"content\":\"ok\",\"is_error\":false}]}]}",
    );
    defer decoded.deinit();
    try std.testing.expectEqualStrings("hello", decoded.messages[0].request.parts[0].user_prompt.text);
    try std.testing.expectEqualStrings("call", decoded.messages[1].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("ok", decoded.messages[2].request.parts[0].tool_return.content);
}

test "history version 1 migrates every rich part" {
    var decoded = try parse(
        std.testing.allocator,
        "{\"version\":1,\"messages\":[" ++
            "{\"role\":\"system\",\"parts\":[{\"type\":\"text\",\"text\":\"rules\"}]}," ++
            "{\"role\":\"user\",\"metadata\":[{\"key\":\"tenant\",\"value\":\"one\"}],\"parts\":[" ++
            "{\"type\":\"image\",\"source\":\"bytes\",\"data\":\"cG5n\",\"media_type\":\"image/png\"}," ++
            "{\"type\":\"audio\",\"source\":\"url\",\"url\":\"https://example.com/a.mp3\",\"media_type\":\"audio/mpeg\"}," ++
            "{\"type\":\"document\",\"source\":\"provider_file\",\"file_id\":\"doc\",\"provider\":\"openai\",\"media_type\":\"application/pdf\"}," ++
            "{\"type\":\"binary\",\"source\":\"bytes\",\"data\":\"eA==\",\"media_type\":\"application/octet-stream\"}]}," ++
            "{\"role\":\"assistant\",\"parts\":[" ++
            "{\"type\":\"text\",\"text\":\"answer\"}," ++
            "{\"type\":\"thinking\",\"content\":\"thought\",\"signature\":\"sig\",\"metadata\":[{\"key\":\"safe\",\"value\":\"yes\"}]}," ++
            "{\"type\":\"tool_call\",\"id\":\"call\",\"name\":\"lookup\",\"arguments_json\":\"{}\",\"thought_signature\":\"tool-sig\"}," ++
            "{\"type\":\"image\",\"source\":\"url\",\"url\":\"https://example.com/i.png\",\"media_type\":\"image/png\"}," ++
            "{\"type\":\"audio\",\"source\":\"bytes\",\"data\":\"YQ==\",\"media_type\":\"audio/mpeg\"}," ++
            "{\"type\":\"document\",\"source\":\"provider_file\",\"file_id\":\"answer\",\"media_type\":\"application/pdf\"}," ++
            "{\"type\":\"binary\",\"source\":\"bytes\",\"data\":\"Yg==\",\"media_type\":\"application/octet-stream\"}]}]}",
    );
    defer decoded.deinit();

    try std.testing.expectEqualStrings("rules", decoded.messages[0].request.parts[0].system_prompt);
    try std.testing.expectEqual(@as(usize, 4), decoded.messages[1].request.parts.len);
    try std.testing.expectEqualStrings("png", decoded.messages[1].request.parts[0].user_prompt.image.source.bytes);
    try std.testing.expectEqualStrings("thought", decoded.messages[2].response.parts[1].thinking.content);
    try std.testing.expectEqualStrings("tool-sig", decoded.messages[2].response.parts[2].tool_call.thought_signature.?);
    try std.testing.expectEqual(@as(usize, 7), decoded.messages[2].response.parts.len);
}

fn summarizeForTest(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const model.Message,
) ![]const u8 {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += messages.len;
    return allocator.dupe(u8, "summary");
}

fn customForTest(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    run: Context,
    messages: []const model.Message,
) ![]const model.Message {
    const requests: *usize = @ptrCast(@alignCast(context));
    requests.* = run.model_requests;
    return allocator.dupe(model.Message, messages);
}

test "history processors preserve system requests and repair tool traffic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]model.Message{
        .{ .request = .{ .parts = &.{.{ .system_prompt = "rules" }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "one" } }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "two" } }} } },
        .{ .response = .{ .parts = &.{
            .{ .tool_call = .{ .id = "bad", .name = "bad", .arguments_json = "{" } },
            .{ .tool_call = .{ .id = "call", .name = "lookup", .arguments_json = "{}" } },
        } } },
        .{ .request = .{ .parts = &.{
            .{ .tool_return = .{
                .call_id = "call",
                .name = "stale",
                .content = "ok",
            } },
            .{ .tool_return = .{
                .call_id = "orphan",
                .name = "stale",
                .content = "ignored",
            } },
        } } },
        .{ .response = .{ .parts = &.{.{ .text = "done" }} } },
    };
    const compacted = try compact(arena.allocator(), &messages);
    try std.testing.expectEqualStrings("one\ntwo", compacted[1].request.parts[0].user_prompt.text);
    const valid = try providerValid(arena.allocator(), &messages);
    try std.testing.expectEqualStrings("lookup", valid[4].request.parts[0].tool_return.name);
    const trimmed = try trim(arena.allocator(), &messages, 3);
    try std.testing.expectEqualStrings("rules", trimmed[0].request.parts[0].system_prompt);

    const response_messages = [_]model.Message{
        .{ .response = .{ .parts = &.{.{ .text = "one" }} } },
        .{ .response = .{ .parts = &.{.{ .text = "two" }} } },
    };
    const compacted_responses = try compact(arena.allocator(), &response_messages);
    try std.testing.expectEqualStrings("one\ntwo", compacted_responses[0].response.parts[0].text);

    var summarized_count: usize = 0;
    const summarized = try (Processor{ .summarize = .{
        .context = &summarized_count,
        .keep_recent_messages = 2,
        .summarizeFn = summarizeForTest,
    } }).process(arena.allocator(), .{ .profile = .{}, .usage = .{}, .model_requests = 0 }, &messages);
    try std.testing.expect(summarized_count > 0);
    try std.testing.expectEqualStrings("summary", summarized[1].request.parts[0].user_prompt.text);

    var observed_requests: usize = 0;
    const context: Context = .{ .profile = .{}, .usage = .{}, .model_requests = 7 };
    const processors = [_]Processor{
        .{ .trim = .{ .max_messages = messages.len } },
        .compact,
        .provider_valid,
        .{ .custom = .{ .context = &observed_requests, .processFn = customForTest } },
    };
    _ = try processAll(arena.allocator(), &processors, context, &messages);
    try std.testing.expectEqual(@as(usize, 7), observed_requests);

    const orphaned = [_]model.Message{
        .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "orphan", .name = "tool", .content = "x" } }} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{ .id = "missing", .name = "tool", .arguments_json = "{}" } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "different", .name = "tool", .content = "x" } }} } },
        .{ .response = .{ .parts = &.{.{ .text = "boundary" }} } },
        .{ .request = .{ .parts = &.{} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{ .id = "last", .name = "tool", .arguments_json = "{}" } }} } },
    };
    const without_orphans = try providerValid(arena.allocator(), &orphaned);
    try std.testing.expectEqual(@as(usize, 1), without_orphans.len);
    try std.testing.expectEqualStrings("boundary", without_orphans[0].response.parts[0].text);
}

test "history rejects malformed documents and invalid raw provider JSON" {
    try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.UnsupportedVersion, parse(std.testing.allocator, "{\"version\":3,\"messages\":[]}"));
    try std.testing.expectError(Error.InvalidHistory, stringify(std.testing.allocator, &.{.{ .response = .{
        .parts = &.{.{ .text = "x" }},
        .provider_details_json = "{",
    } }}));

    const malformed = [_][]const u8{
        "{",
        "[]",
        "{\"version\":\"2\",\"messages\":[]}",
        "{\"version\":2,\"messages\":{}}",
        "{\"version\":2,\"messages\":[{\"kind\":\"other\",\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"other\"}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"state\":\"other\",\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"user-prompt\",\"content\":{\"kind\":\"other\",\"source\":\"url\",\"url\":\"x\",\"media_type\":\"x\"}}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"file\",\"content\":{\"kind\":\"other\",\"source\":\"url\",\"url\":\"x\",\"media_type\":\"x\"}}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"finish_reason\":{\"kind\":\"bogus\",\"raw\":\"x\"},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"metadata\":{},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"timestamp_unix_ms\":\"now\",\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"provider_name\":1,\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":\"one\",\"output_tokens\":0},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":\"wrong\"}]}",
        "{\"version\":2,\"messages\":[{\"kind\":1,\"parts\":[]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"other\",\"parts\":[]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"user\",\"parts\":[{\"type\":\"other\",\"source\":\"url\",\"url\":\"x\",\"media_type\":\"x\"}]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"assistant\",\"parts\":[{\"type\":\"other\",\"source\":\"url\",\"url\":\"x\",\"media_type\":\"x\"}]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"tool\",\"parts\":[{\"type\":\"text\",\"text\":\"wrong\"}]}]}",
        "{\"version\":1,\"messages\":[{\"role\":\"tool\",\"parts\":[{\"type\":\"tool_result\",\"call_id\":\"x\",\"name\":\"x\",\"content\":\"x\",\"is_error\":\"yes\"}]}]}",
    };
    for (malformed) |document| {
        try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, document));
    }
}

test "history rejects documents beyond its JSON nesting limit" {
    const source = "[" ** 65 ++ "0" ++ "]" ** 65;
    try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, source));
}

fn checkParseAllocationFailure(allocator: std.mem.Allocator) !void {
    var owned = try parse(
        allocator,
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[" ++
            "{\"part_kind\":\"user-prompt\",\"content\":{\"kind\":\"text\",\"content\":\"hello\"}}," ++
            "{\"part_kind\":\"user-prompt\",\"content\":{\"kind\":\"binary\",\"source\":\"bytes\",\"data\":\"ZGF0YQ==\",\"media_type\":\"application/octet-stream\"}}]}]}",
    );
    defer owned.deinit();
}

fn checkProviderValidAllocationFailure(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try providerValid(arena.allocator(), &.{
        .{ .response = .{ .parts = &.{.{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}" } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "call", .name = "tool", .content = "ok" } }} } },
    });
}

fn checkStringifyAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = stringify(allocator, &.{.{ .response = .{
        .parts = &.{.{ .binary = .{
            .source = .{ .bytes = "data" },
            .media_type = "application/octet-stream",
        } }},
        .provider_details_json = "{\"cached\":true}",
    } }}) catch |failure| switch (failure) {
        error.WriteFailed => return error.OutOfMemory,
        else => return failure,
    };
    allocator.free(encoded);
}

test "history allocation failures clean up owned state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParseAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkStringifyAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkProviderValidAllocationFailure, .{});
}
