//! Opt-in recorder for the real-provider model cassette matrix.

const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("support/cassettes.zig");
const manifest = @import("support/cassette_manifest.zig");
const output_scenarios = @import("support/output_scenarios.zig");
const stream_scenarios = @import("support/stream_scenarios.zig");

const prompt = "Call the weather tool exactly once with city Madrid. Then reply with one short sentence.";
const system_prompt = "Always use the weather tool before answering.";
const native_prompt = "Use the available web tools to read https://ziglang.org and answer with the site's main heading in one short sentence.";
const native_google_prompt = "Use Google Search to identify the current stable Zig release. Answer in one short sentence.";
const native_system_prompt = "Use the available provider-managed web tool before answering.";
const rich_prompt = "Name the single dominant color in this image. Answer with one word.";
const pixel_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const filters = args[1..];
    manifest.validateFilters(filters) catch |failure| {
        std.log.err("invalid cassette filter: {s}", .{@errorName(failure)});
        std.process.exit(2);
    };
    if (hasArgument(filters, "--list") or hasArgument(filters, "--list-runnable")) {
        try listRecordings(init, filters, hasArgument(filters, "--list-runnable"));
        return;
    }

    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();

    for (manifest.all) |entry| {
        if (!manifest.selected(entry, filters)) continue;
        const key = requiredCredential(init, entry, 0);
        switch (entry.route) {
            .openai => switch (entry.scenario) {
                .buffered, .function_tool, .streamed_text, .streamed_function_tool, .structured_output, .thinking => try recordOpenAI(init, http.transport(), key, entry),
                .native_tool => try recordNativeOpenAI(init, http.transport(), key, entry),
                else => unreachable,
            },
            .anthropic => switch (entry.scenario) {
                .buffered, .function_tool, .streamed_text, .streamed_function_tool, .structured_output, .thinking => try recordAnthropic(init, http.transport(), key, entry),
                .native_tool => try recordNativeAnthropic(init, http.transport(), key, entry),
                else => unreachable,
            },
            .google => switch (entry.scenario) {
                .buffered, .function_tool, .streamed_text, .streamed_function_tool, .structured_output, .thinking => try recordGoogle(init, http.transport(), key, entry),
                .native_tool => try recordNativeGoogle(init, http.transport(), key, entry),
                else => unreachable,
            },
            .compatible => try recordCompatible(init, http.transport(), key, entry),
            .bedrock_converse => try recordNativeBedrock(
                init,
                http.transport(),
                key,
                requiredCredential(init, entry, 1),
                entry,
            ),
            .azure_responses => try recordNativeAzure(
                init,
                http.transport(),
                key,
                requiredCredential(init, entry, 1),
                entry,
            ),
            .mistral_conversations => try recordNativeMistral(init, http.transport(), key, entry),
            .cohere_chat => try recordNativeCohere(init, http.transport(), key, entry),
            .openai_rich => try recordRichOpenAI(init, http.transport(), key, entry),
            .anthropic_rich => try recordRichAnthropic(init, http.transport(), key, entry),
            .google_rich => try recordRichGoogle(init, http.transport(), key, entry),
            .openai_files => try recordOpenAIFileLifecycle(init, http.transport(), key),
            .anthropic_files => try recordAnthropicFileLifecycle(init, http.transport(), key),
            .google_files => try recordGoogleFileLifecycle(init, http.transport(), key),
        }
    }
}

fn recordCompatible(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    const base_url = switch (entry.endpoint) {
        .fixed => entry.base_url,
        .azure_openai => try zigai.providers.azure_openai.apiBase(
            init.gpa,
            requiredCredential(init, entry, 1),
        ),
        .bedrock => try zigai.providers.bedrock.mantleApiBase(
            init.gpa,
            requiredCredential(init, entry, 1),
        ),
    };
    defer if (entry.endpoint != .fixed) init.gpa.free(base_url);

    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.providers.openai_compatible.Provider.initWithOptions(api_key, recording.transport(), .{
        .base_url = base_url,
        .provider_name = entry.provider,
        .authentication = if (entry.api_key_header)
            .{ .header = "api-key", .prefix = "" }
        else
            .{},
    });
    var client = zigai.providers.openai_compatible.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runTextScenario(init, client.model());
    if (entry.endpoint != .fixed) try normalizeCompatibleUrl(init.gpa, &recording, entry);
    try writeCompatible(init, recording, entry);
}

fn normalizeCompatibleUrl(
    allocator: std.mem.Allocator,
    recording: *cassettes.RecordingTransport,
    entry: manifest.Entry,
) !void {
    const fixture_base = switch (entry.endpoint) {
        .azure_openai => "https://example.openai.azure.com/openai/v1",
        .bedrock => "https://bedrock-mantle.example-region.api.aws/v1",
        .fixed => return,
    };
    for (recording.interactions.items) |*interaction| {
        allocator.free(interaction.request.url);
        interaction.request.url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{fixture_base});
    }
}

fn runTextScenario(init: std.process.Init, model: zigai.Model) !void {
    var observer_context: u8 = 0;
    var result = try (zigai.Agent{
        .model = model,
        .io = init.io,
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 2 },
        .provider_error_observer = .{ .context = &observer_context, .observeFn = logProviderError },
    }).run(init.gpa, "Reply with exactly: pong");
    defer result.deinit();
    if (!std.mem.eql(u8, result.output, "pong") or result.usage.totalTokens() == 0)
        return error.UnexpectedModelBehavior;
}

fn writeCompatible(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: manifest.Entry,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} -> {s}", .{ entry.provider, entry.model, path });
}

fn hasArgument(arguments: []const []const u8, expected: []const u8) bool {
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, expected)) return true;
    }
    return false;
}

fn credentialValue(init: std.process.Init, requirement: manifest.CredentialRequirement) ?[]const u8 {
    for (requirement.alternatives) |name| {
        const value = init.environ_map.get(name) orelse continue;
        if (value.len > 0) return value;
    }
    return null;
}

fn requiredCredential(init: std.process.Init, entry: manifest.Entry, index: usize) []const u8 {
    const requirements = manifest.credentialRequirements(entry.credentials);
    const requirement = requirements[index];
    return credentialValue(init, requirement) orelse {
        std.log.err("{s} is not runnable; set one of its credential variables", .{entry.id});
        for (requirement.alternatives) |name| std.log.err("  {s}", .{name});
        std.process.exit(1);
    };
}

fn credentialsAvailable(init: std.process.Init, entry: manifest.Entry) bool {
    for (manifest.credentialRequirements(entry.credentials)) |requirement| {
        if (credentialValue(init, requirement) == null) return false;
    }
    return true;
}

fn listRecordings(
    init: std.process.Init,
    filters: []const []const u8,
    runnable_only: bool,
) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    for (manifest.all) |entry| {
        if (!manifest.selected(entry, filters)) continue;
        const ready = credentialsAvailable(init, entry);
        if (runnable_only and !ready) continue;
        try output.interface.print("{s}\t{s}\t{s}\t{s}\n", .{
            if (ready) "ready" else "missing-credentials",
            entry.provider,
            entry.scenario.name(),
            entry.id,
        });
    }
    try output.interface.flush();
}

fn runFirstPartyScenario(
    init: std.process.Init,
    model: zigai.Model,
    scenario: manifest.Scenario,
    require_thinking_parts: bool,
) !void {
    switch (scenario) {
        .buffered => try runTextScenario(init, model),
        .function_tool => try runScenario(init, model),
        .streamed_text => try runStreamTextScenario(init, model),
        .streamed_function_tool => try runStreamToolScenario(init, model),
        .structured_output => try output_scenarios.runStructured(init.gpa, init.io, model),
        .thinking => try output_scenarios.runThinking(init.gpa, init.io, model, require_thinking_parts),
        else => unreachable,
    }
}

fn runStreamTextScenario(init: std.process.Init, model: zigai.Model) !void {
    var capture: stream_scenarios.Capture = .{};
    var result = try (zigai.Agent{
        .model = model,
        .io = init.io,
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 2 },
    }).runStream(init.gpa, stream_scenarios.text_prompt, capture.sink());
    defer result.deinit();
    try capture.validateText(result.output, result.usage);
}

fn runStreamToolScenario(init: std.process.Init, model: zigai.Model) !void {
    var tool_calls: u8 = 0;
    const tool = stream_scenarios.weatherTool(&tool_calls);
    var capture: stream_scenarios.Capture = .{};
    var result = try (zigai.Agent{
        .model = model,
        .io = init.io,
        .tools = &.{tool},
        .system_prompt = stream_scenarios.tool_system_prompt,
        .model_settings = .{ .max_tokens = 1024 },
        .limits = .{ .max_model_requests = 4, .max_tool_calls = 2 },
    }).runStream(init.gpa, stream_scenarios.tool_prompt, capture.sink());
    defer result.deinit();
    try capture.validateTool(result.output, result.usage, tool_calls);
}

fn recordOpenAI(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.openai.Provider.init(api_key, recording.transport());
    var client = zigai.openai.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runFirstPartyScenario(init, client.model(), entry.scenario, false);
    try write(init, recording, entry, "openai");
}

fn recordAnthropic(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.anthropic.Provider.init(api_key, recording.transport());
    var client = zigai.anthropic.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
        .max_tokens = 128,
    };
    try runFirstPartyScenario(init, client.model(), entry.scenario, true);
    try write(init, recording, entry, "anthropic");
}

fn recordGoogle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.google.Provider.init(api_key, recording.transport());
    var client = zigai.google.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runFirstPartyScenario(init, client.model(), entry.scenario, false);
    try write(init, recording, entry, "google");
}

fn recordOpenAIFileLifecycle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
) !void {
    const multipart = cassettes.MultipartFileFilter{};
    var recording = cassettes.RecordingTransport.initWithOptions(init.gpa, transport, .{
        .request_filters = .{ .body = multipart.bodyFilter() },
    });
    defer recording.deinit();
    var concrete = zigai.openai.Provider.init(api_key, recording.transport());
    try runFileLifecycle(init, concrete.provider(), true, "fine-tune");
    try writeFileLifecycle(init, recording, "openai");
}

fn recordAnthropicFileLifecycle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
) !void {
    const multipart = cassettes.MultipartFileFilter{};
    var recording = cassettes.RecordingTransport.initWithOptions(init.gpa, transport, .{
        .request_filters = .{ .body = multipart.bodyFilter() },
    });
    defer recording.deinit();
    var concrete = zigai.anthropic.Provider.init(api_key, recording.transport());
    try runFileLifecycle(init, concrete.provider(), false, null);
    try writeFileLifecycle(init, recording, "anthropic");
}

fn recordGoogleFileLifecycle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
) !void {
    const session_url = "https://generativelanguage.googleapis.com/upload/v1beta/files/REDACTED";
    const url_filter = cassettes.PrefixRedactionFilter{
        .prefix = "https://generativelanguage.googleapis.com/upload/v1beta/files?",
        .replacement = session_url,
    };
    const body_filter = cassettes.NonJsonBodyFilter{};
    const response_headers = cassettes.ResponseHeaderRules{ .rules = &.{.{
        .name = "x-goog-upload-url",
        .replacement = session_url,
    }} };
    var recording = cassettes.RecordingTransport.initWithOptions(init.gpa, transport, .{
        .request_filters = .{
            .url = url_filter.bodyFilter(),
            .body = body_filter.bodyFilter(),
        },
        .response_header_filter = response_headers.filter(),
    });
    defer recording.deinit();
    var concrete = zigai.google.Provider.init(api_key, recording.transport());
    try runFileLifecycle(init, concrete.provider(), false, null);
    try writeFileLifecycle(init, recording, "google");
}

fn runFileLifecycle(init: std.process.Init, provider: zigai.Provider, download: bool, purpose: ?[]const u8) !void {
    const fine_tune_body = "{\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"},{\"role\":\"assistant\",\"content\":\"Hello\"}]}\n";
    const filename = if (purpose != null and std.mem.eql(u8, purpose.?, "fine-tune")) "zigai-cassette.jsonl" else "zigai-cassette.txt";
    const bytes = if (purpose != null and std.mem.eql(u8, purpose.?, "fine-tune")) fine_tune_body else "ZigAI file cassette fixture.\n";
    var uploaded = try provider.uploadFile(init.gpa, .{
        .filename = filename,
        .media_type = "text/plain",
        .bytes = bytes,
        .purpose = purpose,
    });
    defer uploaded.deinit();
    const file = uploaded.value.uploadedFile();
    var delete_pending = true;
    defer if (delete_pending) provider.deleteFile(init.gpa, file) catch |failure| {
        std.log.err("failed to clean up temporary {s} file {s}: {s}", .{ provider.name, file.id, @errorName(failure) });
    };
    var inspected = try provider.inspectFile(init.gpa, file);
    defer inspected.deinit();
    if (download) {
        try (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }).sleep(init.io);
        var downloaded = try provider.downloadFile(init.gpa, file);
        defer downloaded.deinit();
        if (!std.mem.eql(u8, downloaded.value.bytes, bytes)) return error.UnexpectedModelBehavior;
    }
    try provider.deleteFile(init.gpa, file);
    delete_pending = false;
}

fn recordNativeOpenAI(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.openai.Provider.init(api_key, recording.transport());
    var client = zigai.openai.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runNativeScenario(init, client.model(), &.{.{ .web_search = .{} }}, native_prompt);
    try writeNative(init, recording, entry);
}

fn recordNativeAnthropic(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.anthropic.Provider.init(api_key, recording.transport());
    var client = zigai.anthropic.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
        .max_tokens = 256,
    };
    try runNativeScenario(init, client.model(), &.{
        .{ .web_search = .{} },
        .{ .web_fetch = .{} },
    }, native_prompt);
    try writeNative(init, recording, entry);
}

fn recordNativeGoogle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.google.Provider.init(api_key, recording.transport());
    var client = zigai.google.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runNativeScenario(init, client.model(), &.{
        .{ .web_search = .{} },
        .{ .web_fetch = .{} },
    }, native_google_prompt);
    try writeNative(init, recording, entry);
}

fn recordNativeBedrock(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    region: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = try zigai.providers.bedrock.Provider.init(api_key, region, recording.transport());
    var client = zigai.providers.bedrock.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runScenario(init, client.model());
    try normalizeBedrockRuntimeUrl(init.gpa, &recording, provider.http.base_url);
    try writeNative(init, recording, entry);
}

fn recordNativeAzure(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    endpoint: []const u8,
    entry: manifest.Entry,
) !void {
    const base_url = try zigai.providers.azure_openai.apiBase(init.gpa, endpoint);
    defer init.gpa.free(base_url);
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.providers.azure_openai.Provider.initWithOptions(api_key, recording.transport(), .{
        .base_url = base_url,
    });
    var client = zigai.providers.azure_openai.ResponsesClient{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runScenario(init, client.model());
    try normalizeAzureUrl(init.gpa, &recording, base_url);
    try writeNative(init, recording, entry);
}

fn recordNativeMistral(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.providers.mistral.ConversationsProvider.init(api_key, recording.transport());
    var client = zigai.providers.mistral.ConversationsClient{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runNativeScenario(
        init,
        client.model(),
        &.{.{ .web_search = .{} }},
        native_google_prompt,
    );
    try writeNative(init, recording, entry);
}

fn recordNativeCohere(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.providers.cohere.ChatProvider.init(api_key, recording.transport());
    var client = zigai.providers.cohere.ChatClient{
        .model_name = entry.model,
        .provider = provider.provider(),
        .settings = .{ .extra_body = .{ .cohere = "{\"strict_tools\":true}" } },
    };
    try runScenario(init, client.model());
    try writeNative(init, recording, entry);
}

fn normalizeAzureUrl(
    allocator: std.mem.Allocator,
    recording: *cassettes.RecordingTransport,
    actual_base_url: []const u8,
) !void {
    for (recording.interactions.items) |*interaction| {
        if (!std.mem.startsWith(u8, interaction.request.url, actual_base_url)) return error.UnexpectedProviderUrl;
        const path = interaction.request.url[actual_base_url.len..];
        const normalized = try std.fmt.allocPrint(
            allocator,
            "https://example.openai.azure.com/openai/v1{s}",
            .{path},
        );
        allocator.free(interaction.request.url);
        interaction.request.url = normalized;
    }
}

fn normalizeBedrockRuntimeUrl(
    allocator: std.mem.Allocator,
    recording: *cassettes.RecordingTransport,
    actual_base_url: []const u8,
) !void {
    for (recording.interactions.items) |*interaction| {
        if (!std.mem.startsWith(u8, interaction.request.url, actual_base_url)) return error.UnexpectedProviderUrl;
        const path = interaction.request.url[actual_base_url.len..];
        const normalized = try std.fmt.allocPrint(
            allocator,
            "https://bedrock-runtime.example-region.amazonaws.com{s}",
            .{path},
        );
        allocator.free(interaction.request.url);
        interaction.request.url = normalized;
    }
}

fn recordRichOpenAI(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.openai.Provider.init(api_key, recording.transport());
    var client = zigai.openai.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runRichScenario(init, client.model());
    try writeRich(init, recording, entry);
}

fn recordRichAnthropic(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.anthropic.Provider.init(api_key, recording.transport());
    var client = zigai.anthropic.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
        .max_tokens = 64,
    };
    try runRichScenario(init, client.model());
    try writeRich(init, recording, entry);
}

fn recordRichGoogle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: manifest.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.google.Provider.init(api_key, recording.transport());
    var client = zigai.google.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runRichScenario(init, client.model());
    try writeRich(init, recording, entry);
}

fn runScenario(init: std.process.Init, model: zigai.Model) !void {
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    var result = try (zigai.Agent{
        .model = model,
        .tools = &.{tool},
        .system_prompt = system_prompt,
        .io = init.io,
        .limits = .{ .max_model_requests = 4, .max_tool_calls = 2 },
        .provider_error_observer = .{ .context = &calls, .observeFn = logProviderError },
    }).run(init.gpa, prompt);
    defer result.deinit();
    if (calls != 1 or result.output.len == 0) return error.UnexpectedModelBehavior;
}

fn runNativeScenario(
    init: std.process.Init,
    model: zigai.Model,
    tools: []const zigai.BuiltinTool,
    scenario_prompt: []const u8,
) !void {
    var result = try (zigai.Agent{
        .model = model,
        .builtin_tools = tools,
        .system_prompt = native_system_prompt,
        .io = init.io,
        .limits = .{ .max_model_requests = 2 },
    }).run(init.gpa, scenario_prompt);
    defer result.deinit();
    if (result.output.len == 0 or result.usage.totalTokens() == 0) return error.UnexpectedModelBehavior;
}

fn runRichScenario(init: std.process.Init, model: zigai.Model) !void {
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(pixel_png_base64);
    const image_bytes = try init.gpa.alloc(u8, decoded_size);
    defer init.gpa.free(image_bytes);
    try std.base64.standard.Decoder.decode(image_bytes, pixel_png_base64);
    const image = zigai.PromptPart{ .image = .{
        .source = .{ .bytes = image_bytes },
        .media_type = "image/png",
    } };
    var observer_context: u8 = 0;
    var result = try (zigai.Agent{
        .model = model,
        .io = init.io,
        .limits = .{ .max_model_requests = 1 },
        .provider_error_observer = .{ .context = &observer_context, .observeFn = logProviderError },
    }).runWithOptions(init.gpa, rich_prompt, .{ .prompt_parts = &.{image} });
    defer result.deinit();
    if (result.output.len == 0 or result.usage.totalTokens() == 0) return error.UnexpectedModelBehavior;
}

fn logProviderError(_: *anyopaque, value: zigai.model.ProviderError) void {
    std.log.err("{s} returned HTTP {d}: {s}", .{ value.provider, value.status, value.message });
}

fn weatherTool(calls: *u8) zigai.Tool {
    return .{
        .definition = .{
            .name = "weather",
            .description = "Get the current weather for a city.",
            .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
        },
        .context = calls,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                const count: *u8 = @ptrCast(@alignCast(context));
                count.* += 1;
                const parsed = try std.json.parseFromSliceLeaky(
                    struct { city: []const u8 },
                    allocator,
                    arguments,
                    .{ .ignore_unknown_fields = false },
                );
                if (!std.mem.eql(u8, parsed.city, "Madrid")) return error.UnexpectedCity;
                return allocator.dupe(u8, "{\"temperature_c\":31,\"condition\":\"sunny\"}");
            }
        }.execute,
    };
}

fn write(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: manifest.Entry,
    provider: []const u8,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} -> {s}", .{ provider, entry.model, path });
}

fn writeNative(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: manifest.Entry,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} native tools -> {s}", .{ entry.provider, entry.model, path });
}

fn writeRich(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: manifest.Entry,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} rich content -> {s}", .{ entry.provider, entry.model, path });
}

fn writeFileLifecycle(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    provider: []const u8,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/cassettes/files/{s}.yaml", .{provider});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} file lifecycle -> {s}", .{ provider, path });
}
