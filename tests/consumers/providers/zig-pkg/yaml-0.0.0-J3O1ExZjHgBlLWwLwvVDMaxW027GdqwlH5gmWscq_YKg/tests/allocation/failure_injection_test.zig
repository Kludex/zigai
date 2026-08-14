//! Purpose: Verify public owning APIs clean up after allocation failures.
//! Owns: Allocation-failure injection checks for parse, load, emit, and dump paths.
//! Does not own: Stress limits or conformance comparison.
//! Depends on: yaml public API and std.testing.
//! Tested by: zig build test-allocation.

const std = @import("std");
const yaml = @import("yaml");
const allocator = std.testing.allocator;
test "allocator failures clean up parseEvents allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkParseEventsAllocationFailure, .{});
}

test "allocator failures clean up loadStream allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkLoadStreamAllocationFailure, .{});
}

test "allocator failures clean up load allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkLoadAllocationFailure, .{});
}

test "allocator failures clean up typed load allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkTypedLoadAllocationFailure, .{});
}

test "allocator failures clean up typed stream allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkTypedStreamAllocationFailure, .{});
}

test "allocator failures clean up node conversion allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkTypedConvertNodeAllocationFailure, .{});
}

test "allocator failures clean up emitEvents allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkEmitEventsAllocationFailure, .{});
}

test "allocator failures clean up emitValue allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkEmitValueAllocationFailure, .{});
}

test "allocator failures clean up dump allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkDumpAllocationFailure, .{});
}

test "allocator failures clean up dumpStream allocations" {
    try std.testing.checkAllAllocationFailures(allocator, checkDumpStreamAllocationFailure, .{});
}

fn checkParseEventsAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const inputs = [_][]const u8{
        \\root:
        \\  - one
        \\  - two
        \\
        ,
        \\---
        \\? [flow, key]
        \\:
        \\  literal: |
        \\    text
        \\  folded: >
        \\    more
        \\
        ,
        \\plain: first line
        \\  second line
        \\  third line
        \\
        ,
        \\%TAG !e! tag:example.com,2000:
        \\---
        \\&root !e!map
        \\  ? !e!key "quoted\nkey"
        \\  : [*root, {plain: value}]
        \\
        ,
        \\&root [plain, key: &node !<tag:example.com,2000:seq> [*node, {inner: value}], ? explicit : , : empty]
        \\
    };

    for (inputs) |input| {
        var events = try yaml.parseEvents(failing_allocator, input);
        defer events.deinit();
    }
}

fn checkLoadStreamAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const inputs = [_][]const u8{
        \\---
        \\root:
        \\  - one
        \\  - two
        \\---
        \\true
        \\
        ,
        \\---
        \\nulls: [null, ~, ""]
        \\bools: [true, false]
        \\numbers: [0, -12, 3.25, .inf]
        \\
        ,
        \\---
        \\!<tag:example.com,2000:map> &map
        \\name: &name !<tag:example.com,2000:name> "decoded\\nvalue"
        \\
        ,
        \\---
        \\anchor: &value {nested: [one, two]}
        \\alias: *value
        \\
    };

    for (inputs) |input| {
        var stream = try yaml.loadStream(failing_allocator, input);
        defer stream.deinit();
    }
}

fn checkLoadAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const inputs = [_][]const u8{
        "root:\n  nested: [one, two]\n",
        "---\n&root {alias: *root, tagged: !!str true}\n",
        "k00: v\nk01: v\nk02: v\nk03: v\nk04: v\nk05: v\nk06: v\nk07: v\nk08: v\nk09: v\nk10: v\nk11: v\nk12: v\nk13: v\nk14: v\nk15: v\nk16: v\nk17: v\nk18: v\nk19: v\nk20: v\nk21: v\nk22: v\nk23: v\nk24: v\nk25: v\nk26: v\nk27: v\nk28: v\nk29: v\nk30: v\nk31: v\nk32: v\n",
        "[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]\n",
    };

    for (inputs) |input| {
        var document = try yaml.load(failing_allocator, input);
        defer document.deinit();
    }
}

fn checkTypedLoadAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const Nested = struct { label: []const u8 };
    const Config = struct {
        name: []const u8,
        nested: []const Nested,
    };

    var document = try yaml.loadTyped(Config, failing_allocator,
        \\name: demo
        \\nested:
        \\  - label: one
        \\  - label: two
        \\
    );
    defer document.deinit();
}

fn checkTypedStreamAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const Config = struct {
        name: []const u8,
        ports: []const u16,
    };

    var stream = try yaml.loadStreamTyped(Config, failing_allocator,
        \\---
        \\name: first
        \\ports: [80, 443]
        \\---
        \\name: second
        \\ports: [8080]
        \\
    );
    defer stream.deinit();
}

fn checkTypedConvertNodeAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const Config = struct {
        name: []const u8,
        tags: []const []const u8,
    };

    var loaded = try yaml.load(allocator,
        \\name: demo
        \\tags: [one, two]
        \\
    );
    defer loaded.deinit();

    var typed = try yaml.convertNode(Config, failing_allocator, loaded.root, .{});
    defer typed.deinit();
}

fn checkEmitEventsAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const block_events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "root" } },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    const flow_events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .sequence_start = .{ .style = .flow, .anchor = "items", .tag = "tag:example.com,2000:items" } },
        .{ .scalar = .{ .value = "" } },
        .{ .mapping_start = .{ .style = .flow } },
        .{ .scalar = .{ .value = "a,b" } },
        .{ .scalar = .{ .value = "line\nnext", .style = .single_quoted } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };
    const block_scalar_events = [_]yaml.Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .block } },
        .{ .scalar = .{ .value = "literal" } },
        .{ .scalar = .{ .value = "text\n", .style = .literal } },
        .{ .scalar = .{ .value = "folded" } },
        .{ .scalar = .{ .value = "more\ntext\n", .style = .folded } },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    const event_sets = [_][]const yaml.Event{
        &block_events,
        &flow_events,
        &block_scalar_events,
    };

    for (event_sets) |events| {
        const emitted = try yaml.emitEvents(failing_allocator, events);
        defer failing_allocator.free(emitted);
    }
}

fn checkEmitValueAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const key: yaml.Node = .{ .scalar = .{ .value = "key" } };
    const first: yaml.Node = .{ .scalar = .{ .value = "one" } };
    const second: yaml.Node = .{ .scalar = .{ .value = "two" } };
    const items = [_]*const yaml.Node{ &first, &second };
    const sequence: yaml.Node = .{ .sequence = .{ .items = &items } };
    const pair = yaml.MappingPair{ .key = &key, .value = &sequence };
    const pairs = [_]yaml.MappingPair{pair};
    const mapping: yaml.Node = .{ .mapping = .{ .pairs = &pairs } };

    const emitted = try yaml.emitValue(failing_allocator, &mapping);
    defer failing_allocator.free(emitted);
}

fn checkDumpAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const loaded_inputs = [_][]const u8{
        "root:\n  - one\n  - two\n",
        "anchor: &value {nested: true}\nalias: *value\n",
    };

    for (loaded_inputs) |input| {
        var document = try yaml.load(failing_allocator, input);
        defer document.deinit();

        const dumped = try yaml.dump(failing_allocator, document.root);
        defer failing_allocator.free(dumped);
    }

    const float_node: yaml.Node = .{ .float_value = .{ .value = 12.0 } };
    const dumped_float = try yaml.dump(failing_allocator, &float_node);
    defer failing_allocator.free(dumped_float);
}

fn checkDumpStreamAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    const first_scalar: yaml.Node = .{ .scalar = .{ .value = "one" } };
    const second_scalar: yaml.Node = .{ .scalar = .{ .value = "two" } };
    const tagged_scalar: yaml.Node = .{ .scalar = .{
        .value = "tagged",
        .tag = "tag:example.com,2000:scalar",
    } };
    const literal_scalar: yaml.Node = .{ .scalar = .{
        .value = "literal\n",
        .style = .literal,
    } };
    const items = [_]*const yaml.Node{ &first_scalar, &second_scalar };
    const sequence: yaml.Node = .{ .sequence = .{ .items = &items } };
    const pair = yaml.MappingPair{ .key = &tagged_scalar, .value = &literal_scalar };
    const pairs = [_]yaml.MappingPair{pair};
    const mapping: yaml.Node = .{ .mapping = .{ .pairs = &pairs } };
    const documents = [_]*const yaml.Node{ &sequence, &mapping };

    const dumped = try yaml.dumpStream(failing_allocator, &documents);
    defer failing_allocator.free(dumped);
}
