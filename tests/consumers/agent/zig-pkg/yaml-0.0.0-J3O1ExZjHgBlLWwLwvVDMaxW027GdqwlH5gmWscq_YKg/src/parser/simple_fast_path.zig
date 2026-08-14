//! Purpose: Emit events for strict simple block collection fast paths.
//! Owns: Narrow token-shape predicates for fallback-safe parser shortcuts.
//! Does not own: General YAML grammar, scanner tokenization, or loader behavior.
//! Depends on: scanner tokens, parser event types, and plain scalar token rules.
//! Tested by: in-file tests and parser unit tests.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const types = @import("event.zig");
const internal = @import("internal.zig");
const scalar_parser = @import("scalar.zig");

const Error = types.Error;
const EventBuilder = internal.EventBuilder;

const max_simple_implicit_key_bytes: usize = 1024;

pub fn appendBlockMappingDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *EventBuilder,
) Error!bool {
    const pair_count = simpleBlockMappingPairCount(tokens) orelse return false;

    try events.ensureTotalCapacity(allocator, events.slice().len + 4 + pair_count * 2);
    try events.append(allocator, .{ .document_start = .{} });
    try events.append(allocator, .{ .mapping_start = .{ .style = .block } });

    var index: usize = 1;
    while (index < tokens.len - 1) {
        index += 1;
        try appendSimpleScalarEvent(allocator, events, tokens[index].scalar);
        index += 2;
        try appendSimpleScalarEvent(allocator, events, tokens[index].scalar);
        index += 1;
    }

    try events.append(allocator, .mapping_end);
    try events.append(allocator, .{ .document_end = .{} });
    return true;
}

pub fn appendBlockSequenceDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *EventBuilder,
) Error!bool {
    _ = simpleBlockSequenceItemCount(tokens) orelse return false;

    try events.ensureTotalCapacity(allocator, events.slice().len + tokens.len + 4);
    try events.append(allocator, .{ .document_start = .{} });
    try events.append(allocator, .{ .sequence_start = .{ .style = .block } });

    var index: usize = 1;
    while (index < tokens.len - 1) {
        index += 2;
        if (index + 1 < tokens.len - 1 and tokens[index + 1] == .block_mapping_value) {
            try appendSimpleCompactMappingItem(allocator, events, tokens, &index);
        } else {
            try appendSimpleScalarEvent(allocator, events, tokens[index].scalar);
            index += 1;
        }
    }

    try events.append(allocator, .sequence_end);
    try events.append(allocator, .{ .document_end = .{} });
    return true;
}

fn simpleBlockMappingPairCount(tokens: []const scanner.Token) ?usize {
    if (tokens.len < 6 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var count: usize = 0;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimplePlainScalarToken(tokens[index].scalar)) return null;
        index += 1;

        count += 1;
    }

    return if (count == 0) null else count;
}

fn simpleBlockSequenceItemCount(tokens: []const scanner.Token) ?usize {
    if (tokens.len < 4 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var count: usize = 0;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;
        if (index >= tokens.len - 1 or tokens[index] != .block_sequence_entry) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimplePlainScalarToken(tokens[index].scalar)) return null;
        if (index + 1 < tokens.len - 1 and tokens[index + 1] == .block_mapping_value) {
            if (!isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
            index += 2;
            if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimplePlainScalarToken(tokens[index].scalar)) return null;
            index += 1;

            var mapping_indent: ?usize = null;
            while (index < tokens.len - 1) {
                if (tokens[index] != .indent) return null;
                const indent = tokens[index].indent;
                if (indent == 0) break;
                if (mapping_indent) |expected| {
                    if (indent != expected) return null;
                } else {
                    mapping_indent = indent;
                }
                index += 1;

                if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
                index += 1;
                if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
                index += 1;
                if (index >= tokens.len - 1 or tokens[index] != .scalar or !isSimplePlainScalarToken(tokens[index].scalar)) return null;
                index += 1;
            }
        } else {
            index += 1;
        }

        count += 1;
    }

    return if (count == 0) null else count;
}

fn appendSimpleCompactMappingItem(
    allocator: std.mem.Allocator,
    events: *EventBuilder,
    tokens: []const scanner.Token,
    index: *usize,
) std.mem.Allocator.Error!void {
    try events.append(allocator, .{ .mapping_start = .{ .style = .block } });

    while (true) {
        try appendSimpleScalarEvent(allocator, events, tokens[index.*].scalar);
        index.* += 2;
        try appendSimpleScalarEvent(allocator, events, tokens[index.*].scalar);
        index.* += 1;

        if (index.* >= tokens.len - 1 or tokens[index.*] != .indent or tokens[index.*].indent == 0) break;
        index.* += 1;
    }

    try events.append(allocator, .mapping_end);
}

fn appendSimpleScalarEvent(allocator: std.mem.Allocator, events: *EventBuilder, value: []const u8) std.mem.Allocator.Error!void {
    try events.append(allocator, .{ .scalar = .{ .value = try allocator.dupe(u8, value) } });
}

pub fn isSimplePlainScalarToken(value: []const u8) bool {
    if (!scalar_parser.isPlainScalarToken(value)) return false;
    if (std.mem.eql(u8, value, "-") or std.mem.eql(u8, value, "?")) return false;
    return std.mem.indexOfAny(u8, value, " \t\r\n") == null;
}

pub fn isSimpleBlockMappingKeyToken(value: []const u8) bool {
    return value.len <= max_simple_implicit_key_bytes and isSimplePlainScalarToken(value);
}

test "simple block mapping fast path emits scalar mapping events" {
    var token_stream = try scanner.scan(std.testing.allocator, "foo: bar\nbaz: qux\n");
    defer token_stream.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var events: EventBuilder = .{};
    try events.append(allocator, .stream_start);
    try std.testing.expect(try appendBlockMappingDocumentEvents(allocator, token_stream.tokens, &events));
    try events.append(allocator, .stream_end);

    try std.testing.expectEqual(@as(usize, 10), events.slice().len);
    try std.testing.expect(events.slice()[1] == .document_start);
    try std.testing.expect(events.slice()[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, events.slice()[2].mapping_start.style);
    try std.testing.expectEqualStrings("foo", events.slice()[3].scalar.value);
    try std.testing.expectEqualStrings("bar", events.slice()[4].scalar.value);
    try std.testing.expectEqualStrings("baz", events.slice()[5].scalar.value);
    try std.testing.expectEqualStrings("qux", events.slice()[6].scalar.value);
    try std.testing.expect(events.slice()[7] == .mapping_end);
    try std.testing.expect(events.slice()[8] == .document_end);
}

test "simple block mapping fast path declines unsupported shapes before emitting" {
    const cases = [_][]const u8{
        "foo bar: baz\n",
        "foo: bar baz\n",
        "foo: &anchor bar\n",
        "foo: [bar]\n",
        "foo:\n  nested: value\n",
        "? foo\n: bar\n",
    };

    for (cases) |input| {
        var token_stream = try scanner.scan(std.testing.allocator, input);
        defer token_stream.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var events: EventBuilder = .{};
        try events.append(allocator, .stream_start);
        try std.testing.expect(!try appendBlockMappingDocumentEvents(allocator, token_stream.tokens, &events));
        try std.testing.expectEqual(@as(usize, 1), events.slice().len);
    }
}

test "simple block sequence fast path emits scalar and compact mapping events" {
    var token_stream = try scanner.scan(std.testing.allocator, "- one\n" ++
        "- id: 1\n" ++
        "  name: record-1\n" ++
        "- two\n");
    defer token_stream.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var events: EventBuilder = .{};
    try events.append(allocator, .stream_start);
    try std.testing.expect(try appendBlockSequenceDocumentEvents(allocator, token_stream.tokens, &events));
    try events.append(allocator, .stream_end);

    try std.testing.expectEqual(@as(usize, 14), events.slice().len);
    try std.testing.expect(events.slice()[1] == .document_start);
    try std.testing.expect(events.slice()[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, events.slice()[2].sequence_start.style);
    try std.testing.expectEqualStrings("one", events.slice()[3].scalar.value);
    try std.testing.expect(events.slice()[4] == .mapping_start);
    try std.testing.expectEqualStrings("id", events.slice()[5].scalar.value);
    try std.testing.expectEqualStrings("1", events.slice()[6].scalar.value);
    try std.testing.expectEqualStrings("name", events.slice()[7].scalar.value);
    try std.testing.expectEqualStrings("record-1", events.slice()[8].scalar.value);
    try std.testing.expect(events.slice()[9] == .mapping_end);
    try std.testing.expectEqualStrings("two", events.slice()[10].scalar.value);
    try std.testing.expect(events.slice()[11] == .sequence_end);
    try std.testing.expect(events.slice()[12] == .document_end);
}

test "simple block sequence fast path declines unsupported shapes before emitting" {
    const cases = [_][]const u8{
        "- one two\n",
        "- &anchor one\n",
        "- 'one'\n",
        "- [one]\n",
        "-\n  - nested\n",
        "- id: 1 # comment\n",
        "- id: 1\n  name: record one\n",
    };

    for (cases) |input| {
        var token_stream = try scanner.scan(std.testing.allocator, input);
        defer token_stream.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var events: EventBuilder = .{};
        try events.append(allocator, .stream_start);
        try std.testing.expect(!try appendBlockSequenceDocumentEvents(allocator, token_stream.tokens, &events));
        try std.testing.expectEqual(@as(usize, 1), events.slice().len);
    }
}
