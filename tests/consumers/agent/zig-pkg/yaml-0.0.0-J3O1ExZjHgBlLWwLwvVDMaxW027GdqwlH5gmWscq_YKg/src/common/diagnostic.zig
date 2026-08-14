//! Purpose: Define public diagnostics and common YAML error sets.
//! Owns: Parse/load/emit error names, source diagnostic payloads, and byte-offset diagnostic construction.
//! Does not own: Parser recovery or layer-specific diagnostic message selection.
//! Depends on: common/location.zig and std.
//! Tested by: tests/unit/api/root_api_test.zig and stress tests.

const std = @import("std");
const location = @import("location.zig");

/// Syntax and implementation-limit errors returned by the YAML library.
pub const ParseError = error{
    /// Input or event stream violates supported YAML syntax.
    InvalidSyntax,
    /// Input is valid YAML shape that exceeds a current implementation limit.
    Unsupported,
};

/// Error set returned by public APIs that can parse, load, emit, or allocate.
pub const Error = ParseError || std.mem.Allocator.Error;

/// Error set returned by public APIs that emit to a caller-provided writer.
pub const WriteError = Error || std.Io.Writer.Error;

/// Source location and short reason for a parse failure.
///
/// `offset` is a zero-based byte offset into the caller-provided input.
/// `line` and `column` are one-based byte positions. `message` is a static
/// string owned by the library.
pub const Diagnostic = struct {
    message: []const u8 = "",
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
};

/// Builds a diagnostic at `offset` with one-based byte line and column fields.
///
/// `offset` is preserved in the returned diagnostic and clamped only for
/// line/column calculation.
pub fn atOffset(input: []const u8, offset: usize, message: []const u8) Diagnostic {
    const source_location = location.atOffset(input, offset);

    return .{
        .message = message,
        .offset = offset,
        .line = source_location.line,
        .column = source_location.column,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "diagnostic: preserves requested offset while clamping location lookup" {
    const cases = [_]struct { input: []const u8, offset: usize, line: usize, column: usize }{
        .{ .input = "first\r\nsecond", .offset = 8, .line = 2, .column = 2 },
        .{ .input = "", .offset = 99, .line = 1, .column = 1 },
        .{ .input = "key: value\n", .offset = 11, .line = 2, .column = 1 },
        .{ .input = "key: value\n", .offset = 4096, .line = 2, .column = 1 },
    };
    for (cases) |case| {
        const diagnostic = atOffset(case.input, case.offset, "boundary");
        try std.testing.expectEqualStrings("boundary", diagnostic.message);
        try std.testing.expectEqual(case.offset, diagnostic.offset);
        try std.testing.expectEqual(case.line, diagnostic.line);
        try std.testing.expectEqual(case.column, diagnostic.column);
    }
}

test "diagnostic: computes locations across YAML non-ASCII line breaks" {
    const input = "alpha\xc2\x85beta\xe2\x80\xa8gamma\xe2\x80\xa9delta";
    for ([_]usize{ 7, 14, 22 }, 2..) |offset, line| {
        const diagnostic = atOffset(input, offset, "break");
        try std.testing.expectEqual(line, diagnostic.line);
        try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
    }
}
