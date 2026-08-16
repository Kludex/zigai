//! Versioned contracts for routing agent side effects through durable runtimes.
//!
//! Applications own the workflow boundary. ZigAI identifies fixed operation
//! kinds and serializable payloads; runtime adapters provide replay,
//! persistence, scheduling, and worker registration.

const std = @import("std");

pub const payloads = @import("durable/root.zig");

pub const format_version: u8 = 1;
pub const max_payload_bytes: usize = 2 * 1024 * 1024;
pub const max_record_bytes: usize = 8 * 1024 * 1024;
pub const max_identifier_bytes: usize = 128;

pub const Error = error{
    InvalidInvocation,
    InvalidPayload,
    InvalidRecord,
    UnsupportedRecordVersion,
    InputDigestMismatch,
    RuntimeRecordMismatch,
    MissingHandler,
    OperationFailed,
    OperationSuspended,
};

/// Closed operation vocabulary understood by ZigAI and durable runtimes.
/// Handler IDs select application registrations within each operation kind.
pub const OperationKind = enum {
    model_request,
    model_stream,
    tool_call,
    mcp_request,
    event_delivery,
    retry_delay,
    approval_resume,
};

/// One replay-stable operation request. `sequence` is monotonic within a run;
/// retries reuse the complete identity and payload unchanged.
pub const Invocation = struct {
    run_id: []const u8,
    step_id: []const u8,
    sequence: u64,
    kind: OperationKind,
    handler_id: []const u8,
    input_json: []const u8,

    pub fn validate(self: Invocation, allocator: std.mem.Allocator) !void {
        if (!validIdentifier(self.run_id) or !validIdentifier(self.step_id) or
            !validIdentifier(self.handler_id))
            return Error.InvalidInvocation;
        try validatePayload(allocator, self.input_json);
    }

    /// Human-readable idempotency key. Identifiers exclude `/`, so the shape
    /// is unambiguous and can be used directly by engines and stores.
    pub fn stableKey(self: Invocation, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}/{d}", .{
            self.run_id,
            self.step_id,
            self.sequence,
        });
    }

    pub fn inputDigest(self: Invocation) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.input_json, &digest, .{});
        return digest;
    }
};

pub const Failure = struct {
    error_name: []const u8,
    retryable: bool = false,
};

pub const SuspensionReason = enum {
    approval,
    external_tool,
    provider_resume,
};

pub const Suspension = struct {
    reason: SuspensionReason,
    state_json: []const u8,
};

/// Persisted operation result. JSON fields are strings containing complete
/// JSON documents so exact input and output bytes remain replay-visible.
pub const Outcome = union(enum) {
    success: []const u8,
    failure: Failure,
    suspended: Suspension,

    pub fn validate(self: Outcome, allocator: std.mem.Allocator) !void {
        switch (self) {
            .success => |output| try validatePayload(allocator, output),
            .failure => |failure| if (!validIdentifier(failure.error_name))
                return Error.InvalidRecord,
            .suspended => |suspension| try validatePayload(allocator, suspension.state_json),
        }
    }
};

/// One complete durable journal entry. The digest binds a stable operation
/// identity to its exact input, detecting accidental key reuse.
pub const Record = struct {
    version: u8 = format_version,
    invocation: Invocation,
    input_sha256: [32]u8,
    outcome: Outcome,

    pub fn init(invocation: Invocation, outcome: Outcome) Record {
        return .{
            .invocation = invocation,
            .input_sha256 = invocation.inputDigest(),
            .outcome = outcome,
        };
    }

    pub fn validate(self: Record, allocator: std.mem.Allocator) !void {
        if (self.version != format_version) return Error.UnsupportedRecordVersion;
        try self.invocation.validate(allocator);
        try self.outcome.validate(allocator);
        if (!std.mem.eql(u8, &self.input_sha256, &self.invocation.inputDigest()))
            return Error.InputDigestMismatch;
    }
};

/// Arena-owned record returned by parsers and runtime adapters.
pub const OwnedRecord = struct {
    arena: std.heap.ArenaAllocator,
    value: Record,

    pub fn deinit(self: *OwnedRecord) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn copy(allocator: std.mem.Allocator, record: Record) !OwnedRecord {
        const encoded = try stringifyRecord(allocator, record);
        defer allocator.free(encoded);
        return parseRecord(allocator, encoded);
    }
};

/// Adapter boundary implemented by Temporal-like workflow engines or local
/// durable workers. Implementations deduplicate by `Invocation.stableKey`,
/// persist the exact input and result, and dispatch `handler_id` from a worker
/// registration rather than attempting to serialize a Zig callback.
pub const Runtime = struct {
    context: *anyopaque,
    executeFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        invocation: Invocation,
    ) anyerror!OwnedRecord,

    pub fn execute(
        self: Runtime,
        allocator: std.mem.Allocator,
        invocation: Invocation,
    ) !OwnedRecord {
        try invocation.validate(allocator);
        var result = try self.executeFn(self.context, allocator, invocation);
        errdefer result.deinit();
        try result.value.validate(allocator);
        if (!sameInvocation(result.value.invocation, invocation))
            return Error.RuntimeRecordMismatch;
        return result;
    }
};

/// Worker registration IDs for each durable operation family. A runtime may
/// register the same ID for multiple kinds, but each enabled route is explicit.
pub const HandlerIds = struct {
    model_request: ?[]const u8 = null,
    model_stream: ?[]const u8 = null,
    tool_call: ?[]const u8 = null,
    mcp_request: ?[]const u8 = null,
    event_delivery: ?[]const u8 = null,
    retry_delay: ?[]const u8 = null,
    approval_resume: ?[]const u8 = null,

    pub fn get(self: HandlerIds, kind: OperationKind) ?[]const u8 {
        return switch (kind) {
            .model_request => self.model_request,
            .model_stream => self.model_stream,
            .tool_call => self.tool_call,
            .mcp_request => self.mcp_request,
            .event_delivery => self.event_delivery,
            .retry_delay => self.retry_delay,
            .approval_resume => self.approval_resume,
        };
    }
};

/// Immutable routing configuration for one replayable agent invocation.
/// Callers choose semantic step IDs and deterministic sequence numbers; this
/// value deliberately owns no mutable counter that could depend on scheduling.
pub const Binding = struct {
    runtime: Runtime,
    run_id: []const u8,
    handlers: HandlerIds,

    pub fn execute(
        self: Binding,
        allocator: std.mem.Allocator,
        kind: OperationKind,
        step_id: []const u8,
        sequence: u64,
        input_json: []const u8,
    ) !OwnedRecord {
        const handler_id = self.handlers.get(kind) orelse return Error.MissingHandler;
        return self.runtime.execute(allocator, .{
            .run_id = self.run_id,
            .step_id = step_id,
            .sequence = sequence,
            .kind = kind,
            .handler_id = handler_id,
            .input_json = input_json,
        });
    }
};

/// Returns a persisted success payload and maps non-success outcomes to stable
/// framework errors. The returned slice borrows from `record`.
pub fn successPayload(record: *const OwnedRecord) ![]const u8 {
    return switch (record.value.outcome) {
        .success => |payload| payload,
        .failure => Error.OperationFailed,
        .suspended => Error.OperationSuspended,
    };
}

pub fn stringifyRecord(allocator: std.mem.Allocator, record: Record) ![]u8 {
    try record.validate(allocator);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(record.version);
    try json.objectField("invocation");
    try json.beginObject();
    try json.objectField("run_id");
    try json.write(record.invocation.run_id);
    try json.objectField("step_id");
    try json.write(record.invocation.step_id);
    try json.objectField("sequence");
    try json.write(record.invocation.sequence);
    try json.objectField("kind");
    try json.write(@tagName(record.invocation.kind));
    try json.objectField("handler_id");
    try json.write(record.invocation.handler_id);
    try json.objectField("input_json");
    try json.write(record.invocation.input_json);
    try json.endObject();
    try json.objectField("input_sha256");
    try json.write(&std.fmt.bytesToHex(record.input_sha256, .lower));
    switch (record.outcome) {
        .success => |value| {
            try json.objectField("status");
            try json.write("success");
            try json.objectField("output_json");
            try json.write(value);
        },
        .failure => |failure| {
            try json.objectField("status");
            try json.write("failure");
            try json.objectField("error_name");
            try json.write(failure.error_name);
            try json.objectField("retryable");
            try json.write(failure.retryable);
        },
        .suspended => |suspension| {
            try json.objectField("status");
            try json.write("suspended");
            try json.objectField("suspension_reason");
            try json.write(@tagName(suspension.reason));
            try json.objectField("state_json");
            try json.write(suspension.state_json);
        },
    }
    try json.endObject();
    return output.toOwnedSlice();
}

pub fn parseRecord(allocator: std.mem.Allocator, source: []const u8) !OwnedRecord {
    if (source.len > max_record_bytes) return Error.InvalidRecord;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(WireRecord, arena.allocator(), source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_record_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidRecord,
    };
    if (wire.version != format_version) return Error.UnsupportedRecordVersion;
    var digest: [32]u8 = undefined;
    if (wire.input_sha256.len != digest.len * 2) return Error.InvalidRecord;
    _ = std.fmt.hexToBytes(&digest, wire.input_sha256) catch return Error.InvalidRecord;
    const invocation = Invocation{
        .run_id = wire.invocation.run_id,
        .step_id = wire.invocation.step_id,
        .sequence = wire.invocation.sequence,
        .kind = wire.invocation.kind,
        .handler_id = wire.invocation.handler_id,
        .input_json = wire.invocation.input_json,
    };
    const outcome: Outcome = switch (wire.status) {
        .success => .{ .success = wire.output_json orelse return Error.InvalidRecord },
        .failure => .{ .failure = .{
            .error_name = wire.error_name orelse return Error.InvalidRecord,
            .retryable = wire.retryable orelse return Error.InvalidRecord,
        } },
        .suspended => .{ .suspended = .{
            .reason = wire.suspension_reason orelse return Error.InvalidRecord,
            .state_json = wire.state_json orelse return Error.InvalidRecord,
        } },
    };
    if (!validOutcomeFields(wire)) return Error.InvalidRecord;
    const record = Record{
        .version = wire.version,
        .invocation = invocation,
        .input_sha256 = digest,
        .outcome = outcome,
    };
    try record.validate(arena.allocator());
    return .{ .arena = arena, .value = record };
}

const Status = enum { success, failure, suspended };

const WireInvocation = struct {
    run_id: []const u8,
    step_id: []const u8,
    sequence: u64,
    kind: OperationKind,
    handler_id: []const u8,
    input_json: []const u8,
};

const WireRecord = struct {
    version: u8,
    invocation: WireInvocation,
    input_sha256: []const u8,
    status: Status,
    output_json: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    retryable: ?bool = null,
    suspension_reason: ?SuspensionReason = null,
    state_json: ?[]const u8 = null,
};

fn validOutcomeFields(wire: WireRecord) bool {
    return switch (wire.status) {
        .success => wire.output_json != null and wire.error_name == null and
            wire.retryable == null and wire.suspension_reason == null and wire.state_json == null,
        .failure => wire.output_json == null and wire.error_name != null and
            wire.retryable != null and wire.suspension_reason == null and wire.state_json == null,
        .suspended => wire.output_json == null and wire.error_name == null and
            wire.retryable == null and wire.suspension_reason != null and wire.state_json != null,
    };
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > max_identifier_bytes) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-'))
        return false;
    return true;
}

fn validatePayload(allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len == 0 or value.len > max_payload_bytes) return Error.InvalidPayload;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{
        .max_value_len = max_payload_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidPayload,
    };
    defer parsed.deinit();
}

fn sameInvocation(left: Invocation, right: Invocation) bool {
    return left.sequence == right.sequence and left.kind == right.kind and
        std.mem.eql(u8, left.run_id, right.run_id) and
        std.mem.eql(u8, left.step_id, right.step_id) and
        std.mem.eql(u8, left.handler_id, right.handler_id) and
        std.mem.eql(u8, left.input_json, right.input_json);
}

test "durable invocation identities and payloads are strict" {
    const invocation = Invocation{
        .run_id = "run-1",
        .step_id = "model.request",
        .sequence = 7,
        .kind = .model_request,
        .handler_id = "support-agent",
        .input_json = "{\"prompt\":\"hello\"}",
    };
    try invocation.validate(std.testing.allocator);
    const key = try invocation.stableKey(std.testing.allocator);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("run-1/model.request/7", key);
    try std.testing.expect(!std.mem.eql(u8, &invocation.inputDigest(), &([_]u8{0} ** 32)));

    var invalid = invocation;
    invalid.run_id = "bad/run";
    try std.testing.expectError(Error.InvalidInvocation, invalid.validate(std.testing.allocator));
    invalid = invocation;
    invalid.input_json = "{";
    try std.testing.expectError(Error.InvalidPayload, invalid.validate(std.testing.allocator));
    invalid.input_json = "";
    try std.testing.expectError(Error.InvalidPayload, invalid.validate(std.testing.allocator));
    invalid = invocation;
    invalid.handler_id = "";
    try std.testing.expectError(Error.InvalidInvocation, invalid.validate(std.testing.allocator));

    try std.testing.expectError(
        Error.InvalidRecord,
        (Outcome{ .failure = .{ .error_name = "bad/error" } }).validate(std.testing.allocator),
    );
    try std.testing.expectError(
        Error.InvalidPayload,
        (Outcome{ .suspended = .{ .reason = .external_tool, .state_json = "{" } }).validate(std.testing.allocator),
    );
}

test "durable records round trip every terminal state" {
    const invocation = Invocation{
        .run_id = "run-1",
        .step_id = "tool.call",
        .sequence = 3,
        .kind = .tool_call,
        .handler_id = "weather",
        .input_json = "{\"city\":\"Madrid\"}",
    };
    const outcomes = [_]Outcome{
        .{ .success = "{\"temperature_c\":27}" },
        .{ .failure = .{ .error_name = "ProviderUnavailable", .retryable = true } },
        .{ .suspended = .{ .reason = .approval, .state_json = "{\"call_id\":\"one\"}" } },
    };
    for (outcomes) |outcome| {
        const record = Record.init(invocation, outcome);
        const encoded = try stringifyRecord(std.testing.allocator, record);
        defer std.testing.allocator.free(encoded);
        var parsed = try parseRecord(std.testing.allocator, encoded);
        defer parsed.deinit();
        try std.testing.expect(sameInvocation(parsed.value.invocation, invocation));
        try std.testing.expectEqual(std.meta.activeTag(outcome), std.meta.activeTag(parsed.value.outcome));
    }

    var mismatched = Record.init(invocation, outcomes[0]);
    mismatched.input_sha256 = [_]u8{0} ** 32;
    try std.testing.expectError(
        Error.InputDigestMismatch,
        mismatched.validate(std.testing.allocator),
    );
    var unsupported = Record.init(invocation, outcomes[0]);
    unsupported.version = format_version + 1;
    try std.testing.expectError(
        Error.UnsupportedRecordVersion,
        unsupported.validate(std.testing.allocator),
    );
    try std.testing.expectError(Error.InvalidRecord, parseRecord(std.testing.allocator, "{}"));
    try std.testing.expectError(Error.InvalidRecord, parseRecord(std.testing.allocator, "{"));
}

test "durable record parser rejects ambiguous and changed documents" {
    const valid = Record.init(.{
        .run_id = "run",
        .step_id = "stream",
        .sequence = 1,
        .kind = .model_stream,
        .handler_id = "agent",
        .input_json = "{}",
    }, .{ .success = "[]" });
    const encoded = try stringifyRecord(std.testing.allocator, valid);
    defer std.testing.allocator.free(encoded);
    const changed = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        encoded,
        "\"input_json\":\"{}\"",
        "\"input_json\":\"null\"",
    );
    defer std.testing.allocator.free(changed);
    try std.testing.expectError(
        Error.InputDigestMismatch,
        parseRecord(std.testing.allocator, changed),
    );
    const ambiguous = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        encoded,
        "\"output_json\":\"[]\"",
        "\"output_json\":\"[]\",\"error_name\":\"Bad\"",
    );
    defer std.testing.allocator.free(ambiguous);
    try std.testing.expectError(Error.InvalidRecord, parseRecord(std.testing.allocator, ambiguous));
    const unknown = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        encoded,
        "\"version\":1",
        "\"version\":1,\"unknown\":true",
    );
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(Error.InvalidRecord, parseRecord(std.testing.allocator, unknown));
}

test "durable runtime accepts only matching validated records" {
    const State = struct {
        mismatch: bool = false,

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            invocation: Invocation,
        ) !OwnedRecord {
            const self: *@This() = @ptrCast(@alignCast(context));
            var recorded = invocation;
            if (self.mismatch) recorded.step_id = "different";
            return OwnedRecord.copy(
                allocator,
                Record.init(recorded, .{ .success = "{\"ok\":true}" }),
            );
        }
    };
    const invocation = Invocation{
        .run_id = "run",
        .step_id = "mcp",
        .sequence = 2,
        .kind = .mcp_request,
        .handler_id = "filesystem",
        .input_json = "{\"method\":\"tools/list\"}",
    };
    var state: State = .{};
    const runtime = Runtime{ .context = &state, .executeFn = State.execute };
    var result = try runtime.execute(std.testing.allocator, invocation);
    result.deinit();
    state.mismatch = true;
    try std.testing.expectError(
        Error.RuntimeRecordMismatch,
        runtime.execute(std.testing.allocator, invocation),
    );
}

test "durable binding selects explicit handlers and exposes success only" {
    const State = struct {
        fn execute(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            invocation: Invocation,
        ) !OwnedRecord {
            return OwnedRecord.copy(allocator, Record.init(invocation, .{ .success = "{\"ok\":true}" }));
        }
    };
    var marker: u8 = 0;
    const binding = Binding{
        .runtime = .{ .context = &marker, .executeFn = State.execute },
        .run_id = "run",
        .handlers = .{ .model_request = "registered-model" },
    };
    var record = try binding.execute(
        std.testing.allocator,
        .model_request,
        "model.request",
        1,
        "{}",
    );
    defer record.deinit();
    try std.testing.expectEqualStrings("registered-model", record.value.invocation.handler_id);
    try std.testing.expectEqualStrings("{\"ok\":true}", try successPayload(&record));
    try std.testing.expectError(
        Error.MissingHandler,
        binding.execute(std.testing.allocator, .tool_call, "tool.call", 2, "{}"),
    );

    var failed = try OwnedRecord.copy(std.testing.allocator, Record.init(
        record.value.invocation,
        .{ .failure = .{ .error_name = "Unavailable", .retryable = true } },
    ));
    defer failed.deinit();
    try std.testing.expectError(Error.OperationFailed, successPayload(&failed));
    var suspended = try OwnedRecord.copy(std.testing.allocator, Record.init(
        record.value.invocation,
        .{ .suspended = .{ .reason = .provider_resume, .state_json = "{}" } },
    ));
    defer suspended.deinit();
    try std.testing.expectError(Error.OperationSuspended, successPayload(&suspended));
}

test {
    _ = payloads;
}
