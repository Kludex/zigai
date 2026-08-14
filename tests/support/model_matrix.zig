pub const Entry = struct {
    model: []const u8,
    cassette: []const u8,
};

pub const openai = [_]Entry{
    .{ .model = "gpt-5-nano", .cassette = "cassettes/models/openai_gpt_5_nano.yaml" },
    .{ .model = "gpt-5.4-mini", .cassette = "cassettes/models/openai_gpt_5_4_mini.yaml" },
    .{ .model = "gpt-5.5", .cassette = "cassettes/models/openai_gpt_5_5.yaml" },
    .{ .model = "gpt-5.6-luna", .cassette = "cassettes/models/openai_gpt_5_6_luna.yaml" },
};

pub const anthropic = [_]Entry{
    .{ .model = "claude-haiku-4-5-20251001", .cassette = "cassettes/models/anthropic_claude_haiku_4_5.yaml" },
    .{ .model = "claude-sonnet-4-6", .cassette = "cassettes/models/anthropic_claude_sonnet_4_6.yaml" },
    .{ .model = "claude-fable-5", .cassette = "cassettes/models/anthropic_claude_fable_5.yaml" },
    .{ .model = "claude-opus-4-6", .cassette = "cassettes/models/anthropic_claude_opus_4_6.yaml" },
};

pub const google = [_]Entry{
    .{ .model = "gemini-2.5-flash-lite", .cassette = "cassettes/models/google_gemini_2_5_flash_lite.yaml" },
    .{ .model = "gemini-3.1-flash-lite", .cassette = "cassettes/models/google_gemini_3_1_flash_lite.yaml" },
    .{ .model = "gemini-3.5-flash", .cassette = "cassettes/models/google_gemini_3_5_flash.yaml" },
    .{ .model = "gemini-3.1-pro-preview", .cassette = "cassettes/models/google_gemini_3_1_pro_preview.yaml" },
};
