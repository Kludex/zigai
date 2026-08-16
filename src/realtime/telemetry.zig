//! OpenTelemetry signals for provider-neutral realtime session observations.

const std = @import("std");
const telemetry_types = @import("../telemetry.zig");
const base = @import("base.zig");

/// Realtime telemetry configuration.
pub const Config = struct {
    io: std.Io,
    exporter: telemetry_types.Exporter,
    parent: ?telemetry_types.SpanContext = null,
    fail_open: bool = true,

    pub fn start(self: Config) Run {
        const parent = if (self.parent) |value| if (value.isValid()) value else null else null;
        return .{
            .config = self,
            .trace_id = if (parent) |value| value.trace_id else randomId(16, self.io),
            .span_id = randomId(8, self.io),
            .parent_span_id = if (parent) |value| value.span_id else null,
            .started_unix_ns = @intCast(std.Io.Clock.real.now(self.io).nanoseconds),
            .started_awake_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds),
        };
    }
};

/// Per-session instrumentation. It must outlive the observed `Session`.
pub const Run = struct {
    config: Config,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    started_unix_ns: i128,
    started_awake_ns: i128,
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    transport_kind: ?base.TransportKind = null,
    events: usize = 0,
    finished: bool = false,

    pub fn observer(self: *Run) base.Observer {
        return .{ .context = self, .event_fn = observe };
    }

    pub fn spanContext(self: Run) telemetry_types.SpanContext {
        return .{ .trace_id = self.trace_id, .span_id = self.span_id };
    }

    /// Completes the session span once. `error_type` must be low-cardinality.
    pub fn finish(self: *Run, error_type: ?[]const u8) !void {
        if (self.finished) return;
        self.finished = true;
        self.finishFallible(error_type) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }

    fn observe(context: ?*anyopaque, observation: base.Observation) !void {
        const self: *Run = @ptrCast(@alignCast(context.?));
        self.observeFallible(observation) catch |failure| {
            if (!self.config.fail_open) return failure;
        };
    }

    fn observeFallible(self: *Run, observation: base.Observation) !void {
        self.events += 1;
        var attributes: [6]telemetry_types.Attribute = undefined;
        var count: usize = 0;
        const name: []const u8 = switch (observation) {
            .connected => |value| blk: {
                self.provider_name = value.provider_name;
                self.model_name = value.model_name;
                self.transport_kind = value.transport_kind;
                attributes[count] = .{ .key = "gen_ai.provider.name", .value = .{ .string = value.provider_name } };
                count += 1;
                attributes[count] = .{ .key = "gen_ai.request.model", .value = .{ .string = value.model_name } };
                count += 1;
                attributes[count] = .{
                    .key = "network.transport",
                    .value = .{ .string = @tagName(value.transport_kind) },
                };
                count += 1;
                attributes[count] = .{
                    .key = "zigai.realtime.audio.input_rate",
                    .value = .{ .integer = value.profile.audio_input_sample_rate },
                };
                count += 1;
                attributes[count] = .{
                    .key = "zigai.realtime.audio.output_rate",
                    .value = .{ .integer = value.profile.audio_output_sample_rate },
                };
                count += 1;
                break :blk "zigai.realtime.connected";
            },
            .input => |input| blk: {
                attributes[count] = .{ .key = "zigai.realtime.input.type", .value = .{ .string = @tagName(input) } };
                count += 1;
                break :blk "zigai.realtime.input";
            },
            .event => |event| blk: {
                attributes[count] = .{ .key = "zigai.realtime.event.type", .value = .{
                    .string = @tagName(std.meta.activeTag(event)),
                } };
                count += 1;
                break :blk switch (event) {
                    .turn_complete => "zigai.realtime.turn.complete",
                    .reconnect => "zigai.realtime.reconnect",
                    .session_error => "zigai.realtime.error",
                    else => "zigai.realtime.event",
                };
            },
            .usage => |usage| blk: {
                try self.config.exporter.metric(.{
                    .name = "zigai.realtime.tokens",
                    .kind = .counter,
                    .value = @floatFromInt(usage.totalTokens()),
                    .unit = "{token}",
                    .attributes = &.{},
                });
                break :blk "zigai.realtime.usage";
            },
        };
        try self.config.exporter.event(.{
            .name = name,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .time_unix_nano = @intCast(std.Io.Clock.real.now(self.config.io).nanoseconds),
            .attributes = attributes[0..count],
        });
    }

    fn finishFallible(self: *Run, error_type: ?[]const u8) !void {
        const ended_unix_ns: i128 = @intCast(std.Io.Clock.real.now(self.config.io).nanoseconds);
        const ended_awake_ns: i128 = @intCast(std.Io.Clock.awake.now(self.config.io).nanoseconds);
        var attributes: [6]telemetry_types.Attribute = undefined;
        var count: usize = 0;
        attributes[count] = .{ .key = "gen_ai.operation.name", .value = .{ .string = "invoke_agent" } };
        count += 1;
        attributes[count] = .{ .key = "pydantic_ai.realtime", .value = .{ .boolean = true } };
        count += 1;
        if (self.provider_name) |provider| {
            attributes[count] = .{ .key = "gen_ai.provider.name", .value = .{ .string = provider } };
            count += 1;
        }
        if (self.model_name) |model| {
            attributes[count] = .{ .key = "gen_ai.request.model", .value = .{ .string = model } };
            count += 1;
        }
        attributes[count] = .{ .key = "zigai.realtime.event.count", .value = .{ .integer = @intCast(self.events) } };
        count += 1;
        if (error_type) |failure| {
            attributes[count] = .{ .key = "error.type", .value = .{ .string = failure } };
            count += 1;
        }
        const duration_ns = @max(ended_awake_ns - self.started_awake_ns, 0);
        try self.config.exporter.span(.{
            .name = "invoke_agent realtime",
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = self.parent_span_id,
            .start_time_unix_nano = self.started_unix_ns,
            .end_time_unix_nano = ended_unix_ns,
            .duration_seconds = @as(f64, @floatFromInt(duration_ns)) / std.time.ns_per_s,
            .status = if (error_type == null) .ok else .error_status,
            .attributes = attributes[0..count],
        });
    }
};

fn randomId(comptime length: usize, io: std.Io) [length]u8 {
    var result: [length]u8 = undefined;
    io.random(&result);
    if (std.mem.allEqual(u8, &result, 0)) result[length - 1] = 1;
    return result;
}

test "realtime telemetry correlates events usage and the session span" {
    const Capture = struct {
        spans: usize = 0,
        events: usize = 0,
        metrics: usize = 0,
        parent: [8]u8,

        fn span(context: *anyopaque, value: telemetry_types.Span) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualSlices(u8, &self.parent, &value.parent_span_id.?);
            self.spans += 1;
        }
        fn event(context: *anyopaque, _: telemetry_types.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
        fn metric(context: *anyopaque, _: telemetry_types.Metric) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.metrics += 1;
        }
    };
    const parent = telemetry_types.SpanContext{
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
    };
    var capture = Capture{ .parent = parent.span_id };
    var run = (Config{
        .io = std.testing.io,
        .parent = parent,
        .exporter = .{
            .context = &capture,
            .spanFn = Capture.span,
            .metricFn = Capture.metric,
            .eventFn = Capture.event,
        },
    }).start();
    const observer = run.observer();
    try observer.emit(.{ .connected = .{
        .transport_kind = .websocket,
        .provider_name = "openai",
        .model_name = "gpt-realtime",
        .profile = .{},
    } });
    try observer.emit(.{ .input = .audio });
    try observer.emit(.{ .event = .{ .turn_complete = .{ .interrupted = false, .response_id = "r1" } } });
    try observer.emit(.{ .usage = .{ .input_tokens = 2, .output_tokens = 3 } });
    try run.finish(null);
    try run.finish(null);
    try std.testing.expect(run.spanContext().isValid());
    try std.testing.expectEqual(@as(usize, 1), capture.spans);
    try std.testing.expectEqual(@as(usize, 4), capture.events);
    try std.testing.expectEqual(@as(usize, 1), capture.metrics);
}
