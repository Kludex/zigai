//! Hugging Face Inference Providers router client.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://router.huggingface.co/v1";
pub const api_key_env = "HF_TOKEN";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "huggingface",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.huggingFace,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
