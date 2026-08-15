//! Amazon Bedrock Mantle client using its OpenAI-compatible API.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_key_env = "AWS_BEARER_TOKEN_BEDROCK";
pub const region_env = "AWS_DEFAULT_REGION";

const defaults: compatible.ClientDefaults = .{
    .base_url = "",
    .provider_name = "bedrock",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.bedrock,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);

/// Builds the regional Bedrock Mantle v1 API base.
pub fn apiBase(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://bedrock-mantle.{s}.api.aws/v1", .{region});
}

test "apiBase includes the region" {
    const value = try apiBase(std.testing.allocator, "eu-west-1");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://bedrock-mantle.eu-west-1.api.aws/v1", value);
}
