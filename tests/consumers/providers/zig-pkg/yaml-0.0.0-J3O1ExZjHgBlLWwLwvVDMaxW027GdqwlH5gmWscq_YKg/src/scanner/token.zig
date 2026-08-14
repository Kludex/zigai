//! Purpose: Define scanner tokens and token-stream ownership.
//! Owns: Token payload types and arena-owned token stream lifecycle.
//! Does not own: Tokenization logic or parser interpretation.
//! Depends on: std.
//! Tested by: tests/unit/scanner/scanner_test.zig and parser/event conformance tests.

const std = @import("std");

/// Lexical token produced by `scan`.
///
/// Payload slices either borrow from unchanged UTF-8 input passed to `scan` or
/// point into decoded or normalized storage owned by the returned `TokenStream`.
pub const Token = union(enum) {
    stream_start,
    stream_end,
    directive: []const u8,
    comment: []const u8,
    document_start,
    document_start_content: DocumentStartContent,
    document_end,
    indent: usize,
    block_sequence_entry,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    flow_entry,
    flow_mapping_key,
    flow_mapping_value,
    anchor: []const u8,
    alias: []const u8,
    tag: []const u8,
    block_scalar: BlockScalar,
    scalar: []const u8,
};

pub const DocumentStartContent = struct {
    separated_by_tab: bool = false,
};

/// Block scalar presentation style from a `|` or `>` header.
pub const BlockScalarStyle = enum {
    literal,
    folded,
};

/// Block scalar chomping indicator from a block scalar header.
pub const BlockScalarChomping = enum {
    clip,
    strip,
    keep,
};

/// Lexical block scalar token.
///
/// `content` is the raw block scalar body slice. Folding, chomping, and
/// indentation stripping belong to later parser stages.
pub const BlockScalar = struct {
    style: BlockScalarStyle,
    chomping: BlockScalarChomping = .clip,
    indent_indicator: ?usize = null,
    content: []const u8,
};

/// Errors returned by the scanner.
pub const Error = error{InvalidSyntax} || std.mem.Allocator.Error;

/// Arena-owned sequence of scanner tokens.
///
/// Token storage and any decoded or normalized UTF input are owned by this
/// stream and released with `deinit`. Payload slices are valid until `deinit`;
/// keep borrowed UTF-8 input alive while inspecting tokens.
pub const TokenStream = struct {
    arena: std.heap.ArenaAllocator,
    /// Decoded UTF-8 source after YAML line-break normalization.
    ///
    /// This slice is valid until `deinit`. It may borrow from caller-provided
    /// UTF-8 input when no decoding or line-break normalization was required.
    source: []const u8,
    tokens: []const Token,

    pub fn deinit(self: *TokenStream) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
