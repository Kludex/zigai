//! Amazon Bedrock Converse JSON wire adapter.
//!
//! This adapter is buffered. ConverseStream uses binary AWS EventStream
//! frames, not the line-oriented streaming contract exposed by `Provider`.

const std = @import("std");
const model_types = @import("../../model.zig");
const provider_types = @import("../../provider.zig");
const transport = @import("../../transport.zig");
const common = @import("../common.zig");
const json_limits = @import("../../json.zig");
const profiles = @import("../profiles.zig");

pub const Error = model_types.ProviderRequestError || error{
    InvalidProviderResponse,
    InvalidRequestEncoding,
    UnsupportedContentType,
    UnsupportedOutputMode,
};

pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    settings: model_types.ModelSettings = .{},
    profile: model_types.ModelProfile = .{
        .supports_tools = false,
        .supports_parallel_tool_calls = false,
        .supports_json_schema_output = false,
        .supports_json_object_output = false,
        .supports_system_messages = true,
        .supports_streaming = false,
        .supports_max_tokens = true,
        .supports_request_headers = true,
        .extra_body_kind = .bedrock,
    },

    pub fn model(self: *Client) model_types.Model {
        return .{
            .context = self,
            .profile = self.provider.modelProfile(self.model_name, self.profile),
            .provider_name = self.provider.name,
            .model_name = self.model_name,
            .settings = self.settings,
            .requestFn = request,
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, value);
        defer allocator.free(body);
        const endpoint = try converseEndpoint(allocator, self.model_name);
        defer allocator.free(endpoint);
        var headers: std.ArrayList(transport.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        const response = self.provider.request(allocator, .{
            .method = .POST,
            .endpoint = endpoint,
            .headers = headers.items,
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
            .url_policy = value.url_policy,
        }) catch |failure| return common.transportError(failure);
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            self.provider.observeError(
                allocator,
                response.status,
                response.body,
                response.metadata,
                value.error_observer,
                value.error_policy,
            );
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body) catch |failure| return common.responseDecodeError(failure);
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try rejectUnsupportedSettings(request.settings);
    if (request.builtin_tools.len > 0) return error.UnsupportedContentType;
    try common.validateToolChoice(request.tools, 0, request.settings.tool_choice);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try writeSystem(&json, request);
    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| {
        if (!messageHasContent(message)) continue;
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message == .response) "assistant" else "user");
        try json.objectField("content");
        try json.beginArray();
        try writeMessageContent(allocator, &json, message);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try writeInferenceConfig(&json, request.settings);
    try writeToolConfig(allocator, &json, request);
    try writeOutputConfig(allocator, &json, request.output);
    try writeServiceTier(&json, request.settings.service_tier);
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        .bedrock,
        &.{ "system", "messages", "inferenceConfig", "toolConfig", "outputConfig", "serviceTier" },
    );
    try json.endObject();
    return output.toOwnedSlice();
}

fn rejectUnsupportedSettings(settings: model_types.ModelSettings) !void {
    if (settings.seed != null or settings.reasoning_effort != null or settings.top_k != null or
        settings.presence_penalty != null or settings.frequency_penalty != null or
        settings.logprobs != null or settings.parallel_tool_calls != null or
        settings.thinking_budget_tokens != null or settings.truncation != null)
        return error.InvalidRequestEncoding;
}

fn writeSystem(json: *std.json.Stringify, request: model_types.ModelRequest) !void {
    var any = request.instructions.len > 0;
    for (request.messages) |message| switch (message) {
        .request => |value| for (value.parts) |part| switch (part) {
            .system_prompt, .system_prompt_part => any = true,
            else => {},
        },
        .response => {},
    };
    if (!any) return;
    try json.objectField("system");
    try json.beginArray();
    for (request.messages) |message| switch (message) {
        .request => |value| for (value.parts) |part| switch (part) {
            .system_prompt => |text| try writeText(json, text),
            .system_prompt_part => |prompt| try writeText(json, prompt.content),
            else => {},
        },
        .response => {},
    };
    for (request.instructions) |instruction| try writeText(json, instruction);
    try json.endArray();
}

fn messageHasContent(message: model_types.Message) bool {
    return switch (message) {
        .request => |value| blk: {
            for (value.parts) |part| switch (part) {
                .system_prompt, .system_prompt_part => {},
                else => break :blk true,
            };
            break :blk false;
        },
        .response => |value| value.parts.len > 0,
    };
}

fn writeMessageContent(allocator: std.mem.Allocator, json: *std.json.Stringify, message: model_types.Message) !void {
    switch (message) {
        .request => |value| for (value.parts) |part| switch (part) {
            .system_prompt, .system_prompt_part => {},
            .user_prompt => |content| try writeUserContent(json, content),
            .user_prompt_part => |prompt| try writeUserContent(json, prompt.content),
            .retry_prompt => |text| try writeText(json, text),
            .retry_prompt_part => |prompt| try writeText(json, prompt.content),
            .tool_return => |result| try writeToolResult(allocator, json, result),
            .capability_load_return => |result| try writeToolResult(allocator, json, common.capabilityLoadToolResult(result)),
            .speech => |speech| if (speech.transcript) |text| try writeText(json, text) else return error.UnsupportedContentType,
            .tool_search_return, .tool_availability_delta => return error.UnsupportedContentType,
        },
        .response => |value| for (value.parts) |part| switch (part) {
            .text => |text| try writeText(json, text),
            .text_part => |text| {
                try ensureReplayable(text.provider);
                try writeText(json, text.content);
            },
            .tool_call => |call| try writeToolUse(allocator, json, call),
            .capability_load_call => |call| {
                const portable = try common.capabilityLoadToolCall(allocator, call);
                defer allocator.free(portable.arguments_json);
                try writeToolUse(allocator, json, portable);
            },
            .thinking => |thinking| try writeThinking(json, thinking),
            .speech => |speech| {
                try ensureReplayable(speech.provider);
                if (speech.transcript) |text| try writeText(json, text) else return error.UnsupportedContentType;
            },
            .image,
            .audio,
            .video,
            .document,
            .binary,
            .tool_search_call,
            .native_tool_search_call,
            .native_tool_call,
            .native_tool_search_return,
            .native_tool_return,
            .compaction,
            => return error.UnsupportedContentType,
        },
    }
}

fn writeUserContent(json: *std.json.Stringify, content: model_types.UserContent) !void {
    switch (content) {
        .text => |text| try writeText(json, text),
        .text_content => |text| try writeText(json, text.content),
        .cache_point => {},
        .image, .audio, .video, .document, .binary, .uploaded_file => return error.UnsupportedContentType,
    }
}

fn writeText(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("text");
    try json.write(text);
    try json.endObject();
}

fn writeToolUse(allocator: std.mem.Allocator, json: *std.json.Stringify, call: model_types.ToolCall) !void {
    try ensureReplayable(call.provider);
    if (call.thought_signature != null) return error.UnsupportedContentType;
    if (!validToolIdentifier(call.id) or !validToolIdentifier(call.name)) return error.InvalidRequestEncoding;
    try json.beginObject();
    try json.objectField("toolUse");
    try json.beginObject();
    try json.objectField("toolUseId");
    try json.write(call.id);
    try json.objectField("name");
    try json.write(call.name);
    try json.objectField("input");
    try common.rawJson(allocator, json, call.arguments_json, json_limits.defaults.tool_payload);
    try json.endObject();
    try json.endObject();
}

fn writeToolResult(allocator: std.mem.Allocator, json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len > 0) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("toolResult");
    try json.beginObject();
    try json.objectField("toolUseId");
    try json.write(result.call_id);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    const parsed = json_limits.parse(
        std.json.Value,
        allocator,
        result.content,
        json_limits.defaults.tool_payload,
        .{},
        error.InvalidRequestEncoding,
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return failure,
        else => null,
    };
    if (parsed) |document| {
        defer document.deinit();
        try json.objectField("json");
        try json.write(document.value);
    } else {
        try json.objectField("text");
        try json.write(result.content);
    }
    try json.endObject();
    try json.endArray();
    if (result.isError()) {
        try json.objectField("status");
        try json.write("error");
    }
    try json.endObject();
    try json.endObject();
}

fn writeThinking(json: *std.json.Stringify, thinking: model_types.Thinking) !void {
    if (thinking.provider.provider_details) |details| {
        if (thinking.provider.provider_name) |name| if (!std.mem.eql(u8, name, "bedrock"))
            return error.UnsupportedContentType;
        try json.beginObject();
        try json.objectField("reasoningContent");
        try json.write(details.value);
        try json.endObject();
        return;
    }
    if (thinking.provider.id != null) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("reasoningContent");
    try json.beginObject();
    try json.objectField("reasoningText");
    try json.beginObject();
    try json.objectField("text");
    try json.write(thinking.content);
    if (thinking.signature) |signature| {
        try json.objectField("signature");
        try json.write(signature);
    }
    try json.endObject();
    try json.endObject();
    try json.endObject();
}

fn ensureReplayable(provider: model_types.ProviderPart) !void {
    if (provider.requiresReplay()) return error.UnsupportedContentType;
}

fn writeInferenceConfig(json: *std.json.Stringify, settings: model_types.ModelSettings) !void {
    if (settings.max_tokens == null and settings.temperature == null and settings.stop_sequences == null and settings.top_p == null)
        return;
    try json.objectField("inferenceConfig");
    try json.beginObject();
    if (settings.max_tokens) |value| {
        try json.objectField("maxTokens");
        try json.write(value);
    }
    if (settings.temperature) |value| {
        if (value < 0 or value > 1) return error.InvalidRequestEncoding;
        try json.objectField("temperature");
        try json.write(value);
    }
    if (settings.top_p) |value| {
        try json.objectField("topP");
        try json.write(value);
    }
    if (settings.stop_sequences) |value| {
        try json.objectField("stopSequences");
        try json.write(value);
    }
    try json.endObject();
}

fn writeToolConfig(allocator: std.mem.Allocator, json: *std.json.Stringify, request: model_types.ModelRequest) !void {
    if (request.tools.len == 0) return;
    if (request.settings.tool_choice) |choice| switch (choice) {
        .none => return,
        else => {},
    };
    try json.objectField("toolConfig");
    try json.beginObject();
    try json.objectField("tools");
    try json.beginArray();
    for (request.tools) |tool| {
        if (!common.toolIncluded(request.settings.tool_choice, tool.name)) continue;
        if (!validToolIdentifier(tool.name)) return error.InvalidRequestEncoding;
        try json.beginObject();
        try json.objectField("toolSpec");
        try json.beginObject();
        try json.objectField("name");
        try json.write(tool.name);
        try json.objectField("description");
        const description = try common.toolDescription(allocator, tool);
        defer if (description) |owned| allocator.free(owned);
        try json.write(description orelse tool.description);
        try json.objectField("inputSchema");
        try json.beginObject();
        try json.objectField("json");
        try common.rawJson(allocator, json, tool.parameters_json_schema, json_limits.defaults.schema);
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
    if (request.settings.tool_choice) |choice| switch (choice) {
        .none, .allowed => {},
        .auto => try writeToolChoice(json, "auto", null),
        .required => try writeToolChoice(json, "any", null),
        .tool => |name| try writeToolChoice(json, "tool", name),
    };
    try json.endObject();
}

fn writeToolChoice(json: *std.json.Stringify, kind: []const u8, name: ?[]const u8) !void {
    try json.objectField("toolChoice");
    try json.beginObject();
    try json.objectField(kind);
    try json.beginObject();
    if (name) |value| {
        try json.objectField("name");
        try json.write(value);
    }
    try json.endObject();
    try json.endObject();
}

fn writeOutputConfig(allocator: std.mem.Allocator, json: *std.json.Stringify, output: model_types.OutputFormat) !void {
    switch (output) {
        .text => {},
        .json_object => return error.UnsupportedOutputMode,
        .json_schema => |format| {
            if (!validToolIdentifier(format.name)) return error.InvalidRequestEncoding;
            try json_limits.validateAs(
                allocator,
                format.schema,
                json_limits.defaults.schema,
                error.InvalidRequestEncoding,
            );
            try json.objectField("outputConfig");
            try json.beginObject();
            try json.objectField("textFormat");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_schema");
            try json.objectField("structure");
            try json.beginObject();
            try json.objectField("jsonSchema");
            try json.beginObject();
            try json.objectField("schema");
            try json.write(format.schema);
            try json.objectField("name");
            try json.write(format.name);
            try json.endObject();
            try json.endObject();
            try json.endObject();
            try json.endObject();
        },
    }
}

fn writeServiceTier(json: *std.json.Stringify, tier: ?model_types.ServiceTier) !void {
    const value = tier orelse return;
    if (value == .auto) return;
    try json.objectField("serviceTier");
    try json.beginObject();
    try json.objectField("type");
    try json.write(switch (value) {
        .auto => unreachable,
        .default => "default",
        .flex => "flex",
        .priority => "priority",
    });
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
    const output = try common.requiredObject(root, "output");
    const message = try common.requiredObject(.{ .object = output }, "message");
    if (!std.mem.eql(u8, try common.objectString(message, "role"), "assistant"))
        return error.InvalidProviderResponse;
    const content = try common.requiredArray(.{ .object = message }, "content");
    var parts: std.ArrayList(model_types.Part) = .empty;
    for (content.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        const recognized = @as(usize, @intFromBool(object.get("text") != null)) +
            @as(usize, @intFromBool(object.get("toolUse") != null)) +
            @as(usize, @intFromBool(object.get("reasoningContent") != null));
        if (recognized != 1) return error.InvalidProviderResponse;
        if (try common.optionalObjectString(object, "text")) |text| {
            try parts.append(allocator, .{ .text = text });
        } else if (object.get("toolUse")) |tool_value| {
            const tool = switch (tool_value) {
                .object => |value| value,
                else => return error.InvalidProviderResponse,
            };
            const id = try common.objectString(tool, "toolUseId");
            const name = try common.objectString(tool, "name");
            if (!validToolIdentifier(id) or !validToolIdentifier(name)) return error.InvalidProviderResponse;
            const input = tool.get("input") orelse return error.InvalidProviderResponse;
            try parts.append(allocator, .{ .tool_call = .{
                .id = id,
                .name = name,
                .arguments_json = try std.json.Stringify.valueAlloc(allocator, input, .{}),
            } });
        } else if (object.get("reasoningContent")) |reasoning_value| {
            try parts.append(allocator, .{ .thinking = try decodeReasoning(reasoning_value) });
        } else {
            return error.InvalidProviderResponse;
        }
    }
    const root_object = switch (root) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const usage: model_types.RequestUsage = if (root_object.get("usage")) |value| try decodeUsage(value) else .{};
    const finish_reason = if (try common.optionalObjectString(root_object, "stopReason")) |value|
        bedrockFinishReason(value)
    else
        null;
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage, .finish_reason = finish_reason };
}

fn decodeReasoning(value: std.json.Value) !model_types.Thinking {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidProviderResponse,
    };
    const recognized = @as(usize, @intFromBool(object.get("reasoningText") != null)) +
        @as(usize, @intFromBool(object.get("redactedContent") != null));
    if (recognized != 1) return error.InvalidProviderResponse;
    if (object.get("reasoningText")) |reasoning_value| {
        const reasoning = switch (reasoning_value) {
            .object => |entry| entry,
            else => return error.InvalidProviderResponse,
        };
        return .{
            .content = try common.objectString(reasoning, "text"),
            .signature = try common.optionalObjectString(reasoning, "signature"),
            .provider = .{ .provider_name = "bedrock" },
        };
    }
    _ = try common.objectString(object, "redactedContent");
    return .{
        .content = "",
        .provider = .{
            .provider_name = "bedrock",
            .provider_details = try model_types.ProviderDetails.fromValue(value),
        },
    };
}

fn decodeUsage(value: std.json.Value) !model_types.RequestUsage {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidProviderResponse,
    };
    const uncached = try common.objectInteger(object, "inputTokens");
    const cache_read = try common.optionalObjectInteger(object, "cacheReadInputTokens") orelse 0;
    const cache_write = try common.optionalObjectInteger(object, "cacheWriteInputTokens") orelse 0;
    const cached = std.math.add(u64, cache_read, cache_write) catch return error.InvalidProviderResponse;
    return .{
        .input_tokens = std.math.add(u64, uncached, cached) catch return error.InvalidProviderResponse,
        .cache_read_tokens = cache_read,
        .cache_write_tokens = cache_write,
        .output_tokens = try common.objectInteger(object, "outputTokens"),
    };
}

fn bedrockFinishReason(raw: []const u8) model_types.FinishReason {
    const kind: model_types.FinishReason.Kind = if (std.mem.eql(u8, raw, "end_turn") or
        std.mem.eql(u8, raw, "stop_sequence"))
        .stop
    else if (std.mem.eql(u8, raw, "tool_use"))
        .tool_calls
    else if (std.mem.eql(u8, raw, "max_tokens") or std.mem.eql(u8, raw, "model_context_window_exceeded"))
        .length
    else if (std.mem.eql(u8, raw, "guardrail_intervened") or std.mem.eql(u8, raw, "content_filtered"))
        .content_filter
    else if (std.mem.eql(u8, raw, "malformed_tool_use") or std.mem.eql(u8, raw, "malformed_model_output"))
        .incomplete_tool_call
    else
        .other;
    return .{ .kind = kind, .raw = raw };
}

fn converseEndpoint(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    if (model_name.len == 0) return error.InvalidRequestEncoding;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("/model/");
    try writePathSegment(&output.writer, model_name);
    try output.writer.writeAll("/converse");
    return output.toOwnedSlice();
}

fn validToolIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
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

test "encodes Converse instructions tools settings output and extensions" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt = "Be concise." },
            .{ .user_prompt = .{ .text = "Weather?" } },
        } } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call_1",
            .name = "weather",
            .arguments_json = "{\"city\":\"Madrid\"}",
        } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call_1",
            .name = "weather",
            .content = "{\"temp\":31}",
        } }} } },
    };
    const body = try encodeRequest(std.testing.allocator, .{
        .messages = &messages,
        .instructions = &.{"Use Celsius."},
        .tools = &.{.{
            .name = "weather",
            .description = "Get weather.",
            .parameters_json_schema = "{\"type\":\"object\"}",
        }},
        .output = .{ .json_schema = .{
            .name = "forecast",
            .schema = "{\"type\":\"object\"}",
        } },
        .settings = .{
            .max_tokens = 128,
            .temperature = 0.2,
            .top_p = 0.9,
            .stop_sequences = &.{"END"},
            .tool_choice = .required,
            .service_tier = .priority,
            .extra_body = .{ .bedrock = "{\"requestMetadata\":{\"tenant\":\"test\"}}" },
        },
    });
    defer std.testing.allocator.free(body);
    for ([_][]const u8{
        "\"system\":[{\"text\":\"Be concise.\"},{\"text\":\"Use Celsius.\"}]",
        "\"toolUseId\":\"call_1\"",
        "\"json\":{\"temp\":31}",
        "\"maxTokens\":128",
        "\"toolChoice\":{\"any\":{}}",
        "\"jsonSchema\":{\"schema\":\"{\\\"type\\\":\\\"object\\\"}\",\"name\":\"forecast\"}",
        "\"serviceTier\":{\"type\":\"priority\"}",
        "\"requestMetadata\":{\"tenant\":\"test\"}",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
}

test "decodes Converse text tools reasoning usage and stop reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[" ++
            "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"think\",\"signature\":\"sig\"}}}," ++
            "{\"text\":\"Use a coat.\"}," ++
            "{\"toolUse\":{\"toolUseId\":\"call_1\",\"name\":\"weather\",\"input\":{\"city\":\"Madrid\"}}}" ++
            "]}},\"stopReason\":\"tool_use\",\"usage\":{\"inputTokens\":10,\"cacheReadInputTokens\":3,\"cacheWriteInputTokens\":2,\"outputTokens\":4,\"totalTokens\":19}}",
    );
    try std.testing.expectEqual(@as(usize, 3), response.parts.len);
    try std.testing.expectEqualStrings("think", response.parts[0].thinking.content);
    try std.testing.expectEqualStrings("sig", response.parts[0].thinking.signature.?);
    try std.testing.expectEqualStrings("Use a coat.", response.parts[1].text);
    try std.testing.expectEqualStrings("{\"city\":\"Madrid\"}", response.parts[2].tool_call.arguments_json);
    try std.testing.expectEqual(@as(u64, 15), response.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), response.usage.cache_read_tokens);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);

    inline for (.{
        .{ "end_turn", model_types.FinishReason.Kind.stop },
        .{ "max_tokens", model_types.FinishReason.Kind.length },
        .{ "guardrail_intervened", model_types.FinishReason.Kind.content_filter },
        .{ "malformed_tool_use", model_types.FinishReason.Kind.incomplete_tool_call },
        .{ "future_reason", model_types.FinishReason.Kind.other },
    }) |entry| try std.testing.expectEqual(entry[1], bedrockFinishReason(entry[0]).kind);
}

test "replays redacted Converse reasoning through provider details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"redactedContent\":\"AA==\"}}]}}}",
    );
    const replay = try encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = response }},
    });
    defer std.testing.allocator.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, "\"reasoningContent\":{\"redactedContent\":\"AA==\"}") != null);
}

test "Converse endpoint encodes arbitrary model identifiers" {
    const endpoint = try converseEndpoint(std.testing.allocator, "arn:aws:bedrock/model name");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("/model/arn%3Aaws%3Abedrock%2Fmodel%20name/converse", endpoint);
    try std.testing.expectError(error.InvalidRequestEncoding, converseEndpoint(std.testing.allocator, ""));
}

test "encodes detailed portable message forms" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt_part = .{ .content = "System detail." } },
            .{ .user_prompt_part = .{ .content = .{ .text_content = .{ .content = "User detail." } } } },
            .{ .retry_prompt = "Retry compact." },
            .{ .retry_prompt_part = .{ .content = "Retry detail." } },
            .{ .capability_load_return = .{ .call_id = "load_1", .instructions = "Use maps." } },
            .{ .speech = .{ .speaker = .user, .transcript = "Spoken input." } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text = "Compact response." },
            .{ .text_part = .{ .content = "Detailed response." } },
            .{ .capability_load_call = .{ .call_id = "load_1", .capability_id = "maps" } },
            .{ .thinking = .{ .content = "Reasoning.", .signature = "signed" } },
            .{ .speech = .{ .speaker = .assistant, .transcript = "Spoken response." } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    for ([_][]const u8{
        "System detail.",
        "User detail.",
        "Retry compact.",
        "Retry detail.",
        "load_capability",
        "Use maps.",
        "Spoken input.",
        "Compact response.",
        "Detailed response.",
        "Reasoning.",
        "signed",
        "Spoken response.",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
}

test "encodes Converse tool results choices schemas and tiers" {
    const tool = model_types.ToolDefinition{
        .name = "weather",
        .description = "Weather",
        .parameters_json_schema = "{\"type\":\"object\"}",
        .return_json_schema = "{\"type\":\"object\"}",
        .return_schema_visibility = .model_description,
    };
    inline for (.{
        .{ model_types.ToolChoice.auto, "\"toolChoice\":{\"auto\":{}}" },
        .{ model_types.ToolChoice.required, "\"toolChoice\":{\"any\":{}}" },
        .{ model_types.ToolChoice{ .tool = "weather" }, "\"toolChoice\":{\"tool\":{\"name\":\"weather\"}}" },
    }) |entry| {
        const body = try encodeRequest(std.testing.allocator, .{
            .messages = &.{},
            .tools = &.{tool},
            .settings = .{ .tool_choice = entry[0] },
        });
        defer std.testing.allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, entry[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "Return JSON Schema") != null);
    }

    const without_tools = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .tools = &.{tool},
        .settings = .{ .tool_choice = .none },
    });
    defer std.testing.allocator.free(without_tools);
    try std.testing.expect(std.mem.indexOf(u8, without_tools, "toolConfig") == null);

    const results = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call_text",
            .name = "weather",
            .content = "not JSON",
        } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call_error",
            .name = "weather",
            .content = "failed",
            .outcome = .failed,
        } }} } },
    };
    const result_body = try encodeRequest(std.testing.allocator, .{ .messages = &results });
    defer std.testing.allocator.free(result_body);
    try std.testing.expect(std.mem.indexOf(u8, result_body, "\"text\":\"not JSON\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_body, "\"status\":\"error\"") != null);

    inline for (.{ model_types.ServiceTier.default, .flex, .priority }) |tier| {
        const body = try encodeRequest(std.testing.allocator, .{
            .messages = &.{},
            .settings = .{ .service_tier = tier },
        });
        defer std.testing.allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, @tagName(tier)) != null);
    }
    const automatic = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .settings = .{ .service_tier = .auto },
    });
    defer std.testing.allocator.free(automatic);
    try std.testing.expect(std.mem.indexOf(u8, automatic, "serviceTier") == null);
}

test "validates Converse output settings and tool identifiers" {
    const valid = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .output = .{ .json_schema = .{ .name = "result", .schema = "{\"type\":\"object\"}" } },
    });
    defer std.testing.allocator.free(valid);
    try std.testing.expect(std.mem.indexOf(u8, valid, "outputConfig") != null);

    try std.testing.expectError(error.UnsupportedOutputMode, encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .output = .json_object,
    }));
    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .output = .{ .json_schema = .{ .name = "bad name", .schema = "{}" } },
    }));
    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .output = .{ .json_schema = .{ .name = "result", .schema = "not-json" } },
    }));

    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "bad id",
            .name = "weather",
            .arguments_json = "{}",
        } }} } }},
    }));
    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call_1",
            .name = "bad name",
            .arguments_json = "{}",
        } }} } }},
    }));
    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .tools = &.{.{
            .name = "bad name",
            .description = "Bad",
            .parameters_json_schema = "{}",
        }},
    }));
    inline for (.{ @as(f64, -0.1), 1.1 }) |temperature| try std.testing.expectError(
        error.InvalidRequestEncoding,
        encodeRequest(std.testing.allocator, .{
            .messages = &.{},
            .settings = .{ .temperature = temperature },
        }),
    );
}

test "rejects unsupported Converse history forms" {
    const rich = model_types.Content{ .source = .{ .bytes = "data" }, .media_type = "image/png" };
    const unsupported = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .speech = .{ .speaker = .user } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_search_return = .{ .call_id = "search", .discovered_tools = &.{} } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_availability_delta = .{ .tools_added = &.{"weather"} } }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .image = rich } }} } },
        .{ .response = .{ .parts = &.{.{ .text_part = .{ .content = "bound", .provider = .{ .id = "item" } } }} } },
        .{ .response = .{ .parts = &.{.{ .speech = .{ .speaker = .assistant } }} } },
        .{ .response = .{ .parts = &.{.{ .image = rich }} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call_1",
            .name = "weather",
            .arguments_json = "{}",
            .thought_signature = "foreign",
        } }} } },
    };
    for (unsupported) |message| try std.testing.expectError(
        error.UnsupportedContentType,
        encodeRequest(std.testing.allocator, .{ .messages = &.{message} }),
    );
}

test "replays and validates Converse reasoning" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"redactedContent\":\"AA==\"}", .{});
    defer parsed.deinit();
    const details = try model_types.ProviderDetails.fromValue(parsed.value);
    const replay = try encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = .{ .parts = &.{.{ .thinking = .{
            .content = "",
            .provider = .{ .provider_name = "bedrock", .provider_details = details },
        } }} } }},
    });
    defer std.testing.allocator.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, "redactedContent") != null);

    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = .{ .parts = &.{.{ .thinking = .{
            .content = "",
            .provider = .{ .provider_name = "anthropic", .provider_details = details },
        } }} } }},
    }));
    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(std.testing.allocator, .{
        .messages = &.{.{ .response = .{ .parts = &.{.{ .thinking = .{
            .content = "reason",
            .provider = .{ .id = "reasoning-item" },
        } }} } }},
    }));
}

test "rejects malformed Converse responses and decodes all terminal reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{}",
        "{\"output\":{\"message\":{\"role\":\"user\",\"content\":[]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[null]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"x\",\"toolUse\":{}}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"toolUse\":null}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"toolUse\":{\"toolUseId\":\"bad id\",\"name\":\"tool\",\"input\":{}}}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":null}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{}}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"reasoningText\":null}}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"reasoningText\":{\"text\":\"x\"},\"redactedContent\":\"AA==\"}}]}}}",
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[]}},\"usage\":null}",
    }) |body| try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), body));

    const redacted = try decodeResponse(
        arena.allocator(),
        "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"redactedContent\":\"AA==\"}}]}}}",
    );
    try std.testing.expectEqualStrings("", redacted.parts[0].thinking.content);
    try std.testing.expect(redacted.parts[0].thinking.provider.provider_details != null);

    inline for (.{
        .{ "stop_sequence", model_types.FinishReason.Kind.stop },
        .{ "model_context_window_exceeded", model_types.FinishReason.Kind.length },
        .{ "content_filtered", model_types.FinishReason.Kind.content_filter },
        .{ "malformed_model_output", model_types.FinishReason.Kind.incomplete_tool_call },
    }) |entry| try std.testing.expectEqual(entry[1], bedrockFinishReason(entry[0]).kind);
}

test "Converse tool result preserves parser allocation failures" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.ensureTotalCapacity(1024);
    var json: std.json.Stringify = .{ .writer = &output.writer };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, writeToolResult(failing.allocator(), &json, .{
        .call_id = "call_1",
        .name = "weather",
        .content = "{\"temperature\":31}",
    }));
}

test "Converse client preserves the provider boundary" {
    const State = struct {
        calls: usize = 0,
        observed: bool = false,

        fn request(context: *anyopaque, allocator: std.mem.Allocator, value: provider_types.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(transport.Method.POST, value.method);
            try std.testing.expectEqualStrings("/model/arn%3Aaws%3Abedrock%2Fmodel%20name/converse", value.endpoint);
            try expectHeader(value.headers, "content-type", "application/json");
            try expectHeader(value.headers, "x-trace", "boundary");
            self.calls += 1;
            return .{
                .status = if (self.calls == 1) 200 else 429,
                .body = try allocator.dupe(u8, if (self.calls == 1)
                    "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"ok\"}]}}}"
                else
                    "{\"message\":\"slow down\"}"),
            };
        }

        fn observe(
            context: *anyopaque,
            _: std.mem.Allocator,
            status: u16,
            body: []const u8,
            _: transport.ResponseMetadata,
            observer: ?model_types.ProviderErrorObserver,
            _: model_types.ProviderErrorPolicy,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.observed = status == 429 and std.mem.indexOf(u8, body, "slow down") != null and observer != null;
        }

        fn observeApplication(_: *anyopaque, _: model_types.ProviderError) void {}

        fn expectHeader(headers: []const transport.Header, name: []const u8, value: []const u8) !void {
            for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) {
                try std.testing.expectEqualStrings(value, header.value);
                return;
            };
            return error.MissingHeader;
        }
    };
    var state: State = .{};
    var client = Client{
        .model_name = "arn:aws:bedrock/model name",
        .provider = .{
            .context = &state,
            .name = "bedrock",
            .base_url = "https://bedrock.example.test",
            .requestFn = State.request,
            .observeErrorFn = State.observe,
        },
    };
    var marker: u8 = 0;
    const request_value = model_types.ModelRequest{
        .messages = &.{},
        .error_observer = .{ .context = &marker, .observeFn = State.observeApplication },
        .error_policy = .{ .capture_body = true },
        .settings = .{ .extra_headers = &.{.{ .name = "x-trace", .value = "boundary" }} },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), request_value);
    try std.testing.expectEqualStrings("ok", response.parts[0].text);
    try std.testing.expectError(error.ProviderRateLimited, client.model().request(arena.allocator(), request_value));
    try std.testing.expect(state.observed);
}
