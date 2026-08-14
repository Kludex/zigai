//! Purpose: Select source-location diagnostics for parser failures.
//! Owns: Parser-internal diagnostic classification and source scans.
//! Does not own: Parser behavior or the public diagnostic payload type.
//! Depends on: common/diagnostic.zig, common/limit.zig, reader/encoding.zig, parser/tag.zig, parser/event.zig.
//! Tested by: tests/unit/api/root_api_test.zig and tests/conformance/yaml_suite_runner.zig.

const std = @import("std");
const common_diagnostic = @import("../common/diagnostic.zig");
const common_limit = @import("../common/limit.zig");
const encoding = @import("../reader/encoding.zig");
const tag_resolver = @import("tag.zig");
const types = @import("event.zig");

const Diagnostic = types.Diagnostic;
const Error = types.Error;

pub const utf8_bom = "\xEF\xBB\xBF";

pub const Line = struct {
    start: usize,
    end: usize,
    next: usize,
};

pub fn diagnosticForParseError(input: []const u8, err: Error) Diagnostic {
    return switch (err) {
        error.InvalidSyntax => invalidSyntaxDiagnostic(input),
        error.Unsupported => unsupportedDiagnostic(input),
        error.OutOfMemory => diagnosticAt(input, 0, "out of memory"),
    };
}

fn invalidSyntaxDiagnostic(input: []const u8) Diagnostic {
    if (encodedInputDiagnostic(input)) |diagnostic| {
        return diagnostic;
    }

    if (firstInvalidUtf8Offset(input)) |offset| return diagnosticAt(input, offset, "invalid UTF-8");
    if (firstNonPrintableOffset(input)) |offset| return diagnosticAt(input, offset, "non-printable character");
    if (firstMisplacedUtf8BomOffset(input)) |offset| return diagnosticAt(input, offset, "misplaced UTF-8 BOM");
    if (firstTabIndentedBlockNodeOffset(input)) |offset| return diagnosticAt(input, offset, "tab used for indentation");
    if (unsupportedYamlDirectiveVersionOffset(input)) |offset| return diagnosticAt(input, offset, "unsupported YAML directive version");
    if (duplicateYamlDirectiveOffset(input)) |offset| return diagnosticAt(input, offset, "duplicate YAML directive");
    if (duplicateTagDirectiveOffset(input)) |offset| return diagnosticAt(input, offset, "duplicate TAG directive");
    if (invalidTagDirectiveOffset(input)) |offset| return diagnosticAt(input, offset, "invalid TAG directive");
    if (firstInvalidTagPropertyOffset(input)) |offset| return diagnosticAt(input, offset, "invalid tag property");
    if (missingTagShorthandSuffixOffset(input)) |offset| return diagnosticAt(input, offset, "tag shorthand missing suffix");
    if (firstUnexpectedFlowCloseIndicatorOffset(input)) |offset| return diagnosticAt(input, offset, "unexpected flow close indicator");
    if (firstInvalidDoubleQuotedEscapeOffset(input)) |offset| return diagnosticAt(input, offset, "invalid double-quoted escape");
    if (firstUnterminatedQuotedScalarOffset(input, '"')) |offset| return diagnosticAt(input, offset, "unterminated double-quoted scalar");
    if (firstUnterminatedQuotedScalarOffset(input, '\'')) |offset| return diagnosticAt(input, offset, "unterminated single-quoted scalar");
    if (firstReservedPlainScalarIndicatorOffset(input)) |offset| return diagnosticAt(input, offset, "reserved indicator at plain scalar start");

    return diagnosticAt(input, firstContentOffset(input), "invalid YAML syntax");
}

fn unsupportedDiagnostic(input: []const u8) Diagnostic {
    if (firstUnsupportedFlowDepthOffset(input)) |offset| {
        return diagnosticAt(input, offset, "flow collection nesting exceeds parser limit");
    }

    return diagnosticAt(input, firstContentOffset(input), "unsupported YAML feature");
}

pub fn diagnosticAt(input: []const u8, offset: usize, message: []const u8) Diagnostic {
    const clamped_offset = @min(offset, input.len);
    return common_diagnostic.atOffset(input, clamped_offset, message);
}

pub fn lineAt(input: []const u8, start: usize) Line {
    var relative_end = start;
    while (relative_end < input.len and consumeLineBreak(input, relative_end, input.len) == null) : (relative_end += 1) {}

    const next = if (relative_end < input.len)
        consumeLineBreak(input, relative_end, input.len) orelse relative_end + 1
    else
        relative_end;

    return .{
        .start = start,
        .end = relative_end,
        .next = next,
    };
}

pub fn stripUtf8Bom(input: []const u8) []const u8 {
    return input[utf8BomPrefixLen(input)..];
}

pub fn utf8BomPrefixLen(input: []const u8) usize {
    return if (std.mem.startsWith(u8, input, utf8_bom)) utf8_bom.len else 0;
}

pub fn directiveLinePrefixOffset(line: []const u8) usize {
    return if (std.mem.startsWith(u8, line, utf8_bom)) utf8_bom.len else 0;
}

pub fn isTopLevelDirectiveLine(line: []const u8) bool {
    return line.len > 0 and line[0] == '%';
}

pub fn isDocumentStartMarker(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "---")) return false;
    return line.len == 3 or line[3] == ' ' or line[3] == '\t';
}

pub fn isDocumentEndMarker(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "...")) return false;
    if (line.len == 3) return true;
    if (line[3] != ' ' and line[3] != '\t') return false;

    const suffix = std.mem.trimStart(u8, line[3..], " \t");
    return suffix.len == 0 or suffix[0] == '#';
}

pub fn stripLineComment(line: []const u8) []const u8 {
    var index: usize = 0;
    var quote: ?u8 = null;

    while (index < line.len) : (index += 1) {
        const byte = line[index];

        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < line.len and line[index + 1] == '\'') {
                index += 1;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < line.len) {
                index += 1;
                continue;
            }
            if (byte == active_quote) quote = null;
            continue;
        }

        switch (byte) {
            '\'', '"' => if (startsQuotedLineScalar(line, index)) {
                quote = byte;
            },
            '#' => {
                if (index == 0 or line[index - 1] == ' ' or line[index - 1] == '\t') {
                    return line[0..index];
                }
            },
            else => {},
        }
    }

    return line;
}

fn startsQuotedLineScalar(line: []const u8, quote_index: usize) bool {
    var index = quote_index;
    while (index > 0) {
        index -= 1;
        switch (line[index]) {
            ' ', '\t' => {},
            else => return false,
        }
    }

    return true;
}

pub fn isCommentStart(input: []const u8, index: usize) bool {
    if (input[index] != '#') return false;
    return index == 0 or input[index - 1] == ' ' or input[index - 1] == '\t' or endsWithLineBreakBefore(input, index);
}

pub fn consumeLineBreak(input: []const u8, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    return switch (input[start]) {
        '\n' => start + 1,
        '\r' => if (start + 1 < end and input[start + 1] == '\n') start + 2 else start + 1,
        0xc2 => if (start + 1 < end and input[start + 1] == 0x85) start + 2 else null,
        0xe2 => if (start + 2 < end and input[start + 1] == 0x80 and (input[start + 2] == 0xa8 or input[start + 2] == 0xa9)) start + 3 else null,
        else => null,
    };
}

fn endsWithLineBreakBefore(input: []const u8, index: usize) bool {
    if (index == 0) return false;
    if (input[index - 1] == '\n' or input[index - 1] == '\r') return true;
    if (index >= 2 and input[index - 2] == 0xc2 and input[index - 1] == 0x85) return true;
    return index >= 3 and input[index - 3] == 0xe2 and input[index - 2] == 0x80 and
        (input[index - 1] == 0xa8 or input[index - 1] == 0xa9);
}

pub fn isLineBreakByte(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

pub fn isSeparationByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or isLineBreakByte(byte);
}

pub fn canStartFlowCollection(previous: u8) bool {
    return switch (previous) {
        0, '[', '{', ',', ':', '?', '-' => true,
        else => false,
    };
}

pub fn startsQuotedScalarForCharacterValidation(input: []const u8, quote_index: usize) bool {
    if (quote_index == 0) return true;
    if (endsWithLineBreakBefore(input, quote_index)) return true;

    var index = quote_index;
    while (index > 0) {
        index -= 1;
        if (endsWithLineBreakBefore(input, index + 1)) return true;
        switch (input[index]) {
            ' ', '\t' => {},
            '\n', '\r', '[', '{', ',', ':', '?', '-' => return true,
            else => {
                if (input[quote_index - 1] == ' ' or input[quote_index - 1] == '\t') {
                    const token_start = previousTokenStart(input, index);
                    return input[token_start] == '&' or input[token_start] == '!';
                }
                return false;
            },
        }
    }

    return true;
}

fn previousTokenStart(input: []const u8, token_end: usize) usize {
    var index = token_end;
    while (index > 0) {
        switch (input[index - 1]) {
            ' ', '\t', '\r', '\n', '[', '{', ',', ':', '?' => break,
            else => index -= 1,
        }
    }
    return index;
}

pub fn isValidVerbatimTag(content: []const u8) bool {
    if (content.len == 0) return false;
    if (!isValidTagUriChars(content)) return false;

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

pub fn tagHandleLen(tag: []const u8) ?usize {
    if (tag.len == 0 or tag[0] != '!') return null;
    if (tag.len == 1) return 1;
    if (tag[1] == '!') return 2;

    var index: usize = 1;
    while (index < tag.len) : (index += 1) {
        switch (tag[index]) {
            'A'...'Z', 'a'...'z', '0'...'9', '-' => {},
            '!' => return index + 1,
            else => return null,
        }
    }
    return null;
}

fn isValidTagUriChars(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) : (index += tagUriCharLen(input[index..]) orelse return false) {}
    return true;
}

fn tagUriCharLen(input: []const u8) ?usize {
    if (input.len == 0) return null;
    if (input[0] != '%') {
        return if (isTagUriChar(input[0])) 1 else null;
    }
    if (input.len < 3) return null;
    return if (isHexDigit(input[1]) and isHexDigit(input[2])) 3 else null;
}

fn isTagUriChar(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']' => true,
        else => false,
    };
}

pub fn isHexDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

pub fn firstInvalidUtf8Offset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[index]) catch return index;
        if (index + len > input.len) return index;
        _ = std.unicode.utf8Decode(input[index .. index + len]) catch return index;
        index += len;
    }

    return null;
}

pub fn firstNonPrintableOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
        if (index + len > input.len) return null;
        const codepoint = std.unicode.utf8Decode(input[index .. index + len]) catch return null;
        if (!isYamlAllowedCodepoint(codepoint, quote != null)) return index;

        const byte = input[index];
        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                index += 2;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < input.len and input[index + 1] == '"') {
                index += 2;
                continue;
            }
            if (byte == active_quote) quote = null;
        } else if ((byte == '\'' or byte == '"') and startsQuotedScalarForCharacterValidation(input, index)) {
            quote = byte;
        }

        index += len;
    }

    return null;
}

pub fn firstMisplacedUtf8BomOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var line_start = true;
    var quote: ?u8 = null;

    while (index < input.len) {
        if (quote == null) {
            if (consumeLineBreak(input, index, input.len)) |next| {
                index = next;
                line_start = true;
                continue;
            }
        }

        if (std.mem.startsWith(u8, input[index..], utf8_bom)) {
            if (quote == null and !line_start) return index;
            index += utf8_bom.len;
            line_start = false;
            continue;
        }

        const byte = input[index];
        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                index += 2;
                line_start = false;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < input.len) {
                index += 2;
                line_start = false;
                continue;
            }
            if (byte == active_quote) quote = null;
        } else switch (byte) {
            '\'', '"' => if (startsQuotedScalarForCharacterValidation(input, index)) {
                quote = byte;
            },
            else => {},
        }

        line_start = false;
        index += 1;
    }

    return null;
}

pub fn firstReservedPlainScalarIndicatorOffset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            '@', '`' => if (reservedIndicatorStartsPlainScalar(input, index)) return index,
            else => {},
        }
    }

    return null;
}

fn reservedIndicatorStartsPlainScalar(input: []const u8, index: usize) bool {
    const previous = previousNonWhitespaceIndex(input, index) orelse return true;
    return switch (input[previous]) {
        ':', '[', '{', ',' => true,
        '-', '?' => isSeparatedIndicatorAt(input, previous),
        else => false,
    };
}

fn previousNonWhitespaceIndex(input: []const u8, index: usize) ?usize {
    var cursor = index;
    while (cursor > 0) {
        if (cursor >= 3 and consumeLineBreak(input, cursor - 3, cursor) == cursor) return null;
        if (cursor >= 2 and consumeLineBreak(input, cursor - 2, cursor) == cursor) return null;

        cursor -= 1;
        switch (input[cursor]) {
            ' ', '\t' => {},
            '\n', '\r' => return null,
            else => return cursor,
        }
    }
    return null;
}

fn isSeparatedIndicatorAt(input: []const u8, index: usize) bool {
    const next = index + 1;
    return next >= input.len or isSeparationByte(input[next]);
}

pub fn firstUnsupportedFlowDepthOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var last_significant: u8 = 0;

    while (index < input.len) : (index += 1) {
        const byte = input[index];

        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                index += 1;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < input.len) {
                index += 1;
                continue;
            }
            if (byte == active_quote) quote = null;
            continue;
        }

        if (consumeLineBreak(input, index, input.len)) |next| {
            if (depth == 0) last_significant = 0;
            index = next - 1;
            continue;
        }

        if (byte == '#' and isCommentStart(input, index)) {
            index = lineAt(input, index).next;
            if (depth == 0) last_significant = 0;
            if (index == input.len) break;
            index -= 1;
            continue;
        }

        switch (byte) {
            '\'', '"' => {
                quote = byte;
                last_significant = byte;
            },
            '[', '{' => {
                if (depth != 0 or canStartFlowCollection(last_significant)) {
                    depth += 1;
                    if (depth > common_limit.max_parse_collection_depth) return index;
                }
                last_significant = byte;
            },
            ']', '}' => {
                if (depth != 0) depth -= 1;
                last_significant = byte;
            },
            ' ', '\t' => {},
            else => last_significant = byte,
        }
    }

    return null;
}

pub fn firstContentOffset(input: []const u8) usize {
    var index: usize = 0;
    while (index < input.len) {
        if (consumeLineBreak(input, index, input.len)) |next| {
            index = next;
            continue;
        }

        switch (input[index]) {
            ' ', '\t' => index += 1,
            else => return index,
        }
    }

    return 0;
}

fn isYamlAllowedCodepoint(codepoint: u21, _: bool) bool {
    return codepoint == 0x09 or
        codepoint == 0x0a or
        codepoint == 0x0d or
        (codepoint >= 0x20 and codepoint <= 0x7e) or
        codepoint == 0x85 or
        (codepoint >= 0xa0 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

pub fn unsupportedYamlDirectiveVersionOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var in_directive_prefix = true;

    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        index = line.next;

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (isDocumentEndMarker(raw)) {
            in_directive_prefix = true;
            continue;
        }

        if (!in_directive_prefix) continue;

        if (isDocumentStartMarker(raw)) {
            in_directive_prefix = false;
            continue;
        }

        if (!isTopLevelDirectiveLine(raw)) {
            in_directive_prefix = false;
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, stripLineComment(raw), " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%YAML")) continue;
        const version = tokens.next() orelse continue;
        if (tokens.next() != null) continue;

        const major_is_one = yamlDirectiveVersionMajorIsOne(version) orelse continue;
        if (!major_is_one) return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
    }

    return null;
}

pub fn duplicateYamlDirectiveOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var in_directive_prefix = true;
    var seen_yaml_directive = false;

    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        index = line.next;

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (isDocumentEndMarker(raw)) {
            in_directive_prefix = true;
            seen_yaml_directive = false;
            continue;
        }

        if (!in_directive_prefix) continue;

        if (isDocumentStartMarker(raw)) {
            in_directive_prefix = false;
            continue;
        }

        if (!isTopLevelDirectiveLine(raw)) {
            in_directive_prefix = false;
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, stripLineComment(raw), " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%YAML")) continue;

        if (seen_yaml_directive) return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        seen_yaml_directive = true;
    }

    return null;
}

pub fn duplicateTagDirectiveOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var directive_prefix_start: usize = 0;
    var in_directive_prefix = true;

    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        index = line.next;

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (isDocumentEndMarker(raw)) {
            in_directive_prefix = true;
            directive_prefix_start = index;
            continue;
        }

        if (!in_directive_prefix) continue;

        if (isDocumentStartMarker(raw)) {
            in_directive_prefix = false;
            continue;
        }

        if (!isTopLevelDirectiveLine(raw)) {
            in_directive_prefix = false;
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, stripLineComment(raw), " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%TAG")) continue;
        const handle = tokens.next() orelse continue;

        if (tagDirectiveHandleSeen(input[directive_prefix_start..line.start], handle)) {
            return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        }
    }

    return null;
}

pub fn invalidTagDirectiveOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var in_directive_prefix = true;

    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, input[line.start..line.end], "\r"));
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        index = line.next;

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (isDocumentEndMarker(raw)) {
            in_directive_prefix = true;
            continue;
        }

        if (!in_directive_prefix) continue;

        if (isDocumentStartMarker(raw)) {
            in_directive_prefix = false;
            continue;
        }

        if (!isTopLevelDirectiveLine(raw)) {
            in_directive_prefix = false;
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, stripLineComment(raw), " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%TAG")) continue;
        const handle = tokens.next() orelse return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        const prefix = tokens.next() orelse return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        if (tokens.next() != null) return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        if (!tag_resolver.isValidHandle(handle)) return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
        if (!tag_resolver.isValidPrefix(prefix)) return line.start + directiveLinePrefixOffset(input[line.start..line.end]);
    }

    return null;
}

fn yamlDirectiveVersionMajorIsOne(version: []const u8) ?bool {
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse return null;
    if (separator == 0 or separator + 1 == version.len) return null;
    if (std.mem.indexOfScalarPos(u8, version, separator + 1, '.') != null) return null;

    for (version[0..separator]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    for (version[separator + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }

    return std.mem.eql(u8, version[0..separator], "1");
}

fn tagDirectiveHandleSeen(prefix: []const u8, handle: []const u8) bool {
    var index: usize = 0;
    while (index < prefix.len) {
        const line = lineAt(prefix, index);
        const raw = stripUtf8Bom(std.mem.trimEnd(u8, prefix[line.start..line.end], "\r"));
        index = line.next;

        if (!isTopLevelDirectiveLine(raw)) continue;

        var tokens = std.mem.tokenizeAny(u8, stripLineComment(raw), " \t");
        const name = tokens.next() orelse continue;
        if (!std.mem.eql(u8, name, "%TAG")) continue;
        const previous_handle = tokens.next() orelse continue;
        if (std.mem.eql(u8, previous_handle, handle)) return true;
    }

    return false;
}

pub fn encodedInputDiagnostic(input: []const u8) ?Diagnostic {
    const detected = encoding.detectInputEncoding(input);
    const content = input[detected.offset..];

    return switch (detected.encoding) {
        .utf8 => null,
        .utf16_le => if (firstMalformedUtf16Offset(content, .little)) |offset|
            diagnosticAt(input, detected.offset + offset, "invalid UTF-16")
        else
            diagnosticAt(input, detected.offset, "invalid YAML syntax"),
        .utf16_be => if (firstMalformedUtf16Offset(content, .big)) |offset|
            diagnosticAt(input, detected.offset + offset, "invalid UTF-16")
        else
            diagnosticAt(input, detected.offset, "invalid YAML syntax"),
        .utf32_le => if (firstMalformedUtf32Offset(content, .little)) |offset|
            diagnosticAt(input, detected.offset + offset, "invalid UTF-32")
        else
            diagnosticAt(input, detected.offset, "invalid YAML syntax"),
        .utf32_be => if (firstMalformedUtf32Offset(content, .big)) |offset|
            diagnosticAt(input, detected.offset + offset, "invalid UTF-32")
        else
            diagnosticAt(input, detected.offset, "invalid YAML syntax"),
    };
}

fn firstMalformedUtf16Offset(input: []const u8, endian: std.builtin.Endian) ?usize {
    if (input.len % 2 != 0) return input.len - 1;

    var index: usize = 0;
    while (index < input.len) : (index += 2) {
        const code_unit_start = index;
        const code_unit = std.mem.readInt(u16, input[index..][0..2], endian);

        if (std.unicode.utf16IsHighSurrogate(code_unit)) {
            const low_start = index + 2;
            if (low_start >= input.len) return code_unit_start;
            const low = std.mem.readInt(u16, input[low_start..][0..2], endian);
            if (!std.unicode.utf16IsLowSurrogate(low)) return low_start;
            index = low_start;
            continue;
        }

        if (std.unicode.utf16IsLowSurrogate(code_unit)) {
            return code_unit_start;
        }
    }

    return null;
}

fn firstMalformedUtf32Offset(input: []const u8, endian: std.builtin.Endian) ?usize {
    if (input.len % 4 != 0) return input.len - (input.len % 4);

    var index: usize = 0;
    while (index < input.len) : (index += 4) {
        const codepoint = std.mem.readInt(u32, input[index..][0..4], endian);
        if (codepoint > 0x10ffff) return index;
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) return index;
    }

    return null;
}

pub fn firstTabIndentedBlockNodeOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var previous_line_requests_indented_node = false;
    while (index < input.len) {
        const line = lineAt(input, index);
        const raw = std.mem.trimEnd(u8, input[line.start..line.end], "\r");
        index = line.next;

        var cursor: usize = 0;
        var first_tab: ?usize = null;
        while (cursor < raw.len and (raw[cursor] == ' ' or raw[cursor] == '\t')) : (cursor += 1) {
            if (raw[cursor] == '\t' and first_tab == null) first_tab = cursor;
        }

        if (first_tab != null and cursor < raw.len and
            (tabIndentStartsBlockNode(raw, cursor) or
                (previous_line_requests_indented_node and isFlowStartByte(raw[cursor]))))
        {
            return line.start + first_tab.?;
        }

        const uncommented = std.mem.trimEnd(u8, stripLineComment(raw), " \t");
        if (std.mem.trim(u8, uncommented, " \t").len != 0) {
            previous_line_requests_indented_node = lineRequestsIndentedNode(uncommented);
        }
    }

    return null;
}

fn tabIndentStartsBlockNode(line: []const u8, cursor: usize) bool {
    if (line[cursor] == '#') return false;
    if (line[cursor] == '-' and isSeparatedIndicatorAt(line, cursor)) return true;
    if (line[cursor] == '?' and isSeparatedIndicatorAt(line, cursor)) return true;
    if (line[cursor] == '[' or line[cursor] == '{') return false;
    return blockMappingSeparator(line[cursor..]) != null;
}

fn lineRequestsIndentedNode(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;

    if ((trimmed[0] == '-' or trimmed[0] == '?') and isSeparatedIndicatorAt(trimmed, 0)) {
        return std.mem.trim(u8, trimmed[1..], " \t").len == 0;
    }

    const separator = blockMappingSeparator(trimmed) orelse return false;
    return std.mem.trim(u8, trimmed[separator + 1 ..], " \t").len == 0;
}

fn isFlowStartByte(byte: u8) bool {
    return byte == '[' or byte == '{';
}

fn blockMappingSeparator(line: []const u8) ?usize {
    var index: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;

    while (index < line.len) : (index += 1) {
        const byte = line[index];

        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < line.len and line[index + 1] == '\'') {
                index += 1;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < line.len) {
                index += 1;
                continue;
            }
            if (byte == active_quote) quote = null;
            continue;
        }

        switch (byte) {
            '[' => {
                square_depth += 1;
                continue;
            },
            ']' => {
                if (square_depth > 0) square_depth -= 1;
                continue;
            },
            '{' => {
                curly_depth += 1;
                continue;
            },
            '}' => {
                if (curly_depth > 0) curly_depth -= 1;
                continue;
            },
            else => {},
        }

        if (square_depth != 0 or curly_depth != 0) {
            if (byte == '\'' or byte == '"') quote = byte;
            continue;
        }

        if (startsNodeToken(line, index)) {
            const token_len = nodePropertyTokenLen(line[index..]);
            if (token_len > 0) index += token_len - 1;
            continue;
        }

        if (byte == '#' and (index == 0 or line[index - 1] == ' ' or line[index - 1] == '\t')) {
            return null;
        }

        if ((byte == '\'' or byte == '"') and (index == 0 or line[index - 1] == ' ' or line[index - 1] == '\t')) {
            quote = byte;
            continue;
        }

        if (byte == ':' and (index + 1 == line.len or line[index + 1] == ' ' or line[index + 1] == '\t')) {
            return index;
        }
    }

    return null;
}

fn startsNodeToken(input: []const u8, index: usize) bool {
    if (index >= input.len) return false;
    switch (input[index]) {
        '&', '!', '*' => {},
        else => return false,
    }

    return index == 0 or input[index - 1] == ' ' or input[index - 1] == '\t';
}

fn nodePropertyTokenLen(input: []const u8) usize {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            ' ', '\t', '\r', '\n' => break,
            else => {},
        }
    }
    return index;
}

pub fn firstInvalidTagPropertyOffset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const line = lineAt(input, index);
        const raw_line = input[line.start..line.end];
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        const content_offset = directiveLinePrefixOffset(raw);
        const content = stripUtf8Bom(raw);
        const uncommented = stripLineComment(content);
        index = line.next;

        if (isTopLevelDirectiveLine(content)) continue;

        var cursor: usize = 0;
        while (cursor < uncommented.len) {
            cursor = skipTagDiagnosticSeparators(uncommented, cursor);
            if (cursor >= uncommented.len) break;

            if (std.mem.startsWith(u8, uncommented[cursor..], "!<")) {
                const tag_end = std.mem.indexOfScalarPos(u8, uncommented, cursor + 2, '>') orelse
                    return line.start + content_offset + cursor;
                if (!isValidVerbatimTag(uncommented[cursor + 2 .. tag_end])) {
                    return line.start + content_offset + cursor;
                }
                cursor = tag_end + 1;
                continue;
            }

            cursor = skipTagDiagnosticToken(uncommented, cursor);
        }
    }

    return null;
}

pub fn missingTagShorthandSuffixOffset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const line = lineAt(input, index);
        const raw_line = input[line.start..line.end];
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        const content_offset = directiveLinePrefixOffset(raw);
        const content = stripUtf8Bom(raw);
        const uncommented = stripLineComment(content);
        index = line.next;

        if (isTopLevelDirectiveLine(content)) continue;

        var cursor: usize = 0;
        while (cursor < uncommented.len) {
            cursor = skipTagDiagnosticSeparators(uncommented, cursor);
            if (cursor >= uncommented.len) break;

            const token_start = cursor;
            while (cursor < uncommented.len and !isTagDiagnosticSeparator(uncommented[cursor])) {
                cursor += 1;
            }

            const token = uncommented[token_start..cursor];
            if (tagHandleLen(token)) |handle_len| {
                if (handle_len == token.len and !std.mem.eql(u8, token, "!")) {
                    return line.start + content_offset + token_start;
                }
            }
        }
    }

    return null;
}

pub fn firstUnexpectedFlowCloseIndicatorOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;

    while (index < input.len) : (index += 1) {
        const byte = input[index];

        if (quote) |active_quote| {
            if (active_quote == '\'' and byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                index += 1;
                continue;
            }
            if (active_quote == '"' and byte == '\\' and index + 1 < input.len) {
                index += 1;
                continue;
            }
            if (byte == active_quote) quote = null;
            continue;
        }

        if (byte == '#' and isCommentStart(input, index)) {
            index = lineAt(input, index).next;
            if (index == input.len) break;
            index -= 1;
            continue;
        }

        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            '{' => curly_depth += 1,
            ']' => {
                if (square_depth == 0) return index;
                square_depth -= 1;
            },
            '}' => {
                if (curly_depth == 0) return index;
                curly_depth -= 1;
            },
            else => {},
        }
    }

    return null;
}

pub fn firstInvalidDoubleQuotedEscapeOffset(input: []const u8) ?usize {
    var index: usize = 0;
    var quote: ?u8 = null;

    while (index < input.len) {
        const byte = input[index];
        if (quote) |active_quote| {
            if (active_quote == '\'') {
                if (byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                    index += 2;
                    continue;
                }
                if (byte == '\'') quote = null;
                index += 1;
                continue;
            }

            if (byte == '\\') {
                const escape_offset = index;
                index = consumeDiagnosticDoubleQuotedEscape(input, index + 1) orelse return escape_offset;
                continue;
            }
            if (byte == '"') quote = null;
            index += 1;
            continue;
        }

        if ((byte == '\'' or byte == '"') and startsQuotedScalarForCharacterValidation(input, index)) {
            quote = byte;
        }
        index += 1;
    }

    return null;
}

pub fn firstUnterminatedQuotedScalarOffset(input: []const u8, target_quote: u8) ?usize {
    var index: usize = 0;
    var quote: ?u8 = null;
    var quote_start: usize = 0;

    while (index < input.len) {
        const byte = input[index];
        if (quote) |active_quote| {
            if (active_quote == '\'') {
                if (byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                    index += 2;
                    continue;
                }
                if (byte == '\'') quote = null;
                index += 1;
                continue;
            }

            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == '"') quote = null;
            index += 1;
            continue;
        }

        if (byte == '#' and isCommentStart(input, index)) {
            index = lineAt(input, index).next;
            continue;
        }

        if ((byte == '\'' or byte == '"') and startsQuotedScalarForCharacterValidation(input, index)) {
            quote = byte;
            if (byte == target_quote) quote_start = index;
        }
        index += 1;
    }

    return if (quote == target_quote) quote_start else null;
}

fn consumeDiagnosticDoubleQuotedEscape(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    if (consumeLineBreak(input, start, input.len)) |next| return next;

    return switch (input[start]) {
        '0', 'a', 'b', 't', '\t', 'n', 'v', 'f', 'r', 'e', ' ', '"', '/', '\\', 'N', '_', 'L', 'P' => start + 1,
        'x' => consumeDiagnosticHexEscape(input, start, 2),
        'u' => consumeDiagnosticHexEscape(input, start, 4),
        'U' => consumeDiagnosticHexEscape(input, start, 8),
        else => null,
    };
}

fn consumeDiagnosticHexEscape(input: []const u8, marker: usize, digit_count: usize) ?usize {
    const digits_start = marker + 1;
    const digits_end = digits_start + digit_count;
    if (digits_end > input.len) return null;

    var codepoint: u21 = 0;
    for (input[digits_start..digits_end]) |byte| {
        const value = diagnosticHexDigitValue(byte) orelse return null;
        if (codepoint > (0x10ffff - value) / 16) return null;
        codepoint = codepoint * 16 + value;
    }
    if (!isValidEscapedCodepoint(codepoint)) return null;
    return digits_end;
}

fn diagnosticHexDigitValue(byte: u8) ?u21 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn isValidEscapedCodepoint(codepoint: u21) bool {
    return codepoint <= 0x10ffff and (codepoint < 0xd800 or codepoint > 0xdfff);
}

fn skipTagDiagnosticSeparators(line: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < line.len and isTagDiagnosticSeparator(line[cursor])) {
        cursor += 1;
    }
    return cursor;
}

fn skipTagDiagnosticToken(line: []const u8, start: usize) usize {
    if (start >= line.len) return start;

    return switch (line[start]) {
        '\'' => skipSingleQuotedDiagnosticToken(line, start),
        '"' => skipDoubleQuotedDiagnosticToken(line, start),
        else => value: {
            var cursor = start;
            while (cursor < line.len and !isTagDiagnosticSeparator(line[cursor])) {
                cursor += 1;
            }
            break :value cursor;
        },
    };
}

fn skipSingleQuotedDiagnosticToken(line: []const u8, start: usize) usize {
    var cursor = start + 1;
    while (cursor < line.len) : (cursor += 1) {
        if (line[cursor] != '\'') continue;
        if (cursor + 1 < line.len and line[cursor + 1] == '\'') {
            cursor += 1;
            continue;
        }
        return cursor + 1;
    }
    return line.len;
}

fn skipDoubleQuotedDiagnosticToken(line: []const u8, start: usize) usize {
    var cursor = start + 1;
    while (cursor < line.len) : (cursor += 1) {
        if (line[cursor] == '\\' and cursor + 1 < line.len) {
            cursor += 1;
            continue;
        }
        if (line[cursor] == '"') return cursor + 1;
    }
    return line.len;
}

fn isTagDiagnosticSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '[', ']', '{', '}', ',', ':', '?' => true,
        else => false,
    };
}

test "source diagnostic common: line and byte helpers cover YAML separators" {
    const input = "first\r\nsecond\xC2\x85third";

    const first = lineAt(input, 0);
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 5), first.end);
    try std.testing.expectEqual(@as(usize, 7), first.next);

    const second = lineAt(input, first.next);
    try std.testing.expectEqual(@as(usize, 7), second.start);
    try std.testing.expectEqual(@as(usize, 13), second.end);
    try std.testing.expectEqual(@as(usize, 15), second.next);

    try std.testing.expect(isSeparationByte(' '));
    try std.testing.expect(isSeparationByte('\t'));
    try std.testing.expect(isSeparationByte('\n'));
    try std.testing.expect(isLineBreakByte('\r'));
    try std.testing.expect(!isLineBreakByte('x'));
    try std.testing.expect(!isSeparationByte(','));
}

test "source diagnostic common: flow collection starts after YAML indicators" {
    const accepted = [_]u8{ 0, '[', '{', ',', ':', '?', '-' };
    for (accepted) |previous| {
        try std.testing.expect(canStartFlowCollection(previous));
    }

    for ([_]u8{ 'a', ']', '}', '#', ' ' }) |previous| {
        try std.testing.expect(!canStartFlowCollection(previous));
    }
}

test "source diagnostic common: tag URI hex digits accept both cases" {
    try std.testing.expect(isHexDigit('0'));
    try std.testing.expect(isHexDigit('f'));
    try std.testing.expect(isHexDigit('F'));
    try std.testing.expect(!isHexDigit('g'));
}

test "source diagnostic common: quoted comments and tag URI characters" {
    try std.testing.expectEqualStrings("'not # comment' ", stripLineComment("'not # comment' # comment"));
    try std.testing.expectEqualStrings("\"not \\# comment\" ", stripLineComment("\"not \\# comment\" # comment"));

    var runtime_line = "runtime # comment".*;
    try std.testing.expectEqualStrings("runtime ", stripLineComment(&runtime_line));

    try std.testing.expect(isValidVerbatimTag("tag:example.com,2026:yaml/[ok]%2f"));
    try std.testing.expect(!isValidVerbatimTag("tag:example.com,2026:yaml/%2"));
}

test "source directive diagnostics: large major versions are unsupported" {
    try std.testing.expectEqual(
        @as(?usize, 0),
        unsupportedYamlDirectiveVersionOffset("%YAML 65536.0\n---\nvalue\n"),
    );
    try std.testing.expectEqual(
        @as(?usize, 0),
        unsupportedYamlDirectiveVersionOffset("%YAML 999999999999999999999999.0\n---\nvalue\n"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        unsupportedYamlDirectiveVersionOffset("%YAML 1.999999999999999999999999\n---\nvalue\n"),
    );
}

test "source directive diagnostics: invalid TAG directives report directive line" {
    try std.testing.expectEqual(@as(?usize, 0), invalidTagDirectiveOffset("%TAG !bad tag:example.com,2000:app/\n--- value\n"));
    try std.testing.expectEqual(@as(?usize, 0), invalidTagDirectiveOffset("%TAG !e! [bad\n--- value\n"));
    try std.testing.expectEqual(@as(?usize, null), invalidTagDirectiveOffset("%TAG !e! tag:example.com,2000:app/\n--- !e!value\n"));
}

test "source directive diagnostics: duplicate TAG handles in initial prefix" {
    try std.testing.expectEqual(
        @as(?usize, "%TAG !e! tag:example.com,2000:app/\n".len),
        duplicateTagDirectiveOffset(
            "%TAG !e! tag:example.com,2000:app/\n" ++
                "%TAG !e! tag:example.com,2000:other/\n" ++
                "--- !e!value\n",
        ),
    );
}

test "source diagnostics: encoded input diagnostics report UTF-16 malformed offsets" {
    try std.testing.expect(encodedInputDiagnostic("plain utf8") == null);

    const odd_length_with_bom = "\xff\xfeA";
    const odd = encodedInputDiagnostic(odd_length_with_bom).?;
    try std.testing.expectEqualStrings("invalid UTF-16", odd.message);
    try std.testing.expectEqual(@as(usize, 2), odd.offset);

    const low_surrogate_without_bom = "\x00A\xdc\x00";
    const low = encodedInputDiagnostic(low_surrogate_without_bom).?;
    try std.testing.expectEqualStrings("invalid UTF-16", low.message);
    try std.testing.expectEqual(@as(usize, 2), low.offset);

    const high_surrogate_then_non_low = "A\x00\x00\xd8B\x00";
    const high = encodedInputDiagnostic(high_surrogate_then_non_low).?;
    try std.testing.expectEqualStrings("invalid UTF-16", high.message);
    try std.testing.expectEqual(@as(usize, 4), high.offset);
}

test "source diagnostics: encoded input diagnostics report UTF-32 malformed offsets" {
    const incomplete_unit_without_bom = "\x00\x00\x00A\x00";
    const incomplete = encodedInputDiagnostic(incomplete_unit_without_bom).?;
    try std.testing.expectEqualStrings("invalid UTF-32", incomplete.message);
    try std.testing.expectEqual(@as(usize, 4), incomplete.offset);

    const surrogate_without_bom = "A\x00\x00\x00\x00\xd8\x00\x00";
    const surrogate = encodedInputDiagnostic(surrogate_without_bom).?;
    try std.testing.expectEqualStrings("invalid UTF-32", surrogate.message);
    try std.testing.expectEqual(@as(usize, 4), surrogate.offset);

    const out_of_range_with_bom = "\x00\x00\xfe\xff\x00\x11\x00\x00";
    const out_of_range = encodedInputDiagnostic(out_of_range_with_bom).?;
    try std.testing.expectEqualStrings("invalid UTF-32", out_of_range.message);
    try std.testing.expectEqual(@as(usize, 4), out_of_range.offset);
}

test "source diagnostics: encoded input diagnostics fall back for valid encoded syntax errors" {
    const utf16_le_flow = "\x5b\x00";
    const utf16_le = encodedInputDiagnostic(utf16_le_flow).?;
    try std.testing.expectEqualStrings("invalid YAML syntax", utf16_le.message);
    try std.testing.expectEqual(@as(usize, 0), utf16_le.offset);

    const utf16_le_units = "\xff\xfeA\x00B\x00";
    const utf16_units = encodedInputDiagnostic(utf16_le_units).?;
    try std.testing.expectEqualStrings("invalid YAML syntax", utf16_units.message);
    try std.testing.expectEqual(@as(usize, 2), utf16_units.offset);

    const utf16_be_flow = "\x00[";
    const utf16 = encodedInputDiagnostic(utf16_be_flow).?;
    try std.testing.expectEqualStrings("invalid YAML syntax", utf16.message);
    try std.testing.expectEqual(@as(usize, 0), utf16.offset);

    const utf32_le_flow = "[\x00\x00\x00";
    const utf32 = encodedInputDiagnostic(utf32_le_flow).?;
    try std.testing.expectEqualStrings("invalid YAML syntax", utf32.message);
    try std.testing.expectEqual(@as(usize, 0), utf32.offset);
}

test "source diagnostic syntax: flow close scan resumes after comment line" {
    try std.testing.expectEqual(
        @as(?usize, 10),
        firstUnexpectedFlowCloseIndicatorOffset("# comment\n]"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        firstUnexpectedFlowCloseIndicatorOffset("{ok}"),
    );
}
