//! Cohere client using its OpenAI compatibility API.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.cohere.ai/compatibility/v1";
pub const api_key_env = "CO_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "cohere",
});
