const std = @import("std");
const json_limits = @import("json.zig");

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.seq_cst);
    }
};

/// Shared cancellation and monotonic deadline state for one agent invocation.
/// A deadline is created once and downstream operations consume its remaining
/// time instead of restarting a timeout.
pub const RunControl = struct {
    io: ?std.Io = null,
    cancellation: ?*const CancellationToken = null,
    deadline: ?std.Io.Clock.Timestamp = null,

    /// Creates a control using the awake monotonic clock. A deadline requires
    /// an I/O runtime because every consumer must observe the same clock.
    pub fn init(io: ?std.Io, cancellation: ?*const CancellationToken, timeout_ms: ?u64) !RunControl {
        const runtime = if (timeout_ms != null)
            io orelse return error.RunControlRequiresIo
        else
            io;
        const deadline = if (timeout_ms) |milliseconds| blk: {
            const maximum: u64 = @intCast(std.math.maxInt(i64));
            break :blk std.Io.Clock.Timestamp.fromNow(runtime.?, .{
                .raw = .fromMilliseconds(@intCast(@min(milliseconds, maximum))),
                .clock = .awake,
            });
        } else null;
        return .{ .io = runtime, .cancellation = cancellation, .deadline = deadline };
    }

    /// Fails when cancellation was requested or the deadline has elapsed.
    pub fn check(self: RunControl) !void {
        if (self.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        _ = try self.remainingMilliseconds();
    }

    /// Returns the positive milliseconds left, rounded up so a live
    /// sub-millisecond deadline is not mistaken for an expired one.
    pub fn remainingMilliseconds(self: RunControl) !?u64 {
        const deadline = self.deadline orelse return null;
        const io = self.io orelse return error.RunControlRequiresIo;
        const now = std.Io.Clock.Timestamp.now(io, deadline.clock);
        const nanoseconds = now.durationTo(deadline).raw.nanoseconds;
        if (nanoseconds <= 0) return error.RunTimedOut;
        const unit: i96 = std.time.ns_per_ms;
        const rounded = @divFloor(nanoseconds + unit - 1, unit);
        return @intCast(@min(rounded, std.math.maxInt(u64)));
    }

    /// Tightens an operation-local timeout to the remaining run deadline.
    pub fn timeoutMilliseconds(self: RunControl, local_timeout_ms: ?u64) !?u64 {
        if (self.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        const remaining = try self.remainingMilliseconds();
        if (remaining) |run_timeout| {
            if (local_timeout_ms) |local| return @min(run_timeout, local);
            return run_timeout;
        }
        return local_timeout_ms;
    }

    /// Invokes one fallible operation while racing cancellation and the
    /// absolute run deadline. Losing work is cancelled and drained before this
    /// function returns, so it cannot mutate caller-owned state afterward.
    /// Results that require cleanup should be allocated in the run-owned arena
    /// because a result completed at the cancellation boundary may be discarded.
    pub fn invoke(
        self: RunControl,
        comptime Result: type,
        comptime operation: anytype,
        args: anytype,
    ) !Result {
        try self.check();
        if (self.cancellation == null and self.deadline == null)
            return @call(.auto, operation, args);

        const io = self.io orelse {
            const result = try @call(.auto, operation, args);
            try self.check();
            return result;
        };
        const Outcome = InvocationOutcome(Result);
        var buffer: [3]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.operation, operation, args) catch
            return error.RunControlConcurrencyUnavailable;
        if (self.deadline) |deadline|
            select.async(.deadline, waitForDeadline, .{ io, deadline });
        if (self.cancellation) |token|
            select.async(.cancelled, waitForCancellation, .{ io, token });

        return switch (try select.await()) {
            .operation => |result| operation: {
                const value = try result;
                try self.check();
                break :operation value;
            },
            .deadline => |result| blk: {
                result catch return error.Cancelled;
                break :blk error.RunTimedOut;
            },
            .cancelled => |result| blk: {
                result catch return error.Cancelled;
                break :blk error.Cancelled;
            },
        };
    }

    fn InvocationOutcome(comptime Result: type) type {
        return union(enum) {
            operation: anyerror!Result,
            deadline: anyerror!void,
            cancelled: anyerror!void,
        };
    }

    fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return deadline.wait(io);
    }

    fn waitForCancellation(io: std.Io, token: *const CancellationToken) !void {
        while (!token.isCancelled()) {
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }).sleep(io);
        }
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    /// Provider reasoning state that must accompany this call in later turns.
    thought_signature: ?[]const u8 = null,
};

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

pub const ProviderFile = struct {
    /// Provider file identifier or URI.
    id: []const u8,
    /// Optional provider guard. When set, another provider must reject it.
    provider: ?[]const u8 = null,
};

pub const ContentSource = union(enum) {
    bytes: []const u8,
    url: []const u8,
    provider_file: ProviderFile,
};

/// Rich content with a semantic kind supplied by its enclosing `Part` tag.
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

/// Rich content accepted by `RunOptions.prompt_parts`.
pub const PromptPart = UserContent;

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json_schema: []const u8,
    /// Application-visible schema for the encoded tool result. Providers do
    /// not currently receive this field.
    return_json_schema: ?[]const u8 = null,
};

/// Application metadata carried with a tool and exposed to lifecycle hooks.
pub const ToolMetadata = Metadata;

/// Determines whether an agent may execute a tool immediately or must pause.
pub const ToolExecution = enum {
    immediate,
    requires_approval,
    external,
};

/// Encoded result from a tool plus user messages to append after the protocol
/// tool-result message.
pub const ToolOutput = struct {
    content: []const u8,
    follow_up_messages: []const RequestMessage = &.{},
};

/// Resource limits for local tool execution. An agent supplies the run-wide
/// policy; `Tool.limits` may tighten it for one tool.
pub const ToolLimits = struct {
    /// Maximum wall-clock duration for one call. Requires an agent `io`.
    timeout_ms: ?u64 = null,
    /// Maximum simultaneously executing calls.
    max_concurrency: usize = 8,
    /// Maximum accepted calls waiting for an execution slot.
    max_queue_size: usize = 64,
    /// Maximum bytes in one encoded tool result.
    max_result_bytes: usize = 1024 * 1024,
    /// Maximum follow-up messages returned by one tool call.
    max_follow_up_messages: usize = 16,
    /// Maximum aggregate string and binary bytes in follow-up messages.
    max_follow_up_bytes: usize = 1024 * 1024,
};

/// A typed reflected-tool return with optional model-visible follow-up
/// messages. `reflect.tool` derives its return schema from `Value`.
pub fn ToolReturn(comptime Value: type) type {
    return struct {
        value: Value,
        follow_up_messages: []const RequestMessage = &.{},

        pub const zigai_tool_return = true;
        pub const ValueType = Value;
    };
}

pub const Tool = struct {
    definition: ToolDefinition,
    /// Metadata for application policy and observability; providers do not receive it.
    metadata: []const ToolMetadata = &.{},
    execution: ToolExecution = .immediate,
    context: *anyopaque,
    /// Overrides `Agent.max_tool_retries` for this tool when non-null.
    max_retries: ?usize = null,
    /// Tightens the agent's local execution limits for this tool when non-null.
    limits: ?ToolLimits = null,
    validateFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        arguments_json: []const u8,
    ) anyerror!void = null,
    executeFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) anyerror![]const u8 = null,
    executeWithContextFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_context: ToolRunContext,
        arguments_json: []const u8,
    ) anyerror![]const u8 = null,
    executeOutputFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        arguments_json: []const u8,
    ) anyerror!ToolOutput = null,
    executeOutputWithContextFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_context: ToolRunContext,
        arguments_json: []const u8,
    ) anyerror!ToolOutput = null,
    /// Classifies failures that are safe to show to the model for correction.
    /// By default, only allocation and cancellation failures are fatal.
    isRecoverableFn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    /// Validates one JSON argument document, then executes this tool.
    pub fn execute(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        try validateToolArgumentsJson(allocator, arguments_json);
        return self.executePrepared(allocator, arguments_json);
    }

    fn executePrepared(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        if (self.executeFn) |execute_fn| return execute_fn(self.context, allocator, arguments_json);
        if (self.executeOutputFn) |execute_output| {
            const output = try execute_output(self.context, allocator, arguments_json);
            return output.content;
        }
        return error.MissingToolExecutor;
    }

    /// Validates one bounded JSON argument document and any tool-specific rules.
    pub fn validate(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) !void {
        try validateToolArgumentsJson(allocator, arguments_json);
        const validate_arguments = self.validateFn orelse return;
        return validate_arguments(self.context, allocator, arguments_json);
    }

    /// Validates and executes this tool with the current agent run context.
    pub fn executeWithContext(self: Tool, allocator: std.mem.Allocator, run_context: ToolRunContext, arguments_json: []const u8) ![]const u8 {
        try validateToolArgumentsJson(allocator, arguments_json);
        if (self.executeWithContextFn) |contextual|
            return contextual(self.context, allocator, run_context, arguments_json);
        if (self.executeOutputWithContextFn) |execute_output|
            return (try execute_output(self.context, allocator, run_context, arguments_json)).content;
        return self.executePrepared(allocator, arguments_json);
    }

    /// Validates and executes this tool while preserving rich output metadata.
    pub fn executeOutput(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolOutput {
        try validateToolArgumentsJson(allocator, arguments_json);
        return self.executeOutputPrepared(allocator, arguments_json);
    }

    fn executeOutputPrepared(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolOutput {
        if (self.executeOutputFn) |execute_output| return execute_output(self.context, allocator, arguments_json);
        return .{ .content = try self.executePrepared(allocator, arguments_json) };
    }

    /// Validates and executes this contextual tool with rich output metadata.
    pub fn executeOutputWithContext(
        self: Tool,
        allocator: std.mem.Allocator,
        run_context: ToolRunContext,
        arguments_json: []const u8,
    ) !ToolOutput {
        try validateToolArgumentsJson(allocator, arguments_json);
        if (self.executeOutputWithContextFn) |execute_output|
            return execute_output(self.context, allocator, run_context, arguments_json);
        if (self.executeWithContextFn) |execute_context| return .{
            .content = try execute_context(self.context, allocator, run_context, arguments_json),
        };
        return self.executeOutputPrepared(allocator, arguments_json);
    }

    /// Returns whether `failure` can be safely exposed to the model.
    pub fn isRecoverable(self: Tool, failure: anyerror) bool {
        if (self.isRecoverableFn) |classify| return classify(self.context, failure);
        return switch (failure) {
            error.OutOfMemory,
            error.Cancelled,
            error.RequestCancelled,
            error.RunTimedOut,
            error.RunControlRequiresIo,
            error.RunControlConcurrencyUnavailable,
            error.ToolConcurrencyUnavailable,
            error.ToolIsolationRequiresIo,
            => false,
            else => true,
        };
    }
};

fn validateToolArgumentsJson(allocator: std.mem.Allocator, arguments_json: []const u8) !void {
    try json_limits.validateAs(allocator, arguments_json, json_limits.defaults.tool_payload, error.InvalidToolArguments);
}

/// Per-run state made available to contextual tools. `dependency` provides a
/// checked-at-the-call-site cast while keeping Agent itself non-generic.
pub const ToolRunContext = struct {
    dependencies: ?*anyopaque = null,
    usage: Usage = .{},
    model_requests: usize = 0,
    /// Shared cooperative cancellation state for the run.
    cancellation: ?*const CancellationToken = null,
    /// Runtime available to tools for cancellable I/O.
    io: ?std.Io = null,
    /// Absolute monotonic deadline shared by the complete agent invocation.
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn dependency(self: ToolRunContext, comptime T: type) ?*T {
        const pointer = self.dependencies orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
};

/// Capabilities belong to the model, not the provider transport. Keeping this
/// separate lets callers reject an unsupported feature before making a paid
/// network request.
pub const ModelProfile = struct {
    supports_tools: bool = true,
    supports_parallel_tool_calls: bool = true,
    supports_json_schema_output: bool = false,
    supports_json_object_output: bool = false,
    supports_system_messages: bool = true,
    supports_thinking: bool = false,
    supports_streaming: bool = false,
    supports_temperature: bool = false,
    supports_max_tokens: bool = true,
    supports_stop_sequences: bool = false,
    supports_seed: bool = false,
    reasoning_efforts: ReasoningEffortSet = ReasoningEffortSet.initEmpty(),
    builtin_tools: BuiltinToolSet = BuiltinToolSet.initEmpty(),
    content_types: ContentTypeSet = ContentTypeSet.initEmpty(),

    pub const ReasoningEffortSet = std.EnumSet(ReasoningEffort);
    pub const BuiltinToolSet = std.EnumSet(BuiltinToolKind);
    pub const ContentTypeSet = std.EnumSet(ContentType);

    pub fn supportsReasoningEffort(self: ModelProfile, effort: ReasoningEffort) bool {
        return self.reasoning_efforts.contains(effort);
    }

    pub fn supportsBuiltinTool(self: ModelProfile, kind: BuiltinToolKind) bool {
        return self.builtin_tools.contains(kind);
    }

    pub fn supportsContentType(self: ModelProfile, kind: ContentType) bool {
        return self.content_types.contains(kind);
    }
};

pub const ContentType = enum {
    image,
    audio,
    document,
    binary,
    thinking,
};

pub const BuiltinToolKind = enum {
    web_search,
    web_fetch,
};

/// A provider-managed tool. The provider executes it inside the model request;
/// it never enters the application's local tool dispatcher.
pub const BuiltinTool = union(BuiltinToolKind) {
    web_search: WebSearch,
    web_fetch: WebFetch,

    pub const WebSearch = struct {};
    pub const WebFetch = struct {};

    pub fn kind(self: BuiltinTool) BuiltinToolKind {
        return std.meta.activeTag(self);
    }
};

pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

/// Provider-neutral generation controls. Null fields inherit from a lower-precedence layer.
pub const ModelSettings = struct {
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?i64 = null,
    reasoning_effort: ?ReasoningEffort = null,

    /// Applies each non-null field from `overrides` to `self`.
    pub fn overrideWith(self: ModelSettings, overrides: ModelSettings) ModelSettings {
        return .{
            .temperature = overrides.temperature orelse self.temperature,
            .max_tokens = overrides.max_tokens orelse self.max_tokens,
            .stop_sequences = overrides.stop_sequences orelse self.stop_sequences,
            .seed = overrides.seed orelse self.seed,
            .reasoning_effort = overrides.reasoning_effort orelse self.reasoning_effort,
        };
    }
};

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

/// Stable error categories emitted by provider adapters. Agents can make retry
/// decisions from these without depending on a provider's private error JSON.
pub const ProviderRequestError = error{
    ProviderRateLimited,
    ProviderServerError,
    ProviderRequestFailed,
};

pub const ProviderError = struct {
    provider: []const u8,
    status: u16,
    code: ?[]const u8 = null,
    message: []const u8,
    body: []const u8,
    retry_after_seconds: ?u64 = null,
    rate_limit_remaining_requests: ?u64 = null,
    rate_limit_remaining_tokens: ?u64 = null,
};

/// Receives a borrowed error view synchronously. Copy fields in the callback if
/// they need to outlive the request.
pub const ProviderErrorObserver = struct {
    context: *anyopaque,
    observeFn: *const fn (context: *anyopaque, provider_error: ProviderError) void,

    pub fn observe(self: ProviderErrorObserver, provider_error: ProviderError) void {
        self.observeFn(self.context, provider_error);
    }
};

pub const ModelRequest = struct {
    messages: []const Message,
    /// Current-run instructions. Providers encode these as their native
    /// instruction or system-message representation; agents do not retain
    /// them in reusable message history.
    instructions: []const []const u8 = &.{},
    tools: []const ToolDefinition = &.{},
    builtin_tools: []const BuiltinTool = &.{},
    output: OutputFormat = .text,
    error_observer: ?ProviderErrorObserver = null,
    timeout_ms: ?u64 = null,
    cancellation: ?*const CancellationToken = null,
    settings: ModelSettings = .{},
};

pub const OutputFormat = union(enum) {
    text,
    json_object,
    json_schema: JsonSchema,

    pub const JsonSchema = struct {
        name: []const u8,
        schema: []const u8,
        strict: bool = true,
    };
};

/// Provider response data allocated by the allocator passed to `Model.request`
/// or `Model.stream`. Direct callers should normally use an arena allocator;
/// `Agent` copies the response into its own owned result arena.
pub const ModelResponse = ResponseMessage;

pub const ToolCallDelta = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_delta: []const u8 = "",
};

/// Borrowed events emitted synchronously while a model response is arriving.
/// Providers return the same accumulated `ModelResponse` used by buffered
/// requests after the final event, so the agent loop has one source of truth.
pub const ModelStreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    tool_call: ToolCall,
    usage: Usage,
};

pub const ModelStreamSink = struct {
    context: *anyopaque,
    eventFn: *const fn (context: *anyopaque, event: ModelStreamEvent) anyerror!void,

    pub fn emit(self: ModelStreamSink, event: ModelStreamEvent) !void {
        return self.eventFn(self.context, event);
    }
};

/// A small Zig vtable keeps the agent independent from every provider package
/// without forcing provider implementations to allocate wrapper objects.
pub const Model = struct {
    context: *anyopaque,
    profile: ModelProfile,
    /// Provider identity used by telemetry and application policy.
    provider_name: ?[]const u8 = null,
    /// Provider model identifier used by telemetry and application policy.
    model_name: ?[]const u8 = null,
    settings: ModelSettings = .{},
    requestFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, request: ModelRequest) anyerror!ModelResponse,
    streamFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: ModelRequest,
        sink: ModelStreamSink,
    ) anyerror!ModelResponse = null,

    pub fn request(self: Model, allocator: std.mem.Allocator, value: ModelRequest) !ModelResponse {
        var response = try self.requestFn(self.context, allocator, value);
        response.provider_name = response.provider_name orelse self.provider_name;
        response.model_name = response.model_name orelse self.model_name;
        return response;
    }

    pub fn stream(self: Model, allocator: std.mem.Allocator, value: ModelRequest, sink: ModelStreamSink) !ModelResponse {
        const stream_request = self.streamFn orelse return error.StreamingNotSupported;
        var response = try stream_request(self.context, allocator, value, sink);
        response.provider_name = response.provider_name orelse self.provider_name;
        response.model_name = response.model_name orelse self.model_name;
        return response;
    }
};

test "usage adds provider totals" {
    var usage = Usage{ .input_tokens = 2, .output_tokens = 3 };
    usage.add(.{ .input_tokens = 5, .output_tokens = 7 });
    try std.testing.expectEqual(@as(u64, 7), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 10), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 17), usage.totalTokens());
}

test "run control shares one deadline and drains interrupted work" {
    const State = struct {
        active: std.atomic.Value(bool) = .init(false),

        fn slow(self: *@This(), io: std.Io) !u8 {
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            while (true) try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            } }).sleep(io);
        }
    };

    try std.testing.expectError(
        error.RunControlRequiresIo,
        RunControl.init(null, null, 1),
    );
    try (RunControl{}).invoke(void, struct {
        fn call() !void {
            try std.testing.expect(true);
        }
    }.call, .{});

    var unavailable = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer unavailable.deinit();
    const unavailable_control = try RunControl.init(unavailable.io(), null, 10);
    try std.testing.expectError(
        error.RunControlConcurrencyUnavailable,
        unavailable_control.invoke(void, struct {
            fn call() !void {
                unreachable;
            }
        }.call, .{}),
    );

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var state: State = .{};
    const control = try RunControl.init(io, null, 2);
    const first_remaining = (try control.remainingMilliseconds()).?;
    try std.testing.expect(first_remaining > 0 and first_remaining <= 2);
    try std.testing.expectEqual(@as(?u64, 1), try control.timeoutMilliseconds(1));
    try std.testing.expectError(error.RunTimedOut, control.invoke(u8, State.slow, .{ &state, io }));
    try std.testing.expect(!state.active.load(.seq_cst));
    try std.testing.expectError(error.RunTimedOut, control.check());
}

test "run control drains cancellation and supports cooperative fallback" {
    const State = struct {
        active: std.atomic.Value(bool) = .init(false),

        fn slow(self: *@This(), io: std.Io) !void {
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            } }).sleep(io);
        }

        fn cancelAfter(io: std.Io, token: *CancellationToken, state: *@This()) !void {
            while (!state.active.load(.seq_cst)) try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(1),
                .clock = .awake,
            } }).sleep(io);
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(10),
                .clock = .awake,
            } }).sleep(io);
            token.cancel();
        }

        fn cancelCooperatively(token: *CancellationToken) !u8 {
            token.cancel();
            return 1;
        }

        fn succeed() !void {
            try std.testing.expect(true);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var token: CancellationToken = .{};
    var state: State = .{};
    var canceller = try io.concurrent(State.cancelAfter, .{ io, &token, &state });
    try std.testing.expectError(
        error.Cancelled,
        (RunControl{ .io = io, .cancellation = &token }).invoke(void, State.slow, .{ &state, io }),
    );
    try canceller.await(io);
    try std.testing.expect(!state.active.load(.seq_cst));

    var live_token: CancellationToken = .{};
    try (RunControl{ .cancellation = &live_token }).invoke(void, State.succeed, .{});

    var cooperative_token: CancellationToken = .{};
    try std.testing.expectError(
        error.Cancelled,
        (RunControl{ .cancellation = &cooperative_token }).invoke(
            u8,
            State.cancelCooperatively,
            .{&cooperative_token},
        ),
    );
}

test "tool run context casts optional dependencies" {
    var value: u32 = 42;
    const context = ToolRunContext{ .dependencies = &value };
    try std.testing.expectEqual(@as(u32, 42), context.dependency(u32).?.*);
    try std.testing.expect((ToolRunContext{}).dependency(u32) == null);
}

test "model stream sinks propagate events and unsupported models fail" {
    const Capture = struct {
        called: bool = false,
        requests: usize = 0,
        fn event(context: *anyopaque, value: ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = std.mem.eql(u8, value.text_delta, "hello");
        }
        fn request(context: *anyopaque, _: std.mem.Allocator, _: ModelRequest) !ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests += 1;
            return .{ .parts = &.{} };
        }
    };
    var capture: Capture = .{};
    const sink = ModelStreamSink{ .context = &capture, .eventFn = Capture.event };
    try sink.emit(.{ .text_delta = "hello" });
    try std.testing.expect(capture.called);
    const value = Model{ .context = &capture, .profile = .{}, .requestFn = Capture.request };
    const response = try value.request(std.testing.allocator, .{ .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 0), response.parts.len);
    try std.testing.expectEqual(@as(usize, 1), capture.requests);
    try std.testing.expectError(error.StreamingNotSupported, value.stream(std.testing.allocator, .{ .messages = &.{} }, sink));
}

test "tool execution adapters preserve rich outputs" {
    const Executor = struct {
        fn output(_: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolOutput {
            return .{ .content = try allocator.dupe(u8, arguments_json) };
        }

        fn contextual(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: ToolRunContext,
            _: []const u8,
        ) !ToolOutput {
            return .{ .content = try std.fmt.allocPrint(allocator, "{d}", .{run_context.model_requests}) };
        }
    };
    var context: u8 = 0;
    const output_tool = Tool{
        .definition = .{ .name = "output", .description = "", .parameters_json_schema = "{}" },
        .context = &context,
        .executeOutputFn = Executor.output,
    };
    const plain = try output_tool.execute(std.testing.allocator, "\"result\"");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("\"result\"", plain);
    try std.testing.expectError(error.InvalidToolArguments, output_tool.execute(std.testing.allocator, "result"));
    const deeply_nested = "[" ** 65 ++ "0" ++ "]" ** 65;
    try std.testing.expectError(error.InvalidToolArguments, output_tool.execute(std.testing.allocator, deeply_nested));

    const contextual_tool = Tool{
        .definition = .{ .name = "contextual", .description = "", .parameters_json_schema = "{}" },
        .context = &context,
        .executeOutputWithContextFn = Executor.contextual,
    };
    const contextual = try contextual_tool.executeWithContext(
        std.testing.allocator,
        .{ .model_requests = 7 },
        "{}",
    );
    defer std.testing.allocator.free(contextual);
    try std.testing.expectEqualStrings("7", contextual);

    const rich = try contextual_tool.executeOutputWithContext(
        std.testing.allocator,
        .{ .model_requests = 9 },
        "{}",
    );
    defer std.testing.allocator.free(rich.content);
    try std.testing.expectEqualStrings("9", rich.content);

    const missing = Tool{
        .definition = .{ .name = "missing", .description = "", .parameters_json_schema = "{}" },
        .context = &context,
    };
    try std.testing.expectError(error.MissingToolExecutor, missing.execute(std.testing.allocator, "{}"));
    try std.testing.expectError(error.MissingToolExecutor, missing.executeWithContext(std.testing.allocator, .{}, "{}"));
}
