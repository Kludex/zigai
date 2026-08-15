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
        .imports = &.{.{ .name = "yaml", .module = yaml }},
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
    const pydantic_ai_codec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pydantic_ai_codec.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const run_pydantic_ai_codec_tests = b.addRunArtifact(pydantic_ai_codec_tests);
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
    const spec_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/spec_common.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const run_spec_cli_tests = b.addRunArtifact(spec_cli_tests);
    const mcp_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mcp_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{
                .{ .name = "zigai", .module = zigai },
                .{ .name = "yaml", .module = yaml },
            },
        }),
    });
    const run_mcp_conformance_tests = b.addRunArtifact(mcp_conformance_tests);
    const mcp_interop = b.addExecutable(.{
        .name = "zigai-mcp-interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mcp_interop.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{
                .{ .name = "zigai", .module = zigai },
                .{ .name = "yaml", .module = yaml },
            },
        }),
    });
    const run_mcp_interop = b.addRunArtifact(mcp_interop);
    if (b.args) |args| run_mcp_interop.addArgs(args);
    const mcp_interop_step = b.step("mcp-interop", "Record an official MCP reference-server transcript");
    mcp_interop_step.dependOn(&run_mcp_interop.step);
    const mcp_upstream = b.addExecutable(.{
        .name = "zigai-mcp-upstream",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mcp_upstream.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "yaml", .module = yaml }},
        }),
    });
    const run_mcp_upstream = b.addRunArtifact(mcp_upstream);
    if (b.args) |args| run_mcp_upstream.addArgs(args);
    const mcp_upstream_step = b.step("mcp-upstream", "Print one pinned official MCP server revision");
    mcp_upstream_step.dependOn(&run_mcp_upstream.step);
    const mcp_conformance_client = b.addExecutable(.{
        .name = "zigai-mcp-conformance-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mcp_conformance_client.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const install_mcp_conformance_client = b.addInstallArtifact(mcp_conformance_client, .{});
    const mcp_conformance_client_step = b.step("mcp-conformance-client", "Build the official MCP conformance client adapter");
    mcp_conformance_client_step.dependOn(&install_mcp_conformance_client.step);
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
    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stress.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = error_tracing,
            .imports = &.{.{ .name = "zigai", .module = zigai }},
        }),
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("stress", "Run bounded stress and allocation-failure scenarios");
    stress_step.dependOn(&run_stress_tests.step);
    const fuzz_step = b.step("fuzz", "Run parser and protocol fuzz targets");
    fuzz_step.dependOn(&run_tests.step);
    fuzz_step.dependOn(&run_cli_common_tests.step);
    fuzz_step.dependOn(&run_spec_cli_tests.step);
    fuzz_step.dependOn(&run_mcp_conformance_tests.step);
    fuzz_step.dependOn(&run_fuzz_tests.step);
    const test_step = b.step("test", "Run the complete test suite");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_pydantic_ai_codec_tests.step);
    test_step.dependOn(&run_cassette_tests.step);
    test_step.dependOn(&run_cli_common_tests.step);
    test_step.dependOn(&run_spec_cli_tests.step);
    test_step.dependOn(&run_mcp_conformance_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    const check = b.step("check", "Compile all public packages");
    check.dependOn(&tests.step);
    check.dependOn(&integration_tests.step);
    check.dependOn(&pydantic_ai_codec_tests.step);
    check.dependOn(&cassette_tests.step);
    check.dependOn(&cli_common_tests.step);
    check.dependOn(&spec_cli_tests.step);
    check.dependOn(&mcp_conformance_tests.step);
    check.dependOn(&mcp_interop.step);
    check.dependOn(&mcp_upstream.step);
    check.dependOn(&mcp_conformance_client.step);
    check.dependOn(&fuzz_tests.step);

    const openai_cli = addCli(b, target, optimize, zigai, "zigai-openai", "src/cli/openai.zig");
    const anthropic_cli = addCli(b, target, optimize, zigai, "zigai-anthropic", "src/cli/anthropic.zig");
    const google_cli = addCli(b, target, optimize, zigai, "zigai-google", "src/cli/google.zig");
    const spec_cli = addCli(b, target, optimize, zigai, "zigai-agent-spec", "src/cli/spec.zig");
    const http_smoke = addCli(b, target, optimize, zigai, "zigai-http-smoke", "tests/http_transport_smoke.zig");
    const http_stress = addCli(b, target, optimize, zigai, "zigai-http-stress", "tests/http_stress.zig");
    const install_http_stress = b.addInstallArtifact(http_stress, .{});
    const stress_http_step = b.step("stress-http", "Build the real-socket reconnect stress executable");
    stress_http_step.dependOn(&install_http_stress.step);
    b.installArtifact(openai_cli);
    b.installArtifact(anthropic_cli);
    b.installArtifact(google_cli);
    b.installArtifact(spec_cli);
    check.dependOn(&openai_cli.step);
    check.dependOn(&anthropic_cli.step);
    check.dependOn(&google_cli.step);
    check.dependOn(&spec_cli.step);
    check.dependOn(&http_smoke.step);
    check.dependOn(&http_stress.step);
    check.dependOn(&stress_tests.step);

    const examples = b.step("examples", "Compile runnable provider examples");
    inline for (.{ "openai", "anthropic", "google", "ollama", "crusoe", "snowflake", "zai" }) |provider| {
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
    const record_cassettes = b.step("record-cassettes", "Record real-provider cassettes");
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
