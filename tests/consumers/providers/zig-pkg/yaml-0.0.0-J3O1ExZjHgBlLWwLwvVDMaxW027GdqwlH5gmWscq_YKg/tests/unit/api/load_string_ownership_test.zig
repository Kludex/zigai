//! Purpose: Verify public load string decoding and ownership boundaries.
//! Owns: Loader string copy/lifetime regressions for decoded scalar data and metadata.
//! Does not own: General load behavior, tag policy, dumping, or parser diagnostics.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const expectScalarString = support.expectScalarString;
const loadStreamWithOptions = support.loadStreamWithOptions;

test "load preserves decoded scalar text with tags anchors and aliases" {
    var document = try support.load(std.testing.allocator,
        \\single: 'single ''quoted'' value'
        \\double: "escaped\nline and \t tab"
        \\literal: |
        \\  line one
        \\  line two
        \\tagged: !<tag:example.com,2000:tagged> tagged value
        \\anchored: &item "alias target"
        \\alias: *item
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 6), document.root.mapping.pairs.len);

    try expectScalarString(document.root.mapping.pairs[0].value, "single 'quoted' value");
    try expectScalarString(document.root.mapping.pairs[1].value, "escaped\nline and \t tab");
    try expectScalarString(document.root.mapping.pairs[2].value, "line one\nline two\n");

    const tagged = document.root.mapping.pairs[3].value;
    try expectScalarString(tagged, "tagged value");
    try std.testing.expectEqualStrings("tag:example.com,2000:tagged", tagged.scalar.tag.?);

    const anchored = document.root.mapping.pairs[4].value;
    try expectScalarString(anchored, "alias target");
    try std.testing.expectEqualStrings("item", anchored.scalar.anchor.?);
    try std.testing.expectEqual(anchored, document.root.mapping.pairs[5].value);
}

test "loadStreamWithOptions owns strings after parser events are released" {
    var poison: PoisonOnFreeAllocator = .{ .child = std.testing.allocator };

    var stream = try loadStreamWithOptions(poison.allocator(),
        \\!<tag:example.com,2000:map> &map
        \\name: &name !<tag:example.com,2000:name> "decoded\nvalue"
        \\ref: *name
        \\
    , .{});
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("map", root.mapping.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 2), root.mapping.pairs.len);

    try expectScalarString(root.mapping.pairs[0].key, "name");
    const value = root.mapping.pairs[0].value;
    try expectScalarString(value, "decoded\nvalue");
    try std.testing.expectEqualStrings("name", value.scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:name", value.scalar.tag.?);

    try expectScalarString(root.mapping.pairs[1].key, "ref");
    try std.testing.expectEqual(value, root.mapping.pairs[1].value);
}

test "loadStreamWithOptions fast path owns strings after input is released" {
    const input = try std.testing.allocator.dupe(u8,
        \\!<tag:example.com,2000:map> &map
        \\name: &name !<tag:example.com,2000:name> "decoded\nvalue"
        \\
    );

    var stream = try loadStreamWithOptions(std.testing.allocator, input, .{});
    defer stream.deinit();

    @memset(input, 0xa5);
    std.testing.allocator.free(input);

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("map", root.mapping.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", root.mapping.tag.?);

    try expectScalarString(root.mapping.pairs[0].key, "name");
    const value = root.mapping.pairs[0].value;
    try expectScalarString(value, "decoded\nvalue");
    try std.testing.expectEqualStrings("name", value.scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:name", value.scalar.tag.?);
}

test "loadStreamWithOptions fast path retains decoded normalized scalar metadata" {
    const input = try utf16Le(std.testing.allocator, "!<tag:example.com,2000:map> &map\r\n" ++
        "plain: plain value\r\n" ++
        "single: 'single ''quoted'' value'\r\n" ++
        "double: \"decoded\\nvalue\"\r\n" ++
        "literal: |\r\n" ++
        "  line one\r\n" ++
        "  line two\r\n" ++
        "tagged: !<tag:example.com,2000:tag> &tagged tagged value\r\n");

    var stream = try loadStreamWithOptions(std.testing.allocator, input, .{});
    defer stream.deinit();

    @memset(input, 0xa5);
    std.testing.allocator.free(input);

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("map", root.mapping.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 5), root.mapping.pairs.len);

    try expectScalarString(root.mapping.pairs[0].value, "plain value");
    try expectScalarString(root.mapping.pairs[1].value, "single 'quoted' value");
    try expectScalarString(root.mapping.pairs[2].value, "decoded\nvalue");
    try expectScalarString(root.mapping.pairs[3].value, "line one\nline two\n");

    const tagged = root.mapping.pairs[4].value;
    try expectScalarString(tagged, "tagged value");
    try std.testing.expectEqualStrings("tagged", tagged.scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:tag", tagged.scalar.tag.?);
}

fn utf16Le(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, 2 + input.len * 2);
    try out.appendSlice(allocator, &.{ 0xff, 0xfe });
    for (input) |byte| {
        try out.append(allocator, byte);
        try out.append(allocator, 0);
    }
    return out.toOwnedSlice(allocator);
}

const PoisonOnFreeAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *PoisonOnFreeAllocator) std.mem.Allocator {
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
        const self: *PoisonOnFreeAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonOnFreeAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonOnFreeAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonOnFreeAllocator = @ptrCast(@alignCast(context));
        @memset(memory, 0xa5);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
