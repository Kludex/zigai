//! A dependency-free Google Gemini GenerateContent API client.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

pub const api_base = "https://generativelanguage.googleapis.com/v1beta";

pub const Error = model_types.ProviderRequestError || error{
    /// A successful Gemini payload does not match GenerateContent.
    InvalidProviderResponse,
    /// Provider-neutral input cannot be encoded as a valid Gemini request.
    InvalidRequestEncoding,
};

pub const Client = struct {
    model_name: []const u8,
    api_key: []const u8,
    transport: http.Transport,
    base_url: []const u8 = api_base,
    settings: model_types.ModelSettings = .{},
    profile: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = true,
        .supports_system_messages = true,
        .supports_thinking = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
        .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initMany(&.{
            .minimal,
            .low,
            .medium,
            .high,
        }),
        .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .web_fetch }),
        .content_types = model_types.ModelProfile.ContentTypeSet.initFull(),
    },

    pub fn model(self: *Client) model_types.Model {
        return .{
            .context = self,
            .profile = self.profile,
            .provider_name = "gcp.gen_ai",
            .model_name = self.model_name,
            .settings = self.settings,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:generateContent", .{ self.base_url, self.model_name });
        defer allocator.free(url);
        const response = self.transport.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }) catch |failure| return common.transportError(failure);
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "google", response.status, response.body, response.metadata, value.error_policy);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body) catch |failure| return common.responseDecodeError(failure);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ self.base_url, self.model_name });
        defer allocator.free(url);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.parts.deinit(allocator);
        defer state.error_body.deinit(allocator);
        const response = self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink()) catch |failure| return common.transportError(failure);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "google", response.status, state.error_body.items, response.metadata, value.error_policy);
            return common.statusError(response.status);
        }
        return .{
            .parts = try state.parts.toOwnedSlice(allocator),
            .usage = state.usage,
            .finish_reason = state.finish_reason,
        };
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    parts: std.ArrayList(model_types.Part) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,

    fn lineSink(self: *StreamState) http.LineSink {
        return .{ .context = self, .startFn = start, .lineFn = line };
    }

    fn start(context: *anyopaque, response: http.StreamResponse) !void {
        const self: *StreamState = @ptrCast(@alignCast(context));
        self.status = response.status;
    }

    fn line(context: *anyopaque, value: []const u8) !void {
        const self: *StreamState = @ptrCast(@alignCast(context));
        if (self.status < 200 or self.status >= 300) {
            if (self.error_body.items.len > 0) try self.error_body.append(self.allocator, '\n');
            return self.error_body.appendSlice(self.allocator, value);
        }
        if (!std.mem.startsWith(u8, value, "data:")) return;
        const data = std.mem.trim(u8, value[5..], " ");
        if (data.len == 0) return;
        const chunk = try decodeResponse(self.allocator, data);
        defer self.allocator.free(chunk.parts);
        for (chunk.parts) |part| {
            try self.parts.append(self.allocator, part);
            switch (part) {
                .text => |text| try self.sink.emit(.{ .text_delta = text }),
                .tool_call => |call| try self.sink.emit(.{ .tool_call = call }),
                else => {},
            }
        }
        if (chunk.usage.input_tokens != 0 or chunk.usage.output_tokens != 0) {
            self.usage = chunk.usage;
            try self.sink.emit(.{ .usage = self.usage });
        }
        if (chunk.finish_reason != null) self.finish_reason = chunk.finish_reason;
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();

    var has_system = request.instructions.len > 0;
    for (request.messages) |message| switch (message) {
        .request => |request_message| for (request_message.parts) |part| if (part == .system_prompt) {
            has_system = true;
            break;
        },
        .response => {},
    };
    if (has_system) {
        try json.objectField("systemInstruction");
        try json.beginObject();
        try json.objectField("parts");
        try json.beginArray();
        for (request.messages) |message| switch (message) {
            .request => |request_message| for (request_message.parts) |part| switch (part) {
                .system_prompt => |text| try writeTextPart(&json, text),
                else => {},
            },
            .response => {},
        };
        for (request.instructions) |instruction| try writeTextPart(&json, instruction);
        try json.endArray();
        try json.endObject();
    }

    try json.objectField("contents");
    try json.beginArray();
    for (request.messages) |message| {
        if (!messageHasGoogleContent(message)) continue;
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message == .response) "model" else "user");
        try json.objectField("parts");
        try json.beginArray();
        switch (message) {
            .request => |request_message| for (request_message.parts) |part| switch (part) {
                .system_prompt => {},
                .retry_prompt => |text| try writeTextPart(&json, text),
                .user_prompt => |content| switch (content) {
                    .text => |text| try writeTextPart(&json, text),
                    .image => |value| try writeRichContent(allocator, &json, value),
                    .audio => |value| try writeRichContent(allocator, &json, value),
                    .document => |value| try writeRichContent(allocator, &json, value),
                    .binary => |value| try writeRichContent(allocator, &json, value),
                },
                .tool_return => |result| try writeToolReturn(allocator, &json, result),
            },
            .response => |response| for (response.parts) |part| switch (part) {
                .text => |text| try writeTextPart(&json, text),
                .image => |content| try writeRichContent(allocator, &json, content),
                .audio => |content| try writeRichContent(allocator, &json, content),
                .document => |content| try writeRichContent(allocator, &json, content),
                .binary => |content| try writeRichContent(allocator, &json, content),
                .thinking => |thinking| {
                    try json.beginObject();
                    try json.objectField("text");
                    try json.write(thinking.content);
                    try json.objectField("thought");
                    try json.write(true);
                    if (thinking.signature) |signature| {
                        try json.objectField("thoughtSignature");
                        try json.write(signature);
                    }
                    try json.endObject();
                },
                .tool_call => |call| {
                    try json.beginObject();
                    try json.objectField("functionCall");
                    try json.beginObject();
                    try json.objectField("name");
                    try json.write(call.name);
                    try json.objectField("args");
                    try common.rawJson(allocator, &json, call.arguments_json, json_limits.defaults.tool_payload);
                    try json.objectField("id");
                    try json.write(call.id);
                    try json.endObject();
                    if (call.thought_signature) |signature| {
                        try json.objectField("thoughtSignature");
                        try json.write(signature);
                    }
                    try json.endObject();
                },
            },
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    if (request.tools.len > 0 or request.builtin_tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        if (request.tools.len > 0) {
            try json.beginObject();
            try json.objectField("functionDeclarations");
            try json.beginArray();
            for (request.tools) |tool| {
                try json.beginObject();
                try json.objectField("name");
                try json.write(tool.name);
                try json.objectField("description");
                try json.write(tool.description);
                try json.objectField("parameters");
                try writeToolSchema(allocator, &json, tool.parameters_json_schema);
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        }
        for (request.builtin_tools) |tool| {
            try json.beginObject();
            try json.objectField(switch (tool) {
                .web_search => "googleSearch",
                .web_fetch => "urlContext",
            });
            try json.beginObject();
            try json.endObject();
            try json.endObject();
        }
        try json.endArray();
    }

    const schema = switch (request.output) {
        .json_schema => |format| format.schema,
        else => null,
    };
    const json_output = request.output != .text;
    if (json_output or hasGenerationSettings(request.settings)) {
        try writeGenerationConfig(allocator, &json, schema, json_output, request.settings);
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeToolSchema(allocator: std.mem.Allocator, json: *std.json.Stringify, source: []const u8) !void {
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.schema,
        .{},
        error.InvalidRequestEncoding,
    );
    defer parsed.deinit();
    return writeToolSchemaValue(json, parsed.value);
}

fn writeToolSchemaValue(json: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            try json.beginObject();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "additionalProperties")) continue;
                try json.objectField(entry.key_ptr.*);
                try writeToolSchemaValue(json, entry.value_ptr.*);
            }
            try json.endObject();
        },
        .array => |array| {
            try json.beginArray();
            for (array.items) |item| try writeToolSchemaValue(json, item);
            try json.endArray();
        },
        else => try json.write(value),
    }
}

fn messageHasGoogleContent(message: model_types.Message) bool {
    return switch (message) {
        .request => |request| blk: {
            for (request.parts) |part| if (part != .system_prompt) break :blk true;
            break :blk false;
        },
        .response => |response| response.parts.len > 0,
    };
}

fn writeToolReturn(allocator: std.mem.Allocator, json: *std.json.Stringify, result: model_types.ToolResult) !void {
    try json.beginObject();
    try json.objectField("functionResponse");
    try json.beginObject();
    try json.objectField("name");
    try json.write(result.name);
    try json.objectField("response");
    try json.beginObject();
    try json.objectField(if (result.is_error) "error" else "result");
    try common.rawJson(allocator, json, result.content, json_limits.defaults.tool_payload);
    try json.endObject();
    try json.objectField("id");
    try json.write(result.call_id);
    try json.endObject();
    try json.endObject();
}

fn writeTextPart(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("text");
    try json.write(text);
    try json.endObject();
}

fn writeRichContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    content: model_types.Content,
) !void {
    try json.beginObject();
    switch (content.source) {
        .bytes => |bytes| {
            const encoded = try common.base64Alloc(allocator, bytes);
            defer allocator.free(encoded);
            try json.objectField("inlineData");
            try json.beginObject();
            try json.objectField("mimeType");
            try json.write(content.media_type);
            try json.objectField("data");
            try json.write(encoded);
            try json.endObject();
        },
        .url => |url| {
            try json.objectField("fileData");
            try json.beginObject();
            try json.objectField("mimeType");
            try json.write(content.media_type);
            try json.objectField("fileUri");
            try json.write(url);
            try json.endObject();
        },
        .provider_file => |file| {
            try json.objectField("fileData");
            try json.beginObject();
            try json.objectField("mimeType");
            try json.write(content.media_type);
            try json.objectField("fileUri");
            try json.write(file.id);
            try json.endObject();
        },
    }
    if (content.thought_signature) |signature| {
        try json.objectField("thoughtSignature");
        try json.write(signature);
    }
    try json.endObject();
}

fn hasGenerationSettings(settings: model_types.ModelSettings) bool {
    return settings.temperature != null or settings.max_tokens != null or
        settings.stop_sequences != null or settings.seed != null or settings.reasoning_effort != null;
}

fn writeGenerationConfig(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    schema: ?[]const u8,
    json_output: bool,
    settings: model_types.ModelSettings,
) !void {
    try json.objectField("generationConfig");
    try json.beginObject();
    if (json_output) {
        try json.objectField("responseMimeType");
        try json.write("application/json");
    }
    if (schema) |value| {
        try json.objectField("responseJsonSchema");
        try common.rawJson(allocator, json, value, json_limits.defaults.schema);
    }
    if (settings.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }
    if (settings.max_tokens) |max_tokens| {
        try json.objectField("maxOutputTokens");
        try json.write(max_tokens);
    }
    if (settings.stop_sequences) |stop_sequences| {
        try json.objectField("stopSequences");
        try json.write(stop_sequences);
    }
    if (settings.seed) |seed| {
        try json.objectField("seed");
        try json.write(seed);
    }
    if (settings.reasoning_effort) |effort| {
        try json.objectField("thinkingConfig");
        try json.beginObject();
        try json.objectField("thinkingLevel");
        try json.write(switch (effort) {
            .minimal => "MINIMAL",
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
            else => unreachable,
        });
        try json.endObject();
    }
    try json.endObject();
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    );
    const root_object = switch (root) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const candidates = if (root_object.get("candidates")) |value| switch (value) {
        .array => |items| items,
        else => return error.InvalidProviderResponse,
    } else {
        const feedback = try common.requiredObject(root, "promptFeedback");
        const block_reason = try common.objectString(feedback, "blockReason");
        return .{ .parts = &.{}, .finish_reason = .{ .kind = .content_filter, .raw = block_reason } };
    };
    if (candidates.items.len == 0) {
        const feedback = try common.requiredObject(root, "promptFeedback");
        const block_reason = try common.objectString(feedback, "blockReason");
        return .{ .parts = &.{}, .finish_reason = .{ .kind = .content_filter, .raw = block_reason } };
    }
    const candidate = switch (candidates.items[0]) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    var finish_reason = if (try common.optionalObjectString(candidate, "finishReason")) |reason|
        googleFinishReason(reason)
    else
        null;
    var parts: std.ArrayList(model_types.Part) = .empty;
    if (candidate.get("content")) |content_value| {
        const parts_value = try common.requiredArray(content_value, "parts");
        for (parts_value.items, 0..) |part_value, index| {
            const object = switch (part_value) {
                .object => |value| value,
                else => return error.InvalidProviderResponse,
            };
            if (object.get("text")) |text_value| {
                const value = switch (text_value) {
                    .string => |text| text,
                    else => return error.InvalidProviderResponse,
                };
                const is_thought = if (object.get("thought")) |thought_value| switch (thought_value) {
                    .bool => |thought| thought,
                    else => return error.InvalidProviderResponse,
                } else false;
                if (is_thought) {
                    try parts.append(allocator, .{ .thinking = .{
                        .content = value,
                        .signature = try common.optionalObjectString(object, "thoughtSignature"),
                    } });
                } else try parts.append(allocator, .{ .text = value });
            } else if (object.get("inlineData")) |inline_value| {
                const inline_data = switch (inline_value) {
                    .object => |value| value,
                    else => return error.InvalidProviderResponse,
                };
                const content = model_types.Content{
                    .source = .{ .bytes = try common.base64DecodeAlloc(
                        allocator,
                        try common.objectString(inline_data, "data"),
                    ) },
                    .media_type = try common.objectString(inline_data, "mimeType"),
                    .thought_signature = try common.optionalObjectString(object, "thoughtSignature"),
                };
                try parts.append(allocator, richPart(content));
            } else if (object.get("fileData")) |file_value| {
                const file_data = switch (file_value) {
                    .object => |value| value,
                    else => return error.InvalidProviderResponse,
                };
                const content = model_types.Content{
                    .source = .{ .provider_file = .{
                        .id = try common.objectString(file_data, "fileUri"),
                        .provider = "gcp.gen_ai",
                    } },
                    .media_type = try common.objectString(file_data, "mimeType"),
                    .thought_signature = try common.optionalObjectString(object, "thoughtSignature"),
                };
                try parts.append(allocator, richPart(content));
            } else if (object.get("functionCall")) |call_value| {
                const call = switch (call_value) {
                    .object => |value| value,
                    else => return error.InvalidProviderResponse,
                };
                const args = call.get("args") orelse return error.InvalidProviderResponse;
                const id = if (call.get("id")) |id_value| switch (id_value) {
                    .string => |value| value,
                    else => return error.InvalidProviderResponse,
                } else try std.fmt.allocPrint(allocator, "google-call-{d}", .{index});
                try parts.append(allocator, .{ .tool_call = .{
                    .id = id,
                    .name = try common.objectString(call, "name"),
                    .arguments_json = try std.json.Stringify.valueAlloc(allocator, args, .{}),
                    .thought_signature = try common.optionalObjectString(object, "thoughtSignature"),
                } });
            }
        }
    } else if (finish_reason == null) return error.InvalidProviderResponse;

    var usage: model_types.Usage = .{};
    if (switch (root) {
        .object => |object| object.get("usageMetadata"),
        else => null,
    }) |usage_value| {
        const object = switch (usage_value) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        usage = .{
            .input_tokens = try common.objectInteger(object, "promptTokenCount"),
            .output_tokens = try common.objectInteger(object, "candidatesTokenCount"),
        };
    }
    if (finish_reason) |*reason| {
        if (reason.kind == .stop and hasToolCalls(parts.items)) reason.kind = .tool_calls;
    }
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage, .finish_reason = finish_reason };
}

fn richPart(content: model_types.Content) model_types.Part {
    if (std.mem.startsWith(u8, content.media_type, "image/")) return .{ .image = content };
    if (std.mem.startsWith(u8, content.media_type, "audio/")) return .{ .audio = content };
    if (std.mem.eql(u8, content.media_type, "application/pdf") or
        std.mem.startsWith(u8, content.media_type, "text/")) return .{ .document = content };
    return .{ .binary = content };
}

fn googleFinishReason(raw: []const u8) model_types.FinishReason {
    const kind: model_types.FinishReason.Kind = if (std.mem.eql(u8, raw, "STOP"))
        .stop
    else if (std.mem.eql(u8, raw, "MAX_TOKENS"))
        .length
    else if (std.mem.eql(u8, raw, "SAFETY") or
        std.mem.eql(u8, raw, "RECITATION") or
        std.mem.eql(u8, raw, "BLOCKLIST") or
        std.mem.eql(u8, raw, "PROHIBITED_CONTENT") or
        std.mem.eql(u8, raw, "SPII"))
        .content_filter
    else if (std.mem.eql(u8, raw, "MALFORMED_FUNCTION_CALL") or
        std.mem.eql(u8, raw, "UNEXPECTED_TOOL_CALL"))
        .incomplete_tool_call
    else
        .other;
    return .{ .kind = kind, .raw = raw };
}

fn hasToolCalls(parts: []const model_types.Part) bool {
    for (parts) |part| switch (part) {
        .tool_call => return true,
        else => {},
    };
    return false;
}

test "encodes Gemini system, tool, result, error, and structured output parts" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .system_prompt = "Be concise." }} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call_1",
            .name = "weather",
            .arguments_json = "{\"city\":\"Madrid\"}",
            .thought_signature = "signed-state",
        } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "call_1", .name = "weather", .content = "{\"message\":\"failed\"}", .is_error = true } }} } },
    };
    const body = try encodeRequest(std.testing.allocator, .{
        .messages = &messages,
        .instructions = &.{"Current instruction."},
        .tools = &.{.{
            .name = "weather",
            .description = "Get weather.",
            .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"additionalProperties\":false}},\"additionalProperties\":false}",
        }},
        .settings = .{
            .temperature = 0.6,
            .max_tokens = 256,
            .stop_sequences = &.{"STOP"},
            .seed = 7,
            .reasoning_effort = .medium,
        },
        .output = .{ .json_schema = .{ .name = "answer", .schema = "{\"type\":\"object\"}" } },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Current instruction.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionDeclarations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "additionalProperties") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thoughtSignature\":\"signed-state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error\":{\"message\":\"failed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"responseJsonSchema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"maxOutputTokens\":256") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stopSequences\":[\"STOP\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinkingConfig\":{\"thinkingLevel\":\"MEDIUM\"}") != null);

    const object_body = try encodeRequest(std.testing.allocator, .{ .messages = &.{}, .output = .json_object });
    defer std.testing.allocator.free(object_body);
    try std.testing.expect(std.mem.indexOf(u8, object_body, "\"responseMimeType\":\"application/json\"") != null);
}

test "encodes Gemini Google Search and URL Context tools" {
    const body = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .builtin_tools = &.{
            .{ .web_search = .{} },
            .{ .web_fetch = .{} },
        },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"googleSearch\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"urlContext\":{}") != null);
}

test "encodes and decodes Gemini rich content and thinking" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .retry_prompt = "Try again." },
            .{ .user_prompt = .{ .text = "Review these." } },
            .{ .user_prompt = .{ .image = .{ .source = .{ .bytes = "png" }, .media_type = "image/png" } } },
            .{ .user_prompt = .{ .audio = .{ .source = .{ .bytes = "mp3" }, .media_type = "audio/mpeg" } } },
            .{ .user_prompt = .{ .document = .{
                .source = .{ .provider_file = .{ .id = "files/guide", .provider = "gcp.gen_ai" } },
                .media_type = "application/pdf",
            } } },
            .{ .user_prompt = .{ .document = .{
                .source = .{ .url = "https://example.test/guide.pdf" },
                .media_type = "application/pdf",
                .thought_signature = "document-signed",
            } } },
            .{ .user_prompt = .{ .binary = .{ .source = .{ .bytes = "raw" }, .media_type = "application/octet-stream" } } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text = "Previous answer." },
            .{ .image = .{ .source = .{ .bytes = "answer-image" }, .media_type = "image/png" } },
            .{ .audio = .{ .source = .{ .bytes = "answer-audio" }, .media_type = "audio/mpeg" } },
            .{ .document = .{ .source = .{ .url = "https://example.test/answer.pdf" }, .media_type = "application/pdf" } },
            .{ .binary = .{ .source = .{ .bytes = "answer-binary" }, .media_type = "application/octet-stream" } },
            .{ .thinking = .{ .content = "private", .signature = "signed" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"inlineData\":{\"mimeType\":\"audio/mpeg\",\"data\":\"bXAz\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"fileData\":{\"mimeType\":\"application/pdf\",\"fileUri\":\"files/guide\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"fileUri\":\"https://example.test/guide.pdf\"},\"thoughtSignature\":\"document-signed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"inlineData\":{\"mimeType\":\"application/octet-stream\",\"data\":\"cmF3\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"private\",\"thought\":true,\"thoughtSignature\":\"signed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Previous answer.") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"private\",\"thought\":true,\"thoughtSignature\":\"signed\"},{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"cG5n\"},\"thoughtSignature\":\"image-signed\"},{\"fileData\":{\"mimeType\":\"audio/mpeg\",\"fileUri\":\"files/audio\"}},{\"fileData\":{\"mimeType\":\"application/pdf\",\"fileUri\":\"files/pdf\"}},{\"fileData\":{\"mimeType\":\"application/octet-stream\",\"fileUri\":\"files/raw\"}}]},\"finishReason\":\"STOP\"}]}",
    );
    try std.testing.expectEqualStrings("private", response.parts[0].thinking.content);
    try std.testing.expectEqualStrings("signed", response.parts[0].thinking.signature.?);
    try std.testing.expectEqualSlices(u8, "png", response.parts[1].image.source.bytes);
    try std.testing.expectEqualStrings("image-signed", response.parts[1].image.thought_signature.?);
    try std.testing.expectEqualStrings("files/audio", response.parts[2].audio.source.provider_file.id);
    try std.testing.expectEqualStrings("files/pdf", response.parts[3].document.source.provider_file.id);
    try std.testing.expectEqualStrings("files/raw", response.parts[4].binary.source.provider_file.id);
}

test "decodes Gemini text, calls with and without ids, and usage" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"checking"},{"functionCall":{"id":"call_1","name":"weather","args":{"city":"Madrid"}},"thoughtSignature":"signed-state"},{"functionCall":{"name":"other","args":{}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 3), response.parts.len);
    try std.testing.expectEqualStrings("checking", response.parts[0].text);
    try std.testing.expectEqualStrings("call_1", response.parts[1].tool_call.id);
    try std.testing.expectEqualStrings("signed-state", response.parts[1].tool_call.thought_signature.?);
    try std.testing.expectEqualStrings("google-call-2", response.parts[2].tool_call.id);
    try std.testing.expectEqual(@as(u64, 8), response.usage.input_tokens);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
    try std.testing.expectEqualStrings("STOP", response.finish_reason.?.raw);
}

test "maps Gemini safety and malformed call reasons" {
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, googleFinishReason("SAFETY").kind);
    try std.testing.expectEqual(
        model_types.FinishReason.Kind.incomplete_tool_call,
        googleFinishReason("MALFORMED_FUNCTION_CALL").kind,
    );
}

test "decodes blocked Gemini prompts without candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"promptFeedback\":{\"blockReason\":\"PROHIBITED_CONTENT\"}}",
    );
    try std.testing.expectEqual(@as(usize, 0), response.parts.len);
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, response.finish_reason.?.kind);
    try std.testing.expectEqualStrings("PROHIBITED_CONTENT", response.finish_reason.?.raw);
    const empty = try decodeResponse(
        arena.allocator(),
        "{\"candidates\":[],\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}",
    );
    try std.testing.expectEqualStrings("SAFETY", empty.finish_reason.?.raw);
}

test "rejects malformed Gemini responses" {
    const invalid = [_][]const u8{
        "{\"candidates\":[]}",
        "{\"candidates\":[false]}",
        "{\"candidates\":[{}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[false]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":false}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\",\"thought\":1}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":false}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"fileData\":false}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":false}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"x\"}}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":false,\"name\":\"x\",\"args\":{}}}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[]}}],\"usageMetadata\":false}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), body));
    }
}

test "Google rejects provider responses beyond the JSON nesting limit" {
    const source = "[" ** 129 ++ "0" ++ "]" ** 129;
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(std.testing.allocator, source));
}
