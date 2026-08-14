//! Purpose: Validate loaded YAML mapping keys according to duplicate-key policy.
//! Owns: Semantic key equality for public value nodes.
//! Does not own: Event composition, schema construction, parser validation, or emission.
//! Depends on: value/value.zig.
//! Tested by: in-file tests, tests/unit/api/root_api_test.zig, and conformance loader tests.

const std = @import("std");
const value = @import("../value/value.zig");
const diagnostic = @import("../common/diagnostic.zig");

const MappingNode = value.MappingNode;
const MappingPair = value.MappingPair;
const Node = value.Node;
const Error = diagnostic.Error;
const ParseError = diagnostic.ParseError;
const ScalarNode = value.ScalarNode;
const SequenceNode = value.SequenceNode;

const max_node_compare_depth: usize = 256;
const indexed_validation_min_pairs: usize = 32;
const MappingKeySet = std.HashMapUnmanaged(*const Node, void, MappingKeyContext, 80);
const StringScalarKeySet = std.HashMapUnmanaged(*const Node, void, StringScalarKeyContext, 80);
const StringScalarKeyValidation = enum { validated, fallback };

/// Rejects mappings that contain duplicate keys after schema construction.
pub fn validateUniqueMappingKeys(allocator: std.mem.Allocator, pairs: []const MappingPair) Error!void {
    if (pairs.len >= indexed_validation_min_pairs and pairs.len <= std.math.maxInt(StringScalarKeySet.Size)) {
        switch (try validateUniqueStringScalarMappingKeys(allocator, pairs)) {
            .validated => return,
            .fallback => {},
        }
    }

    if (pairs.len < indexed_validation_min_pairs or pairs.len > std.math.maxInt(MappingKeySet.Size)) {
        return validateUniqueMappingKeysLinear(pairs);
    }

    var seen: MappingKeySet = .empty;
    defer seen.deinit(allocator);
    try seen.ensureTotalCapacity(allocator, @intCast(pairs.len));

    for (pairs) |pair| {
        const entry = try seen.getOrPut(allocator, pair.key);
        if (entry.found_existing) return ParseError.InvalidSyntax;
    }
}

fn validateUniqueStringScalarMappingKeys(allocator: std.mem.Allocator, pairs: []const MappingPair) Error!StringScalarKeyValidation {
    var seen: StringScalarKeySet = .empty;
    defer seen.deinit(allocator);
    try seen.ensureTotalCapacity(allocator, @intCast(pairs.len));

    for (pairs) |pair| {
        if (!isStandardStringScalarMappingKey(pair.key)) return .fallback;
        const entry = try seen.getOrPut(allocator, pair.key);
        if (entry.found_existing) return ParseError.InvalidSyntax;
    }

    return .validated;
}

const StringScalarKeyContext = struct {
    pub fn hash(_: @This(), node: *const Node) u64 {
        return hashBytes(node.scalar.value);
    }

    pub fn eql(_: @This(), lhs: *const Node, rhs: *const Node) bool {
        return std.mem.eql(u8, lhs.scalar.value, rhs.scalar.value);
    }
};

fn isStandardStringScalarMappingKey(node: *const Node) bool {
    return node.* == .scalar and isStandardMappingKeyTag(node.scalar.tag, "tag:yaml.org,2002:str");
}

fn isStandardMappingKeyTag(node_tag: ?[]const u8, standard_tag: []const u8) bool {
    return std.mem.eql(u8, resolvedMappingKeyTag(node_tag, standard_tag), standard_tag);
}

fn validateUniqueMappingKeysLinear(pairs: []const MappingPair) ParseError!void {
    for (pairs, 0..) |pair, index| {
        for (pairs[0..index]) |previous| {
            if (nodesEqualForMappingKey(previous.key, pair.key, 0)) return ParseError.InvalidSyntax;
        }
    }
}

const MappingKeyContext = struct {
    pub fn hash(_: @This(), node: *const Node) u64 {
        return hashNodeForMappingKey(node, 0);
    }

    pub fn eql(_: @This(), lhs: *const Node, rhs: *const Node) bool {
        return nodesEqualForMappingKey(lhs, rhs, 0);
    }
};

fn hashNodeForMappingKey(node: *const Node, depth: usize) u64 {
    if (depth >= max_node_compare_depth) return hashPointer(node);

    return switch (node.*) {
        .null_value => |node_value| mixHash(1, hashTag(node_value.tag, "tag:yaml.org,2002:null")),
        .bool_value => |node_value| mixHash(mixHash(2, @intFromBool(node_value.value)), hashTag(node_value.tag, "tag:yaml.org,2002:bool")),
        .int_value => |node_value| mixHash(3, hashInt(node_value.value) ^ hashTag(node_value.tag, "tag:yaml.org,2002:int")),
        .float_value => |node_value| mixHash(4, hashFloat(node_value.value) ^ hashTag(node_value.tag, "tag:yaml.org,2002:float")),
        .scalar => |scalar| mixHash(5, hashBytes(scalar.value) ^ hashTag(scalar.tag, "tag:yaml.org,2002:str")),
        .sequence => |sequence| mixHash(6, hashSequenceForMappingKey(sequence, depth + 1)),
        .mapping => |mapping| mixHash(7, hashMappingForMappingKey(mapping, depth + 1)),
        .alias => |alias| mixHash(8, hashBytes(alias)),
    };
}

fn hashSequenceForMappingKey(sequence: SequenceNode, depth: usize) u64 {
    var hash = mixHash(hashTag(sequence.tag, "tag:yaml.org,2002:seq"), sequence.items.len);
    for (sequence.items) |item| {
        hash = mixHash(hash, hashNodeForMappingKey(item, depth));
    }
    return hash;
}

fn hashMappingForMappingKey(mapping: MappingNode, depth: usize) u64 {
    var sum: u64 = 0;
    var xor: u64 = 0;
    for (mapping.pairs) |pair| {
        const pair_hash = mixHash(hashNodeForMappingKey(pair.key, depth), hashNodeForMappingKey(pair.value, depth));
        sum +%= pair_hash;
        xor ^= mixHash(pair_hash, pair_hash >> 32);
    }
    return mixHash(mixHash(hashTag(mapping.tag, "tag:yaml.org,2002:map"), mapping.pairs.len), mixHash(sum, xor));
}

fn hashTag(tag: ?[]const u8, standard_tag: []const u8) u64 {
    return hashBytes(resolvedMappingKeyTag(tag, standard_tag));
}

fn hashPointer(node: *const Node) u64 {
    return mixHash(0x9e37_79b9_7f4a_7c15, @intFromPtr(node));
}

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn hashInt(int_value: i128) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&int_value));
    return hasher.final();
}

fn hashFloat(float_value: f64) u64 {
    if (std.math.isNan(float_value)) return 0x7ff8_0000_0000_0000;
    if (float_value == 0) return 0;
    const bits: u64 = @bitCast(float_value);
    return bits;
}

fn mixHash(lhs: u64, rhs: u64) u64 {
    var hash = lhs ^ rhs;
    hash *%= 0x9e37_79b1_85eb_ca87;
    hash ^= hash >> 33;
    return hash;
}

/// Rejects duplicate keys across a constructed YAML `!!omap` sequence.
pub fn validateUniqueOrderedMapKeys(items: []const *const Node) ParseError!void {
    for (items, 0..) |item, index| {
        if (item.* != .mapping or item.mapping.pairs.len != 1) return ParseError.InvalidSyntax;
        const pair = item.mapping.pairs[0];
        for (items[0..index]) |previous_item| {
            if (previous_item.* != .mapping or previous_item.mapping.pairs.len != 1) return ParseError.InvalidSyntax;
            if (nodesEqualForMappingKey(previous_item.mapping.pairs[0].key, pair.key, 0)) return ParseError.InvalidSyntax;
        }
    }
}

fn nodesEqualForMappingKey(lhs: *const Node, rhs: *const Node, depth: usize) bool {
    if (lhs == rhs) return true;
    if (depth >= max_node_compare_depth) return false;

    return switch (lhs.*) {
        .null_value => |lhs_value| rhs.* == .null_value and tagsEqualForMappingKey(lhs_value.tag, rhs.null_value.tag, "tag:yaml.org,2002:null"),
        .bool_value => |lhs_value| rhs.* == .bool_value and
            lhs_value.value == rhs.bool_value.value and
            tagsEqualForMappingKey(lhs_value.tag, rhs.bool_value.tag, "tag:yaml.org,2002:bool"),
        .int_value => |lhs_value| rhs.* == .int_value and
            lhs_value.value == rhs.int_value.value and
            tagsEqualForMappingKey(lhs_value.tag, rhs.int_value.tag, "tag:yaml.org,2002:int"),
        .float_value => |lhs_value| rhs.* == .float_value and
            floatsEqualForMappingKey(lhs_value.value, rhs.float_value.value) and
            tagsEqualForMappingKey(lhs_value.tag, rhs.float_value.tag, "tag:yaml.org,2002:float"),
        .scalar => |lhs_scalar| rhs.* == .scalar and scalarNodesEqualForMappingKey(lhs_scalar, rhs.scalar),
        .sequence => |lhs_sequence| rhs.* == .sequence and sequenceNodesEqualForMappingKey(lhs_sequence, rhs.sequence, depth + 1),
        .mapping => |lhs_mapping| rhs.* == .mapping and mappingNodesEqualForMappingKey(lhs_mapping, rhs.mapping, depth + 1),
        .alias => |lhs_alias| rhs.* == .alias and std.mem.eql(u8, lhs_alias, rhs.alias),
    };
}

fn floatsEqualForMappingKey(lhs: f64, rhs: f64) bool {
    if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
    return lhs == rhs;
}

fn scalarNodesEqualForMappingKey(lhs: ScalarNode, rhs: ScalarNode) bool {
    return scalarTagsEqualForMappingKey(lhs.tag, rhs.tag) and std.mem.eql(u8, lhs.value, rhs.value);
}

fn sequenceNodesEqualForMappingKey(lhs: SequenceNode, rhs: SequenceNode, depth: usize) bool {
    if (!tagsEqualForMappingKey(lhs.tag, rhs.tag, "tag:yaml.org,2002:seq")) return false;
    if (lhs.items.len != rhs.items.len) return false;

    for (lhs.items, rhs.items) |lhs_item, rhs_item| {
        if (!nodesEqualForMappingKey(lhs_item, rhs_item, depth)) return false;
    }
    return true;
}

fn mappingNodesEqualForMappingKey(lhs: MappingNode, rhs: MappingNode, depth: usize) bool {
    if (!tagsEqualForMappingKey(lhs.tag, rhs.tag, "tag:yaml.org,2002:map")) return false;
    if (lhs.pairs.len != rhs.pairs.len) return false;

    for (lhs.pairs) |lhs_pair| {
        if (matchingPairCount(lhs.pairs, lhs_pair, depth) != matchingPairCount(rhs.pairs, lhs_pair, depth)) return false;
    }
    return true;
}

fn matchingPairCount(pairs: []const MappingPair, target: MappingPair, depth: usize) usize {
    var count: usize = 0;
    for (pairs) |pair| {
        if (nodesEqualForMappingKey(pair.key, target.key, depth) and
            nodesEqualForMappingKey(pair.value, target.value, depth))
        {
            count += 1;
        }
    }
    return count;
}

fn scalarTagsEqualForMappingKey(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    return tagsEqualForMappingKey(lhs, rhs, "tag:yaml.org,2002:str");
}

fn tagsEqualForMappingKey(lhs: ?[]const u8, rhs: ?[]const u8, standard_tag: []const u8) bool {
    const lhs_tag = resolvedMappingKeyTag(lhs, standard_tag);
    const rhs_tag = resolvedMappingKeyTag(rhs, standard_tag);
    return std.mem.eql(u8, lhs_tag, rhs_tag);
}

fn resolvedMappingKeyTag(tag: ?[]const u8, standard_tag: []const u8) []const u8 {
    const tag_value = tag orelse return standard_tag;
    if (std.mem.eql(u8, tag_value, "!")) return standard_tag;
    return tag_value;
}

test {
    std.testing.refAllDecls(@This());
}

test "loader duplicate key: normalizes standard scalar tags" {
    const first = Node{ .scalar = .{ .value = "same" } };
    const second = Node{ .scalar = .{ .value = "same", .tag = "!" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try std.testing.expectError(ParseError.InvalidSyntax, validateUniqueMappingKeys(std.testing.allocator, &pairs));
}

test "loader duplicate key: rejects duplicate ordered map keys" {
    const first_key = Node{ .scalar = .{ .value = "same" } };
    const second_key = Node{ .scalar = .{ .value = "same", .tag = "!" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const first_pairs = [_]MappingPair{.{ .key = &first_key, .value = &value_node }};
    const second_pairs = [_]MappingPair{.{ .key = &second_key, .value = &value_node }};
    const first_item = Node{ .mapping = .{ .pairs = &first_pairs } };
    const second_item = Node{ .mapping = .{ .pairs = &second_pairs } };
    const items = [_]*const Node{ &first_item, &second_item };

    try std.testing.expectError(ParseError.InvalidSyntax, validateUniqueOrderedMapKeys(&items));
}

test "loader duplicate key: keeps non-standard scalar tags distinct" {
    const first = Node{ .scalar = .{ .value = "same", .tag = "!first" } };
    const second = Node{ .scalar = .{ .value = "same", .tag = "!second" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try validateUniqueMappingKeys(std.testing.allocator, &pairs);
}

test "loader duplicate key: string scalar fast path validates standard keys" {
    const first = Node{ .scalar = .{ .value = "first" } };
    const second = Node{ .scalar = .{ .value = "second", .tag = "!" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try std.testing.expectEqual(StringScalarKeyValidation.validated, try validateUniqueStringScalarMappingKeys(std.testing.allocator, &pairs));
}

test "loader duplicate key: string scalar fast path falls back for complex keys" {
    const item = Node{ .scalar = .{ .value = "item" } };
    const items = [_]*const Node{&item};
    const sequence = Node{ .sequence = .{ .items = &items } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &sequence, .value = &value_node },
    };

    try std.testing.expectEqual(StringScalarKeyValidation.fallback, try validateUniqueStringScalarMappingKeys(std.testing.allocator, &pairs));
}

test "loader duplicate key: compares alias names" {
    const first = Node{ .alias = "anchor" };
    const second = Node{ .alias = "anchor" };
    const third = Node{ .alias = "other" };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const duplicate_pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };
    const distinct_pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &third, .value = &value_node },
    };

    try std.testing.expectError(ParseError.InvalidSyntax, validateUniqueMappingKeys(std.testing.allocator, &duplicate_pairs));
    try validateUniqueMappingKeys(std.testing.allocator, &distinct_pairs);
}

test "loader duplicate key: treats NaN floats as equal" {
    const first = Node{ .float_value = .{ .value = std.math.nan(f64) } };
    const second = Node{ .float_value = .{ .value = std.math.nan(f64), .tag = "!" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try std.testing.expectError(ParseError.InvalidSyntax, validateUniqueMappingKeys(std.testing.allocator, &pairs));
}

test "loader duplicate key: compares mapping keys independent of pair order" {
    const key_a = Node{ .scalar = .{ .value = "a" } };
    const key_b = Node{ .scalar = .{ .value = "b" } };
    const value_a = Node{ .int_value = .{ .value = 1 } };
    const value_b = Node{ .int_value = .{ .value = 2 } };
    const mapping_pairs_a = [_]MappingPair{
        .{ .key = &key_a, .value = &value_a },
        .{ .key = &key_b, .value = &value_b },
    };
    const mapping_pairs_b = [_]MappingPair{
        .{ .key = &key_b, .value = &value_b },
        .{ .key = &key_a, .value = &value_a },
    };
    const first = Node{ .mapping = .{ .pairs = &mapping_pairs_a } };
    const second = Node{ .mapping = .{ .pairs = &mapping_pairs_b, .tag = "!" } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try std.testing.expectError(ParseError.InvalidSyntax, validateUniqueMappingKeys(std.testing.allocator, &pairs));
}

test "loader duplicate key: compares nested mapping pair multiplicity" {
    const key_a = Node{ .scalar = .{ .value = "a" } };
    const key_b = Node{ .scalar = .{ .value = "b" } };
    const value_1 = Node{ .int_value = .{ .value = 1 } };
    const value_2 = Node{ .int_value = .{ .value = 2 } };
    const mapping_pairs_a = [_]MappingPair{
        .{ .key = &key_a, .value = &value_1 },
        .{ .key = &key_a, .value = &value_1 },
    };
    const mapping_pairs_b = [_]MappingPair{
        .{ .key = &key_a, .value = &value_1 },
        .{ .key = &key_b, .value = &value_2 },
    };
    const first = Node{ .mapping = .{ .pairs = &mapping_pairs_a } };
    const second = Node{ .mapping = .{ .pairs = &mapping_pairs_b } };
    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &first, .value = &value_node },
        .{ .key = &second, .value = &value_node },
    };

    try validateUniqueMappingKeys(std.testing.allocator, &pairs);
}

test "loader duplicate key: depth guard keeps excessive nested keys distinct" {
    const depth = max_node_compare_depth + 1;
    var nodes_a = try std.testing.allocator.alloc(Node, depth + 1);
    defer std.testing.allocator.free(nodes_a);
    var nodes_b = try std.testing.allocator.alloc(Node, depth + 1);
    defer std.testing.allocator.free(nodes_b);
    var items_a = try std.testing.allocator.alloc(*const Node, depth);
    defer std.testing.allocator.free(items_a);
    var items_b = try std.testing.allocator.alloc(*const Node, depth);
    defer std.testing.allocator.free(items_b);

    nodes_a[depth] = .{ .scalar = .{ .value = "leaf" } };
    nodes_b[depth] = .{ .scalar = .{ .value = "leaf" } };
    var index = depth;
    while (index > 0) {
        index -= 1;
        items_a[index] = &nodes_a[index + 1];
        items_b[index] = &nodes_b[index + 1];
        nodes_a[index] = .{ .sequence = .{ .items = items_a[index .. index + 1] } };
        nodes_b[index] = .{ .sequence = .{ .items = items_b[index .. index + 1] } };
    }

    const value_node = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]MappingPair{
        .{ .key = &nodes_a[0], .value = &value_node },
        .{ .key = &nodes_b[0], .value = &value_node },
    };

    try validateUniqueMappingKeys(std.testing.allocator, &pairs);
}
