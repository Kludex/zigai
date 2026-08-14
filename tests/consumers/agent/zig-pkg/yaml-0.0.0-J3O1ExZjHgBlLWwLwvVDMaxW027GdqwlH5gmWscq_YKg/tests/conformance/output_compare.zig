//! Purpose: Produce and compare YAML output for conformance emitter checks.
//! Owns: Canonical event emission and loaded-value dump helpers.
//! Does not own: Suite discovery, parser event rendering, or JSON comparison.
//! Depends on: yaml public parse/load/emitter APIs.
//! Tested by: tests/conformance/yaml_suite_runner.zig.

const std = @import("std");
const yaml = @import("yaml");

pub const Case = struct {
    id: []const u8,
    name: []const u8,
};

pub fn matchesCanonicalEventsOutput(
    allocator: std.mem.Allocator,
    case: Case,
    input: []const u8,
    expected_yaml: []const u8,
) !bool {
    const actual = actualCanonicalEventsOutput(allocator, case, input) catch |err| switch (err) {
        error.InvalidSyntax, error.Unsupported => return false,
        error.OutOfMemory => return err,
    };
    defer allocator.free(actual);

    return std.mem.eql(u8, expected_yaml, actual);
}

pub fn actualCanonicalEventsOutput(allocator: std.mem.Allocator, case: Case, input: []const u8) ![]u8 {
    var stream = yaml.parseEvents(allocator, input) catch |err| {
        std.debug.print("case {s} ({s}) failed to parse before canonical emit: {s}\n", .{ case.id, case.name, @errorName(err) });
        return err;
    };
    defer stream.deinit();

    return yaml.emitEventsWithOptions(allocator, stream.events, .{
        .omit_redundant_document_start = true,
        .preserve_collection_style = false,
    });
}

pub fn actualCanonicalLoadedDumpOutput(allocator: std.mem.Allocator, case: Case, input: []const u8) ![]u8 {
    var stream = yaml.loadStream(allocator, input) catch |err| {
        std.debug.print("case {s} ({s}) failed to load before canonical dump: {s}\n", .{ case.id, case.name, @errorName(err) });
        return err;
    };
    defer stream.deinit();

    return yaml.dumpStreamWithOptions(allocator, stream.documents, .{
        .preserve_top_level_flow_mapping_style = false,
        .preserve_collection_style = false,
        .omit_redundant_document_start = true,
    });
}
