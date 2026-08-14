//! Purpose: Consolidate public root API load behavior regression tests.
//! Owns: Public load and loadStream behavior assertions.
//! Does not own: Parse, emit, dump, diagnostic, limit, or tag behavior assertions.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const yaml = support.yaml;
const CollectionStyle = support.CollectionStyle;
const Diagnostic = support.Diagnostic;
const DumpOptions = support.DumpOptions;
const Error = support.Error;
const Event = support.Event;
const EmitOptions = support.EmitOptions;
const MappingPair = support.MappingPair;
const Node = support.Node;
const ParseError = support.ParseError;
const ScalarStyle = support.ScalarStyle;
const dump = support.dump;
const dumpStream = support.dumpStream;
const dumpWithOptions = support.dumpWithOptions;
const emitEvents = support.emitEvents;
const emitEventsWithOptions = support.emitEventsWithOptions;
const load = support.load;
const loadStream = support.loadStream;
const loadStreamWithOptions = support.loadStreamWithOptions;
const loadWithOptions = support.loadWithOptions;
const parseEvents = support.parseEvents;
const parseEventsWithOptions = support.parseEventsWithOptions;
const scanner = support.scanner;
const max_parse_flow_depth = support.max_parse_flow_depth;
const expectJsonSchemaLoadInvalid = support.expectJsonSchemaLoadInvalid;
const expectLoadInvalidSyntax = support.expectLoadInvalidSyntax;
const expectScalarString = support.expectScalarString;
const yaml_safety_fuzz_corpus = support.yaml_safety_fuzz_corpus;
const fuzzYamlSafety = support.fuzzYamlSafety;
const exerciseYamlInput = support.exerciseYamlInput;

test "loadStream loads multiple documents" {
    var stream = try loadStream(std.testing.allocator,
        \\--- one
        \\--- two
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 2), stream.documents.len);
    try std.testing.expect(stream.documents[0].* == .scalar);
    try std.testing.expectEqualStrings("one", stream.documents[0].scalar.value);
    try std.testing.expect(stream.documents[1].* == .scalar);
    try std.testing.expectEqualStrings("two", stream.documents[1].scalar.value);
}

test "loadWithOptions failsafe schema leaves plain scalars as strings" {
    var document = try loadWithOptions(std.testing.allocator,
        \\true
        \\
    , .{ .schema = .failsafe });
    defer document.deinit();

    try expectScalarString(document.root, "true");
}

test "loadWithOptions json schema follows YAML 1.2.2 scalar resolution" {
    var json_true = try loadWithOptions(std.testing.allocator,
        \\true
        \\
    , .{ .schema = .json });
    defer json_true.deinit();
    try std.testing.expect(json_true.root.* == .bool_value);
    try std.testing.expectEqual(true, json_true.root.bool_value.value);

    var json_null = try loadWithOptions(std.testing.allocator,
        \\null
        \\
    , .{ .schema = .json });
    defer json_null.deinit();
    try std.testing.expect(json_null.root.* == .null_value);

    var json_float = try loadWithOptions(std.testing.allocator,
        \\12e03
        \\
    , .{ .schema = .json });
    defer json_float.deinit();
    try std.testing.expect(json_float.root.* == .float_value);
    try std.testing.expectEqual(@as(f64, 12000), json_float.root.float_value.value);

    var json_zero_dot = try loadWithOptions(std.testing.allocator,
        \\0.
        \\
    , .{ .schema = .json });
    defer json_zero_dot.deinit();
    try std.testing.expect(json_zero_dot.root.* == .float_value);
    try std.testing.expectEqual(@as(f64, 0), json_zero_dot.root.float_value.value);

    var json_trailing_decimal = try loadWithOptions(std.testing.allocator,
        \\1.
        \\
    , .{ .schema = .json });
    defer json_trailing_decimal.deinit();
    try std.testing.expect(json_trailing_decimal.root.* == .float_value);
    try std.testing.expectEqual(@as(f64, 1), json_trailing_decimal.root.float_value.value);

    var json_missing_fraction_digits = try loadWithOptions(std.testing.allocator,
        \\1.e2
        \\
    , .{ .schema = .json });
    defer json_missing_fraction_digits.deinit();
    try std.testing.expect(json_missing_fraction_digits.root.* == .float_value);
    try std.testing.expectEqual(@as(f64, 100), json_missing_fraction_digits.root.float_value.value);
}

test "loadWithOptions json schema rejects unmatched plain scalars" {
    try expectJsonSchemaLoadInvalid(
        \\True
        \\
    );
    try expectJsonSchemaLoadInvalid(
        \\0x3A
        \\
    );
    try expectJsonSchemaLoadInvalid(
        \\+12.3
        \\
    );
    try expectJsonSchemaLoadInvalid(
        \\plain string
        \\
    );
    try expectJsonSchemaLoadInvalid(
        \\- plain
        \\
    );
}

test "loadWithOptions json schema keeps quoted strings as strings" {
    var document = try loadWithOptions(std.testing.allocator,
        \\[
        \\  "True",
        \\  'plain string',
        \\]
        \\
    , .{ .schema = .json });
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 2), document.root.sequence.items.len);
    try expectScalarString(document.root.sequence.items[0], "True");
    try expectScalarString(document.root.sequence.items[1], "plain string");
}

test "loadWithOptions explicit standard string tag overrides schema resolution" {
    var core_document = try loadWithOptions(std.testing.allocator,
        \\!!str true
        \\
    , .{ .schema = .core });
    defer core_document.deinit();
    try expectScalarString(core_document.root, "true");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", core_document.root.scalar.tag.?);

    var json_document = try loadWithOptions(std.testing.allocator,
        \\!!str plain string
        \\
    , .{ .schema = .json });
    defer json_document.deinit();
    try expectScalarString(json_document.root, "plain string");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", json_document.root.scalar.tag.?);
}

test "loadWithOptions core schema keeps existing default resolution" {
    var document = try loadWithOptions(std.testing.allocator,
        \\[True, 0o7, +12.3]
        \\
    , .{ .schema = .core });
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), document.root.sequence.items.len);
    try std.testing.expect(document.root.sequence.items[0].* == .bool_value);
    try std.testing.expectEqual(true, document.root.sequence.items[0].bool_value.value);
    try std.testing.expect(document.root.sequence.items[1].* == .int_value);
    try std.testing.expectEqual(@as(i128, 7), document.root.sequence.items[1].int_value.value);
    try std.testing.expect(document.root.sequence.items[2].* == .float_value);
    try std.testing.expectEqual(@as(f64, 12.3), document.root.sequence.items[2].float_value.value);
}

test "loadWithOptions core schema resolves infinity and nan floats" {
    var document = try loadWithOptions(std.testing.allocator,
        \\[.inf, -.Inf, +.INF, .NAN]
        \\
    , .{ .schema = .core });
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 4), document.root.sequence.items.len);

    try std.testing.expect(document.root.sequence.items[0].* == .float_value);
    try std.testing.expect(std.math.isPositiveInf(document.root.sequence.items[0].float_value.value));

    try std.testing.expect(document.root.sequence.items[1].* == .float_value);
    try std.testing.expect(std.math.isInf(document.root.sequence.items[1].float_value.value));
    try std.testing.expect(document.root.sequence.items[1].float_value.value < 0);

    try std.testing.expect(document.root.sequence.items[2].* == .float_value);
    try std.testing.expect(std.math.isPositiveInf(document.root.sequence.items[2].float_value.value));

    try std.testing.expect(document.root.sequence.items[3].* == .float_value);
    try std.testing.expect(std.math.isNan(document.root.sequence.items[3].float_value.value));
}

test "loadWithOptions core schema does not resolve signed nan" {
    var document = try loadWithOptions(std.testing.allocator,
        \\+.NAN
        \\
    , .{ .schema = .core });
    defer document.deinit();

    try expectScalarString(document.root, "+.NAN");
}

test "load rejects duplicate scalar mapping keys" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\name: first
        \\name: second
        \\
    ));
}

test "load rejects duplicate mapping keys after core schema resolution" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\true: first
        \\True: second
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\0xB: hex
        \\11: decimal
        \\
    ));
}

test "load rejects duplicate mapping keys after non-specific scalar tag resolution" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\! 12: tagged string
        \\"12": quoted string
        \\
    ));
}

test "loadWithOptions can allow duplicate mapping keys" {
    var document = try loadWithOptions(std.testing.allocator,
        \\name: first
        \\name: second
        \\
    , .{ .duplicate_key_behavior = .allow });
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), document.root.mapping.pairs.len);
    try expectScalarString(document.root.mapping.pairs[0].key, "name");
    try expectScalarString(document.root.mapping.pairs[0].value, "first");
    try expectScalarString(document.root.mapping.pairs[1].key, "name");
    try expectScalarString(document.root.mapping.pairs[1].value, "second");
}

test "load duplicate-key equality behavior covers optimized cases" {
    const duplicate_inputs = [_][]const u8{
        \\name: first
        \\name: second
        \\
        ,
        \\? [one, {two: three}]
        \\: first
        \\? [one, {two: three}]
        \\: second
        \\
        ,
        \\? {left: one, right: two}
        \\: first
        \\? {right: two, left: one}
        \\: second
        \\
        ,
        \\? &key {left: one}
        \\: first
        \\? *key
        \\: second
        \\
        ,
        \\! same: first
        \\same: second
        \\
        ,
        \\.NAN: first
        \\.nan: second
        \\
        ,
        \\? {outer: {left: one, right: two}}
        \\: first
        \\? {outer: {right: two, left: one}}
        \\: second
        \\
        ,
    };

    for (duplicate_inputs) |input| {
        try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator, input));
    }

    var distinct_nested = try load(std.testing.allocator,
        \\? {outer: {left: one}}
        \\: first
        \\? {outer: {left: two}}
        \\: second
        \\
    );
    defer distinct_nested.deinit();
    try std.testing.expectEqual(@as(usize, 2), distinct_nested.root.mapping.pairs.len);
}

test "load owns preallocated collection contents" {
    var document = try load(std.testing.allocator, "items: [one, two, three, four]\nk00: v\nk01: v\nk02: v\nk03: v\nk04: v\nk05: v\nk06: v\nk07: v\nk08: v\nk09: v\nk10: v\nk11: v\nk12: v\nk13: v\nk14: v\nk15: v\nk16: v\nk17: v\nk18: v\nk19: v\nk20: v\nk21: v\nk22: v\nk23: v\nk24: v\nk25: v\nk26: v\nk27: v\nk28: v\nk29: v\nk30: v\nk31: v\nk32: v\n");
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 34), document.root.mapping.pairs.len);
    try std.testing.expectEqual(@as(usize, 4), document.root.mapping.pairs[0].value.sequence.items.len);
}

test "load preserves anchors on schema-resolved scalar aliases for dumping" {
    var document = try load(std.testing.allocator,
        \\truth: &truth true
        \\again: *truth
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), document.root.mapping.pairs.len);
    try std.testing.expect(document.root.mapping.pairs[0].value == document.root.mapping.pairs[1].value);

    const emitted = try dump(std.testing.allocator, document.root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\truth: &truth true
        \\again: *truth
        \\
    , emitted);
}

test "load keeps anchor-only scalars normal while aliases preserve identity" {
    var anchored = try load(std.testing.allocator,
        \\- &item value
        \\
    );
    defer anchored.deinit();

    try std.testing.expect(anchored.root.sequence.items[0].* == .scalar);
    try std.testing.expectEqualStrings("value", anchored.root.sequence.items[0].scalar.value);
    try std.testing.expectEqualStrings("item", anchored.root.sequence.items[0].scalar.anchor.?);

    var aliased = try load(std.testing.allocator,
        \\- &item value
        \\- *item
        \\
    );
    defer aliased.deinit();

    try std.testing.expectEqual(aliased.root.sequence.items[0], aliased.root.sequence.items[1]);
}

test "load preserves tags on schema-resolved scalar aliases for dumping" {
    var document = try load(std.testing.allocator,
        \\answer: &answer !!int "42"
        \\again: *answer
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), document.root.mapping.pairs.len);
    try std.testing.expect(document.root.mapping.pairs[0].value == document.root.mapping.pairs[1].value);

    const emitted = try dump(std.testing.allocator, document.root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\answer: &answer !!int 42
        \\again: *answer
        \\
    , emitted);
}

test "load preserves collection style anchor and tag metadata" {
    var sequence_document = try load(std.testing.allocator,
        \\&items !<tag:example.com,2000:items> [one]
        \\
    );
    defer sequence_document.deinit();

    try std.testing.expect(sequence_document.root.* == .sequence);
    try std.testing.expectEqual(CollectionStyle.flow, sequence_document.root.sequence.style);
    try std.testing.expectEqualStrings("items", sequence_document.root.sequence.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:items", sequence_document.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 1), sequence_document.root.sequence.items.len);

    var mapping_document = try load(std.testing.allocator,
        \\&root !<tag:example.com,2000:root> {key: value}
        \\
    );
    defer mapping_document.deinit();

    try std.testing.expect(mapping_document.root.* == .mapping);
    try std.testing.expectEqual(CollectionStyle.flow, mapping_document.root.mapping.style);
    try std.testing.expectEqualStrings("root", mapping_document.root.mapping.anchor.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:root", mapping_document.root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 1), mapping_document.root.mapping.pairs.len);
}

test "loadWithOptions can reject unknown tags" {
    var preserved = try loadWithOptions(std.testing.allocator,
        \\!<tag:example.com,2000:value> value
        \\
    , .{});
    defer preserved.deinit();
    try std.testing.expect(preserved.root.* == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:value", preserved.root.scalar.tag.?);

    var non_specific = try loadWithOptions(std.testing.allocator,
        \\! value
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer non_specific.deinit();
    try std.testing.expect(non_specific.root.* == .scalar);
    try std.testing.expectEqualStrings("!", non_specific.root.scalar.tag.?);

    var standard_set = try loadWithOptions(std.testing.allocator,
        \\!!set
        \\? key
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer standard_set.deinit();
    try std.testing.expect(standard_set.root.* == .mapping);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:set", standard_set.root.mapping.tag.?);

    var standard_binary = try loadWithOptions(std.testing.allocator,
        \\!!binary SGVsbG8=
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer standard_binary.deinit();
    try expectScalarString(standard_binary.root, "SGVsbG8=");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:binary", standard_binary.root.scalar.tag.?);

    var standard_timestamp = try loadWithOptions(std.testing.allocator,
        \\!!timestamp 2001-12-15T02:59:43.1Z
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer standard_timestamp.deinit();
    try expectScalarString(standard_timestamp.root, "2001-12-15T02:59:43.1Z");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", standard_timestamp.root.scalar.tag.?);

    var standard_omap = try loadWithOptions(std.testing.allocator,
        \\!!omap
        \\- a: 1
        \\- b: 2
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer standard_omap.deinit();
    try std.testing.expect(standard_omap.root.* == .sequence);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:omap", standard_omap.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), standard_omap.root.sequence.items.len);

    var standard_pairs = try loadWithOptions(std.testing.allocator,
        \\!!pairs
        \\- a: 1
        \\- b: 2
        \\
    , .{ .unknown_tag_behavior = .reject });
    defer standard_pairs.deinit();
    try std.testing.expect(standard_pairs.root.* == .sequence);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:pairs", standard_pairs.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), standard_pairs.root.sequence.items.len);

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!local value
        \\
    , .{
        .unknown_tag_behavior = .reject,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected unknown tag", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!<tag:example.com,2000:items> [one]
        \\
    , .{
        .unknown_tag_behavior = .reject,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected unknown tag", diagnostic.message);
}

test "load rejects recognized standard tags applied to the wrong node kind" {
    try expectLoadInvalidSyntax(
        \\!!seq scalar
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!map scalar
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!str [value]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool [true]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!binary [SGVsbG8=]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp [2001-12-15]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!omap {a: 1}
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!pairs {a: 1}
        \\
    );
}

test "load rejects invalid standard set ordered mapping and pairs content" {
    try expectLoadInvalidSyntax(
        \\!!set {a: 1}
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!omap
        \\- {a: 1, b: 2}
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!omap
        \\- [a, b]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!omap
        \\- a: 1
        \\- a: 2
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!pairs
        \\- {a: 1, b: 2}
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!pairs
        \\- [a, b]
        \\
    );
}

test "load validates explicit standard binary scalar content" {
    var plain_document = try load(std.testing.allocator,
        \\!!binary SGVsbG8=
        \\
    );
    defer plain_document.deinit();
    try expectScalarString(plain_document.root, "SGVsbG8=");

    var quoted_document = try load(std.testing.allocator,
        \\!!binary "SGVsbG8="
        \\
    );
    defer quoted_document.deinit();
    try expectScalarString(quoted_document.root, "SGVsbG8=");

    var literal_document = try load(std.testing.allocator,
        \\!!binary |
        \\  SGVs
        \\  bG8=
        \\
    );
    defer literal_document.deinit();
    try expectScalarString(literal_document.root, "SGVs\nbG8=\n");

    var folded_document = try load(std.testing.allocator,
        \\!!binary >
        \\  SGVs
        \\  bG8=
        \\
    );
    defer folded_document.deinit();
    try expectScalarString(folded_document.root, "SGVs bG8=\n");

    try expectLoadInvalidSyntax(
        \\!!binary SGVsbG8*
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!binary SGVsbG8
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!binary SG=VsbG8
        \\
    );
}

test "load validates explicit standard timestamp scalar content" {
    var date_document = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15
        \\
    );
    defer date_document.deinit();
    try expectScalarString(date_document.root, "2001-12-15");

    var datetime_document = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15T02:59:43.1Z
        \\
    );
    defer datetime_document.deinit();
    try expectScalarString(datetime_document.root, "2001-12-15T02:59:43.1Z");

    var separated_datetime_document = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15 02:59:43 -5:00
        \\
    );
    defer separated_datetime_document.deinit();
    try expectScalarString(separated_datetime_document.root, "2001-12-15 02:59:43 -5:00");

    try expectLoadInvalidSyntax(
        \\!!timestamp not-a-date
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-13-15
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-1-15
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-5
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T2:59:43Z
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp "2001-12-15T02:59:43 "
        \\
    );
}

test "load rejects invalid explicit null scalar content" {
    try expectLoadInvalidSyntax(
        \\!!null not-null
        \\
    );
}

test "load resolves aliases to the most recent duplicate anchor" {
    var document = try load(std.testing.allocator,
        \\- &item first
        \\- &item second
        \\- *item
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), document.root.sequence.items.len);

    const first = document.root.sequence.items[0];
    const second = document.root.sequence.items[1];
    const alias = document.root.sequence.items[2];

    try std.testing.expect(first != second);
    try std.testing.expectEqual(second, alias);
    try std.testing.expect(first.* == .scalar);
    try std.testing.expect(second.* == .scalar);
    try std.testing.expectEqualStrings("first", first.scalar.value);
    try std.testing.expectEqualStrings("second", second.scalar.value);
}

test "loadStream rejects aliases to anchors from previous documents" {
    try std.testing.expectError(ParseError.InvalidSyntax, loadStream(std.testing.allocator,
        \\--- &base one
        \\--- *base
        \\
    ));
}

test "load rejects duplicate float mapping keys after core resolution" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\1.0: first
        \\1.00: second
        \\
    ));

    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\.NAN: first
        \\.nan: second
        \\
    ));
}

test "load rejects duplicate sequence mapping keys by structure" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\? [one, two]
        \\: first
        \\? [one, two]
        \\: second
        \\
    ));
}

test "load rejects duplicate mapping keys by structure" {
    try std.testing.expectError(ParseError.InvalidSyntax, load(std.testing.allocator,
        \\? {left: one, right: two}
        \\: first
        \\? {right: two, left: one}
        \\: second
        \\
    ));
}

test "load allows distinct nested mapping keys" {
    var document = try load(std.testing.allocator,
        \\? {left: one}
        \\: first
        \\? {left: two}
        \\: second
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), document.root.mapping.pairs.len);
}

test "load rejects duplicate standard set keys when duplicate mappings are allowed" {
    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!!set
        \\? a
        \\? a
        \\
    , .{ .duplicate_key_behavior = .allow }));
}

test "load preserves standard collection duplicate-key semantics" {
    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator,
        \\!!omap
        \\- a: first
        \\- a: second
        \\
    , .{ .duplicate_key_behavior = .allow }));

    var pairs = try loadWithOptions(std.testing.allocator,
        \\!!pairs
        \\- a: first
        \\- a: second
        \\
    , .{});
    defer pairs.deinit();

    try std.testing.expect(pairs.root.* == .sequence);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:pairs", pairs.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), pairs.root.sequence.items.len);

    try std.testing.expect(pairs.root.sequence.items[0].* == .mapping);
    try std.testing.expect(pairs.root.sequence.items[1].* == .mapping);
    try expectScalarString(pairs.root.sequence.items[0].mapping.pairs[0].key, "a");
    try expectScalarString(pairs.root.sequence.items[0].mapping.pairs[0].value, "first");
    try expectScalarString(pairs.root.sequence.items[1].mapping.pairs[0].key, "a");
    try expectScalarString(pairs.root.sequence.items[1].mapping.pairs[0].value, "second");
}

test "loadStream treats explicit empty documents as null nodes" {
    var stream = try yaml.loadStream(std.testing.allocator,
        \\---
        \\...
        \\---
        \\...
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 2), stream.documents.len);
    try std.testing.expect(stream.documents[0].* == .null_value);
    try std.testing.expect(stream.documents[1].* == .null_value);
}

test "dumpStream preserves explicit empty document count" {
    var loaded = try yaml.loadStream(std.testing.allocator,
        \\---
        \\...
        \\---
        \\...
        \\
    );
    defer loaded.deinit();

    const dumped = try yaml.dumpStream(std.testing.allocator, loaded.documents);
    defer std.testing.allocator.free(dumped);

    var reparsed = try yaml.loadStream(std.testing.allocator, dumped);
    defer reparsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), reparsed.documents.len);
    try std.testing.expect(reparsed.documents[0].* == .null_value);
    try std.testing.expect(reparsed.documents[1].* == .null_value);
}
