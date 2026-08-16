//! Explicit multi-agent orchestration for delegation, handoff, and subagent runs.
//!
//! A `Session` owns cumulative successful-run usage and bounded run identity.
//! A `Scope` borrows dependencies, history, cancellation, deadlines, and trace
//! context. Agent results remain independently owned by their caller.

const std = @import("std");
const agent_types = @import("agent.zig");
const message_types = @import("messages.zig");
const model_types = @import("model.zig");
const telemetry_types = @import("telemetry.zig");
const usage_types = @import("usage.zig");

const Agent = agent_types.Agent;
const Message = message_types.Message;
const RunUsage = usage_types.RunUsage;

const UsageCapture = struct {
    arena: std.mem.Allocator,
    usage: RunUsage = .{},

    fn observe(context: *anyopaque, event: agent_types.LifecycleEvent) !void {
        const self: *UsageCapture = @ptrCast(@alignCast(context));
        switch (event) {
            .model_request_start => try self.usage.recordRequest(null),
            .model_request_end => |value| try self.usage.addRequest(self.arena, value.response.usage),
            .tool_validation_start => self.usage.tool_calls = std.math.add(
                usize,
                self.usage.tool_calls,
                1,
            ) catch return Error.UsageOverflow,
            else => {},
        }
    }
};

fn attachUsageCapture(
    arena: std.mem.Allocator,
    agent: Agent,
    capture: *UsageCapture,
) std.mem.Allocator.Error!Agent {
    var configured = agent;
    const hooks = try arena.alloc(agent_types.LifecycleHook, agent.hooks.len + 1);
    hooks[0] = .{ .context = capture, .eventFn = UsageCapture.observe };
    @memcpy(hooks[1..], agent.hooks);
    configured.hooks = hooks;
    return configured;
}

/// Multi-agent transition semantics.
pub const Kind = enum {
    /// A child performs work and returns control to its caller.
    delegation,
    /// Application code transfers the next turn to another agent.
    handoff,
    /// A bounded nested agent performs isolated or shared work.
    subagent,
};

/// Session failures that callers can discriminate independently of agent errors.
pub const Error = error{
    /// The stable session or target identity is empty, too long, or malformed.
    InvalidIdentity,
    /// A session limit is zero or internally inconsistent.
    InvalidLimits,
    /// A nested delegation exceeded `Limits.max_depth`.
    DepthLimitExceeded,
    /// The session attempted more agent runs than `Limits.max_runs`.
    RunLimitExceeded,
    /// Aggregate request usage exceeded the session ceiling.
    RequestLimitExceeded,
    /// Aggregate tool usage exceeded the session ceiling.
    ToolCallLimitExceeded,
    /// Aggregate token usage exceeded the session ceiling.
    TokenLimitExceeded,
    /// Aggregate exact cost exceeded the session ceiling.
    CostLimitExceeded,
    /// Usage counters or cost arithmetic overflowed.
    UsageOverflow,
};

/// Hard bounds shared by one complete multi-agent session.
pub const Limits = struct {
    /// Maximum nested delegation or subagent depth. Root handoffs are depth zero.
    max_depth: usize = 8,
    /// Maximum started agent invocations, including failed invocations.
    max_runs: usize = 64,
    max_requests: ?usize = null,
    max_tool_calls: ?usize = null,
    max_total_tokens: ?u64 = null,
    max_cost_nano_usd: ?u64 = null,
};

/// Context passed to one target agent.
pub const Context = union(enum) {
    /// Reuse the current scope's dependencies and canonical history.
    shared,
    /// Use an explicit dependency pointer and history boundary.
    isolated: Isolated,

    pub const Isolated = struct {
        dependencies: ?*anyopaque = null,
        history: []const Message = &.{},
    };
};

/// Per-invocation options. Multi-agent control fields override matching run fields.
pub const CallOptions = struct {
    context: Context = .shared,
    run: agent_types.RunOptions = .{},
};

/// Borrowed multi-agent lifecycle event.
pub const Event = union(enum) {
    start: Start,
    end: End,
    failure: Failure,

    pub const Start = struct {
        kind: Kind,
        target: []const u8,
        depth: usize,
        run_index: usize,
    };

    pub const End = struct {
        kind: Kind,
        target: []const u8,
        depth: usize,
        run_index: usize,
        run_usage: RunUsage,
        session_usage: RunUsage,
    };

    pub const Failure = struct {
        kind: Kind,
        target: []const u8,
        depth: usize,
        run_index: usize,
        failure_name: []const u8,
    };
};

/// Infallible synchronous lifecycle observer. Nested slices are borrowed.
pub const Observer = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: Event) void,

    pub fn emit(self: Observer, event: Event) void {
        self.event_fn(self.context, event);
    }
};

/// Owned cumulative state for one bounded multi-agent execution tree.
///
/// A session is intentionally single-threaded. This keeps run ordering, usage
/// limits, and trace identities deterministic. Use one session per concurrent
/// tree instead of sharing it between threads.
pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    run_id: []const u8,
    limits: Limits,
    observer: ?Observer,
    total_usage: RunUsage = .{},
    runs_started: usize = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        run_id: []const u8,
        limits: Limits,
        observer: ?Observer,
    ) (std.mem.Allocator.Error || Error)!Session {
        if (!validIdentity(run_id)) return Error.InvalidIdentity;
        if (limits.max_runs == 0) return Error.InvalidLimits;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned_run_id = try arena.allocator().dupe(u8, run_id);
        return .{
            .arena = arena,
            .run_id = owned_run_id,
            .limits = limits,
            .observer = observer,
        };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns cumulative usage borrowed until the next invocation or `deinit`.
    pub fn usage(self: *const Session) RunUsage {
        return self.total_usage;
    }

    /// Returns the number of started successful or failed invocations.
    pub fn runCount(self: *const Session) usize {
        return self.runs_started;
    }

    /// Adds usage from parent work executed outside this session's scopes.
    pub fn recordUsage(
        self: *Session,
        run_usage: RunUsage,
    ) (std.mem.Allocator.Error || Error)!void {
        self.total_usage.addRun(self.arena.allocator(), run_usage) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.UsageOverflow => Error.UsageOverflow,
        };
        try self.enforceUsage();
    }

    fn begin(self: *Session, kind: Kind, target: []const u8, depth: usize) Error!usize {
        if (!validIdentity(target)) return Error.InvalidIdentity;
        if (depth > self.limits.max_depth) return Error.DepthLimitExceeded;
        if (self.runs_started >= self.limits.max_runs) return Error.RunLimitExceeded;
        const index = self.runs_started;
        self.runs_started += 1;
        self.emit(.{ .start = .{
            .kind = kind,
            .target = target,
            .depth = depth,
            .run_index = index,
        } });
        return index;
    }

    fn finish(
        self: *Session,
        kind: Kind,
        target: []const u8,
        depth: usize,
        run_index: usize,
        run_usage: RunUsage,
    ) (std.mem.Allocator.Error || Error)!void {
        try self.recordUsage(run_usage);
        self.emit(.{ .end = .{
            .kind = kind,
            .target = target,
            .depth = depth,
            .run_index = run_index,
            .run_usage = run_usage,
            .session_usage = self.total_usage,
        } });
    }

    fn fail(
        self: *Session,
        kind: Kind,
        target: []const u8,
        depth: usize,
        run_index: usize,
        failure: anyerror,
    ) void {
        self.emit(.{ .failure = .{
            .kind = kind,
            .target = target,
            .depth = depth,
            .run_index = run_index,
            .failure_name = @errorName(failure),
        } });
    }

    fn enforceUsage(self: *const Session) Error!void {
        if (self.limits.max_requests) |maximum| {
            if (self.total_usage.requests > maximum) return Error.RequestLimitExceeded;
        }
        if (self.limits.max_tool_calls) |maximum| {
            if (self.total_usage.tool_calls > maximum) return Error.ToolCallLimitExceeded;
        }
        if (self.limits.max_total_tokens) |maximum| {
            const total = std.math.add(
                u64,
                self.total_usage.input_tokens,
                self.total_usage.output_tokens,
            ) catch return Error.UsageOverflow;
            if (total > maximum) return Error.TokenLimitExceeded;
        }
        if (self.limits.max_cost_nano_usd) |maximum| {
            if (self.total_usage.cost) |cost| {
                if (cost.nano_usd > maximum) return Error.CostLimitExceeded;
            }
        }
    }

    fn emit(self: Session, event: Event) void {
        if (self.observer) |observer| observer.emit(event);
    }
};

/// Borrowed execution context for one point in a multi-agent tree.
pub const Scope = struct {
    session: *Session,
    depth: usize = 0,
    dependencies: ?*anyopaque = null,
    history: []const Message = &.{},
    io: ?std.Io = null,
    cancellation: ?*const model_types.CancellationToken = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    telemetry_parent: ?telemetry_types.SpanContext = null,

    /// Creates a root scope. Its first handoff remains at depth zero.
    pub fn root(session: *Session) Scope {
        return .{ .session = session };
    }

    /// Creates a scope for delegation from an active contextual tool.
    pub fn fromToolContext(
        session: *Session,
        depth: usize,
        context: model_types.ToolRunContext,
    ) Scope {
        return .{
            .session = session,
            .depth = depth,
            .dependencies = context.dependencies,
            .history = context.messages,
            .io = context.io,
            .cancellation = context.cancellation,
            .deadline = context.deadline,
        };
    }

    /// Returns a same-depth scope with replacement canonical history.
    pub fn withHistory(self: Scope, history: []const Message) Scope {
        var next = self;
        next.history = history;
        return next;
    }

    /// Returns the scope occupied by a completed delegated child.
    pub fn child(self: Scope, history: []const Message) Scope {
        var next = self;
        next.depth +|= 1;
        next.history = history;
        return next;
    }

    /// Runs a child that returns control to this scope.
    pub fn delegate(
        self: Scope,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !Agent.Result {
        return self.run(agent, .delegation, self.depth +| 1, target, gpa, prompt, options);
    }

    /// Runs a typed child that returns control to this scope.
    pub fn delegateTyped(
        self: Scope,
        comptime Output: type,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !agent_types.TypedResult(Output) {
        return self.runTyped(Output, agent, .delegation, self.depth +| 1, target, gpa, prompt, options);
    }

    /// Transfers the next programmatic turn without increasing recursion depth.
    pub fn handoff(
        self: Scope,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !Agent.Result {
        return self.run(agent, .handoff, self.depth, target, gpa, prompt, options);
    }

    /// Transfers a typed programmatic turn without increasing recursion depth.
    pub fn handoffTyped(
        self: Scope,
        comptime Output: type,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !agent_types.TypedResult(Output) {
        return self.runTyped(Output, agent, .handoff, self.depth, target, gpa, prompt, options);
    }

    /// Runs a bounded nested subagent and returns control to this scope.
    pub fn subagent(
        self: Scope,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !Agent.Result {
        return self.run(agent, .subagent, self.depth +| 1, target, gpa, prompt, options);
    }

    /// Runs a typed bounded subagent and returns control to this scope.
    pub fn subagentTyped(
        self: Scope,
        comptime Output: type,
        agent: *const Agent,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: CallOptions,
    ) !agent_types.TypedResult(Output) {
        return self.runTyped(Output, agent, .subagent, self.depth +| 1, target, gpa, prompt, options);
    }

    fn run(
        self: Scope,
        agent: *const Agent,
        kind: Kind,
        depth: usize,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        call_options: CallOptions,
    ) !Agent.Result {
        const run_index = try self.session.begin(kind, target, depth);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var usage_capture = UsageCapture{ .arena = scratch.allocator() };
        var configured = attachUsageCapture(scratch.allocator(), agent.*, &usage_capture) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        if (configured.io == null) configured.io = self.io;
        if (self.cancellation) |cancellation| configured.cancellation = cancellation;
        const options = self.prepareOptions(
            scratch.allocator(),
            kind,
            depth,
            run_index,
            target,
            call_options,
        ) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        var result = configured.runWithOptions(gpa, prompt, options) catch |failure| {
            self.session.recordUsage(usage_capture.usage) catch |usage_failure| {
                self.session.fail(kind, target, depth, run_index, usage_failure);
                return usage_failure;
            };
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        errdefer result.deinit();
        self.session.finish(kind, target, depth, run_index, result.usage) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        return result;
    }

    fn runTyped(
        self: Scope,
        comptime Output: type,
        agent: *const Agent,
        kind: Kind,
        depth: usize,
        target: []const u8,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        call_options: CallOptions,
    ) !agent_types.TypedResult(Output) {
        const run_index = try self.session.begin(kind, target, depth);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var usage_capture = UsageCapture{ .arena = scratch.allocator() };
        var configured = attachUsageCapture(scratch.allocator(), agent.*, &usage_capture) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        if (configured.io == null) configured.io = self.io;
        if (self.cancellation) |cancellation| configured.cancellation = cancellation;
        const options = self.prepareOptions(
            scratch.allocator(),
            kind,
            depth,
            run_index,
            target,
            call_options,
        ) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        var result = configured.runTypedWithOptions(Output, gpa, prompt, options) catch |failure| {
            self.session.recordUsage(usage_capture.usage) catch |usage_failure| {
                self.session.fail(kind, target, depth, run_index, usage_failure);
                return usage_failure;
            };
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        errdefer result.deinit();
        self.session.finish(kind, target, depth, run_index, result.usage) catch |failure| {
            self.session.fail(kind, target, depth, run_index, failure);
            return failure;
        };
        return result;
    }

    fn prepareOptions(
        self: Scope,
        arena: std.mem.Allocator,
        kind: Kind,
        depth: usize,
        run_index: usize,
        target: []const u8,
        call_options: CallOptions,
    ) !agent_types.RunOptions {
        var options = call_options.run;
        switch (call_options.context) {
            .shared => {
                options.dependencies = self.dependencies;
                options.message_history = self.history;
            },
            .isolated => |isolated| {
                options.dependencies = isolated.dependencies;
                options.message_history = isolated.history;
            },
        }
        if (options.telemetry_parent == null) options.telemetry_parent = self.telemetry_parent;
        if (self.deadline) |deadline| {
            const remaining = try (model_types.RunControl{
                .io = self.io,
                .cancellation = self.cancellation,
                .deadline = deadline,
            }).remainingMilliseconds();
            const milliseconds = remaining.?;
            options.timeout_ms = if (options.timeout_ms) |local| @min(local, milliseconds) else milliseconds;
        }
        const node_id = try std.fmt.allocPrint(arena, "{s}.{d}.{d}", .{
            @tagName(kind),
            depth,
            run_index,
        });
        options.correlation = .{
            .run_id = self.session.run_id,
            .node_id = node_id,
            .node_name = target,
        };
        return options;
    }
};

fn validIdentity(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

test "multi-agent scopes propagate shared and isolated context usage and traces" {
    const Capture = struct {
        expected_history: usize = 1,
        expected_dependency: *u8,
        expected_parent: [8]u8,
        requests: usize = 0,
        starts: usize = 0,
        ends: usize = 0,
        correlations: usize = 0,
        traced_runs: usize = 0,

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: model_types.ModelRequest,
        ) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(self.expected_history + 1, request_value.messages.len);
            const usage: model_types.Usage = if (self.requests == 0)
                .{ .input_tokens = 2, .output_tokens = 3 }
            else
                .{ .input_tokens = 5, .output_tokens = 7 };
            self.requests += 1;
            return .{ .parts = &.{.{ .text = "child" }}, .usage = usage };
        }

        fn instruction(
            context: *anyopaque,
            _: std.mem.Allocator,
            run: agent_types.InstructionContext,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(run.dependency(u8).? == self.expected_dependency);
            return "";
        }

        fn hook(context: *anyopaque, event: agent_types.LifecycleEvent) !void {
            if (event != .run_start) return;
            const self: *@This() = @ptrCast(@alignCast(context));
            const correlation = event.run_start.correlation.?;
            try std.testing.expectEqualStrings("tree-1", correlation.run_id);
            self.correlations += 1;
        }

        fn span(context: *anyopaque, value: telemetry_types.Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, value.name, "invoke_agent")) return;
            try std.testing.expectEqualSlices(u8, &self.expected_parent, &value.parent_span_id.?);
            self.traced_runs += 1;
        }

        fn metric(_: *anyopaque, _: telemetry_types.Metric) !void {}

        fn observe(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .start => self.starts += 1,
                .end => self.ends += 1,
                .failure => {},
            }
        }
    };
    var shared_dependency: u8 = 1;
    var isolated_dependency: u8 = 2;
    const parent = telemetry_types.SpanContext{
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
    };
    var capture = Capture{
        .expected_dependency = &shared_dependency,
        .expected_parent = parent.span_id,
    };
    const instructions = [_]agent_types.Instruction{.{ .dynamic = .{
        .context = &capture,
        .resolveFn = Capture.instruction,
    } }};
    const hooks = [_]agent_types.LifecycleHook{.{ .context = &capture, .eventFn = Capture.hook }};
    const agent = Agent{
        .model = .{ .context = &capture, .profile = .{}, .requestFn = Capture.request },
        .instructions = &instructions,
        .hooks = &hooks,
        .telemetry = .{
            .io = std.testing.io,
            .exporter = .{
                .context = &capture,
                .spanFn = Capture.span,
                .metricFn = Capture.metric,
            },
        },
    };
    var session = try Session.init(
        std.testing.allocator,
        "tree-1",
        .{ .max_requests = 2, .max_total_tokens = 17 },
        .{ .context = &capture, .event_fn = Capture.observe },
    );
    defer session.deinit();
    const history = [_]Message{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "history" } }} } }};
    var scope = Scope.root(&session);
    scope.dependencies = &shared_dependency;
    scope.history = &history;
    scope.io = std.testing.io;
    scope.telemetry_parent = parent;
    var delegated = try scope.delegate(&agent, "researcher", std.testing.allocator, "work", .{});
    defer delegated.deinit();
    try std.testing.expectEqualStrings("child", delegated.output);

    capture.expected_history = 0;
    capture.expected_dependency = &isolated_dependency;
    var handed = try scope.handoff(&agent, "writer", std.testing.allocator, "write", .{
        .context = .{ .isolated = .{ .dependencies = &isolated_dependency } },
    });
    defer handed.deinit();
    try std.testing.expectEqual(@as(usize, 2), session.usage().requests);
    try std.testing.expectEqual(@as(u64, 17), session.usage().totalTokens());
    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 2), capture.ends);
    try std.testing.expectEqual(@as(usize, 2), capture.correlations);
    try std.testing.expectEqual(@as(usize, 2), capture.traced_runs);
}

test "multi-agent scopes enforce recursion run and usage limits" {
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "done" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{
        .{ .parts = &parts, .usage = .{ .input_tokens = 2 } },
        .{ .parts = &parts },
    } };
    const agent = Agent{ .model = scripted.model() };
    var session = try Session.init(std.testing.allocator, "bounded", .{
        .max_depth = 1,
        .max_runs = 2,
        .max_total_tokens = 1,
    }, null);
    defer session.deinit();
    const scope = Scope.root(&session);
    try std.testing.expectError(
        Error.DepthLimitExceeded,
        scope.child(&.{}).subagent(&agent, "deep", std.testing.allocator, "work", .{}),
    );
    try std.testing.expectError(
        Error.TokenLimitExceeded,
        scope.delegate(&agent, "child", std.testing.allocator, "work", .{}),
    );
    session.limits.max_total_tokens = null;
    var next = try scope.handoff(&agent, "next", std.testing.allocator, "work", .{});
    next.deinit();
    try std.testing.expectError(
        Error.RunLimitExceeded,
        scope.handoff(&agent, "last", std.testing.allocator, "work", .{}),
    );
    try std.testing.expectEqual(@as(usize, 2), session.runCount());
}

test "multi-agent tool scopes propagate cancellation deadlines and failures" {
    const Capture = struct {
        failures: usize = 0,

        fn observe(context: ?*anyopaque, event: Event) void {
            if (event != .failure) return;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.failures += 1;
        }
    };
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "unused" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    var capture: Capture = .{};
    var session = try Session.init(
        std.testing.allocator,
        "controlled",
        .{},
        .{ .context = &capture, .event_fn = Capture.observe },
    );
    defer session.deinit();
    var cancellation: model_types.CancellationToken = .{};
    cancellation.cancel();
    var dependency: u8 = 1;
    const history = [_]Message{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "history" } }} } }};
    const cancelled = Scope.fromToolContext(&session, 0, .{
        .dependencies = &dependency,
        .messages = &history,
        .cancellation = &cancellation,
        .io = std.testing.io,
    });
    try std.testing.expectError(
        error.Cancelled,
        cancelled.delegate(&agent, "cancelled", std.testing.allocator, "work", .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), scripted.request_count);

    const expired = Scope.fromToolContext(&session, 0, .{
        .dependencies = &dependency,
        .messages = &history,
        .io = std.testing.io,
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .raw = .fromMilliseconds(0),
            .clock = .awake,
        }),
    });
    try std.testing.expectError(
        error.RunTimedOut,
        expired.subagent(&agent, "expired", std.testing.allocator, "work", .{}),
    );

    var live = Scope.root(&session);
    live.io = std.testing.io;
    live.deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromSeconds(1),
        .clock = .awake,
    });
    var result = try live.handoff(&agent, "live", std.testing.allocator, "work", .{
        .run = .{ .timeout_ms = 100 },
    });
    result.deinit();
    try std.testing.expectEqual(@as(usize, 2), capture.failures);
}

test "multi-agent usage captures tools and failed-run budget errors" {
    const testing_types = @import("testing.zig");
    const call_parts = [_]model_types.Part{.{ .tool_call = .{
        .id = "call-1",
        .name = "work",
        .arguments_json = "{}",
    } }};
    const final_parts = [_]model_types.Part{.{ .text = "done" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{
        .{ .parts = &call_parts },
        .{ .parts = &final_parts },
    } };
    var executions: usize = 0;
    const tool = model_types.Tool{
        .definition = .{ .name = "work", .description = "", .parameters_json_schema = "{}" },
        .context = &executions,
        .executeFn = struct {
            fn execute(context: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![]const u8 {
                const count: *usize = @ptrCast(@alignCast(context));
                count.* += 1;
                return gpa.dupe(u8, "ok");
            }
        }.execute,
    };
    const agent = Agent{ .model = scripted.model(), .tools = &.{tool} };
    var session = try Session.init(std.testing.allocator, "tools", .{}, null);
    defer session.deinit();
    var result = try Scope.root(&session).handoff(&agent, "worker", std.testing.allocator, "work", .{});
    result.deinit();
    try std.testing.expectEqual(@as(usize, 1), executions);
    try std.testing.expectEqual(@as(usize, 1), session.usage().tool_calls);

    var failed_session = try Session.init(std.testing.allocator, "failed", .{ .max_requests = 0 }, null);
    defer failed_session.deinit();
    var empty_script = testing_types.ScriptedModel{ .responses = &.{} };
    const empty_agent = Agent{ .model = empty_script.model() };
    try std.testing.expectError(
        Error.RequestLimitExceeded,
        Scope.root(&failed_session).handoff(&empty_agent, "empty", std.testing.allocator, "work", .{}),
    );

    const Answer = struct { value: u8 };
    var typed_session = try Session.init(std.testing.allocator, "typed-failed", .{ .max_requests = 0 }, null);
    defer typed_session.deinit();
    var typed_script = testing_types.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_json_schema_output = true },
    };
    const typed_agent = Agent{ .model = typed_script.model() };
    try std.testing.expectError(
        Error.RequestLimitExceeded,
        Scope.root(&typed_session).handoffTyped(
            Answer,
            &typed_agent,
            "empty",
            std.testing.allocator,
            "work",
            .{},
        ),
    );
}

test "typed multi-agent runs preserve output and every failure boundary" {
    const testing_types = @import("testing.zig");
    const Answer = struct { value: u8 };
    const success_parts = [_]model_types.Part{.{ .text = "{\"value\":4}" }};
    var success_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &success_parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    const success_agent = Agent{ .model = success_script.model() };
    var session = try Session.init(std.testing.allocator, "typed", .{}, null);
    defer session.deinit();
    const scope = Scope.root(&session);
    var success = try scope.delegateTyped(
        Answer,
        &success_agent,
        "typed-child",
        std.testing.allocator,
        "work",
        .{},
    );
    defer success.deinit();
    try std.testing.expectEqual(@as(u8, 4), success.output.value);

    var empty_script = testing_types.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_json_schema_output = true },
    };
    const empty_agent = Agent{ .model = empty_script.model() };
    try std.testing.expectError(
        error.ScriptExhausted,
        scope.handoffTyped(Answer, &empty_agent, "empty", std.testing.allocator, "work", .{}),
    );
    try std.testing.expectEqual(@as(usize, 2), session.usage().requests);

    var expired = scope;
    expired.io = std.testing.io;
    expired.deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(0),
        .clock = .awake,
    });
    try std.testing.expectError(
        error.RunTimedOut,
        expired.subagentTyped(Answer, &success_agent, "expired", std.testing.allocator, "work", .{}),
    );

    const limit_parts = [_]model_types.Part{.{ .text = "{\"value\":5}" }};
    var limit_script = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &limit_parts, .usage = .{ .input_tokens = 2 } }},
        .profile = .{ .supports_json_schema_output = true },
    };
    const limit_agent = Agent{ .model = limit_script.model() };
    session.limits.max_total_tokens = 1;
    try std.testing.expectError(
        Error.TokenLimitExceeded,
        scope.delegateTyped(Answer, &limit_agent, "limited", std.testing.allocator, "work", .{}),
    );
}

test "multi-agent sessions enforce every aggregate usage limit" {
    var requests = try Session.init(std.testing.allocator, "requests", .{ .max_requests = 0 }, null);
    defer requests.deinit();
    try std.testing.expectError(
        Error.RequestLimitExceeded,
        requests.recordUsage(.{ .requests = 1 }),
    );

    var tools = try Session.init(std.testing.allocator, "tools", .{ .max_tool_calls = 0 }, null);
    defer tools.deinit();
    try std.testing.expectError(
        Error.ToolCallLimitExceeded,
        tools.recordUsage(.{ .tool_calls = 1 }),
    );

    var cost = try Session.init(std.testing.allocator, "cost", .{ .max_cost_nano_usd = 0 }, null);
    defer cost.deinit();
    try std.testing.expectError(
        Error.CostLimitExceeded,
        cost.recordUsage(.{ .cost = .{ .nano_usd = 1 } }),
    );

    var overflow = try Session.init(std.testing.allocator, "overflow", .{}, null);
    defer overflow.deinit();
    try overflow.recordUsage(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectError(
        Error.UsageOverflow,
        overflow.recordUsage(.{ .input_tokens = 1 }),
    );
}

fn runMultiAgentWithAllocator(gpa: std.mem.Allocator) !void {
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "owned" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    var session = try Session.init(gpa, "allocation-run", .{}, null);
    defer session.deinit();
    var result = try Scope.root(&session).handoff(&agent, "agent", gpa, "prompt", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("owned", result.output);
}

fn runTypedMultiAgentWithAllocator(gpa: std.mem.Allocator) !void {
    const testing_types = @import("testing.zig");
    const Answer = struct { value: u8 };
    const parts = [_]model_types.Part{.{ .text = "{\"value\":1}" }};
    var scripted = testing_types.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    const agent = Agent{ .model = scripted.model() };
    var session = try Session.init(gpa, "typed-allocation", .{}, null);
    defer session.deinit();
    var result = try Scope.root(&session).handoffTyped(Answer, &agent, "agent", gpa, "prompt", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 1), result.output.value);
}

test "multi-agent invocation ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runMultiAgentWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runTypedMultiAgentWithAllocator,
        .{},
    );
}

test "multi-agent session identity and allocation failures are explicit" {
    try std.testing.expectError(
        Error.InvalidIdentity,
        Session.init(std.testing.allocator, "bad/run", .{}, null),
    );
    var session = try Session.init(std.testing.allocator, "run", .{}, null);
    defer session.deinit();
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "unused" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    try std.testing.expectError(
        Error.InvalidIdentity,
        Scope.root(&session).handoff(&agent, "bad/target", std.testing.allocator, "work", .{}),
    );
    try std.testing.expectError(
        Error.InvalidLimits,
        Session.init(std.testing.allocator, "run", .{ .max_runs = 0 }, null),
    );
    const Support = struct {
        fn allocate(gpa: std.mem.Allocator) !void {
            var allocation_session = try Session.init(gpa, "allocation", .{}, null);
            defer allocation_session.deinit();
            try allocation_session.recordUsage(.{ .details = &.{.{ .name = "tokens", .value = 1 }} });
            try std.testing.expectEqualStrings("allocation", allocation_session.run_id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Support.allocate, .{});
}
