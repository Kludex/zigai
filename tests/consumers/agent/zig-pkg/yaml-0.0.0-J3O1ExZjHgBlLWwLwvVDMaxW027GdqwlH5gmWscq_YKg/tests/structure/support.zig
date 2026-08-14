//! Purpose: Share helpers for repository structure checks.
//! Owns: File reading, line limits, and forbidden-import assertions.
//! Does not own: Specific structure policy tests.
//! Depends on: std only.
//! Tested by: tests/structure/file_size_test.zig.

pub const std = @import("std");

pub const SourceFile = struct {
    path: []const u8,
    max_lines: usize,
};

pub fn readRepoFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
}

pub fn expectLineLimits(files: []const SourceFile) !void {
    for (files) |file| {
        const source = try readRepoFile(file.path);
        defer std.testing.allocator.free(source);

        try std.testing.expect(lineCount(source) <= file.max_lines);
    }
}

pub fn expectRepoFilesPresent(paths: []const []const u8) !void {
    for (paths) |path| {
        const source = readRepoFile(path) catch |err| {
            std.debug.print("required repository file is missing: {s}\n", .{path});
            return err;
        };
        defer std.testing.allocator.free(source);

        try std.testing.expect(source.len > 0);
    }
}

pub fn expectRepoFilesAbsent(paths: []const []const u8) !void {
    for (paths) |path| {
        const source = readRepoFile(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer std.testing.allocator.free(source);

        std.debug.print("stale repository file remains: {s}\n", .{path});
        return error.StaleRepositoryFile;
    }
}

pub fn expectContainsAll(source: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

pub fn expectContainsNone(source: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
    }
}

pub fn lineCount(source: []const u8) usize {
    if (source.len == 0) return 0;

    var lines: usize = 1;
    for (source) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

pub fn expectNoForbiddenImportsUnder(root_path: []const u8, forbidden_imports: []const []const u8) !void {
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

        const source = try readRepoFile(full_path);
        defer std.testing.allocator.free(source);

        for (forbidden_imports) |forbidden| {
            if (std.mem.indexOf(u8, source, forbidden) != null) {
                std.debug.print("{s} imports root compatibility facade {s}\n", .{ full_path, forbidden });
                return error.RootCompatibilityFacadeImport;
            }
        }
    }
}

pub fn expectNoForbiddenImportsIn(path: []const u8, forbidden_imports: []const []const u8) !void {
    const source = try readRepoFile(path);
    defer std.testing.allocator.free(source);

    for (forbidden_imports) |forbidden| {
        if (std.mem.indexOf(u8, source, forbidden) != null) {
            std.debug.print("{s} imports root compatibility facade {s}\n", .{ path, forbidden });
            return error.RootCompatibilityFacadeImport;
        }
    }
}
