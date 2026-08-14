//! Purpose: Split token streams into YAML document ranges and append document events.
//! Owns: Document-boundary stream traversal, document event framing, and single-document callback dispatch.
//! Does not own: Node parsing, scanner tokenization, schema resolution, or event ownership.
//! Depends on: scanner/scanner.zig, parser/internal.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const token_cursor = @import("internal.zig");
const types = @import("event.zig");

const Error = types.Error;
const Event = types.Event;
const EventBuilder = token_cursor.EventBuilder;
const ParseError = types.ParseError;
const skipComments = token_cursor.skipComments;

pub const AppendSingleDocumentFn = *const fn (
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
) Error!bool;

pub fn appendSingleDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const root_class = parsers.root_class;
    if (shouldTryDocumentParser(root_class, .scalar) and try appendScalarDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;
    if (shouldTryDocumentParser(root_class, .alias) and try appendAliasDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;
    if (shouldTryDocumentParser(root_class, .block_sequence) and try appendPlainBlockSequenceDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;
    if (shouldTryDocumentParser(root_class, .block_mapping) and try appendPlainBlockMappingDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;
    if (shouldTryDocumentParser(root_class, .flow_sequence) and try appendFlowSequenceDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;
    if (shouldTryDocumentParser(root_class, .flow_mapping) and try appendFlowMappingDocumentEvents(allocator, tokens, start, end, events, parsers)) return true;

    return false;
}

fn shouldTryDocumentParser(root_class: anytype, comptime expected: @TypeOf(root_class)) bool {
    return root_class == .fallback or root_class == expected or (root_class == .empty and expected == .scalar);
}

test "document dispatch does not allocate token wrappers before parser callbacks" {
    const tokens = [_]scanner.Token{ .stream_start, .{ .scalar = "value" }, .stream_end };
    var events: EventBuilder = .{};
    defer events.deinit(std.testing.allocator);

    const parsed = try appendSingleDocumentEvents(noAllocAllocator(), &tokens, 1, tokens.len - 1, &events, .{
        .root_class = TestRootClass.fallback,
        .parse_scalar_document_range = rejectScalarDocument,
        .parse_alias_document_range = rejectAliasDocument,
        .parse_plain_block_sequence_document_range = rejectPlainSequenceDocument,
        .parse_plain_block_mapping_document_range = rejectPlainMappingDocument,
        .parse_flow_sequence_document_range = rejectFlowDocument,
        .parse_flow_mapping_document_range = rejectFlowDocument,
        .append_plain_block_node_event = rejectAppendPlainBlockNodeEvent,
    });
    try std.testing.expect(!parsed);
    try std.testing.expectEqual(@as(usize, 0), events.slice().len);
}

test "document dispatch skips parser callbacks for classified roots" {
    const tokens = [_]scanner.Token{ .stream_start, .flow_sequence_start, .flow_sequence_end, .stream_end };
    var events: EventBuilder = .{};
    defer events.deinit(std.testing.allocator);

    const parsed = try appendSingleDocumentEvents(std.testing.allocator, &tokens, 1, tokens.len - 1, &events, .{
        .root_class = TestRootClass.flow_sequence,
        .parse_scalar_document_range = failScalarDocument,
        .parse_alias_document_range = rejectAliasDocument,
        .parse_plain_block_sequence_document_range = rejectPlainSequenceDocument,
        .parse_plain_block_mapping_document_range = rejectPlainMappingDocument,
        .parse_flow_sequence_document_range = rejectFlowDocument,
        .parse_flow_mapping_document_range = rejectFlowDocument,
        .append_plain_block_node_event = rejectAppendPlainBlockNodeEvent,
    });
    try std.testing.expect(!parsed);
}

test "document dispatch preserves fallback parser order" {
    const tokens = [_]scanner.Token{ .stream_start, .flow_sequence_start, .flow_sequence_end, .stream_end };
    var events: EventBuilder = .{};
    defer events.deinit(std.testing.allocator);

    try std.testing.expectError(ParseError.InvalidSyntax, appendSingleDocumentEvents(std.testing.allocator, &tokens, 1, tokens.len - 1, &events, .{
        .root_class = TestRootClass.fallback,
        .parse_scalar_document_range = failScalarDocument,
        .parse_alias_document_range = rejectAliasDocument,
        .parse_plain_block_sequence_document_range = rejectPlainSequenceDocument,
        .parse_plain_block_mapping_document_range = rejectPlainMappingDocument,
        .parse_flow_sequence_document_range = rejectFlowDocument,
        .parse_flow_mapping_document_range = rejectFlowDocument,
        .append_plain_block_node_event = rejectAppendPlainBlockNodeEvent,
    }));
}

const TestRootClass = enum {
    fallback,
    empty,
    scalar,
    alias,
    block_sequence,
    block_mapping,
    flow_sequence,
    flow_mapping,
};

const RejectDocument = struct {
    scalar: ?types.Scalar = null,
    value: []const u8 = "",
    items: []const u8 = &.{},
    pairs: []const RejectPair = &.{},
    events: []const Event = &.{},
    properties: token_cursor.NodeProperties = .{},
    directives: token_cursor.TokenDirectives = .{},
    explicit_start: bool = false,
    explicit_end: bool = false,
    content_same_line: bool = false,
    content_same_line_separated_by_tab: bool = false,
};

const RejectPair = struct {
    key: u8 = 0,
    value: u8 = 0,
};

fn rejectScalarDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!RejectDocument {
    return ParseError.Unsupported;
}

fn failScalarDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!RejectDocument {
    return ParseError.InvalidSyntax;
}

fn rejectAliasDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!?RejectDocument {
    return null;
}

fn rejectPlainSequenceDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!?RejectDocument {
    return null;
}

fn rejectPlainMappingDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!?RejectDocument {
    return null;
}

fn rejectFlowDocument(_: std.mem.Allocator, _: []const scanner.Token, _: usize, _: usize) Error!?RejectDocument {
    return null;
}

fn rejectAppendPlainBlockNodeEvent(_: std.mem.Allocator, _: *EventBuilder, _: anytype) Error!void {
    return ParseError.Unsupported;
}

fn noAllocAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = noAlloc,
            .resize = noResize,
            .remap = noRemap,
            .free = noFree,
        },
    };
}

fn noAlloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return null;
}

fn noResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn noRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn noFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

fn appendScalarDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = parsers.parse_scalar_document_range(allocator, tokens, start, end) catch |err| switch (err) {
        ParseError.Unsupported => return false,
        else => return err,
    };

    const scalar = parsed.scalar orelse return false;
    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .scalar = scalar });
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendAliasDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_alias_document_range(allocator, tokens, start, end) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .alias = parsed.value });
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendPlainBlockSequenceDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_plain_block_sequence_document_range(allocator, tokens, start, end) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .sequence_start = .{
        .style = .block,
        .anchor = parsed.properties.anchor,
        .tag = parsed.properties.tag,
    } });
    for (parsed.items) |item| {
        try parsers.append_plain_block_node_event(allocator, events, item);
    }
    try events.append(allocator, .sequence_end);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendPlainBlockMappingDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_plain_block_mapping_document_range(allocator, tokens, start, end) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .mapping_start = .{
        .style = .block,
        .anchor = parsed.properties.anchor,
        .tag = parsed.properties.tag,
    } });
    for (parsed.pairs) |pair| {
        try parsers.append_plain_block_node_event(allocator, events, pair.key);
        try parsers.append_plain_block_node_event(allocator, events, pair.value);
    }
    try events.append(allocator, .mapping_end);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendFlowSequenceDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_flow_sequence_document_range(allocator, tokens, start, end) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.appendSlice(allocator, parsed.events);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendFlowMappingDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_flow_mapping_document_range(allocator, tokens, start, end) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.appendSlice(allocator, parsed.events);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendDocumentStart(allocator: std.mem.Allocator, events: *EventBuilder, parsed: anytype) Error!void {
    const Parsed = @TypeOf(parsed);
    try events.append(allocator, .{ .document_start = .{
        .explicit = parsed.explicit_start,
        .force_document_start = if (@hasField(Parsed, "force_document_start")) parsed.force_document_start else false,
        .yaml_version = parsed.directives.yaml_version,
        .tag_directives = parsed.directives.tag_directives,
        .has_reserved_directive = parsed.directives.has_reserved_directive,
        .content_same_line = parsed.content_same_line,
        .content_same_line_separated_by_tab = parsed.content_same_line_separated_by_tab,
    } });
}

fn appendDocumentEnd(allocator: std.mem.Allocator, events: *EventBuilder, parsed: anytype) Error!void {
    try events.append(allocator, .{ .document_end = .{ .explicit = parsed.explicit_end } });
}

pub fn appendImplicitDocumentStartSeparatedStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    const end = tokens.len - 1;
    var boundary: ?usize = null;
    var saw_content = false;

    var index: usize = 1;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment => {},
            .document_start => {
                if (!saw_content) return false;
                boundary = index;
                break;
            },
            .document_end => return false,
            .directive => {
                if (saw_content) return ParseError.InvalidSyntax;
                return false;
            },
            else => saw_content = true,
        }
    }

    const document_boundary = boundary orelse return false;
    if (!try append_single_document(allocator, tokens, 1, document_boundary, events)) {
        return ParseError.Unsupported;
    }

    if (try appendRemainingDocumentStreamEvents(allocator, tokens, document_boundary, end, events, append_single_document)) {
        return true;
    }

    return ParseError.Unsupported;
}

fn appendRemainingDocumentStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    if (try appendDocumentEndSeparatedStreamEventsRange(allocator, tokens, start, end, events, append_single_document)) return true;
    if (try appendExplicitDocumentStreamEventsRange(allocator, tokens, start, end, events, append_single_document)) return true;
    if (try append_single_document(allocator, tokens, start, end, events)) return true;
    return false;
}

pub fn appendDocumentEndSeparatedStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    return appendDocumentEndSeparatedStreamEventsRange(allocator, tokens, 1, tokens.len - 1, events, append_single_document);
}

fn appendDocumentEndSeparatedStreamEventsRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    var index: usize = start;
    var saw_boundary = false;

    while (index < end) {
        skipComments(tokens, &index, end);
        if (index >= end) break;

        if (tokens[index] == .document_end) {
            var next_document = index + 1;
            skipComments(tokens, &next_document, end);
            if (next_document >= end) return saw_boundary;

            switch (tokens[next_document]) {
                .indent, .document_start, .document_end, .directive => {},
                else => return ParseError.InvalidSyntax,
            }

            saw_boundary = true;
            index = next_document;
            continue;
        }

        const document_start = index;
        var document_end = index;
        while (document_end < end and tokens[document_end] != .document_end) : (document_end += 1) {}

        if (document_end >= end) {
            if (!saw_boundary) return false;
            if (!try append_single_document(allocator, tokens, document_start, end, events)) {
                return ParseError.Unsupported;
            }
            return true;
        }

        var next_document = document_end + 1;
        skipComments(tokens, &next_document, end);
        if (next_document >= end) {
            if (!saw_boundary) return false;
            if (!try append_single_document(allocator, tokens, document_start, next_document, events)) {
                return ParseError.Unsupported;
            }
            return true;
        }

        switch (tokens[next_document]) {
            .indent, .document_start, .document_end, .directive => {},
            else => return ParseError.InvalidSyntax,
        }

        saw_boundary = true;
        if (!try append_single_document(allocator, tokens, document_start, next_document, events)) {
            return ParseError.Unsupported;
        }
        index = next_document;
    }

    return saw_boundary;
}

pub fn appendExplicitDocumentStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    return appendExplicitDocumentStreamEventsRange(allocator, tokens, 1, tokens.len - 1, events, append_single_document);
}

fn appendExplicitDocumentStreamEventsRange(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    start: usize,
    end: usize,
    events: *EventBuilder,
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    if (explicitDocumentStartCount(tokens[start..end]) < 2) return false;

    var index: usize = start;

    while (index < end) {
        skipComments(tokens, &index, end);
        if (index >= end) break;

        const document_start = findExplicitDocumentStartAfterPrefix(tokens, index, end) orelse return false;
        const document_prefix_start = index;
        index = document_start + 1;
        var flow_depth: usize = 0;
        while (index < end and tokens[index] != .document_start) : (index += 1) {
            switch (tokens[index]) {
                .flow_sequence_start, .flow_mapping_start => {
                    flow_depth += 1;
                    continue;
                },
                .flow_sequence_end, .flow_mapping_end => {
                    if (flow_depth > 0) flow_depth -= 1;
                    continue;
                },
                else => {},
            }
            if (flow_depth == 0 and isUnindentedDirectiveLikeContent(tokens, index, end)) return ParseError.InvalidSyntax;
        }

        if (!try append_single_document(allocator, tokens, document_prefix_start, index, events)) {
            return ParseError.Unsupported;
        }
    }

    return true;
}

fn findExplicitDocumentStartAfterPrefix(tokens: []const scanner.Token, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment, .directive => {},
            .document_start => return index,
            else => return null,
        }
    }
    return null;
}

fn isUnindentedDirectiveLikeContent(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index + 1 >= end or tokens[index] != .indent or tokens[index].indent != 0) return false;
    if (tokens[index + 1] != .scalar) return false;
    return std.mem.startsWith(u8, tokens[index + 1].scalar, "%");
}

fn explicitDocumentStartCount(tokens: []const scanner.Token) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (token == .document_start) count += 1;
    }
    return count;
}
