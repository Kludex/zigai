//! Ordered fallback over provider-neutral models.

const std = @import("std");
const model_types = @import("../model.zig");

pub const Event = struct {
    failed_index: usize,
    next_index: usize,
    failure: anyerror,
};

/// Tries models in order when a request fails with a fallback-safe error.
pub const Fallback = struct {
    models: []const model_types.Model,
    context: ?*anyopaque = null,
    shouldFallbackFn: ?*const fn (context: ?*anyopaque, failure: anyerror) bool = null,
    onFallbackFn: ?*const fn (context: ?*anyopaque, event: Event) anyerror!void = null,

    pub fn model(self: *Fallback) model_types.Model {
        return .{
            .context = self,
            .profile = commonProfile(self.models),
            .requestFn = request,
            .streamFn = stream,
        };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const self: *Fallback = @ptrCast(@alignCast(context));
        if (self.models.len == 0) return error.NoFallbackModels;
        for (self.models, 0..) |candidate, index| {
            var candidate_request = request_value;
            candidate_request.settings = candidate.settings.overrideWith(request_value.settings);
            return candidate.request(allocator, candidate_request) catch |failure| {
                if (index + 1 == self.models.len or !self.shouldFallback(failure)) return failure;
                try self.notify(.{ .failed_index = index, .next_index = index + 1, .failure = failure });
                continue;
            };
        }
        unreachable;
    }

    fn stream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: model_types.ModelRequest,
        sink: model_types.ModelStreamSink,
    ) !model_types.ModelResponse {
        const self: *Fallback = @ptrCast(@alignCast(context));
        if (self.models.len == 0) return error.NoFallbackModels;
        for (self.models, 0..) |candidate, index| {
            var emitted = false;
            var forwarding = ForwardingSink{ .sink = sink, .emitted = &emitted };
            var candidate_request = request_value;
            candidate_request.settings = candidate.settings.overrideWith(request_value.settings);
            return candidate.stream(allocator, candidate_request, forwarding.sinkValue()) catch |failure| {
                if (emitted or index + 1 == self.models.len or !self.shouldFallback(failure)) return failure;
                try self.notify(.{ .failed_index = index, .next_index = index + 1, .failure = failure });
                continue;
            };
        }
        unreachable;
    }

    fn shouldFallback(self: Fallback, failure: anyerror) bool {
        if (self.shouldFallbackFn) |classify| return classify(self.context, failure);
        return switch (failure) {
            error.ProviderRateLimited,
            error.ProviderServerError,
            error.ProviderRequestFailed,
            error.RequestTimedOut,
            error.InvalidProviderResponse,
            => true,
            else => false,
        };
    }

    fn notify(self: Fallback, event: Event) !void {
        const callback = self.onFallbackFn orelse return;
        return callback(self.context, event);
    }
};

const ForwardingSink = struct {
    sink: model_types.ModelStreamSink,
    emitted: *bool,

    fn sinkValue(self: *ForwardingSink) model_types.ModelStreamSink {
        return .{ .context = self, .eventFn = emit };
    }

    fn emit(context: *anyopaque, event: model_types.ModelStreamEvent) !void {
        const self: *ForwardingSink = @ptrCast(@alignCast(context));
        try self.sink.emit(event);
        self.emitted.* = true;
    }
};

fn commonProfile(models: []const model_types.Model) model_types.ModelProfile {
    if (models.len == 0) return .{
        .supports_tools = false,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = false,
        .supports_max_tokens = false,
    };
    var profile = models[0].profile;
    for (models[1..]) |candidate| {
        const other = candidate.profile;
        profile.supports_tools = profile.supports_tools and other.supports_tools;
        profile.supports_parallel_tool_calls = profile.supports_parallel_tool_calls and other.supports_parallel_tool_calls;
        profile.supports_json_schema_output = profile.supports_json_schema_output and other.supports_json_schema_output;
        profile.supports_json_object_output = profile.supports_json_object_output and other.supports_json_object_output;
        profile.supports_system_messages = profile.supports_system_messages and other.supports_system_messages;
        profile.supports_thinking = profile.supports_thinking and other.supports_thinking;
        profile.supports_streaming = profile.supports_streaming and other.supports_streaming;
        profile.supports_temperature = profile.supports_temperature and other.supports_temperature;
        profile.supports_max_tokens = profile.supports_max_tokens and other.supports_max_tokens;
        profile.supports_stop_sequences = profile.supports_stop_sequences and other.supports_stop_sequences;
        profile.supports_seed = profile.supports_seed and other.supports_seed;
        profile.reasoning_efforts.setIntersection(other.reasoning_efforts);
        profile.builtin_tools.setIntersection(other.builtin_tools);
        profile.content_types.setIntersection(other.content_types);
    }
    return profile;
}

test "fallback tries the next model and preserves candidate settings" {
    const State = struct {
        calls: usize = 0,
        fn fail(context: *anyopaque, _: std.mem.Allocator, request_value: model_types.ModelRequest) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(?f64, 0.3), request_value.settings.temperature);
            return error.ProviderServerError;
        }
        fn succeed(context: *anyopaque, _: std.mem.Allocator, request_value: model_types.ModelRequest) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqual(@as(?u64, 200), request_value.settings.max_tokens);
            return .{ .parts = &.{.{ .text = "ok" }} };
        }
    };
    const Capture = struct {
        calls: usize = 0,
        fn fallback(context: ?*anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(usize, 0), event.failed_index);
            try std.testing.expectEqual(error.ProviderServerError, event.failure);
            self.calls += 1;
        }
    };
    var first_state: State = .{};
    var second_state: State = .{};
    var capture: Capture = .{};
    const candidates = [_]model_types.Model{
        .{
            .context = &first_state,
            .profile = .{},
            .settings = .{ .temperature = 0.3 },
            .requestFn = State.fail,
        },
        .{
            .context = &second_state,
            .profile = .{},
            .settings = .{ .max_tokens = 100 },
            .requestFn = State.succeed,
        },
    };
    var fallback = Fallback{
        .models = &candidates,
        .context = &capture,
        .onFallbackFn = Capture.fallback,
    };
    const response = try fallback.model().request(std.testing.allocator, .{
        .messages = &.{},
        .settings = .{ .max_tokens = 200 },
    });
    try std.testing.expectEqualStrings("ok", response.parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), first_state.calls);
    try std.testing.expectEqual(@as(usize, 1), second_state.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "fallback does not retry unsafe failures" {
    const Failing = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.InvalidRequestEncoding; // kcov-ignore
        }
    };
    var unused: u8 = 0;
    const candidates = [_]model_types.Model{
        .{ .context = &unused, .profile = .{}, .requestFn = Failing.request },
        .{ .context = &unused, .profile = .{}, .requestFn = Failing.request },
    };
    var fallback = Fallback{ .models = &candidates };
    try std.testing.expectError(
        error.InvalidRequestEncoding,
        fallback.model().request(std.testing.allocator, .{ .messages = &.{} }),
    );
}

test "fallback profile intersects builtin tools" {
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return .{ .parts = &.{.{ .text = "unused" }} };
        }
    };
    var unused: u8 = 0;
    const candidates = [_]model_types.Model{
        .{ .context = &unused, .profile = .{
            .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .web_fetch }),
            .content_types = model_types.ModelProfile.ContentTypeSet.initMany(&.{ .image, .audio }),
        }, .requestFn = Stub.request },
        .{ .context = &unused, .profile = .{
            .builtin_tools = model_types.ModelProfile.BuiltinToolSet.initMany(&.{.web_search}),
            .content_types = model_types.ModelProfile.ContentTypeSet.initMany(&.{.image}),
        }, .requestFn = Stub.request },
    };
    var fallback = Fallback{ .models = &candidates };
    const profile = fallback.model().profile;
    try std.testing.expect(profile.supportsBuiltinTool(.web_search));
    try std.testing.expect(!profile.supportsBuiltinTool(.web_fetch));
    try std.testing.expect(profile.supportsContentType(.image));
    try std.testing.expect(!profile.supportsContentType(.audio));
    const response = try fallback.model().request(std.testing.allocator, .{ .messages = &.{} });
    try std.testing.expectEqualStrings("unused", response.parts[0].text);
}

test "stream fallback stops after exposing output" {
    const State = struct {
        calls: usize = 0,
        emit_before_failure: bool,
        succeeds: bool = false,
        fn request(_: *anyopaque, _: std.mem.Allocator, _: model_types.ModelRequest) !model_types.ModelResponse {
            return error.Unused; // kcov-ignore
        }
        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: model_types.ModelRequest,
            sink: model_types.ModelStreamSink,
        ) !model_types.ModelResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.succeeds) return .{ .parts = &.{.{ .text = "recovered" }} };
            if (self.emit_before_failure) try sink.emit(.{ .text_delta = "visible" });
            return error.ProviderServerError;
        }
    };
    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, _: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
    };
    var first = State{ .emit_before_failure = true };
    var second = State{ .emit_before_failure = false };
    const candidates = [_]model_types.Model{
        .{ .context = &first, .profile = .{ .supports_streaming = true }, .requestFn = State.request, .streamFn = State.stream },
        .{ .context = &second, .profile = .{ .supports_streaming = true }, .requestFn = State.request, .streamFn = State.stream },
    };
    var fallback = Fallback{ .models = &candidates };
    var sink_state: Sink = .{};
    try std.testing.expectError(error.ProviderServerError, fallback.model().stream(
        std.testing.allocator,
        .{ .messages = &.{} },
        .{ .context = &sink_state, .eventFn = Sink.emit },
    ));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 0), second.calls);
    try std.testing.expectEqual(@as(usize, 1), sink_state.events);

    var retry_first = State{ .emit_before_failure = false };
    var retry_second = State{ .emit_before_failure = false, .succeeds = true };
    const retry_candidates = [_]model_types.Model{
        .{ .context = &retry_first, .profile = .{ .supports_streaming = true }, .requestFn = State.request, .streamFn = State.stream },
        .{ .context = &retry_second, .profile = .{ .supports_streaming = true }, .requestFn = State.request, .streamFn = State.stream },
    };
    var retrying = Fallback{ .models = &retry_candidates };
    const recovered = try retrying.model().stream(
        std.testing.allocator,
        .{ .messages = &.{} },
        .{ .context = &sink_state, .eventFn = Sink.emit },
    );
    try std.testing.expectEqualStrings("recovered", recovered.parts[0].text);
    try std.testing.expectEqual(@as(usize, 1), retry_first.calls);
    try std.testing.expectEqual(@as(usize, 1), retry_second.calls);
    try std.testing.expectError(error.Unused, retry_candidates[0].request(std.testing.allocator, .{ .messages = &.{} }));
}
