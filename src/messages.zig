//! Provider-neutral conversation messages.
//!
//! These types describe durable agent history, not a provider's wire format.
//! Provider adapters translate them only at the model boundary. All slices are
//! borrowed unless an enclosing owned result or history value says otherwise.

const std = @import("std");
const usage_types = @import("usage.zig");

/// Application metadata retained in message history but never interpreted by
/// provider adapters.
pub const Metadata = struct {
    key: []const u8,
    value: []const u8,
};

/// Provider-specific JSON retained without flattening it into application
/// metadata. The value is always an object, and its complete graph follows the
/// ownership boundary of the enclosing message.
pub const ProviderDetails = struct {
    value: std.json.Value,

    /// Wraps a parsed JSON object without allocating.
    pub fn fromValue(value: std.json.Value) error{InvalidProviderDetails}!ProviderDetails {
        if (value != .object) return error.InvalidProviderDetails;
        return .{ .value = value };
    }

    /// Writes the structured object through Zig's JSON serializer.
    pub fn jsonStringify(self: ProviderDetails, json: anytype) !void {
        try json.write(self.value);
    }
};

/// Provider-owned fields that must be replayed only through the provider that
/// produced them.
pub const ProviderPart = struct {
    /// Provider item identifier, distinct from a function tool-call ID.
    id: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    provider_details: ?ProviderDetails = null,

    /// Whether replaying this part requires provider-specific wire support.
    pub fn requiresReplay(self: ProviderPart) bool {
        return self.id != null or self.provider_details != null;
    }
};

/// A function-tool family with a stable framework-defined payload.
pub const ToolPartKind = enum {
    tool_search,
    capability_load,
};

/// A function-tool call produced by a model.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    tool_kind: ?ToolPartKind = null,
    provider: ProviderPart = .{},
    /// Provider reasoning state that must accompany this call in later turns.
    thought_signature: ?[]const u8 = null,
};

/// The observable outcome of a tool invocation.
pub const ToolOutcome = enum {
    success,
    failed,
    denied,
    interrupted,
};

/// A function-tool result returned to a model.
pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    /// Text or serialized JSON returned to the model.
    content: []const u8,
    /// Multimodal files returned alongside `content`.
    files: []const Content = &.{},
    tool_kind: ?ToolPartKind = null,
    metadata: []const Metadata = &.{},
    timestamp_unix_ms: ?i64 = null,
    /// Explicit outcome. `null` preserves the legacy `is_error` shorthand.
    outcome: ?ToolOutcome = null,
    /// Compatibility shorthand for callers written before outcomes were added.
    is_error: bool = false,

    pub fn isError(self: ToolResult) bool {
        return self.effectiveOutcome() == .failed;
    }

    pub fn effectiveOutcome(self: ToolResult) ToolOutcome {
        return self.outcome orelse if (self.is_error) .failed else .success;
    }
};

/// A file already owned by a provider.
pub const UploadedFile = struct {
    /// Provider file identifier or URI.
    id: []const u8,
    /// File IDs are not portable, so the owning provider is required.
    provider_name: []const u8,
    media_type: ?[]const u8 = null,
    metadata: []const Metadata = &.{},

    /// Views this file as generic rich content without allocating.
    pub fn asContent(self: UploadedFile) Content {
        return .{
            .source = .{ .uploaded_file = self },
            .media_type = self.media_type orelse "application/octet-stream",
        };
    }
};

/// Compatibility shape for provider files created before provider ownership
/// became mandatory. New code should use `UploadedFile`.
pub const ProviderFile = struct {
    id: []const u8,
    provider: ?[]const u8 = null,
};

/// Storage used by rich content before a provider adapter encodes it.
pub const ContentSource = union(enum) {
    bytes: []const u8,
    url: []const u8,
    uploaded_file: UploadedFile,
    /// Legacy provider-file representation retained for source compatibility.
    provider_file: ProviderFile,
};

/// Rich content with a semantic kind supplied by its enclosing part tag.
pub const Content = struct {
    source: ContentSource,
    media_type: []const u8,
    filename: ?[]const u8 = null,
    /// Stable identifier that lets a model refer to this content later.
    identifier: ?[]const u8 = null,
    provider: ProviderPart = .{},
    /// Opaque provider reasoning state attached to generated media.
    thought_signature: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
};

/// Text with application-only metadata.
pub const TextContent = struct {
    content: []const u8,
    metadata: []const Metadata = &.{},
};

/// An explicit prompt-cache boundary.
pub const CachePoint = struct {
    ttl: Ttl = .five_minutes,

    pub const Ttl = enum {
        five_minutes,
        one_hour,
    };
};

/// Model reasoning retained for providers that require it on the next turn.
/// Applications should treat signatures and provider details as opaque.
pub const Thinking = struct {
    content: []const u8,
    signature: ?[]const u8 = null,
    provider: ProviderPart = .{},
    metadata: []const Metadata = &.{},
};

/// Content supplied by an application in a user prompt.
pub const UserContent = union(enum) {
    text: []const u8,
    text_content: TextContent,
    image: Content,
    audio: Content,
    video: Content,
    document: Content,
    binary: Content,
    uploaded_file: UploadedFile,
    cache_point: CachePoint,
};

/// A system prompt and its provenance.
pub const SystemPromptPart = struct {
    content: []const u8,
    timestamp_unix_ms: ?i64 = null,
    dynamic_ref: ?[]const u8 = null,
};

/// A user prompt item and the time it was created.
pub const UserPromptPart = struct {
    content: UserContent,
    timestamp_unix_ms: ?i64 = null,
};

/// A retry request tied to an optional tool call.
pub const RetryPromptPart = struct {
    content: []const u8,
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    timestamp_unix_ms: ?i64 = null,
};

/// A single static or dynamic instruction block.
pub const InstructionPart = struct {
    content: []const u8,
    dynamic: bool = false,
};

/// A provider-native tool call. Unlike `ToolCall`, ZigAI never executes it.
pub const NativeToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    tool_kind: ?ToolPartKind = null,
    provider: ProviderPart,
};

/// A provider-native tool result returned inline with a model response.
pub const NativeToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const u8,
    files: []const Content = &.{},
    tool_kind: ?ToolPartKind = null,
    metadata: []const Metadata = &.{},
    timestamp_unix_ms: ?i64 = null,
    outcome: ToolOutcome = .success,
    provider: ProviderPart,
};

/// A model query for tools hidden from its initial tool list.
pub const ToolSearchCall = struct {
    call_id: []const u8,
    queries: []const []const u8,
    provider: ProviderPart = .{},
};

/// One tool discovered by a tool-search call.
pub const ToolSearchMatch = struct {
    name: []const u8,
};

/// Results of a local or provider-native tool search.
pub const ToolSearchResult = struct {
    call_id: []const u8,
    discovered_tools: []const ToolSearchMatch,
    message: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
    timestamp_unix_ms: ?i64 = null,
    outcome: ToolOutcome = .success,
    provider: ProviderPart = .{},
};

/// A model request to load an on-demand capability.
pub const CapabilityLoadCall = struct {
    call_id: []const u8,
    capability_id: []const u8,
};

/// The instructions contributed by a loaded capability.
pub const CapabilityLoadResult = struct {
    call_id: []const u8,
    instructions: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
    timestamp_unix_ms: ?i64 = null,
    outcome: ToolOutcome = .success,
};

/// Tools revealed to the model at this point in history.
pub const ToolAvailabilityDeltaPart = struct {
    tools_added: []const []const u8,
    tool_call_id: ?[]const u8 = null,
};

/// Spoken audio and its optional transcript.
pub const SpeechPart = struct {
    speaker: Speaker,
    transcript: ?[]const u8 = null,
    audio: ?Content = null,
    interrupted_at_ms: ?u64 = null,
    provider: ProviderPart = .{},

    pub const Speaker = enum {
        user,
        assistant,
    };
};

/// A provider-generated summary that replaces an earlier history window.
pub const CompactionPart = struct {
    content: ?[]const u8 = null,
    provider: ProviderPart = .{},
};

/// Plain model text and replay metadata.
pub const TextPart = struct {
    content: []const u8,
    provider: ProviderPart = .{},
};

/// One part of a request sent to a model.
pub const RequestPart = union(enum) {
    /// Compact prompt form without per-part metadata.
    system_prompt: []const u8,
    system_prompt_part: SystemPromptPart,
    /// Compact prompt-item form without a timestamp.
    user_prompt: UserContent,
    user_prompt_part: UserPromptPart,
    speech: SpeechPart,
    tool_search_return: ToolSearchResult,
    capability_load_return: CapabilityLoadResult,
    tool_return: ToolResult,
    /// Compact retry form not associated with a tool call.
    retry_prompt: []const u8,
    retry_prompt_part: RetryPromptPart,
    tool_availability_delta: ToolAvailabilityDeltaPart,
};

/// One part returned by a model.
pub const ResponsePart = union(enum) {
    /// Compact text form without provider replay metadata.
    text: []const u8,
    text_part: TextPart,
    tool_search_call: ToolSearchCall,
    capability_load_call: CapabilityLoadCall,
    tool_call: ToolCall,
    native_tool_search_call: ToolSearchCall,
    native_tool_call: NativeToolCall,
    native_tool_search_return: ToolSearchResult,
    native_tool_return: NativeToolResult,
    thinking: Thinking,
    compaction: CompactionPart,
    image: Content,
    audio: Content,
    video: Content,
    document: Content,
    binary: Content,
    speech: SpeechPart,
};

/// Lifecycle state of a request captured in history.
pub const RequestState = enum {
    complete,
    interrupted,
};

/// Lifecycle state of a response captured in history.
pub const ResponseState = enum {
    complete,
    incomplete,
    suspended,
    interrupted,
};

pub const Usage = usage_types.RequestUsage;
pub const RequestUsage = usage_types.RequestUsage;
pub const UsageDetail = usage_types.Detail;
pub const UsageCost = usage_types.Cost;

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
    /// Structured instructions used to render `instructions`.
    instruction_parts: []const InstructionPart = &.{},
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
    /// Structured provider data that must survive a history round trip.
    provider_details: ?ProviderDetails = null,
    provider_response_id: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    run_id: ?[]const u8 = null,
    conversation_id: ?[]const u8 = null,
    /// Application metadata retained in history and never sent to providers.
    metadata: []const Metadata = &.{},
    state: ResponseState = .complete,
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

/// PydanticAI name for a durable request or response message.
pub const ModelMessage = Message;
/// PydanticAI name for request-part vocabulary.
pub const ModelRequestPart = RequestPart;
/// PydanticAI name for response-part vocabulary.
pub const ModelResponsePart = ResponsePart;
/// PydanticAI name for a function-tool return.
pub const ToolReturnPart = ToolResult;
/// PydanticAI compatibility name for a provider-native tool call.
pub const BuiltinToolCallPart = NativeToolCall;
/// PydanticAI compatibility name for a provider-native tool return.
pub const BuiltinToolReturnPart = NativeToolResult;
/// PydanticAI name for generated file content.
pub const FilePart = Content;
/// PydanticAI name for model reasoning.
pub const ThinkingPart = Thinking;
/// PydanticAI name for a local tool-search return.
pub const ToolSearchReturnPart = ToolSearchResult;
/// PydanticAI name for an on-demand capability-load call.
pub const LoadCapabilityCallPart = CapabilityLoadCall;
/// PydanticAI name for an on-demand capability-load return.
pub const LoadCapabilityReturnPart = CapabilityLoadResult;

/// Deep-copies canonical messages and every nested borrowed value into
/// `arena`. The returned slice remains valid until that arena is released.
pub fn dupeMessages(arena: std.mem.Allocator, source: []const Message) std.mem.Allocator.Error![]const Message {
    const copied = try arena.alloc(Message, source.len);
    for (source, copied) |message, *target| target.* = try dupeMessage(arena, message);
    return copied;
}

/// Deep-copies one canonical message into `arena`.
pub fn dupeMessage(arena: std.mem.Allocator, message: Message) std.mem.Allocator.Error!Message {
    return switch (message) {
        .request => |request| .{ .request = try dupeRequestMessage(arena, request) },
        .response => |response| .{ .response = try dupeResponseMessage(arena, response) },
    };
}

/// Deep-copies one request message and all nested parts into `arena`.
pub fn dupeRequestMessage(
    arena: std.mem.Allocator,
    request: RequestMessage,
) std.mem.Allocator.Error!RequestMessage {
    const parts = try arena.alloc(RequestPart, request.parts.len);
    for (request.parts, parts) |part, *target| target.* = try dupeRequestPart(arena, part);
    const instruction_parts = try arena.alloc(InstructionPart, request.instruction_parts.len);
    for (request.instruction_parts, instruction_parts) |part, *target| target.* = .{
        .content = try arena.dupe(u8, part.content),
        .dynamic = part.dynamic,
    };
    return .{
        .parts = parts,
        .timestamp_unix_ms = request.timestamp_unix_ms,
        .instruction_parts = instruction_parts,
        .instructions = try dupeOptional(arena, request.instructions),
        .run_id = try dupeOptional(arena, request.run_id),
        .conversation_id = try dupeOptional(arena, request.conversation_id),
        .metadata = try dupeMetadata(arena, request.metadata),
        .state = request.state,
    };
}

/// Deep-copies one response message and all nested parts into `arena`.
pub fn dupeResponseMessage(
    arena: std.mem.Allocator,
    response: ResponseMessage,
) std.mem.Allocator.Error!ResponseMessage {
    const parts = try arena.alloc(ResponsePart, response.parts.len);
    for (response.parts, parts) |part, *target| target.* = try dupeResponsePart(arena, part);
    return .{
        .parts = parts,
        .usage = try response.usage.dupe(arena),
        .timestamp_unix_ms = response.timestamp_unix_ms,
        .provider_name = try dupeOptional(arena, response.provider_name),
        .provider_url = try dupeOptional(arena, response.provider_url),
        .provider_details = if (response.provider_details) |details|
            try dupeProviderDetails(arena, details)
        else
            null,
        .provider_response_id = try dupeOptional(arena, response.provider_response_id),
        .model_name = try dupeOptional(arena, response.model_name),
        .finish_reason = if (response.finish_reason) |reason| .{
            .kind = reason.kind,
            .raw = try arena.dupe(u8, reason.raw),
        } else null,
        .run_id = try dupeOptional(arena, response.run_id),
        .conversation_id = try dupeOptional(arena, response.conversation_id),
        .metadata = try dupeMetadata(arena, response.metadata),
        .state = response.state,
    };
}

/// Copies one request part into caller-owned memory.
pub fn dupeRequestPart(arena: std.mem.Allocator, part: RequestPart) !RequestPart {
    const gpa = arena;
    return switch (part) {
        .system_prompt => |value| .{ .system_prompt = try gpa.dupe(u8, value) },
        .system_prompt_part => |value| .{ .system_prompt_part = .{
            .content = try gpa.dupe(u8, value.content),
            .timestamp_unix_ms = value.timestamp_unix_ms,
            .dynamic_ref = try dupeOptional(gpa, value.dynamic_ref),
        } },
        .user_prompt => |value| .{ .user_prompt = try dupeUserContent(gpa, value) },
        .user_prompt_part => |value| .{ .user_prompt_part = .{
            .content = try dupeUserContent(gpa, value.content),
            .timestamp_unix_ms = value.timestamp_unix_ms,
        } },
        .speech => |value| .{ .speech = try dupeSpeech(gpa, value) },
        .tool_search_return => |value| .{ .tool_search_return = try dupeToolSearchResult(gpa, value) },
        .capability_load_return => |value| .{ .capability_load_return = .{
            .call_id = try gpa.dupe(u8, value.call_id),
            .instructions = try dupeOptional(gpa, value.instructions),
            .metadata = try dupeMetadata(gpa, value.metadata),
            .timestamp_unix_ms = value.timestamp_unix_ms,
            .outcome = value.outcome,
        } },
        .tool_return => |value| .{ .tool_return = try dupeToolResult(gpa, value) },
        .retry_prompt => |value| .{ .retry_prompt = try gpa.dupe(u8, value) },
        .retry_prompt_part => |value| .{ .retry_prompt_part = .{
            .content = try gpa.dupe(u8, value.content),
            .tool_name = try dupeOptional(gpa, value.tool_name),
            .tool_call_id = try dupeOptional(gpa, value.tool_call_id),
            .timestamp_unix_ms = value.timestamp_unix_ms,
        } },
        .tool_availability_delta => |value| .{ .tool_availability_delta = .{
            .tools_added = try dupeStrings(gpa, value.tools_added),
            .tool_call_id = try dupeOptional(gpa, value.tool_call_id),
        } },
    };
}

/// Copies one response part into caller-owned memory.
pub fn dupeResponsePart(arena: std.mem.Allocator, part: ResponsePart) !ResponsePart {
    const gpa = arena;
    return switch (part) {
        .text => |value| .{ .text = try gpa.dupe(u8, value) },
        .text_part => |value| .{ .text_part = .{
            .content = try gpa.dupe(u8, value.content),
            .provider = try dupeProviderPart(gpa, value.provider),
        } },
        .tool_search_call => |value| .{ .tool_search_call = try dupeToolSearchCall(gpa, value) },
        .capability_load_call => |value| .{ .capability_load_call = .{
            .call_id = try gpa.dupe(u8, value.call_id),
            .capability_id = try gpa.dupe(u8, value.capability_id),
        } },
        .tool_call => |value| .{ .tool_call = try dupeToolCall(gpa, value) },
        .native_tool_search_call => |value| .{ .native_tool_search_call = try dupeToolSearchCall(gpa, value) },
        .native_tool_call => |value| .{ .native_tool_call = .{
            .id = try gpa.dupe(u8, value.id),
            .name = try gpa.dupe(u8, value.name),
            .arguments_json = try gpa.dupe(u8, value.arguments_json),
            .tool_kind = value.tool_kind,
            .provider = try dupeProviderPart(gpa, value.provider),
        } },
        .native_tool_search_return => |value| .{
            .native_tool_search_return = try dupeToolSearchResult(gpa, value),
        },
        .native_tool_return => |value| .{ .native_tool_return = .{
            .call_id = try gpa.dupe(u8, value.call_id),
            .name = try gpa.dupe(u8, value.name),
            .content = try gpa.dupe(u8, value.content),
            .files = try dupeContents(gpa, value.files),
            .tool_kind = value.tool_kind,
            .metadata = try dupeMetadata(gpa, value.metadata),
            .timestamp_unix_ms = value.timestamp_unix_ms,
            .outcome = value.outcome,
            .provider = try dupeProviderPart(gpa, value.provider),
        } },
        .thinking => |value| .{ .thinking = .{
            .content = try gpa.dupe(u8, value.content),
            .signature = try dupeOptional(gpa, value.signature),
            .provider = try dupeProviderPart(gpa, value.provider),
            .metadata = try dupeMetadata(gpa, value.metadata),
        } },
        .compaction => |value| .{ .compaction = .{
            .content = try dupeOptional(gpa, value.content),
            .provider = try dupeProviderPart(gpa, value.provider),
        } },
        .image => |value| .{ .image = try dupeContent(gpa, value) },
        .audio => |value| .{ .audio = try dupeContent(gpa, value) },
        .video => |value| .{ .video = try dupeContent(gpa, value) },
        .document => |value| .{ .document = try dupeContent(gpa, value) },
        .binary => |value| .{ .binary = try dupeContent(gpa, value) },
        .speech => |value| .{ .speech = try dupeSpeech(gpa, value) },
    };
}

fn dupeToolCall(arena: std.mem.Allocator, value: ToolCall) !ToolCall {
    const gpa = arena;
    return .{
        .id = try gpa.dupe(u8, value.id),
        .name = try gpa.dupe(u8, value.name),
        .arguments_json = try gpa.dupe(u8, value.arguments_json),
        .tool_kind = value.tool_kind,
        .provider = try dupeProviderPart(gpa, value.provider),
        .thought_signature = try dupeOptional(gpa, value.thought_signature),
    };
}

fn dupeToolResult(arena: std.mem.Allocator, value: ToolResult) !ToolResult {
    const gpa = arena;
    const call_id = try gpa.dupe(u8, value.call_id);
    return .{
        .call_id = call_id,
        .name = try gpa.dupe(u8, value.name),
        .content = try gpa.dupe(u8, value.content),
        .files = try dupeContents(gpa, value.files),
        .tool_kind = value.tool_kind,
        .metadata = try dupeMetadata(gpa, value.metadata),
        .timestamp_unix_ms = value.timestamp_unix_ms,
        .outcome = value.outcome,
        .is_error = value.is_error,
    };
}

fn dupeToolSearchCall(arena: std.mem.Allocator, value: ToolSearchCall) !ToolSearchCall {
    const gpa = arena;
    return .{
        .call_id = try gpa.dupe(u8, value.call_id), // kcov-ignore
        .queries = try dupeStrings(gpa, value.queries),
        .provider = try dupeProviderPart(gpa, value.provider),
    };
}

fn dupeToolSearchResult(arena: std.mem.Allocator, value: ToolSearchResult) !ToolSearchResult {
    const gpa = arena;
    const matches = try gpa.alloc(ToolSearchMatch, value.discovered_tools.len);
    for (value.discovered_tools, matches) |match, *copy| copy.* = .{ .name = try gpa.dupe(u8, match.name) };
    return .{
        .call_id = try gpa.dupe(u8, value.call_id),
        .discovered_tools = matches,
        .message = try dupeOptional(gpa, value.message),
        .metadata = try dupeMetadata(gpa, value.metadata),
        .timestamp_unix_ms = value.timestamp_unix_ms,
        .outcome = value.outcome,
        .provider = try dupeProviderPart(gpa, value.provider),
    };
}

fn dupeSpeech(arena: std.mem.Allocator, value: SpeechPart) !SpeechPart {
    const gpa = arena;
    const speaker = value.speaker;
    return .{
        .speaker = speaker,
        .transcript = try dupeOptional(gpa, value.transcript),
        .audio = if (value.audio) |audio| try dupeContent(gpa, audio) else null,
        .interrupted_at_ms = value.interrupted_at_ms,
        .provider = try dupeProviderPart(gpa, value.provider),
    };
}

/// Copies one user-content item into caller-owned memory.
pub fn dupeUserContent(arena: std.mem.Allocator, value: UserContent) !UserContent {
    const gpa = arena;
    return switch (value) {
        .text => |text| .{ .text = try gpa.dupe(u8, text) },
        .text_content => |text| .{ .text_content = .{
            .content = try gpa.dupe(u8, text.content),
            .metadata = try dupeMetadata(gpa, text.metadata),
        } },
        .image => |content| .{ .image = try dupeContent(gpa, content) },
        .audio => |content| .{ .audio = try dupeContent(gpa, content) },
        .video => |content| .{ .video = try dupeContent(gpa, content) },
        .document => |content| .{ .document = try dupeContent(gpa, content) },
        .binary => |content| .{ .binary = try dupeContent(gpa, content) },
        .uploaded_file => |file| .{ .uploaded_file = try dupeUploadedFile(gpa, file) },
        .cache_point => |point| .{ .cache_point = point },
    };
}

/// Copies rich content into caller-owned memory.
pub fn dupeContent(arena: std.mem.Allocator, value: Content) !Content {
    const gpa = arena;
    return .{
        .source = switch (value.source) {
            .bytes => |bytes| .{ .bytes = try gpa.dupe(u8, bytes) },
            .url => |url| .{ .url = try gpa.dupe(u8, url) },
            .uploaded_file => |file| .{ .uploaded_file = try dupeUploadedFile(gpa, file) },
            .provider_file => |file| .{ .provider_file = .{
                .id = try gpa.dupe(u8, file.id),
                .provider = try dupeOptional(gpa, file.provider),
            } },
        },
        .media_type = try gpa.dupe(u8, value.media_type),
        .filename = try dupeOptional(gpa, value.filename),
        .identifier = try dupeOptional(gpa, value.identifier),
        .provider = try dupeProviderPart(gpa, value.provider),
        .thought_signature = try dupeOptional(gpa, value.thought_signature),
        .metadata = try dupeMetadata(gpa, value.metadata),
    };
}

fn dupeContents(arena: std.mem.Allocator, source: []const Content) ![]const Content {
    const gpa = arena;
    const result = try gpa.alloc(Content, source.len);
    for (source, result) |value, *copy| copy.* = try dupeContent(gpa, value);
    return result;
}

fn dupeUploadedFile(arena: std.mem.Allocator, value: UploadedFile) !UploadedFile {
    const gpa = arena;
    return .{
        .id = try gpa.dupe(u8, value.id), // kcov-ignore
        .provider_name = try gpa.dupe(u8, value.provider_name),
        .media_type = try dupeOptional(gpa, value.media_type),
        .metadata = try dupeMetadata(gpa, value.metadata),
    };
}

fn dupeProviderPart(arena: std.mem.Allocator, value: ProviderPart) !ProviderPart {
    const gpa = arena;
    return .{
        .id = try dupeOptional(gpa, value.id),
        .provider_name = try dupeOptional(gpa, value.provider_name),
        .provider_details = if (value.provider_details) |details| try dupeProviderDetails(gpa, details) else null,
    };
}

/// Copies provider details and every nested JSON value into caller-owned memory.
pub fn dupeProviderDetails(arena: std.mem.Allocator, details: ProviderDetails) !ProviderDetails {
    return .{ .value = try dupeJsonValue(arena, details.value) };
}

fn dupeJsonValue(arena: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{ .number_string = try arena.dupe(u8, item) },
        .string => |item| .{ .string = try arena.dupe(u8, item) },
        .array => |items| blk: {
            var copy = std.json.Array.init(arena);
            for (items.items) |item| try copy.append(try dupeJsonValue(arena, item));
            break :blk .{ .array = copy };
        },
        .object => |items| blk: {
            var copy: std.json.ObjectMap = .empty;
            var iterator = items.iterator();
            while (iterator.next()) |entry| try copy.put(
                arena,
                try arena.dupe(u8, entry.key_ptr.*),
                try dupeJsonValue(arena, entry.value_ptr.*),
            );
            break :blk .{ .object = copy };
        },
    };
}

/// Copies application metadata into caller-owned memory.
pub fn dupeMetadata(arena: std.mem.Allocator, source: []const Metadata) ![]const Metadata {
    const gpa = arena;
    const result = try gpa.alloc(Metadata, source.len);
    for (source, result) |item, *copy| copy.* = .{
        .key = try gpa.dupe(u8, item.key),
        .value = try gpa.dupe(u8, item.value),
    };
    return result;
}

fn dupeStrings(arena: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const gpa = arena;
    const result = try gpa.alloc([]const u8, source.len);
    for (source, result) |value, *copy| copy.* = try gpa.dupe(u8, value);
    return result;
}

fn dupeOptional(arena: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const gpa = arena;
    return if (value) |string| try gpa.dupe(u8, string) else null;
}

fn checkAllVariantDupes(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const metadata = [_]Metadata{.{ .key = "source", .value = "test" }};
    var provider_details_array = std.json.Array.init(gpa);
    try provider_details_array.append(.null);
    try provider_details_array.append(.{ .integer = 7 });
    try provider_details_array.append(.{ .float = 1.5 });
    try provider_details_array.append(.{ .number_string = "123456789012345678901234567890" });
    try provider_details_array.append(.{ .string = "unknown" });
    var provider_details_object: std.json.ObjectMap = .empty;
    try provider_details_object.put(gpa, "opaque", .{ .bool = true });
    try provider_details_object.put(gpa, "values", .{ .array = provider_details_array });
    const provider = ProviderPart{
        .id = "provider-item",
        .provider_name = "test-provider",
        .provider_details = .{ .value = .{ .object = provider_details_object } },
    };
    const uploaded = UploadedFile{
        .id = "file-1",
        .provider_name = "test-provider",
        .media_type = "image/png",
        .metadata = &metadata,
    };
    const rich_contents = [_]Content{
        .{
            .source = .{ .bytes = "bytes" },
            .media_type = "application/octet-stream",
            .filename = "data.bin",
            .identifier = "content-1",
            .provider = provider,
            .thought_signature = "signature",
            .metadata = &metadata,
        },
        .{ .source = .{ .url = "https://example.test/file" }, .media_type = "text/plain" },
        .{ .source = .{ .uploaded_file = uploaded }, .media_type = "image/png" },
        .{
            .source = .{ .provider_file = .{ .id = "legacy-file", .provider = "test-provider" } },
            .media_type = "application/pdf",
        },
    };
    const discovered = [_]ToolSearchMatch{.{ .name = "weather" }};
    const queries = [_][]const u8{ "weather", "forecast" };
    const tools = [_][]const u8{ "weather", "clock" };

    const request_parts = [_]RequestPart{
        .{ .system_prompt = "system" },
        .{ .system_prompt_part = .{
            .content = "dynamic system",
            .timestamp_unix_ms = 1,
            .dynamic_ref = "tenant",
        } },
        .{ .user_prompt = .{ .text = "plain" } },
        .{ .user_prompt = .{ .text_content = .{ .content = "rich text", .metadata = &metadata } } },
        .{ .user_prompt = .{ .image = rich_contents[0] } },
        .{ .user_prompt = .{ .audio = rich_contents[1] } },
        .{ .user_prompt = .{ .video = rich_contents[2] } },
        .{ .user_prompt = .{ .document = rich_contents[3] } },
        .{ .user_prompt = .{ .binary = rich_contents[0] } },
        .{ .user_prompt = .{ .uploaded_file = uploaded } },
        .{ .user_prompt = .{ .cache_point = .{ .ttl = .one_hour } } },
        .{ .user_prompt_part = .{
            .content = .{ .text_content = .{ .content = "timestamped", .metadata = &metadata } },
            .timestamp_unix_ms = 2,
        } },
        .{ .speech = .{
            .speaker = .user,
            .transcript = "hello",
            .audio = rich_contents[0],
            .interrupted_at_ms = 10,
            .provider = provider,
        } },
        .{ .tool_search_return = .{
            .call_id = "search-1",
            .discovered_tools = &discovered,
            .message = "one match",
            .metadata = &metadata,
            .timestamp_unix_ms = 3,
            .outcome = .success,
            .provider = provider,
        } },
        .{ .capability_load_return = .{
            .call_id = "load-1",
            .instructions = "loaded",
            .metadata = &metadata,
            .timestamp_unix_ms = 4,
            .outcome = .denied,
        } },
        .{ .tool_return = .{
            .call_id = "tool-1",
            .name = "weather",
            .content = "sunny",
            .files = &rich_contents,
            .tool_kind = .tool_search,
            .metadata = &metadata,
            .timestamp_unix_ms = 5,
            .outcome = .interrupted,
            .is_error = true,
        } },
        .{ .retry_prompt = "retry" },
        .{ .retry_prompt_part = .{
            .content = "invalid arguments",
            .tool_name = "weather",
            .tool_call_id = "tool-1",
            .timestamp_unix_ms = 6,
        } },
        .{ .tool_availability_delta = .{ .tools_added = &tools, .tool_call_id = "search-1" } },
    };
    for (request_parts) |part| _ = try dupeRequestPart(gpa, part);

    const response_parts = [_]ResponsePart{
        .{ .text = "plain" },
        .{ .text_part = .{ .content = "rich", .provider = provider } },
        .{ .tool_search_call = .{ .call_id = "search-1", .queries = &queries, .provider = provider } },
        .{ .capability_load_call = .{ .call_id = "load-1", .capability_id = "maps" } },
        .{ .tool_call = .{
            .id = "tool-1",
            .name = "weather",
            .arguments_json = "{}",
            .tool_kind = .capability_load,
            .provider = provider,
            .thought_signature = "signature",
        } },
        .{ .native_tool_search_call = .{
            .call_id = "native-search",
            .queries = &queries,
            .provider = provider,
        } },
        .{ .native_tool_call = .{
            .id = "native-1",
            .name = "web_search",
            .arguments_json = "{}",
            .tool_kind = .tool_search,
            .provider = provider,
        } },
        .{ .native_tool_search_return = .{
            .call_id = "native-search",
            .discovered_tools = &discovered,
            .message = "found",
            .metadata = &metadata,
            .timestamp_unix_ms = 7,
            .outcome = .success,
            .provider = provider,
        } },
        .{ .native_tool_return = .{
            .call_id = "native-1",
            .name = "web_search",
            .content = "result",
            .files = &rich_contents,
            .tool_kind = .tool_search,
            .metadata = &metadata,
            .timestamp_unix_ms = 8,
            .outcome = .failed,
            .provider = provider,
        } },
        .{ .thinking = .{
            .content = "reasoning",
            .signature = "signature",
            .provider = provider,
            .metadata = &metadata,
        } },
        .{ .compaction = .{ .content = "summary", .provider = provider } },
        .{ .image = rich_contents[0] },
        .{ .audio = rich_contents[1] },
        .{ .video = rich_contents[2] },
        .{ .document = rich_contents[3] },
        .{ .binary = rich_contents[0] },
        .{
            .speech = .{
                .speaker = .assistant,
                .transcript = "hello",
                .audio = rich_contents[0], // kcov-ignore
                .interrupted_at_ms = 9,
                .provider = provider,
            },
        },
    };
    for (response_parts) |part| _ = try dupeResponsePart(gpa, part);

    const search_copy = (try dupeResponsePart(gpa, response_parts[2])).tool_search_call;
    try std.testing.expectEqualStrings("search-1", search_copy.call_id);
    const uploaded_copy = (try dupeUserContent(gpa, .{ .uploaded_file = uploaded })).uploaded_file;
    try std.testing.expectEqualStrings("file-1", uploaded_copy.id);
    const speech_copy = (try dupeResponsePart(gpa, response_parts[16])).speech;
    try std.testing.expectEqualStrings("bytes", speech_copy.audio.?.source.bytes);
    const details_copy = (try dupeContent(gpa, rich_contents[0])).provider.provider_details.?;
    try std.testing.expect(details_copy.value.object.get("opaque").?.bool);
    try std.testing.expectEqualStrings(
        "123456789012345678901234567890",
        details_copy.value.object.get("values").?.array.items[3].number_string,
    );

    const messages = [_]Message{
        .{ .request = .{
            .parts = &request_parts,
            .timestamp_unix_ms = 10,
            .instruction_parts = &.{.{ .content = "dynamic", .dynamic = true }},
            .instructions = "rules",
            .run_id = "request-run",
            .conversation_id = "conversation",
            .metadata = &metadata,
            .state = .interrupted,
        } },
        .{ .response = .{
            .parts = &response_parts,
            .usage = .{
                .input_tokens = 2,
                .details = &.{.{ .name = "accepted_tokens", .value = 1 }},
                .cost_table_version = "prices-v1",
            },
            .timestamp_unix_ms = 11,
            .provider_name = "test-provider",
            .provider_url = "https://example.test",
            .provider_details = provider.provider_details,
            .provider_response_id = "response-1",
            .model_name = "test-model",
            .finish_reason = .{ .kind = .stop, .raw = "done" },
            .run_id = "response-run",
            .conversation_id = "conversation",
            .metadata = &metadata,
            .state = .interrupted,
        } },
    };
    const message_copy = try dupeMessages(gpa, &messages);
    try std.testing.expectEqual(@as(usize, 2), message_copy.len);
    try std.testing.expectEqualStrings("rules", message_copy[0].request.instructions.?);
    try std.testing.expectEqualStrings("done", message_copy[1].response.finish_reason.?.raw);
    try std.testing.expectEqualStrings("accepted_tokens", message_copy[1].response.usage.details[0].name);
    try std.testing.expectEqualStrings("prices-v1", message_copy[1].response.usage.cost_table_version.?);

    _ = uploaded.asContent();
    _ = try dupeMetadata(gpa, &metadata);
    _ = try dupeMetadata(gpa, &.{});
}

test "usage reports provider totals" {
    const value = Usage{ .input_tokens = 10, .output_tokens = 16 };
    try std.testing.expectEqual(@as(u64, 26), value.totalTokens());
}

test "tool results expose only failed outcomes as provider errors" {
    const failed = ToolResult{ .call_id = "1", .name = "tool", .content = "no", .outcome = .failed };
    const denied = ToolResult{ .call_id = "2", .name = "tool", .content = "no", .outcome = .denied };
    const legacy = ToolResult{ .call_id = "3", .name = "tool", .content = "no", .is_error = true };

    try std.testing.expect(failed.isError());
    try std.testing.expect(!denied.isError());
    try std.testing.expectEqual(ToolOutcome.failed, legacy.effectiveOutcome());
    try std.testing.expect((ProviderPart{ .id = "item" }).requiresReplay());
    try std.testing.expect((ProviderPart{ .provider_details = .{ .value = .{ .object = .empty } } }).requiresReplay());
    try std.testing.expect(!(ProviderPart{ .provider_name = "provider" }).requiresReplay());
    try std.testing.expectError(error.InvalidProviderDetails, ProviderDetails.fromValue(.{ .string = "invalid" }));
}

test "every message variant supports owned duplication" {
    try checkAllVariantDupes(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllVariantDupes, .{});
}
