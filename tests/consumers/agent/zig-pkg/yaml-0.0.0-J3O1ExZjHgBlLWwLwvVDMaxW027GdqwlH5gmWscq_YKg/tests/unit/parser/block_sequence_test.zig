//! Purpose: Verify block sequence parser token behavior.
//! Owns: Consolidated block sequence parser token regression coverage.
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

test "parseTokens parses a block sequence of plain scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- one
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses tab separation after block sequence indicators" {
    var token_stream = try scanner.scan(std.testing.allocator, "-\tone\n-\ttwo\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens folds plain scalar continuations in block sequence entries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- single multiline
        \\ - sequence entry
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 7), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("single multiline - sequence entry", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_end);
    try std.testing.expect(event_stream.events[5] == .document_end);
    try std.testing.expect(event_stream.events[6] == .stream_end);
}

test "parseTokens parses block sequence item comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- one # first
        \\- two # second
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses block sequence omitted values as empty scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses block sequence property-only items as empty scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  &item !<tag:example.com,2000:item>
        \\- next
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("item", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("next", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses block sequence with quoted scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- 'it''s'
        \\- "tab\t"
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("it's", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("tab\t", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses multiline quoted block sequence scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- "line
        \\  # not a comment"
        \\- 'line
        \\  # not a comment'
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("line # not a comment", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("line # not a comment", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects multiline quoted compact mapping keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- "line
        \\  key": value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses block sequence entries with indented block nodes" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  "flow in block"
        \\- >
        \\ Block scalar
        \\- !!map # Block collection
        \\  foo : bar
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("flow in block", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("Block scalar\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[5].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses block sequence entries with indented flow nodes" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  [one, two]
        \\-
        \\  {key: value}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[7].mapping_start.style);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses block sequence entries with block scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- |
        \\  literal
        \\  text
        \\- >
        \\  folded
        \\  text
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("literal\ntext\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("folded text\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens marks explicit block sequence document ends" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- one
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 7), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_end);
    try std.testing.expect(event_stream.events[5] == .document_end);
    try std.testing.expect(event_stream.events[5].document_end.explicit);
    try std.testing.expect(event_stream.events[6] == .stream_end);
}

test "parseTokens parses block sequence entries with scalar node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- &first !<tag:example.com,2000:item> one
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("first", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented block sequence entries with scalar node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  &first !<tag:example.com,2000:item> one
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("first", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses separated properties before indented block sequence scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  &first
        \\  !<tag:example.com,2000:item>
        \\  one
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("first", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects scalar content adjacent to sequence item properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- !!str, xxx
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses alias nodes in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- &item one
        \\- *item
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("item", event_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .alias);
    try std.testing.expectEqualStrings("item", event_stream.events[4].alias);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses top-level block sequence node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\&seq !<tag:example.com,2000:seq>
        \\- one
        \\- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("seq", event_stream.events[2].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", event_stream.events[2].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses indented top-level block sequences with node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\ - !!str a
        \\ - b
        \\ - !!int 42
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("a", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:int", event_stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("42", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .document_end);
    try std.testing.expect(event_stream.events[8] == .stream_end);
}

test "parseTokens parses block sequence entries with compact block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- name: Mark
        \\  hr: 65
        \\- name: Sammy
        \\  hr: 63
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 18), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("Mark", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("hr", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("65", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("Sammy", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("hr", event_stream.events[12].scalar.value);
    try std.testing.expect(event_stream.events[13] == .scalar);
    try std.testing.expectEqualStrings("63", event_stream.events[13].scalar.value);
    try std.testing.expect(event_stream.events[14] == .mapping_end);
}

test "parseTokens rejects node properties on compact nested collections" {
    var sequence_tokens = try scanner.scan(std.testing.allocator,
        \\- &items - one
        \\
    );
    defer sequence_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, sequence_tokens.tokens));

    var value_tokens = try scanner.scan(std.testing.allocator,
        \\? key
        \\: !tag - value
        \\
    );
    defer value_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, value_tokens.tokens));

    var explicit_mapping_tokens = try scanner.scan(std.testing.allocator,
        \\- &item ? key
        \\  : value
        \\
    );
    defer explicit_mapping_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, explicit_mapping_tokens.tokens));
}

test "parseTokens parses node properties on compact block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- &key key: value
        \\- !tag : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("!tag", event_stream.events[8].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses compact block mappings with omitted implicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- :
        \\- : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses later compact mapping entries with omitted implicit keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- first: one
        \\  : two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("first", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens preserves node properties on empty block scalar nodes" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- !!str
        \\- &anchor
        \\-
        \\  !!null : a
        \\  b: !!str
        \\- !!str : !!null
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 18), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("anchor", event_stream.events[4].scalar.anchor.?);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:null", event_stream.events[6].scalar.tag.?);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[9].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[9].scalar.tag.?);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_start);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[12].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[12].scalar.tag.?);
    try std.testing.expect(event_stream.events[13] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[13].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:null", event_stream.events[13].scalar.tag.?);
    try std.testing.expect(event_stream.events[14] == .mapping_end);
    try std.testing.expect(event_stream.events[15] == .sequence_end);
    try std.testing.expect(event_stream.events[16] == .document_end);
    try std.testing.expect(event_stream.events[17] == .stream_end);
}

test "parseTokens folds plain scalar continuations in compact block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- name: Mark
        \\  note: a
        \\    b
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("Mark", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("note", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("a b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens folds dash-started plain scalar continuations in compact block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- note: first line
        \\    - still scalar text
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("note", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("first line - still scalar text", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping keys in block sequence entries" {
    var token_stream = try scanner.scan(std.testing.allocator, "- ? : x\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("x", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
}

test "parseTokens parses compact explicit mapping entries with omitted keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with following-line values in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? [key]
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens folds compact explicit mapping multiline scalar keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? multi
        \\    line
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("multi line", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens folds compact explicit mapping multiline quoted scalar keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? 'multi
        \\    line'
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("multi line", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens rejects compact explicit mapping multiline scalar keys with same-line values" {
    var plain_token_stream = try scanner.scan(std.testing.allocator,
        \\- ? multi
        \\    line: value
        \\
    );
    defer plain_token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, plain_token_stream.tokens));

    var quoted_token_stream = try scanner.scan(std.testing.allocator,
        \\- ? 'multi
        \\    line': value
        \\
    );
    defer quoted_token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, quoted_token_stream.tokens));
}

test "parseTokens rejects compact explicit mapping multiline flow keys with same-line values" {
    var sequence_token_stream = try scanner.scan(std.testing.allocator,
        \\- ? [multi,
        \\    line]: value
        \\
    );
    defer sequence_token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, sequence_token_stream.tokens));

    var mapping_token_stream = try scanner.scan(std.testing.allocator,
        \\- ? {multi:
        \\    line}: value
        \\
    );
    defer mapping_token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, mapping_token_stream.tokens));
}

test "parseTokens parses compact explicit mapping entries with comments before following-line values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? key
        \\  # key comment
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with nested mapping keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\    key: nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with nested sequence keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\    - nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with separated property nested sequence keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\    - nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("key", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with commented separated property nested flow mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\  # key node comment
        \\    {nested: key}
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("key", event_stream.events[4].mapping_start.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with commented separated property nested sequence keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\  # key node comment
        \\    - nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("key", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with split property nested sequence keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\  !<tag:example.com,2000:seq>
        \\    - nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("key", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", event_stream.events[4].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with separated property nested flow sequence keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\    [nested]
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("key", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with separated property indented scalar keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\  &key
        \\    nested
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with indented scalar keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ?
        \\    key
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with block scalar keys in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? >
        \\    folded
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("folded\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit block scalar keys with indentation indicators" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- ? >2
        \\    folded
        \\  : value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("folded\n", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses compact explicit mapping entries with compact mapping nodes" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- sun: yellow
        \\- ? earth: blue
        \\  : moon: white
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 20), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("sun", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("yellow", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("earth", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("blue", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .mapping_start);
    try std.testing.expect(event_stream.events[13] == .scalar);
    try std.testing.expectEqualStrings("moon", event_stream.events[13].scalar.value);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("white", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .mapping_end);
    try std.testing.expect(event_stream.events[16] == .mapping_end);
    try std.testing.expect(event_stream.events[17] == .sequence_end);
    try std.testing.expect(event_stream.events[18] == .document_end);
    try std.testing.expect(event_stream.events[19] == .stream_end);
}

test "parseTokens parses block sequence compact mappings with following pairs" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\Stack:
        \\  - file: TopClass.py
        \\    line: 23
        \\    code: |
        \\      x = MoreObject("345\n")
        \\  - file: MoreClass.py
        \\    line: 58
        \\    code: |-
        \\      foo = bar
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 25), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("Stack", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("file", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("TopClass.py", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("line", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("23", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("code", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[11].scalar.style);
    try std.testing.expectEqualStrings("x = MoreObject(\"345\\n\")\n", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .mapping_start);
    try std.testing.expect(event_stream.events[19] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[19].scalar.style);
    try std.testing.expectEqualStrings("foo = bar", event_stream.events[19].scalar.value);
    try std.testing.expect(event_stream.events[20] == .mapping_end);
    try std.testing.expect(event_stream.events[21] == .sequence_end);
    try std.testing.expect(event_stream.events[22] == .mapping_end);
    try std.testing.expect(event_stream.events[23] == .document_end);
    try std.testing.expect(event_stream.events[24] == .stream_end);
}

test "parseTokens parses multi-document log stream with compact mapping sequence entries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\Time: 2001-11-23 15:01:42 -5
        \\User: ed
        \\Warning:
        \\  This is an error message
        \\  for the log file
        \\---
        \\Time: 2001-11-23 15:02:31 -5
        \\User: ed
        \\Warning:
        \\  A slightly different error
        \\  message.
        \\---
        \\Date: 2001-11-23 15:03:17 -5
        \\User: ed
        \\Fatal:
        \\  Unknown variable "bar"
        \\Stack:
        \\  - file: TopClass.py
        \\    line: 23
        \\    code: |
        \\      x = MoreObject("345\n")
        \\  - file: MoreClass.py
        \\    line: 58
        \\    code: |-
        \\      foo = bar
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 51), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("This is an error message for the log file", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[11] == .document_start);
    try std.testing.expect(event_stream.events[18] == .scalar);
    try std.testing.expectEqualStrings("A slightly different error message.", event_stream.events[18].scalar.value);
    try std.testing.expect(event_stream.events[21] == .document_start);
    try std.testing.expect(event_stream.events[29] == .scalar);
    try std.testing.expectEqualStrings("Stack", event_stream.events[29].scalar.value);
    try std.testing.expect(event_stream.events[30] == .sequence_start);
    try std.testing.expect(event_stream.events[31] == .mapping_start);
    try std.testing.expect(event_stream.events[37] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[37].scalar.style);
    try std.testing.expectEqualStrings("x = MoreObject(\"345\\n\")\n", event_stream.events[37].scalar.value);
    try std.testing.expect(event_stream.events[45] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[45].scalar.style);
    try std.testing.expectEqualStrings("foo = bar", event_stream.events[45].scalar.value);
    try std.testing.expect(event_stream.events[46] == .mapping_end);
    try std.testing.expect(event_stream.events[47] == .sequence_end);
    try std.testing.expect(event_stream.events[48] == .mapping_end);
    try std.testing.expect(event_stream.events[49] == .document_end);
    try std.testing.expect(event_stream.events[50] == .stream_end);
}

test "parser helpers: compact sequence resets when first item is invalid" {
    const tokens = [_]Token{
        .block_sequence_entry,
        .flow_sequence_end,
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var index: usize = 0;
    const node = try parser.parseCompactPlainBlockSequenceNode(
        arena.allocator(),
        &tokens,
        &index,
        contentEnd(&tokens),
        0,
        .{},
        .{},
        0,
    );

    try std.testing.expect(node == null);
    try std.testing.expectEqual(@as(usize, 0), index);
}

test "parser helpers: indented sequence item resets on bare sequence indicator scalar" {
    const tokens = [_]Token{
        .{ .indent = 2 },
        .{ .scalar = "-" },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var index: usize = 0;
    const node = try parser.parseIndentedPlainBlockSequenceItemNode(
        arena.allocator(),
        &tokens,
        &index,
        contentEnd(&tokens),
        0,
        .{},
        .{},
    );

    try std.testing.expectEqual(@as(?parser.PlainBlockNode, null), node);
    try std.testing.expectEqual(@as(usize, 0), index);
}

fn contentEnd(tokens: []const Token) usize {
    if (tokens.len > 0 and tokens[tokens.len - 1] == .stream_end) return tokens.len - 1;
    return tokens.len;
}

fn parse(input: []const u8) !types.EventStream {
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();
    return try parseTokens(std.testing.allocator, token_stream.tokens);
}

test "parseTokens parses indentless sequence compact mapping variants" {
    var event_stream = try parse(
        \\items:
        \\- key: value
        \\- ? explicit
        \\  : entry
        \\tail: done
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 19), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("explicit", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("entry", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .mapping_end);
}

test "parseTokens parses indentless sequence scalar, alias, and flow variants" {
    var event_stream = try parse(
        \\anchor: &a value
        \\items:
        \\- "quoted"
        \\- |
        \\  literal
        \\- *a
        \\- [flow]
        \\tail: done
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 19), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[7].scalar.style);
    try std.testing.expectEqualStrings("quoted", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[8].scalar.style);
    try std.testing.expectEqualStrings("literal\n", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .alias);
    try std.testing.expectEqualStrings("a", event_stream.events[9].alias);
    try std.testing.expect(event_stream.events[10] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[10].sequence_start.style);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("flow", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .sequence_end);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
}

test "parseTokens parses indentless sequence nested collection variants" {
    var event_stream = try parse(
        \\items:
        \\-
        \\  - nested
        \\-
        \\  name: nested mapping
        \\- &empty
        \\tail: done
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 19), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("nested mapping", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("empty", event_stream.events[12].scalar.anchor.?);
    try std.testing.expectEqualStrings("", event_stream.events[12].scalar.value);
}

test "parseTokens rejects indentless sequence alias items with node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\anchor: &a value
        \\items:
        \\- &bad *a
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens folds plain scalar continuations in nested block mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  inner: a
        \\    b
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
    try std.testing.expectEqualStrings("inner", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("a b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses block sequence entries with nested block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  - one
        \\  - two
        \\- three
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("three", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses block sequence entries with nested block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  name: Bob
        \\  age: 42
        \\- active
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("age", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("42", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("active", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses block sequence entries with nested block sequence value properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  &items !<tag:example.com,2000:items>
        \\  - one
        \\- done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].sequence_start.style);
    try std.testing.expectEqualStrings("items", event_stream.events[3].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", event_stream.events[3].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses nested block sequence item mapping value properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\items:
        \\  -
        \\    &person !<tag:example.com,2000:person>
        \\    name: Bob
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[5].mapping_start.style);
    try std.testing.expectEqualStrings("person", event_stream.events[5].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:person", event_stream.events[5].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .document_end);
    try std.testing.expect(event_stream.events[14] == .stream_end);
}

test "parseTokens parses recursive block sequence descendants" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\-
        \\  -
        \\    - one
        \\    - two
        \\- done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses flow collection entries in block sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- [one, two]
        \\- {name: Bob}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[7].mapping_start.style);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens parses nested block sequence item variants in mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\anchor: &a anchored
        \\items:
        \\  - "quoted"
        \\  - |
        \\    literal
        \\  - *a
        \\  - [flow]
        \\  - key: value
        \\  - ? explicit
        \\    : entry
        \\  -
        \\  -
        \\    nested
        \\tail: done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 29), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("anchored", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[6].sequence_start.style);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[7].scalar.style);
    try std.testing.expectEqualStrings("quoted", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[8].scalar.style);
    try std.testing.expectEqualStrings("literal\n", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .alias);
    try std.testing.expectEqualStrings("a", event_stream.events[9].alias);
    try std.testing.expect(event_stream.events[10] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[10].sequence_start.style);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("flow", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .sequence_end);
    try std.testing.expect(event_stream.events[13] == .mapping_start);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .mapping_end);
    try std.testing.expect(event_stream.events[17] == .mapping_start);
    try std.testing.expect(event_stream.events[18] == .scalar);
    try std.testing.expectEqualStrings("explicit", event_stream.events[18].scalar.value);
    try std.testing.expect(event_stream.events[19] == .scalar);
    try std.testing.expectEqualStrings("entry", event_stream.events[19].scalar.value);
    try std.testing.expect(event_stream.events[20] == .mapping_end);
    try std.testing.expect(event_stream.events[21] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[21].scalar.value);
    try std.testing.expect(event_stream.events[22] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[22].scalar.value);
    try std.testing.expect(event_stream.events[23] == .sequence_end);
    try std.testing.expect(event_stream.events[24] == .scalar);
    try std.testing.expectEqualStrings("tail", event_stream.events[24].scalar.value);
    try std.testing.expect(event_stream.events[25] == .scalar);
    try std.testing.expectEqualStrings("done", event_stream.events[25].scalar.value);
    try std.testing.expect(event_stream.events[26] == .mapping_end);
    try std.testing.expect(event_stream.events[27] == .document_end);
    try std.testing.expect(event_stream.events[28] == .stream_end);
}
