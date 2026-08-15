//! Amazon Bedrock provider adapters.
//!
//! Mantle exposes Bedrock-hosted models through OpenAI-compatible Chat
//! Completions. Its provider and client names are explicit so native Bedrock
//! Runtime adapters can coexist without sharing wire-protocol assumptions.

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

pub const MantleProvider = compatible.ProviderWithDefaults(defaults);
pub const MantleClient = compatible.ClientWithDefaults(defaults);

/// Compatibility alias for the original Mantle-only API. New code should use
/// `MantleProvider`; `Provider` is reserved for the native Bedrock adapter.
pub const Provider = MantleProvider;

/// Compatibility alias for the original Mantle-only API. New code should use
/// `MantleClient`; `Client` is reserved for the native Bedrock adapter.
pub const Client = MantleClient;

/// Builds the regional Bedrock Mantle v1 API base.
pub fn mantleApiBase(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://bedrock-mantle.{s}.api.aws/v1", .{region});
}

/// Compatibility alias for the original Mantle-only helper. New code should
/// use `mantleApiBase`; `apiBase` is reserved for native Bedrock Runtime.
pub const apiBase = mantleApiBase;

test "mantleApiBase includes the region" {
    const value = try mantleApiBase(std.testing.allocator, "eu-west-1");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://bedrock-mantle.eu-west-1.api.aws/v1", value);
}
