//! DeepSeek client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.deepseek.com/v1";
pub const api_key_env = "DEEPSEEK_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "deepseek",
});
