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
                try std.testing.expectEqualStrings("You are concise.", request.messages[0].request.parts[0].system_prompt);
                try std.testing.expectEqualStrings("What is the weather?", request.messages[1].request.parts[0].user_prompt.text);
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                return;
            }
            try std.testing.expectEqual(@as(usize, 4), request.messages.len);
            const result = request.messages[3].request.parts[0].tool_return;
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
    try std.testing.expectEqual(@as(usize, 2), result.usage.requests);
    try std.testing.expectEqual(@as(usize, 1), result.usage.tool_calls);
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
            try std.testing.expectEqual(@as(usize, 4), request.messages.len);
            const result = request.messages[2].request.parts[0].tool_return;
            try std.testing.expectEqualStrings("approval-1", result.call_id);
            try std.testing.expectEqualStrings("sent", result.content);
            try std.testing.expect(!result.is_error);
            try std.testing.expectEqualStrings("Publishing was approved.", request.messages[3].request.parts[0].user_prompt.text);
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
        .executeOutputFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) !zigai.ToolOutput {
                const count: *u8 = @ptrCast(@alignCast(context));
                count.* += 1;
                return .{
                    .content = try allocator.dupe(u8, "sent"),
                    .follow_up_messages = &.{.{
                        .parts = &.{.{ .user_prompt = .{ .text = "Publishing was approved." } }},
                    }},
                };
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
            const result = request.messages[2].request.parts[0].tool_return;
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
            const result = request.messages[2].request.parts[0].tool_return;
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

test "streamed pause and resume expose deferred request and result events" {
    const call = [_]zigai.Part{.{ .tool_call = .{
        .id = "approval",
        .name = "tool",
        .arguments_json = "{}",
    } }};
    const final = [_]zigai.Part{.{ .text = "Executed." }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &call }, .{ .parts = &final } },
        .profile = .{ .supports_streaming = true },
    };
    var executions: u8 = 0;
    var tool = successfulTool(&executions);
    tool.execution = .requires_approval;
    const agent = zigai.Agent{ .model = scripted.model(), .tools = &.{tool} };
    const Capture = struct {
        requests: usize = 0,
        results: usize = 0,
        finals: usize = 0,

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .deferred_tool_requests => |event_value| {
                    self.requests += event_value.requests.len;
                    try std.testing.expectEqualStrings("approval", event_value.requests[0].call_id);
                },
                .deferred_tool_results => |event_value| {
                    self.results += event_value.results.len;
                    try std.testing.expectEqualStrings("ok", event_value.results[0].tool_return.content);
                },
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    const sink = zigai.AgentStreamSink{ .context = &capture, .eventFn = Capture.event };
    var first = try agent.runUntilPauseStream(std.testing.allocator, "do it", sink);
    defer first.deinit();
    const state = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| paused.state_json,
    };
    var resumed = try agent.resumeRunStream(std.testing.allocator, state, &.{.{
        .call_id = "approval",
        .action = .approve,
    }}, sink);
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
    try std.testing.expectEqual(@as(usize, 1), capture.requests);
    try std.testing.expectEqual(@as(usize, 1), capture.results);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(u8, 1), executions);
}

test "pending messages are copied ordered streamed and persisted in result history" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var queue = zigai.PendingMessageQueue.init(std.testing.allocator, threaded.io());
    defer queue.deinit();

    var first_text = [_]u8{ 'f', 'i', 'r', 's', 't' };
    try queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = &first_text } }} }});
    first_text[0] = 'X';
    try queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "second" } }} }});

    const State = struct {
        queue: *zigai.PendingMessageQueue,
        calls: usize = 0,

        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.calls == 0) {
                try std.testing.expectEqualStrings("first", request_value.messages[1].request.parts[0].user_prompt.text);
                try std.testing.expectEqualStrings("second", request_value.messages[2].request.parts[0].user_prompt.text);
                try self.queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "during" } }} }});
                self.calls += 1;
                try zigai.model.emitCompletePart(sink, 0, .{ .text = "draft" });
                return .{ .parts = &.{.{ .text = "draft" }} };
            }
            try std.testing.expectEqual(@as(usize, 5), request_value.messages.len);
            try std.testing.expectEqualStrings("draft", request_value.messages[3].response.parts[0].text);
            try std.testing.expectEqualStrings("during", request_value.messages[4].request.parts[0].user_prompt.text);
            self.calls += 1;
            try zigai.model.emitCompletePart(sink, 0, .{ .text = "final" });
            return .{ .parts = &.{.{ .text = "final" }} };
        }
    };
    const Capture = struct {
        enqueued: usize = 0,
        finals: usize = 0,

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .enqueued_messages => |event_value| self.enqueued += event_value.messages.len,
                .final_result => self.finals += 1,
                else => {},
            }
        }
    };
    var state = State{ .queue = &queue };
    var capture: Capture = .{};
    const model = zigai.Model{
        .context = &state,
        .profile = .{ .supports_streaming = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    var result = try (zigai.Agent{ .model = model }).runStreamWithOptions(
        std.testing.allocator,
        "prompt",
        .{ .pending_messages = &queue },
        .{ .context = &capture, .eventFn = Capture.event },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("final", result.output);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqual(@as(usize, 3), capture.enqueued);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqual(@as(usize, 6), result.messages.len);
    try std.testing.expectError(
        zigai.Agent.Error.PendingMessageQueueClosed,
        queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "late" } }} }}),
    );
}

test "pending messages survive a pause after deferred tool results" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var queue = zigai.PendingMessageQueue.init(std.testing.allocator, threaded.io());
    defer queue.deinit();

    const State = struct {
        queue: *zigai.PendingMessageQueue,
        calls: usize = 0,

        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.calls == 0) {
                try self.queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "after approval" } }} }});
                self.calls += 1;
                const parts = &struct {
                    const value = [_]zigai.Part{.{ .tool_call = .{
                        .id = "approval",
                        .name = "tool",
                        .arguments_json = "{}",
                    } }};
                }.value;
                try zigai.model.emitCompletePart(sink, 0, parts[0]);
                return .{ .parts = parts };
            }
            try std.testing.expectEqual(@as(usize, 5), request_value.messages.len);
            try std.testing.expect(request_value.messages[2].request.parts[0] == .tool_return);
            try std.testing.expectEqualStrings(
                "after approval",
                request_value.messages[3].request.parts[0].user_prompt.text,
            );
            try std.testing.expectEqualStrings(
                "during resume",
                request_value.messages[4].request.parts[0].user_prompt.text,
            );
            self.calls += 1;
            try zigai.model.emitCompletePart(sink, 0, .{ .text = "done" });
            return .{ .parts = &.{.{ .text = "done" }} };
        }
    };
    const Capture = struct {
        enqueued: usize = 0,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value == .enqueued_messages) self.enqueued += value.enqueued_messages.messages.len;
        }
    };
    var state = State{ .queue = &queue };
    var executions: u8 = 0;
    var tool = successfulTool(&executions);
    tool.execution = .requires_approval;
    const model = zigai.Model{
        .context = &state,
        .profile = .{ .supports_streaming = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    const agent = zigai.Agent{ .model = model, .tools = &.{tool} };
    var capture: Capture = .{};
    const sink = zigai.AgentStreamSink{ .context = &capture, .eventFn = Capture.event };
    var first = try agent.runUntilPauseStreamWithOptions(
        std.testing.allocator,
        "go",
        .{ .pending_messages = &queue },
        sink,
    );
    defer first.deinit();
    const state_json = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| paused.state_json,
    };
    var resume_queue = zigai.PendingMessageQueue.init(std.testing.allocator, threaded.io());
    defer resume_queue.deinit();
    try resume_queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "during resume" } }} }});
    var resumed = try agent.resumeRunStreamWithOptions(
        std.testing.allocator,
        state_json,
        &.{.{ .call_id = "approval", .action = .approve }},
        .{ .pending_messages = &resume_queue },
        sink,
    );
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
    try std.testing.expectEqual(@as(usize, 2), capture.enqueued);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "pending message queues close and discard accepted input on cancellation" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var queue = zigai.PendingMessageQueue.init(std.testing.allocator, threaded.io());
    defer queue.deinit();

    const State = struct {
        queue: *zigai.PendingMessageQueue,
        calls: usize = 0,

        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try self.queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "discard me" } }} }});
            return error.Cancelled;
        }
    };
    var state = State{ .queue = &queue };
    const agent = zigai.Agent{ .model = .{
        .context = &state,
        .profile = .{},
        .requestFn = State.request,
    } };
    try std.testing.expectError(
        error.Cancelled,
        agent.runWithOptions(std.testing.allocator, "go", .{ .pending_messages = &queue }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectError(
        zigai.Agent.Error.PendingMessageQueueClosed,
        queue.enqueue(&.{.{ .parts = &.{.{ .user_prompt = .{ .text = "late" } }} }}),
    );
    try std.testing.expectError(
        zigai.Agent.Error.PendingMessageQueueAlreadyUsed,
        agent.runWithOptions(std.testing.allocator, "again", .{ .pending_messages = &queue }),
    );
}

test "resuming mixed deferred calls handles every decision path" {
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "immediate", .name = "immediate", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "approval", .name = "approval", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "external", .name = "external", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "invalid", .name = "validated", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "Finished." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const results = request.messages[2].request.parts;
            try std.testing.expectEqual(@as(usize, 4), results.len);
            try std.testing.expectEqualStrings("executed", results[0].tool_return.content);
            try std.testing.expectEqualStrings("supplied", results[1].tool_return.content);
            try std.testing.expect(results[2].tool_return.is_error);
            try std.testing.expectEqualStrings("denied", results[2].tool_return.content);
            try std.testing.expect(results[3].tool_return.is_error);
            try std.testing.expect(std.mem.indexOf(u8, results[3].tool_return.content, "InvalidToolArguments") != null);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &calls }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
    };
    const Executor = struct {
        fn execute(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "executed");
        }
    };
    var unused: u8 = 0;
    const immediate = zigai.Tool{
        .definition = .{ .name = "immediate", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeFn = Executor.execute,
    };
    const approval = zigai.Tool{
        .definition = .{ .name = "approval", .description = "", .parameters_json_schema = "{}" },
        .execution = .requires_approval,
        .context = &unused,
        .executeFn = Executor.execute,
    };
    const external = zigai.Tool{
        .definition = .{ .name = "external", .description = "", .parameters_json_schema = "{}" },
        .execution = .external,
        .context = &unused,
        .executeFn = Executor.execute,
    };
    var validated = zigai.reflect.tool("validated", "", struct {
        fn execute(args: struct { value: u8 }) !u8 {
            return args.value;
        }
    }.execute);
    validated.execution = .requires_approval;
    validated.max_retries = 1;
    const tools = [_]zigai.Tool{ immediate, approval, external, validated };
    const agent = zigai.Agent{ .model = scripted.model(), .tools = &tools };
    var first = try agent.runUntilPause(std.testing.allocator, "Run mixed calls.");
    defer first.deinit();
    const state = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| state: {
            try std.testing.expectEqual(@as(usize, 2), paused.calls.len);
            break :state paused.state_json;
        },
    };
    try std.testing.expectError(zigai.Agent.Error.UnexpectedDeferredToolDecision, agent.resumeRun(
        std.testing.allocator,
        state,
        &.{
            .{ .call_id = "approval", .action = .result, .content = "supplied" },
            .{ .call_id = "approval", .action = .approve },
        },
    ));
    var resumed = try agent.resumeRun(std.testing.allocator, state, &.{
        .{ .call_id = "approval", .action = .result, .content = "supplied" },
        .{ .call_id = "external", .action = .deny, .content = "denied" },
    });
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
}

test "ordered tool policies persist dynamic approval and transformed arguments" {
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "policy-call", .name = "policy", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "Finished." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) return;
            const result = request.messages[2].request.parts[0].tool_return;
            try std.testing.expectEqualStrings("validated", result.content);
            try std.testing.expect(!result.is_error);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &calls }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
    };
    const State = struct {
        prepare_calls: usize = 0,
        arguments_calls: usize = 0,
        approval_calls: usize = 0,
        call_calls: usize = 0,
        return_calls: usize = 0,

        fn apply(context: *anyopaque, allocator: std.mem.Allocator, event: zigai.ToolPolicyEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .prepare => |prepared| {
                    self.prepare_calls += 1;
                    try std.testing.expect(prepared.run.messages.len > 0);
                },
                .arguments => |arguments| {
                    self.arguments_calls += 1;
                    try std.testing.expectEqual(@as(usize, 2), arguments.context.run.messages.len);
                    try std.testing.expectEqual(@as(u8, 9), arguments.context.run.dependency(u8).?.*);
                    arguments.arguments_json = try allocator.dupe(u8, "{\"value\":2}");
                },
                .approval => |approval| {
                    self.approval_calls += 1;
                    try std.testing.expectEqualStrings("{\"value\":2}", approval.arguments_json);
                    approval.execution = .requires_approval;
                },
                .call => |call| {
                    self.call_calls += 1;
                    try std.testing.expect(call.context.approved);
                    try std.testing.expectEqualStrings("{\"value\":2}", call.arguments_json);
                    call.output = .{ .content = "short-circuited" };
                },
                .return_value => |returned| {
                    self.return_calls += 1;
                    try std.testing.expectEqualStrings("{\"value\":2}", returned.arguments_json);
                    try std.testing.expectEqualStrings("short-circuited", returned.output.content);
                    returned.output.content = "validated";
                },
            }
        }
    };
    const Executor = struct {
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
            return error.ExecutorMustBeSkipped;
        }
    };
    var state: State = .{};
    var dependency: u8 = 9;
    const tool = zigai.Tool{
        .definition = .{ .name = "policy", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = Executor.execute,
    };
    const policy = zigai.ToolPolicy{ .context = &state, .applyFn = State.apply };
    const agent = zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .tool_policies = &.{policy},
        .dependencies = &dependency,
    };
    var first = try agent.runUntilPause(std.testing.allocator, "Run policy.");
    defer first.deinit();
    const paused = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |value| value,
    };
    try std.testing.expectEqual(@as(usize, 1), paused.calls.len);
    try std.testing.expectEqualStrings("{\"value\":2}", paused.calls[0].arguments_json);
    var resumed = try agent.resumeRun(std.testing.allocator, paused.state_json, &.{.{
        .call_id = "policy-call",
        .action = .approve,
    }});
    defer resumed.deinit();
    try std.testing.expect(resumed == .complete);
    try std.testing.expectEqual(@as(usize, 3), state.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), state.arguments_calls);
    try std.testing.expectEqual(@as(usize, 1), state.approval_calls);
    try std.testing.expectEqual(@as(usize, 1), state.call_calls);
    try std.testing.expectEqual(@as(usize, 1), state.return_calls);
}

test "tool argument and return policies share the per-tool retry budget" {
    const call = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "retry", .name = "retry", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &call },
            .{ .parts = &call },
            .{ .parts = &call },
            .{ .parts = &final },
        },
    };
    const State = struct {
        argument_retries: usize = 0,
        return_retries: usize = 0,
        executions: usize = 0,

        fn policy(context: *anyopaque, _: std.mem.Allocator, event: zigai.ToolPolicyEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .arguments => |arguments| if (arguments.context.retry_number == 0) {
                    self.argument_retries += 1;
                    arguments.retry_message = "Fix the arguments.";
                },
                .return_value => |returned| if (returned.context.retry_number == 1) {
                    self.return_retries += 1;
                    returned.retry_message = "Return a better result.";
                } else {
                    returned.output.content = "accepted";
                },
                else => {},
            }
        }

        fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.executions += 1;
            return allocator.dupe(u8, "raw");
        }
    };
    var state: State = .{};
    const tool = zigai.Tool{
        .definition = .{ .name = "retry", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = State.execute,
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .tool_policies = &.{.{ .context = &state, .applyFn = State.policy }},
    }).run(std.testing.allocator, "Retry.");
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(usize, 1), state.argument_retries);
    try std.testing.expectEqual(@as(usize, 1), state.return_retries);
    try std.testing.expectEqual(@as(usize, 2), state.executions);
    const final_result = result.messages[result.messages.len - 2].request.parts[0].tool_return;
    try std.testing.expectEqualStrings("accepted", final_result.content);
}

test "agent tool policies run before capability policies" {
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqualStrings("base agent capability", request.tools[0].description);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final }},
        .inspectFn = Inspector.inspect,
    };
    const Policy = struct {
        suffix: []const u8,

        fn apply(context: *anyopaque, allocator: std.mem.Allocator, event: zigai.ToolPolicyEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .prepare => |prepared| prepared.tool.definition.description = try std.mem.concat(
                    allocator,
                    u8,
                    &.{ prepared.tool.definition.description, self.suffix },
                ),
                else => {},
            }
        }
    };
    var agent_policy = Policy{ .suffix = " agent" };
    var capability_policy = Policy{ .suffix = " capability" };
    var tool_context: u8 = 0;
    const tool = zigai.Tool{
        .definition = .{ .name = "demo", .description = "base", .parameters_json_schema = "{}" },
        .context = &tool_context,
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .tool_policies = &.{.{ .context = &agent_policy, .applyFn = Policy.apply }},
        .capabilities = &.{.{ .tool_policies = &.{.{
            .context = &capability_policy,
            .applyFn = Policy.apply,
        }} }},
    }).run(std.testing.allocator, "Prepare.");
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.output);
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

test "builtin web tools compose through capabilities and fail before unsupported requests" {
    const final = [_]zigai.model.Part{.{ .text = "Grounded." }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.builtin_tools.len);
            try std.testing.expectEqual(zigai.BuiltinToolKind.web_search, request.builtin_tools[0].kind());
        }
    };
    var supported = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final }},
        .profile = .{
            .builtin_tools = zigai.ModelProfile.BuiltinToolSet.initMany(&.{.web_search}),
        },
        .inspectFn = Inspector.inspect,
    };
    const search_tools = [_]zigai.BuiltinTool{.{ .web_search = .{} }};
    var result = try (zigai.Agent{
        .model = supported.model(),
        .capabilities = &.{.{ .builtin_tools = &search_tools }},
    }).run(std.testing.allocator, "Search.");
    defer result.deinit();
    try std.testing.expectEqualStrings("Grounded.", result.output);

    var unsupported = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{
            .builtin_tools = zigai.ModelProfile.BuiltinToolSet.initMany(&.{.web_search}),
        },
    };
    const fetch_tools = [_]zigai.BuiltinTool{.{ .web_fetch = .{} }};
    try std.testing.expectError(
        zigai.Agent.Error.ModelDoesNotSupportWebFetch,
        (zigai.Agent{ .model = unsupported.model(), .builtin_tools = &fetch_tools }).run(std.testing.allocator, "Fetch."),
    );
    try std.testing.expectEqual(@as(usize, 0), unsupported.request_count);

    const duplicates = [_]zigai.BuiltinTool{
        .{ .web_search = .{} },
        .{ .web_search = .{} },
    };
    try std.testing.expectError(
        zigai.Agent.Error.DuplicateBuiltinTool,
        (zigai.Agent{ .model = supported.model(), .builtin_tools = &duplicates }).run(std.testing.allocator, "Search."),
    );
}

test "rich prompt parts are copied and capability-checked before requests" {
    const final = [_]zigai.model.Part{.{ .text = "Seen." }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.messages.len);
            try std.testing.expectEqual(@as(usize, 2), request.messages[0].request.parts.len);
            try std.testing.expectEqualSlices(u8, "png", request.messages[0].request.parts[0].user_prompt.image.source.bytes);
            try std.testing.expectEqualStrings("Describe it.", request.messages[0].request.parts[1].user_prompt.text);
            try std.testing.expectEqualStrings("camera", request.messages[0].request.parts[0].user_prompt.image.metadata[0].value);
        }
    };
    var supported = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final }},
        .profile = .{
            .content_types = zigai.ModelProfile.ContentTypeSet.initMany(&.{.image}),
        },
        .provider_name = "openai",
        .inspectFn = Inspector.inspect,
    };
    const image = [_]zigai.PromptPart{.{ .image = .{
        .source = .{ .bytes = "png" },
        .media_type = "image/png",
        .metadata = &.{.{ .key = "source", .value = "camera" }},
    } }};
    var result = try (zigai.Agent{ .model = supported.model() }).runWithOptions(
        std.testing.allocator,
        "Describe it.",
        .{ .prompt_parts = &image },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("camera", result.messages[0].request.parts[0].user_prompt.image.metadata[0].value);

    var unsupported = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .content_types = zigai.ModelProfile.ContentTypeSet.initMany(&.{.image}) },
        .provider_name = "openai",
    };
    const audio = [_]zigai.PromptPart{.{ .audio = .{
        .source = .{ .bytes = "mp3" },
        .media_type = "audio/mpeg",
    } }};
    try std.testing.expectError(
        zigai.Agent.Error.ModelDoesNotSupportAudio,
        (zigai.Agent{ .model = unsupported.model() }).runWithOptions(
            std.testing.allocator,
            "Listen.",
            .{ .prompt_parts = &audio },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), unsupported.request_count);

    const wrong_provider = [_]zigai.PromptPart{.{ .image = .{
        .source = .{ .provider_file = .{ .id = "file_123", .provider = "anthropic" } },
        .media_type = "image/png",
    } }};
    try std.testing.expectError(
        zigai.Agent.Error.ProviderFileProviderMismatch,
        (zigai.Agent{ .model = supported.model() }).runWithOptions(
            std.testing.allocator,
            "Describe it.",
            .{ .prompt_parts = &wrong_provider },
        ),
    );

    const local_url = [_]zigai.PromptPart{.{ .image = .{
        .source = .{ .url = "https://127.0.0.1/private.png" },
        .media_type = "image/png",
    } }};
    try std.testing.expectError(
        zigai.Agent.Error.LocalNetworkUrlForbidden,
        (zigai.Agent{ .model = supported.model() }).runWithOptions(
            std.testing.allocator,
            "Describe it.",
            .{ .prompt_parts = &local_url },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), supported.request_count);

    const invalid_history = [_]zigai.Message{.{
        .response = .{ .parts = &.{.{ .thinking = .{ .content = "private" } }} },
    }};
    try std.testing.expectError(
        zigai.Agent.Error.ModelDoesNotSupportThinking,
        (zigai.Agent{ .model = supported.model() }).runWithOptions(
            std.testing.allocator,
            "Continue.",
            .{ .message_history = &invalid_history },
        ),
    );
}

test "typed tool results inject provider-neutral follow-up messages" {
    const Lookup = struct {
        const Result = struct { city: []const u8, temperature_c: i32 };

        fn call(args: struct { city: []const u8 }) !zigai.ToolReturn(Result) {
            return .{
                .value = .{ .city = args.city, .temperature_c = 31 },
                .follow_up_messages = &.{.{
                    .parts = &.{.{ .user_prompt = .{ .text = "The reading came from the roof sensor." } }},
                    .metadata = &.{.{ .key = "sensor", .value = "roof" }},
                }},
            };
        }
    };
    const call_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "call_1",
        .name = "lookup",
        .arguments_json = "{\"city\":\"Madrid\"}",
    } }};
    const final_parts = [_]zigai.Part{.{ .text = "It is 31 C from the roof sensor." }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            try std.testing.expect(request.tools[0].return_json_schema != null);
            if (index != 1) return;
            try std.testing.expectEqual(@as(usize, 4), request.messages.len);
            try std.testing.expectEqualStrings(
                "{\"city\":\"Madrid\",\"temperature_c\":31}",
                request.messages[2].request.parts[0].tool_return.content,
            );
            try std.testing.expectEqualStrings("The reading came from the roof sensor.", request.messages[3].request.parts[0].user_prompt.text);
            try std.testing.expectEqualStrings("roof", request.messages[3].request.metadata[0].value);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &call_parts },
            .{ .parts = &final_parts },
        },
        .inspectFn = Inspector.inspect,
    };
    const lookup = zigai.reflect.tool("lookup", "Look up a temperature.", Lookup.call);
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{lookup},
    }).run(std.testing.allocator, "Check Madrid.");
    defer result.deinit();
    try std.testing.expectEqualStrings("It is 31 C from the roof sensor.", result.output);
    try std.testing.expectEqual(@as(usize, 5), result.messages.len);

    var invalid_script = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call_parts }} };
    var unused: u8 = 0;
    const invalid_tool = zigai.Tool{
        .definition = .{
            .name = "lookup",
            .description = "Return an invalid follow-up.",
            .parameters_json_schema = "{\"type\":\"object\"}",
        },
        .context = &unused,
        .executeOutputFn = struct {
            fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !zigai.ToolOutput {
                return .{
                    .content = "{}",
                    .follow_up_messages = &.{.{
                        .parts = &.{
                            .{ .system_prompt = "not allowed" },
                            .{ .tool_return = .{ .call_id = "id", .name = "name", .content = "result" } },
                        },
                    }},
                };
            }
        }.execute,
    };
    try std.testing.expectError(
        zigai.Agent.Error.InvalidToolFollowUpMessage,
        (zigai.Agent{ .model = invalid_script.model(), .tools = &.{invalid_tool} }).run(
            std.testing.allocator,
            "Check Madrid.",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), invalid_script.request_count);
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
            try std.testing.expectEqualStrings("Stable system prompt.", request.messages[0].request.parts[0].system_prompt);
            try std.testing.expectEqualStrings("Earlier answer", request.messages[1].response.parts[0].text);
            try std.testing.expectEqualStrings("old-call", request.messages[1].response.parts[1].tool_call.id);
            try std.testing.expect(request.messages[2].request.parts[0].tool_return.is_error);
            try std.testing.expectEqualStrings("Zig allocators", request.messages[3].request.parts[0].user_prompt.text);
        }
    };

    const history = [_]zigai.model.Message{
        .{ .response = .{ .parts = &.{
            .{ .text = "Earlier answer" },
            .{ .tool_call = .{ .id = "old-call", .name = "lookup", .arguments_json = "{}" } },
        } } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "old-call",
            .name = "lookup",
            .content = "unavailable",
            .is_error = true,
        } }} } },
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
    try std.testing.expectEqualStrings("old-call", result.messages[1].response.parts[1].tool_call.id);
    try std.testing.expectEqualStrings("unavailable", result.messages[2].request.parts[0].tool_return.content);
    try std.testing.expectEqualStrings(
        "Use plain language.\n\nAnswer developers about Zig allocators.\n\nKeep it short.",
        result.messages[3].request.instructions.?,
    );

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
        .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "earlier" } }} },
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
    try std.testing.expectEqualStrings("earlier", result.messages[0].request.parts[0].user_prompt.text);
}

test "context budgets compact history before requests and preserve callback control" {
    const State = struct {
        estimates: usize = 0,
        compactions: usize = 0,
        request_messages: usize = 0,
        saw_settings: bool = false,

        fn estimate(context: *anyopaque, input: zigai.context_budget.Input, _: zigai.context_budget.ByteUsage) u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.estimates += 1;
            self.saw_settings = input.settings.max_tokens == 20;
            return @intCast(input.messages.len * 10);
        }

        fn compact(
            context: *anyopaque,
            _: std.mem.Allocator,
            event: zigai.ContextOverflowEvent,
        ) ![]const zigai.Message {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.compactions += 1;
            try std.testing.expectEqual(zigai.ContextOverflow.Kind.input_tokens, event.overflow.kind);
            try std.testing.expectEqual(@as(u64, 30), event.snapshot.estimated_input_tokens);
            return event.input.messages[event.input.messages.len - 1 ..];
        }

        fn request(context: *anyopaque, _: std.mem.Allocator, request_value: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.request_messages = request_value.messages.len;
            return .{ .parts = &.{.{ .text = "done" }} };
        }
    };
    var state: State = .{};
    const budget = zigai.ContextBudget{
        .max_total_tokens = 35,
        .estimator = .{ .context = &state, .estimateFn = State.estimate },
        .on_overflow = .{ .context = &state, .compactFn = State.compact },
    };
    const previous = [_]zigai.Message{
        .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "old" } }} } },
        .{ .response = .{ .parts = &.{.{ .text = "old answer" }} } },
    };
    var result = try (zigai.Agent{
        .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
        .model_settings = .{ .max_tokens = 20 },
        .context_budget = budget,
    }).runWithOptions(std.testing.allocator, "new", .{ .message_history = &previous });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), state.estimates);
    try std.testing.expectEqual(@as(usize, 1), state.compactions);
    try std.testing.expectEqual(@as(usize, 1), state.request_messages);
    try std.testing.expect(state.saw_settings);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
}

test "context budgets reject every byte and token boundary before requesting" {
    const State = struct {
        requests: usize = 0,

        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests += 1;
            return .{ .parts = &.{.{ .text = "done" }} };
        }

        fn reject(_: *anyopaque, _: std.mem.Allocator, _: zigai.ContextOverflowEvent) ![]const zigai.Message {
            return error.ContextRejected;
        }

        fn unchanged(_: *anyopaque, _: std.mem.Allocator, event: zigai.ContextOverflowEvent) ![]const zigai.Message {
            return event.input.messages;
        }
    };
    var state: State = .{};
    const selected_model = zigai.Model{ .context = &state, .profile = .{
        .supports_tools = true,
        .supports_json_schema_output = true,
        .content_types = zigai.ModelProfile.ContentTypeSet.initMany(&.{.image}),
    }, .requestFn = State.request };
    try std.testing.expectError(zigai.Agent.Error.ContextPromptTooLarge, (zigai.Agent{
        .model = selected_model,
        .context_budget = .{ .max_prompt_bytes = 0 },
    }).run(std.testing.allocator, "x"));
    const tool = zigai.Tool{
        .definition = .{ .name = "tool", .description = "d", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = struct {
            fn execute(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
                return allocator.dupe(u8, "ok");
            }
        }.execute,
    };
    try std.testing.expectError(zigai.Agent.Error.ContextToolsTooLarge, (zigai.Agent{
        .model = selected_model,
        .tools = &.{tool},
        .context_budget = .{ .max_tool_bytes = 0 },
    }).run(std.testing.allocator, ""));
    try std.testing.expectError(zigai.Agent.Error.ContextSchemaTooLarge, (zigai.Agent{
        .model = selected_model,
        .output = .{ .json_schema = .{ .name = "x", .schema = "{}" } },
        .context_budget = .{ .max_schema_bytes = 0 },
    }).run(std.testing.allocator, ""));
    try std.testing.expectError(zigai.Agent.Error.ContextMediaTooLarge, (zigai.Agent{
        .model = selected_model,
        .context_budget = .{ .max_media_bytes = 0 },
    }).runWithOptions(std.testing.allocator, "", .{ .prompt_parts = &.{.{ .image = .{
        .source = .{ .bytes = "png" },
        .media_type = "image/png",
    } }} }));
    try std.testing.expectError(zigai.Agent.Error.ContextTokenLimitExceeded, (zigai.Agent{
        .model = selected_model,
        .model_settings = .{ .max_tokens = 11 },
        .context_budget = .{ .max_total_tokens = 10 },
    }).run(std.testing.allocator, ""));
    try std.testing.expectError(error.ContextRejected, (zigai.Agent{
        .model = selected_model,
        .context_budget = .{
            .max_prompt_bytes = 0,
            .on_overflow = .{ .context = &state, .compactFn = State.reject },
        },
    }).run(std.testing.allocator, "x"));
    try std.testing.expectError(zigai.Agent.Error.ContextPromptTooLarge, (zigai.Agent{
        .model = selected_model,
        .context_budget = .{
            .max_prompt_bytes = 0,
            .on_overflow = .{ .context = &state, .compactFn = State.unchanged },
        },
    }).run(std.testing.allocator, "x"));
    var overridden = try (zigai.Agent{
        .model = selected_model,
        .context_budget = .{ .max_prompt_bytes = 0 },
    }).runWithOptions(std.testing.allocator, "x", .{
        .context_budget = .{ .max_prompt_bytes = 1 },
    });
    defer overridden.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.requests);
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
    const schema: zigai.OutputSpec = .{ .json_schema = .{
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
            try std.testing.expectEqualStrings("{\"answer\":\"no\"}", request.messages[1].response.parts[0].text);
            try std.testing.expectEqualStrings(
                "The previous response did not match the required output schema. " ++
                    "Return only valid JSON matching the schema.",
                request.messages[2].request.parts[0].retry_prompt,
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

test "native output unions use one provider schema and validate every alternative" {
    const choices = [_]zigai.OutputChoice{
        .{
            .name = "answer",
            .schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"integer\"}}," ++
                "\"required\":[\"answer\"],\"additionalProperties\":false}",
        },
        .{
            .name = "refusal",
            .schema = "{\"type\":\"object\",\"properties\":{\"refusal\":{\"type\":\"string\"}}," ++
                "\"required\":[\"refusal\"],\"additionalProperties\":false}",
        },
    };
    const parts = [_]zigai.model.Part{.{ .text = "{\"refusal\":\"unsafe\"}" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            const format = request.output.json_schema;
            try std.testing.expectEqualStrings("result", format.name);
            try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"anyOf\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"answer\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"refusal\"") != null);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_json_schema_output = true },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .native = .{ .choices = &choices, .name = "result" } },
        .validate_output_locally = true,
    }).run(std.testing.allocator, "answer or refuse");
    defer result.deinit();
    try std.testing.expectEqualStrings(parts[0].text, result.output);
}

test "prompted output falls back to text and always retries invalid JSON" {
    const choices = [_]zigai.OutputChoice{.{
        .name = "answer",
        .schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"integer\"}}," ++
            "\"required\":[\"answer\"],\"additionalProperties\":false}",
    }};
    const invalid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":\"no\"}" }};
    const valid_parts = [_]zigai.model.Part{.{ .text = "{\"answer\":42}" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(zigai.model.OutputFormat.text, request.output);
            try std.testing.expectEqual(@as(usize, 1), request.instructions.len);
            try std.testing.expect(std.mem.indexOf(u8, request.instructions[0], "JSON Schema:") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.instructions[0], "\"answer\"") != null);
            if (index == 1) try std.testing.expectEqual(@as(usize, 3), request.messages.len);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &invalid_parts }, .{ .parts = &valid_parts } },
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_system_messages = true },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .prompted = .{ .output = .{ .choices = &choices, .description = "An integer answer." } } },
        .max_output_retries = 1,
    }).run(std.testing.allocator, "answer");
    defer result.deinit();
    try std.testing.expectEqualStrings(valid_parts[0].text, result.output);
    try std.testing.expectEqual(@as(usize, 2), result.model_requests);
}

test "prompted output uses JSON-object mode and rejects unsupported models" {
    const choices = [_]zigai.OutputChoice{.{ .name = "answer", .schema = "{\"type\":\"object\"}" }};
    const parts = [_]zigai.model.Part{.{ .text = "{}" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(zigai.model.OutputFormat.json_object, request.output);
        }
    };
    var supported = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_system_messages = true, .supports_json_object_output = true },
    };
    var result = try (zigai.Agent{
        .model = supported.model(),
        .output = .{ .prompted = .{ .output = .{ .choices = &choices } } },
    }).run(std.testing.allocator, "answer");
    defer result.deinit();

    var unsupported = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_system_messages = false },
    };
    try std.testing.expectError(zigai.Agent.Error.ModelDoesNotSupportPromptedOutput, (zigai.Agent{
        .model = unsupported.model(),
        .output = .{ .prompted = .{ .output = .{ .choices = &choices } } },
    }).run(std.testing.allocator, "answer"));
    try std.testing.expectEqual(@as(usize, 0), unsupported.request_count);
}

test "tool output exposes one tool per choice and returns the selected union branch" {
    const choices = [_]zigai.OutputChoice{
        .{ .name = "answer", .description = "Return an answer.", .schema = "{\"type\":\"object\"}" },
        .{ .name = "refusal", .schema = "{\"type\":\"string\"}" },
    };
    const calls = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "output-1",
        .name = "refusal",
        .arguments_json = "{\"value\":\"unsafe\"}",
    } }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(zigai.model.OutputFormat.text, request.output);
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("answer", request.tools[0].name);
            try std.testing.expectEqualStrings("Return an answer.", request.tools[0].description);
            try std.testing.expectEqualStrings("refusal", request.tools[1].name);
            try std.testing.expect(std.mem.indexOf(
                u8,
                request.tools[1].parameters_json_schema,
                "\"value\"",
            ) != null);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &calls }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_streaming = true },
    };
    const Capture = struct {
        results: usize = 0,
        finals: usize = 0,
        name: ?[]const u8 = null,
        value: ?[]const u8 = null,

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .function_tool_result => self.results += 1,
                .final_result => |final| {
                    self.finals += 1;
                    self.name = final.output_name;
                    self.value = switch (final.structured_output.?) {
                        .string => |text_value| text_value,
                        else => return error.ExpectedStringSnapshot,
                    };
                },
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
    }).runStream(std.testing.allocator, "answer or refuse", .{
        .context = &capture,
        .eventFn = Capture.event,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("\"unsafe\"", result.output);
    try std.testing.expectEqualStrings("refusal", result.output_name.?);
    try std.testing.expectEqual(@as(usize, 3), result.messages.len);
    try std.testing.expectEqualStrings("Final output accepted.", result.messages[2].request.parts[0].tool_return.content);
    try std.testing.expectEqual(@as(usize, 1), capture.results);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
    try std.testing.expectEqualStrings("refusal", capture.name.?);
    try std.testing.expectEqualStrings("unsafe", capture.value.?);
}

test "output functions receive run context and can request a model retry" {
    const State = struct {
        calls: usize = 0,

        fn call(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.OutputRunContext,
            arguments: []const u8,
        ) !zigai.OutputFunctionResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, self.calls), run_context.model_requests);
            try std.testing.expectEqual(@as(u32, 7), run_context.dependency(u32).?.*);
            if (std.mem.indexOf(u8, arguments, "-1") != null) return .{ .retry = "Use a positive value." };
            return .{ .output = try allocator.dupe(u8, "accepted") };
        }
    };
    var state: State = .{};
    var dependency: u32 = 7;
    const choices = [_]zigai.OutputChoice{.{
        .name = "finish",
        .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
            "\"required\":[\"value\"],\"additionalProperties\":false}",
        .function = .{ .context = &state, .callFn = State.call },
    }};
    const first = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "finish-1",
        .name = "finish",
        .arguments_json = "{\"value\":-1}",
    } }};
    const second = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "finish-2",
        .name = "finish",
        .arguments_json = "{\"value\":2}",
    } }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) return;
            try std.testing.expectEqual(@as(usize, 3), request.messages.len);
            const retry = request.messages[2].request.parts[0].tool_return;
            try std.testing.expect(retry.isError());
            try std.testing.expectEqualStrings("Use a positive value.", retry.content);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &first }, .{ .parts = &second } },
        .inspectFn = Inspector.inspect,
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .dependencies = &dependency,
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .max_output_retries = 1,
    }).run(std.testing.allocator, "finish");
    defer result.deinit();
    try std.testing.expectEqualStrings("accepted", result.output);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "output validators receive run context retry and transform in order" {
    const State = struct {
        first_calls: usize = 0,
        second_calls: usize = 0,

        fn first(
            context: *anyopaque,
            _: std.mem.Allocator,
            run_context: zigai.OutputRunContext,
            output_name: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.first_calls += 1;
            try std.testing.expect(output_name == null);
            try std.testing.expect(!run_context.partial_output);
            try std.testing.expectEqual(@as(u32, 9), run_context.dependency(u32).?.*);
            try std.testing.expectEqual(self.first_calls, run_context.model_requests);
            try std.testing.expect(run_context.messages[run_context.messages.len - 1] == .response);
            if (std.mem.indexOf(u8, output_json, ":1") != null) {
                return .{ .retry = "Value must be greater than one." };
            }
            return .{ .output = output_json };
        }

        fn second(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.second_calls += 1;
            try std.testing.expectEqualStrings("{\"value\":2}", output_json);
            return .{ .output = try allocator.dupe(u8, "{\"value\":3}") };
        }
    };
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) return;
            try std.testing.expectEqualStrings(
                "Value must be greater than one.",
                request.messages[2].request.parts[0].retry_prompt,
            );
        }
    };
    const schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
        "\"required\":[\"value\"],\"additionalProperties\":false}";
    const first = [_]zigai.Part{.{ .text = "{\"value\":1}" }};
    const second = [_]zigai.Part{.{ .text = "{\"value\":2}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &first }, .{ .parts = &second } },
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_json_schema_output = true },
    };
    var dependency: u32 = 9;
    var state: State = .{};
    const validators = [_]zigai.OutputValidator{
        .{ .context = &state, .validateFn = State.first },
        .{ .context = &state, .validateFn = State.second },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .dependencies = &dependency,
        .output = .{ .json_schema = .{ .name = "answer", .schema = schema } },
        .output_validators = &validators,
        .validate_output_locally = true,
        .max_output_retries = 1,
    }).run(std.testing.allocator, "answer");
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"value\":3}", result.output);
    try std.testing.expectEqual(@as(usize, 2), state.first_calls);
    try std.testing.expectEqual(@as(usize, 1), state.second_calls);
}

test "tool output validators receive the selected name and transform output" {
    const State = struct {
        calls: usize = 0,
        fn validate(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.OutputRunContext,
            output_name: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("finish", output_name.?);
            try std.testing.expect(!run_context.partial_output);
            try std.testing.expectEqualStrings("{\"value\":1}", output_json);
            if (self.calls == 1) return .{ .retry = "Try the output again." };
            return .{ .output = try allocator.dupe(u8, "{\"value\":2}") };
        }
    };
    const choices = [_]zigai.OutputChoice{.{
        .name = "finish",
        .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
            "\"required\":[\"value\"],\"additionalProperties\":false}",
    }};
    const first_call = [_]zigai.Part{.{ .tool_call = .{
        .id = "finish-1",
        .name = "finish",
        .arguments_json = "{\"value\":1}",
    } }};
    const second_call = [_]zigai.Part{.{ .tool_call = .{
        .id = "finish-2",
        .name = "finish",
        .arguments_json = "{\"value\":1}",
    } }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) return;
            const retry = request.messages[2].request.parts[0].tool_return;
            try std.testing.expect(retry.isError());
            try std.testing.expectEqualStrings("Try the output again.", retry.content);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &first_call }, .{ .parts = &second_call } },
        .inspectFn = Inspector.inspect,
    };
    var state: State = .{};
    const validators = [_]zigai.OutputValidator{.{ .context = &state, .validateFn = State.validate }};
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .output_validators = &validators,
        .max_output_retries = 1,
    }).run(std.testing.allocator, "finish");
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"value\":2}", result.output);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "thrown tool output validator errors abort and emit lifecycle failure" {
    const Callback = struct {
        fn validate(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            _: []const u8,
        ) !zigai.OutputValidatorResult {
            return error.ValidatorBackendFailed;
        }
    };
    const Hook = struct {
        failures: usize = 0,
        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .output_validation_error => |event_value| {
                    try std.testing.expectEqual(error.ValidatorBackendFailed, event_value.failure);
                    try std.testing.expect(!event_value.will_retry);
                    self.failures += 1;
                },
                else => {},
            }
        }
    };
    const choices = [_]zigai.OutputChoice{.{ .name = "finish", .schema = "{\"type\":\"object\"}" }};
    const call = [_]zigai.Part{.{ .tool_call = .{
        .id = "finish-1",
        .name = "finish",
        .arguments_json = "{}",
    } }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call }} };
    var context: u8 = 0;
    var hook: Hook = .{};
    try std.testing.expectError(error.ValidatorBackendFailed, (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .output_validators = &.{.{ .context = &context, .validateFn = Callback.validate }},
        .hooks = &.{.{ .context = &hook, .eventFn = Hook.event }},
    }).run(std.testing.allocator, "finish"));
    try std.testing.expectEqual(@as(usize, 1), hook.failures);
}

test "output validator retry limits and thrown errors stay distinct" {
    const Callbacks = struct {
        fn retry(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            _: []const u8,
        ) !zigai.OutputValidatorResult {
            return .{ .retry = "again" };
        }

        fn fail(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            _: []const u8,
        ) !zigai.OutputValidatorResult {
            return error.ValidatorBackendFailed;
        }
    };
    var state: u8 = 0;
    const parts = [_]zigai.Part{.{ .text = "answer" }};
    var exhausted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.OutputRetriesExceeded, (zigai.Agent{
        .model = exhausted.model(),
        .output_validators = &.{.{ .context = &state, .validateFn = Callbacks.retry }},
        .max_output_retries = 0,
    }).run(std.testing.allocator, "answer"));

    var oversized = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.ToolResultTooLarge, (zigai.Agent{
        .model = oversized.model(),
        .output_validators = &.{.{ .context = &state, .validateFn = Callbacks.retry }},
        .max_output_retries = 1,
        .tool_limits = .{ .max_result_bytes = 1 },
    }).run(std.testing.allocator, "answer"));

    var failed = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(error.ValidatorBackendFailed, (zigai.Agent{
        .model = failed.model(),
        .output_validators = &.{.{ .context = &state, .validateFn = Callbacks.fail }},
    }).run(std.testing.allocator, "answer"));
    try std.testing.expectEqual(@as(usize, 1), failed.request_count);
}

test "capability output validators run before typed decoding" {
    const Answer = struct { answer: u32 };
    const Callback = struct {
        fn validate(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            try std.testing.expectEqualStrings("{\"answer\":41}", output_json);
            return .{ .output = try allocator.dupe(u8, "{\"answer\":42}") };
        }
    };
    const parts = [_]zigai.Part{.{ .text = "{\"answer\":41}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    var context: u8 = 0;
    const validator = zigai.OutputValidator{ .context = &context, .validateFn = Callback.validate };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .capabilities = &.{.{ .output_validators = &.{validator} }},
    }).runTyped(Answer, std.testing.allocator, "answer");
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 42), result.output.answer);
}

test "structured output is revalidated after validator transformation" {
    const Callback = struct {
        fn validate(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: ?[]const u8,
            _: []const u8,
        ) !zigai.OutputValidatorResult {
            return .{ .output = "{\"value\":\"invalid\"}" };
        }
    };
    const schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
        "\"required\":[\"value\"],\"additionalProperties\":false}";
    const parts = [_]zigai.Part{.{ .text = "{\"value\":1}" }};
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{ .supports_json_schema_output = true },
    };
    var context: u8 = 0;
    try std.testing.expectError(zigai.json_schema.Error.OutputSchemaValidationFailed, (zigai.Agent{
        .model = scripted.model(),
        .output = .{ .json_schema = .{ .name = "answer", .schema = schema } },
        .output_validators = &.{.{ .context = &context, .validateFn = Callback.validate }},
        .max_output_retries = 0,
    }).run(std.testing.allocator, "answer"));
}

test "output end strategies control tools emitted beside a final result" {
    const Runner = struct {
        fn run(strategy: zigai.OutputEndStrategy) !u8 {
            const choices = [_]zigai.OutputChoice{.{
                .name = "finish",
                .schema = "{\"type\":\"object\"}",
            }};
            const calls = [_]zigai.model.Part{
                .{ .tool_call = .{ .id = "before", .name = "tool", .arguments_json = "{}" } },
                .{ .tool_call = .{ .id = "finish", .name = "finish", .arguments_json = "{}" } },
                .{ .tool_call = .{ .id = "finish-again", .name = "finish", .arguments_json = "{}" } },
                .{ .tool_call = .{ .id = "after", .name = "tool", .arguments_json = "{}" } },
            };
            var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &calls }} };
            var executions: u8 = 0;
            const tool = successfulTool(&executions);
            var result = try (zigai.Agent{
                .model = scripted.model(),
                .tools = &.{tool},
                .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
                .end_strategy = strategy,
            }).run(std.testing.allocator, "finish");
            defer result.deinit();
            try std.testing.expectEqualStrings("{}", result.output);
            return executions;
        }
    };
    try std.testing.expectEqual(@as(u8, 0), try Runner.run(.early));
    try std.testing.expectEqual(@as(u8, 1), try Runner.run(.graceful));
    try std.testing.expectEqual(@as(u8, 2), try Runner.run(.exhaustive));
}

test "output function retries obey early ordering budgets and result limits" {
    const State = struct {
        fn retry(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: []const u8,
        ) !zigai.OutputFunctionResult {
            return .{ .retry = "retry" };
        }

        fn longRetry(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.output.RunContext,
            _: []const u8,
        ) !zigai.OutputFunctionResult {
            return .{ .retry = "too long" };
        }
    };
    var state: u8 = 0;
    const choices = [_]zigai.OutputChoice{
        .{
            .name = "retry_output",
            .schema = "{\"type\":\"object\"}",
            .function = .{ .context = &state, .callFn = State.retry },
        },
        .{ .name = "final_output", .schema = "{\"type\":\"object\"}" },
    };
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "retry", .name = "retry_output", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "final", .name = "final_output", .arguments_json = "{}" } },
    };
    var early = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &calls }} };
    var result = try (zigai.Agent{
        .model = early.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .end_strategy = .early,
        .max_output_retries = 1,
    }).run(std.testing.allocator, "finish");
    defer result.deinit();
    try std.testing.expectEqualStrings("{}", result.output);
    try std.testing.expect(result.messages[2].request.parts[0].tool_return.isError());

    const long_choice = [_]zigai.OutputChoice{.{
        .name = "retry_output",
        .schema = "{\"type\":\"object\"}",
        .function = .{ .context = &state, .callFn = State.longRetry },
    }};
    const long_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "long",
        .name = "retry_output",
        .arguments_json = "{}",
    } }};
    inline for (.{ zigai.OutputEndStrategy.early, zigai.OutputEndStrategy.graceful }) |strategy| {
        var oversized = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &long_call }} };
        try std.testing.expectError(zigai.Agent.Error.ToolResultTooLarge, (zigai.Agent{
            .model = oversized.model(),
            .output = .{ .tool = .{ .output = .{ .choices = &long_choice } } },
            .end_strategy = strategy,
            .max_output_retries = 1,
            .tool_limits = .{ .max_result_bytes = 1 },
        }).run(std.testing.allocator, "finish"));
    }

    var exhausted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &long_call }} };
    try std.testing.expectError(zigai.Agent.Error.OutputRetriesExceeded, (zigai.Agent{
        .model = exhausted.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &long_choice } } },
        .max_output_retries = 0,
    }).run(std.testing.allocator, "finish"));
}

test "tool output rejects missing calls invalid arguments and name conflicts" {
    const choices = [_]zigai.OutputChoice{.{
        .name = "tool",
        .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
            "\"required\":[\"value\"],\"additionalProperties\":false}",
    }};
    const text = [_]zigai.model.Part{.{ .text = "done" }};
    var missing = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &text }} };
    try std.testing.expectError(zigai.Agent.Error.OutputToolRequired, (zigai.Agent{
        .model = missing.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .max_output_retries = 0,
    }).run(std.testing.allocator, "finish"));

    const recovered_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "recovered",
        .name = "tool",
        .arguments_json = "{\"value\":1}",
    } }};
    var recovered = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &text }, .{ .parts = &recovered_call } },
    };
    var recovered_result = try (zigai.Agent{
        .model = recovered.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .max_output_retries = 1,
    }).run(std.testing.allocator, "finish");
    defer recovered_result.deinit();
    try std.testing.expectEqualStrings("{\"value\":1}", recovered_result.output);

    const invalid_call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "bad",
        .name = "tool",
        .arguments_json = "{\"value\":\"no\"}",
    } }};
    var invalid = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &invalid_call }} };
    try std.testing.expectError(zigai.json_schema.Error.OutputSchemaValidationFailed, (zigai.Agent{
        .model = invalid.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .max_output_retries = 0,
    }).run(std.testing.allocator, "finish"));

    var collision = zigai.testing.ScriptedModel{ .responses = &.{} };
    var calls: u8 = 0;
    const tool = successfulTool(&calls);
    try std.testing.expectError(zigai.Agent.Error.DuplicateToolName, (zigai.Agent{
        .model = collision.model(),
        .tools = &.{tool},
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
    }).run(std.testing.allocator, "finish"));
    try std.testing.expectEqual(@as(usize, 0), collision.request_count);

    var unsupported = zigai.testing.ScriptedModel{
        .responses = &.{},
        .profile = .{ .supports_tools = false },
    };
    try std.testing.expectError(zigai.Agent.Error.ModelDoesNotSupportTools, (zigai.Agent{
        .model = unsupported.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
    }).run(std.testing.allocator, "finish"));

    var malformed = zigai.testing.ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(zigai.Agent.Error.InvalidOutputSpec, (zigai.Agent{
        .model = malformed.model(),
        .output = .{ .tool = .{ .output = .{ .choices = &.{} } } },
    }).run(std.testing.allocator, "finish"));
    try std.testing.expectEqual(@as(usize, 0), malformed.request_count);
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
        snapshot_answer: ?[]const u8 = null,
        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .final_result => |event_value| {
                    self.finals += 1;
                    const snapshot = event_value.structured_output orelse return error.MissingStructuredSnapshot;
                    const object = switch (snapshot) {
                        .object => |item| item,
                        else => return error.ExpectedObjectSnapshot,
                    };
                    self.snapshot_answer = switch (object.get("answer") orelse return error.MissingSnapshotAnswer) {
                        .string => |item| item,
                        else => return error.ExpectedStringSnapshot,
                    };
                },
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
    try std.testing.expectEqualStrings("yes", capture.snapshot_answer.?);
}

test "structured streaming emits accumulated partially validated snapshots" {
    const State = struct {
        partial_validations: usize = 0,
        final_validations: usize = 0,
        raw_deltas: usize = 0,
        partials: usize = 0,

        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            try sink.emit(.{ .part_start = .{ .index = 0, .part = .{ .text = "" } } });
            try sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .text = .{ .content_delta = "{\"name\":\"Al" } },
            } });
            try sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .text = .{ .content_delta = "ice\",\"age\":4" } },
            } });
            try sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .text = .{ .content_delta = "2}" } },
            } });
            const parts = &struct {
                const value = [_]zigai.Part{.{ .text = "{\"name\":\"Alice\",\"age\":42}" }};
            }.value;
            try sink.emit(.{ .part_end = .{ .index = 0, .part = parts[0] } });
            try sink.emit(.{ .usage = .{} });
            return .{ .parts = parts };
        }

        fn validate(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.output.RunContext,
            output_name: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(output_name == null);
            if (run_context.partial_output) {
                self.partial_validations += 1;
                try std.testing.expect(run_context.messages[run_context.messages.len - 1] == .request);
                return switch (self.partial_validations) {
                    1 => .{ .output = try allocator.dupe(u8, "{\"name\":\"A\"}") },
                    2 => .{ .retry = "wait for another snapshot" },
                    else => .{ .output = output_json },
                };
            }
            self.final_validations += 1;
            try std.testing.expect(run_context.messages[run_context.messages.len - 1] == .response);
            return .{ .output = output_json };
        }

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model => |model_event| if (model_event == .part_delta) {
                    self.raw_deltas += 1;
                },
                .partial_output => |partial| {
                    self.partials += 1;
                    try std.testing.expectEqual(
                        if (self.partials == 1) @as(usize, 1) else 3,
                        self.raw_deltas,
                    );
                    try std.testing.expect(partial.output_name == null);
                    const object = switch (partial.structured_output orelse return error.MissingPartialSnapshot) {
                        .object => |item| item,
                        else => return error.ExpectedObjectSnapshot,
                    };
                    if (self.partials == 1) {
                        try std.testing.expectEqualStrings("{\"name\":\"A\"}", partial.output);
                        try std.testing.expectEqualStrings("A", object.get("name").?.string);
                    } else {
                        try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":42}", partial.output);
                        try std.testing.expectEqual(@as(i64, 42), object.get("age").?.integer);
                    }
                },
                else => {},
            }
        }
    };
    const schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}}," ++
        "\"required\":[\"name\",\"age\"],\"additionalProperties\":false}";
    var state: State = .{};
    const validators = [_]zigai.OutputValidator{.{ .context = &state, .validateFn = State.validate }};
    const model = zigai.Model{
        .context = &state,
        .profile = .{ .supports_json_schema_output = true, .supports_streaming = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    var result = try (zigai.Agent{
        .model = model,
        .output = .{ .json_schema = .{ .name = "person", .schema = schema } },
        .output_validators = &validators,
        .validate_output_locally = true,
    }).runStream(std.testing.allocator, "answer", .{ .context = &state, .eventFn = State.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":42}", result.output);
    try std.testing.expectEqual(@as(usize, 3), state.partial_validations);
    try std.testing.expectEqual(@as(usize, 1), state.final_validations);
    try std.testing.expectEqual(@as(usize, 3), state.raw_deltas);
    try std.testing.expectEqual(@as(usize, 2), state.partials);
}

test "tool output functions receive partial and final streaming contexts" {
    const State = struct {
        function_partials: usize = 0,
        function_finals: usize = 0,
        validator_partials: usize = 0,
        validator_finals: usize = 0,
        streamed_partials: usize = 0,

        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            const initial = zigai.Part{ .tool_call = .{
                .id = "finish-1",
                .name = "finish",
                .arguments_json = "",
            } };
            try sink.emit(.{ .part_start = .{ .index = 0, .part = initial } });
            try sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .tool_call = .{ .arguments_delta = "{\"value\":" } },
            } });
            try sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .tool_call = .{ .arguments_delta = "4}" } },
            } });
            const parts = &struct {
                const value = [_]zigai.Part{.{ .tool_call = .{
                    .id = "finish-1",
                    .name = "finish",
                    .arguments_json = "{\"value\":4}",
                } }};
            }.value;
            try sink.emit(.{ .part_end = .{ .index = 0, .part = parts[0] } });
            return .{ .parts = parts };
        }

        fn outputFunction(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.output.RunContext,
            arguments_json: []const u8,
        ) !zigai.OutputFunctionResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (run_context.partial_output) {
                self.function_partials += 1;
                return .{ .output = try std.fmt.allocPrint(allocator, "preview:{s}", .{arguments_json}) };
            }
            self.function_finals += 1;
            try std.testing.expectEqualStrings("{\"value\":4}", arguments_json);
            return .{ .output = "accepted" };
        }

        fn validate(
            context: *anyopaque,
            _: std.mem.Allocator,
            run_context: zigai.output.RunContext,
            output_name: ?[]const u8,
            output_json: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("finish", output_name.?);
            if (run_context.partial_output) {
                self.validator_partials += 1;
                try std.testing.expect(std.mem.startsWith(u8, output_json, "preview:"));
            } else {
                self.validator_finals += 1;
                try std.testing.expectEqualStrings("accepted", output_json);
            }
            return .{ .output = output_json };
        }

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value == .partial_output) {
                const partial = value.partial_output;
                self.streamed_partials += 1;
                try std.testing.expectEqualStrings("finish", partial.output_name.?);
                try std.testing.expect(partial.structured_output == null);
                try std.testing.expect(std.mem.startsWith(u8, partial.output, "preview:"));
            }
        }
    };
    const schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"value\":{\"type\":\"integer\"}},\"required\":[\"value\"]," ++
        "\"additionalProperties\":false}";
    var state: State = .{};
    const choices = [_]zigai.OutputChoice{.{
        .name = "finish",
        .schema = schema,
        .function = .{ .context = &state, .callFn = State.outputFunction },
    }};
    const validators = [_]zigai.OutputValidator{.{ .context = &state, .validateFn = State.validate }};
    const model = zigai.Model{
        .context = &state,
        .profile = .{ .supports_tools = true, .supports_streaming = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    var result = try (zigai.Agent{
        .model = model,
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
        .output_validators = &validators,
    }).runStream(std.testing.allocator, "answer", .{ .context = &state, .eventFn = State.event });
    defer result.deinit();
    try std.testing.expectEqualStrings("accepted", result.output);
    try std.testing.expectEqual(@as(usize, 2), state.function_partials);
    try std.testing.expectEqual(@as(usize, 1), state.function_finals);
    try std.testing.expectEqual(@as(usize, 2), state.validator_partials);
    try std.testing.expectEqual(@as(usize, 1), state.validator_finals);
    try std.testing.expectEqual(@as(usize, 2), state.streamed_partials);
}

test "streaming snapshots handle metadata text and atomic output tools" {
    const State = struct {
        kind: enum { text, tool },
        partials: usize = 0,

        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            return switch (self.kind) {
                .text => {
                    const part = zigai.Part{ .text_part = .{ .content = "done" } };
                    try sink.emit(.{ .part_start = .{
                        .index = 0,
                        .part = .{ .text_part = .{ .content = "" } },
                    } });
                    try sink.emit(.{ .part_end = .{ .index = 0, .part = part } });
                    return .{ .parts = &.{part} };
                },
                .tool => {
                    const part = zigai.Part{ .tool_call = .{
                        .id = "finish-1",
                        .name = "finish",
                        .arguments_json = "{\"value\":4}",
                    } };
                    try sink.emit(.{ .part_start = .{ .index = 0, .part = .{ .tool_call = .{
                        .id = "finish-1",
                        .name = "finish",
                        .arguments_json = "",
                    } } } });
                    try sink.emit(.{ .part_end = .{ .index = 0, .part = part } });
                    return .{ .parts = &.{part} };
                },
            };
        }

        fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value == .partial_output) self.partials += 1;
        }
    };

    var text_state = State{ .kind = .text };
    const text_model = zigai.Model{
        .context = &text_state,
        .profile = .{ .supports_streaming = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    var text_result = try (zigai.Agent{ .model = text_model }).runStream(
        std.testing.allocator,
        "answer",
        .{ .context = &text_state, .eventFn = State.event },
    );
    defer text_result.deinit();
    try std.testing.expectEqualStrings("done", text_result.output);
    try std.testing.expectEqual(@as(usize, 1), text_state.partials);

    const choices = [_]zigai.OutputChoice{.{
        .name = "finish",
        .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}}," ++
            "\"required\":[\"value\"],\"additionalProperties\":false}",
    }};
    var tool_state = State{ .kind = .tool };
    const tool_model = zigai.Model{
        .context = &tool_state,
        .profile = .{ .supports_streaming = true, .supports_tools = true },
        .requestFn = State.request,
        .streamFn = State.stream,
    };
    var tool_result = try (zigai.Agent{
        .model = tool_model,
        .output = .{ .tool = .{ .output = .{ .choices = &choices } } },
    }).runStream(
        std.testing.allocator,
        "answer",
        .{ .context = &tool_state, .eventFn = State.event },
    );
    defer tool_result.deinit();
    try std.testing.expectEqualStrings("{\"value\":4}", tool_result.output);
    try std.testing.expectEqual(@as(usize, 1), tool_state.partials);
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
                .final_result => self.finals += 1,
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
            try std.testing.expectEqual(@as(f64, 0.6), request.settings.top_p.?);
            try std.testing.expectEqual(@as(u32, 30), request.settings.top_k.?);
            try std.testing.expectEqual(@as(f64, 0.4), request.settings.presence_penalty.?);
            try std.testing.expectEqual(@as(f64, -0.2), request.settings.frequency_penalty.?);
            try std.testing.expectEqual(@as(u8, 5), request.settings.logprobs.?.top);
            try std.testing.expectEqualStrings("search", request.settings.tool_choice.?.tool);
            try std.testing.expect(!request.settings.parallel_tool_calls.?);
            try std.testing.expectEqual(@as(?u64, null), request.settings.thinking_budget_tokens);
            try std.testing.expectEqual(zigai.ServiceTier.priority, request.settings.service_tier.?);
            try std.testing.expectEqual(zigai.Truncation.auto, request.settings.truncation.?);
            try std.testing.expectEqualStrings("x-feature", request.settings.extra_headers.?[0].name);
            try std.testing.expectEqual(zigai.ExtraBodyKind.openai, request.settings.extra_body.?.kind());
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{
            .supports_temperature = true,
            .supports_stop_sequences = true,
            .supports_seed = true,
            .supports_top_p = true,
            .supports_top_k = true,
            .supports_presence_penalty = true,
            .supports_frequency_penalty = true,
            .supports_logprobs = true,
            .supports_tool_choice = true,
            .supports_parallel_tool_call_setting = true,
            .supports_thinking_budget = true,
            .supports_truncation = true,
            .supports_request_headers = true,
            .extra_body_kind = .openai,
            .reasoning_efforts = zigai.ModelProfile.ReasoningEffortSet.initFull(),
            .service_tiers = zigai.ModelProfile.ServiceTierSet.initFull(),
        },
    };
    var model = scripted.model();
    model.settings = .{
        .temperature = 0.1,
        .max_tokens = 100,
        .stop_sequences = &.{"model-stop"},
        .seed = 1,
        .reasoning_effort = .low,
        .top_p = 0.5,
        .top_k = 20,
        .presence_penalty = 0.1,
        .frequency_penalty = -0.1,
        .logprobs = .{ .top = 2 },
        .tool_choice = .auto,
        .parallel_tool_calls = true,
        .service_tier = .default,
        .truncation = .disabled,
        .extra_headers = &.{.{ .name = "x-feature", .value = "on" }},
        .extra_body = .{ .openai = "{\"store\":false}" },
    };
    var result = try (zigai.Agent{
        .model = model,
        .model_settings = .{
            .temperature = 0.2,
            .max_tokens = 200,
            .seed = 2,
            .top_p = 0.6,
            .top_k = 30,
            .presence_penalty = 0.4,
            .frequency_penalty = -0.2,
        },
    }).runWithOptions(std.testing.allocator, "hi", .{ .model_settings = .{
        .temperature = 0.3,
        .stop_sequences = &.{"run-stop"},
        .seed = 3,
        .reasoning_effort = .high,
        .logprobs = .{ .top = 5 },
        .tool_choice = .{ .tool = "search" },
        .parallel_tool_calls = false,
        .service_tier = .priority,
        .truncation = .auto,
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

    const Case = struct {
        settings: zigai.ModelSettings,
        failure: anyerror,
    };
    const cases = [_]Case{
        .{ .settings = .{ .top_p = 0.5 }, .failure = zigai.Agent.Error.ModelDoesNotSupportTopP },
        .{ .settings = .{ .top_k = 10 }, .failure = zigai.Agent.Error.ModelDoesNotSupportTopK },
        .{ .settings = .{ .presence_penalty = 0.1 }, .failure = zigai.Agent.Error.ModelDoesNotSupportPresencePenalty },
        .{
            .settings = .{ .frequency_penalty = 0.1 },
            .failure = zigai.Agent.Error.ModelDoesNotSupportFrequencyPenalty,
        },
        .{ .settings = .{ .logprobs = .{} }, .failure = zigai.Agent.Error.ModelDoesNotSupportLogprobs },
        .{ .settings = .{ .tool_choice = .auto }, .failure = zigai.Agent.Error.ModelDoesNotSupportToolChoice },
        .{
            .settings = .{ .parallel_tool_calls = false },
            .failure = zigai.Agent.Error.ModelDoesNotSupportParallelToolCallSetting,
        },
        .{
            .settings = .{ .thinking_budget_tokens = 1_024 },
            .failure = zigai.Agent.Error.ModelDoesNotSupportThinkingBudget,
        },
        .{ .settings = .{ .service_tier = .default }, .failure = zigai.Agent.Error.ModelDoesNotSupportServiceTier },
        .{ .settings = .{ .truncation = .auto }, .failure = zigai.Agent.Error.ModelDoesNotSupportTruncation },
        .{ .settings = .{ .extra_headers = &.{} }, .failure = zigai.Agent.Error.ModelDoesNotSupportRequestHeaders },
        .{
            .settings = .{ .extra_body = .{ .openai = "{}" } },
            .failure = zigai.Agent.Error.ModelDoesNotSupportExtraBody,
        },
    };
    for (cases) |case| {
        var unsupported = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
        try std.testing.expectError(case.failure, (zigai.Agent{
            .model = unsupported.model(),
            .model_settings = case.settings,
        }).run(std.testing.allocator, "hi"));
        try std.testing.expectEqual(@as(usize, 0), unsupported.request_count);
    }

    var invalid = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.InvalidModelSettings, (zigai.Agent{
        .model = invalid.model(),
        .model_settings = .{ .top_p = 2 },
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 0), invalid.request_count);

    var serial_only = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .profile = .{
            .supports_parallel_tool_calls = false,
            .supports_parallel_tool_call_setting = true,
        },
    };
    try std.testing.expectError(zigai.Agent.Error.ModelDoesNotSupportParallelToolCallSetting, (zigai.Agent{
        .model = serial_only.model(),
        .model_settings = .{ .parallel_tool_calls = true },
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 0), serial_only.request_count);
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

test "on-demand capability loads its complete bundle on the next model request" {
    const load_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "load-research",
        .name = "load_capability",
        .arguments_json = "{\"id\":\"research\"}",
    } }};
    const search_parts = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "search-call",
        .name = "search",
        .arguments_json = "{}",
    } }};
    const final_parts = [_]zigai.model.Part{.{ .text = "researched" }};
    const BaseInspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.tools.len);
            try std.testing.expectEqualStrings("load_capability", request.tools[0].name);
            try std.testing.expect(std.mem.indexOf(
                u8,
                request.instructions[0],
                "research: Use for detailed research.",
            ) != null);
        }
    };
    const SelectedInspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.tools.len);
            try std.testing.expectEqualStrings("search", request.tools[0].name);
            try std.testing.expectEqual(@as(f64, 0.7), request.settings.temperature.?);
            if (index == 0) {
                const loaded = request.messages[2].request.parts[0].tool_return;
                try std.testing.expectEqualStrings("load_capability", loaded.name);
                try std.testing.expectEqual(zigai.ToolPartKind.capability_load, loaded.tool_kind.?);
                try std.testing.expect(std.mem.indexOf(u8, loaded.content, "Research carefully.") != null);
            } else {
                try std.testing.expectEqualStrings("ok", request.messages[4].request.parts[0].tool_return.content);
            }
        }
    };
    var base = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &load_parts }},
        .inspectFn = BaseInspector.inspect,
    };
    var selected = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &search_parts }, .{ .parts = &final_parts } },
        .inspectFn = SelectedInspector.inspect,
        .profile = .{ .supports_temperature = true },
    };
    const Selector = struct {
        model: zigai.Model,
        calls: usize = 0,

        fn select(context: ?*anyopaque, run: zigai.CapabilityContext) !zigai.Model {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            try std.testing.expectEqual(zigai.CapabilityScope.agent, run.scope);
            try std.testing.expectEqualStrings("tests", run.metadata[0].value);
            try std.testing.expectEqualSlices([]const u8, &.{"research"}, run.loaded_capability_ids);
            return self.model;
        }
    };
    const Hook = struct {
        starts: usize = 0,
        ends: usize = 0,

        fn event(context: *anyopaque, value: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (value) {
                .model_request_start => self.starts += 1,
                .run_end => self.ends += 1,
                else => {},
            }
        }
    };
    var selector = Selector{ .model = selected.model() };
    var hook: Hook = .{};
    var executions: u8 = 0;
    const search = zigai.Tool{
        .definition = .{ .name = "search", .description = "", .parameters_json_schema = "{}" },
        .context = &executions,
        .executeWithContextFn = struct {
            fn execute(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                run: zigai.ToolRunContext,
                _: []const u8,
            ) ![]const u8 {
                const calls: *u8 = @ptrCast(@alignCast(context));
                calls.* += 1;
                try std.testing.expectEqual(@as(usize, 1), run.capabilities.available_ids.len);
                try std.testing.expectEqualStrings("research", run.capabilities.available_ids[0]);
                try std.testing.expectEqualStrings("research", run.capabilities.loaded_ids[0]);
                return allocator.dupe(u8, "ok");
            }
        }.execute,
    };
    var result = try (zigai.Agent{
        .model = base.model(),
        .capabilities = &.{.{
            .id = "research",
            .description = "Use for detailed research.",
            .metadata = &.{.{ .key = "owner", .value = "tests" }},
            .loading = .on_demand,
            .tools = &.{search},
            .instructions = &.{.{ .text = "Research carefully." }},
            .hooks = &.{.{ .context = &hook, .eventFn = Hook.event }},
            .model_settings = .{ .temperature = 0.7 },
            .context = &selector,
            .selectModelFn = Selector.select,
        }},
    }).run(std.testing.allocator, "investigate");
    defer result.deinit();
    try std.testing.expectEqualStrings("researched", result.output);
    try std.testing.expectEqual(@as(u8, 1), executions);
    try std.testing.expectEqual(@as(usize, 1), selector.calls);
    try std.testing.expectEqual(@as(usize, 2), hook.starts);
    try std.testing.expectEqual(@as(usize, 1), hook.ends);
    try std.testing.expectEqual(
        zigai.ToolPartKind.capability_load,
        result.messages[1].response.parts[0].tool_call.tool_kind.?,
    );
}

test "capability scopes compose from inherited through subagent deterministically" {
    const parts = [_]zigai.model.Part{.{ .text = "ordered" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 5), request.instructions.len);
            const expected = [_][]const u8{ "inherited", "agent", "run", "nested", "subagent" };
            for (expected, request.instructions) |text, actual| {
                try std.testing.expectEqualStrings(text, actual);
            }
            try std.testing.expectEqual(@as(f64, 0.7), request.settings.temperature.?);
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .supports_temperature = true },
    };
    const inherited = zigai.Capability{
        .id = "inherited",
        .instructions = &.{.{ .text = "inherited" }},
        .model_settings = .{ .temperature = 0.1 },
    };
    const agent_capability = zigai.Capability{
        .id = "agent",
        .instructions = &.{.{ .text = "agent" }},
        .model_settings = .{ .temperature = 0.2 },
    };
    const run = zigai.Capability{
        .id = "run",
        .instructions = &.{.{ .text = "run" }},
        .model_settings = .{ .temperature = 0.3 },
    };
    const nested = zigai.Capability{
        .id = "nested",
        .instructions = &.{.{ .text = "nested" }},
        .model_settings = .{ .temperature = 0.4 },
    };
    const subagent = zigai.Capability{
        .id = "subagent",
        .instructions = &.{.{ .text = "subagent" }},
        .model_settings = .{ .temperature = 0.5 },
    };
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .capabilities = &.{agent_capability},
        .model_settings = .{ .temperature = 0.6 },
    }).runWithOptions(std.testing.allocator, "compose", .{
        .capabilities = &.{run},
        .capability_layers = &.{
            .{ .scope = .subagent, .capabilities = &.{subagent} },
            .{ .scope = .nested, .capabilities = &.{nested} },
            .{ .scope = .inherited, .capabilities = &.{inherited} },
        },
        .model_settings = .{ .temperature = 0.7 },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("ordered", result.output);
}

test "loaded capability activates native tools toolsets policies processors and validators together" {
    const load_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "load-bundle",
        .name = "load_capability",
        .arguments_json = "{\"id\":\"bundle\"}",
    } }};
    const final_parts = [_]zigai.Part{.{ .text = "raw" }};
    const Inspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("direct", request.tools[0].name);
            try std.testing.expectEqualStrings("toolset", request.tools[1].name);
            try std.testing.expectEqualStrings("active", request.tools[0].description);
            try std.testing.expectEqualStrings("active", request.tools[1].description);
            try std.testing.expectEqual(@as(usize, 1), request.builtin_tools.len);
            try std.testing.expectEqual(zigai.BuiltinToolKind.web_search, request.builtin_tools[0].kind());
        }
    };
    var base = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &load_parts }} };
    var selected = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final_parts }},
        .inspectFn = Inspector.inspect,
        .profile = .{ .builtin_tools = zigai.ModelProfile.BuiltinToolSet.initMany(&.{.web_search}) },
    };
    const State = struct {
        model: zigai.Model,
        history_calls: usize = 0,
        policy_calls: usize = 0,
        validator_calls: usize = 0,
        hook_starts: usize = 0,

        fn select(context: ?*anyopaque, _: zigai.CapabilityContext) !zigai.Model {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.model;
        }

        fn process(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.HistoryContext,
            messages: []const zigai.Message,
        ) ![]const zigai.Message {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.history_calls += 1;
            return messages;
        }

        fn policy(context: *anyopaque, _: std.mem.Allocator, event: zigai.ToolPolicyEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .prepare => |prepared| {
                    self.policy_calls += 1;
                    prepared.tool.definition.description = "active";
                },
                else => {},
            }
        }

        fn validate(
            context: *anyopaque,
            _: std.mem.Allocator,
            run: zigai.OutputRunContext,
            _: ?[]const u8,
            output: []const u8,
        ) !zigai.OutputValidatorResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.validator_calls += 1;
            try std.testing.expectEqualStrings("raw", output);
            try std.testing.expectEqualStrings("bundle", run.capabilities.loaded_ids[0]);
            return .{ .output = "validated" };
        }

        fn hook(context: *anyopaque, event: zigai.LifecycleEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .model_request_start => self.hook_starts += 1,
                else => {},
            }
        }
    };
    var state = State{ .model = selected.model() };
    const direct = zigai.Tool{
        .definition = .{ .name = "direct", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
    };
    const toolset_tool = zigai.Tool{
        .definition = .{ .name = "toolset", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
    };
    const native = [_]zigai.BuiltinTool{.{ .web_search = .{} }};
    const toolset = zigai.Toolset{ .tools = &.{toolset_tool} };
    const processor = zigai.HistoryProcessor{ .custom = .{
        .context = &state,
        .processFn = State.process,
    } };
    const validator = zigai.OutputValidator{ .context = &state, .validateFn = State.validate };
    var result = try (zigai.Agent{
        .model = base.model(),
        .capabilities = &.{.{
            .id = "bundle",
            .description = "complete bundle",
            .loading = .on_demand,
            .tools = &.{direct},
            .builtin_tools = &native,
            .toolsets = &.{toolset},
            .hooks = &.{.{ .context = &state, .eventFn = State.hook }},
            .tool_policies = &.{.{ .context = &state, .applyFn = State.policy }},
            .history_processors = &.{processor},
            .output_validators = &.{validator},
            .context = &state,
            .selectModelFn = State.select,
        }},
    }).run(std.testing.allocator, "load all");
    defer result.deinit();
    try std.testing.expectEqualStrings("validated", result.output);
    try std.testing.expectEqual(@as(usize, 1), state.history_calls);
    try std.testing.expectEqual(@as(usize, 2), state.policy_calls);
    try std.testing.expectEqual(@as(usize, 1), state.validator_calls);
    try std.testing.expectEqual(@as(usize, 1), state.hook_starts);
}

test "capability graph failures stop before the first model request" {
    const parts = [_]zigai.model.Part{.{ .text = "unused" }};

    var invalid_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.InvalidCapability, (zigai.Agent{
        .model = invalid_model.model(),
        .capabilities = &.{.{ .id = "bad id" }},
    }).run(std.testing.allocator, "invalid"));
    try std.testing.expectEqual(@as(usize, 0), invalid_model.request_count);

    var duplicate_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.DuplicateCapabilityId, (zigai.Agent{
        .model = duplicate_model.model(),
        .capabilities = &.{
            .{ .id = "same" },
            .{ .id = "same" },
        },
    }).run(std.testing.allocator, "duplicate"));
    try std.testing.expectEqual(@as(usize, 0), duplicate_model.request_count);

    var dependency_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.MissingCapabilityDependency, (zigai.Agent{
        .model = dependency_model.model(),
        .capabilities = &.{.{ .id = "child", .dependencies = &.{"missing"} }},
    }).run(std.testing.allocator, "dependency"));
    try std.testing.expectEqual(@as(usize, 0), dependency_model.request_count);

    var cycle_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.CapabilityDependencyCycle, (zigai.Agent{
        .model = cycle_model.model(),
        .capabilities = &.{
            .{ .id = "one", .dependencies = &.{"two"} },
            .{ .id = "two", .dependencies = &.{"one"} },
        },
    }).run(std.testing.allocator, "cycle"));
    try std.testing.expectEqual(@as(usize, 0), cycle_model.request_count);

    var conflict_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    try std.testing.expectError(zigai.Agent.Error.CapabilityConflict, (zigai.Agent{
        .model = conflict_model.model(),
        .capabilities = &.{
            .{ .id = "online", .conflicts = &.{"offline"} },
            .{ .id = "offline" },
        },
    }).run(std.testing.allocator, "conflict"));
    try std.testing.expectEqual(@as(usize, 0), conflict_model.request_count);

    var reserved_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    var calls: u8 = 0;
    var reserved_tool = successfulTool(&calls);
    reserved_tool.definition.name = "load_capability";
    const loaded_history = [_]zigai.Message{
        .{ .response = .{ .parts = &.{.{ .tool_call = .{
            .id = "loaded",
            .name = "load_capability",
            .arguments_json = "{\"id\":\"restored\"}",
            .tool_kind = .capability_load,
        } }} } },
        .{ .request = .{ .parts = &.{.{ .tool_return = .{
            .call_id = "loaded",
            .name = "load_capability",
            .content = "loaded",
            .tool_kind = .capability_load,
        } }} } },
    };
    try std.testing.expectError(zigai.Agent.Error.DuplicateToolName, (zigai.Agent{
        .model = reserved_model.model(),
        .tools = &.{reserved_tool},
        .capabilities = &.{.{
            .id = "restored",
            .description = "Restored capability.",
            .loading = .on_demand,
        }},
    }).runWithOptions(std.testing.allocator, "reserved", .{ .message_history = &loaded_history }));
    try std.testing.expectEqual(@as(usize, 0), reserved_model.request_count);
}

test "an on-demand conflict fails without partially activating its bundle" {
    const load_online = [_]zigai.Part{.{ .tool_call = .{
        .id = "load-online",
        .name = "load_capability",
        .arguments_json = "{\"id\":\"online\"}",
    } }};
    const load_offline = [_]zigai.Part{.{ .tool_call = .{
        .id = "load-offline",
        .name = "load_capability",
        .arguments_json = "{\"id\":\"offline\"}",
    } }};
    const final_parts = [_]zigai.Part{.{ .text = "kept online" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) {
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                try std.testing.expectEqualStrings("load_capability", request.tools[0].name);
                return;
            }
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("online_tool", request.tools[0].name);
            try std.testing.expectEqualStrings("load_capability", request.tools[1].name);
            if (index == 2) {
                const result = request.messages[4].request.parts[0].tool_return;
                try std.testing.expectEqual(zigai.ToolOutcome.failed, result.effectiveOutcome());
                try std.testing.expect(std.mem.indexOf(u8, result.content, "CapabilityConflict") != null);
            }
        }
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{
            .{ .parts = &load_online },
            .{ .parts = &load_offline },
            .{ .parts = &final_parts },
        },
        .inspectFn = Inspector.inspect,
    };
    var calls: u8 = 0;
    var online_tool = successfulTool(&calls);
    online_tool.definition.name = "online_tool";
    var offline_tool = successfulTool(&calls);
    offline_tool.definition.name = "offline_tool";
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .capabilities = &.{
            .{
                .id = "online",
                .description = "Online mode.",
                .loading = .on_demand,
                .conflicts = &.{"offline"},
                .tools = &.{online_tool},
            },
            .{
                .id = "offline",
                .description = "Offline mode.",
                .loading = .on_demand,
                .tools = &.{offline_tool},
            },
        },
    }).run(std.testing.allocator, "choose a mode");
    defer result.deinit();
    try std.testing.expectEqualStrings("kept online", result.output);
    try std.testing.expectEqual(@as(u8, 0), calls);
}

test "on-demand dependencies load together and history controls retention" {
    const load_parts = [_]zigai.model.Part{.{ .capability_load_call = .{
        .call_id = "load-child",
        .capability_id = "child",
    } }};
    const final_parts = [_]zigai.model.Part{.{ .text = "loaded" }};
    const InitialInspector = struct {
        fn inspect(index: usize, request: zigai.ModelRequest) !void {
            if (index == 0) {
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                try std.testing.expectEqualStrings("load_capability", request.tools[0].name);
                return;
            }
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("base_tool", request.tools[0].name);
            try std.testing.expectEqualStrings("child_tool", request.tools[1].name);
            const result = request.messages[2].request.parts[0].tool_return.content;
            const base_position = std.mem.indexOf(u8, result, "base instructions").?;
            const child_position = std.mem.indexOf(u8, result, "child instructions").?;
            try std.testing.expect(base_position < child_position);
        }
    };
    var initial = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &load_parts }, .{ .parts = &final_parts } },
        .inspectFn = InitialInspector.inspect,
    };
    var calls: u8 = 0;
    var base_tool = successfulTool(&calls);
    base_tool.definition.name = "base_tool";
    var child_tool = successfulTool(&calls);
    child_tool.definition.name = "child_tool";
    const persistent = [_]zigai.Capability{
        .{
            .id = "base",
            .description = "base",
            .loading = .on_demand,
            .tools = &.{base_tool},
            .instructions = &.{.{ .text = "base instructions" }},
        },
        .{
            .id = "child",
            .description = "child",
            .dependencies = &.{"base"},
            .loading = .on_demand,
            .tools = &.{child_tool},
            .instructions = &.{.{ .text = "child instructions" }},
        },
    };
    var first = try (zigai.Agent{ .model = initial.model(), .capabilities = &persistent }).run(
        std.testing.allocator,
        "load",
    );
    defer first.deinit();

    const ReplayInspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 2), request.tools.len);
            try std.testing.expectEqualStrings("base_tool", request.tools[0].name);
            try std.testing.expectEqualStrings("child_tool", request.tools[1].name);
        }
    };
    var replay = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final_parts }},
        .inspectFn = ReplayInspector.inspect,
    };
    var replayed = try (zigai.Agent{ .model = replay.model(), .capabilities = &persistent }).runWithOptions(
        std.testing.allocator,
        "continue",
        .{ .message_history = first.messages },
    );
    defer replayed.deinit();

    var ephemeral_capabilities = persistent;
    ephemeral_capabilities[0].unload_policy = .run_end;
    ephemeral_capabilities[1].unload_policy = .run_end;
    const EphemeralInspector = struct {
        fn inspect(_: usize, request: zigai.ModelRequest) !void {
            try std.testing.expectEqual(@as(usize, 1), request.tools.len);
            try std.testing.expectEqualStrings("load_capability", request.tools[0].name);
        }
    };
    var ephemeral = zigai.testing.ScriptedModel{
        .responses = &.{.{ .parts = &final_parts }},
        .inspectFn = EphemeralInspector.inspect,
    };
    var forgotten = try (zigai.Agent{
        .model = ephemeral.model(),
        .capabilities = &ephemeral_capabilities,
    }).runWithOptions(std.testing.allocator, "new run", .{ .message_history = first.messages });
    defer forgotten.deinit();
}

test "run-end capability remains loaded across a paused-run continuation" {
    const load_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "load-sensitive",
        .name = "load_capability",
        .arguments_json = "{\"id\":\"sensitive\"}",
    } }};
    const approval_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "approve-sensitive",
        .name = "sensitive_action",
        .arguments_json = "{}",
    } }};
    const final_parts = [_]zigai.Part{.{ .text = "approved" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &load_parts },
        .{ .parts = &approval_parts },
        .{ .parts = &final_parts },
    } };
    var executions: u8 = 0;
    var tool = successfulTool(&executions);
    tool.definition.name = "sensitive_action";
    tool.execution = .requires_approval;
    const agent = zigai.Agent{
        .model = scripted.model(),
        .capabilities = &.{.{
            .id = "sensitive",
            .description = "sensitive workflow",
            .loading = .on_demand,
            .unload_policy = .run_end,
            .tools = &.{tool},
        }},
    };
    var first = try agent.runUntilPause(std.testing.allocator, "act");
    defer first.deinit();
    const state = switch (first) {
        .complete => return error.ExpectedPausedRun,
        .paused => |paused| paused.state_json,
    };
    var resumed = try agent.resumeRun(std.testing.allocator, state, &.{.{
        .call_id = "approve-sensitive",
        .action = .approve,
    }});
    defer resumed.deinit();
    switch (resumed) {
        .paused => return error.ExpectedCompletedRun,
        .complete => |result| try std.testing.expectEqualStrings("approved", result.output),
    }
    try std.testing.expectEqual(@as(u8, 1), executions);
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
                try std.testing.expectEqualStrings("db__alpha", request.messages[2].request.parts[0].tool_return.name);
            } else {
                try std.testing.expectEqual(@as(usize, 1), request.tools.len);
                try std.testing.expectEqualStrings("utility__always", request.tools[0].name);
                try std.testing.expectEqualStrings("db__beta", request.messages[4].request.parts[0].tool_return.name);
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
        partials: usize = 0,

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

        fn stream(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sink += 1;
            if (value == .partial_output) self.partials += 1;
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
    try std.testing.expectEqual(@as(usize, 6), capture.sink);
    try std.testing.expectEqual(@as(usize, 1), capture.partials);
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

    const thinking_parts = [_]zigai.model.Part{.{ .thinking = .{ .content = "private" } }};
    const no_text = [_]zigai.model.ModelResponse{.{ .parts = &thinking_parts }};
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

    var policy_disabled = zigai.testing.ScriptedModel{
        .responses = &responses,
        .profile = .{
            .supports_parallel_tool_calls = true,
            .supports_parallel_tool_call_setting = true,
        },
    };
    try std.testing.expectError(
        zigai.agent.Agent.Error.ParallelToolCallsNotSupported,
        (zigai.Agent{
            .model = policy_disabled.model(),
            .tools = &.{tool},
            .model_settings = .{ .parallel_tool_calls = false },
        }).run(std.testing.allocator, "hi"),
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
        .{ .tool_call = .{ .id = "slow-id", .name = "slow", .arguments_json = "\"slow\"" } },
        .{ .tool_call = .{ .id = "fast-id", .name = "fast", .arguments_json = "\"fast\"" } },
    };
    const final_parts = [_]zigai.model.Part{.{ .text = "done" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const results = request.messages[2].request.parts;
            try std.testing.expectEqual(@as(usize, 2), results.len);
            try std.testing.expectEqualStrings("slow-id", results[0].tool_return.call_id);
            try std.testing.expectEqualStrings("slow", results[0].tool_return.content);
            try std.testing.expectEqualStrings("fast-id", results[1].tool_return.call_id);
            try std.testing.expectEqualStrings("fast", results[1].tool_return.content);
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
            const value = arguments[1 .. arguments.len - 1];
            if (self.active.fetchAdd(1, .seq_cst) > 0) self.overlapped.store(true, .seq_cst);
            defer _ = self.active.fetchSub(1, .seq_cst);
            const io = run_context.io orelse return error.MissingIo;
            (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(if (std.mem.eql(u8, value, "slow")) 40 else 5),
                .clock = .awake,
            } }).sleep(io) catch return error.ToolCancelled;
            try std.testing.expect(run_context.cancellation == null);
            return allocator.dupe(u8, value);
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

test "sequential tools never overlap other local calls" {
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "exclusive", .name = "exclusive", .arguments_json = "\"exclusive\"" } },
        .{ .tool_call = .{ .id = "first", .name = "normal", .arguments_json = "\"first\"" } },
        .{ .tool_call = .{ .id = "second", .name = "normal", .arguments_json = "\"second\"" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{
        .{ .parts = &calls },
        .{ .parts = &final },
    } };
    const State = struct {
        active: std.atomic.Value(usize) = .init(0),
        exclusive_active: std.atomic.Value(bool) = .init(false),
        violation: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run: zigai.ToolRunContext,
            arguments: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const exclusive = std.mem.eql(u8, arguments, "\"exclusive\"");
            if (exclusive) {
                if (self.active.load(.seq_cst) != 0) self.violation.store(true, .seq_cst);
                self.exclusive_active.store(true, .seq_cst);
            } else if (self.exclusive_active.load(.seq_cst)) {
                self.violation.store(true, .seq_cst);
            }
            _ = self.active.fetchAdd(1, .seq_cst);
            defer {
                _ = self.active.fetchSub(1, .seq_cst);
                if (exclusive) self.exclusive_active.store(false, .seq_cst);
            }
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }).sleep(run.io.?);
            return allocator.dupe(u8, arguments);
        }
    };
    var state: State = .{};
    const tools = [_]zigai.Tool{
        .{
            .definition = .{ .name = "exclusive", .description = "", .parameters_json_schema = "{}" },
            .sequential = true,
            .context = &state,
            .executeWithContextFn = State.execute,
        },
        .{
            .definition = .{ .name = "normal", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .executeWithContextFn = State.execute,
        },
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &tools,
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run all.");
    defer result.deinit();
    try std.testing.expect(!state.violation.load(.seq_cst));
}

test "tool isolation returns bounded timeout result and follow-up failures" {
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "timeout", .name = "timeout", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "result", .name = "result", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "follow-count", .name = "follow-count", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "follow-bytes", .name = "follow-bytes", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "rich", .name = "rich", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "recovered" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const results = request.messages[2].request.parts;
            try std.testing.expectEqual(@as(usize, 5), results.len);
            try std.testing.expect(std.mem.indexOf(u8, results[0].tool_return.content, "ToolTimedOut") != null);
            try std.testing.expect(std.mem.indexOf(u8, results[1].tool_return.content, "ToolResultTooLarge") != null);
            try std.testing.expect(std.mem.indexOf(u8, results[2].tool_return.content, "ToolFollowUpOverflow") != null);
            try std.testing.expect(std.mem.indexOf(u8, results[3].tool_return.content, "ToolFollowUpOverflow") != null);
            try std.testing.expect(!results[4].tool_return.is_error);
            for (results[0..4]) |part| try std.testing.expect(part.tool_return.is_error);
            const follow_up = request.messages[3].request;
            try std.testing.expectEqual(@as(usize, 4), follow_up.parts.len);
            try std.testing.expectEqualStrings("run", follow_up.run_id.?);
        }
    };
    const Execute = struct {
        fn timeout(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            context: zigai.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const io = context.io orelse return error.MissingIo;
            (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(50),
                .clock = .awake,
            } }).sleep(io) catch return error.ToolCancelled;
            return allocator.dupe(u8, "late");
        }
        fn large(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "large");
        }
        fn follow(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !zigai.ToolOutput {
            return .{ .content = "ok", .follow_up_messages = &.{.{
                .parts = &.{.{ .user_prompt = .{ .text = "too large" } }},
            }} };
        }
        fn rich(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !zigai.ToolOutput {
            return .{ .content = "ok", .follow_up_messages = &.{.{
                .parts = &.{
                    .{ .user_prompt = .{ .image = .{
                        .source = .{ .bytes = "image" },
                        .media_type = "image/png",
                        .filename = "image.png",
                        .thought_signature = "signature",
                        .metadata = &.{.{ .key = "kind", .value = "diagram" }},
                    } } },
                    .{ .user_prompt = .{ .audio = .{
                        .source = .{ .url = "https://example.test/audio" },
                        .media_type = "audio/mpeg",
                    } } },
                    .{ .user_prompt = .{ .document = .{
                        .source = .{ .provider_file = .{ .id = "file-1", .provider = "test" } },
                        .media_type = "application/pdf",
                    } } },
                    .{ .user_prompt = .{ .binary = .{
                        .source = .{ .bytes = "binary" },
                        .media_type = "application/octet-stream",
                    } } },
                },
                .instructions = "instruction",
                .run_id = "run",
                .conversation_id = "conversation",
                .metadata = &.{.{ .key = "source", .value = "tool" }},
            }} };
        }
    };
    var unused: u8 = 0;
    const tools = [_]zigai.Tool{
        .{
            .definition = .{ .name = "timeout", .description = "", .parameters_json_schema = "{}" },
            .context = &unused,
            .limits = .{ .timeout_ms = 1 },
            .executeWithContextFn = Execute.timeout,
        },
        .{
            .definition = .{ .name = "result", .description = "", .parameters_json_schema = "{}" },
            .context = &unused,
            .limits = .{ .max_result_bytes = 3 },
            .executeFn = Execute.large,
        },
        .{
            .definition = .{ .name = "follow-count", .description = "", .parameters_json_schema = "{}" },
            .context = &unused,
            .limits = .{ .max_follow_up_messages = 0 },
            .executeOutputFn = Execute.follow,
        },
        .{
            .definition = .{ .name = "follow-bytes", .description = "", .parameters_json_schema = "{}" },
            .context = &unused,
            .limits = .{ .max_follow_up_bytes = 1 },
            .executeOutputFn = Execute.follow,
        },
        .{
            .definition = .{ .name = "rich", .description = "", .parameters_json_schema = "{}" },
            .context = &unused,
            .executeOutputFn = Execute.rich,
        },
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &calls }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
        .profile = .{ .content_types = zigai.ModelProfile.ContentTypeSet.initMany(&.{
            .image,
            .audio,
            .document,
            .binary,
        }) },
        .provider_name = "test",
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &tools,
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run bounded tools.");
    defer result.deinit();
    try std.testing.expectEqualStrings("recovered", result.output);
}

test "per-tool concurrency and queue limits serialize accepted calls" {
    const calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "one", .name = "limited", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "two", .name = "limited", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "three", .name = "limited", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "other", .name = "other", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "global-overflow", .name = "another", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "done" }};
    const Inspector = struct {
        fn inspect(index: usize, request: zigai.model.ModelRequest) !void {
            if (index == 0) return;
            const results = request.messages[2].request.parts;
            try std.testing.expectEqualStrings("ok", results[0].tool_return.content);
            try std.testing.expectEqualStrings("ok", results[1].tool_return.content);
            try std.testing.expect(std.mem.indexOf(u8, results[2].tool_return.content, "ToolQueueOverflow") != null);
            try std.testing.expectEqualStrings("ok", results[3].tool_return.content);
            try std.testing.expect(std.mem.indexOf(u8, results[4].tool_return.content, "ToolQueueOverflow") != null);
        }
    };
    const State = struct {
        active: std.atomic.Value(usize) = .init(0),
        overlapped: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.active.fetchAdd(1, .seq_cst) != 0) self.overlapped.store(true, .seq_cst);
            defer _ = self.active.fetchSub(1, .seq_cst);
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }).sleep(run_context.io.?);
            return allocator.dupe(u8, "ok");
        }
    };
    const Other = struct {
        fn execute(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "ok");
        }
    };
    var state: State = .{};
    const tools = [_]zigai.Tool{
        .{
            .definition = .{ .name = "limited", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .limits = .{ .max_concurrency = 1, .max_queue_size = 1 },
            .executeWithContextFn = State.execute,
        },
        .{
            .definition = .{ .name = "other", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .executeFn = Other.execute,
        },
        .{
            .definition = .{ .name = "another", .description = "", .parameters_json_schema = "{}" },
            .context = &state,
            .executeFn = Other.execute,
        },
    };
    var scripted = zigai.testing.ScriptedModel{
        .responses = &.{ .{ .parts = &calls }, .{ .parts = &final } },
        .inspectFn = Inspector.inspect,
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &tools,
        .tool_limits = .{ .max_concurrency = 2, .max_queue_size = 1 },
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run limited tools.");
    defer result.deinit();
    try std.testing.expect(!state.overlapped.load(.seq_cst));
}

test "tool isolation requires IO and available concurrency" {
    const call = [_]zigai.model.Part{.{ .tool_call = .{
        .id = "slow",
        .name = "slow",
        .arguments_json = "{}",
    } }};
    const State = struct {
        active: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            } }).sleep(run_context.io.?);
            return allocator.dupe(u8, "late");
        }
    };
    var state: State = .{};
    const tool = zigai.Tool{
        .definition = .{ .name = "slow", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeWithContextFn = State.execute,
    };

    var no_io_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call }} };
    try std.testing.expectError(
        zigai.Agent.Error.ToolIsolationRequiresIo,
        (zigai.Agent{
            .model = no_io_model.model(),
            .tools = &.{tool},
            .tool_limits = .{ .timeout_ms = 1 },
        }).run(std.testing.allocator, "Run."),
    );

    var tighter_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call }} };
    var timed_tool = tool;
    timed_tool.limits = .{ .timeout_ms = 1 };
    try std.testing.expectError(
        zigai.Agent.Error.ToolIsolationRequiresIo,
        (zigai.Agent{
            .model = tighter_model.model(),
            .tools = &.{timed_tool},
            .tool_limits = .{ .timeout_ms = 10 },
        }).run(std.testing.allocator, "Run."),
    );

    var unavailable_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &call }} };
    var no_concurrency = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer no_concurrency.deinit();
    try std.testing.expectError(
        zigai.Agent.Error.ToolConcurrencyUnavailable,
        (zigai.Agent{
            .model = unavailable_model.model(),
            .tools = &.{timed_tool},
            .io = no_concurrency.io(),
        }).run(std.testing.allocator, "Run."),
    );
}

test "parallel tools handle validation and terminal execution failures" {
    const invalid_calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "invalid", .name = "validated", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "valid", .name = "valid", .arguments_json = "{}" } },
    };
    const final = [_]zigai.model.Part{.{ .text = "recovered" }};
    var validation_model = zigai.testing.ScriptedModel{ .responses = &.{ .{ .parts = &invalid_calls }, .{ .parts = &final } } };
    var validated = zigai.reflect.tool("validated", "", struct {
        fn execute(args: struct { value: u8 }) !u8 {
            return args.value;
        }
    }.execute);
    validated.max_retries = 1;
    var calls: u8 = 0;
    var valid = successfulTool(&calls);
    valid.definition.name = "valid";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recovered = try (zigai.Agent{
        .model = validation_model.model(),
        .tools = &.{ validated, valid },
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run both.");
    defer recovered.deinit();
    try std.testing.expectEqualStrings("recovered", recovered.output);
    try std.testing.expectEqual(@as(u8, 1), calls);

    const fatal_calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "fatal", .name = "fatal", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "slow", .name = "slow", .arguments_json = "{}" } },
    };
    var fatal_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &fatal_calls }} };
    const Terminal = struct {
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
            return error.TerminalToolFailure;
        }
        fn recoverable(_: *anyopaque, _: anyerror) bool {
            return false;
        }
    };
    const Slow = struct {
        fn execute(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: zigai.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const io = run_context.io orelse return error.MissingIo;
            (std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            } }).sleep(io) catch return error.ToolCancelled;
            return allocator.dupe(u8, "slow");
        }
    };
    var unused: u8 = 0;
    const fatal = zigai.Tool{
        .definition = .{ .name = "fatal", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeFn = Terminal.execute,
        .isRecoverableFn = Terminal.recoverable,
    };
    const slow = zigai.Tool{
        .definition = .{ .name = "slow", .description = "", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeWithContextFn = Slow.execute,
    };
    try std.testing.expectError(error.TerminalToolFailure, (zigai.Agent{
        .model = fatal_model.model(),
        .tools = &.{ fatal, slow },
        .io = threaded.io(),
    }).run(std.testing.allocator, "Run both."));

    const limited_calls = [_]zigai.model.Part{
        .{ .tool_call = .{ .id = "slow-one", .name = "slow-one", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "slow-two", .name = "slow-two", .arguments_json = "{}" } },
    };
    var limited_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &limited_calls }} };
    var slow_one = slow;
    slow_one.definition.name = "slow-one";
    var slow_two = slow;
    slow_two.definition.name = "slow-two";
    var limited = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer limited.deinit();
    try std.testing.expectError(zigai.Agent.Error.ToolConcurrencyUnavailable, (zigai.Agent{
        .model = limited_model.model(),
        .tools = &.{ slow_one, slow_two },
        .io = limited.io(),
    }).run(std.testing.allocator, "Exceed concurrency."));
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
            const result = request.messages[request.messages.len - 1].request.parts[0].tool_return;
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
            const result = request.messages[2].request.parts[0].tool_return;
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
            if (std.mem.eql(u8, value.name, "invoke_agent")) self.run_spans += 1;
            if (std.mem.startsWith(u8, value.name, "chat ")) self.request_spans += 1;
            if (std.mem.startsWith(u8, value.name, "execute_tool ")) self.tool_spans += 1;
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
        .capabilities = &.{.{}},
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
    try std.testing.expectEqual(@as(usize, 3), result.usage.requests);
    try std.testing.expectEqual(@as(usize, 1), result.usage.tool_calls);
}

test "structured diagnostics instrument ordinary and capability runs with redaction" {
    const Capture = struct {
        starts: usize = 0,
        ends: usize = 0,
        redactions: usize = 0,

        fn emit(context: *anyopaque, event: zigai.DiagnosticEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, event.name, "zigai.run.start")) self.starts += 1;
            if (std.mem.eql(u8, event.name, "zigai.run.end")) self.ends += 1;
            self.redactions += event.sensitive_values_redacted;
            for (event.attributes) |attribute| switch (attribute.value) {
                .string => |value| try std.testing.expect(std.mem.indexOf(u8, value, "private") == null),
                else => {},
            };
        }
    };
    const parts = [_]zigai.model.Part{.{ .text = "private answer" }};
    const responses = [_]zigai.model.ModelResponse{.{ .parts = &parts }};
    var first_model = zigai.testing.ScriptedModel{ .responses = &responses };
    var second_model = zigai.testing.ScriptedModel{ .responses = &responses };
    var capture: Capture = .{};
    const diagnostics = zigai.Diagnostics{
        .sink = .{ .context = &capture, .emitFn = Capture.emit },
        .minimum_level = .trace,
        .capture_content = true,
        .sensitive_values = &.{"private"},
    };
    var first = try (zigai.Agent{
        .model = first_model.model(),
        .diagnostics = diagnostics,
    }).run(std.testing.allocator, "private prompt");
    defer first.deinit();
    var second = try (zigai.Agent{
        .model = second_model.model(),
        .capabilities = &.{.{}},
        .diagnostics = diagnostics,
    }).run(std.testing.allocator, "private prompt");
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 2), capture.ends);
    try std.testing.expect(capture.redactions >= 4);
}

test "agent online evaluations preserve traces across success capability and failure runs" {
    const State = struct {
        successes: usize = 0,
        failures: usize = 0,
        results: usize = 0,
        spans: usize = 0,

        fn evaluate(
            context: *anyopaque,
            _: std.mem.Allocator,
            observation: zigai.OnlineEvalObservation,
        ) !zigai.OnlineEvaluation {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(observation.trace.isValid());
            try std.testing.expectEqualStrings("production prompt", observation.prompt);
            switch (observation.outcome) {
                .success => |success| {
                    self.successes += 1;
                    try std.testing.expectEqualStrings("done", success.output);
                    try std.testing.expectEqual(@as(usize, 1), success.model_requests);
                },
                .failure => |failure| {
                    self.failures += 1;
                    try std.testing.expectEqualStrings("TestProviderFailure", failure.name);
                },
            }
            return .{ .passed = true, .score = 1 };
        }

        fn result(context: *anyopaque, value: zigai.OnlineEvalResult) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(value.trace.isValid());
            try std.testing.expectEqualStrings("production-quality", value.evaluator_name);
            self.results += 1;
        }

        fn span(context: *anyopaque, value: zigai.TelemetrySpan) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.name, "invoke_agent")) self.spans += 1;
        }

        fn metric(_: *anyopaque, _: zigai.TelemetryMetric) !void {}
    };
    const FailingModel = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.TestProviderFailure;
        }
    };

    var state: State = .{};
    const evaluators = [_]zigai.OnlineEvaluator{.{
        .name = "production-quality",
        .context = &state,
        .evaluateFn = State.evaluate,
    }};
    var queue = try zigai.OnlineEvalQueue.init(
        std.testing.allocator,
        std.testing.io,
        &evaluators,
        .{ .context = &state, .emitFn = State.result },
        .{},
    );
    defer queue.deinit();
    const telemetry = zigai.OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &state, .spanFn = State.span, .metricFn = State.metric },
    };
    const parts = [_]zigai.model.Part{.{ .text = "done" }};
    const responses = [_]zigai.ModelResponse{.{ .parts = &parts }};
    var ordinary_model = zigai.testing.ScriptedModel{ .responses = &responses };
    var capability_model = zigai.testing.ScriptedModel{ .responses = &responses };

    var ordinary = try (zigai.Agent{
        .model = ordinary_model.model(),
        .telemetry = telemetry,
        .online_evals = &queue,
    }).run(std.testing.allocator, "production prompt");
    defer ordinary.deinit();
    var capability = try (zigai.Agent{
        .model = capability_model.model(),
        .capabilities = &.{.{}},
        .telemetry = telemetry,
        .online_evals = &queue,
    }).run(std.testing.allocator, "production prompt");
    defer capability.deinit();

    var unused: u8 = 0;
    try std.testing.expectError(
        error.TestProviderFailure,
        (zigai.Agent{
            .model = .{ .context = &unused, .profile = .{}, .requestFn = FailingModel.request },
            .retry_policy = .{ .max_retries = 0 },
            .telemetry = telemetry,
            .online_evals = &queue,
        }).run(std.testing.allocator, "production prompt"),
    );
    try std.testing.expectEqual(@as(usize, 3), queue.stats().pending);
    const processed = try queue.flush();
    try std.testing.expectEqual(@as(usize, 3), processed.observations);
    try std.testing.expectEqual(@as(usize, 3), processed.evaluations);
    try std.testing.expectEqual(@as(usize, 2), state.successes);
    try std.testing.expectEqual(@as(usize, 1), state.failures);
    try std.testing.expectEqual(@as(usize, 3), state.results);
    try std.testing.expectEqual(@as(usize, 3), state.spans);

    var unused_model = zigai.testing.ScriptedModel{ .responses = &responses };
    try std.testing.expectError(
        zigai.AgentError.OnlineEvaluationRequiresTelemetry,
        (zigai.Agent{ .model = unused_model.model(), .online_evals = &queue }).run(
            std.testing.allocator,
            "production prompt",
        ),
    );
}

test "agent applies an explicit versioned price table" {
    const Model = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.model.ModelResponse {
            return .{
                .parts = &.{.{ .text = "priced" }},
                .usage = .{
                    .input_tokens = 1_000_000,
                    .cache_read_tokens = 100_000,
                    .output_tokens = 100_000,
                },
            };
        }
    };
    const Capture = struct {
        cost: f64 = 0,

        fn span(_: *anyopaque, _: zigai.TelemetrySpan) !void {}

        fn metric(context: *anyopaque, value: zigai.TelemetryMetric) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.name, "gen_ai.client.estimated_cost")) self.cost += value.value;
        }
    };
    var unused: u8 = 0;
    var capture: Capture = .{};
    const model = zigai.Model{
        .context = &unused,
        .profile = .{},
        .provider_name = "openai",
        .model_name = "gpt-5-nano",
        .requestFn = Model.request,
    };
    var result = try (zigai.Agent{
        .model = model,
        .io = std.testing.io,
        .price_table = zigai.pricing.builtin,
        .telemetry = .{
            .io = std.testing.io,
            .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        },
    }).run(std.testing.allocator, "price this");
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 85_500_000), result.usage.cost.?.nano_usd);
    try std.testing.expectEqual(zigai.UsageCostSource.price_table, result.usage.cost_source.?);
    try std.testing.expectEqualStrings(zigai.pricing.builtin_version, result.usage.cost_table_version.?);
    try std.testing.expectEqual(@as(usize, 1), result.usage.requests);
    try std.testing.expectEqual(@as(usize, 0), result.usage.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), result.messages.len - 1);
    try std.testing.expect(result.messages[result.messages.len - 1].response.usage.duration_ms != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0855), capture.cost, 0.0000001);

    try std.testing.expectError(
        zigai.AgentError.CostLimitExceeded,
        (zigai.Agent{
            .model = model,
            .price_table = zigai.pricing.builtin,
            .limits = .{ .max_cost_nano_usd = 85_499_999 },
        }).run(std.testing.allocator, "price this"),
    );
    const overflowing_prices = zigai.PriceTable{
        .version = "overflow",
        .entries = &.{.{
            .provider = "openai",
            .model = "gpt-5-nano",
            .rates = .{ .input = std.math.maxInt(u64), .cache_read = std.math.maxInt(u64), .output = std.math.maxInt(u64) },
        }},
    };
    try std.testing.expectError(
        zigai.AgentError.UsageOverflow,
        (zigai.Agent{ .model = model, .price_table = overflowing_prices }).run(std.testing.allocator, "price this"),
    );
}

test "provider credentials reach only the trusted transport" {
    const secret = "provider-secret";
    const TransportState = struct {
        saw_secret: bool = false,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: zigai.transport.Request) !zigai.transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (request.headers) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
                self.saw_secret = std.mem.eql(u8, header.value, "Bearer " ++ secret) and
                    header.isSensitive() and std.mem.eql(u8, header.redactedValue(), "[REDACTED]");
            }
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"safe\"}]}]}",
                ),
            };
        }
    };
    const Capture = struct {
        spans: usize = 0,

        fn checkAttributes(attributes: []const zigai.telemetry.Attribute) !void {
            for (attributes) |attribute| switch (attribute.value) {
                .string => |value| try std.testing.expect(std.mem.indexOf(u8, value, secret) == null),
                else => {},
            };
        }

        fn span(context: *anyopaque, value: zigai.TelemetrySpan) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.spans += 1;
            try checkAttributes(value.attributes);
        }

        fn metric(_: *anyopaque, value: zigai.TelemetryMetric) !void {
            try checkAttributes(value.attributes);
        }
    };
    var transport_state: TransportState = .{};
    var capture: Capture = .{};
    var provider_state = zigai.providers.openai.Provider.init(secret, .{ .context = &transport_state, .sendFn = TransportState.send });
    var client = zigai.providers.openai.Client{
        .model_name = "gpt-test",
        .provider = provider_state.provider(),
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .telemetry = .{
            .io = std.testing.io,
            .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        },
    }).run(std.testing.allocator, "hello");
    defer result.deinit();
    try std.testing.expectEqualStrings("safe", result.output);
    try std.testing.expect(transport_state.saw_secret);
    try std.testing.expect(capture.spans > 0);
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

    var capability_capture: Capture = .{};
    var capability_failed = FlakyModel{
        .failures_remaining = 1,
        .failure = error.ProviderServerError,
        .response = .{ .parts = &parts },
    };
    try std.testing.expectError(error.ProviderServerError, (zigai.Agent{
        .model = capability_failed.model(),
        .capabilities = &.{.{}},
        .hooks = &.{.{ .context = &capability_capture, .eventFn = Capture.event }},
        .retry_policy = .{ .max_retries = 0 },
    }).run(std.testing.allocator, "hi"));
    try std.testing.expectEqual(@as(usize, 1), capability_capture.run_errors);
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

test "agent keeps correlation and idempotency stable across one logical retry" {
    const State = struct {
        attempts: usize = 0,
        key: [32]u8 = undefined,
        saw_correlation: bool = false,
        saw_same_key: bool = false,

        fn request(context: *anyopaque, _: std.mem.Allocator, request_value: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            self.saw_correlation = std.mem.eql(u8, request_value.request_id orelse "", "run-123");
            const key = request_value.idempotency_key orelse return error.MissingIdempotencyKey;
            try std.testing.expectEqual(@as(usize, 32), key.len);
            if (self.attempts == 1) {
                @memcpy(&self.key, key);
                return error.ProviderConnectionError;
            }
            self.saw_same_key = std.mem.eql(u8, &self.key, key);
            return .{ .parts = &.{.{ .text = "done" }} };
        }
    };
    var state: State = .{};
    const retrying_model = zigai.Model{
        .context = &state,
        .profile = .{ .supports_idempotency_key = true },
        .requestFn = State.request,
    };
    var result = try (zigai.Agent{ .model = retrying_model, .io = std.testing.io }).runWithOptions(
        std.testing.allocator,
        "retry",
        .{ .request_id = "run-123" },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), state.attempts);
    try std.testing.expect(state.saw_correlation);
    try std.testing.expect(state.saw_same_key);

    state = .{};
    try std.testing.expectError(zigai.Agent.Error.RetryIdempotencyRequiresIo, (zigai.Agent{
        .model = retrying_model,
    }).run(std.testing.allocator, "retry"));
    try std.testing.expectEqual(@as(usize, 0), state.attempts);
}

test "agent stops before a server-directed delay exceeds the retry budget" {
    const State = struct {
        attempts: usize = 0,

        fn request(context: *anyopaque, _: std.mem.Allocator, request_value: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            request_value.error_observer.?.observe(.{
                .provider = "test",
                .status = 503,
                .message = "unavailable",
                .body = "{}",
                .retry_after_seconds = 2,
            });
            return error.ProviderServerError;
        }
    };
    var state: State = .{};
    try std.testing.expectError(error.ProviderServerError, (zigai.Agent{
        .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
        .io = std.testing.io,
        .retry_policy = .{
            .backoff = .{ .maximum_delay_ms = 2_000 },
            .max_total_delay_ms = 1_999,
        },
    }).run(std.testing.allocator, "retry"));
    try std.testing.expectEqual(@as(usize, 1), state.attempts);
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
    try std.testing.expectEqualStrings("typed result", result.messages[2].request.parts[0].tool_return.content);
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

test "one run deadline bounds model and tool work without late writes" {
    const BlockingModel = struct {
        io: std.Io,
        active: std.atomic.Value(bool) = .init(false),
        saw_bounded_timeout: std.atomic.Value(bool) = .init(false),

        fn request(context: *anyopaque, _: std.mem.Allocator, model_request: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            const timeout_ms = model_request.timeout_ms orelse return error.MissingRunTimeout;
            self.saw_bounded_timeout.store(timeout_ms > 0 and timeout_ms <= 100, .seq_cst);
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            try (std.Io.Timeout{ .duration = .{
                .raw = .fromSeconds(10),
                .clock = .awake,
            } }).sleep(self.io);
            return .{ .parts = &.{.{ .text = "late" }} };
        }
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var blocking_model = BlockingModel{ .io = threaded.io() };
    try std.testing.expectError(zigai.Agent.Error.RunTimedOut, (zigai.Agent{
        .model = .{ .context = &blocking_model, .profile = .{}, .requestFn = BlockingModel.request },
        .io = threaded.io(),
        .run_timeout_ms = 200,
    }).runWithOptions(std.testing.allocator, "wait", .{ .timeout_ms = 100 }));
    try std.testing.expect(blocking_model.saw_bounded_timeout.load(.seq_cst));
    try std.testing.expect(!blocking_model.active.load(.seq_cst));
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
                .request_id = "req_123",
            });
            return error.ProviderRateLimited;
        }
        fn hook(context: *anyopaque, event: zigai.agent.RetryEvent) !void {
            const state: *State = @ptrCast(@alignCast(context));
            state.retries += 1;
            try std.testing.expectEqual(@as(?u64, 3), event.retry_after_seconds);
            try std.testing.expectEqual(@as(?u64, 0), event.rate_limit_remaining_requests);
            try std.testing.expectEqual(@as(?u64, 12), event.rate_limit_remaining_tokens);
            try std.testing.expectEqualStrings("req_123", event.provider_request_id.?);
            try std.testing.expectEqual(@as(u64, 0), event.total_delay_ms);
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
                .function_tool_result => |tool_event| {
                    self.tool_results += 1;
                    try std.testing.expectEqualStrings("ok", tool_event.result.content);
                },
                .final_result => |final_event| {
                    self.finals += 1;
                    try std.testing.expectEqualStrings("done", final_event.output);
                },
                else => {},
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
    try std.testing.expectEqual(@as(usize, 7), capture.model_events);
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
            try model_sink.emit(.{ .part_delta = .{
                .index = 0,
                .delta = .{ .text = .{ .content_delta = "partial" } },
            } });
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
