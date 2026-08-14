//! Purpose: Apply loader preflight limits to parser event streams.
//! Owns: Event-count checks that happen before composition and construction.
//! Does not own: Parser limits, compose-time alias expansion limits, value construction, or diagnostics formatting.
//! Depends on: common/diagnostic.zig, loader/failure.zig, parser/event.zig.
//! Tested by: tests/unit/loader/loader_test.zig and in-file tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const event = @import("../parser/event.zig");
const failure = @import("failure.zig");

const Error = diagnostic.Error;
const Event = event.Event;
const LoadFailure = failure.LoadFailure;
const ParseError = diagnostic.ParseError;

/// Loader preflight limits that can be checked directly from parser events.
pub const Options = struct {
    max_alias_count: ?usize = null,
    max_document_count: ?usize = null,
};

pub const EventSummary = struct {
    document_count: usize = 0,
    alias_count: usize = 0,
    has_aliases: bool = false,
    value_node_count: usize = 0,
};

pub fn summarizeEvents(events: []const Event) EventSummary {
    var summary: EventSummary = .{};
    for (events) |yaml_event| {
        switch (yaml_event) {
            .document_start => summary.document_count += 1,
            .alias => {
                summary.alias_count += 1;
                summary.has_aliases = true;
            },
            .scalar, .sequence_start, .mapping_start => summary.value_node_count += 1,
            else => {},
        }
    }
    return summary;
}

/// Checks event-stream limits before the composer allocates representation nodes.
pub fn checkEvents(events: []const Event, options: Options, load_failure: ?*LoadFailure) Error!void {
    return checkSummary(summarizeEvents(events), options, load_failure);
}

pub fn checkSummary(summary: EventSummary, options: Options, load_failure: ?*LoadFailure) Error!void {
    if (options.max_document_count) |limit| {
        if (summary.document_count > limit) {
            recordFailure(load_failure, .document_count_limit);
            return ParseError.Unsupported;
        }
    }

    if (options.max_alias_count) |limit| {
        if (summary.alias_count > limit) {
            recordFailure(load_failure, .alias_count_limit);
            return ParseError.Unsupported;
        }
    }
}

fn recordFailure(load_failure: ?*LoadFailure, failure_value: LoadFailure) void {
    if (load_failure) |target| {
        if (target.* == .unknown) target.* = failure_value;
    }
}

test "loader limit: rejects streams over document count limit" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "two" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_document_count = 1 }, &load_failure));
    try std.testing.expectEqual(LoadFailure.document_count_limit, load_failure);
}

test "loader limit: rejects streams over alias count limit" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_alias_count = 0 }, &load_failure));
    try std.testing.expectEqual(LoadFailure.alias_count_limit, load_failure);
}

test "loader limit: accepts counts exactly at configured limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try checkEvents(&events, .{
        .max_document_count = 1,
        .max_alias_count = 1,
    }, &load_failure);
    try std.testing.expectEqual(LoadFailure.unknown, load_failure);
}

test "loader limit: summarizes event counts for loader preflight" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "self" } },
        .{ .alias = "root" },
        .mapping_end,
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "two" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    const summary = summarizeEvents(&events);
    try std.testing.expectEqual(@as(usize, 2), summary.document_count);
    try std.testing.expectEqual(@as(usize, 1), summary.alias_count);
    try std.testing.expect(summary.has_aliases);
    try std.testing.expectEqual(@as(usize, 3), summary.value_node_count);

    var load_failure: LoadFailure = .unknown;
    try std.testing.expectError(ParseError.Unsupported, checkSummary(summary, .{
        .max_document_count = 1,
        .max_alias_count = 0,
    }, &load_failure));
    try std.testing.expectEqual(LoadFailure.document_count_limit, load_failure);
}

test "loader limit: can reject without recording failure details" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_document_count = 0 }, null));
    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_alias_count = 0 }, null));
}
