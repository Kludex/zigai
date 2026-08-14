//! Purpose: Build-only facade for tests that need internal YAML layers.
//! Owns: Re-exporting private modules to unit tests without adding them to the public package facade.
//! Does not own: Stable public API, implementation logic, or user-facing documentation.
//! Depends on: Internal layer modules under src/.
//! Tested by: tests/unit/reader/reader_test.zig and tests/unit/compose/composer_test.zig.

const std = @import("std");

pub const composer = @import("compose/composer.zig");
pub const load_api = @import("api/load.zig");
pub const loader = @import("loader/loader.zig");
pub const parser = @import("parser/api.zig");
pub const reader = @import("reader/reader.zig");
pub const schema = @import("schema/schema.zig");
pub const scanner = @import("scanner/scanner.zig");
pub const value = @import("value/value.zig");
pub const diagnostics = @import("parser/diagnostics.zig");
pub const source_diagnostic = diagnostics;
pub const source_diagnostic_chars = diagnostics;
pub const source_diagnostic_common = diagnostics;
pub const source_diagnostic_directive = diagnostics;
pub const source_diagnostic_encoding = diagnostics;
pub const source_diagnostic_indent = diagnostics;
pub const source_diagnostic_syntax = diagnostics;

pub const parseTokens = parser.parseTokens;
pub const types = parser.types;

test {
    std.testing.refAllDecls(@This());
}
