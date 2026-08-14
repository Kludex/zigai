//! Purpose: Prepare YAML input bytes and expose byte-wise source iteration.
//! Owns: Reader-level input preparation, byte offsets, and one-based locations.
//! Does not own: Scanner tokenization, parser grammar, or diagnostics.
//! Depends on: common/location.zig, reader/encoding.zig.
//! Tested by: tests/unit/reader/reader_test.zig.

const std = @import("std");
const location = @import("../common/location.zig");
const encoding = @import("encoding.zig");

pub const Error = encoding.Error;
pub const SourceLocation = location.SourceLocation;
pub const InputEncoding = encoding.InputEncoding;
pub const DetectedInputEncoding = encoding.DetectedInputEncoding;
pub const DecodedInput = encoding.DecodedInput;

pub const normalizeYamlLineBreaks = encoding.normalizeYamlLineBreaks;
pub const decodeInputBytes = encoding.decodeInputBytes;
pub const detectInputEncoding = encoding.detectInputEncoding;

/// Prepared YAML source used by scanner and reader consumers.
///
/// `bytes` is decoded UTF-8 after YAML CR/CRLF line-break normalization. It is
/// valid until `deinit`. When the caller supplied already-valid UTF-8 without
/// normalizable line breaks, `bytes` may borrow the caller's input.
pub const Source = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,

    pub fn allocator(self: *Source) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Source) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn releaseArena(self: *Source) std.heap.ArenaAllocator {
        const arena = self.arena;
        self.* = undefined;
        return arena;
    }
};

/// Decodes YAML input bytes and normalizes YAML line breaks for downstream
/// scanner/parser layers.
pub fn prepare(allocator: std.mem.Allocator, input: []const u8) Error!Source {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    const decoded = try encoding.decodeInputBytes(arena_allocator, input);
    const normalized = try encoding.normalizeYamlLineBreaks(arena_allocator, decoded.bytes);
    return .{
        .arena = arena,
        .bytes = normalized.bytes,
    };
}

/// Byte-wise reader over prepared YAML source.
///
/// Offsets are zero-based byte offsets. Locations are one-based byte line and
/// column positions for the next byte to read.
pub const Reader = struct {
    bytes: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn offset(self: Reader) usize {
        return self.index;
    }

    pub fn location(self: Reader) SourceLocation {
        return .{
            .line = self.line,
            .column = self.column,
        };
    }

    pub fn peek(self: Reader) ?u8 {
        if (self.index >= self.bytes.len) return null;
        return self.bytes[self.index];
    }

    pub fn next(self: *Reader) ?u8 {
        const byte = self.peek() orelse return null;
        self.index += 1;
        if (byte == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return byte;
    }
};

test {
    std.testing.refAllDecls(@This());
}
