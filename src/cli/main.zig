const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.process.exit(@intFromEnum(app.ExitCode.runtime_error));
    };
    const code = app.execute(init, args) catch |failure| {
        std.log.err("zigai: {s}", .{@errorName(failure)});
        std.process.exit(@intFromEnum(app.classifyError(failure)));
    };
    if (code != .success) std.process.exit(@intFromEnum(code));
}
