//! Purpose: Consolidate public root API safety-limit regression tests.
//! Owns: Public limit, malformed-input safety, and depth-budget assertions.
//! Does not own: Parse, load, emit, dump, diagnostic, or tag success behavior assertions.
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

test "dump escapes constructed scalars containing raw C0 controls" {
    const root: Node = .{ .scalar = .{ .value = "bell \x07 nul \x00" } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"bell \x07 nul \x00"
        \\
    , emitted);
}

test "dump escapes constructed scalars containing raw DEL and C1 controls" {
    const root: Node = .{ .scalar = .{
        .value = "\x7f\xc2\x80\xc2\x9f",
    } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"\x7F\x80\x9F"
        \\
    , emitted);
}

test "dump escapes constructed scalars containing UTF-8 BOM" {
    const root: Node = .{ .scalar = .{ .value = "prefix \xef\xbb\xbf suffix" } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"prefix \uFEFF suffix"
        \\
    , emitted);
}

test "dump escapes constructed scalars containing carriage returns" {
    const root: Node = .{ .scalar = .{ .value = "left" ++ "\r" ++ "right" } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"left\rright"
        \\
    , emitted);

    var reparsed = try load(std.testing.allocator, emitted);
    defer reparsed.deinit();

    try std.testing.expect(reparsed.root.* == .scalar);
    try std.testing.expectEqualStrings("left" ++ "\r" ++ "right", reparsed.root.scalar.value);
}

test "emitEvents escapes non-ASCII codepoints in double quoted scalars" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "Sosa did fine.\xe2\x98\xba", .style = .double_quoted } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"Sosa did fine.\u263A"
        \\
    , emitted);
}

test "emitEvents escapes quotes and non-BMP codepoints in double quoted scalars" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "smile \xF0\x9F\x99\x82 and quote \"", .style = .double_quoted } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\"smile \U0001F642 and quote \""
        \\
    , emitted);
}

test "emitEventsWithOptions quotes non-ASCII plain canonical mapping values" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "wanted" } },
        .{ .scalar = .{ .value = "love \xe2\x99\xa5 and peace \xe2\x98\xae" } },
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
        \\wanted: "love \u2665 and peace \u262E"
        \\
    , emitted);
}

test "emitEvents emits aliases in block mapping values" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "ref" } },
        .{ .alias = "anchor" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const emitted = try emitEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\ref: *anchor
        \\
    , emitted);
}

test "dump emits constructed alias nodes" {
    const key: Node = .{ .scalar = .{ .value = "ref" } };
    const value: Node = .{ .alias = "anchor" };
    const pairs = [_]MappingPair{.{ .key = &key, .value = &value }};
    const root: Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try dump(std.testing.allocator, &root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\---
        \\ref: *anchor
        \\
    , emitted);
}

test "emitEvents rejects anchors and aliases containing YAML line separators" {
    const names = [_][]const u8{
        "bad\xe2\x80\xa8anchor",
        "bad\xe2\x80\xa9anchor",
    };

    for (names) |name| {
        const anchored = [_]Event{
            .stream_start,
            .{ .document_start = .{} },
            .{ .scalar = .{ .value = "value", .anchor = name } },
            .{ .document_end = .{} },
            .stream_end,
        };
        try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &anchored));

        const alias = [_]Event{
            .stream_start,
            .{ .document_start = .{} },
            .{ .alias = name },
            .{ .document_end = .{} },
            .stream_end,
        };
        try std.testing.expectError(ParseError.InvalidSyntax, emitEvents(std.testing.allocator, &alias));
    }
}

test "dump emits aliases for anchored self references" {
    var document = try load(std.testing.allocator,
        \\&anchor {ref: *anchor}
        \\
    );
    defer document.deinit();

    const emitted = try dump(std.testing.allocator, document.root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\&anchor {ref: *anchor}
        \\
    , emitted);
}

test "dump rejects unanchored recursive constructed nodes" {
    const key: Node = .{ .scalar = .{ .value = "ref" } };
    var root: Node = undefined;
    const pairs = [_]MappingPair{.{ .key = &key, .value = &root }};
    root = .{ .mapping = .{ .pairs = &pairs } };

    try std.testing.expectError(ParseError.Unsupported, dump(std.testing.allocator, &root));
}

test "dump emits aliases for repeated anchored nodes" {
    var document = try load(std.testing.allocator,
        \\{root: &anchor [one], again: *anchor}
        \\
    );
    defer document.deinit();

    const emitted = try dump(std.testing.allocator, document.root);
    defer std.testing.allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\{root: &anchor [one], again: *anchor}
        \\
    , emitted);
}

test "parser loader and emitter handle malformed byte corpus safely" {
    for (yaml_safety_fuzz_corpus) |input| {
        try exerciseYamlInput(input);
    }

    var prng = std.Random.DefaultPrng.init(0x9a6d_5eed);
    const random = prng.random();
    var input_buffer: [256]u8 = undefined;
    for (0..64) |_| {
        random.bytes(input_buffer[0..]);
        const input_len = random.intRangeAtMost(usize, 0, input_buffer.len);
        try exerciseYamlInput(input_buffer[0..input_len]);
    }
}

test "parser loader and emitter handle fuzzed top-level plain scalar before block scalar safely" {
    try exerciseYamlInput("cM\r|\n$x#");
}

test "parser loader and emitter handle anchored scalar before explicit document safely" {
    try exerciseYamlInput("---\n&ZKRL 1.2\n---\n");
}

test "fuzz parser loader and emitter malformed byte safety" {
    try std.testing.fuzz({}, fuzzYamlSafety, .{
        .corpus = &yaml_safety_fuzz_corpus,
    });
}

test "parseEvents rejects nesting past parser depth budget" {
    const depth = 300;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    for (0..depth) |_| try input.append(std.testing.allocator, '[');
    try input.appendSlice(std.testing.allocator, "value");
    for (0..depth) |_| try input.append(std.testing.allocator, ']');
    try input.append(std.testing.allocator, '\n');

    try std.testing.expectError(ParseError.Unsupported, parseEvents(std.testing.allocator, input.items));
}

test "parseEventsWithOptions enforces parser limits at exact boundaries" {
    const sequence_input = "- one\n- two\n";

    var token_stream = try scanner.scan(std.testing.allocator, sequence_input);
    defer token_stream.deinit();
    var baseline = try parseEvents(std.testing.allocator, sequence_input);
    defer baseline.deinit();

    var event_boundary = try parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_event_count = baseline.events.len,
    });
    defer event_boundary.deinit();
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_event_count = baseline.events.len - 1,
    }));

    var token_boundary = try parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_token_count = token_stream.tokens.len,
    });
    defer token_boundary.deinit();
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_token_count = token_stream.tokens.len - 1,
    }));

    var scalar_boundary = try parseEventsWithOptions(std.testing.allocator, "abcd\n", .{
        .max_scalar_bytes = 4,
    });
    defer scalar_boundary.deinit();
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
    }));

    var nesting_boundary = try parseEventsWithOptions(std.testing.allocator, "[[value]]\n", .{
        .max_nesting_depth = 2,
    });
    defer nesting_boundary.deinit();
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, "[[value]]\n", .{
        .max_nesting_depth = 1,
    }));
}

test "parseEventsWithOptions reports diagnostics for fused parser limit failures" {
    const sequence_input = "- one\n- two\n";
    var token_stream = try scanner.scan(std.testing.allocator, sequence_input);
    defer token_stream.deinit();
    var baseline = try parseEvents(std.testing.allocator, sequence_input);
    defer baseline.deinit();

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_event_count = baseline.events.len - 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(sequence_input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, sequence_input, .{
        .max_token_count = token_stream.tokens.len - 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(sequence_input.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, "[[value]]\n", .{
        .max_nesting_depth = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

test "parseEventsWithOptions reports nesting depth diagnostic" {
    const depth = 300;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    for (0..depth) |_| try input.append(std.testing.allocator, '[');
    try input.appendSlice(std.testing.allocator, "value");
    for (0..depth) |_| try input.append(std.testing.allocator, ']');
    try input.append(std.testing.allocator, '\n');

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, parseEventsWithOptions(std.testing.allocator, input.items, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(input.items.len, diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
}

test "loadStreamWithOptions reports parse-stage size and depth limits" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, loadStreamWithOptions(std.testing.allocator, "abcd", .{
        .max_input_bytes = 3,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("input exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.column);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, loadStreamWithOptions(std.testing.allocator, "abcd\n", .{
        .max_scalar_bytes = 3,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, loadStreamWithOptions(std.testing.allocator, "[[value]]\n", .{
        .max_nesting_depth = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.offset);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}
