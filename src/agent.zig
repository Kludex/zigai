//! The provider-neutral agent loop and its owned buffered and typed results.

const std = @import("std");
const model_types = @import("model.zig");
const output_types = @import("output.zig");
const tool_policy = @import("tool.zig");
const capability_types = @import("capability.zig");
const json_schema = @import("json_schema.zig");
const reflect = @import("reflect.zig");
const history = @import("history.zig");
const context_budget = @import("context_budget.zig");
const telemetry_types = @import("telemetry.zig");
const online_eval_types = @import("online_evals.zig");
const diagnostic_types = @import("diagnostics.zig");
const json_limits = @import("json.zig");
const transport = @import("transport.zig");
const security = @import("security.zig");
const usage_types = @import("usage.zig");
const pricing_types = @import("pricing.zig");
const durable_types = @import("durable.zig");

const Message = model_types.Message;
const PromptPart = model_types.PromptPart;
const RequestPart = model_types.RequestPart;
const ResponsePart = model_types.ResponsePart;
const Part = ResponsePart;

const AgentError = error{
    /// The run's cooperative cancellation token was signalled.
    Cancelled,
    /// The provider reported that content filtering ended generation.
    ContentFiltered,
    /// Provider-facing media exceeds `ContextBudget.max_media_bytes`.
    ContextMediaTooLarge,
    /// Provider-facing prompt text exceeds `ContextBudget.max_prompt_bytes`.
    ContextPromptTooLarge,
    /// Provider-facing schemas exceed `ContextBudget.max_schema_bytes`.
    ContextSchemaTooLarge,
    /// Aggregate context measurement overflowed `u64`.
    ContextSizeOverflow,
    /// Estimated input exceeds the effective token capacity.
    ContextTokenLimitExceeded,
    /// Provider-facing tools exceed `ContextBudget.max_tool_bytes`.
    ContextToolsTooLarge,
    /// Two locally available tools have the same provider-visible name.
    DuplicateToolName,
    /// Two provider-managed tools have the same provider-visible identity.
    DuplicateBuiltinTool,
    /// Two named capabilities in the composed scopes have the same ID.
    DuplicateCapabilityId,
    /// A capability ID or metadata declaration is malformed.
    InvalidCapability,
    /// A capability dependency names no capability in the composed scopes.
    MissingCapabilityDependency,
    /// Capability dependencies contain a cycle.
    CapabilityDependencyCycle,
    /// Two capabilities that cannot coexist would both be active.
    CapabilityConflict,
    /// A successful model response contained no usable parts.
    EmptyModelResponse,
    /// Generation ended with an unfinished provider tool call.
    IncompleteToolCall,
    /// Reported cumulative input usage exceeded its run limit.
    InputTokenLimitExceeded,
    /// Typed output could not be decoded after validation.
    InvalidTypedOutput,
    /// The output specification has invalid names, schemas, or prompt templates.
    InvalidOutputSpec,
    /// A model setting is malformed or outside its provider-neutral range.
    InvalidModelSettings,
    /// Structured output could not be decoded for its final stream snapshot.
    InvalidStructuredOutput,
    /// The run attempted more model requests than allowed.
    MaxModelRequestsExceeded,
    /// The run attempted more local tool calls than allowed.
    MaxToolCallsExceeded,
    /// The selected model profile does not accept audio content.
    ModelDoesNotSupportAudio,
    /// The selected model profile does not accept generic binary content.
    ModelDoesNotSupportBinaryContent,
    /// The selected model profile does not accept documents.
    ModelDoesNotSupportDocuments,
    /// The selected model profile does not accept images.
    ModelDoesNotSupportImages,
    /// The selected model profile does not accept video content.
    ModelDoesNotSupportVideo,
    /// The selected model profile cannot encode system messages or instructions.
    ModelDoesNotSupportSystemMessages,
    /// The selected model profile cannot preserve thinking content.
    ModelDoesNotSupportThinking,
    /// Local tools were supplied to a model profile without tool support.
    ModelDoesNotSupportTools,
    /// The selected model profile does not support native web fetch.
    ModelDoesNotSupportWebFetch,
    /// The selected model profile does not support native web search.
    ModelDoesNotSupportWebSearch,
    /// The selected model profile does not support native X search.
    ModelDoesNotSupportXSearch,
    /// The selected model profile does not support provider-managed code execution.
    ModelDoesNotSupportCodeExecution,
    /// The selected model profile does not support provider-managed file search.
    ModelDoesNotSupportFileSearch,
    /// The selected model profile does not support provider-managed remote MCP.
    ModelDoesNotSupportRemoteMcp,
    /// JSON-object output was requested from an unsupported model profile.
    ModelDoesNotSupportJsonObjectOutput,
    /// JSON Schema output was requested from an unsupported model profile.
    ModelDoesNotSupportJsonSchemaOutput,
    /// Prompted structured output requires model instructions.
    ModelDoesNotSupportPromptedOutput,
    /// Tool output was required, but the model returned no output-tool call.
    OutputToolRequired,
    /// An output function requested another attempt after the retry budget.
    OutputRetriesExceeded,
    /// `max_tokens` was set for a model profile that rejects it.
    ModelDoesNotSupportMaxTokens,
    /// The requested reasoning effort is absent from the model profile.
    ModelDoesNotSupportReasoningEffort,
    /// `seed` was set for a model profile that rejects it.
    ModelDoesNotSupportSeed,
    /// Stop sequences were set for a model profile that rejects them.
    ModelDoesNotSupportStopSequences,
    /// Streaming was requested from a model profile without streaming support.
    ModelDoesNotSupportStreaming,
    /// `temperature` was set for a model profile that rejects it.
    ModelDoesNotSupportTemperature,
    /// `top_p` was set for a model profile that rejects it.
    ModelDoesNotSupportTopP,
    /// `top_k` was set for a model profile that rejects it.
    ModelDoesNotSupportTopK,
    /// A presence penalty was set for a model profile that rejects it.
    ModelDoesNotSupportPresencePenalty,
    /// A frequency penalty was set for a model profile that rejects it.
    ModelDoesNotSupportFrequencyPenalty,
    /// Log probabilities were requested from a model profile that rejects them.
    ModelDoesNotSupportLogprobs,
    /// Tool choice was set for a model profile that rejects it.
    ModelDoesNotSupportToolChoice,
    /// Parallel-tool policy was set for a model profile that cannot encode it.
    ModelDoesNotSupportParallelToolCallSetting,
    /// A thinking token budget was set for a model profile that rejects it.
    ModelDoesNotSupportThinkingBudget,
    /// A service tier was set for a model profile that rejects it.
    ModelDoesNotSupportServiceTier,
    /// Truncation policy was set for a model profile that rejects it.
    ModelDoesNotSupportTruncation,
    /// Request headers were set for a model profile that rejects them.
    ModelDoesNotSupportRequestHeaders,
    /// Provider extension JSON does not match the selected model profile.
    ModelDoesNotSupportExtraBody,
    /// Generation stopped for length before producing a complete result.
    ModelOutputTruncated,
    /// Reported cumulative output usage exceeded its run limit.
    OutputTokenLimitExceeded,
    /// Estimated or provider-reported cumulative cost exceeded its run limit.
    CostLimitExceeded,
    /// A model emitted parallel calls while parallel execution was disabled.
    ParallelToolCallsNotSupported,
    /// Parallel tool execution was required without an `Io` runtime.
    ParallelToolCallsRequireIo,
    /// A provider-managed file belongs to a different provider.
    ProviderFileProviderMismatch,
    /// An outbound or provider-fetched URL is not syntactically valid.
    InvalidUrl,
    /// An outbound or provider-fetched URL has no host.
    UrlMissingHost,
    /// An outbound or provider-fetched URL uses a forbidden scheme.
    UrlSchemeNotAllowed,
    /// An outbound or provider-fetched URL embeds user information.
    UrlCredentialsForbidden,
    /// An outbound or provider-fetched URL targets a forbidden local address.
    LocalNetworkUrlForbidden,
    /// An outbound or provider-fetched URL host is absent from the allowlist.
    UrlHostNotAllowed,
    /// Reported cumulative input plus output usage exceeded its run limit.
    TotalTokenLimitExceeded,
    /// Usage counters, durations, or cost overflowed their exact integer type.
    UsageOverflow,
    /// The runtime could not schedule all required controlled tool tasks.
    ToolConcurrencyUnavailable,
    /// A tool returned too many or too-large follow-up messages.
    ToolFollowUpOverflow,
    /// A configured tool isolation control requires an `Io` runtime.
    ToolIsolationRequiresIo,
    /// More tool calls were waiting than the configured queue permits.
    ToolQueueOverflow,
    /// A tool result exceeded its encoded byte limit.
    ToolResultTooLarge,
    /// A tool policy requested a retry after the per-tool budget was exhausted.
    ToolPolicyRetry,
    /// A local tool exceeded its execution timeout.
    ToolTimedOut,
    /// A normal run encountered a tool requiring approval or external execution.
    ToolCallRequiresDeferredRun,
    /// A durable runtime returned a persisted failure outcome.
    DurableOperationFailed,
    /// A durable runtime suspended an operation not handled by this run API.
    DurableOperationSuspended,
    /// A resumed approval call has no matching decision.
    MissingDeferredToolDecision,
    /// A resume decision does not match any paused tool call.
    UnexpectedDeferredToolDecision,
    /// An external deferred tool resumed without a supplied result.
    DeferredToolRequiresResult,
    /// Serialized paused or resume state is malformed or incompatible.
    InvalidDeferredState,
    /// A follow-up message contains a part invalid for its request role.
    InvalidContentRole,
    /// A pending-message queue was attached to more than one run.
    PendingMessageQueueAlreadyUsed,
    /// A pending message was submitted after its run stopped accepting input.
    PendingMessageQueueClosed,
    /// A tool follow-up message violates provider request invariants.
    InvalidToolFollowUpMessage,
    /// The model requested a tool that is not currently available.
    UnknownTool,
    /// Retry backoff was configured without an `Io` runtime.
    RetryBackoffRequiresIo,
    /// Idempotent retry keys were required without an `Io` entropy source.
    RetryIdempotencyRequiresIo,
    /// A deadline was configured without an `Io` runtime.
    RunControlRequiresIo,
    /// Online evaluation requires a correlated OpenTelemetry run context.
    OnlineEvaluationRequiresTelemetry,
    /// The runtime could not schedule a run operation and its control watchers.
    RunControlConcurrencyUnavailable,
    /// The invocation's absolute monotonic deadline elapsed.
    RunTimedOut,
};

const AgentUsageLimits = struct {
    max_model_requests: usize = 8,
    /// Maximum number of tool calls requested across the complete run.
    max_tool_calls: usize = 64,
    max_input_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    max_total_tokens: ?u64 = null,
    /// Exact nano-USD ceiling. It is enforced only when cost is available.
    max_cost_nano_usd: ?u64 = null,
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
    retry_connection_errors: bool = true,
    retry_decode_errors: bool = true,
    /// Maximum cumulative backoff delay across one complete agent run.
    max_total_delay_ms: ?u64 = 30_000,
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
    /// Borrowed provider response ID. Copy it in the hook to retain it.
    provider_request_id: ?[]const u8 = null,
    delay_ms: u64 = 0,
    total_delay_ms: u64 = 0,
};

pub const RetryHook = struct {
    context: *anyopaque,
    waitFn: *const fn (context: *anyopaque, event: RetryEvent) anyerror!void,

    pub fn wait(self: RetryHook, event: RetryEvent) !void {
        return self.waitFn(self.context, event);
    }
};

fn invokeRetryHook(hook: RetryHook, event: RetryEvent) !void {
    return hook.wait(event);
}

/// A validated function-tool call about to enter the local dispatcher.
pub const FunctionToolCallEvent = struct {
    call: model_types.ToolCall,
};

/// A completed local function-tool invocation.
pub const FunctionToolResultEvent = struct {
    result: model_types.ToolResult,
};

/// Calls that paused the run for approval or external execution.
pub const DeferredToolRequestsEvent = struct {
    requests: []const DeferredToolCall,
};

/// Results accepted while continuing a previously paused run.
pub const DeferredToolResultsEvent = struct {
    results: []const RequestPart,
};

/// Messages added to an active run. The event is part of the stable stream
/// vocabulary; pending-message injection emits it when messages enter history.
pub const EnqueuedMessagesEvent = struct {
    messages: []const Message,
};

/// A change to the tools visible to the model.
pub const ToolAvailabilityDeltaEvent = struct {
    part: model_types.ToolAvailabilityDeltaPart,
};

/// The one accepted final output for a run. `structured_output` is a borrowed,
/// validated JSON snapshot for JSON object/schema outputs and null for text.
pub const FinalResultEvent = struct {
    output: []const u8,
    /// Selected choice name for tool output; null for text/native/prompted output.
    output_name: ?[]const u8 = null,
    structured_output: ?std.json.Value = null,
};

/// One accumulated provisional output snapshot. Structured snapshots are
/// repaired and partially validated; all values are borrowed for the callback.
pub const PartialOutputEvent = struct {
    output: []const u8,
    output_name: ?[]const u8 = null,
    structured_output: ?std.json.Value = null,
};

/// Borrowed agent-run events. Model part events are provisional; only
/// `final_result` means output validation succeeded.
pub const AgentStreamEvent = union(enum) {
    model: model_types.ModelStreamEvent,
    function_tool_call: FunctionToolCallEvent,
    function_tool_result: FunctionToolResultEvent,
    tool_availability_delta: ToolAvailabilityDeltaEvent,
    deferred_tool_requests: DeferredToolRequestsEvent,
    deferred_tool_results: DeferredToolResultsEvent,
    enqueued_messages: EnqueuedMessagesEvent,
    partial_output: PartialOutputEvent,
    final_result: FinalResultEvent,
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

const ControlledOutputValidator = struct {
    validator: OutputValidator,
    control: model_types.RunControl,

    fn validate(context: *anyopaque, allocator: std.mem.Allocator, output: []const u8) !void {
        const self: *ControlledOutputValidator = @ptrCast(@alignCast(context));
        return self.control.invoke(void, invokeOutputValidator, .{ self.validator, allocator, output });
    }
};

fn invokeOutputValidator(validator: OutputValidator, allocator: std.mem.Allocator, output: []const u8) !void {
    return validator.validate(allocator, output);
}

pub const InstructionContext = struct {
    dependencies: ?*anyopaque = null,
    prompt: []const u8,
    /// Active and on-demand-loaded capability IDs at evaluation time.
    capabilities: capability_types.Snapshot = .{},
    control: model_types.RunControl = .{},

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
    /// Rich parts inserted before the text prompt in the new user message.
    prompt_parts: []const PromptPart = &.{},
    /// Extra instructions appended after the agent's static and dynamic ones.
    instructions: []const []const u8 = &.{},
    /// Capabilities contributed for this invocation after agent capabilities.
    capabilities: []const Capability = &.{},
    /// Explicit inherited, nested, or subagent layers. Layers compose by
    /// `CapabilityScope` and then declaration order, independent of slice order.
    capability_layers: []const CapabilityLayer = &.{},
    /// Overrides agent dependencies when non-null.
    dependencies: ?*anyopaque = null,
    /// Highest-precedence generation settings for this run.
    model_settings: model_types.ModelSettings = .{},
    /// Extra provider-facing history processors applied after agent processors.
    history_processors: []const history.Processor = &.{},
    /// Replaces the agent's context budget for this invocation.
    context_budget: ?context_budget.Budget = null,
    /// Provider-facing correlation ID for every model request in this run.
    request_id: ?[]const u8 = null,
    /// Upstream trace context used as the parent of this agent invocation.
    telemetry_parent: ?telemetry_types.SpanContext = null,
    /// Tightens `Agent.run_timeout_ms` for this invocation.
    timeout_ms: ?u64 = null,
    /// A one-run, thread-safe queue for request messages submitted while the
    /// agent is working. The caller owns and deinitializes the queue.
    pending_messages: ?*PendingMessageQueue = null,
    /// Routes side effects through a durable runtime. The binding is immutable;
    /// operation identities are derived from deterministic agent-loop state.
    durable: ?durable_types.Binding = null,
};

/// A one-run FIFO for injecting owned request messages at safe agent-loop
/// boundaries. Enqueue order is the order calls acquire the queue lock. The
/// queue closes atomically before a final result, pause, cancellation, or
/// failure, and rejects all later submissions.
pub const PendingMessageQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    state: State = .ready,
    batches: std.ArrayList(Batch) = .empty,

    const State = enum { ready, active, closed };

    const Batch = struct {
        arena: std.heap.ArenaAllocator,
        messages: []const model_types.RequestMessage,

        fn deinit(self: *Batch) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    const Drained = struct {
        allocator: std.mem.Allocator,
        batches: std.ArrayList(Batch),

        fn deinit(self: *Drained) void {
            for (self.batches.items) |*batch| batch.deinit();
            self.batches.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) PendingMessageQueue {
        return .{ .allocator = allocator, .io = io };
    }

    /// Copies one ordered batch. The source can be released as soon as this
    /// method returns.
    pub fn enqueue(self: *PendingMessageQueue, messages_to_add: []const model_types.RequestMessage) !void {
        if (messages_to_add.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const copies = try arena.allocator().alloc(model_types.RequestMessage, messages_to_add.len);
        for (messages_to_add, copies) |message, *copy| {
            copy.* = try copyRequestMessage(arena.allocator(), message);
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .closed) return AgentError.PendingMessageQueueClosed;
        try self.batches.append(self.allocator, .{ .arena = arena, .messages = copies });
    }

    /// Releases queued copies. The queue must outlive any run that uses it.
    pub fn deinit(self: *PendingMessageQueue) void {
        self.close();
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    fn activate(self: *PendingMessageQueue) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return AgentError.PendingMessageQueueAlreadyUsed;
        self.state = .active;
    }

    fn drain(self: *PendingMessageQueue) ?Drained {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.batches.items.len == 0) return null;
        const batches = self.batches;
        self.batches = .empty;
        return .{ .allocator = self.allocator, .batches = batches };
    }

    fn drainOrClose(self: *PendingMessageQueue) ?Drained {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.batches.items.len == 0) {
            self.state = .closed;
            return null;
        }
        const batches = self.batches;
        self.batches = .empty;
        return .{ .allocator = self.allocator, .batches = batches };
    }

    fn closeAndDrain(self: *PendingMessageQueue) ?Drained {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .closed;
        if (self.batches.items.len == 0) return null;
        const batches = self.batches;
        self.batches = .empty;
        return .{ .allocator = self.allocator, .batches = batches };
    }

    fn close(self: *PendingMessageQueue) void {
        var drained = self.closeAndDrain() orelse return;
        drained.deinit();
    }
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

/// Arena-owned resume decisions. All slices remain valid until `deinit`.
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
    const parsed = try json_limits.parseLeaky(
        SerializedResume,
        arena.allocator(),
        source,
        json_limits.defaults.resume_decisions,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
        Agent.Error.InvalidDeferredState,
    );
    if (parsed.version != 1) return Agent.Error.InvalidDeferredState;
    return .{ .arena = arena, .decisions = parsed.decisions };
}

/// Arena-owned paused state. All slices remain valid until `deinit`.
pub const PausedRun = struct {
    arena: std.heap.ArenaAllocator,
    state_json: []const u8,
    calls: []const DeferredToolCall,
    usage: usage_types.RunUsage,
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

const SerializedResolvedToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    model_arguments_json: []const u8,
    execution: model_types.ToolExecution,
    retry_number: usize,
    durable_sequence: ?u64 = null,
};

const SerializedPause = struct {
    version: u8,
    prompt: []const u8,
    history_json: []const u8,
    instructions: []const []const u8,
    usage: usage_types.RunUsage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    tool_retries: []const SerializedToolRetry,
    calls: []const SerializedResolvedToolCall,
    pending_history_json: ?[]const u8 = null,
};

const ResumeState = struct {
    messages: []const Message,
    instructions: []const []const u8,
    usage: usage_types.RunUsage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    tool_retries: []const SerializedToolRetry,
    calls: []const SerializedResolvedToolCall,
    pending_messages: []const Message,
};

pub const CapabilityContext = struct {
    /// Original prompt for the current invocation.
    prompt: []const u8,
    /// Application dependency pointer supplied by the agent or run.
    dependencies: ?*anyopaque,
    /// Model selected by lower-precedence capability layers.
    model: model_types.Model,
    /// Composition scope of the capability being evaluated.
    scope: capability_types.Scope = .agent,
    /// Application-only metadata declared by the capability.
    metadata: []const capability_types.Metadata = &.{},
    /// IDs whose complete bundles are active for the next model step.
    available_capability_ids: []const []const u8 = &.{},
    /// Active IDs that entered through on-demand loading.
    loaded_capability_ids: []const []const u8 = &.{},
    /// Cooperative cancellation and deadline control for callbacks.
    control: model_types.RunControl = .{},
};

/// Current run state available while preparing tools for the next model step.
pub const ToolsetContext = struct {
    messages: []const Message,
    usage: usage_types.RunUsage,
    model_requests: usize,
    dependencies: ?*anyopaque,
    capabilities: capability_types.Snapshot = .{},
    control: model_types.RunControl = .{},

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
        usage: usage_types.RunUsage,
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

const ControlledLifecycleHook = struct {
    hook: LifecycleHook,
    control: model_types.RunControl,

    fn emit(context: *anyopaque, event: LifecycleEvent) !void {
        const self: *ControlledLifecycleHook = @ptrCast(@alignCast(context));
        return self.control.invoke(void, invokeLifecycleHook, .{ self.hook, event });
    }
};

const ControlledHooks = struct {
    adapters: []ControlledLifecycleHook,
    hooks: []LifecycleHook,

    fn init(
        allocator: std.mem.Allocator,
        configured: []const LifecycleHook,
        control: model_types.RunControl,
    ) !ControlledHooks {
        const adapters = try allocator.alloc(ControlledLifecycleHook, configured.len);
        errdefer allocator.free(adapters);
        const hooks = try allocator.alloc(LifecycleHook, configured.len);
        errdefer allocator.free(hooks);
        for (configured, adapters, hooks) |hook, *adapter, *wrapped| {
            adapter.* = .{ .hook = hook, .control = control };
            wrapped.* = .{ .context = adapter, .eventFn = ControlledLifecycleHook.emit };
        }
        return .{ .adapters = adapters, .hooks = hooks };
    }

    fn deinit(self: ControlledHooks, allocator: std.mem.Allocator) void {
        allocator.free(self.hooks);
        allocator.free(self.adapters);
    }
};

fn invokeLifecycleHook(hook: LifecycleHook, event: LifecycleEvent) !void {
    return hook.emit(event);
}

const ControlledStreamSink = struct {
    sink: AgentStreamSink,
    control: model_types.RunControl,

    fn emit(context: *anyopaque, event: AgentStreamEvent) !void {
        const self: *ControlledStreamSink = @ptrCast(@alignCast(context));
        return self.control.invoke(void, invokeStreamSink, .{ self.sink, event });
    }
};

fn invokeStreamSink(sink: AgentStreamSink, event: AgentStreamEvent) !void {
    return sink.emit(event);
}

/// A reusable feature bundle. Named bundles can declare dependencies,
/// conflicts, model-facing discovery text, and on-demand loading behavior.
pub const Capability = struct {
    /// Stable ID required for discovery, dependencies, and conflicts.
    id: ?[]const u8 = null,
    /// Concise model-facing text shown before an on-demand capability loads.
    description: ?[]const u8 = null,
    /// Application-only metadata exposed to the capability model selector.
    metadata: []const capability_types.Metadata = &.{},
    /// IDs activated first, in declaration order.
    dependencies: []const []const u8 = &.{},
    /// IDs that cannot be active at the same time.
    conflicts: []const []const u8 = &.{},
    /// Whether the complete bundle starts active or is progressively disclosed.
    loading: capability_types.Loading = .eager,
    /// Whether a successful on-demand load is restored from later run history.
    unload_policy: capability_types.UnloadPolicy = .history,
    tools: []const model_types.Tool = &.{},
    builtin_tools: []const model_types.BuiltinTool = &.{},
    toolsets: []const Toolset = &.{},
    instructions: []const Instruction = &.{},
    hooks: []const LifecycleHook = &.{},
    tool_policies: []const tool_policy.Policy = &.{},
    history_processors: []const history.Processor = &.{},
    output_validators: []const output_types.Validator = &.{},
    model_settings: model_types.ModelSettings = .{},
    context: ?*anyopaque = null,
    selectModelFn: ?*const fn (context: ?*anyopaque, run: CapabilityContext) anyerror!model_types.Model = null,

    pub fn selectModel(self: Capability, run: CapabilityContext) !model_types.Model {
        const select = self.selectModelFn orelse return run.model;
        return select(self.context, run);
    }

    /// Returns the borrowed registry data for this implementation bundle.
    pub fn descriptor(self: Capability) capability_types.Descriptor {
        return .{
            .id = self.id,
            .description = self.description,
            .metadata = self.metadata,
            .dependencies = self.dependencies,
            .conflicts = self.conflicts,
            .loading = self.loading,
            .unload_policy = self.unload_policy,
        };
    }
};

/// A capability layer supplied by an enclosing run, nested agent, or subagent.
pub const CapabilityLayer = struct {
    /// Fixed precedence tier; input layer slice order never changes tier order.
    scope: capability_types.Scope,
    /// Capabilities composed in declaration order within `scope`.
    capabilities: []const Capability,
};

const ScopedCapability = struct {
    capability: Capability,
    scope: capability_types.Scope,
    source_index: usize,
};

const ActiveCapabilities = struct {
    model: model_types.Model,
    tools: []const model_types.Tool,
    builtin_tools: []const model_types.BuiltinTool,
    toolsets: []const Toolset,
    tool_policies: []const tool_policy.Policy,
    history_processors: []const history.Processor,
    output_validators: []const output_types.Validator,
    model_settings: model_types.ModelSettings,
};

const CapabilityRuntime = struct {
    scoped: []const ScopedCapability,
    entries: []const capability_types.Entry,
    active: []bool,
    loaded: []bool,
    initial: []bool,
    pending: []bool,
    generation: usize = 0,
    prompt: []const u8,
    dependencies: ?*anyopaque,
    control: model_types.RunControl,

    fn init(
        allocator: std.mem.Allocator,
        scoped: []const ScopedCapability,
        prompt: []const u8,
        dependencies: ?*anyopaque,
        control: model_types.RunControl,
        previous_messages: []const Message,
        restoring_pause: bool,
    ) !CapabilityRuntime {
        const entries = try allocator.alloc(capability_types.Entry, scoped.len);
        const active = try allocator.alloc(bool, scoped.len);
        const loaded = try allocator.alloc(bool, scoped.len);
        const initial = try allocator.alloc(bool, scoped.len);
        const pending = try allocator.alloc(bool, scoped.len);
        @memset(active, false);
        @memset(loaded, false);
        @memset(initial, false);
        @memset(pending, false);
        for (scoped, entries) |item, *entry| entry.* = .{
            .descriptor = item.capability.descriptor(),
            .scope = item.scope,
            .source_index = item.source_index,
        };
        var runtime = CapabilityRuntime{
            .scoped = scoped,
            .entries = entries,
            .active = active,
            .loaded = loaded,
            .initial = initial,
            .pending = pending,
            .prompt = prompt,
            .dependencies = dependencies,
            .control = control,
        };
        const capability_registry = runtime.registry();
        if (try capability_registry.diagnose(allocator)) |diagnostic| return capabilityDiagnosticError(diagnostic);

        for (scoped, 0..) |item, index| {
            if (item.capability.loading != .eager) continue;
            try runtime.activate(allocator, index, true);
        }
        try runtime.restoreHistoryLoads(allocator, previous_messages, restoring_pause);
        return runtime;
    }

    fn registry(self: *const CapabilityRuntime) capability_types.Registry {
        return .{ .entries = self.entries };
    }

    fn activate(self: *CapabilityRuntime, allocator: std.mem.Allocator, index: usize, is_initial: bool) !void {
        const id = self.entries[index].descriptor.id orelse {
            self.active[index] = true;
            if (is_initial) self.initial[index] = true;
            return;
        };
        var resolution = try self.registry().resolve(allocator, id, self.active);
        defer resolution.deinit();
        switch (resolution.outcome) {
            .diagnostic => |diagnostic| return capabilityDiagnosticError(diagnostic),
            .plan => |plan| for (plan) |resolved| {
                self.active[resolved] = true;
                if (self.scoped[resolved].capability.loading == .on_demand) self.loaded[resolved] = true;
                if (is_initial) self.initial[resolved] = true;
            },
        }
    }

    fn restoreHistoryLoads(
        self: *CapabilityRuntime,
        allocator: std.mem.Allocator,
        previous_messages: []const Message,
        restoring_pause: bool,
    ) !void {
        for (previous_messages, 0..) |message, message_index| switch (message) {
            .response => |response| for (response.parts) |part| switch (part) {
                .capability_load_call => |call| {
                    if (!hasSuccessfulCapabilityReturn(previous_messages[message_index + 1 ..], call.call_id)) continue;
                    try self.activateHistoryId(allocator, call.capability_id, restoring_pause);
                },
                .tool_call => |call| {
                    if (!std.mem.eql(u8, call.name, load_capability_tool_name) or
                        !hasSuccessfulToolReturn(previous_messages[message_index + 1 ..], call.id, call.name)) continue;
                    const parsed = json_limits.parseLeaky(
                        LoadCapabilityArguments,
                        allocator,
                        call.arguments_json,
                        json_limits.defaults.tool_payload,
                        .{ .ignore_unknown_fields = false },
                        AgentError.InvalidCapability,
                    ) catch continue;
                    try self.activateHistoryId(allocator, parsed.id, restoring_pause);
                },
                else => {},
            },
            .request => {},
        };
    }

    fn activateHistoryId(
        self: *CapabilityRuntime,
        allocator: std.mem.Allocator,
        id: []const u8,
        restoring_pause: bool,
    ) !void {
        const index = self.registry().findIndex(id) orelse return;
        if (!restoring_pause and self.scoped[index].capability.unload_policy != .history) return;
        try self.activate(allocator, index, false);
    }

    fn activeIds(self: *const CapabilityRuntime, allocator: std.mem.Allocator, loaded_only: bool) ![]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        for (self.entries, 0..) |entry, index| {
            if (!self.active[index] or (loaded_only and !self.loaded[index])) continue;
            if (entry.descriptor.id) |id| try ids.append(allocator, id);
        }
        return ids.toOwnedSlice(allocator);
    }

    fn snapshot(self: *const CapabilityRuntime, allocator: std.mem.Allocator) !capability_types.Snapshot {
        return .{
            .available_ids = try self.activeIds(allocator, false),
            .loaded_ids = try self.activeIds(allocator, true),
        };
    }

    fn assemble(
        self: *CapabilityRuntime,
        allocator: std.mem.Allocator,
        agent: Agent,
    ) !ActiveCapabilities {
        var tools: std.ArrayList(model_types.Tool) = .empty;
        try tools.appendSlice(allocator, agent.tools);
        var builtin_tools: std.ArrayList(model_types.BuiltinTool) = .empty;
        try builtin_tools.appendSlice(allocator, agent.builtin_tools);
        var toolsets: std.ArrayList(Toolset) = .empty;
        try toolsets.appendSlice(allocator, agent.toolsets);
        var policies: std.ArrayList(tool_policy.Policy) = .empty;
        try policies.appendSlice(allocator, agent.tool_policies);
        var processors: std.ArrayList(history.Processor) = .empty;
        try processors.appendSlice(allocator, agent.history_processors);
        var validators: std.ArrayList(output_types.Validator) = .empty;
        try validators.appendSlice(allocator, agent.output_validators);
        var settings: model_types.ModelSettings = .{};
        var selected_model = agent.model;
        const available_ids = try self.activeIds(allocator, false);
        const loaded_ids = try self.activeIds(allocator, true);
        for (self.scoped, 0..) |item, index| {
            if (!self.active[index]) continue;
            const capability = item.capability;
            try tools.appendSlice(allocator, capability.tools);
            try builtin_tools.appendSlice(allocator, capability.builtin_tools);
            try toolsets.appendSlice(allocator, capability.toolsets);
            try policies.appendSlice(allocator, capability.tool_policies);
            try processors.appendSlice(allocator, capability.history_processors);
            try validators.appendSlice(allocator, capability.output_validators);
            settings = settings.overrideWith(capability.model_settings);
            selected_model = try self.control.invoke(model_types.Model, selectCapabilityModel, .{
                capability,
                CapabilityContext{
                    .prompt = self.prompt,
                    .dependencies = self.dependencies,
                    .model = selected_model,
                    .scope = item.scope,
                    .metadata = capability.metadata,
                    .available_capability_ids = available_ids,
                    .loaded_capability_ids = loaded_ids,
                    .control = self.control,
                },
            });
        }
        if (self.hasDeferred()) try tools.append(allocator, self.loadTool());
        return .{
            .model = selected_model,
            .tools = try tools.toOwnedSlice(allocator),
            .builtin_tools = try builtin_tools.toOwnedSlice(allocator),
            .toolsets = try toolsets.toOwnedSlice(allocator),
            .tool_policies = try policies.toOwnedSlice(allocator),
            .history_processors = try processors.toOwnedSlice(allocator),
            .output_validators = try validators.toOwnedSlice(allocator),
            .model_settings = settings,
        };
    }

    fn appendInitialInstructions(
        self: *CapabilityRuntime,
        allocator: std.mem.Allocator,
        instructions: *std.ArrayList(Instruction),
    ) !void {
        for (self.scoped, 0..) |item, index| {
            if (self.initial[index]) try instructions.appendSlice(allocator, item.capability.instructions);
        }
        if (try self.catalogInstruction(allocator)) |catalog| {
            try instructions.append(allocator, .{ .text = catalog });
        }
    }

    fn catalogInstruction(self: *const CapabilityRuntime, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.hasDeferred()) return null;
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(
            allocator,
            "The following capabilities can be loaded with the `load_capability` tool. " ++
                "Their tools and behavior stay unavailable until loaded:\n",
        );
        for (self.scoped, 0..) |item, index| {
            const capability = item.capability;
            if (capability.loading != .on_demand or self.active[index]) continue;
            try content.appendSlice(allocator, "- ");
            try content.appendSlice(allocator, capability.id.?);
            if (capability.description) |description| {
                try content.appendSlice(allocator, ": ");
                try content.appendSlice(allocator, description);
            }
            try content.append(allocator, '\n');
        }
        const owned: []const u8 = try content.toOwnedSlice(allocator);
        return owned;
    }

    fn hasDeferred(self: *const CapabilityRuntime) bool {
        for (self.scoped, 0..) |item, index| {
            if (item.capability.loading == .on_demand and !self.active[index]) return true;
        }
        return false;
    }

    fn hasOnDemand(self: *const CapabilityRuntime) bool {
        for (self.scoped) |item| if (item.capability.loading == .on_demand) return true;
        return false;
    }

    fn loadTool(self: *CapabilityRuntime) model_types.Tool {
        return .{
            .definition = .{
                .name = load_capability_tool_name,
                .description = "Load one named capability and its required dependencies.",
                .parameters_json_schema = load_capability_schema,
            },
            .sequential = true,
            .context = self,
            .validateFn = validateCapabilityLoad,
            .executeWithContextFn = executeCapabilityLoad,
        };
    }

    fn requestLoad(
        self: *CapabilityRuntime,
        allocator: std.mem.Allocator,
        capability_id: []const u8,
    ) ![]const u8 {
        const index = self.registry().findIndex(capability_id) orelse return error.UnknownCapability;
        if (self.scoped[index].capability.loading != .on_demand) return error.CapabilityAlreadyAvailable;
        if (self.active[index] or self.pending[index]) {
            return std.fmt.allocPrint(allocator, "Capability `{s}` is already loaded.", .{capability_id});
        }
        const effective = try allocator.dupe(bool, self.active);
        for (self.pending, effective) |is_pending, *is_active| is_active.* = is_active.* or is_pending;
        var resolution = try self.registry().resolve(allocator, capability_id, effective);
        defer resolution.deinit();
        const plan = switch (resolution.outcome) {
            .diagnostic => |diagnostic| {
                std.debug.assert(diagnostic.kind == .active_conflict);
                return error.CapabilityConflict;
            },
            .plan => |value| value,
        };
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(allocator, "Loaded capabilities:");
        for (plan) |resolved| {
            const capability = self.scoped[resolved].capability;
            if (capability.id) |id| {
                try content.appendSlice(allocator, "\n- ");
                try content.appendSlice(allocator, id);
            }
            const resolved_instructions = try resolveInstructions(allocator, capability.instructions, &.{}, .{
                .dependencies = self.dependencies,
                .prompt = self.prompt,
                .capabilities = try self.snapshot(allocator),
                .control = self.control,
            });
            for (resolved_instructions) |instruction| {
                try content.appendSlice(allocator, "\n\n");
                try content.appendSlice(allocator, instruction);
            }
        }
        const owned = try content.toOwnedSlice(allocator);
        for (plan) |resolved| self.pending[resolved] = true;
        return owned;
    }

    fn commitPending(self: *CapabilityRuntime) void {
        var changed = false;
        for (self.pending, 0..) |*is_pending, index| {
            if (!is_pending.*) continue;
            self.active[index] = true;
            self.loaded[index] = true;
            is_pending.* = false;
            changed = true;
        }
        if (changed) self.generation += 1;
    }
};

const CapabilityHookAdapter = struct {
    runtime: *CapabilityRuntime,
    capability_index: usize,
    hook: LifecycleHook,

    fn emit(context: *anyopaque, event: LifecycleEvent) !void {
        const self: *CapabilityHookAdapter = @ptrCast(@alignCast(context));
        if (!self.runtime.active[self.capability_index]) return;
        return self.hook.emit(event);
    }
};

const LoadCapabilityArguments = struct { id: []const u8 };
const load_capability_tool_name = "load_capability";
const load_capability_schema =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}," ++
    "\"required\":[\"id\"],\"additionalProperties\":false}";

fn validateCapabilityLoad(context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) !void {
    const runtime: *CapabilityRuntime = @ptrCast(@alignCast(context));
    const parsed = try json_limits.parseLeaky(
        LoadCapabilityArguments,
        allocator,
        arguments_json,
        json_limits.defaults.tool_payload,
        .{ .ignore_unknown_fields = false },
        error.InvalidCapabilityArguments,
    );
    if (runtime.registry().findIndex(parsed.id) == null) return error.UnknownCapability;
}

fn executeCapabilityLoad(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    _: model_types.ToolRunContext,
    arguments_json: []const u8,
) ![]const u8 {
    const runtime: *CapabilityRuntime = @ptrCast(@alignCast(context));
    const parsed = try json_limits.parseLeaky(
        LoadCapabilityArguments,
        allocator,
        arguments_json,
        json_limits.defaults.tool_payload,
        .{ .ignore_unknown_fields = false },
        error.InvalidCapabilityArguments,
    );
    return runtime.requestLoad(allocator, parsed.id);
}

fn capabilityDiagnosticError(diagnostic: capability_types.Diagnostic) AgentError {
    return switch (diagnostic.kind) {
        .duplicate_id => AgentError.DuplicateCapabilityId,
        .missing_dependency => AgentError.MissingCapabilityDependency,
        .dependency_cycle => AgentError.CapabilityDependencyCycle,
        .active_conflict => AgentError.CapabilityConflict,
        else => AgentError.InvalidCapability,
    };
}

fn hasSuccessfulCapabilityReturn(messages: []const Message, call_id: []const u8) bool {
    for (messages) |message| switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .capability_load_return => |result| if (std.mem.eql(u8, result.call_id, call_id)) {
                return result.outcome == .success;
            },
            .tool_return => |result| if (result.tool_kind == .capability_load and
                std.mem.eql(u8, result.call_id, call_id))
            {
                return !result.isError();
            },
            else => {},
        },
        .response => {},
    };
    return false;
}

fn hasSuccessfulToolReturn(messages: []const Message, call_id: []const u8, name: []const u8) bool {
    for (messages) |message| switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .tool_return => |result| if (std.mem.eql(u8, result.call_id, call_id) and
                std.mem.eql(u8, result.name, name)) return !result.isError(),
            else => {},
        },
        .response => {},
    };
    return false;
}

fn selectCapabilityModel(capability: Capability, context: CapabilityContext) !model_types.Model {
    return capability.selectModel(context);
}

/// An owned agent result whose JSON response has been decoded as `Output`.
///
/// `output`, `output_json`, and `messages` may all reference the result arena.
/// Call `deinit` exactly once when none of them are needed anymore.
pub fn TypedResult(comptime Output: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        output: Output,
        output_json: []const u8,
        output_name: ?[]const u8 = null,
        messages: []const Message,
        usage: usage_types.RunUsage,
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
    /// Reusable feature bundles composed before run-scoped capability layers.
    capabilities: []const Capability = &.{},
    hooks: []const LifecycleHook = &.{},
    /// Ordered tool lifecycle policies. Capability policies run afterward in
    /// `capabilities` order.
    tool_policies: []const tool_policy.Policy = &.{},
    tools: []const model_types.Tool = &.{},
    builtin_tools: []const model_types.BuiltinTool = &.{},
    toolsets: []const Toolset = &.{},
    history_processors: []const history.Processor = &.{},
    system_prompt: ?[]const u8 = null,
    instructions: []const Instruction = &.{},
    output: output_types.Spec = .text,
    /// Ordered semantic validators. Each may transform output or return a safe
    /// retry message; thrown errors abort the run.
    output_validators: []const output_types.Validator = &.{},
    /// Policy for ordinary tools emitted alongside a final output.
    end_strategy: output_types.EndStrategy = .graceful,
    /// Re-check structured provider output locally before returning it. This is
    /// intentionally opt-in because JSON Schema support is a documented subset.
    validate_output_locally: bool = false,
    /// Number of invalid final responses returned to the model for correction.
    max_output_retries: usize = 2,
    /// Default number of failures returned to the model for each tool.
    max_tool_retries: usize = 2,
    /// Run-wide local tool execution limits. A tool may only tighten them.
    tool_limits: model_types.ToolLimits = .{},
    /// Overrides model defaults for every run of this agent.
    model_settings: model_types.ModelSettings = .{},
    limits: UsageLimits = .{},
    retry_policy: RetryPolicy = .{},
    /// Provider-request preflight limits and optional compaction policy.
    context_budget: ContextBudget = .{},
    /// Policy for provider endpoints and URLs represented in rich content.
    url_policy: security.UrlPolicy = .{},
    provider_error_observer: ?model_types.ProviderErrorObserver = null,
    /// Bounded provider details made visible to `provider_error_observer`.
    provider_error_policy: model_types.ProviderErrorPolicy = .{},
    dependencies: ?*anyopaque = null,
    /// Cooperative token raced against in-flight work when `io` is available.
    cancellation: ?*const CancellationToken = null,
    /// One monotonic budget shared by the complete invocation.
    run_timeout_ms: ?u64 = null,
    /// Per-model-attempt ceiling, tightened by the remaining run budget.
    request_timeout_ms: ?u64 = null,
    /// Runtime used for HTTP, parallel tools, and preemptive run controls.
    io: ?std.Io = null,
    /// Optional per-run OpenTelemetry spans and metrics.
    telemetry: ?telemetry_types.OpenTelemetry = null,
    /// Optional bounded production-evaluation queue. OpenTelemetry must also
    /// be configured so every sampled observation retains trace correlation.
    online_evals: ?*online_eval_types.Queue = null,
    /// Optional backend-neutral structured diagnostic events.
    diagnostics: ?diagnostic_types.Config = null,
    /// Optional deterministic pricing snapshot. Unknown or incompletely
    /// priced models retain a null cost.
    price_table: ?pricing_types.Table = null,

    pub const UsageLimits = AgentUsageLimits;
    pub const RetryPolicy = AgentRetryPolicy;
    pub const Backoff = AgentBackoff;
    pub const ContextBudget = context_budget.Budget;
    pub const ToolLimits = model_types.ToolLimits;

    pub const Error = AgentError;

    /// Arena-owned buffered result. `output` and `messages` remain valid until
    /// `deinit`.
    pub const Result = struct {
        arena: std.heap.ArenaAllocator,
        output: []const u8,
        /// Selected choice name for tool output; null for other output modes.
        output_name: ?[]const u8 = null,
        messages: []const Message,
        usage: usage_types.RunUsage,
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

    /// Streams until final output or a tool requires approval or external execution.
    pub fn runUntilPauseStream(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        sink: AgentStreamSink,
    ) !RunOutcome {
        return self.runUntilPauseStreamWithOptions(allocator, prompt, .{}, sink);
    }

    pub fn runUntilPauseStreamWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        sink: AgentStreamSink,
    ) !RunOutcome {
        return self.runOutcomeInternal(allocator, prompt, options, sink, null, true, null, &.{});
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
        return self.resumeRunInternal(allocator, state_json, decisions, options, null);
    }

    /// Continues a paused run and emits deferred-result and subsequent model events.
    pub fn resumeRunStream(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions: []const ResumeDecision,
        sink: AgentStreamSink,
    ) !RunOutcome {
        return self.resumeRunStreamWithOptions(allocator, state_json, decisions, .{}, sink);
    }

    pub fn resumeRunStreamWithOptions(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions: []const ResumeDecision,
        options: RunOptions,
        sink: AgentStreamSink,
    ) !RunOutcome {
        return self.resumeRunInternal(allocator, state_json, decisions, options, sink);
    }

    fn resumeRunInternal(
        self: Agent,
        allocator: std.mem.Allocator,
        state_json: []const u8,
        decisions: []const ResumeDecision,
        options: RunOptions,
        stream_sink: ?AgentStreamSink,
    ) !RunOutcome {
        const parsed = try json_limits.parse(
            SerializedPause,
            allocator,
            state_json,
            json_limits.defaults.paused_state,
            .{ .ignore_unknown_fields = false },
            Error.InvalidDeferredState,
        );
        defer parsed.deinit();
        if (parsed.value.version != 2) return Error.InvalidDeferredState;
        var owned_history = history.parse(allocator, parsed.value.history_json) catch
            return Error.InvalidDeferredState;
        defer owned_history.deinit();
        var owned_pending: ?history.Owned = if (parsed.value.pending_history_json) |pending_json|
            history.parse(allocator, pending_json) catch return Error.InvalidDeferredState
        else
            null;
        defer if (owned_pending) |*pending| pending.deinit();
        return self.runOutcomeInternal(
            allocator,
            parsed.value.prompt,
            options,
            stream_sink,
            null,
            true,
            .{
                .messages = owned_history.messages,
                .instructions = parsed.value.instructions,
                .usage = parsed.value.usage,
                .model_requests = parsed.value.model_requests,
                .total_tool_calls = parsed.value.total_tool_calls, // kcov-ignore
                .output_retries = parsed.value.output_retries, // kcov-ignore
                .tool_retries = parsed.value.tool_retries, // kcov-ignore
                .calls = parsed.value.calls,
                .pending_messages = if (owned_pending) |pending| pending.messages else &.{},
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
            .paused => unreachable,
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
        const control = try model_types.RunControl.init(
            self.io,
            self.cancellation,
            earliestTimeout(self.run_timeout_ms, options.timeout_ms),
        );
        try control.check();
        if (options.pending_messages) |queue| try queue.activate();
        defer if (options.pending_messages) |queue| queue.close();
        var sink_adapter: ControlledStreamSink = undefined;
        const controlled_stream_sink: ?AgentStreamSink = if (stream_sink) |sink| sink: {
            sink_adapter = .{ .sink = sink, .control = control };
            break :sink .{ .context = &sink_adapter, .eventFn = ControlledStreamSink.emit };
        } else null;
        var validator_adapter: ControlledOutputValidator = undefined;
        const controlled_output_validator: ?OutputValidator = if (output_validator) |validator| validator: {
            validator_adapter = .{ .validator = validator, .control = control };
            break :validator .{ .context = &validator_adapter, .validateFn = ControlledOutputValidator.validate };
        } else null;
        var telemetry_run: ?telemetry_types.Run = if (self.telemetry) |configured|
            configured.startWithParent(allocator, options.telemetry_parent)
        else
            null;
        defer if (telemetry_run) |*instrumentation| instrumentation.deinit();
        var online_eval_run: ?online_eval_types.Run = if (self.online_evals) |queue| online: {
            const instrumentation = if (telemetry_run) |*telemetry_state| telemetry_state else return AgentError.OnlineEvaluationRequiresTelemetry;
            break :online try queue.start(instrumentation.spanContext());
        } else null;
        var diagnostic_run: ?diagnostic_types.Run = if (self.diagnostics) |configured|
            configured.start(allocator)
        else
            null;

        if (self.capabilities.len == 0 and options.capabilities.len == 0 and options.capability_layers.len == 0) {
            try ensureUniqueToolNames(self.tools);
            var hooks: std.ArrayList(LifecycleHook) = .empty;
            defer hooks.deinit(allocator);
            if (online_eval_run) |*online_state| try hooks.append(allocator, onlineEvalHook(online_state));
            try hooks.appendSlice(allocator, self.hooks);
            if (telemetry_run) |*instrumentation| try hooks.append(allocator, telemetryHook(instrumentation));
            if (diagnostic_run) |*diagnostics| try hooks.append(allocator, diagnosticHook(diagnostics));
            const controlled_hooks = try ControlledHooks.init(allocator, hooks.items, control);
            defer controlled_hooks.deinit(allocator);
            return self.runConfigured(allocator, prompt, options, controlled_stream_sink, controlled_output_validator, controlled_hooks.hooks, allow_pause, resume_state, decisions, control, null) catch |err| {
                emitLifecycle(controlled_hooks.hooks, .{ .run_error = .{ .failure = err } }) catch {};
                return err;
            };
        }
        var capability_arena = std.heap.ArenaAllocator.init(allocator);
        defer capability_arena.deinit();
        const capability_memory = capability_arena.allocator();
        const scoped = try flattenCapabilities(
            capability_memory,
            self.capabilities,
            options.capabilities,
            options.capability_layers,
        );
        const dependencies = options.dependencies orelse self.dependencies;
        var capability_runtime = try CapabilityRuntime.init(
            capability_memory,
            scoped,
            prompt,
            dependencies,
            control,
            if (resume_state) |state| state.messages else options.message_history,
            resume_state != null,
        );
        var instructions: std.ArrayList(Instruction) = .empty;
        try instructions.appendSlice(capability_memory, self.instructions);
        try capability_runtime.appendInitialInstructions(capability_memory, &instructions);
        var hooks: std.ArrayList(LifecycleHook) = .empty;
        if (online_eval_run) |*online_state| try hooks.append(capability_memory, onlineEvalHook(online_state));
        try hooks.appendSlice(capability_memory, self.hooks);
        var hook_count: usize = 0;
        for (scoped) |item| hook_count += item.capability.hooks.len;
        const capability_hook_adapters = try capability_memory.alloc(CapabilityHookAdapter, hook_count);
        var hook_index: usize = 0;
        for (scoped, 0..) |item, capability_index| {
            for (item.capability.hooks) |hook| {
                capability_hook_adapters[hook_index] = .{
                    .runtime = &capability_runtime,
                    .capability_index = capability_index,
                    .hook = hook,
                };
                try hooks.append(capability_memory, .{
                    .context = &capability_hook_adapters[hook_index],
                    .eventFn = CapabilityHookAdapter.emit,
                });
                hook_index += 1;
            }
        }

        var configured = self;
        configured.instructions = instructions.items;
        configured.capabilities = &.{};
        if (telemetry_run) |*instrumentation| {
            try hooks.append(capability_memory, telemetryHook(instrumentation));
        }
        if (diagnostic_run) |*diagnostics| {
            try hooks.append(capability_memory, diagnosticHook(diagnostics));
        }
        const controlled_hooks = try ControlledHooks.init(allocator, hooks.items, control);
        defer controlled_hooks.deinit(allocator);
        return configured.runConfigured(allocator, prompt, options, controlled_stream_sink, controlled_output_validator, controlled_hooks.hooks, allow_pause, resume_state, decisions, control, &capability_runtime) catch |err| {
            emitLifecycle(controlled_hooks.hooks, .{ .run_error = .{ .failure = err } }) catch {};
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
        control: model_types.RunControl,
        capability_runtime: ?*CapabilityRuntime,
    ) !RunOutcome {
        try control.check();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        var active = try activeCapabilityConfig(capability_runtime, memory, self);
        var active_generation: usize = if (capability_runtime) |runtime| runtime.generation else 0;
        var capability_snapshot: capability_types.Snapshot = if (capability_runtime) |runtime|
            try runtime.snapshot(memory)
        else
            .{};
        try requireRunModel(active.model.profile, self.system_prompt != null, stream_sink != null);
        var resolved_settings = active.model.settings
            .overrideWith(active.model_settings)
            .overrideWith(self.model_settings)
            .overrideWith(options.model_settings);
        try requireModelSettings(active.model.profile, resolved_settings);
        try ensureBuiltinToolsSupported(active.model.profile, active.builtin_tools);
        if (resume_state) |state|
            try ensureContentSupported(active.model, self.url_policy, state.messages)
        else
            try ensureContentSupported(active.model, self.url_policy, options.message_history);
        try ensurePromptPartsSupported(active.model, self.url_policy, options.prompt_parts);
        const invocation_started = monotonicNow(self.io);
        try emitLifecycle(hooks, .{ .run_start = .{ .prompt = prompt, .model = active.model } });

        var prepared_output = try prepareAgentOutput(memory, self.output, active.model.profile);

        const dependencies = options.dependencies orelse self.dependencies;
        const resolved_instructions = if (resume_state) |state|
            try copyStrings(memory, state.instructions)
        else
            try resolveInstructions(memory, self.instructions, options.instructions, .{
                .dependencies = dependencies,
                .prompt = prompt,
                .capabilities = capability_snapshot,
                .control = control,
            });
        var initial_instructions = resolved_instructions;
        if (prepared_output.prompted_instruction) |instruction| {
            initial_instructions = try appendString(memory, initial_instructions, instruction);
        }
        if (initial_instructions.len > 0 and !active.model.profile.supports_system_messages) {
            return Error.ModelDoesNotSupportSystemMessages;
        }

        var messages: std.ArrayList(Message) = .empty;
        var definitions: std.ArrayList(model_types.ToolDefinition) = .empty;
        var total_usage: usage_types.RunUsage = if (resume_state) |state|
            try state.usage.dupe(memory)
        else
            .{};
        if (resume_state) |state| {
            if (total_usage.requests == 0) total_usage.requests = state.model_requests;
            if (total_usage.requests != state.model_requests) return Error.InvalidDeferredState;
            total_usage.tool_calls = state.total_tool_calls;
        }
        var provider_errors = ProviderErrorCapture{ .target = self.provider_error_observer };
        var tool_retries = ToolRetryTracker{ .allocator = memory };

        if (resume_state) |state| {
            for (state.messages) |message| try appendMessageCopy(memory, &messages, message);
            try tool_retries.restore(state.tool_retries);
        } else {
            if (self.system_prompt) |system_prompt| {
                try appendSystemMessage(memory, &messages, system_prompt);
            }
            for (options.message_history) |message| try appendMessageCopy(memory, &messages, message);
            try appendPromptMessage(memory, &messages, prompt, options.prompt_parts, initial_instructions);
        }

        var model_requests: usize = if (resume_state) |state| state.model_requests else 0;
        var output_retries: usize = if (resume_state) |state| state.output_retries else 0;
        var total_tool_calls: usize = if (resume_state) |state| state.total_tool_calls else 0;
        var total_retry_delay_ms: u64 = 0;
        var resume_pending = resume_state != null;
        while (true) {
            if (capability_runtime) |runtime| if (active_generation != runtime.generation) {
                active = try runtime.assemble(memory, self);
                active_generation = runtime.generation;
                capability_snapshot = try runtime.snapshot(memory);
                try requireRunModel(active.model.profile, self.system_prompt != null, stream_sink != null);
                resolved_settings = active.model.settings
                    .overrideWith(active.model_settings)
                    .overrideWith(self.model_settings)
                    .overrideWith(options.model_settings);
                try requireModelSettings(active.model.profile, resolved_settings);
                try ensureBuiltinToolsSupported(active.model.profile, active.builtin_tools);
                try ensureContentSupported(active.model, self.url_policy, messages.items);
                prepared_output = try prepareAgentOutput(memory, self.output, active.model.profile);
            };
            var request_instructions = resolved_instructions;
            if (prepared_output.prompted_instruction) |instruction| {
                request_instructions = try appendString(memory, request_instructions, instruction);
            }
            if (!resume_pending) _ = try appendQueuedMessages(
                options.pending_messages,
                false,
                active.model,
                self.url_policy,
                memory,
                &messages,
                stream_sink,
                hooks,
            );
            const toolset_context = ToolsetContext{
                .messages = messages.items,
                .usage = total_usage,
                .model_requests = model_requests,
                .dependencies = dependencies,
                .capabilities = capability_snapshot,
                .control = control,
            };
            const available_tools = try prepareTools(
                memory,
                active.tools,
                active.toolsets,
                active.tool_policies,
                toolset_context,
            );
            try ensureUniqueToolNames(available_tools);
            if (capability_runtime) |runtime| if (runtime.hasOnDemand() and !runtime.hasDeferred()) {
                for (available_tools) |tool| {
                    if (std.mem.eql(u8, tool.definition.name, load_capability_tool_name)) {
                        return Error.DuplicateToolName;
                    }
                }
            };
            try ensureNoOutputToolConflicts(available_tools, prepared_output.tool_choices);
            if (available_tools.len > 0 and !active.model.profile.supports_tools) {
                return Error.ModelDoesNotSupportTools;
            }
            if (resume_pending) {
                const current_messages = messages.items;
                const tool_batch = try executeResumedToolCalls(
                    self,
                    available_tools,
                    memory,
                    current_messages,
                    decisions,
                    resume_state.?.calls,
                    &tool_retries,
                    .{
                        .dependencies = dependencies,
                        .messages = current_messages,
                        .usage = total_usage,
                        .model_requests = model_requests,
                        .capabilities = capability_snapshot,
                        .cancellation = self.cancellation,
                        .io = self.io,
                        .deadline = control.deadline,
                    },
                    hooks,
                    options.durable,
                );
                if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{
                    .deferred_tool_results = .{ .results = tool_batch.parts },
                });
                try messages.append(memory, .{ .request = .{ .parts = tool_batch.parts } });
                try appendToolFollowUps(active.model, self.url_policy, memory, &messages, tool_batch.follow_up_messages);
                const restored = try appendPendingMessageCopies(
                    active.model,
                    self.url_policy,
                    memory,
                    &messages,
                    resume_state.?.pending_messages,
                );
                if (restored.len > 0) if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{
                    .enqueued_messages = .{ .messages = restored },
                });
                resume_pending = false;
                continue;
            }
            definitions.clearRetainingCapacity();
            for (available_tools) |tool| try definitions.append(memory, tool.definition);
            try definitions.appendSlice(memory, prepared_output.tool_definitions);
            const history_context = history.Context{
                .profile = active.model.profile,
                .usage = total_usage,
                .model_requests = model_requests,
                .control = control,
            };
            var request_messages = try history.processAll(
                memory,
                active.history_processors,
                history_context,
                messages.items,
            );
            request_messages = try history.processAll(
                memory,
                options.history_processors,
                history_context,
                request_messages,
            );
            request_messages = try prepareContext(
                memory,
                options.context_budget orelse self.context_budget,
                .{
                    .provider_name = active.model.provider_name,
                    .model_name = active.model.model_name,
                    .messages = request_messages,
                    .instructions = request_instructions,
                    .tools = definitions.items,
                    .builtin_tools = active.builtin_tools,
                    .output = prepared_output.model_format,
                    .settings = resolved_settings,
                },
                control,
            );
            var idempotency_key_storage: [32]u8 = undefined;
            const idempotency_key = if (active.model.profile.supports_idempotency_key and self.retry_policy.max_retries > 0)
                generateIdempotencyKey(self.io orelse return Error.RetryIdempotencyRequiresIo, &idempotency_key_storage)
            else
                null;
            var retries: usize = 0;
            var response = request: while (true) {
                try control.check();
                if (model_requests >= self.limits.max_model_requests) {
                    return Error.MaxModelRequestsExceeded;
                }
                model_requests += 1;
                provider_errors.reset();
                var stream_emitted = false;
                var forwarder = ModelEventForwarder{
                    .allocator = allocator,
                    .sink = stream_sink,
                    .emitted = &stream_emitted,
                    .hooks = hooks,
                    .prepared_output = prepared_output,
                    .validators = active.output_validators,
                    .run_context = .{
                        .dependencies = dependencies,
                        .messages = messages.items,
                        .usage = total_usage,
                        .model_requests = model_requests,
                        .capabilities = capability_snapshot,
                        .partial_output = true,
                        .control = control,
                    },
                    .max_tool_parts = self.limits.max_tool_calls,
                };
                defer forwarder.deinit();
                const model_request = model_types.ModelRequest{
                    .messages = request_messages,
                    .instructions = request_instructions,
                    .tools = definitions.items,
                    .builtin_tools = active.builtin_tools,
                    .output = prepared_output.model_format,
                    .error_observer = provider_errors.observer(),
                    .error_policy = self.provider_error_policy,
                    .url_policy = self.url_policy,
                    .request_id = options.request_id,
                    .idempotency_key = idempotency_key,
                    .timeout_ms = try control.timeoutMilliseconds(self.request_timeout_ms),
                    .cancellation = self.cancellation,
                    .settings = resolved_settings,
                };
                try emitLifecycle(hooks, .{ .model_request_start = .{
                    .number = model_requests,
                    .request = model_request,
                    .streaming = stream_sink != null,
                } });
                const request_started = monotonicNow(self.io);
                const attempt = if (options.durable) |binding|
                    if (stream_sink != null)
                        control.invoke(
                            model_types.ModelResponse,
                            streamModelDurable,
                            .{ binding, memory, model_request, model_requests, forwarder.modelSink() },
                        )
                    else
                        control.invoke(
                            model_types.ModelResponse,
                            requestModelDurable,
                            .{ binding, memory, model_request, model_requests },
                        )
                else if (stream_sink != null)
                    control.invoke(
                        model_types.ModelResponse,
                        streamModel,
                        .{ active.model, memory, model_request, forwarder.modelSink() },
                    )
                else
                    control.invoke(
                        model_types.ModelResponse,
                        requestModel,
                        .{ active.model, memory, model_request },
                    );
                const value = attempt catch |err| {
                    try total_usage.recordRequest(elapsedMilliseconds(self.io, request_started));
                    const retry_candidate = !stream_emitted and retries < self.retry_policy.max_retries and
                        shouldRetry(err, self.retry_policy);
                    const delay_ms = if (retry_candidate) if (self.retry_policy.backoff) |backoff|
                        backoffDelayMilliseconds(
                            self.io orelse return Error.RetryBackoffRequiresIo,
                            backoff,
                            retries + 1, // kcov-ignore
                            provider_errors.retry_after_seconds,
                        )
                    else
                        0 else 0;
                    const within_budget = if (self.retry_policy.max_total_delay_ms) |maximum|
                        delay_ms <= maximum -| total_retry_delay_ms
                    else
                        true;
                    const will_retry = retry_candidate and within_budget;
                    try emitLifecycle(hooks, .{ .model_request_error = .{
                        .number = model_requests,
                        .failure = err,
                        .will_retry = will_retry,
                    } });
                    if (err == error.RequestCancelled) return Error.Cancelled;
                    if (will_retry) {
                        retries += 1;
                        total_retry_delay_ms += delay_ms;
                        if (self.retry_policy.before_retry) |hook| {
                            const retry_event = RetryEvent{
                                .failure = err,
                                .retry_number = retries,
                                .model_requests = model_requests,
                                .retry_after_seconds = provider_errors.retry_after_seconds,
                                .rate_limit_remaining_requests = provider_errors.rate_limit_remaining_requests,
                                .rate_limit_remaining_tokens = provider_errors.rate_limit_remaining_tokens,
                                .provider_request_id = provider_errors.requestId(),
                                .delay_ms = delay_ms,
                                .total_delay_ms = total_retry_delay_ms,
                            };
                            try control.invoke(void, invokeRetryHook, .{ hook, retry_event });
                        }
                        if (self.retry_policy.backoff != null) {
                            const io = self.io orelse return Error.RetryBackoffRequiresIo;
                            try sleepBackoff(io, delay_ms, control);
                        }
                        continue;
                    }
                    return err;
                };
                const request_duration = elapsedMilliseconds(self.io, request_started);
                try total_usage.recordRequest(request_duration);
                var accounted = value;
                accounted.usage.duration_ms = request_duration;
                break :request accounted;
            };
            if (response.usage.cost == null) if (self.price_table) |table| {
                if (active.model.provider_name) |provider_name| if (active.model.model_name) |model_name| {
                    const estimate = table.estimate(provider_name, model_name, response.usage) catch
                        return Error.UsageOverflow;
                    if (estimate) |value| {
                        response.usage.cost = value.cost;
                        response.usage.cost_source = .price_table;
                        response.usage.cost_table_version = value.table_version;
                    }
                };
            };
            try emitLifecycle(hooks, .{ .model_request_end = .{
                .number = model_requests,
                .response = response,
            } });
            try total_usage.addRequest(memory, response.usage);
            try enforceUsageLimits(total_usage, self.limits);
            try enforceFinishReason(response.finish_reason);
            if (response.parts.len == 0) return Error.EmptyModelResponse;

            try messages.append(memory, .{ .response = try copyResponseMessage(memory, response) });
            const agent_parts = try normalizeAgentResponseParts(memory, response.parts);

            var tool_call_count: usize = 0;
            for (agent_parts) |part| switch (part) {
                .tool_call => tool_call_count += 1,
                else => {},
            };

            if (tool_call_count == 0) {
                if (try appendQueuedMessages(
                    options.pending_messages,
                    false,
                    active.model,
                    self.url_policy,
                    memory,
                    &messages,
                    stream_sink,
                    hooks,
                )) continue;
                if (prepared_output.requires_tool_output) {
                    if (output_retries >= self.max_output_retries) return Error.OutputToolRequired;
                    output_retries += 1;
                    try appendRetryMessage(
                        memory,
                        &messages,
                        "Return the final result by calling one of the provided output tools.",
                    );
                    continue;
                }
                const raw_output = try collectText(memory, agent_parts);
                try emitLifecycle(hooks, .{ .output_validation_start = .{
                    .output = raw_output,
                    .retry_number = output_retries,
                } });
                const validation = try validateFinalOutput(
                    memory,
                    prepared_output.validation_format,
                    self.validate_output_locally or prepared_output.validation_required,
                    raw_output,
                    null,
                    active.output_validators,
                    .{
                        .dependencies = dependencies,
                        .messages = messages.items,
                        .usage = total_usage,
                        .model_requests = model_requests,
                        .capabilities = capability_snapshot,
                        .control = control,
                    },
                    output_validator,
                );
                const output = switch (validation) {
                    .accepted => |accepted| accepted,
                    .retry => |retry| retry: {
                        const failure = retry.failure orelse error.OutputValidationRetry;
                        const will_retry = output_retries < self.max_output_retries;
                        try emitLifecycle(hooks, .{ .output_validation_error = .{
                            .output = raw_output,
                            .failure = failure,
                            .retry_number = output_retries,
                            .will_retry = will_retry,
                        } });
                        try consumeOutputRetry(self.max_output_retries, &output_retries, retry.failure);
                        if (retry.message.len > self.tool_limits.max_result_bytes) return Error.ToolResultTooLarge;
                        try appendRetryMessage(memory, &messages, retry.message);
                        break :retry null;
                    },
                } orelse continue;
                try emitLifecycle(hooks, .{ .output_validation_end = .{
                    .output = output,
                    .retry_number = output_retries,
                } });
                if (try appendQueuedMessages(
                    options.pending_messages,
                    true,
                    active.model,
                    self.url_policy,
                    memory,
                    &messages,
                    stream_sink,
                    hooks,
                )) continue;
                if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{ .final_result = .{
                    .output = output,
                    .structured_output = try structuredOutputSnapshot(
                        memory,
                        prepared_output.validation_format,
                        output,
                    ),
                } });
                addRunDuration(&total_usage, self.io, invocation_started) catch return Error.UsageOverflow;
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
            total_usage.tool_calls = total_tool_calls;
            if (!active.model.profile.supports_tools) return Error.ModelDoesNotSupportTools;
            if (tool_call_count > 1 and
                (!active.model.profile.supports_parallel_tool_calls or resolved_settings.parallel_tool_calls == false))
            {
                return Error.ParallelToolCallsNotSupported;
            }
            var ordinary_tool_call_count: usize = 0;
            for (agent_parts) |part| switch (part) {
                .tool_call => |call| if (prepared_output.findToolChoice(call.name) == null) {
                    ordinary_tool_call_count += 1;
                },
                else => {},
            };
            const tool_run_context = model_types.ToolRunContext{
                .dependencies = dependencies,
                .messages = messages.items,
                .usage = total_usage,
                .model_requests = model_requests,
                .capabilities = capability_snapshot,
                .cancellation = self.cancellation,
                .io = self.io,
                .deadline = control.deadline,
            };
            const tool_work = try resolveToolCalls(
                available_tools,
                memory,
                agent_parts,
                ordinary_tool_call_count,
                prepared_output,
                &tool_retries,
                tool_run_context,
                active.tool_policies,
                hooks,
                total_tool_calls - tool_call_count + 1,
            );
            if (hasDeferredToolCall(tool_work)) {
                if (!allow_pause) return Error.ToolCallRequiresDeferredRun;
                const pending_queue = options.pending_messages;
                const pending = try closeAndCopyPendingMessages(
                    pending_queue,
                    active.model,
                    self.url_policy,
                    memory,
                );
                addRunDuration(&total_usage, self.io, invocation_started) catch return Error.UsageOverflow;
                const paused = try createPausedRun(
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
                    agent_parts,
                    tool_work,
                    pending,
                );
                if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{
                    .deferred_tool_requests = .{ .requests = paused.calls },
                });
                return .{ .paused = paused };
            }

            if (stream_sink) |sink| for (agent_parts) |part| switch (part) {
                .tool_call => |call| try emitStreamEvent(hooks, sink, .{
                    .function_tool_call = .{ .call = call },
                }),
                else => {},
            };

            var has_output_call = false;
            for (agent_parts) |part| switch (part) {
                .tool_call => |call| if (prepared_output.findToolChoice(call.name) != null) {
                    has_output_call = true;
                },
                else => {},
            };
            if (has_output_call) {
                const output_run_context = output_types.RunContext{
                    .dependencies = dependencies,
                    .messages = messages.items,
                    .usage = total_usage,
                    .model_requests = model_requests,
                    .capabilities = capability_snapshot,
                    .control = control,
                };
                const records = try memory.alloc(?RequestPart, tool_call_count);
                @memset(records, null);
                var follow_up_messages: std.ArrayList(model_types.RequestMessage) = .empty;
                var selected: ?SelectedOutput = null;
                var ordinary_failure = false;

                if (self.end_strategy == .early) {
                    var ordinal: usize = 0;
                    for (agent_parts) |part| switch (part) {
                        .tool_call => |call| {
                            const choice = prepared_output.findToolChoice(call.name) orelse {
                                ordinal += 1;
                                continue;
                            };
                            if (selected != null) {
                                records[ordinal] = outputToolResult(
                                    call,
                                    "Tool not executed because a final output was already selected.",
                                    .interrupted,
                                );
                                ordinal += 1;
                                continue;
                            }
                            const attempt = try processOutputCall(
                                memory,
                                choice,
                                call,
                                output_run_context,
                                active.output_validators,
                                hooks,
                                output_retries,
                                self.max_output_retries,
                            );
                            switch (attempt) {
                                .selected => |value| {
                                    selected = value;
                                    records[ordinal] = outputToolResult(call, "Final output accepted.", .success);
                                },
                                .retry => |retry| {
                                    try consumeOutputRetry(self.max_output_retries, &output_retries, retry.failure);
                                    if (retry.message.len > self.tool_limits.max_result_bytes) {
                                        return Error.ToolResultTooLarge;
                                    }
                                    records[ordinal] = outputToolResult(call, retry.message, .failed);
                                },
                            }
                            ordinal += 1;
                        },
                        else => {},
                    };
                }

                var ordinal: usize = 0;
                for (agent_parts) |part| switch (part) {
                    .tool_call => |call| {
                        if (records[ordinal] != null) {
                            ordinal += 1;
                            continue;
                        }
                        if (prepared_output.findToolChoice(call.name)) |choice| {
                            if (selected != null and self.end_strategy != .exhaustive) {
                                records[ordinal] = outputToolResult(
                                    call,
                                    "Tool not executed because a final output was already selected.",
                                    .interrupted,
                                );
                            } else {
                                const attempt = try processOutputCall(
                                    memory,
                                    choice,
                                    call,
                                    output_run_context,
                                    active.output_validators,
                                    hooks,
                                    output_retries,
                                    self.max_output_retries,
                                );
                                switch (attempt) {
                                    .selected => |value| {
                                        if (selected == null) selected = value;
                                        records[ordinal] = outputToolResult(call, "Final output accepted.", .success);
                                    },
                                    .retry => |retry| {
                                        try consumeOutputRetry(self.max_output_retries, &output_retries, retry.failure);
                                        if (retry.message.len > self.tool_limits.max_result_bytes) {
                                            return Error.ToolResultTooLarge;
                                        }
                                        records[ordinal] = outputToolResult(call, retry.message, .failed);
                                    },
                                }
                            }
                        } else if (selected != null and self.end_strategy != .exhaustive) {
                            records[ordinal] = outputToolResult(
                                call,
                                "Tool not executed because a final output was already selected.",
                                .interrupted,
                            );
                        } else {
                            const one_work = findToolWork(tool_work, call.id) orelse return Error.UnknownTool;
                            const one = [_]ToolWork{one_work};
                            const batch = try executeToolCalls(
                                self,
                                available_tools,
                                memory,
                                &one,
                                &tool_retries,
                                tool_run_context,
                                active.tool_policies,
                                hooks,
                                options.durable,
                            );
                            records[ordinal] = batch.parts[0];
                            ordinary_failure = ordinary_failure or batch.parts[0].tool_return.isError();
                            try follow_up_messages.appendSlice(memory, batch.follow_up_messages);
                        }
                        ordinal += 1;
                    },
                    else => {},
                };

                const result_parts = try memory.alloc(RequestPart, records.len);
                for (records, result_parts) |record, *result_part| result_part.* = record.?;
                if (capability_runtime) |runtime| runtime.commitPending();
                if (stream_sink) |sink| for (result_parts) |part| try emitStreamEvent(hooks, sink, .{
                    .function_tool_result = .{ .result = part.tool_return },
                });
                try messages.append(memory, .{ .request = .{ .parts = result_parts } });
                try appendToolFollowUps(
                    active.model,
                    self.url_policy,
                    memory,
                    &messages,
                    follow_up_messages.items,
                );

                if (selected) |final| if (!ordinary_failure and follow_up_messages.items.len == 0) {
                    if (final.output.len > self.tool_limits.max_result_bytes) return Error.ToolResultTooLarge;
                    if (try appendQueuedMessages(
                        options.pending_messages,
                        true,
                        active.model,
                        self.url_policy,
                        memory,
                        &messages,
                        stream_sink,
                        hooks,
                    )) continue;
                    if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{ .final_result = .{
                        .output = final.output,
                        .output_name = final.name,
                        .structured_output = try structuredOutputSnapshot(
                            memory,
                            final.structured_format,
                            final.output,
                        ),
                    } });
                    addRunDuration(&total_usage, self.io, invocation_started) catch return Error.UsageOverflow;
                    try emitLifecycle(hooks, .{ .run_end = .{
                        .output = final.output,
                        .usage = total_usage,
                        .model_requests = model_requests,
                    } });
                    return .{ .complete = .{
                        .arena = arena,
                        .output = final.output,
                        .output_name = final.name,
                        .messages = try messages.toOwnedSlice(memory),
                        .usage = total_usage,
                        .model_requests = model_requests,
                        .finish_reason = response.finish_reason,
                    } };
                };
                continue;
            }

            const tool_batch = try executeToolCalls(
                self,
                available_tools,
                memory,
                tool_work,
                &tool_retries,
                tool_run_context,
                active.tool_policies,
                hooks,
                options.durable,
            );
            if (capability_runtime) |runtime| runtime.commitPending();
            if (stream_sink) |sink| for (tool_batch.parts) |part| {
                try emitStreamEvent(hooks, sink, .{
                    .function_tool_result = .{ .result = part.tool_return },
                });
            };
            try messages.append(memory, .{ .request = .{ .parts = tool_batch.parts } });
            try appendToolFollowUps(active.model, self.url_policy, memory, &messages, tool_batch.follow_up_messages);
        }
    }
};

fn flattenCapabilities(
    allocator: std.mem.Allocator,
    agent_capabilities: []const Capability,
    run_capabilities: []const Capability,
    layers: []const CapabilityLayer,
) ![]const ScopedCapability {
    var flattened: std.ArrayList(ScopedCapability) = .empty;
    for ([_]capability_types.Scope{ .inherited, .agent, .run, .nested, .subagent }) |scope| {
        if (scope == .agent) {
            for (agent_capabilities, 0..) |capability, source_index| try flattened.append(allocator, .{
                .capability = capability,
                .scope = .agent,
                .source_index = source_index,
            });
        } else if (scope == .run) {
            for (run_capabilities, 0..) |capability, source_index| try flattened.append(allocator, .{
                .capability = capability,
                .scope = .run,
                .source_index = source_index,
            });
        }
        for (layers) |layer| {
            if (layer.scope != scope) continue;
            for (layer.capabilities, 0..) |capability, source_index| try flattened.append(allocator, .{
                .capability = capability,
                .scope = scope,
                .source_index = source_index,
            });
        }
    }
    return flattened.toOwnedSlice(allocator);
}

fn normalizeAgentResponseParts(
    allocator: std.mem.Allocator,
    parts: []const ResponsePart,
) ![]const ResponsePart {
    var requires_normalization = false;
    for (parts) |part| if (part == .capability_load_call) {
        requires_normalization = true;
    };
    if (!requires_normalization) return parts;
    const normalized = try allocator.alloc(ResponsePart, parts.len);
    for (parts, normalized) |part, *result| result.* = switch (part) {
        .capability_load_call => |call| .{ .tool_call = .{
            .id = call.call_id,
            .name = load_capability_tool_name,
            .arguments_json = try std.json.Stringify.valueAlloc(
                allocator,
                LoadCapabilityArguments{ .id = call.capability_id },
                .{},
            ),
            .tool_kind = .capability_load,
        } },
        else => part,
    };
    return normalized;
}

fn activeCapabilityConfig(
    runtime: ?*CapabilityRuntime,
    allocator: std.mem.Allocator,
    agent: Agent,
) !ActiveCapabilities {
    if (runtime) |configured| return configured.assemble(allocator, agent);
    return .{
        .model = agent.model,
        .tools = agent.tools,
        .builtin_tools = agent.builtin_tools,
        .toolsets = agent.toolsets,
        .tool_policies = agent.tool_policies,
        .history_processors = agent.history_processors,
        .output_validators = agent.output_validators,
        .model_settings = .{},
    };
}

fn requireRunModel(
    profile: model_types.ModelProfile,
    has_system_prompt: bool,
    streaming: bool,
) Agent.Error!void {
    if (streaming and !profile.supports_streaming) return Agent.Error.ModelDoesNotSupportStreaming;
    if (has_system_prompt and !profile.supports_system_messages) {
        return Agent.Error.ModelDoesNotSupportSystemMessages;
    }
}

fn prepareAgentOutput(
    allocator: std.mem.Allocator,
    spec: output_types.Spec,
    profile: model_types.ModelProfile,
) !output_types.Prepared {
    return output_types.prepare(allocator, spec, profile) catch |failure| switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidOutputSpec => Agent.Error.InvalidOutputSpec,
        error.JsonObjectOutputNotSupported => Agent.Error.ModelDoesNotSupportJsonObjectOutput,
        error.NativeOutputNotSupported => Agent.Error.ModelDoesNotSupportJsonSchemaOutput,
        error.PromptedOutputNotSupported => Agent.Error.ModelDoesNotSupportPromptedOutput,
        error.ToolOutputNotSupported => Agent.Error.ModelDoesNotSupportTools,
    };
}

fn copyStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const copied = try allocator.alloc([]const u8, values.len);
    for (values, copied) |value, *target| target.* = try allocator.dupe(u8, value);
    return copied;
}

fn appendString(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    value: []const u8,
) ![]const []const u8 {
    const appended = try allocator.alloc([]const u8, values.len + 1);
    @memcpy(appended[0..values.len], values);
    appended[values.len] = value;
    return appended;
}

fn hasDeferredToolCall(work: []const ToolWork) bool {
    for (work) |item| if (item.validation_failure == null and item.execution != .immediate) return true;
    return false;
}

fn createPausedRun(
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    messages: []const Message,
    instructions: []const []const u8,
    usage: usage_types.RunUsage,
    model_requests: usize,
    total_tool_calls: usize,
    output_retries: usize,
    retry_entries: []const ToolRetryTracker.Entry,
    tools: []const model_types.Tool,
    parts: []const Part,
    work: []const ToolWork,
    pending_messages: []const Message,
) !PausedRun {
    var calls: std.ArrayList(DeferredToolCall) = .empty;
    var resolved_calls: std.ArrayList(SerializedResolvedToolCall) = .empty;
    for (parts) |part| switch (part) {
        .tool_call => |call| {
            _ = findTool(tools, call.name) orelse continue;
            const resolved = findToolWork(work, call.id) orelse continue;
            const call_id = try allocator.dupe(u8, call.id);
            const name = try allocator.dupe(u8, call.name);
            const arguments_json = try allocator.dupe(u8, resolved.arguments_json);
            const saved = SerializedResolvedToolCall{
                .call_id = call_id,
                .name = name,
                .arguments_json = arguments_json,
                .model_arguments_json = try allocator.dupe(u8, call.arguments_json),
                .execution = if (resolved.validation_failure != null or resolved.retry_message != null)
                    .immediate
                else
                    resolved.execution,
                .retry_number = resolved.retry_number,
                .durable_sequence = resolved.durable_sequence,
            };
            try resolved_calls.append(allocator, saved);
            if (saved.execution != .immediate) try calls.append(allocator, .{
                .call_id = call_id,
                .name = name,
                .arguments_json = arguments_json,
                .execution = saved.execution,
            });
        },
        else => {},
    };
    const paused_calls = try calls.toOwnedSlice(allocator);
    const saved_calls = try resolved_calls.toOwnedSlice(allocator);
    const retries = try allocator.alloc(SerializedToolRetry, retry_entries.len);
    for (retry_entries, retries) |entry, *retry| retry.* = .{
        .name = entry.name,
        .count = entry.count,
    };
    const history_json = try history.stringify(allocator, messages);
    const pending_history_json = if (pending_messages.len > 0)
        try history.stringify(allocator, pending_messages)
    else
        null;
    const state_json = try std.json.Stringify.valueAlloc(allocator, SerializedPause{
        .version = 2,
        .prompt = prompt,
        .history_json = history_json,
        .instructions = instructions,
        .usage = usage,
        .model_requests = model_requests,
        .total_tool_calls = total_tool_calls,
        .output_retries = output_retries,
        .tool_retries = retries,
        .calls = saved_calls,
        .pending_history_json = pending_history_json,
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
    saved_calls: []const SerializedResolvedToolCall,
    tool_retries: *ToolRetryTracker,
    run_context: model_types.ToolRunContext,
    hooks: []const LifecycleHook,
    durable: ?durable_types.Binding,
) !ToolCallBatch {
    if (messages.len == 0) return Agent.Error.InvalidDeferredState;
    const assistant = switch (messages[messages.len - 1]) {
        .response => |response| response,
        .request => return Agent.Error.InvalidDeferredState,
    };
    var call_count: usize = 0;
    for (assistant.parts) |part| switch (part) {
        .tool_call => call_count += 1,
        else => {},
    };
    if (call_count == 0) return Agent.Error.InvalidDeferredState;
    for (decisions, 0..) |decision, index| {
        for (decisions[index + 1 ..]) |other| {
            if (std.mem.eql(u8, decision.call_id, other.call_id)) return Agent.Error.UnexpectedDeferredToolDecision;
        }
        var found = false;
        for (saved_calls) |saved| if (std.mem.eql(u8, saved.call_id, decision.call_id)) {
            found = saved.execution != .immediate;
        };
        if (!found) return Agent.Error.UnexpectedDeferredToolDecision;
    }
    try validateDeferredCalls(tools, assistant.parts, saved_calls);

    const results = try allocator.alloc(RequestPart, call_count);
    var follow_up_messages: std.ArrayList(model_types.RequestMessage) = .empty;
    var result_index: usize = 0;
    for (assistant.parts) |part| switch (part) {
        .tool_call => |call| {
            const tool_index = findToolIndex(tools, call.name) orelse return Agent.Error.UnknownTool;
            const tool = tools[tool_index];
            const saved = saved_calls[result_index];
            const durable_sequence = saved.durable_sequence orelse if (durable != null)
                return Agent.Error.InvalidDeferredState
            else
                0;
            try emitLifecycle(hooks, .{ .tool_validation_start = .{ .call = call } });
            toolRunControl(run_context).invoke(
                void,
                validateToolArguments,
                .{ tool, allocator, saved.arguments_json },
            ) catch |failure| {
                try emitLifecycle(hooks, .{ .tool_validation_error = .{ .call = call, .failure = failure } }); // kcov-ignore
                const work = ToolWork{
                    .call = call,
                    .tool_index = tool_index,
                    .arguments_json = saved.arguments_json,
                    .execution = saved.execution,
                    .retry_number = saved.retry_number,
                    .durable_sequence = durable_sequence,
                    .validation_failure = failure,
                };
                const processed = try toolResult(
                    agent,
                    tools,
                    allocator,
                    work,
                    tool_retries,
                    .{ .failure = failure },
                );
                results[result_index] = .{ .tool_return = processed.result };
                try follow_up_messages.appendSlice(allocator, processed.follow_up_messages);
                result_index += 1;
                continue;
            };
            try emitLifecycle(hooks, .{ .tool_validation_end = .{ .call = call, .tool = tool } });

            switch (saved.execution) {
                .immediate => {
                    try emitLifecycle(hooks, .{ .tool_execution_start = .{ .call = call, .tool = tool } });
                    const outcome = executeToolWorkControlled(
                        agent.io,
                        durable,
                        tool,
                        effectiveToolLimits(agent.tool_limits, tool.limits),
                        allocator,
                        run_context,
                        .{
                            .call = call,
                            .tool_index = tool_index,
                            .arguments_json = saved.arguments_json,
                            .execution = saved.execution,
                            .retry_number = saved.retry_number,
                            .durable_sequence = durable_sequence,
                        },
                        agent.tool_policies,
                    );
                    try emitToolOutcome(hooks, tool, call, outcome);
                    const processed = try toolResult(
                        agent,
                        tools,
                        allocator,
                        .{
                            .call = call,
                            .tool_index = tool_index,
                            .arguments_json = saved.arguments_json,
                            .execution = saved.execution,
                            .retry_number = saved.retry_number,
                            .durable_sequence = durable_sequence,
                        },
                        tool_retries,
                        outcome,
                    );
                    results[result_index] = .{ .tool_return = processed.result };
                    try follow_up_messages.appendSlice(allocator, processed.follow_up_messages);
                },
                .requires_approval => {
                    const approved = try requireResumeDecision(decisions, call.id);
                    switch (approved.action) {
                        .approve => {
                            try emitLifecycle(hooks, .{ .tool_execution_start = .{ .call = call, .tool = tool } });
                            const outcome = executeToolWorkControlled(
                                agent.io,
                                durable,
                                tool,
                                effectiveToolLimits(agent.tool_limits, tool.limits),
                                allocator,
                                run_context,
                                .{
                                    .call = call,
                                    .tool_index = tool_index,
                                    .arguments_json = saved.arguments_json,
                                    .execution = saved.execution,
                                    .retry_number = saved.retry_number,
                                    .durable_sequence = durable_sequence,
                                },
                                agent.tool_policies,
                            );
                            try emitToolOutcome(hooks, tool, call, outcome);
                            const processed = try toolResult(
                                agent,
                                tools,
                                allocator,
                                .{
                                    .call = call,
                                    .tool_index = tool_index,
                                    .arguments_json = saved.arguments_json,
                                    .execution = saved.execution,
                                    .retry_number = saved.retry_number,
                                    .durable_sequence = durable_sequence,
                                },
                                tool_retries,
                                outcome,
                            );
                            results[result_index] = .{ .tool_return = processed.result };
                            try follow_up_messages.appendSlice(allocator, processed.follow_up_messages);
                        },
                        .deny => results[result_index] = .{ .tool_return = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = approved.content orelse "Tool call denied by reviewer.",
                            .is_error = true,
                        } },
                        .result => results[result_index] = .{ .tool_return = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = approved.content orelse "",
                            .is_error = approved.is_error,
                        } },
                    }
                },
                .external => {
                    const supplied = try requireResumeDecision(decisions, call.id);
                    switch (supplied.action) {
                        .approve => return Agent.Error.DeferredToolRequiresResult,
                        .deny => results[result_index] = .{ .tool_return = .{
                            .call_id = call.id,
                            .name = call.name,
                            .content = supplied.content orelse "Tool call denied by reviewer.",
                            .is_error = true,
                        } },
                        .result => results[result_index] = .{ .tool_return = .{
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
    return .{
        .parts = results,
        .follow_up_messages = try follow_up_messages.toOwnedSlice(allocator),
    };
}

fn validateDeferredCalls(
    tools: []const model_types.Tool,
    parts: []const Part,
    saved_calls: []const SerializedResolvedToolCall,
) !void {
    var saved_index: usize = 0;
    for (parts) |part| switch (part) {
        .tool_call => |call| {
            _ = findTool(tools, call.name) orelse return Agent.Error.UnknownTool;
            if (saved_index >= saved_calls.len) return Agent.Error.InvalidDeferredState;
            const saved = saved_calls[saved_index];
            if (!std.mem.eql(u8, saved.call_id, call.id) or
                !std.mem.eql(u8, saved.name, call.name) or
                !std.mem.eql(u8, saved.model_arguments_json, call.arguments_json))
            {
                return Agent.Error.InvalidDeferredState;
            }
            saved_index += 1;
        },
        else => {},
    };
    if (saved_index != saved_calls.len) return Agent.Error.InvalidDeferredState;
}

fn requireResumeDecision(decisions: []const ResumeDecision, call_id: []const u8) Agent.Error!ResumeDecision {
    for (decisions) |decision| {
        if (std.mem.eql(u8, decision.call_id, call_id)) return decision;
    }
    return Agent.Error.MissingDeferredToolDecision;
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
            _ = try json_limits.parseLeaky(
                Output,
                allocator,
                output,
                json_limits.defaults.tool_payload,
                .{ .ignore_unknown_fields = false },
                Agent.Error.InvalidTypedOutput,
            );
        }
    };
    return .{ .context = &Wrapper.placeholder, .validateFn = Wrapper.validate };
}

const ValidationAttempt = union(enum) {
    accepted: []const u8,
    retry: struct {
        message: []const u8,
        failure: ?anyerror = null,
    },
};

const schema_retry_message = "The previous response did not match the required output schema. " ++
    "Return only valid JSON matching the schema.";

fn validateFinalOutput(
    allocator: std.mem.Allocator,
    output_format: model_types.OutputFormat,
    validate_locally: bool,
    initial_output: []const u8,
    output_name: ?[]const u8,
    validators: []const output_types.Validator,
    run_context: output_types.RunContext,
    typed_validator: ?OutputValidator,
) !ValidationAttempt {
    if (validate_locally) json_schema.validate(allocator, output_format, initial_output) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return .{ .retry = .{ .message = schema_retry_message, .failure = failure } };
    };
    var output = initial_output;
    for (validators) |validator| {
        const result = try run_context.control.invoke(
            output_types.ValidatorResult,
            invokeConfiguredOutputValidator,
            .{ validator, allocator, run_context, output_name, output },
        );
        switch (result) {
            .output => |transformed| output = transformed,
            .retry => |message| return .{ .retry = .{ .message = message } },
        }
    }
    if (output_format != .text and validators.len > 0) {
        json_schema.validate(allocator, output_format, output) catch |failure| {
            if (failure == error.OutOfMemory) return failure;
            return .{ .retry = .{ .message = schema_retry_message, .failure = failure } };
        };
    }
    if (typed_validator) |validator| validator.validate(allocator, output) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return .{ .retry = .{ .message = schema_retry_message, .failure = failure } };
    };
    return .{ .accepted = output };
}

fn invokeConfiguredOutputValidator(
    validator: output_types.Validator,
    allocator: std.mem.Allocator,
    run_context: output_types.RunContext,
    output_name: ?[]const u8,
    output: []const u8,
) !output_types.ValidatorResult {
    return validator.validate(allocator, run_context, output_name, output);
}

const SelectedOutput = struct {
    name: []const u8,
    output: []const u8,
    structured_format: model_types.OutputFormat,
};

const OutputAttempt = union(enum) {
    selected: SelectedOutput,
    retry: struct {
        message: []const u8,
        failure: ?anyerror = null,
    },
};

fn processOutputCall(
    allocator: std.mem.Allocator,
    prepared: output_types.PreparedChoice,
    call: model_types.ToolCall,
    run_context: output_types.RunContext,
    validators: []const output_types.Validator,
    hooks: []const LifecycleHook,
    retry_number: usize,
    max_retries: usize,
) !OutputAttempt {
    const arguments = output_types.decodeToolArguments(allocator, prepared, call.arguments_json) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return .{ .retry = .{
            .message = "The output arguments did not match this tool's schema. Correct them and try again.",
            .failure = failure,
        } };
    };
    const selected: SelectedOutput = if (prepared.choice.function) |function| selected: {
        const result = try run_context.control.invoke(
            output_types.FunctionResult,
            invokeOutputFunction,
            .{ function, allocator, run_context, arguments },
        );
        break :selected switch (result) {
            .output => |output| .{
                .name = prepared.choice.name,
                .output = output,
                .structured_format = .text,
            },
            .retry => |message| return .{ .retry = .{ .message = message } },
        };
    } else .{
        .name = prepared.choice.name,
        .output = arguments,
        .structured_format = .{ .json_schema = .{
            .name = prepared.choice.name,
            .schema = prepared.choice.schema,
            .strict = prepared.choice.strict,
        } },
    };
    try emitLifecycle(hooks, .{ .output_validation_start = .{
        .output = selected.output,
        .retry_number = retry_number,
    } });
    const validation = validateFinalOutput(
        allocator,
        selected.structured_format,
        selected.structured_format != .text,
        selected.output,
        selected.name,
        validators,
        run_context,
        null,
    ) catch |failure| {
        try emitLifecycle(hooks, .{ .output_validation_error = .{
            .output = selected.output,
            .failure = failure,
            .retry_number = retry_number,
            .will_retry = false,
        } });
        return failure;
    };
    return switch (validation) {
        .accepted => |validated| accepted: {
            try emitLifecycle(hooks, .{ .output_validation_end = .{
                .output = validated,
                .retry_number = retry_number,
            } });
            break :accepted .{ .selected = .{
                .name = selected.name,
                .output = validated,
                .structured_format = selected.structured_format,
            } };
        },
        .retry => |retry| retry_result: {
            try emitLifecycle(hooks, .{ .output_validation_error = .{
                .output = selected.output,
                .failure = retry.failure orelse error.OutputValidationRetry,
                .retry_number = retry_number,
                .will_retry = retry_number < max_retries,
            } });
            break :retry_result .{ .retry = .{
                .message = retry.message,
                .failure = retry.failure,
            } };
        },
    };
}

fn invokeOutputFunction(
    function: output_types.Function,
    allocator: std.mem.Allocator,
    run_context: output_types.RunContext,
    arguments: []const u8,
) !output_types.FunctionResult {
    return function.call(allocator, run_context, arguments);
}

fn outputToolResult(
    call: model_types.ToolCall,
    content: []const u8,
    outcome: model_types.ToolOutcome,
) RequestPart {
    return .{ .tool_return = .{
        .call_id = call.id,
        .name = call.name,
        .content = content,
        .tool_kind = call.tool_kind,
        .outcome = outcome,
    } };
}

fn consumeOutputRetry(maximum: usize, used: *usize, failure: ?anyerror) !void {
    if (used.* >= maximum) {
        if (failure) |cause| return cause;
        return Agent.Error.OutputRetriesExceeded;
    }
    used.* += 1;
}

fn ensureNoOutputToolConflicts(
    tools: []const model_types.Tool,
    choices: []const output_types.PreparedChoice,
) Agent.Error!void {
    for (tools) |tool| for (choices) |choice| {
        if (std.mem.eql(u8, tool.definition.name, choice.choice.name)) return Agent.Error.DuplicateToolName;
    };
}

fn structuredOutputSnapshot(
    allocator: std.mem.Allocator,
    output_format: model_types.OutputFormat,
    output: []const u8,
) !?std.json.Value {
    return switch (output_format) {
        .text => null,
        .json_object, .json_schema => try json_limits.parseLeaky(
            std.json.Value,
            allocator,
            output,
            json_limits.defaults.tool_payload,
            .{},
            Agent.Error.InvalidStructuredOutput,
        ),
    };
}

fn decodeTypedResult(comptime Output: type, untyped: Agent.Result) !TypedResult(Output) {
    var owned = untyped;
    errdefer owned.deinit();
    const output = try json_limits.parseLeaky(
        Output,
        owned.arena.allocator(),
        owned.output,
        json_limits.defaults.tool_payload,
        .{ .ignore_unknown_fields = false },
        Agent.Error.InvalidTypedOutput,
    );
    return .{
        .arena = owned.arena,
        .output = output,
        .output_json = owned.output,
        .output_name = owned.output_name,
        .messages = owned.messages,
        .usage = owned.usage,
        .model_requests = owned.model_requests,
        .finish_reason = owned.finish_reason,
    };
}

const ToolWork = struct {
    call: model_types.ToolCall,
    tool_index: usize,
    arguments_json: []const u8,
    execution: model_types.ToolExecution,
    retry_number: usize = 0,
    durable_sequence: u64 = 0,
    validation_failure: ?anyerror = null,
    retry_message: ?[]const u8 = null,
};

const ToolOutcome = union(enum) {
    success: model_types.ToolOutput,
    retry: []const u8,
    failure: anyerror,
};

const ToolTaskState = enum {
    pending,
    running,
    complete,
};

const ExecutedTool = struct {
    content: []const u8,
    is_error: bool,
    follow_up_messages: []const model_types.RequestMessage = &.{},
};

const ProcessedTool = struct {
    result: model_types.ToolResult,
    follow_up_messages: []const model_types.RequestMessage = &.{},
};

const ToolCallBatch = struct {
    parts: []RequestPart,
    follow_up_messages: []const model_types.RequestMessage = &.{},
};

fn resolveToolCalls(
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    response_parts: []const Part,
    call_count: usize,
    prepared_output: output_types.Prepared,
    tool_retries: *const ToolRetryTracker,
    run_context: model_types.ToolRunContext,
    policies: []const tool_policy.Policy,
    hooks: []const LifecycleHook,
    first_durable_sequence: usize,
) ![]const ToolWork {
    const work = try allocator.alloc(ToolWork, call_count);
    var work_index: usize = 0;
    var call_ordinal: usize = 0;
    for (response_parts) |part| switch (part) {
        .tool_call => |call| {
            defer call_ordinal += 1;
            if (prepared_output.findToolChoice(call.name) != null) continue;
            try emitLifecycle(hooks, .{ .tool_validation_start = .{ .call = call } });
            const tool_index = findToolIndex(tools, call.name) orelse {
                try emitLifecycle(hooks, .{ .tool_validation_error = .{
                    .call = call,
                    .failure = Agent.Error.UnknownTool,
                } });
                return Agent.Error.UnknownTool;
            };
            const tool = tools[tool_index];
            work[work_index] = .{
                .call = call,
                .tool_index = tool_index,
                .arguments_json = call.arguments_json,
                .execution = tool.execution,
                .retry_number = tool_retries.current(call.name),
                .durable_sequence = @intCast(first_durable_sequence + call_ordinal),
            };
            toolRunControl(run_context).invoke(
                void,
                validateToolArgumentJson,
                .{ tool, allocator, call.arguments_json },
            ) catch |failure| {
                work[work_index].validation_failure = failure;
                try emitLifecycle(hooks, .{ .tool_validation_error = .{ .call = call, .failure = failure } });
                work_index += 1;
                continue;
            };
            var arguments = tool_policy.Arguments{
                .context = policyCallContext(run_context, call, tool, work[work_index].retry_number, false),
                .arguments_json = call.arguments_json,
            };
            applyToolPolicies(toolRunControl(run_context), policies, allocator, .{ .arguments = &arguments }) catch |failure| {
                try emitLifecycle(hooks, .{ .tool_validation_error = .{ .call = call, .failure = failure } });
                return failure;
            };
            work[work_index].arguments_json = arguments.arguments_json;
            if (arguments.retry_message) |message| {
                work[work_index].retry_message = message;
                try emitLifecycle(hooks, .{ .tool_validation_error = .{
                    .call = call,
                    .failure = error.ToolArgumentsRejected,
                } });
                work_index += 1;
                continue;
            }
            toolRunControl(run_context).invoke(
                void,
                validateToolArguments,
                .{ tool, allocator, arguments.arguments_json },
            ) catch |failure| {
                work[work_index].validation_failure = failure;
                try emitLifecycle(hooks, .{ .tool_validation_error = .{ .call = call, .failure = failure } });
                work_index += 1;
                continue;
            };
            try emitLifecycle(hooks, .{ .tool_validation_end = .{ .call = call, .tool = tool } });
            var approval = tool_policy.Approval{
                .context = arguments.context,
                .arguments_json = arguments.arguments_json,
                .execution = tool.execution,
            };
            try applyToolPolicies(toolRunControl(run_context), policies, allocator, .{ .approval = &approval });
            work[work_index].execution = approval.execution;
            work_index += 1;
        },
        else => {},
    };
    std.debug.assert(work_index == call_count);
    return work;
}

fn findToolWork(work: []const ToolWork, call_id: []const u8) ?ToolWork {
    for (work) |item| if (std.mem.eql(u8, item.call.id, call_id)) return item;
    return null;
}

fn policyCallContext(
    run_context: model_types.ToolRunContext,
    call: model_types.ToolCall,
    tool: model_types.Tool,
    retry_number: usize,
    approved: bool,
) tool_policy.CallContext {
    return .{
        .run = .{
            .messages = run_context.messages,
            .usage = run_context.usage,
            .model_requests = run_context.model_requests,
            .dependencies = run_context.dependencies,
            .capabilities = run_context.capabilities,
            .control = toolRunControl(run_context),
        },
        .call = call,
        .tool = tool,
        .retry_number = retry_number,
        .approved = approved,
    };
}

fn executeToolCalls(
    agent: Agent,
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    work: []const ToolWork,
    tool_retries: *ToolRetryTracker,
    run_context: model_types.ToolRunContext,
    policies: []const tool_policy.Policy,
    hooks: []const LifecycleHook,
    durable: ?durable_types.Binding,
) !ToolCallBatch {
    const call_count = work.len;
    const result_parts = try allocator.alloc(RequestPart, call_count);
    if (call_count == 1) {
        try toolRunControl(run_context).check();
        const limits = effectiveToolLimits(agent.tool_limits, tools[work[0].tool_index].limits);
        const outcome: ToolOutcome = if (work[0].retry_message) |message|
            .{ .retry = message }
        else if (work[0].validation_failure) |failure|
            .{ .failure = failure }
        else execute: {
            try emitLifecycle(hooks, .{ .tool_execution_start = .{
                .call = work[0].call,
                .tool = tools[work[0].tool_index],
            } });
            const executed = executeToolWorkControlled(
                agent.io,
                durable,
                tools[work[0].tool_index],
                limits,
                allocator,
                run_context,
                work[0],
                policies,
            );
            try emitToolOutcome(hooks, tools[work[0].tool_index], work[0].call, executed);
            break :execute executed;
        };
        const processed = try toolResult(
            agent,
            tools,
            allocator,
            work[0],
            tool_retries,
            outcome,
        );
        result_parts[0] = .{ .tool_return = processed.result };
        return .{ .parts = result_parts, .follow_up_messages = processed.follow_up_messages };
    }

    const io = agent.io orelse return Agent.Error.ParallelToolCallsRequireIo;
    var locked_allocator = LockedAllocator{ .child = allocator, .io = io };
    const concurrent_allocator = locked_allocator.allocator();
    const futures = try allocator.alloc(?std.Io.Future(ToolOutcome), call_count);
    @memset(futures, null);
    const outcomes = try allocator.alloc(ToolOutcome, call_count);
    const states = try allocator.alloc(ToolTaskState, call_count);
    const admitted_per_tool = try allocator.alloc(usize, tools.len);
    @memset(admitted_per_tool, 0);
    var admitted: usize = 0;
    var completed: usize = 0; // kcov-ignore
    const global_capacity = agent.tool_limits.max_concurrency +| agent.tool_limits.max_queue_size;
    for (work, states, outcomes) |item, *state, *outcome| {
        if (item.retry_message) |message| {
            outcome.* = .{ .retry = message };
            state.* = .complete;
            completed += 1;
            continue;
        } else if (item.validation_failure) |failure| {
            outcome.* = .{ .failure = failure };
            state.* = .complete;
            completed += 1;
            continue;
        }
        const limits = effectiveToolLimits(agent.tool_limits, tools[item.tool_index].limits);
        if (admitted >= global_capacity or admitted_per_tool[item.tool_index] >= executionCapacity(limits)) {
            outcome.* = .{ .failure = Agent.Error.ToolQueueOverflow };
            state.* = .complete;
            completed += 1;
            try emitToolOutcome(hooks, tools[item.tool_index], item.call, outcome.*);
            continue;
        }
        admitted += 1;
        admitted_per_tool[item.tool_index] += 1;
        state.* = .pending;
    }

    errdefer {
        for (futures) |*slot| {
            if (slot.*) |*future| _ = future.cancel(io);
        }
    }
    var running: usize = 0;
    while (completed < call_count) {
        try toolRunControl(run_context).check();
        for (work, states, futures) |item, *state, *future| {
            if (state.* != .pending or running >= agent.tool_limits.max_concurrency) continue;
            if (runningSequentialTool(tools, work, states)) continue;
            if (tools[item.tool_index].sequential and running != 0) continue;
            const limits = effectiveToolLimits(agent.tool_limits, tools[item.tool_index].limits);
            if (runningCallsForTool(work, states, item.tool_index) >= limits.max_concurrency) continue;
            try emitLifecycle(hooks, .{ .tool_execution_start = .{
                .call = item.call,
                .tool = tools[item.tool_index],
            } });
            future.* = io.concurrent(executeToolWorkControlled, .{
                @as(?std.Io, io),
                durable,
                tools[item.tool_index],
                limits,
                concurrent_allocator,
                run_context,
                item,
                policies,
            }) catch return Agent.Error.ToolConcurrencyUnavailable;
            state.* = .running;
            running += 1;
        }

        var next: ?usize = null;
        for (states, 0..) |state, index| if (state == .running) {
            next = index;
            break;
        };
        const index = next orelse return Agent.Error.ToolQueueOverflow;
        outcomes[index] = futures[index].?.await(io);
        states[index] = .complete;
        running -= 1;
        completed += 1;
        try emitToolOutcome(hooks, tools[work[index].tool_index], work[index].call, outcomes[index]);
        if (outcomes[index] == .failure and
            !tools[work[index].tool_index].isRecoverable(outcomes[index].failure)) return outcomes[index].failure;
    }
    try toolRunControl(run_context).check();
    var follow_up_messages: std.ArrayList(model_types.RequestMessage) = .empty;
    for (work, outcomes, result_parts) |item, outcome, *result_part| {
        const processed = try toolResult(
            agent,
            tools,
            allocator,
            item,
            tool_retries,
            outcome,
        );
        result_part.* = .{ .tool_return = processed.result };
        try follow_up_messages.appendSlice(allocator, processed.follow_up_messages);
    }
    return .{
        .parts = result_parts,
        .follow_up_messages = try follow_up_messages.toOwnedSlice(allocator),
    };
}

fn executionCapacity(limits: model_types.ToolLimits) usize {
    if (limits.max_concurrency == 0) return 0;
    return limits.max_concurrency +| limits.max_queue_size;
}

fn effectiveToolLimits(agent_limits: model_types.ToolLimits, tool_limits: ?model_types.ToolLimits) model_types.ToolLimits {
    const tool = tool_limits orelse return agent_limits;
    return .{
        .timeout_ms = earliestTimeout(agent_limits.timeout_ms, tool.timeout_ms),
        .max_concurrency = @min(agent_limits.max_concurrency, tool.max_concurrency),
        .max_queue_size = @min(agent_limits.max_queue_size, tool.max_queue_size),
        .max_result_bytes = @min(agent_limits.max_result_bytes, tool.max_result_bytes),
        .max_follow_up_messages = @min(agent_limits.max_follow_up_messages, tool.max_follow_up_messages),
        .max_follow_up_bytes = @min(agent_limits.max_follow_up_bytes, tool.max_follow_up_bytes),
    };
}

fn earliestTimeout(agent_timeout: ?u64, tool_timeout: ?u64) ?u64 {
    if (agent_timeout) |agent_value| {
        if (tool_timeout) |tool_value| return @min(agent_value, tool_value);
        return agent_value;
    }
    return tool_timeout;
}

fn runningCallsForTool(work: []const ToolWork, states: []const ToolTaskState, tool_index: usize) usize {
    var count: usize = 0;
    for (work, states) |item, state| {
        if (state == .running and item.tool_index == tool_index) count += 1;
    }
    return count;
}

fn runningSequentialTool(
    tools: []const model_types.Tool,
    work: []const ToolWork,
    states: []const ToolTaskState,
) bool {
    for (work, states) |item, state| {
        if (state == .running and tools[item.tool_index].sequential) return true;
    }
    return false;
}

fn emitToolOutcome(
    hooks: []const LifecycleHook,
    tool: model_types.Tool,
    call: model_types.ToolCall,
    outcome: ToolOutcome,
) !void {
    switch (outcome) {
        .success => |output| try emitLifecycle(hooks, .{ .tool_execution_end = .{
            .call = call,
            .content = output.content,
        } }),
        .failure => |failure| try emitLifecycle(hooks, .{ .tool_execution_error = .{
            .call = call,
            .failure = failure,
            .recoverable = tool.isRecoverable(failure),
        } }),
        .retry => try emitLifecycle(hooks, .{ .tool_execution_error = .{
            .call = call,
            .failure = Agent.Error.ToolPolicyRetry,
            .recoverable = true,
        } }),
    }
}

fn executeToolWork(
    durable: ?durable_types.Binding,
    tool: model_types.Tool,
    limits: model_types.ToolLimits,
    allocator: std.mem.Allocator,
    run_context: model_types.ToolRunContext,
    work: ToolWork,
    policies: []const tool_policy.Policy,
) ToolOutcome {
    toolRunControl(run_context).check() catch |failure| return .{ .failure = failure };
    var call = tool_policy.Call{
        .context = policyCallContext(
            run_context,
            work.call,
            tool,
            work.retry_number,
            work.execution == .requires_approval,
        ),
        .arguments_json = work.arguments_json,
    };
    tool_policy.applyAll(policies, allocator, .{ .call = &call }) catch |failure|
        return .{ .failure = failure };
    const output = call.output orelse if (durable) |binding| executeToolDurable(
        binding,
        allocator,
        tool,
        run_context,
        work,
        call.arguments_json,
    ) catch |failure| return .{ .failure = failure } else tool.executeOutputWithContext(
        allocator,
        run_context,
        call.arguments_json,
    ) catch |failure| return .{ .failure = failure };
    var returned = tool_policy.Return{
        .context = call.context,
        .arguments_json = call.arguments_json,
        .output = output,
    };
    tool_policy.applyAll(policies, allocator, .{ .return_value = &returned }) catch |failure|
        return .{ .failure = failure };
    if (returned.retry_message) |message| return .{ .retry = message };
    validateToolOutput(returned.output, limits) catch |failure| return .{ .failure = failure };
    return .{ .success = returned.output };
}

fn executeToolDurable(
    binding: durable_types.Binding,
    allocator: std.mem.Allocator,
    tool: model_types.Tool,
    run_context: model_types.ToolRunContext,
    work: ToolWork,
    arguments_json: []const u8,
) !model_types.ToolOutput {
    var call = work.call;
    call.arguments_json = arguments_json;
    const input_json = try durable_types.payloads.tool.stringifyRequest(
        allocator,
        call,
        arguments_json,
        run_context,
        work.retry_number,
        work.execution == .requires_approval,
    );
    defer allocator.free(input_json);
    const kind: durable_types.OperationKind = switch (tool.origin) {
        .application => .tool_call,
        .mcp => .mcp_request,
    };
    var record = try binding.execute(
        allocator,
        kind,
        if (kind == .mcp_request) "mcp.request" else "tool.call",
        work.durable_sequence,
        input_json,
    );
    defer record.deinit();
    const output_json = try durableSuccessPayload(&record);
    var parsed = try durable_types.payloads.tool.parseResponse(allocator, output_json);
    defer parsed.deinit();
    const follow_ups = try allocator.alloc(model_types.RequestMessage, parsed.value.follow_up_messages.len);
    for (parsed.value.follow_up_messages, follow_ups) |message, *copy| {
        copy.* = try copyRequestMessage(allocator, message);
    }
    return .{
        .content = try allocator.dupe(u8, parsed.value.content),
        .follow_up_messages = follow_ups,
    };
}

fn validateToolArguments(
    tool: model_types.Tool,
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) !void {
    return tool.validate(allocator, arguments_json);
}

fn validateToolArgumentJson(
    tool: model_types.Tool,
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) !void {
    return tool.validateJson(allocator, arguments_json);
}

fn toolRunControl(context: model_types.ToolRunContext) model_types.RunControl {
    return .{
        .io = context.io,
        .cancellation = context.cancellation,
        .deadline = context.deadline,
    };
}

const ToolControlOutcome = union(enum) {
    tool: ToolOutcome,
    timeout: anyerror!void,
    deadline: anyerror!void,
    cancelled: anyerror!void,
};

fn executeToolWorkControlled(
    maybe_io: ?std.Io,
    durable: ?durable_types.Binding,
    tool: model_types.Tool,
    limits: model_types.ToolLimits,
    allocator: std.mem.Allocator,
    run_context: model_types.ToolRunContext,
    work: ToolWork,
    policies: []const tool_policy.Policy,
) ToolOutcome {
    if (limits.max_concurrency == 0) return .{ .failure = Agent.Error.ToolQueueOverflow };
    if (limits.timeout_ms == null and run_context.cancellation == null and run_context.deadline == null)
        return executeToolWork(durable, tool, limits, allocator, run_context, work, policies);
    const io = maybe_io orelse return .{ .failure = Agent.Error.ToolIsolationRequiresIo };
    var buffer: [4]ToolControlOutcome = undefined;
    var select: std.Io.Select(ToolControlOutcome) = .init(io, &buffer);
    defer select.cancelDiscard();
    select.concurrent(.tool, executeToolWork, .{ durable, tool, limits, allocator, run_context, work, policies }) catch
        return .{ .failure = Agent.Error.ToolConcurrencyUnavailable };
    if (limits.timeout_ms) |milliseconds|
        select.concurrent(.timeout, waitForToolTimeout, .{ io, milliseconds }) catch
            return .{ .failure = Agent.Error.ToolConcurrencyUnavailable };
    if (run_context.deadline) |deadline|
        select.concurrent(.deadline, waitForToolDeadline, .{ io, deadline }) catch
            return .{ .failure = Agent.Error.ToolConcurrencyUnavailable };
    if (run_context.cancellation) |token|
        select.concurrent(.cancelled, waitForToolCancellation, .{ io, token }) catch
            return .{ .failure = Agent.Error.ToolConcurrencyUnavailable };
    const outcome = select.await() catch return .{ .failure = Agent.Error.Cancelled };
    return switch (outcome) {
        .tool => |result| tool_result: {
            toolRunControl(run_context).check() catch |failure|
                break :tool_result .{ .failure = failure };
            break :tool_result result;
        },
        .timeout => |result| timeout: {
            result catch return .{ .failure = Agent.Error.Cancelled };
            break :timeout .{ .failure = Agent.Error.ToolTimedOut };
        },
        .deadline => |result| deadline: {
            result catch return .{ .failure = Agent.Error.Cancelled };
            break :deadline .{ .failure = Agent.Error.RunTimedOut };
        },
        .cancelled => |result| cancelled: {
            result catch return .{ .failure = Agent.Error.Cancelled };
            break :cancelled .{ .failure = Agent.Error.Cancelled };
        },
    };
}

fn waitForToolTimeout(io: std.Io, milliseconds: u64) !void {
    const maximum: u64 = @intCast(std.math.maxInt(i64));
    return toolTimeout(@min(milliseconds, maximum)).sleep(io); // kcov-ignore
}

fn waitForToolDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
    return deadline.wait(io);
}

fn waitForToolCancellation(io: std.Io, token: *const CancellationToken) !void {
    while (!token.isCancelled()) try toolTimeout(5).sleep(io);
}

fn toolTimeout(milliseconds: u64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    } };
}

fn validateToolOutput(output: model_types.ToolOutput, limits: model_types.ToolLimits) Agent.Error!void {
    if (output.content.len > limits.max_result_bytes) return Agent.Error.ToolResultTooLarge;
    if (output.follow_up_messages.len > limits.max_follow_up_messages) return Agent.Error.ToolFollowUpOverflow;
    var total: usize = 0;
    for (output.follow_up_messages) |message| {
        for (message.instruction_parts) |instruction| {
            if (!consumeBoundedBytes(&total, limits.max_follow_up_bytes, instruction.content.len))
                return Agent.Error.ToolFollowUpOverflow;
        }
        if (!consumeFollowUpBytes(&total, limits.max_follow_up_bytes, message.instructions))
            return Agent.Error.ToolFollowUpOverflow;
        if (!consumeFollowUpBytes(&total, limits.max_follow_up_bytes, message.run_id))
            return Agent.Error.ToolFollowUpOverflow;
        if (!consumeFollowUpBytes(&total, limits.max_follow_up_bytes, message.conversation_id))
            return Agent.Error.ToolFollowUpOverflow;
        for (message.metadata) |metadata| {
            if (!consumeBoundedBytes(&total, limits.max_follow_up_bytes, metadata.key.len) or
                !consumeBoundedBytes(&total, limits.max_follow_up_bytes, metadata.value.len))
                return Agent.Error.ToolFollowUpOverflow;
        }
        for (message.parts) |part| if (!consumeRequestPartBytes(&total, limits.max_follow_up_bytes, part))
            return Agent.Error.ToolFollowUpOverflow;
    }
}

fn consumeFollowUpBytes(total: *usize, limit: usize, value: ?[]const u8) bool {
    return consumeBoundedBytes(total, limit, if (value) |bytes| bytes.len else 0);
}

fn consumeRequestPartBytes(total: *usize, limit: usize, part: RequestPart) bool {
    return switch (part) {
        .system_prompt, .retry_prompt => |text| consumeBoundedBytes(total, limit, text.len),
        .system_prompt_part => |prompt| consumeBoundedBytes(total, limit, prompt.content.len) and
            consumeFollowUpBytes(total, limit, prompt.dynamic_ref),
        .user_prompt => |prompt| consumeUserContentBytes(total, limit, prompt),
        .user_prompt_part => |prompt| consumeUserContentBytes(total, limit, prompt.content),
        .speech => |speech| consumeSpeechBytes(total, limit, speech),
        .tool_search_return => |result| consumeToolSearchResultBytes(total, limit, result),
        .capability_load_return => |result| consumeBoundedBytes(total, limit, result.call_id.len) and
            consumeFollowUpBytes(total, limit, result.instructions) and
            consumeMetadataBytes(total, limit, result.metadata),
        .tool_return => |result| consumeToolResultBytes(total, limit, result),
        .retry_prompt_part => |prompt| consumeBoundedBytes(total, limit, prompt.content.len) and
            consumeFollowUpBytes(total, limit, prompt.tool_name) and
            consumeFollowUpBytes(total, limit, prompt.tool_call_id),
        .tool_availability_delta => |delta| blk: {
            for (delta.tools_added) |name| if (!consumeBoundedBytes(total, limit, name.len)) break :blk false;
            break :blk consumeFollowUpBytes(total, limit, delta.tool_call_id);
        },
    };
}

fn consumeUserContentBytes(total: *usize, limit: usize, prompt: PromptPart) bool {
    return switch (prompt) {
        .text => |text| consumeBoundedBytes(total, limit, text.len),
        .text_content => |text| consumeBoundedBytes(total, limit, text.content.len) and
            consumeMetadataBytes(total, limit, text.metadata),
        .image, .audio, .video, .document, .binary => |content| consumeContentBytes(total, limit, content),
        .uploaded_file => |file| consumeUploadedFileBytes(total, limit, file),
        .cache_point => true,
    };
}

fn consumeToolResultBytes(total: *usize, limit: usize, result: model_types.ToolResult) bool {
    if (!consumeBoundedBytes(total, limit, result.call_id.len) or
        !consumeBoundedBytes(total, limit, result.name.len) or
        !consumeBoundedBytes(total, limit, result.content.len) or
        !consumeMetadataBytes(total, limit, result.metadata)) return false;
    for (result.files) |content| if (!consumeContentBytes(total, limit, content)) return false;
    return true;
}

fn consumeToolSearchResultBytes(total: *usize, limit: usize, result: model_types.ToolSearchResult) bool {
    if (!consumeBoundedBytes(total, limit, result.call_id.len) or
        !consumeFollowUpBytes(total, limit, result.message) or
        !consumeMetadataBytes(total, limit, result.metadata)) return false;
    for (result.discovered_tools) |tool| if (!consumeBoundedBytes(total, limit, tool.name.len)) return false;
    return true;
}

fn consumeSpeechBytes(total: *usize, limit: usize, speech: model_types.SpeechPart) bool {
    return consumeFollowUpBytes(total, limit, speech.transcript) and
        (if (speech.audio) |audio| consumeContentBytes(total, limit, audio) else true);
}

fn consumeUploadedFileBytes(total: *usize, limit: usize, file: model_types.UploadedFile) bool {
    return consumeBoundedBytes(total, limit, file.id.len) and
        consumeBoundedBytes(total, limit, file.provider_name.len) and
        consumeFollowUpBytes(total, limit, file.media_type) and
        consumeMetadataBytes(total, limit, file.metadata);
}

fn consumeMetadataBytes(total: *usize, limit: usize, metadata: []const model_types.Metadata) bool {
    for (metadata) |item| if (!consumeBoundedBytes(total, limit, item.key.len) or
        !consumeBoundedBytes(total, limit, item.value.len)) return false;
    return true;
}

fn consumeContentBytes(total: *usize, limit: usize, content: model_types.Content) bool {
    const source_ok = switch (content.source) {
        .bytes, .url => |value| consumeBoundedBytes(total, limit, value.len),
        .provider_file => |file| consumeBoundedBytes(total, limit, file.id.len) and
            consumeFollowUpBytes(total, limit, file.provider),
        .uploaded_file => |file| consumeUploadedFileBytes(total, limit, file),
    };
    if (!source_ok or
        !consumeBoundedBytes(total, limit, content.media_type.len) or
        !consumeFollowUpBytes(total, limit, content.filename) or
        !consumeFollowUpBytes(total, limit, content.identifier) or
        !consumeFollowUpBytes(total, limit, content.thought_signature)) return false;
    if (!consumeFollowUpBytes(total, limit, content.provider.id) or
        !consumeFollowUpBytes(total, limit, content.provider.provider_name) or
        !consumeProviderDetailsBytes(total, limit, content.provider.provider_details)) return false;
    for (content.metadata) |metadata| {
        if (!consumeBoundedBytes(total, limit, metadata.key.len) or
            !consumeBoundedBytes(total, limit, metadata.value.len)) return false;
    }
    return true;
}

fn consumeProviderDetailsBytes(
    total: *usize,
    limit: usize,
    details: ?model_types.ProviderDetails,
) bool {
    return consumeJsonValueBytes(total, limit, if (details) |value| value.value else return true);
}

fn consumeJsonValueBytes(total: *usize, limit: usize, value: std.json.Value) bool {
    return switch (value) {
        .null => consumeBoundedBytes(total, limit, 4),
        .bool => |item| consumeBoundedBytes(total, limit, if (item) 4 else 5),
        .integer => consumeBoundedBytes(total, limit, 20),
        .float => consumeBoundedBytes(total, limit, 32),
        .number_string => |item| consumeBoundedBytes(total, limit, item.len),
        .string => |item| consumeJsonStringBytes(total, limit, item),
        .array => |items| blk: {
            if (!consumeBoundedBytes(total, limit, 2)) break :blk false;
            for (items.items, 0..) |item, index| {
                if ((index > 0 and !consumeBoundedBytes(total, limit, 1)) or
                    !consumeJsonValueBytes(total, limit, item)) break :blk false;
            }
            break :blk true;
        },
        .object => |items| blk: {
            if (!consumeBoundedBytes(total, limit, 2)) break :blk false;
            var iterator = items.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| {
                if ((index > 0 and !consumeBoundedBytes(total, limit, 1)) or
                    !consumeJsonStringBytes(total, limit, entry.key_ptr.*) or
                    !consumeBoundedBytes(total, limit, 1) or
                    !consumeJsonValueBytes(total, limit, entry.value_ptr.*)) break :blk false;
                index += 1;
            }
            break :blk true;
        },
    };
}

fn consumeJsonStringBytes(total: *usize, limit: usize, value: []const u8) bool {
    if (!consumeBoundedBytes(total, limit, 2)) return false;
    for (value) |byte| {
        const encoded_len: usize = if (byte == '"' or byte == '\\') 2 else if (byte < 0x20) 6 else 1;
        if (!consumeBoundedBytes(total, limit, encoded_len)) return false;
    }
    return true;
}

fn consumeBoundedBytes(total: *usize, limit: usize, amount: usize) bool {
    if (amount > limit -| total.*) return false;
    total.* += amount;
    return true;
}

fn toolResult(
    agent: Agent,
    tools: []const model_types.Tool,
    allocator: std.mem.Allocator,
    work: ToolWork,
    tool_retries: *ToolRetryTracker,
    outcome: ToolOutcome,
) !ProcessedTool {
    const tool = tools[work.tool_index];
    const executed: ExecutedTool = switch (outcome) {
        .success => |output| .{
            .content = output.content,
            .is_error = false,
            .follow_up_messages = output.follow_up_messages,
        },
        .retry => |message| retry: {
            const retry_limit = tool.max_retries orelse agent.max_tool_retries;
            if (!try tool_retries.consume(work.call.name, retry_limit)) return Agent.Error.ToolPolicyRetry;
            break :retry .{ .content = message, .is_error = true };
        },
        .failure => |failure| recover: {
            if (!tool.isRecoverable(failure)) return failure;
            const retry_limit = tool.max_retries orelse agent.max_tool_retries;
            const retry_allowed = try tool_retries.consume(work.call.name, retry_limit);
            if (!retry_allowed) return failure;
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
        .result = .{
            .call_id = work.call.id,
            .name = work.call.name,
            .content = executed.content,
            .tool_kind = work.call.tool_kind orelse if (std.mem.eql(u8, work.call.name, load_capability_tool_name))
                .capability_load
            else
                null,
            .is_error = executed.is_error,
        },
        .follow_up_messages = executed.follow_up_messages,
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

const PartialToolAccumulator = struct {
    index: usize,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *PartialToolAccumulator, allocator: std.mem.Allocator) void {
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

const ModelEventForwarder = struct {
    allocator: std.mem.Allocator,
    sink: ?AgentStreamSink,
    emitted: *bool,
    hooks: []const LifecycleHook,
    prepared_output: output_types.Prepared,
    validators: []const output_types.Validator,
    run_context: output_types.RunContext,
    max_tool_parts: usize,
    text: std.ArrayList(u8) = .empty,
    tool_parts: std.ArrayList(PartialToolAccumulator) = .empty,

    fn deinit(self: *ModelEventForwarder) void {
        self.text.deinit(self.allocator);
        for (self.tool_parts.items) |*part| part.deinit(self.allocator);
        self.tool_parts.deinit(self.allocator);
    }

    fn modelSink(self: *ModelEventForwarder) model_types.ModelStreamSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
        const self: *ModelEventForwarder = @ptrCast(@alignCast(context));
        self.emitted.* = true;
        try emitStreamEvent(self.hooks, self.sink.?, .{ .model = event });
        switch (event) {
            .part_start => |started| switch (started.part) {
                .text => |content| try self.appendText(content),
                .text_part => |part| try self.appendText(part.content),
                .tool_call => |call| try self.appendTool(started.index, call.name, call.arguments_json),
                else => {},
            },
            .part_delta => |changed| switch (changed.delta) {
                .text => |delta| try self.appendText(delta.content_delta),
                .tool_call => |delta| try self.appendTool(
                    changed.index,
                    delta.name,
                    delta.arguments_delta,
                ),
                else => {},
            },
            .part_end => |ended| switch (ended.part) {
                .text => |content| if (self.text.items.len == 0) try self.appendText(content),
                .text_part => |part| if (self.text.items.len == 0) try self.appendText(part.content),
                .tool_call => |call| {
                    const accumulated = try self.toolPart(ended.index);
                    if (accumulated.name.items.len == 0) try accumulated.name.appendSlice(self.allocator, call.name);
                    if (accumulated.arguments.items.len == 0) {
                        try accumulated.arguments.appendSlice(self.allocator, call.arguments_json);
                        try self.emitToolPartial(accumulated);
                    }
                },
                else => {},
            },
            .usage => {},
        }
    }

    fn appendText(self: *ModelEventForwarder, content: []const u8) !void {
        if (content.len == 0 or self.prepared_output.requires_tool_output) return;
        try self.text.appendSlice(self.allocator, content);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const event = try preparePartialOutput(
            scratch.allocator(),
            self.prepared_output.validation_format,
            self.text.items,
            null,
            self.validators,
            self.run_context,
        ) orelse return;
        try emitStreamEvent(self.hooks, self.sink.?, .{ .partial_output = event });
    }

    fn appendTool(
        self: *ModelEventForwarder,
        index: usize,
        name: ?[]const u8,
        arguments_delta: []const u8,
    ) !void {
        const accumulated = try self.toolPart(index);
        if (name) |value| if (accumulated.name.items.len == 0 or
            !std.mem.eql(u8, accumulated.name.items, value))
        {
            accumulated.name.clearRetainingCapacity();
            try accumulated.name.appendSlice(self.allocator, value);
        };
        if (arguments_delta.len > 0) try accumulated.arguments.appendSlice(self.allocator, arguments_delta);
        if (accumulated.arguments.items.len > 0) try self.emitToolPartial(accumulated);
    }

    fn toolPart(self: *ModelEventForwarder, index: usize) !*PartialToolAccumulator {
        for (self.tool_parts.items) |*part| if (part.index == index) return part;
        if (self.tool_parts.items.len >= self.max_tool_parts) return Agent.Error.MaxToolCallsExceeded;
        try self.tool_parts.append(self.allocator, .{ .index = index });
        return &self.tool_parts.items[self.tool_parts.items.len - 1];
    }

    fn emitToolPartial(self: *ModelEventForwarder, accumulated: *PartialToolAccumulator) !void {
        const choice = self.prepared_output.findToolChoice(accumulated.name.items) orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const memory = scratch.allocator();
        var output = try output_types.decodePartialToolArguments(
            memory,
            choice,
            accumulated.arguments.items,
        ) orelse return;
        var format: model_types.OutputFormat = .{ .json_schema = .{
            .name = choice.choice.name,
            .schema = choice.choice.schema,
            .strict = choice.choice.strict,
        } };
        if (choice.choice.function) |function| {
            const result = try self.run_context.control.invoke(
                output_types.FunctionResult,
                invokeOutputFunction,
                .{ function, memory, self.run_context, output },
            );
            output = switch (result) {
                .output => |value| value,
                .retry => return,
            };
            format = .text;
        }
        const event = try preparePartialOutput(
            memory,
            format,
            output,
            choice.choice.name,
            self.validators,
            self.run_context,
        ) orelse return;
        try emitStreamEvent(self.hooks, self.sink.?, .{ .partial_output = event });
    }
};

fn preparePartialOutput(
    allocator: std.mem.Allocator,
    output_format: model_types.OutputFormat,
    initial_output: []const u8,
    output_name: ?[]const u8,
    validators: []const output_types.Validator,
    run_context: output_types.RunContext,
) !?PartialOutputEvent {
    var output = initial_output;
    var structured_output: ?std.json.Value = null;
    if (output_format != .text) {
        const partial = try json_schema.validatePartial(allocator, output_format, output) orelse return null;
        output = partial.json;
        structured_output = partial.value;
    }
    for (validators) |validator| {
        const result = try run_context.control.invoke(
            output_types.ValidatorResult,
            invokeConfiguredOutputValidator,
            .{ validator, allocator, run_context, output_name, output },
        );
        output = switch (result) {
            .output => |transformed| transformed,
            .retry => return null,
        };
    }
    if (output_format != .text and validators.len > 0) {
        const partial = try json_schema.validatePartial(allocator, output_format, output) orelse return null;
        output = partial.json;
        structured_output = partial.value;
    }
    return .{
        .output = output,
        .output_name = output_name,
        .structured_output = structured_output,
    };
}

fn requestModel(
    model: model_types.Model,
    allocator: std.mem.Allocator,
    request: model_types.ModelRequest,
) !model_types.ModelResponse {
    return model.request(allocator, request);
}

fn streamModel(
    model: model_types.Model,
    allocator: std.mem.Allocator,
    request: model_types.ModelRequest,
    sink: model_types.ModelStreamSink,
) !model_types.ModelResponse {
    return model.stream(allocator, request, sink);
}

fn requestModelDurable(
    binding: durable_types.Binding,
    allocator: std.mem.Allocator,
    request: model_types.ModelRequest,
    sequence: usize,
) !model_types.ModelResponse {
    return executeModelDurable(binding, allocator, request, sequence, .model_request, null);
}

fn streamModelDurable(
    binding: durable_types.Binding,
    allocator: std.mem.Allocator,
    request: model_types.ModelRequest,
    sequence: usize,
    sink: model_types.ModelStreamSink,
) !model_types.ModelResponse {
    return executeModelDurable(binding, allocator, request, sequence, .model_stream, sink);
}

fn executeModelDurable(
    binding: durable_types.Binding,
    allocator: std.mem.Allocator,
    request: model_types.ModelRequest,
    sequence: usize,
    kind: durable_types.OperationKind,
    sink: ?model_types.ModelStreamSink,
) !model_types.ModelResponse {
    const input_json = try durable_types.payloads.model.stringifyRequest(allocator, request);
    defer allocator.free(input_json);
    var record = try binding.execute(
        allocator,
        kind,
        if (kind == .model_stream) "model.stream" else "model.request",
        @intCast(sequence),
        input_json,
    );
    defer record.deinit();
    const output_json = try durableSuccessPayload(&record);
    var parsed = try durable_types.payloads.model.parseResponse(allocator, output_json);
    defer parsed.deinit();
    if (sink) |stream_sink| {
        for (parsed.value.parts, 0..) |part, index| {
            try model_types.emitCompletePart(stream_sink, index, part);
        }
        try stream_sink.emit(.{ .usage = parsed.value.usage });
    }
    return copyResponseMessage(allocator, parsed.value);
}

fn durableSuccessPayload(record: *const durable_types.OwnedRecord) ![]const u8 {
    return durable_types.successPayload(record) catch |failure| switch (failure) {
        error.OperationFailed => Agent.Error.DurableOperationFailed,
        error.OperationSuspended => Agent.Error.DurableOperationSuspended,
    };
}

const ProviderErrorCapture = struct {
    target: ?model_types.ProviderErrorObserver,
    retry_after_seconds: ?u64 = null,
    rate_limit_remaining_requests: ?u64 = null,
    rate_limit_remaining_tokens: ?u64 = null,
    provider_request_id: ?transport.MetadataText = null,

    fn reset(self: *ProviderErrorCapture) void {
        self.retry_after_seconds = null;
        self.rate_limit_remaining_requests = null;
        self.rate_limit_remaining_tokens = null;
        self.provider_request_id = null;
    }

    fn observer(self: *ProviderErrorCapture) model_types.ProviderErrorObserver {
        return .{ .context = self, .observeFn = observe };
    }

    fn observe(context: *anyopaque, value: model_types.ProviderError) void {
        const self: *ProviderErrorCapture = @ptrCast(@alignCast(context));
        self.retry_after_seconds = value.retry_after_seconds;
        self.rate_limit_remaining_requests = value.rate_limit_remaining_requests;
        self.rate_limit_remaining_tokens = value.rate_limit_remaining_tokens;
        self.provider_request_id = if (value.request_id) |request_id| transport.MetadataText.init(request_id) else null;
        if (self.target) |target| target.observe(value);
    }

    fn requestId(self: *const ProviderErrorCapture) ?[]const u8 {
        if (self.provider_request_id) |*value| return value.slice();
        return null;
    }
};

fn prepareContext(
    arena: std.mem.Allocator,
    budget: context_budget.Budget,
    input: context_budget.Input,
    control: model_types.RunControl,
) ![]const Message {
    if (!budget.isConfigured()) return input.messages;
    try control.check();
    const snapshot = try contextSnapshot(budget, input, control);
    const overflow = budget.firstOverflow(input.settings, snapshot) orelse return input.messages;
    const hook = budget.on_overflow orelse return contextOverflowError(overflow.kind);
    const compacted = try control.invoke(
        []const Message,
        invokeContextOverflowHook,
        .{ hook, arena, context_budget.OverflowEvent{
            .input = input,
            .snapshot = snapshot,
            .overflow = overflow,
        } },
    );
    var compacted_input = input;
    compacted_input.messages = compacted;
    const compacted_snapshot = try contextSnapshot(budget, compacted_input, control);
    const remaining = budget.firstOverflow(input.settings, compacted_snapshot) orelse return compacted;
    return contextOverflowError(remaining.kind);
}

fn contextSnapshot(
    budget: context_budget.Budget,
    input: context_budget.Input,
    control: model_types.RunControl,
) !context_budget.Snapshot {
    const bytes = context_budget.measure(input) catch return Agent.Error.ContextSizeOverflow;
    const estimated_input_tokens = if (budget.estimator) |estimator|
        try control.invoke(u64, invokeTokenEstimator, .{ estimator, input, bytes })
    else
        context_budget.defaultEstimate(input, bytes) catch return Agent.Error.ContextSizeOverflow;
    return .{ .bytes = bytes, .estimated_input_tokens = estimated_input_tokens };
}

fn invokeTokenEstimator(
    estimator: context_budget.TokenEstimator,
    input: context_budget.Input,
    bytes: context_budget.ByteUsage,
) !u64 {
    return estimator.estimate(input, bytes);
}

fn invokeContextOverflowHook(
    hook: context_budget.OverflowHook,
    arena: std.mem.Allocator,
    event: context_budget.OverflowEvent,
) ![]const Message {
    return hook.compact(arena, event);
}

fn contextOverflowError(kind: context_budget.Overflow.Kind) Agent.Error {
    return switch (kind) {
        .prompt_bytes => Agent.Error.ContextPromptTooLarge,
        .tool_bytes => Agent.Error.ContextToolsTooLarge,
        .schema_bytes => Agent.Error.ContextSchemaTooLarge,
        .media_bytes => Agent.Error.ContextMediaTooLarge,
        .input_tokens => Agent.Error.ContextTokenLimitExceeded,
    };
}

fn checkCancellation(token: ?*const CancellationToken) Agent.Error!void {
    if (token) |value| if (value.isCancelled()) return Agent.Error.Cancelled; // kcov-ignore
}

fn requireCapability(supported: bool, failure: Agent.Error) Agent.Error!void {
    if (!supported) return failure;
}

fn requireModelSettings(profile: model_types.ModelProfile, settings: model_types.ModelSettings) Agent.Error!void {
    settings.validate() catch return Agent.Error.InvalidModelSettings;
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
    if (settings.top_p != null and !profile.supports_top_p) return Agent.Error.ModelDoesNotSupportTopP;
    if (settings.top_k != null and !profile.supports_top_k) return Agent.Error.ModelDoesNotSupportTopK;
    if (settings.presence_penalty != null and !profile.supports_presence_penalty) {
        return Agent.Error.ModelDoesNotSupportPresencePenalty;
    }
    if (settings.frequency_penalty != null and !profile.supports_frequency_penalty) {
        return Agent.Error.ModelDoesNotSupportFrequencyPenalty;
    }
    if (settings.logprobs != null and !profile.supports_logprobs) return Agent.Error.ModelDoesNotSupportLogprobs;
    if (settings.tool_choice != null and !profile.supports_tool_choice) {
        return Agent.Error.ModelDoesNotSupportToolChoice;
    }
    if (settings.parallel_tool_calls != null and !profile.supports_parallel_tool_call_setting) {
        return Agent.Error.ModelDoesNotSupportParallelToolCallSetting;
    }
    if (settings.parallel_tool_calls == true and !profile.supports_parallel_tool_calls) {
        return Agent.Error.ModelDoesNotSupportParallelToolCallSetting;
    }
    if (settings.thinking_budget_tokens != null and !profile.supports_thinking_budget) {
        return Agent.Error.ModelDoesNotSupportThinkingBudget;
    }
    if (settings.service_tier) |tier|
        if (!profile.supportsServiceTier(tier)) return Agent.Error.ModelDoesNotSupportServiceTier;
    if (settings.truncation != null and !profile.supports_truncation) {
        return Agent.Error.ModelDoesNotSupportTruncation;
    }
    if (settings.extra_headers != null and !profile.supports_request_headers) {
        return Agent.Error.ModelDoesNotSupportRequestHeaders;
    }
    if (settings.extra_body) |body| {
        if (profile.extra_body_kind == null or profile.extra_body_kind.? != body.kind()) {
            return Agent.Error.ModelDoesNotSupportExtraBody;
        }
    }
}

fn shouldRetry(err: anyerror, policy: Agent.RetryPolicy) bool {
    return switch (err) {
        error.ProviderConnectionError => policy.retry_connection_errors,
        error.ProviderResponseDecodeError => policy.retry_decode_errors,
        error.ProviderRateLimited => policy.retry_rate_limits,
        error.ProviderServerError => policy.retry_server_errors,
        error.RequestTimedOut => policy.retry_timeouts,
        else => false,
    };
}

fn backoffDelayMilliseconds(io: std.Io, backoff: Agent.Backoff, retry_number: usize, retry_after_seconds: ?u64) u64 {
    if (backoff.respect_retry_after) if (retry_after_seconds) |seconds| {
        return @min(std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64), backoff.maximum_delay_ms);
    };
    var delay = @min(backoff.initial_delay_ms, backoff.maximum_delay_ms);
    var exponent = retry_number -| 1;
    while (exponent > 0 and delay < backoff.maximum_delay_ms) : (exponent -= 1) {
        delay = @min(std.math.mul(u64, delay, 2) catch std.math.maxInt(u64), backoff.maximum_delay_ms);
    }
    var random_source = std.Random.IoSource{ .io = io };
    return random_source.interface().uintAtMost(u64, delay);
}

fn generateIdempotencyKey(io: std.Io, output: *[32]u8) []const u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    output.* = std.fmt.bytesToHex(random, .lower);
    return output;
}

fn sleepBackoff(io: std.Io, delay_ms: u64, control: model_types.RunControl) !void {
    return control.invoke(void, sleepBackoffDuration, .{ io, delay_ms });
}

fn sleepBackoffDuration(io: std.Io, delay_ms: u64) !void {
    const maximum: u64 = @intCast(std.math.maxInt(i64));
    toolTimeout(@min(delay_ms, maximum)).sleep(io) catch |err| return normalizeBackoffSleepError(err); // kcov-ignore
}

fn normalizeBackoffSleepError(err: error{Canceled}) Agent.Error {
    return switch (err) {
        error.Canceled => Agent.Error.Cancelled,
    };
}

fn monotonicNow(io: ?std.Io) ?std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io orelse return null, .awake);
}

fn elapsedMilliseconds(io: ?std.Io, started: ?std.Io.Clock.Timestamp) ?u64 {
    const start = started orelse return null;
    const end = std.Io.Clock.Timestamp.now(io orelse return null, start.clock);
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return @intCast(@min(@divFloor(nanoseconds, std.time.ns_per_ms), std.math.maxInt(u64)));
}

fn addRunDuration(
    usage: *usage_types.RunUsage,
    io: ?std.Io,
    started: ?std.Io.Clock.Timestamp,
) error{UsageOverflow}!void {
    const duration = elapsedMilliseconds(io, started) orelse return;
    usage.run_duration_ms = std.math.add(u64, usage.run_duration_ms, duration) catch return error.UsageOverflow;
}

fn enforceUsageLimits(usage: usage_types.RunUsage, limits: Agent.UsageLimits) Agent.Error!void {
    if (limits.max_input_tokens) |maximum| {
        if (usage.input_tokens > maximum) return Agent.Error.InputTokenLimitExceeded;
    }
    if (limits.max_output_tokens) |maximum| {
        if (usage.output_tokens > maximum) return Agent.Error.OutputTokenLimitExceeded;
    }
    if (limits.max_total_tokens) |maximum| {
        if (usage.totalTokens() > maximum) return Agent.Error.TotalTokenLimitExceeded;
    }
    if (limits.max_cost_nano_usd) |maximum| if (usage.cost) |cost| {
        if (cost.nano_usd > maximum) return Agent.Error.CostLimitExceeded;
    };
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

fn appendSystemMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), text: []const u8) !void {
    const parts = try allocator.alloc(RequestPart, 1);
    parts[0] = .{ .system_prompt = try allocator.dupe(u8, text) };
    try messages.append(allocator, .{ .request = .{ .parts = parts } });
}

fn appendRetryMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), text: []const u8) !void {
    const parts = try allocator.alloc(RequestPart, 1);
    parts[0] = .{ .retry_prompt = try allocator.dupe(u8, text) };
    try messages.append(allocator, .{ .request = .{ .parts = parts } });
}

fn appendPromptMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    prompt: []const u8,
    rich_parts: []const PromptPart,
    instructions: []const []const u8,
) !void {
    const extra: usize = if (prompt.len > 0) 1 else 0;
    const parts = try allocator.alloc(RequestPart, rich_parts.len + extra);
    for (rich_parts, parts[0..rich_parts.len]) |part, *copy| {
        copy.* = .{ .user_prompt = try copyPromptPart(allocator, part) };
    }
    if (prompt.len > 0) {
        parts[rich_parts.len] = .{ .user_prompt = .{ .text = try allocator.dupe(u8, prompt) } };
    }
    try messages.append(allocator, .{ .request = .{
        .parts = parts,
        .instructions = if (instructions.len > 0) try std.mem.join(allocator, "\n\n", instructions) else null,
    } });
}

fn appendMessageCopy(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), message: Message) !void {
    try messages.append(allocator, switch (message) {
        .request => |request| .{ .request = try copyRequestMessage(allocator, request) },
        .response => |response| .{ .response = try copyResponseMessage(allocator, response) },
    });
}

fn appendPendingMessageCopies(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    source: []const Message,
) ![]const Message {
    const start = messages.items.len;
    for (source) |message| switch (message) {
        .request => {
            try ensureContentSupported(selected_model, url_policy, &.{message});
            try appendMessageCopy(allocator, messages, message);
        },
        .response => return Agent.Error.InvalidContentRole,
    };
    return messages.items[start..];
}

fn appendDrainedPendingMessages(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    drained: *const PendingMessageQueue.Drained,
) ![]const Message {
    const start = messages.items.len;
    for (drained.batches.items) |batch| for (batch.messages) |request| {
        const message = Message{ .request = request };
        try ensureContentSupported(selected_model, url_policy, &.{message});
        try appendMessageCopy(allocator, messages, message);
    };
    return messages.items[start..];
}

fn appendQueuedMessages(
    queue: ?*PendingMessageQueue,
    close_when_empty: bool,
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    stream_sink: ?AgentStreamSink,
    hooks: []const LifecycleHook,
) !bool {
    const pending = queue orelse return false;
    var drained = (if (close_when_empty) pending.drainOrClose() else pending.drain()) orelse return false;
    defer drained.deinit();
    const added = try appendDrainedPendingMessages(selected_model, url_policy, allocator, messages, &drained);
    if (stream_sink) |sink| try emitStreamEvent(hooks, sink, .{
        .enqueued_messages = .{ .messages = added },
    });
    return true;
}

fn closeAndCopyPendingMessages(
    queue: ?*PendingMessageQueue,
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    allocator: std.mem.Allocator,
) ![]const Message {
    const pending = queue orelse return &.{};
    var drained = pending.closeAndDrain() orelse return &.{};
    defer drained.deinit();
    var messages: std.ArrayList(Message) = .empty;
    return appendDrainedPendingMessages(selected_model, url_policy, allocator, &messages, &drained);
}

fn appendToolFollowUps(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    follow_ups: []const model_types.RequestMessage,
) !void {
    for (follow_ups) |request| {
        for (request.parts) |part| switch (part) {
            .user_prompt => |content| try ensurePromptPartSupported(selected_model, url_policy, content),
            else => return Agent.Error.InvalidToolFollowUpMessage,
        };
        try messages.append(allocator, .{ .request = try copyRequestMessage(allocator, request) });
    }
}

fn copyPromptPart(allocator: std.mem.Allocator, part: PromptPart) !PromptPart {
    return model_types.dupeUserContent(allocator, part);
}

fn copyResponsePart(allocator: std.mem.Allocator, part: ResponsePart) !ResponsePart {
    var copied = try model_types.dupeResponsePart(allocator, part);
    switch (copied) {
        .tool_call => |*call| if (call.tool_kind == null and
            std.mem.eql(u8, call.name, load_capability_tool_name))
        {
            call.tool_kind = .capability_load;
        },
        else => {},
    }
    return copied;
}

fn copyPart(allocator: std.mem.Allocator, part: ResponsePart) !ResponsePart {
    return copyResponsePart(allocator, part);
}

fn copyRequestPart(allocator: std.mem.Allocator, part: RequestPart) !RequestPart {
    return model_types.dupeRequestPart(allocator, part);
}

fn copyRequestMessage(allocator: std.mem.Allocator, request: model_types.RequestMessage) !model_types.RequestMessage {
    const parts = try allocator.alloc(RequestPart, request.parts.len);
    for (request.parts, parts) |part, *copy| copy.* = try copyRequestPart(allocator, part);
    return .{
        .parts = parts,
        .timestamp_unix_ms = request.timestamp_unix_ms,
        .instruction_parts = blk: {
            const result = try allocator.alloc(model_types.InstructionPart, request.instruction_parts.len);
            for (request.instruction_parts, result) |part, *copy| copy.* = .{
                .content = try allocator.dupe(u8, part.content),
                .dynamic = part.dynamic,
            };
            break :blk result;
        },
        .instructions = try copyOptionalString(allocator, request.instructions),
        .run_id = try copyOptionalString(allocator, request.run_id),
        .conversation_id = try copyOptionalString(allocator, request.conversation_id),
        .metadata = try copyMetadata(allocator, request.metadata),
        .state = request.state,
    };
}

fn copyResponseMessage(allocator: std.mem.Allocator, response: model_types.ResponseMessage) !model_types.ResponseMessage {
    const parts = try allocator.alloc(ResponsePart, response.parts.len);
    for (response.parts, parts) |part, *copy| copy.* = try copyResponsePart(allocator, part);
    return .{
        .parts = parts,
        .usage = response.usage,
        .timestamp_unix_ms = response.timestamp_unix_ms,
        .provider_name = try copyOptionalString(allocator, response.provider_name),
        .provider_url = try copyOptionalString(allocator, response.provider_url),
        .provider_details = if (response.provider_details) |details|
            try model_types.dupeProviderDetails(allocator, details)
        else
            null,
        .provider_response_id = try copyOptionalString(allocator, response.provider_response_id),
        .model_name = try copyOptionalString(allocator, response.model_name),
        .finish_reason = if (response.finish_reason) |reason| .{
            .kind = reason.kind,
            .raw = try allocator.dupe(u8, reason.raw),
        } else null,
        .run_id = try copyOptionalString(allocator, response.run_id),
        .conversation_id = try copyOptionalString(allocator, response.conversation_id),
        .metadata = try copyMetadata(allocator, response.metadata),
        .state = response.state,
    };
}

fn copyOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |string| try allocator.dupe(u8, string) else null;
}

fn copyContent(allocator: std.mem.Allocator, value: model_types.Content) !model_types.Content {
    return model_types.dupeContent(allocator, value);
}

fn copyMetadata(allocator: std.mem.Allocator, source: []const model_types.Metadata) ![]const model_types.Metadata {
    return model_types.dupeMetadata(allocator, source);
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
            const value = try context.control.invoke(
                []const u8,
                resolveDynamicInstruction,
                .{ dynamic, allocator, context },
            );
            if (value.len > 0) try resolved.append(allocator, try allocator.dupe(u8, value));
        },
    };
    for (runtime) |value| if (value.len > 0) {
        try resolved.append(allocator, try allocator.dupe(u8, value));
    };
    return resolved.toOwnedSlice(allocator);
}

fn resolveDynamicInstruction(
    instruction: Instruction.Dynamic,
    allocator: std.mem.Allocator,
    context: InstructionContext,
) ![]const u8 {
    return instruction.resolve(allocator, context);
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

fn onlineEvalHook(run: *online_eval_types.Run) LifecycleHook {
    const Adapter = struct {
        fn emit(context: *anyopaque, event: LifecycleEvent) !void {
            const online_run: *online_eval_types.Run = @ptrCast(@alignCast(context));
            switch (event) {
                .run_start => |start| online_run.begin(start.prompt) catch {},
                .run_end => |end| online_run.succeed(
                    end.output,
                    end.usage,
                    end.model_requests,
                ) catch {},
                .run_error => |run_error| online_run.fail(run_error.failure) catch {},
                else => {},
            }
        }
    };
    return .{ .context = run, .eventFn = Adapter.emit };
}

fn diagnosticHook(run: *diagnostic_types.Run) LifecycleHook {
    const Adapter = struct {
        fn emit(context: *anyopaque, event: LifecycleEvent) !void {
            const diagnostic_run: *diagnostic_types.Run = @ptrCast(@alignCast(context));
            return diagnostic_run.observe(event);
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
    policies: []const tool_policy.Policy,
    context: ToolsetContext,
) ![]const model_types.Tool {
    var candidates: std.ArrayList(model_types.Tool) = .empty;
    try candidates.appendSlice(allocator, direct_tools);

    for (toolsets) |toolset| {
        const entries = try context.control.invoke(
            []const ToolsetEntry,
            prepareToolset,
            .{ toolset, allocator, context },
        );
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
            try candidates.append(allocator, tool);
        }
    }
    var prepared: std.ArrayList(model_types.Tool) = .empty;
    const run = tool_policy.RunContext{
        .messages = context.messages,
        .usage = context.usage,
        .model_requests = context.model_requests,
        .dependencies = context.dependencies,
        .capabilities = context.capabilities,
        .control = context.control,
    };
    for (candidates.items) |candidate| {
        var event = tool_policy.Prepare{ .run = run, .tool = candidate };
        try applyToolPolicies(context.control, policies, allocator, .{ .prepare = &event });
        if (event.enabled) try prepared.append(allocator, event.tool);
    }
    return prepared.toOwnedSlice(allocator);
}

fn applyToolPolicies(
    control: model_types.RunControl,
    policies: []const tool_policy.Policy,
    allocator: std.mem.Allocator,
    event: tool_policy.Event,
) !void {
    return control.invoke(void, tool_policy.applyAll, .{ policies, allocator, event });
}

fn prepareToolset(
    toolset: Toolset,
    allocator: std.mem.Allocator,
    context: ToolsetContext,
) ![]const ToolsetEntry {
    return toolset.prepare(allocator, context);
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

    fn current(self: *const ToolRetryTracker, name: []const u8) usize {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.count;
        }
        return 0;
    }
};

fn ensureUniqueToolNames(tools: []const model_types.Tool) Agent.Error!void {
    for (tools, 0..) |tool, index| {
        for (tools[index + 1 ..]) |other| {
            if (std.mem.eql(u8, tool.definition.name, other.definition.name)) return Agent.Error.DuplicateToolName;
        }
    }
}

fn ensureBuiltinToolsSupported(
    profile: model_types.ModelProfile,
    tools: []const model_types.BuiltinTool,
) Agent.Error!void {
    for (tools, 0..) |tool, index| {
        const kind = tool.kind();
        for (tools[index + 1 ..]) |other| {
            if (tool.conflictsWith(other)) return Agent.Error.DuplicateBuiltinTool;
        }
        if (profile.supportsBuiltinTool(kind)) continue;
        return switch (kind) {
            .web_search => Agent.Error.ModelDoesNotSupportWebSearch,
            .web_fetch => Agent.Error.ModelDoesNotSupportWebFetch,
            .x_search => Agent.Error.ModelDoesNotSupportXSearch,
            .code_execution => Agent.Error.ModelDoesNotSupportCodeExecution,
            .file_search => Agent.Error.ModelDoesNotSupportFileSearch,
            .remote_mcp => Agent.Error.ModelDoesNotSupportRemoteMcp,
        };
    }
}

fn ensureContentSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    messages: []const Message,
) Agent.Error!void {
    for (messages) |message| switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .user_prompt => |content| try ensurePromptPartSupported(selected_model, url_policy, content),
            .user_prompt_part => |prompt| try ensurePromptPartSupported(selected_model, url_policy, prompt.content),
            .speech => |speech| if (speech.audio) |audio| {
                try ensureProviderPartOwnedBy(selected_model, speech.provider);
                try ensureContentPartSupported(selected_model, url_policy, .audio, audio);
            } else try ensureProviderPartOwnedBy(selected_model, speech.provider),
            .tool_search_return => |result| try ensureProviderPartOwnedBy(selected_model, result.provider),
            .tool_return => |result| for (result.files) |content| {
                try ensureAnyContentSupported(selected_model, url_policy, content);
            },
            else => {},
        },
        .response => |response| try ensureResponsePartsSupported(selected_model, url_policy, response.parts),
    };
}

fn ensurePromptPartsSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    parts: []const PromptPart,
) Agent.Error!void {
    for (parts) |part| try ensurePromptPartSupported(selected_model, url_policy, part);
}

fn ensurePromptPartSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    part: PromptPart,
) Agent.Error!void {
    switch (part) {
        .image => |content| try ensureContentPartSupported(selected_model, url_policy, .image, content),
        .audio => |content| try ensureContentPartSupported(selected_model, url_policy, .audio, content),
        .video => |content| try ensureContentPartSupported(selected_model, url_policy, .video, content),
        .document => |content| try ensureContentPartSupported(selected_model, url_policy, .document, content),
        .binary => |content| try ensureContentPartSupported(selected_model, url_policy, .binary, content),
        .uploaded_file => |file| {
            try ensureUploadedFileOwnedBy(selected_model, file);
            try ensureAnyContentSupported(selected_model, url_policy, file.asContent());
        },
        .text, .text_content, .cache_point => {},
    }
}

fn ensureResponsePartsSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    parts: []const ResponsePart,
) Agent.Error!void {
    for (parts) |part| switch (part) {
        .text_part => |text| try ensureProviderPartOwnedBy(selected_model, text.provider),
        .tool_search_call, .native_tool_search_call => |call| try ensureProviderPartOwnedBy(
            selected_model,
            call.provider,
        ),
        .tool_call => |call| try ensureProviderPartOwnedBy(selected_model, call.provider),
        .native_tool_call => |call| try ensureProviderPartOwnedBy(selected_model, call.provider),
        .native_tool_search_return => |result| try ensureProviderPartOwnedBy(selected_model, result.provider),
        .native_tool_return => |result| {
            try ensureProviderPartOwnedBy(selected_model, result.provider);
            for (result.files) |content| try ensureAnyContentSupported(selected_model, url_policy, content);
        },
        .compaction => |compaction| try ensureProviderPartOwnedBy(selected_model, compaction.provider),
        .image => |content| {
            try ensureContentPartSupported(selected_model, url_policy, .image, content);
        },
        .audio => |content| {
            try ensureContentPartSupported(selected_model, url_policy, .audio, content);
        },
        .video => |content| {
            try ensureContentPartSupported(selected_model, url_policy, .video, content);
        },
        .document => |content| {
            try ensureContentPartSupported(selected_model, url_policy, .document, content);
        },
        .binary => |content| {
            try ensureContentPartSupported(selected_model, url_policy, .binary, content);
        },
        .thinking => |thinking| {
            if (!selected_model.profile.supportsContentType(.thinking)) return Agent.Error.ModelDoesNotSupportThinking;
            try ensureProviderPartOwnedBy(selected_model, thinking.provider);
        },
        .speech => |speech| {
            try ensureProviderPartOwnedBy(selected_model, speech.provider);
            if (speech.audio) |audio| try ensureContentPartSupported(selected_model, url_policy, .audio, audio);
        },
        else => {},
    };
}

fn ensureContentPartSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    kind: model_types.ContentType,
    content: model_types.Content,
) Agent.Error!void {
    if (!selected_model.profile.supportsContentType(kind)) return switch (kind) {
        .image => Agent.Error.ModelDoesNotSupportImages,
        .audio => Agent.Error.ModelDoesNotSupportAudio,
        .video => Agent.Error.ModelDoesNotSupportVideo,
        .document => Agent.Error.ModelDoesNotSupportDocuments,
        .binary => Agent.Error.ModelDoesNotSupportBinaryContent,
        .thinking => Agent.Error.ModelDoesNotSupportThinking,
    };
    try ensureProviderPartOwnedBy(selected_model, content.provider);
    switch (content.source) {
        .url => |url| try url_policy.validate(url),
        .provider_file => |file| if (file.provider) |expected| {
            const actual = selected_model.provider_name orelse return Agent.Error.ProviderFileProviderMismatch;
            if (!std.mem.eql(u8, expected, actual)) return Agent.Error.ProviderFileProviderMismatch;
        },
        .uploaded_file => |file| try ensureUploadedFileOwnedBy(selected_model, file),
        else => {},
    }
}

fn ensureAnyContentSupported(
    selected_model: model_types.Model,
    url_policy: security.UrlPolicy,
    content: model_types.Content,
) Agent.Error!void {
    const kind: model_types.ContentType = if (std.mem.startsWith(u8, content.media_type, "image/"))
        .image
    else if (std.mem.startsWith(u8, content.media_type, "audio/"))
        .audio
    else if (std.mem.startsWith(u8, content.media_type, "video/"))
        .video
    else if (std.mem.startsWith(u8, content.media_type, "text/") or
        std.mem.eql(u8, content.media_type, "application/pdf"))
        .document
    else
        .binary;
    try ensureContentPartSupported(selected_model, url_policy, kind, content);
}

fn ensureUploadedFileOwnedBy(selected_model: model_types.Model, file: model_types.UploadedFile) Agent.Error!void {
    const actual = selected_model.provider_name orelse return Agent.Error.ProviderFileProviderMismatch;
    if (!std.mem.eql(u8, file.provider_name, actual)) return Agent.Error.ProviderFileProviderMismatch;
}

fn ensureProviderPartOwnedBy(selected_model: model_types.Model, provider: model_types.ProviderPart) Agent.Error!void {
    const has_provider_data = provider.id != null or provider.provider_details != null;
    const expected = provider.provider_name orelse if (has_provider_data)
        return Agent.Error.ProviderFileProviderMismatch
    else
        return;
    const actual = selected_model.provider_name orelse return Agent.Error.ProviderFileProviderMismatch;
    if (!std.mem.eql(u8, expected, actual)) return Agent.Error.ProviderFileProviderMismatch;
}

fn findTool(tools: []const model_types.Tool, name: []const u8) ?model_types.Tool {
    const index = findToolIndex(tools, name) orelse return null;
    return tools[index];
}

fn findToolIndex(tools: []const model_types.Tool, name: []const u8) ?usize {
    for (tools, 0..) |tool, index| if (std.mem.eql(u8, tool.definition.name, name)) return index;
    return null;
}

test "tool preparation policies compose after toolsets" {
    const State = struct {
        suffix: []const u8,
        calls: usize = 0,

        fn apply(context: *anyopaque, allocator: std.mem.Allocator, event: tool_policy.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const prepared = switch (event) {
                .prepare => |value| value,
                else => return error.UnexpectedToolPolicyStage,
            };
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 3), prepared.run.model_requests);
            try std.testing.expectEqual(@as(u16, 7), prepared.run.dependency(u16).?.*);
            if (std.mem.eql(u8, prepared.tool.definition.name, "hidden")) {
                prepared.enabled = false;
                return;
            }
            prepared.tool.definition.description = try std.mem.concat(
                allocator,
                u8,
                &.{ prepared.tool.definition.description, self.suffix },
            );
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tool_context: u8 = 0;
    const hidden = model_types.Tool{
        .definition = .{ .name = "hidden", .description = "hidden", .parameters_json_schema = "{}" },
        .context = &tool_context,
    };
    const visible = model_types.Tool{
        .definition = .{ .name = "visible", .description = "visible", .parameters_json_schema = "{}" },
        .context = &tool_context,
    };
    var first = State{ .suffix = " one" };
    var second = State{ .suffix = " two" };
    const policies = [_]tool_policy.Policy{
        .{ .context = &first, .applyFn = State.apply },
        .{ .context = &second, .applyFn = State.apply },
    };
    var dependency: u16 = 7;
    const prepared = try prepareTools(
        allocator,
        &.{hidden},
        &.{.{ .tools = &.{visible} }},
        &policies,
        .{
            .messages = &.{},
            .usage = .{},
            .model_requests = 3,
            .dependencies = &dependency,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), prepared.len);
    try std.testing.expectEqualStrings("visible", prepared[0].definition.name);
    try std.testing.expectEqualStrings("visible one two", prepared[0].definition.description);
    try std.testing.expectEqual(@as(usize, 2), first.calls);
    try std.testing.expectEqual(@as(usize, 2), second.calls);
}

test "tool policy failure and parallel retry branches are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tool_context: u8 = 0;
    const Executor = struct {
        fn execute(_: *anyopaque, memory: std.mem.Allocator, _: []const u8) ![]const u8 {
            return memory.dupe(u8, "raw");
        }
    };
    const tool = model_types.Tool{
        .definition = .{ .name = "demo", .description = "", .parameters_json_schema = "{}" },
        .context = &tool_context,
        .executeFn = Executor.execute,
    };
    var retries = ToolRetryTracker{ .allocator = allocator };
    const malformed_call = Part{ .tool_call = .{
        .id = "malformed",
        .name = "demo",
        .arguments_json = "{",
    } };
    const malformed = try resolveToolCalls(
        &.{tool},
        allocator,
        &.{malformed_call},
        1,
        .{ .model_format = .text, .validation_format = .text },
        &retries,
        .{},
        &.{},
        &.{},
        1,
    );
    try std.testing.expectEqual(error.InvalidToolArguments, malformed[0].validation_failure.?);

    const PolicyFailure = struct {
        stage: enum { arguments, call, return_value },

        fn apply(context: *anyopaque, _: std.mem.Allocator, event: tool_policy.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .arguments => if (self.stage == .arguments) return error.ArgumentPolicyFailed,
                .call => if (self.stage == .call) return error.CallPolicyFailed,
                .return_value => if (self.stage == .return_value) return error.ReturnPolicyFailed,
                else => {},
            }
        }
    };
    var failure = PolicyFailure{ .stage = .arguments };
    const policy = tool_policy.Policy{ .context = &failure, .applyFn = PolicyFailure.apply };
    const valid_call = Part{ .tool_call = .{ .id = "valid", .name = "demo", .arguments_json = "{}" } };
    try std.testing.expectError(error.ArgumentPolicyFailed, resolveToolCalls(
        &.{tool},
        allocator,
        &.{valid_call},
        1,
        .{ .model_format = .text, .validation_format = .text },
        &retries,
        .{},
        &.{policy},
        &.{},
        1,
    ));

    const work = ToolWork{
        .call = valid_call.tool_call,
        .tool_index = 0,
        .arguments_json = "{}",
        .execution = .immediate,
    };
    failure.stage = .call;
    try std.testing.expectEqual(error.CallPolicyFailed, executeToolWork(
        null,
        tool,
        .{},
        allocator,
        .{},
        work,
        &.{policy},
    ).failure);
    failure.stage = .return_value;
    try std.testing.expectEqual(error.ReturnPolicyFailed, executeToolWork(
        null,
        tool,
        .{},
        allocator,
        .{},
        work,
        &.{policy},
    ).failure);

    try std.testing.expect(findToolWork(&.{work}, "missing") == null);

    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore: durable routing guard
            return error.UnusedModel;
        }
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const other = model_types.Tool{
        .definition = .{ .name = "other", .description = "", .parameters_json_schema = "{}" },
        .context = &tool_context,
        .executeFn = Executor.execute,
    };
    const parallel_work = [_]ToolWork{
        .{
            .call = .{ .id = "retry", .name = "demo", .arguments_json = "{}" },
            .tool_index = 0,
            .arguments_json = "{}",
            .execution = .immediate,
            .retry_message = "retry",
        },
        .{
            .call = .{ .id = "invalid", .name = "other", .arguments_json = "{}" },
            .tool_index = 1,
            .arguments_json = "{}",
            .execution = .immediate,
            .validation_failure = error.InvalidArguments,
        },
    };
    var parallel_retries = ToolRetryTracker{ .allocator = allocator };
    const parallel_agent = Agent{
        .model = .{ .context = &tool_context, .profile = .{}, .requestFn = Stub.request },
        .io = io,
    };
    try std.testing.expectError(error.UnusedModel, parallel_agent.model.request(allocator, .{ .messages = &.{} }));
    const batch = try executeToolCalls(
        parallel_agent,
        &.{ tool, other },
        allocator,
        &parallel_work,
        &parallel_retries,
        .{ .io = io },
        &.{},
        &.{},
        null,
    );
    try std.testing.expectEqualStrings("retry", batch.parts[0].tool_return.content);
    try std.testing.expect(batch.parts[1].tool_return.is_error);
}

fn collectText(allocator: std.mem.Allocator, parts: []const ResponsePart) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| switch (part) {
        .text => |text| try output.appendSlice(allocator, text),
        .text_part => |text| try output.appendSlice(allocator, text.content),
        .speech => |speech| if (speech.transcript) |text| try output.appendSlice(allocator, text),
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

test "tool control drains work at deadlines and cancellation" {
    const State = struct {
        active: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run: model_types.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            _ = allocator;
            while (true) try (std.Io.Timeout{ .duration = .{
                .raw = .fromSeconds(10),
                .clock = .awake,
            } }).sleep(run.io.?);
        }

        fn cancelAfter(io: std.Io, token: *CancellationToken, state: *@This()) !void {
            const start_deadline = std.Io.Clock.Timestamp.fromNow(io, .{
                .raw = .fromSeconds(5),
                .clock = .awake,
            });
            while (!state.active.load(.seq_cst)) {
                if (std.Io.Clock.Timestamp.now(io, .awake).durationTo(start_deadline).raw.nanoseconds <= 0) { // unreachable in a passing scheduler test
                    token.cancel(); // unreachable in a passing scheduler test
                    return error.ToolDidNotStart; // unreachable in a passing scheduler test
                }
                try toolTimeout(1).sleep(io); // unreachable when the tool starts before the canceller is scheduled
            }
            token.cancel();
        }
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var state = State{ .active = .init(false) };
    const tool = model_types.Tool{
        .definition = .{ .name = "slow", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeWithContextFn = State.execute,
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromSeconds(1),
        .clock = .awake,
    });
    const outcome = executeToolWorkControlled(io, null, tool, .{}, std.testing.allocator, .{
        .io = io,
        .deadline = deadline,
    }, .{
        .call = .{ .id = "slow", .name = "slow", .arguments_json = "{}" },
        .tool_index = 0,
        .arguments_json = "{}",
        .execution = .immediate,
    }, &.{});
    try std.testing.expectEqual(Agent.Error.RunTimedOut, outcome.failure);
    try std.testing.expect(!state.active.load(.seq_cst));

    var token: CancellationToken = .{};
    var cancel_runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer cancel_runtime.deinit();
    var cancel = try cancel_runtime.io().concurrent(State.cancelAfter, .{ cancel_runtime.io(), &token, &state });
    const cancelled = executeToolWorkControlled(io, null, tool, .{}, std.testing.allocator, .{
        .io = io,
        .cancellation = &token,
    }, .{
        .call = .{ .id = "slow", .name = "slow", .arguments_json = "{}" },
        .tool_index = 0,
        .arguments_json = "{}",
        .execution = .immediate,
    }, &.{});
    try cancel.await(cancel_runtime.io());
    try std.testing.expectEqual(Agent.Error.Cancelled, cancelled.failure);
    try std.testing.expect(!state.active.load(.seq_cst));

    const Fast = struct {
        fn execute(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "ok");
        }
    };
    var success_runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer success_runtime.deinit();
    const success_io = success_runtime.io();
    const fast_tool = model_types.Tool{
        .definition = .{ .name = "fast", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = Fast.execute,
    };
    const succeeded = executeToolWorkControlled(success_io, null, fast_tool, .{ .timeout_ms = 10_000 }, std.testing.allocator, .{ .io = success_io }, .{
        .call = .{ .id = "fast", .name = "fast", .arguments_json = "{}" },
        .tool_index = 0,
        .arguments_json = "{}",
        .execution = .immediate,
    }, &.{});
    try std.testing.expect(succeeded == .success);
    defer std.testing.allocator.free(succeeded.success.content);
    try std.testing.expectEqualStrings("ok", succeeded.success.content);
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
    try std.testing.expect(shouldRetry(error.ProviderConnectionError, defaults));
    try std.testing.expect(shouldRetry(error.ProviderResponseDecodeError, defaults));
    try std.testing.expect(shouldRetry(error.ProviderRateLimited, defaults));
    try std.testing.expect(shouldRetry(error.ProviderServerError, defaults));
    try std.testing.expect(shouldRetry(error.RequestTimedOut, defaults));
    try std.testing.expect(!shouldRetry(error.ProviderRequestFailed, defaults));
    try std.testing.expect(!shouldRetry(error.ProviderRateLimited, .{ .retry_rate_limits = false }));
    try std.testing.expect(!shouldRetry(error.ProviderServerError, .{ .retry_server_errors = false }));
    try std.testing.expect(!shouldRetry(error.RequestTimedOut, .{ .retry_timeouts = false }));
    try std.testing.expect(!shouldRetry(error.ProviderConnectionError, .{ .retry_connection_errors = false }));
    try std.testing.expect(!shouldRetry(error.ProviderResponseDecodeError, .{ .retry_decode_errors = false }));
}

test "backoff applies full jitter, caps growth, and honors Retry-After" {
    const policy: Agent.Backoff = .{ .initial_delay_ms = 100, .maximum_delay_ms = 350 };
    try std.testing.expect(backoffDelayMilliseconds(std.testing.io, policy, 1, null) <= 100);
    try std.testing.expect(backoffDelayMilliseconds(std.testing.io, policy, 2, null) <= 200);
    try std.testing.expect(backoffDelayMilliseconds(std.testing.io, policy, 4, null) <= 350);
    try std.testing.expectEqual(@as(u64, 350), backoffDelayMilliseconds(std.testing.io, policy, 1, 2));
    try std.testing.expect(backoffDelayMilliseconds(std.testing.io, .{
        .initial_delay_ms = 100,
        .maximum_delay_ms = 350,
        .respect_retry_after = false,
    }, 1, 2) <= 100);
    try std.testing.expectEqual(@as(u64, 350), backoffDelayMilliseconds(std.testing.io, policy, 1, std.math.maxInt(u64)));
    var idempotency_key: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32), generateIdempotencyKey(std.testing.io, &idempotency_key).len);
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

test "pending message final drains close only after the FIFO is empty" {
    var queue = PendingMessageQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    try queue.enqueue(&.{});
    try queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "queued" } }} }});
    try queue.activate();
    var drained = queue.drainOrClose().?;
    defer drained.deinit();
    try std.testing.expectEqual(@as(usize, 1), drained.batches.items.len);
    try std.testing.expect(queue.drainOrClose() == null);
    try std.testing.expectError(
        Agent.Error.PendingMessageQueueClosed,
        queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "late" } }} }}),
    );
}

test "pending message queue serializes concurrent producers" {
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var queue = PendingMessageQueue.init(std.testing.allocator, io);
    defer queue.deinit();
    const Producer = struct {
        fn enqueue(target: *PendingMessageQueue, text: []const u8) !void {
            try target.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = text } }} }});
        }
    };
    var first = try io.concurrent(Producer.enqueue, .{ &queue, "first" });
    var second = try io.concurrent(Producer.enqueue, .{ &queue, "second" });
    try first.await(io);
    try second.await(io);
    try queue.activate();
    var drained = queue.drain().?;
    defer drained.deinit();
    try std.testing.expectEqual(@as(usize, 2), drained.batches.items.len);
    var saw_first = false;
    var saw_second = false;
    for (drained.batches.items) |batch| {
        const text = batch.messages[0].parts[0].user_prompt.text;
        saw_first = saw_first or std.mem.eql(u8, text, "first");
        saw_second = saw_second or std.mem.eql(u8, text, "second");
    }
    try std.testing.expect(saw_first and saw_second);
}

test "pending message copies reject response roles" {
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.Unused;
        }
    };
    var unused: u8 = 0;
    const selected_model = model_types.Model{ .context = &unused, .profile = .{}, .requestFn = Stub.request };
    try std.testing.expectError(error.Unused, selected_model.request(std.testing.allocator, .{ .messages = &.{} }));
    var messages: std.ArrayList(Message) = .empty;
    try std.testing.expectError(Agent.Error.InvalidContentRole, appendPendingMessageCopies(
        selected_model,
        .{},
        std.testing.allocator,
        &messages,
        &.{.{ .response = .{ .parts = &.{.{ .text = "invalid" }} } }},
    ));
}

fn checkResumeDecisionAllocationFailure(allocator: std.mem.Allocator) !void {
    var decisions = try parseResumeDecisions(
        allocator,
        "{\"version\":1,\"decisions\":[{\"call_id\":\"call\",\"action\":\"approve\"}]}",
    );
    defer decisions.deinit();
}

fn checkControlledHooksAllocationFailure(allocator: std.mem.Allocator) !void {
    var placeholder: u8 = 0;
    const controlled = try ControlledHooks.init(allocator, &.{.{
        .context = &placeholder,
        .eventFn = ControlledLifecycleHook.emit, // kcov-ignore
    }}, .{});
    defer controlled.deinit(allocator);
}

fn checkPendingMessageQueueAllocationFailure(allocator: std.mem.Allocator) !void {
    var queue = PendingMessageQueue.init(allocator, std.testing.io);
    defer queue.deinit();
    try queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "copied" } }} }});
}

test "agent private helpers cover ownership settings retries and rich content" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkResumeDecisionAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkControlledHooksAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPendingMessageQueueAllocationFailure, .{});

    try std.testing.expectError(Agent.Error.ToolFollowUpOverflow, validateToolOutput(.{
        .content = "",
        .follow_up_messages = &.{.{ .parts = &.{}, .metadata = &.{.{ .key = "a", .value = "bc" }} }},
    }, .{ .max_follow_up_bytes = 2 }));
    try std.testing.expectError(Agent.Error.ToolFollowUpOverflow, validateToolOutput(.{
        .content = "",
        .follow_up_messages = &.{.{ .parts = &.{}, .instructions = "too long" }},
    }, .{ .max_follow_up_bytes = 2 }));
    try std.testing.expectError(Agent.Error.ToolFollowUpOverflow, validateToolOutput(.{
        .content = "",
        .follow_up_messages = &.{.{ .parts = &.{}, .run_id = "too long" }},
    }, .{ .max_follow_up_bytes = 2 }));
    try std.testing.expectError(Agent.Error.ToolFollowUpOverflow, validateToolOutput(.{
        .content = "",
        .follow_up_messages = &.{.{
            .parts = &.{},
            .instruction_parts = &.{.{ .content = "too long" }},
        }},
    }, .{ .max_follow_up_bytes = 2 }));

    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportMaxTokens,
        requireModelSettings(.{ .supports_max_tokens = false }, .{ .max_tokens = 1 }),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportStopSequences,
        requireModelSettings(.{ .supports_stop_sequences = false }, .{ .stop_sequences = &.{"stop"} }),
    );

    var locked = LockedAllocator{ .child = std.testing.allocator, .io = std.testing.io };
    const concurrent = locked.allocator();
    var bytes = try concurrent.alloc(u8, 64);
    if (concurrent.resize(bytes, 32)) bytes = bytes[0..32];
    if (concurrent.remap(bytes, 16)) |remapped| bytes = remapped;
    concurrent.free(bytes);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const copied = [_]Part{
        try copyPart(allocator, .{ .image = .{ .source = .{ .bytes = "image" }, .media_type = "image/png" } }),
        try copyPart(allocator, .{ .audio = .{ .source = .{ .bytes = "audio" }, .media_type = "audio/mpeg" } }),
        try copyPart(allocator, .{ .document = .{
            .source = .{ .url = "https://example.test/doc" },
            .media_type = "application/pdf",
        } }),
        try copyPart(allocator, .{ .binary = .{
            .source = .{ .provider_file = .{ .id = "file", .provider = "provider" } },
            .media_type = "application/octet-stream",
        } }),
        try copyPart(allocator, .{ .thinking = .{ .content = "private", .signature = "signed" } }),
    };
    try std.testing.expectEqualStrings("image", copied[0].image.source.bytes);
    try std.testing.expectEqualStrings("audio", copied[1].audio.source.bytes);
    try std.testing.expectEqualStrings("https://example.test/doc", copied[2].document.source.url);
    try std.testing.expectEqualStrings("file", copied[3].binary.source.provider_file.id);
    try std.testing.expectEqualStrings("signed", copied[4].thinking.signature.?);

    const copied_prompts = [_]PromptPart{
        try copyPromptPart(allocator, .{ .audio = .{ .source = .{ .bytes = "audio" }, .media_type = "audio/mpeg" } }),
        try copyPromptPart(allocator, .{ .video = .{ .source = .{ .bytes = "video" }, .media_type = "video/mp4" } }),
        try copyPromptPart(allocator, .{ .document = .{ .source = .{ .bytes = "doc" }, .media_type = "application/pdf" } }),
        try copyPromptPart(allocator, .{ .binary = .{ .source = .{ .bytes = "binary" }, .media_type = "application/octet-stream" } }),
    };
    try std.testing.expectEqualStrings("audio", copied_prompts[0].audio.source.bytes);
    _ = try copyRequestPart(allocator, .{ .system_prompt = "system" });
    _ = try copyRequestPart(allocator, .{ .retry_prompt = "retry" });
    _ = try copyRequestMessage(allocator, .{
        .parts = &.{.{ .user_prompt = .{ .text = "hello" } }},
        .instruction_parts = &.{.{ .content = "structured", .dynamic = true }},
        .instructions = "rendered",
        .run_id = "run",
        .conversation_id = "conversation",
        .metadata = &.{.{ .key = "key", .value = "value" }},
        .state = .interrupted,
    });

    const provider = model_types.ProviderPart{ .id = "item", .provider_name = "provider" };
    const uploaded = model_types.UploadedFile{
        .id = "file",
        .provider_name = "provider",
        .media_type = "video/mp4",
        .metadata = &.{.{ .key = "key", .value = "value" }},
    };
    const rich_content = model_types.Content{
        .source = .{ .uploaded_file = uploaded },
        .media_type = "video/mp4",
        .provider = provider,
        .metadata = &.{.{ .key = "key", .value = "value" }},
    };
    try validateToolOutput(.{
        .content = "ok",
        .follow_up_messages = &.{.{
            .parts = &.{
                .{ .system_prompt_part = .{ .content = "system", .dynamic_ref = "dynamic" } },
                .{ .user_prompt_part = .{ .content = .{ .text_content = .{
                    .content = "text",
                    .metadata = &.{.{ .key = "key", .value = "value" }},
                } } } },
                .{ .user_prompt = .{ .uploaded_file = uploaded } },
                .{ .speech = .{ .speaker = .user, .transcript = "spoken", .audio = rich_content } },
                .{ .tool_search_return = .{
                    .call_id = "search",
                    .discovered_tools = &.{.{ .name = "weather" }},
                    .message = "found",
                    .metadata = &.{.{ .key = "key", .value = "value" }},
                } },
                .{ .capability_load_return = .{
                    .call_id = "load",
                    .instructions = "loaded",
                    .metadata = &.{.{ .key = "key", .value = "value" }},
                } },
                .{ .tool_return = .{
                    .call_id = "tool",
                    .name = "weather",
                    .content = "result",
                    .files = &.{rich_content},
                    .metadata = &.{.{ .key = "key", .value = "value" }},
                } },
                .{ .retry_prompt_part = .{
                    .content = "retry",
                    .tool_name = "weather",
                    .tool_call_id = "tool",
                } },
                .{ .tool_availability_delta = .{
                    .tools_added = &.{ "weather", "clock" },
                    .tool_call_id = "search",
                } },
            },
            .instruction_parts = &.{.{ .content = "instruction" }},
            .instructions = "rendered",
            .run_id = "run",
            .conversation_id = "conversation",
            .metadata = &.{.{ .key = "key", .value = "value" }},
        }},
    }, .{ .max_follow_up_bytes = 4096 });

    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return .{ .parts = &.{} }; // kcov-ignore
        }
    };
    var unused: u8 = 0;
    const selected_model = model_types.Model{
        .context = &unused,
        .profile = .{ .content_types = model_types.ModelProfile.ContentTypeSet.initMany(&.{
            .image,
            .audio,
            .video,
            .document,
            .binary,
            .thinking,
        }) },
        .provider_name = "provider",
        .requestFn = Stub.request,
    };
    _ = try selected_model.request(allocator, .{ .messages = &.{} });
    var messages: std.ArrayList(Message) = .empty;
    try std.testing.expectError(Agent.Error.InvalidToolFollowUpMessage, appendToolFollowUps(
        selected_model,
        .{},
        allocator,
        &messages,
        &.{.{ .parts = &.{.{ .system_prompt = "not allowed" }} }},
    ));

    var tracker = ToolRetryTracker{ .allocator = allocator };
    try tracker.restore(&.{.{ .name = "first", .count = 1 }});
    try std.testing.expect(try tracker.consume("first", 3));
    try std.testing.expect(try tracker.consume("second", 1));
    try std.testing.expect(!try tracker.consume("missing", 0));

    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportWebSearch,
        ensureBuiltinToolsSupported(.{}, &.{.{ .web_search = .{} }}),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportWebFetch,
        ensureBuiltinToolsSupported(.{}, &.{.{ .web_fetch = .{} }}),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportXSearch,
        ensureBuiltinToolsSupported(.{}, &.{.{ .x_search = .{} }}),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportCodeExecution,
        ensureBuiltinToolsSupported(.{}, &.{.{ .code_execution = .{} }}),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportFileSearch,
        ensureBuiltinToolsSupported(.{}, &.{.{ .file_search = .{ .vector_store_ids = &.{"collection"} } }}),
    );
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportRemoteMcp,
        ensureBuiltinToolsSupported(.{}, &.{.{ .remote_mcp = .{ .server_url = "https://example.test", .server_label = "one" } }}),
    );
    try ensureBuiltinToolsSupported(.{
        .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{.remote_mcp}),
    }, &.{
        .{ .remote_mcp = .{ .server_url = "https://one.example", .server_label = "one" } },
        .{ .remote_mcp = .{ .server_url = "https://two.example", .server_label = "two" } },
    });
    try std.testing.expectError(
        Agent.Error.DuplicateBuiltinTool,
        ensureBuiltinToolsSupported(.{
            .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{.remote_mcp}),
        }, &.{
            .{ .remote_mcp = .{ .server_url = "https://one.example", .server_label = "same" } },
            .{ .remote_mcp = .{ .server_url = "https://two.example", .server_label = "same" } },
        }),
    );
    const content = model_types.Content{ .source = .{ .bytes = "x" }, .media_type = "application/octet-stream" };
    try ensurePromptPartsSupported(selected_model, .{}, &.{
        .{ .image = content },
        .{ .audio = content },
        .{ .video = content },
        .{ .document = content },
        .{ .binary = content },
        .{ .uploaded_file = uploaded },
    });
    try ensureResponsePartsSupported(selected_model, .{}, &.{
        .{ .text_part = .{ .content = "text", .provider = provider } },
        .{ .tool_search_call = .{ .call_id = "search", .queries = &.{}, .provider = provider } },
        .{ .native_tool_search_call = .{ .call_id = "search", .queries = &.{}, .provider = provider } },
        .{ .tool_call = .{ .id = "tool", .name = "weather", .arguments_json = "{}", .provider = provider } },
        .{ .native_tool_call = .{
            .id = "native",
            .name = "search",
            .arguments_json = "{}",
            .provider = provider,
        } },
        .{ .native_tool_search_return = .{
            .call_id = "search",
            .discovered_tools = &.{},
            .provider = provider,
        } },
        .{ .native_tool_return = .{
            .call_id = "native",
            .name = "search",
            .content = "result",
            .files = &.{rich_content},
            .provider = provider,
        } },
        .{ .compaction = .{ .content = "summary", .provider = provider } },
        .{ .image = content },
        .{ .audio = content },
        .{ .video = content },
        .{ .document = content },
        .{ .binary = content },
        .{ .thinking = .{ .content = "private", .provider = provider } },
        .{ .speech = .{ .speaker = .assistant, .audio = content, .provider = provider } },
    });
    try ensureContentSupported(selected_model, .{}, &.{
        .{ .request = .{ .parts = &.{
            .{ .user_prompt = .{ .text = "text" } },
            .{ .user_prompt_part = .{ .content = .{ .video = content } } },
            .{ .speech = .{ .speaker = .user, .audio = content, .provider = provider } },
            .{ .tool_search_return = .{ .call_id = "search", .discovered_tools = &.{}, .provider = provider } },
            .{ .tool_return = .{ .call_id = "tool", .name = "weather", .content = "ok", .files = &.{content} } },
        } } },
        .{ .response = .{ .parts = &.{.{ .text = "text" }} } },
    });
    try std.testing.expectError(
        Agent.Error.ModelDoesNotSupportThinking,
        ensureResponsePartsSupported(.{
            .context = &unused,
            .profile = .{},
            .requestFn = Stub.request,
        }, .{}, &.{.{ .thinking = .{ .content = "private" } }}),
    );
    const unsupported_model = model_types.Model{ .context = &unused, .profile = .{}, .requestFn = Stub.request };
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportImages, ensureContentPartSupported(unsupported_model, .{}, .image, content));
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportAudio, ensureContentPartSupported(unsupported_model, .{}, .audio, content));
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportVideo, ensureContentPartSupported(unsupported_model, .{}, .video, content));
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportDocuments, ensureContentPartSupported(unsupported_model, .{}, .document, content));
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportBinaryContent, ensureContentPartSupported(unsupported_model, .{}, .binary, content));
    try std.testing.expectError(Agent.Error.ModelDoesNotSupportThinking, ensureContentPartSupported(unsupported_model, .{}, .thinking, content));

    const local_url = model_types.Content{
        .source = .{ .url = "https://127.0.0.1/private" },
        .media_type = "image/png",
    };
    try std.testing.expectError(
        Agent.Error.LocalNetworkUrlForbidden,
        ensureContentPartSupported(selected_model, .{}, .image, local_url),
    );
    try ensureContentPartSupported(selected_model, .{ .allow_local_network = true }, .image, local_url);
    try std.testing.expectError(
        Agent.Error.ProviderFileProviderMismatch,
        ensureProviderPartOwnedBy(selected_model, .{ .id = "missing-owner" }),
    );
    try std.testing.expectError(
        Agent.Error.ProviderFileProviderMismatch,
        ensureProviderPartOwnedBy(selected_model, .{ .provider_name = "other" }),
    );
    const collected = try collectText(allocator, &.{
        .{ .text_part = .{ .content = "detailed" } },
        .{ .speech = .{ .speaker = .assistant, .transcript = " speech" } },
    });
    try std.testing.expectEqualStrings("detailed speech", collected);
}

test "structured provider details copy and count every JSON value kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values = std.json.Array.init(allocator);
    try values.append(.null);
    try values.append(.{ .bool = false });
    try values.append(.{ .integer = 1 });
    try values.append(.{ .float = 1.5 });
    try values.append(.{ .number_string = "123456789012345678901234567890" });
    try values.append(.{ .string = "opaque\n\"value" });
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "values", .{ .array = values });
    const details = model_types.ProviderDetails{ .value = .{ .object = object } };

    var total: usize = 0;
    try std.testing.expect(consumeProviderDetailsBytes(&total, 256, details));
    try std.testing.expect(total > 0);
    total = 0;
    try std.testing.expect(!consumeProviderDetailsBytes(&total, 1, details));
    try std.testing.expect(consumeProviderDetailsBytes(&total, 1, null));

    const copied = try copyResponseMessage(allocator, .{ .parts = &.{}, .provider_details = details });
    try std.testing.expectEqualStrings(
        "opaque\n\"value",
        copied.provider_details.?.value.object.get("values").?.array.items[5].string,
    );
}

test "typed result decoding releases invalid untyped results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const output = try arena.allocator().dupe(u8, "not-json");
    const messages = try arena.allocator().alloc(Message, 0);
    const result = Agent.Result{
        .arena = arena,
        .output = output,
        .messages = messages,
        .usage = .{},
        .model_requests = 1,
        .finish_reason = null,
    };
    try std.testing.expectError(Agent.Error.InvalidTypedOutput, decodeTypedResult(struct { value: u8 }, result));
}

test "paused state serializes retries and rejects mismatched calls" {
    var unused: u8 = 0;
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return .{ .parts = &.{} }; // kcov-ignore
        }
    };
    const agent = Agent{ .model = .{ .context = &unused, .profile = .{}, .requestFn = Stub.request } };
    _ = try agent.model.request(std.testing.allocator, .{ .messages = &.{} });
    const approval = model_types.Tool{
        .definition = .{ .name = "approval", .description = "", .parameters_json_schema = "{}" },
        .execution = .requires_approval,
        .context = &unused,
    };
    const call = Part{ .tool_call = .{ .id = "call", .name = "approval", .arguments_json = "{}" } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var paused = try createPausedRun(
        &arena,
        arena.allocator(),
        "prompt",
        &.{.{ .response = .{ .parts = &.{call} } }},
        &.{"instruction"},
        .{},
        1,
        1,
        0,
        &.{.{ .name = "approval", .count = 1 }},
        &.{approval},
        &.{call},
        &.{.{
            .call = call.tool_call,
            .tool_index = 0,
            .arguments_json = "{}",
            .execution = .requires_approval,
        }},
        &.{},
    );
    defer paused.deinit();
    try std.testing.expect(std.mem.indexOf(u8, paused.state_json, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, paused.state_json, "\"tool_retries\":[{\"name\":\"approval\",\"count\":1}]") != null);
    try std.testing.expectError(Agent.Error.InvalidDeferredState, validateDeferredCalls(
        &.{approval},
        &.{call},
        &.{.{
            .call_id = "different",
            .name = "approval",
            .arguments_json = "{}",
            .model_arguments_json = "{}",
            .execution = .requires_approval,
            .retry_number = 0,
        }},
    ));
    var retries = ToolRetryTracker{ .allocator = std.testing.allocator };
    try std.testing.expectError(Agent.Error.InvalidDeferredState, executeResumedToolCalls(
        agent,
        &.{approval},
        std.testing.allocator,
        &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "not a response" } }} } }},
        &.{},
        &.{},
        &retries,
        .{},
        &.{},
        null,
    ));
}

fn capabilityLoadFailureInstruction(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: InstructionContext,
) ![]const u8 {
    return error.TestInstructionFailure;
}

fn checkCapabilityLoadAllocationFailure(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const capabilities = [_]ScopedCapability{.{
        .capability = .{ .id = "deferred", .loading = .on_demand },
        .scope = .agent,
        .source_index = 0,
    }};
    const entries = [_]capability_types.Entry{.{
        .descriptor = capabilities[0].capability.descriptor(),
        .scope = .agent,
        .source_index = 0,
    }};
    var active = [_]bool{false};
    var loaded = [_]bool{false};
    var initial = [_]bool{false};
    var pending = [_]bool{false};
    var runtime = CapabilityRuntime{
        .scoped = &capabilities,
        .entries = &entries,
        .active = &active,
        .loaded = &loaded,
        .initial = &initial,
        .pending = &pending,
        .prompt = "prompt",
        .dependencies = null,
        .control = .{},
    };
    _ = try runtime.requestLoad(allocator, "deferred");
    try std.testing.expect(pending[0]);
    const duplicate = try runtime.requestLoad(allocator, "deferred");
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "already loaded") != null);
}

test "capability load is atomic across instruction and allocation failures" {
    var unused: u8 = 0;
    const capabilities = [_]ScopedCapability{.{ // kcov-ignore: comptime-only test fixture declaration
        .capability = .{
            .id = "deferred",
            .loading = .on_demand,
            .instructions = &.{.{ .dynamic = .{
                .context = &unused,
                .resolveFn = capabilityLoadFailureInstruction,
            } }},
        },
        .scope = .agent,
        .source_index = 0,
    }};
    const entries = [_]capability_types.Entry{.{
        .descriptor = capabilities[0].capability.descriptor(),
        .scope = .agent,
        .source_index = 0,
    }};
    var active = [_]bool{false};
    var loaded = [_]bool{false};
    var initial = [_]bool{false};
    var pending = [_]bool{false};
    var runtime = CapabilityRuntime{
        .scoped = &capabilities,
        .entries = &entries,
        .active = &active,
        .loaded = &loaded,
        .initial = &initial,
        .pending = &pending,
        .prompt = "prompt",
        .dependencies = null,
        .control = .{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TestInstructionFailure,
        runtime.requestLoad(arena.allocator(), "deferred"),
    );
    try std.testing.expect(!pending[0]);
    try std.testing.expectEqual(
        AgentError.InvalidCapability,
        capabilityDiagnosticError(.{ .kind = .missing_conflict }),
    );
    const typed_success = [_]Message{.{ .request = .{ .parts = &.{.{ .capability_load_return = .{
        .call_id = "typed",
        .instructions = "loaded",
    } }} } }};
    try std.testing.expect(hasSuccessfulCapabilityReturn(&typed_success, "typed"));
    const typed_failure = [_]Message{.{ .request = .{ .parts = &.{.{ .capability_load_return = .{
        .call_id = "typed",
        .outcome = .failed,
    } }} } }};
    try std.testing.expect(!hasSuccessfulCapabilityReturn(&typed_failure, "typed"));
    const ordinary_success = [_]Message{.{ .request = .{ .parts = &.{.{ .tool_return = .{
        .call_id = "ordinary",
        .name = load_capability_tool_name,
        .content = "loaded",
        .tool_kind = .capability_load,
    } }} } }};
    try std.testing.expect(hasSuccessfulCapabilityReturn(&ordinary_success, "ordinary"));
    try std.testing.expect(hasSuccessfulToolReturn(&ordinary_success, "ordinary", load_capability_tool_name));
    try std.testing.expect(!hasSuccessfulCapabilityReturn(&.{}, "missing"));
    try std.testing.expect(!hasSuccessfulToolReturn(&.{}, "missing", load_capability_tool_name));
    const response_only = [_]Message{.{ .response = .{ .parts = &.{} } }};
    try std.testing.expect(!hasSuccessfulCapabilityReturn(&response_only, "missing"));
    try std.testing.expect(!hasSuccessfulToolReturn(&response_only, "missing", load_capability_tool_name));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCapabilityLoadAllocationFailure,
        .{},
    );
}

test "durable model routes bypass local providers and replay normalized streams" {
    const RuntimeState = struct {
        calls: usize = 0,
        outcome: enum { success, failure, suspended } = .success,

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            invocation: durable_types.Invocation,
        ) !durable_types.OwnedRecord {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(u64, 1), invocation.sequence);
            try std.testing.expectEqualStrings(
                if (invocation.kind == .model_stream) "model.stream" else "model.request",
                invocation.step_id,
            );
            var request = try durable_types.payloads.model.parseRequest(allocator, invocation.input_json);
            defer request.deinit();
            try std.testing.expectEqualStrings("hello", request.value.messages[0].request.parts[0].user_prompt.text);
            switch (self.outcome) {
                .success => {},
                .failure => return durable_types.OwnedRecord.copy(
                    allocator,
                    durable_types.Record.init(invocation, .{ .failure = .{ .error_name = "Unavailable" } }),
                ),
                .suspended => return durable_types.OwnedRecord.copy(
                    allocator,
                    durable_types.Record.init(invocation, .{ .suspended = .{
                        .reason = .provider_resume,
                        .state_json = "{}",
                    } }),
                ),
            }
            const output_json = try durable_types.payloads.model.stringifyResponse(allocator, .{
                .parts = &.{.{ .text = "durable" }},
                .usage = .{ .input_tokens = 1, .output_tokens = 1 },
                .provider_name = "durable",
                .model_name = "worker-model",
            });
            defer allocator.free(output_json);
            return durable_types.OwnedRecord.copy(
                allocator,
                durable_types.Record.init(invocation, .{ .success = output_json }),
            );
        }
    };
    const LocalModel = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.LocalModelMustNotRun; // kcov-ignore: durable routing guard
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: model_types.ModelRequest,
            _: model_types.ModelStreamSink,
        ) !model_types.ModelResponse { // kcov-ignore: durable routing guard
            return error.LocalModelMustNotRun; // kcov-ignore: durable routing guard
        }
    };
    const Sink = struct {
        model_events: usize = 0,

        fn emit(context: *anyopaque, event: AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .model => self.model_events += 1,
                else => {},
            }
        }
    };

    var runtime_state: RuntimeState = .{};
    var local_state: u8 = 0;
    const binding = durable_types.Binding{
        .runtime = .{ .context = &runtime_state, .executeFn = RuntimeState.execute },
        .run_id = "run-1",
        .handlers = .{
            .model_request = "model-worker",
            .model_stream = "model-stream-worker",
        },
    };
    const durable_agent = Agent{ .model = .{
        .context = &local_state,
        .profile = .{ .supports_streaming = true },
        .requestFn = LocalModel.request,
        .streamFn = LocalModel.stream,
    } };
    var buffered = try durable_agent.runWithOptions(std.testing.allocator, "hello", .{ .durable = binding });
    defer buffered.deinit();
    try std.testing.expectEqualStrings("durable", buffered.output);

    var sink_state: Sink = .{};
    var streamed = try durable_agent.runStreamWithOptions(
        std.testing.allocator,
        "hello",
        .{ .durable = binding },
        .{ .context = &sink_state, .eventFn = Sink.emit },
    );
    defer streamed.deinit();
    try std.testing.expectEqualStrings("durable", streamed.output);
    try std.testing.expectEqual(@as(usize, 4), sink_state.model_events);
    try std.testing.expectEqual(@as(usize, 2), runtime_state.calls);

    runtime_state.outcome = .failure;
    try std.testing.expectError(
        Agent.Error.DurableOperationFailed,
        durable_agent.runWithOptions(std.testing.allocator, "hello", .{ .durable = binding }),
    );
    runtime_state.outcome = .suspended;
    try std.testing.expectError(
        Agent.Error.DurableOperationSuspended,
        durable_agent.runWithOptions(std.testing.allocator, "hello", .{ .durable = binding }),
    );
}

test "durable parallel tools use source-order identities and MCP operation kinds" {
    const RuntimeState = struct {
        seen_tools: std.atomic.Value(u8) = .init(0),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            invocation: durable_types.Invocation,
        ) !durable_types.OwnedRecord {
            const self: *@This() = @ptrCast(@alignCast(context));
            const output_json = switch (invocation.kind) {
                .model_request => try durable_types.payloads.model.stringifyResponse(allocator, if (invocation.sequence == 1)
                    .{ .parts = &.{
                        .{ .tool_call = .{ .id = "app-1", .name = "app", .arguments_json = "{}" } },
                        .{ .tool_call = .{ .id = "mcp-1", .name = "mcp", .arguments_json = "{}" } },
                    } }
                else
                    .{ .parts = &.{.{ .text = "complete" }} }),
                .tool_call, .mcp_request => output: {
                    var request = try durable_types.payloads.tool.parseRequest(allocator, invocation.input_json);
                    defer request.deinit();
                    if (invocation.kind == .tool_call) {
                        try std.testing.expectEqualStrings("app", request.call.name);
                        try std.testing.expectEqual(@as(u64, 1), invocation.sequence);
                        _ = self.seen_tools.fetchOr(1, .seq_cst);
                    } else {
                        try std.testing.expectEqualStrings("mcp", request.call.name);
                        try std.testing.expectEqual(@as(u64, 2), invocation.sequence);
                        _ = self.seen_tools.fetchOr(2, .seq_cst);
                    }
                    break :output try durable_types.payloads.tool.stringifyResponse(allocator, .{
                        .content = request.call.name,
                        .follow_up_messages = if (invocation.kind == .tool_call)
                            &.{.{ .parts = &.{.{ .user_prompt = .{ .text = "durable follow-up" } }} }}
                        else
                            &.{},
                    });
                },
                else => return error.UnexpectedDurableOperation,
            };
            defer allocator.free(output_json);
            return durable_types.OwnedRecord.copy(
                allocator,
                durable_types.Record.init(invocation, .{ .success = output_json }),
            );
        }
    };
    const Local = struct {
        fn model(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore: durable routing guard
            return error.LocalModelMustNotRun; // kcov-ignore: durable routing guard
        }

        fn tool(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 { // kcov-ignore: durable routing guard
            return error.LocalToolMustNotRun; // kcov-ignore: durable routing guard
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var runtime_state: RuntimeState = .{};
    var local_state: u8 = 0;
    const configured = Agent{
        .model = .{
            .context = &local_state,
            .profile = .{},
            .requestFn = Local.model,
        },
        .tools = &.{
            .{
                .definition = .{ .name = "app", .description = "", .parameters_json_schema = "{}" },
                .context = &local_state,
                .executeFn = Local.tool,
            },
            .{
                .definition = .{ .name = "mcp", .description = "", .parameters_json_schema = "{}" },
                .origin = .mcp,
                .context = &local_state,
                .executeFn = Local.tool,
            },
        },
        .io = threaded.io(),
    };
    const binding = durable_types.Binding{
        .runtime = .{ .context = &runtime_state, .executeFn = RuntimeState.execute },
        .run_id = "parallel-run",
        .handlers = .{
            .model_request = "model-worker",
            .tool_call = "tool-worker",
            .mcp_request = "mcp-worker",
        },
    };
    var result = try configured.runWithOptions(std.testing.allocator, "run", .{ .durable = binding });
    defer result.deinit();
    try std.testing.expectEqualStrings("complete", result.output);
    try std.testing.expectEqual(@as(u8, 3), runtime_state.seen_tools.load(.seq_cst));
}
