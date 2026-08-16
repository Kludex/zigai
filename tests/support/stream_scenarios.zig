const std = @import("std");
const zigai = @import("zigai");

pub const text_prompt = "Reply with exactly: pong";
pub const tool_prompt = "Call the weather tool exactly once with city Madrid. After the tool result, reply with exactly: 31 C.";
pub const tool_system_prompt = "Always call the weather tool before answering.";

pub fn weatherTool(calls: *u8) zigai.Tool {
    return .{
        .definition = .{
            .name = "weather",
            .description = "Get the current weather for a city.",
            .parameters_json_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
        },
        .context = calls,
        .executeFn = struct {
            fn execute(context: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
                const count: *u8 = @ptrCast(@alignCast(context));
                count.* += 1;
                const parsed = try std.json.parseFromSliceLeaky(
                    struct { city: []const u8 },
                    allocator,
                    arguments,
                    .{ .ignore_unknown_fields = false },
                );
                if (!std.mem.eql(u8, parsed.city, "Madrid")) return error.UnexpectedCity;
                return allocator.dupe(u8, "{\"temperature_c\":31,\"condition\":\"sunny\"}");
            }
        }.execute,
    };
}

pub const Capture = struct {
    text_deltas: usize = 0,
    tool_argument_deltas: usize = 0,
    completed_tool_calls: usize = 0,
    tool_results: usize = 0,
    usage_events: usize = 0,
    final_results: usize = 0,

    pub fn sink(self: *Capture) zigai.AgentStreamSink {
        return .{ .context = self, .eventFn = event };
    }

    fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        switch (value) {
            .model => |model_event| switch (model_event) {
                .part_delta => |part_event| switch (part_event.delta) {
                    .text => self.text_deltas += 1,
                    .tool_call => self.tool_argument_deltas += 1,
                    else => {},
                },
                .part_end => |part_event| switch (part_event.part) {
                    .tool_call => self.completed_tool_calls += 1,
                    else => {},
                },
                .part_start => {},
                .usage => self.usage_events += 1,
            },
            .function_tool_result => self.tool_results += 1,
            .final_result => self.final_results += 1,
            else => {},
        }
    }

    pub fn validateText(self: Capture, output: []const u8, usage: zigai.RunUsage) !void {
        if (!std.mem.eql(u8, output, "pong")) return error.UnexpectedStreamOutput;
        if (usage.totalTokens() == 0) return error.MissingStreamUsage;
        if (self.text_deltas == 0) return error.MissingTextDelta;
        if (self.completed_tool_calls != 0 or self.tool_results != 0)
            return error.UnexpectedToolEvent;
        if (self.usage_events == 0) return error.MissingUsageEvent;
        if (self.final_results != 1) return error.UnexpectedFinalResultCount;
    }

    pub fn validateTool(
        self: Capture,
        output: []const u8,
        usage: zigai.RunUsage,
        tool_calls: u8,
    ) !void {
        if (std.mem.indexOf(u8, output, "31") == null) return error.UnexpectedStreamOutput;
        if (usage.totalTokens() == 0) return error.MissingStreamUsage;
        if (tool_calls != 1) return error.UnexpectedToolExecutionCount;
        if (self.text_deltas == 0) return error.MissingTextDelta;
        if (self.completed_tool_calls != 1) return error.UnexpectedToolCallCount;
        if (self.tool_results != 1) return error.UnexpectedToolResultCount;
        if (self.usage_events == 0) return error.MissingUsageEvent;
        if (self.final_results != 1) return error.UnexpectedFinalResultCount;
    }
};

test "stream capture rejects incomplete text and tool event sequences" {
    const usage = zigai.RunUsage{ .input_tokens = 1, .output_tokens = 1 };
    var text: Capture = .{
        .text_deltas = 1,
        .usage_events = 1,
        .final_results = 1,
    };
    try text.validateText("pong", usage);
    text.tool_results = 1;
    try std.testing.expectError(error.UnexpectedToolEvent, text.validateText("pong", usage));

    const tool: Capture = .{
        .text_deltas = 1,
        .completed_tool_calls = 1,
        .tool_results = 1,
        .usage_events = 2,
        .final_results = 1,
    };
    try tool.validateTool("31 C.", usage, 1);
    try std.testing.expectError(error.UnexpectedToolExecutionCount, tool.validateTool("31 C.", usage, 0));
}
