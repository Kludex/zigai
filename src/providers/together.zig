//! Together AI client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.together.xyz/v1";
pub const api_key_env = "TOGETHER_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "together",
});
