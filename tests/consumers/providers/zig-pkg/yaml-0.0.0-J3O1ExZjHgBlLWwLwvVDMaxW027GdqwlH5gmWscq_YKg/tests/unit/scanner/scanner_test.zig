//! Purpose: Aggregate focused scanner unit-test shards.
//! Owns: Importing scanner regression modules into the build step.
//! Does not own: Individual scanner behavior assertions.
//! Depends on: tests/unit/scanner/scanner/*.zig.
//! Tested by: zig build test-unit.

comptime {
    _ = @import("scanner/document_flow_test.zig");
    _ = @import("scanner/scalar_property_test.zig");
    _ = @import("scanner/indent_sequence_test.zig");
    _ = @import("scanner/compact_indicator_edge_test.zig");
    _ = @import("scanner/quote_context_edge_test.zig");
    _ = @import("scanner/encoding_character_test.zig");
    _ = @import("scanner/document_start_encoding_test.zig");
    _ = @import("scanner/block_scalar_test.zig");
}
