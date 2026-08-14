//! Purpose: Stress nesting-depth limits for parsing, emitting, and dumping.
//! Owns: Deep collection construction and rejection tests.
//! Does not own: Byte-count limits, alias expansion, or large successful inputs.
//! Depends on: tests/stress/support.zig and yaml public API.
//! Tested by: zig build test-stress.

const std = @import("std");
const yaml = @import("yaml");
const support = @import("support.zig");

const allocator = support.allocator;

test "stress parseEvents rejects excessively deep block nesting" {
    const depth = 300;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..depth) |index| {
        for (0..index) |_| try input.appendSlice(allocator, "  ");
        try input.appendSlice(allocator, "-\n");
    }
    for (0..depth) |_| try input.appendSlice(allocator, "  ");
    try input.appendSlice(allocator, "leaf\n");

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEvents(allocator, input.items));
}

test "stress parseEvents accepts configured deep block nesting" {
    const depth = 300;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..depth) |index| {
        for (0..index) |_| try input.appendSlice(allocator, "  ");
        try input.appendSlice(allocator, "-\n");
    }
    for (0..depth) |_| try input.appendSlice(allocator, "  ");
    try input.appendSlice(allocator, "leaf\n");

    var events = try yaml.parseEventsWithOptions(allocator, input.items, .{ .max_nesting_depth = depth + 1 });
    defer events.deinit();
}

test "stress parseEvents accepts configured deep flow nesting" {
    const depth = 300;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..depth) |_| try input.append(allocator, '[');
    try input.appendSlice(allocator, "leaf");
    for (0..depth) |_| try input.append(allocator, ']');
    try input.append(allocator, '\n');

    var events = try yaml.parseEventsWithOptions(allocator, input.items, .{ .max_nesting_depth = depth + 1 });
    defer events.deinit();
}

test "stress loadStream accepts configured deep block nesting" {
    const depth = 300;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..depth) |index| {
        for (0..index) |_| try input.appendSlice(allocator, "  ");
        try input.appendSlice(allocator, "-\n");
    }
    for (0..depth) |_| try input.appendSlice(allocator, "  ");
    try input.appendSlice(allocator, "leaf\n");

    var stream = try yaml.loadStreamWithOptions(allocator, input.items, .{ .max_nesting_depth = depth + 1 });
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
}

test "stress loadStream accepts configured deep flow nesting" {
    const depth = 300;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..depth) |_| try input.append(allocator, '[');
    try input.appendSlice(allocator, "leaf");
    for (0..depth) |_| try input.append(allocator, ']');
    try input.append(allocator, '\n');

    var stream = try yaml.loadStreamWithOptions(allocator, input.items, .{ .max_nesting_depth = depth + 1 });
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
}

test "stress dump rejects excessively deep constructed nesting" {
    const depth = 300;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root = try support.nestedSequence(arena.allocator(), depth);

    const dumped = yaml.dump(allocator, root) catch |err| {
        try std.testing.expectEqual(yaml.ParseError.Unsupported, err);
        return;
    };
    defer allocator.free(dumped);
    return error.TestExpectedError;
}

test "stress dump accepts constructed nesting at depth budget" {
    const depth = 256;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root = try support.nestedSequence(arena.allocator(), depth);

    const dumped = try yaml.dump(allocator, root);
    defer allocator.free(dumped);

    var reparsed = try yaml.parseEvents(allocator, dumped);
    defer reparsed.deinit();
}

test "stress emitEvents rejects excessively deep constructed event nesting" {
    const depth = 300;

    var events: std.ArrayList(yaml.Event) = .empty;
    defer events.deinit(allocator);

    try events.append(allocator, .stream_start);
    try events.append(allocator, .{ .document_start = .{} });
    for (0..depth) |_| {
        try events.append(allocator, .{ .sequence_start = .{ .style = .block } });
    }
    try events.append(allocator, .{ .scalar = .{ .value = "leaf" } });
    for (0..depth) |_| {
        try events.append(allocator, .sequence_end);
    }
    try events.append(allocator, .{ .document_end = .{} });
    try events.append(allocator, .stream_end);

    const emitted = yaml.emitEvents(allocator, events.items) catch |err| {
        try std.testing.expectEqual(yaml.ParseError.Unsupported, err);
        return;
    };
    defer allocator.free(emitted);
    return error.TestExpectedError;
}
