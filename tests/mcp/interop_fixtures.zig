//! Deterministic replay of transcripts captured from official MCP servers.

const std = @import("std");
const zigai = @import("zigai");
const transcripts = @import("transcripts.zig");
const upstreams = @import("upstreams.zig");

const typescript_stdio = @embedFile("cassettes/typescript-todos-stdio.yaml");
const typescript_http = @embedFile("cassettes/typescript-todos-http.yaml");
const python_http = @embedFile("cassettes/python-everything-http.yaml");

test "official TypeScript reference server replays over stdio and HTTP" {
    const expected = Expected{
        .server = "typescript-todos",
        .discover = "todos",
        .tool = "add_task",
        .resource = "todos://board",
        .prompt = "plan-my-day",
    };
    try replayReferenceServer(typescript_stdio, .stdio, expected);
    try replayReferenceServer(typescript_http, .http, expected);
}

test "official Python reference server replays over HTTP" {
    try replayReferenceServer(python_http, .http, .{
        .server = "python-everything",
        .discover = "mcp-conformance-test-server",
        .tool = "test_simple_text",
        .resource = "test://static-text",
        .prompt = "test_simple_prompt",
    });
}

test "recorded MCP fixtures match the canonical pinned upstream matrix" {
    var manifest = try upstreams.parse(std.testing.allocator, @embedFile("upstreams.yaml"));
    defer manifest.deinit();
    try expectPinnedFixture(manifest.value(), typescript_stdio);
    try expectPinnedFixture(manifest.value(), typescript_http);
    try expectPinnedFixture(manifest.value(), python_http);
}

test "official TypeScript reference transports expose the same protocol surface" {
    var stdio = try transcripts.parse(std.testing.allocator, typescript_stdio);
    defer stdio.deinit();
    var http = try transcripts.parse(std.testing.allocator, typescript_http);
    defer http.deinit();

    try std.testing.expectEqual(stdio.value.interactions.len, http.value.interactions.len);
    for (stdio.value.interactions, http.value.interactions) |left, right| {
        try std.testing.expectEqualStrings(left.request.method, right.request.method);
        try std.testing.expectEqualStrings(left.request.message, right.request.message);
        try std.testing.expectEqual(left.events.len, right.events.len);
        for (left.events, right.events) |left_event, right_event| {
            try std.testing.expectEqualStrings(left_event, right_event);
        }
        try std.testing.expectEqualStrings(left.response, right.response);
    }
}

const Expected = struct {
    server: []const u8,
    discover: []const u8,
    tool: []const u8,
    resource: []const u8,
    prompt: []const u8,
};

fn replayReferenceServer(
    source: []const u8,
    expected_transport: transcripts.TransportKind,
    expected: Expected,
) !void {
    var replay = try transcripts.ReplayTransport.init(std.testing.allocator, source);
    defer replay.deinit();
    try std.testing.expectEqual(expected_transport, replay.parsed.value.transport);
    try std.testing.expectEqualStrings(expected.server, replay.parsed.value.source.server);

    var client = zigai.mcp.Client{
        .transport = replay.transport(),
        .name = "zigai-interop",
        .version = "0.1.0",
    };
    const discover = try client.discover(std.testing.allocator);
    defer std.testing.allocator.free(discover);
    try std.testing.expect(std.mem.indexOf(u8, discover, expected.discover) != null);
    const tools = try client.listTools(std.testing.allocator, null);
    defer std.testing.allocator.free(tools);
    try std.testing.expect(std.mem.indexOf(u8, tools, expected.tool) != null);
    const resources = try client.listResources(std.testing.allocator, null);
    defer std.testing.allocator.free(resources);
    try std.testing.expect(std.mem.indexOf(u8, resources, expected.resource) != null);
    const prompts = try client.listPrompts(std.testing.allocator, null);
    defer std.testing.allocator.free(prompts);
    try std.testing.expect(std.mem.indexOf(u8, prompts, expected.prompt) != null);
    try std.testing.expectEqual(@as(usize, 0), replay.remaining());
}

fn expectPinnedFixture(manifest: *const upstreams.Manifest, source: []const u8) !void {
    var transcript = try transcripts.parse(std.testing.allocator, source);
    defer transcript.deinit();
    for (manifest.servers) |server| {
        if (!std.mem.eql(u8, server.id, transcript.value.source.server)) continue;
        try std.testing.expectEqualStrings(server.revision, transcript.value.source.revision);
        const expected_transport: upstreams.Transport = switch (transcript.value.transport) {
            .stdio => .stdio,
            .http => .http,
        };
        try std.testing.expect(std.mem.indexOfScalar(upstreams.Transport, server.transports, expected_transport) != null);
        return;
    }
    return error.UnpinnedFixture;
}
