//! Borrowed telemetry signals and the synchronous exporter boundary.

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

    pub const Kind = enum { internal, client, server };
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

/// Instantaneous signal correlated with an agent trace and active phase.
pub const Event = struct {
    name: []const u8,
    trace_id: [16]u8,
    span_id: [8]u8,
    time_unix_nano: i128,
    attributes: []const Attribute,
};

/// Synchronous bridge to an OpenTelemetry SDK or OTLP exporter.
pub const Exporter = struct {
    context: *anyopaque,
    spanFn: *const fn (context: *anyopaque, span: Span) anyerror!void,
    metricFn: *const fn (context: *anyopaque, metric: Metric) anyerror!void,
    eventFn: ?*const fn (context: *anyopaque, event: Event) anyerror!void = null,

    pub fn span(self: Exporter, value: Span) !void {
        return self.spanFn(self.context, value);
    }

    pub fn metric(self: Exporter, value: Metric) !void {
        return self.metricFn(self.context, value);
    }

    pub fn event(self: Exporter, value: Event) !void {
        const emit = self.eventFn orelse return;
        return emit(self.context, value);
    }
};
