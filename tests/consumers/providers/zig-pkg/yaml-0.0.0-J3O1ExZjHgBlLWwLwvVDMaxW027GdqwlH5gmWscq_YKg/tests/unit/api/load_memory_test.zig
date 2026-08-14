//! Purpose: Verify public load temporary-storage memory boundaries.
//! Owns: Public load/loadStream allocation lifetime regression tests.
//! Does not own: General load behavior, string decoding, parser events, or diagnostics.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const expectScalarString = support.expectScalarString;
const loadStreamWithOptions = support.loadStreamWithOptions;

test "loadStreamWithOptions source-line fast path avoids scanner storage" {
    var counter: LiveTrackingAllocator = .{ .child = std.testing.allocator };

    var stream = try loadStreamWithOptions(counter.allocator(),
        \\name: yaml
        \\version: 1
        \\enabled: true
        \\
    , .{});
    defer stream.deinit();

    try std.testing.expectEqual(counter.live_bytes, counter.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    try std.testing.expect(stream.documents[0].* == .mapping);
}

test "loadStreamWithOptions fast path releases parser storage before returning" {
    var counter: LiveTrackingAllocator = .{ .child = std.testing.allocator };
    const input = try std.testing.allocator.dupe(u8,
        \\!<tag:example.com,2000:map> &map
        \\plain: plain value
        \\single: 'single ''quoted'' value'
        \\double: "decoded\nvalue"
        \\tagged: !<tag:example.com,2000:tag> &tagged tagged value
        \\
    );

    var stream = try loadStreamWithOptions(counter.allocator(), input, .{});
    defer stream.deinit();

    const retained_after_load = counter.live_bytes;
    const peak_during_load = counter.peak_live_bytes;

    @memset(input, 0xa5);
    std.testing.allocator.free(input);

    try std.testing.expect(peak_during_load > retained_after_load);
    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("map", root.mapping.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 4), root.mapping.pairs.len);

    try expectScalarString(root.mapping.pairs[0].value, "plain value");
    try expectScalarString(root.mapping.pairs[1].value, "single 'quoted' value");
    try expectScalarString(root.mapping.pairs[2].value, "decoded\nvalue");

    const tagged = root.mapping.pairs[3].value;
    try expectScalarString(tagged, "tagged value");
    try std.testing.expectEqualStrings("tagged", tagged.scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:tag", tagged.scalar.tag.?);
}

const LiveTrackingAllocator = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *LiveTrackingAllocator) std.mem.Allocator {
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
        const self: *LiveTrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.addLiveBytes(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveTrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveTrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveTrackingAllocator = @ptrCast(@alignCast(context));
        self.live_bytes -= memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn countResize(self: *LiveTrackingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.addLiveBytes(new_len - old_len);
        } else {
            self.live_bytes -= old_len - new_len;
        }
    }

    fn addLiveBytes(self: *LiveTrackingAllocator, len: usize) void {
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }
};
