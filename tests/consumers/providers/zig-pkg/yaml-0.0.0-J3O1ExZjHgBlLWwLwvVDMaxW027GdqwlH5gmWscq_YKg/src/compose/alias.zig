//! Purpose: Enforce alias safety limits during YAML graph composition.
//! Owns: Alias event counting and bounded alias expansion-size calculation.
//! Does not own: Anchor lookup, node allocation, schema resolution, or public values.
//! Depends on: common/diagnostic.zig, compose/node.zig.
//! Tested by: tests/unit/compose/composer_test.zig and stress alias-limit tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const graph = @import("node.zig");

const Error = diagnostic.Error;
const Node = graph.Node;
const ParseError = diagnostic.ParseError;

/// Alias-related limits and counters for one composed stream.
pub const Limiter = struct {
    max_alias_count: ?usize = null,
    max_alias_expansion: ?usize = null,
    alias_count: usize = 0,
    alias_expansion_count: usize = 0,

    pub fn countAlias(self: *Limiter) ParseError!void {
        const limit = self.max_alias_count orelse return;

        if (self.alias_count >= limit) return ParseError.Unsupported;
        self.alias_count += 1;
    }

    pub fn countExpansion(
        self: *Limiter,
        allocator: std.mem.Allocator,
        node: *const Node,
        complete_nodes: *const std.AutoHashMapUnmanaged(*const Node, void),
    ) Error!void {
        const limit = self.max_alias_expansion orelse return;
        if (!complete_nodes.contains(node)) return ParseError.Unsupported;

        var stack: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
        defer stack.deinit(allocator);

        const expansion = try nodeExpansionSize(allocator, node, complete_nodes, &stack);
        if (expansion > limit) return ParseError.Unsupported;
        if (self.alias_expansion_count > limit - expansion) return ParseError.Unsupported;
        self.alias_expansion_count += expansion;
    }
};

fn nodeExpansionSize(
    allocator: std.mem.Allocator,
    node: *const Node,
    complete_nodes: *const std.AutoHashMapUnmanaged(*const Node, void),
    stack: *std.AutoHashMapUnmanaged(*const Node, void),
) Error!usize {
    if (!complete_nodes.contains(node)) return ParseError.Unsupported;
    if (stack.contains(node)) return ParseError.Unsupported;

    try stack.put(allocator, node, {});
    defer _ = stack.remove(node);

    var total: usize = 1;
    switch (node.*) {
        .scalar => {},
        .sequence => |sequence| {
            for (sequence.items) |item| {
                total = try addExpansionSize(total, try nodeExpansionSize(allocator, item, complete_nodes, stack));
            }
        },
        .mapping => |mapping| {
            for (mapping.pairs) |pair| {
                total = try addExpansionSize(total, try nodeExpansionSize(allocator, pair.key, complete_nodes, stack));
                total = try addExpansionSize(total, try nodeExpansionSize(allocator, pair.value, complete_nodes, stack));
            }
        },
    }
    return total;
}

fn addExpansionSize(lhs: usize, rhs: usize) ParseError!usize {
    if (rhs > std.math.maxInt(usize) - lhs) return ParseError.Unsupported;
    return lhs + rhs;
}

test {
    std.testing.refAllDecls(@This());
}

test "compose alias limiter: counts aliases up to configured limit" {
    var limiter = Limiter{ .max_alias_count = 2 };

    try limiter.countAlias();
    try limiter.countAlias();

    try std.testing.expectError(ParseError.Unsupported, limiter.countAlias());
    try std.testing.expectEqual(@as(usize, 2), limiter.alias_count);
}

test "compose alias limiter: counts bounded expansion size" {
    const scalar_a = Node{ .scalar = .{ .value = "a" } };
    const scalar_b = Node{ .scalar = .{ .value = "b" } };
    const items = [_]*const Node{ &scalar_a, &scalar_b };
    const sequence = Node{ .sequence = .{ .items = &items } };

    var complete_nodes: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
    defer complete_nodes.deinit(std.testing.allocator);
    try complete_nodes.put(std.testing.allocator, &scalar_a, {});
    try complete_nodes.put(std.testing.allocator, &scalar_b, {});
    try complete_nodes.put(std.testing.allocator, &sequence, {});

    var limiter = Limiter{ .max_alias_expansion = 3 };
    try limiter.countExpansion(std.testing.allocator, &sequence, &complete_nodes);

    try std.testing.expectEqual(@as(usize, 3), limiter.alias_expansion_count);
    try std.testing.expectError(ParseError.Unsupported, limiter.countExpansion(std.testing.allocator, &sequence, &complete_nodes));
    try std.testing.expectEqual(@as(usize, 3), limiter.alias_expansion_count);
}

test "compose alias limiter: counts mapping expansion size" {
    const scalar_key = Node{ .scalar = .{ .value = "key" } };
    const scalar_value = Node{ .scalar = .{ .value = "value" } };
    const pairs = [_]graph.MappingPair{.{ .key = &scalar_key, .value = &scalar_value }};
    const mapping = Node{ .mapping = .{ .pairs = &pairs } };

    var complete_nodes: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
    defer complete_nodes.deinit(std.testing.allocator);
    try complete_nodes.put(std.testing.allocator, &scalar_key, {});
    try complete_nodes.put(std.testing.allocator, &scalar_value, {});
    try complete_nodes.put(std.testing.allocator, &mapping, {});

    var limiter = Limiter{ .max_alias_expansion = 3 };
    try limiter.countExpansion(std.testing.allocator, &mapping, &complete_nodes);

    try std.testing.expectEqual(@as(usize, 3), limiter.alias_expansion_count);
}

test "compose alias limiter: rejects incomplete alias expansion targets" {
    const scalar = Node{ .scalar = .{ .value = "unfinished" } };

    var complete_nodes: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
    defer complete_nodes.deinit(std.testing.allocator);

    var limiter = Limiter{ .max_alias_expansion = 1 };
    try std.testing.expectError(ParseError.Unsupported, limiter.countExpansion(std.testing.allocator, &scalar, &complete_nodes));
    try std.testing.expectEqual(@as(usize, 0), limiter.alias_expansion_count);
}
