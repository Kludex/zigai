//! Purpose: Verify focused parser diagnostic helper branches.
//! Owns: Unit coverage for diagnostic scanners that are awkward to reach through full parser failures.
//! Does not own: Public diagnostic API integration or parser behavior.
//! Depends on: src/parser/diagnostics.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_event_parser");

const chars = internal.source_diagnostic_chars;
const common = internal.source_diagnostic_common;
const directive = internal.source_diagnostic_directive;
const encoding = internal.source_diagnostic_encoding;
const indent = internal.source_diagnostic_indent;
const source_diagnostic = internal.source_diagnostic;
const syntax = internal.source_diagnostic_syntax;
const scanner = internal.scanner;
const parseTokens = internal.parseTokens;
const ParseError = internal.types.ParseError;
const types = internal.types;

fn expectInvalidSyntaxFromScanOrParse(input: []const u8) !void {
    var token_stream = scanner.scan(std.testing.allocator, input) catch |err| {
        try std.testing.expectEqual(ParseError.InvalidSyntax, err);
        return;
    };
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "source diagnostics: common line marker and comment helpers cover quoted branches" {
    var flow_start_bytes = [_]u8{ 0, '[', '{', ',', ':', '?', '-', 'a' };
    flow_start_bytes[7] = 'a';
    for (flow_start_bytes[0..7]) |byte| {
        try std.testing.expect(common.canStartFlowCollection(byte));
    }
    try std.testing.expect(!common.canStartFlowCollection(flow_start_bytes[7]));

    const crlf_line = common.lineAt("one\r\ntwo", 0);
    try std.testing.expectEqual(@as(usize, 0), crlf_line.start);
    try std.testing.expectEqual(@as(usize, 3), crlf_line.end);
    try std.testing.expectEqual(@as(usize, 5), crlf_line.next);

    const final_line = common.lineAt("plain", 0);
    try std.testing.expectEqual(@as(usize, 0), final_line.start);
    try std.testing.expectEqual(@as(usize, 5), final_line.end);
    try std.testing.expectEqual(@as(usize, 5), final_line.next);

    const nel_line = common.lineAt("one\xc2\x85two", 0);
    try std.testing.expectEqual(@as(usize, 0), nel_line.start);
    try std.testing.expectEqual(@as(usize, 3), nel_line.end);
    try std.testing.expectEqual(@as(usize, 5), nel_line.next);

    const ls_line = common.lineAt("one\xe2\x80\xa8two", 0);
    try std.testing.expectEqual(@as(usize, 0), ls_line.start);
    try std.testing.expectEqual(@as(usize, 3), ls_line.end);
    try std.testing.expectEqual(@as(usize, 6), ls_line.next);

    const ps_line = common.lineAt("one\xe2\x80\xa9two", 0);
    try std.testing.expectEqual(@as(usize, 0), ps_line.start);
    try std.testing.expectEqual(@as(usize, 3), ps_line.end);
    try std.testing.expectEqual(@as(usize, 6), ps_line.next);

    try std.testing.expect(common.isDocumentEndMarker("..."));
    try std.testing.expect(common.isDocumentEndMarker("... # done"));
    try std.testing.expect(!common.isDocumentEndMarker("...suffix"));

    try std.testing.expectEqualStrings(
        "'can''t # still quoted' ",
        common.stripLineComment("'can''t # still quoted' # real"),
    );
    var runtime_single_quoted_comment = "'runtime # still quoted' # real".*;
    try std.testing.expectEqualStrings(
        "'runtime # still quoted' ",
        common.stripLineComment(&runtime_single_quoted_comment),
    );
    try std.testing.expectEqualStrings(
        "\"escaped \\\" # still quoted\" ",
        common.stripLineComment("\"escaped \\\" # still quoted\" # real"),
    );
    try std.testing.expectEqualStrings("plain ", common.stripLineComment("plain # comment"));

    try std.testing.expect(!common.isCommentStart("plain#text", 5));
    try std.testing.expect(common.isCommentStart("plain #text", 6));
    try std.testing.expect(common.isCommentStart("plain\xc2\x85#text", 7));
    try std.testing.expect(common.isCommentStart("plain\xe2\x80\xa8#text", 8));
    try std.testing.expect(common.isCommentStart("plain\xe2\x80\xa9#text", 8));
    try std.testing.expectEqual(@as(?usize, 3), common.consumeLineBreak("a\r\nb", 1, 4));
    try std.testing.expectEqual(@as(?usize, 3), common.consumeLineBreak("a\xc2\x85b", 1, 4));
    try std.testing.expectEqual(@as(?usize, 4), common.consumeLineBreak("a\xe2\x80\xa8b", 1, 5));
    try std.testing.expectEqual(@as(?usize, 4), common.consumeLineBreak("a\xe2\x80\xa9b", 1, 5));

    var runtime_bytes = [_]u8{ '\n', '\r', 'x' };
    runtime_bytes[2] = 'x';
    try std.testing.expect(common.isLineBreakByte(runtime_bytes[0]));
    try std.testing.expect(common.isLineBreakByte(runtime_bytes[1]));
    try std.testing.expect(!common.isLineBreakByte(runtime_bytes[2]));

    try std.testing.expect(common.isLineBreakByte('\n'));
    try std.testing.expect(common.isLineBreakByte('\r'));
    try std.testing.expect(!common.isLineBreakByte('x'));
    try std.testing.expect(common.isSeparationByte(' '));
    try std.testing.expect(common.isSeparationByte('\t'));
    try std.testing.expect(common.isSeparationByte('\n'));
}

test "source diagnostics: common tag and quoted-scalar helpers cover edge cases" {
    try std.testing.expectEqualStrings("value", common.stripUtf8Bom(common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(usize, common.utf8_bom.len), common.directiveLinePrefixOffset(common.utf8_bom ++ "%YAML 1.2"));
    try std.testing.expectEqual(@as(usize, 0), common.directiveLinePrefixOffset("%YAML 1.2"));

    try std.testing.expect(common.isDocumentStartMarker("---"));
    try std.testing.expect(common.isDocumentStartMarker("--- # comment"));
    try std.testing.expect(!common.isDocumentStartMarker("---suffix"));
    try std.testing.expect(!common.isDocumentStartMarker("--"));

    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("\"top\"", 0));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("!tag \"tagged\"", 5));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("[\"flow\"]", 1));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("? \"key\"", 2));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("- \"entry\"", 2));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("plain\xc2\x85\"next\"", 7));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("plain\xe2\x80\xa8  \"next\"", 10));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("plain\xe2\x80\xa9  \"next\"", 10));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("  \"indented\"", 2));
    try std.testing.expect(!common.startsQuotedScalarForCharacterValidation("plain \"content\"", 6));

    try std.testing.expect(common.isValidVerbatimTag("!local"));
    try std.testing.expect(common.isValidVerbatimTag("tag:example.com,2000:app"));
    try std.testing.expect(!common.isValidVerbatimTag(""));
    try std.testing.expect(!common.isValidVerbatimTag("tag{bad"));
    try std.testing.expect(!common.isValidVerbatimTag("noscheme"));

    try std.testing.expectEqual(@as(?usize, 1), common.tagHandleLen("!"));
    try std.testing.expectEqual(@as(?usize, 2), common.tagHandleLen("!!str"));
    try std.testing.expectEqual(@as(?usize, 3), common.tagHandleLen("!e!value"));
    try std.testing.expectEqual(@as(?usize, null), common.tagHandleLen("tag:example.com,2000:app"));
    try std.testing.expectEqual(@as(?usize, null), common.tagHandleLen("!bad"));
    try std.testing.expectEqual(@as(?usize, null), common.tagHandleLen(""));
    try std.testing.expectEqual(@as(?usize, null), common.tagHandleLen("x"));
    try std.testing.expectEqual(@as(?usize, 2), common.tagHandleLen("!!"));

    try std.testing.expect(common.canStartFlowCollection(0));
    try std.testing.expect(common.canStartFlowCollection(','));
    try std.testing.expect(!common.canStartFlowCollection('a'));

    try std.testing.expect(common.isHexDigit('F'));
    try std.testing.expect(common.isHexDigit('0'));
    try std.testing.expect(common.isHexDigit('a'));
    try std.testing.expect(!common.isHexDigit('g'));
}

test "source diagnostics: tab-indented mapping ignores flow separators" {
    try std.testing.expectEqual(@as(?usize, 0), indent.firstTabIndentedBlockNodeOffset("\tkey [item]: value"));
    try std.testing.expectEqual(@as(?usize, 5), indent.firstTabIndentedBlockNodeOffset("key:\n\t[flow]\n"));
}

test "source diagnostics: character scans locate malformed and misplaced bytes" {
    try std.testing.expectEqual(@as(?usize, 0), chars.firstInvalidUtf8Offset("\x80"));
    try std.testing.expectEqual(@as(?usize, 0), chars.firstInvalidUtf8Offset("\xe2\x82"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstInvalidUtf8Offset("ok"));

    try std.testing.expectEqual(@as(?usize, 1), chars.firstNonPrintableOffset("a\x01"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstNonPrintableOffset("'can''t'"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstNonPrintableOffset("\"escaped \\\" quote\""));

    try std.testing.expectEqual(@as(?usize, 1), chars.firstMisplacedUtf8BomOffset("a" ++ common.utf8_bom));
    try std.testing.expectEqual(@as(?usize, 14), chars.firstMisplacedUtf8BomOffset("plain \" quote " ++ common.utf8_bom ++ " text"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\r" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\r\n" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\n" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\xc2\x85" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\xe2\x80\xa8" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\xe2\x80\xa9" ++ common.utf8_bom ++ "value"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\"" ++ common.utf8_bom ++ "\""));
}

test "source diagnostics: encoded input accepts valid UTF-16 surrogate pairs before syntax fallback" {
    const utf16_le_pair = "\xff\xfe=\xd8\x00\xde";
    const diagnostic = encoding.encodedInputDiagnostic(utf16_le_pair).?;

    try std.testing.expectEqualStrings("invalid YAML syntax", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.offset);
}

test "source diagnostics: encoded input scans multiple valid UTF-16 units before syntax fallback" {
    const utf16_le_units = "\xff\xfeA\x00B\x00";
    const diagnostic = encoding.encodedInputDiagnostic(utf16_le_units).?;

    try std.testing.expectEqualStrings("invalid YAML syntax", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.offset);
}

test "source diagnostics: reserved indicator and flow depth scans cover edge cases" {
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset("[ @bad ]"));
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset("- @bad"));
    try std.testing.expectEqual(@as(?usize, 0), chars.firstReservedPlainScalarIndicatorOffset("@bad"));
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset("{ `bad }"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstReservedPlainScalarIndicatorOffset("plain @text"));
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset("? @bad"));
    try std.testing.expectEqual(@as(?usize, 6), chars.firstReservedPlainScalarIndicatorOffset("plain\r@bad"));
    try std.testing.expectEqual(@as(?usize, 7), chars.firstReservedPlainScalarIndicatorOffset("plain\r\n`bad"));
    try std.testing.expectEqual(@as(?usize, 7), chars.firstReservedPlainScalarIndicatorOffset("plain\xc2\x85@bad"));
    try std.testing.expectEqual(@as(?usize, 8), chars.firstReservedPlainScalarIndicatorOffset("plain\xe2\x80\xa8`bad"));
    try std.testing.expectEqual(@as(?usize, 8), chars.firstReservedPlainScalarIndicatorOffset("plain\xe2\x80\xa9@bad"));

    var deep: [1026]u8 = undefined;
    @memset(deep[0..1025], '[');
    deep[1025] = ']';
    try std.testing.expectEqual(@as(?usize, 1024), chars.firstUnsupportedFlowDepthOffset(&deep));
    try std.testing.expectEqual(@as(?usize, null), chars.firstUnsupportedFlowDepthOffset("\"[[[[\" # quoted"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstUnsupportedFlowDepthOffset("['it''s', \"\\]\", {ok: yes}] # done\nplain"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstUnsupportedFlowDepthOffset("[ # comment"));

    try std.testing.expectEqual(@as(usize, 3), chars.firstContentOffset(" \n\tvalue"));
    try std.testing.expectEqual(@as(usize, 0), chars.firstContentOffset(" \n\t"));
}

test "source diagnostics: flow depth resets after every YAML line break" {
    const line_breaks = [_][]const u8{ "\r", "\r\n", "\xc2\x85", "\xe2\x80\xa8", "\xe2\x80\xa9" };

    for (line_breaks) |line_break| {
        var input: ["plain".len + "\xe2\x80\xa8".len + 1025]u8 = undefined;
        @memcpy(input[0.."plain".len], "plain");
        @memcpy(input["plain".len..][0..line_break.len], line_break);
        @memset(input["plain".len + line_break.len ..][0..1025], '[');

        try std.testing.expectEqual(
            @as(?usize, "plain".len + line_break.len + 1024),
            chars.firstUnsupportedFlowDepthOffset(input[0 .. "plain".len + line_break.len + 1025]),
        );
    }
}

test "source diagnostics: unsupported content skips every YAML line break" {
    const line_breaks = [_][]const u8{ "\n", "\r", "\r\n", "\xc2\x85", "\xe2\x80\xa8", "\xe2\x80\xa9" };

    for (line_breaks) |line_break| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ " \t", line_break, "unsupported" });
        defer std.testing.allocator.free(input);

        try std.testing.expectEqual(@as(usize, 2 + line_break.len), chars.firstContentOffset(input));
    }
}

test "source diagnostics: tab indentation scans cover block-node edge cases" {
    try std.testing.expectEqual(@as(?usize, 5), indent.firstTabIndentedBlockNodeOffset("key:\n\t[value]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: value\n\t[value]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key:\n\t# comment\n"));
    try std.testing.expectEqual(@as(?usize, 0), indent.firstTabIndentedBlockNodeOffset("\tkey: value\n"));
    try std.testing.expectEqual(@as(?usize, 4), indent.firstTabIndentedBlockNodeOffset("-\n  \t{flow: value}\n"));
}

test "source diagnostics: tab indentation ignores inline flow and quoted mapping separators" {
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: [a: b]\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: {a: b}\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: 'a: b'\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: \"a\\\": b\"\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 2), indent.firstTabIndentedBlockNodeOffset("?\n\t[flow]\n"));
}

test "source diagnostics: tab indentation scans quoted and flow mapping keys" {
    try std.testing.expectEqual(@as(?usize, 9), indent.firstTabIndentedBlockNodeOffset("'it''s':\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 10), indent.firstTabIndentedBlockNodeOffset("\"a\\\": b\":\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 8), indent.firstTabIndentedBlockNodeOffset("{a: b}:\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 8), indent.firstTabIndentedBlockNodeOffset("[a: b]:\n\t[flow]\n"));
}

test "source diagnostics: tab indentation scans empty mapping-value requests" {
    try std.testing.expectEqual(@as(?usize, 6), indent.firstTabIndentedBlockNodeOffset("key: \n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 14), indent.firstTabIndentedBlockNodeOffset("flow [a: b]: \n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 16), indent.firstTabIndentedBlockNodeOffset("quoted 'a: b': \n\t[flow]\n"));
}

test "source diagnostics: tab indentation ignores non-empty mapping-value requests" {
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: value\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: []\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: {}\n\t[flow]\n"));
}

test "source diagnostics: tab indentation scans balanced flow separators" {
    try std.testing.expectEqual(@as(?usize, 7), indent.firstTabIndentedBlockNodeOffset("[a]:\n  \t[key]\n"));
    try std.testing.expectEqual(@as(?usize, 7), indent.firstTabIndentedBlockNodeOffset("{a}:\n  \t{key}\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("[a]]\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key without separator\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key [a] # comment\n\t[flow]\n"));
}

test "source diagnostics: tab indentation scans property and comment-empty mapping values" {
    try std.testing.expectEqual(@as(?usize, 15), indent.firstTabIndentedBlockNodeOffset("key: # comment\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, 2), indent.firstTabIndentedBlockNodeOffset("-\n\t{flow: value}\n"));
    try std.testing.expectEqual(@as(?usize, 2), indent.firstTabIndentedBlockNodeOffset("?\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("\t[not block]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: &a value\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: !tag value\n\t[flow]\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("key: *alias value\n\t[flow]\n"));
}

test "source diagnostics: character scans ignore escaped quote content where allowed" {
    try std.testing.expectEqual(@as(?usize, null), chars.firstNonPrintableOffset("'it''s printable'"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstNonPrintableOffset("\"escaped \\\" quote\""));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("'it''s " ++ common.utf8_bom ++ "'"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstMisplacedUtf8BomOffset("\"escaped \\" ++ common.utf8_bom ++ "\""));
}

test "source diagnostics: character scans cover quoted invalid bytes and flow line breaks" {
    try std.testing.expectEqual(@as(?usize, 0), chars.firstInvalidUtf8Offset("\xf4\x90\x80\x80"));
    try std.testing.expectEqual(@as(?usize, 5), chars.firstNonPrintableOffset("\"bad \x01\""));
    try std.testing.expectEqual(@as(?usize, 5), chars.firstNonPrintableOffset("'bad \x01'"));
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset(": @bad"));
    try std.testing.expectEqual(@as(?usize, 2), chars.firstReservedPlainScalarIndicatorOffset(", `bad"));
    try std.testing.expectEqual(@as(?usize, null), chars.firstUnsupportedFlowDepthOffset("plain [[[["));

    var deep: [1027]u8 = undefined;
    deep[0] = '[';
    deep[1] = '\n';
    @memset(deep[2..], '[');
    try std.testing.expectEqual(@as(?usize, 1025), chars.firstUnsupportedFlowDepthOffset(&deep));
    try std.testing.expectEqual(@as(?usize, null), chars.firstUnsupportedFlowDepthOffset("[#not-comment\n]"));
}

test "source diagnostics: encoded input diagnostics report malformed code units" {
    try std.testing.expect(encoding.encodedInputDiagnostic("ok") == null);

    const utf16_odd = "\xff\xfea";
    const odd = encoding.encodedInputDiagnostic(utf16_odd).?;
    try std.testing.expectEqualStrings("invalid UTF-16", odd.message);
    try std.testing.expectEqual(@as(usize, 2), odd.offset);

    const utf16_high_surrogate = "\xff\xfe\x00\xd8";
    const high = encoding.encodedInputDiagnostic(utf16_high_surrogate).?;
    try std.testing.expectEqualStrings("invalid UTF-16", high.message);
    try std.testing.expectEqual(@as(usize, 2), high.offset);

    const utf32_invalid = "\xff\xfe\x00\x00\x00\x00\x11\x00";
    const invalid32 = encoding.encodedInputDiagnostic(utf32_invalid).?;
    try std.testing.expectEqualStrings("invalid UTF-32", invalid32.message);
    try std.testing.expectEqual(@as(usize, 4), invalid32.offset);

    const utf16_valid_but_rejected = "\xff\xfea\x00";
    const syntax_error = encoding.encodedInputDiagnostic(utf16_valid_but_rejected).?;
    try std.testing.expectEqualStrings("invalid YAML syntax", syntax_error.message);
    try std.testing.expectEqual(@as(usize, 2), syntax_error.offset);
}

test "source diagnostics: syntax scans locate tag flow and quoted-scalar failures" {
    try std.testing.expectEqual(@as(?usize, 0), syntax.firstInvalidTagPropertyOffset("!<> value"));
    try std.testing.expectEqual(@as(?usize, 0), syntax.firstInvalidTagPropertyOffset("!<noscheme> value"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidTagPropertyOffset("!<tag:example.com,2000:ok> value"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidTagPropertyOffset("'!<ignored>' \"!<also ignored>\" !<tag:example.com,2000:ok>"));
    try std.testing.expectEqual(@as(?usize, 8), syntax.firstInvalidTagPropertyOffset("'it''s' !<noscheme>"));
    try std.testing.expectEqual(@as(?usize, 13), syntax.firstInvalidTagPropertyOffset("\"escaped \\\"\" !<noscheme>"));
    try std.testing.expectEqual(@as(?usize, 5), syntax.missingTagShorthandSuffixOffset("key: !!\n"));
    try std.testing.expectEqual(@as(?usize, 2), syntax.missingTagShorthandSuffixOffset("[ !! ]"));
    try std.testing.expectEqual(@as(?usize, null), syntax.missingTagShorthandSuffixOffset("key: ! value\n"));

    try std.testing.expectEqual(@as(?usize, 0), syntax.firstUnexpectedFlowCloseIndicatorOffset("]"));
    try std.testing.expectEqual(@as(?usize, 0), syntax.firstUnexpectedFlowCloseIndicatorOffset("}"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("[# comment\n]"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("[ # comment\n]"));
    try std.testing.expectEqual(@as(?usize, 16), syntax.firstUnexpectedFlowCloseIndicatorOffset("plain # comment\n]"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("['it''s', \"\\]\", {ok: yes}]"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("[']']"));

    try std.testing.expectEqual(@as(?usize, 1), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\q\""));
    try std.testing.expectEqual(@as(?usize, 1), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\x0g\""));
    try std.testing.expectEqual(@as(?usize, 1), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\uD800\""));
    try std.testing.expectEqual(@as(?usize, 1), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\U00110000\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("'it''s \\q' \"ok\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\nnext\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\rnext\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\r\nnext\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\xc2\x85next\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\xe2\x80\xa8next\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"line\\\xe2\x80\xa9next\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\0\\a\\b\\t\\\t\\n\\v\\f\\r\\e\\ \\\"\\/\\\\\\N\\_\\L\\P\\x41\\u0041\\U00000041\""));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\x0a\\u00af\""));

    try std.testing.expectEqual(@as(?usize, 0), syntax.firstUnterminatedQuotedScalarOffset("'it''s", '\''));
    try std.testing.expectEqual(@as(?usize, 0), syntax.firstUnterminatedQuotedScalarOffset("\"open", '"'));
    try std.testing.expectEqual(@as(?usize, 10), syntax.firstUnterminatedQuotedScalarOffset("# comment\n\"open", '"'));
    try std.testing.expectEqual(@as(?usize, 0), syntax.firstUnterminatedQuotedScalarOffset("\"escaped \\\" still open", '"'));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnterminatedQuotedScalarOffset("'it''s'", '\''));
}

test "source diagnostics: tag property scan skips quoted tokens before later invalid tags" {
    try std.testing.expectEqual(@as(?usize, 15), syntax.firstInvalidTagPropertyOffset("'!<ignored>' [ !<noscheme>"));
    try std.testing.expectEqual(@as(?usize, 26), syntax.firstInvalidTagPropertyOffset("\"escaped \\\" !<ignored>\" , !<noscheme>"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidTagPropertyOffset("'!<unterminated>"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidTagPropertyOffset("\"!<unterminated>"));
}

test "source diagnostics: common tag helpers reject malformed URI forms" {
    try std.testing.expect(!common.isValidVerbatimTag("1bad:still"));
    try std.testing.expect(!common.isValidVerbatimTag("a_bad"));
    try std.testing.expect(!common.isValidVerbatimTag("tag%2Gbad"));
    try std.testing.expect(!common.isValidVerbatimTag("tag%"));
    try std.testing.expect(common.isValidVerbatimTag("a+b.c-tag:ok"));
    try std.testing.expectEqual(@as(?usize, null), common.tagHandleLen("!bad_"));
    try std.testing.expect(common.startsQuotedScalarForCharacterValidation("&a \"v\"", 3));
    try std.testing.expect(!common.startsQuotedScalarForCharacterValidation("plain text \"quoted\"", 11));
}

test "source diagnostics: directive scans reset across document boundaries" {
    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML 1.x\n---\nvalue\n"));
    try std.testing.expectEqual(@as(?usize, 5), directive.unsupportedYamlDirectiveVersionOffset("# ok\n%YAML 2.0\n---\nvalue\n"));

    try std.testing.expectEqual(@as(?usize, 10), directive.duplicateYamlDirectiveOffset("%YAML 1.2\n%YAML 1.2\n---\nvalue\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateYamlDirectiveOffset("%YAML 1.2\n---\nvalue\n...\n%YAML 1.2\n---\nagain\n"));

    try std.testing.expectEqual(@as(?usize, 31), directive.duplicateTagDirectiveOffset("%TAG !e! tag:example.com,2000:\n%TAG !e! tag:example.org,2000:\n---\n!e!v tagged\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateTagDirectiveOffset("%TAG !e! tag:example.com,2000:\n---\n!e!v tagged\n...\n%TAG !e! tag:example.org,2000:\n---\n!e!v again\n"));
}

test "source diagnostics: directive scans honor every YAML line break" {
    const line_breaks = [_][]const u8{ "\n", "\r", "\r\n", "\xc2\x85", "\xe2\x80\xa8", "\xe2\x80\xa9" };

    for (line_breaks) |line_break| {
        const unsupported = try std.mem.concat(std.testing.allocator, u8, &.{
            "%YAML 1.2", line_break,
            "%YAML 2.0", line_break,
            "---",       line_break,
            "value",     line_break,
        });
        defer std.testing.allocator.free(unsupported);
        try std.testing.expectEqual(@as(?usize, "%YAML 1.2".len + line_break.len), directive.unsupportedYamlDirectiveVersionOffset(unsupported));

        const duplicate_yaml = try std.mem.concat(std.testing.allocator, u8, &.{
            "%YAML 1.2", line_break,
            "%YAML 1.2", line_break,
            "---",       line_break,
            "value",     line_break,
        });
        defer std.testing.allocator.free(duplicate_yaml);
        try std.testing.expectEqual(@as(?usize, "%YAML 1.2".len + line_break.len), directive.duplicateYamlDirectiveOffset(duplicate_yaml));

        const duplicate_tag = try std.mem.concat(std.testing.allocator, u8, &.{
            "%TAG !e! tag:example.com,2000:", line_break,
            "%TAG !e! tag:example.org,2000:", line_break,
            "---",                            line_break,
            "!e!v tagged",                    line_break,
        });
        defer std.testing.allocator.free(duplicate_tag);
        try std.testing.expectEqual(@as(?usize, "%TAG !e! tag:example.com,2000:".len + line_break.len), directive.duplicateTagDirectiveOffset(duplicate_tag));

        const reset = try std.mem.concat(std.testing.allocator, u8, &.{
            "%YAML 1.2", line_break,
            "---",       line_break,
            "value",     line_break,
            "...",       line_break,
            "%YAML 1.2", line_break,
            "---",       line_break,
            "again",     line_break,
        });
        defer std.testing.allocator.free(reset);
        try std.testing.expectEqual(@as(?usize, null), directive.duplicateYamlDirectiveOffset(reset));
    }
}

test "source diagnostics: directive scans handle BOM prefixes and malformed versions" {
    const bom_yaml = common.utf8_bom ++ "%YAML 2.0\n---\nvalue\n";
    try std.testing.expectEqual(@as(?usize, common.utf8_bom.len), directive.unsupportedYamlDirectiveVersionOffset(bom_yaml));

    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML 1\n---\nvalue\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML 1.\n---\nvalue\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML 1.2.3\n---\nvalue\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML x.2\n---\nvalue\n"));

    const duplicate_with_comment = "%YAML 1.2 # ok\n%YAML 1.2\n---\nvalue\n";
    try std.testing.expectEqual(@as(?usize, 15), directive.duplicateYamlDirectiveOffset(duplicate_with_comment));

    const duplicate_tag_with_bom = "%TAG !e! tag:example.com,2000:\n" ++ common.utf8_bom ++ "%TAG !e! tag:example.org,2000:\n---\n!e!v tagged\n";
    const duplicate_line = std.mem.indexOf(u8, duplicate_tag_with_bom, common.utf8_bom ++ "%TAG").?;
    try std.testing.expectEqual(@as(?usize, duplicate_line + common.utf8_bom.len), directive.duplicateTagDirectiveOffset(duplicate_tag_with_bom));
}

test "source diagnostics: directive scans stop outside directive prefix" {
    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("---\n%YAML 2.0\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateYamlDirectiveOffset("---\n%YAML 1.2\n%YAML 1.2\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateTagDirectiveOffset("---\n%TAG !e! tag:example.com,2000:\n%TAG !e! tag:example.org,2000:\n"));

    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("value\n%YAML 2.0\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateYamlDirectiveOffset("value\n%YAML 1.2\n%YAML 1.2\n"));
    try std.testing.expectEqual(@as(?usize, null), directive.duplicateTagDirectiveOffset("value\n%TAG !e! tag:example.com,2000:\n%TAG !e! tag:example.org,2000:\n"));

    try std.testing.expectEqual(@as(?usize, null), directive.unsupportedYamlDirectiveVersionOffset("%YAML 2.0 extra\n---\nvalue\n"));
}

test "source diagnostics: tab indentation scans node-property block mapping lines" {
    try std.testing.expectEqual(@as(?usize, 0), indent.firstTabIndentedBlockNodeOffset("\t&anchor key: value\n"));
    try std.testing.expectEqual(@as(?usize, 0), indent.firstTabIndentedBlockNodeOffset("\t!tag key: value\n"));
    try std.testing.expectEqual(@as(?usize, 0), indent.firstTabIndentedBlockNodeOffset("\t*alias key: value\n"));
    try std.testing.expectEqual(@as(?usize, null), indent.firstTabIndentedBlockNodeOffset("\t&anchor # property-only comment\n"));
}

test "source diagnostics: parse-error selector covers fallback branches" {
    const oom = source_diagnostic.diagnosticForParseError("value", error.OutOfMemory);
    try std.testing.expectEqualStrings("out of memory", oom.message);
    try std.testing.expectEqual(@as(usize, 0), oom.offset);

    const unsupported = source_diagnostic.diagnosticForParseError(" \n\tfeature", error.Unsupported);
    try std.testing.expectEqualStrings("unsupported YAML feature", unsupported.message);
    try std.testing.expectEqual(@as(usize, 3), unsupported.offset);

    var deep: [1026]u8 = undefined;
    @memset(deep[0..1025], '[');
    deep[1025] = ']';
    const unsupported_depth = source_diagnostic.diagnosticForParseError(&deep, error.Unsupported);
    try std.testing.expectEqualStrings("flow collection nesting exceeds parser limit", unsupported_depth.message);
    try std.testing.expectEqual(@as(usize, 1024), unsupported_depth.offset);

    const invalid = source_diagnostic.diagnosticForParseError(" \n\t", error.InvalidSyntax);
    try std.testing.expectEqualStrings("invalid YAML syntax", invalid.message);
    try std.testing.expectEqual(@as(usize, 0), invalid.offset);
}

test "source diagnostics: YAML input character boundaries" {
    const cases = [_]struct {
        input: []const u8,
        invalid_offset: ?usize,
    }{
        .{ .input = "\x09", .invalid_offset = null },
        .{ .input = "\x0a", .invalid_offset = null },
        .{ .input = "\x0d", .invalid_offset = null },
        .{ .input = "\x1f", .invalid_offset = 0 },
        .{ .input = "\x20", .invalid_offset = null },
        .{ .input = "\x7e", .invalid_offset = null },
        .{ .input = "\x7f", .invalid_offset = 0 },
        .{ .input = "\xc2\x84", .invalid_offset = 0 },
        .{ .input = "\xc2\x85", .invalid_offset = null },
        .{ .input = "\xc2\x9f", .invalid_offset = 0 },
        .{ .input = "\xc2\xa0", .invalid_offset = null },
        .{ .input = "\xed\x9f\xbf", .invalid_offset = null },
        .{ .input = "\xee\x80\x80", .invalid_offset = null },
        .{ .input = "\xef\xbf\xbd", .invalid_offset = null },
        .{ .input = "\xf0\x90\x80\x80", .invalid_offset = null },
        .{ .input = "\xf4\x8f\xbf\xbf", .invalid_offset = null },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.invalid_offset, chars.firstNonPrintableOffset(case.input));
    }
}

test "source diagnostics: unsupported flow depth offset" {
    const too_deep = "[" ** (internal.parser.max_block_depth + 1);
    const too_deep_mapping = "{" ** (internal.parser.max_block_depth + 1);
    const quoted_then_too_deep = "\"quoted [ text\"\n" ++ too_deep;

    try std.testing.expectEqual(
        @as(?usize, internal.parser.max_block_depth),
        chars.firstUnsupportedFlowDepthOffset(too_deep[0..]),
    );
    try std.testing.expectEqual(
        @as(?usize, internal.parser.max_block_depth),
        chars.firstUnsupportedFlowDepthOffset(too_deep_mapping[0..]),
    );
    try std.testing.expectEqual(
        @as(?usize, "\"quoted [ text\"\n".len + internal.parser.max_block_depth),
        chars.firstUnsupportedFlowDepthOffset(quoted_then_too_deep[0..]),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        chars.firstUnsupportedFlowDepthOffset("'[[[' # comment [\n"),
    );
}

test "source diagnostics: UTF-8 BOM is allowed at line start" {
    try std.testing.expectEqual(
        @as(?usize, null),
        chars.firstMisplacedUtf8BomOffset("\n\xEF\xBB\xBFkey: value\n"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        chars.firstMisplacedUtf8BomOffset("\xEF\xBB\xBFkey: value\n"),
    );
}

test "source diagnostics: syntax scanners skip comments and quoted flow indicators" {
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("[\" ] \", ']"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("[''']''']"));
    try std.testing.expectEqual(@as(?usize, 17), syntax.firstUnexpectedFlowCloseIndicatorOffset("[ok] # comment ]\n}"));
    try std.testing.expectEqual(@as(?usize, 10), syntax.firstUnexpectedFlowCloseIndicatorOffset("# comment\n]"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("{ok}"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnexpectedFlowCloseIndicatorOffset("{k: [v]}"));
}

test "source diagnostics: syntax scanners report escaped EOF and ignored single quotes" {
    try std.testing.expectEqual(@as(?usize, 1), syntax.firstInvalidDoubleQuotedEscapeOffset("\"\\"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidDoubleQuotedEscapeOffset("'\\q'"));
    try std.testing.expectEqual(@as(?usize, null), syntax.firstUnterminatedQuotedScalarOffset("'closed'\n\"open", '\''));
    try std.testing.expectEqual(@as(?usize, 9), syntax.firstUnterminatedQuotedScalarOffset("'closed'\n\"open", '"'));
}

test "source diagnostics: tag scanner treats flow punctuation as separators" {
    try std.testing.expectEqual(@as(?usize, null), syntax.firstInvalidTagPropertyOffset("[!<tag:example.com,2000:seq>, {!<tag:example.com,2000:key>: !<tag:example.com,2000:value>}]"));
    try std.testing.expectEqual(@as(?usize, 2), syntax.missingTagShorthandSuffixOffset("[ !!, value ]"));
    try std.testing.expectEqual(@as(?usize, 2), syntax.missingTagShorthandSuffixOffset("{ !!: value }"));
    try std.testing.expectEqual(@as(?usize, 2), syntax.missingTagShorthandSuffixOffset("? !!\n"));
}

test "parseTokens rejects multiline implicit flow collection keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\[23
        \\]: 42
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects multiline implicit plain block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\multi
        \\  line
        \\: value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects nested multiline implicit plain block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\outer:
        \\  multi
        \\    line
        \\  : value
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens accepts multiline explicit plain block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\? multi
        \\  line
        \\: value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("multi line", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .mapping_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens rejects flow implicit keys followed by newline" {
    var sequence_tokens = try scanner.scan(std.testing.allocator,
        \\---
        \\[ key
        \\  : value ]
        \\
    );
    defer sequence_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, sequence_tokens.tokens));
}

test "parseTokens rejects implicit keys longer than 1024 characters" {
    var block_input: std.ArrayList(u8) = .empty;
    defer block_input.deinit(std.testing.allocator);
    try block_input.appendNTimes(std.testing.allocator, 'a', 1025);
    try block_input.appendSlice(std.testing.allocator, ": value\n");

    var block_tokens = try scanner.scan(std.testing.allocator, block_input.items);
    defer block_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, block_tokens.tokens));

    var flow_input: std.ArrayList(u8) = .empty;
    defer flow_input.deinit(std.testing.allocator);
    try flow_input.append(std.testing.allocator, '{');
    try flow_input.appendNTimes(std.testing.allocator, 'a', 1025);
    try flow_input.appendSlice(std.testing.allocator, ": value}\n");

    var flow_tokens = try scanner.scan(std.testing.allocator, flow_input.items);
    defer flow_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, flow_tokens.tokens));
}

test "parseTokens counts flow collection delimiters in implicit key length" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.append(std.testing.allocator, '[');
    try input.appendNTimes(std.testing.allocator, 'a', 1023);
    try input.appendSlice(std.testing.allocator, "]: value\n");

    var token_stream = try scanner.scan(std.testing.allocator, input.items);
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects alias implicit keys longer than 1024 characters" {
    var block_input: std.ArrayList(u8) = .empty;
    defer block_input.deinit(std.testing.allocator);
    try block_input.append(std.testing.allocator, '*');
    try block_input.appendNTimes(std.testing.allocator, 'a', 1024);
    try block_input.appendSlice(std.testing.allocator, " : value\n");

    var block_tokens = try scanner.scan(std.testing.allocator, block_input.items);
    defer block_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, block_tokens.tokens));

    var flow_input: std.ArrayList(u8) = .empty;
    defer flow_input.deinit(std.testing.allocator);
    try flow_input.appendSlice(std.testing.allocator, "[*");
    try flow_input.appendNTimes(std.testing.allocator, 'a', 1024);
    try flow_input.appendSlice(std.testing.allocator, " : value]\n");

    var flow_tokens = try scanner.scan(std.testing.allocator, flow_input.items);
    defer flow_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, flow_tokens.tokens));

    var compact_input: std.ArrayList(u8) = .empty;
    defer compact_input.deinit(std.testing.allocator);
    try compact_input.appendSlice(std.testing.allocator, "- *");
    try compact_input.appendNTimes(std.testing.allocator, 'a', 1024);
    try compact_input.appendSlice(std.testing.allocator, " : value\n");

    var compact_tokens = try scanner.scan(std.testing.allocator, compact_input.items);
    defer compact_tokens.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, compact_tokens.tokens));
}

test "parseTokens accepts long alias nodes outside implicit keys" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "- - *");
    try input.appendNTimes(std.testing.allocator, 'a', 1024);
    try input.append(std.testing.allocator, '\n');

    var token_stream = try scanner.scan(std.testing.allocator, input.items);
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expect(event_stream.events[4] == .alias);
    try std.testing.expectEqual(@as(usize, 1024), event_stream.events[4].alias.len);
}

test "parseTokens rejects block sequence aliases with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- *anchor
        \\  trailing
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects nested block sequence aliases with following content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key:
        \\  - *anchor
        \\    trailing
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses block sequence aliases before following entries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- *anchor
        \\- next
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 8), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[3].alias);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("next", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .document_end);
    try std.testing.expect(event_stream.events[7] == .stream_end);
}

test "parseTokens accepts implicit keys up to 1024 characters" {
    var block_input: std.ArrayList(u8) = .empty;
    defer block_input.deinit(std.testing.allocator);
    try block_input.appendNTimes(std.testing.allocator, 'a', 1024);
    try block_input.appendSlice(std.testing.allocator, ": value\n");

    var block_tokens = try scanner.scan(std.testing.allocator, block_input.items);
    defer block_tokens.deinit();

    var block_events = try parseTokens(std.testing.allocator, block_tokens.tokens);
    defer block_events.deinit();

    try std.testing.expect(block_events.events[3] == .scalar);
    try std.testing.expectEqual(@as(usize, 1024), block_events.events[3].scalar.value.len);

    var flow_input: std.ArrayList(u8) = .empty;
    defer flow_input.deinit(std.testing.allocator);
    try flow_input.append(std.testing.allocator, '{');
    try flow_input.appendNTimes(std.testing.allocator, 'a', 1024);
    try flow_input.appendSlice(std.testing.allocator, ": value}\n");

    var flow_tokens = try scanner.scan(std.testing.allocator, flow_input.items);
    defer flow_tokens.deinit();

    var flow_events = try parseTokens(std.testing.allocator, flow_tokens.tokens);
    defer flow_events.deinit();

    try std.testing.expect(flow_events.events[3] == .scalar);
    try std.testing.expectEqual(@as(usize, 1024), flow_events.events[3].scalar.value.len);
}

test "parseTokens rejects block sequence indicators on the same line as mapping values" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\key: - a
        \\     - b
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects flow entries that start with an invalid comment" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\[ a, b, c,#invalid
        \\]
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects flow indicators in anchor and alias names" {
    try expectInvalidSyntaxFromScanOrParse("&bad, value\n");
    try expectInvalidSyntaxFromScanOrParse("&bad[ value\n");
    try expectInvalidSyntaxFromScanOrParse("&bad[]\n");
    try expectInvalidSyntaxFromScanOrParse("&bad{}\n");
    try expectInvalidSyntaxFromScanOrParse("*bad{name}\n");
}

test "parseTokens rejects empty flow mapping entries" {
    var double_comma_tokens = try scanner.scan(std.testing.allocator, "{a: b,, c: d}\n");
    defer double_comma_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, double_comma_tokens.tokens));

    var leading_comma_tokens = try scanner.scan(std.testing.allocator, "{, a: b}\n");
    defer leading_comma_tokens.deinit();
    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, leading_comma_tokens.tokens));
}

test "parseTokens rejects tab-indented flow sequence content in block sequences" {
    const input = "- [\n" ++
        "\tfoo,\n" ++
        " foo\n" ++
        " ]\n";
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects tab-separated compact mappings in explicit values" {
    var token_stream = try scanner.scan(std.testing.allocator, "? key:\n:\tkey:\n");
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses recursive block mapping value collections" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\root:
        \\  child:
        \\    items:
        \\      - one
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("root", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("child", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .mapping_start);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_start);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .sequence_end);
    try std.testing.expect(event_stream.events[11] == .mapping_end);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .mapping_end);
    try std.testing.expect(event_stream.events[14] == .document_end);
    try std.testing.expect(event_stream.events[15] == .stream_end);
}

test "parseTokens parses flow collection values in block mappings" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\items: [one, two]
        \\meta: {enabled: true}
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 16), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("items", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[4].sequence_start.style);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("one", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqualStrings("two", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
    try std.testing.expect(event_stream.events[8] == .scalar);
    try std.testing.expectEqualStrings("meta", event_stream.events[8].scalar.value);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[9].mapping_start.style);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("enabled", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("true", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .mapping_end);
    try std.testing.expect(event_stream.events[13] == .mapping_end);
    try std.testing.expect(event_stream.events[14] == .document_end);
    try std.testing.expect(event_stream.events[15] == .stream_end);
}

test "parseTokens parses indented flow sequence mapping values" {
    const input =
        "  # Leading comment line spaces are\n" ++
        "   # neither content nor indentation.\n" ++
        "    \n" ++
        "Not indented:\n" ++
        " By one space: |\n" ++
        "    By four\n" ++
        "      spaces\n" ++
        " Flow style: [    # Leading spaces\n" ++
        "   By two,        # in flow style\n" ++
        "  Also by two,    # are neither\n" ++
        "  \tStill by two   # content nor\n" ++
        "    ]             # indentation.\n";
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 17), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .mapping_start);
    try std.testing.expect(event_stream.events[3] == .scalar);
    try std.testing.expectEqualStrings("Not indented", event_stream.events[3].scalar.value);
    try std.testing.expect(event_stream.events[4] == .mapping_start);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("By one space", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[6].scalar.style);
    try std.testing.expectEqualStrings("By four\n  spaces\n", event_stream.events[6].scalar.value);
    try std.testing.expect(event_stream.events[7] == .scalar);
    try std.testing.expectEqualStrings("Flow style", event_stream.events[7].scalar.value);
    try std.testing.expect(event_stream.events[8] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, event_stream.events[8].sequence_start.style);
    try std.testing.expect(event_stream.events[9] == .scalar);
    try std.testing.expectEqualStrings("By two", event_stream.events[9].scalar.value);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("Also by two", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .scalar);
    try std.testing.expectEqualStrings("Still by two", event_stream.events[11].scalar.value);
    try std.testing.expect(event_stream.events[12] == .sequence_end);
    try std.testing.expect(event_stream.events[13] == .mapping_end);
    try std.testing.expect(event_stream.events[14] == .mapping_end);
    try std.testing.expect(event_stream.events[15] == .document_end);
    try std.testing.expect(event_stream.events[16] == .stream_end);
}

test "parseTokens rejects tab-indented block scalar content" {
    var token_stream = try scanner.scan(std.testing.allocator, "foo: |\n\t\nbar: 1\n");
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}
