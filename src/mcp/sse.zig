//! Bounded Server-Sent Events framing for request-scoped MCP responses.

const std = @import("std");

pub const Error = error{SseEventTooLarge};

/// Receives one assembled SSE `data` value. The value is borrowed for the
/// callback duration.
pub const DataSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, data: []const u8) anyerror!void,

    pub fn emit(self: DataSink, data: []const u8) !void {
        return self.emitFn(self.context, data);
    }
};

/// Incremental SSE parser. It deliberately ignores `event`, `id`, and `retry`:
/// MCP 2026-07-28 streams are request-scoped and have no Last-Event-ID resume
/// path.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    max_event_bytes: usize,
    sink: DataSink,
    data: std.ArrayList(u8) = .empty,
    has_data: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_event_bytes: usize, sink: DataSink) Parser {
        return .{
            .allocator = allocator,
            .max_event_bytes = max_event_bytes,
            .sink = sink,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes one line without its LF terminator. A trailing CR is accepted.
    pub fn line(self: *Parser, raw_line: []const u8) !void {
        const value = std.mem.trimEnd(u8, raw_line, "\r");
        if (value.len == 0) return self.dispatch();
        if (value[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, value, ':');
        const field = if (colon) |index| value[0..index] else value;
        if (!std.mem.eql(u8, field, "data")) return;
        var field_value = if (colon) |index| value[index + 1 ..] else "";
        if (field_value.len > 0 and field_value[0] == ' ') field_value = field_value[1..];
        const separator: usize = @intFromBool(self.has_data);
        if (separator > self.max_event_bytes or
            self.data.items.len > self.max_event_bytes - separator or
            field_value.len > self.max_event_bytes - separator - self.data.items.len)
        {
            return error.SseEventTooLarge;
        }
        if (self.has_data) try self.data.append(self.allocator, '\n');
        try self.data.appendSlice(self.allocator, field_value);
        self.has_data = true;
    }

    /// Dispatches a final event even when EOF is not preceded by a blank line.
    pub fn finish(self: *Parser) !void {
        return self.dispatch();
    }

    fn dispatch(self: *Parser) !void {
        if (!self.has_data) return;
        try self.sink.emit(self.data.items);
        self.data.clearRetainingCapacity();
        self.has_data = false;
    }
};

test "SSE parser assembles bounded multi-line data and ignores stateless fields" {
    const Capture = struct {
        values: [3][32]u8 = undefined,
        lengths: [3]usize = .{0} ** 3,
        count: usize = 0,

        fn emit(context: *anyopaque, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.values[self.count][0..data.len], data);
            self.lengths[self.count] = data.len;
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var parser = Parser.init(std.testing.allocator, 32, .{
        .context = &capture,
        .emitFn = Capture.emit,
    });
    defer parser.deinit();
    try parser.line(": keepalive");
    try parser.line("event: message");
    try parser.line("id: removed-in-2026");
    try parser.line("retry: 1000");
    try parser.line("data: first");
    try parser.line("data:second\r");
    try parser.line("");
    try parser.line("data");
    try parser.line("");
    try parser.line("data: final");
    try parser.finish();
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualStrings("first\nsecond", capture.values[0][0..capture.lengths[0]]);
    try std.testing.expectEqualStrings("", capture.values[1][0..capture.lengths[1]]);
    try std.testing.expectEqualStrings("final", capture.values[2][0..capture.lengths[2]]);
}

test "SSE parser rejects joined events beyond its byte bound" {
    var unused: u8 = 0;
    const Sink = struct {
        fn emit(_: *anyopaque, _: []const u8) !void {}
    };
    var parser = Parser.init(std.testing.allocator, 3, .{
        .context = &unused,
        .emitFn = Sink.emit,
    });
    defer parser.deinit();
    try parser.line("data:a");
    try std.testing.expectError(error.SseEventTooLarge, parser.line("data:bc"));
    try parser.finish();

    var zero = Parser.init(std.testing.allocator, 0, .{
        .context = &unused,
        .emitFn = Sink.emit,
    });
    defer zero.deinit();
    try zero.line("data:");
    try std.testing.expectError(error.SseEventTooLarge, zero.line("data:"));
}

test "SSE parser releases every partial allocation" {
    const Check = struct {
        fn emit(_: *anyopaque, _: []const u8) !void {}

        fn run(allocator: std.mem.Allocator) !void {
            var unused: u8 = 0;
            var parser = Parser.init(allocator, 64, .{
                .context = &unused,
                .emitFn = emit,
            });
            defer parser.deinit();
            try parser.line("data: first");
            try parser.line("data: second");
            try parser.finish();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
