const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zigai", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "zigai-agent-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigai", .module = dependency.module("zigai") }},
        }),
    });
    const run = b.addRunArtifact(executable);
    b.step("run", "Build and run the public Agent API consumer").dependOn(&run.step);
}
