//! Local JSON and JSON Schema validation for structured model output.

const std = @import("std");
const model_types = @import("model.zig");

pub const Error = error{
    InvalidJsonOutput,
    InvalidJsonSchema,
    OutputSchemaValidationFailed,
};

pub fn validate(allocator: std.mem.Allocator, output_format: model_types.OutputFormat, output: []const u8) !void {
    switch (output_format) {
        .text => return,
        .json_object => {
            const parsed_output = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch return Error.InvalidJsonOutput;
            defer parsed_output.deinit();
            if (parsed_output.value != .object) return Error.OutputSchemaValidationFailed;
        },
        .json_schema => |format| {
            const parsed_output = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch return Error.InvalidJsonOutput;
            defer parsed_output.deinit();
            const parsed_schema = std.json.parseFromSlice(std.json.Value, allocator, format.schema, .{}) catch return Error.InvalidJsonSchema;
            defer parsed_schema.deinit();
            if (!matches(parsed_schema.value, parsed_output.value)) return Error.OutputSchemaValidationFailed;
        },
    }
}

fn matches(schema: std.json.Value, value: std.json.Value) bool {
    const object = switch (schema) {
        .bool => |allowed| return allowed,
        .object => |item| item,
        else => return false,
    };
    if (object.get("anyOf")) |choices| if (!matchesAny(choices, value, false)) return false;
    if (object.get("oneOf")) |choices| if (!matchesAny(choices, value, true)) return false;
    if (object.get("type")) |expected| if (!matchesType(expected, value)) return false;
    if (object.get("enum")) |allowed| if (!matchesEnum(allowed, value)) return false;
    switch (value) {
        .object => |actual| if (!matchesObject(object, actual)) return false,
        .array => |actual| if (!matchesArray(object, actual)) return false,
        .string => |actual| if (!matchesLength(object, actual.len)) return false,
        .integer => |actual| if (!matchesNumber(object, @floatFromInt(actual))) return false,
        .float => |actual| if (!matchesNumber(object, actual)) return false,
        else => {},
    }
    return true;
}

fn matchesAny(choices: std.json.Value, value: std.json.Value, exactly_one: bool) bool {
    const array = switch (choices) {
        .array => |item| item,
        else => return false,
    };
    var count: usize = 0;
    for (array.items) |choice| if (matches(choice, value)) {
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
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |item| item == b.bool,
        .integer => |item| item == b.integer,
        .float => |item| item == b.float,
        .number_string => |item| std.mem.eql(u8, item, b.number_string),
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
}

fn matchesObject(schema: std.json.ObjectMap, actual: std.json.ObjectMap) bool {
    if (schema.get("required")) |required| {
        const names = switch (required) {
            .array => |item| item,
            else => return false,
        };
        for (names.items) |name| if (name != .string or actual.get(name.string) == null) return false;
    }
    const properties = if (schema.get("properties")) |value| switch (value) {
        .object => |item| item,
        else => return false,
    } else null;
    var iterator = actual.iterator();
    while (iterator.next()) |entry| {
        if (properties) |known| {
            if (known.get(entry.key_ptr.*)) |property_schema| {
                if (!matches(property_schema, entry.value_ptr.*)) return false;
                continue;
            }
        }
        if (schema.get("additionalProperties")) |additional| switch (additional) {
            .bool => |allowed| if (!allowed) return false,
            .object => if (!matches(additional, entry.value_ptr.*)) return false,
            else => return false,
        };
    }
    return true;
}

fn matchesArray(schema: std.json.ObjectMap, actual: std.json.Array) bool {
    if (!matchesLength(schema, actual.items.len)) return false;
    if (schema.get("items")) |item_schema| for (actual.items) |item| if (!matches(item_schema, item)) return false;
    return true;
}

fn matchesLength(schema: std.json.ObjectMap, length: usize) bool {
    if (integerKeyword(schema, "minLength") orelse integerKeyword(schema, "minItems")) |minimum| if (length < minimum) return false;
    if (integerKeyword(schema, "maxLength") orelse integerKeyword(schema, "maxItems")) |maximum| if (length > maximum) return false;
    return true;
}

fn integerKeyword(schema: std.json.ObjectMap, name: []const u8) ?usize {
    const value = schema.get(name) orelse return null;
    return switch (value) {
        .integer => |item| if (item >= 0) @intCast(item) else null,
        else => null,
    };
}

fn matchesNumber(schema: std.json.ObjectMap, actual: f64) bool {
    if (numberKeyword(schema, "minimum")) |minimum| if (actual < minimum) return false;
    if (numberKeyword(schema, "maximum")) |maximum| if (actual > maximum) return false;
    return true;
}

fn numberKeyword(schema: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = schema.get(name) orelse return null;
    return switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| item,
        else => null,
    };
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
    try std.testing.expectError(Error.OutputSchemaValidationFailed, validate(std.testing.allocator, .{ .json_schema = .{ .name = "bad", .schema = "[]" } }, "{}"));
}

test "schema matcher covers boolean schemas, type arrays, and enum equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(matches(.{ .bool = true }, .null));
    try std.testing.expect(!matches(.{ .bool = false }, .null));
    const union_schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"type\":[\"string\",\"null\"]}", .{});
    try std.testing.expect(matches(union_schema, .{ .string = "ok" }));
    try std.testing.expect(matches(union_schema, .null));
    try std.testing.expect(!matches(union_schema, .{ .bool = true }));
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
    const required_wrong = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"required\":true}", .{});
    try std.testing.expect(!matches(required_wrong, actual));
    const denied = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"properties\":{\"known\":{\"type\":\"string\"}},\"additionalProperties\":false}", .{});
    try std.testing.expect(!matches(denied, actual));
    const typed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"properties\":{\"known\":{\"type\":\"string\"}},\"additionalProperties\":{\"type\":\"string\"}}", .{});
    try std.testing.expect(matches(typed, actual));
    const bad_actual = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"extra\":1}", .{});
    try std.testing.expect(!matches(typed, bad_actual));
    const invalid_additional = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"additionalProperties\":1}", .{});
    try std.testing.expect(!matches(invalid_additional, actual));
}
