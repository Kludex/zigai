//! Mistral AI adapters.
//!
//! Chat Completions remains the compatibility surface. Native Conversations
//! support lives behind explicit names because its entries, built-in tools,
//! and persistent sessions have a different wire contract.

pub const chat = @import("chat.zig");
pub const conversations = @import("conversations.zig");
pub const session = @import("session.zig");

pub const api_base = chat.api_base;
pub const api_key_env = chat.api_key_env;

/// OpenAI-compatible Mistral Chat Completions provider.
pub const ChatProvider = chat.Provider;
/// OpenAI-compatible Mistral Chat Completions client.
pub const ChatClient = chat.Client;

/// Backwards-compatible alias for `ChatProvider`.
pub const Provider = ChatProvider;
/// Backwards-compatible alias for `ChatClient`.
pub const Client = ChatClient;

/// Native Mistral Conversations provider.
pub const ConversationsProvider = conversations.Provider;
/// Stateless native Mistral Conversations model adapter.
pub const ConversationsClient = conversations.Client;
pub const ConversationsError = conversations.Error;
pub const ManagedTool = conversations.ManagedTool;
pub const ToolConfiguration = conversations.ToolConfiguration;
pub const ConnectorAuthorization = conversations.ConnectorAuthorization;
pub const Session = session.Session;
pub const ConversationHistory = session.History;
pub const ConversationEntry = session.Entry;
pub const ConversationEntryKind = session.EntryKind;

test {
    _ = chat;
    _ = conversations;
    _ = session;
}
