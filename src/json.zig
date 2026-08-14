//! Allocation bounds for JSON received from untrusted peers.
//!
//! `validate` scans a complete document before callers allocate its value graph.
//! It borrows the source and retains no state after returning.

const std = @import("std");

/// Stable failures reported while enforcing an untrusted JSON boundary.
pub const ValidationError = error{
    /// The complete encoded document exceeds `Limits.max_document_bytes`.
    DocumentTooLarge,
    /// One string or number exceeds `Limits.max_value_bytes` after decoding.
    ValueTooLarge,
    /// Array or object nesting exceeds `Limits.max_depth`.
    NestingTooDeep,
    /// One array or object exceeds `Limits.max_collection_items`.
    CollectionTooLarge,
    /// The source is not one complete JSON document.
    InvalidJson,
};

/// Independent limits checked before a JSON value graph is allocated.
pub const Limits = struct {
    /// Maximum bytes in the complete encoded document.
    max_document_bytes: usize,
    /// Maximum decoded bytes in one string or encoded bytes in one number.
    max_value_bytes: usize,
    /// Maximum nested array and object containers, including the root.
    max_depth: usize,
    /// Maximum elements in one array or fields in one object.
    max_collection_items: usize,
};

/// Reviewed defaults for each untrusted JSON boundary in ZigAI.
pub const defaults = struct {
    /// Persisted reusable message history.
    pub const history: Limits = .{
        .max_document_bytes = 16 * 1024 * 1024,
        .max_value_bytes = 1024 * 1024,
        .max_depth = 64,
        .max_collection_items = 65_536,
    };

    /// Paused agent state, whose history is stored as one encoded string.
    pub const paused_state: Limits = .{
        .max_document_bytes = 32 * 1024 * 1024,
        .max_value_bytes = 16 * 1024 * 1024,
        .max_depth = 64,
        .max_collection_items = 65_536,
    };

    /// Decisions supplied when a paused run resumes.
    pub const resume_decisions: Limits = .{
        .max_document_bytes = 4 * 1024 * 1024,
        .max_value_bytes = 1024 * 1024,
        .max_depth = 32,
        .max_collection_items = 16_384,
    };

    /// One buffered provider response or streaming provider event.
    pub const provider_response: Limits = .{
        .max_document_bytes = 16 * 1024 * 1024,
        .max_value_bytes = 4 * 1024 * 1024,
        .max_depth = 128,
        .max_collection_items = 65_536,
    };

    /// Tool arguments, structured tool results, and typed agent output.
    pub const tool_payload: Limits = .{
        .max_document_bytes = 1024 * 1024,
        .max_value_bytes = 1024 * 1024,
        .max_depth = 64,
        .max_collection_items = 4096,
    };

    /// One MCP JSON-RPC request, response, notification, or SSE event.
    pub const mcp_message: Limits = .{
        .max_document_bytes = 4 * 1024 * 1024,
        .max_value_bytes = 1024 * 1024,
        .max_depth = 64,
        .max_collection_items = 16_384,
    };

    /// A provider-facing or tool-facing JSON Schema document.
    pub const schema: Limits = .{
        .max_document_bytes = 2 * 1024 * 1024,
        .max_value_bytes = 512 * 1024,
        .max_depth = 64,
        .max_collection_items = 16_384,
    };

    /// A local CLI tool manifest.
    pub const cli_config: Limits = .{
        .max_document_bytes = 1024 * 1024,
        .max_value_bytes = 256 * 1024,
        .max_depth = 32,
        .max_collection_items = 4096,
    };
};

const ContainerKind = enum {
    array,
    object,
};

const Frame = struct {
    kind: ContainerKind,
    item_count: usize = 0,
    object_expects_value: bool = false,
};

/// Validates syntax and allocation limits without retaining or constructing a
/// JSON value graph. Temporary scanner allocations use `gpa` and are released
/// before this function returns.
pub fn validate(gpa: std.mem.Allocator, source: []const u8, limits: Limits) (ValidationError || std.mem.Allocator.Error)!void {
    if (source.len > limits.max_document_bytes) return error.DocumentTooLarge;

    var scanner = std.json.Scanner.initCompleteInput(gpa, source);
    defer scanner.deinit();
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);

    while (true) {
        const token = scanner.nextAllocMax(gpa, .alloc_if_needed, limits.max_value_bytes) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.ValueTooLarge,
            else => return error.InvalidJson,
        };
        defer freeToken(gpa, token);

        switch (token) {
            .object_begin => {
                try consumeValue(&frames, limits.max_collection_items);
                if (frames.items.len >= limits.max_depth) return error.NestingTooDeep;
                try frames.append(gpa, .{ .kind = .object });
            },
            .array_begin => {
                try consumeValue(&frames, limits.max_collection_items);
                if (frames.items.len >= limits.max_depth) return error.NestingTooDeep;
                try frames.append(gpa, .{ .kind = .array });
            },
            .object_end => {
                const frame = frames.pop().?;
                std.debug.assert(frame.kind == .object and !frame.object_expects_value);
            },
            .array_end => {
                const frame = frames.pop().?;
                std.debug.assert(frame.kind == .array);
            },
            .string, .allocated_string => |value| {
                if (value.len > limits.max_value_bytes) return error.ValueTooLarge;
                try consumeString(&frames, limits.max_collection_items);
            },
            .number, .allocated_number => |value| {
                if (value.len > limits.max_value_bytes) return error.ValueTooLarge;
                try consumeValue(&frames, limits.max_collection_items);
            },
            .true, .false, .null => try consumeValue(&frames, limits.max_collection_items),
            .end_of_document => return,
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => unreachable, // Complete-input allocation never emits partial tokens.
        }
    }
}

/// Validates one document while mapping every syntax or policy failure to the
/// caller's stable domain error. Allocation failure is always preserved.
pub fn validateAs(
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    comptime invalid_error: anytype,
) (@TypeOf(invalid_error) || std.mem.Allocator.Error)!void {
    validate(gpa, source, limits) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid_error,
    };
}

/// Returns whether `source` is one valid document within `limits`. Allocation
/// failure remains distinguishable from an invalid or oversized document.
pub fn isValid(gpa: std.mem.Allocator, source: []const u8, limits: Limits) std.mem.Allocator.Error!bool {
    validate(gpa, source, limits) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}

/// Preflights one document, then parses an owned value graph. Syntax, policy,
/// and type-shape failures are mapped to the caller's stable domain error.
pub fn parse(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    options: std.json.ParseOptions,
    comptime invalid_error: anytype,
) (@TypeOf(invalid_error) || std.mem.Allocator.Error)!std.json.Parsed(T) {
    try validateAs(gpa, source, limits, invalid_error);
    return std.json.parseFromSlice(T, gpa, source, options) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid_error,
    };
}

/// Preflights one document, then parses a value graph owned by `gpa` without a
/// deinitialization wrapper. This is intended for arena allocators.
pub fn parseLeaky(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    options: std.json.ParseOptions,
    comptime invalid_error: anytype,
) (@TypeOf(invalid_error) || std.mem.Allocator.Error)!T {
    try validateAs(gpa, source, limits, invalid_error);
    return std.json.parseFromSliceLeaky(T, gpa, source, options) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid_error,
    };
}

fn consumeString(frames: *std.ArrayList(Frame), maximum_items: usize) ValidationError!void {
    if (frames.items.len == 0) return;
    const frame = &frames.items[frames.items.len - 1];
    if (frame.kind == .object and !frame.object_expects_value) {
        try incrementCollection(frame, maximum_items);
        frame.object_expects_value = true;
        return;
    }
    try consumeValue(frames, maximum_items);
}

fn consumeValue(frames: *std.ArrayList(Frame), maximum_items: usize) ValidationError!void {
    if (frames.items.len == 0) return;
    const frame = &frames.items[frames.items.len - 1];
    switch (frame.kind) {
        .array => try incrementCollection(frame, maximum_items),
        .object => {
            std.debug.assert(frame.object_expects_value);
            frame.object_expects_value = false;
        },
    }
}

fn incrementCollection(frame: *Frame, maximum_items: usize) ValidationError!void {
    if (frame.item_count >= maximum_items) return error.CollectionTooLarge;
    frame.item_count += 1;
}

fn freeToken(gpa: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |value| gpa.free(value),
        else => {},
    }
}

test "validate accepts exact document value depth and collection boundaries" {
    const source = "{\"one\":[1,2]}";
    const limits = Limits{
        .max_document_bytes = source.len,
        .max_value_bytes = 3,
        .max_depth = 2,
        .max_collection_items = 2,
    };
    try validate(std.testing.allocator, source, limits);
    try validate(std.testing.allocator, "\"ok\"", limits);
    try validate(std.testing.allocator, "true", limits);
}

test "validate reports every configured boundary" {
    const limits = Limits{
        .max_document_bytes = 8,
        .max_value_bytes = 2,
        .max_depth = 2,
        .max_collection_items = 2,
    };
    try std.testing.expectError(error.DocumentTooLarge, validate(std.testing.allocator, "[1,2,3,4]", limits));
    try std.testing.expectError(error.ValueTooLarge, validate(std.testing.allocator, "\"abc\"", limits));
    try std.testing.expectError(error.ValueTooLarge, validate(std.testing.allocator, "\"\\u0061\\u0062\\u0063\"", .{
        .max_document_bytes = 32,
        .max_value_bytes = 2,
        .max_depth = 2,
        .max_collection_items = 2,
    }));
    try std.testing.expectError(error.NestingTooDeep, validate(std.testing.allocator, "[[[]]]", limits));
    try std.testing.expectError(error.CollectionTooLarge, validate(std.testing.allocator, "[1,2,3]", limits));
    try std.testing.expectError(error.CollectionTooLarge, validate(std.testing.allocator, "{\"a\":1,\"b\":2,\"c\":3}", .{
        .max_document_bytes = 32,
        .max_value_bytes = 2,
        .max_depth = 2,
        .max_collection_items = 2,
    }));
}

test "validate rejects malformed and incomplete documents" {
    const limits = defaults.tool_payload;
    try std.testing.expectError(error.InvalidJson, validate(std.testing.allocator, "{", limits));
    try std.testing.expectError(error.InvalidJson, validate(std.testing.allocator, "[] []", limits));
    try std.testing.expectError(error.InvalidJson, validate(std.testing.allocator, "{\"a\"}", limits));
}

test "validate releases temporary allocations on every failure" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            try validate(gpa, "{\"escaped\":\"line\\nvalue\",\"nested\":[{\"ok\":true}]}", defaults.tool_payload);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "validateAs maps policy failures and preserves allocation failures" {
    try std.testing.expectError(
        error.InvalidPayload,
        validateAs(std.testing.allocator, "{", defaults.tool_payload, error.InvalidPayload),
    );

    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            try validateAs(
                gpa,
                "{\"escaped\":\"line\\nvalue\"}",
                defaults.tool_payload,
                error.InvalidPayload,
            );
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "isValid distinguishes invalid JSON from allocation failure" {
    try std.testing.expect(try isValid(std.testing.allocator, "{}", defaults.tool_payload));
    try std.testing.expect(!try isValid(std.testing.allocator, "{", defaults.tool_payload));

    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            if (!try isValid(gpa, "{\"escaped\":\"line\\nvalue\"}", defaults.tool_payload)) {
                return error.UnexpectedInvalidJson;
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "bounded parsers map type-shape failures and preserve allocation failures" {
    const Payload = struct { ok: bool };
    try std.testing.expectError(
        error.InvalidPayload,
        parse(Payload, std.testing.allocator, "{\"ok\":1}", defaults.tool_payload, .{}, error.InvalidPayload),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        parseLeaky(Payload, std.testing.allocator, "{\"ok\":1}", defaults.tool_payload, .{}, error.InvalidPayload),
    );

    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const parsed = try parse(
                Payload,
                gpa,
                "{\"ok\":true}",
                defaults.tool_payload,
                .{},
                error.InvalidPayload,
            );
            parsed.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
