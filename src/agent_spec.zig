//! Strict, data-only agent specifications for JSON and YAML configuration.
//!
//! Parsed values own an arena and contain references only. Provider clients,
//! executable tools, and capability implementations are resolved separately so
//! configuration parsing never performs network access or reads secrets.

const std = @import("std");
const yaml = @import("yaml");
const json_limits = @import("json.zig");
const capability_types = @import("capability.zig");

pub const Error = error{
    InvalidAgentSpec,
    UnsupportedAgentSpecVersion,
};

/// Explicit reference to a secret supplied by the resolution environment.
pub const SecretReference = struct {
    /// Environment variable name. Literal secret values are not accepted.
    env: []const u8,
};

/// Provider and model identity without provider-client lifetime ownership.
pub const ProviderSpec = struct {
    /// Provider resolver key such as `openai`, `anthropic`, or `google`.
    name: []const u8,
    /// Exact model ID passed to the provider resolver.
    model: []const u8,
    /// Optional provider endpoint override.
    base_url: ?[]const u8 = null,
    /// Optional environment-backed credential reference.
    api_key: ?SecretReference = null,
};

/// Reference to an application-registered capability implementation.
pub const CapabilitySpec = struct {
    /// Stable capability registry ID.
    id: []const u8,
    /// Optional loading override for this agent specification.
    loading: ?capability_types.Loading = null,
    /// Optional retention override for this agent specification.
    unload_policy: ?capability_types.UnloadPolicy = null,
};

/// Versioned, provider-neutral agent configuration document.
pub const Spec = struct {
    /// Schema version. ZigAI currently accepts only version 1.
    version: u8,
    /// Optional application-facing agent name.
    name: ?[]const u8 = null,
    /// Provider and exact model selection.
    provider: ProviderSpec,
    /// Optional system prompt.
    system_prompt: ?[]const u8 = null,
    /// Static agent instructions in declaration order.
    instructions: []const []const u8 = &.{},
    /// Capability references in declaration order.
    capabilities: []const CapabilitySpec = &.{},
};

/// Arena-owned specification. All nested slices remain valid until `deinit`.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Spec,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses strict JSON. Unknown fields and literal API keys are rejected.
pub fn parseJson(gpa: std.mem.Allocator, source: []const u8) !Owned {
    try json_limits.validate(gpa, source, json_limits.defaults.cli_config);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const owned_source = try memory.dupe(u8, source);
    const value = std.json.parseFromSliceLeaky(Spec, memory, owned_source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidAgentSpec,
    };
    try validate(value);
    return .{ .arena = arena, .value = value };
}

/// Parses strict YAML using the core schema and the JSON-equivalent shape.
pub fn parseYaml(gpa: std.mem.Allocator, source: []const u8) !Owned {
    if (source.len > json_limits.defaults.cli_config.max_document_bytes) {
        return error.DocumentTooLarge;
    }
    var document = yaml.loadWithOptions(gpa, source, .{
        .schema = .core,
        .duplicate_key_behavior = .reject,
        .unknown_tag_behavior = .reject,
        .max_input_bytes = json_limits.defaults.cli_config.max_document_bytes,
        .max_nesting_depth = json_limits.defaults.cli_config.max_depth,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidAgentSpec,
    };
    defer document.deinit();

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    writeJsonNode(&json, document.root) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidAgentSpec,
    };
    return parseJson(gpa, output.written());
}

fn validate(spec: Spec) !void {
    if (spec.version != 1) return Error.UnsupportedAgentSpecVersion;
    if (spec.name) |name| if (name.len == 0) return Error.InvalidAgentSpec;
    if (!validId(spec.provider.name) or spec.provider.model.len == 0) return Error.InvalidAgentSpec;
    if (spec.provider.base_url) |base_url| if (base_url.len == 0) return Error.InvalidAgentSpec;
    if (spec.provider.api_key) |secret| if (!validEnvironmentName(secret.env)) {
        return Error.InvalidAgentSpec;
    };
    if (spec.instructions.len > 64 or spec.capabilities.len > 256) return Error.InvalidAgentSpec;
    for (spec.instructions) |instruction| if (instruction.len == 0) return Error.InvalidAgentSpec;
    for (spec.capabilities, 0..) |item, index| {
        if (!validId(item.id)) return Error.InvalidAgentSpec;
        for (spec.capabilities[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, item.id)) return Error.InvalidAgentSpec;
        }
    }
}

fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id, 0..) |byte, index| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!valid or (index == 0 and !std.ascii.isAlphanumeric(byte))) return false;
    }
    return true;
}

fn validEnvironmentName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn writeJsonNode(json: *std.json.Stringify, node: *const yaml.Node) !void {
    switch (node.*) {
        .null_value => try json.write(null),
        .bool_value => |value| try json.write(value.value),
        .int_value => |value| try json.write(value.value),
        .float_value => |value| try json.write(value.value),
        .scalar => |value| try json.write(value.value),
        .sequence => |sequence| {
            try json.beginArray();
            for (sequence.items) |item| try writeJsonNode(json, item);
            try json.endArray();
        },
        .mapping => |mapping| {
            try json.beginObject();
            for (mapping.pairs) |pair| {
                const key = switch (pair.key.*) {
                    .scalar => |value| value.value,
                    else => return Error.InvalidAgentSpec,
                };
                try json.objectField(key);
                try writeJsonNode(json, pair.value);
            }
            try json.endObject();
        },
        .alias => return Error.InvalidAgentSpec,
    }
}

test "JSON and YAML parse to the same strict agent specification" {
    const json =
        \\{"version":1,"name":"support","provider":{"name":"openai","model":"gpt-5-mini","api_key":{"env":"OPENAI_API_KEY"}},"system_prompt":"Help.","instructions":["Be concise."],"capabilities":[{"id":"search","loading":"on_demand","unload_policy":"history"}]}
    ;
    const yaml_source =
        \\version: 1
        \\name: support
        \\provider:
        \\  name: openai
        \\  model: gpt-5-mini
        \\  api_key:
        \\    env: OPENAI_API_KEY
        \\system_prompt: Help.
        \\instructions:
        \\- Be concise.
        \\capabilities:
        \\- id: search
        \\  loading: on_demand
        \\  unload_policy: history
    ;
    var from_json = try parseJson(std.testing.allocator, json);
    defer from_json.deinit();
    var from_yaml = try parseYaml(std.testing.allocator, yaml_source);
    defer from_yaml.deinit();
    try std.testing.expectEqualStrings(from_json.value.provider.model, from_yaml.value.provider.model);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", from_yaml.value.provider.api_key.?.env);
    try std.testing.expectEqual(capability_types.Loading.on_demand, from_yaml.value.capabilities[0].loading.?);
}

test "agent specifications reject unknown fields literals duplicates and invalid semantics" {
    const invalid_json = [_][]const u8{
        "{\"version\":1,\"provider\":{\"name\":\"openai\",\"model\":\"m\"},\"unknown\":true}",
        "{\"version\":2,\"provider\":{\"name\":\"openai\",\"model\":\"m\"}}",
        "{\"version\":1,\"provider\":{\"name\":\"openai\",\"model\":\"m\",\"api_key\":\"literal\"}}",
        "{\"version\":1,\"provider\":{\"name\":\"openai\",\"model\":\"m\"},\"capabilities\":[{\"id\":\"same\"},{\"id\":\"same\"}]}",
        "{\"version\":1,\"provider\":{\"name\":\"bad name\",\"model\":\"m\"}}",
        "{\"version\":1,\"provider\":{\"name\":\"openai\",\"model\":\"m\",\"api_key\":{\"env\":\"BAD-NAME\"}}}",
    };
    for (invalid_json) |source| {
        const result = parseJson(std.testing.allocator, source);
        if (std.mem.indexOf(u8, source, "\"version\":2") != null) {
            try std.testing.expectError(Error.UnsupportedAgentSpecVersion, result);
        } else {
            try std.testing.expectError(Error.InvalidAgentSpec, result);
        }
    }
    try std.testing.expectError(Error.InvalidAgentSpec, parseYaml(std.testing.allocator,
        \\version: 1
        \\version: 1
        \\provider: {name: openai, model: m}
    ));
    try std.testing.expectError(Error.InvalidAgentSpec, parseYaml(std.testing.allocator,
        \\version: 1
        \\provider: {name: openai, model: m}
        \\unknown: [null, true, 1.5]
    ));
    try std.testing.expectError(Error.InvalidAgentSpec, parseYaml(std.testing.allocator,
        \\version: 1
        \\provider: &provider {name: openai, model: m}
        \\copy: *provider
    ));
    try std.testing.expectError(Error.InvalidAgentSpec, parseYaml(std.testing.allocator,
        \\? [complex]
        \\: value
    ));
}

test "agent specification semantic validation covers every bounded field" {
    const valid_provider = ProviderSpec{ .name = "openai", .model = "model" };
    try validate(.{ .version = 1, .provider = .{ .name = "gateway_1.test", .model = "model" } });
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .name = "",
        .provider = valid_provider,
    }));
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = .{ .name = "", .model = "model" },
    }));
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = .{ .name = "openai", .model = "" },
    }));
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = .{ .name = "openai", .model = "model", .base_url = "" },
    }));
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = .{ .name = "openai", .model = "model", .api_key = .{ .env = "" } },
    }));
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = .{ .name = "openai", .model = "model", .api_key = .{ .env = "1KEY" } },
    }));
    const too_many_instructions = [_][]const u8{"instruction"} ** 65;
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = valid_provider,
        .instructions = &too_many_instructions,
    }));
    const empty_instruction = [_][]const u8{""};
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = valid_provider,
        .instructions = &empty_instruction,
    }));
    const too_many_capabilities = [_]CapabilitySpec{.{ .id = "same" }} ** 257;
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = valid_provider,
        .capabilities = &too_many_capabilities,
    }));
    const invalid_capability = [_]CapabilitySpec{.{ .id = "-invalid" }};
    try std.testing.expectError(Error.InvalidAgentSpec, validate(.{
        .version = 1,
        .provider = valid_provider,
        .capabilities = &invalid_capability,
    }));
}

test "agent specification parsers enforce the document byte limit" {
    const limit = json_limits.defaults.cli_config.max_document_bytes;
    const source = try std.testing.allocator.alloc(u8, limit + 1);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    try std.testing.expectError(error.DocumentTooLarge, parseJson(std.testing.allocator, source));
    try std.testing.expectError(error.DocumentTooLarge, parseYaml(std.testing.allocator, source));
}

fn checkAllocationFailure(gpa: std.mem.Allocator) !void {
    var parsed = try parseYaml(gpa,
        \\version: 1
        \\provider:
        \\  name: openai
        \\  model: gpt-5-mini
        \\capabilities:
        \\- id: search
    );
    parsed.deinit();
}

test "agent specification parsing releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailure, .{});
}
