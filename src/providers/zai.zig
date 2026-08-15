//! Z.AI client through its OpenAI-compatible Chat Completions API.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const common = @import("common.zig");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://api.z.ai/api/paas/v4";
pub const api_key_env = "ZAI_API_KEY";

const compatibility_defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "zai",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.zAI,
};

const native_defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "zai",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.zAI,
    .extra_body_kind = .zai,
    .thinking_field = "reasoning_content",
};

pub const Provider = compatible.ProviderWithDefaults(compatibility_defaults);
pub const CompatibilityClient = compatible.ClientWithDefaults(compatibility_defaults);
const WireClient = compatible.ClientWithDefaults(native_defaults);

/// Z.AI deep-thinking request control.
pub const Thinking = struct {
    mode: Mode = .enabled,

    pub const Mode = enum { enabled, disabled };
};

/// Z.AI-specific client with typed thinking controls and automatic
/// `reasoning_content` preservation through the compatibility codec.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    profile: model_types.ModelProfile = native_defaults.profile,
    idempotency_header: ?[]const u8 = null,
    include_stream_usage: bool = native_defaults.include_stream_usage,
    settings: model_types.ModelSettings = .{},
    thinking: ?Thinking = null,
    clear_thinking: ?bool = null,

    pub fn model(self: *Client) model_types.Model {
        var resolved_profile = self.provider.modelProfile(self.model_name, self.profile);
        resolved_profile.supports_idempotency_key = self.idempotency_header != null;
        resolved_profile.extra_body_kind = .zai;
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
        try self.validateThinking();
        var prepared = value;
        const extra = try prepareExtraBody(
            allocator,
            value.settings.extra_body,
            self.thinking,
            self.clear_thinking,
        );
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .zai = body };
        var delegate = self.wireClient();
        return delegate.model().request(allocator, prepared);
    }

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        try self.validateThinking();
        var prepared = value;
        const extra = try prepareExtraBody(
            allocator,
            value.settings.extra_body,
            self.thinking,
            self.clear_thinking,
        );
        defer if (extra) |body| allocator.free(body);
        if (extra) |body| prepared.settings.extra_body = .{ .zai = body };
        var delegate = self.wireClient();
        return delegate.model().stream(allocator, prepared, sink);
    }

    fn validateThinking(self: *Client) !void {
        if (self.thinking == null and self.clear_thinking == null) return;
        if (!self.model().profile.supports_thinking) return error.InvalidRequestEncoding;
    }

    fn wireClient(self: *Client) WireClient {
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
    thinking: ?Thinking,
    clear_thinking: ?bool,
) !?[]u8 {
    if (thinking == null and clear_thinking == null and raw == null) return null;
    if (raw) |body| if (body.kind() != .zai) return error.InvalidRequestEncoding;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    if (thinking) |value| {
        try json.objectField("thinking");
        try json.write(.{ .type = @tagName(value.mode) });
    }
    if (clear_thinking) |value| {
        try json.objectField("clear_thinking");
        try json.write(value);
    }
    try common.writeExtraBodyFields(
        allocator,
        &json,
        raw,
        .zai,
        &.{ "thinking", "clear_thinking" },
    );
    try json.endObject();
    return try output.toOwnedSlice();
}

test "Z.AI client preserves buffered reasoning across a tool turn" {
    const transport = @import("../transport.zig");
    const State = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("https://api.z.ai/api/paas/v4/chat/completions", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"thinking\":{\"type\":\"enabled\"}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"clear_thinking\":false") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"safe_extension\":true") != null);
            if (self.calls == 1) return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"private thought\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":null}",
                ),
            };
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"reasoning_content\":\"private thought\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"tool_call_id\":\"call_1\"") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"choices\":[{\"message\":{\"content\":\"pong\",\"reasoning_content\":null},\"finish_reason\":\"stop\"}],\"usage\":null}",
                ),
            };
        }
    };
    var state: State = .{};
    var provider = Provider.init("secret", .{ .context = &state, .sendFn = State.send });
    var client = Client{
        .model_name = "glm-5.1",
        .provider = provider.provider(),
        .thinking = .{},
        .clear_thinking = false,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
        .settings = .{ .extra_body = .{ .zai = "{\"safe_extension\":true}" } },
    });
    try std.testing.expectEqual(@as(usize, 2), first.parts.len);
    try std.testing.expectEqualStrings("private thought", first.parts[0].thinking.content);
    try std.testing.expectEqualStrings("zai", first.parts[0].thinking.provider.provider_name.?);
    const second = try client.model().request(arena.allocator(), .{
        .messages = &.{
            .{ .response = first },
            .{ .request = .{ .parts = &.{.{ .tool_return = .{
                .call_id = "call_1",
                .name = "lookup",
                .content = "ok",
            } }} } },
        },
        .settings = .{ .extra_body = .{ .zai = "{\"safe_extension\":true}" } },
    });
    try std.testing.expectEqualStrings("pong", second.parts[0].text);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqual(model_types.ExtraBodyKind.zai, client.model().profile.extra_body_kind.?);
}

test "Z.AI client streams thinking before visible text" {
    const transport = @import("../transport.zig");
    const State = struct {
        streams: usize = 0,

        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            return error.UnexpectedRequest;
        }

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            request: transport.Request,
            sink: transport.LineSink,
        ) !transport.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streams += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"thinking\":{\"type\":\"disabled\"}") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"clear_thinking\":true") != null);
            try sink.start(.{ .status = 200 });
            if (self.streams == 1) {
                try sink.line("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private \"},\"finish_reason\":null}]}");
                try sink.line("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thought\"},\"finish_reason\":null}]}");
                try sink.line("data: {\"choices\":[{\"delta\":{\"content\":\"visible\"},\"finish_reason\":null}]}");
            } else {
                try sink.line("data: {\"choices\":[{\"delta\":{\"content\":\"visible\"},\"finish_reason\":null}]}");
                try sink.line("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private \"},\"finish_reason\":null}]}");
                try sink.line("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thought\"},\"finish_reason\":null}]}");
            }
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
    var state: State = .{};
    const streaming_transport = transport.Transport{
        .context = &state,
        .sendFn = State.send,
        .streamLinesFn = State.stream,
    };
    try std.testing.expectError(error.UnexpectedRequest, streaming_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    var provider = Provider.init("secret", streaming_transport);
    var client = Client{
        .model_name = "glm-4.7",
        .provider = provider.provider(),
        .thinking = .{ .mode = .disabled },
        .clear_thinking = true,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sink: Sink = .{};
    const response = try client.model().stream(arena.allocator(), .{ .messages = &.{} }, .{
        .context = &sink,
        .eventFn = Sink.emit,
    });
    try std.testing.expectEqual(@as(usize, 2), response.parts.len);
    try std.testing.expectEqualStrings("private thought", response.parts[0].thinking.content);
    try std.testing.expectEqualStrings("visible", response.parts[1].text);
    try std.testing.expectEqual(@as(usize, 7), sink.events);

    const reversed = try client.model().stream(arena.allocator(), .{ .messages = &.{} }, .{
        .context = &sink,
        .eventFn = Sink.emit,
    });
    try std.testing.expectEqual(@as(usize, 2), reversed.parts.len);
    try std.testing.expectEqualStrings("visible", reversed.parts[0].text);
    try std.testing.expectEqualStrings("private thought", reversed.parts[1].thinking.content);
    try std.testing.expectEqual(@as(usize, 14), sink.events);
    try std.testing.expectEqual(@as(usize, 2), state.streams);
}

test "Z.AI client rejects malformed buffered reasoning" {
    const transport = @import("../transport.zig");
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: transport.Request) !transport.Response {
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":true},\"finish_reason\":\"stop\"}],\"usage\":null}",
                ),
            };
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{ .context = &marker, .sendFn = Stub.send });
    var client = Client{ .model_name = "glm-5.1", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.ProviderResponseDecodeError,
        client.model().request(arena.allocator(), .{ .messages = &.{} }),
    );
}

test "Z.AI thinking controls reject invalid compatibility paths before transport" {
    const transport = @import("../transport.zig");
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.UnexpectedRequest;
        }
    };
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try prepareExtraBody(std.testing.allocator, null, null, null),
    );
    const clear_only = try prepareExtraBody(std.testing.allocator, null, null, false);
    defer std.testing.allocator.free(clear_only.?);
    try std.testing.expectEqualStrings("{\"clear_thinking\":false}", clear_only.?);
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(std.testing.allocator, .{ .openai_compatible = "{}" }, .{}, null),
    );
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(
            std.testing.allocator,
            .{ .zai = "{\"thinking\":{\"type\":\"disabled\"}}" },
            .{},
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        prepareExtraBody(
            std.testing.allocator,
            .{ .zai = "{\"clear_thinking\":true}" },
            null,
            null,
        ),
    );

    var stub: Stub = .{};
    const counting_transport = transport.Transport{ .context = &stub, .sendFn = Stub.send };
    try std.testing.expectError(error.UnexpectedRequest, counting_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    stub.calls = 0;
    var provider = Provider.init("secret", counting_transport);
    var compatibility = CompatibilityClient{
        .model_name = "glm-5.1",
        .provider = provider.provider(),
    };
    try std.testing.expectEqual(
        model_types.ExtraBodyKind.openai_compatible,
        compatibility.model().profile.extra_body_kind.?,
    );
    try std.testing.expectError(error.InvalidRequestEncoding, compatibility.model().request(
        std.testing.allocator,
        .{ .messages = &.{.{ .response = .{ .parts = &.{.{ .thinking = .{
            .content = "thought",
        } }} } }} },
    ));
    var plain = Client{ .model_name = "glm-5.1", .provider = provider.provider() };
    try plain.validateThinking();
    var unsupported = Client{
        .model_name = "glm-4-32b",
        .provider = provider.provider(),
        .thinking = .{},
    };
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        unsupported.model().request(std.testing.allocator, .{ .messages = &.{} }),
    );
    var invalid_replay = Client{ .model_name = "glm-5.1", .provider = provider.provider() };
    try std.testing.expectError(error.InvalidRequestEncoding, invalid_replay.model().request(
        std.testing.allocator,
        .{ .messages = &.{.{ .response = .{ .parts = &.{.{ .thinking = .{
            .content = "thought",
            .signature = "unsupported",
        } }} } }} },
    ));
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
}
