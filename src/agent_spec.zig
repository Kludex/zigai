//! Strict, data-only agent specifications for JSON and YAML configuration.
//!
//! Parsed values own an arena and contain references only. Provider clients,
//! executable tools, and capability implementations are resolved separately so
//! configuration parsing never performs network access or reads secrets.

const std = @import("std");
const yaml = @import("yaml");
const json_limits = @import("json.zig");
const capability_types = @import("capability.zig");
const agent_types = @import("agent.zig");
const model_types = @import("model.zig");

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

/// Read-only environment view supplied explicitly by the application.
pub const Environment = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        return self.getFn(self.context, name);
    }
};

/// Fields in which `${NAME}` expansion is permitted. Expansion is off by
/// default and `$${NAME}` always produces the literal `${NAME}`.
pub const InterpolationFields = struct {
    model: bool = false,
    base_url: bool = false,
    system_prompt: bool = false,
    instructions: bool = false,
};

/// Deny-by-default policy for reading process-like environment values.
pub const EnvironmentPolicy = struct {
    fields: InterpolationFields = .{},
    /// Names permitted in `${NAME}` placeholders in enabled fields.
    interpolation_names: []const []const u8 = &.{},
    /// Names permitted in structured `api_key.env` references.
    secret_names: []const []const u8 = &.{},
};

/// Fully expanded provider input passed to application-owned resolution code.
/// The API key is available only during resolution and is never retained by
/// ZigAI diagnostics.
pub const ProviderInput = struct {
    name: []const u8,
    model: []const u8,
    base_url: ?[]const u8,
    api_key: ?[]const u8,

    fn validation(self: ProviderInput) ProviderValidationInput {
        return .{
            .name = self.name,
            .model = self.model,
            .base_url = self.base_url,
            .has_api_key = self.api_key != null,
        };
    }
};

/// Secret-free provider input used by dry-run validation callbacks.
pub const ProviderValidationInput = struct {
    name: []const u8,
    model: []const u8,
    base_url: ?[]const u8,
    has_api_key: bool,
};

pub const ProviderResolutionError = error{
    UnknownProvider,
    UnknownModel,
    InvalidProviderConfiguration,
};

/// Model plus optional application cleanup. `buildFn` may allocate model
/// context in the supplied arena; cleanup runs before that arena is released.
pub const ModelHandle = struct {
    model: model_types.Model,
    cleanup_context: ?*anyopaque = null,
    cleanupFn: ?*const fn (context: *anyopaque) void = null,

    pub fn deinit(self: *ModelHandle) void {
        if (self.cleanupFn) |cleanup| cleanup(self.cleanup_context orelse self.model.context);
        self.* = undefined;
    }
};

/// Application boundary for provider/model lookup and client construction.
/// `validateFn` must be side-effect free and perform no network access.
pub const ProviderResolver = struct {
    context: *anyopaque,
    validateFn: *const fn (context: *anyopaque, input: ProviderValidationInput) ProviderResolutionError!void,
    buildFn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        input: ProviderInput,
    ) anyerror!ModelHandle,

    pub fn validate(self: ProviderResolver, input: ProviderValidationInput) ProviderResolutionError!void {
        return self.validateFn(self.context, input);
    }

    pub fn build(self: ProviderResolver, arena: std.mem.Allocator, input: ProviderInput) !ModelHandle {
        return self.buildFn(self.context, arena, input);
    }
};

/// Application-owned capability catalog. Returned implementations and their
/// callback contexts must outlive the resolved agent.
pub const CapabilityResolver = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, id: []const u8) ?agent_types.Capability,

    pub fn get(self: CapabilityResolver, id: []const u8) ?agent_types.Capability {
        return self.getFn(self.context, id);
    }
};

pub const ResolutionOptions = struct {
    environment: ?Environment = null,
    environment_policy: EnvironmentPolicy = .{},
    provider: ProviderResolver,
    capabilities: ?CapabilityResolver = null,
};

pub const ResolutionError = error{
    InvalidEnvironmentInterpolation,
    EnvironmentVariableNotAllowed,
    MissingEnvironmentVariable,
    EmptySecret,
    UnknownCapability,
    InvalidCapabilityImplementation,
    InvalidCapabilityComposition,
};

/// Arena-owned runnable agent assembled from a data-only specification.
pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    model_handle: ModelHandle,
    agent: agent_types.Agent,

    pub fn deinit(self: *Resolved) void {
        self.model_handle.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Performs every local resolution check without constructing a provider
/// client or making network requests.
pub fn validateResolution(gpa: std.mem.Allocator, spec: Spec, options: ResolutionOptions) !void {
    var prepared = try prepareResolution(gpa, spec, options);
    defer prepared.arena.deinit();
    try options.provider.validate(prepared.provider.validation());
}

/// Resolves a specification into an owned `Agent` after a successful dry-run
/// validation. Provider and capability implementations remain application
/// choices rather than parser dependencies.
pub fn resolve(gpa: std.mem.Allocator, spec: Spec, options: ResolutionOptions) !Resolved {
    var prepared = try prepareResolution(gpa, spec, options);
    errdefer prepared.arena.deinit();
    try options.provider.validate(prepared.provider.validation());
    var model_handle = try options.provider.build(prepared.arena.allocator(), prepared.provider);
    errdefer model_handle.deinit();
    return .{
        .arena = prepared.arena, // kcov-ignore
        .model_handle = model_handle,
        .agent = .{
            .model = model_handle.model,
            .capabilities = prepared.capabilities,
            .system_prompt = prepared.system_prompt,
            .instructions = prepared.instructions,
        },
    };
}

const PreparedResolution = struct {
    arena: std.heap.ArenaAllocator,
    provider: ProviderInput,
    system_prompt: ?[]const u8,
    instructions: []const agent_types.Instruction,
    capabilities: []const agent_types.Capability,
};

fn prepareResolution(gpa: std.mem.Allocator, spec: Spec, options: ResolutionOptions) !PreparedResolution {
    try validate(spec);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const environment = options.environment;
    const policy = options.environment_policy;

    const provider = ProviderInput{
        .name = try memory.dupe(u8, spec.provider.name),
        .model = try interpolate(memory, spec.provider.model, policy.fields.model, environment, policy.interpolation_names),
        .base_url = if (spec.provider.base_url) |value|
            try interpolate(memory, value, policy.fields.base_url, environment, policy.interpolation_names)
        else
            null,
        .api_key = if (spec.provider.api_key) |reference|
            try resolveSecret(memory, reference, environment, policy.secret_names)
        else
            null,
    };

    const system_prompt = if (spec.system_prompt) |value|
        try interpolate(memory, value, policy.fields.system_prompt, environment, policy.interpolation_names)
    else
        null;
    const instructions = try memory.alloc(agent_types.Instruction, spec.instructions.len);
    for (spec.instructions, instructions) |source, *instruction| {
        instruction.* = .{ .text = try interpolate(
            memory,
            source,
            policy.fields.instructions,
            environment,
            policy.interpolation_names,
        ) };
    }
    const capabilities = try resolveCapabilities(memory, spec.capabilities, options.capabilities);
    return .{
        .arena = arena,
        .provider = provider,
        .system_prompt = system_prompt,
        .instructions = instructions,
        .capabilities = capabilities,
    };
}

fn resolveSecret(
    allocator: std.mem.Allocator,
    reference: SecretReference,
    environment: ?Environment,
    allowed_names: []const []const u8,
) ![]const u8 {
    if (!containsName(allowed_names, reference.env)) return ResolutionError.EnvironmentVariableNotAllowed;
    const source = environment orelse return ResolutionError.MissingEnvironmentVariable;
    const value = source.get(reference.env) orelse return ResolutionError.MissingEnvironmentVariable;
    if (value.len == 0) return ResolutionError.EmptySecret;
    return allocator.dupe(u8, value);
}

fn interpolate(
    allocator: std.mem.Allocator,
    source: []const u8,
    enabled: bool,
    environment: ?Environment,
    allowed_names: []const []const u8,
) ![]const u8 {
    if (!enabled) return allocator.dupe(u8, source);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '$' and index + 1 < source.len and source[index + 1] == '$') {
            try output.append(allocator, '$');
            index += 2;
            continue;
        }
        if (source[index] != '$' or index + 1 >= source.len or source[index + 1] != '{') {
            try output.append(allocator, source[index]);
            index += 1;
            continue;
        }
        const closing = std.mem.indexOfScalarPos(u8, source, index + 2, '}') orelse
            return ResolutionError.InvalidEnvironmentInterpolation;
        const name = source[index + 2 .. closing];
        if (!validEnvironmentName(name)) return ResolutionError.InvalidEnvironmentInterpolation;
        if (!containsName(allowed_names, name)) return ResolutionError.EnvironmentVariableNotAllowed;
        const values = environment orelse return ResolutionError.MissingEnvironmentVariable;
        const value = values.get(name) orelse return ResolutionError.MissingEnvironmentVariable;
        try output.appendSlice(allocator, value);
        index = closing + 1;
    }
    return output.toOwnedSlice(allocator);
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

fn resolveCapabilities(
    allocator: std.mem.Allocator,
    configured: []const CapabilitySpec,
    maybe_resolver: ?CapabilityResolver,
) ![]const agent_types.Capability {
    if (configured.len == 0) return &.{};
    const resolver = maybe_resolver orelse return ResolutionError.UnknownCapability;
    var resolved: std.ArrayList(agent_types.Capability) = .empty;
    defer resolved.deinit(allocator);
    for (configured) |item| {
        try appendCapability(allocator, &resolved, resolver, item.id, item);
    }
    var index: usize = 0;
    while (index < resolved.items.len) : (index += 1) {
        for (resolved.items[index].dependencies) |dependency| {
            if (findCapability(resolved.items, dependency) == null) {
                try appendCapability(allocator, &resolved, resolver, dependency, null);
            }
        }
    }
    const capabilities = try resolved.toOwnedSlice(allocator);
    const entries = try allocator.alloc(capability_types.Entry, capabilities.len);
    for (capabilities, entries, 0..) |capability, *entry, source_index| entry.* = .{
        .descriptor = capability.descriptor(),
        .scope = .agent,
        .source_index = source_index,
    };
    if (try (capability_types.Registry{ .entries = entries }).diagnose(allocator) != null) {
        return ResolutionError.InvalidCapabilityComposition;
    }
    return capabilities;
}

fn appendCapability(
    allocator: std.mem.Allocator,
    resolved: *std.ArrayList(agent_types.Capability),
    resolver: CapabilityResolver,
    id: []const u8,
    override: ?CapabilitySpec,
) !void {
    var capability = resolver.get(id) orelse return ResolutionError.UnknownCapability;
    const implementation_id = capability.id orelse return ResolutionError.InvalidCapabilityImplementation;
    if (!std.mem.eql(u8, implementation_id, id)) return ResolutionError.InvalidCapabilityImplementation;
    if (override) |item| {
        if (item.loading) |loading| capability.loading = loading;
        if (item.unload_policy) |unload_policy| capability.unload_policy = unload_policy;
    }
    try resolved.append(allocator, capability);
}

fn findCapability(capabilities: []const agent_types.Capability, id: []const u8) ?usize {
    for (capabilities, 0..) |capability, index| {
        if (std.mem.eql(u8, capability.id.?, id)) return index;
    }
    return null;
}

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
        error.WriteFailed => error.OutOfMemory,
        error.InvalidAgentSpec => Error.InvalidAgentSpec,
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

const WriteJsonNodeError = error{ WriteFailed, InvalidAgentSpec };

fn writeJsonNode(json: *std.json.Stringify, node: *const yaml.Node) WriteJsonNodeError!void {
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
                    else => return error.InvalidAgentSpec,
                };
                try json.objectField(key);
                try writeJsonNode(json, pair.value);
            }
            try json.endObject();
        },
        // The public loader resolves aliases to their anchored nodes. Only
        // manually constructed `yaml.Node` values can retain this tag.
        .alias => unreachable,
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

const ResolutionTestState = struct {
    validate_count: usize = 0,
    build_count: usize = 0,
    cleanup_count: usize = 0,
    expected_model: []const u8 = "model-prod",
    expected_base_url: []const u8 = "https://api.example.test/${literal}",
    expected_key: []const u8 = "secret",
    expected_has_api_key: bool = true,
    fail_build: bool = false,

    fn environment(_: *anyopaque, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "MODEL")) return "model-prod";
        if (std.mem.eql(u8, name, "HOST")) return "api.example.test";
        if (std.mem.eql(u8, name, "ROLE")) return "support";
        if (std.mem.eql(u8, name, "API_KEY")) return "secret";
        if (std.mem.eql(u8, name, "EMPTY")) return "";
        return null;
    }

    fn validate(context: *anyopaque, input: ProviderValidationInput) ProviderResolutionError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.validate_count += 1;
        if (!std.mem.eql(u8, input.name, "openai")) return error.UnknownProvider;
        if (!std.mem.eql(u8, input.model, self.expected_model)) return error.UnknownModel;
        if (!std.mem.eql(u8, input.base_url.?, self.expected_base_url)) return error.InvalidProviderConfiguration;
        if (input.has_api_key != self.expected_has_api_key) return error.InvalidProviderConfiguration;
    }

    fn build(context: *anyopaque, arena: std.mem.Allocator, input: ProviderInput) !ModelHandle {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.build_count += 1;
        if (self.fail_build) return error.TestBuildFailed;
        if (self.expected_has_api_key and !std.mem.eql(u8, input.api_key.?, self.expected_key)) {
            return error.InvalidProviderConfiguration;
        }
        const client = try arena.create(ResolutionTestClient);
        client.* = .{ .state = self, .model_name = try arena.dupe(u8, input.model) };
        return .{
            .model = .{
                .context = client,
                .profile = .{},
                .provider_name = "test",
                .model_name = client.model_name,
                .requestFn = ResolutionTestClient.request,
            },
            .cleanup_context = self,
            .cleanupFn = cleanup,
        };
    }

    fn cleanup(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.cleanup_count += 1;
    }

    fn provider(self: *@This()) ProviderResolver {
        return .{ .context = self, .validateFn = ResolutionTestState.validate, .buildFn = ResolutionTestState.build };
    }
};

const ResolutionTestClient = struct {
    state: *ResolutionTestState,
    model_name: []const u8,

    fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
        return .{ .parts = &.{} };
    }
};

const ResolutionTestCapabilities = struct {
    fn get(_: *anyopaque, id: []const u8) ?agent_types.Capability {
        if (std.mem.eql(u8, id, "search")) return .{
            .id = "search",
            .dependencies = &.{"auth"},
        };
        if (std.mem.eql(u8, id, "auth")) return .{ .id = "auth" };
        if (std.mem.eql(u8, id, "mismatch")) return .{ .id = "other" };
        if (std.mem.eql(u8, id, "broken")) return .{
            .id = "broken",
            .conflicts = &.{"absent"},
        };
        return null;
    }

    fn resolver() CapabilityResolver {
        return .{ .context = undefined, .getFn = get };
    }
};

fn resolutionOptions(state: *ResolutionTestState) ResolutionOptions {
    return .{
        .environment = .{ .context = state, .getFn = ResolutionTestState.environment },
        .environment_policy = .{
            .fields = .{ .model = true, .base_url = true, .system_prompt = true, .instructions = true },
            .interpolation_names = &.{ "MODEL", "HOST", "ROLE" },
            .secret_names = &.{"API_KEY"},
        },
        .provider = state.provider(),
        .capabilities = ResolutionTestCapabilities.resolver(),
    };
}

test "agent resolution is dry-runnable and builds an owned agent" {
    var state = ResolutionTestState{};
    const spec = Spec{
        .version = 1,
        .provider = .{
            .name = "openai",
            .model = "${MODEL}",
            .base_url = "https://${HOST}/$${literal}",
            .api_key = .{ .env = "API_KEY" },
        },
        .system_prompt = "You are ${ROLE}.",
        .instructions = &.{ "Help ${ROLE} users.", "$${ROLE}" },
        .capabilities = &.{.{
            .id = "search",
            .loading = .on_demand,
            .unload_policy = .run_end,
        }},
    };
    const options = resolutionOptions(&state);
    try validateResolution(std.testing.allocator, spec, options);
    try std.testing.expectEqual(@as(usize, 1), state.validate_count);
    try std.testing.expectEqual(@as(usize, 0), state.build_count);

    var resolved = try resolve(std.testing.allocator, spec, options);
    try std.testing.expectEqual(@as(usize, 2), state.validate_count);
    try std.testing.expectEqual(@as(usize, 1), state.build_count);
    try std.testing.expectEqualStrings("You are support.", resolved.agent.system_prompt.?);
    try std.testing.expectEqualStrings("Help support users.", resolved.agent.instructions[0].text);
    try std.testing.expectEqualStrings("${ROLE}", resolved.agent.instructions[1].text);
    try std.testing.expectEqual(@as(usize, 2), resolved.agent.capabilities.len);
    try std.testing.expectEqualStrings("search", resolved.agent.capabilities[0].id.?);
    try std.testing.expectEqual(capability_types.Loading.on_demand, resolved.agent.capabilities[0].loading);
    try std.testing.expectEqual(capability_types.UnloadPolicy.run_end, resolved.agent.capabilities[0].unload_policy);
    try std.testing.expectEqualStrings("auth", resolved.agent.capabilities[1].id.?);
    try std.testing.expectEqualStrings("model-prod", resolved.agent.model.model_name.?);
    const response = try resolved.agent.model.request(std.testing.allocator, .{ .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 0), response.parts.len);
    resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.cleanup_count);
}

test "agent resolution leaves interpolation disabled unless explicitly enabled" {
    var state = ResolutionTestState{
        .expected_model = "${MODEL}",
        .expected_base_url = "https://${HOST}",
    };
    const spec = Spec{
        .version = 1,
        .provider = .{
            .name = "openai",
            .model = "${MODEL}",
            .base_url = "https://${HOST}",
            .api_key = .{ .env = "API_KEY" },
        },
    };
    try validateResolution(std.testing.allocator, spec, .{
        .environment = .{ .context = &state, .getFn = ResolutionTestState.environment },
        .environment_policy = .{ .secret_names = &.{"API_KEY"} },
        .provider = state.provider(),
    });
}

test "agent resolution reports environment capability and provider failures" {
    var state = ResolutionTestState{
        .expected_base_url = "https://api.example.test/plain",
        .expected_has_api_key = false,
    };
    const base = Spec{
        .version = 1,
        .provider = .{ .name = "openai", .model = "model-prod", .base_url = "https://api.example.test/plain" },
    };
    var options = resolutionOptions(&state);
    try std.testing.expectError(ResolutionError.EnvironmentVariableNotAllowed, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "model-prod", .api_key = .{ .env = "OTHER" } } },
        options,
    ));
    options.environment = null;
    try std.testing.expectError(ResolutionError.MissingEnvironmentVariable, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "${MODEL}" } },
        options,
    ));
    options = resolutionOptions(&state);
    options.environment_policy.secret_names = &.{"EMPTY"};
    try std.testing.expectError(ResolutionError.EmptySecret, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "model-prod", .api_key = .{ .env = "EMPTY" } } },
        options,
    ));
    options = resolutionOptions(&state);
    try std.testing.expectError(ResolutionError.InvalidEnvironmentInterpolation, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "${BAD-NAME}" } },
        options,
    ));
    try std.testing.expectError(ResolutionError.InvalidEnvironmentInterpolation, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "${MODEL" } },
        options,
    ));
    try std.testing.expectError(ResolutionError.EnvironmentVariableNotAllowed, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "${OTHER}" } },
        options,
    ));
    try std.testing.expectError(ResolutionError.MissingEnvironmentVariable, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = .{ .name = "openai", .model = "${MISSING}" } },
        .{
            .environment = options.environment,
            .environment_policy = .{ .fields = .{ .model = true }, .interpolation_names = &.{"MISSING"} },
            .provider = options.provider,
        },
    ));
    try std.testing.expectError(ResolutionError.UnknownCapability, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = base.provider, .capabilities = &.{.{ .id = "missing" }} },
        options,
    ));
    options.capabilities = null;
    try std.testing.expectError(ResolutionError.UnknownCapability, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = base.provider, .capabilities = &.{.{ .id = "search" }} },
        options,
    ));
    options = resolutionOptions(&state);
    try std.testing.expectError(ResolutionError.InvalidCapabilityImplementation, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = base.provider, .capabilities = &.{.{ .id = "mismatch" }} },
        options,
    ));
    try std.testing.expectError(ResolutionError.InvalidCapabilityComposition, validateResolution(
        std.testing.allocator,
        .{ .version = 1, .provider = base.provider, .capabilities = &.{.{ .id = "broken" }} },
        options,
    ));

    state.expected_model = "other";
    try std.testing.expectError(error.UnknownModel, validateResolution(std.testing.allocator, base, options));

    state.expected_model = "model-prod";
    state.expected_key = "different";
    state.expected_has_api_key = true;
    try std.testing.expectError(error.InvalidProviderConfiguration, resolve(std.testing.allocator, .{
        .version = 1,
        .provider = .{
            .name = "openai",
            .model = "model-prod",
            .base_url = "https://api.example.test/plain",
            .api_key = .{ .env = "API_KEY" },
        },
    }, options));
    state.expected_key = "secret";
    state.fail_build = true;
    try std.testing.expectError(error.TestBuildFailed, resolve(std.testing.allocator, .{
        .version = 1,
        .provider = .{
            .name = "openai",
            .model = "model-prod",
            .base_url = "https://api.example.test/plain",
            .api_key = .{ .env = "API_KEY" },
        },
    }, options));
}

fn checkResolutionAllocationFailure(gpa: std.mem.Allocator) !void {
    var state = ResolutionTestState{};
    var resolved = try resolve(gpa, .{
        .version = 1,
        .provider = .{
            .name = "openai",
            .model = "${MODEL}",
            .base_url = "https://${HOST}/$${literal}",
            .api_key = .{ .env = "API_KEY" },
        },
        .system_prompt = "${ROLE}",
        .instructions = &.{"${ROLE}"},
        .capabilities = &.{.{ .id = "search" }},
    }, resolutionOptions(&state));
    resolved.deinit();
}

test "agent resolution releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkResolutionAllocationFailure, .{});
}
