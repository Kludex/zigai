//! First-party provider adapters.
//!
//! Providers own authentication, endpoints, and wire formats. Each client
//! exposes the provider-neutral `Model` consumed by `Agent`.

pub const openai = @import("providers/openai.zig");
pub const openai_compatible = @import("providers/openai_compatible.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const azure_openai = @import("providers/azure_openai.zig");
pub const bedrock = @import("providers/bedrock.zig");
pub const cerebras = @import("providers/cerebras.zig");
pub const cohere = @import("providers/cohere.zig");
pub const deepseek = @import("providers/deepseek.zig");
pub const doubleword = @import("providers/doubleword.zig");
pub const google = @import("providers/google.zig");
pub const groq = @import("providers/groq.zig");
pub const huggingface = @import("providers/huggingface.zig");
pub const mistral = @import("providers/mistral.zig");
pub const openrouter = @import("providers/openrouter.zig");
pub const ovhcloud = @import("providers/ovhcloud.zig");
pub const pydantic_gateway = @import("providers/pydantic_gateway.zig");
pub const together = @import("providers/together.zig");

test {
    _ = openai;
    _ = openai_compatible;
    _ = anthropic;
    _ = azure_openai;
    _ = bedrock;
    _ = cerebras;
    _ = cohere;
    _ = deepseek;
    _ = doubleword;
    _ = google;
    _ = groq;
    _ = huggingface;
    _ = mistral;
    _ = openrouter;
    _ = ovhcloud;
    _ = pydantic_gateway;
    _ = together;
}
