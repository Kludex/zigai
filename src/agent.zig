//! The provider-neutral agent loop and its owned buffered and typed results.

const std = @import("std");
const model_types = @import("model.zig");
const json_schema = @import("json_schema.zig");
const reflect = @import("reflect.zig");

const Message = model_types.Message;
const Part = model_types.Part;

const AgentError = error{
    Cancelled,
    EmptyModelResponse,
    InputTokenLimitExceeded,
    InvalidTypedOutput,
    MaxModelRequestsExceeded,
    ModelDoesNotSupportSystemMessages,
    ModelDoesNotSupportTools,
    ModelDoesNotSupportJsonObjectOutput,
    ModelDoesNotSupportJsonSchemaOutput,
    ModelDoesNotSupportStreaming,
    OutputTokenLimitExceeded,
    ParallelToolCallsNotSupported,
    TotalTokenLimitExceeded,
    UnknownTool,
    RetryBackoffRequiresIo,
};

const AgentUsageLimits = struct {
    max_model_requests: usize = 8,
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

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const Agent = struct {
    model: model_types.Model,
    tools: []const model_types.Tool = &.{},
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
    limits: UsageLimits = .{},
    retry_policy: RetryPolicy = .{},
    provider_error_observer: ?model_types.ProviderErrorObserver = null,
    dependencies: ?*anyopaque = null,
    cancellation: ?*const CancellationToken = null,
    request_timeout_ms: ?u64 = null,
    io: ?std.Io = null,

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

        pub fn deinit(self: *Result) void {
            self.arena.deinit();
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
        return decodeTypedResult(Output, try configured.runInternal(
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
        return self.runInternal(allocator, prompt, options, null, null);
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
        return decodeTypedResult(Output, try configured.runInternal(
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
        return self.runInternal(allocator, prompt, options, sink, null);
    }

    fn runInternal(
        self: Agent,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: RunOptions,
        stream_sink: ?AgentStreamSink,
        output_validator: ?OutputValidator,
    ) !Result {
        try checkCancellation(self.cancellation);
        if (stream_sink != null and !self.model.profile.supports_streaming) return Error.ModelDoesNotSupportStreaming;
        if (self.system_prompt != null and !self.model.profile.supports_system_messages) {
            return Error.ModelDoesNotSupportSystemMessages;
        }
        if (self.tools.len > 0 and !self.model.profile.supports_tools) {
            return Error.ModelDoesNotSupportTools;
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

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();

        const dependencies = options.dependencies orelse self.dependencies;
        const resolved_instructions = try resolveInstructions(memory, self.instructions, options.instructions, .{
            .dependencies = dependencies,
            .prompt = prompt,
        });
        if (resolved_instructions.len > 0 and !self.model.profile.supports_system_messages) {
            return Error.ModelDoesNotSupportSystemMessages;
        }

        var messages: std.ArrayList(Message) = .empty;
        var definitions: std.ArrayList(model_types.ToolDefinition) = .empty;
        var total_usage: model_types.Usage = .{};
        var provider_errors = ProviderErrorCapture{ .target = self.provider_error_observer };
        const tool_retries = try memory.alloc(usize, self.tools.len);
        @memset(tool_retries, 0);

        if (self.system_prompt) |system_prompt| {
            try appendTextMessage(memory, &messages, .system, system_prompt);
        }
        for (options.message_history) |message| try appendMessageCopy(memory, &messages, message);
        try appendTextMessage(memory, &messages, .user, prompt);
        for (self.tools) |tool| try definitions.append(memory, tool.definition);

        var model_requests: usize = 0;
        var output_retries: usize = 0;
        while (true) {
            var retries: usize = 0;
            const response = request: while (true) {
                try checkCancellation(self.cancellation);
                if (model_requests >= self.limits.max_model_requests) {
                    return Error.MaxModelRequestsExceeded;
                }
                model_requests += 1;
                provider_errors.reset();
                var stream_emitted = false;
                var forwarder = ModelEventForwarder{ .sink = stream_sink, .emitted = &stream_emitted };
                const model_request = model_types.ModelRequest{
                    .messages = messages.items,
                    .instructions = resolved_instructions,
                    .tools = definitions.items,
                    .output = self.output,
                    .error_observer = provider_errors.observer(),
                    .timeout_ms = self.request_timeout_ms,
                    .cancellation = self.cancellation,
                };
                break :request (if (stream_sink != null)
                    self.model.stream(memory, model_request, forwarder.modelSink())
                else
                    self.model.request(memory, model_request)) catch |err| {
                    if (err == error.RequestCancelled) return Error.Cancelled;
                    if (!stream_emitted and retries < self.retry_policy.max_retries and shouldRetry(err, self.retry_policy)) {
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
            total_usage.add(response.usage);
            try enforceUsageLimits(total_usage, self.limits);
            if (response.parts.len == 0) return Error.EmptyModelResponse;

            try messages.append(memory, .{ .role = .assistant, .parts = response.parts });

            var tool_call_count: usize = 0;
            for (response.parts) |part| switch (part) {
                .tool_call => tool_call_count += 1,
                else => {},
            };

            if (tool_call_count == 0) {
                const output = try collectText(memory, response.parts);
                validateFinalOutput(self, memory, output, output_validator) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    if (output_retries >= self.max_output_retries) return err;
                    output_retries += 1;
                    try appendTextMessage(memory, &messages, .user, "The previous response did not match the required output schema. " ++
                        "Return only valid JSON matching the schema.");
                    continue;
                };
                if (stream_sink) |sink| try sink.emit(.{ .final_output = output });
                return .{
                    .arena = arena,
                    .output = output,
                    .messages = try messages.toOwnedSlice(memory),
                    .usage = total_usage,
                    .model_requests = model_requests,
                };
            }
            if (!self.model.profile.supports_tools) return Error.ModelDoesNotSupportTools;
            if (tool_call_count > 1 and !self.model.profile.supports_parallel_tool_calls) {
                return Error.ParallelToolCallsNotSupported;
            }

            const result_parts = try memory.alloc(Part, tool_call_count);
            var result_index: usize = 0;
            for (response.parts) |part| switch (part) {
                .tool_call => |call| {
                    try checkCancellation(self.cancellation);
                    const tool_index = findToolIndex(self.tools, call.name) orelse return Error.UnknownTool;
                    const tool = self.tools[tool_index];
                    var is_error = false;
                    const content = tool.executeWithContext(memory, .{
                        .dependencies = dependencies,
                        .usage = total_usage,
                        .model_requests = model_requests,
                    }, call.arguments_json) catch |err| failure: {
                        if (!tool.isRecoverable(err)) return err;
                        const retry_limit = tool.max_retries orelse self.max_tool_retries;
                        if (tool_retries[tool_index] >= retry_limit) return err;
                        tool_retries[tool_index] += 1;
                        is_error = true;
                        break :failure try std.fmt.allocPrint(
                            memory,
                            "Tool {s} failed with {s}. Correct the arguments or approach and try again.",
                            .{ call.name, @errorName(err) },
                        );
                    };
                    result_parts[result_index] = .{ .tool_result = .{
                        .call_id = call.id,
                        .name = call.name,
                        .content = content,
                        .is_error = is_error,
                    } };
                    if (stream_sink) |sink| try sink.emit(.{ .tool_result = result_parts[result_index].tool_result });
                    result_index += 1;
                },
                else => {},
            };
            try messages.append(memory, .{ .role = .tool, .parts = result_parts });
        }
    }
};

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
    };
}

const ModelEventForwarder = struct {
    sink: ?AgentStreamSink,
    emitted: *bool,

    fn modelSink(self: *ModelEventForwarder) model_types.ModelStreamSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
        const self: *ModelEventForwarder = @ptrCast(@alignCast(context));
        self.emitted.* = true;
        try self.sink.?.emit(.{ .model = event });
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
