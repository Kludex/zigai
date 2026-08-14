//! Purpose: Parse flow collection tokens into parser events.
//! Owns: Flow node recursion, flow sequence entries, and flow mapping pairs for the direct parser.
//! Does not own: Document framing, block-node parsing, scanning, or schema resolution.
//! Depends on: common/limit.zig, parser/internal.zig, parser/scalar.zig, scanner/scanner.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const common_limit = @import("../common/limit.zig");
const internal = @import("internal.zig");
const scalar_parser = @import("scalar.zig");
const implicit_key = internal;
const token_cursor = internal;
const scanner = @import("../scanner/scanner.zig");
const types = @import("event.zig");

const Error = types.Error;
const Event = types.Event;
const EventBuilder = internal.EventBuilder;
const ParseError = types.ParseError;
const NodeProperties = internal.NodeProperties;
const TokenDirectives = internal.TokenDirectives;

pub fn appendNodeEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    directives: TokenDirectives,
) Error!bool {
    return appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{});
}

const FlowNodeOptions = struct {
    allow_plain_indented_continuations: bool = false,
};

fn appendNodeEventsWithOptions(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    directives: TokenDirectives,
    options: FlowNodeOptions,
) Error!bool {
    if (index.* >= end) return false;
    const property_start = index.*;
    const properties = try internal.consumeNodeProperties(allocator, tokens, index, end, directives);
    const has_properties = properties.anchor != null or properties.tag != null;
    if (has_properties) token_cursor.skipFlowInsignificant(tokens, index, end);
    if (index.* >= end) {
        index.* = property_start;
        return false;
    }
    if (has_properties) {
        if (token_cursor.flowEmptyScalarBoundaryIndex(tokens, index.*, end)) |boundary| {
            index.* = boundary;
            try appendEmptyScalarWithProperties(allocator, events, properties.anchor, properties.tag);
            return true;
        }
    }

    return switch (tokens[index.*]) {
        .scalar => |value| {
            if (scalar_parser.isBareBlockSequenceEntryScalar(value)) return ParseError.InvalidSyntax;
            if (scalar_parser.scalarTokenHasInvalidPlainStart(value)) return ParseError.InvalidSyntax;
            var scalar = if (scalar_parser.isPlainFlowScalarToken(value)) value: {
                if (options.allow_plain_indented_continuations) {
                    break :value (try scalar_parser.parsePlainFlowScalarTokenRunWithContinuations(allocator, tokens, index, end)) orelse return false;
                }
                break :value (try scalar_parser.parsePlainScalarTokenRun(allocator, tokens, index, end)) orelse return false;
            } else if (scalar_parser.isQuotedScalarToken(value)) value: {
                index.* += 1;
                break :value try scalar_parser.parseScalarToken(allocator, value);
            } else return false;
            scalar.anchor = properties.anchor;
            scalar.tag = properties.tag;
            try events.append(allocator, .{ .scalar = scalar });
            return true;
        },
        .alias => |value| {
            if (has_properties) return ParseError.InvalidSyntax;
            try events.append(allocator, .{ .alias = try allocator.dupe(u8, value) });
            index.* += 1;
            try token_cursor.validateFlowAliasHasNoFollowingContent(tokens, index.*, end);
            return true;
        },
        .flow_sequence_start => {
            return try appendSequenceNodeEvents(allocator, tokens, index, end, events, depth, properties, directives);
        },
        .flow_mapping_start => {
            return try appendMappingNodeEvents(allocator, tokens, index, end, events, depth, properties, directives);
        },
        else => {
            if (has_properties) index.* = property_start;
            return false;
        },
    };
}

pub fn appendSequenceNodeEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!bool {
    if (index.* >= end or tokens[index.*] != .flow_sequence_start) return false;
    if (depth >= common_limit.max_parse_collection_depth) return ParseError.Unsupported;
    index.* += 1;

    try events.append(allocator, .{ .sequence_start = .{
        .style = .flow,
        .anchor = properties.anchor,
        .tag = properties.tag,
    } });

    token_cursor.skipFlowInsignificant(tokens, index, end);
    if (index.* < end and tokens[index.*] == .flow_sequence_end) {
        index.* += 1;
        try events.append(allocator, .sequence_end);
        return true;
    }

    while (index.* < end) {
        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (index.* < end and tokens[index.*] == .flow_entry) return ParseError.InvalidSyntax;
        if (!try appendSequenceEntryEvents(allocator, tokens, index, end, events, depth + 1, directives)) return false;

        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (index.* >= end) return false;

        switch (tokens[index.*]) {
            .flow_entry => {
                index.* += 1;
                token_cursor.skipFlowInsignificant(tokens, index, end);
                if (index.* < end and tokens[index.*] == .flow_sequence_end) {
                    index.* += 1;
                    try events.append(allocator, .sequence_end);
                    return true;
                }
            },
            .flow_sequence_end => {
                index.* += 1;
                try events.append(allocator, .sequence_end);
                return true;
            },
            else => return false,
        }
    }

    return false;
}

fn appendSequenceEntryEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    directives: TokenDirectives,
) Error!bool {
    if (index.* < end and tokens[index.*] == .flow_mapping_key) {
        return appendExplicitSequenceMappingEntryEvents(allocator, tokens, index, end, events, depth, directives);
    }

    if (index.* < end and tokens[index.*] == .flow_mapping_value) {
        index.* += 1;
        try events.append(allocator, .{ .mapping_start = .{ .style = .flow } });
        try appendEmptyScalar(allocator, events);

        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (token_cursor.isFlowSequenceEntryBoundary(tokens, index.*, end)) {
            try appendEmptyScalar(allocator, events);
        } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{
            .allow_plain_indented_continuations = true,
        })) {
            return false;
        }

        try events.append(allocator, .mapping_end);
        return true;
    }

    const key_checkpoint = events.checkpoint();
    var key_committed = false;
    errdefer if (!key_committed) events.rollback(key_checkpoint);
    const key_start = index.*;
    if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{
        .allow_plain_indented_continuations = true,
    })) {
        events.rollback(key_checkpoint);
        return false;
    }

    token_cursor.skipComments(tokens, index, end);
    if (token_cursor.flowMappingValueFollowsLineBreak(tokens, index.*, end)) return ParseError.InvalidSyntax;
    if (index.* >= end or tokens[index.*] != .flow_mapping_value) {
        key_committed = true;
        return true;
    }

    try implicit_key.validateImplicitTokenKeyLength(tokens, key_start, index.*);
    index.* += 1;
    try events.insert(allocator, key_checkpoint.len, .{ .mapping_start = .{ .style = .flow } });
    key_committed = true;

    token_cursor.skipFlowInsignificant(tokens, index, end);
    if (token_cursor.isFlowSequenceEntryBoundary(tokens, index.*, end)) {
        try appendEmptyScalar(allocator, events);
    } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{
        .allow_plain_indented_continuations = true,
    })) {
        return false;
    }
    try events.append(allocator, .mapping_end);
    return true;
}

fn appendExplicitSequenceMappingEntryEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    directives: TokenDirectives,
) Error!bool {
    if (index.* >= end or tokens[index.*] != .flow_mapping_key) return false;
    index.* += 1;

    try events.append(allocator, .{ .mapping_start = .{ .style = .flow } });

    token_cursor.skipFlowInsignificant(tokens, index, end);
    const empty_key = index.* < end and
        (tokens[index.*] == .flow_mapping_value or token_cursor.isFlowSequenceEntryBoundary(tokens, index.*, end));
    if (empty_key) {
        try appendEmptyScalar(allocator, events);
    } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{
        .allow_plain_indented_continuations = true,
    })) {
        return false;
    }

    token_cursor.skipFlowInsignificant(tokens, index, end);
    if (token_cursor.isFlowSequenceEntryBoundary(tokens, index.*, end)) {
        try appendEmptyScalar(allocator, events);
    } else {
        if (index.* >= end or tokens[index.*] != .flow_mapping_value) return false;
        index.* += 1;

        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (token_cursor.isFlowSequenceEntryBoundary(tokens, index.*, end)) {
            try appendEmptyScalar(allocator, events);
        } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth, directives, .{
            .allow_plain_indented_continuations = true,
        })) {
            return false;
        }
    }

    try events.append(allocator, .mapping_end);
    return true;
}

pub fn appendMappingNodeEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    events: *EventBuilder,
    depth: usize,
    properties: NodeProperties,
    directives: TokenDirectives,
) Error!bool {
    if (index.* >= end or tokens[index.*] != .flow_mapping_start) return false;
    if (depth >= common_limit.max_parse_collection_depth) return ParseError.Unsupported;
    index.* += 1;

    try events.append(allocator, .{ .mapping_start = .{
        .style = .flow,
        .anchor = properties.anchor,
        .tag = properties.tag,
    } });

    token_cursor.skipFlowInsignificant(tokens, index, end);
    if (index.* < end and tokens[index.*] == .flow_mapping_end) {
        index.* += 1;
        try events.append(allocator, .mapping_end);
        return true;
    }

    while (index.* < end) {
        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (index.* < end and tokens[index.*] == .flow_entry) return ParseError.InvalidSyntax;
        const explicit_key = index.* < end and tokens[index.*] == .flow_mapping_key;
        if (explicit_key) {
            index.* += 1;
            token_cursor.skipFlowInsignificant(tokens, index, end);
        }
        const child_flow_node_options: FlowNodeOptions = .{ .allow_plain_indented_continuations = true };

        const key_start = index.*;
        const empty_key = index.* < end and
            (tokens[index.*] == .flow_mapping_value or
                (explicit_key and token_cursor.isFlowMappingEmptyValueBoundary(tokens, index.*, end)));
        if (empty_key) {
            try appendEmptyScalar(allocator, events);
        } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth + 1, directives, child_flow_node_options)) {
            return false;
        }

        token_cursor.skipFlowInsignificant(tokens, index, end);
        const empty_value_boundary = token_cursor.isFlowMappingEmptyValueBoundary(tokens, index.*, end);
        if (explicit_key and empty_value_boundary) {
            try appendEmptyScalar(allocator, events);
        } else if (!explicit_key and !empty_key and empty_value_boundary) {
            try implicit_key.validateImplicitTokenKeyLength(tokens, key_start, index.*);
            try appendEmptyScalar(allocator, events);
        } else {
            if (index.* >= end or tokens[index.*] != .flow_mapping_value) return false;
            if (!explicit_key and !empty_key) try implicit_key.validateImplicitTokenKeyLength(tokens, key_start, index.*);
            index.* += 1;

            token_cursor.skipFlowInsignificant(tokens, index, end);
            if (token_cursor.isFlowMappingEmptyValueBoundary(tokens, index.*, end)) {
                try appendEmptyScalar(allocator, events);
            } else if (!try appendNodeEventsWithOptions(allocator, tokens, index, end, events, depth + 1, directives, child_flow_node_options)) {
                return false;
            }
        }

        token_cursor.skipFlowInsignificant(tokens, index, end);
        if (index.* >= end) return false;

        switch (tokens[index.*]) {
            .flow_entry => {
                index.* += 1;
                token_cursor.skipFlowInsignificant(tokens, index, end);
                if (index.* < end and tokens[index.*] == .flow_mapping_end) {
                    index.* += 1;
                    try events.append(allocator, .mapping_end);
                    return true;
                }
            },
            .flow_mapping_end => {
                index.* += 1;
                try events.append(allocator, .mapping_end);
                return true;
            },
            else => return false,
        }
    }

    return false;
}

pub const FlowNodeDocumentTokens = struct {
    events: []const Event,
    directives: TokenDirectives = .{},
    explicit_start: bool = false,
    explicit_end: bool = false,
    content_same_line: bool = false,
    content_same_line_separated_by_tab: bool = false,
};

pub fn parseSequenceTokens(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
) Error!?FlowNodeDocumentTokens {
    return parseTokens(allocator, tokens, 1, tokens.len - 1, .sequence_start);
}

pub fn parseSequenceTokenRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
) Error!?FlowNodeDocumentTokens {
    return parseTokens(allocator, tokens, start, end, .sequence_start);
}

pub fn parseMappingTokens(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
) Error!?FlowNodeDocumentTokens {
    return parseTokens(allocator, tokens, 1, tokens.len - 1, .mapping_start);
}

pub fn parseMappingTokenRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
) Error!?FlowNodeDocumentTokens {
    return parseTokens(allocator, tokens, start, end, .mapping_start);
}

const ExpectedRootEvent = enum {
    sequence_start,
    mapping_start,
};

fn parseTokens(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    expected_root: ExpectedRootEvent,
) Error!?FlowNodeDocumentTokens {
    var index: usize = start;

    if (index == end) return null;

    const directives = try internal.consumeLeadingDirectives(allocator, tokens, &index, end);
    if (index == end and directives.seen) return ParseError.InvalidSyntax;

    const explicit_start = index < end and tokens[index] == .document_start;
    if (directives.seen and !explicit_start) return ParseError.InvalidSyntax;
    if (explicit_start) index += 1;
    const document_start_content = token_cursor.consumeDocumentStartContent(tokens, &index, end);

    token_cursor.skipComments(tokens, &index, end);
    const content_same_line = document_start_content.content_same_line;
    if (explicit_start and !content_same_line and (index >= end or tokens[index] != .indent)) return null;
    if (index < end and tokens[index] == .indent) index += 1;
    token_cursor.skipComments(tokens, &index, end);

    var node_events: EventBuilder = .{};
    defer node_events.deinit(allocator);
    try node_events.ensureTotalCapacity(allocator, @min(end - index, 16));
    var properties = try internal.consumeTopLevelSeparated(allocator, tokens, &index, end, directives);
    if (!internal.has(properties)) {
        properties = try internal.consumeNodeProperties(allocator, tokens, &index, end, directives);
    }
    if (internal.has(properties)) {
        switch (expected_root) {
            .sequence_start => if (!try appendSequenceNodeEvents(allocator, tokens, &index, end, &node_events, 0, properties, directives)) return null,
            .mapping_start => if (!try appendMappingNodeEvents(allocator, tokens, &index, end, &node_events, 0, properties, directives)) return null,
        }
    } else {
        if (index >= end or !tokenMatchesRoot(tokens[index], expected_root)) return null;
        if (!try appendNodeEvents(allocator, tokens, &index, end, &node_events, 0, directives)) return null;
        if (!rootEventMatches(node_events.slice(), expected_root)) return null;
    }

    token_cursor.skipComments(tokens, &index, end);
    const explicit_end = index < end and tokens[index] == .document_end;
    if (explicit_end) {
        index += 1;
        token_cursor.skipComments(tokens, &index, end);
    }

    if (index != end) return null;
    return .{
        .events = try node_events.toOwnedSlice(allocator),
        .directives = directives,
        .explicit_start = explicit_start,
        .explicit_end = explicit_end,
        .content_same_line = content_same_line,
        .content_same_line_separated_by_tab = document_start_content.separated_by_tab,
    };
}

fn tokenMatchesRoot(token: scanner.Token, expected: ExpectedRootEvent) bool {
    return switch (expected) {
        .sequence_start => token == .flow_sequence_start,
        .mapping_start => token == .flow_mapping_start,
    };
}

fn rootEventMatches(events: []const Event, expected: ExpectedRootEvent) bool {
    if (events.len == 0) return false;
    return switch (expected) {
        .sequence_start => events[0] == .sequence_start,
        .mapping_start => events[0] == .mapping_start,
    };
}

fn appendEmptyScalar(allocator: std.mem.Allocator, events: *EventBuilder) Error!void {
    try appendEmptyScalarWithProperties(allocator, events, null, null);
}

fn appendEmptyScalarWithProperties(
    allocator: std.mem.Allocator,
    events: *EventBuilder,
    anchor: ?[]const u8,
    tag: ?[]const u8,
) Error!void {
    try events.append(allocator, .{ .scalar = .{
        .value = try allocator.dupe(u8, ""),
        .anchor = anchor,
        .tag = tag,
    } });
}
