const std = @import("std");
const zigai = @import("zigai");

pub const structured_prompt = "Return a JSON object whose value field is the integer 42.";
pub const thinking_prompt = "Calculate 982451653 multiplied by 57885161 privately. After calculating, reply with exactly: done";
pub const thinking_answer = "done";

pub const StructuredAnswer = struct {
    value: i64,
};

pub fn runStructured(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    model: zigai.Model,
) !void {
    var result = try (zigai.Agent{
        .model = model,
        .io = io,
        .model_settings = .{ .max_tokens = 256 },
        .limits = .{ .max_model_requests = 2 },
    }).runTyped(StructuredAnswer, allocator, structured_prompt);
    defer result.deinit();
    if (result.output.value != 42) return error.UnexpectedStructuredOutput;
    if (result.usage.totalTokens() == 0) return error.MissingStructuredUsage;
}

pub const ThinkingCapture = struct {
    starts: usize = 0,
    deltas: usize = 0,
    ends: usize = 0,
    signed_ends: usize = 0,
    usage_events: usize = 0,
    final_results: usize = 0,

    pub fn sink(self: *ThinkingCapture) zigai.AgentStreamSink {
        return .{ .context = self, .eventFn = event };
    }

    fn event(context: *anyopaque, value: zigai.AgentStreamEvent) !void {
        const self: *ThinkingCapture = @ptrCast(@alignCast(context));
        switch (value) {
            .model => |model_event| switch (model_event) {
                .part_start => |part_event| switch (part_event.part) {
                    .thinking => self.starts += 1,
                    else => {},
                },
                .part_delta => |part_event| switch (part_event.delta) {
                    .thinking => self.deltas += 1,
                    else => {},
                },
                .part_end => |part_event| switch (part_event.part) {
                    .thinking => |thinking| {
                        self.ends += 1;
                        if (thinking.signature != null) self.signed_ends += 1;
                    },
                    else => {},
                },
                .usage => self.usage_events += 1,
            },
            .final_result => self.final_results += 1,
            else => {},
        }
    }

    fn validate(self: ThinkingCapture, require_thinking_parts: bool) !void {
        if (self.usage_events == 0) return error.MissingThinkingUsageEvent;
        if (self.final_results != 1) return error.UnexpectedThinkingFinalResultCount;
        if (require_thinking_parts) {
            if (self.starts == 0 or self.deltas == 0 or self.ends == 0) return error.MissingThinkingPart;
            if (self.signed_ends == 0) return error.MissingThinkingSignature;
        } else if (self.starts != 0 or self.deltas != 0 or self.ends != 0) {
            return error.UnexpectedThinkingPart;
        }
    }
};

pub fn runThinking(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    model: zigai.Model,
    require_thinking_parts: bool,
) !void {
    var capture: ThinkingCapture = .{};
    var result = try (zigai.Agent{
        .model = model,
        .io = io,
        .model_settings = .{ .max_tokens = 2048, .reasoning_effort = .high },
        .limits = .{ .max_model_requests = 2 },
    }).runStream(allocator, thinking_prompt, capture.sink());
    defer result.deinit();
    if (!std.mem.eql(u8, std.mem.trim(u8, result.output, " \t\r\n"), thinking_answer))
        return error.UnexpectedThinkingOutput;
    if (result.usage.reasoning_tokens == 0) return error.MissingReasoningUsage;
    try capture.validate(require_thinking_parts);

    var thinking_parts: usize = 0;
    for (result.messages) |message| switch (message) {
        .response => |response| for (response.parts) |part| switch (part) {
            .thinking => thinking_parts += 1,
            else => {},
        },
        .request => {},
    };
    if ((thinking_parts > 0) != require_thinking_parts) return error.UnexpectedThinkingHistory;
}
