//! Purpose: Run yaml-test-suite directly through the scanner/token parser layer.
//! Owns: Direct parser conformance assertions for parser events and expected errors.
//! Does not own: Suite discovery or event rendering helpers.
//! Depends on: yaml_event_parser and focused conformance support modules.
//! Tested by: zig build test-direct-conformance.

const std = @import("std");
const event_parser = @import("yaml_event_parser");
const direct_conformance_options = @import("direct_conformance_options");
const event_compare = @import("event_compare.zig");
const suite_cases = @import("suite_cases.zig");

const suite_root = direct_conformance_options.yaml_test_suite_dir;
const using_pinned_yaml_test_suite = direct_conformance_options.using_pinned_yaml_test_suite;

test "yaml-test-suite direct scanner parser events and expected errors" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    try suite_cases.expectConfiguredParserCaseCount(using_pinned_yaml_test_suite, 402, cases.items.len);

    for (cases.items) |case| {
        const input = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.yaml");
        defer std.testing.allocator.free(input);

        if (case.has_error) {
            if (event_parser.scanner.scan(std.testing.allocator, input)) |tokens| {
                var token_stream = tokens;
                defer token_stream.deinit();

                if (event_parser.parseTokens(std.testing.allocator, token_stream.tokens)) |stream| {
                    var parsed = stream;
                    parsed.deinit();
                    std.debug.print("case {s} unexpectedly parsed through direct scanner/parser\n", .{case.id});
                    return error.TestExpectedError;
                } else |_| {}
            } else |err| switch (err) {
                error.InvalidSyntax => {},
                error.OutOfMemory => return err,
            }
            continue;
        }

        const expected_events = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "test.event");
        defer std.testing.allocator.free(expected_events);

        var token_stream = event_parser.scanner.scan(std.testing.allocator, input) catch |err| {
            std.debug.print("case {s} failed to scan directly: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer token_stream.deinit();

        var stream = event_parser.parseTokens(std.testing.allocator, token_stream.tokens) catch |err| {
            std.debug.print("case {s} failed to parse directly: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer stream.deinit();

        const actual = try event_compare.render(std.testing.allocator, stream.events);
        defer std.testing.allocator.free(actual);

        std.testing.expectEqualStrings(expected_events, actual) catch |err| {
            std.debug.print("case {s} produced unexpected direct scanner/parser events\n", .{case.id});
            return err;
        };
    }
}
