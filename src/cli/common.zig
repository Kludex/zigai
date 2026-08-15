const std = @import("std");
const zigai = @import("zigai");

pub const Input = struct {
    prompt: []const u8,
    api_key: []const u8,
    stream: bool,
    tools_path: ?[]const u8,
};

/// Returns the transport policy for a provider endpoint selected by the CLI.
/// A custom endpoint is an explicit operator choice and may target local HTTP.
pub fn urlPolicyForConfiguredEndpoint(base_url: []const u8, default_url: []const u8) zigai.security.UrlPolicy {
    if (std.mem.eql(u8, base_url, default_url)) return .{};
    return .{
        .allow_http = std.ascii.startsWithIgnoreCase(base_url, "http://"),
        .allow_local_network = true,
    };
}

pub fn promptAndKey(init: std.process.Init, key_name: []const u8) !Input {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = parseArguments(args) catch {
        std.log.err("usage: {s} [--stream] [--tools <manifest.json>] <prompt>", .{args[0]});
        return error.InvalidArguments;
    };
    const key = init.environ_map.get(key_name) orelse {
        std.log.err("{s} is not set", .{key_name});
        return error.MissingApiKey;
    };
    if (key.len == 0) {
        std.log.err("{s} is empty", .{key_name});
        return error.MissingApiKey;
    }
    return .{ .prompt = parsed.prompt, .api_key = key, .stream = parsed.stream, .tools_path = parsed.tools_path };
}

const ParsedArguments = struct {
    prompt: []const u8,
    stream: bool = false,
    tools_path: ?[]const u8 = null,
};

fn parseArguments(args: []const []const u8) !ParsedArguments {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = ParsedArguments{ .prompt = "" };
    var has_prompt = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--stream")) {
            if (parsed.stream) return error.InvalidArguments;
            parsed.stream = true;
        } else if (std.mem.eql(u8, argument, "--tools")) {
            if (parsed.tools_path != null or index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            parsed.tools_path = args[index];
        } else if (std.mem.startsWith(u8, argument, "--") or has_prompt) {
            return error.InvalidArguments;
        } else {
            parsed.prompt = argument;
            has_prompt = true;
        }
    }
    if (!has_prompt) return error.InvalidArguments;
    return parsed;
}

pub const LoadedTools = struct {
    arena: std.heap.ArenaAllocator,
    tools: []const zigai.Tool,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !LoadedTools {
        const manifest_path = path orelse return .{ .arena = .init(allocator), .tools = &.{} };
        const json = try std.Io.Dir.cwd().readFileAlloc(
            io,
            manifest_path,
            allocator,
            .limited(zigai.json.defaults.cli_config.max_document_bytes),
        );
        defer allocator.free(json);
        return fromJson(allocator, io, json);
    }

    fn fromJson(allocator: std.mem.Allocator, io: std.Io, json: []const u8) !LoadedTools {
        try zigai.json.validate(allocator, json, zigai.json.defaults.cli_config);
        var loaded = LoadedTools{ .arena = .init(allocator), .tools = &.{} };
        errdefer loaded.deinit();
        const memory = loaded.arena.allocator();
        const owned_json = try memory.dupe(u8, json);
        const configs = try std.json.parseFromSliceLeaky([]const ToolConfig, memory, owned_json, .{ .ignore_unknown_fields = false });
        const runners = try memory.alloc(ToolRunner, configs.len);
        const tools = try memory.alloc(zigai.Tool, configs.len);
        for (configs, runners, tools) |config, *runner, *tool| {
            if (config.name.len == 0 or config.command.len == 0 or config.command[0].len == 0) return error.InvalidToolManifest;
            const schema = try std.json.Stringify.valueAlloc(memory, config.parameters, .{});
            runner.* = .{ .io = io, .command = config.command };
            tool.* = .{
                .definition = .{
                    .name = config.name,
                    .description = config.description,
                    .parameters_json_schema = schema,
                },
                .context = runner,
                .executeFn = ToolRunner.execute,
            };
        }
        loaded.tools = tools;
        return loaded;
    }

    pub fn deinit(self: *LoadedTools) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ToolConfig = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters: std.json.Value,
    command: []const []const u8,
};

const ToolRunner = struct {
    io: std.Io,
    command: []const []const u8,

    fn execute(context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        const self: *ToolRunner = @ptrCast(@alignCast(context));
        const argv = try allocator.alloc([]const u8, self.command.len + 1);
        for (self.command, argv[0..self.command.len]) |argument, *destination| destination.* = argument;
        argv[argv.len - 1] = arguments_json;
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        allocator.free(result.stderr);
        const succeeded = switch (result.term) {
            .exited => |status| status == 0,
            else => false,
        };
        if (!succeeded) {
            allocator.free(result.stdout);
            return error.ToolCommandFailed;
        }
        return result.stdout;
    }
};

pub fn streamSink(io: *std.Io) zigai.AgentStreamSink {
    return .{ .context = io, .eventFn = printStreamEvent };
}

fn printStreamEvent(context: *anyopaque, event: zigai.AgentStreamEvent) !void {
    const io: *std.Io = @ptrCast(@alignCast(context));
    const text = switch (event) {
        .model => |model_event| switch (model_event) {
            .text_delta => |value| value,
            else => return,
        },
        else => return,
    };
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), io.*, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

pub fn printNewline(io: std.Io) !void {
    var buffer: [1]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn printResult(io: std.Io, output: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try file_writer.interface.writeAll(output);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

test "CLI argument parsing accepts streaming and tool manifests in either order" {
    const first = try parseArguments(&.{ "cli", "--stream", "--tools", "tools.json", "hello" });
    try std.testing.expect(first.stream);
    try std.testing.expectEqualStrings("tools.json", first.tools_path.?);
    try std.testing.expectEqualStrings("hello", first.prompt);
    const second = try parseArguments(&.{ "cli", "hello", "--tools", "tools.json" });
    try std.testing.expect(!second.stream);
    try std.testing.expectEqualStrings("hello", second.prompt);
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{"cli"}));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "cli", "--tools" }));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "cli", "one", "two" }));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "cli", "--unknown", "one" }));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "cli", "--stream", "--stream", "one" }));
}

test "CLI endpoint policy keeps defaults strict and permits explicit local endpoints" {
    const strict = urlPolicyForConfiguredEndpoint("https://api.example.com", "https://api.example.com");
    try std.testing.expect(!strict.allow_http);
    try std.testing.expect(!strict.allow_local_network);

    const local = urlPolicyForConfiguredEndpoint("HTTP://127.0.0.1:8000", "https://api.example.com");
    try std.testing.expect(local.allow_http);
    try std.testing.expect(local.allow_local_network);

    const custom_https = urlPolicyForConfiguredEndpoint("https://gateway.internal", "https://api.example.com");
    try std.testing.expect(!custom_https.allow_http);
    try std.testing.expect(custom_https.allow_local_network);
}

test "tool manifests create executable provider-neutral tools" {
    var loaded = try LoadedTools.fromJson(std.testing.allocator, std.testing.io, "[{\"name\":\"echo\",\"description\":\"Echo JSON\",\"parameters\":{\"type\":\"object\"},\"command\":[\"/bin/echo\"]}]");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.tools.len);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", loaded.tools[0].definition.parameters_json_schema);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = try loaded.tools[0].execute(arena.allocator(), "{\"value\":1}");
    try std.testing.expectEqualStrings("{\"value\":1}\n", output);
    try std.testing.expectError(error.InvalidToolManifest, LoadedTools.fromJson(std.testing.allocator, std.testing.io, "[{\"name\":\"bad\",\"parameters\":{},\"command\":[]}]"));

    var failing = try LoadedTools.fromJson(std.testing.allocator, std.testing.io, "[{\"name\":\"fail\",\"parameters\":{},\"command\":[\"/usr/bin/false\"]}]");
    defer failing.deinit();
    try std.testing.expectError(error.ToolCommandFailed, failing.tools[0].execute(arena.allocator(), "{}"));
}

test "tool manifest loading enforces the CLI JSON nesting limit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = "[" ** 33 ++ "]" ** 33;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tools.json", .data = source });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/tools.json",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.NestingTooDeep,
        LoadedTools.load(std.testing.allocator, std.testing.io, path),
    );
}
