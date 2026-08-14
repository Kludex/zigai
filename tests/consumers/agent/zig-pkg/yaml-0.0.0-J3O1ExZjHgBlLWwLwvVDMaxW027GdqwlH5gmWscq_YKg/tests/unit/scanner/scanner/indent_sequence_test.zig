//! Purpose: Verify indentation, compact block sequence indicators, and tab handling.
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

test "scanner rejects tabs used as block indentation but accepts tab separation" {
    var separated = try scan(std.testing.allocator, "-\tfoo\nkey:\tvalue\n");
    defer separated.deinit();

    try expectTokenKindNames(separated.tokens, &.{
        "stream_start",
        "indent",
        "block_sequence_entry",
        "scalar",
        "indent",
        "scalar",
        "block_mapping_value",
        "scalar",
        "stream_end",
    });
    try std.testing.expectEqualStrings("foo", separated.tokens[3].scalar);
    try std.testing.expectEqualStrings("key", separated.tokens[5].scalar);
    try std.testing.expectEqualStrings("value", separated.tokens[7].scalar);

    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "\tkey: value\n"));
}

test "scanner tokenizes compact block sequence indicators with spaces" {
    var tokens = try scan(std.testing.allocator,
        \\- - nested
        \\  - second
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_sequence_entry,
        .block_sequence_entry,
        .scalar,
        .indent,
        .block_sequence_entry,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("nested", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("second", tokens.tokens[7].scalar);
}

test "scanner tokenizes compact block sequence indicators after node properties" {
    var tokens = try scan(std.testing.allocator,
        \\---
        \\- &items - nested
        \\---
        \\? key
        \\: !tag - value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .indent,
        .block_sequence_entry,
        .anchor,
        .block_sequence_entry,
        .scalar,
        .document_start,
        .indent,
        .block_mapping_key,
        .scalar,
        .indent,
        .block_mapping_value,
        .tag,
        .block_sequence_entry,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("items", tokens.tokens[4].anchor);
    try std.testing.expectEqualStrings("nested", tokens.tokens[6].scalar);
    try std.testing.expectEqualStrings("key", tokens.tokens[10].scalar);
    try std.testing.expectEqualStrings("!tag", tokens.tokens[13].tag);
    try std.testing.expectEqualStrings("value", tokens.tokens[15].scalar);
}

test "scanner rejects tab-separated compact block sequence indicators" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "-\t-\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "- \t-\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "? -\n:\t-\n"));
}

test "scanner rejects tab-separated explicit block mapping keys before nested nodes" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "?\t-\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "?\tkey:\n"));
}

test "scanner accepts tab-separated explicit block mapping plain keys" {
    var tokens = try scan(std.testing.allocator, "?\tplain\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_mapping_key,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("plain", tokens.tokens[3].scalar);
}

test "scanner accepts tab-separated continuation and flow collection lines" {
    var plain = try scan(std.testing.allocator, "1st non-empty\n\n 2nd non-empty\n\t3rd non-empty\n");
    defer plain.deinit();

    try expectTokenKindNames(plain.tokens, &.{
        "stream_start",
        "indent",
        "scalar",
        "scalar",
        "indent",
        "scalar",
        "scalar",
        "indent",
        "scalar",
        "scalar",
        "stream_end",
    });
    try std.testing.expectEqual(@as(usize, 0), plain.tokens[7].indent);
    try std.testing.expectEqualStrings("3rd", plain.tokens[8].scalar);

    var flow = try scan(std.testing.allocator, "\t[\n\t]\n");
    defer flow.deinit();

    try expectTokenKinds(flow.tokens, &.{
        .stream_start,
        .indent,
        .flow_sequence_start,
        .indent,
        .flow_sequence_end,
        .stream_end,
    });

    var top_level_flow = try scan(std.testing.allocator, "\t[scalar]\n");
    defer top_level_flow.deinit();

    try expectTokenKinds(top_level_flow.tokens, &.{
        .stream_start,
        .indent,
        .flow_sequence_start,
        .scalar,
        .flow_sequence_end,
        .stream_end,
    });
    try std.testing.expectEqual(@as(usize, 0), top_level_flow.tokens[1].indent);
    try std.testing.expectEqualStrings("scalar", top_level_flow.tokens[3].scalar);
}
