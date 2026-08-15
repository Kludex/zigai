const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get(zigai.providers.zai.api_key_env) orelse return error.MissingApiKey;
    const model_name = init.environ_map.get("ZAI_MODEL") orelse "glm-5.1";
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var provider = zigai.providers.zai.Provider.init(key, http.transport());
    var client = zigai.providers.zai.Client{
        .model_name = model_name,
        .provider = provider.provider(),
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .system_prompt = "Be concise.",
        .io = init.io,
    }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
