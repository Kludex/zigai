const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("support/cassettes.zig");
const cassette_manifest = @import("support/cassette_manifest.zig");
const output_scenarios = @import("support/output_scenarios.zig");
const stream_scenarios = @import("support/stream_scenarios.zig");

const matrix_prompt = "Call the weather tool exactly once with city Madrid. Then reply with one short sentence.";
const matrix_system_prompt = "Always use the weather tool before answering.";
const native_prompt = "Use the available web tools to read https://ziglang.org and answer with the site's main heading in one short sentence.";
const native_google_prompt = "Use Google Search to identify the current stable Zig release. Answer in one short sentence.";
const native_system_prompt = "Use the available provider-managed web tool before answering.";
const rich_prompt = "Name the single dominant color in this image. Answer with one word.";
const pixel_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=";

const weather_definition: zigai.model.ToolDefinition = .{
    .name = "weather",
    .description = "Get weather.",
    .parameters_json_schema = "{\"type\":\"object\"}",
};

fn weatherTool(state: *u8) zigai.Tool {
    return .{
        .definition = weather_definition,
        .context = state,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                const calls: *u8 = @ptrCast(@alignCast(context));
                calls.* += 1;
                try std.testing.expectEqualStrings("{\"city\":\"Madrid\"}", arguments);
                return allocator.dupe(u8, "{\"temperature_c\":31}");
            }
        }.execute,
    };
}

fn matrixWeatherTool(state: *u8) zigai.Tool {
    return .{
        .definition = .{
            .name = "weather",
            .description = "Get the current weather for a city.",
            .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
        },
        .context = state,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                const calls: *u8 = @ptrCast(@alignCast(context));
                calls.* += 1;
                const parsed = try std.json.parseFromSliceLeaky(
                    struct { city: []const u8 },
                    allocator,
                    arguments,
                    .{ .ignore_unknown_fields = false },
                );
                try std.testing.expectEqualStrings("Madrid", parsed.city);
                return allocator.dupe(u8, "{\"temperature_c\":31,\"condition\":\"sunny\"}");
            }
        }.execute,
    };
}

test "real OpenAI model cassettes replay complete tool loops" {
    inline for (cassette_manifest.openai) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
        var client = zigai.openai.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real Anthropic model cassettes replay complete tool loops" {
    inline for (cassette_manifest.anthropic) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
            .max_tokens = 128,
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real Google model cassettes replay complete tool loops" {
    inline for (cassette_manifest.google) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
        var client = zigai.google.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real OpenAI model cassettes replay buffered text" {
    inline for (cassette_manifest.openai_buffered) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
        var client = zigai.openai.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
        };
        try replayBufferedScenario(client.model(), &cassette);
    }
}

test "real Anthropic model cassettes replay buffered text" {
    inline for (cassette_manifest.anthropic_buffered) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
            .max_tokens = 128,
        };
        try replayBufferedScenario(client.model(), &cassette);
    }
}

test "real Google model cassettes replay buffered text" {
    inline for (cassette_manifest.google_buffered) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
        var client = zigai.google.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
        };
        try replayBufferedScenario(client.model(), &cassette);
    }
}

test "real OpenAI model cassettes replay streamed text" {
    inline for (cassette_manifest.openai_streamed_text) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
        var client = zigai.openai.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayStreamTextScenario(client.model(), &cassette);
    }
}

test "real Anthropic model cassettes replay streamed text" {
    inline for (cassette_manifest.anthropic_streamed_text) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
            .max_tokens = 128,
        };
        try replayStreamTextScenario(client.model(), &cassette);
    }
}

test "real Google model cassettes replay streamed text" {
    inline for (cassette_manifest.google_streamed_text) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
        var client = zigai.google.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayStreamTextScenario(client.model(), &cassette);
    }
}

test "real OpenAI model cassettes replay streamed function tools" {
    inline for (cassette_manifest.openai_streamed_tools) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
        var client = zigai.openai.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayStreamToolScenario(client.model(), &cassette);
    }
}

test "real Anthropic model cassettes replay streamed function tools" {
    inline for (cassette_manifest.anthropic_streamed_tools) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
            .max_tokens = 128,
        };
        try replayStreamToolScenario(client.model(), &cassette);
    }
}

test "real Google model cassettes replay streamed function tools" {
    inline for (cassette_manifest.google_streamed_tools) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
        var client = zigai.google.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayStreamToolScenario(client.model(), &cassette);
    }
}

test "real OpenAI capability cassettes replay structured output and thinking" {
    inline for (cassette_manifest.openai_capabilities) |entry| {
        const fixture = @embedFile(entry.cassette);
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, fixture);
        defer cassette.deinit();
        var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
        var client = zigai.openai.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayCapabilityScenario(client.model(), &cassette, entry.scenario, false);
        try expectCapabilityWire(.openai, entry.scenario, fixture);
    }
}

test "real Anthropic capability cassettes replay structured output and thinking" {
    inline for (cassette_manifest.anthropic_capabilities) |entry| {
        const fixture = @embedFile(entry.cassette);
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, fixture);
        defer cassette.deinit();
        var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .provider = provider_state.provider(),
        };
        try replayCapabilityScenario(client.model(), &cassette, entry.scenario, true);
        try expectCapabilityWire(.anthropic, entry.scenario, fixture);
    }
}

test "real Google capability cassettes replay structured output and thinking" {
    inline for (cassette_manifest.google_capabilities) |entry| {
        const fixture = @embedFile(entry.cassette);
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, fixture);
        defer cassette.deinit();
        var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
        var client = zigai.google.Client{ .model_name = entry.model, .provider = provider_state.provider() };
        try replayCapabilityScenario(client.model(), &cassette, entry.scenario, false);
        try expectCapabilityWire(.google, entry.scenario, fixture);
    }
}

test "real OpenAI-compatible provider cassettes replay text responses" {
    inline for (cassette_manifest.compatible) |entry| {
        if (comptime std.mem.eql(u8, entry.provider, "azure-openai"))
            try replayCompatibleProvider(zigai.providers.azure_openai.Provider, zigai.providers.azure_openai.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "bedrock"))
            try replayCompatibleProvider(zigai.providers.bedrock.MantleProvider, zigai.providers.bedrock.MantleClient, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "cerebras"))
            try replayCompatibleProvider(zigai.providers.cerebras.Provider, zigai.providers.cerebras.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "cohere"))
            try replayCompatibleProvider(zigai.providers.cohere.Provider, zigai.providers.cohere.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "deepseek"))
            try replayCompatibleProvider(zigai.providers.deepseek.Provider, zigai.providers.deepseek.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "doubleword"))
            try replayCompatibleProvider(zigai.providers.doubleword.Provider, zigai.providers.doubleword.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "groq"))
            try replayCompatibleProvider(zigai.providers.groq.Provider, zigai.providers.groq.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "huggingface"))
            try replayCompatibleProvider(zigai.providers.huggingface.Provider, zigai.providers.huggingface.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "mistral"))
            try replayCompatibleProvider(zigai.providers.mistral.Provider, zigai.providers.mistral.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "openrouter"))
            try replayCompatibleProvider(zigai.providers.openrouter.Provider, zigai.providers.openrouter.Client, entry)
        else if (comptime std.mem.eql(u8, entry.provider, "together"))
            try replayCompatibleProvider(zigai.providers.together.Provider, zigai.providers.together.Client, entry)
        else
            @compileError("compatible cassette has no named provider client: " ++ entry.provider);
    }
}

test "real Bedrock Converse cassette replays a complete tool loop" {
    var cassette = try cassettes.ReplayTransport.init(
        std.testing.allocator,
        @embedFile("cassettes/native/bedrock_converse_claude_sonnet_4_6.yaml"),
    );
    defer cassette.deinit();
    var provider_state = try zigai.providers.bedrock.Provider.initWithOptions(
        "not-recorded",
        "example-region",
        cassette.transport(),
        .{ .base_url = "https://bedrock-runtime.example-region.amazonaws.com" },
    );
    var client = zigai.providers.bedrock.Client{
        .model_name = "us.anthropic.claude-sonnet-4-6",
        .provider = provider_state.provider(),
    };
    try replayMatrixScenario(client.model(), &cassette);
}

test "real Azure Responses cassette replays a complete tool loop" {
    var cassette = try cassettes.ReplayTransport.init(
        std.testing.allocator,
        @embedFile("cassettes/native/azure_responses_gpt_4o.yaml"),
    );
    defer cassette.deinit();
    var provider_state = zigai.providers.azure_openai.Provider.initWithOptions(
        "not-recorded",
        cassette.transport(),
        .{ .base_url = "https://example.openai.azure.com/openai/v1" },
    );
    var client = zigai.providers.azure_openai.ResponsesClient{
        .model_name = "gpt-4o",
        .provider = provider_state.provider(),
    };
    try replayMatrixScenario(client.model(), &cassette);
}

test "real Mistral Conversations cassette replays native web search" {
    var cassette = try cassettes.ReplayTransport.init(
        std.testing.allocator,
        @embedFile("cassettes/native/mistral_conversations_web_search.yaml"),
    );
    defer cassette.deinit();
    var provider_state = zigai.providers.mistral.ConversationsProvider.init("not-recorded", cassette.transport());
    var client = zigai.providers.mistral.ConversationsClient{
        .model_name = "mistral-small-latest",
        .provider = provider_state.provider(),
    };
    try replayNativeScenario(
        client.model(),
        &cassette,
        &.{.{ .web_search = .{} }},
        native_google_prompt,
    );
}

test "real Cohere v2 cassette replays a complete tool loop" {
    var cassette = try cassettes.ReplayTransport.init(
        std.testing.allocator,
        @embedFile("cassettes/native/cohere_v2_command_a.yaml"),
    );
    defer cassette.deinit();
    var provider_state = zigai.providers.cohere.ChatProvider.init("not-recorded", cassette.transport());
    var client = zigai.providers.cohere.ChatClient{
        .model_name = "command-a-03-2025",
        .provider = provider_state.provider(),
        .settings = .{ .extra_body = .{ .cohere = "{\"strict_tools\":true}" } },
    };
    try replayMatrixScenario(client.model(), &cassette);
}

fn replayCompatibleProvider(
    comptime ProviderType: type,
    comptime ClientType: type,
    comptime entry: cassette_manifest.Entry,
) !void {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
    defer cassette.deinit();
    const base_url = switch (entry.endpoint) {
        .fixed => entry.base_url,
        .azure_openai => "https://example.openai.azure.com/openai/v1",
        .bedrock => "https://bedrock-mantle.example-region.api.aws/v1",
    };
    var provider_state = ProviderType.initWithOptions("not-recorded", cassette.transport(), .{ .base_url = base_url });
    var client = ClientType{
        .model_name = entry.model,
        .provider = provider_state.provider(),
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 1 },
    }).run(std.testing.allocator, "Reply with exactly: pong");
    defer result.deinit();
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.usage.totalTokens() > 0);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayBufferedScenario(model: zigai.Model, cassette: *cassettes.ReplayTransport) !void {
    var result = try (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 2 },
    }).run(std.testing.allocator, "Reply with exactly: pong");
    defer result.deinit();
    try std.testing.expectEqualStrings("pong", result.output);
    try std.testing.expect(result.usage.totalTokens() > 0);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayStreamTextScenario(model: zigai.Model, cassette: *cassettes.ReplayTransport) !void {
    var capture: stream_scenarios.Capture = .{};
    var result = try (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 2 },
    }).runStream(std.testing.allocator, stream_scenarios.text_prompt, capture.sink());
    defer result.deinit();
    try capture.validateText(result.output, result.usage);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayStreamToolScenario(model: zigai.Model, cassette: *cassettes.ReplayTransport) !void {
    var tool_calls: u8 = 0;
    const tool = stream_scenarios.weatherTool(&tool_calls);
    var capture: stream_scenarios.Capture = .{};
    var result = try (zigai.Agent{
        .model = model,
        .tools = &.{tool},
        .system_prompt = stream_scenarios.tool_system_prompt,
        .model_settings = .{ .max_tokens = 1024 },
        .limits = .{ .max_model_requests = 4, .max_tool_calls = 2 },
    }).runStream(std.testing.allocator, stream_scenarios.tool_prompt, capture.sink());
    defer result.deinit();
    try capture.validateTool(result.output, result.usage, tool_calls);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayCapabilityScenario(
    model: zigai.Model,
    cassette: *cassettes.ReplayTransport,
    scenario: cassette_manifest.Scenario,
    require_thinking_parts: bool,
) !void {
    switch (scenario) {
        .structured_output => try output_scenarios.runStructured(std.testing.allocator, null, model),
        .thinking => try output_scenarios.runThinking(
            std.testing.allocator,
            null,
            model,
            require_thinking_parts,
        ),
        else => return error.UnexpectedCapabilityScenario,
    }
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

const FirstPartyProvider = enum { openai, anthropic, google };

fn expectCapabilityWire(
    provider: FirstPartyProvider,
    scenario: cassette_manifest.Scenario,
    fixture: []const u8,
) !void {
    const needles: []const []const u8 = switch (scenario) {
        .structured_output => switch (provider) {
            .openai => &.{ "text:", "format:", "type: \"json_schema\"", "strict: true" },
            .anthropic => &.{ "output_config:", "format:", "type: \"json_schema\"" },
            .google => &.{ "generationConfig:", "responseMimeType: \"application/json\"", "responseJsonSchema:" },
        },
        .thinking => switch (provider) {
            .openai => &.{ "reasoning:", "effort: \"high\"", "\"reasoning_tokens\":" },
            .anthropic => &.{ "output_config:", "effort: \"high\"", "type\":\"thinking\"" },
            .google => &.{ "thinkingConfig:", "thinkingLevel: \"HIGH\"", "\"thoughtsTokenCount\":" },
        },
        else => return error.UnexpectedCapabilityScenario,
    };
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, fixture, needle) != null);
}

test "real OpenAI cassette replays native web search" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/native/openai_web_search.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
    var client = zigai.openai.Client{
        .model_name = "gpt-5-nano",
        .provider = provider_state.provider(),
    };
    try replayNativeScenario(
        client.model(),
        &cassette,
        &.{.{ .web_search = .{} }},
        native_prompt,
    );
}

test "real Anthropic cassette replays native web search and fetch" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/native/anthropic_web_search_fetch.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
    var client = zigai.anthropic.Client{
        .model_name = "claude-sonnet-4-6",
        .provider = provider_state.provider(),
        .max_tokens = 256,
    };
    try replayNativeScenario(
        client.model(),
        &cassette,
        &.{ .{ .web_search = .{} }, .{ .web_fetch = .{} } },
        native_prompt,
    );
}

test "real Google cassette replays native web search and fetch" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/native/google_web_search_fetch.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
    var client = zigai.google.Client{
        .model_name = "gemini-3.5-flash",
        .provider = provider_state.provider(),
    };
    try replayNativeScenario(
        client.model(),
        &cassette,
        &.{ .{ .web_search = .{} }, .{ .web_fetch = .{} } },
        native_google_prompt,
    );
}

test "real OpenAI cassette replays image input" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/rich/openai_image.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai.Provider.init("not-recorded", cassette.transport());
    var client = zigai.openai.Client{
        .model_name = "gpt-5-nano",
        .provider = provider_state.provider(),
    };
    try replayRichScenario(client.model(), &cassette);
}

test "real Anthropic cassette replays image input" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/rich/anthropic_image.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.anthropic.Provider.init("not-recorded", cassette.transport());
    var client = zigai.anthropic.Client{
        .model_name = "claude-sonnet-4-6",
        .provider = provider_state.provider(),
        .max_tokens = 64,
    };
    try replayRichScenario(client.model(), &cassette);
}

test "real Google cassette replays image input" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/rich/google_image.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.google.Provider.init("not-recorded", cassette.transport());
    var client = zigai.google.Client{
        .model_name = "gemini-3.5-flash",
        .provider = provider_state.provider(),
    };
    try replayRichScenario(client.model(), &cassette);
}

fn replayMatrixScenario(model: zigai.Model, cassette: *cassettes.ReplayTransport) !void {
    var calls: u8 = 0;
    const tool = matrixWeatherTool(&calls);
    var result = try (zigai.Agent{
        .model = model,
        .tools = &.{tool},
        .system_prompt = matrix_system_prompt,
        .limits = .{ .max_model_requests = 4, .max_tool_calls = 2 },
    }).run(std.testing.allocator, matrix_prompt);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.usage.totalTokens() > 0);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayNativeScenario(
    model: zigai.Model,
    cassette: *cassettes.ReplayTransport,
    builtin_tools: []const zigai.BuiltinTool,
    prompt: []const u8,
) !void {
    var result = try (zigai.Agent{
        .model = model,
        .builtin_tools = builtin_tools,
        .system_prompt = native_system_prompt,
        .limits = .{ .max_model_requests = 2 },
    }).run(std.testing.allocator, prompt);
    defer result.deinit();
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.usage.totalTokens() > 0);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

fn replayRichScenario(model: zigai.Model, cassette: *cassettes.ReplayTransport) !void {
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(pixel_png_base64);
    const image_bytes = try std.testing.allocator.alloc(u8, decoded_size);
    defer std.testing.allocator.free(image_bytes);
    try std.base64.standard.Decoder.decode(image_bytes, pixel_png_base64);
    const image = zigai.PromptPart{ .image = .{
        .source = .{ .bytes = image_bytes },
        .media_type = "image/png",
    } };
    var result = try (zigai.Agent{
        .model = model,
        .limits = .{ .max_model_requests = 1 },
    }).runWithOptions(std.testing.allocator, rich_prompt, .{ .prompt_parts = &.{image} });
    defer result.deinit();
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.usage.totalTokens() > 0);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "OpenAI cassette covers the complete agent tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/openai_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://openai.test/v1",
    });
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).run(std.testing.allocator, "What is the weather?");
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expectEqual(@as(u64, 28), result.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "Anthropic cassette covers the complete agent tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/anthropic_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.anthropic.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://anthropic.test/v1",
    });
    var client = zigai.anthropic.Client{
        .model_name = "claude-test",
        .provider = provider_state.provider(),
        .max_tokens = 256,
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).run(std.testing.allocator, "What is the weather?");
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expectEqual(@as(u64, 28), result.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "Google cassette covers the complete agent tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/google_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.google.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://google.test/v1beta",
    });
    var client = zigai.google.Client{
        .model_name = "gemini-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).run(std.testing.allocator, "What is the weather?");
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expectEqual(@as(u64, 28), result.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "OpenAI-compatible cassette covers the complete Chat Completions tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/openai_compatible_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai_compatible.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://compatible.test/v1",
    });
    var client = zigai.openai_compatible.Client{
        .model_name = "compat-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).run(std.testing.allocator, "What is the weather?");
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expectEqual(@as(u64, 28), result.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "OpenAI streaming cassette covers deltas and the complete agent tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/openai_stream_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://openai.test/v1",
    });
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    const Capture = struct {
        text_deltas: usize = 0,
        argument_deltas: usize = 0,
        completed_calls: usize = 0,
        tool_results: usize = 0,
        usage_events: usize = 0,
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => |model_event| switch (model_event) {
                    .part_delta => |part_event| switch (part_event.delta) {
                        .text => self.text_deltas += 1,
                        .tool_call => self.argument_deltas += 1,
                        else => {},
                    },
                    .part_end => |part_event| switch (part_event.part) {
                        .tool_call => self.completed_calls += 1,
                        else => {},
                    },
                    .part_start => {},
                    .usage => self.usage_events += 1,
                },
                .function_tool_result => self.tool_results += 1,
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).runStream(std.testing.allocator, "What is the weather?", .{ .context = &capture, .eventFn = Capture.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(usize, 2), capture.text_deltas);
    try std.testing.expectEqual(@as(usize, 1), capture.argument_deltas);
    try std.testing.expectEqual(@as(usize, 1), capture.completed_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_results);
    try std.testing.expectEqual(@as(usize, 2), capture.usage_events);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "Anthropic streaming cassette covers fragmented tools and text" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/anthropic_stream_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.anthropic.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://anthropic.test/v1",
    });
    var client = zigai.anthropic.Client{
        .model_name = "claude-test",
        .provider = provider_state.provider(),
        .max_tokens = 256,
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    const Capture = struct {
        text: usize = 0,
        arguments: usize = 0,
        calls: usize = 0,
        results: usize = 0,
        usage: usize = 0,
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => |item| switch (item) {
                    .part_delta => |part_event| switch (part_event.delta) {
                        .text => self.text += 1,
                        .tool_call => self.arguments += 1,
                        else => {},
                    },
                    .part_end => |part_event| switch (part_event.part) {
                        .tool_call => self.calls += 1,
                        else => {},
                    },
                    .part_start => {},
                    .usage => self.usage += 1,
                },
                .function_tool_result => self.results += 1,
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).runStream(std.testing.allocator, "What is the weather?", .{ .context = &capture, .eventFn = Capture.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(usize, 2), capture.text);
    try std.testing.expectEqual(@as(usize, 2), capture.arguments);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.results);
    try std.testing.expectEqual(@as(usize, 2), capture.usage);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "Google streaming cassette covers chunked text and the tool loop" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/google_stream_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.google.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://google.test/v1beta",
    });
    var client = zigai.google.Client{
        .model_name = "gemini-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    const Capture = struct {
        text: usize = 0,
        calls: usize = 0,
        results: usize = 0,
        usage: usize = 0,
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => |item| switch (item) {
                    .part_delta => |part_event| switch (part_event.delta) {
                        .text => self.text += 1,
                        .tool_call => return error.UnexpectedGeminiDelta,
                        else => {},
                    },
                    .part_end => |part_event| switch (part_event.part) {
                        .tool_call => self.calls += 1,
                        else => {},
                    },
                    .part_start => {},
                    .usage => self.usage += 1,
                },
                .function_tool_result => self.results += 1,
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).runStream(std.testing.allocator, "What is the weather?", .{ .context = &capture, .eventFn = Capture.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(usize, 2), capture.text);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.results);
    try std.testing.expectEqual(@as(usize, 3), capture.usage);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "OpenAI-compatible streaming cassette covers fragmented Chat Completions tools" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/openai_compatible_stream_tool_loop.yaml"));
    defer cassette.deinit();
    var provider_state = zigai.openai_compatible.Provider.initWithOptions("not-recorded", cassette.transport(), .{
        .base_url = "https://compatible.test/v1",
    });
    var client = zigai.openai_compatible.Client{
        .model_name = "compat-test",
        .provider = provider_state.provider(),
    };
    var calls: u8 = 0;
    const tool = weatherTool(&calls);
    const Capture = struct {
        text: usize = 0,
        deltas: usize = 0,
        calls: usize = 0,
        results: usize = 0,
        usage: usize = 0,
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => |item| switch (item) {
                    .part_delta => |part_event| switch (part_event.delta) {
                        .text => self.text += 1,
                        .tool_call => self.deltas += 1,
                        else => {},
                    },
                    .part_end => |part_event| switch (part_event.part) {
                        .tool_call => self.calls += 1,
                        else => {},
                    },
                    .part_start => {},
                    .usage => self.usage += 1,
                },
                .function_tool_result => self.results += 1,
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &.{tool},
        .system_prompt = "You are concise.",
    }).runStream(std.testing.allocator, "What is the weather?", .{ .context = &capture, .eventFn = Capture.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(usize, 2), capture.text);
    try std.testing.expectEqual(@as(usize, 2), capture.deltas);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.results);
    try std.testing.expectEqual(@as(usize, 2), capture.usage);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}

test "OpenAI client exposes stable rate-limit classification" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return .{ .status = 429, .body = try allocator.dupe(u8, "{\"error\":{}}") };
        }
    };
    var unused: u8 = 0;
    var provider_state = zigai.openai.Provider.init("test", .{ .context = &unused, .sendFn = Stub.send });
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Capture = struct {
        fn observe(context: *anyopaque, value: zigai.model.ProviderError) void {
            const called: *bool = @ptrCast(@alignCast(context));
            called.* = value.status == 429 and std.mem.eql(u8, value.provider, "openai");
        }
    };
    var called = false;
    try std.testing.expectError(
        error.ProviderRateLimited,
        client.model().request(arena.allocator(), .{
            .messages = &.{},
            .error_observer = .{ .context = &called, .observeFn = Capture.observe },
        }),
    );
    try std.testing.expect(called);
}

test "agent provider error bodies are hidden by default and bounded when enabled" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return .{
                .status = 400,
                .body = try allocator.dupe(u8, "{\"error\":{\"code\":\"bad_request\",\"message\":\"secret-message\"}}"),
            };
        }
    };
    const Capture = struct {
        body: [5]u8 = undefined,
        body_len: usize = 0,
        truncated: bool = false,

        fn observe(context: *anyopaque, value: zigai.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.body_len = value.body.len;
            @memcpy(self.body[0..value.body.len], value.body);
            self.truncated = value.body_truncated;
        }
    };
    var unused: u8 = 0;
    const provider_transport = zigai.transport.Transport{ .context = &unused, .sendFn = Stub.send };
    var provider_state = zigai.openai.Provider.init("test", provider_transport);

    var hidden: Capture = .{};
    var hidden_client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    try std.testing.expectError(error.ProviderRequestFailed, (zigai.Agent{
        .model = hidden_client.model(),
        .provider_error_observer = .{ .context = &hidden, .observeFn = Capture.observe },
    }).run(std.testing.allocator, "fail"));
    try std.testing.expectEqual(@as(usize, 0), hidden.body_len);
    try std.testing.expect(!hidden.truncated);

    var captured: Capture = .{};
    var captured_client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    try std.testing.expectError(error.ProviderRequestFailed, (zigai.Agent{
        .model = captured_client.model(),
        .provider_error_observer = .{ .context = &captured, .observeFn = Capture.observe },
        .provider_error_policy = .{ .capture_body = true, .max_body_bytes = 5 },
    }).run(std.testing.allocator, "fail"));
    try std.testing.expectEqualStrings("{\"err", captured.body[0..captured.body_len]);
    try std.testing.expect(captured.truncated);
}

test "provider streaming preserves application callback errors" {
    const Stub = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return error.Unused;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.transport.Request,
            sink: zigai.transport.LineSink,
        ) !zigai.transport.StreamResponse {
            const response = zigai.transport.StreamResponse{ .status = 200 };
            try sink.start(response);
            try sink.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}");
            return response;
        }
    };
    const Sink = struct {
        fn emit(_: *anyopaque, _: zigai.ModelStreamEvent) !void {
            return error.ApplicationSinkFailed;
        }
    };
    var unused: u8 = 0;
    var provider_state = zigai.openai.Provider.init("test", .{ .context = &unused, .sendFn = Stub.send, .streamLinesFn = Stub.stream });
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ApplicationSinkFailed, client.model().stream(
        arena.allocator(),
        .{ .messages = &.{} },
        .{ .context = &unused, .eventFn = Sink.emit },
    ));
}

test "Anthropic, Google, and OpenAI-compatible clients classify server failures" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: zigai.transport.Request) !zigai.transport.Response {
            const body = if (std.mem.indexOf(u8, request.url, "google") != null)
                "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}"
            else
                "{\"error\":{}}";
            return .{ .status = 503, .body = try allocator.dupe(u8, body) };
        }
    };
    var unused: u8 = 0;
    const transport = zigai.transport.Transport{ .context = &unused, .sendFn = Stub.send };
    var anthropic_provider = zigai.anthropic.Provider.init("test", transport);
    var anthropic = zigai.anthropic.Client{ .model_name = "claude-test", .provider = anthropic_provider.provider() };
    var google_provider = zigai.google.Provider.init("test", transport);
    var google = zigai.google.Client{ .model_name = "gemini-test", .provider = google_provider.provider() };
    var compatible_provider = zigai.openai_compatible.Provider.initWithOptions("test", transport, .{ .base_url = "https://compatible.test/v1" });
    var compatible = zigai.openai_compatible.Client{ .model_name = "compat-test", .provider = compatible_provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ProviderServerError, anthropic.model().request(arena.allocator(), .{ .messages = &.{} }));
    try std.testing.expectError(error.ProviderServerError, google.model().request(arena.allocator(), .{ .messages = &.{} }));
    try std.testing.expectError(error.ProviderServerError, compatible.model().request(arena.allocator(), .{ .messages = &.{} }));
}

test "all streaming clients classify multiline server failures" {
    const Stub = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return error.Unused;
        }
        fn stream(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request, sink: zigai.transport.LineSink) !zigai.transport.StreamResponse {
            const response = zigai.transport.StreamResponse{ .status = 503 };
            try sink.start(response);
            try sink.line("{\"error\":");
            try sink.line("{\"message\":\"down\"}}");
            return response;
        }
        fn event(_: *anyopaque, _: zigai.model.ModelStreamEvent) !void {}
    };
    var unused: u8 = 0;
    const transport = zigai.transport.Transport{ .context = &unused, .sendFn = Stub.send, .streamLinesFn = Stub.stream };
    const sink = zigai.model.ModelStreamSink{ .context = &unused, .eventFn = Stub.event };
    var openai_provider = zigai.openai.Provider.init("test", transport);
    var openai = zigai.openai.Client{ .model_name = "test", .provider = openai_provider.provider() };
    var anthropic_provider = zigai.anthropic.Provider.init("test", transport);
    var anthropic = zigai.anthropic.Client{ .model_name = "test", .provider = anthropic_provider.provider() };
    var google_provider = zigai.google.Provider.init("test", transport);
    var google = zigai.google.Client{ .model_name = "test", .provider = google_provider.provider() };
    var compatible_provider = zigai.openai_compatible.Provider.initWithOptions("test", transport, .{ .base_url = "https://compatible.test/v1" });
    var compatible = zigai.openai_compatible.Client{ .model_name = "test", .provider = compatible_provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ openai.model(), anthropic.model(), google.model(), compatible.model() }) |model| {
        try std.testing.expectError(error.ProviderServerError, model.stream(arena.allocator(), .{ .messages = &.{} }, sink));
    }
}

test "streaming clients reject malformed events and Anthropic accepts empty tool input" {
    const State = struct {
        mode: enum { malformed, empty_tool, invalid_compatible_tool } = .malformed,
        fn send(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
            return error.Unused;
        }
        fn stream(context: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request, sink: zigai.transport.LineSink) !zigai.transport.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            const response = zigai.transport.StreamResponse{ .status = 200 };
            try sink.start(response);
            switch (self.mode) {
                .malformed => try sink.line("data: false"),
                .empty_tool => {
                    try sink.line("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}");
                    try sink.line("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"empty\"}}");
                    try sink.line("data: {\"type\":\"content_block_stop\",\"index\":0}");
                    try sink.line("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":1}}");
                },
                .invalid_compatible_tool => try sink.line("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":false}]}}]}"),
            }
            return response;
        }
        fn event(_: *anyopaque, _: zigai.model.ModelStreamEvent) !void {}
    };
    var state: State = .{};
    const transport = zigai.transport.Transport{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream };
    const sink = zigai.model.ModelStreamSink{ .context = &state, .eventFn = State.event };
    var openai_provider = zigai.openai.Provider.init("test", transport);
    var openai = zigai.openai.Client{ .model_name = "test", .provider = openai_provider.provider() };
    var anthropic_provider = zigai.anthropic.Provider.init("test", transport);
    var anthropic = zigai.anthropic.Client{ .model_name = "test", .provider = anthropic_provider.provider() };
    var compatible_provider = zigai.openai_compatible.Provider.initWithOptions("test", transport, .{ .base_url = "https://compatible.test/v1" });
    var compatible = zigai.openai_compatible.Client{ .model_name = "test", .provider = compatible_provider.provider() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ProviderResponseDecodeError, openai.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
    try std.testing.expectError(error.ProviderResponseDecodeError, anthropic.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
    state.mode = .empty_tool;
    const response = try anthropic.model().stream(arena.allocator(), .{ .messages = &.{} }, sink);
    try std.testing.expectEqualStrings("{}", response.parts[0].tool_call.arguments_json);
    state.mode = .invalid_compatible_tool;
    try std.testing.expectError(error.ProviderResponseDecodeError, compatible.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
}
test "real provider file cassettes replay each safe lifecycle" {
    const multipart = cassettes.MultipartFileFilter{};
    const fine_tune_body = "{\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"},{\"role\":\"assistant\",\"content\":\"Hello\"}]}\n";
    {
        var replay = try cassettes.ReplayTransport.initWithRequestFilters(
            std.testing.allocator,
            @embedFile("cassettes/files/openai.yaml"),
            .{ .body = multipart.bodyFilter() },
        );
        defer replay.deinit();
        var concrete = zigai.openai.Provider.init("fixture", replay.transport());
        const provider = concrete.provider();
        var uploaded = try provider.uploadFile(std.testing.allocator, .{
            .filename = "zigai-cassette.jsonl",
            .media_type = "text/plain",
            .bytes = fine_tune_body,
            .purpose = "fine-tune",
        });
        defer uploaded.deinit();
        const file = uploaded.value.uploadedFile();
        var inspected = try provider.inspectFile(std.testing.allocator, file);
        defer inspected.deinit();
        var downloaded = try provider.downloadFile(std.testing.allocator, file);
        defer downloaded.deinit();
        try std.testing.expect(downloaded.value.bytes.len > 0);
        try provider.deleteFile(std.testing.allocator, file);
        try std.testing.expectEqual(@as(usize, 0), replay.remaining());
    }
    {
        var replay = try cassettes.ReplayTransport.initWithRequestFilters(
            std.testing.allocator,
            @embedFile("cassettes/files/anthropic.yaml"),
            .{ .body = multipart.bodyFilter() },
        );
        defer replay.deinit();
        var concrete = zigai.anthropic.Provider.init("fixture", replay.transport());
        const provider = concrete.provider();
        var uploaded = try provider.uploadFile(std.testing.allocator, .{
            .filename = "zigai-cassette.txt",
            .media_type = "text/plain",
            .bytes = "fixture",
        });
        defer uploaded.deinit();
        try std.testing.expectEqual(@as(?bool, false), uploaded.value.downloadable);
        try std.testing.expect(std.mem.indexOf(u8, uploaded.value.metadata_json.?, "\"downloadable\":false") != null);
        const file = uploaded.value.uploadedFile();
        var inspected = try provider.inspectFile(std.testing.allocator, file);
        defer inspected.deinit();
        try provider.deleteFile(std.testing.allocator, file);
        try std.testing.expectEqual(@as(usize, 0), replay.remaining());
    }
    {
        const session_url = "https://generativelanguage.googleapis.com/upload/v1beta/files/REDACTED";
        const url_filter = cassettes.PrefixRedactionFilter{
            .prefix = "https://generativelanguage.googleapis.com/upload/v1beta/files?",
            .replacement = session_url,
        };
        const body_filter = cassettes.NonJsonBodyFilter{};
        var replay = try cassettes.ReplayTransport.initWithRequestFilters(
            std.testing.allocator,
            @embedFile("cassettes/files/google.yaml"),
            .{ .url = url_filter.bodyFilter(), .body = body_filter.bodyFilter() },
        );
        defer replay.deinit();
        var concrete = zigai.google.Provider.init("fixture", replay.transport());
        const provider = concrete.provider();
        var uploaded = try provider.uploadFile(std.testing.allocator, .{
            .filename = "zigai-cassette.txt",
            .media_type = "text/plain",
            .bytes = "fixture",
        });
        defer uploaded.deinit();
        const file = uploaded.value.uploadedFile();
        var inspected = try provider.inspectFile(std.testing.allocator, file);
        defer inspected.deinit();
        try provider.deleteFile(std.testing.allocator, file);
        try std.testing.expectEqual(@as(usize, 0), replay.remaining());
    }
}

test "real file cassettes contain only deterministic redacted upload data" {
    const openai = @embedFile("cassettes/files/openai.yaml");
    const anthropic = @embedFile("cassettes/files/anthropic.yaml");
    const google = @embedFile("cassettes/files/google.yaml");
    for ([_][]const u8{ openai, anthropic, google }) |cassette| {
        try std.testing.expect(std.mem.indexOf(u8, cassette, "[REDACTED FILE CONTENT]") != null);
        try std.testing.expect(std.mem.indexOf(u8, cassette, "ZigAI file cassette fixture") == null);
        try std.testing.expect(std.mem.indexOf(u8, cassette, "api-key") == null);
        try std.testing.expect(std.mem.indexOf(u8, cassette, "Bearer ") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, google, "files/REDACTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, google, "upload_id=") == null);
}
