const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zigai", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "zigai-provider-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigai", .module = dependency.module("zigai") },
                .{ .name = "zopenai", .module = dependency.module("zopenai") },
                .{ .name = "zanthropic", .module = dependency.module("zanthropic") },
                .{ .name = "zgoogle", .module = dependency.module("zgoogle") },
                .{ .name = "zopenai_compatible", .module = dependency.module("zopenai_compatible") },
            },
        }),
    });
    const run = b.addRunArtifact(executable);
    b.step("run", "Build and run the public provider-package consumer").dependOn(&run.step);
}
