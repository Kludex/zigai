//! Purpose: Run repeatable parser and loader microbenchmarks.
//! Owns: Benchmark fixtures, timing loop, metric formatting, and anti-optimization checksums.
//! Does not own: YAML parser, scanner, loader, or conformance assertions.
//! Depends on: Public yaml module and std.
//! Tested by: zig build bench and structure build-step checks.

const std = @import("std");
const yaml_internal = @import("yaml_internal");

const Io = std.Io;

const Fixture = struct {
    name: []const u8,
    input: []const u8,
    owned: bool = false,
    single_document: bool = true,
};

const ApiPath = enum {
    scanner,
    parser_events,
    load_default,
    load_failsafe_allow,
    load_stream_default,

    fn label(self: ApiPath) []const u8 {
        return switch (self) {
            .scanner => "scanner",
            .parser_events => "parser-events",
            .load_default => "load-default",
            .load_failsafe_allow => "load-failsafe-allow-duplicates",
            .load_stream_default => "load-stream-default",
        };
    }
};

const AllocationPath = enum {
    scanner,
    parser_events,
    composer_events,
    loader_events,
    load_default,
    load_failsafe_allow,
    load_stream_default,

    fn label(self: AllocationPath) []const u8 {
        return switch (self) {
            .scanner => "scanner",
            .parser_events => "parser-events",
            .composer_events => "composer-events",
            .loader_events => "loader-events",
            .load_default => "load-default",
            .load_failsafe_allow => "load-failsafe-allow-duplicates",
            .load_stream_default => "load-stream-default",
        };
    }
};

const AllocationMetrics = struct {
    allocations: usize,
    frees: usize,
    allocated_bytes: usize,
    freed_bytes: usize,
    retained_bytes: usize,
    peak_live_bytes: usize,
    checksum: u64,
};

const AllocationRun = struct {
    checksum: u64,
    retained_bytes: usize,
};

const CountMetrics = struct {
    token_count: usize,
    event_count: usize,
};

const conformance_subset =
    \\---
    \\foo:
    \\  bar: baz
    \\---
    \\- { one : two , three: four , }
    \\- {five: six,seven : eight}
    \\---
    \\'here''s to "quotes"'
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const fixtures = try buildFixtures(allocator);
    defer deinitFixtures(allocator, fixtures);

    try stdout.print("yaml benchmark\n", .{});
    try stdout.print("types scanner_token_size={} parser_event_size={} value_node_size={} scalar_node_size={} sequence_node_size={} mapping_pair_size={} mapping_node_size={} loaded_document_size={} loaded_stream_size={}\n", .{
        @sizeOf(yaml_internal.scanner.Token),
        @sizeOf(yaml_internal.parser.Event),
        @sizeOf(yaml_internal.value.Node),
        @sizeOf(yaml_internal.value.ScalarNode),
        @sizeOf(yaml_internal.value.SequenceNode),
        @sizeOf(yaml_internal.value.MappingPair),
        @sizeOf(yaml_internal.value.MappingNode),
        @sizeOf(yaml_internal.value.LoadedDocument),
        @sizeOf(yaml_internal.value.LoadedStream),
    });
    try stdout.print("format: input bytes api iterations ns_per_op bytes_per_sec checksum\n", .{});

    for (fixtures) |fixture| {
        try runBenchmark(allocator, io, stdout, fixture, .scanner);
        try runBenchmark(allocator, io, stdout, fixture, .parser_events);
        if (fixture.single_document) {
            try runBenchmark(allocator, io, stdout, fixture, .load_default);
            try runBenchmark(allocator, io, stdout, fixture, .load_failsafe_allow);
        } else {
            try runBenchmark(allocator, io, stdout, fixture, .load_stream_default);
        }
    }

    try stdout.print("allocation counts\n", .{});
    for (fixtures) |fixture| {
        const counts = try countTokensAndEvents(allocator, fixture.input);
        try reportAllocations(allocator, stdout, fixture, .scanner, counts);
        try reportAllocations(allocator, stdout, fixture, .parser_events, counts);
        try reportAllocations(allocator, stdout, fixture, .composer_events, counts);
        try reportAllocations(allocator, stdout, fixture, .loader_events, counts);
        if (fixture.single_document) {
            try reportAllocations(allocator, stdout, fixture, .load_default, counts);
            try reportAllocations(allocator, stdout, fixture, .load_failsafe_allow, counts);
        } else {
            try reportAllocations(allocator, stdout, fixture, .load_stream_default, counts);
        }
    }

    try stdout.flush();
}

fn buildFixtures(allocator: std.mem.Allocator) ![]Fixture {
    var fixtures: std.ArrayList(Fixture) = .empty;
    errdefer {
        for (fixtures.items) |fixture| {
            if (fixture.owned) allocator.free(fixture.input);
        }
        fixtures.deinit(allocator);
    }

    try fixtures.append(allocator, .{
        .name = "small-config",
        .input =
        \\name: yaml
        \\version: 1
        \\features:
        \\  parser: true
        \\  loader: true
        \\limits:
        \\  depth: 128
        \\  aliases: 64
        \\
        ,
    });
    try fixtures.append(allocator, .{
        .name = "quoted-escaped-scalars",
        .input =
        \\single: 'here''s to "quotes"'
        \\double: "escaped\\nline and \\t tab"
        \\plain: value with spaces
        \\flow: ["a:b", 'c#d', "unicode \\u263a"]
        \\
        ,
    });
    try fixtures.append(allocator, .{
        .name = "aliases",
        .input =
        \\base: &base
        \\  name: base
        \\  enabled: true
        \\items:
        \\  - *base
        \\  - *base
        \\
        ,
    });
    try fixtures.append(allocator, .{
        .name = "multi-document-stream",
        .input =
        \\---
        \\name: first
        \\---
        \\- 1
        \\- 2
        \\---
        \\nested:
        \\  value: true
        \\
        ,
        .single_document = false,
    });
    try fixtures.append(allocator, .{
        .name = "conformance-subset-9J7A-5C5M-4GC6",
        .input = conformance_subset,
        .single_document = false,
    });

    try fixtures.append(allocator, .{
        .name = "wide-mapping",
        .input = try generateWideMapping(allocator, 512),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "sequence-records",
        .input = try generateSequenceRecords(allocator, 200),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "nested-flow",
        .input = try generateNestedFlow(allocator, 128),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "wide-mapping-large",
        .input = try generateWideMapping(allocator, 1536),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "sequence-records-large",
        .input = try generateSequenceRecords(allocator, 512),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "alias-heavy",
        .input = try generateAliasHeavy(allocator, 256),
        .owned = true,
    });
    try fixtures.append(allocator, .{
        .name = "scalar-heavy",
        .input = try generateScalarHeavy(allocator, 192),
        .owned = true,
    });

    return fixtures.toOwnedSlice(allocator);
}

test "benchmark fixtures include comparison-derived hot paths" {
    const allocator = std.testing.allocator;
    const fixtures = try buildFixtures(allocator);
    defer deinitFixtures(allocator, fixtures);

    try expectFixture(fixtures, "nested-flow");
    try expectFixture(fixtures, "wide-mapping-large");
    try expectFixture(fixtures, "sequence-records-large");
    try expectFixture(fixtures, "alias-heavy");
    try expectFixture(fixtures, "scalar-heavy");
}

test "public load allocation metrics report retained and peak live bytes" {
    const metrics = try measureAllocations(std.testing.allocator,
        \\name: yaml
        \\items:
        \\  - one
        \\  - two
        \\
    , .load_default);

    try std.testing.expect(metrics.allocations > 0);
    try std.testing.expect(metrics.allocated_bytes >= metrics.retained_bytes);
    try std.testing.expect(metrics.peak_live_bytes >= metrics.retained_bytes);
    try std.testing.expect(metrics.retained_bytes > 0);
    try std.testing.expectEqual(metrics.allocated_bytes, metrics.freed_bytes);
}

test "benchmark count metrics include scanner tokens and parser events" {
    const counts = try countTokensAndEvents(std.testing.allocator,
        \\name: yaml
        \\items:
        \\  - one
        \\  - two
        \\
    );

    try std.testing.expect(counts.token_count > 0);
    try std.testing.expect(counts.event_count > 0);
}

fn expectFixture(fixtures: []const Fixture, name: []const u8) !void {
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, fixture.name, name)) return;
    }
    return error.MissingFixture;
}

fn deinitFixtures(allocator: std.mem.Allocator, fixtures: []Fixture) void {
    for (fixtures) |fixture| {
        if (fixture.owned) allocator.free(fixture.input);
    }
    allocator.free(fixtures);
}

fn generateWideMapping(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count * 24);
    for (0..count) |index| {
        try out.print(allocator, "key_{d}: value_{d}\n", .{ index, index });
    }
    return out.toOwnedSlice(allocator);
}

fn generateSequenceRecords(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count * 56);
    for (0..count) |index| {
        try out.print(allocator,
            \\- id: {d}
            \\  name: record-{d}
            \\  active: {s}
            \\  score: {d}
            \\
        , .{ index, index, if (index % 2 == 0) "true" else "false", index * 3 });
    }
    return out.toOwnedSlice(allocator);
}

fn generateNestedFlow(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count * 180);
    try out.appendSlice(allocator, "root:\n");
    for (0..count) |index| {
        try out.print(allocator, "  node_{d}: {{id: {d}, meta: {{name: node-{d}, flags: [true, false, null], nested: {{a: value-{d}, b: [one, two, three]}}}}, edges: [{{to: node-{d}, weight: {d}}}, {{to: node-{d}, weight: {d}}}]}}\n", .{
            index,
            index,
            index,
            index,
            (index + 1) % count,
            index * 3,
            (index + 2) % count,
            index * 5,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn generateAliasHeavy(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count * 56);
    for (0..count) |index| {
        try out.print(allocator,
            \\- &a{d}
            \\  id: {d}
            \\  name: item-{d}
            \\- *a{d}
            \\
        , .{ index, index, index, index });
    }
    return out.toOwnedSlice(allocator);
}

fn generateScalarHeavy(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count * 160);
    try out.appendSlice(allocator, "scalars:\n");
    for (0..count) |index| {
        try out.print(allocator,
            \\  item_{d}:
            \\    plain: plain value {d} with spaces
            \\    single: 'single ''quoted'' value {d}'
            \\    double: "double value {d} with \\n newline and \\t tab"
            \\    literal: |
            \\      line {d}
            \\      more scalar text {d}
            \\
        , .{ index, index, index, index, index, index });
    }
    return out.toOwnedSlice(allocator);
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    fixture: Fixture,
    api_path: ApiPath,
) !void {
    const iterations = iterationCount(fixture.input.len, api_path);
    var checksum: u64 = try runOne(allocator, fixture.input, api_path);

    const start = Io.Timestamp.now(io, .awake).toNanoseconds();
    for (0..iterations) |_| {
        checksum +%= try runOne(allocator, fixture.input, api_path);
    }
    const end = Io.Timestamp.now(io, .awake).toNanoseconds();

    const elapsed_ns = elapsedNanoseconds(start, end);
    const ns_per_op = elapsed_ns / iterations;
    const bytes_per_sec = (@as(u128, fixture.input.len) * iterations * std.time.ns_per_s) / elapsed_ns;
    try stdout.print(
        "input={s} bytes={} api={s} iterations={} ns_per_op={} bytes_per_sec={} checksum={}\n",
        .{ fixture.name, fixture.input.len, api_path.label(), iterations, ns_per_op, bytes_per_sec, checksum },
    );
}

fn reportAllocations(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    fixture: Fixture,
    allocation_path: AllocationPath,
    counts: CountMetrics,
) !void {
    const metrics = try measureAllocations(allocator, fixture.input, allocation_path);
    try stdout.print(
        "allocs input={s} bytes={} api={s} token_count={} event_count={} allocations={} frees={} allocated_bytes={} freed_bytes={} retained_bytes={} peak_live_bytes={} checksum={}\n",
        .{
            fixture.name,
            fixture.input.len,
            allocation_path.label(),
            counts.token_count,
            counts.event_count,
            metrics.allocations,
            metrics.frees,
            metrics.allocated_bytes,
            metrics.freed_bytes,
            metrics.retained_bytes,
            metrics.peak_live_bytes,
            metrics.checksum,
        },
    );
}

fn iterationCount(input_len: usize, api_path: ApiPath) u64 {
    const base: u64 = if (input_len < 512) 1024 else if (input_len < 4096) 256 else if (input_len < 32768) 64 else 32;
    return switch (api_path) {
        .scanner => base * 2,
        .parser_events => base,
        .load_default, .load_failsafe_allow, .load_stream_default => @max(8, base / 2),
    };
}

fn elapsedNanoseconds(start: i96, end: i96) u64 {
    const elapsed = end - start;
    if (elapsed <= 0) return 1;
    return @intCast(elapsed);
}

fn runOne(allocator: std.mem.Allocator, input: []const u8, api_path: ApiPath) !u64 {
    return switch (api_path) {
        .scanner => checksumScanner(try yaml_internal.scanner.scan(allocator, input)),
        .parser_events => checksumParserEvents(try parseEvents(allocator, input)),
        .load_default => try checksumLoadedInput(allocator, input, true, .core, .reject),
        .load_failsafe_allow => try checksumLoadedInput(allocator, input, true, .failsafe, .allow),
        .load_stream_default => try checksumLoadedInput(allocator, input, false, .core, .reject),
    };
}

fn measureAllocations(allocator: std.mem.Allocator, input: []const u8, allocation_path: AllocationPath) !AllocationMetrics {
    var counter: CountingAllocator = .{ .child = allocator };
    const counted_allocator = counter.allocator();

    const run: AllocationRun = switch (allocation_path) {
        .scanner => .{ .checksum = checksumScanner(try yaml_internal.scanner.scan(counted_allocator, input)), .retained_bytes = counter.live_bytes },
        .parser_events => .{ .checksum = checksumParserEvents(try parseEvents(counted_allocator, input)), .retained_bytes = counter.live_bytes },
        .composer_events => .{ .checksum = try measureComposerAllocations(allocator, counted_allocator, input), .retained_bytes = counter.live_bytes },
        .loader_events => .{ .checksum = try measureLoaderAllocations(allocator, counted_allocator, input), .retained_bytes = counter.live_bytes },
        .load_default => try measurePublicLoadAllocations(&counter, input, true, .core, .reject),
        .load_failsafe_allow => try measurePublicLoadAllocations(&counter, input, true, .failsafe, .allow),
        .load_stream_default => try measurePublicLoadAllocations(&counter, input, false, .core, .reject),
    };

    return .{
        .allocations = counter.allocations,
        .frees = counter.frees,
        .allocated_bytes = counter.allocated_bytes,
        .freed_bytes = counter.freed_bytes,
        .retained_bytes = run.retained_bytes,
        .peak_live_bytes = counter.peak_live_bytes,
        .checksum = run.checksum,
    };
}

fn measureComposerAllocations(allocator: std.mem.Allocator, counted_allocator: std.mem.Allocator, input: []const u8) !u64 {
    var events = try parseEvents(allocator, input);
    defer events.deinit();

    var arena = std.heap.ArenaAllocator.init(counted_allocator);
    defer arena.deinit();

    const documents = try yaml_internal.composer.composeStream(arena.allocator(), events.events, .{});
    return checksumGraphDocuments(documents);
}

fn measureLoaderAllocations(allocator: std.mem.Allocator, counted_allocator: std.mem.Allocator, input: []const u8) !u64 {
    var events = try parseEvents(allocator, input);
    defer events.deinit();

    var arena = std.heap.ArenaAllocator.init(counted_allocator);
    defer arena.deinit();

    const documents = try yaml_internal.loader.loadStreamFromEvents(arena.allocator(), events.events, .core, .reject, .preserve, null, null, null);
    var checksum: u64 = documents.len;
    for (documents) |document| {
        checksum +%= checksumNode(document);
    }
    return checksum;
}

fn measurePublicLoadAllocations(
    counter: *CountingAllocator,
    input: []const u8,
    require_single_document: bool,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
) !AllocationRun {
    const counted_allocator = counter.allocator();

    if (require_single_document) {
        var document = try yaml_internal.load_api.loadWithOptions(counted_allocator, input, .{
            .schema = selected_schema,
            .duplicate_key_behavior = duplicate_key_behavior,
        });
        defer document.deinit();

        return .{
            .checksum = 1 +% checksumNode(document.root),
            .retained_bytes = counter.live_bytes,
        };
    }

    var stream = try yaml_internal.load_api.loadStreamWithOptions(counted_allocator, input, .{
        .schema = selected_schema,
        .duplicate_key_behavior = duplicate_key_behavior,
    });
    defer stream.deinit();

    var checksum: u64 = stream.documents.len;
    for (stream.documents) |document| {
        checksum +%= checksumNode(document);
    }
    return .{
        .checksum = checksum,
        .retained_bytes = counter.live_bytes,
    };
}

fn countTokensAndEvents(allocator: std.mem.Allocator, input: []const u8) !CountMetrics {
    var token_stream = try yaml_internal.scanner.scan(allocator, input);
    defer token_stream.deinit();

    var event_stream = try yaml_internal.parseTokens(allocator, token_stream.tokens);
    defer event_stream.deinit();

    return .{
        .token_count = token_stream.tokens.len,
        .event_count = event_stream.events.len,
    };
}

fn parseEvents(allocator: std.mem.Allocator, input: []const u8) !yaml_internal.parser.EventStream {
    var token_stream = try yaml_internal.scanner.scan(allocator, input);
    defer token_stream.deinit();
    return yaml_internal.parseTokens(allocator, token_stream.tokens);
}

fn checksumLoadedInput(
    allocator: std.mem.Allocator,
    input: []const u8,
    require_single_document: bool,
    selected_schema: anytype,
    duplicate_key_behavior: anytype,
) !u64 {
    if (require_single_document) {
        var document = try yaml_internal.load_api.loadWithOptions(allocator, input, .{
            .schema = selected_schema,
            .duplicate_key_behavior = duplicate_key_behavior,
        });
        defer document.deinit();
        return 1 +% checksumNode(document.root);
    } else {
        var stream = try yaml_internal.load_api.loadStreamWithOptions(allocator, input, .{
            .schema = selected_schema,
            .duplicate_key_behavior = duplicate_key_behavior,
        });
        defer stream.deinit();

        var checksum: u64 = stream.documents.len;
        for (stream.documents) |document| {
            checksum +%= checksumNode(document);
        }
        return checksum;
    }
}

fn checksumScanner(stream: yaml_internal.scanner.TokenStream) u64 {
    var token_stream = stream;
    defer token_stream.deinit();

    var checksum: u64 = stream.tokens.len;
    for (stream.tokens) |token| {
        checksum *%= 16_777_619;
        checksum +%= switch (token) {
            .stream_start => 1,
            .stream_end => 2,
            .directive => |value| checksumBytes(value),
            .comment => |value| checksumBytes(value),
            .document_start => 3,
            .document_start_content => 4,
            .document_end => 5,
            .indent => |value| value,
            .block_sequence_entry => 6,
            .block_mapping_key => 7,
            .block_mapping_value => 8,
            .flow_sequence_start => 9,
            .flow_sequence_end => 10,
            .flow_mapping_start => 11,
            .flow_mapping_end => 12,
            .flow_entry => 13,
            .flow_mapping_key => 14,
            .flow_mapping_value => 15,
            .anchor => |value| checksumBytes(value),
            .alias => |value| checksumBytes(value),
            .tag => |value| checksumBytes(value),
            .block_scalar => |value| checksumBytes(value.content),
            .scalar => |value| checksumBytes(value),
        };
    }
    return checksum;
}

fn checksumParserEvents(stream: yaml_internal.parser.EventStream) u64 {
    var event_stream = stream;
    defer event_stream.deinit();

    var checksum: u64 = stream.events.len;
    for (stream.events) |event| {
        checksum *%= 16_777_619;
        checksum +%= switch (event) {
            .stream_start => 1,
            .stream_end => 2,
            .document_start => |value| if (value.explicit) 3 else 4,
            .document_end => |value| if (value.explicit) 5 else 6,
            .sequence_start => |value| checksumMaybeBytes(value.anchor) +% checksumMaybeBytes(value.tag) +% 7,
            .sequence_end => 8,
            .mapping_start => |value| checksumMaybeBytes(value.anchor) +% checksumMaybeBytes(value.tag) +% 9,
            .mapping_end => 10,
            .scalar => |value| checksumBytes(value.value) +% checksumMaybeBytes(value.anchor) +% checksumMaybeBytes(value.tag),
            .alias => |value| checksumBytes(value),
        };
    }
    return checksum;
}

fn checksumGraphDocuments(documents: []const *const yaml_internal.composer.Node) u64 {
    var checksum: u64 = documents.len;
    for (documents) |document| {
        checksum +%= checksumGraphNode(document);
    }
    return checksum;
}

fn checksumGraphNode(node: *const yaml_internal.composer.Node) u64 {
    return switch (node.*) {
        .scalar => |value| checksumBytes(value.value),
        .sequence => |sequence| checksumGraphSequence(sequence.items),
        .mapping => |mapping| checksumGraphMapping(mapping.pairs),
    };
}

fn checksumGraphSequence(items: []const *const yaml_internal.composer.Node) u64 {
    var checksum: u64 = items.len +% 17;
    for (items) |item| {
        checksum *%= 16_777_619;
        checksum +%= checksumGraphNode(item);
    }
    return checksum;
}

fn checksumGraphMapping(pairs: []const yaml_internal.composer.MappingPair) u64 {
    var checksum: u64 = pairs.len +% 31;
    for (pairs) |pair| {
        checksum *%= 16_777_619;
        checksum +%= checksumGraphNode(pair.key);
        checksum *%= 16_777_619;
        checksum +%= checksumGraphNode(pair.value);
    }
    return checksum;
}

fn checksumNode(node: anytype) u64 {
    return switch (node.*) {
        .null_value => 1,
        .bool_value => |value| if (value.value) 2 else 3,
        .int_value => |value| checksumInt(value.value),
        .float_value => |value| checksumFloat(value.value),
        .scalar => |value| checksumBytes(value.value),
        .sequence => |sequence| checksumSequence(sequence.items),
        .mapping => |mapping| checksumMapping(mapping.pairs),
        .alias => |value| checksumBytes(value),
    };
}

fn checksumSequence(items: anytype) u64 {
    var checksum: u64 = items.len +% 17;
    for (items) |item| {
        checksum *%= 16_777_619;
        checksum +%= checksumNode(item);
    }
    return checksum;
}

fn checksumMapping(pairs: anytype) u64 {
    var checksum: u64 = pairs.len +% 31;
    for (pairs) |pair| {
        checksum *%= 16_777_619;
        checksum +%= checksumNode(pair.key);
        checksum *%= 16_777_619;
        checksum +%= checksumNode(pair.value);
    }
    return checksum;
}

fn checksumMaybeBytes(value: ?[]const u8) u64 {
    return if (value) |bytes| checksumBytes(bytes) else 0;
}

fn checksumBytes(bytes: []const u8) u64 {
    var checksum: u64 = 2_166_136_261;
    for (bytes) |byte| {
        checksum ^= byte;
        checksum *%= 16_777_619;
    }
    return checksum;
}

fn checksumInt(value: i128) u64 {
    const magnitude: u128 = if (value < 0) @intCast(-value) else @intCast(value);
    return @truncate(magnitude ^ (magnitude >> 64));
}

fn checksumFloat(value: f64) u64 {
    return @bitCast(value);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.allocated_bytes += len;
        self.addLiveBytes(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.freed_bytes += memory.len;
        self.live_bytes -= memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn countResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const delta = new_len - old_len;
            self.allocated_bytes += delta;
            self.addLiveBytes(delta);
        } else {
            const delta = old_len - new_len;
            self.freed_bytes += delta;
            self.live_bytes -= delta;
        }
    }

    fn addLiveBytes(self: *CountingAllocator, len: usize) void {
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }
};
