//! Purpose: Shared setup for scanner regression test shards.
//! Owns: Common scanner imports and token-kind assertion helpers.
//! Does not own: Scanner behavior assertions.
//! Depends on: public yaml scanner namespace.
//! Tested by: tests/unit/scanner/scanner_test.zig.

pub const std = @import("std");
pub const yaml = @import("yaml");
pub const scanner = yaml.scanner;

pub const BlockScalarChomping = scanner.BlockScalarChomping;
pub const BlockScalarStyle = scanner.BlockScalarStyle;
pub const Token = scanner.Token;
pub const scan = scanner.scan;

pub fn expectTokenKinds(tokens: []const Token, expected: []const std.meta.Tag(Token)) !void {
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |expected_tag, token| {
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(token));
    }
}

pub fn expectTokenKindNames(tokens: []const Token, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |expected_name, token| {
        try std.testing.expectEqualStrings(expected_name, @tagName(std.meta.activeTag(token)));
    }
}
