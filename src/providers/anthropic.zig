//! A dependency-free Anthropic Messages API client.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

pub const api_base = "https://api.anthropic.com/v1";
pub const api_version = "2023-06-01";

pub const Error = model_types.ProviderRequestError || error{
    /// A successful Anthropic payload does not match the Messages API contract.
    InvalidProviderResponse,
    /// Provider-neutral input cannot be encoded as a valid Anthropic request.
    InvalidRequestEncoding,
    /// A requested rich-content kind has no Anthropic representation.
    UnsupportedContentType,
    /// The requested structured-output mode has no Anthropic representation.
    UnsupportedOutputMode,
};

pub const Client = struct {
    model_name: []const u8,
    api_key: []const u8,
    transport: http.Transport,
    max_tokens: u32 = 4096,
    base_url: []const u8 = api_base,
    settings: model_types.ModelSettings = .{},
    profile: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = false,
        .supports_system_messages = true,
        .supports_thinking = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_top_p = true,
        .supports_top_k = true,
        .supports_tool_choice = true,
        .supports_parallel_tool_call_setting = true,
        .supports_thinking_budget = true,
        .supports_request_headers = true,
        .extra_body_kind = .anthropic,
        .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initMany(&.{
            .low,
            .medium,
            .high,
            .xhigh,
            .max,
        }),
        .service_tiers = model_types.ModelProfile.ServiceTierSet.initMany(&.{ .auto, .default }),
        .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .web_fetch }),
        .content_types = model_types.ModelProfile.ContentTypeSet.initMany(&.{ .image, .document, .thinking }),
    },

    pub fn model(self: *Client) model_types.Model {
        const profile = self.profile;
        return .{
            .context = self,
            .profile = profile,
            .provider_name = "anthropic",
            .model_name = self.model_name,
            .settings = self.settings,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, self.model_name, self.max_tokens, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.base_url});
        defer allocator.free(url);
        try value.url_policy.validate(url);
        const stable_headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
            .{ .name = "anthropic-version", .value = api_version },
        };
        const file_headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
            .{ .name = "anthropic-version", .value = api_version },
            .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
        };
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, if (hasProviderFiles(value.messages)) &file_headers else &stable_headers);
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        const response = self.transport.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }) catch |failure| return common.transportError(failure);
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(
                allocator,
                value.error_observer,
                "anthropic",
                response.status,
                response.body,
                response.metadata,
                value.error_policy,
                &.{self.api_key},
            );
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body) catch |failure| return common.responseDecodeError(failure);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, self.max_tokens, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.base_url});
        defer allocator.free(url);
        try value.url_policy.validate(url);
        const stable_headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
            .{ .name = "anthropic-version", .value = api_version },
        };
        const file_headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
            .{ .name = "anthropic-version", .value = api_version },
            .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
        };
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, if (hasProviderFiles(value.messages)) &file_headers else &stable_headers);
        try common.appendRequestHeaders(allocator, &headers, value.settings.extra_headers);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.deinit();
        const response = self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink()) catch |failure| return common.transportError(failure);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(
                allocator,
                value.error_observer,
                "anthropic",
                response.status,
                state.error_body.items,
                response.metadata,
                value.error_policy,
                &.{self.api_key},
            );
            return common.statusError(response.status);
        }
        if (state.text.items.len > 0) try state.parts.insert(
            allocator,
            leadingThinkingCount(state.parts.items),
            .{ .text = try state.text.toOwnedSlice(allocator) },
        );
        return .{
            .parts = try state.parts.toOwnedSlice(allocator), // kcov-ignore
            .usage = state.usage,
            .finish_reason = state.finish_reason,
        };
    }
};

fn hasProviderFiles(messages: []const model_types.Message) bool {
    for (messages) |message| switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .user_prompt => |prompt| switch (prompt) {
                .image, .document => |content| switch (content.source) {
                    .provider_file, .uploaded_file => return true,
                    else => {},
                },
                .uploaded_file => return true,
                else => {},
            },
            .user_prompt_part => |prompt| switch (prompt.content) {
                .image, .document => |content| switch (content.source) {
                    .provider_file, .uploaded_file => return true,
                    else => {},
                },
                .uploaded_file => return true,
                else => {},
            },
            else => {},
        },
        .response => |response| for (response.parts) |part| switch (part) {
            .image, .document => |content| switch (content.source) {
                .provider_file, .uploaded_file => return true,
                else => {},
            },
            else => {},
        },
    };
    return false;
}

fn leadingThinkingCount(parts: []const model_types.Part) usize {
    for (parts, 0..) |part, index| if (part != .thinking) return index;
    return parts.len;
}

pub fn encodeStreamingRequest(allocator: std.mem.Allocator, model_name: []const u8, max_tokens: u32, request: model_types.ModelRequest) ![]u8 {
    const buffered = try encodeRequest(allocator, model_name, max_tokens, request);
    defer allocator.free(buffered);
    if (buffered.len == 0 or buffered[buffered.len - 1] != '}') return error.InvalidRequestEncoding;
    return std.fmt.allocPrint(allocator, "{s},\"stream\":true}}", .{buffered[0 .. buffered.len - 1]});
}

const PendingCall = struct {
    index: u64,
    id: []const u8,
    name: []const u8,
    arguments: std.ArrayList(u8) = .empty,
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    thinking_signature: std.ArrayList(u8) = .empty,
    thinking_index: ?u64 = null,
    text_index: ?u64 = null,
    parts: std.ArrayList(model_types.Part) = .empty,
    pending: std.ArrayList(PendingCall) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,

    fn deinit(self: *StreamState) void {
        self.text.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
        self.thinking_signature.deinit(self.allocator);
        self.parts.deinit(self.allocator);
        for (self.pending.items) |*call| call.arguments.deinit(self.allocator);
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
        const kind = try common.objectString(object, "type");
        if (std.mem.eql(u8, kind, "message_start")) {
            const message = try common.requiredObject(root, "message");
            const usage = try common.requiredObject(.{ .object = message }, "usage");
            self.usage = try decodeUsageObject(self.allocator, usage);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const block = try common.requiredObject(root, "content_block");
            const block_type = try common.objectString(block, "type");
            const index = try common.objectInteger(object, "index");
            if (std.mem.eql(u8, block_type, "tool_use")) {
                try self.pending.append(self.allocator, .{
                    .index = index,
                    .id = try common.objectString(block, "id"),
                    .name = try common.objectString(block, "name"),
                });
                const call = self.pending.items[self.pending.items.len - 1];
                try self.sink.emit(.{ .part_start = .{ .index = @intCast(index), .part = .{ .tool_call = .{
                    .id = call.id,
                    .name = call.name,
                    .arguments_json = "{}",
                } } } });
            } else if (std.mem.eql(u8, block_type, "text")) {
                self.text_index = index;
                const initial = try common.optionalObjectString(block, "text") orelse "";
                if (initial.len > 0) try self.text.appendSlice(self.allocator, initial);
                try self.sink.emit(.{ .part_start = .{ .index = @intCast(index), .part = .{ .text = initial } } });
            } else if (std.mem.eql(u8, block_type, "thinking")) {
                self.thinking_index = index;
                const initial = try common.optionalObjectString(block, "thinking") orelse "";
                if (initial.len > 0) try self.thinking.appendSlice(self.allocator, initial);
                try self.sink.emit(.{ .part_start = .{ .index = @intCast(index), .part = .{ .thinking = .{
                    .content = initial,
                } } } });
            } else if (std.mem.eql(u8, block_type, "redacted_thinking")) {
                const part: model_types.ResponsePart = .{ .thinking = .{
                    .content = "",
                    .signature = try common.objectString(block, "data"),
                } };
                try self.parts.append(self.allocator, part);
                try model_types.emitCompletePart(self.sink, @intCast(index), part);
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = try common.requiredObject(root, "delta");
            const delta_type = try common.objectString(delta, "type");
            const index: usize = @intCast(try common.objectInteger(object, "index"));
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                const text = try common.objectString(delta, "text");
                if (self.text_index == null) {
                    self.text_index = @intCast(index);
                    try self.sink.emit(.{ .part_start = .{ .index = index, .part = .{ .text = "" } } });
                }
                try self.text.appendSlice(self.allocator, text);
                try self.sink.emit(.{ .part_delta = .{
                    .index = index,
                    .delta = .{ .text = .{ .content_delta = text } },
                } });
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const partial = try common.objectString(delta, "partial_json");
                const call = self.findPending(@intCast(index)) orelse return error.InvalidProviderResponse;
                try call.arguments.appendSlice(self.allocator, partial);
                try self.sink.emit(.{ .part_delta = .{
                    .index = index,
                    .delta = .{ .tool_call = .{ .id = call.id, .name = call.name, .arguments_delta = partial } },
                } });
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                const content = try common.objectString(delta, "thinking");
                try self.thinking.appendSlice(self.allocator, content);
                try self.sink.emit(.{ .part_delta = .{
                    .index = index,
                    .delta = .{ .thinking = .{ .content_delta = content } },
                } });
            } else if (std.mem.eql(u8, delta_type, "signature_delta")) {
                const signature = try common.objectString(delta, "signature");
                try self.thinking_signature.appendSlice(self.allocator, signature);
                try self.sink.emit(.{ .part_delta = .{
                    .index = index,
                    .delta = .{ .thinking = .{ .signature_delta = signature } },
                } });
            }
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            const index = try common.objectInteger(object, "index");
            if (self.thinking_index != null and self.thinking_index.? == index) {
                const signature = if (self.thinking_signature.items.len > 0)
                    try self.thinking_signature.toOwnedSlice(self.allocator)
                else
                    null;
                const part: model_types.ResponsePart = .{ .thinking = .{
                    .content = try self.thinking.toOwnedSlice(self.allocator),
                    .signature = signature,
                } };
                try self.parts.append(self.allocator, part);
                try self.sink.emit(.{ .part_end = .{ .index = @intCast(index), .part = part } });
                self.thinking_index = null;
            } else if (self.text_index != null and self.text_index.? == index) {
                try self.sink.emit(.{ .part_end = .{
                    .index = @intCast(index),
                    .part = .{ .text = self.text.items },
                } });
                self.text_index = null;
            } else if (self.findPending(index)) |pending| {
                const arguments = if (pending.arguments.items.len == 0)
                    try self.allocator.dupe(u8, "{}")
                else
                    try pending.arguments.toOwnedSlice(self.allocator);
                const call = model_types.ToolCall{ .id = pending.id, .name = pending.name, .arguments_json = arguments };
                try self.parts.append(self.allocator, .{ .tool_call = call });
                try self.sink.emit(.{ .part_end = .{ .index = @intCast(index), .part = .{ .tool_call = call } } });
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (object.get("delta")) |delta_value| {
                const delta = switch (delta_value) {
                    .object => |item| item,
                    else => return error.InvalidProviderResponse,
                };
                if (try common.optionalObjectString(delta, "stop_reason")) |reason| {
                    self.finish_reason = anthropicFinishReason(reason);
                }
            }
            const usage = try common.requiredObject(root, "usage");
            self.usage.output_tokens = try common.objectInteger(usage, "output_tokens");
            try self.sink.emit(.{ .usage = self.usage });
        }
    }

    fn findPending(self: *StreamState, index: u64) ?*PendingCall {
        for (self.pending.items) |*call| if (call.index == index) return call;
        return null;
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, model_name: []const u8, max_tokens: u32, request: model_types.ModelRequest) ![]u8 {
    request.settings.validate() catch return error.InvalidRequestEncoding;
    try common.validateToolChoice(request.tools, request.builtin_tools.len, request.settings.tool_choice);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("max_tokens");
    try json.write(request.settings.max_tokens orelse max_tokens);
    if (request.settings.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }
    if (request.settings.stop_sequences) |stop_sequences| {
        try json.objectField("stop_sequences");
        try json.write(stop_sequences);
    }
    if (request.settings.top_p) |top_p| {
        try json.objectField("top_p");
        try json.write(top_p);
    }
    if (request.settings.top_k) |top_k| {
        try json.objectField("top_k");
        try json.write(top_k);
    }
    if (request.settings.thinking_budget_tokens) |budget| {
        try json.objectField("thinking");
        try json.beginObject();
        try json.objectField("type");
        try json.write("enabled");
        try json.objectField("budget_tokens");
        try json.write(budget);
        try json.endObject();
    }
    if (request.settings.tool_choice != null or request.settings.parallel_tool_calls != null) {
        try writeToolChoice(&json, request.settings.tool_choice, request.settings.parallel_tool_calls);
    }
    if (request.settings.service_tier) |tier| {
        try json.objectField("service_tier");
        try json.write(switch (tier) {
            .auto => "auto",
            .default => "standard_only",
            .flex, .priority => return error.InvalidRequestEncoding,
        });
    }

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
        try json.objectField("system");
        try json.beginArray();
        for (request.messages) |message| switch (message) {
            .request => |request_message| for (request_message.parts) |part| switch (part) {
                .system_prompt => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    try json.endObject();
                },
                .system_prompt_part => |prompt| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(prompt.content);
                    try json.endObject();
                },
                else => {},
            },
            .response => {},
        };
        for (request.instructions) |instruction| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("text");
            try json.objectField("text");
            try json.write(instruction);
            try json.endObject();
        }
        try json.endArray();
    }

    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| {
        if (!messageHasAnthropicContent(message)) continue;
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message == .response) "assistant" else "user");
        try json.objectField("content");
        try json.beginArray();
        switch (message) {
            .request => |request_message| for (request_message.parts) |part| switch (part) {
                .system_prompt, .system_prompt_part => {},
                .user_prompt => |content| switch (content) {
                    .text => |text| {
                        try json.beginObject();
                        try json.objectField("type");
                        try json.write("text");
                        try json.objectField("text");
                        try json.write(text);
                        try json.endObject();
                    },
                    .text_content => |text| {
                        try json.beginObject();
                        try json.objectField("type");
                        try json.write("text");
                        try json.objectField("text");
                        try json.write(text.content);
                        try json.endObject();
                    },
                    .image => |value| try writeRichContent(allocator, &json, "image", value),
                    .document => |value| try writeRichContent(allocator, &json, "document", value),
                    .cache_point => {},
                    .uploaded_file => |file| try writeRichContent(
                        allocator,
                        &json,
                        if (std.mem.startsWith(u8, file.media_type orelse "", "image/")) "image" else "document",
                        file.asContent(),
                    ),
                    .audio, .video, .binary => return error.UnsupportedContentType,
                },
                .user_prompt_part => |prompt| switch (prompt.content) {
                    .text => |text| try writeTextBlock(&json, text),
                    .text_content => |text| try writeTextBlock(&json, text.content),
                    .image => |value| try writeRichContent(allocator, &json, "image", value),
                    .document => |value| try writeRichContent(allocator, &json, "document", value),
                    .cache_point => {},
                    .uploaded_file => |file| try writeRichContent(
                        allocator,
                        &json,
                        if (std.mem.startsWith(u8, file.media_type orelse "", "image/")) "image" else "document",
                        file.asContent(),
                    ),
                    .audio, .video, .binary => return error.UnsupportedContentType,
                },
                .retry_prompt => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    try json.endObject();
                },
                .retry_prompt_part => |prompt| try writeTextBlock(&json, prompt.content),
                .tool_return => |result| try writeToolReturn(&json, result),
                .speech => |speech| {
                    try ensureProviderPartReplayable(speech.provider);
                    if (speech.transcript) |text|
                        try writeTextBlock(&json, text)
                    else
                        return error.UnsupportedContentType;
                },
                .tool_search_return, .capability_load_return, .tool_availability_delta => return error.UnsupportedContentType,
            },
            .response => |response| for (response.parts) |part| switch (part) {
                .text => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    try json.endObject();
                },
                .text_part => |text| {
                    try ensureProviderPartReplayable(text.provider);
                    try writeTextBlock(&json, text.content);
                },
                .image => |content| try writeRichContent(allocator, &json, "image", content),
                .document => |content| try writeRichContent(allocator, &json, "document", content),
                .thinking => |thinking| {
                    try ensureProviderPartReplayable(thinking.provider);
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("thinking");
                    try json.objectField("thinking");
                    try json.write(thinking.content);
                    if (thinking.signature) |signature| {
                        try json.objectField("signature");
                        try json.write(signature);
                    }
                    try json.endObject();
                },
                .speech => |speech| {
                    try ensureProviderPartReplayable(speech.provider);
                    if (speech.transcript) |text|
                        try writeTextBlock(&json, text)
                    else
                        return error.UnsupportedContentType;
                },
                .audio, .video, .binary, .tool_search_call, .capability_load_call, .native_tool_search_call, .native_tool_call, .native_tool_search_return, .native_tool_return, .compaction => return error.UnsupportedContentType,
                .tool_call => |call| {
                    try ensureProviderPartReplayable(call.provider);
                    if (call.thought_signature != null) return error.UnsupportedContentType;
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("tool_use");
                    try json.objectField("id");
                    try json.write(call.id);
                    try json.objectField("name");
                    try json.write(call.name);
                    try json.objectField("input");
                    try common.rawJson(allocator, &json, call.arguments_json, json_limits.defaults.tool_payload);
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
        for (request.builtin_tools) |tool| {
            try json.beginObject();
            switch (tool) {
                .web_search => {
                    try json.objectField("type");
                    try json.write("web_search_20250305");
                    try json.objectField("name");
                    try json.write("web_search");
                },
                .web_fetch => {
                    try json.objectField("type");
                    try json.write("web_fetch_20250910");
                    try json.objectField("name");
                    try json.write("web_fetch");
                },
            }
            try json.endObject();
        }
        for (request.tools) |tool| {
            if (!common.toolIncluded(request.settings.tool_choice, tool.name)) continue;
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("input_schema");
            try common.rawJson(allocator, &json, tool.parameters_json_schema, json_limits.defaults.schema);
            try json.endObject();
        }
        try json.endArray();
    }
    if (request.output == .json_object) return error.UnsupportedOutputMode;
    const schema = switch (request.output) {
        .json_schema => |format| format.schema,
        else => null,
    };
    if (schema != null or request.settings.reasoning_effort != null) {
        try json.objectField("output_config");
        try json.beginObject();
        if (request.settings.reasoning_effort) |effort| {
            try json.objectField("effort");
            try json.write(@tagName(effort));
        }
        if (schema) |schema_value| {
            try json.objectField("format");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_schema");
            try json.objectField("schema");
            try common.rawJson(allocator, &json, schema_value, json_limits.defaults.schema);
            try json.endObject();
        }
        try json.endObject();
    }
    try common.writeExtraBodyFields(
        allocator,
        &json,
        request.settings.extra_body,
        .anthropic,
        &.{
            "model", "max_tokens", "system",   "messages",    "tools",        "temperature",   "stop_sequences",
            "top_p", "top_k",      "thinking", "tool_choice", "service_tier", "output_config", "stream",
        },
    );
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeToolChoice(
    json: *std.json.Stringify,
    choice: ?model_types.ToolChoice,
    parallel: ?bool,
) !void {
    try json.objectField("tool_choice");
    try json.beginObject();
    switch (choice orelse .auto) {
        .auto => {
            try json.objectField("type");
            try json.write("auto");
        },
        .none => {
            try json.objectField("type");
            try json.write("none");
        },
        .required, .allowed => {
            try json.objectField("type");
            try json.write("any");
        },
        .tool => |name| {
            try json.objectField("type");
            try json.write("tool");
            try json.objectField("name");
            try json.write(name);
        },
    }
    if (parallel) |enabled| {
        try json.objectField("disable_parallel_tool_use");
        try json.write(!enabled);
    }
    try json.endObject();
}

fn messageHasAnthropicContent(message: model_types.Message) bool {
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

fn writeTextBlock(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write(text);
    try json.endObject();
}

fn writeToolReturn(json: *std.json.Stringify, result: model_types.ToolResult) !void {
    if (result.files.len > 0) return error.UnsupportedContentType;
    try json.beginObject();
    try json.objectField("type");
    try json.write("tool_result");
    try json.objectField("tool_use_id");
    try json.write(result.call_id);
    try json.objectField("content");
    try json.write(result.content);
    if (result.isError()) {
        try json.objectField("is_error");
        try json.write(true);
    }
    try json.endObject();
}

fn writeRichContent(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    kind: []const u8,
    content: model_types.Content,
) !void {
    try ensureProviderPartReplayable(content.provider);
    if (content.thought_signature != null) return error.UnsupportedContentType;
    switch (content.source) {
        .provider_file => |file| if (file.provider) |owner| {
            if (!std.mem.eql(u8, owner, "anthropic")) return error.UnsupportedContentType;
        },
        .uploaded_file => |file| if (!std.mem.eql(u8, file.provider_name, "anthropic"))
            return error.UnsupportedContentType,
        else => {},
    }
    try json.beginObject();
    try json.objectField("type");
    try json.write(kind);
    try json.objectField("source");
    try json.beginObject();
    switch (content.source) {
        .bytes => |bytes| {
            const encoded = try common.base64Alloc(allocator, bytes);
            defer allocator.free(encoded);
            try json.objectField("type");
            try json.write("base64");
            try json.objectField("media_type");
            try json.write(content.media_type);
            try json.objectField("data");
            try json.write(encoded);
        },
        .url => |url| {
            try json.objectField("type");
            try json.write("url");
            try json.objectField("url");
            try json.write(url);
        },
        .provider_file => |file| {
            try json.objectField("type");
            try json.write("file");
            try json.objectField("file_id");
            try json.write(file.id);
        },
        .uploaded_file => |file| {
            try json.objectField("type");
            try json.write("file");
            try json.objectField("file_id");
            try json.write(file.id);
        },
    }
    try json.endObject();
    if (std.mem.eql(u8, kind, "document")) if (content.filename) |filename| {
        try json.objectField("title");
        try json.write(filename);
    };
    try json.endObject();
}

fn ensureProviderPartReplayable(provider: model_types.ProviderPart) !void {
    if (provider.requiresReplay()) return error.UnsupportedContentType;
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
    const content = try common.requiredArray(root, "content");
    var parts: std.ArrayList(model_types.Part) = .empty;
    for (content.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        const kind = try common.objectString(object, "type");
        if (std.mem.eql(u8, kind, "text")) {
            try parts.append(allocator, .{ .text = try common.objectString(object, "text") });
        } else if (std.mem.eql(u8, kind, "thinking") or std.mem.eql(u8, kind, "redacted_thinking")) {
            try parts.append(allocator, .{ .thinking = .{
                .content = if (std.mem.eql(u8, kind, "thinking"))
                    try common.objectString(object, "thinking")
                else
                    "",
                .signature = try common.optionalObjectString(object, "signature") orelse
                    try common.optionalObjectString(object, "data"),
            } });
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            const input = object.get("input") orelse return error.InvalidProviderResponse;
            const arguments = try std.json.Stringify.valueAlloc(allocator, input, .{});
            try parts.append(allocator, .{ .tool_call = .{
                .id = try common.objectString(object, "id"),
                .name = try common.objectString(object, "name"),
                .arguments_json = arguments,
            } });
        }
    }
    var usage: model_types.Usage = .{};
    if (switch (root) {
        .object => |object| object.get("usage"),
        else => null,
    }) |usage_value| {
        const object = switch (usage_value) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        usage = try decodeUsageObject(allocator, object);
    }
    const finish_reason = if (try common.optionalObjectString(root_object, "stop_reason")) |reason|
        anthropicFinishReason(reason)
    else
        null;
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage, .finish_reason = finish_reason };
}

fn decodeUsageObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !model_types.RequestUsage {
    const uncached = try common.objectInteger(object, "input_tokens");
    const cache_write = try common.optionalObjectInteger(object, "cache_creation_input_tokens") orelse 0;
    const cache_read = try common.optionalObjectInteger(object, "cache_read_input_tokens") orelse 0;
    const cached_input = std.math.add(u64, cache_write, cache_read) catch return error.InvalidProviderResponse;
    const input = std.math.add(u64, uncached, cached_input) catch return error.InvalidProviderResponse;
    var details: std.ArrayList(model_types.UsageDetail) = .empty;
    if (object.get("cache_creation")) |value| {
        const cache = switch (value) {
            .object => |entry| entry,
            .null => null,
            else => return error.InvalidProviderResponse,
        };
        if (cache) |entry| inline for ([_]struct { raw: []const u8, name: []const u8 }{
            .{ .raw = "ephemeral_5m_input_tokens", .name = "cache_write_5m_tokens" },
            .{ .raw = "ephemeral_1h_input_tokens", .name = "cache_write_1h_tokens" },
        }) |field| {
            if (try common.optionalObjectInteger(entry, field.raw)) |counter| {
                try details.append(allocator, .{ .name = field.name, .value = counter });
            }
        };
    }
    return .{
        .input_tokens = input,
        .cache_write_tokens = cache_write,
        .cache_read_tokens = cache_read,
        .output_tokens = try common.optionalObjectInteger(object, "output_tokens") orelse 0,
        .details = try details.toOwnedSlice(allocator),
    };
}

fn anthropicFinishReason(raw: []const u8) model_types.FinishReason {
    const kind: model_types.FinishReason.Kind = if (std.mem.eql(u8, raw, "end_turn") or
        std.mem.eql(u8, raw, "stop_sequence"))
        .stop
    else if (std.mem.eql(u8, raw, "tool_use"))
        .tool_calls
    else if (std.mem.eql(u8, raw, "max_tokens") or
        std.mem.eql(u8, raw, "model_context_window_exceeded"))
        .length
    else if (std.mem.eql(u8, raw, "refusal"))
        .content_filter
    else
        .other;
    return .{ .kind = kind, .raw = raw };
}

test "decodes Anthropic tool use" {
    const body =
        \\{"content":[{"type":"tool_use","id":"toolu_1","name":"weather","input":{"city":"Madrid"}}],"stop_reason":"tool_use","usage":{"input_tokens":8,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":1},"output_tokens":3}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqualStrings("toolu_1", response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"city\":\"Madrid\"}", response.parts[0].tool_call.arguments_json);
    try std.testing.expectEqual(@as(u64, 3), response.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 13), response.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), response.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 3), response.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 1), response.usage.detail("cache_write_5m_tokens").?);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "maps Anthropic length and refusal reasons" {
    try std.testing.expectEqual(model_types.FinishReason.Kind.length, anthropicFinishReason("max_tokens").kind);
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, anthropicFinishReason("refusal").kind);
}

test "encodes complete Anthropic settings and filters allowed tools" {
    const tools = [_]model_types.ToolDefinition{
        .{ .name = "search", .description = "Search.", .parameters_json_schema = "{}" },
        .{ .name = "fetch", .description = "Fetch.", .parameters_json_schema = "{}" },
    };
    const body = try encodeRequest(std.testing.allocator, "claude-test", 512, .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{
            .top_p = 0.8,
            .top_k = 32,
            .thinking_budget_tokens = 2_048,
            .tool_choice = .{ .allowed = &.{"search"} },
            .parallel_tool_calls = false,
            .service_tier = .default,
            .extra_body = .{ .anthropic = "{\"metadata\":{\"user_id\":\"safe\"}}" },
        },
    });
    defer std.testing.allocator.free(body);
    for ([_][]const u8{
        "\"top_p\":0.8",
        "\"top_k\":32",
        "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}",
        "\"tool_choice\":{\"type\":\"any\",\"disable_parallel_tool_use\":true}",
        "\"service_tier\":\"standard_only\"",
        "\"metadata\":{\"user_id\":\"safe\"}",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"fetch\"") == null);

    inline for (.{
        model_types.ToolChoice.auto,
        model_types.ToolChoice.none,
        model_types.ToolChoice.required,
    }) |choice| {
        const scalar = try encodeRequest(std.testing.allocator, "claude-test", 512, .{
            .messages = &.{},
            .tools = &tools,
            .settings = .{ .tool_choice = choice },
        });
        std.testing.allocator.free(scalar);
    }
    const named = try encodeRequest(std.testing.allocator, "claude-test", 512, .{
        .messages = &.{},
        .tools = &tools,
        .settings = .{ .tool_choice = .{ .tool = "fetch" }, .service_tier = .auto },
    });
    defer std.testing.allocator.free(named);
    try std.testing.expect(std.mem.indexOf(u8, named, "\"type\":\"tool\",\"name\":\"fetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, named, "\"service_tier\":\"auto\"") != null);

    try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, "claude-test", 512, .{
        .messages = &.{},
        .settings = .{ .reasoning_effort = .high, .thinking_budget_tokens = 1_024 },
    }));
    inline for (.{ model_types.ServiceTier.flex, model_types.ServiceTier.priority }) |tier| {
        try std.testing.expectError(error.InvalidRequestEncoding, encodeRequest(std.testing.allocator, "claude-test", 512, .{
            .messages = &.{},
            .settings = .{ .service_tier = tier },
        }));
    }
}

test "Anthropic clients forward validated request settings headers" {
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
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\"}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, request: http.Request, _: http.LineSink) !http.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streaming = hasFeature(request);
            return error.ConnectionResetByPeer;
        }
    };
    var state: State = .{};
    try std.testing.expect(!State.hasFeature(.{ .method = .POST, .url = "https://example.test" }));
    var client = Client{
        .model_name = "claude-test",
        .api_key = "secret",
        .transport = .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream },
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

test "encodes instructions, tool errors, and requests without system content" {
    const result_parts = [_]model_types.RequestPart{.{ .tool_return = .{
        .call_id = "call_1",
        .name = "weather",
        .content = "failed",
        .is_error = true,
    } }};
    const messages = [_]model_types.Message{.{ .request = .{ .parts = &result_parts } }};
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &messages,
        .instructions = &.{"Current instruction."},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\",\"text\":\"Current instruction.\"}]") != null);

    const without_system = try encodeRequest(std.testing.allocator, "claude-test", 20, .{ .messages = &messages });
    defer std.testing.allocator.free(without_system);
    try std.testing.expect(std.mem.indexOf(u8, without_system, "\"system\"") == null);
}

test "rejects malformed usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(
        arena.allocator(),
        "{\"content\":[],\"usage\":false}",
    ));
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(
        arena.allocator(),
        "{\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_creation\":false}}",
    ));
}

test "encodes Anthropic structured output and rejects JSON-object mode" {
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &.{},
        .settings = .{
            .temperature = 0.4,
            .max_tokens = 99,
            .stop_sequences = &.{"END"},
            .reasoning_effort = .high,
        },
        .output = .{ .json_schema = .{
            .name = "unused-by-anthropic",
            .schema = "{\"type\":\"object\"}",
        } },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stop_sequences\":[\"END\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"high\",\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\"}}}") != null);
    try std.testing.expectError(error.UnsupportedOutputMode, encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &.{},
        .output = .json_object,
    }));
}

test "encodes Anthropic web search and web fetch server tools" {
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &.{},
        .builtin_tools = &.{
            .{ .web_search = .{} },
            .{ .web_fetch = .{} },
        },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"web_search_20250305\",\"name\":\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"web_fetch_20250910\",\"name\":\"web_fetch\"") != null);
}

test "encodes Anthropic rich inputs and preserves thinking" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .user_prompt = .{ .text = "Review these." } },
            .{ .retry_prompt = "Try again." },
            .{ .user_prompt = .{ .image = .{ .source = .{ .bytes = "png" }, .media_type = "image/png" } } },
            .{ .user_prompt = .{ .document = .{
                .source = .{ .provider_file = .{ .id = "file_123", .provider = "anthropic" } },
                .media_type = "application/pdf",
                .filename = "Guide",
            } } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text = "Previous answer." },
            .{ .image = .{ .source = .{ .bytes = "answer" }, .media_type = "image/png" } },
            .{ .document = .{ .source = .{ .url = "https://example.test/answer.pdf" }, .media_type = "application/pdf" } },
            .{ .thinking = .{ .content = "private", .signature = "signed" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"cG5n\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{\"type\":\"file\",\"file_id\":\"file_123\"},\"title\":\"Guide\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"thinking\",\"thinking\":\"private\",\"signature\":\"signed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Previous answer.") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"private\",\"signature\":\"signed\"},{\"type\":\"text\",\"text\":\"answer\"}],\"stop_reason\":\"end_turn\"}",
    );
    try std.testing.expectEqualStrings("private", response.parts[0].thinking.content);
    try std.testing.expectEqualStrings("signed", response.parts[0].thinking.signature.?);
}

test "Anthropic streaming preserves thinking deltas and signatures" {
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {} // kcov-ignore
    };
    var unused: u8 = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &unused, .eventFn = Sink.emit },
        .status = 200,
    };
    defer state.deinit();
    try StreamState.line(&state, "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}");
    try StreamState.line(&state, "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private\"}}");
    try StreamState.line(&state, "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"signed\"}}");
    try StreamState.line(&state, "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"redacted\"}}");
    try StreamState.line(&state, "data: {\"type\":\"content_block_stop\",\"index\":0}");
    try state.sink.emit(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .text = .{ .content_delta = "covered" } },
    } });
    try std.testing.expectEqual(@as(usize, 2), state.parts.items.len);
    try std.testing.expectEqualStrings("redacted", state.parts.items[0].thinking.signature.?);
    try std.testing.expectEqualStrings("private", state.parts.items[1].thinking.content);
    try std.testing.expectEqualStrings("signed", state.parts.items[1].thinking.signature.?);
    try std.testing.expectEqual(@as(usize, 2), leadingThinkingCount(state.parts.items));
    try std.testing.expect(state.findPending(99) == null);
}

test "covers Anthropic rich and streaming response edges" {
    try std.testing.expect(hasProviderFiles(&.{.{
        .request = .{ .parts = &.{.{ .user_prompt = .{ .image = .{
            .source = .{ .provider_file = .{ .id = "file" } },
            .media_type = "image/png",
        } } }} },
    }}));
    try std.testing.expect(hasProviderFiles(&.{.{
        .response = .{ .parts = &.{.{ .document = .{
            .source = .{ .provider_file = .{ .id = "file" } },
            .media_type = "application/pdf",
        } }} },
    }}));
    const url_messages = [_]model_types.Message{.{
        .request = .{ .parts = &.{.{ .user_prompt = .{ .document = .{
            .source = .{ .url = "https://example.test/guide.pdf" },
            .media_type = "application/pdf",
        } } }} },
    }};
    const url_body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{ .messages = &url_messages });
    defer std.testing.allocator.free(url_body);
    try std.testing.expect(std.mem.indexOf(u8, url_body, "\"source\":{\"type\":\"url\",\"url\":\"https://example.test/guide.pdf\"}") != null);
    const unsupported = [_]model_types.Message{.{
        .request = .{ .parts = &.{.{ .user_prompt = .{ .audio = .{
            .source = .{ .bytes = "audio" },
            .media_type = "audio/mpeg",
        } } }} },
    }};
    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(
        std.testing.allocator,
        "claude-test",
        20,
        .{ .messages = &unsupported },
    ));
    const unsupported_response = [_]model_types.Message{.{ .response = .{ .parts = &.{.{ .binary = .{
        .source = .{ .bytes = "binary" },
        .media_type = "application/octet-stream",
    } }} } }};
    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(
        std.testing.allocator,
        "claude-test",
        20,
        .{ .messages = &unsupported_response },
    ));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const redacted = try decodeResponse(
        arena.allocator(),
        "{\"content\":[{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}]}",
    );
    try std.testing.expectEqualStrings("opaque", redacted.parts[0].thinking.signature.?);
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), "[]"));

    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, _: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
    };
    var sink: Sink = .{};
    var state = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &sink, .eventFn = Sink.emit },
        .status = 200,
    };
    defer state.deinit();
    try std.testing.expectError(error.InvalidProviderResponse, StreamState.line(
        &state,
        "data: {\"type\":\"message_delta\",\"delta\":[],\"usage\":{\"output_tokens\":1}}",
    ));
    try StreamState.line(
        &state,
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}",
    );
    try std.testing.expectEqual(model_types.FinishReason.Kind.stop, state.finish_reason.?.kind);
    try std.testing.expectEqual(@as(usize, 1), sink.events);
}

test "Anthropic encodes detailed message forms and rejects lossy forms" {
    const uploaded = model_types.UploadedFile{
        .id = "file_uploaded",
        .provider_name = "anthropic",
        .media_type = "image/png",
    };
    const image = model_types.Content{
        .source = .{ .uploaded_file = uploaded },
        .media_type = "image/png",
    };
    try std.testing.expect(hasProviderFiles(&.{.{ .request = .{ .parts = &.{
        .{ .user_prompt = .{ .uploaded_file = uploaded } },
    } } }}));
    try std.testing.expect(hasProviderFiles(&.{.{ .request = .{ .parts = &.{
        .{ .user_prompt_part = .{ .content = .{ .image = image } } },
    } } }}));
    try std.testing.expect(hasProviderFiles(&.{.{ .request = .{ .parts = &.{
        .{ .user_prompt_part = .{ .content = .{ .uploaded_file = uploaded } } },
    } } }}));
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt_part = .{ .content = "system" } },
            .{ .user_prompt = .{ .text_content = .{ .content = "rich" } } },
            .{ .user_prompt = .{ .uploaded_file = uploaded } },
            .{ .user_prompt_part = .{ .content = .{ .text = "timestamped" } } },
            .{ .user_prompt_part = .{ .content = .{ .text_content = .{ .content = "metadata" } } } },
            .{ .user_prompt_part = .{ .content = .{ .image = image } } },
            .{ .user_prompt_part = .{ .content = .{ .document = .{
                .source = .{ .url = "https://example.test/guide.pdf" },
                .media_type = "application/pdf",
            } } } },
            .{ .user_prompt_part = .{ .content = .{ .cache_point = .{} } } },
            .{ .user_prompt_part = .{ .content = .{ .uploaded_file = uploaded } } },
            .{ .retry_prompt_part = .{ .content = "retry" } },
            .{ .speech = .{ .speaker = .user, .transcript = "spoken" } },
            .{ .tool_return = .{ .call_id = "call", .name = "tool", .content = "ok" } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text_part = .{ .content = "answer" } },
            .{ .image = image },
            .{ .document = .{
                .source = .{ .url = "https://example.test/result.pdf" },
                .media_type = "application/pdf",
            } },
            .{ .speech = .{ .speaker = .assistant, .transcript = "said" } },
            .{ .thinking = .{ .content = "think", .signature = "signature" } },
            .{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "file_uploaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "spoken") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "said") != null);

    const unsupported = [_]model_types.Message{
        .{ .request = .{ .parts = &.{.{ .user_prompt_part = .{ .content = .{ .video = image } } }} } },
        .{ .request = .{ .parts = &.{.{ .speech = .{ .speaker = .user } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_availability_delta = .{ .tools_added = &.{} } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "call",
            .name = "tool",
            .content = "ok",
            .files = &.{image},
        } }} } },
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .uploaded_file = .{
            .id = "foreign-file",
            .provider_name = "openai",
        } } }} } },
        .{ .response = .{ .parts = &.{.{ .text_part = .{
            .content = "provider-bound",
            .provider = .{ .id = "item", .provider_name = "anthropic" },
        } }} } },
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "call",
            .name = "tool",
            .arguments_json = "{}",
            .thought_signature = "unsupported",
        } }} } },
        .{ .response = .{ .parts = &.{.{ .speech = .{ .speaker = .assistant } }} } },
        .{ .response = .{ .parts = &.{.{ .compaction = .{ .content = "summary" } }} } },
    };
    for (unsupported) |message| try std.testing.expectError(
        error.UnsupportedContentType,
        encodeRequest(std.testing.allocator, "claude-test", 20, .{ .messages = &.{message} }),
    );
}

test "Anthropic rejects provider responses beyond the JSON nesting limit" {
    const source = "[" ** 129 ++ "0" ++ "]" ** 129;
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(std.testing.allocator, source));
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

test "fuzz Anthropic streaming decoder" {
    try std.testing.fuzz({}, fuzzStreamLine, .{ .corpus = &.{"\x08\x00\x00\x00data: {}"} });
}
