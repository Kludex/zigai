//! Purpose: Share parser-internal block node, property, and block helper code.
//! Owns: Block node shapes, node properties, and helpers shared by block mapping and sequence parsing.
//! Does not own: Top-level parser dispatch, scalar parsing, flow parsing internals, or scanner state.
//! Depends on: parser/tag.zig, parser/scalar.zig, parser/flow.zig, scanner/scanner.zig, parser/event.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const tag_resolver = @import("tag.zig");
const scalar_parser = @import("scalar.zig");
const flow = @import("flow.zig");
const scanner = @import("../scanner/scanner.zig");
const types = @import("event.zig");

const Error = types.Error;
const Event = types.Event;
const ParseError = types.ParseError;
const isPlainScalarContinuationToken = scalar_parser.isPlainScalarContinuationToken;
const scalarStartsAdjacentToPropertyIndicator = scalar_parser.scalarStartsAdjacentToPropertyIndicator;
const scalarTokenSpansLines = scalar_parser.scalarTokenSpansLines;
const max_implicit_key_codepoints: usize = 1024;

pub const EventStats = struct {
    event_count: usize = 0,
    max_scalar_bytes: usize = 0,
    max_nesting_depth: usize = 0,
    current_nesting_depth: usize = 0,
    malformed_nesting: bool = false,

    pub fn observe(self: *EventStats, event: Event) void {
        self.event_count += 1;
        switch (event) {
            .scalar => |scalar| self.max_scalar_bytes = @max(self.max_scalar_bytes, scalar.value.len),
            .sequence_start, .mapping_start => {
                self.current_nesting_depth += 1;
                self.max_nesting_depth = @max(self.max_nesting_depth, self.current_nesting_depth);
            },
            .sequence_end, .mapping_end => {
                if (self.current_nesting_depth == 0) {
                    self.malformed_nesting = true;
                } else {
                    self.current_nesting_depth -= 1;
                }
            },
            else => {},
        }
    }

    pub fn observeSlice(self: *EventStats, events: []const Event) void {
        for (events) |event| self.observe(event);
    }
};

pub const EventBuilder = struct {
    list: std.ArrayList(Event) = .empty,
    stats: EventStats = .{},

    pub const Checkpoint = struct {
        len: usize,
        stats: EventStats,
    };

    pub fn deinit(self: *EventBuilder, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.* = .{};
    }

    pub fn checkpoint(self: *const EventBuilder) Checkpoint {
        return .{ .len = self.list.items.len, .stats = self.stats };
    }

    pub fn rollback(self: *EventBuilder, saved: Checkpoint) void {
        std.debug.assert(saved.len <= self.list.items.len);
        self.list.items.len = saved.len;
        self.stats = saved.stats;
    }

    pub fn ensureTotalCapacity(self: *EventBuilder, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
        try self.list.ensureTotalCapacity(allocator, capacity);
    }

    pub fn append(self: *EventBuilder, allocator: std.mem.Allocator, event: Event) std.mem.Allocator.Error!void {
        try self.list.append(allocator, event);
        self.stats.observe(event);
    }

    pub fn appendSlice(self: *EventBuilder, allocator: std.mem.Allocator, events: []const Event) std.mem.Allocator.Error!void {
        try self.list.appendSlice(allocator, events);
        self.stats.observeSlice(events);
    }

    pub fn insert(self: *EventBuilder, allocator: std.mem.Allocator, index: usize, event: Event) std.mem.Allocator.Error!void {
        try self.list.insert(allocator, index, event);
        self.recomputeStats();
    }

    pub fn toOwnedSlice(self: *EventBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const Event {
        return self.list.toOwnedSlice(allocator);
    }

    pub fn slice(self: *const EventBuilder) []const Event {
        return self.list.items;
    }

    fn recomputeStats(self: *EventBuilder) void {
        self.stats = .{};
        self.stats.observeSlice(self.list.items);
    }
};

test "event builder tracks event stats while appending" {
    var builder: EventBuilder = .{};
    defer builder.deinit(std.testing.allocator);

    try builder.append(std.testing.allocator, .stream_start);
    try builder.append(std.testing.allocator, .{ .document_start = .{} });
    try builder.append(std.testing.allocator, .{ .sequence_start = .{ .style = .flow } });
    try builder.append(std.testing.allocator, .{ .mapping_start = .{ .style = .flow } });
    try builder.append(std.testing.allocator, .{ .scalar = .{ .value = "abcd" } });
    try builder.append(std.testing.allocator, .mapping_end);
    try builder.append(std.testing.allocator, .sequence_end);

    try std.testing.expectEqual(@as(usize, 7), builder.stats.event_count);
    try std.testing.expectEqual(@as(usize, 4), builder.stats.max_scalar_bytes);
    try std.testing.expectEqual(@as(usize, 2), builder.stats.max_nesting_depth);
    try std.testing.expectEqual(@as(usize, 0), builder.stats.current_nesting_depth);
    try std.testing.expect(!builder.stats.malformed_nesting);
}

test "event builder rollback restores events and stats" {
    var builder: EventBuilder = .{};
    defer builder.deinit(std.testing.allocator);

    try builder.append(std.testing.allocator, .stream_start);
    try builder.append(std.testing.allocator, .{ .sequence_start = .{ .style = .flow } });
    try builder.append(std.testing.allocator, .{ .scalar = .{ .value = "kept" } });
    const checkpoint = builder.checkpoint();

    try builder.append(std.testing.allocator, .{ .mapping_start = .{ .style = .flow } });
    try builder.append(std.testing.allocator, .{ .scalar = .{ .value = "discarded" } });
    try builder.append(std.testing.allocator, .mapping_end);
    builder.rollback(checkpoint);

    try std.testing.expectEqual(@as(usize, 3), builder.slice().len);
    try std.testing.expectEqual(@as(usize, 3), builder.stats.event_count);
    try std.testing.expectEqual(@as(usize, 4), builder.stats.max_scalar_bytes);
    try std.testing.expectEqual(@as(usize, 1), builder.stats.current_nesting_depth);
}

pub const Line = struct {
    start: usize,
    end: usize,
    next: usize,
};

pub const DocumentStartContent = struct {
    content_same_line: bool = false,
    separated_by_tab: bool = false,
};

pub fn sourceRange(first: []const u8, last: []const u8) ?[]const u8 {
    const start = @intFromPtr(first.ptr);
    const last_start = @intFromPtr(last.ptr);
    if (last_start < start) return null;
    const len = last_start - start + last.len;
    const ptr: [*]const u8 = @ptrFromInt(start);
    return ptr[0..len];
}

pub fn lineAt(input: []const u8, start: usize) Line {
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

pub fn containsLineBreak(input: []const u8) bool {
    for (input) |byte| {
        if (isLineBreakByte(byte)) return true;
    }
    return false;
}

pub fn isLineBreakByte(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

pub fn leadingSpaces(input: []const u8) usize {
    var count: usize = 0;
    while (count < input.len and input[count] == ' ') : (count += 1) {}
    return count;
}

pub fn skipHorizontalWhitespace(input: []const u8, start: usize, end: usize) usize {
    var index = start;
    while (index < end and (input[index] == ' ' or input[index] == '\t')) : (index += 1) {}
    return index;
}

pub fn consumeLineBreak(input: []const u8, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    return switch (input[start]) {
        '\n' => start + 1,
        '\r' => if (start + 1 < end and input[start + 1] == '\n') start + 2 else start + 1,
        else => null,
    };
}

pub fn consumeDocumentStartContent(tokens: []const scanner.Token, index: *usize, end: usize) DocumentStartContent {
    if (index.* >= end) return .{};
    return switch (tokens[index.*]) {
        .document_start_content => |content| value: {
            index.* += 1;
            break :value .{
                .content_same_line = true,
                .separated_by_tab = content.separated_by_tab,
            };
        },
        else => .{},
    };
}

pub fn skipComments(tokens: []const scanner.Token, index: *usize, end: usize) void {
    while (index.* < end and tokens[index.*] == .comment) {
        index.* += 1;
    }
}

pub fn skipFlowInsignificant(tokens: []const scanner.Token, index: *usize, end: usize) void {
    while (index.* < end) {
        switch (tokens[index.*]) {
            .comment, .indent => index.* += 1,
            else => return,
        }
    }
}

pub fn flowCollectionDescendantSpansLines(tokens: []const scanner.Token) bool {
    var depth: usize = 0;
    for (tokens) |token| {
        switch (token) {
            .flow_sequence_start, .flow_mapping_start => depth += 1,
            .flow_sequence_end, .flow_mapping_end => if (depth > 0) {
                depth -= 1;
            },
            .indent => if (depth > 0) {
                return true;
            },
            else => {},
        }
    }
    return false;
}

pub fn flowCollectionAtStartSpansLines(tokens: []const scanner.Token, start: usize, end: usize) bool {
    if (start >= end or !isFlowStartToken(tokens[start])) return false;

    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .flow_sequence_start, .flow_mapping_start => depth += 1,
            .flow_sequence_end, .flow_mapping_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return false;
            },
            .indent => if (depth > 0) return true,
            else => {},
        }
    }

    return false;
}

pub fn validateFlowContinuationIndent(tokens: []const scanner.Token, start: usize, end: usize, parent_indent: usize) Error!void {
    if (start >= end or !isFlowStartToken(tokens[start])) return;

    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .flow_sequence_start, .flow_mapping_start => depth += 1,
            .flow_sequence_end, .flow_mapping_end => {
                if (depth == 0) return ParseError.InvalidSyntax;
                depth -= 1;
                if (depth == 0) return;
            },
            .indent => |indent| {
                if (depth > 0 and indent <= parent_indent) return ParseError.InvalidSyntax;
            },
            else => {},
        }
    }

    return ParseError.InvalidSyntax;
}

pub fn isFlowStartToken(token: scanner.Token) bool {
    return token == .flow_sequence_start or token == .flow_mapping_start;
}

pub fn validateAliasFlowCollectionSeparation(tokens: []const scanner.Token) ParseError!void {
    if (tokens.len < 2) return;

    for (tokens[0 .. tokens.len - 1], 0..) |token, index| {
        if (token == .alias and isFlowStartToken(tokens[index + 1])) return ParseError.InvalidSyntax;
    }
}

pub fn aliasDocumentHasTrailingContent(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment, .indent => {},
            .document_start, .document_end => return false,
            .scalar,
            .alias,
            .anchor,
            .tag,
            .block_scalar,
            .block_sequence_entry,
            .block_mapping_key,
            .block_mapping_value,
            .flow_sequence_start,
            .flow_mapping_start,
            => return true,
            else => return false,
        }
    }

    return false;
}

pub fn isPlainBlockOmittedValueBoundary(tokens: []const scanner.Token, index: usize, end: usize) bool {
    return isPlainBlockOmittedValueBoundaryAtIndent(tokens, index, end, 0);
}

pub fn isPlainBlockOmittedValueBoundaryAtIndent(tokens: []const scanner.Token, index: usize, end: usize, collection_indent: usize) bool {
    if (index >= end) return true;
    return switch (tokens[index]) {
        .document_end => true,
        .indent => |indent| indent <= collection_indent,
        else => false,
    };
}

pub fn isExplicitBlockMappingValueBoundary(tokens: []const scanner.Token, index: usize, end: usize, key_indent: usize) bool {
    return index + 1 < end and
        tokens[index] == .indent and
        tokens[index].indent == key_indent and
        tokens[index + 1] == .block_mapping_value;
}

pub fn isFlowSequenceEntryBoundary(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index >= end) return false;
    return tokens[index] == .flow_entry or tokens[index] == .flow_sequence_end;
}

pub fn isFlowMappingEmptyValueBoundary(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index >= end) return false;
    return tokens[index] == .flow_entry or tokens[index] == .flow_mapping_end;
}

pub fn flowEmptyScalarBoundaryIndex(tokens: []const scanner.Token, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment, .indent => {},
            else => break,
        }
    }
    if (index >= end) return null;

    return switch (tokens[index]) {
        .flow_entry, .flow_sequence_end, .flow_mapping_value, .flow_mapping_end => index,
        else => null,
    };
}

pub fn validateFlowAliasHasNoFollowingContent(tokens: []const scanner.Token, start: usize, end: usize) ParseError!void {
    var index = start;
    skipFlowInsignificant(tokens, &index, end);
    if (index >= end) return;

    switch (tokens[index]) {
        .flow_entry,
        .flow_sequence_end,
        .flow_mapping_end,
        .flow_mapping_value,
        => {},
        else => return ParseError.InvalidSyntax,
    }
}

pub fn flowMappingValueFollowsLineBreak(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var index = start;
    var saw_line_break = false;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment => {},
            .indent => saw_line_break = true,
            else => break,
        }
    }

    return saw_line_break and index < end and tokens[index] == .flow_mapping_value;
}

pub fn validateImplicitScalarKeyLength(value: []const u8) ParseError!void {
    try validateImplicitKeySourceLength(std.mem.trimEnd(u8, value, " \t\r\n"));
}

pub fn validateImplicitAliasKeyLength(value: []const u8) ParseError!void {
    try validateImplicitKeySourceLengthWithExtra(value, 1);
}

pub fn validateImplicitTokenKeyLength(tokens: []const scanner.Token, start: usize, stop: usize) ParseError!void {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var first_index: usize = start;
    var last_index: usize = start;

    for (tokens[start..stop], start..) |token, token_index| {
        const source = tokenSourceSlice(token) orelse continue;
        if (first == null) {
            first = source;
            first_index = token_index;
        }
        last = source;
        last_index = token_index;
    }

    const first_source = first orelse {
        try validateImplicitKeyExtraCodepoints(implicitKeyTokenPresentationCodepoints(tokens[start..stop]));
        return;
    };
    const last_source = last orelse return;
    const source = sourceRange(first_source, last_source) orelse return;
    const extra_codepoints =
        implicitKeyTokenPresentationCodepoints(tokens[start..first_index]) +
        implicitKeyTokenLeadingCodepoints(tokens[first_index]) +
        implicitKeyTokenPresentationCodepoints(tokens[last_index + 1 .. stop]);
    try validateImplicitKeySourceLengthWithExtra(std.mem.trimEnd(u8, source, " \t\r\n"), extra_codepoints);
}

pub fn tokenRangeSpansLines(tokens: []const scanner.Token, start: usize, stop: usize) bool {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;

    for (tokens[start..stop]) |token| {
        const source = tokenSourceSlice(token) orelse continue;
        if (first == null) first = source;
        last = source;
    }

    const first_source = first orelse return false;
    const last_source = last orelse return false;
    const source = sourceRange(first_source, last_source) orelse return false;
    return containsLineBreak(source);
}

pub const NodeProperties = struct {
    anchor: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    source_end: ?usize = null,
};

pub const TokenDirectives = struct {
    tag_directives: []const tag_resolver.Directive = &.{},
    yaml_version: ?[]const u8 = null,
    has_reserved_directive: bool = false,
    seen: bool = false,
};

pub const PlainBlockNode = union(enum) {
    scalar: types.Scalar,
    alias: []const u8,
    sequence: PlainBlockSequence,
    mapping: PlainBlockMapping,
    flow_events: []const Event,
};

pub const PlainBlockSequence = struct {
    items: []const PlainBlockNode,
    properties: NodeProperties = .{},
};

pub const PlainBlockPair = struct {
    key: PlainBlockNode,
    value: PlainBlockNode,
};

pub const PlainBlockMapping = struct {
    pairs: []const PlainBlockPair,
    properties: NodeProperties = .{},
};

pub fn has(properties: NodeProperties) bool {
    return properties.anchor != null or properties.tag != null;
}

pub fn merge(target: *NodeProperties, source: NodeProperties) ParseError!void {
    if (source.anchor) |anchor| {
        if (target.anchor != null) return ParseError.InvalidSyntax;
        target.anchor = anchor;
    }
    if (source.tag) |tag| {
        if (target.tag != null) return ParseError.InvalidSyntax;
        target.tag = tag;
    }
    if (source.source_end) |source_end| {
        target.source_end = source_end;
    }
}

pub fn consumeLeadingDirectives(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
) Error!TokenDirectives {
    var tag_directives: std.ArrayList(tag_resolver.Directive) = .empty;
    errdefer tag_directives.deinit(allocator);

    var directives: TokenDirectives = .{};
    while (index.* < end) {
        switch (tokens[index.*]) {
            .comment => index.* += 1,
            .directive => |directive| {
                directives.seen = true;
                try consumeDirectiveToken(allocator, directive, &directives, &tag_directives);
                index.* += 1;
            },
            else => break,
        }
    }

    directives.tag_directives = try tag_directives.toOwnedSlice(allocator);
    return directives;
}

pub fn consumeNodeProperties(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    directives: TokenDirectives,
) Error!NodeProperties {
    var properties: NodeProperties = .{};

    while (index.* < end) {
        switch (tokens[index.*]) {
            .anchor => |anchor| {
                if (properties.anchor != null) return ParseError.InvalidSyntax;
                properties.anchor = try allocator.dupe(u8, anchor);
                properties.source_end = @intFromPtr(anchor.ptr) + anchor.len;
                index.* += 1;
                skipComments(tokens, index, end);
            },
            .tag => |tag_value| {
                if (properties.tag != null) return ParseError.InvalidSyntax;
                properties.tag = try tag_resolver.resolve(allocator, directives.tag_directives, tag_value);
                properties.source_end = @intFromPtr(tag_value.ptr) + tag_value.len;
                index.* += 1;
                skipComments(tokens, index, end);
            },
            else => break,
        }
    }

    return properties;
}

pub fn consumeBlockCollectionProperties(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    directives: TokenDirectives,
) Error!NodeProperties {
    const property_line_start = index.*;
    if (index.* < end and tokens[index.*] == .indent and tokens[index.*].indent == 0) {
        if (index.* + 1 >= end or !isNodePropertyToken(tokens[index.* + 1])) return .{};
        index.* += 1;
    } else if (index.* >= end or !isNodePropertyToken(tokens[index.*])) {
        return .{};
    }

    const properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
    if (index.* < end and tokens[index.*] == .indent) return properties;

    index.* = property_line_start;
    return .{};
}

pub fn consumeTopLevelSeparated(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    directives: TokenDirectives,
) Error!NodeProperties {
    const start = index.*;
    var merged: NodeProperties = .{};
    var saw_separated_property_line = false;

    while (index.* < end) {
        if (saw_separated_property_line and propertyLineStartsBlockMappingPair(tokens, index.*, end)) {
            return merged;
        }

        const line_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        if (!has(line_properties)) break;
        try merge(&merged, line_properties);

        if (index.* < end and tokens[index.*] == .indent and tokens[index.*].indent == 0) {
            saw_separated_property_line = true;
            index.* += 1;
            continue;
        }

        if (saw_separated_property_line) return merged;

        index.* = start;
        return .{};
    }

    if (saw_separated_property_line) return merged;

    index.* = start;
    return .{};
}

pub fn isNodePropertyToken(token: scanner.Token) bool {
    return token == .anchor or token == .tag;
}

pub fn appendEvent(allocator: std.mem.Allocator, events: *EventBuilder, node: PlainBlockNode) Error!void {
    switch (node) {
        .scalar => |scalar| try events.append(allocator, .{ .scalar = scalar }),
        .alias => |alias| try events.append(allocator, .{ .alias = alias }),
        .flow_events => |flow_events| try events.appendSlice(allocator, flow_events),
        .sequence => |sequence| {
            try events.append(allocator, .{ .sequence_start = .{
                .style = .block,
                .anchor = sequence.properties.anchor,
                .tag = sequence.properties.tag,
            } });
            for (sequence.items) |item| {
                try appendEvent(allocator, events, item);
            }
            try events.append(allocator, .sequence_end);
        },
        .mapping => |mapping| {
            try events.append(allocator, .{ .mapping_start = .{
                .style = .block,
                .anchor = mapping.properties.anchor,
                .tag = mapping.properties.tag,
            } });
            for (mapping.pairs) |pair| {
                try appendEvent(allocator, events, pair.key);
                try appendEvent(allocator, events, pair.value);
            }
            try events.append(allocator, .mapping_end);
        },
    }
}

pub fn emptyScalar(allocator: std.mem.Allocator, properties: NodeProperties) Error!PlainBlockNode {
    return .{ .scalar = .{
        .value = try allocator.dupe(u8, ""),
        .anchor = properties.anchor,
        .tag = properties.tag,
    } };
}

pub fn parseFlowPlainBlockNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    const start = index.*;
    var events: EventBuilder = .{};
    defer events.deinit(allocator);
    try events.ensureTotalCapacity(allocator, @min(end - index.*, 16));

    const parsed = if (index.* < end and tokens[index.*] == .flow_sequence_start)
        try flow.appendSequenceNodeEvents(allocator, tokens, index, end, &events, 0, properties, directives)
    else if (index.* < end and tokens[index.*] == .flow_mapping_start)
        try flow.appendMappingNodeEvents(allocator, tokens, index, end, &events, 0, properties, directives)
    else
        false;

    if (!parsed) {
        index.* = start;
        return null;
    }

    return .{ .flow_events = try events.toOwnedSlice(allocator) };
}

pub fn isNestedBlockCollectionStart(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index >= end) return false;
    return switch (tokens[index]) {
        .block_sequence_entry, .block_mapping_key => true,
        .alias => index + 1 < end and tokens[index + 1] == .block_mapping_value,
        .scalar => index + 1 < end and tokens[index + 1] == .block_mapping_value,
        else => false,
    };
}

pub fn validateAliasHasNoFollowingContent(
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    parent_indent: usize,
) ParseError!void {
    var index = start;
    while (index < end) {
        switch (tokens[index]) {
            .comment => index += 1,
            .document_end => return,
            .indent => |indent| {
                if (indent <= parent_indent) return;
                index += 1;
                while (index < end and tokens[index] == .comment) {
                    index += 1;
                }
                if (index >= end or tokens[index] == .document_end) return;
                if (tokens[index] == .indent) continue;
                return ParseError.InvalidSyntax;
            },
            else => return ParseError.InvalidSyntax,
        }
    }
}

pub fn validateExplicitMappingAliasKeyHasNoFollowingContent(
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    key_indent: usize,
) ParseError!void {
    var index = start;
    while (index < end) {
        switch (tokens[index]) {
            .comment => index += 1,
            .block_mapping_value, .document_end => return,
            .indent => |indent| {
                if (indent <= key_indent) return;
                index += 1;
                while (index < end and tokens[index] == .comment) {
                    index += 1;
                }
                if (index >= end or tokens[index] == .document_end) return;
                if (tokens[index] == .indent) continue;
                return ParseError.InvalidSyntax;
            },
            else => return ParseError.InvalidSyntax,
        }
    }
}

pub fn indentlessBlockSequenceStartsAtIndent(tokens: []const scanner.Token, index: usize, end: usize, indent: usize) bool {
    return index + 1 < end and
        tokens[index] == .indent and
        tokens[index].indent == indent and
        tokens[index + 1] == .block_sequence_entry;
}

pub fn nodePropertyLineStartsNestedBlockMappingKey(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var index = start;
    var saw_property = false;
    while (index < end) {
        switch (tokens[index]) {
            .anchor, .tag => {
                saw_property = true;
                index += 1;
                skipComments(tokens, &index, end);
            },
            else => break,
        }
    }

    return saw_property and scalarTokenRunStartsBlockMappingKey(tokens, index, end);
}

pub fn scalarTokenRunStartsBlockMappingKey(tokens: []const scanner.Token, start: usize, end: usize) bool {
    if (start >= end or tokens[start] != .scalar) return false;

    var index = start + 1;
    while (index < end and tokens[index] == .scalar and isPlainScalarContinuationToken(tokens[index].scalar)) {
        index += 1;
    }

    return index < end and tokens[index] == .block_mapping_value;
}

pub fn multilineScalarCandidateHasNoImmediateMappingValue(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index >= end or tokens[index] != .scalar) return false;
    if (!scalarTokenSpansLines(tokens[index].scalar)) return false;

    var after_scalar = index + 1;
    skipComments(tokens, &after_scalar, end);
    return after_scalar >= end or tokens[after_scalar] != .block_mapping_value;
}

pub fn isSingleIndicatorScalarKeyBeforeValue(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index + 1 >= end or tokens[index] != .scalar or tokens[index + 1] != .block_mapping_value) return false;
    const value = tokens[index].scalar;
    if (value.len != 1) return false;
    return value[0] == ':' or value[0] == '?' or value[0] == '-';
}

pub const NestedBlockCollectionPropertyLine = struct {
    properties: NodeProperties,
    indent: usize,
};

pub fn consumeNestedBlockCollectionPropertyLine(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    directives: TokenDirectives,
) Error!?NestedBlockCollectionPropertyLine {
    const start = index.*;
    var properties: NodeProperties = .{};
    var property_indent: ?usize = null;

    while (index.* < end) {
        const line_start = index.*;
        if (tokens[index.*] != .indent or tokens[index.*].indent <= parent_indent) break;
        const line_indent = tokens[index.*].indent;
        index.* += 1;

        const line_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        if (!has(line_properties)) {
            index.* = line_start;
            break;
        }

        if (index.* >= end or tokens[index.*] != .indent) {
            if (property_indent != null) {
                index.* = line_start;
                break;
            }
            index.* = start;
            return null;
        }

        try merge(&properties, line_properties);
        property_indent = if (property_indent) |indent| @max(indent, line_indent) else line_indent;
    }

    const indent = property_indent orelse {
        index.* = start;
        return null;
    };

    return .{
        .properties = properties,
        .indent = indent,
    };
}

pub fn parsePropertyOnlyEmptyBlockScalarNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: usize,
    end: usize,
    properties: NodeProperties,
    boundary_indent: usize,
) Error!?PlainBlockNode {
    if (!has(properties)) return null;
    if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index, end, boundary_indent)) {
        return try emptyScalar(allocator, properties);
    }
    return null;
}

pub fn validateNodePropertiesSeparatedFromScalar(
    properties: NodeProperties,
    tokens: []const scanner.Token,
    index: usize,
    end: usize,
) ParseError!void {
    if (properties.source_end) |property_end| {
        if (index < end and tokens[index] == .scalar and scalarStartsAdjacentToPropertyIndicator(property_end, tokens[index].scalar)) {
            return ParseError.InvalidSyntax;
        }
    }
}

pub fn compactBlockSequenceEntryHasSameLineContent(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index >= end or tokens[index] != .block_sequence_entry) return false;
    const next = index + 1;
    if (next >= end) return false;
    return tokens[next] != .indent and tokens[next] != .document_end;
}

pub fn appendCompactExplicitBlockMappingPair(
    allocator: std.mem.Allocator,
    pairs: *std.ArrayList(PlainBlockPair),
    node: PlainBlockNode,
) Error!void {
    if (node != .mapping or node.mapping.pairs.len != 1) return ParseError.InvalidSyntax;
    try pairs.append(allocator, node.mapping.pairs[0]);
}

fn consumeDirectiveToken(
    allocator: std.mem.Allocator,
    directive: []const u8,
    directives: *TokenDirectives,
    tag_directives: *std.ArrayList(tag_resolver.Directive),
) Error!void {
    var parts = std.mem.tokenizeAny(u8, directive, " \t");
    const name = parts.next() orelse return;

    if (std.mem.eql(u8, name, "%YAML")) {
        if (directives.yaml_version != null) return ParseError.InvalidSyntax;
        const version = parts.next() orelse return ParseError.InvalidSyntax;
        if (!tag_resolver.isValidYamlVersion(version)) return ParseError.InvalidSyntax;
        if (parts.next() != null) return ParseError.InvalidSyntax;
        directives.yaml_version = try allocator.dupe(u8, version);
        return;
    }

    if (std.mem.eql(u8, name, "%TAG")) {
        const handle = parts.next() orelse return ParseError.InvalidSyntax;
        const prefix = parts.next() orelse return ParseError.InvalidSyntax;
        if (parts.next() != null) return ParseError.InvalidSyntax;
        if (!tag_resolver.isValidHandle(handle)) return ParseError.InvalidSyntax;
        if (!tag_resolver.isValidPrefix(prefix)) return ParseError.InvalidSyntax;

        for (tag_directives.items) |existing| {
            if (std.mem.eql(u8, existing.handle, handle)) return ParseError.InvalidSyntax;
        }

        try tag_directives.append(allocator, .{
            .handle = try allocator.dupe(u8, handle),
            .prefix = try allocator.dupe(u8, prefix),
        });
        return;
    }

    directives.has_reserved_directive = true;
}

fn tokenSourceSlice(token: scanner.Token) ?[]const u8 {
    return switch (token) {
        .directive => |value| value,
        .comment => |value| value,
        .anchor => |value| value,
        .alias => |value| value,
        .tag => |value| value,
        .scalar => |value| value,
        .block_scalar => |value| value.content,
        else => null,
    };
}

fn implicitKeyTokenLeadingCodepoints(token: scanner.Token) usize {
    return switch (token) {
        .anchor, .alias => 1,
        else => 0,
    };
}

fn implicitKeyTokenPresentationCodepoints(tokens: []const scanner.Token) usize {
    var count: usize = 0;
    for (tokens) |token| {
        count += switch (token) {
            .flow_sequence_start,
            .flow_sequence_end,
            .flow_mapping_start,
            .flow_mapping_end,
            .flow_entry,
            .flow_mapping_key,
            .flow_mapping_value,
            => 1,
            else => 0,
        };
    }
    return count;
}

fn validateImplicitKeySourceLength(source: []const u8) ParseError!void {
    try validateImplicitKeySourceLengthWithExtra(source, 0);
}

fn validateImplicitKeyExtraCodepoints(codepoints: usize) ParseError!void {
    if (codepoints > max_implicit_key_codepoints) return ParseError.InvalidSyntax;
}

fn validateImplicitKeySourceLengthWithExtra(source: []const u8, extra_codepoints: usize) ParseError!void {
    const codepoints = (std.unicode.utf8CountCodepoints(source) catch return ParseError.InvalidSyntax) + extra_codepoints;
    try validateImplicitKeyExtraCodepoints(codepoints);
}

fn propertyLineStartsBlockMappingPair(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var index = start;
    var saw_property = false;

    while (index < end and isNodePropertyToken(tokens[index])) : (index += 1) {
        saw_property = true;
    }
    if (!saw_property) return false;

    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .block_mapping_value => return true,
            .comment, .indent, .document_start, .document_end => return false,
            else => {},
        }
    }

    return false;
}

test {
    std.testing.refAllDecls(@This());
}

test "parser source slice: lineAt advances past CRLF as one line break" {
    const line = lineAt("first\r\nsecond", 0);

    try std.testing.expectEqual(@as(usize, 0), line.start);
    try std.testing.expectEqual(@as(usize, 5), line.end);
    try std.testing.expectEqual(@as(usize, 7), line.next);
}

test "parser source slice: consumeLineBreak consumes CRLF and standalone CR" {
    try std.testing.expectEqual(@as(?usize, 7), consumeLineBreak("first\r\nsecond", 5, 13));
    try std.testing.expectEqual(@as(?usize, 6), consumeLineBreak("first\rsecond", 5, 12));
}

test "token cursor: alias trailing content ignores non-content stream end" {
    const tokens = [_]scanner.Token{
        .{ .comment = "" },
        .stream_end,
        .{ .scalar = "ignored" },
    };

    try std.testing.expect(!aliasDocumentHasTrailingContent(&tokens, 0, tokens.len));
}

test "parser implicit key: token range accepts block scalar source slices" {
    const tokens = [_]scanner.Token{
        .{ .block_scalar = .{ .style = .literal, .content = "key" } },
    };

    try validateImplicitTokenKeyLength(&tokens, 0, tokens.len);
}
