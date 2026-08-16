const std = @import("std");
const harness = @import("harness");
const workloads = @import("workloads");

pub fn main(init: std.process.Init) !void {
    var threaded = std.Io.Threaded.init(init.gpa, .{});
    defer threaded.deinit();
    var catalog = workloads.Catalog{ .io = threaded.io() };
    const items = catalog.workloads();
    const measurements = try harness.measure(init.gpa, init.io, &items, .{});
    defer init.gpa.free(measurements);
    const json = try harness.stringifyMeasurementsJson(init.gpa, measurements);
    defer init.gpa.free(json);

    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.writeAll(json);
    try output.interface.flush();
}
