//! Local JSON and JSON Schema validation for structured model output.

const std = @import("std");
const model_types = @import("model.zig");
const json_limits = @import("json.zig");

pub const Error = error{
    /// Structured model output is not one valid JSON value.
    InvalidJsonOutput,
    /// The configured output schema is not valid JSON Schema input.
    InvalidJsonSchema,
    /// Valid JSON output does not satisfy the configured schema.
    OutputSchemaValidationFailed,
    /// The schema uses valid JSON Schema vocabulary outside ZigAI's documented subset.
    UnsupportedJsonSchema,
};

/// The supported vocabulary follows the validation semantics of JSON Schema
/// Draft 2020-12. Unsupported keywords are rejected rather than ignored.
pub const supported_dialect = "https://json-schema.org/draft/2020-12/schema";

pub fn validate(allocator: std.mem.Allocator, output_format: model_types.OutputFormat, output: []const u8) !void {
    switch (output_format) {
        .text => return,
        .json_object => {
            const parsed_output = try json_limits.parse(
                std.json.Value,
                allocator,
                output,
                json_limits.defaults.tool_payload,
                .{},
                Error.InvalidJsonOutput,
            );
            defer parsed_output.deinit();
            if (parsed_output.value != .object) return Error.OutputSchemaValidationFailed;
        },
        .json_schema => |format| {
            const parsed_output = try json_limits.parse(
                std.json.Value,
                allocator,
                output,
                json_limits.defaults.tool_payload,
                .{},
                Error.InvalidJsonOutput,
            );
            defer parsed_output.deinit();
            const parsed_schema = try json_limits.parse(
                std.json.Value,
                allocator,
                format.schema,
                json_limits.defaults.schema,
                .{},
                Error.InvalidJsonSchema,
            );
            defer parsed_schema.deinit();
            try validateSchemaValue(parsed_schema.value);
            if (!matches(.{ .root = parsed_schema.value }, parsed_schema.value, parsed_output.value)) {
                return Error.OutputSchemaValidationFailed;
            }
        },
    }
}

/// Validates one bounded schema without validating an output value.
pub fn validateSchema(allocator: std.mem.Allocator, schema: []const u8) !void {
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        schema,
        json_limits.defaults.schema,
        .{},
        Error.InvalidJsonSchema,
    );
    defer parsed.deinit();
    try validateSchemaValue(parsed.value);
}

fn validateSchemaValue(schema: std.json.Value) Error!void {
    try validateSchemaNode(schema, schema);
}

fn validateSchemaNode(root: std.json.Value, schema: std.json.Value) Error!void {
    const object = switch (schema) {
        .bool => return,
        .object => |item| item,
        else => return Error.InvalidJsonSchema,
    };

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, name, "$schema")) {
            const dialect = stringValue(value) orelse return Error.InvalidJsonSchema;
            if (!std.mem.eql(u8, dialect, supported_dialect) and
                !std.mem.eql(u8, dialect, supported_dialect ++ "#")) return Error.UnsupportedJsonSchema;
        } else if (std.mem.eql(u8, name, "$id") or
            std.mem.eql(u8, name, "$anchor") or
            std.mem.eql(u8, name, "$comment") or
            std.mem.eql(u8, name, "title") or
            std.mem.eql(u8, name, "description") or
            std.mem.eql(u8, name, "format"))
        {
            _ = stringValue(value) orelse return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "default")) {
            // An annotation may contain any JSON value.
        } else if (std.mem.eql(u8, name, "examples")) {
            if (value != .array) return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "readOnly") or
            std.mem.eql(u8, name, "writeOnly") or
            std.mem.eql(u8, name, "deprecated"))
        {
            if (value != .bool) return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "$defs")) {
            const definitions = objectValue(value) orelse return Error.InvalidJsonSchema;
            var definitions_iterator = definitions.iterator();
            while (definitions_iterator.next()) |definition| {
                try validateSchemaNode(root, definition.value_ptr.*);
            }
        } else if (std.mem.eql(u8, name, "$ref")) {
            const reference = stringValue(value) orelse return Error.InvalidJsonSchema;
            if (!isSupportedReference(reference)) return Error.UnsupportedJsonSchema;
            _ = resolveReference(root, reference) orelse return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "type")) {
            try validateTypeKeyword(value);
        } else if (std.mem.eql(u8, name, "enum")) {
            const allowed = arrayValue(value) orelse return Error.InvalidJsonSchema;
            if (allowed.items.len == 0) return Error.InvalidJsonSchema;
            for (allowed.items, 0..) |item, index| {
                for (allowed.items[index + 1 ..]) |other| {
                    if (equal(item, other)) return Error.InvalidJsonSchema;
                }
            }
        } else if (std.mem.eql(u8, name, "const")) {
            // A constant may contain any JSON value.
        } else if (std.mem.eql(u8, name, "allOf") or
            std.mem.eql(u8, name, "anyOf") or
            std.mem.eql(u8, name, "oneOf") or
            std.mem.eql(u8, name, "prefixItems"))
        {
            const schemas = arrayValue(value) orelse return Error.InvalidJsonSchema;
            if (schemas.items.len == 0) return Error.InvalidJsonSchema;
            for (schemas.items) |child| try validateSchemaNode(root, child);
        } else if (std.mem.eql(u8, name, "not") or
            std.mem.eql(u8, name, "if") or
            std.mem.eql(u8, name, "then") or
            std.mem.eql(u8, name, "else") or
            std.mem.eql(u8, name, "items") or
            std.mem.eql(u8, name, "contains") or
            std.mem.eql(u8, name, "propertyNames") or
            std.mem.eql(u8, name, "additionalProperties"))
        {
            try validateSchemaNode(root, value);
        } else if (std.mem.eql(u8, name, "properties")) {
            const properties = objectValue(value) orelse return Error.InvalidJsonSchema;
            var properties_iterator = properties.iterator();
            while (properties_iterator.next()) |property| {
                try validateSchemaNode(root, property.value_ptr.*);
            }
        } else if (std.mem.eql(u8, name, "required")) {
            try validateUniqueStringArray(value);
        } else if (std.mem.eql(u8, name, "dependentRequired")) {
            const dependencies = objectValue(value) orelse return Error.InvalidJsonSchema;
            var dependencies_iterator = dependencies.iterator();
            while (dependencies_iterator.next()) |dependency| {
                try validateUniqueStringArray(dependency.value_ptr.*);
            }
        } else if (std.mem.eql(u8, name, "minLength") or
            std.mem.eql(u8, name, "maxLength") or
            std.mem.eql(u8, name, "minItems") or
            std.mem.eql(u8, name, "maxItems") or
            std.mem.eql(u8, name, "minContains") or
            std.mem.eql(u8, name, "maxContains") or
            std.mem.eql(u8, name, "minProperties") or
            std.mem.eql(u8, name, "maxProperties"))
        {
            _ = nonnegativeInteger(value) orelse return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "minimum") or
            std.mem.eql(u8, name, "maximum") or
            std.mem.eql(u8, name, "exclusiveMinimum") or
            std.mem.eql(u8, name, "exclusiveMaximum"))
        {
            _ = numericValue(value) orelse return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "multipleOf")) {
            const divisor = numericValue(value) orelse return Error.InvalidJsonSchema;
            if (divisor <= 0) return Error.InvalidJsonSchema;
        } else if (std.mem.eql(u8, name, "uniqueItems")) {
            if (value != .bool) return Error.InvalidJsonSchema;
        } else {
            return Error.UnsupportedJsonSchema;
        }
    }
}

fn validateTypeKeyword(value: std.json.Value) Error!void {
    switch (value) {
        .string => |name| if (!isKnownType(name)) return Error.InvalidJsonSchema,
        .array => |names| {
            if (names.items.len == 0) return Error.InvalidJsonSchema;
            for (names.items, 0..) |name, index| {
                const type_name = stringValue(name) orelse return Error.InvalidJsonSchema;
                if (!isKnownType(type_name)) return Error.InvalidJsonSchema;
                for (names.items[index + 1 ..]) |other| {
                    const other_name = stringValue(other) orelse return Error.InvalidJsonSchema;
                    if (std.mem.eql(u8, type_name, other_name)) return Error.InvalidJsonSchema;
                }
            }
        },
        else => return Error.InvalidJsonSchema,
    }
}

fn validateUniqueStringArray(value: std.json.Value) Error!void {
    const strings = arrayValue(value) orelse return Error.InvalidJsonSchema;
    for (strings.items, 0..) |item, index| {
        const name = stringValue(item) orelse return Error.InvalidJsonSchema;
        for (strings.items[index + 1 ..]) |other| {
            const other_name = stringValue(other) orelse return Error.InvalidJsonSchema;
            if (std.mem.eql(u8, name, other_name)) return Error.InvalidJsonSchema;
        }
    }
}

fn isKnownType(name: []const u8) bool {
    return std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "boolean") or
        std.mem.eql(u8, name, "object") or
        std.mem.eql(u8, name, "array") or
        std.mem.eql(u8, name, "number") or
        std.mem.eql(u8, name, "integer") or
        std.mem.eql(u8, name, "string");
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |item| item,
        else => null,
    };
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |item| item,
        else => null,
    };
}

fn arrayValue(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |item| item,
        else => null,
    };
}

fn nonnegativeInteger(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |item| if (item >= 0) @intCast(item) else null,
        else => null,
    };
}

fn isSupportedReference(reference: []const u8) bool {
    if (std.mem.eql(u8, reference, "#")) return true;
    const prefix = "#/$defs/";
    if (!std.mem.startsWith(u8, reference, prefix) or reference.len == prefix.len) return false;
    const segment = reference[prefix.len..];
    return std.mem.indexOfScalar(u8, segment, '/') == null and validPointerSegment(segment);
}

fn resolveReference(root: std.json.Value, reference: []const u8) ?std.json.Value {
    if (std.mem.eql(u8, reference, "#")) return root;
    if (!isSupportedReference(reference)) return null;
    const root_object = objectValue(root) orelse return null;
    const definitions = objectValue(root_object.get("$defs") orelse return null) orelse return null;
    const segment = reference["#/$defs/".len..];
    var iterator = definitions.iterator();
    while (iterator.next()) |entry| {
        if (pointerSegmentEql(segment, entry.key_ptr.*)) return entry.value_ptr.*;
    }
    return null;
}

fn validPointerSegment(segment: []const u8) bool {
    var index: usize = 0;
    while (index < segment.len) : (index += 1) {
        if (segment[index] != '~') continue;
        index += 1;
        if (index >= segment.len or (segment[index] != '0' and segment[index] != '1')) return false;
    }
    return true;
}

fn pointerSegmentEql(encoded: []const u8, decoded: []const u8) bool {
    var encoded_index: usize = 0;
    var decoded_index: usize = 0;
    while (encoded_index < encoded.len and decoded_index < decoded.len) {
        const byte: u8 = if (encoded[encoded_index] == '~') blk: {
            if (encoded_index + 1 >= encoded.len) return false;
            encoded_index += 1;
            break :blk switch (encoded[encoded_index]) {
                '0' => '~',
                '1' => '/',
                else => return false,
            };
        } else encoded[encoded_index];
        if (byte != decoded[decoded_index]) return false;
        encoded_index += 1;
        decoded_index += 1;
    }
    return encoded_index == encoded.len and decoded_index == decoded.len;
}

const MatchContext = struct {
    root: std.json.Value,
    depth: usize = 0,

    fn nested(self: MatchContext) ?MatchContext {
        if (self.depth >= json_limits.defaults.schema.max_depth) return null;
        return .{ .root = self.root, .depth = self.depth + 1 };
    }
};

fn matches(context: MatchContext, schema: std.json.Value, value: std.json.Value) bool {
    const object = switch (schema) {
        .bool => |allowed| return allowed,
        .object => |item| item,
        else => return false,
    };
    const nested = context.nested() orelse return false;
    if (object.get("$ref")) |reference| {
        const target = resolveReference(context.root, reference.string) orelse return false;
        if (!matches(nested, target, value)) return false;
    }
    if (object.get("allOf")) |choices| for (choices.array.items) |choice| {
        if (!matches(nested, choice, value)) return false;
    };
    if (object.get("anyOf")) |choices| if (!matchesAny(nested, choices, value, false)) return false;
    if (object.get("oneOf")) |choices| if (!matchesAny(nested, choices, value, true)) return false;
    if (object.get("not")) |denied| if (matches(nested, denied, value)) return false;
    if (object.get("if")) |condition| {
        if (matches(nested, condition, value)) {
            if (object.get("then")) |consequence| if (!matches(nested, consequence, value)) return false;
        } else if (object.get("else")) |alternative| if (!matches(nested, alternative, value)) return false;
    }
    if (object.get("type")) |expected| if (!matchesType(expected, value)) return false;
    if (object.get("const")) |expected| if (!equal(expected, value)) return false;
    if (object.get("enum")) |allowed| if (!matchesEnum(allowed, value)) return false;
    switch (value) {
        .object => |actual| if (!matchesObject(nested, object, actual)) return false,
        .array => |actual| if (!matchesArray(nested, object, actual)) return false,
        .string => |actual| if (!matchesString(object, actual)) return false,
        .integer, .float, .number_string => if (!matchesNumber(object, value)) return false,
        else => {},
    }
    return true;
}

fn matchesAny(context: MatchContext, choices: std.json.Value, value: std.json.Value, exactly_one: bool) bool {
    const array = choices.array;
    var count: usize = 0;
    for (array.items) |choice| if (matches(context, choice, value)) {
        count += 1;
        if (!exactly_one) return true;
    };
    return count == 1;
}

fn matchesType(expected: std.json.Value, value: std.json.Value) bool {
    return switch (expected) {
        .string => |name| isType(name, value),
        .array => |names| for (names.items) |name| {
            if (name == .string and isType(name.string, value)) break true;
        } else false,
        else => false,
    };
}

fn isType(name: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float or value == .number_string;
    if (std.mem.eql(u8, name, "integer")) return value == .integer;
    if (std.mem.eql(u8, name, "object")) return value == .object;
    if (std.mem.eql(u8, name, "array")) return value == .array;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, name, "null")) return value == .null;
    return false;
}

fn matchesEnum(allowed: std.json.Value, value: std.json.Value) bool {
    const array = switch (allowed) {
        .array => |item| item,
        else => return false,
    };
    for (array.items) |item| if (equal(item, value)) return true;
    return false;
}

fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) == std.meta.activeTag(b)) return switch (a) {
        .null => true,
        .bool => |item| item == b.bool,
        .integer => |item| item == b.integer,
        .float => |item| item == b.float,
        .number_string => |item| if (numericValue(a)) |left|
            left == numericValue(b).?
        else
            std.mem.eql(u8, item, b.number_string),
        .string => |item| std.mem.eql(u8, item, b.string),
        .array => |items| blk: {
            if (items.items.len != b.array.items.len) break :blk false;
            for (items.items, b.array.items) |left, right| if (!equal(left, right)) break :blk false;
            break :blk true;
        },
        .object => |items| blk: {
            if (items.count() != b.object.count()) break :blk false;
            var iterator = items.iterator();
            while (iterator.next()) |entry| if (!equal(entry.value_ptr.*, b.object.get(entry.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
    if (numericValue(a)) |left| if (numericValue(b)) |right| return left == right;
    return false;
}

fn matchesObject(context: MatchContext, schema: std.json.ObjectMap, actual: std.json.ObjectMap) bool {
    if (!matchesSize(schema, actual.count(), "minProperties", "maxProperties")) return false;
    if (schema.get("required")) |required| {
        const names = required.array;
        for (names.items) |name| if (name != .string or actual.get(name.string) == null) return false;
    }
    if (schema.get("dependentRequired")) |dependencies| {
        var dependency_iterator = dependencies.object.iterator();
        while (dependency_iterator.next()) |entry| {
            if (actual.get(entry.key_ptr.*) == null) continue;
            for (entry.value_ptr.array.items) |required| {
                if (actual.get(required.string) == null) return false;
            }
        }
    }
    const properties = if (schema.get("properties")) |item| item.object else null;
    const property_names = schema.get("propertyNames");
    var iterator = actual.iterator();
    while (iterator.next()) |entry| {
        if (property_names) |name_schema| {
            if (!matches(context, name_schema, .{ .string = entry.key_ptr.* })) return false;
        }
        if (properties) |known| {
            if (known.get(entry.key_ptr.*)) |property_schema| {
                if (!matches(context, property_schema, entry.value_ptr.*)) return false;
                continue;
            }
        }
        if (schema.get("additionalProperties")) |additional| switch (additional) {
            .bool => |allowed| if (!allowed) return false,
            .object => if (!matches(context, additional, entry.value_ptr.*)) return false,
            else => return false,
        };
    }
    return true;
}

fn matchesArray(context: MatchContext, schema: std.json.ObjectMap, actual: std.json.Array) bool {
    if (!matchesSize(schema, actual.items.len, "minItems", "maxItems")) return false;
    if (schema.get("uniqueItems")) |unique| if (unique.bool) {
        for (actual.items, 0..) |item, index| for (actual.items[index + 1 ..]) |other| {
            if (equal(item, other)) return false;
        };
    };
    var prefix_length: usize = 0;
    if (schema.get("prefixItems")) |prefix| {
        prefix_length = @min(prefix.array.items.len, actual.items.len);
        for (prefix.array.items[0..prefix_length], actual.items[0..prefix_length]) |item_schema, item| {
            if (!matches(context, item_schema, item)) return false;
        }
    }
    if (schema.get("items")) |item_schema| for (actual.items[prefix_length..]) |item| {
        if (!matches(context, item_schema, item)) return false;
    };
    if (schema.get("contains")) |contained_schema| {
        var count: usize = 0;
        for (actual.items) |item| if (matches(context, contained_schema, item)) {
            count += 1;
        };
        const minimum = integerKeyword(schema, "minContains") orelse 1;
        if (count < minimum) return false;
        if (integerKeyword(schema, "maxContains")) |maximum| if (count > maximum) return false;
    }
    return true;
}

fn matchesString(schema: std.json.ObjectMap, actual: []const u8) bool {
    const length = std.unicode.utf8CountCodepoints(actual) catch return false;
    return matchesSize(schema, length, "minLength", "maxLength");
}

fn matchesSize(schema: std.json.ObjectMap, length: usize, minimum_name: []const u8, maximum_name: []const u8) bool {
    if (integerKeyword(schema, minimum_name)) |minimum| if (length < minimum) return false;
    if (integerKeyword(schema, maximum_name)) |maximum| if (length > maximum) return false;
    return true;
}

fn integerKeyword(schema: std.json.ObjectMap, name: []const u8) ?usize {
    const value = schema.get(name) orelse return null;
    return switch (value) {
        .integer => |item| if (item >= 0) @intCast(item) else null,
        else => null,
    };
}

fn matchesNumber(schema: std.json.ObjectMap, value: std.json.Value) bool {
    const actual = numericValue(value) orelse return false;
    if (numberKeyword(schema, "minimum")) |minimum| if (actual < minimum) return false;
    if (numberKeyword(schema, "maximum")) |maximum| if (actual > maximum) return false;
    if (numberKeyword(schema, "exclusiveMinimum")) |minimum| if (actual <= minimum) return false;
    if (numberKeyword(schema, "exclusiveMaximum")) |maximum| if (actual >= maximum) return false;
    if (numberKeyword(schema, "multipleOf")) |divisor| {
        const quotient = actual / divisor;
        const nearest = @round(quotient);
        const tolerance = 1e-15 * @max(@abs(quotient), 1);
        if (@abs(quotient - nearest) > tolerance) return false;
    }
    return true;
}

fn numberKeyword(schema: std.json.ObjectMap, name: []const u8) ?f128 {
    const value = schema.get(name) orelse return null;
    return numericValue(value);
}

fn numericValue(value: std.json.Value) ?f128 {
    return switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| @floatCast(item),
        .number_string => |item| std.fmt.parseFloat(f128, item) catch null,
        else => null,
    };
}

fn matchesRoot(schema: std.json.Value, value: std.json.Value) bool {
    return matches(.{ .root = schema }, schema, value);
}

test "validates objects, arrays, unions, enums, and bounds" {
    const schema =
        \\{"type":"object","properties":{"name":{"type":"string","minLength":2},"score":{"type":"number","minimum":0,"maximum":10},"tags":{"type":"array","minItems":1,"maxItems":2,"items":{"enum":["a","b"]}},"choice":{"oneOf":[{"type":"integer"},{"type":"null"}]}},"required":["name","score","tags"],"additionalProperties":false}
    ;
    const format: model_types.OutputFormat = .{ .json_schema = .{ .name = "test", .schema = schema } };
    try validate(std.testing.allocator, format, "{\"name\":\"ok\",\"score\":4.5,\"tags\":[\"a\"],\"choice\":null}");
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "{\"name\":\"x\",\"score\":11,\"tags\":[\"c\"],\"extra\":true}"));
    try validate(std.testing.allocator, .{ .json_schema = .{ .name = "union", .schema = "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"boolean\"}]}" } }, "true");
}

test "reports invalid JSON, schemas, and object mode" {
    try validate(std.testing.allocator, .text, "anything");
    try std.testing.expectError(Error.InvalidJsonOutput, validate(std.testing.allocator, .json_object, "no"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, .json_object, "[]"));
    try std.testing.expectError(Error.InvalidJsonSchema, validate(std.testing.allocator, .{ .json_schema = .{ .name = "bad", .schema = "no" } }, "{}"));
    try std.testing.expectError(Error.InvalidJsonSchema, validate(std.testing.allocator, .{ .json_schema = .{ .name = "bad", .schema = "[]" } }, "{}"));
}

test "structured output rejects JSON beyond its nesting limit" {
    const source = "[" ** 65 ++ "0" ++ "]" ** 65;
    try std.testing.expectError(Error.InvalidJsonOutput, validate(std.testing.allocator, .json_object, source));
}

test "schema matcher covers boolean schemas, type arrays, and enum equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(matchesRoot(.{ .bool = true }, .null));
    try std.testing.expect(!matchesRoot(.{ .bool = false }, .null));
    const union_schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"type\":[\"string\",\"null\"]}", .{});
    try std.testing.expect(matchesRoot(union_schema, .{ .string = "ok" }));
    try std.testing.expect(matchesRoot(union_schema, .null));
    try std.testing.expect(!matchesRoot(union_schema, .{ .bool = true }));
    try std.testing.expect(!isType("unknown", .null));

    const allowed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[true,1,1.5,[1],{\"a\":1}]", .{});
    try std.testing.expect(matchesEnum(allowed, .{ .bool = true }));
    try std.testing.expect(matchesEnum(allowed, .{ .integer = 1 }));
    try std.testing.expect(matchesEnum(allowed, .{ .float = 1.5 }));
    try std.testing.expect(!matchesEnum(allowed, .{ .string = "missing" }));
    try std.testing.expect(equal(.{ .number_string = "1e2" }, .{ .number_string = "1e2" }));
}

test "recursive equality covers arrays and objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const array = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[1,2]", .{});
    const same_array = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[1,2]", .{});
    const short_array = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[1]", .{});
    const different_array = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[1,3]", .{});
    try std.testing.expect(equal(array, same_array));
    try std.testing.expect(!equal(array, short_array));
    try std.testing.expect(!equal(array, different_array));

    const object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"a\":1,\"b\":true}", .{});
    const same_object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"a\":1,\"b\":true}", .{});
    const short_object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"a\":1}", .{});
    const renamed_object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"a\":1,\"c\":true}", .{});
    const changed_object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"a\":2,\"b\":true}", .{});
    try std.testing.expect(equal(object, same_object));
    try std.testing.expect(!equal(object, short_object));
    try std.testing.expect(!equal(object, renamed_object));
    try std.testing.expect(!equal(object, changed_object));
}

test "object matching validates required and additional property forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const actual = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"known\":\"ok\",\"extra\":\"yes\"}", .{});
    const denied = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"properties\":{\"known\":{\"type\":\"string\"}},\"additionalProperties\":false}", .{});
    try std.testing.expect(!matchesRoot(denied, actual));
    const typed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"properties\":{\"known\":{\"type\":\"string\"}},\"additionalProperties\":{\"type\":\"string\"}}", .{});
    try std.testing.expect(matchesRoot(typed, actual));
    const bad_actual = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"extra\":1}", .{});
    try std.testing.expect(!matchesRoot(typed, bad_actual));
    try std.testing.expectError(Error.InvalidJsonSchema, validateSchema(std.testing.allocator, "{\"required\":true}"));
    try std.testing.expectError(Error.InvalidJsonSchema, validateSchema(std.testing.allocator, "{\"additionalProperties\":1}"));
}

test "validates the documented Draft 2020-12 composition subset" {
    const schema =
        \\{
        \\  "$schema":"https://json-schema.org/draft/2020-12/schema",
        \\  "$id":"https://example.test/result",
        \\  "$anchor":"result",
        \\  "$comment":"annotations are accepted",
        \\  "title":"Result",
        \\  "description":"A bounded result",
        \\  "format":"application-defined",
        \\  "default":null,
        \\  "examples":[{"kind":"ready","name":"ok"}],
        \\  "readOnly":false,
        \\  "writeOnly":false,
        \\  "deprecated":false,
        \\  "$defs":{
        \\    "a/b~c":{
        \\      "type":"object",
        \\      "properties":{
        \\        "kind":{"const":"ready"},
        \\        "name":{"type":"string","minLength":1,"maxLength":2}
        \\      },
        \\      "required":["kind","name"]
        \\    }
        \\  },
        \\  "$ref":"#/$defs/a~1b~0c",
        \\  "allOf":[{"not":{"required":["blocked"]}}],
        \\  "if":{"properties":{"kind":{"const":"ready"}},"required":["kind"]},
        \\  "then":{"required":["name"]},
        \\  "else":{"required":["reason"]}
        \\}
    ;
    const format: model_types.OutputFormat = .{ .json_schema = .{ .name = "composition", .schema = schema } };
    try validateSchema(std.testing.allocator, schema);
    try validate(std.testing.allocator, format, "{\"kind\":\"ready\",\"name\":\"é\"}");
    try std.testing.expectError(
        Error.OutputSchemaValidationFailed,
        validate(std.testing.allocator, format, "{\"kind\":\"ready\",\"name\":\"long\"}"),
    );
    try std.testing.expectError(
        Error.OutputSchemaValidationFailed,
        validate(std.testing.allocator, format, "{\"kind\":\"ready\",\"name\":\"ok\",\"blocked\":true}"),
    );
}

test "validates object dependencies, property names, and property counts" {
    const schema =
        \\{"type":"object","minProperties":2,"maxProperties":3,"propertyNames":{"type":"string","minLength":2},"dependentRequired":{"cc":["billing"]},"additionalProperties":{"type":"string"}}
    ;
    const format: model_types.OutputFormat = .{ .json_schema = .{ .name = "object", .schema = schema } };
    try validate(std.testing.allocator, format, "{\"cc\":\"1\",\"billing\":\"home\"}");
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "{\"cc\":\"1\",\"other\":\"x\"}"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "{\"x\":\"1\",\"ok\":\"2\"}"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "{\"aa\":\"1\",\"bb\":\"2\",\"cc\":\"3\",\"dd\":\"4\"}"));
}

test "validates tuple tails, contains counts, uniqueness, and numeric bounds" {
    const schema =
        \\{"type":"array","minItems":3,"maxItems":5,"prefixItems":[{"const":"scores"}],"items":{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":10,"multipleOf":0.5},"contains":{"type":"number","minimum":5},"minContains":1,"maxContains":2,"uniqueItems":true}
    ;
    const format: model_types.OutputFormat = .{ .json_schema = .{ .name = "array", .schema = schema } };
    try validate(std.testing.allocator, format, "[\"scores\",1.5,5,9.5]");
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "[\"scores\",1,1.0]"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "[\"scores\",1,2]"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "[\"scores\",5,6,7]"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "[\"scores\",0,5]"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "[\"scores\",1.25,5]"));
}

test "composition enforces anyOf and exactly one oneOf branch" {
    const schema =
        \\{"anyOf":[{"type":"number"},{"type":"string"}],"oneOf":[{"type":"integer"},{"minimum":0}]}
    ;
    const format: model_types.OutputFormat = .{ .json_schema = .{ .name = "branches", .schema = schema } };
    try validate(std.testing.allocator, format, "-1");
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "1"));
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, format, "true"));
}

test "schema preflight distinguishes malformed and unsupported vocabulary" {
    const malformed = [_][]const u8{
        "null",
        "{\"$schema\":false}",
        "{\"$defs\":[]}",
        "{\"$ref\":false}",
        "{\"$ref\":\"#/$defs/missing\"}",
        "{\"$defs\":{\"present\":{}},\"$ref\":\"#/$defs/missing\"}",
        "{\"type\":\"unknown\"}",
        "{\"type\":[]}",
        "{\"type\":[\"string\",\"string\"]}",
        "{\"enum\":[]}",
        "{\"enum\":[1,1.0]}",
        "{\"allOf\":[]}",
        "{\"not\":0}",
        "{\"properties\":[]}",
        "{\"required\":[\"a\",\"a\"]}",
        "{\"dependentRequired\":{\"a\":[1]}}",
        "{\"minLength\":-1}",
        "{\"minimum\":false}",
        "{\"multipleOf\":0}",
        "{\"uniqueItems\":1}",
        "{\"examples\":false}",
        "{\"readOnly\":\"yes\"}",
    };
    for (malformed) |schema| {
        try std.testing.expectError(Error.InvalidJsonSchema, validateSchema(std.testing.allocator, schema));
    }

    const unsupported = [_][]const u8{
        "{\"pattern\":\"^[a-z]+$\"}",
        "{\"unevaluatedProperties\":false}",
        "{\"$schema\":\"https://json-schema.org/draft/2019-09/schema\"}",
        "{\"$ref\":\"https://example.test/schema\"}",
        "{\"$ref\":\"#/$defs/a/b\",\"$defs\":{\"a\":{}}}",
        "{\"$ref\":\"#/$defs/a~2b\",\"$defs\":{\"a~2b\":{}}}",
    };
    for (unsupported) |schema| {
        try std.testing.expectError(Error.UnsupportedJsonSchema, validateSchema(std.testing.allocator, schema));
    }

    try std.testing.expect(equal(.{ .number_string = "not-a-number" }, .{ .number_string = "not-a-number" }));
}
