//! Purpose: Run public API conformance against the pinned yaml-test-suite data.
//! Owns: Public parser, loader, emitter, and canonical-output conformance tests.
//! Does not own: Suite discovery or comparison helper implementations.
//! Depends on: yaml public API and focused conformance support modules.
//! Tested by: zig build test-conformance.

const std = @import("std");
const yaml = @import("yaml");
const conformance_options = @import("conformance_options");
const event_compare = @import("event_compare.zig");
const json_compare = @import("json_compare.zig");
const output_compare = @import("output_compare.zig");
const skips = @import("skips.zig");
const suite_cases = @import("suite_cases.zig");

const suite_root = conformance_options.yaml_test_suite_dir;
const using_pinned_yaml_test_suite = conformance_options.using_pinned_yaml_test_suite;

test "yaml-test-suite discovery covers configured parser cases" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    try suite_cases.expectConfiguredParserCaseCount(using_pinned_yaml_test_suite, 402, cases.items.len);
}

test "yaml-test-suite skip list is explicitly documented" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    try skips.expectValid(cases.items);
    try skips.expectNoneForPinnedSuite(using_pinned_yaml_test_suite);
}

test "yaml-test-suite discovered parser events and expected errors" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    for (cases.items) |case| {
        const input = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.yaml");
        defer std.testing.allocator.free(input);

        if (case.has_error) {
            if (yaml.parseEvents(std.testing.allocator, input)) |stream| {
                var parsed = stream;
                parsed.deinit();
                std.debug.print("case {s} unexpectedly parsed\n", .{case.id});
                return error.TestExpectedError;
            } else |_| {}
            continue;
        }

        const expected_events = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "test.event");
        defer std.testing.allocator.free(expected_events);

        var stream = yaml.parseEvents(std.testing.allocator, input) catch |err| {
            std.debug.print("case {s} failed to parse: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer stream.deinit();

        const actual = try event_compare.render(std.testing.allocator, stream.events);
        defer std.testing.allocator.free(actual);

        std.testing.expectEqualStrings(expected_events, actual) catch |err| {
            std.debug.print("case {s} failed\n", .{case.id});
            return err;
        };
    }
}

test "yaml-test-suite discovered canonical output" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    var suite_dir = try std.Io.Dir.cwd().openDir(std.testing.io, suite_root, .{
        .access_sub_paths = true,
    });
    defer suite_dir.close(std.testing.io);

    var checked: usize = 0;
    for (cases.items) |case| {
        if (case.has_error) continue;
        if (!(try suite_cases.fileExists(std.testing.allocator, suite_dir, case.id, "out.yaml"))) continue;

        const input = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.yaml");
        defer std.testing.allocator.free(input);
        const expected_yaml = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "out.yaml");
        defer std.testing.allocator.free(expected_yaml);

        const output_case: output_compare.Case = .{
            .id = case.id,
            .name = case.id,
        };

        const matches_events = output_compare.matchesCanonicalEventsOutput(
            std.testing.allocator,
            output_case,
            input,
            expected_yaml,
        ) catch |err| return err;
        if (matches_events) {
            checked += 1;
            continue;
        }

        const actual = output_compare.actualCanonicalLoadedDumpOutput(
            std.testing.allocator,
            output_case,
            input,
        ) catch |err| return err;
        defer std.testing.allocator.free(actual);

        std.testing.expectEqualStrings(expected_yaml, actual) catch |err| {
            std.debug.print("case {s} dumped unexpected discovered canonical YAML\n", .{case.id});
            return err;
        };

        checked += 1;
    }

    try suite_cases.expectPinnedSuiteCount(using_pinned_yaml_test_suite, 242, checked);
}

test "yaml-test-suite discovered emitter output" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    var suite_dir = try std.Io.Dir.cwd().openDir(std.testing.io, suite_root, .{
        .access_sub_paths = true,
    });
    defer suite_dir.close(std.testing.io);

    var checked: usize = 0;
    for (cases.items) |case| {
        if (case.has_error) continue;
        if (!(try suite_cases.fileExists(std.testing.allocator, suite_dir, case.id, "emit.yaml"))) continue;

        const input = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.yaml");
        defer std.testing.allocator.free(input);
        const expected_yaml = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "emit.yaml");
        defer std.testing.allocator.free(expected_yaml);

        var stream = yaml.parseEvents(std.testing.allocator, input) catch |err| {
            std.debug.print("case {s} failed to parse before emit: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer stream.deinit();

        const actual = try yaml.emitEvents(std.testing.allocator, stream.events);
        defer std.testing.allocator.free(actual);

        std.testing.expectEqualStrings(expected_yaml, actual) catch |err| {
            std.debug.print("case {s} emitted unexpected YAML\n", .{case.id});
            return err;
        };

        checked += 1;
    }

    try suite_cases.expectPinnedSuiteCount(using_pinned_yaml_test_suite, 53, checked);
}

test "yaml-test-suite discovered load matches json" {
    var cases = try suite_cases.discover(std.testing.allocator, suite_root);
    defer cases.deinit();

    var checked: usize = 0;
    var suite_dir = try std.Io.Dir.cwd().openDir(std.testing.io, suite_root, .{
        .access_sub_paths = true,
    });
    defer suite_dir.close(std.testing.io);

    for (cases.items) |case| {
        if (case.has_error) continue;
        if (!(try suite_cases.fileExists(std.testing.allocator, suite_dir, case.id, "in.json"))) continue;

        const input = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.yaml");
        defer std.testing.allocator.free(input);
        const expected_json = try suite_cases.readCaseFile(std.testing.allocator, suite_root, case.id, "in.json");
        defer std.testing.allocator.free(expected_json);

        var loaded = yaml.loadStream(std.testing.allocator, input) catch |err| {
            std.debug.print("case {s} failed to load: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer loaded.deinit();

        json_compare.expectLoadedStreamJsonEqual(std.testing.allocator, loaded.documents, expected_json) catch |err| {
            std.debug.print("case {s} loaded value did not match JSON\n", .{case.id});
            return err;
        };

        checked += 1;
    }

    try suite_cases.expectPinnedSuiteCount(using_pinned_yaml_test_suite, 279, checked);
}
