//! Purpose: Classify loader-stage failures for public diagnostics.
//! Owns: Stable internal failure categories shared by loader and constructor layers.
//! Does not own: Diagnostic formatting, parser errors, composition, or duplicate-key comparison.
//! Depends on: std only.
//! Tested by: tests/unit/api/root_api/load_diagnostic_test.zig.

/// Loader-stage failure categories used to choose public diagnostic messages.
pub const LoadFailure = enum {
    /// A loader/composer error occurred before a more specific category was set.
    unknown,
    /// The stream contains more documents than the configured limit.
    document_count_limit,
    /// The stream contains more aliases than the configured limit.
    alias_count_limit,
    /// The stream exceeds the configured materialized alias-expansion budget.
    alias_expansion_limit,
    /// The event stream cannot be composed into a well-formed representation graph.
    invalid_graph,
    /// A standard YAML tag was applied to an incompatible node kind.
    invalid_standard_tag,
    /// A recognized scalar tag carried invalid scalar content.
    invalid_scalar_tag,
    /// The configured loader policy rejected an unknown/local tag.
    unknown_tag,
    /// A mapping contains duplicate keys under the configured policy.
    duplicate_key,
};
