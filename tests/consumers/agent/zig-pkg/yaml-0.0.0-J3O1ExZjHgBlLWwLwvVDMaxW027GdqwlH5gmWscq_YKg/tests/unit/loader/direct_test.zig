//! Purpose: Verify direct event-to-value loader behavior and fallback parity.
//! Owns: Direct loader comparison tests for alias-free events and alias fallback.
//! Does not own: Parser event generation, public diagnostics, or typed loading.
//! Depends on: src/internal.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_internal");

const Event = internal.types.Event;
const ParseError = internal.types.ParseError;
const loader = internal.loader;
const Node = loader.Node;
const direct_loader = loader.direct;

test "loader direct: alias-free events match composed path" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow, .anchor = "root", .tag = "!root" } },
        .{ .scalar = .{ .value = "enabled" } },
        .{ .scalar = .{ .value = "true" } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{ .style = .flow, .anchor = "items" } },
        .{ .scalar = .{ .value = "1" } },
        .{ .scalar = .{ .value = "two", .style = .double_quoted, .tag = "tag:yaml.org,2002:str" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try expectDirectMatchesComposed(&events, .core, .reject, .preserve, null);
}

test "loader direct: stream events match composed path" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "first" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "false" } },
        .{ .scalar = .{ .value = "3" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try expectDirectMatchesComposed(&events, .core, .reject, .preserve, 2);
}

test "loader direct: load options match composed path" {
    const duplicate_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "first" } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "second" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try expectDirectErrorMatchesComposed(&duplicate_events, .core, .reject, .preserve, null);
    try expectDirectMatchesComposed(&duplicate_events, .failsafe, .allow, .preserve, null);

    const unknown_tag_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value", .tag = "!local" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try expectDirectErrorMatchesComposed(&unknown_tag_events, .core, .reject, .reject, null);
    try expectDirectMatchesComposed(&unknown_tag_events, .core, .reject, .preserve, null);
}

test "loader direct: duplicate key validation uses temporary allocator" {
    const pair_count = 40;
    var key_strings: [pair_count][]u8 = undefined;
    for (&key_strings, 0..) |*key, index| {
        key.* = try std.fmt.allocPrint(std.testing.allocator, "key-{d}", .{index});
    }
    defer for (key_strings) |key| std.testing.allocator.free(key);

    var events: [pair_count * 2 + 6]Event = undefined;
    events[0] = .stream_start;
    events[1] = .{ .document_start = .{} };
    events[2] = .{ .mapping_start = .{ .style = .block } };
    for (key_strings, 0..) |key, index| {
        events[3 + index * 2] = .{ .scalar = .{ .value = key } };
        events[4 + index * 2] = .{ .scalar = .{ .value = "value" } };
    }
    events[events.len - 3] = .mapping_end;
    events[events.len - 2] = .{ .document_end = .{} };
    events[events.len - 1] = .stream_end;

    var output_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena.deinit();
    var temporary_counter: LiveCountingAllocator = .{ .child = std.testing.allocator };

    const documents = try loader.loadStreamFromEventsWithFailure(
        output_arena.allocator(),
        temporary_counter.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
        null,
        true,
    );

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expectEqual(@as(usize, pair_count), documents[0].mapping.pairs.len);
    try std.testing.expect(temporary_counter.allocations > 0);
    try std.testing.expectEqual(@as(usize, 0), temporary_counter.live_bytes);
}

test "loader: alias events use composed fallback" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "value", .anchor = "item" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expect(!direct_loader.supports(&events));

    var loaded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loaded_arena.deinit();
    const loaded_documents = try loader.loadStreamFromEvents(
        loaded_arena.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
    );
    try std.testing.expectEqual(loaded_documents[0].sequence.items[0], loaded_documents[0].sequence.items[1]);

    var composed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composed_arena.deinit();
    const composed_documents = try loader.loadStreamFromEventsComposed(
        composed_arena.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
        null,
    );
    try expectDocumentsEqual(composed_documents, loaded_documents);
}

test "loader: fallback preserves alias limit behavior" {
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

    try std.testing.expect(!direct_loader.supports(&events));
    try expectLoadErrorMatchesComposed(&events, .core, .reject, .preserve, 0, null, null, ParseError.Unsupported);
    try expectLoadErrorMatchesComposed(&events, .core, .reject, .preserve, null, 1024, null, ParseError.Unsupported);
}

fn expectDirectMatchesComposed(
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_document_count: ?usize,
) !void {
    var direct_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer direct_arena.deinit();
    const direct_documents = try direct_loader.loadStreamFromEvents(
        direct_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_document_count,
        null,
    );

    var composed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composed_arena.deinit();
    const composed_documents = try loader.loadStreamFromEventsComposed(
        composed_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        null,
        null,
        max_document_count,
        null,
    );

    try expectDocumentsEqual(composed_documents, direct_documents);
}

fn expectDirectErrorMatchesComposed(
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_document_count: ?usize,
) !void {
    var direct_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer direct_arena.deinit();
    const direct_error = expectDirectLoadError(
        direct_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_document_count,
        null,
    );

    var composed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composed_arena.deinit();
    const composed_error = expectComposedLoadError(
        composed_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        null,
        null,
        max_document_count,
        null,
    );

    try std.testing.expectEqual(composed_error, direct_error);
}

fn expectLoadErrorMatchesComposed(
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
    expected_error: anyerror,
) !void {
    var loaded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loaded_arena.deinit();
    const loaded_error = expectLoadError(
        loaded_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        max_document_count,
    );

    var composed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composed_arena.deinit();
    const composed_error = expectComposedLoadError(
        composed_arena.allocator(),
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        max_document_count,
        null,
    );

    try std.testing.expectEqual(expected_error, loaded_error);
    try std.testing.expectEqual(composed_error, loaded_error);
}

fn expectLoadError(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
) anyerror {
    if (loader.loadStreamFromEvents(
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        max_document_count,
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        return err;
    }
}

fn expectDirectLoadError(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_document_count: ?usize,
    load_failure: ?*loader.LoadFailure,
) anyerror {
    if (direct_loader.loadStreamFromEvents(
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_document_count,
        load_failure,
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        return err;
    }
}

fn expectComposedLoadError(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
    unknown_tag_behavior: anytype,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
    load_failure: ?*loader.LoadFailure,
) anyerror {
    if (loader.loadStreamFromEventsComposed(
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        max_document_count,
        load_failure,
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        return err;
    }
}

fn expectDocumentsEqual(expected: []const *const Node, actual: []const *const Node) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_node, actual_node| {
        try expectNodesEqual(expected_node, actual_node);
    }
}

fn expectNodesEqual(expected: *const Node, actual: *const Node) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected.*), std.meta.activeTag(actual.*));
    switch (expected.*) {
        .null_value => |expected_value| {
            try expectOptionalStringEqual(expected_value.anchor, actual.null_value.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.null_value.tag);
        },
        .bool_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.bool_value.value);
            try expectOptionalStringEqual(expected_value.anchor, actual.bool_value.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.bool_value.tag);
        },
        .int_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.int_value.value);
            try expectOptionalStringEqual(expected_value.anchor, actual.int_value.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.int_value.tag);
        },
        .float_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.float_value.value);
            try expectOptionalStringEqual(expected_value.anchor, actual.float_value.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.float_value.tag);
        },
        .scalar => |expected_value| {
            try std.testing.expectEqualStrings(expected_value.value, actual.scalar.value);
            try std.testing.expectEqual(expected_value.style, actual.scalar.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.scalar.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.scalar.tag);
        },
        .sequence => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.sequence.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.sequence.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.sequence.tag);
            try std.testing.expectEqual(expected_value.items.len, actual.sequence.items.len);
            for (expected_value.items, actual.sequence.items) |expected_item, actual_item| {
                try expectNodesEqual(expected_item, actual_item);
            }
        },
        .mapping => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.mapping.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.mapping.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.mapping.tag);
            try std.testing.expectEqual(expected_value.pairs.len, actual.mapping.pairs.len);
            for (expected_value.pairs, actual.mapping.pairs) |expected_pair, actual_pair| {
                try expectNodesEqual(expected_pair.key, actual_pair.key);
                try expectNodesEqual(expected_pair.value, actual_pair.value);
            }
        },
        .alias => |expected_value| try std.testing.expectEqualStrings(expected_value, actual.alias),
    }
}

fn expectOptionalStringEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_value, actual.?);
    } else {
        try std.testing.expect(actual == null);
    }
}

const LiveCountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    live_bytes: usize = 0,

    fn allocator(self: *LiveCountingAllocator) std.mem.Allocator {
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
        const self: *LiveCountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.live_bytes += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveCountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveCountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveCountingAllocator = @ptrCast(@alignCast(context));
        self.live_bytes -= memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn countResize(self: *LiveCountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.live_bytes += new_len - old_len;
        } else {
            self.live_bytes -= old_len - new_len;
        }
    }
};
