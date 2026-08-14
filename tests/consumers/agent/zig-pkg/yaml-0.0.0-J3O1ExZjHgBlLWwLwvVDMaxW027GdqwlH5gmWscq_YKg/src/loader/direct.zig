//! Purpose: Construct public value nodes directly from parser events when safe.
//! Owns: Alias-free event stream loading, direct value-node allocation, and fallback support checks.
//! Does not own: Event parsing, alias resolution, public API diagnostics, or emission.
//! Depends on: parser/event.zig, schema, loader options, duplicate-key validation, and value/value.zig.
//! Tested by: tests/unit/loader/loader_test.zig and public loader conformance tests.

const std = @import("std");
const construction_policy = @import("construction_policy.zig");
const diagnostic = @import("../common/diagnostic.zig");
const failure = @import("failure.zig");
const limit = @import("limit.zig");
const node_pool = @import("../common/node_pool.zig");
const options = @import("options.zig");
const parser_event = @import("../parser/event.zig");
const schema = @import("../schema/schema.zig");
const value_model = @import("../value/value.zig");

const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const Error = diagnostic.Error;
const Event = parser_event.Event;
const LoadFailure = failure.LoadFailure;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const NodePool = node_pool.Pool(Node);
const ParseError = diagnostic.ParseError;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;
const ConstructionPolicy = construction_policy.Policy;

/// Returns true when the direct loader supports the event stream shape.
pub fn supports(events: []const Event) bool {
    return !limit.summarizeEvents(events).has_aliases;
}

/// Loads alias-free parser events directly into arena-owned public value roots.
pub fn loadStreamFromEvents(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_document_count: ?usize,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    const summary = limit.summarizeEvents(events);
    try limit.checkSummary(summary, .{ .max_document_count = max_document_count }, load_failure);
    return loadStreamFromEventsWithSummary(
        allocator,
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        summary,
        load_failure,
    );
}

pub fn loadStreamFromEventsWithSummary(
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    summary: limit.EventSummary,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    return loadStreamFromEventsWithStringPolicy(
        allocator,
        temporary_allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        summary,
        load_failure,
        true,
    );
}

/// Loads events whose string payloads already live as long as `allocator`.
pub fn loadStreamFromEventsBorrowingStringsWithSummary(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    summary: limit.EventSummary,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    return loadStreamFromEventsWithStringPolicy(
        allocator,
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        summary,
        load_failure,
        false,
    );
}

pub fn loadStreamFromEventsWithStringPolicy(
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    summary: limit.EventSummary,
    load_failure: ?*LoadFailure,
    copy_strings: bool,
) Error![]const *const Node {
    if (summary.has_aliases) return ParseError.Unsupported;
    const collection_child_counts = buildDirectCollectionChildCounts(temporary_allocator, events) catch |err| {
        if (err == ParseError.InvalidSyntax) recordFailure(load_failure, .invalid_graph);
        return err;
    };
    defer if (collection_child_counts.len > 0) temporary_allocator.free(collection_child_counts);

    var loader: DirectLoader = .{
        .allocator = allocator,
        .temporary_allocator = temporary_allocator,
        .events = events,
        .collection_child_counts = collection_child_counts,
        .schema = selected_schema,
        .duplicate_key_behavior = duplicate_key_behavior,
        .unknown_tag_behavior = unknown_tag_behavior,
        .failure = load_failure,
        .document_count = summary.document_count,
        .value_node_count = summary.value_node_count,
        .copy_strings = copy_strings,
    };
    return loader.loadStream();
}

const DirectLoader = struct {
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    events: []const Event,
    collection_child_counts: []const usize,
    collection_child_count_index: usize = 0,
    schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure,
    document_count: usize,
    value_node_count: usize,
    copy_strings: bool,
    index: usize = 0,
    nodes: NodePool = .{},

    fn loadStream(self: *DirectLoader) Error![]const *const Node {
        self.nodes = try NodePool.init(self.allocator, self.value_node_count);
        errdefer self.nodes.deinit(self.allocator);

        try self.expectStreamStart();

        var documents: std.ArrayList(*const Node) = .empty;
        errdefer documents.deinit(self.allocator);
        try documents.ensureTotalCapacity(self.allocator, self.document_count);

        while (self.index < self.events.len and self.events[self.index] == .document_start) {
            self.index += 1;

            const root = try self.constructNode();

            if (self.index >= self.events.len or self.events[self.index] != .document_end) return self.invalidGraph();
            self.index += 1;

            try documents.append(self.allocator, root);
        }

        if (self.index >= self.events.len or self.events[self.index] != .stream_end) return self.invalidGraph();
        self.index += 1;
        if (self.index != self.events.len) return self.invalidGraph();

        return documents.toOwnedSlice(self.allocator);
    }

    fn expectStreamStart(self: *DirectLoader) Error!void {
        if (self.index >= self.events.len or self.events[self.index] != .stream_start) return self.invalidGraph();
        self.index += 1;
    }

    fn constructNode(self: *DirectLoader) Error!*const Node {
        if (self.index >= self.events.len) return self.invalidGraph();

        const current = self.events[self.index];
        self.index += 1;

        return switch (current) {
            .scalar => |scalar| self.constructScalar(scalar),
            .sequence_start => |collection| self.constructSequence(try self.nextCollectionChildCount(), collection),
            .mapping_start => |collection| self.constructMapping(try self.nextCollectionChildCount(), collection),
            .alias => ParseError.Unsupported,
            else => self.invalidGraph(),
        };
    }

    fn constructScalar(self: *DirectLoader, scalar: parser_event.Scalar) Error!*const Node {
        const node = try self.nodes.create();

        node.* = (try self.resolveSchemaScalar(scalar)) orelse .{ .scalar = .{
            .value = try self.retainSlice(scalar.value),
            .style = scalar.style,
            .anchor = try self.retainOptionalSlice(scalar.anchor),
            .tag = try self.retainOptionalSlice(scalar.tag),
        } };
        return node;
    }

    fn constructSequence(self: *DirectLoader, child_count: usize, collection: parser_event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        try self.constructionPolicy().validateTag(collection.tag, .sequence);

        var items: std.ArrayList(*const Node) = .empty;
        errdefer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, child_count);

        while (self.index < self.events.len and self.events[self.index] != .sequence_end) {
            try items.append(self.allocator, try self.constructNode());
        }
        if (self.index >= self.events.len) return self.invalidGraph();
        self.index += 1;

        const owned_items = try items.toOwnedSlice(self.allocator);
        node.* = .{ .sequence = .{
            .items = owned_items,
            .style = collection.style,
            .anchor = try self.retainOptionalSlice(collection.anchor),
            .tag = try self.retainOptionalSlice(collection.tag),
        } };
        try self.constructionPolicy().validateConstructedSequence(owned_items, collection.tag);
        return node;
    }

    fn constructMapping(self: *DirectLoader, child_count: usize, collection: parser_event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        try self.constructionPolicy().validateTag(collection.tag, .mapping);

        var pairs: std.ArrayList(MappingPair) = .empty;
        errdefer pairs.deinit(self.allocator);
        try pairs.ensureTotalCapacity(self.allocator, child_count / 2);

        while (self.index < self.events.len and self.events[self.index] != .mapping_end) {
            const key = try self.constructNode();
            if (self.index >= self.events.len or self.events[self.index] == .mapping_end) return self.invalidGraph();
            try pairs.append(self.allocator, .{
                .key = key,
                .value = try self.constructNode(),
            });
        }
        if (self.index >= self.events.len) return self.invalidGraph();
        self.index += 1;

        const owned_pairs = try pairs.toOwnedSlice(self.allocator);
        node.* = .{ .mapping = .{
            .pairs = owned_pairs,
            .style = collection.style,
            .anchor = try self.retainOptionalSlice(collection.anchor),
            .tag = try self.retainOptionalSlice(collection.tag),
        } };
        try self.constructionPolicy().validateConstructedMapping(
            self.temporary_allocator,
            owned_pairs,
            collection.tag,
            self.duplicate_key_behavior,
        );
        return node;
    }

    fn invalidGraph(self: *DirectLoader) Error {
        self.recordFailure(.invalid_graph);
        return ParseError.InvalidSyntax;
    }

    fn recordFailure(self: *DirectLoader, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }

    fn resolveSchemaScalar(self: *DirectLoader, scalar_value: parser_event.Scalar) Error!?Node {
        const resolved = (try self.constructionPolicy().validateAndResolveScalar(.{
            .value = scalar_value.value,
            .is_plain = scalar_value.style == .plain,
            .tag = scalar_value.tag,
        })) orelse return null;
        return construction_policy.nodeFromResolvedScalar(
            resolved,
            try self.retainOptionalSlice(scalar_value.anchor),
            try self.retainOptionalSlice(scalar_value.tag),
        );
    }

    fn constructionPolicy(self: *DirectLoader) ConstructionPolicy {
        return .{
            .schema = self.schema,
            .unknown_tag_behavior = self.unknown_tag_behavior,
            .failure = self.failure,
        };
    }

    fn retainSlice(self: *DirectLoader, value: []const u8) std.mem.Allocator.Error![]const u8 {
        return if (self.copy_strings) try self.allocator.dupe(u8, value) else value;
    }

    fn retainOptionalSlice(self: *DirectLoader, maybe_value: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
        return if (maybe_value) |slice| try self.retainSlice(slice) else null;
    }

    fn nextCollectionChildCount(self: *DirectLoader) Error!usize {
        if (self.collection_child_count_index >= self.collection_child_counts.len) return self.invalidGraph();
        const child_count = self.collection_child_counts[self.collection_child_count_index];
        self.collection_child_count_index += 1;
        return child_count;
    }
};

fn buildDirectCollectionChildCounts(allocator: std.mem.Allocator, events: []const Event) Error![]usize {
    const collection_count = countCollectionStarts(events);
    if (collection_count == 0) return &[_]usize{};

    const counts = try allocator.alloc(usize, collection_count);
    errdefer allocator.free(counts);
    @memset(counts, 0);

    const stack = try allocator.alloc(usize, collection_count);
    defer allocator.free(stack);

    var stack_len: usize = 0;
    var next_collection: usize = 0;
    for (events) |event_value| {
        switch (event_value) {
            .sequence_start, .mapping_start => {
                if (stack_len > 0) counts[stack[stack_len - 1]] += 1;
                stack[stack_len] = next_collection;
                stack_len += 1;
                next_collection += 1;
            },
            .scalar, .alias => {
                if (stack_len > 0) counts[stack[stack_len - 1]] += 1;
            },
            .sequence_end, .mapping_end => {
                if (stack_len == 0) return ParseError.InvalidSyntax;
                stack_len -= 1;
            },
            else => {},
        }
    }

    if (stack_len != 0) return ParseError.InvalidSyntax;
    if (next_collection != collection_count) return ParseError.InvalidSyntax;
    return counts;
}

fn countCollectionStarts(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event_value| {
        switch (event_value) {
            .sequence_start, .mapping_start => count += 1,
            else => {},
        }
    }
    return count;
}

fn recordFailure(load_failure: ?*LoadFailure, load_failure_value: LoadFailure) void {
    if (load_failure) |target| {
        if (target.* == .unknown) target.* = load_failure_value;
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "direct loader precomputes collection child counts" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "items" } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "one" } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "key" } },
        .{ .scalar = .{ .value = "value" } },
        .mapping_end,
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const counts = try buildDirectCollectionChildCounts(std.testing.allocator, &events);
    defer std.testing.allocator.free(counts);

    try std.testing.expectEqual(@as(usize, 2), counts[0]);
    try std.testing.expectEqual(@as(usize, 2), counts[1]);
    try std.testing.expectEqual(@as(usize, 2), counts[2]);
}
