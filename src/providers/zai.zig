//! Z.AI client through its OpenAI-compatible Chat Completions API.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://api.z.ai/api/paas/v4";
pub const api_key_env = "ZAI_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "zai",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.zAI,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
