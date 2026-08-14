//! Purpose: Consolidate public root API parse behavior regression tests.
//! Owns: Public parseEvents and pull-parser behavior assertions.
//! Does not own: Load, emit, dump, diagnostic, limit, or tag behavior assertions.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const CollectionStyle = support.CollectionStyle;
const Diagnostic = support.Diagnostic;
const ParseError = support.ParseError;
const ScalarStyle = support.ScalarStyle;
const yaml = support.yaml;
const load = support.load;
const parseEvents = support.parseEvents;
const parseEventsWithOptions = support.parseEventsWithOptions;
const expectScalarString = support.expectScalarString;

test "parseEvents preserves escaped whitespace before folded double quoted line break" {
    var stream = try parseEvents(std.testing.allocator,
        \\"kept \_
        \\  next"
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("kept \xc2\xa0 next", stream.events[2].scalar.value);
}

test "parseEvents owns flow sequence speculative event strings" {
    const input = try std.testing.allocator.dupe(u8, "&root [plain, key: &node !<tag:example.com,2000:seq> [*node]]\n");
    defer std.testing.allocator.free(input);

    var stream = try parseEvents(std.testing.allocator, input);
    defer stream.deinit();
    @memset(input, 'x');

    try std.testing.expectEqualStrings("root", stream.events[2].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("plain", stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("key", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("node", stream.events[6].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", stream.events[6].sequence_start.tag.?);
    try std.testing.expectEqualStrings("node", stream.events[7].alias);
}

test "Parser.init reports token and event count limit diagnostics" {
    const input =
        \\- one
        \\- two
        \\
    ;

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, input, .{
        .max_token_count = 4,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, input, .{
        .max_event_count = 4,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
}

test "Parser.init reports input scalar and nesting limit diagnostics" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, "abcd", .{
        .max_input_bytes = 3,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("input exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.offset);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, "[[value]]\n", .{
        .max_nesting_depth = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.offset);
}

test "Parser.init preserves flow sequence implicit mapping limit diagnostics" {
    const input = "[plain, key: [nested], tail]\n";
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, input, .{
        .max_event_count = 13,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, input, .{
        .max_scalar_bytes = 5,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, yaml.Parser.init(std.testing.allocator, input, .{
        .max_nesting_depth = 2,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
}

test "load keeps hash characters inside double quoted block mapping scalars" {
    var document = try load(std.testing.allocator,
        \\key: "value # not a comment"
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 1), document.root.mapping.pairs.len);
    try expectScalarString(document.root.mapping.pairs[0].key, "key");
    try expectScalarString(document.root.mapping.pairs[0].value, "value # not a comment");
}

test "load keeps unbalanced quote characters inside plain scalar continuations" {
    var document = try load(std.testing.allocator,
        \\message: Unknown variable "bar
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 1), document.root.mapping.pairs.len);
    try expectScalarString(document.root.mapping.pairs[0].key, "message");
    try expectScalarString(document.root.mapping.pairs[0].value, "Unknown variable \"bar");
}

test "parseEvents keeps hash characters inside multiline quoted mapping scalars" {
    var double_quoted = try parseEvents(std.testing.allocator,
        \\key: "line
        \\  # not a comment"
        \\
    );
    defer double_quoted.deinit();

    try std.testing.expectEqual(@as(usize, 8), double_quoted.events.len);
    try std.testing.expect(double_quoted.events[2] == .mapping_start);
    try std.testing.expect(double_quoted.events[4] == .scalar);
    try std.testing.expectEqualStrings("line # not a comment", double_quoted.events[4].scalar.value);

    var single_quoted = try parseEvents(std.testing.allocator,
        \\key: 'line
        \\  # not a comment'
        \\
    );
    defer single_quoted.deinit();

    try std.testing.expectEqual(@as(usize, 8), single_quoted.events.len);
    try std.testing.expect(single_quoted.events[2] == .mapping_start);
    try std.testing.expect(single_quoted.events[4] == .scalar);
    try std.testing.expectEqualStrings("line # not a comment", single_quoted.events[4].scalar.value);
}

test "parseEvents treats CR-only line breaks as YAML line breaks" {
    var stream = try parseEvents(std.testing.allocator, "- one\r- two\r");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[0] == .stream_start);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
    try std.testing.expect(stream.events[6] == .document_end);
    try std.testing.expect(stream.events[7] == .stream_end);
}

test "parseEvents folds CR-only line breaks in plain scalars" {
    var stream = try parseEvents(std.testing.allocator, "one\rtwo\r");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one two", stream.events[2].scalar.value);
}

test "parseEvents treats YAML non-ASCII line separators as line breaks" {
    var stream = try parseEvents(std.testing.allocator, "one\xc2\x85two\xe2\x80\xa8three\xe2\x80\xa9four\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[0] == .stream_start);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one two three four", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[4] == .stream_end);
}

test "parseEvents splits block sequence entries on non-ASCII line separators" {
    var stream = try parseEvents(std.testing.allocator, "- one\xc2\x85- two\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
    try std.testing.expect(stream.events[6] == .document_end);
    try std.testing.expect(stream.events[7] == .stream_end);
}

test "parseEvents rejects invalid UTF-8 input" {
    const input = [_]u8{ 'o', 'k', 0xc0, '\n' };

    var stream = parseEvents(std.testing.allocator, &input) catch |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
        return;
    };
    defer stream.deinit();

    try std.testing.expect(false);
}

test "parseEventsWithOptions reports invalid UTF-8 location" {
    const input = [_]u8{ 'o', 'k', 0xc0, '\n' };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(@as(usize, 2), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.column);
    try std.testing.expectEqualStrings("invalid UTF-8", diagnostic.message);
}

test "parseEvents rejects non-printable raw input characters" {
    const nul_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x00, '\n' };
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &nul_input));

    const bell_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x07, '\n' };
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &bell_input));

    const del_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0x7f, '\n' };
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &del_input));

    const c1_input = [_]u8{ 'b', 'a', 'd', ':', ' ', 0xc2, 0x80, '\n' };
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &c1_input));
}

test "parseEventsWithOptions reports non-printable character location" {
    const input = [_]u8{ 'o', 'k', '\n', 'b', 'a', 'd', ':', ' ', 0x7f, '\n' };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(@as(usize, 8), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
    try std.testing.expectEqualStrings("non-printable character", diagnostic.message);
}

test "parseEvents allows escaped controls inside double quoted scalars" {
    var stream = try parseEvents(std.testing.allocator,
        \\"escaped \0 \x07"
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("escaped \x00 \x07", stream.events[2].scalar.value);
}

test "parseEvents rejects escaped surrogate codepoints" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\"\uD800"
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\"\U0000DFFF"
        \\
    ));
}

test "parseEventsWithOptions reports invalid double-quoted escape location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\key: "bad\q"
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("invalid double-quoted escape", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 9), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.column);
}

test "parseEventsWithOptions reports unterminated double-quoted scalar location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\key: "unterminated
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unterminated double-quoted scalar", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

test "parseEventsWithOptions reports unterminated single-quoted scalar location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\key: 'unterminated
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unterminated single-quoted scalar", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

test "parseEventsWithOptions reports unexpected flow close indicator location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\key: ]
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unexpected flow close indicator", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

test "parseEvents rejects raw non-printable characters inside quoted scalars" {
    const input = [_]u8{ '"', 'q', 'u', 'o', 't', 'e', 'd', ' ', 0x7f, ' ', 0xc2, 0x80, '"', '\n' };
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &input));
}

test "parseEventsWithOptions reports non-printable characters after escaped quoted delimiters" {
    const single_quoted = [_]u8{ '\'', 'i', 't', '\'', '\'', 's', ' ', 0x7f, '\'', '\n' };
    var single_diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &single_quoted, .{
        .diagnostic = &single_diagnostic,
    }));

    try std.testing.expectEqualStrings("non-printable character", single_diagnostic.message);
    try std.testing.expectEqual(@as(usize, 7), single_diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), single_diagnostic.line);
    try std.testing.expectEqual(@as(usize, 8), single_diagnostic.column);

    const double_quoted = [_]u8{ '"', 's', 'a', 'i', 'd', ' ', '\\', '"', ' ', 0xc2, 0x80, '"', '\n' };
    var double_diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &double_quoted, .{
        .diagnostic = &double_diagnostic,
    }));

    try std.testing.expectEqualStrings("non-printable character", double_diagnostic.message);
    try std.testing.expectEqual(@as(usize, 9), double_diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), double_diagnostic.line);
    try std.testing.expectEqual(@as(usize, 10), double_diagnostic.column);
}

test "parseEvents ignores UTF-8 BOM at stream and document prefixes" {
    var stream = try parseEvents(std.testing.allocator, "\xEF\xBB\xBF--- first\n" ++
        "...\n" ++
        "\xEF\xBB\xBF# prefix comment\n" ++
        "\xEF\xBB\xBF--- second\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("first", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expect(stream.events[4].document_start.explicit);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("second", stream.events[5].scalar.value);
}

test "parseEvents rejects UTF-8 BOM inside block document content" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "- one\n" ++
        "\xEF\xBB\xBF- two\n"));
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "one \xEF\xBB\xBF two\n"));
}

test "parseEvents rejects UTF-8 BOM after quote-like plain scalar text" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, "plain \" quote \xEF\xBB\xBF text\n", .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("misplaced UTF-8 BOM", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 14), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 15), diagnostic.column);
}

test "parseEventsWithOptions reports misplaced UTF-8 BOM location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, "ok\none \xEF\xBB\xBF two\n", .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(@as(usize, 7), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
    try std.testing.expectEqualStrings("misplaced UTF-8 BOM", diagnostic.message);
}

test "parseEvents preserves UTF-8 BOM inside quoted scalars" {
    var stream = try parseEvents(std.testing.allocator, "\"a \xEF\xBB\xBF b\"\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("a \xEF\xBB\xBF b", stream.events[2].scalar.value);
}

test "parseEvents decodes UTF-16 input before parsing" {
    const utf16le = [_]u8{
        0xff, 0xfe,
        'k',  0x00,
        'e',  0x00,
        'y',  0x00,
        ':',  0x00,
        ' ',  0x00,
        'v',  0x00,
        'a',  0x00,
        'l',  0x00,
        'u',  0x00,
        'e',  0x00,
        '\n', 0x00,
    };

    var stream = try parseEvents(std.testing.allocator, &utf16le);
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .mapping_end);
}

test "parseEvents detects short UTF-16 input without byte order mark" {
    const utf16le = [_]u8{ 'x', 0x00 };

    var stream = try parseEvents(std.testing.allocator, &utf16le);
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("x", stream.events[2].scalar.value);
}

test "parseEvents decodes UTF-32 input before parsing" {
    const utf32be = [_]u8{
        0x00, 0x00, 0xfe, 0xff,
        0x00, 0x01, 0x03, 0x48,
        0x00, 0x00, 0x00, 0x0a,
    };

    var stream = try parseEvents(std.testing.allocator, &utf32be);
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("\xf0\x90\x8d\x88", stream.events[2].scalar.value);
}

test "parseEvents rejects malformed UTF-16 input" {
    const dangling_surrogate = [_]u8{
        0xff, 0xfe,
        0x00, 0xd8,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, &dangling_surrogate));
}

test "parseEventsWithOptions reports malformed UTF-16 input" {
    const dangling_surrogate = [_]u8{
        0xff, 0xfe,
        'a',  0x00,
        0x00, 0xd8,
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &dangling_surrogate, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid UTF-16", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseEventsWithOptions reports odd-length UTF-16 input" {
    const odd_length_utf16 = [_]u8{
        0xff, 0xfe,
        'a',  0x00,
        'b',
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &odd_length_utf16, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid UTF-16", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseEventsWithOptions reports malformed UTF-16 big-endian input after valid surrogate pair" {
    const valid_pair_then_dangling_surrogate = [_]u8{
        0xfe, 0xff,
        0xd8, 0x00,
        0xdc, 0x00,
        0xd8, 0x00,
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &valid_pair_then_dangling_surrogate, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid UTF-16", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 7), diagnostic.column);
}

test "parseEventsWithOptions reports syntax fallback for valid UTF-16 big-endian input" {
    const unterminated_flow = [_]u8{
        0xfe, 0xff,
        0x00, '[',
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &unterminated_flow, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid YAML syntax", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.column);
}

test "parseEventsWithOptions reports malformed UTF-32 input" {
    const out_of_range_codepoint = [_]u8{
        0xff, 0xfe, 0x00, 0x00,
        0x00, 0x00, 0x11, 0x00,
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &out_of_range_codepoint, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid UTF-32", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseEventsWithOptions reports surrogate UTF-32 big-endian input" {
    const surrogate_codepoint = [_]u8{
        0x00, 0x00, 0xfe, 0xff,
        0x00, 0x00, 0xd8, 0x00,
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &surrogate_codepoint, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid UTF-32", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseEventsWithOptions reports syntax fallback for valid UTF-32 big-endian input" {
    const unterminated_flow = [_]u8{
        0x00, 0x00, 0xfe, 0xff,
        0x00, 0x00, 0x00, '[',
    };
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, &unterminated_flow, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("invalid YAML syntax", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseEvents preserves YAML directive version on document start" {
    var stream = try parseEvents(std.testing.allocator,
        \\%YAML 1.2
        \\---
        \\foo
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expectEqualStrings("1.2", stream.events[1].document_start.yaml_version.?);
}

test "parseEvents accepts YAML directive minor versions for major version one" {
    var stream = try parseEvents(std.testing.allocator,
        \\%YAML 1.3 # parse with major-version compatibility
        \\---
        \\foo
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expectEqualStrings("1.3", stream.events[1].document_start.yaml_version.?);
}

test "parseEvents records reserved directives on document start" {
    var stream = try parseEvents(std.testing.allocator,
        \\%FOO bar
        \\---
        \\"foo"
        \\
    );
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.has_reserved_directive);
}

test "parseEvents scopes reserved directives to the following document" {
    var stream = try parseEvents(std.testing.allocator,
        \\%FOO first
        \\--- one
        \\...
        \\--- two
        \\...
        \\%BAR second
        \\--- three
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.has_reserved_directive);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expect(!stream.events[4].document_start.has_reserved_directive);
    try std.testing.expect(stream.events[7] == .document_start);
    try std.testing.expect(stream.events[7].document_start.has_reserved_directive);
}

test "parseEvents rejects directives not followed by document start" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\--- first
        \\...
        \\%YAML 1.2
        \\second
        \\
    ));
}

test "parseEvents applies directives after explicit document end markers" {
    var stream = try parseEvents(std.testing.allocator,
        \\%YAML 1.2
        \\%TAG !e! tag:example.com,2000:first/
        \\--- !e!name one
        \\...
        \\%YAML 1.1
        \\%TAG !e! tag:example.com,2000:second/
        \\--- !e!name two
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expectEqualStrings("1.2", stream.events[1].document_start.yaml_version.?);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:first/name", stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("one", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expectEqualStrings("1.1", stream.events[4].document_start.yaml_version.?);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:second/name", stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("two", stream.events[5].scalar.value);
}

test "parseEvents parses bare scalar documents after explicit document end markers" {
    var stream = try parseEvents(std.testing.allocator,
        \\---
        \\one
        \\...
        \\two
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expect(!stream.events[4].document_start.explicit);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("two", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .document_end);
    try std.testing.expect(!stream.events[6].document_end.explicit);
}

test "parseEvents parses bare mapping documents after explicit document end markers" {
    var stream = try parseEvents(std.testing.allocator,
        \\---
        \\scalar1
        \\...
        \\key: value
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("scalar1", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expect(!stream.events[4].document_start.explicit);
    try std.testing.expect(stream.events[5] == .mapping_start);
    try std.testing.expect(stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("key", stream.events[6].scalar.value);
    try std.testing.expect(stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("value", stream.events[7].scalar.value);
    try std.testing.expectEqual(support.Event.mapping_end, stream.events[8]);
    try std.testing.expect(stream.events[9] == .document_end);
    try std.testing.expect(!stream.events[9].document_end.explicit);
}

test "parseEvents parses explicit document end comments" {
    var stream = try parseEvents(std.testing.allocator,
        \\---
        \\plain
        \\... # done
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .stream_end);
}

test "parseEvents treats indented directive-looking content as a scalar" {
    var stream = try parseEvents(std.testing.allocator,
        \\  %YAML 1.2
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("%YAML 1.2", stream.events[2].scalar.value);
}

test "parseEvents treats indented document markers as scalar content" {
    var start_marker = try parseEvents(std.testing.allocator,
        \\  ---
        \\
    );
    defer start_marker.deinit();

    try std.testing.expectEqual(@as(usize, 5), start_marker.events.len);
    try std.testing.expect(start_marker.events[2] == .scalar);
    try std.testing.expectEqualStrings("---", start_marker.events[2].scalar.value);

    var end_marker = try parseEvents(std.testing.allocator,
        \\  ...
        \\
    );
    defer end_marker.deinit();

    try std.testing.expectEqual(@as(usize, 5), end_marker.events.len);
    try std.testing.expect(end_marker.events[2] == .scalar);
    try std.testing.expectEqualStrings("...", end_marker.events[2].scalar.value);
}

test "parseEvents treats document start marker without separation as scalar content" {
    var stream = try parseEvents(std.testing.allocator,
        \\---#not a marker
        \\next
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(!stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("---#not a marker next", stream.events[2].scalar.value);
}

test "parseEvents records explicit document content on the marker line" {
    var stream = try parseEvents(std.testing.allocator,
        \\--- "foo"
        \\
    );
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[1].document_start.content_same_line);
}

test "parseEvents records tab-separated document marker content" {
    var stream = try parseEvents(std.testing.allocator, "---\tfoo\n");
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.content_same_line);
    try std.testing.expect(stream.events[1].document_start.content_same_line_separated_by_tab);
}

test "parseEvents records tab-separated alias document marker content" {
    var stream = try parseEvents(std.testing.allocator, "---\t*anchor\n");
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[1].document_start.content_same_line);
    try std.testing.expect(stream.events[1].document_start.content_same_line_separated_by_tab);
    try std.testing.expect(stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", stream.events[2].alias);
}

test "parseEvents parses same-line document start block collections" {
    var sequence = try parseEvents(std.testing.allocator, "--- - one\n");
    defer sequence.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence.events.len);
    try std.testing.expect(sequence.events[1] == .document_start);
    try std.testing.expect(sequence.events[1].document_start.explicit);
    try std.testing.expect(sequence.events[1].document_start.content_same_line);
    try std.testing.expect(sequence.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, sequence.events[2].sequence_start.style);
    try std.testing.expect(sequence.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence.events[3].scalar.value);
    try std.testing.expectEqual(support.Event.sequence_end, sequence.events[4]);

    var mapping = try parseEvents(std.testing.allocator, "--- key: value\n");
    defer mapping.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping.events.len);
    try std.testing.expect(mapping.events[1] == .document_start);
    try std.testing.expect(mapping.events[1].document_start.explicit);
    try std.testing.expect(mapping.events[1].document_start.content_same_line);
    try std.testing.expect(mapping.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, mapping.events[2].mapping_start.style);
    try std.testing.expect(mapping.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", mapping.events[3].scalar.value);
    try std.testing.expect(mapping.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", mapping.events[4].scalar.value);
    try std.testing.expectEqual(support.Event.mapping_end, mapping.events[5]);
}

test "parseEvents parses same-line document start block scalars" {
    var empty_literal = try parseEvents(std.testing.allocator, "--- |1-\n");
    defer empty_literal.deinit();

    try std.testing.expectEqual(@as(usize, 5), empty_literal.events.len);
    try std.testing.expect(empty_literal.events[1] == .document_start);
    try std.testing.expect(empty_literal.events[1].document_start.explicit);
    try std.testing.expect(empty_literal.events[1].document_start.content_same_line);
    try std.testing.expect(empty_literal.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.literal, empty_literal.events[2].scalar.style);
    try std.testing.expectEqualStrings("", empty_literal.events[2].scalar.value);

    const input = "--- |-\n" ++
        " ab\n" ++
        " \n" ++
        " \n" ++
        "...\n";
    var ended_literal = try parseEvents(std.testing.allocator, input);
    defer ended_literal.deinit();

    try std.testing.expectEqual(@as(usize, 5), ended_literal.events.len);
    try std.testing.expect(ended_literal.events[1] == .document_start);
    try std.testing.expect(ended_literal.events[1].document_start.explicit);
    try std.testing.expect(ended_literal.events[1].document_start.content_same_line);
    try std.testing.expect(ended_literal.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.literal, ended_literal.events[2].scalar.style);
    try std.testing.expectEqualStrings("ab", ended_literal.events[2].scalar.value);
    try std.testing.expect(ended_literal.events[3] == .document_end);
    try std.testing.expect(ended_literal.events[3].document_end.explicit);
}

test "parseEvents records multiline flow collections as requiring document start" {
    var stream = try parseEvents(std.testing.allocator,
        \\k: {
        \\ k
        \\ :
        \\ v
        \\ }
        \\
    );
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.force_document_start);
}

test "parseEvents does not force document start for top-level multiline flow collection" {
    var stream = try parseEvents(std.testing.allocator,
        \\{
        \\"empty":
        \\}
        \\
    );
    defer stream.deinit();

    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(!stream.events[1].document_start.force_document_start);
}

test "parseEvents preserves same-line document start flow collections" {
    var sequence = try parseEvents(std.testing.allocator, "--- [one]\n");
    defer sequence.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence.events.len);
    try std.testing.expect(sequence.events[1] == .document_start);
    try std.testing.expect(sequence.events[1].document_start.explicit);
    try std.testing.expect(sequence.events[1].document_start.content_same_line);
    try std.testing.expect(sequence.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, sequence.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("one", sequence.events[3].scalar.value);
    try std.testing.expectEqual(support.Event.sequence_end, sequence.events[4]);

    var mapping = try parseEvents(std.testing.allocator, "--- {foo: bar}\n");
    defer mapping.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping.events.len);
    try std.testing.expect(mapping.events[1] == .document_start);
    try std.testing.expect(mapping.events[1].document_start.explicit);
    try std.testing.expect(mapping.events[1].document_start.content_same_line);
    try std.testing.expect(mapping.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, mapping.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("foo", mapping.events[3].scalar.value);
    try std.testing.expectEqualStrings("bar", mapping.events[4].scalar.value);
    try std.testing.expectEqual(support.Event.mapping_end, mapping.events[5]);
}

test "parseEvents preserves same-line document start scalar content" {
    var plain = try parseEvents(std.testing.allocator, "--- plain\n");
    defer plain.deinit();

    try std.testing.expectEqual(@as(usize, 5), plain.events.len);
    try std.testing.expect(plain.events[1] == .document_start);
    try std.testing.expect(plain.events[1].document_start.explicit);
    try std.testing.expect(plain.events[1].document_start.content_same_line);
    try std.testing.expectEqual(support.ScalarStyle.plain, plain.events[2].scalar.style);
    try std.testing.expectEqualStrings("plain", plain.events[2].scalar.value);

    var quoted = try parseEvents(std.testing.allocator, "--- \"quoted\"\n");
    defer quoted.deinit();

    try std.testing.expectEqual(@as(usize, 5), quoted.events.len);
    try std.testing.expect(quoted.events[1].document_start.content_same_line);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, quoted.events[2].scalar.style);
    try std.testing.expectEqualStrings("quoted", quoted.events[2].scalar.value);
}

test "parseEvents decodes top-level quoted scalar documents" {
    var single = try parseEvents(std.testing.allocator, "'it''s'\n");
    defer single.deinit();

    try std.testing.expectEqual(@as(usize, 5), single.events.len);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, single.events[2].scalar.style);
    try std.testing.expectEqualStrings("it's", single.events[2].scalar.value);

    var double = try parseEvents(std.testing.allocator, "\"tab\\t omega \\u03A9 smile \\U0001F642\"\n");
    defer double.deinit();

    try std.testing.expectEqual(@as(usize, 5), double.events.len);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, double.events[2].scalar.style);
    try std.testing.expectEqualStrings("tab\t omega \xce\xa9 smile \xf0\x9f\x99\x82", double.events[2].scalar.value);
}

test "parseEvents rejects forbidden quoted scalar marker lines" {
    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\---
        \\"
        \\---
        \\"
        \\
    ));
}

test "parseEvents parses implicit document before explicit directive boundaries" {
    var stream = try parseEvents(std.testing.allocator,
        \\Document
        \\---
        \\# Empty
        \\...
        \\%YAML 1.2
        \\---
        \\matches %: 20
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(!stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("Document", stream.events[2].scalar.value);
    try std.testing.expect(stream.events[3] == .document_end);
    try std.testing.expect(!stream.events[3].document_end.explicit);
    try std.testing.expect(stream.events[4] == .document_start);
    try std.testing.expect(stream.events[4].document_start.explicit);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .document_end);
    try std.testing.expect(stream.events[6].document_end.explicit);
    try std.testing.expect(stream.events[7] == .document_start);
    try std.testing.expect(stream.events[7].document_start.explicit);
    try std.testing.expectEqualStrings("1.2", stream.events[7].document_start.yaml_version.?);
    try std.testing.expect(stream.events[8] == .mapping_start);
    try std.testing.expect(stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("matches %", stream.events[9].scalar.value);
    try std.testing.expect(stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("20", stream.events[10].scalar.value);
    try std.testing.expectEqual(support.Event.mapping_end, stream.events[11]);
    try std.testing.expect(stream.events[12] == .document_end);
    try std.testing.expect(stream.events[13] == .stream_end);
}

test "public API accepts and emits empty YAML streams" {
    var parsed = try yaml.parseEvents(std.testing.allocator, "# comment-only stream\n");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.events.len);
    try std.testing.expectEqual(yaml.Event.stream_start, parsed.events[0]);
    try std.testing.expectEqual(yaml.Event.stream_end, parsed.events[1]);

    var parser = try yaml.Parser.init(std.testing.allocator, "# comment-only stream\n", .{});
    defer parser.deinit();
    try std.testing.expectEqual(yaml.Event.stream_start, (try parser.next()).?);
    try std.testing.expectEqual(yaml.Event.stream_end, (try parser.next()).?);
    try std.testing.expectEqual(@as(?yaml.Event, null), try parser.next());

    var loaded = try yaml.loadStream(std.testing.allocator, "# comment-only stream\n");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.documents.len);

    const emitted = try yaml.emitEvents(std.testing.allocator, parsed.events);
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("", emitted);

    const dumped = try yaml.dumpStream(std.testing.allocator, loaded.documents);
    defer std.testing.allocator.free(dumped);
    try std.testing.expectEqualStrings("", dumped);
}

test "public API treats document-end-only input as an empty stream" {
    var parsed = try yaml.parseEvents(std.testing.allocator,
        \\...
        \\
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.events.len);
    try std.testing.expectEqual(yaml.Event.stream_start, parsed.events[0]);
    try std.testing.expectEqual(yaml.Event.stream_end, parsed.events[1]);

    var parser = try yaml.Parser.init(std.testing.allocator, "...\n", .{});
    defer parser.deinit();
    try std.testing.expectEqual(yaml.Event.stream_start, (try parser.next()).?);
    try std.testing.expectEqual(yaml.Event.stream_end, (try parser.next()).?);
    try std.testing.expectEqual(@as(?yaml.Event, null), try parser.next());

    var loaded = try yaml.loadStream(std.testing.allocator,
        \\...
        \\
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.documents.len);

    const emitted = try yaml.emitEvents(std.testing.allocator, parsed.events);
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("", emitted);

    const dumped = try yaml.dumpStream(std.testing.allocator, loaded.documents);
    defer std.testing.allocator.free(dumped);
    try std.testing.expectEqualStrings("", dumped);
}

test "parseEvents folds property-looking plain scalar continuations" {
    var stream = try parseEvents(std.testing.allocator,
        \\---
        \\k:#foo
        \\ &a !t s
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expect(stream.events[1] == .document_start);
    try std.testing.expect(stream.events[1].document_start.explicit);
    try std.testing.expect(stream.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.plain, stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("k:#foo &a !t s", stream.events[2].scalar.value);
}

test "parseEvents preserves split scalar node properties" {
    var plain_stream = try parseEvents(std.testing.allocator,
        \\&plain
        \\value
        \\
    );
    defer plain_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), plain_stream.events.len);
    try std.testing.expect(plain_stream.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.plain, plain_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("plain", plain_stream.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("value", plain_stream.events[2].scalar.value);

    var quoted_stream = try parseEvents(std.testing.allocator,
        \\!<tag:example.com,2000:scalar>
        \\"value"
        \\
    );
    defer quoted_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), quoted_stream.events.len);
    try std.testing.expect(quoted_stream.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, quoted_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("tag:example.com,2000:scalar", quoted_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", quoted_stream.events[2].scalar.value);

    var block_stream = try parseEvents(std.testing.allocator,
        \\&block
        \\|
        \\  value
        \\
    );
    defer block_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), block_stream.events.len);
    try std.testing.expect(block_stream.events[2] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.literal, block_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("block", block_stream.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("value\n", block_stream.events[2].scalar.value);
}

test "parseEvents parses tab-separated block sequence entries" {
    var stream = try parseEvents(std.testing.allocator, "-\tone\n-\ttwo\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[2].sequence_start.style);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
}

test "parseEvents preserves property-only block sequence entries" {
    var stream = try parseEvents(std.testing.allocator,
        \\-
        \\  &item !<tag:example.com,2000:item>
        \\- next
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("item", stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("next", stream.events[4].scalar.value);
}

test "parseEvents preserves quoted block sequence entry styles" {
    var stream = try parseEvents(std.testing.allocator,
        \\- 'it''s'
        \\- "tab\t"
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("it's", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("tab\t", stream.events[4].scalar.value);
}

test "parseEvents preserves block scalar sequence entry styles" {
    var stream = try parseEvents(std.testing.allocator,
        \\- |
        \\  literal
        \\  text
        \\- >
        \\  folded
        \\  text
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.literal, stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("literal\ntext\n", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.folded, stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("folded text\n", stream.events[4].scalar.value);
}

test "parseEvents preserves block sequence scalar properties and aliases" {
    var stream = try parseEvents(std.testing.allocator,
        \\- &first !<tag:example.com,2000:item> one
        \\-
        \\  &second
        \\  !!str
        \\  two
        \\- *first
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[2].sequence_start.style);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("first", stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("second", stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("two", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .alias);
    try std.testing.expectEqualStrings("first", stream.events[5].alias);
    try std.testing.expect(stream.events[6] == .sequence_end);
}

test "parseEvents preserves top-level block sequence properties" {
    var stream = try parseEvents(std.testing.allocator,
        \\&seq !<tag:example.com,2000:seq>
        \\- one
        \\- two
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("seq", stream.events[2].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", stream.events[2].sequence_start.tag.?);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
}

test "parseEvents preserves indented tagged block sequence entries" {
    var stream = try parseEvents(std.testing.allocator,
        \\ - !!str a
        \\ - b
        \\ - !!int 42
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("a", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("b", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:int", stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("42", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .sequence_end);
}

test "parseEvents preserves nested block sequence descendants" {
    var stream = try parseEvents(std.testing.allocator,
        \\-
        \\  - one
        \\  - two
        \\-
        \\  name: Bob
        \\  age: 42
        \\- done
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 17), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[3].sequence_start.style);
    try std.testing.expectEqualStrings("one", stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("two", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .sequence_end);
    try std.testing.expect(stream.events[7] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[7].mapping_start.style);
    try std.testing.expectEqualStrings("name", stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("Bob", stream.events[9].scalar.value);
    try std.testing.expectEqualStrings("age", stream.events[10].scalar.value);
    try std.testing.expectEqualStrings("42", stream.events[11].scalar.value);
    try std.testing.expect(stream.events[12] == .mapping_end);
    try std.testing.expectEqualStrings("done", stream.events[13].scalar.value);
    try std.testing.expect(stream.events[14] == .sequence_end);
}

test "parseEvents preserves nested block sequence collection properties" {
    var stream = try parseEvents(std.testing.allocator,
        \\-
        \\  &items !<tag:example.com,2000:items>
        \\  - one
        \\- done
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[3].sequence_start.style);
    try std.testing.expectEqualStrings("items", stream.events[3].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", stream.events[3].sequence_start.tag.?);
    try std.testing.expectEqualStrings("one", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
    try std.testing.expectEqualStrings("done", stream.events[6].scalar.value);
}

test "parseEvents preserves recursive block sequence descendants" {
    var stream = try parseEvents(std.testing.allocator,
        \\-
        \\  -
        \\    - one
        \\    - two
        \\- done
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expect(stream.events[3] == .sequence_start);
    try std.testing.expect(stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("one", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("two", stream.events[6].scalar.value);
    try std.testing.expect(stream.events[7] == .sequence_end);
    try std.testing.expect(stream.events[8] == .sequence_end);
    try std.testing.expectEqualStrings("done", stream.events[9].scalar.value);
    try std.testing.expect(stream.events[10] == .sequence_end);
}

test "parseEvents preserves mixed nested block sequence item variants" {
    var stream = try parseEvents(std.testing.allocator,
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
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 29), stream.events.len);
    try std.testing.expectEqualStrings("a", stream.events[4].scalar.anchor.?);
    try std.testing.expect(stream.events[6] == .sequence_start);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, stream.events[7].scalar.style);
    try std.testing.expectEqualStrings("quoted", stream.events[7].scalar.value);
    try std.testing.expectEqual(support.ScalarStyle.literal, stream.events[8].scalar.style);
    try std.testing.expectEqualStrings("literal\n", stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("a", stream.events[9].alias);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[10].sequence_start.style);
    try std.testing.expectEqualStrings("flow", stream.events[11].scalar.value);
    try std.testing.expectEqualStrings("key", stream.events[14].scalar.value);
    try std.testing.expectEqualStrings("value", stream.events[15].scalar.value);
    try std.testing.expectEqualStrings("explicit", stream.events[18].scalar.value);
    try std.testing.expectEqualStrings("entry", stream.events[19].scalar.value);
    try std.testing.expectEqualStrings("", stream.events[21].scalar.value);
    try std.testing.expectEqualStrings("nested", stream.events[22].scalar.value);
    try std.testing.expectEqualStrings("tail", stream.events[24].scalar.value);
    try std.testing.expectEqualStrings("done", stream.events[25].scalar.value);
}

test "parseEvents preserves indentless sequence compact mapping variants" {
    var event_stream = try parseEvents(std.testing.allocator,
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
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expectEqualStrings("explicit", event_stream.events[10].scalar.value);
    try std.testing.expectEqualStrings("entry", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
    try std.testing.expectEqualStrings("tail", event_stream.events[14].scalar.value);
    try std.testing.expectEqualStrings("done", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .mapping_end);
}

test "parseEvents preserves indentless sequence scalar alias and flow variants" {
    var event_stream = try parseEvents(std.testing.allocator,
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
    try std.testing.expectEqualStrings("items", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, event_stream.events[7].scalar.style);
    try std.testing.expectEqualStrings("quoted", event_stream.events[7].scalar.value);
    try std.testing.expectEqual(support.ScalarStyle.literal, event_stream.events[8].scalar.style);
    try std.testing.expectEqualStrings("literal\n", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .alias);
    try std.testing.expectEqualStrings("a", event_stream.events[9].alias);
    try std.testing.expect(event_stream.events[10] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[10].sequence_start.style);
    try std.testing.expectEqualStrings("flow", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .sequence_end);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
}

test "parseEvents preserves indentless sequence nested collection variants" {
    var event_stream = try parseEvents(std.testing.allocator,
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
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expect(event_stream.events[5] == .sequence_start);
    try std.testing.expectEqualStrings("nested", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expectEqualStrings("name", event_stream.events[9].scalar.value);
    try std.testing.expectEqualStrings("nested mapping", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expectEqualStrings("empty", event_stream.events[12].scalar.anchor.?);
    try std.testing.expectEqualStrings("", event_stream.events[12].scalar.value);
}

test "parseEvents rejects indentless sequence alias items with node properties" {
    try std.testing.expectError(error.InvalidSyntax, parseEvents(std.testing.allocator,
        \\anchor: &a value
        \\items:
        \\- &bad *a
        \\
    ));
}

test "parseEvents preserves compact block mapping pairs and key properties" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\- name: Mark
        \\  hr: 65
        \\- &key key: value
        \\- !tag : tagged
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 20), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("Mark", event_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("hr", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("65", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[10].scalar.anchor.?);
    try std.testing.expectEqualStrings("key", event_stream.events[10].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .mapping_start);
    try std.testing.expectEqualStrings("!tag", event_stream.events[14].scalar.tag.?);
    try std.testing.expectEqualStrings("", event_stream.events[14].scalar.value);
    try std.testing.expectEqualStrings("tagged", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[16] == .mapping_end);
    try std.testing.expect(event_stream.events[17] == .sequence_end);
}

test "parseEvents preserves omitted implicit keys in compact block mappings" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\- :
        \\- : value
        \\- first: one
        \\  : two
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 20), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[11] == .mapping_start);
    try std.testing.expectEqualStrings("first", event_stream.events[12].scalar.value);
    try std.testing.expectEqualStrings("one", event_stream.events[13].scalar.value);
    try std.testing.expectEqualStrings("", event_stream.events[14].scalar.value);
    try std.testing.expectEqualStrings("two", event_stream.events[15].scalar.value);
    try std.testing.expect(event_stream.events[17] == .sequence_end);
}

test "parseEvents folds compact block mapping scalar continuations" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\- name: Mark
        \\  note: a
        \\    b
        \\- note: first line
        \\    - still scalar text
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("name", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("Mark", event_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("note", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("a b", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expectEqualStrings("note", event_stream.events[10].scalar.value);
    try std.testing.expectEqualStrings("first line - still scalar text", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
}

test "parseEvents preserves compact explicit mapping keys in block sequences" {
    var empty_key_stream = try parseEvents(std.testing.allocator, "- ? : x\n");
    defer empty_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), empty_key_stream.events.len);
    try std.testing.expect(empty_key_stream.events[2] == .sequence_start);
    try std.testing.expect(empty_key_stream.events[3] == .mapping_start);
    try std.testing.expect(empty_key_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("", empty_key_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("x", empty_key_stream.events[6].scalar.value);
    try std.testing.expect(empty_key_stream.events[7] == .mapping_end);
    try std.testing.expectEqualStrings("", empty_key_stream.events[8].scalar.value);
    try std.testing.expect(empty_key_stream.events[9] == .mapping_end);
    try std.testing.expect(empty_key_stream.events[10] == .sequence_end);

    var omitted_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\  : value
        \\
    );
    defer omitted_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), omitted_key_stream.events.len);
    try std.testing.expect(omitted_key_stream.events[2] == .sequence_start);
    try std.testing.expect(omitted_key_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("", omitted_key_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", omitted_key_stream.events[5].scalar.value);
    try std.testing.expect(omitted_key_stream.events[6] == .mapping_end);
    try std.testing.expect(omitted_key_stream.events[7] == .sequence_end);
}

test "parseEvents preserves following-line compact explicit mapping values" {
    var flow_key_stream = try parseEvents(std.testing.allocator,
        \\- ? [key]
        \\  : value
        \\
    );
    defer flow_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), flow_key_stream.events.len);
    try std.testing.expect(flow_key_stream.events[2] == .sequence_start);
    try std.testing.expect(flow_key_stream.events[3] == .mapping_start);
    try std.testing.expect(flow_key_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_key_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("key", flow_key_stream.events[5].scalar.value);
    try std.testing.expect(flow_key_stream.events[6] == .sequence_end);
    try std.testing.expectEqualStrings("value", flow_key_stream.events[7].scalar.value);
    try std.testing.expect(flow_key_stream.events[8] == .mapping_end);
}

test "parseEvents folds compact explicit multiline scalar keys" {
    var plain_key_stream = try parseEvents(std.testing.allocator,
        \\- ? multi
        \\    line
        \\  : value
        \\
    );
    defer plain_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), plain_key_stream.events.len);
    try std.testing.expect(plain_key_stream.events[2] == .sequence_start);
    try std.testing.expect(plain_key_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("multi line", plain_key_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", plain_key_stream.events[5].scalar.value);
    try std.testing.expect(plain_key_stream.events[6] == .mapping_end);

    var quoted_key_stream = try parseEvents(std.testing.allocator,
        \\- ? 'multi
        \\    line'
        \\  : value
        \\
    );
    defer quoted_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), quoted_key_stream.events.len);
    try std.testing.expect(quoted_key_stream.events[2] == .sequence_start);
    try std.testing.expect(quoted_key_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, quoted_key_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("multi line", quoted_key_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", quoted_key_stream.events[5].scalar.value);
}

test "parseEvents rejects compact explicit multiline keys with same-line values" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- ? multi
        \\    line: value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- ? [multi,
        \\    line]: value
        \\
    ));
}

test "parseEvents preserves compact explicit mappings with comments before values" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\- ? key
        \\  # key comment
        \\  : value
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("key", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
}

test "parseEvents preserves compact explicit nested collection keys" {
    var mapping_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\    key: nested
        \\  : value
        \\
    );
    defer mapping_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), mapping_key_stream.events.len);
    try std.testing.expect(mapping_key_stream.events[2] == .sequence_start);
    try std.testing.expect(mapping_key_stream.events[3] == .mapping_start);
    try std.testing.expect(mapping_key_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", mapping_key_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("nested", mapping_key_stream.events[6].scalar.value);
    try std.testing.expect(mapping_key_stream.events[7] == .mapping_end);
    try std.testing.expectEqualStrings("value", mapping_key_stream.events[8].scalar.value);

    var sequence_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\    - nested
        \\  : value
        \\
    );
    defer sequence_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), sequence_key_stream.events.len);
    try std.testing.expect(sequence_key_stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("nested", sequence_key_stream.events[5].scalar.value);
    try std.testing.expect(sequence_key_stream.events[6] == .sequence_end);
    try std.testing.expectEqualStrings("value", sequence_key_stream.events[7].scalar.value);
}

test "parseEvents preserves separated properties on compact explicit nested keys" {
    var flow_mapping_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\  &key
        \\  # key node comment
        \\    {nested: key}
        \\  : value
        \\
    );
    defer flow_mapping_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), flow_mapping_key_stream.events.len);
    try std.testing.expect(flow_mapping_key_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_mapping_key_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("key", flow_mapping_key_stream.events[4].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("nested", flow_mapping_key_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("key", flow_mapping_key_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("value", flow_mapping_key_stream.events[8].scalar.value);

    var sequence_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\  &key
        \\  !<tag:example.com,2000:seq>
        \\    - nested
        \\  : value
        \\
    );
    defer sequence_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), sequence_key_stream.events.len);
    try std.testing.expect(sequence_key_stream.events[4] == .sequence_start);
    try std.testing.expectEqualStrings("key", sequence_key_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", sequence_key_stream.events[4].sequence_start.tag.?);
    try std.testing.expectEqualStrings("nested", sequence_key_stream.events[5].scalar.value);
}

test "parseEvents preserves compact explicit scalar and block scalar keys" {
    var scalar_key_stream = try parseEvents(std.testing.allocator,
        \\- ?
        \\  &key
        \\    nested
        \\  : value
        \\
    );
    defer scalar_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), scalar_key_stream.events.len);
    try std.testing.expectEqualStrings("key", scalar_key_stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("nested", scalar_key_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", scalar_key_stream.events[5].scalar.value);

    var block_scalar_key_stream = try parseEvents(std.testing.allocator,
        \\- ? >2
        \\    folded
        \\  : value
        \\
    );
    defer block_scalar_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), block_scalar_key_stream.events.len);
    try std.testing.expectEqual(support.ScalarStyle.folded, block_scalar_key_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("folded\n", block_scalar_key_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("value", block_scalar_key_stream.events[5].scalar.value);
}

test "parseEvents preserves compact mapping nodes in compact explicit entries" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\- sun: yellow
        \\- ? earth: blue
        \\  : moon: white
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 20), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .mapping_start);
    try std.testing.expectEqualStrings("sun", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("yellow", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_start);
    try std.testing.expect(event_stream.events[8] == .mapping_start);
    try std.testing.expectEqualStrings("earth", event_stream.events[9].scalar.value);
    try std.testing.expectEqualStrings("blue", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_start);
    try std.testing.expectEqualStrings("moon", event_stream.events[13].scalar.value);
    try std.testing.expectEqualStrings("white", event_stream.events[14].scalar.value);
    try std.testing.expect(event_stream.events[17] == .sequence_end);
}

test "parseEvents preserves compact and zero-indented explicit mapping keys" {
    var compact_stream = try parseEvents(std.testing.allocator, "? []: x\n");
    defer compact_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), compact_stream.events.len);
    try std.testing.expect(compact_stream.events[2] == .mapping_start);
    try std.testing.expect(compact_stream.events[3] == .mapping_start);
    try std.testing.expect(compact_stream.events[4] == .sequence_start);
    try std.testing.expect(compact_stream.events[5] == .sequence_end);
    try std.testing.expectEqualStrings("x", compact_stream.events[6].scalar.value);
    try std.testing.expect(compact_stream.events[7] == .mapping_end);
    try std.testing.expectEqualStrings("", compact_stream.events[8].scalar.value);

    var sequence_stream = try parseEvents(std.testing.allocator,
        \\---
        \\?
        \\- a
        \\- b
        \\:
        \\- c
        \\- d
        \\
    );
    defer sequence_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), sequence_stream.events.len);
    try std.testing.expect(sequence_stream.events[1].document_start.explicit);
    try std.testing.expect(sequence_stream.events[3] == .sequence_start);
    try std.testing.expectEqualStrings("a", sequence_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("b", sequence_stream.events[5].scalar.value);
    try std.testing.expect(sequence_stream.events[6] == .sequence_end);
    try std.testing.expect(sequence_stream.events[7] == .sequence_start);
    try std.testing.expectEqualStrings("c", sequence_stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("d", sequence_stream.events[9].scalar.value);
    try std.testing.expect(sequence_stream.events[10] == .sequence_end);
}

test "parseEvents preserves block scalar explicit mapping key metadata" {
    var stream = try parseEvents(std.testing.allocator,
        \\?
        \\  &key
        \\  !<tag:example.com,2000:key>
        \\  |
        \\    literal key
        \\: value
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.literal, stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key", stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("literal key\n", stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("value", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .mapping_end);
}

test "parseEvents preserves nested explicit mapping key nodes" {
    var collection_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ?
        \\    {a: b}
        \\  : value
        \\
    );
    defer collection_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), collection_stream.events.len);
    try std.testing.expectEqualStrings("outer", collection_stream.events[3].scalar.value);
    try std.testing.expect(collection_stream.events[4] == .mapping_start);
    try std.testing.expect(collection_stream.events[5] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, collection_stream.events[5].mapping_start.style);
    try std.testing.expectEqualStrings("a", collection_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("b", collection_stream.events[7].scalar.value);
    try std.testing.expect(collection_stream.events[8] == .mapping_end);
    try std.testing.expectEqualStrings("value", collection_stream.events[9].scalar.value);

    var property_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ?
        \\    &key !<tag:example.com,2000:key>
        \\  : value
        \\
    );
    defer property_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), property_stream.events.len);
    try std.testing.expectEqualStrings("outer", property_stream.events[3].scalar.value);
    try std.testing.expect(property_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("key", property_stream.events[5].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", property_stream.events[5].scalar.tag.?);
    try std.testing.expectEqualStrings("", property_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("value", property_stream.events[6].scalar.value);
}

test "parseEvents preserves plain block mapping keys and values" {
    var stream = try parseEvents(std.testing.allocator,
        \\foo: bar
        \\baz: qux
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("foo", stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("bar", stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("baz", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("qux", stream.events[6].scalar.value);
    try std.testing.expect(stream.events[7] == .mapping_end);
}

test "parseEvents preserves folded explicit mapping keys and omitted values" {
    var folded_stream = try parseEvents(std.testing.allocator,
        \\? >
        \\  folded
        \\:
        \\
    );
    defer folded_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), folded_stream.events.len);
    try std.testing.expect(folded_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.ScalarStyle.folded, folded_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("folded\n", folded_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("", folded_stream.events[4].scalar.value);

    var omitted_stream = try parseEvents(std.testing.allocator,
        \\?
        \\: value
        \\? key
        \\:
        \\
    );
    defer omitted_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), omitted_stream.events.len);
    try std.testing.expect(omitted_stream.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("", omitted_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("value", omitted_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("key", omitted_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("", omitted_stream.events[6].scalar.value);
}

test "parseEvents preserves explicit mapping key properties" {
    var property_only_stream = try parseEvents(std.testing.allocator,
        \\?
        \\  &key !<tag:example.com,2000:key>
        \\: value
        \\
    );
    defer property_only_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), property_only_stream.events.len);
    try std.testing.expect(property_only_stream.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("key", property_only_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", property_only_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("", property_only_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("value", property_only_stream.events[4].scalar.value);

    var scalar_property_stream = try parseEvents(std.testing.allocator,
        \\?
        \\  &key
        \\  !<tag:example.com,2000:key>
        \\  name
        \\: value
        \\
    );
    defer scalar_property_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), scalar_property_stream.events.len);
    try std.testing.expect(scalar_property_stream.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("key", scalar_property_stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", scalar_property_stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("name", scalar_property_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("value", scalar_property_stream.events[4].scalar.value);
}

test "parseEvents preserves complex flow collection explicit mapping keys" {
    var flow_mapping_stream = try parseEvents(std.testing.allocator,
        \\?
        \\  {nested: key}
        \\: value
        \\
    );
    defer flow_mapping_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), flow_mapping_stream.events.len);
    try std.testing.expect(flow_mapping_stream.events[2] == .mapping_start);
    try std.testing.expect(flow_mapping_stream.events[3] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_mapping_stream.events[3].mapping_start.style);
    try std.testing.expectEqualStrings("nested", flow_mapping_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("key", flow_mapping_stream.events[5].scalar.value);
    try std.testing.expect(flow_mapping_stream.events[6] == .mapping_end);
    try std.testing.expectEqualStrings("value", flow_mapping_stream.events[7].scalar.value);

    var flow_sequence_stream = try parseEvents(std.testing.allocator,
        \\?
        \\  [
        \\    a,
        \\    b
        \\  ]
        \\: value
        \\
    );
    defer flow_sequence_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), flow_sequence_stream.events.len);
    try std.testing.expect(flow_sequence_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_sequence_stream.events[3].sequence_start.style);
    try std.testing.expectEqualStrings("a", flow_sequence_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("b", flow_sequence_stream.events[5].scalar.value);
    try std.testing.expect(flow_sequence_stream.events[6] == .sequence_end);
    try std.testing.expectEqualStrings("value", flow_sequence_stream.events[7].scalar.value);
}

test "parseEvents preserves separated properties on flow explicit mapping keys" {
    var stream = try parseEvents(std.testing.allocator,
        \\? &key !<tag:example.com,2000:key>
        \\  {nested: key}
        \\: value
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), stream.events.len);
    try std.testing.expect(stream.events[3] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[3].mapping_start.style);
    try std.testing.expectEqualStrings("key", stream.events[3].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", stream.events[3].mapping_start.tag.?);
    try std.testing.expectEqualStrings("nested", stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("key", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("value", stream.events[7].scalar.value);
}

test "parseEvents preserves multiline explicit mapping keys and values" {
    var stream = try parseEvents(std.testing.allocator,
        \\? a
        \\  true
        \\: null
        \\  d
        \\? e
        \\  42
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("a true", stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("null d", stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("e 42", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("", stream.events[6].scalar.value);
    try std.testing.expect(stream.events[7] == .mapping_end);
}

test "parseEvents rejects invalid alias explicit mapping keys" {
    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\?
        \\  &key
        \\  *anchor
        \\: value
        \\
    ));

    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\? *anchor
        \\  trailing
        \\: value
        \\
    ));
}

test "parseEvents parses tab-separated block mapping values" {
    var key_stream = try parseEvents(std.testing.allocator, "key\t: value\n");
    defer key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), key_stream.events.len);
    try std.testing.expect(key_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, key_stream.events[2].mapping_start.style);
    try std.testing.expect(key_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", key_stream.events[3].scalar.value);
    try std.testing.expect(key_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", key_stream.events[4].scalar.value);

    var value_stream = try parseEvents(std.testing.allocator, "other:\titem\n");
    defer value_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), value_stream.events.len);
    try std.testing.expect(value_stream.events[2] == .mapping_start);
    try std.testing.expect(value_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("other", value_stream.events[3].scalar.value);
    try std.testing.expect(value_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("item", value_stream.events[4].scalar.value);
}

test "parseEvents parses explicit block mapping values with compact sequences" {
    var stream = try parseEvents(std.testing.allocator, "? a\n" ++
        ": -\tb\n" ++
        "  -  -\tc\n" ++
        "     - d\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("a", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, stream.events[4].sequence_start.style);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("b", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .sequence_start);
    try std.testing.expect(stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("c", stream.events[7].scalar.value);
    try std.testing.expect(stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("d", stream.events[8].scalar.value);
    try std.testing.expect(stream.events[9] == .sequence_end);
    try std.testing.expect(stream.events[10] == .sequence_end);
}

test "parseEvents preserves quoted block mapping scalar styles" {
    var stream = try parseEvents(std.testing.allocator,
        \\"key\n": 'value'
        \\'other': "line\n"
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key\n", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("value", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, stream.events[5].scalar.style);
    try std.testing.expectEqualStrings("other", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("line\n", stream.events[6].scalar.value);
}

test "parseEvents preserves block mapping scalar node properties" {
    var stream = try parseEvents(std.testing.allocator,
        \\&key !<tag:example.com,2000:key> name: &value !!str Bob
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", stream.events[3].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:key", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("name", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", stream.events[4].scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", stream.events[4].scalar.tag.?);
    try std.testing.expectEqualStrings("Bob", stream.events[4].scalar.value);
}

test "parseEvents preserves nested block mapping flow keys and collection values" {
    var flow_key_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  [a, b]: value
        \\
    );
    defer flow_key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), flow_key_stream.events.len);
    try std.testing.expect(flow_key_stream.events[4] == .mapping_start);
    try std.testing.expect(flow_key_stream.events[5] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_key_stream.events[5].sequence_start.style);
    try std.testing.expectEqualStrings("a", flow_key_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("b", flow_key_stream.events[7].scalar.value);
    try std.testing.expect(flow_key_stream.events[8] == .sequence_end);
    try std.testing.expectEqualStrings("value", flow_key_stream.events[9].scalar.value);

    var flow_value_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ? key
        \\  : [a, b]
        \\
    );
    defer flow_value_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), flow_value_stream.events.len);
    try std.testing.expect(flow_value_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", flow_value_stream.events[5].scalar.value);
    try std.testing.expect(flow_value_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, flow_value_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("a", flow_value_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("b", flow_value_stream.events[8].scalar.value);
}

test "parseEvents preserves nested explicit block mapping collection values" {
    var sequence_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ? key
        \\  :
        \\    - item
        \\
    );
    defer sequence_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), sequence_stream.events.len);
    try std.testing.expect(sequence_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", sequence_stream.events[5].scalar.value);
    try std.testing.expect(sequence_stream.events[6] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, sequence_stream.events[6].sequence_start.style);
    try std.testing.expectEqualStrings("item", sequence_stream.events[7].scalar.value);
    try std.testing.expect(sequence_stream.events[8] == .sequence_end);

    var mapping_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ? key
        \\  :
        \\    inner: value
        \\
    );
    defer mapping_stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), mapping_stream.events.len);
    try std.testing.expect(mapping_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("key", mapping_stream.events[5].scalar.value);
    try std.testing.expect(mapping_stream.events[6] == .mapping_start);
    try std.testing.expectEqualStrings("inner", mapping_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("value", mapping_stream.events[8].scalar.value);
    try std.testing.expect(mapping_stream.events[9] == .mapping_end);
}

test "parseEvents preserves nested block sequence values with split properties" {
    var indentless_stream = try parseEvents(std.testing.allocator,
        \\seq:
        \\ &anchor
        \\- a
        \\- b
        \\
    );
    defer indentless_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), indentless_stream.events.len);
    try std.testing.expectEqualStrings("seq", indentless_stream.events[3].scalar.value);
    try std.testing.expect(indentless_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, indentless_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("anchor", indentless_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("a", indentless_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("b", indentless_stream.events[6].scalar.value);

    var property_stream = try parseEvents(std.testing.allocator,
        \\items:
        \\  &items !<tag:example.com,2000:items>
        \\  - one
        \\tail: done
        \\
    );
    defer property_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), property_stream.events.len);
    try std.testing.expectEqualStrings("items", property_stream.events[3].scalar.value);
    try std.testing.expect(property_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.block, property_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("items", property_stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", property_stream.events[4].sequence_start.tag.?);
    try std.testing.expectEqualStrings("one", property_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("tail", property_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("done", property_stream.events[8].scalar.value);
}

test "parseEvents preserves nested block mapping values with split properties" {
    var property_stream = try parseEvents(std.testing.allocator,
        \\person:
        \\  &person !<tag:example.com,2000:person>
        \\  name: Bob
        \\tail: done
        \\
    );
    defer property_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), property_stream.events.len);
    try std.testing.expectEqualStrings("person", property_stream.events[3].scalar.value);
    try std.testing.expect(property_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, property_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("person", property_stream.events[4].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:person", property_stream.events[4].mapping_start.tag.?);
    try std.testing.expectEqualStrings("name", property_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("Bob", property_stream.events[6].scalar.value);
    try std.testing.expect(property_stream.events[7] == .mapping_end);
    try std.testing.expectEqualStrings("tail", property_stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("done", property_stream.events[9].scalar.value);

    var split_stream = try parseEvents(std.testing.allocator,
        \\key: &anchor
        \\ !!map
        \\  a: b
        \\
    );
    defer split_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), split_stream.events.len);
    try std.testing.expectEqualStrings("key", split_stream.events[3].scalar.value);
    try std.testing.expect(split_stream.events[4] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.block, split_stream.events[4].mapping_start.style);
    try std.testing.expectEqualStrings("anchor", split_stream.events[4].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", split_stream.events[4].mapping_start.tag.?);
    try std.testing.expectEqualStrings("a", split_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("b", split_stream.events[6].scalar.value);
}

test "parseEvents preserves nested block mappings with omitted implicit keys" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  : value
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expectEqualStrings("outer", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expectEqualStrings("", event_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("value", event_stream.events[6].scalar.value);
}

test "parseEvents preserves split properties before nested explicit block mapping keys" {
    var stream = try parseEvents(std.testing.allocator,
        \\outer:
        \\  ? &anchor
        \\    !!map
        \\    a: b
        \\  : value
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 14), stream.events.len);
    try std.testing.expect(stream.events[4] == .mapping_start);
    try std.testing.expect(stream.events[5] == .mapping_start);
    try std.testing.expectEqual(CollectionStyle.block, stream.events[5].mapping_start.style);
    try std.testing.expectEqualStrings("anchor", stream.events[5].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", stream.events[5].mapping_start.tag.?);
    try std.testing.expectEqualStrings("a", stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("b", stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("value", stream.events[9].scalar.value);
}

test "parseEvents preserves nested explicit omitted values before anchored keys" {
    var stream = try parseEvents(std.testing.allocator,
        \\root:
        \\  ? b
        \\  &anchor c: 3
        \\tail: done
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), stream.events.len);
    try std.testing.expectEqualStrings("b", stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("", stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("anchor", stream.events[7].scalar.anchor.?);
    try std.testing.expectEqualStrings("c", stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("3", stream.events[8].scalar.value);
}

test "parseEvents preserves explicit mapping entries between sequences" {
    var stream = try parseEvents(std.testing.allocator,
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
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 22), stream.events.len);
    try std.testing.expectEqual(CollectionStyle.block, stream.events[3].sequence_start.style);
    try std.testing.expectEqualStrings("Detroit Tigers", stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("Chicago cubs", stream.events[5].scalar.value);
    try std.testing.expectEqual(CollectionStyle.block, stream.events[7].sequence_start.style);
    try std.testing.expectEqualStrings("2001-07-23", stream.events[8].scalar.value);
    try std.testing.expectEqual(CollectionStyle.flow, stream.events[10].sequence_start.style);
    try std.testing.expectEqualStrings("New York Yankees", stream.events[11].scalar.value);
    try std.testing.expectEqualStrings("Atlanta Braves", stream.events[12].scalar.value);
    try std.testing.expectEqual(CollectionStyle.flow, stream.events[14].sequence_start.style);
    try std.testing.expectEqualStrings("2001-08-14", stream.events[17].scalar.value);
}

test "parseEvents preserves split flow collection node properties" {
    var sequence_stream = try parseEvents(std.testing.allocator,
        \\&items
        \\[one]
        \\
    );
    defer sequence_stream.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_stream.events.len);
    try std.testing.expect(sequence_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, sequence_stream.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("items", sequence_stream.events[2].sequence_start.anchor.?);
    try std.testing.expect(sequence_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence_stream.events[3].scalar.value);
    try std.testing.expect(sequence_stream.events[4] == .sequence_end);

    var mapping_stream = try parseEvents(std.testing.allocator,
        \\!<tag:example.com,2000:root>
        \\{key: value}
        \\
    );
    defer mapping_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_stream.events.len);
    try std.testing.expect(mapping_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, mapping_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("tag:example.com,2000:root", mapping_stream.events[2].mapping_start.tag.?);
    try std.testing.expect(mapping_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", mapping_stream.events[3].scalar.value);
    try std.testing.expect(mapping_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", mapping_stream.events[4].scalar.value);
    try std.testing.expect(mapping_stream.events[5] == .mapping_end);
}

test "parseEvents preserves separated tags before nested flow collection values" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\!!map {
        \\  k: !!seq
        \\  [ a, !!str b]
        \\}
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", event_stream.events[2].mapping_start.tag.?);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("k", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:seq", event_stream.events[4].sequence_start.tag.?);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("a", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[6].scalar.tag.?);
    try std.testing.expectEqualStrings("b", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .mapping_end);
}

test "parseEvents preserves quoted scalars in flow sequences" {
    var stream = try parseEvents(std.testing.allocator, "['it''s', \"tab\\t\"]\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[2].sequence_start.style);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("it's", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("tab\t", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
}

test "parseEvents preserves alias entries in flow sequences" {
    var stream = try parseEvents(std.testing.allocator, "[*anchor, plain]\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[2].sequence_start.style);
    try std.testing.expect(stream.events[3] == .alias);
    try std.testing.expectEqualStrings("anchor", stream.events[3].alias);
    try std.testing.expect(stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("plain", stream.events[4].scalar.value);
    try std.testing.expect(stream.events[5] == .sequence_end);
}

test "parseEvents preserves tagged scalar entries in flow sequences" {
    var stream = try parseEvents(std.testing.allocator, "[!<tag:example.com,2000:item> one]\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 7), stream.events.len);
    try std.testing.expect(stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[2].sequence_start.style);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:item", stream.events[3].scalar.tag.?);
    try std.testing.expectEqualStrings("one", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .sequence_end);
}

test "parseEvents preserves properties on top-level flow collections" {
    var sequence_stream = try parseEvents(std.testing.allocator, "&seq !<tag:example.com,2000:seq> [one]\n");
    defer sequence_stream.deinit();
    try std.testing.expectEqual(@as(usize, 7), sequence_stream.events.len);
    try std.testing.expect(sequence_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, sequence_stream.events[2].sequence_start.style);
    try std.testing.expectEqualStrings("seq", sequence_stream.events[2].sequence_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:seq", sequence_stream.events[2].sequence_start.tag.?);

    var mapping_stream = try parseEvents(std.testing.allocator, "!<tag:example.com,2000:map> &map {key: value}\n");
    defer mapping_stream.deinit();
    try std.testing.expectEqual(@as(usize, 8), mapping_stream.events.len);
    try std.testing.expect(mapping_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, mapping_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("map", mapping_stream.events[2].mapping_start.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", mapping_stream.events[2].mapping_start.tag.?);
}

test "parseEvents preserves multiline implicit flow mapping keys and values" {
    var key_stream = try parseEvents(std.testing.allocator,
        \\{
        \\multi
        \\ line: value
        \\}
        \\
    );
    defer key_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), key_stream.events.len);
    try std.testing.expect(key_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, key_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("multi line", key_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("value", key_stream.events[4].scalar.value);
    try std.testing.expect(key_stream.events[5] == .mapping_end);

    var value_stream = try parseEvents(std.testing.allocator,
        \\{
        \\foo: bar
        \\ baz
        \\}
        \\
    );
    defer value_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), value_stream.events.len);
    try std.testing.expect(value_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, value_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("foo", value_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("bar baz", value_stream.events[4].scalar.value);
    try std.testing.expect(value_stream.events[5] == .mapping_end);
}

test "parseEvents preserves percent-started flow mapping key continuations" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\---
        \\{ matches
        \\% : 20 }
        \\...
        \\---
        \\# Empty
        \\...
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 11), event_stream.events.len);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("matches %", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("20", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6].document_end.explicit);
    try std.testing.expect(event_stream.events[7].document_start.explicit);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9].document_end.explicit);
}

test "parseEvents preserves flow mapping nested values and quoted scalar styles" {
    var nested_stream = try parseEvents(std.testing.allocator, "{foo: [bar, baz], qux: corge}\n");
    defer nested_stream.deinit();

    try std.testing.expectEqual(@as(usize, 13), nested_stream.events.len);
    try std.testing.expect(nested_stream.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("foo", nested_stream.events[3].scalar.value);
    try std.testing.expect(nested_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, nested_stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("bar", nested_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("baz", nested_stream.events[6].scalar.value);
    try std.testing.expect(nested_stream.events[7] == .sequence_end);
    try std.testing.expectEqualStrings("qux", nested_stream.events[8].scalar.value);
    try std.testing.expectEqualStrings("corge", nested_stream.events[9].scalar.value);

    var quoted_stream = try parseEvents(std.testing.allocator, "{\"key\\n\": 'value'}\n");
    defer quoted_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), quoted_stream.events.len);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, quoted_stream.events[3].scalar.style);
    try std.testing.expectEqualStrings("key\n", quoted_stream.events[3].scalar.value);
    try std.testing.expectEqual(support.ScalarStyle.single_quoted, quoted_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("value", quoted_stream.events[4].scalar.value);
}

test "parseEvents rejects invalid flow mapping entries" {
    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "{a: b,, c: d}\n"));
    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "{, a: b}\n"));
    try std.testing.expectError(support.ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "{|: value}\n"));
}

test "parseEvents preserves properties on nested flow collections" {
    var stream = try parseEvents(std.testing.allocator, "{seq: &seq [one], map: !<tag:example.com,2000:map> {key: value}}\n");
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 15), stream.events.len);
    try std.testing.expect(stream.events[2] == .mapping_start);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("seq", stream.events[3].scalar.value);
    try std.testing.expect(stream.events[4] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[4].sequence_start.style);
    try std.testing.expectEqualStrings("seq", stream.events[4].sequence_start.anchor.?);
    try std.testing.expectEqual(@as(?[]const u8, null), stream.events[4].sequence_start.tag);
    try std.testing.expect(stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", stream.events[5].scalar.value);
    try std.testing.expect(stream.events[6] == .sequence_end);
    try std.testing.expect(stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("map", stream.events[7].scalar.value);
    try std.testing.expect(stream.events[8] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, stream.events[8].mapping_start.style);
    try std.testing.expectEqual(@as(?[]const u8, null), stream.events[8].mapping_start.anchor);
    try std.testing.expectEqualStrings("tag:example.com,2000:map", stream.events[8].mapping_start.tag.?);
    try std.testing.expect(stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("key", stream.events[9].scalar.value);
    try std.testing.expect(stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("value", stream.events[10].scalar.value);
    try std.testing.expect(stream.events[11] == .mapping_end);
    try std.testing.expect(stream.events[12] == .mapping_end);
}

test "parseEvents preserves property-only flow sequence entries as empty nodes" {
    var event_stream = try parseEvents(std.testing.allocator, "[!!str, &anchor, *anchor]\n");
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", event_stream.events[3].scalar.tag.?);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("anchor", event_stream.events[4].scalar.anchor.?);
    try std.testing.expect(event_stream.events[5] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[5].alias);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
}

test "parseEvents preserves empty flow mapping values" {
    var event_stream = try parseEvents(std.testing.allocator, "{foo: , bar: baz}\n");
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("bar", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("baz", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .mapping_end);
}

test "parseEvents preserves omitted flow mapping values" {
    var event_stream = try parseEvents(std.testing.allocator,
        \\{
        \\unquoted : "separate",
        \\http://foo.com,
        \\omitted value:,
        \\}
        \\
    );
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 12), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("unquoted", event_stream.events[3].scalar.value);
    try std.testing.expectEqual(support.ScalarStyle.double_quoted, event_stream.events[4].scalar.style);
    try std.testing.expectEqualStrings("separate", event_stream.events[4].scalar.value);
    try std.testing.expectEqualStrings("http://foo.com", event_stream.events[5].scalar.value);
    try std.testing.expectEqualStrings("", event_stream.events[6].scalar.value);
    try std.testing.expectEqualStrings("omitted value", event_stream.events[7].scalar.value);
    try std.testing.expectEqualStrings("", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_end);
}

test "parseEvents preserves trailing omitted flow mapping values" {
    var event_stream = try parseEvents(std.testing.allocator, "{foo:}\n");
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expectEqual(support.CollectionStyle.flow, event_stream.events[2].mapping_start.style);
    try std.testing.expectEqualStrings("foo", event_stream.events[3].scalar.value);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
}

test "Parser.next iterates multi-document streams in event order" {
    var parser = try support.yaml.Parser.init(std.testing.allocator,
        \\--- one
        \\--- [two]
        \\
    , .{});
    defer parser.deinit();

    try std.testing.expectEqual(support.Event.stream_start, (try parser.next()).?);
    try std.testing.expect((try parser.next()).? == .document_start);
    try std.testing.expectEqualStrings("one", (try parser.next()).?.scalar.value);
    try std.testing.expect((try parser.next()).? == .document_end);
    try std.testing.expect((try parser.next()).? == .document_start);
    try std.testing.expect((try parser.next()).? == .sequence_start);
    try std.testing.expectEqualStrings("two", (try parser.next()).?.scalar.value);
    try std.testing.expectEqual(support.Event.sequence_end, (try parser.next()).?);
    try std.testing.expect((try parser.next()).? == .document_end);
    try std.testing.expectEqual(support.Event.stream_end, (try parser.next()).?);
    try std.testing.expectEqual(@as(?support.Event, null), try parser.next());
}

test "Parser.init clears diagnostics after successful parse" {
    var diagnostic: Diagnostic = .{
        .message = "previous failure",
        .offset = 7,
        .line = 2,
        .column = 3,
    };

    var parser = try support.yaml.Parser.init(std.testing.allocator, "value\n", .{
        .diagnostic = &diagnostic,
    });
    defer parser.deinit();

    try std.testing.expectEqualStrings("", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}
