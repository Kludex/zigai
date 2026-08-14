//! Purpose: Parse scanner tokens into YAML events.
//! Owns: Direct token-consuming parser state and event construction.
//! Does not own: Scanning, schema resolution, loading, or emitting.
//! Depends on: scanner/scanner.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
pub const scanner = @import("../scanner/scanner.zig");
pub const types = @import("event.zig");
const internal = @import("internal.zig");
const implicit_key = internal;
const flow = @import("flow.zig");
const document = @import("document.zig");
const scalar_parser = @import("scalar.zig");
const token_cursor = internal;
const block_sequence = @import("block_sequence.zig");
const block_mapping = @import("block_mapping.zig");
const common_limit = @import("../common/limit.zig");
const simple_fast_path = @import("simple_fast_path.zig");

pub const Error = types.Error;
pub const Event = types.Event;
pub const EventBuilder = internal.EventBuilder;
pub const EventStats = internal.EventStats;
pub const EventStream = types.EventStream;
pub const ParseError = types.ParseError;
pub const max_block_depth: usize = common_limit.max_parse_collection_depth;
pub const NodeProperties = internal.NodeProperties;
pub const TokenDirectives = internal.TokenDirectives;
pub const PlainBlockNode = internal.PlainBlockNode;
pub const PlainBlockPair = internal.PlainBlockPair;
pub const ScalarDocumentTokens = scalar_parser.ScalarDocumentTokens;
pub const appendCompactExplicitBlockMappingPair = internal.appendCompactExplicitBlockMappingPair;
pub const appendPlainBlockNodeEvent = internal.appendEvent;
pub const appendDocumentEndSeparatedStreamEvents = document.appendDocumentEndSeparatedStreamEvents;
pub const appendExplicitDocumentStreamEvents = document.appendExplicitDocumentStreamEvents;
pub const appendImplicitDocumentStartSeparatedStreamEvents = document.appendImplicitDocumentStartSeparatedStreamEvents;
pub const parseAliasDocumentTokens = scalar_parser.parseAliasTokens;
const parseAliasDocumentTokenRange = scalar_parser.parseAliasTokenRange;
pub const appendNodeEvents = flow.appendNodeEvents;
pub const appendMappingNodeEvents = flow.appendMappingNodeEvents;
pub const parseFlowMappingDocumentTokens = flow.parseMappingTokens;
const parseFlowMappingDocumentTokenRange = flow.parseMappingTokenRange;
pub const parseFlowPlainBlockNode = internal.parseFlowPlainBlockNode;
pub const parseFlowSequenceDocumentTokens = flow.parseSequenceTokens;
const parseFlowSequenceDocumentTokenRange = flow.parseSequenceTokenRange;
pub const parseScalarDocumentTokens = scalar_parser.parseScalarTokens;
const parseScalarDocumentTokenRange = scalar_parser.parseScalarTokenRange;
pub const consumeBlockCollectionProperties = internal.consumeBlockCollectionProperties;
pub const compactBlockSequenceEntryHasSameLineContent = internal.compactBlockSequenceEntryHasSameLineContent;
pub const consumeNestedBlockCollectionPropertyLine = internal.consumeNestedBlockCollectionPropertyLine;
pub const isBareBlockSequenceEntryScalar = scalar_parser.isBareBlockSequenceEntryScalar;
pub const isBlockSequenceItemScalar = scalar_parser.isBlockSequenceItemScalar;
pub const isFlowIndicatorOrTag = scalar_parser.isFlowIndicatorOrTag;
pub const isPlainScalarContinuationToken = scalar_parser.isPlainScalarContinuationToken;
pub const isPlainScalarToken = scalar_parser.isPlainScalarToken;
pub const isTabSeparatedCompactMappingStart = scalar_parser.isTabSeparatedCompactMappingStart;
pub const parseBlockScalarToken = scalar_parser.parseBlockScalarToken;
pub const parseBlockScalarTokenAt = scalar_parser.parseBlockScalarTokenAt;
pub const parsePlainBlockSequenceItemScalarTokenRun = scalar_parser.parsePlainBlockSequenceItemScalarTokenRun;
pub const parsePlainScalarTokenRun = scalar_parser.parsePlainScalarTokenRun;
pub const parsePlainScalarTokenRunWithIndentedContinuations = scalar_parser.parsePlainScalarTokenRunWithIndentedContinuations;
pub const parseScalarToken = scalar_parser.parseScalarToken;
pub const scalarTokenSpansLines = scalar_parser.scalarTokenSpansLines;
pub const consumeLeadingDirectives = internal.consumeLeadingDirectives;
pub const consumeNodeProperties = internal.consumeNodeProperties;
pub const consumeDocumentStartContent = token_cursor.consumeDocumentStartContent;
pub const emptyScalarNode = internal.emptyScalar;
pub const flowCollectionAtStartSpansLines = token_cursor.flowCollectionAtStartSpansLines;
pub const flowCollectionDescendantSpansLines = token_cursor.flowCollectionDescendantSpansLines;
pub const hasNodeProperties = internal.has;
pub const indentlessBlockSequenceStartsAtIndent = internal.indentlessBlockSequenceStartsAtIndent;
pub const isExplicitBlockMappingValueBoundary = token_cursor.isExplicitBlockMappingValueBoundary;
pub const isFlowStartToken = token_cursor.isFlowStartToken;
pub const isPlainBlockOmittedValueBoundary = token_cursor.isPlainBlockOmittedValueBoundary;
pub const isPlainBlockOmittedValueBoundaryAtIndent = token_cursor.isPlainBlockOmittedValueBoundaryAtIndent;
pub const isNestedBlockCollectionStart = internal.isNestedBlockCollectionStart;
pub const isSingleIndicatorScalarKeyBeforeValue = internal.isSingleIndicatorScalarKeyBeforeValue;
pub const mergeNodeProperties = internal.merge;
pub const multilineScalarCandidateHasNoImmediateMappingValue = internal.multilineScalarCandidateHasNoImmediateMappingValue;
pub const nodePropertyLineStartsNestedBlockMappingKey = internal.nodePropertyLineStartsNestedBlockMappingKey;
pub const parsePropertyOnlyEmptyBlockScalarNode = internal.parsePropertyOnlyEmptyBlockScalarNode;
pub const scalarTokenRunStartsBlockMappingKey = internal.scalarTokenRunStartsBlockMappingKey;
pub const skipComments = token_cursor.skipComments;
pub const tokenRangeSpansLines = implicit_key.tokenRangeSpansLines;
pub const validateAliasFlowCollectionSeparation = token_cursor.validateAliasFlowCollectionSeparation;
pub const validateAliasHasNoFollowingContent = internal.validateAliasHasNoFollowingContent;
pub const validateBlockFlowScalarToken = scalar_parser.validateBlockFlowScalarToken;
pub const validateExplicitMappingAliasKeyHasNoFollowingContent = internal.validateExplicitMappingAliasKeyHasNoFollowingContent;
pub const validateFlowContinuationIndent = token_cursor.validateFlowContinuationIndent;
pub const validateImplicitAliasKeyLength = implicit_key.validateImplicitAliasKeyLength;
pub const validateImplicitScalarKeyLength = implicit_key.validateImplicitScalarKeyLength;
pub const validateImplicitTokenKeyLength = implicit_key.validateImplicitTokenKeyLength;
pub const validateNodePropertiesSeparatedFromScalar = internal.validateNodePropertiesSeparatedFromScalar;
pub const parseCompactPlainBlockSequenceNode = block_sequence.parseCompactPlainBlockSequenceNode;
pub const inferredCompactSequenceIndent = block_sequence.inferredCompactSequenceIndent;
pub const parsePlainBlockSequenceItemAfterIndicator = block_sequence.parsePlainBlockSequenceItemAfterIndicator;
pub const parseIndentedPlainBlockSequenceItemNode = block_sequence.parseIndentedPlainBlockSequenceItemNode;
pub const PlainSequenceDocumentTokens = block_sequence.PlainSequenceDocumentTokens;
pub const parsePlainBlockSequenceDocumentTokens = block_sequence.parsePlainBlockSequenceDocumentTokens;
const parsePlainBlockSequenceDocumentTokenRange = block_sequence.parsePlainBlockSequenceDocumentTokenRange;
pub const parseIndentlessPlainBlockSequenceNode = block_sequence.parseIndentlessPlainBlockSequenceNode;
pub const parseNestedPlainBlockSequenceNode = block_sequence.parseNestedPlainBlockSequenceNode;
pub const parsePlainBlockMappingKeyNode = block_mapping.parsePlainBlockMappingKeyNode;
pub const parseExplicitBlockMappingScalarKeyNode = block_mapping.parseExplicitBlockMappingScalarKeyNode;
pub const parseIndentedExplicitBlockMappingScalarKeyNode = block_mapping.parseIndentedExplicitBlockMappingScalarKeyNode;
pub const parseIndentedExplicitBlockMappingBlockScalarKeyNode = block_mapping.parseIndentedExplicitBlockMappingBlockScalarKeyNode;
pub const parseIndentedExplicitBlockMappingFlowKeyNode = block_mapping.parseIndentedExplicitBlockMappingFlowKeyNode;
pub const parseIndentedExplicitBlockMappingAliasKeyNode = block_mapping.parseIndentedExplicitBlockMappingAliasKeyNode;
pub const parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode = block_mapping.parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode;
pub const MultilineScalarKeyBehavior = block_mapping.MultilineScalarKeyBehavior;
pub const parsePlainBlockMappingScalarKey = block_mapping.parsePlainBlockMappingScalarKey;
pub const multilinePlainScalarKeyBeforeValue = block_mapping.multilinePlainScalarKeyBeforeValue;
pub const parseIndentedPlainBlockMappingValueNode = block_mapping.parseIndentedPlainBlockMappingValueNode;
pub const parsePlainBlockMappingValueNode = block_mapping.parsePlainBlockMappingValueNode;
pub const parseNestedBlockCollectionAfterPropertyLine = block_mapping.parseNestedBlockCollectionAfterPropertyLine;
pub const parseCompactExplicitBlockMappingNode = block_mapping.parseCompactExplicitBlockMappingNode;
pub const isCompactExplicitOmittedKeyBoundary = block_mapping.isCompactExplicitOmittedKeyBoundary;
pub const parseCompactExplicitBlockMappingKeyNode = block_mapping.parseCompactExplicitBlockMappingKeyNode;
pub const parseCompactPlainBlockMappingNode = block_mapping.parseCompactPlainBlockMappingNode;
pub const PlainMappingDocumentTokens = block_mapping.PlainMappingDocumentTokens;
pub const parsePlainBlockMappingDocumentTokens = block_mapping.parsePlainBlockMappingDocumentTokens;
const parsePlainBlockMappingDocumentTokenRange = block_mapping.parsePlainBlockMappingDocumentTokenRange;
pub const parseNestedPlainBlockMappingNode = block_mapping.parseNestedPlainBlockMappingNode;

pub const DocumentRootClass = enum {
    fallback,
    empty,
    scalar,
    alias,
    block_sequence,
    block_mapping,
    flow_sequence,
    flow_mapping,
};

pub const ParsedEventStream = struct {
    stream: EventStream,
    stats: EventStats,
};

pub fn classifyDocumentRoot(tokens: []const scanner.Token) DocumentRootClass {
    if (tokens.len < 2) return .fallback;
    if (tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return .fallback;

    return classifyDocumentRootRange(tokens, 1, tokens.len - 1);
}

fn classifyDocumentRootRange(tokens: []const scanner.Token, start: usize, end: usize) DocumentRootClass {
    var index: usize = start;
    skipComments(tokens, &index, end);
    if (index == end) return .empty;
    if (tokens[index] == .document_end) {
        index += 1;
        skipComments(tokens, &index, end);
        return if (index == end) .empty else .fallback;
    }
    if (tokens[index] == .directive) return .fallback;

    if (tokens[index] == .document_start) {
        index += 1;
        _ = consumeDocumentStartContent(tokens, &index, end);
    }

    if (hasStreamControl(tokens[index..end])) return .fallback;
    return classifySingleDocumentRoot(tokens, index, end);
}

/// Parses scanner tokens into a YAML event stream.
///
/// This is the public parser path. It handles stream/document framing, block
/// and flow collection roots, scalar and alias roots, directives, node
/// properties, and comments. Unsupported token shapes return `Unsupported`.
pub fn parseTokens(allocator: std.mem.Allocator, tokens: []const scanner.Token) Error!EventStream {
    const parsed = try parseTokensWithStats(allocator, tokens);
    return parsed.stream;
}

pub fn parseTokensWithStats(allocator: std.mem.Allocator, tokens: []const scanner.Token) Error!ParsedEventStream {
    if (tokens.len < 2) return ParseError.InvalidSyntax;
    if (tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return ParseError.InvalidSyntax;
    try validateAliasFlowCollectionSeparation(tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const root_class = classifyDocumentRoot(tokens);

    const parsed = if (shouldTryRootClass(root_class, .scalar))
        parseScalarDocumentTokens(arena_allocator, tokens) catch |err| switch (err) {
            ParseError.Unsupported => ScalarDocumentTokens{ .scalar = null },
            else => return err,
        }
    else
        ScalarDocumentTokens{ .scalar = null };

    var events: EventBuilder = .{};
    try events.ensureTotalCapacity(arena_allocator, @min(tokens.len, 32));

    try events.append(arena_allocator, .stream_start);

    var content_index: usize = 1;
    skipComments(tokens, &content_index, tokens.len - 1);
    if (content_index == tokens.len - 1) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }
    if (tokens[content_index] == .document_end) {
        content_index += 1;
        skipComments(tokens, &content_index, tokens.len - 1);
        if (content_index == tokens.len - 1) {
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (parsed.scalar) |scalar| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = parsed.explicit_start,
            .yaml_version = parsed.directives.yaml_version,
            .tag_directives = parsed.directives.tag_directives,
            .has_reserved_directive = parsed.directives.has_reserved_directive,
            .content_same_line = parsed.content_same_line,
            .content_same_line_separated_by_tab = parsed.content_same_line_separated_by_tab,
        } });
        try events.append(arena_allocator, .{ .scalar = scalar });
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = parsed.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (shouldTryRootClass(root_class, .alias)) {
        if (try parseAliasDocumentTokens(arena_allocator, tokens)) |alias| {
            try events.append(arena_allocator, .{ .document_start = .{
                .explicit = alias.explicit_start,
                .yaml_version = alias.directives.yaml_version,
                .tag_directives = alias.directives.tag_directives,
                .has_reserved_directive = alias.directives.has_reserved_directive,
                .content_same_line = alias.content_same_line,
                .content_same_line_separated_by_tab = alias.content_same_line_separated_by_tab,
            } });
            try events.append(arena_allocator, .{ .alias = alias.value });
            try events.append(arena_allocator, .{ .document_end = .{ .explicit = alias.explicit_end } });
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (root_class == .fallback and try appendImplicitDocumentStartSeparatedStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (root_class == .fallback and try appendDocumentEndSeparatedStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (root_class == .fallback and try appendExplicitDocumentStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (shouldTryRootClass(root_class, .block_sequence)) {
        if (try simple_fast_path.appendBlockSequenceDocumentEvents(arena_allocator, tokens, &events)) {
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }

        if (try parsePlainBlockSequenceDocumentTokens(arena_allocator, tokens)) |sequence| {
            try events.append(arena_allocator, .{ .document_start = .{
                .explicit = sequence.explicit_start,
                .force_document_start = sequence.force_document_start,
                .yaml_version = sequence.directives.yaml_version,
                .tag_directives = sequence.directives.tag_directives,
                .has_reserved_directive = sequence.directives.has_reserved_directive,
                .content_same_line = sequence.content_same_line,
                .content_same_line_separated_by_tab = sequence.content_same_line_separated_by_tab,
            } });
            try events.append(arena_allocator, .{ .sequence_start = .{
                .style = .block,
                .anchor = sequence.properties.anchor,
                .tag = sequence.properties.tag,
            } });
            for (sequence.items) |item| {
                try appendPlainBlockNodeEvent(arena_allocator, &events, item);
            }
            try events.append(arena_allocator, .sequence_end);
            try events.append(arena_allocator, .{ .document_end = .{ .explicit = sequence.explicit_end } });
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (shouldTryRootClass(root_class, .block_mapping)) {
        if (try simple_fast_path.appendBlockMappingDocumentEvents(arena_allocator, tokens, &events)) {
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }

        if (try parsePlainBlockMappingDocumentTokens(arena_allocator, tokens)) |mapping| {
            try events.append(arena_allocator, .{ .document_start = .{
                .explicit = mapping.explicit_start,
                .force_document_start = mapping.force_document_start,
                .yaml_version = mapping.directives.yaml_version,
                .tag_directives = mapping.directives.tag_directives,
                .has_reserved_directive = mapping.directives.has_reserved_directive,
                .content_same_line = mapping.content_same_line,
                .content_same_line_separated_by_tab = mapping.content_same_line_separated_by_tab,
            } });
            try events.append(arena_allocator, .{ .mapping_start = .{
                .style = .block,
                .anchor = mapping.properties.anchor,
                .tag = mapping.properties.tag,
            } });
            for (mapping.pairs) |pair| {
                try appendPlainBlockNodeEvent(arena_allocator, &events, pair.key);
                try appendPlainBlockNodeEvent(arena_allocator, &events, pair.value);
            }
            try events.append(arena_allocator, .mapping_end);
            try events.append(arena_allocator, .{ .document_end = .{ .explicit = mapping.explicit_end } });
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (shouldTryRootClass(root_class, .flow_sequence)) {
        if (try parseFlowSequenceDocumentTokens(arena_allocator, tokens)) |sequence| {
            try events.append(arena_allocator, .{ .document_start = .{
                .explicit = sequence.explicit_start,
                .yaml_version = sequence.directives.yaml_version,
                .tag_directives = sequence.directives.tag_directives,
                .has_reserved_directive = sequence.directives.has_reserved_directive,
                .content_same_line = sequence.content_same_line,
                .content_same_line_separated_by_tab = sequence.content_same_line_separated_by_tab,
            } });
            try events.appendSlice(arena_allocator, sequence.events);
            try events.append(arena_allocator, .{ .document_end = .{ .explicit = sequence.explicit_end } });
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (shouldTryRootClass(root_class, .flow_mapping)) {
        if (try parseFlowMappingDocumentTokens(arena_allocator, tokens)) |mapping| {
            try events.append(arena_allocator, .{ .document_start = .{
                .explicit = mapping.explicit_start,
                .yaml_version = mapping.directives.yaml_version,
                .tag_directives = mapping.directives.tag_directives,
                .has_reserved_directive = mapping.directives.has_reserved_directive,
                .content_same_line = mapping.content_same_line,
                .content_same_line_separated_by_tab = mapping.content_same_line_separated_by_tab,
            } });
            try events.appendSlice(arena_allocator, mapping.events);
            try events.append(arena_allocator, .{ .document_end = .{ .explicit = mapping.explicit_end } });
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    return ParseError.Unsupported;
}

fn hasStreamControl(tokens: []const scanner.Token) bool {
    for (tokens) |token| {
        switch (token) {
            .directive, .document_start, .document_end => return true,
            else => {},
        }
    }
    return false;
}

fn classifySingleDocumentRoot(tokens: []const scanner.Token, start: usize, end: usize) DocumentRootClass {
    var index = start;
    skipComments(tokens, &index, end);
    if (index == end) return .empty;
    if (tokens[index] == .indent) {
        if (tokens[index].indent != 0) return .fallback;
        index += 1;
        skipComments(tokens, &index, end);
        if (index == end) return .empty;
    }

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
    if (index == end) return .fallback;
    if (saw_property and tokens[index] == .indent) return .fallback;

    return switch (tokens[index]) {
        .block_scalar => .scalar,
        .scalar => if (scalarRootNeedsFallback(tokens, index, end)) .fallback else if (scalarTokenRunStartsBlockMappingKey(tokens, index, end)) .block_mapping else .scalar,
        .alias => if (index + 1 < end and tokens[index + 1] == .block_mapping_value) .block_mapping else .alias,
        .block_sequence_entry => .block_sequence,
        .block_mapping_key, .block_mapping_value => .block_mapping,
        .flow_sequence_start => if (flowRootCanBeBlockMappingKey(tokens, index, end)) .fallback else .flow_sequence,
        .flow_mapping_start => if (flowRootCanBeBlockMappingKey(tokens, index, end)) .fallback else .flow_mapping,
        else => .fallback,
    };
}

fn scalarRootNeedsFallback(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .scalar => |value| {
                if (scalarTokenSpansLines(value)) return true;
                if (index != start and !isPlainScalarContinuationToken(value)) return false;
            },
            .comment => {},
            .indent => return true,
            .block_mapping_value => return false,
            else => return false,
        }
    }
    return false;
}

fn flowRootCanBeBlockMappingKey(tokens: []const scanner.Token, start: usize, end: usize) bool {
    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .flow_sequence_start, .flow_mapping_start => depth += 1,
            .flow_sequence_end, .flow_mapping_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return index + 1 < end and tokens[index + 1] == .block_mapping_value;
            },
            else => {},
        }
    }
    return false;
}

fn shouldTryRootClass(actual: DocumentRootClass, expected: DocumentRootClass) bool {
    return actual == .fallback or actual == expected;
}

fn appendSingleDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
) Error!bool {
    return document.appendSingleDocumentEvents(allocator, tokens, start, end, events, .{
        .root_class = classifyDocumentRootRange(tokens, start, end),
        .parse_scalar_document_range = parseScalarDocumentTokenRange,
        .parse_alias_document_range = parseAliasDocumentTokenRange,
        .parse_plain_block_sequence_document_range = parsePlainBlockSequenceDocumentTokenRange,
        .parse_plain_block_mapping_document_range = parsePlainBlockMappingDocumentTokenRange,
        .parse_flow_sequence_document_range = parseFlowSequenceDocumentTokenRange,
        .parse_flow_mapping_document_range = parseFlowMappingDocumentTokenRange,
        .append_plain_block_node_event = appendPlainBlockNodeEvent,
    });
}

fn finishEventStream(
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    events: *EventBuilder,
) std.mem.Allocator.Error!ParsedEventStream {
    const stats = events.stats;
    const owned_events = try events.toOwnedSlice(allocator);
    return .{
        .stream = .{
            .arena = arena.*,
            .events = owned_events,
        },
        .stats = stats,
    };
}

test "parseTokensWithStats reports private event stats" {
    var token_stream = try scanner.scan(std.testing.allocator, "[ab, c]\n");
    defer token_stream.deinit();

    var parsed = try parseTokensWithStats(std.testing.allocator, token_stream.tokens);
    defer parsed.stream.deinit();

    try std.testing.expectEqual(parsed.stream.events.len, parsed.stats.event_count);
    try std.testing.expectEqual(@as(usize, 2), parsed.stats.max_scalar_bytes);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.max_nesting_depth);
    try std.testing.expectEqual(@as(usize, 0), parsed.stats.current_nesting_depth);
    try std.testing.expect(!parsed.stats.malformed_nesting);
}

test "parseTokensWithStats reports flow sequence implicit mapping stats" {
    var token_stream = try scanner.scan(std.testing.allocator, "[plain, key: [nested], tail]\n");
    defer token_stream.deinit();

    var parsed = try parseTokensWithStats(std.testing.allocator, token_stream.tokens);
    defer parsed.stream.deinit();

    try std.testing.expectEqual(parsed.stream.events.len, parsed.stats.event_count);
    try std.testing.expectEqual(@as(usize, 6), parsed.stats.max_scalar_bytes);
    try std.testing.expectEqual(@as(usize, 3), parsed.stats.max_nesting_depth);
    try std.testing.expectEqual(@as(usize, 0), parsed.stats.current_nesting_depth);
    try std.testing.expect(!parsed.stats.malformed_nesting);
}
