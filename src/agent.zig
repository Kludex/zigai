//! The provider-neutral agent loop and its owned buffered and typed results.

const std = @import("std");
const model_types = @import("model.zig");
const json_schema = @import("json_schema.zig");
const reflect = @import("reflect.zig");
const history = @import("history.zig");
const telemetry_types = @import("telemetry.zig");

const Message = model_types.Message;
const Part = model_types.Part;

const AgentError = error{
    Cancelled,
    ContentFiltered,
    DuplicateToolName,
    EmptyModelResponse,
    IncompleteToolCall,
    InputTokenLimitExceeded,
    InvalidTypedOutput,
    MaxModelRequestsExceeded,
    MaxToolCallsExceeded,
    ModelDoesNotSupportSystemMessages,
    ModelDoesNotSupportTools,
    ModelDoesNotSupportJsonObjectOutput,
    ModelDoesNotSupportJsonSchemaOutput,
    ModelDoesNotSupportMaxTokens,
    ModelDoesNotSupportReasoningEffort,
    ModelDoesNotSupportSeed,
    ModelDoesNotSupportStopSequences,
    ModelDoesNotSupportStreaming,
    ModelDoesNotSupportTemperature,
    ModelOutputTruncated,
    OutputTokenLimitExceeded,
    ParallelToolCallsNotSupported,
    ParallelToolCallsRequireIo,
    TotalTokenLimitExceeded,
    ToolConcurrencyUnavailable,
    ToolCallRequiresDeferredRun,
    MissingDeferredToolDecision,
    UnexpectedDeferredToolDecision,
    DeferredToolRequiresResult,
    InvalidDeferredState,
    UnknownTool,
    RetryBackoffRequiresIo,
};

const AgentUsageLimits = struct {
    max_model_requests: usize = 8,
    /// Maximum number of tool calls requested across the complete run.
    max_tool_calls: usize = 64,
    max_input_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    max_total_tokens: ?u64 = null,
};

const AgentBackoff = struct {
    initial_delay_ms: u64 = 250,
    maximum_delay_ms: u64 = 8_000,
    respect_retry_after: bool = true,
};

const AgentRetryPolicy = struct {
    max_retries: usize = 2,
    retry_rate_limits: bool = true,
    retry_server_errors: bool = true,
    retry_timeouts: bool = true,
    backoff: ?AgentBackoff = null,
    before_retry: ?RetryHook = null,
};

pub const CancellationToken = model_types.CancellationToken;

pub const RetryEvent = struct {
    failure: anyerror,
    retry_number: usize,
    model_requests: usize,
    retry_after_seconds: ?u64 = null,
    rate_limit_remaining_requests: ?u64 = null,
    rate_limit_remaining_tokens: ?u64 = null,
    delay_ms: u64 = 0,
};

pub const RetryHook = struct {
    context: *anyopaque,
    waitFn: *const fn (context: *anyopaque, event: RetryEvent) anyerror!void,

    pub fn wait(self: RetryHook, event: RetryEvent) !void {
        return self.waitFn(self.context, event);
    }
};

pub const AgentStreamEvent = union(enum) {
    model: model_types.ModelStreamEvent,
    tool_result: model_types.ToolResult,
    final_output: []const u8,
};

pub const AgentStreamSink = struct {
    context: *anyopaque,
    eventFn: *const fn (context: *anyopaque, event: AgentStreamEvent) anyerror!void,

    pub fn emit(self: AgentStreamSink, event: AgentStreamEvent) !void {
        return self.eventFn(self.context, event);
    }
};

const OutputValidator = struct {
    context: *anyopaque,
    validateFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, output: []const u8) anyerror!void,

    fn validate(self: OutputValidator, allocator: std.mem.Allocator, output: []const u8) !void {
        return self.validateFn(self.context, allocator, output);
    }
};

pub const InstructionContext = struct {
    dependencies: ?*anyopaque = null,
    prompt: []const u8,

    /// Recovers the application dependency type supplied by the agent or run.
    pub fn dependency(self: InstructionContext, comptime T: type) ?*T {
        const pointer = self.dependencies orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
};

/// A static instruction or a callback evaluated once at the start of a run.
pub const Instruction = union(enum) {
    text: []const u8,
    dynamic: Dynamic,

    pub const Dynamic = struct {
        context: *anyopaque,
        resolveFn: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: InstructionContext,
        ) anyerror![]const u8,

        pub fn resolve(
            self: Dynamic,
            allocator: std.mem.Allocator,
            run_context: InstructionContext,
        ) ![]const u8 {
            return self.resolveFn(self.context, allocator, run_context);
        }
    };
};

/// Values that apply only to one buffered or streaming run.
pub const RunOptions = struct {
    /// Earlier conversation messages. They are copied into the result arena.
    message_history: []const Message = &.{},
    /// Extra instructions appended after the agent's static and dynamic ones.
    instructions: []const []const u8 = &.{},
    /// Overrides agent dependencies when non-null.
    dependencies: ?*anyopaque = null,
    /// Highest-precedence generation settings for this run.
    model_settings: model_types.ModelSettings = .{},
    /// Extra provider-facing history processors applied after agent processors.
    history_processors: []const history.Processor = &.{},
};

pub const DeferredToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    execution: model_types.ToolExecution,
};

pub const ResumeAction = enum {
    approve,
    deny,
    result,
};

/// A serializable decision for one paused tool call. `content` is the denial
/// reason or externally produced result for `deny` and `result` actions.
pub const ResumeDecision = struct {
    call_id: []const u8,
    action: ResumeAction,
    content: ?[]const u8 = null,
    is_error: bool = false,
};

const SerializedResume = struct {
    version: u8 = 1,
    decisions: []const ResumeDecision,
};

pub fn stringifyResumeDecisions(
    allocator: std.mem.Allocator,
    decisions: []const ResumeDecision,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, SerializedResume{
        .decisions = decisions,
    }, .{});
}

pub const OwnedResumeDecisions = struct {
    arena: std.heap.ArenaAllocator,
    decisions: []const ResumeDecision,

    pub fn deinit(self: *OwnedResumeDecisions) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseResumeDecisions(
    allocator: std.mem.Allocator,
    source: []const u8,
) !OwnedResumeDecisions {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        SerializedResume,
        arena.allocator(),
        source,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch return Agent.Error.InvalidDeferredState;
    if (parsed.version != 1) return Agent.Error.InvalidDeferredState;
    return .{ .arena = arena, .decisions = parsed.decisions };
}

pub const PausedRun = struct {
    arena: std.heap.ArenaAllocator,
    state_json: []const u8,
    calls: []const DeferredToolCall,
    usage: model_types.Usage,
    model_requests: usize,

    pub fn deinit(self: *PausedRun) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const SerializedToolRetry = struct {
    name: []const u8,
    count: usize,
};

const SerializedPause = struct {
    version: u8,
    prompt: []const u8,
    history_json: []const u8,
    instructions: []const []const u8,
    usage: model_types.Usage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    tool_retries: []const SerializedToolRetry,
    calls: []const DeferredToolCall,
};

const ResumeState = struct {
    messages: []const Message,
    instructions: []const []const u8,
    usage: model_types.Usage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    tool_retries: []const SerializedToolRetry,
    calls: []const DeferredToolCall,
};

pub const CapabilityContext = struct {
    prompt: []const u8,
    dependencies: ?*anyopaque,
    model: model_types.Model,
};

/// Current run state available while preparing tools for the next model step.
pub const ToolsetContext = struct {
    messages: []const Message,
    usage: model_types.Usage,
    model_requests: usize,
    dependencies: ?*anyopaque,

    pub fn dependency(self: ToolsetContext, comptime T: type) ?*T {
        const pointer = self.dependencies orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
};

/// One prepared tool plus its step-specific availability and metadata.
pub const ToolsetEntry = struct {
    tool: model_types.Tool,
    enabled: bool = true,
    metadata: []const model_types.ToolMetadata = &.{},
};

/// A static tool collection or a collection prepared dynamically for each model step.
pub const Toolset = struct {
    tools: []const model_types.Tool = &.{},
    namespace: ?[]const u8 = null,
    metadata: []const model_types.ToolMetadata = &.{},
    context: ?*anyopaque = null,
    prepareFn: ?*const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        run: ToolsetContext,
        tools: []const model_types.Tool,
    ) anyerror![]const ToolsetEntry = null,

    pub fn prepare(self: Toolset, allocator: std.mem.Allocator, run: ToolsetContext) ![]const ToolsetEntry {
        const prepare_tools = self.prepareFn orelse {
            const entries = try allocator.alloc(ToolsetEntry, self.tools.len);
            for (self.tools, entries) |tool, *entry| entry.* = .{ .tool = tool };
            return entries;
        };
        return prepare_tools(self.context, allocator, run, self.tools);
    }
};

pub const LifecycleEvent = union(enum) {
    run_start: RunStart,
    run_end: RunEnd,
    run_error: RunError,
    model_request_start: ModelRequestStart,
    model_request_end: ModelRequestEnd,
    model_request_error: ModelRequestError,
    tool_validation_start: ToolValidationStart,
    tool_validation_end: ToolValidationEnd,
    tool_validation_error: ToolValidationError,
    tool_execution_start: ToolExecutionStart,
    tool_execution_end: ToolExecutionEnd,
    tool_execution_error: ToolExecutionError,
    output_validation_start: OutputValidationStart,
    output_validation_end: OutputValidationEnd,
    output_validation_error: OutputValidationError,
    stream_event: StreamEvent,

    pub const RunStart = struct {
        prompt: []const u8,
        model: model_types.Model,
    };

    pub const RunEnd = struct {
        output: []const u8,
        usage: model_types.Usage,
        model_requests: usize,
    };

    pub const RunError = struct { failure: anyerror };
    pub const ModelRequestStart = struct {
        number: usize,
        request: model_types.ModelRequest,
        streaming: bool,
    };
    pub const ModelRequestEnd = struct {
        number: usize,
        response: model_types.ModelResponse,
    };
    pub const ModelRequestError = struct {
        number: usize,
        failure: anyerror,
        will_retry: bool,
    };
    pub const ToolValidationStart = struct { call: model_types.ToolCall };
    pub const ToolValidationEnd = struct {
        call: model_types.ToolCall,
        tool: model_types.Tool,
    };
    pub const ToolValidationError = struct {
        call: model_types.ToolCall,
        failure: anyerror,
    };
    pub const ToolExecutionStart = struct {
        call: model_types.ToolCall,
        tool: model_types.Tool,
    };
    pub const ToolExecutionEnd = struct {
        call: model_types.ToolCall,
        content: []const u8,
    };
    pub const ToolExecutionError = struct {
        call: model_types.ToolCall,
        failure: anyerror,
        recoverable: bool,
    };
    pub const OutputValidationStart = struct {
        output: []const u8,
        retry_number: usize,
    };
    pub const OutputValidationEnd = struct {
        output: []const u8,
        retry_number: usize,
    };
    pub const OutputValidationError = struct {
        output: []const u8,
        failure: anyerror,
        retry_number: usize,
        will_retry: bool,
    };
    pub const StreamEvent = struct {
        stage: Stage,
        event: AgentStreamEvent,

        pub const Stage = enum { before, after };
    };
};

pub const LifecycleHook = struct {
    context: *anyopaque,
    eventFn: *const fn (context: *anyopaque, event: LifecycleEvent) anyerror!void,

    pub fn emit(self: LifecycleHook, event: LifecycleEvent) !void {
        return self.eventFn(self.context, event);
    }
};

/// A reusable feature bundle applied in `Agent.capabilities` order.
pub const Capability = struct {
    tools: []const model_types.Tool = &.{},
    toolsets: []const Toolset = &.{},
    instructions: []const Instruction = &.{},
    hooks: []const LifecycleHook = &.{},
    history_processors: []const history.Processor = &.{},
    model_settings: model_types.ModelSettings = .{},
    context: ?*anyopaque = null,
    selectModelFn: ?*const fn (context: ?*anyopaque, run: CapabilityContext) anyerror!model_types.Model = null,

    pub fn selectModel(self: Capability, run: CapabilityContext) !model_types.Model {
        const select = self.selectModelFn orelse return run.model;
        return select(self.context, run);
    }
};

/// An owned agent result whose JSON response has been decoded as `Output`.
///
/// `output`, `output_json`, and `messages` may all reference the result arena.
/// Call `deinit` exactly once when none of them are needed anymore.
pub fn TypedResult(comptime Output: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        output: Output,
        output_json: []const u8,
        messages: []const Message,
        usage: model_types.Usage,
        model_requests: usize,
        finish_reason: ?model_types.FinishReason,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const Agent = struct {
    model: model_types.Model,
    capabilities: []const Capability = &.{},
    hooks: []const LifecycleHook = &.{},
    tools: []const model_types.Tool = &.{},
    toolsets: []const Toolset = &.{},
    history_processors: []const history.Processor = &.{},
    system_prompt: ?[]const u8 = null,
    instructions: []const Instruction = &.{},
    output: model_types.OutputFormat = .text,
    /// Re-check structured provider output locally before returning it. This is
    /// intentionally opt-in because JSON Schema support is a documented subset.
    validate_output_locally: bool = false,
    /// Number of invalid final responses returned to the model for correction.
    max_output_retries: usize = 2,
    /// Default number of failures returned to the model for each tool.
    max_tool_retries: usize = 2,
    /// Overrides model defaults for every run of this agent.
    model_settings: model_types.ModelSettings = .{},
    limits: UsageLimits = .{},
    retry_policy: RetryPolicy = .{},
    provider_error_observer: ?model_types.ProviderErrorObserver = null,
    dependencies: ?*anyopaque = null,
    cancellation: ?*const CancellationToken = null,
    request_timeout_ms: ?u64 = null,
    io: ?std.Io = null,
    /// Optional per-run OpenTelemetry spans and metrics.
    telemetry: ?telemetry_types.OpenTelemetry = null,

    pub const UsageLimits = AgentUsageLimits;
    pub const RetryPolicy = AgentRetryPolicy;
    pub const Backoff = AgentBackoff;

    pub const Error = AgentError;

    pub const Result = struct {
        arena: std.heap.ArenaAllocator,
        output: []const u8,
        messages: []const Message,
        usage: model_types.Usage,
        model_requests: usize,
        finish_reason: ?model_types.FinishReason,

        pub fn deinit(self: *Result) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub const RunOutcome = union(enum) {
        complete: Result,
        paused: PausedRun,

        pub fn deinit(self: *RunOutcome) void {
            switch (self.*) {
                .complete => |*result| result.deinit(),
                .paused => |*paused| paused.deinit(),
            }
            self.* = undefined;
        }
    };

    pub fn run(self: Agent, allocator: std.mem.Allocator, prompt: []const u8) !Result {
        return self.runWithOptions(allocator, prompt, .{});
    }

    /// Derives a strict JSON Schema from `Output`, requests it from the model,
    /// and decodes the final response into an owned typed result.
    pub fn runTyped(
        self: Agent,
        comptime Output: type,
        allocator: std.mem.Allocator,
        prompt: []const u8,
    ) !TypedResult(Output) {
        return self.runTypedWithOptions(Output, allocator, prompt, .{});
    }

    /// Runs a typed request with history, run-specific instructions, or dependencies.
    pub fn runTypedWithOptions(
        self: Agent,
        comptime Output: type,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
    ) !TypedResult(Output) {
        const configured = withTypedOutput(self, Output);
        return decodeTypedResult(Output, try configured.runResultInternal(
            allocator,
            prompt,
            options,
            null,
            typedOutputValidator(Output),
        ));
    }

    /// Runs with message history, run-specific instructions, or dependencies.
    pub fn runWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
    ) !Result {
        return self.runResultInternal(allocator, prompt, options, null, null);
    }

    /// Runs until final output or a tool needs approval or external execution.
    pub fn runUntilPause(self: Agent, allocator: std.mem.Allocator, prompt: []const u8) !RunOutcome {
        return self.runUntilPauseWithOptions(allocator, prompt, .{});
    }

    pub fn runUntilPauseWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
    ) !RunOutcome {
        return self.runOutcomeInternal(allocator, prompt, options, null, null, true, null, &.{});
    }

    /// Continues a serialized paused run. Decisions must cover every paused
    /// approval or external tool call exactly once.
    pub fn resumeRun(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions: []const ResumeDecision,
    ) !RunOutcome {
        return self.resumeRunWithOptions(allocator, state_json, decisions, .{});
    }

    pub fn resumeRunJson(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions_json: []const u8,
    ) !RunOutcome {
        var decisions = try parseResumeDecisions(allocator, decisions_json);
        defer decisions.deinit();
        return self.resumeRun(allocator, state_json, decisions.decisions);
    }

    pub fn resumeRunWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions: []const ResumeDecision,
        options: RunOptions,
    ) !RunOutcome {
        const parsed = std.json.parseFromSlice(SerializedPause, allocator, state_json, .{
            .ignore_unknown_fields = false,
        }) catch return Error.InvalidDeferredState;
        defer parsed.deinit();
        if (parsed.value.version != 1) return Error.InvalidDeferredState;
        var owned_history = history.parse(allocator, parsed.value.history_json) catch
            return Error.InvalidDeferredState;
        defer owned_history.deinit();
        return self.runOutcomeInternal(
            allocator,
            parsed.value.prompt,
            options,
            null,
            null,
            true,
            .{
                .messages = owned_history.messages,
                .instructions = parsed.value.instructions,
                .usage = parsed.value.usage,
                .model_requests = parsed.value.model_requests,
                .total_tool_calls = parsed.value.total_tool_calls,
                .output_retries = parsed.value.output_retries,
                .tool_retries = parsed.value.tool_retries,
                .calls = parsed.value.calls,
            },
            decisions,
        );
    }

    pub fn runStream(self: Agent, allocator: std.mem.Allocator, prompt: []const u8, sink: AgentStreamSink) !Result {
        return self.runStreamWithOptions(allocator, prompt, .{}, sink);
    }

    /// Streams a typed request and returns the decoded, arena-owned result.
    pub fn runTypedStream(
        self: Agent,
        comptime Output: type,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        sink: AgentStreamSink,
    ) !TypedResult(Output) {
        return self.runTypedStreamWithOptions(Output, allocator, prompt, .{}, sink);
    }

    /// Streams a typed request with history, instructions, or dependencies.
    pub fn runTypedStreamWithOptions(
        self: Agent,
        comptime Output: type,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        sink: AgentStreamSink,
    ) !TypedResult(Output) {
        const configured = withTypedOutput(self, Output);
        return decodeTypedResult(Output, try configured.runResultInternal(
            allocator,
            prompt,
            options,
            sink,
            typedOutputValidator(Output),
        ));
    }

    /// Streams a run with message history, run-specific instructions, or dependencies.
    pub fn runStreamWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        sink: AgentStreamSink,
    ) !Result {
        return self.runResultInternal(allocator, prompt, options, sink, null);
    }

    fn runResultInternal(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        stream_sink: ?AgentStreamSink,
        output_validator: ?OutputValidator,
    ) !Result {
        const outcome = try self.runOutcomeInternal(
            allocator,
            prompt,
            options,
            stream_sink,
            output_validator,
            false,
            null,
            &.{},
        );
        return switch (outcome) {
            .complete => |result| result,
            .paused => |paused_value| {
                var paused = paused_value;
                paused.deinit();
                return Error.ToolCallRequiresDeferredRun;
            },
        };
    }

    fn runOutcomeInternal(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        stream_sink: ?AgentStreamSink,
        output_validator: ?OutputValidator,
        allow_pause: bool,
        resume_state: ?ResumeState,
        decisions: []const ResumeDecision,
    ) !RunOutcome {
        var telemetry_run: ?telemetry_types.Run = if (self.telemetry) |configured|
            configured.start(allocator)
        else
            null;
        defer if (telemetry_run) |*instrumentation| instrumentation.deinit();

        if (self.capabilities.len == 0) {
            try ensureUniqueToolNames(self.tools);
            var hooks: std.ArrayList(LifecycleHook) = .empty;
            defer hooks.deinit(allocator);
            try hooks.appendSlice(allocator, self.hooks);
            if (telemetry_run) |*instrumentation| try hooks.append(allocator, telemetryHook(instrumentation));
            return self.runConfigured(allocator, prompt, options, stream_sink, output_validator, hooks.items, allow_pause, resume_state, decisions) catch |err| {
                try emitLifecycle(hooks.items, .{ .run_error = .{ .failure = err } });
                return err;
            };
        }
        var tools: std.ArrayList(model_types.Tool) = .empty;
        defer tools.deinit(allocator);
        try tools.appendSlice(allocator, self.tools);
        var instructions: std.ArrayList(Instruction) = .empty;
        defer instructions.deinit(allocator);
        try instructions.appendSlice(allocator, self.instructions);
        var toolsets: std.ArrayList(Toolset) = .empty;
        defer toolsets.deinit(allocator);
        try toolsets.appendSlice(allocator, self.toolsets);
        var hooks: std.ArrayList(LifecycleHook) = .empty;
        defer hooks.deinit(allocator);
        try hooks.appendSlice(allocator, self.hooks);
        var history_processors: std.ArrayList(history.Processor) = .empty;
        defer history_processors.deinit(allocator);
        try history_processors.appendSlice(allocator, self.history_processors);

        const dependencies = options.dependencies orelse self.dependencies;
        var model = self.model;
        var capability_settings: model_types.ModelSettings = .{};
        for (self.capabilities) |capability| {
            try tools.appendSlice(allocator, capability.tools);
            try toolsets.appendSlice(allocator, capability.toolsets);
            try instructions.appendSlice(allocator, capability.instructions);
            try hooks.appendSlice(allocator, capability.hooks);
            try history_processors.appendSlice(allocator, capability.history_processors);
            capability_settings = capability_settings.overrideWith(capability.model_settings);
            model = try capability.selectModel(.{
                .prompt = prompt,
                .dependencies = dependencies,
                .model = model,
            });
        }
        try ensureUniqueToolNames(tools.items);

        var configured = self;
        configured.model = model;
        configured.tools = tools.items;
        configured.toolsets = toolsets.items;
        configured.instructions = instructions.items;
        configured.history_processors = history_processors.items;
        configured.model_settings = capability_settings.overrideWith(self.model_settings);
        configured.capabilities = &.{};
        if (telemetry_run) |*instrumentation| try hooks.append(allocator, telemetryHook(instrumentation));
        return configured.runConfigured(allocator, prompt, options, stream_sink, output_validator, hooks.items, allow_pause, resume_state, decisions) catch |err| {
            try emitLifecycle(hooks.items, .{ .run_error = .{ .failure = err } });
            return err;
        };
    }

    fn runConfigured(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        stream_sink: ?AgentStreamSink,
        output_validator: ?OutputValidator,
        hooks: []const LifecycleHook,
        allow_pause: bool,
        resume_state: ?ResumeState,
        decisions: []const ResumeDecision,
    ) !RunOutcome {
        try checkCancellation(self.cancellation);
        if (stream_sink != null and !self.model.profile.supports_streaming) return Error.ModelDoesNotSupportStreaming;
        if (self.system_prompt != null and !self.model.profile.supports_system_messages) {
            return Error.ModelDoesNotSupportSystemMessages;
        }
        switch (self.output) {
            .text => {},
            .json_object => try requireCapability(
                self.model.profile.supports_json_object_output,
                Error.ModelDoesNotSupportJsonObjectOutput,
            ),
            .json_schema => try requireCapability(
                self.model.profile.supports_json_schema_output,
                Error.ModelDoesNotSupportJsonSchemaOutput,
            ),
        }
        const resolved_settings = self.model.settings.overrideWith(self.model_settings).overrideWith(options.model_settings);
        try requireModelSettings(self.model.profile, resolved_settings);
        try emitLifecycle(hooks, .{ .run_start = .{ .prompt = prompt, .model = self.model } });

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();

        const dependencies = options.dependencies orelse self.dependencies;
        const resolved_instructions = if (resume_state) |state|
            try copyStrings(memory, state.instructions)
        else
            try resolveInstructions(memory, self.instructions, options.instructions, .{
                .dependencies = dependencies,
                .prompt = prompt,
            });
        if (resolved_instructions.len > 0 and !self.model.profile.supports_system_messages) {
            return Error.ModelDoesNotSupportSystemMessages;
        }

        var messages: std.ArrayList(Message) = .empty;
        var definitions: std.ArrayList(model_types.ToolDefinition) = .empty;
        var total_usage: model_types.Usage = if (resume_state) |state| state.usage else .{};
        var provider_errors = ProviderErrorCapture{ .target = self.provider_error_observer };
        var tool_retries = ToolRetryTracker{ .allocator = memory };

        if (resume_state) |state| {
            for (state.messages) |message| try appendMessageCopy(memory, &messages, message);
            try tool_retries.restore(state.tool_retries);
        } else {
            if (self.system_prompt) |system_prompt| {
                try appendTextMessage(memory, &messages, .system, system_prompt);
            }
            for (options.message_history) |message| try appendMessageCopy(memory, &messages, message);
            try appendTextMessage(memory, &messages, .user, prompt);
        }

        var model_requests: usize = if (resume_state) |state| state.model_requests else 0;
        var output_retries: usize = if (resume_state) |state| state.output_retries else 0;
        var total_tool_calls: usize = if (resume_state) |state| state.total_tool_calls else 0;
        var resume_pending = resume_state != null;
        while (true) {
            const available_tools = try prepareTools(memory, self.tools, self.toolsets, .{
                .messages = messages.items,
                .usage = total_usage,
                .model_requests = model_requests,
                .dependencies = dependencies,
            });
            try ensureUniqueToolNames(available_tools);
            if (available_tools.len > 0 and !self.model.profile.supports_tools) {
                return Error.ModelDoesNotSupportTools;
            }
            if (resume_pending) {
                const result_parts = try executeResumedToolCalls(
                    self,
                    available_tools,
                    memory,
                    messages.items,
                    decisions,
                    resume_state.?.calls,
                    &tool_retries,
                    .{
                        .dependencies = dependencies,
                        .usage = total_usage,
                        .model_requests = model_requests,
                        .cancellation = self.cancellation,
                        .io = self.io,
                    },
                    hooks,
                );
                try messages.append(memory, .{ .role = .tool, .parts = result_parts });
                resume_pending = false;
                continue;
            }
            definitions.clearRetainingCapacity();
            for (available_tools) |tool| try definitions.append(memory, tool.definition);
            const history_context = history.Context{
                .profile = self.model.profile,
                .usage = total_usage,
                .model_requests = model_requests,
            };
            var request_messages = try history.processAll(
                memory,
                self.history_processors,
                history_context,
                messages.items,
            );
            request_messages = try history.processAll(
                memory,
                options.history_processors,
                history_context,
                request_messages,
            );
            var retries: usize = 0;
            const response = request: while (true) {
                try checkCancellation(self.cancellation);
                if (model_requests >= self.limits.max_model_requests) {
                    return Error.MaxModelRequestsExceeded;
                }
                model_requests += 1;
                provider_errors.reset();
                var stream_emitted = false;
                var forwarder = ModelEventForwarder{
                    .sink = stream_sink,
                    .emitted = &stream_emitted,
                    .hooks = hooks,
                };
                const model_request = model_types.ModelRequest{
                    .messages = request_messages,
                    .instructions = resolved_instructions,
                    .tools = definitions.items,
                    .output = self.output,
                    .error_observer = provider_errors.observer(),
                    .timeout_ms = self.request_timeout_ms,
                    .cancellation = self.cancellation,
                    .settings = resolved_settings,
                };
                try emitLifecycle(hooks, .{ .model_request_start = .{
                    .number = model_requests,
                    .request = model_request,
                    .streaming = stream_sink != null,
                } });
                break :request (if (stream_sink != null)
                    self.model.stream(memory, model_request, forwarder.modelSink())
                else
                    self.model.request(memory, model_request)) catch |err| {
                    const will_retry = !stream_emitted and retries < self.retry_policy.max_retries and
                        shouldRetry(err, self.retry_policy);
                    try emitLifecycle(hooks, .{ .model_request_error = .{
                        .number = model_requests,
                        .failure = err,
                        .will_retry = will_retry,
                    } });
                    if (err == error.RequestCancelled) return Error.Cancelled;
                    if (will_retry) {
                        retries += 1;
                        const delay_ms = if (self.retry_policy.backoff) |backoff|
                            backoffDelayMilliseconds(backoff, retries, provider_errors.retry_after_seconds)
                        else
                            0;
                        if (self.retry_policy.before_retry) |hook| try hook.wait(.{
                            .failure = err,
                            .retry_number = retries,
                            .model_requests = model_requests,
                            .retry_after_seconds = provider_errors.retry_after_seconds,
                            .rate_limit_remaining_requests = provider_errors.rate_limit_remaining_requests,
                            .rate_limit_remaining_tokens = provider_errors.rate_limit_remaining_tokens,
                            .delay_ms = delay_ms,
                        });
                        if (self.retry_policy.backoff != null) {
                            const io = self.io orelse return Error.RetryBackoffRequiresIo;
                            try sleepBackoff(io, delay_ms, self.cancellation);
                        }
                        continue;
                    }
                    return err;
                };
            };
            try emitLifecycle(hooks, .{ .model_request_end = .{
                .number = model_requests,
                .response = response,
            } });
            total_usage.add(response.usage);
            try enforceUsageLimits(total_usage, self.limits);
            try enforceFinishReason(response.finish_reason);
            if (response.parts.len == 0) return Error.EmptyModelResponse;

            try messages.append(memory, .{ .role = .assistant, .parts = response.parts });

            var tool_call_count: usize = 0;
            for (response.parts) |part| switch (part) {
                .tool_call => tool_call_count += 1,
                else => {},
            };

            if (tool_call_count == 0) {
                const output = try collectText(memory, response.parts);
                try emitLifecycle(hooks, .{ .output_validation_start = .{
                    .output = output,
                    .retry_number = output_retries,
                } });
                validateFinalOutput(self, memory, output, output_validator) catch |err| {
                    const will_retry = err != error.OutOfMemory and output_retries < self.max_output_retries;
                    try emitLifecycle(hooks, .{ .output_validation_error = .{
                        .output = output,
                        .failure = err,
                        .retry_number = output_retries,
                        .will_retry = will_retry,
                    } });
                    if (err == error.OutOfMemory) return err;
                    if (!will_retry) return err;
                    output_retries += 1;
                    try appendTextMessage(memory, &messages, .user, "The previous response did not match the required output schema. " ++
                        "Return only valid JSON matching the schema.");
                    continue;
                };
                try emitLifecycle(hooks, .{ .output_validation_end = .{
                    .output = output,
                    .retry_number = output_retries,
                } });
                if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{ .final_output = output });
                try emitLifecycle(hooks, .{ .run_end = .{
                    .output = output,
                    .usage = total_usage,
                    .model_requests = model_requests,
                } });
                return .{ .complete = .{
                    .arena = arena,
                    .output = output,
                    .messages = try messages.toOwnedSlice(memory),
                    .usage = total_usage,
                    .model_requests = model_requests,
                    .finish_reason = response.finish_reason,
                } };
            }
            if (tool_call_count > self.limits.max_tool_calls -| total_tool_calls) {
                return Error.MaxToolCallsExceeded;
            }
            total_tool_calls += tool_call_count;
            if (!self.model.profile.supports_tools) return Error.ModelDoesNotSupportTools;
            if (tool_call_count > 1 and !self.model.profile.supports_parallel_tool_calls) {
                return Error.ParallelToolCallsNotSupported;
            }
            if (hasDeferredToolCall(available_tools, response.parts)) {
                if (!allow_pause) return Error.ToolCallRequiresDeferredRun;
                return .{ .paused = try createPausedRun(
                    &arena,
                    memory,
                    prompt,
                    messages.items,
                    resolved_instructions,
                    total_usage,
                    model_requests,
                    total_tool_calls,
                    output_retries,
                    tool_retries.entries.items,
                    available_tools,
                    response.parts,
                ) };
            }

            const result_parts = try executeToolCalls(
                self,
                available_tools,
                memory,
                response.parts,
                tool_call_count,
                &tool_retries,
                .{
                    .dependencies = dependencies,
                    .usage = total_usage,
                    .model_requests = model_requests,
                    .cancellation = self.cancellation,
                    .io = self.io,
                },
                hooks,
            );
            if (stream_sink) |sink| for (result_parts) |part| {
                try emitStreamEvent(hooks, sink, .{ .tool_result = part.tool_result });
            };
            try messages.append(memory, .{ .role = .tool, .parts = result_parts });
        }
    }
};

fn copyStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const copied = try allocator.alloc([]const u8, values.len);
    for (values, copied) |value, *target| target.* = try allocator.dupe(u8, value);
    return copied;
}

fn hasDeferredToolCall(tools: []const model_types.Tool, parts: []const Part) bool {
    for (parts) |part| switch (part) {
        .tool_call => |call| {
            const tool = findTool(tools, call.name) orelse continue;
            if (tool.execution != .immediate) return true;
        },
        else => {},
    };
    return false;
}

fn createPausedRun(
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    messages: []const Message,
    instructions: []const []const u8,
    usage: model_types.Usage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    retry_entries: []const ToolRetryTracker.Entry,
    tools: []const model_types.Tool,
    parts: []const Part,
) !PausedRun {
    var calls: std.ArrayList(DeferredToolCall) = .empty;
    for (parts) |part| switch (part) {
        .tool_call => |call| {
            const tool = findTool(tools, call.name) orelse continue;
            if (tool.execution == .immediate) continue;
            try calls.append(allocator, .{
                .call_id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments_json = try allocator.dupe(u8, call.arguments_json),
                .execution = tool.execution,
            });
        },
        else => {},
    };
    const paused_calls = try calls.toOwnedSlice(allocator);
    const retries = try allocator.alloc(SerializedToolRetry, retry_entries.len);
    for (retry_entries, retries) |entry, *retry| retry.* = .{
        .name = entry.name,
        .count = entry.count,
    };
    const history_json = try history.stringify(allocator, messages);
    const state_json = try std.json.Stringify.valueAlloc(allocator, SerializedPause{
        .version = 1,
        .prompt = prompt,
        .history_json = history_json,
        .instructions = instructions,
        .usage = usage,
        .model_requests = model_requests,
        .total_tool_calls = total_tool_calls,
        .output_retries = output_retries,
        .tool_retries = retries,
        .calls = paused_calls,
    }, .{});
    return .{
        .arena = arena.*,
        .state_json = state_json,
        .calls = paused_calls,
        .usage = usage,
        .model_requests = model_requests,
    };
}

fn executeResumedToolCalls(
    agent: Agent,
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    messages: []const Message,
    decisions: []const ResumeDecision,
    saved_calls: []const DeferredToolCall,
    tool_retries: *ToolRetryTracker,
    run_context: model_types.ToolRunContext,
    hooks: []const LifecycleHook,
) ![]Part {
    if (messages.len == 0) return Agent.Error.InvalidDeferredState;
    const assistant = messages[messages.len - 1];
    if (assistant.role != .assistant) return Agent.Error.InvalidDeferredState;
    var call_count: usize = 0;
    for (assistant.parts) |part| switch (part) {
        .tool_call => call_count += 1,
        else => {},
    };
    if (call_count == 0) return Agent.Error.InvalidDeferredState;
    try validateDeferredCalls(tools, assistant.parts, saved_calls);

    for (decisions, 0..) |decision, index| {
        for (decisions[index + 1 ..]) |other| {
            if (std.mem.eql(u8, decision.call_id, other.call_id)) return Agent.Error.UnexpectedDeferredToolDecision;
        }
        var found = false;
        for (assistant.parts) |part| switch (part) {
            .tool_call => |call| if (std.mem.eql(u8, call.id, decision.call_id)) {
                const tool = findTool(tools, call.name) orelse return Agent.Error.UnknownTool;
                found = tool.execution != .immediate;
            },
            else => {},
        };
        if (!found) return Agent.Error.UnexpectedDeferredToolDecision;
    }

    const results = try allocator.alloc(Part, call_count);
    var result_index: usize = 0;
    for (assistant.parts) |part| switch (part) {
        .tool_call => |call| {
            const tool_index = findToolIndex(tools, call.name) orelse return Agent.Error.UnknownTool;
            const tool = tools[tool_index];
            try emitLifecycle(hooks, .{ .tool_validation_start = .{ .call = call } });
            tool.validate(allocator, call.arguments_json) catch |failure| {
                try emitLifecycle(hooks, .{ .tool_validation_error = .{ .call = call, .failure = failure } });
                const work = ToolWork{ .call = call, .tool_index = tool_index, .validation_failure = failure };
                results[result_index] = .{ .tool_result = try toolResult(
                    agent,
                    tools,
                    allocator,
                    work,
                    tool_retries,
                    .{ .failure = failure },
                ) };
                result_index += 1;
                continue;
            };
            try emitLifecycle(hooks, .{ .tool_validation_end = .{ .call = call, .tool = tool } });

            const decision = findResumeDecision(decisions, call.id);
            switch (tool.execution) {
                .immediate => {
                    try emitLifecycle(hooks, .{ .tool_execution_start = .{ .call = call, .tool = tool } });
                    const outcome = executeTool(tool, allocator, run_context, call.arguments_json);
                    try emitToolOutcome(hooks, tool, call, outcome);
                    results[result_index] = .{ .tool_result = try toolResult(
                        agent,
                        tools,
                        allocator,
                        .{ .call = call, .tool_index = tool_index },
                        tool_retries,
                        outcome,
                    ) };
                },
                .requires_approval => {
                    const approved = decision orelse return Agent.Error.MissingDeferredToolDecision;
                    switch (approved.action) {
                        .approve => {
                            try emitLifecycle(hooks, .{ .tool_execution_start = .{ .call = call, .tool = tool } });
                            const outcome = executeTool(tool, allocator, run_context, call.arguments_json);
                            try emitToolOutcome(hooks, tool, call, outcome);
                            results[result_index] = .{ .tool_result = try toolResult(
                                agent,
                                tools,
                                allocator,
                                .{ .call = call, .tool_index = tool_index },
                                tool_retries,
                                outcome,
                            ) };
                        },
                        .deny => results[result_index] = .{ .tool_result = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = approved.content orelse "Tool call denied by reviewer.",
                            .is_error = true,
                        } },
                        .result => results[result_index] = .{ .tool_result = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = approved.content orelse "",
                            .is_error = approved.is_error,
                        } },
                    }
                },
                .external => {
                    const supplied = decision orelse return Agent.Error.MissingDeferredToolDecision;
                    switch (supplied.action) {
                        .approve => return Agent.Error.DeferredToolRequiresResult,
                        .deny => results[result_index] = .{ .tool_result = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = supplied.content orelse "Tool call denied by reviewer.",
                            .is_error = true,
                        } },
                        .result => results[result_index] = .{ .tool_result = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = supplied.content orelse "",
                            .is_error = supplied.is_error,
                        } },
                    }
                },
            }
            result_index += 1;
        },
        else => {},
    };
    return results;
}

fn validateDeferredCalls(
    tools: []const model_types.Tool,
    parts: []const Part,
    saved_calls: []const DeferredToolCall,
) !void {
    var saved_index: usize = 0;
    for (parts) |part| switch (part) {
        .tool_call => |call| {
            const tool = findTool(tools, call.name) orelse return Agent.Error.UnknownTool;
            if (tool.execution == .immediate) continue;
            if (saved_index >= saved_calls.len) return Agent.Error.InvalidDeferredState;
            const saved = saved_calls[saved_index];
            if (!std.mem.eql(u8, saved.call_id, call.id) or
                !std.mem.eql(u8, saved.name, call.name) or
                !std.mem.eql(u8, saved.arguments_json, call.arguments_json) or
                saved.execution != tool.execution)
            {
                return Agent.Error.InvalidDeferredState;
            }
            saved_index += 1;
        },
        else => {},
    };
    if (saved_index != saved_calls.len) return Agent.Error.InvalidDeferredState;
}

fn findResumeDecision(decisions: []const ResumeDecision, call_id: []const u8) ?ResumeDecision {
    for (decisions) |decision| {
        if (std.mem.eql(u8, decision.call_id, call_id)) return decision;
    }
    return null;
}

fn withTypedOutput(agent: Agent, comptime Output: type) Agent {
    var configured = agent;
    configured.output = .{ .json_schema = .{
        .name = "response",
        .schema = reflect.schemaOf(Output),
    } };
    return configured;
}

fn typedOutputValidator(comptime Output: type) OutputValidator {
    const Wrapper = struct {
        var placeholder: u8 = 0;

        fn validate(_: *anyopaque, allocator: std.mem.Allocator, output: []const u8) !void {
            _ = std.json.parseFromSliceLeaky(Output, allocator, output, .{
                .ignore_unknown_fields = false,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => Agent.Error.InvalidTypedOutput,
            };
        }
    };
    return .{ .context = &Wrapper.placeholder, .validateFn = Wrapper.validate };
}

fn validateFinalOutput(
    agent: Agent,
    allocator: std.mem.Allocator,
    output: []const u8,
    output_validator: ?OutputValidator,
) !void {
    if (agent.validate_output_locally) try json_schema.validate(allocator, agent.output, output);
    if (output_validator) |validator| try validator.validate(allocator, output);
}

fn decodeTypedResult(comptime Output: type, untyped: Agent.Result) !TypedResult(Output) {
    var owned = untyped;
    errdefer owned.deinit();
    const output = std.json.parseFromSliceLeaky(Output, owned.arena.allocator(), owned.output, .{
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Agent.Error.InvalidTypedOutput,
    };
    return .{
        .arena = owned.arena,
        .output = output,
        .output_json = owned.output,
        .messages = owned.messages,
        .usage = owned.usage,
        .model_requests = owned.model_requests,
        .finish_reason = owned.finish_reason,
    };
}

const ToolWork = struct {
    call: model_types.ToolCall,
    tool_index: usize,
    validation_failure: ?anyerror = null,
};

const ToolOutcome = union(enum) {
    success: []const u8,
    failure: anyerror,
};

const ExecutedTool = struct {
    content: []const u8,
    is_error: bool,
};

fn executeToolCalls(
    agent: Agent,
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    response_parts: []const Part,
    call_count: usize,
    tool_retries: *ToolRetryTracker,
    run_context: model_types.ToolRunContext,
    hooks: []const LifecycleHook,
) ![]Part {
    const work = try allocator.alloc(ToolWork, call_count);
    var work_index: usize = 0;
    for (response_parts) |part| switch (part) {
        .tool_call => |call| {
            try emitLifecycle(hooks, .{ .tool_validation_start = .{ .call = call } });
            const tool_index = findToolIndex(tools, call.name) orelse {
                try emitLifecycle(hooks, .{ .tool_validation_error = .{
                    .call = call,
                    .failure = Agent.Error.UnknownTool,
                } });
                return Agent.Error.UnknownTool;
            };
            work[work_index] = .{
                .call = call,
                .tool_index = tool_index,
            };
            tools[tool_index].validate(allocator, call.arguments_json) catch |err| {
                work[work_index].validation_failure = err;
                try emitLifecycle(hooks, .{ .tool_validation_error = .{
                    .call = call,
                    .failure = err,
                } });
                work_index += 1;
                continue;
            };
            try emitLifecycle(hooks, .{ .tool_validation_end = .{
                .call = call,
                .tool = tools[tool_index],
            } });
            work_index += 1;
        },
        else => {},
    };

    const result_parts = try allocator.alloc(Part, call_count);
    if (call_count == 1) {
        try checkCancellation(agent.cancellation);
        const outcome: ToolOutcome = if (work[0].validation_failure) |failure|
            .{ .failure = failure }
        else execute: {
            try emitLifecycle(hooks, .{ .tool_execution_start = .{
                .call = work[0].call,
                .tool = tools[work[0].tool_index],
            } });
            const executed = executeTool(
                tools[work[0].tool_index],
                allocator,
                run_context,
                work[0].call.arguments_json,
            );
            try emitToolOutcome(hooks, tools[work[0].tool_index], work[0].call, executed);
            break :execute executed;
        };
        result_parts[0] = .{ .tool_result = try toolResult(
            agent,
            tools,
            allocator,
            work[0],
            tool_retries,
            outcome,
        ) };
        return result_parts;
    }

    const io = agent.io orelse return Agent.Error.ParallelToolCallsRequireIo;
    var locked_allocator = LockedAllocator{ .child = allocator, .io = io };
    const concurrent_allocator = locked_allocator.allocator();
    const futures = try allocator.alloc(?std.Io.Future(ToolOutcome), call_count);
    @memset(futures, null);
    const outcomes = try allocator.alloc(ToolOutcome, call_count);
    var spawned: usize = 0;
    while (spawned < call_count) : (spawned += 1) {
        const item = work[spawned];
        if (item.validation_failure) |failure| {
            outcomes[spawned] = .{ .failure = failure };
            continue;
        }
        try emitLifecycle(hooks, .{ .tool_execution_start = .{
            .call = item.call,
            .tool = tools[item.tool_index],
        } });
        futures[spawned] = io.concurrent(executeTool, .{
            tools[item.tool_index],
            concurrent_allocator,
            run_context,
            item.call.arguments_json,
        }) catch {
            for (futures[0..spawned]) |*slot| {
                if (slot.*) |*future| _ = future.cancel(io);
            }
            return Agent.Error.ToolConcurrencyUnavailable;
        };
    }

    var awaited: usize = 0;
    errdefer {
        for (futures[awaited..]) |*slot| {
            if (slot.*) |*future| _ = future.cancel(io);
        }
    }
    while (awaited < call_count) {
        try checkCancellation(agent.cancellation);
        if (futures[awaited]) |*future| {
            outcomes[awaited] = future.await(io);
            try emitToolOutcome(
                hooks,
                tools[work[awaited].tool_index],
                work[awaited].call,
                outcomes[awaited],
            );
        }
        if (outcomes[awaited] == .failure and
            !tools[work[awaited].tool_index].isRecoverable(outcomes[awaited].failure))
        {
            return outcomes[awaited].failure;
        }
        awaited += 1;
    }
    try checkCancellation(agent.cancellation);
    for (work, outcomes, result_parts) |item, outcome, *result_part| {
        result_part.* = .{ .tool_result = try toolResult(
            agent,
            tools,
            allocator,
            item,
            tool_retries,
            outcome,
        ) };
    }
    return result_parts;
}

fn emitToolOutcome(
    hooks: []const LifecycleHook,
    tool: model_types.Tool,
    call: model_types.ToolCall,
    outcome: ToolOutcome,
) !void {
    switch (outcome) {
        .success => |content| try emitLifecycle(hooks, .{ .tool_execution_end = .{
            .call = call,
            .content = content,
        } }),
        .failure => |failure| try emitLifecycle(hooks, .{ .tool_execution_error = .{
            .call = call,
            .failure = failure,
            .recoverable = tool.isRecoverable(failure),
        } }),
    }
}

fn executeTool(
    tool: model_types.Tool,
    allocator: std.mem.Allocator,
    run_context: model_types.ToolRunContext,
    arguments_json: []const u8,
) ToolOutcome {
    checkCancellation(run_context.cancellation) catch |err| return .{ .failure = err };
    const content = tool.executeWithContext(allocator, run_context, arguments_json) catch |err| {
        return .{ .failure = err };
    };
    return .{ .success = content };
}

fn toolResult(
    agent: Agent,
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    work: ToolWork,
    tool_retries: *ToolRetryTracker,
    outcome: ToolOutcome,
) !model_types.ToolResult {
    const tool = tools[work.tool_index];
    const executed: ExecutedTool = switch (outcome) {
        .success => |content| .{ .content = content, .is_error = false },
        .failure => |failure| recover: {
            if (!tool.isRecoverable(failure)) return failure;
            const retry_limit = tool.max_retries orelse agent.max_tool_retries;
            if (!try tool_retries.consume(work.call.name, retry_limit)) return failure;
            break :recover .{
                .content = try std.fmt.allocPrint(
                    allocator,
                    "Tool {s} failed with {s}. Correct the arguments or approach and try again.",
                    .{ work.call.name, @errorName(failure) },
                ),
                .is_error = true,
            };
        },
    };
    return .{
        .call_id = work.call.id,
        .name = work.call.name,
        .content = executed.content,
        .is_error = executed.is_error,
    };
}

const LockedAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, return_address);
    }
};

const ModelEventForwarder = struct {
    sink: ?AgentStreamSink,
    emitted: *bool,
    hooks: []const LifecycleHook,

    fn modelSink(self: *ModelEventForwarder) model_types.ModelStreamSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
        const self: *ModelEventForwarder = @ptrCast(@alignCast(context));
        self.emitted.* = true;
        try emitStreamEvent(self.hooks, self.sink.?, .{ .model = event });
    }
};

const ProviderErrorCapture = struct {
    target: ?model_types.ProviderErrorObserver,
    retry_after_seconds: ?u64 = null,
    rate_limit_remaining_requests: ?u64 = null,
    rate_limit_remaining_tokens: ?u64 = null,

    fn reset(self: *ProviderErrorCapture) void {
        self.retry_after_seconds = null;
        self.rate_limit_remaining_requests = null;
        self.rate_limit_remaining_tokens = null;
    }

    fn observer(self: *ProviderErrorCapture) model_types.ProviderErrorObserver {
        return .{ .context = self, .observeFn = observe };
    }

    fn observe(context: *anyopaque, value: model_types.ProviderError) void {
        const self: *ProviderErrorCapture = @ptrCast(@alignCast(context));
        self.retry_after_seconds = value.retry_after_seconds;
        self.rate_limit_remaining_requests = value.rate_limit_remaining_requests;
        self.rate_limit_remaining_tokens = value.rate_limit_remaining_tokens;
        if (self.target) |target| target.observe(value);
    }
};

fn checkCancellation(token: ?*const CancellationToken) Agent.Error!void {
    if (token) |value| if (value.isCancelled()) return Agent.Error.Cancelled;
}

fn requireCapability(supported: bool, failure: Agent.Error) Agent.Error!void {
    if (!supported) return failure;
}

fn requireModelSettings(profile: model_types.ModelProfile, settings: model_types.ModelSettings) Agent.Error!void {
    if (settings.temperature != null and !profile.supports_temperature) {
        return Agent.Error.ModelDoesNotSupportTemperature;
    }
    if (settings.max_tokens != null and !profile.supports_max_tokens) {
        return Agent.Error.ModelDoesNotSupportMaxTokens;
    }
    if (settings.stop_sequences != null and !profile.supports_stop_sequences) {
        return Agent.Error.ModelDoesNotSupportStopSequences;
    }
    if (settings.seed != null and !profile.supports_seed) return Agent.Error.ModelDoesNotSupportSeed;
    if (settings.reasoning_effort) |effort| {
        if (!profile.supportsReasoningEffort(effort)) return Agent.Error.ModelDoesNotSupportReasoningEffort;
    }
}

fn shouldRetry(err: anyerror, policy: Agent.RetryPolicy) bool {
    return switch (err) {
        error.ProviderRateLimited => policy.retry_rate_limits,
        error.ProviderServerError => policy.retry_server_errors,
        error.RequestTimedOut => policy.retry_timeouts,
        else => false,
    };
}

fn backoffDelayMilliseconds(backoff: Agent.Backoff, retry_number: usize, retry_after_seconds: ?u64) u64 {
    if (backoff.respect_retry_after) if (retry_after_seconds) |seconds| {
        return @min(std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64), backoff.maximum_delay_ms);
    };
    var delay = @min(backoff.initial_delay_ms, backoff.maximum_delay_ms);
    var exponent = retry_number -| 1;
    while (exponent > 0 and delay < backoff.maximum_delay_ms) : (exponent -= 1) {
        delay = @min(std.math.mul(u64, delay, 2) catch std.math.maxInt(u64), backoff.maximum_delay_ms);
    }
    return delay;
}

fn sleepBackoff(io: std.Io, delay_ms: u64, token: ?*const CancellationToken) !void {
    var remaining = delay_ms;
    while (remaining > 0) {
        try checkCancellation(token);
        const chunk: u64 = @min(remaining, 25);
        (std.Io.Timeout{ .duration = .{
            .raw = .fromMilliseconds(@intCast(chunk)),
            .clock = .awake,
        } }).sleep(io) catch |err| return normalizeBackoffSleepError(err);
        remaining -= chunk;
    }
    try checkCancellation(token);
}

fn normalizeBackoffSleepError(err: error{Canceled}) Agent.Error {
    return switch (err) {
        error.Canceled => Agent.Error.Cancelled,
    };
}

fn enforceUsageLimits(usage: model_types.Usage, limits: Agent.UsageLimits) Agent.Error!void {
    if (limits.max_input_tokens) |maximum| {
        if (usage.input_tokens > maximum) return Agent.Error.InputTokenLimitExceeded;
    }
    if (limits.max_output_tokens) |maximum| {
        if (usage.output_tokens > maximum) return Agent.Error.OutputTokenLimitExceeded;
    }
    if (limits.max_total_tokens) |maximum| {
        if (usage.totalTokens() > maximum) return Agent.Error.TotalTokenLimitExceeded;
    }
}

fn enforceFinishReason(reason: ?model_types.FinishReason) Agent.Error!void {
    const value = reason orelse return;
    return switch (value.kind) {
        .length => Agent.Error.ModelOutputTruncated,
        .content_filter => Agent.Error.ContentFiltered,
        .incomplete_tool_call => Agent.Error.IncompleteToolCall,
        else => {},
    };
}

fn appendTextMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), role: model_types.Role, text: []const u8) !void {
    const parts = try allocator.alloc(Part, 1);
    parts[0] = .{ .text = try allocator.dupe(u8, text) };
    try messages.append(allocator, .{ .role = role, .parts = parts });
}

fn appendMessageCopy(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), message: Message) !void {
    const parts = try allocator.alloc(Part, message.parts.len);
    for (message.parts, parts) |part, *copy| copy.* = switch (part) {
        .text => |value| .{ .text = try allocator.dupe(u8, value) },
        .tool_call => |value| .{ .tool_call = .{
            .id = try allocator.dupe(u8, value.id),
            .name = try allocator.dupe(u8, value.name),
            .arguments_json = try allocator.dupe(u8, value.arguments_json),
            .thought_signature = if (value.thought_signature) |signature|
                try allocator.dupe(u8, signature)
            else
                null,
        } },
        .tool_result => |value| .{ .tool_result = .{
            .call_id = try allocator.dupe(u8, value.call_id),
            .name = try allocator.dupe(u8, value.name),
            .content = try allocator.dupe(u8, value.content),
            .is_error = value.is_error,
        } },
    };
    try messages.append(allocator, .{ .role = message.role, .parts = parts });
}

fn resolveInstructions(
    allocator: std.mem.Allocator,
    configured: []const Instruction,
    runtime: []const []const u8,
    context: InstructionContext,
) ![]const []const u8 {
    var resolved: std.ArrayList([]const u8) = .empty;
    for (configured) |instruction| switch (instruction) {
        .text => |value| if (value.len > 0) try resolved.append(allocator, try allocator.dupe(u8, value)),
        .dynamic => {},
    };
    for (configured) |instruction| switch (instruction) {
        .text => {},
        .dynamic => |dynamic| {
            const value = try dynamic.resolve(allocator, context);
            if (value.len > 0) try resolved.append(allocator, try allocator.dupe(u8, value));
        },
    };
    for (runtime) |value| if (value.len > 0) {
        try resolved.append(allocator, try allocator.dupe(u8, value));
    };
    return resolved.toOwnedSlice(allocator);
}

fn emitLifecycle(hooks: []const LifecycleHook, event: LifecycleEvent) !void {
    for (hooks) |hook| try hook.emit(event);
}

fn telemetryHook(run: *telemetry_types.Run) LifecycleHook {
    const Adapter = struct {
        fn emit(context: *anyopaque, event: LifecycleEvent) !void {
            const telemetry_run: *telemetry_types.Run = @ptrCast(@alignCast(context));
            return telemetry_run.observe(event);
        }
    };
    return .{ .context = run, .eventFn = Adapter.emit };
}

fn emitStreamEvent(hooks: []const LifecycleHook, sink: AgentStreamSink, event: AgentStreamEvent) !void {
    try emitLifecycle(hooks, .{ .stream_event = .{ .stage = .before, .event = event } });
    try sink.emit(event);
    try emitLifecycle(hooks, .{ .stream_event = .{ .stage = .after, .event = event } });
}

fn prepareTools(
    allocator: std.mem.Allocator,
    direct_tools: []const model_types.Tool,
    toolsets: []const Toolset,
    context: ToolsetContext,
) ![]const model_types.Tool {
    var prepared: std.ArrayList(model_types.Tool) = .empty;
    try prepared.appendSlice(allocator, direct_tools);

    for (toolsets) |toolset| {
        const entries = try toolset.prepare(allocator, context);
        for (entries) |entry| {
            if (!entry.enabled) continue;
            var tool = entry.tool;
            if (toolset.namespace) |namespace| {
                if (namespace.len > 0) {
                    tool.definition.name = try std.fmt.allocPrint(
                        allocator,
                        "{s}__{s}",
                        .{ namespace, tool.definition.name },
                    );
                }
            }
            tool.metadata = try mergeToolMetadata(
                allocator,
                tool.metadata,
                toolset.metadata,
                entry.metadata,
            );
            try prepared.append(allocator, tool);
        }
    }
    return prepared.toOwnedSlice(allocator);
}

fn mergeToolMetadata(
    allocator: std.mem.Allocator,
    tool: []const model_types.ToolMetadata,
    toolset: []const model_types.ToolMetadata,
    entry: []const model_types.ToolMetadata,
) ![]const model_types.ToolMetadata {
    var merged: std.ArrayList(model_types.ToolMetadata) = .empty;
    for ([_][]const model_types.ToolMetadata{ tool, toolset, entry }) |layer| {
        for (layer) |metadata| {
            for (merged.items) |*existing| {
                if (std.mem.eql(u8, existing.key, metadata.key)) {
                    existing.* = metadata;
                    break;
                }
            } else try merged.append(allocator, metadata);
        }
    }
    return merged.toOwnedSlice(allocator);
}

const ToolRetryTracker = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        name: []const u8,
        count: usize,
    };

    fn restore(self: *ToolRetryTracker, saved: []const SerializedToolRetry) !void {
        for (saved) |entry| try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, entry.name),
            .count = entry.count,
        });
    }

    fn consume(self: *ToolRetryTracker, name: []const u8, limit: usize) !bool {
        if (limit == 0) return false;
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.count >= limit) return false;
            entry.count += 1;
            return true;
        }
        try self.entries.append(self.allocator, .{ .name = name, .count = 1 });
        return true;
    }
};

fn ensureUniqueToolNames(tools: []const model_types.Tool) Agent.Error!void {
    for (tools, 0..) |tool, index| {
        for (tools[index + 1 ..]) |other| {
            if (std.mem.eql(u8, tool.definition.name, other.definition.name)) return Agent.Error.DuplicateToolName;
        }
    }
}

fn findTool(tools: []const model_types.Tool, name: []const u8) ?model_types.Tool {
    const index = findToolIndex(tools, name) orelse return null;
    return tools[index];
}

fn findToolIndex(tools: []const model_types.Tool, name: []const u8) ?usize {
    for (tools, 0..) |tool, index| if (std.mem.eql(u8, tool.definition.name, name)) return index;
    return null;
}

fn collectText(allocator: std.mem.Allocator, parts: []const Part) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| switch (part) {
        .text => |text| try output.appendSlice(allocator, text),
        else => {},
    };
    if (output.items.len == 0) return Agent.Error.EmptyModelResponse;
    return output.toOwnedSlice(allocator);
}

test "tool lookup is exact" {
    var unused: u8 = 0;
    const tool = model_types.Tool{
        .definition = .{ .name = "weather", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeFn = struct {
            fn call(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
                return allocator.dupe(u8, "ok");
            }
        }.call,
    };
    try std.testing.expect(findTool(&.{tool}, "weather") != null);
    try std.testing.expect(findTool(&.{tool}, "Weather") == null);
    const content = try tool.execute(std.testing.allocator, "{}");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("ok", content);
}

test "capability requirement accepts and rejects" {
    try requireCapability(true, Agent.Error.ModelDoesNotSupportTools);
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportTools,
        requireCapability(false, Agent.Error.ModelDoesNotSupportTools),
    );
}

test "retry classification follows policy" {
    const defaults: Agent.RetryPolicy = .{};
    try std.testing.expect(shouldRetry(error.ProviderRateLimited, defaults));
    try std.testing.expect(shouldRetry(error.ProviderServerError, defaults));
    try std.testing.expect(shouldRetry(error.RequestTimedOut, defaults));
    try std.testing.expect(!shouldRetry(error.ProviderRequestFailed, defaults));
    try std.testing.expect(!shouldRetry(error.ProviderRateLimited, .{ .retry_rate_limits = false }));
    try std.testing.expect(!shouldRetry(error.ProviderServerError, .{ .retry_server_errors = false }));
    try std.testing.expect(!shouldRetry(error.RequestTimedOut, .{ .retry_timeouts = false }));
}

test "backoff is exponential, capped, and honors Retry-After" {
    const policy: Agent.Backoff = .{ .initial_delay_ms = 100, .maximum_delay_ms = 350 };
    try std.testing.expectEqual(@as(u64, 100), backoffDelayMilliseconds(policy, 1, null));
    try std.testing.expectEqual(@as(u64, 200), backoffDelayMilliseconds(policy, 2, null));
    try std.testing.expectEqual(@as(u64, 350), backoffDelayMilliseconds(policy, 4, null));
    try std.testing.expectEqual(@as(u64, 350), backoffDelayMilliseconds(policy, 1, 2));
    try std.testing.expectEqual(@as(u64, 100), backoffDelayMilliseconds(.{
        .initial_delay_ms = 100,
        .maximum_delay_ms = 350,
        .respect_retry_after = false,
    }, 1, 2));
    try std.testing.expectEqual(@as(u64, 350), backoffDelayMilliseconds(policy, 1, std.math.maxInt(u64)));
    try std.testing.expectEqual(Agent.Error.Cancelled, normalizeBackoffSleepError(error.Canceled));
}

test "usage limits accept values at their boundaries" {
    try enforceUsageLimits(.{ .input_tokens = 2, .output_tokens = 3 }, .{
        .max_input_tokens = 2,
        .max_output_tokens = 3,
        .max_total_tokens = 5,
    });
}

test "cancellation tokens and retry hooks expose stable state" {
    var token: CancellationToken = .{};
    try checkCancellation(&token);
    token.cancel();
    try std.testing.expect(token.isCancelled());
    try std.testing.expectError(Agent.Error.Cancelled, checkCancellation(&token));

    const Capture = struct {
        called: bool = false,
        fn wait(context: *anyopaque, event: RetryEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = event.failure == error.ProviderServerError and event.retry_number == 1 and event.model_requests == 1;
        }
    };
    var capture: Capture = .{};
    try (RetryHook{ .context = &capture, .waitFn = Capture.wait }).wait(.{
        .failure = error.ProviderServerError,
        .retry_number = 1,
        .model_requests = 1,
    });
    try std.testing.expect(capture.called);
}
