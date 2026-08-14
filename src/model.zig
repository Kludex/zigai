const std = @import("std");

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.seq_cst);
    }
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const Part = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    parts: []const Part,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json_schema: []const u8,
};

/// Application metadata carried with a tool and exposed to lifecycle hooks.
pub const ToolMetadata = struct {
    key: []const u8,
    value: []const u8,
};

pub const Tool = struct {
    definition: ToolDefinition,
    /// Metadata for application policy and observability; providers do not receive it.
    metadata: []const ToolMetadata = &.{},
    context: *anyopaque,
    /// Overrides `Agent.max_tool_retries` for this tool when non-null.
    max_retries: ?usize = null,
    validateFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        arguments_json: []const u8,
    ) anyerror!void = null,
    executeFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) anyerror![]const u8,
    executeWithContextFn: ?*const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_context: ToolRunContext,
        arguments_json: []const u8,
    ) anyerror![]const u8 = null,
    /// Classifies failures that are safe to show to the model for correction.
    /// By default, only allocation and cancellation failures are fatal.
    isRecoverableFn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    pub fn execute(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        return self.executeFn(self.context, allocator, arguments_json);
    }

    pub fn validate(self: Tool, allocator: std.mem.Allocator, arguments_json: []const u8) !void {
        const validate_arguments = self.validateFn orelse return;
        return validate_arguments(self.context, allocator, arguments_json);
    }

    pub fn executeWithContext(self: Tool, allocator: std.mem.Allocator, run_context: ToolRunContext, arguments_json: []const u8) ![]const u8 {
        const contextual = self.executeWithContextFn orelse return self.execute(allocator, arguments_json);
        return contextual(self.context, allocator, run_context, arguments_json);
    }

    /// Returns whether `failure` can be safely exposed to the model.
    pub fn isRecoverable(self: Tool, failure: anyerror) bool {
        if (self.isRecoverableFn) |classify| return classify(self.context, failure);
        return switch (failure) {
            error.OutOfMemory, error.Cancelled, error.RequestCancelled => false,
            else => true,
        };
    }
};

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

    pub const ReasoningEffortSet = std.EnumSet(ReasoningEffort);

    pub fn supportsReasoningEffort(self: ModelProfile, effort: ReasoningEffort) bool {
        return self.reasoning_efforts.contains(effort);
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

pub const ModelResponse = struct {
    parts: []const Part,
    usage: Usage = .{},
    /// Concrete provider identity, populated by `Model.request` when omitted by an adapter.
    provider_name: ?[]const u8 = null,
    /// Concrete model identity, populated by `Model.request` when omitted by an adapter.
    model_name: ?[]const u8 = null,
    /// Normalized termination category and the provider's original value.
    finish_reason: ?FinishReason = null,
};

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
