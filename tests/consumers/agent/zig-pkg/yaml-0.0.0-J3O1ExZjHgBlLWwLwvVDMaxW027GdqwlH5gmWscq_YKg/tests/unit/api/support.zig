//! Purpose: Shared setup for public root API regression test shards.
//! Owns: Common imports, aliases, scalar assertions, and malformed-input fuzz helpers.
//! Does not own: Public API behavior assertions.
//! Depends on: public yaml module.
//! Tested by: tests/unit/api/root_api_test.zig.

pub const std = @import("std");
pub const yaml = @import("yaml");

pub const CollectionStyle = yaml.CollectionStyle;
pub const Diagnostic = yaml.Diagnostic;
pub const DumpOptions = yaml.DumpOptions;
pub const Error = yaml.Error;
pub const Event = yaml.Event;
pub const EmitOptions = yaml.EmitOptions;
pub const MappingPair = yaml.MappingPair;
pub const Node = yaml.Node;
pub const ParseError = yaml.ParseError;
pub const ScalarStyle = yaml.ScalarStyle;
pub const TagDirective = yaml.TagDirective;
pub const dump = yaml.dump;
pub const dumpStream = yaml.dumpStream;
pub const dumpWithOptions = yaml.dumpWithOptions;
pub const emitValue = yaml.emitValue;
pub const emitValueWithOptions = yaml.emitValueWithOptions;
pub const emitEvents = yaml.emitEvents;
pub const emitEventsWithOptions = yaml.emitEventsWithOptions;
pub const load = yaml.load;
pub const loadStream = yaml.loadStream;
pub const loadStreamWithOptions = yaml.loadStreamWithOptions;
pub const loadWithOptions = yaml.loadWithOptions;
pub const parseEvents = yaml.parseEvents;
pub const parseEventsWithOptions = yaml.parseEventsWithOptions;
pub const scanner = yaml.scanner;
pub const max_parse_flow_depth: usize = 256;

pub fn expectJsonSchemaLoadInvalid(input: []const u8) !void {
    var document = loadWithOptions(std.testing.allocator, input, .{ .schema = .json }) catch |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
        return;
    };
    defer document.deinit();
    return error.TestExpectedError;
}

pub fn expectLoadInvalidSyntax(input: []const u8) !void {
    if (load(std.testing.allocator, input)) |document| {
        var loaded = document;
        loaded.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
    }
}

pub fn expectScalarString(node: *const Node, expected: []const u8) !void {
    try std.testing.expect(node.* == .scalar);
    try std.testing.expectEqualStrings(expected, node.scalar.value);
}

pub const yaml_safety_fuzz_corpus = [_][]const u8{
    "",
    "\xff",
    "\xc0\x80",
    "key: value\n",
    "- one\n- two\n",
    "[one, {two: three}]\n",
    "&anchor {ref: *anchor}\n",
    "*missing\n",
    "\"unterminated\n",
    "|\n  literal\n",
    "%YAML 1.2\n---\ntrue\n",
};

pub fn fuzzYamlSafety(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    if (smith.in) |input| {
        try exerciseYamlInput(input);
        return;
    }

    const Weight = std.testing.Smith.Weight;
    const len_weights = &.{
        Weight.rangeAtMost(u32, 0, 128, 8),
        Weight.rangeAtMost(u32, 129, 512, 1),
    };
    const byte_weights = &.{
        Weight.rangeAtMost(u8, 0x00, 0xff, 1),
        Weight.rangeAtMost(u8, 0x20, 0x7e, 6),
        Weight.value(u8, '\n', 10),
        Weight.value(u8, '\r', 3),
        Weight.value(u8, ' ', 12),
        Weight.value(u8, '\t', 4),
        Weight.value(u8, '-', 5),
        Weight.value(u8, ':', 5),
        Weight.value(u8, '[', 4),
        Weight.value(u8, ']', 4),
        Weight.value(u8, '{', 4),
        Weight.value(u8, '}', 4),
        Weight.value(u8, '"', 4),
        Weight.value(u8, '\'', 4),
        Weight.value(u8, '#', 3),
        Weight.value(u8, '&', 3),
        Weight.value(u8, '*', 3),
        Weight.value(u8, '!', 3),
        Weight.value(u8, '|', 3),
        Weight.value(u8, '>', 3),
        Weight.value(u8, '%', 2),
        Weight.value(u8, 0xef, 2),
        Weight.value(u8, 0xbb, 2),
        Weight.value(u8, 0xbf, 2),
    };

    var input_buffer: [512]u8 = undefined;
    const len = smith.sliceWeighted(&input_buffer, len_weights, byte_weights);
    try exerciseYamlInput(input_buffer[0..len]);
}

pub fn exerciseYamlInput(input: []const u8) !void {
    var parsed = parseEvents(std.testing.allocator, input) catch |err| {
        try expectSafeYamlError(err);
        return;
    };
    defer parsed.deinit();

    var loaded = loadStream(std.testing.allocator, input) catch |err| {
        try expectSafeYamlError(err);
        return;
    };
    defer loaded.deinit();

    const emitted = emitEvents(std.testing.allocator, parsed.events) catch |err| {
        try expectSafeYamlError(err);
        return;
    };
    defer std.testing.allocator.free(emitted);

    var reparsed_emitted = try parseEvents(std.testing.allocator, emitted);
    defer reparsed_emitted.deinit();

    const dumped = dumpStream(std.testing.allocator, loaded.documents) catch |err| {
        try expectSafeYamlError(err);
        return;
    };
    defer std.testing.allocator.free(dumped);

    var reparsed_dumped = try parseEvents(std.testing.allocator, dumped);
    defer reparsed_dumped.deinit();
}

fn expectSafeYamlError(err: Error) Error!void {
    switch (err) {
        error.InvalidSyntax, error.Unsupported => {},
        error.OutOfMemory => return err,
    }
}
