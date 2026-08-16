//! Optional, deterministic token-cost estimation.
//!
//! Prices are never fetched at runtime. Applications explicitly select a
//! table, can replace it with their own, and can persist the table version
//! alongside estimates.

const std = @import("std");
const usage_types = @import("usage.zig");

pub const Error = error{CostOverflow};

pub const Match = enum {
    exact,
    prefix,
    suffix,
    contains,
    digit_prefix,
    dated,
};

pub const Bucket = enum {
    input,
    cache_write,
    cache_write_1h,
    cache_read,
    output,
    output_reasoning,
    input_audio,
    cache_audio_read,
    output_audio,
    input_image,
    cache_image_read,
    output_image,
    input_video,
    output_video,
    output_citation,
    requests,
    web_searches,
};

/// Token prices in nano-USD per one million tokens. Null means that a bucket
/// cannot be priced by this row; an estimate is then unavailable rather than
/// silently under-counted.
pub const Rates = struct {
    input: ?u64 = null,
    cache_write: ?u64 = null,
    cache_write_1h: ?u64 = null,
    cache_read: ?u64 = null,
    output: ?u64 = null,
    output_reasoning: ?u64 = null,
    input_audio: ?u64 = null,
    cache_audio_read: ?u64 = null,
    output_audio: ?u64 = null,
    input_image: ?u64 = null,
    cache_image_read: ?u64 = null,
    output_image: ?u64 = null,
    input_video: ?u64 = null,
    output_video: ?u64 = null,
    output_citation: ?u64 = null,
    /// Nano-USD per thousand requests.
    requests: ?u64 = null,
    /// Nano-USD per thousand web searches.
    web_searches: ?u64 = null,
};

pub const Tier = struct {
    bucket: Bucket,
    /// The tier applies when total input tokens are greater than this value,
    /// matching genai-prices' cliff semantics.
    start_tokens: u64,
    rate: u64,
};

pub const Entry = struct {
    provider: []const u8,
    model: []const u8,
    match: Match = .exact,
    rates: Rates,
    tiers: []const Tier = &.{},

    fn rateFor(self: Entry, bucket: Bucket, total_input_tokens: u64) ?u64 {
        var rate = rateValue(self.rates, bucket);
        for (self.tiers) |tier| {
            if (tier.bucket == bucket and total_input_tokens > tier.start_tokens) rate = tier.rate;
        }
        return rate;
    }
};

pub const ProviderFallback = struct {
    provider: []const u8,
    fallbacks: []const []const u8,
};

pub const Estimate = struct {
    cost: usage_types.Cost,
    table_version: []const u8,
};

pub const Table = struct {
    version: []const u8,
    entries: []const Entry,
    fallbacks: []const ProviderFallback = &.{},

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
        const total_input = usage.input_tokens;
        const reasoning = @min(usage.reasoning_tokens, usage.output_tokens);
        const input_image = usage.detail("input_image_tokens") orelse 0;
        const cache_image = @min(
            usage.detail("cache_image_read_tokens") orelse 0,
            @min(usage.cache_read_tokens, input_image),
        );
        const input_video = usage.detail("input_video_tokens") orelse 0;
        const output_image = usage.detail("output_image_tokens") orelse 0;
        const output_video = usage.detail("output_video_tokens") orelse 0;
        const output_citation = usage.detail("output_citation_tokens") orelse sumDetails(usage, &.{
            "output_text_citation_tokens",
            "output_image_citation_tokens",
        });
        const cached_audio = @min(usage.cache_audio_read_tokens, @min(usage.cache_read_tokens, usage.input_audio_tokens));
        const uncached_audio = usage.input_audio_tokens -| cached_audio;
        const priced_input_image = if (entry.rateFor(.input_image, total_input) != null) input_image -| cache_image else 0;
        const priced_cache_image = if (entry.rateFor(.cache_image_read, total_input) != null) cache_image else 0;
        const priced_input_video = if (entry.rateFor(.input_video, total_input) != null) input_video else 0;
        const cached_text = usage.cache_read_tokens -| (cached_audio +| priced_cache_image);
        const cache_write_1h = @min(usage.cache_write_tokens, usage.detail("cache_write_1h_tokens") orelse 0);
        const cache_write_default = usage.cache_write_tokens -| cache_write_1h;
        const plain_input = usage.input_tokens -| (usage.cache_write_tokens +|
            usage.cache_read_tokens +| uncached_audio +| priced_input_image +| priced_input_video);
        const priced_reasoning = if (entry.rateFor(.output_reasoning, total_input) != null) reasoning else 0;
        const priced_output_image = if (entry.rateFor(.output_image, total_input) != null) output_image else 0;
        const priced_output_video = if (entry.rateFor(.output_video, total_input) != null) output_video else 0;
        const priced_output_citation = if (entry.rateFor(.output_citation, total_input) != null) output_citation else 0;
        const plain_output = usage.output_tokens -| (usage.output_audio_tokens +| priced_reasoning +|
            priced_output_image +| priced_output_video +| priced_output_citation);

        var total: u64 = 0;
        for ([_]struct { count: u64, bucket: Bucket }{
            .{ .count = plain_input, .bucket = .input },
            .{ .count = cache_write_default, .bucket = .cache_write },
            .{ .count = cache_write_1h, .bucket = .cache_write_1h },
            .{ .count = cached_text, .bucket = .cache_read },
            .{ .count = uncached_audio, .bucket = .input_audio },
            .{ .count = cached_audio, .bucket = .cache_audio_read },
            .{ .count = priced_input_image, .bucket = .input_image },
            .{ .count = priced_cache_image, .bucket = .cache_image_read },
            .{ .count = priced_input_video, .bucket = .input_video },
            .{ .count = plain_output, .bucket = .output },
            .{ .count = priced_reasoning, .bucket = .output_reasoning },
            .{ .count = usage.output_audio_tokens, .bucket = .output_audio },
            .{ .count = priced_output_image, .bucket = .output_image },
            .{ .count = priced_output_video, .bucket = .output_video },
            .{ .count = priced_output_citation, .bucket = .output_citation },
        }) |bucket| {
            if (bucket.count == 0) continue;
            try addBucket(&total, bucket.count, entry.rateFor(bucket.bucket, total_input) orelse return null);
        }
        if (entry.rateFor(.requests, total_input)) |rate| try addUnit(&total, 1, rate, 1_000);
        const web_searches = usage.detail("web_searches") orelse usage.detail("web_search_requests") orelse 0;
        if (web_searches > 0) {
            const rate = entry.rateFor(.web_searches, total_input) orelse return null;
            try addUnit(&total, web_searches, rate, 1_000);
        }
        return .{ .cost = .{ .nano_usd = total }, .table_version = self.version };
    }

    fn find(self: Table, provider: []const u8, model: []const u8) ?Entry {
        const canonical = canonicalProvider(provider);
        if (self.findInProvider(canonical, model)) |entry| return entry;
        for (self.fallbacks) |fallback| {
            if (!std.ascii.eqlIgnoreCase(fallback.provider, canonical)) continue;
            for (fallback.fallbacks) |fallback_provider| {
                if (self.findInProvider(fallback_provider, model)) |entry| return entry;
            }
        }
        return null;
    }

    fn findInProvider(self: Table, provider: []const u8, model: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.provider, provider)) continue;
            if (matches(entry.match, model, entry.model)) return entry;
        }
        return null;
    }
};

fn rateValue(rates: Rates, bucket: Bucket) ?u64 {
    return switch (bucket) {
        inline else => |field| @field(rates, @tagName(field)),
    };
}

fn addUnit(total: *u64, count: u64, rate: u64, per: u64) Error!void {
    const product = @as(u128, count) * rate;
    const rounded = (product + per / 2) / per;
    if (rounded > std.math.maxInt(u64)) return error.CostOverflow;
    total.* = std.math.add(u64, total.*, @intCast(rounded)) catch return error.CostOverflow;
}

fn addBucket(total: *u64, tokens: u64, rate: u64) Error!void {
    return addUnit(total, tokens, rate, 1_000_000);
}

fn canonicalProvider(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "bedrock")) return "aws";
    if (std.ascii.eqlIgnoreCase(provider, "azure-openai")) return "azure";
    if (std.ascii.eqlIgnoreCase(provider, "xai")) return "x-ai";
    if (std.ascii.eqlIgnoreCase(provider, "zai")) return "zhipuai";
    if (std.ascii.eqlIgnoreCase(provider, "gcp.gen_ai") or
        std.ascii.eqlIgnoreCase(provider, "gcp.vertex_ai")) return "google";
    return provider;
}

fn matches(kind: Match, value: []const u8, pattern: []const u8) bool {
    return switch (kind) {
        .exact => std.mem.eql(u8, value, pattern),
        .prefix => std.mem.startsWith(u8, value, pattern),
        .suffix => std.mem.endsWith(u8, value, pattern),
        .contains => std.mem.indexOf(u8, value, pattern) != null,
        .digit_prefix => std.mem.startsWith(u8, value, pattern) and
            value.len > pattern.len and std.ascii.isDigit(value[pattern.len]),
        .dated => blk: {
            if (!std.mem.startsWith(u8, value, pattern) or value.len != pattern.len + 8) break :blk false;
            for (value[pattern.len..]) |character| {
                if (!std.ascii.isDigit(character)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn sumDetails(usage: usage_types.RequestUsage, names: []const []const u8) u64 {
    var total: u64 = 0;
    for (names) |name| total +|= usage.detail(name) orelse 0;
    return total;
}

const snapshot = @import("pricing_snapshot.zig");
const SnapshotEntry = Entry;
const SnapshotProviderFallback = ProviderFallback;
const SnapshotSchema = struct {
    pub const Entry = SnapshotEntry;
    pub const ProviderFallback = SnapshotProviderFallback;
};

const builtin_entries = snapshot.entries(SnapshotSchema);
const builtin_fallbacks = snapshot.fallbacks(SnapshotSchema);

/// Identifies the exact genai-prices release and date used by the built-in table.
pub const builtin_version = "genai-prices-" ++ snapshot.source_version ++ "-" ++ snapshot.snapshot_date;
pub const builtin_source_version = snapshot.source_version;
pub const builtin_source_commit = snapshot.source_commit;
pub const builtin_source_sha256 = snapshot.source_sha256;
pub const builtin_provider_count = snapshot.provider_count;
pub const builtin_model_count = snapshot.model_count;
pub const builtin_entry_count = snapshot.entry_count;

pub const builtin_sources = [_][]const u8{
    "https://github.com/pydantic/genai-prices",
    "https://raw.githubusercontent.com/pydantic/genai-prices/" ++ snapshot.source_commit ++ "/" ++ snapshot.source_path,
};

/// Offline standard-price snapshot generated from pydantic/genai-prices v2.
/// Unknown models and non-empty buckets without a price return null.
pub const builtin = Table{
    .version = builtin_version,
    .entries = &builtin_entries,
    .fallbacks = &builtin_fallbacks,
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
    try std.testing.expectEqualStrings("v0.1.0", builtin_source_version);
    try std.testing.expectEqual(@as(usize, 34), builtin_provider_count);
    try std.testing.expectEqual(@as(usize, 1_290), builtin_model_count);
    try std.testing.expectEqual(@as(usize, 2_026), builtin_entry_count);
    try std.testing.expect(std.mem.indexOf(u8, builtin_version, "genai-prices-") != null);
    inline for (.{
        .{ "openai", "gpt-5-nano" },
        .{ "anthropic", "claude-sonnet-4-6" },
        .{ "google", "gemini-3.5-flash" },
    }) |model| {
        const estimate = (try builtin.estimate(model[0], model[1], .{ .input_tokens = 1_000_000 })).?;
        try std.testing.expect(estimate.cost.nano_usd > 0);
    }
}

test "price table applies all genai-prices usage buckets" {
    const table = Table{ .version = "all-buckets", .entries = &.{.{
        .provider = "provider",
        .model = "model",
        .rates = .{
            .input = 1_000_000_000,
            .cache_write = 1_000_000_000,
            .cache_write_1h = 1_000_000_000,
            .cache_read = 1_000_000_000,
            .output = 1_000_000_000,
            .output_reasoning = 1_000_000_000,
            .input_audio = 1_000_000_000,
            .cache_audio_read = 1_000_000_000,
            .output_audio = 1_000_000_000,
            .input_image = 1_000_000_000,
            .cache_image_read = 1_000_000_000,
            .output_image = 1_000_000_000,
            .input_video = 1_000_000_000,
            .output_video = 1_000_000_000,
            .output_citation = 1_000_000_000,
            .requests = 1_000_000_000,
            .web_searches = 1_000_000_000,
        },
    }} };
    const estimate = (try table.estimate("provider", "model", .{
        .input_tokens = 1_000_000,
        .cache_write_tokens = 100_000,
        .cache_read_tokens = 200_000,
        .output_tokens = 1_000_000,
        .reasoning_tokens = 200_000,
        .input_audio_tokens = 100_000,
        .cache_audio_read_tokens = 20_000,
        .output_audio_tokens = 100_000,
        .details = &.{
            .{ .name = "cache_write_1h_tokens", .value = 20_000 },
            .{ .name = "input_image_tokens", .value = 100_000 },
            .{ .name = "cache_image_read_tokens", .value = 30_000 },
            .{ .name = "input_video_tokens", .value = 50_000 },
            .{ .name = "output_image_tokens", .value = 100_000 },
            .{ .name = "output_video_tokens", .value = 50_000 },
            .{ .name = "output_text_citation_tokens", .value = 10_000 },
            .{ .name = "output_image_citation_tokens", .value = 20_000 },
            .{ .name = "web_searches", .value = 2 },
        },
    })).?;
    try std.testing.expectEqual(@as(u64, 2_003_000_000), estimate.cost.nano_usd);
}

test "price table supports every genai-prices model matcher" {
    try std.testing.expect(matches(.exact, "model", "model"));
    try std.testing.expect(!matches(.exact, "MODEL", "model"));
    try std.testing.expect(!matches(.exact, "model-v2", "model"));
    try std.testing.expect(matches(.prefix, "model-v2", "model"));
    try std.testing.expect(!matches(.prefix, "mod", "model"));
    try std.testing.expect(matches(.suffix, "vendor/model", "model"));
    try std.testing.expect(!matches(.suffix, "model-v2", "model"));
    try std.testing.expect(matches(.contains, "vendor/model:v1", "model"));
    try std.testing.expect(matches(.contains, "model", ""));
    try std.testing.expect(!matches(.contains, "mod", "model"));
    try std.testing.expect(!matches(.contains, "other", "model"));
    try std.testing.expect(matches(.digit_prefix, "model-2-preview", "model-"));
    try std.testing.expect(!matches(.digit_prefix, "model-preview", "model-"));
    try std.testing.expect(!matches(.digit_prefix, "model-", "model-"));
    try std.testing.expect(matches(.dated, "model-20260816", "model-"));
    try std.testing.expect(!matches(.dated, "other-20260816", "model-"));
    try std.testing.expect(!matches(.dated, "model-2026081", "model-"));
    try std.testing.expect(!matches(.dated, "model-2026081x", "model-"));
}

test "price table supports provider aliases fallbacks and first-match order" {
    inline for (.{
        .{ "bedrock", "aws" },
        .{ "azure-openai", "azure" },
        .{ "xai", "x-ai" },
        .{ "zai", "zhipuai" },
        .{ "gcp.gen_ai", "google" },
        .{ "gcp.vertex_ai", "google" },
        .{ "custom", "custom" },
    }) |provider| try std.testing.expectEqualStrings(provider[1], canonicalProvider(provider[0]));

    const table = Table{
        .version = "fallbacks",
        .entries = &.{
            .{ .provider = "target", .model = "model", .match = .prefix, .rates = .{ .input = 1 } },
            .{ .provider = "target", .model = "model-exact", .rates = .{ .input = 2 } },
        },
        .fallbacks = &.{
            .{ .provider = "unused", .fallbacks = &.{"other"} },
            .{ .provider = "source", .fallbacks = &.{ "missing", "target" } },
        },
    };
    const estimate = (try table.estimate("SOURCE", "model-exact", .{ .input_tokens = 1_000_000 })).?;
    try std.testing.expectEqual(@as(u64, 1), estimate.cost.nano_usd);
    try std.testing.expect((try table.estimate("other", "model", .{ .input_tokens = 1 })) == null);
}

test "price table applies cliff tiers above their input boundary" {
    const entry = Entry{
        .provider = "provider",
        .model = "model",
        .rates = .{ .input = 10 },
        .tiers = &.{
            .{ .bucket = .output, .start_tokens = 1, .rate = 99 },
            .{ .bucket = .input, .start_tokens = 200_000, .rate = 20 },
        },
    };
    try std.testing.expectEqual(@as(?u64, 10), entry.rateFor(.input, 200_000));
    try std.testing.expectEqual(@as(?u64, 20), entry.rateFor(.input, 200_001));
    try std.testing.expectEqual(@as(?u64, null), entry.rateFor(.cache_read, 200_001));
}

test "price table requires web-search rates and protects cost arithmetic" {
    const table = Table{ .version = "v", .entries = &.{.{
        .provider = "provider",
        .model = "model",
        .rates = .{ .input = 1 },
    }} };
    try std.testing.expect((try table.estimate("provider", "model", .{
        .details = &.{.{ .name = "web_search_requests", .value = 1 }},
    })) == null);

    var total: u64 = 0;
    try std.testing.expectError(error.CostOverflow, addUnit(&total, std.math.maxInt(u64), std.math.maxInt(u64), 1));
    total = std.math.maxInt(u64);
    try std.testing.expectError(error.CostOverflow, addUnit(&total, 1, 1, 1));
    total = 0;
    try addUnit(&total, 1, 1, 2);
    try std.testing.expectEqual(@as(u64, 1), total);
}
