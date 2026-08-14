//! A dependency-free Anthropic Messages API client.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");

pub const api_base = "https://api.anthropic.com/v1";
pub const api_version = "2023-06-01";

pub const Client = struct {
    model_name: []const u8,
    api_key: []const u8,
    transport: http.Transport,
    max_tokens: u32 = 4096,
    base_url: []const u8 = api_base,
    profile: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = false,
        .supports_system_messages = true,
        .supports_thinking = true,
        .supports_streaming = true,
    },

    pub fn model(self: *Client) model_types.Model {
        return .{ .context = self, .profile = self.profile, .requestFn = request, .streamFn = stream };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeRequest(allocator, self.model_name, self.max_tokens, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.base_url});
        defer allocator.free(url);
        const response = try self.transport.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
                .{ .name = "anthropic-version", .value = api_version },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        });
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "anthropic", response.status, response.body, response.metadata);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, self.max_tokens, value);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.base_url});
        defer allocator.free(url);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.deinit();
        const response = try self.transport.streamLines(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-api-key", .value = self.api_key, .sensitive = true },
                .{ .name = "anthropic-version", .value = api_version },
            },
            .body = body,
            .timeout_ms = value.timeout_ms,
            .cancellation = value.cancellation,
        }, state.lineSink());
        if (response.status < 200 or response.status >= 300) {
            common.notifyProviderError(allocator, value.error_observer, "anthropic", response.status, state.error_body.items, response.metadata);
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
    parts: std.ArrayList(model_types.Part) = .empty,
    pending: std.ArrayList(PendingCall) = .empty,
    error_body: std.ArrayList(u8) = .empty,
    usage: model_types.Usage = .{},
    finish_reason: ?model_types.FinishReason = null,

    fn deinit(self: *StreamState) void {
        self.text.deinit(self.allocator);
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
        const root = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, data, .{});
        const object = switch (root) {
            .object => |item| item,
            else => return error.InvalidProviderResponse,
        };
        const kind = try common.objectString(object, "type");
        if (std.mem.eql(u8, kind, "message_start")) {
            const message = try common.requiredObject(root, "message");
            const usage = try common.requiredObject(.{ .object = message }, "usage");
            self.usage.input_tokens = try common.objectInteger(usage, "input_tokens");
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const block = try common.requiredObject(root, "content_block");
            const block_type = try common.objectString(block, "type");
            if (std.mem.eql(u8, block_type, "tool_use")) {
                try self.pending.append(self.allocator, .{
                    .index = try common.objectInteger(object, "index"),
                    .id = try common.objectString(block, "id"),
                    .name = try common.objectString(block, "name"),
                });
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = try common.requiredObject(root, "delta");
            const delta_type = try common.objectString(delta, "type");
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                const text = try common.objectString(delta, "text");
                try self.text.appendSlice(self.allocator, text);
                try self.sink.emit(.{ .text_delta = text });
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const partial = try common.objectString(delta, "partial_json");
                const call = self.findPending(try common.objectInteger(object, "index")) orelse return error.InvalidProviderResponse;
                try call.arguments.appendSlice(self.allocator, partial);
                try self.sink.emit(.{ .tool_call_delta = .{ .id = call.id, .name = call.name, .arguments_delta = partial } });
            }
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            if (self.findPending(try common.objectInteger(object, "index"))) |pending| {
                const arguments = if (pending.arguments.items.len == 0)
                    try self.allocator.dupe(u8, "{}")
                else
                    try pending.arguments.toOwnedSlice(self.allocator);
                const call = model_types.ToolCall{ .id = pending.id, .name = pending.name, .arguments_json = arguments };
                try self.parts.append(self.allocator, .{ .tool_call = call });
                try self.sink.emit(.{ .tool_call = call });
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
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("max_tokens");
    try json.write(max_tokens);

    var has_system = request.instructions.len > 0;
    for (request.messages) |message| if (message.role == .system) {
        has_system = true;
        break;
    };
    if (has_system) {
        try json.objectField("system");
        try json.beginArray();
        for (request.messages) |message| if (message.role == .system) {
            for (message.parts) |part| switch (part) {
                .text => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    try json.endObject();
                },
                else => {},
            };
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
        if (message.role == .system) continue;
        try json.beginObject();
        try json.objectField("role");
        try json.write(if (message.role == .assistant) "assistant" else "user");
        try json.objectField("content");
        try json.beginArray();
        for (message.parts) |part| switch (part) {
            .text => |text| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("text");
                try json.objectField("text");
                try json.write(text);
                try json.endObject();
            },
            .tool_call => |call| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("tool_use");
                try json.objectField("id");
                try json.write(call.id);
                try json.objectField("name");
                try json.write(call.name);
                try json.objectField("input");
                try common.rawJson(&json, call.arguments_json);
                try json.endObject();
            },
            .tool_result => |result| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("tool_result");
                try json.objectField("tool_use_id");
                try json.write(result.call_id);
                try json.objectField("content");
                try json.write(result.content);
                if (result.is_error) {
                    try json.objectField("is_error");
                    try json.write(true);
                }
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
        for (request.tools) |tool| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("input_schema");
            try common.rawJson(&json, tool.parameters_json_schema);
            try json.endObject();
        }
        try json.endArray();
    }
    switch (request.output) {
        .text => {},
        .json_object => return error.UnsupportedOutputMode,
        .json_schema => |format| {
            try json.objectField("output_config");
            try json.beginObject();
            try json.objectField("format");
            try json.beginObject();
            try json.objectField("type");
            try json.write("json_schema");
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
        usage = .{
            .input_tokens = try common.objectInteger(object, "input_tokens"),
            .output_tokens = try common.objectInteger(object, "output_tokens"),
        };
    }
    const finish_reason = if (try common.optionalObjectString(root_object, "stop_reason")) |reason|
        anthropicFinishReason(reason)
    else
        null;
    return .{ .parts = try parts.toOwnedSlice(allocator), .usage = usage, .finish_reason = finish_reason };
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
        \\{"content":[{"type":"tool_use","id":"toolu_1","name":"weather","input":{"city":"Madrid"}}],"stop_reason":"tool_use","usage":{"input_tokens":8,"output_tokens":3}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), body);
    try std.testing.expectEqualStrings("toolu_1", response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"city\":\"Madrid\"}", response.parts[0].tool_call.arguments_json);
    try std.testing.expectEqual(@as(u64, 3), response.usage.output_tokens);
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
}

test "maps Anthropic length and refusal reasons" {
    try std.testing.expectEqual(model_types.FinishReason.Kind.length, anthropicFinishReason("max_tokens").kind);
    try std.testing.expectEqual(model_types.FinishReason.Kind.content_filter, anthropicFinishReason("refusal").kind);
}

test "encodes instructions, tool errors, and requests without system content" {
    const result_parts = [_]model_types.Part{.{ .tool_result = .{
        .call_id = "call_1",
        .name = "weather",
        .content = "failed",
        .is_error = true,
    } }};
    const messages = [_]model_types.Message{.{ .role = .tool, .parts = &result_parts }};
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
}

test "encodes Anthropic structured output and rejects JSON-object mode" {
    const body = try encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &.{},
        .output = .{ .json_schema = .{
            .name = "unused-by-anthropic",
            .schema = "{\"type\":\"object\"}",
        } },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\"}}}") != null);
    try std.testing.expectError(error.UnsupportedOutputMode, encodeRequest(std.testing.allocator, "claude-test", 20, .{
        .messages = &.{},
        .output = .json_object,
    }));
}
