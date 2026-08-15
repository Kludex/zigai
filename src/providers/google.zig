//! A dependency-free Google Gemini GenerateContent API client.

const std = @import("std");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const http_provider = @import("http.zig");
const operations = @import("operations.zig");
const files = @import("files.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

pub const api_base = "https://generativelanguage.googleapis.com/v1beta";
pub const upload_api_base = "https://generativelanguage.googleapis.com/upload/v1beta";

pub const Error = model_types.ProviderRequestError || error{
    /// A successful Gemini payload does not match GenerateContent.
    InvalidProviderResponse,
    /// Provider-neutral input cannot be encoded as a valid Gemini request.
    InvalidRequestEncoding,
    /// Provider-neutral rich content cannot be represented by Gemini.
    UnsupportedContentType,
};

/// Google Generative Language provider state. Credentials and HTTP policy are
/// separate from the GenerateContent wire adapter.
pub const Provider = struct {
    http: http_provider.Configured,
    upload_http: http_provider.Configured,
    discovery_limits: operations.DiscoveryLimits,

    pub const Options = struct {
        base_url: []const u8 = api_base,
        upload_base_url: []const u8 = upload_api_base,
        headers: []const http.Header = &.{},
        request_policy: provider_types.RequestPolicy = .{},
        file_limits: provider_types.FileLimits = .{ .max_upload_bytes = 2 * 1024 * 1024 * 1024 },
        model_profiles: ?http_provider.Configured.ModelProfiles = null,
        discovery_limits: operations.DiscoveryLimits = .{},
    };

    pub fn init(api_key: []const u8, transport: http.Transport) Provider {
        return initWithOptions(api_key, transport, .{});
    }

    pub fn initWithOptions(api_key: []const u8, transport: http.Transport, options: Options) Provider {
        return .{
            .http = .{
                .name = "gcp.gen_ai",
                .base_url = options.base_url,
                .transport = transport,
                .credential = .{ .header = .{ .name = "x-goog-api-key", .value = api_key } },
                .headers = options.headers,
                .request_policy = options.request_policy,
                .file_limits = options.file_limits,
                .model_profiles = options.model_profiles,
            },
            .upload_http = .{
                .name = "gcp.gen_ai",
                .base_url = options.upload_base_url,
                .transport = transport,
                .credential = .{ .header = .{ .name = "x-goog-api-key", .value = api_key } },
                .headers = options.headers,
                .request_policy = options.request_policy,
                .file_limits = options.file_limits,
            },
            .discovery_limits = options.discovery_limits,
        };
    }

    pub fn provider(self: *Provider) provider_types.Provider {
        self.http.operations = .{
            .context = self,
            .listModelsFn = listModels,
            .uploadFileFn = uploadFile,
            .inspectFileFn = inspectFile,
            .deleteFileFn = deleteFile,
        };
        return self.http.provider();
    }

    fn listModels(context: *anyopaque, allocator: std.mem.Allocator) !provider_types.OwnedModels {
        const self: *Provider = @ptrCast(@alignCast(context));
        return operations.listGoogleModels(&self.http, allocator, self.discovery_limits);
    }

    fn uploadFile(context: *anyopaque, allocator: std.mem.Allocator, input: provider_types.FileInput) !provider_types.OwnedFile {
        const self: *Provider = @ptrCast(@alignCast(context));
        return files.uploadGoogle(&self.http, &self.upload_http, allocator, input);
    }

    fn inspectFile(context: *anyopaque, allocator: std.mem.Allocator, file: model_types.UploadedFile) !provider_types.OwnedFile {
        const self: *Provider = @ptrCast(@alignCast(context));
        return files.inspectGoogle(&self.http, allocator, file);
    }

    fn deleteFile(context: *anyopaque, allocator: std.mem.Allocator, file: model_types.UploadedFile) !void {
        const self: *Provider = @ptrCast(@alignCast(context));
        return files.deleteGoogle(&self.http, allocator, file);
    }
};

pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
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
        .supports_top_p = true,
        .supports_top_k = true,
        .supports_presence_penalty = true,
        .supports_frequency_penalty = true,
        .supports_logprobs = true,
        .supports_tool_choice = true,
        .supports_thinking_budget = true,
        .supports_request_headers = true,
        .extra_body_kind = .google,
        .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initMany(&.{
            .minimal,
            .low,
            .medium,
            .high,
        }),
        .service_tiers = model_types.ModelProfile.ServiceTierSet.initFull(),
        .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .web_fetch }),
        .content_types = model_types.ModelProfile.ContentTypeSet.initFull(),
    },

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

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequestForProvider(allocator, self.provider.name, value);
        defer allocator.free(body);
        const endpoint = try std.fmt.allocPrint(allocator, "/models/{s}:generateContent", .{self.model_name});
        defer allocator.free(endpoint);
        var headers: std.ArrayList(http.Header) = .empty;
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

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequestForProvider(allocator, self.provider.name, value);
        defer allocator.free(body);
        const endpoint = try std.fmt.allocPrint(allocator, "/models/{s}:streamGenerateContent?alt=sse", .{self.model_name});
        defer allocator.free(endpoint);
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.parts.deinit(allocator);
        defer state.error_body.deinit(allocator);
        const response = self.provider.streamLines(allocator, .{
            .method = .POST,
            .endpoint = endpoint,
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
        return .{
            .parts = try state.parts.toOwnedSlice(allocator), // kcov-ignore
            .usage = state.usage,
            .finish_reason = state.finish_reason,
        };
    }
};

test "Google provider owns resumable file upload inspect and delete" {
    const State = struct {
        step: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request_value: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            const body = switch (self.step) {
                0 => blk: {
                    try std.testing.expectEqual(http.Method.POST, request_value.method);
                    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/upload/v1beta/files", request_value.url);
                    try expectHeader(request_value.headers, "x-goog-api-key", "secret");
                    try expectHeader(request_value.headers, "x-goog-upload-command", "start");
                    try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"display_name\":\"note.txt\"") != null);
                    const sink = request_value.response_header_sink.?;
                    try sink.header(.{ .name = "content-length", .value = "0" });
                    try sink.header(.{
                        .name = "x-goog-upload-url",
                        .value = "https://generativelanguage.googleapis.com/upload/v1beta/files/session-1",
                    });
                    break :blk "";
                },
                1 => blk: {
                    try std.testing.expectEqual(http.Method.POST, request_value.method);
                    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/upload/v1beta/files/session-1", request_value.url);
                    try expectHeader(request_value.headers, "x-goog-upload-command", "upload, finalize");
                    try std.testing.expectEqualStrings("hi", request_value.body);
                    break :blk "{\"file\":{\"name\":\"files/abc-123\",\"displayName\":\"note.txt\",\"mimeType\":\"text/plain\",\"sizeBytes\":\"2\",\"uri\":\"https://generativelanguage.googleapis.com/v1beta/files/abc-123\"}}";
                },
                2 => blk: {
                    try std.testing.expectEqual(http.Method.GET, request_value.method);
                    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/files/abc-123", request_value.url);
                    try expectHeader(request_value.headers, "x-goog-api-key", "secret");
                    break :blk "{\"name\":\"files/abc-123\",\"displayName\":\"note.txt\",\"mimeType\":\"text/plain\",\"sizeBytes\":\"2\",\"uri\":\"https://generativelanguage.googleapis.com/v1beta/files/abc-123\"}";
                },
                3 => blk: {
                    try std.testing.expectEqual(http.Method.DELETE, request_value.method);
                    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/files/abc-123", request_value.url);
                    try expectHeader(request_value.headers, "x-goog-api-key", "secret");
                    break :blk "{}";
                },
                else => return error.UnexpectedRequest,
            };
            self.step += 1;
            return .{ .status = 200, .body = try allocator.dupe(u8, body) };
        }

        fn expectHeader(headers: []const http.Header, name: []const u8, value: []const u8) !void {
            for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) {
                try std.testing.expectEqualStrings(value, header.value);
                return;
            };
            return error.TestUnexpectedResult;
        }
    };
    var state: State = .{};
    var concrete = Provider.init("secret", .{ .context = &state, .sendFn = State.send });
    const provider = concrete.provider();
    var uploaded = try provider.uploadFile(std.testing.allocator, .{
        .filename = "note.txt",
        .media_type = "text/plain",
        .bytes = "hi",
    });
    defer uploaded.deinit();
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/files/abc-123", uploaded.value.id);
    try std.testing.expectEqual(@as(?u64, 2), uploaded.value.size_bytes);
    const file = uploaded.value.uploadedFile();
    var inspected = try provider.inspectFile(std.testing.allocator, file);
    defer inspected.deinit();
    try std.testing.expectEqualStrings("note.txt", inspected.value.filename.?);
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.downloadFile(std.testing.allocator, file));
    try provider.deleteFile(std.testing.allocator, file);
    try std.testing.expectEqual(@as(usize, 4), state.step);
}

test "Google provider owns identity and model profile overrides" {
    const Profiles = struct {
        fn override(_: *anyopaque, _: []const u8, profile: model_types.ModelProfile) model_types.ModelProfile {
            var overridden = profile;
            overridden.supports_tools = false;
            return overridden;
        }
    };
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"models\":[{\"name\":\"models/gemini-test\"}]}") };
        }
    };
    var state: State = .{};
    var provider_state = Provider.initWithOptions("secret", .{ .context = &state, .sendFn = State.send }, .{
        .model_profiles = .{ .context = &state, .overrideFn = Profiles.override },
    });
    var client = Client{ .model_name = "gemini-test", .provider = provider_state.provider() };
    const model = client.model();
    try std.testing.expectEqualStrings("gcp.gen_ai", model.provider_name.?);
    try std.testing.expect(!model.profile.supports_tools);
    try std.testing.expect(model.profile.supports_streaming);
    var models = try provider_state.provider().listModels(std.testing.allocator);
    defer models.deinit();
    try std.testing.expectEqualStrings("gemini-test", models.items[0].id);
}

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    parts: std.ArrayList(model_types.Part) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,
    next_part_index: usize = 0,

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
            try model_types.emitCompletePart(self.sink, self.next_part_index, part);
            self.next_part_index += 1;
        }
        if (chunk.usage.input_tokens != 0 or chunk.usage.output_tokens != 0) {
            self.usage = chunk.usage;
            try self.sink.emit(.{ .usage = self.usage });
        }
        if (chunk.finish_reason != null) self.finish_reason = chunk.finish_reason;
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    return encodeRequestForProvider(allocator, "gcp.gen_ai", request);
}

fn encodeRequestForProvider(allocator: std.mem.Allocator, provider_name: []const u8, request: model_types.ModelRequest) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try common.validateToolChoice(request.tools, request.builtin_tools.len, request.settings.tool_choice);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();

    var has_system = request.instructions.len > 0;
    for (request.messages) |message| switch (message) {
        .request => |request_message| for (request_message.parts) |part| switch (part) {
            .system_prompt, .system_prompt_part => {
                has_system = true;
                break;
            },
            else => {},
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
                .system_prompt_part => |prompt| try writeTextPart(&json, prompt.content),
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
                .system_prompt, .system_prompt_part => {},
                .retry_prompt => |text| try writeTextPart(&json, text),
                .retry_prompt_part => |prompt| try writeTextPart(&json, prompt.content),
                .user_prompt => |content| switch (content) {
                    .text => |text| try writeTextPart(&json, text),
                    .text_content => |text| try writeTextPart(&json, text.content),
                    .image => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .audio => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .video => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .document => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .binary => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .cache_point => {},
                    .uploaded_file => |file| try writeRichContent(allocator, &json, provider_name, file.asContent()),
                },
                .user_prompt_part => |prompt| switch (prompt.content) {
                    .text => |text| try writeTextPart(&json, text),
                    .text_content => |text| try writeTextPart(&json, text.content),
                    .image => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .audio => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .video => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .document => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .binary => |value| try writeRichContent(allocator, &json, provider_name, value),
                    .cache_point => {},
                    .uploaded_file => |file| try writeRichContent(allocator, &json, provider_name, file.asContent()),
                },
                .tool_return => |result| try writeToolReturn(allocator, &json, result),
                .speech => |speech| {
                    try ensureProviderPartReplayable(speech.provider);
                    if (speech.transcript) |text|
                        try writeTextPart(&json, text)
                    else
                        return error.UnsupportedContentType;
                },
                .capability_load_return => |result| try writeCapabilityLoadReturn(&json, result),
                .tool_search_return, .tool_availability_delta => return error.UnsupportedContentType,
            },
            .response => |response| for (response.parts) |part| switch (part) {
                .text => |text| try writeTextPart(&json, text),
                .text_part => |text| {
                    try ensureProviderPartReplayable(text.provider);
                    try writeTextPart(&json, text.content);
                },
                .image => |content| try writeRichContent(allocator, &json, provider_name, content),
                .audio => |content| try writeRichContent(allocator, &json, provider_name, content),
                .video => |content| try writeRichContent(allocator, &json, provider_name, content),
                .document => |content| try writeRichContent(allocator, &json, provider_name, content),
                .binary => |content| try writeRichContent(allocator, &json, provider_name, content),
                .thinking => |thinking| {
                    try ensureProviderPartReplayable(thinking.provider);
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
                    try ensureProviderPartReplayable(call.provider);
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
                .capability_load_call => |call| {
                    const portable = try common.capabilityLoadToolCall(allocator, call);
                    defer allocator.free(portable.arguments_json);
                    try json.beginObject();
                    try json.objectField("functionCall");
                    try json.beginObject();
                    try json.objectField("name");
                    try json.write(portable.name);
                    try json.objectField("args");
                    try common.rawJson(allocator, &json, portable.arguments_json, json_limits.defaults.tool_payload);
                    try json.objectField("id");
                    try json.write(portable.id);
                    try json.endObject();
                    try json.endObject();
                },
                .speech => |speech| {
                    try ensureProviderPartReplayable(speech.provider);
                    if (speech.transcript) |text|
                        try writeTextPart(&json, text)
                    else
                        return error.UnsupportedContentType;
                },
                .tool_search_call, .native_tool_search_call, .native_tool_call, .native_tool_search_return, .native_tool_return, .compaction => return error.UnsupportedContentType,
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
                if (!common.toolIncluded(request.settings.tool_choice, tool.name)) continue;
                try json.beginObject();
                try json.objectField("name");
                try json.write(tool.name);
                try json.objectField("description");
                const description = try common.toolDescription(allocator, tool);
                defer if (description) |owned| allocator.free(owned);
                try json.write(description orelse tool.description);
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
    if (request.settings.tool_choice) |choice| try writeToolConfig(&json, choice);

    const schema = switch (request.output) {
        .json_schema => |format| format.schema,
        else => null,
    };
    const json_output = request.output != .text;
    if (json_output or hasGenerationSettings(request.settings)) {
        try writeGenerationConfig(allocator, &json, schema, json_output, request.settings);
    }
    if (request.settings.service_tier) |tier| switch (tier) {
        .auto => {},
        .default, .flex, .priority => {
            try json.objectField("serviceTier");
            try json.write(switch (tier) {
                .default => "standard",
                .flex => "flex",
                .priority => "priority",
                .auto => unreachable,
            });
        },
    };
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        .google,
        &.{ "systemInstruction", "contents", "tools", "toolConfig", "generationConfig", "serviceTier" },
    );
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeToolConfig(json: *std.json.Stringify, choice: model_types.ToolChoice) !void {
    try json.objectField("toolConfig");
    try json.beginObject();
    try json.objectField("functionCallingConfig");
    try json.beginObject();
    try json.objectField("mode");
    try json.write(switch (choice) {
        .auto => "AUTO",
        .none => "NONE",
        .required, .tool, .allowed => "ANY",
    });
    switch (choice) {
        .tool => |name| {
            try json.objectField("allowedFunctionNames");
            try json.write(&.{name});
        },
        .allowed => |names| {
            try json.objectField("allowedFunctionNames");
            try json.write(names);
        },
        else => {},
    }
    try json.endObject();
    try json.endObject();
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
            for (request.parts) |part| switch (part) {
                .system_prompt, .system_prompt_part => {},
                else => break :blk true,
            };
            break :blk false;
        },
        .response => |response| response.parts.len > 0,
    };
}

fn writeToolReturn(allocator: std.mem.Allocator, json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len > 0) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("functionResponse");
    try json.beginObject();
    try json.objectField("name");
    try json.write(result.name);
    try json.objectField("response");
    try json.beginObject();
    try json.objectField(if (result.isError()) "error" else "result");
    try common.rawJson(allocator, json, result.content, json_limits.defaults.tool_payload);
    try json.endObject();
    try json.objectField("id");
    try json.write(result.call_id);
    try json.endObject();
    try json.endObject();
}

fn writeCapabilityLoadReturn(json: *std.json.Stringify, result: model_types.CapabilityLoadResult) !void {
    try json.beginObject();
    try json.objectField("functionResponse");
    try json.beginObject();
    try json.objectField("name");
    try json.write(common.capability_load_tool_name);
    try json.objectField("response");
    try json.beginObject();
    try json.objectField(if (result.outcome == .success) "result" else "error");
    try json.write(result.instructions orelse "");
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
    provider_name: []const u8,
    content: model_types.Content,
) !void {
    try ensureProviderPartReplayable(content.provider);
    switch (content.source) {
        .provider_file => |file| if (file.provider) |owner| {
            if (!std.mem.eql(u8, owner, provider_name)) return error.UnsupportedContentType;
        },
        .uploaded_file => |file| if (!std.mem.eql(u8, file.provider_name, provider_name))
            return error.UnsupportedContentType,
        else => {},
    }
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
        .uploaded_file => |file| {
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

fn ensureProviderPartReplayable(provider: model_types.ProviderPart) !void {
    if (provider.requiresReplay()) return error.UnsupportedContentType;
}

fn hasGenerationSettings(settings: model_types.ModelSettings) bool {
    return settings.temperature != null or settings.max_tokens != null or
        settings.stop_sequences != null or settings.seed != null or settings.reasoning_effort != null or
        settings.top_p != null or settings.top_k != null or settings.presence_penalty != null or
        settings.frequency_penalty != null or settings.logprobs != null or settings.thinking_budget_tokens != null;
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
    if (settings.top_p) |top_p| {
        try json.objectField("topP");
        try json.write(top_p);
    }
    if (settings.top_k) |top_k| {
        try json.objectField("topK");
        try json.write(top_k);
    }
    if (settings.presence_penalty) |penalty| {
        try json.objectField("presencePenalty");
        try json.write(penalty);
    }
    if (settings.frequency_penalty) |penalty| {
        try json.objectField("frequencyPenalty");
        try json.write(penalty);
    }
    if (settings.logprobs) |logprobs| {
        try json.objectField("responseLogprobs");
        try json.write(true);
        try json.objectField("logprobs");
        try json.write(logprobs.top);
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
    } else if (settings.thinking_budget_tokens) |budget| {
        try json.objectField("thinkingConfig");
        try json.beginObject();
        try json.objectField("thinkingBudget");
        try json.write(budget);
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
        usage = try decodeUsageMetadata(allocator, object);
    }
    if (finish_reason) |*reason| {
        if (reason.kind == .stop and hasToolCalls(parts.items)) reason.kind = .tool_calls;
    }
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage, .finish_reason = finish_reason };
}

fn decodeUsageMetadata(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model_types.RequestUsage {
    const candidates = try common.objectInteger(object, "candidatesTokenCount");
    const reasoning = try common.optionalObjectInteger(object, "thoughtsTokenCount") orelse 0;
    const output = std.math.add(u64, candidates, reasoning) catch return error.InvalidProviderResponse;
    var details: std.ArrayList(model_types.UsageDetail) = .empty;
    if (try common.optionalObjectInteger(object, "totalTokenCount")) |value| {
        try details.append(allocator, .{ .name = "total_tokens", .value = value });
    }
    if (try common.optionalObjectInteger(object, "toolUsePromptTokenCount")) |value| {
        try details.append(allocator, .{ .name = "tool_use_prompt_tokens", .value = value });
    }
    return .{
        .input_tokens = try common.objectInteger(object, "promptTokenCount"),
        .cache_read_tokens = try common.optionalObjectInteger(object, "cachedContentTokenCount") orelse 0,
        .output_tokens = output,
        .reasoning_tokens = reasoning,
        .input_audio_tokens = try modalityTokens(object, "promptTokensDetails", "AUDIO"),
        .output_audio_tokens = try modalityTokens(object, "candidatesTokensDetails", "AUDIO"),
        .details = try details.toOwnedSlice(allocator),
    };
}

fn modalityTokens(object: std.json.ObjectMap, field: []const u8, modality: []const u8) !u64 {
    const value = object.get(field) orelse return 0;
    const array = switch (value) {
        .array => |items| items,
        .null => return 0,
        else => return error.InvalidProviderResponse,
    };
    var total: u64 = 0;
    for (array.items) |item| {
        const detail = switch (item) {
            .object => |entry| entry,
            else => return error.InvalidProviderResponse,
        };
        const kind = try common.optionalObjectString(detail, "modality") orelse return error.InvalidProviderResponse;
        if (!std.ascii.eqlIgnoreCase(kind, modality)) continue;
        total = std.math.add(u64, total, try common.objectInteger(detail, "tokenCount")) catch
            return error.InvalidProviderResponse;
    }
    return total;
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

test "encodes complete Gemini settings and tool policy" {
    const tools = [_]model_types.ToolDefinition{
        .{ .name = "search", .description = "Search.", .parameters_json_schema = "{}" },
        .{ .name = "fetch", .description = "Fetch.", .parameters_json_schema = "{}" },
    };
    const body = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{
            .top_p = 0.75,
            .top_k = 24,
            .presence_penalty = 0.1,
            .frequency_penalty = 0.2,
            .logprobs = .{ .top = 3 },
            .thinking_budget_tokens = 1_024,
            .tool_choice = .{ .allowed = &.{"search"} },
            .service_tier = .priority,
            .extra_body = .{ .google = "{\"labels\":{\"team\":\"agents\"}}" },
        },
    });
    defer std.testing.allocator.free(body);
    for ([_][]const u8{
        "\"topP\":0.75",
        "\"topK\":24",
        "\"presencePenalty\":0.1",
        "\"frequencyPenalty\":0.2",
        "\"responseLogprobs\":true",
        "\"logprobs\":3",
        "\"thinkingConfig\":{\"thinkingBudget\":1024}",
        "\"mode\":\"ANY\"",
        "\"allowedFunctionNames\":[\"search\"]",
        "\"serviceTier\":\"priority\"",
        "\"labels\":{\"team\":\"agents\"}",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"fetch\"") == null);

    inline for (.{
        model_types.ToolChoice.auto,
        model_types.ToolChoice.none,
        model_types.ToolChoice.required,
    }) |choice| {
        const scalar = try encodeRequest(std.testing.allocator, .{
            .messages = &.{},
            .tools = &tools,
            .settings = .{ .tool_choice = choice },
        });
        std.testing.allocator.free(scalar);
    }
    const named = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{ .tool_choice = .{ .tool = "fetch" }, .service_tier = .default },
    });
    defer std.testing.allocator.free(named);
    try std.testing.expect(std.mem.indexOf(u8, named, "\"allowedFunctionNames\":[\"fetch\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, named, "\"serviceTier\":\"standard\"") != null);

    const automatic = try encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .settings = .{ .service_tier = .auto },
    });
    defer std.testing.allocator.free(automatic);
    try std.testing.expect(std.mem.indexOf(u8, automatic, "serviceTier") == null);
    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, .{
        .messages = &.{},
        .settings = .{ .reasoning_effort = .high, .thinking_budget_tokens = 1_024 },
    }));
}

test "encodes model-visible tool return schemas" {
    const encoded = try encodeRequest(std.testing.allocator, .{
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

test "Google clients forward validated request settings headers" {
    const State = struct {
        buffered: bool = false,
        streaming: bool = false,

        fn hasFeature(request: http.Request) bool {
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-feature") and
                std.mem.eql(u8, header.value, "on")) return true;
            return false;
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.buffered = hasFeature(request);
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, request: http.Request, _: http.LineSink) !http.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streaming = hasFeature(request);
            return error.ConnectionResetByPeer;
        }
    };
    var state: State = .{};
    var provider_state = Provider.init("secret", .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream });
    try std.testing.expect(!State.hasFeature(.{ .method = .POST, .url = "https://example.test" }));
    var client = Client{
        .model_name = "gemini-test",
        .provider = provider_state.provider(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const request = model_types.ModelRequest{
        .messages = &.{},
        .settings = .{ .extra_headers = &.{.{ .name = "x-feature", .value = "on" }} },
    };
    _ = try client.model().request(arena.allocator(), request);
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {}
    };
    try Sink.emit(&state, .{ .usage = .{} });
    try std.testing.expectError(error.ProviderConnectionError, client.model().stream(
        arena.allocator(),
        request,
        .{ .context = &state, .eventFn = Sink.emit },
    ));
    try std.testing.expect(state.buffered);
    try std.testing.expect(state.streaming);
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
        \\{"candidates":[{"content":{"parts":[{"text":"checking"},{"functionCall":{"id":"call_1","name":"weather","args":{"city":"Madrid"}},"thoughtSignature":"signed-state"},{"functionCall":{"name":"other","args":{}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"cachedContentTokenCount":2,"candidatesTokenCount":3,"thoughtsTokenCount":4,"totalTokenCount":15,"toolUsePromptTokenCount":1,"promptTokensDetails":[{"modality":"AUDIO","tokenCount":2}],"candidatesTokensDetails":[{"modality":"AUDIO","tokenCount":1}],"unusedTokensDetails":null}}
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
    try std.testing.expectEqual(@as(u64, 7), response.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 2), response.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 4), response.usage.reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 2), response.usage.input_audio_tokens);
    try std.testing.expectEqual(@as(u64, 1), response.usage.output_audio_tokens);
    try std.testing.expectEqual(@as(u64, 1), response.usage.detail("tool_use_prompt_tokens").?);
    try std.testing.expectEqual(@as(u64, 0), try modalityTokens(
        std.json.ObjectMap.empty,
        "missing",
        "AUDIO",
    ));
    var null_details: std.json.ObjectMap = .empty;
    try null_details.put(arena.allocator(), "details", .null);
    try std.testing.expectEqual(@as(u64, 0), try modalityTokens(null_details, "details", "AUDIO"));
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
        "{\"candidates\":[{\"content\":{\"parts\":[]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":1,\"promptTokensDetails\":[false]}}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), body));
    }
}

test "Google encodes detailed multimodal forms and rejects local protocol parts" {
    var marker: u8 = 0;
    var provider_state = Provider.init("secret", .{ .context = &marker, .sendFn = undefined });
    var client = Client{
        .model_name = "gemini-test",
        .provider = provider_state.provider(),
    };
    const exposed_model = client.model();
    try std.testing.expectEqualStrings("gcp.gen_ai", exposed_model.provider_name.?);
    try std.testing.expect(exposed_model.profile.supportsContentType(.video));

    const uploaded = model_types.UploadedFile{
        .id = "gs://bucket/file",
        .provider_name = "gcp.gen_ai",
        .media_type = "video/mp4",
    };
    const video = model_types.Content{
        .source = .{ .uploaded_file = uploaded },
        .media_type = "video/mp4",
        .thought_signature = "signature",
    };
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt_part = .{ .content = "system" } },
            .{ .retry_prompt_part = .{ .content = "retry" } },
            .{ .user_prompt = .{ .text_content = .{ .content = "rich" } } },
            .{ .user_prompt = .{ .video = video } },
            .{ .user_prompt = .{ .uploaded_file = uploaded } },
            .{ .user_prompt_part = .{ .content = .{ .text = "timestamped" } } },
            .{ .user_prompt_part = .{ .content = .{ .text_content = .{ .content = "metadata" } } } },
            .{ .user_prompt_part = .{ .content = .{ .image = .{
                .source = .{ .bytes = "image" },
                .media_type = "image/png",
            } } } },
            .{ .user_prompt_part = .{ .content = .{ .audio = .{
                .source = .{ .url = "https://example.test/audio.mp3" },
                .media_type = "audio/mpeg",
            } } } },
            .{ .user_prompt_part = .{ .content = .{ .video = video } } },
            .{ .user_prompt_part = .{ .content = .{ .document = .{
                .source = .{ .provider_file = .{ .id = "gs://bucket/doc", .provider = "gcp.gen_ai" } },
                .media_type = "application/pdf",
            } } } },
            .{ .user_prompt_part = .{ .content = .{ .binary = .{
                .source = .{ .bytes = "data" },
                .media_type = "application/octet-stream",
            } } } },
            .{ .user_prompt_part = .{ .content = .{ .cache_point = .{} } } },
            .{ .user_prompt_part = .{ .content = .{ .uploaded_file = uploaded } } },
            .{ .speech = .{ .speaker = .user, .transcript = "spoken" } },
            .{ .tool_return = .{ .call_id = "call", .name = "tool", .content = "{\"ok\":true}" } },
            .{ .capability_load_return = .{ .call_id = "load", .instructions = "loaded" } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text_part = .{ .content = "answer" } },
            .{ .image = .{ .source = .{ .bytes = "image" }, .media_type = "image/png" } },
            .{ .audio = .{ .source = .{ .url = "https://example.test/a.mp3" }, .media_type = "audio/mpeg" } },
            .{ .video = video },
            .{ .document = .{
                .source = .{ .provider_file = .{ .id = "gs://bucket/doc", .provider = "gcp.gen_ai" } },
                .media_type = "application/pdf",
            } },
            .{ .binary = .{ .source = .{ .bytes = "data" }, .media_type = "application/octet-stream" } },
            .{ .speech = .{ .speaker = .assistant, .transcript = "said" } },
            .{ .thinking = .{ .content = "think", .signature = "signature" } },
            .{ .tool_call = .{
                .id = "call",
                .name = "tool",
                .arguments_json = "{}",
                .thought_signature = "signature",
            } },
            .{ .capability_load_call = .{ .call_id = "load", .capability_id = "weather" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "gs://bucket/file") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "spoken") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "said") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "load_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "weather") != null);
    const gateway_messages = [_]model_types.Message{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .uploaded_file = .{
        .id = "gateway-file",
        .provider_name = "gateway",
    } } }} } }};
    const gateway_body = try encodeRequestForProvider(std.testing.allocator, "gateway", .{ .messages = &gateway_messages });
    defer std.testing.allocator.free(gateway_body);
    try std.testing.expect(std.mem.indexOf(u8, gateway_body, "gateway-file") != null);

    const unsupported = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .speech = .{ .speaker = .user } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_availability_delta = .{ .tools_added = &.{} } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call",
            .name = "tool",
            .content = "{}",
            .files = &.{video},
        } }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .uploaded_file = .{
            .id = "foreign-file",
            .provider_name = "openai",
        } } }} } },
        .{ .response = .{ .parts = &.{.{ .text_part = .{
            .content = "provider-bound",
            .provider = .{ .id = "item", .provider_name = "gcp.gen_ai" },
        } }} } },
        .{ .response = .{ .parts = &.{.{ .speech = .{ .speaker = .assistant } }} } },
        .{ .response = .{ .parts = &.{.{ .compaction = .{ .content = "summary" } }} } },
    };
    for (unsupported) |message| try std.testing.expectError(
        error.UnsupportedContentType,
        encodeRequest(std.testing.allocator, .{ .messages = &.{message} }),
    );
}

test "Google rejects provider responses beyond the JSON nesting limit" {
    const source = "[" ** 129 ++ "0" ++ "]" ** 129;
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(std.testing.allocator, source));
}

fn fuzzStreamLine(_: void, smith: *std.testing.Smith) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {} // kcov-ignore
    };
    var context: u8 = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &context, .eventFn = Sink.emit },
        .status = 200,
    };
    StreamState.line(&state, value) catch {};
}

test "fuzz Google streaming decoder" {
    try std.testing.fuzz({}, fuzzStreamLine, .{ .corpus = &.{"\x08\x00\x00\x00data: {}"} });
}
