//! Groq client.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://api.groq.com/openai/v1";
pub const api_key_env = "GROQ_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "groq",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.groq,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
