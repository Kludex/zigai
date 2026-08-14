//! Purpose: Verify parser-event composition into representation graphs.
//! Owns: Composer behavior tests for anchors, aliases, recursion, and stream shape.
//! Does not own: Scanner, parser tokenization, schema construction, or public loading.
//! Depends on: src/compose/composer.zig, src/parser/event.zig, src/common/style.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_internal");

const composer = internal.composer;
const Event = composer.Event;
const ParseError = composer.ParseError;

test "composer: resolves aliases to anchored representation nodes" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .anchor = "item", .value = "one" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .sequence);
    try std.testing.expectEqual(@as(usize, 2), documents[0].sequence.items.len);
    try std.testing.expectEqual(documents[0].sequence.items[0], documents[0].sequence.items[1]);
}

test "composer: resolves aliases to the most recent duplicate anchor" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .anchor = "item", .value = "first" } },
        .{ .scalar = .{ .anchor = "item", .value = "second" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), documents[0].sequence.items.len);
    try std.testing.expect(documents[0].sequence.items[0] != documents[0].sequence.items[1]);
    try std.testing.expectEqual(documents[0].sequence.items[1], documents[0].sequence.items[2]);
    try std.testing.expectEqualStrings("first", documents[0].sequence.items[0].scalar.value);
    try std.testing.expectEqualStrings("second", documents[0].sequence.items[1].scalar.value);
}

test "composer: rejects undefined aliases" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "missing" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: rejects structural events where nodes are required" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: rejects aliases to anchors from previous documents" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "base", .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .alias = "base" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: supports recursive aliases to the current anchored node" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow, .anchor = "root" } },
        .{ .scalar = .{ .value = "self" } },
        .{ .alias = "root" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .mapping);
    try std.testing.expectEqual(@as(usize, 1), documents[0].mapping.pairs.len);
    try std.testing.expectEqual(documents[0], documents[0].mapping.pairs[0].value);
}

test "composer: enforces document and alias count limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "base", .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .alias = "base" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_document_count = 1,
    }));
    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_document_count = 2,
        .max_alias_count = 0,
    }));
}

test "composer: enforces alias expansion limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "base" } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .alias = "base" },
        .{ .alias = "base" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const accepted = try composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 6,
    });
    try std.testing.expectEqual(@as(usize, 1), accepted.len);

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 5,
    }));
}

test "composer: finite alias expansion limit rejects recursive aliases" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow, .anchor = "root" } },
        .{ .scalar = .{ .value = "self" } },
        .{ .alias = "root" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 1024,
    }));
}

test "composer: alias-free stream avoids completion tracking allocation" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "one" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var buffer: [4096]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var counted: CountingAllocator = .{ .child = fixed_buffer.allocator() };

    const documents = try composer.composeStream(counted.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expectEqualStrings("one", documents[0].scalar.value);
    try std.testing.expect(counted.allocations <= 3);
}

test "composer: wide mapping batches graph node allocation" {
    const pair_count = 64;
    var events = try std.testing.allocator.alloc(Event, pair_count * 2 + 6);
    defer std.testing.allocator.free(events);

    events[0] = .stream_start;
    events[1] = .{ .document_start = .{} };
    events[2] = .{ .mapping_start = .{ .style = .block } };
    for (0..pair_count) |index| {
        events[3 + index * 2] = .{ .scalar = .{ .value = "key" } };
        events[4 + index * 2] = .{ .scalar = .{ .value = "value" } };
    }
    events[events.len - 3] = .mapping_end;
    events[events.len - 2] = .{ .document_end = .{} };
    events[events.len - 1] = .stream_end;

    var buffer: [65536]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var counted: CountingAllocator = .{ .child = fixed_buffer.allocator() };

    const documents = try composer.composeStream(counted.allocator(), events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expectEqual(@as(usize, pair_count), documents[0].mapping.pairs.len);
    try std.testing.expect(counted.allocations <= 4);
}

test "composer: graph string slices borrow from events" {
    const root_anchor = "root";
    const root_tag = "!root";
    const key_value = "key";
    const sequence_anchor = "items";
    const sequence_tag = "!items";
    const scalar_value = "decoded value";
    const scalar_anchor = "item";
    const scalar_tag = "!item";
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block, .anchor = root_anchor, .tag = root_tag } },
        .{ .scalar = .{ .value = key_value } },
        .{ .sequence_start = .{ .style = .flow, .anchor = sequence_anchor, .tag = sequence_tag } },
        .{ .scalar = .{ .value = scalar_value, .anchor = scalar_anchor, .tag = scalar_tag } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    const root = documents[0].mapping;
    try std.testing.expectEqual(root_anchor.ptr, root.anchor.?.ptr);
    try std.testing.expectEqual(root_tag.ptr, root.tag.?.ptr);

    const key = root.pairs[0].key.scalar;
    try std.testing.expectEqual(key_value.ptr, key.value.ptr);

    const sequence = root.pairs[0].value.sequence;
    try std.testing.expectEqual(sequence_anchor.ptr, sequence.anchor.?.ptr);
    try std.testing.expectEqual(sequence_tag.ptr, sequence.tag.?.ptr);

    const scalar = sequence.items[0].scalar;
    try std.testing.expectEqual(scalar_value.ptr, scalar.value.ptr);
    try std.testing.expectEqual(scalar_anchor.ptr, scalar.anchor.?.ptr);
    try std.testing.expectEqual(scalar_tag.ptr, scalar.tag.?.ptr);
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
