//! A dependency-free Google Gemini GenerateContent API client.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");

pub const api_base = "https://generativelanguage.googleapis.com/v1beta";

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
        .supports_thinking = false,
        .supports_streaming = true,
    },

    pub fn model(self: *Client) model_types.Model {
        return .{ .context = self, .profile = self.profile, .requestFn = request, .streamFn = stream };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:generateContent", .{ self.base_url, self.model_name });
        defer allocator.free(url);
        const response = try self.transport.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        });
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "google", response.status, response.body, response.metadata);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body);
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
        const response = try self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key, .sensitive = true },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink());
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "google", response.status, state.error_body.items, response.metadata);
            return common.statusError(response.status);
        }
        return .{ .parts = try state.parts.toOwnedSlice(allocator), .usage = state.usage };
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    sink: model_types.ModelStreamSink,
    status: u16 = 0,
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
        if (data.len == 0) return;
        const chunk = try decodeResponse(self.allocator, data);
        defer self.allocator.free(chunk.parts);
        for (chunk.parts) |part| {
            try self.parts.append(self.allocator, part);
            switch (part) {
                .text => |text| try self.sink.emit(.{ .text_delta = text }),
                .tool_call => |call| try self.sink.emit(.{ .tool_call = call }),
                .tool_result => {},
            }
        }
        if (chunk.usage.input_tokens != 0 or chunk.usage.output_tokens != 0) {
            self.usage = chunk.usage;
            try self.sink.emit(.{ .usage = self.usage });
        }
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();

    var has_system = request.instructions.len > 0;
    for (request.messages) |message| if (message.role == .system) {
        has_system = true;
        break;
    };
    if (has_system) {
        try json.objectField("systemInstruction");
        try json.beginObject();
        try json.objectField("parts");
        try json.beginArray();
        for (request.messages) |message| if (message.role == .system) {
            for (message.parts) |part| switch (part) {
                .text => |text| try writeTextPart(&json, text),
                else => {},
            };
        };
        for (request.instructions) |instruction| try writeTextPart(&json, instruction);
        try json.endArray();
        try json.endObject();
    }

    try json.objectField("contents");
    try json.beginArray();
    for (request.messages) |message| {
        if (message.role == .system) continue;
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message.role == .assistant) "model" else "user");
        try json.objectField("parts");
        try json.beginArray();
        for (message.parts) |part| switch (part) {
            .text => |text| try writeTextPart(&json, text),
            .tool_call => |call| {
                try json.beginObject();
                try json.objectField("functionCall");
                try json.beginObject();
                try json.objectField("name");
                try json.write(call.name);
                try json.objectField("args");
                try common.rawJson(&json, call.arguments_json);
                try json.objectField("id");
                try json.write(call.id);
                try json.endObject();
                try json.endObject();
            },
            .tool_result => |result| {
                try json.beginObject();
                try json.objectField("functionResponse");
                try json.beginObject();
                try json.objectField("name");
                try json.write(result.name);
                try json.objectField("response");
                try json.beginObject();
                try json.objectField(if (result.is_error) "error" else "result");
                try common.rawJson(&json, result.content);
                try json.endObject();
                try json.objectField("id");
                try json.write(result.call_id);
                try json.endObject();
                try json.endObject();
            },
        };
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
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
            try common.rawJson(&json, tool.parameters_json_schema);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        try json.endArray();
    }

    switch (request.output) {
        .text => {},
        .json_object => try writeGenerationConfig(&json, null),
        .json_schema => |format| try writeGenerationConfig(&json, format.schema),
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn writeTextPart(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginObject();
    try json.objectField("text");
    try json.write(text);
    try json.endObject();
}

fn writeGenerationConfig(json: *std.json.Stringify, schema: ?[]const u8) !void {
    try json.objectField("generationConfig");
    try json.beginObject();
    try json.objectField("responseMimeType");
    try json.write("application/json");
    if (schema) |value| {
        try json.objectField("responseJsonSchema");
        try common.rawJson(json, value);
    }
    try json.endObject();
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const candidates = try common.requiredArray(root, "candidates");
    if (candidates.items.len == 0) return error.InvalidProviderResponse;
    const candidate = switch (candidates.items[0]) {
        .object => |value| value,
        else => return error.InvalidProviderResponse,
    };
    const content_value = candidate.get("content") orelse return error.InvalidProviderResponse;
    const parts_value = try common.requiredArray(content_value, "parts");
    var parts: std.ArrayList(model_types.Part) = .empty;
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
            try parts.append(allocator, .{ .text = value });
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
            } });
        }
    }

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
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage };
}

test "encodes Gemini system, tool, result, error, and structured output parts" {
    const messages = [_]model_types.Message{
        .{ .role = .system, .parts = &.{.{ .text = "Be concise." }} },
        .{ .role = .assistant, .parts = &.{.{ .tool_call = .{ .id = "call_1", .name = "weather", .arguments_json = "{\"city\":\"Madrid\"}" } }} },
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{ .call_id = "call_1", .name = "weather", .content = "{\"message\":\"failed\"}", .is_error = true } }} },
    };
    const body = try encodeRequest(std.testing.allocator, .{
        .messages = &messages,
        .instructions = &.{"Current instruction."},
        .tools = &.{.{ .name = "weather", .description = "Get weather.", .parameters_json_schema = "{\"type\":\"object\"}" }},
        .output = .{ .json_schema = .{ .name = "answer", .schema = "{\"type\":\"object\"}" } },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Current instruction.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionDeclarations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error\":{\"message\":\"failed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"responseJsonSchema\":{\"type\":\"object\"}") != null);

    const object_body = try encodeRequest(std.testing.allocator, .{ .messages = &.{}, .output = .json_object });
    defer std.testing.allocator.free(object_body);
    try std.testing.expect(std.mem.indexOf(u8, object_body, "\"responseMimeType\":\"application/json\"") != null);
}

test "decodes Gemini text, calls with and without ids, and usage" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"checking"},{"functionCall":{"id":"call_1","name":"weather","args":{"city":"Madrid"}}},{"functionCall":{"name":"other","args":{}}}]}}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 3), response.parts.len);
    try std.testing.expectEqualStrings("checking", response.parts[0].text);
    try std.testing.expectEqualStrings("call_1", response.parts[1].tool_call.id);
    try std.testing.expectEqualStrings("google-call-2", response.parts[2].tool_call.id);
    try std.testing.expectEqual(@as(u64, 8), response.usage.input_tokens);
}

test "rejects malformed Gemini responses" {
    const invalid = [_][]const u8{
        "{\"candidates\":[]}",
        "{\"candidates\":[false]}",
        "{\"candidates\":[{}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[false]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":false}]}}]}",
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
