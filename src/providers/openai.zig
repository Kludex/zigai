//! A dependency-free OpenAI Responses API client.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

pub const api_base = "https://api.openai.com/v1";

pub const Error = model_types.ProviderRequestError || error{
    InvalidProviderResponse,
    InvalidRequestEncoding,
    UnsupportedBuiltinTool,
    UnsupportedContentType,
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
        .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initFull(),
        .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{.web_search}),
        .content_types = model_types.ModelProfile.ContentTypeSet.initMany(&.{ .image, .document, .binary }),
    },

    pub fn model(self: *Client) model_types.Model {
        return .{
            .context = self,
            .profile = self.profile,
            .provider_name = "openai",
            .model_name = self.model_name,
            .settings = self.settings,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, self.model_name, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{self.base_url});
        defer allocator.free(url);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(authorization);
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = authorization, .sensitive = true },
        });
        if (value.request_id) |request_id| try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
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
            common.notifyProviderError(allocator, value.error_observer, "openai", response.status, response.body, response.metadata);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body) catch |failure| return common.responseDecodeError(failure);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{self.base_url});
        defer allocator.free(url);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(authorization);
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = authorization, .sensitive = true },
        });
        if (value.request_id) |request_id| try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.text.deinit(allocator);
        defer state.parts.deinit(allocator);
        defer state.error_body.deinit(allocator);
        const response = self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink()) catch |failure| return common.transportError(failure);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "openai", response.status, state.error_body.items, response.metadata);
            return common.statusError(response.status);
        }
        if (state.text.items.len > 0) try state.parts.insert(allocator, 0, .{ .text = try state.text.toOwnedSlice(allocator) });
        return .{
            .parts = try state.parts.toOwnedSlice(allocator),
            .usage = state.usage,
            .finish_reason = state.finish_reason,
        };
    }
};

pub fn encodeStreamingRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest) ![]u8 {
    const buffered = try encodeRequest(allocator, model_name, request);
    defer allocator.free(buffered);
    if (buffered.len == 0 or buffered[buffered.len - 1] != '}') return error.InvalidRequestEncoding;
    return std.fmt.allocPrint(allocator, "{s},\"stream\":true}}", .{buffered[0 .. buffered.len - 1]});
}

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
    text: std.ArrayList(u8) = .empty,
    parts: std.ArrayList(model_types.Part) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,
    saw_tool_call_delta: bool = false,

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
        const kind = try common.objectString(object, "type");
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = try common.objectString(object, "delta");
            try self.text.appendSlice(self.allocator, delta);
            try self.sink.emit(.{ .text_delta = delta });
        } else if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
            self.saw_tool_call_delta = true;
            const delta = try common.objectString(object, "delta");
            try self.sink.emit(.{ .tool_call_delta = .{
                .id = try common.objectString(object, "item_id"),
                .arguments_delta = delta,
            } });
        } else if (std.mem.eql(u8, kind, "response.function_call_arguments.done")) {
            const call = model_types.ToolCall{
                .id = try common.objectString(object, "item_id"),
                .name = try common.objectString(object, "name"),
                .arguments_json = try common.objectString(object, "arguments"),
            };
            try self.parts.append(self.allocator, .{ .tool_call = call });
            try self.sink.emit(.{ .tool_call = call });
        } else if (std.mem.eql(u8, kind, "response.refusal.delta")) {
            self.finish_reason = .{ .kind = .content_filter, .raw = "refusal" };
        } else if (std.mem.eql(u8, kind, "response.completed") or
            std.mem.eql(u8, kind, "response.incomplete") or
            std.mem.eql(u8, kind, "response.failed"))
        {
            const response = try common.requiredObject(root, "response");
            if (self.finish_reason == null or self.finish_reason.?.kind != .content_filter) {
                self.finish_reason = try decodeFinishReason(
                    response,
                    hasToolCalls(self.parts.items),
                    self.saw_tool_call_delta and !hasToolCalls(self.parts.items),
                ) orelse .{
                    .kind = if (std.mem.eql(u8, kind, "response.completed"))
                        if (hasToolCalls(self.parts.items)) .tool_calls else .stop
                    else if (std.mem.eql(u8, kind, "response.incomplete"))
                        if (self.saw_tool_call_delta) .incomplete_tool_call else .other
                    else
                        .other,
                    .raw = kind,
                };
            }
            if (response.get("usage")) |usage_value| {
                const usage = switch (usage_value) {
                    .object => |usage_object| usage_object,
                    else => return error.InvalidProviderResponse,
                };
                self.usage = .{
                    .input_tokens = try common.objectInteger(usage, "input_tokens"),
                    .output_tokens = try common.objectInteger(usage, "output_tokens"),
                };
                try self.sink.emit(.{ .usage = self.usage });
            }
        }
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    if (request.instructions.len > 0) {
        const instructions = try std.mem.join(allocator, "\n\n", request.instructions);
        defer allocator.free(instructions);
        try json.objectField("instructions");
        try json.write(instructions);
    }
    try json.objectField("input");
    try json.beginArray();
    for (request.messages) |message| switch (message) {
        .request => |request_message| for (request_message.parts) |part| switch (part) {
            .system_prompt => |text| try writeTextMessage(&json, "system", text),
            .retry_prompt => |text| try writeTextMessage(&json, "user", text),
            .user_prompt => |content| switch (content) {
                .text => |text| try writeTextMessage(&json, "user", text),
                .image => |value| try writeContentMessage(allocator, &json, "user", .image, value),
                .document => |value| try writeContentMessage(allocator, &json, "user", .document, value),
                .binary => |value| try writeContentMessage(allocator, &json, "user", .binary, value),
                .audio => return error.UnsupportedContentType,
            },
            .tool_return => |result| try writeToolReturn(&json, result),
        },
        .response => |response| for (response.parts) |part| switch (part) {
            .text => |text| try writeTextMessage(&json, "assistant", text),
            .image => |content| try writeContentMessage(allocator, &json, "assistant", .image, content),
            .document => |content| try writeContentMessage(allocator, &json, "assistant", .document, content),
            .binary => |content| try writeContentMessage(allocator, &json, "assistant", .binary, content),
            .audio, .thinking => return error.UnsupportedContentType,
            .tool_call => |call| try writeToolCall(&json, call),
        },
    };
    try json.endArray();
    if (request.tools.len > 0 or request.builtin_tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.builtin_tools) |tool| switch (tool) {
            .web_search => {
                try json.beginObject();
                try json.objectField("type");
                try json.write("web_search");
                try json.endObject();
            },
            .web_fetch => return error.UnsupportedBuiltinTool,
        };
        for (request.tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try common.rawJson(allocator, &json, tool.parameters_json_schema, json_limits.defaults.schema);
            try json.endObject();
        }
        try json.endArray();
    }
    if (request.settings.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }
    if (request.settings.max_tokens) |max_tokens| {
        try json.objectField("max_output_tokens");
        try json.write(max_tokens);
    }
    if (request.settings.reasoning_effort) |effort| {
        try json.objectField("reasoning");
        try json.beginObject();
        try json.objectField("effort");
        try json.write(@tagName(effort));
        try json.endObject();
    }
    switch (request.output) {
        .text => {},
        .json_object => {
            try json.objectField("text");
            try json.beginObject();
            try json.objectField("format");
            try json.write(.{ .type = "json_object" });
            try json.endObject();
        },
        .json_schema => |format| {
            try json.objectField("text");
            try json.beginObject();
            try json.objectField("format");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_schema");
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
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeContentMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    role: []const u8,
    kind: model_types.ContentType,
    content: model_types.Content,
) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("message");
    try json.objectField("role");
    try json.write(role);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write(if (kind == .image) "input_image" else "input_file");
    switch (content.source) {
        .bytes => |bytes| {
            const encoded = try common.base64Alloc(allocator, bytes);
            defer allocator.free(encoded);
            if (kind == .image) {
                const data_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ content.media_type, encoded });
                defer allocator.free(data_url);
                try json.objectField("image_url");
                try json.write(data_url);
            } else {
                try json.objectField("file_data");
                try json.write(encoded);
                try json.objectField("filename");
                try json.write(content.filename orelse "file");
            }
        },
        .url => |url| {
            try json.objectField(if (kind == .image) "image_url" else "file_url");
            try json.write(url);
            if (kind != .image) if (content.filename) |filename| {
                try json.objectField("filename");
                try json.write(filename);
            };
        },
        .provider_file => |file| {
            try json.objectField("file_id");
            try json.write(file.id);
        },
    }
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

fn writeTextMessage(json: *std.json.Stringify, role: []const u8, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("message");
    try json.objectField("role");
    try json.write(role);
    try json.objectField("content");
    try json.write(text);
    try json.endObject();
}

fn writeToolCall(json: *std.json.Stringify, call: model_types.ToolCall) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("function_call");
    try json.objectField("call_id");
    try json.write(call.id);
    try json.objectField("name");
    try json.write(call.name);
    try json.objectField("arguments");
    try json.write(call.arguments_json);
    try json.endObject();
}

fn writeToolReturn(json: *std.json.Stringify, result: model_types.ToolResult) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("function_call_output");
    try json.objectField("call_id");
    try json.write(result.call_id);
    try json.objectField("output");
    try json.write(result.content);
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
    const output_items = try common.requiredArray(root, "output");
    var parts: std.ArrayList(model_types.Part) = .empty;
    var content_filtered = false;
    var incomplete_tool_call = false;
    for (output_items.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        const kind = try common.objectString(object, "type");
        if (std.mem.eql(u8, kind, "message")) {
            const content_value = object.get("content") orelse return error.InvalidProviderResponse;
            const content = switch (content_value) {
                .array => |value| value,
                else => return error.InvalidProviderResponse,
            };
            for (content.items) |content_item| {
                const content_object = switch (content_item) {
                    .object => |value| value,
                    else => return error.InvalidProviderResponse,
                };
                const content_type = try common.objectString(content_object, "type");
                if (std.mem.eql(u8, content_type, "output_text")) {
                    try parts.append(allocator, .{ .text = try common.objectString(content_object, "text") });
                } else if (std.mem.eql(u8, content_type, "refusal")) {
                    content_filtered = true;
                }
            }
        } else if (std.mem.eql(u8, kind, "function_call")) {
            if (try common.optionalObjectString(object, "status")) |status| {
                if (std.mem.eql(u8, status, "incomplete")) {
                    incomplete_tool_call = true;
                    continue;
                }
            }
            try parts.append(allocator, .{ .tool_call = .{
                .id = try common.objectString(object, "call_id"),
                .name = try common.objectString(object, "name"),
                .arguments_json = try common.objectString(object, "arguments"),
            } });
        }
    }
    var usage: model_types.Usage = .{};
    if (switch (root) {
        .object => |object| object.get("usage"),
        else => null,
    }) |usage_value| {
        const usage_object = switch (usage_value) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        usage = .{
            .input_tokens = try common.objectInteger(usage_object, "input_tokens"),
            .output_tokens = try common.objectInteger(usage_object, "output_tokens"),
        };
    }
    const finish_reason = if (content_filtered)
        model_types.FinishReason{ .kind = .content_filter, .raw = "refusal" }
    else
        try decodeFinishReason(root_object, hasToolCalls(parts.items), incomplete_tool_call);
    return .{
        .parts = try parts.toOwnedSlice(allocator),
        .usage = usage,
        .finish_reason = finish_reason,
    };
}

fn decodeFinishReason(
    object: std.json.ObjectMap,
    has_tool_calls: bool,
    incomplete_tool_call: bool,
) !?model_types.FinishReason {
    const status = try common.optionalObjectString(object, "status") orelse return null;
    if (std.mem.eql(u8, status, "completed")) return .{
        .kind = if (has_tool_calls) .tool_calls else .stop,
        .raw = status,
    };
    if (std.mem.eql(u8, status, "incomplete")) {
        const details_value = object.get("incomplete_details") orelse return .{
            .kind = if (incomplete_tool_call) .incomplete_tool_call else .other,
            .raw = status,
        };
        const details = switch (details_value) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        const reason = try common.optionalObjectString(details, "reason") orelse status;
        const kind: model_types.FinishReason.Kind = if (incomplete_tool_call)
            .incomplete_tool_call
        else if (std.mem.eql(u8, reason, "max_output_tokens"))
            .length
        else if (std.mem.eql(u8, reason, "content_filter"))
            .content_filter
        else
            .incomplete_tool_call;
        return .{ .kind = kind, .raw = reason };
    }
    return .{ .kind = .other, .raw = status };
}

fn hasToolCalls(parts: []const model_types.Part) bool {
    for (parts) |part| switch (part) {
        .tool_call => return true,
        else => {},
    };
    return false;
}

test "decodes text, function calls, and usage" {
    const body =
        \\{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"thinking"}]},{"type":"function_call","call_id":"call_1","name":"weather","arguments":"{\"city\":\"Madrid\"}"}],"usage":{"input_tokens":11,"output_tokens":7}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), response.parts.len);
    try std.testing.expectEqualStrings("thinking", response.parts[0].text);
    try std.testing.expectEqualStrings("weather", response.parts[1].tool_call.name);
    try std.testing.expectEqual(@as(u64, 11), response.usage.input_tokens);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
    try std.testing.expectEqualStrings("completed", response.finish_reason.?.raw);
}

test "maps incomplete Responses API reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(
        arena.allocator(),
        "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}",
    );
    try std.testing.expectEqual(model_types.FinishReason.Kind.length, response.finish_reason.?.kind);
    try std.testing.expectEqualStrings("max_output_tokens", response.finish_reason.?.raw);
}

test "rejects malformed nested content and usage" {
    var arena_one = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_one.deinit();
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(
        arena_one.allocator(),
        "{\"output\":[{\"type\":\"message\",\"content\":[false]}]}",
    ));

    var arena_two = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_two.deinit();
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(
        arena_two.allocator(),
        "{\"output\":[],\"usage\":[]}",
    ));
}

test "encodes both Responses API structured output modes" {
    const json_object = try encodeRequest(std.testing.allocator, "gpt-test", .{
        .messages = &.{},
        .instructions = &.{ "First.", "Second." },
        .output = .json_object,
    });
    defer std.testing.allocator.free(json_object);
    try std.testing.expect(std.mem.indexOf(u8, json_object, "\"instructions\":\"First.\\n\\nSecond.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_object, "\"format\":{\"type\":\"json_object\"}") != null);

    const json_schema = try encodeRequest(std.testing.allocator, "gpt-test", .{
        .messages = &.{},
        .settings = .{ .temperature = 0.2, .max_tokens = 512, .reasoning_effort = .high },
        .output = .{ .json_schema = .{
            .name = "answer",
            .schema = "{\"type\":\"object\"}",
        } },
    });
    defer std.testing.allocator.free(json_schema);
    try std.testing.expect(std.mem.indexOf(u8, json_schema, "\"type\":\"json_schema\",\"name\":\"answer\",\"strict\":true,\"schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_schema, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_schema, "\"max_output_tokens\":512") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_schema, "\"reasoning\":{\"effort\":\"high\"}") != null);
}

test "client forwards OpenAI request correlation IDs" {
    const State = struct {
        buffered: bool = false,
        streaming: bool = false,

        fn hasCorrelation(request: http.Request) bool {
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-client-request-id") and
                std.mem.eql(u8, header.value, "run-123")) return true;
            return false;
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request_value: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.buffered = hasCorrelation(request_value);
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, request_value: http.Request, _: http.LineSink) !http.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streaming = hasCorrelation(request_value);
            return error.ConnectionResetByPeer;
        }
    };
    var state: State = .{};
    var client = Client{
        .model_name = "gpt-test",
        .api_key = "secret",
        .transport = .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try client.model().request(arena.allocator(), .{ .messages = &.{}, .request_id = "run-123" });
    const Sink = struct {
        fn emit(_: *anyopaque, _: model_types.ModelStreamEvent) !void {}
    };
    try std.testing.expectError(error.ProviderConnectionError, client.model().stream(arena.allocator(), .{
        .messages = &.{},
        .request_id = "run-123",
    }, .{ .context = &state, .eventFn = Sink.emit }));
    try std.testing.expect(state.buffered);
    try std.testing.expect(state.streaming);
}

test "encodes OpenAI web search and rejects standalone web fetch" {
    const search = try encodeRequest(std.testing.allocator, "gpt-test", .{
        .messages = &.{},
        .builtin_tools = &.{.{ .web_search = .{} }},
    });
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"tools\":[{\"type\":\"web_search\"}]") != null);
    try std.testing.expectError(error.UnsupportedBuiltinTool, encodeRequest(std.testing.allocator, "gpt-test", .{
        .messages = &.{},
        .builtin_tools = &.{.{ .web_fetch = .{} }},
    }));
}

test "encodes OpenAI image, document, and provider file inputs" {
    const messages = [_]model_types.Message{
        .{ .request = .{ .parts = &.{
            .{ .retry_prompt = "Retry with the files." },
            .{ .user_prompt = .{ .text = "Review these." } },
            .{ .user_prompt = .{ .image = .{ .source = .{ .bytes = "png" }, .media_type = "image/png" } } },
            .{ .user_prompt = .{ .document = .{
                .source = .{ .url = "https://example.test/guide.pdf" },
                .media_type = "application/pdf",
                .filename = "guide.pdf",
            } } },
            .{ .user_prompt = .{ .binary = .{
                .source = .{ .provider_file = .{ .id = "file_123", .provider = "openai" } },
                .media_type = "application/octet-stream",
            } } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text = "Previous answer." },
            .{ .image = .{ .source = .{ .bytes = "answer" }, .media_type = "image/png" } },
            .{ .document = .{ .source = .{ .url = "https://example.test/answer.pdf" }, .media_type = "application/pdf" } },
            .{ .binary = .{ .source = .{ .provider_file = .{ .id = "file_answer" } }, .media_type = "application/octet-stream" } },
        } } },
    };
    const body = try encodeRequest(std.testing.allocator, "gpt-test", .{ .messages = &messages });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_url\":\"data:image/png;base64,cG5n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"file_url\":\"https://example.test/guide.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"filename\":\"guide.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"file_id\":\"file_123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Previous answer.") != null);
}

test "covers Responses API refusal, incomplete, and malformed edges" {
    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, _: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sink: Sink = .{};
    var refusal = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &sink, .eventFn = Sink.emit },
        .status = 200,
    };
    try StreamState.line(&refusal, "data: {\"type\":\"response.refusal.delta\"}");
    try refusal.sink.emit(.{ .text_delta = "covered" });
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, refusal.finish_reason.?.kind);

    var incomplete = StreamState{
        .allocator = arena.allocator(),
        .sink = .{ .context = &sink, .eventFn = Sink.emit },
        .status = 200,
        .saw_tool_call_delta = true,
    };
    try StreamState.line(&incomplete, "data: {\"type\":\"response.incomplete\",\"response\":{}}");
    try std.testing.expectEqual(model_types.FinishReason.Kind.incomplete_tool_call, incomplete.finish_reason.?.kind);
    try std.testing.expectError(error.InvalidProviderResponse, StreamState.line(
        &incomplete,
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":false}}",
    ));

    const unsupported_messages = [_]model_types.Message{.{
        .request = .{ .parts = &.{.{ .user_prompt = .{ .audio = .{
            .source = .{ .bytes = "audio" },
            .media_type = "audio/mpeg",
        } } }} },
    }};
    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(
        std.testing.allocator,
        "gpt-test",
        .{ .messages = &unsupported_messages },
    ));
    const unsupported_response = [_]model_types.Message{.{ .response = .{ .parts = &.{.{ .audio = .{
        .source = .{ .bytes = "audio" },
        .media_type = "audio/mpeg",
    } }} } }};
    try std.testing.expectError(error.UnsupportedContentType, encodeRequest(
        std.testing.allocator,
        "gpt-test",
        .{ .messages = &unsupported_response },
    ));
    const document_messages = [_]model_types.Message{.{
        .request = .{ .parts = &.{.{ .user_prompt = .{ .document = .{
            .source = .{ .bytes = "pdf" },
            .media_type = "application/pdf",
            .filename = "guide.pdf",
        } } }} },
    }};
    const document = try encodeRequest(std.testing.allocator, "gpt-test", .{ .messages = &document_messages });
    defer std.testing.allocator.free(document);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"file_data\":\"cGRm\"") != null);

    const invalid = [_][]const u8{
        "[]",
        "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\"}]}]}",
        "{\"status\":\"incomplete\",\"incomplete_details\":false,\"output\":[]}",
    };
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), invalid[0]));
    const filtered = try decodeResponse(arena.allocator(), invalid[1]);
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, filtered.finish_reason.?.kind);
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(arena.allocator(), invalid[2]));
    const incomplete_call = try decodeResponse(
        arena.allocator(),
        "{\"status\":\"incomplete\",\"output\":[{\"type\":\"function_call\",\"status\":\"incomplete\"}]}",
    );
    try std.testing.expectEqual(model_types.FinishReason.Kind.incomplete_tool_call, incomplete_call.finish_reason.?.kind);
    const unknown = try decodeResponse(arena.allocator(), "{\"status\":\"paused\",\"output\":[]}");
    try std.testing.expectEqual(model_types.FinishReason.Kind.other, unknown.finish_reason.?.kind);
}

test "OpenAI rejects provider responses beyond the JSON nesting limit" {
    const source = "[" ** 129 ++ "0" ++ "]" ** 129;
    try std.testing.expectError(error.InvalidProviderResponse, decodeResponse(std.testing.allocator, source));
}
