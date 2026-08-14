//! Purpose: Stress anchor, alias, and alias-expansion behavior.
//! Owns: Many-alias success cases and configured alias safety limits.
//! Does not own: General count limits or deep nesting limits.
//! Depends on: yaml public API and std.testing.
//! Tested by: zig build test-stress.

const std = @import("std");
const yaml = @import("yaml");
const support = @import("support.zig");

const allocator = support.allocator;

test "stress load resolves many anchors and aliases" {
    const pair_count = 256;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..pair_count) |index| {
        try input.print(allocator, "- &a{d} value-{d}\n", .{ index, index });
        try input.print(allocator, "- *a{d}\n", .{index});
    }

    var document = try yaml.load(allocator, input.items);
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(pair_count * 2, document.root.sequence.items.len);

    for (0..pair_count) |index| {
        const anchored = document.root.sequence.items[index * 2];
        const alias = document.root.sequence.items[index * 2 + 1];
        try std.testing.expectEqual(anchored, alias);
    }
}

test "stress loadStreamWithOptions rejects aliases beyond configured count limit" {
    const input =
        \\- &base value
        \\- *base
        \\- *base
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{
        .max_alias_count = 2,
    });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_alias_count = 1,
    }));
}

test "stress loadStreamWithOptions rejects alias expansion beyond configured limit" {
    const input =
        \\- &base
        \\  - one
        \\  - two
        \\- *base
        \\- *base
        \\
    ;

    var accepted = try yaml.loadStreamWithOptions(allocator, input, .{
        .max_alias_expansion = 6,
    });
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_alias_expansion = 5,
    }));
}

test "stress loadStreamWithOptions rejects recursive aliases with finite expansion limit" {
    const input =
        \\&root
        \\self: *root
        \\
    ;

    var accepted = try yaml.loadStream(allocator, input);
    defer accepted.deinit();

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.loadStreamWithOptions(allocator, input, .{
        .max_alias_expansion = 1024,
    }));
}
