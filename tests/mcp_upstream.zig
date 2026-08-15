//! Small build helper that exposes one canonical upstream pin to automation.

const std = @import("std");
const upstreams = @import("mcp/upstreams.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    var manifest = try upstreams.parse(init.gpa, @embedFile("mcp/upstreams.yaml"));
    defer manifest.deinit();
    const server = upstreams.findServer(manifest.value(), args[1]) orelse return error.UnknownUpstream;
    var buffer: [64]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("{s}\n", .{server.revision});
    try output.interface.flush();
}
