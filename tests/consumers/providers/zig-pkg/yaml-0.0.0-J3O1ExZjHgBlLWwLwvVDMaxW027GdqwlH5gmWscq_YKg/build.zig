//! Purpose: Define the project build graph and public build steps.
//! Owns: Module wiring, test roots, conformance, coverage, Valgrind, docs, and aggregate build steps.
//! Does not own: Reusable build-step helper implementations.
//! Depends on: tools/build_steps.zig and std.Build.
//! Tested by: tests/structure/docs_tooling_test.zig and zig build test.

const std = @import("std");
const build_steps = @import("tools/build_steps.zig");

const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;
const addTestRun = build_steps.addTestRun;
const addTestRunAndArtifact = build_steps.addTestRunAndArtifact;

comptime {
    const required = std.SemanticVersion.parse(minimum_zig_version) catch unreachable;
    if (@import("builtin").zig_version.order(required) == .lt) {
        @compileError("This project requires Zig " ++ minimum_zig_version ++ " or newer.");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text.");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    // The self-hosted x86_64 backend (default on Linux since Zig 0.15) emits DWARF
    // that kcov v43 cannot parse, producing empty coverage reports. Opt into the
    // LLVM backend with -Duse-llvm=true for the coverage and valgrind CI steps.
    // See ziglang/zig#24463 and #25368.
    const use_llvm = b.option(bool, "use-llvm", "Build test binaries with the LLVM backend (needed for kcov coverage on Zig 0.16+).");
    const coverage_threshold = b.option(u8, "coverage-threshold", "Minimum line coverage percent required by test-coverage.") orelse 85;
    const yaml_test_suite_dir = b.option(
        []const u8,
        "yaml-test-suite-dir",
        "Path to the yaml-test-suite data directory used by conformance tests.",
    ) orelse "vendor/yaml-test-suite";
    const libfyaml_fy_tool = b.option(
        []const u8,
        "libfyaml-fy-tool",
        "Path to libfyaml's fy-tool executable for the optional libfyaml-compare step.",
    );
    const using_pinned_yaml_test_suite = std.mem.eql(u8, yaml_test_suite_dir, "vendor/yaml-test-suite");

    const yaml_mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const yaml_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = false,
    });

    const unit_tests = b.addTest(.{
        .root_module = yaml_unit_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test-unit", "Run library unit tests");
    unit_step.dependOn(&run_unit_tests.step);

    const yaml_imports: []const std.Build.Module.Import = &.{.{ .name = "yaml", .module = yaml_mod }};
    build_steps.addBenchmarkStep(b, target);

    const yaml_internal_mod = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const internal_imports: []const std.Build.Module.Import = &.{.{ .name = "yaml_internal", .module = yaml_internal_mod }};

    const schema_step = b.step("test-schema", "Run schema resolver unit tests");
    const FocusedUnitRoot = struct {
        root_source_file: []const u8,
        imports: []const std.Build.Module.Import,
    };
    const focused_unit_roots = [_]FocusedUnitRoot{
        .{ .root_source_file = "tests/unit/api/root_api_test.zig", .imports = yaml_imports },
        .{ .root_source_file = "tests/unit/api/load_string_ownership_test.zig", .imports = yaml_imports },
        .{ .root_source_file = "tests/unit/scanner/scanner_test.zig", .imports = yaml_imports },
        .{ .root_source_file = "tests/unit/reader/reader_test.zig", .imports = internal_imports },
        .{ .root_source_file = "tests/unit/api/parser_stream_test.zig", .imports = yaml_imports },
        .{ .root_source_file = "tests/unit/compose/composer_test.zig", .imports = internal_imports },
        .{ .root_source_file = "tests/unit/loader/loader_test.zig", .imports = internal_imports },
        .{ .root_source_file = "tests/unit/loader/direct_test.zig", .imports = internal_imports },
        .{ .root_source_file = "tests/unit/schema/schema_test.zig", .imports = internal_imports },
        .{ .root_source_file = "tools/benchmark.zig", .imports = internal_imports },
    };
    var focused_unit_coverage_artifacts: [focused_unit_roots.len + 1]*std.Build.Step.Compile = undefined;
    for (focused_unit_roots, 0..) |unit_root, index| {
        const focused_tests = addTestRunAndArtifact(b, .{
            .root_source_file = unit_root.root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = unit_root.imports,
            .filters = test_filters,
            .use_llvm = use_llvm,
        });
        focused_unit_coverage_artifacts[index] = focused_tests.compile;
        unit_step.dependOn(&focused_tests.run.step);
        if (std.mem.eql(u8, unit_root.root_source_file, "tests/unit/schema/schema_test.zig")) {
            schema_step.dependOn(&focused_tests.run.step);
        }
    }
    unit_step.dependOn(schema_step);

    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/yaml_suite_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = yaml_imports,
    });
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "yaml_test_suite_dir", yaml_test_suite_dir);
    conformance_options.addOption(bool, "using_pinned_yaml_test_suite", using_pinned_yaml_test_suite);
    conformance_mod.addOptions("conformance_options", conformance_options);

    const conformance_tests = b.addTest(.{
        .root_module = conformance_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const conformance_step = b.step("test-conformance", "Run yaml-test-suite conformance tests");
    conformance_step.dependOn(&run_conformance_tests.step);

    const event_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const direct_conformance_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/direct_conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml_event_parser", .module = event_parser_mod }},
    });
    const direct_conformance_options = b.addOptions();
    direct_conformance_options.addOption([]const u8, "yaml_test_suite_dir", yaml_test_suite_dir);
    direct_conformance_options.addOption(bool, "using_pinned_yaml_test_suite", using_pinned_yaml_test_suite);
    direct_conformance_mod.addOptions("direct_conformance_options", direct_conformance_options);

    const direct_conformance_tests = b.addTest(.{
        .root_module = direct_conformance_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_direct_conformance_tests = b.addRunArtifact(direct_conformance_tests);
    const direct_conformance_step = b.step("test-direct-conformance", "Run yaml-test-suite directly through scanner and parser layers");
    direct_conformance_step.dependOn(&run_direct_conformance_tests.step);

    const conformance_report_mod = b.createModule(.{
        .root_source_file = b.path("tools/report_conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    const conformance_report_exe = b.addExecutable(.{
        .name = "yaml-conformance-report",
        .root_module = conformance_report_mod,
    });
    const run_conformance_report = b.addRunArtifact(conformance_report_exe);
    run_conformance_report.addArg(yaml_test_suite_dir);
    run_conformance_report.step.dependOn(conformance_step);
    run_conformance_report.step.dependOn(direct_conformance_step);
    const conformance_report_step = b.step("conformance-report", "Run conformance tests and print yaml-test-suite coverage counts");
    conformance_report_step.dependOn(&run_conformance_report.step);

    const libfyaml_compare_step = b.step("libfyaml-compare", "Compare yaml-test-suite behavior with libfyaml fy-tool");
    if (b.findProgram(&.{"python3"}, &.{})) |python3| {
        if (libfyaml_fy_tool) |fy_tool| {
            const run_libfyaml_compare = b.addSystemCommand(&.{ python3, "tools/compare_libfyaml.py", fy_tool, yaml_test_suite_dir });
            run_libfyaml_compare.step.dependOn(conformance_report_step);
            libfyaml_compare_step.dependOn(&run_libfyaml_compare.step);
        } else if (b.findProgram(&.{"fy-tool"}, &.{})) |fy_tool| {
            const run_libfyaml_compare = b.addSystemCommand(&.{ python3, "tools/compare_libfyaml.py", fy_tool, yaml_test_suite_dir });
            run_libfyaml_compare.step.dependOn(conformance_report_step);
            libfyaml_compare_step.dependOn(&run_libfyaml_compare.step);
        } else |_| {
            const missing_fy_tool = b.addFail("fy-tool is required for 'zig build libfyaml-compare'; pass -Dlibfyaml-fy-tool=/path/to/fy-tool or install fy-tool on PATH.");
            libfyaml_compare_step.dependOn(&missing_fy_tool.step);
        }
    } else |_| {
        const missing_python = b.addFail("python3 is required for 'zig build libfyaml-compare'.");
        libfyaml_compare_step.dependOn(&missing_python.step);
    }

    const parser_tokens_unit_tests = addTestRunAndArtifact(b, .{
        .root_source_file = "tests/unit/parser/parser_tokens_test.zig",
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml_event_parser", .module = event_parser_mod }},
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    unit_step.dependOn(&parser_tokens_unit_tests.run.step);
    focused_unit_coverage_artifacts[focused_unit_roots.len] = parser_tokens_unit_tests.compile;

    const structure_step = b.step("test-structure", "Run repository structure checks");
    const structure_test_roots = [_][]const u8{
        "tests/structure/file_size_test.zig",
        "tests/structure/source_size_test.zig",
        "tests/structure/unit_size_test.zig",
        "tests/structure/api_boundary_test.zig",
        "tests/structure/docs_tooling_test.zig",
        "tests/structure/module_comment_test.zig",
        "tests/structure/ci_workflow_test.zig",
    };
    for (structure_test_roots) |root_source_file| {
        const run_structure_tests = addTestRun(b, .{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .filters = test_filters,
            .use_llvm = use_llvm,
        });
        structure_step.dependOn(&run_structure_tests.step);
    }

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/stress/stress.zig"),
        .target = target,
        .optimize = optimize,
        .imports = yaml_imports,
    });

    const stress_tests = b.addTest(.{
        .root_module = stress_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("test-stress", "Run generated stress and limit tests");
    stress_step.dependOn(&run_stress_tests.step);

    const allocation_mod = b.createModule(.{
        .root_source_file = b.path("tests/allocation/allocation_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = yaml_imports,
    });

    const allocation_tests = b.addTest(.{
        .root_module = allocation_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_allocation_tests = b.addRunArtifact(allocation_tests);
    const allocation_step = b.step("test-allocation", "Run allocator failure and cleanup tests");
    allocation_step.dependOn(&run_allocation_tests.step);

    const leak_step = b.step("test-leaks", "Run allocator-backed leak detection tests");
    leak_step.dependOn(unit_step);
    leak_step.dependOn(conformance_step);
    leak_step.dependOn(direct_conformance_step);
    leak_step.dependOn(stress_step);
    leak_step.dependOn(allocation_step);

    const extra_coverage_artifacts = focused_unit_coverage_artifacts;

    const test_artifacts: build_steps.TestArtifacts = .{
        .unit = unit_tests,
        .conformance = conformance_tests,
        .direct_conformance = direct_conformance_tests,
        .stress = stress_tests,
        .allocation = allocation_tests,
        .extra_coverage = &extra_coverage_artifacts,
    };
    build_steps.addValgrindStep(b, test_artifacts);
    build_steps.addCoverageStep(b, test_artifacts, .{
        .target = target,
        .optimize = optimize,
        .threshold_percent = coverage_threshold,
    });
    build_steps.addDocsStep(b, yaml_mod);

    const test_step = b.step("test", "Run unit, structure, conformance, direct-conformance, stress, and allocation tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(structure_step);
    test_step.dependOn(conformance_step);
    test_step.dependOn(direct_conformance_step);
    test_step.dependOn(stress_step);
    test_step.dependOn(allocation_step);
}
