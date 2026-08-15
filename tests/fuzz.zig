//! Fuzz entry points for public parsers and protocol dispatchers.

const std = @import("std");
const zigai = @import("zigai");
const cassette = @import("support/cassettes/format.zig");

const max_input_bytes = 16 * 1024;

fn input(smith: *std.testing.Smith, buffer: []u8) []const u8 {
    return buffer[0..smith.slice(buffer)];
}

fn fuzzHistory(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var parsed = zigai.history.parse(std.testing.allocator, input(smith, &buffer)) catch return;
    parsed.deinit();
}

test "fuzz history envelope parser" {
    try std.testing.fuzz({}, fuzzHistory, .{ .corpus = &.{
        "\x1b\x00\x00\x00{\"version\":2,\"messages\":[]}",
    } });
}

fn fuzzPydanticAiMessages(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var parsed = zigai.codecs.pydantic_ai.parse(std.testing.allocator, input(smith, &buffer)) catch return;
    parsed.deinit();
}

test "fuzz PydanticAI message codec" {
    try std.testing.fuzz({}, fuzzPydanticAiMessages, .{ .corpus = &.{
        "\x02\x00\x00\x00[]",
        "\x1f\x00\x00\x00[{\"kind\":\"request\",\"parts\":[]}]",
    } });
}

fn fuzzResumeDecisions(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var parsed = zigai.parseResumeDecisions(std.testing.allocator, input(smith, &buffer)) catch return;
    parsed.deinit();
}

test "fuzz deferred resume decision parser" {
    try std.testing.fuzz({}, fuzzResumeDecisions, .{ .corpus = &.{
        "\x1c\x00\x00\x00{\"version\":1,\"decisions\":[]}",
    } });
}

const FuzzModel = struct {
    fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
        return error.FuzzModelStopped;
    }
};

fn fuzzPausedState(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var context: u8 = 0;
    const agent = zigai.Agent{ .model = .{
        .context = &context,
        .profile = .{},
        .requestFn = FuzzModel.request,
    } };
    var outcome = agent.resumeRun(std.testing.allocator, input(smith, &buffer), &.{}) catch return;
    outcome.deinit();
}

test "fuzz deferred paused-state parser" {
    try std.testing.fuzz({}, fuzzPausedState, .{ .corpus = &.{"\x02\x00\x00\x00{}"} });
}

fn fuzzJsonSchema(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    zigai.json_schema.validate(std.testing.allocator, .{ .json_schema = .{
        .name = "fuzz",
        .schema = "{\"type\":\"object\"}",
    } }, input(smith, &buffer)) catch return;
}

test "fuzz JSON Schema output parser" {
    try std.testing.fuzz({}, fuzzJsonSchema, .{ .corpus = &.{
        "\x02\x00\x00\x00{}",
    } });
}

fn fuzzProviderResponses(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    const source = input(smith, &buffer);
    inline for (.{
        zigai.providers.openai.decodeResponse,
        zigai.providers.openai_compatible.decodeResponse,
        zigai.providers.anthropic.decodeResponse,
        zigai.providers.google.decodeResponse,
    }) |decode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (decode(arena.allocator(), source)) |_| {} else |_| {}
    }
}

test "fuzz buffered provider response decoders" {
    try std.testing.fuzz({}, fuzzProviderResponses, .{ .corpus = &.{
        "\x02\x00\x00\x00{}",
        "\x0d\x00\x00\x00{\"output\":[]}",
    } });
}

fn fuzzCassetteYaml(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var parsed = cassette.parse(std.testing.allocator, input(smith, &buffer)) catch return;
    parsed.deinit();
}

test "fuzz cassette YAML parser" {
    try std.testing.fuzz({}, fuzzCassetteYaml, .{ .corpus = &.{
        "\x1c\x00\x00\x00version: 1\ninteractions: []\n",
    } });
}

const Handler = struct {
    fn handle(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
        return allocator.dupe(u8, "{}");
    }
};

fn fuzzMcpJsonRpc(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_input_bytes]u8 = undefined;
    var context: u8 = 0;
    var server = zigai.mcp.Server{ .handler = .{ .context = &context, .handleFn = Handler.handle } };
    const response = server.handle(std.testing.allocator, input(smith, &buffer), null) catch return;
    response.deinit(std.testing.allocator);
}

test "fuzz MCP JSON-RPC dispatcher" {
    try std.testing.fuzz({}, fuzzMcpJsonRpc, .{ .corpus = &.{
        "\x02\x00\x00\x00{}",
    } });
}
