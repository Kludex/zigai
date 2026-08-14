//! Application-controlled selection of a concrete model for each request.

const std = @import("std");
const model_types = @import("../model.zig");

pub const Context = struct {
    request: model_types.ModelRequest,
    streaming: bool,
};

/// Routes each request to the model returned by `selectFn`.
pub const Selector = struct {
    context: *anyopaque,
    profile: model_types.ModelProfile,
    settings: model_types.ModelSettings = .{},
    selectFn: *const fn (context: *anyopaque, run: Context) anyerror!model_types.Model,

    pub fn model(self: *Selector) model_types.Model {
        return .{
            .context = self,
            .profile = self.profile,
            .settings = self.settings,
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const self: *Selector = @ptrCast(@alignCast(context));
        const selected = try self.selectFn(self.context, .{ .request = request_value, .streaming = false });
        var selected_request = request_value;
        selected_request.settings = selected.settings.overrideWith(request_value.settings);
        return selected.request(allocator, selected_request);
    }

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Selector = @ptrCast(@alignCast(context));
        const selected = try self.selectFn(self.context, .{ .request = request_value, .streaming = true });
        var selected_request = request_value;
        selected_request.settings = selected.settings.overrideWith(request_value.settings);
        return selected.stream(allocator, selected_request, sink);
    }
};

test "selector routes requests with application context" {
    const Selected = struct {
        calls: usize = 0,
        fn request(context: *anyopaque, _: std.mem.Allocator, request_value: model_types.ModelRequest) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(?u64, 50), request_value.settings.max_tokens);
            return .{ .parts = &.{.{ .text = "selected" }} };
        }
    };
    const Route = struct {
        model_value: model_types.Model,
        calls: usize = 0,
        fn select(context: *anyopaque, run: Context) !model_types.Model {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(!run.streaming);
            try std.testing.expectEqualStrings("route me", run.request.messages[0].request.parts[0].user_prompt.text);
            self.calls += 1;
            return self.model_value;
        }
    };
    var selected: Selected = .{};
    const selected_model = model_types.Model{
        .context = &selected,
        .profile = .{},
        .settings = .{ .max_tokens = 20 },
        .requestFn = Selected.request,
    };
    var route = Route{ .model_value = selected_model };
    var selector = Selector{
        .context = &route,
        .profile = .{},
        .selectFn = Route.select,
    };
    const response = try selector.model().request(std.testing.allocator, .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "route me" } }} } }},
        .settings = .{ .max_tokens = 50 },
    });
    try std.testing.expectEqualStrings("selected", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), route.calls);
    try std.testing.expectEqual(@as(usize, 1), selected.calls);
}

test "selector routes streaming requests and merges settings" {
    const Selected = struct {
        calls: usize = 0,
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.Unused;
        }
        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: model_types.ModelRequest,
            sink: model_types.ModelStreamSink,
        ) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(?f64, 0.4), request_value.settings.temperature);
            try std.testing.expectEqual(@as(?u64, 80), request_value.settings.max_tokens);
            try sink.emit(.{ .text_delta = "selected" });
            return .{ .parts = &.{.{ .text = "selected" }} };
        }
    };
    const Route = struct {
        model_value: model_types.Model,
        calls: usize = 0,
        fn select(context: *anyopaque, run: Context) !model_types.Model {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(run.streaming);
            self.calls += 1;
            return self.model_value;
        }
    };
    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("selected", event.text_delta);
            self.events += 1;
        }
    };
    var selected: Selected = .{};
    var route = Route{ .model_value = .{
        .context = &selected,
        .profile = .{ .supports_streaming = true },
        .settings = .{ .temperature = 0.4, .max_tokens = 20 },
        .requestFn = Selected.request,
        .streamFn = Selected.stream,
    } };
    var selector = Selector{ .context = &route, .profile = .{ .supports_streaming = true }, .selectFn = Route.select };
    var sink: Sink = .{};
    const response = try selector.model().stream(
        std.testing.allocator,
        .{ .messages = &.{}, .settings = .{ .max_tokens = 80 } },
        .{ .context = &sink, .eventFn = Sink.emit },
    );
    try std.testing.expectEqualStrings("selected", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), route.calls);
    try std.testing.expectEqual(@as(usize, 1), selected.calls);
    try std.testing.expectEqual(@as(usize, 1), sink.events);
    try std.testing.expectError(error.Unused, route.model_value.request(std.testing.allocator, .{ .messages = &.{} }));
}
