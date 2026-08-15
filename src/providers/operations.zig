//! Shared non-inference HTTP operations for provider implementations.

const std = @import("std");
const provider_types = @import("../provider.zig");
const http_provider = @import("http.zig");
const transport = @import("../transport.zig");
const common = @import("common.zig");
const json_limits = @import("../json.zig");

pub const DiscoveryLimits = struct {
    max_pages: usize = 100,
    max_models: usize = 10_000,

    fn validate(self: DiscoveryLimits) !void {
        if (self.max_pages == 0 or self.max_models == 0) return error.InvalidProviderPolicy;
    }
};

/// Lists models from an OpenAI-compatible `GET /models` endpoint.
pub fn listOpenAIModels(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    limits: DiscoveryLimits,
) !provider_types.OwnedModels {
    try limits.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var items: std.ArrayList(provider_types.ModelDescriptor) = .empty;
    _ = try appendPage(configured, allocator, arena.allocator(), &items, .{
        .endpoint = "/models",
        .items_field = "data",
        .id_field = "id",
    }, limits.max_models);
    return .{ .arena = arena, .items = try items.toOwnedSlice(arena.allocator()) };
}

/// Lists every page from Anthropic's Models API.
pub fn listAnthropicModels(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    limits: DiscoveryLimits,
) !provider_types.OwnedModels {
    try limits.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    var items: std.ArrayList(provider_types.ModelDescriptor) = .empty;
    var token: ?[]const u8 = null;
    var page_count: usize = 0;
    while (true) {
        page_count += 1;
        if (page_count > limits.max_pages) return error.ResponseTooLarge;
        const endpoint = if (token) |value|
            try queryEndpoint(memory, "/models?limit=1000&after_id=", value)
        else
            "/models?limit=1000";
        const page = try appendPage(configured, allocator, memory, &items, .{
            .endpoint = endpoint,
            .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
            .items_field = "data",
            .id_field = "id",
            .next_field = "last_id",
            .has_more_field = "has_more",
        }, limits.max_models);
        if (!page.has_more) break;
        token = page.next orelse return error.ProviderResponseDecodeError;
    }
    return .{ .arena = arena, .items = try items.toOwnedSlice(memory) };
}

/// Lists every page from Google Generative Language's Models API.
pub fn listGoogleModels(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    limits: DiscoveryLimits,
) !provider_types.OwnedModels {
    try limits.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    var items: std.ArrayList(provider_types.ModelDescriptor) = .empty;
    var token: ?[]const u8 = null;
    var page_count: usize = 0;
    while (true) {
        page_count += 1;
        if (page_count > limits.max_pages) return error.ResponseTooLarge;
        const endpoint = if (token) |value|
            try queryEndpoint(memory, "/models?pageSize=1000&pageToken=", value)
        else
            "/models?pageSize=1000";
        const page = try appendPage(configured, allocator, memory, &items, .{
            .endpoint = endpoint,
            .items_field = "models",
            .id_field = "name",
            .id_prefix = "models/",
            .next_field = "nextPageToken",
        }, limits.max_models);
        token = page.next;
        if (token == null) break;
    }
    return .{ .arena = arena, .items = try items.toOwnedSlice(memory) };
}

const PageOptions = struct {
    endpoint: []const u8,
    headers: []const transport.Header = &.{},
    items_field: []const u8,
    id_field: []const u8,
    id_prefix: []const u8 = "",
    next_field: ?[]const u8 = null,
    has_more_field: ?[]const u8 = null,
};

const Page = struct {
    next: ?[]const u8 = null,
    has_more: bool = false,
};

fn appendPage(
    configured: *http_provider.Configured,
    allocator: std.mem.Allocator,
    memory: std.mem.Allocator,
    items: *std.ArrayList(provider_types.ModelDescriptor),
    options: PageOptions,
    max_models: usize,
) !Page {
    const response = configured.provider().request(allocator, .{
        .method = .GET,
        .endpoint = options.endpoint,
        .headers = options.headers,
    }) catch |failure| return common.transportError(failure);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return common.statusError(response.status);
    const root = json_limits.parseLeaky(
        std.json.Value,
        memory,
        response.body,
        json_limits.defaults.provider_response,
        .{},
        error.InvalidProviderResponse,
    ) catch |failure| return common.responseDecodeError(failure);
    const object = switch (root) {
        .object => |value| value,
        else => return error.ProviderResponseDecodeError,
    };
    const values = common.requiredArray(root, options.items_field) catch |failure| return common.responseDecodeError(failure);
    if (values.items.len > max_models -| items.items.len) return error.ResponseTooLarge;
    try items.ensureUnusedCapacity(memory, values.items.len);
    for (values.items) |value| {
        const model_object = switch (value) {
            .object => |entry| entry,
            else => return error.ProviderResponseDecodeError,
        };
        const resource_name = common.objectString(model_object, options.id_field) catch |failure| return common.responseDecodeError(failure);
        if (!std.mem.startsWith(u8, resource_name, options.id_prefix) or resource_name.len == options.id_prefix.len)
            return error.ProviderResponseDecodeError;
        items.appendAssumeCapacity(.{
            .id = resource_name[options.id_prefix.len..],
            .metadata_json = try std.json.Stringify.valueAlloc(memory, value, .{}),
        });
    }
    const next = if (options.next_field) |field|
        common.optionalObjectString(object, field) catch |failure| return common.responseDecodeError(failure)
    else
        null;
    const has_more = if (options.has_more_field) |field| blk: {
        const value = object.get(field) orelse return error.ProviderResponseDecodeError;
        break :blk switch (value) {
            .bool => |boolean| boolean,
            else => return error.ProviderResponseDecodeError,
        };
    } else next != null;
    return .{ .next = next, .has_more = has_more };
}

fn queryEndpoint(allocator: std.mem.Allocator, prefix: []const u8, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(prefix);
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try output.writer.writeByte(byte);
        } else {
            try output.writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice();
}

test "OpenAI model discovery is authenticated owned and bounded" {
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
    };
    var models = try listOpenAIModels(&configured, std.testing.allocator, .{});
    defer models.deinit();
    try std.testing.expectEqualStrings("gpt-test", models.items[0].id);
    try std.testing.expectEqualStrings(
        "{\"id\":\"gpt-test\",\"object\":\"model\",\"owned_by\":\"openai\"}",
        models.items[0].metadata_json.?,
    );
    try std.testing.expectError(error.InvalidProviderPolicy, listOpenAIModels(&configured, std.testing.allocator, .{ .max_models = 0 }));
    state.status = 429;
    try std.testing.expectError(error.ProviderRateLimited, listOpenAIModels(&configured, std.testing.allocator, .{}));
    state.status = 200;
    state.body = "{\"data\":[null]}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listOpenAIModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"data\":{}}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listOpenAIModels(&configured, std.testing.allocator, .{}));
    state.body = "[]";
    try std.testing.expectError(error.ProviderResponseDecodeError, listOpenAIModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"data\":[{\"id\":\"\"}]}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listOpenAIModels(&configured, std.testing.allocator, .{}));
    state.body = "not-json";
    try std.testing.expectError(error.ProviderResponseDecodeError, listOpenAIModels(&configured, std.testing.allocator, .{}));
}

test "Anthropic and Google model discovery paginate and normalize identifiers" {
    const State = struct {
        provider: enum { anthropic, google } = .anthropic,
        request_count: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.request_count += 1;
            return switch (self.provider) {
                .anthropic => blk: {
                    if (self.request_count == 0) {
                        try std.testing.expectEqualStrings("https://api.example.test/v1/models?limit=1000", request.url);
                        try std.testing.expectEqualStrings("anthropic-version", request.headers[0].name);
                        break :blk .{ .status = 200, .body = try allocator.dupe(u8,
                            \\{"data":[{"id":"claude-one"}],"has_more":true,"last_id":"next+/="}
                        ) };
                    }
                    try std.testing.expectEqualStrings("https://api.example.test/v1/models?limit=1000&after_id=next%2B%2F%3D", request.url);
                    break :blk .{ .status = 200, .body = try allocator.dupe(u8,
                        \\{"data":[{"id":"claude-two"}],"has_more":false,"last_id":"claude-two"}
                    ) };
                },
                .google => blk: {
                    if (self.request_count == 0) {
                        try std.testing.expectEqualStrings("https://api.example.test/v1/models?pageSize=1000", request.url);
                        break :blk .{ .status = 200, .body = try allocator.dupe(u8,
                            \\{"models":[{"name":"models/gemini-one"}],"nextPageToken":"next+/="}
                        ) };
                    }
                    try std.testing.expectEqualStrings("https://api.example.test/v1/models?pageSize=1000&pageToken=next%2B%2F%3D", request.url);
                    break :blk .{ .status = 200, .body = try allocator.dupe(u8,
                        \\{"models":[{"name":"models/gemini-two"}]}
                    ) };
                },
            };
        }
    };
    var state: State = .{};
    var configured = http_provider.Configured{
        .name = "test",
        .base_url = "https://api.example.test/v1",
        .transport = .{ .context = &state, .sendFn = State.send },
    };
    var anthropic = try listAnthropicModels(&configured, std.testing.allocator, .{});
    defer anthropic.deinit();
    try std.testing.expectEqualStrings("claude-one", anthropic.items[0].id);
    try std.testing.expectEqualStrings("claude-two", anthropic.items[1].id);
    state = .{ .provider = .google };
    var google = try listGoogleModels(&configured, std.testing.allocator, .{});
    defer google.deinit();
    try std.testing.expectEqualStrings("gemini-one", google.items[0].id);
    try std.testing.expectEqualStrings("gemini-two", google.items[1].id);
}

test "paginated discovery rejects malformed and unbounded provider pages" {
    const State = struct {
        body: []const u8,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = 200, .body = try allocator.dupe(u8, self.body) };
        }
    };
    var state = State{ .body = "{\"data\":[],\"has_more\":true}" };
    var configured = http_provider.Configured{
        .name = "test",
        .base_url = "https://api.example.test/v1",
        .transport = .{ .context = &state, .sendFn = State.send },
    };
    try std.testing.expectError(error.ProviderResponseDecodeError, listAnthropicModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"data\":[],\"has_more\":\"yes\"}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listAnthropicModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"models\":[{\"name\":\"wrong\"}]}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listGoogleModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"models\":[],\"nextPageToken\":1}";
    try std.testing.expectError(error.ProviderResponseDecodeError, listGoogleModels(&configured, std.testing.allocator, .{}));
    state.body = "{\"models\":[],\"nextPageToken\":\"again\"}";
    try std.testing.expectError(error.ResponseTooLarge, listGoogleModels(&configured, std.testing.allocator, .{ .max_pages = 1 }));
    state.body = "{\"data\":[{\"id\":\"one\"},{\"id\":\"two\"}]}";
    try std.testing.expectError(error.ResponseTooLarge, listOpenAIModels(&configured, std.testing.allocator, .{ .max_models = 1 }));
}

test "model discovery releases every partial allocation" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: transport.Request) !transport.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8,
                \\{"data":[{"id":"one","owned_by":"a"},{"id":"two","owned_by":"b"}]}
            ) };
        }
        fn run(allocator: std.mem.Allocator) !void {
            var marker: u8 = 0;
            var configured = http_provider.Configured{
                .name = "openai-compatible",
                .base_url = "https://api.example.test/v1",
                .transport = .{ .context = &marker, .sendFn = send },
            };
            var models = try listOpenAIModels(&configured, allocator, .{});
            models.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.run, .{});
}
