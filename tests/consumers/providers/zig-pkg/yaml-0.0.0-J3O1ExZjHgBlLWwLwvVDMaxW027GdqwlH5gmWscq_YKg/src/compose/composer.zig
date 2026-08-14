//! Purpose: Compose parser events into an untyped YAML representation graph.
//! Owns: Document stream structure, anchor tracking, alias resolution, and graph-shape validation.
//! Does not own: Scanning, parsing, schema resolution, public value construction, duplicate-key policy, or emission.
//! Depends on: common/diagnostic.zig, parser/event.zig, compose/graph.zig.
//! Tested by: tests/unit/compose/composer_test.zig.

const std = @import("std");
const alias_limit = @import("alias.zig");
const anchor_table = @import("anchor_table.zig");
const diagnostic = @import("../common/diagnostic.zig");
const event = @import("../parser/event.zig");
const graph = @import("graph.zig");
const node_pool = @import("../common/node_pool.zig");

const Error = diagnostic.Error;
const NodePool = node_pool.Pool(Node);
pub const Event = event.Event;
pub const MappingPair = graph.MappingPair;
pub const Node = graph.Node;
pub const ParseError = diagnostic.ParseError;

/// Limits applied while composing parser events.
pub const Options = struct {
    /// Reject streams that contain more alias events than this count.
    max_alias_count: ?usize = null,
    /// Reject streams whose resolved aliases would expand to more graph nodes
    /// than this count if aliases were materialized by a consumer.
    max_alias_expansion: ?usize = null,
    /// Reject streams that contain more documents than this count.
    max_document_count: ?usize = null,
};

/// Composes a complete YAML event stream into representation graph roots.
///
/// The caller owns returned nodes and collection storage through `allocator`.
/// Graph string slices borrow from `events`; the event stream must outlive the
/// composed graph. Public loading copies strings during construction before
/// releasing parser event storage.
pub fn composeStream(allocator: std.mem.Allocator, events: []const Event, options: Options) Error![]const *const Node {
    var composer: Composer = .{
        .allocator = allocator,
        .events = events,
        .options = options,
    };
    return composer.composeStream();
}

const Composer = struct {
    allocator: std.mem.Allocator,
    events: []const Event,
    options: Options,
    index: usize = 0,
    alias_limiter: alias_limit.Limiter = .{},
    document_count: usize = 0,
    anchors: anchor_table.AnchorTable = .{},
    complete_nodes: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    nodes: NodePool = .{},

    fn composeStream(self: *Composer) Error![]const *const Node {
        self.alias_limiter = .{
            .max_alias_count = self.options.max_alias_count,
            .max_alias_expansion = self.options.max_alias_expansion,
        };
        self.nodes = try NodePool.init(self.allocator, countGraphNodes(self.events));
        errdefer self.nodes.deinit(self.allocator);
        defer self.complete_nodes.deinit(self.allocator);
        defer self.anchors.deinit(self.allocator);

        try self.expectStreamStart();

        var documents: std.ArrayList(*const Node) = .empty;
        errdefer documents.deinit(self.allocator);
        try documents.ensureTotalCapacity(self.allocator, countDocumentStarts(self.events));

        while (self.index < self.events.len and self.events[self.index] == .document_start) {
            try self.countDocument();
            self.anchors.clearRetainingCapacity();
            self.index += 1;

            const root = try self.composeNode();

            if (self.index >= self.events.len or self.events[self.index] != .document_end) return ParseError.InvalidSyntax;
            self.index += 1;

            try documents.append(self.allocator, root);
        }

        if (self.index >= self.events.len or self.events[self.index] != .stream_end) return ParseError.InvalidSyntax;
        self.index += 1;
        if (self.index != self.events.len) return ParseError.InvalidSyntax;

        return documents.toOwnedSlice(self.allocator);
    }

    fn expectStreamStart(self: *Composer) ParseError!void {
        if (self.index >= self.events.len or self.events[self.index] != .stream_start) return ParseError.InvalidSyntax;
        self.index += 1;
    }

    fn composeNode(self: *Composer) Error!*const Node {
        if (self.index >= self.events.len) return ParseError.InvalidSyntax;

        const current = self.events[self.index];
        self.index += 1;

        switch (current) {
            .scalar => |scalar| return self.composeScalar(scalar),
            .sequence_start => |collection| return self.composeSequence(collection),
            .mapping_start => |collection| return self.composeMapping(collection),
            .alias => |alias| return self.composeAlias(alias),
            else => return ParseError.InvalidSyntax,
        }
    }

    fn composeScalar(self: *Composer, scalar: event.Scalar) Error!*const Node {
        const node = try self.nodes.create();
        node.* = .{ .scalar = .{
            .value = scalar.value,
            .style = scalar.style,
            .anchor = scalar.anchor,
            .tag = scalar.tag,
        } };
        try self.rememberAnchor(node.scalar.anchor, node);
        try self.markComplete(node);
        return node;
    }

    fn composeSequence(self: *Composer, collection: event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        const anchor = collection.anchor;
        const tag = collection.tag;
        try self.rememberAnchor(anchor, node);

        var items: std.ArrayList(*const Node) = .empty;
        errdefer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, countDirectCollectionNodes(self.events, self.index, false));

        while (self.index < self.events.len and self.events[self.index] != .sequence_end) {
            try items.append(self.allocator, try self.composeNode());
        }
        if (self.index >= self.events.len) return ParseError.InvalidSyntax;
        self.index += 1;

        node.* = .{ .sequence = .{
            .items = try items.toOwnedSlice(self.allocator),
            .style = collection.style,
            .anchor = anchor,
            .tag = tag,
        } };
        try self.markComplete(node);
        return node;
    }

    fn composeMapping(self: *Composer, collection: event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        const anchor = collection.anchor;
        const tag = collection.tag;
        try self.rememberAnchor(anchor, node);

        var pairs: std.ArrayList(MappingPair) = .empty;
        errdefer pairs.deinit(self.allocator);
        try pairs.ensureTotalCapacity(self.allocator, countDirectCollectionNodes(self.events, self.index, true) / 2);

        while (self.index < self.events.len and self.events[self.index] != .mapping_end) {
            const key = try self.composeNode();
            if (self.index >= self.events.len or self.events[self.index] == .mapping_end) return ParseError.InvalidSyntax;
            const value = try self.composeNode();
            try pairs.append(self.allocator, .{
                .key = key,
                .value = value,
            });
        }
        if (self.index >= self.events.len) return ParseError.InvalidSyntax;
        self.index += 1;

        node.* = .{ .mapping = .{
            .pairs = try pairs.toOwnedSlice(self.allocator),
            .style = collection.style,
            .anchor = anchor,
            .tag = tag,
        } };
        try self.markComplete(node);
        return node;
    }

    fn composeAlias(self: *Composer, alias: []const u8) Error!*const Node {
        try self.alias_limiter.countAlias();
        const node = self.anchors.get(alias) orelse return ParseError.InvalidSyntax;
        try self.alias_limiter.countExpansion(self.allocator, node, &self.complete_nodes);
        return node;
    }

    fn rememberAnchor(self: *Composer, anchor: ?[]const u8, node: *const Node) Error!void {
        try self.anchors.remember(self.allocator, anchor, node);
    }

    fn markComplete(self: *Composer, node: *const Node) std.mem.Allocator.Error!void {
        if (self.options.max_alias_expansion == null) return;
        try self.complete_nodes.put(self.allocator, node, {});
    }

    fn countDocument(self: *Composer) ParseError!void {
        const max_document_count = self.options.max_document_count orelse return;

        if (self.document_count >= max_document_count) return ParseError.Unsupported;
        self.document_count += 1;
    }
};

fn countDocumentStarts(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event_value| {
        if (event_value == .document_start) count += 1;
    }
    return count;
}

fn countGraphNodes(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event_value| switch (event_value) {
        .scalar, .sequence_start, .mapping_start => count += 1,
        else => {},
    };
    return count;
}

fn countDirectCollectionNodes(events: []const Event, start: usize, mapping: bool) usize {
    var count: usize = 0;
    var depth: usize = 0;
    var index = start;
    while (index < events.len) : (index += 1) {
        const event_value = events[index];
        if (depth == 0 and collectionEnded(event_value, mapping)) return count;
        if (depth == 0 and eventStartsNode(event_value)) count += 1;
        switch (event_value) {
            .sequence_start, .mapping_start => depth += 1,
            .sequence_end, .mapping_end => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return count;
}

fn collectionEnded(event_value: Event, mapping: bool) bool {
    return if (mapping) event_value == .mapping_end else event_value == .sequence_end;
}

fn eventStartsNode(event_value: Event) bool {
    return switch (event_value) {
        .scalar, .alias, .sequence_start, .mapping_start => true,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
