//! Native Mistral Conversations model adapter.
//!
//! `Client.model` always creates a stateless conversation (`store: false`) and
//! replays provider-neutral history. Persistent conversation lifecycle is a
//! separate concern and is deliberately not hidden inside model retries.

const std = @import("std");
const compatible = @import("../openai_compatible.zig");
const common = @import("../common.zig");
const profiles = @import("../profiles.zig");
const json_limits = @import("../../json.zig");
const model_types = @import("../../model.zig");
const provider_types = @import("../../provider.zig");
const transport = @import("../../transport.zig");

pub const api_base = "https://api.mistral.ai/v1";

pub const Error = model_types.ProviderRequestError || error{
    /// A successful payload does not match Mistral Conversations.
    InvalidProviderResponse,
    /// Provider-neutral input cannot be represented by Conversations.
    InvalidRequestEncoding,
    /// The request contains a provider-managed tool this adapter does not support.
    UnsupportedManagedTool,
    /// The request contains content this adapter cannot encode losslessly.
    UnsupportedContentType,
};

const default_profile = model_types.ModelProfile{
    .supports_tools = true,
    .supports_parallel_tool_calls = false,
    .supports_json_schema_output = true,
    .supports_json_object_output = true,
    .supports_system_messages = true,
    .supports_streaming = false,
    .supports_temperature = true,
    .supports_max_tokens = true,
    .supports_stop_sequences = true,
    .supports_seed = true,
    .supports_top_p = true,
    .supports_presence_penalty = true,
    .supports_frequency_penalty = true,
    .supports_tool_choice = true,
    .supports_request_headers = true,
    .extra_body_kind = .mistral,
    .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initMany(&.{
        .none,
        .minimal,
        .low,
        .medium,
        .high,
        .xhigh,
    }),
    .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .code_execution }),
};

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "mistral",
    .profile = default_profile,
    .model_profile_lookup = profiles.mistralConversations,
};

/// Authenticated provider state for the native Conversations endpoint.
pub const Provider = compatible.ProviderWithDefaults(defaults);

/// Optional filtering and confirmation policy for a Mistral-managed tool.
pub const ToolConfiguration = struct {
    exclude: ?[]const []const u8 = null,
    include: ?[]const []const u8 = null,
    requires_confirmation: ?[]const []const u8 = null,
};

/// Request-scoped credential for a Mistral connector.
pub const ConnectorAuthorization = union(enum) {
    api_key: []const u8,
    oauth2_token: []const u8,
};

/// Mistral-only server-managed tools. Portable tools remain on `ModelRequest`.
pub const ManagedTool = union(enum) {
    web_search_premium: ToolConfiguration,
    image_generation: ToolConfiguration,
    document_library: DocumentLibrary,
    connector: Connector,

    pub const DocumentLibrary = struct {
        library_ids: []const []const u8,
        configuration: ToolConfiguration = .{},
    };

    pub const Connector = struct {
        connector_id: []const u8,
        authorization: ?ConnectorAuthorization = null,
        configuration: ToolConfiguration = .{},
    };
};

/// Stateless native Conversations adapter for the provider-neutral model loop.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    profile: model_types.ModelProfile = default_profile,
    managed_tools: []const ManagedTool = &.{},
    settings: model_types.ModelSettings = .{},

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

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, self.model_name, value, self.managed_tools);
        defer allocator.free(body);
        var headers: std.ArrayList(transport.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        if (value.request_id) |request_id|
            try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        const response = self.provider.request(allocator, .{
            .method = .POST,
            .endpoint = "/conversations",
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

/// Encodes one stateless native Conversations request.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try validateSettings(request.settings);
    try common.validateToolChoice(request.tools, request.builtin_tools.len, request.settings.tool_choice);
    try validateManagedTools(request.builtin_tools, managed_tools);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("inputs");
    try json.beginArray();
    for (request.messages) |message| switch (message) {
        .request => |value| try writeRequestMessage(allocator, &json, value),
        .response => |value| try writeResponseMessage(allocator, &json, value),
    };
    try json.endArray();
    try writeInstructions(allocator, &json, request);
    try writeTools(allocator, &json, request, managed_tools);
    try writeCompletionArgs(allocator, &json, request);
    try json.objectField("store");
    try json.write(false);
    try json.objectField("stream");
    try json.write(false);
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        .mistral,
        &.{ "model", "inputs", "instructions", "tools", "completion_args", "store", "stream" },
    );
    try json.endObject();
    return output.toOwnedSlice();
}

fn validateSettings(settings: model_types.ModelSettings) !void {
    if (settings.top_k != null or settings.logprobs != null or settings.parallel_tool_calls != null or
        settings.thinking_budget_tokens != null or settings.service_tier != null or settings.truncation != null)
        return error.InvalidRequestEncoding;
    if (settings.reasoning_effort == .max) return error.InvalidRequestEncoding;
}

fn validateManagedTools(portable: []const model_types.BuiltinTool, managed: []const ManagedTool) !void {
    for (portable, 0..) |tool, index| {
        switch (tool) {
            .web_search, .code_execution => {},
            else => return error.UnsupportedManagedTool,
        }
        for (portable[index + 1 ..]) |other| if (tool.conflictsWith(other))
            return error.InvalidRequestEncoding;
    }
    for (managed, 0..) |tool, index| {
        try validateManagedTool(tool);
        for (managed[index + 1 ..]) |other| if (managedToolsConflict(tool, other))
            return error.InvalidRequestEncoding;
        if (tool == .web_search_premium) for (portable) |candidate| if (candidate == .web_search)
            return error.InvalidRequestEncoding;
    }
}

fn validateManagedTool(tool: ManagedTool) !void {
    switch (tool) {
        .web_search_premium => |configuration| try validateToolConfiguration(configuration),
        .image_generation => |configuration| try validateToolConfiguration(configuration),
        .document_library => |value| {
            if (value.library_ids.len == 0) return error.InvalidRequestEncoding;
            try validateNames(value.library_ids);
            try validateToolConfiguration(value.configuration);
        },
        .connector => |value| {
            if (value.connector_id.len == 0) return error.InvalidRequestEncoding;
            if (value.authorization) |authorization| switch (authorization) {
                inline else => |secret| if (secret.len == 0) return error.InvalidRequestEncoding,
            };
            try validateToolConfiguration(value.configuration);
        },
    }
}

fn validateToolConfiguration(configuration: ToolConfiguration) !void {
    if (configuration.include) |values| try validateNames(values);
    if (configuration.exclude) |values| try validateNames(values);
    if (configuration.requires_confirmation) |values| try validateNames(values);
}

fn validateNames(values: []const []const u8) !void {
    if (values.len == 0) return error.InvalidRequestEncoding;
    for (values) |value| if (value.len == 0) return error.InvalidRequestEncoding;
}

fn managedToolsConflict(left: ManagedTool, right: ManagedTool) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .connector => |value| std.mem.eql(u8, value.connector_id, right.connector.connector_id),
        else => true,
    };
}

fn writeInstructions(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: model_types.ModelRequest,
) !void {
    var instructions: std.ArrayList(u8) = .empty;
    defer instructions.deinit(allocator);
    for (request.instructions) |instruction| try appendInstruction(allocator, &instructions, instruction);
    for (request.messages) |message| switch (message) {
        .request => |value| for (value.parts) |part| switch (part) {
            .system_prompt => |content| try appendInstruction(allocator, &instructions, content),
            .system_prompt_part => |prompt| try appendInstruction(allocator, &instructions, prompt.content),
            else => {},
        },
        .response => {},
    };
    if (instructions.items.len == 0) return;
    try json.objectField("instructions");
    try json.write(instructions.items);
}

fn appendInstruction(allocator: std.mem.Allocator, target: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len == 0) return;
    if (target.items.len > 0) try target.appendSlice(allocator, "\n\n");
    try target.appendSlice(allocator, value);
}

fn writeRequestMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    message: model_types.RequestMessage,
) !void {
    for (message.parts) |part| switch (part) {
        .system_prompt, .system_prompt_part, .tool_availability_delta => {},
        .user_prompt => |content| try writeUserContent(allocator, json, content),
        .user_prompt_part => |prompt| try writeUserContent(allocator, json, prompt.content),
        .retry_prompt => |content| try writeMessage(json, "message.input", "user", content),
        .retry_prompt_part => |prompt| try writeMessage(json, "message.input", "user", prompt.content),
        .tool_return => |result| try writeFunctionResult(json, result),
        .capability_load_return => |result| try writeFunctionResult(json, common.capabilityLoadToolResult(result)),
        .speech => |speech| if (speech.transcript) |content|
            try writeMessage(json, "message.input", "user", content)
        else
            return error.UnsupportedContentType,
        .tool_search_return => return error.UnsupportedContentType,
    };
}

fn writeUserContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    content: model_types.UserContent,
) !void {
    switch (content) {
        .text => |value| try writeMessage(json, "message.input", "user", value),
        .text_content => |value| try writeMessage(json, "message.input", "user", value.content),
        .image => |value| try writeRichContent(allocator, json, .image, value),
        .document => |value| try writeRichContent(allocator, json, .document, value),
        .uploaded_file => |file| try writeRichContent(allocator, json, .document, file.asContent()),
        .cache_point => {},
        else => return error.UnsupportedContentType,
    }
}

fn writeRichContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: model_types.ContentType,
    content: model_types.Content,
) !void {
    if (content.provider.requiresReplay() or content.thought_signature != null) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("object");
    try json.write("entry");
    try json.objectField("type");
    try json.write("message.input");
    try json.objectField("role");
    try json.write("user");
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    switch (content.source) {
        .bytes => |bytes| {
            try json.objectField("type");
            try json.write(if (kind == .image) "image_url" else "document_url");
            const encoded = try common.base64Alloc(allocator, bytes);
            defer allocator.free(encoded);
            const data_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ content.media_type, encoded });
            defer allocator.free(data_url);
            try json.objectField(if (kind == .image) "image_url" else "document_url");
            try json.write(data_url);
        },
        .url => |url| {
            try json.objectField("type");
            try json.write(if (kind == .image) "image_url" else "document_url");
            try json.objectField(if (kind == .image) "image_url" else "document_url");
            try json.write(url);
        },
        .provider_file => |file| {
            if (file.provider) |owner| if (!std.mem.eql(u8, owner, "mistral")) return error.UnsupportedContentType;
            try json.objectField("type");
            try json.write("tool_file");
            try json.objectField("tool");
            try json.write("document_library");
            try json.objectField("file_id");
            try json.write(file.id);
        },
        .uploaded_file => |file| {
            if (!std.mem.eql(u8, file.provider_name, "mistral")) return error.UnsupportedContentType;
            try json.objectField("type");
            try json.write("tool_file");
            try json.objectField("tool");
            try json.write("document_library");
            try json.objectField("file_id");
            try json.write(file.id);
        },
    }
    if (content.filename) |filename| {
        const field: ?[]const u8 = switch (content.source) {
            .provider_file, .uploaded_file => "file_name",
            else => if (kind == .document) "document_name" else null,
        };
        if (field) |name| {
            try json.objectField(name);
            try json.write(filename);
        }
    }
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

fn writeResponseMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    message: model_types.ResponseMessage,
) !void {
    for (message.parts) |part| switch (part) {
        .text => |content| try writeMessage(json, "message.output", "assistant", content),
        .text_part => |value| {
            if (value.provider.requiresReplay()) {
                if (!std.mem.eql(u8, value.provider.provider_name orelse "", "mistral"))
                    return error.UnsupportedContentType;
                const details = value.provider.provider_details orelse return error.UnsupportedContentType;
                try json.beginObject();
                try json.objectField("object");
                try json.write("entry");
                try json.objectField("type");
                try json.write("message.output");
                try json.objectField("role");
                try json.write("assistant");
                try json.objectField("content");
                try json.beginArray();
                try json.write(details.value);
                try json.endArray();
                try json.endObject();
            } else {
                try writeMessage(json, "message.output", "assistant", value.content);
            }
        },
        .tool_call => |call| try writeFunctionCall(allocator, json, call),
        .capability_load_call => |call| {
            const portable = try common.capabilityLoadToolCall(allocator, call);
            defer allocator.free(portable.arguments_json);
            try writeFunctionCall(allocator, json, portable);
        },
        .native_tool_return => |value| try writeNativeEntry(json, value.provider),
        .thinking => |value| try writeThinking(json, value),
        else => return error.UnsupportedContentType,
    };
}

fn writeMessage(json: *std.json.Stringify, entry_type: []const u8, role: []const u8, content: []const u8) !void {
    try json.beginObject();
    try json.objectField("object");
    try json.write("entry");
    try json.objectField("type");
    try json.write(entry_type);
    try json.objectField("role");
    try json.write(role);
    try json.objectField("content");
    try json.write(content);
    try json.endObject();
}

fn writeFunctionCall(allocator: std.mem.Allocator, json: *std.json.Stringify, call: model_types.ToolCall) !void {
    if (call.thought_signature != null) return error.UnsupportedContentType;
    if (call.provider.provider_name) |name| if (!std.mem.eql(u8, name, "mistral")) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("object");
    try json.write("entry");
    try json.objectField("type");
    try json.write("function.call");
    try json.objectField("tool_call_id");
    try json.write(call.id);
    try json.objectField("name");
    try json.write(call.name);
    try json.objectField("arguments");
    try common.rawJson(allocator, json, call.arguments_json, json_limits.defaults.tool_payload);
    if (call.provider.id) |id| {
        try json.objectField("id");
        try json.write(id);
    }
    try json.endObject();
}

fn writeFunctionResult(json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len > 0) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("object");
    try json.write("entry");
    try json.objectField("type");
    try json.write("function.result");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("result");
    try json.write(result.content);
    try json.endObject();
}

fn writeNativeEntry(json: *std.json.Stringify, provider: model_types.ProviderPart) !void {
    if (!std.mem.eql(u8, provider.provider_name orelse "", "mistral")) return error.UnsupportedContentType;
    const details = provider.provider_details orelse return error.UnsupportedContentType;
    try json.write(details.value);
}

fn writeThinking(json: *std.json.Stringify, value: model_types.Thinking) !void {
    if (!std.mem.eql(u8, value.provider.provider_name orelse "", "mistral")) return error.UnsupportedContentType;
    if (value.provider.provider_details) |details| return json.write(details.value);
    try json.beginObject();
    try json.objectField("object");
    try json.write("entry");
    try json.objectField("type");
    try json.write("message.output");
    try json.objectField("role");
    try json.write("assistant");
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("thinking");
    try json.objectField("thinking");
    try json.write(&.{.{ .type = "text", .text = value.content }});
    if (value.signature) |signature| {
        try json.objectField("signature");
        try json.write(signature);
    }
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

fn writeTools(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
) !void {
    if (request.tools.len == 0 and request.builtin_tools.len == 0 and managed_tools.len == 0) return;
    try json.objectField("tools");
    try json.beginArray();
    for (request.tools) |tool| {
        if (!common.toolIncluded(request.settings.tool_choice, tool.name)) continue;
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
        try common.rawJson(allocator, json, tool.parameters_json_schema, json_limits.defaults.schema);
        try json.objectField("strict");
        try json.write(true);
        try json.endObject();
        try json.endObject();
    }
    for (request.builtin_tools) |tool| switch (tool) {
        .web_search => try writeSimpleManagedTool(json, "web_search", .{}),
        .code_execution => try writeSimpleManagedTool(json, "code_interpreter", .{}),
        else => return error.UnsupportedManagedTool,
    };
    for (managed_tools) |tool| try writeManagedTool(json, tool);
    try json.endArray();
}

fn writeManagedTool(json: *std.json.Stringify, tool: ManagedTool) !void {
    switch (tool) {
        .web_search_premium => |configuration| try writeSimpleManagedTool(json, "web_search_premium", configuration),
        .image_generation => |configuration| try writeSimpleManagedTool(json, "image_generation", configuration),
        .document_library => |value| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("document_library");
            try json.objectField("library_ids");
            try json.write(value.library_ids);
            try writeToolConfiguration(json, value.configuration);
            try json.endObject();
        },
        .connector => |value| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("connector");
            try json.objectField("connector_id");
            try json.write(value.connector_id);
            if (value.authorization) |authorization| {
                try json.objectField("authorization");
                try json.beginObject();
                switch (authorization) {
                    .api_key => |secret| {
                        try json.objectField("type");
                        try json.write("api-key");
                        try json.objectField("value");
                        try json.write(secret);
                    },
                    .oauth2_token => |secret| {
                        try json.objectField("type");
                        try json.write("oauth2-token");
                        try json.objectField("value");
                        try json.write(secret);
                    },
                }
                try json.endObject();
            }
            try writeToolConfiguration(json, value.configuration);
            try json.endObject();
        },
    }
}

fn writeSimpleManagedTool(
    json: *std.json.Stringify,
    kind: []const u8,
    configuration: ToolConfiguration,
) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write(kind);
    try writeToolConfiguration(json, configuration);
    try json.endObject();
}

fn writeToolConfiguration(json: *std.json.Stringify, configuration: ToolConfiguration) !void {
    if (configuration.exclude == null and configuration.include == null and configuration.requires_confirmation == null) return;
    try json.objectField("tool_configuration");
    try json.beginObject();
    if (configuration.exclude) |values| {
        try json.objectField("exclude");
        try json.write(values);
    }
    if (configuration.include) |values| {
        try json.objectField("include");
        try json.write(values);
    }
    if (configuration.requires_confirmation) |values| {
        try json.objectField("requires_confirmation");
        try json.write(values);
    }
    try json.endObject();
}

fn writeCompletionArgs(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: model_types.ModelRequest,
) !void {
    const settings = request.settings;
    const has_args = settings.temperature != null or settings.max_tokens != null or settings.stop_sequences != null or
        settings.seed != null or settings.reasoning_effort != null or settings.top_p != null or
        settings.presence_penalty != null or settings.frequency_penalty != null or settings.tool_choice != null or
        request.output != .text;
    if (!has_args) return;
    try json.objectField("completion_args");
    try json.beginObject();
    if (settings.temperature) |value| {
        try json.objectField("temperature");
        try json.write(value);
    }
    if (settings.max_tokens) |value| {
        try json.objectField("max_tokens");
        try json.write(value);
    }
    if (settings.stop_sequences) |value| {
        try json.objectField("stop");
        try json.write(value);
    }
    if (settings.seed) |value| {
        try json.objectField("random_seed");
        try json.write(value);
    }
    if (settings.reasoning_effort) |value| {
        try json.objectField("reasoning_effort");
        try json.write(@tagName(value));
    }
    if (settings.top_p) |value| {
        try json.objectField("top_p");
        try json.write(value);
    }
    if (settings.presence_penalty) |value| {
        try json.objectField("presence_penalty");
        try json.write(value);
    }
    if (settings.frequency_penalty) |value| {
        try json.objectField("frequency_penalty");
        try json.write(value);
    }
    if (settings.tool_choice) |choice| {
        try json.objectField("tool_choice");
        try json.write(switch (choice) {
            .auto => "auto",
            .none => "none",
            .required, .tool, .allowed => "required",
        });
    }
    switch (request.output) {
        .text => {},
        .json_object => {
            try json.objectField("response_format");
            try json.write(.{ .type = "json_object" });
        },
        .json_schema => |format| {
            try json.objectField("response_format");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_schema");
            try json.objectField("json_schema");
            try json.beginObject();
            try json.objectField("name");
            try json.write(format.name);
            try json.objectField("schema");
            try common.rawJson(allocator, json, format.schema, json_limits.defaults.schema);
            try json.objectField("strict");
            try json.write(format.strict);
            try json.endObject();
            try json.endObject();
        },
    }
    try json.endObject();
}

/// Decodes one buffered native Conversations response.
pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    );
    const object = switch (root) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const conversation_id = try common.objectString(object, "conversation_id");
    const outputs = try common.requiredArray(root, "outputs");
    var parts: std.ArrayList(model_types.ResponsePart) = .empty;
    for (outputs.items) |output| try decodeOutput(allocator, &parts, output);
    const usage: model_types.Usage = if (object.get("usage")) |value|
        try decodeUsage(allocator, value)
    else
        .{};
    const has_calls = hasFunctionCalls(parts.items);
    return .{
        .parts = try parts.toOwnedSlice(allocator),
        .usage = usage,
        .conversation_id = conversation_id,
        .provider_response_id = conversation_id,
        .finish_reason = .{ .kind = if (has_calls) .tool_calls else .stop, .raw = "completed" },
    };
}

fn decodeOutput(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(model_types.ResponsePart),
    output: std.json.Value,
) !void {
    const object = switch (output) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const kind = try common.objectString(object, "type");
    if (std.mem.eql(u8, kind, "message.output")) return decodeMessageOutput(allocator, parts, object);
    if (std.mem.eql(u8, kind, "function.call")) {
        const arguments_value = object.get("arguments") orelse return error.InvalidProviderResponse;
        const arguments = switch (arguments_value) {
            .string => |value| value,
            .object => try std.json.Stringify.valueAlloc(allocator, arguments_value, .{}),
            else => return error.InvalidProviderResponse,
        };
        try parts.append(allocator, .{ .tool_call = .{
            .id = try common.objectString(object, "tool_call_id"),
            .name = try common.objectString(object, "name"),
            .arguments_json = arguments,
            .provider = .{ .id = try common.optionalObjectString(object, "id"), .provider_name = "mistral" },
        } });
        return;
    }
    const details = try model_types.ProviderDetails.fromValue(output);
    const id = try common.optionalObjectString(object, "id") orelse kind;
    const name = try common.optionalObjectString(object, "name") orelse kind;
    const content = if (object.get("info")) |info|
        try std.json.Stringify.valueAlloc(allocator, info, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, output, .{});
    try parts.append(allocator, .{ .native_tool_return = .{
        .call_id = id,
        .name = name,
        .content = content,
        .provider = .{ .id = id, .provider_name = "mistral", .provider_details = details },
    } });
}

fn decodeMessageOutput(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(model_types.ResponsePart),
    object: std.json.ObjectMap,
) !void {
    const content = object.get("content") orelse return error.InvalidProviderResponse;
    switch (content) {
        .string => |value| try parts.append(allocator, .{ .text = value }),
        .array => |chunks| for (chunks.items) |chunk| try decodeContentChunk(allocator, parts, chunk),
        else => return error.InvalidProviderResponse,
    }
}

fn decodeContentChunk(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(model_types.ResponsePart),
    chunk: std.json.Value,
) !void {
    const object = switch (chunk) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const kind = try common.objectString(object, "type");
    if (std.mem.eql(u8, kind, "text")) {
        try parts.append(allocator, .{ .text_part = .{
            .content = try common.objectString(object, "text"),
            .provider = .{ .provider_name = "mistral", .provider_details = try model_types.ProviderDetails.fromValue(chunk) },
        } });
    } else if (std.mem.eql(u8, kind, "thinking")) {
        const thinking = try common.requiredArray(chunk, "thinking");
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (thinking.items) |item| {
            const item_object = switch (item) {
                .object => |value| value,
                else => return error.InvalidProviderResponse,
            };
            if (std.mem.eql(u8, try common.objectString(item_object, "type"), "text"))
                try text.appendSlice(allocator, try common.objectString(item_object, "text"));
        }
        try parts.append(allocator, .{ .thinking = .{
            .content = try text.toOwnedSlice(allocator),
            .signature = try common.optionalObjectString(object, "signature"),
            .provider = .{ .provider_name = "mistral", .provider_details = try model_types.ProviderDetails.fromValue(chunk) },
        } });
    } else if (std.mem.eql(u8, kind, "image_url") or std.mem.eql(u8, kind, "document_url")) {
        const field = if (std.mem.eql(u8, kind, "image_url")) "image_url" else "document_url";
        const url_value = object.get(field) orelse return error.InvalidProviderResponse;
        const url = switch (url_value) {
            .string => |value| value,
            .object => |value| try common.objectString(value, "url"),
            else => return error.InvalidProviderResponse,
        };
        const value = model_types.Content{
            .source = .{ .url = url },
            .media_type = if (std.mem.eql(u8, kind, "image_url")) "image/*" else "application/octet-stream",
            .filename = try common.optionalObjectString(object, "document_name"),
            .provider = .{ .provider_name = "mistral", .provider_details = try model_types.ProviderDetails.fromValue(chunk) },
        };
        try parts.append(allocator, if (std.mem.eql(u8, kind, "image_url")) .{ .image = value } else .{ .document = value });
    } else if (std.mem.eql(u8, kind, "tool_file")) {
        const media_type = try common.optionalObjectString(object, "file_type") orelse "application/octet-stream";
        const value = model_types.Content{
            .source = .{ .uploaded_file = .{
                .id = try common.objectString(object, "file_id"),
                .provider_name = "mistral",
                .media_type = media_type,
            } },
            .media_type = media_type,
            .filename = try common.optionalObjectString(object, "file_name"),
            .provider = .{ .provider_name = "mistral", .provider_details = try model_types.ProviderDetails.fromValue(chunk) },
        };
        try parts.append(allocator, .{ .binary = value });
    } else {
        const rendered = try std.json.Stringify.valueAlloc(allocator, chunk, .{});
        try parts.append(allocator, .{ .text_part = .{
            .content = rendered,
            .provider = .{ .provider_name = "mistral", .provider_details = try model_types.ProviderDetails.fromValue(chunk) },
        } });
    }
}

fn decodeUsage(allocator: std.mem.Allocator, value: std.json.Value) !model_types.Usage {
    const object = switch (value) {
        .object => |usage| usage,
        else => return error.InvalidProviderResponse,
    };
    var details: std.ArrayList(model_types.UsageDetail) = .empty;
    if (try common.optionalObjectInteger(object, "total_tokens")) |tokens|
        try details.append(allocator, .{ .name = "total_tokens", .value = tokens });
    if (try common.optionalObjectInteger(object, "connector_tokens")) |tokens|
        try details.append(allocator, .{ .name = "connector_tokens", .value = tokens });
    if (object.get("connectors")) |connectors_value| switch (connectors_value) {
        .null => {},
        .object => |connectors| {
            var iterator = connectors.iterator();
            while (iterator.next()) |entry| {
                const tokens = switch (entry.value_ptr.*) {
                    .integer => |count| std.math.cast(u64, count) orelse return error.InvalidProviderResponse,
                    else => return error.InvalidProviderResponse,
                };
                try details.append(allocator, .{
                    .name = try std.fmt.allocPrint(allocator, "connector.{s}.tokens", .{entry.key_ptr.*}),
                    .value = tokens,
                });
            }
        },
        else => return error.InvalidProviderResponse,
    };
    return .{
        .input_tokens = try common.optionalObjectInteger(object, "prompt_tokens") orelse 0,
        .output_tokens = try common.optionalObjectInteger(object, "completion_tokens") orelse 0,
        .details = try details.toOwnedSlice(allocator),
    };
}

fn hasFunctionCalls(parts: []const model_types.ResponsePart) bool {
    for (parts) |part| switch (part) {
        .tool_call => return true,
        else => {},
    };
    return false;
}

test "native request keeps model calls stateless and maps Mistral tools" {
    const tools = [_]model_types.ToolDefinition{.{
        .name = "weather",
        .description = "Get weather.",
        .parameters_json_schema = "{\"type\":\"object\"}",
    }};
    const managed = [_]ManagedTool{
        .{ .document_library = .{ .library_ids = &.{"lib_1"} } },
        .{ .connector = .{ .connector_id = "github", .authorization = .{ .api_key = "secret" } } },
    };
    const body = try encodeRequest(std.testing.allocator, "mistral-small-latest", .{
        .messages = &.{.{ .request = .{ .parts = &.{
            .{ .system_prompt = "Be concise." },
            .{ .user_prompt = .{ .text = "Hello" } },
        } } }},
        .instructions = &.{"Use tools when needed."},
        .tools = &tools,
        .builtin_tools = &.{ .{ .web_search = .{} }, .{ .code_execution = .{} } },
        .output = .json_object,
        .settings = .{ .temperature = 0.2, .tool_choice = .auto, .extra_body = .{ .mistral = "{\"name\":\"test\"}" } },
    }, &managed);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Use tools when needed.\\n\\nBe concise.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"code_interpreter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"library_ids\":[\"lib_1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"api-key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"json_object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"test\"") != null);
}

test "native response distinguishes local calls from managed execution" {
    const body =
        "{\"conversation_id\":\"conv_1\",\"outputs\":[" ++
        "{\"object\":\"entry\",\"type\":\"message.output\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}," ++
        "{\"object\":\"entry\",\"type\":\"tool.execution\",\"id\":\"exec_1\",\"name\":\"web_search\",\"arguments\":\"{}\",\"info\":{\"results\":1}}," ++
        "{\"object\":\"entry\",\"type\":\"function.call\",\"id\":\"entry_1\",\"tool_call_id\":\"call_1\",\"name\":\"weather\",\"arguments\":{\"city\":\"Paris\"}}" ++
        "],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,\"connector_tokens\":2,\"connectors\":{\"web_search\":2}}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqualStrings("conv_1", response.conversation_id.?);
    try std.testing.expectEqualStrings("Hello", response.parts[0].text_part.content);
    try std.testing.expectEqualStrings("web_search", response.parts[1].native_tool_return.name);
    try std.testing.expectEqualStrings("weather", response.parts[2].tool_call.name);
    try std.testing.expectEqual(@as(u64, 3), response.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), response.usage.detail("connector.web_search.tokens"));
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "native client uses Conversations authentication and endpoint" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqualStrings("https://api.mistral.ai/v1/conversations", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"store\":false") != null);
            var authenticated = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization") and
                    std.mem.eql(u8, header.value, "Bearer secret")) authenticated = true;
            }
            try std.testing.expect(authenticated);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"conversation_id\":\"conv_1\",\"outputs\":[{\"type\":\"message.output\",\"content\":\"pong\"}],\"usage\":{}}"),
            };
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{ .context = &marker, .sendFn = State.send });
    var client = Client{ .model_name = "mistral-small-latest", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{ .messages = &.{} });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expect(client.model().profile.supportsBuiltinTool(.web_search));
    try std.testing.expectEqual(model_types.ExtraBodyKind.mistral, client.model().profile.extra_body_kind.?);
}
