//! Purpose: Parse YAML block mappings.
//! Owns: Block mapping document, key, value, compact, and nested node parsing.
//! Does not own: Sequence, scalar, flow, scanning, schema resolution, or loading.
//! Depends on: parser/internal.zig, parser/scalar.zig, parser/block_sequence.zig, scanner/scanner.zig, and common/limit.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const block_sequence = @import("block_sequence.zig");
const common_limit = @import("../common/limit.zig");
const internal = @import("internal.zig");
const scalar_parser = @import("scalar.zig");
const scanner = @import("../scanner/scanner.zig");
const types = @import("event.zig");

const Error = types.Error;
const ParseError = types.ParseError;
const max_block_depth = common_limit.max_parse_collection_depth;
const NodeProperties = internal.NodeProperties;
const TokenDirectives = internal.TokenDirectives;
const PlainBlockNode = internal.PlainBlockNode;
const PlainBlockPair = internal.PlainBlockPair;
const appendCompactExplicitBlockMappingPair = internal.appendCompactExplicitBlockMappingPair;
const parseFlowPlainBlockNode = internal.parseFlowPlainBlockNode;
const consumeBlockCollectionProperties = internal.consumeBlockCollectionProperties;
const compactBlockSequenceEntryHasSameLineContent = internal.compactBlockSequenceEntryHasSameLineContent;
const consumeNestedBlockCollectionPropertyLine = internal.consumeNestedBlockCollectionPropertyLine;
const isBareBlockSequenceEntryScalar = scalar_parser.isBareBlockSequenceEntryScalar;
const isTabSeparatedCompactMappingStart = scalar_parser.isTabSeparatedCompactMappingStart;
const parseBlockScalarToken = scalar_parser.parseBlockScalarToken;
const parseBlockScalarTokenAt = scalar_parser.parseBlockScalarTokenAt;
const parsePlainScalarTokenRun = scalar_parser.parsePlainScalarTokenRun;
const parsePlainScalarTokenRunWithIndentedContinuations = scalar_parser.parsePlainScalarTokenRunWithIndentedContinuations;
const parseScalarToken = scalar_parser.parseScalarToken;
const scalarTokenSpansLines = scalar_parser.scalarTokenSpansLines;
const consumeLeadingDirectives = internal.consumeLeadingDirectives;
const consumeNodeProperties = internal.consumeNodeProperties;
const consumeDocumentStartContent = internal.consumeDocumentStartContent;
const emptyScalarNode = internal.emptyScalar;
const flowCollectionAtStartSpansLines = internal.flowCollectionAtStartSpansLines;
const flowCollectionDescendantSpansLines = internal.flowCollectionDescendantSpansLines;
const hasNodeProperties = internal.has;
const indentlessBlockSequenceStartsAtIndent = internal.indentlessBlockSequenceStartsAtIndent;
const isExplicitBlockMappingValueBoundary = internal.isExplicitBlockMappingValueBoundary;
const isFlowStartToken = internal.isFlowStartToken;
const isPlainBlockOmittedValueBoundaryAtIndent = internal.isPlainBlockOmittedValueBoundaryAtIndent;
const isNestedBlockCollectionStart = internal.isNestedBlockCollectionStart;
const isPlainScalarToken = scalar_parser.isPlainScalarToken;
const isSingleIndicatorScalarKeyBeforeValue = internal.isSingleIndicatorScalarKeyBeforeValue;
const mergeNodeProperties = internal.merge;
const multilineScalarCandidateHasNoImmediateMappingValue = internal.multilineScalarCandidateHasNoImmediateMappingValue;
const scalarTokenRunStartsBlockMappingKey = internal.scalarTokenRunStartsBlockMappingKey;
const parsePropertyOnlyEmptyBlockScalarNode = internal.parsePropertyOnlyEmptyBlockScalarNode;
const skipComments = internal.skipComments;
const tokenRangeSpansLines = internal.tokenRangeSpansLines;
const validateAliasHasNoFollowingContent = internal.validateAliasHasNoFollowingContent;
const validateBlockFlowScalarToken = scalar_parser.validateBlockFlowScalarToken;
const validateExplicitMappingAliasKeyHasNoFollowingContent = internal.validateExplicitMappingAliasKeyHasNoFollowingContent;
const validateFlowContinuationIndent = internal.validateFlowContinuationIndent;
const validateImplicitAliasKeyLength = internal.validateImplicitAliasKeyLength;
const validateImplicitScalarKeyLength = internal.validateImplicitScalarKeyLength;
const validateImplicitTokenKeyLength = internal.validateImplicitTokenKeyLength;
const validateNodePropertiesSeparatedFromScalar = internal.validateNodePropertiesSeparatedFromScalar;
const parseCompactPlainBlockSequenceNode = block_sequence.parseCompactPlainBlockSequenceNode;
const parseIndentedPlainBlockSequenceItemNode = block_sequence.parseIndentedPlainBlockSequenceItemNode;
const parseIndentlessPlainBlockSequenceNode = block_sequence.parseIndentlessPlainBlockSequenceNode;
const parseNestedPlainBlockSequenceNode = block_sequence.parseNestedPlainBlockSequenceNode;

pub fn parsePlainBlockMappingKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    if (try parsePlainBlockMappingScalarKey(allocator, tokens, index, end, .invalid)) |key| {
        var parsed = key;
        parsed.anchor = properties.anchor;
        parsed.tag = properties.tag;
        return .{ .scalar = parsed };
    }

    if (index.* < end and tokens[index.*] == .alias) {
        if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
        const alias = try allocator.dupe(u8, tokens[index.*].alias);
        index.* += 1;
        return .{ .alias = alias };
    }

    if (hasNodeProperties(properties) and index.* < end and tokens[index.*] == .block_mapping_value) {
        return try emptyScalarNode(allocator, properties);
    }

    if (try parseFlowPlainBlockNode(allocator, tokens, index, end, properties, directives)) |node| {
        return node;
    }

    return null;
}

pub fn parseExplicitBlockMappingScalarKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
) Error!?PlainBlockNode {
    if (index.* >= end or tokens[index.*] != .scalar) return null;

    var scalar = if (try parsePlainScalarTokenRunWithIndentedContinuations(allocator, tokens, index, end, key_indent)) |plain|
        plain
    else value: {
        const parsed = try parseScalarToken(allocator, tokens[index.*].scalar);
        index.* += 1;
        break :value parsed;
    };
    scalar.anchor = properties.anchor;
    scalar.tag = properties.tag;
    return .{ .scalar = scalar };
}

pub fn parseIndentedExplicitBlockMappingScalarKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= key_indent) return null;
    index.* += 1;

    const node = (try parseExplicitBlockMappingScalarKeyNode(
        allocator,
        tokens,
        index,
        end,
        key_indent,
        properties,
    )) orelse {
        index.* = start;
        return null;
    };

    if (index.* < end and tokens[index.*] == .block_mapping_value) {
        index.* = start;
        return null;
    }

    return node;
}

pub fn parseIndentedExplicitBlockMappingBlockScalarKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
) Error!?PlainBlockNode {
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= key_indent) return null;

    const node_indent = tokens[index.*].indent;
    const node_start = index.* + 1;
    if (node_start >= end or tokens[node_start] != .block_scalar) return null;

    index.* = node_start;
    var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, node_indent);
    scalar.anchor = properties.anchor;
    scalar.tag = properties.tag;
    index.* += 1;
    return .{ .scalar = scalar };
}

pub fn parseIndentedExplicitBlockMappingFlowKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= key_indent) return null;

    const node_start = index.* + 1;
    if (node_start >= end or !isFlowStartToken(tokens[node_start])) return null;

    var flow_index = node_start;
    try validateFlowContinuationIndent(tokens, flow_index, end, key_indent);
    const node = (try parseFlowPlainBlockNode(
        allocator,
        tokens,
        &flow_index,
        end,
        properties,
        directives,
    )) orelse {
        index.* = start;
        return null;
    };

    index.* = flow_index;
    return node;
}

pub fn parseIndentedExplicitBlockMappingAliasKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
) Error!?PlainBlockNode {
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= key_indent) return null;

    const node_start = index.* + 1;
    if (node_start >= end or tokens[node_start] != .alias) return null;
    if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;

    index.* = node_start;
    const alias = try allocator.dupe(u8, tokens[index.*].alias);
    index.* += 1;
    try validateExplicitMappingAliasKeyHasNoFollowingContent(tokens, index.*, end, key_indent);
    return .{ .alias = alias };
}

pub fn parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    const start = index.*;
    const property_line = (try consumeNestedBlockCollectionPropertyLine(
        allocator,
        tokens,
        index,
        end,
        key_indent,
        directives,
    )) orelse return null;

    if (!isExplicitBlockMappingValueBoundary(tokens, index.*, end, key_indent)) {
        index.* = start;
        return null;
    }

    var node_properties = properties;
    try mergeNodeProperties(&node_properties, property_line.properties);
    return try emptyScalarNode(allocator, node_properties);
}

pub const MultilineScalarKeyBehavior = enum {
    invalid,
    unsupported,
};

pub fn parsePlainBlockMappingScalarKey(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    multiline_behavior: MultilineScalarKeyBehavior,
) Error!?types.Scalar {
    if (index.* >= end or tokens[index.*] != .scalar) return null;

    const first = tokens[index.*].scalar;
    if (std.mem.eql(u8, first, "?")) return null;
    if (scalarTokenSpansLines(first)) return switch (multiline_behavior) {
        .invalid => ParseError.InvalidSyntax,
        .unsupported => null,
    };

    if (isSingleIndicatorScalarKeyBeforeValue(tokens, index.*, end)) {
        index.* += 1;
        return .{
            .value = try allocator.dupe(u8, first),
            .style = .plain,
        };
    }

    if (!isPlainScalarToken(first)) {
        try validateImplicitScalarKeyLength(first);
        index.* += 1;
        return try parseScalarToken(allocator, first);
    }

    const key_start = index.*;
    const parsed = (try parsePlainScalarTokenRun(allocator, tokens, index, end)) orelse return null;
    try validateImplicitTokenKeyLength(tokens, key_start, index.*);
    return parsed;
}

pub fn multilinePlainScalarKeyBeforeValue(tokens: []const scanner.Token, index: usize, end: usize, key_indent: usize) bool {
    if (index >= end or tokens[index] != .scalar) return false;
    const first = tokens[index].scalar;
    if (!isPlainScalarToken(first)) return false;

    var cursor = index + 1;
    var spans_lines = scalarTokenSpansLines(first);
    while (cursor < end) {
        switch (tokens[cursor]) {
            .scalar => |value| {
                if (!scalar_parser.isPlainScalarContinuationToken(value)) break;
                cursor += 1;
            },
            .indent => |indent| {
                if (indent <= key_indent or cursor + 1 >= end) {
                    return spans_lines and indent == key_indent and cursor + 1 < end and tokens[cursor + 1] == .block_mapping_value;
                }
                if (tokens[cursor + 1] != .scalar or !scalar_parser.isPlainScalarContinuationToken(tokens[cursor + 1].scalar)) break;
                spans_lines = true;
                cursor += 2;
            },
            else => break,
        }
    }

    return spans_lines and cursor < end and tokens[cursor] == .block_mapping_value;
}
pub fn parseIndentedPlainBlockMappingValueNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= parent_indent) return null;

    const node_indent = tokens[index.*].indent;
    const node_start = index.* + 1;
    if (node_start >= end) return null;
    if (flowCollectionHasImmediateBlockMappingValue(tokens, node_start, end)) return null;
    switch (tokens[node_start]) {
        .block_sequence_entry, .block_mapping_key => return null,
        .scalar => {
            if (multilinePlainScalarKeyBeforeValue(tokens, node_start, end, node_indent)) return ParseError.InvalidSyntax;
            if (scalarTokenRunStartsBlockMappingKey(tokens, node_start, end)) return null;
        },
        else => {},
    }

    index.* += 1;

    var node_properties = properties;
    const line_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
    if (isNestedBlockCollectionStart(tokens, index.*, end)) {
        index.* = start;
        return null;
    }
    try mergeNodeProperties(&node_properties, line_properties);
    try validateNodePropertiesSeparatedFromScalar(node_properties, tokens, index.*, end);
    if (hasNodeProperties(node_properties) and
        isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, parent_indent) and
        !indentlessBlockSequenceStartsAtIndent(tokens, index.*, end, parent_indent))
    {
        return try emptyScalarNode(allocator, node_properties);
    }

    if (index.* + 1 < end and tokens[index.*] == .indent and tokens[index.*].indent > parent_indent and tokens[index.* + 1] == .block_scalar) {
        index.* += 1;
        var scalar = try parseBlockScalarTokenAt(allocator, tokens, index, end, parent_indent);
        scalar.anchor = node_properties.anchor;
        scalar.tag = node_properties.tag;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .scalar) {
        try validateBlockFlowScalarToken(tokens[index.*].scalar, node_indent);
        var scalar = if (try parsePlainScalarTokenRunWithIndentedContinuations(allocator, tokens, index, end, parent_indent)) |plain|
            plain
        else value_scalar: {
            const parsed = try parseScalarToken(allocator, tokens[index.*].scalar);
            index.* += 1;
            break :value_scalar parsed;
        };
        scalar.anchor = node_properties.anchor;
        scalar.tag = node_properties.tag;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .block_scalar) {
        var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, node_indent);
        scalar.anchor = node_properties.anchor;
        scalar.tag = node_properties.tag;
        index.* += 1;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .alias) {
        if (hasNodeProperties(node_properties)) return ParseError.InvalidSyntax;
        const alias = try allocator.dupe(u8, tokens[index.*].alias);
        index.* += 1;
        try validateAliasHasNoFollowingContent(tokens, index.*, end, parent_indent);
        return .{ .alias = alias };
    }

    if (index.* < end and isFlowStartToken(tokens[index.*])) {
        try validateFlowContinuationIndent(tokens, index.*, end, parent_indent);
    }
    if (try parseFlowPlainBlockNode(allocator, tokens, index, end, node_properties, directives)) |node| {
        return node;
    }

    index.* = start;
    return null;
}

fn flowCollectionHasImmediateBlockMappingValue(tokens: []const scanner.Token, start: usize, end: usize) bool {
    if (start >= end or !isFlowStartToken(tokens[start])) return false;

    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .flow_sequence_start, .flow_mapping_start => depth += 1,
            .flow_sequence_end, .flow_mapping_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) {
                    const next = index + 1;
                    return next < end and tokens[next] == .block_mapping_value;
                }
            },
            else => {},
        }
    }

    return false;
}

pub fn parsePlainBlockMappingValueNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    key_indent: usize,
    mapping_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
    allow_compact_mapping: bool,
) Error!PlainBlockNode {
    if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, mapping_indent, properties, directives, depth, false)) |node| {
        return node;
    }

    if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (allow_compact_mapping) {
        if (isTabSeparatedCompactMappingStart(tokens, index.*, end)) return ParseError.InvalidSyntax;
        if (try parseCompactPlainBlockMappingNode(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
            return node;
        }
    } else if (scalarTokenRunStartsBlockMappingKey(tokens, index.*, end)) {
        return ParseError.InvalidSyntax;
    }

    if (index.* < end and tokens[index.*] == .scalar) {
        if (multilinePlainScalarKeyBeforeValue(tokens, index.*, end, key_indent)) return ParseError.InvalidSyntax;
        if (isBareBlockSequenceEntryScalar(tokens[index.*].scalar)) return ParseError.Unsupported;
        try validateBlockFlowScalarToken(tokens[index.*].scalar, 1);
        var scalar = if (try parsePlainScalarTokenRunWithIndentedContinuations(allocator, tokens, index, end, key_indent)) |plain|
            plain
        else value_scalar: {
            const parsed = try parseScalarToken(allocator, tokens[index.*].scalar);
            index.* += 1;
            break :value_scalar parsed;
        };
        scalar.anchor = properties.anchor;
        scalar.tag = properties.tag;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .block_scalar) {
        var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, key_indent);
        scalar.anchor = properties.anchor;
        scalar.tag = properties.tag;
        index.* += 1;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .alias) {
        if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
        const alias = try allocator.dupe(u8, tokens[index.*].alias);
        index.* += 1;
        try validateAliasHasNoFollowingContent(tokens, index.*, end, key_indent);
        return .{ .alias = alias };
    }

    if (index.* < end and isFlowStartToken(tokens[index.*])) {
        try validateFlowContinuationIndent(tokens, index.*, end, key_indent);
    }
    if (try parseFlowPlainBlockNode(allocator, tokens, index, end, properties, directives)) |node| {
        return node;
    }

    if (try parseIndentedPlainBlockMappingValueNode(allocator, tokens, index, end, key_indent, properties, directives)) |node| {
        return node;
    }

    if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, key_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, mapping_indent)) {
        return .{ .scalar = .{
            .value = try allocator.dupe(u8, ""),
            .anchor = properties.anchor,
            .tag = properties.tag,
        } };
    }

    return ParseError.Unsupported;
}

pub fn parseNestedBlockCollectionAfterPropertyLine(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
) Error!?PlainBlockNode {
    const start = index.*;
    const property_line = (try consumeNestedBlockCollectionPropertyLine(
        allocator,
        tokens,
        index,
        end,
        parent_indent,
        directives,
    )) orelse return null;

    var node_properties = properties;
    try mergeNodeProperties(&node_properties, property_line.properties);

    if (index.* < end and tokens[index.*] == .indent) {
        const node_indent = tokens[index.*].indent;
        if (node_indent >= property_line.indent) {
            if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, index, end, parent_indent, node_properties, directives)) |node| {
                return node;
            }

            const node_start = index.* + 1;
            if (node_start < end and isFlowStartToken(tokens[node_start])) {
                var flow_index = node_start;
                try validateFlowContinuationIndent(tokens, flow_index, end, parent_indent);
                if (try parseFlowPlainBlockNode(allocator, tokens, &flow_index, end, node_properties, directives)) |node| {
                    index.* = flow_index;
                    return node;
                }
            }

            if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, parent_indent, node_properties, directives, depth)) |node| {
                return node;
            }

            if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, parent_indent, node_properties, directives, depth)) |node| {
                return node;
            }
        } else if (node_indent == parent_indent) {
            if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, index, end, parent_indent, node_properties, directives, depth)) |node| {
                return node;
            }
        }
    }

    index.* = start;
    return null;
}

test "parser block mapping value: flow collection followed by value marker is not indented value" {
    const tokens = [_]scanner.Token{
        .{ .indent = 2 },
        .flow_sequence_start,
        .{ .scalar = "key" },
        .flow_sequence_end,
        .block_mapping_value,
    };

    try std.testing.expect(flowCollectionHasImmediateBlockMappingValue(&tokens, 1, tokens.len));

    var index: usize = 0;
    const node = try parseIndentedPlainBlockMappingValueNode(
        std.testing.allocator,
        &tokens,
        &index,
        tokens.len,
        0,
        .{},
        .{},
    );

    try std.testing.expect(node == null);
    try std.testing.expectEqual(@as(usize, 0), index);
}

test "parser block mapping value: indented value resets when token cannot form a node" {
    const tokens = [_]scanner.Token{
        .{ .indent = 2 },
        .flow_entry,
    };

    var index: usize = 0;
    const node = try parseIndentedPlainBlockMappingValueNode(
        std.testing.allocator,
        &tokens,
        &index,
        tokens.len,
        0,
        .{},
        .{},
    );

    try std.testing.expect(node == null);
    try std.testing.expectEqual(@as(usize, 0), index);
}

test "parser block mapping value: property line accepts indented flow collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = [_]scanner.Token{
        .{ .indent = 2 },
        .{ .tag = "!map" },
        .{ .indent = 4 },
        .flow_mapping_start,
        .{ .scalar = "key" },
        .flow_mapping_value,
        .{ .scalar = "value" },
        .flow_mapping_end,
    };

    var index: usize = 0;
    const node = (try parseNestedBlockCollectionAfterPropertyLine(
        arena.allocator(),
        &tokens,
        &index,
        tokens.len,
        0,
        .{},
        .{},
        0,
    )).?;

    try std.testing.expect(node == .flow_events);
    try std.testing.expectEqualStrings("!map", node.flow_events[0].mapping_start.tag.?);
    try std.testing.expectEqual(@as(usize, tokens.len), index);
}
pub fn parseCompactExplicitBlockMappingNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
    allow_separate_key_value: bool,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end) return null;
    if (tokens[index.*] == .block_mapping_key) {
        index.* += 1;
    } else if (tokens[index.*] == .scalar and
        std.mem.eql(u8, tokens[index.*].scalar, "?"))
    {
        index.* += 1;
    } else {
        return null;
    }
    if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
    if (depth >= max_block_depth) return ParseError.Unsupported;
    skipComments(tokens, index, end);

    const key_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
    const key = if (try parseCompactExplicitBlockMappingKeyNode(
        allocator,
        tokens,
        index,
        end,
        parent_indent,
        key_properties,
        directives,
        depth + 1,
    )) |node| node else if (allow_separate_key_value) key: {
        if (isCompactExplicitOmittedKeyBoundary(tokens, index.*, end, parent_indent)) {
            break :key try emptyScalarNode(allocator, key_properties);
        }
        if (try parseExplicitBlockMappingScalarKeyNode(allocator, tokens, index, end, parent_indent + 2, key_properties)) |node| {
            break :key node;
        }
        if (try parsePlainBlockMappingKeyNode(allocator, tokens, index, end, key_properties, directives)) |node| {
            break :key node;
        }
        if (index.* < end and tokens[index.*] == .block_scalar) {
            var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, parent_indent + 2);
            scalar.anchor = key_properties.anchor;
            scalar.tag = key_properties.tag;
            index.* += 1;
            break :key PlainBlockNode{ .scalar = scalar };
        }
        if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, index, end, parent_indent, key_properties, directives)) |node| {
            break :key node;
        }
        if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, parent_indent, key_properties, directives, depth + 1)) |node| {
            break :key node;
        }
        if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, parent_indent, key_properties, directives, depth + 1)) |node| {
            break :key node;
        }
        if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, parent_indent, key_properties, directives, depth + 1)) |node| {
            break :key node;
        }
        index.* = start;
        return null;
    } else {
        index.* = start;
        return null;
    };
    skipComments(tokens, index, end);

    const value: PlainBlockNode = if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, parent_indent)) value: {
        break :value .{ .scalar = .{ .value = try allocator.dupe(u8, "") } };
    } else if (index.* + 1 < end and
        tokens[index.*] == .indent and
        tokens[index.*].indent == parent_indent + 2 and
        tokens[index.* + 1] == .block_mapping_value)
    value: {
        const value_indent = tokens[index.*].indent;
        index.* += 2;
        skipComments(tokens, index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        break :value try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            value_indent,
            value_indent,
            value_properties,
            directives,
            depth + 1,
            true,
        );
    } else {
        index.* = start;
        return null;
    };

    const pairs = try allocator.alloc(PlainBlockPair, 1);
    pairs[0] = .{
        .key = key,
        .value = value,
    };

    return .{ .mapping = .{
        .pairs = pairs,
        .properties = properties,
    } };
}

pub fn isCompactExplicitOmittedKeyBoundary(tokens: []const scanner.Token, index: usize, end: usize, parent_indent: usize) bool {
    if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index, end, parent_indent)) return true;
    return index + 1 < end and
        tokens[index] == .indent and
        tokens[index].indent == parent_indent + 2 and
        tokens[index + 1] == .block_mapping_value;
}

pub fn parseCompactExplicitBlockMappingKeyNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
) Error!?PlainBlockNode {
    if (index.* < end and tokens[index.*] == .block_mapping_value) {
        if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
        index.* += 1;
        skipComments(tokens, index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            parent_indent,
            parent_indent,
            value_properties,
            directives,
            depth + 1,
            true,
        );

        const pairs = try allocator.alloc(PlainBlockPair, 1);
        pairs[0] = .{
            .key = .{ .scalar = .{ .value = try allocator.dupe(u8, "") } },
            .value = value,
        };

        return .{ .mapping = .{
            .pairs = pairs,
            .properties = properties,
        } };
    }

    const key_start = index.*;
    const key_node = if (try parseExplicitBlockMappingScalarKeyNode(allocator, tokens, index, end, parent_indent, properties)) |node|
        node
    else if (try parsePlainBlockMappingKeyNode(allocator, tokens, index, end, properties, directives)) |node|
        node
    else
        return null;

    {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] != .block_mapping_value) {
            index.* = key_start;
            return null;
        }
        if (tokenRangeSpansLines(tokens, key_start, index.*)) return ParseError.InvalidSyntax;
        try validateImplicitTokenKeyLength(tokens, key_start, index.*);
        index.* += 1;
        skipComments(tokens, index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            parent_indent,
            parent_indent,
            value_properties,
            directives,
            depth + 1,
            true,
        );

        const pairs = try allocator.alloc(PlainBlockPair, 1);
        pairs[0] = .{
            .key = key_node,
            .value = value,
        };

        return .{ .mapping = .{
            .pairs = pairs,
            .properties = properties,
        } };
    }

    return null;
}
pub fn parseCompactPlainBlockMappingNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
) Error!?PlainBlockNode {
    const start = index.*;
    if (depth >= max_block_depth) return ParseError.Unsupported;

    const mapping_indent = parent_indent + 2;
    var pairs: std.ArrayList(PlainBlockPair) = .empty;
    const mapping_properties: NodeProperties = .{};

    if (index.* < end and tokens[index.*] == .block_mapping_value) {
        index.* += 1;
        skipComments(tokens, index, end);

        const first_value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const first_value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            mapping_indent,
            mapping_indent,
            first_value_properties,
            directives,
            depth + 1,
            true,
        );
        try pairs.append(allocator, .{
            .key = try emptyScalarNode(allocator, properties),
            .value = first_value,
        });
    } else {
        const first_key_start = index.*;
        if (multilineScalarCandidateHasNoImmediateMappingValue(tokens, index.*, end)) {
            index.* = start;
            return null;
        }
        const first_key = (parsePlainBlockMappingKeyNode(allocator, tokens, index, end, properties, directives) catch |err| switch (err) {
            ParseError.Unsupported => null,
            else => return err,
        }) orelse {
            index.* = start;
            return null;
        };
        if (index.* >= end or tokens[index.*] != .block_mapping_value) {
            index.* = start;
            return null;
        }
        try validateImplicitTokenKeyLength(tokens, first_key_start, index.*);
        index.* += 1;
        skipComments(tokens, index, end);

        const first_value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const first_value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            mapping_indent,
            mapping_indent,
            first_value_properties,
            directives,
            depth + 1,
            true,
        );
        try pairs.append(allocator, .{
            .key = first_key,
            .value = first_value,
        });
    }

    while (index.* < end) {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] == .document_end) break;
        if (tokens[index.*] != .indent or tokens[index.*].indent != mapping_indent) break;

        index.* += 1;
        if (index.* < end and tokens[index.*] == .block_mapping_value) {
            index.* += 1;
            skipComments(tokens, index, end);

            const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
            const value = try parsePlainBlockMappingValueNode(
                allocator,
                tokens,
                index,
                end,
                mapping_indent,
                mapping_indent,
                value_properties,
                directives,
                depth + 1,
                true,
            );
            try pairs.append(allocator, .{
                .key = .{ .scalar = .{ .value = try allocator.dupe(u8, "") } },
                .value = value,
            });
            continue;
        }

        const key_start = index.*;
        const key_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        if (multilineScalarCandidateHasNoImmediateMappingValue(tokens, index.*, end)) {
            index.* = start;
            return null;
        }
        const key = (parsePlainBlockMappingKeyNode(allocator, tokens, index, end, key_properties, directives) catch |err| switch (err) {
            ParseError.Unsupported => null,
            else => return err,
        }) orelse {
            index.* = start;
            return null;
        };
        if (index.* >= end or tokens[index.*] != .block_mapping_value) {
            index.* = start;
            return null;
        }
        try validateImplicitTokenKeyLength(tokens, key_start, index.*);
        index.* += 1;
        skipComments(tokens, index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            index,
            end,
            mapping_indent,
            mapping_indent,
            value_properties,
            directives,
            depth + 1,
            true,
        );
        try pairs.append(allocator, .{
            .key = key,
            .value = value,
        });
    }

    return .{ .mapping = .{
        .pairs = try pairs.toOwnedSlice(allocator),
        .properties = mapping_properties,
    } };
}
pub const PlainMappingDocumentTokens = struct {
    pairs: []const PlainBlockPair,
    properties: NodeProperties = .{},
    directives: TokenDirectives = .{},
    explicit_start: bool = false,
    explicit_end: bool = false,
    force_document_start: bool = false,
    content_same_line: bool = false,
    content_same_line_separated_by_tab: bool = false,
};

pub fn parsePlainBlockMappingDocumentTokens(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
) Error!?PlainMappingDocumentTokens {
    return parsePlainBlockMappingDocumentTokenRange(allocator, tokens, 1, tokens.len - 1);
}

pub fn parsePlainBlockMappingDocumentTokenRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
) Error!?PlainMappingDocumentTokens {
    var index: usize = start;

    if (index == end) return null;

    const directives = try consumeLeadingDirectives(allocator, tokens, &index, end);
    if (index == end and directives.seen) return ParseError.InvalidSyntax;

    const explicit_start = index < end and tokens[index] == .document_start;
    if (directives.seen and !explicit_start) return ParseError.InvalidSyntax;
    if (explicit_start) index += 1;
    const document_start_content = consumeDocumentStartContent(tokens, &index, end);
    skipComments(tokens, &index, end);

    const content_same_line = document_start_content.content_same_line;
    const collection_properties = try consumeBlockCollectionProperties(allocator, tokens, &index, end, directives);

    var pairs: std.ArrayList(PlainBlockPair) = .empty;
    var explicit_end = false;
    var mapping_indent: ?usize = null;
    while (index < end) {
        skipComments(tokens, &index, end);
        if (index >= end) break;

        if (tokens[index] == .document_end) {
            explicit_end = true;
            index += 1;
            skipComments(tokens, &index, end);
            break;
        }

        var entry_started_same_line = false;
        const key_indent: usize = indent: {
            if (content_same_line and mapping_indent == null and tokens[index] != .indent) {
                entry_started_same_line = true;
                mapping_indent = 0;
                break :indent 0;
            }
            if (tokens[index] != .indent) return null;
            if (mapping_indent) |expected_indent| {
                if (tokens[index].indent != expected_indent) {
                    if (content_same_line) return ParseError.InvalidSyntax;
                    return null;
                }
            } else {
                mapping_indent = tokens[index].indent;
            }
            const current_indent = tokens[index].indent;
            index += 1;
            break :indent current_indent;
        };
        const current_mapping_indent = mapping_indent.?;
        if (try parseCompactExplicitBlockMappingNode(allocator, tokens, &index, end, key_indent, .{}, directives, 0, false)) |node| {
            try appendCompactExplicitBlockMappingPair(allocator, &pairs, node);
            continue;
        }

        if (index < end and tokens[index] == .block_mapping_key) {
            index += 1;
            skipComments(tokens, &index, end);

            const key_properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
            const key: PlainBlockNode = if (try parseCompactPlainBlockSequenceNode(allocator, tokens, &index, end, key_indent, key_properties, directives, 0)) |node| value: {
                break :value node;
            } else if (try parseExplicitBlockMappingScalarKeyNode(allocator, tokens, &index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingScalarKeyNode(allocator, tokens, &index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingBlockScalarKeyNode(allocator, tokens, &index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingFlowKeyNode(allocator, tokens, &index, end, key_indent, key_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingAliasKeyNode(allocator, tokens, &index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode(allocator, tokens, &index, end, key_indent, key_properties, directives)) |node| value: {
                break :value node;
            } else if (index < end and tokens[index] == .block_scalar) value: {
                var scalar = try parseBlockScalarToken(allocator, tokens[index].block_scalar, key_indent);
                scalar.anchor = key_properties.anchor;
                scalar.tag = key_properties.tag;
                index += 1;
                break :value .{ .scalar = scalar };
            } else if (index < end and tokens[index] == .alias) value: {
                if (hasNodeProperties(key_properties)) return ParseError.InvalidSyntax;
                const alias = try allocator.dupe(u8, tokens[index].alias);
                index += 1;
                try validateExplicitMappingAliasKeyHasNoFollowingContent(tokens, index, end, key_indent);
                break :value .{ .alias = alias };
            } else if (try parseFlowPlainBlockNode(allocator, tokens, &index, end, key_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, &index, end, key_indent, key_properties, directives, 0)) |node| value: {
                break :value node;
            } else if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, &index, end, key_indent, key_properties, directives, 0)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, &index, end, key_indent, key_properties, directives, 0)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, &index, end, key_indent, key_properties, directives, 0)) |node| value: {
                break :value node;
            } else if (try parsePropertyOnlyEmptyBlockScalarNode(allocator, tokens, index, end, key_properties, key_indent)) |node| value: {
                break :value node;
            } else if (isExplicitBlockMappingValueBoundary(tokens, index, end, key_indent)) value: {
                break :value .{ .scalar = .{
                    .value = try allocator.dupe(u8, ""),
                    .anchor = key_properties.anchor,
                    .tag = key_properties.tag,
                } };
            } else {
                return null;
            };

            skipComments(tokens, &index, end);
            if (isExplicitBlockMappingValueBoundary(tokens, index, end, key_indent)) {
                index += 2;
                skipComments(tokens, &index, end);
            } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index, end, key_indent)) {
                try pairs.append(allocator, .{
                    .key = key,
                    .value = .{ .scalar = .{ .value = try allocator.dupe(u8, "") } },
                });
                continue;
            } else {
                return null;
            }

            const value_properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
            const value_node = try parsePlainBlockMappingValueNode(
                allocator,
                tokens,
                &index,
                end,
                key_indent,
                current_mapping_indent,
                value_properties,
                directives,
                0,
                false,
            );

            try pairs.append(allocator, .{ .key = key, .value = value_node });
            continue;
        }

        const key_properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
        if (entry_started_same_line and hasNodeProperties(key_properties) and index < end and isFlowStartToken(tokens[index])) return null;
        if (entry_started_same_line and hasNodeProperties(key_properties)) return ParseError.InvalidSyntax;
        if (index < end and tokens[index] == .block_mapping_value) {
            const key: PlainBlockNode = .{ .scalar = .{
                .value = try allocator.dupe(u8, ""),
                .anchor = key_properties.anchor,
                .tag = key_properties.tag,
            } };
            index += 1;
            skipComments(tokens, &index, end);

            const value_properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
            const value_node = try parsePlainBlockMappingValueNode(
                allocator,
                tokens,
                &index,
                end,
                key_indent,
                current_mapping_indent,
                value_properties,
                directives,
                0,
                false,
            );

            try pairs.append(allocator, .{ .key = key, .value = value_node });
            continue;
        }

        if (multilinePlainScalarKeyBeforeValue(tokens, index, end, key_indent)) return ParseError.InvalidSyntax;
        const key: PlainBlockNode = if (try parsePlainBlockMappingScalarKey(allocator, tokens, &index, end, if (entry_started_same_line) .unsupported else .invalid)) |scalar_key| value: {
            var parsed = scalar_key;
            parsed.anchor = key_properties.anchor;
            parsed.tag = key_properties.tag;
            break :value .{ .scalar = parsed };
        } else if (index < end and tokens[index] == .alias) value: {
            if (hasNodeProperties(key_properties)) return ParseError.InvalidSyntax;
            try validateImplicitAliasKeyLength(tokens[index].alias);
            const alias = try allocator.dupe(u8, tokens[index].alias);
            index += 1;
            break :value .{ .alias = alias };
        } else if (index < end and isFlowStartToken(tokens[index])) value: {
            const key_start = index;
            const spans_lines = flowCollectionAtStartSpansLines(tokens, index, end);
            if (try parseFlowPlainBlockNode(allocator, tokens, &index, end, key_properties, directives)) |node| {
                if (index < end and tokens[index] == .block_mapping_value) {
                    if (spans_lines) return ParseError.InvalidSyntax;
                    try validateImplicitTokenKeyLength(tokens, key_start, index);
                }
                break :value node;
            }
            return null;
        } else if (try parseFlowPlainBlockNode(allocator, tokens, &index, end, key_properties, directives)) |node| value: {
            break :value node;
        } else {
            return null;
        };

        if (index >= end or tokens[index] != .block_mapping_value) return null;
        index += 1;
        skipComments(tokens, &index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
        if (compactBlockSequenceEntryHasSameLineContent(tokens, index, end)) return ParseError.InvalidSyntax;
        const block_value = try parsePlainBlockMappingValueNode(
            allocator,
            tokens,
            &index,
            end,
            key_indent,
            current_mapping_indent,
            value_properties,
            directives,
            0,
            false,
        );

        try pairs.append(allocator, .{ .key = key, .value = block_value });
    }

    if (pairs.items.len == 0 or index != end) return null;
    return .{
        .pairs = try pairs.toOwnedSlice(allocator),
        .properties = collection_properties,
        .directives = directives,
        .explicit_start = explicit_start,
        .explicit_end = explicit_end,
        .force_document_start = flowCollectionDescendantSpansLines(tokens[start..end]),
        .content_same_line = content_same_line,
        .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
    };
}
pub fn parseNestedPlainBlockMappingNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    parent_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= parent_indent) return null;
    if (depth >= max_block_depth) return ParseError.Unsupported;

    const mapping_indent = tokens[index.*].indent;
    var pairs: std.ArrayList(PlainBlockPair) = .empty;

    while (index.* < end) {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] == .document_end) break;

        if (tokens[index.*] != .indent) {
            index.* = start;
            return null;
        }

        const key_indent = tokens[index.*].indent;
        if (key_indent < mapping_indent) break;
        if (key_indent != mapping_indent) {
            index.* = start;
            return null;
        }
        index.* += 1;

        if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, key_indent, .{}, directives, depth + 1, false)) |node| {
            try appendCompactExplicitBlockMappingPair(allocator, &pairs, node);
            continue;
        }

        if (index.* < end and tokens[index.*] == .block_mapping_key) {
            index.* += 1;
            skipComments(tokens, index, end);

            const key_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
            const key: PlainBlockNode = if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, key_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseExplicitBlockMappingScalarKeyNode(allocator, tokens, index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingScalarKeyNode(allocator, tokens, index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingBlockScalarKeyNode(allocator, tokens, index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingFlowKeyNode(allocator, tokens, index, end, key_indent, key_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseIndentedExplicitBlockMappingAliasKeyNode(allocator, tokens, index, end, key_indent, key_properties)) |node| value: {
                break :value node;
            } else if (try parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode(allocator, tokens, index, end, key_indent, key_properties, directives)) |node| value: {
                break :value node;
            } else if (index.* < end and tokens[index.*] == .block_scalar) value: {
                var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, key_indent);
                scalar.anchor = key_properties.anchor;
                scalar.tag = key_properties.tag;
                index.* += 1;
                break :value .{ .scalar = scalar };
            } else if (index.* < end and tokens[index.*] == .alias) value: {
                if (hasNodeProperties(key_properties)) return ParseError.InvalidSyntax;
                const alias = try allocator.dupe(u8, tokens[index.*].alias);
                index.* += 1;
                try validateExplicitMappingAliasKeyHasNoFollowingContent(tokens, index.*, end, key_indent);
                break :value .{ .alias = alias };
            } else if (try parseFlowPlainBlockNode(allocator, tokens, index, end, key_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, key_indent, key_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, key_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, key_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, key_indent, key_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parsePropertyOnlyEmptyBlockScalarNode(allocator, tokens, index.*, end, key_properties, key_indent)) |node| value: {
                break :value node;
            } else if (isExplicitBlockMappingValueBoundary(tokens, index.*, end, key_indent)) value: {
                break :value .{ .scalar = .{
                    .value = try allocator.dupe(u8, ""),
                    .anchor = key_properties.anchor,
                    .tag = key_properties.tag,
                } };
            } else {
                index.* = start;
                return null;
            };

            skipComments(tokens, index, end);
            if (isExplicitBlockMappingValueBoundary(tokens, index.*, end, key_indent)) {
                index.* += 2;
                skipComments(tokens, index, end);
            } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, key_indent)) {
                try pairs.append(allocator, .{
                    .key = key,
                    .value = .{ .scalar = .{ .value = try allocator.dupe(u8, "") } },
                });
                continue;
            } else {
                index.* = start;
                return null;
            }

            const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
            const value_node: PlainBlockNode = if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1, false)) |node| value: {
                break :value node;
            } else if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (index.* < end and tokens[index.*] == .scalar) value: {
                if (isBareBlockSequenceEntryScalar(tokens[index.*].scalar)) return ParseError.Unsupported;
                try validateBlockFlowScalarToken(tokens[index.*].scalar, 1);
                var scalar = if (try parsePlainScalarTokenRunWithIndentedContinuations(allocator, tokens, index, end, key_indent)) |plain|
                    plain
                else value_scalar: {
                    const parsed = try parseScalarToken(allocator, tokens[index.*].scalar);
                    index.* += 1;
                    break :value_scalar parsed;
                };
                scalar.anchor = value_properties.anchor;
                scalar.tag = value_properties.tag;
                break :value .{ .scalar = scalar };
            } else if (index.* < end and tokens[index.*] == .block_scalar) value: {
                var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, key_indent);
                scalar.anchor = value_properties.anchor;
                scalar.tag = value_properties.tag;
                index.* += 1;
                break :value .{ .scalar = scalar };
            } else if (index.* < end and tokens[index.*] == .alias) value: {
                if (hasNodeProperties(value_properties)) return ParseError.InvalidSyntax;
                const alias = try allocator.dupe(u8, tokens[index.*].alias);
                index.* += 1;
                try validateAliasHasNoFollowingContent(tokens, index.*, end, key_indent);
                break :value .{ .alias = alias };
            } else if (try parseFlowPlainBlockNode(allocator, tokens, index, end, value_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseIndentedPlainBlockMappingValueNode(allocator, tokens, index, end, key_indent, value_properties, directives)) |node| value: {
                break :value node;
            } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
                break :value node;
            } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, mapping_indent)) value: {
                break :value .{ .scalar = .{
                    .value = try allocator.dupe(u8, ""),
                    .anchor = value_properties.anchor,
                    .tag = value_properties.tag,
                } };
            } else {
                index.* = start;
                return null;
            };

            try pairs.append(allocator, .{
                .key = key,
                .value = value_node,
            });
            continue;
        }

        const key_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        if (index.* < end and tokens[index.*] == .block_mapping_value) {
            const key: PlainBlockNode = try emptyScalarNode(allocator, key_properties);
            index.* += 1;
            skipComments(tokens, index, end);

            const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
            const value_node = try parsePlainBlockMappingValueNode(
                allocator,
                tokens,
                index,
                end,
                key_indent,
                mapping_indent,
                value_properties,
                directives,
                depth + 1,
                true,
            );

            try pairs.append(allocator, .{
                .key = key,
                .value = value_node,
            });
            continue;
        }

        if (multilinePlainScalarKeyBeforeValue(tokens, index.*, end, key_indent)) return ParseError.InvalidSyntax;
        const key: PlainBlockNode = if (try parsePlainBlockMappingScalarKey(allocator, tokens, index, end, .unsupported)) |scalar_key| value: {
            var parsed = scalar_key;
            parsed.anchor = key_properties.anchor;
            parsed.tag = key_properties.tag;
            break :value .{ .scalar = parsed };
        } else if (index.* < end and tokens[index.*] == .alias) value: {
            if (hasNodeProperties(key_properties)) return ParseError.InvalidSyntax;
            try validateImplicitAliasKeyLength(tokens[index.*].alias);
            const alias = try allocator.dupe(u8, tokens[index.*].alias);
            index.* += 1;
            break :value .{ .alias = alias };
        } else if (index.* < end and isFlowStartToken(tokens[index.*])) value: {
            const key_start = index.*;
            const spans_lines = flowCollectionAtStartSpansLines(tokens, index.*, end);
            if (try parseFlowPlainBlockNode(allocator, tokens, index, end, key_properties, directives)) |node| {
                if (index.* < end and tokens[index.*] == .block_mapping_value) {
                    if (spans_lines) return ParseError.InvalidSyntax;
                    try validateImplicitTokenKeyLength(tokens, key_start, index.*);
                }
                break :value node;
            }
            index.* = start;
            return null;
        } else if (try parseFlowPlainBlockNode(allocator, tokens, index, end, key_properties, directives)) |node| value: {
            break :value node;
        } else {
            index.* = start;
            return null;
        };

        if (index.* >= end or tokens[index.*] != .block_mapping_value) {
            index.* = start;
            return null;
        }
        index.* += 1;
        skipComments(tokens, index, end);

        const value_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        const value_node: PlainBlockNode = if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (index.* < end and tokens[index.*] == .scalar) value: {
            try validateBlockFlowScalarToken(tokens[index.*].scalar, 1);
            var scalar = if (try parsePlainScalarTokenRunWithIndentedContinuations(allocator, tokens, index, end, key_indent)) |plain|
                plain
            else value_scalar: {
                const parsed = try parseScalarToken(allocator, tokens[index.*].scalar);
                index.* += 1;
                break :value_scalar parsed;
            };
            scalar.anchor = value_properties.anchor;
            scalar.tag = value_properties.tag;
            break :value .{ .scalar = scalar };
        } else if (index.* < end and tokens[index.*] == .block_scalar) value: {
            var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, key_indent);
            scalar.anchor = value_properties.anchor;
            scalar.tag = value_properties.tag;
            index.* += 1;
            break :value .{ .scalar = scalar };
        } else if (index.* < end and tokens[index.*] == .alias) value: {
            if (hasNodeProperties(value_properties)) return ParseError.InvalidSyntax;
            const alias = try allocator.dupe(u8, tokens[index.*].alias);
            index.* += 1;
            try validateAliasHasNoFollowingContent(tokens, index.*, end, key_indent);
            break :value .{ .alias = alias };
        } else if (try parseFlowPlainBlockNode(allocator, tokens, index, end, value_properties, directives)) |node| value: {
            break :value node;
        } else if (try parseIndentedPlainBlockMappingValueNode(allocator, tokens, index, end, key_indent, value_properties, directives)) |node| value: {
            break :value node;
        } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseIndentlessPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, key_indent, value_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, mapping_indent)) value: {
            break :value .{ .scalar = .{
                .value = try allocator.dupe(u8, ""),
                .anchor = value_properties.anchor,
                .tag = value_properties.tag,
            } };
        } else {
            index.* = start;
            return null;
        };

        try pairs.append(allocator, .{
            .key = key,
            .value = value_node,
        });
    }

    if (pairs.items.len == 0) {
        index.* = start;
        return null;
    }

    return .{ .mapping = .{
        .pairs = try pairs.toOwnedSlice(allocator),
        .properties = properties,
    } };
}
