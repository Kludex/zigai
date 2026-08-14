pub const Entry = struct {
    model: []const u8,
    cassette: []const u8,
};

pub const CompatibleEndpoint = enum {
    fixed,
    azure_openai,
    bedrock,
};

pub const CompatibleEntry = struct {
    provider: []const u8,
    model: []const u8,
    cassette: []const u8,
    api_key_env: []const u8,
    base_url: []const u8 = "",
    endpoint: CompatibleEndpoint = .fixed,
    api_key_header: bool = false,
};

pub const openai = [_]Entry{
    .{ .model = "gpt-4o-mini", .cassette = "cassettes/models/openai_gpt_4o_mini.yaml" },
    .{ .model = "gpt-4.1-mini", .cassette = "cassettes/models/openai_gpt_4_1_mini.yaml" },
    .{ .model = "gpt-5-nano", .cassette = "cassettes/models/openai_gpt_5_nano.yaml" },
    .{ .model = "gpt-5-mini", .cassette = "cassettes/models/openai_gpt_5_mini.yaml" },
    .{ .model = "gpt-5.4-mini", .cassette = "cassettes/models/openai_gpt_5_4_mini.yaml" },
    .{ .model = "gpt-5.5", .cassette = "cassettes/models/openai_gpt_5_5.yaml" },
    .{ .model = "gpt-5.6-luna", .cassette = "cassettes/models/openai_gpt_5_6_luna.yaml" },
    .{ .model = "gpt-5.6-sol", .cassette = "cassettes/models/openai_gpt_5_6_sol.yaml" },
};

pub const anthropic = [_]Entry{
    .{ .model = "claude-haiku-4-5-20251001", .cassette = "cassettes/models/anthropic_claude_haiku_4_5.yaml" },
    .{ .model = "claude-sonnet-4-5-20250929", .cassette = "cassettes/models/anthropic_claude_sonnet_4_5.yaml" },
    .{ .model = "claude-opus-4-5-20251101", .cassette = "cassettes/models/anthropic_claude_opus_4_5.yaml" },
    .{ .model = "claude-sonnet-4-6", .cassette = "cassettes/models/anthropic_claude_sonnet_4_6.yaml" },
    .{ .model = "claude-opus-4-6", .cassette = "cassettes/models/anthropic_claude_opus_4_6.yaml" },
    .{ .model = "claude-fable-5", .cassette = "cassettes/models/anthropic_claude_fable_5.yaml" },
    .{ .model = "claude-sonnet-5", .cassette = "cassettes/models/anthropic_claude_sonnet_5.yaml" },
    .{ .model = "claude-opus-5", .cassette = "cassettes/models/anthropic_claude_opus_5.yaml" },
};

pub const google = [_]Entry{
    .{ .model = "gemini-2.5-flash-lite", .cassette = "cassettes/models/google_gemini_2_5_flash_lite.yaml" },
    .{ .model = "gemini-2.5-flash", .cassette = "cassettes/models/google_gemini_2_5_flash.yaml" },
    .{ .model = "gemini-2.5-pro", .cassette = "cassettes/models/google_gemini_2_5_pro.yaml" },
    .{ .model = "gemini-3-flash-preview", .cassette = "cassettes/models/google_gemini_3_flash_preview.yaml" },
    .{ .model = "gemini-3.1-flash-lite", .cassette = "cassettes/models/google_gemini_3_1_flash_lite.yaml" },
    .{ .model = "gemini-3.5-flash", .cassette = "cassettes/models/google_gemini_3_5_flash.yaml" },
    .{ .model = "gemini-3.1-pro-preview", .cassette = "cassettes/models/google_gemini_3_1_pro_preview.yaml" },
    .{ .model = "gemini-3.7-flash", .cassette = "cassettes/models/google_gemini_3_7_flash.yaml" },
};

pub const compatible = [_]CompatibleEntry{
    .{
        .provider = "azure-openai",
        .model = "gpt-4o",
        .cassette = "cassettes/providers/azure_openai_gpt_4o.yaml",
        .api_key_env = "AZURE_OPENAI_API_KEY",
        .endpoint = .azure_openai,
        .api_key_header = true,
    },
    .{
        .provider = "bedrock",
        .model = "openai.gpt-oss-20b",
        .cassette = "cassettes/providers/bedrock_gpt_oss_20b.yaml",
        .api_key_env = "AWS_BEARER_TOKEN_BEDROCK",
        .endpoint = .bedrock,
    },
    .{
        .provider = "cerebras",
        .model = "gpt-oss-120b",
        .cassette = "cassettes/providers/cerebras_gpt_oss_120b.yaml",
        .api_key_env = "CEREBRAS_API_KEY",
        .base_url = "https://api.cerebras.ai/v1",
    },
    .{
        .provider = "cohere",
        .model = "command-a-plus-05-2026",
        .cassette = "cassettes/providers/cohere_command_a_plus.yaml",
        .api_key_env = "CO_API_KEY",
        .base_url = "https://api.cohere.ai/compatibility/v1",
    },
    .{
        .provider = "deepseek",
        .model = "deepseek-v4-flash",
        .cassette = "cassettes/providers/deepseek_v4_flash.yaml",
        .api_key_env = "DEEPSEEK_API_KEY",
        .base_url = "https://api.deepseek.com/v1",
    },
    .{
        .provider = "doubleword",
        .model = "openai/gpt-oss-20b",
        .cassette = "cassettes/providers/doubleword_gpt_oss_20b.yaml",
        .api_key_env = "DOUBLEWORD_API_KEY",
        .base_url = "https://api.doubleword.ai/v1",
    },
    .{
        .provider = "groq",
        .model = "openai/gpt-oss-20b",
        .cassette = "cassettes/providers/groq_gpt_oss_20b.yaml",
        .api_key_env = "GROQ_API_KEY",
        .base_url = "https://api.groq.com/openai/v1",
    },
    .{
        .provider = "huggingface",
        .model = "CohereLabs/c4ai-command-r7b-12-2024",
        .cassette = "cassettes/providers/huggingface_command_r7b.yaml",
        .api_key_env = "HF_TOKEN",
        .base_url = "https://router.huggingface.co/v1",
    },
    .{
        .provider = "mistral",
        .model = "mistral-small-latest",
        .cassette = "cassettes/providers/mistral_small.yaml",
        .api_key_env = "MISTRAL_API_KEY",
        .base_url = "https://api.mistral.ai/v1",
    },
    .{
        .provider = "openrouter",
        .model = "openai/gpt-4o-mini",
        .cassette = "cassettes/providers/openrouter_gpt_4o_mini.yaml",
        .api_key_env = "OPENROUTER_API_KEY",
        .base_url = "https://openrouter.ai/api/v1",
    },
    .{
        .provider = "together",
        .model = "openai/gpt-oss-20b",
        .cassette = "cassettes/providers/together_gpt_oss_20b.yaml",
        .api_key_env = "TOGETHER_API_KEY",
        .base_url = "https://api.together.xyz/v1",
    },
};
