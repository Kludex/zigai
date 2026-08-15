//! Capability identity, discovery metadata, dependency planning, and scope labels.
//!
//! Registry entries borrow their strings and metadata. Load resolutions own an
//! arena and remain valid until `deinit`; the registry never owns capability
//! implementations or executes agent behavior.

const std = @import("std");
const messages = @import("messages.zig");

pub const Metadata = messages.Metadata;

/// Whether a capability is available immediately or disclosed by name first.
pub const Loading = enum {
    eager,
    on_demand,
};

/// How an on-demand load survives the invocation that performed it.
pub const UnloadPolicy = enum {
    /// Forget the load when the current run ends.
    run_end,
    /// Reconstruct the load from canonical message history in later runs.
    history,
};

/// The composition layer that contributed a capability.
pub const Scope = enum {
    inherited,
    agent,
    run,
    nested,
    subagent,
};

/// Borrowed progressive-disclosure state exposed to run callbacks and tools.
pub const Snapshot = struct {
    /// Stable IDs whose complete bundles are currently active.
    available_ids: []const []const u8 = &.{},
    /// Active IDs that entered through on-demand loading.
    loaded_ids: []const []const u8 = &.{},
};

/// Stable discovery and composition data for one capability implementation.
pub const Descriptor = struct {
    /// Stable identifier used by dependencies and on-demand loading.
    id: ?[]const u8 = null,
    /// Short model-facing catalog text for an on-demand capability.
    description: ?[]const u8 = null,
    /// Application-only key/value data.
    metadata: []const Metadata = &.{},
    /// Capability IDs that must activate first, in declaration order.
    dependencies: []const []const u8 = &.{},
    /// Capability IDs that may not be active at the same time.
    conflicts: []const []const u8 = &.{},
    /// Whether the implementation starts active or is disclosed by name first.
    loading: Loading = .eager,
    /// Whether history reconstructs a successful load in later invocations.
    unload_policy: UnloadPolicy = .history,
};

/// One descriptor in its deterministic composition layer and source order.
pub const Entry = struct {
    /// Borrowed identity and dependency data.
    descriptor: Descriptor,
    /// Fixed composition tier for diagnostics and deterministic ordering.
    scope: Scope,
    /// Declaration position inside the source layer.
    source_index: usize,
};

/// Stable categories returned by registry validation and load planning.
pub const DiagnosticKind = enum {
    too_many_capabilities,
    too_many_metadata,
    too_many_dependencies,
    too_many_conflicts,
    invalid_id,
    missing_id,
    duplicate_id,
    duplicate_metadata,
    duplicate_dependency,
    duplicate_conflict,
    missing_dependency,
    missing_conflict,
    dependency_cycle,
    self_conflict,
    active_conflict,
    unknown_capability,
    invalid_active_state,
};

/// Borrowed details for the first deterministic registry or load failure.
pub const Diagnostic = struct {
    /// Machine-readable failure category.
    kind: DiagnosticKind,
    /// Capability primarily responsible for the failure, when known.
    capability_id: ?[]const u8 = null,
    /// Dependency, conflict, or metadata key related to the failure.
    related_id: ?[]const u8 = null,
    /// Composition scope of `capability_id`.
    scope: ?Scope = null,
    /// Composition scope of `related_id` when it identifies a capability.
    related_scope: ?Scope = null,
};

/// Defensive limits applied before dependency traversal.
pub const Limits = struct {
    /// Maximum number of composed registry entries.
    max_capabilities: usize = 256,
    /// Maximum application metadata entries on any one capability.
    max_metadata_per_capability: usize = 64,
    /// Maximum direct dependency count on any one capability.
    max_dependencies_per_capability: usize = 64,
    /// Maximum direct conflict count on any one capability.
    max_conflicts_per_capability: usize = 64,
};

/// Arena-owned dependency order or a borrowed diagnostic.
pub const LoadResolution = struct {
    arena: std.heap.ArenaAllocator,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        /// Registry indexes in dependency-first activation order.
        plan: []const usize,
        diagnostic: Diagnostic,
    };

    pub fn deinit(self: *LoadResolution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrowed registry view. Entry order is the composition order.
pub const Registry = struct {
    /// Borrowed entries in deterministic composition order.
    entries: []const Entry,
    /// Validation bounds for untrusted or generated registries.
    limits: Limits = .{},

    /// Returns the first structural problem, or null when the registry is valid.
    pub fn diagnose(self: Registry, gpa: std.mem.Allocator) !?Diagnostic {
        if (self.entries.len > self.limits.max_capabilities) return .{ .kind = .too_many_capabilities };
        for (self.entries, 0..) |entry, index| {
            const descriptor = entry.descriptor;
            if (descriptor.metadata.len > self.limits.max_metadata_per_capability) return .{
                .kind = .too_many_metadata,
                .capability_id = descriptor.id,
                .scope = entry.scope,
            };
            if (descriptor.dependencies.len > self.limits.max_dependencies_per_capability) return .{
                .kind = .too_many_dependencies,
                .capability_id = descriptor.id,
                .scope = entry.scope,
            };
            if (descriptor.conflicts.len > self.limits.max_conflicts_per_capability) return .{
                .kind = .too_many_conflicts,
                .capability_id = descriptor.id,
                .scope = entry.scope,
            };
            if (descriptor.loading == .on_demand or
                descriptor.dependencies.len > 0 or descriptor.conflicts.len > 0)
            {
                if (descriptor.id == null) return .{ .kind = .missing_id, .scope = entry.scope };
            }
            if (descriptor.id) |id| {
                if (!validId(id)) return .{
                    .kind = .invalid_id,
                    .capability_id = id,
                    .scope = entry.scope,
                };
                for (self.entries[0..index]) |previous| if (previous.descriptor.id) |previous_id| {
                    if (std.mem.eql(u8, previous_id, id)) return .{
                        .kind = .duplicate_id,
                        .capability_id = id,
                        .scope = entry.scope,
                        .related_scope = previous.scope,
                    };
                };
                for (descriptor.metadata, 0..) |metadata, metadata_index| {
                    for (descriptor.metadata[0..metadata_index]) |previous| {
                        if (std.mem.eql(u8, previous.key, metadata.key)) return .{
                            .kind = .duplicate_metadata,
                            .capability_id = id,
                            .related_id = metadata.key,
                            .scope = entry.scope,
                        };
                    }
                }
                for (descriptor.dependencies, 0..) |dependency, dependency_index| {
                    for (descriptor.dependencies[0..dependency_index]) |previous| {
                        if (std.mem.eql(u8, previous, dependency)) return .{
                            .kind = .duplicate_dependency,
                            .capability_id = id,
                            .related_id = dependency,
                            .scope = entry.scope,
                        };
                    }
                    if (self.findIndex(dependency) == null) return .{
                        .kind = .missing_dependency,
                        .capability_id = id,
                        .related_id = dependency,
                        .scope = entry.scope,
                    };
                }
                for (descriptor.conflicts, 0..) |conflict, conflict_index| {
                    for (descriptor.conflicts[0..conflict_index]) |previous| {
                        if (std.mem.eql(u8, previous, conflict)) return .{
                            .kind = .duplicate_conflict,
                            .capability_id = id,
                            .related_id = conflict,
                            .scope = entry.scope,
                        };
                    }
                    if (std.mem.eql(u8, id, conflict)) return .{
                        .kind = .self_conflict,
                        .capability_id = id,
                        .related_id = conflict,
                        .scope = entry.scope,
                    };
                    if (self.findIndex(conflict) == null) return .{
                        .kind = .missing_conflict,
                        .capability_id = id,
                        .related_id = conflict,
                        .scope = entry.scope,
                    };
                }
            }
        }

        const colors = try gpa.alloc(Color, self.entries.len);
        defer gpa.free(colors);
        @memset(colors, .unvisited);
        for (self.entries, 0..) |_, index| {
            if (self.visitForCycle(colors, index)) |diagnostic| return diagnostic;
        }
        return null;
    }

    /// Resolves one ID and all inactive dependencies in declaration order.
    pub fn resolve(
        self: Registry,
        gpa: std.mem.Allocator,
        capability_id: []const u8,
        active: []const bool,
    ) !LoadResolution {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        if (active.len != self.entries.len) return .{
            .arena = arena,
            .outcome = .{ .diagnostic = .{ .kind = .invalid_active_state } },
        };
        if (try self.diagnose(arena.allocator())) |diagnostic| return .{
            .arena = arena,
            .outcome = .{ .diagnostic = diagnostic },
        };
        const target = self.findIndex(capability_id) orelse return .{
            .arena = arena,
            .outcome = .{ .diagnostic = .{
                .kind = .unknown_capability,
                .capability_id = capability_id,
            } },
        };

        const colors = try arena.allocator().alloc(Color, self.entries.len);
        @memset(colors, .unvisited);
        var plan: std.ArrayList(usize) = .empty;
        if (try self.visitForLoad(arena.allocator(), colors, active, &plan, target)) |diagnostic| return .{
            .arena = arena,
            .outcome = .{ .diagnostic = diagnostic },
        };
        return .{ .arena = arena, .outcome = .{ .plan = try plan.toOwnedSlice(arena.allocator()) } };
    }

    /// Returns the composition index for `id`, or null when it is unknown.
    pub fn findIndex(self: Registry, id: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.descriptor.id) |candidate| {
                if (std.mem.eql(u8, candidate, id)) return index;
            }
        }
        return null;
    }

    fn visitForCycle(self: Registry, colors: []Color, index: usize) ?Diagnostic {
        switch (colors[index]) {
            .visited => return null,
            .visiting => return .{
                .kind = .dependency_cycle,
                .capability_id = self.entries[index].descriptor.id,
                .scope = self.entries[index].scope,
            },
            .unvisited => {},
        }
        colors[index] = .visiting;
        const descriptor = self.entries[index].descriptor;
        for (descriptor.dependencies) |dependency| {
            const dependency_index = self.findIndex(dependency).?;
            if (self.visitForCycle(colors, dependency_index)) |diagnostic| return diagnostic;
        }
        colors[index] = .visited;
        return null;
    }

    fn visitForLoad(
        self: Registry,
        gpa: std.mem.Allocator,
        colors: []Color,
        active: []const bool,
        plan: *std.ArrayList(usize),
        index: usize,
    ) !?Diagnostic {
        if (active[index] or colors[index] == .visited) return null;
        if (colors[index] == .visiting) return .{
            .kind = .dependency_cycle,
            .capability_id = self.entries[index].descriptor.id,
            .scope = self.entries[index].scope,
        };
        colors[index] = .visiting;
        const entry = self.entries[index];
        for (entry.descriptor.dependencies) |dependency| {
            const dependency_index = self.findIndex(dependency).?;
            if (try self.visitForLoad(gpa, colors, active, plan, dependency_index)) |diagnostic| return diagnostic;
        }
        for (self.entries, 0..) |other, other_index| {
            if (!active[other_index] and colors[other_index] != .visited) continue;
            if (conflicts(entry.descriptor, other.descriptor)) return .{
                .kind = .active_conflict,
                .capability_id = entry.descriptor.id,
                .related_id = other.descriptor.id,
                .scope = entry.scope,
                .related_scope = other.scope,
            };
        }
        colors[index] = .visited;
        try plan.append(gpa, index);
        return null;
    }
};

const Color = enum { unvisited, visiting, visited };

fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id, 0..) |byte, index| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!valid or (index == 0 and !std.ascii.isAlphanumeric(byte))) return false;
    }
    return true;
}

fn conflicts(left: Descriptor, right: Descriptor) bool {
    const left_id = left.id orelse return false;
    const right_id = right.id orelse return false;
    for (left.conflicts) |id| if (std.mem.eql(u8, id, right_id)) return true;
    for (right.conflicts) |id| if (std.mem.eql(u8, id, left_id)) return true;
    return false;
}

test "registry validates identity metadata dependencies and cycles" {
    const entries = [_]Entry{
        .{ .descriptor = .{ .id = "base" }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{
            .id = "feature",
            .metadata = &.{.{ .key = "owner", .value = "app" }},
            .dependencies = &.{"base"},
            .loading = .on_demand,
        }, .scope = .run, .source_index = 0 },
    };
    try std.testing.expectEqual(@as(?Diagnostic, null), try (Registry{ .entries = &entries }).diagnose(
        std.testing.allocator,
    ));

    const duplicate = [_]Entry{
        .{ .descriptor = .{ .id = "same" }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "same" }, .scope = .nested, .source_index = 0 },
    };
    const duplicate_diagnostic = (try (Registry{ .entries = &duplicate }).diagnose(std.testing.allocator)).?;
    try std.testing.expectEqual(DiagnosticKind.duplicate_id, duplicate_diagnostic.kind);
    try std.testing.expectEqual(Scope.nested, duplicate_diagnostic.scope.?);
    try std.testing.expectEqual(Scope.agent, duplicate_diagnostic.related_scope.?);

    const cycle = [_]Entry{
        .{ .descriptor = .{ .id = "one", .dependencies = &.{"two"} }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "two", .dependencies = &.{"one"} }, .scope = .run, .source_index = 0 },
    };
    const cycle_diagnostic = (try (Registry{ .entries = &cycle }).diagnose(std.testing.allocator)).?;
    try std.testing.expectEqual(DiagnosticKind.dependency_cycle, cycle_diagnostic.kind);
}

test "registry resolves dependencies first and reports active conflicts" {
    const entries = [_]Entry{
        .{ .descriptor = .{ .id = "base" }, .scope = .inherited, .source_index = 0 },
        .{ .descriptor = .{ .id = "search", .conflicts = &.{"offline"} }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{
            .id = "research",
            .dependencies = &.{ "base", "search" },
            .loading = .on_demand,
        }, .scope = .subagent, .source_index = 0 },
        .{ .descriptor = .{ .id = "offline" }, .scope = .run, .source_index = 0 },
    };
    const registry = Registry{ .entries = &entries };
    var resolved = try registry.resolve(std.testing.allocator, "research", &.{ false, false, false, false });
    defer resolved.deinit();
    try std.testing.expect(resolved.outcome == .plan);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, resolved.outcome.plan);

    var conflict = try registry.resolve(std.testing.allocator, "research", &.{ false, false, false, true });
    defer conflict.deinit();
    try std.testing.expect(conflict.outcome == .diagnostic);
    const diagnostic = conflict.outcome.diagnostic;
    try std.testing.expectEqual(DiagnosticKind.active_conflict, diagnostic.kind);
    try std.testing.expectEqualStrings("search", diagnostic.capability_id.?);
    try std.testing.expectEqualStrings("offline", diagnostic.related_id.?);
}

test "registry reports every structural diagnostic" {
    const unnamed = [_]Entry{.{
        .descriptor = .{},
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        @as(?Diagnostic, null),
        try (Registry{ .entries = &unnamed }).diagnose(std.testing.allocator),
    );
    try std.testing.expectEqual(
        DiagnosticKind.too_many_capabilities,
        (try (Registry{ .entries = &unnamed, .limits = .{ .max_capabilities = 0 } }).diagnose(
            std.testing.allocator,
        )).?.kind,
    );
    const excessive_dependencies = [_]Entry{.{
        .descriptor = .{ .id = "limited", .dependencies = &.{"limited"} },
        .scope = .agent,
        .source_index = 0,
    }};
    const dependency_limit_diagnostic = (try (Registry{
        .entries = &excessive_dependencies,
        .limits = .{ .max_dependencies_per_capability = 0 },
    }).diagnose(std.testing.allocator)).?;
    try std.testing.expectEqual(DiagnosticKind.too_many_dependencies, dependency_limit_diagnostic.kind);
    const metadata_limit = [_]Entry{.{
        .descriptor = .{ .id = "limited", .metadata = &.{.{ .key = "owner", .value = "app" }} },
        .scope = .agent,
        .source_index = 0,
    }};
    const metadata_limit_diagnostic = (try (Registry{
        .entries = &metadata_limit,
        .limits = .{ .max_metadata_per_capability = 0 },
    }).diagnose(std.testing.allocator)).?;
    try std.testing.expectEqual(DiagnosticKind.too_many_metadata, metadata_limit_diagnostic.kind);
    const conflict_limit = [_]Entry{
        .{ .descriptor = .{ .id = "limited", .conflicts = &.{"other"} }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "other" }, .scope = .run, .source_index = 0 },
    };
    const conflict_limit_diagnostic = (try (Registry{
        .entries = &conflict_limit,
        .limits = .{ .max_conflicts_per_capability = 0 },
    }).diagnose(std.testing.allocator)).?;
    try std.testing.expectEqual(DiagnosticKind.too_many_conflicts, conflict_limit_diagnostic.kind);
    const missing_id = [_]Entry{.{
        .descriptor = .{ .loading = .on_demand },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.missing_id,
        (try (Registry{ .entries = &missing_id }).diagnose(std.testing.allocator)).?.kind,
    );
    const invalid_id = [_]Entry{.{
        .descriptor = .{ .id = "bad id" },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.invalid_id,
        (try (Registry{ .entries = &invalid_id }).diagnose(std.testing.allocator)).?.kind,
    );
    const empty_id = [_]Entry{.{
        .descriptor = .{ .id = "" },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.invalid_id,
        (try (Registry{ .entries = &empty_id }).diagnose(std.testing.allocator)).?.kind,
    );
    const metadata = [_]Metadata{
        .{ .key = "owner", .value = "one" },
        .{ .key = "owner", .value = "two" },
    };
    const duplicate_metadata = [_]Entry{.{
        .descriptor = .{ .id = "valid", .metadata = &metadata },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.duplicate_metadata,
        (try (Registry{ .entries = &duplicate_metadata }).diagnose(std.testing.allocator)).?.kind,
    );
    const missing_dependency = [_]Entry{.{
        .descriptor = .{ .id = "valid", .dependencies = &.{"missing"} },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.missing_dependency,
        (try (Registry{ .entries = &missing_dependency }).diagnose(std.testing.allocator)).?.kind,
    );
    const duplicate_dependency = [_]Entry{
        .{ .descriptor = .{ .id = "base" }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "child", .dependencies = &.{ "base", "base" } }, .scope = .run, .source_index = 0 },
    };
    try std.testing.expectEqual(
        DiagnosticKind.duplicate_dependency,
        (try (Registry{ .entries = &duplicate_dependency }).diagnose(std.testing.allocator)).?.kind,
    );
    const self_conflict = [_]Entry{.{
        .descriptor = .{ .id = "valid", .conflicts = &.{"valid"} },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.self_conflict,
        (try (Registry{ .entries = &self_conflict }).diagnose(std.testing.allocator)).?.kind,
    );
    const missing_conflict = [_]Entry{.{
        .descriptor = .{ .id = "online", .conflicts = &.{"offline"} },
        .scope = .agent,
        .source_index = 0,
    }};
    try std.testing.expectEqual(
        DiagnosticKind.missing_conflict,
        (try (Registry{ .entries = &missing_conflict }).diagnose(std.testing.allocator)).?.kind,
    );
    const duplicate_conflict = [_]Entry{
        .{ .descriptor = .{ .id = "online", .conflicts = &.{ "offline", "offline" } }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "offline" }, .scope = .run, .source_index = 0 },
    };
    try std.testing.expectEqual(
        DiagnosticKind.duplicate_conflict,
        (try (Registry{ .entries = &duplicate_conflict }).diagnose(std.testing.allocator)).?.kind,
    );
}

test "registry reports invalid load state unknown IDs and reverse conflicts" {
    const entries = [_]Entry{
        .{ .descriptor = .{ .id = "online" }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "offline", .conflicts = &.{"online"} }, .scope = .run, .source_index = 0 },
    };
    const registry = Registry{ .entries = &entries };

    var invalid_state = try registry.resolve(std.testing.allocator, "online", &.{false});
    defer invalid_state.deinit();
    try std.testing.expectEqual(DiagnosticKind.invalid_active_state, invalid_state.outcome.diagnostic.kind);

    var unknown = try registry.resolve(std.testing.allocator, "missing", &.{ false, false });
    defer unknown.deinit();
    try std.testing.expectEqual(DiagnosticKind.unknown_capability, unknown.outcome.diagnostic.kind);

    var already_active = try registry.resolve(std.testing.allocator, "online", &.{ true, false });
    defer already_active.deinit();
    try std.testing.expectEqual(@as(usize, 0), already_active.outcome.plan.len);

    var reverse_conflict = try registry.resolve(std.testing.allocator, "online", &.{ false, true });
    defer reverse_conflict.deinit();
    try std.testing.expectEqual(DiagnosticKind.active_conflict, reverse_conflict.outcome.diagnostic.kind);

    const malformed = [_]Entry{.{
        .descriptor = .{ .id = "child", .dependencies = &.{"missing"} },
        .scope = .agent,
        .source_index = 0,
    }};
    var malformed_resolution = try (Registry{ .entries = &malformed }).resolve(
        std.testing.allocator,
        "child",
        &.{false},
    );
    defer malformed_resolution.deinit();
    try std.testing.expectEqual(
        DiagnosticKind.missing_dependency,
        malformed_resolution.outcome.diagnostic.kind,
    );
}

test "load traversal defends against a cycle after registry validation" {
    const entries = [_]Entry{
        .{ .descriptor = .{ .id = "one", .dependencies = &.{"two"} }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "two", .dependencies = &.{"one"} }, .scope = .run, .source_index = 0 },
    };
    const registry = Registry{ .entries = &entries };
    var colors = [_]Color{ .unvisited, .unvisited };
    var plan: std.ArrayList(usize) = .empty;
    defer plan.deinit(std.testing.allocator);
    const diagnostic = (try registry.visitForLoad(
        std.testing.allocator,
        &colors,
        &.{ false, false },
        &plan,
        0,
    )).?;
    try std.testing.expectEqual(DiagnosticKind.dependency_cycle, diagnostic.kind);
}

fn checkRegistryAllocationFailure(gpa: std.mem.Allocator) !void {
    const entries = [_]Entry{
        .{ .descriptor = .{ .id = "base" }, .scope = .agent, .source_index = 0 },
        .{ .descriptor = .{ .id = "feature", .dependencies = &.{"base"} }, .scope = .run, .source_index = 0 },
    };
    const registry = Registry{ .entries = &entries };
    _ = try registry.diagnose(gpa);
    var resolved = try registry.resolve(gpa, "feature", &.{ false, false });
    defer resolved.deinit();
}

test "registry releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRegistryAllocationFailure,
        .{},
    );
}
