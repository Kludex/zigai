//! Purpose: Verify the schema resolver layer directly.
//! Owns: Focused failsafe, JSON, core, explicit-tag, and tag-kind assertions.
//! Does not own: Loader construction, duplicate-key behavior, or public API integration.
//! Depends on: yaml_internal schema facade.
//! Tested by: zig build test-schema.

const std = @import("std");
const internal = @import("yaml_internal");

const schema = internal.schema;

test "schema: failsafe leaves plain scalars unresolved" {
    try std.testing.expect((try schema.resolveScalar(.failsafe, "true", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.failsafe, "42", true, null)) == null);
}

test "schema: json accepts only JSON schema plain scalar spellings" {
    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.json, "null", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = true }, (try schema.resolveScalar(.json, "true", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = -12 }, (try schema.resolveScalar(.json, "-12", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 1.5 }, (try schema.resolveScalar(.json, "1.5", true, null)).?);

    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "True", true, null));
    try std.testing.expect((try schema.resolveScalar(.json, "True", false, null)) == null);
}

test "schema: core resolves YAML core scalar spellings" {
    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.core, "~", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = false }, (try schema.resolveScalar(.core, "FALSE", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 63 }, (try schema.resolveScalar(.core, "0o77", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 1000 }, (try schema.resolveScalar(.core, "1e3", true, null)).?);
}

test "schema: core helper predicates classify plain and null scalars" {
    try std.testing.expect(schema.resolvesAsCorePlainScalar("null"));
    try std.testing.expect(schema.resolvesAsCorePlainScalar("0x3A"));
    try std.testing.expect(schema.resolvesAsCorePlainScalar("0x3a"));
    try std.testing.expect(schema.resolvesAsCorePlainScalar(".Inf"));
    try std.testing.expect(!schema.resolvesAsCorePlainScalar("plain string"));

    try std.testing.expect(schema.isCoreNullScalar("", true, null));
    try std.testing.expect(schema.isCoreNullScalar("~", false, "tag:yaml.org,2002:null"));
    try std.testing.expect(!schema.isCoreNullScalar("~", false, null));
}

test "schema: explicit standard scalar tags validate spelling" {
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 42 }, (try schema.resolveScalar(.failsafe, "42", false, "tag:yaml.org,2002:int")).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = true }, (try schema.resolveScalar(.failsafe, "TRUE", false, "tag:yaml.org,2002:bool")).?);
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.core, "not-int", true, "tag:yaml.org,2002:int"));
}

test "schema: json rejects incomplete signed numbers" {
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "-", true, null));
}

test "schema: json rejects non-JSON number spellings" {
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "+1", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "01", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "1e", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "1e+", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, ".inf", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, ".nan", true, null));

    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 1 }, (try schema.resolveScalar(.json, "1.", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 100 }, (try schema.resolveScalar(.json, "1.e2", true, null)).?);
}

test "schema: core leaves YAML 1.1 boolean spellings as strings" {
    try std.testing.expect((try schema.resolveScalar(.core, "yes", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "No", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "ON", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "off", true, null)) == null);
}

test "schema: core leaves obvious non-reserved strings unresolved" {
    const values = [_][]const u8{
        "nullish",
        "truefalse",
        "FALSEhood",
        "plain-123",
        "version1.2",
        ".nanx",
        "+.infinity",
        "-not-a-number",
    };

    for (values) |value| {
        try std.testing.expect((try schema.resolveScalar(.core, value, true, null)) == null);
        try std.testing.expect(!schema.resolvesAsCorePlainScalar(value));
    }
}

test "schema: null bool and numeric boundaries remain exact" {
    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.core, "", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.core, "NULL", true, null)).?);
    try std.testing.expect((try schema.resolveScalar(.core, "NULLS", true, null)) == null);

    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = true }, (try schema.resolveScalar(.core, "True", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = false }, (try schema.resolveScalar(.core, "false", true, null)).?);
    try std.testing.expect((try schema.resolveScalar(.core, "false.", true, null)) == null);

    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 42 }, (try schema.resolveScalar(.core, "+42", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 0x1e3 }, (try schema.resolveScalar(.core, "0x1e3", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 1 }, (try schema.resolveScalar(.core, "1.", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 100 }, (try schema.resolveScalar(.core, "1.e2", true, null)).?);
    try std.testing.expect((try schema.resolveScalar(.core, "+", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "-", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, ".", true, null)) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "1e+", true, null)) == null);
}

test "schema: json reserved spellings and number boundaries remain exact" {
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "nullish", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "truefalse", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "-", true, null));
    try std.testing.expectError(error.InvalidSyntax, schema.resolveScalar(.json, "1e+", true, null));

    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.json, "null", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = false }, (try schema.resolveScalar(.json, "false", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 0 }, (try schema.resolveScalar(.json, "-0", true, null)).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 1 }, (try schema.resolveScalar(.json, "1.", true, null)).?);
}

test "schema: explicit standard tags resolve non-plain scalars" {
    try std.testing.expectEqual(schema.ResolvedScalar.null_value, (try schema.resolveScalar(.failsafe, "", false, "tag:yaml.org,2002:null")).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .bool_value = false }, (try schema.resolveScalar(.failsafe, "False", false, "tag:yaml.org,2002:bool")).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .int_value = 42 }, (try schema.resolveScalar(.failsafe, "+42", false, "tag:yaml.org,2002:int")).?);
    try std.testing.expectEqual(schema.ResolvedScalar{ .float_value = 42 }, (try schema.resolveScalar(.failsafe, "42", false, "tag:yaml.org,2002:float")).?);
}

test "schema: unknown explicit scalar tags remain unresolved" {
    try std.testing.expect((try schema.resolveScalar(.core, "value", true, "!local")) == null);
    try std.testing.expect((try schema.resolveScalar(.core, "value", false, "tag:example.com,2026:value")) == null);
}

test "schema: standard collection tags must match node kind" {
    try schema.validateStandardTagKind("tag:yaml.org,2002:seq", .sequence);
    try schema.validateStandardTagKind("tag:yaml.org,2002:map", .mapping);
    try schema.validateStandardTagKind("tag:yaml.org,2002:str", .scalar);

    try std.testing.expectError(error.InvalidSyntax, schema.validateStandardTagKind("tag:yaml.org,2002:seq", .scalar));
    try std.testing.expectError(error.InvalidSyntax, schema.validateStandardTagKind("tag:yaml.org,2002:map", .sequence));
}
