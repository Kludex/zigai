const std = @import("std");
const zigai = @import("zigai");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.promptAndKey(init, "GEMINI_API_KEY");
    const base_url = init.environ_map.get("GEMINI_BASE_URL") orelse zigai.google.api_base;
    const url_policy = common.urlPolicyForConfiguredEndpoint(base_url, zigai.google.api_base);
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = url_policy,
    });
    defer http.deinit();
    var provider = zigai.google.Provider.initWithOptions(input.api_key, http.transport(), .{
        .base_url = base_url,
        .request_policy = .{ .url_policy = url_policy },
    });
    var client = zigai.google.Client{
        .model_name = init.environ_map.get("GEMINI_MODEL") orelse "gemini-2.5-flash-lite",
        .provider = provider.provider(),
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
