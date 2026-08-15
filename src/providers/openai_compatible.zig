//! OpenAI-compatible Chat Completions client for gateways and local servers.

const std = @import("std");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const http_provider = @import("http.zig");
const operations = @import("operations.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");
const provider_profiles = @import("profiles.zig");

pub const api_base = "https://api.openai.com/v1";

pub const Error = model_types.ProviderRequestError || error{
    /// A successful payload does not match OpenAI Chat Completions.
    InvalidProviderResponse,
    /// Provider-neutral input cannot be encoded as Chat Completions.
    InvalidRequestEncoding,
};

pub const profiles = provider_profiles.openai_compatible;

/// Authentication applied to compatible API requests.
pub const Authentication = struct {
    /// HTTP header carrying the credential.
    header: []const u8 = "authorization",
    /// Text placed before the credential, normally `Bearer `.
    prefix: []const u8 = "Bearer ",
};

/// Compile-time defaults used to define a first-class compatible provider.
pub const ClientDefaults = struct {
    base_url: []const u8 = api_base,
    provider_name: []const u8 = "openai-compatible",
    profile: model_types.ModelProfile = profiles.full,
    /// Built-in capabilities for model families recognized by a named
    /// provider. Application lookups take precedence and overrides run last.
    model_profile_lookup: ?*const fn ([]const u8) ?model_types.ModelProfile = null,
    authentication: Authentication = .{},
    include_stream_usage: bool = true,
    extra_body_kind: model_types.ExtraBodyKind = .openai_compatible,
    provider_details_field: ?[]const u8 = null,
};

/// Defines provider state for an OpenAI-compatible API while retaining
/// compile-time defaults for named providers.
pub fn ProviderWithDefaults(comptime defaults: ClientDefaults) type {
    return struct {
        http: http_provider.Configured,
        discovery_limits: operations.DiscoveryLimits,
        application_model_profiles: ?http_provider.Configured.ModelProfiles,

        const Self = @This();

        pub const Options = struct {
            base_url: []const u8 = defaults.base_url,
            provider_name: []const u8 = defaults.provider_name,
            authentication: Authentication = defaults.authentication,
            headers: []const http.Header = &.{},
            request_policy: provider_types.RequestPolicy = .{},
            file_limits: provider_types.FileLimits = .{},
            model_profiles: ?http_provider.Configured.ModelProfiles = null,
            discovery_limits: operations.DiscoveryLimits = .{},
        };

        pub fn init(api_key: []const u8, transport: http.Transport) Self {
            return initWithOptions(api_key, transport, .{});
        }

        pub fn initWithOptions(api_key: []const u8, transport: http.Transport, options: Options) Self {
            return .{
                .http = .{
                    .name = options.provider_name,
                    .base_url = options.base_url,
                    .transport = transport,
                    .credential = .{ .header = .{
                        .name = options.authentication.header,
                        .value = api_key,
                        .prefix = options.authentication.prefix,
                    } },
                    .headers = options.headers,
                    .request_policy = options.request_policy,
                    .file_limits = options.file_limits,
                },
                .discovery_limits = options.discovery_limits,
                .application_model_profiles = options.model_profiles,
            };
        }

        pub fn provider(self: *Self) provider_types.Provider {
            self.http.model_profiles = if (defaults.model_profile_lookup != null or self.application_model_profiles != null)
                .{
                    .context = self,
                    .lookupFn = lookupModelProfile,
                    .overrideFn = overrideModelProfile,
                }
            else
                null;
            self.http.operations = .{
                .context = self,
                .listModelsFn = listModels,
            };
            return self.http.provider();
        }

        fn listModels(context: *anyopaque, allocator: std.mem.Allocator) !provider_types.OwnedModels {
            const self: *Self = @ptrCast(@alignCast(context));
            return operations.listOpenAIModels(&self.http, allocator, self.discovery_limits);
        }

        fn lookupModelProfile(context: *anyopaque, model_name: []const u8) ?model_types.ModelProfile {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.application_model_profiles) |application| {
                if (application.lookupFn) |lookup| {
                    if (lookup(application.context, model_name)) |profile| return profile;
                }
            }
            if (defaults.model_profile_lookup) |lookup| return lookup(model_name);
            return null;
        }

        fn overrideModelProfile(
            context: *anyopaque,
            model_name: []const u8,
            profile: model_types.ModelProfile,
        ) model_types.ModelProfile {
            const self: *Self = @ptrCast(@alignCast(context));
            const application = self.application_model_profiles orelse return profile;
            const apply = application.overrideFn orelse return profile;
            return apply(application.context, model_name, profile);
        }
    };
}

pub const Provider = ProviderWithDefaults(.{});

/// Defines a Chat Completions adapter with provider-specific model defaults.
/// Runtime connection configuration belongs to `ProviderWithDefaults`.
pub fn ClientWithDefaults(comptime defaults: ClientDefaults) type {
    return struct {
        model_name: []const u8,
        provider: provider_types.Provider,
        profile: model_types.ModelProfile = defaults.profile,
        /// Optional gateway-specific header used to deduplicate retries.
        idempotency_header: ?[]const u8 = null,
        include_stream_usage: bool = defaults.include_stream_usage,
        settings: model_types.ModelSettings = .{},

        const Self = @This();

        pub fn model(self: *Self) model_types.Model {
            var model_profile = self.provider.modelProfile(self.model_name, self.profile);
            model_profile.supports_idempotency_key = self.idempotency_header != null;
            model_profile.extra_body_kind = defaults.extra_body_kind;
            return .{
                .context = self,
                .profile = model_profile,
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
            const self: *Self = @ptrCast(@alignCast(context));
            const body = try encodeRequestFor(allocator, self.model_name, value, defaults.extra_body_kind);
            defer allocator.free(body);
            var headers: std.ArrayList(http.Header) = .empty;
            defer headers.deinit(allocator);
            try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
            if (value.request_id) |request_id| try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
            if (self.idempotency_header) |name| if (value.idempotency_key) |key|
                try headers.append(allocator, .{ .name = name, .value = key });
            try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
            const response = self.provider.request(allocator, .{
                .method = .POST,
                .endpoint = "/chat/completions",
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
            return decodeResponseFor(allocator, response.body, defaults.provider_details_field) catch |failure| return common.responseDecodeError(failure);
        }

        fn stream(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            value: model_types.ModelRequest,
            sink: model_types.ModelStreamSink,
        ) !model_types.ModelResponse {
            const self: *Self = @ptrCast(@alignCast(context));
            const body = try encodeStreamingRequestFor(allocator, self.model_name, value, self.include_stream_usage, defaults.extra_body_kind);
            defer allocator.free(body);
            var headers: std.ArrayList(http.Header) = .empty;
            defer headers.deinit(allocator);
            try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
            if (value.request_id) |request_id| try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
            if (self.idempotency_header) |name| if (value.idempotency_key) |key|
                try headers.append(allocator, .{ .name = name, .value = key });
            try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
            var state = StreamState{
                .allocator = allocator,
                .sink = sink,
                .provider_details_field = defaults.provider_details_field,
            };
            defer state.deinit();
            const response = self.provider.streamLines(allocator, .{
                .method = .POST,
                .endpoint = "/chat/completions",
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
            try state.finalizeCalls();
            try state.finishText();
            if (state.text.items.len > 0) {
                try state.parts.insert(allocator, 0, .{ .text = try state.text.toOwnedSlice(allocator) });
            }
            return .{
                .parts = try state.parts.toOwnedSlice(allocator), // kcov-ignore
                .usage = state.usage,
                .finish_reason = state.finish_reason,
                .provider_details = state.provider_details,
            };
        }
    };
}

pub const Client = ClientWithDefaults(.{});

pub fn encodeRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest) ![]u8 {
    return encodeRequestFor(allocator, model_name, request, .openai_compatible);
}

fn encodeRequestFor(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    extra_body_kind: model_types.ExtraBodyKind,
) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try common.validateToolChoice(request.tools, request.builtin_tools.len, request.settings.tool_choice);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("messages");
    try json.beginArray();
    for (request.instructions) |instruction| {
        try json.beginObject();
        try json.objectField("role");
        try json.write("system");
        try json.objectField("content");
        try json.write(instruction);
        try json.endObject();
    }
    for (request.messages) |message| switch (message) {
        .request => |request_message| for (request_message.parts) |part| switch (part) {
            .system_prompt => |text| try writeTextMessage(&json, "system", text),
            .system_prompt_part => |prompt| try writeTextMessage(&json, "system", prompt.content),
            .retry_prompt => |text| try writeTextMessage(&json, "user", text),
            .retry_prompt_part => |prompt| try writeTextMessage(&json, "user", prompt.content),
            .user_prompt => |content| switch (content) {
                .text => |text| try writeTextMessage(&json, "user", text),
                .text_content => |text| try writeTextMessage(&json, "user", text.content),
                .cache_point => {},
                else => return error.InvalidRequestEncoding,
            },
            .user_prompt_part => |prompt| switch (prompt.content) {
                .text => |text| try writeTextMessage(&json, "user", text),
                .text_content => |text| try writeTextMessage(&json, "user", text.content),
                .cache_point => {},
                else => return error.InvalidRequestEncoding,
            },
            .tool_return => |result| try writeToolResult(&json, result),
            .speech => |speech| {
                try ensureProviderPartReplayable(speech.provider);
                if (speech.transcript) |text|
                    try writeTextMessage(&json, "user", text)
                else
                    return error.InvalidRequestEncoding;
            },
            .capability_load_return => |result| try writeToolResult(&json, common.capabilityLoadToolResult(result)),
            .tool_search_return, .tool_availability_delta => return error.InvalidRequestEncoding,
        },
        .response => |response| try writeResponseMessage(allocator, &json, response),
    };
    try json.endArray();
    if (request.tools.len > 0) {
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
            try common.rawJson(allocator, &json, tool.parameters_json_schema, json_limits.defaults.schema);
            try json.endObject();
            try json.endObject();
        }
        try json.endArray();
    }
    if (request.settings.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }
    if (request.settings.max_tokens) |max_tokens| {
        try json.objectField("max_tokens");
        try json.write(max_tokens);
    }
    if (request.settings.stop_sequences) |stop_sequences| {
        try json.objectField("stop");
        try json.write(stop_sequences);
    }
    if (request.settings.seed) |seed| {
        try json.objectField("seed");
        try json.write(seed);
    }
    if (request.settings.reasoning_effort) |effort| {
        try json.objectField("reasoning_effort");
        try json.write(@tagName(effort));
    }
    if (request.settings.top_p) |top_p| {
        try json.objectField("top_p");
        try json.write(top_p);
    }
    if (request.settings.presence_penalty) |penalty| {
        try json.objectField("presence_penalty");
        try json.write(penalty);
    }
    if (request.settings.frequency_penalty) |penalty| {
        try json.objectField("frequency_penalty");
        try json.write(penalty);
    }
    if (request.settings.logprobs) |logprobs| {
        try json.objectField("logprobs");
        try json.write(true);
        try json.objectField("top_logprobs");
        try json.write(logprobs.top);
    }
    if (request.settings.parallel_tool_calls) |enabled| {
        try json.objectField("parallel_tool_calls");
        try json.write(enabled);
    }
    if (request.settings.tool_choice) |choice| try writeToolChoice(&json, choice);
    if (request.settings.service_tier) |tier| {
        try json.objectField("service_tier");
        try json.write(@tagName(tier));
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
            try json.objectField("strict");
            try json.write(format.strict);
            try json.objectField("schema");
            try common.rawJson(allocator, &json, format.schema, json_limits.defaults.schema);
            try json.endObject();
            try json.endObject();
        },
    }
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        extra_body_kind,
        &.{
            "model",
            "messages",
            "tools",
            "temperature",
            "max_tokens",
            "stop",
            "seed",
            "reasoning_effort",
            "top_p",
            "presence_penalty",
            "frequency_penalty",
            "logprobs",
            "top_logprobs",
            "parallel_tool_calls",
            "tool_choice",
            "service_tier",
            "response_format",
            "stream",
            "stream_options",
        },
    );
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeToolChoice(json: *std.json.Stringify, choice: model_types.ToolChoice) !void {
    try json.objectField("tool_choice");
    switch (choice) {
        .auto => try json.write("auto"),
        .none => try json.write("none"),
        .required, .allowed => try json.write("required"),
        .tool => |name| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("function");
            try json.beginObject();
            try json.objectField("name");
            try json.write(name);
            try json.endObject();
            try json.endObject();
        },
    }
}

pub fn encodeStreamingRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest, include_usage: bool) ![]u8 {
    return encodeStreamingRequestFor(allocator, model_name, request, include_usage, .openai_compatible);
}

fn encodeStreamingRequestFor(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: model_types.ModelRequest,
    include_usage: bool,
    extra_body_kind: model_types.ExtraBodyKind,
) ![]u8 {
    const buffered = try encodeRequestFor(allocator, model_name, request, extra_body_kind);
    defer allocator.free(buffered);
    if (buffered.len == 0 or buffered[buffered.len - 1] != '}') return error.InvalidRequestEncoding;
    if (include_usage) return std.fmt.allocPrint(
        allocator,
        "{s},\"stream\":true,\"stream_options\":{{\"include_usage\":true}}}}",
        .{buffered[0 .. buffered.len - 1]},
    );
    return std.fmt.allocPrint(allocator, "{s},\"stream\":true}}", .{buffered[0 .. buffered.len - 1]});
}

fn writeResponseMessage(allocator: std.mem.Allocator, json: *std.json.Stringify, message: model_types.ResponseMessage) !void {
    for (message.parts) |part| switch (part) {
        .text => {},
        .text_part => |text| try ensureProviderPartReplayable(text.provider),
        .tool_call => |call| {
            try ensureProviderPartReplayable(call.provider);
            if (call.thought_signature != null) return error.InvalidRequestEncoding;
        },
        .capability_load_call => {},
        .speech => |speech| {
            try ensureProviderPartReplayable(speech.provider);
            if (speech.transcript == null) return error.InvalidRequestEncoding;
        },
        else => return error.InvalidRequestEncoding,
    };
    const text = try collectText(allocator, message.parts);
    defer allocator.free(text);
    try json.beginObject();
    try json.objectField("role");
    try json.write("assistant");
    try json.objectField("content");
    if (text.len > 0) try json.write(text) else try json.write(null);
    var has_calls = false;
    for (message.parts) |part| if (part == .tool_call or part == .capability_load_call) {
        has_calls = true;
        break;
    };
    if (has_calls) {
        try json.objectField("tool_calls");
        try json.beginArray();
        for (message.parts) |part| switch (part) {
            .tool_call => |call| {
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
                try json.write(call.arguments_json);
                try json.endObject();
                try json.endObject();
            },
            .capability_load_call => |call| {
                const portable = try common.capabilityLoadToolCall(allocator, call);
                defer allocator.free(portable.arguments_json);
                try json.beginObject();
                try json.objectField("id");
                try json.write(portable.id);
                try json.objectField("type");
                try json.write("function");
                try json.objectField("function");
                try json.beginObject();
                try json.objectField("name");
                try json.write(portable.name);
                try json.objectField("arguments");
                try json.write(portable.arguments_json);
                try json.endObject();
                try json.endObject();
            },
            else => {},
        };
        try json.endArray();
    }
    try json.endObject();
}

fn writeTextMessage(json: *std.json.Stringify, role: []const u8, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("role");
    try json.write(role);
    try json.objectField("content");
    try json.write(text);
    try json.endObject();
}

fn writeToolResult(json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len > 0) return error.InvalidRequestEncoding;
    try json.beginObject();
    try json.objectField("role");
    try json.write("tool");
    try json.objectField("tool_call_id");
    try json.write(result.call_id);
    try json.objectField("content");
    try json.write(result.content);
    try json.endObject();
}

fn collectText(allocator: std.mem.Allocator, parts: []const model_types.Part) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    for (parts) |part| switch (part) {
        .text => |value| try text.appendSlice(allocator, value),
        .text_part => |value| try text.appendSlice(allocator, value.content),
        .speech => |value| if (value.transcript) |transcript| try text.appendSlice(allocator, transcript),
        else => {},
    };
    return text.toOwnedSlice(allocator);
}

fn ensureProviderPartReplayable(provider: model_types.ProviderPart) !void {
    if (provider.requiresReplay()) return error.InvalidRequestEncoding;
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    return decodeResponseFor(allocator, body, null);
}

fn decodeResponseFor(
    allocator: std.mem.Allocator,
    body: []const u8,
    provider_details_field: ?[]const u8,
) !model_types.ModelResponse {
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
    const choices = try common.requiredArray(root, "choices");
    if (choices.items.len == 0) return error.InvalidProviderResponse;
    const choice = switch (choices.items[0]) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const message = try common.requiredObject(.{ .object = choice }, "message");
    var finish_reason = if (try common.optionalObjectString(choice, "finish_reason")) |reason|
        compatibleFinishReason(reason)
    else
        null;
    var parts: std.ArrayList(model_types.Part) = .empty;
    if (message.get("content")) |content| switch (content) {
        .string => |text| if (text.len > 0) try parts.append(allocator, .{ .text = text }),
        .null => {},
        else => return error.InvalidProviderResponse,
    };
    if (message.get("tool_calls")) |calls_value| {
        const calls = switch (calls_value) {
            .array => |value| value,
            .null => null,
            else => return error.InvalidProviderResponse,
        };
        for (if (calls) |value| value.items else &.{}) |call_value| {
            const call = switch (call_value) {
                .object => |value| value,
                else => return error.InvalidProviderResponse,
            };
            const function = try common.requiredObject(.{ .object = call }, "function");
            const arguments = try common.objectString(function, "arguments");
            if (!try validToolArguments(allocator, arguments)) {
                finish_reason = .{
                    .kind = .incomplete_tool_call,
                    .raw = if (finish_reason) |reason| reason.raw else "malformed_tool_arguments",
                };
                continue;
            }
            try parts.append(allocator, .{ .tool_call = .{
                .id = try common.objectString(call, "id"),
                .name = try common.objectString(function, "name"),
                .arguments_json = arguments,
            } });
        }
    }
    return .{
        .parts = try parts.toOwnedSlice(allocator),
        .usage = try decodeUsage(allocator, root),
        .finish_reason = finish_reason,
        .provider_details = try responseProviderDetails(object, provider_details_field),
        .provider_response_id = try common.optionalObjectString(object, "id"),
        .model_name = try common.optionalObjectString(object, "model"),
    };
}

fn responseProviderDetails(
    object: std.json.ObjectMap,
    field: ?[]const u8,
) !?model_types.ProviderDetails {
    const name = field orelse return null;
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => try model_types.ProviderDetails.fromValue(value),
        .null => null,
        else => error.InvalidProviderResponse,
    };
}

fn compatibleFinishReason(raw: []const u8) model_types.FinishReason {
    const kind: model_types.FinishReason.Kind = if (std.mem.eql(u8, raw, "stop"))
        .stop
    else if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call"))
        .tool_calls
    else if (std.mem.eql(u8, raw, "length"))
        .length
    else if (std.mem.eql(u8, raw, "content_filter"))
        .content_filter
    else
        .other;
    return .{ .kind = kind, .raw = raw };
}

fn decodeUsage(allocator: std.mem.Allocator, root: std.json.Value) !model_types.Usage {
    const object = switch (root) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const usage_value = object.get("usage") orelse return .{};
    const usage = switch (usage_value) {
        .object => |value| value,
        .null => return .{},
        else => return error.InvalidProviderResponse,
    };
    const prompt_details = if (usage.get("prompt_tokens_details")) |value| switch (value) {
        .object => |details| details,
        .null => null,
        else => return error.InvalidProviderResponse,
    } else null;
    const completion_details = if (usage.get("completion_tokens_details")) |value| switch (value) {
        .object => |details| details,
        .null => null,
        else => return error.InvalidProviderResponse,
    } else null;
    var details: std.ArrayList(model_types.UsageDetail) = .empty;
    if (try common.optionalObjectInteger(usage, "total_tokens")) |value| {
        try details.append(allocator, .{ .name = "total_tokens", .value = value });
    }
    const cost = if (try common.optionalObjectNumber(usage, "cost")) |value|
        model_types.UsageCost.fromUsd(value) catch return error.InvalidProviderResponse
    else
        null;
    return .{
        .input_tokens = try common.objectInteger(usage, "prompt_tokens"),
        .cache_write_tokens = if (prompt_details) |value|
            try common.optionalObjectInteger(value, "cache_write_tokens") orelse 0
        else
            0,
        .cache_read_tokens = if (prompt_details) |value|
            try common.optionalObjectInteger(value, "cached_tokens") orelse 0
        else
            0,
        .output_tokens = try common.objectInteger(usage, "completion_tokens"),
        .reasoning_tokens = if (completion_details) |value|
            try common.optionalObjectInteger(value, "reasoning_tokens") orelse 0
        else
            0,
        .input_audio_tokens = if (prompt_details) |value|
            try common.optionalObjectInteger(value, "audio_tokens") orelse 0
        else
            0,
        .output_audio_tokens = if (completion_details) |value|
            try common.optionalObjectInteger(value, "audio_tokens") orelse 0
        else
            0,
        .details = try details.toOwnedSlice(allocator),
        .cost = cost,
        .cost_source = if (cost != null) .provider else null,
    };
}

const PendingCall = struct {
    index: u64,
    part_index: usize,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    finalized: bool = false,

    fn deinit(self: *PendingCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    text: std.ArrayList(u8) = .empty,
    parts: std.ArrayList(model_types.Part) = .empty,
    pending: std.ArrayList(PendingCall) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,
    provider_details_field: ?[]const u8 = null,
    provider_details: ?model_types.ProviderDetails = null,
    text_index: ?usize = null,
    next_part_index: usize = 0,

    fn deinit(self: *StreamState) void {
        self.text.deinit(self.allocator);
        self.parts.deinit(self.allocator);
        for (self.pending.items) |*call| call.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.error_body.deinit(self.allocator);
    }

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
        if (std.mem.eql(u8, data, "[DONE]")) return self.finalizeCalls();
        const root = try json_limits.parseLeaky(
            std.json.Value,
            self.allocator,
            data,
            json_limits.defaults.provider_response,
            .{},
            error.InvalidProviderResponse,
        );
        if (self.provider_details_field) |field| {
            const object = switch (root) {
                .object => |item| item,
                else => return error.InvalidProviderResponse,
            };
            if (object.get(field) != null)
                self.provider_details = try responseProviderDetails(object, field);
        }
        const usage = try decodeUsage(self.allocator, root);
        if (usage.input_tokens != 0 or usage.output_tokens != 0) {
            self.usage = usage;
            try self.sink.emit(.{ .usage = usage });
        }
        const choices = try common.requiredArray(root, "choices");
        if (choices.items.len == 0) return;
        const choice = switch (choices.items[0]) {
            .object => |item| item,
            else => return error.InvalidProviderResponse,
        };
        const delta = try common.requiredObject(.{ .object = choice }, "delta");
        if (delta.get("content")) |content| switch (content) {
            .string => |text| if (text.len > 0) {
                const index = try self.ensureTextPart();
                try self.text.appendSlice(self.allocator, text);
                try self.sink.emit(.{ .part_delta = .{
                    .index = index,
                    .delta = .{ .text = .{ .content_delta = text } },
                } });
            },
            .null => {},
            else => return error.InvalidProviderResponse,
        };
        if (delta.get("tool_calls")) |calls_value| {
            const calls = switch (calls_value) {
                .array => |item| item,
                else => return error.InvalidProviderResponse,
            };
            for (calls.items) |call_value| try self.appendCallDelta(call_value);
        }
        if (try common.optionalObjectString(choice, "finish_reason")) |reason| {
            self.finish_reason = compatibleFinishReason(reason);
            if (self.finish_reason.?.kind == .tool_calls) try self.finalizeCalls();
        }
    }

    fn appendCallDelta(self: *StreamState, value: std.json.Value) !void {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidProviderResponse,
        };
        const index = try common.objectInteger(object, "index");
        const pending = try self.findOrAppend(index);
        const id = optionalString(object, "id") orelse "";
        if (id.len > 0) try pending.id.appendSlice(self.allocator, id);
        var name: []const u8 = "";
        var arguments: []const u8 = "";
        if (object.get("function")) |function_value| {
            const function = switch (function_value) {
                .object => |item| item,
                else => return error.InvalidProviderResponse,
            };
            name = optionalString(function, "name") orelse "";
            arguments = optionalString(function, "arguments") orelse "";
            try pending.name.appendSlice(self.allocator, name);
            try pending.arguments.appendSlice(self.allocator, arguments);
        }
        try self.sink.emit(.{ .part_delta = .{
            .index = pending.part_index,
            .delta = .{ .tool_call = .{
                .id = if (id.len > 0) id else null,
                .name = if (name.len > 0) name else null,
                .arguments_delta = arguments,
            } },
        } });
    }

    fn findOrAppend(self: *StreamState, index: u64) !*PendingCall {
        for (self.pending.items) |*call| if (call.index == index) return call;
        const part_index = self.next_part_index;
        self.next_part_index += 1;
        try self.pending.append(self.allocator, .{ .index = index, .part_index = part_index });
        try self.sink.emit(.{ .part_start = .{ .index = part_index, .part = .{ .tool_call = .{
            .id = "",
            .name = "",
            .arguments_json = "{}",
        } } } });
        return &self.pending.items[self.pending.items.len - 1];
    }

    fn finalizeCalls(self: *StreamState) !void {
        for (self.pending.items) |*pending| {
            if (pending.finalized) continue;
            if (pending.id.items.len == 0 or pending.name.items.len == 0 or pending.arguments.items.len == 0) {
                self.finish_reason = .{
                    .kind = .incomplete_tool_call,
                    .raw = if (self.finish_reason) |reason| reason.raw else "incomplete_tool_call",
                };
                pending.finalized = true;
                continue;
            }
            if (!try validToolArguments(self.allocator, pending.arguments.items)) {
                self.finish_reason = .{
                    .kind = .incomplete_tool_call,
                    .raw = if (self.finish_reason) |reason| reason.raw else "malformed_tool_arguments",
                };
                pending.finalized = true;
                continue;
            }
            const call = model_types.ToolCall{
                .id = try pending.id.toOwnedSlice(self.allocator),
                .name = try pending.name.toOwnedSlice(self.allocator),
                .arguments_json = try pending.arguments.toOwnedSlice(self.allocator),
            };
            pending.finalized = true;
            try self.parts.append(self.allocator, .{ .tool_call = call });
            try self.sink.emit(.{ .part_end = .{
                .index = pending.part_index,
                .part = .{ .tool_call = call },
            } });
        }
    }

    fn ensureTextPart(self: *StreamState) !usize {
        if (self.text_index) |index| return index;
        const index = self.next_part_index;
        self.next_part_index += 1;
        self.text_index = index;
        try self.sink.emit(.{ .part_start = .{ .index = index, .part = .{ .text = "" } } });
        return index;
    }

    fn finishText(self: *StreamState) !void {
        const index = self.text_index orelse return;
        try self.sink.emit(.{ .part_end = .{ .index = index, .part = .{ .text = self.text.items } } });
        self.text_index = null;
    }
};

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |item| item,
        .null => null,
        else => null,
    };
}

fn validToolArguments(allocator: std.mem.Allocator, arguments: []const u8) !bool {
    return json_limits.isValid(allocator, arguments, json_limits.defaults.tool_payload);
}

test "encodes Chat Completions messages, tools, and schema output" {
    const body = try encodeRequest(std.testing.allocator, "model", .{
        .messages = &.{
            .{ .request = .{ .parts = &.{
                .{ .system_prompt = "system" },
                .{ .retry_prompt = "retry" },
                .{ .user_prompt = .{ .text = "question" } },
            } } },
            .{ .response = .{ .parts = &.{
                .{ .text = "checking" },
                .{ .tool_call = .{ .id = "call", .name = "weather", .arguments_json = "{}" } },
            } } },
            .{ .request = .{ .parts = &.{.{ .tool_return = .{ .call_id = "call", .name = "weather", .content = "sunny" } }} } },
        },
        .instructions = &.{"Current instruction."},
        .tools = &.{.{ .name = "weather", .description = "Weather", .parameters_json_schema = "{\"type\":\"object\"}" }},
        .settings = .{
            .temperature = 0.7,
            .max_tokens = 128,
            .stop_sequences = &.{"DONE"},
            .seed = 9,
            .reasoning_effort = .low,
        },
        .output = .{ .json_schema = .{ .name = "answer", .schema = "{\"type\":\"object\"}" } },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\",\"content\":\"Current instruction.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stop\":[\"DONE\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"checking\"") != null);

    const object_mode = try encodeRequest(std.testing.allocator, "model", .{ .messages = &.{}, .output = .json_object });
    defer std.testing.allocator.free(object_mode);
    try std.testing.expect(std.mem.indexOf(u8, object_mode, "\"type\":\"json_object\"") != null);
}

test "encodes model-visible tool return schemas" {
    const encoded = try encodeRequest(std.testing.allocator, "model", .{
        .messages = &.{},
        .tools = &.{.{
            .name = "demo",
            .description = "Demo.",
            .parameters_json_schema = "{}",
            .return_json_schema = "{\"type\":\"string\"}",
            .return_schema_visibility = .model_description,
        }},
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "Return JSON Schema") != null);
}

test "encodes complete compatible settings and filters allowed tools" {
    const tools = [_]model_types.ToolDefinition{
        .{ .name = "search", .description = "Search.", .parameters_json_schema = "{}" },
        .{ .name = "fetch", .description = "Fetch.", .parameters_json_schema = "{}" },
    };
    const body = try encodeRequest(std.testing.allocator, "model", .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{
            .top_p = 0.7,
            .presence_penalty = 0.2,
            .frequency_penalty = -0.1,
            .logprobs = .{ .top = 4 },
            .parallel_tool_calls = false,
            .tool_choice = .{ .allowed = &.{"search"} },
            .service_tier = .flex,
            .extra_body = .{ .openai_compatible = "{\"min_p\":0.05}" },
        },
    });
    defer std.testing.allocator.free(body);
    for ([_][]const u8{
        "\"top_p\":0.7",
        "\"presence_penalty\":0.2",
        "\"frequency_penalty\":-0.1",
        "\"logprobs\":true",
        "\"top_logprobs\":4",
        "\"parallel_tool_calls\":false",
        "\"tool_choice\":\"required\"",
        "\"service_tier\":\"flex\"",
        "\"min_p\":0.05",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"fetch\"") == null);

    inline for (.{
        model_types.ToolChoice.auto,
        model_types.ToolChoice.none,
        model_types.ToolChoice.required,
    }) |choice| {
        const scalar = try encodeRequest(std.testing.allocator, "model", .{
            .messages = &.{},
            .tools = &tools,
            .settings = .{ .tool_choice = choice },
        });
        std.testing.allocator.free(scalar);
    }
    const named = try encodeRequest(std.testing.allocator, "model", .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{ .tool_choice = .{ .tool = "fetch" } },
    });
    defer std.testing.allocator.free(named);
    try std.testing.expect(std.mem.indexOf(
        u8,
        named,
        "\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"fetch\"}}",
    ) != null);
}

test "stream request usage collection is configurable" {
    const with_usage = try encodeStreamingRequest(std.testing.allocator, "model", .{ .messages = &.{} }, true);
    defer std.testing.allocator.free(with_usage);
    try std.testing.expect(std.mem.indexOf(u8, with_usage, "stream_options") != null);
    const without_usage = try encodeStreamingRequest(std.testing.allocator, "model", .{ .messages = &.{} }, false);
    defer std.testing.allocator.free(without_usage);
    try std.testing.expect(std.mem.indexOf(u8, without_usage, "stream_options") == null);
}

test "compatible clients forward correlation and configured idempotency headers" {
    const State = struct {
        buffered: bool = false,
        streaming: bool = false,

        fn hasHeaders(request: http.Request) bool {
            var authorization = false;
            var correlation = false;
            var idempotency = false;
            var feature = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization"))
                    authorization = std.mem.eql(u8, header.value, "Bearer secret");
                if (std.ascii.eqlIgnoreCase(header.name, "x-client-request-id"))
                    correlation = std.mem.eql(u8, header.value, "run-123");
                if (std.ascii.eqlIgnoreCase(header.name, "x-idempotency-key"))
                    idempotency = std.mem.eql(u8, header.value, "attempt-123");
                if (std.ascii.eqlIgnoreCase(header.name, "x-feature"))
                    feature = std.mem.eql(u8, header.value, "on");
            }
            return authorization and correlation and idempotency and feature and
                std.mem.eql(u8, request.url, "https://api.openai.com/v1/chat/completions");
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request_value: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.endsWith(u8, request_value.url, "/models")) return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"data\":[{\"id\":\"model\"}]}"),
            };
            self.buffered = hasHeaders(request_value);
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, request_value: http.Request, _: http.LineSink) !http.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streaming = hasHeaders(request_value);
            return error.ConnectionResetByPeer;
        }
    };
    var state: State = .{};
    var provider_state = Provider.init("secret", .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream });
    var client = Client{
        .model_name = "model",
        .provider = provider_state.provider(),
        .idempotency_header = "x-idempotency-key",
    };
    var models = try provider_state.provider().listModels(std.testing.allocator);
    defer models.deinit();
    try std.testing.expectEqualStrings("model", models.items[0].id);
    try std.testing.expect(client.model().profile.supports_idempotency_key);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const request_value = model_types.ModelRequest{
        .messages = &.{},
        .request_id = "run-123",
        .idempotency_key = "attempt-123",
        .settings = .{ .extra_headers = &.{.{ .name = "x-feature", .value = "on" }} },
    };
    _ = try client.model().request(arena.allocator(), request_value);
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {} // unreachable: the transport fails before events
    };
    try std.testing.expectError(error.ProviderConnectionError, client.model().stream(
        arena.allocator(),
        request_value,
        .{ .context = &state, .eventFn = Sink.emit },
    ));
    try std.testing.expect(state.buffered);
    try std.testing.expect(state.streaming);
}

test "decodes Chat Completions text, tools, usage, and finish reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), "{\"choices\":[{\"message\":{\"content\":\"hello\",\"tool_calls\":[{\"id\":\"call\",\"function\":{\"name\":\"weather\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5,\"cost\":0.0000024,\"prompt_tokens_details\":{\"cached_tokens\":1,\"cache_write_tokens\":1,\"audio_tokens\":1},\"completion_tokens_details\":{\"reasoning_tokens\":1,\"audio_tokens\":1}}}");
    try std.testing.expectEqual(@as(usize, 2), response.parts.len);
    try std.testing.expectEqualStrings("hello", response.parts[0].text);
    try std.testing.expectEqualStrings("weather", response.parts[1].tool_call.name);
    try std.testing.expectEqual(@as(u64, 5), response.usage.totalTokens());
    try std.testing.expectEqual(@as(u64, 1), response.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 1), response.usage.reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 2_400), response.usage.cost.?.nano_usd);
    try std.testing.expectEqual(model_types.UsageCostSource.provider, response.usage.cost_source.?);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "named compatible decoders preserve selected response metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = "{\"id\":\"gen_1\",\"model\":\"routed/model\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]";
    const missing = try decodeResponseFor(arena.allocator(), base ++ "}", "router");
    try std.testing.expect(missing.provider_details == null);
    try std.testing.expectEqualStrings("gen_1", missing.provider_response_id.?);
    try std.testing.expectEqualStrings("routed/model", missing.model_name.?);
    const null_details = try decodeResponseFor(arena.allocator(), base ++ ",\"router\":null}", "router");
    try std.testing.expect(null_details.provider_details == null);
    try std.testing.expectError(
        error.InvalidProviderResponse,
        decodeResponseFor(arena.allocator(), base ++ ",\"router\":true}", "router"),
    );
}

test "maps compatible truncation and content filtering" {
    try std.testing.expectEqual(model_types.FinishReason.Kind.length, compatibleFinishReason("length").kind);
    try std.testing.expectEqual(
        model_types.FinishReason.Kind.content_filter,
        compatibleFinishReason("content_filter").kind,
    );
}

test "rejects malformed Chat Completions choices, content, calls, and usage" {
    const invalid_bodies = [_][]const u8{
        "{\"choices\":[false]}",
        "{\"choices\":[{\"message\":{\"content\":false}}]}",
        "{\"choices\":[{\"message\":{\"tool_calls\":[false]}}]}",
        "{\"choices\":[{\"message\":{}}],\"usage\":false}",
    };
    for (invalid_bodies) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), body));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const null_usage = try decodeResponse(arena.allocator(), "{\"choices\":[{\"message\":{\"content\":null}}],\"usage\":null}");
    try std.testing.expectEqual(@as(u64, 0), null_usage.usage.totalTokens());
}

test "profiles provide conservative compatibility presets" {
    try std.testing.expect(profiles.full.supports_json_schema_output);
    try std.testing.expect(!profiles.basic.supports_parallel_tool_calls);
    try std.testing.expect(!profiles.minimal.supports_tools);
}

test "named compatible providers layer built-in and application profiles" {
    const BuiltIn = struct {
        fn lookup(name: []const u8) ?model_types.ModelProfile {
            if (std.mem.eql(u8, name, "builtin")) return .{
                .supports_tools = true,
                .supports_streaming = true,
            };
            if (std.mem.eql(u8, name, "shared")) return .{
                .supports_streaming = true,
            };
            return null;
        }
    };
    const Application = struct {
        fn lookup(_: *anyopaque, name: []const u8) ?model_types.ModelProfile {
            if (!std.mem.eql(u8, name, "shared")) return null;
            return .{ .supports_json_schema_output = true };
        }

        fn override(_: *anyopaque, _: []const u8, profile: model_types.ModelProfile) model_types.ModelProfile {
            var result = profile;
            result.supports_tools = false;
            return result;
        }
    };
    const Stub = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: http.Request) !http.Response {
            return error.UnexpectedRequest;
        }
    };
    const NamedProvider = ProviderWithDefaults(.{
        .provider_name = "named",
        .model_profile_lookup = BuiltIn.lookup,
    });

    var marker: u8 = 0;
    const transport = http.Transport{ .context = &marker, .sendFn = Stub.send };
    try std.testing.expectError(error.UnexpectedRequest, transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    var provider_state = NamedProvider.initWithOptions("secret", transport, .{
        .model_profiles = .{
            .context = &marker,
            .lookupFn = Application.lookup,
            .overrideFn = Application.override,
        },
    });
    const provider = provider_state.provider();

    const built_in = provider.modelProfile("builtin", .{});
    try std.testing.expect(built_in.supports_streaming);
    try std.testing.expect(!built_in.supports_tools);

    const application = provider.modelProfile("shared", .{});
    try std.testing.expect(application.supports_json_schema_output);
    try std.testing.expect(!application.supports_streaming);

    const fallback = provider.modelProfile("unknown", .{
        .supports_tools = true,
        .supports_seed = true,
    });
    try std.testing.expect(fallback.supports_seed);
    try std.testing.expect(!fallback.supports_tools);

    var built_in_only = NamedProvider.init("secret", transport);
    try std.testing.expect(built_in_only.provider().modelProfile("builtin", .{}).supports_streaming);

    var lookup_only = NamedProvider.initWithOptions("secret", transport, .{
        .model_profiles = .{ .context = &marker, .lookupFn = Application.lookup },
    });
    try std.testing.expect(lookup_only.provider().modelProfile("shared", .{}).supports_json_schema_output);

    var override_only = Provider.initWithOptions("secret", transport, .{
        .model_profiles = .{ .context = &marker, .overrideFn = Application.override },
    });
    try std.testing.expect(!override_only.provider().modelProfile("unknown", .{}).supports_tools);
}

test "compatible responses classify malformed buffered and streamed tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const malformed = try decodeResponse(
        arena.allocator(),
        "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]}}]}",
    );
    try std.testing.expectEqual(@as(usize, 0), malformed.parts.len);
    try std.testing.expectEqual(model_types.FinishReason.Kind.incomplete_tool_call, malformed.finish_reason.?.kind);

    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {} // kcov-ignore
    };
    var unused: u8 = 0;
    var incomplete = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &unused, .eventFn = Sink.emit },
        .status = 200,
    };
    defer incomplete.deinit();
    try StreamState.line(
        &incomplete,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call\"}]},\"finish_reason\":\"tool_calls\"}]}",
    );
    try std.testing.expectEqual(model_types.FinishReason.Kind.incomplete_tool_call, incomplete.finish_reason.?.kind);

    var invalid = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &unused, .eventFn = Sink.emit },
        .status = 200,
    };
    defer invalid.deinit();
    try StreamState.line(
        &invalid,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}",
    );
    try std.testing.expectEqual(model_types.FinishReason.Kind.incomplete_tool_call, invalid.finish_reason.?.kind);
    try std.testing.expectError(error.InvalidProviderResponse, StreamState.line(
        &invalid,
        "data: {\"choices\":[false]}",
    ));
}

test "compatible providers reject responses beyond the JSON nesting limit" {
    const source = "[" ** 129 ++ "0" ++ "]" ** 129;
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(std.testing.allocator, source));
}

fn checkBufferedToolAllocationFailure(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try decodeResponse(
        arena.allocator(),
        "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}}]}",
    );
}

fn checkStreamedToolAllocationFailure(allocator: std.mem.Allocator) !void {
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void { // kcov-ignore
            return; // kcov-ignore
        }
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var unused: u8 = 0;
    var state = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &unused, .eventFn = Sink.emit },
        .status = 200,
    };
    defer state.deinit();
    try StreamState.line(
        &state,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}",
    );
}

test "compatible tool parsing propagates allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBufferedToolAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkStreamedToolAllocationFailure, .{});
}

test "compatible providers encode detailed text and reject rich history" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt_part = .{ .content = "system" } },
            .{ .retry_prompt_part = .{ .content = "retry" } },
            .{ .user_prompt = .{ .text_content = .{ .content = "rich" } } },
            .{ .user_prompt = .{ .cache_point = .{} } },
            .{ .user_prompt_part = .{ .content = .{ .text = "timestamped" } } },
            .{ .user_prompt_part = .{ .content = .{ .text_content = .{ .content = "metadata" } } } },
            .{ .user_prompt_part = .{ .content = .{ .cache_point = .{} } } },
            .{ .speech = .{ .speaker = .user, .transcript = "spoken" } },
            .{ .tool_return = .{ .call_id = "call", .name = "tool", .content = "ok" } },
            .{ .capability_load_return = .{ .call_id = "load", .instructions = "loaded" } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text_part = .{ .content = "answer" } },
            .{ .speech = .{ .speaker = .assistant, .transcript = "said" } },
            .{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}" } },
            .{ .capability_load_call = .{ .call_id = "load", .capability_id = "weather" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, "model", .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "spoken") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "said") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "load_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "weather") != null);

    const file = model_types.Content{ .source = .{ .bytes = "x" }, .media_type = "application/octet-stream" };
    const unsupported = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .image = file } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_availability_delta = .{ .tools_added = &.{} } }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt_part = .{ .content = .{ .image = file } } }} } },
        .{ .request = .{ .parts = &.{.{ .speech = .{ .speaker = .user } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call",
            .name = "tool",
            .content = "ok",
            .files = &.{file},
        } }} } },
        .{ .response = .{ .parts = &.{.{ .speech = .{ .speaker = .assistant } }} } },
        .{ .response = .{ .parts = &.{.{ .text_part = .{
            .content = "provider-bound",
            .provider = .{ .id = "item", .provider_name = "provider" },
        } }} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call",
            .name = "tool",
            .arguments_json = "{}",
            .thought_signature = "unsupported",
        } }} } },
        .{ .response = .{ .parts = &.{.{ .compaction = .{ .content = "summary" } }} } },
    };
    for (unsupported) |message| try std.testing.expectError(
        error.InvalidRequestEncoding,
        encodeRequest(std.testing.allocator, "model", .{ .messages = &.{message} }),
    );
}

fn fuzzStreamLine(_: void, smith: *std.testing.Smith) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void { // kcov-ignore
            return; // kcov-ignore
        }
    };
    var context: u8 = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &context, .eventFn = Sink.emit },
        .status = 200,
    };
    defer state.deinit();
    StreamState.line(&state, value) catch {};
}

test "fuzz OpenAI-compatible streaming decoder" {
    try std.testing.fuzz({}, fuzzStreamLine, .{ .corpus = &.{"\x08\x00\x00\x00data: {}"} });
}
