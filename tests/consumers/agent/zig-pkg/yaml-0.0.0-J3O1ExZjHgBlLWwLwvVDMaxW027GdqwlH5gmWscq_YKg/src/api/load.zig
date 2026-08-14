//! Purpose: Public YAML loader API.
//! Owns: Single-document and stream loading entry points plus load-time limits.
//! Does not own: Event parsing, composition internals, schema resolution details, or value deinitialization types.
//! Depends on: api/parse.zig, api/options.zig, api/diagnostics.zig, api/diagnostic_policy.zig, loader/loader.zig, and value/value.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig, tests/stress/stress.zig.

const std = @import("std");
const common_limit = @import("../common/limit.zig");
const node_pool = @import("../common/node_pool.zig");
const diagnostic_policy = @import("diagnostic_policy.zig");
const diagnostics = @import("diagnostics.zig");
const construction_policy = @import("../loader/construction_policy.zig");
const options_api = @import("options.zig");
const parse = @import("parse.zig");
const loader = @import("../loader/loader.zig");
const scanner = @import("../scanner/scanner.zig");
const simple_fast_path = @import("../parser/simple_fast_path.zig");
const parser_tag = @import("../parser/tag.zig");
const value = @import("../value/value.zig");

const Error = diagnostics.Error;
const LoadedDocument = value.LoadedDocument;
const LoadedStream = value.LoadedStream;
const LoadOptions = options_api.LoadOptions;
const NodePool = node_pool.Pool(value.Node);
const ParseError = diagnostics.ParseError;
const ConstructionPolicy = construction_policy.Policy;

/// Loads a single YAML document into an arena-owned representation graph.
/// Returned node data is owned by the returned `LoadedDocument`; call `deinit`
/// to release it.
pub fn load(allocator: std.mem.Allocator, input: []const u8) Error!LoadedDocument {
    return loadWithOptions(allocator, input, .{});
}

/// Loads a single YAML document using the provided schema options.
/// Returned node data is owned by the returned `LoadedDocument`; call `deinit`
/// to release it.
pub fn loadWithOptions(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedDocument {
    var loaded_stream = try loadStreamWithOptions(allocator, input, options);
    const document_count = loaded_stream.documents.len;
    if (document_count != 1) {
        loaded_stream.deinit();
        diagnostic_policy.setSingleDocumentCountFailure(options.diagnostic, input);
        return if (document_count == 0) ParseError.InvalidSyntax else ParseError.Unsupported;
    }

    return .{
        .arena = loaded_stream.arena,
        .root = loaded_stream.documents[0],
    };
}

/// Loads all YAML documents in `input` into an arena-owned representation graph.
/// Returned node data is owned by the returned `LoadedStream`; call `deinit` to
/// release it.
pub fn loadStream(allocator: std.mem.Allocator, input: []const u8) Error!LoadedStream {
    return loadStreamWithOptions(allocator, input, .{});
}

/// Loads all YAML documents using the provided schema options.
/// Returned node data is owned by the returned `LoadedStream`; call `deinit` to
/// release it.
pub fn loadStreamWithOptions(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedStream {
    if (try tryStrictSimpleLoadStream(allocator, input, options)) |loaded_stream| {
        return loaded_stream;
    }

    return loadStreamViaEvents(allocator, input, options);
}

fn loadStreamViaEvents(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedStream {
    var event_stream = try parse.parseEventsWithOptions(allocator, input, .{
        .max_input_bytes = options.max_input_bytes,
        .max_event_count = options.max_event_count,
        .max_token_count = options.max_token_count,
        .max_nesting_depth = options.max_nesting_depth,
        .max_scalar_bytes = options.max_scalar_bytes,
        .diagnostic = options.diagnostic,
    });
    defer event_stream.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var load_failure: loader.LoadFailure = .unknown;
    const documents = loader.loadStreamFromEventsWithFailure(
        arena.allocator(),
        allocator,
        event_stream.events,
        options.schema,
        options.duplicate_key_behavior,
        options.unknown_tag_behavior,
        options.max_alias_count,
        options.max_alias_expansion,
        options.max_document_count,
        &load_failure,
        true,
    ) catch |err| {
        diagnostic_policy.setLoadFailure(options.diagnostic, input, load_failure, err);
        return err;
    };

    return .{
        .arena = arena,
        .documents = documents,
    };
}

fn loadStreamFastPath(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    return tryStrictSimpleLoadStream(allocator, input, options);
}

fn tryStrictSimpleLoadStream(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    if (options.max_input_bytes) |max_input_bytes| {
        if (input.len > max_input_bytes) {
            diagnostic_policy.setLimit(options.diagnostic, input, .{ .input_size = max_input_bytes });
            return ParseError.Unsupported;
        }
    }

    if (try trySourceLineLoadStreamAfterInputLimit(allocator, input, options)) |loaded_stream| {
        return loaded_stream;
    }

    if (!mayBeStrictSimpleInput(input)) return null;

    var token_stream = scanner.scan(allocator, input) catch |err| switch (err) {
        error.InvalidSyntax => return null,
        error.OutOfMemory => return err,
    };
    defer token_stream.deinit();

    if (options.max_token_count) |max_token_count| {
        if (token_stream.tokens.len > max_token_count) {
            diagnostic_policy.setLimit(options.diagnostic, input, .token_count);
            return ParseError.Unsupported;
        }
    }

    const shape = strictSimpleShape(token_stream.tokens) orelse return null;
    try checkStrictShapeLimits(input, options, shape);

    if (options.max_document_count) |max_document_count| {
        if (max_document_count == 0) {
            diagnostic_policy.setLoadFailure(options.diagnostic, input, .document_count_limit, ParseError.Unsupported);
            return ParseError.Unsupported;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    var builder: StrictSimpleBuilder = .{
        .arena_allocator = arena_allocator,
        .temporary_allocator = allocator,
        .input = input,
        .options = options,
        .nodes = try NodePool.init(arena_allocator, strictShapeStats(shape).node_count),
    };
    const root = try builder.construct(token_stream.tokens, shape);

    const documents = try arena_allocator.alloc(*const value.Node, 1);
    documents[0] = root;

    diagnostic_policy.clear(options.diagnostic);
    return .{
        .arena = arena,
        .documents = documents,
    };
}

fn trySourceLineLoadStream(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    if (options.max_input_bytes) |max_input_bytes| {
        if (input.len > max_input_bytes) {
            diagnostic_policy.setLimit(options.diagnostic, input, .{ .input_size = max_input_bytes });
            return ParseError.Unsupported;
        }
    }

    return trySourceLineLoadStreamAfterInputLimit(allocator, input, options);
}

fn trySourceLineLoadStreamAfterInputLimit(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    const shape = sourceLineShape(input) orelse return null;
    try checkSourceLineLimits(input, options, shape);

    if (options.max_document_count) |max_document_count| {
        if (max_document_count == 0) {
            diagnostic_policy.setLoadFailure(options.diagnostic, input, .document_count_limit, ParseError.Unsupported);
            return ParseError.Unsupported;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const stats = sourceLineStrictStats(shape);
    const arena_allocator = arena.allocator();
    var builder: StrictSimpleBuilder = .{
        .arena_allocator = arena_allocator,
        .temporary_allocator = allocator,
        .input = input,
        .options = options,
        .nodes = try NodePool.init(arena_allocator, stats.node_count),
    };

    const root = switch (shape) {
        .mapping => try builder.constructSourceLineMapping(input, stats.root_child_count),
        .sequence => try builder.constructSourceLineSequence(input, stats.root_child_count),
    };

    const documents = try arena_allocator.alloc(*const value.Node, 1);
    documents[0] = root;

    diagnostic_policy.clear(options.diagnostic);
    return .{
        .arena = arena,
        .documents = documents,
    };
}

const max_source_line_implicit_key_bytes: usize = 1024;

const SourceLineShape = union(enum) {
    mapping: SourceLineStats,
    sequence: SourceLineStats,
};

const SourceLineStats = struct {
    strict: StrictShapeStats,
    token_count: usize,
};

const SourceLinePair = struct {
    key: []const u8,
    value: []const u8,
};

const SourceLineIterator = struct {
    input: []const u8,
    cursor: usize = 0,

    fn init(input: []const u8) SourceLineIterator {
        return .{ .input = input };
    }

    fn next(self: *SourceLineIterator) ?[]const u8 {
        if (self.cursor >= self.input.len) return null;

        const start = self.cursor;
        var end = start;
        while (end < self.input.len and self.input[end] != '\n') : (end += 1) {}
        self.cursor = if (end < self.input.len) end + 1 else end;
        return self.input[start..end];
    }

    fn peek(self: *const SourceLineIterator) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

fn sourceLineShape(input: []const u8) ?SourceLineShape {
    if (input.len == 0 or !hasOnlySourceLineBytes(input)) return null;

    var lines = SourceLineIterator.init(input);
    const first = lines.next() orelse return null;
    if (first.len == 0) return null;

    if (std.mem.startsWith(u8, first, "- ")) return sourceLineSequenceShape(input);
    if (parseSourceLinePair(first) != null) return sourceLineMappingShape(input);
    return null;
}

fn sourceLineStrictStats(shape: SourceLineShape) StrictShapeStats {
    return switch (shape) {
        inline else => |stats| stats.strict,
    };
}

fn sourceLineTokenCount(shape: SourceLineShape) usize {
    return switch (shape) {
        inline else => |stats| stats.token_count,
    };
}

fn sourceLineMappingShape(input: []const u8) ?SourceLineShape {
    var lines = SourceLineIterator.init(input);
    var pair_count: usize = 0;
    var max_scalar_bytes: usize = 0;
    var token_count: usize = 2;

    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const pair = parseSourceLinePair(line) orelse return null;
        max_scalar_bytes = @max(max_scalar_bytes, pair.key.len);
        max_scalar_bytes = @max(max_scalar_bytes, pair.value.len);
        pair_count += 1;
        token_count += 4;
    }

    if (pair_count == 0) return null;
    return .{ .mapping = .{
        .strict = .{
            .event_count = 6 + pair_count * 2,
            .max_nesting_depth = 1,
            .max_scalar_bytes = max_scalar_bytes,
            .node_count = 1 + pair_count * 2,
            .root_child_count = pair_count,
        },
        .token_count = token_count,
    } };
}

fn sourceLineSequenceShape(input: []const u8) ?SourceLineShape {
    var lines = SourceLineIterator.init(input);
    var item_count: usize = 0;
    var item_event_count: usize = 0;
    var max_nesting_depth: usize = 1;
    var max_scalar_bytes: usize = 0;
    var node_count: usize = 1;
    var token_count: usize = 2;

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "- ")) return null;
        const item = line[2..];
        token_count += 2;

        if (parseSourceLinePair(item)) |pair| {
            max_nesting_depth = 2;
            item_event_count += 2;
            node_count += 1;
            includeSourceLinePairStats(pair, &max_scalar_bytes, &item_event_count, &node_count);
            token_count += 3;

            while (lines.peek()) |next_line| {
                if (std.mem.startsWith(u8, next_line, "- ")) break;
                if (!std.mem.startsWith(u8, next_line, "  ")) return null;
                const continuation = next_line[2..];
                const continuation_pair = parseSourceLinePair(continuation) orelse return null;
                _ = lines.next();
                includeSourceLinePairStats(continuation_pair, &max_scalar_bytes, &item_event_count, &node_count);
                token_count += 4;
            }
        } else {
            if (!isSourceLineScalarToken(item)) return null;
            max_scalar_bytes = @max(max_scalar_bytes, item.len);
            item_event_count += 1;
            node_count += 1;
            token_count += 1;

            if (lines.peek()) |next_line| {
                if (!std.mem.startsWith(u8, next_line, "- ")) return null;
            }
        }

        item_count += 1;
    }

    if (item_count == 0) return null;
    return .{ .sequence = .{
        .strict = .{
            .event_count = 6 + item_event_count,
            .max_nesting_depth = max_nesting_depth,
            .max_scalar_bytes = max_scalar_bytes,
            .node_count = node_count,
            .root_child_count = item_count,
        },
        .token_count = token_count,
    } };
}

fn includeSourceLinePairStats(
    pair: SourceLinePair,
    max_scalar_bytes: *usize,
    item_event_count: *usize,
    node_count: *usize,
) void {
    max_scalar_bytes.* = @max(max_scalar_bytes.*, pair.key.len);
    max_scalar_bytes.* = @max(max_scalar_bytes.*, pair.value.len);
    item_event_count.* += 2;
    node_count.* += 2;
}

fn parseSourceLinePair(line: []const u8) ?SourceLinePair {
    const separator = std.mem.indexOf(u8, line, ": ") orelse return null;
    const key = line[0..separator];
    const scalar_value = line[separator + 2 ..];
    if (!isSourceLineKeyToken(key) or !isSourceLineScalarToken(scalar_value)) return null;
    return .{ .key = key, .value = scalar_value };
}

fn isSourceLineKeyToken(token: []const u8) bool {
    return token.len <= max_source_line_implicit_key_bytes and isSourceLineScalarToken(token);
}

fn isSourceLineScalarToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "-") or std.mem.eql(u8, token, "?")) return false;
    for (token) |byte| {
        if (byte <= ' ' or byte > '~') return false;
    }
    return std.mem.indexOfAny(u8, token, ":#%!&*'\"[]{},|>@`") == null;
}

fn hasOnlySourceLineBytes(input: []const u8) bool {
    for (input) |byte| {
        if (byte != '\n' and (byte < ' ' or byte > '~')) return false;
    }
    return true;
}

fn checkSourceLineLimits(input: []const u8, options: LoadOptions, shape: SourceLineShape) Error!void {
    if (options.max_token_count) |max_token_count| {
        if (sourceLineTokenCount(shape) > max_token_count) {
            diagnostic_policy.setLimit(options.diagnostic, input, .token_count);
            return ParseError.Unsupported;
        }
    }

    try checkStrictStatsLimits(input, options, sourceLineStrictStats(shape));
}

const StrictSimpleShape = union(enum) {
    scalar: StrictShapeStats,
    mapping: StrictShapeStats,
    sequence: StrictShapeStats,
};

const StrictShapeStats = struct {
    event_count: usize,
    max_nesting_depth: usize,
    max_scalar_bytes: usize,
    node_count: usize,
    root_child_count: usize = 0,
    nested_mapping_values: bool = false,
};

const StrictScalarToken = struct {
    value: []const u8,
    tag: ?[]const u8 = null,
};

const StrictScalarRole = enum {
    key,
    value,
};

const StrictNodeStats = struct {
    event_count: usize,
    max_nesting_depth: usize,
    max_scalar_bytes: usize = 0,
    node_count: usize,
    root_child_count: usize = 0,
};

fn mayBeStrictSimpleInput(input: []const u8) bool {
    var start: usize = 0;
    while (start < input.len) {
        var end = start;
        while (end < input.len and input[end] != '\n') : (end += 1) {}
        var line = input[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0) {
            if (trimmed[0] == '#') return false;
            if (trimmed[0] == '%') return false;
            if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "...")) return false;
            if (std.mem.indexOfAny(u8, trimmed, "&*'\"[]{}|>%#") != null) return false;
            if (line.len != trimmed.len and !std.mem.containsAtLeast(u8, trimmed, 1, ":")) return false;
        }

        start = if (end < input.len) end + 1 else end;
    }
    return true;
}

fn strictShapeStats(shape: StrictSimpleShape) StrictShapeStats {
    return switch (shape) {
        inline else => |stats| stats,
    };
}

fn strictSimpleShape(tokens: []const scanner.Token) ?StrictSimpleShape {
    if (strictSimpleScalarShape(tokens)) |stats| return .{ .scalar = stats };
    if (strictSimpleBlockMappingShape(tokens)) |stats| return .{ .mapping = stats };
    if (strictSimpleBlockSequenceShape(tokens)) |stats| return .{ .sequence = stats };
    return null;
}

fn strictSimpleScalarShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 4 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;
    var index: usize = 1;
    if (tokens[index] != .indent or tokens[index].indent != 0) return null;
    index += 1;

    const scalar_token = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return null;
    if (index != tokens.len - 1) return null;

    return .{
        .event_count = 5,
        .max_nesting_depth = 0,
        .max_scalar_bytes = scalar_token.value.len,
        .node_count = 1,
    };
}

fn strictSimpleBlockMappingShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (strictFlatBlockMappingShape(tokens)) |stats| return stats;
    return strictNestedBlockMappingShape(tokens);
}

fn strictFlatBlockMappingShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 6 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var pair_count: usize = 0;
    var max_scalar_bytes: usize = 0;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;

        const key = readStrictScalarToken(tokens, &index, tokens.len - 1, .key) orelse return null;
        max_scalar_bytes = @max(max_scalar_bytes, key.value.len);

        if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
        index += 1;

        const scalar_value = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return null;
        max_scalar_bytes = @max(max_scalar_bytes, scalar_value.value.len);

        pair_count += 1;
    }

    if (pair_count == 0) return null;
    return .{
        .event_count = 6 + pair_count * 2,
        .max_nesting_depth = 1,
        .max_scalar_bytes = max_scalar_bytes,
        .node_count = 1 + pair_count * 2,
        .root_child_count = pair_count,
    };
}

fn strictNestedBlockMappingShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 6 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var index: usize = 1;
    const mapping = strictBlockMappingNodeStats(tokens, &index, tokens.len - 1, 0, 1) orelse return null;
    if (index != tokens.len - 1) return null;

    return .{
        .event_count = 4 + mapping.event_count,
        .max_nesting_depth = mapping.max_nesting_depth,
        .max_scalar_bytes = mapping.max_scalar_bytes,
        .node_count = mapping.node_count,
        .root_child_count = mapping.root_child_count,
        .nested_mapping_values = true,
    };
}

fn strictBlockMappingNodeStats(
    tokens: []const scanner.Token,
    index: *usize,
    end: usize,
    mapping_indent: usize,
    depth: usize,
) ?StrictNodeStats {
    var stats: StrictNodeStats = .{
        .event_count = 2,
        .max_nesting_depth = depth,
        .node_count = 1,
    };
    var pair_count: usize = 0;

    while (index.* < end) {
        if (tokens[index.*] != .indent) break;
        const indent = tokens[index.*].indent;
        if (indent < mapping_indent) break;
        if (indent != mapping_indent) return null;
        index.* += 1;

        const key = readStrictScalarToken(tokens, index, end, .key) orelse return null;
        includeStrictScalarStats(&stats, key);

        if (index.* >= end or tokens[index.*] != .block_mapping_value) return null;
        index.* += 1;

        var value_index = index.*;
        if (readStrictScalarToken(tokens, &value_index, end, .value)) |scalar_value| {
            index.* = value_index;
            includeStrictScalarStats(&stats, scalar_value);
        } else {
            if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= mapping_indent) return null;
            const nested = strictBlockMappingNodeStats(tokens, index, end, tokens[index.*].indent, depth + 1) orelse return null;
            includeStrictNodeStats(&stats, nested);
        }

        pair_count += 1;
    }

    if (pair_count == 0) return null;
    stats.root_child_count = pair_count;
    return stats;
}

fn includeStrictScalarStats(stats: *StrictNodeStats, scalar_token: StrictScalarToken) void {
    stats.event_count += 1;
    stats.node_count += 1;
    stats.max_scalar_bytes = @max(stats.max_scalar_bytes, scalar_token.value.len);
}

fn includeStrictNodeStats(stats: *StrictNodeStats, node_stats: StrictNodeStats) void {
    stats.event_count += node_stats.event_count;
    stats.node_count += node_stats.node_count;
    stats.max_scalar_bytes = @max(stats.max_scalar_bytes, node_stats.max_scalar_bytes);
    stats.max_nesting_depth = @max(stats.max_nesting_depth, node_stats.max_nesting_depth);
}

fn strictSimpleBlockSequenceShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 4 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var item_count: usize = 0;
    var item_event_count: usize = 0;
    var max_nesting_depth: usize = 1;
    var max_scalar_bytes: usize = 0;
    var node_count: usize = 1;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;
        if (index >= tokens.len - 1 or tokens[index] != .block_sequence_entry) return null;
        index += 1;

        const first = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return null;
        if (index < tokens.len - 1 and tokens[index] == .block_mapping_value) {
            if (!simple_fast_path.isSimpleBlockMappingKeyToken(first.value)) return null;
            max_nesting_depth = 2;
            item_event_count += 2;
            node_count += 3;
            max_scalar_bytes = @max(max_scalar_bytes, first.value.len);
            index += 1;

            const first_value = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return null;
            item_event_count += 2;
            max_scalar_bytes = @max(max_scalar_bytes, first_value.value.len);

            var mapping_indent: ?usize = null;
            while (index < tokens.len - 1) {
                if (tokens[index] != .indent) return null;
                const indent = tokens[index].indent;
                if (indent == 0) break;
                if (mapping_indent) |expected| {
                    if (indent != expected) return null;
                } else {
                    mapping_indent = indent;
                }
                index += 1;

                const key = readStrictScalarToken(tokens, &index, tokens.len - 1, .key) orelse return null;
                max_scalar_bytes = @max(max_scalar_bytes, key.value.len);
                if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
                index += 1;
                const scalar_value = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return null;
                max_scalar_bytes = @max(max_scalar_bytes, scalar_value.value.len);
                item_event_count += 2;
                node_count += 2;
            }
        } else {
            max_scalar_bytes = @max(max_scalar_bytes, first.value.len);
            item_event_count += 1;
            node_count += 1;
        }

        item_count += 1;
    }

    if (item_count == 0) return null;
    return .{
        .event_count = 6 + item_event_count,
        .max_nesting_depth = max_nesting_depth,
        .max_scalar_bytes = max_scalar_bytes,
        .node_count = node_count,
        .root_child_count = item_count,
    };
}

fn readStrictScalarToken(tokens: []const scanner.Token, index: *usize, end: usize, role: StrictScalarRole) ?StrictScalarToken {
    var cursor = index.*;
    if (cursor >= end) return null;

    const tag_value = if (tokens[cursor] == .tag) value: {
        if (!isStrictSimpleTagToken(tokens[cursor].tag)) return null;
        const raw = tokens[cursor].tag;
        cursor += 1;
        break :value raw;
    } else null;

    if (cursor >= end or tokens[cursor] != .scalar) return null;
    const scalar_value = tokens[cursor].scalar;
    const supported = switch (role) {
        .key => simple_fast_path.isSimpleBlockMappingKeyToken(scalar_value),
        .value => simple_fast_path.isSimplePlainScalarToken(scalar_value),
    };
    if (!supported) return null;

    index.* = cursor + 1;
    return .{ .value = scalar_value, .tag = tag_value };
}

fn isStrictSimpleTagToken(raw: []const u8) bool {
    if (raw.len == 0 or raw[0] != '!') return false;
    if (std.mem.eql(u8, raw, "!")) return true;
    if (std.mem.indexOfAny(u8, raw, "<>%")) |_| return false;

    if (std.mem.startsWith(u8, raw, "!!")) {
        return raw.len > 2 and std.mem.indexOfScalar(u8, raw[2..], '!') == null;
    }

    return std.mem.indexOfScalar(u8, raw[1..], '!') == null;
}

fn checkStrictShapeLimits(input: []const u8, options: LoadOptions, shape: StrictSimpleShape) Error!void {
    try checkStrictStatsLimits(input, options, strictShapeStats(shape));
}

fn checkStrictStatsLimits(input: []const u8, options: LoadOptions, stats: StrictShapeStats) Error!void {
    if (options.max_event_count) |max_event_count| {
        if (stats.event_count > max_event_count) {
            diagnostic_policy.setLimit(options.diagnostic, input, .event_count);
            return ParseError.Unsupported;
        }
    }

    if (options.max_scalar_bytes) |max_scalar_bytes| {
        if (stats.max_scalar_bytes > max_scalar_bytes) {
            diagnostic_policy.setLimit(options.diagnostic, input, .scalar_size);
            return ParseError.Unsupported;
        }
    }

    const max_nesting_depth = options.max_nesting_depth orelse common_limit.default_parse_collection_depth;
    if (stats.max_nesting_depth > max_nesting_depth) {
        diagnostic_policy.setLimit(options.diagnostic, input, .nesting_depth);
        return ParseError.Unsupported;
    }
}

const StrictSimpleBuilder = struct {
    arena_allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    input: []const u8,
    options: LoadOptions,
    nodes: NodePool,

    fn construct(self: *StrictSimpleBuilder, tokens: []const scanner.Token, shape: StrictSimpleShape) Error!*const value.Node {
        return switch (shape) {
            .scalar => self.constructRootScalar(tokens),
            .mapping => |stats| if (stats.nested_mapping_values)
                self.constructNestedBlockMapping(tokens, stats.root_child_count)
            else
                self.constructFlatBlockMapping(tokens, stats.root_child_count),
            .sequence => |stats| self.constructBlockSequence(tokens, stats.root_child_count),
        };
    }

    fn constructRootScalar(self: *StrictSimpleBuilder, tokens: []const scanner.Token) Error!*const value.Node {
        var index: usize = 2;
        const scalar_token = readStrictScalarToken(tokens, &index, tokens.len - 1, .value) orelse return ParseError.InvalidSyntax;
        return self.constructPlainScalar(scalar_token);
    }

    fn constructFlatBlockMapping(self: *StrictSimpleBuilder, tokens: []const scanner.Token, pair_count: usize) Error!*const value.Node {
        const pairs = try self.arena_allocator.alloc(value.MappingPair, pair_count);

        var pair_index: usize = 0;
        var token_index: usize = 1;
        while (token_index < tokens.len - 1) : (pair_index += 1) {
            token_index += 1;
            const key_token = readStrictScalarToken(tokens, &token_index, tokens.len - 1, .key) orelse return ParseError.InvalidSyntax;
            const key = try self.constructPlainScalar(key_token);
            if (token_index >= tokens.len - 1 or tokens[token_index] != .block_mapping_value) return ParseError.InvalidSyntax;
            token_index += 1;
            const value_token = readStrictScalarToken(tokens, &token_index, tokens.len - 1, .value) orelse return ParseError.InvalidSyntax;
            const node_value = try self.constructPlainScalar(value_token);
            pairs[pair_index] = .{ .key = key, .value = node_value };
        }

        try self.validateMappingPairs(pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = pairs } };
        return node;
    }

    fn constructNestedBlockMapping(self: *StrictSimpleBuilder, tokens: []const scanner.Token, pair_count: usize) Error!*const value.Node {
        var token_index: usize = 1;
        return self.constructBlockMappingAt(tokens, &token_index, tokens.len - 1, 0, pair_count);
    }

    fn constructBlockMappingAt(
        self: *StrictSimpleBuilder,
        tokens: []const scanner.Token,
        index: *usize,
        end: usize,
        mapping_indent: usize,
        pair_capacity: usize,
    ) Error!*const value.Node {
        var pairs: std.ArrayList(value.MappingPair) = .empty;
        errdefer pairs.deinit(self.arena_allocator);
        try pairs.ensureTotalCapacity(self.arena_allocator, pair_capacity);

        while (index.* < end) {
            if (tokens[index.*] != .indent) break;
            const indent = tokens[index.*].indent;
            if (indent < mapping_indent) break;
            if (indent != mapping_indent) return ParseError.InvalidSyntax;
            index.* += 1;

            const key_token = readStrictScalarToken(tokens, index, end, .key) orelse return ParseError.InvalidSyntax;
            const key = try self.constructPlainScalar(key_token);

            if (index.* >= end or tokens[index.*] != .block_mapping_value) return ParseError.InvalidSyntax;
            index.* += 1;

            var value_index = index.*;
            const node_value = if (readStrictScalarToken(tokens, &value_index, end, .value)) |value_token| value: {
                index.* = value_index;
                break :value try self.constructPlainScalar(value_token);
            } else value: {
                if (index.* >= end or tokens[index.*] != .indent or tokens[index.*].indent <= mapping_indent) return ParseError.InvalidSyntax;
                break :value try self.constructBlockMappingAt(tokens, index, end, tokens[index.*].indent, 0);
            };

            try pairs.append(self.arena_allocator, .{ .key = key, .value = node_value });
        }

        const owned_pairs = try pairs.toOwnedSlice(self.arena_allocator);
        try self.validateMappingPairs(owned_pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = owned_pairs } };
        return node;
    }

    fn constructBlockSequence(self: *StrictSimpleBuilder, tokens: []const scanner.Token, item_count: usize) Error!*const value.Node {
        const items = try self.arena_allocator.alloc(*const value.Node, item_count);

        var item_index: usize = 0;
        var token_index: usize = 1;
        while (token_index < tokens.len - 1) : (item_index += 1) {
            token_index += 2;
            const item_start = token_index;
            const first = readStrictScalarToken(tokens, &token_index, tokens.len - 1, .value) orelse return ParseError.InvalidSyntax;
            if (token_index < tokens.len - 1 and tokens[token_index] == .block_mapping_value) {
                if (!simple_fast_path.isSimpleBlockMappingKeyToken(first.value)) return ParseError.InvalidSyntax;
                token_index = item_start;
                items[item_index] = try self.constructCompactMappingItem(tokens, &token_index);
            } else {
                items[item_index] = try self.constructPlainScalar(first);
            }
        }

        const node = try self.nodes.create();
        node.* = .{ .sequence = .{ .items = items } };
        return node;
    }

    fn constructCompactMappingItem(self: *StrictSimpleBuilder, tokens: []const scanner.Token, index: *usize) Error!*const value.Node {
        var pairs: std.ArrayList(value.MappingPair) = .empty;
        errdefer pairs.deinit(self.arena_allocator);

        while (true) {
            const key_token = readStrictScalarToken(tokens, index, tokens.len - 1, .key) orelse return ParseError.InvalidSyntax;
            const key = try self.constructPlainScalar(key_token);
            if (index.* >= tokens.len - 1 or tokens[index.*] != .block_mapping_value) return ParseError.InvalidSyntax;
            index.* += 1;
            const value_token = readStrictScalarToken(tokens, index, tokens.len - 1, .value) orelse return ParseError.InvalidSyntax;
            const node_value = try self.constructPlainScalar(value_token);
            try pairs.append(self.arena_allocator, .{ .key = key, .value = node_value });

            if (index.* >= tokens.len - 1 or tokens[index.*] != .indent or tokens[index.*].indent == 0) break;
            index.* += 1;
        }

        const owned_pairs = try pairs.toOwnedSlice(self.arena_allocator);
        try self.validateMappingPairs(owned_pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = owned_pairs } };
        return node;
    }

    fn constructSourceLineMapping(self: *StrictSimpleBuilder, input: []const u8, pair_count: usize) Error!*const value.Node {
        const pairs = try self.arena_allocator.alloc(value.MappingPair, pair_count);

        var lines = SourceLineIterator.init(input);
        var pair_index: usize = 0;
        while (lines.next()) |line| : (pair_index += 1) {
            const pair = parseSourceLinePair(line) orelse return ParseError.InvalidSyntax;
            pairs[pair_index] = try self.constructSourceLinePair(pair);
        }

        try self.validateMappingPairs(pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = pairs } };
        return node;
    }

    fn constructSourceLineSequence(self: *StrictSimpleBuilder, input: []const u8, item_count: usize) Error!*const value.Node {
        const items = try self.arena_allocator.alloc(*const value.Node, item_count);

        var lines = SourceLineIterator.init(input);
        var item_index: usize = 0;
        while (lines.next()) |line| : (item_index += 1) {
            if (!std.mem.startsWith(u8, line, "- ")) return ParseError.InvalidSyntax;
            const item = line[2..];
            if (parseSourceLinePair(item)) |pair| {
                items[item_index] = try self.constructSourceLineCompactMapping(pair, &lines);
            } else {
                if (!isSourceLineScalarToken(item)) return ParseError.InvalidSyntax;
                items[item_index] = try self.constructPlainScalar(.{ .value = item });
            }
        }

        const node = try self.nodes.create();
        node.* = .{ .sequence = .{ .items = items } };
        return node;
    }

    fn constructSourceLineCompactMapping(
        self: *StrictSimpleBuilder,
        first_pair: SourceLinePair,
        lines: *SourceLineIterator,
    ) Error!*const value.Node {
        var pairs: std.ArrayList(value.MappingPair) = .empty;
        errdefer pairs.deinit(self.arena_allocator);

        try pairs.append(self.arena_allocator, try self.constructSourceLinePair(first_pair));
        while (lines.peek()) |line| {
            if (std.mem.startsWith(u8, line, "- ")) break;
            if (!std.mem.startsWith(u8, line, "  ")) return ParseError.InvalidSyntax;
            const pair = parseSourceLinePair(line[2..]) orelse return ParseError.InvalidSyntax;
            _ = lines.next();
            try pairs.append(self.arena_allocator, try self.constructSourceLinePair(pair));
        }

        const owned_pairs = try pairs.toOwnedSlice(self.arena_allocator);
        try self.validateMappingPairs(owned_pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = owned_pairs } };
        return node;
    }

    fn constructSourceLinePair(self: *StrictSimpleBuilder, pair: SourceLinePair) Error!value.MappingPair {
        return .{
            .key = try self.constructPlainScalar(.{ .value = pair.key }),
            .value = try self.constructPlainScalar(.{ .value = pair.value }),
        };
    }

    fn constructPlainScalar(self: *StrictSimpleBuilder, scalar_token: StrictScalarToken) Error!*const value.Node {
        const node = try self.nodes.create();
        node.* = try self.constructPlainScalarNode(scalar_token);
        return node;
    }

    fn constructPlainScalarNode(self: *StrictSimpleBuilder, scalar_token: StrictScalarToken) Error!value.Node {
        const resolved_tag = try self.resolveTag(scalar_token.tag);
        var load_failure: loader.LoadFailure = .unknown;
        const resolved = self.constructionPolicy(&load_failure).validateAndResolveScalar(.{
            .value = scalar_token.value,
            .is_plain = true,
            .tag = resolved_tag,
        }) catch |err| {
            diagnostic_policy.setLoadFailure(self.options.diagnostic, self.input, load_failure, err);
            return err;
        };

        if (resolved) |resolved_scalar| {
            return construction_policy.nodeFromResolvedScalar(resolved_scalar, null, resolved_tag);
        }

        return .{ .scalar = .{
            .value = try self.arena_allocator.dupe(u8, scalar_token.value),
            .tag = resolved_tag,
        } };
    }

    fn resolveTag(self: *StrictSimpleBuilder, raw_tag: ?[]const u8) Error!?[]const u8 {
        const tag_value = raw_tag orelse return null;
        return parser_tag.resolve(self.arena_allocator, &.{}, tag_value) catch |err| {
            diagnostic_policy.setLoadFailure(self.options.diagnostic, self.input, .invalid_graph, err);
            return err;
        };
    }

    fn validateMappingPairs(self: *StrictSimpleBuilder, pairs: []const value.MappingPair) Error!void {
        var load_failure: loader.LoadFailure = .unknown;
        self.constructionPolicy(&load_failure).validateDuplicateMappingKeys(
            self.temporary_allocator,
            pairs,
            self.options.duplicate_key_behavior,
        ) catch |err| {
            diagnostic_policy.setLoadFailure(self.options.diagnostic, self.input, load_failure, err);
            return err;
        };
    }

    fn constructionPolicy(self: *StrictSimpleBuilder, load_failure: *loader.LoadFailure) ConstructionPolicy {
        return .{
            .schema = self.options.schema,
            .unknown_tag_behavior = self.options.unknown_tag_behavior,
            .failure = load_failure,
        };
    }
};

test "loadWithOptions sets fallback diagnostic for multi-document single load" {
    const input = "---\none\n---\ntwo\n";
    var diagnostic: diagnostics.Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
}

test "loadWithOptions sets fallback diagnostic for empty single load" {
    const input = "# no document\n";
    var diagnostic: diagnostics.Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
}

test "load diagnostic maps unknown loader failures by parse error" {
    const input = "key: value\n";

    const invalid = diagnostic_policy.loadFailureDiagnostic(input, .unknown, ParseError.InvalidSyntax);
    try std.testing.expectEqualStrings("loader rejected invalid YAML graph", invalid.message);
    try std.testing.expectEqual(input.len, invalid.offset);

    const unsupported = diagnostic_policy.loadFailureDiagnostic(input, .unknown, ParseError.Unsupported);
    try std.testing.expectEqualStrings("loader exceeded configured safety limit", unsupported.message);
    try std.testing.expectEqual(input.len, unsupported.offset);
}

test "load fast path accepts alias-free input" {
    var loaded = (try loadStreamFastPath(std.testing.allocator,
        \\name: yaml
        \\version: 1
        \\
    , .{})).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.documents.len);
    try std.testing.expect(loaded.documents[0].* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), loaded.documents[0].mapping.pairs.len);
}

test "load fast path declines aliases for fallback" {
    const loaded = try loadStreamFastPath(std.testing.allocator,
        \\base: &base value
        \\again: *base
        \\
    , .{});

    try std.testing.expect(loaded == null);
}

test "load fast path declines alias-heavy input for fallback" {
    const input =
        \\- &a0 value0
        \\- *a0
        \\- &a1 value1
        \\- *a1
        \\
    ;

    const fast = try tryStrictSimpleLoadStream(std.testing.allocator, input, .{});
    if (fast) |loaded| {
        var owned = loaded;
        defer owned.deinit();
        return error.ExpectedFallback;
    }

    var stream = try loadStreamWithOptions(std.testing.allocator, input, .{});
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .sequence);
    try std.testing.expectEqual(@as(usize, 4), root.sequence.items.len);
    try std.testing.expectEqual(root.sequence.items[0], root.sequence.items[1]);
    try std.testing.expectEqual(root.sequence.items[2], root.sequence.items[3]);
}

test "strict simple load fast path matches forced fallback" {
    const cases = [_][]const u8{
        "plain\n",
        "!!str value\n",
        "name: yaml\nversion: 1\n",
        "name: yaml\nfeatures:\n  parser: true\n  loader: true\n",
        "- one\n- two\n",
        "- id: 1\n  name: record-1\n- id: 2\n  name: record-2\n",
    };

    for (cases) |input| {
        var fast = (try tryStrictSimpleLoadStream(std.testing.allocator, input, .{})).?;
        defer fast.deinit();

        var fallback = try loadStreamViaEvents(std.testing.allocator, input, .{});
        defer fallback.deinit();

        try expectLoadedStreamsEqual(&fast, &fallback);
    }
}

test "source-line simple load fast path matches forced fallback" {
    const cases = [_][]const u8{
        "name: yaml\nversion: 1\n",
        "- one\n- two\n",
        "- id: 1\n  name: record-1\n- id: 2\n  name: record-2\n",
    };

    for (cases) |input| {
        var direct = (try trySourceLineLoadStream(std.testing.allocator, input, .{})).?;
        defer direct.deinit();

        var fallback = try loadStreamViaEvents(std.testing.allocator, input, .{});
        defer fallback.deinit();

        try expectLoadedStreamsEqual(&direct, &fallback);
    }
}

test "source-line simple load fast path declines unsupported shapes" {
    const cases = [_][]const u8{
        "plain\n",
        "# comment\nkey: value\n",
        "%YAML 1.2\n---\nvalue\n",
        "---\nkey: value\n",
        "...\n",
        "key: value # comment\n",
        "key: !local value\n",
        "key: &anchor value\n",
        "key: *anchor\n",
        "key: 'quoted'\n",
        "key: \"quoted\"\n",
        "key: |\n  line\n",
        "key: [value]\n",
        "key: {nested: value}\n",
        "key:\n",
        "key: first\n  second\n",
        "key: value\n\nother: value\n",
        " key: value\n",
        "foo bar: value\n",
        "key: two words\n",
        "key: value\r\n",
        "key:\tvalue\n",
        "caf\xc3\xa9: value\n",
        "-\n",
        "- - nested\n",
        "- one\n  name: nope\n",
        "- id: 1\n name: nope\n",
        "- id: 1\n    name: nope\n",
        "- id: 1\n  name: record one\n",
    };

    for (cases) |input| {
        const loaded = try trySourceLineLoadStream(std.testing.allocator, input, .{});
        if (loaded) |stream| {
            var owned = stream;
            defer owned.deinit();
            return error.ExpectedFallback;
        }
        try std.testing.expect(loaded == null);
    }
}

test "source-line simple load fast path preserves schema duplicate key and limit behavior" {
    var core = (try trySourceLineLoadStream(std.testing.allocator, "truth: TRUE\nnothing: ~\n", .{ .schema = .core })).?;
    defer core.deinit();
    try std.testing.expect(core.documents[0].mapping.pairs[0].value.* == .bool_value);
    try std.testing.expectEqual(true, core.documents[0].mapping.pairs[0].value.bool_value.value);
    try std.testing.expect(core.documents[0].mapping.pairs[1].value.* == .null_value);

    var failsafe = (try trySourceLineLoadStream(std.testing.allocator, "truth: TRUE\n", .{ .schema = .failsafe })).?;
    defer failsafe.deinit();
    try std.testing.expect(failsafe.documents[0].mapping.pairs[0].value.* == .scalar);
    try std.testing.expectEqualStrings("TRUE", failsafe.documents[0].mapping.pairs[0].value.scalar.value);

    var json = (try trySourceLineLoadStream(std.testing.allocator, "- true\n- false\n", .{ .schema = .json })).?;
    defer json.deinit();
    try std.testing.expect(json.documents[0].sequence.items[0].* == .bool_value);
    try std.testing.expectEqual(true, json.documents[0].sequence.items[0].bool_value.value);

    var diagnostic: diagnostics.Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, trySourceLineLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected duplicate mapping key", diagnostic.message);

    var duplicate_allowed = (try trySourceLineLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .duplicate_key_behavior = .allow,
    })).?;
    defer duplicate_allowed.deinit();
    try std.testing.expectEqual(@as(usize, 2), duplicate_allowed.documents[0].mapping.pairs.len);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: b\n", .{
        .max_input_bytes = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("input exceeds configured size limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: bb\n", .{
        .max_scalar_bytes = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: b\n", .{
        .max_token_count = 5,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: b\n", .{
        .max_event_count = 7,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: b\n", .{
        .max_nesting_depth = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, trySourceLineLoadStream(std.testing.allocator, "a: b\n", .{
        .max_document_count = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader exceeded configured document count limit", diagnostic.message);
}

test "source-line simple load fast path cleans up accepted and declined allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSourceLineLoadAllocationFailure, .{});
}

fn checkSourceLineLoadAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    var mapping = (try trySourceLineLoadStream(failing_allocator, "name: yaml\nversion: 1\n", .{})).?;
    defer mapping.deinit();

    var sequence = (try trySourceLineLoadStream(failing_allocator, "- id: 1\n  name: record-1\n", .{})).?;
    defer sequence.deinit();

    const declined = try trySourceLineLoadStream(failing_allocator, "name: [yaml]\n", .{});
    try std.testing.expect(declined == null);
}

test "strict simple load fast path declines unsupported shapes" {
    const cases = [_][]const u8{
        "*anchor\n",
        "&anchor value\n",
        "%YAML 1.2\n---\nvalue\n",
        "--- value\n",
        "key: value # comment\n",
        "\"quoted\"\n",
        "literal: |\n  line\n",
        "[one, two]\n",
        "key: first\n  second\n",
        "key:\n",
        "-\n  - nested\n",
    };

    for (cases) |input| {
        const fast = try tryStrictSimpleLoadStream(std.testing.allocator, input, .{});
        if (fast) |loaded| {
            var owned = loaded;
            defer owned.deinit();
            return error.ExpectedFallback;
        }
        try std.testing.expect(fast == null);
    }
}

test "strict simple load fast path owns accepted strings after input and scan storage release" {
    const input = try std.testing.allocator.dupe(u8, "name: yaml\nversion: 1\n");

    var stream = (try tryStrictSimpleLoadStream(std.testing.allocator, input, .{})).?;
    defer stream.deinit();

    @memset(input, 0xa5);
    std.testing.allocator.free(input);

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("name", root.mapping.pairs[0].key.scalar.value);
    try std.testing.expectEqualStrings("yaml", root.mapping.pairs[0].value.scalar.value);
    try std.testing.expectEqualStrings("version", root.mapping.pairs[1].key.scalar.value);
    try std.testing.expectEqual(@as(i128, 1), root.mapping.pairs[1].value.int_value.value);
}

test "strict simple load fast path cleans up accepted and declined allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkStrictSimpleLoadAllocationFailure, .{});
}

fn checkStrictSimpleLoadAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    var accepted = (try tryStrictSimpleLoadStream(failing_allocator, "name: yaml\nversion: 1\n", .{})).?;
    defer accepted.deinit();

    var tagged = (try tryStrictSimpleLoadStream(failing_allocator, "name: !local yaml\nversion: !!int 1\n", .{})).?;
    defer tagged.deinit();

    const declined = try tryStrictSimpleLoadStream(failing_allocator, "name: [yaml]\n", .{});
    try std.testing.expect(declined == null);
}

test "strict simple load fast path preserves schema duplicate key and limit behavior" {
    var core = (try tryStrictSimpleLoadStream(std.testing.allocator, "truth: TRUE\nnothing: ~\n", .{ .schema = .core })).?;
    defer core.deinit();
    try std.testing.expect(core.documents[0].mapping.pairs[0].value.* == .bool_value);
    try std.testing.expectEqual(true, core.documents[0].mapping.pairs[0].value.bool_value.value);
    try std.testing.expect(core.documents[0].mapping.pairs[1].value.* == .null_value);

    var failsafe = (try tryStrictSimpleLoadStream(std.testing.allocator, "truth: TRUE\n", .{ .schema = .failsafe })).?;
    defer failsafe.deinit();
    try std.testing.expect(failsafe.documents[0].mapping.pairs[0].value.* == .scalar);
    try std.testing.expectEqualStrings("TRUE", failsafe.documents[0].mapping.pairs[0].value.scalar.value);

    var json = (try tryStrictSimpleLoadStream(std.testing.allocator, "true\n", .{ .schema = .json })).?;
    defer json.deinit();
    try std.testing.expect(json.documents[0].* == .bool_value);
    try std.testing.expectEqual(true, json.documents[0].bool_value.value);

    var diagnostic: diagnostics.Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, tryStrictSimpleLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected duplicate mapping key", diagnostic.message);

    var duplicate_allowed = (try tryStrictSimpleLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .duplicate_key_behavior = .allow,
    })).?;
    defer duplicate_allowed.deinit();
    try std.testing.expectEqual(@as(usize, 2), duplicate_allowed.documents[0].mapping.pairs.len);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: bb\n", .{
        .max_scalar_bytes = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_token_count = 5,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_event_count = 7,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_nesting_depth = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_document_count = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader exceeded configured document count limit", diagnostic.message);
}

test "strict simple load fast path preserves unknown tag behavior" {
    var preserved = (try tryStrictSimpleLoadStream(std.testing.allocator, "!local value\n", .{})) orelse return error.ExpectedDirectLoad;
    defer preserved.deinit();
    try std.testing.expect(preserved.documents[0].* == .scalar);
    try std.testing.expectEqualStrings("value", preserved.documents[0].scalar.value);
    try std.testing.expectEqualStrings("!local", preserved.documents[0].scalar.tag.?);

    var standard = (try tryStrictSimpleLoadStream(std.testing.allocator, "!!str true\n", .{})) orelse return error.ExpectedDirectLoad;
    defer standard.deinit();
    try std.testing.expect(standard.documents[0].* == .scalar);
    try std.testing.expectEqualStrings("true", standard.documents[0].scalar.value);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", standard.documents[0].scalar.tag.?);

    var diagnostic: diagnostics.Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, tryStrictSimpleLoadStream(std.testing.allocator, "!local value\n", .{
        .unknown_tag_behavior = .reject,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected unknown tag", diagnostic.message);
}

test "strict simple load fast path matches forced fallback malformed diagnostics" {
    const cases = [_][]const u8{
        "!!int not-int\n",
        "!!seq value\n",
        "!!binary SGVsbG8\n",
    };

    for (cases) |input| {
        const direct = try expectStrictSimpleLoadError(input);
        const fallback = try expectFallbackLoadError(input);

        try std.testing.expectEqual(fallback.err, direct.err);
        try std.testing.expectEqualStrings(fallback.diagnostic.message, direct.diagnostic.message);
        try std.testing.expectEqual(fallback.diagnostic.offset, direct.diagnostic.offset);
        try std.testing.expectEqual(fallback.diagnostic.line, direct.diagnostic.line);
        try std.testing.expectEqual(fallback.diagnostic.column, direct.diagnostic.column);
    }
}

const LoadErrorResult = struct {
    err: Error,
    diagnostic: diagnostics.Diagnostic,
};

fn expectStrictSimpleLoadError(input: []const u8) !LoadErrorResult {
    var diagnostic: diagnostics.Diagnostic = .{};
    if (tryStrictSimpleLoadStream(std.testing.allocator, input, .{ .diagnostic = &diagnostic })) |loaded| {
        var owned = loaded orelse return error.ExpectedDirectLoad;
        owned.deinit();
        return error.ExpectedLoadFailure;
    } else |err| {
        return .{ .err = err, .diagnostic = diagnostic };
    }
}

fn expectFallbackLoadError(input: []const u8) !LoadErrorResult {
    var diagnostic: diagnostics.Diagnostic = .{};
    if (loadStreamViaEvents(std.testing.allocator, input, .{ .diagnostic = &diagnostic })) |loaded| {
        var owned = loaded;
        owned.deinit();
        return error.ExpectedLoadFailure;
    } else |err| {
        return .{ .err = err, .diagnostic = diagnostic };
    }
}

fn expectLoadedStreamsEqual(actual: *const LoadedStream, expected: *const LoadedStream) !void {
    try std.testing.expectEqual(expected.documents.len, actual.documents.len);
    for (actual.documents, expected.documents) |actual_document, expected_document| {
        try expectNodesEqual(actual_document, expected_document);
    }
}

fn expectNodesEqual(actual: *const value.Node, expected: *const value.Node) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected.*), std.meta.activeTag(actual.*));
    switch (expected.*) {
        .null_value => |expected_value| try expectOptionalStringEqual(expected_value.tag, actual.null_value.tag),
        .bool_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.bool_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.bool_value.tag);
        },
        .int_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.int_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.int_value.tag);
        },
        .float_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.float_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.float_value.tag);
        },
        .scalar => |expected_value| {
            try std.testing.expectEqualStrings(expected_value.value, actual.scalar.value);
            try std.testing.expectEqual(expected_value.style, actual.scalar.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.scalar.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.scalar.tag);
        },
        .sequence => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.sequence.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.sequence.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.sequence.tag);
            try std.testing.expectEqual(expected_value.items.len, actual.sequence.items.len);
            for (actual.sequence.items, expected_value.items) |actual_item, expected_item| {
                try expectNodesEqual(actual_item, expected_item);
            }
        },
        .mapping => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.mapping.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.mapping.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.mapping.tag);
            try std.testing.expectEqual(expected_value.pairs.len, actual.mapping.pairs.len);
            for (actual.mapping.pairs, expected_value.pairs) |actual_pair, expected_pair| {
                try expectNodesEqual(actual_pair.key, expected_pair.key);
                try expectNodesEqual(actual_pair.value, expected_pair.value);
            }
        },
        .alias => |expected_alias| try std.testing.expectEqualStrings(expected_alias, actual.alias),
    }
}

fn expectOptionalStringEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |expected_value| {
        try std.testing.expectEqualStrings(expected_value, actual.?);
    }
}
