//! Provider-neutral request and run usage accounting.

const std = @import("std");

/// One provider-native integer counter that does not have a first-class field.
/// Names and the enclosing slice are borrowed from their owner.
pub const Detail = struct {
    name: []const u8,
    value: u64,
};

/// An exact USD amount represented as billionths of one dollar.
pub const Cost = struct {
    nano_usd: u64,

    pub fn fromUsd(value: f64) error{InvalidCost}!Cost {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCost;
        const scaled = value * nano_usd_per_usd;
        if (scaled > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidCost;
        return .{ .nano_usd = @intFromFloat(@round(scaled)) };
    }

    pub fn usd(self: Cost) f64 {
        return @as(f64, @floatFromInt(self.nano_usd)) / nano_usd_per_usd;
    }

    pub const nano_usd_per_usd: u64 = 1_000_000_000;
};

pub const CostSource = enum {
    provider,
    price_table,
    mixed,
};

/// Usage reported for one successful provider response. Input and output
/// totals include their cached, audio, and reasoning subsets.
pub const RequestUsage = struct {
    input_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    output_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    input_audio_tokens: u64 = 0,
    cache_audio_read_tokens: u64 = 0,
    output_audio_tokens: u64 = 0,
    details: []const Detail = &.{},
    cost: ?Cost = null,
    cost_source: ?CostSource = null,
    /// Set only for price-table estimates. The slice is borrowed from the
    /// selected table, which must outlive the run.
    cost_table_version: ?[]const u8 = null,
    /// End-to-end provider latency measured by the agent. Direct model calls
    /// leave this null because the provider does not own the clock.
    duration_ms: ?u64 = null,

    pub fn totalTokens(self: RequestUsage) u64 {
        return self.input_tokens +| self.output_tokens;
    }

    pub fn detail(self: RequestUsage, name: []const u8) ?u64 {
        for (self.details) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
        return null;
    }

    pub fn hasValues(self: RequestUsage) bool {
        return self.totalTokens() != 0 or self.cache_write_tokens != 0 or self.cache_read_tokens != 0 or
            self.reasoning_tokens != 0 or self.input_audio_tokens != 0 or self.cache_audio_read_tokens != 0 or
            self.output_audio_tokens != 0 or self.details.len != 0 or self.cost != null or self.duration_ms != null;
    }

    /// Deep-copies all borrowed request-usage storage into `arena`.
    pub fn dupe(self: RequestUsage, arena: std.mem.Allocator) std.mem.Allocator.Error!RequestUsage {
        var copy = self;
        const details = try arena.alloc(Detail, self.details.len);
        for (self.details, details) |item, *target| target.* = .{
            .name = try arena.dupe(u8, item.name),
            .value = item.value,
        };
        copy.details = details;
        copy.cost_table_version = if (self.cost_table_version) |version|
            try arena.dupe(u8, version)
        else
            null;
        return copy;
    }
};

/// Usage accumulated across one complete or paused agent run. `details` is an
/// aggregate by name. Its storage follows the enclosing result arena.
pub const RunUsage = struct {
    input_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    output_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    input_audio_tokens: u64 = 0,
    cache_audio_read_tokens: u64 = 0,
    output_audio_tokens: u64 = 0,
    details: []const Detail = &.{},
    cost: ?Cost = null,
    cost_source: ?CostSource = null,
    cost_table_version: ?[]const u8 = null,
    requests: usize = 0,
    tool_calls: usize = 0,
    request_duration_ms: u64 = 0,
    run_duration_ms: u64 = 0,

    pub fn totalTokens(self: RunUsage) u64 {
        return self.input_tokens +| self.output_tokens;
    }

    pub fn detail(self: RunUsage, name: []const u8) ?u64 {
        for (self.details) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
        return null;
    }

    /// Records one provider attempt, including attempts that later fail and
    /// are retried. A null duration means the run has no monotonic clock.
    pub fn recordRequest(self: *RunUsage, duration_ms: ?u64) error{UsageOverflow}!void {
        const requests = std.math.add(usize, self.requests, 1) catch return error.UsageOverflow;
        const request_duration_ms = if (duration_ms) |duration|
            std.math.add(u64, self.request_duration_ms, duration) catch return error.UsageOverflow
        else
            self.request_duration_ms;
        self.requests = requests;
        self.request_duration_ms = request_duration_ms;
    }

    /// Adds one completed provider response. Detail storage is allocated from
    /// `allocator`; callers normally pass the arena that owns the run result.
    pub fn addRequest(
        self: *RunUsage,
        allocator: std.mem.Allocator,
        request: RequestUsage,
    ) (std.mem.Allocator.Error || error{UsageOverflow})!void {
        var next = self.*;
        try addTokenFields(&next, request);
        try addCost(allocator, &next, request.cost, request.cost_source, request.cost_table_version);
        next.details = try mergeDetails(allocator, self.details, request.details);
        self.* = next;
    }

    /// Adds another run, including its request, tool, latency, and cost totals.
    pub fn addRun(
        self: *RunUsage,
        allocator: std.mem.Allocator,
        other: RunUsage,
    ) (std.mem.Allocator.Error || error{UsageOverflow})!void {
        var next = self.*;
        try addTokenFields(&next, other);
        next.requests = std.math.add(usize, next.requests, other.requests) catch return error.UsageOverflow;
        next.tool_calls = std.math.add(usize, next.tool_calls, other.tool_calls) catch return error.UsageOverflow;
        next.request_duration_ms = std.math.add(u64, next.request_duration_ms, other.request_duration_ms) catch
            return error.UsageOverflow;
        next.run_duration_ms = std.math.add(u64, next.run_duration_ms, other.run_duration_ms) catch
            return error.UsageOverflow;
        try addCost(allocator, &next, other.cost, other.cost_source, other.cost_table_version);
        next.details = try mergeDetails(allocator, self.details, other.details);
        self.* = next;
    }

    /// Deep-copies all borrowed run-usage storage into `allocator`.
    pub fn dupe(self: RunUsage, allocator: std.mem.Allocator) std.mem.Allocator.Error!RunUsage {
        var copy = self;
        const details = try allocator.alloc(Detail, self.details.len);
        for (self.details, details) |item, *target| target.* = .{
            .name = try allocator.dupe(u8, item.name),
            .value = item.value,
        };
        copy.details = details;
        copy.cost_table_version = if (self.cost_table_version) |version|
            try allocator.dupe(u8, version)
        else
            null;
        return copy;
    }
};

/// Compatibility name for the original per-response usage type.
pub const Usage = RequestUsage;

fn addTokenFields(target: anytype, source: anytype) error{UsageOverflow}!void {
    inline for (.{
        "input_tokens",
        "cache_write_tokens",
        "cache_read_tokens",
        "output_tokens",
        "reasoning_tokens",
        "input_audio_tokens",
        "cache_audio_read_tokens",
        "output_audio_tokens",
    }) |name| {
        @field(target, name) = std.math.add(u64, @field(target, name), @field(source, name)) catch
            return error.UsageOverflow;
    }
}

fn mergeDetails(
    allocator: std.mem.Allocator,
    left: []const Detail,
    right: []const Detail,
) (std.mem.Allocator.Error || error{UsageOverflow})![]const Detail {
    if (right.len == 0) return left;
    var merged: std.ArrayList(Detail) = .empty;
    defer merged.deinit(allocator);
    try merged.appendSlice(allocator, left);
    for (right) |incoming| {
        var found = false;
        for (merged.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, incoming.name)) continue;
            existing.value = std.math.add(u64, existing.value, incoming.value) catch return error.UsageOverflow;
            found = true;
            break;
        }
        if (!found) try merged.append(allocator, .{
            .name = try allocator.dupe(u8, incoming.name),
            .value = incoming.value,
        });
    }
    return merged.toOwnedSlice(allocator);
}

fn addCost(
    allocator: std.mem.Allocator,
    target: *RunUsage,
    incoming: ?Cost,
    source: ?CostSource,
    table_version: ?[]const u8,
) (std.mem.Allocator.Error || error{UsageOverflow})!void {
    const value = incoming orelse return;
    if (target.cost) |current| {
        target.cost = .{ .nano_usd = std.math.add(u64, current.nano_usd, value.nano_usd) catch
            return error.UsageOverflow };
        const same_source = target.cost_source == source;
        const same_version = optionalStringsEqual(target.cost_table_version, table_version);
        if (!same_source or !same_version) {
            target.cost_source = .mixed;
            target.cost_table_version = null;
        }
        return;
    }
    target.cost = value;
    target.cost_source = source;
    target.cost_table_version = if (table_version) |version| try allocator.dupe(u8, version) else null;
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "request usage exposes inclusive totals and details" {
    const value = RequestUsage{
        .input_tokens = 10,
        .cache_read_tokens = 4,
        .output_tokens = 5,
        .reasoning_tokens = 2,
        .details = &.{.{ .name = "provider_counter", .value = 7 }},
    };
    try std.testing.expectEqual(@as(u64, 15), value.totalTokens());
    try std.testing.expectEqual(@as(u64, 7), value.detail("provider_counter").?);
    try std.testing.expect(value.detail("missing") == null);
    try std.testing.expect(value.hasValues());
    try std.testing.expect(!(RequestUsage{}).hasValues());
}

test "run usage aggregates counters details costs and latency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var total = RunUsage{ .details = &.{.{ .name = "shared", .value = 2 }} };
    try total.recordRequest(9);
    try total.addRequest(arena.allocator(), .{
        .input_tokens = 8,
        .output_tokens = 3,
        .details = &.{
            .{ .name = "shared", .value = 4 },
            .{ .name = "native", .value = 1 },
        },
        .cost = .{ .nano_usd = 50 },
        .cost_source = .price_table,
        .cost_table_version = "test-v1",
    });
    try std.testing.expectEqual(@as(usize, 1), total.requests);
    try std.testing.expectEqual(@as(u64, 9), total.request_duration_ms);
    try std.testing.expectEqual(@as(u64, 6), total.detail("shared").?);
    try std.testing.expectEqual(@as(u64, 1), total.detail("native").?);
    try std.testing.expectEqual(@as(u64, 50), total.cost.?.nano_usd);
    try std.testing.expectEqual(CostSource.price_table, total.cost_source.?);
    try std.testing.expectEqualStrings("test-v1", total.cost_table_version.?);
    try std.testing.expect(total.detail("missing") == null);

    try total.addRun(arena.allocator(), .{
        .cost = .{ .nano_usd = 5 },
        .cost_source = .price_table,
        .cost_table_version = "test-v1",
    });
    try std.testing.expectEqual(CostSource.price_table, total.cost_source.?);
    try total.addRun(arena.allocator(), .{
        .input_tokens = 2,
        .details = &.{.{ .name = "third", .value = 3 }},
        .cost = .{ .nano_usd = 25 },
        .cost_source = .provider,
        .requests = 2,
        .tool_calls = 1,
        .request_duration_ms = 4,
        .run_duration_ms = 5,
    });
    try std.testing.expectEqual(CostSource.mixed, total.cost_source.?);
    try std.testing.expect(total.cost_table_version == null);
    try std.testing.expectEqual(@as(usize, 3), total.requests);
    try std.testing.expectEqual(@as(usize, 1), total.tool_calls);
    const copied = try total.dupe(arena.allocator());
    try std.testing.expectEqualStrings("third", copied.details[copied.details.len - 1].name);
}

test "cost conversion rejects invalid values" {
    try std.testing.expectEqual(@as(u64, 1_250_000_000), (try Cost.fromUsd(1.25)).nano_usd);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), (Cost{ .nano_usd = 1_250_000_000 }).usd(), 0.000000001);
    try std.testing.expectError(error.InvalidCost, Cost.fromUsd(-1));
    try std.testing.expectError(error.InvalidCost, Cost.fromUsd(std.math.nan(f64)));
}

test "usage aggregation reports overflow" {
    var total = RunUsage{ .input_tokens = std.math.maxInt(u64) };
    try std.testing.expectError(error.UsageOverflow, total.addRequest(std.testing.allocator, .{ .input_tokens = 1 }));
    total = .{ .requests = std.math.maxInt(usize) };
    try std.testing.expectError(error.UsageOverflow, total.recordRequest(null));
    total = .{ .cost = .{ .nano_usd = std.math.maxInt(u64) } };
    try std.testing.expectError(error.UsageOverflow, total.addRequest(std.testing.allocator, .{
        .cost = .{ .nano_usd = 1 },
    }));
}

test "usage detail aggregation cleans up allocation failures" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var total = RunUsage{ .details = &.{.{ .name = "one", .value = 1 }} };
            try total.addRequest(arena.allocator(), .{ .details = &.{.{ .name = "two", .value = 2 }} });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
