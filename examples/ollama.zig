const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const model_name = init.environ_map.get("OLLAMA_MODEL") orelse "gpt-oss:20b";
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = zigai.providers.ollama.local_request_policy.url_policy,
    });
    defer http.deinit();
    var provider = zigai.providers.ollama.Provider.init(http.transport());
    var client = zigai.providers.ollama.Client{
        .model_name = model_name,
        .provider = provider.provider(),
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .system_prompt = "Be concise.",
        .url_policy = zigai.providers.ollama.local_request_policy.url_policy,
        .io = init.io,
    }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
