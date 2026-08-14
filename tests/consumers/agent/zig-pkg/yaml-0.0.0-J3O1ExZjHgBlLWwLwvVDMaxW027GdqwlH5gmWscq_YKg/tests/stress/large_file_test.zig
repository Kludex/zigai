//! Purpose: Stress public loading APIs with large scalars, sequences, and repeated documents.
//! Owns: Large successful input cases for the public value model.
//! Does not own: Limit rejection, alias expansion, or allocation-failure tests.
//! Depends on: tests/stress/support.zig and yaml public API.
//! Tested by: zig build test-stress.

const std = @import("std");
const yaml = @import("yaml");
const support = @import("support.zig");

const allocator = support.allocator;

test "stress load preserves a large plain scalar" {
    const scalar_len = 64 * 1024;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..scalar_len) |_| {
        try input.append(allocator, 'a');
    }
    try input.append(allocator, '\n');

    var document = try yaml.load(allocator, input.items);
    defer document.deinit();

    try std.testing.expect(document.root.* == .scalar);
    try std.testing.expectEqual(scalar_len, document.root.scalar.value.len);
    for (document.root.scalar.value) |byte| {
        try std.testing.expectEqual(@as(u8, 'a'), byte);
    }
}

test "stress load handles a large block sequence" {
    const item_count = 2048;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..item_count) |index| {
        try input.print(allocator, "- item-{d}\n", .{index});
    }

    var document = try yaml.load(allocator, input.items);
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(item_count, document.root.sequence.items.len);
    try support.expectScalar(document.root.sequence.items[0], "item-0");
    try support.expectScalar(document.root.sequence.items[item_count - 1], "item-2047");
}

test "stress loadStream handles many repeated documents" {
    const document_count = 128;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    for (0..document_count) |index| {
        try input.print(allocator, "--- document-{d}\n", .{index});
    }

    var stream = try yaml.loadStream(allocator, input.items);
    defer stream.deinit();

    try std.testing.expectEqual(document_count, stream.documents.len);
    try support.expectScalar(stream.documents[0], "document-0");
    try support.expectScalar(stream.documents[document_count - 1], "document-127");
}
