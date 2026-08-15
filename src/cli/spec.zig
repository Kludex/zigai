const std = @import("std");
const zigai = @import("zigai");
const common = @import("spec_common.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arguments = common.parseArguments(init.arena.allocator(), args) catch {
        std.log.err(
            "usage: {s} validate <agent.json|agent.yaml> [--interpolate] [--allow-env NAME] [--capability ID]",
            .{args[0]},
        );
        return error.InvalidArguments;
    };
    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        arguments.path,
        init.gpa,
        .limited(zigai.json.defaults.cli_config.max_document_bytes),
    );
    defer init.gpa.free(source);
    var environment = ProcessEnvironment{ .map = init.environ_map };
    try common.validateSource(
        init.gpa,
        source,
        try common.formatForPath(arguments.path),
        arguments,
        .{ .context = &environment, .getFn = ProcessEnvironment.get },
    );
    var buffer: [64]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.writeAll("valid\n");
    try output.interface.flush();
}

const ProcessEnvironment = struct {
    map: *std.process.Environ.Map,

    fn get(context: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.map.get(name);
    }
};
