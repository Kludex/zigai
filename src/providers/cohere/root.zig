//! Cohere adapters.
//!
//! The existing OpenAI-compatible client remains the default surface. Native
//! Cohere v2 Chat support lives behind explicit names because its messages,
//! tools, citations, and streaming events use a different wire contract.

pub const compatibility = @import("compatibility.zig");
pub const chat = @import("chat.zig");

pub const api_base = compatibility.api_base;
pub const api_key_env = compatibility.api_key_env;
pub const native_api_base = chat.api_base;

/// Cohere's OpenAI-compatible provider.
pub const CompatibilityProvider = compatibility.Provider;
/// Cohere's OpenAI-compatible client.
pub const CompatibilityClient = compatibility.Client;

/// Backwards-compatible alias for `CompatibilityProvider`.
pub const Provider = CompatibilityProvider;
/// Backwards-compatible alias for `CompatibilityClient`.
pub const Client = CompatibilityClient;

/// Provider state for Cohere's native v2 APIs.
pub const ChatProvider = chat.Provider;
/// Native Cohere v2 Chat client.
pub const ChatClient = chat.Client;
pub const ChatError = chat.Error;

test {
    _ = compatibility;
    _ = chat;
}
