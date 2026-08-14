//! Purpose: Enforce the required line-coverage percentage from kcov JSON output.
//! Owns: Finding merged `coverage.json` reports and comparing them with a configured threshold.
//! Does not own: Running kcov, collecting coverage, or choosing source exclusions.
//! Depends on: std only.
//! Tested by: in-file unit tests and `zig build test-coverage`.

const std = @import("std");
const Io = std.Io;

const CoverageSummary = struct {
    path: []const u8,
    covered: u64,
    instrumented: u64,
    percent: f64,

    fn meets(self: CoverageSummary, threshold_percent: u8) bool {
        return self.percent + 0.000_001 >= @as(f64, @floatFromInt(threshold_percent));
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 3) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    const threshold_percent = try parseThreshold(args[2]);
    const summary = try findCoverageSummary(allocator, io, args[1]);

    if (!summary.meets(threshold_percent)) {
        var stderr_buffer: [512]u8 = undefined;
        var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
        const stderr = &stderr_writer.interface;

        try stderr.print(
            "coverage {d:.2}% is below required {d}% ({d}/{d} lines) from {s}\n",
            .{ summary.percent, threshold_percent, summary.covered, summary.instrumented, summary.path },
        );
        try stderr.flush();
        return error.CoverageBelowThreshold;
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "coverage {d:.2}% meets required {d}% ({d}/{d} lines) from {s}\n",
        .{ summary.percent, threshold_percent, summary.covered, summary.instrumented, summary.path },
    );
    try stdout.flush();
}

fn printUsage(io: Io) !void {
    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: yaml-check-coverage-threshold <coverage-dir> <threshold-percent>\n");
    try stderr.flush();
}

fn parseThreshold(input: []const u8) !u8 {
    const value = try std.fmt.parseInt(u8, input, 10);
    if (value > 100) return error.InvalidCoverageThreshold;
    return value;
}

fn findCoverageSummary(allocator: std.mem.Allocator, io: Io, root_path: []const u8) !CoverageSummary {
    var root_dir = try Io.Dir.cwd().openDir(io, root_path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer root_dir.close(io);

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    var best: ?CoverageSummary = null;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "coverage.json")) continue;

        const source = try root_dir.readFileAlloc(io, entry.path, allocator, .limited(64 * 1024 * 1024));
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        const summary = try parseCoverageJson(allocator, source, full_path);

        if (best == null or summary.instrumented > best.?.instrumented) {
            best = summary;
        }
    }

    return best orelse error.CoverageSummaryNotFound;
}

fn parseCoverageJson(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !CoverageSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    return coverageSummaryFromValue(parsed.value, path) orelse error.InvalidCoverageSummary;
}

fn coverageSummaryFromValue(value: std.json.Value, path: []const u8) ?CoverageSummary {
    if (value != .object) return null;

    const object = &value.object;
    const instrumented = unsignedField(object, &.{
        "instrumented",
        "instrumented_lines",
        "lines_instrumented",
        "total_lines",
    }) orelse 0;
    const covered = unsignedField(object, &.{
        "covered",
        "covered_lines",
        "lines_covered",
    }) orelse 0;
    const percent = numberField(object, &.{
        "percent_covered",
        "coverage",
        "line_percent",
    }) orelse percentFromCounts(covered, instrumented) orelse return null;

    return .{
        .path = path,
        .covered = covered,
        .instrumented = instrumented,
        .percent = percent,
    };
}

fn percentFromCounts(covered: u64, instrumented: u64) ?f64 {
    if (instrumented == 0) return null;
    return (@as(f64, @floatFromInt(covered)) * 100.0) / @as(f64, @floatFromInt(instrumented));
}

fn unsignedField(object: *const std.json.ObjectMap, names: []const []const u8) ?u64 {
    for (names) |name| {
        if (object.get(name)) |value| {
            return unsignedValue(value);
        }
    }
    return null;
}

fn numberField(object: *const std.json.ObjectMap, names: []const []const u8) ?f64 {
    for (names) |name| {
        if (object.get(name)) |value| {
            return numberValue(value);
        }
    }
    return null;
}

fn unsignedValue(value: std.json.Value) ?u64 {
    switch (value) {
        .integer => |integer| {
            if (integer < 0) return null;
            return @intCast(integer);
        },
        .float => |float| {
            if (float < 0 or @floor(float) != float) return null;
            return @intFromFloat(float);
        },
        .number_string => |number| return std.fmt.parseInt(u64, number, 10) catch null,
        .string => |string| return std.fmt.parseInt(u64, string, 10) catch null,
        else => return null,
    }
}

fn numberValue(value: std.json.Value) ?f64 {
    switch (value) {
        .integer => |integer| return @floatFromInt(integer),
        .float => |float| return float,
        .number_string => |number| return std.fmt.parseFloat(f64, number) catch null,
        .string => |string| return std.fmt.parseFloat(f64, string) catch null,
        else => return null,
    }
}

test "coverage checker: parses kcov-style summary percentages" {
    const source =
        \\{
        \\  "percent_covered": 100.0,
        \\  "covered": 42,
        \\  "instrumented": 42
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const summary = coverageSummaryFromValue(parsed.value, "coverage.json").?;
    try std.testing.expect(summary.meets(100));
    try std.testing.expectEqual(@as(u64, 42), summary.covered);
    try std.testing.expectEqual(@as(u64, 42), summary.instrumented);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), summary.percent, 0.001);
}

test "coverage checker: computes percent when only counts are present" {
    const source =
        \\{
        \\  "covered_lines": 75,
        \\  "instrumented_lines": 100
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const summary = coverageSummaryFromValue(parsed.value, "coverage.json").?;
    try std.testing.expect(summary.meets(75));
    try std.testing.expect(!summary.meets(100));
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), summary.percent, 0.001);
}

test "coverage checker: parses kcov merged string values" {
    const source =
        \\{
        \\  "percent_covered": "76.17",
        \\  "covered_lines": "4805",
        \\  "total_lines": "6308"
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const summary = coverageSummaryFromValue(parsed.value, "coverage.json").?;
    try std.testing.expect(summary.meets(76));
    try std.testing.expect(!summary.meets(77));
    try std.testing.expectEqual(@as(u64, 4805), summary.covered);
    try std.testing.expectEqual(@as(u64, 6308), summary.instrumented);
    try std.testing.expectApproxEqAbs(@as(f64, 76.17), summary.percent, 0.001);
}
