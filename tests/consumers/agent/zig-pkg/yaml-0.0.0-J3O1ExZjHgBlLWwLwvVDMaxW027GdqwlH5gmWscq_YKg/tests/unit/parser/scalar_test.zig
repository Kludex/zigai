//! Purpose: Verify scalar parser token behavior.
//! Owns: Consolidated scalar parser token regression coverage.
//! Does not own: Shared parser test helpers or conformance harness behavior.
//! Depends on: support.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig.

const support = @import("support.zig");

const std = support.std;
const scanner = support.scanner;
const parser = support.event_parser.parser;
const parseTokens = support.parseTokens;
const ParseError = support.ParseError;
const types = support.types;
const expectInvalidSyntaxFromScanOrParse = support.expectInvalidSyntaxFromScanOrParse;

test "parseTokens parses plain scalar comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\# leading
        \\plain # trailing
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseScalarToken fast paths simple scalar allocations" {
    const content = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-simple-scalar-content";
    const plain_token = content;
    const single_token = "'" ++ content ++ "'";
    const double_token = "\"" ++ content ++ "\"";

    try expectSimpleScalarAllocation(plain_token, content, .plain);
    try expectSimpleScalarAllocation(single_token, content, .single_quoted);
    try expectSimpleScalarAllocation(double_token, content, .double_quoted);
}

fn expectSimpleScalarAllocation(token: []const u8, expected: []const u8, style: types.ScalarStyle) !void {
    var counter: CountingAllocator = .{ .child = std.testing.allocator };
    const counted_allocator = counter.allocator();

    const parsed = try parser.parseScalarToken(counted_allocator, token);
    defer counted_allocator.free(parsed.value);

    try std.testing.expectEqual(style, parsed.style);
    try std.testing.expectEqualStrings(expected, parsed.value);
    try std.testing.expectEqual(expected.len, counter.allocated_bytes);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocated_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocated_bytes += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn countResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) self.allocated_bytes += new_len - old_len;
    }
};

test "parseTokens parses an explicit empty document with comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\# Empty
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseTokens parses an alias document" {
    var token_stream = try scanner.scan(std.testing.allocator, "*anchor\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[2].alias);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .stream_end);

    try std.testing.expect(@intFromPtr(event_stream.events[2].alias.ptr) != @intFromPtr(token_stream.tokens[2].alias.ptr));
}

test "parseTokens marks alias documents with explicit end" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\*anchor
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[2].alias);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
}

test "parseTokens marks alias documents after explicit marker as same-line content" {
    var token_stream = try scanner.scan(std.testing.allocator, "--- *anchor\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line);
    try std.testing.expect(event_stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[2].alias);
}

test "parseTokens preserves tab-separated alias document start metadata" {
    var token_stream = try scanner.scan(std.testing.allocator, "---\t*anchor\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line_separated_by_tab);
    try std.testing.expect(event_stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[2].alias);
}

test "parseTokens rejects alias documents with trailing scalar content" {
    var token_stream = try scanner.scan(std.testing.allocator, "*anchor trailing\n");
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects alias documents with trailing block collection content" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\*anchor
        \\- trailing
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens rejects node properties before alias documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\&node
        \\*anchor
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses alias documents followed by indented comments" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\*anchor
        \\  # trailing comment
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .alias);
    try std.testing.expectEqualStrings("anchor", event_stream.events[2].alias);
}

test "parseTokens parses an anchored scalar document" {
    var token_stream = try scanner.scan(std.testing.allocator, "&node plain\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("node", event_stream.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
}

test "parseTokens parses a tagged scalar document" {
    var token_stream = try scanner.scan(std.testing.allocator, "!<tag:example.com,2000:app/foo> \"bar\"\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("bar", event_stream.events[2].scalar.value);
}

test "parseTokens decodes percent escapes in verbatim tag URIs" {
    var token_stream = try scanner.scan(std.testing.allocator, "!<tag:example.com,2000:app%2Ffoo> value\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("tag:example.com,2000:app/foo", event_stream.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", event_stream.events[2].scalar.value);
}

test "parseTokens decodes double-quoted non-ASCII separator escapes" {
    var token_stream = try scanner.scan(std.testing.allocator, "\"\\N\\L\\P\"\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("\xC2\x85\xE2\x80\xA8\xE2\x80\xA9", event_stream.events[2].scalar.value);
}

test "parseTokens parses a top-level tag-only empty scalar" {
    var token_stream = try scanner.scan(std.testing.allocator, "!\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[2].scalar.value);
    try std.testing.expectEqualStrings("!", event_stream.events[2].scalar.tag.?);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseTokens marks property-only empty scalar documents with explicit end" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\!
        \\...
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[2].scalar.value);
    try std.testing.expectEqualStrings("!", event_stream.events[2].scalar.tag.?);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
}

test "parseTokens parses split node properties before top-level scalar documents" {
    var plain_tokens = try scanner.scan(std.testing.allocator,
        \\&plain
        \\value
        \\
    );
    defer plain_tokens.deinit();

    var plain_events = try parseTokens(std.testing.allocator, plain_tokens.tokens);
    defer plain_events.deinit();

    try std.testing.expectEqual(@as(usize, 5), plain_events.events.len);
    try std.testing.expect(plain_events.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", plain_events.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("value", plain_events.events[2].scalar.value);

    var quoted_tokens = try scanner.scan(std.testing.allocator,
        \\!<tag:example.com,2000:scalar>
        \\"value"
        \\
    );
    defer quoted_tokens.deinit();

    var quoted_events = try parseTokens(std.testing.allocator, quoted_tokens.tokens);
    defer quoted_events.deinit();

    try std.testing.expectEqual(@as(usize, 5), quoted_events.events.len);
    try std.testing.expect(quoted_events.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, quoted_events.events[2].scalar.style);
    try std.testing.expectEqualStrings("tag:example.com,2000:scalar", quoted_events.events[2].scalar.tag.?);
    try std.testing.expectEqualStrings("value", quoted_events.events[2].scalar.value);

    var block_tokens = try scanner.scan(std.testing.allocator,
        \\&block
        \\|
        \\  value
        \\
    );
    defer block_tokens.deinit();

    var block_events = try parseTokens(std.testing.allocator, block_tokens.tokens);
    defer block_events.deinit();

    try std.testing.expectEqual(@as(usize, 5), block_events.events.len);
    try std.testing.expect(block_events.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, block_events.events[2].scalar.style);
    try std.testing.expectEqualStrings("block", block_events.events[2].scalar.anchor.?);
    try std.testing.expectEqualStrings("value\n", block_events.events[2].scalar.value);
}

test "parseTokens parses a top-level literal block scalar" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\|
        \\  line one
        \\  line two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("line one\nline two\n", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseTokens parses a top-level folded block scalar" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\>
        \\  line one
        \\  line two
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[0] == .stream_start);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.folded, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("line one line two\n", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[4] == .stream_end);
}

test "parseTokens parses same-line document start flow collections" {
    var sequence_tokens = try scanner.scan(std.testing.allocator, "--- [one]\n");
    defer sequence_tokens.deinit();
    var sequence_events = try parseTokens(std.testing.allocator, sequence_tokens.tokens);
    defer sequence_events.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_events.events.len);
    try std.testing.expect(sequence_events.events[1] == .document_start);
    try std.testing.expect(sequence_events.events[1].document_start.explicit);
    try std.testing.expect(sequence_events.events[1].document_start.content_same_line);
    try std.testing.expect(sequence_events.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, sequence_events.events[2].sequence_start.style);
    try std.testing.expect(sequence_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence_events.events[3].scalar.value);
    try std.testing.expect(sequence_events.events[4] == .sequence_end);

    var mapping_tokens = try scanner.scan(std.testing.allocator, "--- {foo: bar}\n");
    defer mapping_tokens.deinit();
    var mapping_events = try parseTokens(std.testing.allocator, mapping_tokens.tokens);
    defer mapping_events.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_events.events.len);
    try std.testing.expect(mapping_events.events[1] == .document_start);
    try std.testing.expect(mapping_events.events[1].document_start.explicit);
    try std.testing.expect(mapping_events.events[1].document_start.content_same_line);
    try std.testing.expect(mapping_events.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.flow, mapping_events.events[2].mapping_start.style);
    try std.testing.expect(mapping_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("foo", mapping_events.events[3].scalar.value);
    try std.testing.expect(mapping_events.events[4] == .scalar);
    try std.testing.expectEqualStrings("bar", mapping_events.events[4].scalar.value);
    try std.testing.expect(mapping_events.events[5] == .mapping_end);
}

test "parseTokens parses same-line document start block collections" {
    var sequence_tokens = try scanner.scan(std.testing.allocator, "--- - one\n");
    defer sequence_tokens.deinit();
    var sequence_events = try parseTokens(std.testing.allocator, sequence_tokens.tokens);
    defer sequence_events.deinit();

    try std.testing.expectEqual(@as(usize, 7), sequence_events.events.len);
    try std.testing.expect(sequence_events.events[1] == .document_start);
    try std.testing.expect(sequence_events.events[1].document_start.explicit);
    try std.testing.expect(sequence_events.events[1].document_start.content_same_line);
    try std.testing.expect(sequence_events.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, sequence_events.events[2].sequence_start.style);
    try std.testing.expect(sequence_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("one", sequence_events.events[3].scalar.value);
    try std.testing.expect(sequence_events.events[4] == .sequence_end);

    var mapping_tokens = try scanner.scan(std.testing.allocator, "--- key: value\n");
    defer mapping_tokens.deinit();
    var mapping_events = try parseTokens(std.testing.allocator, mapping_tokens.tokens);
    defer mapping_events.deinit();

    try std.testing.expectEqual(@as(usize, 8), mapping_events.events.len);
    try std.testing.expect(mapping_events.events[1] == .document_start);
    try std.testing.expect(mapping_events.events[1].document_start.explicit);
    try std.testing.expect(mapping_events.events[1].document_start.content_same_line);
    try std.testing.expect(mapping_events.events[2] == .mapping_start);
    try std.testing.expectEqual(types.CollectionStyle.block, mapping_events.events[2].mapping_start.style);
    try std.testing.expect(mapping_events.events[3] == .scalar);
    try std.testing.expectEqualStrings("key", mapping_events.events[3].scalar.value);
    try std.testing.expect(mapping_events.events[4] == .scalar);
    try std.testing.expectEqualStrings("value", mapping_events.events[4].scalar.value);
    try std.testing.expect(mapping_events.events[5] == .mapping_end);
}

test "parseTokens rejects same-line document start block collection continuations" {
    var sequence_tokens = try scanner.scan(std.testing.allocator,
        \\--- - one
        \\    - two
        \\
    );
    defer sequence_tokens.deinit();
    if (parseTokens(std.testing.allocator, sequence_tokens.tokens)) |stream| {
        var parsed = stream;
        parsed.deinit();
        return error.TestExpectedError;
    } else |_| {}

    var mapping_tokens = try scanner.scan(std.testing.allocator,
        \\--- one: 1
        \\    two: 2
        \\
    );
    defer mapping_tokens.deinit();
    if (parseTokens(std.testing.allocator, mapping_tokens.tokens)) |stream| {
        var parsed = stream;
        parsed.deinit();
        return error.TestExpectedError;
    } else |_| {}
}

test "parseTokens parses space-separated compact nested sequence indicators" {
    var token_stream = try scanner.scan(std.testing.allocator, "- -\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 9), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[2].sequence_start.style);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expectEqual(types.CollectionStyle.block, event_stream.events[3].sequence_start.style);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
}

test "parseTokens parses compact nested sequence scalar entries" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\- - nested
        \\  - second
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 10), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .scalar);
    try std.testing.expectEqualStrings("second", event_stream.events[5].scalar.value);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .sequence_end);
}

test "parseTokens parses compact nested sequences across documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\- - nested
        \\---
        \\? key
        \\: - value
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 17), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[2] == .sequence_start);
    try std.testing.expect(event_stream.events[3] == .sequence_start);
    try std.testing.expect(event_stream.events[4] == .scalar);
    try std.testing.expectEqualStrings("nested", event_stream.events[4].scalar.value);
    try std.testing.expect(event_stream.events[5] == .sequence_end);
    try std.testing.expect(event_stream.events[6] == .sequence_end);
    try std.testing.expect(event_stream.events[7] == .document_end);
    try std.testing.expect(event_stream.events[8] == .document_start);
    try std.testing.expect(event_stream.events[9] == .mapping_start);
    try std.testing.expect(event_stream.events[10] == .scalar);
    try std.testing.expectEqualStrings("key", event_stream.events[10].scalar.value);
    try std.testing.expect(event_stream.events[11] == .sequence_start);
    try std.testing.expect(event_stream.events[12] == .scalar);
    try std.testing.expectEqualStrings("value", event_stream.events[12].scalar.value);
    try std.testing.expect(event_stream.events[13] == .sequence_end);
    try std.testing.expect(event_stream.events[14] == .mapping_end);
}

test "parseTokens parses same-line document start scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "--- plain\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqualStrings("plain", event_stream.events[2].scalar.value);
}

test "parseTokens parses same-line document start block scalars" {
    var token_stream = try scanner.scan(std.testing.allocator, "--- |1-\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("", event_stream.events[2].scalar.value);
}

test "parseTokens parses same-line document start block scalars before document end" {
    const input = "--- |-\n" ++
        " ab\n" ++
        " \n" ++
        " \n" ++
        "...\n";
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[1] == .document_start);
    try std.testing.expect(event_stream.events[1].document_start.explicit);
    try std.testing.expect(event_stream.events[1].document_start.content_same_line);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.literal, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("ab", event_stream.events[2].scalar.value);
    try std.testing.expect(event_stream.events[3] == .document_end);
    try std.testing.expect(event_stream.events[3].document_end.explicit);
}

test "parseTokens parses single quoted scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator, "'quoted'\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("quoted", event_stream.events[2].scalar.value);
}

test "parseTokens decodes doubled quotes in single quoted scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator, "'it''s'\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("it's", event_stream.events[2].scalar.value);
}

test "parseTokens folds line breaks in multiline single quoted scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\' first
        \\
        \\ second
        \\  third '
        \\
    );
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.single_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings(" first\nsecond third ", event_stream.events[2].scalar.value);
}

test "parseTokens rejects multiline quoted implicit block mapping keys" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\"a\nb": 1
        \\"c
        \\ d": 1
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}

test "parseTokens parses double quoted scalar documents" {
    var token_stream = try scanner.scan(std.testing.allocator, "\"quoted\"\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("quoted", event_stream.events[2].scalar.value);
}

test "parseTokens decodes double quoted scalar escapes" {
    var token_stream = try scanner.scan(std.testing.allocator, "\"tab\\t omega \\u03A9 smile \\U0001F642\"\n");
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("tab\t omega \xce\xa9 smile \xf0\x9f\x99\x82", event_stream.events[2].scalar.value);
}

test "parseTokens folds and escapes multiline double quoted scalar documents" {
    const input = "\"folded \n" ++
        "to a space,\n" ++
        "\n" ++
        "to a line feed, or \t\\\n" ++
        " \\ \tnon-content\"\n";
    var token_stream = try scanner.scan(std.testing.allocator, input);
    defer token_stream.deinit();

    var event_stream = try parseTokens(std.testing.allocator, token_stream.tokens);
    defer event_stream.deinit();

    try std.testing.expectEqual(@as(usize, 5), event_stream.events.len);
    try std.testing.expect(event_stream.events[2] == .scalar);
    try std.testing.expectEqual(types.ScalarStyle.double_quoted, event_stream.events[2].scalar.style);
    try std.testing.expectEqualStrings("folded to a space,\nto a line feed, or \t \tnon-content", event_stream.events[2].scalar.value);
}

test "parseTokens rejects forbidden document marker lines inside quoted scalars" {
    var token_stream = try scanner.scan(std.testing.allocator,
        \\---
        \\"
        \\---
        \\"
        \\
    );
    defer token_stream.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, parseTokens(std.testing.allocator, token_stream.tokens));
}
