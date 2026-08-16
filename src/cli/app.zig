//! Unified production CLI configuration, provider selection, persistence, and execution.

const std = @import("std");
const zigai = @import("zigai");
const common = @import("common.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    runtime_error = 1,
    invalid_usage = 2,
    invalid_config = 3,
    missing_credential = 4,
    provider_error = 5,
    approval_required = 10,
};

pub const ProviderName = enum { openai, anthropic, google };
pub const OutputMode = enum { text, json, events };
pub const ApprovalMode = enum { deferred, approve, deny };
pub const Shell = enum { bash, zsh, fish };

pub const MCPServerConfig = struct {
    command: []const []const u8,
};

pub const Config = struct {
    provider: ProviderName = .openai,
    model: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    history_path: ?[]const u8 = null,
    paused_path: ?[]const u8 = null,
    tools_path: ?[]const u8 = null,
    require_tool_approval: bool = false,
    output: OutputMode = .text,
    approval: ApprovalMode = .deferred,
    mcp_servers: []const MCPServerConfig = &.{},
};

pub const OwnedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *OwnedConfig) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Arguments = struct {
    config_path: ?[]const u8 = null,
    provider: ?ProviderName = null,
    model: ?[]const u8 = null,
    history_path: ?[]const u8 = null,
    paused_path: ?[]const u8 = null,
    output: ?OutputMode = null,
    approval: ?ApprovalMode = null,
    mcp_commands: []const []const u8 = &.{},
    prompt: ?[]const u8 = null,
    stdin_prompt: bool = false,
    resume_run: bool = false,
    completion: ?Shell = null,
};

pub fn parseArguments(gpa: std.mem.Allocator, args: []const []const u8) !Arguments {
    if (args.len == 0) return error.InvalidArguments;
    var result: Arguments = .{};
    var mcp_commands: std.ArrayList([]const u8) = .empty;
    errdefer mcp_commands.deinit(gpa);
    var index: usize = 1;
    if (index < args.len and std.mem.eql(u8, args[index], "completion")) {
        if (index + 2 != args.len) return error.InvalidArguments;
        result.completion = std.meta.stringToEnum(Shell, args[index + 1]) orelse return error.InvalidArguments;
        return result;
    }
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--config")) {
            result.config_path = try optionValue(args, &index, result.config_path == null);
        } else if (std.mem.eql(u8, argument, "--provider")) {
            const value = try optionValue(args, &index, result.provider == null);
            result.provider = std.meta.stringToEnum(ProviderName, value) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--model")) {
            result.model = try optionValue(args, &index, result.model == null);
        } else if (std.mem.eql(u8, argument, "--history")) {
            result.history_path = try optionValue(args, &index, result.history_path == null);
        } else if (std.mem.eql(u8, argument, "--paused")) {
            result.paused_path = try optionValue(args, &index, result.paused_path == null);
        } else if (std.mem.eql(u8, argument, "--output")) {
            const value = try optionValue(args, &index, result.output == null);
            result.output = std.meta.stringToEnum(OutputMode, value) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--approval")) {
            const value = try optionValue(args, &index, result.approval == null);
            result.approval = std.meta.stringToEnum(ApprovalMode, value) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--mcp")) {
            try mcp_commands.append(gpa, try optionValue(args, &index, true));
        } else if (std.mem.eql(u8, argument, "--resume")) {
            if (result.resume_run) return error.InvalidArguments;
            result.resume_run = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            if (result.output != null) return error.InvalidArguments;
            result.output = .json;
        } else if (std.mem.eql(u8, argument, "--events")) {
            if (result.output != null) return error.InvalidArguments;
            result.output = .events;
        } else if (std.mem.eql(u8, argument, "-")) {
            if (result.prompt != null or result.stdin_prompt) return error.InvalidArguments;
            result.stdin_prompt = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return error.InvalidArguments;
        } else {
            if (result.prompt != null or result.stdin_prompt) return error.InvalidArguments;
            result.prompt = argument;
        }
    }
    if (!result.resume_run and result.prompt == null and !result.stdin_prompt) return error.InvalidArguments;
    if (result.resume_run and (result.prompt != null or result.stdin_prompt)) return error.InvalidArguments;
    result.mcp_commands = try mcp_commands.toOwnedSlice(gpa);
    return result;
}

pub fn deinitArguments(gpa: std.mem.Allocator, arguments: *Arguments) void {
    gpa.free(arguments.mcp_commands);
    arguments.* = undefined;
}

fn optionValue(args: []const []const u8, index: *usize, allowed: bool) ![]const u8 {
    if (!allowed or index.* + 1 >= args.len) return error.InvalidArguments;
    index.* += 1;
    if (args[index.*].len == 0) return error.InvalidArguments;
    return args[index.*];
}

pub fn loadConfig(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !OwnedConfig {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    if (path == null) return .{ .arena = arena, .value = .{} };
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path.?,
        arena.allocator(),
        .limited(zigai.json.defaults.cli_config.max_document_bytes),
    );
    const value = try zigai.json.parseLeaky(
        Config,
        arena.allocator(),
        source,
        zigai.json.defaults.cli_config,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
        error.InvalidCLIConfig,
    );
    try validateConfig(value);
    return .{ .arena = arena, .value = value };
}

fn validateConfig(config: Config) !void {
    if (config.model) |value| if (value.len == 0) return error.InvalidCLIConfig;
    if (config.api_key_env) |value| try validateIdentifier(value);
    for (config.mcp_servers) |server| {
        if (server.command.len == 0 or server.command[0].len == 0) return error.InvalidCLIConfig;
    }
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidCLIConfig;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return error.InvalidCLIConfig;
}

pub fn mergeConfig(config: Config, arguments: Arguments) Config {
    var result = config;
    if (arguments.provider) |value| result.provider = value;
    if (arguments.model) |value| result.model = value;
    if (arguments.history_path) |value| result.history_path = value;
    if (arguments.paused_path) |value| result.paused_path = value;
    if (arguments.output) |value| result.output = value;
    if (arguments.approval) |value| result.approval = value;
    return result;
}

pub fn defaultBaseURL(provider: ProviderName) []const u8 {
    return switch (provider) {
        .openai => zigai.openai.api_base,
        .anthropic => zigai.anthropic.api_base,
        .google => zigai.google.api_base,
    };
}

pub fn endpointPolicy(base_url: []const u8, default_base: []const u8) zigai.security.UrlPolicy {
    if (std.mem.eql(u8, base_url, default_base)) return .{};
    return .{
        .allow_http = std.ascii.startsWithIgnoreCase(base_url, "http://"),
        .allow_local_network = true,
    };
}

pub fn defaultModel(provider: ProviderName) []const u8 {
    return switch (provider) {
        .openai => "gpt-5-mini",
        .anthropic => "claude-sonnet-4-5",
        .google => "gemini-2.5-flash",
    };
}

pub fn defaultKeyEnvironment(provider: ProviderName) []const u8 {
    return switch (provider) {
        .openai => "OPENAI_API_KEY",
        .anthropic => "ANTHROPIC_API_KEY",
        .google => "GEMINI_API_KEY",
    };
}

pub fn completion(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => "complete -W '--config --provider --model --history --paused --output --approval --mcp --resume --json --events completion' zigai",
        .zsh => "compdef '_arguments \"--provider[provider]:provider:(openai anthropic google)\" \"--output[output]:output:(text json events)\"' zigai",
        .fish => "complete -c zigai -l provider -a 'openai anthropic google'; complete -c zigai -l output -a 'text json events'",
    };
}

pub fn classifyError(failure: anyerror) ExitCode {
    return switch (failure) {
        error.InvalidArguments => .invalid_usage,
        error.InvalidCLIConfig, error.FileNotFound => .invalid_config,
        error.MissingApiKey => .missing_credential,
        error.ProviderConnectionError,
        error.ProviderRateLimited,
        error.ProviderServerError,
        error.ProviderRequestFailed,
        error.ProviderResponseDecodeError,
        => .provider_error,
        else => .runtime_error,
    };
}

pub const HistoryStore = struct {
    path: []const u8,

    pub fn load(self: HistoryStore, gpa: std.mem.Allocator, io: std.Io) !?zigai.OwnedHistory {
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            self.path,
            gpa,
            .limited(zigai.json.defaults.history.max_document_bytes),
        ) catch |failure| return switch (failure) {
            error.FileNotFound => null,
            else => failure,
        };
        defer gpa.free(source);
        return try zigai.history.parse(gpa, source);
    }

    pub fn save(self: HistoryStore, gpa: std.mem.Allocator, io: std.Io, messages: []const zigai.Message) !void {
        const source = try zigai.history.stringify(gpa, messages);
        defer gpa.free(source);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(source);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
};

pub const PausedStore = struct {
    path: []const u8,

    const Document = struct {
        version: u8 = 1,
        state_json: []const u8,
        calls: []const Call,

        const Call = struct {
            call_id: []const u8,
            execution: zigai.model.ToolExecution,
        };
    };

    pub const Owned = struct {
        arena: std.heap.ArenaAllocator,
        state_json: []const u8,
        calls: []const Document.Call,

        pub fn deinit(self: *Owned) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub fn load(self: PausedStore, gpa: std.mem.Allocator, io: std.Io) !Owned {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            self.path,
            arena.allocator(),
            .limited(zigai.json.defaults.paused_state.max_document_bytes),
        );
        const document = try zigai.json.parseLeaky(
            Document,
            arena.allocator(),
            source,
            zigai.json.defaults.paused_state,
            .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
            error.InvalidPausedCLIState,
        );
        if (document.version != 1 or document.calls.len == 0) return error.InvalidPausedCLIState;
        return .{ .arena = arena, .state_json = document.state_json, .calls = document.calls };
    }

    pub fn save(self: PausedStore, gpa: std.mem.Allocator, io: std.Io, paused: zigai.PausedRun) !void {
        const calls = try gpa.alloc(Document.Call, paused.calls.len);
        defer gpa.free(calls);
        for (paused.calls, calls) |call, *copy| copy.* = .{
            .call_id = call.call_id,
            .execution = call.execution,
        };
        const source = try std.json.Stringify.valueAlloc(gpa, Document{
            .state_json = paused.state_json,
            .calls = calls,
        }, .{});
        defer gpa.free(source);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(source);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
};

pub const ProviderRuntime = union(ProviderName) {
    openai: OpenAIState,
    anthropic: AnthropicState,
    google: GoogleState,

    const OpenAIState = struct { provider: zigai.openai.Provider, client: zigai.openai.Client };
    const AnthropicState = struct { provider: zigai.anthropic.Provider, client: zigai.anthropic.Client };
    const GoogleState = struct { provider: zigai.google.Provider, client: zigai.google.Client };

    pub fn init(
        self: *ProviderRuntime,
        provider_name: ProviderName,
        model_name: []const u8,
        api_key: []const u8,
        base_url: ?[]const u8,
        url_policy: zigai.security.UrlPolicy,
        transport: zigai.transport.Transport,
    ) void {
        switch (provider_name) {
            .openai => {
                self.* = .{ .openai = .{
                    .provider = zigai.openai.Provider.initWithOptions(api_key, transport, .{
                        .base_url = base_url orelse zigai.openai.api_base,
                        .request_policy = .{ .url_policy = url_policy },
                    }),
                    .client = undefined,
                } };
                self.openai.client = .{
                    .model_name = model_name,
                    .provider = self.openai.provider.provider(),
                };
            },
            .anthropic => {
                self.* = .{ .anthropic = .{
                    .provider = zigai.anthropic.Provider.initWithOptions(api_key, transport, .{
                        .base_url = base_url orelse zigai.anthropic.api_base,
                        .request_policy = .{ .url_policy = url_policy },
                    }),
                    .client = undefined,
                } };
                self.anthropic.client = .{
                    .model_name = model_name,
                    .provider = self.anthropic.provider.provider(),
                };
            },
            .google => {
                self.* = .{ .google = .{
                    .provider = zigai.google.Provider.initWithOptions(api_key, transport, .{
                        .base_url = base_url orelse zigai.google.api_base,
                        .request_policy = .{ .url_policy = url_policy },
                    }),
                    .client = undefined,
                } };
                self.google.client = .{
                    .model_name = model_name,
                    .provider = self.google.provider.provider(),
                };
            },
        }
    }

    pub fn model(self: *ProviderRuntime) zigai.Model {
        return switch (self.*) {
            .openai => |*state| state.client.model(),
            .anthropic => |*state| state.client.model(),
            .google => |*state| state.client.model(),
        };
    }
};

pub const MCPRuntime = struct {
    gpa: std.mem.Allocator,
    transports: []zigai.mcp.StdioTransport,
    clients: []zigai.mcp.Client,
    toolsets: []zigai.Toolset,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        configured: []const MCPServerConfig,
        commands: []const []const u8,
    ) !MCPRuntime {
        const count = configured.len + commands.len;
        const transports = try gpa.alloc(zigai.mcp.StdioTransport, count);
        errdefer gpa.free(transports);
        const clients = try gpa.alloc(zigai.mcp.Client, count);
        errdefer gpa.free(clients);
        const toolsets = try gpa.alloc(zigai.Toolset, count);
        errdefer gpa.free(toolsets);
        var initialized: usize = 0;
        errdefer for (transports[0..initialized]) |*transport| transport.deinit();
        for (configured) |server| {
            transports[initialized] = try zigai.mcp.StdioTransport.init(io, server.command);
            clients[initialized] = .{ .transport = transports[initialized].transport() };
            toolsets[initialized] = clients[initialized].toolset();
            initialized += 1;
        }
        for (commands) |command| {
            transports[initialized] = try zigai.mcp.StdioTransport.init(io, &.{command});
            clients[initialized] = .{ .transport = transports[initialized].transport() };
            toolsets[initialized] = clients[initialized].toolset();
            initialized += 1;
        }
        return .{ .gpa = gpa, .transports = transports, .clients = clients, .toolsets = toolsets };
    }

    pub fn deinit(self: *MCPRuntime) void {
        for (self.transports) |*transport| transport.deinit();
        self.gpa.free(self.toolsets);
        self.gpa.free(self.clients);
        self.gpa.free(self.transports);
        self.* = undefined;
    }
};

const EventOutput = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    enabled: bool,

    fn emit(context: ?*anyopaque, event: zigai.ui.Event) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.enabled) return;
        const json = try zigai.ui.ag_ui.encode(self.gpa, event);
        defer self.gpa.free(json);
        try writeOutput(self.io, json, true);
    }
};

pub fn execute(init: std.process.Init, args: []const []const u8) !ExitCode {
    var arguments = try parseArguments(init.gpa, args);
    defer deinitArguments(init.gpa, &arguments);
    if (arguments.completion) |shell| {
        try writeOutput(init.io, completion(shell), true);
        return .success;
    }
    var owned_config = try loadConfig(init.gpa, init.io, arguments.config_path);
    defer owned_config.deinit();
    const config = mergeConfig(owned_config.value, arguments);
    const key_name = config.api_key_env orelse defaultKeyEnvironment(config.provider);
    const api_key = init.environ_map.get(key_name) orelse return error.MissingApiKey;
    if (api_key.len == 0) return error.MissingApiKey;
    const model_name = config.model orelse defaultModel(config.provider);
    const default_base = defaultBaseURL(config.provider);
    const base_url = config.base_url orelse default_base;
    const url_policy = endpointPolicy(base_url, default_base);
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{ .url_policy = url_policy });
    defer http.deinit();
    var provider_runtime: ProviderRuntime = undefined;
    provider_runtime.init(
        config.provider,
        model_name,
        api_key,
        config.base_url,
        url_policy,
        http.transport(),
    );
    var mcp = try MCPRuntime.init(init.gpa, init.io, config.mcp_servers, arguments.mcp_commands);
    defer mcp.deinit();
    var loaded_tools = try common.LoadedTools.load(init.gpa, init.io, config.tools_path);
    defer loaded_tools.deinit();
    if (config.require_tool_approval) {
        for (@constCast(loaded_tools.tools)) |*tool| tool.execution = .requires_approval;
    }
    var agent = zigai.Agent{
        .model = provider_runtime.model(),
        .system_prompt = config.system_prompt,
        .tools = loaded_tools.tools,
        .toolsets = mcp.toolsets,
        .url_policy = url_policy,
        .io = init.io,
    };

    const prompt: ?[]u8 = if (!arguments.resume_run)
        if (arguments.stdin_prompt)
            try readStdin(init.gpa, init.io) // kcov-ignore: piped stdin is exercised by scripts/test-cli
        else
            try init.gpa.dupe(u8, arguments.prompt.?)
    else
        null;
    defer if (prompt) |value| init.gpa.free(value);
    return runAgent(init.gpa, init.io, &agent, config, arguments.resume_run, prompt, true);
}

pub fn runAgent(
    gpa: std.mem.Allocator,
    io: std.Io,
    agent: *zigai.Agent,
    config: Config,
    resume_run: bool,
    prompt: ?[]const u8,
    emit_output: bool,
) !ExitCode {
    var owned_history: ?zigai.OwnedHistory = if (config.history_path) |path|
        try (HistoryStore{ .path = path }).load(gpa, io)
    else
        null;
    defer if (owned_history) |*history| history.deinit();
    const run_options = zigai.RunOptions{
        .message_history = if (owned_history) |history| history.messages else &.{},
    };
    var event_output = EventOutput{ .gpa = gpa, .io = io, .enabled = emit_output };
    var bridge = zigai.ui.Bridge{
        .sink = .{ .context = &event_output, .event_fn = EventOutput.emit },
        .thread_id = "cli",
        .run_id = "cli-run",
    };
    if (config.output == .events) try bridge.begin();

    var outcome: zigai.RunOutcome = if (resume_run) resume_block: {
        const paused_path = config.paused_path orelse ".zigai-paused.json";
        var saved = try (PausedStore{ .path = paused_path }).load(gpa, io);
        defer saved.deinit();
        if (config.approval == .deferred) return error.ApprovalDecisionRequired;
        const decisions = try decisionsForCalls(gpa, saved.calls, config.approval);
        defer gpa.free(decisions);
        break :resume_block try agent.resumeRunWithOptions(gpa, saved.state_json, decisions, run_options);
    } else if (config.output == .events)
        try agent.runUntilPauseStreamWithOptions(gpa, prompt.?, run_options, bridge.agentSink())
    else
        try agent.runUntilPauseWithOptions(gpa, prompt.?, run_options);

    while (true) switch (outcome) {
        .complete => |*result| {
            defer result.deinit();
            if (config.output == .events) {
                try bridge.finish();
            } else if (emit_output) {
                try printResult(gpa, io, result, config.output);
            }
            if (config.history_path) |path| try (HistoryStore{ .path = path }).save(gpa, io, result.messages);
            return .success;
        },
        .paused => |*paused| {
            if (config.approval == .deferred) {
                const paused_path = config.paused_path orelse ".zigai-paused.json";
                try (PausedStore{ .path = paused_path }).save(gpa, io, paused.*);
                if (emit_output) try printPaused(gpa, io, paused.calls, paused_path);
                paused.deinit();
                return .approval_required;
            }
            const decisions = try decisionsForCalls(gpa, paused.calls, config.approval);
            defer gpa.free(decisions);
            const next = try agent.resumeRunWithOptions(gpa, paused.state_json, decisions, run_options);
            paused.deinit();
            outcome = next;
        },
    };
}

fn decisionsForCalls(gpa: std.mem.Allocator, calls: anytype, mode: ApprovalMode) ![]zigai.ResumeDecision {
    const decisions = try gpa.alloc(zigai.ResumeDecision, calls.len);
    for (calls, decisions) |call, *decision| {
        decision.* = .{
            .call_id = call.call_id,
            .action = if (mode == .approve and call.execution == .requires_approval) .approve else .deny,
            .content = if (mode == .deny or call.execution != .requires_approval) "Denied by CLI policy." else null,
        };
    }
    return decisions;
}

fn readStdin(gpa: std.mem.Allocator, io: std.Io) ![]u8 { // kcov-ignore: piped stdin is exercised by scripts/test-cli
    var buffer: [4096]u8 = undefined; // kcov-ignore: OS stdin wrapper
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer); // kcov-ignore: OS stdin wrapper
    return readPrompt(gpa, &reader.interface); // kcov-ignore: OS stdin wrapper
}

fn readPrompt(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const input = try reader.allocRemaining(gpa, .limited(1024 * 1024));
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(input);
        return error.EmptyPrompt;
    }
    if (trimmed.ptr == input.ptr and trimmed.len == input.len) return input;
    const result = try gpa.dupe(u8, trimmed);
    gpa.free(input);
    return result;
}

fn printResult(gpa: std.mem.Allocator, io: std.Io, result: *const zigai.Agent.Result, mode: OutputMode) !void {
    if (mode == .text) return writeOutput(io, result.output, true);
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .output = result.output,
        .model_requests = result.model_requests,
        .usage = result.usage,
    }, .{});
    defer gpa.free(json);
    try writeOutput(io, json, true);
}

fn printPaused(
    gpa: std.mem.Allocator,
    io: std.Io,
    calls: []const zigai.DeferredToolCall,
    path: []const u8,
) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .status = "approval_required",
        .paused_path = path,
        .calls = calls,
    }, .{});
    defer gpa.free(json);
    try writeOutput(io, json, true);
}

fn writeOutput(io: std.Io, value: []const u8, newline: bool) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll(value);
    if (newline) try output.interface.writeByte('\n');
    try output.interface.flush();
}

test "production CLI parses overrides completions and exit codes" {
    var arguments = try parseArguments(std.testing.allocator, &.{
        "zigai",
        "--provider",
        "anthropic",
        "--model",
        "claude",
        "--history",
        "history.json",
        "--paused",
        "paused.json",
        "--events",
        "--approval",
        "approve",
        "--mcp",
        "server",
        "hello",
    });
    defer deinitArguments(std.testing.allocator, &arguments);
    const config = mergeConfig(.{}, arguments);
    try std.testing.expectEqual(ProviderName.anthropic, config.provider);
    try std.testing.expectEqual(OutputMode.events, config.output);
    try std.testing.expectEqual(ApprovalMode.approve, config.approval);
    try std.testing.expectEqualStrings("claude", config.model.?);
    try std.testing.expectEqual(@as(usize, 1), arguments.mcp_commands.len);
    try std.testing.expectEqualStrings("hello", arguments.prompt.?);

    var completion_args = try parseArguments(std.testing.allocator, &.{ "zigai", "completion", "fish" });
    defer deinitArguments(std.testing.allocator, &completion_args);
    try std.testing.expectEqual(Shell.fish, completion_args.completion.?);
    try std.testing.expect(std.mem.indexOf(u8, completion(.bash), "complete") != null);
    try std.testing.expectError(error.InvalidArguments, parseArguments(std.testing.allocator, &.{"zigai"}));
    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(std.testing.allocator, &.{ "zigai", "--resume", "prompt" }),
    );
    try std.testing.expectEqual(ExitCode.missing_credential, classifyError(error.MissingApiKey));
    try std.testing.expectEqual(ExitCode.provider_error, classifyError(error.ProviderRateLimited));
    try std.testing.expectEqualStrings("gpt-5-mini", defaultModel(.openai));
    try std.testing.expectEqualStrings("GEMINI_API_KEY", defaultKeyEnvironment(.google));
    try std.testing.expectEqualStrings(zigai.anthropic.api_base, defaultBaseURL(.anthropic));
    try std.testing.expect(!endpointPolicy(zigai.openai.api_base, zigai.openai.api_base).allow_http);
    try std.testing.expect(endpointPolicy("http://localhost:8000", zigai.openai.api_base).allow_local_network);

    var output_args = try parseArguments(std.testing.allocator, &.{ "zigai", "--output", "text", "-" });
    defer deinitArguments(std.testing.allocator, &output_args);
    try std.testing.expect(output_args.stdin_prompt);
    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(std.testing.allocator, &.{ "zigai", "--json", "--events", "prompt" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArguments(std.testing.allocator, &.{ "zigai", "--unknown", "prompt" }),
    );
    var prompt_reader = std.Io.Reader.fixed("  stdin prompt\n");
    const prompt = try readPrompt(std.testing.allocator, &prompt_reader);
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("stdin prompt", prompt);
    var empty_reader = std.Io.Reader.fixed(" \n");
    try std.testing.expectError(error.EmptyPrompt, readPrompt(std.testing.allocator, &empty_reader));
}

test "production CLI config history paused state and provider selection are owned" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "{\"provider\":\"google\",\"model\":\"gemini\",\"output\":\"json\",\"mcp_servers\":[]}",
    });
    const directory = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(directory);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{directory});
    defer std.testing.allocator.free(config_path);
    var defaults = try loadConfig(std.testing.allocator, std.testing.io, null);
    defaults.deinit();
    var config = try loadConfig(std.testing.allocator, std.testing.io, config_path);
    defer config.deinit();
    try std.testing.expectEqual(ProviderName.google, config.value.provider);
    const ConfigAllocation = struct {
        fn run(gpa: std.mem.Allocator, path: []const u8) !void {
            var loaded = try loadConfig(gpa, std.testing.io, path);
            loaded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ConfigAllocation.run,
        .{config_path},
    );
    try std.testing.expectError(error.InvalidCLIConfig, validateConfig(.{ .model = "" }));
    try std.testing.expectError(error.InvalidCLIConfig, validateConfig(.{ .api_key_env = "BAD-NAME" }));
    try std.testing.expectError(
        error.InvalidCLIConfig,
        validateConfig(.{ .mcp_servers = &.{.{ .command = &.{} }} }),
    );

    const history_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/history.json", .{directory});
    defer std.testing.allocator.free(history_path);
    const messages = [_]zigai.Message{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "hello" } }} } }};
    const history_store = HistoryStore{ .path = history_path };
    try history_store.save(std.testing.allocator, std.testing.io, &messages);
    var loaded_history = (try history_store.load(std.testing.allocator, std.testing.io)).?;
    defer loaded_history.deinit();
    try std.testing.expectEqualStrings("hello", loaded_history.messages[0].request.parts[0].user_prompt.text);

    const paused_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/paused.json", .{directory});
    defer std.testing.allocator.free(paused_path);
    var paused_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer paused_arena.deinit();
    const paused = zigai.PausedRun{
        .arena = paused_arena,
        .state_json = "{\"version\":2}",
        .calls = &.{.{
            .call_id = "call-1",
            .name = "tool",
            .arguments_json = "{}",
            .execution = .requires_approval,
        }},
        .usage = .{},
        .model_requests = 1,
    };
    const paused_store = PausedStore{ .path = paused_path };
    try paused_store.save(std.testing.allocator, std.testing.io, paused);
    var loaded_paused = try paused_store.load(std.testing.allocator, std.testing.io);
    defer loaded_paused.deinit();
    try std.testing.expectEqualStrings("call-1", loaded_paused.calls[0].call_id);
    const PausedAllocation = struct {
        fn run(gpa: std.mem.Allocator, path: []const u8) !void {
            var loaded = try (PausedStore{ .path = path }).load(gpa, std.testing.io);
            loaded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        PausedAllocation.run,
        .{paused_path},
    );

    const Transport = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return error.ModelMustNotRun;
        }
    };
    var marker: u8 = 0;
    const transport = zigai.transport.Transport{ .context = &marker, .sendFn = Transport.send };
    inline for (std.meta.fields(ProviderName)) |field| {
        const provider: ProviderName = @enumFromInt(field.value);
        var runtime: ProviderRuntime = undefined;
        runtime.init(provider, defaultModel(provider), "key", null, .{}, transport);
        try std.testing.expect(runtime.model().provider_name != null);
    }

    var mcp = try MCPRuntime.init(std.testing.allocator, std.testing.io, &.{}, &.{});
    mcp.deinit();
    const MCPAllocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var runtime = MCPRuntime.init(gpa, std.testing.io, &.{.{ .command = &.{} }}, &.{}) catch |failure| {
                if (failure == error.EmptyCommand) return;
                return failure;
            };
            runtime.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, MCPAllocation.run, .{});
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[],"ttlMs":0,"cacheScope":"private"}}' ;;
        \\  esac
        \\done
    ;
    var configured_mcp = try MCPRuntime.init(
        std.testing.allocator,
        std.testing.io,
        &.{.{ .command = &.{ "/bin/sh", "-c", script } }},
        &.{"/bin/cat"},
    );
    var prepared_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer prepared_arena.deinit();
    const prepared = try configured_mcp.toolsets[0].prepare(prepared_arena.allocator(), .{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    });
    try std.testing.expectEqual(@as(usize, 0), prepared.len);
    configured_mcp.deinit();
    inline for (std.meta.fields(ProviderName)) |field| {
        const provider: ProviderName = @enumFromInt(field.value);
        var runtime: ProviderRuntime = undefined;
        runtime.init(provider, defaultModel(provider), "key", null, .{}, transport);
        try std.testing.expectError(
            error.ModelMustNotRun,
            runtime.model().request(std.testing.allocator, .{ .messages = &.{} }),
        );
    }
}

test "production CLI runs events and persists resumable tool approvals" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(directory);
    const paused_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/approval.json", .{directory});
    defer std.testing.allocator.free(paused_path);
    const history_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/history.json", .{directory});
    defer std.testing.allocator.free(history_path);

    const call_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "call-1",
        .name = "publish",
        .arguments_json = "{}",
    } }};
    const final_parts = [_]zigai.Part{.{ .text = "published" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &call_parts },
        .{ .parts = &final_parts },
    } };
    var executions: usize = 0;
    const tool = zigai.Tool{
        .definition = .{ .name = "publish", .description = "", .parameters_json_schema = "{}" },
        .execution = .requires_approval,
        .context = &executions,
        .executeFn = struct {
            fn execute(context: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![]const u8 {
                const count: *usize = @ptrCast(@alignCast(context));
                count.* += 1;
                return gpa.dupe(u8, "ok");
            }
        }.execute,
    };
    var agent = zigai.Agent{ .model = scripted.model(), .tools = &.{tool} };
    const deferred = Config{
        .paused_path = paused_path,
        .history_path = history_path,
        .approval = .deferred,
        .output = .json,
    };
    try std.testing.expectEqual(
        ExitCode.approval_required,
        try runAgent(std.testing.allocator, std.testing.io, &agent, deferred, false, "publish", false),
    );
    try std.testing.expectEqual(@as(usize, 0), executions);
    var approved = deferred;
    approved.approval = .approve;
    try std.testing.expectEqual(
        ExitCode.success,
        try runAgent(std.testing.allocator, std.testing.io, &agent, approved, true, null, false),
    );
    try std.testing.expectEqual(@as(usize, 1), executions);

    const event_parts = [_]zigai.Part{.{ .text = "event" }};
    var event_script = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &event_parts }},
        .profile = .{ .supports_streaming = true },
    };
    var event_agent = zigai.Agent{ .model = event_script.model() };
    try std.testing.expectEqual(
        ExitCode.success,
        try runAgent(std.testing.allocator, std.testing.io, &event_agent, .{ .output = .events }, false, "event", false),
    );

    var inline_script = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &call_parts },
        .{ .parts = &final_parts },
    } };
    var inline_agent = zigai.Agent{ .model = inline_script.model(), .tools = &.{tool} };
    try std.testing.expectEqual(
        ExitCode.success,
        try runAgent(std.testing.allocator, std.testing.io, &inline_agent, .{ .approval = .approve }, false, "publish", false),
    );

    const external_calls = [_]PausedStore.Document.Call{.{
        .call_id = "external",
        .execution = .external,
    }};
    const denied = try decisionsForCalls(std.testing.allocator, &external_calls, .approve);
    defer std.testing.allocator.free(denied);
    try std.testing.expectEqual(zigai.ResumeAction.deny, denied[0].action);
}
