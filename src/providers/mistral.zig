//! Mistral AI client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.mistral.ai/v1";
pub const api_key_env = "MISTRAL_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "mistral",
});
