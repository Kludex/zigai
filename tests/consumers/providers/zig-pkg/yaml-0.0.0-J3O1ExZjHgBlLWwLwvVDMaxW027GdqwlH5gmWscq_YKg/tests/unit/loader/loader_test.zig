//! Purpose: Verify focused loader-layer entry points.
//! Owns: Loader bridge behavior that is not part of the public root API.
//! Does not own: Parser event generation, schema scalar rules, or public diagnostics.
//! Depends on: src/internal.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_internal");
const Event = internal.types.Event;
const loader = internal.loader;

test "loader: loadStreamFromEvents constructs document roots without failure sink" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try loader.loadStreamFromEvents(
        arena.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .scalar);
    try std.testing.expectEqualStrings("value", documents[0].scalar.value);
}

test "loader: alias-free events avoid construction identity map allocation" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var buffer: [8192]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var counted: CountingAllocator = .{ .child = fixed_buffer.allocator() };

    const documents = try loader.loadStreamFromEvents(
        counted.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .scalar);
    try std.testing.expectEqualStrings("value", documents[0].scalar.value);
    try std.testing.expect(counted.allocations <= 6);
}

test "loader: alias-free sequence batches value node allocation" {
    const item_count = 64;
    var events = try std.testing.allocator.alloc(Event, item_count + 6);
    defer std.testing.allocator.free(events);

    events[0] = .stream_start;
    events[1] = .{ .document_start = .{} };
    events[2] = .{ .sequence_start = .{ .style = .block } };
    for (0..item_count) |index| {
        events[3 + index] = .{ .scalar = .{ .value = "1" } };
    }
    events[events.len - 3] = .sequence_end;
    events[events.len - 2] = .{ .document_end = .{} };
    events[events.len - 1] = .stream_end;
    var buffer: [65536]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var counted: CountingAllocator = .{ .child = fixed_buffer.allocator() };
    const documents = try loader.loadStreamFromEvents(
        counted.allocator(),
        events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expectEqual(@as(usize, item_count), documents[0].sequence.items.len);
    try std.testing.expect(counted.allocations <= 6);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,

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
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
