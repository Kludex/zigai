//! Purpose: Define public YAML parse and load options plus option re-exports.
//! Owns: Stable parse/load/emit/dump option structs and public option re-exports.
//! Does not own: Parser, loader, schema, or emitter implementation.
//! Depends on: api/diagnostics.zig, loader/options.zig, schema/schema.zig.
//! Tested by: public API, conformance, stress, and emitter tests.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const loader_options = @import("../loader/options.zig");
const schema = @import("../schema/schema.zig");

/// YAML 1.2.2 recommended schemas for loader scalar resolution.
pub const Schema = schema.Schema;

/// Controls how the loader handles duplicate mapping keys.
pub const DuplicateKeyBehavior = loader_options.DuplicateKeyBehavior;

/// Controls how the loader handles local or otherwise unrecognized tags.
pub const UnknownTagBehavior = loader_options.UnknownTagBehavior;

/// Options controlling YAML event emission.
pub const EmitOptions = struct {
    /// Preserve a top-level flow mapping's style instead of emitting the
    /// yaml-test-suite canonical block mapping form.
    preserve_top_level_flow_mapping_style: bool = false,
    /// Preserve flow mapping style for block-sequence items instead of using
    /// the yaml-test-suite compact block mapping form.
    preserve_block_sequence_flow_mapping_style: bool = false,
    /// Preserve flow collection styles in emitted event streams. Disable this
    /// for canonical output that normalizes collections to block style.
    preserve_collection_style: bool = true,
    /// Preserve `%TAG` directives that are present on document-start events even
    /// when no emitted node uses the declared handle.
    preserve_unused_tag_directives: bool = false,
    /// Do not add an implicit `---` before simple top-level block mappings.
    omit_redundant_document_start: bool = false,
    /// Reject output longer than this many bytes.
    max_output_bytes: ?usize = null,
};

/// Options controlling YAML document dumping.
pub const DumpOptions = struct {
    /// Preserve a top-level flow mapping's style instead of emitting it as a
    /// block mapping. This is the default for constructed document dumping.
    preserve_top_level_flow_mapping_style: bool = true,
    /// Preserve flow mapping style for block-sequence items instead of using
    /// the yaml-test-suite compact block mapping form.
    preserve_block_sequence_flow_mapping_style: bool = false,
    /// Preserve flow collection styles in dumped node graphs. Disable this for
    /// canonical output that normalizes collections to block style.
    preserve_collection_style: bool = true,
    /// Do not add an implicit `---` before simple top-level block mappings.
    omit_redundant_document_start: bool = false,
    /// Reject output longer than this many bytes.
    max_output_bytes: ?usize = null,
};

/// Options controlling YAML event parsing.
pub const ParseOptions = struct {
    /// Reject inputs longer than this many bytes before scanning.
    max_input_bytes: ?usize = null,
    /// Reject streams that produce more parser events than this count.
    max_event_count: ?usize = null,
    /// Reject streams that produce more scanner tokens than this count.
    max_token_count: ?usize = null,
    /// Reject streams whose collection nesting exceeds this depth.
    max_nesting_depth: ?usize = null,
    /// Reject decoded scalar values longer than this many bytes.
    max_scalar_bytes: ?usize = null,
    /// Optional diagnostic populated when parsing fails.
    diagnostic: ?*diagnostics.Diagnostic = null,
};

/// Options controlling YAML document loading.
pub const LoadOptions = struct {
    /// Schema used to resolve untagged plain scalars.
    schema: Schema = .core,
    /// Duplicate mapping key handling policy.
    duplicate_key_behavior: DuplicateKeyBehavior = .reject,
    /// Unknown/local tag handling policy.
    unknown_tag_behavior: UnknownTagBehavior = .preserve,
    /// Reject inputs longer than this many bytes before scanning.
    max_input_bytes: ?usize = null,
    /// Reject streams that contain more alias nodes than this count.
    max_alias_count: ?usize = null,
    /// Reject streams whose resolved aliases would expand to more graph nodes
    /// than this count if aliases were materialized by a consumer.
    max_alias_expansion: ?usize = null,
    /// Reject streams that contain more documents than this count.
    max_document_count: ?usize = null,
    /// Reject streams that produce more parser events than this count.
    max_event_count: ?usize = null,
    /// Reject streams that produce more scanner tokens than this count.
    max_token_count: ?usize = null,
    /// Reject streams whose collection nesting exceeds this depth.
    max_nesting_depth: ?usize = null,
    /// Reject decoded scalar values longer than this many bytes.
    max_scalar_bytes: ?usize = null,
    /// Optional diagnostic populated when parsing fails before loading.
    diagnostic: ?*diagnostics.Diagnostic = null,
};

test {
    std.testing.refAllDecls(@This());
}
