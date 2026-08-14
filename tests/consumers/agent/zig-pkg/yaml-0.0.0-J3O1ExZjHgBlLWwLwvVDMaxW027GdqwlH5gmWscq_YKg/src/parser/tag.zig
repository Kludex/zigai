//! Purpose: Resolve parser tag directives and tag property spellings.
//! Owns: YAML directive tag handles, URI escape decoding, and tag spelling validation.
//! Does not own: Parser state transitions, node property scanning, or schema resolution.
//! Depends on: parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const types = @import("event.zig");

const Error = types.Error;
const ParseError = types.ParseError;
const utf8_bom = "\xEF\xBB\xBF";

pub const Directive = types.TagDirective;

pub const Directives = struct {
    tag_directives: TagDirectives = .{},
    yaml_version: ?[]const u8 = null,
};

pub const TagDirectives = struct {
    entries: []const Directive = &.{},
};

const Line = struct {
    start: usize,
    end: usize,
    next: usize,
};

pub fn parseDirectives(allocator: std.mem.Allocator, input: []const u8) Error!Directives {
    var directives: std.ArrayList(Directive) = .empty;
    errdefer directives.deinit(allocator);

    var index: usize = 0;
    var yaml_version: ?[]const u8 = null;
    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const directive = std.mem.trim(u8, stripLineComment(std.mem.trimStart(u8, raw, " \t")), " \t\r");
        index = line.next;

        if (!std.mem.startsWith(u8, directive, "%")) continue;

        var tokens = std.mem.tokenizeAny(u8, directive, " \t");
        const name = tokens.next() orelse continue;
        if (std.mem.eql(u8, name, "%YAML")) {
            if (yaml_version != null) return ParseError.InvalidSyntax;

            const version = tokens.next() orelse return ParseError.InvalidSyntax;
            if (!isValidYamlVersion(version)) return ParseError.InvalidSyntax;
            if (tokens.next() != null) return ParseError.InvalidSyntax;
            yaml_version = version;
            continue;
        }

        if (!std.mem.eql(u8, name, "%TAG")) continue;

        const handle = tokens.next() orelse return ParseError.InvalidSyntax;
        const prefix = tokens.next() orelse return ParseError.InvalidSyntax;
        if (tokens.next() != null) return ParseError.InvalidSyntax;
        if (!isValidHandle(handle)) return ParseError.InvalidSyntax;
        if (!isValidPrefix(prefix)) return ParseError.InvalidSyntax;

        for (directives.items) |existing| {
            if (std.mem.eql(u8, existing.handle, handle)) return ParseError.InvalidSyntax;
        }

        try directives.append(allocator, .{
            .handle = handle,
            .prefix = prefix,
        });
    }

    return .{
        .tag_directives = .{ .entries = try directives.toOwnedSlice(allocator) },
        .yaml_version = yaml_version,
    };
}

pub fn prefixHasReservedDirective(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const directive = std.mem.trim(u8, stripLineComment(std.mem.trimStart(u8, raw, " \t")), " \t\r");
        index = line.next;

        if (!std.mem.startsWith(u8, directive, "%")) continue;
        var tokens = std.mem.tokenizeAny(u8, directive, " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%YAML") and !std.mem.eql(u8, name, "%TAG")) return true;
    }

    return false;
}

pub fn parseProperty(input: []const u8) ParseError![]const u8 {
    if (input.len == 0 or input[0] != '!') return ParseError.InvalidSyntax;
    if (std.mem.startsWith(u8, input, "!<")) {
        if (!std.mem.endsWith(u8, input, ">")) return ParseError.InvalidSyntax;
        if (!isValidVerbatimTag(input[2 .. input.len - 1])) return ParseError.InvalidSyntax;
        return input;
    }

    for (input) |byte| {
        switch (byte) {
            ',', '[', ']', '{', '}' => return ParseError.InvalidSyntax,
            else => {},
        }
    }
    return input;
}

pub fn resolve(allocator: std.mem.Allocator, directives: []const Directive, tag: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, tag, "!<") and std.mem.endsWith(u8, tag, ">")) {
        const content = tag[2 .. tag.len - 1];
        if (!isValidVerbatimTag(content)) return ParseError.InvalidSyntax;
        return decodeUriEscapes(allocator, content);
    }

    const handle_len = tagHandleLen(tag) orelse return allocator.dupe(u8, tag);
    const handle = tag[0..handle_len];
    const suffix = tag[handle_len..];

    if (suffix.len == 0) {
        if (std.mem.eql(u8, handle, "!")) return allocator.dupe(u8, "!");
        return ParseError.InvalidSyntax;
    }
    if (!isValidShorthandSuffix(suffix)) return ParseError.InvalidSyntax;

    for (directives) |directive| {
        if (std.mem.eql(u8, directive.handle, handle)) {
            return joinAndDecodeUriEscapes(allocator, directive.prefix, suffix);
        }
    }

    if (std.mem.eql(u8, handle, "!!")) {
        return joinAndDecodeUriEscapes(allocator, "tag:yaml.org,2002:", suffix);
    }

    if (std.mem.eql(u8, handle, "!")) {
        return decodeUriEscapes(allocator, tag);
    }

    return ParseError.InvalidSyntax;
}

pub fn isValidYamlVersion(version: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse return false;
    if (separator == 0 or separator + 1 == version.len) return false;
    if (std.mem.indexOfScalarPos(u8, version, separator + 1, '.') != null) return false;

    for (version[0..separator]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    for (version[separator + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    const major = std.fmt.parseInt(u16, version[0..separator], 10) catch return false;
    return major == 1;
}

pub fn isValidHandle(handle: []const u8) bool {
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

pub fn isValidPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;

    if (prefix[0] == '!') {
        return isValidUriChars(prefix[1..]);
    }

    const first_len = uriCharLen(prefix) orelse return false;
    if (first_len == 1 and isFlowIndicatorOrTag(prefix[0])) return false;
    return isValidUriChars(prefix[first_len..]);
}

fn isFlowIndicatorOrTag(byte: u8) bool {
    return switch (byte) {
        '[', ']', '{', '}', ',', '!' => true,
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

fn joinAndDecodeUriEscapes(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, prefix, '%') == null and std.mem.indexOfScalar(u8, suffix, '%') == null) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, suffix });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendDecodedUriEscapes(allocator, &out, prefix);
    try appendDecodedUriEscapes(allocator, &out, suffix);
    return out.toOwnedSlice(allocator);
}

fn decodeUriEscapes(allocator: std.mem.Allocator, input: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) return allocator.dupe(u8, input);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendDecodedUriEscapes(allocator, &out, input);
    return out.toOwnedSlice(allocator);
}

fn appendDecodedUriEscapes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) Error!void {
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try out.append(allocator, input[index]);
            index += 1;
            continue;
        }

        if (index + 2 >= input.len) return ParseError.InvalidSyntax;
        const byte = std.fmt.parseInt(u8, input[index + 1 .. index + 3], 16) catch return ParseError.InvalidSyntax;
        try out.append(allocator, byte);
        index += 3;
    }
}

pub fn isValidVerbatimTag(content: []const u8) bool {
    if (content.len == 0) return false;
    if (!isValidUriChars(content)) return false;

    if (content[0] == '!') return content.len > 1;
    return hasUriScheme(content);
}

fn hasUriScheme(content: []const u8) bool {
    if (!std.ascii.isAlphabetic(content[0])) return false;

    var index: usize = 1;
    while (index < content.len) : (index += 1) {
        switch (content[index]) {
            ':' => return true,
            'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
            else => return false,
        }
    }

    return false;
}

fn isValidUriChars(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) {
        const len = uriCharLen(input[index..]) orelse return false;
        index += len;
    }
    return true;
}

fn isValidShorthandSuffix(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) {
        const len = uriCharLen(input[index..]) orelse return false;
        if (len == 1 and (input[index] == '!' or isFlowIndicatorOrTag(input[index]))) return false;
        index += len;
    }
    return true;
}

fn uriCharLen(input: []const u8) ?usize {
    if (input.len == 0) return null;
    if (input[0] != '%') {
        return if (isUriChar(input[0])) 1 else null;
    }
    if (input.len < 3) return null;
    return if (isHexDigit(input[1]) and isHexDigit(input[2])) 3 else null;
}

fn isUriChar(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']' => true,
        else => false,
    };
}

fn isHexDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn stripLineComment(line: []const u8) []const u8 {
    for (line, 0..) |byte, index| {
        if (byte == '#' and (index == 0 or line[index - 1] == ' ' or line[index - 1] == '\t')) {
            return line[0..index];
        }
    }
    return line;
}

fn stripUtf8Bom(input: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, input, utf8_bom)) input[utf8_bom.len..] else input;
}

fn lineAt(input: []const u8, start: usize) Line {
    var end = start;
    while (end < input.len and input[end] != '\n' and input[end] != '\r') : (end += 1) {}
    return .{
        .start = start,
        .end = end,
        .next = if (end < input.len and input[end] == '\r' and end + 1 < input.len and input[end + 1] == '\n')
            end + 2
        else if (end < input.len)
            end + 1
        else
            end,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "parser tag: rejects unescaped shorthand suffix indicators" {
    const invalid_tags = [_][]const u8{
        "!bad!suffix",
        "!bad[suffix",
        "!bad]suffix",
        "!bad{suffix",
        "!bad}suffix",
        "!bad,suffix",
        "!!str!suffix",
        "!!str[suffix",
    };

    for (invalid_tags) |invalid_tag| {
        try std.testing.expectError(ParseError.InvalidSyntax, resolve(std.testing.allocator, &.{}, invalid_tag));
    }
}

test "parser tag: accepts escaped shorthand suffix indicators" {
    const resolved = try resolve(std.testing.allocator, &.{}, "!!str%21suffix");
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings("tag:yaml.org,2002:str!suffix", resolved);
}

test "parser tag: rejects verbatim tags with invalid URI scheme characters" {
    try std.testing.expectError(ParseError.InvalidSyntax, resolve(std.testing.allocator, &.{}, "!<a[b:tag>"));
}

test "parser tag: URI escape decoding cleans up after allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkUriEscapeAllocationFailure,
        .{},
    );
}

fn checkUriEscapeAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const decoded = try decodeUriEscapes(failing_allocator, "tag:example:%21value");
    defer failing_allocator.free(decoded);
    try std.testing.expectEqualStrings("tag:example:!value", decoded);

    const resolved = try resolve(failing_allocator, &.{}, "!!str%21suffix");
    defer failing_allocator.free(resolved);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str!suffix", resolved);
}
