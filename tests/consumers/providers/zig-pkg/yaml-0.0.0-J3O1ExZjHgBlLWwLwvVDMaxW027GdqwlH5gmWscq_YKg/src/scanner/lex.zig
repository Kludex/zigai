//! Purpose: Shared scanner lexical predicates, printable validation, and escape scanning.
//! Owns: Byte-level YAML presentation helpers used by scanner internals.
//! Does not own: Token emission or parser grammar.
//! Depends on: std, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and parser/event conformance tests.

const std = @import("std");
const token = @import("token.zig");

const Error = token.Error;

pub const utf8_bom = "\xEF\xBB\xBF";

pub const Line = struct {
    end: usize,
    next: usize,
};

pub fn lineAt(input: []const u8, start: usize) Line {
    var end = start;
    while (end < input.len and !isLineBreakByte(input[end])) : (end += 1) {}
    return .{
        .end = end,
        .next = if (end < input.len) consumeLineBreak(input, end) else end,
    };
}

pub fn lineStartAt(input: []const u8, index: usize) usize {
    var cursor = index;
    while (cursor > 0 and !isLineBreakByte(input[cursor - 1])) : (cursor -= 1) {}
    return cursor;
}

pub fn findBlockScalarContentEnd(
    input: []const u8,
    start: usize,
    parent_indent: usize,
    indent_indicator: ?usize,
    allow_zero_indent: bool,
) usize {
    var cursor = start;
    var end = start;
    var inferred_indent: ?usize = null;

    while (cursor < input.len) {
        const current_line = lineAt(input, cursor);
        const line = input[cursor..current_line.end];
        if (isBlankLine(line)) {
            end = current_line.next;
            cursor = current_line.next;
            continue;
        }

        const line_indent = countIndentPrefixSpaces(line);
        if (line_indent == 0 and (startsDocumentMarker(line, "---") or startsDocumentMarker(line, "..."))) {
            break;
        }

        const required_indent = if (indent_indicator) |indicator|
            parent_indent + indicator
        else
            inferred_indent orelse blk: {
                if (line_indent <= parent_indent) {
                    if (!(allow_zero_indent and parent_indent == 0)) return end;
                    inferred_indent = 0;
                    break :blk 0;
                }
                inferred_indent = line_indent;
                break :blk line_indent;
            };

        if (line_indent < required_indent) break;
        end = current_line.next;
        cursor = current_line.next;
    }

    return end;
}

pub fn consumeLineBreak(input: []const u8, start: usize) usize {
    if (input[start] == '\r' and start + 1 < input.len and input[start + 1] == '\n') return start + 2;
    return start + 1;
}

pub fn isLineBreakByte(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

pub fn isCommentStart(input: []const u8, index: usize) bool {
    return index == 0 or input[index - 1] == ' ' or input[index - 1] == '\t' or isLineBreakByte(input[index - 1]);
}

pub fn stripLineComment(input: []const u8) []const u8 {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (input[index] == '#' and index > 0 and isCommentStart(input, index)) return input[0..index];
    }
    return input;
}

pub fn startsDocumentMarker(input: []const u8, marker: []const u8) bool {
    if (!std.mem.startsWith(u8, input, marker)) return false;
    return input.len == marker.len or input[marker.len] == ' ' or input[marker.len] == '\t' or isLineBreakByte(input[marker.len]);
}

pub fn startsBlockIndentedStructure(input: []const u8, cursor: usize) bool {
    if (cursor >= input.len) return false;

    if (input[cursor] == '-' and isSeparatedIndicatorAt(input, cursor, 1)) return true;
    if (input[cursor] == '?' and isSeparatedIndicatorAt(input, cursor, 1)) return true;
    if (input[cursor] == '[' or input[cursor] == '{') return false;

    const line = lineAt(input, cursor);
    var index = cursor;
    while (index < line.end) : (index += 1) {
        if (input[index] == ':' and isMappingSeparatorAt(input, index, false)) return true;
    }
    return false;
}

pub fn countIndentSpaces(input: []const u8) usize {
    var count: usize = 0;
    for (input) |byte| {
        if (byte == ' ') count += 1;
    }
    return count;
}

pub fn countIndentPrefixSpaces(input: []const u8) usize {
    var count: usize = 0;
    while (count < input.len and input[count] == ' ') : (count += 1) {}
    return count;
}

pub fn isBlankLine(input: []const u8) bool {
    for (input) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r') return false;
    }
    return true;
}

pub fn isSeparatedIndicatorAt(input: []const u8, index: usize, width: usize) bool {
    const next = index + width;
    return next >= input.len or input[next] == ' ' or input[next] == '\t' or isLineBreakByte(input[next]);
}

pub fn isFlowIndicator(byte: u8) bool {
    return switch (byte) {
        '[', ']', '{', '}', ',' => true,
        else => false,
    };
}

pub fn isFlowStartIndicator(byte: u8) bool {
    return byte == '[' or byte == '{';
}

pub fn isReservedIndicator(byte: u8) bool {
    return byte == '@' or byte == '`';
}

pub fn reservedIndicatorStartsPlainScalar(input: []const u8, index: usize) bool {
    const previous = previousNonWhitespaceIndex(input, index) orelse return true;
    return switch (input[previous]) {
        ':', '[', '{', ',' => true,
        '-', '?' => isSeparatedIndicatorAt(input, previous, 1),
        else => false,
    };
}

pub fn isMappingSeparatorAt(input: []const u8, index: usize, in_flow: bool) bool {
    if (index + 1 >= input.len) return true;
    const next = input[index + 1];
    if (next == ' ' or next == '\t' or isLineBreakByte(next)) return true;
    return in_flow and isFlowIndicator(next);
}

pub fn previousNonWhitespaceByte(input: []const u8, index: usize) ?u8 {
    const previous = previousNonWhitespaceIndex(input, index) orelse return null;
    return input[previous];
}

pub fn previousNonWhitespaceIndex(input: []const u8, index: usize) ?usize {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (input[cursor]) {
            ' ', '\t', '\n', '\r' => {},
            else => return cursor,
        }
    }
    return null;
}

pub fn hexDigitValue(byte: u8) ?u21 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn isValidEscapedCodepoint(codepoint: u21) bool {
    return codepoint <= 0x10ffff and (codepoint < 0xd800 or codepoint > 0xdfff);
}

pub fn validate(input: []const u8) Error!void {
    var index: usize = 0;
    while (index < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[index]) catch return error.InvalidSyntax;
        if (index + len > input.len) return error.InvalidSyntax;
        const codepoint = std.unicode.utf8Decode(input[index .. index + len]) catch return error.InvalidSyntax;
        if (!isYamlPrintableCodepoint(codepoint)) return error.InvalidSyntax;
        index += len;
    }
}

fn isYamlPrintableCodepoint(codepoint: u21) bool {
    return codepoint == 0x09 or
        codepoint == 0x0a or
        codepoint == 0x0d or
        (codepoint >= 0x20 and codepoint <= 0x7e) or
        codepoint == 0x85 or
        (codepoint >= 0xa0 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

pub fn consumeDoubleQuoted(input: []const u8, index: *usize) Error!void {
    if (index.* >= input.len) return error.InvalidSyntax;

    if (isLineBreakByte(input[index.*])) {
        index.* = consumeLineBreak(input, index.*);
        return;
    }

    switch (input[index.*]) {
        '0', 'a', 'b', 't', '\t', 'n', 'v', 'f', 'r', 'e', ' ', '"', '/', '\\', 'N', '_', 'L', 'P' => {
            index.* += 1;
        },
        'x' => try consumeHex(input, index, 2),
        'u' => try consumeHex(input, index, 4),
        'U' => try consumeHex(input, index, 8),
        else => return error.InvalidSyntax,
    }
}

fn consumeHex(input: []const u8, index: *usize, digit_count: usize) Error!void {
    const digits_start = index.* + 1;
    const digits_end = digits_start + digit_count;
    if (digits_end > input.len) return error.InvalidSyntax;

    var codepoint: u21 = 0;
    for (input[digits_start..digits_end]) |byte| {
        const value = hexDigitValue(byte) orelse return error.InvalidSyntax;
        if (codepoint > (0x10ffff - value) / 16) return error.InvalidSyntax;
        codepoint = codepoint * 16 + value;
    }
    if (!isValidEscapedCodepoint(codepoint)) return error.InvalidSyntax;

    index.* = digits_end;
}

test "scanner lex: top-level block scalar content can infer zero indentation" {
    const input = "%!PS-Adobe-2.0\ncontinued\n...\n";

    try std.testing.expectEqual(
        @as(usize, "%!PS-Adobe-2.0\ncontinued\n".len),
        findBlockScalarContentEnd(input, 0, 0, null, true),
    );
}

test "scanner: printable code point boundaries match YAML 1.2.2" {
    const accepted = [_]u21{ 0x09, 0x0a, 0x0d, 0x20, 0x7e, 0x85, 0xa0, 0xd7ff, 0xe000, 0xfffd, 0x10000, 0x10ffff };
    const rejected = [_]u21{ 0x00, 0x08, 0x0b, 0x0c, 0x0e, 0x1f, 0x7f, 0x84, 0x86, 0x9f, 0xd800, 0xdfff, 0xfffe };

    for (accepted) |codepoint| {
        try std.testing.expect(isYamlPrintableCodepoint(codepoint));
    }
    for (rejected) |codepoint| {
        try std.testing.expect(!isYamlPrintableCodepoint(codepoint));
    }
}

test "scanner: printable validation rejects malformed UTF-8" {
    try std.testing.expectError(error.InvalidSyntax, validate("\xc3"));
    try std.testing.expectError(error.InvalidSyntax, validate("\xf0\x9f"));
    try std.testing.expectError(error.InvalidSyntax, validate("\xed\xa0\x80"));
}

test "scanner: printable validation accepts YAML line break code points" {
    try validate("line\nnext");
    try validate("line\rnext");
    try validate("line\xc2\x85next");
    try validate("line\xe2\x80\xa8next");
    try validate("line\xe2\x80\xa9next");
}

test "scanner escape: accepts YAML named double quoted escapes" {
    const accepted = [_][]const u8{ "0", "a", "b", "t", "\t", "n", "v", "f", "r", "e", " ", "\"", "/", "\\", "N", "_", "L", "P" };
    for (accepted) |input| {
        var index: usize = 0;
        try consumeDoubleQuoted(input, &index);
        try std.testing.expectEqual(input.len, index);
    }
}

test "scanner escape: accepts escaped line breaks and valid hex code points" {
    var lf_index: usize = 0;
    try consumeDoubleQuoted("\nnext", &lf_index);
    try std.testing.expectEqual(@as(usize, 1), lf_index);

    var crlf_index: usize = 0;
    try consumeDoubleQuoted("\r\nnext", &crlf_index);
    try std.testing.expectEqual(@as(usize, 2), crlf_index);

    inline for (.{ "x20", "u2028", "U0010FFFF" }) |input| {
        var index: usize = 0;
        try consumeDoubleQuoted(input, &index);
        try std.testing.expectEqual(input.len, index);
    }
}

test "scanner escape: rejects malformed hex and invalid escaped code points" {
    const rejected = [_][]const u8{ "", "q", "x0", "xzz", "u12", "uD800", "uDFFF", "U00110000", "UFFFFFFFF" };
    for (rejected) |input| {
        var index: usize = 0;
        try std.testing.expectError(error.InvalidSyntax, consumeDoubleQuoted(input, &index));
    }
}
