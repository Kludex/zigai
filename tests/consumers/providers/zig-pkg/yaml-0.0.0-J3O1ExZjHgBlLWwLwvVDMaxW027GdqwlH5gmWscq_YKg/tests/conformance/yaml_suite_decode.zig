//! Purpose: Decode yaml-test-suite visible character markers in generated fixtures.
//! Owns: Fixture marker detection and marker-to-byte expansion for conformance data files.
//! Does not own: Suite discovery, parser execution, or conformance comparisons.
//! Depends on: std only.
//! Tested by: In-file tests and tests/conformance/yaml_suite_runner.zig.

const std = @import("std");

const visible_space = "\xE2\x90\xA3";
const visible_tab_arrow = "\xC2\xBB";
const visible_tab_dash = "\xE2\x80\x94";
const visible_newline = "\xE2\x86\xB5";
const visible_no_final_newline = "\xE2\x88\x8E";
const visible_carriage_return = "\xE2\x86\x90";
const visible_bom = "\xE2\x87\x94";

pub fn shouldDecode(filename: []const u8) bool {
    return std.mem.eql(u8, filename, "in.yaml") or
        std.mem.eql(u8, filename, "out.yaml") or
        std.mem.eql(u8, filename, "emit.yaml") or
        std.mem.eql(u8, filename, "test.event");
}

pub fn containsEncodedCharacters(filename: []const u8, input: []const u8) bool {
    if (!shouldDecode(filename)) return false;

    var index: usize = 0;
    while (index < input.len) {
        if (startsWith(input[index..], visible_space) or
            startsWith(input[index..], visible_newline) or
            startsWith(input[index..], visible_no_final_newline) or
            startsWith(input[index..], visible_carriage_return) or
            startsWith(input[index..], visible_bom) or
            visibleTabMarkerLen(input[index..]) != null)
        {
            return true;
        }

        if (std.mem.eql(u8, filename, "test.event") and
            (startsWith(input[index..], "<SPC>") or startsWith(input[index..], "<TAB>")))
        {
            return true;
        }

        index += 1;
    }

    return false;
}

pub fn decodeCaseFile(allocator: std.mem.Allocator, filename: []const u8, input: []const u8) ![]u8 {
    if (!shouldDecode(filename)) return allocator.dupe(u8, input);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        if (startsWith(input[index..], visible_space)) {
            try out.append(allocator, ' ');
            index += visible_space.len;
            continue;
        }

        if (visibleTabMarkerLen(input[index..])) |marker_len| {
            try out.append(allocator, '\t');
            index += marker_len;
            continue;
        }

        if (startsWith(input[index..], visible_newline)) {
            try out.append(allocator, '\n');
            index += visible_newline.len;
            index = skipOnePhysicalLineBreak(input, index);
            continue;
        }

        if (startsWith(input[index..], visible_no_final_newline)) {
            index += visible_no_final_newline.len;
            if (onlyPhysicalLineBreaksRemain(input[index..])) break;
            continue;
        }

        if (startsWith(input[index..], visible_carriage_return)) {
            try out.append(allocator, '\r');
            index += visible_carriage_return.len;
            continue;
        }

        if (startsWith(input[index..], visible_bom)) {
            try out.appendSlice(allocator, "\xEF\xBB\xBF");
            index += visible_bom.len;
            continue;
        }

        if (std.mem.eql(u8, filename, "test.event") and startsWith(input[index..], "<SPC>")) {
            try out.append(allocator, ' ');
            index += "<SPC>".len;
            continue;
        }

        if (std.mem.eql(u8, filename, "test.event") and startsWith(input[index..], "<TAB>")) {
            try out.append(allocator, '\t');
            index += "<TAB>".len;
            continue;
        }

        try out.append(allocator, input[index]);
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn startsWith(input: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, input, prefix);
}

fn visibleTabMarkerLen(input: []const u8) ?usize {
    if (startsWith(input, visible_tab_arrow)) return visible_tab_arrow.len;

    var len: usize = 0;
    var dash_count: usize = 0;
    while (dash_count < 3 and startsWith(input[len..], visible_tab_dash)) : (dash_count += 1) {
        len += visible_tab_dash.len;
    }

    if (dash_count == 0) return null;
    if (!startsWith(input[len..], visible_tab_arrow)) return null;
    return len + visible_tab_arrow.len;
}

fn skipOnePhysicalLineBreak(input: []const u8, index: usize) usize {
    if (index >= input.len) return index;
    if (input[index] == '\r') {
        if (index + 1 < input.len and input[index + 1] == '\n') return index + 2;
        return index + 1;
    }
    if (input[index] == '\n') return index + 1;
    return index;
}

fn onlyPhysicalLineBreaksRemain(input: []const u8) bool {
    for (input) |byte| {
        if (byte != '\n' and byte != '\r') return false;
    }
    return true;
}

test "yaml-suite-decode: detects official YAML visible character markers" {
    try std.testing.expect(containsEncodedCharacters("in.yaml", "key:\xE2\x90\xA3value"));
    try std.testing.expect(containsEncodedCharacters("in.yaml", "before\xE2\x80\x94\xE2\x80\x94\xC2\xBBafter"));
    try std.testing.expect(containsEncodedCharacters("in.yaml", "line\xE2\x86\xB5\n"));
    try std.testing.expect(containsEncodedCharacters("in.yaml", "\xE2\x87\x94bom"));
    try std.testing.expect(containsEncodedCharacters("in.yaml", "no newline\xE2\x88\x8E\n"));
    try std.testing.expect(!containsEncodedCharacters("in.json", "key:\xE2\x90\xA3value"));
}

test "yaml-suite-decode: expands YAML visible character markers" {
    const input =
        "\xE2\x87\x94" ++
        "name:\xE2\x90\xA3value\n" ++
        "indent:\xE2\x80\x94\xC2\xBBtab\n" ++
        "line\xE2\x86\xB5\n" ++
        "carriage\xE2\x86\x90return\n" ++
        "no final newline\xE2\x88\x8E\n";

    const decoded = try decodeCaseFile(std.testing.allocator, "in.yaml", input);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBF" ++
            "name: value\n" ++
            "indent:\ttab\n" ++
            "line\n" ++
            "carriage\rreturn\n" ++
            "no final newline",
        decoded,
    );
}

test "yaml-suite-decode: expands test.event visible space and tab markers" {
    const decoded = try decodeCaseFile(std.testing.allocator, "test.event", "=VAL :a<SPC>b<TAB>c\n");
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("=VAL :a b\tc\n", decoded);
}
