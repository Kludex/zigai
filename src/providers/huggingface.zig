//! Hugging Face Inference Providers router client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://router.huggingface.co/v1";
pub const api_key_env = "HF_TOKEN";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "huggingface",
});
