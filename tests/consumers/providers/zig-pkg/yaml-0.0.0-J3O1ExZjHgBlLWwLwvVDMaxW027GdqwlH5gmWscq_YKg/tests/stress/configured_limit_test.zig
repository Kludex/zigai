//! Purpose: Stress configured public parser, loader, emitter, and dumper limits.
//! Owns: Input, output, token, event, nesting, scalar, and document-count limits.
//! Does not own: Alias-specific limits or allocation-failure injection.
//! Depends on: yaml public API and std.testing.
//! Tested by: zig build test-stress.

const std = @import("std");
const yaml = @import("yaml");
const support = @import("support.zig");

const allocator = support.allocator;

test "stress emitEventsWithOptions rejects output beyond configured byte limit" {
    const events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "leaf" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const accepted = try yaml.emitEventsWithOptions(allocator, &events, .{ .max_output_bytes = 5 });
    defer allocator.free(accepted);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.emitEventsWithOptions(allocator, &events, .{
        .max_output_bytes = 4,
    }));
}

test "stress dumpWithOptions rejects output beyond configured byte limit" {
    const root: yaml.Node = .{ .scalar = .{ .value = "leaf" } };

    const accepted = try yaml.dumpWithOptions(allocator, &root, .{ .max_output_bytes = 5 });
    defer allocator.free(accepted);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.dumpWithOptions(allocator, &root, .{
        .max_output_bytes = 4,
    }));
}

test "stress loadStreamWithOptions rejects documents beyond configured count limit" {
    const input =
        \\--- one
        \\--- two
        \\--- three
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{ .max_document_count = 3 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_document_count = 2,
    }));
}

test "stress parseEventsWithOptions rejects input beyond configured byte limit" {
    var diagnostic: yaml.Diagnostic = .{};

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEventsWithOptions(allocator, "abcd", .{
        .max_input_bytes = 3,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("input exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.column);
}

test "stress loadStreamWithOptions rejects input beyond configured byte limit" {
    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, "abcd", .{
        .max_input_bytes = 3,
    }));
}

test "stress parseEventsWithOptions rejects events beyond configured count limit" {
    const input =
        \\- one
        \\- two
        \\
    ;
    var diagnostic: yaml.Diagnostic = .{};

    var accepted = try yaml.parseEventsWithOptions(allocator, input, .{ .max_event_count = 8 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEventsWithOptions(allocator, input, .{
        .max_event_count = 7,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "stress parseEventsWithOptions rejects tokens beyond configured count limit" {
    const input =
        \\- one
        \\- two
        \\
    ;
    var diagnostic: yaml.Diagnostic = .{};

    var accepted = try yaml.parseEventsWithOptions(allocator, input, .{ .max_token_count = 64 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEventsWithOptions(allocator, input, .{
        .max_token_count = 1,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "stress loadStreamWithOptions rejects events beyond configured count limit" {
    const input =
        \\- one
        \\- two
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{ .max_event_count = 8 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_event_count = 7,
    }));
}

test "stress loadStreamWithOptions rejects tokens beyond configured count limit" {
    const input =
        \\- one
        \\- two
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{ .max_token_count = 64 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_token_count = 1,
    }));
}

test "stress parseEventsWithOptions rejects nesting beyond configured depth limit" {
    const input =
        \\-
        \\  - leaf
        \\
    ;
    var diagnostic: yaml.Diagnostic = .{};

    var accepted = try yaml.parseEventsWithOptions(allocator, input, .{ .max_nesting_depth = 2 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEventsWithOptions(allocator, input, .{
        .max_nesting_depth = 1,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "stress loadStreamWithOptions rejects nesting beyond configured depth limit" {
    const input =
        \\-
        \\  - leaf
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{ .max_nesting_depth = 2 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_nesting_depth = 1,
    }));
}

test "stress parseEventsWithOptions rejects scalars beyond configured byte limit" {
    var diagnostic: yaml.Diagnostic = .{};

    var accepted = try yaml.parseEventsWithOptions(allocator, "abcd\n", .{ .max_scalar_bytes = 4 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.parseEventsWithOptions(allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "stress loadStreamWithOptions rejects scalars beyond configured byte limit" {
    var accepted = try yaml.loadStreamWithOptions(allocator, "abcd\n", .{ .max_scalar_bytes = 4 });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
    }));
}
