//! Purpose: Enforce public/internal API boundaries from AGENTS.md.
//! Owns: Compatibility facade and forbidden-import structure checks.
//! Does not own: File-size, docs, or module-comment checks.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const std = support.std;

test "structure: public parser uses the scanner/token parser directly" {
    const source = try support.readRepoFile("src/api/parse.zig");
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "parser/source.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "parseEventsFromSource") == null);
}

test "structure: direct parser build and API avoid parser compatibility facade" {
    const parse_api_source = try support.readRepoFile("src/api/parse.zig");
    defer std.testing.allocator.free(parse_api_source);

    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    try std.testing.expect(std.mem.indexOf(u8, parse_api_source, "@import(\"../parser.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, ".root_source_file = b.path(\"src/parser.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, ".root_source_file = \"src/parser.zig\"") == null);
}

test "structure: duplicate root compatibility facade is removed" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    try std.testing.expect(std.mem.indexOf(u8, build_source, "src/root.zig") == null);
}

test "structure: implementation modules avoid root compatibility facades" {
    const forbidden_imports = [_][]const u8{
        "@import(\"../types.zig\")",
        "@import(\"../scanner.zig\")",
        "@import(\"../schema.zig\")",
        "@import(\"../parser.zig\")",
        "@import(\"../loader.zig\")",
        "@import(\"../encoding.zig\")",
    };

    try support.expectNoForbiddenImportsUnder("src", &forbidden_imports);
    try support.expectNoForbiddenImportsIn("src/lib.zig", &.{
        "@import(\"types.zig\")",
        "@import(\"scanner.zig\")",
        "@import(\"schema.zig\")",
        "@import(\"parser.zig\")",
        "@import(\"loader.zig\")",
        "@import(\"encoding.zig\")",
    });
    try support.expectNoForbiddenImportsIn("src/internal.zig", &.{
        "@import(\"types.zig\")",
        "@import(\"scanner.zig\")",
        "@import(\"schema.zig\")",
        "@import(\"parser.zig\")",
        "@import(\"loader.zig\")",
        "@import(\"encoding.zig\")",
    });
}

test "structure: parser internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/parser", &.{
        "@import(\"../api/",
    });
}

test "structure: block parser shards avoid parser hub imports" {
    try support.expectNoForbiddenImportsIn("src/parser/block_mapping.zig", &.{
        "@import(\"parser.zig\")",
    });
    try support.expectNoForbiddenImportsIn("src/parser/block_sequence.zig", &.{
        "@import(\"parser.zig\")",
    });
}

test "structure: loader internals avoid public aggregate type facade" {
    try support.expectNoForbiddenImportsUnder("src/loader", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: compose internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/compose", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: scanner feature modules avoid generic scanner mutation seams" {
    const scanner_feature_modules = [_][]const u8{
        "src/scanner/scalar.zig",
        "src/scanner/property.zig",
        "src/scanner/block_scalar.zig",
        "src/scanner/lex.zig",
    };

    for (scanner_feature_modules) |path| {
        try support.expectNoForbiddenImportsIn(path, &.{"scanner: anytype"});
    }
}

test "structure: loader construction imports compose graph directly" {
    try support.expectNoForbiddenImportsIn("src/loader/construct.zig", &.{
        "@import(\"../compose/node.zig\")",
    });
}

test "structure: loader scalar and tag construction policy is shared" {
    const direct_source = try support.readRepoFile("src/loader/direct.zig");
    defer std.testing.allocator.free(direct_source);

    const construct_source = try support.readRepoFile("src/loader/construct.zig");
    defer std.testing.allocator.free(construct_source);

    try support.expectContainsAll(direct_source, &.{
        "@import(\"construction_policy.zig\")",
    });
    try support.expectContainsAll(construct_source, &.{
        "@import(\"construction_policy.zig\")",
    });

    const adapter_policy_duplicates = [_][]const u8{
        "schema.resolveScalar(",
        "tag.validateStandardTagKind(",
        "tag.validateStandardBinaryContent(",
        "tag.validateStandardTimestampContent(",
    };
    try support.expectContainsNone(direct_source, &adapter_policy_duplicates);
    try support.expectContainsNone(construct_source, &adapter_policy_duplicates);
}

test "structure: strict simple loader uses shared construction policy" {
    const load_api_source = try support.readRepoFile("src/api/load.zig");
    defer std.testing.allocator.free(load_api_source);

    try support.expectContainsAll(load_api_source, &.{
        "@import(\"../loader/construction_policy.zig\")",
    });

    const strict_policy_duplicates = [_][]const u8{
        "@import(\"../loader/duplicate_key.zig\")",
        "@import(\"../schema/schema.zig\")",
        "@import(\"../schema/tag.zig\")",
        "schema.resolveScalar(",
        "schema_tag.validateStandardTagKind(",
        "schema_tag.validateStandardBinaryContent(",
        "schema_tag.validateStandardTimestampContent(",
        "duplicate_key.validateUniqueMappingKeys(",
    };
    try support.expectContainsNone(load_api_source, &strict_policy_duplicates);
}

test "structure: API entrypoints use diagnostic policy" {
    const parse_source = try support.readRepoFile("src/api/parse.zig");
    defer std.testing.allocator.free(parse_source);
    const load_source = try support.readRepoFile("src/api/load.zig");
    defer std.testing.allocator.free(load_source);

    try support.expectContainsAll(parse_source, &.{
        "@import(\"diagnostic_policy.zig\")",
    });
    try support.expectContainsAll(load_source, &.{
        "@import(\"diagnostic_policy.zig\")",
    });

    const inline_policy_duplicates = [_][]const u8{
        "@import(\"../common/diagnostic.zig\")",
        "@import(\"../parser/diagnostics.zig\")",
        "fn diagnosticAt",
        "fn setLimitDiagnostic",
        "fn setLoadFailureDiagnostic",
        "fn loadDiagnostic",
        "diagnosticForParseError",
        "common_diagnostic.atOffset",
    };
    try support.expectContainsNone(parse_source, &inline_policy_duplicates);
    try support.expectContainsNone(load_source, &inline_policy_duplicates);
}

test "structure: emitter internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/emitter", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: scalar emitter owns block scalar policy" {
    const scalar_source = try support.readRepoFile("src/emitter/scalar.zig");
    defer std.testing.allocator.free(scalar_source);
    const block_source = try support.readRepoFile("src/emitter/block.zig");
    defer std.testing.allocator.free(block_source);

    try support.expectContainsNone(scalar_source, &.{"@import(\"block.zig\")"});
    try support.expectContainsNone(block_source, &.{
        "pub fn scalarShouldUseQuotedBlockFallback",
        "pub fn blockScalarEndsWithWhitespaceOnlyContentLine",
        "pub fn blockScalarHasTrailingSpaceOnlyContentLine",
        "pub fn blockScalarHasLeadingTabIndentedLine",
        "pub fn blockScalarUsesKeepChomping",
        "pub fn blockScalarHasTabStartedLine",
        "pub fn appendLiteral",
        "pub fn appendFolded",
    });
}

test "structure: API entrypoints avoid aggregate public type facade" {
    const entrypoints = [_][]const u8{
        "src/api/parse.zig",
        "src/api/load.zig",
        "src/api/emit.zig",
    };

    for (entrypoints) |entrypoint| {
        try support.expectNoForbiddenImportsIn(entrypoint, &.{
            "@import(\"../api/types.zig\")",
            "@import(\"types.zig\")",
        });
    }
}
