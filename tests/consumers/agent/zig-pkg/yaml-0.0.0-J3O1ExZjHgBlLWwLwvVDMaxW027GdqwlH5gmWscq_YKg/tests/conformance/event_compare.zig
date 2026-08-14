//! Purpose: Render parser events into yaml-test-suite `test.event` text.
//! Owns: Event text formatting used by public and direct parser conformance tests.
//! Does not own: Parser execution, suite discovery, or fixture reading.
//! Depends on: std only.
//! Tested by: tests/conformance/yaml_suite_runner.zig and tests/conformance/direct_conformance.zig.

const std = @import("std");

pub fn render(allocator: std.mem.Allocator, events: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (events) |event| {
        switch (event) {
            .stream_start => try out.appendSlice(allocator, "+STR\n"),
            .stream_end => try out.appendSlice(allocator, "-STR\n"),
            .document_start => |document| {
                if (document.explicit) {
                    try out.appendSlice(allocator, "+DOC ---\n");
                } else {
                    try out.appendSlice(allocator, "+DOC\n");
                }
            },
            .document_end => |document| {
                if (document.explicit) {
                    try out.appendSlice(allocator, "-DOC ...\n");
                } else {
                    try out.appendSlice(allocator, "-DOC\n");
                }
            },
            .sequence_start => |collection| {
                switch (collection.style) {
                    .block => try out.appendSlice(allocator, "+SEQ"),
                    .flow => try out.appendSlice(allocator, "+SEQ []"),
                }
                try appendEventAnchor(allocator, &out, collection.anchor);
                try appendEventTag(allocator, &out, collection.tag);
                try out.append(allocator, '\n');
            },
            .sequence_end => try out.appendSlice(allocator, "-SEQ\n"),
            .mapping_start => |collection| {
                switch (collection.style) {
                    .block => try out.appendSlice(allocator, "+MAP"),
                    .flow => try out.appendSlice(allocator, "+MAP {}"),
                }
                try appendEventAnchor(allocator, &out, collection.anchor);
                try appendEventTag(allocator, &out, collection.tag);
                try out.append(allocator, '\n');
            },
            .mapping_end => try out.appendSlice(allocator, "-MAP\n"),
            .scalar => |scalar| {
                try out.appendSlice(allocator, "=VAL ");
                if (scalar.anchor) |anchor| {
                    try out.append(allocator, '&');
                    try appendEventValue(allocator, &out, anchor);
                    try out.append(allocator, ' ');
                }
                if (scalar.tag) |tag| {
                    try out.append(allocator, '<');
                    try appendEventValue(allocator, &out, tag);
                    try out.appendSlice(allocator, "> ");
                }
                switch (scalar.style) {
                    .plain => try out.append(allocator, ':'),
                    .single_quoted => try out.append(allocator, '\''),
                    .double_quoted => try out.append(allocator, '"'),
                    .literal => try out.append(allocator, '|'),
                    .folded => try out.append(allocator, '>'),
                }
                try appendEventValue(allocator, &out, scalar.value);
                try out.append(allocator, '\n');
            },
            .alias => |alias| {
                try out.appendSlice(allocator, "=ALI *");
                try appendEventValue(allocator, &out, alias);
                try out.append(allocator, '\n');
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendEventAnchor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), anchor: ?[]const u8) !void {
    if (anchor) |value| {
        try out.append(allocator, ' ');
        try out.append(allocator, '&');
        try appendEventValue(allocator, out, value);
    }
}

fn appendEventTag(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: ?[]const u8) !void {
    if (tag) |value| {
        try out.append(allocator, ' ');
        try out.append(allocator, '<');
        try appendEventValue(allocator, out, value);
        try out.append(allocator, '>');
    }
}

fn appendEventValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            0x08 => try out.appendSlice(allocator, "\\b"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, byte),
        }
    }
}
