//! Pydantic AI Gateway client using its OpenAI-compatible chat proxy.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const api_base = "https://gateway-us.pydantic.dev/proxy/chat";
pub const api_key_env = "PYDANTIC_AI_GATEWAY_API_KEY";

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "pydantic-ai-gateway",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.pydanticGateway,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);
