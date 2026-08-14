const std = @import("std");
const zigai = @import("zigai");

test "agent executes a tool and sends its result back to the model" {
    const tool_call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "call-weather",
        .name = "weather",
        .arguments_json = "{\"city\":\"Madrid\"}",
    } }};
    const final_parts = [_]zigai.model.Part{.{ .text = "It is sunny in Madrid." }};
    const responses = [_]zigai.model.ModelResponse{
        .{ .parts = &tool_call_parts, .usage = .{ .input_tokens = 10, .output_tokens = 4 } },
        .{ .parts = &final_parts, .usage = .{ .input_tokens = 18, .output_tokens = 6 } },
    };

    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) {
                try std.testing.expectEqual(@as(usize, 2), request.messages.len);
                try std.testing.expectEqual(zigai.model.Role.system, request.messages[0].role);
                try std.testing.expectEqualStrings("You are concise.", request.messages[0].parts[0].text);
                try std.testing.expectEqualStrings("What is the weather?", request.messages[1].parts[0].text);
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                return;
            }
            try std.testing.expectEqual(@as(usize, 4), request.messages.len);
            const result = request.messages[3].parts[0].tool_result;
            try std.testing.expectEqualStrings("call-weather", result.call_id);
            try std.testing.expectEqualStrings("{\"temperature_c\":31}", result.content);
        }
    };

    var scripted = zigai.testing.ScriptedModel{
        .responses = &responses,
        .inspectFn = Inspector.inspect,
    };
    var tool_state: u8 = 0;
    const weather = zigai.Tool{
        .definition = .{
            .name = "weather",
            .description = "Get the current weather for a city.",
            .parameters_json_schema = "{\"type\":\"object\"}",
        },
        .context = &tool_state,
        .executeFn = struct {
            fn execute(_: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                try std.testing.expectEqualStrings("{\"city\":\"Madrid\"}", arguments);
                return allocator.dupe(u8, "{\"temperature_c\":31}");
            }
        }.execute,
    };

    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{weather},
        .system_prompt = "You are concise.",
    }).run(std.testing.allocator, "What is the weather?");
    defer result.deinit();

    try std.testing.expectEqualStrings("It is sunny in Madrid.", result.output);
    try std.testing.expectEqual(@as(usize, 2), result.model_requests);
    try std.testing.expectEqual(@as(u64, 28), result.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 10), result.usage.output_tokens);
}

fn successfulTool(state: *u8) zigai.Tool {
    return .{
        .definition = .{ .name = "tool", .description = "", .parameters_json_schema = "{}" },
        .context = state,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
                const calls: *u8 = @ptrCast(@alignCast(context));
                calls.* += 1;
                return allocator.dupe(u8, "ok");
            }
        }.execute,
    };
}

test "agent joins final text parts" {
    const parts = [_]zigai.model.Part{ .{ .text = "hello " }, .{ .text = "world" } };
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &parts }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &responses };
    var result = try (zigai.Agent{ .model = scripted.model() }).run(std.testing.allocator, "hi");
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world", result.output);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "instructions compose for one run without entering message history" {
    const Dependencies = struct { audience: []const u8 };
    const DynamicState = struct {
        calls: usize = 0,

        fn resolve(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.InstructionContext,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const dependencies = run_context.dependency(Dependencies) orelse return error.MissingDependencies;
            return std.fmt.allocPrint(allocator, "Answer {s} about {s}.", .{ dependencies.audience, run_context.prompt });
        }
    };
    const EmptyInstruction = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: zigai.InstructionContext) ![]const u8 {
            return "";
        }
    };
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 3), request.instructions.len);
            try std.testing.expectEqualStrings("Use plain language.", request.instructions[0]);
            try std.testing.expectEqualStrings("Answer developers about Zig allocators.", request.instructions[1]);
            try std.testing.expectEqualStrings("Keep it short.", request.instructions[2]);

            try std.testing.expectEqual(@as(usize, 4), request.messages.len);
            try std.testing.expectEqual(zigai.model.Role.system, request.messages[0].role);
            try std.testing.expectEqualStrings("Stable system prompt.", request.messages[0].parts[0].text);
            try std.testing.expectEqualStrings("Earlier answer", request.messages[1].parts[0].text);
            try std.testing.expectEqualStrings("old-call", request.messages[1].parts[1].tool_call.id);
            try std.testing.expect(request.messages[2].parts[0].tool_result.is_error);
            try std.testing.expectEqualStrings("Zig allocators", request.messages[3].parts[0].text);
        }
    };

    const history = [_]zigai.model.Message{
        .{ .role = .assistant, .parts = &.{
            .{ .text = "Earlier answer" },
            .{ .tool_call = .{ .id = "old-call", .name = "lookup", .arguments_json = "{}" } },
        } },
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{
            .call_id = "old-call",
            .name = "lookup",
            .content = "unavailable",
            .is_error = true,
        } }} },
    };
    const final_parts = [_]zigai.model.Part{.{ .text = "Done." }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final_parts }},
        .inspectFn = Inspector.inspect,
    };
    var dynamic_state: DynamicState = .{};
    var unused: u8 = 0;
    var dependencies = Dependencies{ .audience = "developers" };
    const configured = [_]zigai.Instruction{
        .{ .dynamic = .{ .context = &dynamic_state, .resolveFn = DynamicState.resolve } },
        .{ .text = "" },
        .{ .text = "Use plain language." },
        .{ .dynamic = .{ .context = &unused, .resolveFn = EmptyInstruction.resolve } },
    };

    var result = try (zigai.Agent{
        .model = scripted.model(),
        .system_prompt = "Stable system prompt.",
        .instructions = &configured,
    }).runWithOptions(std.testing.allocator, "Zig allocators", .{
        .message_history = &history,
        .instructions = &.{ "", "Keep it short." },
        .dependencies = &dependencies,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), dynamic_state.calls);
    try std.testing.expectEqual(@as(usize, 5), result.messages.len);
    try std.testing.expectEqualStrings("old-call", result.messages[1].parts[1].tool_call.id);
    try std.testing.expectEqualStrings("unavailable", result.messages[2].parts[0].tool_result.content);

    const FollowUpInspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 3), request.instructions.len);
            try std.testing.expectEqualStrings("Use plain language.", request.instructions[0]);
            try std.testing.expectEqualStrings("Answer readers about Follow up.", request.instructions[1]);
            try std.testing.expectEqualStrings("New run only.", request.instructions[2]);
            try std.testing.expectEqual(@as(usize, 6), request.messages.len);
        }
    };
    var follow_up = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final_parts }},
        .inspectFn = FollowUpInspector.inspect,
    };
    dependencies.audience = "readers";
    var follow_up_result = try (zigai.Agent{
        .model = follow_up.model(),
        .instructions = &configured,
    }).runWithOptions(std.testing.allocator, "Follow up", .{
        .message_history = result.messages,
        .instructions = &.{"New run only."},
        .dependencies = &dependencies,
    });
    defer follow_up_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), dynamic_state.calls);
}

test "instruction failures and unsupported system capability stop before requesting" {
    const Failure = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: zigai.InstructionContext) ![]const u8 {
            return error.InstructionFailed;
        }
    };
    var unused: u8 = 0;
    var failing = zigai.testing.ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(error.InstructionFailed, (zigai.Agent{
        .model = failing.model(),
        .instructions = &.{.{ .dynamic = .{ .context = &unused, .resolveFn = Failure.resolve } }},
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 0), failing.request_count);

    var unsupported = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_system_messages = false },
    };
    try std.testing.expectError(zigai.agent.Agent.Error.ModelDoesNotSupportSystemMessages, (zigai.Agent{
        .model = unsupported.model(),
        .instructions = &.{.{ .text = "Be concise." }},
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 0), unsupported.request_count);
    try std.testing.expect((zigai.InstructionContext{ .prompt = "hi" }).dependency(u8) == null);
}

test "agent optionally validates structured output before returning it" {
    const valid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":42}" }};
    const invalid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"no\"}" }};
    const schema: zigai.model.OutputFormat = .{ .json_schema = .{
        .name = "answer",
        .schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"integer\"}},\"required\":[\"answer\"],\"additionalProperties\":false}",
    } };

    var valid = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &valid_parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    var result = try (zigai.Agent{
        .model = valid.model(),
        .output = schema,
        .validate_output_locally = true,
    }).run(std.testing.allocator, "answer");
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"answer\":42}", result.output);

    var invalid = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &invalid_parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    try std.testing.expectError(zigai.json_schema.Error.OutputSchemaValidationFailed, (zigai.Agent{
        .model = invalid.model(),
        .output = schema,
        .validate_output_locally = true,
    }).run(std.testing.allocator, "answer"));
}

test "typed agent output derives its schema and owns decoded data" {
    const Weather = struct {
        city: []const u8,
        temperature_c: f64,
        alerts: []const []const u8,
    };
    const parts = [_]zigai.model.Part{.{
        .text = "{\"city\":\"Madrid\",\"temperature_c\":31.5,\"alerts\":[\"heat\"]}",
    }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            const format = request.output.json_schema;
            try std.testing.expectEqualStrings("response", format.name);
            try std.testing.expect(format.strict);
            try std.testing.expectEqualStrings(zigai.reflect.schemaOf(Weather), format.schema);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_json_schema_output = true },
    };

    var result = try (zigai.Agent{ .model = scripted.model() }).runTyped(
        Weather,
        std.testing.allocator,
        "What is the weather?",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("Madrid", result.output.city);
    try std.testing.expectEqual(@as(f64, 31.5), result.output.temperature_c);
    try std.testing.expectEqualStrings("heat", result.output.alerts[0]);
    try std.testing.expectEqualStrings(parts[0].text, result.output_json);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "typed agent output reports decoding errors without leaking" {
    const Answer = struct { answer: u32 };
    const parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"not a number\"}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    try std.testing.expectError(
        zigai.Agent.Error.InvalidTypedOutput,
        (zigai.Agent{ .model = scripted.model() }).runTyped(Answer, std.testing.allocator, "Answer."),
    );
}

test "typed agent output is available after streaming completes" {
    const Answer = struct { answer: []const u8 };
    const parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"yes\"}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true, .supports_streaming = true },
    };
    const Capture = struct {
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .final_output => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{ .model = scripted.model() }).runTypedStream(
        Answer,
        std.testing.allocator,
        "Answer.",
        .{ .context = &capture, .eventFn = Capture.event },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("yes", result.output.answer);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
}

test "streaming validation suppresses the final event for invalid output" {
    const parts = [_]zigai.model.Part{.{ .text = "not JSON" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_object_output = true, .supports_streaming = true },
    };
    const Capture = struct {
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.agent.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .final_output => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    try std.testing.expectError(zigai.json_schema.Error.InvalidJsonOutput, (zigai.Agent{
        .model = scripted.model(),
        .output = .json_object,
        .validate_output_locally = true,
    }).runStream(std.testing.allocator, "answer", .{ .context = &capture, .eventFn = Capture.event }));
    try std.testing.expectEqual(@as(usize, 0), capture.finals);
}

test "agent rejects unsupported requested capabilities before a model request" {
    var no_system = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_system_messages = false },
    };
    try std.testing.expectError(
        zigai.agent.Agent.Error.ModelDoesNotSupportSystemMessages,
        (zigai.Agent{ .model = no_system.model(), .system_prompt = "system" }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), no_system.request_count);

    var no_tools = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_tools = false },
    };
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    try std.testing.expectError(
        zigai.agent.Agent.Error.ModelDoesNotSupportTools,
        (zigai.Agent{ .model = no_tools.model(), .tools = &.{tool} }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), no_tools.request_count);

    var no_json = zigai.testing.ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(
        zigai.agent.Agent.Error.ModelDoesNotSupportJsonObjectOutput,
        (zigai.Agent{ .model = no_json.model(), .output = .json_object }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectError(
        zigai.agent.Agent.Error.ModelDoesNotSupportJsonSchemaOutput,
        (zigai.Agent{
            .model = no_json.model(),
            .output = .{ .json_schema = .{ .name = "answer", .schema = "{}" } },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), no_json.request_count);
}

test "agent rejects empty and textless final responses" {
    const no_parts = [_]zigai.model.ModelResponse{.{ .parts = &.{} }};
    var empty = zigai.testing.ScriptedModel{ .responses = &no_parts };
    try std.testing.expectError(
        zigai.agent.Agent.Error.EmptyModelResponse,
        (zigai.Agent{ .model = empty.model() }).run(std.testing.allocator, "hi"),
    );

    const tool_result_parts = [_]zigai.model.Part{.{ .tool_result = .{
        .call_id = "id",
        .name = "tool",
        .content = "ignored",
    } }};
    const no_text = [_]zigai.model.ModelResponse{.{ .parts = &tool_result_parts }};
    var textless = zigai.testing.ScriptedModel{ .responses = &no_text };
    try std.testing.expectError(
        zigai.agent.Agent.Error.EmptyModelResponse,
        (zigai.Agent{ .model = textless.model() }).run(std.testing.allocator, "hi"),
    );
}

test "agent enforces model request and parallel tool limits" {
    var never_called = zigai.testing.ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(
        zigai.agent.Agent.Error.MaxModelRequestsExceeded,
        (zigai.Agent{ .model = never_called.model(), .limits = .{ .max_model_requests = 0 } }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), never_called.request_count);

    const calls_parts = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "one", .name = "tool", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "two", .name = "tool", .arguments_json = "{}" } },
    };
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &calls_parts }};
    var no_parallel = zigai.testing.ScriptedModel{
        .responses = &responses,
        .profile = .{ .supports_parallel_tool_calls = false },
    };
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    try std.testing.expectError(
        zigai.agent.Agent.Error.ParallelToolCallsNotSupported,
        (zigai.Agent{ .model = no_parallel.model(), .tools = &.{tool} }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(u8, 0), calls);
}

test "agent reports unknown tools and exhausts a bounded tool loop" {
    const call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "one",
        .name = "missing",
        .arguments_json = "{}",
    } }};
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &call_parts }};
    var unknown = zigai.testing.ScriptedModel{ .responses = &responses };
    try std.testing.expectError(
        zigai.agent.Agent.Error.UnknownTool,
        (zigai.Agent{ .model = unknown.model() }).run(std.testing.allocator, "hi"),
    );

    const known_call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "one",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    const bounded_responses = [_]zigai.model.ModelResponse{.{ .parts = &known_call_parts }};
    var bounded = zigai.testing.ScriptedModel{ .responses = &bounded_responses };
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    try std.testing.expectError(
        zigai.agent.Agent.Error.MaxModelRequestsExceeded,
        (zigai.Agent{ .model = bounded.model(), .tools = &.{tool}, .limits = .{ .max_model_requests = 1 } }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(u8, 1), calls);
}

test "agent propagates tool failures" {
    const call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "one",
        .name = "fails",
        .arguments_json = "{}",
    } }};
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &call_parts }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &responses };
    var unused: u8 = 0;
    const tool = zigai.Tool{
        .definition = .{ .name = "fails", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeFn = struct {
            fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
                return error.ToolFailed;
            }
        }.execute,
    };
    try std.testing.expectError(
        error.ToolFailed,
        (zigai.Agent{ .model = scripted.model(), .tools = &.{tool} }).run(std.testing.allocator, "hi"),
    );
}

const FlakyModel = struct {
    failures_remaining: usize,
    failure: anyerror,
    attempts: usize = 0,
    response: zigai.model.ModelResponse,

    fn model(self: *FlakyModel) zigai.Model {
        return .{ .context = self, .profile = .{}, .requestFn = request };
    }

    fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.model.ModelRequest) !zigai.model.ModelResponse {
        const self: *FlakyModel = @ptrCast(@alignCast(context));
        self.attempts += 1;
        if (self.failures_remaining > 0) {
            self.failures_remaining -= 1;
            return self.failure;
        }
        return self.response;
    }
};

test "agent retries transient provider failures and counts every request" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    var flaky = FlakyModel{
        .failures_remaining = 2,
        .failure = error.ProviderRateLimited,
        .response = .{ .parts = &parts, .usage = .{ .input_tokens = 1, .output_tokens = 1 } },
    };
    var result = try (zigai.Agent{ .model = flaky.model() }).run(std.testing.allocator, "hi");
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 3), result.model_requests);
    try std.testing.expectEqual(@as(usize, 3), flaky.attempts);
}

test "agent honors retry policy and the global request limit" {
    const parts = [_]zigai.model.Part{.{ .text = "unreachable" }};
    var capped = FlakyModel{
        .failures_remaining = 3,
        .failure = error.ProviderRateLimited,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(
        error.ProviderRateLimited,
        (zigai.Agent{
            .model = capped.model(),
            .retry_policy = .{ .max_retries = 1 },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 2), capped.attempts);

    var disabled = FlakyModel{
        .failures_remaining = 2,
        .failure = error.ProviderServerError,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(
        error.ProviderServerError,
        (zigai.Agent{
            .model = disabled.model(),
            .retry_policy = .{ .retry_server_errors = false },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 1), disabled.attempts);

    var request_limited = FlakyModel{
        .failures_remaining = 2,
        .failure = error.ProviderRateLimited,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(
        zigai.agent.Agent.Error.MaxModelRequestsExceeded,
        (zigai.Agent{
            .model = request_limited.model(),
            .limits = .{ .max_model_requests = 1 },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 1), request_limited.attempts);
}

test "agent provides optional built-in backoff and requires an IO implementation" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    var missing_io = FlakyModel{
        .failures_remaining = 1,
        .failure = error.RequestTimedOut,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(zigai.agent.Agent.Error.RetryBackoffRequiresIo, (zigai.Agent{
        .model = missing_io.model(),
        .retry_policy = .{ .backoff = .{ .initial_delay_ms = 0 } },
    }).run(std.testing.allocator, "retry"));

    var backed_off = FlakyModel{
        .failures_remaining = 1,
        .failure = error.RequestTimedOut,
        .response = .{ .parts = &parts },
    };
    var result = try (zigai.Agent{
        .model = backed_off.model(),
        .io = std.testing.io,
        .retry_policy = .{ .backoff = .{ .initial_delay_ms = 1, .maximum_delay_ms = 1 } },
    }).run(std.testing.allocator, "retry");
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 2), backed_off.attempts);
}

test "agent enforces cumulative token limits" {
    const parts = [_]zigai.model.Part{.{ .text = "answer" }};
    const response = [_]zigai.model.ModelResponse{.{
        .parts = &parts,
        .usage = .{ .input_tokens = 4, .output_tokens = 3 },
    }};

    var input = zigai.testing.ScriptedModel{ .responses = &response };
    try std.testing.expectError(
        zigai.agent.Agent.Error.InputTokenLimitExceeded,
        (zigai.Agent{ .model = input.model(), .limits = .{ .max_input_tokens = 3 } }).run(std.testing.allocator, "hi"),
    );

    var output = zigai.testing.ScriptedModel{ .responses = &response };
    try std.testing.expectError(
        zigai.agent.Agent.Error.OutputTokenLimitExceeded,
        (zigai.Agent{ .model = output.model(), .limits = .{ .max_output_tokens = 2 } }).run(std.testing.allocator, "hi"),
    );

    var total = zigai.testing.ScriptedModel{ .responses = &response };
    try std.testing.expectError(
        zigai.agent.Agent.Error.TotalTokenLimitExceeded,
        (zigai.Agent{ .model = total.model(), .limits = .{ .max_total_tokens = 6 } }).run(std.testing.allocator, "hi"),
    );
}

test "contextual tools receive typed dependencies and current run accounting" {
    const Dependencies = struct { prefix: []const u8 };
    const ToolState = struct {
        saw_usage: bool = false,
        saw_request_count: bool = false,
    };
    const ContextTool = struct {
        fn fallback(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
            return error.ContextWasNotProvided;
        }

        fn execute(raw: *anyopaque, allocator: std.mem.Allocator, context: zigai.model.ToolRunContext, _: []const u8) ![]const u8 {
            const state: *ToolState = @ptrCast(@alignCast(raw));
            const dependencies = context.dependency(Dependencies) orelse return error.MissingDependencies;
            state.saw_usage = context.usage.input_tokens == 2 and context.usage.output_tokens == 1;
            state.saw_request_count = context.model_requests == 1;
            return std.fmt.allocPrint(allocator, "{s} result", .{dependencies.prefix});
        }
    };
    var script = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &.{.{ .tool_call = .{ .id = "call_1", .name = "context", .arguments_json = "{}" } }}, .usage = .{ .input_tokens = 2, .output_tokens = 1 } },
        .{ .parts = &.{.{ .text = "done" }} },
    } };
    var state: ToolState = .{};
    var dependencies = Dependencies{ .prefix = "typed" };
    const tool = zigai.Tool{
        .definition = .{ .name = "context", .description = "Read context.", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = ContextTool.fallback,
        .executeWithContextFn = ContextTool.execute,
    };
    var result = try (zigai.Agent{
        .model = script.model(),
        .tools = &.{tool},
        .dependencies = &dependencies,
    }).run(std.testing.allocator, "use context");
    defer result.deinit();
    try std.testing.expect(state.saw_usage);
    try std.testing.expect(state.saw_request_count);
    try std.testing.expectEqualStrings("typed result", result.messages[2].parts[0].tool_result.content);
}

test "agent supports preflight cancellation and a fallible retry hook" {
    const parts = [_]zigai.model.Part{.{ .text = "unused" }};
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &parts }};
    var cancelled_model = zigai.testing.ScriptedModel{ .responses = &responses };
    var token: zigai.agent.CancellationToken = .{};
    token.cancel();
    try std.testing.expectError(zigai.agent.Agent.Error.Cancelled, (zigai.Agent{
        .model = cancelled_model.model(),
        .cancellation = &token,
    }).run(std.testing.allocator, "stop"));
    try std.testing.expectEqual(@as(usize, 0), cancelled_model.request_count);

    const Failing = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.model.ModelRequest) !zigai.model.ModelResponse {
            return error.ProviderRateLimited;
        }
        fn hook(_: *anyopaque, event: zigai.agent.RetryEvent) !void {
            try std.testing.expectEqual(@as(usize, 1), event.retry_number);
            return error.BackoffInterrupted;
        }
    };
    var unused: u8 = 0;
    const model = zigai.Model{
        .context = &unused,
        .profile = .{},
        .requestFn = Failing.request,
    };
    try std.testing.expectError(error.BackoffInterrupted, (zigai.Agent{
        .model = model,
        .retry_policy = .{ .before_retry = .{ .context = &unused, .waitFn = Failing.hook } },
    }).run(std.testing.allocator, "retry"));
}

test "agent propagates runtime controls and normalizes in-flight cancellation" {
    const RuntimeModel = struct {
        token: *zigai.CancellationToken,
        fn request(context: *anyopaque, _: std.mem.Allocator, model_request: zigai.model.ModelRequest) !zigai.model.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(?u64, 250), model_request.timeout_ms);
            try std.testing.expect(model_request.cancellation == self.token);
            self.token.cancel();
            return error.RequestCancelled;
        }
    };
    var token: zigai.CancellationToken = .{};
    var runtime = RuntimeModel{ .token = &token };
    const model = zigai.Model{ .context = &runtime, .profile = .{}, .requestFn = RuntimeModel.request };
    try std.testing.expectError(zigai.agent.Agent.Error.Cancelled, (zigai.Agent{
        .model = model,
        .request_timeout_ms = 250,
        .cancellation = &token,
    }).run(std.testing.allocator, "cancel while waiting"));
}

test "retry hooks receive captured provider response metadata" {
    const State = struct { retries: usize = 0 };
    const Failing = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, model_request: zigai.model.ModelRequest) !zigai.model.ModelResponse {
            model_request.error_observer.?.observe(.{
                .provider = "test",
                .status = 429,
                .message = "slow down",
                .body = "{}",
                .retry_after_seconds = 3,
                .rate_limit_remaining_requests = 0,
                .rate_limit_remaining_tokens = 12,
            });
            return error.ProviderRateLimited;
        }
        fn hook(context: *anyopaque, event: zigai.agent.RetryEvent) !void {
            const state: *State = @ptrCast(@alignCast(context));
            state.retries += 1;
            try std.testing.expectEqual(@as(?u64, 3), event.retry_after_seconds);
            try std.testing.expectEqual(@as(?u64, 0), event.rate_limit_remaining_requests);
            try std.testing.expectEqual(@as(?u64, 12), event.rate_limit_remaining_tokens);
        }
    };
    var state: State = .{};
    const model = zigai.Model{ .context = &state, .profile = .{}, .requestFn = Failing.request };
    try std.testing.expectError(error.ProviderRateLimited, (zigai.Agent{
        .model = model,
        .retry_policy = .{ .max_retries = 1, .before_retry = .{ .context = &state, .waitFn = Failing.hook } },
    }).run(std.testing.allocator, "retry"));
    try std.testing.expectEqual(@as(usize, 1), state.retries);
}

test "streaming agent uses the same tool loop and emits ordered events" {
    const calls = [_]zigai.model.Part{.{ .tool_call = .{ .id = "call_1", .name = "tool", .arguments_json = "{}" } }};
    const answer = [_]zigai.model.Part{.{ .text = "done" }};
    const responses = [_]zigai.model.ModelResponse{
        .{ .parts = &calls, .usage = .{ .input_tokens = 2, .output_tokens = 1 } },
        .{ .parts = &answer, .usage = .{ .input_tokens = 3, .output_tokens = 1 } },
    };
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.instructions.len);
            try std.testing.expectEqualStrings("Stream carefully.", request.instructions[0]);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &responses,
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_streaming = true },
    };
    var tool_calls: u8 = 0;
    const tool = successfulTool(&tool_calls);
    const Capture = struct {
        model_events: usize = 0,
        tool_results: usize = 0,
        finals: usize = 0,
        fn event(context: *anyopaque, value: zigai.agent.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => self.model_events += 1,
                .tool_result => |result| {
                    self.tool_results += 1;
                    try std.testing.expectEqualStrings("ok", result.content);
                },
                .final_output => |output| {
                    self.finals += 1;
                    try std.testing.expectEqualStrings("done", output);
                },
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{ .model = scripted.model(), .tools = &.{tool} }).runStreamWithOptions(
        std.testing.allocator,
        "go",
        .{ .instructions = &.{"Stream carefully."} },
        .{ .context = &capture, .eventFn = Capture.event },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 4), capture.model_events);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_results);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
}

test "streaming capability is checked and emitted streams are never retried" {
    const Sink = struct {
        fn event(_: *anyopaque, _: zigai.agent.AgentStreamEvent) !void {}
    };
    var unused: u8 = 0;
    const sink = zigai.agent.AgentStreamSink{ .context = &unused, .eventFn = Sink.event };
    var unsupported = zigai.testing.ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(zigai.agent.Agent.Error.ModelDoesNotSupportStreaming, (zigai.Agent{
        .model = unsupported.model(),
    }).runStream(std.testing.allocator, "no", sink));

    const StreamingFailure = struct {
        calls: usize = 0,
        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.model.ModelRequest) !zigai.model.ModelResponse {
            return error.Unused;
        }
        fn stream(context: *anyopaque, _: std.mem.Allocator, _: zigai.model.ModelRequest, model_sink: zigai.model.ModelStreamSink) !zigai.model.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try model_sink.emit(.{ .text_delta = "partial" });
            return error.ProviderRateLimited;
        }
    };
    var failure: StreamingFailure = .{};
    const model = zigai.Model{
        .context = &failure,
        .profile = .{ .supports_streaming = true },
        .requestFn = StreamingFailure.request,
        .streamFn = StreamingFailure.stream,
    };
    try std.testing.expectError(error.ProviderRateLimited, (zigai.Agent{ .model = model }).runStream(std.testing.allocator, "go", sink));
    try std.testing.expectEqual(@as(usize, 1), failure.calls);
}
