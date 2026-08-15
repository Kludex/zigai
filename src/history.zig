//! Lossless serialization and provider-facing processing for reusable agent history.
//!
//! Version 2 stores distinct request and response message_types. The parser also
//! accepts version 1 role-based histories and migrates them into the new model.

const std = @import("std");
const model = @import("model.zig");
const message_types = @import("messages.zig");
const usage_types = @import("usage.zig");
const json_limits = @import("json.zig");

pub const Error = error{
    /// History JSON or a provider-facing message sequence is invalid.
    InvalidHistory,
    /// The serialized history version is not supported.
    UnsupportedVersion,
};

/// An owned history parsed from ZigAI's versioned JSON representation.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const message_types.Message,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Runtime state supplied to history processors before a model request.
pub const Context = struct {
    profile: model.ModelProfile,
    usage: usage_types.RunUsage,
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
            messages: []const message_types.Message,
        ) anyerror![]const u8,
    };

    pub const Custom = struct {
        context: *anyopaque,
        processFn: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run: Context,
            messages: []const message_types.Message,
        ) anyerror![]const message_types.Message,
    };

    pub fn process(
        self: Processor,
        allocator: std.mem.Allocator,
        context: Context,
        messages: []const message_types.Message,
    ) ![]const message_types.Message {
        return switch (self) {
            .trim => |options| trim(allocator, messages, options.max_messages),
            .compact => compact(allocator, messages),
            .provider_valid => providerValid(allocator, messages),
            .summarize => |options| summarize(allocator, messages, options, context.control),
            .custom => |custom| context.control.invoke(
                []const message_types.Message,
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
    messages: []const message_types.Message,
) ![]const message_types.Message {
    return custom.processFn(custom.context, allocator, context, messages);
}

/// Applies processors from left to right.
pub fn processAll(
    allocator: std.mem.Allocator,
    processors: []const Processor,
    context: Context,
    messages: []const message_types.Message,
) ![]const message_types.Message {
    var current = messages;
    for (processors) |processor| current = try processor.process(allocator, context, current);
    return current;
}

/// Encodes messages using ZigAI history JSON version 2.
pub fn stringify(allocator: std.mem.Allocator, messages: []const message_types.Message) ![]u8 {
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

fn writeRequest(allocator: std.mem.Allocator, json: *std.json.Stringify, request: message_types.RequestMessage) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write("request");
    try json.objectField("parts");
    try json.beginArray();
    for (request.parts) |part| {
        try json.beginObject();
        switch (part) {
            .system_prompt => |content| try writeTextPart(json, "system-prompt", content),
            .system_prompt_part => |prompt| {
                try writeTextPart(json, "system-prompt", prompt.content);
                try writeOptionalInteger(json, "timestamp_unix_ms", prompt.timestamp_unix_ms);
                try writeOptionalString(json, "dynamic_ref", prompt.dynamic_ref);
            },
            .user_prompt => |content| {
                try json.objectField("part_kind");
                try json.write("user-prompt");
                try json.objectField("content");
                try writeUserContent(allocator, json, content);
            },
            .user_prompt_part => |prompt| {
                try json.objectField("part_kind");
                try json.write("user-prompt");
                try json.objectField("content");
                try writeUserContent(allocator, json, prompt.content);
                try writeOptionalInteger(json, "timestamp_unix_ms", prompt.timestamp_unix_ms);
            },
            .speech => |speech| try writeSpeech(allocator, json, speech),
            .tool_search_return => |result| try writeToolSearchResult(allocator, json, result, false),
            .capability_load_return => |result| try writeCapabilityLoadResult(json, result),
            .tool_return => |result| {
                try json.objectField("part_kind");
                try json.write("tool-return");
                try writeToolReturn(allocator, json, result);
            },
            .retry_prompt => |content| try writeTextPart(json, "retry-prompt", content),
            .retry_prompt_part => |prompt| {
                try writeTextPart(json, "retry-prompt", prompt.content);
                try writeOptionalString(json, "tool_name", prompt.tool_name);
                try writeOptionalString(json, "tool_call_id", prompt.tool_call_id);
                try writeOptionalInteger(json, "timestamp_unix_ms", prompt.timestamp_unix_ms);
            },
            .tool_availability_delta => |delta| {
                try json.objectField("part_kind");
                try json.write("tool-availability-delta");
                try json.objectField("tools_added");
                try json.write(delta.tools_added);
                try writeOptionalString(json, "tool_call_id", delta.tool_call_id);
            },
        }
        try json.endObject();
    }
    try json.endArray();
    try writeOptionalInteger(json, "timestamp_unix_ms", request.timestamp_unix_ms);
    if (request.instruction_parts.len > 0) {
        try json.objectField("instruction_parts");
        try json.write(request.instruction_parts);
    }
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

fn writeResponse(allocator: std.mem.Allocator, json: *std.json.Stringify, response: message_types.ResponseMessage) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write("response");
    try json.objectField("parts");
    try json.beginArray();
    for (response.parts) |part| {
        try json.beginObject();
        switch (part) {
            .text => |content| try writeTextPart(json, "text", content),
            .text_part => |text| {
                try writeTextPart(json, "text", text.content);
                try writeProviderPart(allocator, json, text.provider);
            },
            .tool_search_call => |call| try writeToolSearchCall(allocator, json, call, false),
            .capability_load_call => |call| try writeCapabilityLoadCall(json, call),
            .image => |content| try writeResponseContent(allocator, json, "image", content),
            .audio => |content| try writeResponseContent(allocator, json, "audio", content),
            .video => |content| try writeResponseContent(allocator, json, "video", content),
            .document => |content| try writeResponseContent(allocator, json, "document", content),
            .binary => |content| try writeResponseContent(allocator, json, "binary", content),
            .thinking => |thinking| {
                try json.objectField("part_kind");
                try json.write("thinking");
                try json.objectField("content");
                try json.write(thinking.content);
                try writeOptionalString(json, "signature", thinking.signature);
                try writeProviderPart(allocator, json, thinking.provider);
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
                try writeOptionalToolKind(json, call.tool_kind);
                try writeProviderPart(allocator, json, call.provider);
                try writeOptionalString(json, "thought_signature", call.thought_signature);
            },
            .native_tool_search_call => |call| try writeToolSearchCall(allocator, json, call, true),
            .native_tool_call => |call| {
                try json.objectField("part_kind");
                try json.write("builtin-tool-call");
                try writeNativeToolCall(allocator, json, call);
            },
            .native_tool_search_return => |result| try writeToolSearchResult(allocator, json, result, true),
            .native_tool_return => |result| try writeNativeToolResult(allocator, json, result),
            .compaction => |part_value| {
                try json.objectField("part_kind");
                try json.write("compaction");
                try writeOptionalString(json, "content", part_value.content);
                try writeProviderPart(allocator, json, part_value.provider);
            },
            .speech => |speech| try writeSpeech(allocator, json, speech),
        }
        try json.endObject();
    }
    try json.endArray();
    if (response.usage.hasValues()) {
        try json.objectField("usage");
        try json.write(response.usage);
    }
    try writeOptionalInteger(json, "timestamp_unix_ms", response.timestamp_unix_ms);
    try writeOptionalString(json, "provider_name", response.provider_name);
    try writeOptionalString(json, "provider_url", response.provider_url);
    try writeOptionalProviderDetails(json, "provider_details", response.provider_details);
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
    if (response.state != .complete) {
        try json.objectField("state");
        try json.write(@tagName(response.state));
    }
    try json.endObject();
}

fn writeTextPart(json: *std.json.Stringify, kind: []const u8, content: []const u8) !void {
    try json.objectField("part_kind");
    try json.write(kind);
    try json.objectField("content");
    try json.write(content);
}

fn writeToolReturn(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    result: message_types.ToolResult,
) !void {
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("tool_name");
    try json.write(result.name);
    try json.objectField("content");
    try json.write(result.content);
    if (result.files.len > 0) {
        try json.objectField("files");
        try writeContents(allocator, json, result.files);
    }
    try writeOptionalToolKind(json, result.tool_kind);
    try writeMetadata(json, result.metadata);
    try writeOptionalInteger(json, "timestamp_unix_ms", result.timestamp_unix_ms);
    try json.objectField("outcome");
    try json.write(@tagName(result.effectiveOutcome()));
}

fn writeUserContent(allocator: std.mem.Allocator, json: *std.json.Stringify, content: message_types.UserContent) !void {
    try json.beginObject();
    switch (content) {
        .text => |text| {
            try json.objectField("kind");
            try json.write("text");
            try json.objectField("content");
            try json.write(text);
        },
        .text_content => |text| {
            try json.objectField("kind");
            try json.write("text-content");
            try json.objectField("content");
            try json.write(text.content);
            try writeMetadata(json, text.metadata);
        },
        .image => |value| try writeContent(allocator, json, "image", value),
        .audio => |value| try writeContent(allocator, json, "audio", value),
        .video => |value| try writeContent(allocator, json, "video", value),
        .document => |value| try writeContent(allocator, json, "document", value),
        .binary => |value| try writeContent(allocator, json, "binary", value),
        .uploaded_file => |file| try writeUploadedFile(json, file),
        .cache_point => |point| {
            try json.objectField("kind");
            try json.write("cache-point");
            try json.objectField("ttl");
            try json.write(@tagName(point.ttl));
        },
    }
    try json.endObject();
}

fn writeResponseContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: []const u8,
    content: message_types.Content,
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
    content: message_types.Content,
) !void {
    try json.objectField("kind");
    try json.write(kind);
    try json.objectField("media_type");
    try json.write(content.media_type);
    try writeOptionalString(json, "filename", content.filename);
    try writeOptionalString(json, "identifier", content.identifier);
    try writeProviderPart(allocator, json, content.provider);
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
        .uploaded_file => |file| {
            try json.objectField("source");
            try json.write("uploaded_file");
            try json.objectField("uploaded_file");
            try json.beginObject();
            try writeUploadedFileFields(json, file);
            try json.endObject();
        },
    }
}

fn writeProviderPart(
    _: std.mem.Allocator,
    json: *std.json.Stringify,
    provider: message_types.ProviderPart,
) !void {
    if ((provider.id != null or provider.provider_details != null) and provider.provider_name == null)
        return Error.InvalidHistory;
    try writeOptionalString(json, "id", provider.id);
    try writeOptionalString(json, "provider_name", provider.provider_name);
    try writeOptionalProviderDetails(json, "provider_details", provider.provider_details);
}

fn writeOptionalToolKind(json: *std.json.Stringify, kind: ?message_types.ToolPartKind) !void {
    if (kind) |value| {
        try json.objectField("tool_kind");
        try json.write(@tagName(value));
    }
}

fn writeContents(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    contents: []const message_types.Content,
) !void {
    try json.beginArray();
    for (contents) |content| {
        try json.beginObject();
        try writeContent(allocator, json, contentKind(content.media_type), content);
        try json.endObject();
    }
    try json.endArray();
}

fn contentKind(media_type: []const u8) []const u8 {
    if (std.mem.startsWith(u8, media_type, "image/")) return "image";
    if (std.mem.startsWith(u8, media_type, "audio/")) return "audio";
    if (std.mem.startsWith(u8, media_type, "video/")) return "video";
    if (std.mem.startsWith(u8, media_type, "text/") or std.mem.eql(u8, media_type, "application/pdf"))
        return "document";
    return "binary";
}

fn writeUploadedFile(json: *std.json.Stringify, file: message_types.UploadedFile) !void {
    try json.objectField("kind");
    try json.write("uploaded-file");
    try writeUploadedFileFields(json, file);
}

fn writeUploadedFileFields(json: *std.json.Stringify, file: message_types.UploadedFile) !void {
    try json.objectField("file_id");
    try json.write(file.id);
    try json.objectField("provider_name");
    try json.write(file.provider_name);
    try writeOptionalString(json, "media_type", file.media_type);
    try writeMetadata(json, file.metadata);
}

fn writeSpeech(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    speech: message_types.SpeechPart,
) !void {
    try json.objectField("part_kind");
    try json.write("speech");
    try json.objectField("speaker");
    try json.write(@tagName(speech.speaker));
    try writeOptionalString(json, "transcript", speech.transcript);
    if (speech.audio) |audio| {
        try json.objectField("audio");
        try json.beginObject();
        try writeContent(allocator, json, "audio", audio);
        try json.endObject();
    }
    if (speech.interrupted_at_ms) |offset| {
        try json.objectField("interrupted_at_ms");
        try json.write(offset);
    }
    try writeProviderPart(allocator, json, speech.provider);
}

fn writeToolSearchCall(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    call: message_types.ToolSearchCall,
    native: bool,
) !void {
    try json.objectField("part_kind");
    try json.write(if (native) "builtin-tool-search-call" else "tool-search-call");
    try json.objectField("tool_call_id");
    try json.write(call.call_id);
    try json.objectField("queries");
    try json.write(call.queries);
    try writeProviderPart(allocator, json, call.provider);
}

fn writeToolSearchResult(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    result: message_types.ToolSearchResult,
    native: bool,
) !void {
    try json.objectField("part_kind");
    try json.write(if (native) "builtin-tool-search-return" else "tool-search-return");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("discovered_tools");
    try json.write(result.discovered_tools);
    try writeOptionalString(json, "message", result.message);
    try writeMetadata(json, result.metadata);
    try writeOptionalInteger(json, "timestamp_unix_ms", result.timestamp_unix_ms);
    try json.objectField("outcome");
    try json.write(@tagName(result.outcome));
    try writeProviderPart(allocator, json, result.provider);
}

fn writeCapabilityLoadCall(json: *std.json.Stringify, call: message_types.CapabilityLoadCall) !void {
    try json.objectField("part_kind");
    try json.write("capability-load-call");
    try json.objectField("tool_call_id");
    try json.write(call.call_id);
    try json.objectField("capability_id");
    try json.write(call.capability_id);
}

fn writeCapabilityLoadResult(json: *std.json.Stringify, result: message_types.CapabilityLoadResult) !void {
    try json.objectField("part_kind");
    try json.write("capability-load-return");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try writeOptionalString(json, "instructions", result.instructions);
    try writeMetadata(json, result.metadata);
    try writeOptionalInteger(json, "timestamp_unix_ms", result.timestamp_unix_ms);
    try json.objectField("outcome");
    try json.write(@tagName(result.outcome));
}

fn writeNativeToolCall(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    call: message_types.NativeToolCall,
) !void {
    try json.objectField("tool_call_id");
    try json.write(call.id);
    try json.objectField("tool_name");
    try json.write(call.name);
    try json.objectField("args");
    try json.write(call.arguments_json);
    try writeOptionalToolKind(json, call.tool_kind);
    try writeProviderPart(allocator, json, call.provider);
}

fn writeNativeToolResult(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    result: message_types.NativeToolResult,
) !void {
    try json.objectField("part_kind");
    try json.write("builtin-tool-return");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("tool_name");
    try json.write(result.name);
    try json.objectField("content");
    try json.write(result.content);
    if (result.files.len > 0) {
        try json.objectField("files");
        try writeContents(allocator, json, result.files);
    }
    try writeOptionalToolKind(json, result.tool_kind);
    try writeMetadata(json, result.metadata);
    try writeOptionalInteger(json, "timestamp_unix_ms", result.timestamp_unix_ms);
    try json.objectField("outcome");
    try json.write(@tagName(result.outcome));
    try writeProviderPart(allocator, json, result.provider);
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

fn writeOptionalProviderDetails(
    json: *std.json.Stringify,
    name: []const u8,
    details: ?message_types.ProviderDetails,
) !void {
    const value = details orelse return;
    if (value.value != .object) return Error.InvalidHistory;
    try json.objectField(name);
    try json.write(value);
}

fn writeMetadata(json: *std.json.Stringify, metadata: []const message_types.Metadata) !void {
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

fn parseV2(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const message_types.Message {
    const messages = try allocator.alloc(message_types.Message, values.len);
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

fn parseRequest(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.RequestMessage {
    const values = try jsonArray(object, "parts");
    const parts = try allocator.alloc(message_types.RequestPart, values.len);
    for (values, parts) |value, *part| {
        const part_object = try asObject(value);
        const kind = try jsonString(part_object, "part_kind");
        if (std.mem.eql(u8, kind, "system-prompt")) {
            const content = try jsonString(part_object, "content");
            const timestamp = try optionalJsonInteger(part_object, "timestamp_unix_ms");
            const dynamic_ref = try optionalJsonString(part_object, "dynamic_ref");
            part.* = if (timestamp != null or dynamic_ref != null)
                .{ .system_prompt_part = .{
                    .content = content,
                    .timestamp_unix_ms = timestamp,
                    .dynamic_ref = dynamic_ref,
                } }
            else
                .{ .system_prompt = content };
        } else if (std.mem.eql(u8, kind, "user-prompt")) {
            const content = try parseUserContent(allocator, try jsonObject(part_object, "content"));
            const timestamp = try optionalJsonInteger(part_object, "timestamp_unix_ms");
            part.* = if (timestamp) |value_timestamp|
                .{ .user_prompt_part = .{ .content = content, .timestamp_unix_ms = value_timestamp } }
            else
                .{ .user_prompt = content };
        } else if (std.mem.eql(u8, kind, "speech")) {
            const speech = try parseSpeech(allocator, part_object);
            if (speech.speaker != .user) return Error.InvalidHistory;
            part.* = .{ .speech = speech };
        } else if (std.mem.eql(u8, kind, "tool-search-return")) {
            part.* = .{ .tool_search_return = try parseToolSearchResult(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "capability-load-return")) {
            part.* = .{ .capability_load_return = try parseCapabilityLoadResult(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "tool-return")) {
            part.* = .{ .tool_return = try parseToolReturn(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "retry-prompt")) {
            const content = try jsonString(part_object, "content");
            const tool_name = try optionalJsonString(part_object, "tool_name");
            const tool_call_id = try optionalJsonString(part_object, "tool_call_id");
            const timestamp = try optionalJsonInteger(part_object, "timestamp_unix_ms");
            part.* = if (tool_name != null or tool_call_id != null or timestamp != null)
                .{ .retry_prompt_part = .{
                    .content = content,
                    .tool_name = tool_name,
                    .tool_call_id = tool_call_id,
                    .timestamp_unix_ms = timestamp,
                } }
            else
                .{ .retry_prompt = content };
        } else if (std.mem.eql(u8, kind, "tool-availability-delta")) {
            part.* = .{ .tool_availability_delta = .{
                .tools_added = try parseStrings(allocator, try jsonArray(part_object, "tools_added")),
                .tool_call_id = try optionalJsonString(part_object, "tool_call_id"),
            } };
        } else return Error.InvalidHistory;
    }
    const state_name = try optionalJsonString(object, "state");
    return .{
        .parts = parts,
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .instruction_parts = try parseInstructionParts(allocator, object.get("instruction_parts")),
        .instructions = try optionalJsonString(object, "instructions"),
        .run_id = try optionalJsonString(object, "run_id"),
        .conversation_id = try optionalJsonString(object, "conversation_id"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .state = if (state_name) |name|
            std.meta.stringToEnum(message_types.RequestState, name) orelse return Error.InvalidHistory
        else
            .complete,
    };
}

fn parseResponse(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.ResponseMessage {
    const values = try jsonArray(object, "parts");
    const parts = try allocator.alloc(message_types.ResponsePart, values.len);
    for (values, parts) |value, *part| {
        const part_object = try asObject(value);
        const kind = try jsonString(part_object, "part_kind");
        if (std.mem.eql(u8, kind, "text")) {
            const content = try jsonString(part_object, "content");
            const provider = try parseProviderPart(allocator, part_object);
            part.* = if (hasProviderPart(provider))
                .{ .text_part = .{ .content = content, .provider = provider } }
            else
                .{ .text = content };
        } else if (std.mem.eql(u8, kind, "tool-search-call")) {
            part.* = .{ .tool_search_call = try parseToolSearchCall(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "capability-load-call")) {
            part.* = .{ .capability_load_call = .{
                .call_id = try jsonString(part_object, "tool_call_id"),
                .capability_id = try jsonString(part_object, "capability_id"),
            } };
        } else if (std.mem.eql(u8, kind, "thinking")) {
            part.* = .{ .thinking = .{
                .content = try jsonString(part_object, "content"),
                .signature = try optionalJsonString(part_object, "signature"),
                .provider = try parseProviderPart(allocator, part_object),
                .metadata = try parseMetadata(allocator, part_object.get("metadata")),
            } };
        } else if (std.mem.eql(u8, kind, "tool-call")) {
            part.* = .{ .tool_call = .{
                .id = try jsonString(part_object, "tool_call_id"),
                .name = try jsonString(part_object, "tool_name"),
                .arguments_json = try jsonString(part_object, "args"),
                .tool_kind = try parseOptionalToolKind(part_object),
                .provider = try parseProviderPart(allocator, part_object),
                .thought_signature = try optionalJsonString(part_object, "thought_signature"),
            } };
        } else if (std.mem.eql(u8, kind, "builtin-tool-search-call")) {
            part.* = .{ .native_tool_search_call = try parseToolSearchCall(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "builtin-tool-call")) {
            part.* = .{ .native_tool_call = try parseNativeToolCall(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "builtin-tool-search-return")) {
            part.* = .{ .native_tool_search_return = try parseToolSearchResult(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "builtin-tool-return")) {
            part.* = .{ .native_tool_return = try parseNativeToolResult(allocator, part_object) };
        } else if (std.mem.eql(u8, kind, "compaction")) {
            part.* = .{ .compaction = .{
                .content = try optionalJsonString(part_object, "content"),
                .provider = try parseProviderPart(allocator, part_object),
            } };
        } else if (std.mem.eql(u8, kind, "speech")) {
            const speech = try parseSpeech(allocator, part_object);
            if (speech.speaker != .assistant) return Error.InvalidHistory;
            part.* = .{ .speech = speech };
        } else if (std.mem.eql(u8, kind, "file")) {
            const content_object = try jsonObject(part_object, "content");
            const content_kind = try jsonString(content_object, "kind");
            const content = try parseContent(allocator, content_object);
            if (std.mem.eql(u8, content_kind, "image")) part.* = .{ .image = content } else if (std.mem.eql(u8, content_kind, "audio")) part.* = .{ .audio = content } else if (std.mem.eql(u8, content_kind, "video")) part.* = .{ .video = content } else if (std.mem.eql(u8, content_kind, "document")) part.* = .{ .document = content } else if (std.mem.eql(u8, content_kind, "binary")) part.* = .{ .binary = content } else return Error.InvalidHistory;
        } else return Error.InvalidHistory;
    }
    const state_name = try optionalJsonString(object, "state");
    return .{
        .parts = parts,
        .usage = try parseUsage(allocator, object.get("usage")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .provider_name = try optionalJsonString(object, "provider_name"),
        .provider_url = try optionalJsonString(object, "provider_url"),
        .provider_details = try optionalProviderDetails(object, "provider_details"),
        .provider_response_id = try optionalJsonString(object, "provider_response_id"),
        .model_name = try optionalJsonString(object, "model_name"),
        .finish_reason = try parseFinishReason(object.get("finish_reason")),
        .run_id = try optionalJsonString(object, "run_id"),
        .conversation_id = try optionalJsonString(object, "conversation_id"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .state = if (state_name) |name|
            std.meta.stringToEnum(message_types.ResponseState, name) orelse return Error.InvalidHistory
        else
            .complete,
    };
}

fn parseV1(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const message_types.Message {
    const messages = try allocator.alloc(message_types.Message, values.len);
    for (values, messages) |value, *message| {
        const object = try asObject(value);
        const role = try jsonString(object, "role");
        const parts = try jsonArray(object, "parts");
        const metadata = try parseMetadata(allocator, object.get("metadata"));
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "user") or
            std.mem.eql(u8, role, "tool"))
        {
            const request_parts = try allocator.alloc(message_types.RequestPart, parts.len);
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
            const response_parts = try allocator.alloc(message_types.ResponsePart, parts.len);
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

fn parseUserContent(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.UserContent {
    const kind = try jsonString(object, "kind");
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try jsonString(object, "content") };
    if (std.mem.eql(u8, kind, "text-content")) return .{ .text_content = .{
        .content = try jsonString(object, "content"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    } };
    if (std.mem.eql(u8, kind, "uploaded-file"))
        return .{ .uploaded_file = try parseUploadedFile(allocator, object) };
    if (std.mem.eql(u8, kind, "cache-point")) {
        const ttl = std.meta.stringToEnum(message_types.CachePoint.Ttl, try jsonString(object, "ttl")) orelse
            return Error.InvalidHistory;
        return .{ .cache_point = .{ .ttl = ttl } };
    }
    const content = try parseContent(allocator, object);
    if (std.mem.eql(u8, kind, "image")) return .{ .image = content };
    if (std.mem.eql(u8, kind, "audio")) return .{ .audio = content };
    if (std.mem.eql(u8, kind, "video")) return .{ .video = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseV1UserContent(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: []const u8,
) !message_types.UserContent {
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try jsonString(object, "text") };
    const content = try parseContent(allocator, object);
    if (std.mem.eql(u8, kind, "image")) return .{ .image = content };
    if (std.mem.eql(u8, kind, "audio")) return .{ .audio = content };
    if (std.mem.eql(u8, kind, "video")) return .{ .video = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseV1ResponsePart(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: []const u8,
) !message_types.ResponsePart {
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
    if (std.mem.eql(u8, kind, "video")) return .{ .video = content };
    if (std.mem.eql(u8, kind, "document")) return .{ .document = content };
    if (std.mem.eql(u8, kind, "binary")) return .{ .binary = content };
    return Error.InvalidHistory;
}

fn parseToolReturn(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.ToolResult {
    const outcome = try parseOutcome(object);
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .name = try jsonString(object, "tool_name"),
        .content = try jsonString(object, "content"),
        .files = try parseContents(allocator, object.get("files")),
        .tool_kind = try parseOptionalToolKind(object),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .outcome = outcome,
        .is_error = if (outcome == null) try optionalJsonBool(object, "is_error") orelse false else false,
    };
}

fn parseContent(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.Content {
    const source_name = try jsonString(object, "source");
    const source: message_types.ContentSource = if (std.mem.eql(u8, source_name, "bytes")) blk: {
        const encoded = try jsonString(object, "data");
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return Error.InvalidHistory;
        const decoded = try allocator.alloc(u8, size); // kcov-ignore
        std.base64.standard.Decoder.decode(decoded, encoded) catch return Error.InvalidHistory;
        break :blk .{ .bytes = decoded };
    } else if (std.mem.eql(u8, source_name, "url"))
        .{ .url = try jsonString(object, "url") }
    else if (std.mem.eql(u8, source_name, "provider_file"))
        .{ .provider_file = .{
            .id = try jsonString(object, "file_id"),
            .provider = try optionalJsonString(object, "provider"),
        } }
    else if (std.mem.eql(u8, source_name, "uploaded_file"))
        .{ .uploaded_file = try parseUploadedFile(allocator, try jsonObject(object, "uploaded_file")) }
    else
        return Error.InvalidHistory;
    return .{
        .source = source,
        .media_type = try jsonString(object, "media_type"),
        .filename = try optionalJsonString(object, "filename"),
        .identifier = try optionalJsonString(object, "identifier"),
        .provider = try parseProviderPart(allocator, object),
        .thought_signature = try optionalJsonString(object, "thought_signature"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    };
}

fn parseProviderPart(_: std.mem.Allocator, object: std.json.ObjectMap) !message_types.ProviderPart {
    const provider = message_types.ProviderPart{
        .id = try optionalJsonString(object, "id"),
        .provider_name = try optionalJsonString(object, "provider_name"),
        .provider_details = try optionalProviderDetails(object, "provider_details"),
    };
    if ((provider.id != null or provider.provider_details != null) and provider.provider_name == null)
        return Error.InvalidHistory;
    return provider;
}

fn hasProviderPart(provider: message_types.ProviderPart) bool {
    return provider.id != null or provider.provider_name != null or provider.provider_details != null;
}

fn parseOptionalToolKind(object: std.json.ObjectMap) !?message_types.ToolPartKind {
    const name = try optionalJsonString(object, "tool_kind") orelse return null;
    return std.meta.stringToEnum(message_types.ToolPartKind, name) orelse return Error.InvalidHistory;
}

fn parseOutcome(object: std.json.ObjectMap) !?message_types.ToolOutcome {
    const name = try optionalJsonString(object, "outcome") orelse return null;
    return std.meta.stringToEnum(message_types.ToolOutcome, name) orelse return Error.InvalidHistory;
}

fn parseUploadedFile(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.UploadedFile {
    return .{
        .id = try jsonString(object, "file_id"),
        .provider_name = try jsonString(object, "provider_name"),
        .media_type = try optionalJsonString(object, "media_type"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
    };
}

fn parseContents(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const message_types.Content {
    const values = switch (value orelse return &.{}) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    };
    const result = try allocator.alloc(message_types.Content, values.len);
    for (values, result) |item, *content| content.* = try parseContent(allocator, try asObject(item));
    return result;
}

fn parseStrings(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *string| string.* = switch (value) {
        .string => |text| text,
        else => return Error.InvalidHistory,
    };
    return result;
}

fn parseToolSearchCall(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !message_types.ToolSearchCall {
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .queries = try parseStrings(allocator, try jsonArray(object, "queries")),
        .provider = try parseProviderPart(allocator, object),
    };
}

fn parseToolSearchResult(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !message_types.ToolSearchResult {
    const values = try jsonArray(object, "discovered_tools");
    const matches = try allocator.alloc(message_types.ToolSearchMatch, values.len);
    for (values, matches) |value, *match| {
        match.* = .{ .name = try jsonString(try asObject(value), "name") };
    }
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .discovered_tools = matches,
        .message = try optionalJsonString(object, "message"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .outcome = try parseOutcome(object) orelse .success,
        .provider = try parseProviderPart(allocator, object),
    };
}

fn parseCapabilityLoadResult(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !message_types.CapabilityLoadResult {
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .instructions = try optionalJsonString(object, "instructions"),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .outcome = try parseOutcome(object) orelse .success,
    };
}

fn parseNativeToolCall(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !message_types.NativeToolCall {
    return .{
        .id = try jsonString(object, "tool_call_id"),
        .name = try jsonString(object, "tool_name"),
        .arguments_json = try jsonString(object, "args"),
        .tool_kind = try parseOptionalToolKind(object),
        .provider = try parseProviderPart(allocator, object),
    };
}

fn parseNativeToolResult(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !message_types.NativeToolResult {
    return .{
        .call_id = try jsonString(object, "tool_call_id"),
        .name = try jsonString(object, "tool_name"),
        .content = try jsonString(object, "content"),
        .files = try parseContents(allocator, object.get("files")),
        .tool_kind = try parseOptionalToolKind(object),
        .metadata = try parseMetadata(allocator, object.get("metadata")),
        .timestamp_unix_ms = try optionalJsonInteger(object, "timestamp_unix_ms"),
        .outcome = try parseOutcome(object) orelse .success,
        .provider = try parseProviderPart(allocator, object),
    };
}

fn parseSpeech(allocator: std.mem.Allocator, object: std.json.ObjectMap) !message_types.SpeechPart {
    const speaker_name = try jsonString(object, "speaker");
    const audio = if (object.get("audio")) |value| try parseContent(allocator, try asObject(value)) else null;
    const interrupted_at = try optionalJsonInteger(object, "interrupted_at_ms");
    if (interrupted_at != null and interrupted_at.? < 0) return Error.InvalidHistory;
    return .{
        .speaker = std.meta.stringToEnum(message_types.SpeechPart.Speaker, speaker_name) orelse
            return Error.InvalidHistory,
        .transcript = try optionalJsonString(object, "transcript"),
        .audio = audio,
        .interrupted_at_ms = if (interrupted_at) |value| @intCast(value) else null,
        .provider = try parseProviderPart(allocator, object),
    };
}

fn parseInstructionParts(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) ![]const message_types.InstructionPart {
    const values = switch (value orelse return &.{}) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    };
    const result = try allocator.alloc(message_types.InstructionPart, values.len);
    for (values, result) |item, *part| {
        const object = try asObject(item);
        part.* = .{
            .content = try jsonString(object, "content"),
            .dynamic = try optionalJsonBool(object, "dynamic") orelse false,
        };
    }
    return result;
}

fn parseUsage(allocator: std.mem.Allocator, value: ?std.json.Value) !message_types.Usage {
    const object = try asObject(value orelse return .{});
    const details_values = if (object.get("details")) |details| switch (details) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    } else &.{};
    const details = try allocator.alloc(usage_types.Detail, details_values.len);
    for (details_values, details) |item, *detail| {
        const detail_object = try asObject(item);
        const counter = try jsonInteger(detail_object, "value");
        if (counter < 0) return Error.InvalidHistory;
        detail.* = .{ .name = try jsonString(detail_object, "name"), .value = @intCast(counter) };
    }
    const cost = if (object.get("cost")) |cost_value| switch (cost_value) {
        .object => |cost_object| blk: {
            break :blk usage_types.Cost{ .nano_usd = try jsonUnsigned(cost_object, "nano_usd") };
        },
        .null => null,
        else => return Error.InvalidHistory,
    } else null;
    return .{
        .input_tokens = try jsonUnsigned(object, "input_tokens"),
        .cache_write_tokens = try optionalJsonUnsigned(object, "cache_write_tokens") orelse 0,
        .cache_read_tokens = try optionalJsonUnsigned(object, "cache_read_tokens") orelse 0,
        .output_tokens = try jsonUnsigned(object, "output_tokens"),
        .reasoning_tokens = try optionalJsonUnsigned(object, "reasoning_tokens") orelse 0,
        .input_audio_tokens = try optionalJsonUnsigned(object, "input_audio_tokens") orelse 0,
        .cache_audio_read_tokens = try optionalJsonUnsigned(object, "cache_audio_read_tokens") orelse 0,
        .output_audio_tokens = try optionalJsonUnsigned(object, "output_audio_tokens") orelse 0,
        .details = details,
        .cost = cost,
        .cost_source = if (object.get("cost_source")) |source| switch (source) {
            .string => |name| std.meta.stringToEnum(usage_types.CostSource, name) orelse
                return Error.InvalidHistory,
            .null => null,
            else => return Error.InvalidHistory,
        } else null,
        .cost_table_version = if (object.get("cost_table_version")) |version| switch (version) {
            .string => |text| text,
            .null => null,
            else => return Error.InvalidHistory,
        } else null,
        .duration_ms = if (object.get("duration_ms")) |duration| switch (duration) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return Error.InvalidHistory,
            .null => null,
            else => return Error.InvalidHistory,
        } else null,
    };
}

fn parseFinishReason(value: ?std.json.Value) !?message_types.FinishReason {
    const object = try asObject(value orelse return null);
    const kind_name = try jsonString(object, "kind");
    return .{
        .kind = std.meta.stringToEnum(message_types.FinishReason.Kind, kind_name) orelse return Error.InvalidHistory,
        .raw = try jsonString(object, "raw"),
    };
}

fn optionalProviderDetails(object: std.json.ObjectMap, name: []const u8) !?message_types.ProviderDetails {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    return message_types.ProviderDetails.fromValue(value) catch return Error.InvalidHistory;
}

fn parseMetadata(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const message_types.Metadata {
    const values = switch (value orelse return &.{}) {
        .array => |array| array.items,
        else => return Error.InvalidHistory,
    };
    const metadata = try allocator.alloc(message_types.Metadata, values.len);
    for (values, metadata) |item, *result| {
        const object = try asObject(item);
        result.* = .{ .key = try jsonString(object, "key"), .value = try jsonString(object, "value") };
    }
    return metadata;
}

/// Keeps system-prompt requests plus the newest `max_messages` other message_types.
pub fn trim(
    allocator: std.mem.Allocator,
    messages: []const message_types.Message,
    max_messages: usize,
) ![]const message_types.Message {
    var ordinary: usize = 0;
    for (messages) |message| if (!isSystemRequest(message)) {
        ordinary += 1;
    };
    const skip = ordinary -| max_messages;
    var seen: usize = 0;
    var retained: std.ArrayList(message_types.Message) = .empty;
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
pub fn compact(allocator: std.mem.Allocator, messages: []const message_types.Message) ![]const message_types.Message {
    var result: std.ArrayList(message_types.Message) = .empty;
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

fn compactPair(allocator: std.mem.Allocator, left: message_types.Message, right: message_types.Message) !?message_types.Message {
    return switch (left) {
        .request => |left_request| switch (right) {
            .request => |right_request| if (requestText(left_request)) |left_text| blk: {
                const right_text = requestText(right_request) orelse break :blk null;
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ left_text, right_text });
                const parts = try allocator.alloc(message_types.RequestPart, 1);
                parts[0] = .{ .user_prompt = .{ .text = joined } };
                break :blk .{ .request = .{ .parts = parts } };
            } else null,
            .response => null,
        },
        .response => |left_response| switch (right) {
            .response => |right_response| if (responseText(left_response)) |left_text| blk: {
                const right_text = responseText(right_response) orelse break :blk null;
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ left_text, right_text });
                const parts = try allocator.alloc(message_types.ResponsePart, 1);
                parts[0] = .{ .text = joined };
                break :blk .{ .response = .{ .parts = parts } };
            } else null,
            .request => null,
        },
    };
}

/// Removes malformed and orphaned tool traffic and repairs tool-return names.
pub fn providerValid(allocator: std.mem.Allocator, messages: []const message_types.Message) ![]const message_types.Message {
    var cleaned: std.ArrayList(message_types.Message) = .empty;
    for (messages) |message| switch (message) {
        .request => |request| if (request.parts.len > 0) try cleaned.append(allocator, message),
        .response => |response| {
            var parts: std.ArrayList(message_types.ResponsePart) = .empty;
            for (response.parts) |part| switch (part) {
                .tool_call => |call| if (try validJson(allocator, call.arguments_json)) {
                    try parts.append(allocator, part);
                },
                .native_tool_call => |call| if (try validJson(allocator, call.arguments_json)) {
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

    var result: std.ArrayList(message_types.Message) = .empty;
    for (cleaned.items, 0..) |message, index| switch (message) {
        .request => |request| {
            const previous = lastResponse(result.items);
            var parts: std.ArrayList(message_types.RequestPart) = .empty;
            for (request.parts) |part| switch (part) {
                .tool_return => |tool_return| if (previous) |response| {
                    if (findCall(response.parts, tool_return.call_id)) |call| {
                        var repaired = tool_return;
                        repaired.name = call.name;
                        try parts.append(allocator, .{ .tool_return = repaired });
                    }
                },
                .tool_search_return => |tool_return| if (previous) |response| {
                    if (hasResponseCall(response.parts, tool_return.call_id, .tool_search))
                        try parts.append(allocator, part);
                },
                .capability_load_return => |tool_return| if (previous) |response| {
                    if (hasResponseCall(response.parts, tool_return.call_id, .capability_load))
                        try parts.append(allocator, part);
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
            var parts: std.ArrayList(message_types.ResponsePart) = .empty;
            for (response.parts) |part| switch (part) {
                .tool_call => |call| if (hasFutureReturn(cleaned.items[index + 1 ..], call.id)) {
                    try parts.append(allocator, part);
                },
                .tool_search_call => |call| if (hasFutureTypedReturn(
                    cleaned.items[index + 1 ..],
                    call.call_id,
                    .tool_search,
                )) {
                    try parts.append(allocator, part);
                },
                .capability_load_call => |call| if (hasFutureTypedReturn(
                    cleaned.items[index + 1 ..],
                    call.call_id,
                    .capability_load,
                )) {
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
    messages: []const message_types.Message,
    options: Processor.Summarize,
    control: model.RunControl,
) ![]const message_types.Message {
    var ordinary: usize = 0;
    for (messages) |message| {
        if (!isSystemRequest(message)) ordinary += 1;
    }
    if (ordinary <= options.keep_recent_messages) return messages;
    const older_count = ordinary - options.keep_recent_messages;
    var older: std.ArrayList(message_types.Message) = .empty;
    var retained: std.ArrayList(message_types.Message) = .empty;
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
    const summary_parts = try allocator.alloc(message_types.RequestPart, 1);
    summary_parts[0] = .{ .user_prompt = .{ .text = summary } };
    var with_summary: std.ArrayList(message_types.Message) = .empty;
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
    messages: []const message_types.Message,
) ![]const u8 {
    return options.summarizeFn(options.context, allocator, messages);
}

fn isSystemRequest(message: message_types.Message) bool {
    return switch (message) {
        .response => false,
        .request => |request| blk: {
            if (request.parts.len == 0) break :blk false;
            for (request.parts) |part| switch (part) {
                .system_prompt, .system_prompt_part => {},
                else => break :blk false,
            };
            break :blk true;
        },
    };
}

fn messagePartsLen(message: message_types.Message) usize {
    return switch (message) {
        .request => |request| request.parts.len,
        .response => |response| response.parts.len,
    };
}

fn requestText(request: message_types.RequestMessage) ?[]const u8 {
    if (request.metadata.len > 0 or request.parts.len != 1) return null;
    return switch (request.parts[0]) {
        .user_prompt => |content| switch (content) {
            .text => |text| text,
            else => null,
        },
        else => null,
    };
}

fn responseText(response: message_types.ResponseMessage) ?[]const u8 {
    if (response.metadata.len > 0 or response.parts.len != 1) return null;
    return switch (response.parts[0]) {
        .text => |text| text,
        else => null,
    };
}

fn lastResponse(messages: []const message_types.Message) ?message_types.ResponseMessage {
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

fn hasFutureReturn(messages: []const message_types.Message, id: []const u8) bool {
    for (messages) |message| switch (message) {
        .response => return false,
        .request => |request| for (request.parts) |part| switch (part) {
            .tool_return => |result| if (std.mem.eql(u8, result.call_id, id)) return true,
            .tool_search_return => |result| if (std.mem.eql(u8, result.call_id, id)) return true,
            .capability_load_return => |result| if (std.mem.eql(u8, result.call_id, id)) return true,
            else => {},
        },
    };
    return false;
}

fn hasFutureTypedReturn(
    messages: []const message_types.Message,
    id: []const u8,
    kind: message_types.ToolPartKind,
) bool {
    for (messages) |message| switch (message) {
        .response => return false,
        .request => |request| for (request.parts) |part| switch (part) {
            .tool_search_return => |result| if (kind == .tool_search and
                std.mem.eql(u8, result.call_id, id)) return true,
            .capability_load_return => |result| if (kind == .capability_load and
                std.mem.eql(u8, result.call_id, id)) return true,
            else => {},
        },
    };
    return false;
}

fn hasResponseCall(
    parts: []const message_types.ResponsePart,
    id: []const u8,
    kind: message_types.ToolPartKind,
) bool {
    for (parts) |part| switch (part) {
        .tool_search_call => |call| if (kind == .tool_search and std.mem.eql(u8, call.call_id, id)) return true,
        .capability_load_call => |call| if (kind == .capability_load and std.mem.eql(u8, call.call_id, id)) return true,
        else => {},
    };
    return false;
}

fn findCall(parts: []const message_types.ResponsePart, id: []const u8) ?message_types.ToolCall {
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
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn jsonObject(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return asObject(object.get(name) orelse return Error.InvalidHistory);
}

fn jsonArray(object: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .array => |array| array.items,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .string => |value| value,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn optionalJsonString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn jsonInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return Error.InvalidHistory) {
        .integer => |integer| integer,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn jsonUnsigned(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = try jsonInteger(object, name);
    if (value < 0) return Error.InvalidHistory;
    return @intCast(value);
}

fn optionalJsonInteger(object: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn optionalJsonUnsigned(object: std.json.ObjectMap, name: []const u8) !?u64 {
    const value = try optionalJsonInteger(object, name) orelse return null;
    if (value < 0) return Error.InvalidHistory;
    return @intCast(value);
}

fn optionalJsonBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => Error.InvalidHistory, // kcov-ignore
    };
}

fn testingProviderDetails(arena: std.mem.Allocator, source: []const u8) !message_types.ProviderDetails {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    return message_types.ProviderDetails.fromValue(value);
}

test "history version 2 round trips request response parts and provenance" {
    var details_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer details_arena.deinit();
    const provider_details = try testingProviderDetails(details_arena.allocator(), "{\"cached\":true}");
    const messages = [_]message_types.Message{
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
            .usage = .{
                .input_tokens = 3,
                .cache_write_tokens = 1,
                .cache_read_tokens = 1,
                .output_tokens = 2,
                .reasoning_tokens = 1,
                .input_audio_tokens = 1,
                .cache_audio_read_tokens = 1,
                .output_audio_tokens = 1,
                .details = &.{.{ .name = "native", .value = 7 }},
                .cost = .{ .nano_usd = 2_400 },
                .cost_source = .provider,
                .duration_ms = 9,
            },
            .timestamp_unix_ms = 20,
            .provider_name = "openai",
            .provider_url = "https://api.openai.com/v1",
            .provider_details = provider_details,
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
    try std.testing.expectEqual(message_types.RequestState.interrupted, request.state);
    const response = decoded.messages[1].response;
    try std.testing.expectEqualStrings("answer", response.parts[0].text);
    try std.testing.expect(response.provider_details.?.value.object.get("cached").?.bool);
    try std.testing.expectEqual(@as(u64, 5), response.usage.totalTokens());
    try std.testing.expectEqual(@as(u64, 1), response.usage.reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 7), response.usage.detail("native").?);
    try std.testing.expectEqual(@as(u64, 2_400), response.usage.cost.?.nano_usd);
    try std.testing.expectEqual(usage_types.CostSource.provider, response.usage.cost_source.?);
    try std.testing.expectEqual(@as(u64, 9), response.usage.duration_ms.?);
    try std.testing.expectEqual(message_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "history version 2 round trips the complete message vocabulary" {
    var details_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer details_arena.deinit();
    const provider = message_types.ProviderPart{
        .id = "item-1",
        .provider_name = "openai",
        .provider_details = try testingProviderDetails(details_arena.allocator(), "{\"opaque\":true}"),
    };
    const uploaded = message_types.UploadedFile{
        .id = "file-1",
        .provider_name = "openai",
        .media_type = "video/mp4",
        .metadata = &.{.{ .key = "scope", .value = "test" }},
    };
    const video = message_types.Content{
        .source = .{ .uploaded_file = uploaded },
        .media_type = "video/mp4",
        .identifier = "clip",
        .provider = provider,
    };
    const text_file = message_types.Content{
        .source = .{ .bytes = "notes" },
        .media_type = "text/plain",
        .filename = "notes.txt",
    };
    const binary_file = message_types.Content{
        .source = .{ .bytes = "data" },
        .media_type = "application/octet-stream",
    };
    const search_result = message_types.ToolSearchResult{
        .call_id = "search-1",
        .discovered_tools = &.{.{ .name = "weather" }},
        .message = "one match",
        .metadata = &.{.{ .key = "ranker", .value = "bm25" }},
        .timestamp_unix_ms = 15,
        .outcome = .success,
        .provider = provider,
    };
    const messages = [_]message_types.Message{
        .{ .request = .{
            .parts = &.{
                .{ .system_prompt_part = .{ .content = "rules", .timestamp_unix_ms = 1, .dynamic_ref = "ref" } },
                .{ .user_prompt = .{ .text_content = .{
                    .content = "hello",
                    .metadata = &.{.{ .key = "ui", .value = "chat" }},
                } } },
                .{ .user_prompt_part = .{ .content = .{ .video = video }, .timestamp_unix_ms = 2 } },
                .{ .user_prompt = .{ .uploaded_file = uploaded } },
                .{ .user_prompt = .{ .cache_point = .{ .ttl = .one_hour } } },
                .{ .speech = .{ .speaker = .user, .transcript = "spoken", .audio = .{
                    .source = .{ .bytes = "audio" },
                    .media_type = "audio/wav",
                } } },
                .{ .tool_search_return = search_result },
                .{ .capability_load_return = .{
                    .call_id = "load-1",
                    .instructions = "loaded",
                    .outcome = .denied,
                } },
                .{ .tool_return = .{
                    .call_id = "call-1",
                    .name = "render",
                    .content = "{\"ok\":false}",
                    .files = &.{ video, text_file, binary_file },
                    .tool_kind = .tool_search,
                    .metadata = &.{.{ .key = "attempt", .value = "1" }},
                    .timestamp_unix_ms = 3,
                    .outcome = .failed,
                } },
                .{ .retry_prompt_part = .{
                    .content = "retry",
                    .tool_name = "render",
                    .tool_call_id = "call-1",
                    .timestamp_unix_ms = 4,
                } },
                .{ .tool_availability_delta = .{
                    .tools_added = &.{ "weather", "forecast" },
                    .tool_call_id = "load-1",
                } },
            },
            .instruction_parts = &.{
                .{ .content = "static" },
                .{ .content = "dynamic", .dynamic = true },
            },
        } },
        .{ .response = .{
            .parts = &.{
                .{ .text_part = .{ .content = "answer", .provider = provider } },
                .{ .tool_search_call = .{ .call_id = "search-1", .queries = &.{"weather"} } },
                .{ .capability_load_call = .{ .call_id = "load-1", .capability_id = "weather" } },
                .{ .tool_call = .{
                    .id = "call-1",
                    .name = "render",
                    .arguments_json = "{}",
                    .tool_kind = .capability_load,
                    .provider = provider,
                } },
                .{ .native_tool_search_call = .{
                    .call_id = "native-search",
                    .queries = &.{ "a", "b" },
                    .provider = provider,
                } },
                .{ .native_tool_call = .{
                    .id = "native-1",
                    .name = "web_search",
                    .arguments_json = "{}",
                    .provider = provider,
                } },
                .{ .native_tool_search_return = search_result },
                .{ .native_tool_return = .{
                    .call_id = "native-1",
                    .name = "web_search",
                    .content = "result",
                    .files = &.{ video, text_file, binary_file },
                    .outcome = .interrupted,
                    .provider = provider,
                } },
                .{ .thinking = .{ .content = "think", .provider = provider } },
                .{ .compaction = .{ .content = "summary", .provider = provider } },
                .{ .video = video },
                .{ .speech = .{
                    .speaker = .assistant,
                    .transcript = "said",
                    .interrupted_at_ms = 12,
                    .provider = provider,
                } },
            },
            .state = .interrupted,
        } },
    };

    const encoded = try stringify(std.testing.allocator, &messages);
    defer std.testing.allocator.free(encoded);
    var decoded = try parse(std.testing.allocator, encoded);
    defer decoded.deinit();

    const request = decoded.messages[0].request;
    try std.testing.expectEqual(@as(usize, 11), request.parts.len);
    try std.testing.expectEqualStrings("ref", request.parts[0].system_prompt_part.dynamic_ref.?);
    try std.testing.expectEqualStrings("hello", request.parts[1].user_prompt.text_content.content);
    try std.testing.expectEqualStrings("file-1", request.parts[2].user_prompt_part.content.video.source.uploaded_file.id);
    try std.testing.expectEqual(message_types.CachePoint.Ttl.one_hour, request.parts[4].user_prompt.cache_point.ttl);
    try std.testing.expectEqual(message_types.ToolOutcome.failed, request.parts[8].tool_return.effectiveOutcome());
    try std.testing.expect(request.instruction_parts[1].dynamic);

    const response = decoded.messages[1].response;
    try std.testing.expectEqual(@as(usize, 12), response.parts.len);
    try std.testing.expectEqualStrings("item-1", response.parts[0].text_part.provider.id.?);
    try std.testing.expectEqualStrings("weather", response.parts[1].tool_search_call.queries[0]);
    try std.testing.expectEqualStrings("weather", response.parts[2].capability_load_call.capability_id);
    try std.testing.expectEqualStrings("native-1", response.parts[7].native_tool_return.call_id);
    try std.testing.expectEqualStrings("summary", response.parts[9].compaction.content.?);
    try std.testing.expectEqual(@as(?u64, 12), response.parts[11].speech.interrupted_at_ms);
    try std.testing.expectEqual(message_types.ResponseState.interrupted, response.state);
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
    messages: []const message_types.Message,
) ![]const u8 {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += messages.len;
    return allocator.dupe(u8, "summary");
}

fn customForTest(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    run: Context,
    messages: []const message_types.Message,
) ![]const message_types.Message {
    const requests: *usize = @ptrCast(@alignCast(context));
    requests.* = run.model_requests;
    return allocator.dupe(message_types.Message, messages);
}

test "history processors preserve system requests and repair tool traffic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]message_types.Message{
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

    const response_messages = [_]message_types.Message{
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
        .{ .trim = .{ .max_messages = messages.len } }, // kcov-ignore
        .compact, // kcov-ignore
        .provider_valid, // kcov-ignore
        .{ .custom = .{ .context = &observed_requests, .processFn = customForTest } }, // kcov-ignore
    };
    _ = try processAll(arena.allocator(), &processors, context, &messages);
    try std.testing.expectEqual(@as(usize, 7), observed_requests);

    const orphaned = [_]message_types.Message{
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

test "provider validation pairs typed calls and returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const typed = [_]message_types.Message{
        .{ .response = .{ .parts = &.{
            .{ .tool_search_call = .{ .call_id = "search", .queries = &.{"weather"} } },
            .{ .capability_load_call = .{ .call_id = "load", .capability_id = "maps" } },
            .{ .native_tool_call = .{
                .id = "native",
                .name = "web_search",
                .arguments_json = "{}",
                .provider = .{},
            } },
        } } },
        .{ .request = .{ .parts = &.{
            .{ .tool_search_return = .{
                .call_id = "search",
                .discovered_tools = &.{.{ .name = "weather" }},
            } },
            .{ .capability_load_return = .{ .call_id = "load", .instructions = "loaded" } },
        } } },
    };
    const valid = try providerValid(arena.allocator(), &typed);
    try std.testing.expectEqual(@as(usize, 2), valid.len);
    try std.testing.expectEqual(@as(usize, 3), valid[0].response.parts.len);
    try std.testing.expectEqual(@as(usize, 2), valid[1].request.parts.len);

    const search_return = message_types.Message{ .request = .{ .parts = &.{.{ .tool_search_return = .{
        .call_id = "search",
        .discovered_tools = &.{},
    } }} } };
    const load_return = message_types.Message{ .request = .{ .parts = &.{.{ .capability_load_return = .{
        .call_id = "load",
    } }} } };
    try std.testing.expect(hasFutureReturn(&.{search_return}, "search"));
    try std.testing.expect(hasFutureReturn(&.{load_return}, "load"));
    try std.testing.expect(hasFutureTypedReturn(&.{search_return}, "search", .tool_search));
    try std.testing.expect(hasFutureTypedReturn(&.{load_return}, "load", .capability_load));
    try std.testing.expect(!hasFutureTypedReturn(&.{search_return}, "search", .capability_load));
    try std.testing.expect(!hasFutureTypedReturn(&.{.{ .response = .{ .parts = &.{} } }}, "search", .tool_search));
    try std.testing.expect(hasResponseCall(typed[0].response.parts, "search", .tool_search));
    try std.testing.expect(hasResponseCall(typed[0].response.parts, "load", .capability_load));
    try std.testing.expect(!hasResponseCall(typed[0].response.parts, "missing", .tool_search));

    const invalid_native = [_]message_types.Message{.{ .response = .{ .parts = &.{.{ .native_tool_call = .{
        .id = "native",
        .name = "web_search",
        .arguments_json = "{",
        .provider = .{},
    } }} } }};
    try std.testing.expectEqual(@as(usize, 0), (try providerValid(arena.allocator(), &invalid_native)).len);
}

test "history rejects malformed documents and invalid structured provider details" {
    try std.testing.expectError(Error.InvalidHistory, parse(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.UnsupportedVersion, parse(std.testing.allocator, "{\"version\":3,\"messages\":[]}"));
    try std.testing.expectError(Error.InvalidHistory, stringify(std.testing.allocator, &.{.{ .response = .{
        .parts = &.{.{ .text = "x" }},
        .provider_details = .{ .value = .{ .string = "not-an-object" } },
    } }}));
    try std.testing.expectError(Error.InvalidHistory, stringify(std.testing.allocator, &.{.{ .response = .{
        .parts = &.{.{ .text_part = .{
            .content = "x",
            .provider = .{ .id = "item-without-provider" },
        } }},
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
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":-1,\"output_tokens\":0},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"details\":false},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cost\":false},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cost_source\":\"unknown\"},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"duration_ms\":-1},\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"state\":\"other\",\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"speech\",\"speaker\":\"assistant\"}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"speech\",\"speaker\":\"user\"}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"text\",\"content\":\"x\",\"id\":\"item\"}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"file\",\"content\":{\"kind\":\"binary\",\"source\":\"bytes\",\"data\":\"!\",\"media_type\":\"application/octet-stream\"}}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"system-prompt\",\"content\":1}]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"run_id\":1,\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"timestamp_unix_ms\":\"now\",\"parts\":[]}]}",
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"capability-load-return\",\"tool_call_id\":\"load\",\"outcome\":1}]}]}",
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

test "history JSON field helpers reject incorrect value types" {
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "value", .{ .bool = true });

    try std.testing.expectError(Error.InvalidHistory, asObject(.{ .bool = true }));
    try std.testing.expectError(Error.InvalidHistory, jsonString(object, "value"));
    try std.testing.expectError(Error.InvalidHistory, optionalJsonString(object, "value"));
    try std.testing.expectError(Error.InvalidHistory, jsonInteger(object, "value"));
    try std.testing.expectError(Error.InvalidHistory, optionalJsonInteger(object, "value"));
    try std.testing.expectEqual(true, (try optionalJsonBool(object, "value")).?);
    try object.put(std.testing.allocator, "value", .{ .integer = 1 });
    try std.testing.expectError(Error.InvalidHistory, optionalJsonBool(object, "value"));
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
        .provider_details = .{ .value = .{ .object = .empty } },
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
