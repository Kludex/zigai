//! Explicit adapters for running ZigAI agents as typed graph steps.
//!
//! Node definitions and callback contexts remain borrowed by the graph. A
//! scratch arena owns prepared prompt/options data for one invocation; agent
//! results remain owned until the result adapter returns. Applications must
//! copy any output, history, or usage storage retained in the graph value.

const std = @import("std");
const agent_types = @import("agent.zig");
const durable_types = @import("durable.zig");
const graph_types = @import("graph.zig");
const message_types = @import("messages.zig");
const model_types = @import("model.zig");
const telemetry_types = @import("telemetry.zig");
const testing_types = @import("testing.zig");
const usage_types = @import("usage.zig");

const Agent = agent_types.Agent;
const CallbackError = graph_types.CallbackError;
const Message = message_types.Message;
const RunUsage = usage_types.RunUsage;

/// Prompt and invocation settings prepared for one agent node. The text and
/// every slice in `options` may use the supplied scratch arena.
pub const Prepared = struct {
    /// Borrowed prompt valid for the duration of the node invocation.
    prompt: []const u8,
    /// Borrowed run options valid for the duration of the node invocation.
    options: agent_types.RunOptions = .{},
};

/// Node-local controls layered over the borrowed agent configuration.
pub const Control = struct {
    /// Cooperative token used for this node invocation when non-null.
    cancellation: ?*const model_types.CancellationToken = null,
    /// Deadline that can only tighten agent and prepared run timeouts.
    timeout_ms: ?u64 = null,
};

/// Stable orchestration and trace identity injected into an agent run.
pub const Correlation = struct {
    /// Stable graph-run identity used by hooks, telemetry, and durable routing.
    run_id: []const u8,
    /// Parent trace inherited by this agent node when the prepared options omit one.
    telemetry_parent: ?telemetry_types.SpanContext = null,
};

/// Stage at which an agent-node invocation failed.
pub const FailurePhase = enum {
    /// Prompt or run-option preparation failed before the agent started.
    prepare,
    /// The agent run failed before producing an accepted result.
    agent,
    /// A streamed event callback failed before the graph transition committed.
    stream,
    /// The application result adapter rejected the completed agent result.
    apply,
};

/// Borrowed lifecycle observation for buffered and streaming agent nodes.
pub const Event = union(enum) {
    /// A prompt was prepared and the agent invocation is about to start.
    start: Start,
    /// One agent event was delivered successfully in provider order.
    stream: Stream,
    /// A completed agent result was successfully adapted into the graph value.
    end: End,
    /// A preparation, stream, agent, or result-adaptation phase failed.
    failure: Failure,

    pub const Start = struct {
        node_id: graph_types.NodeId,
        step_number: usize,
        prompt: []const u8,
    };

    pub const Stream = struct {
        node_id: graph_types.NodeId,
        step_number: usize,
        event: agent_types.AgentStreamEvent,
    };

    pub const End = struct {
        node_id: graph_types.NodeId,
        step_number: usize,
        output_json: []const u8,
        messages: []const Message,
        usage: RunUsage,
        model_requests: usize,
    };

    pub const Failure = struct {
        node_id: graph_types.NodeId,
        step_number: usize,
        phase: FailurePhase,
        failure_name: []const u8,
    };
};

/// Infallible borrowed observer. Copy event slices before retaining them.
pub const Observer = struct {
    /// Borrowed observer state.
    context: ?*anyopaque = null,
    /// Receives synchronous events whose nested slices are borrowed.
    event_fn: *const fn (context: ?*anyopaque, event: Event) void,

    pub fn emit(self: Observer, event: Event) void {
        self.event_fn(self.context, event);
    }
};

/// Fallible synchronous stream delivery. Event storage is borrowed for the
/// callback only. A failure aborts the node before result adaptation.
pub const StreamSink = struct {
    /// Borrowed stream consumer state.
    context: ?*anyopaque = null,
    /// Receives agent events in provider and tool-loop order.
    event_fn: *const fn (
        context: ?*anyopaque,
        event: agent_types.AgentStreamEvent,
    ) CallbackError!void,

    pub fn emit(self: StreamSink, event: agent_types.AgentStreamEvent) CallbackError!void {
        return self.event_fn(self.context, event);
    }
};

const StreamRelay = struct {
    node_id: graph_types.NodeId,
    step_number: usize,
    sink: StreamSink,
    observer: ?Observer,
    failure: ?CallbackError = null,

    fn agentSink(self: *StreamRelay) agent_types.AgentStreamSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, event: agent_types.AgentStreamEvent) !void {
        const self: *StreamRelay = @ptrCast(@alignCast(context));
        self.sink.emit(event) catch |failure| {
            self.failure = failure;
            return failure;
        };
        if (self.observer) |observer| observer.emit(.{ .stream = .{
            .node_id = self.node_id,
            .step_number = self.step_number,
            .event = event,
        } });
    }
};

/// Owned canonical history and cumulative usage for propagation between agent
/// nodes. All nested strings and detail names live in one arena.
pub const Conversation = struct {
    /// Owns `messages`, usage details, and every nested borrowed slice.
    arena: std.heap.ArenaAllocator,
    /// Canonical history copied into `arena`.
    messages: []const Message,
    /// Cumulative usage copied into `arena`.
    usage: RunUsage,

    pub fn init(
        gpa: std.mem.Allocator,
        messages: []const Message,
        usage: RunUsage,
    ) std.mem.Allocator.Error!Conversation {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const messages_copy = try message_types.dupeMessages(arena.allocator(), messages);
        const usage_copy = try usage.dupe(arena.allocator());
        return .{
            .arena = arena,
            .messages = messages_copy,
            .usage = usage_copy,
        };
    }

    pub fn deinit(self: *Conversation) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Replaces the complete conversation atomically after copying succeeds.
    pub fn replace(
        self: *Conversation,
        gpa: std.mem.Allocator,
        messages: []const Message,
        usage: RunUsage,
    ) std.mem.Allocator.Error!void {
        const next = try init(gpa, messages, usage);
        self.deinit();
        self.* = next;
    }

    /// Replaces history while adding one node's usage to the existing total.
    pub fn appendRun(
        self: *Conversation,
        gpa: std.mem.Allocator,
        messages: []const Message,
        usage: RunUsage,
    ) (std.mem.Allocator.Error || error{UsageOverflow})!void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var cumulative = try self.usage.dupe(scratch.allocator());
        try cumulative.addRun(scratch.allocator(), usage);
        try self.replace(gpa, messages, cumulative);
    }
};

fn configureAgent(agent: *const Agent, control: Control, graph_io: ?std.Io) Agent {
    var configured = agent.*;
    if (configured.io == null) configured.io = graph_io;
    if (control.cancellation) |cancellation| configured.cancellation = cancellation;
    return configured;
}

fn configureOptions(
    arena: std.mem.Allocator,
    options: *agent_types.RunOptions,
    control: Control,
    correlation: ?Correlation,
    node_id: graph_types.NodeId,
    node_name: []const u8,
    step_number: usize,
) CallbackError!void {
    if (control.timeout_ms) |timeout| {
        options.timeout_ms = if (options.timeout_ms) |prepared| @min(prepared, timeout) else timeout;
    }

    const durable_run_id = if (options.durable) |binding| binding.run_id else null;
    if (correlation) |configured| {
        if (durable_run_id) |run_id| {
            if (!std.mem.eql(u8, configured.run_id, run_id)) return error.StepFailed;
        }
        if (options.telemetry_parent == null) options.telemetry_parent = configured.telemetry_parent;
    }
    const run_id = if (correlation) |configured| configured.run_id else durable_run_id;
    if (run_id) |id| {
        const node_id_text = std.fmt.allocPrint(arena, "{d}", .{node_id.index}) catch return error.OutOfMemory;
        options.correlation = .{
            .run_id = id,
            .node_id = node_id_text,
            .node_name = node_name,
        };
        if (options.request_id == null) {
            options.request_id = std.fmt.allocPrint(arena, "{s}.{s}.{d}", .{
                id,
                node_id_text,
                step_number,
            }) catch return error.OutOfMemory;
        }
    }
    if (options.durable) |*binding| {
        const local_namespace = std.fmt.allocPrint(arena, "graph.{d}.step.{d}", .{
            node_id.index,
            step_number,
        }) catch return error.OutOfMemory;
        binding.step_namespace = if (binding.step_namespace) |parent|
            std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, local_namespace }) catch return error.OutOfMemory
        else
            local_namespace;
    }
}

/// Returns a buffered agent step whose application value remains fully typed.
/// `Workflow` must be a type produced by `graph.Graph`.
pub fn BufferedNode(comptime Workflow: type) type {
    const Value = Workflow.ValueType;
    return struct {
        const Self = @This();

        agent: *const Agent,
        context: ?*anyopaque = null,
        control: Control = .{},
        correlation: ?Correlation = null,
        stream_sink: ?StreamSink = null,
        prepare_fn: *const fn (
            context: ?*anyopaque,
            arena: std.mem.Allocator,
            run: *Workflow.Context,
            input: *const Value,
        ) CallbackError!Prepared,
        apply_fn: *const fn (
            context: ?*anyopaque,
            gpa: std.mem.Allocator,
            run: *Workflow.Context,
            input: Value,
            result: *const Agent.Result,
        ) CallbackError!Value,
        observer: ?Observer = null,

        /// Creates a borrowed graph-step definition. `self`, the agent, and
        /// callback contexts must outlive the built graph.
        pub fn step(
            self: *Self,
            name: []const u8,
            metadata: graph_types.NodeMetadata,
        ) Workflow.Step {
            return .{
                .name = name,
                .metadata = metadata,
                .context = self,
                .run_fn = run,
            };
        }

        fn run(
            context: ?*anyopaque,
            graph_run: *Workflow.Context,
            input: Value,
        ) CallbackError!Value {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const node_id = graph_run.node_id.?;
            var scratch = std.heap.ArenaAllocator.init(graph_run.gpa);
            defer scratch.deinit();
            var prepared = self.prepare_fn(
                self.context,
                scratch.allocator(),
                graph_run,
                &input,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .prepare, failure);
                return failure;
            };
            if (prepared.options.dependencies == null)
                prepared.options.dependencies = graph_run.deps;
            configureOptions(
                scratch.allocator(),
                &prepared.options,
                self.control,
                self.correlation,
                node_id,
                graph_run.node_name.?,
                graph_run.step_number,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .prepare, failure);
                return failure;
            };
            self.emit(.{ .start = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .prompt = prepared.prompt,
            } });
            const configured_agent = configureAgent(self.agent, self.control, graph_run.io);
            var relay: StreamRelay = undefined;
            if (self.stream_sink) |stream_sink| relay = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .sink = stream_sink,
                .observer = self.observer,
            };
            var result = (if (self.stream_sink != null)
                configured_agent.runStreamWithOptions(
                    graph_run.gpa,
                    prepared.prompt,
                    prepared.options,
                    relay.agentSink(),
                )
            else
                configured_agent.runWithOptions(
                    graph_run.gpa,
                    prepared.prompt,
                    prepared.options,
                )) catch |failure| {
                if (self.stream_sink != null and relay.failure != null) {
                    self.emitFailure(node_id, graph_run.step_number, .stream, relay.failure.?);
                    return relay.failure.?;
                }
                self.emitFailure(node_id, graph_run.step_number, .agent, failure);
                return normalizeAgentFailure(failure);
            };
            defer result.deinit();
            const output = self.apply_fn(
                self.context,
                graph_run.gpa,
                graph_run,
                input,
                &result,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .apply, failure);
                return failure;
            };
            self.emit(.{ .end = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .output_json = result.output,
                .messages = result.messages,
                .usage = result.usage,
                .model_requests = result.model_requests,
            } });
            return output;
        }

        fn emit(self: Self, event: Event) void {
            if (self.observer) |observer| observer.emit(event);
        }

        fn emitFailure(
            self: Self,
            node_id: graph_types.NodeId,
            step_number: usize,
            phase: FailurePhase,
            failure: anyerror,
        ) void {
            self.emit(.{ .failure = .{
                .node_id = node_id,
                .step_number = step_number,
                .phase = phase,
                .failure_name = @errorName(failure),
            } });
        }
    };
}

/// Returns a JSON-Schema-backed typed agent step. The typed result is borrowed
/// only for `apply_fn`; copy nested data into `gpa` before returning it.
pub fn TypedNode(comptime Workflow: type, comptime AgentOutput: type) type {
    const Value = Workflow.ValueType;
    const TypedResult = agent_types.TypedResult(AgentOutput);
    return struct {
        const Self = @This();

        agent: *const Agent,
        context: ?*anyopaque = null,
        control: Control = .{},
        correlation: ?Correlation = null,
        stream_sink: ?StreamSink = null,
        prepare_fn: *const fn (
            context: ?*anyopaque,
            arena: std.mem.Allocator,
            run: *Workflow.Context,
            input: *const Value,
        ) CallbackError!Prepared,
        apply_fn: *const fn (
            context: ?*anyopaque,
            gpa: std.mem.Allocator,
            run: *Workflow.Context,
            input: Value,
            result: *const TypedResult,
        ) CallbackError!Value,
        observer: ?Observer = null,

        pub fn step(
            self: *Self,
            name: []const u8,
            metadata: graph_types.NodeMetadata,
        ) Workflow.Step {
            return .{
                .name = name,
                .metadata = metadata,
                .context = self,
                .run_fn = run,
            };
        }

        fn run(
            context: ?*anyopaque,
            graph_run: *Workflow.Context,
            input: Value,
        ) CallbackError!Value {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const node_id = graph_run.node_id.?;
            var scratch = std.heap.ArenaAllocator.init(graph_run.gpa);
            defer scratch.deinit();
            var prepared = self.prepare_fn(
                self.context,
                scratch.allocator(),
                graph_run,
                &input,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .prepare, failure);
                return failure;
            };
            if (prepared.options.dependencies == null)
                prepared.options.dependencies = graph_run.deps;
            configureOptions(
                scratch.allocator(),
                &prepared.options,
                self.control,
                self.correlation,
                node_id,
                graph_run.node_name.?,
                graph_run.step_number,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .prepare, failure);
                return failure;
            };
            self.emit(.{ .start = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .prompt = prepared.prompt,
            } });
            const configured_agent = configureAgent(self.agent, self.control, graph_run.io);
            var relay: StreamRelay = undefined;
            if (self.stream_sink) |stream_sink| relay = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .sink = stream_sink,
                .observer = self.observer,
            };
            var result = (if (self.stream_sink != null)
                configured_agent.runTypedStreamWithOptions(
                    AgentOutput,
                    graph_run.gpa,
                    prepared.prompt,
                    prepared.options,
                    relay.agentSink(),
                )
            else
                configured_agent.runTypedWithOptions(
                    AgentOutput,
                    graph_run.gpa,
                    prepared.prompt,
                    prepared.options,
                )) catch |failure| {
                if (self.stream_sink != null and relay.failure != null) {
                    self.emitFailure(node_id, graph_run.step_number, .stream, relay.failure.?);
                    return relay.failure.?;
                }
                self.emitFailure(node_id, graph_run.step_number, .agent, failure);
                return normalizeAgentFailure(failure);
            };
            defer result.deinit();
            const output = self.apply_fn(
                self.context,
                graph_run.gpa,
                graph_run,
                input,
                &result,
            ) catch |failure| {
                self.emitFailure(node_id, graph_run.step_number, .apply, failure);
                return failure;
            };
            self.emit(.{ .end = .{
                .node_id = node_id,
                .step_number = graph_run.step_number,
                .output_json = result.output_json,
                .messages = result.messages,
                .usage = result.usage,
                .model_requests = result.model_requests,
            } });
            return output;
        }

        fn emit(self: Self, event: Event) void {
            if (self.observer) |observer| observer.emit(event);
        }

        fn emitFailure(
            self: Self,
            node_id: graph_types.NodeId,
            step_number: usize,
            phase: FailurePhase,
            failure: anyerror,
        ) void {
            self.emit(.{ .failure = .{
                .node_id = node_id,
                .step_number = step_number,
                .phase = phase,
                .failure_name = @errorName(failure),
            } });
        }
    };
}

fn normalizeAgentFailure(failure: anyerror) CallbackError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => error.StepFailed,
    };
}

test "buffered agent nodes propagate canonical history usage dependencies and events" {
    const Value = struct {
        prompt: []const u8,
        output: ?[]u8 = null,
    };
    const State = struct { conversation: ?Conversation = null };
    const Deps = struct { marker: u8 };
    const Workflow = graph_types.Graph(State, Deps, Value, Value, Value);
    const Capture = struct {
        tags: [6]std.meta.Tag(Event) = undefined,
        count: usize = 0,
        end_tokens: u64 = 0,

        fn observe(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.tags[self.count] = std.meta.activeTag(event);
            self.count += 1;
            if (event == .end) self.end_tokens = event.end.usage.totalTokens();
        }
    };
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: Value) CallbackError!Value {
            return input;
        }

        fn end(_: ?*anyopaque, _: *Workflow.Context, input: Value) CallbackError!Value {
            return input;
        }

        fn prepare(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            run: *Workflow.Context,
            input: *const Value,
        ) CallbackError!Prepared {
            if (run.deps.marker != 9) return error.StepFailed;
            return .{
                .prompt = std.fmt.allocPrint(arena, "{s}:{d}", .{
                    input.prompt,
                    run.step_number,
                }) catch return error.OutOfMemory,
                .options = .{
                    .message_history = if (run.state.conversation) |conversation|
                        conversation.messages
                    else
                        &.{},
                },
            };
        }

        fn apply(
            _: ?*anyopaque,
            gpa: std.mem.Allocator,
            run: *Workflow.Context,
            input: Value,
            result: *const Agent.Result,
        ) CallbackError!Value {
            const output = gpa.dupe(u8, result.output) catch return error.OutOfMemory;
            errdefer gpa.free(output);
            if (run.state.conversation) |*conversation| {
                conversation.appendRun(gpa, result.messages, result.usage) catch |failure| return switch (failure) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.StepFailed,
                };
            } else {
                run.state.conversation = Conversation.init(gpa, result.messages, result.usage) catch
                    return error.OutOfMemory;
            }
            if (input.output) |previous| gpa.free(previous);
            return .{ .prompt = input.prompt, .output = output };
        }
    };
    const Inspector = struct {
        fn inspect(index: usize, request: model_types.ModelRequest) !void {
            const expected_messages: usize = switch (index) {
                0 => 1,
                1 => 3,
                else => 5,
            };
            try std.testing.expectEqual(expected_messages, request.messages.len);
            try std.testing.expectEqualStrings(
                if (index == 1) "question:2" else "question:1",
                request.messages[request.messages.len - 1].request.parts[0].user_prompt.text,
            );
        }
    };
    const first_parts = [_]model_types.Part{.{ .text = "first" }};
    const second_parts = [_]model_types.Part{.{ .text = "second" }};
    const third_parts = [_]model_types.Part{.{ .text = "third" }};
    var scripted = testing_types.ScriptedModel{
        .responses = &.{
            .{ .parts = &first_parts, .usage = .{ .input_tokens = 2, .output_tokens = 3 } },
            .{ .parts = &second_parts, .usage = .{ .input_tokens = 5, .output_tokens = 7 } },
            .{ .parts = &third_parts },
        },
        .inspectFn = Inspector.inspect,
    };
    const agent = Agent{ .model = scripted.model() };
    var capture: Capture = .{};
    var first_node = BufferedNode(Workflow){
        .agent = &agent,
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
        .observer = .{ .context = &capture, .event_fn = Capture.observe },
    };
    var second_node = first_node;
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const first = try builder.addStep(std.testing.allocator, first_node.step("first-agent", .{
        .label = "First agent",
    }));
    const second = try builder.addStep(std.testing.allocator, second_node.step("second-agent", .{}));
    try builder.setEntry(first);
    try builder.connect(std.testing.allocator, first, second);
    try builder.finish(std.testing.allocator, second);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var state: State = .{};
    defer if (state.conversation) |*conversation| conversation.deinit();
    var deps = Deps{ .marker = 9 };
    const output = try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        .{ .prompt = "question" },
        .{},
    );
    defer if (output.output) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("second", output.output.?);
    try std.testing.expectEqual(@as(usize, 4), state.conversation.?.messages.len);
    try std.testing.expectEqual(@as(u64, 17), state.conversation.?.usage.totalTokens());
    try std.testing.expectEqual(@as(usize, 2), state.conversation.?.usage.requests);
    try std.testing.expectEqual(@as(usize, 4), capture.count);
    try std.testing.expectEqual(std.meta.Tag(Event).start, capture.tags[0]);
    try std.testing.expectEqual(std.meta.Tag(Event).end, capture.tags[3]);
    try std.testing.expectEqual(@as(u64, 12), capture.end_tokens);

    state.conversation.?.usage.requests = std.math.maxInt(usize);
    try std.testing.expectError(error.StepFailed, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        .{ .prompt = "question" },
        .{},
    ));
}

test "typed agent nodes decode application output before adapting the graph value" {
    const Answer = struct { value: u32 };
    const Workflow = graph_types.Graph(u8, u8, u32, u32, u32);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u32) CallbackError!u32 {
            return input;
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u32) CallbackError!u32 {
            return input;
        }
        fn prepare(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            _: *Workflow.Context,
            input: *const u32,
        ) CallbackError!Prepared {
            return .{
                .prompt = std.fmt.allocPrint(arena, "answer {d}", .{input.*}) catch
                    return error.OutOfMemory,
            };
        }
        fn apply(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            input: u32,
            result: *const agent_types.TypedResult(Answer),
        ) CallbackError!u32 {
            return input + result.output.value;
        }
    };
    const parts = [_]model_types.Part{.{ .text = "{\"value\":7}" }};
    var scripted = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    const agent = Agent{ .model = scripted.model() };
    var node = TypedNode(Workflow, Answer){
        .agent = &agent,
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const typed = try builder.addStep(std.testing.allocator, node.step("typed-agent", .{}));
    try builder.setEntry(typed);
    try builder.finish(std.testing.allocator, typed);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var state: u8 = 0;
    var deps: u8 = 0;
    try std.testing.expectEqual(@as(u32, 12), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        5,
        .{},
    ));
}

test "typed agent nodes report prepare agent and apply failures" {
    const Answer = struct { value: u8 };
    const Workflow = graph_types.Graph(u8, u8, u8, u8, u8);
    const Capture = struct {
        phase: ?FailurePhase = null,

        fn observe(context: ?*anyopaque, event: Event) void {
            if (event != .failure) return;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.phase = event.failure.phase;
        }

        fn rejectStream(_: ?*anyopaque, _: agent_types.AgentStreamEvent) CallbackError!void {
            return error.StepFailed;
        }

        fn acceptStream(_: ?*anyopaque, _: agent_types.AgentStreamEvent) CallbackError!void {}
    };
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepareFailure(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return error.StepFailed;
        }
        fn prepare(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = "prompt" };
        }
        fn apply(
            context: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            input: u8,
            _: *const agent_types.TypedResult(Answer),
        ) CallbackError!u8 {
            if (context != null) return error.StepFailed;
            return input;
        }
    };
    const Support = struct {
        fn runNode(node: *TypedNode(Workflow, Answer), capture: *Capture) !u8 {
            node.observer = .{ .context = capture, .event_fn = Capture.observe };
            var builder: Workflow.Builder = .{};
            defer builder.deinit(std.testing.allocator);
            try builder.setStart(.{ .run_fn = Callbacks.boundary });
            try builder.setEnd(.{ .run_fn = Callbacks.boundary });
            const id = try builder.addStep(std.testing.allocator, node.step("typed-agent", .{}));
            try builder.setEntry(id);
            try builder.finish(std.testing.allocator, id);
            var graph = try builder.build(std.testing.allocator);
            defer graph.deinit(std.testing.allocator);
            var state: u8 = 0;
            var deps: u8 = 0;
            return graph.run(std.testing.allocator, &state, &deps, 0, .{});
        }
    };

    var empty_script = testing_types.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_json_schema_output = true },
    };
    const empty_agent = Agent{ .model = empty_script.model() };
    var capture: Capture = .{};
    var node = TypedNode(Workflow, Answer){
        .agent = &empty_agent,
        .prepare_fn = Callbacks.prepareFailure,
        .apply_fn = Callbacks.apply,
    };
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.prepare, capture.phase.?);

    capture = .{};
    node.prepare_fn = Callbacks.prepare;
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.agent, capture.phase.?);

    const parts = [_]model_types.Part{.{ .text = "{\"value\":1}" }};
    var success_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    const success_agent = Agent{ .model = success_script.model() };
    capture = .{};
    node.agent = &success_agent;
    node.context = &capture;
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.apply, capture.phase.?);

    var stream_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true, .supports_streaming = true },
    };
    const stream_agent = Agent{ .model = stream_script.model() };
    capture = .{};
    node.agent = &stream_agent;
    node.context = null;
    node.stream_sink = .{ .event_fn = Capture.rejectStream };
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.stream, capture.phase.?);

    var final_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true, .supports_streaming = true },
    };
    const final_agent = Agent{ .model = final_script.model() };
    node.agent = &final_agent;
    node.context = null;
    node.stream_sink = .{ .event_fn = Capture.acceptStream };
    try std.testing.expectEqual(@as(u8, 0), try Support.runNode(&node, &capture));
}

test "streaming agent nodes deliver ordered events and abort before transition on sink failure" {
    const State = struct { applied: usize = 0 };
    const Workflow = graph_types.Graph(State, u8, u8, u8, u8);
    const Capture = struct {
        stream_count: usize = 0,
        observed_count: usize = 0,
        final_seen: bool = false,
        fail_stream: bool = false,
        failure_phase: ?FailurePhase = null,

        fn stream(context: ?*anyopaque, event: agent_types.AgentStreamEvent) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.fail_stream) return error.StepFailed;
            self.stream_count += 1;
            if (event == .final_result) self.final_seen = true;
        }

        fn observe(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .stream => self.observed_count += 1,
                .failure => |failure| self.failure_phase = failure.phase,
                else => {},
            }
        }
    };
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepare(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = "prompt" };
        }
        fn apply(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            run: *Workflow.Context,
            input: u8,
            _: *const Agent.Result,
        ) CallbackError!u8 {
            run.state.applied += 1;
            return input + 1;
        }
    };
    const Support = struct {
        fn runNode(node: *BufferedNode(Workflow), state: *State) !u8 {
            var builder: Workflow.Builder = .{};
            defer builder.deinit(std.testing.allocator);
            try builder.setStart(.{ .run_fn = Callbacks.boundary });
            try builder.setEnd(.{ .run_fn = Callbacks.boundary });
            const id = try builder.addStep(std.testing.allocator, node.step("stream-agent", .{}));
            try builder.setEntry(id);
            try builder.finish(std.testing.allocator, id);
            var graph = try builder.build(std.testing.allocator);
            defer graph.deinit(std.testing.allocator);
            var deps: u8 = 0;
            return graph.run(std.testing.allocator, state, &deps, 0, .{});
        }
    };

    const parts = [_]model_types.Part{.{ .text = "streamed" }};
    var success_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_streaming = true },
    };
    const success_agent = Agent{ .model = success_script.model() };
    var capture: Capture = .{};
    var node = BufferedNode(Workflow){
        .agent = &success_agent,
        .stream_sink = .{ .context = &capture, .event_fn = Capture.stream },
        .observer = .{ .context = &capture, .event_fn = Capture.observe },
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    var state: State = .{};
    try std.testing.expectEqual(@as(u8, 1), try Support.runNode(&node, &state));
    try std.testing.expect(capture.final_seen);
    try std.testing.expectEqual(capture.stream_count, capture.observed_count);
    try std.testing.expectEqual(@as(usize, 1), state.applied);

    var failure_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_streaming = true },
    };
    const failure_agent = Agent{ .model = failure_script.model() };
    capture = .{ .fail_stream = true };
    node.agent = &failure_agent;
    node.stream_sink = .{ .context = &capture, .event_fn = Capture.stream };
    node.observer = .{ .context = &capture, .event_fn = Capture.observe };
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &state));
    try std.testing.expectEqual(FailurePhase.stream, capture.failure_phase.?);
    try std.testing.expectEqual(@as(usize, 1), state.applied);
}

test "agent nodes namespace durable operations and expose stable graph correlation" {
    const Workflow = graph_types.Graph(u8, u8, u8, u8, u8);
    const Capture = struct {
        operation_count: usize = 0,
        hook_count: usize = 0,

        fn execute(
            context: *anyopaque,
            gpa: std.mem.Allocator,
            invocation: durable_types.Invocation,
        ) !durable_types.OwnedRecord {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("workflow-run", invocation.run_id);
            const expected_node = self.operation_count % 2;
            const expected_step = if (expected_node == 0)
                "workflow.graph.0.step.1.model.request"
            else
                "workflow.graph.1.step.2.model.request";
            try std.testing.expectEqualStrings(expected_step, invocation.step_id);
            try std.testing.expectEqual(@as(u64, 1), invocation.sequence);
            self.operation_count += 1;
            const output_json = try durable_types.payloads.model.stringifyResponse(gpa, .{
                .parts = &.{.{ .text = "durable" }},
                .usage = .{},
                .provider_name = "durable",
            });
            defer gpa.free(output_json);
            return durable_types.OwnedRecord.copy(
                gpa,
                durable_types.Record.init(invocation, .{ .success = output_json }),
            );
        }

        fn localModel(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: model_types.ModelRequest,
        ) !model_types.ModelResponse {
            return error.LocalModelMustNotRun;
        }

        fn hook(context: *anyopaque, event: agent_types.LifecycleEvent) !void {
            if (event != .run_start) return;
            const self: *@This() = @ptrCast(@alignCast(context));
            const correlation = event.run_start.correlation.?;
            const expected_node = self.hook_count % 2;
            try std.testing.expectEqualStrings("workflow-run", correlation.run_id);
            try std.testing.expectEqualStrings(if (expected_node == 0) "0" else "1", correlation.node_id);
            try std.testing.expectEqualStrings(
                if (expected_node == 0) "first-agent" else "second-agent",
                correlation.node_name,
            );
            self.hook_count += 1;
        }
    };
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepare(
            context: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            const binding: *const durable_types.Binding = @ptrCast(@alignCast(context.?));
            return .{ .prompt = "prompt", .options = .{ .durable = binding.* } };
        }
        fn apply(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            input: u8,
            result: *const Agent.Result,
        ) CallbackError!u8 {
            if (!std.mem.eql(u8, result.output, "durable")) return error.StepFailed;
            return input + 1;
        }
    };

    var capture: Capture = .{};
    const binding = durable_types.Binding{
        .runtime = .{ .context = &capture, .executeFn = Capture.execute },
        .run_id = "workflow-run",
        .handlers = .{ .model_request = "model-worker" },
        .step_namespace = "workflow",
    };
    const hooks = [_]agent_types.LifecycleHook{.{ .context = &capture, .eventFn = Capture.hook }};
    const agent = Agent{
        .model = .{ .context = &capture, .profile = .{}, .requestFn = Capture.localModel },
        .hooks = &hooks,
    };
    var first_node = BufferedNode(Workflow){
        .agent = &agent,
        .context = @constCast(&binding),
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    var second_node = first_node;
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.boundary });
    try builder.setEnd(.{ .run_fn = Callbacks.boundary });
    const first = try builder.addStep(std.testing.allocator, first_node.step("first-agent", .{}));
    const second = try builder.addStep(std.testing.allocator, second_node.step("second-agent", .{}));
    try builder.setEntry(first);
    try builder.connect(std.testing.allocator, first, second);
    try builder.finish(std.testing.allocator, second);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var state: u8 = 0;
    var deps: u8 = 0;
    try std.testing.expectEqual(@as(u8, 2), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{},
    ));
    try std.testing.expectEqual(@as(u8, 2), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 4), capture.operation_count);
    try std.testing.expectEqual(@as(usize, 4), capture.hook_count);

    first_node.correlation = .{ .run_id = "different-run" };
    var mismatch_builder: Workflow.Builder = .{};
    defer mismatch_builder.deinit(std.testing.allocator);
    try mismatch_builder.setStart(.{ .run_fn = Callbacks.boundary });
    try mismatch_builder.setEnd(.{ .run_fn = Callbacks.boundary });
    const mismatch = try mismatch_builder.addStep(
        std.testing.allocator,
        first_node.step("mismatch", .{}),
    );
    try mismatch_builder.setEntry(mismatch);
    try mismatch_builder.finish(std.testing.allocator, mismatch);
    var mismatch_graph = try mismatch_builder.build(std.testing.allocator);
    defer mismatch_graph.deinit(std.testing.allocator);
    try std.testing.expectError(error.StepFailed, mismatch_graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 4), capture.operation_count);
}

test "agent node controls cancel before side effects and require IO for deadlines" {
    const Workflow = graph_types.Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepare(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = "prompt", .options = .{ .timeout_ms = 5 } };
        }
        fn apply(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            input: u8,
            _: *const Agent.Result,
        ) CallbackError!u8 {
            return input;
        }
    };
    const Support = struct {
        fn runNode(node: *BufferedNode(Workflow), io: ?std.Io) !u8 {
            var builder: Workflow.Builder = .{};
            defer builder.deinit(std.testing.allocator);
            try builder.setStart(.{ .run_fn = Callbacks.boundary });
            try builder.setEnd(.{ .run_fn = Callbacks.boundary });
            const id = try builder.addStep(std.testing.allocator, node.step("controlled-agent", .{}));
            try builder.setEntry(id);
            try builder.finish(std.testing.allocator, id);
            var graph = try builder.build(std.testing.allocator);
            defer graph.deinit(std.testing.allocator);
            var state: u8 = 0;
            var deps: u8 = 0;
            return graph.run(std.testing.allocator, &state, &deps, 0, .{ .io = io });
        }
    };

    const parts = [_]model_types.Part{.{ .text = "unused" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    var cancellation: model_types.CancellationToken = .{};
    cancellation.cancel();
    var node = BufferedNode(Workflow){
        .agent = &agent,
        .control = .{ .cancellation = &cancellation },
        .correlation = .{
            .run_id = "controlled-run",
            .telemetry_parent = .{
                .trace_id = [_]u8{1} ** 16,
                .span_id = [_]u8{2} ** 8,
            },
        },
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    try std.testing.expectError(error.Cancelled, Support.runNode(&node, std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), scripted.request_count);

    node.control = .{ .timeout_ms = 1 };
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, null));
    try std.testing.expectEqual(@as(usize, 0), scripted.request_count);

    const SlowModel = struct {
        io: std.Io,
        active: std.atomic.Value(bool) = .init(false),

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: model_types.ModelRequest,
        ) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            while (true) try (std.Io.Timeout{ .duration = .{
                .raw = .fromSeconds(10),
                .clock = .awake,
            } }).sleep(self.io);
        }
    };
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var slow = SlowModel{ .io = runtime.io() };
    const slow_agent = Agent{ .model = .{
        .context = &slow,
        .profile = .{},
        .requestFn = SlowModel.request,
    } };
    node.agent = &slow_agent;
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, runtime.io()));
    try std.testing.expect(!slow.active.load(.seq_cst));
}

test "agent node failures retain their phase and stable graph error" {
    const Workflow = graph_types.Graph(u8, u8, u8, u8, u8);
    const Capture = struct {
        phase: ?FailurePhase = null,
        failure_name: ?[]const u8 = null,

        fn observe(context: ?*anyopaque, event: Event) void {
            if (event != .failure) return;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.phase = event.failure.phase;
            self.failure_name = event.failure.failure_name;
        }
    };
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepareFailure(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return error.StepFailed;
        }
        fn prepare(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = "prompt" };
        }
        fn apply(
            context: ?*anyopaque,
            _: std.mem.Allocator,
            _: *Workflow.Context,
            input: u8,
            _: *const Agent.Result,
        ) CallbackError!u8 {
            if (context != null) return error.StepFailed;
            return input;
        }
    };
    const Support = struct {
        fn runNode(node: *BufferedNode(Workflow), capture: *Capture) !u8 {
            node.observer = .{ .context = capture, .event_fn = Capture.observe };
            var builder: Workflow.Builder = .{};
            defer builder.deinit(std.testing.allocator);
            try builder.setStart(.{ .run_fn = Callbacks.boundary });
            try builder.setEnd(.{ .run_fn = Callbacks.boundary });
            const id = try builder.addStep(std.testing.allocator, node.step("agent", .{}));
            try builder.setEntry(id);
            try builder.finish(std.testing.allocator, id);
            var graph = try builder.build(std.testing.allocator);
            defer graph.deinit(std.testing.allocator);
            var state: u8 = 0;
            var deps: u8 = 0;
            return graph.run(std.testing.allocator, &state, &deps, 0, .{});
        }
    };

    var empty_script = testing_types.ScriptedModel{ .responses = &.{} };
    const empty_agent = Agent{ .model = empty_script.model() };
    var capture: Capture = .{};
    var node = BufferedNode(Workflow){
        .agent = &empty_agent,
        .prepare_fn = Callbacks.prepareFailure,
        .apply_fn = Callbacks.apply,
    };
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.prepare, capture.phase.?);

    capture = .{};
    node.prepare_fn = Callbacks.prepare;
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.agent, capture.phase.?);
    try std.testing.expectEqualStrings("ScriptExhausted", capture.failure_name.?);

    const parts = [_]model_types.Part{.{ .text = "ok" }};
    var success_script = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const success_agent = Agent{ .model = success_script.model() };
    capture = .{};
    node.agent = &success_agent;
    node.context = &capture;
    try std.testing.expectError(error.StepFailed, Support.runNode(&node, &capture));
    try std.testing.expectEqual(FailurePhase.apply, capture.phase.?);

    var cancellation: model_types.CancellationToken = .{};
    cancellation.cancel();
    const cancelled_agent = Agent{ .model = success_script.model(), .cancellation = &cancellation };
    capture = .{};
    node.agent = &cancelled_agent;
    node.context = null;
    try std.testing.expectError(error.Cancelled, Support.runNode(&node, &capture));
    try std.testing.expectEqualStrings("Cancelled", capture.failure_name.?);

    var final_script = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const final_agent = Agent{ .model = final_script.model() };
    capture = .{};
    node.agent = &final_agent;
    try std.testing.expectEqual(@as(u8, 0), try Support.runNode(&node, &capture));
}

fn copyConversationWithAllocator(gpa: std.mem.Allocator) !void {
    const messages = [_]Message{
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "prompt" } }} } },
        .{ .response = .{ .parts = &.{.{ .text = "answer" }} } },
    };
    var conversation = try Conversation.init(gpa, &messages, .{
        .details = &.{.{ .name = "accepted_tokens", .value = 1 }},
    });
    defer conversation.deinit();
    try std.testing.expectEqualStrings("prompt", conversation.messages[0].request.parts[0].user_prompt.text);
}

test "conversation ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        copyConversationWithAllocator,
        .{},
    );
}

test "buffered agent nodes release adapted output when usage propagation fails" {
    const State = struct { conversation: Conversation };
    const Workflow = graph_types.Graph(State, u8, u8, u8, u8);
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn prepare(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            run: *Workflow.Context,
            _: *const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = "prompt", .options = .{
                .message_history = run.state.conversation.messages,
            } };
        }
        fn apply(
            _: ?*anyopaque,
            gpa: std.mem.Allocator,
            run: *Workflow.Context,
            input: u8,
            result: *const Agent.Result,
        ) CallbackError!u8 {
            const output = gpa.dupe(u8, result.output) catch return error.OutOfMemory;
            errdefer gpa.free(output);
            run.state.conversation.appendRun(gpa, result.messages, result.usage) catch |failure| return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.UsageOverflow => error.StepFailed,
            };
            gpa.free(output);
            return input;
        }
    };
    const parts = [_]model_types.Part{.{ .text = "answer" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{
        .{ .parts = &parts },
        .{ .parts = &parts },
    } };
    const agent = Agent{ .model = scripted.model() };
    var node = BufferedNode(Workflow){
        .agent = &agent,
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.boundary });
    try builder.setEnd(.{ .run_fn = Callbacks.boundary });
    const id = try builder.addStep(std.testing.allocator, node.step("agent", .{}));
    try builder.setEntry(id);
    try builder.finish(std.testing.allocator, id);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var state = State{ .conversation = try Conversation.init(std.testing.allocator, &.{}, .{
        .requests = std.math.maxInt(usize),
    }) };
    defer state.conversation.deinit();
    var deps: u8 = 0;
    try std.testing.expectError(
        error.StepFailed,
        graph.run(std.testing.allocator, &state, &deps, 0, .{}),
    );
    state.conversation.usage.requests = 0;
    try std.testing.expectEqual(
        @as(u8, 0),
        try graph.run(std.testing.allocator, &state, &deps, 0, .{}),
    );
}

fn runBufferedNodeWithAllocator(gpa: std.mem.Allocator) !void {
    const Workflow = graph_types.Graph(u8, u8, []const u8, []const u8, []const u8);
    const Callbacks = struct {
        fn boundary(_: ?*anyopaque, _: *Workflow.Context, input: []const u8) CallbackError![]const u8 {
            return input;
        }
        fn prepare(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            _: *Workflow.Context,
            input: *const []const u8,
        ) CallbackError!Prepared {
            return .{ .prompt = arena.dupe(u8, input.*) catch return error.OutOfMemory };
        }
        fn apply(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: *Workflow.Context,
            _: []const u8,
            result: *const Agent.Result,
        ) CallbackError![]const u8 {
            return allocator.dupe(u8, result.output) catch return error.OutOfMemory;
        }
    };
    const parts = [_]model_types.Part{.{ .text = "owned" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    var node = BufferedNode(Workflow){
        .agent = &agent,
        .correlation = .{ .run_id = "allocation-run" },
        .prepare_fn = Callbacks.prepare,
        .apply_fn = Callbacks.apply,
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(gpa);
    try builder.setStart(.{ .run_fn = Callbacks.boundary });
    try builder.setEnd(.{ .run_fn = Callbacks.boundary });
    const id = try builder.addStep(gpa, node.step("agent", .{}));
    try builder.setEntry(id);
    try builder.finish(gpa, id);
    var graph = try builder.build(gpa);
    defer graph.deinit(gpa);
    var state: u8 = 0;
    var deps: u8 = 0;
    const output = try graph.run(gpa, &state, &deps, "prompt", .{});
    defer gpa.free(output);
    try std.testing.expectEqualStrings("owned", output);
}

test "agent node ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runBufferedNodeWithAllocator,
        .{},
    );
}
