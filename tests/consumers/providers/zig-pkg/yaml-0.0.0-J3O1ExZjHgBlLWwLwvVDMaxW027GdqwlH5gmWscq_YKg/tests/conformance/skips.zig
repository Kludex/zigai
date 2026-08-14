//! Purpose: Validate documented yaml-test-suite skip metadata.
//! Owns: The explicit conformance skip list and metadata validation helpers.
//! Does not own: Suite discovery, parser behavior, or comparison logic.
//! Depends on: suite_cases.zig and std.
//! Tested by: tests/conformance/yaml_suite_runner.zig.

const std = @import("std");
const suite_cases = @import("suite_cases.zig");

pub const Skip = struct {
    id: []const u8,
    reason: []const u8,
    feature_area: []const u8,
    tracking: []const u8,
    added: []const u8,
};

pub const entries = [_]Skip{};

pub fn expectValid(cases: []const suite_cases.DiscoveredCase) !void {
    for (entries, 0..) |skip, skip_index| {
        try expectNonEmpty("id", skip.id);
        try expectNonEmpty("reason", skip.reason);
        try expectNonEmpty("feature_area", skip.feature_area);
        try expectTracking(skip.tracking);
        try expectDate(skip.added);

        if (!caseExists(cases, skip.id)) {
            std.debug.print("skip references unknown yaml-test-suite case: {s}\n", .{skip.id});
            return error.UnknownSkippedCase;
        }

        for (entries[0..skip_index]) |previous| {
            if (std.mem.eql(u8, previous.id, skip.id)) {
                std.debug.print("duplicate yaml-test-suite skip: {s}\n", .{skip.id});
                return error.DuplicateSkippedCase;
            }
        }
    }
}

pub fn expectNoneForPinnedSuite(using_pinned_yaml_test_suite: bool) !void {
    if (!using_pinned_yaml_test_suite) return;
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

fn caseExists(cases: []const suite_cases.DiscoveredCase, id: []const u8) bool {
    for (cases) |case| {
        if (std.mem.eql(u8, case.id, id)) return true;
    }
    return false;
}

fn expectNonEmpty(field: []const u8, value: []const u8) !void {
    if (value.len != 0) return;
    std.debug.print("yaml-test-suite skip is missing required field: {s}\n", .{field});
    return error.MissingSkipMetadata;
}

fn expectTracking(value: []const u8) !void {
    try expectNonEmpty("tracking", value);
    if (std.mem.startsWith(u8, value, "TODO(") or
        std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "http://"))
    {
        return;
    }

    return error.InvalidSkipTracking;
}

fn expectDate(value: []const u8) !void {
    if (value.len == 10 and
        isDigit(value[0]) and
        isDigit(value[1]) and
        isDigit(value[2]) and
        isDigit(value[3]) and
        value[4] == '-' and
        isDigit(value[5]) and
        isDigit(value[6]) and
        value[7] == '-' and
        isDigit(value[8]) and
        isDigit(value[9]))
    {
        return;
    }

    std.debug.print("yaml-test-suite skip has invalid added date: {s}\n", .{value});
    return error.InvalidSkipDate;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

test "skips: tracking metadata must be an issue link or TODO" {
    try expectTracking("TODO(parser-directives)");
    try expectTracking("https://github.com/example/yaml/issues/1");
    try std.testing.expectError(error.InvalidSkipTracking, expectTracking("parser-directives"));
}
