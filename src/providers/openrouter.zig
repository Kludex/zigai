//! OpenRouter Chat Completions client with typed provider routing.

const std = @import("std");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const compatible = @import("openai_compatible.zig");
const common = @import("common.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://openrouter.ai/api/v1";
pub const api_key_env = "OPENROUTER_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "openrouter",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.openRouter,
    .extra_body_kind = .openrouter,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const CompatibilityClient = compatible.ClientWithDefaults(defaults);

/// Request-scoped OpenRouter endpoint selection and data-policy controls.
pub const Routing = struct {
    order: ?[]const []const u8 = null,
    only: ?[]const []const u8 = null,
    ignore: ?[]const []const u8 = null,
    allow_fallbacks: ?bool = null,
    require_parameters: ?bool = null,
    data_collection: ?DataCollection = null,
    zdr: ?bool = null,
    enforce_distillable_text: ?bool = null,
    quantizations: ?[]const []const u8 = null,
    sort: ?Sort = null,
    preferred_min_throughput: ?Threshold = null,
    preferred_max_latency: ?Threshold = null,
    max_price: ?MaxPrice = null,

    pub const DataCollection = enum { allow, deny };
    pub const SortBy = enum { price, throughput, latency };
    pub const Partition = enum { model, none };
    pub const Sort = union(enum) {
        by: SortBy,
        partitioned: struct {
            by: SortBy,
            partition: Partition = .model,
        },
    };
    pub const Threshold = union(enum) {
        value: f64,
        percentiles: Percentiles,
    };
    pub const Percentiles = struct {
        p50: ?f64 = null,
        p75: ?f64 = null,
        p90: ?f64 = null,
        p99: ?f64 = null,
    };
    pub const MaxPrice = struct {
        prompt: ?f64 = null,
        completion: ?f64 = null,
        image: ?f64 = null,
        request: ?f64 = null,
    };

    pub fn validate(self: Routing) error{InvalidRequestEncoding}!void {
        try validateNames(self.order);
        try validateNames(self.only);
        try validateNames(self.ignore);
        if (self.only) |allowed| if (self.ignore) |ignored| {
            for (allowed) |name| for (ignored) |blocked| {
                if (std.mem.eql(u8, name, blocked)) return error.InvalidRequestEncoding;
            };
        };
        try validateNames(self.quantizations);
        if (self.preferred_min_throughput) |value| try validateThreshold(value);
        if (self.preferred_max_latency) |value| try validateThreshold(value);
        if (self.max_price) |price| {
            try validateOptionalNumber(price.prompt);
            try validateOptionalNumber(price.completion);
            try validateOptionalNumber(price.image);
            try validateOptionalNumber(price.request);
            if (price.prompt == null and price.completion == null and price.image == null and price.request == null)
                return error.InvalidRequestEncoding;
        }
    }
};

/// OpenRouter-specific client. The wire format remains Chat Completions, while
/// routing policy stays typed and isolated from generic compatible providers.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    profile: model_types.ModelProfile = defaults.profile,
    idempotency_header: ?[]const u8 = null,
    include_stream_usage: bool = defaults.include_stream_usage,
    settings: model_types.ModelSettings = .{},
    routing: ?Routing = null,

    pub fn model(self: *Client) model_types.Model {
        var resolved_profile = self.provider.modelProfile(self.model_name, self.profile);
        resolved_profile.supports_idempotency_key = self.idempotency_header != null;
        resolved_profile.extra_body_kind = .openrouter;
        return .{
            .context = self,
            .profile = resolved_profile,
            .provider_name = self.provider.name,
            .model_name = self.model_name,
            .settings = self.settings,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        var prepared = value;
        const extra = try prepareExtraBody(allocator, value.settings.extra_body, self.routing);
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .openrouter = body };
        var delegate = self.compatibilityClient();
        return delegate.model().request(allocator, prepared);
    }

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        var prepared = value;
        const extra = try prepareExtraBody(allocator, value.settings.extra_body, self.routing);
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .openrouter = body };
        var delegate = self.compatibilityClient();
        return delegate.model().stream(allocator, prepared, sink);
    }

    fn compatibilityClient(self: *Client) CompatibilityClient {
        return .{
            .model_name = self.model_name,
            .provider = self.provider,
            .profile = self.profile,
            .idempotency_header = self.idempotency_header,
            .include_stream_usage = self.include_stream_usage,
            .settings = self.settings,
        };
    }
};

fn prepareExtraBody(
    allocator: std.mem.Allocator,
    raw: ?model_types.ProviderExtraBody,
    routing: ?Routing,
) !?[]u8 {
    const value = routing orelse return null;
    try value.validate();
    if (raw) |body| if (body.kind() != .openrouter) return error.InvalidRequestEncoding;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("provider");
    try writeRouting(&json, value);
    try common.writeExtraBodyFields(allocator, &json, raw, .openrouter, &.{"provider"});
    try json.endObject();
    return try output.toOwnedSlice();
}

fn writeRouting(json: *std.json.Stringify, routing: Routing) !void {
    try json.beginObject();
    if (routing.order) |value| try writeField(json, "order", value);
    if (routing.only) |value| try writeField(json, "only", value);
    if (routing.ignore) |value| try writeField(json, "ignore", value);
    if (routing.allow_fallbacks) |value| try writeField(json, "allow_fallbacks", value);
    if (routing.require_parameters) |value| try writeField(json, "require_parameters", value);
    if (routing.data_collection) |value| try writeField(json, "data_collection", @tagName(value));
    if (routing.zdr) |value| try writeField(json, "zdr", value);
    if (routing.enforce_distillable_text) |value| try writeField(json, "enforce_distillable_text", value);
    if (routing.quantizations) |value| try writeField(json, "quantizations", value);
    if (routing.sort) |value| {
        try json.objectField("sort");
        switch (value) {
            .by => |by| try json.write(@tagName(by)),
            .partitioned => |sort| try json.write(.{
                .by = @tagName(sort.by),
                .partition = @tagName(sort.partition),
            }),
        }
    }
    if (routing.preferred_min_throughput) |value| try writeThreshold(json, "preferred_min_throughput", value);
    if (routing.preferred_max_latency) |value| try writeThreshold(json, "preferred_max_latency", value);
    if (routing.max_price) |value| {
        try json.objectField("max_price");
        try json.beginObject();
        if (value.prompt) |number| try writeField(json, "prompt", number);
        if (value.completion) |number| try writeField(json, "completion", number);
        if (value.image) |number| try writeField(json, "image", number);
        if (value.request) |number| try writeField(json, "request", number);
        try json.endObject();
    }
    try json.endObject();
}

fn writeThreshold(json: *std.json.Stringify, name: []const u8, threshold: Routing.Threshold) !void {
    try json.objectField(name);
    switch (threshold) {
        .value => |value| try json.write(value),
        .percentiles => |value| {
            try json.beginObject();
            if (value.p50) |number| try writeField(json, "p50", number);
            if (value.p75) |number| try writeField(json, "p75", number);
            if (value.p90) |number| try writeField(json, "p90", number);
            if (value.p99) |number| try writeField(json, "p99", number);
            try json.endObject();
        },
    }
}

fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn validateNames(names: ?[]const []const u8) error{InvalidRequestEncoding}!void {
    const values = names orelse return;
    if (values.len == 0) return error.InvalidRequestEncoding;
    for (values, 0..) |name, index| {
        if (name.len == 0) return error.InvalidRequestEncoding;
        for (values[0..index]) |earlier| if (std.mem.eql(u8, name, earlier)) return error.InvalidRequestEncoding;
    }
}

fn validateThreshold(threshold: Routing.Threshold) error{InvalidRequestEncoding}!void {
    switch (threshold) {
        .value => |value| try validateNumber(value),
        .percentiles => |values| {
            try validateOptionalNumber(values.p50);
            try validateOptionalNumber(values.p75);
            try validateOptionalNumber(values.p90);
            try validateOptionalNumber(values.p99);
            if (values.p50 == null and values.p75 == null and values.p90 == null and values.p99 == null)
                return error.InvalidRequestEncoding;
        },
    }
}

fn validateOptionalNumber(value: ?f64) error{InvalidRequestEncoding}!void {
    if (value) |number| try validateNumber(number);
}

fn validateNumber(value: f64) error{InvalidRequestEncoding}!void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidRequestEncoding;
}

test "OpenRouter client isolates typed routing from Chat Completions" {
    const transport = @import("../transport.zig");
    const State = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"order\":[\"anthropic\",\"openai\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"only\":[\"anthropic\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"ignore\":[\"openai\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"allow_fallbacks\":false") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"require_parameters\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"data_collection\":\"deny\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"zdr\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"enforce_distillable_text\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"quantizations\":[\"int8\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"sort\":{\"by\":\"throughput\",\"partition\":\"none\"}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"preferred_min_throughput\":12.5") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"preferred_max_latency\":{\"p50\":1,\"p75\":2,\"p90\":3,\"p99\":4}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"max_price\":{\"prompt\":0.1,\"completion\":0.2,\"image\":0.3,\"request\":0.4}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"transforms\":[\"middle-out\"]") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"pong\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"),
            };
        }
    };
    var state: State = .{};
    var provider = Provider.init("secret", .{ .context = &state, .sendFn = State.send });
    var client = Client{
        .model_name = "openai/gpt-4o-mini",
        .provider = provider.provider(),
        .routing = .{
            .order = &.{ "anthropic", "openai" },
            .only = &.{"anthropic"},
            .ignore = &.{"openai"},
            .allow_fallbacks = false,
            .require_parameters = true,
            .data_collection = .deny,
            .zdr = true,
            .enforce_distillable_text = true,
            .quantizations = &.{"int8"},
            .sort = .{ .partitioned = .{ .by = .throughput, .partition = .none } },
            .preferred_min_throughput = .{ .value = 12.5 },
            .preferred_max_latency = .{ .percentiles = .{ .p50 = 1, .p75 = 2, .p90 = 3, .p99 = 4 } },
            .max_price = .{ .prompt = 0.1, .completion = 0.2, .image = 0.3, .request = 0.4 },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
        .settings = .{ .extra_body = .{ .openrouter = "{\"transforms\":[\"middle-out\"]}" } },
    });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(model_types.ExtraBodyKind.openrouter, client.model().profile.extra_body_kind.?);
}

test "OpenRouter routing supports simple sorting and streaming" {
    const transport = @import("../transport.zig");
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"provider\":{\"sort\":\"price\"}") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"raw\"}}],\"usage\":null}"),
            };
        }

        fn stream(_: *anyopaque, _: std.mem.Allocator, request: transport.Request, sink: transport.LineSink) !transport.StreamResponse {
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"stream\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"provider\":{\"sort\":\"price\"}") != null);
            try sink.start(.{ .status = 200 });
            try sink.line("data: {\"choices\":[{\"delta\":{\"content\":\"streamed\"},\"finish_reason\":null}]}");
            try sink.line("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}");
            try sink.line("data: [DONE]");
            return .{ .status = 200 };
        }
    };
    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, _: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{ .context = &marker, .sendFn = State.send, .streamLinesFn = State.stream });
    var client = Client{
        .model_name = "openai/gpt-4o-mini",
        .provider = provider.provider(),
        .routing = .{ .sort = .{ .by = .price } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = try client.model().request(arena.allocator(), .{ .messages = &.{} });
    try std.testing.expectEqualStrings("raw", raw.parts[0].text);
    var sink: Sink = .{};
    const response = try client.model().stream(arena.allocator(), .{ .messages = &.{} }, .{
        .context = &sink,
        .eventFn = Sink.emit,
    });
    try std.testing.expectEqualStrings("streamed", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 4), sink.events);
}

test "OpenRouter routing rejects invalid policies before transport" {
    const invalid_names = [_]Routing{
        .{ .order = &.{} },
        .{ .only = &.{""} },
        .{ .ignore = &.{ "a", "a" } },
        .{ .only = &.{"a"}, .ignore = &.{"a"} },
        .{ .quantizations = &.{} },
    };
    for (invalid_names) |routing| try std.testing.expectError(error.InvalidRequestEncoding, routing.validate());
    const invalid_numbers = [_]Routing{
        .{ .preferred_min_throughput = .{ .value = -1 } },
        .{ .preferred_max_latency = .{ .value = std.math.nan(f64) } },
        .{ .preferred_min_throughput = .{ .percentiles = .{} } },
        .{ .preferred_max_latency = .{ .percentiles = .{ .p50 = -1 } } },
        .{ .max_price = .{} },
        .{ .max_price = .{ .prompt = std.math.inf(f64) } },
    };
    for (invalid_numbers) |routing| try std.testing.expectError(error.InvalidRequestEncoding, routing.validate());

    const empty = try prepareExtraBody(std.testing.allocator, null, .{});
    defer std.testing.allocator.free(empty.?);
    try std.testing.expectEqualStrings("{\"provider\":{}}", empty.?);
    try std.testing.expectEqual(@as(?[]u8, null), try prepareExtraBody(std.testing.allocator, null, null));
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(std.testing.allocator, .{ .openai_compatible = "{}" }, .{}),
    );
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(std.testing.allocator, .{ .openrouter = "{\"provider\":{}}" }, .{}),
    );
}
