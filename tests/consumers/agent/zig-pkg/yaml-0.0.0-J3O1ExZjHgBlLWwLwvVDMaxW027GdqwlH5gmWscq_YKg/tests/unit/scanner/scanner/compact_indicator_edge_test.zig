//! Purpose: Verify compact indicator edge cases that must remain scalar content.
//! Owns: Focused scanner regressions for context-sensitive compact indicators.
//! Does not own: General scalar scanning or parser interpretation.
//! Depends on: support.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig.

const support = @import("support.zig");

const std = support.std;
const scan = support.scan;
const expectTokenKinds = support.expectTokenKinds;

test "scanner keeps property-prefixed dash scalar outside compact collection context" {
    var tokens = try scan(std.testing.allocator, "&node - scalar\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .anchor,
        .scalar,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("node", tokens.tokens[2].anchor);
    try std.testing.expectEqualStrings("-", tokens.tokens[3].scalar);
    try std.testing.expectEqualStrings("scalar", tokens.tokens[4].scalar);
}
