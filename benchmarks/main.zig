const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const workloads = @import("workloads");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const target = try std.fmt.allocPrint(init.gpa, "{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    defer init.gpa.free(target);
    const environment = harness.Environment{
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target = target,
    };
    var threaded = std.Io.Threaded.init(init.gpa, .{});
    defer threaded.deinit();
    var catalog = workloads.Catalog{ .io = threaded.io() };
    const items = catalog.workloads();
    const measurements = try harness.measure(init.gpa, init.io, &items, .{});
    defer init.gpa.free(measurements);

    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "measure"))) {
        const json = try harness.stringifyMeasurementsJson(init.gpa, environment, measurements);
        defer init.gpa.free(json);
        return writeStdout(init.io, json);
    }
    if (args.len != 4 or !std.mem.eql(u8, args[1], "check"))
        return error.InvalidArguments;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        init.gpa,
        .limited(1024 * 1024),
    );
    defer init.gpa.free(source);
    var baseline = try harness.parseBaseline(init.gpa, source);
    defer baseline.deinit();
    try baseline.value.validateEnvironment(environment);
    var report = try harness.compare(init.gpa, baseline.value, measurements);
    defer report.deinit();
    const json = try harness.stringifyReportJson(init.gpa, report);
    defer init.gpa.free(json);
    try writeAtomic(init.io, args[3], json);
    try writeStdout(init.io, json);
    if (!report.passed()) return error.BenchmarkRegression;
}

fn writeStdout(io: std.Io, value: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try output.interface.writeAll(value);
    try output.interface.flush();
}

fn writeAtomic(io: std.Io, path: []const u8, value: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(value);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}
