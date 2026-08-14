//! Purpose: Define the untyped YAML representation graph built from parser events.
//! Owns: Composer graph node, sequence, mapping, scalar, and mapping-pair payload types.
//! Does not own: Parser events, schema resolution, public value construction, or emission.
//! Depends on: parser/event.zig.
//! Tested by: tests/unit/compose/composer_test.zig.

const event = @import("../parser/event.zig");

pub const CollectionStyle = event.CollectionStyle;
pub const ScalarStyle = event.ScalarStyle;

/// Untyped scalar node in the YAML representation graph.
///
/// String slices borrow from parser events; the graph must not outlive its
/// source event stream.
pub const ScalarNode = struct {
    /// Decoded scalar value borrowed from the parser event stream.
    value: []const u8,
    /// Source presentation style.
    style: ScalarStyle = .plain,
    /// Optional anchor name borrowed from the parser event stream.
    anchor: ?[]const u8 = null,
    /// Optional tag borrowed from the parser event stream.
    tag: ?[]const u8 = null,
};

/// Key/value pair in an untyped representation mapping.
pub const MappingPair = struct {
    /// Mapping key node.
    key: *const Node,
    /// Mapping value node.
    value: *const Node,
};

/// Untyped sequence node in the YAML representation graph.
///
/// String slices borrow from parser events; the graph must not outlive its
/// source event stream.
pub const SequenceNode = struct {
    /// Sequence item nodes, in source order.
    items: []const *const Node,
    /// Source presentation style.
    style: CollectionStyle = .block,
    /// Optional anchor name borrowed from the parser event stream.
    anchor: ?[]const u8 = null,
    /// Optional tag borrowed from the parser event stream.
    tag: ?[]const u8 = null,
};

/// Untyped mapping node in the YAML representation graph.
///
/// String slices borrow from parser events; the graph must not outlive its
/// source event stream.
pub const MappingNode = struct {
    /// Mapping pairs, in source order.
    pairs: []const MappingPair,
    /// Source presentation style.
    style: CollectionStyle = .block,
    /// Optional anchor name borrowed from the parser event stream.
    anchor: ?[]const u8 = null,
    /// Optional tag borrowed from the parser event stream.
    tag: ?[]const u8 = null,
};

/// Untyped YAML representation graph node.
///
/// Aliases are resolved by the composer to point at anchored `Node` instances,
/// including recursive aliases that point back to an ancestor node.
pub const Node = union(enum) {
    /// Scalar node before schema construction.
    scalar: ScalarNode,
    /// Sequence node before schema construction.
    sequence: SequenceNode,
    /// Mapping node before schema construction.
    mapping: MappingNode,
};
