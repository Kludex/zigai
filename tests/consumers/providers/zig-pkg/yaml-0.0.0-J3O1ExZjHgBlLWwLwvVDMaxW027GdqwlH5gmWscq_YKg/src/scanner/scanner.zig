//! Purpose: Tokenize YAML presentation bytes into scanner tokens.
//! Owns: Scanner state machine and token emission.
//! Does not own: Token type definitions, parser grammar, or schema resolution.
//! Depends on: reader/reader.zig, scanner/token.zig, scanner/lex.zig, scanner feature modules.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const block_scalar = @import("block_scalar.zig");
const lex = @import("lex.zig");
const property = @import("property.zig");
const reader = @import("../reader/reader.zig");
const scalar = @import("scalar.zig");
const token = @import("token.zig");

pub const Token = token.Token;
pub const DocumentStartContent = token.DocumentStartContent;
pub const BlockScalarStyle = token.BlockScalarStyle;
pub const BlockScalarChomping = token.BlockScalarChomping;
pub const BlockScalar = token.BlockScalar;
pub const Error = token.Error;
pub const TokenStream = token.TokenStream;

const consumeLineBreak = lex.consumeLineBreak;
const isCommentStart = lex.isCommentStart;
const isLineBreakByte = lex.isLineBreakByte;
const isMappingSeparatorAt = lex.isMappingSeparatorAt;
const isSeparatedIndicatorAt = lex.isSeparatedIndicatorAt;
const lineAt = lex.lineAt;

const min_preallocated_input_bytes: usize = 1024;
const token_capacity_input_divisor: usize = 4;
const max_initial_token_capacity: usize = 8 * 1024;

/// Tokenizes a YAML byte stream into lexical tokens.
///
/// UTF-8 input is borrowed for the lifetime of the returned `TokenStream`.
/// UTF-16 and UTF-32 inputs are decoded into storage owned by the stream.
pub fn scan(allocator: std.mem.Allocator, input: []const u8) Error!TokenStream {
    var source = try reader.prepare(allocator, input);
    errdefer source.deinit();
    const arena_allocator = source.allocator();
    const utf8_input = source.bytes;

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(arena_allocator);

    if (initialTokenCapacity(utf8_input.len)) |capacity| {
        try tokens.ensureTotalCapacity(arena_allocator, capacity);
    }

    try tokens.append(arena_allocator, .stream_start);

    var scanner_state: Scanner = .{
        .input = utf8_input,
        .allocator = arena_allocator,
        .tokens = &tokens,
    };
    try scanner_state.scan();

    try tokens.append(arena_allocator, .stream_end);

    const owned_tokens = try tokens.toOwnedSlice(arena_allocator);
    return .{
        .arena = source.releaseArena(),
        .source = utf8_input,
        .tokens = owned_tokens,
    };
}

const Scanner = struct {
    input: []const u8,
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    index: usize = 0,
    line_start: bool = true,
    line_content_start: usize = 0,
    square_depth: usize = 0,
    curly_depth: usize = 0,
    document_prefix: bool = true,

    fn scan(self: *Scanner) Error!void {
        while (self.index < self.input.len) {
            if (isLineBreakByte(self.input[self.index])) {
                self.index = consumeLineBreak(self.input, self.index);
                self.line_start = true;
                continue;
            }

            if (self.line_start) {
                try scanLinePrefix(self);
                continue;
            }

            const byte = self.input[self.index];
            switch (byte) {
                ' ', '\t' => self.index += 1,
                '#' => {
                    if (isCommentStart(self.input, self.index)) {
                        try appendComment(self);
                    } else {
                        try appendScalar(self);
                    }
                },
                '[' => try appendFlowSequenceStart(self),
                ']' => try appendFlowSequenceEnd(self),
                '{' => try appendFlowMappingStart(self),
                '}' => try appendFlowMappingEnd(self),
                ',' => {
                    if (!(try appendFlowEntry(self))) {
                        try appendScalar(self);
                    }
                },
                ':' => {
                    if (!(try appendMappingValue(self))) {
                        try appendScalar(self);
                    }
                },
                '&' => try appendAnchor(self),
                '*' => try appendAlias(self),
                '!' => try appendTag(self),
                '\'', '"' => {
                    if (self.quoteStartsPlainScalarContinuation(byte)) {
                        try appendScalar(self);
                    } else {
                        const value = try scalar.readQuotedScalar(self.input, &self.index, byte);
                        try self.tokens.append(self.allocator, .{ .scalar = value });
                    }
                },
                '|', '>' => {
                    if (!block_scalar.indicatorStartsNode(self.tokens.items, self.index, self.line_content_start, flowDepth(self))) {
                        try appendScalar(self);
                        continue;
                    }
                    const value = try block_scalar.readBlockScalar(self.input, &self.index, self.line_content_start, self.tokens.items, flowDepth(self), byte);
                    self.line_start = true;
                    try self.tokens.append(self.allocator, .{ .block_scalar = value });
                },
                '-' => {
                    if (self.index == self.line_content_start and isSeparatedIndicatorAt(self.input, self.index, 1)) {
                        try self.tokens.append(self.allocator, .block_sequence_entry);
                        self.index += 1;
                    } else if (try consumeCompactBlockSequenceEntry(self)) {
                        try self.tokens.append(self.allocator, .block_sequence_entry);
                    } else {
                        try appendScalar(self);
                    }
                },
                '?' => {
                    if (isExplicitMappingKeyIndicator(self)) {
                        if (explicitMappingKeyHasTabbedNestedNode(self)) return error.InvalidSyntax;
                        try self.tokens.append(self.allocator, if (flowDepth(self) == 0) .block_mapping_key else .flow_mapping_key);
                        self.index += 1;
                    } else {
                        try appendScalar(self);
                    }
                },
                else => try appendScalar(self),
            }
        }

        if (self.square_depth != 0 or self.curly_depth != 0) return error.InvalidSyntax;
    }

    fn quoteStartsPlainScalarContinuation(self: *const Scanner, quote: u8) bool {
        if (self.index == self.line_content_start and self.lineStartQuoteHasMappingValueAfter(quote)) {
            return false;
        }

        var cursor = self.tokens.items.len;
        while (cursor > 0) {
            cursor -= 1;
            switch (self.tokens.items[cursor]) {
                .stream_start => continue,
                .comment, .indent => continue,
                .anchor, .alias, .tag => continue,
                .scalar => |value| {
                    if (std.mem.eql(u8, value, "?") and block_scalar.compactSequenceExplicitKeyParentIndent(self.tokens.items, 0) != null) {
                        return false;
                    }
                    return true;
                },
                else => return false,
            }
        }
        return false;
    }

    fn lineStartQuoteHasMappingValueAfter(self: *const Scanner, quote: u8) bool {
        const line = lineAt(self.input, self.index);
        var cursor = self.index + 1;
        while (cursor < line.end) : (cursor += 1) {
            const byte = self.input[cursor];
            if (quote == '\'' and byte == '\'' and cursor + 1 < line.end and self.input[cursor + 1] == '\'') {
                cursor += 1;
                continue;
            }
            if (quote == '"' and byte == '\\' and cursor + 1 < line.end) {
                cursor += 1;
                continue;
            }
            if (byte != quote) continue;

            const after_quote = cursor + 1;
            return after_quote < line.end and
                self.input[after_quote] == ':' and
                isMappingSeparatorAt(self.input, after_quote, flowDepth(self) != 0);
        }
        return false;
    }
};

fn scanLinePrefix(scanner: anytype) Error!void {
    const start = scanner.index;
    if (std.mem.startsWith(u8, scanner.input[start..], lex.utf8_bom)) {
        if (!scanner.document_prefix) return error.InvalidSyntax;
        scanner.index += lex.utf8_bom.len;
        return;
    }

    var cursor = scanner.index;
    while (cursor < scanner.input.len and (scanner.input[cursor] == ' ' or scanner.input[cursor] == '\t')) : (cursor += 1) {}

    if (cursor >= scanner.input.len) {
        scanner.index = cursor;
        return;
    }

    if (lex.isLineBreakByte(scanner.input[cursor])) {
        scanner.index = cursor;
        return;
    }

    if (scanner.input[cursor] == '#') {
        scanner.index = cursor;
        scanner.line_start = false;
        try appendComment(scanner);
        return;
    }

    if (flowDepth(scanner) == 0 and std.mem.indexOfScalar(u8, scanner.input[start..cursor], '\t') != null) {
        if (lex.startsBlockIndentedStructure(scanner.input, cursor) or
            tabWouldIndentSeparatedFlowNode(scanner, cursor))
        {
            return error.InvalidSyntax;
        }
    }

    if (flowDepth(scanner) == 0 and cursor == start and scanner.input[cursor] == '%' and scanner.document_prefix) {
        try appendDirective(scanner);
        return;
    }

    if (cursor == start and lex.startsDocumentMarker(scanner.input[cursor..], "---")) {
        try scanner.tokens.append(scanner.allocator, .document_start);
        try appendDocumentStartContent(scanner, cursor + 3);
        scanner.index = cursor + 3;
        scanner.line_start = false;
        scanner.document_prefix = false;
        return;
    }

    if (cursor == start and lex.startsDocumentMarker(scanner.input[cursor..], "...")) {
        try scanner.tokens.append(scanner.allocator, .document_end);
        scanner.index = cursor + 3;
        scanner.line_start = false;
        scanner.document_prefix = true;
        return;
    }

    scanner.line_start = false;
    scanner.line_content_start = cursor;
    scanner.document_prefix = false;
    try scanner.tokens.append(scanner.allocator, .{ .indent = lex.countIndentSpaces(scanner.input[start..cursor]) });
    scanner.index = cursor;
}

fn appendComment(scanner: anytype) Error!void {
    const line = lex.lineAt(scanner.input, scanner.index);
    const body = std.mem.trim(u8, scanner.input[scanner.index + 1 .. line.end], " \t\r");
    try scanner.tokens.append(scanner.allocator, .{ .comment = body });
    scanner.index = line.end;
}

fn appendDirective(scanner: anytype) Error!void {
    const line = lex.lineAt(scanner.input, scanner.index);
    const raw = std.mem.trim(u8, lex.stripLineComment(scanner.input[scanner.index..line.end]), " \t\r");
    if (raw.len == 0) return error.InvalidSyntax;
    try scanner.tokens.append(scanner.allocator, .{ .directive = raw });
    scanner.index = line.next;
    scanner.line_start = true;
}

fn appendDocumentStartContent(scanner: anytype, marker_end: usize) Error!void {
    const line = lex.lineAt(scanner.input, marker_end);
    var content_start = marker_end;
    while (content_start < line.end and (scanner.input[content_start] == ' ' or scanner.input[content_start] == '\t')) : (content_start += 1) {}
    if (content_start >= line.end or scanner.input[content_start] == '#') return;

    scanner.line_content_start = content_start;
    try scanner.tokens.append(scanner.allocator, .{ .document_start_content = .{
        .separated_by_tab = std.mem.indexOfScalar(u8, scanner.input[marker_end..content_start], '\t') != null,
    } });
}

fn appendScalar(scanner: anytype) Error!void {
    const value = try scalar.readPlainScalar(scanner.input, &scanner.index, flowDepth(scanner));
    try scanner.tokens.append(scanner.allocator, .{ .scalar = value });
}

fn tabWouldIndentSeparatedFlowNode(scanner: anytype, cursor: usize) bool {
    if (!lex.isFlowStartIndicator(scanner.input[cursor])) return false;

    var index = scanner.tokens.items.len;
    while (index > 0) {
        index -= 1;
        switch (scanner.tokens.items[index]) {
            .comment => continue,
            .block_sequence_entry, .block_mapping_key, .block_mapping_value => return true,
            else => return false,
        }
    }
    return false;
}

fn appendFlowSequenceStart(scanner: anytype) Error!void {
    scanner.square_depth += 1;
    try scanner.tokens.append(scanner.allocator, .flow_sequence_start);
    scanner.index += 1;
}

fn appendFlowSequenceEnd(scanner: anytype) Error!void {
    if (scanner.square_depth == 0) return error.InvalidSyntax;
    scanner.square_depth -= 1;
    try scanner.tokens.append(scanner.allocator, .flow_sequence_end);
    scanner.index += 1;
}

fn appendFlowMappingStart(scanner: anytype) Error!void {
    scanner.curly_depth += 1;
    try scanner.tokens.append(scanner.allocator, .flow_mapping_start);
    scanner.index += 1;
}

fn appendFlowMappingEnd(scanner: anytype) Error!void {
    if (scanner.curly_depth == 0) return error.InvalidSyntax;
    scanner.curly_depth -= 1;
    try scanner.tokens.append(scanner.allocator, .flow_mapping_end);
    scanner.index += 1;
}

fn appendFlowEntry(scanner: anytype) Error!bool {
    if (flowDepth(scanner) == 0) return false;
    try scanner.tokens.append(scanner.allocator, .flow_entry);
    scanner.index += 1;
    return true;
}

fn appendMappingValue(scanner: anytype) Error!bool {
    if (!colonStartsMappingValue(scanner)) return false;
    try scanner.tokens.append(scanner.allocator, if (flowDepth(scanner) == 0) .block_mapping_value else .flow_mapping_value);
    scanner.index += 1;
    return true;
}

fn appendAnchor(scanner: anytype) Error!void {
    const value = try property.readName(scanner.input, &scanner.index, 1);
    try scanner.tokens.append(scanner.allocator, .{ .anchor = value });
}

fn appendAlias(scanner: anytype) Error!void {
    const value = try property.readName(scanner.input, &scanner.index, 1);
    try scanner.tokens.append(scanner.allocator, .{ .alias = value });
}

fn appendTag(scanner: anytype) Error!void {
    const value = try property.readTag(scanner.input, &scanner.index);
    try scanner.tokens.append(scanner.allocator, .{ .tag = value });
}

fn consumeCompactBlockSequenceEntry(scanner: anytype) Error!bool {
    if (flowDepth(scanner) != 0) return false;
    if (!lex.isSeparatedIndicatorAt(scanner.input, scanner.index, 1)) return false;
    if (scanner.index <= scanner.line_content_start) return false;
    if (scanner.tokens.items.len == 0) return false;

    if (!compactBlockSequenceContextAllowsEntry(scanner)) return false;

    const previous = lex.previousNonWhitespaceIndex(scanner.input, scanner.index) orelse return false;
    if (std.mem.indexOfScalar(u8, scanner.input[previous + 1 .. scanner.index], '\t') != null) {
        return error.InvalidSyntax;
    }

    scanner.index += 1;
    return true;
}

fn isExplicitMappingKeyIndicator(scanner: anytype) bool {
    if (!lex.isSeparatedIndicatorAt(scanner.input, scanner.index, 1)) return false;
    if (flowDepth(scanner) == 0) return scanner.index == scanner.line_content_start;

    const previous = lex.previousNonWhitespaceByte(scanner.input, scanner.index) orelse return false;
    return previous == '[' or previous == '{' or previous == ',';
}

fn explicitMappingKeyHasTabbedNestedNode(scanner: anytype) bool {
    if (flowDepth(scanner) != 0 or scanner.index != scanner.line_content_start) return false;

    var cursor = scanner.index + 1;
    var saw_tab = false;
    while (cursor < scanner.input.len and (scanner.input[cursor] == ' ' or scanner.input[cursor] == '\t')) : (cursor += 1) {
        saw_tab = saw_tab or scanner.input[cursor] == '\t';
    }
    if (!saw_tab or cursor >= scanner.input.len or lex.isLineBreakByte(scanner.input[cursor])) return false;
    if (scanner.input[cursor] == '#' and lex.isCommentStart(scanner.input, cursor)) return false;

    if (scanner.input[cursor] == '-' and lex.isSeparatedIndicatorAt(scanner.input, cursor, 1)) return true;
    if (scanner.input[cursor] == '?' and lex.isSeparatedIndicatorAt(scanner.input, cursor, 1)) return true;

    const line = lex.lineAt(scanner.input, cursor);
    while (cursor < line.end) : (cursor += 1) {
        if (scanner.input[cursor] == '#' and lex.isCommentStart(scanner.input, cursor)) return false;
        if (scanner.input[cursor] == ':' and lex.isMappingSeparatorAt(scanner.input, cursor, false)) return true;
    }
    return false;
}

fn flowDepth(scanner: anytype) usize {
    return scanner.square_depth + scanner.curly_depth;
}

fn initialTokenCapacity(input_len: usize) ?usize {
    if (input_len < min_preallocated_input_bytes) return null;
    return @min(max_initial_token_capacity, input_len / token_capacity_input_divisor);
}

fn colonStartsMappingValue(scanner: anytype) bool {
    const in_flow = flowDepth(scanner) != 0;
    if (lex.isMappingSeparatorAt(scanner.input, scanner.index, in_flow)) return true;
    if (!in_flow) return false;
    return previousTokenAllowsAdjacentFlowValue(scanner);
}

fn previousTokenAllowsAdjacentFlowValue(scanner: anytype) bool {
    var cursor = scanner.tokens.items.len;
    while (cursor > 0) {
        cursor -= 1;
        switch (scanner.tokens.items[cursor]) {
            .comment, .indent => continue,
            .scalar => |value| return value.len > 0 and (value[0] == '\'' or value[0] == '"'),
            .flow_sequence_end, .flow_mapping_end => return true,
            else => return false,
        }
    }
    return false;
}

fn compactBlockSequenceContextAllowsEntry(scanner: anytype) bool {
    var cursor = scanner.tokens.items.len;
    while (cursor > 0) {
        cursor -= 1;
        switch (scanner.tokens.items[cursor]) {
            .anchor, .tag => continue,
            .block_sequence_entry,
            .block_mapping_key,
            .block_mapping_value,
            => return true,
            else => return false,
        }
    }
    return false;
}

test "scanner line: tab-separated flow node without prior structural token is not indentation" {
    var tokens: std.ArrayList(token.Token) = .empty;
    defer tokens.deinit(std.testing.allocator);

    const ScannerState = struct {
        input: []const u8,
        tokens: *std.ArrayList(token.Token),
    };
    var scanner: ScannerState = .{
        .input = "\t[]",
        .tokens = &tokens,
    };

    try std.testing.expect(!tabWouldIndentSeparatedFlowNode(&scanner, 1));
}

test "scanner indicator: adjacent flow value requires previous content token" {
    const FakeScanner = struct {
        allocator: std.mem.Allocator,
        input: []const u8,
        index: usize,
        line_content_start: usize = 0,
        square_depth: usize = 0,
        curly_depth: usize = 0,
        tokens: std.ArrayList(token.Token) = .empty,

        fn deinit(self: *@This()) void {
            self.tokens.deinit(self.allocator);
        }
    };

    var fake = FakeScanner{
        .allocator = std.testing.allocator,
        .input = ":value",
        .index = 0,
        .square_depth = 1,
    };
    defer fake.deinit();

    try std.testing.expect(!try appendMappingValue(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.index);
    try std.testing.expectEqual(@as(usize, 0), fake.tokens.items.len);
}

test "scanner indicator: compact sequence entry requires structural context after properties" {
    const FakeScanner = struct {
        allocator: std.mem.Allocator,
        input: []const u8,
        index: usize,
        line_content_start: usize = 0,
        square_depth: usize = 0,
        curly_depth: usize = 0,
        tokens: std.ArrayList(token.Token) = .empty,

        fn deinit(self: *@This()) void {
            self.tokens.deinit(self.allocator);
        }
    };

    var fake = FakeScanner{
        .allocator = std.testing.allocator,
        .input = "a -",
        .index = 2,
    };
    defer fake.deinit();

    try fake.tokens.append(fake.allocator, .{ .anchor = "a" });
    try fake.tokens.append(fake.allocator, .{ .tag = "!t" });

    try std.testing.expect(!try consumeCompactBlockSequenceEntry(&fake));
    try std.testing.expectEqual(@as(usize, 2), fake.index);
    try std.testing.expectEqual(@as(usize, 2), fake.tokens.items.len);
}

test "scanner token capacity estimate stays conservative" {
    try std.testing.expectEqual(@as(?usize, null), initialTokenCapacity(97));
    try std.testing.expectEqual(@as(?usize, 7509), initialTokenCapacity(30_036));
    try std.testing.expectEqual(@as(?usize, 8192), initialTokenCapacity(1_000_000));
}
