//! Snowflake Cortex client through its OpenAI-compatible Chat Completions API.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const common = @import("common.zig");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const profiles = @import("profiles.zig");

pub const account_env = "SNOWFLAKE_ACCOUNT";
pub const token_env = "SNOWFLAKE_TOKEN";

pub const Error = error{
    InvalidSnowflakeAccount,
};

const defaults: compatible.ClientDefaults = .{
    .base_url = "",
    .provider_name = "snowflake",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.snowflake,
    .extra_body_kind = .snowflake,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const CompatibilityClient = compatible.ClientWithDefaults(defaults);

/// Claude reasoning controls accepted by Snowflake Cortex. Exactly one field
/// must be set. Cortex requires request temperature `1` when this is present.
pub const Reasoning = struct {
    effort: ?Effort = null,
    max_tokens: ?u64 = null,

    pub const Effort = enum { low, medium, high };

    pub fn validate(self: Reasoning) error{InvalidRequestEncoding}!void {
        if ((self.effort == null) == (self.max_tokens == null)) return error.InvalidRequestEncoding;
        if (self.max_tokens == 0) return error.InvalidRequestEncoding;
    }
};

/// Snowflake-specific client. Chat Completions encoding stays delegated to the
/// compatibility client; only Cortex reasoning preparation lives here.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    profile: model_types.ModelProfile = defaults.profile,
    idempotency_header: ?[]const u8 = null,
    include_stream_usage: bool = defaults.include_stream_usage,
    settings: model_types.ModelSettings = .{},
    reasoning: ?Reasoning = null,

    pub fn model(self: *Client) model_types.Model {
        var resolved_profile = self.provider.modelProfile(self.model_name, self.profile);
        resolved_profile.supports_idempotency_key = self.idempotency_header != null;
        resolved_profile.extra_body_kind = .snowflake;
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

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        var prepared = try self.prepare(value);
        const extra = try prepareExtraBody(allocator, value.settings.extra_body, self.reasoning);
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .snowflake = body };
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
        var prepared = try self.prepare(value);
        const extra = try prepareExtraBody(allocator, value.settings.extra_body, self.reasoning);
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .snowflake = body };
        var delegate = self.compatibilityClient();
        return delegate.model().stream(allocator, prepared, sink);
    }

    fn prepare(self: *Client, value: model_types.ModelRequest) !model_types.ModelRequest {
        var prepared = value;
        const reasoning = self.reasoning orelse return prepared;
        try reasoning.validate();
        if (!startsWithIgnoreCase(self.model_name, "claude")) return error.InvalidRequestEncoding;
        if (prepared.settings.temperature) |temperature| {
            if (temperature != 1) return error.InvalidRequestEncoding;
        } else {
            prepared.settings.temperature = 1;
        }
        return prepared;
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
    reasoning: ?Reasoning,
) !?[]u8 {
    const value = reasoning orelse return null;
    try value.validate();
    if (raw) |body| if (body.kind() != .snowflake) return error.InvalidRequestEncoding;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("reasoning");
    try json.beginObject();
    if (value.effort) |effort| {
        try json.objectField("effort");
        try json.write(@tagName(effort));
    }
    if (value.max_tokens) |max_tokens| {
        try json.objectField("max_tokens");
        try json.write(max_tokens);
    }
    try json.endObject();
    try common.writeExtraBodyFields(allocator, &json, raw, .snowflake, &.{"reasoning"});
    try json.endObject();
    return try output.toOwnedSlice();
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Builds the Cortex `/api/v2/cortex/v1` root from a Snowflake account
/// identifier or canonical account hostname. The caller owns the result.
pub fn apiBase(allocator: std.mem.Allocator, account: []const u8) ![]u8 {
    var identifier = std.mem.trimEnd(u8, account, "/");
    if (std.mem.startsWith(u8, identifier, "https://")) identifier = identifier["https://".len..];
    if (std.mem.startsWith(u8, identifier, "http://")) return error.InvalidSnowflakeAccount;
    const suffix = ".snowflakecomputing.com";
    if (std.mem.endsWith(u8, identifier, suffix)) identifier = identifier[0 .. identifier.len - suffix.len];
    try validateAccount(identifier);
    return std.fmt.allocPrint(
        allocator,
        "https://{s}.snowflakecomputing.com/api/v2/cortex/v1",
        .{identifier},
    );
}

fn validateAccount(identifier: []const u8) Error!void {
    if (identifier.len == 0 or identifier.len > 253 or identifier[0] == '.' or
        identifier[identifier.len - 1] == '.' or std.mem.indexOf(u8, identifier, "..") != null)
    {
        return error.InvalidSnowflakeAccount;
    }
    for (identifier) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-')
            return error.InvalidSnowflakeAccount;
    }
}

test "Snowflake API base accepts identifiers and canonical account hosts" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "myorg-myaccount", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "xy12345.us-east-1", .expected = "https://xy12345.us-east-1.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "myorg-myaccount.snowflakecomputing.com", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "https://myorg-myaccount.snowflakecomputing.com/", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
    };
    for (cases) |case| {
        const value = try apiBase(std.testing.allocator, case.input);
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(case.expected, value);
    }
}

test "Snowflake API base rejects values that could select another origin" {
    const invalid = [_][]const u8{
        "",
        "http://myorg-myaccount",
        ".myaccount",
        "myaccount.",
        "myorg..myaccount",
        "myaccount/path",
        "myaccount:443",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidSnowflakeAccount, apiBase(std.testing.allocator, value));
    }
    const too_long = [_]u8{'a'} ** 254;
    try std.testing.expectError(error.InvalidSnowflakeAccount, apiBase(std.testing.allocator, &too_long));
}

test "Snowflake client adds typed Claude reasoning to buffered requests" {
    const transport = @import("../transport.zig");
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqualStrings(
                "https://account.snowflakecomputing.com/api/v2/cortex/v1/chat/completions",
                request.url,
            );
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"reasoning\":{\"effort\":\"high\"}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"temperature\":1") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"guardrails\":true") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"choices\":[{\"message\":{\"content\":\"pong\"},\"finish_reason\":\"stop\"}],\"usage\":null}",
                ),
            };
        }
    };
    var marker: u8 = 0;
    var provider = Provider.initWithOptions("secret", .{ .context = &marker, .sendFn = State.send }, .{
        .base_url = "https://account.snowflakecomputing.com/api/v2/cortex/v1",
    });
    var client = Client{
        .model_name = "claude-sonnet-4-5",
        .provider = provider.provider(),
        .reasoning = .{ .effort = .high },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
        .settings = .{ .extra_body = .{ .snowflake = "{\"guardrails\":true}" } },
    });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expectEqual(model_types.ExtraBodyKind.snowflake, client.model().profile.extra_body_kind.?);
}

test "Snowflake client applies typed reasoning to streaming requests" {
    const transport = @import("../transport.zig");
    const State = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            return error.UnexpectedRequest;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            request: transport.Request,
            sink: transport.LineSink,
        ) !transport.StreamResponse {
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"reasoning\":{\"max_tokens\":2048}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"temperature\":1") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"stream\":true") != null);
            try sink.start(.{ .status = 200 });
            try sink.line("data: {\"choices\":[{\"delta\":{\"content\":\"streamed\"},\"finish_reason\":null}]}");
            try sink.line("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}");
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
    const streaming_transport = transport.Transport{
        .context = &marker,
        .sendFn = State.send,
        .streamLinesFn = State.stream,
    };
    try std.testing.expectError(error.UnexpectedRequest, streaming_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    var provider = Provider.initWithOptions("secret", streaming_transport, .{
        .base_url = "https://account.snowflakecomputing.com/api/v2/cortex/v1",
    });
    var client = Client{
        .model_name = "CLAUDE-sonnet-4-5",
        .provider = provider.provider(),
        .reasoning = .{ .max_tokens = 2_048 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sink: Sink = .{};
    const response = try client.model().stream(arena.allocator(), .{
        .messages = &.{},
        .settings = .{ .temperature = 1 },
    }, .{ .context = &sink, .eventFn = Sink.emit });
    try std.testing.expectEqualStrings("streamed", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 3), sink.events);
}

test "Snowflake reasoning rejects invalid controls before transport" {
    const transport = @import("../transport.zig");
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.UnexpectedRequest;
        }
    };
    try std.testing.expectError(error.InvalidRequestEncoding, (Reasoning{}).validate());
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        (Reasoning{ .effort = .low, .max_tokens = 1 }).validate(),
    );
    try std.testing.expectError(error.InvalidRequestEncoding, (Reasoning{ .max_tokens = 0 }).validate());
    try std.testing.expectEqual(@as(?[]u8, null), try prepareExtraBody(std.testing.allocator, null, null));
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(std.testing.allocator, .{ .openai_compatible = "{}" }, .{ .effort = .medium }),
    );
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(
            std.testing.allocator,
            .{ .snowflake = "{\"reasoning\":{\"effort\":\"low\"}}" },
            .{ .effort = .medium },
        ),
    );

    var stub: Stub = .{};
    const counting_transport = transport.Transport{ .context = &stub, .sendFn = Stub.send };
    try std.testing.expectError(error.UnexpectedRequest, counting_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    stub.calls = 0;
    var provider = Provider.initWithOptions("secret", counting_transport, .{
        .base_url = "https://account.snowflakecomputing.com/api/v2/cortex/v1",
    });
    var non_claude = Client{
        .model_name = "openai-gpt-5",
        .provider = provider.provider(),
        .reasoning = .{ .effort = .high },
    };
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        non_claude.model().request(std.testing.allocator, .{ .messages = &.{} }),
    );
    var wrong_temperature = Client{
        .model_name = "claude-sonnet-4-5",
        .provider = provider.provider(),
        .reasoning = .{ .effort = .high },
    };
    try std.testing.expectError(error.InvalidRequestEncoding, wrong_temperature.model().request(
        std.testing.allocator,
        .{ .messages = &.{}, .settings = .{ .temperature = 0.5 } },
    ));
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
}
