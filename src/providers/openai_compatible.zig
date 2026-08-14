//! OpenAI-compatible Chat Completions client for gateways and local servers.

const std = @import("std");
const model_types = @import("../model.zig");
const http = @import("../transport.zig");
const common = @import("common.zig");

pub const api_base = "https://api.openai.com/v1";

pub const Error = model_types.ProviderRequestError || error{
    InvalidProviderResponse,
    InvalidRequestEncoding,
};

pub const profiles = struct {
    pub const full: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = true,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
        .reasoning_efforts = model_types.ModelProfile.ReasoningEffortSet.initFull(),
    };
    pub const basic: model_types.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
    };
    pub const minimal: model_types.ModelProfile = .{
        .supports_tools = false,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
    };
};

pub const Client = struct {
    model_name: []const u8,
    api_key: []const u8,
    transport: http.Transport,
    base_url: []const u8,
    provider_name: []const u8 = "openai-compatible",
    profile: model_types.ModelProfile = profiles.full,
    include_stream_usage: bool = true,
    settings: model_types.ModelSettings = .{},

    pub fn model(self: *Client) model_types.Model {
        return .{
            .context = self,
            .profile = self.profile,
            .provider_name = self.provider_name,
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
        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
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
            common.notifyProviderError(allocator, value.error_observer, self.provider_name, response.status, response.body, response.metadata);
            return common.statusError(response.status);
        }
        return decodeResponse(allocator, response.body);
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = try encodeStreamingRequest(allocator, self.model_name, value, self.include_stream_usage);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(authorization);
        var state = StreamState{ .allocator = allocator, .sink = sink };
        defer state.deinit();
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
            common.notifyProviderError(allocator, value.error_observer, self.provider_name, response.status, state.error_body.items, response.metadata);
            return common.statusError(response.status);
        }
        try state.finalizeCalls();
        if (state.text.items.len > 0) try state.parts.insert(allocator, 0, .{ .text = try state.text.toOwnedSlice(allocator) });
        return .{
            .parts = try state.parts.toOwnedSlice(allocator),
            .usage = state.usage,
            .finish_reason = state.finish_reason,
        };
    }
};

pub fn encodeRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest) ![]u8 {
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
    for (request.messages) |message| {
        if (message.role == .tool) {
            for (message.parts) |part| switch (part) {
                .tool_result => |result| try writeToolResult(&json, result),
                else => {},
            };
        } else {
            try writeMessage(allocator, &json, message);
        }
    }
    try json.endArray();
    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("function");
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("parameters");
            try common.rawJson(&json, tool.parameters_json_schema);
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
            try common.rawJson(&json, format.schema);
            try json.endObject();
            try json.endObject();
        },
    }
    try json.endObject();
    return output.toOwnedSlice();
}

pub fn encodeStreamingRequest(allocator: std.mem.Allocator, model_name: []const u8, request: model_types.ModelRequest, include_usage: bool) ![]u8 {
    const buffered = try encodeRequest(allocator, model_name, request);
    defer allocator.free(buffered);
    if (buffered.len == 0 or buffered[buffered.len - 1] != '}') return error.InvalidRequestEncoding;
    if (include_usage) return std.fmt.allocPrint(
        allocator,
        "{s},\"stream\":true,\"stream_options\":{{\"include_usage\":true}}}}",
        .{buffered[0 .. buffered.len - 1]},
    );
    return std.fmt.allocPrint(allocator, "{s},\"stream\":true}}", .{buffered[0 .. buffered.len - 1]});
}

fn writeMessage(allocator: std.mem.Allocator, json: *std.json.Stringify, message: model_types.Message) !void {
    const text = try collectText(allocator, message.parts);
    defer allocator.free(text);
    try json.beginObject();
    try json.objectField("role");
    try json.write(@tagName(message.role));
    try json.objectField("content");
    if (text.len > 0) try json.write(text) else try json.write(null);
    var has_calls = false;
    for (message.parts) |part| if (part == .tool_call) {
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
            else => {},
        };
        try json.endArray();
    }
    try json.endObject();
}

fn writeToolResult(json: *std.json.Stringify, result: model_types.ToolResult) !void {
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
        else => {},
    };
    return text.toOwnedSlice(allocator);
}

pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) !model_types.ModelResponse {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
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
            else => return error.InvalidProviderResponse,
        };
        for (calls.items) |call_value| {
            const call = switch (call_value) {
                .object => |value| value,
                else => return error.InvalidProviderResponse,
            };
            const function = try common.requiredObject(.{ .object = call }, "function");
            const arguments = try common.objectString(function, "arguments");
            _ = std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    finish_reason = .{
                        .kind = .incomplete_tool_call,
                        .raw = if (finish_reason) |reason| reason.raw else "malformed_tool_arguments",
                    };
                    continue;
                },
            };
            try parts.append(allocator, .{ .tool_call = .{
                .id = try common.objectString(call, "id"),
                .name = try common.objectString(function, "name"),
                .arguments_json = arguments,
            } });
        }
    }
    return .{
        .parts = try parts.toOwnedSlice(allocator),
        .usage = try decodeUsage(root),
        .finish_reason = finish_reason,
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

fn decodeUsage(root: std.json.Value) !model_types.Usage {
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
    return .{
        .input_tokens = try common.objectInteger(usage, "prompt_tokens"),
        .output_tokens = try common.objectInteger(usage, "completion_tokens"),
    };
}

const PendingCall = struct {
    index: u64,
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
        const root = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, data, .{});
        const usage = try decodeUsage(root);
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
                try self.text.appendSlice(self.allocator, text);
                try self.sink.emit(.{ .text_delta = text });
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
        try self.sink.emit(.{ .tool_call_delta = .{
            .id = if (id.len > 0) id else null,
            .name = if (name.len > 0) name else null,
            .arguments_delta = arguments,
        } });
    }

    fn findOrAppend(self: *StreamState, index: u64) !*PendingCall {
        for (self.pending.items) |*call| if (call.index == index) return call;
        try self.pending.append(self.allocator, .{ .index = index });
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
            _ = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, pending.arguments.items, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.finish_reason = .{
                        .kind = .incomplete_tool_call,
                        .raw = if (self.finish_reason) |reason| reason.raw else "malformed_tool_arguments",
                    };
                    pending.finalized = true;
                    continue;
                },
            };
            const call = model_types.ToolCall{
                .id = try pending.id.toOwnedSlice(self.allocator),
                .name = try pending.name.toOwnedSlice(self.allocator),
                .arguments_json = try pending.arguments.toOwnedSlice(self.allocator),
            };
            pending.finalized = true;
            try self.parts.append(self.allocator, .{ .tool_call = call });
            try self.sink.emit(.{ .tool_call = call });
        }
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

test "encodes Chat Completions messages, tools, and schema output" {
    const body = try encodeRequest(std.testing.allocator, "model", .{
        .messages = &.{
            .{ .role = .system, .parts = &.{.{ .text = "system" }} },
            .{ .role = .assistant, .parts = &.{.{ .tool_call = .{ .id = "call", .name = "weather", .arguments_json = "{}" } }} },
            .{ .role = .tool, .parts = &.{.{ .tool_result = .{ .call_id = "call", .name = "weather", .content = "sunny" } }} },
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

    const object_mode = try encodeRequest(std.testing.allocator, "model", .{ .messages = &.{}, .output = .json_object });
    defer std.testing.allocator.free(object_mode);
    try std.testing.expect(std.mem.indexOf(u8, object_mode, "\"type\":\"json_object\"") != null);
}

test "stream request usage collection is configurable" {
    const with_usage = try encodeStreamingRequest(std.testing.allocator, "model", .{ .messages = &.{} }, true);
    defer std.testing.allocator.free(with_usage);
    try std.testing.expect(std.mem.indexOf(u8, with_usage, "stream_options") != null);
    const without_usage = try encodeStreamingRequest(std.testing.allocator, "model", .{ .messages = &.{} }, false);
    defer std.testing.allocator.free(without_usage);
    try std.testing.expect(std.mem.indexOf(u8, without_usage, "stream_options") == null);
}

test "decodes Chat Completions text, tools, usage, and finish reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try decodeResponse(arena.allocator(), "{\"choices\":[{\"message\":{\"content\":\"hello\",\"tool_calls\":[{\"id\":\"call\",\"function\":{\"name\":\"weather\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}");
    try std.testing.expectEqual(@as(usize, 2), response.parts.len);
    try std.testing.expectEqualStrings("hello", response.parts[0].text);
    try std.testing.expectEqualStrings("weather", response.parts[1].tool_call.name);
    try std.testing.expectEqual(@as(u64, 5), response.usage.totalTokens());
    try std.testing.expectEqual(model_types.FinishReason.Kind.tool_calls, response.finish_reason.?.kind);
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
