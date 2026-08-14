//! Purpose: Define the public loaded YAML value graph.
//! Owns: Node union, payload structs, and loaded-value ownership containers.
//! Does not own: Loading, schema rules, duplicate-key semantics, or emitting.
//! Depends on: common/style.zig and std heap arena allocator.
//! Tested by: loader, public API, conformance, stress, and emitter tests.

const std = @import("std");
const style = @import("../common/style.zig");

pub const CollectionStyle = style.CollectionStyle;
pub const ScalarStyle = style.ScalarStyle;

/// String scalar node in a loaded YAML representation graph.
pub const ScalarNode = struct {
    /// Decoded scalar value.
    value: []const u8,
    /// Source presentation style.
    style: ScalarStyle = .plain,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const NullNode = struct {
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const BoolNode = struct {
    /// Resolved boolean value.
    value: bool,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const IntNode = struct {
    /// Resolved integer value.
    value: i128,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const FloatNode = struct {
    /// Resolved floating point value.
    value: f64,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

/// Key/value pair in a loaded mapping node.
pub const MappingPair = struct {
    /// Mapping key node.
    key: *const Node,
    /// Mapping value node.
    value: *const Node,
};

/// Sequence node in a loaded YAML representation graph.
pub const SequenceNode = struct {
    /// Sequence item nodes, in source order.
    items: []const *const Node,
    /// Source presentation style.
    style: CollectionStyle = .block,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

/// Mapping node in a loaded YAML representation graph.
pub const MappingNode = struct {
    /// Mapping pairs, in source order.
    pairs: []const MappingPair,
    /// Source presentation style.
    style: CollectionStyle = .block,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

/// Loaded YAML node.
///
/// Nodes are owned by a `LoadedDocument` or `LoadedStream` arena. Aliases are
/// resolved to anchored nodes while loading when possible; constructed alias
/// nodes can still be dumped.
pub const Node = union(enum) {
    /// YAML null value after schema resolution.
    null_value: NullNode,
    /// YAML boolean value after schema resolution.
    bool_value: BoolNode,
    /// YAML integer value after schema resolution.
    int_value: IntNode,
    /// YAML floating-point value after schema resolution.
    float_value: FloatNode,
    /// String scalar node.
    scalar: ScalarNode,
    /// Sequence node.
    sequence: SequenceNode,
    /// Mapping node.
    mapping: MappingNode,
    /// Constructed alias node naming an anchor.
    alias: []const u8,
};

pub const LoadedDocument = struct {
    /// Arena owning `root` and all loaded node data.
    arena: std.heap.ArenaAllocator,
    /// Root node of the single loaded document.
    root: *const Node,

    /// Releases all node data owned by this document.
    pub fn deinit(self: *LoadedDocument) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const LoadedStream = struct {
    /// Arena owning `documents` and all loaded node data.
    arena: std.heap.ArenaAllocator,
    /// Root nodes for all documents in the stream.
    documents: []const *const Node,

    /// Releases all node data owned by this stream.
    pub fn deinit(self: *LoadedStream) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
