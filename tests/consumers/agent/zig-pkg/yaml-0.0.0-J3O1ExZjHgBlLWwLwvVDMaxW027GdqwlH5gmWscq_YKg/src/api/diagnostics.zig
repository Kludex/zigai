//! Purpose: Public diagnostics API facade.
//! Owns: Stable re-exports for diagnostics and shared public error sets.
//! Does not own: Diagnostic construction, parser recovery, or layer-specific error handling.
//! Depends on: common/diagnostic.zig.
//! Tested by: tests/unit/api/root_api_test.zig and stress tests.

const std = @import("std");
const impl = @import("../common/diagnostic.zig");

pub const ParseError = impl.ParseError;
pub const Error = impl.Error;
pub const WriteError = impl.WriteError;
pub const Diagnostic = impl.Diagnostic;

test {
    std.testing.refAllDecls(@This());
}
