//! Purpose: Validate standard YAML tag compatibility with representation node kinds.
//! Owns: Standard tag-to-node-kind checks used during construction.
//! Does not own: Scalar schema resolution, tag handle parsing, or emitter tag formatting.
//! Depends on: common/diagnostic.zig, schema/scalars.zig.
//! Tested by: in-file tests and loader/conformance tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const scalars = @import("scalars.zig");

const ParseError = diagnostic.ParseError;

pub const NodeKind = enum {
    scalar,
    sequence,
    mapping,
};

/// Returns true for local or otherwise unrecognized tags.
///
/// Null means the parser did not attach an explicit tag. `!` is the YAML
/// non-specific tag and is accepted as a known tag spelling.
pub fn isUnknownTag(tag: ?[]const u8) bool {
    const value = tag orelse return false;
    if (std.mem.eql(u8, value, "!")) return false;
    return !isKnownStandardTag(value);
}

/// Rejects a known standard YAML tag when it is attached to an incompatible
/// graph node kind. Unknown or local tags are preserved for later consumers.
pub fn validateStandardTagKind(tag: ?[]const u8, kind: NodeKind) ParseError!void {
    const value = tag orelse return;
    if (isKnownScalarTag(value)) {
        if (kind != .scalar) return ParseError.InvalidSyntax;
        return;
    }

    if (std.mem.eql(u8, value, "tag:yaml.org,2002:seq")) {
        if (kind != .sequence) return ParseError.InvalidSyntax;
        return;
    }

    if (std.mem.eql(u8, value, "tag:yaml.org,2002:omap")) {
        if (kind != .sequence) return ParseError.InvalidSyntax;
        return;
    }

    if (std.mem.eql(u8, value, "tag:yaml.org,2002:pairs")) {
        if (kind != .sequence) return ParseError.InvalidSyntax;
        return;
    }

    if (std.mem.eql(u8, value, "tag:yaml.org,2002:map")) {
        if (kind != .mapping) return ParseError.InvalidSyntax;
        return;
    }

    if (std.mem.eql(u8, value, "tag:yaml.org,2002:set")) {
        if (kind != .mapping) return ParseError.InvalidSyntax;
    }
}

pub fn isStandardOmapTag(tag: ?[]const u8) bool {
    return if (tag) |value| std.mem.eql(u8, value, "tag:yaml.org,2002:omap") else false;
}

pub fn isStandardPairsTag(tag: ?[]const u8) bool {
    return if (tag) |value| std.mem.eql(u8, value, "tag:yaml.org,2002:pairs") else false;
}

pub fn isStandardSetTag(tag: ?[]const u8) bool {
    return if (tag) |value| std.mem.eql(u8, value, "tag:yaml.org,2002:set") else false;
}

pub fn validateStandardBinaryContent(node_tag: ?[]const u8, value: []const u8) ParseError!void {
    if (!isStandardBinaryTag(node_tag)) return;

    var significant_len: usize = 0;
    var padding_count: usize = 0;
    var saw_padding = false;

    for (value) |byte| {
        if (isBinaryWhitespace(byte)) continue;

        if (byte == '=') {
            saw_padding = true;
            padding_count += 1;
            if (padding_count > 2) return ParseError.InvalidSyntax;
        } else {
            if (!isBase64DataByte(byte) or saw_padding) return ParseError.InvalidSyntax;
        }
        significant_len += 1;
    }

    if (significant_len % 4 != 0) return ParseError.InvalidSyntax;
}

pub fn validateStandardTimestampContent(node_tag: ?[]const u8, value: []const u8) ParseError!void {
    if (!isStandardTimestampTag(node_tag)) return;
    if (!scalars.timestamp_scalar.isValid(value)) return ParseError.InvalidSyntax;
}

fn isStandardBinaryTag(tag: ?[]const u8) bool {
    return if (tag) |value| std.mem.eql(u8, value, "tag:yaml.org,2002:binary") else false;
}

fn isStandardTimestampTag(tag: ?[]const u8) bool {
    return if (tag) |value| std.mem.eql(u8, value, "tag:yaml.org,2002:timestamp") else false;
}

fn isBinaryWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn isBase64DataByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '+' or
        byte == '/';
}

fn isKnownStandardTag(value: []const u8) bool {
    return isKnownScalarTag(value) or
        std.mem.eql(u8, value, "tag:yaml.org,2002:seq") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:omap") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:pairs") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:map") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:set");
}

fn isKnownScalarTag(value: []const u8) bool {
    return std.mem.eql(u8, value, "tag:yaml.org,2002:str") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:null") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:bool") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:int") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:float") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:binary") or
        std.mem.eql(u8, value, "tag:yaml.org,2002:timestamp");
}

test "schema tag: accepts compatible standard tags" {
    try validateStandardTagKind(null, .mapping);
    try validateStandardTagKind("!", .sequence);
    try validateStandardTagKind("tag:yaml.org,2002:str", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:null", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:bool", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:float", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:binary", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:timestamp", .scalar);
    try validateStandardTagKind("tag:yaml.org,2002:seq", .sequence);
    try validateStandardTagKind("tag:yaml.org,2002:omap", .sequence);
    try validateStandardTagKind("tag:yaml.org,2002:pairs", .sequence);
    try validateStandardTagKind("tag:yaml.org,2002:map", .mapping);
    try validateStandardTagKind("tag:yaml.org,2002:set", .mapping);
    try validateStandardTagKind("!custom", .mapping);
}

test "schema tag: rejects incompatible standard tags" {
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:null", .sequence));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:bool", .mapping));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:int", .mapping));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:float", .sequence));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:binary", .mapping));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:timestamp", .sequence));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:seq", .scalar));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:omap", .mapping));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:pairs", .mapping));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:map", .sequence));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTagKind("tag:yaml.org,2002:set", .sequence));
}

test "schema tag: classifies unknown tag spellings" {
    try std.testing.expect(!isUnknownTag(null));
    try std.testing.expect(!isUnknownTag("!"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:str"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:null"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:bool"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:int"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:float"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:binary"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:timestamp"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:seq"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:omap"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:pairs"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:map"));
    try std.testing.expect(!isUnknownTag("tag:yaml.org,2002:set"));
    try std.testing.expect(isUnknownTag("!local"));
    try std.testing.expect(isUnknownTag("!<tag:example.com,2000:value>"));
    try std.testing.expect(isUnknownTag("tag:example.com,2000:value"));
    try std.testing.expect(isUnknownTag("tag:yaml.org,2002:merge"));
}

test "schema tag: identifies standard collection tags with content constraints" {
    try std.testing.expect(isStandardOmapTag("tag:yaml.org,2002:omap"));
    try std.testing.expect(!isStandardOmapTag("tag:yaml.org,2002:seq"));
    try std.testing.expect(!isStandardOmapTag(null));

    try std.testing.expect(isStandardPairsTag("tag:yaml.org,2002:pairs"));
    try std.testing.expect(!isStandardPairsTag("tag:yaml.org,2002:seq"));
    try std.testing.expect(!isStandardPairsTag(null));

    try std.testing.expect(isStandardSetTag("tag:yaml.org,2002:set"));
    try std.testing.expect(!isStandardSetTag("tag:yaml.org,2002:map"));
    try std.testing.expect(!isStandardSetTag(null));
}

test "schema tag: validates standard binary base64 content" {
    try validateStandardBinaryContent("tag:yaml.org,2002:binary", "SGVsbG8=");
    try validateStandardBinaryContent("tag:yaml.org,2002:binary", "SGVs\nbG8=\n");
    try validateStandardBinaryContent("tag:yaml.org,2002:binary", "TQ==\t\r\n");
    try validateStandardBinaryContent("tag:yaml.org,2002:binary", "T W E =");
    try validateStandardBinaryContent("tag:yaml.org,2002:binary", "");
    try validateStandardBinaryContent("tag:yaml.org,2002:str", "not base64*");

    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "SGVsbG8*"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "SGVsbG8"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "SG=VsbG8"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "TQ==AA"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "TQ==\nAA"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardBinaryContent("tag:yaml.org,2002:binary", "SGVsbG8==="));
}

test "schema tag: validates standard timestamp content" {
    try validateStandardTimestampContent("tag:yaml.org,2002:timestamp", "2001-12-15");
    try validateStandardTimestampContent("tag:yaml.org,2002:timestamp", "2001-12-15T02:59:43.1Z");
    try validateStandardTimestampContent("tag:yaml.org,2002:str", "not-a-date");

    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTimestampContent("tag:yaml.org,2002:timestamp", "not-a-date"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTimestampContent("tag:yaml.org,2002:timestamp", "2001-13-15"));
    try std.testing.expectError(ParseError.InvalidSyntax, validateStandardTimestampContent("tag:yaml.org,2002:timestamp", "2001-12-15T02:59"));
}
