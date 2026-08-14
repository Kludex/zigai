//! Purpose: Normalize YAML reader line breaks.
//! Owns: YAML line-break normalization for prepared UTF-8 input.
//! Does not own: Character encoding detection, UTF decoding, or scanner line tokenization.
//! Depends on: std.
//! Tested by: in-file tests and scanner/parser integration tests.

const std = @import("std");

pub const Error = error{InvalidSyntax} || std.mem.Allocator.Error;

pub const NormalizedInput = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: NormalizedInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

/// Returns YAML source bytes after line-break normalization.
///
/// YAML 1.2.2 line breaks are LF, CR, CRLF, NEL, LS, and PS. All non-LF
/// variants are normalized to LF. The returned bytes borrow `input` when no
/// normalization is needed.
pub fn normalizeYamlLineBreaks(allocator: std.mem.Allocator, input: []const u8) Error!NormalizedInput {
    var ascii_index: usize = 0;
    while (ascii_index < input.len) : (ascii_index += 1) {
        const byte = input[ascii_index];
        if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte <= 0x7e)) continue;
        if (byte < 0x80 and byte != '\r') return error.InvalidSyntax;
        break;
    }
    if (ascii_index == input.len) return .{ .bytes = input };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var normalized = false;
    var copy_start: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[index]) catch return error.InvalidSyntax;
        if (index + len > input.len) return error.InvalidSyntax;
        const codepoint = std.unicode.utf8Decode(input[index .. index + len]) catch return error.InvalidSyntax;
        if (!isYamlPrintableCodepoint(codepoint)) return error.InvalidSyntax;

        const replacement_len: ?usize = switch (codepoint) {
            '\r' => if (index + 1 < input.len and input[index + 1] == '\n') 2 else 1,
            0x85, 0x2028, 0x2029 => len,
            else => null,
        };
        if (replacement_len) |consumed| {
            if (!normalized) {
                try out.ensureTotalCapacity(allocator, input.len);
                normalized = true;
            }
            try out.appendSlice(allocator, input[copy_start..index]);
            try out.append(allocator, '\n');
            index += consumed;
            copy_start = index;
            continue;
        }

        index += len;
    }

    if (!normalized) return .{ .bytes = input };

    try out.appendSlice(allocator, input[copy_start..]);
    const owned = try out.toOwnedSlice(allocator);
    return .{ .bytes = owned, .owned = owned };
}

fn isYamlPrintableCodepoint(codepoint: u21) bool {
    return codepoint == 0x09 or
        codepoint == 0x0a or
        codepoint == 0x0d or
        (codepoint >= 0x20 and codepoint <= 0x7e) or
        codepoint == 0x85 or
        (codepoint >= 0xa0 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

test normalizeYamlLineBreaks {
    var normalized = try normalizeYamlLineBreaks(std.testing.allocator, "one\r\ntwo\rthree\nfour\xc2\x85five\xe2\x80\xa8six\xe2\x80\xa9seven");
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expect(normalized.owned != null);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix\nseven", normalized.bytes);
}

test "normalizeYamlLineBreaks borrows input when no normalization is needed" {
    const input = "one\ntwo\xc2\xa0three";

    const normalized = try normalizeYamlLineBreaks(std.testing.allocator, input);
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expect(normalized.owned == null);
    try std.testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(normalized.bytes.ptr));
    try std.testing.expectEqualStrings(input, normalized.bytes);
}

test "normalizeYamlLineBreaks cleans up after allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkNormalizeYamlLineBreaksAllocationFailure, .{});
}

test "normalizeYamlLineBreaks rejects malformed and non-printable UTF-8" {
    try std.testing.expectError(error.InvalidSyntax, normalizeYamlLineBreaks(std.testing.allocator, "\xc3"));
    try std.testing.expectError(error.InvalidSyntax, normalizeYamlLineBreaks(std.testing.allocator, "bad\x01"));
}

fn checkNormalizeYamlLineBreaksAllocationFailure(allocator: std.mem.Allocator) !void {
    var normalized = try normalizeYamlLineBreaks(allocator, "one\r\ntwo\xc2\x85three\xe2\x80\xa8four");
    defer normalized.deinit(allocator);

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", normalized.bytes);
}
