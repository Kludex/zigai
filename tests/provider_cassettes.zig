const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("support/cassettes.zig");

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
    try std.testing.expectError(error.InvalidProviderResponse, openai.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
    try std.testing.expectError(error.InvalidProviderResponse, anthropic.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
    state.mode = .empty_tool;
    const response = try anthropic.model().stream(arena.allocator(), .{ .messages = &.{} }, sink);
    try std.testing.expectEqualStrings("{}", response.parts[0].tool_call.arguments_json);
    state.mode = .invalid_compatible_tool;
    try std.testing.expectError(error.InvalidProviderResponse, compatible.model().stream(arena.allocator(), .{ .messages = &.{} }, sink));
}
