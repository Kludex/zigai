//! Thread-safe bounded buffering for synchronous telemetry exporters.

const std = @import("std");
const types = @import("types.zig");

const Attribute = types.Attribute;
const Event = types.Event;
const Metric = types.Metric;
const Exporter = types.Exporter;
const Span = types.Span;

/// Signals are deep-copied on admission and exported only by `flush` or
/// `shutdown`. Downstream callbacks are serialized and never run under the
/// admission lock.
pub const BufferedExporter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    downstream: Exporter,
    max_records: usize,
    overflow: OverflowPolicy = .drop_newest,
    fail_open: bool = true,

    mutex: std.Io.Mutex = .init,
    flush_mutex: std.Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,
    state: State = .open,
    dropped_backpressure: usize = 0,
    dropped_allocation: usize = 0,
    dropped_export: usize = 0,
    reported_backpressure: usize = 0,
    reported_allocation: usize = 0,
    reported_export: usize = 0,

    pub const OverflowPolicy = enum { drop_newest, drop_oldest, reject };
    pub const State = enum { open, closed };
    pub const Stats = struct {
        pending: usize,
        dropped_backpressure: usize,
        dropped_allocation: usize,
        dropped_export: usize,
    };
    pub const FlushResult = struct {
        exported: usize = 0,
        failed: usize = 0,
        dropped_reported: usize = 0,
    };

    const Record = struct {
        arena: std.heap.ArenaAllocator,
        signal: Signal,

        const Signal = union(enum) { span: Span, metric: Metric, event: Event };

        fn init(allocator: std.mem.Allocator, signal: anytype) !Record {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const memory = arena.allocator();
            const owned: Signal = switch (@TypeOf(signal)) {
                Span => .{ .span = try copySpan(memory, signal) },
                Metric => .{ .metric = try copyMetric(memory, signal) },
                Event => .{ .event = try copyEvent(memory, signal) },
                else => @compileError("unsupported telemetry signal"),
            };
            return .{ .arena = arena, .signal = owned };
        }

        fn deinit(self: *Record) void {
            self.arena.deinit();
            self.* = undefined;
        }

        fn emit(self: Record, sink: Exporter) !void {
            return switch (self.signal) {
                .span => |value| sink.span(value),
                .metric => |value| sink.metric(value),
                .event => |value| sink.event(value),
            };
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        downstream: Exporter,
        max_records: usize,
    ) BufferedExporter {
        return .{
            .allocator = allocator,
            .io = io,
            .downstream = downstream,
            .max_records = max_records,
        };
    }

    pub fn exporter(self: *BufferedExporter) Exporter {
        return .{
            .context = self,
            .spanFn = enqueueSpan,
            .metricFn = enqueueMetric,
            .eventFn = enqueueEvent,
        };
    }

    pub fn stats(self: *BufferedExporter) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .pending = self.records.items.len,
            .dropped_backpressure = self.dropped_backpressure,
            .dropped_allocation = self.dropped_allocation,
            .dropped_export = self.dropped_export,
        };
    }

    /// Prevents new admission. Already queued signals remain flushable.
    pub fn close(self: *BufferedExporter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .closed;
    }

    /// Detaches the current batch before invoking downstream callbacks.
    pub fn flush(self: *BufferedExporter) !FlushResult {
        self.flush_mutex.lockUncancelable(self.io);
        defer self.flush_mutex.unlock(self.io);

        self.mutex.lockUncancelable(self.io);
        var batch = self.records;
        self.records = .empty;
        self.mutex.unlock(self.io);
        defer batch.deinit(self.allocator);

        var result: FlushResult = .{};
        for (batch.items, 0..) |*record, index| {
            record.emit(self.downstream) catch |failure| {
                result.failed += 1;
                const dropped_count = if (self.fail_open) 1 else batch.items.len - index;
                self.incrementExportDrops(dropped_count);
                record.deinit();
                if (!self.fail_open) {
                    for (batch.items[index + 1 ..]) |*remaining| remaining.deinit();
                    return failure;
                }
                continue;
            };
            result.exported += 1;
            record.deinit();
        }
        result.dropped_reported = try self.reportDrops();
        return result;
    }

    /// Closes admission and flushes the final batch.
    pub fn shutdown(self: *BufferedExporter) !FlushResult {
        self.close();
        return self.flush();
    }

    /// Drops unflushed signals. Call `shutdown` first when delivery matters.
    pub fn deinit(self: *BufferedExporter) void {
        self.close();
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    fn enqueueSpan(context: *anyopaque, value: Span) !void {
        const self: *BufferedExporter = @ptrCast(@alignCast(context));
        return self.enqueue(value);
    }

    fn enqueueMetric(context: *anyopaque, value: Metric) !void {
        const self: *BufferedExporter = @ptrCast(@alignCast(context));
        return self.enqueue(value);
    }

    fn enqueueEvent(context: *anyopaque, value: Event) !void {
        const self: *BufferedExporter = @ptrCast(@alignCast(context));
        return self.enqueue(value);
    }

    fn enqueue(self: *BufferedExporter, signal: anytype) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .closed) return error.TelemetryExporterClosed;
        if (self.max_records == 0 or self.records.items.len >= self.max_records) {
            self.dropped_backpressure +|= 1;
            switch (self.overflow) {
                .drop_newest => return,
                .reject => return error.TelemetryBackpressure,
                .drop_oldest => if (self.records.items.len != 0) {
                    var oldest = self.records.orderedRemove(0);
                    oldest.deinit();
                } else return,
            }
        }
        const record = Record.init(self.allocator, signal) catch |failure| {
            self.dropped_allocation +|= 1;
            if (!self.fail_open) return failure;
            return;
        };
        self.records.append(self.allocator, record) catch |failure| {
            var owned = record;
            owned.deinit();
            self.dropped_allocation +|= 1;
            if (!self.fail_open) return failure;
        };
    }

    fn incrementExportDrops(self: *BufferedExporter, count: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropped_export +|= count;
    }

    fn reportDrops(self: *BufferedExporter) !usize {
        self.mutex.lockUncancelable(self.io);
        const backpressure = self.dropped_backpressure -| self.reported_backpressure;
        const allocation = self.dropped_allocation -| self.reported_allocation;
        const export_failure = self.dropped_export -| self.reported_export;
        self.mutex.unlock(self.io);

        var reported: usize = 0;
        reported +|= try self.reportDropReason(.backpressure, backpressure);
        reported +|= try self.reportDropReason(.allocation, allocation);
        reported +|= try self.reportDropReason(.export_failure, export_failure);
        return reported;
    }

    const DropReason = enum { backpressure, allocation, export_failure };

    fn reportDropReason(self: *BufferedExporter, reason: DropReason, count: usize) !usize {
        if (count == 0) return 0;
        self.downstream.metric(.{
            .name = "zigai.telemetry.dropped",
            .kind = .counter,
            .value = @floatFromInt(count),
            .unit = "{signal}",
            .attributes = &.{.{ .key = "reason", .value = .{ .string = @tagName(reason) } }},
        }) catch |failure| {
            if (!self.fail_open) return failure;
            return 0;
        };
        self.mutex.lockUncancelable(self.io);
        switch (reason) {
            .backpressure => self.reported_backpressure += count,
            .allocation => self.reported_allocation += count,
            .export_failure => self.reported_export += count,
        }
        self.mutex.unlock(self.io);
        return count;
    }
};

fn copyAttributes(allocator: std.mem.Allocator, attributes: []const Attribute) ![]Attribute {
    const copies = try allocator.alloc(Attribute, attributes.len);
    for (attributes, copies) |attribute, *copy| {
        copy.* = .{
            .key = try allocator.dupe(u8, attribute.key),
            .value = switch (attribute.value) {
                .string => |value| .{ .string = try allocator.dupe(u8, value) },
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
                .boolean => |value| .{ .boolean = value },
            },
        };
    }
    return copies;
}

fn copySpan(allocator: std.mem.Allocator, value: Span) !Span {
    var copy = value;
    copy.name = try allocator.dupe(u8, value.name);
    copy.attributes = try copyAttributes(allocator, value.attributes);
    return copy;
}

fn copyMetric(allocator: std.mem.Allocator, value: Metric) !Metric {
    var copy = value;
    copy.name = try allocator.dupe(u8, value.name);
    copy.unit = try allocator.dupe(u8, value.unit);
    copy.attributes = try copyAttributes(allocator, value.attributes);
    return copy;
}

fn copyEvent(allocator: std.mem.Allocator, value: Event) !Event {
    var copy = value;
    copy.name = try allocator.dupe(u8, value.name);
    copy.attributes = try copyAttributes(allocator, value.attributes);
    return copy;
}
const BufferedTestSink = struct {
    spans: usize = 0,
    metrics: usize = 0,
    events: usize = 0,
    dropped: usize = 0,
    first_span: ?u8 = null,
    last_span: ?u8 = null,
    saw_backpressure: bool = false,
    saw_allocation: bool = false,
    saw_export_failure: bool = false,
    owned_span_valid: bool = false,
    owned_metric_valid: bool = false,
    owned_event_valid: bool = false,
    fail_spans: usize = 0,
    fail_drop_metrics: usize = 0,

    fn exporter(self: *BufferedTestSink) Exporter {
        return .{
            .context = self,
            .spanFn = span,
            .metricFn = metric,
            .eventFn = event,
        };
    }

    fn span(context: *anyopaque, value: Span) !void {
        const self: *BufferedTestSink = @ptrCast(@alignCast(context));
        if (self.fail_spans != 0) {
            self.fail_spans -= 1;
            return error.TestExportFailure;
        }
        self.spans += 1;
        if (value.name.len != 0) {
            if (self.first_span == null) self.first_span = value.name[0];
            self.last_span = value.name[0];
        }
        if (std.mem.eql(u8, value.name, "owned-span")) {
            try std.testing.expectEqual(@as(usize, 4), value.attributes.len);
            try std.testing.expectEqualStrings("owned-key", value.attributes[0].key);
            try std.testing.expectEqualStrings("owned-value", value.attributes[0].value.string);
            try std.testing.expectEqual(@as(i64, 7), value.attributes[1].value.integer);
            try std.testing.expectEqual(@as(f64, 1.5), value.attributes[2].value.float);
            try std.testing.expect(value.attributes[3].value.boolean);
            self.owned_span_valid = true;
        }
    }

    fn metric(context: *anyopaque, value: Metric) !void {
        const self: *BufferedTestSink = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, value.name, "zigai.telemetry.dropped")) {
            if (self.fail_drop_metrics != 0) {
                self.fail_drop_metrics -= 1;
                return error.TestExportFailure;
            }
            const count: usize = @intFromFloat(value.value);
            self.dropped += count;
            try std.testing.expectEqualStrings("{signal}", value.unit);
            try std.testing.expectEqual(@as(usize, 1), value.attributes.len);
            const reason = value.attributes[0].value.string;
            self.saw_backpressure = self.saw_backpressure or std.mem.eql(u8, reason, "backpressure");
            self.saw_allocation = self.saw_allocation or std.mem.eql(u8, reason, "allocation");
            self.saw_export_failure = self.saw_export_failure or std.mem.eql(u8, reason, "export_failure");
            return;
        }
        self.metrics += 1;
        if (std.mem.eql(u8, value.name, "owned-metric")) {
            try std.testing.expectEqualStrings("ms", value.unit);
            try std.testing.expectEqualStrings("owned-value", value.attributes[0].value.string);
            self.owned_metric_valid = true;
        }
    }

    fn event(context: *anyopaque, value: Event) !void {
        const self: *BufferedTestSink = @ptrCast(@alignCast(context));
        self.events += 1;
        if (std.mem.eql(u8, value.name, "owned-event")) {
            try std.testing.expectEqualStrings("owned-value", value.attributes[0].value.string);
            self.owned_event_valid = true;
        }
    }
};

fn bufferedTestSpan(name: []const u8) Span {
    return .{
        .name = name,
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
        .start_time_unix_nano = 1,
        .end_time_unix_nano = 2,
        .duration_seconds = 0.000000001,
        .status = .ok,
        .attributes = &.{},
    };
}

test "buffered exporter owns every signal until flush" {
    var sink: BufferedTestSink = .{};
    var buffered = BufferedExporter.init(std.testing.allocator, std.testing.io, sink.exporter(), 3);
    defer buffered.deinit();
    const exporter = buffered.exporter();

    var span_name = "owned-span".*;
    var metric_name = "owned-metric".*;
    var metric_unit = "ms".*;
    var event_name = "owned-event".*;
    var key = "owned-key".*;
    var text = "owned-value".*;
    const attributes = [_]Attribute{
        .{ .key = &key, .value = .{ .string = &text } },
        .{ .key = "integer", .value = .{ .integer = 7 } },
        .{ .key = "float", .value = .{ .float = 1.5 } },
        .{ .key = "boolean", .value = .{ .boolean = true } },
    };
    var span_value = bufferedTestSpan(&span_name);
    span_value.attributes = &attributes;
    try exporter.span(span_value);
    try exporter.metric(.{
        .name = &metric_name,
        .kind = .histogram,
        .value = 2,
        .unit = &metric_unit,
        .attributes = attributes[0..1],
    });
    try exporter.event(.{
        .name = &event_name,
        .trace_id = [_]u8{3} ** 16,
        .span_id = [_]u8{4} ** 8,
        .time_unix_nano = 3,
        .attributes = attributes[0..1],
    });
    @memset(&span_name, 'x');
    @memset(&metric_name, 'x');
    @memset(&metric_unit, 'x');
    @memset(&event_name, 'x');
    @memset(&key, 'x');
    @memset(&text, 'x');

    const result = try buffered.flush();
    try std.testing.expectEqual(@as(usize, 3), result.exported);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expect(sink.owned_span_valid);
    try std.testing.expect(sink.owned_metric_valid);
    try std.testing.expect(sink.owned_event_valid);
    try std.testing.expectEqual(@as(usize, 0), buffered.stats().pending);
}

test "buffered exporter applies every overflow policy" {
    var newest_sink: BufferedTestSink = .{};
    var newest = BufferedExporter.init(std.testing.allocator, std.testing.io, newest_sink.exporter(), 1);
    defer newest.deinit();
    try newest.exporter().span(bufferedTestSpan("a"));
    try newest.exporter().span(bufferedTestSpan("b"));
    const newest_result = try newest.flush();
    try std.testing.expectEqual(@as(?u8, 'a'), newest_sink.first_span);
    try std.testing.expectEqual(@as(usize, 1), newest_result.dropped_reported);
    try std.testing.expect(newest_sink.saw_backpressure);

    var oldest_sink: BufferedTestSink = .{};
    var oldest = BufferedExporter.init(std.testing.allocator, std.testing.io, oldest_sink.exporter(), 1);
    defer oldest.deinit();
    oldest.overflow = .drop_oldest;
    try oldest.exporter().span(bufferedTestSpan("a"));
    try oldest.exporter().span(bufferedTestSpan("b"));
    _ = try oldest.flush();
    try std.testing.expectEqual(@as(?u8, 'b'), oldest_sink.first_span);

    var rejected_sink: BufferedTestSink = .{};
    var rejected = BufferedExporter.init(std.testing.allocator, std.testing.io, rejected_sink.exporter(), 1);
    defer rejected.deinit();
    rejected.overflow = .reject;
    try rejected.exporter().span(bufferedTestSpan("a"));
    try std.testing.expectError(error.TelemetryBackpressure, rejected.exporter().span(bufferedTestSpan("b")));
    _ = try rejected.flush();

    var zero_sink: BufferedTestSink = .{};
    var zero = BufferedExporter.init(std.testing.allocator, std.testing.io, zero_sink.exporter(), 0);
    defer zero.deinit();
    zero.overflow = .drop_oldest;
    try zero.exporter().span(bufferedTestSpan("a"));
    _ = try zero.flush();
    try std.testing.expectEqual(@as(usize, 0), zero_sink.spans);
    try std.testing.expectEqual(@as(usize, 1), zero_sink.dropped);
}

test "buffered exporter isolates downstream failures and retries drop metrics" {
    var open_sink: BufferedTestSink = .{ .fail_spans = 2, .fail_drop_metrics = 1 };
    var open = BufferedExporter.init(std.testing.allocator, std.testing.io, open_sink.exporter(), 2);
    defer open.deinit();
    try open.exporter().span(bufferedTestSpan("a"));
    try open.exporter().span(bufferedTestSpan("b"));
    const first = try open.flush();
    try std.testing.expectEqual(@as(usize, 2), first.failed);
    try std.testing.expectEqual(@as(usize, 0), first.dropped_reported);
    const second = try open.flush();
    try std.testing.expectEqual(@as(usize, 2), second.dropped_reported);
    try std.testing.expect(open_sink.saw_export_failure);

    var closed_sink: BufferedTestSink = .{ .fail_spans = 1 };
    var closed = BufferedExporter.init(std.testing.allocator, std.testing.io, closed_sink.exporter(), 2);
    defer closed.deinit();
    closed.fail_open = false;
    try closed.exporter().span(bufferedTestSpan("a"));
    try closed.exporter().span(bufferedTestSpan("b"));
    try std.testing.expectError(error.TestExportFailure, closed.flush());
    try std.testing.expectEqual(@as(usize, 2), closed.stats().dropped_export);
    const reported = try closed.flush();
    try std.testing.expectEqual(@as(usize, 2), reported.dropped_reported);

    var metric_sink: BufferedTestSink = .{ .fail_drop_metrics = 1 };
    var metric_failure = BufferedExporter.init(std.testing.allocator, std.testing.io, metric_sink.exporter(), 0);
    defer metric_failure.deinit();
    metric_failure.fail_open = false;
    try metric_failure.exporter().span(bufferedTestSpan("dropped"));
    try std.testing.expectError(error.TestExportFailure, metric_failure.flush());
    try std.testing.expectEqual(@as(usize, 1), (try metric_failure.flush()).dropped_reported);
}

fn checkBufferedExporterAllocationFailure(allocator: std.mem.Allocator) !void {
    var sink: BufferedTestSink = .{};
    var buffered = BufferedExporter.init(allocator, std.testing.io, sink.exporter(), 1);
    defer buffered.deinit();
    buffered.fail_open = false;
    try buffered.exporter().span(bufferedTestSpan("allocation"));
    _ = try buffered.shutdown();
}

test "buffered exporter handles allocation failure and shutdown" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBufferedExporterAllocationFailure,
        .{},
    );

    var sink: BufferedTestSink = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buffered = BufferedExporter.init(failing.allocator(), std.testing.io, sink.exporter(), 1);
    defer buffered.deinit();
    try buffered.exporter().span(bufferedTestSpan("allocation"));
    const allocation_stats = buffered.stats();
    try std.testing.expectEqual(@as(usize, 1), allocation_stats.dropped_allocation);
    _ = try buffered.shutdown();
    try std.testing.expect(sink.saw_allocation);

    try std.testing.expectError(error.TelemetryExporterClosed, buffered.exporter().span(bufferedTestSpan("closed")));
}

test "buffered exporter serializes concurrent producers" {
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var sink: BufferedTestSink = .{};
    var buffered = BufferedExporter.init(std.heap.smp_allocator, io, sink.exporter(), 2);
    defer buffered.deinit();
    const Producer = struct {
        fn emit(target: *BufferedExporter, name: []const u8) !void {
            try target.exporter().span(bufferedTestSpan(name));
        }
    };
    var first = try io.concurrent(Producer.emit, .{ &buffered, "a" });
    var second = try io.concurrent(Producer.emit, .{ &buffered, "b" });
    try first.await(io);
    try second.await(io);
    const result = try buffered.shutdown();
    try std.testing.expectEqual(@as(usize, 2), result.exported);
    try std.testing.expectEqual(@as(usize, 2), sink.spans);
    try std.testing.expectError(error.TelemetryExporterClosed, buffered.exporter().span(bufferedTestSpan("c")));
}

test "buffered exporter deinit discards pending work without callbacks" {
    var sink: BufferedTestSink = .{};
    var buffered = BufferedExporter.init(std.testing.allocator, std.testing.io, sink.exporter(), 1);
    try buffered.exporter().span(bufferedTestSpan("a"));
    buffered.deinit();
    try std.testing.expectEqual(@as(usize, 0), sink.spans);
}
