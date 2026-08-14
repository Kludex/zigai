//! Purpose: Decode YAML input bytes into UTF-8.
//! Owns: UTF-8/UTF-16/UTF-32 detection and UTF decoding.
//! Does not own: Scanner tokenization or parse diagnostics.
//! Depends on: std, reader/line_break.zig.
//! Tested by: in-file tests and scanner/parser integration tests.

const std = @import("std");
const line_break = @import("line_break.zig");

pub const Error = error{InvalidSyntax} || std.mem.Allocator.Error;

pub const InputEncoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,
};

pub const DetectedInputEncoding = struct {
    encoding: InputEncoding,
    offset: usize = 0,
};

pub const DecodedInput = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: DecodedInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

pub const normalizeYamlLineBreaks = line_break.normalizeYamlLineBreaks;

pub fn decodeInputBytes(allocator: std.mem.Allocator, input: []const u8) Error!DecodedInput {
    const detected = detectInputEncoding(input);
    const content = input[detected.offset..];

    return switch (detected.encoding) {
        .utf8 => .{ .bytes = input },
        .utf16_le => blk: {
            const decoded = try decodeUtf16Bytes(allocator, content, .little);
            break :blk .{ .bytes = decoded, .owned = decoded };
        },
        .utf16_be => blk: {
            const decoded = try decodeUtf16Bytes(allocator, content, .big);
            break :blk .{ .bytes = decoded, .owned = decoded };
        },
        .utf32_le => blk: {
            const decoded = try decodeUtf32Bytes(allocator, content, .little);
            break :blk .{ .bytes = decoded, .owned = decoded };
        },
        .utf32_be => blk: {
            const decoded = try decodeUtf32Bytes(allocator, content, .big);
            break :blk .{ .bytes = decoded, .owned = decoded };
        },
    };
}

pub fn detectInputEncoding(input: []const u8) DetectedInputEncoding {
    if (std.mem.startsWith(u8, input, "\x00\x00\xFE\xFF")) return .{ .encoding = .utf32_be, .offset = 4 };
    if (std.mem.startsWith(u8, input, "\xFF\xFE\x00\x00")) return .{ .encoding = .utf32_le, .offset = 4 };
    if (std.mem.startsWith(u8, input, "\xFE\xFF")) return .{ .encoding = .utf16_be, .offset = 2 };
    if (std.mem.startsWith(u8, input, "\xFF\xFE")) return .{ .encoding = .utf16_le, .offset = 2 };

    if (input.len >= 4) {
        if (input[0] == 0 and input[1] == 0 and input[2] == 0 and input[3] != 0) {
            return .{ .encoding = .utf32_be };
        }
        if (input[0] != 0 and input[1] == 0 and input[2] == 0 and input[3] == 0) {
            return .{ .encoding = .utf32_le };
        }
        if (input[0] == 0 and input[1] != 0 and input[2] == 0 and input[3] != 0) {
            return .{ .encoding = .utf16_be };
        }
        if (input[0] != 0 and input[1] == 0 and input[2] != 0 and input[3] == 0) {
            return .{ .encoding = .utf16_le };
        }
    }

    if (input.len >= 2) {
        if (input[0] == 0 and input[1] != 0) return .{ .encoding = .utf16_be };
        if (input[0] != 0 and input[1] == 0) return .{ .encoding = .utf16_le };
    }

    return .{ .encoding = .utf8 };
}

fn decodeUtf16Bytes(allocator: std.mem.Allocator, input: []const u8, endian: std.builtin.Endian) Error![]u8 {
    if (input.len % 2 != 0) return error.InvalidSyntax;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const code_unit = std.mem.readInt(u16, input[index..][0..2], endian);
        index += 2;

        const codepoint: u21 = if (std.unicode.utf16IsHighSurrogate(code_unit)) blk: {
            if (index >= input.len) return error.InvalidSyntax;
            const low = std.mem.readInt(u16, input[index..][0..2], endian);
            index += 2;
            if (!std.unicode.utf16IsLowSurrogate(low)) return error.InvalidSyntax;

            const high_ten: u21 = @as(u21, code_unit) - 0xD800;
            const low_ten: u21 = @as(u21, low) - 0xDC00;
            break :blk 0x10000 + ((high_ten << 10) | low_ten);
        } else if (std.unicode.utf16IsLowSurrogate(code_unit)) {
            return error.InvalidSyntax;
        } else @as(u21, code_unit);

        try appendEncodedCodepoint(allocator, &out, codepoint);
    }

    return out.toOwnedSlice(allocator);
}

fn decodeUtf32Bytes(allocator: std.mem.Allocator, input: []const u8, endian: std.builtin.Endian) Error![]u8 {
    if (input.len % 4 != 0) return error.InvalidSyntax;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) : (index += 4) {
        const raw = std.mem.readInt(u32, input[index..][0..4], endian);
        if (raw > 0x10ffff) return error.InvalidSyntax;
        const codepoint: u21 = @intCast(raw);
        try appendEncodedCodepoint(allocator, &out, codepoint);
    }

    return out.toOwnedSlice(allocator);
}

fn appendEncodedCodepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidSyntax;
    try out.appendSlice(allocator, buffer[0..len]);
}

test "reader encoding: detects BOMs and null-byte encoding patterns" {
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_be, .offset = 4 }, detectInputEncoding("\x00\x00\xFE\xFF\x00\x00\x00a"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_le, .offset = 4 }, detectInputEncoding("\xFF\xFE\x00\x00a\x00\x00\x00"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_be, .offset = 2 }, detectInputEncoding("\xFE\xFF\x00a"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_le, .offset = 2 }, detectInputEncoding("\xFF\xFEa\x00"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_be }, detectInputEncoding("\x00\x00\x00a"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_le }, detectInputEncoding("a\x00\x00\x00"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_be }, detectInputEncoding("\x00a\x00b"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_le }, detectInputEncoding("a\x00b\x00"));
}

test "reader encoding: decodes UTF-16 surrogate pairs and rejects malformed units" {
    const decoded = try decodeInputBytes(std.testing.allocator, "\xFF\xFEA\x00=\xD8\x00\xDE");
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A😀", decoded.bytes);

    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\xFE\xFF\x00"));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\xFE\xFF\xD8\x3D"));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\xFE\xFF\xD8\x3D\x00A"));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\xFE\xFF\xDE\x00"));
}

test "reader encoding: decodes UTF-32 and rejects malformed code points" {
    const decoded = try decodeInputBytes(std.testing.allocator, "\x00\x00\xFE\xFF\x00\x00\x00A\x00\x01\xF6\x00");
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A😀", decoded.bytes);

    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\x00\x00\xFE\xFF\x00\x00\x00"));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, "\x00\x00\xFE\xFF\x00\x11\x00\x00"));
}
