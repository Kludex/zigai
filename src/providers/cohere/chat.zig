//! A dependency-free Cohere v2 Chat client.

const std = @import("std");
const model_types = @import("../../model.zig");
const provider_types = @import("../../provider.zig");
const http_provider = @import("../http.zig");
const http = @import("../../transport.zig");
const common = @import("../common.zig");
const json_limits = @import("../../json.zig");

pub const api_base = "https://api.cohere.com";
pub const api_key_env = "CO_API_KEY";

pub const Error = model_types.ProviderRequestError || error{
    InvalidRequestEncoding,
    UnsupportedBuiltinTool,
    UnsupportedContentType,
    UnsupportedOutputMode,
};

const native_profile: model_types.ModelProfile = .{
    .supports_tools = true,
    .supports_parallel_tool_calls = true,
    .supports_json_schema_output = true,
    .supports_json_object_output = true,
    .supports_system_messages = true,
    .supports_thinking = true,
    .supports_streaming = false,
    .supports_temperature = true,
    .supports_max_tokens = true,
    .supports_stop_sequences = true,
    .supports_seed = true,
    .supports_top_p = true,
    .supports_top_k = true,
    .supports_presence_penalty = true,
    .supports_frequency_penalty = true,
    .supports_logprobs = true,
    .supports_tool_choice = true,
    .supports_thinking_budget = true,
    .supports_request_headers = true,
    .extra_body_kind = .cohere,
    .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initMany(&.{.none}),
};

/// Authentication and transport state for Cohere's native API.
pub const Provider = struct {
    http: http_provider.Configured,

    pub const Options = struct {
        base_url: []const u8 = api_base,
        headers: []const http.Header = &.{},
        request_policy: provider_types.RequestPolicy = .{},
        model_profiles: ?http_provider.Configured.ModelProfiles = null,
    };

    pub fn init(api_key: []const u8, transport: http.Transport) Provider {
        return initWithOptions(api_key, transport, .{});
    }

    pub fn initWithOptions(api_key: []const u8, transport: http.Transport, options: Options) Provider {
        return .{ .http = .{
            .name = "cohere",
            .base_url = options.base_url,
            .transport = transport,
            .credential = .{ .bearer = api_key },
            .headers = options.headers,
            .request_policy = options.request_policy,
            .model_profiles = options.model_profiles,
        } };
    }

    pub fn provider(self: *Provider) provider_types.Provider {
        return self.http.provider();
    }
};

/// Native Cohere v2 Chat model adapter.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    settings: model_types.ModelSettings = .{},
    profile: model_types.ModelProfile = native_profile,

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
        const body = try encodeRequestForProvider(allocator, self.provider.name, self.model_name, value, false);
        defer allocator.free(body);
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        const response = self.provider.request(allocator, .{
            .method = .POST,
            .endpoint = "/v2/chat",
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
        var decoded = decodeResponse(allocator, response.body) catch |failure| return common.responseDecodeError(failure);
        decoded.provider_name = self.provider.name;
        decoded.provider_url = self.provider.base_url;
        decoded.model_name = self.model_name;
        return decoded;
    }
};

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
) ![]u8 {
    return encodeRequestForProvider(allocator, "cohere", model_name, request, false);
}

fn encodeRequestForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    model_name: []const u8,
    request: model_types.ModelRequest,
    stream: bool,
) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    if (request.builtin_tools.len != 0) return error.UnsupportedBuiltinTool;
    if (request.output != .text and request.tools.len != 0) return error.UnsupportedOutputMode;
    if (request.settings.parallel_tool_calls != null or request.settings.service_tier != null or
        request.settings.truncation != null or request.idempotency_key != null or request.request_id != null)
        return error.InvalidRequestEncoding;
    if (request.settings.seed) |seed| if (seed < 0) return error.InvalidRequestEncoding;
    if (request.settings.logprobs) |logprobs| if (logprobs.top != 0) return error.InvalidRequestEncoding;
    try common.validateToolChoice(request.tools, 0, request.settings.tool_choice);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("stream");
    try json.write(stream);
    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| try writeMessage(allocator, &json, provider_name, message);
    for (request.instructions) |instruction| try writeTextMessage(&json, "system", instruction);
    try json.endArray();

    if (request.tools.len != 0) try writeTools(allocator, &json, request.tools, request.settings.tool_choice);
    if (request.settings.tool_choice) |choice| try writeToolChoice(&json, choice);
    try writeOutput(allocator, &json, request.output);
    try writeSettings(&json, request.settings);
    try common.writeExtraBodyFields(allocator, &json, request.settings.extra_body, .cohere, &.{
        "model",            "stream",            "messages",       "tools",    "tool_choice", "response_format",
        "temperature",      "max_tokens",        "stop_sequences", "seed",     "p",           "k",
        "presence_penalty", "frequency_penalty", "logprobs",       "thinking",
    });
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    provider_name: []const u8,
    message: model_types.Message,
) !void {
    switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .system_prompt => |text| try writeTextMessage(json, "system", text),
            .system_prompt_part => |prompt| try writeTextMessage(json, "system", prompt.content),
            .user_prompt => |content| try writeUserContent(json, content),
            .user_prompt_part => |prompt| try writeUserContent(json, prompt.content),
            .retry_prompt => |text| try writeTextMessage(json, "user", text),
            .retry_prompt_part => |prompt| try writeTextMessage(json, "user", prompt.content),
            .tool_return => |result| try writeToolResult(json, result),
            .capability_load_return => |result| try writeToolResult(json, common.capabilityLoadToolResult(result)),
            .speech => |speech| try writeSpeechMessage(json, "user", speech),
            .tool_search_return, .tool_availability_delta => return error.UnsupportedContentType,
        },
        .response => |response| try writeAssistantMessage(allocator, json, provider_name, response.parts),
    }
}

fn writeTextMessage(json: *std.json.Stringify, role: []const u8, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("role");
    try json.write(role);
    try json.objectField("content");
    try json.write(text);
    try json.endObject();
}

fn writeUserContent(json: *std.json.Stringify, content: model_types.UserContent) !void {
    return switch (content) {
        .text => |text| writeTextMessage(json, "user", text),
        .text_content => |text| writeTextMessage(json, "user", text.content),
        .cache_point => {},
        else => error.UnsupportedContentType,
    };
}

fn writeSpeechMessage(json: *std.json.Stringify, role: []const u8, speech: model_types.SpeechPart) !void {
    try ensureProviderPart(speech.provider, "cohere");
    return writeTextMessage(json, role, speech.transcript orelse return error.UnsupportedContentType);
}

fn writeToolResult(json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len != 0) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("role");
    try json.write("tool");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("document");
    try json.objectField("document");
    try json.beginObject();
    try json.objectField("data");
    try json.write(result.content);
    try json.endObject();
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

fn writeAssistantMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    provider_name: []const u8,
    parts: []const model_types.ResponsePart,
) !void {
    try json.beginObject();
    try json.objectField("role");
    try json.write("assistant");
    try json.objectField("content");
    try json.beginArray();
    for (parts) |part| switch (part) {
        .text => |text| try writeContentBlock(json, "text", "text", text),
        .text_part => |text| {
            try ensureProviderPart(text.provider, provider_name);
            try writeContentBlock(json, "text", "text", text.content);
        },
        .thinking => |thinking| {
            try ensureProviderPart(thinking.provider, provider_name);
            if (!isToolPlan(thinking.provider)) try writeContentBlock(json, "thinking", "thinking", thinking.content);
        },
        .speech => |speech| {
            try ensureProviderPart(speech.provider, provider_name);
            try writeContentBlock(json, "text", "text", speech.transcript orelse return error.UnsupportedContentType);
        },
        .tool_call, .capability_load_call => {},
        else => return error.UnsupportedContentType,
    };
    try json.endArray();
    for (parts) |part| switch (part) {
        .thinking => |thinking| if (isToolPlan(thinking.provider)) {
            try json.objectField("tool_plan");
            try json.write(thinking.content);
        },
        else => {},
    };
    var has_calls = false;
    for (parts) |part| if (part == .tool_call or part == .capability_load_call) {
        has_calls = true;
        break;
    };
    if (has_calls) {
        try json.objectField("tool_calls");
        try json.beginArray();
        for (parts) |part| switch (part) {
            .tool_call => |call| try writeToolCall(allocator, json, provider_name, call),
            .capability_load_call => |call| {
                const portable = try common.capabilityLoadToolCall(allocator, call);
                defer allocator.free(portable.arguments_json);
                try writeToolCall(allocator, json, provider_name, portable);
            },
            else => {},
        };
        try json.endArray();
    }
    try json.endObject();
}

fn writeContentBlock(json: *std.json.Stringify, kind: []const u8, field: []const u8, value: []const u8) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write(kind);
    try json.objectField(field);
    try json.write(value);
    try json.endObject();
}

fn writeToolCall(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    provider_name: []const u8,
    call: model_types.ToolCall,
) !void {
    try ensureProviderPart(call.provider, provider_name);
    try json.beginObject();
    try json.objectField("id");
    try json.write(call.id);
    try json.objectField("type");
    try json.write("function");
    try json.objectField("function");
    try json.beginObject();
    try json.objectField("name");
    try json.write(call.name);
    try json.objectField("arguments");
    try common.rawJson(allocator, json, call.arguments_json, json_limits.defaults.tool_payload);
    try json.endObject();
    try json.endObject();
}

fn writeTools(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    tools: []const model_types.ToolDefinition,
    choice: ?model_types.ToolChoice,
) !void {
    try json.objectField("tools");
    try json.beginArray();
    for (tools) |tool| {
        if (!toolIncluded(choice, tool.name)) continue;
        try json.beginObject();
        try json.objectField("type");
        try json.write("function");
        try json.objectField("function");
        try json.beginObject();
        try json.objectField("name");
        try json.write(tool.name);
        try json.objectField("description");
        const description = try common.toolDescription(allocator, tool);
        defer if (description) |owned| allocator.free(owned);
        try json.write(description orelse tool.description);
        try json.objectField("parameters");
        try common.rawJson(allocator, json, tool.parameters_json_schema, json_limits.defaults.tool_payload);
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
}

fn toolIncluded(choice: ?model_types.ToolChoice, name: []const u8) bool {
    const value = choice orelse return true;
    return switch (value) {
        .tool => |selected| std.mem.eql(u8, selected, name),
        else => common.toolIncluded(choice, name),
    };
}

fn writeToolChoice(json: *std.json.Stringify, choice: model_types.ToolChoice) !void {
    const value = switch (choice) {
        .auto, .allowed => return,
        .none => "NONE",
        .required, .tool => "REQUIRED",
    };
    try json.objectField("tool_choice");
    try json.write(value);
}

fn writeOutput(allocator: std.mem.Allocator, json: *std.json.Stringify, output: model_types.OutputFormat) !void {
    switch (output) {
        .text => {},
        .json_object => {
            try json.objectField("response_format");
            try json.write(.{ .type = "json_object" });
        },
        .json_schema => |format| {
            try json.objectField("response_format");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_object");
            try json.objectField("schema");
            try common.rawJson(allocator, json, format.schema, json_limits.defaults.tool_payload);
            try json.endObject();
        },
    }
}

fn writeSettings(json: *std.json.Stringify, settings: model_types.ModelSettings) !void {
    inline for (.{
        .{ "temperature", settings.temperature },
        .{ "max_tokens", settings.max_tokens },
        .{ "seed", settings.seed },
        .{ "p", settings.top_p },
        .{ "k", settings.top_k },
        .{ "presence_penalty", settings.presence_penalty },
        .{ "frequency_penalty", settings.frequency_penalty },
    }) |entry| if (entry[1]) |value| {
        try json.objectField(entry[0]);
        try json.write(value);
    };
    if (settings.stop_sequences) |values| {
        try json.objectField("stop_sequences");
        try json.write(values);
    }
    if (settings.logprobs != null) {
        try json.objectField("logprobs");
        try json.write(true);
    }
    if (settings.reasoning_effort != null or settings.thinking_budget_tokens != null) {
        try json.objectField("thinking");
        try json.beginObject();
        if (settings.reasoning_effort) |effort| {
            try json.objectField("type");
            try json.write(if (effort == .none) "disabled" else "enabled");
        }
        if (settings.thinking_budget_tokens) |budget| {
            try json.objectField("token_budget");
            try json.write(budget);
        }
        try json.endObject();
    }
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.provider_response,
        .{ .allocate = .alloc_always },
        error.InvalidProviderResponse,
    );
    const object = switch (root) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const id = try common.objectString(object, "id");
    const raw_finish = try common.objectString(object, "finish_reason");
    const message = try common.requiredObject(root, "message");
    var parts: std.ArrayList(model_types.ResponsePart) = .empty;
    if (message.get("content")) |content_value| switch (content_value) {
        .array => |content| for (content.items) |item| try decodeContent(allocator, &parts, item),
        .null => {},
        else => return error.InvalidProviderResponse,
    };
    if (try common.optionalObjectString(message, "tool_plan")) |plan| {
        try parts.append(allocator, .{ .thinking = .{
            .content = plan,
            .provider = .{
                .provider_name = "cohere",
                .provider_details = try markerDetails(allocator, "tool_plan"),
            },
        } });
    }
    if (message.get("tool_calls")) |calls_value| switch (calls_value) {
        .array => |calls| for (calls.items) |call| try parts.append(allocator, .{ .tool_call = try decodeToolCall(call) }),
        .null => {},
        else => return error.InvalidProviderResponse,
    };
    return .{
        .parts = try parts.toOwnedSlice(allocator),
        .usage = try decodeUsage(object),
        .provider_details = try responseDetails(allocator, object, message),
        .provider_response_id = id,
        .finish_reason = decodeFinishReason(raw_finish),
    };
}

fn decodeContent(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(model_types.ResponsePart),
    item: std.json.Value,
) !void {
    const object = switch (item) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const kind = try common.objectString(object, "type");
    if (std.mem.eql(u8, kind, "text")) {
        try parts.append(allocator, .{ .text = try common.objectString(object, "text") });
    } else if (std.mem.eql(u8, kind, "thinking")) {
        try parts.append(allocator, .{ .thinking = .{
            .content = try common.objectString(object, "thinking"),
            .provider = .{
                .provider_name = "cohere",
                .provider_details = try markerDetails(allocator, "thinking"),
            },
        } });
    } else return error.InvalidProviderResponse;
}

fn decodeToolCall(value: std.json.Value) !model_types.ToolCall {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidProviderResponse,
    };
    if (!std.mem.eql(u8, try common.objectString(object, "type"), "function"))
        return error.InvalidProviderResponse;
    const function = try common.requiredObject(value, "function");
    const arguments = function.get("arguments") orelse return error.InvalidProviderResponse;
    return .{
        .id = try common.objectString(object, "id"),
        .name = try common.objectString(function, "name"),
        .arguments_json = switch (arguments) {
            .string => |text| text,
            else => return error.InvalidProviderResponse,
        },
        .provider = .{ .provider_name = "cohere" },
    };
}

fn decodeUsage(object: std.json.ObjectMap) !model_types.Usage {
    const usage_value = object.get("usage") orelse return .{};
    if (usage_value == .null) return .{};
    const usage = switch (usage_value) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const tokens_value = usage.get("tokens") orelse return .{};
    if (tokens_value == .null) return .{};
    const tokens = switch (tokens_value) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    return .{
        .input_tokens = (try common.optionalObjectInteger(tokens, "input_tokens")) orelse 0,
        .output_tokens = (try common.optionalObjectInteger(tokens, "output_tokens")) orelse 0,
    };
}

fn responseDetails(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    message: std.json.ObjectMap,
) !?model_types.ProviderDetails {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    if (message.get("citations")) |value| try object.put(allocator, "citations", value);
    if (root.get("logprobs")) |value| try object.put(allocator, "logprobs", value);
    if (root.get("usage")) |usage| if (usage == .object) {
        if (usage.object.get("billed_units")) |value| try object.put(allocator, "billed_units", value);
    };
    if (object.count() == 0) return null;
    return try model_types.ProviderDetails.fromValue(.{ .object = object });
}

fn decodeFinishReason(raw: []const u8) model_types.FinishReason {
    const kind: model_types.FinishReason.Kind = if (std.mem.eql(u8, raw, "COMPLETE") or
        std.mem.eql(u8, raw, "STOP_SEQUENCE"))
        .stop
    else if (std.mem.eql(u8, raw, "MAX_TOKENS"))
        .length
    else if (std.mem.eql(u8, raw, "TOOL_CALL"))
        .tool_calls
    else
        .other;
    return .{ .kind = kind, .raw = raw };
}

fn markerDetails(allocator: std.mem.Allocator, kind: []const u8) !model_types.ProviderDetails {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, "type", .{ .string = kind });
    return try model_types.ProviderDetails.fromValue(.{ .object = object });
}

fn isToolPlan(provider: model_types.ProviderPart) bool {
    const details = provider.provider_details orelse return false;
    const kind = details.value.object.get("type") orelse return false;
    return kind == .string and std.mem.eql(u8, kind.string, "tool_plan");
}

fn ensureProviderPart(part: model_types.ProviderPart, provider_name: []const u8) !void {
    if (part.provider_name) |owner| if (!std.mem.eql(u8, owner, provider_name))
        return error.UnsupportedContentType;
    if (part.id != null) return error.UnsupportedContentType;
}

test "native Cohere v2 request preserves messages tools and settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt = "Be concise." },
            .{ .user_prompt = .{ .text = "Weather?" } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .thinking = .{ .content = "Use weather.", .provider = .{
                .provider_name = "cohere",
                .provider_details = try markerDetails(arena.allocator(), "tool_plan"),
            } } },
            .{ .tool_call = .{ .id = "call_1", .name = "weather", .arguments_json = "{\"city\":\"Madrid\"}", .provider = .{ .provider_name = "cohere" } } },
        } } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "call_1", .name = "weather", .content = "sunny" } }} } },
    };
    const body = try encodeRequest(arena.allocator(), "command-a-03-2025", .{
        .messages = &messages,
        .instructions = &.{"Answer directly."},
        .tools = &.{.{
            .name = "weather",
            .description = "Weather lookup",
            .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}",
        }},
        .settings = .{
            .temperature = 0.2,
            .max_tokens = 100,
            .stop_sequences = &.{"END"},
            .seed = 7,
            .top_p = 0.8,
            .top_k = 20,
            .presence_penalty = 0.1,
            .frequency_penalty = 0.2,
            .logprobs = .{},
            .tool_choice = .required,
            .extra_body = .{ .cohere = "{\"strict_tools\":true}" },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_plan\":\"Use weather.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"REQUIRED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict_tools\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"k\":20") != null);
}

test "native Cohere v2 response decodes reasoning tools citations and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(),
        \\{"id":"chat_1","finish_reason":"TOOL_CALL","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Check weather."},{"type":"text","text":"One moment."}],"tool_plan":"Call weather.","tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\\\"city\\\":\\\"Madrid\\\"}"}}],"citations":[{"start":0,"end":3}]},"usage":{"billed_units":{"input_tokens":2,"output_tokens":3},"tokens":{"input_tokens":4,"output_tokens":5}},"logprobs":[{"token":"One"}]}
    );
    try std.testing.expectEqual(@as(usize, 4), response.parts.len);
    try std.testing.expectEqualStrings("Check weather.", response.parts[0].thinking.content);
    try std.testing.expectEqualStrings("weather", response.parts[3].tool_call.name);
    try std.testing.expectEqual(@as(u64, 4), response.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), response.usage.output_tokens);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
    try std.testing.expect(response.provider_details != null);
}

test "native Cohere client owns endpoint identity and provider errors" {
    const State = struct {
        status: u16 = 200,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("https://api.cohere.com/v2/chat", request.url);
            try std.testing.expectEqualStrings("Bearer secret", request.headers[0].value);
            return .{ .status = self.status, .body = try allocator.dupe(
                u8,
                if (self.status == 200)
                    "{\"id\":\"chat_1\",\"finish_reason\":\"COMPLETE\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}}"
                else
                    "{\"message\":\"failed\"}",
            ) };
        }
    };
    var state: State = .{};
    var provider = Provider.init("secret", .{ .context = &state, .sendFn = State.send });
    var client = Client{ .model_name = "command-a-03-2025", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
    });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expectEqualStrings("cohere", response.provider_name.?);
    try std.testing.expectEqualStrings("command-a-03-2025", response.model_name.?);
    try std.testing.expectEqual(model_types.ExtraBodyKind.cohere, client.model().profile.extra_body_kind.?);
    state.status = 429;
    try std.testing.expectError(error.ProviderRateLimited, client.model().request(arena.allocator(), .{ .messages = &.{} }));
}
