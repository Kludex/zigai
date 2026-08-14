//! Purpose: Select YAML 1.2.2 schemas and dispatch scalar resolution.
//! Owns: Schema selection, explicit scalar tag dispatch, and recommended-schema plain scalar resolution.
//! Does not own: Scalar spelling parsers, tag-kind validation, node construction, duplicate-key handling, or emission.
//! Depends on: schema/scalars.zig, schema/tag.zig.
//! Tested by: loader, conformance, and root API tests.

const std = @import("std");
const scalars = @import("scalars.zig");
const tag = @import("tag.zig");

/// YAML 1.2.2 recommended schemas for loader scalar resolution.
pub const Schema = enum {
    /// Resolve untagged scalars as strings while still building sequences and mappings.
    failsafe,
    /// Resolve YAML 1.2.2 JSON-schema nulls, booleans, integers, and floats.
    json,
    /// Resolve the YAML 1.2.2 core schema. This is the default.
    core,
};

pub const ResolvedScalar = scalars.ResolvedScalar;

pub const Error = error{InvalidSyntax};

pub const NodeKind = tag.NodeKind;

pub const validateStandardTagKind = tag.validateStandardTagKind;

/// Resolves a scalar according to its explicit tag or the selected schema.
///
/// `is_plain` controls implicit resolution. Non-plain scalars resolve only
/// when they carry an explicit standard scalar tag.
pub fn resolveScalar(
    selected_schema: Schema,
    value: []const u8,
    is_plain: bool,
    scalar_tag: ?[]const u8,
) Error!?ResolvedScalar {
    if (scalar_tag) |explicit_tag| {
        return resolveExplicitScalarTag(explicit_tag, value);
    }

    if (!is_plain) return null;
    return switch (selected_schema) {
        .failsafe => resolveFailsafePlainScalar(value),
        .json => resolveJsonPlainScalar(value),
        .core => resolveCorePlainScalar(value),
    };
}

/// Returns true when a plain scalar would become a non-string core value.
pub fn resolvesAsCorePlainScalar(value: []const u8) bool {
    return resolvesCorePlainScalar(value);
}

/// Returns true when the scalar resolves to a core-schema null.
pub fn isCoreNullScalar(value: []const u8, is_plain: bool, scalar_tag: ?[]const u8) bool {
    return isCoreNull(value, is_plain, scalar_tag);
}

fn resolveExplicitScalarTag(scalar_tag: []const u8, value: []const u8) Error!?ResolvedScalar {
    if (std.mem.eql(u8, scalar_tag, "tag:yaml.org,2002:null")) {
        if (!scalars.null_scalar.isCoreValue(value)) return error.InvalidSyntax;
        return .null_value;
    }
    if (std.mem.eql(u8, scalar_tag, "tag:yaml.org,2002:bool")) {
        return .{ .bool_value = scalars.bool_scalar.parseCore(value) orelse return error.InvalidSyntax };
    }
    if (std.mem.eql(u8, scalar_tag, "tag:yaml.org,2002:int")) {
        return .{ .int_value = scalars.int_scalar.parseCore(value) orelse return error.InvalidSyntax };
    }
    if (std.mem.eql(u8, scalar_tag, "tag:yaml.org,2002:float")) {
        return .{ .float_value = scalars.float_scalar.parseCore(value, .explicit) orelse return error.InvalidSyntax };
    }
    return null;
}

/// Failsafe leaves plain scalars unresolved so the loader constructs strings.
fn resolveFailsafePlainScalar(value: []const u8) ?ResolvedScalar {
    _ = value;
    return null;
}

/// Resolves a JSON-schema plain scalar.
///
/// JSON schema rejects unrecognized plain scalar spellings instead of silently
/// treating them as strings.
fn resolveJsonPlainScalar(value: []const u8) Error!?ResolvedScalar {
    return resolveKnownJsonPlainScalar(value) orelse error.InvalidSyntax;
}

fn resolveKnownJsonPlainScalar(value: []const u8) ?ResolvedScalar {
    if (std.mem.eql(u8, value, "null")) return .null_value;
    if (std.mem.eql(u8, value, "true")) return .{ .bool_value = true };
    if (std.mem.eql(u8, value, "false")) return .{ .bool_value = false };
    if (mayBeJsonNumber(value)) {
        if (hasJsonFloatMarker(value)) {
            if (scalars.float_scalar.parseJson(value)) |float_value| return .{ .float_value = float_value };
        } else if (scalars.int_scalar.parseJson(value)) |int_value| return .{ .int_value = int_value };
    }
    return null;
}

/// Resolves a core-schema plain scalar, returning null for strings.
fn resolveCorePlainScalar(value: []const u8) ?ResolvedScalar {
    if (scalars.null_scalar.isCoreValue(value)) return .null_value;
    if (scalars.bool_scalar.parseCore(value)) |bool_value| return .{ .bool_value = bool_value };
    if (mayBeCoreNumeric(value)) {
        if (hasCoreFloatMarker(value)) {
            if (scalars.float_scalar.parseCore(value, .implicit)) |float_value| return .{ .float_value = float_value };
        } else if (scalars.int_scalar.parseCore(value)) |int_value| return .{ .int_value = int_value };
    }
    return null;
}

/// Returns true when a plain scalar would become a non-string core value.
fn resolvesCorePlainScalar(value: []const u8) bool {
    if (scalars.null_scalar.isCoreValue(value)) return true;
    if (scalars.bool_scalar.parseCore(value) != null) return true;
    if (mayBeCoreNumeric(value)) {
        if (hasCoreFloatMarker(value)) {
            if (scalars.float_scalar.parseCore(value, .implicit) != null) return true;
        } else if (scalars.int_scalar.parseCore(value) != null) return true;
    }
    return false;
}

fn mayBeJsonNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    return value[0] == '-' or std.ascii.isDigit(value[0]);
}

fn mayBeCoreNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    return value[0] == '+' or value[0] == '-' or value[0] == '.' or std.ascii.isDigit(value[0]);
}

fn hasJsonFloatMarker(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, ".eE") != null;
}

fn hasCoreFloatMarker(value: []const u8) bool {
    const offset: usize = if (value.len > 0 and (value[0] == '+' or value[0] == '-')) 1 else 0;
    const unsigned = value[offset..];
    if (std.mem.startsWith(u8, unsigned, "0x") or std.mem.startsWith(u8, unsigned, "0o")) return false;
    return std.mem.indexOfAny(u8, unsigned, ".eE") != null;
}

/// Returns true when the scalar resolves to a core-schema null.
fn isCoreNull(value: []const u8, is_plain: bool, scalar_tag: ?[]const u8) bool {
    return scalars.null_scalar.isCoreScalar(value, is_plain, scalar_tag);
}

test resolveScalar {
    try std.testing.expectEqual(ResolvedScalar.null_value, (try resolveScalar(.core, "~", true, null)).?);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = true }, (try resolveScalar(.json, "true", true, null)).?);
    try std.testing.expect((try resolveScalar(.failsafe, "true", true, null)) == null);
    try std.testing.expect((try resolveScalar(.core, "true", false, null)) == null);
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.json, "True", true, null));
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.json, "plain string", true, null));
    try std.testing.expect((try resolveScalar(.json, "plain string", false, null)) == null);
    try std.testing.expect((try resolveScalar(.json, "plain string", true, "!")) == null);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = 42 }, (try resolveScalar(.failsafe, "42", false, "tag:yaml.org,2002:int")).?);
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.core, "not-null", true, "tag:yaml.org,2002:null"));
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.core, "not-int", true, "tag:yaml.org,2002:int"));
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.core, "0x1.0p0", true, "tag:yaml.org,2002:float"));
}

test "resolver: explicit standard tags bypass implicit schema and style" {
    try std.testing.expectEqual(ResolvedScalar.null_value, (try resolveScalar(.failsafe, "", false, "tag:yaml.org,2002:null")).?);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = false }, (try resolveScalar(.failsafe, "FALSE", false, "tag:yaml.org,2002:bool")).?);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = -42 }, (try resolveScalar(.json, "-0x2A", false, "tag:yaml.org,2002:int")).?);
    try std.testing.expectEqual(ResolvedScalar{ .float_value = 1000 }, (try resolveScalar(.json, "1e3", false, "tag:yaml.org,2002:float")).?);
}

test "resolver: implicit dispatch preserves strings outside selected schema" {
    try std.testing.expect((try resolveScalar(.core, "FALSE", false, null)) == null);
    try std.testing.expect((try resolveScalar(.core, "FALSE", true, "!")) == null);
    try std.testing.expect((try resolveScalar(.core, "FALSE", true, "!local")) == null);
    try std.testing.expect((try resolveScalar(.core, "plain", true, "tag:yaml.org,2002:str")) == null);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = false }, (try resolveScalar(.core, "FALSE", true, null)).?);
    try std.testing.expectError(error.InvalidSyntax, resolveScalar(.json, "FALSE", true, null));
}

test "resolver: core helper wrappers use core implicit semantics" {
    try std.testing.expect(resolvesAsCorePlainScalar("FALSE"));
    try std.testing.expect(resolvesAsCorePlainScalar("-0o7"));
    try std.testing.expect(!resolvesAsCorePlainScalar("false-like"));
    try std.testing.expect(isCoreNullScalar("~", true, null));
    try std.testing.expect(!isCoreNullScalar("~", false, null));
    try std.testing.expect(isCoreNullScalar("~", false, "tag:yaml.org,2002:null"));
}

test "resolver: numeric spelling guards classify impossible parser inputs" {
    try std.testing.expect(!mayBeJsonNumber("plain string"));
    try std.testing.expect(!mayBeJsonNumber("+1"));
    try std.testing.expect(mayBeJsonNumber("-1"));
    try std.testing.expect(mayBeJsonNumber("1.0"));

    try std.testing.expect(!mayBeCoreNumeric("plain string"));
    try std.testing.expect(!mayBeCoreNumeric("falsehood"));
    try std.testing.expect(mayBeCoreNumeric("+0x2A"));
    try std.testing.expect(mayBeCoreNumeric(".Inf"));
}

test "failsafe schema" {
    try std.testing.expect(resolveFailsafePlainScalar("null") == null);
    try std.testing.expect(resolveFailsafePlainScalar("true") == null);
    try std.testing.expect(resolveFailsafePlainScalar("42") == null);
}

test "JSON schema" {
    try std.testing.expectEqual(ResolvedScalar.null_value, (try resolveJsonPlainScalar("null")).?);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = true }, (try resolveJsonPlainScalar("true")).?);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = false }, (try resolveJsonPlainScalar("false")).?);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = 0 }, (try resolveJsonPlainScalar("0")).?);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = 0 }, (try resolveJsonPlainScalar("-0")).?);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = -12 }, (try resolveJsonPlainScalar("-12")).?);
    try std.testing.expectEqual(ResolvedScalar{ .float_value = 1.5 }, (try resolveJsonPlainScalar("1.5")).?);
    try std.testing.expectEqual(ResolvedScalar{ .float_value = 0 }, (try resolveJsonPlainScalar("0e0")).?);
    try std.testing.expectEqual(ResolvedScalar{ .float_value = 0 }, (try resolveJsonPlainScalar("-0.0")).?);
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("Null"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("NULL"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("True"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("FALSE"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("truth"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("falsehood"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("00"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("-01"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("+0"));
    try std.testing.expectError(error.InvalidSyntax, resolveJsonPlainScalar("0x0"));
}

test "core schema" {
    try std.testing.expectEqual(ResolvedScalar.null_value, resolveCorePlainScalar("~").?);
    try std.testing.expectEqual(ResolvedScalar{ .bool_value = false }, resolveCorePlainScalar("FALSE").?);
    try std.testing.expectEqual(ResolvedScalar{ .int_value = 63 }, resolveCorePlainScalar("0o77").?);
    try std.testing.expectEqual(ResolvedScalar{ .float_value = 1000 }, resolveCorePlainScalar("1e3").?);
    try std.testing.expect(resolveCorePlainScalar("plain string") == null);
}

test "core schema: helper predicates match scalar resolution" {
    const non_strings = [_][]const u8{ "", "~", "TRUE", "-0x2A", ".inf" };
    for (non_strings) |value| try std.testing.expect(resolvesCorePlainScalar(value));

    const strings = [_][]const u8{ "nulls", "yes", "0x", "+.nanx" };
    for (strings) |value| try std.testing.expect(!resolvesCorePlainScalar(value));

    try std.testing.expect(isCoreNull("", true, null));
    try std.testing.expect(!isCoreNull("", false, null));
    try std.testing.expect(isCoreNull("", false, "tag:yaml.org,2002:null"));
    try std.testing.expect(!isCoreNull("", false, "tag:yaml.org,2002:str"));
}

test {
    std.testing.refAllDecls(@This());
}
