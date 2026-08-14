//! Purpose: Enforce AGENTS file-size guardrails for unit-test regression shards.
//! Owns: Unit-test line-count checks for focused parser, scanner, schema, and API shards.
//! Does not own: Source implementation, docs, conformance, stress, or allocation checks.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const SourceFile = support.SourceFile;

test "structure: flow parser regression shards stay consolidated" {
    const files = [_]SourceFile{
        .{ .path = "tests/unit/parser/flow_test.zig", .max_lines = 1200 },
    };

    try support.expectLineLimits(&files);
}

test "structure: unit regression tests stay split by feature" {
    const files = [_]SourceFile{
        .{ .path = "tests/unit/scanner/scanner_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/support.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/document_flow_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/scalar_property_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/indent_sequence_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/encoding_character_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/document_start_encoding_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/scanner/scanner/block_scalar_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/parser/parser_tokens_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/parser/support.zig", .max_lines = 600 },
        .{ .path = "tests/unit/parser/document_test.zig", .max_lines = 900 },
        .{ .path = "tests/unit/parser/scalar_test.zig", .max_lines = 1000 },
        .{ .path = "tests/unit/parser/block_sequence_test.zig", .max_lines = 2200 },
        .{ .path = "tests/unit/parser/block_mapping_test.zig", .max_lines = 3000 },
        .{ .path = "tests/unit/parser/diagnostics_test.zig", .max_lines = 1200 },
        .{ .path = "tests/unit/parser/flow_test.zig", .max_lines = 1200 },
        .{ .path = "tests/unit/loader/loader_test.zig", .max_lines = 140 },
        .{ .path = "tests/unit/loader/direct_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/schema/schema_test.zig", .max_lines = 300 },
        .{ .path = "tests/unit/api/root_api_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/api/support.zig", .max_lines = 600 },
        .{ .path = "tests/unit/api/load_string_ownership_test.zig", .max_lines = 180 },
        .{ .path = "tests/unit/api/load_memory_test.zig", .max_lines = 160 },
        .{ .path = "tests/unit/api/load_test.zig", .max_lines = 900 },
        .{ .path = "tests/unit/api/tags_test.zig", .max_lines = 2000 },
        .{ .path = "tests/unit/api/emit_test.zig", .max_lines = 2700 },
        .{ .path = "tests/unit/api/parse_test.zig", .max_lines = 3000 },
        .{ .path = "tests/unit/api/diagnostics_test.zig", .max_lines = 900 },
        .{ .path = "tests/unit/api/dump_test.zig", .max_lines = 700 },
        .{ .path = "tests/unit/api/limits_test.zig", .max_lines = 600 },
        .{ .path = "tests/unit/api/typed_test.zig", .max_lines = 900 },
    };

    try support.expectLineLimits(&files);
}
