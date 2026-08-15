//! Opt-in recorder for the real-provider model cassette matrix.

const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("support/cassettes.zig");
const matrix = @import("support/model_matrix.zig");

const prompt = "Call the weather tool exactly once with city Madrid. Then reply with one short sentence.";
const system_prompt = "Always use the weather tool before answering.";
const native_prompt = "Use the available web tools to read https://ziglang.org and answer with the site's main heading in one short sentence.";
const native_google_prompt = "Use Google Search to identify the current stable Zig release. Answer in one short sentence.";
const native_system_prompt = "Use the available provider-managed web tool before answering.";
const rich_prompt = "Name the single dominant color in this image. Answer with one word.";
const pixel_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=";

const NativeEntry = struct {
    provider: []const u8,
    model: []const u8,
    cassette: []const u8,
};

const native_openai = NativeEntry{
    .provider = "openai",
    .model = "gpt-5-nano",
    .cassette = "cassettes/native/openai_web_search.yaml",
};
const native_anthropic = NativeEntry{
    .provider = "anthropic",
    .model = "claude-sonnet-4-6",
    .cassette = "cassettes/native/anthropic_web_search_fetch.yaml",
};
const native_google = NativeEntry{
    .provider = "google",
    .model = "gemini-3.5-flash",
    .cassette = "cassettes/native/google_web_search_fetch.yaml",
};
const native_bedrock = NativeEntry{
    .provider = "bedrock",
    .model = "us.anthropic.claude-sonnet-4-6",
    .cassette = "cassettes/native/bedrock_converse_claude_sonnet_4_6.yaml",
};
const native_azure = NativeEntry{
    .provider = "azure-openai",
    .model = "gpt-4o",
    .cassette = "cassettes/native/azure_responses_gpt_4o.yaml",
};
const rich_openai = NativeEntry{
    .provider = "openai",
    .model = "gpt-5-nano",
    .cassette = "cassettes/rich/openai_image.yaml",
};
const rich_anthropic = NativeEntry{
    .provider = "anthropic",
    .model = "claude-sonnet-4-6",
    .cassette = "cassettes/rich/anthropic_image.yaml",
};
const rich_google = NativeEntry{
    .provider = "google",
    .model = "gemini-3.5-flash",
    .cassette = "cassettes/rich/google_image.yaml",
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const openai_key = requiredKey(init, "OPENAI_API_KEY");
    const anthropic_key = requiredKey(init, "ANTHROPIC_API_KEY");
    const google_key = init.environ_map.get("GOOGLE_API_KEY") orelse
        requiredKey(init, "GEMINI_API_KEY");

    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();

    for (matrix.openai) |entry| if (selected(args, "openai", entry.model)) {
        try recordOpenAI(init, http.transport(), openai_key, entry);
    };
    for (matrix.anthropic) |entry| if (selected(args, "anthropic", entry.model)) {
        try recordAnthropic(init, http.transport(), anthropic_key, entry);
    };
    for (matrix.google) |entry| if (selected(args, "google", entry.model)) {
        try recordGoogle(init, http.transport(), google_key, entry);
    };
    for (matrix.compatible) |entry| if (selected(args, entry.provider, entry.model)) {
        try recordCompatible(init, http.transport(), entry);
    };
    if (selectedNative(args, native_openai)) {
        try recordNativeOpenAI(init, http.transport(), openai_key, native_openai);
    }
    if (selectedNative(args, native_anthropic)) {
        try recordNativeAnthropic(init, http.transport(), anthropic_key, native_anthropic);
    }
    if (selectedNative(args, native_google)) {
        try recordNativeGoogle(init, http.transport(), google_key, native_google);
    }
    if (selectedNative(args, native_bedrock)) {
        try recordNativeBedrock(
            init,
            http.transport(),
            requiredKey(init, zigai.providers.bedrock.api_key_env),
            requiredKey(init, zigai.providers.bedrock.region_env),
            native_bedrock,
        );
    }
    if (selectedNative(args, native_azure)) {
        try recordNativeAzure(
            init,
            http.transport(),
            requiredKey(init, zigai.providers.azure_openai.api_key_env),
            requiredKey(init, zigai.providers.azure_openai.endpoint_env),
            native_azure,
        );
    }
    if (selectedRich(args, rich_openai)) {
        try recordRichOpenAI(init, http.transport(), openai_key, rich_openai);
    }
    if (selectedRich(args, rich_anthropic)) {
        try recordRichAnthropic(init, http.transport(), anthropic_key, rich_anthropic);
    }
    if (selectedRich(args, rich_google)) {
        try recordRichGoogle(init, http.transport(), google_key, rich_google);
    }
    if (selectedFiles(args, "openai")) {
        try recordOpenAIFileLifecycle(init, http.transport(), openai_key);
    }
    if (selectedFiles(args, "anthropic")) {
        try recordAnthropicFileLifecycle(init, http.transport(), anthropic_key);
    }
    if (selectedFiles(args, "google")) {
        try recordGoogleFileLifecycle(init, http.transport(), google_key);
    }
}

fn recordCompatible(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    entry: matrix.CompatibleEntry,
) !void {
    const api_key = requiredKey(init, entry.api_key_env);
    const base_url = switch (entry.endpoint) {
        .fixed => entry.base_url,
        .azure_openai => try zigai.providers.azure_openai.apiBase(
            init.gpa,
            requiredKey(init, zigai.providers.azure_openai.endpoint_env),
        ),
        .bedrock => try zigai.providers.bedrock.mantleApiBase(
            init.gpa,
            requiredKey(init, zigai.providers.bedrock.region_env),
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
    entry: matrix.CompatibleEntry,
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
        .limits = .{ .max_model_requests = 1 },
        .provider_error_observer = .{ .context = &observer_context, .observeFn = logProviderError },
    }).run(init.gpa, "Reply with exactly: pong");
    defer result.deinit();
    if (result.output.len == 0 or result.usage.totalTokens() == 0) return error.UnexpectedModelBehavior;
}

fn writeCompatible(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: matrix.CompatibleEntry,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} -> {s}", .{ entry.provider, entry.model, path });
}

fn requiredKey(init: std.process.Init, name: []const u8) []const u8 {
    const value = init.environ_map.get(name) orelse {
        std.log.err("{s} is not set", .{name});
        std.process.exit(1);
    };
    if (value.len == 0) {
        std.log.err("{s} is empty", .{name});
        std.process.exit(1);
    }
    return value;
}

fn selected(args: []const []const u8, provider: []const u8, model: []const u8) bool {
    if (args.len <= 1) return true;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, provider) or std.mem.eql(u8, argument, model)) return true;
    }
    return false;
}

fn selectedNative(args: []const []const u8, entry: NativeEntry) bool {
    if (args.len <= 1) return true;
    for (args[1..]) |argument| {
        const provider_filter =
            (std.mem.eql(u8, entry.provider, "openai") and std.mem.eql(u8, argument, "native-openai")) or
            (std.mem.eql(u8, entry.provider, "anthropic") and std.mem.eql(u8, argument, "native-anthropic")) or
            (std.mem.eql(u8, entry.provider, "google") and std.mem.eql(u8, argument, "native-google")) or
            (std.mem.eql(u8, entry.provider, "bedrock") and std.mem.eql(u8, argument, "native-bedrock")) or
            (std.mem.eql(u8, entry.provider, "azure-openai") and std.mem.eql(u8, argument, "native-azure"));
        if (std.mem.eql(u8, argument, "native-tools") or
            provider_filter or
            std.mem.eql(u8, argument, entry.provider) or
            std.mem.eql(u8, argument, entry.model))
        {
            return true;
        }
    }
    return false;
}

fn selectedRich(args: []const []const u8, entry: NativeEntry) bool {
    if (args.len <= 1) return true;
    for (args[1..]) |argument| {
        const provider_filter =
            (std.mem.eql(u8, entry.provider, "openai") and std.mem.eql(u8, argument, "rich-openai")) or
            (std.mem.eql(u8, entry.provider, "anthropic") and std.mem.eql(u8, argument, "rich-anthropic")) or
            (std.mem.eql(u8, entry.provider, "google") and std.mem.eql(u8, argument, "rich-google"));
        if (std.mem.eql(u8, argument, "rich-content") or
            provider_filter or
            std.mem.eql(u8, argument, entry.provider) or
            std.mem.eql(u8, argument, entry.model))
        {
            return true;
        }
    }
    return false;
}

fn selectedFiles(args: []const []const u8, provider: []const u8) bool {
    if (args.len <= 1) return true;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "files") or
            std.mem.eql(u8, argument, provider) or
            (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, argument, "files-openai")) or
            (std.mem.eql(u8, provider, "anthropic") and std.mem.eql(u8, argument, "files-anthropic")) or
            (std.mem.eql(u8, provider, "google") and std.mem.eql(u8, argument, "files-google")))
        {
            return true;
        }
    }
    return false;
}

fn recordOpenAI(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: matrix.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.openai.Provider.init(api_key, recording.transport());
    var client = zigai.openai.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runScenario(init, client.model());
    try write(init, recording, entry, "openai");
}

fn recordAnthropic(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: matrix.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.anthropic.Provider.init(api_key, recording.transport());
    var client = zigai.anthropic.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
        .max_tokens = 128,
    };
    try runScenario(init, client.model());
    try write(init, recording, entry, "anthropic");
}

fn recordGoogle(
    init: std.process.Init,
    transport: zigai.transport.Transport,
    api_key: []const u8,
    entry: matrix.Entry,
) !void {
    var recording = cassettes.RecordingTransport.init(init.gpa, transport);
    defer recording.deinit();
    var provider = zigai.google.Provider.init(api_key, recording.transport());
    var client = zigai.google.Client{
        .model_name = entry.model,
        .provider = provider.provider(),
    };
    try runScenario(init, client.model());
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: NativeEntry,
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
    entry: matrix.Entry,
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
    entry: NativeEntry,
) !void {
    const path = try std.fmt.allocPrint(init.gpa, "tests/{s}", .{entry.cassette});
    defer init.gpa.free(path);
    try recording.writeCassetteAtomic(init.gpa, init.io, .cwd(), path);
    std.log.info("recorded {s} {s} native tools -> {s}", .{ entry.provider, entry.model, path });
}

fn writeRich(
    init: std.process.Init,
    recording: cassettes.RecordingTransport,
    entry: NativeEntry,
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
