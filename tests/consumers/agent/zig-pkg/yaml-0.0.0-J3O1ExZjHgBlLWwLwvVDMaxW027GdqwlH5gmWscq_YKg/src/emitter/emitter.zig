//! Purpose: Public event-emitter, value-emitter, and document event loop.
//! Owns: Emitter API functions, event cursor state, stream/document framing, and document-level emission policy.
//! Does not own: Flow layout, block layout, scalar formatting, node dumping, or schema construction.
//! Depends on: block.zig, common/diagnostic.zig, flow.zig, parser/event.zig, scalar.zig, value/value.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance emitter tests.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const common_limit = @import("../common/limit.zig");
const event_types = @import("../parser/event.zig");
const value_model = @import("../value/value.zig");
const block = @import("block.zig");
const flow = @import("flow.zig");
const scalar_emit = @import("scalar.zig");
const schema = @import("../schema/schema.zig");
const style_types = @import("../common/style.zig");
const tag_emit = @import("tag.zig");

const CollectionStyle = style_types.CollectionStyle;
const DocumentStart = event_types.DocumentStart;
const Error = common.Error;
const Event = event_types.Event;
const Node = value_model.Node;
const ParseError = common.ParseError;
const Scalar = event_types.Scalar;
const ScalarNode = value_model.ScalarNode;
const ScalarStyle = style_types.ScalarStyle;
const WriteError = common.WriteError;

const appendEmittedAlias = scalar_emit.appendEmittedAlias;
const appendEmittedCollectionProperties = scalar_emit.appendEmittedCollectionProperties;
const appendEmittedScalarNodeIndented = scalar_emit.appendEmittedScalarNodeIndented;
const appendEmittedTag = scalar_emit.appendEmittedTag;
const blockScalarEndsWithWhitespaceOnlyContentLine = scalar_emit.blockScalarEndsWithWhitespaceOnlyContentLine;
const blockScalarHasLeadingTabIndentedLine = scalar_emit.blockScalarHasLeadingTabIndentedLine;
const blockScalarHasTabStartedLine = scalar_emit.blockScalarHasTabStartedLine;
const blockScalarHasTrailingSpaceOnlyContentLine = scalar_emit.blockScalarHasTrailingSpaceOnlyContentLine;
const blockScalarUsesKeepChomping = scalar_emit.blockScalarUsesKeepChomping;
const collectionHasProperties = scalar_emit.collectionHasProperties;
const flowPlainScalarNeedsQuoting = scalar_emit.flowPlainScalarNeedsQuoting;
const isNonEmptyInlineEvent = scalar_emit.isNonEmptyInlineEvent;
const isPlainEmptyScalar = scalar_emit.isPlainEmptyScalar;
const plainBlockMappingKeyNeedsQuoting = scalar_emit.plainBlockMappingKeyNeedsQuoting;
const plainScalarNeedsQuoting = scalar_emit.plainScalarNeedsQuoting;
const scalarContainsNonAsciiCodepoint = scalar_emit.scalarContainsNonAsciiCodepoint;
const scalarUsesQuotedBlockFallback = scalar_emit.scalarUsesQuotedBlockFallback;
const validateAnchorName = scalar_emit.validateAnchorName;

pub const EmitOptions = struct {
    preserve_top_level_flow_mapping_style: bool = false,
    preserve_block_sequence_flow_mapping_style: bool = false,
    preserve_collection_style: bool = true,
    preserve_unused_tag_directives: bool = false,
    omit_redundant_document_start: bool = false,
    max_output_bytes: ?usize = null,
};

pub const DumpOptions = struct {
    preserve_top_level_flow_mapping_style: bool = true,
    preserve_block_sequence_flow_mapping_style: bool = false,
    preserve_collection_style: bool = true,
    omit_redundant_document_start: bool = false,
    max_output_bytes: ?usize = null,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    events: []const Event,
    index: usize = 0,
    preserve_top_level_flow_mapping_style: bool = false,
    preserve_block_sequence_flow_mapping_style: bool = false,
    preserve_collection_style: bool = true,
    preserve_unused_tag_directives: bool = false,
    omit_redundant_document_start: bool = false,
    max_output_bytes: ?usize = null,
    split_top_level_global_tagged_scalar: bool = false,
    current_document_start_explicit: bool = false,
    emit_collection_depth: usize = 0,

    pub fn expectEvent(self: *State, comptime expected: std.meta.Tag(Event)) ParseError!void {
        if (self.index >= self.events.len or std.meta.activeTag(self.events[self.index]) != expected) {
            return ParseError.InvalidSyntax;
        }
        self.index += 1;
    }

    pub fn enterEmitCollection(self: *State) ParseError!void {
        if (self.emit_collection_depth >= common_limit.max_emit_collection_depth) return ParseError.Unsupported;
        self.emit_collection_depth += 1;
    }

    pub fn leaveEmitCollection(self: *State) void {
        self.emit_collection_depth -= 1;
    }

    pub fn topLevelEventStartsOwnLine(self: *const State, event: Event) bool {
        return switch (event) {
            .mapping_start => |collection| !collectionHasProperties(collection),
            .sequence_start => |collection| self.emittedCollectionStyle(collection.style) == .block and !collectionHasProperties(collection),
            else => false,
        };
    }

    pub fn emittedCollectionStyle(self: *const State, style: CollectionStyle) CollectionStyle {
        return if (self.preserve_collection_style) style else .block;
    }

    pub fn emittedMappingKeyScalar(self: *const State, scalar: Scalar) Scalar {
        if (self.preserve_collection_style) return scalar;
        if (scalar.style != .double_quoted) return scalar;
        if (scalar.anchor != null or scalar.tag != null) return scalar;
        if (scalar.value.len == 0) return scalar;
        if (scalar.value.len == 1) return scalar;
        if (std.mem.indexOfScalar(u8, scalar.value, '\n') != null) return scalar;
        if (std.mem.indexOfAny(u8, scalar.value, " \t") != null) return scalar;
        if (plainBlockMappingKeyNeedsQuoting(scalar.value)) return scalar;
        if (schema.resolvesAsCorePlainScalar(scalar.value)) return scalar;

        var plain = scalar;
        plain.style = .plain;
        return plain;
    }

    pub fn emittedScalar(self: *const State, scalar: Scalar) Scalar {
        if (self.preserve_collection_style) return scalar;
        if (scalar.style != .plain) return scalar;
        if (!scalarContainsNonAsciiCodepoint(scalar.value)) return scalar;

        var quoted = scalar;
        quoted.style = .double_quoted;
        return quoted;
    }

    pub fn emittedFlowScalar(self: *const State, scalar: Scalar) Scalar {
        var emitted = self.emittedScalar(scalar);
        switch (emitted.style) {
            .literal, .folded => emitted.style = .double_quoted,
            .plain => if (flowPlainScalarNeedsQuoting(emitted.value)) {
                emitted.style = .single_quoted;
            },
            .single_quoted, .double_quoted => {},
        }
        return emitted;
    }

    pub fn emittedTopLevelScalar(self: *const State, scalar: Scalar) Scalar {
        var emitted = self.emittedScalar(scalar);
        if (self.preserve_collection_style) return emitted;
        if (emitted.style != .double_quoted) return emitted;
        if (emitted.anchor != null or emitted.tag != null) return emitted;
        if (std.mem.indexOf(u8, emitted.value, "...") == null) return emitted;
        if (plainScalarNeedsQuoting(emitted.value)) return emitted;

        emitted.style = .plain;
        return emitted;
    }
};

pub const OutputBuffer = struct {
    const Self = @This();

    list: std.ArrayList(u8) = .empty,
    max_output_bytes: ?usize = null,
    limit_exceeded: bool = false,

    pub fn append(self: *Self, allocator: std.mem.Allocator, byte: u8) std.mem.Allocator.Error!void {
        try self.checkCanAppend(1);
        try self.list.append(allocator, byte);
    }

    pub fn appendSlice(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.checkCanAppend(bytes.len);
        try self.list.appendSlice(allocator, bytes);
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.* = .{};
    }

    fn toOwnedSlice(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.list.toOwnedSlice(allocator);
    }

    fn checkCanAppend(self: *Self, additional_bytes: usize) std.mem.Allocator.Error!void {
        const max_output_bytes = self.max_output_bytes orelse return;
        if (self.list.items.len > max_output_bytes or additional_bytes > max_output_bytes - self.list.items.len) {
            self.limit_exceeded = true;
            return error.OutOfMemory;
        }
    }
};

/// Emits a YAML stream from parser events. Caller owns the returned memory.
pub fn emitEvents(allocator: std.mem.Allocator, events: []const Event) Error![]u8 {
    return emitEventsWithOptions(allocator, events, .{});
}

/// Emits a YAML stream from parser events using the provided options. Caller
/// owns the returned memory.
pub fn emitEventsWithOptions(allocator: std.mem.Allocator, events: []const Event, options: EmitOptions) Error![]u8 {
    var emitter: State = .{
        .allocator = allocator,
        .events = events,
        .preserve_top_level_flow_mapping_style = options.preserve_top_level_flow_mapping_style,
        .preserve_block_sequence_flow_mapping_style = options.preserve_block_sequence_flow_mapping_style,
        .preserve_collection_style = options.preserve_collection_style,
        .preserve_unused_tag_directives = options.preserve_unused_tag_directives,
        .omit_redundant_document_start = options.omit_redundant_document_start,
        .max_output_bytes = options.max_output_bytes,
    };
    return emit(&emitter);
}

/// Emits a YAML stream from parser events into `writer`.
pub fn emitEventsToWriter(allocator: std.mem.Allocator, writer: *std.Io.Writer, events: []const Event) WriteError!void {
    return emitEventsToWriterWithOptions(allocator, writer, events, .{});
}

/// Emits a YAML stream from parser events into `writer` using the provided
/// options.
pub fn emitEventsToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    events: []const Event,
    options: EmitOptions,
) WriteError!void {
    const output = try emitEventsWithOptions(allocator, events, options);
    defer allocator.free(output);

    try writer.writeAll(output);
}

/// Dumps a single YAML node as a document. Caller owns the returned memory.
pub fn dump(allocator: std.mem.Allocator, root: *const Node) Error![]u8 {
    return dumpWithOptions(allocator, root, .{});
}

/// Emits a single value-model node as a YAML document. Caller owns the returned
/// memory.
pub fn emitValue(allocator: std.mem.Allocator, root: *const Node) Error![]u8 {
    return dump(allocator, root);
}

/// Dumps a single YAML node into `writer`.
pub fn dumpToWriter(allocator: std.mem.Allocator, writer: *std.Io.Writer, root: *const Node) WriteError!void {
    return dumpToWriterWithOptions(allocator, writer, root, .{});
}

/// Emits a single value-model node into `writer`.
pub fn emitValueToWriter(allocator: std.mem.Allocator, writer: *std.Io.Writer, root: *const Node) WriteError!void {
    return dumpToWriter(allocator, writer, root);
}

/// Dumps a single YAML node using the provided options. Caller owns the returned
/// memory.
pub fn dumpWithOptions(allocator: std.mem.Allocator, root: *const Node, options: DumpOptions) Error![]u8 {
    const documents = [_]*const Node{root};
    return dumpStreamWithOptions(allocator, &documents, options);
}

/// Dumps a single YAML node into `writer` using the provided options.
pub fn dumpToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: *const Node,
    options: DumpOptions,
) WriteError!void {
    const output = try dumpWithOptions(allocator, root, options);
    defer allocator.free(output);

    try writer.writeAll(output);
}

/// Emits a single value-model node as a YAML document using the provided
/// options. Caller owns the returned memory.
pub fn emitValueWithOptions(allocator: std.mem.Allocator, root: *const Node, options: DumpOptions) Error![]u8 {
    return dumpWithOptions(allocator, root, options);
}

/// Emits a single value-model node into `writer` using the provided options.
pub fn emitValueToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: *const Node,
    options: DumpOptions,
) WriteError!void {
    return dumpToWriterWithOptions(allocator, writer, root, options);
}

/// Dumps YAML nodes as a multi-document stream. Caller owns the returned memory.
pub fn dumpStream(allocator: std.mem.Allocator, documents: []const *const Node) Error![]u8 {
    return dumpStreamWithOptions(allocator, documents, .{});
}

/// Dumps YAML nodes as a multi-document stream into `writer`.
pub fn dumpStreamToWriter(allocator: std.mem.Allocator, writer: *std.Io.Writer, documents: []const *const Node) WriteError!void {
    return dumpStreamToWriterWithOptions(allocator, writer, documents, .{});
}

/// Dumps YAML nodes as a multi-document stream using the provided options.
/// Caller owns the returned memory.
pub fn dumpStreamWithOptions(allocator: std.mem.Allocator, documents: []const *const Node, options: DumpOptions) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(arena_allocator);

    try events.append(arena_allocator, .stream_start);
    for (documents, 0..) |root, index| {
        try events.append(arena_allocator, .{ .document_start = .{ .explicit = index != 0 } });
        {
            var state: DumpState = .{};
            state.preserve_collection_style = options.preserve_collection_style;
            defer state.deinit(arena_allocator);
            try appendNodeEvents(arena_allocator, &events, root, &state);
        }
        try events.append(arena_allocator, .{ .document_end = .{} });
    }
    try events.append(arena_allocator, .stream_end);

    var emitter: State = .{
        .allocator = allocator,
        .events = events.items,
        .preserve_top_level_flow_mapping_style = options.preserve_top_level_flow_mapping_style,
        .preserve_block_sequence_flow_mapping_style = options.preserve_block_sequence_flow_mapping_style,
        .preserve_collection_style = options.preserve_collection_style,
        .omit_redundant_document_start = options.omit_redundant_document_start,
        .max_output_bytes = options.max_output_bytes,
    };
    return emit(&emitter);
}

/// Dumps YAML nodes as a multi-document stream into `writer` using the provided
/// options.
pub fn dumpStreamToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    documents: []const *const Node,
    options: DumpOptions,
) WriteError!void {
    const output = try dumpStreamWithOptions(allocator, documents, options);
    defer allocator.free(output);

    try writer.writeAll(output);
}

pub fn emit(self: *State) Error![]u8 {
    var out: OutputBuffer = .{ .max_output_bytes = self.max_output_bytes };
    errdefer out.deinit(self.allocator);

    emitIntoBuffer(self, &out) catch |err| {
        if (err == error.OutOfMemory and out.limit_exceeded) return ParseError.Unsupported;
        return err;
    };

    return out.toOwnedSlice(self.allocator);
}

fn emitIntoBuffer(self: *State, out: anytype) Error!void {
    try self.expectEvent(.stream_start);

    var document_index: usize = 0;
    var previous_document_start_explicit = false;
    var previous_document_empty = false;
    while (self.index < self.events.len and self.events[self.index] == .document_start) : (document_index += 1) {
        const document_start = self.events[self.index].document_start;
        self.split_top_level_global_tagged_scalar = !self.preserve_collection_style and
            document_index != 0 and previous_document_start_explicit;
        self.current_document_start_explicit = document_start.explicit;
        self.index += 1;
        try validateYamlVersion(document_start.yaml_version);
        const uses_declared_tags = try validateDocumentTagsDeclared(self, document_start.tag_directives);
        const empty_plain_document = isPlainEmptyDocument(self);
        const emit_yaml_version = self.preserve_collection_style and document_start.yaml_version != null and
            (!empty_plain_document or emptyPlainDocumentHasExplicitEnd(self));
        const emit_tag_directives = document_start.tag_directives.len != 0 and
            (self.preserve_unused_tag_directives or (!empty_plain_document and uses_declared_tags));
        const force_document_start = emit_yaml_version or emit_tag_directives or
            (!document_start.explicit and shouldEmitExplicitDocumentStart(self));
        const emit_document_start = force_document_start or
            (document_start.explicit and !shouldOmitExplicitDocumentStart(self));
        const force_document_end = !self.preserve_collection_style and
            (topLevelNodeContainsKeepBlockScalar(self) or
                shouldPreserveSameLinePlainScalarDocumentEnd(self, document_start) or
                topLevelPlainScalarContainsDirectiveText(self)) or
            (self.omit_redundant_document_start and empty_plain_document and
                document_index != 0 and !previous_document_empty);

        if (emit_yaml_version) {
            const version = document_start.yaml_version.?;
            try out.*.appendSlice(self.allocator, "%YAML ");
            try out.*.appendSlice(self.allocator, version);
            try out.*.append(self.allocator, '\n');
        }

        if (emit_tag_directives) {
            for (document_start.tag_directives) |directive| {
                try tag_emit.appendTagDirective(self.allocator, &out, directive);
            }
        }

        if (emit_document_start) {
            try out.*.appendSlice(self.allocator, "---");
        }

        if (self.index >= self.events.len) return ParseError.InvalidSyntax;
        if (self.events[self.index] == .document_end) {
            if (emit_document_start) try out.*.append(self.allocator, '\n');
        } else if (shouldEmitEmptyDocument(self)) {
            if (emit_document_start) try out.*.append(self.allocator, '\n');
            self.index += 1;
        } else if (empty_plain_document and emit_document_start) {
            if (self.omit_redundant_document_start) {
                try out.*.append(self.allocator, '\n');
            } else {
                try out.*.appendSlice(self.allocator, " null");
                try out.*.append(self.allocator, '\n');
            }
            self.index += 1;
        } else {
            if (emit_document_start and topLevelGlobalScalarTagStartsOnDocumentStart(self)) {
                try emitTopLevelGlobalTaggedScalarAfterDocumentStart(self, &out);
            } else {
                if (emit_document_start) {
                    const starts_own_line = self.topLevelEventStartsOwnLine(self.events[self.index]) or
                        canonicalTopLevelScalarStartsOwnLine(self, document_start);
                    try out.*.append(self.allocator, if (starts_own_line) '\n' else ' ');
                }
                try emitTopLevelNode(self, &out);
            }
            try out.*.append(self.allocator, '\n');
        }

        if (self.index >= self.events.len or self.events[self.index] != .document_end) return ParseError.InvalidSyntax;
        const document_end = self.events[self.index].document_end;
        self.index += 1;

        if (document_end.explicit or force_document_end) try out.*.appendSlice(self.allocator, "...\n");
        previous_document_start_explicit = document_start.explicit;
        previous_document_empty = empty_plain_document;
    }

    try self.expectEvent(.stream_end);
    if (self.index != self.events.len) return ParseError.InvalidSyntax;
}

fn validateYamlVersion(version: ?[]const u8) ParseError!void {
    const value = version orelse return;
    const separator = std.mem.indexOfScalar(u8, value, '.') orelse return ParseError.InvalidSyntax;
    if (separator == 0 or separator + 1 == value.len) return ParseError.InvalidSyntax;
    if (std.mem.indexOfScalarPos(u8, value, separator + 1, '.') != null) return ParseError.InvalidSyntax;

    for (value[0..separator]) |byte| {
        if (!std.ascii.isDigit(byte)) return ParseError.InvalidSyntax;
    }
    for (value[separator + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return ParseError.InvalidSyntax;
    }

    const major = std.fmt.parseInt(u16, value[0..separator], 10) catch return ParseError.InvalidSyntax;
    if (major != 1) return ParseError.InvalidSyntax;
}

fn validateDocumentTagsDeclared(self: *const State, tag_directives: []const event_types.TagDirective) ParseError!bool {
    try tag_emit.validateTagDirectives(tag_directives);

    var end = self.index;
    while (end < self.events.len and self.events[end] != .document_end) : (end += 1) {}
    if (end >= self.events.len) return ParseError.InvalidSyntax;
    const document_events = self.events[self.index..end];
    try tag_emit.validateNamedTagsDeclared(document_events, tag_directives);
    return tag_emit.usesDeclaredTagDirective(document_events, tag_directives);
}

fn emitTopLevelGlobalTaggedScalarAfterDocumentStart(self: *State, out: anytype) Error!void {
    const scalar = self.events[self.index].scalar;
    if (scalar.anchor) |anchor| {
        try validateAnchorName(anchor);
        try out.*.append(self.allocator, ' ');
        try out.*.append(self.allocator, '&');
        try out.*.appendSlice(self.allocator, anchor);
    }
    if (scalar.tag) |tag| {
        try out.*.append(self.allocator, ' ');
        try appendEmittedTag(self.allocator, out, tag);
    }

    var scalar_without_tag = scalar;
    scalar_without_tag.tag = null;
    scalar_without_tag.anchor = null;
    if ((scalar_without_tag.style == .plain or
        (scalar_without_tag.style == .double_quoted and !self.split_top_level_global_tagged_scalar)) and
        scalar_without_tag.anchor == null and
        scalar_without_tag.value.len != 0 and
        std.mem.indexOfScalar(u8, scalar_without_tag.value, '\n') == null and
        (scalar_without_tag.style != .plain or !plainScalarNeedsQuoting(scalar_without_tag.value)))
    {
        try out.*.append(self.allocator, ' ');
        try appendEmittedScalarNodeIndented(self.allocator, out, scalar_without_tag, .{
            .content = 2,
            .indicator = 2,
        });
        self.index += 1;
        return;
    }

    try out.*.append(self.allocator, '\n');
    try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedScalar(scalar_without_tag), .{
        .content = 2,
        .indicator = 2,
        .quote_block_scalar_whitespace_only_lines = !self.preserve_collection_style,
        .quote_block_scalar_tab_indented_lines = !self.preserve_collection_style,
    });
    self.index += 1;
}

fn isPlainEmptyDocument(self: *const State) bool {
    if (self.index + 1 >= self.events.len) return false;
    if (self.events[self.index] != .scalar or !isPlainEmptyScalar(self.events[self.index].scalar)) return false;
    return self.events[self.index + 1] == .document_end;
}

fn emptyPlainDocumentHasExplicitEnd(self: *const State) bool {
    if (!isPlainEmptyDocument(self)) return false;
    return self.events[self.index + 1].document_end.explicit;
}

fn shouldEmitEmptyDocument(self: *const State) bool {
    if (!isPlainEmptyDocument(self)) return false;

    return emptyPlainDocumentHasExplicitEnd(self);
}

fn emitTopLevelNode(self: *State, out: anytype) Error!void {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;

    switch (self.events[self.index]) {
        .scalar => |scalar| {
            try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedTopLevelScalar(scalar), .{
                .content = 2,
                .indicator = 2,
                .quote_block_scalar_whitespace_only_lines = !self.preserve_collection_style,
                .quote_block_scalar_tab_indented_lines = !self.preserve_collection_style,
                .quote_literal_tab_started_lines = !self.preserve_collection_style and self.current_document_start_explicit,
                .quote_plain_multiline = !self.preserve_collection_style,
            });
            self.index += 1;
        },
        .alias => |alias| {
            try appendEmittedAlias(self.allocator, out, alias);
            self.index += 1;
        },
        .mapping_start => |collection| {
            self.index += 1;
            if (try flow.emitEmptyMappingIfPresent(self, out, collection, null)) return;
            const style = self.emittedCollectionStyle(collection.style);
            const emit_as_flow = style == .flow and self.preserve_top_level_flow_mapping_style;
            if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                try out.*.append(self.allocator, if (emit_as_flow) ' ' else '\n');
            }
            if (emit_as_flow) {
                try flow.emitFlowMapping(self, out);
            } else {
                try block.emitBlockMapping(self, out);
            }
        },
        .sequence_start => |collection| {
            self.index += 1;
            if (try flow.emitEmptySequenceIfPresent(self, out, collection, null)) return;
            const style = self.emittedCollectionStyle(collection.style);
            const wrote_properties = try appendEmittedCollectionProperties(self.allocator, out, collection);
            if (wrote_properties) {
                try out.*.append(self.allocator, switch (style) {
                    .block => '\n',
                    .flow => ' ',
                });
            }
            switch (style) {
                .block => try block.emitBlockSequence(self, out),
                .flow => try flow.emitFlowSequence(self, out),
            }
        },
        else => return ParseError.Unsupported,
    }
}

fn topLevelGlobalScalarTagStartsOnDocumentStart(self: *const State) bool {
    if (self.index >= self.events.len or self.events[self.index] != .scalar) return false;
    const tag = self.events[self.index].scalar.tag orelse return false;
    return !std.mem.startsWith(u8, tag, "!");
}

fn shouldEmitExplicitDocumentStart(self: *const State) bool {
    if (self.index + 1 >= self.events.len) return false;
    if (!self.preserve_collection_style and currentDocumentStart(self).force_document_start) return true;
    if (!self.preserve_collection_style and
        self.events[self.index] == .sequence_start and
        topLevelNodeContainsBlockScalar(self)) return true;
    if (!self.preserve_collection_style and
        self.events[self.index] == .mapping_start and
        self.events[self.index].mapping_start.style == .flow and
        topLevelFlowMappingStartsWithQuestionKey(self)) return true;

    return switch (self.events[self.index]) {
        .sequence_start => |collection| self.emittedCollectionStyle(collection.style) == .flow and self.events[self.index + 1] == .sequence_end,
        .mapping_start => |collection| topLevelMappingNeedsExplicitDocumentStart(self, self.emittedCollectionStyle(collection.style)),
        else => false,
    };
}

fn shouldOmitExplicitDocumentStart(self: *const State) bool {
    if (!self.omit_redundant_document_start) return false;
    if (self.index >= self.events.len or self.events[self.index] != .scalar) return false;
    return topLevelScalarWouldUseQuotedBlockFallback(self, self.events[self.index].scalar);
}

fn topLevelNodeContainsKeepBlockScalar(self: *const State) bool {
    var index = self.index;
    var depth: usize = 0;
    var last_content_is_keep_block_scalar = false;

    while (index < self.events.len) : (index += 1) {
        switch (self.events[index]) {
            .scalar => |scalar| switch (scalar.style) {
                .literal, .folded => last_content_is_keep_block_scalar = blockScalarUsesKeepChomping(scalar.value),
                .plain, .single_quoted, .double_quoted => last_content_is_keep_block_scalar = false,
            },
            .alias => last_content_is_keep_block_scalar = false,
            .sequence_start, .mapping_start => {
                depth += 1;
                last_content_is_keep_block_scalar = false;
            },
            .sequence_end, .mapping_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return last_content_is_keep_block_scalar;
            },
            .document_start, .document_end, .stream_start, .stream_end => return last_content_is_keep_block_scalar,
        }
    }

    return last_content_is_keep_block_scalar;
}

fn shouldPreserveSameLinePlainScalarDocumentEnd(self: *const State, document_start: DocumentStart) bool {
    if (!document_start.explicit or !document_start.content_same_line) return false;
    if (document_start.yaml_version != null) return false;
    if (self.index >= self.events.len or self.events[self.index] != .scalar) return false;
    const scalar = self.events[self.index].scalar;
    return scalar.style == .plain and scalar.tag == null and
        (scalar.anchor != null or document_start.content_same_line_separated_by_tab);
}

fn topLevelPlainScalarContainsDirectiveText(self: *const State) bool {
    if (self.index >= self.events.len or self.events[self.index] != .scalar) return false;
    const scalar = self.events[self.index].scalar;
    return scalar.style == .plain and std.mem.indexOf(u8, scalar.value, "%YAML") != null;
}

fn canonicalTopLevelScalarStartsOwnLine(self: *const State, document_start: DocumentStart) bool {
    if (!self.omit_redundant_document_start or !document_start.explicit) return false;
    if (document_start.content_same_line) return false;
    return switch (self.events[self.index]) {
        .scalar => |scalar| if (scalar.tag) |tag|
            std.mem.startsWith(u8, tag, "!") and !std.mem.eql(u8, tag, "!")
        else
            document_start.has_reserved_directive and scalar.style == .double_quoted,
        else => false,
    };
}

fn currentDocumentStart(self: *const State) DocumentStart {
    var index = self.index;
    while (index > 0) {
        index -= 1;
        if (self.events[index] == .document_start) return self.events[index].document_start;
    }
    return .{};
}

fn topLevelScalarWouldUseQuotedBlockFallback(self: *const State, scalar: Scalar) bool {
    if (self.preserve_collection_style) return false;
    return switch (scalar.style) {
        .literal, .folded => scalar.value.len == 0 or
            blockScalarEndsWithWhitespaceOnlyContentLine(scalar.value) or
            blockScalarHasLeadingTabIndentedLine(scalar.value) or
            (scalar.style == .literal and blockScalarHasTabStartedLine(scalar.value)),
        .plain, .single_quoted, .double_quoted => false,
    };
}

fn topLevelMappingNeedsExplicitDocumentStart(self: *const State, style: CollectionStyle) bool {
    if (!self.omit_redundant_document_start and
        style == .block and
        isLastDocumentAfterTopLevelNode(self) and
        topLevelBlockMappingHasOnlyNonEmptyInlineScalarPairs(self)) return true;

    var index = self.index;
    var depth: usize = 0;

    while (index < self.events.len) : (index += 1) {
        switch (self.events[index]) {
            .mapping_start, .sequence_start => depth += 1,
            .mapping_end, .sequence_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return false;
            },
            .scalar => |scalar| if ((!self.preserve_collection_style and
                scalarUsesQuotedBlockFallback(scalar) and
                !canonicalBlockScalarWouldBeQuoted(self, scalar)) or
                (self.preserve_collection_style and blockScalarHasTrailingSpaceOnlyContentLine(scalar.value))) return true,
            .document_end, .stream_end => return false,
            else => {},
        }
    }

    return false;
}

fn isLastDocumentAfterTopLevelNode(self: *const State) bool {
    const node_end = topLevelNodeEndIndex(self) orelse return false;
    if (node_end + 1 >= self.events.len) return false;
    return self.events[node_end] == .document_end and self.events[node_end + 1] == .stream_end;
}

fn topLevelNodeEndIndex(self: *const State) ?usize {
    if (self.index >= self.events.len) return null;

    switch (self.events[self.index]) {
        .scalar, .alias => return self.index + 1,
        .sequence_start, .mapping_start => {},
        else => return null,
    }

    var index = self.index;
    var depth: usize = 0;
    while (index < self.events.len) : (index += 1) {
        switch (self.events[index]) {
            .sequence_start, .mapping_start => depth += 1,
            .sequence_end, .mapping_end => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            .document_start, .document_end, .stream_start, .stream_end => return null,
            else => {},
        }
    }

    return null;
}

fn topLevelNodeContainsBlockScalar(self: *const State) bool {
    var index = self.index;
    var depth: usize = 0;
    var mapping_depth: usize = 0;

    while (index < self.events.len) : (index += 1) {
        switch (self.events[index]) {
            .scalar => |scalar| switch (scalar.style) {
                .literal, .folded => if (mapping_depth != 0 and !canonicalBlockScalarWouldBeQuoted(self, scalar)) return true,
                .plain, .single_quoted, .double_quoted => {},
            },
            .sequence_start => depth += 1,
            .mapping_start => {
                depth += 1;
                mapping_depth += 1;
            },
            .sequence_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return false;
            },
            .mapping_end => {
                if (depth == 0) return false;
                depth -= 1;
                if (mapping_depth != 0) mapping_depth -= 1;
                if (depth == 0) return false;
            },
            .document_start, .document_end, .stream_start, .stream_end => return false,
            .alias => {},
        }
    }

    return false;
}

fn topLevelFlowMappingStartsWithQuestionKey(self: *const State) bool {
    if (self.index + 1 >= self.events.len) return false;
    if (self.events[self.index] != .mapping_start or self.events[self.index].mapping_start.style != .flow) return false;
    if (self.events[self.index + 1] != .scalar) return false;
    const key = self.events[self.index + 1].scalar;
    return key.value.len != 0 and key.value[0] == '?';
}

fn canonicalBlockScalarWouldBeQuoted(self: *const State, scalar: Scalar) bool {
    if (self.preserve_collection_style) return false;
    if (scalar.value.len == 0) return true;
    return blockScalarEndsWithWhitespaceOnlyContentLine(scalar.value) or
        blockScalarHasLeadingTabIndentedLine(scalar.value);
}

fn topLevelBlockMappingHasOnlyNonEmptyInlineScalarPairs(self: *const State) bool {
    if (self.index >= self.events.len or self.events[self.index] != .mapping_start) return false;

    var index = self.index + 1;
    var saw_pair = false;
    while (index < self.events.len) {
        switch (self.events[index]) {
            .mapping_end => return saw_pair,
            .scalar, .alias => {
                if (!isNonEmptyInlineEvent(self.events[index])) return false;
                index += 1;
                if (index >= self.events.len or !isNonEmptyInlineEvent(self.events[index])) return false;

                saw_pair = true;
                index += 1;
            },
            else => return false,
        }
    }

    return false;
}

const max_dump_node_depth: usize = 256;

fn appendNodeEvents(
    allocator: std.mem.Allocator,
    events: *std.ArrayList(Event),
    node: *const Node,
    state: *DumpState,
) Error!void {
    const anchor = dumpNodeAnchor(node);
    if (pathContainsNode(state.path.items, node)) {
        if (anchor) |value| try events.append(allocator, .{ .alias = value }) else return ParseError.Unsupported;
        return;
    }
    switch (node.*) {
        .sequence, .mapping => if (state.path.items.len >= max_dump_node_depth) return ParseError.Unsupported,
        else => {},
    }
    if (anchor) |value| {
        if (pathContainsNode(state.emitted_anchored.items, node)) {
            try events.append(allocator, .{ .alias = value });
            return;
        }
        try state.emitted_anchored.append(allocator, node);
    }

    try state.path.append(allocator, node);
    defer _ = state.path.pop();

    switch (node.*) {
        .null_value => |value| try events.append(allocator, .{ .scalar = .{
            .value = "null",
            .anchor = value.anchor,
            .tag = value.tag,
        } }),
        .bool_value => |value| try events.append(allocator, .{ .scalar = .{
            .value = if (value.value) "true" else "false",
            .anchor = value.anchor,
            .tag = value.tag,
        } }),
        .int_value => |value| try events.append(allocator, .{ .scalar = .{
            .value = try std.fmt.allocPrint(allocator, "{d}", .{value.value}),
            .anchor = value.anchor,
            .tag = value.tag,
        } }),
        .float_value => |value| try events.append(allocator, .{ .scalar = .{
            .value = try dumpFloatScalarValue(allocator, value.value),
            .anchor = value.anchor,
            .tag = value.tag,
        } }),
        .scalar => |scalar| try events.append(allocator, .{ .scalar = .{
            .value = scalar.value,
            .style = dumpScalarStyle(scalar),
            .anchor = scalar.anchor,
            .tag = scalar.tag,
        } }),
        .sequence => |sequence| {
            try events.append(allocator, .{ .sequence_start = .{
                .style = if (state.preserve_collection_style) sequence.style else .block,
                .anchor = sequence.anchor,
                .tag = sequence.tag,
            } });
            for (sequence.items) |item| {
                try appendNodeEvents(allocator, events, item, state);
            }
            try events.append(allocator, .sequence_end);
        },
        .mapping => |mapping| {
            try events.append(allocator, .{ .mapping_start = .{
                .style = if (state.preserve_collection_style) mapping.style else .block,
                .anchor = mapping.anchor,
                .tag = mapping.tag,
            } });
            for (mapping.pairs) |pair| {
                try appendNodeEvents(allocator, events, pair.key, state);
                try appendNodeEvents(allocator, events, pair.value, state);
            }
            try events.append(allocator, .mapping_end);
        },
        .alias => |alias| try events.append(allocator, .{ .alias = alias }),
    }
}

const DumpState = struct {
    path: std.ArrayList(*const Node) = .empty,
    emitted_anchored: std.ArrayList(*const Node) = .empty,
    preserve_collection_style: bool = true,

    fn deinit(self: *DumpState, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        self.emitted_anchored.deinit(allocator);
    }
};

fn pathContainsNode(path: []const *const Node, node: *const Node) bool {
    for (path) |ancestor| {
        if (ancestor == node) return true;
    }
    return false;
}

fn dumpNodeAnchor(node: *const Node) ?[]const u8 {
    return switch (node.*) {
        .null_value => |value| value.anchor,
        .bool_value => |value| value.anchor,
        .int_value => |value| value.anchor,
        .float_value => |value| value.anchor,
        .scalar => |scalar| scalar.anchor,
        .sequence => |sequence| sequence.anchor,
        .mapping => |mapping| mapping.anchor,
        .alias => null,
    };
}

fn dumpFloatScalarValue(allocator: std.mem.Allocator, value: f64) std.mem.Allocator.Error![]const u8 {
    if (std.math.isNan(value)) return ".nan";
    if (std.math.isPositiveInf(value)) return ".inf";
    if (std.math.isInf(value) and value < 0) return "-.inf";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "{d}", .{value});
    if (std.mem.indexOfAny(u8, out.items, ".eE") == null) {
        try out.appendSlice(allocator, ".0");
    }
    return out.toOwnedSlice(allocator);
}

fn dumpScalarStyle(scalar: ScalarNode) ScalarStyle {
    if (scalar.style == .plain) {
        if (std.mem.indexOfScalar(u8, scalar.value, '\n') != null) return .single_quoted;
        if (scalar.tag == null and schema.resolvesAsCorePlainScalar(scalar.value)) return .single_quoted;
    }

    return scalar.style;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

fn expectEmitError(expected: anyerror, events: []const Event) !void {
    var state = State{
        .allocator = testing.allocator,
        .events = events,
    };
    try testing.expectError(expected, emit(&state));
}

test "emitter: validates caller constructed YAML version directives" {
    const invalid_versions = [_][]const u8{ "", "1", ".2", "1.", "1.2.3", "a.2", "1.b", "2.0" };
    for (invalid_versions) |version| {
        const events = [_]Event{
            .stream_start,
            .{ .document_start = .{ .explicit = true, .yaml_version = version } },
            .{ .scalar = .{ .value = "value" } },
            .{ .document_end = .{} },
            .stream_end,
        };
        try expectEmitError(ParseError.InvalidSyntax, &events);
    }

    const valid_events = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true, .yaml_version = "1.3" } },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    var state = State{
        .allocator = testing.allocator,
        .events = &valid_events,
        .preserve_collection_style = true,
    };
    const emitted = try emit(&state);
    defer testing.allocator.free(emitted);
    try testing.expectEqualStrings("%YAML 1.3\n--- value\n", emitted);
}

test "emitter: rejects malformed document event framing" {
    try expectEmitError(ParseError.InvalidSyntax, &.{
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    });

    try expectEmitError(ParseError.InvalidSyntax, &.{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value" } },
        .stream_end,
    });

    try expectEmitError(ParseError.InvalidSyntax, &.{
        .stream_start,
        .{ .document_start = .{} },
        .{ .document_end = .{} },
        .{ .scalar = .{ .value = "trailing" } },
        .stream_end,
    });
}

test "emitter document policy: defensive scans handle truncated event windows" {
    const keep_scalar = [_]Event{.{ .scalar = .{ .value = "value\n\n", .style = .literal } }};
    try testing.expect(topLevelNodeContainsKeepBlockScalar(&.{
        .allocator = testing.allocator,
        .events = &keep_scalar,
    }));

    const empty_flow_sequence = [_]Event{
        .{ .sequence_start = .{ .style = .flow } },
        .sequence_end,
    };
    try testing.expect(!shouldEmitExplicitDocumentStart(&.{
        .allocator = testing.allocator,
        .events = &empty_flow_sequence,
        .preserve_collection_style = false,
    }));

    const unterminated_mapping = [_]Event{.{ .mapping_start = .{ .style = .block } }};
    try testing.expect(!shouldEmitExplicitDocumentStart(&.{
        .allocator = testing.allocator,
        .events = &unterminated_mapping,
    }));

    const interrupted_sequence = [_]Event{
        .{ .sequence_start = .{ .style = .block } },
        .{ .document_end = .{} },
    };
    try testing.expect(!shouldEmitExplicitDocumentStart(&.{
        .allocator = testing.allocator,
        .events = &interrupted_sequence,
        .preserve_collection_style = false,
    }));
}

test "emitter document policy: block mapping pair scan distinguishes complete and truncated pairs" {
    const complete_pairs = [_]Event{
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    try testing.expect(shouldEmitExplicitDocumentStart(&.{
        .allocator = testing.allocator,
        .events = &complete_pairs,
    }));

    const truncated_pairs = [_]Event{
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
    };
    try testing.expect(!shouldEmitExplicitDocumentStart(&.{
        .allocator = testing.allocator,
        .events = &truncated_pairs,
    }));
}

test "emitter document policy: defensive helpers reject invalid top-level starts" {
    const starts_with_document_end = [_]Event{.{ .document_end = .{} }};
    try testing.expectEqual(@as(?usize, null), topLevelNodeEndIndex(&.{
        .allocator = testing.allocator,
        .events = &starts_with_document_end,
    }));

    const unterminated_sequence_with_block_scalar = [_]Event{
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "value\n", .style = .literal } },
    };
    try testing.expect(!topLevelNodeContainsBlockScalar(&.{
        .allocator = testing.allocator,
        .events = &unterminated_sequence_with_block_scalar,
    }));

    const unterminated_inline_pairs = [_]Event{
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
    };
    try testing.expect(!topLevelBlockMappingHasOnlyNonEmptyInlineScalarPairs(&.{
        .allocator = testing.allocator,
        .events = &unterminated_inline_pairs,
    }));
}
