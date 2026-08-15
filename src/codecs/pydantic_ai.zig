//! Lossless JSON interoperability with PydanticAI stable v2 messages.
//!
//! PydanticAI permits arbitrary JSON in metadata, provider details, tool
//! returns, and usage details. This codec therefore exposes an owned JSON DOM
//! instead of coercing that data into ZigAI's narrower runtime message types.
//! ZigAI history remains a separate, explicitly versioned format.

const std = @import("std");
const json_limits = @import("../json.zig");

/// Upstream release used to define and generate this codec's golden contract.
pub const upstream_version = "2.31.0";

/// Stable codec failures in addition to allocation and JSON-boundary errors.
pub const Error = error{
    /// Valid JSON does not have the PydanticAI stable-v2 message shape.
    InvalidMessages,
};

/// Default limits for persisted PydanticAI message documents.
pub const default_limits = json_limits.defaults.history;

/// A parsed PydanticAI message list and all of its recursively owned JSON data.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const std.json.Value,

    /// Releases the complete parsed value graph.
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses and structurally validates one PydanticAI stable-v2 message list.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) (Error || json_limits.ValidationError || std.mem.Allocator.Error)!Owned {
    return parseWithLimits(gpa, source, default_limits);
}

/// Parses with caller-selected pre-allocation limits.
pub fn parseWithLimits(
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: json_limits.Limits,
) (Error || json_limits.ValidationError || std.mem.Allocator.Error)!Owned {
    try json_limits.validate(gpa, source, limits);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{
        .duplicate_field_behavior = .@"error",
        // Keep arbitrary-precision numbers and their lexical representation.
        .parse_numbers = false,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMessages,
    };
    const messages = switch (root) {
        .array => |array| array.items,
        else => return error.InvalidMessages,
    };
    try validate(messages);
    return .{ .arena = arena, .messages = messages };
}

/// Validates an already parsed message list without allocating.
pub fn validate(messages: []const std.json.Value) Error!void {
    for (messages) |message| try validateMessage(message);
}

/// Serializes a validated message list as compact JSON.
pub fn stringify(gpa: std.mem.Allocator, messages: []const std.json.Value) (Error || std.mem.Allocator.Error)![]u8 {
    try validate(messages);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginArray() catch return error.OutOfMemory;
    for (messages) |message| json.write(message) catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// Parses and rewrites a document without dropping fields or normalizing JSON numbers.
pub fn canonicalize(
    gpa: std.mem.Allocator,
    source: []const u8,
) (Error || json_limits.ValidationError || std.mem.Allocator.Error)![]u8 {
    var owned = try parse(gpa, source);
    defer owned.deinit();
    return stringify(gpa, owned.messages);
}

fn validateMessage(value: std.json.Value) Error!void {
    const object = try requireObject(value);
    const kind = try requiredString(object, "kind");
    const parts = try requiredArray(object, "parts");
    if (std.mem.eql(u8, kind, "request")) {
        try validateOptionalString(object, "timestamp");
        try validateOptionalString(object, "instructions");
        try validateOptionalString(object, "run_id");
        try validateOptionalString(object, "conversation_id");
        try validateOptionalObject(object, "metadata");
        try validateOptionalEnum(object, "state", &.{ "complete", "interrupted" });
        for (parts) |part| try validateRequestPart(part);
        return;
    }
    if (std.mem.eql(u8, kind, "response")) {
        try validateOptionalObjectValue(object, "usage", validateUsage);
        try validateOptionalString(object, "model_name");
        try validateOptionalString(object, "timestamp");
        try validateOptionalString(object, "provider_name");
        try validateOptionalString(object, "provider_url");
        try validateOptionalObject(object, "provider_details");
        try validateOptionalString(object, "provider_response_id");
        try validateOptionalEnum(object, "finish_reason", &.{ "stop", "length", "content_filter", "tool_call", "error" });
        try validateOptionalString(object, "run_id");
        try validateOptionalString(object, "conversation_id");
        try validateOptionalObject(object, "metadata");
        try validateOptionalEnum(object, "state", &.{ "complete", "incomplete", "suspended", "interrupted" });
        for (parts) |part| try validateResponsePart(part);
        return;
    }
    return error.InvalidMessages;
}

fn validateRequestPart(value: std.json.Value) Error!void {
    const object = try requireObject(value);
    const kind = try requiredString(object, "part_kind");
    if (std.mem.eql(u8, kind, "system-prompt")) {
        _ = try requiredString(object, "content");
        try validateOptionalString(object, "timestamp");
        try validateOptionalString(object, "dynamic_ref");
    } else if (std.mem.eql(u8, kind, "user-prompt")) {
        try validateUserPromptContent(try required(object, "content"));
        try validateOptionalString(object, "timestamp");
    } else if (std.mem.eql(u8, kind, "speech")) {
        try validateSpeech(object, "user");
    } else if (std.mem.eql(u8, kind, "tool-return")) {
        try validateToolReturn(object, false);
    } else if (std.mem.eql(u8, kind, "retry-prompt")) {
        try validateRetryPrompt(object);
    } else if (std.mem.eql(u8, kind, "tool-availability-delta")) {
        if (object.get("tools_added")) |tools| try validateStrings(switch (tools) {
            .array => |array| array.items,
            else => return error.InvalidMessages,
        });
        try validateOptionalString(object, "tool_call_id");
    } else {
        return error.InvalidMessages;
    }
}

fn validateResponsePart(value: std.json.Value) Error!void {
    const object = try requireObject(value);
    const kind = try requiredString(object, "part_kind");
    if (std.mem.eql(u8, kind, "text")) {
        _ = try requiredString(object, "content");
        try validateProviderPart(object);
    } else if (std.mem.eql(u8, kind, "thinking")) {
        _ = try requiredString(object, "content");
        try validateOptionalString(object, "signature");
        try validateProviderPart(object);
    } else if (std.mem.eql(u8, kind, "compaction")) {
        try validateOptionalString(object, "content");
        try validateProviderPart(object);
    } else if (std.mem.eql(u8, kind, "tool-call")) {
        try validateToolCall(object, false);
    } else if (std.mem.eql(u8, kind, "builtin-tool-call")) {
        try validateToolCall(object, true);
    } else if (std.mem.eql(u8, kind, "builtin-tool-return")) {
        try validateToolReturn(object, true);
    } else if (std.mem.eql(u8, kind, "file")) {
        try validateBinaryContent(try required(object, "content"));
        try validateProviderPart(object);
    } else if (std.mem.eql(u8, kind, "speech")) {
        try validateSpeech(object, "assistant");
    } else {
        return error.InvalidMessages;
    }
}

fn validateUserPromptContent(value: std.json.Value) Error!void {
    switch (value) {
        .string => return,
        .array => |array| for (array.items) |item| try validateUserContent(item),
        else => return error.InvalidMessages,
    }
}

fn validateUserContent(value: std.json.Value) Error!void {
    if (value == .string) return;
    const object = try requireObject(value);
    const kind = try requiredString(object, "kind");
    if (std.mem.eql(u8, kind, "text-content")) {
        _ = try requiredString(object, "content");
        return;
    }
    if (std.mem.eql(u8, kind, "binary")) return validateBinaryContent(value);
    if (std.mem.eql(u8, kind, "uploaded-file")) {
        _ = try requiredString(object, "file_id");
        _ = try requiredString(object, "provider_name");
        try validateOptionalObject(object, "vendor_metadata");
        try validateOptionalString(object, "media_type");
        try validateOptionalString(object, "identifier");
        return;
    }
    if (std.mem.eql(u8, kind, "cache-point")) {
        try validateOptionalEnum(object, "ttl", &.{ "5m", "1h" });
        return;
    }
    if (isOneOf(kind, &.{ "image-url", "audio-url", "document-url", "video-url" })) {
        _ = try requiredString(object, "url");
        if (object.get("force_download")) |download| switch (download) {
            .bool => {},
            .string => |text| if (!std.mem.eql(u8, text, "allow-local")) return error.InvalidMessages,
            else => return error.InvalidMessages,
        };
        try validateOptionalObject(object, "vendor_metadata");
        try validateOptionalString(object, "media_type");
        try validateOptionalString(object, "identifier");
        return;
    }
    return error.InvalidMessages;
}

fn validateBinaryContent(value: std.json.Value) Error!void {
    const object = try requireObject(value);
    if (object.get("kind")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "binary")) return error.InvalidMessages;
    }
    _ = try requiredString(object, "data");
    _ = try requiredString(object, "media_type");
    try validateOptionalObject(object, "vendor_metadata");
    try validateOptionalString(object, "identifier");
}

fn validateSpeech(object: std.json.ObjectMap, expected_speaker: []const u8) Error!void {
    if (!std.mem.eql(u8, try requiredString(object, "speaker"), expected_speaker)) return error.InvalidMessages;
    try validateOptionalString(object, "transcript");
    if (object.get("audio")) |audio| if (audio != .null) try validateBinaryContent(audio);
    if (object.get("interrupted_at_ms")) |milliseconds| if (milliseconds != .null and !isInteger(milliseconds))
        return error.InvalidMessages;
    try validateProviderPart(object);
}

fn validateToolCall(object: std.json.ObjectMap, native: bool) Error!void {
    try validateOptionalString(object, "tool_call_id");
    if (object.get("args")) |args| switch (args) {
        .null, .string, .object => {},
        else => return error.InvalidMessages,
    };
    const tool_kind = try optionalToolKind(object);
    const name = try optionalRequiredString(object, "tool_name");
    if (tool_kind) |kind| {
        if (std.mem.eql(u8, kind, "tool-search")) {
            const expected = if (native) "tool_search" else "search_tools";
            if (name) |actual| if (!std.mem.eql(u8, actual, expected)) return error.InvalidMessages;
            if (object.get("args")) |args| if (args == .object) {
                const queries = try requiredArray(args.object, "queries");
                try validateStrings(queries);
            };
        } else if (!native) {
            if (name) |actual| if (!std.mem.eql(u8, actual, "load_capability")) return error.InvalidMessages;
            if (object.get("args")) |args| {
                if (args == .object) _ = try requiredString(args.object, "id");
            }
        } else if (name == null) {
            return error.InvalidMessages;
        }
    } else if (name == null) return error.InvalidMessages;
    try validateProviderPart(object);
}

fn validateToolReturn(object: std.json.ObjectMap, native: bool) Error!void {
    _ = try required(object, "content");
    try validateOptionalString(object, "tool_call_id");
    const tool_kind = try optionalToolKind(object);
    const name = try optionalRequiredString(object, "tool_name");
    if (tool_kind) |kind| {
        if (std.mem.eql(u8, kind, "tool-search")) {
            const expected = if (native) "tool_search" else "search_tools";
            if (name) |actual| if (!std.mem.eql(u8, actual, expected)) return error.InvalidMessages;
            try validateToolSearchResult(try required(object, "content"));
        } else if (!native) {
            if (name) |actual| if (!std.mem.eql(u8, actual, "load_capability")) return error.InvalidMessages;
            const content = try requireObject(try required(object, "content"));
            try validateOptionalString(content, "instructions");
        } else if (name == null) {
            return error.InvalidMessages;
        }
    } else if (name == null) return error.InvalidMessages;
    try validateOptionalString(object, "timestamp");
    try validateOptionalEnum(object, "outcome", &.{ "success", "failed", "denied", "interrupted" });
    if (native) try validateProviderPart(object);
}

fn validateToolSearchResult(value: std.json.Value) Error!void {
    const object = try requireObject(value);
    const tools = try requiredArray(object, "discovered_tools");
    for (tools) |tool| _ = try requiredString(try requireObject(tool), "name");
    try validateOptionalString(object, "message");
}

fn validateRetryPrompt(object: std.json.ObjectMap) Error!void {
    const content = try required(object, "content");
    switch (content) {
        .string => {},
        .array => |array| for (array.items) |item| {
            const detail = try requireObject(item);
            _ = try requiredString(detail, "type");
            for (try requiredArray(detail, "loc")) |location| switch (location) {
                .string => {},
                else => if (!isInteger(location)) return error.InvalidMessages,
            };
            _ = try requiredString(detail, "msg");
            _ = try required(detail, "input");
            if (detail.get("ctx")) |context| if (context != .object) return error.InvalidMessages;
            if (detail.get("url")) |url| if (url != .string) return error.InvalidMessages;
        },
        else => return error.InvalidMessages,
    }
    try validateOptionalString(object, "tool_name");
    try validateOptionalString(object, "tool_call_id");
    try validateOptionalString(object, "timestamp");
}

fn validateUsage(object: std.json.ObjectMap) Error!void {
    inline for (.{
        "input_tokens",
        "cache_write_tokens",
        "cache_read_tokens",
        "output_tokens",
        "input_audio_tokens",
        "cache_audio_read_tokens",
        "output_audio_tokens",
    }) |name| if (object.get(name)) |value| if (!isInteger(value)) return error.InvalidMessages;
    if (object.get("details")) |details| {
        const values = try requireObject(details);
        var iterator = values.iterator();
        while (iterator.next()) |entry| if (!isInteger(entry.value_ptr.*)) return error.InvalidMessages;
    }
    if (object.get("cost")) |cost| switch (cost) {
        .null, .string, .integer, .float, .number_string => {},
        else => return error.InvalidMessages,
    };
}

fn validateProviderPart(object: std.json.ObjectMap) Error!void {
    try validateOptionalString(object, "id");
    try validateOptionalString(object, "provider_name");
    try validateOptionalObject(object, "provider_details");
}

fn optionalToolKind(object: std.json.ObjectMap) Error!?[]const u8 {
    const value = object.get("tool_kind") orelse return null;
    if (value == .null) return null;
    const name = switch (value) {
        .string => |text| text,
        else => return error.InvalidMessages,
    };
    if (!isOneOf(name, &.{ "tool-search", "capability-load" })) return error.InvalidMessages;
    return name;
}

fn validateOptionalString(object: std.json.ObjectMap, name: []const u8) Error!void {
    if (object.get(name)) |value| if (value != .null and value != .string) return error.InvalidMessages;
}

fn validateOptionalObject(object: std.json.ObjectMap, name: []const u8) Error!void {
    if (object.get(name)) |value| if (value != .null and value != .object) return error.InvalidMessages;
}

fn validateOptionalObjectValue(
    object: std.json.ObjectMap,
    name: []const u8,
    validator: *const fn (std.json.ObjectMap) Error!void,
) Error!void {
    if (object.get(name)) |value| try validator(try requireObject(value));
}

fn validateOptionalEnum(object: std.json.ObjectMap, name: []const u8, allowed: []const []const u8) Error!void {
    const value = object.get(name) orelse return;
    if (value == .null) return;
    const text = switch (value) {
        .string => |item| item,
        else => return error.InvalidMessages,
    };
    if (!isOneOf(text, allowed)) return error.InvalidMessages;
}

fn required(object: std.json.ObjectMap, name: []const u8) Error!std.json.Value {
    return object.get(name) orelse error.InvalidMessages;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    return switch (try required(object, name)) {
        .string => |value| value,
        else => error.InvalidMessages,
    };
}

fn optionalRequiredString(object: std.json.ObjectMap, name: []const u8) Error!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidMessages,
    };
}

fn requiredArray(object: std.json.ObjectMap, name: []const u8) Error![]const std.json.Value {
    return switch (try required(object, name)) {
        .array => |value| value.items,
        else => error.InvalidMessages,
    };
}

fn requireObject(value: std.json.Value) Error!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidMessages,
    };
}

fn validateStrings(values: []const std.json.Value) Error!void {
    for (values) |value| if (value != .string) return error.InvalidMessages;
}

fn isOneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| if (std.mem.eql(u8, value, item)) return true;
    return false;
}

fn isInteger(value: std.json.Value) bool {
    return switch (value) {
        .integer => true,
        .number_string => |text| blk: {
            if (text.len == 0) break :blk false;
            const start: usize = if (text[0] == '-') 1 else 0;
            if (start == text.len) break :blk false;
            for (text[start..]) |character| if (!std.ascii.isDigit(character)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

test "codec preserves arbitrary numbers and unknown schema-compatible fields" {
    const source =
        \\[{"kind":"request","parts":[],"metadata":{"precise":123456789012345678901234567890},"extension":{"ok":true}}]
    ;
    const encoded = try canonicalize(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "123456789012345678901234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"extension\"") != null);

    const string_prompt = try canonicalize(
        std.testing.allocator,
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"user-prompt\",\"content\":\"hello\"}]}]",
    );
    std.testing.allocator.free(string_prompt);
}

test "codec accepts upstream defaults for specialized parts" {
    const source =
        \\[{"kind":"request","parts":[{"part_kind":"tool-availability-delta"},{"part_kind":"tool-return","tool_kind":"tool-search","content":{"discovered_tools":[]}},{"part_kind":"tool-return","tool_kind":"capability-load","content":{}}]},{"kind":"response","parts":[{"part_kind":"tool-call","tool_kind":"tool-search"},{"part_kind":"tool-call","tool_kind":"capability-load"},{"part_kind":"builtin-tool-call","tool_kind":"tool-search"},{"part_kind":"builtin-tool-return","tool_kind":"tool-search","content":{"discovered_tools":[]}},{"part_kind":"file","content":{"data":"AA==","media_type":"image/png"}}]}]
    ;
    var owned = try parse(std.testing.allocator, source);
    owned.deinit();
}

test "codec rejects invalid envelopes, roles, discriminators, and typed payloads" {
    const invalid = [_][]const u8{
        "{}",
        "[{}]",
        "[{\"kind\":\"other\",\"parts\":[]}]",
        "[{\"kind\":\"request\",\"parts\":{}}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"text\",\"content\":\"no\"}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"speech\",\"speaker\":\"assistant\"}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"speech\",\"speaker\":\"user\"}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"file\",\"content\":\"no\"}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"user-prompt\",\"content\":[{\"kind\":\"unknown\"}]}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"user-prompt\",\"content\":[{\"kind\":\"image-url\",\"url\":\"https://example.com/a.png\",\"force_download\":1}]}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"speech\",\"speaker\":\"assistant\",\"interrupted_at_ms\":\"soon\"}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"tool-call\",\"tool_name\":\"tool\",\"args\":[]}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"tool-call\"}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"builtin-tool-call\",\"tool_kind\":\"capability-load\"}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"tool-return\",\"content\":\"ok\"}]}]",
        "[{\"kind\":\"response\",\"parts\":[{\"part_kind\":\"builtin-tool-return\",\"tool_kind\":\"capability-load\",\"content\":\"ok\"}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"retry-prompt\",\"content\":1}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"tool-availability-delta\",\"tools_added\":{}}]}]",
        "[{\"kind\":\"request\",\"parts\":[{\"part_kind\":\"retry-prompt\",\"content\":[{\"type\":\"x\",\"loc\":[true],\"msg\":\"bad\",\"input\":null}]}]}]",
        "[{\"kind\":\"response\",\"parts\":[],\"usage\":{\"input_tokens\":1.5}}]",
        "[{\"kind\":\"response\",\"parts\":[],\"usage\":{\"details\":{\"reasoning_tokens\":\"many\"}}}]",
        "[{\"kind\":\"request\",\"parts\":[],\"state\":\"unknown\"}]",
        "[{\"kind\":\"request\",\"parts\":[],\"kind\":\"request\"}]",
    };
    for (invalid) |source| try std.testing.expectError(error.InvalidMessages, parse(std.testing.allocator, source));
}

test "codec reports JSON boundaries and supports custom limits" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "["));
    try std.testing.expectError(error.InvalidMessages, parse(std.testing.allocator, "[{\"kind\":\"request\",\"kind\":\"request\",\"parts\":[]}]"));
    try std.testing.expectError(error.DocumentTooLarge, parseWithLimits(std.testing.allocator, "[]", .{
        .max_document_bytes = 1,
        .max_value_bytes = 8,
        .max_depth = 2,
        .max_collection_items = 2,
    }));
}

fn checkParseAllocations(gpa: std.mem.Allocator) !void {
    var owned = try parse(gpa, "[{\"kind\":\"request\",\"parts\":[]}]");
    owned.deinit();
}

test "parse releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParseAllocations, .{});
}
