//! Thin executable adapter for the official MCP client conformance runner.

const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const scenario = init.environ_map.get("MCP_CONFORMANCE_SCENARIO") orelse return error.MissingScenario;
    var http = zigai.transport.HttpTransport.initWithOptions(init.gpa, init.io, .{
        .url_policy = .{ .allow_http = true, .allow_local_network = true },
    });
    defer http.deinit();
    var streamable = zigai.mcp.StreamableHttpTransport.initWithPolicy(
        init.io,
        http.transport(),
        args[1],
        .{ .allow_http = true, .allow_local_network = true },
    );
    var client = zigai.mcp.Client{
        .transport = streamable.transport(),
        .name = "zigai-conformance",
        .version = "0.1.0",
    };

    if (std.mem.eql(u8, scenario, "tools_call")) {
        const tools = try client.listTools(init.gpa, null);
        defer init.gpa.free(tools);
        const name = try firstToolName(init.gpa, tools);
        defer init.gpa.free(name);
        const result = try client.callTool(init.gpa, name, "{\"a\":2,\"b\":3}");
        init.gpa.free(result);
        return;
    }
    if (std.mem.eql(u8, scenario, "json-schema-ref-no-deref")) {
        const tools = try client.listTools(init.gpa, null);
        init.gpa.free(tools);
        return;
    }
    return error.UnsupportedConformanceScenario;
}

fn firstToolName(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidConformanceResponse,
    };
    const tools = switch (object.get("tools") orelse return error.InvalidConformanceResponse) {
        .array => |value| value,
        else => return error.InvalidConformanceResponse,
    };
    if (tools.items.len == 0) return error.InvalidConformanceResponse;
    const tool = switch (tools.items[0]) {
        .object => |value| value,
        else => return error.InvalidConformanceResponse,
    };
    const name = switch (tool.get("name") orelse return error.InvalidConformanceResponse) {
        .string => |value| value,
        else => return error.InvalidConformanceResponse,
    };
    return allocator.dupe(u8, name);
}

test "official conformance adapter extracts the first listed tool" {
    const name = try firstToolName(std.testing.allocator, "{\"tools\":[{\"name\":\"add_numbers\"}]}");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("add_numbers", name);
    try std.testing.expectError(error.InvalidConformanceResponse, firstToolName(std.testing.allocator, "{\"tools\":[]}"));
}
