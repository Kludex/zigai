//! Purpose: Parse YAML block sequence documents and nodes.
//! Owns: Top-level, compact, indented, indentless, and nested block sequence parsing.
//! Does not own: Mapping document parsing, scanning, schema resolution, or loading.
//! Depends on: parser/internal.zig, parser/scalar.zig, parser/block_mapping.zig, scanner/scanner.zig, and common/limit.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const block_mapping = @import("block_mapping.zig");
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
const parseFlowPlainBlockNode = internal.parseFlowPlainBlockNode;
const consumeBlockCollectionProperties = internal.consumeBlockCollectionProperties;
const isBlockSequenceItemScalar = scalar_parser.isBlockSequenceItemScalar;
const isPlainScalarToken = scalar_parser.isPlainScalarToken;
const parseBlockScalarToken = scalar_parser.parseBlockScalarToken;
const parsePlainBlockSequenceItemScalarTokenRun = scalar_parser.parsePlainBlockSequenceItemScalarTokenRun;
const parsePlainScalarTokenRun = scalar_parser.parsePlainScalarTokenRun;
const parseScalarToken = scalar_parser.parseScalarToken;
const consumeLeadingDirectives = internal.consumeLeadingDirectives;
const consumeNodeProperties = internal.consumeNodeProperties;
const consumeDocumentStartContent = internal.consumeDocumentStartContent;
const emptyScalarNode = internal.emptyScalar;
const flowCollectionDescendantSpansLines = internal.flowCollectionDescendantSpansLines;
const hasNodeProperties = internal.has;
const isFlowStartToken = internal.isFlowStartToken;
const isPlainBlockOmittedValueBoundary = internal.isPlainBlockOmittedValueBoundary;
const isPlainBlockOmittedValueBoundaryAtIndent = internal.isPlainBlockOmittedValueBoundaryAtIndent;
const mergeNodeProperties = internal.merge;
const nodePropertyLineStartsNestedBlockMappingKey = internal.nodePropertyLineStartsNestedBlockMappingKey;
const skipComments = internal.skipComments;
const validateAliasHasNoFollowingContent = internal.validateAliasHasNoFollowingContent;
const validateBlockFlowScalarToken = scalar_parser.validateBlockFlowScalarToken;
const validateFlowContinuationIndent = internal.validateFlowContinuationIndent;
const validateNodePropertiesSeparatedFromScalar = internal.validateNodePropertiesSeparatedFromScalar;
const parseNestedBlockCollectionAfterPropertyLine = block_mapping.parseNestedBlockCollectionAfterPropertyLine;
const parseCompactExplicitBlockMappingNode = block_mapping.parseCompactExplicitBlockMappingNode;
const parseCompactPlainBlockMappingNode = block_mapping.parseCompactPlainBlockMappingNode;
const parseNestedPlainBlockMappingNode = block_mapping.parseNestedPlainBlockMappingNode;

pub const PlainSequenceDocumentTokens = struct {
    items: []const PlainBlockNode,
    properties: NodeProperties = .{},
    directives: TokenDirectives = .{},
    explicit_start: bool = false,
    explicit_end: bool = false,
    force_document_start: bool = false,
    content_same_line: bool = false,
    content_same_line_separated_by_tab: bool = false,
};

pub fn parsePlainBlockSequenceDocumentTokens(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
) Error!?PlainSequenceDocumentTokens {
    return parsePlainBlockSequenceDocumentTokenRange(allocator, tokens, 1, tokens.len - 1);
}

pub fn parsePlainBlockSequenceDocumentTokenRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
) Error!?PlainSequenceDocumentTokens {
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

    var items: std.ArrayList(PlainBlockNode) = .empty;

    var explicit_end = false;
    var sequence_indent: ?usize = null;
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
        const item_indent: usize = indent: {
            if (content_same_line and sequence_indent == null and tokens[index] == .block_sequence_entry) {
                entry_started_same_line = true;
                sequence_indent = 0;
                break :indent 0;
            }
            if (tokens[index] != .indent) return null;
            if (sequence_indent) |expected_indent| {
                if (tokens[index].indent != expected_indent) {
                    if (content_same_line) return ParseError.InvalidSyntax;
                    return null;
                }
            } else {
                sequence_indent = tokens[index].indent;
            }
            const current_indent = tokens[index].indent;
            index += 1;
            break :indent current_indent;
        };

        if (index >= end or tokens[index] != .block_sequence_entry) return null;
        index += 1;
        skipComments(tokens, &index, end);

        const properties = try consumeNodeProperties(allocator, tokens, &index, end, directives);
        try validateNodePropertiesSeparatedFromScalar(properties, tokens, index, end);
        skipComments(tokens, &index, end);
        const item: PlainBlockNode = if (try parseCompactExplicitBlockMappingNode(allocator, tokens, &index, end, item_indent, properties, directives, 0, true)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockSequenceNode(allocator, tokens, &index, end, item_indent, properties, directives, 0)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockMappingNode(allocator, tokens, &index, end, item_indent, properties, directives, 0)) |node| value: {
            break :value node;
        } else if (index < end and tokens[index] == .scalar) value: {
            const scalar = tokens[index].scalar;
            if (!isBlockSequenceItemScalar(scalar)) return null;
            const continuation_boundary_indent = if (entry_started_same_line) std.math.maxInt(usize) else item_indent;
            var parsed = if (try parsePlainBlockSequenceItemScalarTokenRun(allocator, tokens, &index, end, continuation_boundary_indent)) |plain|
                plain
            else value_scalar: {
                const parsed_scalar = try parseScalarToken(allocator, scalar);
                index += 1;
                break :value_scalar parsed_scalar;
            };
            parsed.anchor = properties.anchor;
            parsed.tag = properties.tag;
            break :value .{ .scalar = parsed };
        } else if (index < end and tokens[index] == .block_scalar) value: {
            var scalar = try parseBlockScalarToken(allocator, tokens[index].block_scalar, item_indent);
            scalar.anchor = properties.anchor;
            scalar.tag = properties.tag;
            index += 1;
            break :value .{ .scalar = scalar };
        } else if (index < end and tokens[index] == .alias) value: {
            if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
            const alias = try allocator.dupe(u8, tokens[index].alias);
            index += 1;
            try validateAliasHasNoFollowingContent(tokens, index, end, item_indent);
            break :value .{ .alias = alias };
        } else if (index < end and isFlowStartToken(tokens[index])) value: {
            try validateFlowContinuationIndent(tokens, index, end, item_indent);
            if (try parseFlowPlainBlockNode(allocator, tokens, &index, end, properties, directives)) |node| {
                break :value node;
            }
            return null;
        } else if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, &index, end, item_indent, properties, directives)) |node| value: {
            break :value node;
        } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, &index, end, item_indent, properties, directives, 0)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, &index, end, item_indent, properties, directives, 0)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, &index, end, item_indent, properties, directives, 0)) |node| value: {
            break :value node;
        } else if (isPlainBlockOmittedValueBoundary(tokens, index, end)) value: {
            break :value .{ .scalar = .{
                .value = try allocator.dupe(u8, ""),
                .anchor = properties.anchor,
                .tag = properties.tag,
            } };
        } else {
            return null;
        };

        try items.append(allocator, item);
    }

    if (items.items.len == 0 or index != end) return null;
    return .{
        .items = try items.toOwnedSlice(allocator),
        .properties = collection_properties,
        .directives = directives,
        .explicit_start = explicit_start,
        .explicit_end = explicit_end,
        .force_document_start = flowCollectionDescendantSpansLines(tokens[start..end]),
        .content_same_line = content_same_line,
        .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
    };
}

pub fn parseCompactPlainBlockSequenceNode(
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
    if (index.* >= end or tokens[index.*] != .block_sequence_entry) return null;
    if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
    if (depth >= max_block_depth) return ParseError.Unsupported;
    index.* += 1;

    const default_sequence_indent = parent_indent + 2;
    var items: std.ArrayList(PlainBlockNode) = .empty;

    const first_item = (try parsePlainBlockSequenceItemAfterIndicator(
        allocator,
        tokens,
        index,
        end,
        default_sequence_indent,
        default_sequence_indent,
        .{},
        directives,
        depth + 1,
    )) orelse {
        index.* = start;
        return noCompactPlainBlockSequenceNode();
    };
    try items.append(allocator, first_item);

    const sequence_indent = inferredCompactSequenceIndent(tokens, index.*, end, parent_indent) orelse default_sequence_indent;

    while (index.* < end) {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] == .document_end) break;

        if (tokens[index.*] != .indent or tokens[index.*].indent != sequence_indent) break;
        const line_start = index.*;
        index.* += 1;

        if (index.* >= end or tokens[index.*] != .block_sequence_entry) {
            index.* = line_start;
            break;
        }
        index.* += 1;
        skipComments(tokens, index, end);

        const item_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        try validateNodePropertiesSeparatedFromScalar(item_properties, tokens, index.*, end);
        skipComments(tokens, index, end);
        const item = (try parsePlainBlockSequenceItemAfterIndicator(
            allocator,
            tokens,
            index,
            end,
            sequence_indent,
            sequence_indent,
            item_properties,
            directives,
            depth + 1,
        )) orelse {
            index.* = start;
            return null;
        };
        try items.append(allocator, item);
    }

    return .{ .sequence = .{
        .items = try items.toOwnedSlice(allocator),
        .properties = properties,
    } };
}

fn noCompactPlainBlockSequenceNode() ?PlainBlockNode {
    return null;
}

pub fn inferredCompactSequenceIndent(tokens: []const scanner.Token, start: usize, end: usize, parent_indent: usize) ?usize {
    var index = start;
    skipComments(tokens, &index, end);
    if (index + 1 >= end or tokens[index] != .indent or tokens[index + 1] != .block_sequence_entry) return null;
    const indent = tokens[index].indent;
    if (indent <= parent_indent) return null;
    return indent;
}

pub fn parsePlainBlockSequenceItemAfterIndicator(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    item_indent: usize,
    sequence_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
    depth: usize,
) Error!?PlainBlockNode {
    if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, sequence_indent, properties, directives, depth, true)) |node| {
        return node;
    }

    if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, item_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (try parseCompactPlainBlockMappingNode(allocator, tokens, index, end, item_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (index.* < end and tokens[index.*] == .scalar) {
        const scalar = tokens[index.*].scalar;
        if (!isBlockSequenceItemScalar(scalar)) return null;
        try validateBlockFlowScalarToken(scalar, 1);
        var parsed = if (isPlainScalarToken(scalar))
            (try parsePlainScalarTokenRun(allocator, tokens, index, end)) orelse return null
        else value: {
            index.* += 1;
            break :value try parseScalarToken(allocator, scalar);
        };
        parsed.anchor = properties.anchor;
        parsed.tag = properties.tag;
        return .{ .scalar = parsed };
    }

    if (index.* < end and tokens[index.*] == .block_scalar) {
        var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, item_indent);
        scalar.anchor = properties.anchor;
        scalar.tag = properties.tag;
        index.* += 1;
        return .{ .scalar = scalar };
    }

    if (index.* < end and tokens[index.*] == .alias) {
        if (hasNodeProperties(properties)) return ParseError.InvalidSyntax;
        const alias = try allocator.dupe(u8, tokens[index.*].alias);
        index.* += 1;
        try validateAliasHasNoFollowingContent(tokens, index.*, end, sequence_indent);
        return .{ .alias = alias };
    }

    if (index.* < end and isFlowStartToken(tokens[index.*])) {
        try validateFlowContinuationIndent(tokens, index.*, end, item_indent);
    }
    if (try parseFlowPlainBlockNode(allocator, tokens, index, end, properties, directives)) |node| {
        return node;
    }

    if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, index, end, item_indent, properties, directives)) |node| {
        return node;
    }

    if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, item_indent, properties, directives, depth)) |node| {
        return node;
    }

    if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, sequence_indent)) {
        return .{ .scalar = .{
            .value = try allocator.dupe(u8, ""),
            .anchor = properties.anchor,
            .tag = properties.tag,
        } };
    }

    return null;
}

pub fn parseIndentedPlainBlockSequenceItemNode(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    item_indent: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!?PlainBlockNode {
    const start = index.*;
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= item_indent) return null;

    const node_indent = tokens[index.*].indent;
    const node_start = index.* + 1;
    if (node_start >= end) return null;
    if (nodePropertyLineStartsNestedBlockMappingKey(tokens, node_start, end)) return null;
    switch (tokens[node_start]) {
        .block_sequence_entry, .block_mapping_key => return null,
        .scalar => {
            if (node_start + 1 < end and tokens[node_start + 1] == .block_mapping_value) return null;
        },
        else => {},
    }

    index.* += 1;

    var node_properties = properties;
    const line_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
    try mergeNodeProperties(&node_properties, line_properties);
    try validateNodePropertiesSeparatedFromScalar(node_properties, tokens, index.*, end);
    if (hasNodeProperties(node_properties) and isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, item_indent)) {
        return try emptyScalarNode(allocator, node_properties);
    }

    if (index.* < end and tokens[index.*] == .scalar) {
        const scalar = tokens[index.*].scalar;
        if (!isBlockSequenceItemScalar(scalar)) {
            index.* = start;
            return null;
        }
        try validateBlockFlowScalarToken(scalar, node_indent);
        var parsed = if (try parsePlainBlockSequenceItemScalarTokenRun(allocator, tokens, index, end, item_indent)) |plain|
            plain
        else value_scalar: {
            const parsed_scalar = try parseScalarToken(allocator, scalar);
            index.* += 1;
            break :value_scalar parsed_scalar;
        };
        parsed.anchor = node_properties.anchor;
        parsed.tag = node_properties.tag;
        return .{ .scalar = parsed };
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
        try validateAliasHasNoFollowingContent(tokens, index.*, end, item_indent);
        return .{ .alias = alias };
    }

    if (index.* < end and isFlowStartToken(tokens[index.*])) {
        try validateFlowContinuationIndent(tokens, index.*, end, item_indent);
    }
    if (try parseFlowPlainBlockNode(allocator, tokens, index, end, node_properties, directives)) |node| {
        return node;
    }

    index.* = start;
    return null;
}

pub fn parseIndentlessPlainBlockSequenceNode(
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
    if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent != parent_indent) return null;
    if (depth >= max_block_depth) return ParseError.Unsupported;

    const sequence_indent = parent_indent;
    var items: std.ArrayList(PlainBlockNode) = .empty;

    while (index.* < end) {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] == .document_end) break;

        if (tokens[index.*] != .indent) {
            index.* = start;
            return null;
        }

        const line_start = index.*;
        const item_indent = tokens[index.*].indent;
        if (item_indent < sequence_indent) break;
        if (item_indent != sequence_indent) {
            index.* = start;
            return null;
        }
        index.* += 1;

        if (index.* >= end or tokens[index.*] != .block_sequence_entry) {
            if (items.items.len > 0) {
                index.* = line_start;
                break;
            }
            index.* = start;
            return null;
        }
        index.* += 1;
        skipComments(tokens, index, end);

        const item_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        try validateNodePropertiesSeparatedFromScalar(item_properties, tokens, index.*, end);
        skipComments(tokens, index, end);
        const item: PlainBlockNode = if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1, true)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (index.* < end and tokens[index.*] == .scalar) value: {
            const scalar = tokens[index.*].scalar;
            if (!isBlockSequenceItemScalar(scalar)) {
                index.* = start;
                return null;
            }
            try validateBlockFlowScalarToken(scalar, 1);
            var parsed = if (try parsePlainBlockSequenceItemScalarTokenRun(allocator, tokens, index, end, sequence_indent)) |plain|
                plain
            else value_scalar: {
                const parsed_scalar = try parseScalarToken(allocator, scalar);
                index.* += 1;
                break :value_scalar parsed_scalar;
            };
            parsed.anchor = item_properties.anchor;
            parsed.tag = item_properties.tag;
            break :value .{ .scalar = parsed };
        } else if (index.* < end and tokens[index.*] == .block_scalar) value: {
            var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, item_indent);
            scalar.anchor = item_properties.anchor;
            scalar.tag = item_properties.tag;
            index.* += 1;
            break :value .{ .scalar = scalar };
        } else if (index.* < end and tokens[index.*] == .alias) value: {
            if (hasNodeProperties(item_properties)) return ParseError.InvalidSyntax;
            const alias = try allocator.dupe(u8, tokens[index.*].alias);
            index.* += 1;
            try validateAliasHasNoFollowingContent(tokens, index.*, end, item_indent);
            break :value .{ .alias = alias };
        } else if (index.* < end and isFlowStartToken(tokens[index.*])) value: {
            try validateFlowContinuationIndent(tokens, index.*, end, item_indent);
            if (try parseFlowPlainBlockNode(allocator, tokens, index, end, item_properties, directives)) |node| {
                break :value node;
            }
            index.* = start;
            return null;
        } else if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, index, end, item_indent, item_properties, directives)) |node| value: {
            break :value node;
        } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, sequence_indent)) value: {
            break :value .{ .scalar = .{
                .value = try allocator.dupe(u8, ""),
                .anchor = item_properties.anchor,
                .tag = item_properties.tag,
            } };
        } else {
            index.* = start;
            return null;
        };

        try items.append(allocator, item);
    }

    if (items.items.len == 0) {
        index.* = start;
        return null;
    }

    return .{ .sequence = .{
        .items = try items.toOwnedSlice(allocator),
        .properties = properties,
    } };
}

pub fn parseNestedPlainBlockSequenceNode(
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

    const sequence_indent = tokens[index.*].indent;
    var items: std.ArrayList(PlainBlockNode) = .empty;

    while (index.* < end) {
        skipComments(tokens, index, end);
        if (index.* >= end or tokens[index.*] == .document_end) break;

        if (tokens[index.*] != .indent) {
            index.* = start;
            return null;
        }

        const item_indent = tokens[index.*].indent;
        if (item_indent < sequence_indent) break;
        if (item_indent != sequence_indent) {
            index.* = start;
            return null;
        }
        index.* += 1;

        if (index.* >= end or tokens[index.*] != .block_sequence_entry) {
            index.* = start;
            return null;
        }
        index.* += 1;
        skipComments(tokens, index, end);

        const item_properties = try consumeNodeProperties(allocator, tokens, index, end, directives);
        try validateNodePropertiesSeparatedFromScalar(item_properties, tokens, index.*, end);
        skipComments(tokens, index, end);
        const item: PlainBlockNode = if (try parseCompactExplicitBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1, true)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockSequenceNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseCompactPlainBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (index.* < end and tokens[index.*] == .scalar) value: {
            const scalar = tokens[index.*].scalar;
            if (!isBlockSequenceItemScalar(scalar)) {
                index.* = start;
                return null;
            }
            try validateBlockFlowScalarToken(scalar, 1);
            var parsed = if (try parsePlainBlockSequenceItemScalarTokenRun(allocator, tokens, index, end, sequence_indent)) |plain|
                plain
            else value_scalar: {
                const parsed_scalar = try parseScalarToken(allocator, scalar);
                index.* += 1;
                break :value_scalar parsed_scalar;
            };
            parsed.anchor = item_properties.anchor;
            parsed.tag = item_properties.tag;
            break :value .{ .scalar = parsed };
        } else if (index.* < end and tokens[index.*] == .block_scalar) value: {
            var scalar = try parseBlockScalarToken(allocator, tokens[index.*].block_scalar, item_indent);
            scalar.anchor = item_properties.anchor;
            scalar.tag = item_properties.tag;
            index.* += 1;
            break :value .{ .scalar = scalar };
        } else if (index.* < end and tokens[index.*] == .alias) value: {
            if (hasNodeProperties(item_properties)) return ParseError.InvalidSyntax;
            const alias = try allocator.dupe(u8, tokens[index.*].alias);
            index.* += 1;
            try validateAliasHasNoFollowingContent(tokens, index.*, end, item_indent);
            break :value .{ .alias = alias };
        } else if (index.* < end and isFlowStartToken(tokens[index.*])) value: {
            try validateFlowContinuationIndent(tokens, index.*, end, item_indent);
            if (try parseFlowPlainBlockNode(allocator, tokens, index, end, item_properties, directives)) |node| {
                break :value node;
            }
            index.* = start;
            return null;
        } else if (try parseIndentedPlainBlockSequenceItemNode(allocator, tokens, index, end, item_indent, item_properties, directives)) |node| value: {
            break :value node;
        } else if (try parseNestedBlockCollectionAfterPropertyLine(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockSequenceNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (try parseNestedPlainBlockMappingNode(allocator, tokens, index, end, item_indent, item_properties, directives, depth + 1)) |node| value: {
            break :value node;
        } else if (isPlainBlockOmittedValueBoundaryAtIndent(tokens, index.*, end, sequence_indent)) value: {
            break :value .{ .scalar = .{
                .value = try allocator.dupe(u8, ""),
                .anchor = item_properties.anchor,
                .tag = item_properties.tag,
            } };
        } else {
            index.* = start;
            return null;
        };

        try items.append(allocator, item);
    }

    if (items.items.len == 0) {
        index.* = start;
        return null;
    }

    return .{ .sequence = .{
        .items = try items.toOwnedSlice(allocator),
        .properties = properties,
    } };
}

test "parser block sequence entry: compact sequence stops before non-entry indented line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = [_]scanner.Token{
        .block_sequence_entry,
        .{ .scalar = "first" },
        .{ .indent = 2 },
        .{ .tag = "!leftover" },
    };
    var index: usize = 0;

    const node = (try parseCompactPlainBlockSequenceNode(
        arena.allocator(),
        &tokens,
        &index,
        tokens.len,
        0,
        .{},
        .{},
        0,
    )).?;

    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expect(node == .sequence);
    try std.testing.expectEqual(@as(usize, 1), node.sequence.items.len);
    try std.testing.expect(node.sequence.items[0] == .scalar);
    try std.testing.expectEqualStrings("first", node.sequence.items[0].scalar.value);
}

test "parser block sequence entry: compact sequence resets after invalid later item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = [_]scanner.Token{
        .block_sequence_entry,
        .{ .scalar = "first" },
        .{ .indent = 2 },
        .block_sequence_entry,
        .flow_sequence_end,
    };
    var index: usize = 0;

    const node = try parseCompactPlainBlockSequenceNode(
        arena.allocator(),
        &tokens,
        &index,
        tokens.len,
        0,
        .{},
        .{},
        0,
    );

    try std.testing.expect(node == null);
    try std.testing.expectEqual(@as(usize, 0), index);
}

test "parser block sequence entry: indented bare entry marker is not scalar content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = [_]scanner.Token{
        .{ .indent = 4 },
        .{ .scalar = "-" },
    };
    var index: usize = 0;

    const node = try parseIndentedPlainBlockSequenceItemNode(
        arena.allocator(),
        &tokens,
        &index,
        tokens.len,
        2,
        .{},
        .{},
    );

    try std.testing.expect(node == null);
    try std.testing.expectEqual(@as(usize, 0), index);
}
