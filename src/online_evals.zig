//! Trace-correlated evaluation contracts for sampled production agent runs.

const std = @import("std");
const model_types = @import("model.zig");
const telemetry = @import("telemetry.zig");

pub const Error = error{
    InvalidSamplingPolicy,
    InvalidEvaluation,
};

/// Deterministic head sampling. Trace-ratio decisions remain stable anywhere
/// the same trace ID and policy are used.
pub const SamplingPolicy = union(enum) {
    always,
    never,
    trace_ratio: Ratio,

    pub const Ratio = struct {
        numerator: u64,
        denominator: u64,
    };

    pub fn validate(self: SamplingPolicy) !void {
        switch (self) {
            .always, .never => {},
            .trace_ratio => |ratio| {
                if (ratio.denominator == 0 or ratio.numerator > ratio.denominator)
                    return Error.InvalidSamplingPolicy;
            },
        }
    }

    pub fn includes(self: SamplingPolicy, trace_id: [16]u8) !bool {
        try self.validate();
        return switch (self) {
            .always => true,
            .never => false,
            .trace_ratio => |ratio| if (ratio.numerator == 0)
                false
            else if (ratio.numerator == ratio.denominator)
                true
            else
                std.mem.readInt(u64, trace_id[0..8], .big) % ratio.denominator < ratio.numerator,
        };
    }
};

/// Borrowed data from one completed sampled agent invocation.
pub const Observation = struct {
    trace: telemetry.SpanContext,
    prompt: []const u8,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        success: Success,
        failure: Failure,
    };

    pub const Success = struct {
        output: []const u8,
        usage: model_types.RunUsage,
        model_requests: usize,
    };

    pub const Failure = struct {
        name: []const u8,
    };
};

pub const Evaluation = struct {
    passed: bool,
    score: ?f64 = null,
    reason: ?[]const u8 = null,

    pub fn validate(self: Evaluation) !void {
        if (self.score) |score| {
            if (!std.math.isFinite(score) or score < 0 or score > 1)
                return Error.InvalidEvaluation;
        }
    }
};

/// Application evaluator. It runs only when a queue consumer explicitly
/// processes sampled observations, never from the agent lifecycle callback.
pub const Evaluator = struct {
    name: []const u8,
    context: *anyopaque,
    evaluateFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        observation: Observation,
    ) anyerror!Evaluation,

    pub fn evaluate(
        self: Evaluator,
        allocator: std.mem.Allocator,
        observation: Observation,
    ) !Evaluation {
        const result = try self.evaluateFn(self.context, allocator, observation);
        try result.validate();
        return result;
    }
};

/// Borrowed result delivered synchronously while queued work is processed.
pub const Result = struct {
    trace: telemetry.SpanContext,
    evaluator_name: []const u8,
    evaluation: Evaluation,
};

pub const ResultSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, result: Result) anyerror!void,

    pub fn emit(self: ResultSink, result: Result) !void {
        return self.emitFn(self.context, result);
    }
};

test "online eval sampling is deterministic and validates ratios" {
    const low = [_]u8{0} ** 16;
    var high = [_]u8{0xff} ** 16;
    high[7] = 3;

    try std.testing.expect(try @as(SamplingPolicy, .always).includes(low));
    try std.testing.expect(!try @as(SamplingPolicy, .never).includes(low));
    try std.testing.expect(!try (SamplingPolicy{ .trace_ratio = .{
        .numerator = 0,
        .denominator = 10,
    } }).includes(low));
    try std.testing.expect(try (SamplingPolicy{ .trace_ratio = .{
        .numerator = 10,
        .denominator = 10,
    } }).includes(high));
    const half = SamplingPolicy{ .trace_ratio = .{ .numerator = 1, .denominator = 2 } };
    try std.testing.expectEqual(try half.includes(high), try half.includes(high));
    try std.testing.expectError(
        Error.InvalidSamplingPolicy,
        (SamplingPolicy{ .trace_ratio = .{ .numerator = 1, .denominator = 0 } }).validate(),
    );
    try std.testing.expectError(
        Error.InvalidSamplingPolicy,
        (SamplingPolicy{ .trace_ratio = .{ .numerator = 2, .denominator = 1 } }).includes(low),
    );
}

test "online evaluator validates results and delegates to sinks" {
    const State = struct {
        evaluations: usize = 0,
        results: usize = 0,

        fn evaluate(context: *anyopaque, _: std.mem.Allocator, observation: Observation) !Evaluation {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.evaluations += 1;
            try std.testing.expectEqualStrings("prompt", observation.prompt);
            return .{ .passed = true, .score = 0.75, .reason = "good" };
        }

        fn invalid(_: *anyopaque, _: std.mem.Allocator, _: Observation) !Evaluation {
            return .{ .passed = false, .score = std.math.nan(f64) };
        }

        fn emit(context: *anyopaque, result: Result) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.results += 1;
            try std.testing.expectEqualStrings("quality", result.evaluator_name);
            try std.testing.expect(result.evaluation.passed);
        }
    };
    var state: State = .{};
    const observation = Observation{
        .trace = .{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 },
        .prompt = "prompt",
        .outcome = .{ .success = .{ .output = "output", .usage = .{}, .model_requests = 1 } },
    };
    const evaluator = Evaluator{ .name = "quality", .context = &state, .evaluateFn = State.evaluate };
    const evaluation = try evaluator.evaluate(std.testing.allocator, observation);
    try (ResultSink{ .context = &state, .emitFn = State.emit }).emit(.{
        .trace = observation.trace,
        .evaluator_name = evaluator.name,
        .evaluation = evaluation,
    });
    try std.testing.expectEqual(@as(usize, 1), state.evaluations);
    try std.testing.expectEqual(@as(usize, 1), state.results);
    try std.testing.expectError(
        Error.InvalidEvaluation,
        (Evaluator{ .name = "invalid", .context = &state, .evaluateFn = State.invalid }).evaluate(
            std.testing.allocator,
            observation,
        ),
    );
    try std.testing.expectError(
        Error.InvalidEvaluation,
        (Evaluation{ .passed = false, .score = -0.1 }).validate(),
    );
    try std.testing.expectError(
        Error.InvalidEvaluation,
        (Evaluation{ .passed = false, .score = 1.1 }).validate(),
    );
    try (Evaluation{ .passed = true }).validate();
}
