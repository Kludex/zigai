//! Public API deprecation metadata and persisted-format migration guarantees.

const std = @import("std");

pub const current_version = Version{ .major = 0, .minor = 1, .patch = 0 };
pub const minimum_zig_version = "0.16.0";

/// Semantic version used by compatibility metadata.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(value: []const u8) !Version {
        var parts = std.mem.splitScalar(u8, value, '.');
        const major = try parsePart(parts.next() orelse return error.InvalidVersion);
        const minor = try parsePart(parts.next() orelse return error.InvalidVersion);
        const patch = try parsePart(parts.next() orelse return error.InvalidVersion);
        if (parts.next() != null) return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn order(left: Version, right: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |field| {
            const result = std.math.order(@field(left, field), @field(right, field));
            if (result != .eq) return result;
        }
        return .eq;
    }

    fn parsePart(value: []const u8) !u32 {
        if (value.len == 0) return error.InvalidVersion;
        return std.fmt.parseInt(u32, value, 10) catch return error.InvalidVersion;
    }
};

/// Public symbol deprecation schedule.
pub const Deprecation = struct {
    symbol: []const u8,
    replacement: []const u8,
    deprecated_since: Version,
    removal_no_earlier_than: Version,

    pub fn removable(self: Deprecation, release: Version) bool {
        return Version.order(release, self.removal_no_earlier_than) != .lt;
    }
};

/// Current public deprecations. Aliases remain available through their removal release.
pub const deprecations = [_]Deprecation{.{
    .symbol = "zigai.Usage",
    .replacement = "zigai.RequestUsage",
    .deprecated_since = .{ .major = 0, .minor = 1, .patch = 0 },
    .removal_no_earlier_than = .{ .major = 1, .minor = 0, .patch = 0 },
}};

pub fn deprecation(symbol: []const u8) ?Deprecation {
    for (deprecations) |item| if (std.mem.eql(u8, item.symbol, symbol)) return item;
    return null;
}

/// Persisted format and its guaranteed reader/migration range.
pub const MigrationGuarantee = struct {
    format: []const u8,
    current: u32,
    oldest_readable: u32,
    migration: Migration,

    pub const Migration = enum {
        built_in,
        application_callback,
        exact_only,
    };
};

pub const migration_guarantees = [_]MigrationGuarantee{
    .{ .format = "history", .current = 2, .oldest_readable = 1, .migration = .built_in },
    .{ .format = "paused_agent_run", .current = 2, .oldest_readable = 2, .migration = .exact_only },
    .{ .format = "durable_record", .current = 1, .oldest_readable = 1, .migration = .exact_only },
    .{ .format = "durable_checkpoint", .current = 2, .oldest_readable = 1, .migration = .built_in },
    .{ .format = "graph_snapshot", .current = 1, .oldest_readable = 1, .migration = .application_callback },
    .{ .format = "eval_dataset", .current = 1, .oldest_readable = 1, .migration = .exact_only },
    .{ .format = "eval_report", .current = 1, .oldest_readable = 1, .migration = .exact_only },
};

pub fn migrationGuarantee(format: []const u8) ?MigrationGuarantee {
    for (migration_guarantees) |guarantee| {
        if (std.mem.eql(u8, guarantee.format, format)) return guarantee;
    }
    return null;
}

test "compatibility versions deprecations and migrations are reviewable" {
    try std.testing.expectEqual(current_version, try Version.parse("0.1.0"));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(current_version, .{ .major = 1, .minor = 0, .patch = 0 }));
    try std.testing.expectError(error.InvalidVersion, Version.parse("0.1"));
    const usage = deprecation("zigai.Usage").?;
    try std.testing.expect(!usage.removable(current_version));
    try std.testing.expect(usage.removable(.{ .major = 1, .minor = 0, .patch = 0 }));
    try std.testing.expect(deprecation("zigai.Agent") == null);
    const history = migrationGuarantee("history").?;
    try std.testing.expectEqual(MigrationGuarantee.Migration.built_in, history.migration);
    try std.testing.expect(migrationGuarantee("unknown") == null);
}
