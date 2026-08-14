//! Purpose: Define shared YAML safety-limit constants.
//! Owns: Hard internal limits that protect parser and emitter recursion.
//! Does not own: Public option structs, event-stream limit checks, or diagnostics.
//! Depends on: std.
//! Tested by: tests/structure/source_size_test.zig and parser/emitter tests.

const std = @import("std");

/// Default public nesting budget used when callers do not configure one.
pub const default_parse_collection_depth: usize = 256;

/// Hard internal parser recursion guard for configured deep documents.
pub const max_parse_collection_depth: usize = 1024;

/// Maximum nested collection depth emitted from parser events.
pub const max_emit_collection_depth: usize = 256;

test {
    std.testing.refAllDecls(@This());
}

test "common limit: parser and emitter depth caps are positive" {
    try std.testing.expect(default_parse_collection_depth > 0);
    try std.testing.expect(max_parse_collection_depth >= default_parse_collection_depth);
    try std.testing.expect(max_emit_collection_depth > 0);
}
