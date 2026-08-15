//! Azure OpenAI client using the v1 Chat Completions API.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

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
pub const Client = compatible.ClientWithDefaults(defaults);

/// Builds the Azure v1 API base from an Azure OpenAI resource endpoint.
pub fn apiBase(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/openai/v1", .{std.mem.trimEnd(u8, endpoint, "/")});
}

test "apiBase normalizes a trailing slash" {
    const value = try apiBase(std.testing.allocator, "https://example.openai.azure.com/");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://example.openai.azure.com/openai/v1", value);
}
