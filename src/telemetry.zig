//! OpenTelemetry-shaped spans and metrics for agent lifecycle events.

const std = @import("std");
const model_types = @import("model.zig");

pub const Attribute = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
    };
};

pub const Span = struct {
    name: []const u8,
    kind: Kind = .internal,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8 = null,
    start_time_unix_nano: i128,
    end_time_unix_nano: i128,
    duration_seconds: f64,
    status: Status,
    attributes: []const Attribute,

    pub const Kind = enum { internal, client };
    pub const Status = enum { ok, error_status };
};

pub const Metric = struct {
    name: []const u8,
    kind: Kind,
    value: f64,
    unit: []const u8,
    attributes: []const Attribute,

    pub const Kind = enum { counter, histogram };
};

/// Synchronous bridge to an OpenTelemetry SDK or OTLP exporter.
pub const Exporter = struct {
    context: *anyopaque,
    spanFn: *const fn (context: *anyopaque, span: Span) anyerror!void,
    metricFn: *const fn (context: *anyopaque, metric: Metric) anyerror!void,

    pub fn span(self: Exporter, value: Span) !void {
        return self.spanFn(self.context, value);
    }

    pub fn metric(self: Exporter, value: Metric) !void {
        return self.metricFn(self.context, value);
    }
};

pub const CostEstimator = struct {
    context: *anyopaque,
    estimateFn: *const fn (
        context: *anyopaque,
        provider_name: ?[]const u8,
        model_name: ?[]const u8,
        usage: model_types.Usage,
    ) f64,

    pub fn estimate(
        self: CostEstimator,
        provider_name: ?[]const u8,
        model_name: ?[]const u8,
        usage: model_types.Usage,
    ) f64 {
        return self.estimateFn(self.context, provider_name, model_name, usage);
    }
};

/// OpenTelemetry instrumentation settings copied into each isolated agent run.
pub const OpenTelemetry = struct {
    io: std.Io,
    exporter: Exporter,
    cost_estimator: ?CostEstimator = null,
    /// Prompt content is sensitive and is never captured unless explicitly enabled.
    capture_prompts: bool = false,
    /// Observability failures do not fail agent runs unless this is disabled.
    fail_open: bool = true,

    pub fn start(self: OpenTelemetry, allocator: std.mem.Allocator) Run {
        return .{
            .allocator = allocator,
            .config = self,
            .trace_id = randomId(16, self.io),
            .run_span_id = randomId(8, self.io),
        };
    }
};

/// Per-run instrumentation state. Applications normally configure this through `Agent.telemetry`.
pub const Run = struct {
    allocator: std.mem.Allocator,
    config: OpenTelemetry,
    trace_id: [16]u8,
    run_span_id: [8]u8,
    model: ?model_types.Model = null,
    request_provider_name: ?[]const u8 = null,
    request_model_name: ?[]const u8 = null,
    input_messages: ?[]u8 = null,
    run_start: ?Start = null,
    request_start: ?Start = null,
    request_span_id: ?[8]u8 = null,
    last_request_span_id: ?[8]u8 = null,
    request_number: usize = 0,
    tool_starts: std.ArrayList(ToolStart) = .empty,

    const Start = struct {
        real_ns: i128,
        awake_ns: i128,
    };

    const ToolStart = struct {
        id: []const u8,
        name: []const u8,
        start: Start,
        span_id: [8]u8,
        parent_span_id: ?[8]u8,
    };

    pub fn deinit(self: *Run) void {
        if (self.input_messages) |messages| self.allocator.free(messages);
        self.tool_starts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes an agent lifecycle event. Values are borrowed for this call only.
    pub fn observe(self: *Run, event: anytype) !void {
        switch (event) {
            .run_start => |value| try self.onRunStart(value.prompt, value.model),
            .run_end => try self.onRunEnd(.ok, null),
            .run_error => |value| try self.onRunEnd(.error_status, value.failure),
            .model_request_start => |value| try self.onRequestStart(value.number),
            .model_request_end => |value| {
                self.request_provider_name = value.response.provider_name orelse self.request_provider_name;
                self.request_model_name = value.response.model_name orelse self.request_model_name;
                try self.onRequestEnd(.ok, null, value.response.usage);
            },
            .model_request_error => |value| {
                try self.onRequestEnd(.error_status, value.failure, .{});
                if (value.will_retry) try self.retryMetric("model");
            },
            .tool_validation_start => |value| try self.onToolStart(value.call.id, value.call.name),
            .tool_validation_error => |value| try self.onToolEnd(value.call.id, .error_status, value.failure),
            .tool_validation_end, .tool_execution_start => {},
            .tool_execution_end => |value| try self.onToolEnd(value.call.id, .ok, null),
            .tool_execution_error => |value| {
                try self.onToolEnd(value.call.id, .error_status, value.failure);
                if (value.recoverable) try self.retryMetric("tool");
            },
            .output_validation_error => |value| if (value.will_retry) try self.retryMetric("output"),
            .output_validation_start, .output_validation_end, .stream_event => {},
        }
    }

    fn onRunStart(self: *Run, prompt: []const u8, model: model_types.Model) !void {
        self.model = model;
        self.input_messages = if (self.config.capture_prompts)
            try encodePrompt(self.allocator, prompt)
        else
            null;
        self.run_start = self.now();
        try self.exportMetric(.{
            .name = "zigai.agent.runs",
            .kind = .counter,
            .value = 1,
            .unit = "{run}",
            .attributes = &.{},
        });
    }

    fn onRunEnd(
        self: *Run,
        status: Span.Status,
        failure: ?anyerror,
    ) !void {
        const start = self.run_start orelse return;
        const end = self.now();
        var attributes: [8]Attribute = undefined;
        var count: usize = 0;
        self.modelAttributes(&attributes, &count);
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "invoke_agent" } };
        count += 1;
        if (self.input_messages) |messages| {
            attributes[count] = .{ .key = "gen_ai.input.messages", .value = .{ .string = messages } };
            count += 1;
        }
        if (failure) |value| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = @errorName(value) } };
            count += 1;
        }
        try self.exportSpan(makeSpan(
            "gen_ai.invoke_agent",
            .internal,
            self.trace_id,
            self.run_span_id,
            null,
            start,
            end,
            status,
            attributes[0..count],
        ));
        try self.durationMetric("zigai.agent.run.duration", start, end, "invoke_agent");
        self.run_start = null;
    }

    fn onRequestStart(self: *Run, number: usize) !void {
        self.request_number = number;
        self.request_start = self.now();
        self.request_span_id = randomId(8, self.config.io);
        if (self.model) |model| {
            self.request_provider_name = model.provider_name;
            self.request_model_name = model.model_name;
        }
    }

    fn onRequestEnd(
        self: *Run,
        status: Span.Status,
        failure: ?anyerror,
        usage: model_types.Usage,
    ) !void {
        const start = self.request_start orelse return;
        const end = self.now();
        var attributes: [8]Attribute = undefined;
        var count: usize = 0;
        self.modelAttributes(&attributes, &count);
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "chat" } };
        count += 1;
        attributes[count] = .{ .key = "zigai.request.number", .value = .{ .integer = @intCast(self.request_number) } };
        count += 1;
        if (usage.totalTokens() > 0) {
            attributes[count] = .{ .key = "gen_ai.usage.input_tokens", .value = .{ .integer = @intCast(usage.input_tokens) } };
            count += 1;
            attributes[count] = .{ .key = "gen_ai.usage.output_tokens", .value = .{ .integer = @intCast(usage.output_tokens) } };
            count += 1;
        }
        if (failure) |value| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = @errorName(value) } };
            count += 1;
        }
        const span_id = self.request_span_id orelse randomId(8, self.config.io);
        try self.exportSpan(makeSpan(
            "gen_ai.chat",
            .client,
            self.trace_id,
            span_id,
            self.run_span_id,
            start,
            end,
            status,
            attributes[0..count],
        ));
        try self.durationMetric("gen_ai.client.operation.duration", start, end, "chat");
        try self.exportMetric(.{
            .name = "zigai.model.requests",
            .kind = .counter,
            .value = 1,
            .unit = "{request}",
            .attributes = attributes[0..count],
        });
        if (usage.totalTokens() > 0) {
            try self.usageMetrics(usage);
            if (self.config.cost_estimator) |estimator| {
                try self.exportMetric(.{
                    .name = "gen_ai.client.estimated_cost",
                    .kind = .counter,
                    .value = estimator.estimate(self.request_provider_name, self.request_model_name, usage),
                    .unit = "USD",
                    .attributes = attributes[0..count],
                });
            }
        }
        self.last_request_span_id = span_id;
        self.request_start = null;
        self.request_span_id = null;
    }

    fn onToolStart(self: *Run, id: []const u8, name: []const u8) !void {
        try self.tool_starts.append(self.allocator, .{
            .id = id,
            .name = name,
            .start = self.now(),
            .span_id = randomId(8, self.config.io),
            .parent_span_id = self.last_request_span_id,
        });
    }

    fn onToolEnd(self: *Run, id: []const u8, status: Span.Status, failure: ?anyerror) !void {
        var index: ?usize = null;
        for (self.tool_starts.items, 0..) |item, item_index| {
            if (std.mem.eql(u8, item.id, id)) {
                index = item_index;
                break;
            }
        }
        const item_index = index orelse return;
        const item = self.tool_starts.swapRemove(item_index);
        const end = self.now();
        var attributes: [6]Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "execute_tool" } };
        count += 1;
        attributes[count] = .{ .key = "gen_ai.tool.name", .value = .{ .string = item.name } };
        count += 1;
        attributes[count] = .{ .key = "gen_ai.tool.call.id", .value = .{ .string = item.id } };
        count += 1;
        if (failure) |value| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = @errorName(value) } };
            count += 1;
        }
        try self.exportSpan(makeSpan(
            "gen_ai.execute_tool",
            .internal,
            self.trace_id,
            item.span_id,
            item.parent_span_id orelse self.run_span_id,
            item.start,
            end,
            status,
            attributes[0..count],
        ));
        try self.durationMetric("zigai.tool.duration", item.start, end, "execute_tool");
        try self.exportMetric(.{
            .name = "zigai.tool.calls",
            .kind = .counter,
            .value = 1,
            .unit = "{call}",
            .attributes = attributes[0..count],
        });
    }

    fn retryMetric(self: *Run, kind: []const u8) !void {
        const attributes = [_]Attribute{.{ .key = "zigai.retry.kind", .value = .{ .string = kind } }};
        try self.exportMetric(.{
            .name = "zigai.agent.retries",
            .kind = .counter,
            .value = 1,
            .unit = "{retry}",
            .attributes = &attributes,
        });
    }

    fn usageMetrics(self: *Run, usage: model_types.Usage) !void {
        for ([_]struct { name: []const u8, value: u64 }{
            .{ .name = "input", .value = usage.input_tokens },
            .{ .name = "output", .value = usage.output_tokens },
        }) |token| {
            var attributes: [4]Attribute = undefined;
            var count: usize = 0;
            self.modelAttributes(&attributes, &count);
            attributes[count] = .{ .key = "gen_ai.token.type", .value = .{ .string = token.name } };
            count += 1;
            try self.exportMetric(.{
                .name = "gen_ai.client.token.usage",
                .kind = .histogram,
                .value = @floatFromInt(token.value),
                .unit = "{token}",
                .attributes = attributes[0..count],
            });
        }
    }

    fn durationMetric(self: *Run, name: []const u8, start: Start, end: Start, operation: []const u8) !void {
        const attributes = [_]Attribute{.{ .key = "gen_ai.operation.name", .value = .{ .string = operation } }};
        try self.exportMetric(.{
            .name = name,
            .kind = .histogram,
            .value = durationSeconds(start, end),
            .unit = "s",
            .attributes = &attributes,
        });
    }

    fn modelAttributes(self: *Run, attributes: []Attribute, count: *usize) void {
        if (self.request_provider_name) |provider| {
            attributes[count.*] = .{ .key = "gen_ai.provider.name", .value = .{ .string = provider } };
            count.* += 1;
        }
        if (self.request_model_name) |name| {
            attributes[count.*] = .{ .key = "gen_ai.request.model", .value = .{ .string = name } };
            count.* += 1;
        }
    }

    fn now(self: Run) Start {
        return .{
            .real_ns = @intCast(std.Io.Clock.real.now(self.config.io).nanoseconds),
            .awake_ns = @intCast(std.Io.Clock.awake.now(self.config.io).nanoseconds),
        };
    }

    fn exportSpan(self: Run, value: Span) !void {
        self.config.exporter.span(value) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }

    fn exportMetric(self: Run, value: Metric) !void {
        self.config.exporter.metric(value) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }
};

fn makeSpan(
    name: []const u8,
    kind: Span.Kind,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    start: Run.Start,
    end: Run.Start,
    status: Span.Status,
    attributes: []const Attribute,
) Span {
    return .{
        .name = name,
        .kind = kind,
        .trace_id = trace_id,
        .span_id = span_id,
        .parent_span_id = parent_span_id,
        .start_time_unix_nano = start.real_ns,
        .end_time_unix_nano = end.real_ns,
        .duration_seconds = durationSeconds(start, end),
        .status = status,
        .attributes = attributes,
    };
}

fn randomId(comptime length: usize, io: std.Io) [length]u8 {
    var id: [length]u8 = undefined;
    std.Io.random(io, &id);
    for (id) |byte| if (byte != 0) return id;
    id[length - 1] = 1;
    return id; // all-zero random fallback
}

fn durationSeconds(start: Run.Start, end: Run.Start) f64 {
    const duration_ns = @max(@as(i128, 0), end.awake_ns - start.awake_ns);
    return @as(f64, @floatFromInt(duration_ns)) / std.time.ns_per_s;
}

fn encodePrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginArray();
    try json.beginObject();
    try json.objectField("role");
    try json.write("user");
    try json.objectField("parts");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("content");
    try json.write(prompt);
    try json.endObject();
    try json.endArray();
    try json.endObject();
    try json.endArray();
    return output.toOwnedSlice();
}

test "telemetry records captured prompts and lifecycle failures" {
    const agent_types = @import("agent.zig");
    const Capture = struct {
        error_spans: usize = 0,
        retries: usize = 0,
        saw_prompt: bool = false,

        fn span(context: *anyopaque, value: Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value.status == .error_status) self.error_spans += 1;
            for (value.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "gen_ai.input.messages")) {
                    try std.testing.expect(std.mem.indexOf(u8, attribute.value.string, "private prompt") != null);
                    self.saw_prompt = true;
                }
            }
        }

        fn metric(context: *anyopaque, value: Metric) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.name, "zigai.agent.retries")) self.retries += 1;
        }
    };
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return .{ .parts = &.{} };
        }
    };
    var capture: Capture = .{};
    var unused: u8 = 0;
    const model = model_types.Model{
        .context = &unused,
        .profile = .{},
        .provider_name = "test",
        .model_name = "errors",
        .requestFn = Stub.request,
    };
    const stub_response = try model.request(std.testing.allocator, .{ .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 0), stub_response.parts.len);
    var run = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .capture_prompts = true,
    }).start(std.testing.allocator);
    defer run.deinit();

    try run.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "private prompt", .model = model } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_start = .{
        .number = 1,
        .request = .{ .messages = &.{} },
        .streaming = false,
    } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_end = .{
        .number = 1,
        .response = .{ .parts = &.{} },
    } });
    const first = model_types.ToolCall{ .id = "first", .name = "lookup", .arguments_json = "{}" };
    const second = model_types.ToolCall{ .id = "second", .name = "lookup", .arguments_json = "{}" };
    const third = model_types.ToolCall{ .id = "third", .name = "lookup", .arguments_json = "{}" };
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = first } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = second } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_end = .{ .call = second, .content = "ok" } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_error = .{ .call = first, .failure = error.InvalidToolArguments } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = third } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_error = .{
        .call = third,
        .failure = error.ToolFailed,
        .recoverable = true,
    } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_error = .{
        .output = "invalid",
        .failure = error.InvalidOutput,
        .retry_number = 1,
        .will_retry = true,
    } });
    try run.observe(agent_types.LifecycleEvent{ .run_error = .{ .failure = error.ProviderServerError } });

    try std.testing.expectEqual(@as(usize, 3), capture.error_spans);
    try std.testing.expectEqual(@as(usize, 2), capture.retries);
    try std.testing.expect(capture.saw_prompt);
}
