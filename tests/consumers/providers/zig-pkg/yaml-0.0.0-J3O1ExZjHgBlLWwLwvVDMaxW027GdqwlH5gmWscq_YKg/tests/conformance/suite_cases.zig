//! Purpose: Discover and read yaml-test-suite case files for conformance tests.
//! Owns: Suite case discovery, file lookup, pinned-suite count checks, and fixture reading.
//! Does not own: Event, JSON, emitter, or loader comparison logic.
//! Depends on: std and yaml_suite_decode.zig.
//! Tested by: tests/conformance/yaml_suite_runner.zig and tests/conformance/direct_conformance.zig.

const std = @import("std");
const yaml_suite_decode = @import("yaml_suite_decode.zig");

pub const DiscoveredCase = struct {
    id: []const u8,
    has_error: bool,
};

pub const DiscoveredCases = struct {
    allocator: std.mem.Allocator,
    items: []const DiscoveredCase,

    pub fn deinit(self: *DiscoveredCases) void {
        for (self.items) |case| {
            self.allocator.free(case.id);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn discover(allocator: std.mem.Allocator, suite_root: []const u8) !DiscoveredCases {
    var suite_dir = try std.Io.Dir.cwd().openDir(std.testing.io, suite_root, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer suite_dir.close(std.testing.io);

    var walker = try suite_dir.walk(allocator);
    defer walker.deinit();

    var cases: std.ArrayList(DiscoveredCase) = .empty;
    errdefer {
        for (cases.items) |case| {
            allocator.free(case.id);
        }
        cases.deinit(allocator);
    }

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        const id = caseIdFromInputPath(entry.path) orelse continue;

        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);

        try cases.append(allocator, .{
            .id = owned_id,
            .has_error = try fileExists(allocator, suite_dir, id, "error"),
        });
    }

    std.mem.sort(DiscoveredCase, cases.items, {}, discoveredCaseLessThan);

    return .{
        .allocator = allocator,
        .items = try cases.toOwnedSlice(allocator),
    };
}

pub fn fileExists(
    allocator: std.mem.Allocator,
    suite_dir: std.Io.Dir,
    id: []const u8,
    filename: []const u8,
) !bool {
    const path = try std.fs.path.join(allocator, &.{ id, filename });
    defer allocator.free(path);

    suite_dir.access(std.testing.io, path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn readCaseFile(
    allocator: std.mem.Allocator,
    suite_root: []const u8,
    id: []const u8,
    filename: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ suite_root, id, filename });
    defer allocator.free(path);

    const raw = try readFile(allocator, path);
    if (!yaml_suite_decode.containsEncodedCharacters(filename, raw)) return raw;
    defer allocator.free(raw);

    return yaml_suite_decode.decodeCaseFile(allocator, filename, raw);
}

pub fn expectConfiguredParserCaseCount(
    using_pinned_yaml_test_suite: bool,
    expected_pinned_count: usize,
    actual_count: usize,
) !void {
    if (using_pinned_yaml_test_suite) {
        try std.testing.expectEqual(expected_pinned_count, actual_count);
    } else {
        try std.testing.expect(actual_count > 0);
    }
}

pub fn expectPinnedSuiteCount(
    using_pinned_yaml_test_suite: bool,
    expected_pinned_count: usize,
    actual_count: usize,
) !void {
    if (using_pinned_yaml_test_suite) {
        try std.testing.expectEqual(expected_pinned_count, actual_count);
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
}

fn caseIdFromInputPath(path: []const u8) ?[]const u8 {
    const suffix = "in.yaml";
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len == suffix.len) return null;

    const separator_index = path.len - suffix.len - 1;
    if (path[separator_index] != std.fs.path.sep) return null;

    return path[0..separator_index];
}

fn discoveredCaseLessThan(_: void, lhs: DiscoveredCase, rhs: DiscoveredCase) bool {
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

test {
    std.testing.refAllDecls(yaml_suite_decode);
}
