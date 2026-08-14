//! Purpose: Provide a tiny typed allocation pool for batch-created internal nodes.
//! Owns: Generic fixed-count pool allocation and pointer handout.
//! Does not own: Graph semantics, value semantics, or pool lifetime policy.
//! Depends on: std.mem.Allocator.
//! Tested by: composer, loader, and allocation-failure tests.

const std = @import("std");

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pool: ?[]T = null,
        next: usize = 0,

        pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
            if (count == 0) return .{};
            return .{ .pool = try allocator.alloc(T, count) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.pool) |pool| allocator.free(pool);
            self.* = .{};
        }

        pub fn create(self: *Self) std.mem.Allocator.Error!*T {
            const pool = self.pool orelse return error.OutOfMemory;
            if (self.next >= pool.len) return error.OutOfMemory;
            const item = &pool[self.next];
            self.next += 1;
            return item;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
