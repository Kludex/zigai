//! Google Gemini `batchEmbedContents` text embedding adapter.

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

/// Borrowed Gemini embedding client.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    max_batch_size: usize = 100,
    max_dimensions: ?usize = null,
    query_task_type: []const u8 = "RETRIEVAL_QUERY",
    document_task_type: []const u8 = "RETRIEVAL_DOCUMENT",
    document_title: ?[]const u8 = null,

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
        if (!validModelName(self.model_name)) return Error.InvalidRequestEncoding;
        const body = encodeRequest(gpa, self, request) catch |failure| return switch (failure) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            else => Error.InvalidRequestEncoding,
        };
        defer gpa.free(body);
        const endpoint = try std.fmt.allocPrint(gpa, "/models/{s}:batchEmbedContents", .{self.model_name});
        defer gpa.free(endpoint);
        const response = self.provider.request(gpa, .{
            .method = .POST,
            .endpoint = endpoint,
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

fn encodeRequest(gpa: std.mem.Allocator, client: *const Client, request: base.Request) ![]u8 {
    if (request.inputs.len == 0) return Error.InvalidRequestEncoding;
    const task_type = switch (request.input_type) {
        .query => client.query_task_type,
        .document => client.document_task_type,
    };
    if (task_type.len == 0) return Error.InvalidRequestEncoding;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("requests");
    try json.beginArray();
    for (request.inputs) |input| {
        try json.beginObject();
        try json.objectField("model");
        const model_name = try std.fmt.allocPrint(gpa, "models/{s}", .{client.model_name});
        defer gpa.free(model_name);
        try json.write(model_name);
        try json.objectField("content");
        try json.beginObject();
        try json.objectField("parts");
        try json.beginArray();
        try json.beginObject();
        try json.objectField("text");
        try json.write(input);
        try json.endObject();
        try json.endArray();
        try json.endObject();
        try json.objectField("taskType");
        try json.write(task_type);
        if (request.input_type == .document) if (client.document_title) |title| {
            try json.objectField("title");
            try json.write(title);
        };
        if (request.dimensions) |dimensions| {
            try json.objectField("outputDimensionality");
            try json.write(dimensions);
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return output.toOwnedSlice();
}

const WireResponse = struct {
    embeddings: []const Embedding,

    const Embedding = struct {
        values: []const f32,
        statistics: ?Statistics = null,
    };

    const Statistics = struct {
        tokenCount: ?u64 = null,
        truncated: ?bool = null,
    };
};

fn decodeResponse(gpa: std.mem.Allocator, source: []const u8, expected_count: usize) !base.BatchResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const parsed = try json_limits.parseLeaky(
        WireResponse,
        arena.allocator(),
        source,
        json_limits.defaults.provider_response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        Error.InvalidProviderResponse,
    );
    if (parsed.embeddings.len != expected_count) return Error.InvalidProviderResponse;
    const vectors = try arena.allocator().alloc([]const f32, expected_count);
    var input_tokens: u64 = 0;
    for (parsed.embeddings, vectors) |embedding, *vector| {
        if (embedding.values.len == 0) return Error.InvalidProviderResponse;
        vector.* = embedding.values;
        if (embedding.statistics) |statistics| if (statistics.tokenCount) |tokens| {
            input_tokens = std.math.add(u64, input_tokens, tokens) catch return Error.InvalidProviderResponse;
        };
    }
    return .{
        .arena = arena,
        .vectors = vectors,
        .usage = .{ .input_tokens = input_tokens },
    };
}

fn validModelName(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

test "Google embeddings encode document task dimensions and token usage" {
    const State = struct {
        fn request(
            _: *anyopaque,
            gpa: std.mem.Allocator,
            request_value: provider_types.Request,
        ) !transport.Response {
            try std.testing.expectEqualStrings(
                "/models/gemini-embedding-001:batchEmbedContents",
                request_value.endpoint,
            );
            try std.testing.expect(std.mem.indexOf(
                u8,
                request_value.body,
                "\"taskType\":\"RETRIEVAL_DOCUMENT\"",
            ) != null);
            try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"title\":\"Guide\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"outputDimensionality\":2") != null);
            return .{
                .status = 200,
                .body = try gpa.dupe(u8, "{\"embeddings\":[" ++
                    "{\"values\":[1,2],\"statistics\":{\"tokenCount\":3}}," ++
                    "{\"values\":[3,4],\"statistics\":{\"tokenCount\":5}}]}"),
            };
        }
    };
    var marker: u8 = 0;
    var client = Client{
        .model_name = "gemini-embedding-001",
        .provider = .{
            .context = &marker,
            .name = "gcp.gen_ai",
            .base_url = "https://generativelanguage.test/v1beta",
            .requestFn = State.request,
        },
        .max_dimensions = 3_072,
        .document_title = "Guide",
    };
    var result = try (base.Embedder{ .model = client.model() }).embedDocuments(
        std.testing.allocator,
        &.{ "first", "second" },
        .{ .dimensions = 2 },
    );
    defer result.deinit();
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, result.vectors[0]);
    try std.testing.expectEqual(@as(u64, 8), result.usage.input_tokens);
}

fn runGoogleWithAllocator(gpa: std.mem.Allocator) !void {
    const State = struct {
        fn request(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: provider_types.Request,
        ) !transport.Response {
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"embeddings\":[{\"values\":[1,2]}]}"),
            };
        }
    };
    var marker: u8 = 0;
    var client = Client{
        .model_name = "embedding",
        .provider = .{
            .context = &marker,
            .name = "gcp.gen_ai",
            .base_url = "https://generativelanguage.test/v1beta",
            .requestFn = State.request,
        },
    };
    var result = try (base.Embedder{ .model = client.model() }).embedQuery(gpa, "input", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 2), result.vectors[0][1]);
}

test "Google embedding ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runGoogleWithAllocator, .{});
}

test "Google embeddings reject unsafe models and malformed response counts" {
    const State = struct {
        calls: usize = 0,

        fn request(
            context: *anyopaque,
            gpa: std.mem.Allocator,
            _: provider_types.Request,
        ) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return .{ .status = 200, .body = try gpa.dupe(u8, "{\"embeddings\":[]}") };
        }
    };
    var state: State = .{};
    var client = Client{
        .model_name = "../unsafe",
        .provider = .{
            .context = &state,
            .name = "gcp.gen_ai",
            .base_url = "https://generativelanguage.test/v1beta",
            .requestFn = State.request,
        },
    };
    try std.testing.expectError(
        Error.InvalidRequestEncoding,
        client.model().embed(std.testing.allocator, .{ .inputs = &.{"input"}, .input_type = .query }),
    );
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    client.model_name = "embedding";
    try std.testing.expectError(
        error.ProviderResponseDecodeError,
        client.model().embed(std.testing.allocator, .{ .inputs = &.{"input"}, .input_type = .query }),
    );
}
