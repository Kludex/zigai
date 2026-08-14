//! Purpose: Aggregate focused public root API unit-test shards.
//! Owns: Importing root API regression modules into the build step.
//! Does not own: Individual public API behavior assertions.
//! Depends on: tests/unit/api/*_test.zig.
//! Tested by: zig build test-unit.

comptime {
    _ = @import("parse_test.zig");
    _ = @import("load_test.zig");
    _ = @import("load_memory_test.zig");
    _ = @import("tags_test.zig");
    _ = @import("emit_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("limits_test.zig");
    _ = @import("dump_test.zig");
    _ = @import("typed_test.zig");
}

const std = @import("std");
const yaml = @import("yaml");

test "public value graph type sizes stay stable" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(yaml.Node));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(yaml.ScalarNode));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(yaml.NullNode));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(yaml.BoolNode));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(yaml.IntNode));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(yaml.FloatNode));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(yaml.MappingPair));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(yaml.SequenceNode));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(yaml.MappingNode));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(yaml.LoadedDocument));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(yaml.LoadedStream));
}
