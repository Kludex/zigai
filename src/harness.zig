//! Reusable bounded agent compositions with owned artifacts and lifecycle hooks.
//!
//! A harness copies an existing `Agent` for each invocation. It layers typed
//! capabilities and preset instructions without owning provider/model state.

const std = @import("std");
const agent_spec = @import("agent_spec.zig");
const agent_types = @import("agent.zig");
const model_types = @import("model.zig");

const Agent = agent_types.Agent;

/// Reusable high-level composition.
pub const Preset = enum {
    coder,
    researcher,
    custom,
};

/// One explicitly enabled or disabled capability implementation.
pub const CapabilityConfig = struct {
    capability: agent_types.Capability,
    enabled: bool = true,
};

/// Bounded artifact produced by a completed run.
pub const Artifact = struct {
    name: []const u8,
    media_type: []const u8,
    bytes: []const u8,
};

/// Resource limits applied to each harness invocation.
pub const Limits = struct {
    max_model_requests: usize = 8,
    max_tool_calls: usize = 64,
    max_total_tokens: ?u64 = null,
    max_output_bytes: usize = 4 * 1024 * 1024,
    max_artifacts: usize = 64,
    max_artifact_bytes: usize = 16 * 1024 * 1024,
    max_total_artifact_bytes: usize = 64 * 1024 * 1024,
    timeout_ms: ?u64 = null,
};

/// Borrowed harness lifecycle observation.
pub const Event = union(enum) {
    start: Start,
    artifact: Artifact,
    end: End,
    failure: Failure,

    pub const Start = struct { preset: Preset, prompt: []const u8 };
    pub const End = struct {
        preset: Preset,
        model_requests: usize,
        artifact_count: usize,
    };
    pub const Failure = struct { preset: Preset, failure_name: []const u8 };
};

/// Fallible synchronous harness observer.
pub const Observer = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: Event) anyerror!void,

    pub fn emit(self: Observer, event: Event) !void {
        return self.event_fn(self.context, event);
    }
};

/// Callback that copies zero or more artifacts from a completed agent result.
pub const ArtifactProducer = struct {
    context: ?*anyopaque = null,
    produce_fn: *const fn (
        context: ?*anyopaque,
        collector: *ArtifactCollector,
        result: *const Agent.Result,
    ) anyerror!void,

    pub fn produce(self: ArtifactProducer, collector: *ArtifactCollector, result: *const Agent.Result) !void {
        return self.produce_fn(self.context, collector, result);
    }
};

/// Run-scoped artifact collector. Producer callbacks borrow this value only.
pub const ArtifactCollector = struct {
    arena: std.mem.Allocator,
    limits: Limits,
    observer: ?Observer,
    artifacts: std.ArrayList(Artifact) = .empty,
    total_bytes: usize = 0,

    pub fn add(
        self: *ArtifactCollector,
        name: []const u8,
        media_type: []const u8,
        bytes: []const u8,
    ) !void {
        if (name.len == 0 or name.len > 1024 or media_type.len == 0 or media_type.len > 255)
            return error.InvalidHarnessArtifact;
        if (std.mem.indexOfAny(u8, name, "\r\n\x00") != null or
            std.mem.indexOfAny(u8, media_type, "\r\n\x00") != null)
            return error.InvalidHarnessArtifact;
        if (self.artifacts.items.len >= self.limits.max_artifacts) return error.TooManyHarnessArtifacts;
        if (bytes.len > self.limits.max_artifact_bytes) return error.HarnessArtifactTooLarge;
        const total = std.math.add(usize, self.total_bytes, bytes.len) catch
            return error.HarnessArtifactTooLarge;
        if (total > self.limits.max_total_artifact_bytes) return error.HarnessArtifactTooLarge;
        const artifact = Artifact{
            .name = try self.arena.dupe(u8, name),
            .media_type = try self.arena.dupe(u8, media_type),
            .bytes = try self.arena.dupe(u8, bytes),
        };
        try self.artifacts.append(self.arena, artifact);
        self.total_bytes = total;
        if (self.observer) |observer| try observer.emit(.{ .artifact = artifact });
    }
};

/// Harness composition and run policy.
pub const Config = struct {
    preset: Preset = .custom,
    capabilities: []const CapabilityConfig = &.{},
    instructions: []const agent_types.Instruction = &.{},
    artifact_producers: []const ArtifactProducer = &.{},
    observer: ?Observer = null,
    limits: Limits = .{},
};

/// One arena-owned artifact set plus the normal owned agent result.
pub const Result = struct {
    artifact_arena: std.heap.ArenaAllocator,
    artifacts: []const Artifact,
    agent_result: Agent.Result,

    pub fn deinit(self: *Result) void {
        self.agent_result.deinit();
        self.artifact_arena.deinit();
        self.* = undefined;
    }
};

/// Provider-neutral reusable agent harness.
pub const Harness = struct {
    agent: *const Agent,
    config: Config,

    pub fn init(agent: *const Agent, config: Config) Harness {
        return .{ .agent = agent, .config = config };
    }

    /// Uses the agent assembled by a strict `agent_spec` resolution.
    pub fn fromResolved(resolved: *const agent_spec.Resolved, config: Config) Harness {
        return .{ .agent = &resolved.agent, .config = config };
    }

    pub fn run(
        self: Harness,
        gpa: std.mem.Allocator,
        prompt: []const u8,
        options: agent_types.RunOptions,
    ) !Result {
        try validateConfig(self.config);
        if (self.config.observer) |observer| try observer.emit(.{ .start = .{
            .preset = self.config.preset,
            .prompt = prompt,
        } });
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var configured = try self.configure(scratch.allocator());
        var run_options = options;
        const timeout_ms = if (self.config.limits.timeout_ms) |timeout|
            if (run_options.timeout_ms) |requested| @min(requested, timeout) else timeout
        else
            run_options.timeout_ms;
        const control = try model_types.RunControl.init(
            configured.io,
            configured.cancellation,
            timeout_ms,
        );
        run_options.timeout_ms = try control.remainingMilliseconds();
        var agent_result = configured.runWithOptions(gpa, prompt, run_options) catch |failure| {
            if (self.config.observer) |observer| try observer.emit(.{ .failure = .{
                .preset = self.config.preset,
                .failure_name = @errorName(failure),
            } });
            return failure;
        };
        errdefer agent_result.deinit();
        if (agent_result.output.len > self.config.limits.max_output_bytes)
            return error.HarnessOutputTooLarge;

        var artifact_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer artifact_arena.deinit();
        var collector = ArtifactCollector{
            .arena = artifact_arena.allocator(),
            .limits = self.config.limits,
            .observer = self.config.observer,
        };
        for (self.config.artifact_producers) |producer| {
            try control.invoke(void, invokeProducer, .{ producer, &collector, &agent_result });
        }
        const artifacts = try collector.artifacts.toOwnedSlice(artifact_arena.allocator());
        if (self.config.observer) |observer| try observer.emit(.{ .end = .{
            .preset = self.config.preset,
            .model_requests = agent_result.model_requests,
            .artifact_count = artifacts.len,
        } });
        return .{
            .artifact_arena = artifact_arena,
            .artifacts = artifacts,
            .agent_result = agent_result,
        };
    }

    fn configure(self: Harness, arena: std.mem.Allocator) !Agent {
        var configured = self.agent.*;
        const preset_instruction: ?[]const u8 = switch (self.config.preset) {
            .coder => "Work as a coding agent. Inspect context, make precise changes, verify them, and report evidence.",
            .researcher => "Work as a research agent. Gather evidence, distinguish facts from inference, and cite sources.",
            .custom => null,
        };
        const instruction_count = self.agent.instructions.len + self.config.instructions.len +
            @intFromBool(preset_instruction != null);
        const instructions = try arena.alloc(agent_types.Instruction, instruction_count);
        var instruction_index: usize = 0;
        for (self.agent.instructions, instructions[0..self.agent.instructions.len]) |source, *target| {
            target.* = source;
            instruction_index += 1;
        }
        if (preset_instruction) |text| {
            instructions[instruction_index] = .{ .text = text };
            instruction_index += 1;
        }
        for (self.config.instructions, instructions[instruction_index..]) |source, *target| target.* = source;
        configured.instructions = instructions;

        var enabled_count: usize = 0;
        for (self.config.capabilities) |selection| enabled_count += @intFromBool(selection.enabled);
        const capabilities = try arena.alloc(agent_types.Capability, self.agent.capabilities.len + enabled_count);
        @memcpy(capabilities[0..self.agent.capabilities.len], self.agent.capabilities);
        var capability_index = self.agent.capabilities.len;
        for (self.config.capabilities) |selection| {
            if (!selection.enabled) continue;
            capabilities[capability_index] = selection.capability;
            capability_index += 1;
        }
        configured.capabilities = capabilities;
        configured.limits.max_model_requests = @min(
            configured.limits.max_model_requests,
            self.config.limits.max_model_requests,
        );
        configured.limits.max_tool_calls = @min(
            configured.limits.max_tool_calls,
            self.config.limits.max_tool_calls,
        );
        if (self.config.limits.max_total_tokens) |maximum| {
            configured.limits.max_total_tokens = if (configured.limits.max_total_tokens) |current|
                @min(current, maximum)
            else
                maximum;
        }
        return configured;
    }
};

fn invokeProducer(
    producer: ArtifactProducer,
    collector: *ArtifactCollector,
    result: *const Agent.Result,
) !void {
    return producer.produce(collector, result);
}

fn validateConfig(config: Config) !void {
    const limits = config.limits;
    if (limits.max_model_requests == 0 or limits.max_tool_calls == 0 or
        limits.max_output_bytes == 0 or limits.max_artifacts == 0 or
        limits.max_artifact_bytes == 0 or limits.max_total_artifact_bytes == 0)
        return error.InvalidHarnessLimits;
    for (config.capabilities) |selection| if (selection.enabled and selection.capability.id == null)
        return error.InvalidHarnessCapability;
}

test "coder harness composes capabilities hooks and owned artifacts" {
    const State = struct {
        requests: usize = 0,
        starts: usize = 0,
        artifacts: usize = 0,
        ends: usize = 0,

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: model_types.ModelRequest,
        ) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(request_value.instructions.len >= 3);
            try std.testing.expect(std.mem.indexOf(u8, request_value.instructions[0], "coding agent") != null or
                std.mem.indexOf(u8, request_value.instructions[1], "coding agent") != null);
            self.requests += 1;
            return .{ .parts = &.{.{ .text = "artifact body" }} };
        }

        fn observe(context: ?*anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .start => self.starts += 1,
                .artifact => self.artifacts += 1,
                .end => self.ends += 1,
                .failure => {},
            }
        }

        fn produce(_: ?*anyopaque, collector: *ArtifactCollector, result: *const Agent.Result) !void {
            try collector.add("answer.txt", "text/plain", result.output);
        }
    };
    var state: State = .{};
    const base_instructions = [_]agent_types.Instruction{.{ .text = "base" }};
    const agent = Agent{
        .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
        .instructions = &base_instructions,
    };
    const capability_instructions = [_]agent_types.Instruction{.{ .text = "capability" }};
    const selections = [_]CapabilityConfig{
        .{ .capability = .{ .id = "workspace", .instructions = &capability_instructions } },
        .{ .capability = .{}, .enabled = false },
    };
    const custom_instructions = [_]agent_types.Instruction{.{ .text = "custom" }};
    const producers = [_]ArtifactProducer{.{ .produce_fn = State.produce }};
    var result = try (Harness.init(&agent, .{
        .preset = .coder,
        .capabilities = &selections,
        .instructions = &custom_instructions,
        .artifact_producers = &producers,
        .observer = .{ .context = &state, .event_fn = State.observe },
    })).run(std.testing.allocator, "build", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("answer.txt", result.artifacts[0].name);
    try std.testing.expectEqualStrings("artifact body", result.artifacts[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), state.requests);
    try std.testing.expectEqual(@as(usize, 1), state.starts);
    try std.testing.expectEqual(@as(usize, 1), state.artifacts);
    try std.testing.expectEqual(@as(usize, 1), state.ends);
}

test "harness limits failures and agent-spec integration are explicit" {
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "too long" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    try std.testing.expectError(
        error.InvalidHarnessLimits,
        (Harness.init(&agent, .{ .limits = .{ .max_artifacts = 0 } })).run(std.testing.allocator, "x", .{}),
    );
    try std.testing.expectError(
        error.InvalidHarnessCapability,
        (Harness.init(&agent, .{ .capabilities = &.{.{ .capability = .{} }} })).run(
            std.testing.allocator,
            "x",
            .{},
        ),
    );
    try std.testing.expectError(
        error.HarnessOutputTooLarge,
        (Harness.init(&agent, .{ .preset = .researcher, .limits = .{ .max_output_bytes = 1 } })).run(
            std.testing.allocator,
            "x",
            .{},
        ),
    );

    const resolved_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var resolved = agent_spec.Resolved{
        .arena = resolved_arena,
        .model_handle = .{ .model = agent.model },
        .agent = agent,
    };
    defer resolved.deinit();
    const harness = Harness.fromResolved(&resolved, .{});
    try std.testing.expect(harness.agent == &resolved.agent);
}

fn runHarnessWithAllocator(gpa: std.mem.Allocator) !void {
    const testing_types = @import("testing.zig");
    const parts = [_]model_types.Part{.{ .text = "owned" }};
    var scripted = testing_types.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    const agent = Agent{ .model = scripted.model() };
    const Producer = struct {
        fn produce(_: ?*anyopaque, collector: *ArtifactCollector, result: *const Agent.Result) !void {
            try collector.add("owned.txt", "text/plain", result.output);
        }
    };
    var result = try (Harness.init(&agent, .{
        .artifact_producers = &.{.{ .produce_fn = Producer.produce }},
    })).run(gpa, "prompt", .{});
    result.deinit();
}

test "harness invocation ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runHarnessWithAllocator,
        .{},
    );
}
