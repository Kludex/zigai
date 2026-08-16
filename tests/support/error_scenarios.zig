const std = @import("std");
const zigai = @import("zigai");
const cassettes = @import("cassettes.zig");

pub const prompt = "Reply with exactly: pong";

const Capture = struct {
    provider: []const u8,
    provider_errors: usize = 0,
    retry_hooks: usize = 0,
    valid: bool = true,

    fn observer(self: *Capture) zigai.ProviderErrorObserver {
        return .{ .context = self, .observeFn = observe };
    }

    fn retryHook(self: *Capture) zigai.agent.RetryHook {
        return .{ .context = self, .waitFn = beforeRetry };
    }

    fn observe(context: *anyopaque, value: zigai.ProviderError) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.provider_errors += 1;
        self.valid = self.valid and std.mem.eql(u8, value.provider, self.provider);
        switch (value.status) {
            429 => self.valid = self.valid and value.retry_after_seconds == 3 and
                value.rate_limit_remaining_requests == 0 and
                value.rate_limit_remaining_tokens == 12 and value.request_id != null,
            503 => self.valid = self.valid and value.request_id != null,
            400 => self.valid = self.valid and value.body.len == 24 and value.body_truncated and
                value.message.len == 16 and value.code != null and value.code.?.len == 8 and
                value.request_id != null,
            else => self.valid = false,
        }
    }

    fn beforeRetry(context: *anyopaque, event: zigai.agent.RetryEvent) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.retry_hooks += 1;
        if (event.retry_number != 1 or event.model_requests == 0 or event.delay_ms != 0 or
            event.total_delay_ms != 0 or event.provider_request_id == null)
        {
            self.valid = false;
        }
        if (event.failure == error.ProviderRateLimited) {
            self.valid = self.valid and event.retry_after_seconds == 3 and
                event.rate_limit_remaining_requests == 0 and event.rate_limit_remaining_tokens == 12;
        } else if (event.failure != error.ProviderServerError) {
            self.valid = false;
        }
    }
};

pub fn replay(
    model: zigai.Model,
    cassette: *cassettes.ReplayTransport,
    provider: []const u8,
) !void {
    var capture = Capture{ .provider = provider };
    var recovered = try (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 64 },
        .retry_policy = .{
            .max_retries = 1,
            .before_retry = capture.retryHook(),
        },
        .provider_error_observer = capture.observer(),
    }).run(std.testing.allocator, prompt);
    defer recovered.deinit();
    try std.testing.expectEqualStrings("pong", recovered.output);
    try std.testing.expectEqual(@as(usize, 2), recovered.model_requests);

    try std.testing.expectError(error.ProviderServerError, (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 64 },
        .retry_policy = .{
            .max_retries = 1,
            .before_retry = capture.retryHook(),
        },
        .provider_error_observer = capture.observer(),
    }).run(std.testing.allocator, prompt));

    try std.testing.expectError(error.ProviderResponseDecodeError, (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 64 },
        .retry_policy = .{ .max_retries = 0 },
        .provider_error_observer = capture.observer(),
    }).run(std.testing.allocator, prompt));

    try std.testing.expectError(error.ProviderRequestFailed, (zigai.Agent{
        .model = model,
        .model_settings = .{ .max_tokens = 64 },
        .retry_policy = .{ .max_retries = 0 },
        .provider_error_observer = capture.observer(),
        .provider_error_policy = .{
            .capture_body = true,
            .max_body_bytes = 24,
            .max_message_bytes = 16,
            .max_code_bytes = 8,
        },
    }).run(std.testing.allocator, prompt));

    try std.testing.expectEqual(@as(usize, 4), capture.provider_errors);
    try std.testing.expectEqual(@as(usize, 2), capture.retry_hooks);
    try std.testing.expect(capture.valid);
    try std.testing.expectEqual(@as(usize, 0), cassette.remaining());
}
