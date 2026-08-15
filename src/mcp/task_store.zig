//! Durable client state for the `io.modelcontextprotocol/tasks` extension.
//!
//! The protocol remains transport-neutral. Applications opt into persistence
//! by attaching a `Store` to an MCP client; the built-in `FileStore` uses one
//! versioned JSON document and atomic replacement.

const std = @import("std");
const builtin = @import("builtin");
const json_limits = @import("../json.zig");

pub const format_version: u64 = 1;

pub const Error = error{
    InvalidTaskStore,
    TaskStoreTooLarge,
};

/// One resumable task. `pending_input_responses_json` is an object that was
/// durably recorded before `tasks/update`; replaying it does not invoke the
/// application's input handler again.
pub const Record = struct {
    task_id: []const u8,
    answered_input_keys: []const []const u8 = &.{},
    pending_input_responses_json: ?[]const u8 = null,
};

/// Arena-owned snapshot of all resumable tasks.
pub const OwnedRecords = struct {
    arena: std.heap.ArenaAllocator,
    records: []const Record,

    pub fn deinit(self: *OwnedRecords) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Application-defined durable storage. Implementations must replace a record
/// atomically by task ID and make removal idempotent.
pub const Store = struct {
    context: *anyopaque,
    loadFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!OwnedRecords,
    saveFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, record: Record) anyerror!void,
    removeFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, task_id: []const u8) anyerror!void,

    pub fn load(self: Store, allocator: std.mem.Allocator) !OwnedRecords {
        return self.loadFn(self.context, allocator);
    }

    pub fn save(self: Store, allocator: std.mem.Allocator, record: Record) !void {
        if (record.task_id.len == 0) return error.InvalidTaskStore;
        return self.saveFn(self.context, allocator, record);
    }

    pub fn remove(self: Store, allocator: std.mem.Allocator, task_id: []const u8) !void {
        if (task_id.len == 0) return error.InvalidTaskStore;
        return self.removeFn(self.context, allocator, task_id);
    }
};

/// A concurrency-safe, atomically replaced file store. `path` and `dir` are
/// borrowed and must outlive the store.
pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    max_bytes: usize = 1024 * 1024,
    /// Task input can contain secrets, so POSIX files default to owner-only.
    permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600),
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, dir: std.Io.Dir, path: []const u8) FileStore {
        return .{ .io = io, .dir = dir, .path = path };
    }

    pub fn store(self: *FileStore) Store {
        return .{
            .context = self,
            .loadFn = load,
            .saveFn = save,
            .removeFn = remove,
        };
    }

    fn load(context: *anyopaque, allocator: std.mem.Allocator) !OwnedRecords {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loadUnlocked(allocator);
    }

    fn save(context: *anyopaque, allocator: std.mem.Allocator, record: Record) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var current = try self.loadUnlocked(allocator);
        defer current.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(allocator);
        try records.appendSlice(allocator, current.records);
        for (records.items) |*existing| {
            if (std.mem.eql(u8, existing.task_id, record.task_id)) {
                existing.* = record;
                return self.writeUnlocked(allocator, records.items);
            }
        }
        try records.append(allocator, record);
        return self.writeUnlocked(allocator, records.items);
    }

    fn remove(context: *anyopaque, allocator: std.mem.Allocator, task_id: []const u8) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var current = try self.loadUnlocked(allocator);
        defer current.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(allocator);
        for (current.records) |record| {
            if (!std.mem.eql(u8, record.task_id, task_id)) try records.append(allocator, record);
        }
        if (records.items.len == current.records.len) return;
        return self.writeUnlocked(allocator, records.items);
    }

    fn loadUnlocked(self: *FileStore, allocator: std.mem.Allocator) !OwnedRecords {
        if (self.path.len == 0) return error.InvalidTaskStore;
        var owned = OwnedRecords{
            .arena = .init(allocator),
            .records = &.{},
        };
        errdefer owned.arena.deinit();
        const source = self.dir.readFileAlloc(
            self.io,
            self.path,
            owned.arena.allocator(),
            .limited(self.max_bytes),
        ) catch |failure| switch (failure) {
            error.FileNotFound => return owned,
            error.StreamTooLong => return error.TaskStoreTooLarge,
            else => return failure,
        };
        const root = json_limits.parseLeaky(
            std.json.Value,
            owned.arena.allocator(),
            source,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidTaskStore,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidTaskStore,
        };
        const object = valueObject(root) catch return error.InvalidTaskStore;
        const version = switch (object.get("version") orelse return error.InvalidTaskStore) {
            .integer => |value| std.math.cast(u64, value) orelse return error.InvalidTaskStore,
            else => return error.InvalidTaskStore,
        };
        if (version != format_version) return error.InvalidTaskStore;
        const task_values = switch (object.get("tasks") orelse return error.InvalidTaskStore) {
            .array => |value| value,
            else => return error.InvalidTaskStore,
        };
        const records = try owned.arena.allocator().alloc(Record, task_values.items.len);
        for (task_values.items, 0..) |task_value, index| {
            records[index] = try parseRecord(owned.arena.allocator(), task_value);
            for (records[0..index]) |previous| {
                if (std.mem.eql(u8, previous.task_id, records[index].task_id))
                    return error.InvalidTaskStore;
            }
        }
        owned.records = records;
        return owned;
    }

    fn writeUnlocked(self: *FileStore, allocator: std.mem.Allocator, records: []const Record) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var task_values: std.json.Array = .init(memory);
        for (records) |record| {
            if (record.task_id.len == 0) return error.InvalidTaskStore;
            var object: std.json.ObjectMap = .{};
            try object.put(memory, "taskId", .{ .string = record.task_id });
            var answered: std.json.Array = .init(memory);
            for (record.answered_input_keys, 0..) |key, index| {
                if (key.len == 0) return error.InvalidTaskStore;
                for (record.answered_input_keys[0..index]) |previous| {
                    if (std.mem.eql(u8, previous, key)) return error.InvalidTaskStore;
                }
                try answered.append(.{ .string = key });
            }
            try object.put(memory, "answeredInputKeys", .{ .array = answered });
            const pending: std.json.Value = if (record.pending_input_responses_json) |source| blk: {
                const value = json_limits.parseLeaky(
                    std.json.Value,
                    memory,
                    source,
                    json_limits.defaults.mcp_message,
                    .{},
                    error.InvalidTaskStore,
                ) catch |failure| switch (failure) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidTaskStore,
                };
                if (value != .object) return error.InvalidTaskStore;
                break :blk value;
            } else .null;
            try object.put(memory, "pendingInputResponses", pending);
            try task_values.append(.{ .object = object });
        }
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = format_version,
            .tasks = std.json.Value{ .array = task_values },
        }, .{});
        defer allocator.free(json);
        if (json.len > self.max_bytes) return error.TaskStoreTooLarge;

        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{
            .make_path = true,
            .permissions = self.permissions,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(json);
        try writer.interface.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};

fn parseRecord(allocator: std.mem.Allocator, value: std.json.Value) !Record {
    const object = valueObject(value) catch return error.InvalidTaskStore;
    const task_id = switch (object.get("taskId") orelse return error.InvalidTaskStore) {
        .string => |string| string,
        else => return error.InvalidTaskStore,
    };
    if (task_id.len == 0) return error.InvalidTaskStore;
    const answered_values = switch (object.get("answeredInputKeys") orelse return error.InvalidTaskStore) {
        .array => |array| array,
        else => return error.InvalidTaskStore,
    };
    const answered = try allocator.alloc([]const u8, answered_values.items.len);
    for (answered_values.items, 0..) |answered_value, index| {
        answered[index] = switch (answered_value) {
            .string => |string| string,
            else => return error.InvalidTaskStore,
        };
        if (answered[index].len == 0) return error.InvalidTaskStore;
        for (answered[0..index]) |previous| {
            if (std.mem.eql(u8, previous, answered[index])) return error.InvalidTaskStore;
        }
    }
    const pending = switch (object.get("pendingInputResponses") orelse return error.InvalidTaskStore) {
        .null => null,
        .object => |pending_object| try std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .object = pending_object },
            .{},
        ),
        else => return error.InvalidTaskStore,
    };
    return .{
        .task_id = task_id,
        .answered_input_keys = answered,
        .pending_input_responses_json = pending,
    };
}

fn valueObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidTaskStore,
    };
}

test "file store atomically saves replaces removes and reloads task state" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_store = FileStore.init(std.testing.io, temporary.dir, "nested/tasks.json");
    const store_value = file_store.store();

    var empty = try store_value.load(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);

    try store_value.save(std.testing.allocator, .{
        .task_id = "task-1",
        .pending_input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
    });
    try store_value.save(std.testing.allocator, .{ .task_id = "task-2" });
    try store_value.save(std.testing.allocator, .{
        .task_id = "task-1",
        .answered_input_keys = &.{"approval"},
    });

    var loaded = try store_value.load(std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.records.len);
    try std.testing.expectEqualStrings("task-1", loaded.records[0].task_id);
    try std.testing.expectEqualStrings("approval", loaded.records[0].answered_input_keys[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.records[0].pending_input_responses_json);

    try store_value.remove(std.testing.allocator, "task-1");
    try store_value.remove(std.testing.allocator, "missing");
    var remaining = try store_value.load(std.testing.allocator);
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining.records.len);
    try std.testing.expectEqualStrings("task-2", remaining.records[0].task_id);
}

test "file store rejects malformed oversized and invalid records" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_store = FileStore.init(std.testing.io, temporary.dir, "tasks.json");
    const store_value = file_store.store();
    try std.testing.expectError(
        error.InvalidTaskStore,
        store_value.save(std.testing.allocator, .{ .task_id = "" }),
    );
    try std.testing.expectError(
        error.InvalidTaskStore,
        store_value.remove(std.testing.allocator, ""),
    );
    try std.testing.expectError(
        error.InvalidTaskStore,
        store_value.save(std.testing.allocator, .{
            .task_id = "task-1",
            .pending_input_responses_json = "[]",
        }),
    );
    try std.testing.expectError(
        error.InvalidTaskStore,
        store_value.save(std.testing.allocator, .{
            .task_id = "task-1",
            .answered_input_keys = &.{ "same", "same" },
        }),
    );
    try std.testing.expectError(
        error.InvalidTaskStore,
        store_value.save(std.testing.allocator, .{
            .task_id = "task-1",
            .pending_input_responses_json = "{",
        }),
    );

    const malformed_documents = [_][]const u8{
        "not-json",
        "{\"version\":1,\"tasks\":[{\"taskId\":\"same\",\"answeredInputKeys\":[],\"pendingInputResponses\":null},{\"taskId\":\"same\",\"answeredInputKeys\":[],\"pendingInputResponses\":null}]}",
        "{\"version\":1,\"tasks\":[{\"taskId\":\"task-1\",\"answeredInputKeys\":[\"same\",\"same\"],\"pendingInputResponses\":null}]}",
    };
    for (malformed_documents) |document| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tasks.json", .data = document });
        try std.testing.expectError(error.InvalidTaskStore, store_value.load(std.testing.allocator));
    }
    var empty_path = FileStore.init(std.testing.io, temporary.dir, "");
    try std.testing.expectError(error.InvalidTaskStore, empty_path.store().load(std.testing.allocator));

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tasks.json", .data = "123456789" });
    file_store.max_bytes = 8;
    try std.testing.expectError(
        error.TaskStoreTooLarge,
        store_value.load(std.testing.allocator),
    );
    file_store.max_bytes = 32;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tasks.json", .data = "{\"version\":1,\"tasks\":[]}" });
    try std.testing.expectError(
        error.TaskStoreTooLarge,
        store_value.save(std.testing.allocator, .{ .task_id = "task-1" }),
    );
}

test "file store releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            var file_store = FileStore.init(std.testing.io, temporary.dir, "tasks.json");
            const store_value = file_store.store();
            try store_value.save(allocator, .{
                .task_id = "task-1",
                .answered_input_keys = &.{"prior"},
                .pending_input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
            });
            var loaded = try store_value.load(allocator);
            defer loaded.deinit();
            try std.testing.expectEqual(@as(usize, 1), loaded.records.len);
            try store_value.save(allocator, .{ .task_id = "task-2" });
            try store_value.remove(allocator, "task-1");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
