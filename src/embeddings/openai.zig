//! OpenAI and OpenAI-compatible `/embeddings` wire adapter.

const std = @import("std");
const base = @import("base.zig");
const json_limits = @import("../json.zig");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const common = @import("../providers/common.zig");
const transport = @import("../transport.zig");

pub const Error = model_types.ProviderRequestError || error{
    InvalidRequestEncoding,
    InvalidProviderResponse,
};

/// Borrowed OpenAI embedding client.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    max_batch_size: usize = 2_048,
    max_dimensions: ?usize = null,

    pub fn model(self: *Client) base.Model {
        return .{
            .context = self,
            .provider_name = self.provider.name,
            .model_name = self.model_name,
            .max_batch_size = self.max_batch_size,
            .max_dimensions = self.max_dimensions,
            .embed_fn = embed,
        };
    }

    fn embed(context: *anyopaque, gpa: std.mem.Allocator, request: base.Request) !base.BatchResult {
        const self: *Client = @ptrCast(@alignCast(context));
        const body = encodeRequest(gpa, self.model_name, request) catch |failure| return switch (failure) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            else => Error.InvalidRequestEncoding,
        };
        defer gpa.free(body);
        const response = self.provider.request(gpa, .{
            .method = .POST,
            .endpoint = "/embeddings",
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .body = body,
            .timeout_ms = request.timeout_ms,
            .cancellation = request.cancellation,
        }) catch |failure| return common.transportError(failure);
        defer gpa.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            self.provider.observeError(gpa, response.status, response.body, response.metadata, null, .{});
            return common.statusError(response.status);
        }
        return decodeResponse(gpa, response.body, request.inputs.len) catch |failure|
            return common.responseDecodeError(failure);
    }
};

fn encodeRequest(gpa: std.mem.Allocator, model_name: []const u8, request: base.Request) ![]u8 {
    if (model_name.len == 0 or request.inputs.len == 0) return Error.InvalidRequestEncoding;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_name);
    try json.objectField("input");
    try json.write(request.inputs);
    if (request.dimensions) |dimensions| {
        try json.objectField("dimensions");
        try json.write(dimensions);
    }
    try json.objectField("encoding_format");
    try json.write("float");
    try json.endObject();
    return output.toOwnedSlice();
}

const WireResponse = struct {
    data: []const Item,
    model: ?[]const u8 = null,
    usage: ?Usage = null,
    id: ?[]const u8 = null,

    const Item = struct {
        embedding: []const f32,
        index: usize,
    };

    const Usage = struct {
        prompt_tokens: u64 = 0,
        total_tokens: u64 = 0,
    };
};

fn decodeResponse(gpa: std.mem.Allocator, source: []const u8, expected_count: usize) !base.BatchResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const parsed = try json_limits.parseLeaky(
        WireResponse,
        memory,
        source,
        json_limits.defaults.provider_response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        Error.InvalidProviderResponse,
    );
    if (parsed.data.len != expected_count) return Error.InvalidProviderResponse;
    const vectors = try memory.alloc([]const f32, expected_count);
    const seen = try memory.alloc(bool, expected_count);
    @memset(seen, false);
    for (parsed.data) |item| {
        if (item.index >= expected_count or seen[item.index] or item.embedding.len == 0)
            return Error.InvalidProviderResponse;
        seen[item.index] = true;
        vectors[item.index] = item.embedding;
    }
    const response_id = if (parsed.id) |id| try memory.dupe(u8, id) else null;
    return .{
        .arena = arena,
        .vectors = vectors,
        .usage = .{ .input_tokens = if (parsed.usage) |usage| usage.prompt_tokens else 0 },
        .response_id = response_id,
    };
}

test "OpenAI embeddings encode dimensions and restore provider index order" {
    const State = struct {
        fn request(
            _: *anyopaque,
            gpa: std.mem.Allocator,
            request_value: provider_types.Request,
        ) !transport.Response {
            try std.testing.expectEqualStrings("/embeddings", request_value.endpoint);
            try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"dimensions\":2") != null);
            try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"encoding_format\":\"float\"") != null);
            return .{
                .status = 200,
                .body = try gpa.dupe(u8, "{\"data\":[{\"embedding\":[3,4],\"index\":1}," ++
                    "{\"embedding\":[1,2],\"index\":0}]," ++
                    "\"model\":\"text-embedding-3-small\"," ++
                    "\"usage\":{\"prompt_tokens\":7,\"total_tokens\":7}}"),
            };
        }
    };
    var marker: u8 = 0;
    var client = Client{
        .model_name = "text-embedding-3-small",
        .provider = .{
            .context = &marker,
            .name = "openai",
            .base_url = "https://api.openai.test/v1",
            .requestFn = State.request,
        },
        .max_dimensions = 3_072,
    };
    var result = try (base.Embedder{ .model = client.model() }).embedDocuments(
        std.testing.allocator,
        &.{ "first", "second" },
        .{ .dimensions = 2 },
    );
    defer result.deinit();
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, result.vectors[0]);
    try std.testing.expectEqualSlices(f32, &.{ 3, 4 }, result.vectors[1]);
    try std.testing.expectEqual(@as(u64, 7), result.usage.input_tokens);
}

fn runOpenAIWithAllocator(gpa: std.mem.Allocator) !void {
    const State = struct {
        fn request(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: provider_types.Request,
        ) !transport.Response {
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"data\":[{\"embedding\":[1,2],\"index\":0}],\"id\":\"response-1\"}",
                ),
            };
        }
    };
    var marker: u8 = 0;
    var client = Client{
        .model_name = "embedding",
        .provider = .{
            .context = &marker,
            .name = "openai",
            .base_url = "https://api.openai.test/v1",
            .requestFn = State.request,
        },
    };
    var result = try (base.Embedder{ .model = client.model() }).embedQuery(gpa, "input", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 2), result.vectors[0][1]);
}

test "OpenAI embedding ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runOpenAIWithAllocator, .{});
}

test "OpenAI embeddings map status and malformed response failures" {
    const State = struct {
        body: []const u8,
        status: u16,

        fn request(
            context: *anyopaque,
            gpa: std.mem.Allocator,
            _: provider_types.Request,
        ) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = self.status, .body = try gpa.dupe(u8, self.body) };
        }
    };
    var state = State{ .body = "{}", .status = 429 };
    var client = Client{
        .model_name = "embedding",
        .provider = .{
            .context = &state,
            .name = "openai",
            .base_url = "https://api.openai.test/v1",
            .requestFn = State.request,
        },
    };
    try std.testing.expectError(
        error.ProviderRateLimited,
        client.model().embed(std.testing.allocator, .{ .inputs = &.{"input"}, .input_type = .query }),
    );
    state.status = 200;
    try std.testing.expectError(
        error.ProviderResponseDecodeError,
        client.model().embed(std.testing.allocator, .{ .inputs = &.{"input"}, .input_type = .query }),
    );
}
