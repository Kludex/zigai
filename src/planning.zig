//! Bounded plans, advisory callbacks, approval gates, and dynamic execution.
//!
//! Plans are immutable revisions. Executions own step output and advisory text
//! in one arena and propagate one deadline, cancellation token, usage, and trace.

const std = @import("std");
const agent_types = @import("agent.zig");
const model_types = @import("model.zig");
const multi_agent = @import("multi_agent.zig");
const telemetry = @import("telemetry.zig");
const usage_types = @import("usage.zig");

/// One immutable plan step.
pub const Step = struct {
    id: []const u8,
    title: []const u8,
    dependencies: []const []const u8 = &.{},
    requires_approval: bool = false,
};

/// Hard plan, advisory, and output limits.
pub const Limits = struct {
    max_steps: usize = 128,
    max_dependencies_per_step: usize = 32,
    max_id_bytes: usize = 128,
    max_title_bytes: usize = 4 * 1024,
    max_advisors: usize = 16,
    max_advice_bytes: usize = 1024 * 1024,
    max_step_output_bytes: usize = 4 * 1024 * 1024,
};

/// Arena-owned immutable plan revision.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    revision: u64,
    steps: []const Step,
    limits: Limits,

    pub fn init(
        gpa: std.mem.Allocator,
        id: []const u8,
        steps: []const Step,
        limits: Limits,
    ) !Plan {
        return copy(gpa, id, 1, steps, limits);
    }

    pub fn revise(self: *const Plan, gpa: std.mem.Allocator, steps: []const Step) !Plan {
        const revision = std.math.add(u64, self.revision, 1) catch return error.PlanRevisionExhausted;
        return copy(gpa, self.id, revision, steps, self.limits);
    }

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn copy(
        gpa: std.mem.Allocator,
        id: []const u8,
        revision: u64,
        steps: []const Step,
        limits: Limits,
    ) !Plan {
        try validate(gpa, id, steps, limits);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const copied_steps = try arena.allocator().alloc(Step, steps.len);
        for (steps, copied_steps) |step, *target| {
            const dependencies = try arena.allocator().alloc([]const u8, step.dependencies.len);
            for (step.dependencies, dependencies) |dependency, *copy_dependency| {
                copy_dependency.* = try arena.allocator().dupe(u8, dependency);
            }
            target.* = .{
                .id = try arena.allocator().dupe(u8, step.id),
                .title = try arena.allocator().dupe(u8, step.title),
                .dependencies = dependencies,
                .requires_approval = step.requires_approval,
            };
        }
        const owned_id = try arena.allocator().dupe(u8, id);
        return .{ .arena = arena, .id = owned_id, .revision = revision, .steps = copied_steps, .limits = limits };
    }
};

/// Explicit user decision for a gated step.
pub const Approval = struct {
    step_id: []const u8,
    approved: bool,
};

/// Step callback output allocated in the execution arena.
pub const StepResult = struct {
    output: []const u8,
    usage: usage_types.RunUsage = .{},
};

/// Dynamic step callback.
pub const Executor = struct {
    context: ?*anyopaque = null,
    execute_fn: *const fn (
        context: ?*anyopaque,
        arena: std.mem.Allocator,
        run: StepContext,
    ) anyerror!StepResult,

    pub fn execute(self: Executor, arena: std.mem.Allocator, context: StepContext) !StepResult {
        return self.execute_fn(self.context, arena, context);
    }
};

/// Borrowed context for one dynamic step.
pub const StepContext = struct {
    plan_id: []const u8,
    revision: u64,
    step: Step,
    completed: []const StepExecution,
    control: model_types.RunControl,
    trace_parent: ?telemetry.SpanContext,
    nested_scope: ?multi_agent.Scope,
};

/// Advisory callback run before approved execution.
pub const Advisor = struct {
    name: []const u8,
    context: ?*anyopaque = null,
    advise_fn: *const fn (
        context: ?*anyopaque,
        arena: std.mem.Allocator,
        plan: *const Plan,
        control: model_types.RunControl,
    ) anyerror![]const u8,

    pub fn advise(
        self: Advisor,
        arena: std.mem.Allocator,
        plan: *const Plan,
        control: model_types.RunControl,
    ) ![]const u8 {
        return self.advise_fn(self.context, arena, plan, control);
    }
};

/// One completed dynamic step.
pub const StepExecution = struct {
    step_id: []const u8,
    output: []const u8,
};

/// One advisory result.
pub const Advice = struct {
    name: []const u8,
    content: []const u8,
};

/// Trace-linked planning lifecycle event.
pub const Event = union(enum) {
    plan_revised: PlanRevision,
    advice: AdviceEvent,
    approval_required: ApprovalEvent,
    step_start: StepEvent,
    step_end: StepEvent,
    run_end: PlanRevision,
    failure: Failure,

    pub const PlanRevision = struct {
        plan_id: []const u8,
        revision: u64,
        trace: ?telemetry.SpanContext,
    };
    pub const AdviceEvent = struct {
        plan_id: []const u8,
        revision: u64,
        advisor: []const u8,
        trace: ?telemetry.SpanContext,
    };
    pub const ApprovalEvent = struct {
        plan_id: []const u8,
        revision: u64,
        step_id: []const u8,
        trace: ?telemetry.SpanContext,
    };
    pub const StepEvent = struct {
        plan_id: []const u8,
        revision: u64,
        step_id: []const u8,
        trace: ?telemetry.SpanContext,
    };
    pub const Failure = struct {
        plan_id: []const u8,
        revision: u64,
        failure_name: []const u8,
        trace: ?telemetry.SpanContext,
    };
};

/// Fallible synchronous planning observer.
pub const Observer = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: Event) anyerror!void,

    pub fn emit(self: Observer, event: Event) !void {
        return self.event_fn(self.context, event);
    }
};

/// Dynamic execution settings.
pub const RunOptions = struct {
    io: ?std.Io = null,
    cancellation: ?*const model_types.CancellationToken = null,
    timeout_ms: ?u64 = null,
    approvals: []const Approval = &.{},
    advisors: []const Advisor = &.{},
    observer: ?Observer = null,
    trace_parent: ?telemetry.SpanContext = null,
    nested_scope: ?multi_agent.Scope = null,
};

/// Arena-owned complete execution.
pub const Execution = struct {
    arena: std.heap.ArenaAllocator,
    steps: []const StepExecution,
    advice: []const Advice,
    usage: usage_types.RunUsage,

    pub fn deinit(self: *Execution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Arena-owned approval pause.
pub const Paused = struct {
    arena: std.heap.ArenaAllocator,
    step_ids: []const []const u8,

    pub fn deinit(self: *Paused) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    complete: Execution,
    paused: Paused,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .complete => |*execution| execution.deinit(),
            .paused => |*paused| paused.deinit(),
        }
        self.* = undefined;
    }
};

/// Agent capability adapter for executing one dynamic plan as a function tool.
pub const CapabilityAdapter = struct {
    plan: *const Plan,
    executor: Executor,
    options: RunOptions = .{},
    tools: [1]model_types.Tool = undefined,
    instructions: [1]agent_types.Instruction = undefined,

    pub fn capability(self: *CapabilityAdapter) agent_types.Capability {
        self.instructions[0] = .{ .text = "Use execute_dynamic_plan when the approved plan should run. Report plan step outputs to the user." };
        self.tools[0] = .{
            .definition = .{
                .name = "execute_dynamic_plan",
                .description = "Execute the current bounded dynamic plan in dependency order.",
                .parameters_json_schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
            },
            .execution = if (hasApproval(self.plan)) .requires_approval else .immediate,
            .context = self,
            .executeWithContextFn = execute,
        };
        return .{
            .id = "dynamic_workflow",
            .description = "Execute a bounded, approval-aware dynamic plan.",
            .tools = &self.tools,
            .instructions = &self.instructions,
        };
    }

    fn execute(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        tool_context: model_types.ToolRunContext,
        _: []const u8,
    ) ![]const u8 {
        const self: *CapabilityAdapter = @ptrCast(@alignCast(context));
        var options = self.options;
        options.io = tool_context.io;
        options.cancellation = tool_context.cancellation;
        if (tool_context.deadline) |deadline| {
            options.timeout_ms = (try (model_types.RunControl{
                .io = tool_context.io,
                .cancellation = tool_context.cancellation,
                .deadline = deadline,
            }).remainingMilliseconds()).?;
        }
        const approvals = try gpa.alloc(Approval, self.plan.steps.len);
        defer gpa.free(approvals);
        var approval_count: usize = 0;
        for (self.plan.steps) |step| if (step.requires_approval) {
            approvals[approval_count] = .{ .step_id = step.id, .approved = true };
            approval_count += 1;
        };
        options.approvals = approvals[0..approval_count];
        var outcome = try run(gpa, self.plan, self.executor, options);
        defer outcome.deinit();
        return switch (outcome) {
            .complete => |execution| std.json.Stringify.valueAlloc(gpa, .{
                .plan_id = self.plan.id,
                .revision = self.plan.revision,
                .steps = execution.steps,
                .usage = execution.usage,
            }, .{}),
            .paused => error.PlanApprovalRequired,
        };
    }
};

fn hasApproval(plan: *const Plan) bool {
    for (plan.steps) |step| if (step.requires_approval) return true;
    return false;
}

/// Executes an approved dynamic plan in dependency order.
pub fn run(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    executor: Executor,
    options: RunOptions,
) !Outcome {
    if (options.advisors.len > plan.limits.max_advisors) return error.TooManyPlanAdvisors;
    const control = try model_types.RunControl.init(options.io, options.cancellation, options.timeout_ms);
    try emit(options.observer, .{ .plan_revised = .{
        .plan_id = plan.id,
        .revision = plan.revision,
        .trace = options.trace_parent,
    } }, control);
    if (try missingApprovals(gpa, plan, options.approvals, options.trace_parent, options.observer, control)) |paused| {
        return .{ .paused = paused };
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const advice = try memory.alloc(Advice, options.advisors.len);
    for (options.advisors, advice) |advisor, *result| {
        const content = try control.invoke([]const u8, invokeAdvisor, .{ advisor, memory, plan, control });
        if (content.len > plan.limits.max_advice_bytes) return error.PlanAdviceTooLarge;
        result.* = .{ .name = try memory.dupe(u8, advisor.name), .content = content };
        try emit(options.observer, .{ .advice = .{
            .plan_id = plan.id,
            .revision = plan.revision,
            .advisor = advisor.name,
            .trace = options.trace_parent,
        } }, control);
    }
    const executions = try memory.alloc(StepExecution, plan.steps.len);
    const completed = try memory.alloc(bool, plan.steps.len);
    @memset(completed, false);
    var usage: usage_types.RunUsage = .{};
    var completed_count: usize = 0;
    while (completed_count < plan.steps.len) {
        var progressed = false;
        for (plan.steps, 0..) |step, index| {
            if (completed[index] or !dependenciesComplete(plan, step, completed)) continue;
            try emit(options.observer, .{ .step_start = .{
                .plan_id = plan.id,
                .revision = plan.revision,
                .step_id = step.id,
                .trace = options.trace_parent,
            } }, control);
            const result = control.invoke(StepResult, invokeExecutor, .{
                executor,
                memory,
                StepContext{
                    .plan_id = plan.id,
                    .revision = plan.revision,
                    .step = step,
                    .completed = executions[0..completed_count],
                    .control = control,
                    .trace_parent = options.trace_parent,
                    .nested_scope = options.nested_scope,
                },
            }) catch |failure| {
                try emit(options.observer, .{ .failure = .{
                    .plan_id = plan.id,
                    .revision = plan.revision,
                    .failure_name = @errorName(failure),
                    .trace = options.trace_parent,
                } }, control);
                return failure;
            };
            if (result.output.len > plan.limits.max_step_output_bytes) return error.PlanStepOutputTooLarge;
            try usage.addRun(memory, result.usage);
            executions[completed_count] = .{
                .step_id = try memory.dupe(u8, step.id),
                .output = try memory.dupe(u8, result.output),
            };
            completed[index] = true;
            completed_count += 1;
            progressed = true;
            try emit(options.observer, .{ .step_end = .{
                .plan_id = plan.id,
                .revision = plan.revision,
                .step_id = step.id,
                .trace = options.trace_parent,
            } }, control);
        }
        if (!progressed) return error.InvalidPlanGraph;
    }
    try emit(options.observer, .{ .run_end = .{
        .plan_id = plan.id,
        .revision = plan.revision,
        .trace = options.trace_parent,
    } }, control);
    return .{ .complete = .{
        .arena = arena,
        .steps = executions,
        .advice = advice,
        .usage = usage,
    } };
}

fn missingApprovals(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    approvals: []const Approval,
    trace: ?telemetry.SpanContext,
    observer: ?Observer,
    control: model_types.RunControl,
) !?Paused {
    var count: usize = 0;
    for (plan.steps) |step| if (step.requires_approval) {
        const decision = findApproval(approvals, step.id) orelse {
            count += 1;
            continue;
        };
        if (!decision.approved) return error.PlanApprovalDenied;
    };
    if (count == 0) return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const ids = try arena.allocator().alloc([]const u8, count);
    var index: usize = 0;
    for (plan.steps) |step| {
        if (!step.requires_approval or findApproval(approvals, step.id) != null) continue;
        ids[index] = try arena.allocator().dupe(u8, step.id);
        index += 1;
        try emit(observer, .{ .approval_required = .{
            .plan_id = plan.id,
            .revision = plan.revision,
            .step_id = step.id,
            .trace = trace,
        } }, control);
    }
    return .{ .arena = arena, .step_ids = ids };
}

fn findApproval(approvals: []const Approval, step_id: []const u8) ?Approval {
    for (approvals) |approval| if (std.mem.eql(u8, approval.step_id, step_id)) return approval;
    return null;
}

fn dependenciesComplete(plan: *const Plan, step: Step, completed: []const bool) bool {
    for (step.dependencies) |dependency| {
        const index = stepIndex(plan.steps, dependency).?;
        if (!completed[index]) return false;
    }
    return true;
}

fn invokeExecutor(executor: Executor, arena: std.mem.Allocator, context: StepContext) !StepResult {
    return executor.execute(arena, context);
}

fn invokeAdvisor(advisor: Advisor, arena: std.mem.Allocator, plan: *const Plan, control: model_types.RunControl) ![]const u8 {
    return advisor.advise(arena, plan, control);
}

fn invokeObserver(observer: Observer, event: Event) !void {
    return observer.emit(event);
}

fn emit(observer: ?Observer, event: Event, control: model_types.RunControl) !void {
    if (observer) |sink| try control.invoke(void, invokeObserver, .{ sink, event });
}

fn validate(gpa: std.mem.Allocator, id: []const u8, steps: []const Step, limits: Limits) !void {
    try validateId(id, limits.max_id_bytes);
    if (steps.len == 0 or steps.len > limits.max_steps) return error.InvalidPlan;
    for (steps, 0..) |step, index| {
        try validateId(step.id, limits.max_id_bytes);
        if (step.title.len == 0 or step.title.len > limits.max_title_bytes) return error.InvalidPlan;
        if (step.dependencies.len > limits.max_dependencies_per_step) return error.InvalidPlan;
        for (steps[0..index]) |previous| if (std.mem.eql(u8, previous.id, step.id))
            return error.InvalidPlan;
        for (step.dependencies) |dependency| {
            if (std.mem.eql(u8, dependency, step.id) or stepIndex(steps, dependency) == null)
                return error.InvalidPlan;
        }
    }
    const visiting = try gpa.alloc(bool, steps.len);
    defer gpa.free(visiting);
    const visited = try gpa.alloc(bool, steps.len);
    defer gpa.free(visited);
    @memset(visiting, false);
    @memset(visited, false);
    for (steps, 0..) |_, index| if (hasCycle(steps, index, visiting, visited)) return error.InvalidPlan;
}

fn hasCycle(steps: []const Step, index: usize, visiting: []bool, visited: []bool) bool {
    if (visiting[index]) return true;
    if (visited[index]) return false;
    visiting[index] = true;
    for (steps[index].dependencies) |dependency| {
        if (hasCycle(steps, stepIndex(steps, dependency).?, visiting, visited)) return true;
    }
    visiting[index] = false;
    visited[index] = true;
    return false;
}

fn stepIndex(steps: []const Step, id: []const u8) ?usize {
    for (steps, 0..) |step, index| if (std.mem.eql(u8, step.id, id)) return index;
    return null;
}

fn validateId(id: []const u8, maximum: usize) !void {
    if (id.len == 0 or id.len > maximum) return error.InvalidPlan;
    for (id) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
        return error.InvalidPlan;
}

test "dynamic plans pause revise advise execute and propagate usage traces" {
    const State = struct {
        events: usize = 0,
        executions: usize = 0,
        saw_trace: bool = false,
        saw_nested: bool = false,

        fn observe(context: ?*anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events += 1;
            const trace = switch (event) {
                .plan_revised => |value| value.trace,
                .advice => |value| value.trace,
                .approval_required => |value| value.trace,
                .step_start => |value| value.trace,
                .step_end => |value| value.trace,
                .run_end => |value| value.trace,
                .failure => |value| value.trace,
            };
            self.saw_trace = self.saw_trace or trace != null;
        }

        fn advise(_: ?*anyopaque, arena: std.mem.Allocator, plan: *const Plan, _: model_types.RunControl) ![]const u8 {
            try std.testing.expectEqual(@as(u64, 2), plan.revision);
            return arena.dupe(u8, "reviewed");
        }

        fn execute(context: ?*anyopaque, arena: std.mem.Allocator, run_context: StepContext) !StepResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.executions += 1;
            self.saw_nested = self.saw_nested or run_context.nested_scope != null;
            return .{
                .output = try std.fmt.allocPrint(arena, "done:{s}", .{run_context.step.id}),
                .usage = .{ .requests = 1, .input_tokens = 2 },
            };
        }
    };
    var first = try Plan.init(std.testing.allocator, "plan", &.{
        .{ .id = "inspect", .title = "Inspect" },
        .{ .id = "change", .title = "Change", .dependencies = &.{"inspect"}, .requires_approval = true },
    }, .{});
    defer first.deinit();
    var revised = try first.revise(std.testing.allocator, first.steps);
    defer revised.deinit();
    try std.testing.expectEqual(@as(u64, 2), revised.revision);
    var state: State = .{};
    const parent = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var usage_session = try multi_agent.Session.init(std.testing.allocator, "nested", .{}, null);
    defer usage_session.deinit();
    const options = RunOptions{
        .advisors = &.{.{ .name = "review", .advise_fn = State.advise }},
        .observer = .{ .context = &state, .event_fn = State.observe },
        .trace_parent = parent,
        .nested_scope = multi_agent.Scope.root(&usage_session),
    };
    var paused = try run(
        std.testing.allocator,
        &revised,
        .{ .context = &state, .execute_fn = State.execute },
        options,
    );
    defer paused.deinit();
    try std.testing.expectEqual(@as(usize, 1), paused.paused.step_ids.len);
    try std.testing.expectEqualStrings("change", paused.paused.step_ids[0]);

    var approved_options = options;
    approved_options.approvals = &.{.{ .step_id = "change", .approved = true }};
    var completed = try run(
        std.testing.allocator,
        &revised,
        .{ .context = &state, .execute_fn = State.execute },
        approved_options,
    );
    defer completed.deinit();
    try std.testing.expectEqual(@as(usize, 2), completed.complete.steps.len);
    try std.testing.expectEqualStrings("done:change", completed.complete.steps[1].output);
    try std.testing.expectEqualStrings("reviewed", completed.complete.advice[0].content);
    try std.testing.expectEqual(@as(usize, 2), completed.complete.usage.requests);
    try std.testing.expect(state.saw_trace);
    try std.testing.expect(state.saw_nested);
    try State.observe(&state, .{ .failure = .{
        .plan_id = revised.id,
        .revision = revised.revision,
        .failure_name = "Synthetic",
        .trace = parent,
    } });

    var adapter = CapabilityAdapter{
        .plan = &revised,
        .executor = .{ .context = &state, .execute_fn = State.execute },
        .options = options,
    };
    const capability = adapter.capability();
    try std.testing.expectEqual(model_types.ToolExecution.requires_approval, capability.tools[0].execution);
    const encoded = try capability.tools[0].executeWithContext(
        std.testing.allocator,
        .{
            .io = std.testing.io,
            .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
                .raw = .fromSeconds(1),
                .clock = .awake,
            }),
        },
        "{}",
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "done:change") != null);

    var ungated = try Plan.init(std.testing.allocator, "ungated", &.{.{ .id = "step", .title = "Step" }}, .{});
    defer ungated.deinit();
    var ungated_adapter = CapabilityAdapter{
        .plan = &ungated,
        .executor = .{ .context = &state, .execute_fn = State.execute },
    };
    try std.testing.expectEqual(
        model_types.ToolExecution.immediate,
        ungated_adapter.capability().tools[0].execution,
    );
}

test "plan validation approvals and execution failures remain explicit" {
    try std.testing.expectError(
        error.InvalidPlan,
        Plan.init(std.testing.allocator, "plan", &.{.{
            .id = "cycle",
            .title = "Cycle",
            .dependencies = &.{"cycle"},
        }}, .{}),
    );
    try std.testing.expectError(
        error.InvalidPlan,
        Plan.init(std.testing.allocator, "plan", &.{.{
            .id = "step",
            .title = "Missing",
            .dependencies = &.{"missing"},
        }}, .{}),
    );
    var plan = try Plan.init(std.testing.allocator, "plan", &.{.{
        .id = "approved",
        .title = "Approved",
        .requires_approval = true,
    }}, .{});
    defer plan.deinit();
    const ExecutorState = struct {
        failures: usize = 0,
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: StepContext) !StepResult {
            return error.StepFailed;
        }
        fn observe(context: ?*anyopaque, event: Event) !void {
            if (event != .failure) return;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.failures += 1;
        }
    };
    var executor_state: ExecutorState = .{};
    try std.testing.expectError(
        error.PlanApprovalDenied,
        run(std.testing.allocator, &plan, .{ .execute_fn = ExecutorState.execute }, .{
            .approvals = &.{.{ .step_id = "approved", .approved = false }},
        }),
    );
    try std.testing.expectError(
        error.StepFailed,
        run(std.testing.allocator, &plan, .{ .execute_fn = ExecutorState.execute }, .{
            .approvals = &.{.{ .step_id = "approved", .approved = true }},
            .observer = .{ .context = &executor_state, .event_fn = ExecutorState.observe },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), executor_state.failures);
}

fn runPlanWithAllocator(gpa: std.mem.Allocator) !void {
    var plan = try Plan.init(gpa, "plan", &.{.{ .id = "step", .title = "Step" }}, .{});
    defer plan.deinit();
    const Execute = struct {
        fn run(_: ?*anyopaque, arena: std.mem.Allocator, _: StepContext) !StepResult {
            return .{ .output = try arena.dupe(u8, "output") };
        }
    };
    var outcome = try run(gpa, &plan, .{ .execute_fn = Execute.run }, .{});
    outcome.deinit();
}

fn pausePlanWithAllocator(gpa: std.mem.Allocator) !void {
    var plan = try Plan.init(gpa, "plan", &.{.{
        .id = "step",
        .title = "Step",
        .requires_approval = true,
    }}, .{});
    defer plan.deinit();
    const Execute = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: StepContext) !StepResult { // kcov-ignore: approval blocks execution
            return error.MustNotExecute; // kcov-ignore: approval blocks execution
        }
    };
    var outcome = try run(gpa, &plan, .{ .execute_fn = Execute.run }, .{});
    outcome.deinit();
}

test "planning ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runPlanWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        pausePlanWithAllocator,
        .{},
    );
}
