const std = @import("std");
const zigai = @import("zigai");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.promptAndKey(init, "GEMINI_API_KEY");
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var recording = common.Recording.init(init.gpa, http.transport(), init.environ_map.get("ZIGAI_CASSETTE_PATH"));
    defer recording.deinit();
    var client = zigai.google.Client{
        .model_name = init.environ_map.get("GEMINI_MODEL") orelse "gemini-2.5-flash-lite",
        .api_key = input.api_key,
        .transport = recording.transport(http.transport()),
        .base_url = init.environ_map.get("GEMINI_BASE_URL") orelse zigai.google.api_base,
    };
    var loaded_tools = try common.LoadedTools.load(init.gpa, init.io, input.tools_path);
    defer loaded_tools.deinit();
    var stream_io = init.io;
    var result = if (input.stream)
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools }).runStream(init.gpa, input.prompt, common.streamSink(&stream_io))
    else
        try (zigai.Agent{ .model = client.model(), .tools = loaded_tools.tools }).run(init.gpa, input.prompt);
    defer result.deinit();
    try recording.finish(init.io);
    if (input.stream) try common.printNewline(init.io) else try common.printResult(init.io, result.output);
}
