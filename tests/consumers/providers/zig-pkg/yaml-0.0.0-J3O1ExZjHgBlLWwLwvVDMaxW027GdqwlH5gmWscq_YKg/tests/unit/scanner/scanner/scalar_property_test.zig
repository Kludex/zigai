//! Purpose: Verify block properties, anchors, aliases, tags, and plain scalar boundaries.
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

test "scanner tokenizes block flow properties anchors aliases tags indentation and comments" {
    var tokens = try scan(std.testing.allocator,
        \\- &anchor !tag [one, *anchor, {key: value}] # tail
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .block_sequence_entry,
        .anchor,
        .tag,
        .flow_sequence_start,
        .scalar,
        .flow_entry,
        .alias,
        .flow_entry,
        .flow_mapping_start,
        .scalar,
        .flow_mapping_value,
        .scalar,
        .flow_mapping_end,
        .flow_sequence_end,
        .comment,
        .stream_end,
    });
    try std.testing.expectEqual(@as(usize, 0), tokens.tokens[1].indent);
    try std.testing.expectEqualStrings("anchor", tokens.tokens[3].anchor);
    try std.testing.expectEqualStrings("!tag", tokens.tokens[4].tag);
    try std.testing.expectEqualStrings("one", tokens.tokens[6].scalar);
    try std.testing.expectEqualStrings("anchor", tokens.tokens[8].alias);
    try std.testing.expectEqualStrings("key", tokens.tokens[11].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[13].scalar);
    try std.testing.expectEqualStrings("tail", tokens.tokens[16].comment);
}

test "scanner tokenizes a bare non-specific tag property" {
    var tokens = try scan(std.testing.allocator,
        \\! a
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .tag,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("!", tokens.tokens[2].tag);
    try std.testing.expectEqualStrings("a", tokens.tokens[3].scalar);
}

test "scanner keeps block plain scalar flow indicators inside scalar chunks" {
    var tokens = try scan(std.testing.allocator,
        \\a!"#$%&'()*+,-./09:;<=>?@AZ[\]^_`az{|}~: safe
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("a!\"#$%&'()*+,-./09:;<=>?@AZ[\\]^_`az{|}~", tokens.tokens[2].scalar);
    try std.testing.expectEqualStrings("safe", tokens.tokens[4].scalar);
}

test "scanner keeps inline block scalar indicators inside plain scalar content" {
    var tokens = try scan(std.testing.allocator, "cM | > $x#\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .scalar,
        .scalar,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("cM", tokens.tokens[2].scalar);
    try std.testing.expectEqualStrings("|", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings(">", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("$x#", tokens.tokens[5].scalar);
}

test "scanner treats comma outside flow collections as plain scalar content" {
    var tokens = try scan(std.testing.allocator, ",-./09\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings(",-./09", tokens.tokens[2].scalar);
}

test "scanner tokenizes explicit mapping key indicators without consuming question-mark scalars" {
    var tokens = try scan(std.testing.allocator,
        \\? key
        \\: value
        \\{? explicit: entry, ?foo: safe}
        \\
    );
    defer tokens.deinit();

    try expectTokenKindNames(tokens.tokens, &.{
        "stream_start",
        "indent",
        "block_mapping_key",
        "scalar",
        "indent",
        "block_mapping_value",
        "scalar",
        "indent",
        "flow_mapping_start",
        "flow_mapping_key",
        "scalar",
        "flow_mapping_value",
        "scalar",
        "flow_entry",
        "scalar",
        "flow_mapping_value",
        "scalar",
        "flow_mapping_end",
        "stream_end",
    });
    try std.testing.expectEqualStrings("key", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("value", tokens.tokens[6].scalar);
    try std.testing.expectEqualStrings("explicit", tokens.tokens[10].scalar);
    try std.testing.expectEqualStrings("entry", tokens.tokens[12].scalar);
    try std.testing.expectEqualStrings("?foo", tokens.tokens[14].scalar);
    try std.testing.expectEqualStrings("safe", tokens.tokens[16].scalar);
}

test "scanner keeps separated question marks inside plain scalar text as scalars" {
    var tokens = try scan(std.testing.allocator,
        \\another ? string
        \\[another ? string]
        \\
    );
    defer tokens.deinit();

    try expectTokenKindNames(tokens.tokens, &.{
        "stream_start",
        "indent",
        "scalar",
        "scalar",
        "scalar",
        "indent",
        "flow_sequence_start",
        "scalar",
        "scalar",
        "scalar",
        "flow_sequence_end",
        "stream_end",
    });
    try std.testing.expectEqualStrings("another", tokens.tokens[2].scalar);
    try std.testing.expectEqualStrings("?", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("string", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("another", tokens.tokens[7].scalar);
    try std.testing.expectEqualStrings("?", tokens.tokens[8].scalar);
    try std.testing.expectEqualStrings("string", tokens.tokens[9].scalar);
}

test "scanner keeps unbalanced quote characters inside plain scalar continuations" {
    var tokens = try scan(std.testing.allocator,
        \\message: Unknown variable "bar
        \\
    );
    defer tokens.deinit();

    try expectTokenKindNames(tokens.tokens, &.{
        "stream_start",
        "indent",
        "scalar",
        "block_mapping_value",
        "scalar",
        "scalar",
        "scalar",
        "stream_end",
    });
    try std.testing.expectEqualStrings("message", tokens.tokens[2].scalar);
    try std.testing.expectEqualStrings("Unknown", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("variable", tokens.tokens[5].scalar);
    try std.testing.expectEqualStrings("\"bar", tokens.tokens[6].scalar);
}
