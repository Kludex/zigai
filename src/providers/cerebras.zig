//! Cerebras Inference client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://api.cerebras.ai/v1";
pub const api_key_env = "CEREBRAS_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "cerebras",
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
