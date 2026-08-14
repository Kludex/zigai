//! Purpose: Aggregate focused parser-layer unit-test shards.
//! Owns: Importing parser token and parser diagnostic regression modules into the build step.
//! Does not own: Individual parser behavior assertions.
//! Depends on: consolidated parser feature tests.
//! Tested by: zig build test-unit.

comptime {
    _ = @import("document_test.zig");
    _ = @import("block_sequence_test.zig");
    _ = @import("block_mapping_test.zig");
    _ = @import("flow_test.zig");
    _ = @import("scalar_test.zig");
    _ = @import("diagnostics_test.zig");
}
