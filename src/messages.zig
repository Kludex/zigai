//! Provider-neutral conversation messages.
//!
//! These types describe durable agent history, not a provider's wire format.
//! Provider adapters translate them only at the model boundary. All slices are
//! borrowed unless an enclosing owned result or history value says otherwise.

const std = @import("std");

/// A function-tool call produced by a model.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    /// Provider reasoning state that must accompany this call in later turns.
    thought_signature: ?[]const u8 = null,
};

/// A function-tool result returned to a model.
pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// Application metadata retained in message history but never interpreted by
/// provider adapters.
pub const Metadata = struct {
    key: []const u8,
    value: []const u8,
};

/// A file already owned by a provider.
pub const ProviderFile = struct {
    /// Provider file identifier or URI.
    id: []const u8,
    /// Optional provider guard. When set, another provider must reject it.
    provider: ?[]const u8 = null,
};

/// Storage used by rich content before a provider adapter encodes it.
pub const ContentSource = union(enum) {
    bytes: []const u8,
    url: []const u8,
    provider_file: ProviderFile,
};

/// Rich content with a semantic kind supplied by its enclosing part tag.
pub const Content = struct {
    source: ContentSource,
    media_type: []const u8,
    filename: ?[]const u8 = null,
    /// Opaque provider reasoning state attached to generated media.
    thought_signature: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
};

/// Model reasoning retained for providers that require it on the next turn.
/// Applications should treat signatures as opaque.
pub const Thinking = struct {
    content: []const u8,
    signature: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
};

/// Content supplied by an application in a user prompt.
pub const UserContent = union(enum) {
    text: []const u8,
    image: Content,
    audio: Content,
    document: Content,
    binary: Content,
};

/// One part of a request sent to a model.
pub const RequestPart = union(enum) {
    system_prompt: []const u8,
    user_prompt: UserContent,
    tool_return: ToolResult,
    retry_prompt: []const u8,
};

/// One part returned by a model.
pub const ResponsePart = union(enum) {
    text: []const u8,
    image: Content,
    audio: Content,
    document: Content,
    binary: Content,
    thinking: Thinking,
    tool_call: ToolCall,
};

/// Lifecycle state of a request captured in history.
pub const RequestState = enum {
    complete,
    interrupted,
};

/// Token usage reported by a provider.
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
    }

    pub fn totalTokens(self: Usage) u64 {
        return self.input_tokens + self.output_tokens;
    }
};

/// Why a provider ended generation, normalized without discarding its raw value.
pub const FinishReason = struct {
    kind: Kind,
    raw: []const u8,

    pub const Kind = enum {
        stop,
        tool_calls,
        length,
        content_filter,
        incomplete_tool_call,
        other,
    };
};

/// An application request recorded in provider-neutral message history.
pub const RequestMessage = struct {
    parts: []const RequestPart,
    timestamp_unix_ms: ?i64 = null,
    /// Rendered instructions used for the run that created this request.
    instructions: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    conversation_id: ?[]const u8 = null,
    /// Application metadata retained in history and never sent to providers.
    metadata: []const Metadata = &.{},
    state: RequestState = .complete,
};

/// A provider response recorded in provider-neutral message history.
pub const ResponseMessage = struct {
    parts: []const ResponsePart,
    usage: Usage = .{},
    timestamp_unix_ms: ?i64 = null,
    provider_name: ?[]const u8 = null,
    provider_url: ?[]const u8 = null,
    /// Raw JSON for provider data that must survive a history round trip.
    provider_details_json: ?[]const u8 = null,
    provider_response_id: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    run_id: ?[]const u8 = null,
    conversation_id: ?[]const u8 = null,
    /// Application metadata retained in history and never sent to providers.
    metadata: []const Metadata = &.{},
};

/// A request or response in reusable provider-neutral history.
pub const Message = union(enum) {
    request: RequestMessage,
    response: ResponseMessage,
};

/// Compatibility name for model response parts.
pub const Part = ResponsePart;

/// Rich content accepted by `Agent.RunOptions.prompt_parts`.
pub const PromptPart = UserContent;

test "usage accumulates provider totals" {
    var usage = Usage{ .input_tokens = 3, .output_tokens = 5 };
    usage.add(.{ .input_tokens = 7, .output_tokens = 11 });

    try std.testing.expectEqual(@as(u64, 10), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 16), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 26), usage.totalTokens());
}
