//! OVHcloud AI Endpoints client.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1";
pub const api_key_env = "OVHCLOUD_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "ovhcloud",
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
