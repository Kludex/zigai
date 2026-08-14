//! Purpose: Verify parser and loader hot paths avoid pathological allocation growth.
//! Owns: Allocation-count regression checks for performance-sensitive inputs.
//! Does not own: Allocation-failure injection or public API behavior tests.
//! Depends on: yaml public API and std.testing.
//! Tested by: zig build test-allocation.

const std = @import("std");
const yaml = @import("yaml");

test "parseEvents keeps nested flow allocation bounded" {
    const input = try generateNestedFlow(std.testing.allocator, 32);
    defer std.testing.allocator.free(input);

    var counter: CountingAllocator = .{ .child = std.testing.allocator };
    const counted_allocator = counter.allocator();

    var events = try yaml.parseEvents(counted_allocator, input);
    defer events.deinit();

    try std.testing.expect(events.events.len > 0);
    try std.testing.expect(counter.allocated_bytes < 2 * 1024 * 1024);
}

fn generateNestedFlow(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, count * 180);
    try out.appendSlice(allocator, "root:\n");
    for (0..count) |index| {
        try out.print(allocator, "  node_{d}: {{id: {d}, meta: {{name: node-{d}, flags: [true, false, null], nested: {{a: value-{d}, b: [one, two, three]}}}}, edges: [{{to: node_{d}, weight: {d}}}, {{to: node_{d}, weight: {d}}}]}}\n", .{
            index,
            index,
            index,
            index,
            (index + 1) % count,
            index * 3,
            (index + 2) % count,
            index * 5,
        });
    }
    return out.toOwnedSlice(allocator);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.allocated_bytes += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.freed_bytes += memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn countResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.allocated_bytes += new_len - old_len;
        } else {
            self.freed_bytes += old_len - new_len;
        }
    }
};
