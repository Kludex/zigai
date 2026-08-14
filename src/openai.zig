//! A dependency-free OpenAI Responses API client.

const std = @import("std");
const model_types = @import("model.zig");
const http = @import("transport.zig");
const common = @import("provider_common.zig");

pub const api_base = "https://api.openai.com/v1";

pub const Client = struct {
    model_name: []const u8,
    api_key: []const u8,
    transport: http.Transport,
    base_url: []const u8 = api_base,
    profile: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = true,
        .supports_system_messages = true,
        .supports_thinking = true,
        .supports_streaming = true,
    },

    pub fn model(self: *Client) model_types.Model {
        return .{ .context = self, .profile = self.profile, .requestFn = request, .streamFn = stream };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, self.model_name, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{self.base_url});
        defer allocator.free(url);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(authorization);
        const response = try self.transport.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = authorization, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        });
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "openai", response.status, response.body, response.metadata);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{self.base_url});
        defer allocator.free(url);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(authorization);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.text.deinit(allocator);
        defer state.parts.deinit(allocator);
        defer state.error_body.deinit(allocator);
        const response = try self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = authorization, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink());
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "openai", response.status, state.error_body.items, response.metadata);
            return common.statusError(response.status);
        }
        if (state.text.items.len > 0) try state.parts.insert(allocator, 0, .{ .text = try state.text.toOwnedSlice(allocator) });
        return .{ .parts = try state.parts.toOwnedSlice(allocator), .usage = state.usage };
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
        const root = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, data, .{});
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
        } else if (std.mem.eql(u8, kind, "response.completed")) {
            const response = try common.requiredObject(root, "response");
            const usage = try common.requiredObject(.{ .object = response }, "usage");
            self.usage = .{
                .input_tokens = try common.objectInteger(usage, "input_tokens"),
                .output_tokens = try common.objectInteger(usage, "output_tokens"),
            };
            try self.sink.emit(.{ .usage = self.usage });
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
    try json.objectField("input");
    try json.beginArray();
    for (request.messages) |message| {
        for (message.parts) |part| switch (part) {
            .text => |text| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("message");
                try json.objectField("role");
                try json.write(@tagName(message.role));
                try json.objectField("content");
                try json.write(text);
                try json.endObject();
            },
            .tool_call => |call| {
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
            },
            .tool_result => |result| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("function_call_output");
                try json.objectField("call_id");
                try json.write(result.call_id);
                try json.objectField("output");
                try json.write(result.content);
                try json.endObject();
            },
        };
    }
    try json.endArray();
    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try common.rawJson(&json, tool.parameters_json_schema);
            try json.endObject();
        }
        try json.endArray();
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
            try common.rawJson(&json, format.schema);
            try json.endObject();
            try json.endObject();
        },
    }
    try json.endObject();
    return output.toOwnedSlice();
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const output_items = try common.requiredArray(root, "output");
    var parts: std.ArrayList(model_types.Part) = .empty;
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
                }
            }
        } else if (std.mem.eql(u8, kind, "function_call")) {
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
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage };
}

test "decodes text, function calls, and usage" {
    const body =
        \\{"output":[{"type":"message","content":[{"type":"output_text","text":"thinking"}]},{"type":"function_call","call_id":"call_1","name":"weather","arguments":"{\"city\":\"Madrid\"}"}],"usage":{"input_tokens":11,"output_tokens":7}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), response.parts.len);
    try std.testing.expectEqualStrings("thinking", response.parts[0].text);
    try std.testing.expectEqualStrings("weather", response.parts[1].tool_call.name);
    try std.testing.expectEqual(@as(u64, 11), response.usage.input_tokens);
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
        .output = .json_object,
    });
    defer std.testing.allocator.free(json_object);
    try std.testing.expect(std.mem.indexOf(u8, json_object, "\"format\":{\"type\":\"json_object\"}") != null);

    const json_schema = try encodeRequest(std.testing.allocator, "gpt-test", .{
        .messages = &.{},
        .output = .{ .json_schema = .{
            .name = "answer",
            .schema = "{\"type\":\"object\"}",
        } },
    });
    defer std.testing.allocator.free(json_schema);
    try std.testing.expect(std.mem.indexOf(u8, json_schema, "\"type\":\"json_schema\",\"name\":\"answer\",\"strict\":true,\"schema\":{\"type\":\"object\"}") != null);
}
