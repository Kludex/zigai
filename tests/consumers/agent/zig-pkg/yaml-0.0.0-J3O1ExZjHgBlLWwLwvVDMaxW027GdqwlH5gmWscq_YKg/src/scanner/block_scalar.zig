//! Purpose: Scan YAML block scalar headers and raw content ranges.
//! Owns: Literal/folded header validation, chomping, indentation indicators, and content bounds.
//! Does not own: Folding or chomping application in parsed scalar values.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const BlockScalar = token.BlockScalar;
const BlockScalarChomping = token.BlockScalarChomping;
const Error = token.Error;

pub fn indicatorStartsNode(tokens: []const token.Token, index: usize, line_content_start: usize, flow_depth: usize) bool {
    if (flow_depth != 0) return false;
    if (index == line_content_start) return true;
    if (tokens.len == 0) return false;

    return switch (tokens[tokens.len - 1]) {
        .document_start,
        .document_start_content,
        .block_sequence_entry,
        .block_mapping_key,
        .block_mapping_value,
        .anchor,
        .tag,
        => true,
        .scalar => |value| std.mem.eql(u8, value, "?") and compactSequenceExplicitKeyParentIndent(tokens, 0) != null,
        else => false,
    };
}

pub fn readBlockScalar(
    input: []const u8,
    index: *usize,
    line_content_start: usize,
    tokens: []const token.Token,
    flow_depth: usize,
    indicator: u8,
) Error!BlockScalar {
    if (flow_depth != 0) return error.InvalidSyntax;

    const header_line = lex.lineAt(input, index.*);
    const header = lex.stripLineComment(input[index.* + 1 .. header_line.end]);

    var chomping: BlockScalarChomping = .clip;
    var indent_indicator: ?usize = null;
    var saw_chomping = false;
    var saw_indent = false;
    var cursor: usize = 0;
    while (cursor < header.len) : (cursor += 1) {
        switch (header[cursor]) {
            ' ', '\t', '\r' => {},
            '-' => {
                if (saw_chomping) return error.InvalidSyntax;
                saw_chomping = true;
                chomping = .strip;
            },
            '+' => {
                if (saw_chomping) return error.InvalidSyntax;
                saw_chomping = true;
                chomping = .keep;
            },
            '1'...'9' => {
                if (saw_indent) return error.InvalidSyntax;
                saw_indent = true;
                indent_indicator = header[cursor] - '0';
            },
            else => return error.InvalidSyntax,
        }
    }

    const line_start = lex.lineStartAt(input, index.*);
    const base_parent_indent = if (lex.startsDocumentMarker(input[line_start..], "---"))
        0
    else if (line_content_start >= line_start)
        lex.countIndentSpaces(input[line_start..line_content_start])
    else
        0;
    const parent_indent = compactSequenceMappingValueParentIndent(input, index.*, line_content_start, tokens, base_parent_indent) orelse
        compactSequenceExplicitKeyParentIndent(tokens, base_parent_indent) orelse
        base_parent_indent;
    const content_start = header_line.next;
    const content_end = lex.findBlockScalarContentEnd(
        input,
        content_start,
        parent_indent,
        indent_indicator,
        canReadZeroIndentedBlockScalar(tokens),
    );

    index.* = content_end;

    return .{
        .style = if (indicator == '|') .literal else .folded,
        .chomping = chomping,
        .indent_indicator = indent_indicator,
        .content = input[content_start..content_end],
    };
}

pub fn compactSequenceExplicitKeyParentIndent(tokens: []const token.Token, base_parent_indent: usize) ?usize {
    var cursor = tokens.len;
    while (cursor > 0) {
        switch (tokens[cursor - 1]) {
            .anchor, .tag => cursor -= 1,
            else => break,
        }
    }
    if (cursor == 0) return null;

    switch (tokens[cursor - 1]) {
        .scalar => |value| if (!std.mem.eql(u8, value, "?")) return null,
        else => return null,
    }

    cursor -= 1;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor]) {
            .anchor, .tag => continue,
            .block_sequence_entry => return base_parent_indent + 2,
            else => return null,
        }
    }

    return null;
}

fn compactSequenceMappingValueParentIndent(
    input: []const u8,
    index: usize,
    line_content_start: usize,
    tokens: []const token.Token,
    base_parent_indent: usize,
) ?usize {
    if (tokens.len == 0 or tokens[tokens.len - 1] != .block_mapping_value) {
        return null;
    }

    var cursor = line_content_start;
    var compact_sequence_entries: usize = 0;
    while (cursor < index and input[cursor] == '-' and lex.isSeparatedIndicatorAt(input, cursor, 1)) {
        compact_sequence_entries += 1;
        cursor += 1;
        while (cursor < index and input[cursor] == ' ') : (cursor += 1) {}
    }

    if (compact_sequence_entries == 0) return null;
    return base_parent_indent + compact_sequence_entries * 2;
}

fn canReadZeroIndentedBlockScalar(tokens: []const token.Token) bool {
    if (tokens.len == 0) return false;
    return switch (std.meta.activeTag(tokens[tokens.len - 1])) {
        .document_start, .document_start_content, .indent => true,
        else => false,
    };
}

test "scanner block scalar: compact explicit key parent indent rejects non-sequence prefixes" {
    const scalar_only = [_]token.Token{.{ .scalar = "?" }};
    try std.testing.expectEqual(@as(?usize, null), compactSequenceExplicitKeyParentIndent(&scalar_only, 4));

    const wrong_prefix = [_]token.Token{
        .{ .scalar = "prefix" },
        .{ .scalar = "?" },
    };
    try std.testing.expectEqual(@as(?usize, null), compactSequenceExplicitKeyParentIndent(&wrong_prefix, 4));
}
