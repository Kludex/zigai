//! Backend-neutral structured diagnostics with bounded, redacted attributes.

const std = @import("std");

pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warning,
    err,
};

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

/// Borrowed structured event. A sink must copy any data retained after `emit`.
pub const Event = struct {
    level: Level,
    name: []const u8,
    attributes: []const Attribute = &.{},
    attributes_dropped: usize = 0,
    values_truncated: usize = 0,
    sensitive_values_redacted: usize = 0,
};

/// Application-owned bridge to a logging backend.
pub const Sink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: Event) anyerror!void,

    pub fn emit(self: Sink, event: Event) !void {
        return self.emitFn(self.context, event);
    }
};

pub const Config = struct {
    sink: Sink,
    minimum_level: Level = .info,
    max_attributes: usize = 24,
    max_key_bytes: usize = 128,
    max_value_bytes: usize = 1024,
    /// Exact sensitive byte strings replaced before any truncation.
    sensitive_values: []const []const u8 = &.{},
    /// Prompt, output, tool arguments, and tool results remain omitted by default.
    capture_content: bool = false,
    /// Sink failures do not fail agent runs unless this is disabled.
    fail_open: bool = true,

    pub fn validate(self: Config) !void {
        if (self.max_attributes == 0 or self.max_key_bytes == 0 or self.max_value_bytes == 0)
            return error.InvalidDiagnosticPolicy;
        for (self.sensitive_values) |value| if (value.len == 0) return error.InvalidDiagnosticPolicy;
    }

    pub fn emit(self: Config, allocator: std.mem.Allocator, event: Event) !void {
        try self.validate();
        if (@intFromEnum(event.level) < @intFromEnum(self.minimum_level)) return;
        if (!validName(event.name, self.max_key_bytes)) return error.InvalidDiagnosticEvent;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const count = @min(event.attributes.len, self.max_attributes);
        const attributes = try memory.alloc(Attribute, count);
        var truncated = event.values_truncated;
        var redacted = event.sensitive_values_redacted;
        for (event.attributes[0..count], attributes) |source, *target| {
            if (!validName(source.key, self.max_key_bytes)) return error.InvalidDiagnosticEvent;
            target.key = source.key;
            target.value = switch (source.value) {
                .string => |value| value: {
                    const sanitized = try sanitize(memory, value, self.sensitive_values, self.max_value_bytes);
                    truncated +|= @intFromBool(sanitized.truncated);
                    redacted +|= sanitized.redactions;
                    break :value .{ .string = sanitized.value };
                },
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
                .boolean => |value| .{ .boolean = value },
            };
        }
        self.sink.emit(.{
            .level = event.level,
            .name = event.name,
            .attributes = attributes,
            .attributes_dropped = event.attributes_dropped +| (event.attributes.len - count),
            .values_truncated = truncated,
            .sensitive_values_redacted = redacted,
        }) catch |failure| if (!self.fail_open) return failure;
    }

    pub fn start(self: Config, allocator: std.mem.Allocator) Run {
        return .{ .allocator = allocator, .config = self };
    }
};

/// Per-run lifecycle adapter used by `Agent.diagnostics`.
pub const Run = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn observe(self: Run, event: anytype) !void {
        switch (event) {
            .run_start => |value| {
                var attributes: [3]Attribute = undefined;
                var count: usize = 0;
                appendModel(&attributes, &count, value.model);
                if (self.config.capture_content) {
                    attributes[count] = .{ .key = "zigai.prompt", .value = .{ .string = value.prompt } };
                    count += 1;
                }
                try self.config.emit(self.allocator, .{ .level = .info, .name = "zigai.run.start", .attributes = attributes[0..count] });
            },
            .run_end => |value| {
                var attributes = [_]Attribute{
                    .{ .key = "zigai.model.requests", .value = .{ .integer = @intCast(value.model_requests) } },
                    .{ .key = "zigai.output", .value = .{ .string = value.output } },
                };
                try self.config.emit(self.allocator, .{
                    .level = .info,
                    .name = "zigai.run.end",
                    .attributes = attributes[0..if (self.config.capture_content) 2 else 1],
                });
            },
            .run_error => |value| try self.failure(.err, "zigai.run.error", value.failure, false),
            .model_request_start => |value| {
                const attributes = [_]Attribute{
                    .{ .key = "zigai.request.number", .value = .{ .integer = @intCast(value.number) } },
                    .{ .key = "zigai.request.streaming", .value = .{ .boolean = value.streaming } },
                };
                try self.config.emit(self.allocator, .{ .level = .debug, .name = "zigai.model.request.start", .attributes = &attributes });
            },
            .model_request_end => |value| {
                var attributes: [3]Attribute = undefined;
                var count: usize = 0;
                attributes[count] = .{ .key = "zigai.request.number", .value = .{ .integer = @intCast(value.number) } };
                count += 1;
                if (value.response.provider_name) |provider| {
                    attributes[count] = .{ .key = "gen_ai.provider.name", .value = .{ .string = provider } };
                    count += 1;
                }
                if (value.response.model_name) |model| {
                    attributes[count] = .{ .key = "gen_ai.response.model", .value = .{ .string = model } };
                    count += 1;
                }
                try self.config.emit(self.allocator, .{ .level = .debug, .name = "zigai.model.request.end", .attributes = attributes[0..count] });
            },
            .model_request_error => |value| try self.failure(
                if (value.will_retry) .warning else .err,
                "zigai.model.request.error",
                value.failure,
                value.will_retry,
            ),
            .tool_validation_start => |value| try self.tool(.trace, "zigai.tool.validation.start", value.call, null),
            .tool_validation_end => |value| try self.tool(.trace, "zigai.tool.validation.end", value.call, null),
            .tool_validation_error => |value| try self.tool(.warning, "zigai.tool.validation.error", value.call, value.failure),
            .tool_execution_start => |value| try self.tool(.debug, "zigai.tool.execution.start", value.call, null),
            .tool_execution_end => |value| {
                const content: ?[]const u8 = if (self.config.capture_content) value.content else null;
                try self.tool(.info, "zigai.tool.execution.end", value.call, null);
                if (content) |captured| try self.config.emit(self.allocator, .{
                    .level = .trace,
                    .name = "zigai.tool.result",
                    .attributes = &.{.{ .key = "zigai.tool.result", .value = .{ .string = captured } }},
                });
            },
            .tool_execution_error => |value| try self.tool(
                if (value.recoverable) .warning else .err,
                "zigai.tool.execution.error",
                value.call,
                value.failure,
            ),
            .output_validation_start => try self.config.emit(self.allocator, .{ .level = .trace, .name = "zigai.output.validation.start" }),
            .output_validation_end => try self.config.emit(self.allocator, .{ .level = .debug, .name = "zigai.output.validation.end" }),
            .output_validation_error => |value| try self.failure(
                if (value.will_retry) .warning else .err,
                "zigai.output.validation.error",
                value.failure,
                value.will_retry,
            ),
            .stream_event => |value| {
                const attributes = [_]Attribute{
                    .{ .key = "zigai.stream.stage", .value = .{ .string = @tagName(value.stage) } },
                    .{ .key = "zigai.stream.event", .value = .{ .string = @tagName(std.meta.activeTag(value.event)) } },
                };
                try self.config.emit(self.allocator, .{ .level = .trace, .name = "zigai.stream.event", .attributes = &attributes });
            },
        }
    }

    fn failure(self: Run, level: Level, name: []const u8, value: anyerror, will_retry: bool) !void {
        const attributes = [_]Attribute{
            .{ .key = "error.type", .value = .{ .string = @errorName(value) } },
            .{ .key = "zigai.will_retry", .value = .{ .boolean = will_retry } },
        };
        try self.config.emit(self.allocator, .{ .level = level, .name = name, .attributes = &attributes });
    }

    fn tool(self: Run, level: Level, name: []const u8, call: anytype, failure_value: ?anyerror) !void {
        var attributes: [4]Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "gen_ai.tool.name", .value = .{ .string = call.name } };
        count += 1;
        attributes[count] = .{ .key = "gen_ai.tool.call.id", .value = .{ .string = call.id } };
        count += 1;
        if (self.config.capture_content) {
            attributes[count] = .{ .key = "gen_ai.tool.call.arguments", .value = .{ .string = call.arguments_json } };
            count += 1;
        }
        if (failure_value) |tool_failure| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = @errorName(tool_failure) } };
            count += 1;
        }
        try self.config.emit(self.allocator, .{ .level = level, .name = name, .attributes = attributes[0..count] });
    }
};

fn appendModel(attributes: []Attribute, count: *usize, model: anytype) void {
    if (model.provider_name) |provider| {
        attributes[count.*] = .{ .key = "gen_ai.provider.name", .value = .{ .string = provider } };
        count.* += 1;
    }
    if (model.model_name) |name| {
        attributes[count.*] = .{ .key = "gen_ai.request.model", .value = .{ .string = name } };
        count.* += 1;
    }
}

const Sanitized = struct {
    value: []const u8,
    truncated: bool,
    redactions: usize,
};

fn sanitize(
    allocator: std.mem.Allocator,
    source: []const u8,
    sensitive_values: []const []const u8,
    maximum: usize,
) !Sanitized {
    var current = try allocator.dupe(u8, source);
    var redactions: usize = 0;
    for (sensitive_values) |sensitive| {
        if (std.mem.indexOf(u8, current, sensitive) == null) continue;
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var remaining = current;
        while (std.mem.indexOf(u8, remaining, sensitive)) |index| {
            try output.writer.writeAll(remaining[0..index]);
            try output.writer.writeAll("[REDACTED]");
            remaining = remaining[index + sensitive.len ..];
            redactions +|= 1;
        }
        try output.writer.writeAll(remaining);
        current = try output.toOwnedSlice();
    }
    const truncated = current.len > maximum;
    return .{ .value = current[0..@min(current.len, maximum)], .truncated = truncated, .redactions = redactions };
}

fn validName(value: []const u8, maximum: usize) bool {
    return value.len > 0 and value.len <= maximum and std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

test "diagnostic config filters levels bounds attributes and redacts before truncation" {
    const Capture = struct {
        calls: usize = 0,
        fn emit(context: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 1), event.attributes.len);
            try std.testing.expectEqualStrings("xx[REDACTE", event.attributes[0].value.string);
            try std.testing.expectEqual(@as(usize, 1), event.attributes_dropped);
            try std.testing.expectEqual(@as(usize, 1), event.values_truncated);
            try std.testing.expectEqual(@as(usize, 1), event.sensitive_values_redacted);
        }
    };
    var capture: Capture = .{};
    const config = Config{
        .sink = .{ .context = &capture, .emitFn = Capture.emit },
        .minimum_level = .debug,
        .max_attributes = 1,
        .max_value_bytes = 10,
        .sensitive_values = &.{"secret"},
    };
    try config.emit(std.testing.allocator, .{ .level = .trace, .name = "ignored" });
    try config.emit(std.testing.allocator, .{
        .level = .info,
        .name = "event",
        .attributes = &.{
            .{ .key = "value", .value = .{ .string = "xxsecret-tail" } },
            .{ .key = "dropped", .value = .{ .boolean = true } },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "diagnostic policy validates names secrets and fail-open behavior" {
    const Failure = struct {
        fn emit(_: *anyopaque, _: Event) !void {
            return error.BackendFailed;
        }
    };
    var unused: u8 = 0;
    const sink = Sink{ .context = &unused, .emitFn = Failure.emit };
    try std.testing.expectError(error.InvalidDiagnosticPolicy, (Config{ .sink = sink, .max_attributes = 0 }).validate());
    try std.testing.expectError(error.InvalidDiagnosticPolicy, (Config{ .sink = sink, .sensitive_values = &.{""} }).validate());
    try std.testing.expectError(
        error.InvalidDiagnosticEvent,
        (Config{ .sink = sink }).emit(std.testing.allocator, .{ .level = .info, .name = "bad\nname" }),
    );
    try std.testing.expectError(
        error.InvalidDiagnosticEvent,
        (Config{ .sink = sink }).emit(std.testing.allocator, .{
            .level = .info,
            .name = "bad-attribute",
            .attributes = &.{.{ .key = "bad\nkey", .value = .{ .string = "value" } }},
        }),
    );
    try (Config{ .sink = sink }).emit(std.testing.allocator, .{
        .level = .info,
        .name = "typed-values",
        .attributes = &.{
            .{ .key = "integer", .value = .{ .integer = 1 } },
            .{ .key = "float", .value = .{ .float = 1.5 } },
            .{ .key = "boolean", .value = .{ .boolean = true } },
        },
    });
    try (Config{ .sink = sink }).emit(std.testing.allocator, .{ .level = .info, .name = "fail-open" });
    try std.testing.expectError(
        error.BackendFailed,
        (Config{ .sink = sink, .fail_open = false }).emit(std.testing.allocator, .{ .level = .info, .name = "fail-closed" }),
    );
}

test "diagnostic run maps the complete agent lifecycle without leaking captured secrets" {
    const agent_types = @import("agent.zig");
    const model_types = @import("model.zig");
    const Capture = struct {
        events: usize = 0,
        redactions: usize = 0,

        fn emit(context: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
            self.redactions += event.sensitive_values_redacted;
            for (event.attributes) |attribute| switch (attribute.value) {
                .string => |value| try std.testing.expect(std.mem.indexOf(u8, value, "secret") == null),
                else => {},
            };
        }
    };
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.Unused;
        }
        fn tool(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "ok");
        }
    };
    var capture: Capture = .{};
    var unused: u8 = 0;
    const model = model_types.Model{
        .context = &unused,
        .profile = .{},
        .provider_name = "test-provider",
        .model_name = "test-model",
        .requestFn = Stub.request,
    };
    const tool = model_types.Tool{
        .definition = .{ .name = "lookup", .description = "Lookup.", .parameters_json_schema = "{}" },
        .context = &unused,
        .executeFn = Stub.tool,
    };
    const call = model_types.ToolCall{ .id = "call", .name = "lookup", .arguments_json = "{\"value\":\"secret\"}" };
    var run = (Config{
        .sink = .{ .context = &capture, .emitFn = Capture.emit },
        .minimum_level = .trace,
        .capture_content = true,
        .sensitive_values = &.{"secret"},
    }).start(std.testing.allocator);
    try run.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "secret prompt", .model = model } });
    try run.observe(agent_types.LifecycleEvent{ .run_end = .{ .output = "secret output", .usage = .{}, .model_requests = 1 } });
    try run.observe(agent_types.LifecycleEvent{ .run_error = .{ .failure = error.RunFailed } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_start = .{ .number = 1, .request = .{ .messages = &.{} }, .streaming = true } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_end = .{ .number = 1, .response = .{
        .parts = &.{},
        .provider_name = "response-provider",
        .model_name = "response-model",
    } } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_error = .{ .number = 2, .failure = error.ProviderServerError, .will_retry = true } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = call } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_end = .{ .call = call, .tool = tool } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_error = .{ .call = call, .failure = error.InvalidToolArguments } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_start = .{ .call = call, .tool = tool } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_end = .{ .call = call, .content = "secret result" } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_error = .{ .call = call, .failure = error.ToolFailed, .recoverable = false } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_start = .{ .output = "value", .retry_number = 0 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_end = .{ .output = "value", .retry_number = 0 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_error = .{
        .output = "value",
        .failure = error.InvalidOutput,
        .retry_number = 1,
        .will_retry = false,
    } });
    try run.observe(agent_types.LifecycleEvent{ .stream_event = .{
        .stage = .after,
        .event = .{ .final_result = .{ .output = "done" } },
    } });
    var quiet_run = (Config{
        .sink = .{ .context = &capture, .emitFn = Capture.emit },
        .minimum_level = .trace,
    }).start(std.testing.allocator);
    try quiet_run.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "omitted", .model = model } });
    try quiet_run.observe(agent_types.LifecycleEvent{ .run_end = .{ .output = "omitted", .usage = .{}, .model_requests = 1 } });
    try quiet_run.observe(agent_types.LifecycleEvent{ .tool_execution_end = .{ .call = call, .content = "omitted" } });
    try quiet_run.observe(agent_types.LifecycleEvent{ .model_request_error = .{ .number = 2, .failure = error.ProviderServerError, .will_retry = false } });
    try quiet_run.observe(agent_types.LifecycleEvent{ .tool_execution_error = .{ .call = call, .failure = error.ToolFailed, .recoverable = true } });
    try quiet_run.observe(agent_types.LifecycleEvent{ .output_validation_error = .{
        .output = "value",
        .failure = error.InvalidOutput,
        .retry_number = 1,
        .will_retry = true,
    } });
    try std.testing.expectEqual(@as(usize, 23), capture.events);
    try std.testing.expect(capture.redactions >= 4);
}
