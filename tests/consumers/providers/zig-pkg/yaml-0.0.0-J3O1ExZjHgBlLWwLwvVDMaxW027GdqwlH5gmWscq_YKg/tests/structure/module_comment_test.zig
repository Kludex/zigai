//! Purpose: Enforce AGENTS module comments on non-trivial Zig files.
//! Owns: Repository-wide module-comment scanning.
//! Does not own: File-size, docs, or import-boundary checks.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const std = support.std;

test "structure: non-trivial Zig files start with AGENTS module comments" {
    try expectModuleCommentFile("build.zig");
    try expectModuleCommentsUnder("src");
    try expectModuleCommentsUnder("tests");
    try expectModuleCommentsUnder("tools");
}

fn expectModuleCommentFile(path: []const u8) !void {
    const source = try support.readRepoFile(path);
    defer std.testing.allocator.free(source);

    if (!std.mem.startsWith(u8, source, "//! Purpose: ")) {
        std.debug.print("{s} is missing AGENTS module comments\n", .{path});
        return error.MissingModuleComment;
    }
}

fn expectModuleCommentsUnder(root_path: []const u8) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root_path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer root_dir.close(std.testing.io);

    var walker = try root_dir.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, entry.path });
        defer std.testing.allocator.free(full_path);

        const source = try support.readRepoFile(full_path);
        defer std.testing.allocator.free(source);

        if (!std.mem.startsWith(u8, source, "//! Purpose: ")) {
            std.debug.print("{s} is missing AGENTS module comments\n", .{full_path});
            return error.MissingModuleComment;
        }
    }
}
