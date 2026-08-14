//! Purpose: Shared setup for parser token regression tests.
//! Owns: Common imports and small helpers used by parser token tests.
//! Does not own: Parser behavior assertions.
//! Depends on: yaml_event_parser test import.
//! Tested by: tests/unit/parser/parser_tokens_test.zig.

pub const std = @import("std");
pub const event_parser = @import("yaml_event_parser");

pub const scanner = event_parser.scanner;
pub const parseTokens = event_parser.parseTokens;
pub const ParseError = event_parser.types.ParseError;
pub const types = event_parser.types;

pub fn expectInvalidSyntaxFromScanOrParse(input: []const u8) !void {
    var token_stream = scanner.scan(std.testing.allocator, input) catch |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
        return;
    };
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}
