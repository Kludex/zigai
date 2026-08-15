//! Opt-in recorder against one already-pinned official MCP reference server.

const std = @import("std");
const zigai = @import("zigai");
const transcripts = @import("mcp/transcripts.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 6) return error.InvalidArguments;
    const transport_kind = std.meta.stringToEnum(transcripts.TransportKind, args[1]) orelse
        return error.InvalidArguments;
    const source = transcripts.Source{ .server = args[2], .revision = args[3] };
    const output_path = args[4];

    switch (transport_kind) {
        .stdio => {
            var transport = try zigai.mcp.StdioTransport.initWithOptions(init.io, args[5..], .{
                .stderr = .inherit,
                .shutdown_grace_ms = 2_000,
            });
            defer transport.deinit();
            try record(init, transport.transport(), source, transport_kind, output_path);
        },
        .http => {
            if (args.len != 6) return error.InvalidArguments;
            var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
                .url_policy = .{ .allow_http = true, .allow_local_network = true },
            });
            defer http.deinit();
            var transport = zigai.mcp.StreamableHttpTransport.initWithPolicy(
                init.io,
                http.transport(),
                args[5],
                .{ .allow_http = true, .allow_local_network = true },
            );
            try record(init, transport.transport(), source, transport_kind, output_path);
        },
    }
}

fn record(
    init: std.process.Init,
    transport: zigai.mcp.Transport,
    source: transcripts.Source,
    transport_kind: transcripts.TransportKind,
    output_path: []const u8,
) !void {
    var recorder = transcripts.RecordingTransport.init(init.gpa, transport, source, transport_kind);
    defer recorder.deinit();
    var client = zigai.mcp.Client{
        .transport = recorder.transport(),
        .name = "zigai-interop",
        .version = "0.1.0",
    };
    const discover = try client.discover(init.gpa);
    init.gpa.free(discover);
    const tools = try client.listTools(init.gpa, null);
    init.gpa.free(tools);
    const resources = try client.listResources(init.gpa, null);
    init.gpa.free(resources);
    const prompts = try client.listPrompts(init.gpa, null);
    init.gpa.free(prompts);
    try recorder.writeTranscriptAtomic(init.gpa, init.io, .cwd(), output_path);
}
