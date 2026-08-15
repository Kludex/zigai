const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const error_tracing = b.option(bool, "error-tracing", "Enable Zig error return traces");
    const yaml_dependency = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const yaml = yaml_dependency.module("yaml");

    const zigai = b.addModule("zigai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = error_tracing,
    });
    _ = b.addModule("zopenai", .{
        .root_source_file = b.path("src/zopenai.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigai", .module = zigai }},
    });
    _ = b.addModule("zopenai_compatible", .{
        .root_source_file = b.path("src/zopenai_compatible.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigai", .module = zigai }},
    });
    _ = b.addModule("zanthropic", .{
        .root_source_file = b.path("src/zanthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigai", .module = zigai }},
    });
    _ = b.addModule("zgoogle", .{
        .root_source_file = b.path("src/zgoogle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigai", .module = zigai }},
    });

    const tests = b.addTest(.{
        .root_module = zigai,
    });
    const run_tests = b.addRunArtifact(tests);
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/agent_loop.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const cassette_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/provider_cassettes.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{
                .{ .name = "zigai", .module = zigai },
                .{ .name = "yaml", .module = yaml },
            },
        }),
    });
    const run_cassette_tests = b.addRunArtifact(cassette_tests);
    const cli_common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/common.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const run_cli_common_tests = b.addRunArtifact(cli_common_tests);
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{
                .{ .name = "zigai", .module = zigai },
                .{ .name = "yaml", .module = yaml },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const test_step = b.step("test", "Run the complete test suite");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_cassette_tests.step);
    test_step.dependOn(&run_cli_common_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    const check = b.step("check", "Compile all public packages");
    check.dependOn(&tests.step);
    check.dependOn(&integration_tests.step);
    check.dependOn(&cassette_tests.step);
    check.dependOn(&cli_common_tests.step);
    check.dependOn(&fuzz_tests.step);

    const openai_cli = addCli(b, target, optimize, zigai, "zigai-openai", "src/cli/openai.zig");
    const anthropic_cli = addCli(b, target, optimize, zigai, "zigai-anthropic", "src/cli/anthropic.zig");
    const google_cli = addCli(b, target, optimize, zigai, "zigai-google", "src/cli/google.zig");
    const http_smoke = addCli(b, target, optimize, zigai, "zigai-http-smoke", "tests/http_transport_smoke.zig");
    b.installArtifact(openai_cli);
    b.installArtifact(anthropic_cli);
    b.installArtifact(google_cli);
    check.dependOn(&openai_cli.step);
    check.dependOn(&anthropic_cli.step);
    check.dependOn(&google_cli.step);
    check.dependOn(&http_smoke.step);

    const examples = b.step("examples", "Compile runnable provider examples");
    inline for (.{ "openai", "anthropic", "google" }) |provider| {
        const executable = addCli(b, target, optimize, zigai, "example-" ++ provider, "examples/" ++ provider ++ ".zig");
        examples.dependOn(&executable.step);
        check.dependOn(&executable.step);
    }

    const docs = b.step("docs", "Generate Zig API documentation");
    const generate_docs = b.addSystemCommand(&.{"./scripts/docs"});
    docs.dependOn(&generate_docs.step);

    const recorder = b.addExecutable(.{
        .name = "zigai-record-cassettes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/record_cassettes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigai", .module = zigai },
                .{ .name = "yaml", .module = yaml },
            },
        }),
    });
    const run_recorder = b.addRunArtifact(recorder);
    if (b.args) |args| run_recorder.addArgs(args);
    const record_cassettes = b.step("record-cassettes", "Record real-provider model cassettes");
    record_cassettes.dependOn(&run_recorder.step);
}

fn addCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigai: *std.Build.Module,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
}
