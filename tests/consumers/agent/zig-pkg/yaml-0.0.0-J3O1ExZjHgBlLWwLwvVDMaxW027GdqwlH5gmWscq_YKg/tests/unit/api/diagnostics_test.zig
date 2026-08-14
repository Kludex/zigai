//! Purpose: Consolidate public root API diagnostic regression tests.
//! Owns: Public parser, loader, and event-stream diagnostic assertions.
//! Does not own: Parse, load, emit, dump, limit, or tag success behavior assertions.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const Diagnostic = support.Diagnostic;
const Event = support.Event;
const ParseError = support.ParseError;
const emitEventsWithOptions = support.emitEventsWithOptions;
const loadStreamWithOptions = support.loadStreamWithOptions;
const loadWithOptions = support.loadWithOptions;
const parseEvents = support.parseEvents;
const parseEventsWithOptions = support.parseEventsWithOptions;

test "parseEvents rejects YAML directive with unsupported major version" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%YAML 2.0
        \\---
        \\foo
        \\
    ));
}

test "parseEventsWithOptions reports unsupported YAML directive version location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\%YAML 2.0
        \\---
        \\foo
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unsupported YAML directive version", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports duplicate YAML directive location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\%YAML 1.2
        \\%YAML 1.2
        \\---
        \\foo
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("duplicate YAML directive", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports duplicate TAG directive location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\!e!value
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("duplicate TAG directive", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 35), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEvents rejects invalid TAG directive handles" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !bad tag:example.com,2000:app/
        \\--- !bad value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !b*d! tag:example.com,2000:app/
        \\--- value
        \\
    ));
}

test "parseEvents rejects reserved indicators at the start of plain scalars" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\commercial-at: @text
        \\
    ));
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\grave-accent: `text
        \\
    ));
}

test "parseEventsWithOptions reports reserved indicator location" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\ok:
        \\  @reserved
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("reserved indicator at plain scalar start", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.column);
}

test "parseEventsWithOptions reports tab indentation before block nodes" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, "key:\n\t- value\n", .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("tab used for indentation", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports tab indentation before separated flow nodes" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, "key:\n\t[one]\n", .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("tab used for indentation", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEvents rejects block scalar indicators in flow plain scalar positions" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "[|]\n"));
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "[>]\n"));
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, "{|: value}\n"));
}

test "parseEvents rejects flow indicators in anchor and alias names" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\&bad, value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\&bad[ value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\*bad{name}
        \\
    ));
}

test "parseEvents rejects empty flow mapping entries" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\{a: b,, c: d}
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\{, a: b}
        \\
    ));

    var trailing_comma = try parseEvents(std.testing.allocator,
        \\{a: b,}
        \\
    );
    defer trailing_comma.deinit();

    try std.testing.expectEqual(@as(usize, 8), trailing_comma.events.len);
    try std.testing.expect(trailing_comma.events[2] == .mapping_start);
    try std.testing.expect(trailing_comma.events[3] == .scalar);
    try std.testing.expectEqualStrings("a", trailing_comma.events[3].scalar.value);
    try std.testing.expect(trailing_comma.events[4] == .scalar);
    try std.testing.expectEqualStrings("b", trailing_comma.events[4].scalar.value);
    try std.testing.expect(trailing_comma.events[5] == .mapping_end);
}

test "parseEvents allows colon in anchor and alias names" {
    var stream = try parseEvents(std.testing.allocator,
        \\- &ok:name value
        \\- *ok:name
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), stream.events.len);
    try std.testing.expect(stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("ok:name", stream.events[3].scalar.anchor.?);
    try std.testing.expect(stream.events[4] == .alias);
    try std.testing.expectEqualStrings("ok:name", stream.events[4].alias);
}

test "parseEvents allows trailing comments after top-level flow nodes" {
    var double_quoted = try parseEvents(std.testing.allocator,
        \\"quoted" # comment
        \\
    );
    defer double_quoted.deinit();
    try std.testing.expect(double_quoted.events[2] == .scalar);
    try std.testing.expectEqualStrings("quoted", double_quoted.events[2].scalar.value);

    var single_quoted = try parseEvents(std.testing.allocator,
        \\'quoted' # comment
        \\
    );
    defer single_quoted.deinit();
    try std.testing.expect(single_quoted.events[2] == .scalar);
    try std.testing.expectEqualStrings("quoted", single_quoted.events[2].scalar.value);

    var alias = try parseEvents(std.testing.allocator,
        \\*anchor # comment
        \\
    );
    defer alias.deinit();
    try std.testing.expect(alias.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", alias.events[2].alias);

    var sequence = try parseEvents(std.testing.allocator,
        \\[one, two] # comment
        \\
    );
    defer sequence.deinit();
    try std.testing.expect(sequence.events[2] == .sequence_start);
    try std.testing.expect(sequence.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence.events[3].scalar.value);
    try std.testing.expect(sequence.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", sequence.events[4].scalar.value);
    try std.testing.expect(sequence.events[5] == .sequence_end);
}

test "parseEvents ignores commas inside flow line comments" {
    var events = try parseEvents(std.testing.allocator,
        \\[
        \\  one # comment, not an entry separator
        \\  , two
        \\]
        \\
    );
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 8), events.events.len);
    try std.testing.expect(events.events[0] == .stream_start);
    try std.testing.expect(events.events[1] == .document_start);
    try std.testing.expect(events.events[2] == .sequence_start);
    try std.testing.expect(events.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", events.events[3].scalar.value);
    try std.testing.expect(events.events[4] == .scalar);
    try std.testing.expectEqualStrings("two", events.events[4].scalar.value);
    try std.testing.expect(events.events[5] == .sequence_end);
    try std.testing.expect(events.events[6] == .document_end);
    try std.testing.expect(events.events[7] == .stream_end);
}

test "parseEvents rejects properties before separated alias nodes" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- &anchor value
        \\- &alias
        \\  *anchor
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- &anchor value
        \\- !local
        \\  *anchor
        \\
    ));
}

test "parseEvents rejects invalid verbatim tags" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- !<!> foo
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\- !<$:?> bar
        \\
    ));
}

test "parseEvents rejects malformed percent escapes in tag properties" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\!<tag:example.com,2000:bad%ZZ> value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\!bad% value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\!!str%0G value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\--- !e!bad%2 value
        \\
    ));
}

test "parseEventsWithOptions reports invalid verbatim tag location" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\key: !<not-a-uri> value
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("invalid tag property", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

test "parseEvents rejects invalid TAG directive prefixes" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !e! tag:example.com/{bad
        \\---
        \\!e!suffix value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !e! tag:example.com/%GG
        \\---
        \\value
        \\
    ));
}

test "parseEvents rejects tag shorthands without suffixes" {
    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\!! value
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\!e! value
        \\
    ));
}

test "parseEventsWithOptions reports tag shorthand without suffix location" {
    var secondary_diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\!! value
        \\
    , .{
        .diagnostic = &secondary_diagnostic,
    }));

    try std.testing.expectEqualStrings("tag shorthand missing suffix", secondary_diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), secondary_diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), secondary_diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), secondary_diagnostic.column);

    var named_diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\!e! value
        \\
    , .{
        .diagnostic = &named_diagnostic,
    }));

    try std.testing.expectEqualStrings("tag shorthand missing suffix", named_diagnostic.message);
    try std.testing.expectEqual(@as(usize, 39), named_diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), named_diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), named_diagnostic.column);
}

test "parseEventsWithOptions reports huge unsupported YAML directive major versions" {
    const input =
        \\--- first
        \\...
        \\%YAML 999999999999999999999999.0
        \\--- second
        \\
    ;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unsupported YAML directive version", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 14), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadStreamWithOptions propagates huge YAML directive diagnostics" {
    const input =
        \\%YAML 999999999999999999999999.0
        \\--- value
        \\
    ;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadStreamWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unsupported YAML directive version", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports invalid TAG directive handles" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\%TAG !bad tag:example.com,2000:app/
        \\--- !bad value
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("invalid TAG directive", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports invalid TAG directive prefixes after document end reset" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, parseEventsWithOptions(std.testing.allocator,
        \\--- ok
        \\...
        \\%TAG !e! [bad
        \\--- value
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("invalid TAG directive", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 11), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports parser diagnostics" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\%YAML 2.0
        \\---
        \\foo
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("unsupported YAML directive version", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports loader diagnostics for duplicate keys" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\same: one
        \\same: two
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader rejected duplicate mapping key", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 20), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports loader diagnostics for document count limits" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadWithOptions(std.testing.allocator,
        \\---
        \\one
        \\---
        \\two
        \\
    , .{
        .max_document_count = 1,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader exceeded configured document count limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 16), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports loader diagnostics for empty streams" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\# only comments
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 16), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports loader diagnostics for multi-document streams" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadWithOptions(std.testing.allocator,
        \\---
        \\one
        \\---
        \\two
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 16), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadStreamWithOptions reports loader diagnostics for alias count limits" {
    const input =
        \\- &base value
        \\- *base
        \\- *base
        \\
    ;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadStreamWithOptions(std.testing.allocator, input, .{
        .max_alias_count = 1,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader exceeded configured alias count limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadStreamWithOptions reports loader diagnostics for alias expansion limits" {
    const input =
        \\- &base
        \\  - one
        \\  - two
        \\- *base
        \\- *base
        \\
    ;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadStreamWithOptions(std.testing.allocator, input, .{
        .max_alias_expansion = 5,
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader exceeded configured alias expansion limit", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports multi-document diagnostic for single-document load" {
    const input =
        \\---
        \\first
        \\---
        \\second
        \\
    ;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports empty-stream diagnostic for single-document load" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator, "", .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports comment-only diagnostic for single-document load" {
    const input = "# only a comment\n";
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports runtime empty-stream diagnostic for single-document load" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "# runtime comment\n");

    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator, input.items, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.items.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports standard tag node-kind diagnostics" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!!seq scalar
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader rejected tag for node kind", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 13), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "loadWithOptions reports invalid tagged scalar diagnostics" {
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!!int 12.3
        \\
    , .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader rejected invalid tagged scalar", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 11), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "emitEvents rejects malformed nested collection events" {
    const flow_sequence_with_document_end = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .document_end = .{} },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.Unsupported, emitEventsWithOptions(std.testing.allocator, &flow_sequence_with_document_end, .{}));

    const block_sequence_with_document_end = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .document_end = .{} },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.Unsupported, emitEventsWithOptions(std.testing.allocator, &block_sequence_with_document_end, .{}));

    const block_mapping_with_document_end = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .document_end = .{} },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.Unsupported, emitEventsWithOptions(std.testing.allocator, &block_mapping_with_document_end, .{}));
}

test "emitEvents rejects malformed mapping value events" {
    const block_mapping_with_document_end_value = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .document_end = .{} },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.Unsupported, emitEventsWithOptions(std.testing.allocator, &block_mapping_with_document_end_value, .{}));

    const flow_mapping_without_value = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "key" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.Unsupported, emitEventsWithOptions(std.testing.allocator, &flow_mapping_without_value, .{}));
}
