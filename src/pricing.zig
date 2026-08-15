//! Optional, deterministic token-cost estimation.
//!
//! Prices are never fetched at runtime. Applications explicitly select a
//! table, can replace it with their own, and can persist the table version
//! alongside estimates.

const std = @import("std");
const usage_types = @import("usage.zig");

pub const Error = error{CostOverflow};

pub const Match = enum { exact, prefix };

/// Token prices in nano-USD per one million tokens. Null means that a bucket
/// cannot be priced by this row; an estimate is then unavailable rather than
/// silently under-counted.
pub const Rates = struct {
    input: ?u64 = null,
    cache_write: ?u64 = null,
    cache_write_1h: ?u64 = null,
    cache_read: ?u64 = null,
    output: ?u64 = null,
    input_audio: ?u64 = null,
    cache_audio_read: ?u64 = null,
    output_audio: ?u64 = null,
};

pub const Entry = struct {
    provider: []const u8,
    model: []const u8,
    match: Match = .exact,
    rates: Rates,
};

pub const Estimate = struct {
    cost: usage_types.Cost,
    table_version: []const u8,
};

pub const Table = struct {
    version: []const u8,
    entries: []const Entry,

    /// Returns null when the model is absent or a non-empty usage bucket has
    /// no price. Cached and audio counts are inclusive subsets and are removed
    /// from their parent buckets before applying rates.
    pub fn estimate(
        self: Table,
        provider: []const u8,
        model: []const u8,
        usage: usage_types.RequestUsage,
    ) Error!?Estimate {
        const entry = self.find(provider, model) orelse return null;
        const cached_audio = @min(usage.cache_audio_read_tokens, @min(usage.cache_read_tokens, usage.input_audio_tokens));
        const uncached_audio = usage.input_audio_tokens -| cached_audio;
        const cached_text = usage.cache_read_tokens -| cached_audio;
        const cache_write_1h = @min(usage.cache_write_tokens, usage.detail("cache_write_1h_tokens") orelse 0);
        const cache_write_default = usage.cache_write_tokens -| cache_write_1h;
        const plain_input = usage.input_tokens -| (usage.cache_write_tokens +|
            usage.cache_read_tokens +| uncached_audio);
        const plain_output = usage.output_tokens -| usage.output_audio_tokens;

        var total: u64 = 0;
        for ([_]struct { tokens: u64, rate: ?u64 }{
            .{ .tokens = plain_input, .rate = entry.rates.input },
            .{ .tokens = cache_write_default, .rate = entry.rates.cache_write },
            .{ .tokens = cache_write_1h, .rate = entry.rates.cache_write_1h },
            .{ .tokens = cached_text, .rate = entry.rates.cache_read },
            .{ .tokens = uncached_audio, .rate = entry.rates.input_audio },
            .{ .tokens = cached_audio, .rate = entry.rates.cache_audio_read },
            .{ .tokens = plain_output, .rate = entry.rates.output },
            .{ .tokens = usage.output_audio_tokens, .rate = entry.rates.output_audio },
        }) |bucket| {
            if (bucket.tokens == 0) continue;
            try addBucket(&total, bucket.tokens, bucket.rate orelse return null);
        }
        return .{ .cost = .{ .nano_usd = total }, .table_version = self.version };
    }

    fn find(self: Table, provider: []const u8, model: []const u8) ?Entry {
        var prefix: ?Entry = null;
        for (self.entries) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.provider, provider)) continue;
            switch (entry.match) {
                .exact => if (std.mem.eql(u8, entry.model, model)) return entry,
                .prefix => {
                    if (prefix == null and std.mem.startsWith(u8, model, entry.model)) prefix = entry;
                },
            }
        }
        return prefix;
    }
};

fn addBucket(total: *u64, tokens: u64, rate: u64) Error!void {
    const product = @as(u128, tokens) * rate;
    const rounded = (product + 500_000) / 1_000_000;
    if (rounded > std.math.maxInt(u64)) return error.CostOverflow;
    total.* = std.math.add(u64, total.*, @intCast(rounded)) catch return error.CostOverflow;
}

/// Checked-in standard-price snapshot. Prices are nano-USD per million tokens.
/// The table is deliberately explicit and small; unknown models return null.
pub const builtin_version = "2026-08-15";

pub const builtin_sources = [_][]const u8{
    "https://openai.com/api/pricing/",
    "https://platform.claude.com/docs/en/about-claude/pricing",
    "https://ai.google.dev/gemini-api/docs/pricing",
};

pub const builtin = Table{
    .version = builtin_version,
    .entries = &.{
        .{ .provider = "openai", .model = "gpt-5.6-sol", .match = .prefix, .rates = .{
            .input = 5_000_000_000,
            .cache_read = 500_000_000,
            .output = 30_000_000_000,
        } },
        .{ .provider = "openai", .model = "gpt-5.6-terra", .match = .prefix, .rates = .{
            .input = 2_500_000_000,
            .cache_read = 250_000_000,
            .output = 15_000_000_000,
        } },
        .{ .provider = "openai", .model = "gpt-5.6-luna", .match = .prefix, .rates = .{
            .input = 1_000_000_000,
            .cache_read = 100_000_000,
            .output = 6_000_000_000,
        } },
        .{ .provider = "openai", .model = "gpt-5-nano", .match = .prefix, .rates = .{
            .input = 50_000_000,
            .cache_read = 5_000_000,
            .output = 400_000_000,
        } },
        .{ .provider = "anthropic", .model = "claude-sonnet-4-", .match = .prefix, .rates = .{
            .input = 3_000_000_000,
            .cache_write = 3_750_000_000,
            .cache_write_1h = 6_000_000_000,
            .cache_read = 300_000_000,
            .output = 15_000_000_000,
        } },
        .{ .provider = "anthropic", .model = "claude-haiku-4-5", .match = .prefix, .rates = .{
            .input = 1_000_000_000,
            .cache_write = 1_250_000_000,
            .cache_write_1h = 2_000_000_000,
            .cache_read = 100_000_000,
            .output = 5_000_000_000,
        } },
        .{ .provider = "google", .model = "gemini-3.5-flash", .match = .prefix, .rates = .{
            .input = 1_500_000_000,
            .cache_read = 150_000_000,
            .output = 9_000_000_000,
        } },
    },
};

test "price table estimates inclusive cached buckets without double counting" {
    const table = Table{ .version = "test-v1", .entries = &.{.{
        .provider = "provider",
        .model = "model",
        .rates = .{
            .input = 1_000_000_000,
            .cache_write = 2_000_000_000,
            .cache_write_1h = 3_000_000_000,
            .cache_read = 100_000_000,
            .output = 3_000_000_000,
            .input_audio = 4_000_000_000,
            .cache_audio_read = 200_000_000,
            .output_audio = 5_000_000_000,
        },
    }} };
    const estimate = (try table.estimate("PROVIDER", "model", .{
        .input_tokens = 1_000_000,
        .cache_write_tokens = 100_000,
        .cache_read_tokens = 200_000,
        .input_audio_tokens = 300_000,
        .cache_audio_read_tokens = 50_000,
        .output_tokens = 400_000,
        .output_audio_tokens = 100_000,
        .details = &.{.{ .name = "cache_write_1h_tokens", .value = 25_000 }},
    })).?;
    try std.testing.expectEqualStrings("test-v1", estimate.table_version);
    try std.testing.expectEqual(@as(u64, 3_100_000_000), estimate.cost.nano_usd);
}

test "price table distinguishes unknown and unpriceable usage" {
    try std.testing.expect((try builtin.estimate("openai", "missing", .{ .input_tokens = 1 })) == null);
    const table = Table{ .version = "v", .entries = &.{.{
        .provider = "provider",
        .model = "model",
        .rates = .{ .input = 1 },
    }} };
    try std.testing.expect((try table.estimate("provider", "model", .{ .output_tokens = 1 })) == null);
}

test "built-in snapshot prices each first-party default" {
    inline for (.{
        .{ "openai", "gpt-5-nano" },
        .{ "anthropic", "claude-sonnet-4-6" },
        .{ "google", "gemini-3.5-flash" },
    }) |model| {
        const estimate = (try builtin.estimate(model[0], model[1], .{ .input_tokens = 1_000_000 })).?;
        try std.testing.expect(estimate.cost.nano_usd > 0);
    }
}
