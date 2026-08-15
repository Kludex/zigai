const std = @import("std");
const zigai = @import("zigai");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.promptAndKey(init, "OPENAI_API_KEY");
    const base_url = init.environ_map.get("OPENAI_BASE_URL") orelse zigai.openai.api_base;
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = common.urlPolicyForConfiguredEndpoint(base_url, zigai.openai.api_base),
    });
    defer http.deinit();
    var client = zigai.openai.Client{
        .model_name = init.environ_map.get("OPENAI_MODEL") orelse "gpt-5-mini",
        .api_key = input.api_key,
        .transport = http.transport(),
        .base_url = base_url,
    };
    var loaded_tools = try common.LoadedTools.load(init.gpa, init.io, input.tools_path);
    defer loaded_tools.deinit();
    var stream_io = init.io;
    var result = if (input.stream)
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools, .io = init.io }).runStream(init.gpa, input.prompt, common.streamSink(&stream_io))
    else
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools, .io = init.io }).run(init.gpa, input.prompt);
    defer result.deinit();
    if (input.stream) try common.printNewline(init.io) else try common.printResult(init.io, result.output);
}
