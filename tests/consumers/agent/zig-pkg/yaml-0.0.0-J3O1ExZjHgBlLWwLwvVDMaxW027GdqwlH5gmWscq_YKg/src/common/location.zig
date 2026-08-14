//! Purpose: Convert byte offsets into source locations.
//! Owns: Line and column tracking for normalized or raw YAML source slices.
//! Does not own: Diagnostic messages, parser recovery, or scanner token locations.
//! Depends on: std only.
//! Tested by: in-file tests and parser diagnostic tests.

const std = @import("std");

/// One-based source location for a byte offset.
pub const SourceLocation = struct {
    line: usize,
    column: usize,
};

/// Returns the one-based line and column at `offset`.
///
/// `offset` is clamped to `input.len`. Columns count bytes, matching the
/// current parser diagnostic contract.
pub fn atOffset(input: []const u8, offset: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    var index: usize = 0;
    const end = @min(offset, input.len);

    while (index < end) {
        if (lineBreakLen(input, index, end)) |len| {
            index += len;
            line += 1;
            column = 1;
        } else {
            index += 1;
            column += 1;
        }
    }

    return .{
        .line = line,
        .column = column,
    };
}

fn lineBreakLen(input: []const u8, index: usize, end: usize) ?usize {
    return switch (input[index]) {
        '\n' => 1,
        '\r' => if (index + 1 < end and input[index + 1] == '\n') 2 else 1,
        0xC2 => if (index + 1 < end and input[index + 1] == 0x85) 2 else null,
        0xE2 => if (index + 2 < end and input[index + 1] == 0x80 and (input[index + 2] == 0xA8 or input[index + 2] == 0xA9)) 3 else null,
        else => null,
    };
}

test atOffset {
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 1 }, atOffset("abc", 0));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 3 }, atOffset("abc", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\nbc", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\rbc", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\r\nbc", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xC2\x85bc", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xE2\x80\xA8bc", 4));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xE2\x80\xA9bc", 4));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 4 }, atOffset("a\xC2\xA0b", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 5 }, atOffset("a\xE2\x82\xACb", 4));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 3 }, atOffset("a\nbc", 99));
}

test "location: offsets inside YAML line break encodings" {
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\r\nb", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\r\nb", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 2 }, atOffset("a\r\nb", 4));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 3 }, atOffset("a\xC2\x85b", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xC2\x85b", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 3 }, atOffset("a\xE2\x80\xA8b", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 4 }, atOffset("a\xE2\x80\xA8b", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xE2\x80\xA8b", 4));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 3 }, atOffset("a\xE2\x80\xA9b", 2));
    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 4 }, atOffset("a\xE2\x80\xA9b", 3));
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 1 }, atOffset("a\xE2\x80\xA9b", 4));
}
