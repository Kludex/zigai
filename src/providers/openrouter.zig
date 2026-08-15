//! OpenRouter client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://openrouter.ai/api/v1";
pub const api_key_env = "OPENROUTER_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "openrouter",
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
