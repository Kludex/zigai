//! Trace-correlated evaluation contracts for sampled production agent runs.

const std = @import("std");
const model_types = @import("model.zig");
const telemetry = @import("telemetry.zig");

pub const Error = error{
    InvalidSamplingPolicy,
    InvalidEvaluation,
    InvalidTraceContext,
    OnlineEvaluationRunNotStarted,
    OnlineEvaluationRunAlreadyStarted,
    OnlineEvaluationRunAlreadyFinished,
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

pub const Queue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sampling: SamplingPolicy,
    evaluators: []const Evaluator,
    result_sink: ResultSink,
    metric_exporter: ?telemetry.Exporter,
    max_pending: usize,
    max_content_bytes: usize,
    overflow: OverflowPolicy,
    fail_open: bool,

    mutex: std.Io.Mutex = .init,
    flush_mutex: std.Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,
    state: State = .open,
    sampled: std.atomic.Value(usize) = .init(0),
    skipped: std.atomic.Value(usize) = .init(0),
    dropped_backpressure: std.atomic.Value(usize) = .init(0),
    dropped_allocation: std.atomic.Value(usize) = .init(0),
    dropped_contention: std.atomic.Value(usize) = .init(0),
    dropped_closed: usize = 0,
    dropped_processing: usize = 0,
    reported_backpressure: usize = 0,
    reported_allocation: usize = 0,
    reported_contention: usize = 0,
    reported_closed: usize = 0,
    reported_processing: usize = 0,

    pub const OverflowPolicy = enum { drop_newest, drop_oldest };
    pub const State = enum { open, closed };

    pub const Options = struct {
        sampling: SamplingPolicy = .always,
        max_pending: usize = 128,
        max_content_bytes: usize = 16 * 1_024,
        overflow: OverflowPolicy = .drop_newest,
        /// Processing and metric failures are isolated when true. Admission
        /// allocation failures are always counted and isolated from agents.
        fail_open: bool = true,
        metric_exporter: ?telemetry.Exporter = null,
    };

    pub const Stats = struct {
        pending: usize,
        sampled: usize,
        skipped: usize,
        dropped_backpressure: usize,
        dropped_allocation: usize,
        dropped_contention: usize,
        dropped_closed: usize,
        dropped_processing: usize,
    };

    pub const FlushResult = struct {
        observations: usize = 0,
        evaluations: usize = 0,
        failed: usize = 0,
        dropped_reported: usize = 0,
    };

    const Record = struct {
        arena: std.heap.ArenaAllocator,
        observation: Observation,

        fn init(
            allocator: std.mem.Allocator,
            max_content_bytes: usize,
            trace: telemetry.SpanContext,
            prompt: []const u8,
            outcome: Observation.Outcome,
        ) !Record {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const memory = arena.allocator();
            const owned_outcome: Observation.Outcome = switch (outcome) {
                .success => |success| .{ .success = .{
                    .output = try memory.dupe(u8, utf8Prefix(success.output, max_content_bytes)),
                    .usage = try success.usage.dupe(memory),
                    .model_requests = success.model_requests,
                } },
                .failure => |failure| .{ .failure = .{
                    .name = try memory.dupe(u8, utf8Prefix(failure.name, max_content_bytes)),
                } },
            };
            const observation = Observation{
                .trace = trace,
                .prompt = try memory.dupe(u8, utf8Prefix(prompt, max_content_bytes)),
                .outcome = owned_outcome,
            };
            return .{ .arena = arena, .observation = observation };
        }

        fn deinit(self: *Record) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        evaluators: []const Evaluator,
        result_sink: ResultSink,
        options: Options,
    ) !Queue {
        try options.sampling.validate();
        var records: std.ArrayList(Record) = .empty;
        errdefer records.deinit(allocator);
        try records.ensureTotalCapacityPrecise(allocator, options.max_pending);
        return .{
            .allocator = allocator,
            .io = io,
            .sampling = options.sampling,
            .evaluators = evaluators,
            .result_sink = result_sink,
            .metric_exporter = options.metric_exporter,
            .max_pending = options.max_pending,
            .max_content_bytes = options.max_content_bytes,
            .overflow = options.overflow,
            .fail_open = options.fail_open,
            .records = records,
        };
    }

    /// Starts one isolated producer state. The queue must outlive the run.
    pub fn start(self: *Queue, trace: telemetry.SpanContext) !Run {
        if (!trace.isValid()) return Error.InvalidTraceContext;
        const selected = self.sampling.includes(trace.trace_id) catch unreachable;
        if (selected)
            saturatingAtomicAdd(&self.sampled, 1)
        else
            saturatingAtomicAdd(&self.skipped, 1);
        return .{ .queue = self, .trace = trace, .sampled = selected };
    }

    pub fn stats(self: *Queue) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .pending = self.records.items.len,
            .sampled = self.sampled.load(.monotonic),
            .skipped = self.skipped.load(.monotonic),
            .dropped_backpressure = self.dropped_backpressure.load(.monotonic),
            .dropped_allocation = self.dropped_allocation.load(.monotonic),
            .dropped_contention = self.dropped_contention.load(.monotonic),
            .dropped_closed = self.dropped_closed,
            .dropped_processing = self.dropped_processing,
        };
    }

    pub fn close(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .closed;
    }

    /// Runs evaluators and result sinks outside the agent path. Calls are
    /// serialized, while producers may continue admitting the next batch.
    pub fn flush(self: *Queue) !FlushResult {
        self.flush_mutex.lockUncancelable(self.io);
        defer self.flush_mutex.unlock(self.io);

        var replacement: std.ArrayList(Record) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacityPrecise(self.allocator, self.max_pending);
        self.mutex.lockUncancelable(self.io);
        var batch = self.records;
        self.records = replacement;
        replacement = .empty;
        self.mutex.unlock(self.io);
        defer batch.deinit(self.allocator);

        var result: FlushResult = .{};
        for (batch.items, 0..) |*record, record_index| {
            result.observations += 1;
            for (self.evaluators, 0..) |evaluator, evaluator_index| {
                const evaluation = evaluator.evaluate(record.arena.allocator(), record.observation) catch |failure| {
                    result.failed += 1;
                    self.incrementProcessingDrops(1);
                    if (!self.fail_open) {
                        const remaining = remainingEvaluations(
                            self.evaluators.len,
                            batch.items.len,
                            record_index,
                            evaluator_index,
                        );
                        self.incrementProcessingDrops(remaining);
                        record.deinit();
                        for (batch.items[record_index + 1 ..]) |*pending| pending.deinit();
                        return failure;
                    }
                    continue;
                };
                self.result_sink.emit(.{
                    .trace = record.observation.trace,
                    .evaluator_name = evaluator.name,
                    .evaluation = evaluation,
                }) catch |failure| {
                    result.failed += 1;
                    self.incrementProcessingDrops(1);
                    if (!self.fail_open) {
                        const remaining = remainingEvaluations(
                            self.evaluators.len,
                            batch.items.len,
                            record_index,
                            evaluator_index,
                        );
                        self.incrementProcessingDrops(remaining);
                        record.deinit();
                        for (batch.items[record_index + 1 ..]) |*pending| pending.deinit();
                        return failure;
                    }
                    continue;
                };
                result.evaluations += 1;
            }
            record.deinit();
        }
        result.dropped_reported = try self.reportDrops();
        return result;
    }

    pub fn shutdown(self: *Queue) !FlushResult {
        self.close();
        return self.flush();
    }

    /// Discards pending observations. Call `shutdown` first for processing.
    pub fn deinit(self: *Queue) void {
        self.close();
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    fn enqueue(
        self: *Queue,
        trace: telemetry.SpanContext,
        prompt: []const u8,
        outcome: Observation.Outcome,
    ) void {
        if (self.max_pending == 0) {
            saturatingAtomicAdd(&self.dropped_backpressure, 1);
            return;
        }
        var record = Record.init(
            self.allocator,
            self.max_content_bytes,
            trace,
            prompt,
            outcome,
        ) catch {
            saturatingAtomicAdd(&self.dropped_allocation, 1);
            return;
        };
        if (!self.mutex.tryLock()) {
            record.deinit();
            saturatingAtomicAdd(&self.dropped_contention, 1);
            return;
        }
        defer self.mutex.unlock(self.io);
        if (self.state == .closed) {
            record.deinit();
            self.dropped_closed +|= 1;
            return;
        }
        if (self.records.items.len >= self.max_pending) {
            saturatingAtomicAdd(&self.dropped_backpressure, 1);
            switch (self.overflow) {
                .drop_newest => {
                    record.deinit();
                    return;
                },
                .drop_oldest => if (self.records.items.len != 0) {
                    var oldest = self.records.orderedRemove(0);
                    oldest.deinit();
                } else {
                    record.deinit(); // kcov-ignore: positive-capacity overflow always contains an oldest record
                    return;
                },
            }
        }
        self.records.appendAssumeCapacity(record);
    }

    fn incrementProcessingDrops(self: *Queue, count: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropped_processing +|= count;
    }

    fn reportDrops(self: *Queue) !usize {
        const exporter = self.metric_exporter orelse return 0;
        self.mutex.lockUncancelable(self.io);
        const backpressure = self.dropped_backpressure.load(.monotonic) -| self.reported_backpressure;
        const allocation = self.dropped_allocation.load(.monotonic) -| self.reported_allocation;
        const contention = self.dropped_contention.load(.monotonic) -| self.reported_contention;
        const closed = self.dropped_closed -| self.reported_closed;
        const processing = self.dropped_processing -| self.reported_processing;
        self.mutex.unlock(self.io);

        var reported: usize = 0;
        reported +|= try self.reportDropReason(exporter, .backpressure, backpressure);
        reported +|= try self.reportDropReason(exporter, .allocation, allocation);
        reported +|= try self.reportDropReason(exporter, .contention, contention);
        reported +|= try self.reportDropReason(exporter, .closed, closed);
        reported +|= try self.reportDropReason(exporter, .processing, processing);
        return reported;
    }

    const DropReason = enum { backpressure, allocation, contention, closed, processing };

    fn reportDropReason(
        self: *Queue,
        exporter: telemetry.Exporter,
        reason: DropReason,
        count: usize,
    ) !usize {
        if (count == 0) return 0;
        exporter.metric(.{
            .name = "zigai.online_eval.dropped",
            .kind = .counter,
            .value = @floatFromInt(count),
            .unit = "{work}",
            .attributes = &.{.{ .key = "reason", .value = .{ .string = @tagName(reason) } }},
        }) catch |failure| {
            if (!self.fail_open) return failure;
            return 0;
        };
        self.mutex.lockUncancelable(self.io);
        switch (reason) {
            .backpressure => self.reported_backpressure += count,
            .allocation => self.reported_allocation += count,
            .contention => self.reported_contention += count,
            .closed => self.reported_closed += count,
            .processing => self.reported_processing += count,
        }
        self.mutex.unlock(self.io);
        return count;
    }
};

/// Per-agent-invocation producer state. It only copies one terminal
/// observation into the bounded queue; evaluator callbacks run during flush.
pub const Run = struct {
    queue: *Queue,
    trace: telemetry.SpanContext,
    sampled: bool,
    prompt: ?[]const u8 = null,
    finished: bool = false,

    pub fn begin(self: *Run, prompt: []const u8) !void {
        if (self.finished) return Error.OnlineEvaluationRunAlreadyFinished;
        if (self.prompt != null) return Error.OnlineEvaluationRunAlreadyStarted;
        self.prompt = prompt;
    }

    pub fn succeed(
        self: *Run,
        output: []const u8,
        usage: model_types.RunUsage,
        model_requests: usize,
    ) !void {
        const prompt = try self.finish();
        if (self.sampled) self.queue.enqueue(self.trace, prompt, .{ .success = .{
            .output = output,
            .usage = usage,
            .model_requests = model_requests,
        } });
    }

    pub fn fail(self: *Run, failure: anyerror) !void {
        const prompt = try self.finish();
        if (self.sampled) self.queue.enqueue(self.trace, prompt, .{ .failure = .{
            .name = @errorName(failure),
        } });
    }

    fn finish(self: *Run) ![]const u8 {
        if (self.finished) return Error.OnlineEvaluationRunAlreadyFinished;
        const prompt = self.prompt orelse return Error.OnlineEvaluationRunNotStarted;
        self.finished = true;
        return prompt;
    }
};

fn saturatingAtomicAdd(counter: *std.atomic.Value(usize), count: usize) void {
    var current = counter.load(.monotonic);
    while (true) {
        const next = current +| count;
        current = counter.cmpxchgWeak(current, next, .monotonic, .monotonic) orelse return;
    } // kcov-ignore: retry requires an architecture-dependent weak-CAS race or spurious failure
}

fn remainingEvaluations(
    evaluators: usize,
    records: usize,
    record_index: usize,
    evaluator_index: usize,
) usize {
    return (evaluators -| (evaluator_index + 1)) +|
        ((records -| (record_index + 1)) *| evaluators);
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

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

const QueueTestState = struct {
    evaluated: usize = 0,
    emitted: usize = 0,
    metrics: usize = 0,
    dropped: usize = 0,
    first_prompt: ?u8 = null,
    last_prompt: ?u8 = null,
    saw_success: bool = false,
    saw_failure: bool = false,
    saw_backpressure: bool = false,
    saw_allocation: bool = false,
    saw_contention: bool = false,
    saw_closed: bool = false,
    saw_processing: bool = false,
    fail_evaluations: usize = 0,
    invalid_evaluations: usize = 0,
    fail_sinks: usize = 0,
    fail_metrics: usize = 0,

    fn evaluator(self: *QueueTestState, name: []const u8) Evaluator {
        return .{ .name = name, .context = self, .evaluateFn = evaluate };
    }

    fn sink(self: *QueueTestState) ResultSink {
        return .{ .context = self, .emitFn = emit };
    }

    fn exporter(self: *QueueTestState) telemetry.Exporter {
        return .{ .context = self, .spanFn = span, .metricFn = metric };
    }

    fn evaluate(context: *anyopaque, _: std.mem.Allocator, observation: Observation) !Evaluation {
        const self: *QueueTestState = @ptrCast(@alignCast(context));
        if (self.fail_evaluations != 0) {
            self.fail_evaluations -= 1;
            return error.TestEvaluationFailure;
        }
        if (self.invalid_evaluations != 0) {
            self.invalid_evaluations -= 1;
            return .{ .passed = false, .score = 2 };
        }
        self.evaluated += 1;
        if (observation.prompt.len != 0) {
            if (self.first_prompt == null) self.first_prompt = observation.prompt[0];
            self.last_prompt = observation.prompt[0];
        }
        switch (observation.outcome) {
            .success => |success| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(success.output));
                self.saw_success = true;
            },
            .failure => |failure| {
                try std.testing.expectEqualStrings("Test", failure.name);
                self.saw_failure = true;
            },
        }
        return .{ .passed = true, .score = 1 };
    }

    fn emit(context: *anyopaque, _: Result) !void {
        const self: *QueueTestState = @ptrCast(@alignCast(context));
        if (self.fail_sinks != 0) {
            self.fail_sinks -= 1;
            return error.TestSinkFailure;
        }
        self.emitted += 1;
    }

    fn span(_: *anyopaque, _: telemetry.Span) !void {} // kcov-ignore: dropped-work reporting emits only metrics

    fn metric(context: *anyopaque, value: telemetry.Metric) !void {
        const self: *QueueTestState = @ptrCast(@alignCast(context));
        if (self.fail_metrics != 0) {
            self.fail_metrics -= 1;
            return error.TestMetricFailure;
        }
        self.metrics += 1;
        if (!std.mem.eql(u8, value.name, "zigai.online_eval.dropped")) return;
        self.dropped += @intFromFloat(value.value);
        const reason = value.attributes[0].value.string;
        self.saw_backpressure = self.saw_backpressure or std.mem.eql(u8, reason, "backpressure");
        self.saw_allocation = self.saw_allocation or std.mem.eql(u8, reason, "allocation");
        self.saw_contention = self.saw_contention or std.mem.eql(u8, reason, "contention");
        self.saw_closed = self.saw_closed or std.mem.eql(u8, reason, "closed");
        self.saw_processing = self.saw_processing or std.mem.eql(u8, reason, "processing");
    }
};

test "online eval queue owns bounded successful and failed observations" {
    var state: QueueTestState = .{};
    const evaluators = [_]Evaluator{state.evaluator("quality")};
    var queue = try Queue.init(std.testing.allocator, std.testing.io, &evaluators, state.sink(), .{
        .max_content_bytes = 4,
    });
    defer queue.deinit();
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var prompt = "prompt".*;
    var output = "a€b".*;
    const details = [_]model_types.UsageDetail{.{ .name = "owned", .value = 2 }};
    var success = try queue.start(trace);
    try success.begin(&prompt);
    try std.testing.expectError(Error.OnlineEvaluationRunAlreadyStarted, success.begin("again"));
    try success.succeed(&output, .{ .details = &details }, 2);
    @memset(&prompt, 'x');
    @memset(&output, 'x');

    var failed = try queue.start(trace);
    try failed.begin("failure");
    try failed.fail(error.TestRunFailure);
    const result = try queue.flush();
    try std.testing.expectEqual(@as(usize, 2), result.observations);
    try std.testing.expectEqual(@as(usize, 2), result.evaluations);
    try std.testing.expect(state.saw_success);
    try std.testing.expect(state.saw_failure);
    try std.testing.expectEqual(@as(usize, 0), queue.stats().pending);

    try std.testing.expectError(Error.OnlineEvaluationRunAlreadyFinished, success.succeed("again", .{}, 0));
    try std.testing.expectError(Error.OnlineEvaluationRunAlreadyFinished, success.begin("again"));
    var not_started = try queue.start(trace);
    try std.testing.expectError(Error.OnlineEvaluationRunNotStarted, not_started.fail(error.TestRunFailure));
}

test "online eval queue samples and applies saturation policies" {
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var skipped_state: QueueTestState = .{};
    var skipped = try Queue.init(std.testing.allocator, std.testing.io, &.{}, skipped_state.sink(), .{
        .sampling = .never,
    });
    defer skipped.deinit();
    var skipped_run = try skipped.start(trace);
    try skipped_run.begin("skip");
    try skipped_run.succeed("output", .{}, 1);
    try std.testing.expectEqual(@as(usize, 1), skipped.stats().skipped);
    try std.testing.expectEqual(@as(usize, 0), (try skipped.flush()).observations);

    var newest_state: QueueTestState = .{};
    const newest_evaluators = [_]Evaluator{newest_state.evaluator("quality")};
    var newest = try Queue.init(std.testing.allocator, std.testing.io, &newest_evaluators, newest_state.sink(), .{
        .max_pending = 1,
        .metric_exporter = newest_state.exporter(),
    });
    defer newest.deinit();
    for ([_][]const u8{ "a", "b" }) |prompt| {
        var run = try newest.start(trace);
        try run.begin(prompt);
        try run.succeed("output", .{}, 1);
    }
    _ = try newest.flush();
    try std.testing.expectEqual(@as(?u8, 'a'), newest_state.first_prompt);
    try std.testing.expect(newest_state.saw_backpressure);

    var oldest_state: QueueTestState = .{};
    const oldest_evaluators = [_]Evaluator{oldest_state.evaluator("quality")};
    var oldest = try Queue.init(std.testing.allocator, std.testing.io, &oldest_evaluators, oldest_state.sink(), .{
        .max_pending = 1,
        .overflow = .drop_oldest,
    });
    defer oldest.deinit();
    for ([_][]const u8{ "a", "b" }) |prompt| {
        var run = try oldest.start(trace);
        try run.begin(prompt);
        try run.succeed("output", .{}, 1);
    }
    _ = try oldest.flush();
    try std.testing.expectEqual(@as(?u8, 'b'), oldest_state.first_prompt);

    var zero_state: QueueTestState = .{};
    var zero = try Queue.init(std.testing.allocator, std.testing.io, &.{}, zero_state.sink(), .{
        .max_pending = 0,
        .overflow = .drop_oldest,
    });
    defer zero.deinit();
    var zero_run = try zero.start(trace);
    try zero_run.begin("zero");
    try zero_run.succeed("output", .{}, 1);
    try std.testing.expectEqual(@as(usize, 1), zero.stats().dropped_backpressure);
}

test "online eval queue isolates allocation closure and processing failures" {
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var allocation_state: QueueTestState = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var allocation = try Queue.init(failing.allocator(), std.testing.io, &.{}, allocation_state.sink(), .{
        .max_pending = 1,
        .metric_exporter = allocation_state.exporter(),
    });
    defer allocation.deinit();
    failing.fail_index = failing.alloc_index;
    var allocation_run = try allocation.start(trace);
    try allocation_run.begin("allocation");
    try allocation_run.succeed("output", .{}, 1);
    failing.fail_index = std.math.maxInt(usize);
    _ = try allocation.flush();
    try std.testing.expectEqual(@as(usize, 1), allocation.stats().dropped_allocation);
    try std.testing.expect(allocation_state.saw_allocation);

    allocation.close();
    var closed_run = try allocation.start(trace);
    try closed_run.begin("closed");
    try closed_run.succeed("output", .{}, 1);
    _ = try allocation.flush();
    try std.testing.expect(allocation_state.saw_closed);

    var contention_state: QueueTestState = .{};
    var contention = try Queue.init(std.testing.allocator, std.testing.io, &.{}, contention_state.sink(), .{
        .max_pending = 1,
        .metric_exporter = contention_state.exporter(),
    });
    defer contention.deinit();
    var contention_run = try contention.start(trace);
    try contention_run.begin("contention");
    contention.mutex.lockUncancelable(std.testing.io);
    try contention_run.succeed("output", .{}, 1);
    contention.mutex.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), contention.stats().dropped_contention);
    _ = try contention.flush();
    try std.testing.expect(contention_state.saw_contention);

    var open_state: QueueTestState = .{ .invalid_evaluations = 1, .fail_sinks = 1 };
    const open_evaluators = [_]Evaluator{
        open_state.evaluator("first"),
        open_state.evaluator("second"),
    };
    var open = try Queue.init(std.testing.allocator, std.testing.io, &open_evaluators, open_state.sink(), .{
        .metric_exporter = open_state.exporter(),
    });
    defer open.deinit();
    var open_run = try open.start(trace);
    try open_run.begin("open");
    try open_run.succeed("output", .{}, 1);
    const open_result = try open.flush();
    try std.testing.expectEqual(@as(usize, 2), open_result.failed);
    try std.testing.expectEqual(@as(usize, 2), open.stats().dropped_processing);
    try std.testing.expect(open_state.saw_processing);

    var fail_state: QueueTestState = .{ .fail_evaluations = 1 };
    const fail_evaluators = [_]Evaluator{
        fail_state.evaluator("first"),
        fail_state.evaluator("second"),
    };
    var fail_closed = try Queue.init(std.testing.allocator, std.testing.io, &fail_evaluators, fail_state.sink(), .{
        .fail_open = false,
        .metric_exporter = fail_state.exporter(),
    });
    defer fail_closed.deinit();
    for (0..2) |_| {
        var run = try fail_closed.start(trace);
        try run.begin("fail");
        try run.succeed("output", .{}, 1);
    }
    try std.testing.expectError(error.TestEvaluationFailure, fail_closed.flush());
    try std.testing.expectEqual(@as(usize, 4), fail_closed.stats().dropped_processing);
    try std.testing.expectEqual(@as(usize, 4), (try fail_closed.flush()).dropped_reported);

    var sink_state: QueueTestState = .{ .fail_sinks = 1 };
    const sink_evaluators = [_]Evaluator{
        sink_state.evaluator("first"),
        sink_state.evaluator("second"),
    };
    var sink_closed = try Queue.init(std.testing.allocator, std.testing.io, &sink_evaluators, sink_state.sink(), .{
        .fail_open = false,
    });
    defer sink_closed.deinit();
    var sink_run = try sink_closed.start(trace);
    try sink_run.begin("sink");
    try sink_run.succeed("output", .{}, 1);
    try std.testing.expectError(error.TestSinkFailure, sink_closed.flush());
    try std.testing.expectEqual(@as(usize, 2), sink_closed.stats().dropped_processing);
}

test "online eval queue retries dropped metrics and shuts down" {
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var state: QueueTestState = .{ .fail_metrics = 1 };
    var queue = try Queue.init(std.testing.allocator, std.testing.io, &.{}, state.sink(), .{
        .max_pending = 0,
        .metric_exporter = state.exporter(),
    });
    defer queue.deinit();
    var run = try queue.start(trace);
    try run.begin("drop");
    try run.succeed("output", .{}, 1);
    try std.testing.expectEqual(@as(usize, 0), (try queue.flush()).dropped_reported);
    try std.testing.expectEqual(@as(usize, 1), (try queue.shutdown()).dropped_reported);

    var fail_state: QueueTestState = .{ .fail_metrics = 1 };
    var fail_closed = try Queue.init(std.testing.allocator, std.testing.io, &.{}, fail_state.sink(), .{
        .max_pending = 0,
        .metric_exporter = fail_state.exporter(),
        .fail_open = false,
    });
    defer fail_closed.deinit();
    var fail_run = try fail_closed.start(trace);
    try fail_run.begin("drop");
    try fail_run.succeed("output", .{}, 1);
    try std.testing.expectError(error.TestMetricFailure, fail_closed.flush());
    try std.testing.expectEqual(@as(usize, 1), (try fail_closed.shutdown()).dropped_reported);
}

test "online eval queue serializes concurrent sampled producers" {
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var state: QueueTestState = .{};
    const evaluators = [_]Evaluator{state.evaluator("quality")};
    var queue = try Queue.init(std.heap.smp_allocator, io, &evaluators, state.sink(), .{});
    defer queue.deinit();
    const Producer = struct {
        fn run(target: *Queue, context: telemetry.SpanContext, prompt: []const u8) !void {
            var producer = try target.start(context);
            try producer.begin(prompt);
            try producer.succeed("output", .{}, 1);
        }
    };
    var first = try io.concurrent(Producer.run, .{ &queue, trace, "a" });
    var second = try io.concurrent(Producer.run, .{ &queue, trace, "b" });
    try first.await(io);
    try second.await(io);
    const result = try queue.shutdown();
    try std.testing.expectEqual(@as(usize, 2), result.observations);
    try std.testing.expectEqual(@as(usize, 2), result.evaluations);
}

test "online eval queue deinit discards pending observations" {
    const trace = telemetry.SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var state: QueueTestState = .{};
    const evaluators = [_]Evaluator{state.evaluator("quality")};
    var queue = try Queue.init(std.testing.allocator, std.testing.io, &evaluators, state.sink(), .{});
    var run = try queue.start(trace);
    try run.begin("pending");
    try run.succeed("output", .{}, 1);
    queue.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.evaluated);
}

test "online eval queue validates construction and trace identity" {
    var state: QueueTestState = .{};
    try std.testing.expectError(
        Error.InvalidSamplingPolicy,
        Queue.init(std.testing.allocator, std.testing.io, &.{}, state.sink(), .{
            .sampling = .{ .trace_ratio = .{ .numerator = 1, .denominator = 0 } },
        }),
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        Queue.init(failing.allocator(), std.testing.io, &.{}, state.sink(), .{ .max_pending = 1 }),
    );
    var queue = try Queue.init(std.testing.allocator, std.testing.io, &.{}, state.sink(), .{});
    defer queue.deinit();
    try std.testing.expectError(Error.InvalidTraceContext, queue.start(.{
        .trace_id = [_]u8{0} ** 16,
        .span_id = [_]u8{0} ** 8,
    }));
}
