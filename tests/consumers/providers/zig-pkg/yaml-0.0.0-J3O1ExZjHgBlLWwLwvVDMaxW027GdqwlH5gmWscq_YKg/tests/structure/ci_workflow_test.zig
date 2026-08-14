//! Purpose: Enforce AGENTS.md CI workflow requirements.
//! Owns: Repository-level checks for required CI commands.
//! Does not own: CI runner behavior or YAML library behavior.
//! Depends on: std only.
//! Tested by: zig build test-structure.

const std = @import("std");

test "structure: CI workflow runs required AGENTS checks" {
    const workflow = try readRepoFile(".github/workflows/ci.yml");
    defer std.testing.allocator.free(workflow);

    const required_commands = [_][]const u8{
        "zig fmt --check build.zig build.zig.zon src tests tools",
        "git diff --check",
        "zig build test-unit",
        "zig build test-structure",
        "zig build test",
        "zig build test-conformance",
        "zig build test-direct-conformance",
        "zig build test-stress",
        "zig build test-allocation",
        "zig build test-leaks",
        "zig build test-coverage -Duse-llvm=true",
        "zig build test-valgrind -Duse-llvm=true -Dcpu=baseline",
        "zig build docs",
        "zig build conformance-report",
    };

    for (required_commands) |command| {
        if (std.mem.indexOf(u8, workflow, command) == null) {
            std.debug.print("CI workflow missing required command: {s}\n", .{command});
            return error.MissingCiCommand;
        }
    }
}

fn readRepoFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
}
