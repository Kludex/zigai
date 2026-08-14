//! Test doubles that exercise the same public Model interface as live clients.

const std = @import("std");
const model_types = @import("model.zig");

pub const ScriptedModel = struct {
    responses: []const model_types.ModelResponse,
    next_response: usize = 0,
    request_count: usize = 0,
    inspectFn: ?*const fn (request_index: usize, request: model_types.ModelRequest) anyerror!void = null,
    profile: model_types.ModelProfile = .{},
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,

    pub fn model(self: *ScriptedModel) model_types.Model {
        return .{
            .context = self,
            .profile = self.profile,
            .provider_name = self.provider_name,
            .model_name = self.model_name,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(context: *anyopaque, _: std.mem.Allocator, value: model_types.ModelRequest) !model_types.ModelResponse {
        const self: *ScriptedModel = @ptrCast(@alignCast(context));
        const current = self.request_count;
        self.request_count += 1;
        if (self.inspectFn) |inspect| try inspect(current, value);
        if (self.next_response >= self.responses.len) return error.ScriptExhausted;
        const response = self.responses[self.next_response];
        self.next_response += 1;
        return response;
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, value: model_types.ModelRequest, sink: model_types.ModelStreamSink) !model_types.ModelResponse {
        const response = try request(context, allocator, value);
        for (response.parts) |part| switch (part) {
            .text => |text| try sink.emit(.{ .text_delta = text }),
            .tool_call => |call| try sink.emit(.{ .tool_call = call }),
            else => {},
        };
        try sink.emit(.{ .usage = response.usage });
        return response;
    }
};

test "scripted model reports exhaustion" {
    var scripted = ScriptedModel{ .responses = &.{} };
    try std.testing.expectError(error.ScriptExhausted, scripted.model().request(std.testing.allocator, .{ .messages = &.{} }));
    try std.testing.expectEqual(@as(usize, 1), scripted.request_count);
}
