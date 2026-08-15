//! Shared non-inference HTTP operations for provider implementations.

const std = @import("std");
const provider_types = @import("../provider.zig");
const http_provider = @import("http.zig");
const transport = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

/// Lists models from an OpenAI-compatible `GET /models` endpoint.
pub fn listOpenAIModels(context: *anyopaque, allocator: std.mem.Allocator) !provider_types.OwnedModels {
    const configured: *http_provider.Configured = @ptrCast(@alignCast(context));
    const response = configured.provider().request(allocator, .{
        .method = .GET,
        .endpoint = "/models",
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const root = json_limits.parseLeaky(
        std.json.Value,
        memory,
        response.body,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    ) catch |failure| return common.responseDecodeError(failure);
    const values = common.requiredArray(root, "data") catch |failure| return common.responseDecodeError(failure);
    const items = try memory.alloc(provider_types.ModelDescriptor, values.items.len);
    for (values.items, items) |value, *item| {
        const object = switch (value) {
            .object => |object| object,
            else => return error.ProviderResponseDecodeError,
        };
        item.* = .{
            .id = common.objectString(object, "id") catch |failure| return common.responseDecodeError(failure),
            .metadata_json = try std.json.Stringify.valueAlloc(memory, value, .{}),
        };
    }
    return .{ .arena = arena, .items = items };
}

test "OpenAI model discovery is authenticated owned and metadata preserving" {
    const State = struct {
        status: u16 = 200,
        body: []const u8 =
            \\{"object":"list","data":[{"id":"gpt-test","object":"model","owned_by":"openai"}]}
        ,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("https://api.example.test/v1/models", request.url);
            try std.testing.expectEqualStrings("Bearer secret", request.headers[0].value);
            return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
        }
    };
    var state: State = .{};
    var configured = http_provider.Configured{
        .name = "openai-compatible",
        .base_url = "https://api.example.test/v1",
        .transport = .{ .context = &state, .sendFn = State.send },
        .credential = .{ .bearer = "secret" },
        .operations = .{ .context = undefined, .listModelsFn = listOpenAIModels },
    };
    configured.operations.?.context = &configured;
    var models = try configured.provider().listModels(std.testing.allocator);
    defer models.deinit();
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expectEqualStrings("gpt-test", models.items[0].id);
    try std.testing.expectEqualStrings(
        "{\"id\":\"gpt-test\",\"object\":\"model\",\"owned_by\":\"openai\"}",
        models.items[0].metadata_json.?,
    );

    state.status = 429;
    try std.testing.expectError(error.ProviderRateLimited, configured.provider().listModels(std.testing.allocator));
    state.status = 200;
    state.body = "{\"data\":[null]}";
    try std.testing.expectError(error.ProviderResponseDecodeError, configured.provider().listModels(std.testing.allocator));
    state.body = "{\"data\":{}}";
    try std.testing.expectError(error.ProviderResponseDecodeError, configured.provider().listModels(std.testing.allocator));
    state.body = "not-json";
    try std.testing.expectError(error.ProviderResponseDecodeError, configured.provider().listModels(std.testing.allocator));
}

test "OpenAI model discovery releases every partial allocation" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: transport.Request) !transport.Response {
            return .{
                .status = 200,
                .body = try allocator.dupe(u8,
                    \\{"data":[{"id":"one","owned_by":"a"},{"id":"two","owned_by":"b"}]}
                ),
            };
        }

        fn run(allocator: std.mem.Allocator) !void {
            var marker: u8 = 0;
            var configured = http_provider.Configured{
                .name = "openai-compatible",
                .base_url = "https://api.example.test/v1",
                .transport = .{ .context = &marker, .sendFn = send },
                .credential = .{ .bearer = "secret" },
                .operations = .{ .context = undefined, .listModelsFn = listOpenAIModels },
            };
            configured.operations.?.context = &configured;
            var models = try configured.provider().listModels(allocator);
            models.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.run, .{});
}
