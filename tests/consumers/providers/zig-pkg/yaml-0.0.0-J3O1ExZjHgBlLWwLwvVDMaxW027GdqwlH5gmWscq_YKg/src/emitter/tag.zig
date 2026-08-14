//! Purpose: Emit and validate YAML tag, anchor, and alias property spellings.
//! Owns: Tag percent-encoding, tag URI validation, shorthand tag validation, and anchor name validation.
//! Does not own: Scalar style rendering, collection layout, event traversal, or schema resolution.
//! Depends on: common/diagnostic.zig, parser/event.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance emitter checks.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const event_types = @import("../parser/event.zig");

const Error = common.Error;
const ParseError = common.ParseError;
const TagDirective = event_types.TagDirective;

pub fn appendEmittedTag(allocator: std.mem.Allocator, out: anytype, tag: []const u8) Error!void {
    try validateEmittedTag(tag);

    if (std.mem.startsWith(u8, tag, "!")) {
        try appendPercentEncodedBareTag(allocator, out, tag);
        return;
    }

    const standard_prefix = "tag:yaml.org,2002:";
    if (std.mem.startsWith(u8, tag, standard_prefix) and tag.len > standard_prefix.len) {
        try out.*.appendSlice(allocator, "!!");
        try appendPercentEncodedBareTag(allocator, out, tag[standard_prefix.len..]);
        return;
    }

    try out.*.appendSlice(allocator, "!<");
    try appendPercentEncodedVerbatimTag(allocator, out, tag);
    try out.*.append(allocator, '>');
}

pub fn appendTagDirective(allocator: std.mem.Allocator, out: anytype, directive: TagDirective) Error!void {
    try validateTagDirective(directive);
    try out.*.appendSlice(allocator, "%TAG ");
    try out.*.appendSlice(allocator, directive.handle);
    try out.*.append(allocator, ' ');
    try out.*.appendSlice(allocator, directive.prefix);
    try out.*.append(allocator, '\n');
}

pub fn validateTagDirectives(directives: []const TagDirective) ParseError!void {
    for (directives, 0..) |directive, index| {
        try validateTagDirective(directive);
        for (directives[0..index]) |previous| {
            if (std.mem.eql(u8, previous.handle, directive.handle)) return ParseError.InvalidSyntax;
        }
    }
}

pub fn validateNamedTagsDeclared(events: []const event_types.Event, tag_directives: []const TagDirective) ParseError!void {
    for (events) |event| {
        const tag = switch (event) {
            .scalar => |scalar| scalar.tag,
            .sequence_start => |collection| collection.tag,
            .mapping_start => |collection| collection.tag,
            else => null,
        } orelse continue;

        const handle = namedTagHandle(tag) orelse continue;
        if (!tagHandleDeclared(handle, tag_directives)) return ParseError.InvalidSyntax;
    }
}

pub fn usesDeclaredTagDirective(events: []const event_types.Event, tag_directives: []const TagDirective) bool {
    for (events) |event| {
        const tag = switch (event) {
            .scalar => |scalar| scalar.tag,
            .sequence_start => |collection| collection.tag,
            .mapping_start => |collection| collection.tag,
            else => null,
        } orelse continue;
        const handle = shorthandTagHandle(tag) orelse continue;
        if (tagHandleDeclared(handle, tag_directives)) return true;
    }
    return false;
}

pub fn validateAnchorName(name: []const u8) ParseError!void {
    if (name.len == 0) return ParseError.InvalidSyntax;

    var index: usize = 0;
    while (index < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[index]) catch return ParseError.InvalidSyntax;
        if (index + len > name.len) return ParseError.InvalidSyntax;
        const codepoint = std.unicode.utf8Decode(name[index .. index + len]) catch return ParseError.InvalidSyntax;
        if (!isYamlAllowedCodepoint(codepoint)) return ParseError.InvalidSyntax;
        if (isAnchorNameSeparatorCodepoint(codepoint)) return ParseError.InvalidSyntax;

        if (len == 1) {
            switch (name[index]) {
                ',', '[', ']', '{', '}' => return ParseError.InvalidSyntax,
                else => {},
            }
        }

        index += len;
    }
}

fn validateEmittedTag(tag: []const u8) ParseError!void {
    if (tag.len == 0) return ParseError.InvalidSyntax;
    if (std.mem.startsWith(u8, tag, "!")) {
        try validateEmittedShorthandTag(tag);
        return;
    }
    if (!hasUriSchemePrefix(tag)) return ParseError.InvalidSyntax;
}

fn validateEmittedShorthandTag(tag: []const u8) ParseError!void {
    const handle_len = tagHandleLen(tag) orelse return ParseError.InvalidSyntax;
    const handle = tag[0..handle_len];
    const suffix = tag[handle_len..];
    if (!isValidTagHandle(handle)) return ParseError.InvalidSyntax;
    if (suffix.len == 0 and !std.mem.eql(u8, handle, "!")) return ParseError.InvalidSyntax;
}

pub fn validateTagDirective(directive: TagDirective) ParseError!void {
    if (!isValidTagHandle(directive.handle)) return ParseError.InvalidSyntax;
    if (!isValidTagPrefix(directive.prefix)) return ParseError.InvalidSyntax;
}

fn namedTagHandle(tag: []const u8) ?[]const u8 {
    const handle = shorthandTagHandle(tag) orelse return null;
    if (std.mem.eql(u8, handle, "!") or std.mem.eql(u8, handle, "!!")) return null;
    return handle;
}

fn shorthandTagHandle(tag: []const u8) ?[]const u8 {
    const handle_len = tagHandleLen(tag) orelse return null;
    const handle = tag[0..handle_len];
    if (tag.len == handle_len) return null;
    return handle;
}

fn tagHandleDeclared(handle: []const u8, directives: []const TagDirective) bool {
    for (directives) |directive| {
        if (std.mem.eql(u8, directive.handle, handle)) return true;
    }
    return false;
}

fn isValidTagHandle(handle: []const u8) bool {
    if (std.mem.eql(u8, handle, "!") or std.mem.eql(u8, handle, "!!")) return true;
    if (handle.len < 3 or handle[0] != '!' or handle[handle.len - 1] != '!') return false;

    for (handle[1 .. handle.len - 1]) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn isValidTagPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (prefix[0] == '!') return isValidTagUriChars(prefix[1..]);
    if (isFlowIndicatorOrTag(prefix[0])) return false;
    return isValidTagUriChars(prefix);
}

fn isFlowIndicatorOrTag(byte: u8) bool {
    return switch (byte) {
        '[', ']', '{', '}', ',', '!' => true,
        else => false,
    };
}

fn hasUriSchemePrefix(tag: []const u8) bool {
    if (tag.len == 0 or !std.ascii.isAlphabetic(tag[0])) return false;

    var index: usize = 1;
    while (index < tag.len) : (index += 1) {
        switch (tag[index]) {
            ':' => return true,
            'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
            else => return false,
        }
    }

    return false;
}

fn appendPercentEncodedBareTag(
    allocator: std.mem.Allocator,
    out: anytype,
    tag: []const u8,
) std.mem.Allocator.Error!void {
    for (tag) |byte| {
        if (isBareTagChar(byte)) {
            try out.*.append(allocator, byte);
        } else {
            try appendPercentEncodedByte(allocator, out, byte);
        }
    }
}

fn appendPercentEncodedVerbatimTag(
    allocator: std.mem.Allocator,
    out: anytype,
    tag: []const u8,
) std.mem.Allocator.Error!void {
    for (tag) |byte| {
        if (isTagUriChar(byte)) {
            try out.*.append(allocator, byte);
        } else {
            try appendPercentEncodedByte(allocator, out, byte);
        }
    }
}

fn isBareTagChar(byte: u8) bool {
    if (!isTagUriChar(byte)) return false;
    return switch (byte) {
        ',', '[', ']', '{', '}' => false,
        else => true,
    };
}

fn appendPercentEncodedByte(
    allocator: std.mem.Allocator,
    out: anytype,
    byte: u8,
) std.mem.Allocator.Error!void {
    try out.*.append(allocator, '%');
    try appendFixedHex(allocator, out, byte, 2);
}

pub fn appendFixedHex(
    allocator: std.mem.Allocator,
    out: anytype,
    value: u21,
    comptime width: usize,
) std.mem.Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    const widened: u32 = value;
    var shift: usize = (width - 1) * 4;
    while (true) {
        const digit: usize = @intCast((widened >> @intCast(shift)) & 0x0f);
        try out.*.append(allocator, hex[digit]);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn isYamlAllowedCodepoint(codepoint: u21) bool {
    return codepoint == 0x09 or
        codepoint == 0x0a or
        codepoint == 0x0d or
        (codepoint >= 0x20 and codepoint <= 0x7e) or
        codepoint == 0x85 or
        (codepoint >= 0xa0 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

fn isAnchorNameSeparatorCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        0x09, 0x0a, 0x0d, 0x20, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

fn tagHandleLen(tag: []const u8) ?usize {
    if (tag.len == 0 or tag[0] != '!') return null;
    if (tag.len >= 2 and tag[1] == '!') return 2;

    var index: usize = 1;
    while (index < tag.len) : (index += 1) {
        if (tag[index] == '!') return index + 1;
    }

    return 1;
}

fn isTagUriChar(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']' => true,
        else => false,
    };
}

fn isValidTagUriChars(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            if (!isTagUriChar(input[index])) return false;
            index += 1;
            continue;
        }
        if (index + 2 >= input.len or !isHexDigit(input[index + 1]) or !isHexDigit(input[index + 2])) return false;
        index += 3;
    }
    return true;
}

fn isHexDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

test "emitter: YAML allowed output code point boundaries" {
    const allowed = [_]u21{
        0x09,
        0x0a,
        0x0d,
        0x20,
        0x7e,
        0x85,
        0xa0,
        0xd7ff,
        0xe000,
        0xfffd,
        0x10000,
        0x10ffff,
    };
    const rejected = [_]u21{
        0x00,
        0x08,
        0x0b,
        0x0c,
        0x0e,
        0x1f,
        0x7f,
        0x84,
        0x86,
        0x9f,
        0xd800,
        0xdfff,
        0xfffe,
    };

    for (allowed) |codepoint| {
        try std.testing.expect(isYamlAllowedCodepoint(codepoint));
    }
    for (rejected) |codepoint| {
        try std.testing.expect(!isYamlAllowedCodepoint(codepoint));
    }
}

test "emitter: fixed-width hex appends uppercase padded digits" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendFixedHex(std.testing.allocator, &out, 0x0a, 2);
    try std.testing.expectEqualStrings("0A", out.items);

    out.clearRetainingCapacity();
    try appendFixedHex(std.testing.allocator, &out, 0x2028, 4);
    try std.testing.expectEqualStrings("2028", out.items);

    out.clearRetainingCapacity();
    try appendFixedHex(std.testing.allocator, &out, 0x10ffff, 8);
    try std.testing.expectEqualStrings("0010FFFF", out.items);
}
