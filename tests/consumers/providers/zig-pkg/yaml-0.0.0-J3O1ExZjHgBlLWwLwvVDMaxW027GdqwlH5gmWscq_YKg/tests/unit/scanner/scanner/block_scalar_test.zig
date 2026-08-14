//! Purpose: Verify block scalar headers, compact keys, chomping, content, and indentation inference.
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

test "scanner tokenizes block scalar headers and raw content" {
    var tokens = try scan(std.testing.allocator,
        \\|-
        \\  literal
        \\  lines
        \\folded: >2+
        \\    folded
        \\    lines
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_scalar,
        .indent,
        .scalar,
        .block_mapping_value,
        .block_scalar,
        .stream_end,
    });

    const literal = tokens.tokens[2].block_scalar;
    try std.testing.expectEqual(BlockScalarStyle.literal, literal.style);
    try std.testing.expectEqual(BlockScalarChomping.strip, literal.chomping);
    try std.testing.expectEqual(@as(?usize, null), literal.indent_indicator);
    try std.testing.expectEqualStrings("  literal\n  lines\n", literal.content);

    const folded = tokens.tokens[6].block_scalar;
    try std.testing.expectEqual(BlockScalarStyle.folded, folded.style);
    try std.testing.expectEqual(BlockScalarChomping.keep, folded.chomping);
    try std.testing.expectEqual(@as(?usize, 2), folded.indent_indicator);
    try std.testing.expectEqualStrings("    folded\n    lines\n", folded.content);
}

test "scanner stops compact sequence mapping block scalars before sibling pairs" {
    var tokens = try scan(std.testing.allocator,
        \\- aaa: |2
        \\    xxx
        \\  bbb: |
        \\    yyy
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_sequence_entry,
        .scalar,
        .block_mapping_value,
        .block_scalar,
        .indent,
        .scalar,
        .block_mapping_value,
        .block_scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("aaa", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("    xxx\n", tokens.tokens[5].block_scalar.content);
    try std.testing.expectEqualStrings("bbb", tokens.tokens[7].scalar);
    try std.testing.expectEqualStrings("    yyy\n", tokens.tokens[9].block_scalar.content);
}

test "scanner tokenizes block scalar compact explicit keys in block sequences" {
    var tokens = try scan(std.testing.allocator,
        \\- ? >
        \\    folded
        \\  : value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_sequence_entry,
        .scalar,
        .block_scalar,
        .indent,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("?", tokens.tokens[3].scalar);
    try std.testing.expectEqual(BlockScalarStyle.folded, tokens.tokens[4].block_scalar.style);
    try std.testing.expectEqualStrings("    folded\n", tokens.tokens[4].block_scalar.content);
    try std.testing.expectEqualStrings("value", tokens.tokens[7].scalar);
}

test "scanner tokenizes top-level explicit block scalar keys" {
    var tokens = try scan(std.testing.allocator,
        \\? >
        \\  folded key
        \\: value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_mapping_key,
        .block_scalar,
        .indent,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqual(BlockScalarStyle.folded, tokens.tokens[3].block_scalar.style);
    try std.testing.expectEqualStrings("  folded key\n", tokens.tokens[3].block_scalar.content);
    try std.testing.expectEqualStrings("value", tokens.tokens[6].scalar);
}

test "scanner tokenizes quoted compact explicit keys in block sequences" {
    var tokens = try scan(std.testing.allocator,
        \\- ? 'multi
        \\    line'
        \\  : value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_sequence_entry,
        .scalar,
        .scalar,
        .indent,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("?", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("'multi\n    line'", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[7].scalar);
}

test "scanner tokenizes zero-indented top-level block scalar content" {
    var tokens = try scan(std.testing.allocator,
        \\|
        \\%!PS-Adobe-2.0 # Not the first line
        \\...
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_scalar,
        .document_end,
        .stream_end,
    });

    try std.testing.expectEqualStrings("%!PS-Adobe-2.0 # Not the first line\n", tokens.tokens[2].block_scalar.content);
}

test "scanner rejects block scalar header comments without separation" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\|#comment
        \\  literal
        \\
    ));

    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\>#comment
        \\  folded
        \\
    ));
}

test "scanner accepts separated block scalar header comments" {
    var literal = try scan(std.testing.allocator,
        \\| # header comment
        \\  literal
        \\  lines
        \\
    );
    defer literal.deinit();

    try expectTokenKinds(literal.tokens, &.{
        .stream_start,
        .indent,
        .block_scalar,
        .stream_end,
    });
    try std.testing.expectEqual(BlockScalarStyle.literal, literal.tokens[2].block_scalar.style);
    try std.testing.expectEqualStrings("  literal\n  lines\n", literal.tokens[2].block_scalar.content);

    var folded = try scan(std.testing.allocator,
        \\>2- # header comment
        \\    folded
        \\    lines
        \\
    );
    defer folded.deinit();

    try expectTokenKinds(folded.tokens, &.{
        .stream_start,
        .indent,
        .block_scalar,
        .stream_end,
    });
    const block = folded.tokens[2].block_scalar;
    try std.testing.expectEqual(BlockScalarStyle.folded, block.style);
    try std.testing.expectEqual(BlockScalarChomping.strip, block.chomping);
    try std.testing.expectEqual(@as(?usize, 2), block.indent_indicator);
    try std.testing.expectEqualStrings("    folded\n    lines\n", block.content);

    var tab_separated = try scan(std.testing.allocator, "|+\t# header comment\n  literal\n");
    defer tab_separated.deinit();

    try expectTokenKinds(tab_separated.tokens, &.{
        .stream_start,
        .indent,
        .block_scalar,
        .stream_end,
    });
    const tab_block = tab_separated.tokens[2].block_scalar;
    try std.testing.expectEqual(BlockScalarStyle.literal, tab_block.style);
    try std.testing.expectEqual(BlockScalarChomping.keep, tab_block.chomping);
    try std.testing.expectEqualStrings("  literal\n", tab_block.content);
}

test "scanner rejects invalid block scalar indentation indicators" {
    const cases = [_][]const u8{
        "|0\n  literal\n",
        ">0\n  folded\n",
        "|10\n  literal\n",
        ">10\n  folded\n",
        "|-10\n  literal\n",
        ">+10\n  folded\n",
        "|0-\n  literal\n",
        ">0+\n  folded\n",
    };

    for (cases) |input| {
        try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, input));
    }
}

test "scanner rejects duplicate block scalar header indicators" {
    const cases = [_][]const u8{
        "|-+\n  literal\n",
        "|+-\n  literal\n",
        ">++\n  folded\n",
        ">--\n  folded\n",
        "|22\n  literal\n",
        ">2-3\n  folded\n",
    };

    for (cases) |input| {
        try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, input));
    }
}

test "scanner infers nested block scalar indentation" {
    var tokens = try scan(std.testing.allocator,
        \\parent:
        \\  child: |
        \\    nested
        \\    lines
        \\  next: value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .block_mapping_value,
        .indent,
        .scalar,
        .block_mapping_value,
        .block_scalar,
        .indent,
        .scalar,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });

    const block = tokens.tokens[7].block_scalar;
    try std.testing.expectEqual(BlockScalarStyle.literal, block.style);
    try std.testing.expectEqual(@as(?usize, null), block.indent_indicator);
    try std.testing.expectEqualStrings("    nested\n    lines\n", block.content);
    try std.testing.expectEqualStrings("next", tokens.tokens[9].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[11].scalar);
}

test "scanner accepts block scalars after document markers and node properties" {
    var anchored = try scan(std.testing.allocator,
        \\&a |
        \\  value
        \\
    );
    defer anchored.deinit();

    try expectTokenKinds(anchored.tokens, &.{
        .stream_start,
        .indent,
        .anchor,
        .block_scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("a", anchored.tokens[2].anchor);
    try std.testing.expectEqualStrings("  value\n", anchored.tokens[3].block_scalar.content);

    var tagged = try scan(std.testing.allocator,
        \\!tag >
        \\  value
        \\
    );
    defer tagged.deinit();

    try expectTokenKinds(tagged.tokens, &.{
        .stream_start,
        .indent,
        .tag,
        .block_scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("!tag", tagged.tokens[2].tag);
    try std.testing.expectEqual(BlockScalarStyle.folded, tagged.tokens[3].block_scalar.style);
    try std.testing.expectEqualStrings("  value\n", tagged.tokens[3].block_scalar.content);
}

test "scanner treats block scalar indicators inside plain and flow content as non-node indicators" {
    var plain = try scan(std.testing.allocator,
        \\a|b
        \\a>b
        \\
    );
    defer plain.deinit();

    try expectTokenKinds(plain.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .indent,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("a|b", plain.tokens[2].scalar);
    try std.testing.expectEqualStrings("a>b", plain.tokens[4].scalar);

    var flow_literal = try scan(std.testing.allocator, "[|]\n");
    defer flow_literal.deinit();
    try expectTokenKinds(flow_literal.tokens, &.{
        .stream_start,
        .indent,
        .flow_sequence_start,
        .scalar,
        .flow_sequence_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings("|", flow_literal.tokens[3].scalar);

    var flow_folded = try scan(std.testing.allocator, "[>]\n");
    defer flow_folded.deinit();
    try expectTokenKinds(flow_folded.tokens, &.{
        .stream_start,
        .indent,
        .flow_sequence_start,
        .scalar,
        .flow_sequence_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings(">", flow_folded.tokens[3].scalar);
}
