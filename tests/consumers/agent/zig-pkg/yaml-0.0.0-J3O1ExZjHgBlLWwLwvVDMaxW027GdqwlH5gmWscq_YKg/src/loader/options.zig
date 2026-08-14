//! Purpose: Define loader-owned construction policy options.
//! Owns: Duplicate-key and unknown-tag behavior enums used by loader internals and public options.
//! Does not own: Public aggregate load options, schema selection, parser limits, or diagnostics.
//! Depends on: std only.
//! Tested by: tests/unit/api/root_api_test.zig and tests/structure/api_boundary_test.zig.

const std = @import("std");

/// Controls how the loader handles duplicate mapping keys.
pub const DuplicateKeyBehavior = enum {
    /// Reject duplicate mapping keys after schema resolution.
    reject,
    /// Preserve duplicate mapping pairs in source order.
    allow,
};

/// Controls how the loader handles local or otherwise unrecognized tags.
pub const UnknownTagBehavior = enum {
    /// Preserve unknown tag metadata on loaded nodes.
    preserve,
    /// Reject unknown tags while accepting standard YAML tags and `!`.
    reject,
};

test {
    std.testing.refAllDecls(@This());
}
