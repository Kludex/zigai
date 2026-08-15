//! Typed, borrowed value objects for MCP capability negotiation.
//!
//! These types encode the standardized capability surface without owning
//! application memory. Raw JSON remains available at the transport boundary
//! for forward-compatible capabilities and extensions.

const std = @import("std");
const json_limits = @import("../json.zig");

pub const Error = error{
    InvalidCapabilities,
    InvalidExtensionIdentifier,
};

/// Sampling features a client is prepared to provide through MRTR.
pub const SamplingCapabilities = struct {
    context: bool = false,
    tools: bool = false,
};

/// Elicitation modes a client is prepared to provide through MRTR.
pub const ElicitationCapabilities = struct {
    form: bool = false,
    url: bool = false,
};

/// Standardized client capabilities for one MCP request.
///
/// `experimental_json` and `extensions_json`, when present, must each encode a
/// JSON object. Experimental values and extension settings must be objects.
pub const ClientCapabilities = struct {
    roots: bool = false,
    sampling: ?SamplingCapabilities = null,
    elicitation: ?ElicitationCapabilities = null,
    experimental_json: ?[]const u8 = null,
    extensions_json: ?[]const u8 = null,

    /// Serializes an owned capability document. The caller frees the result.
    pub fn stringifyAlloc(self: ClientCapabilities, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};

        if (self.experimental_json) |source| {
            const experimental = try parseObject(memory, source);
            try validateObjectValues(experimental, error.InvalidCapabilities);
            try object.put(memory, "experimental", .{ .object = experimental });
        }
        if (self.roots) try object.put(memory, "roots", emptyObject());
        if (self.sampling) |sampling| {
            var value: std.json.ObjectMap = .{};
            if (sampling.context) try value.put(memory, "context", emptyObject());
            if (sampling.tools) try value.put(memory, "tools", emptyObject());
            try object.put(memory, "sampling", .{ .object = value });
        }
        if (self.elicitation) |elicitation| {
            var value: std.json.ObjectMap = .{};
            if (elicitation.form) try value.put(memory, "form", emptyObject());
            if (elicitation.url) try value.put(memory, "url", emptyObject());
            try object.put(memory, "elicitation", .{ .object = value });
        }
        if (self.extensions_json) |source| {
            const extensions = try parseObject(memory, source);
            try validateExtensions(extensions);
            try object.put(memory, "extensions", .{ .object = extensions });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

pub const PromptCapabilities = struct {
    list_changed: bool = false,
};

pub const ResourceCapabilities = struct {
    subscribe: bool = false,
    list_changed: bool = false,
};

pub const ToolCapabilities = struct {
    list_changed: bool = false,
};

/// Standardized capabilities advertised by an MCP server.
pub const ServerCapabilities = struct {
    logging: bool = false,
    completions: bool = false,
    prompts: ?PromptCapabilities = null,
    resources: ?ResourceCapabilities = null,
    tools: ?ToolCapabilities = null,
    experimental_json: ?[]const u8 = null,
    extensions_json: ?[]const u8 = null,

    /// Serializes an owned capability document. The caller frees the result.
    pub fn stringifyAlloc(self: ServerCapabilities, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};

        if (self.experimental_json) |source| {
            const experimental = try parseObject(memory, source);
            try validateObjectValues(experimental, error.InvalidCapabilities);
            try object.put(memory, "experimental", .{ .object = experimental });
        }
        if (self.logging) try object.put(memory, "logging", emptyObject());
        if (self.completions) try object.put(memory, "completions", emptyObject());
        if (self.prompts) |prompts| {
            var value: std.json.ObjectMap = .{};
            if (prompts.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "prompts", .{ .object = value });
        }
        if (self.resources) |resources| {
            var value: std.json.ObjectMap = .{};
            if (resources.subscribe) try value.put(memory, "subscribe", .{ .bool = true });
            if (resources.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "resources", .{ .object = value });
        }
        if (self.tools) |tools| {
            var value: std.json.ObjectMap = .{};
            if (tools.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "tools", .{ .object = value });
        }
        if (self.extensions_json) |source| {
            const extensions = try parseObject(memory, source);
            try validateExtensions(extensions);
            try object.put(memory, "extensions", .{ .object = extensions });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

/// MCP extension identifiers use a reverse-DNS prefix and one slash.
pub fn isExtensionIdentifier(value: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (separator == 0 or std.mem.indexOfScalarPos(u8, value, separator + 1, '/') != null) return false;
    var labels = std.mem.splitScalar(u8, value[0..separator], '.');
    while (labels.next()) |label| {
        if (label.len == 0 or !std.ascii.isAlphabetic(label[0]) or
            !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        if (label.len > 2) {
            for (label[1 .. label.len - 1]) |character| {
                if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
            }
        }
    }
    const name = value[separator + 1 ..];
    if (name.len == 0) return true;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    if (name.len > 2) {
        for (name[1 .. name.len - 1]) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '-' and
                character != '_' and character != '.') return false;
        }
    }
    return true;
}

fn emptyObject() std.json.Value {
    return .{ .object = .{} };
}

fn parseObject(allocator: std.mem.Allocator, source: []const u8) !std.json.ObjectMap {
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidCapabilities,
    );
    return switch (value) {
        .object => |object| object,
        else => error.InvalidCapabilities,
    };
}

fn validateObjectValues(object: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.* != .object) return invalid_error;
}

fn validateExtensions(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isExtensionIdentifier(entry.key_ptr.*)) return error.InvalidExtensionIdentifier;
        if (entry.value_ptr.* != .object) return error.InvalidCapabilities;
    }
}

test "typed MCP capability documents preserve standardized and extension settings" {
    const client_json = try (ClientCapabilities{
        .roots = true,
        .sampling = .{ .context = true, .tools = true },
        .elicitation = .{ .form = true, .url = true },
        .experimental_json = "{\"preview\":{\"enabled\":true}}",
        .extensions_json = "{\"com.example/feature\":{\"mode\":\"strict\"}}",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(client_json);
    try std.testing.expectEqualStrings(
        "{\"experimental\":{\"preview\":{\"enabled\":true}},\"roots\":{}," ++
            "\"sampling\":{\"context\":{},\"tools\":{}}," ++
            "\"elicitation\":{\"form\":{},\"url\":{}}," ++
            "\"extensions\":{\"com.example/feature\":{\"mode\":\"strict\"}}}",
        client_json,
    );

    const server_json = try (ServerCapabilities{
        .logging = true,
        .completions = true,
        .prompts = .{ .list_changed = true },
        .resources = .{ .subscribe = true, .list_changed = true },
        .tools = .{},
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(server_json);
    try std.testing.expectEqualStrings(
        "{\"logging\":{},\"completions\":{},\"prompts\":{\"listChanged\":true}," ++
            "\"resources\":{\"subscribe\":true,\"listChanged\":true},\"tools\":{}}",
        server_json,
    );
}

test "typed MCP capability documents reject malformed open settings" {
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ClientCapabilities{ .experimental_json = "[]" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ClientCapabilities{ .experimental_json = "{\"preview\":true}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidExtensionIdentifier,
        (ServerCapabilities{ .extensions_json = "{\"unprefixed\":{}}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ServerCapabilities{ .extensions_json = "{\"com.example/feature\":true}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expect(isExtensionIdentifier("com.example/feature_name-1"));
    try std.testing.expect(!isExtensionIdentifier("1example/feature"));
    try std.testing.expect(!isExtensionIdentifier("com..example/feature"));
    try std.testing.expect(!isExtensionIdentifier("com.example/two/paths"));
    try std.testing.expect(!isExtensionIdentifier("com.example/-feature"));
}

test "typed MCP capability serialization releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const client = try (ClientCapabilities{
                .roots = true,
                .sampling = .{ .context = true, .tools = true },
                .elicitation = .{ .form = true, .url = true },
                .experimental_json = "{\"preview\":{}}",
                .extensions_json = "{\"com.example/feature\":{}}",
            }).stringifyAlloc(allocator);
            defer allocator.free(client);
            const server = try (ServerCapabilities{
                .logging = true,
                .completions = true,
                .prompts = .{ .list_changed = true },
                .resources = .{ .subscribe = true, .list_changed = true },
                .tools = .{ .list_changed = true },
                .experimental_json = "{\"preview\":{}}",
                .extensions_json = "{\"com.example/feature\":{}}",
            }).stringifyAlloc(allocator);
            defer allocator.free(server);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
