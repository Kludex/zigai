//! Pure argument parsing and dry-run support for the agent-spec CLI.

const std = @import("std");
const zigai = @import("zigai");

pub const Format = enum { json, yaml };

pub const Arguments = struct {
    path: []const u8,
    interpolate: bool,
    environment_names: []const []const u8,
    capability_ids: []const []const u8,
};

pub fn parseArguments(allocator: std.mem.Allocator, args: []const []const u8) !Arguments {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "validate")) return error.InvalidArguments;
    var path: ?[]const u8 = null;
    var interpolate = false;
    var environment_names: std.ArrayList([]const u8) = .empty;
    defer environment_names.deinit(allocator);
    var capability_ids: std.ArrayList([]const u8) = .empty;
    defer capability_ids.deinit(allocator);
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--interpolate")) {
            if (interpolate) return error.InvalidArguments;
            interpolate = true;
        } else if (std.mem.eql(u8, argument, "--allow-env")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            try appendUnique(allocator, &environment_names, args[index]);
        } else if (std.mem.eql(u8, argument, "--capability")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            try appendUnique(allocator, &capability_ids, args[index]);
        } else if (std.mem.startsWith(u8, argument, "--") or path != null) {
            return error.InvalidArguments;
        } else {
            path = argument;
        }
    }
    return .{
        .path = path orelse return error.InvalidArguments,
        .interpolate = interpolate,
        .environment_names = try environment_names.toOwnedSlice(allocator),
        .capability_ids = try capability_ids.toOwnedSlice(allocator),
    };
}

fn appendUnique(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    if (value.len == 0) return error.InvalidArguments;
    for (values.items) |previous| if (std.mem.eql(u8, previous, value)) return error.InvalidArguments;
    try values.append(allocator, value);
}

pub fn formatForPath(path: []const u8) !Format {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return .json;
    if (std.ascii.eqlIgnoreCase(extension, ".yaml") or std.ascii.eqlIgnoreCase(extension, ".yml")) return .yaml;
    return error.UnsupportedAgentSpecFormat;
}

pub fn validateSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    format: Format,
    arguments: Arguments,
    environment: zigai.agent_spec.Environment,
) !void {
    var parsed = switch (format) {
        .json => try zigai.agent_spec.parseJson(allocator, source),
        .yaml => try zigai.agent_spec.parseYaml(allocator, source),
    };
    defer parsed.deinit();
    var catalog = CapabilityCatalog{ .ids = arguments.capability_ids };
    var provider = DryRunProvider{};
    try zigai.agent_spec.validateResolution(allocator, parsed.value, .{
        .environment = environment,
        .environment_policy = .{
            .fields = if (arguments.interpolate) .{
                .model = true,
                .base_url = true,
                .system_prompt = true,
                .instructions = true,
            } else .{},
            .interpolation_names = arguments.environment_names,
            .secret_names = arguments.environment_names,
        },
        .provider = .{
            .context = &provider,
            .validateFn = DryRunProvider.validate,
            .buildFn = DryRunProvider.build,
        },
        .capabilities = .{ .context = &catalog, .getFn = CapabilityCatalog.get },
    });
}

const CapabilityCatalog = struct {
    ids: []const []const u8,

    fn get(context: *anyopaque, id: []const u8) ?zigai.Capability {
        const self: *@This() = @ptrCast(@alignCast(context));
        for (self.ids) |known| if (std.mem.eql(u8, known, id)) return .{ .id = known };
        return null;
    }
};

const DryRunProvider = struct {
    const names = [_][]const u8{
        "anthropic",
        "azure-openai",
        "bedrock",
        "cerebras",
        "cohere",
        "deepseek",
        "doubleword",
        "google",
        "groq",
        "huggingface",
        "mistral",
        "openai",
        "openai-compatible",
        "openrouter",
        "ovhcloud",
        "pydantic-gateway",
        "together",
    };

    fn validate(_: *anyopaque, input: zigai.agent_spec.ProviderValidationInput) zigai.agent_spec.ProviderResolutionError!void {
        var known = false;
        for (names) |name| if (std.mem.eql(u8, name, input.name)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownProvider;
        if (input.model.len == 0) return error.UnknownModel;
        if (input.base_url) |base_url| {
            (zigai.security.UrlPolicy{ .allow_http = true, .allow_local_network = true }).validate(base_url) catch
                return error.InvalidProviderConfiguration;
        }
    }

    fn build(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: zigai.agent_spec.ProviderInput,
    ) !zigai.agent_spec.ModelHandle { // kcov-ignore
        return error.DryRunOnly; // kcov-ignore
    }
};

const TestEnvironment = struct {
    fn get(_: *anyopaque, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "MODEL")) return "gpt-5-mini";
        if (std.mem.eql(u8, name, "OPENAI_API_KEY")) return "secret";
        return null;
    }

    fn value() zigai.agent_spec.Environment {
        return .{ .context = undefined, .getFn = get };
    }
};

test "agent spec CLI parses explicit grants and detects formats" {
    const arguments = try parseArguments(std.testing.allocator, &.{
        "zigai-agent-spec",
        "validate",
        "agent.yaml",
        "--interpolate",
        "--allow-env",
        "MODEL",
        "--allow-env",
        "OPENAI_API_KEY",
        "--capability",
        "search",
    });
    defer std.testing.allocator.free(arguments.environment_names);
    defer std.testing.allocator.free(arguments.capability_ids);
    try std.testing.expect(arguments.interpolate);
    try std.testing.expectEqual(@as(usize, 2), arguments.environment_names.len);
    try std.testing.expectEqualStrings("search", arguments.capability_ids[0]);
    try std.testing.expectEqual(Format.json, try formatForPath("agent.JSON"));
    try std.testing.expectEqual(Format.yaml, try formatForPath("agent.yml"));
    try std.testing.expectError(error.UnsupportedAgentSpecFormat, formatForPath("agent.txt"));
}

test "agent spec CLI rejects ambiguous arguments" {
    const invalid = [_][]const []const u8{
        &.{},
        &.{ "cli", "check", "agent.json" },
        &.{ "cli", "validate" },
        &.{ "cli", "validate", "a.json", "b.json" },
        &.{ "cli", "validate", "a.json", "--unknown" },
        &.{ "cli", "validate", "a.json", "--interpolate", "--interpolate" },
        &.{ "cli", "validate", "a.json", "--allow-env" },
        &.{ "cli", "validate", "a.json", "--allow-env", "" },
        &.{ "cli", "validate", "a.json", "--allow-env", "A", "--allow-env", "A" },
        &.{ "cli", "validate", "a.json", "--capability" },
        &.{ "cli", "validate", "a.json", "--capability", "x", "--capability", "x" },
    };
    for (invalid) |args| try std.testing.expectError(error.InvalidArguments, parseArguments(std.testing.allocator, args));
}

test "agent spec CLI validates JSON and YAML without building a model" {
    const arguments = Arguments{
        .path = "agent.yaml",
        .interpolate = true,
        .environment_names = &.{ "MODEL", "OPENAI_API_KEY" },
        .capability_ids = &.{"search"},
    };
    try validateSource(std.testing.allocator,
        \\version: 1
        \\provider:
        \\  name: openai
        \\  model: ${MODEL}
        \\  api_key: {env: OPENAI_API_KEY}
        \\capabilities: [{id: search}]
    , .yaml, arguments, TestEnvironment.value());
    try validateSource(std.testing.allocator,
        \\{"version":1,"provider":{"name":"anthropic","model":"claude"}}
    , .json, .{
        .path = "agent.json",
        .interpolate = false,
        .environment_names = &.{},
        .capability_ids = &.{},
    }, TestEnvironment.value());
    try std.testing.expect(TestEnvironment.value().get("MISSING") == null);
}

test "agent spec CLI reports provider URL environment and capability failures" {
    const base = Arguments{
        .path = "agent.yaml",
        .interpolate = false,
        .environment_names = &.{},
        .capability_ids = &.{},
    };
    try std.testing.expectError(error.UnknownProvider, validateSource(std.testing.allocator,
        \\version: 1
        \\provider: {name: unknown, model: model}
    , .yaml, base, TestEnvironment.value()));
    try std.testing.expectError(error.InvalidProviderConfiguration, validateSource(std.testing.allocator,
        \\version: 1
        \\provider: {name: openai, model: model, base_url: 'file:///tmp/model'}
    , .yaml, base, TestEnvironment.value()));
    try std.testing.expectError(error.EnvironmentVariableNotAllowed, validateSource(std.testing.allocator,
        \\version: 1
        \\provider: {name: openai, model: model, api_key: {env: OPENAI_API_KEY}}
    , .yaml, base, TestEnvironment.value()));
    try std.testing.expectError(error.UnknownCapability, validateSource(std.testing.allocator,
        \\version: 1
        \\provider: {name: openai, model: model}
        \\capabilities: [{id: search}]
    , .yaml, base, TestEnvironment.value()));
}
