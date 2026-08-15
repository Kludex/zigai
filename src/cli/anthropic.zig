const std = @import("std");
const zigai = @import("zigai");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.promptAndKey(init, "ANTHROPIC_API_KEY");
    const base_url = init.environ_map.get("ANTHROPIC_BASE_URL") orelse zigai.anthropic.api_base;
    const url_policy = common.urlPolicyForConfiguredEndpoint(base_url, zigai.anthropic.api_base);
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = url_policy,
    });
    defer http.deinit();
    var client = zigai.anthropic.Client{
        .model_name = init.environ_map.get("ANTHROPIC_MODEL") orelse "claude-haiku-4-5",
        .api_key = input.api_key,
        .transport = http.transport(),
        .base_url = base_url,
    };
    var loaded_tools = try common.LoadedTools.load(init.gpa, init.io, input.tools_path);
    defer loaded_tools.deinit();
    var stream_io = init.io;
    var result = if (input.stream)
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools, .url_policy = url_policy, .io = init.io }).runStream(init.gpa, input.prompt, common.streamSink(&stream_io))
    else
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools, .url_policy = url_policy, .io = init.io }).run(init.gpa, input.prompt);
    defer result.deinit();
    if (input.stream) try common.printNewline(init.io) else try common.printResult(init.io, result.output);
}
