//! Purpose: Compatibility facade for representation graph node imports.
//! Owns: Re-exporting compose/graph.zig for callers that still import compose/node.zig.
//! Does not own: Representation graph type definitions, parser events, schema resolution, public value construction, or emission.
//! Depends on: compose/graph.zig.
//! Tested by: tests/unit/compose/composer_test.zig.

const graph = @import("graph.zig");

pub const CollectionStyle = graph.CollectionStyle;
pub const ScalarStyle = graph.ScalarStyle;
pub const ScalarNode = graph.ScalarNode;
pub const MappingPair = graph.MappingPair;
pub const SequenceNode = graph.SequenceNode;
pub const MappingNode = graph.MappingNode;
pub const Node = graph.Node;
