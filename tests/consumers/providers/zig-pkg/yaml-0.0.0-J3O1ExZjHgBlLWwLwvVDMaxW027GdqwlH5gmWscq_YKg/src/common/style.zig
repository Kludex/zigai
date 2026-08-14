//! Purpose: Define shared YAML presentation style enums.
//! Owns: Public scalar and collection style tags used across parser, value, and emitter layers.
//! Does not own: Event payloads, loaded values, or emission decisions.
//! Depends on: std only.
//! Tested by: public API, parser, loader, and emitter tests.

const std = @import("std");

/// YAML collection presentation style.
pub const CollectionStyle = enum {
    /// Indentation-based block collection style.
    block,
    /// Bracket/brace-delimited flow collection style.
    flow,
};

/// YAML scalar presentation style.
pub const ScalarStyle = enum {
    /// Plain unquoted scalar style.
    plain,
    /// Single-quoted scalar style.
    single_quoted,
    /// Double-quoted scalar style.
    double_quoted,
    /// Literal block scalar style (`|`).
    literal,
    /// Folded block scalar style (`>`).
    folded,
};

test {
    std.testing.refAllDecls(@This());
}
