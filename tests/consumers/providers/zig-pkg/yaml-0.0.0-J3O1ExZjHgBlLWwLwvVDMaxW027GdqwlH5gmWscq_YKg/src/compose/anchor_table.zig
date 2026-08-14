//! Purpose: Track YAML anchors while composing parser events.
//! Owns: Anchor-name to representation-node lookup storage.
//! Does not own: Alias validation, node construction, schema resolution, or public values.
//! Depends on: compose/node.zig.
//! Tested by: tests/unit/compose/composer_test.zig.

const std = @import("std");
const graph = @import("node.zig");

const Node = graph.Node;

/// Per-document table of anchors visible to alias events.
pub const AnchorTable = struct {
    entries: std.StringArrayHashMapUnmanaged(*const Node) = .empty,

    pub fn deinit(self: *AnchorTable, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *AnchorTable) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn remember(self: *AnchorTable, allocator: std.mem.Allocator, anchor: ?[]const u8, node: *const Node) std.mem.Allocator.Error!void {
        if (anchor) |name| {
            try self.entries.put(allocator, name, node);
        }
    }

    pub fn get(self: *const AnchorTable, alias: []const u8) ?*const Node {
        return self.entries.get(alias);
    }
};

test {
    std.testing.refAllDecls(@This());
}
