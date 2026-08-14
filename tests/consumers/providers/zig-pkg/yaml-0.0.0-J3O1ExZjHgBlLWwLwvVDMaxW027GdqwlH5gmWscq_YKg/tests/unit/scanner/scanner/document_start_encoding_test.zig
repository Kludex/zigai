//! Purpose: Verify same-line document starts, UTF decoding, BOM handling, and reserved indicators.
//! Owns: A focused shard of scanner regression coverage.
//! Does not own: Shared scanner test helpers or parser behavior.
//! Depends on: support.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig.

const support = @import("support.zig");

const std = support.std;
const BlockScalarChomping = support.BlockScalarChomping;
const BlockScalarStyle = support.BlockScalarStyle;
const scan = support.scan;
const expectTokenKinds = support.expectTokenKinds;
const expectTokenKindNames = support.expectTokenKindNames;

test "scanner records same-line document start content separator" {
    var tokens = try scan(std.testing.allocator, "---\ttab\n" ++
        "--- space\n" ++
        "--- # comment only\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .scalar,
        .document_start,
        .document_start_content,
        .scalar,
        .document_start,
        .comment,
        .stream_end,
    });
    try std.testing.expect(tokens.tokens[2].document_start_content.separated_by_tab);
    try std.testing.expect(!tokens.tokens[5].document_start_content.separated_by_tab);
}

test "scanner tokenizes same-line document start block scalar headers" {
    var tokens = try scan(std.testing.allocator, "--- |1-\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .block_scalar,
        .stream_end,
    });
    try std.testing.expectEqual(BlockScalarStyle.literal, tokens.tokens[3].block_scalar.style);
    try std.testing.expectEqual(BlockScalarChomping.strip, tokens.tokens[3].block_scalar.chomping);
    try std.testing.expectEqual(@as(?usize, 1), tokens.tokens[3].block_scalar.indent_indicator);
    try std.testing.expectEqualStrings("", tokens.tokens[3].block_scalar.content);

    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "--- |0\n"));
}

test "scanner tokenizes same-line document start block scalar content" {
    const input = "--- |-\n" ++
        " ab\n" ++
        " \n" ++
        " \n" ++
        "...\n";
    var tokens = try scan(std.testing.allocator, input);
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .block_scalar,
        .document_end,
        .stream_end,
    });
    try std.testing.expectEqual(BlockScalarStyle.literal, tokens.tokens[3].block_scalar.style);
    try std.testing.expectEqual(BlockScalarChomping.strip, tokens.tokens[3].block_scalar.chomping);
    try std.testing.expectEqualStrings(" ab\n \n \n", tokens.tokens[3].block_scalar.content);
}

test "scanner tokenizes same-line document start block indicators" {
    var tokens = try scan(std.testing.allocator,
        \\--- - one
        \\--- ? key
        \\: value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .block_sequence_entry,
        .scalar,
        .document_start,
        .document_start_content,
        .block_mapping_key,
        .scalar,
        .indent,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("one", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("key", tokens.tokens[8].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[11].scalar);
}

test "scanner decodes UTF-16 input before tokenizing" {
    const input = [_]u8{
        0xff, 0xfe,
        'k',  0,
        'e',  0,
        'y',  0,
        ':',  0,
        ' ',  0,
        'v',  0,
        'a',  0,
        'l',  0,
        'u',  0,
        'e',  0,
        '\n', 0,
    };

    var tokens = try scan(std.testing.allocator, &input);
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("key", tokens.tokens[2].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[4].scalar);
}

test "scanner decodes UTF-32 input before tokenizing" {
    const input = [_]u8{
        0, 0, 0, 'a',
        0, 0, 0, '\n',
    };

    var tokens = try scan(std.testing.allocator, &input);
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("a", tokens.tokens[2].scalar);
}

test "scanner rejects misplaced UTF-8 BOM inside plain block content" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "- one\n" ++
        "\xEF\xBB\xBF- two\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "one \xEF\xBB\xBF two\n"));
}

test "scanner rejects misplaced UTF-8 BOM inside node properties" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "&bad\xEF\xBB\xBFanchor value\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "*bad\xEF\xBB\xBFalias\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "!bad\xEF\xBB\xBFtag value\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "!<tag:yaml.org,2002:\xEF\xBB\xBFstr> value\n"));
}

test "scanner rejects reserved indicators at the start of plain scalars" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "@reserved\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "`reserved\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "- @reserved\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "{key: `reserved}\n"));
}

test "scanner allows reserved indicators inside plain scalar text" {
    var tokens = try scan(std.testing.allocator, "Billsmer @ 338-4338.\n");
    defer tokens.deinit();

    try expectTokenKindNames(tokens.tokens, &.{
        "stream_start",
        "indent",
        "scalar",
        "scalar",
        "scalar",
        "stream_end",
    });
    try std.testing.expectEqualStrings("@", tokens.tokens[3].scalar);
}
