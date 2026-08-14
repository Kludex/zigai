//! Purpose: Public event parsing API.
//! Owns: Input limits, scanner invocation, and scanner/token parser execution.
//! Does not own: Scanner tokenization, token parser internals, loading, or emitting.
//! Depends on: scanner/scanner.zig, parser/api.zig, parser/event.zig, api/options.zig, api/diagnostics.zig, api/diagnostic_policy.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig.

const std = @import("std");
const diagnostic_policy = @import("diagnostic_policy.zig");
const diagnostics = @import("diagnostics.zig");
const event_types = @import("../parser/event.zig");
const common_limit = @import("../common/limit.zig");
const options_api = @import("options.zig");
const token_parser = @import("../parser/api.zig");
const scanner = @import("../scanner/scanner.zig");

const Event = event_types.Event;
const EventStats = token_parser.EventStats;
const Error = diagnostics.Error;
const EventStream = event_types.EventStream;
const ParseError = diagnostics.ParseError;
const ParseOptions = options_api.ParseOptions;

const ParseResult = struct {
    stream: EventStream,
    stats: ?EventStats = null,
};

/// Owning event-stream parser facade.
///
/// `Parser` parses the input during `init`, owns the resulting event stream,
/// and yields events one at a time from `next`. String slices in returned
/// events remain valid until `deinit`.
pub const Parser = struct {
    stream: EventStream,
    index: usize = 0,

    /// Parses `input` using `options` and returns an owning parser.
    pub fn init(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) Error!Parser {
        return .{
            .stream = try parseEventsWithOptions(allocator, input, options),
        };
    }

    /// Releases all event data owned by this parser.
    pub fn deinit(self: *Parser) void {
        self.stream.deinit();
        self.* = undefined;
    }

    /// Returns the next event, or null after the stream has been consumed.
    pub fn next(self: *Parser) Error!?Event {
        if (self.index >= self.stream.events.len) return null;
        const event = self.stream.events[self.index];
        self.index += 1;
        return event;
    }
};

/// Parses `input` into a YAML event stream. Returned slices are owned by the
/// returned `EventStream`; call `deinit` to release them.
pub fn parseEvents(allocator: std.mem.Allocator, input: []const u8) Error!EventStream {
    return parseEventsWithOptions(allocator, input, .{});
}

/// Parses `input` into a YAML event stream using the provided options. Returned
/// slices are owned by the returned `EventStream`; call `deinit` to release
/// them.
pub fn parseEventsWithOptions(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) Error!EventStream {
    if (options.max_input_bytes) |max_input_bytes| {
        if (input.len > max_input_bytes) {
            diagnostic_policy.setLimit(options.diagnostic, input, .{ .input_size = max_input_bytes });
            return ParseError.Unsupported;
        }
    }

    const result = parseEventsInternal(allocator, input, options) catch |err| {
        diagnostic_policy.setParseFailure(options.diagnostic, input, err);
        return err;
    };
    var stream = result.stream;

    if (options.max_event_count) |max_event_count| {
        const event_count = if (result.stats) |stats| stats.event_count else stream.events.len;
        if (event_count > max_event_count) {
            stream.deinit();
            diagnostic_policy.setLimit(options.diagnostic, input, .event_count);
            return ParseError.Unsupported;
        }
    }

    if (options.max_scalar_bytes) |max_scalar_bytes| {
        const scalar_too_long = if (result.stats) |stats| stats.max_scalar_bytes > max_scalar_bytes else hasScalarLongerThan(stream.events, max_scalar_bytes);
        if (scalar_too_long) {
            stream.deinit();
            diagnostic_policy.setLimit(options.diagnostic, input, .scalar_size);
            return ParseError.Unsupported;
        }
    }

    const max_nesting_depth = options.max_nesting_depth orelse common_limit.default_parse_collection_depth;
    const nesting_too_deep = if (result.stats) |stats|
        stats.malformed_nesting or stats.max_nesting_depth > max_nesting_depth
    else
        hasNestingDeeperThan(stream.events, max_nesting_depth);
    if (nesting_too_deep) {
        stream.deinit();
        diagnostic_policy.setLimit(options.diagnostic, input, .nesting_depth);
        return ParseError.Unsupported;
    }

    diagnostic_policy.clear(options.diagnostic);
    return stream;
}

fn hasScalarLongerThan(events: []const Event, max_scalar_bytes: usize) bool {
    for (events) |event| {
        switch (event) {
            .scalar => |scalar| if (scalar.value.len > max_scalar_bytes) return true,
            else => {},
        }
    }
    return false;
}

fn hasNestingDeeperThan(events: []const Event, max_nesting_depth: usize) bool {
    var depth: usize = 0;

    for (events) |event| {
        switch (event) {
            .sequence_start, .mapping_start => {
                if (depth >= max_nesting_depth) return true;
                depth += 1;
            },
            .sequence_end, .mapping_end => {
                if (depth == 0) return true;
                depth -= 1;
            },
            else => {},
        }
    }

    return false;
}

fn parseEventsInternal(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) Error!ParseResult {
    var token_stream = try scanner.scan(allocator, input);
    defer token_stream.deinit();

    if (options.max_token_count) |max_token_count| {
        if (token_stream.tokens.len > max_token_count) {
            diagnostic_policy.setLimit(options.diagnostic, input, .token_count);
            return ParseError.Unsupported;
        }
    }

    const parsed = try token_parser.parseTokensWithStats(allocator, token_stream.tokens);
    return .{ .stream = parsed.stream, .stats = parsed.stats };
}

test "parse api: scalar limit helper detects only oversized scalar events" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "abc" } },
        .{ .sequence_start = .{ .style = .block } },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expect(!hasScalarLongerThan(&events, 3));
    try std.testing.expect(hasScalarLongerThan(&events, 2));
}

test "parse api: nesting helper detects malformed and excessive event depth" {
    const balanced = [_]Event{
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .flow } },
        .mapping_end,
        .sequence_end,
    };
    const starts_too_deep = [_]Event{
        .{ .sequence_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .flow } },
        .sequence_end,
        .sequence_end,
    };
    const closes_without_start = [_]Event{.mapping_end};

    try std.testing.expect(!hasNestingDeeperThan(&balanced, 2));
    try std.testing.expect(hasNestingDeeperThan(&starts_too_deep, 1));
    try std.testing.expect(hasNestingDeeperThan(&closes_without_start, 1));
}
