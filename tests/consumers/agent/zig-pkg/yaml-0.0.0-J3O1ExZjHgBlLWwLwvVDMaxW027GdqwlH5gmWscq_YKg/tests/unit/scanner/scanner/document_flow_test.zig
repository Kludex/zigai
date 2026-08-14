//! Purpose: Verify document markers, directives, comments, and flow indicator tokenization.
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

test "scanner tokenizes directives comments and document boundaries" {
    var tokens = try scan(std.testing.allocator,
        \\%YAML 1.2 # version
        \\---
        \\# body comment
        \\...
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .directive,
        .document_start,
        .comment,
        .document_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings("%YAML 1.2", tokens.tokens[1].directive);
    try std.testing.expectEqualStrings("body comment", tokens.tokens[3].comment);
}

test "scanner treats percent at line start inside flow as scalar content" {
    var tokens = try scan(std.testing.allocator,
        \\{ matches
        \\% : 20 }
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .flow_mapping_start,
        .scalar,
        .indent,
        .scalar,
        .flow_mapping_value,
        .scalar,
        .flow_mapping_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings("%", tokens.tokens[5].scalar);
}

test "scanner tokenizes adjacent flow mapping values after JSON-like keys" {
    var tokens = try scan(std.testing.allocator, "[\"JSON like\":adjacent, {JSON: like}:adjacent]\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .flow_sequence_start,
        .scalar,
        .flow_mapping_value,
        .scalar,
        .flow_entry,
        .flow_mapping_start,
        .scalar,
        .flow_mapping_value,
        .scalar,
        .flow_mapping_end,
        .flow_mapping_value,
        .scalar,
        .flow_sequence_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings("\"JSON like\"", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("adjacent", tokens.tokens[5].scalar);
    try std.testing.expectEqualStrings("JSON", tokens.tokens[8].scalar);
    try std.testing.expectEqualStrings("like", tokens.tokens[10].scalar);
    try std.testing.expectEqualStrings("adjacent", tokens.tokens[13].scalar);
}

test "scanner tokenizes adjacent flow mapping values on following lines" {
    var tokens = try scan(std.testing.allocator,
        \\---
        \\{ "foo"
        \\  :bar }
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .indent,
        .flow_mapping_start,
        .scalar,
        .indent,
        .flow_mapping_value,
        .scalar,
        .flow_mapping_end,
        .stream_end,
    });
    try std.testing.expectEqualStrings("\"foo\"", tokens.tokens[4].scalar);
    try std.testing.expectEqualStrings("bar", tokens.tokens[7].scalar);
}

test "scanner tokenizes block mapping values after flow collection keys" {
    var tokens = try scan(std.testing.allocator,
        \\outer:
        \\  [a, b]: value
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .block_mapping_value,
        .indent,
        .flow_sequence_start,
        .scalar,
        .flow_entry,
        .scalar,
        .flow_sequence_end,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });
}

test "scanner rejects unclosed flow collections at end of input" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "[unterminated\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "{unterminated\n"));
}

test "scanner tokenizes directive-looking content outside a document prefix as scalar text" {
    var content = try scan(std.testing.allocator,
        \\key: value
        \\%YAML 1.2
        \\
    );
    defer content.deinit();

    try expectTokenKindNames(content.tokens, &.{
        "stream_start",
        "indent",
        "scalar",
        "block_mapping_value",
        "scalar",
        "indent",
        "scalar",
        "scalar",
        "stream_end",
    });
    try std.testing.expectEqualStrings("%YAML", content.tokens[6].scalar);

    var next_document = try scan(std.testing.allocator,
        \\--- first
        \\...
        \\%YAML 1.2
        \\--- second
        \\
    );
    defer next_document.deinit();

    try expectTokenKinds(next_document.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .scalar,
        .document_end,
        .directive,
        .document_start,
        .document_start_content,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("%YAML 1.2", next_document.tokens[5].directive);
    try std.testing.expect(!next_document.tokens[2].document_start_content.separated_by_tab);
    try std.testing.expect(!next_document.tokens[7].document_start_content.separated_by_tab);
}
