//! Purpose: Construct the public value model from composed representation graph nodes.
//! Owns: Schema scalar construction, value-node allocation, alias identity preservation, and duplicate-key policy.
//! Does not own: Event parsing, event composition, scalar spelling rules, public loading API, or emission.
//! Depends on: common/diagnostic.zig, compose/graph.zig, schema/schema.zig, value/value.zig, loader/options.zig, loader/duplicate_key.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/stress/stress.zig, and conformance tests.

const std = @import("std");
const construction_policy = @import("construction_policy.zig");
const diagnostic = @import("../common/diagnostic.zig");
const failure = @import("failure.zig");
const graph = @import("../compose/graph.zig");
const node_pool = @import("../common/node_pool.zig");
const options = @import("options.zig");
const schema = @import("../schema/schema.zig");
const value_model = @import("../value/value.zig");

const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const Error = diagnostic.Error;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const NodePool = node_pool.Pool(Node);
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;
const ConstructionPolicy = construction_policy.Policy;

pub const LoadFailure = failure.LoadFailure;

/// Constructs public value-model document roots from composed graph roots.
/// Public value strings are copied into `allocator` so loaded values outlive
/// parser event storage.
pub fn constructStream(
    allocator: std.mem.Allocator,
    documents: []const *const graph.Node,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
) Error![]const *const Node {
    return constructStreamWithFailure(
        allocator,
        allocator,
        documents,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        null,
        true,
    );
}

/// Constructs public value-model document roots and records load-stage failure
/// categories for diagnostics when construction fails. Public value strings are
/// copied into `allocator` so loaded values outlive parser event storage.
pub fn constructStreamWithFailure(
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    documents: []const *const graph.Node,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    load_failure: ?*LoadFailure,
    preserve_alias_identity: bool,
) Error![]const *const Node {
    var constructor: Constructor = .{
        .allocator = allocator,
        .temporary_allocator = temporary_allocator,
        .schema = selected_schema,
        .duplicate_key_behavior = duplicate_key_behavior,
        .unknown_tag_behavior = unknown_tag_behavior,
        .failure = load_failure,
        .preserve_alias_identity = preserve_alias_identity,
    };
    return constructor.constructStream(documents);
}

const Constructor = struct {
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure = null,
    preserve_alias_identity: bool,
    constructed: std.AutoHashMapUnmanaged(*const graph.Node, *const Node) = .empty,
    nodes: NodePool = .{},

    fn constructStream(self: *Constructor, documents: []const *const graph.Node) Error![]const *const Node {
        if (!self.preserve_alias_identity) {
            self.nodes = try NodePool.init(self.allocator, countGraphDocumentNodes(documents));
            errdefer self.nodes.deinit(self.allocator);
        }
        defer if (self.preserve_alias_identity) self.constructed.deinit(self.allocator);

        var loaded_documents: std.ArrayList(*const Node) = .empty;
        errdefer loaded_documents.deinit(self.allocator);
        try loaded_documents.ensureTotalCapacity(self.allocator, documents.len);

        for (documents) |document| {
            const node = if (self.preserve_alias_identity)
                try self.constructNodeTracked(document)
            else
                try self.constructNodeUntracked(document);
            try loaded_documents.append(self.allocator, node);
        }

        return loaded_documents.toOwnedSlice(self.allocator);
    }

    fn constructNodeTracked(self: *Constructor, graph_node: *const graph.Node) Error!*const Node {
        if (self.constructed.get(graph_node)) |node| return node;

        const node = try self.allocator.create(Node);
        try self.constructed.put(self.allocator, graph_node, node);
        try self.constructNodeInto(node, graph_node, true);
        return node;
    }

    fn constructNodeUntracked(self: *Constructor, graph_node: *const graph.Node) Error!*const Node {
        const node = try self.nodes.create();
        try self.constructNodeInto(node, graph_node, false);
        return node;
    }

    fn constructNodeInto(self: *Constructor, node: *Node, graph_node: *const graph.Node, comptime track_identity: bool) Error!void {
        switch (graph_node.*) {
            .scalar => |scalar| {
                node.* = (try resolveSchemaScalar(self.allocator, self.constructionPolicy(), scalar)) orelse
                    .{ .scalar = .{
                        .value = try self.allocator.dupe(u8, scalar.value),
                        .style = scalar.style,
                        .anchor = try copyOptionalSlice(self.allocator, scalar.anchor),
                        .tag = try copyOptionalSlice(self.allocator, scalar.tag),
                    } };
            },
            .sequence => |sequence| {
                try self.constructionPolicy().validateTag(sequence.tag, .sequence);
                try self.constructionPolicy().validateGraphSequence(sequence);

                var items: std.ArrayList(*const Node) = .empty;
                errdefer items.deinit(self.allocator);
                try items.ensureTotalCapacity(self.allocator, sequence.items.len);

                for (sequence.items) |item| {
                    try items.append(self.allocator, if (track_identity)
                        try self.constructNodeTracked(item)
                    else
                        try self.constructNodeUntracked(item));
                }

                const owned_items = try items.toOwnedSlice(self.allocator);
                node.* = .{ .sequence = .{
                    .items = owned_items,
                    .style = sequence.style,
                    .anchor = try copyOptionalSlice(self.allocator, sequence.anchor),
                    .tag = try copyOptionalSlice(self.allocator, sequence.tag),
                } };
                try self.constructionPolicy().validateConstructedSequence(owned_items, sequence.tag);
            },
            .mapping => |mapping| {
                try self.constructionPolicy().validateTag(mapping.tag, .mapping);
                try self.constructionPolicy().validateGraphMapping(mapping);

                var pairs: std.ArrayList(MappingPair) = .empty;
                errdefer pairs.deinit(self.allocator);
                try pairs.ensureTotalCapacity(self.allocator, mapping.pairs.len);

                for (mapping.pairs) |pair| {
                    try pairs.append(self.allocator, .{
                        .key = if (track_identity)
                            try self.constructNodeTracked(pair.key)
                        else
                            try self.constructNodeUntracked(pair.key),
                        .value = if (track_identity)
                            try self.constructNodeTracked(pair.value)
                        else
                            try self.constructNodeUntracked(pair.value),
                    });
                }

                const owned_pairs = try pairs.toOwnedSlice(self.allocator);
                node.* = .{ .mapping = .{
                    .pairs = owned_pairs,
                    .style = mapping.style,
                    .anchor = try copyOptionalSlice(self.allocator, mapping.anchor),
                    .tag = try copyOptionalSlice(self.allocator, mapping.tag),
                } };
                try self.constructionPolicy().validateConstructedMapping(
                    self.temporary_allocator,
                    owned_pairs,
                    mapping.tag,
                    self.duplicate_key_behavior,
                );
            },
        }
    }

    fn recordFailure(self: *Constructor, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }

    fn constructionPolicy(self: *Constructor) ConstructionPolicy {
        return .{
            .schema = self.schema,
            .unknown_tag_behavior = self.unknown_tag_behavior,
            .failure = self.failure,
        };
    }
};

fn countGraphDocumentNodes(documents: []const *const graph.Node) usize {
    var count: usize = 0;
    for (documents) |document| {
        count += countGraphNodes(document);
    }
    return count;
}

fn countGraphNodes(node: *const graph.Node) usize {
    return switch (node.*) {
        .scalar => 1,
        .sequence => |sequence| countSequenceGraphNodes(sequence.items),
        .mapping => |mapping| countMappingGraphNodes(mapping.pairs),
    };
}

fn countSequenceGraphNodes(items: []const *const graph.Node) usize {
    var count: usize = 1;
    for (items) |item| {
        count += countGraphNodes(item);
    }
    return count;
}

fn countMappingGraphNodes(pairs: []const graph.MappingPair) usize {
    var count: usize = 1;
    for (pairs) |pair| {
        count += countGraphNodes(pair.key);
        count += countGraphNodes(pair.value);
    }
    return count;
}

fn resolveSchemaScalar(
    allocator: std.mem.Allocator,
    policy: ConstructionPolicy,
    scalar_value: graph.ScalarNode,
) Error!?Node {
    const resolved = (try policy.validateAndResolveScalar(.{
        .value = scalar_value.value,
        .is_plain = scalar_value.style == .plain,
        .tag = scalar_value.tag,
    })) orelse return null;
    return construction_policy.nodeFromResolvedScalar(
        resolved,
        try copyOptionalSlice(allocator, scalar_value.anchor),
        try copyOptionalSlice(allocator, scalar_value.tag),
    );
}

fn copyOptionalSlice(allocator: std.mem.Allocator, maybe_value: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (maybe_value) |slice| try allocator.dupe(u8, slice) else null;
}

test {
    std.testing.refAllDecls(@This());
}

test "loader construct: direct stream wrapper constructs scalar documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const scalar = graph.Node{ .scalar = .{ .value = "value" } };
    const documents = [_]*const graph.Node{&scalar};

    const loaded = try constructStream(
        arena.allocator(),
        &documents,
        .core,
        .reject,
        .preserve,
    );

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(loaded[0].* == .scalar);
    try std.testing.expectEqualStrings("value", loaded[0].scalar.value);
}
