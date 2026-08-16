const std = @import("std");
const zigai = @import("zigai");

const Server = struct {
    gpa: std.mem.Allocator,

    fn emit(context: ?*anyopaque, event: zigai.ui.Event) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const record = try zigai.ui.vercel.encode(self.gpa, event);
        defer self.gpa.free(record);
        std.debug.print("{s}", .{record});
    }
};

pub fn main(init: std.process.Init) !void {
    var server = Server{ .gpa = init.gpa };
    var bridge = zigai.ui.Bridge{
        .sink = .{ .context = &server, .event_fn = Server.emit },
        .thread_id = "browser-demo",
        .run_id = "run-1",
    };
    try bridge.begin();
    try bridge.emitCustom(init.gpa, "progress", "{\"percent\":100}");
    try bridge.finish();
    const done = try zigai.ui.vercel.encodeDone(init.gpa);
    defer init.gpa.free(done);
    std.debug.print("{s}", .{done});
}
