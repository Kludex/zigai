//! Doubleword client.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://api.doubleword.ai/v1";
pub const api_key_env = "DOUBLEWORD_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "doubleword",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.doubleword,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
