//! Purpose: Verify flow collection parser token behavior.
//! Owns: Consolidated flow parser token regression coverage.
//! Does not own: Shared parser test helpers or conformance harness behavior.
//! Depends on: support.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig.

const support = @import("support.zig");

const std = support.std;
const scanner = support.scanner;
const parser = support.event_parser.parser;
const parseTokens = support.parseTokens;
const ParseError = support.ParseError;
const types = support.types;
test "parseTokens parses a flow sequence of plain scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "[one, two]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses a nested flow sequence of plain scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "[one, [two, three]]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("three", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses a flow sequence containing a flow mapping" {
    var token_stream = try scanner.scan(std.testing.allocator, "[one, {two: three}]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].mapping_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("three", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses tab separation inside flow collections" {
    var token_stream = try scanner.scan(std.testing.allocator, "[one,\ttwo,\t{three:\tfour}]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[5].mapping_start.style);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("three", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("four", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .sequence_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses implicit single-pair flow mappings in flow sequences" {
    var token_stream = try scanner.scan(std.testing.allocator, "[YAML: separate, \"JSON like\":adjacent, {JSON: like}:adjacent]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 21), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("YAML", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("separate", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[7].mapping_start.style);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[8].scalar.style);
    try std.testing.expectEqualStrings("JSON like", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("adjacent", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[11].mapping_start.style);
    try std.testing.expect(event_stream.events[12] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[12].mapping_start.style);
    try std.testing.expect(event_stream.events[13] == .scalar);
    try std.testing.expectEqualStrings("JSON", event_stream.events[13].scalar.value);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("like", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .mapping_end);
    try std.testing.expect(event_stream.events[16] == .scalar);
    try std.testing.expectEqualStrings("adjacent", event_stream.events[16].scalar.value);
    try std.testing.expect(event_stream.events[17] == .mapping_end);
    try std.testing.expect(event_stream.events[18] == .sequence_end);
    try std.testing.expect(event_stream.events[19] == .document_end);
    try std.testing.expect(event_stream.events[20] == .stream_end);
}

test "parseTokens parses empty implicit keys in single-pair flow sequence mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- [ : empty key ]
        \\- [: another empty key]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 18), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].mapping_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("empty key", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[9].sequence_start.style);
    try std.testing.expect(event_stream.events[10] == .mapping_start);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("another empty key", event_stream.events[12].scalar.value);
    try std.testing.expect(event_stream.events[13] == .mapping_end);
    try std.testing.expect(event_stream.events[14] == .sequence_end);
    try std.testing.expect(event_stream.events[15] == .sequence_end);
    try std.testing.expect(event_stream.events[16] == .document_end);
    try std.testing.expect(event_stream.events[17] == .stream_end);
}

test "parseTokens parses explicit single-pair flow mappings in flow sequences" {
    var token_stream = try scanner.scan(std.testing.allocator, "[? a : b]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses multiline explicit flow mapping keys in flow sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\[
        \\? foo
        \\ bar : baz
        \\]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("foo bar", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses multiline implicit flow mapping values in flow sequences" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\[
        \\foo: bar
        \\ baz
        \\]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar baz", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .document_end);
    try std.testing.expect(event_stream.events[9] == .stream_end);
}

test "parseTokens parses property-only flow sequence entries as empty scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "[!!str, &anchor, *anchor]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("anchor", event_stream.events[4].scalar.anchor.?);
    try std.testing.expect(event_stream.events[5] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[5].alias);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .document_end);
    try std.testing.expect(event_stream.events[8] == .stream_end);
}
test "parseTokens preserves empty implicit flow sequence mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator, "[key:, :]");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);

    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[3].mapping_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);

    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);

    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens preserves empty explicit flow sequence mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator, "[? a, ? :]");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);

    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);

    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);

    try std.testing.expect(event_stream.events[11] == .sequence_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}
test "parseTokens parses a flow sequence with quoted scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "['it''s', \"tab\\t\"]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
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

test "parseTokens parses multiline flow sequence entries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\[
        \\"double
        \\ quoted", 'single
        \\           quoted',
        \\plain
        \\ text, [ nested ],
        \\single: pair,
        \\]
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("double quoted", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("single quoted", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("plain text", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[6].sequence_start.style);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[9].mapping_start.style);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("single", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("pair", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
    try std.testing.expect(event_stream.events[14] == .document_end);
    try std.testing.expect(event_stream.events[15] == .stream_end);
}

test "parseTokens parses alias nodes in a flow sequence" {
    var token_stream = try scanner.scan(std.testing.allocator, "[*anchor, plain]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].alias);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects flow aliases with following content" {
    var sequence_tokens = try scanner.scan(std.testing.allocator, "[*anchor trailing]\n");
    defer sequence_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, sequence_tokens.tokens));

    var mapping_tokens = try scanner.scan(std.testing.allocator, "{ref: *anchor trailing}\n");
    defer mapping_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, mapping_tokens.tokens));
}

test "parseTokens parses tagged scalar nodes in a flow sequence" {
    var token_stream = try scanner.scan(std.testing.allocator, "[!<tag:example.com,2000:item> one]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 7), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", event_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_end);
    try std.testing.expect(event_stream.events[5] == .document_end);
    try std.testing.expect(event_stream.events[6] == .stream_end);
}

test "parseTokens parses anchored and tagged top-level flow collections" {
    var sequence_tokens = try scanner.scan(std.testing.allocator, "&seq !<tag:example.com,2000:seq> [one]\n");
    defer sequence_tokens.deinit();
    var sequence_events = try parseTokens(std.testing.allocator, sequence_tokens.tokens);
    defer sequence_events.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_events.events.len);
    try std.testing.expect(sequence_events.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, sequence_events.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("seq", sequence_events.events[2].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", sequence_events.events[2].sequence_start.tag.?);
    try std.testing.expect(sequence_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence_events.events[3].scalar.value);
    try std.testing.expect(sequence_events.events[4] == .sequence_end);

    var mapping_tokens = try scanner.scan(std.testing.allocator, "!<tag:example.com,2000:map> &map {key: value}\n");
    defer mapping_tokens.deinit();
    var mapping_events = try parseTokens(std.testing.allocator, mapping_tokens.tokens);
    defer mapping_events.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_events.events.len);
    try std.testing.expect(mapping_events.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, mapping_events.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("map", mapping_events.events[2].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", mapping_events.events[2].mapping_start.tag.?);
    try std.testing.expect(mapping_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", mapping_events.events[3].scalar.value);
    try std.testing.expect(mapping_events.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", mapping_events.events[4].scalar.value);
    try std.testing.expect(mapping_events.events[5] == .mapping_end);
}

test "parseTokens parses split node properties before top-level flow collections" {
    var sequence_tokens = try scanner.scan(std.testing.allocator,
        \\&items
        \\[one]
        \\
    );
    defer sequence_tokens.deinit();

    var sequence_events = try parseTokens(std.testing.allocator, sequence_tokens.tokens);
    defer sequence_events.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_events.events.len);
    try std.testing.expect(sequence_events.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, sequence_events.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("items", sequence_events.events[2].sequence_start.anchor.?);
    try std.testing.expect(sequence_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence_events.events[3].scalar.value);
    try std.testing.expect(sequence_events.events[4] == .sequence_end);

    var mapping_tokens = try scanner.scan(std.testing.allocator,
        \\!<tag:example.com,2000:root>
        \\{key: value}
        \\
    );
    defer mapping_tokens.deinit();

    var mapping_events = try parseTokens(std.testing.allocator, mapping_tokens.tokens);
    defer mapping_events.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_events.events.len);
    try std.testing.expect(mapping_events.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, mapping_events.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("tag:example.com,2000:root", mapping_events.events[2].mapping_start.tag.?);
    try std.testing.expect(mapping_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", mapping_events.events[3].scalar.value);
    try std.testing.expect(mapping_events.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", mapping_events.events[4].scalar.value);
    try std.testing.expect(mapping_events.events[5] == .mapping_end);
}

test "parseTokens parses anchored and tagged nested flow collections" {
    var token_stream = try scanner.scan(std.testing.allocator, "{seq: &seq [one], map: !<tag:example.com,2000:map> {key: value}}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("seq", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("seq", event_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqual(@as(?[]const u8, null), event_stream.events[4].sequence_start.tag);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("map", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[8].mapping_start.style);
    try std.testing.expectEqual(@as(?[]const u8, null), event_stream.events[8].mapping_start.anchor);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", event_stream.events[8].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .document_end);
    try std.testing.expect(event_stream.events[14] == .stream_end);
}

test "parseTokens parses separated tags before nested flow collection values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\!!map {
        \\  k: !!seq
        \\  [ a, !!str b]
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[2].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("k", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:seq", event_stream.events[4].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[6].scalar.tag.?);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}
test "parseTokens parses a flow mapping of plain scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "{foo: bar, baz: qux}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
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

test "parseTokens parses multiline implicit flow mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\multi
        \\ line: value
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("multi line", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses percent-started flow mapping key continuations across documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\{ matches
        \\% : 20 }
        \\...
        \\---
        \\# Empty
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("matches %", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("20", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .document_start);
    try std.testing.expect(event_stream.events[7].document_start.explicit);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(event_stream.events[9].document_end.explicit);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses multiline implicit flow mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\foo: bar
        \\ baz
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar baz", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses a flow mapping containing a flow sequence value" {
    var token_stream = try scanner.scan(std.testing.allocator, "{foo: [bar, baz], qux: corge}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("qux", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("corge", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(event_stream.events[12] == .stream_end);
}

test "parseTokens parses a flow mapping with quoted scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "{\"key\\n\": 'value'}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key\n", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses an empty flow sequence" {
    var token_stream = try scanner.scan(std.testing.allocator, "[]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 6), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .sequence_end);
    try std.testing.expect(event_stream.events[4] == .document_end);
    try std.testing.expect(event_stream.events[5] == .stream_end);
}

test "parseTokens parses an empty flow mapping" {
    var token_stream = try scanner.scan(std.testing.allocator, "{}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 6), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .mapping_end);
    try std.testing.expect(event_stream.events[4] == .document_end);
    try std.testing.expect(event_stream.events[5] == .stream_end);
}

test "parseTokens parses a flow sequence with a trailing comma" {
    var token_stream = try scanner.scan(std.testing.allocator, "[one, two,]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects empty flow sequence entries" {
    var double_comma_tokens = try scanner.scan(std.testing.allocator, "[one,, two]\n");
    defer double_comma_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, double_comma_tokens.tokens));

    var leading_comma_tokens = try scanner.scan(std.testing.allocator, "[, one]\n");
    defer leading_comma_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, leading_comma_tokens.tokens));
}

test "parseTokens rejects block scalar indicators as flow plain scalars" {
    var literal_sequence_tokens = try scanner.scan(std.testing.allocator, "[|]\n");
    defer literal_sequence_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, literal_sequence_tokens.tokens));

    var folded_sequence_tokens = try scanner.scan(std.testing.allocator, "[>]\n");
    defer folded_sequence_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, folded_sequence_tokens.tokens));

    var mapping_key_tokens = try scanner.scan(std.testing.allocator, "{|: value}\n");
    defer mapping_key_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, mapping_key_tokens.tokens));
}

test "parser helpers: incomplete flow mapping with only start returns false" {
    const tokens = [_]scanner.Token{.flow_mapping_start};

    var events: parser.EventBuilder = .{};
    defer events.deinit(std.testing.allocator);

    var index: usize = 0;
    const parsed = try parser.appendMappingNodeEvents(
        std.testing.allocator,
        &tokens,
        &index,
        tokens.len,
        &events,
        0,
        .{},
        .{},
    );

    try std.testing.expect(!parsed);
    try std.testing.expectEqual(@as(usize, tokens.len), index);
    try std.testing.expectEqual(@as(usize, 1), events.slice().len);
    try std.testing.expect(events.slice()[0] == .mapping_start);
}
test "parseTokens parses a flow mapping with a trailing comma" {
    var token_stream = try scanner.scan(std.testing.allocator, "{foo: bar,}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses empty flow mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator, "{foo: , bar: baz}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
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

test "parseTokens parses omitted flow mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\unquoted : "separate",
        \\http://foo.com,
        \\omitted value:,
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("unquoted", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("separate", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("http://foo.com", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("omitted value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses flow mapping value indicators on following lines" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\{ "foo"
        \\  :bar }
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses empty flow mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator, "{: empty, key: value, :}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("empty", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses explicit flow mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\? explicit: entry,
        \\implicit: entry,
        \\?
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("explicit", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("entry", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("implicit", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("entry", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
    try std.testing.expect(event_stream.events[10] == .document_end);
    try std.testing.expect(event_stream.events[11] == .stream_end);
}

test "parseTokens parses multiline explicit flow mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\? foo
        \\ bar : baz
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo bar", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses multiline explicit flow mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\{
        \\? foo : bar
        \\ baz
        \\}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar baz", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses a trailing empty flow mapping value" {
    var token_stream = try scanner.scan(std.testing.allocator, "{foo:}\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens preserves mixed flow sequence event equivalence" {
    var token_stream = try scanner.scan(std.testing.allocator, "&root [plain, key: &node !<tag:example.com,2000:seq> [*node, {inner: value}], ? explicit : , : empty]\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    const expected = [_]types.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow, .anchor = "root" } },
        .{ .scalar = .{ .value = "plain" } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "key" } },
        .{ .sequence_start = .{ .style = .flow, .anchor = "node", .tag = "tag:example.com,2000:seq" } },
        .{ .alias = "node" },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "inner" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .mapping_end,
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "explicit" } },
        .{ .scalar = .{ .value = "" } },
        .mapping_end,
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "" } },
        .{ .scalar = .{ .value = "empty" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectEqualDeep(&expected, event_stream.events);
}

test "parseTokens does not overallocate temporary flow sequence entry events" {
    const item_count = 96;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.append(std.testing.allocator, '[');
    for (0..item_count) |index| {
        if (index != 0) try input.appendSlice(std.testing.allocator, ", ");
        try input.print(std.testing.allocator, "item_{d}", .{index});
    }
    try input.appendSlice(std.testing.allocator, "]\n");

    var token_stream = try scanner.scan(std.testing.allocator, input.items);
    defer token_stream.deinit();

    var counted: CountingAllocator = .{ .child = std.testing.allocator };
    var event_stream = try parseTokens(counted.allocator(), token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, item_count + 6), event_stream.events.len);
    try std.testing.expect(counted.allocated_bytes <= input.items.len * 72);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocated_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocated_bytes += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
