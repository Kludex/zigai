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
const message_types = @import("../../messages.zig");
const provider_types = @import("../../provider.zig");
const transport = @import("../../transport.zig");

const NativeToolCall = message_types.NativeToolCall;
const NativeToolResult = message_types.NativeToolResult;

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
    .supports_streaming = true,
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
            .streamFn = stream,
        };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.sendBuffered(allocator, value, false);
    }

    /// Starts a stored conversation and returns its first response. The
    /// returned `conversation_id` can be passed to `Session.init`.
    pub fn start(
        self: *Client,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        return self.sendBuffered(allocator, value, true);
    }

    fn sendBuffered(
        self: *Client,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
        store: bool,
    ) !model_types.ModelResponse {
        const body = if (store)
            try encodeStoredRequest(allocator, self.model_name, value, self.managed_tools)
        else
            try encodeRequest(allocator, self.model_name, value, self.managed_tools);
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

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, value, self.managed_tools);
        defer allocator.free(body);
        var headers: std.ArrayList(transport.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "accept", .value = "text/event-stream" });
        if (value.request_id) |request_id|
            try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.deinit();
        const response = self.provider.streamLines(allocator, .{
            .method = .POST,
            .endpoint = "/conversations",
            .headers = headers.items,
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
            .url_policy = value.url_policy,
        }, state.lineSink()) catch |failure| return common.transportError(failure);
        if (response.status < 200 or response.status >= 300) {
            self.provider.observeError(
                allocator,
                response.status,
                state.error_body.items,
                response.metadata,
                value.error_observer,
                value.error_policy,
            );
            return common.statusError(response.status);
        }
        return state.finish() catch |failure| switch (failure) {
            error.InvalidProviderResponse => error.ProviderResponseDecodeError,
            else => failure,
        };
    }
};

/// Encodes one stateless native Conversations request.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
) ![]u8 {
    return encodeRequestMode(allocator, model_name, request, managed_tools, false, false);
}

/// Encodes the first request of an explicitly stored conversation.
pub fn encodeStoredRequest(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
) ![]u8 {
    return encodeRequestMode(allocator, model_name, request, managed_tools, true, false);
}

/// Encodes one stateless streaming Conversations request.
pub fn encodeStreamingRequest(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
) ![]u8 {
    return encodeRequestMode(allocator, model_name, request, managed_tools, false, true);
}

fn encodeRequestMode(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    managed_tools: []const ManagedTool,
    store: bool,
    streaming: bool,
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
    try json.write(store);
    try json.objectField("stream");
    try json.write(streaming);
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

/// Encodes entries appended to a stored conversation. Conversation-level
/// instructions and tool declarations belong to the initial request.
pub fn encodeAppendRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try validateSettings(request.settings);
    if (request.instructions.len > 0 or request.tools.len > 0 or request.builtin_tools.len > 0)
        return error.InvalidRequestEncoding;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("inputs");
    try json.beginArray();
    for (request.messages) |message| switch (message) {
        .request => |value| try writeRequestMessage(allocator, &json, value),
        .response => |value| try writeResponseMessage(allocator, &json, value),
    };
    try json.endArray();
    try writeCompletionArgs(allocator, &json, request);
    try json.objectField("store");
    try json.write(true);
    try json.objectField("stream");
    try json.write(false);
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        .mistral,
        &.{ "inputs", "completion_args", "store", "stream" },
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
        .native_tool_call => {},
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

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    text: std.ArrayList(u8) = .empty,
    parts: std.ArrayList(model_types.ResponsePart) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    function_calls: std.ArrayList(PendingFunctionCall) = .empty,
    tool_executions: std.ArrayList(PendingToolExecution) = .empty,
    usage: model_types.Usage = .{},
    conversation_id: ?[]const u8 = null,
    text_index: ?usize = null,
    next_part_index: usize = 0,
    pending_event: ?EventKind = null,
    saw_done: bool = false,

    const EventKind = enum {
        response_started,
        response_done,
        response_error,
        message_output,
        tool_started,
        tool_delta,
        tool_done,
        function_call,
        other,
    };

    const PendingFunctionCall = struct {
        output_index: usize,
        part_index: usize,
        id: []const u8,
        entry_id: ?[]const u8,
        name: []const u8,
        arguments: std.ArrayList(u8) = .empty,
    };

    const PendingToolExecution = struct {
        output_index: usize,
        part_index: usize,
        id: []const u8,
        name: []const u8,
        arguments: std.ArrayList(u8) = .empty,
        ended: bool = false,
    };

    fn deinit(self: *StreamState) void {
        self.text.deinit(self.allocator);
        self.parts.deinit(self.allocator);
        self.error_body.deinit(self.allocator);
        for (self.function_calls.items) |*call| call.arguments.deinit(self.allocator);
        self.function_calls.deinit(self.allocator);
        for (self.tool_executions.items) |*execution| execution.arguments.deinit(self.allocator);
        self.tool_executions.deinit(self.allocator);
    }

    fn lineSink(self: *StreamState) transport.LineSink {
        return .{ .context = self, .startFn = start, .lineFn = line };
    }

    fn start(context: *anyopaque, response: transport.StreamResponse) !void {
        const self: *StreamState = @ptrCast(@alignCast(context));
        self.status = response.status;
    }

    fn line(context: *anyopaque, value: []const u8) !void {
        const self: *StreamState = @ptrCast(@alignCast(context));
        if (self.status < 200 or self.status >= 300) {
            if (self.error_body.items.len > 0) try self.error_body.append(self.allocator, '\n');
            return self.error_body.appendSlice(self.allocator, value);
        }
        if (std.mem.startsWith(u8, value, "event:")) {
            self.pending_event = eventKind(std.mem.trim(u8, value["event:".len..], " "));
            return;
        }
        if (!std.mem.startsWith(u8, value, "data:")) return;
        const data = std.mem.trim(u8, value["data:".len..], " ");
        if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) return;
        const root = try json_limits.parseLeaky(
            std.json.Value,
            self.allocator,
            data,
            json_limits.defaults.provider_response,
            .{},
            error.InvalidProviderResponse,
        );
        const object = switch (root) {
            .object => |item| item,
            else => return error.InvalidProviderResponse,
        };
        const kind = if (try common.optionalObjectString(object, "type")) |name| eventKind(name) else self.pending_event orelse .other;
        self.pending_event = null;
        switch (kind) {
            .response_started => self.conversation_id = try common.objectString(object, "conversation_id"),
            .response_done => {
                if (object.get("usage")) |usage| self.usage = try decodeUsage(self.allocator, usage);
                try self.sink.emit(.{ .usage = self.usage });
                self.saw_done = true;
            },
            .response_error => return error.InvalidProviderResponse,
            .message_output => try self.messageDelta(object),
            .function_call => try self.functionCallDelta(object),
            .tool_started => try self.toolStarted(object),
            .tool_delta => try self.toolDelta(object),
            .tool_done => try self.toolDone(object),
            .other => {},
        }
    }

    fn messageDelta(self: *StreamState, object: std.json.ObjectMap) !void {
        const content = object.get("content") orelse return error.InvalidProviderResponse;
        const text = switch (content) {
            .string => |value| value,
            .object => |chunk| if (std.mem.eql(u8, try common.objectString(chunk, "type"), "text"))
                try common.objectString(chunk, "text")
            else
                null,
            else => return error.InvalidProviderResponse,
        };
        if (text) |delta| {
            const index = try self.ensureTextPart();
            try self.text.appendSlice(self.allocator, delta);
            try self.sink.emit(.{ .part_delta = .{
                .index = index,
                .delta = .{ .text = .{ .content_delta = delta, .provider = .{ .provider_name = "mistral" } } },
            } });
            return;
        }
        const before = self.parts.items.len;
        try decodeContentChunk(self.allocator, &self.parts, content);
        for (self.parts.items[before..]) |part| {
            const index = self.next_part_index;
            self.next_part_index += 1;
            try model_types.emitCompletePart(self.sink, index, part);
        }
    }

    fn functionCallDelta(self: *StreamState, object: std.json.ObjectMap) !void {
        const output_index = try outputIndex(object);
        const call = try self.findOrCreateFunctionCall(
            output_index,
            try common.objectString(object, "tool_call_id"),
            try common.optionalObjectString(object, "id"),
            try common.objectString(object, "name"),
        );
        const delta = try common.objectString(object, "arguments");
        try call.arguments.appendSlice(self.allocator, delta);
        try self.sink.emit(.{ .part_delta = .{
            .index = call.part_index,
            .delta = .{ .tool_call = .{
                .id = call.id,
                .name = call.name,
                .arguments_delta = delta,
                .provider = .{ .id = call.entry_id, .provider_name = "mistral" },
            } },
        } });
    }

    fn findOrCreateFunctionCall(
        self: *StreamState,
        output_index: usize,
        id: []const u8,
        entry_id: ?[]const u8,
        name: []const u8,
    ) !*PendingFunctionCall {
        for (self.function_calls.items) |*call| if (call.output_index == output_index) return call;
        const part_index = self.next_part_index;
        self.next_part_index += 1;
        try self.function_calls.append(self.allocator, .{
            .output_index = output_index,
            .part_index = part_index,
            .id = id,
            .entry_id = entry_id,
            .name = name,
        });
        try self.sink.emit(.{ .part_start = .{ .index = part_index, .part = .{ .tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = "",
            .provider = .{ .id = entry_id, .provider_name = "mistral" },
        } } } });
        return &self.function_calls.items[self.function_calls.items.len - 1];
    }

    fn toolStarted(self: *StreamState, object: std.json.ObjectMap) !void {
        const execution = try self.findOrCreateToolExecution(
            try outputIndex(object),
            try common.objectString(object, "id"),
            try common.objectString(object, "name"),
        );
        const arguments = try common.objectString(object, "arguments");
        try execution.arguments.appendSlice(self.allocator, arguments);
        if (arguments.len > 0) try self.sink.emit(.{ .part_delta = .{
            .index = execution.part_index,
            .delta = .{ .native_tool_call = .{
                .id = execution.id,
                .name = execution.name,
                .arguments_delta = arguments,
                .provider = .{ .id = execution.id, .provider_name = "mistral" },
            } },
        } });
    }

    fn toolDelta(self: *StreamState, object: std.json.ObjectMap) !void {
        const execution = try self.findOrCreateToolExecution(
            try outputIndex(object),
            try common.objectString(object, "id"),
            try common.objectString(object, "name"),
        );
        const delta = try common.objectString(object, "arguments");
        try execution.arguments.appendSlice(self.allocator, delta);
        try self.sink.emit(.{ .part_delta = .{
            .index = execution.part_index,
            .delta = .{ .native_tool_call = .{
                .id = execution.id,
                .name = execution.name,
                .arguments_delta = delta,
                .provider = .{ .id = execution.id, .provider_name = "mistral" },
            } },
        } });
    }

    fn findOrCreateToolExecution(
        self: *StreamState,
        output_index: usize,
        id: []const u8,
        name: []const u8,
    ) !*PendingToolExecution {
        for (self.tool_executions.items) |*execution| if (execution.output_index == output_index) return execution;
        const part_index = self.next_part_index;
        self.next_part_index += 1;
        try self.tool_executions.append(self.allocator, .{
            .output_index = output_index,
            .part_index = part_index,
            .id = id,
            .name = name,
        });
        try self.sink.emit(.{ .part_start = .{ .index = part_index, .part = .{ .native_tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = "",
            .provider = .{ .id = id, .provider_name = "mistral" },
        } } } });
        return &self.tool_executions.items[self.tool_executions.items.len - 1];
    }

    fn toolDone(self: *StreamState, object: std.json.ObjectMap) !void {
        const execution = try self.findOrCreateToolExecution(
            try outputIndex(object),
            try common.objectString(object, "id"),
            try common.objectString(object, "name"),
        );
        if (execution.ended) return error.InvalidProviderResponse;
        execution.ended = true;
        const arguments = if (execution.arguments.items.len == 0) "{}" else execution.arguments.items;
        const call = NativeToolCall{
            .id = execution.id,
            .name = execution.name,
            .arguments_json = try self.allocator.dupe(u8, arguments),
            .provider = .{ .id = execution.id, .provider_name = "mistral" },
        };
        try self.sink.emit(.{ .part_end = .{ .index = execution.part_index, .part = .{ .native_tool_call = call } } });
        try self.parts.append(self.allocator, .{ .native_tool_call = call });

        const info = object.get("info") orelse std.json.Value{ .null = {} };
        const content = if (info == .null) "" else try std.json.Stringify.valueAlloc(self.allocator, info, .{});
        const details = try makeToolExecutionDetails(
            self.allocator,
            execution.id,
            execution.name,
            arguments,
            info,
        );
        const result = NativeToolResult{
            .call_id = execution.id,
            .name = execution.name,
            .content = content,
            .provider = .{ .id = execution.id, .provider_name = "mistral", .provider_details = details },
        };
        const result_index = self.next_part_index;
        self.next_part_index += 1;
        try model_types.emitCompletePart(self.sink, result_index, .{ .native_tool_return = result });
        try self.parts.append(self.allocator, .{ .native_tool_return = result });
    }

    fn ensureTextPart(self: *StreamState) !usize {
        if (self.text_index) |index| return index;
        const index = self.next_part_index;
        self.next_part_index += 1;
        self.text_index = index;
        try self.sink.emit(.{ .part_start = .{ .index = index, .part = .{ .text_part = .{
            .content = "",
            .provider = .{ .provider_name = "mistral" },
        } } } });
        return index;
    }

    fn finish(self: *StreamState) !model_types.ModelResponse {
        if (!self.saw_done) return error.InvalidProviderResponse;
        if (self.text_index) |index| {
            const text = try self.text.toOwnedSlice(self.allocator);
            const part = model_types.ResponsePart{ .text_part = .{
                .content = text,
                .provider = .{ .provider_name = "mistral" },
            } };
            try self.sink.emit(.{ .part_end = .{ .index = index, .part = part } });
            try self.parts.insert(self.allocator, @min(index, self.parts.items.len), part);
            self.text_index = null;
        }
        for (self.function_calls.items) |*pending| {
            const arguments = if (pending.arguments.items.len == 0)
                try self.allocator.dupe(u8, "{}")
            else
                try pending.arguments.toOwnedSlice(self.allocator);
            const call = model_types.ToolCall{
                .id = pending.id,
                .name = pending.name,
                .arguments_json = arguments,
                .provider = .{ .id = pending.entry_id, .provider_name = "mistral" },
            };
            try self.sink.emit(.{ .part_end = .{ .index = pending.part_index, .part = .{ .tool_call = call } } });
            try self.parts.append(self.allocator, .{ .tool_call = call });
        }
        return .{
            .parts = try self.parts.toOwnedSlice(self.allocator),
            .usage = self.usage,
            .conversation_id = self.conversation_id,
            .provider_response_id = self.conversation_id,
            .finish_reason = .{
                .kind = if (self.function_calls.items.len > 0) .tool_calls else .stop,
                .raw = "completed",
            },
        };
    }
};

fn eventKind(value: []const u8) StreamState.EventKind {
    if (std.mem.eql(u8, value, "conversation.response.started")) return .response_started;
    if (std.mem.eql(u8, value, "conversation.response.done")) return .response_done;
    if (std.mem.eql(u8, value, "conversation.response.error")) return .response_error;
    if (std.mem.eql(u8, value, "message.output.delta")) return .message_output;
    if (std.mem.eql(u8, value, "tool.execution.started")) return .tool_started;
    if (std.mem.eql(u8, value, "tool.execution.delta")) return .tool_delta;
    if (std.mem.eql(u8, value, "tool.execution.done")) return .tool_done;
    if (std.mem.eql(u8, value, "function.call.delta")) return .function_call;
    return .other;
}

fn outputIndex(object: std.json.ObjectMap) !usize {
    const value = try common.optionalObjectInteger(object, "output_index") orelse 0;
    return std.math.cast(usize, value) orelse error.InvalidProviderResponse;
}

fn makeToolExecutionDetails(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    info: std.json.Value,
) !model_types.ProviderDetails {
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .object = "entry",
        .type = "tool.execution",
        .id = id,
        .name = name,
        .arguments = arguments,
        .info = info,
    }, .{});
    defer allocator.free(encoded);
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        encoded,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    );
    return model_types.ProviderDetails.fromValue(value);
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
    if (std.mem.eql(u8, kind, "tool.execution")) {
        const details = try model_types.ProviderDetails.fromValue(output);
        const id = try common.optionalObjectString(object, "id") orelse kind;
        const name = try common.objectString(object, "name");
        const arguments = try common.objectString(object, "arguments");
        try parts.append(allocator, .{ .native_tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = arguments,
            .provider = .{ .id = id, .provider_name = "mistral" },
        } });
        const content = if (object.get("info")) |info|
            try std.json.Stringify.valueAlloc(allocator, info, .{})
        else
            "";
        try parts.append(allocator, .{ .native_tool_return = .{
            .call_id = id,
            .name = name,
            .content = content,
            .provider = .{ .id = id, .provider_name = "mistral", .provider_details = details },
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
    try std.testing.expectEqualStrings("web_search", response.parts[1].native_tool_call.name);
    try std.testing.expectEqualStrings("web_search", response.parts[2].native_tool_return.name);
    try std.testing.expectEqualStrings("weather", response.parts[3].tool_call.name);
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

test "native client streams text local calls and managed executions" {
    const State = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            return error.UnexpectedRequest;
        }

        fn stream(_: *anyopaque, _: std.mem.Allocator, request: transport.Request, sink: transport.LineSink) !transport.StreamResponse {
            try std.testing.expectEqualStrings("https://api.mistral.ai/v1/conversations", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"stream\":true") != null);
            try sink.start(.{ .status = 200 });
            try sink.line("event: conversation.response.started");
            try sink.line("data: {\"conversation_id\":\"conv_stream\"}");
            try sink.line("data: {\"type\":\"message.output.delta\",\"id\":\"msg_1\",\"content\":\"po\"}");
            try sink.line("data: {\"type\":\"message.output.delta\",\"id\":\"msg_1\",\"content\":{\"type\":\"text\",\"text\":\"ng\"}}");
            try sink.line("data: {\"type\":\"tool.execution.started\",\"output_index\":1,\"id\":\"exec_1\",\"name\":\"web_search\",\"arguments\":\"{\"}");
            try sink.line("data: {\"type\":\"tool.execution.delta\",\"output_index\":1,\"id\":\"exec_1\",\"name\":\"web_search\",\"arguments\":\"}\"}");
            try sink.line("data: {\"type\":\"tool.execution.done\",\"output_index\":1,\"id\":\"exec_1\",\"name\":\"web_search\",\"info\":{\"results\":1}}");
            try sink.line("data: {\"type\":\"function.call.delta\",\"output_index\":2,\"id\":\"entry_1\",\"tool_call_id\":\"call_1\",\"name\":\"weather\",\"arguments\":\"{}\"}");
            try sink.line("data: {\"type\":\"conversation.response.done\",\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}");
            return .{ .status = 200 };
        }
    };
    const Capture = struct {
        starts: usize = 0,
        deltas: usize = 0,
        ends: usize = 0,
        usage_events: usize = 0,

        fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .part_start => self.starts += 1,
                .part_delta => self.deltas += 1,
                .part_end => self.ends += 1,
                .usage => self.usage_events += 1,
            }
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{
        .context = &marker,
        .sendFn = State.send,
        .streamLinesFn = State.stream,
    });
    var client = Client{ .model_name = "mistral-small-latest", .provider = provider.provider() };
    var capture: Capture = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().stream(arena.allocator(), .{ .messages = &.{} }, .{
        .context = &capture,
        .eventFn = Capture.emit,
    });
    try std.testing.expectEqualStrings("conv_stream", response.conversation_id.?);
    try std.testing.expectEqualStrings("pong", response.parts[0].text_part.content);
    try std.testing.expectEqualStrings("{}", response.parts[1].native_tool_call.arguments_json);
    try std.testing.expectEqualStrings("web_search", response.parts[2].native_tool_return.name);
    try std.testing.expectEqualStrings("weather", response.parts[3].tool_call.name);
    try std.testing.expectEqual(@as(u64, 2), response.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 4), capture.starts);
    try std.testing.expectEqual(@as(usize, 5), capture.deltas);
    try std.testing.expectEqual(@as(usize, 4), capture.ends);
    try std.testing.expectEqual(@as(usize, 1), capture.usage_events);
}
