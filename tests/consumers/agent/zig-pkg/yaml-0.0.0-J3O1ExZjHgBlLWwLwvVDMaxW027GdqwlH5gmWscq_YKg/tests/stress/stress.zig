//! Purpose: Aggregate focused stress-test shards.
//! Owns: Importing stress regression modules into the build step.
//! Does not own: Individual stress behavior assertions or allocation-failure tests.
//! Depends on: tests/stress/*.zig.
//! Tested by: zig build test-stress.

comptime {
    _ = @import("large_file_test.zig");
    _ = @import("deep_nesting_test.zig");
    _ = @import("alias_limit_test.zig");
    _ = @import("configured_limit_test.zig");
}
