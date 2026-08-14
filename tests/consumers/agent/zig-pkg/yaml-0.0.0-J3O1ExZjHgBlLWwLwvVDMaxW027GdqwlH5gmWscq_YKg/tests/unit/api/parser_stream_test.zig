//! Purpose: Verify the public streaming parser facade.
//! Owns: Parser init/next/deinit API behavior.
//! Does not own: Scanner or event parser internals.
//! Depends on: public yaml module.
//! Tested by: zig build test-unit.

const std = @import("std");
const yaml = @import("yaml");

test "api parser: next yields events in order then null" {
    var parser = try yaml.Parser.init(std.testing.allocator, "key: value\n", .{});
    defer parser.deinit();

    try std.testing.expectEqual(yaml.Event.stream_start, (try parser.next()).?);
    try std.testing.expectEqualDeep(yaml.Event{ .document_start = .{} }, (try parser.next()).?);
    try std.testing.expectEqualDeep(yaml.Event{ .mapping_start = .{ .style = .block } }, (try parser.next()).?);
    try std.testing.expectEqualDeep(yaml.Event{ .scalar = .{ .value = "key" } }, (try parser.next()).?);
    try std.testing.expectEqualDeep(yaml.Event{ .scalar = .{ .value = "value" } }, (try parser.next()).?);
    try std.testing.expectEqual(yaml.Event.mapping_end, (try parser.next()).?);
    try std.testing.expectEqualDeep(yaml.Event{ .document_end = .{} }, (try parser.next()).?);
    try std.testing.expectEqual(yaml.Event.stream_end, (try parser.next()).?);
    try std.testing.expectEqual(@as(?yaml.Event, null), try parser.next());
}

test "api parser: init applies parse options and diagnostics" {
    var diagnostic: yaml.Diagnostic = .{};

    try std.testing.expectError(
        error.Unsupported,
        yaml.Parser.init(std.testing.allocator, "key: value\n", .{
            .max_input_bytes = 3,
            .diagnostic = &diagnostic,
        }),
    );

    try std.testing.expectEqualStrings("input exceeds configured size limit", diagnostic.message);
}

test "api parser: init clears stale diagnostic on success" {
    var diagnostic: yaml.Diagnostic = .{ .message = "stale", .offset = 9, .line = 2, .column = 3 };

    var parser = try yaml.Parser.init(std.testing.allocator, "value\n", .{
        .diagnostic = &diagnostic,
    });
    defer parser.deinit();

    try std.testing.expectEqualStrings("", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
    try std.testing.expectEqual(yaml.Event.stream_start, (try parser.next()).?);
}

test "api parser: init accepts exact safety limit boundaries" {
    const input =
        \\- one
        \\- two
        \\
    ;

    var tokens = try yaml.scanner.scan(std.testing.allocator, input);
    defer tokens.deinit();

    var baseline = try yaml.parseEvents(std.testing.allocator, input);
    defer baseline.deinit();

    var parser = try yaml.Parser.init(std.testing.allocator, input, .{
        .max_input_bytes = input.len,
        .max_token_count = tokens.tokens.len,
        .max_event_count = baseline.events.len,
        .max_scalar_bytes = 3,
        .max_nesting_depth = 1,
    });
    defer parser.deinit();

    var count: usize = 0;
    while (try parser.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(baseline.events.len, count);
}
