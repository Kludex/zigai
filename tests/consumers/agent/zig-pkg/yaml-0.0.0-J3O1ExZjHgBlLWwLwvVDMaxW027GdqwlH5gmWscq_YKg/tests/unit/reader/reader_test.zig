//! Purpose: Verify the reader layer decodes YAML input and tracks byte locations.
//! Owns: Reader-layer regression coverage.
//! Does not own: Scanner tokenization or parser diagnostics.
//! Depends on: yaml_internal.reader.
//! Tested by: zig build test-unit.

const std = @import("std");
const yaml_internal = @import("yaml_internal");

const Reader = yaml_internal.reader.Reader;
const DetectedInputEncoding = yaml_internal.reader.DetectedInputEncoding;
const prepare = yaml_internal.reader.prepare;
const decodeInputBytes = yaml_internal.reader.decodeInputBytes;
const detectInputEncoding = yaml_internal.reader.detectInputEncoding;

test "reader: detects byte order marks" {
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_be, .offset = 4 }, detectInputEncoding("\x00\x00\xFE\xFF\x00\x00\x00a"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_le, .offset = 4 }, detectInputEncoding("\xFF\xFE\x00\x00a\x00\x00\x00"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_be, .offset = 2 }, detectInputEncoding("\xFE\xFF\x00a"));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_le, .offset = 2 }, detectInputEncoding("\xFF\xFEa\x00"));
}

test "reader: detects null-pattern encodings without byte order marks" {
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_be }, detectInputEncoding(&.{ 0x00, 0x00, 0x00, 'a' }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf32_le }, detectInputEncoding(&.{ 'a', 0x00, 0x00, 0x00 }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_be }, detectInputEncoding(&.{ 0x00, 'a', 0x00, 'b' }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_le }, detectInputEncoding(&.{ 'a', 0x00, 'b', 0x00 }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_be }, detectInputEncoding(&.{ 0x00, 'a' }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf16_le }, detectInputEncoding(&.{ 'a', 0x00 }));
    try std.testing.expectEqual(DetectedInputEncoding{ .encoding = .utf8 }, detectInputEncoding("plain"));
}

test "reader: decodes UTF inputs and preserves UTF-8 borrowing" {
    const utf8 = try decodeInputBytes(std.testing.allocator, "plain");
    defer utf8.deinit(std.testing.allocator);
    try std.testing.expect(utf8.owned == null);
    try std.testing.expectEqualStrings("plain", utf8.bytes);

    var utf16_le = try decodeInputBytes(std.testing.allocator, &.{ 0xff, 0xfe, 'o', 0x00, 'k', 0x00 });
    defer utf16_le.deinit(std.testing.allocator);
    try std.testing.expect(utf16_le.owned != null);
    try std.testing.expectEqualStrings("ok", utf16_le.bytes);

    var utf32_be = try decodeInputBytes(std.testing.allocator, &.{ 0x00, 0x00, 0xfe, 0xff, 0x00, 0x00, 0x00, '!' });
    defer utf32_be.deinit(std.testing.allocator);
    try std.testing.expect(utf32_be.owned != null);
    try std.testing.expectEqualStrings("!", utf32_be.bytes);
}

test "reader: rejects malformed UTF-16 and UTF-32 byte streams" {
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, &.{ 0xff, 0xfe, 0x00 }));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, &.{ 0xfe, 0xff, 0xd8, 0x00 }));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, &.{ 0xff, 0xfe, 0x00, 0xdc }));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, &.{ 0x00, 0x00, 0xfe, 0xff, 0x00 }));
    try std.testing.expectError(error.InvalidSyntax, decodeInputBytes(std.testing.allocator, &.{ 0x00, 0x00, 0xfe, 0xff, 0x00, 0x11, 0x00, 0x00 }));
}

test "reader: prepares decoded normalized source for scanner layers" {
    const input = [_]u8{
        0xff, 0xfe,
        'a',  0,
        '\r', 0,
        '\n', 0,
        'b',  0,
    };

    var source = try prepare(std.testing.allocator, &input);
    defer source.deinit();

    try std.testing.expectEqualStrings("a\nb", source.bytes);
}

test "reader: prepares printable ASCII LF source without copying" {
    const input = "root:\n\tkey: value\nplain: !#$%&()*+,-./09:;<=>?@AZ[]^_`az{|}~\n";

    var source = try prepare(std.testing.allocator, input);
    defer source.deinit();

    try std.testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(source.bytes.ptr));
    try std.testing.expectEqualStrings(input, source.bytes);
}

test "reader: rejects invalid ASCII control bytes" {
    const cases = [_][]const u8{
        "bad\x00x",
        "bad\x08",
        "bad\x0b",
        "bad\x0c",
        "bad\x1f",
        "bad\x7f",
    };

    for (cases) |input| {
        try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, input));
    }
}

test "reader: normalizes CR and CRLF while preserving LF" {
    var source = try prepare(std.testing.allocator, "one\r\ntwo\rthree\nfour");
    defer source.deinit();

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", source.bytes);
}

test "reader: falls back for non-ASCII validation and line breaks" {
    const non_ascii = "caf\xc3\xa9\nnext";
    var valid = try prepare(std.testing.allocator, non_ascii);
    defer valid.deinit();
    try std.testing.expectEqual(@intFromPtr(non_ascii.ptr), @intFromPtr(valid.bytes.ptr));
    try std.testing.expectEqualStrings(non_ascii, valid.bytes);

    var normalized = try prepare(std.testing.allocator, "one\xc2\x85two");
    defer normalized.deinit();
    try std.testing.expectEqualStrings("one\ntwo", normalized.bytes);

    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, "bad\xc3("));
}

test "reader: normalizes YAML non-ASCII line breaks" {
    var source = try prepare(std.testing.allocator, "one\xc2\x85two\xe2\x80\xa8three\xe2\x80\xa9four");
    defer source.deinit();

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", source.bytes);
}

test "reader: normalizes YAML line breaks at stream boundaries" {
    var terminal_cr = try prepare(std.testing.allocator, "one\r");
    defer terminal_cr.deinit();
    try std.testing.expectEqualStrings("one\n", terminal_cr.bytes);

    var terminal_crlf = try prepare(std.testing.allocator, "one\r\n");
    defer terminal_crlf.deinit();
    try std.testing.expectEqualStrings("one\n", terminal_crlf.bytes);

    var adjacent = try prepare(std.testing.allocator, "one\r\xc2\x85\xe2\x80\xa8\xe2\x80\xa9two");
    defer adjacent.deinit();
    try std.testing.expectEqualStrings("one\n\n\n\ntwo", adjacent.bytes);
}

test "reader: prepares UTF-32 little-endian source" {
    const input = [_]u8{
        0xff, 0xfe, 0x00, 0x00,
        'o',  0x00, 0x00, 0x00,
        'k',  0x00, 0x00, 0x00,
    };

    var source = try prepare(std.testing.allocator, &input);
    defer source.deinit();

    try std.testing.expectEqualStrings("ok", source.bytes);
}

test "reader: prepares UTF-16 big-endian source" {
    const input = [_]u8{
        0xfe, 0xff,
        0x00, 'o',
        0x00, 'k',
    };

    var source = try prepare(std.testing.allocator, &input);
    defer source.deinit();

    try std.testing.expectEqualStrings("ok", source.bytes);
}

test "reader: prepares UTF-32 big-endian source" {
    const input = [_]u8{
        0x00, 0x00, 0xfe, 0xff,
        0x00, 0x00, 0x00, 'o',
        0x00, 0x00, 0x00, 'k',
    };

    var source = try prepare(std.testing.allocator, &input);
    defer source.deinit();

    try std.testing.expectEqualStrings("ok", source.bytes);
}

test "reader: detects UTF encodings without byte order marks" {
    var utf16_be = try prepare(std.testing.allocator, &[_]u8{ 0x00, 'o', 0x00, 'k' });
    defer utf16_be.deinit();
    try std.testing.expectEqualStrings("ok", utf16_be.bytes);

    var utf16_le = try prepare(std.testing.allocator, &[_]u8{ 'o', 0x00, 'k', 0x00 });
    defer utf16_le.deinit();
    try std.testing.expectEqualStrings("ok", utf16_le.bytes);

    var utf32_be = try prepare(std.testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 'o', 0x00, 0x00, 0x00, 'k' });
    defer utf32_be.deinit();
    try std.testing.expectEqualStrings("ok", utf32_be.bytes);

    var utf32_le = try prepare(std.testing.allocator, &[_]u8{ 'o', 0x00, 0x00, 0x00, 'k', 0x00, 0x00, 0x00 });
    defer utf32_le.deinit();
    try std.testing.expectEqualStrings("ok", utf32_le.bytes);
}

test "reader: decodes UTF-16 surrogate pairs" {
    const input = [_]u8{
        0xff, 0xfe,
        0x3d, 0xd8,
        0x00, 0xde,
    };

    var source = try prepare(std.testing.allocator, &input);
    defer source.deinit();

    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", source.bytes);
}

test "reader: rejects malformed UTF-16 input" {
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00 }));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0xd8 }));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0xdc }));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0xd8, 'x', 0x00 }));
}

test "reader: rejects malformed UTF-32 input" {
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0x00, 0x01 }));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00 }));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 0x00, 0x00, 0x00, 0xd8, 0x00, 0x00 }));
}

test "reader: rejects non-printable decoded input" {
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, "bad\x01"));
    try std.testing.expectError(error.InvalidSyntax, prepare(std.testing.allocator, &[_]u8{ 0xff, 0xfe, 'b', 0x00, 0x01, 0x00 }));
}

test "reader: advances through UTF-8 bytes with one-based locations" {
    var source = try prepare(std.testing.allocator, "a\nbc");
    defer source.deinit();

    var reader = Reader.init(source.bytes);

    try std.testing.expectEqual(@as(usize, 0), reader.offset());
    try std.testing.expectEqual(@as(usize, 1), reader.location().line);
    try std.testing.expectEqual(@as(usize, 1), reader.location().column);

    try std.testing.expectEqual(@as(?u8, 'a'), reader.next());
    try std.testing.expectEqual(@as(usize, 1), reader.offset());
    try std.testing.expectEqual(@as(usize, 1), reader.location().line);
    try std.testing.expectEqual(@as(usize, 2), reader.location().column);

    try std.testing.expectEqual(@as(?u8, '\n'), reader.next());
    try std.testing.expectEqual(@as(usize, 2), reader.offset());
    try std.testing.expectEqual(@as(usize, 2), reader.location().line);
    try std.testing.expectEqual(@as(usize, 1), reader.location().column);

    try std.testing.expectEqual(@as(?u8, 'b'), reader.peek());
    try std.testing.expectEqual(@as(?u8, 'b'), reader.next());
    try std.testing.expectEqual(@as(?u8, 'c'), reader.next());
    try std.testing.expectEqual(@as(?u8, null), reader.next());
}
