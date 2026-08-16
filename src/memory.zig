//! Tenant-isolated conversation and semantic memory with pluggable stores.
//!
//! Conversation entries reuse canonical `Message` values. Search results own
//! citations and copies. The deterministic in-memory backend is single-threaded.

const std = @import("std");
const embeddings = @import("embeddings/base.zig");
const message_types = @import("messages.zig");

/// Memory record family.
pub const Kind = enum {
    conversation,
    semantic,
    compaction,
};

/// One borrowed record submitted to a store.
pub const Entry = struct {
    id: []const u8,
    tenant_id: []const u8,
    kind: Kind,
    content: []const u8,
    messages: []const message_types.Message = &.{},
    embedding: []const f32 = &.{},
    created_unix_ms: i64,
};

/// Search input. `embedding` enables semantic similarity.
pub const Query = struct {
    tenant_id: []const u8,
    text: []const u8 = "",
    embedding: []const f32 = &.{},
    limit: usize = 10,
    kinds: ?[]const Kind = null,
};

/// Citation attached to one search match.
pub const Citation = struct {
    entry_id: []const u8,
    tenant_id: []const u8,
    excerpt: []const u8,
    score: f64,
    created_unix_ms: i64,
};

/// One owned search match with canonical messages.
pub const Match = struct {
    entry: Entry,
    citation: Citation,
};

/// Arena-owned source-ordered search result.
pub const SearchResult = struct {
    arena: std.heap.ArenaAllocator,
    matches: []const Match,

    pub fn deinit(self: *SearchResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Retention and compaction policy applied with an explicit clock value.
pub const RetentionPolicy = struct {
    max_age_ms: ?u64 = null,
    max_entries: ?usize = null,
    keep_recent_for_compaction: usize = 20,
};

/// Hard trust and memory bounds.
pub const Limits = struct {
    max_tenant_bytes: usize = 256,
    max_id_bytes: usize = 256,
    max_content_bytes: usize = 4 * 1024 * 1024,
    max_messages_per_entry: usize = 1_000,
    max_embedding_dimensions: usize = 65_536,
    max_entries: usize = 100_000,
    max_search_limit: usize = 1_000,
};

/// Application compactor. Returned content is owned by `gpa`.
pub const Compactor = struct {
    context: ?*anyopaque = null,
    compact_fn: *const fn (
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        entries: []const Entry,
    ) anyerror![]u8,

    pub fn compact(
        self: Compactor,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        entries: []const Entry,
    ) ![]u8 {
        return self.compact_fn(self.context, gpa, tenant_id, entries);
    }
};

/// Provider-neutral persistent memory boundary.
pub const Store = struct {
    context: *anyopaque,
    put_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, entry: Entry) anyerror!void,
    search_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, query: Query) anyerror!SearchResult,
    delete_fn: *const fn (context: *anyopaque, tenant_id: []const u8, id: []const u8) anyerror!bool,
    delete_tenant_fn: *const fn (context: *anyopaque, tenant_id: []const u8) anyerror!usize,
    retain_fn: *const fn (
        context: *anyopaque,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
    ) anyerror!usize,
    compact_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
        compactor: Compactor,
    ) anyerror!bool,

    pub fn put(self: Store, gpa: std.mem.Allocator, entry: Entry) !void {
        return self.put_fn(self.context, gpa, entry);
    }

    pub fn search(self: Store, gpa: std.mem.Allocator, query: Query) !SearchResult {
        return self.search_fn(self.context, gpa, query);
    }

    pub fn delete(self: Store, tenant_id: []const u8, id: []const u8) !bool {
        return self.delete_fn(self.context, tenant_id, id);
    }

    pub fn deleteTenant(self: Store, tenant_id: []const u8) !usize {
        return self.delete_tenant_fn(self.context, tenant_id);
    }

    pub fn retain(
        self: Store,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
    ) !usize {
        return self.retain_fn(self.context, tenant_id, now_unix_ms, policy);
    }

    pub fn compact(
        self: Store,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
        compactor: Compactor,
    ) !bool {
        return self.compact_fn(self.context, gpa, tenant_id, now_unix_ms, policy, compactor);
    }
};

/// Deterministic single-threaded memory backend for tests and local workers.
pub const InMemoryStore = struct {
    gpa: std.mem.Allocator,
    limits: Limits = .{},
    records: std.ArrayList(OwnedEntry) = .empty,

    const OwnedEntry = struct {
        arena: std.heap.ArenaAllocator,
        value: Entry,

        fn copy(gpa: std.mem.Allocator, entry: Entry) !OwnedEntry {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const value = Entry{
                .id = try arena.allocator().dupe(u8, entry.id),
                .tenant_id = try arena.allocator().dupe(u8, entry.tenant_id),
                .kind = entry.kind,
                .content = try arena.allocator().dupe(u8, entry.content),
                .messages = try message_types.dupeMessages(arena.allocator(), entry.messages),
                .embedding = try arena.allocator().dupe(f32, entry.embedding),
                .created_unix_ms = entry.created_unix_ms,
            };
            return .{ .arena = arena, .value = value };
        }

        fn deinit(self: *OwnedEntry) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub fn init(gpa: std.mem.Allocator, limits: Limits) InMemoryStore {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *InMemoryStore) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn store(self: *InMemoryStore) Store {
        return .{
            .context = self,
            .put_fn = put,
            .search_fn = search,
            .delete_fn = delete,
            .delete_tenant_fn = deleteTenant,
            .retain_fn = retain,
            .compact_fn = compact,
        };
    }

    fn put(context: *anyopaque, _: std.mem.Allocator, entry: Entry) !void {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateEntry(entry, self.limits);
        for (self.records.items) |record| {
            if (std.mem.eql(u8, record.value.tenant_id, entry.tenant_id) and
                std.mem.eql(u8, record.value.id, entry.id))
                return error.MemoryEntryAlreadyExists;
        }
        if (self.records.items.len >= self.limits.max_entries) return error.MemoryStoreFull;
        var owned = try OwnedEntry.copy(self.gpa, entry);
        errdefer owned.deinit();
        try self.records.append(self.gpa, owned);
    }

    fn search(context: *anyopaque, gpa: std.mem.Allocator, query: Query) !SearchResult {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateQuery(query, self.limits);
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (self.records.items, 0..) |record, index| {
            const entry = record.value;
            if (!std.mem.eql(u8, entry.tenant_id, query.tenant_id)) continue;
            if (!kindAllowed(entry.kind, query.kinds)) continue;
            const score = if (query.embedding.len > 0)
                if (entry.embedding.len == query.embedding.len)
                    embeddings.cosineSimilarity(query.embedding, entry.embedding) catch continue
                else
                    continue
            else if (containsIgnoreCase(entry.content, query.text))
                @as(f64, 1)
            else
                continue;
            try scored.append(gpa, .{ .index = index, .score = score });
        }
        std.mem.sort(Scored, scored.items, self, compareScored);
        const count = @min(query.limit, scored.items.len);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const matches = try arena.allocator().alloc(Match, count);
        for (scored.items[0..count], matches) |scored_entry, *match| {
            const source = self.records.items[scored_entry.index].value;
            const entry = try copyEntry(arena.allocator(), source);
            match.* = .{
                .entry = entry,
                .citation = .{
                    .entry_id = entry.id,
                    .tenant_id = entry.tenant_id,
                    .excerpt = entry.content,
                    .score = scored_entry.score,
                    .created_unix_ms = entry.created_unix_ms,
                },
            };
        }
        return .{ .arena = arena, .matches = matches };
    }

    const Scored = struct { index: usize, score: f64 };

    fn compareScored(self: *InMemoryStore, left: Scored, right: Scored) bool {
        if (left.score != right.score) return left.score > right.score;
        const left_entry = self.records.items[left.index].value;
        const right_entry = self.records.items[right.index].value;
        if (left_entry.created_unix_ms != right_entry.created_unix_ms)
            return left_entry.created_unix_ms > right_entry.created_unix_ms;
        return std.mem.lessThan(u8, left_entry.id, right_entry.id);
    }

    fn delete(context: *anyopaque, tenant_id: []const u8, id: []const u8) !bool {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateTenantAndId(tenant_id, id, self.limits);
        for (self.records.items, 0..) |record, index| {
            if (!std.mem.eql(u8, record.value.tenant_id, tenant_id) or
                !std.mem.eql(u8, record.value.id, id))
                continue;
            var removed = self.records.orderedRemove(index);
            removed.deinit();
            return true;
        }
        return false;
    }

    fn deleteTenant(context: *anyopaque, tenant_id: []const u8) !usize {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateIdentifier(tenant_id, self.limits.max_tenant_bytes);
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.records.items.len) {
            if (!std.mem.eql(u8, self.records.items[index].value.tenant_id, tenant_id)) {
                index += 1;
                continue;
            }
            var record = self.records.orderedRemove(index);
            record.deinit();
            removed += 1;
        }
        return removed;
    }

    fn retain(
        context: *anyopaque,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
    ) !usize {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateIdentifier(tenant_id, self.limits.max_tenant_bytes);
        var removed: usize = 0;
        if (policy.max_age_ms) |age| {
            var index: usize = 0;
            while (index < self.records.items.len) {
                const entry = self.records.items[index].value;
                const expires = std.math.add(i64, entry.created_unix_ms, @intCast(@min(age, std.math.maxInt(i64)))) catch
                    std.math.maxInt(i64);
                if (!std.mem.eql(u8, entry.tenant_id, tenant_id) or expires > now_unix_ms) {
                    index += 1;
                    continue;
                }
                var record = self.records.orderedRemove(index);
                record.deinit();
                removed += 1;
            }
        }
        if (policy.max_entries) |maximum| {
            while (self.tenantCount(tenant_id) > maximum) {
                const oldest = self.oldestIndex(tenant_id).?;
                var record = self.records.orderedRemove(oldest);
                record.deinit();
                removed += 1;
            }
        }
        return removed;
    }

    fn compact(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        tenant_id: []const u8,
        now_unix_ms: i64,
        policy: RetentionPolicy,
        compactor: Compactor,
    ) !bool {
        const self: *InMemoryStore = @ptrCast(@alignCast(context));
        try validateIdentifier(tenant_id, self.limits.max_tenant_bytes);
        const count = self.tenantCount(tenant_id);
        if (count <= policy.keep_recent_for_compaction) return false;
        const compact_count = count - policy.keep_recent_for_compaction;
        const all_indices = try gpa.alloc(usize, count);
        defer gpa.free(all_indices);
        var found: usize = 0;
        for (self.records.items, 0..) |record, index| {
            if (!std.mem.eql(u8, record.value.tenant_id, tenant_id)) continue;
            all_indices[found] = index;
            found += 1;
        }
        std.mem.sort(usize, all_indices, self, compareEntryIndexOldest);
        const indices = all_indices[0..compact_count];
        const entries = try gpa.alloc(Entry, compact_count);
        defer gpa.free(entries);
        for (indices, entries) |index, *entry| entry.* = self.records.items[index].value;
        const content = try compactor.compact(gpa, tenant_id, entries);
        defer gpa.free(content);
        var id_buffer: [128]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "compaction-{d}", .{now_unix_ms});
        try validateOutputEntry(content, self.limits);
        var summary = try OwnedEntry.copy(self.gpa, .{
            .id = id,
            .tenant_id = tenant_id,
            .kind = .compaction,
            .content = content,
            .created_unix_ms = now_unix_ms,
        });
        errdefer summary.deinit();
        try self.records.ensureUnusedCapacity(self.gpa, 1);
        std.mem.sort(usize, indices, {}, descendingIndex);
        for (indices) |index| {
            var removed = self.records.orderedRemove(index);
            removed.deinit();
        }
        try self.records.append(self.gpa, summary);
        return true;
    }

    fn compareEntryIndexOldest(self: *InMemoryStore, left: usize, right: usize) bool {
        const left_entry = self.records.items[left].value;
        const right_entry = self.records.items[right].value;
        if (left_entry.created_unix_ms != right_entry.created_unix_ms)
            return left_entry.created_unix_ms < right_entry.created_unix_ms;
        return std.mem.lessThan(u8, left_entry.id, right_entry.id);
    }

    fn descendingIndex(_: void, left: usize, right: usize) bool {
        return left > right;
    }

    fn tenantCount(self: InMemoryStore, tenant_id: []const u8) usize {
        var count: usize = 0;
        for (self.records.items) |record| {
            count += @intFromBool(std.mem.eql(u8, record.value.tenant_id, tenant_id));
        }
        return count;
    }

    fn oldestIndex(self: InMemoryStore, tenant_id: []const u8) ?usize {
        var result: ?usize = null;
        for (self.records.items, 0..) |record, index| {
            if (!std.mem.eql(u8, record.value.tenant_id, tenant_id)) continue;
            if (result == null) {
                result = index;
            } else {
                const current = self.records.items[result.?].value;
                const candidate = record.value;
                if (candidate.created_unix_ms < current.created_unix_ms or
                    (candidate.created_unix_ms == current.created_unix_ms and
                        std.mem.lessThan(u8, candidate.id, current.id)))
                    result = index;
            }
        }
        return result;
    }
};

fn validateEntry(entry: Entry, limits: Limits) !void {
    try validateTenantAndId(entry.tenant_id, entry.id, limits);
    try validateOutputEntry(entry.content, limits);
    if (entry.messages.len > limits.max_messages_per_entry) return error.MemoryEntryTooLarge;
    if (entry.embedding.len > limits.max_embedding_dimensions) return error.MemoryEntryTooLarge;
    for (entry.embedding) |value| if (!std.math.isFinite(value)) return error.InvalidMemoryEmbedding;
    if (entry.kind == .conversation and entry.messages.len == 0) return error.InvalidMemoryEntry;
    if (entry.kind == .semantic and entry.content.len == 0) return error.InvalidMemoryEntry;
}

fn validateOutputEntry(content: []const u8, limits: Limits) !void {
    if (content.len > limits.max_content_bytes) return error.MemoryEntryTooLarge;
}

fn validateQuery(query: Query, limits: Limits) !void {
    try validateIdentifier(query.tenant_id, limits.max_tenant_bytes);
    if (query.limit == 0 or query.limit > limits.max_search_limit) return error.InvalidMemoryQuery;
    if (query.text.len == 0 and query.embedding.len == 0) return error.InvalidMemoryQuery;
    if (query.text.len > limits.max_content_bytes or query.embedding.len > limits.max_embedding_dimensions)
        return error.InvalidMemoryQuery;
    for (query.embedding) |value| if (!std.math.isFinite(value)) return error.InvalidMemoryEmbedding;
}

fn validateTenantAndId(tenant_id: []const u8, id: []const u8, limits: Limits) !void {
    try validateIdentifier(tenant_id, limits.max_tenant_bytes);
    try validateIdentifier(id, limits.max_id_bytes);
}

fn validateIdentifier(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum) return error.InvalidMemoryIdentifier;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
        return error.InvalidMemoryIdentifier;
}

fn kindAllowed(kind: Kind, allowed: ?[]const Kind) bool {
    const kinds = allowed orelse return true;
    for (kinds) |candidate| if (candidate == kind) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn copyEntry(arena: std.mem.Allocator, source: Entry) !Entry {
    return .{
        .id = try arena.dupe(u8, source.id),
        .tenant_id = try arena.dupe(u8, source.tenant_id),
        .kind = source.kind,
        .content = try arena.dupe(u8, source.content),
        .messages = try message_types.dupeMessages(arena, source.messages),
        .embedding = try arena.dupe(f32, source.embedding),
        .created_unix_ms = source.created_unix_ms,
    };
}

test "memory search isolates tenants and returns lexical semantic citations" {
    var memory = InMemoryStore.init(std.testing.allocator, .{});
    defer memory.deinit();
    const store = memory.store();
    const conversation = [_]message_types.Message{.{ .request = .{
        .parts = &.{.{ .user_prompt = .{ .text = "How does Zig work?" } }},
    } }};
    try store.put(std.testing.allocator, .{
        .id = "conversation-1",
        .tenant_id = "tenant-a",
        .kind = .conversation,
        .content = "Zig memory safety discussion",
        .messages = &conversation,
        .created_unix_ms = 10,
    });
    try store.put(std.testing.allocator, .{
        .id = "semantic-1",
        .tenant_id = "tenant-a",
        .kind = .semantic,
        .content = "allocator ownership",
        .embedding = &.{ 1, 0 },
        .created_unix_ms = 20,
    });
    try store.put(std.testing.allocator, .{
        .id = "semantic-0",
        .tenant_id = "tenant-a",
        .kind = .semantic,
        .content = "same score",
        .embedding = &.{ 1, 0 },
        .created_unix_ms = 20,
    });
    try store.put(std.testing.allocator, .{
        .id = "semantic-3",
        .tenant_id = "tenant-a",
        .kind = .semantic,
        .content = "newer score",
        .embedding = &.{ 1, 0 },
        .created_unix_ms = 25,
    });
    try store.put(std.testing.allocator, .{
        .id = "semantic-2",
        .tenant_id = "tenant-a",
        .kind = .semantic,
        .content = "lower score",
        .embedding = &.{ 1, 1 },
        .created_unix_ms = 30,
    });
    try store.put(std.testing.allocator, .{
        .id = "private",
        .tenant_id = "tenant-b",
        .kind = .semantic,
        .content = "Zig secret",
        .embedding = &.{ 1, 0 },
        .created_unix_ms = 30,
    });

    var lexical = try store.search(std.testing.allocator, .{
        .tenant_id = "tenant-a",
        .text = "zig",
    });
    defer lexical.deinit();
    try std.testing.expectEqual(@as(usize, 1), lexical.matches.len);
    try std.testing.expectEqualStrings("conversation-1", lexical.matches[0].citation.entry_id);
    try std.testing.expectEqualStrings(
        "How does Zig work?",
        lexical.matches[0].entry.messages[0].request.parts[0].user_prompt.text,
    );

    var semantic = try store.search(std.testing.allocator, .{
        .tenant_id = "tenant-a",
        .embedding = &.{ 1, 0 },
        .kinds = &.{.semantic},
    });
    defer semantic.deinit();
    try std.testing.expectEqual(@as(usize, 4), semantic.matches.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), semantic.matches[0].citation.score, 0.000001);
    try std.testing.expectEqualStrings("semantic-3", semantic.matches[0].entry.id);
    try std.testing.expectEqualStrings("semantic-0", semantic.matches[1].entry.id);
    try std.testing.expectEqualStrings("semantic-1", semantic.matches[2].entry.id);
    try std.testing.expectEqualStrings("semantic-2", semantic.matches[3].entry.id);
    try std.testing.expectEqualStrings("tenant-a", semantic.matches[0].citation.tenant_id);
    try std.testing.expectError(
        error.MemoryEntryAlreadyExists,
        store.put(std.testing.allocator, .{
            .id = "semantic-1",
            .tenant_id = "tenant-a",
            .kind = .semantic,
            .content = "duplicate",
            .created_unix_ms = 40,
        }),
    );
    try std.testing.expect(!(try store.delete("tenant-a", "missing")));
    try std.testing.expect(try store.delete("tenant-b", "private"));
    try std.testing.expectEqual(@as(usize, 0), try store.deleteTenant("tenant-b"));
}

test "memory retention deletion and compaction are deterministic" {
    var memory = InMemoryStore.init(std.testing.allocator, .{});
    defer memory.deinit();
    const store = memory.store();
    inline for (.{
        .{ "one", "old one", 1 },
        .{ "two", "old two", 1 },
        .{ "three", "recent", 100 },
    }) |item| try store.put(std.testing.allocator, .{
        .id = item[0],
        .tenant_id = "tenant",
        .kind = .semantic,
        .content = item[1],
        .created_unix_ms = item[2],
    });
    const Compaction = struct {
        fn compact(
            _: ?*anyopaque,
            gpa: std.mem.Allocator,
            _: []const u8,
            entries: []const Entry,
        ) ![]u8 {
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expectEqualStrings("one", entries[0].id);
            return std.fmt.allocPrint(gpa, "{s}; {s}", .{ entries[0].content, entries[1].content });
        }
    };
    try std.testing.expect(try store.compact(
        std.testing.allocator,
        "tenant",
        200,
        .{ .keep_recent_for_compaction = 1 },
        .{ .compact_fn = Compaction.compact },
    ));
    try std.testing.expect(!(try store.compact(
        std.testing.allocator,
        "tenant",
        201,
        .{ .keep_recent_for_compaction = 2 },
        .{ .compact_fn = Compaction.compact },
    )));
    var compacted = try store.search(std.testing.allocator, .{
        .tenant_id = "tenant",
        .text = "old one",
        .kinds = &.{.compaction},
    });
    defer compacted.deinit();
    try std.testing.expectEqualStrings("compaction-200", compacted.matches[0].entry.id);
    try std.testing.expectEqual(@as(usize, 1), try store.retain("tenant", 300, .{ .max_age_ms = 150 }));
    try std.testing.expectEqual(@as(usize, 1), try store.deleteTenant("tenant"));

    inline for (.{ "a", "b", "c" }, 0..) |id, index| try store.put(std.testing.allocator, .{
        .id = id,
        .tenant_id = "limited",
        .kind = .semantic,
        .content = id,
        .created_unix_ms = @intCast(index),
    });
    try std.testing.expectEqual(@as(usize, 2), try store.retain("limited", 10, .{ .max_entries = 1 }));
}

fn runMemoryWithAllocator(gpa: std.mem.Allocator) !void {
    var memory = InMemoryStore.init(gpa, .{});
    defer memory.deinit();
    const store = memory.store();
    try store.put(gpa, .{
        .id = "entry",
        .tenant_id = "tenant",
        .kind = .semantic,
        .content = "content",
        .embedding = &.{ 1, 0 },
        .created_unix_ms = 1,
    });
    var result = try store.search(gpa, .{ .tenant_id = "tenant", .embedding = &.{ 1, 0 } });
    result.deinit();
}

fn compactMemoryWithAllocator(gpa: std.mem.Allocator) !void {
    var memory = InMemoryStore.init(gpa, .{});
    defer memory.deinit();
    const store = memory.store();
    try store.put(gpa, .{
        .id = "one",
        .tenant_id = "tenant",
        .kind = .semantic,
        .content = "one",
        .created_unix_ms = 1,
    });
    try store.put(gpa, .{
        .id = "two",
        .tenant_id = "tenant",
        .kind = .semantic,
        .content = "two",
        .created_unix_ms = 2,
    });
    const Compact = struct {
        fn run(_: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const Entry) ![]u8 {
            return allocator.dupe(u8, "summary");
        }
    };
    _ = try store.compact(gpa, "tenant", 3, .{ .keep_recent_for_compaction = 1 }, .{
        .compact_fn = Compact.run,
    });
}

test "memory ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runMemoryWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compactMemoryWithAllocator,
        .{},
    );
}
