//! Typed contracts for the `io.modelcontextprotocol/tasks` extension.
//!
//! Request values borrow application memory. Parsed task results own one arena;
//! every string and JSON value in `Owned` remains valid until `deinit`.

const std = @import("std");
const json_limits = @import("../json.zig");
const primitives = @import("primitives.zig");

pub const extension_identifier = "io.modelcontextprotocol/tasks";

pub const Error = error{
    InvalidTask,
    InvalidTaskRequest,
};

pub const Status = enum {
    working,
    input_required,
    completed,
    cancelled,
    failed,

    pub fn terminal(self: Status) bool {
        return switch (self) {
            .working, .input_required => false,
            .completed, .cancelled, .failed => true,
        };
    }
};

/// Metadata common to task-creation, polling, and notification payloads.
pub const Metadata = struct {
    task_id: []const u8,
    status_message: ?[]const u8,
    created_at: []const u8,
    last_updated_at: []const u8,
    /// Milliseconds from creation, or `null` when the task has no TTL.
    ttl_ms: ?u64,
    /// Server-suggested polling delay in milliseconds.
    poll_interval_ms: ?u64,
};

pub const JsonRpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value,
};

/// A status-specific task payload. JSON objects borrow the enclosing `Owned`
/// arena and must not outlive it.
pub const State = union(Status) {
    working: void,
    input_required: std.json.ObjectMap,
    completed: std.json.ObjectMap,
    cancelled: void,
    failed: JsonRpcError,
};

/// The seed returned instead of a synchronous tool result.
pub const CreatedTask = struct {
    metadata: Metadata,
    status: Status,
};

/// The complete state returned by `tasks/get` or `notifications/tasks`.
pub const DetailedTask = struct {
    metadata: Metadata,
    state: State,

    pub fn status(self: DetailedTask) Status {
        return std.meta.activeTag(self.state);
    }
};

pub const Value = union(enum) {
    created: CreatedTask,
    detailed: DetailedTask,
};

/// Arena-owned task result. Call `deinit` exactly once.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parameters shared by `tasks/get` and `tasks/cancel`.
pub const Request = struct {
    task_id: []const u8,

    pub fn stringifyAlloc(self: Request, allocator: std.mem.Allocator) ![]u8 {
        if (self.task_id.len == 0) return error.InvalidTaskRequest;
        return std.json.Stringify.valueAlloc(allocator, .{ .taskId = self.task_id }, .{});
    }
};

/// Parameters for `tasks/update`.
pub const UpdateRequest = struct {
    task_id: []const u8,
    /// MRTR response map encoded as one bounded JSON object.
    input_responses_json: []const u8,

    pub fn stringifyAlloc(self: UpdateRequest, allocator: std.mem.Allocator) ![]u8 {
        if (self.task_id.len == 0) return error.InvalidTaskRequest;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const responses = try parseObject(arena.allocator(), self.input_responses_json, error.InvalidTaskRequest);
        var iterator = responses.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* != .object)
            return error.InvalidTaskRequest;
        return std.json.Stringify.valueAlloc(allocator, .{
            .taskId = self.task_id,
            .inputResponses = std.json.Value{ .object = responses },
        }, .{});
    }
};

/// Parses the `resultType: "task"` result returned when a task is created.
pub fn parseCreated(allocator: std.mem.Allocator, source: []const u8) !Owned {
    var owned = Owned{ .arena = .init(allocator), .value = undefined };
    errdefer owned.arena.deinit();
    const object = try parseObject(owned.arena.allocator(), source, error.InvalidTask);
    try expectResultType(object, "task");
    const common = try parseCommon(object);
    owned.value = .{ .created = .{
        .metadata = common.metadata,
        .status = common.status,
    } };
    return owned;
}

/// Parses a `tasks/get` result, or a `notifications/tasks` parameter object when
/// `has_result_type` is false.
pub fn parseDetailed(
    allocator: std.mem.Allocator,
    source: []const u8,
    has_result_type: bool,
) !Owned {
    var owned = Owned{ .arena = .init(allocator), .value = undefined };
    errdefer owned.arena.deinit();
    const object = try parseObject(owned.arena.allocator(), source, error.InvalidTask);
    if (has_result_type) try expectResultType(object, "complete");
    const common = try parseCommon(object);
    owned.value = .{ .detailed = .{
        .metadata = common.metadata,
        .state = try parseState(object, common.status),
    } };
    return owned;
}

const Common = struct {
    metadata: Metadata,
    status: Status,
};

fn parseCommon(object: std.json.ObjectMap) !Common {
    const task_id = try requiredString(object, "taskId");
    if (task_id.len == 0) return error.InvalidTask;
    const status = std.meta.stringToEnum(Status, try requiredString(object, "status")) orelse
        return error.InvalidTask;
    return .{
        .metadata = .{
            .task_id = task_id,
            .status_message = try optionalString(object, "statusMessage"),
            .created_at = try requiredString(object, "createdAt"),
            .last_updated_at = try requiredString(object, "lastUpdatedAt"),
            .ttl_ms = try nullableUnsigned(object, "ttlMs"),
            .poll_interval_ms = try optionalUnsigned(object, "pollIntervalMs"),
        },
        .status = status,
    };
}

fn parseState(object: std.json.ObjectMap, status: Status) !State {
    return switch (status) {
        .working => blk: {
            try rejectPayload(object);
            break :blk .{ .working = {} };
        },
        .input_required => blk: {
            if (object.get("result") != null or object.get("error") != null) return error.InvalidTask;
            const requests = try requiredObject(object, "inputRequests");
            var iterator = requests.iterator();
            while (iterator.next()) |entry| {
                const request = switch (entry.value_ptr.*) {
                    .object => |value| value,
                    else => return error.InvalidTask,
                };
                _ = primitives.InputKind.fromMethod(try requiredString(request, "method")) catch
                    return error.InvalidTask;
                if (request.get("params")) |params| if (params != .object) return error.InvalidTask;
            }
            break :blk .{ .input_required = requests };
        },
        .completed => blk: {
            if (object.get("inputRequests") != null or object.get("error") != null) return error.InvalidTask;
            break :blk .{ .completed = try requiredObject(object, "result") };
        },
        .cancelled => blk: {
            try rejectPayload(object);
            break :blk .{ .cancelled = {} };
        },
        .failed => blk: {
            if (object.get("inputRequests") != null or object.get("result") != null) return error.InvalidTask;
            const rpc_error = try requiredObject(object, "error");
            break :blk .{ .failed = .{
                .code = try requiredInteger(rpc_error, "code"),
                .message = try requiredString(rpc_error, "message"),
                .data = rpc_error.get("data"),
            } };
        },
    };
}

fn rejectPayload(object: std.json.ObjectMap) !void {
    if (object.get("inputRequests") != null or object.get("result") != null or
        object.get("error") != null) return error.InvalidTask;
}

fn expectResultType(object: std.json.ObjectMap, expected: []const u8) !void {
    if (!std.mem.eql(u8, try requiredString(object, "resultType"), expected)) return error.InvalidTask;
}

fn parseObject(
    allocator: std.mem.Allocator,
    source: []const u8,
    comptime invalid_error: anytype,
) !std.json.ObjectMap {
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.mcp_message,
        .{ .allocate = .alloc_always },
        invalid_error,
    );
    return switch (value) {
        .object => |object| object,
        else => invalid_error,
    };
}

fn requiredObject(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (object.get(name) orelse return error.InvalidTask) {
        .object => |value| value,
        else => error.InvalidTask,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.InvalidTask) {
        .string => |value| value,
        else => error.InvalidTask,
    };
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |value| value,
        else => error.InvalidTask,
    };
}

fn requiredInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return error.InvalidTask) {
        .integer => |value| value,
        else => error.InvalidTask,
    };
}

fn nullableUnsigned(object: std.json.ObjectMap, name: []const u8) !?u64 {
    return switch (object.get(name) orelse return error.InvalidTask) {
        .null => null,
        .integer => |value| if (value >= 0) @intCast(value) else error.InvalidTask,
        else => error.InvalidTask,
    };
}

fn optionalUnsigned(object: std.json.ObjectMap, name: []const u8) !?u64 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| if (value >= 0) @intCast(value) else error.InvalidTask,
        else => error.InvalidTask,
    };
}

test "task requests serialize bounded parameters" {
    const get = try (Request{ .task_id = "task-1" }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(get);
    try std.testing.expectEqualStrings("{\"taskId\":\"task-1\"}", get);

    const update = try (UpdateRequest{
        .task_id = "task-1",
        .input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(update);
    try std.testing.expectEqualStrings(
        "{\"taskId\":\"task-1\",\"inputResponses\":{\"approval\":{\"action\":\"accept\"}}}",
        update,
    );
}

test "task requests reject empty identifiers and malformed responses" {
    try std.testing.expectError(
        error.InvalidTaskRequest,
        (Request{ .task_id = "" }).stringifyAlloc(std.testing.allocator),
    );
    const invalid = [_][]const u8{ "[]", "{", "{\"key\":true}" };
    for (invalid) |source| try std.testing.expectError(
        error.InvalidTaskRequest,
        (UpdateRequest{ .task_id = "task", .input_responses_json = source }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidTaskRequest,
        (UpdateRequest{ .task_id = "", .input_responses_json = "{}" }).stringifyAlloc(std.testing.allocator),
    );
}

test "created task parsing owns metadata and exposes every status" {
    const statuses = [_]Status{ .working, .input_required, .completed, .cancelled, .failed };
    for (statuses) |status| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"resultType\":\"task\",\"taskId\":\"task-{s}\",\"status\":\"{s}\"," ++
                "\"statusMessage\":\"ready\",\"createdAt\":\"2026-08-15T10:00:00Z\"," ++
                "\"lastUpdatedAt\":\"2026-08-15T10:01:00Z\",\"ttlMs\":null,\"pollIntervalMs\":250}}",
            .{ @tagName(status), @tagName(status) },
        );
        defer std.testing.allocator.free(source);
        var owned = try parseCreated(std.testing.allocator, source);
        defer owned.deinit();
        const task = owned.value.created;
        try std.testing.expectEqual(status, task.status);
        try std.testing.expectEqualStrings("ready", task.metadata.status_message.?);
        try std.testing.expectEqual(@as(?u64, null), task.metadata.ttl_ms);
        try std.testing.expectEqual(@as(?u64, 250), task.metadata.poll_interval_ms);
    }
}

test "detailed task parsing enforces status-specific payloads" {
    const cases = [_]struct {
        source: []const u8,
        status: Status,
    }{
        .{ .status = .working, .source = "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":100}" },
        .{ .status = .input_required, .source = "{\"resultType\":\"complete\",\"taskId\":\"b\",\"status\":\"input_required\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":100,\"inputRequests\":{\"approval\":{\"method\":\"elicitation/create\",\"params\":{}}}}" },
        .{ .status = .completed, .source = "{\"resultType\":\"complete\",\"taskId\":\"c\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":100,\"result\":{\"content\":[]}}" },
        .{ .status = .cancelled, .source = "{\"resultType\":\"complete\",\"taskId\":\"d\",\"status\":\"cancelled\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":null}" },
        .{ .status = .failed, .source = "{\"resultType\":\"complete\",\"taskId\":\"e\",\"status\":\"failed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":100,\"error\":{\"code\":-32603,\"message\":\"failed\",\"data\":{\"retry\":false}}}" },
    };
    for (cases) |case| {
        var owned = try parseDetailed(std.testing.allocator, case.source, true);
        defer owned.deinit();
        const task = owned.value.detailed;
        try std.testing.expectEqual(case.status, task.status());
        try std.testing.expectEqual(case.status.terminal(), task.status().terminal());
    }

    var notification = try parseDetailed(
        std.testing.allocator,
        "{\"taskId\":\"n\",\"status\":\"failed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"error\":{\"code\":-1,\"message\":\"no\"}}",
        false,
    );
    defer notification.deinit();
    const failure = notification.value.detailed.state.failed;
    try std.testing.expectEqual(@as(i64, -1), failure.code);
    try std.testing.expect(failure.data == null);
}

test "task parsing rejects malformed metadata and payload combinations" {
    const invalid = [_][]const u8{
        "[]",
        "{\"resultType\":\"complete\"}",
        "{\"resultType\":\"task\",\"taskId\":\"\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"unknown\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"statusMessage\":1,\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":1,\"lastUpdatedAt\":\"now\",\"ttlMs\":0}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":1,\"ttlMs\":0}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":-1}",
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"pollIntervalMs\":-1}",
    };
    for (invalid) |source| try std.testing.expectError(
        error.InvalidTask,
        parseCreated(std.testing.allocator, source),
    );

    const invalid_details = [_][]const u8{
        "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"result\":{}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"input_required\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"inputRequests\":[]}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"input_required\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"inputRequests\":{\"x\":true}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"input_required\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"inputRequests\":{\"x\":{\"method\":\"unknown\"}}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"input_required\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"inputRequests\":{\"x\":{\"method\":\"roots/list\",\"params\":[]}}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"result\":[],\"error\":{}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"cancelled\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"error\":{}}",
        "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"failed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0,\"error\":{\"code\":\"x\",\"message\":1}}",
    };
    for (invalid_details) |source| try std.testing.expectError(
        error.InvalidTask,
        parseDetailed(std.testing.allocator, source, true),
    );
}

test "task parsing and serialization release partial allocations" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const update = try (UpdateRequest{
                .task_id = "task",
                .input_responses_json = "{\"a\":{\"action\":\"accept\",\"content\":{\"ok\":true}}}",
            }).stringifyAlloc(allocator);
            defer allocator.free(update);
            var task = try parseDetailed(
                allocator,
                "{\"resultType\":\"complete\",\"taskId\":\"task\",\"status\":\"input_required\",\"statusMessage\":\"waiting\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"pollIntervalMs\":10,\"inputRequests\":{\"a\":{\"method\":\"elicitation/create\",\"params\":{}}}}",
                true,
            );
            defer task.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
