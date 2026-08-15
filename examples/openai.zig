const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("OPENAI_API_KEY") orelse return error.MissingApiKey;
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var provider = zigai.openai.Provider.init(key, http.transport());
    var client = zigai.openai.Client{ .model_name = "gpt-5-mini", .provider = provider.provider() };
    var result = try (zigai.Agent{ .model = client.model(), .system_prompt = "Be concise.", .io = init.io }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
