//! Purpose: Coordinate YAML event loading through compose and construct layers.
//! Owns: Loader-facing bridge from parser events to public value-model document roots.
//! Does not own: Event parsing, representation graph composition, schema construction details, duplicate-key comparison, or emission.
//! Depends on: common/diagnostic.zig, compose/composer.zig, loader/construct.zig, loader/limit.zig, loader/options.zig, parser/event.zig, schema/schema.zig, value/value.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig, and tests/stress/stress.zig.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const composer = @import("../compose/composer.zig");
const construct = @import("construct.zig");
pub const direct = @import("direct.zig");
const parser_event = @import("../parser/event.zig");
const failure = @import("failure.zig");
const limit = @import("limit.zig");
const options = @import("options.zig");
const schema = @import("../schema/schema.zig");
const value_model = @import("../value/value.zig");

const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const Error = diagnostic.Error;
const Event = parser_event.Event;
pub const Node = value_model.Node;
const ParseError = diagnostic.ParseError;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;

pub const LoadFailure = failure.LoadFailure;

pub fn loadStreamFromEvents(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
) Error![]const *const Node {
    return loadStreamFromEventsWithFailure(
        allocator,
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        max_document_count,
        null,
        true,
    );
}

pub fn loadStreamFromEventsWithFailure(
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
    load_failure: ?*LoadFailure,
    copy_event_strings: bool,
) Error![]const *const Node {
    const summary = limit.summarizeEvents(events);
    try limit.checkSummary(summary, .{
        .max_alias_count = max_alias_count,
        .max_document_count = max_document_count,
    }, load_failure);

    if (!summary.has_aliases) {
        return direct.loadStreamFromEventsWithStringPolicy(
            allocator,
            temporary_allocator,
            events,
            selected_schema,
            duplicate_key_behavior,
            unknown_tag_behavior,
            summary,
            load_failure,
            copy_event_strings,
        );
    }

    return loadStreamFromEventsComposedUnchecked(
        allocator,
        temporary_allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        load_failure,
        summary.has_aliases,
    );
}

/// Loads events through the representation graph composer and constructor path.
pub fn loadStreamFromEventsComposed(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    max_document_count: ?usize,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    const summary = limit.summarizeEvents(events);
    try limit.checkSummary(summary, .{
        .max_alias_count = max_alias_count,
        .max_document_count = max_document_count,
    }, load_failure);

    return loadStreamFromEventsComposedUnchecked(
        allocator,
        allocator,
        events,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        max_alias_count,
        max_alias_expansion,
        load_failure,
        summary.has_aliases,
    );
}

fn loadStreamFromEventsComposedUnchecked(
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_alias_count: ?usize,
    max_alias_expansion: ?usize,
    load_failure: ?*LoadFailure,
    has_alias_events: bool,
) Error![]const *const Node {
    var compose_arena = std.heap.ArenaAllocator.init(temporary_allocator);
    defer compose_arena.deinit();
    const graph_documents = composer.composeStream(compose_arena.allocator(), events, .{
        .max_alias_count = max_alias_count,
        .max_alias_expansion = max_alias_expansion,
        .max_document_count = null,
    }) catch |err| {
        switch (err) {
            ParseError.InvalidSyntax => recordFailure(load_failure, .invalid_graph),
            ParseError.Unsupported => if (max_alias_expansion != null) recordFailure(load_failure, .alias_expansion_limit),
            else => {},
        }
        return err;
    };
    return construct.constructStreamWithFailure(
        allocator,
        temporary_allocator,
        graph_documents,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        load_failure,
        has_alias_events,
    );
}

fn recordFailure(load_failure: ?*LoadFailure, failure_value: LoadFailure) void {
    if (load_failure) |target| {
        if (target.* == .unknown) target.* = failure_value;
    }
}

test {
    std.testing.refAllDecls(@This());
}
