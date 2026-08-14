//! Purpose: Enforce documentation and build-tooling structure checks.
//! Owns: Required docs, build-step discoverability, and public validation references.
//! Does not own: Source file sizes or API import boundaries.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const std = support.std;
test "structure: AGENTS build tooling steps are discoverable" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    const build_steps_source = try support.readRepoFile("tools/build_steps.zig");
    defer std.testing.allocator.free(build_steps_source);

    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "b.step(\"coverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "b.step(\"bench\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, ".ReleaseFast") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "b.step(\"conformance-report\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "b.step(\"test-schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "addBenchmarkStep") != null);

    const report_source = try support.readRepoFile("tools/report_conformance.zig");
    defer std.testing.allocator.free(report_source);

    try std.testing.expect(std.mem.startsWith(u8, report_source, "//! Purpose: "));
    try std.testing.expect(std.mem.startsWith(u8, build_steps_source, "//! Purpose: "));
}

test "structure: public documentation set is present" {
    try support.expectRepoFilesPresent(&[_][]const u8{
        "README.md",
        "docs/api.md",
        "docs/architecture.md",
        "docs/memory.md",
        "vendor/yaml-test-suite.PIN",
    });
}

test "structure: build step runs every structure policy shard" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    const structure_tests = [_][]const u8{
        "tests/structure/file_size_test.zig",
        "tests/structure/source_size_test.zig",
        "tests/structure/unit_size_test.zig",
        "tests/structure/api_boundary_test.zig",
        "tests/structure/docs_tooling_test.zig",
        "tests/structure/module_comment_test.zig",
        "tests/structure/ci_workflow_test.zig",
    };

    for (structure_tests) |path| {
        if (std.mem.indexOf(u8, build_source, path) == null) {
            std.debug.print("structure test shard is not wired into build.zig: {s}\n", .{path});
            return error.StructureShardNotWired;
        }
    }
}

test "structure: README records pinned validation entry points" {
    const readme_source = try support.readRepoFile("README.md");
    defer std.testing.allocator.free(readme_source);

    try support.expectContainsAll(readme_source, &[_][]const u8{
        "vendor/yaml-test-suite.PIN",
        "zig build conformance-report",
        "docs/api.md",
        "docs/architecture.md",
        "docs/memory.md",
    });

    try support.expectContainsNone(readme_source, &[_][]const u8{
        "docs/STATUS.md",
        "docs/verification-history.md",
        "coverage percentage",
        "current conformance counts",
    });
}

test "structure: coverage step enforces configured threshold" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    const build_steps_source = try support.readRepoFile("tools/build_steps.zig");
    defer std.testing.allocator.free(build_steps_source);
    const ci_source = try support.readRepoFile(".github/workflows/ci.yml");
    defer std.testing.allocator.free(ci_source);

    try std.testing.expect(std.mem.indexOf(u8, build_source, "coverage-threshold") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "orelse 85") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "check_coverage_threshold.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "addCoverageThresholdStep") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_source, "-Dcoverage-threshold=85") != null);
}

test "structure: coverage step includes focused unit test shards" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    const build_steps_source = try support.readRepoFile("tools/build_steps.zig");
    defer std.testing.allocator.free(build_steps_source);

    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "extra_coverage") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "addTestRunAndArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "focused_unit_coverage_artifacts") != null);
}

test "structure: coverage step cleans output root before kcov runs" {
    const build_steps_source = try support.readRepoFile("tools/build_steps.zig");
    defer std.testing.allocator.free(build_steps_source);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "addCoverageRootStep") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "rm") != null and std.mem.indexOf(u8, build_steps_source, "-rf") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "mkdir") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_steps_source, "coverage_run.step.dependOn(coverage_root_step)") != null);
}

test "structure: stale documentation artifacts are absent" {
    try support.expectRepoFilesAbsent(&[_][]const u8{
        "PROMPT.md",
        "docs/STATUS.md",
        "docs/verification-history.md",
        "docs/_refactor_facades.md",
        "tasks/todo.md",
        "tasks/lessons.md",
    });
}

test "structure: build script delegates bulky build-step wiring" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    try std.testing.expect(support.lineCount(build_source) <= 300);
    try std.testing.expect(std.mem.indexOf(u8, build_source, "@import(\"tools/build_steps.zig\")") != null);
}
