//! Provider-neutral embedding requests, bounded batching, retries, and owned results.
//!
//! Models own provider wire formats. `Embedder` validates borrowed text, runs
//! bounded source-order batches, and copies every vector into one result arena.

const std = @import("std");
const model_types = @import("../model.zig");
const usage_types = @import("../usage.zig");

/// Whether text is embedded for lookup or indexing.
pub const InputType = enum {
    query,
    document,
};

/// Stable embedding-layer failures.
pub const Error = error{
    EmptyInputs,
    TooManyInputs,
    EmptyInput,
    InputTooLarge,
    TotalInputTooLarge,
    InvalidBatchSize,
    InvalidDimensions,
    TooManyBatches,
    ResponseCountMismatch,
    ResponseDimensionsMismatch,
    InvalidVectorValue,
    RetryBackoffRequiresIo,
    RetryBudgetExceeded,
    UsageOverflow,
};

/// Hard memory and work bounds applied before provider I/O.
pub const Limits = struct {
    max_inputs: usize = 1_024,
    max_input_bytes: usize = 1024 * 1024,
    max_total_input_bytes: usize = 16 * 1024 * 1024,
    max_dimensions: usize = 65_536,
    max_batches: usize = 1_024,

    pub fn validate(self: Limits) Error!void {
        if (self.max_inputs == 0 or self.max_input_bytes == 0 or
            self.max_total_input_bytes == 0 or self.max_dimensions == 0 or self.max_batches == 0)
            return Error.InvalidBatchSize;
    }
};

/// One provider request. Input slices remain borrowed for the call.
pub const Request = struct {
    inputs: []const []const u8,
    input_type: InputType,
    dimensions: ?usize = null,
    timeout_ms: ?u64 = null,
    cancellation: ?*const model_types.CancellationToken = null,
};

/// Arena-owned response from one provider batch.
pub const BatchResult = struct {
    arena: std.heap.ArenaAllocator,
    vectors: []const []const f32,
    usage: usage_types.RequestUsage = .{},
    response_id: ?[]const u8 = null,

    pub fn deinit(self: *BatchResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Small provider-neutral embedding model vtable.
pub const Model = struct {
    context: *anyopaque,
    provider_name: []const u8,
    model_name: []const u8,
    max_batch_size: usize,
    max_dimensions: ?usize = null,
    embed_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        request: Request,
    ) anyerror!BatchResult,
    is_retryable_fn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    pub fn embed(self: Model, gpa: std.mem.Allocator, request: Request) !BatchResult {
        return self.embed_fn(self.context, gpa, request);
    }

    pub fn isRetryable(self: Model, failure: anyerror) bool {
        if (self.is_retryable_fn) |classify| return classify(self.context, failure);
        return switch (failure) {
            error.ProviderConnectionError,
            error.ProviderRateLimited,
            error.ProviderServerError,
            error.RequestTimedOut,
            => true,
            else => false,
        };
    }
};

/// Retry observation before an interruptible full-jitter delay.
pub const RetryEvent = struct {
    batch_index: usize,
    retry_number: usize,
    failure: anyerror,
    delay_ms: u64,
    total_delay_ms: u64,
};

/// Fallible retry observer. It must not retain the borrowed event.
pub const RetryHook = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: RetryEvent) anyerror!void,

    pub fn emit(self: RetryHook, event: RetryEvent) !void {
        return self.event_fn(self.context, event);
    }
};

/// Bounded full-jitter retry policy shared by every batch.
pub const RetryPolicy = struct {
    max_retries: usize = 2,
    initial_delay_ms: u64 = 100,
    maximum_delay_ms: u64 = 2_000,
    max_total_delay_ms: ?u64 = 30_000,
    before_retry: ?RetryHook = null,
};

/// Per-call controls and dimension/batch overrides.
pub const Options = struct {
    dimensions: ?usize = null,
    max_batch_size: ?usize = null,
    timeout_ms: ?u64 = null,
    cancellation: ?*const model_types.CancellationToken = null,
    io: ?std.Io = null,
    retry: RetryPolicy = .{},
};

/// Arena-owned vectors and metadata for one complete embedding operation.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    vectors: []const []const f32,
    inputs: []const []const u8,
    input_type: InputType,
    dimensions: usize,
    provider_name: []const u8,
    model_name: []const u8,
    usage: usage_types.RunUsage,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Finds the first vector whose copied input exactly matches `input`.
    pub fn vectorFor(self: *const Result, input: []const u8) ?[]const f32 {
        for (self.inputs, self.vectors) |candidate, vector| {
            if (std.mem.eql(u8, candidate, input)) return vector;
        }
        return null;
    }
};

/// High-level bounded embedding runner.
pub const Embedder = struct {
    model: Model,
    limits: Limits = .{},

    pub fn embedQuery(
        self: Embedder,
        gpa: std.mem.Allocator,
        input: []const u8,
        options: Options,
    ) !Result {
        return self.embed(gpa, &.{input}, .query, options);
    }

    pub fn embedDocuments(
        self: Embedder,
        gpa: std.mem.Allocator,
        inputs: []const []const u8,
        options: Options,
    ) !Result {
        return self.embed(gpa, inputs, .document, options);
    }

    pub fn embed(
        self: Embedder,
        gpa: std.mem.Allocator,
        inputs: []const []const u8,
        input_type: InputType,
        options: Options,
    ) !Result {
        try self.validate(inputs, options);
        const batch_size = @min(options.max_batch_size orelse self.model.max_batch_size, self.model.max_batch_size);
        if (batch_size == 0) return Error.InvalidBatchSize;
        const batch_count = std.math.divCeil(usize, inputs.len, batch_size) catch return Error.InvalidBatchSize;
        if (batch_count > self.limits.max_batches) return Error.TooManyBatches;
        const control = try model_types.RunControl.init(options.io, options.cancellation, options.timeout_ms);

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const copied_inputs = try memory.alloc([]const u8, inputs.len);
        for (inputs, copied_inputs) |input, *copy| copy.* = try memory.dupe(u8, input);
        const vectors = try memory.alloc([]const f32, inputs.len);
        var usage: usage_types.RunUsage = .{};
        var dimensions: ?usize = null;
        var offset: usize = 0;
        var batch_index: usize = 0;
        var total_retry_delay_ms: u64 = 0;
        while (offset < inputs.len) : (batch_index += 1) {
            const end = @min(offset + batch_size, inputs.len);
            var batch = try self.requestBatch(
                gpa,
                inputs[offset..end],
                input_type,
                options,
                control,
                batch_index,
                &usage,
                &total_retry_delay_ms,
            );
            defer batch.deinit();
            if (batch.vectors.len != end - offset) return Error.ResponseCountMismatch;
            for (batch.vectors, vectors[offset..end]) |vector, *target| {
                if (vector.len == 0 or vector.len > self.limits.max_dimensions) return Error.InvalidDimensions;
                if (options.dimensions) |requested| if (vector.len != requested)
                    return Error.ResponseDimensionsMismatch;
                if (dimensions) |expected| {
                    if (vector.len != expected) return Error.ResponseDimensionsMismatch;
                } else {
                    dimensions = vector.len;
                }
                for (vector) |value| if (!std.math.isFinite(value)) return Error.InvalidVectorValue;
                target.* = try memory.dupe(f32, vector);
            }
            try usage.addRequest(memory, batch.usage);
            offset = end;
        }
        const provider_name = try memory.dupe(u8, self.model.provider_name);
        const model_name = try memory.dupe(u8, self.model.model_name);
        return .{
            .arena = arena,
            .vectors = vectors,
            .inputs = copied_inputs,
            .input_type = input_type,
            .dimensions = dimensions.?,
            .provider_name = provider_name,
            .model_name = model_name,
            .usage = usage,
        };
    }

    fn validate(self: Embedder, inputs: []const []const u8, options: Options) Error!void {
        try self.limits.validate();
        if (inputs.len == 0) return Error.EmptyInputs;
        if (inputs.len > self.limits.max_inputs) return Error.TooManyInputs;
        if (self.model.max_batch_size == 0) return Error.InvalidBatchSize;
        if (options.max_batch_size) |size| if (size == 0) return Error.InvalidBatchSize;
        if (options.dimensions) |dimensions| {
            if (dimensions == 0 or dimensions > self.limits.max_dimensions) return Error.InvalidDimensions;
            if (self.model.max_dimensions) |maximum| if (dimensions > maximum) return Error.InvalidDimensions;
        }
        var total: usize = 0;
        for (inputs) |input| {
            if (input.len == 0) return Error.EmptyInput;
            if (input.len > self.limits.max_input_bytes) return Error.InputTooLarge;
            total = std.math.add(usize, total, input.len) catch return Error.TotalInputTooLarge;
            if (total > self.limits.max_total_input_bytes) return Error.TotalInputTooLarge;
        }
    }

    fn requestBatch(
        self: Embedder,
        gpa: std.mem.Allocator,
        inputs: []const []const u8,
        input_type: InputType,
        options: Options,
        control: model_types.RunControl,
        batch_index: usize,
        usage: *usage_types.RunUsage,
        total_retry_delay_ms: *u64,
    ) !BatchResult {
        var retries: usize = 0;
        while (true) {
            const timeout_ms = try control.remainingMilliseconds();
            const started = monotonicNow(options.io);
            var attempt_arena = std.heap.ArenaAllocator.init(gpa);
            defer attempt_arena.deinit();
            const result = control.invoke(BatchResult, invokeModel, .{
                self.model,
                attempt_arena.allocator(),
                Request{
                    .inputs = inputs,
                    .input_type = input_type,
                    .dimensions = options.dimensions,
                    .timeout_ms = timeout_ms,
                    .cancellation = options.cancellation,
                },
            });
            usage.recordRequest(elapsedMilliseconds(options.io, started)) catch return Error.UsageOverflow;
            if (result) |value| {
                var batch = value;
                defer batch.deinit();
                return copyBatch(gpa, batch);
            } else |failure| {
                if (retries >= options.retry.max_retries or !self.model.isRetryable(failure)) return failure;
                retries += 1;
                const delay_ms = try retryDelay(options.io, options.retry, retries);
                const next_total = std.math.add(u64, total_retry_delay_ms.*, delay_ms) catch
                    return Error.RetryBudgetExceeded;
                if (options.retry.max_total_delay_ms) |maximum| {
                    if (next_total > maximum) return Error.RetryBudgetExceeded;
                }
                total_retry_delay_ms.* = next_total;
                const event = RetryEvent{
                    .batch_index = batch_index,
                    .retry_number = retries,
                    .failure = failure,
                    .delay_ms = delay_ms,
                    .total_delay_ms = next_total,
                };
                if (options.retry.before_retry) |hook| try hook.emit(event);
                if (delay_ms > 0) {
                    const io = options.io orelse return Error.RetryBackoffRequiresIo;
                    try control.invoke(void, sleep, .{ io, delay_ms });
                }
            }
        }
    }
};

fn invokeModel(model: Model, gpa: std.mem.Allocator, request: Request) !BatchResult {
    return model.embed(gpa, request);
}

fn copyBatch(gpa: std.mem.Allocator, source: BatchResult) !BatchResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const vectors = try arena.allocator().alloc([]const f32, source.vectors.len);
    for (source.vectors, vectors) |vector, *copy| {
        copy.* = try arena.allocator().dupe(f32, vector);
    }
    const usage = try source.usage.dupe(arena.allocator());
    const response_id = if (source.response_id) |id| try arena.allocator().dupe(u8, id) else null;
    return .{
        .arena = arena,
        .vectors = vectors,
        .usage = usage,
        .response_id = response_id,
    };
}

fn retryDelay(io: ?std.Io, policy: RetryPolicy, retry_number: usize) Error!u64 {
    var maximum = @min(policy.initial_delay_ms, policy.maximum_delay_ms);
    var exponent = retry_number -| 1;
    while (exponent > 0 and maximum < policy.maximum_delay_ms) : (exponent -= 1) {
        maximum = @min(std.math.mul(u64, maximum, 2) catch std.math.maxInt(u64), policy.maximum_delay_ms);
    }
    if (maximum == 0) return 0;
    const runtime = io orelse return Error.RetryBackoffRequiresIo;
    var source = std.Random.IoSource{ .io = runtime };
    return source.interface().uintAtMost(u64, maximum);
}

fn sleep(io: std.Io, milliseconds: u64) !void {
    return (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64)))),
        .clock = .awake,
    } }).sleep(io);
}

fn monotonicNow(io: ?std.Io) ?i128 {
    const runtime = io orelse return null;
    return std.Io.Clock.awake.now(runtime).nanoseconds;
}

fn elapsedMilliseconds(io: ?std.Io, started: ?i128) ?u64 {
    const start = started orelse return null;
    const runtime = io orelse return null;
    const elapsed = std.Io.Clock.awake.now(runtime).nanoseconds - start;
    if (elapsed <= 0) return 0;
    return @intCast(@divFloor(elapsed, std.time.ns_per_ms));
}

test "embedder batches in source order and owns vectors inputs and usage" {
    const State = struct {
        calls: usize = 0,

        fn embed(context: *anyopaque, gpa: std.mem.Allocator, request: Request) !BatchResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const vectors = try arena.allocator().alloc([]const f32, request.inputs.len);
            for (request.inputs, vectors) |input, *vector| {
                const values = try arena.allocator().alloc(f32, 2);
                values[0] = @floatFromInt(input.len);
                values[1] = @floatFromInt(self.calls);
                vector.* = values;
            }
            self.calls += 1;
            return .{
                .arena = arena,
                .vectors = vectors,
                .usage = .{ .input_tokens = @intCast(request.inputs.len) },
            };
        }
    };
    var state: State = .{};
    const embedder = Embedder{ .model = .{
        .context = &state,
        .provider_name = "test",
        .model_name = "small",
        .max_batch_size = 2,
        .max_dimensions = 2,
        .embed_fn = State.embed,
    } };
    var result = try embedder.embedDocuments(std.testing.allocator, &.{ "one", "four", "five" }, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqual(@as(usize, 2), result.dimensions);
    try std.testing.expectEqual(@as(f32, 3), result.vectors[0][0]);
    try std.testing.expectEqual(@as(f32, 1), result.vectors[2][1]);
    try std.testing.expectEqual(@as(usize, 2), result.usage.requests);
    try std.testing.expectEqual(@as(u64, 3), result.usage.input_tokens);
    try std.testing.expectEqualSlices(f32, result.vectors[1], result.vectorFor("four").?);
    try std.testing.expectEqual(@as(?[]const f32, null), result.vectorFor("missing"));

    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var allocation_state: State = .{};
            var allocation_result = try (Embedder{ .model = .{
                .context = &allocation_state,
                .provider_name = "test",
                .model_name = "batch-allocation",
                .max_batch_size = 2,
                .embed_fn = State.embed,
            } }).embedDocuments(gpa, &.{ "one", "two" }, .{});
            allocation_result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Allocation.run, .{});
}

test "embedder retries transient batches with bounded full jitter" {
    const State = struct {
        calls: usize = 0,
        retries: usize = 0,

        fn embed(context: *anyopaque, gpa: std.mem.Allocator, _: Request) !BatchResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls <= 2) return error.ProviderRateLimited;
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const vectors = try arena.allocator().alloc([]const f32, 1);
            vectors[0] = try arena.allocator().dupe(f32, &.{ 1, 2 });
            return .{ .arena = arena, .vectors = vectors };
        }

        fn retry(context: ?*anyopaque, event: RetryEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(self.retries + 1, event.retry_number);
            self.retries += 1;
        }
    };
    var state: State = .{};
    var result = try (Embedder{ .model = .{
        .context = &state,
        .provider_name = "test",
        .model_name = "retry",
        .max_batch_size = 1,
        .embed_fn = State.embed,
    } }).embedQuery(std.testing.allocator, "query", .{
        .io = std.testing.io,
        .retry = .{
            .initial_delay_ms = 1,
            .maximum_delay_ms = 2,
            .before_retry = .{ .context = &state, .event_fn = State.retry },
        },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), state.calls);
    try std.testing.expectEqual(@as(usize, 2), state.retries);
    try std.testing.expectEqual(@as(usize, 3), result.usage.requests);

    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var allocation_state: State = .{};
            var allocation_result = try (Embedder{ .model = .{
                .context = &allocation_state,
                .provider_name = "test",
                .model_name = "retry-allocation",
                .max_batch_size = 1,
                .embed_fn = State.embed,
            } }).embedQuery(gpa, "query", .{
                .retry = .{ .max_retries = 2, .initial_delay_ms = 0, .maximum_delay_ms = 0 },
            });
            allocation_result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Allocation.run, .{});
}

test "embedder validates requested dimensions before provider I/O" {
    var marker: u8 = 0;
    const model = Model{
        .context = &marker,
        .provider_name = "test",
        .model_name = "dimensions",
        .max_batch_size = 1,
        .max_dimensions = 2,
        .embed_fn = struct {
            fn embed(_: *anyopaque, _: std.mem.Allocator, _: Request) !BatchResult { // kcov-ignore: pre-I/O guard
                return error.ModelMustNotRun; // kcov-ignore: pre-I/O guard
            }
        }.embed,
    };
    const embedder = Embedder{ .model = model, .limits = .{ .max_dimensions = 3 } };
    try std.testing.expectError(
        Error.InvalidDimensions,
        embedder.embedQuery(std.testing.allocator, "query", .{ .dimensions = 0 }),
    );
    try std.testing.expectError(
        Error.InvalidDimensions,
        embedder.embedQuery(std.testing.allocator, "query", .{ .dimensions = 3 }),
    );
}

fn embedWithAllocator(gpa: std.mem.Allocator) !void {
    const State = struct {
        fn embed(_: *anyopaque, allocator: std.mem.Allocator, _: Request) !BatchResult {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const vectors = try arena.allocator().alloc([]const f32, 1);
            vectors[0] = try arena.allocator().dupe(f32, &.{1});
            return .{ .arena = arena, .vectors = vectors };
        }
    };
    var marker: u8 = 0;
    var result = try (Embedder{ .model = .{
        .context = &marker,
        .provider_name = "test",
        .model_name = "allocation",
        .max_batch_size = 1,
        .embed_fn = State.embed,
    } }).embedQuery(gpa, "query", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 1), result.vectors[0][0]);
}

test "embedder ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, embedWithAllocator, .{});
}
