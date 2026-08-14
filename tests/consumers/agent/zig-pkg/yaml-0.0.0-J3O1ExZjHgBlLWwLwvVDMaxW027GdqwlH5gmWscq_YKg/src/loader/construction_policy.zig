//! Purpose: Centralize loader construction semantics shared by construction adapters.
//! Owns: Schema scalar resolution, standard scalar tag validation, unknown-tag policy, and failure classification for tag/scalar construction.
//! Does not own: Event traversal, graph traversal, duplicate-key comparison, collection allocation, alias identity, or public diagnostics.
//! Depends on: common/diagnostic.zig, loader/failure.zig, loader/options.zig, schema/schema.zig, schema/tag.zig, and value/value.zig.
//! Tested by: tests/structure/api_boundary_test.zig and focused loader parity tests.

const std = @import("std");
const duplicate_key = @import("duplicate_key.zig");
const diagnostic = @import("../common/diagnostic.zig");
const failure = @import("failure.zig");
const graph = @import("../compose/graph.zig");
const options = @import("options.zig");
const schema = @import("../schema/schema.zig");
const tag = @import("../schema/tag.zig");
const value_model = @import("../value/value.zig");

const Error = diagnostic.Error;
const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const LoadFailure = failure.LoadFailure;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const ParseError = diagnostic.ParseError;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;

pub const ScalarInput = struct {
    value: []const u8,
    is_plain: bool,
    tag: ?[]const u8,
};

pub const Policy = struct {
    schema: Schema,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure = null,

    pub inline fn validateTag(self: Policy, node_tag: ?[]const u8, kind: tag.NodeKind) Error!void {
        tag.validateStandardTagKind(node_tag, kind) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        if (self.unknown_tag_behavior == .reject and tag.isUnknownTag(node_tag)) {
            self.recordFailure(.unknown_tag);
            return ParseError.InvalidSyntax;
        }
    }

    pub inline fn validateAndResolveScalar(self: Policy, scalar: ScalarInput) Error!?schema.ResolvedScalar {
        try self.validateTag(scalar.tag, .scalar);
        tag.validateStandardBinaryContent(scalar.tag, scalar.value) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };
        tag.validateStandardTimestampContent(scalar.tag, scalar.value) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        return schema.resolveScalar(
            self.schema,
            scalar.value,
            scalar.is_plain,
            scalar.tag,
        ) catch |err| {
            self.recordFailure(.invalid_scalar_tag);
            return err;
        };
    }

    pub inline fn validateGraphSequence(self: Policy, sequence: graph.SequenceNode) Error!void {
        if (!tag.isStandardOmapTag(sequence.tag) and !tag.isStandardPairsTag(sequence.tag)) return;

        for (sequence.items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    pub inline fn validateGraphMapping(self: Policy, mapping: graph.MappingNode) Error!void {
        if (!tag.isStandardSetTag(mapping.tag)) return;

        for (mapping.pairs) |pair| {
            if (!isGraphSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    pub inline fn validateConstructedSequence(self: Policy, items: []const *const Node, node_tag: ?[]const u8) Error!void {
        if (tag.isStandardOmapTag(node_tag)) {
            duplicate_key.validateUniqueOrderedMapKeys(items) catch |err| {
                self.recordFailure(.invalid_standard_tag);
                return err;
            };
        } else if (tag.isStandardPairsTag(node_tag)) {
            try self.validateStandardSequenceItems(items);
        }
    }

    pub inline fn validateConstructedMapping(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        node_tag: ?[]const u8,
        duplicate_key_behavior: DuplicateKeyBehavior,
    ) Error!void {
        if (tag.isStandardSetTag(node_tag)) {
            try self.validateStandardSetPairs(pairs);
            try self.validateUniqueMappingKeys(temporary_allocator, pairs, .invalid_standard_tag);
        } else if (duplicate_key_behavior == .reject) {
            try self.validateUniqueMappingKeys(temporary_allocator, pairs, .duplicate_key);
        }
    }

    pub inline fn validateDuplicateMappingKeys(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        duplicate_key_behavior: DuplicateKeyBehavior,
    ) Error!void {
        if (duplicate_key_behavior == .allow) return;
        try self.validateUniqueMappingKeys(temporary_allocator, pairs, .duplicate_key);
    }

    inline fn recordFailure(self: Policy, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }

    inline fn validateUniqueMappingKeys(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        load_failure: LoadFailure,
    ) Error!void {
        duplicate_key.validateUniqueMappingKeys(temporary_allocator, pairs) catch |err| {
            self.recordFailure(load_failure);
            return err;
        };
    }

    inline fn validateStandardSequenceItems(self: Policy, items: []const *const Node) Error!void {
        for (items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    inline fn validateStandardSetPairs(self: Policy, pairs: []const MappingPair) Error!void {
        for (pairs) |pair| {
            if (!isSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }
};

pub inline fn nodeFromResolvedScalar(resolved: schema.ResolvedScalar, anchor: ?[]const u8, node_tag: ?[]const u8) Node {
    return switch (resolved) {
        .null_value => .{ .null_value = .{
            .anchor = anchor,
            .tag = node_tag,
        } },
        .bool_value => |bool_value| .{ .bool_value = .{
            .value = bool_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
        .int_value => |int_value| .{ .int_value = .{
            .value = int_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
        .float_value => |float_value| .{ .float_value = .{
            .value = float_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
    };
}

inline fn isSetNullValue(node: *const Node) bool {
    return switch (node.*) {
        .null_value => true,
        .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
        else => false,
    };
}

inline fn isGraphSetNullValue(node: *const graph.Node) bool {
    return switch (node.*) {
        .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "construction policy: resolves scalar values and classifies scalar failures" {
    var load_failure: LoadFailure = .unknown;
    const policy: Policy = .{
        .schema = .core,
        .unknown_tag_behavior = .reject,
        .failure = &load_failure,
    };

    const resolved = (try policy.validateAndResolveScalar(.{
        .value = "true",
        .is_plain = true,
        .tag = null,
    })).?;
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = true }, resolved);

    const bool_node = nodeFromResolvedScalar(resolved, "anchor", null);
    try std.testing.expect(bool_node == .bool_value);
    try std.testing.expect(bool_node.bool_value.value);
    try std.testing.expectEqualStrings("anchor", bool_node.bool_value.anchor.?);

    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateAndResolveScalar(.{
        .value = "value",
        .is_plain = true,
        .tag = "!local",
    }));
    try std.testing.expectEqual(LoadFailure.unknown_tag, load_failure);

    load_failure = .unknown;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateAndResolveScalar(.{
        .value = "not-an-int",
        .is_plain = true,
        .tag = "tag:yaml.org,2002:int",
    }));
    try std.testing.expectEqual(LoadFailure.invalid_scalar_tag, load_failure);

    load_failure = .unknown;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateAndResolveScalar(.{
        .value = "not-a-date",
        .is_plain = true,
        .tag = "tag:yaml.org,2002:timestamp",
    }));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);

    load_failure = .duplicate_key;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateTag("tag:yaml.org,2002:seq", .scalar));
    try std.testing.expectEqual(LoadFailure.duplicate_key, load_failure);
}

test "construction policy: validates graph collection tag content" {
    var load_failure: LoadFailure = .unknown;
    const policy: Policy = .{
        .schema = .core,
        .unknown_tag_behavior = .preserve,
        .failure = &load_failure,
    };

    const scalar_item: graph.Node = .{ .scalar = .{ .value = "item" } };
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateGraphSequence(.{
        .items = &.{&scalar_item},
        .tag = "tag:yaml.org,2002:omap",
    }));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);

    load_failure = .unknown;
    try policy.validateGraphSequence(.{
        .items = &.{&scalar_item},
        .tag = "tag:yaml.org,2002:seq",
    });
    try std.testing.expectEqual(LoadFailure.unknown, load_failure);

    const key: graph.Node = .{ .scalar = .{ .value = "key" } };
    const null_value: graph.Node = .{ .scalar = .{ .value = "~" } };
    const non_null_value: graph.Node = .{ .scalar = .{ .value = "value" } };
    try policy.validateGraphMapping(.{
        .pairs = &.{.{ .key = &key, .value = &null_value }},
        .tag = "tag:yaml.org,2002:set",
    });

    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateGraphMapping(.{
        .pairs = &.{.{ .key = &key, .value = &non_null_value }},
        .tag = "tag:yaml.org,2002:set",
    }));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);
}

test "construction policy: validates constructed collection tags and duplicates" {
    var load_failure: LoadFailure = .unknown;
    const policy: Policy = .{
        .schema = .core,
        .unknown_tag_behavior = .preserve,
        .failure = &load_failure,
    };

    const key_a: Node = .{ .scalar = .{ .value = "a" } };
    const key_a_again: Node = .{ .scalar = .{ .value = "a" } };
    const value: Node = .{ .scalar = .{ .value = "value" } };
    const null_value: Node = .{ .null_value = .{} };
    const valid_pair = MappingPair{ .key = &key_a, .value = &null_value };
    const duplicate_pairs = [_]MappingPair{
        valid_pair,
        .{ .key = &key_a_again, .value = &null_value },
    };

    try policy.validateConstructedMapping(std.testing.allocator, &.{valid_pair}, "tag:yaml.org,2002:set", .reject);
    try policy.validateDuplicateMappingKeys(std.testing.allocator, &duplicate_pairs, .allow);

    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateConstructedMapping(
        std.testing.allocator,
        &.{.{ .key = &key_a, .value = &value }},
        "tag:yaml.org,2002:set",
        .reject,
    ));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);

    load_failure = .unknown;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateConstructedMapping(
        std.testing.allocator,
        &duplicate_pairs,
        "tag:yaml.org,2002:set",
        .reject,
    ));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);

    load_failure = .unknown;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateDuplicateMappingKeys(
        std.testing.allocator,
        &duplicate_pairs,
        .reject,
    ));
    try std.testing.expectEqual(LoadFailure.duplicate_key, load_failure);

    const omap_item_a: Node = .{ .mapping = .{ .pairs = &.{valid_pair} } };
    const omap_item_b: Node = .{ .mapping = .{ .pairs = &.{.{ .key = &key_a_again, .value = &null_value }} } };
    load_failure = .unknown;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateConstructedSequence(
        &.{ &omap_item_a, &omap_item_b },
        "tag:yaml.org,2002:omap",
    ));
    try std.testing.expectEqual(LoadFailure.invalid_standard_tag, load_failure);

    const scalar_item: Node = .{ .scalar = .{ .value = "item" } };
    load_failure = .duplicate_key;
    try std.testing.expectError(ParseError.InvalidSyntax, policy.validateConstructedSequence(
        &.{&scalar_item},
        "tag:yaml.org,2002:pairs",
    ));
    try std.testing.expectEqual(LoadFailure.duplicate_key, load_failure);
}

test "construction policy: creates public nodes for each resolved scalar kind" {
    const null_node = nodeFromResolvedScalar(.null_value, "a", "tag:yaml.org,2002:null");
    try std.testing.expect(null_node == .null_value);
    try std.testing.expectEqualStrings("a", null_node.null_value.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:null", null_node.null_value.tag.?);

    const bool_node = nodeFromResolvedScalar(.{ .bool_value = false }, null, null);
    try std.testing.expect(bool_node == .bool_value);
    try std.testing.expect(!bool_node.bool_value.value);

    const int_node = nodeFromResolvedScalar(.{ .int_value = -42 }, null, null);
    try std.testing.expect(int_node == .int_value);
    try std.testing.expectEqual(@as(i128, -42), int_node.int_value.value);

    const float_node = nodeFromResolvedScalar(.{ .float_value = 1.5 }, null, null);
    try std.testing.expect(float_node == .float_value);
    try std.testing.expectEqual(@as(f64, 1.5), float_node.float_value.value);
}
