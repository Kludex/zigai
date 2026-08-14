//! Purpose: Compare loaded YAML value graphs with yaml-test-suite `in.json`.
//! Owns: JSON document splitting and recursive node-to-JSON assertions.
//! Does not own: YAML loading or suite discovery.
//! Depends on: yaml public value model, std.json.
//! Tested by: tests/conformance/yaml_suite_runner.zig.

const std = @import("std");
const yaml = @import("yaml");

pub fn expectLoadedStreamJsonEqual(
    allocator: std.mem.Allocator,
    documents: []const *const yaml.Node,
    expected_json: []const u8,
) !void {
    var cursor: usize = 0;
    var document_index: usize = 0;

    while (try nextJsonDocument(expected_json, &cursor)) |json_document| {
        if (document_index >= documents.len) return error.TestUnexpectedResult;

        var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, json_document, .{});
        defer parsed_json.deinit();

        try expectNodeJsonEqual(documents[document_index], parsed_json.value);
        document_index += 1;
    }

    try std.testing.expectEqual(documents.len, document_index);
}

fn nextJsonDocument(input: []const u8, cursor: *usize) !?[]const u8 {
    const start = skipJsonWhitespace(input, cursor.*);
    if (start == input.len) {
        cursor.* = start;
        return null;
    }

    const end = switch (input[start]) {
        '{', '[' => try findJsonCompositeEnd(input, start),
        '"' => try findJsonStringEnd(input, start),
        else => findJsonScalarEnd(input, start),
    };

    cursor.* = end;
    return input[start..end];
}

fn findJsonCompositeEnd(input: []const u8, start: usize) !usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];

        if (in_string) {
            if (escaped) {
                escaped = false;
            } else switch (byte) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return error.TestUnexpectedResult;
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
    }

    return error.TestUnexpectedResult;
}

fn findJsonStringEnd(input: []const u8, start: usize) !usize {
    var escaped = false;

    var index = start + 1;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (escaped) {
            escaped = false;
        } else switch (byte) {
            '\\' => escaped = true,
            '"' => return index + 1,
            else => {},
        }
    }

    return error.TestUnexpectedResult;
}

fn findJsonScalarEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and !isJsonWhitespace(input[end])) : (end += 1) {}
    return end;
}

fn skipJsonWhitespace(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len and isJsonWhitespace(input[index])) : (index += 1) {}
    return index;
}

fn isJsonWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn expectNodeJsonEqual(node: *const yaml.Node, expected: std.json.Value) !void {
    switch (expected) {
        .null => {
            try std.testing.expect(node.* == .null_value);
        },
        .bool => |value| {
            try std.testing.expect(node.* == .bool_value);
            try std.testing.expectEqual(value, node.bool_value.value);
        },
        .integer => |value| {
            switch (node.*) {
                .int_value => |actual| try std.testing.expectEqual(@as(i128, value), actual.value),
                .float_value => |actual| try std.testing.expectEqual(@as(f64, @floatFromInt(value)), actual.value),
                else => return error.TestUnexpectedResult,
            }
        },
        .float => |value| {
            switch (node.*) {
                .int_value => |actual| try std.testing.expectEqual(value, @as(f64, @floatFromInt(actual.value))),
                .float_value => |actual| try std.testing.expectEqual(value, actual.value),
                else => return error.TestUnexpectedResult,
            }
        },
        .string => |value| {
            try std.testing.expect(node.* == .scalar);
            try std.testing.expectEqualStrings(value, node.scalar.value);
        },
        .array => |array| {
            try std.testing.expect(node.* == .sequence);
            try std.testing.expectEqual(array.items.len, node.sequence.items.len);
            for (array.items, node.sequence.items) |expected_item, actual_item| {
                try expectNodeJsonEqual(actual_item, expected_item);
            }
        },
        .object => |object| {
            try std.testing.expect(node.* == .mapping);
            try std.testing.expectEqual(object.count(), node.mapping.pairs.len);

            var iter = object.iterator();
            while (iter.next()) |entry| {
                const value_node = findMappingValue(node.mapping.pairs, entry.key_ptr.*) orelse {
                    std.debug.print("missing mapping key {s}\n", .{entry.key_ptr.*});
                    return error.TestExpectedEqual;
                };
                try expectNodeJsonEqual(value_node, entry.value_ptr.*);
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

fn findMappingValue(mapping: []const yaml.MappingPair, key: []const u8) ?*const yaml.Node {
    for (mapping) |pair| {
        if (pair.key.* == .scalar and std.mem.eql(u8, pair.key.scalar.value, key)) {
            return pair.value;
        }
    }
    return null;
}
