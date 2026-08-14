//! Purpose: Enforce AGENTS source and test file size guardrails.
//! Owns: Executable line-count checks for focused files.
//! Does not own: API boundary, docs, or module-comment checks.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const SourceFile = support.SourceFile;

test "structure: event emitter implementation files stay below AGENTS ceiling" {
    const files = [_]SourceFile{
        .{ .path = "src/emitter/emitter.zig", .max_lines = 1500 },
        .{ .path = "src/emitter/flow.zig", .max_lines = 600 },
        .{ .path = "src/emitter/block.zig", .max_lines = 1200 },
    };

    try support.expectLineLimits(&files);
}

test "structure: structure checks stay split into focused test files" {
    const files = [_]SourceFile{
        .{ .path = "tests/structure/file_size_test.zig", .max_lines = 80 },
        .{ .path = "tests/structure/source_size_test.zig", .max_lines = 250 },
        .{ .path = "tests/structure/unit_size_test.zig", .max_lines = 180 },
        .{ .path = "tests/structure/api_boundary_test.zig", .max_lines = 240 },
        .{ .path = "tests/structure/docs_tooling_test.zig", .max_lines = 140 },
        .{ .path = "tests/structure/module_comment_test.zig", .max_lines = 100 },
        .{ .path = "tests/structure/support.zig", .max_lines = 120 },
    };

    try support.expectLineLimits(&files);
}

test "structure: remaining implementation files stay below split-consideration threshold" {
    const files = [_]SourceFile{
        .{ .path = "src/emitter/block.zig", .max_lines = 1200 },
        .{ .path = "src/parser/block_sequence.zig", .max_lines = 1200 },
        .{ .path = "src/parser/diagnostics.zig", .max_lines = 1500 },
    };

    try support.expectLineLimits(&files);
}

test "structure: common modules stay focused" {
    const files = [_]SourceFile{
        .{ .path = "src/common/diagnostic.zig", .max_lines = 80 },
        .{ .path = "src/common/location.zig", .max_lines = 80 },
        .{ .path = "src/common/limit.zig", .max_lines = 80 },
    };

    try support.expectLineLimits(&files);
}

test "structure: API diagnostic policy stays focused" {
    const files = [_]SourceFile{
        .{ .path = "src/api/diagnostic_policy.zig", .max_lines = 180 },
    };

    try support.expectLineLimits(&files);
}

test "structure: scalar emitter stays consolidated and bounded" {
    const files = [_]SourceFile{
        .{ .path = "src/emitter/scalar.zig", .max_lines = 1200 },
    };

    try support.expectLineLimits(&files);
}

test "structure: value graph payloads stay cohesive" {
    const files = [_]SourceFile{
        .{ .path = "src/value/value.zig", .max_lines = 500 },
    };

    try support.expectLineLimits(&files);
    try support.expectRepoFilesAbsent(&.{
        "src/value/scalar.zig",
        "src/value/sequence.zig",
        "src/value/mapping.zig",
        "src/value/document.zig",
        "src/value/stream.zig",
        "src/value/deinit.zig",
    });
}

test "structure: parser diagnostics stay consolidated" {
    const files = [_]SourceFile{
        .{ .path = "src/parser/diagnostics.zig", .max_lines = 1500 },
    };

    try support.expectLineLimits(&files);
}

test "structure: schema stays in final Phase 4 shape" {
    const files = [_]SourceFile{
        .{ .path = "src/schema/schema.zig", .max_lines = 400 },
        .{ .path = "src/schema/scalars.zig", .max_lines = 800 },
        .{ .path = "src/schema/tag.zig", .max_lines = 260 },
    };

    try support.expectLineLimits(&files);
}

test "structure: scanner state machine stays split by concern" {
    const files = [_]SourceFile{
        .{ .path = "src/scanner/scanner.zig", .max_lines = 800 },
        .{ .path = "src/scanner/lex.zig", .max_lines = 400 },
        .{ .path = "src/scanner/scalar.zig", .max_lines = 300 },
        .{ .path = "src/scanner/block_scalar.zig", .max_lines = 300 },
    };

    try support.expectLineLimits(&files);
}

test "structure: reader preparation stays split by concern" {
    const files = [_]SourceFile{
        .{ .path = "src/reader/reader.zig", .max_lines = 180 },
        .{ .path = "src/reader/encoding.zig", .max_lines = 180 },
        .{ .path = "src/reader/line_break.zig", .max_lines = 120 },
    };

    try support.expectLineLimits(&files);
}

test "structure: direct token parser is split into feature modules" {
    const files = [_]SourceFile{
        .{ .path = "src/parser/parser.zig", .max_lines = 600 },
        .{ .path = "src/parser/event.zig", .max_lines = 140 },
        .{ .path = "src/parser/block_sequence.zig", .max_lines = 1200 },
        .{ .path = "src/parser/block_mapping.zig", .max_lines = 1800 },
        .{ .path = "src/parser/simple_fast_path.zig", .max_lines = 600 },
        .{ .path = "src/parser/document.zig", .max_lines = 600 },
        .{ .path = "src/parser/internal.zig", .max_lines = 1200 },
        .{ .path = "src/parser/scalar.zig", .max_lines = 1500 },
        .{ .path = "src/parser/flow.zig", .max_lines = 600 },
        .{ .path = "src/parser/diagnostics.zig", .max_lines = 1500 },
        .{ .path = "src/parser/tag.zig", .max_lines = 600 },
    };

    try support.expectLineLimits(&files);
}

test "structure: consolidated block mapping parser stays bounded" {
    const files = [_]SourceFile{
        .{ .path = "src/parser/block_mapping.zig", .max_lines = 1800 },
    };

    try support.expectLineLimits(&files);
}

test "structure: conformance harness is split into focused modules" {
    const files = [_]SourceFile{
        .{ .path = "tests/conformance/yaml_suite_runner.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/direct_conformance.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/suite_cases.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/event_compare.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/json_compare.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/output_compare.zig", .max_lines = 600 },
        .{ .path = "tests/conformance/skips.zig", .max_lines = 300 },
    };

    try support.expectLineLimits(&files);
}

test "structure: stress and allocation tests stay split by concern" {
    const files = [_]SourceFile{
        .{ .path = "tests/stress/stress.zig", .max_lines = 120 },
        .{ .path = "tests/stress/support.zig", .max_lines = 180 },
        .{ .path = "tests/stress/large_file_test.zig", .max_lines = 220 },
        .{ .path = "tests/stress/deep_nesting_test.zig", .max_lines = 220 },
        .{ .path = "tests/stress/alias_limit_test.zig", .max_lines = 220 },
        .{ .path = "tests/stress/configured_limit_test.zig", .max_lines = 260 },
        .{ .path = "tests/allocation/allocation_test.zig", .max_lines = 120 },
        .{ .path = "tests/allocation/failure_injection_test.zig", .max_lines = 300 },
    };

    try support.expectLineLimits(&files);
}

test "structure: loader coordinator stays focused" {
    const files = [_]SourceFile{
        .{ .path = "src/loader/loader.zig", .max_lines = 180 },
    };

    try support.expectLineLimits(&files);
}

test "structure: compose coordinator stays focused" {
    const files = [_]SourceFile{
        .{ .path = "src/compose/composer.zig", .max_lines = 260 },
    };

    try support.expectLineLimits(&files);
}
