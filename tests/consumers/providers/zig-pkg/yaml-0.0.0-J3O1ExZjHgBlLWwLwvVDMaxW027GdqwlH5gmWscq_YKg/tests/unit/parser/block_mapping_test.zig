//! Purpose: Verify block mapping parser token behavior.
//! Owns: Consolidated block mapping parser token regression coverage.
//! Does not own: Shared parser test helpers or conformance harness behavior.
//! Depends on: support.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig.

const support = @import("support.zig");

const std = support.std;
const parser = support.event_parser.parser;
const scanner = support.scanner;
const parseTokens = support.parseTokens;
const ParseError = support.ParseError;
const types = support.types;
const Token = parser.scanner.Token;
const expectInvalidSyntaxFromScanOrParse = support.expectInvalidSyntaxFromScanOrParse;

test "parseTokens parses a block mapping of plain scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\foo: bar
        \\baz: qux
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("qux", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens folds plain scalar token runs in block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator, "escaped slash: \"a\\/b\"\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("escaped slash", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a/b", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? key
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses omitted explicit block mapping keys and values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\: value
        \\? key
        \\:
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses explicit block mapping keys with omitted values before anchored keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\a: 1
        \\? b
        \\&anchor c: 3
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("1", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("anchor", event_stream.events[7].scalar.anchor.?);
    try std.testing.expectEqualStrings("c", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("3", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses separated property-only explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  &key !<tag:example.com,2000:key>
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses property-only implicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\&key !<tag:example.com,2000:key> : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented scalar explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  name
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses separated scalar properties in explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? &key !<tag:example.com,2000:key>
        \\  name
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("name", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented scalar explicit block mapping keys with separated property lines" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  &key
        \\  !<tag:example.com,2000:key>
        \\  name
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("name", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}
test "parseTokens parses indented flow mapping explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  {nested: key}
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses multiline flow sequence explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  [
        \\    a,
        \\    b
        \\  ]
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses indented alias explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  *anchor
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].alias);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects separated properties before alias explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  &key
        \\  *anchor
        \\: value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects explicit block mapping alias keys with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? *anchor
        \\  trailing
        \\: value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects indented explicit block mapping alias keys with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  *anchor
        \\    trailing
        \\: value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses separated flow mapping properties in explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? &key !<tag:example.com,2000:key>
        \\  {nested: key}
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expectEqualStrings("key", event_stream.events[3].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses commented indented flow mapping explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  # key comment
        \\  {nested: key}
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses explicit block mapping multiline plain scalar keys and values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? a
        \\  true
        \\: null
        \\  d
        \\? e
        \\  42
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("a true", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("null d", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("e 42", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses explicit block mapping value indicators after comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\? key
        \\# comment
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses nested explicit block mapping multiline plain scalar keys and values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ? a
        \\    true
        \\  : null
        \\    d
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a true", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("null d", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}
test "parseTokens parses explicit block mapping values with compact sequences" {
    var token_stream = try scanner.scan(std.testing.allocator, "? a\n" ++
        ": -\tb\n" ++
        "  -  -\tc\n" ++
        "     - d\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("c", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("d", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
}

test "parseTokens parses compact sequence item collections in block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\root:
        \\  - ? explicit
        \\    : value
        \\  - child: scalar
        \\  - - nested
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 20), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("root", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("explicit", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("child", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("scalar", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .sequence_start);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .sequence_end);
    try std.testing.expect(event_stream.events[16] == .sequence_end);
    try std.testing.expect(event_stream.events[17] == .mapping_end);
    try std.testing.expect(event_stream.events[18] == .document_end);
    try std.testing.expect(event_stream.events[19] == .stream_end);
}

test "parser helpers parse compact explicit mapping as block mapping value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = [_]Token{
        .block_mapping_key,
        .{ .scalar = "explicit" },
        .block_mapping_value,
        .{ .scalar = "value" },
        .stream_end,
    };

    var index: usize = 0;
    const node = try parser.parsePlainBlockMappingValueNode(
        arena.allocator(),
        &tokens,
        &index,
        contentEnd(&tokens),
        0,
        0,
        .{},
        .{},
        0,
        false,
    );

    try std.testing.expect(node == .mapping);
    try std.testing.expectEqual(@as(usize, 4), index);
    try std.testing.expectEqual(@as(usize, 1), node.mapping.pairs.len);
    try std.testing.expect(node.mapping.pairs[0].key == .mapping);
    try std.testing.expectEqual(@as(usize, 1), node.mapping.pairs[0].key.mapping.pairs.len);
    try std.testing.expectEqualStrings("explicit", node.mapping.pairs[0].key.mapping.pairs[0].key.scalar.value);
    try std.testing.expectEqualStrings("value", node.mapping.pairs[0].key.mapping.pairs[0].value.scalar.value);
    try std.testing.expectEqualStrings("", node.mapping.pairs[0].value.scalar.value);
}

test "parseTokens rejects compact mappings inside plain single-line values" {
    try expectInvalidSyntaxFromScanOrParse("a: b: c: d\n");
}

fn contentEnd(tokens: []const Token) usize {
    if (tokens.len > 0 and tokens[tokens.len - 1] == .stream_end) return tokens.len - 1;
    return tokens.len;
}

test "parseTokens parses tab separation around block mapping value indicators" {
    var token_stream = try scanner.scan(std.testing.allocator, "key\t: value\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);

    var value_token_stream = try scanner.scan(std.testing.allocator, "other:\titem\n");
    defer value_token_stream.deinit();

    var value_event_stream = try parseTokens(std.testing.allocator, value_token_stream.tokens);
    defer value_event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), value_event_stream.events.len);
    try std.testing.expect(value_event_stream.events[2] == .mapping_start);
    try std.testing.expect(value_event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("other", value_event_stream.events[3].scalar.value);
    try std.testing.expect(value_event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("item", value_event_stream.events[4].scalar.value);
    try std.testing.expect(value_event_stream.events[5] == .mapping_end);
    try std.testing.expect(value_event_stream.events[6] == .document_end);
    try std.testing.expect(value_event_stream.events[7] == .stream_end);
}

test "parseTokens parses block mapping with quoted scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\"key\n": 'value'
        \\'other': "line\n"
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[5].scalar.style);
    try std.testing.expectEqualStrings("other", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("line\n", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses multiline quoted block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\double: "line
        \\  # not a comment"
        \\single: 'line
        \\  # not a comment'
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("double", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("line # not a comment", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("single", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("line # not a comment", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses block mapping entries with scalar node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\&key !<tag:example.com,2000:key> name: &value !!str Bob
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("name", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("Bob", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented block mapping scalar values with node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\!<tag:yaml.org,2002:str> foo :
        \\  !<!bar> baz
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("!bar", event_stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("baz", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses top-level block mapping node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\!<tag:example.com,2000:map> &map
        \\foo: bar
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("map", event_stream.events[2].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", event_stream.events[2].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented top-level block mappings with node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\  !!str a: b
        \\  c: !!int 42
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("a", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("c", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:int", event_stream.events[6].scalar.tag.?);
    try std.testing.expectEqualStrings("42", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses aliases in block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\source: &item one
        \\ref: *item
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("source", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("item", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("ref", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .alias);
    try std.testing.expectEqualStrings("item", event_stream.events[6].alias);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact block sequence values with omitted items" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key: -
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens rejects block mapping value aliases with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\ref: *item
        \\  trailing
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects omitted-key block mapping value aliases with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\: *item
        \\  trailing
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses block mapping value comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\hr:  65    # Home runs
        \\avg: 0.278 # Batting average
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("hr", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("65", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("avg", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("0.278", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens folds plain scalar continuations in block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\plain: a
        \\ b
        \\
        \\ c
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a b\nc", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens folds property-looking plain scalar continuations in block nodes" {
    var mapping_tokens = try scanner.scan(std.testing.allocator,
        \\key: start
        \\ !still-scalar
        \\
    );
    defer mapping_tokens.deinit();

    var mapping_events = try parseTokens(std.testing.allocator, mapping_tokens.tokens);
    defer mapping_events.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_events.events.len);
    try std.testing.expect(mapping_events.events[2] == .mapping_start);
    try std.testing.expect(mapping_events.events[4] == .scalar);
    try std.testing.expectEqualStrings("start !still-scalar", mapping_events.events[4].scalar.value);

    var sequence_tokens = try scanner.scan(std.testing.allocator,
        \\- start
        \\ !still-scalar
        \\
    );
    defer sequence_tokens.deinit();

    var sequence_events = try parseTokens(std.testing.allocator, sequence_tokens.tokens);
    defer sequence_events.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_events.events.len);
    try std.testing.expect(sequence_events.events[2] == .sequence_start);
    try std.testing.expect(sequence_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("start !still-scalar", sequence_events.events[3].scalar.value);
}

test "parseTokens folds dash-started plain scalar continuations in block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\plain: first line
        \\  - still scalar text
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("first line - still scalar text", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}
test "parseTokens parses block mapping omitted values as empty scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\foo:
        \\bar: baz
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses block mapping property-only values as empty scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\foo:
        \\  &value !<tag:example.com,2000:value>
        \\bar: baz
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:value", event_stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses separated properties before indented block mapping scalar values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\foo:
        \\  &value
        \\  !<tag:example.com,2000:value>
        \\  one
        \\bar: two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:value", event_stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses multiline flow sequence block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key:
        \\  [
        \\    a,
        \\    b
        \\  ]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses multiline flow mapping block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key:
        \\  {
        \\    name: Bob,
        \\    age: 42
        \\  }
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].mapping_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("age", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("42", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses multiline flow sequence block sequence items" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  [
        \\    a,
        \\    b
        \\  ]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses commented indented flow mapping block sequence items" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  # item comment
        \\  {
        \\    name: Bob,
        \\    age: 42
        \\  }
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("age", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("42", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses block mappings with omitted implicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\: a
        \\: b
        \\:
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses block mapping values with block scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\literal: |
        \\  line one
        \\  line two
        \\folded: >
        \\  line one
        \\  line two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("literal", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("line one\nline two\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("folded", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("line one line two\n", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses separated tag properties before block scalar mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\literal: |2
        \\  value
        \\folded:
        \\   !foo
        \\  >1
        \\ value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("literal", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("value\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("folded", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("!foo", event_stream.events[6].scalar.tag.?);
    try std.testing.expectEqualStrings("value\n", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses indentless block sequence values in block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\one:
        \\- 2
        \\- 3
        \\four: 5
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("2", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("3", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("four", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("5", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}
test "parseTokens parses indentless sequence after separate anchor property line" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\seq:
        \\ &anchor
        \\- a
        \\- b
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("seq", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("anchor", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses block mapping values with nested block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\items:
        \\  - one
        \\  - two
        \\name: Bob
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses nested block mappings with omitted implicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
}

test "parseTokens parses nested block sequence value properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\items:
        \\  &items !<tag:example.com,2000:items>
        \\  - one
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("items", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", event_stream.events[4].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses nested block mapping value properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\person:
        \\  &person !<tag:example.com,2000:person>
        \\  name: Bob
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("person", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("person", event_stream.events[4].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:person", event_stream.events[4].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses nested explicit block mapping block scalar keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ? |
        \\    key
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key\n", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
}

test "parseTokens parses nested explicit block mapping alias keys and values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\anchor: &v value
        \\outer:
        \\  ? *v
        \\  : *v
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("v", event_stream.events[4].scalar.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_start);
    try std.testing.expect(event_stream.events[7] == .alias);
    try std.testing.expectEqualStrings("v", event_stream.events[7].alias);
    try std.testing.expect(event_stream.events[8] == .alias);
    try std.testing.expectEqualStrings("v", event_stream.events[8].alias);
}

test "parseTokens parses nested explicit block mapping keys with omitted values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ? key
        \\  next: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("next", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[8].scalar.value);
}

test "parseTokens rejects invalid multiline implicit flow keys in nested block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  [a,
        \\   b]: value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses split node properties before nested block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key: &anchor
        \\ !!map
        \\  a: b
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("anchor", event_stream.events[4].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[4].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}
test "parseTokens parses nested sequence values after separated properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  key:
        \\    &items !<tag:example.com,2000:items>
        \\    - one
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("items", event_stream.events[6].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", event_stream.events[6].sequence_start.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expectEqualStrings("tail", event_stream.events[10].scalar.value);
    try std.testing.expectEqualStrings("done", event_stream.events[11].scalar.value);
}

test "parseTokens parses nested mapping values after separated properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  key:
        \\    &person !<tag:example.com,2000:person>
        \\    name: Bob
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[6].mapping_start.style);
    try std.testing.expectEqualStrings("person", event_stream.events[6].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:person", event_stream.events[6].mapping_start.tag.?);
    try std.testing.expectEqualStrings("name", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("Bob", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expectEqualStrings("tail", event_stream.events[11].scalar.value);
    try std.testing.expectEqualStrings("done", event_stream.events[12].scalar.value);
}
test "parseTokens parses indented flow sequence values after separated properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  key:
        \\    &items !<tag:example.com,2000:items>
        \\    [one, two]
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("items", event_stream.events[6].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", event_stream.events[6].sequence_start.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("two", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expectEqualStrings("tail", event_stream.events[11].scalar.value);
    try std.testing.expectEqualStrings("done", event_stream.events[12].scalar.value);
}

test "parseTokens parses indented flow mapping values after separated properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  key:
        \\    &person !<tag:example.com,2000:person>
        \\    {name: Bob}
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[6].mapping_start.style);
    try std.testing.expectEqualStrings("person", event_stream.events[6].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:person", event_stream.events[6].mapping_start.tag.?);
    try std.testing.expectEqualStrings("name", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("Bob", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expectEqualStrings("tail", event_stream.events[11].scalar.value);
    try std.testing.expectEqualStrings("done", event_stream.events[12].scalar.value);
}
fn parse(input: []const u8) !types.EventStream {
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    return parseTokens(std.testing.allocator, token_stream.tokens);
}

test "parseTokens parses nested implicit flow collection mapping keys" {
    var event_stream = try parse(
        \\outer:
        \\  [a, b]: value
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[5].sequence_start.style);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
}

test "parseTokens parses nested explicit block mapping values as flow sequences" {
    var event_stream = try parse(
        \\outer:
        \\  ? key
        \\  : [a, b]
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("a", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("b", event_stream.events[8].scalar.value);
}

test "parseTokens parses nested explicit block mapping values as block sequences" {
    var event_stream = try parse(
        \\outer:
        \\  ? key
        \\  :
        \\    - item
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("item", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
}

test "parseTokens parses nested explicit block mapping values as block mappings" {
    var event_stream = try parse(
        \\outer:
        \\  ? key
        \\  :
        \\    inner: value
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_start);
    try std.testing.expectEqualStrings("inner", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
}
test "parseTokens parses split node properties before nested block mapping explicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? &anchor
        \\  !!map
        \\  a: b
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].mapping_start.style);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[3].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses split node properties before nested explicit key block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ? &anchor
        \\    !!map
        \\    a: b
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[5].mapping_start.style);
    try std.testing.expectEqualStrings("anchor", event_stream.events[5].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[5].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses block mapping values with nested block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\person:
        \\  name: Bob
        \\  age: 42
        \\active: true
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("person", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].mapping_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("age", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("42", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("active", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("true", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .document_end);
    try std.testing.expect(event_stream.events[14] == .stream_end);
}

test "parseTokens parses nested block mappings with explicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\root:
        \\  ? key
        \\  : value
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("root", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses nested explicit block mapping keys with omitted values before anchored keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\root:
        \\  ? b
        \\  &anchor c: 3
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("root", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("anchor", event_stream.events[7].scalar.anchor.?);
    try std.testing.expectEqualStrings("c", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("3", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .document_end);
    try std.testing.expect(event_stream.events[14] == .stream_end);
}

test "parseTokens parses explicit mapping entries between sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? - Detroit Tigers
        \\  - Chicago cubs
        \\:
        \\  - 2001-07-23
        \\
        \\? [ New York Yankees,
        \\    Atlanta Braves ]
        \\: [ 2001-07-02, 2001-08-12,
        \\    2001-08-14 ]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 22), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("Detroit Tigers", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("Chicago cubs", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[7].sequence_start.style);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("2001-07-23", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[10].sequence_start.style);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("New York Yankees", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("Atlanta Braves", event_stream.events[12].scalar.value);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
    try std.testing.expect(event_stream.events[14] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[14].sequence_start.style);
    try std.testing.expect(event_stream.events[15] == .scalar);
    try std.testing.expectEqualStrings("2001-07-02", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .scalar);
    try std.testing.expectEqualStrings("2001-08-12", event_stream.events[16].scalar.value);
    try std.testing.expect(event_stream.events[17] == .scalar);
    try std.testing.expectEqualStrings("2001-08-14", event_stream.events[17].scalar.value);
    try std.testing.expect(event_stream.events[18] == .sequence_end);
    try std.testing.expect(event_stream.events[19] == .mapping_end);
    try std.testing.expect(event_stream.events[20] == .document_end);
    try std.testing.expect(event_stream.events[21] == .stream_end);
}

test "parseTokens parses compact explicit mapping keys in block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator, "? []: x\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("x", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
}

test "parseTokens parses zero-indented sequences in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\?
        \\- a
        \\- b
        \\:
        \\- c
        \\- d
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .sequence_start);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("c", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("d", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
}

test "parseTokens parses block scalar explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? >
        \\  folded
        \\:
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("folded\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
}

test "parseTokens parses indented block scalar explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  >
        \\    folded
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("folded\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses separated block scalar properties in explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  &key
        \\  !<tag:example.com,2000:key>
        \\  |
        \\    literal key
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("literal key\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses nested sequences in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\  - a
        \\  :
        \\  - b
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .sequence_start);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
}

test "parseTokens parses indented block sequences in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  - a
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses nested indented block sequences in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    - a
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses block mappings in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\?
        \\  a: b
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses nested block mappings in explicit mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    a: b
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses nested indented scalar explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    scalar key
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("scalar key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses nested indented block scalar explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    |
        \\      literal key
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[5].scalar.style);
    try std.testing.expectEqualStrings("literal key\n", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses nested indented flow explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    {a: b}
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[5].mapping_start.style);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses nested multiline flow sequence explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    [
        \\      a,
        \\      b
        \\    ]
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[5].sequence_start.style);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses nested indented alias explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    *key
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .alias);
    try std.testing.expectEqualStrings("key", event_stream.events[5].alias);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses nested separated property-only explicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  ?
        \\    &key !<tag:example.com,2000:key>
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", event_stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}
