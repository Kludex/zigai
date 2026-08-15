//! Provider-neutral model settings and explicit provider extension points.
//!
//! Settings borrow all slices. Callers must keep referenced strings alive for
//! the model request; agent results never retain settings.

const std = @import("std");

/// Portable reasoning-effort levels; profiles advertise their exact subset.
pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

/// Portable synchronous inference tiers; profiles advertise their exact subset.
pub const ServiceTier = enum {
    auto,
    default,
    flex,
    priority,
};

/// Provider-managed input truncation policy.
pub const Truncation = enum {
    auto,
    disabled,
};

/// Requests token log probabilities and up to `top` alternatives per token.
pub const Logprobs = struct {
    top: u8 = 0,
};

/// Controls which local function tools the model may call.
pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    tool: []const u8,
    allowed: []const []const u8,
};

/// One request-scoped HTTP header. Sensitive values are redacted by transports.
pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,
};

/// Provider adapter expected to consume an extension body.
pub const ExtraBodyKind = enum {
    openai,
    xai,
    openai_compatible,
    anthropic,
    bedrock,
    google,
    mistral,
    cohere,
    openrouter,
    snowflake,
    zai,
};

/// A bounded JSON object for fields unavailable in the portable settings API.
/// The tag prevents provider-specific configuration from reaching the wrong
/// adapter after model selection or fallback.
pub const ProviderExtraBody = union(ExtraBodyKind) {
    openai: []const u8,
    xai: []const u8,
    openai_compatible: []const u8,
    anthropic: []const u8,
    bedrock: []const u8,
    google: []const u8,
    mistral: []const u8,
    cohere: []const u8,
    openrouter: []const u8,
    snowflake: []const u8,
    zai: []const u8,

    pub fn kind(self: ProviderExtraBody) ExtraBodyKind {
        return std.meta.activeTag(self);
    }

    pub fn json(self: ProviderExtraBody) []const u8 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

/// Provider-neutral generation controls. Null fields inherit from a
/// lower-precedence layer. Slices are borrowed for the duration of a request.
pub const ModelSettings = struct {
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?i64 = null,
    reasoning_effort: ?ReasoningEffort = null,
    top_p: ?f64 = null,
    top_k: ?u32 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    logprobs: ?Logprobs = null,
    tool_choice: ?ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    thinking_budget_tokens: ?u64 = null,
    service_tier: ?ServiceTier = null,
    truncation: ?Truncation = null,
    extra_headers: ?[]const RequestHeader = null,
    extra_body: ?ProviderExtraBody = null,

    /// Applies each non-null field from `overrides` to `self`.
    pub fn overrideWith(self: ModelSettings, overrides: ModelSettings) ModelSettings {
        return .{
            .temperature = overrides.temperature orelse self.temperature,
            .max_tokens = overrides.max_tokens orelse self.max_tokens,
            .stop_sequences = overrides.stop_sequences orelse self.stop_sequences,
            .seed = overrides.seed orelse self.seed,
            .reasoning_effort = overrides.reasoning_effort orelse self.reasoning_effort,
            .top_p = overrides.top_p orelse self.top_p,
            .top_k = overrides.top_k orelse self.top_k,
            .presence_penalty = overrides.presence_penalty orelse self.presence_penalty,
            .frequency_penalty = overrides.frequency_penalty orelse self.frequency_penalty,
            .logprobs = overrides.logprobs orelse self.logprobs,
            .tool_choice = overrides.tool_choice orelse self.tool_choice,
            .parallel_tool_calls = overrides.parallel_tool_calls orelse self.parallel_tool_calls,
            .thinking_budget_tokens = overrides.thinking_budget_tokens orelse self.thinking_budget_tokens,
            .service_tier = overrides.service_tier orelse self.service_tier,
            .truncation = overrides.truncation orelse self.truncation,
            .extra_headers = overrides.extra_headers orelse self.extra_headers,
            .extra_body = overrides.extra_body orelse self.extra_body,
        };
    }

    /// Validates portable value invariants without applying provider policy.
    pub fn validate(self: ModelSettings) error{InvalidModelSettings}!void {
        if (self.temperature) |value| if (!std.math.isFinite(value)) return error.InvalidModelSettings;
        if (self.top_p) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidModelSettings;
        }
        if (self.top_k) |value| if (value == 0) return error.InvalidModelSettings;
        if (self.presence_penalty) |value| if (!std.math.isFinite(value)) return error.InvalidModelSettings;
        if (self.frequency_penalty) |value| if (!std.math.isFinite(value)) return error.InvalidModelSettings;
        if (self.logprobs) |value| if (value.top > 20) return error.InvalidModelSettings;
        if (self.thinking_budget_tokens) |value| if (value == 0) return error.InvalidModelSettings;
        if (self.reasoning_effort != null and self.thinking_budget_tokens != null) return error.InvalidModelSettings;
        if (self.tool_choice) |choice| switch (choice) {
            .tool => |name| if (name.len == 0) return error.InvalidModelSettings,
            .allowed => |names| {
                if (names.len == 0) return error.InvalidModelSettings;
                for (names) |name| if (name.len == 0) return error.InvalidModelSettings;
            },
            else => {},
        };
        if (self.extra_headers) |headers| for (headers) |header| {
            if (!validHeaderName(header.name) or !validHeaderValue(header.value)) return error.InvalidModelSettings;
        };
    }
};

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!isTokenCharacter(byte)) return false;
    return true;
}

fn isTokenCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| if (byte == '\r' or byte == '\n' or byte == 0) return false;
    return true;
}

test "settings merge every field without retaining storage" {
    const headers = [_]RequestHeader{.{ .name = "x-feature", .value = "on" }};
    const base = ModelSettings{
        .temperature = 0.1,
        .max_tokens = 100,
        .stop_sequences = &.{"base"},
        .seed = 1,
        .reasoning_effort = .low,
        .top_p = 0.8,
        .top_k = 20,
        .presence_penalty = 0.2,
        .frequency_penalty = 0.3,
        .logprobs = .{ .top = 2 },
        .tool_choice = .auto,
        .parallel_tool_calls = true,
        .service_tier = .default,
        .truncation = .disabled,
        .extra_headers = &headers,
        .extra_body = .{ .openai = "{\"store\":false}" },
    };
    const merged = base.overrideWith(.{
        .temperature = 0.9,
        .tool_choice = .{ .tool = "search" },
        .service_tier = .priority,
    });
    try base.validate();
    try std.testing.expectEqual(@as(?f64, 0.9), merged.temperature);
    try std.testing.expectEqual(@as(?u64, 100), merged.max_tokens);
    try std.testing.expectEqualStrings("base", merged.stop_sequences.?[0]);
    try std.testing.expectEqual(@as(?i64, 1), merged.seed);
    try std.testing.expectEqual(ReasoningEffort.low, merged.reasoning_effort.?);
    try std.testing.expectEqual(@as(?f64, 0.8), merged.top_p);
    try std.testing.expectEqual(@as(?u32, 20), merged.top_k);
    try std.testing.expectEqual(@as(?f64, 0.2), merged.presence_penalty);
    try std.testing.expectEqual(@as(?f64, 0.3), merged.frequency_penalty);
    try std.testing.expectEqual(@as(u8, 2), merged.logprobs.?.top);
    try std.testing.expectEqualStrings("search", merged.tool_choice.?.tool);
    try std.testing.expect(merged.parallel_tool_calls.?);
    try std.testing.expectEqual(@as(?u64, null), merged.thinking_budget_tokens);
    try std.testing.expectEqual(ServiceTier.priority, merged.service_tier.?);
    try std.testing.expectEqual(Truncation.disabled, merged.truncation.?);
    try std.testing.expectEqualStrings("x-feature", merged.extra_headers.?[0].name);
    try std.testing.expectEqual(ExtraBodyKind.openai, merged.extra_body.?.kind());
    try std.testing.expectEqualStrings("{\"store\":false}", merged.extra_body.?.json());
    try (ModelSettings{ .thinking_budget_tokens = 1_024 }).validate();
}

test "settings reject invalid portable values" {
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .temperature = std.math.nan(f64) }).validate(),
    );
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .top_p = 1.1 }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .top_p = -0.1 }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .top_k = 0 }).validate());
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .presence_penalty = std.math.inf(f64) }).validate(),
    );
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .frequency_penalty = -std.math.inf(f64) }).validate(),
    );
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .thinking_budget_tokens = 0 }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .logprobs = .{ .top = 21 } }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{
        .reasoning_effort = .high,
        .thinking_budget_tokens = 1_024,
    }).validate());
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .tool_choice = .{ .tool = "" } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .tool_choice = .{ .allowed = &.{} } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidModelSettings,
        (ModelSettings{ .tool_choice = .{ .allowed = &.{""} } }).validate(),
    );
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .extra_headers = &.{.{
        .name = "",
        .value = "ok",
    }} }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .extra_headers = &.{.{
        .name = "bad header",
        .value = "ok",
    }} }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .extra_headers = &.{.{
        .name = "x-ok",
        .value = "bad\r\nvalue",
    }} }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (ModelSettings{ .extra_headers = &.{.{
        .name = "x-ok",
        .value = "bad\x00value",
    }} }).validate());
}
