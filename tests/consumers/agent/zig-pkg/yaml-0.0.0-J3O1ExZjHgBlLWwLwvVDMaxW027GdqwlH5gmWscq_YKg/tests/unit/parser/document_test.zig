//! Purpose: Verify document parser token behavior.
//! Owns: Consolidated document stream, directive, tag, and document-boundary regression coverage.
//! Does not own: Shared parser test helpers or conformance harness behavior.
//! Depends on: support.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig.

const support = @import("support.zig");

const std = support.std;
const scanner = support.scanner;
const parseTokens = support.parseTokens;
const ParseError = support.ParseError;
const parser = support.event_parser.parser;
const types = support.types;

fn expectRootClass(expected: parser.DocumentRootClass, input: []const u8) !void {
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    try std.testing.expectEqual(expected, parser.classifyDocumentRoot(token_stream.tokens));
}

test "classifyDocumentRoot conservatively identifies single-document roots" {
    try expectRootClass(.scalar, "plain\n");
    try expectRootClass(.scalar, "|\n  text\n");
    try expectRootClass(.alias, "*anchor\n");
    try expectRootClass(.flow_sequence, "[one, two]\n");
    try expectRootClass(.flow_mapping, "{key: value}\n");
    try expectRootClass(.block_sequence, "- one\n- two\n");
    try expectRootClass(.block_mapping, "key: value\n");
}

test "classifyDocumentRoot falls back for ambiguous roots and streams" {
    try expectRootClass(.fallback, "&anchor\n[one]\n");
    try expectRootClass(.fallback, "%YAML 1.2\n---\nvalue\n");
    try expectRootClass(.fallback,
        \\--- one
        \\--- two
        \\
    );
}

test "parseTokens parses a single plain scalar document" {
    var token_stream = try scanner.scan(std.testing.allocator, "plain\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.plain, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .stream_end);

    try std.testing.expect(@intFromPtr(event_stream.events[2].scalar.value.ptr) != @intFromPtr(token_stream.tokens[2].scalar.ptr));
}

test "parseTokens folds multiline plain scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\plain
        \\  continuation
        \\
        \\next
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.plain, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("plain continuation\nnext", event_stream.events[2].scalar.value);
}

test "parseTokens folds top-level plain scalar continuations that look like node properties" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\k:#foo
        \\ &a !t s
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("k:#foo &a !t s", event_stream.events[2].scalar.value);
}

test "parseTokens parses comment-only streams as empty streams" {
    var token_stream = try scanner.scan(std.testing.allocator, "  # Comment\n" ++
        "   \n" ++
        "\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 2), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .stream_end);
}

test "parseTokens parses document-end-only streams as empty streams" {
    var plain_end_tokens = try scanner.scan(std.testing.allocator,
        \\...
        \\
    );
    defer plain_end_tokens.deinit();

    var plain_end_events = try parseTokens(std.testing.allocator, plain_end_tokens.tokens);
    defer plain_end_events.deinit();

    try std.testing.expectEqual(@as(usize, 2), plain_end_events.events.len);
    try std.testing.expect(plain_end_events.events[0] == .stream_start);
    try std.testing.expect(plain_end_events.events[1] == .stream_end);

    var commented_end_tokens = try scanner.scan(std.testing.allocator,
        \\# comment
        \\...
        \\
    );
    defer commented_end_tokens.deinit();

    var commented_end_events = try parseTokens(std.testing.allocator, commented_end_tokens.tokens);
    defer commented_end_events.deinit();

    try std.testing.expectEqual(@as(usize, 2), commented_end_events.events.len);
    try std.testing.expect(commented_end_events.events[0] == .stream_start);
    try std.testing.expect(commented_end_events.events[1] == .stream_end);
}

test "parseTokens parses explicit plain scalar document markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\plain
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseTokens parses explicit multi-document scalar streams" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\--- one
        \\--- 'two'
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(!event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[5].scalar.style);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses directives after explicit document end markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\--- one
        \\...
        \\%YAML 1.2
        \\--- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[4].document_start.yaml_version.?);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(!event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses explicit empty multi-document streams" {
    var token_stream = try scanner.scan(std.testing.allocator, "---\n---\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(!event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(!event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses explicit multi-document collection streams" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\- one
        \\---
        \\name: Bob
        \\--- [x, y]
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 19), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_end);
    try std.testing.expect(event_stream.events[5] == .document_end);
    try std.testing.expect(!event_stream.events[5].document_end.explicit);
    try std.testing.expect(event_stream.events[6] == .document_start);
    try std.testing.expect(event_stream.events[6].document_start.explicit);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[7].mapping_start.style);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("name", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("Bob", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .mapping_end);
    try std.testing.expect(event_stream.events[11] == .document_end);
    try std.testing.expect(!event_stream.events[11].document_end.explicit);
    try std.testing.expect(event_stream.events[12] == .document_start);
    try std.testing.expect(event_stream.events[12].document_start.explicit);
    try std.testing.expect(event_stream.events[13] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[13].sequence_start.style);
    try std.testing.expect(event_stream.events[14] == .scalar);
    try std.testing.expectEqualStrings("x", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[15] == .scalar);
    try std.testing.expectEqualStrings("y", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .sequence_end);
    try std.testing.expect(event_stream.events[17] == .document_end);
    try std.testing.expect(event_stream.events[17].document_end.explicit);
    try std.testing.expect(event_stream.events[18] == .stream_end);
}

test "parseTokens parses explicit document start after closed flow collection" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\--- {a: [b]}
        \\--- c
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_start);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("c", event_stream.events[10].scalar.value);
}

test "parseTokens parses bare documents after explicit document end markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\scalar1
        \\...
        \\key: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("scalar1", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(!event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .document_end);
    try std.testing.expect(!event_stream.events[9].document_end.explicit);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}

test "parseTokens parses bare scalar documents after explicit document end markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\one
        \\...
        \\two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(!event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(!event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses explicit document end comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\plain
        \\... # done
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

fn rejectSingleDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize, _: *parser.EventBuilder) parser.Error!bool {
    return false;
}

test "parser helpers: explicit stream propagates unsupported document" {
    const tokens = [_]scanner.Token{
        .stream_start,
        .document_start,
        .{ .scalar = "first" },
        .document_start,
        .{ .scalar = "second" },
        .stream_end,
    };

    var events: parser.EventBuilder = .{};
    defer events.deinit(std.testing.allocator);

    try std.testing.expectError(parser.ParseError.Unsupported, parser.appendExplicitDocumentStreamEvents(
        std.testing.allocator,
        &tokens,
        &events,
        rejectSingleDocument,
    ));
}

test "parseTokens parses multi-document tag and anchor combinations" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\&a1
        \\!!str
        \\scalar1
        \\---
        \\!!str
        \\&a2
        \\scalar2
        \\---
        \\&a3
        \\!!str scalar3
        \\---
        \\&a4 !!map
        \\&a5 !!str key5: value4
        \\---
        \\a6: 1
        \\&anchor6 b6: 2
        \\---
        \\!!map
        \\&a8 !!str key8: value7
        \\---
        \\!!map
        \\!!str &a10 key10: value9
        \\---
        \\!!str &a11
        \\value11
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 40), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("a1", event_stream.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("scalar1", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_start);
    try std.testing.expectEqualStrings("a4", event_stream.events[11].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[11].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("a5", event_stream.events[12].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[12].scalar.tag.?);
    try std.testing.expectEqualStrings("key5", event_stream.events[12].scalar.value);
    try std.testing.expect(event_stream.events[20] == .scalar);
    try std.testing.expectEqualStrings("anchor6", event_stream.events[20].scalar.anchor.?);
    try std.testing.expectEqualStrings("b6", event_stream.events[20].scalar.value);
    try std.testing.expect(event_stream.events[25] == .mapping_start);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[25].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[26] == .scalar);
    try std.testing.expectEqualStrings("a8", event_stream.events[26].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[26].scalar.tag.?);
    try std.testing.expectEqualStrings("key8", event_stream.events[26].scalar.value);
    try std.testing.expect(event_stream.events[37] == .scalar);
    try std.testing.expectEqualStrings("a11", event_stream.events[37].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[37].scalar.tag.?);
    try std.testing.expectEqualStrings("value11", event_stream.events[37].scalar.value);
    try std.testing.expect(event_stream.events[39] == .stream_end);
}

test "parseTokens parses explicit multi-document streams with leading directives" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%YAML 1.2
        \\---
        \\one
        \\---
        \\two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[1].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[4].document_start.yaml_version == null);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens parses implicit document before explicit document boundaries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\Document
        \\---
        \\# Empty
        \\...
        \\%YAML 1.2
        \\---
        \\matches %: 20
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(!event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("Document", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(!event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7] == .document_start);
    try std.testing.expect(event_stream.events[7].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[7].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("matches %", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("20", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .document_end);
    try std.testing.expect(event_stream.events[13] == .stream_end);
}

test "parseTokens applies tag directives after explicit document end markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:first/
        \\--- !e!name one
        \\...
        \\%TAG !e! tag:example.com,2000:second/
        \\--- !e!name two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:first/name", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:second/name", event_stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens applies YAML directives after explicit document end markers" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%YAML 1.2
        \\--- one
        \\...
        \\%YAML 1.1
        \\--- two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[1].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(event_stream.events[4].document_start.explicit);
    try std.testing.expectEqualStrings("1.1", event_stream.events[4].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects directives before a following document start without document end" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%YAML 1.2
        \\---
        \\%YAML 1.2
        \\---
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses directives before scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%YAML 1.2
        \\%TAG !e! tag:example.com,2000:app/
        \\%RESERVED value
        \\--- !e!name value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[1].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[1].document_start.has_reserved_directive);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/name", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", event_stream.events[2].scalar.value);
}

test "parseTokens accepts tab separation in directives and document start content" {
    var token_stream = try scanner.scan(std.testing.allocator, "%YAML\t1.2\n" ++
        "%TAG\t!e!\ttag:example.com,2000:app/\n" ++
        "---\t!e!name\tvalue\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", event_stream.events[1].document_start.yaml_version.?);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line_separated_by_tab);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/name", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", event_stream.events[2].scalar.value);
}

test "parseTokens rejects invalid TAG directive handles" {
    var missing_trailing_bang = try scanner.scan(std.testing.allocator,
        \\%TAG !bad tag:example.com,2000:app/
        \\--- !bad value
        \\
    );
    defer missing_trailing_bang.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, missing_trailing_bang.tokens));

    var invalid_character = try scanner.scan(std.testing.allocator,
        \\%TAG !b*d! tag:example.com,2000:app/
        \\--- value
        \\
    );
    defer invalid_character.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, invalid_character.tokens));
}

test "parseTokens decodes tag URI escapes in directive-expanded scalar tags" {
    var named_tokens = try scanner.scan(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app%2F
        \\--- !e!space%20name value
        \\
    );
    defer named_tokens.deinit();

    var named_events = try parseTokens(std.testing.allocator, named_tokens.tokens);
    defer named_events.deinit();

    try std.testing.expectEqual(@as(usize, 5), named_events.events.len);
    try std.testing.expect(named_events.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/space name", named_events.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", named_events.events[2].scalar.value);

    var primary_tokens = try scanner.scan(std.testing.allocator,
        \\%TAG ! !local%2F
        \\--- !space%20name value
        \\
    );
    defer primary_tokens.deinit();

    var primary_events = try parseTokens(std.testing.allocator, primary_tokens.tokens);
    defer primary_events.deinit();

    try std.testing.expectEqual(@as(usize, 5), primary_events.events.len);
    try std.testing.expect(primary_events.events[2] == .scalar);
    try std.testing.expectEqualStrings("!local/space name", primary_events.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", primary_events.events[2].scalar.value);
}

test "parseTokens decodes tag URI escapes in verbatim scalar tags" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\!<tag:example.com,2000:app%2Fspace%20name> value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/space name", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", event_stream.events[2].scalar.value);
}

test "parseTokens rejects malformed percent escapes in tag properties" {
    var verbatim = try scanner.scan(std.testing.allocator,
        \\!<tag:example.com,2000:bad%ZZ> value
        \\
    );
    defer verbatim.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, verbatim.tokens));

    var primary = try scanner.scan(std.testing.allocator,
        \\!bad% value
        \\
    );
    defer primary.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, primary.tokens));

    var secondary = try scanner.scan(std.testing.allocator,
        \\!!str%0G value
        \\
    );
    defer secondary.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, secondary.tokens));

    var named = try scanner.scan(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\--- !e!bad%2 value
        \\
    );
    defer named.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, named.tokens));
}

test "parseTokens rejects tag shorthands without suffixes" {
    var secondary = try scanner.scan(std.testing.allocator,
        \\!! value
        \\
    );
    defer secondary.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, secondary.tokens));

    var named = try scanner.scan(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\!e! value
        \\
    );
    defer named.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, named.tokens));
}

test "parseTokens decodes percent escapes in tag directive prefix and suffix" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app%2F
        \\---
        \\!e!foo%2Fbar value
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo/bar", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", event_stream.events[2].scalar.value);
}

test "parseTokens scopes reserved directives to the following document" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\%FOO first
        \\--- one
        \\...
        \\--- two
        \\...
        \\%BAR second
        \\--- three
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.has_reserved_directive);
    try std.testing.expect(event_stream.events[4] == .document_start);
    try std.testing.expect(!event_stream.events[4].document_start.has_reserved_directive);
    try std.testing.expect(event_stream.events[7] == .document_start);
    try std.testing.expect(event_stream.events[7].document_start.has_reserved_directive);
    try std.testing.expect(event_stream.events[10] == .stream_end);
}
