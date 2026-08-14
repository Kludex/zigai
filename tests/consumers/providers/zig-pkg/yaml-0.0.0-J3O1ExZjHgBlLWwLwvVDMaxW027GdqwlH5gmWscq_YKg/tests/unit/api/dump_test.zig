//! Purpose: Consolidate public root API dump behavior regression tests.
//! Owns: Public dump, dumpStream, emitValue, and dump writer behavior assertions.
//! Does not own: Parse, load, emit-events-only, diagnostic, limit, or tag behavior assertions.
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
const dumpStream = support.dumpStream;
const emitValue = support.emitValue;
const emitValueWithOptions = support.emitValueWithOptions;
const emitEvents = support.emitEvents;
const parseEvents = support.parseEvents;

test "dump emits a constructed scalar sequence" {
    const first: Node = .{ .scalar = .{ .value = "one" } };
    const second: Node = .{ .scalar = .{ .value = "two" } };
    const items = [_]*const Node{ &first, &second };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- one
        \\- two
        \\
    , emitted);
}

test "emitValue aliases single-document value dumping" {
    const first: Node = .{ .scalar = .{ .value = "one" } };
    const second: Node = .{ .scalar = .{ .value = "two" } };
    const items = [_]*const Node{ &first, &second };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try emitValue(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- one
        \\- two
        \\
    , emitted);

    const emitted_with_options = try emitValueWithOptions(std.testing.allocator, &root, .{});
    defer std.testing.allocator.free(emitted_with_options);

    try std.testing.expectEqualStrings(emitted, emitted_with_options);
}

test "dump emits constructed empty collections" {
    const empty_items = [_]*const Node{};
    const empty_sequence: Node = .{ .sequence = .{ .items = &empty_items } };

    const emitted_sequence = try dump(std.testing.allocator, &empty_sequence);
    defer std.testing.allocator.free(emitted_sequence);

    try std.testing.expectEqualStrings(
        \\[]
        \\
    , emitted_sequence);

    const empty_pairs = [_]MappingPair{};
    const empty_mapping: Node = .{ .mapping = .{ .pairs = &empty_pairs } };

    const emitted_mapping = try dump(std.testing.allocator, &empty_mapping);
    defer std.testing.allocator.free(emitted_mapping);

    try std.testing.expectEqualStrings(
        \\{}
        \\
    , emitted_mapping);

    const sequence_items = [_]*const Node{ &empty_sequence, &empty_mapping };
    const sequence_with_empty_collections: Node = .{ .sequence = .{ .items = &sequence_items } };

    const emitted_nested_sequence = try dump(std.testing.allocator, &sequence_with_empty_collections);
    defer std.testing.allocator.free(emitted_nested_sequence);

    try std.testing.expectEqualStrings(
        \\- []
        \\- {}
        \\
    , emitted_nested_sequence);

    const items_key: Node = .{ .scalar = .{ .value = "items" } };
    const meta_key: Node = .{ .scalar = .{ .value = "meta" } };
    const mapping_pairs = [_]MappingPair{
        .{ .key = &items_key, .value = &empty_sequence },
        .{ .key = &meta_key, .value = &empty_mapping },
    };
    const mapping_with_empty_collections: Node = .{ .mapping = .{ .pairs = &mapping_pairs } };

    const emitted_nested_mapping = try dump(std.testing.allocator, &mapping_with_empty_collections);
    defer std.testing.allocator.free(emitted_nested_mapping);

    try std.testing.expectEqualStrings(
        \\items: []
        \\meta: {}
        \\
    , emitted_nested_mapping);
}

test "dump emits anchored scalar sequence items" {
    const item: Node = .{ .scalar = .{ .anchor = "item", .value = "one" } };
    const items = [_]*const Node{&item};
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- &item one
        \\
    , emitted);
}

test "dump emits nested block sequences" {
    const nested_first: Node = .{ .scalar = .{ .value = "one" } };
    const nested_second: Node = .{ .scalar = .{ .value = "two" } };
    const nested_items = [_]*const Node{ &nested_first, &nested_second };
    const nested: Node = .{ .sequence = .{ .items = &nested_items } };
    const sibling: Node = .{ .scalar = .{ .value = "three" } };
    const items = [_]*const Node{ &nested, &sibling };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- - one
        \\  - two
        \\- three
        \\
    , emitted);
}

test "dump emits a constructed block mapping" {
    const name_key: Node = .{ .scalar = .{ .value = "name" } };
    const name_value: Node = .{ .scalar = .{ .value = "zig" } };
    const enabled_key: Node = .{ .scalar = .{ .value = "enabled" } };
    const enabled_value: Node = .{ .bool_value = .{ .value = true } };
    const pairs = [_]MappingPair{
        .{ .key = &name_key, .value = &name_value },
        .{ .key = &enabled_key, .value = &enabled_value },
    };
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\name: zig
        \\enabled: true
        \\
    , emitted);
}

test "dump emits anchored scalar mapping keys" {
    const key: Node = .{ .scalar = .{ .anchor = "field", .value = "name" } };
    const value: Node = .{ .scalar = .{ .value = "zig" } };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\&field name: zig
        \\
    , emitted);
}

test "dump emits tagged scalar mapping values" {
    const key: Node = .{ .scalar = .{ .value = "answer" } };
    const value: Node = .{ .scalar = .{
        .tag = "tag:yaml.org,2002:int",
        .value = "42",
    } };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\answer: !!int 42
        \\
    , emitted);
}

test "dumpStream emits multiple constructed documents" {
    const first: Node = .{ .int_value = .{ .value = 1 } };
    const second: Node = .{ .null_value = .{} };
    const documents = [_]*const Node{ &first, &second };

    const emitted = try dumpStream(std.testing.allocator, &documents);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\1
        \\--- null
        \\
    , emitted);
}

test "dump emits YAML core spellings for non-finite floats" {
    const positive_inf: Node = .{ .float_value = .{ .value = std.math.inf(f64) } };
    const negative_inf: Node = .{ .float_value = .{ .value = -std.math.inf(f64) } };
    const nan_value: Node = .{ .float_value = .{ .value = std.math.nan(f64) } };
    const items = [_]*const Node{ &positive_inf, &negative_inf, &nan_value };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- .inf
        \\- -.inf
        \\- .nan
        \\
    , emitted);
}

test "dump emits finite floats with float syntax" {
    const one: Node = .{ .float_value = .{ .value = 1.0 } };
    const thousand: Node = .{ .float_value = .{ .value = 1000.0 } };
    const negative_zero: Node = .{ .float_value = .{ .value = -0.0 } };
    const fractional: Node = .{ .float_value = .{ .value = 1.25 } };
    const items = [_]*const Node{ &one, &thousand, &negative_zero, &fractional };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- 1.0
        \\- 1000.0
        \\- -0.0
        \\- 1.25
        \\
    , emitted);
}

test "dump quotes string scalars that look like core schema values" {
    const bool_like: Node = .{ .scalar = .{ .value = "true" } };
    const null_like: Node = .{ .scalar = .{ .value = "null" } };
    const int_like: Node = .{ .scalar = .{ .value = "0x3A" } };
    const float_like: Node = .{ .scalar = .{ .value = ".inf" } };
    const items = [_]*const Node{ &bool_like, &null_like, &int_like, &float_like };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- 'true'
        \\- 'null'
        \\- '0x3A'
        \\- '.inf'
        \\
    , emitted);
}

test "dump quotes string scalars that look like YAML indicators" {
    const flow_sequence_like: Node = .{ .scalar = .{ .value = "[not sequence]" } };
    const flow_mapping_like: Node = .{ .scalar = .{ .value = "{not: mapping}" } };
    const alias_like: Node = .{ .scalar = .{ .value = "*alias" } };
    const anchor_like: Node = .{ .scalar = .{ .value = "&anchor" } };
    const tag_like: Node = .{ .scalar = .{ .value = "!tag" } };
    const comment_like: Node = .{ .scalar = .{ .value = "# comment" } };
    const sequence_entry_like: Node = .{ .scalar = .{ .value = "- item" } };
    const mapping_key_like: Node = .{ .scalar = .{ .value = "? key" } };
    const mapping_value_like: Node = .{ .scalar = .{ .value = ": value" } };
    const trailing_comment_like: Node = .{ .scalar = .{ .value = "plain # comment" } };
    const items = [_]*const Node{
        &flow_sequence_like,
        &flow_mapping_like,
        &alias_like,
        &anchor_like,
        &tag_like,
        &comment_like,
        &sequence_entry_like,
        &mapping_key_like,
        &mapping_value_like,
        &trailing_comment_like,
    };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- '[not sequence]'
        \\- '{not: mapping}'
        \\- '*alias'
        \\- '&anchor'
        \\- '!tag'
        \\- '# comment'
        \\- '- item'
        \\- '? key'
        \\- ': value'
        \\- 'plain # comment'
        \\
    , emitted);
}

test "dump quotes multiline plain mapping values with indented continuation" {
    const key: Node = .{ .scalar = .{ .value = "plain" } };
    const value: Node = .{ .scalar = .{ .value = "a b\nc" } };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\plain: 'a b
        \\
        \\  c'
        \\
    , emitted);
}

test "emitEvents quotes multiline plain mapping values with indented continuation" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "plain" } },
        .{ .scalar = .{ .value = "a b\nc" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\plain: 'a b
        \\
        \\  c'
        \\
    , emitted);
}

test "dump escapes YAML line breaks that would normalize on reparse" {
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
        const dumped = try yaml.dump(std.testing.allocator, &root);
        defer std.testing.allocator.free(dumped);

        try std.testing.expect(std.mem.indexOf(u8, dumped, case.escape) != null);

        var reparsed = try yaml.load(std.testing.allocator, dumped);
        defer reparsed.deinit();

        try support.expectScalarString(reparsed.root, case.value);
    }
}

test "dumpStream and dumpToWriter preserve YAML line breaks" {
    const root: yaml.Node = .{ .scalar = .{ .value = "before\xc2\x85after" } };
    const documents = [_]*const yaml.Node{&root};

    const dumped = try yaml.dumpStream(std.testing.allocator, &documents);
    defer std.testing.allocator.free(dumped);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "\\x85") != null);

    var reparsed_stream = try yaml.loadStream(std.testing.allocator, dumped);
    defer reparsed_stream.deinit();
    try std.testing.expectEqual(@as(usize, 1), reparsed_stream.documents.len);
    try support.expectScalarString(reparsed_stream.documents[0], root.scalar.value);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try yaml.dumpToWriter(std.testing.allocator, &writer, &root);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\\x85") != null);

    var reparsed_writer = try yaml.load(std.testing.allocator, writer.buffered());
    defer reparsed_writer.deinit();
    try support.expectScalarString(reparsed_writer.root, root.scalar.value);
}

test "dump preserves primitive node anchors and tags" {
    const null_node: Node = .{ .null_value = .{ .anchor = "n", .tag = "!null" } };
    const bool_node: Node = .{ .bool_value = .{ .value = true, .anchor = "b", .tag = "!bool" } };
    const int_node: Node = .{ .int_value = .{ .value = 7, .anchor = "i", .tag = "!int" } };
    const float_node: Node = .{ .float_value = .{ .value = 1.5, .anchor = "f", .tag = "!float" } };
    const items = [_]*const Node{ &null_node, &bool_node, &int_node, &float_node };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    var reparsed = try parseEvents(std.testing.allocator, emitted);
    defer reparsed.deinit();

    try expectScalarMetadata(reparsed.events[3], "null", "n", "!null");
    try expectScalarMetadata(reparsed.events[4], "true", "b", "!bool");
    try expectScalarMetadata(reparsed.events[5], "7", "i", "!int");
    try expectScalarMetadata(reparsed.events[6], "1.5", "f", "!float");
}

test "dump aliases repeated anchored primitive nodes" {
    const repeated: Node = .{ .int_value = .{ .value = 7, .anchor = "answer" } };
    const items = [_]*const Node{ &repeated, &repeated };
    const root: Node = .{ .sequence = .{ .items = &items } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\- &answer 7
        \\- *answer
        \\
    , emitted);

    var reparsed = try parseEvents(std.testing.allocator, emitted);
    defer reparsed.deinit();
    try expectScalarMetadata(reparsed.events[3], "7", "answer", null);
    try std.testing.expect(reparsed.events[4] == .alias);
    try std.testing.expectEqualStrings("answer", reparsed.events[4].alias);
}

test "dumpStreamWithOptions rejects multi-document output over byte limit" {
    const first: yaml.Node = .{ .scalar = .{ .value = "first" } };
    const second: yaml.Node = .{ .scalar = .{ .value = "second" } };
    const documents = [_]*const yaml.Node{ &first, &second };

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.dumpStreamWithOptions(
        std.testing.allocator,
        &documents,
        .{ .max_output_bytes = 4 },
    ));
}

test "dumpStreamToWriterWithOptions honors output limits before writing" {
    const first: yaml.Node = .{ .scalar = .{ .value = "first" } };
    const second: yaml.Node = .{ .scalar = .{ .value = "second" } };
    const documents = [_]*const yaml.Node{ &first, &second };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(yaml.ParseError.Unsupported, yaml.dumpStreamToWriterWithOptions(
        std.testing.allocator,
        &writer,
        &documents,
        .{ .max_output_bytes = 4 },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "dump rejects constructed invalid anchors and aliases" {
    const anchored: Node = .{ .scalar = .{ .anchor = "bad,anchor", .value = "value" } };
    try std.testing.expectError(ParseError.InvalidSyntax, dump(std.testing.allocator, &anchored));

    const alias: Node = .{ .alias = "bad{alias" };
    try std.testing.expectError(ParseError.InvalidSyntax, dump(std.testing.allocator, &alias));
}

fn expectScalarMetadata(event: anytype, value: []const u8, anchor: ?[]const u8, tag: ?[]const u8) !void {
    try std.testing.expect(event == .scalar);
    try std.testing.expectEqualStrings(value, event.scalar.value);
    if (anchor) |expected| {
        try std.testing.expectEqualStrings(expected, event.scalar.anchor.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), event.scalar.anchor);
    }
    if (tag) |expected| {
        try std.testing.expectEqualStrings(expected, event.scalar.tag.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), event.scalar.tag);
    }
}
