//! Restart-safe state for durable agent stream segments and approvals.
//!
//! Checkpoints are separate from operation records: an operation record owns
//! one side effect, while a checkpoint records how far application code has
//! consumed a replay. Stores use monotonic revisions and reject divergent
//! duplicate writes.

const std = @import("std");
const builtin = @import("builtin");
const json_limits = @import("../json.zig");

pub const format_version: u8 = 2;
pub const max_identifier_bytes: usize = 128;
pub const max_state_bytes: usize = 2 * 1024 * 1024;

pub const Error = error{
    InvalidCheckpoint,
    CheckpointTooLarge,
    CheckpointConflict,
    StaleCheckpoint,
    UnsupportedCheckpointVersion,
};

pub const Kind = enum {
    stream,
    approval,
};

/// One immutable checkpoint revision. `cursor` is the number of stream events
/// already delivered; approval checkpoints keep it at zero.
pub const Record = struct {
    run_id: []const u8,
    checkpoint_id: []const u8,
    kind: Kind,
    revision: u64,
    cursor: u64 = 0,
    state_json: []const u8,

    pub fn validate(self: Record, allocator: std.mem.Allocator) !void {
        if (!validIdentifier(self.run_id) or !validIdentifier(self.checkpoint_id))
            return Error.InvalidCheckpoint;
        if (self.revision == 0) return Error.InvalidCheckpoint;
        if (self.kind == .approval and self.cursor != 0) return Error.InvalidCheckpoint;
        try validateState(allocator, self.state_json);
    }
};

pub const OwnedRecord = struct {
    arena: std.heap.ArenaAllocator,
    value: Record,

    pub fn deinit(self: *OwnedRecord) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SaveResult = enum {
    created,
    advanced,
    duplicate,
};

/// Application-defined checkpoint storage. Implementations atomically compare
/// and replace one `(run_id, checkpoint_id)` record. Equal writes are
/// idempotent; stale or divergent equal-revision writes fail closed.
pub const Store = struct {
    context: *anyopaque,
    loadFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) anyerror!?OwnedRecord,
    saveFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record: Record,
    ) anyerror!SaveResult,
    removeFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) anyerror!void,

    pub fn load(
        self: Store,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) !?OwnedRecord {
        if (!validIdentifier(run_id) or !validIdentifier(checkpoint_id))
            return Error.InvalidCheckpoint;
        return self.loadFn(self.context, allocator, run_id, checkpoint_id);
    }

    pub fn save(self: Store, allocator: std.mem.Allocator, record: Record) !SaveResult {
        try record.validate(allocator);
        return self.saveFn(self.context, allocator, record);
    }

    pub fn remove(
        self: Store,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) !void {
        if (!validIdentifier(run_id) or !validIdentifier(checkpoint_id))
            return Error.InvalidCheckpoint;
        return self.removeFn(self.context, allocator, run_id, checkpoint_id);
    }
};

/// A concurrency-safe file store using one bounded JSON snapshot and atomic
/// replacement. `dir` and `path` are borrowed and must outlive the store.
pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    max_bytes: usize = 4 * 1024 * 1024,
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

    fn load(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) !?OwnedRecord {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var snapshot = try self.loadUnlocked(allocator);
        errdefer snapshot.deinit();
        for (snapshot.records) |record| {
            if (sameKey(record, run_id, checkpoint_id)) return .{
                .arena = snapshot.arena,
                .value = record,
            };
        }
        snapshot.deinit();
        return null;
    }

    fn save(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record: Record,
    ) !SaveResult {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var snapshot = try self.loadUnlocked(allocator);
        defer snapshot.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(allocator);
        try records.appendSlice(allocator, snapshot.records);
        for (records.items) |*existing| {
            if (!sameKey(existing.*, record.run_id, record.checkpoint_id)) continue;
            if (record.revision < existing.revision) return Error.StaleCheckpoint;
            if (record.revision == existing.revision) {
                if (!sameRecord(existing.*, record)) return Error.CheckpointConflict;
                return .duplicate;
            }
            if (record.kind != existing.kind or record.cursor < existing.cursor)
                return Error.CheckpointConflict;
            existing.* = record;
            try self.writeUnlocked(allocator, records.items);
            return .advanced;
        }
        try records.append(allocator, record);
        try self.writeUnlocked(allocator, records.items);
        return .created;
    }

    fn remove(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        checkpoint_id: []const u8,
    ) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var snapshot = try self.loadUnlocked(allocator);
        defer snapshot.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(allocator);
        for (snapshot.records) |record| {
            if (!sameKey(record, run_id, checkpoint_id)) try records.append(allocator, record);
        }
        if (records.items.len == snapshot.records.len) return;
        try self.writeUnlocked(allocator, records.items);
    }

    const Snapshot = struct {
        arena: std.heap.ArenaAllocator,
        records: []const Record,

        fn deinit(self: *Snapshot) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    fn loadUnlocked(self: *FileStore, allocator: std.mem.Allocator) !Snapshot {
        if (self.path.len == 0) return Error.InvalidCheckpoint;
        var snapshot = Snapshot{ .arena = .init(allocator), .records = &.{} };
        errdefer snapshot.arena.deinit();
        const source = self.dir.readFileAlloc(
            self.io,
            self.path,
            snapshot.arena.allocator(),
            .limited(self.max_bytes),
        ) catch |failure| switch (failure) {
            error.FileNotFound => return snapshot,
            error.StreamTooLong => return Error.CheckpointTooLarge,
            else => return failure,
        };
        const root = json_limits.parseLeaky(
            std.json.Value,
            snapshot.arena.allocator(),
            source,
            json_limits.defaults.paused_state,
            .{},
            Error.InvalidCheckpoint,
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => Error.InvalidCheckpoint,
        };
        const object = valueObject(root) catch return Error.InvalidCheckpoint;
        if (object.count() != 2) return Error.InvalidCheckpoint;
        const version = valueU8(object.get("version") orelse return Error.InvalidCheckpoint) catch
            return Error.InvalidCheckpoint;
        if (version != 1 and version != format_version)
            return Error.UnsupportedCheckpointVersion;
        const values = switch (object.get("checkpoints") orelse return Error.InvalidCheckpoint) {
            .array => |array| array,
            else => return Error.InvalidCheckpoint,
        };
        const records = try snapshot.arena.allocator().alloc(Record, values.items.len);
        for (values.items, 0..) |value, index| {
            records[index] = if (version == 1)
                try parseV1(snapshot.arena.allocator(), value)
            else
                try parseV2(snapshot.arena.allocator(), value);
            try records[index].validate(snapshot.arena.allocator());
            for (records[0..index]) |previous| {
                if (sameKey(previous, records[index].run_id, records[index].checkpoint_id))
                    return Error.InvalidCheckpoint;
            }
        }
        snapshot.records = records;
        return snapshot;
    }

    fn writeUnlocked(self: *FileStore, allocator: std.mem.Allocator, records: []const Record) !void {
        for (records) |record| try record.validate(allocator);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = format_version,
            .checkpoints = records,
        }, .{});
        defer allocator.free(json);
        if (json.len > self.max_bytes) return Error.CheckpointTooLarge;
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

fn parseV2(_: std.mem.Allocator, value: std.json.Value) !Record {
    const object = valueObject(value) catch return Error.InvalidCheckpoint;
    if (object.count() != 6) return Error.InvalidCheckpoint;
    return .{
        .run_id = try valueString(object.get("run_id") orelse return Error.InvalidCheckpoint),
        .checkpoint_id = try valueString(object.get("checkpoint_id") orelse return Error.InvalidCheckpoint),
        .kind = try valueKind(object.get("kind") orelse return Error.InvalidCheckpoint),
        .revision = try valueU64(object.get("revision") orelse return Error.InvalidCheckpoint),
        .cursor = try valueU64(object.get("cursor") orelse return Error.InvalidCheckpoint),
        .state_json = try valueString(object.get("state_json") orelse return Error.InvalidCheckpoint),
    };
}

/// Version 1 used `event_cursor` and `payload_json`. Loading migrates it to the
/// current in-memory shape; the next successful save rewrites version 2.
fn parseV1(_: std.mem.Allocator, value: std.json.Value) !Record {
    const object = valueObject(value) catch return Error.InvalidCheckpoint;
    if (object.count() != 6) return Error.InvalidCheckpoint;
    return .{
        .run_id = try valueString(object.get("run_id") orelse return Error.InvalidCheckpoint),
        .checkpoint_id = try valueString(object.get("checkpoint_id") orelse return Error.InvalidCheckpoint),
        .kind = try valueKind(object.get("kind") orelse return Error.InvalidCheckpoint),
        .revision = try valueU64(object.get("revision") orelse return Error.InvalidCheckpoint),
        .cursor = try valueU64(object.get("event_cursor") orelse return Error.InvalidCheckpoint),
        .state_json = try valueString(object.get("payload_json") orelse return Error.InvalidCheckpoint),
    };
}

fn sameKey(record: Record, run_id: []const u8, checkpoint_id: []const u8) bool {
    return std.mem.eql(u8, record.run_id, run_id) and
        std.mem.eql(u8, record.checkpoint_id, checkpoint_id);
}

fn sameRecord(left: Record, right: Record) bool {
    return left.kind == right.kind and left.revision == right.revision and
        left.cursor == right.cursor and std.mem.eql(u8, left.state_json, right.state_json);
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > max_identifier_bytes) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

fn validateState(allocator: std.mem.Allocator, source: []const u8) !void {
    if (source.len == 0 or source.len > max_state_bytes) return Error.CheckpointTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{
        .max_value_len = max_state_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidCheckpoint,
    };
    defer parsed.deinit();
}

fn valueObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => Error.InvalidCheckpoint,
    };
}

fn valueString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => Error.InvalidCheckpoint,
    };
}

fn valueKind(value: std.json.Value) !Kind {
    const string = try valueString(value);
    return std.meta.stringToEnum(Kind, string) orelse Error.InvalidCheckpoint;
}

fn valueU8(value: std.json.Value) !u8 {
    return std.math.cast(u8, try valueU64(value)) orelse Error.InvalidCheckpoint;
}

fn valueU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| std.math.cast(u64, integer) orelse Error.InvalidCheckpoint,
        else => Error.InvalidCheckpoint,
    };
}

test "file store survives restart and rejects divergent duplicate delivery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first = FileStore.init(std.testing.io, temporary.dir, "state/checkpoints.json");
    const original = Record{
        .run_id = "run-1",
        .checkpoint_id = "model-stream-1",
        .kind = .stream,
        .revision = 1,
        .cursor = 2,
        .state_json = "{}",
    };
    try std.testing.expectEqual(SaveResult.created, try first.store().save(std.testing.allocator, original));
    try std.testing.expectEqual(SaveResult.duplicate, try first.store().save(std.testing.allocator, original));
    var conflict = original;
    conflict.cursor = 3;
    try std.testing.expectError(Error.CheckpointConflict, first.store().save(std.testing.allocator, conflict));
    var changed_kind = original;
    changed_kind.kind = .approval;
    changed_kind.cursor = 0;
    changed_kind.revision = 2;
    try std.testing.expectError(Error.CheckpointConflict, first.store().save(std.testing.allocator, changed_kind));

    var restarted = FileStore.init(std.testing.io, temporary.dir, "state/checkpoints.json");
    var loaded = (try restarted.store().load(std.testing.allocator, "run-1", "model-stream-1")).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 2), loaded.value.cursor);
    var advanced = original;
    advanced.revision = 2;
    advanced.cursor = 3;
    try std.testing.expectEqual(SaveResult.advanced, try restarted.store().save(std.testing.allocator, advanced));
    try std.testing.expectError(Error.StaleCheckpoint, restarted.store().save(std.testing.allocator, original));
}

test "version one checkpoint snapshots migrate on load and rewrite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const fixture =
        \\{"version":1,"checkpoints":[{"run_id":"run-1","checkpoint_id":"approval-1","kind":"approval","revision":4,"event_cursor":0,"payload_json":"{\"version\":2}"}]}
    ;
    var file = try temporary.dir.createFile(std.testing.io, "checkpoints.json", .{});
    try file.writeStreamingAll(std.testing.io, fixture);
    file.close(std.testing.io);

    var file_store = FileStore.init(std.testing.io, temporary.dir, "checkpoints.json");
    var migrated = (try file_store.store().load(std.testing.allocator, "run-1", "approval-1")).?;
    defer migrated.deinit();
    try std.testing.expectEqual(Kind.approval, migrated.value.kind);
    try std.testing.expectEqualStrings("{\"version\":2}", migrated.value.state_json);
    var next = migrated.value;
    next.revision = 5;
    _ = try file_store.store().save(std.testing.allocator, next);
    const rewritten = try temporary.dir.readFileAlloc(
        std.testing.io,
        "checkpoints.json",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"cursor\":0") != null);
}

test "checkpoint validation and removal fail closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_store = FileStore.init(std.testing.io, temporary.dir, "checkpoints.json");
    const store_value = file_store.store();
    try std.testing.expectError(
        Error.InvalidCheckpoint,
        store_value.load(std.testing.allocator, "bad/run", "stream"),
    );
    try std.testing.expectError(
        Error.InvalidCheckpoint,
        store_value.remove(std.testing.allocator, "run", "bad/checkpoint"),
    );
    try std.testing.expectError(Error.InvalidCheckpoint, store_value.save(std.testing.allocator, .{
        .run_id = "bad/run",
        .checkpoint_id = "stream",
        .kind = .stream,
        .revision = 1,
        .state_json = "{}",
    }));
    try std.testing.expectError(Error.InvalidCheckpoint, store_value.save(std.testing.allocator, .{
        .run_id = "run",
        .checkpoint_id = "approval",
        .kind = .approval,
        .revision = 1,
        .cursor = 1,
        .state_json = "{}",
    }));
    _ = try store_value.save(std.testing.allocator, .{
        .run_id = "run",
        .checkpoint_id = "stream",
        .kind = .stream,
        .revision = 1,
        .state_json = "{}",
    });
    try store_value.remove(std.testing.allocator, "run", "missing");
    try store_value.remove(std.testing.allocator, "run", "stream");
    try std.testing.expect((try store_value.load(std.testing.allocator, "run", "stream")) == null);
}

test "checkpoint snapshots reject corrupt oversized and ambiguous documents" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const Case = struct {
        name: []const u8,
        source: []const u8,
        failure: anyerror = Error.InvalidCheckpoint,
    };
    const cases = [_]Case{
        .{ .name = "syntax.json", .source = "{" },
        .{ .name = "root.json", .source = "[]" },
        .{ .name = "version-type.json", .source = "{\"version\":\"2\",\"checkpoints\":[]}" },
        .{ .name = "entry-shape.json", .source = "{\"version\":2,\"checkpoints\":[[]]}" },
        .{ .name = "field-type.json", .source = "{\"version\":2,\"checkpoints\":[{\"run_id\":1,\"checkpoint_id\":\"stream\",\"kind\":\"stream\",\"revision\":1,\"cursor\":0,\"state_json\":\"{}\"}]}" },
        .{ .name = "state.json", .source = "{\"version\":2,\"checkpoints\":[{\"run_id\":\"run\",\"checkpoint_id\":\"stream\",\"kind\":\"stream\",\"revision\":1,\"cursor\":0,\"state_json\":\"{\"}]}" },
        .{ .name = "unsupported.json", .source = "{\"version\":3,\"checkpoints\":[]}", .failure = Error.UnsupportedCheckpointVersion },
        .{ .name = "duplicates.json", .source = "{\"version\":2,\"checkpoints\":[{\"run_id\":\"run\",\"checkpoint_id\":\"stream\",\"kind\":\"stream\",\"revision\":1,\"cursor\":0,\"state_json\":\"{}\"},{\"run_id\":\"run\",\"checkpoint_id\":\"stream\",\"kind\":\"stream\",\"revision\":2,\"cursor\":1,\"state_json\":\"{}\"}]}" },
    };
    for (cases) |case| {
        var file = try temporary.dir.createFile(std.testing.io, case.name, .{});
        try file.writeStreamingAll(std.testing.io, case.source);
        file.close(std.testing.io);
        var file_store = FileStore.init(std.testing.io, temporary.dir, case.name);
        try std.testing.expectError(
            case.failure,
            file_store.store().load(std.testing.allocator, "run", "stream"),
        );
    }

    var oversized_file = try temporary.dir.createFile(std.testing.io, "oversized.json", .{});
    try oversized_file.writeStreamingAll(std.testing.io, "{\"version\":2,\"checkpoints\":[]}");
    oversized_file.close(std.testing.io);
    var oversized_store = FileStore.init(std.testing.io, temporary.dir, "oversized.json");
    oversized_store.max_bytes = 8;
    try std.testing.expectError(
        Error.CheckpointTooLarge,
        oversized_store.store().load(std.testing.allocator, "run", "stream"),
    );

    try std.testing.expectError(Error.InvalidCheckpoint, (Record{
        .run_id = "run",
        .checkpoint_id = "stream",
        .kind = .stream,
        .revision = 1,
        .state_json = "{",
    }).validate(std.testing.allocator));
}
