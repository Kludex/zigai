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

test "approval tools pause into JSON and resume without repeating the model request" {
    const calls = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "approval-1",
        .name = "publish",
        .arguments_json = "{\"message\":\"hello\"}",
    } }};
    const final = [_]zigai.model.Part{.{ .text = "Published." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) {
                try std.testing.expectEqual(@as(usize, 1), request.messages.len);
                return;
            }
            try std.testing.expectEqual(@as(usize, 3), request.messages.len);
            const result = request.messages[2].parts[0].tool_result;
            try std.testing.expectEqualStrings("approval-1", result.call_id);
            try std.testing.expectEqualStrings("sent", result.content);
            try std.testing.expect(!result.is_error);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &calls, .usage = .{ .input_tokens = 3, .output_tokens = 2 } },
            .{ .parts = &final, .usage = .{ .input_tokens = 5, .output_tokens = 1 } },
        },
        .inspectFn = Inspector.inspect,
    };
    var executions: u8 = 0;
    const publish = zigai.Tool{
        .definition = .{
            .name = "publish",
            .description = "Publish a message.",
            .parameters_json_schema = "{\"type\":\"object\"}",
        },
        .execution = .requires_approval,
        .context = &executions,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
                const count: *u8 = @ptrCast(@alignCast(context));
                count.* += 1;
                return allocator.dupe(u8, "sent");
            }
        }.execute,
    };
    const agent = zigai.Agent{ .model = scripted.model(), .tools = &.{publish} };
    var first = try agent.runUntilPause(std.testing.allocator, "Publish this.");
    const state_json = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| blk: {
            try std.testing.expectEqual(@as(usize, 1), paused.calls.len);
            try std.testing.expectEqualStrings("approval-1", paused.calls[0].call_id);
            try std.testing.expectEqual(zigai.ToolExecution.requires_approval, paused.calls[0].execution);
            try std.testing.expectEqual(@as(u8, 0), executions);
            const parsed_state = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, paused.state_json, .{});
            parsed_state.deinit();
            break :blk try std.testing.allocator.dupe(u8, paused.state_json);
        },
    };
    first.deinit();
    defer std.testing.allocator.free(state_json);

    const decisions_json = try zigai.stringifyResumeDecisions(std.testing.allocator, &.{.{
        .call_id = "approval-1",
        .action = .approve,
    }});
    defer std.testing.allocator.free(decisions_json);
    var resumed = try agent.resumeRunJson(std.testing.allocator, state_json, decisions_json);
    defer resumed.deinit();
    switch (resumed) {
        .paused => return error.ExpectedCompleteRun,
        .complete => |result| {
            try std.testing.expectEqualStrings("Published.", result.output);
            try std.testing.expectEqual(@as(usize, 2), result.model_requests);
            try std.testing.expectEqual(@as(u64, 8), result.usage.input_tokens);
        },
    }
    try std.testing.expectEqual(@as(u8, 1), executions);
    try std.testing.expectEqual(@as(usize, 2), scripted.request_count);
}

test "external tools accept supplied results without local execution" {
    const external_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "external-1",
        .name = "human_input",
        .arguments_json = "{}",
    } }};
    const final = [_]zigai.model.Part{.{ .text = "Thank you." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const result = request.messages[2].parts[0].tool_result;
            try std.testing.expectEqualStrings("Marcelo", result.content);
            try std.testing.expect(!result.is_error);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &external_call }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
    };
    var executions: u8 = 0;
    var external = successfulTool(&executions);
    external.definition.name = "human_input";
    external.execution = .external;
    const agent = zigai.Agent{ .model = scripted.model(), .tools = &.{external} };
    var first = try agent.runUntilPause(std.testing.allocator, "Ask.");
    defer first.deinit();
    const state = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| paused.state_json,
    };
    try std.testing.expectError(
        zigai.Agent.Error.MissingDeferredToolDecision,
        agent.resumeRun(std.testing.allocator, state, &.{}),
    );
    try std.testing.expectError(
        zigai.Agent.Error.DeferredToolRequiresResult,
        agent.resumeRun(std.testing.allocator, state, &.{.{
            .call_id = "external-1",
            .action = .approve,
        }}),
    );
    var resumed = try agent.resumeRun(std.testing.allocator, state, &.{.{
        .call_id = "external-1",
        .action = .result,
        .content = "Marcelo",
    }});
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
    try std.testing.expectEqual(@as(u8, 0), executions);
}

test "normal run refuses to discard a required approval pause" {
    const call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "approval",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call }} };
    var executions: u8 = 0;
    var tool = successfulTool(&executions);
    tool.execution = .requires_approval;
    try std.testing.expectError(
        zigai.Agent.Error.ToolCallRequiresDeferredRun,
        (zigai.Agent{ .model = scripted.model(), .tools = &.{tool} }).run(std.testing.allocator, "do it"),
    );
    try std.testing.expectEqual(@as(u8, 0), executions);
}

test "denied approval becomes an error tool result" {
    const call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "approval",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    const final = [_]zigai.model.Part{.{ .text = "Not executed." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const result = request.messages[2].parts[0].tool_result;
            try std.testing.expect(result.is_error);
            try std.testing.expectEqualStrings("Not authorized.", result.content);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &call }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
    };
    var executions: u8 = 0;
    var tool = successfulTool(&executions);
    tool.execution = .requires_approval;
    const agent = zigai.Agent{ .model = scripted.model(), .tools = &.{tool} };
    var first = try agent.runUntilPause(std.testing.allocator, "do it");
    defer first.deinit();
    const state = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| paused.state_json,
    };
    var resumed = try agent.resumeRun(std.testing.allocator, state, &.{.{
        .call_id = "approval",
        .action = .deny,
        .content = "Not authorized.",
    }});
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
    try std.testing.expectEqual(@as(u8, 0), executions);
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

test "history processors run before each request without discarding result history" {
    const State = struct {
        calls: usize = 0,
        fn process(
            context: *anyopaque,
            _: std.mem.Allocator,
            run: zigai.HistoryContext,
            messages: []const zigai.model.Message,
        ) ![]const zigai.model.Message {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(self.calls, run.model_requests);
            try std.testing.expectEqual(@as(usize, 2 + self.calls * 2), messages.len);
            if (self.calls == 0) {
                try std.testing.expectEqual(@as(u64, 0), run.usage.input_tokens);
            } else {
                try std.testing.expectEqual(@as(u64, 4), run.usage.input_tokens);
            }
            self.calls += 1;
            return messages;
        }
    };
    const call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "call",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &call, .usage = .{ .input_tokens = 4 } },
        .{ .parts = &final },
    } };
    var processor_state: State = .{};
    var tool_calls: u8 = 0;
    const tool = successfulTool(&tool_calls);
    const previous = [_]zigai.model.Message{.{
        .role = .user,
        .parts = &.{.{ .text = "earlier" }},
    }};
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .history_processors = &.{.{ .custom = .{
            .context = &processor_state,
            .processFn = State.process,
        } }},
    }).runWithOptions(std.testing.allocator, "now", .{
        .message_history = &previous,
        .history_processors = &.{.provider_valid},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), processor_state.calls);
    try std.testing.expectEqual(@as(u8, 1), tool_calls);
    try std.testing.expectEqual(@as(usize, 5), result.messages.len);
    try std.testing.expectEqualStrings("earlier", result.messages[0].parts[0].text);
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
        .max_output_retries = 0,
    }).run(std.testing.allocator, "answer"));
}

test "invalid structured output is returned to the model for correction" {
    const invalid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"no\"}" }};
    const valid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":42}" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            try std.testing.expectEqual(@as(usize, 3), request.messages.len);
            try std.testing.expectEqual(zigai.model.Role.assistant, request.messages[1].role);
            try std.testing.expectEqualStrings("{\"answer\":\"no\"}", request.messages[1].parts[0].text);
            try std.testing.expectEqual(zigai.model.Role.user, request.messages[2].role);
            try std.testing.expectEqualStrings(
                "The previous response did not match the required output schema. " ++
                    "Return only valid JSON matching the schema.",
                request.messages[2].parts[0].text,
            );
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &invalid_parts }, .{ .parts = &valid_parts } },
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_json_schema_output = true },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .json_schema = .{
            .name = "answer",
            .schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"integer\"}},\"required\":[\"answer\"],\"additionalProperties\":false}",
        } },
        .validate_output_locally = true,
        .max_output_retries = 1,
    }).run(std.testing.allocator, "answer");
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"answer\":42}", result.output);
    try std.testing.expectEqual(@as(usize, 2), result.model_requests);
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
        (zigai.Agent{ .model = scripted.model(), .max_output_retries = 0 }).runTyped(
            Answer,
            std.testing.allocator,
            "Answer.",
        ),
    );
}

test "typed agent output retries invalid JSON" {
    const Answer = struct { answer: u32 };
    const invalid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"no\"}" }};
    const valid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":42}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &invalid_parts }, .{ .parts = &valid_parts } },
        .profile = .{ .supports_json_schema_output = true },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .max_output_retries = 1,
    }).runTyped(Answer, std.testing.allocator, "Answer.");
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 42), result.output.answer);
    try std.testing.expectEqual(@as(usize, 2), result.model_requests);
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
        .max_output_retries = 0,
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

test "model settings merge from model through agent and run" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(f64, 0.3), request.settings.temperature.?);
            try std.testing.expectEqual(@as(u64, 200), request.settings.max_tokens.?);
            try std.testing.expectEqualStrings("run-stop", request.settings.stop_sequences.?[0]);
            try std.testing.expectEqual(@as(i64, 3), request.settings.seed.?);
            try std.testing.expectEqual(zigai.ReasoningEffort.high, request.settings.reasoning_effort.?);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{
            .supports_temperature = true,
            .supports_stop_sequences = true,
            .supports_seed = true,
            .reasoning_efforts = zigai.ModelProfile.ReasoningEffortSet.initFull(),
        },
    };
    var model = scripted.model();
    model.settings = .{
        .temperature = 0.1,
        .max_tokens = 100,
        .stop_sequences = &.{"model-stop"},
        .seed = 1,
        .reasoning_effort = .low,
    };
    var result = try (zigai.Agent{
        .model = model,
        .model_settings = .{ .temperature = 0.2, .max_tokens = 200, .seed = 2 },
    }).runWithOptions(std.testing.allocator, "hi", .{ .model_settings = .{
        .temperature = 0.3,
        .stop_sequences = &.{"run-stop"},
        .seed = 3,
        .reasoning_effort = .high,
    } });
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
}

test "unsupported model settings fail before requesting" {
    const parts = [_]zigai.model.Part{.{ .text = "unused" }};
    var temperature = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(
        zigai.Agent.Error.ModelDoesNotSupportTemperature,
        (zigai.Agent{
            .model = temperature.model(),
            .model_settings = .{ .temperature = 0.5 },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), temperature.request_count);

    var reasoning = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .reasoning_efforts = zigai.ModelProfile.ReasoningEffortSet.initOne(.low) },
    };
    try std.testing.expectError(
        zigai.Agent.Error.ModelDoesNotSupportReasoningEffort,
        (zigai.Agent{
            .model = reasoning.model(),
            .model_settings = .{ .reasoning_effort = .high },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), reasoning.request_count);
}

test "capabilities compose tools instructions hooks settings and model selection" {
    const parts = [_]zigai.model.Part{.{ .text = "selected" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("first", request.tools[0].name);
            try std.testing.expectEqualStrings("second", request.tools[1].name);
            try std.testing.expectEqual(@as(usize, 3), request.instructions.len);
            try std.testing.expectEqualStrings("agent", request.instructions[0]);
            try std.testing.expectEqualStrings("capability one", request.instructions[1]);
            try std.testing.expectEqualStrings("capability two", request.instructions[2]);
            try std.testing.expectEqual(@as(f64, 0.5), request.settings.temperature.?);
            try std.testing.expectEqual(@as(u64, 300), request.settings.max_tokens.?);
        }
    };
    var base = zigai.testing.ScriptedModel{ .responses = &.{} };
    var selected = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_temperature = true },
    };
    const Selector = struct {
        model: zigai.Model,
        calls: usize = 0,

        fn select(context: ?*anyopaque, run: zigai.CapabilityContext) !zigai.Model {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            try std.testing.expectEqualStrings("go", run.prompt);
            return self.model;
        }
    };
    var selector = Selector{ .model = selected.model() };
    const HookCapture = struct {
        sequence: [4]u8 = undefined,
        count: usize = 0,
    };
    const HookState = struct {
        capture: *HookCapture,
        id: u8,

        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.capture.sequence[self.capture.count] = switch (value) {
                .run_start => self.id,
                .run_end => |end| end_event: {
                    try std.testing.expectEqualStrings("selected", end.output);
                    break :end_event self.id + 10;
                },
                else => return,
            };
            self.capture.count += 1;
        }
    };
    var hook_capture: HookCapture = .{};
    var hook_one = HookState{ .capture = &hook_capture, .id = 1 };
    var hook_two = HookState{ .capture = &hook_capture, .id = 2 };
    var unused_calls: u8 = 0;
    var first = successfulTool(&unused_calls);
    first.definition.name = "first";
    var second = successfulTool(&unused_calls);
    second.definition.name = "second";
    const capabilities = [_]zigai.Capability{
        .{
            .tools = &.{first},
            .instructions = &.{.{ .text = "capability one" }},
            .hooks = &.{.{ .context = &hook_one, .eventFn = HookState.event }},
            .model_settings = .{ .temperature = 0.2 },
            .context = &selector,
            .selectModelFn = Selector.select,
        },
        .{
            .tools = &.{second},
            .instructions = &.{.{ .text = "capability two" }},
            .hooks = &.{.{ .context = &hook_two, .eventFn = HookState.event }},
            .model_settings = .{ .max_tokens = 300 },
        },
    };
    var result = try (zigai.Agent{
        .model = base.model(),
        .capabilities = &capabilities,
        .instructions = &.{.{ .text = "agent" }},
        .model_settings = .{ .temperature = 0.4 },
    }).runWithOptions(std.testing.allocator, "go", .{
        .model_settings = .{ .temperature = 0.5 },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("selected", result.output);
    try std.testing.expectEqual(@as(usize, 0), base.request_count);
    try std.testing.expectEqual(@as(usize, 1), selected.request_count);
    try std.testing.expectEqual(@as(usize, 1), selector.calls);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 11, 12 }, &hook_capture.sequence);
}

test "capability composition rejects duplicate tool names" {
    const parts = [_]zigai.model.Part{.{ .text = "unused" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    try std.testing.expectError(
        zigai.Agent.Error.DuplicateToolName,
        (zigai.Agent{
            .model = scripted.model(),
            .tools = &.{tool},
            .capabilities = &.{.{ .tools = &.{tool} }},
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), scripted.request_count);
}

test "static and dynamic toolsets prepare namespaced tools for each model step" {
    const Dependencies = struct { tenant: []const u8 };
    const State = struct {
        prepare_calls: usize = 0,
        execution_calls: usize = 0,
        metadata_checks: usize = 0,

        fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.execution_calls += 1;
            return allocator.dupe(u8, "ok");
        }

        fn prepare(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            run: zigai.ToolsetContext,
            tools: []const zigai.Tool,
        ) ![]const zigai.ToolsetEntry {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const dependencies = run.dependency(Dependencies) orelse return error.MissingDependencies;
            try std.testing.expectEqualStrings("acme", dependencies.tenant);
            try std.testing.expectEqual(self.prepare_calls, run.model_requests);
            try std.testing.expectEqual(@as(usize, 1 + self.prepare_calls * 2), run.messages.len);
            if (self.prepare_calls == 0) {
                try std.testing.expectEqual(@as(u64, 0), run.usage.input_tokens);
            } else if (self.prepare_calls == 1) {
                try std.testing.expectEqual(@as(u64, 2), run.usage.input_tokens);
            } else {
                try std.testing.expectEqual(@as(u64, 5), run.usage.input_tokens);
            }

            const entries = try allocator.alloc(zigai.ToolsetEntry, tools.len);
            entries[0] = .{
                .tool = tools[0],
                .enabled = self.prepare_calls == 0,
                .metadata = &.{
                    .{ .key = "scope", .value = "entry" },
                    .{ .key = "phase", .value = "alpha" },
                },
            };
            entries[1] = .{
                .tool = tools[1],
                .enabled = self.prepare_calls == 1,
                .metadata = &.{
                    .{ .key = "scope", .value = "entry" },
                    .{ .key = "phase", .value = "beta" },
                },
            };
            self.prepare_calls += 1;
            return entries;
        }

        fn hook(context: *anyopaque, event: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const tool = switch (event) {
                .tool_validation_end => |value| value.tool,
                else => return,
            };
            var saw_original = false;
            var saw_shared = false;
            var saw_scope = false;
            var saw_phase = false;
            for (tool.metadata) |metadata| {
                if (std.mem.eql(u8, metadata.key, "original")) {
                    saw_original = std.mem.eql(u8, metadata.value, "yes");
                } else if (std.mem.eql(u8, metadata.key, "shared")) {
                    saw_shared = std.mem.eql(u8, metadata.value, "yes");
                } else if (std.mem.eql(u8, metadata.key, "scope")) {
                    saw_scope = std.mem.eql(u8, metadata.value, "entry");
                } else if (std.mem.eql(u8, metadata.key, "phase")) {
                    saw_phase = true;
                }
            }
            try std.testing.expect(saw_original and saw_shared and saw_scope and saw_phase);
            self.metadata_checks += 1;
        }
    };
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) {
                try std.testing.expectEqual(@as(usize, 2), request.tools.len);
                try std.testing.expectEqualStrings("utility__always", request.tools[0].name);
                try std.testing.expectEqualStrings("db__alpha", request.tools[1].name);
            } else if (index == 1) {
                try std.testing.expectEqual(@as(usize, 2), request.tools.len);
                try std.testing.expectEqualStrings("utility__always", request.tools[0].name);
                try std.testing.expectEqualStrings("db__beta", request.tools[1].name);
                try std.testing.expectEqualStrings("db__alpha", request.messages[2].parts[0].tool_result.name);
            } else {
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                try std.testing.expectEqualStrings("utility__always", request.tools[0].name);
                try std.testing.expectEqualStrings("db__beta", request.messages[4].parts[0].tool_result.name);
            }
        }
    };

    const alpha_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "alpha-call",
        .name = "db__alpha",
        .arguments_json = "{}",
    } }};
    const beta_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "beta-call",
        .name = "db__beta",
        .arguments_json = "{}",
    } }};
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &alpha_call, .usage = .{ .input_tokens = 2 } },
            .{ .parts = &beta_call, .usage = .{ .input_tokens = 3 } },
            .{ .parts = &final },
        },
        .inspectFn = Inspector.inspect,
    };
    var state: State = .{};
    var dependencies = Dependencies{ .tenant = "acme" };
    const base_metadata = [_]zigai.ToolMetadata{
        .{ .key = "original", .value = "yes" },
        .{ .key = "scope", .value = "tool" },
    };
    const dynamic_tools = [_]zigai.Tool{
        .{
            .definition = .{ .name = "alpha", .description = "", .parameters_json_schema = "{}" },
            .metadata = &base_metadata,
            .context = &state,
            .executeFn = State.execute,
        },
        .{
            .definition = .{ .name = "beta", .description = "", .parameters_json_schema = "{}" },
            .metadata = &base_metadata,
            .context = &state,
            .executeFn = State.execute,
        },
    };
    const always = zigai.Tool{
        .definition = .{ .name = "always", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = State.execute,
    };
    const toolsets = [_]zigai.Toolset{
        .{ .tools = &.{always}, .namespace = "utility" },
        .{
            .tools = &dynamic_tools,
            .namespace = "db",
            .metadata = &.{
                .{ .key = "shared", .value = "yes" },
                .{ .key = "scope", .value = "toolset" },
            },
            .context = &state,
            .prepareFn = State.prepare,
        },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .toolsets = &toolsets,
        .hooks = &.{.{ .context = &state, .eventFn = State.hook }},
        .dependencies = &dependencies,
    }).run(std.testing.allocator, "work");
    defer result.deinit();

    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 3), state.prepare_calls);
    try std.testing.expectEqual(@as(usize, 2), state.execution_calls);
    try std.testing.expectEqual(@as(usize, 2), state.metadata_checks);
}

test "prepared toolsets reject duplicate names before requesting" {
    var unused: u8 = 0;
    const tool = successfulTool(&unused);
    const toolsets = [_]zigai.Toolset{
        .{ .tools = &.{tool}, .namespace = "same" },
        .{ .tools = &.{tool}, .namespace = "same" },
    };
    const final = [_]zigai.model.Part{.{ .text = "unused" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &final }} };
    try std.testing.expectError(zigai.Agent.Error.DuplicateToolName, (zigai.Agent{
        .model = scripted.model(),
        .toolsets = &toolsets,
    }).run(std.testing.allocator, "work"));
    try std.testing.expectEqual(@as(usize, 0), scripted.request_count);
}

test "lifecycle hooks observe ordered agent phases" {
    const Answer = struct { answer: u32 };
    const call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "call",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    const invalid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"no\"}" }};
    const valid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":42}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &call_parts },
            .{ .parts = &invalid_parts },
            .{ .parts = &valid_parts },
        },
        .profile = .{ .supports_json_schema_output = true },
    };
    const Capture = struct {
        sequence: [16]u8 = undefined,
        count: usize = 0,

        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const code: u8 = switch (value) {
                .run_start => 1,
                .model_request_start => 2,
                .model_request_end => 3,
                .tool_validation_start => 4,
                .tool_validation_end => 5,
                .tool_execution_start => 6,
                .tool_execution_end => 7,
                .output_validation_start => 8,
                .output_validation_end => 9,
                .output_validation_error => |failure| output_error: {
                    try std.testing.expect(failure.will_retry);
                    break :output_error 10;
                },
                .run_end => 11,
                else => return,
            };
            self.sequence[self.count] = code;
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .hooks = &.{.{ .context = &capture, .eventFn = Capture.event }},
        .max_output_retries = 1,
    }).runTyped(Answer, std.testing.allocator, "go");
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 42), result.output.answer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 2, 3, 8, 10, 2, 3, 8, 9, 11 }, &capture.sequence);
}

test "lifecycle hooks wrap every emitted stream event" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_streaming = true },
    };
    const Capture = struct {
        before: usize = 0,
        after: usize = 0,
        sink: usize = 0,

        fn hook(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .stream_event => |stream_value| switch (stream_value.stage) {
                    .before => self.before += 1,
                    .after => self.after += 1,
                },
                else => {},
            }
        }

        fn stream(context: *anyopaque, _: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sink += 1;
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .hooks = &.{.{ .context = &capture, .eventFn = Capture.hook }},
    }).runStream(
        std.testing.allocator,
        "go",
        .{ .context = &capture, .eventFn = Capture.stream },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), capture.sink);
    try std.testing.expectEqual(capture.sink, capture.before);
    try std.testing.expectEqual(capture.sink, capture.after);
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

test "agent distinguishes provider finish reasons from empty responses" {
    const partial_parts = [_]zigai.model.Part{.{ .text = "partial" }};
    const Cases = struct {
        fn expectFailure(
            expected: anyerror,
            reason: zigai.FinishReason,
            parts: []const zigai.model.Part,
        ) !void {
            var scripted = zigai.testing.ScriptedModel{
                .responses = &.{.{ .parts = parts, .finish_reason = reason }},
            };
            try std.testing.expectError(
                expected,
                (zigai.Agent{ .model = scripted.model() }).run(std.testing.allocator, "hi"),
            );
        }
    };
    try Cases.expectFailure(
        zigai.Agent.Error.ModelOutputTruncated,
        .{ .kind = .length, .raw = "max_tokens" },
        &partial_parts,
    );
    try Cases.expectFailure(
        zigai.Agent.Error.ContentFiltered,
        .{ .kind = .content_filter, .raw = "SAFETY" },
        &.{},
    );
    try Cases.expectFailure(
        zigai.Agent.Error.IncompleteToolCall,
        .{ .kind = .incomplete_tool_call, .raw = "MALFORMED_FUNCTION_CALL" },
        &.{},
    );
    try Cases.expectFailure(
        zigai.Agent.Error.EmptyModelResponse,
        .{ .kind = .stop, .raw = "stop" },
        &.{},
    );
}

test "agent result preserves the provider finish reason" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{
            .parts = &parts,
            .finish_reason = .{ .kind = .other, .raw = "provider_custom_stop" },
        }},
    };
    var result = try (zigai.Agent{ .model = scripted.model() }).run(std.testing.allocator, "hi");
    defer result.deinit();
    try std.testing.expectEqual(zigai.FinishReason.Kind.other, result.finish_reason.?.kind);
    try std.testing.expectEqualStrings("provider_custom_stop", result.finish_reason.?.raw);
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

    var over_tool_limit = zigai.testing.ScriptedModel{ .responses = &responses };
    try std.testing.expectError(
        zigai.Agent.Error.MaxToolCallsExceeded,
        (zigai.Agent{
            .model = over_tool_limit.model(),
            .tools = &.{tool},
            .limits = .{ .max_tool_calls = 1 },
        }).run(std.testing.allocator, "hi"),
    );
    try std.testing.expectEqual(@as(u8, 0), calls);

    var missing_io = zigai.testing.ScriptedModel{ .responses = &responses };
    try std.testing.expectError(
        zigai.Agent.Error.ParallelToolCallsRequireIo,
        (zigai.Agent{ .model = missing_io.model(), .tools = &.{tool} }).run(std.testing.allocator, "hi"),
    );

    var unavailable = zigai.testing.ScriptedModel{ .responses = &responses };
    var single_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer single_threaded.deinit();
    try std.testing.expectError(
        zigai.Agent.Error.ToolConcurrencyUnavailable,
        (zigai.Agent{
            .model = unavailable.model(),
            .tools = &.{tool},
            .io = single_threaded.io(),
        }).run(std.testing.allocator, "hi"),
    );
}

test "parallel tools overlap and keep model call order" {
    const call_parts = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "slow-id", .name = "slow", .arguments_json = "slow" } },
        .{ .tool_call = .{ .id = "fast-id", .name = "fast", .arguments_json = "fast" } },
    };
    const final_parts = [_]zigai.model.Part{.{ .text = "done" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const results = request.messages[2].parts;
            try std.testing.expectEqual(@as(usize, 2), results.len);
            try std.testing.expectEqualStrings("slow-id", results[0].tool_result.call_id);
            try std.testing.expectEqualStrings("slow", results[0].tool_result.content);
            try std.testing.expectEqualStrings("fast-id", results[1].tool_result.call_id);
            try std.testing.expectEqualStrings("fast", results[1].tool_result.content);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &call_parts }, .{ .parts = &final_parts } },
        .inspectFn = Inspector.inspect,
    };
    const State = struct {
        active: std.atomic.Value(usize) = .init(0),
        overlapped: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.ToolRunContext,
            arguments: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.active.fetchAdd(1, .seq_cst) > 0) self.overlapped.store(true, .seq_cst);
            defer _ = self.active.fetchSub(1, .seq_cst);
            const io = run_context.io orelse return error.MissingIo;
            (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(if (std.mem.eql(u8, arguments, "slow")) 40 else 5),
                .clock = .awake,
            } }).sleep(io) catch return error.ToolCancelled;
            try std.testing.expect(run_context.cancellation == null);
            return allocator.dupe(u8, arguments);
        }
    };
    var state: State = .{};
    const tools = [_]zigai.Tool{
        .{
            .definition = .{ .name = "slow", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .executeFn = struct {
                fn unused(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
                    return error.UnexpectedFallback;
                }
            }.unused,
            .executeWithContextFn = State.execute,
        },
        .{
            .definition = .{ .name = "fast", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .executeFn = struct {
                fn unused(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
                    return error.UnexpectedFallback;
                }
            }.unused,
            .executeWithContextFn = State.execute,
        },
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &tools,
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run both.");
    defer result.deinit();
    try std.testing.expect(state.overlapped.load(.seq_cst));
    try std.testing.expectEqualStrings("done", result.output);
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

test "invalid tool arguments are returned to the model for correction" {
    const invalid_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "bad",
        .name = "double",
        .arguments_json = "{}",
    } }};
    const valid_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "good",
        .name = "double",
        .arguments_json = "{\"value\":21}",
    } }};
    const final_parts = [_]zigai.model.Part{.{ .text = "42" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const result = request.messages[request.messages.len - 1].parts[0].tool_result;
            if (index == 1) {
                try std.testing.expect(result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, result.content, "InvalidToolArguments") != null);
            } else {
                try std.testing.expect(!result.is_error);
                try std.testing.expectEqualStrings("42", result.content);
            }
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &invalid_call },
            .{ .parts = &valid_call },
            .{ .parts = &final_parts },
        },
        .inspectFn = Inspector.inspect,
    };
    var double = zigai.reflect.tool("double", "Double an integer.", struct {
        fn call(arguments: struct { value: u8 }) !u8 {
            return arguments.value * 2;
        }
    }.call);
    double.max_retries = 1;

    const Hook = struct {
        validation_errors: usize = 0,
        executions: usize = 0,
        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .tool_validation_error => |failure| {
                    try std.testing.expectEqual(error.InvalidToolArguments, failure.failure);
                    self.validation_errors += 1;
                },
                .tool_execution_start => self.executions += 1,
                else => {},
            }
        }
    };
    var hook: Hook = .{};

    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{double},
        .hooks = &.{.{ .context = &hook, .eventFn = Hook.event }},
    }).run(std.testing.allocator, "Double 21.");
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.output);
    try std.testing.expectEqual(@as(usize, 3), result.model_requests);
    try std.testing.expectEqual(@as(usize, 1), hook.validation_errors);
    try std.testing.expectEqual(@as(usize, 1), hook.executions);
}

test "recoverable tool failures are returned as error results" {
    const call_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "one",
        .name = "lookup",
        .arguments_json = "{}",
    } }};
    const final_parts = [_]zigai.model.Part{.{ .text = "No data is available." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const result = request.messages[2].parts[0].tool_result;
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.content, "BackendUnavailable") != null);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &call_parts }, .{ .parts = &final_parts } },
        .inspectFn = Inspector.inspect,
    };
    var unused: u8 = 0;
    const tool = zigai.Tool{
        .definition = .{ .name = "lookup", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .max_retries = 1,
        .executeFn = struct {
            fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
                return error.BackendUnavailable;
            }
        }.execute,
    };
    const Hook = struct {
        saw_recoverable_error: bool = false,
        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .tool_execution_error => |failure| {
                    try std.testing.expectEqual(error.BackendUnavailable, failure.failure);
                    self.saw_recoverable_error = failure.recoverable;
                },
                else => {},
            }
        }
    };
    var hook: Hook = .{};
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .hooks = &.{.{ .context = &hook, .eventFn = Hook.event }},
    }).run(
        std.testing.allocator,
        "Look it up.",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("No data is available.", result.output);
    try std.testing.expect(hook.saw_recoverable_error);
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
        .max_retries = 0,
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

test "OpenTelemetry records runs requests tools retries tokens cost and latency" {
    const ModelState = struct {
        attempts: usize = 0,
        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.model.ModelRequest) !zigai.model.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            if (self.attempts == 1) return error.ProviderServerError;
            if (self.attempts == 2) return .{
                .parts = &.{.{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}" } }},
                .usage = .{ .input_tokens = 2, .output_tokens = 1 },
            };
            return .{
                .parts = &.{.{ .text = "done" }},
                .usage = .{ .input_tokens = 3, .output_tokens = 2 },
            };
        }
    };
    const Capture = struct {
        run_spans: usize = 0,
        request_spans: usize = 0,
        tool_spans: usize = 0,
        retries: usize = 0,
        token_metrics: usize = 0,
        cost: f64 = 0,
        saw_latency: bool = false,
        saw_prompt: bool = false,

        fn span(context: *anyopaque, value: zigai.TelemetrySpan) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.name, "gen_ai.invoke_agent")) self.run_spans += 1;
            if (std.mem.eql(u8, value.name, "gen_ai.chat")) self.request_spans += 1;
            if (std.mem.eql(u8, value.name, "gen_ai.execute_tool")) self.tool_spans += 1;
            try std.testing.expect(value.duration_seconds >= 0);
            for (value.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "gen_ai.input.messages")) self.saw_prompt = true;
            }
        }

        fn metric(context: *anyopaque, value: zigai.TelemetryMetric) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.name, "zigai.agent.retries")) self.retries += 1;
            if (std.mem.eql(u8, value.name, "gen_ai.client.token.usage")) self.token_metrics += 1;
            if (std.mem.eql(u8, value.name, "gen_ai.client.estimated_cost")) self.cost += value.value;
            if (std.mem.indexOf(u8, value.name, "duration") != null) {
                try std.testing.expect(value.value >= 0);
                self.saw_latency = true;
            }
        }
    };
    const Cost = struct {
        fn estimate(_: *anyopaque, provider: ?[]const u8, model_name: ?[]const u8, usage: zigai.model.Usage) f64 {
            std.testing.expectEqualStrings("test", provider.?) catch unreachable;
            std.testing.expectEqualStrings("instrumented", model_name.?) catch unreachable;
            return @as(f64, @floatFromInt(usage.totalTokens())) * 0.01;
        }
    };
    var model_state: ModelState = .{};
    var capture: Capture = .{};
    var unused: u8 = 0;
    var tool_calls: u8 = 0;
    const model = zigai.Model{
        .context = &model_state,
        .profile = .{},
        .provider_name = "test",
        .model_name = "instrumented",
        .requestFn = ModelState.request,
    };
    const telemetry = zigai.OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .cost_estimator = .{ .context = &unused, .estimateFn = Cost.estimate },
    };
    const tool = successfulTool(&tool_calls);
    var result = try (zigai.Agent{
        .model = model,
        .tools = &.{tool},
        .telemetry = telemetry,
    }).run(std.testing.allocator, "private prompt");
    defer result.deinit();

    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 1), capture.run_spans);
    try std.testing.expectEqual(@as(usize, 3), capture.request_spans);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_spans);
    try std.testing.expectEqual(@as(usize, 1), capture.retries);
    try std.testing.expectEqual(@as(usize, 4), capture.token_metrics);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), capture.cost, 0.0001);
    try std.testing.expect(capture.saw_latency);
    try std.testing.expect(!capture.saw_prompt);
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

test "lifecycle hooks observe request errors retries and terminal failures" {
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    const Capture = struct {
        retry_errors: usize = 0,
        terminal_errors: usize = 0,
        run_errors: usize = 0,

        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model_request_error => |failure| {
                    if (failure.will_retry) {
                        self.retry_errors += 1;
                    } else {
                        self.terminal_errors += 1;
                    }
                },
                .run_error => |failure| {
                    try std.testing.expectEqual(error.ProviderServerError, failure.failure);
                    self.run_errors += 1;
                },
                else => {},
            }
        }
    };
    var retried_capture: Capture = .{};
    var retried = FlakyModel{
        .failures_remaining = 1,
        .failure = error.ProviderServerError,
        .response = .{ .parts = &parts },
    };
    var result = try (zigai.Agent{
        .model = retried.model(),
        .hooks = &.{.{ .context = &retried_capture, .eventFn = Capture.event }},
    }).run(std.testing.allocator, "hi");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), retried_capture.retry_errors);
    try std.testing.expectEqual(@as(usize, 0), retried_capture.run_errors);

    var failed_capture: Capture = .{};
    var failed = FlakyModel{
        .failures_remaining = 1,
        .failure = error.ProviderServerError,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(error.ProviderServerError, (zigai.Agent{
        .model = failed.model(),
        .hooks = &.{.{ .context = &failed_capture, .eventFn = Capture.event }},
        .retry_policy = .{ .max_retries = 0 },
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 1), failed_capture.terminal_errors);
    try std.testing.expectEqual(@as(usize, 1), failed_capture.run_errors);
}

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
