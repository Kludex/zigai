//! xAI provider with native Responses and explicit Chat Completions clients.
//!
//! The native client shares the Responses envelope with OpenAI while keeping
//! xAI's tool vocabulary and extension body isolated behind its own dialect.

const std = @import("std");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");
const compatible = @import("openai_compatible.zig");
const openai = @import("openai.zig");
const provider_profiles = @import("profiles.zig");

pub const api_base = "https://api.x.ai/v1";
pub const api_key_env = "XAI_API_KEY";
pub const Error = openai.Error;

const responses_defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "xai",
    .profile = .{},
    .model_profile_lookup = provider_profiles.xAIResponses,
};

const chat_defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "xai",
    .profile = provider_profiles.openai_compatible.unknown,
    .model_profile_lookup = provider_profiles.xAIChat,
};

/// Provider state for xAI's native Responses API.
pub const Provider = compatible.ProviderWithDefaults(responses_defaults);
/// Provider state for xAI's OpenAI-compatible Chat Completions API.
pub const ChatProvider = compatible.ProviderWithDefaults(chat_defaults);
/// Explicit compatibility client. Prefer `Client` for xAI-managed tools.
pub const ChatClient = compatible.ClientWithDefaults(chat_defaults);

/// Native xAI Responses client.
pub const Client = struct {
    model_name: []const u8,
    provider: provider_types.Provider,
    settings: model_types.ModelSettings = .{},
    profile: model_types.ModelProfile = .{},

    pub fn model(self: *Client) model_types.Model {
        var resolved_profile = self.provider.modelProfile(self.model_name, self.profile);
        resolved_profile.extra_body_kind = .xai;
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
        var client = openai.Client{
            .model_name = self.model_name,
            .provider = self.provider,
            .dialect = .xai,
            .extra_body_kind = .xai,
        };
        return client.model().request(allocator, value);
    }

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        var client = openai.Client{
            .model_name = self.model_name,
            .provider = self.provider,
            .dialect = .xai,
            .extra_body_kind = .xai,
        };
        return client.model().stream(allocator, value, sink);
    }
};

test "native client owns the xAI Responses dialect" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqual(transport.Method.POST, request.method);
            try std.testing.expectEqualStrings("https://api.x.ai/v1/responses", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"type\":\"x_search\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"type\":\"code_interpreter\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"allowed_domains\":[\"x.ai\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"enable_image_search\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"allowed_x_handles\":[\"xai\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"from_date\":\"2026-01-01\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"enable_video_understanding\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"vector_store_ids\":[\"collection_1\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"max_num_results\":10") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"server_label\":\"docs\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"server_description\":\"Documentation\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"allowed_tools\":[\"search\"]") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"authorization\":\"test-token\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"x-scope\":\"read\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"xai_extension\":true") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"pong\"}]}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}"),
            };
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{ .context = &marker, .sendFn = State.send });
    var client = Client{ .model_name = "grok-4.6", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
        .builtin_tools = &.{
            .{ .web_search = .{
                .allowed_domains = &.{"x.ai"},
                .enable_image_understanding = false,
                .enable_image_search = true,
            } },
            .{ .x_search = .{
                .allowed_x_handles = &.{"xai"},
                .from_date = "2026-01-01",
                .to_date = "2026-08-15",
                .enable_image_understanding = true,
                .enable_video_understanding = true,
            } },
            .{ .code_execution = .{} },
            .{ .file_search = .{ .vector_store_ids = &.{"collection_1"}, .max_num_results = 10 } },
            .{ .remote_mcp = .{
                .server_url = "https://mcp.example.test",
                .server_label = "docs",
                .server_description = "Documentation",
                .allowed_tools = &.{"search"},
                .authorization = "test-token",
                .headers = &.{.{ .name = "x-scope", .value = "read", .sensitive = true }},
            } },
        },
        .settings = .{ .extra_body = .{ .xai = "{\"xai_extension\":true}" } },
    });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expect(client.model().profile.supportsBuiltinTool(.remote_mcp));
    try std.testing.expectEqual(model_types.ExtraBodyKind.xai, client.model().profile.extra_body_kind.?);
}

test "native xAI tools reject malformed provider configuration before transport" {
    const State = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            return error.UnexpectedRequest;
        }
    };
    var marker: u8 = 0;
    var provider = Provider.init("secret", .{ .context = &marker, .sendFn = State.send });
    var client = Client{ .model_name = "grok-4.6", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const invalid = [_]model_types.BuiltinTool{
        .{ .web_search = .{ .allowed_domains = &.{"x.ai"}, .excluded_domains = &.{"example.com"} } },
        .{ .web_search = .{ .allowed_domains = &.{ "1", "2", "3", "4", "5", "6" } } },
        .{ .web_search = .{ .allowed_domains = &.{""} } },
        .{ .x_search = .{ .allowed_x_handles = &.{"xai"}, .excluded_x_handles = &.{"grok"} } },
        .{ .x_search = .{ .allowed_x_handles = &.{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21" } } },
        .{ .x_search = .{ .from_date = "2026-1-01" } },
        .{ .x_search = .{ .from_date = "2026-13-01" } },
        .{ .x_search = .{ .from_date = "2026-01-32" } },
        .{ .x_search = .{ .from_date = "2026-0a-01" } },
        .{ .x_search = .{ .from_date = "2026-08-15", .to_date = "2026-01-01" } },
        .{ .file_search = .{ .vector_store_ids = &.{} } },
        .{ .file_search = .{ .vector_store_ids = &.{"collection"}, .max_num_results = 0 } },
        .{ .remote_mcp = .{ .server_url = "http://mcp.example.test", .server_label = "docs" } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "" } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .allowed_tools = &.{""} } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .authorization = "" } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .headers = &.{.{ .name = "", .value = "x" }} } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .headers = &.{.{ .name = "x", .value = "" }} } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .headers = &.{.{ .name = "x\nname", .value = "x" }} } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .headers = &.{.{ .name = "x", .value = "bad\rvalue" }} } },
        .{ .remote_mcp = .{ .server_url = "https://mcp.example.test", .server_label = "docs", .headers = &.{ .{ .name = "X-Test", .value = "one" }, .{ .name = "x-test", .value = "two" } } } },
    };
    for (invalid) |tool| try std.testing.expectError(
        error.InvalidRequestEncoding,
        client.model().request(arena.allocator(), .{ .messages = &.{}, .builtin_tools = &.{tool} }),
    );
}

test "Chat compatibility is explicit and has a separate profile" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqualStrings("https://api.x.ai/v1/chat/completions", request.url);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"),
            };
        }
    };
    var marker: u8 = 0;
    var provider = ChatProvider.init("secret", .{ .context = &marker, .sendFn = State.send });
    var client = ChatClient{ .model_name = "grok-4.6", .provider = provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{ .messages = &.{} });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expect(!client.model().profile.supportsBuiltinTool(.x_search));
}
