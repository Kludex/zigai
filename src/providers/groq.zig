//! Groq client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.groq.com/openai/v1";
pub const api_key_env = "GROQ_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "groq",
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
