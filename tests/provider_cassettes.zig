const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("support/cassettes.zig");
const model_matrix = @import("support/model_matrix.zig");

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
    inline for (model_matrix.openai) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var client = zigai.openai.Client{
            .model_name = entry.model,
            .api_key = "not-recorded",
            .transport = cassette.transport(),
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real Anthropic model cassettes replay complete tool loops" {
    inline for (model_matrix.anthropic) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var client = zigai.anthropic.Client{
            .model_name = entry.model,
            .api_key = "not-recorded",
            .transport = cassette.transport(),
            .max_tokens = 128,
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real Google model cassettes replay complete tool loops" {
    inline for (model_matrix.google) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        var client = zigai.google.Client{
            .model_name = entry.model,
            .api_key = "not-recorded",
            .transport = cassette.transport(),
        };
        try replayMatrixScenario(client.model(), &cassette);
    }
}

test "real OpenAI-compatible provider cassettes replay text responses" {
    inline for (model_matrix.compatible) |entry| {
        var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile(entry.cassette));
        defer cassette.deinit();
        const base_url = switch (entry.endpoint) {
            .fixed => entry.base_url,
            .azure_openai => "https://example.openai.azure.com/openai/v1",
            .bedrock => "https://bedrock-mantle.example-region.api.aws/v1",
        };
        var client = zigai.providers.openai_compatible.Client{
            .model_name = entry.model,
            .api_key = "not-recorded",
            .transport = cassette.transport(),
            .base_url = base_url,
            .provider_name = entry.provider,
            .authentication = if (entry.api_key_header)
                .{ .header = "api-key", .prefix = "" }
            else
                .{},
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
}

test "real OpenAI cassette replays native web search" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/native/openai_web_search.yaml"));
    defer cassette.deinit();
    var client = zigai.openai.Client{
        .model_name = "gpt-5-nano",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
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
    var client = zigai.anthropic.Client{
        .model_name = "claude-sonnet-4-6",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
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
    var client = zigai.google.Client{
        .model_name = "gemini-3.5-flash",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
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
    var client = zigai.openai.Client{
        .model_name = "gpt-5-nano",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
    };
    try replayRichScenario(client.model(), &cassette);
}

test "real Anthropic cassette replays image input" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/rich/anthropic_image.yaml"));
    defer cassette.deinit();
    var client = zigai.anthropic.Client{
        .model_name = "claude-sonnet-4-6",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .max_tokens = 64,
    };
    try replayRichScenario(client.model(), &cassette);
}

test "real Google cassette replays image input" {
    var cassette = try cassettes.ReplayTransport.init(std.testing.allocator, @embedFile("cassettes/rich/google_image.yaml"));
    defer cassette.deinit();
    var client = zigai.google.Client{
        .model_name = "gemini-3.5-flash",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
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
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://openai.test/v1",
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
    var client = zigai.anthropic.Client{
        .model_name = "claude-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .max_tokens = 256,
        .base_url = "https://anthropic.test/v1",
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
    var client = zigai.google.Client{
        .model_name = "gemini-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://google.test/v1beta",
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
    var client = zigai.openai_compatible.Client{
        .model_name = "compat-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://compatible.test/v1",
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
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://openai.test/v1",
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
                    .text_delta => self.text_deltas += 1,
                    .tool_call_delta => self.argument_deltas += 1,
                    .tool_call => self.completed_calls += 1,
                    .usage => self.usage_events += 1,
                },
                .tool_result => self.tool_results += 1,
                .final_output => self.finals += 1,
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
    var client = zigai.anthropic.Client{
        .model_name = "claude-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .max_tokens = 256,
        .base_url = "https://anthropic.test/v1",
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
                    .text_delta => self.text += 1,
                    .tool_call_delta => self.arguments += 1,
                    .tool_call => self.calls += 1,
                    .usage => self.usage += 1,
                },
                .tool_result => self.results += 1,
                .final_output => self.finals += 1,
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
    var client = zigai.google.Client{
        .model_name = "gemini-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://google.test/v1beta",
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
                    .text_delta => self.text += 1,
                    .tool_call => self.calls += 1,
                    .usage => self.usage += 1,
                    .tool_call_delta => return error.UnexpectedGeminiDelta,
                },
                .tool_result => self.results += 1,
                .final_output => self.finals += 1,
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
    var client = zigai.openai_compatible.Client{
        .model_name = "compat-test",
        .api_key = "not-recorded",
        .transport = cassette.transport(),
        .base_url = "https://compatible.test/v1",
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
                    .text_delta => self.text += 1,
                    .tool_call_delta => self.deltas += 1,
                    .tool_call => self.calls += 1,
                    .usage => self.usage += 1,
                },
                .tool_result => self.results += 1,
                .final_output => self.finals += 1,
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
    var client = zigai.openai.Client{
        .model_name = "gpt-test",
        .api_key = "test",
        .transport = .{ .context = &unused, .sendFn = Stub.send },
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
    var anthropic = zigai.anthropic.Client{ .model_name = "claude-test", .api_key = "test", .transport = transport };
    var google = zigai.google.Client{ .model_name = "gemini-test", .api_key = "test", .transport = transport };
    var compatible = zigai.openai_compatible.Client{ .model_name = "compat-test", .api_key = "test", .transport = transport, .base_url = "https://compatible.test/v1" };
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
    var openai = zigai.openai.Client{ .model_name = "test", .api_key = "test", .transport = transport };
    var anthropic = zigai.anthropic.Client{ .model_name = "test", .api_key = "test", .transport = transport };
    var google = zigai.google.Client{ .model_name = "test", .api_key = "test", .transport = transport };
    var compatible = zigai.openai_compatible.Client{ .model_name = "test", .api_key = "test", .transport = transport, .base_url = "https://compatible.test/v1" };
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
    var openai = zigai.openai.Client{ .model_name = "test", .api_key = "test", .transport = transport };
    var anthropic = zigai.anthropic.Client{ .model_name = "test", .api_key = "test", .transport = transport };
    var compatible = zigai.openai_compatible.Client{ .model_name = "test", .api_key = "test", .transport = transport, .base_url = "https://compatible.test/v1" };
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
