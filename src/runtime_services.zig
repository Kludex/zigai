//! Local interfaces for step persistence, blobs, managed prompts, and bounded work.
//!
//! Interfaces contain no hosted-service client. In-memory implementations are
//! deterministic, single-threaded stores; the executor uses caller-owned `Io`.

const std = @import("std");
const json_limits = @import("json.zig");
const model_types = @import("model.zig");

pub const StepState = enum { pending, running, succeeded, failed };

/// Versioned persisted workflow step.
pub const StepRecord = struct {
    run_id: []const u8,
    step_id: []const u8,
    revision: u64,
    state: StepState,
    input_json: []const u8,
    output_json: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
};

pub const OwnedStepRecord = struct {
    arena: std.heap.ArenaAllocator,
    value: StepRecord,

    pub fn deinit(self: *OwnedStepRecord) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Optimistic step persistence interface.
pub const StepStore = struct {
    context: *anyopaque,
    save_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        record: StepRecord,
        expected_revision: ?u64,
    ) anyerror!void,
    load_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        run_id: []const u8,
        step_id: []const u8,
    ) anyerror!?OwnedStepRecord,

    pub fn save(
        self: StepStore,
        gpa: std.mem.Allocator,
        record: StepRecord,
        expected_revision: ?u64,
    ) !void {
        return self.save_fn(self.context, gpa, record, expected_revision);
    }

    pub fn load(
        self: StepStore,
        gpa: std.mem.Allocator,
        run_id: []const u8,
        step_id: []const u8,
    ) !?OwnedStepRecord {
        return self.load_fn(self.context, gpa, run_id, step_id);
    }
};

pub const BlobKind = enum { media, artifact };

/// Tenant-owned media or artifact input.
pub const Blob = struct {
    tenant_id: []const u8,
    id: []const u8,
    kind: BlobKind,
    media_type: []const u8,
    bytes: []const u8,
};

pub const OwnedBlob = struct {
    arena: std.heap.ArenaAllocator,
    value: Blob,

    pub fn deinit(self: *OwnedBlob) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Media/artifact persistence interface.
pub const BlobStore = struct {
    context: *anyopaque,
    put_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, blob: Blob) anyerror!void,
    get_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        id: []const u8,
    ) anyerror!?OwnedBlob,
    delete_fn: *const fn (context: *anyopaque, tenant_id: []const u8, id: []const u8) anyerror!bool,

    pub fn put(self: BlobStore, gpa: std.mem.Allocator, blob: Blob) !void {
        return self.put_fn(self.context, gpa, blob);
    }
    pub fn get(self: BlobStore, gpa: std.mem.Allocator, tenant_id: []const u8, id: []const u8) !?OwnedBlob {
        return self.get_fn(self.context, gpa, tenant_id, id);
    }
    pub fn delete(self: BlobStore, tenant_id: []const u8, id: []const u8) !bool {
        return self.delete_fn(self.context, tenant_id, id);
    }
};

/// Versioned managed prompt.
pub const Prompt = struct {
    name: []const u8,
    version: u64,
    template: []const u8,
};

pub const OwnedPrompt = struct {
    arena: std.heap.ArenaAllocator,
    value: Prompt,

    pub fn deinit(self: *OwnedPrompt) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Managed prompt lookup interface.
pub const PromptStore = struct {
    context: *anyopaque,
    get_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        name: []const u8,
        version: ?u64,
    ) anyerror!?OwnedPrompt,

    pub fn get(self: PromptStore, gpa: std.mem.Allocator, name: []const u8, version: ?u64) !?OwnedPrompt {
        return self.get_fn(self.context, gpa, name, version);
    }
};

pub const Limits = struct {
    max_identifier_bytes: usize = 256,
    max_step_json_bytes: usize = 4 * 1024 * 1024,
    max_blobs: usize = 10_000,
    max_blob_bytes: usize = 64 * 1024 * 1024,
    max_prompts: usize = 1_000,
    max_prompt_bytes: usize = 1024 * 1024,
};

/// Deterministic local implementation of all persistence interfaces.
pub const InMemoryStores = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    steps: std.ArrayList(OwnedStepRecord) = .empty,
    blobs: std.ArrayList(OwnedBlob) = .empty,
    prompts: std.ArrayList(OwnedPrompt) = .empty,

    pub fn init(gpa: std.mem.Allocator, limits: Limits) InMemoryStores {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *InMemoryStores) void {
        for (self.steps.items) |*record| record.deinit();
        for (self.blobs.items) |*blob| blob.deinit();
        for (self.prompts.items) |*prompt| prompt.deinit();
        self.steps.deinit(self.gpa);
        self.blobs.deinit(self.gpa);
        self.prompts.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn stepStore(self: *InMemoryStores) StepStore {
        return .{ .context = self, .save_fn = saveStep, .load_fn = loadStep };
    }

    pub fn blobStore(self: *InMemoryStores) BlobStore {
        return .{ .context = self, .put_fn = putBlob, .get_fn = getBlob, .delete_fn = deleteBlob };
    }

    pub fn promptStore(self: *InMemoryStores) PromptStore {
        return .{ .context = self, .get_fn = getPrompt };
    }

    pub fn putPrompt(self: *InMemoryStores, prompt: Prompt) !void {
        try validateIdentifier(prompt.name, self.limits.max_identifier_bytes);
        if (prompt.version == 0 or prompt.template.len == 0 or prompt.template.len > self.limits.max_prompt_bytes)
            return error.InvalidManagedPrompt;
        for (self.prompts.items) |stored| {
            if (std.mem.eql(u8, stored.value.name, prompt.name) and stored.value.version == prompt.version)
                return error.ManagedPromptAlreadyExists;
        }
        if (self.prompts.items.len >= self.limits.max_prompts) return error.ManagedPromptStoreFull;
        var owned = try copyPrompt(self.gpa, prompt);
        errdefer owned.deinit();
        try self.prompts.append(self.gpa, owned);
    }

    fn saveStep(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        record: StepRecord,
        expected_revision: ?u64,
    ) !void {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateStep(gpa, record, self.limits);
        for (self.steps.items, 0..) |*stored, index| {
            if (!sameIdentity(stored.value, record)) continue;
            if (expected_revision == null or stored.value.revision != expected_revision.?)
                return error.StepRevisionConflict;
            const next_revision = std.math.add(u64, expected_revision.?, 1) catch
                return error.StepRevisionConflict;
            if (record.revision != next_revision) return error.StepRevisionConflict;
            const replacement = try copyStep(self.gpa, record);
            stored.deinit();
            self.steps.items[index] = replacement;
            return;
        }
        if (expected_revision != null or record.revision != 1) return error.StepRevisionConflict;
        var owned = try copyStep(self.gpa, record);
        errdefer owned.deinit();
        try self.steps.append(self.gpa, owned);
    }

    fn loadStep(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        run_id: []const u8,
        step_id: []const u8,
    ) !?OwnedStepRecord {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateIdentifier(run_id, self.limits.max_identifier_bytes);
        try validateIdentifier(step_id, self.limits.max_identifier_bytes);
        for (self.steps.items) |stored| {
            if (std.mem.eql(u8, stored.value.run_id, run_id) and
                std.mem.eql(u8, stored.value.step_id, step_id))
                return try copyStep(gpa, stored.value);
        }
        return null;
    }

    fn putBlob(context: *anyopaque, _: std.mem.Allocator, blob: Blob) !void {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateBlob(blob, self.limits);
        for (self.blobs.items) |stored| {
            if (std.mem.eql(u8, stored.value.tenant_id, blob.tenant_id) and
                std.mem.eql(u8, stored.value.id, blob.id))
                return error.BlobAlreadyExists;
        }
        if (self.blobs.items.len >= self.limits.max_blobs) return error.BlobStoreFull;
        var owned = try copyBlob(self.gpa, blob);
        errdefer owned.deinit();
        try self.blobs.append(self.gpa, owned);
    }

    fn getBlob(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        id: []const u8,
    ) !?OwnedBlob {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateIdentifier(tenant_id, self.limits.max_identifier_bytes);
        try validateIdentifier(id, self.limits.max_identifier_bytes);
        for (self.blobs.items) |stored| {
            if (std.mem.eql(u8, stored.value.tenant_id, tenant_id) and
                std.mem.eql(u8, stored.value.id, id))
                return try copyBlob(gpa, stored.value);
        }
        return null;
    }

    fn deleteBlob(context: *anyopaque, tenant_id: []const u8, id: []const u8) !bool {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateIdentifier(tenant_id, self.limits.max_identifier_bytes);
        try validateIdentifier(id, self.limits.max_identifier_bytes);
        for (self.blobs.items, 0..) |stored, index| {
            if (!std.mem.eql(u8, stored.value.tenant_id, tenant_id) or
                !std.mem.eql(u8, stored.value.id, id))
                continue;
            var removed = self.blobs.orderedRemove(index);
            removed.deinit();
            return true;
        }
        return false;
    }

    fn getPrompt(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        name: []const u8,
        version: ?u64,
    ) !?OwnedPrompt {
        const self: *InMemoryStores = @ptrCast(@alignCast(context));
        try validateIdentifier(name, self.limits.max_identifier_bytes);
        var selected: ?Prompt = null;
        for (self.prompts.items) |stored| {
            if (!std.mem.eql(u8, stored.value.name, name)) continue;
            if (version) |exact| {
                if (stored.value.version == exact) selected = stored.value;
            } else if (selected == null or stored.value.version > selected.?.version) {
                selected = stored.value;
            }
        }
        return if (selected) |prompt| try copyPrompt(gpa, prompt) else null;
    }
};

/// Prompt variable supplied to `renderPrompt`.
pub const PromptVariable = struct { name: []const u8, value: []const u8 };

pub fn renderPrompt(
    gpa: std.mem.Allocator,
    prompt: Prompt,
    variables: []const PromptVariable,
    max_output_bytes: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var index: usize = 0;
    while (index < prompt.template.len) {
        if (prompt.template[index] != '{' or index + 1 >= prompt.template.len or prompt.template[index + 1] != '{') {
            try output.append(gpa, prompt.template[index]);
            if (output.items.len > max_output_bytes) return error.ManagedPromptTooLarge;
            index += 1;
            continue;
        }
        const closing = std.mem.indexOfPos(u8, prompt.template, index + 2, "}}") orelse
            return error.InvalidManagedPrompt;
        const name = prompt.template[index + 2 .. closing];
        const value = findVariable(variables, name) orelse return error.MissingPromptVariable;
        try output.appendSlice(gpa, value);
        if (output.items.len > max_output_bytes) return error.ManagedPromptTooLarge;
        index = closing + 2;
    }
    return output.toOwnedSlice(gpa);
}

/// One bounded executor task. Output is allocated in the supplied arena.
pub const Task = struct {
    id: []const u8,
    context: ?*anyopaque = null,
    run_fn: *const fn (
        context: ?*anyopaque,
        arena: std.mem.Allocator,
        control: model_types.RunControl,
    ) anyerror![]const u8,
};

pub const TaskResult = struct { id: []const u8, output: []const u8 };

pub const ExecutionResult = struct {
    arena: std.heap.ArenaAllocator,
    results: []const TaskResult,

    pub fn deinit(self: *ExecutionResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Bounded structured-concurrency executor with source-ordered results.
pub const BoundedExecutor = struct {
    io: std.Io,
    max_concurrency: usize = 4,
    max_tasks: usize = 128,
    max_output_bytes: usize = 4 * 1024 * 1024,

    pub fn run(
        self: BoundedExecutor,
        gpa: std.mem.Allocator,
        tasks: []const Task,
        cancellation: ?*const model_types.CancellationToken,
        timeout_ms: ?u64,
    ) !ExecutionResult {
        if (self.max_concurrency == 0 or self.max_tasks == 0 or tasks.len > self.max_tasks)
            return error.InvalidExecutorLimits;
        const control = try model_types.RunControl.init(self.io, cancellation, timeout_ms);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const results = try arena.allocator().alloc(TaskResult, tasks.len);
        var next: usize = 0;
        while (next < tasks.len) {
            const end = @min(next + self.max_concurrency, tasks.len);
            const buffer = try gpa.alloc(Selection, end - next);
            defer gpa.free(buffer);
            const task_arenas = try gpa.alloc(std.heap.ArenaAllocator, end - next);
            defer gpa.free(task_arenas);
            for (task_arenas) |*task_arena| task_arena.* = .init(gpa);
            defer for (task_arenas) |*task_arena| task_arena.deinit();
            var select: std.Io.Select(Selection) = .init(self.io, buffer);
            defer select.cancelDiscard();
            for (tasks[next..end], next..) |task, index| {
                select.concurrent(.task, runTask, .{
                    task,
                    task_arenas[index - next].allocator(),
                    control,
                    index,
                }) catch return error.ExecutorConcurrencyUnavailable;
            }
            var completed: usize = next;
            while (completed < end) : (completed += 1) switch (try select.await()) {
                .task => |outcome| {
                    const value = try outcome.result;
                    if (value.len > self.max_output_bytes) return error.ExecutorOutputTooLarge;
                    results[outcome.index] = .{
                        .id = try arena.allocator().dupe(u8, tasks[outcome.index].id),
                        .output = try arena.allocator().dupe(u8, value),
                    };
                },
            };
            next = end;
        }
        return .{ .arena = arena, .results = results };
    }

    const Selection = union(enum) {
        task: Outcome,
    };
    const Outcome = struct { index: usize, result: anyerror![]const u8 };
};

fn runTask(
    task: Task,
    arena: std.mem.Allocator,
    control: model_types.RunControl,
    index: usize,
) ExecutorOutcome {
    return .{
        .index = index,
        .result = control.invoke([]const u8, invokeTask, .{ task, arena, control }),
    };
}

const ExecutorOutcome = BoundedExecutor.Outcome;

fn invokeTask(task: Task, arena: std.mem.Allocator, control: model_types.RunControl) ![]const u8 {
    return task.run_fn(task.context, arena, control);
}

fn validateStep(gpa: std.mem.Allocator, record: StepRecord, limits: Limits) !void {
    try validateIdentifier(record.run_id, limits.max_identifier_bytes);
    try validateIdentifier(record.step_id, limits.max_identifier_bytes);
    if (record.revision == 0) return error.InvalidStepRecord;
    try validateJson(gpa, record.input_json, limits.max_step_json_bytes);
    if (record.output_json) |output| try validateJson(gpa, output, limits.max_step_json_bytes);
    if (record.state == .succeeded and record.output_json == null) return error.InvalidStepRecord;
    if (record.state == .failed and record.error_name == null) return error.InvalidStepRecord;
}

fn validateBlob(blob: Blob, limits: Limits) !void {
    try validateIdentifier(blob.tenant_id, limits.max_identifier_bytes);
    try validateIdentifier(blob.id, limits.max_identifier_bytes);
    if (blob.media_type.len == 0 or blob.media_type.len > 255 or blob.bytes.len > limits.max_blob_bytes)
        return error.InvalidBlob;
}

fn validateIdentifier(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum) return error.InvalidRuntimeIdentifier;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
        return error.InvalidRuntimeIdentifier;
}

fn validateJson(gpa: std.mem.Allocator, value: []const u8, maximum: usize) !void {
    if (value.len > maximum) return error.RuntimePayloadTooLarge;
    try json_limits.validateAs(
        gpa,
        value,
        .{ .max_document_bytes = maximum, .max_value_bytes = maximum, .max_depth = 64, .max_collection_items = 16_384 },
        error.InvalidRuntimePayload,
    );
}

fn sameIdentity(left: StepRecord, right: StepRecord) bool {
    return std.mem.eql(u8, left.run_id, right.run_id) and std.mem.eql(u8, left.step_id, right.step_id);
}

fn copyStep(gpa: std.mem.Allocator, record: StepRecord) !OwnedStepRecord {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = StepRecord{
        .run_id = try arena.allocator().dupe(u8, record.run_id),
        .step_id = try arena.allocator().dupe(u8, record.step_id),
        .revision = record.revision,
        .state = record.state,
        .input_json = try arena.allocator().dupe(u8, record.input_json),
        .output_json = if (record.output_json) |output| try arena.allocator().dupe(u8, output) else null,
        .error_name = if (record.error_name) |failure| try arena.allocator().dupe(u8, failure) else null,
    };
    return .{ .arena = arena, .value = value };
}

fn copyBlob(gpa: std.mem.Allocator, blob: Blob) !OwnedBlob {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = Blob{
        .tenant_id = try arena.allocator().dupe(u8, blob.tenant_id),
        .id = try arena.allocator().dupe(u8, blob.id),
        .kind = blob.kind,
        .media_type = try arena.allocator().dupe(u8, blob.media_type),
        .bytes = try arena.allocator().dupe(u8, blob.bytes),
    };
    return .{ .arena = arena, .value = value };
}

fn copyPrompt(gpa: std.mem.Allocator, prompt: Prompt) !OwnedPrompt {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = Prompt{
        .name = try arena.allocator().dupe(u8, prompt.name),
        .version = prompt.version,
        .template = try arena.allocator().dupe(u8, prompt.template),
    };
    return .{ .arena = arena, .value = value };
}

fn findVariable(variables: []const PromptVariable, name: []const u8) ?[]const u8 {
    for (variables) |variable| if (std.mem.eql(u8, variable.name, name)) return variable.value;
    return null;
}

test "runtime stores persist steps blobs and managed prompts" {
    var stores = InMemoryStores.init(std.testing.allocator, .{});
    defer stores.deinit();
    const steps = stores.stepStore();
    try steps.save(std.testing.allocator, .{
        .run_id = "run",
        .step_id = "step",
        .revision = 1,
        .state = .running,
        .input_json = "{\"input\":1}",
    }, null);
    try std.testing.expectError(error.StepRevisionConflict, steps.save(std.testing.allocator, .{
        .run_id = "run",
        .step_id = "step",
        .revision = 2,
        .state = .succeeded,
        .input_json = "{}",
        .output_json = "{}",
    }, 9));
    try steps.save(std.testing.allocator, .{
        .run_id = "run",
        .step_id = "step",
        .revision = 2,
        .state = .succeeded,
        .input_json = "{\"input\":1}",
        .output_json = "{\"output\":2}",
    }, 1);
    var loaded = (try steps.load(std.testing.allocator, "run", "step")).?;
    defer loaded.deinit();
    try std.testing.expectEqual(StepState.succeeded, loaded.value.state);
    try std.testing.expect((try steps.load(std.testing.allocator, "run", "missing")) == null);

    const blobs = stores.blobStore();
    const image_blob = Blob{
        .tenant_id = "tenant-a",
        .id = "image",
        .kind = .media,
        .media_type = "image/png",
        .bytes = "png",
    };
    try blobs.put(std.testing.allocator, image_blob);
    try std.testing.expectError(error.BlobAlreadyExists, blobs.put(std.testing.allocator, image_blob));
    try std.testing.expect((try blobs.get(std.testing.allocator, "tenant-b", "image")) == null);
    var blob = (try blobs.get(std.testing.allocator, "tenant-a", "image")).?;
    defer blob.deinit();
    try std.testing.expectEqualStrings("png", blob.value.bytes);
    try std.testing.expect(try blobs.delete("tenant-a", "image"));
    try std.testing.expect(!(try blobs.delete("tenant-a", "image")));

    try stores.putPrompt(.{ .name = "welcome", .version = 1, .template = "Hello {{name}}" });
    try std.testing.expectError(
        error.ManagedPromptAlreadyExists,
        stores.putPrompt(.{ .name = "welcome", .version = 1, .template = "duplicate" }),
    );
    try stores.putPrompt(.{ .name = "welcome", .version = 2, .template = "Hi {{name}}" });
    var exact_prompt = (try stores.promptStore().get(std.testing.allocator, "welcome", 1)).?;
    defer exact_prompt.deinit();
    try std.testing.expectEqual(@as(u64, 1), exact_prompt.value.version);
    var prompt = (try stores.promptStore().get(std.testing.allocator, "welcome", null)).?;
    defer prompt.deinit();
    try std.testing.expectEqual(@as(u64, 2), prompt.value.version);
    const rendered = try renderPrompt(
        std.testing.allocator,
        prompt.value,
        &.{.{ .name = "name", .value = "Zig" }},
        100,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Hi Zig", rendered);
    try std.testing.expectError(
        error.MissingPromptVariable,
        renderPrompt(std.testing.allocator, prompt.value, &.{}, 100),
    );
}

test "bounded executor overlaps work and preserves source order" {
    const State = struct {
        active: std.atomic.Value(usize) = .init(0),
        maximum: std.atomic.Value(usize) = .init(0),
        fn run(context: ?*anyopaque, arena: std.mem.Allocator, control: model_types.RunControl) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const active = self.active.fetchAdd(1, .seq_cst) + 1;
            defer _ = self.active.fetchSub(1, .seq_cst);
            var current = self.maximum.load(.seq_cst);
            while (active > current) {
                if (self.maximum.cmpxchgWeak(current, active, .seq_cst, .seq_cst)) |observed| {
                    current = observed;
                } else break;
            }
            try control.check();
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }).sleep(control.io.?);
            return arena.dupe(u8, "done");
        }
    };
    var state: State = .{};
    const tasks = [_]Task{
        .{ .id = "one", .context = &state, .run_fn = State.run },
        .{ .id = "two", .context = &state, .run_fn = State.run },
        .{ .id = "three", .context = &state, .run_fn = State.run },
    };
    var result = try (BoundedExecutor{ .io = std.testing.io, .max_concurrency = 2 }).run(
        std.testing.allocator,
        &tasks,
        null,
        null,
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("one", result.results[0].id);
    try std.testing.expectEqualStrings("three", result.results[2].id);
    try std.testing.expect(state.maximum.load(.seq_cst) >= 2);
    try std.testing.expectError(
        error.InvalidExecutorLimits,
        (BoundedExecutor{ .io = std.testing.io, .max_tasks = 1 }).run(
            std.testing.allocator,
            &tasks,
            null,
            null,
        ),
    );
    var unavailable = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer unavailable.deinit();
    try std.testing.expectError(
        error.ExecutorConcurrencyUnavailable,
        (BoundedExecutor{ .io = unavailable.io() }).run(
            std.testing.allocator,
            tasks[0..1],
            null,
            null,
        ),
    );
}

fn runStoresWithAllocator(gpa: std.mem.Allocator) !void {
    var stores = InMemoryStores.init(gpa, .{});
    defer stores.deinit();
    try stores.stepStore().save(gpa, .{
        .run_id = "run",
        .step_id = "step",
        .revision = 1,
        .state = .pending,
        .input_json = "{}",
    }, null);
    try stores.blobStore().put(gpa, .{
        .tenant_id = "tenant",
        .id = "artifact",
        .kind = .artifact,
        .media_type = "text/plain",
        .bytes = "content",
    });
    try stores.putPrompt(.{ .name = "prompt", .version = 1, .template = "text" });
}

fn runExecutorWithAllocator(gpa: std.mem.Allocator) !void {
    const Work = struct {
        fn run(_: ?*anyopaque, arena: std.mem.Allocator, _: model_types.RunControl) ![]const u8 {
            return arena.dupe(u8, "output");
        }
    };
    var result = try (BoundedExecutor{ .io = std.testing.io }).run(
        gpa,
        &.{.{ .id = "task", .run_fn = Work.run }},
        null,
        null,
    );
    result.deinit();
}

test "runtime service ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runStoresWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runExecutorWithAllocator,
        .{},
    );
}
