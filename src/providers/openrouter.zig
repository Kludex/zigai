//! OpenRouter client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://openrouter.ai/api/v1";
pub const api_key_env = "OPENROUTER_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "openrouter",
});
