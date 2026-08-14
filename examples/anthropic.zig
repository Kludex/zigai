const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey;
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var client = zigai.anthropic.Client{ .model_name = "claude-sonnet-4-5", .api_key = key, .transport = http.transport() };
    var result = try (zigai.Agent{ .model = client.model(), .system_prompt = "Be concise." }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
