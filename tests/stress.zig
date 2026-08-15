//! Bounded production stress scenarios driven entirely through ZigAI's public API.

const std = @import("std");
const zigai = @import("zigai");

const final_parts = [_]zigai.Part{.{ .text = "done" }};

const CountingTool = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn execute(context: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.calls.fetchAdd(1, .seq_cst);
        return gpa.dupe(u8, "ok");
    }

    fn tool(self: *@This()) zigai.Tool {
        return .{
            .definition = .{ .name = "work", .description = "", .parameters_json_schema = "{}" },
            .context = self,
            .executeFn = execute,
        };
    }
};

test "long tool loop preserves ownership and terminates" {
    const tool_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "call",
        .name = "work",
        .arguments_json = "{}",
    } }};
    const State = struct {
        rounds: usize,
        requests: usize = 0,

        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.requests += 1;
            if (self.requests < self.rounds) return .{ .parts = &tool_parts };
            return .{ .parts = &final_parts };
        }
    };

    const rounds = 128;
    var state = State{ .rounds = rounds };
    var counter: CountingTool = .{};
    const tool = counter.tool();
    var result = try (zigai.Agent{
        .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
        .tools = &.{tool},
        .limits = .{ .max_model_requests = rounds + 1, .max_tool_calls = rounds },
    }).run(std.testing.allocator, "keep going");
    defer result.deinit();

    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(rounds + 1, state.requests);
    try std.testing.expectEqual(rounds, counter.calls.load(.seq_cst));
}

test "parallel tool batches overlap and drain" {
    const call_count = 32;
    var call_parts: [call_count]zigai.Part = undefined;
    for (&call_parts) |*part| part.* = .{ .tool_call = .{
        .id = "parallel-call",
        .name = "work",
        .arguments_json = "{}",
    } };
    const responses = [_]zigai.ModelResponse{
        .{ .parts = &call_parts },
        .{ .parts = &final_parts },
    };
    var scripted = zigai.testing.ScriptedModel{ .responses = &responses };

    const ParallelTool = struct {
        active: std.atomic.Value(usize) = .init(0),
        calls: std.atomic.Value(usize) = .init(0),
        overlapped: std.atomic.Value(bool) = .init(false),

        fn execute(
            context: *anyopaque,
            gpa: std.mem.Allocator,
            run_context: zigai.ToolRunContext,
            _: []const u8,
        ) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.active.fetchAdd(1, .seq_cst) > 0) self.overlapped.store(true, .seq_cst);
            defer _ = self.active.fetchSub(1, .seq_cst);
            _ = self.calls.fetchAdd(1, .seq_cst);
            const io = run_context.io orelse return error.MissingIo;
            try (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(2), .clock = .awake } }).sleep(io);
            return gpa.dupe(u8, "ok");
        }

        fn unexpectedFallback(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]const u8 {
            return error.UnexpectedFallback;
        }
    };
    var state: ParallelTool = .{};
    const tool = zigai.Tool{
        .definition = .{ .name = "work", .description = "", .parameters_json_schema = "{}" },
        .context = &state,
        .executeFn = ParallelTool.unexpectedFallback,
        .executeWithContextFn = ParallelTool.execute,
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var result = try (zigai.Agent{
        .model = scripted.model(),
        .tools = &.{tool},
        .io = threaded.io(),
    }).run(std.testing.allocator, "run in parallel");
    defer result.deinit();

    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(call_count, state.calls.load(.seq_cst));
    try std.testing.expect(state.overlapped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.active.load(.seq_cst));
}

test "in-flight cancellation races drain model work" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const State = struct {
        io: std.Io,
        started: std.atomic.Value(bool) = .init(false),
        active: std.atomic.Value(bool) = .init(false),

        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            self.started.store(true, .release);
            try (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }).sleep(self.io);
            return .{ .parts = &final_parts };
        }

        fn cancelWhenStarted(self: *@This(), token: *zigai.CancellationToken) void {
            while (!self.started.load(.acquire)) std.Thread.yield() catch {};
            token.cancel();
        }
    };

    for (0..32) |_| {
        var token: zigai.CancellationToken = .{};
        var state = State{ .io = threaded.io() };
        const canceller = try std.Thread.spawn(.{}, State.cancelWhenStarted, .{ &state, &token });
        defer canceller.join();
        try std.testing.expectError(zigai.AgentError.Cancelled, (zigai.Agent{
            .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
            .io = threaded.io(),
            .cancellation = &token,
        }).run(std.testing.allocator, "cancel"));
        try std.testing.expect(!state.active.load(.seq_cst));
    }
}

test "connection failures recover repeatedly through retry policy" {
    const State = struct {
        fail_next: bool = true,
        attempts: usize = 0,

        fn request(context: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            if (self.fail_next) {
                self.fail_next = false;
                return error.ProviderConnectionError;
            }
            self.fail_next = true;
            return .{ .parts = &final_parts };
        }
    };
    var state: State = .{};
    const model = zigai.Model{ .context = &state, .profile = .{}, .requestFn = State.request };
    for (0..64) |_| {
        var result = try (zigai.Agent{
            .model = model,
            .retry_policy = .{ .max_retries = 1 },
        }).run(std.testing.allocator, "reconnect");
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 128), state.attempts);
}

test "large histories copy without aliasing caller storage" {
    const history_len = 1024;
    const history_parts = [_]zigai.RequestPart{.{ .user_prompt = .{ .text = "old" } }};
    var history: [history_len]zigai.Message = undefined;
    for (&history) |*message| message.* = .{ .request = .{ .parts = &history_parts } };

    const State = struct {
        expected_messages: usize,

        fn request(context: *anyopaque, _: std.mem.Allocator, request_value: zigai.ModelRequest) !zigai.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(self.expected_messages, request_value.messages.len);
            return .{ .parts = &final_parts };
        }
    };
    var state = State{ .expected_messages = history_len + 1 };
    var result = try (zigai.Agent{
        .model = .{ .context = &state, .profile = .{}, .requestFn = State.request },
    }).runWithOptions(std.testing.allocator, "new", .{ .message_history = &history });
    defer result.deinit();

    history[0] = .{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "changed" } }} } };
    try std.testing.expectEqualStrings("old", result.messages[0].request.parts[0].user_prompt.text);
    try std.testing.expectEqual(history_len + 2, result.messages.len);
}

test "partial streaming emits every chunk and one final" {
    const chunk_count = 2048;
    const StreamModel = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: zigai.ModelRequest) !zigai.ModelResponse {
            return error.UnexpectedBufferedRequest;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: zigai.ModelRequest,
            sink: zigai.ModelStreamSink,
        ) !zigai.ModelResponse {
            for (0..chunk_count) |_| try sink.emit(.{ .text_delta = "x" });
            return .{ .parts = &final_parts };
        }
    };
    const Capture = struct {
        chunks: usize = 0,
        finals: usize = 0,

        fn event(context: *anyopaque, event_value: zigai.AgentStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .model => |model_event| switch (model_event) {
                    .text_delta => self.chunks += 1,
                    else => {},
                },
                .final_output => self.finals += 1,
                .tool_result => {},
            }
        }
    };
    var model_context: u8 = 0;
    var capture: Capture = .{};
    const model = zigai.Model{
        .context = &model_context,
        .profile = .{ .supports_streaming = true },
        .requestFn = StreamModel.request,
        .streamFn = StreamModel.stream,
    };
    var result = try (zigai.Agent{ .model = model }).runStream(
        std.testing.allocator,
        "stream",
        .{ .context = &capture, .eventFn = Capture.event },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(chunk_count, capture.chunks);
    try std.testing.expectEqual(@as(usize, 1), capture.finals);
}

fn runAgentWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const tool_parts = [_]zigai.Part{.{ .tool_call = .{
        .id = "call",
        .name = "work",
        .arguments_json = "{}",
    } }};
    const responses = [_]zigai.ModelResponse{
        .{ .parts = &tool_parts },
        .{ .parts = &final_parts },
    };
    var scripted = zigai.testing.ScriptedModel{ .responses = &responses };
    var counter: CountingTool = .{};
    const tool = counter.tool();
    var result = try (zigai.Agent{ .model = scripted.model(), .tools = &.{tool} }).run(gpa, "allocate");
    result.deinit();
}

test "agent tool loop releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runAgentWithAllocationFailures,
        .{},
    );
}

test "HTTP clients tolerate repeated init and deinit" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    for (0..512) |_| {
        var client = zigai.transport.HttpTransport.init(std.testing.allocator, threaded.io());
        _ = client.transport();
        client.deinit();
    }
}
