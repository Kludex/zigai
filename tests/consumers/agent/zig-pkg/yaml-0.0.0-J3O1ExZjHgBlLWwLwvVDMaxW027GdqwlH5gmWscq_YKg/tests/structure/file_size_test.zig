//! Purpose: Aggregate focused repository structure checks.
//! Owns: Importing structure-test shards into the build step.
//! Does not own: Individual structure policy assertions.
//! Depends on: tests/structure/*.zig.
//! Tested by: zig build test-structure.

comptime {
    _ = @import("source_size_test.zig");
    _ = @import("unit_size_test.zig");
    _ = @import("api_boundary_test.zig");
    _ = @import("docs_tooling_test.zig");
    _ = @import("module_comment_test.zig");
}
