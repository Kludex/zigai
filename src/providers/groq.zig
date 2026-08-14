//! Groq client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.groq.com/openai/v1";
pub const api_key_env = "GROQ_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "groq",
});
