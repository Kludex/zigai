//! Pydantic AI Gateway client using its OpenAI-compatible chat proxy.

const compatible = @import("openai_compatible.zig");

pub const api_base = "https://gateway-us.pydantic.dev/proxy/chat";
pub const api_key_env = "PYDANTIC_AI_GATEWAY_API_KEY";

pub const Client = compatible.ClientWithDefaults(.{
    .base_url = api_base,
    .provider_name = "pydantic-ai-gateway",
});
