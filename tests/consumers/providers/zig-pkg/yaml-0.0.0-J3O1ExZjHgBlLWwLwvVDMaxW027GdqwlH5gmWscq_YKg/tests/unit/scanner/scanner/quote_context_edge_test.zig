//! Purpose: Verify scanner quote classification edge cases.
//! Owns: Focused regressions for quoted scalars without prior scalar context.
//! Does not own: General quoted-scalar parsing or parser interpretation.
//! Depends on: support.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig.

const support = @import("support.zig");

const std = support.std;
const scan = support.scan;
const expectTokenKinds = support.expectTokenKinds;

test "scanner treats indented leading quote as a scalar start" {
    var tokens = try scan(std.testing.allocator, "  'value'\n");
    defer tokens.deinit();

    try expectTokenKinds(tokens.tokens, &.{
        .stream_start,
        .indent,
        .scalar,
        .stream_end,
    });
    try std.testing.expectEqualStrings("'value'", tokens.tokens[2].scalar);
}
