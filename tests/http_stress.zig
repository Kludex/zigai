//! Repeated real-socket requests against a fixture that closes every connection.

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

    for (0..128) |_| {
        const response = try http.transport().send(init.gpa, .{ .method = .GET, .url = url });
        defer init.gpa.free(response.body);
        if (response.status != 200 or !std.mem.eql(u8, response.body, "healthy")) {
            return error.UnexpectedFixtureResponse;
        }
    }
}
