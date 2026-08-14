//! Purpose: Scan YAML node property spellings.
//! Owns: Anchor, alias, and tag token payload bounds.
//! Does not own: Token emission, schema tag resolution, or parser node properties.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const Error = token.Error;

pub fn readName(input: []const u8, index: *usize, prefix_len: usize) Error![]const u8 {
    const start = index.* + prefix_len;
    var cursor = start;
    while (cursor < input.len) : (cursor += 1) {
        if (std.mem.startsWith(u8, input[cursor..], lex.utf8_bom)) return error.InvalidSyntax;
        const byte = input[cursor];
        if (lex.isFlowStartIndicator(byte)) return error.InvalidSyntax;
        if (byte == ' ' or byte == '\t' or lex.isLineBreakByte(byte) or lex.isFlowIndicator(byte)) break;
        if (byte == '#' and lex.isCommentStart(input, cursor)) break;
    }

    if (cursor == start) return error.InvalidSyntax;
    index.* = cursor;
    return input[start..cursor];
}

pub fn readTag(input: []const u8, index: *usize) Error![]const u8 {
    if (std.mem.startsWith(u8, input[index.*..], "!<")) {
        var cursor = index.* + 2;
        while (cursor < input.len and input[cursor] != '>') : (cursor += 1) {
            if (std.mem.startsWith(u8, input[cursor..], lex.utf8_bom)) return error.InvalidSyntax;
            if (lex.isLineBreakByte(input[cursor])) return error.InvalidSyntax;
        }
        if (cursor >= input.len) return error.InvalidSyntax;
        const tag = input[index.* .. cursor + 1];
        index.* = cursor + 1;
        return tag;
    }

    const start = index.*;
    if (lex.isSeparatedIndicatorAt(input, start, 1) or
        (start + 1 < input.len and lex.isFlowIndicator(input[start + 1])))
    {
        index.* += 1;
        return input[start..index.*];
    }

    _ = try readName(input, index, 1);
    return input[start..index.*];
}
