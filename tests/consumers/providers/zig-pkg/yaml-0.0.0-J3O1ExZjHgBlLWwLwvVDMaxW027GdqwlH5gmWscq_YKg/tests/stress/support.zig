//! Purpose: Shared helpers for stress-test shards.
//! Owns: Common allocator, scalar assertions, and constructed deep-node helpers.
//! Does not own: Individual stress behavior assertions.
//! Depends on: yaml public API and std.testing.
//! Tested by: tests/stress/*.zig.

const std = @import("std");
const yaml = @import("yaml");

pub const allocator = std.testing.allocator;

pub fn expectScalar(node: *const yaml.Node, expected: []const u8) !void {
    try std.testing.expect(node.* == .scalar);
    try std.testing.expectEqualStrings(expected, node.scalar.value);
}

pub fn nestedSequence(arena_allocator: std.mem.Allocator, depth: usize) !*const yaml.Node {
    const leaf = try arena_allocator.create(yaml.Node);
    leaf.* = .{ .scalar = .{ .value = "leaf" } };

    var current: *const yaml.Node = leaf;
    for (0..depth) |_| {
        const items = try arena_allocator.alloc(*const yaml.Node, 1);
        items[0] = current;

        const sequence = try arena_allocator.create(yaml.Node);
        sequence.* = .{ .sequence = .{ .items = items } };
        current = sequence;
    }

    return current;
}
