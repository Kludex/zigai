const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const base_url = init.environ_map.get("ZIGAI_FIXTURE_BASE_URL") orelse return error.MissingFixtureUrl;
    const url = try std.fmt.allocPrint(init.gpa, "{s}/health", .{base_url});
    defer init.gpa.free(url);
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = .{ .allow_http = true, .allow_local_network = true },
    });
    defer http.deinit();
    const HeaderCapture = struct {
        saw_content_type: bool = false,
        fn header(context: *anyopaque, value: zigai.transport.Header) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.ascii.eqlIgnoreCase(value.name, "content-type")) {
                if (!std.mem.eql(u8, value.value, "text/plain")) return error.UnexpectedFixtureHeader;
                self.saw_content_type = true;
            }
        }
    };
    var header_capture: HeaderCapture = .{};
    const response = try http.transport().send(init.gpa, .{
        .method = .GET,
        .url = url,
        .response_header_sink = .{ .context = &header_capture, .headerFn = HeaderCapture.header },
    });
    defer init.gpa.free(response.body);
    if (response.status != 200 or !std.mem.eql(u8, response.body, "healthy") or !header_capture.saw_content_type)
        return error.UnexpectedFixtureResponse;

    const delete_url = try std.fmt.allocPrint(init.gpa, "{s}/delete", .{base_url});
    defer init.gpa.free(delete_url);
    const deleted = try http.transport().send(init.gpa, .{ .method = .DELETE, .url = delete_url });
    defer init.gpa.free(deleted.body);
    if (deleted.status != 200 or !std.mem.eql(u8, deleted.body, "deleted")) return error.UnexpectedFixtureResponse;

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

    const redirect_url = try std.fmt.allocPrint(init.gpa, "{s}/redirect", .{base_url});
    defer init.gpa.free(redirect_url);
    if (http.transport().send(init.gpa, .{ .method = .GET, .url = redirect_url })) |redirect| {
        init.gpa.free(redirect.body);
        return error.ExpectedRedirectRejection;
    } else |err| switch (err) {
        error.RedirectRejected => {},
        else => return err,
    }
    if (http.transport().streamLines(init.gpa, .{ .method = .GET, .url = redirect_url }, .{
        .context = &capture,
        .startFn = Capture.start,
        .lineFn = Capture.line,
    })) |_| {
        return error.ExpectedRedirectRejection;
    } else |err| switch (err) {
        error.RedirectRejected => {},
        else => return err,
    }
    if (capture.starts != 2 or capture.lines != 6) return error.UnexpectedRedirectEvents;

    var inspect_redirect_http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = .{ .allow_http = true, .allow_local_network = true },
        .redirect_policy = .return_response,
    });
    defer inspect_redirect_http.deinit();
    const redirect = try inspect_redirect_http.transport().send(init.gpa, .{ .method = .GET, .url = redirect_url });
    defer init.gpa.free(redirect.body);
    if (redirect.status != 302 or redirect.body.len != 0) return error.UnexpectedRedirectResponse;

    var limited_http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .limits = .{
            .max_response_body_bytes = 8,
            .max_stream_line_bytes = 8,
        },
        .url_policy = .{ .allow_http = true, .allow_local_network = true },
    });
    defer limited_http.deinit();
    const exact_body_url = try std.fmt.allocPrint(init.gpa, "{s}/body-limit-exact", .{base_url});
    defer init.gpa.free(exact_body_url);
    const exact_body = try limited_http.transport().send(init.gpa, .{ .method = .GET, .url = exact_body_url });
    defer init.gpa.free(exact_body.body);
    if (!std.mem.eql(u8, exact_body.body, "xxxxxxxx")) return error.UnexpectedLimitedBody;

    const oversized_body_url = try std.fmt.allocPrint(init.gpa, "{s}/body-limit-over", .{base_url});
    defer init.gpa.free(oversized_body_url);
    if (limited_http.transport().send(init.gpa, .{ .method = .GET, .url = oversized_body_url })) |oversized| {
        init.gpa.free(oversized.body);
        return error.ExpectedResponseTooLarge;
    } else |err| switch (err) {
        error.ResponseTooLarge => {},
        else => return err,
    }

    const exact_stream_url = try std.fmt.allocPrint(init.gpa, "{s}/stream-limit-exact", .{base_url});
    defer init.gpa.free(exact_stream_url);
    _ = try limited_http.transport().streamLines(init.gpa, .{ .method = .GET, .url = exact_stream_url }, .{
        .context = &capture,
        .startFn = Capture.start,
        .lineFn = Capture.line,
    });
    if (capture.starts != 3 or capture.lines != 7) return error.UnexpectedStreamEvents;

    const oversized_stream_url = try std.fmt.allocPrint(init.gpa, "{s}/stream-limit-over", .{base_url});
    defer init.gpa.free(oversized_stream_url);
    if (limited_http.transport().streamLines(init.gpa, .{ .method = .GET, .url = oversized_stream_url }, .{
        .context = &capture,
        .startFn = Capture.start,
        .lineFn = Capture.line,
    })) |_| {
        return error.ExpectedStreamLineTooLarge;
    } else |err| switch (err) {
        error.StreamLineTooLarge => {},
        else => return err,
    }
    if (capture.starts != 4 or capture.lines != 7) return error.UnexpectedStreamEvents;

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
