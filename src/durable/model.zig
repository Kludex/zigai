//! Durable model request and response wire documents.
//!
//! Requests exclude process-local callbacks and cancellation pointers. The
//! worker reconstructs those controls from its registered handler context.

const std = @import("std");
const history = @import("../history.zig");
const model_types = @import("../model.zig");

pub const format_version: u8 = 1;
pub const max_document_bytes: usize = 2 * 1024 * 1024;

pub const Error = error{
    InvalidModelRequest,
    InvalidModelResponse,
    UnsupportedModelWireVersion,
};

const RequestDocument = struct {
    version: u8,
    messages_json: []const u8,
    instructions: []const []const u8,
    tools: []const model_types.ToolDefinition,
    builtin_tools: []const model_types.BuiltinTool,
    output: model_types.OutputFormat,
    error_policy: model_types.ProviderErrorPolicy,
    url_policy: @import("../security.zig").UrlPolicy,
    request_id: ?[]const u8,
    idempotency_key: ?[]const u8,
    timeout_ms: ?u64,
    settings: model_types.ModelSettings,
};

/// Arena-owned request reconstructed by a registered durable model worker.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: model_types.ModelRequest,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Serializes every declarative model-request field. Process-local observer and
/// cancellation pointers are intentionally restored by the worker.
pub fn stringifyRequest(allocator: std.mem.Allocator, request: model_types.ModelRequest) ![]u8 {
    const messages_json = try history.stringify(allocator, request.messages);
    defer allocator.free(messages_json);
    return std.json.Stringify.valueAlloc(allocator, RequestDocument{
        .version = format_version,
        .messages_json = messages_json,
        .instructions = request.instructions,
        .tools = request.tools,
        .builtin_tools = request.builtin_tools,
        .output = request.output,
        .error_policy = request.error_policy,
        .url_policy = request.url_policy,
        .request_id = request.request_id,
        .idempotency_key = request.idempotency_key,
        .timeout_ms = request.timeout_ms,
        .settings = request.settings,
    }, .{});
}

/// Parses one durable model request. All borrowed request slices remain valid
/// until `deinit`; the worker may attach its own observer and cancellation.
pub fn parseRequest(allocator: std.mem.Allocator, source: []const u8) !OwnedRequest {
    if (source.len > max_document_bytes) return Error.InvalidModelRequest;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(RequestDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_document_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidModelRequest,
    };
    if (parsed.version != format_version) return Error.UnsupportedModelWireVersion;
    const messages = history.parseLeaky(memory, parsed.messages_json) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidModelRequest,
    };
    return .{
        .arena = arena,
        .value = .{
            .messages = messages,
            .instructions = parsed.instructions,
            .tools = parsed.tools,
            .builtin_tools = parsed.builtin_tools,
            .output = parsed.output,
            .error_policy = parsed.error_policy,
            .url_policy = parsed.url_policy,
            .request_id = parsed.request_id,
            .idempotency_key = parsed.idempotency_key,
            .timeout_ms = parsed.timeout_ms,
            .settings = parsed.settings,
        },
    };
}

/// Encodes one model response in the canonical message-history format.
pub fn stringifyResponse(allocator: std.mem.Allocator, response: model_types.ModelResponse) ![]u8 {
    return history.stringify(allocator, &.{.{ .response = response }});
}

/// Arena-owned response returned from a durable runtime success record.
pub const OwnedResponse = struct {
    history_value: history.Owned,
    value: model_types.ModelResponse,

    pub fn deinit(self: *OwnedResponse) void {
        self.history_value.deinit();
        self.* = undefined;
    }
};

pub fn parseResponse(allocator: std.mem.Allocator, source: []const u8) !OwnedResponse {
    var parsed = history.parse(allocator, source) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidModelResponse,
    };
    errdefer parsed.deinit();
    if (parsed.messages.len != 1) return Error.InvalidModelResponse;
    const response = switch (parsed.messages[0]) {
        .response => |value| value,
        .request => return Error.InvalidModelResponse,
    };
    return .{ .history_value = parsed, .value = response };
}

test "durable model request round trips declarative fields" {
    const request = model_types.ModelRequest{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "hello" } }} } }},
        .instructions = &.{"be concise"},
        .tools = &.{.{
            .name = "weather",
            .description = "Weather",
            .parameters_json_schema = "{\"type\":\"object\"}",
        }},
        .output = .{ .json_schema = .{ .name = "answer", .schema = "{\"type\":\"object\"}" } },
        .request_id = "request-1",
        .idempotency_key = "stable-1",
        .timeout_ms = 5_000,
        .settings = .{ .temperature = 0.2, .tool_choice = .{ .tool = "weather" } },
    };
    const encoded = try stringifyRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(encoded);
    var decoded = try parseRequest(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("hello", decoded.value.messages[0].request.parts[0].user_prompt.text);
    try std.testing.expectEqualStrings("be concise", decoded.value.instructions[0]);
    try std.testing.expectEqualStrings("weather", decoded.value.tools[0].name);
    try std.testing.expectEqualStrings("answer", decoded.value.output.json_schema.name);
    try std.testing.expectEqualStrings("weather", decoded.value.settings.tool_choice.?.tool);
    try std.testing.expectEqual(@as(?u64, 5_000), decoded.value.timeout_ms);
}

test "durable model response requires exactly one response message" {
    const encoded = try stringifyResponse(std.testing.allocator, .{
        .parts = &.{.{ .text = "done" }},
        .usage = .{ .input_tokens = 2, .output_tokens = 1 },
        .provider_name = "test",
        .model_name = "model",
    });
    defer std.testing.allocator.free(encoded);
    var decoded = try parseResponse(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("done", decoded.value.parts[0].text);
    try std.testing.expectEqual(@as(u64, 2), decoded.value.usage.input_tokens);

    try std.testing.expectError(Error.InvalidModelResponse, parseResponse(
        std.testing.allocator,
        "{\"version\":2,\"messages\":[]}",
    ));
    try std.testing.expectError(Error.InvalidModelRequest, parseRequest(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.InvalidModelResponse, parseResponse(
        std.testing.allocator,
        "{\"version\":2,\"messages\":[{\"kind\":\"request\",\"parts\":[]}]}",
    ));
    const changed_version = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        encoded,
        "\"version\":2",
        "\"version\":3",
    );
    defer std.testing.allocator.free(changed_version);
    try std.testing.expectError(Error.InvalidModelResponse, parseResponse(std.testing.allocator, changed_version));
}
