//! Purpose: Scan YAML scalar token payloads.
//! Owns: Plain scalar token bounds and quoted scalar delimiter validation.
//! Does not own: Block scalar header/content scanning or scalar resolution.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const Error = token.Error;

pub fn readPlainScalar(input: []const u8, index: *usize, flow_depth: usize) Error![]const u8 {
    const start = index.*;
    if (lex.isReservedIndicator(input[start]) and lex.reservedIndicatorStartsPlainScalar(input, start)) {
        return error.InvalidSyntax;
    }
    if (std.mem.startsWith(u8, input[start..], lex.utf8_bom)) return error.InvalidSyntax;

    while (index.* < input.len) {
        if (std.mem.startsWith(u8, input[index.*..], lex.utf8_bom)) return error.InvalidSyntax;
        const byte = input[index.*];
        if (lex.isLineBreakByte(byte) or byte == ' ' or byte == '\t') break;
        if (byte == '#' and lex.isCommentStart(input, index.*)) break;
        if (flow_depth != 0 and lex.isFlowIndicator(byte)) break;
        if (byte == ':' and lex.isMappingSeparatorAt(input, index.*, flow_depth != 0)) break;
        index.* += 1;
    }

    if (index.* == start) return error.InvalidSyntax;
    return input[start..index.*];
}

pub fn readQuotedScalar(input: []const u8, index: *usize, quote: u8) Error![]const u8 {
    const start = index.*;
    index.* += 1;
    while (index.* < input.len) {
        const byte = input[index.*];
        if (quote == '\'' and byte == '\'' and index.* + 1 < input.len and input[index.* + 1] == '\'') {
            index.* += 2;
            continue;
        }
        if (quote == '"' and byte == '\\') {
            index.* += 1;
            try lex.consumeDoubleQuoted(input, index);
            continue;
        }
        index.* += 1;
        if (byte == quote) return input[start..index.*];
    }

    return error.InvalidSyntax;
}
