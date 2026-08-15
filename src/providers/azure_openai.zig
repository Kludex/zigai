//! Azure OpenAI v1 provider with explicit Responses and Chat clients.
//!
//! The GA v1 Responses endpoint uses the OpenAI Responses wire contract, so
//! Azure reuses that adapter while this module continues to own Azure's API
//! root, `api-key` authentication, and deployment capability profiles.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const openai = @import("openai.zig");
const profiles = @import("profiles.zig");
const transport = @import("../transport.zig");

pub const api_key_env = "AZURE_OPENAI_API_KEY";
pub const endpoint_env = "AZURE_OPENAI_ENDPOINT";

const defaults: compatible.ClientDefaults = .{
    .base_url = "",
    .provider_name = "azure-openai",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.azureOpenAI,
    .authentication = .{ .header = "api-key", .prefix = "" },
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
/// Backwards-compatible Chat Completions client.
pub const Client = compatible.ClientWithDefaults(defaults);
pub const ChatClient = Client;
/// Native Azure OpenAI v1 Responses client.
pub const ResponsesClient = openai.Client;
pub const ResponsesError = openai.Error;

/// Builds the Azure v1 API base from an Azure OpenAI resource endpoint.
pub fn apiBase(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/openai/v1", .{std.mem.trimEnd(u8, endpoint, "/")});
}

test "apiBase normalizes a trailing slash" {
    const value = try apiBase(std.testing.allocator, "https://example.openai.azure.com/");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://example.openai.azure.com/openai/v1", value);
}

test "Responses client reuses the native wire contract through Azure provider state" {
    const State = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqual(transport.Method.POST, request.method);
            try std.testing.expectEqualStrings("https://example.openai.azure.com/openai/v1/responses", request.url);
            try std.testing.expect(std.mem.indexOf(u8, request.body, "\"model\":\"gpt-4.1-nano\"") != null);
            var authenticated = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "api-key") and std.mem.eql(u8, header.value, "secret"))
                    authenticated = true;
            }
            try std.testing.expect(authenticated);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"id\":\"resp_azure\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"msg_azure\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"pong\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}"),
            };
        }
    };
    var marker: u8 = 0;
    var provider = Provider.initWithOptions("secret", .{ .context = &marker, .sendFn = State.send }, .{
        .base_url = "https://example.openai.azure.com/openai/v1",
    });
    var client = ResponsesClient{
        .model_name = "gpt-4.1-nano",
        .provider = provider.provider(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
    });
    try std.testing.expectEqualStrings("azure-openai", response.provider_name.?);
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
}
