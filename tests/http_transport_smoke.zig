const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const base_url = init.environ_map.get("ZIGAI_FIXTURE_BASE_URL") orelse return error.MissingFixtureUrl;
    const url = try std.fmt.allocPrint(init.gpa, "{s}/health", .{base_url});
    defer init.gpa.free(url);
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    const response = try http.transport().send(init.gpa, .{ .method = .GET, .url = url });
    defer init.gpa.free(response.body);
    if (response.status != 200 or !std.mem.eql(u8, response.body, "healthy")) return error.UnexpectedFixtureResponse;

    const stream_url = try std.fmt.allocPrint(init.gpa, "{s}/stream", .{base_url});
    defer init.gpa.free(stream_url);
    const Capture = struct {
        starts: usize = 0,
        lines: usize = 0,
        fn start(context: *anyopaque, stream_response: zigai.transport.StreamResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.starts += 1;
            if (stream_response.status != 200) return error.UnexpectedStreamStatus;
        }
        fn line(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.lines += 1;
        }
    };
    var capture: Capture = .{};
    _ = try http.transport().streamLines(init.gpa, .{ .method = .GET, .url = stream_url }, .{
        .context = &capture,
        .startFn = Capture.start,
        .lineFn = Capture.line,
    });
    if (capture.starts != 1 or capture.lines != 3) return error.UnexpectedStreamEvents;
    _ = try http.transport().streamLines(init.gpa, .{ .method = .POST, .url = stream_url, .body = "request" }, .{
        .context = &capture,
        .startFn = Capture.start,
        .lineFn = Capture.line,
    });
    if (capture.starts != 2 or capture.lines != 6) return error.UnexpectedStreamEvents;

    const slow_url = try std.fmt.allocPrint(init.gpa, "{s}/slow", .{base_url});
    defer init.gpa.free(slow_url);
    if (http.transport().send(init.gpa, .{
        .method = .GET,
        .url = slow_url,
        .timeout_ms = 10,
    })) |late_response| {
        init.gpa.free(late_response.body);
        return error.ExpectedRequestTimeout;
    } else |err| switch (err) {
        error.RequestTimedOut => {},
        else => return err,
    }

    var token: zigai.CancellationToken = .{};
    var cancel_future = try init.io.concurrent(cancelAfter, .{ init.io, &token });
    if (http.transport().send(init.gpa, .{
        .method = .GET,
        .url = slow_url,
        .cancellation = &token,
    })) |late_response| {
        init.gpa.free(late_response.body);
        return error.ExpectedRequestCancellation;
    } else |err| switch (err) {
        error.RequestCancelled => {},
        else => return err,
    }
    try cancel_future.await(init.io);

    if (http.transport().streamLines(init.gpa, .{
        .method = .GET,
        .url = slow_url,
        .timeout_ms = 10,
    }, .{ .context = &capture, .startFn = Capture.start, .lineFn = Capture.line })) |_| {
        return error.ExpectedStreamTimeout;
    } else |err| switch (err) {
        error.RequestTimedOut => {},
        else => return err,
    }

    var stream_token: zigai.CancellationToken = .{};
    var stream_cancel_future = try init.io.concurrent(cancelAfter, .{ init.io, &stream_token });
    if (http.transport().streamLines(init.gpa, .{
        .method = .GET,
        .url = slow_url,
        .cancellation = &stream_token,
    }, .{ .context = &capture, .startFn = Capture.start, .lineFn = Capture.line })) |_| {
        return error.ExpectedStreamCancellation;
    } else |err| switch (err) {
        error.RequestCancelled => {},
        else => return err,
    }
    try stream_cancel_future.await(init.io);
}

fn cancelAfter(io: std.Io, token: *zigai.CancellationToken) !void {
    try (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(10),
        .clock = .awake,
    } }).sleep(io);
    token.cancel();
}
