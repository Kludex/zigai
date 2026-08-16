//! OpenTelemetry-shaped spans and metrics for agent lifecycle events.

const std = @import("std");
const model_types = @import("model.zig");

/// OpenTelemetry GenAI semantic conventions implemented by this module.
///
/// GenAI conventions currently evolve in their dedicated upstream repository,
/// independently from the stable core semantic-conventions release.
pub const semantic_conventions = "opentelemetry-semantic-conventions-genai";

/// Trace identity inherited from an upstream operation or passed to a child.
pub const SpanContext = struct {
    trace_id: [16]u8,
    span_id: [8]u8,

    pub fn isValid(self: SpanContext) bool {
        return !allZero(&self.trace_id) and !allZero(&self.span_id);
    }
};

pub const traceparent_length = 55;

/// Formats a sampled W3C Trace Context header value.
pub fn formatTraceparent(context: SpanContext, output: *[traceparent_length]u8) ![]const u8 {
    if (!context.isValid()) return error.InvalidTraceparent;
    const trace_hex = std.fmt.bytesToHex(context.trace_id, .lower);
    const span_hex = std.fmt.bytesToHex(context.span_id, .lower);
    return std.fmt.bufPrint(output, "00-{s}-{s}-01", .{ &trace_hex, &span_hex });
}

/// Parses the W3C version-00 traceparent form used in MCP `_meta` bags.
pub fn parseTraceparent(value: []const u8) !SpanContext {
    if (value.len != traceparent_length or value[2] != '-' or value[35] != '-' or value[52] != '-' or
        !std.mem.eql(u8, value[0..2], "00"))
        return error.InvalidTraceparent;
    var context: SpanContext = undefined;
    _ = std.fmt.hexToBytes(&context.trace_id, value[3..35]) catch return error.InvalidTraceparent;
    _ = std.fmt.hexToBytes(&context.span_id, value[36..52]) catch return error.InvalidTraceparent;
    _ = std.fmt.parseInt(u8, value[53..55], 16) catch return error.InvalidTraceparent;
    if (!context.isValid()) return error.InvalidTraceparent;
    return context;
}

/// Sensitive content categories presented to an application redactor.
pub const ContentKind = enum { prompt };

/// Redacts one captured value. The returned slice must be allocated with the
/// supplied allocator and becomes owned by ZigAI.
pub const Redactor = struct {
    context: *anyopaque,
    redactFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        kind: ContentKind,
        value: []const u8,
    ) anyerror![]u8,

    pub fn redact(
        self: Redactor,
        allocator: std.mem.Allocator,
        kind: ContentKind,
        value: []const u8,
    ) ![]u8 {
        return self.redactFn(self.context, allocator, kind, value);
    }
};

/// Opt-in content capture. `redacted` requires a redactor; otherwise content
/// is omitted. Both raw and redacted values are bounded before export.
pub const ContentPolicy = struct {
    prompts: Mode = .omit,
    max_bytes: usize = 1_024,
    redactor: ?Redactor = null,

    pub const Mode = enum { omit, raw, redacted };
};

/// Hard per-record limits applied before application exporter callbacks run.
pub const Limits = struct {
    max_attributes: usize = 32,
    max_attribute_value_bytes: usize = 8 * 1_024,
};

const signal_types = @import("telemetry/types.zig");
pub const Attribute = signal_types.Attribute;
pub const Span = signal_types.Span;
pub const Metric = signal_types.Metric;
pub const Event = signal_types.Event;
pub const Exporter = signal_types.Exporter;
pub const BufferedExporter = @import("telemetry/buffer.zig").BufferedExporter;
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
    /// Prompt content is sensitive and omitted unless explicitly configured.
    content: ContentPolicy = .{},
    /// Attribute cardinality and value-size limits enforced before export.
    limits: Limits = .{},
    /// Observability failures do not fail agent runs unless this is disabled.
    fail_open: bool = true,

    pub fn start(self: OpenTelemetry, allocator: std.mem.Allocator) Run {
        return self.startWithParent(allocator, null);
    }

    /// Starts a run beneath a valid upstream span. Invalid all-zero contexts
    /// are treated as absent instead of creating malformed traces.
    pub fn startWithParent(
        self: OpenTelemetry,
        allocator: std.mem.Allocator,
        parent: ?SpanContext,
    ) Run {
        const inherited = if (parent) |value| if (value.isValid()) value else null else null;
        return .{
            .allocator = allocator,
            .config = self,
            .trace_id = if (inherited) |value| value.trace_id else randomId(16, self.io),
            .run_span_id = randomId(8, self.io),
            .run_parent_span_id = if (inherited) |value| value.span_id else null,
        };
    }
};

/// MCP signal configuration shared by clients and servers. Transport values
/// follow OpenTelemetry's `network.transport` vocabulary (`pipe`, `tcp`, ...).
pub const McpTelemetry = struct {
    io: std.Io,
    exporter: Exporter,
    parent: ?SpanContext = null,
    network_transport: ?[]const u8 = null,
    network_protocol_name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    limits: Limits = .{},
    fail_open: bool = true,

    pub fn start(
        self: McpTelemetry,
        allocator: std.mem.Allocator,
        role: McpRun.Role,
        method: []const u8,
        target: ?McpRun.Target,
        request_id: ?[]const u8,
        remote_parent: ?SpanContext,
        protocol: []const u8,
    ) McpRun {
        const configured_parent = if (remote_parent) |value|
            if (value.isValid()) value else null
        else if (self.parent) |value|
            if (value.isValid()) value else null
        else
            null;
        return .{
            .allocator = allocator,
            .config = self,
            .role = role,
            .method = method,
            .target = target,
            .request_id = request_id,
            .protocol = protocol,
            .trace_id = if (configured_parent) |value| value.trace_id else randomId(16, self.io),
            .span_id = randomId(8, self.io),
            .parent_span_id = if (configured_parent) |value| value.span_id else null,
            .start_time = .{
                .real_ns = @intCast(std.Io.Clock.real.now(self.io).nanoseconds),
                .awake_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds),
            },
        };
    }
};

/// One MCP request or notification span.
pub const McpRun = struct {
    allocator: std.mem.Allocator,
    config: McpTelemetry,
    role: Role,
    method: []const u8,
    target: ?Target,
    request_id: ?[]const u8,
    protocol: []const u8,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    start_time: Run.Start,

    pub const Role = enum { client, server };
    pub const Target = struct {
        kind: Kind,
        value: []const u8,

        pub const Kind = enum { tool, prompt, resource, task };
    };

    pub fn spanContext(self: McpRun) SpanContext {
        return .{ .trace_id = self.trace_id, .span_id = self.span_id };
    }

    /// Completes the operation. A non-null low-cardinality error type marks the
    /// span as failed. All processing honors `fail_open`.
    pub fn finish(self: *McpRun, error_type: ?[]const u8) !void {
        self.finishFallible(error_type) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }

    fn finishFallible(self: *McpRun, error_type: ?[]const u8) !void {
        const end = Run.Start{
            .real_ns = @intCast(std.Io.Clock.real.now(self.config.io).nanoseconds),
            .awake_ns = @intCast(std.Io.Clock.awake.now(self.config.io).nanoseconds),
        };
        var attributes: [12]Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "mcp.method.name", .value = .{ .string = self.method } };
        count += 1;
        attributes[count] = .{ .key = "mcp.protocol.version", .value = .{ .string = self.protocol } };
        count += 1;
        if (self.request_id) |id| {
            attributes[count] = .{ .key = "jsonrpc.request.id", .value = .{ .string = id } };
            count += 1;
        }
        if (self.target) |target| {
            attributes[count] = .{
                .key = switch (target.kind) {
                    .tool => "gen_ai.tool.name",
                    .prompt => "gen_ai.prompt.name",
                    .resource => "mcp.resource.uri",
                    .task => "zigai.mcp.task.id",
                },
                .value = .{ .string = target.value },
            };
            count += 1;
            if (target.kind == .tool) {
                attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "execute_tool" } };
                count += 1;
            }
        }
        if (self.config.session_id) |session_id| {
            attributes[count] = .{ .key = "mcp.session.id", .value = .{ .string = session_id } };
            count += 1;
        }
        if (self.config.network_transport) |transport| {
            attributes[count] = .{ .key = "network.transport", .value = .{ .string = transport } };
            count += 1;
        }
        if (self.config.network_protocol_name) |network_protocol| {
            attributes[count] = .{ .key = "network.protocol.name", .value = .{ .string = network_protocol } };
            count += 1;
        }
        if (error_type) |failure| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = failure } };
            count += 1;
        }
        const include_target = if (self.target) |target|
            target.kind == .tool or target.kind == .prompt
        else
            false;
        const owned_name = if (include_target)
            std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.method, self.target.?.value }) catch |failure| name: {
                if (!self.config.fail_open) return failure;
                break :name null;
            }
        else
            null;
        defer if (owned_name) |name| self.allocator.free(name);
        var bounded_storage: [maximum_export_attributes]Attribute = undefined;
        const bounded = boundedAttributes(attributes[0..count], self.config.limits, &bounded_storage);
        try self.config.exporter.span(makeSpan(
            owned_name orelse self.method,
            if (self.role == .client) .client else .server,
            self.trace_id,
            self.span_id,
            self.parent_span_id,
            self.start_time,
            end,
            if (error_type == null) .ok else .error_status,
            bounded,
        ));
        const metric_name = if (self.role == .client)
            "mcp.client.operation.duration"
        else
            "mcp.server.operation.duration";
        try self.config.exporter.metric(.{
            .name = metric_name,
            .kind = .histogram,
            .value = durationSeconds(self.start_time, end),
            .unit = "s",
            .attributes = bounded,
        });
    }
};

/// Per-run instrumentation state. Applications normally configure this through `Agent.telemetry`.
pub const Run = struct {
    allocator: std.mem.Allocator,
    config: OpenTelemetry,
    trace_id: [16]u8,
    run_span_id: [8]u8,
    run_parent_span_id: ?[8]u8 = null,
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
    tool_validation_starts: std.ArrayList(ToolStart) = .empty,
    output_validation_start: ?OutputValidationStart = null,

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

    const OutputValidationStart = struct {
        retry_number: usize,
        start: Start,
        span_id: [8]u8,
        parent_span_id: ?[8]u8,
    };

    pub fn deinit(self: *Run) void {
        if (self.input_messages) |messages| self.allocator.free(messages);
        self.tool_starts.deinit(self.allocator);
        self.tool_validation_starts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Context to propagate to work performed as a child of this agent run.
    pub fn spanContext(self: Run) SpanContext {
        return .{ .trace_id = self.trace_id, .span_id = self.run_span_id };
    }

    /// Consumes an agent lifecycle event. Values are borrowed for this call only.
    pub fn observe(self: *Run, event: anytype) !void {
        self.observeFallible(event) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }

    fn observeFallible(self: *Run, event: anytype) !void {
        self.emitLifecycleEvent(event) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
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
            .tool_validation_start => |value| try self.onToolValidationStart(value.call.id, value.call.name),
            .tool_validation_end => |value| try self.onToolValidationEnd(value.call.id, .ok, null),
            .tool_validation_error => |value| try self.onToolValidationEnd(value.call.id, .error_status, value.failure),
            .tool_execution_start => |value| try self.onToolStart(value.call.id, value.call.name),
            .tool_execution_end => |value| try self.onToolEnd(value.call.id, .ok, null),
            .tool_execution_error => |value| {
                try self.onToolEnd(value.call.id, .error_status, value.failure);
                if (value.recoverable) try self.retryMetric("tool");
            },
            .output_validation_start => |value| try self.onOutputValidationStart(value.retry_number),
            .output_validation_end => |value| try self.onOutputValidationEnd(value.retry_number, .ok, null),
            .output_validation_error => |value| {
                try self.onOutputValidationEnd(value.retry_number, .error_status, value.failure);
                if (value.will_retry) try self.retryMetric("output");
            },
            .stream_event => {},
        }
    }

    fn onRunStart(self: *Run, prompt: []const u8, model: model_types.Model) !void {
        self.model = model;
        self.input_messages = self.capturePrompt(prompt) catch |failure| capture: {
            if (!self.config.fail_open) return failure;
            break :capture null;
        };
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
        var attributes: [20]Attribute = undefined;
        var count: usize = 0;
        modelAttributes(self, &attributes, &count);
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
            "invoke_agent",
            .internal,
            self.trace_id,
            self.run_span_id,
            self.run_parent_span_id,
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
        var attributes: [20]Attribute = undefined;
        var count: usize = 0;
        modelAttributes(self, &attributes, &count);
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "chat" } };
        count += 1;
        attributes[count] = .{ .key = "zigai.request.number", .value = .{ .integer = @intCast(self.request_number) } };
        count += 1;
        usageAttributes(usage, &attributes, &count);
        if (failure) |value| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = @errorName(value) } };
            count += 1;
        }
        const span_id = self.request_span_id orelse randomId(8, self.config.io);
        const owned_span_name = if (self.request_model_name) |model_name|
            self.operationSpanName("chat", model_name) catch |allocation_failure| name: {
                if (!self.config.fail_open) return allocation_failure;
                break :name null;
            }
        else
            null;
        defer if (owned_span_name) |name| self.allocator.free(name);
        try self.exportSpan(makeSpan(
            owned_span_name orelse "chat",
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
        if (usage.hasValues()) {
            try self.usageMetrics(usage);
            const estimated_cost = if (usage.cost) |cost|
                cost.usd()
            else if (self.config.cost_estimator) |estimator|
                estimator.estimate(self.request_provider_name, self.request_model_name, usage)
            else
                null;
            if (estimated_cost) |cost| {
                try self.exportMetric(.{
                    .name = "gen_ai.client.estimated_cost",
                    .kind = .counter,
                    .value = cost,
                    .unit = "USD",
                    .attributes = attributes[0..count],
                });
            }
        }
        self.last_request_span_id = span_id;
        self.request_start = null;
        self.request_span_id = null;
    }

    fn emitLifecycleEvent(self: Run, event: anytype) !void {
        var attributes: [8]Attribute = undefined;
        var count: usize = 0;
        const name: []const u8 = switch (event) {
            .run_start => "zigai.run.start",
            .run_end => |value| event_name: {
                attributes[count] = .{ .key = "zigai.model.request.count", .value = .{ .integer = @intCast(value.model_requests) } };
                count += 1;
                break :event_name "zigai.run.end";
            },
            .run_error => |value| event_name: {
                addFailureAttribute(value.failure, &attributes, &count);
                break :event_name "zigai.run.error";
            },
            .model_request_start => |value| event_name: {
                addRequestAttributes(value.number, &attributes, &count);
                attributes[count] = .{ .key = "zigai.request.streaming", .value = .{ .boolean = value.streaming } };
                count += 1;
                break :event_name "zigai.model.request.start";
            },
            .model_request_end => |value| event_name: {
                addRequestAttributes(value.number, &attributes, &count);
                break :event_name "zigai.model.request.end";
            },
            .model_request_error => |value| event_name: {
                addRequestAttributes(value.number, &attributes, &count);
                addFailureAttribute(value.failure, &attributes, &count);
                attributes[count] = .{ .key = "zigai.retry.scheduled", .value = .{ .boolean = value.will_retry } };
                count += 1;
                break :event_name "zigai.model.request.error";
            },
            .tool_validation_start => |value| toolEvent("zigai.tool.validation.start", value.call, &attributes, &count),
            .tool_validation_end => |value| toolEvent("zigai.tool.validation.end", value.call, &attributes, &count),
            .tool_validation_error => |value| event_name: {
                const result = toolEvent("zigai.tool.validation.error", value.call, &attributes, &count);
                addFailureAttribute(value.failure, &attributes, &count);
                break :event_name result;
            },
            .tool_execution_start => |value| toolEvent("zigai.tool.execution.start", value.call, &attributes, &count),
            .tool_execution_end => |value| toolEvent("zigai.tool.execution.end", value.call, &attributes, &count),
            .tool_execution_error => |value| event_name: {
                const result = toolEvent("zigai.tool.execution.error", value.call, &attributes, &count);
                addFailureAttribute(value.failure, &attributes, &count);
                attributes[count] = .{ .key = "zigai.retry.scheduled", .value = .{ .boolean = value.recoverable } };
                count += 1;
                break :event_name result;
            },
            .output_validation_start => |value| outputEvent("zigai.output.validation.start", value.retry_number, &attributes, &count),
            .output_validation_end => |value| outputEvent("zigai.output.validation.end", value.retry_number, &attributes, &count),
            .output_validation_error => |value| event_name: {
                const result = outputEvent("zigai.output.validation.error", value.retry_number, &attributes, &count);
                addFailureAttribute(value.failure, &attributes, &count);
                attributes[count] = .{ .key = "zigai.retry.scheduled", .value = .{ .boolean = value.will_retry } };
                count += 1;
                break :event_name result;
            },
            .stream_event => |value| event_name: {
                attributes[count] = .{ .key = "zigai.stream.stage", .value = .{ .string = @tagName(value.stage) } };
                count += 1;
                attributes[count] = .{ .key = "zigai.stream.event.name", .value = .{ .string = streamEventName(value.event) } };
                count += 1;
                break :event_name "zigai.stream.event";
            },
        };
        try self.exportEvent(.{
            .name = name,
            .trace_id = self.trace_id,
            .span_id = self.run_span_id,
            .time_unix_nano = self.now().real_ns,
            .attributes = attributes[0..count],
        });
    }

    fn onToolValidationStart(self: *Run, id: []const u8, name: []const u8) !void {
        try self.tool_validation_starts.append(self.allocator, .{
            .id = id,
            .name = name,
            .start = self.now(),
            .span_id = randomId(8, self.config.io),
            .parent_span_id = self.last_request_span_id,
        });
    }

    fn onToolValidationEnd(self: *Run, id: []const u8, status: Span.Status, failure: ?anyerror) !void {
        const item = takeToolStart(&self.tool_validation_starts, id) orelse return;
        const end = self.now();
        var attributes: [5]Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "validate_tool" } };
        count += 1;
        attributes[count] = .{ .key = "gen_ai.tool.name", .value = .{ .string = item.name } };
        count += 1;
        attributes[count] = .{ .key = "gen_ai.tool.call.id", .value = .{ .string = item.id } };
        count += 1;
        if (failure) |value| addFailureAttribute(value, &attributes, &count);
        const owned_span_name = self.operationSpanName("validate_tool", item.name) catch |allocation_failure| name: {
            if (!self.config.fail_open) return allocation_failure;
            break :name null;
        };
        defer if (owned_span_name) |name| self.allocator.free(name);
        try self.exportSpan(makeSpan(
            owned_span_name orelse "validate_tool",
            .internal,
            self.trace_id,
            item.span_id,
            item.parent_span_id orelse self.run_span_id,
            item.start,
            end,
            status,
            attributes[0..count],
        ));
        try self.durationMetric("zigai.tool.validation.duration", item.start, end, "validate_tool");
        try self.exportMetric(.{
            .name = "zigai.tool.validations",
            .kind = .counter,
            .value = 1,
            .unit = "{validation}",
            .attributes = attributes[0..count],
        });
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
        const item = takeToolStart(&self.tool_starts, id) orelse return;
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
        const owned_span_name = self.operationSpanName("execute_tool", item.name) catch |allocation_failure| name: {
            if (!self.config.fail_open) return allocation_failure;
            break :name null;
        };
        defer if (owned_span_name) |name| self.allocator.free(name);
        try self.exportSpan(makeSpan(
            owned_span_name orelse "execute_tool",
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

    fn onOutputValidationStart(self: *Run, retry_number: usize) !void {
        self.output_validation_start = .{
            .retry_number = retry_number,
            .start = self.now(),
            .span_id = randomId(8, self.config.io),
            .parent_span_id = self.last_request_span_id,
        };
    }

    fn onOutputValidationEnd(
        self: *Run,
        retry_number: usize,
        status: Span.Status,
        failure: ?anyerror,
    ) !void {
        const item = self.output_validation_start orelse return;
        if (item.retry_number != retry_number) return;
        self.output_validation_start = null;
        const end = self.now();
        var attributes: [4]Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "validate_output" } };
        count += 1;
        attributes[count] = .{ .key = "zigai.retry.number", .value = .{ .integer = @intCast(retry_number) } };
        count += 1;
        if (failure) |value| addFailureAttribute(value, &attributes, &count);
        try self.exportSpan(makeSpan(
            "validate_output",
            .internal,
            self.trace_id,
            item.span_id,
            item.parent_span_id orelse self.run_span_id,
            item.start,
            end,
            status,
            attributes[0..count],
        ));
        try self.durationMetric("zigai.output.validation.duration", item.start, end, "validate_output");
        try self.exportMetric(.{
            .name = "zigai.output.validations",
            .kind = .counter,
            .value = 1,
            .unit = "{validation}",
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
            .{ .name = "cache_write", .value = usage.cache_write_tokens },
            .{ .name = "cache_read", .value = usage.cache_read_tokens },
            .{ .name = "output", .value = usage.output_tokens },
            .{ .name = "reasoning", .value = usage.reasoning_tokens },
            .{ .name = "input_audio", .value = usage.input_audio_tokens },
            .{ .name = "cache_audio_read", .value = usage.cache_audio_read_tokens },
            .{ .name = "output_audio", .value = usage.output_audio_tokens },
        }) |token| {
            if (token.value == 0) continue;
            var attributes: [4]Attribute = undefined;
            var count: usize = 0;
            self.modelAttributes(&attributes, &count); // kcov-ignore
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

    fn usageAttributes(usage: model_types.Usage, attributes: []Attribute, count: *usize) void {
        for ([_]struct { name: []const u8, value: u64 }{
            .{
                .name = "gen_ai.usage.input_tokens",
                .value = usage.input_tokens,
            },
            .{ .name = "gen_ai.usage.cache_creation.input_tokens", .value = usage.cache_write_tokens },
            .{ .name = "gen_ai.usage.cache_read.input_tokens", .value = usage.cache_read_tokens },
            .{ .name = "gen_ai.usage.output_tokens", .value = usage.output_tokens },
            .{ .name = "gen_ai.usage.details.reasoning_tokens", .value = usage.reasoning_tokens },
            .{ .name = "gen_ai.usage.details.input_audio_tokens", .value = usage.input_audio_tokens },
            .{ .name = "gen_ai.usage.details.cache_audio_read_tokens", .value = usage.cache_audio_read_tokens },
            .{ .name = "gen_ai.usage.details.output_audio_tokens", .value = usage.output_audio_tokens },
        }) |item| {
            if (item.value == 0) continue;
            attributes[count.*] = .{ .key = item.name, .value = .{ .integer = @intCast(item.value) } };
            count.* += 1;
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

    fn capturePrompt(self: *Run, prompt: []const u8) !?[]u8 {
        const policy = self.config.content;
        if (policy.prompts == .omit or policy.max_bytes == 0 or
            self.config.limits.max_attribute_value_bytes < encoded_empty_prompt.len)
            return null;

        const captured = switch (policy.prompts) {
            .omit => unreachable,
            .raw => prompt,
            .redacted => redacted: {
                const redactor = policy.redactor orelse return null;
                break :redacted try redactor.redact(self.allocator, .prompt, prompt);
            },
        };
        defer if (policy.prompts == .redacted) self.allocator.free(captured);
        const escaped_budget = (self.config.limits.max_attribute_value_bytes - encoded_empty_prompt.len) / 6;
        const bounded = utf8Prefix(captured, @min(policy.max_bytes, escaped_budget));
        return try encodePrompt(self.allocator, bounded);
    }

    fn operationSpanName(self: Run, operation: []const u8, detail: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ operation, detail });
    }

    fn exportSpan(self: Run, value: Span) !void {
        var storage: [maximum_export_attributes]Attribute = undefined;
        var bounded = value;
        bounded.attributes = boundedAttributes(value.attributes, self.config.limits, &storage);
        try self.config.exporter.span(bounded);
    }

    fn exportMetric(self: Run, value: Metric) !void {
        var storage: [maximum_export_attributes]Attribute = undefined;
        var bounded = value;
        bounded.attributes = boundedAttributes(value.attributes, self.config.limits, &storage);
        try self.config.exporter.metric(bounded);
    }

    fn exportEvent(self: Run, value: Event) !void {
        var storage: [maximum_export_attributes]Attribute = undefined;
        var bounded = value;
        bounded.attributes = boundedAttributes(value.attributes, self.config.limits, &storage);
        try self.config.exporter.event(bounded);
    }
};

fn takeToolStart(items: *std.ArrayList(Run.ToolStart), id: []const u8) ?Run.ToolStart {
    for (items.items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return items.swapRemove(index);
    }
    return null;
}

fn addRequestAttributes(number: usize, attributes: []Attribute, count: *usize) void {
    attributes[count.*] = .{ .key = "zigai.request.number", .value = .{ .integer = @intCast(number) } };
    count.* += 1;
}

fn addFailureAttribute(failure: anyerror, attributes: []Attribute, count: *usize) void {
    attributes[count.*] = .{ .key = "error.type", .value = .{ .string = @errorName(failure) } };
    count.* += 1;
}

fn toolEvent(
    name: []const u8,
    call: model_types.ToolCall,
    attributes: []Attribute,
    count: *usize,
) []const u8 {
    attributes[count.*] = .{ .key = "gen_ai.tool.name", .value = .{ .string = call.name } };
    count.* += 1;
    attributes[count.*] = .{ .key = "gen_ai.tool.call.id", .value = .{ .string = call.id } };
    count.* += 1;
    return name;
}

fn outputEvent(name: []const u8, retry_number: usize, attributes: []Attribute, count: *usize) []const u8 {
    attributes[count.*] = .{ .key = "zigai.retry.number", .value = .{ .integer = @intCast(retry_number) } };
    count.* += 1;
    return name;
}

fn streamEventName(event: anytype) []const u8 {
    return switch (event) {
        .model => "model",
        .function_tool_call => "function_tool_call",
        .function_tool_result => "function_tool_result",
        .tool_availability_delta => "tool_availability_delta",
        .deferred_tool_requests => "deferred_tool_requests",
        .deferred_tool_results => "deferred_tool_results",
        .enqueued_messages => "enqueued_messages",
        .partial_output => "partial_output",
        .final_result => "final_result",
    };
}

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

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

fn durationSeconds(start: Run.Start, end: Run.Start) f64 {
    const duration_ns = @max(@as(i128, 0), end.awake_ns - start.awake_ns);
    return @as(f64, @floatFromInt(duration_ns)) / std.time.ns_per_s;
}

const encoded_empty_prompt = "[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"content\":\"\"}]}]";
const maximum_export_attributes = 64;

fn boundedAttributes(source: []const Attribute, limits: Limits, storage: []Attribute) []const Attribute {
    const count = @min(source.len, @min(limits.max_attributes, storage.len));
    for (source[0..count], storage[0..count]) |attribute, *bounded| {
        bounded.* = attribute;
        if (bounded.value == .string) {
            bounded.value.string = utf8Prefix(bounded.value.string, limits.max_attribute_value_bytes);
        }
    }
    return storage[0..count];
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
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
            return .{ .parts = &.{} }; // kcov-ignore
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
        .content = .{ .prompts = .raw },
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
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_end = .{ .call = second, .tool = undefined } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_start = .{ .call = second, .tool = undefined } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_end = .{ .call = second, .content = "ok" } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_error = .{ .call = first, .failure = error.InvalidToolArguments } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = third } });
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_end = .{ .call = third, .tool = undefined } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_start = .{ .call = third, .tool = undefined } });
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

test "telemetry propagates valid parents and bounds exporter attributes" {
    const Capture = struct {
        expected_trace_id: [16]u8,
        expected_parent_id: [8]u8,
        spans: usize = 0,

        fn span(context: *anyopaque, value: Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.spans += 1;
            try std.testing.expectEqualSlices(u8, &self.expected_trace_id, &value.trace_id);
            if (std.mem.eql(u8, value.name, "invoke_agent")) {
                try std.testing.expectEqualSlices(u8, &self.expected_parent_id, &value.parent_span_id.?);
            }
            try std.testing.expect(value.attributes.len <= 1);
            for (value.attributes) |attribute| switch (attribute.value) {
                .string => |text| try std.testing.expect(text.len <= 3),
                else => {},
            };
        }

        fn metric(_: *anyopaque, value: Metric) !void {
            try std.testing.expect(value.attributes.len <= 1);
            for (value.attributes) |attribute| switch (attribute.value) {
                .string => |text| try std.testing.expect(text.len <= 3),
                else => {},
            };
        }
    };
    const agent_types = @import("agent.zig");
    var unused: u8 = 0;
    const parent = SpanContext{
        .trace_id = [_]u8{0x11} ** 16,
        .span_id = [_]u8{0x22} ** 8,
    };
    var capture = Capture{ .expected_trace_id = parent.trace_id, .expected_parent_id = parent.span_id };
    var run = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .content = .{ .prompts = .raw },
        .limits = .{ .max_attributes = 1, .max_attribute_value_bytes = 3 },
    }).startWithParent(std.testing.allocator, parent);
    defer run.deinit();
    try std.testing.expect(run.spanContext().isValid());
    try run.observe(agent_types.LifecycleEvent{
        .run_start = .{
            .prompt = "sensitive",
            .model = .{
                .context = &unused,
                .profile = .{},
                .provider_name = "provider",
                .model_name = "model",
                .requestFn = struct {
                    fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore
                        return .{ .parts = &.{} }; // kcov-ignore
                    }
                }.request,
            },
        },
    });
    try run.observe(agent_types.LifecycleEvent{ .run_end = .{ .output = "ok", .usage = .{}, .model_requests = 0 } });
    try std.testing.expectEqual(@as(usize, 1), capture.spans);

    var zero: SpanContext = .{ .trace_id = [_]u8{0} ** 16, .span_id = [_]u8{0} ** 8 };
    try std.testing.expect(!zero.isValid());
    zero.trace_id[0] = 1;
    try std.testing.expect(!zero.isValid());
    var independent = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
    }).startWithParent(std.testing.allocator, zero);
    defer independent.deinit();
    try std.testing.expect(!std.mem.eql(u8, &independent.trace_id, &parent.trace_id));
}

test "telemetry redacts captured prompts and isolates capture failures" {
    const Capture = struct {
        prompts: usize = 0,

        fn span(context: *anyopaque, value: Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (value.attributes) |attribute| {
                if (!std.mem.eql(u8, attribute.key, "gen_ai.input.messages")) continue;
                try std.testing.expect(std.mem.indexOf(u8, attribute.value.string, "secr") == null);
                try std.testing.expect(std.mem.indexOf(u8, attribute.value.string, "mask") != null);
                self.prompts += 1;
            }
        }

        fn metric(_: *anyopaque, _: Metric) !void {}
    };
    const Redact = struct {
        fn redact(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            kind: ContentKind,
            _: []const u8,
        ) ![]u8 {
            try std.testing.expectEqual(ContentKind.prompt, kind);
            return allocator.dupe(u8, "masked value");
        }

        fn fail(_: *anyopaque, _: std.mem.Allocator, _: ContentKind, _: []const u8) ![]u8 {
            return error.RedactionFailed;
        }
    };
    const agent_types = @import("agent.zig");
    var capture: Capture = .{};
    var unused: u8 = 0;
    const model = model_types.Model{
        .context = &unused,
        .profile = .{},
        .requestFn = struct {
            fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore
                return .{ .parts = &.{} }; // kcov-ignore
            }
        }.request,
    };
    var run = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .content = .{
            .prompts = .redacted,
            .max_bytes = 6,
            .redactor = .{ .context = &unused, .redactFn = Redact.redact },
        },
    }).start(std.testing.allocator);
    defer run.deinit();
    try run.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "secret", .model = model } });
    try run.observe(agent_types.LifecycleEvent{ .run_end = .{ .output = "ok", .usage = .{}, .model_requests = 0 } });
    try std.testing.expectEqual(@as(usize, 1), capture.prompts);

    var fail_open = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .content = .{ .prompts = .redacted, .redactor = .{ .context = &unused, .redactFn = Redact.fail } },
    }).start(std.testing.allocator);
    defer fail_open.deinit();
    try fail_open.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "secret", .model = model } });
    try std.testing.expect(fail_open.input_messages == null);

    var fail_closed = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .content = .{ .prompts = .redacted, .redactor = .{ .context = &unused, .redactFn = Redact.fail } },
        .fail_open = false,
    }).start(std.testing.allocator);
    defer fail_closed.deinit();
    try std.testing.expectError(
        error.RedactionFailed,
        fail_closed.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "secret", .model = model } }),
    );

    var no_redactor = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric },
        .content = .{ .prompts = .redacted },
    }).start(std.testing.allocator);
    defer no_redactor.deinit();
    try no_redactor.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "secret", .model = model } });
    try std.testing.expect(no_redactor.input_messages == null);
}

test "telemetry UTF-8 bounds preserve complete code points" {
    try std.testing.expectEqualStrings("full", utf8Prefix("full", 4));
    try std.testing.expectEqualStrings("ab", utf8Prefix("abc", 2));
    try std.testing.expectEqualStrings("a", utf8Prefix("a€b", 2));
    const encoded = try encodePrompt(std.testing.allocator, "");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(encoded_empty_prompt, encoded);
}

test "telemetry exporter failures follow fail-open policy" {
    const Failing = struct {
        fn span(_: *anyopaque, _: Span) !void {
            return error.ExportFailed;
        }

        fn metric(_: *anyopaque, _: Metric) !void {
            return error.ExportFailed;
        }

        fn event(_: *anyopaque, _: Event) !void {
            return error.ExportFailed;
        }
    };
    const agent_types = @import("agent.zig");
    var unused: u8 = 0;
    const model = model_types.Model{
        .context = &unused,
        .profile = .{},
        .requestFn = struct {
            fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore
                return .{ .parts = &.{} }; // kcov-ignore
            }
        }.request,
    };
    const exporter = Exporter{
        .context = &unused,
        .spanFn = Failing.span,
        .metricFn = Failing.metric,
        .eventFn = Failing.event,
    };
    try std.testing.expectError(error.ExportFailed, exporter.span(.{
        .name = "failure",
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
        .start_time_unix_nano = 1,
        .end_time_unix_nano = 2,
        .duration_seconds = 0.000000001,
        .status = .error_status,
        .attributes = &.{},
    }));
    var fail_open = (OpenTelemetry{ .io = std.testing.io, .exporter = exporter }).start(std.testing.allocator);
    defer fail_open.deinit();
    try fail_open.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "prompt", .model = model } });
    try std.testing.expect(fail_open.run_start != null);

    var fail_closed = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
        .fail_open = false,
    }).start(std.testing.allocator);
    defer fail_closed.deinit();
    try std.testing.expectError(
        error.ExportFailed,
        fail_closed.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "prompt", .model = model } }),
    );
}

test "telemetry emits correlated lifecycle events and validation spans" {
    const Capture = struct {
        events: usize = 0,
        output_spans: usize = 0,
        output_errors: usize = 0,
        saw_retry_event: bool = false,
        saw_stream_event: bool = false,

        fn span(context: *anyopaque, value: Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, value.name, "validate_output")) return;
            self.output_spans += 1;
            if (value.status == .error_status) self.output_errors += 1;
        }

        fn metric(_: *anyopaque, _: Metric) !void {}

        fn event(context: *anyopaque, value: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
            try std.testing.expect(!allZero(&value.trace_id));
            try std.testing.expect(!allZero(&value.span_id));
            if (std.mem.eql(u8, value.name, "zigai.model.request.error")) {
                for (value.attributes) |attribute| {
                    if (std.mem.eql(u8, attribute.key, "zigai.retry.scheduled")) {
                        self.saw_retry_event = attribute.value.boolean;
                    }
                }
            }
            if (std.mem.eql(u8, value.name, "zigai.stream.event")) self.saw_stream_event = true;
        }
    };
    const agent_types = @import("agent.zig");
    var capture: Capture = .{};
    var run = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{
            .context = &capture,
            .spanFn = Capture.span,
            .metricFn = Capture.metric,
            .eventFn = Capture.event,
        },
    }).start(std.testing.allocator);
    defer run.deinit();

    try run.observe(agent_types.LifecycleEvent{ .model_request_error = .{
        .number = 2,
        .failure = error.ProviderRateLimited,
        .will_retry = true,
    } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_start = .{ .output = "ok", .retry_number = 0 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_end = .{ .output = "ok", .retry_number = 0 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_start = .{ .output = "bad", .retry_number = 1 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_error = .{
        .output = "bad",
        .failure = error.InvalidOutput,
        .retry_number = 1,
        .will_retry = true,
    } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_start = .{ .output = "later", .retry_number = 2 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_end = .{ .output = "mismatch", .retry_number = 3 } });
    try run.observe(agent_types.LifecycleEvent{ .output_validation_end = .{ .output = "later", .retry_number = 2 } });
    try run.observe(agent_types.LifecycleEvent{ .stream_event = .{
        .stage = .before,
        .event = .{ .deferred_tool_requests = undefined },
    } });

    try std.testing.expectEqual(@as(usize, 3), capture.output_spans);
    try std.testing.expectEqual(@as(usize, 1), capture.output_errors);
    try std.testing.expect(capture.events >= 9);
    try std.testing.expect(capture.saw_retry_event);
    try std.testing.expect(capture.saw_stream_event);
}

test "telemetry names every agent stream event" {
    const agent_types = @import("agent.zig");
    try std.testing.expectEqualStrings("model", streamEventName(agent_types.AgentStreamEvent{ .model = undefined }));
    try std.testing.expectEqualStrings("function_tool_call", streamEventName(agent_types.AgentStreamEvent{ .function_tool_call = undefined }));
    try std.testing.expectEqualStrings("function_tool_result", streamEventName(agent_types.AgentStreamEvent{ .function_tool_result = undefined }));
    try std.testing.expectEqualStrings("tool_availability_delta", streamEventName(agent_types.AgentStreamEvent{ .tool_availability_delta = undefined }));
    try std.testing.expectEqualStrings("deferred_tool_requests", streamEventName(agent_types.AgentStreamEvent{ .deferred_tool_requests = undefined }));
    try std.testing.expectEqualStrings("deferred_tool_results", streamEventName(agent_types.AgentStreamEvent{ .deferred_tool_results = undefined }));
    try std.testing.expectEqualStrings("enqueued_messages", streamEventName(agent_types.AgentStreamEvent{ .enqueued_messages = undefined }));
    try std.testing.expectEqualStrings("partial_output", streamEventName(agent_types.AgentStreamEvent{ .partial_output = undefined }));
    try std.testing.expectEqualStrings("final_result", streamEventName(agent_types.AgentStreamEvent{ .final_result = undefined }));
}

fn checkTelemetryAllocationFailure(allocator: std.mem.Allocator) !void {
    const agent_types = @import("agent.zig");
    const Sink = struct {
        fn span(_: *anyopaque, _: Span) !void {} // kcov-ignore: allocation failures stop before this sink
        fn metric(_: *anyopaque, _: Metric) !void {} // kcov-ignore: allocation failures stop before this sink
    };
    var unused: u8 = 0;
    const model = model_types.Model{
        .context = &unused,
        .profile = .{},
        .model_name = "allocation-model",
        .requestFn = struct {
            fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse { // kcov-ignore
                return .{ .parts = &.{} }; // kcov-ignore
            }
        }.request,
    };
    var run = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = .{ .context = &unused, .spanFn = Sink.span, .metricFn = Sink.metric },
        .content = .{ .prompts = .raw },
    }).start(allocator);
    defer run.deinit();
    try run.observe(agent_types.LifecycleEvent{ .run_start = .{ .prompt = "prompt", .model = model } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_start = .{
        .number = 1,
        .request = .{ .messages = &.{} },
        .streaming = false,
    } });
    try run.observe(agent_types.LifecycleEvent{ .model_request_end = .{
        .number = 1,
        .response = .{ .parts = &.{}, .model_name = "allocation-model" },
    } });
    const call = model_types.ToolCall{ .id = "call", .name = "allocation-tool", .arguments_json = "{}" };
    try run.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = call } });
    try run.observe(agent_types.LifecycleEvent{ .tool_execution_end = .{ .call = call, .content = "ok" } });
    try run.observe(agent_types.LifecycleEvent{ .run_end = .{ .output = "ok", .usage = .{}, .model_requests = 1 } });
}

test "telemetry fail-open processing releases failed allocations" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try checkTelemetryAllocationFailure(failing.allocator());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "traceparent round trips and rejects malformed identities" {
    const context = SpanContext{
        .trace_id = [_]u8{0x11} ** 16,
        .span_id = [_]u8{0x22} ** 8,
    };
    var buffer: [traceparent_length]u8 = undefined;
    const encoded = try formatTraceparent(context, &buffer);
    try std.testing.expectEqualStrings(
        "00-11111111111111111111111111111111-2222222222222222-01",
        encoded,
    );
    const parsed = try parseTraceparent(encoded);
    try std.testing.expectEqualSlices(u8, &context.trace_id, &parsed.trace_id);
    try std.testing.expectEqualSlices(u8, &context.span_id, &parsed.span_id);

    const invalid = [_][]const u8{
        "",
        "01-11111111111111111111111111111111-2222222222222222-01",
        "00-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-2222222222222222-01",
        "00-11111111111111111111111111111111-zzzzzzzzzzzzzzzz-01",
        "00-11111111111111111111111111111111-2222222222222222-zz",
        "00-00000000000000000000000000000000-2222222222222222-01",
    };
    for (invalid) |value| try std.testing.expectError(error.InvalidTraceparent, parseTraceparent(value));
    var zero_buffer: [traceparent_length]u8 = undefined;
    try std.testing.expectError(error.InvalidTraceparent, formatTraceparent(.{
        .trace_id = [_]u8{0} ** 16,
        .span_id = [_]u8{0} ** 8,
    }, &zero_buffer));
}

test "MCP telemetry emits semantic client and server operations" {
    const Capture = struct {
        client_spans: usize = 0,
        server_spans: usize = 0,
        metrics: usize = 0,
        errors: usize = 0,

        fn span(context: *anyopaque, value: Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value.kind == .client) self.client_spans += 1;
            if (value.kind == .server) self.server_spans += 1;
            if (value.status == .error_status) self.errors += 1;
            try std.testing.expect(value.attributes.len <= 8);
        }

        fn metric(context: *anyopaque, value: Metric) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(std.mem.startsWith(u8, value.name, "mcp."));
            self.metrics += 1;
        }
    };
    var capture: Capture = .{};
    const exporter = Exporter{ .context = &capture, .spanFn = Capture.span, .metricFn = Capture.metric };
    const parent = SpanContext{ .trace_id = [_]u8{1} ** 16, .span_id = [_]u8{2} ** 8 };
    var client = (McpTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
        .parent = parent,
        .network_transport = "pipe",
        .network_protocol_name = "stdio",
        .session_id = "session",
        .limits = .{ .max_attributes = 8, .max_attribute_value_bytes = 64 },
    }).start(
        std.testing.allocator,
        .client,
        "tools/call",
        .{ .kind = .tool, .value = "weather" },
        "7",
        null,
        "2026-07-28",
    );
    try client.finish(null);
    var server = (McpTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
    }).start(
        std.testing.allocator,
        .server,
        "resources/read",
        .{ .kind = .resource, .value = "file:///bounded" },
        null,
        client.spanContext(),
        "2026-07-28",
    );
    try server.finish("-32603");

    try std.testing.expectEqual(@as(usize, 1), capture.client_spans);
    try std.testing.expectEqual(@as(usize, 1), capture.server_spans);
    try std.testing.expectEqual(@as(usize, 2), capture.metrics);
    try std.testing.expectEqual(@as(usize, 1), capture.errors);
}

test "fail-closed telemetry preserves span-name allocation errors" {
    const agent_types = @import("agent.zig");
    const Sink = struct {
        fn span(_: *anyopaque, _: Span) !void {}
        fn metric(_: *anyopaque, _: Metric) !void {}
    };
    var unused: u8 = 0;
    const exporter = Exporter{ .context = &unused, .spanFn = Sink.span, .metricFn = Sink.metric };
    const call = model_types.ToolCall{ .id = "call", .name = "weather", .arguments_json = "{}" };

    var validation_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var validation = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
        .fail_open = false,
    }).start(validation_allocator.allocator());
    defer validation.deinit();
    try validation.observe(agent_types.LifecycleEvent{ .tool_validation_start = .{ .call = call } });
    try std.testing.expectError(error.OutOfMemory, validation.observe(agent_types.LifecycleEvent{
        .tool_validation_end = .{ .call = call, .tool = undefined },
    }));

    var execution_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var execution = (OpenTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
        .fail_open = false,
    }).start(execution_allocator.allocator());
    defer execution.deinit();
    try execution.observe(agent_types.LifecycleEvent{ .tool_execution_start = .{ .call = call, .tool = undefined } });
    try std.testing.expectError(error.OutOfMemory, execution.observe(agent_types.LifecycleEvent{
        .tool_execution_end = .{ .call = call, .content = "ok" },
    }));

    var mcp_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var mcp_run = (McpTelemetry{
        .io = std.testing.io,
        .exporter = exporter,
        .fail_open = false,
    }).start(
        mcp_allocator.allocator(),
        .client,
        "tools/call",
        .{ .kind = .tool, .value = "weather" },
        "1",
        null,
        "2026-07-28",
    );
    try std.testing.expectError(error.OutOfMemory, mcp_run.finish(null));
}

test {
    _ = @import("telemetry/buffer.zig");
}
