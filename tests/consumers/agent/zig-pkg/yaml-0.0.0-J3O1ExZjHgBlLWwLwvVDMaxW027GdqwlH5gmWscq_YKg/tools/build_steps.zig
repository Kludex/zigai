//! Purpose: Shared build-step helpers for the Zig build graph.
//! Owns: Reusable test, Valgrind, coverage, and docs build-step wiring.
//! Does not own: Project-specific step selection or module definitions.
//! Depends on: std.Build only.
//! Tested by: tests/structure/docs_tooling_test.zig and zig build test.

const std = @import("std");

pub const TestRootOptions = struct {
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import = &.{},
    filters: []const []const u8 = &.{},
    use_llvm: ?bool = null,
};

pub const TestArtifacts = struct {
    unit: *std.Build.Step.Compile,
    conformance: *std.Build.Step.Compile,
    direct_conformance: *std.Build.Step.Compile,
    stress: *std.Build.Step.Compile,
    allocation: *std.Build.Step.Compile,
    extra_coverage: []const *std.Build.Step.Compile = &.{},
};

pub const CoverageOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    threshold_percent: u8,
};

pub const TestRunAndArtifact = struct {
    compile: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

pub fn addTestRun(b: *std.Build, options: TestRootOptions) *std.Build.Step.Run {
    return addTestRunAndArtifact(b, options).run;
}

pub fn addTestRunAndArtifact(b: *std.Build, options: TestRootOptions) TestRunAndArtifact {
    const module = b.createModule(.{
        .root_source_file = b.path(options.root_source_file),
        .target = options.target,
        .optimize = options.optimize,
        .imports = options.imports,
    });
    const tests = b.addTest(.{
        .root_module = module,
        .filters = options.filters,
        .use_llvm = options.use_llvm,
    });
    return .{
        .compile = tests,
        .run = b.addRunArtifact(tests),
    };
}

pub fn addBenchmarkStep(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const yaml_internal_mod = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("tools/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "yaml_internal", .module = yaml_internal_mod }},
    });
    const benchmark_exe = b.addExecutable(.{
        .name = "yaml-benchmark",
        .root_module = benchmark_mod,
    });
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("bench", "Run parser and loader benchmarks in ReleaseFast");
    benchmark_step.dependOn(&run_benchmark.step);
}

pub fn addValgrindStep(b: *std.Build, artifacts: TestArtifacts) void {
    const valgrind_step = b.step("test-valgrind", "Run test binaries under Valgrind leak checking");
    const valgrind = b.findProgram(&.{"valgrind"}, &.{}) catch {
        const missing_valgrind = b.addFail("valgrind is required for 'zig build test-valgrind'; install valgrind or run 'zig build test-leaks' for allocator-backed leak checks.");
        valgrind_step.dependOn(&missing_valgrind.step);
        return;
    };

    const valgrind_args = &.{
        valgrind,
        "--leak-check=full",
        "--show-leak-kinds=all",
        "--errors-for-leak-kinds=all",
        "--error-exitcode=1",
    };

    addArtifactCommandDependency(b, valgrind_step, valgrind_args, artifacts.unit);
    addArtifactCommandDependency(b, valgrind_step, valgrind_args, artifacts.conformance);
    addArtifactCommandDependency(b, valgrind_step, valgrind_args, artifacts.direct_conformance);
    addArtifactCommandDependency(b, valgrind_step, valgrind_args, artifacts.stress);
    addArtifactCommandDependency(b, valgrind_step, valgrind_args, artifacts.allocation);
}

pub fn addCoverageStep(b: *std.Build, artifacts: TestArtifacts, options: CoverageOptions) void {
    const coverage_step = b.step("test-coverage", "Run tests under kcov and merge source coverage reports");
    const kcov = b.findProgram(&.{"kcov"}, &.{}) catch {
        const missing_kcov = b.addFail("kcov is required for 'zig build test-coverage'; install kcov or run the non-coverage test steps instead.");
        coverage_step.dependOn(&missing_kcov.step);
        addCoverageAlias(b, coverage_step);
        return;
    };

    const coverage_root = "zig-out/coverage";
    const coverage_root_step = addCoverageRootStep(b, coverage_root);
    const coverage_merge = b.addSystemCommand(&.{
        kcov,
        "--merge",
        "--dump-summary",
        b.pathJoin(&.{ coverage_root, "merged" }),
    });

    addCoverageMergeInput(b, coverage_merge, &coverage_root_step.step, kcov, coverage_root, "unit", artifacts.unit);
    addCoverageMergeInput(b, coverage_merge, &coverage_root_step.step, kcov, coverage_root, "conformance", artifacts.conformance);
    addCoverageMergeInput(b, coverage_merge, &coverage_root_step.step, kcov, coverage_root, "direct-conformance", artifacts.direct_conformance);
    addCoverageMergeInput(b, coverage_merge, &coverage_root_step.step, kcov, coverage_root, "stress", artifacts.stress);
    addCoverageMergeInput(b, coverage_merge, &coverage_root_step.step, kcov, coverage_root, "allocation", artifacts.allocation);
    for (artifacts.extra_coverage, 0..) |artifact, index| {
        addCoverageMergeInput(
            b,
            coverage_merge,
            &coverage_root_step.step,
            kcov,
            coverage_root,
            b.fmt("extra-{d}", .{index}),
            artifact,
        );
    }

    const threshold_check = addCoverageThresholdStep(b, coverage_root, options);
    threshold_check.step.dependOn(&coverage_merge.step);
    coverage_step.dependOn(&threshold_check.step);
    addCoverageAlias(b, coverage_step);
}

pub fn addCoverageThresholdStep(
    b: *std.Build,
    coverage_root: []const u8,
    options: CoverageOptions,
) *std.Build.Step.Run {
    const threshold_mod = b.createModule(.{
        .root_source_file = b.path("tools/check_coverage_threshold.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    const threshold_exe = b.addExecutable(.{
        .name = "yaml-check-coverage-threshold",
        .root_module = threshold_mod,
    });
    const run_threshold_check = b.addRunArtifact(threshold_exe);
    run_threshold_check.addArg(b.pathJoin(&.{ coverage_root, "merged" }));
    run_threshold_check.addArg(b.fmt("{d}", .{options.threshold_percent}));
    return run_threshold_check;
}

pub fn addDocsStep(b: *std.Build, yaml_mod: *std.Build.Module) void {
    const docs_obj = b.addObject(.{
        .name = "yaml-docs",
        .root_module = yaml_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate public API documentation");
    docs_step.dependOn(&install_docs.step);
}

fn addArtifactCommandDependency(
    b: *std.Build,
    step: *std.Build.Step,
    argv: []const []const u8,
    artifact: *std.Build.Step.Compile,
) void {
    const command = b.addSystemCommand(argv);
    command.addArtifactArg(artifact);
    step.dependOn(&command.step);
}

fn addCoverageCommand(
    b: *std.Build,
    kcov: []const u8,
    output_dir: []const u8,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    // --include-pattern/--exclude-pattern are substring matches against the full
    // source path recorded in DWARF; --include-path/--exclude-path require a
    // path-component match that breaks under containerised CI checkouts.
    // --collect-only defers reporting to the merge step, where one summary is
    // produced from all artifacts together.
    const command = b.addSystemCommand(&.{
        kcov,
        "--collect-only",
        "--clean",
        "--include-pattern=/src/",
        "--exclude-pattern=/tests/,/vendor/,/.zig-cache/,/zig-out/",
        output_dir,
    });
    command.addArtifactArg(artifact);
    return command;
}

fn addCoverageMergeInput(
    b: *std.Build,
    coverage_merge: *std.Build.Step.Run,
    coverage_root_step: *std.Build.Step,
    kcov: []const u8,
    coverage_root: []const u8,
    name: []const u8,
    artifact: *std.Build.Step.Compile,
) void {
    const output_dir = b.pathJoin(&.{ coverage_root, name });
    const coverage_run = addCoverageCommand(b, kcov, output_dir, artifact);
    coverage_run.step.dependOn(coverage_root_step);
    coverage_merge.step.dependOn(&coverage_run.step);
    coverage_merge.addArg(output_dir);
}

fn addCoverageRootStep(b: *std.Build, coverage_root: []const u8) *std.Build.Step.Run {
    const clean = b.addSystemCommand(&.{ "rm", "-rf", coverage_root });
    const make = b.addSystemCommand(&.{ "mkdir", "-p", coverage_root });
    make.step.dependOn(&clean.step);
    return make;
}

fn addCoverageAlias(b: *std.Build, coverage_step: *std.Build.Step) void {
    const coverage_alias_step = b.step("coverage", "Alias for test-coverage");
    coverage_alias_step.dependOn(coverage_step);
}
