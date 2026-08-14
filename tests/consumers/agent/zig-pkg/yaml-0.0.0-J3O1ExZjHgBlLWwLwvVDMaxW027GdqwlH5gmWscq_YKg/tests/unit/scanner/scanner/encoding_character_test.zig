//! Purpose: Verify quoted/flow termination, line-break normalization, escapes, and character validation.
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

test "scanner rejects unterminated quoted and flow input" {
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "[one, two\n"));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, "\"unterminated\n"));
}

test "scanner normalizes YAML non-ASCII line separators before tokenizing" {
    var tokens = try scan(std.testing.allocator, "one\xc2\x85two\xe2\x80\xa8three\xe2\x80\xa9four\n");
    defer tokens.deinit();

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\n", tokens.source);
}

test "scanner normalizes CR and CRLF line breaks before tokenizing" {
    var tokens = try scan(std.testing.allocator, "key:\r\n  |\r\n    one\r    two\r\nnext: value\r\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .block_mapping_value,
        .indent,
        .block_scalar,
        .indent,
        .scalar,
        .block_mapping_value,
        .scalar,
        .stream_end,
    });

    try std.testing.expectEqualStrings("    one\n    two\n", tokens.tokens[5].block_scalar.content);
    try std.testing.expectEqualStrings("next", tokens.tokens[7].scalar);
}

test "scanner exposes decoded normalized UTF-8 source" {
    const input = [_]u8{
        0xff, 0xfe,
        'k',  0,
        'e',  0,
        'y',  0,
        ':',  0,
        ' ',  0,
        'v',  0,
        '\r', 0,
        '\n', 0,
    };

    var tokens = try scan(std.testing.allocator, &input);
    defer tokens.deinit();

    try std.testing.expectEqualStrings("key: v\n", tokens.source);
    try std.testing.expectEqualStrings("key", tokens.tokens[2].scalar);
    try std.testing.expectEqual(@intFromPtr(tokens.source.ptr), @intFromPtr(tokens.tokens[2].scalar.ptr));
}

test "scanner validates double quoted escape sequences and unicode escapes" {
    var tokens = try scan(std.testing.allocator,
        \\"tab\t omega \u03A9 smile \U0001F642"
        \\
    );
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("\"tab\\t omega \\u03A9 smile \\U0001F642\"", tokens.tokens[2].scalar);

    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\"bad \q"
        \\
    ));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\"bad \x0"
        \\
    ));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\"bad \uD800"
        \\
    ));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator,
        \\"bad \UFFFFFFFF"
        \\
    ));
}

test "scanner rejects raw non-printable characters" {
    const nul_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x00, '\n' };
    const bell_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x07, '\n' };
    const del_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x7f, '\n' };
    const c1_input = "bad: \xc2\x9f\n";

    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, &nul_input));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, &bell_input));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, &del_input));
    try std.testing.expectError(error.InvalidSyntax, scan(std.testing.allocator, c1_input));
}

test "scanner ignores UTF-8 BOM at stream and document prefixes" {
    var tokens = try scan(std.testing.allocator, "\xEF\xBB\xBF--- first\n" ++
        "...\n" ++
        "\xEF\xBB\xBF# prefix comment\n" ++
        "\xEF\xBB\xBF--- second\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .document_start,
        .document_start_content,
        .scalar,
        .document_end,
        .comment,
        .document_start,
        .document_start_content,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("first", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("prefix comment", tokens.tokens[5].comment);
    try std.testing.expectEqualStrings("second", tokens.tokens[8].scalar);
}
