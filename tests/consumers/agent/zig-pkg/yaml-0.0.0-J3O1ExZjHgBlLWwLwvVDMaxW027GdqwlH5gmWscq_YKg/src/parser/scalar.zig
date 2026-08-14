//! Purpose: Parse YAML scalar token payloads and scalar-document token streams.
//! Owns: Plain, quoted, block, and document-level scalar parsing.
//! Does not own: Collection parsing, scanning, schema resolution, loading, or emitting.
//! Depends on: parser/internal.zig, scanner/scanner.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const internal = @import("internal.zig");
const source_slice = internal;
const token_cursor = internal;
const scanner = @import("../scanner/scanner.zig");
const types = @import("event.zig");

const Error = types.Error;
const ParseError = types.ParseError;
const TokenDirectives = internal.TokenDirectives;

pub const isPlainScalarToken = plain_scalar_rules.isToken;
pub const isPlainScalarContinuationToken = plain_scalar_rules.isContinuationToken;
pub const isQuotedScalarToken = plain_scalar_rules.isQuotedToken;
pub const scalarTokenHasInvalidPlainStart = plain_scalar_rules.hasInvalidPlainStart;
pub const isFlowIndicatorOrTag = plain_scalar_rules.isFlowIndicatorOrTag;
pub const scalarStartsAdjacentToPropertyIndicator = plain_scalar_rules.startsAdjacentToPropertyIndicator;
pub const isTabSeparatedCompactMappingStart = plain_scalar_rules.isTabSeparatedCompactMappingStart;
pub const scalarTokenSpansLines = plain_scalar_rules.spansLines;
pub const isBlockSequenceItemScalar = plain_scalar_rules.isBlockSequenceItemScalar;
pub const isBareBlockSequenceEntryScalar = plain_scalar_rules.isBareBlockSequenceEntryScalar;
pub const isPlainFlowScalarToken = plain_scalar_rules.isFlowToken;
pub const validateBlockFlowScalarToken = quoted_scalar.validateBlockFlowScalarToken;
pub const parseBlockScalarToken = block_scalar.parseBlockScalarToken;
pub const parseBlockScalarTokenAt = block_scalar.parseBlockScalarTokenAt;
pub const ScalarDocumentTokens = document_scalar.ScalarDocumentTokens;
pub const parseScalarTokens = document_scalar.parseScalarTokens;
pub const parseScalarTokenRange = document_scalar.parseScalarTokenRange;
pub const AliasDocumentTokens = document_scalar.AliasDocumentTokens;
pub const parseAliasTokens = document_scalar.parseAliasTokens;
pub const parseAliasTokenRange = document_scalar.parseAliasTokenRange;

pub fn parseScalarToken(allocator: std.mem.Allocator, value: []const u8) Error!types.Scalar {
    if (value.len == 0) return ParseError.Unsupported;

    if (value[0] == '\'') {
        try quoted_scalar.validateNoForbiddenDocumentMarkerLine(value);
        return .{
            .value = try quoted_scalar.parseSingleQuotedScalarToken(allocator, value),
            .style = .single_quoted,
        };
    }

    if (value[0] == '"') {
        try quoted_scalar.validateNoForbiddenDocumentMarkerLine(value);
        return .{
            .value = try quoted_scalar.parseDoubleQuotedScalarToken(allocator, value),
            .style = .double_quoted,
        };
    }

    if (!isPlainScalarToken(value)) return ParseError.Unsupported;

    return .{
        .value = try plain_scalar_value.parsePlainScalarValue(allocator, value),
        .style = .plain,
    };
}

pub fn parsePlainScalarTokenRun(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
) Error!?types.Scalar {
    if (index.* >= end or tokens[index.*] != .scalar) return null;
    const first = tokens[index.*].scalar;
    if (!isPlainScalarToken(first)) return null;

    var last = first;
    index.* += 1;
    while (index.* < end and tokens[index.*] == .scalar and isPlainScalarContinuationToken(tokens[index.*].scalar)) {
        last = tokens[index.*].scalar;
        index.* += 1;
    }

    const raw = source_slice.sourceRange(first, last) orelse return ParseError.Unsupported;
    return .{
        .value = try plain_scalar_value.parsePlainScalarValue(allocator, raw),
        .style = .plain,
    };
}

pub fn parsePlainBlockSequenceItemScalarTokenRun(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    sequence_indent: usize,
) Error!?types.Scalar {
    if (index.* >= end or tokens[index.*] != .scalar) return null;
    const first = tokens[index.*].scalar;
    if (!isPlainScalarToken(first)) return null;
    if (isFlowIndicatorOrTag(first[0])) return null;

    var last = first;
    var saw_comment = false;
    index.* += 1;
    while (index.* < end) {
        switch (tokens[index.*]) {
            .scalar => |value| {
                if (!isPlainScalarContinuationToken(value)) break;
                if (saw_comment) return ParseError.InvalidSyntax;
                last = value;
                index.* += 1;
            },
            .comment => {
                saw_comment = true;
                index.* += 1;
            },
            .indent => |indent| {
                if (indent <= sequence_indent) break;
                if (index.* + 1 >= end) break;
                switch (tokens[index.* + 1]) {
                    .scalar => |value| {
                        if (!isPlainScalarContinuationToken(value)) break;
                        if (saw_comment) return ParseError.InvalidSyntax;
                        index.* += 1;
                    },
                    .anchor, .alias, .tag => |value| {
                        if (saw_comment) return ParseError.InvalidSyntax;
                        last = value;
                        index.* += 2;
                    },
                    .block_sequence_entry => {
                        if (index.* + 2 >= end or tokens[index.* + 2] != .scalar or
                            !isPlainScalarContinuationToken(tokens[index.* + 2].scalar))
                        {
                            break;
                        }
                        if (saw_comment) return ParseError.InvalidSyntax;
                        index.* += 2;
                    },
                    else => break,
                }
            },
            else => break,
        }
    }

    const raw = source_slice.sourceRange(first, last) orelse return ParseError.Unsupported;
    return .{
        .value = try plain_scalar_value.parsePlainScalarValue(allocator, raw),
        .style = .plain,
    };
}

pub fn parsePlainScalarTokenRunWithIndentedContinuations(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
) Error!?types.Scalar {
    return parsePlainScalarTokenRunWithContinuationLines(allocator, tokens, index, end, parent_indent, false);
}

pub fn parsePlainFlowScalarTokenRunWithContinuations(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
) Error!?types.Scalar {
    return parsePlainScalarTokenRunWithContinuationLines(allocator, tokens, index, end, 0, true);
}

pub fn parsePlainScalarDocumentToken(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
) Error!types.Scalar {
    if (index.* >= end or tokens[index.*] != .scalar) return ParseError.Unsupported;
    const first = tokens[index.*].scalar;
    if (!plain_scalar_rules.isDocumentStartToken(first)) return ParseError.Unsupported;

    var last = first;
    index.* += 1;

    while (index.* < end) {
        switch (tokens[index.*]) {
            .scalar => |value| {
                if (!isPlainScalarContinuationToken(value)) break;
                last = value;
                index.* += 1;
            },
            .anchor, .alias, .tag => {
                last = plain_scalar_rules.documentContinuationPayload(tokens[index.*]) orelse break;
                index.* += 1;
            },
            .indent, .comment => index.* += 1,
            else => break,
        }
    }

    const raw = source_slice.sourceRange(first, last) orelse return ParseError.Unsupported;
    return .{
        .value = try plain_scalar_value.parsePlainScalarValue(allocator, raw),
        .style = .plain,
    };
}

fn parsePlainScalarTokenRunWithContinuationLines(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    allow_unindented_continuations: bool,
) Error!?types.Scalar {
    if (index.* >= end or tokens[index.*] != .scalar) return null;
    const first = tokens[index.*].scalar;
    if (!isPlainScalarToken(first)) return null;

    var last = first;
    var saw_comment = false;
    index.* += 1;
    while (index.* < end) {
        switch (tokens[index.*]) {
            .scalar => |value| {
                if (!isPlainScalarContinuationToken(value)) break;
                if (saw_comment) return ParseError.InvalidSyntax;
                last = value;
                index.* += 1;
            },
            .comment => {
                saw_comment = true;
                index.* += 1;
            },
            .indent => |indent| {
                if (!allow_unindented_continuations and indent <= parent_indent) break;
                if (index.* + 1 >= end) break;
                switch (tokens[index.* + 1]) {
                    .scalar => |value| {
                        if (!isPlainScalarContinuationToken(value)) break;
                        if (saw_comment) return ParseError.InvalidSyntax;
                        index.* += 1;
                    },
                    .anchor, .alias, .tag => |value| {
                        if (saw_comment) return ParseError.InvalidSyntax;
                        last = value;
                        index.* += 2;
                    },
                    .block_sequence_entry => {
                        if (index.* + 2 >= end or tokens[index.* + 2] != .scalar or
                            !isPlainScalarContinuationToken(tokens[index.* + 2].scalar))
                        {
                            break;
                        }
                        if (saw_comment) return ParseError.InvalidSyntax;
                        index.* += 2;
                    },
                    else => break,
                }
            },
            else => break,
        }
    }

    const raw = source_slice.sourceRange(first, last) orelse return ParseError.Unsupported;
    return .{
        .value = try plain_scalar_value.parsePlainScalarValue(allocator, raw),
        .style = .plain,
    };
}

test "parser scalar: parses single plain scalar token" {
    const parsed = try parseScalarToken(std.testing.allocator, "plain scalar");
    defer std.testing.allocator.free(parsed.value);

    try std.testing.expectEqual(types.ScalarStyle.plain, parsed.style);
    try std.testing.expectEqualStrings("plain scalar", parsed.value);
}

const plain_scalar_rules = struct {
    pub fn isToken(value: []const u8) bool {
        if (value.len == 0) return false;
        if (isQuotedToken(value)) return false;
        return hasValidStart(value);
    }

    pub fn isContinuationToken(value: []const u8) bool {
        return value.len != 0;
    }

    pub fn isQuotedToken(value: []const u8) bool {
        return value.len > 0 and (value[0] == '\'' or value[0] == '"');
    }

    pub fn hasInvalidPlainStart(value: []const u8) bool {
        return value.len != 0 and !isQuotedToken(value) and !hasValidStart(value);
    }

    pub fn isFlowIndicatorOrTag(byte: u8) bool {
        return switch (byte) {
            '[', ']', '{', '}', ',', '!' => true,
            else => false,
        };
    }

    pub fn startsAdjacentToPropertyIndicator(property_end: usize, scalar: []const u8) bool {
        return scalar.len != 0 and @intFromPtr(scalar.ptr) == property_end and @This().isFlowIndicatorOrTag(scalar[0]);
    }

    pub fn isTabSeparatedCompactMappingStart(tokens: []const scanner.Token, index: usize, end: usize) bool {
        if (index + 1 >= end or tokens[index] != .scalar or tokens[index + 1] != .block_mapping_value) return false;
        return startsAfterTab(tokens[index].scalar);
    }

    pub fn spansLines(value: []const u8) bool {
        return std.mem.indexOfAny(u8, value, "\n\r") != null;
    }

    pub fn isBlockSequenceItemScalar(value: []const u8) bool {
        return !std.mem.eql(u8, value, "-");
    }

    pub fn isBareBlockSequenceEntryScalar(value: []const u8) bool {
        return std.mem.eql(u8, value, "-");
    }

    pub fn isFlowToken(value: []const u8) bool {
        return isToken(value) and !std.mem.eql(u8, value, "-");
    }

    pub fn isDocumentStartToken(value: []const u8) bool {
        return isToken(value) or std.mem.startsWith(u8, value, "%");
    }

    pub fn documentContinuationPayload(token: scanner.Token) ?[]const u8 {
        return switch (token) {
            .scalar => |value| if (isContinuationToken(value)) value else null,
            .anchor => |value| value,
            .alias => |value| value,
            .tag => |value| value,
            else => null,
        };
    }

    test "parser plain scalar rules: document continuation payload accepts non-empty scalar tokens" {
        try std.testing.expectEqualStrings("continued", documentContinuationPayload(.{ .scalar = "continued" }).?);
        try std.testing.expect(documentContinuationPayload(.{ .scalar = "" }) == null);
    }

    fn hasValidStart(value: []const u8) bool {
        return switch (value[0]) {
            '#', '[', ']', '{', '}', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => false,
            '-', '?', ':' => value.len > 1 and !isSeparationByte(value[1]),
            else => true,
        };
    }

    fn isSeparationByte(byte: u8) bool {
        return byte == ' ' or byte == '\t' or source_slice.isLineBreakByte(byte);
    }

    fn startsAfterTab(scalar: []const u8) bool {
        if (scalar.len == 0) return false;
        const scalar_start = @intFromPtr(scalar.ptr);
        if (scalar_start == 0) return false;
        const previous: [*]const u8 = @ptrFromInt(scalar_start - 1);
        return previous[0] == '\t';
    }
};

const plain_scalar_value = struct {
    pub fn parsePlainScalarValue(allocator: std.mem.Allocator, input: []const u8) Error![]const u8 {
        if (!source_slice.containsLineBreak(input)) {
            if (!singleLinePlainScalarNeedsNormalization(input)) return allocator.dupe(u8, input);
            return allocator.dupe(u8, std.mem.trimEnd(u8, stripLineComment(input), " \t\r"));
        }

        if (hasContentAfterComment(input)) return ParseError.InvalidSyntax;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var wrote_line = false;
        var blank_lines: usize = 0;

        var index: usize = 0;
        while (index < input.len) {
            const raw_line = source_slice.lineAt(input, index);
            const line = std.mem.trim(u8, stripLineComment(input[raw_line.start..raw_line.end]), " \t\r");
            index = raw_line.next;

            if (line.len == 0) {
                if (wrote_line) blank_lines += 1;
                continue;
            }

            if (wrote_line) {
                if (blank_lines == 0) {
                    try out.append(allocator, ' ');
                } else {
                    while (blank_lines > 0) : (blank_lines -= 1) {
                        try out.append(allocator, '\n');
                    }
                }
            }

            try out.appendSlice(allocator, line);
            wrote_line = true;
        }

        return out.toOwnedSlice(allocator);
    }

    fn hasContentAfterComment(input: []const u8) bool {
        var saw_comment = false;

        var index: usize = 0;
        while (index < input.len) {
            const input_line = source_slice.lineAt(input, index);
            const line = input[input_line.start..input_line.end];
            index = input_line.next;

            const stripped = stripLineComment(line);
            const content = std.mem.trim(u8, stripped, " \t");

            if (saw_comment and content.len != 0) return true;
            if (stripped.len != line.len) saw_comment = true;
        }

        return false;
    }

    fn singleLinePlainScalarNeedsNormalization(input: []const u8) bool {
        if (input.len != std.mem.trimEnd(u8, input, " \t\r").len) return true;

        var index: usize = 0;
        while (index < input.len) : (index += 1) {
            if (input[index] == '#' and index > 0 and isCommentStart(input, index)) return true;
        }
        return false;
    }

    fn stripLineComment(input: []const u8) []const u8 {
        var index: usize = 0;
        while (index < input.len) : (index += 1) {
            if (input[index] == '#' and index > 0 and isCommentStart(input, index)) return input[0..index];
        }
        return input;
    }

    fn isCommentStart(input: []const u8, index: usize) bool {
        return index == 0 or input[index - 1] == ' ' or input[index - 1] == '\t' or source_slice.isLineBreakByte(input[index - 1]);
    }

    test "plain scalar value: cleans up after multiline normalization allocation failure" {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            checkMultilineNormalizationAllocationFailure,
            .{},
        );
    }

    fn checkMultilineNormalizationAllocationFailure(failing_allocator: std.mem.Allocator) !void {
        const value = try parsePlainScalarValue(failing_allocator,
            \\first
            \\
            \\second
        );
        defer failing_allocator.free(value);

        try std.testing.expectEqualStrings("first\nsecond", value);
    }
};

const quoted_scalar = struct {
    pub fn validateBlockFlowScalarToken(value: []const u8, required_indent: usize) ParseError!void {
        if (!@This().isQuotedScalarToken(value)) return;
        if (quotedScalarHasInvalidBlockContinuation(value, required_indent)) return ParseError.InvalidSyntax;
    }

    pub fn validateNoForbiddenDocumentMarkerLine(value: []const u8) ParseError!void {
        var index: usize = 0;
        while (index < value.len) {
            if (value[index] != '\n' and value[index] != '\r') {
                index += 1;
                continue;
            }

            index = source_slice.consumeLineBreak(value, index, value.len) orelse return ParseError.InvalidSyntax;
            if (startsForbiddenDocumentMarkerLine(value[index..])) return ParseError.InvalidSyntax;
        }
    }

    pub fn parseSingleQuotedScalarToken(allocator: std.mem.Allocator, value: []const u8) Error![]const u8 {
        if (value.len < 2 or value[value.len - 1] != '\'') return ParseError.InvalidSyntax;

        const content = value[1 .. value.len - 1];
        if (std.mem.indexOfAny(u8, content, "'\n\r") == null) return allocator.dupe(u8, content);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 1;
        while (index < value.len - 1) {
            const byte = value[index];
            if (byte == '\'') {
                if (index + 1 >= value.len - 1 or value[index + 1] != '\'') return ParseError.InvalidSyntax;
                try out.append(allocator, '\'');
                index += 2;
                continue;
            }
            if (byte == '\n' or byte == '\r') {
                index = try appendFlowFoldedLineBreak(allocator, &out, value, index, value.len - 1, null);
                continue;
            }

            try out.append(allocator, byte);
            index += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn parseDoubleQuotedScalarToken(allocator: std.mem.Allocator, value: []const u8) Error![]const u8 {
        if (value.len < 2 or value[value.len - 1] != '"') return ParseError.InvalidSyntax;

        const content = value[1 .. value.len - 1];
        if (std.mem.indexOfAny(u8, content, "\"\\\n\r") == null) return allocator.dupe(u8, content);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 1;
        var trailing_source_whitespace: usize = 0;
        while (index < value.len - 1) {
            const byte = value[index];
            if (byte == '"') return ParseError.InvalidSyntax;
            if (byte == '\n' or byte == '\r') {
                index = try appendFlowFoldedLineBreak(allocator, &out, value, index, value.len - 1, trailing_source_whitespace);
                trailing_source_whitespace = 0;
                continue;
            }

            if (byte != '\\') {
                try out.append(allocator, byte);
                trailing_source_whitespace = if (byte == ' ' or byte == '\t') trailing_source_whitespace + 1 else 0;
                index += 1;
                continue;
            }

            index += 1;
            if (index >= value.len - 1) return ParseError.InvalidSyntax;
            if (value[index] == '\n' or value[index] == '\r') {
                index = try consumeEscapedDoubleLineBreak(value, index, value.len - 1);
                trailing_source_whitespace = 0;
                continue;
            }

            const escaped = switch (value[index]) {
                '0' => 0x00,
                'a' => 0x07,
                'b' => 0x08,
                't', '\t' => 0x09,
                'n' => 0x0a,
                'v' => 0x0b,
                'f' => 0x0c,
                'r' => 0x0d,
                'e' => 0x1b,
                ' ', '"', '/', '\\' => value[index],
                'N' => {
                    try appendUtf8Codepoint(allocator, &out, 0x85);
                    trailing_source_whitespace = 0;
                    index += 1;
                    continue;
                },
                '_' => {
                    try appendUtf8Codepoint(allocator, &out, 0xa0);
                    trailing_source_whitespace = 0;
                    index += 1;
                    continue;
                },
                'L' => {
                    try appendUtf8Codepoint(allocator, &out, 0x2028);
                    trailing_source_whitespace = 0;
                    index += 1;
                    continue;
                },
                'P' => {
                    try appendUtf8Codepoint(allocator, &out, 0x2029);
                    trailing_source_whitespace = 0;
                    index += 1;
                    continue;
                },
                'x' => {
                    const codepoint = try parseHexEscape(value, index + 1, 2);
                    try appendUtf8Codepoint(allocator, &out, codepoint);
                    trailing_source_whitespace = 0;
                    index += 3;
                    continue;
                },
                'u' => {
                    const codepoint = try parseHexEscape(value, index + 1, 4);
                    try appendUtf8Codepoint(allocator, &out, codepoint);
                    trailing_source_whitespace = 0;
                    index += 5;
                    continue;
                },
                'U' => {
                    const codepoint = try parseHexEscape(value, index + 1, 8);
                    try appendUtf8Codepoint(allocator, &out, codepoint);
                    trailing_source_whitespace = 0;
                    index += 9;
                    continue;
                },
                else => return ParseError.InvalidSyntax,
            };
            try out.append(allocator, escaped);
            trailing_source_whitespace = 0;
            index += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    fn isQuotedScalarToken(value: []const u8) bool {
        return value.len > 0 and (value[0] == '\'' or value[0] == '"');
    }

    fn quotedScalarHasInvalidBlockContinuation(value: []const u8, required_indent: usize) bool {
        var index: usize = 0;
        while (index < value.len) {
            if (value[index] != '\n' and value[index] != '\r') {
                index += 1;
                continue;
            }

            index = source_slice.consumeLineBreak(value, index, value.len) orelse return true;
            const line = source_slice.lineAt(value, index);
            const raw_line = value[line.start..line.end];
            if (raw_line.len == 0) continue;

            const spaces = source_slice.leadingSpaces(raw_line);
            if (spaces < raw_line.len and spaces < required_indent) return true;
        }
        return false;
    }

    fn startsForbiddenDocumentMarkerLine(line: []const u8) bool {
        return startsSeparatedDocumentMarker(line, "---") or startsSeparatedDocumentMarker(line, "...");
    }

    fn startsSeparatedDocumentMarker(line: []const u8, marker: []const u8) bool {
        if (!std.mem.startsWith(u8, line, marker)) return false;
        return line.len == marker.len or line[marker.len] == ' ' or line[marker.len] == '\t' or line[marker.len] == '\n' or line[marker.len] == '\r';
    }

    fn parseHexEscape(value: []const u8, start: usize, digit_count: usize) ParseError!u21 {
        if (start + digit_count > value.len - 1) return ParseError.InvalidSyntax;
        return std.fmt.parseInt(u21, value[start .. start + digit_count], 16) catch ParseError.InvalidSyntax;
    }

    fn appendUtf8Codepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) Error!void {
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buffer) catch return ParseError.InvalidSyntax;
        try out.appendSlice(allocator, buffer[0..len]);
    }

    fn appendFlowFoldedLineBreak(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        input: []const u8,
        break_index: usize,
        end: usize,
        trailing_source_whitespace: ?usize,
    ) Error!usize {
        if (trailing_source_whitespace) |len| {
            trimTrailingFlowWhitespaceLen(out, len);
        } else {
            trimTrailingFlowWhitespace(out);
        }

        var index = source_slice.consumeLineBreak(input, break_index, end) orelse return ParseError.InvalidSyntax;
        var folded_empty_lines: usize = 0;

        while (index < end) {
            const after_indent = source_slice.skipHorizontalWhitespace(input, index, end);
            if (after_indent < end and (input[after_indent] == '\n' or input[after_indent] == '\r')) {
                try out.append(allocator, '\n');
                folded_empty_lines += 1;
                index = source_slice.consumeLineBreak(input, after_indent, end) orelse return ParseError.InvalidSyntax;
                continue;
            }

            index = after_indent;
            break;
        }

        if (folded_empty_lines == 0) {
            try out.append(allocator, ' ');
        }

        return index;
    }

    fn consumeEscapedDoubleLineBreak(input: []const u8, break_index: usize, end: usize) ParseError!usize {
        var index = source_slice.consumeLineBreak(input, break_index, end) orelse return end;
        while (index < end) {
            const after_indent = source_slice.skipHorizontalWhitespace(input, index, end);
            if (after_indent < end and (input[after_indent] == '\n' or input[after_indent] == '\r')) {
                index = source_slice.consumeLineBreak(input, after_indent, end) orelse return end;
                continue;
            }
            return after_indent;
        }
        return index;
    }

    fn trimTrailingFlowWhitespace(out: *std.ArrayList(u8)) void {
        while (out.items.len > 0) {
            switch (out.items[out.items.len - 1]) {
                ' ', '\t' => out.items.len -= 1,
                else => return,
            }
        }
    }

    fn trimTrailingFlowWhitespaceLen(out: *std.ArrayList(u8), len: usize) void {
        std.debug.assert(len <= out.items.len);
        out.items.len -= len;
    }

    test "parser: double quoted scalar decodes YAML named escapes" {
        const parsed = try parseDoubleQuotedScalarToken(std.testing.allocator, "\"\\0\\a\\b\\t\\\t\\n\\v\\f\\r\\e\\ \\\"\\/\\\\\\N\\_\\L\\P\"");
        defer std.testing.allocator.free(parsed);

        const expected = [_]u8{
            0x00, 0x07, 0x08, 0x09, 0x09, 0x0a, 0x0b, 0x0c,
            0x0d, 0x1b, ' ',  '"',  '/',  '\\', 0xc2, 0x85,
            0xc2, 0xa0, 0xe2, 0x80, 0xa8, 0xe2, 0x80, 0xa9,
        };
        try std.testing.expectEqualSlices(u8, &expected, parsed);
    }

    test "parser: double quoted scalar decodes fixed-width hex escapes" {
        const parsed = try parseDoubleQuotedScalarToken(std.testing.allocator, "\"\\x41\\u03A9\\U0001F642\"");
        defer std.testing.allocator.free(parsed);

        try std.testing.expectEqualStrings("AΩ🙂", parsed);
    }

    test "parser: double quoted scalar elides escaped line breaks" {
        const token = [_]u8{ '"', 'o', 'n', 'e', ' ', '\\', '\n', ' ', ' ', 't', 'w', 'o', '\\', '\n', ' ', ' ', '\\', '\n', ' ', ' ', 't', 'h', 'r', 'e', 'e', '"' };
        const parsed = try parseDoubleQuotedScalarToken(std.testing.allocator, &token);
        defer std.testing.allocator.free(parsed);

        try std.testing.expectEqualStrings("one twothree", parsed);
    }

    test "parser: quoted scalar allocation failures clean up partial output" {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            checkQuotedScalarAllocationFailure,
            .{},
        );
    }

    fn checkQuotedScalarAllocationFailure(failing_allocator: std.mem.Allocator) !void {
        const single = try parseSingleQuotedScalarToken(failing_allocator, "'can''t stop'");
        defer failing_allocator.free(single);
        try std.testing.expectEqualStrings("can't stop", single);

        const double = try parseDoubleQuotedScalarToken(failing_allocator, "\"alpha beta\"");
        defer failing_allocator.free(double);
        try std.testing.expectEqualStrings("alpha beta", double);
    }

    test "parser: double quoted scalar skips escaped blank continuation lines" {
        const token = [_]u8{ '"', 'o', 'n', 'e', '\\', '\n', ' ', ' ', '\n', ' ', ' ', 't', 'w', 'o', '"' };
        const parsed = try parseDoubleQuotedScalarToken(std.testing.allocator, &token);
        defer std.testing.allocator.free(parsed);

        try std.testing.expectEqualStrings("onetwo", parsed);
    }

    test "parser: double quoted scalar accepts escaped final line break" {
        const token = [_]u8{ '"', 'o', 'n', 'e', '\\', '\n', '"' };
        const parsed = try parseDoubleQuotedScalarToken(std.testing.allocator, &token);
        defer std.testing.allocator.free(parsed);

        try std.testing.expectEqualStrings("one", parsed);
    }
};

const block_scalar = struct {
    pub fn parseBlockScalarToken(allocator: std.mem.Allocator, value: scanner.BlockScalar, header_indent: usize) Error!types.Scalar {
        try validateBlockScalarContentIndent(value.content, header_indent);
        const scalar_indent = blockScalarContentIndent(value.content, header_indent, value.indent_indicator);
        try validateLeadingBlockScalarBlankIndent(value.content, scalar_indent);
        const content = value.content[0..blockScalarContentEnd(value.content, scalar_indent)];
        const parsed = switch (value.style) {
            .literal => parseLiteralBlockScalarToken(allocator, content, scalar_indent),
            .folded => parseFoldedBlockScalarToken(allocator, content, scalar_indent),
        };

        return .{
            .value = applyBlockScalarChomping(try parsed, value.chomping),
            .style = switch (value.style) {
                .literal => .literal,
                .folded => .folded,
            },
        };
    }

    pub fn parseBlockScalarTokenAt(
        allocator: std.mem.Allocator,
        tokens: []const scanner.Token,
        index: *usize,
        end: usize,
        parent_indent: usize,
    ) Error!types.Scalar {
        if (index.* >= end or tokens[index.*] != .block_scalar) return ParseError.Unsupported;

        var value = tokens[index.*].block_scalar;
        index.* += 1;

        if (value.content.len == 0) {
            if (try collectDetachedBlockScalarContent(allocator, tokens, index, end, parent_indent, value.indent_indicator)) |content| {
                value.content = content;
            }
        }

        return @This().parseBlockScalarToken(allocator, value, parent_indent);
    }

    fn collectDetachedBlockScalarContent(
        allocator: std.mem.Allocator,
        tokens: []const scanner.Token,
        index: *usize,
        end: usize,
        parent_indent: usize,
        indent_indicator: ?usize,
    ) Error!?[]const u8 {
        const explicit_indent = indent_indicator orelse return null;
        const content_indent = parent_indent + explicit_indent;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var cursor = index.*;
        var saw_line = false;
        while (cursor + 1 < end) {
            if (tokens[cursor] != .indent) break;
            const line_indent = tokens[cursor].indent;
            if (line_indent < content_indent) break;

            const line = switch (tokens[cursor + 1]) {
                .scalar => |value| value,
                .comment => |value| value,
                else => break,
            };

            try out.appendNTimes(allocator, ' ', line_indent);
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            cursor += 2;
            saw_line = true;
        }

        if (!saw_line) return null;
        index.* = cursor;
        const content = try out.toOwnedSlice(allocator);
        return content;
    }

    fn parseLiteralBlockScalarToken(allocator: std.mem.Allocator, input: []const u8, content_indent: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 0;
        var saw_non_empty_line = false;
        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            const stripped = if (!saw_non_empty_line and isEmptyBlockScalarLine(raw_line))
                ""
            else
                try stripBlockScalarIndent(raw_line, content_indent);
            try out.appendSlice(allocator, stripped);
            try out.append(allocator, '\n');
            if (!isEmptyBlockScalarLine(raw_line)) saw_non_empty_line = true;
            index = line.next;
        }

        return out.toOwnedSlice(allocator);
    }

    fn validateBlockScalarContentIndent(input: []const u8, header_indent: usize) ParseError!void {
        var index: usize = 0;
        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            const spaces = source_slice.leadingSpaces(raw_line);

            if (spaces < raw_line.len and raw_line[spaces] == '\t' and spaces <= header_indent) {
                return ParseError.InvalidSyntax;
            }

            index = line.next;
        }
    }

    fn parseFoldedBlockScalarToken(allocator: std.mem.Allocator, input: []const u8, content_indent: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 0;
        var wrote_line = false;
        var previous_blank = false;
        var previous_more_indented = false;

        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            const current = try blockScalarLine(raw_line, content_indent);
            const next = if (line.next < input.len) next_block: {
                const next_line = source_slice.lineAt(input, line.next);
                const next_raw = std.mem.trimEnd(u8, input[next_line.start..next_line.end], "\r");
                break :next_block try blockScalarLine(next_raw, content_indent);
            } else null;

            if (current.blank) {
                if (!wrote_line or previous_blank or previous_more_indented or (next != null and next.?.more_indented)) {
                    try out.append(allocator, '\n');
                }
                previous_blank = true;
                previous_more_indented = false;
                wrote_line = true;
                index = line.next;
                continue;
            }

            try out.appendSlice(allocator, current.value);
            wrote_line = true;

            if (next) |next_line| {
                try out.append(allocator, if (next_line.blank or current.more_indented or next_line.more_indented) '\n' else ' ');
            } else {
                try out.append(allocator, '\n');
            }

            previous_blank = false;
            previous_more_indented = current.more_indented;
            index = line.next;
        }

        return out.toOwnedSlice(allocator);
    }

    const BlockScalarLine = struct {
        value: []const u8,
        blank: bool,
        more_indented: bool,
    };

    fn blockScalarLine(line: []const u8, content_indent: usize) ParseError!BlockScalarLine {
        const value = try stripBlockScalarIndent(line, content_indent);
        return .{
            .value = value,
            .blank = value.len == 0,
            .more_indented = value.len != 0 and (source_slice.leadingSpaces(line) > content_indent or value[0] == '\t'),
        };
    }

    fn applyBlockScalarChomping(input: []const u8, chomping: scanner.BlockScalarChomping) []const u8 {
        if (chomping == .keep) return input;

        var content_end = input.len;
        while (content_end > 0 and input[content_end - 1] == '\n') : (content_end -= 1) {}

        return switch (chomping) {
            .strip => input[0..content_end],
            .clip => if (content_end == 0) input[0..0] else if (content_end < input.len) input[0 .. content_end + 1] else input,
            .keep => input,
        };
    }

    fn blockScalarContentIndent(input: []const u8, header_indent: usize, explicit_indent: ?usize) usize {
        if (explicit_indent) |indent| return header_indent + indent;

        var index: usize = 0;
        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            if (!isEmptyBlockScalarLine(raw_line)) return source_slice.leadingSpaces(raw_line);
            index = line.next;
        }

        return header_indent + 1;
    }

    fn validateLeadingBlockScalarBlankIndent(input: []const u8, content_indent: usize) ParseError!void {
        var index: usize = 0;
        var saw_over_indented_blank = false;

        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            if (!isEmptyBlockScalarLine(raw_line)) {
                if (saw_over_indented_blank) return ParseError.InvalidSyntax;
                return;
            }

            if (source_slice.leadingSpaces(raw_line) > content_indent) saw_over_indented_blank = true;
            index = line.next;
        }
    }

    fn blockScalarContentEnd(input: []const u8, content_indent: usize) usize {
        var index: usize = 0;
        while (index < input.len) {
            const line = source_slice.lineAt(input, index);
            const raw_line = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
            if (!isEmptyBlockScalarLine(raw_line) and source_slice.leadingSpaces(raw_line) < content_indent) {
                return line.start;
            }
            index = line.next;
        }

        return input.len;
    }

    fn stripBlockScalarIndent(line: []const u8, content_indent: usize) ParseError![]const u8 {
        const indent = source_slice.leadingSpaces(line);
        if (isEmptyBlockScalarLine(line)) {
            return if (indent > content_indent) line[content_indent..] else "";
        }

        if (indent < content_indent) return ParseError.InvalidSyntax;
        return line[content_indent..];
    }

    fn isEmptyBlockScalarLine(line: []const u8) bool {
        return std.mem.trim(u8, line, " ").len == 0;
    }
};

const document_scalar = struct {
    pub const ScalarDocumentTokens = struct {
        scalar: ?types.Scalar,
        directives: TokenDirectives = .{},
        explicit_start: bool = false,
        explicit_end: bool = false,
        content_same_line: bool = false,
        content_same_line_separated_by_tab: bool = false,
    };

    pub fn parseScalarTokens(allocator: std.mem.Allocator, tokens: []const scanner.Token) Error!@This().ScalarDocumentTokens {
        return @This().parseScalarTokenRange(allocator, tokens, 1, tokens.len - 1);
    }

    pub fn parseScalarTokenRange(
        allocator: std.mem.Allocator,
        tokens: []const scanner.Token,
        start: usize,
        end: usize,
    ) Error!@This().ScalarDocumentTokens {
        var index: usize = start;

        if (index == end) return .{ .scalar = null };

        const directives = try internal.consumeLeadingDirectives(allocator, tokens, &index, end);
        if (index == end and directives.seen) return ParseError.InvalidSyntax;

        const explicit_start = index < end and tokens[index] == .document_start;
        if (directives.seen and !explicit_start) return ParseError.InvalidSyntax;
        if (explicit_start) index += 1;
        const document_start_content = token_cursor.consumeDocumentStartContent(tokens, &index, end);

        token_cursor.skipComments(tokens, &index, end);

        if (explicit_start and (index >= end or tokens[index] == .document_end)) {
            const explicit_end = index < end and tokens[index] == .document_end;
            if (explicit_end) {
                index += 1;
                token_cursor.skipComments(tokens, &index, end);
            }
            if (index != end) return ParseError.Unsupported;
            return .{
                .scalar = .{ .value = try allocator.dupe(u8, "") },
                .directives = directives,
                .explicit_start = true,
                .explicit_end = explicit_end,
            };
        }

        const content_same_line = document_start_content.content_same_line;
        if (explicit_start and !content_same_line and (index >= end or tokens[index] != .indent)) return ParseError.Unsupported;
        var content_indent: usize = 0;
        if (index < end and tokens[index] == .indent) {
            content_indent = tokens[index].indent;
            index += 1;
        }
        token_cursor.skipComments(tokens, &index, end);

        const separated_properties = try internal.consumeTopLevelSeparated(allocator, tokens, &index, end, directives);
        const properties = if (internal.has(separated_properties))
            separated_properties
        else
            try internal.consumeNodeProperties(allocator, tokens, &index, end, directives);

        if (index >= end or tokens[index] == .document_end) {
            if (!internal.has(properties)) return ParseError.Unsupported;
            var scalar: types.Scalar = .{ .value = try allocator.dupe(u8, "") };
            scalar.anchor = properties.anchor;
            scalar.tag = properties.tag;

            const explicit_end = index < end and tokens[index] == .document_end;
            if (explicit_end) {
                index += 1;
                token_cursor.skipComments(tokens, &index, end);
            }
            if (index != end) return ParseError.Unsupported;
            return .{
                .scalar = scalar,
                .directives = directives,
                .explicit_start = explicit_start,
                .explicit_end = explicit_end,
                .content_same_line = content_same_line,
                .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
            };
        }
        if (properties.source_end) |property_end| {
            if (tokens[index] == .scalar) {
                const value = tokens[index].scalar;
                if (scalarStartsAdjacentToPropertyIndicator(property_end, value) or
                    isBareBlockSequenceEntryScalar(value))
                {
                    return ParseError.InvalidSyntax;
                }
            }
        }
        var scalar = switch (tokens[index]) {
            .scalar => |value| scalar: {
                if (isQuotedScalarToken(value)) {
                    index += 1;
                    break :scalar try parseScalarToken(allocator, value);
                }
                break :scalar try parsePlainScalarDocumentToken(allocator, tokens, &index, end);
            },
            .block_scalar => |value| scalar: {
                index += 1;
                break :scalar try block_scalar.parseBlockScalarToken(allocator, value, content_indent);
            },
            else => return ParseError.Unsupported,
        };
        scalar.anchor = properties.anchor;
        scalar.tag = properties.tag;

        token_cursor.skipComments(tokens, &index, end);
        const explicit_end = index < end and tokens[index] == .document_end;
        if (explicit_end) {
            index += 1;
            token_cursor.skipComments(tokens, &index, end);
        }

        if (index != end) return ParseError.Unsupported;
        return .{
            .scalar = scalar,
            .directives = directives,
            .explicit_start = explicit_start,
            .explicit_end = explicit_end,
            .content_same_line = content_same_line,
            .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
        };
    }

    pub const AliasDocumentTokens = struct {
        value: []const u8,
        directives: TokenDirectives = .{},
        explicit_start: bool = false,
        explicit_end: bool = false,
        content_same_line: bool = false,
        content_same_line_separated_by_tab: bool = false,
    };

    pub fn parseAliasTokens(allocator: std.mem.Allocator, tokens: []const scanner.Token) Error!?@This().AliasDocumentTokens {
        return @This().parseAliasTokenRange(allocator, tokens, 1, tokens.len - 1);
    }

    pub fn parseAliasTokenRange(
        allocator: std.mem.Allocator,
        tokens: []const scanner.Token,
        start: usize,
        end: usize,
    ) Error!?@This().AliasDocumentTokens {
        var index: usize = start;

        if (index == end) return null;

        const directives = try internal.consumeLeadingDirectives(allocator, tokens, &index, end);
        if (index == end and directives.seen) return ParseError.InvalidSyntax;

        const explicit_start = index < end and tokens[index] == .document_start;
        if (directives.seen and !explicit_start) return ParseError.InvalidSyntax;
        if (explicit_start) index += 1;
        const document_start_content = token_cursor.consumeDocumentStartContent(tokens, &index, end);

        token_cursor.skipComments(tokens, &index, end);
        const content_same_line = document_start_content.content_same_line;
        if (explicit_start and !content_same_line and (index >= end or tokens[index] != .indent)) return null;
        if (index < end and tokens[index] == .indent) index += 1;
        token_cursor.skipComments(tokens, &index, end);

        const separated_properties = try internal.consumeTopLevelSeparated(allocator, tokens, &index, end, directives);
        const properties = if (internal.has(separated_properties))
            separated_properties
        else
            try internal.consumeNodeProperties(allocator, tokens, &index, end, directives);
        if (internal.has(properties) and index < end and tokens[index] == .alias) {
            return ParseError.InvalidSyntax;
        }

        if (index >= end or tokens[index] != .alias) return null;
        const alias = try allocator.dupe(u8, tokens[index].alias);
        index += 1;

        token_cursor.skipComments(tokens, &index, end);
        if (token_cursor.aliasDocumentHasTrailingContent(tokens, index, end)) return ParseError.InvalidSyntax;
        const explicit_end = index < end and tokens[index] == .document_end;
        if (explicit_end) {
            index += 1;
            token_cursor.skipComments(tokens, &index, end);
        }

        if (index != end) return null;
        return .{
            .value = alias,
            .directives = directives,
            .explicit_start = explicit_start,
            .explicit_end = explicit_end,
            .content_same_line = content_same_line,
            .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
        };
    }
};
