//! Provider-neutral, borrowed model metadata and deterministic ID resolution.
//!
//! A catalog never owns strings or profiles. Its entries, aliases, and all
//! returned resolutions borrow the caller's storage and must not outlive it.

const std = @import("std");
pub const model_types = @import("model.zig");
const model = model_types;
const provider = @import("provider.zig");

pub const Error = error{
    InvalidProviderName,
    InvalidModelId,
    InvalidModelAlias,
    InvalidModelSource,
    InvalidModelLimits,
    DuplicateModelIdentifier,
    InvalidModelDeprecation,
    InvalidDiscoveredModel,
    DuplicateDiscoveredModel,
};

pub const Limits = struct {
    context_window_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,

    pub fn validate(self: Limits) Error!void {
        if (self.context_window_tokens == 0 or self.max_output_tokens == 0)
            return error.InvalidModelLimits;
        if (self.context_window_tokens) |context| if (self.max_output_tokens) |output| {
            if (output > context) return error.InvalidModelLimits;
        };
    }
};

pub const Deprecation = struct {
    /// Optional stable catalog version or date at which deprecation began.
    since: ?[]const u8 = null,
    /// Optional provider-published removal date.
    sunset: ?[]const u8 = null,
    /// Canonical model ID in the same provider namespace.
    replacement: ?[]const u8 = null,
};

pub const Entry = struct {
    provider_name: []const u8,
    id: []const u8,
    aliases: []const []const u8 = &.{},
    /// Optional primary source used to review this metadata.
    source_url: ?[]const u8 = null,
    deprecation: ?Deprecation = null,
    limits: Limits = .{},
    /// Trusted capabilities. Absence stays unknown rather than widening them.
    profile: ?model.ModelProfile = null,
};

/// A borrowed resolution into a validated `Catalog`.
pub const ResolvedModel = struct {
    entry: *const Entry,
    /// Catalog-owned identifier that matched: the canonical ID or one alias.
    matched_id: []const u8,

    pub fn canonicalId(self: ResolvedModel) []const u8 {
        return self.entry.id;
    }

    pub fn providerName(self: ResolvedModel) []const u8 {
        return self.entry.provider_name;
    }

    pub fn wasAlias(self: ResolvedModel) bool {
        return !std.mem.eql(u8, self.matched_id, self.entry.id);
    }
};

/// A validated borrowed catalog. Resolution is exact, case-sensitive, and
/// scoped by provider identity. Canonical IDs and aliases share one namespace.
pub const Catalog = struct {
    entries: []const Entry,

    pub fn init(entries: []const Entry) Error!Catalog {
        const catalog = Catalog{ .entries = entries };
        try catalog.validate();
        return catalog;
    }

    pub fn validate(self: Catalog) Error!void {
        for (self.entries, 0..) |entry, index| {
            try validateEntry(entry);
            for (self.entries[0..index]) |previous| {
                if (!std.mem.eql(u8, previous.provider_name, entry.provider_name)) continue;
                if (entriesOverlap(previous, entry)) return error.DuplicateModelIdentifier;
            }
        }
        for (self.entries) |entry| if (entry.deprecation) |deprecation| {
            if (deprecation.replacement) |target_id| {
                if (std.mem.eql(u8, target_id, entry.id)) return error.InvalidModelDeprecation;
                _ = self.findCanonical(entry.provider_name, target_id) orelse
                    return error.InvalidModelDeprecation;
            }
        };
        for (self.entries) |entry| {
            var current = self.findCanonical(entry.provider_name, entry.id).?;
            var replacements: usize = 0;
            while (current.entry.deprecation) |deprecation| {
                const target_id = deprecation.replacement orelse break;
                current = self.findCanonical(entry.provider_name, target_id).?;
                replacements += 1;
                if (replacements >= self.entries.len) return error.InvalidModelDeprecation;
            }
        }
    }

    pub fn resolve(self: Catalog, provider_name: []const u8, requested_id: []const u8) ?ResolvedModel {
        for (self.entries) |*entry| {
            if (!std.mem.eql(u8, entry.provider_name, provider_name)) continue;
            if (std.mem.eql(u8, entry.id, requested_id)) return .{
                .entry = entry,
                .matched_id = entry.id,
            };
            for (entry.aliases) |alias| if (std.mem.eql(u8, alias, requested_id)) return .{
                .entry = entry,
                .matched_id = alias,
            };
        }
        return null;
    }

    pub fn replacement(self: Catalog, resolved: ResolvedModel) ?ResolvedModel {
        const replacement_id = (resolved.entry.deprecation orelse return null).replacement orelse return null;
        return self.findCanonical(resolved.entry.provider_name, replacement_id);
    }

    fn findCanonical(self: Catalog, provider_name: []const u8, id: []const u8) ?ResolvedModel {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.provider_name, provider_name) and
                std.mem.eql(u8, entry.id, id)) return .{ .entry = entry, .matched_id = entry.id };
        }
        return null;
    }
};

/// One borrowed provider discovery record joined to optional trusted catalog
/// metadata. The original descriptor remains visible, but only catalog data is
/// exposed as the trusted profile and limits.
pub const DiscoveryItem = struct {
    descriptor: *const provider.ModelDescriptor,
    catalog_entry: ?*const Entry,
    canonical_id: []const u8,

    pub fn wasAlias(self: DiscoveryItem) bool {
        return !std.mem.eql(u8, self.descriptor.id, self.canonical_id);
    }

    pub fn trustedProfile(self: DiscoveryItem) ?model.ModelProfile {
        const entry = self.catalog_entry orelse return null;
        return entry.profile;
    }

    pub fn limits(self: DiscoveryItem) ?Limits {
        const entry = self.catalog_entry orelse return null;
        return entry.limits;
    }

    pub fn deprecation(self: DiscoveryItem) ?Deprecation {
        const entry = self.catalog_entry orelse return null;
        return entry.deprecation;
    }
};

/// Owns only the merged index. Every `DiscoveryItem` borrows both the provider
/// discovery result and the catalog passed to `mergeDiscovery`.
pub const OwnedDiscovery = struct {
    allocator: std.mem.Allocator,
    items: []const DiscoveryItem,

    pub fn deinit(self: *OwnedDiscovery) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Joins live discovery to trusted catalog metadata without copying or
/// promoting provider-supplied profiles. Duplicate canonical results fail
/// instead of being silently deduplicated.
pub fn mergeDiscovery(
    allocator: std.mem.Allocator,
    catalog: Catalog,
    provider_name: []const u8,
    discovered: []const provider.ModelDescriptor,
) !OwnedDiscovery {
    try catalog.validate();
    if (!validIdentifier(provider_name)) return error.InvalidProviderName;
    const items = try allocator.alloc(DiscoveryItem, discovered.len);
    errdefer allocator.free(items);
    var count: usize = 0;
    for (discovered) |*descriptor| {
        if (!validIdentifier(descriptor.id)) return error.InvalidDiscoveredModel;
        const resolution = catalog.resolve(provider_name, descriptor.id);
        const canonical_id = if (resolution) |resolved| resolved.canonicalId() else descriptor.id;
        for (items[0..count]) |item| {
            if (std.mem.eql(u8, item.canonical_id, canonical_id))
                return error.DuplicateDiscoveredModel;
        }
        items[count] = .{
            .descriptor = descriptor,
            .catalog_entry = if (resolution) |resolved| resolved.entry else null,
            .canonical_id = canonical_id,
        };
        count += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

fn validateEntry(entry: Entry) Error!void {
    if (!validIdentifier(entry.provider_name)) return error.InvalidProviderName;
    if (!validIdentifier(entry.id)) return error.InvalidModelId;
    if (entry.source_url) |source_url| if (!validMetadata(source_url))
        return error.InvalidModelSource;
    try entry.limits.validate();
    for (entry.aliases, 0..) |alias, index| {
        if (!validIdentifier(alias) or std.mem.eql(u8, alias, entry.id))
            return error.InvalidModelAlias;
        for (entry.aliases[0..index]) |previous| {
            if (std.mem.eql(u8, previous, alias)) return error.DuplicateModelIdentifier;
        }
    }
    if (entry.deprecation) |deprecation| {
        if (deprecation.since) |since| if (!validMetadata(since)) return error.InvalidModelDeprecation;
        if (deprecation.sunset) |sunset| if (!validMetadata(sunset)) return error.InvalidModelDeprecation;
        if (deprecation.replacement) |replacement| if (!validIdentifier(replacement))
            return error.InvalidModelDeprecation;
    }
}

fn entriesOverlap(left: Entry, right: Entry) bool {
    if (identifierInEntry(left.id, right) or identifierInEntry(right.id, left)) return true;
    for (left.aliases) |alias| if (identifierInEntry(alias, right)) return true;
    return false;
}

fn identifierInEntry(identifier: []const u8, entry: Entry) bool {
    if (std.mem.eql(u8, identifier, entry.id)) return true;
    for (entry.aliases) |alias| if (std.mem.eql(u8, identifier, alias)) return true;
    return false;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return false;
    return true;
}

fn validMetadata(value: []const u8) bool {
    return value.len > 0 and std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

test "catalog resolves canonical IDs and aliases within provider namespaces" {
    const entries = [_]Entry{
        .{
            .provider_name = "openai",
            .id = "gpt-5.1",
            .aliases = &.{ "gpt-5", "best" },
            .limits = .{ .context_window_tokens = 400_000, .max_output_tokens = 128_000 },
            .profile = .{ .supports_streaming = true, .supports_json_schema_output = true },
        },
        .{
            .provider_name = "openai",
            .id = "gpt-4.1",
            .deprecation = .{
                .since = "2026-01-01",
                .sunset = "2026-12-01",
                .replacement = "gpt-5.1",
            },
        },
        .{ .provider_name = "other", .id = "gpt-5.1", .aliases = &.{"best"} },
    };
    const catalog = try Catalog.init(&entries);
    const canonical = catalog.resolve("openai", "gpt-5.1").?;
    try std.testing.expect(!canonical.wasAlias());
    try std.testing.expectEqualStrings("openai", canonical.providerName());
    try std.testing.expectEqualStrings("gpt-5.1", canonical.canonicalId());
    try std.testing.expect(canonical.entry.profile.?.supports_json_schema_output);
    try std.testing.expectEqual(@as(?u64, 400_000), canonical.entry.limits.context_window_tokens);

    const alias = catalog.resolve("openai", "best").?;
    try std.testing.expect(alias.wasAlias());
    try std.testing.expectEqualStrings("best", alias.matched_id);
    try std.testing.expectEqualStrings("gpt-5.1", alias.canonicalId());
    try std.testing.expectEqualStrings("other", catalog.resolve("other", "best").?.providerName());
    try std.testing.expect(catalog.resolve("openai", "missing") == null);
    try std.testing.expect(catalog.resolve("missing", "gpt-5.1") == null);

    const deprecated = catalog.resolve("openai", "gpt-4.1").?;
    const replacement = catalog.replacement(deprecated).?;
    try std.testing.expectEqualStrings("gpt-5.1", replacement.canonicalId());
    try std.testing.expect(catalog.replacement(canonical) == null);
}

test "catalog validation rejects invalid identity limits and deprecation metadata" {
    try std.testing.expectError(error.InvalidProviderName, Catalog.init(&.{.{ .provider_name = "", .id = "model" }}));
    try std.testing.expectError(error.InvalidProviderName, Catalog.init(&.{.{ .provider_name = "bad name", .id = "model" }}));
    try std.testing.expectError(error.InvalidModelId, Catalog.init(&.{.{ .provider_name = "test", .id = "bad\nmodel" }}));
    try std.testing.expectError(error.InvalidModelSource, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .source_url = "",
    }}));
    try std.testing.expectError(error.InvalidModelLimits, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .limits = .{ .context_window_tokens = 0 },
    }}));
    try std.testing.expectError(error.InvalidModelLimits, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .limits = .{ .context_window_tokens = 10, .max_output_tokens = 11 },
    }}));
    try std.testing.expectError(error.InvalidModelAlias, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .aliases = &.{"model"},
    }}));
    try std.testing.expectError(error.InvalidModelAlias, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .aliases = &.{""},
    }}));
    try std.testing.expectError(error.DuplicateModelIdentifier, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .aliases = &.{ "alias", "alias" },
    }}));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .deprecation = .{ .since = "" },
    }}));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .deprecation = .{ .sunset = "bad\nvalue" },
    }}));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model",
        .deprecation = .{ .replacement = "bad id" },
    }}));
}

test "catalog validation rejects identifier collisions and invalid replacements" {
    try std.testing.expectError(error.DuplicateModelIdentifier, Catalog.init(&.{
        .{ .provider_name = "test", .id = "one", .aliases = &.{"shared"} },
        .{ .provider_name = "test", .id = "two", .aliases = &.{"shared"} },
    }));
    try std.testing.expectError(error.DuplicateModelIdentifier, Catalog.init(&.{
        .{ .provider_name = "test", .id = "one" },
        .{ .provider_name = "test", .id = "two", .aliases = &.{"one"} },
    }));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "one",
        .deprecation = .{ .replacement = "one" },
    }}));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{.{
        .provider_name = "test",
        .id = "one",
        .deprecation = .{ .replacement = "missing" },
    }}));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{
        .{ .provider_name = "test", .id = "one", .deprecation = .{ .replacement = "new" } },
        .{ .provider_name = "test", .id = "two", .aliases = &.{"new"} },
    }));
    try std.testing.expectError(error.InvalidModelDeprecation, Catalog.init(&.{
        .{ .provider_name = "test", .id = "one", .deprecation = .{ .replacement = "two" } },
        .{ .provider_name = "test", .id = "two", .deprecation = .{ .replacement = "one" } },
    }));

    const no_replacement = try Catalog.init(&.{.{
        .provider_name = "test",
        .id = "old",
        .deprecation = .{},
    }});
    try std.testing.expect(no_replacement.replacement(no_replacement.resolve("test", "old").?) == null);
}

test "discovery merge keeps provider payloads separate from trusted catalog metadata" {
    const catalog = try Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model-v2",
        .aliases = &.{"latest"},
        .deprecation = .{},
        .limits = .{ .context_window_tokens = 100, .max_output_tokens = 20 },
        .profile = .{ .supports_tools = false, .supports_streaming = true },
    }});
    const discovered = [_]provider.ModelDescriptor{
        .{
            .id = "latest",
            .profile = .{ .supports_tools = true },
            .metadata_json = "{\"source\":\"provider\"}",
        },
        .{ .id = "unknown", .profile = .{ .supports_tools = true } },
    };
    var merged = try mergeDiscovery(std.testing.allocator, catalog, "test", &discovered);
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expect(merged.items[0].wasAlias());
    try std.testing.expectEqualStrings("model-v2", merged.items[0].canonical_id);
    try std.testing.expect(!merged.items[0].trustedProfile().?.supports_tools);
    try std.testing.expect(merged.items[0].trustedProfile().?.supports_streaming);
    try std.testing.expectEqual(@as(?u64, 100), merged.items[0].limits().?.context_window_tokens);
    try std.testing.expect(merged.items[0].deprecation() != null);
    try std.testing.expectEqualStrings(
        "{\"source\":\"provider\"}",
        merged.items[0].descriptor.metadata_json.?,
    );
    try std.testing.expect(!merged.items[1].wasAlias());
    try std.testing.expect(merged.items[1].trustedProfile() == null);
    try std.testing.expect(merged.items[1].limits() == null);
    try std.testing.expect(merged.items[1].deprecation() == null);
    try std.testing.expect(merged.items[1].descriptor.profile.?.supports_tools);
}

test "discovery merge rejects malformed and duplicate canonical results" {
    const catalog = try Catalog.init(&.{.{
        .provider_name = "test",
        .id = "model-v2",
        .aliases = &.{"latest"},
    }});
    try std.testing.expectError(
        error.InvalidProviderName,
        mergeDiscovery(std.testing.allocator, catalog, "bad provider", &.{}),
    );
    try std.testing.expectError(
        error.InvalidDiscoveredModel,
        mergeDiscovery(std.testing.allocator, catalog, "test", &.{.{ .id = "bad\nmodel" }}),
    );
    try std.testing.expectError(
        error.DuplicateDiscoveredModel,
        mergeDiscovery(std.testing.allocator, catalog, "test", &.{
            .{ .id = "model-v2" },
            .{ .id = "latest" },
        }),
    );
    const invalid_catalog = Catalog{ .entries = &.{.{
        .provider_name = "",
        .id = "model",
    }} };
    try std.testing.expectError(
        error.InvalidProviderName,
        mergeDiscovery(std.testing.allocator, invalid_catalog, "test", &.{}),
    );
}

fn exerciseDiscoveryMergeAllocation(allocator: std.mem.Allocator) !void {
    const catalog = try Catalog.init(&.{.{
        .provider_name = "test",
        .id = "known",
    }});
    var merged = try mergeDiscovery(allocator, catalog, "test", &.{
        .{ .id = "known" },
        .{ .id = "unknown" },
    });
    defer merged.deinit();
}

test "discovery merge releases every allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiscoveryMergeAllocation,
        .{},
    );
}
