//! Purpose: Aggregate allocation-failure test shards.
//! Owns: Importing allocation regression modules into the build step.
//! Does not own: Individual allocation behavior assertions.
//! Depends on: tests/allocation/*.zig.
//! Tested by: zig build test-allocation.

comptime {
    _ = @import("failure_injection_test.zig");
    _ = @import("hot_path_test.zig");
}
