//! Purpose: Print discovered yaml-test-suite conformance coverage counts.
//! Owns: Runtime suite fixture counting for the `zig build conformance-report` step.
//! Does not own: Parser, loader, emitter, or comparison assertions.
//! Depends on: std only.
//! Tested by: zig build conformance-report and tests/structure/file_size_test.zig.

const std = @import("std");
const Io = std.Io;

const Report = struct {
    cases: usize = 0,
    expected_errors: usize = 0,
    parser_event_cases: usize = 0,
    loader_json_cases: usize = 0,
    emitter_cases: usize = 0,
    emitter_expected_error_cases: usize = 0,
    canonical_output_cases: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const suite_root = if (args.len > 1) args[1] else "vendor/yaml-test-suite";

    const report = try collectReport(arena, io, suite_root);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\yaml-test-suite report
        \\suite: {s}
        \\cases: {}
        \\expected error cases: {}
        \\parser event cases: {}
        \\loader JSON cases: {}
        \\emitter emit.yaml cases: {}
        \\emitter emit.yaml expected-error cases: {}
        \\canonical out.yaml cases: {}
        \\
    , .{
        suite_root,
        report.cases,
        report.expected_errors,
        report.parser_event_cases,
        report.loader_json_cases,
        report.emitter_cases,
        report.emitter_expected_error_cases,
        report.canonical_output_cases,
    });
    try stdout.flush();
}

fn collectReport(allocator: std.mem.Allocator, io: Io, suite_root: []const u8) !Report {
    var suite_dir = try Io.Dir.cwd().openDir(io, suite_root, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer suite_dir.close(io);

    var walker = try suite_dir.walk(allocator);
    defer walker.deinit();

    var report: Report = .{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = caseIdFromInputPath(entry.path) orelse continue;

        const has_error = try fileExists(allocator, io, suite_dir, id, "error");
        report.cases += 1;
        if (has_error) report.expected_errors += 1;

        if (try fileExists(allocator, io, suite_dir, id, "test.event")) {
            report.parser_event_cases += 1;
        }
        if (!has_error and try fileExists(allocator, io, suite_dir, id, "in.json")) {
            report.loader_json_cases += 1;
        }
        if (try fileExists(allocator, io, suite_dir, id, "emit.yaml")) {
            if (has_error) {
                report.emitter_expected_error_cases += 1;
            } else {
                report.emitter_cases += 1;
            }
        }
        if (!has_error and try fileExists(allocator, io, suite_dir, id, "out.yaml")) {
            report.canonical_output_cases += 1;
        }
    }

    return report;
}

fn fileExists(
    allocator: std.mem.Allocator,
    io: Io,
    suite_dir: Io.Dir,
    id: []const u8,
    filename: []const u8,
) !bool {
    const path = try std.fs.path.join(allocator, &.{ id, filename });
    defer allocator.free(path);

    suite_dir.access(io, path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn caseIdFromInputPath(path: []const u8) ?[]const u8 {
    const suffix = "in.yaml";
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len == suffix.len) return null;

    const separator_index = path.len - suffix.len - 1;
    if (path[separator_index] != std.fs.path.sep) return null;

    return path[0..separator_index];
}

test caseIdFromInputPath {
    try std.testing.expectEqualStrings("ABC1", caseIdFromInputPath("ABC1/in.yaml").?);
    try std.testing.expectEqualStrings("ABC1/00", caseIdFromInputPath("ABC1/00/in.yaml").?);
    try std.testing.expect(caseIdFromInputPath("ABC1/out.yaml") == null);
    try std.testing.expect(caseIdFromInputPath("in.yaml") == null);
}
