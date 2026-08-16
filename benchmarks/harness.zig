//! Deterministic benchmark baselines and reviewed regression decisions.

const std = @import("std");

pub const schema_version = 2;

pub const Error = error{
    InvalidBaseline,
    InvalidMeasurement,
    InvalidRunnerOptions,
    NondeterministicWorkload,
    EnvironmentMismatch,
    WorkloadSetDrift,
    WorkloadChecksumDrift,
};

/// Checked-in reference for one deterministic workload.
pub const BaselineEntry = struct {
    name: []const u8,
    median_ns: u64,
    checksum: u64,
    /// Null publishes the measurement without making it a CI gate. A value is
    /// enabled only by an explicit baseline review.
    max_regression_basis_points: ?u32 = null,
};

pub const Baseline = struct {
    version: u32,
    zig_version: []const u8,
    optimize: []const u8,
    target: []const u8,
    entries: []const BaselineEntry,

    pub fn validate(self: Baseline) !void {
        if (self.version != schema_version or self.zig_version.len == 0 or
            self.optimize.len == 0 or !validName(self.target) or self.entries.len == 0)
            return Error.InvalidBaseline;
        var previous: ?[]const u8 = null;
        for (self.entries) |entry| {
            if (!validName(entry.name) or entry.median_ns == 0)
                return Error.InvalidBaseline;
            if (entry.max_regression_basis_points) |threshold| {
                if (threshold > 100_000) return Error.InvalidBaseline;
            }
            if (previous) |name| {
                if (std.mem.order(u8, name, entry.name) != .lt)
                    return Error.InvalidBaseline;
            }
            previous = entry.name;
        }
    }

    pub fn validateEnvironment(self: Baseline, environment: Environment) !void {
        try environment.validate();
        if (!std.mem.eql(u8, self.zig_version, environment.zig_version) or
            !std.mem.eql(u8, self.optimize, environment.optimize) or
            !std.mem.eql(u8, self.target, environment.target))
            return Error.EnvironmentMismatch;
    }
};

pub const Environment = struct {
    zig_version: []const u8,
    optimize: []const u8,
    target: []const u8,

    pub fn validate(self: Environment) !void {
        if (self.zig_version.len == 0 or self.optimize.len == 0 or !validName(self.target))
            return Error.InvalidMeasurement;
    }
};

pub const Measurement = struct {
    name: []const u8,
    median_ns: u64,
    checksum: u64,
};

/// Encodes fresh measurements without implying that they are reviewed
/// baselines. The output is stable so CI artifacts remain easy to diff.
pub fn stringifyMeasurementsJson(
    allocator: std.mem.Allocator,
    environment: Environment,
    measurements: []const Measurement,
) ![]u8 {
    try environment.validate();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("version");
    try json.write(schema_version);
    try json.objectField("zig_version");
    try json.write(environment.zig_version);
    try json.objectField("optimize");
    try json.write(environment.optimize);
    try json.objectField("target");
    try json.write(environment.target);
    try json.objectField("measurements");
    try json.beginArray();
    for (measurements) |measurement| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(measurement.name);
        try json.objectField("median_ns");
        try json.write(measurement.median_ns);
        try json.objectField("checksum");
        try json.write(measurement.checksum);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

pub const Workload = struct {
    name: []const u8,
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!u64,

    pub fn run(self: Workload, allocator: std.mem.Allocator) !u64 {
        return self.runFn(self.context, allocator);
    }
};

pub const RunnerOptions = struct {
    warmup_iterations: usize = 8,
    samples: usize = 21,
    iterations_per_sample: usize = 32,

    pub fn validate(self: RunnerOptions) !void {
        if (self.samples == 0 or self.iterations_per_sample == 0 or
            self.warmup_iterations > 1_000_000 or self.samples > 10_000 or
            self.iterations_per_sample > 1_000_000)
            return Error.InvalidRunnerOptions;
    }
};

/// Runs sorted deterministic workloads and reports median nanoseconds per
/// operation. Every callback result is checked and kept observable.
pub fn measure(
    allocator: std.mem.Allocator,
    io: std.Io,
    workloads: []const Workload,
    options: RunnerOptions,
) ![]Measurement {
    try options.validate();
    try validateWorkloads(workloads);
    const measurements = try allocator.alloc(Measurement, workloads.len);
    errdefer allocator.free(measurements);
    const samples = try allocator.alloc(u64, options.samples);
    defer allocator.free(samples);

    for (workloads, measurements) |workload, *measurement| {
        var expected_checksum: ?u64 = null;
        for (0..options.warmup_iterations) |_| {
            const checksum = try workload.run(allocator);
            try acceptChecksum(&expected_checksum, checksum);
            std.mem.doNotOptimizeAway(checksum);
        }
        for (samples) |*sample| {
            const started = std.Io.Clock.Timestamp.now(io, .awake);
            for (0..options.iterations_per_sample) |_| {
                const checksum = try workload.run(allocator);
                try acceptChecksum(&expected_checksum, checksum);
                std.mem.doNotOptimizeAway(checksum);
            }
            const ended = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed = started.durationTo(ended).raw.nanoseconds;
            const positive: u64 = if (elapsed <= 0) 1 else @intCast(@min(
                elapsed,
                std.math.maxInt(u64),
            ));
            sample.* = @max(1, positive / options.iterations_per_sample);
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        measurement.* = .{
            .name = workload.name,
            .median_ns = samples[samples.len / 2],
            .checksum = expected_checksum.?,
        };
    }
    return measurements;
}

pub const Status = enum { unreviewed, pass, regression };

pub const Comparison = struct {
    name: []const u8,
    baseline_ns: u64,
    current_ns: u64,
    checksum: u64,
    max_regression_basis_points: ?u32,
    status: Status,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    zig_version: []const u8,
    optimize: []const u8,
    target: []const u8,
    entries: []Comparison,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn regressions(self: Report) usize {
        var count: usize = 0;
        for (self.entries) |entry| if (entry.status == .regression) {
            count += 1;
        };
        return count;
    }

    pub fn passed(self: Report) bool {
        return self.regressions() == 0;
    }
};

pub fn parseBaseline(
    allocator: std.mem.Allocator,
    source: []const u8,
) !std.json.Parsed(Baseline) {
    var parsed = std.json.parseFromSlice(Baseline, allocator, source, .{
        .ignore_unknown_fields = false,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return failure,
        else => return Error.InvalidBaseline,
    };
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

/// Requires an exact, sorted workload set. Checksum changes are semantic
/// workload changes and must update the baseline deliberately.
pub fn compare(
    allocator: std.mem.Allocator,
    baseline: Baseline,
    measurements: []const Measurement,
) !Report {
    try baseline.validate();
    if (baseline.entries.len != measurements.len) return Error.WorkloadSetDrift;
    const entries = try allocator.alloc(Comparison, measurements.len);
    errdefer allocator.free(entries);
    for (baseline.entries, measurements, entries) |reference, measured, *comparison| {
        if (!validName(measured.name) or measured.median_ns == 0)
            return Error.InvalidMeasurement;
        if (!std.mem.eql(u8, reference.name, measured.name))
            return Error.WorkloadSetDrift;
        if (reference.checksum != measured.checksum)
            return Error.WorkloadChecksumDrift;
        const status: Status = if (reference.max_regression_basis_points) |threshold|
            if (exceedsThreshold(reference.median_ns, measured.median_ns, threshold))
                .regression
            else
                .pass
        else
            .unreviewed;
        comparison.* = .{
            .name = measured.name,
            .baseline_ns = reference.median_ns,
            .current_ns = measured.median_ns,
            .checksum = measured.checksum,
            .max_regression_basis_points = reference.max_regression_basis_points,
            .status = status,
        };
    }
    return .{
        .allocator = allocator,
        .zig_version = baseline.zig_version,
        .optimize = baseline.optimize,
        .target = baseline.target,
        .entries = entries,
    };
}

pub fn stringifyReportJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("version");
    try json.write(schema_version);
    try json.objectField("zig_version");
    try json.write(report.zig_version);
    try json.objectField("optimize");
    try json.write(report.optimize);
    try json.objectField("target");
    try json.write(report.target);
    try json.objectField("conclusion");
    try json.write(if (report.passed()) "pass" else "fail");
    try json.objectField("regressions");
    try json.write(report.regressions());
    try json.objectField("entries");
    try json.beginArray();
    for (report.entries) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        try json.objectField("baseline_ns");
        try json.write(entry.baseline_ns);
        try json.objectField("current_ns");
        try json.write(entry.current_ns);
        try json.objectField("checksum");
        try json.write(entry.checksum);
        try json.objectField("max_regression_basis_points");
        try json.write(entry.max_regression_basis_points);
        try json.objectField("status");
        try json.write(@tagName(entry.status));
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

fn validateWorkloads(workloads: []const Workload) !void {
    if (workloads.len == 0) return Error.InvalidRunnerOptions;
    var previous: ?[]const u8 = null;
    for (workloads) |workload| {
        if (!validName(workload.name)) return Error.InvalidMeasurement;
        if (previous) |name| if (std.mem.order(u8, name, workload.name) != .lt)
            return Error.InvalidMeasurement;
        previous = workload.name;
    }
}

fn acceptChecksum(expected: *?u64, checksum: u64) !void {
    if (expected.*) |value| {
        if (value != checksum) return Error.NondeterministicWorkload;
    } else {
        expected.* = checksum;
    }
}

fn exceedsThreshold(baseline_ns: u64, current_ns: u64, basis_points: u32) bool {
    const scale: u128 = 10_000;
    const allowed = @as(u128, baseline_ns) * (scale + basis_points);
    const current = @as(u128, current_ns) * scale;
    return current > allowed;
}

test "benchmark baselines validate exact sorted workloads" {
    const source =
        \\{
        \\  "version": 2,
        \\  "zig_version": "0.16.0",
        \\  "optimize": "ReleaseSafe",
        \\  "target": "test-aarch64",
        \\  "entries": [
        \\    {"name":"decode","median_ns":100,"checksum":7,"max_regression_basis_points":500},
        \\    {"name":"encode","median_ns":200,"checksum":9}
        \\  ]
        \\}
    ;
    var parsed = try parseBaseline(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);

    const invalid_sources = [_][]const u8{
        "{}",
        "{\"version\":2,\"zig_version\":\"0.16.0\",\"optimize\":\"ReleaseSafe\",\"entries\":[{\"name\":\"a\",\"median_ns\":1,\"checksum\":1}]}",
        "{\"version\":1,\"zig_version\":\"\",\"optimize\":\"ReleaseSafe\",\"entries\":[{\"name\":\"a\",\"median_ns\":1,\"checksum\":1}]}",
    };
    for (invalid_sources) |invalid| try std.testing.expectError(
        Error.InvalidBaseline,
        parseBaseline(std.testing.allocator, invalid),
    );
}

test "benchmark comparison gates only reviewed thresholds" {
    const baseline = Baseline{
        .version = schema_version,
        .zig_version = "0.16.0",
        .optimize = "ReleaseSafe",
        .target = "test-aarch64",
        .entries = &.{
            .{ .name = "a", .median_ns = 100, .checksum = 1, .max_regression_basis_points = 500 },
            .{ .name = "b", .median_ns = 100, .checksum = 2 },
            .{ .name = "c", .median_ns = 100, .checksum = 3, .max_regression_basis_points = 500 },
        },
    };
    var report = try compare(std.testing.allocator, baseline, &.{
        .{ .name = "a", .median_ns = 105, .checksum = 1 },
        .{ .name = "b", .median_ns = 10_000, .checksum = 2 },
        .{ .name = "c", .median_ns = 106, .checksum = 3 },
    });
    defer report.deinit();
    try std.testing.expectEqual(Status.pass, report.entries[0].status);
    try std.testing.expectEqual(Status.unreviewed, report.entries[1].status);
    try std.testing.expectEqual(Status.regression, report.entries[2].status);
    try std.testing.expectEqual(@as(usize, 1), report.regressions());
    try std.testing.expect(!report.passed());
    const json = try stringifyReportJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"conclusion\": \"fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"unreviewed\"") != null);
    try baseline.validateEnvironment(.{
        .zig_version = "0.16.0",
        .optimize = "ReleaseSafe",
        .target = "test-aarch64",
    });
    try std.testing.expectError(Error.EnvironmentMismatch, baseline.validateEnvironment(.{
        .zig_version = "0.16.0",
        .optimize = "Debug",
        .target = "test-aarch64",
    }));
}

test "benchmark comparison rejects structural and semantic drift" {
    const valid = Baseline{
        .version = schema_version,
        .zig_version = "0.16.0",
        .optimize = "ReleaseSafe",
        .target = "test-aarch64",
        .entries = &.{.{ .name = "a", .median_ns = 1, .checksum = 1 }},
    };
    try std.testing.expectError(Error.WorkloadSetDrift, compare(std.testing.allocator, valid, &.{}));
    try std.testing.expectError(Error.WorkloadSetDrift, compare(std.testing.allocator, valid, &.{.{
        .name = "b",
        .median_ns = 1,
        .checksum = 1,
    }}));
    try std.testing.expectError(Error.WorkloadChecksumDrift, compare(std.testing.allocator, valid, &.{.{
        .name = "a",
        .median_ns = 1,
        .checksum = 2,
    }}));
    try std.testing.expectError(Error.InvalidMeasurement, compare(std.testing.allocator, valid, &.{.{
        .name = "a",
        .median_ns = 0,
        .checksum = 1,
    }}));

    const invalid_baselines = [_]Baseline{
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "test-aarch64", .entries = &.{} },
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "bad target", .entries = &.{.{ .name = "a", .median_ns = 1, .checksum = 1 }} },
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "test-aarch64", .entries = &.{.{ .name = "bad name", .median_ns = 1, .checksum = 1 }} },
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "test-aarch64", .entries = &.{.{ .name = "a", .median_ns = 0, .checksum = 1 }} },
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "test-aarch64", .entries = &.{.{ .name = "a", .median_ns = 1, .checksum = 1, .max_regression_basis_points = 100_001 }} },
        .{ .version = schema_version, .zig_version = "0.16.0", .optimize = "ReleaseSafe", .target = "test-aarch64", .entries = &.{ .{ .name = "b", .median_ns = 1, .checksum = 1 }, .{ .name = "a", .median_ns = 1, .checksum = 1 } } },
    };
    for (invalid_baselines) |invalid| try std.testing.expectError(
        Error.InvalidBaseline,
        invalid.validate(),
    );
}

test "benchmark runner warms samples and rejects nondeterminism" {
    const State = struct {
        calls: usize = 0,
        vary: bool = false,

        fn run(context: *anyopaque, _: std.mem.Allocator) !u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return if (self.vary) self.calls else 42;
        }
    };
    var state: State = .{};
    const workloads = [_]Workload{.{ .name = "stable", .context = &state, .runFn = State.run }};
    const measured = try measure(std.testing.allocator, std.testing.io, &workloads, .{
        .warmup_iterations = 2,
        .samples = 3,
        .iterations_per_sample = 2,
    });
    defer std.testing.allocator.free(measured);
    try std.testing.expectEqual(@as(usize, 8), state.calls);
    try std.testing.expectEqual(@as(u64, 42), measured[0].checksum);
    try std.testing.expect(measured[0].median_ns > 0);
    const environment: Environment = .{
        .zig_version = "0.16.0",
        .optimize = "ReleaseSafe",
        .target = "test-aarch64",
    };
    const json = try stringifyMeasurementsJson(std.testing.allocator, environment, measured);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"stable\"") != null);
    const stable_json = try stringifyMeasurementsJson(std.testing.allocator, environment, &.{.{
        .name = "stable",
        .median_ns = 1,
        .checksum = 42,
    }});
    defer std.testing.allocator.free(stable_json);
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 2,
        \\  "zig_version": "0.16.0",
        \\  "optimize": "ReleaseSafe",
        \\  "target": "test-aarch64",
        \\  "measurements": [
        \\    {
        \\      "name": "stable",
        \\      "median_ns": 1,
        \\      "checksum": 42
        \\    }
        \\  ]
        \\}
        \\
    ,
        stable_json,
    );

    state = .{ .vary = true };
    try std.testing.expectError(Error.NondeterministicWorkload, measure(
        std.testing.allocator,
        std.testing.io,
        &workloads,
        .{ .warmup_iterations = 2, .samples = 1, .iterations_per_sample = 1 },
    ));
    try std.testing.expectError(Error.InvalidRunnerOptions, measure(
        std.testing.allocator,
        std.testing.io,
        &workloads,
        .{ .samples = 0 },
    ));
    try std.testing.expectError(Error.InvalidMeasurement, measure(
        std.testing.allocator,
        std.testing.io,
        &.{
            .{ .name = "b", .context = &state, .runFn = State.run },
            .{ .name = "a", .context = &state, .runFn = State.run },
        },
        .{},
    ));
}
