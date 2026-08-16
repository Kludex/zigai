//! Representative deterministic workloads for production-sensitive ZigAI paths.

const std = @import("std");
const harness = @import("harness");
const zigai = @import("zigai");

const openai_response =
    \\{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Madrid is sunny."}]},{"type":"function_call","call_id":"call_weather","name":"weather","arguments":"{\"city\":\"Madrid\"}"}],"usage":{"input_tokens":19,"input_tokens_details":{"cached_tokens":4},"output_tokens":8,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":27}}
;

const mcp_request =
    \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"zigai-benchmark","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
;

const request_messages = [_]zigai.Message{
    .{ .request = .{ .parts = &.{
        .{ .system_prompt = "Answer accurately and briefly." },
        .{ .user_prompt = .{ .text = "What is the weather in Madrid?" } },
    } } },
    .{ .response = .{ .parts = &.{
        .{ .text = "I will check the weather." },
        .{ .tool_call = .{
            .id = "call_weather",
            .name = "weather",
            .arguments_json = "{\"city\":\"Madrid\"}",
        } },
    } } },
    .{ .request = .{ .parts = &.{.{ .tool_return = .{
        .call_id = "call_weather",
        .name = "weather",
        .content = "{\"temperature_c\":27,\"condition\":\"sunny\"}",
    } }} } },
};

const history_messages = request_messages ++ [_]zigai.Message{.{ .response = .{
    .parts = &.{.{ .text = "It is 27 C and sunny in Madrid." }},
    .usage = .{ .input_tokens = 19, .output_tokens = 8 },
    .provider_name = "openai",
    .model_name = "gpt-5-mini",
    .finish_reason = .{ .kind = .stop, .raw = "completed" },
} }};

const tool_definitions = [_]zigai.model.ToolDefinition{.{
    .name = "weather",
    .description = "Return current weather for a city.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
}};

const StructuredResult = struct {
    city: []const u8,
    temperature_c: i16,
    condition: enum { sunny, cloudy, rain },
    alerts: ?[]const []const u8 = null,
};

/// Catalog state is caller-owned so the benchmark can reuse one I/O runtime
/// without hiding process lifetime or allocator ownership.
pub const Catalog = struct {
    io: std.Io,

    pub fn workloads(self: *Catalog) [7]harness.Workload {
        return .{
            workload(self, "history.roundtrip", historyRoundtrip),
            workload(self, "mcp.server", mcpServer),
            workload(self, "parallel_tools.agent", parallelToolsAgent),
            workload(self, "request.decode.openai", requestDecodeOpenai),
            workload(self, "request.encode.openai", requestEncodeOpenai),
            workload(self, "schema.reflect_validate", schemaReflectValidate),
            workload(self, "streaming.openai", streamingModelEvents),
        };
    }

    fn historyRoundtrip(_: *Catalog, allocator: std.mem.Allocator) !u64 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const processed = try zigai.history.processAll(
            memory,
            &.{ .provider_valid, .{ .trim = .{ .max_messages = 8 } }, .compact },
            .{ .profile = .{}, .usage = .{}, .model_requests = 2 },
            &history_messages,
        );
        const encoded = try zigai.history.stringify(memory, processed);
        var parsed = try zigai.history.parse(memory, encoded);
        defer parsed.deinit();
        const roundtrip = try zigai.history.stringify(memory, parsed.messages);
        return checksum(roundtrip);
    }

    fn mcpServer(self: *Catalog, allocator: std.mem.Allocator) !u64 {
        const Handler = struct {
            fn handle(
                _: *anyopaque,
                memory: std.mem.Allocator,
                method: []const u8,
                _: []const u8,
            ) ![]u8 {
                if (!std.mem.eql(u8, method, zigai.mcp.methods.list_tools))
                    return error.UnexpectedMcpMethod;
                return memory.dupe(
                    u8,
                    "{\"tools\":[{\"name\":\"weather\",\"description\":\"Weather lookup\",\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}",
                );
            }
        };
        var server = zigai.mcp.Server{
            .handler = .{ .context = self, .handleFn = Handler.handle },
            .capabilities_json = "{\"tools\":{}}",
        };
        const response = try server.handle(allocator, mcp_request, null);
        defer response.deinit(allocator);
        if (response.status != 200 or response.body == null) return error.InvalidMcpBenchmarkResponse;
        return checksum(response.body.?);
    }

    fn parallelToolsAgent(self: *Catalog, allocator: std.mem.Allocator) !u64 {
        const call_parts = [_]zigai.model.Part{
            .{ .tool_call = .{ .id = "one", .name = "compute", .arguments_json = "{\"value\":1}" } },
            .{ .tool_call = .{ .id = "two", .name = "compute", .arguments_json = "{\"value\":2}" } },
            .{ .tool_call = .{ .id = "three", .name = "compute", .arguments_json = "{\"value\":3}" } },
            .{ .tool_call = .{ .id = "four", .name = "compute", .arguments_json = "{\"value\":4}" } },
        };
        const final_parts = [_]zigai.model.Part{.{ .text = "computed" }};
        var scripted = zigai.testing.ScriptedModel{
            .responses = &.{ .{ .parts = &call_parts }, .{ .parts = &final_parts } },
        };
        const Tool = struct {
            fn execute(_: *anyopaque, memory: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                var hash = std.hash.Wyhash.init(0);
                for (0..128) |_| hash.update(arguments);
                std.mem.doNotOptimizeAway(hash.final());
                return memory.dupe(u8, arguments);
            }
        };
        const tool = zigai.Tool{
            .definition = .{
                .name = "compute",
                .description = "Perform deterministic work.",
                .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}},\"required\":[\"value\"],\"additionalProperties\":false}",
            },
            .context = self,
            .executeFn = Tool.execute,
        };
        var result = try (zigai.Agent{
            .model = scripted.model(),
            .tools = &.{tool},
            .io = self.io,
            .tool_limits = .{ .max_concurrency = 4 },
        }).run(allocator, "Compute all four values.");
        defer result.deinit();
        const encoded = try zigai.history.stringify(allocator, result.messages);
        defer allocator.free(encoded);
        return checksum(encoded);
    }

    fn requestDecodeOpenai(_: *Catalog, allocator: std.mem.Allocator) !u64 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const response = try zigai.providers.openai.decodeResponse(arena.allocator(), openai_response);
        const encoded = try zigai.history.stringify(arena.allocator(), &.{.{ .response = response }});
        return checksum(encoded);
    }

    fn requestEncodeOpenai(_: *Catalog, allocator: std.mem.Allocator) !u64 {
        const body = try zigai.providers.openai.encodeRequest(allocator, "gpt-5-mini", .{
            .messages = &request_messages,
            .instructions = &.{ "Use tools when useful.", "Return concise prose." },
            .tools = &tool_definitions,
            .output = .{ .json_schema = .{
                .name = "weather_result",
                .schema = zigai.reflect.schemaOf(StructuredResult),
            } },
            .settings = .{
                .temperature = 0.2,
                .max_tokens = 256,
                .parallel_tool_calls = true,
                .tool_choice = .auto,
            },
        });
        defer allocator.free(body);
        return checksum(body);
    }

    fn schemaReflectValidate(_: *Catalog, allocator: std.mem.Allocator) !u64 {
        const schema = zigai.reflect.schemaOf(StructuredResult);
        try zigai.json_schema.validateSchema(allocator, schema);
        const output =
            "{\"city\":\"Madrid\",\"temperature_c\":27,\"condition\":\"sunny\",\"alerts\":[\"heat\"]}";
        try zigai.json_schema.validate(allocator, .{ .json_schema = .{
            .name = "weather_result",
            .schema = schema,
        } }, output);
        var hash = std.hash.Wyhash.init(0);
        hash.update(schema);
        hash.update(output);
        return hash.final();
    }

    fn streamingModelEvents(self: *Catalog, allocator: std.mem.Allocator) !u64 {
        const Transport = struct {
            fn send(_: *anyopaque, _: std.mem.Allocator, _: zigai.transport.Request) !zigai.transport.Response {
                return error.UnexpectedBufferedRequest;
            }

            fn stream(
                _: *anyopaque,
                _: std.mem.Allocator,
                request: zigai.transport.Request,
                sink: zigai.transport.LineSink,
            ) !zigai.transport.StreamResponse {
                if (std.mem.indexOf(u8, request.body, "\"stream\":true") == null)
                    return error.InvalidStreamingBenchmarkRequest;
                const response = zigai.transport.StreamResponse{ .status = 200 };
                try sink.start(response);
                try sink.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Madrid is \"}");
                try sink.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"sunny and 27 C.\"}");
                try sink.line("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":19,\"output_tokens\":8,\"total_tokens\":27}}}");
                try sink.line("data: [DONE]");
                return response;
            }
        };
        const Sink = struct {
            hash: std.hash.Wyhash = .init(0),
            events: usize = 0,

            fn emit(context: *anyopaque, event: zigai.model.ModelStreamEvent) !void {
                const sink: *@This() = @ptrCast(@alignCast(context));
                sink.events += 1;
                switch (event) {
                    .part_start => |value| {
                        sink.hash.update("start");
                        updateU64(&sink.hash, @intCast(value.index));
                    },
                    .part_delta => |value| switch (value.delta) {
                        .text => |delta| sink.hash.update(delta.content_delta),
                        .thinking => |delta| sink.hash.update(delta.content_delta),
                        else => sink.hash.update("delta"),
                    },
                    .part_end => |value| {
                        sink.hash.update("end");
                        updateU64(&sink.hash, @intCast(value.index));
                    },
                    .usage => |usage| {
                        sink.hash.update("usage");
                        updateU64(&sink.hash, usage.input_tokens);
                        updateU64(&sink.hash, usage.output_tokens);
                    },
                }
            }
        };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var provider = zigai.openai.Provider.init("benchmark", .{
            .context = self,
            .sendFn = Transport.send,
            .streamLinesFn = Transport.stream,
        });
        var client = zigai.openai.Client{
            .model_name = "gpt-5-mini",
            .provider = provider.provider(),
        };
        var sink: Sink = .{};
        const response = try client.model().stream(
            memory,
            .{ .messages = &request_messages },
            .{ .context = &sink, .eventFn = Sink.emit },
        );
        if (sink.events != 5) return error.IncompleteStreamingBenchmark;
        const encoded = try zigai.history.stringify(memory, &.{.{ .response = response }});
        sink.hash.update(encoded);
        return sink.hash.final();
    }
};

fn workload(
    catalog: *Catalog,
    name: []const u8,
    comptime runFn: fn (*Catalog, std.mem.Allocator) anyerror!u64,
) harness.Workload {
    const Adapter = struct {
        fn run(context: *anyopaque, allocator: std.mem.Allocator) !u64 {
            const self: *Catalog = @ptrCast(@alignCast(context));
            return runFn(self, allocator);
        }
    };
    return .{ .name = name, .context = catalog, .runFn = Adapter.run };
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn updateU64(hash: *std.hash.Wyhash, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

test "all production benchmark workloads are deterministic" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var catalog = Catalog{ .io = threaded.io() };
    const items = catalog.workloads();
    for (items) |item| {
        const first = try item.run(std.testing.allocator);
        const second = try item.run(std.testing.allocator);
        try std.testing.expectEqual(first, second);
    }
}
