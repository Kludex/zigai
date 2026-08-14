//! Purpose: Consolidate public root API emit behavior regression tests.
//! Owns: Public emitEvents, emitValue, and writer emission behavior assertions.
//! Does not own: Parse, load, dump-only, diagnostic, limit, or tag behavior assertions.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const yaml = support.yaml;
const Event = support.Event;
const MappingPair = support.MappingPair;
const Node = support.Node;
const ParseError = support.ParseError;
const dump = support.dump;
const dumpWithOptions = support.dumpWithOptions;
const emitEvents = support.emitEvents;
const emitEventsWithOptions = support.emitEventsWithOptions;
const load = support.load;

test "dump emits constructed collection style anchor and tag metadata" {
    const item: Node = .{ .scalar = .{ .value = "one" } };
    const items = [_]*const Node{&item};
    const root: Node = .{ .sequence = .{
        .items = &items,
        .style = .flow,
        .anchor = "items",
        .tag = "tag:example.com,2000:items",
    } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\&items !<tag:example.com,2000:items> [one]
        \\
    , emitted);
}

test "dump emits constructed top-level flow mapping style" {
    const name_key: Node = .{ .scalar = .{ .value = "name" } };
    const name_value: Node = .{ .scalar = .{ .value = "zig" } };
    const items_key: Node = .{ .scalar = .{ .value = "items" } };
    const first_item: Node = .{ .scalar = .{ .value = "one" } };
    const second_item: Node = .{ .scalar = .{ .value = "two" } };
    const items = [_]*const Node{ &first_item, &second_item };
    const items_value: Node = .{ .sequence = .{ .items = &items, .style = .flow } };
    const pairs = [_]MappingPair{
        .{ .key = &name_key, .value = &name_value },
        .{ .key = &items_key, .value = &items_value },
    };
    const root: Node = .{ .mapping = .{ .pairs = &pairs, .style = .flow } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\{name: zig, items: [one, two]}
        \\
    , emitted);
}

test "dump quotes plain scalars with flow indicators inside flow collections" {
    const comma: Node = .{ .scalar = .{ .value = "one,two" } };
    const bracket: Node = .{ .scalar = .{ .value = "a[b]" } };
    const brace: Node = .{ .scalar = .{ .value = "a{b}" } };
    const items = [_]*const Node{ &comma, &bracket, &brace };
    const root: Node = .{ .sequence = .{
        .items = &items,
        .style = .flow,
    } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\['one,two', 'a[b]', 'a{b}']
        \\
    , emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();

    try std.testing.expect(reparsed.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), reparsed.root.sequence.items.len);
    try std.testing.expectEqualStrings("one,two", reparsed.root.sequence.items[0].scalar.value);
    try std.testing.expectEqualStrings("a[b]", reparsed.root.sequence.items[1].scalar.value);
    try std.testing.expectEqualStrings("a{b}", reparsed.root.sequence.items[2].scalar.value);
}

test "dump emits block-style nested collections inside flow collections as flow" {
    const first_item: Node = .{ .scalar = .{ .value = "one" } };
    const second_item: Node = .{ .scalar = .{ .value = "two" } };
    const nested_sequence_items = [_]*const Node{ &first_item, &second_item };
    const nested_sequence: Node = .{ .sequence = .{ .items = &nested_sequence_items } };

    const key: Node = .{ .scalar = .{ .value = "key" } };
    const value: Node = .{ .scalar = .{ .value = "value" } };
    const nested_mapping_pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const nested_mapping: Node = .{ .mapping = .{ .pairs = &nested_mapping_pairs } };

    const root_items = [_]*const Node{ &nested_sequence, &nested_mapping };
    const root: Node = .{ .sequence = .{ .items = &root_items, .style = .flow } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\[[one, two], {key: value}]
        \\
    , emitted);
}

test "dump quotes block scalar styles inside flow collections" {
    const literal: Node = .{ .scalar = .{
        .value = "line one\nline two\n",
        .style = .literal,
    } };
    const folded: Node = .{ .scalar = .{
        .value = "folded line\n",
        .style = .folded,
    } };
    const items = [_]*const Node{ &literal, &folded };
    const root: Node = .{ .sequence = .{
        .items = &items,
        .style = .flow,
    } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\["line one\nline two\n", "folded line\n"]
        \\
    , emitted);
}

test "emitEventsWithOptions preserves constructed top-level flow mapping style" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "zig" } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_top_level_flow_mapping_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\{name: zig, items: [one, two]}
        \\
    , emitted);
}

test "emitEventsWithOptions can preserve flow mapping sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "a" } },
        .{ .scalar = .{ .value = "b" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_block_sequence_flow_mapping_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- {a: b}
        \\
    , emitted);
}

test "emitEventsWithOptions canonicalizes flow collections as block collections" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\- one
        \\- - two
        \\
    , emitted);
}

test "dumpWithOptions canonicalizes flow collections as block collections" {
    const one: Node = .{ .scalar = .{ .value = "one" } };
    const two: Node = .{ .scalar = .{ .value = "two" } };
    const nested_items = [_]*const Node{&two};
    const nested: Node = .{ .sequence = .{
        .items = &nested_items,
        .style = .flow,
    } };
    const items = [_]*const Node{ &one, &nested };
    const root: Node = .{ .sequence = .{
        .items = &items,
        .style = .flow,
    } };

    const emitted = try dumpWithOptions(std.testing.allocator, &root, .{
        .preserve_collection_style = false,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- one
        \\- - two
        \\
    , emitted);
}

test "dumpWithOptions can preserve flow mapping sequence items" {
    const key: Node = .{ .scalar = .{ .value = "a" } };
    const value: Node = .{ .scalar = .{ .value = "b" } };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const item: Node = .{ .mapping = .{
        .pairs = &pairs,
        .style = .flow,
    } };
    const items = [_]*const Node{&item};
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dumpWithOptions(std.testing.allocator, &root, .{
        .preserve_block_sequence_flow_mapping_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- {a: b}
        \\
    , emitted);
}

test "emitEventsWithOptions omits redundant document start for simple block mappings" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "a!" } },
        .{ .scalar = .{ .value = "safe" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\a!: safe
        \\
    , emitted);
}

test "dumpWithOptions omits redundant document start for simple block mappings" {
    const key: Node = .{ .scalar = .{ .value = "a!" } };
    const value: Node = .{ .scalar = .{ .value = "safe" } };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dumpWithOptions(std.testing.allocator, &root, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\a!: safe
        \\
    , emitted);
}

test "dump quotes tabbed scalars and mapping keys" {
    const tab_key: Node = .{ .scalar = .{ .value = "with\ttab" } };
    const tab_value: Node = .{ .scalar = .{ .value = "value\twith tab" } };
    const pairs = [_]MappingPair{.{ .key = &tab_key, .value = &tab_value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings("---\n'with\ttab': 'value\twith tab'\n", emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();
    try std.testing.expect(reparsed.root.* == .mapping);
    try std.testing.expectEqualStrings("with\ttab", reparsed.root.mapping.pairs[0].key.scalar.value);
    try std.testing.expectEqualStrings("value\twith tab", reparsed.root.mapping.pairs[0].value.scalar.value);
}

test "dump emits empty and multiline mapping keys as explicit quoted keys" {
    const empty_key: Node = .{ .scalar = .{ .value = "" } };
    const empty_value: Node = .{ .scalar = .{ .value = "empty" } };
    const multiline_key: Node = .{ .scalar = .{ .value = "line\nkey" } };
    const multiline_value: Node = .{ .scalar = .{ .value = "multiline" } };
    const pairs = [_]MappingPair{
        .{ .key = &empty_key, .value = &empty_value },
        .{ .key = &multiline_key, .value = &multiline_value },
    };
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\'': empty
        \\? 'line
        \\
        \\  key'
        \\: multiline
        \\
    , emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();
    try std.testing.expect(reparsed.root.* == .mapping);
    try std.testing.expectEqualStrings("", reparsed.root.mapping.pairs[0].key.scalar.value);
    try std.testing.expectEqualStrings("line\nkey", reparsed.root.mapping.pairs[1].key.scalar.value);
}

test "dump quotes flow scalars whose colon is followed by flow-key syntax" {
    const bracket: Node = .{ .scalar = .{ .value = "a:[b" } };
    const brace: Node = .{ .scalar = .{ .value = "a:{b" } };
    const single_quote: Node = .{ .scalar = .{ .value = "a:'b" } };
    const double_quote: Node = .{ .scalar = .{ .value = "a:\"b" } };
    const tab: Node = .{ .scalar = .{ .value = "a:\tb" } };
    const items = [_]*const Node{ &bracket, &brace, &single_quote, &double_quote, &tab };
    const root: Node = .{ .sequence = .{ .items = &items, .style = .flow } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings("['a:[b', 'a:{b', 'a:''b', 'a:\"b', 'a:\tb']\n", emitted);
}

test "dump quotes constructed scalars that are invalid plain scalars" {
    const dash: Node = .{ .scalar = .{ .value = "- item" } };
    const question: Node = .{ .scalar = .{ .value = "? question" } };
    const colon: Node = .{ .scalar = .{ .value = ": value" } };
    const comment: Node = .{ .scalar = .{ .value = "# comment" } };
    const reserved_at: Node = .{ .scalar = .{ .value = "@reserved" } };
    const reserved_tick: Node = .{ .scalar = .{ .value = "`reserved" } };
    const leading_space: Node = .{ .scalar = .{ .value = " leading" } };
    const trailing_space: Node = .{ .scalar = .{ .value = "trailing " } };
    const trailing_colon: Node = .{ .scalar = .{ .value = "trailing:" } };
    const items = [_]*const Node{
        &dash,
        &question,
        &colon,
        &comment,
        &reserved_at,
        &reserved_tick,
        &leading_space,
        &trailing_space,
        &trailing_colon,
    };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- '- item'
        \\- '? question'
        \\- ': value'
        \\- '# comment'
        \\- '@reserved'
        \\- '`reserved'
        \\- ' leading'
        \\- 'trailing '
        \\- 'trailing:'
        \\
    , emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();
    try std.testing.expect(reparsed.root.* == .sequence);
    for (items, 0..) |item, index| {
        try std.testing.expectEqualStrings(item.scalar.value, reparsed.root.sequence.items[index].scalar.value);
    }
}

test "dump quotes constructed strings that would resolve as core scalars" {
    const null_like: Node = .{ .scalar = .{ .value = "null" } };
    const bool_like: Node = .{ .scalar = .{ .value = "true" } };
    const int_like: Node = .{ .scalar = .{ .value = "42" } };
    const float_like: Node = .{ .scalar = .{ .value = "1.5" } };
    const items = [_]*const Node{ &null_like, &bool_like, &int_like, &float_like };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- 'null'
        \\- 'true'
        \\- '42'
        \\- '1.5'
        \\
    , emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();
    try std.testing.expect(reparsed.root.* == .sequence);
    for (items, 0..) |item, index| {
        try std.testing.expect(reparsed.root.sequence.items[index].* == .scalar);
        try std.testing.expectEqualStrings(item.scalar.value, reparsed.root.sequence.items[index].scalar.value);
    }
}

test "emitEvents emits a top-level block sequence" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- one
        \\- two
        \\
    , emitted);
}

test "emitEvents emits bare dash for empty block sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\-
        \\
    , emitted);
}

test "emitEvents emits a top-level flow sequence" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two words", .style = .single_quoted } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\[one, 'two words']
        \\
    , emitted);
}

test "emitEvents emits flow collection mapping values with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "seq" } },
        .{ .sequence_start = .{ .style = .flow, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .scalar = .{ .value = "map" } },
        .{ .mapping_start = .{ .style = .flow, .anchor = "pairs" } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\seq: &items [one]
        \\map: &pairs {key: value}
        \\
    , emitted);
}

test "emitEvents emits block sequence mapping values with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "seq" } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\seq: &items
        \\  - one
        \\
    , emitted);
}

test "emitEvents emits empty collection mapping values with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "seq" } },
        .{ .sequence_start = .{ .style = .flow, .anchor = "empty_seq" } },
        .sequence_end,
        .{ .scalar = .{ .value = "map" } },
        .{ .mapping_start = .{ .style = .flow, .anchor = "empty_map" } },
        .mapping_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\seq: &empty_seq []
        \\map: &empty_map {}
        \\
    , emitted);
}

test "emitEvents emits empty block collections" {
    const empty_sequence_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const empty_sequence = try emitEvents(std.testing.allocator, &empty_sequence_events);
    defer std.testing.allocator.free(empty_sequence);

    try std.testing.expectEqualStrings(
        \\[]
        \\
    , empty_sequence);

    const empty_mapping_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const empty_mapping = try emitEvents(std.testing.allocator, &empty_mapping_events);
    defer std.testing.allocator.free(empty_mapping);

    try std.testing.expectEqualStrings(
        \\{}
        \\
    , empty_mapping);
}

test "emitEvents emits anchored scalar flow sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .anchor = "item", .value = "one" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\[&item one, *item]
        \\
    , emitted);
}

test "emitEvents rejects invalid anchor and alias names" {
    const scalar_anchor_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "bad,", .value = "one" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &scalar_anchor_events));

    const whitespace_anchor_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "bad name", .value = "one" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &whitespace_anchor_events));

    const collection_anchor_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow, .anchor = "bad]" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &collection_anchor_events));

    const alias_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "bad{name}" },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &alias_events));

    const whitespace_alias_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "bad name" },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &whitespace_alias_events));
}

test "emitEvents rejects tag shorthands without suffixes" {
    const secondary_tag_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .tag = "!!", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &secondary_tag_events));

    const named_tag_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .tag = "!e!", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &named_tag_events));
}

test "emitEvents rejects named tag shorthands without directives" {
    const named_tag_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .tag = "!e!foo", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &named_tag_events));
}

test "emitEvents emits flow sequence items in block sequences" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- [one, two]
        \\
    , emitted);
}

test "emitEvents emits flow mapping items with properties in block sequences" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow, .anchor = "pair" } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- &pair {key: value}
        \\
    , emitted);
}

test "emitEvents emits collection mapping keys with properties" {
    const flow_key_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow, .anchor = "key_map" } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .scalar = .{ .value = "mapped" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const flow_key = try emitEvents(std.testing.allocator, &flow_key_events);
    defer std.testing.allocator.free(flow_key);

    try std.testing.expectEqualStrings(
        \\? &key_map {key: value}
        \\: mapped
        \\
    , flow_key);

    const block_key_events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block, .anchor = "key_map" } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .scalar = .{ .value = "mapped" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const block_key = try emitEvents(std.testing.allocator, &block_key_events);
    defer std.testing.allocator.free(block_key);

    try std.testing.expectEqualStrings(
        \\? &key_map
        \\  key: value
        \\: mapped
        \\
    , block_key);
}

test "emitEvents emits nested flow collections inside a flow sequence" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "three" } },
        .{ .scalar = .{ .value = "four" } },
        .sequence_end,
        .{ .scalar = .{ .value = "meta" } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "enabled" } },
        .{ .scalar = .{ .value = "true" } },
        .mapping_end,
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\[[one, two], {items: [three, four], meta: {enabled: true}}]
        \\
    , emitted);
}

test "emitEvents emits block-style nested collections inside flow collections as flow" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\[[one, two], {key: value}]
        \\
    , emitted);
}

test "emitEvents emits top-level collection properties" {
    const tagged_sequence_events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .sequence_start = .{
            .style = .block,
            .anchor = "items",
            .tag = "tag:example.com,2000:app/items",
        } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const tagged_sequence = try emitEvents(std.testing.allocator, &tagged_sequence_events);
    defer std.testing.allocator.free(tagged_sequence);

    try std.testing.expectEqualStrings(
        \\--- &items !<tag:example.com,2000:app/items>
        \\- one
        \\
    , tagged_sequence);

    const anchored_mapping_events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{
            .style = .block,
            .anchor = "root",
        } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const anchored_mapping = try emitEvents(std.testing.allocator, &anchored_mapping_events);
    defer std.testing.allocator.free(anchored_mapping);

    try std.testing.expectEqualStrings(
        \\--- &root
        \\key: value
        \\
    , anchored_mapping);
}

test "emitEvents emits collection properties on block sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .sequence_start = .{
            .style = .block,
            .anchor = "items",
        } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .mapping_start = .{
            .style = .block,
            .tag = "tag:example.com,2000:app/meta",
        } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- &items
        \\  - one
        \\- !<tag:example.com,2000:app/meta>
        \\  key: value
        \\
    , emitted);
}

test "emitEvents preserves block scalar styled mapping keys as explicit keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "line one\nline two\n",
            .style = .literal,
        } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? |
        \\  line one
        \\  line two
        \\: value
        \\
    , emitted);
}

test "emitEvents emits collection properties on block mapping values" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{
            .style = .block,
            .anchor = "items",
        } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .scalar = .{ .value = "meta" } },
        .{ .mapping_start = .{
            .style = .block,
            .tag = "tag:example.com,2000:app/meta",
        } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\items: &items
        \\  - one
        \\meta: !<tag:example.com,2000:app/meta>
        \\  key: value
        \\
    , emitted);
}

test "emitEvents emits block mappings as explicit block mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .scalar = .{ .value = "result" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? key: value
        \\: result
        \\
    , emitted);
}

test "emitEvents emits flow collections as explicit block mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .scalar = .{ .value = "sequence key" } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "zig" } },
        .mapping_end,
        .{ .scalar = .{ .value = "mapping key" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? [one, two]
        \\: sequence key
        \\? {name: zig}
        \\: mapping key
        \\
    , emitted);
}

test "emitEvents emits flow collection keys in compact block mapping sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .scalar = .{ .value = "sequence key" } },
        .mapping_end,
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "zig" } },
        .mapping_end,
        .{ .scalar = .{ .value = "mapping key" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- ? [one, two]
        \\  : sequence key
        \\- ? {name: zig}
        \\  : mapping key
        \\
    , emitted);
}

test "emitEvents emits block collection keys in compact block mapping sequence items" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .scalar = .{ .value = "sequence key" } },
        .mapping_end,
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "zig" } },
        .mapping_end,
        .{ .scalar = .{ .value = "mapping key" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- ? - one
        \\    - two
        \\  : sequence key
        \\- ? name: zig
        \\  : mapping key
        \\
    , emitted);
}

test "emitEvents emits collection properties on explicit block mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .scalar = .{ .value = "anchored sequence key" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? &items
        \\  - one
        \\: anchored sequence key
        \\
    , emitted);
}

test "emitEvents emits empty sequence values after explicit sequence keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block } },
        .sequence_end,
        .{ .sequence_start = .{ .style = .block } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? []
        \\: []
        \\
    , emitted);
}

test "emitEvents canonicalizes block sequence key indentation with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .scalar = .{ .value = "anchored sequence key" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? &items
        \\- one
        \\: anchored sequence key
        \\
    , emitted);
}

test "emitEvents emits literal scalar block mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key\n", .style = .literal } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? |
        \\  key
        \\: value
        \\
    , emitted);
}

test "emitEvents emits a top-level scalar anchor" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .anchor = "node", .value = "foo" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- &node foo
        \\
    , emitted);
}

test "emitEvents preserves indented block sequence keys with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .{ .scalar = .{ .value = "anchored sequence key" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? &items
        \\  - one
        \\: anchored sequence key
        \\
    , emitted);
}

test "emitEvents preserves block sequence values after collection keys with properties" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "key" } },
        .sequence_end,
        .{ .sequence_start = .{ .style = .block, .anchor = "values" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? &items
        \\  - key
        \\: &values
        \\  - one
        \\
    , emitted);
}

test "emitEvents preserves indented block sequence values with properties after scalar keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\key: &items
        \\  - one
        \\
    , emitted);
}

test "emitEvents marks canonicalized top-level flow mapping whose first key starts with question" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "?key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const actual = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
    });
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\---
        \\?key: value
        \\
    , actual);
}

test "emitValue escapes YAML line breaks that would normalize on reparse" {
    const cases = [_]struct {
        value: []const u8,
        escape: []const u8,
    }{
        .{ .value = "before\rafter", .escape = "\\r" },
        .{ .value = "before\xc2\x85after", .escape = "\\x85" },
        .{ .value = "before\xe2\x80\xa8after", .escape = "\\u2028" },
        .{ .value = "before\xe2\x80\xa9after", .escape = "\\u2029" },
    };

    for (cases) |case| {
        const root: yaml.Node = .{ .scalar = .{ .value = case.value } };
        const emitted = try yaml.emitValue(std.testing.allocator, &root);
        defer std.testing.allocator.free(emitted);

        try std.testing.expect(std.mem.indexOf(u8, emitted, case.escape) != null);

        var reparsed = try yaml.load(std.testing.allocator, emitted);
        defer reparsed.deinit();

        try support.expectScalarString(reparsed.root, case.value);
    }
}

test "emitEventsToWriter writes event output into caller writer" {
    const events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "name" } },
        .{ .scalar = .{ .value = "zig" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try yaml.emitEventsToWriter(std.testing.allocator, &writer, &events);

    try std.testing.expectEqualStrings(
        \\---
        \\name: zig
        \\
    , writer.buffered());
}

test "emitEventsToWriterWithOptions honors output limits before writing" {
    const events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "larger" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.emitEventsToWriterWithOptions(
        std.testing.allocator,
        &writer,
        &events,
        .{ .max_output_bytes = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "emitEventsWithOptions checks output limits before growing buffer" {
    const large_scalar =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = large_scalar } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var fixed_buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.emitEventsWithOptions(
        fixed.allocator(),
        &events,
        .{ .max_output_bytes = 8 },
    ));
}

test "emitEventsToWriter frees temporary output when writer fails" {
    const events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "larger" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, yaml.emitEventsToWriter(
        std.testing.allocator,
        &writer,
        &events,
    ));
}

test "dumpStreamToWriter writes loaded values into caller writer" {
    var stream = try yaml.loadStream(std.testing.allocator,
        \\---
        \\- one
        \\- two
        \\
    );
    defer stream.deinit();

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try yaml.dumpStreamToWriter(std.testing.allocator, &writer, stream.documents);

    try std.testing.expectEqualStrings(
        \\- one
        \\- two
        \\
    , writer.buffered());
}

test "dumpStreamToWriterWithOptions writes loaded values with options" {
    var stream = try yaml.loadStream(std.testing.allocator,
        \\---
        \\first
        \\---
        \\second
        \\
    );
    defer stream.deinit();

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try yaml.dumpStreamToWriterWithOptions(std.testing.allocator, &writer, stream.documents, .{
        .max_output_bytes = 64,
    });

    try std.testing.expectEqualStrings(
        \\first
        \\--- second
        \\
    , writer.buffered());
}

test "emitValueToWriter writes single value output into caller writer" {
    const root: yaml.Node = .{ .scalar = .{ .value = "value" } };

    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try yaml.emitValueToWriter(std.testing.allocator, &writer, &root);

    try std.testing.expectEqualStrings(
        \\value
        \\
    , writer.buffered());
}

test "single value writer APIs free temporary output when writer fails" {
    const root: yaml.Node = .{ .scalar = .{ .value = "larger" } };

    var dump_buffer: [1]u8 = undefined;
    var dump_writer: std.Io.Writer = .fixed(&dump_buffer);
    try std.testing.expectError(error.WriteFailed, yaml.dumpToWriter(
        std.testing.allocator,
        &dump_writer,
        &root,
    ));

    var value_buffer: [1]u8 = undefined;
    var value_writer: std.Io.Writer = .fixed(&value_buffer);
    try std.testing.expectError(error.WriteFailed, yaml.emitValueToWriter(
        std.testing.allocator,
        &value_writer,
        &root,
    ));
}

test "dumpToWriter and emitValueToWriterWithOptions write single values" {
    const root: yaml.Node = .{ .mapping = .{
        .style = .block,
        .pairs = &.{
            .{
                .key = &.{ .scalar = .{ .value = "key" } },
                .value = &.{ .scalar = .{ .value = "value" } },
            },
        },
    } };

    var dump_buffer: [64]u8 = undefined;
    var dump_writer: std.Io.Writer = .fixed(&dump_buffer);
    try yaml.dumpToWriter(std.testing.allocator, &dump_writer, &root);

    try std.testing.expectEqualStrings(
        \\---
        \\key: value
        \\
    , dump_writer.buffered());

    var value_buffer: [64]u8 = undefined;
    var value_writer: std.Io.Writer = .fixed(&value_buffer);
    try yaml.emitValueToWriterWithOptions(std.testing.allocator, &value_writer, &root, .{
        .max_output_bytes = 64,
    });

    try std.testing.expectEqualStrings(dump_writer.buffered(), value_writer.buffered());
}

test "dumpToWriterWithOptions honors output limits before writing" {
    const root: yaml.Node = .{ .scalar = .{ .value = "larger" } };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.dumpToWriterWithOptions(
        std.testing.allocator,
        &writer,
        &root,
        .{ .max_output_bytes = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "dumpStreamToWriter frees temporary output when writer fails" {
    const root: yaml.Node = .{ .scalar = .{ .value = "larger" } };
    const documents = [_]*const yaml.Node{&root};

    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, yaml.dumpStreamToWriter(
        std.testing.allocator,
        &writer,
        &documents,
    ));
}

test "emitEvents writes folded scalars with blank lines for semantic newlines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "ab cd\nef\n\ngh\n",
            .style = .folded,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- >
        \\  ab cd
        \\
        \\  ef
        \\
        \\
        \\  gh
        \\
    , emitted);
}

test "emitEvents writes folded scalars preserving breaks around more-indented lines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{
            .value = "Sammy Sosa completed another fine season with great stats.\n\n" ++
                "  63 Home Runs\n" ++
                "  0.288 Batting Average\n\n" ++
                "What a year!\n",
            .style = .folded,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\>
        \\  Sammy Sosa completed another fine season with great stats.
        \\
        \\    63 Home Runs
        \\    0.288 Batting Average
        \\
        \\  What a year!
        \\
    , emitted);
}

test "emitEvents quotes block mapping values ending with a space-only line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "foo" } },
        .{ .scalar = .{
            .value = "x\n \n",
            .style = .literal,
        } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\foo: "x\n \n"
        \\
    , emitted);
}

test "emitEventsWithOptions keeps top-level block scalar indicators on document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "text\n",
            .style = .literal,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- |
        \\  text
        \\
    , emitted);
}

test "emitEvents emits strip chomping for block scalars without a final newline" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "ab",
            .style = .literal,
        } },
        .{ .document_end = .{ .explicit = true } },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- |-
        \\  ab
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions emits keep chomping for newline-only block scalars" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "\n",
            .style = .literal,
        } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- |+
        \\
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions does not force document end when keep-chomp scalar is not final node" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "keep\n\n",
            .style = .literal,
        } },
        .{ .scalar = .{
            .value = "strip",
            .style = .folded,
        } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- |+
        \\  keep
        \\
        \\- >-
        \\  strip
        \\
    , emitted);
}

test "emitEventsWithOptions emits indent indicator for newline-only block scalar mapping values" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "keep" } },
        .{ .scalar = .{
            .value = "\n",
            .style = .literal,
        } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\keep: |2+
        \\
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions forces document start for canonical block scalar collections" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "aaa" } },
        .{ .scalar = .{
            .value = "xxx\n",
            .style = .literal,
        } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\- aaa: |
        \\    xxx
        \\
    , emitted);
}

test "emitEventsWithOptions quotes canonical block scalars with leading tab indentation" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "block" } },
        .{ .scalar = .{
            .value = "text\n \tlines\n",
            .style = .literal,
        } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\block: "text\n \tlines\n"
        \\
    , emitted);
}

test "emitEventsWithOptions keeps canonical literal scalars with tab-only content lines as blocks" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "foo" } },
        .{ .scalar = .{
            .value = "\t\n",
            .style = .literal,
        } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings("foo: |\n  \t\n", emitted);
}

test "emitEventsWithOptions quotes canonical folded scalars with tab-started content lines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{
            .value = "foo \n\n\t bar\n\nbaz\n",
            .style = .folded,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"foo \n\n\t bar\n\nbaz\n"
        \\
    , emitted);
}

test "emitEventsWithOptions emits indent indicator for folded scalar with leading blanks before comment-looking content" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "\n\n# detected\n",
            .style = .folded,
        } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- >2
        \\
        \\
        \\  # detected
        \\
    , emitted);
}

test "emitEventsWithOptions quotes sequence folded scalars with tab-started lines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "\t\ndetected\n",
            .style = .folded,
        } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- "\t\ndetected\n"
        \\
    , emitted);
}

test "emitEventsWithOptions quotes explicit top-level literal scalars with tab-started lines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "literal\n\ttext\n",
            .style = .literal,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"literal\n\ttext\n"
        \\
    , emitted);
}

test "emitEvents emits folded block scalar mapping keys explicitly" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key\nline\n", .style = .folded } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const actual = try emitEventsWithOptions(std.testing.allocator, &events, .{});
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\? >
        \\  key
        \\
        \\  line
        \\: value
        \\
    , actual);
}

test "emitEvents double-quotes unsafe single-quoted mapping keys" {
    const cases = [_]struct {
        name: []const u8,
        value: []const u8,
        expected_key: []const u8,
    }{
        .{ .name = "control", .value = "bell \x07 key", .expected_key = "\"bell \\x07 key\"" },
        .{ .name = "line separator", .value = "left\xe2\x80\xa8right", .expected_key = "\"left\\u2028right\"" },
    };

    for (cases) |case| {
        const events = [_]Event{
            .stream_start,
            .{ .document_start = .{} },
            .{ .mapping_start = .{ .style = .block } },
            .{ .scalar = .{ .value = case.value, .style = .single_quoted } },
            .{ .scalar = .{ .value = case.name, .style = .plain } },
            .mapping_end,
            .{ .document_end = .{} },
            .stream_end,
        };

        const emitted = try emitEvents(std.testing.allocator, &events);
        defer std.testing.allocator.free(emitted);

        try std.testing.expect(std.mem.indexOf(u8, emitted, case.expected_key) != null);

        var reparsed = try load(std.testing.allocator, emitted);
        defer reparsed.deinit();

        try std.testing.expect(reparsed.root.* == .mapping);
        try std.testing.expectEqual(@as(usize, 1), reparsed.root.mapping.pairs.len);
        try std.testing.expect(reparsed.root.mapping.pairs[0].key.* == .scalar);
        try std.testing.expectEqualStrings(case.value, reparsed.root.mapping.pairs[0].key.scalar.value);
    }
}

test "emitEvents double-quotes unsafe double-quoted mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "nul \x00 key", .style = .double_quoted } },
        .{ .scalar = .{ .value = "value", .style = .plain } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings("---\n\"nul \\x00 key\": value\n", emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();

    try std.testing.expect(reparsed.root.* == .mapping);
    try std.testing.expectEqualStrings("nul \x00 key", reparsed.root.mapping.pairs[0].key.scalar.value);
}

test "emitEvents rejects invalid UTF-8 in mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "bad \xff key", .style = .single_quoted } },
        .{ .scalar = .{ .value = "value", .style = .plain } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEventsWithOptions omits document start when canonical block scalar fallback is quoted in mapping" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "text" } },
        .{ .scalar = .{
            .value = "a\n  \nb\n",
            .style = .literal,
        } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\text: "a\n  \nb\n"
        \\
    , emitted);
}

test "emitEventsWithOptions emits canonical indentationless tagged sequence mapping values" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "sequence" } },
        .{ .sequence_start = .{
            .style = .block,
            .tag = "tag:yaml.org,2002:seq",
        } },
        .{ .scalar = .{ .value = "entry" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\sequence: !!seq
        \\- entry
        \\
    , emitted);
}

test "emitEventsWithOptions keeps canonical nested block sequence mapping values at mapping indent" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "outer" } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .mapping_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\outer:
        \\  items:
        \\  - one
        \\  - two
        \\
    , emitted);
}

test "emitEventsWithOptions emits safe quoted canonical mapping keys as plain" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{
            .value = "key",
            .style = .double_quoted,
        } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- key: value
        \\
    , emitted);
}

test "emitEventsWithOptions preserves single-character quoted canonical mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{
            .value = "a",
            .style = .double_quoted,
        } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- "a": value
        \\
    , emitted);
}

test "emitEventsWithOptions emits canonical indentationless tagged sequence mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{
            .style = .block,
            .anchor = "mapping",
        } },
        .{ .sequence_start = .{
            .style = .flow,
            .anchor = "key",
        } },
        .{ .scalar = .{
            .value = "a",
            .anchor = "item",
        } },
        .{ .scalar = .{ .value = "b" } },
        .sequence_end,
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- &mapping
        \\? &key
        \\- &item a
        \\- b
        \\: value
        \\
    , emitted);
}

test "emitEventsWithOptions forces document start for canonical top-level flow mappings" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "?foo" } },
        .{ .scalar = .{ .value = "bar" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\?foo: bar
        \\
    , emitted);
}

test "emitEventsWithOptions quotes canonical top-level block scalar fallback and preserves document end" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "ab\n\n \n",
            .style = .literal,
        } },
        .{ .document_end = .{ .explicit = true } },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"ab\n\n \n"
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions compacts empty sequence mapping keys inside explicit mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .flow } },
        .sequence_end,
        .{ .scalar = .{ .value = "x" } },
        .mapping_end,
        .{ .scalar = .{ .value = "" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? []: x
        \\:
        \\
    , emitted);
}

test "emitEventsWithOptions compacts mapping values after explicit mapping keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "first" } },
        .{ .scalar = .{ .value = "Sammy" } },
        .{ .scalar = .{ .value = "last" } },
        .{ .scalar = .{ .value = "Sosa" } },
        .mapping_end,
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "hr" } },
        .{ .scalar = .{ .value = "65" } },
        .{ .scalar = .{ .value = "avg" } },
        .{ .scalar = .{ .value = "0.278" } },
        .mapping_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? first: Sammy
        \\  last: Sosa
        \\: hr: 65
        \\  avg: 0.278
        \\
    , emitted);
}

test "emitEvents emits quoted multiline scalar mapping keys as explicit keys" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{
            .value = "foo\nbar:baz\tx \\$%^&*()x",
            .style = .double_quoted,
        } },
        .{ .scalar = .{ .value = "23" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\? "foo\nbar:baz\tx \\$%^&*()x"
        \\: 23
        \\
    , emitted);
}

test "emitEvents emits empty scalar mapping values with properties without quoted empty value" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "a" } },
        .{ .scalar = .{
            .value = "",
            .anchor = "anchor",
        } },
        .{ .scalar = .{ .value = "b" } },
        .{ .alias = "anchor" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\a: &anchor
        \\b: *anchor
        \\
    , emitted);
}

test "emitEventsWithOptions keeps canonical explicit empty documents bare" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "" } },
        .{ .document_end = .{} },
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\---
        \\
    , emitted);
}

test "emitEventsWithOptions terminates explicit empty document after non-empty document" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "a" } },
        .{ .scalar = .{ .value = "b" } },
        .mapping_end,
        .{ .document_end = .{} },
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\a: b
        \\---
        \\...
        \\
    , emitted);
}
