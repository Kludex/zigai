//! Purpose: Consolidate public root API tag regression tests.
//! Owns: Public tag loading, parsing, directive, and emission behavior assertions.
//! Does not own: Parse, load, emit, dump, diagnostic, or limit behavior outside tag handling.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const CollectionStyle = support.CollectionStyle;
const EmitOptions = support.EmitOptions;
const Event = support.Event;
const Node = support.Node;
const ParseError = support.ParseError;
const TagDirective = support.TagDirective;
const emitEvents = support.emitEvents;
const emitEventsWithOptions = support.emitEventsWithOptions;
const load = support.load;
const loadWithOptions = support.loadWithOptions;
const parseEvents = support.parseEvents;
const expectLoadInvalidSyntax = support.expectLoadInvalidSyntax;
const expectScalarString = support.expectScalarString;

test "loadWithOptions non-specific scalar tag disables schema resolution" {
    var core_document = try loadWithOptions(std.testing.allocator,
        \\! true
        \\
    , .{ .schema = .core });
    defer core_document.deinit();
    try expectScalarString(core_document.root, "true");
    try std.testing.expectEqualStrings("!", core_document.root.scalar.tag.?);

    var json_document = try loadWithOptions(std.testing.allocator,
        \\! True
        \\
    , .{ .schema = .json });
    defer json_document.deinit();
    try expectScalarString(json_document.root, "True");
    try std.testing.expectEqualStrings("!", json_document.root.scalar.tag.?);
}

test "loadWithOptions non-specific collection tag preserves node kind" {
    var sequence_document = try loadWithOptions(std.testing.allocator,
        \\! [true]
        \\
    , .{ .schema = .core });
    defer sequence_document.deinit();
    try std.testing.expect(sequence_document.root.* == .sequence);
    try std.testing.expectEqual(CollectionStyle.flow, sequence_document.root.sequence.style);
    try std.testing.expectEqualStrings("!", sequence_document.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 1), sequence_document.root.sequence.items.len);
    try std.testing.expect(sequence_document.root.sequence.items[0].* == .bool_value);

    var mapping_document = try loadWithOptions(std.testing.allocator,
        \\! {key: false}
        \\
    , .{ .schema = .core });
    defer mapping_document.deinit();
    try std.testing.expect(mapping_document.root.* == .mapping);
    try std.testing.expectEqual(CollectionStyle.flow, mapping_document.root.mapping.style);
    try std.testing.expectEqualStrings("!", mapping_document.root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 1), mapping_document.root.mapping.pairs.len);
    try expectScalarString(mapping_document.root.mapping.pairs[0].key, "key");
    try std.testing.expect(mapping_document.root.mapping.pairs[0].value.* == .bool_value);
}
test "load: explicit string tag preserves core-like scalar content" {
    var document = try load(std.testing.allocator,
        \\[!!str null, !!str true, !!str 42, !!str 1.5, !!str "quoted"]
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 5), document.root.sequence.items.len);

    try expectString(document.root.sequence.items[0], "null");
    try expectString(document.root.sequence.items[1], "true");
    try expectString(document.root.sequence.items[2], "42");
    try expectString(document.root.sequence.items[3], "1.5");
    try expectString(document.root.sequence.items[4], "quoted");
}

test "load: explicit string tag rejects collection nodes" {
    try expectLoadInvalidSyntax(
        \\!!str [value]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!str {key: value}
        \\
    );
}

fn expectString(node: *const Node, expected: []const u8) !void {
    try std.testing.expect(node.* == .scalar);
    try std.testing.expectEqualStrings(expected, node.scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", node.scalar.tag.?);
}
test "load: explicit null tag accepts core null spellings" {
    var document = try load(std.testing.allocator,
        \\[!!null "", !!null "~", !!null NULL]
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), document.root.sequence.items.len);

    try expectNull(document.root.sequence.items[0]);
    try expectNull(document.root.sequence.items[1]);
    try expectNull(document.root.sequence.items[2]);
}

test "load: explicit null tag rejects malformed spellings" {
    try expectLoadInvalidSyntax(
        \\!!null not-null
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!null "null "
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!null NULLish
        \\
    );
}

fn expectNull(node: *const Node) !void {
    try std.testing.expect(node.* == .null_value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:null", node.null_value.tag.?);
}
test "load validates explicit boolean tag boundaries" {
    var lowercase_true = try load(std.testing.allocator,
        \\!!bool true
        \\
    );
    defer lowercase_true.deinit();
    try std.testing.expect(lowercase_true.root.* == .bool_value);
    try std.testing.expectEqual(true, lowercase_true.root.bool_value.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:bool", lowercase_true.root.bool_value.tag.?);

    var uppercase_false = try load(std.testing.allocator,
        \\!!bool FALSE
        \\
    );
    defer uppercase_false.deinit();
    try std.testing.expect(uppercase_false.root.* == .bool_value);
    try std.testing.expectEqual(false, uppercase_false.root.bool_value.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:bool", uppercase_false.root.bool_value.tag.?);

    var quoted_true = try load(std.testing.allocator,
        \\!!bool "True"
        \\
    );
    defer quoted_true.deinit();
    try std.testing.expect(quoted_true.root.* == .bool_value);
    try std.testing.expectEqual(true, quoted_true.root.bool_value.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:bool", quoted_true.root.bool_value.tag.?);

    try expectLoadInvalidSyntax(
        \\!!bool yes
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool Off
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool truth
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool falsehood
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool +true
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool -false
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!bool .true
        \\
    );
}
test "load: explicit integer tag accepts signed core spellings" {
    var document = try load(std.testing.allocator,
        \\[!!int "+42", !!int -0o7, !!int +0x2A]
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), document.root.sequence.items.len);

    try expectInt(document.root.sequence.items[0], 42);
    try expectInt(document.root.sequence.items[1], -7);
    try expectInt(document.root.sequence.items[2], 42);
}

test "load: explicit integer tag rejects malformed spellings" {
    try expectLoadInvalidSyntax(
        \\!!int 12.3
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!int 0o8
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!int 0x
        \\
    );
}

fn expectInt(node: *const Node, expected: i128) !void {
    try std.testing.expect(node.* == .int_value);
    try std.testing.expectEqual(expected, node.int_value.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:int", node.int_value.tag.?);
}
test "load: explicit float tag accepts core spellings" {
    var document = try load(std.testing.allocator,
        \\[!!float "42", !!float -0.5, !!float +1e3, !!float .25]
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 4), document.root.sequence.items.len);

    try expectFloat(document.root.sequence.items[0], 42);
    try expectFloat(document.root.sequence.items[1], -0.5);
    try expectFloat(document.root.sequence.items[2], 1000);
    try expectFloat(document.root.sequence.items[3], 0.25);
}

test "load: explicit float tag accepts special values" {
    var document = try load(std.testing.allocator,
        \\[!!float .inf, !!float -.Inf, !!float .NAN]
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), document.root.sequence.items.len);

    try expectFloatTag(document.root.sequence.items[0]);
    try std.testing.expect(std.math.isPositiveInf(document.root.sequence.items[0].float_value.value));

    try expectFloatTag(document.root.sequence.items[1]);
    try std.testing.expect(std.math.isNegativeInf(document.root.sequence.items[1].float_value.value));

    try expectFloatTag(document.root.sequence.items[2]);
    try std.testing.expect(std.math.isNan(document.root.sequence.items[2].float_value.value));
}

test "load: explicit float tag rejects malformed spellings" {
    try expectLoadInvalidSyntax(
        \\!!float .
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!float 1e+
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!float +.NaN
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!float 0x1.0p0
        \\
    );
}

fn expectFloat(node: *const Node, expected: f64) !void {
    try expectFloatTag(node);
    try std.testing.expectEqual(expected, node.float_value.value);
}

fn expectFloatTag(node: *const Node) !void {
    try std.testing.expect(node.* == .float_value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:float", node.float_value.tag.?);
}
test "load validates explicit binary padding boundaries" {
    var padded_document = try load(std.testing.allocator,
        \\!!binary TQ==
        \\
    );
    defer padded_document.deinit();
    try expectScalarString(padded_document.root, "TQ==");

    var separated_document = try load(std.testing.allocator,
        \\!!binary T W E =
        \\
    );
    defer separated_document.deinit();
    try expectScalarString(separated_document.root, "T W E =");

    try expectLoadInvalidSyntax(
        \\!!binary TQ==AA
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!binary |
        \\  TQ==
        \\  AA
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!binary SGVsbG8===
        \\
    );
}
test "load accepts YAML 1.2.2 explicit timestamp examples" {
    var canonical = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15T02:59:43.1Z
        \\
    );
    defer canonical.deinit();
    try expectScalarString(canonical.root, "2001-12-15T02:59:43.1Z");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", canonical.root.scalar.tag.?);

    var iso8601 = try load(std.testing.allocator,
        \\!!timestamp 2001-12-14t21:59:43.10-05:00
        \\
    );
    defer iso8601.deinit();
    try expectScalarString(iso8601.root, "2001-12-14t21:59:43.10-05:00");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", iso8601.root.scalar.tag.?);

    var spaced = try load(std.testing.allocator,
        \\!!timestamp 2001-12-14 21:59:43.10 -5
        \\
    );
    defer spaced.deinit();
    try expectScalarString(spaced.root, "2001-12-14 21:59:43.10 -5");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", spaced.root.scalar.tag.?);

    var date = try load(std.testing.allocator,
        \\!!timestamp 2002-12-14
        \\
    );
    defer date.deinit();
    try expectScalarString(date.root, "2002-12-14");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", date.root.scalar.tag.?);
}

test "load validates explicit timestamp date boundaries" {
    var leap_2000 = try load(std.testing.allocator,
        \\!!timestamp 2000-02-29
        \\
    );
    defer leap_2000.deinit();
    try expectScalarString(leap_2000.root, "2000-02-29");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", leap_2000.root.scalar.tag.?);

    var leap_2400 = try load(std.testing.allocator,
        \\!!timestamp 2400-02-29
        \\
    );
    defer leap_2400.deinit();
    try expectScalarString(leap_2400.root, "2400-02-29");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", leap_2400.root.scalar.tag.?);

    try expectLoadInvalidSyntax(
        \\!!timestamp 1900-02-29
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-02-29
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-00
        \\
    );
}

test "load validates explicit timestamp tag on quoted scalars" {
    var quoted = try load(std.testing.allocator,
        \\!!timestamp "2001-12-15T02:59:43Z"
        \\
    );
    defer quoted.deinit();
    try expectScalarString(quoted.root, "2001-12-15T02:59:43Z");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", quoted.root.scalar.tag.?);

    try expectLoadInvalidSyntax(
        \\!!timestamp "2001-12-15T02:59:43z"
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp '2001-12-15T02:59:43.'
        \\
    );
}

test "load validates explicit timestamp time-zone boundaries" {
    var max_offset = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15T02:59:43+23:59
        \\
    );
    defer max_offset.deinit();
    try expectScalarString(max_offset.root, "2001-12-15T02:59:43+23:59");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", max_offset.root.scalar.tag.?);

    var compact_positive = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15 02:59:43 +5
        \\
    );
    defer compact_positive.deinit();
    try expectScalarString(compact_positive.root, "2001-12-15 02:59:43 +5");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", compact_positive.root.scalar.tag.?);

    var compact_zero = try load(std.testing.allocator,
        \\!!timestamp 2001-12-15T02:59:43-0:00
        \\
    );
    defer compact_zero.deinit();
    try expectScalarString(compact_zero.root, "2001-12-15T02:59:43-0:00");
    try std.testing.expectEqualStrings("tag:yaml.org,2002:timestamp", compact_zero.root.scalar.tag.?);

    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59:43+24:00
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59:43+23:60
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59:43+5:0
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59:43+
        \\
    );
}

test "load rejects explicit timestamp with empty fractional seconds" {
    try expectLoadInvalidSyntax(
        \\!!timestamp 2001-12-15T02:59:43.Z
        \\
    );
}
test "load: explicit collection tags are preserved on flow collections" {
    var sequence_document = try load(std.testing.allocator,
        \\!!seq [one, two]
        \\
    );
    defer sequence_document.deinit();

    try std.testing.expect(sequence_document.root.* == .sequence);
    try std.testing.expectEqual(CollectionStyle.flow, sequence_document.root.sequence.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:seq", sequence_document.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), sequence_document.root.sequence.items.len);

    var mapping_document = try load(std.testing.allocator,
        \\!!map {key: value}
        \\
    );
    defer mapping_document.deinit();

    try std.testing.expect(mapping_document.root.* == .mapping);
    try std.testing.expectEqual(CollectionStyle.flow, mapping_document.root.mapping.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", mapping_document.root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 1), mapping_document.root.mapping.pairs.len);
}

test "load: explicit collection tags are preserved on block collections" {
    var sequence_document = try load(std.testing.allocator,
        \\!!seq
        \\- one
        \\- two
        \\
    );
    defer sequence_document.deinit();

    try std.testing.expect(sequence_document.root.* == .sequence);
    try std.testing.expectEqual(CollectionStyle.block, sequence_document.root.sequence.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:seq", sequence_document.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), sequence_document.root.sequence.items.len);

    var mapping_document = try load(std.testing.allocator,
        \\!!map
        \\key: value
        \\
    );
    defer mapping_document.deinit();

    try std.testing.expect(mapping_document.root.* == .mapping);
    try std.testing.expectEqual(CollectionStyle.block, mapping_document.root.mapping.style);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:map", mapping_document.root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 1), mapping_document.root.mapping.pairs.len);
}
test "load: standard ordered map and pairs tags preserve valid sequences" {
    var ordered = try load(std.testing.allocator,
        \\!!omap
        \\- one: 1
        \\- two: 2
        \\
    );
    defer ordered.deinit();

    try std.testing.expect(ordered.root.* == .sequence);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:omap", ordered.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), ordered.root.sequence.items.len);

    var pairs = try load(std.testing.allocator,
        \\!!pairs
        \\- one: 1
        \\- one: 2
        \\
    );
    defer pairs.deinit();

    try std.testing.expect(pairs.root.* == .sequence);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:pairs", pairs.root.sequence.tag.?);
    try std.testing.expectEqual(@as(usize, 2), pairs.root.sequence.items.len);
}

test "load: standard set tag preserves valid null-valued mapping" {
    var document = try load(std.testing.allocator,
        \\!!set
        \\? one
        \\? two
        \\
    );
    defer document.deinit();

    try std.testing.expect(document.root.* == .mapping);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:set", document.root.mapping.tag.?);
    try std.testing.expectEqual(@as(usize, 2), document.root.mapping.pairs.len);
}

test "load: standard collection tags reject invalid constrained content" {
    try expectLoadInvalidSyntax(
        \\!!omap
        \\- one: 1
        \\- two: 2
        \\- three: 3
        \\- one: again
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!pairs [plain]
        \\
    );
    try expectLoadInvalidSyntax(
        \\!!set {one: value}
        \\
    );
}
test "emitEvents preserves YAML directives on empty documents" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .yaml_version = "1.2",
        } },
        .{ .scalar = .{ .value = "" } },
        .{ .document_end = .{ .explicit = true } },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%YAML 1.2
        \\---
        \\...
        \\
    , emitted);
}

test "emitEvents preserves major-one YAML directive minor versions" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .yaml_version = "1.3",
        } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%YAML 1.3
        \\--- value
        \\
    , emitted);
}

test "emitEvents rejects invalid YAML directive versions" {
    const invalid_versions = [_][]const u8{
        "1",
        ".2",
        "1.",
        "1.2.3",
        "1.x",
        "65536.0",
    };

    for (invalid_versions) |version| {
        const events = [_]Event{
            .stream_start,
            .{ .document_start = .{
                .explicit = true,
                .yaml_version = version,
            } },
            .{ .scalar = .{ .value = "value" } },
            .{ .document_end = .{} },
            .stream_end,
        };

        try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
    }
}

test "emitEvents rejects unsupported YAML directive major versions" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .yaml_version = "2.0",
        } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}
test "emitEvents emits a top-level scalar tag" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "tag:example.com,2000:app/foo",
            .value = "bar",
            .style = .double_quoted,
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- !<tag:example.com,2000:app/foo> "bar"
        \\
    , emitted);
}

test "emitEvents percent-encodes global tag URI characters" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "tag:example.com,2000:app/foo bar%",
            .value = "bar",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- !<tag:example.com,2000:app/foo%20bar%25> bar
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();

    try std.testing.expect(parsed.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo bar%", parsed.events[2].scalar.tag.?);
}

test "emitEvents rejects global tags without a URI scheme" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "not-a-uri",
            .value = "bar",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    if (emitEvents(std.testing.allocator, &events)) |emitted| {
        defer std.testing.allocator.free(emitted);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
    }
}

test "emitEventsWithOptions puts top-level global scalar tag on document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "first" } },
        .{ .document_end = .{} },
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "tag:example.com,2000:app/foo",
            .value = "bar",
            .style = .double_quoted,
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
        \\--- first
        \\--- !<tag:example.com,2000:app/foo>
        \\"bar"
        \\
    , emitted);
}

test "emitEventsWithOptions keeps top-level plain global tagged scalar on document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "tag:yaml.org,2002:str",
            .value = "d e",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- !!str d e
        \\
    , emitted);
}

test "emitEventsWithOptions keeps top-level local tagged scalar after document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "!foo",
            .value = "bar",
            .style = .double_quoted,
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
        \\---
        \\!foo "bar"
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions keeps top-level non-specific tagged scalar on document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "!",
            .value = "a",
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
        \\--- ! a
        \\
    , emitted);
}

test "emitEvents emits declared named tag directives" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!e!",
        .prefix = "tag:example.com,2000:app/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .scalar = .{
            .tag = "!e!foo",
            .value = "bar",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,2000:app/
        \\--- !e!foo bar
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();

    try std.testing.expect(parsed.events[1] == .document_start);
    try std.testing.expectEqual(@as(usize, 1), parsed.events[1].document_start.tag_directives.len);
    try std.testing.expectEqualStrings("!e!", parsed.events[1].document_start.tag_directives[0].handle);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/", parsed.events[1].document_start.tag_directives[0].prefix);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo", parsed.events[2].scalar.tag.?);
}

test "emitEvents rejects undeclared named tag handles" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .tag = "!e!foo",
            .value = "bar",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEvents emits declared named tag directives for sequence nodes" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!e!",
        .prefix = "tag:example.com,2000:app/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .sequence_start = .{
            .style = .block,
            .tag = "!e!seq",
        } },
        .{ .scalar = .{ .value = "item" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,2000:app/
        \\--- !e!seq
        \\- item
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();

    try std.testing.expect(parsed.events[2] == .sequence_start);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/seq", parsed.events[2].sequence_start.tag.?);
}

test "emitEvents rejects undeclared named collection tag handles" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{
            .style = .block,
            .tag = "!e!map",
        } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}
test "emitEvents rejects named tag handles missing from non-empty directives" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!other!",
        .prefix = "tag:example.com,2000:other/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .scalar = .{
            .tag = "!e!foo",
            .value = "bar",
        } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}
test "parseEvents rejects unescaped tag shorthand suffix indicators" {
    const invalid_inputs = [_][]const u8{
        "!bad[suffix value\n",
        "!bad]suffix value\n",
        "!bad,suffix value\n",
        "!!str[suffix value\n",
    };

    for (invalid_inputs) |input| {
        try std.testing.expectError(ParseError.InvalidSyntax, parseEvents(std.testing.allocator, input));
    }
}

test "parseEvents accepts escaped tag shorthand suffix indicators" {
    var events = try parseEvents(std.testing.allocator, "!!str%21suffix value\n");
    defer events.deinit();

    try std.testing.expect(events.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str!suffix", events.events[2].scalar.tag.?);
}
test "emitEvents emits declared named tag directives for mapping nodes" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!e!",
        .prefix = "tag:example.com,2000:app/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .mapping_start = .{
            .style = .block,
            .tag = "!e!map",
        } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,2000:app/
        \\--- !e!map
        \\key: value
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();

    try std.testing.expect(parsed.events[2] == .mapping_start);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/map", parsed.events[2].mapping_start.tag.?);
}
test "emitEvents rejects invalid TAG directive handles" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!bad_handle!",
        .prefix = "tag:example.com,2000:app/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEvents rejects invalid TAG directive prefixes" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!e!",
        .prefix = "[tag:example.com,2000:app/",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEvents rejects duplicate TAG directive handles" {
    const tag_directives = [_]TagDirective{
        .{ .handle = "!e!", .prefix = "tag:example.com,2000:first/" },
        .{ .handle = "!e!", .prefix = "tag:example.com,2000:second/" },
    };
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .tag_directives = &tag_directives,
        } },
        .{ .scalar = .{ .tag = "!e!value", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEvents emits primary TAG directives used by shorthand tags" {
    const tag_directives = [_]TagDirective{.{ .handle = "!", .prefix = "tag:example.com,2000:app/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!foo", .value = "bar" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG ! tag:example.com,2000:app/
        \\--- !foo bar
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo", parsed.events[2].scalar.tag.?);
}

test "emitEvents emits secondary TAG directives used by shorthand tags" {
    const tag_directives = [_]TagDirective{.{ .handle = "!!", .prefix = "tag:example.com,2000:types/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!!thing", .value = "bar" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !! tag:example.com,2000:types/
        \\--- !!thing bar
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:types/thing", parsed.events[2].scalar.tag.?);
}
test "emitEvents emits primary TAG directives used by collection tags" {
    const tag_directives = [_]TagDirective{.{ .handle = "!", .prefix = "tag:example.com,2000:primary/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .sequence_start = .{ .style = .block, .tag = "!items" } },
        .{ .scalar = .{ .value = "value" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG ! tag:example.com,2000:primary/
        \\--- !items
        \\- value
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:primary/items", parsed.events[2].sequence_start.tag.?);
}

test "emitEvents emits secondary TAG directives used by collection tags" {
    const tag_directives = [_]TagDirective{.{ .handle = "!!", .prefix = "tag:example.com,2000:types/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .mapping_start = .{ .style = .flow, .tag = "!!map" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !! tag:example.com,2000:types/
        \\--- !!map {}
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:types/map", parsed.events[2].mapping_start.tag.?);
}
test "emitEvents accepts distinct TAG directive handles in one document" {
    const tag_directives = [_]TagDirective{
        .{ .handle = "!", .prefix = "tag:example.com,2000:primary/" },
        .{ .handle = "!e!", .prefix = "tag:example.com,2000:named/" },
    };
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .sequence_start = .{ .style = .block, .tag = "!root" } },
        .{ .scalar = .{ .tag = "!e!item", .value = "value" } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG ! tag:example.com,2000:primary/
        \\%TAG !e! tag:example.com,2000:named/
        \\--- !root
        \\- !e!item value
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:primary/root", parsed.events[2].sequence_start.tag.?);
    try std.testing.expectEqualStrings("tag:example.com,2000:named/item", parsed.events[3].scalar.tag.?);
}

test "emitEvents preserves local TAG directive prefixes" {
    const tag_directives = [_]TagDirective{.{ .handle = "!m!", .prefix = "!my-" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!m!light", .value = "fluorescent" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !m! !my-
        \\--- !m!light fluorescent
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("!my-light", parsed.events[2].scalar.tag.?);
}
test "emitEvents accepts local TAG directive prefixes" {
    const tag_directives = [_]TagDirective{.{ .handle = "!app!", .prefix = "!local/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!app!value", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !app! !local/
        \\--- !app!value value
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("!local/value", parsed.events[2].scalar.tag.?);
}

test "emitEvents accepts escaped TAG directive prefixes" {
    const tag_directives = [_]TagDirective{.{ .handle = "!e!", .prefix = "tag:example.com,%32%30%30%30:app/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!e!value", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,%32%30%30%30:app/
        \\--- !e!value value
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tag:example.com,2000:app/value", parsed.events[2].scalar.tag.?);
}

test "emitEvents rejects TAG directive prefixes with malformed percent escapes" {
    const tag_directives = [_]TagDirective{.{
        .handle = "!e!",
        .prefix = "tag:example.com/%GG",
    }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .tag = "!e!value", .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
}

test "emitEvents rejects TAG directive prefixes that start with flow indicators" {
    const prefixes = [_][]const u8{ "", "{tag:example.com,2000:app/", "]tag:example.com,2000:app/", ",tag:example.com,2000:app/" };
    for (prefixes) |prefix| {
        const tag_directives = [_]TagDirective{.{ .handle = "!e!", .prefix = prefix }};
        const events = [_]Event{
            .stream_start,
            .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
            .{ .scalar = .{ .value = "value" } },
            .{ .document_end = .{} },
            .stream_end,
        };

        try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &events));
    }
}
test "emitEvents can preserve unused TAG directives" {
    const tag_directives = [_]TagDirective{.{ .handle = "!e!", .prefix = "tag:example.com,2000:app/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, EmitOptions{
        .preserve_unused_tag_directives = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,2000:app/
        \\--- value
        \\
    , emitted);
}

test "emitEvents can preserve unused TAG directives on empty explicit documents" {
    const tag_directives = [_]TagDirective{.{ .handle = "!e!", .prefix = "tag:example.com,2000:app/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .value = "" } },
        .{ .document_end = .{ .explicit = true } },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, EmitOptions{
        .preserve_unused_tag_directives = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\...
        \\
    , emitted);
}

test "emitEvents omits unused TAG directives by default" {
    const tag_directives = [_]TagDirective{.{ .handle = "!e!", .prefix = "tag:example.com,2000:app/" }};
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .tag_directives = &tag_directives } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings("--- value\n", emitted);
}
test "emitEvents emits first document YAML directive" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .yaml_version = "1.2",
        } },
        .{ .scalar = .{ .value = "text" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\%YAML 1.2
        \\--- text
        \\
    , emitted);
}

test "emitEventsWithOptions emits safe marker text in top-level quoted scalar as plain" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
            .content_same_line_separated_by_tab = true,
        } },
        .{ .scalar = .{
            .value = "a ...x b",
            .style = .double_quoted,
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
        \\--- a ...x b
        \\
    , emitted);
}

test "emitEventsWithOptions preserves same-line explicit plain scalar document boundaries" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
            .content_same_line_separated_by_tab = true,
        } },
        .{ .scalar = .{ .value = "scalar" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- scalar
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions keeps directive same-line plain scalar without forced document end" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
            .yaml_version = "1.2",
        } },
        .{ .scalar = .{ .value = "text" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- text
        \\
    , emitted);
}

test "emitEventsWithOptions terminates top-level plain scalars containing directive-looking text" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "scalar %YAML 1.2" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- scalar %YAML 1.2
        \\...
        \\
    , emitted);
}

test "emitEventsWithOptions keeps same-line tagged plain scalar without forced document end" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
        } },
        .{ .scalar = .{
            .tag = "tag:yaml.org,2002:str",
            .value = "d e",
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
        \\--- !!str d e
        \\
    , emitted);
}

test "emitEventsWithOptions keeps explicit top-level single quoted scalar on document start line" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{
            .value = "here's to \"quotes\"",
            .style = .single_quoted,
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
        \\--- 'here''s to "quotes"'
        \\
    , emitted);
}

test "emitEvents keeps top-level multiline plain scalars plain" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "a b c d\ne" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- a b c d
        \\
        \\e
        \\
    , emitted);
}

test "emitEvents quotes multiline plain scalars with block-scalar-looking continuation lines" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .scalar = .{ .value = "cM\n|\n$x#" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- 'cM
        \\
        \\  |
        \\
        \\  $x#'
        \\
    , emitted);

    var parsed = try parseEvents(std.testing.allocator, emitted);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("cM\n|\n$x#", parsed.events[2].scalar.value);
}

test "emitEventsWithOptions keeps same-line plain scalar without tab or anchor open" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
        } },
        .{ .scalar = .{ .value = "foo" } },
        .{ .document_end = .{} },
        .{ .document_start = .{
            .explicit = true,
            .content_same_line = true,
        } },
        .{ .scalar = .{ .value = "foo" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEventsWithOptions(std.testing.allocator, &events, .{
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\--- foo
        \\--- foo
        \\
    , emitted);
}
