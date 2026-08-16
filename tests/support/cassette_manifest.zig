const std = @import("std");

pub const Scenario = enum {
    buffered,
    function_tool,
    streamed_text,
    streamed_function_tool,
    structured_output,
    thinking,
    provider_error,
    native_tool,
    rich_media,
    file_lifecycle,

    pub fn name(self: Scenario) []const u8 {
        return switch (self) {
            .buffered => "buffered",
            .function_tool => "function-tool",
            .streamed_text => "streamed-text",
            .streamed_function_tool => "streamed-function-tool",
            .structured_output => "structured-output",
            .thinking => "thinking",
            .provider_error => "provider-error",
            .native_tool => "native-tool",
            .rich_media => "rich-media",
            .file_lifecycle => "file-lifecycle",
        };
    }
};

pub const Route = enum {
    openai,
    anthropic,
    google,
    compatible,
    bedrock_converse,
    azure_responses,
    mistral_conversations,
    cohere_chat,
    openai_rich,
    anthropic_rich,
    google_rich,
    openai_files,
    anthropic_files,
    google_files,
};

pub const CredentialSet = enum {
    openai,
    anthropic,
    google,
    azure_openai,
    bedrock,
    cerebras,
    cohere,
    deepseek,
    doubleword,
    groq,
    huggingface,
    mistral,
    openrouter,
    together,
};

pub const CredentialRequirement = struct {
    alternatives: []const []const u8,
};

const openai_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"OPENAI_API_KEY"} }};
const anthropic_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"ANTHROPIC_API_KEY"} }};
const google_credentials = [_]CredentialRequirement{.{ .alternatives = &.{ "GOOGLE_API_KEY", "GEMINI_API_KEY" } }};
const azure_openai_credentials = [_]CredentialRequirement{
    .{ .alternatives = &.{"AZURE_OPENAI_API_KEY"} },
    .{ .alternatives = &.{"AZURE_OPENAI_ENDPOINT"} },
};
const bedrock_credentials = [_]CredentialRequirement{
    .{ .alternatives = &.{"AWS_BEARER_TOKEN_BEDROCK"} },
    .{ .alternatives = &.{"AWS_DEFAULT_REGION"} },
};
const cerebras_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"CEREBRAS_API_KEY"} }};
const cohere_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"CO_API_KEY"} }};
const deepseek_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"DEEPSEEK_API_KEY"} }};
const doubleword_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"DOUBLEWORD_API_KEY"} }};
const groq_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"GROQ_API_KEY"} }};
const huggingface_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"HF_TOKEN"} }};
const mistral_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"MISTRAL_API_KEY"} }};
const openrouter_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"OPENROUTER_API_KEY"} }};
const together_credentials = [_]CredentialRequirement{.{ .alternatives = &.{"TOGETHER_API_KEY"} }};

pub fn credentialRequirements(set: CredentialSet) []const CredentialRequirement {
    return switch (set) {
        .openai => &openai_credentials,
        .anthropic => &anthropic_credentials,
        .google => &google_credentials,
        .azure_openai => &azure_openai_credentials,
        .bedrock => &bedrock_credentials,
        .cerebras => &cerebras_credentials,
        .cohere => &cohere_credentials,
        .deepseek => &deepseek_credentials,
        .doubleword => &doubleword_credentials,
        .groq => &groq_credentials,
        .huggingface => &huggingface_credentials,
        .mistral => &mistral_credentials,
        .openrouter => &openrouter_credentials,
        .together => &together_credentials,
    };
}

pub const CompatibleEndpoint = enum {
    fixed,
    azure_openai,
    bedrock,
};

pub const FixtureSource = enum {
    live,
    deterministic,
};

pub const Entry = struct {
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    scenario: Scenario,
    cassette: []const u8,
    route: Route,
    credentials: CredentialSet,
    base_url: []const u8 = "",
    endpoint: CompatibleEndpoint = .fixed,
    api_key_header: bool = false,
    source: FixtureSource = .live,
};

pub const openai = [_]Entry{
    modelEntry("openai/gpt-4o-mini/function-tool", "openai", "gpt-4o-mini", "cassettes/models/openai_gpt_4o_mini.yaml", .openai, .openai),
    modelEntry("openai/gpt-4.1-mini/function-tool", "openai", "gpt-4.1-mini", "cassettes/models/openai_gpt_4_1_mini.yaml", .openai, .openai),
    modelEntry("openai/gpt-5-nano/function-tool", "openai", "gpt-5-nano", "cassettes/models/openai_gpt_5_nano.yaml", .openai, .openai),
    modelEntry("openai/gpt-5-mini/function-tool", "openai", "gpt-5-mini", "cassettes/models/openai_gpt_5_mini.yaml", .openai, .openai),
    modelEntry("openai/gpt-5.4-mini/function-tool", "openai", "gpt-5.4-mini", "cassettes/models/openai_gpt_5_4_mini.yaml", .openai, .openai),
    modelEntry("openai/gpt-5.5/function-tool", "openai", "gpt-5.5", "cassettes/models/openai_gpt_5_5.yaml", .openai, .openai),
    modelEntry("openai/gpt-5.6-luna/function-tool", "openai", "gpt-5.6-luna", "cassettes/models/openai_gpt_5_6_luna.yaml", .openai, .openai),
    modelEntry("openai/gpt-5.6-sol/function-tool", "openai", "gpt-5.6-sol", "cassettes/models/openai_gpt_5_6_sol.yaml", .openai, .openai),
};

pub const anthropic = [_]Entry{
    modelEntry("anthropic/claude-haiku-4-5-20251001/function-tool", "anthropic", "claude-haiku-4-5-20251001", "cassettes/models/anthropic_claude_haiku_4_5.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-sonnet-4-5-20250929/function-tool", "anthropic", "claude-sonnet-4-5-20250929", "cassettes/models/anthropic_claude_sonnet_4_5.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-opus-4-5-20251101/function-tool", "anthropic", "claude-opus-4-5-20251101", "cassettes/models/anthropic_claude_opus_4_5.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-sonnet-4-6/function-tool", "anthropic", "claude-sonnet-4-6", "cassettes/models/anthropic_claude_sonnet_4_6.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-opus-4-6/function-tool", "anthropic", "claude-opus-4-6", "cassettes/models/anthropic_claude_opus_4_6.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-fable-5/function-tool", "anthropic", "claude-fable-5", "cassettes/models/anthropic_claude_fable_5.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-sonnet-5/function-tool", "anthropic", "claude-sonnet-5", "cassettes/models/anthropic_claude_sonnet_5.yaml", .anthropic, .anthropic),
    modelEntry("anthropic/claude-opus-5/function-tool", "anthropic", "claude-opus-5", "cassettes/models/anthropic_claude_opus_5.yaml", .anthropic, .anthropic),
};

pub const google = [_]Entry{
    modelEntry("google/gemini-2.5-flash-lite/function-tool", "google", "gemini-2.5-flash-lite", "cassettes/models/google_gemini_2_5_flash_lite.yaml", .google, .google),
    modelEntry("google/gemini-2.5-flash/function-tool", "google", "gemini-2.5-flash", "cassettes/models/google_gemini_2_5_flash.yaml", .google, .google),
    modelEntry("google/gemini-2.5-pro/function-tool", "google", "gemini-2.5-pro", "cassettes/models/google_gemini_2_5_pro.yaml", .google, .google),
    modelEntry("google/gemini-3-flash-preview/function-tool", "google", "gemini-3-flash-preview", "cassettes/models/google_gemini_3_flash_preview.yaml", .google, .google),
    modelEntry("google/gemini-3.1-flash-lite/function-tool", "google", "gemini-3.1-flash-lite", "cassettes/models/google_gemini_3_1_flash_lite.yaml", .google, .google),
    modelEntry("google/gemini-3.5-flash/function-tool", "google", "gemini-3.5-flash", "cassettes/models/google_gemini_3_5_flash.yaml", .google, .google),
    modelEntry("google/gemini-3.1-pro-preview/function-tool", "google", "gemini-3.1-pro-preview", "cassettes/models/google_gemini_3_1_pro_preview.yaml", .google, .google),
    modelEntry("google/gemini-3.7-flash/function-tool", "google", "gemini-3.7-flash", "cassettes/models/google_gemini_3_7_flash.yaml", .google, .google),
};

pub const openai_buffered = [_]Entry{
    bufferedEntry(openai[0], "cassettes/buffered/openai_gpt_4o_mini.yaml"),
    bufferedEntry(openai[1], "cassettes/buffered/openai_gpt_4_1_mini.yaml"),
    bufferedEntry(openai[2], "cassettes/buffered/openai_gpt_5_nano.yaml"),
    bufferedEntry(openai[3], "cassettes/buffered/openai_gpt_5_mini.yaml"),
    bufferedEntry(openai[4], "cassettes/buffered/openai_gpt_5_4_mini.yaml"),
    bufferedEntry(openai[5], "cassettes/buffered/openai_gpt_5_5.yaml"),
    bufferedEntry(openai[6], "cassettes/buffered/openai_gpt_5_6_luna.yaml"),
    bufferedEntry(openai[7], "cassettes/buffered/openai_gpt_5_6_sol.yaml"),
};

pub const anthropic_buffered = [_]Entry{
    bufferedEntry(anthropic[0], "cassettes/buffered/anthropic_claude_haiku_4_5.yaml"),
    bufferedEntry(anthropic[1], "cassettes/buffered/anthropic_claude_sonnet_4_5.yaml"),
    bufferedEntry(anthropic[2], "cassettes/buffered/anthropic_claude_opus_4_5.yaml"),
    bufferedEntry(anthropic[3], "cassettes/buffered/anthropic_claude_sonnet_4_6.yaml"),
    bufferedEntry(anthropic[4], "cassettes/buffered/anthropic_claude_opus_4_6.yaml"),
    bufferedEntry(anthropic[5], "cassettes/buffered/anthropic_claude_fable_5.yaml"),
    bufferedEntry(anthropic[6], "cassettes/buffered/anthropic_claude_sonnet_5.yaml"),
    bufferedEntry(anthropic[7], "cassettes/buffered/anthropic_claude_opus_5.yaml"),
};

pub const google_buffered = [_]Entry{
    bufferedEntry(google[0], "cassettes/buffered/google_gemini_2_5_flash_lite.yaml"),
    bufferedEntry(google[1], "cassettes/buffered/google_gemini_2_5_flash.yaml"),
    bufferedEntry(google[2], "cassettes/buffered/google_gemini_2_5_pro.yaml"),
    bufferedEntry(google[3], "cassettes/buffered/google_gemini_3_flash_preview.yaml"),
    bufferedEntry(google[4], "cassettes/buffered/google_gemini_3_1_flash_lite.yaml"),
    bufferedEntry(google[5], "cassettes/buffered/google_gemini_3_5_flash.yaml"),
    bufferedEntry(google[6], "cassettes/buffered/google_gemini_3_1_pro_preview.yaml"),
    bufferedEntry(google[7], "cassettes/buffered/google_gemini_3_7_flash.yaml"),
};

pub const first_party_buffered = openai_buffered ++ anthropic_buffered ++ google_buffered;

pub const openai_streamed_text = [_]Entry{
    streamEntry(openai[0], .streamed_text, "cassettes/streamed/text/openai_gpt_4o_mini.yaml"),
    streamEntry(openai[1], .streamed_text, "cassettes/streamed/text/openai_gpt_4_1_mini.yaml"),
    streamEntry(openai[2], .streamed_text, "cassettes/streamed/text/openai_gpt_5_nano.yaml"),
    streamEntry(openai[3], .streamed_text, "cassettes/streamed/text/openai_gpt_5_mini.yaml"),
    streamEntry(openai[4], .streamed_text, "cassettes/streamed/text/openai_gpt_5_4_mini.yaml"),
    streamEntry(openai[5], .streamed_text, "cassettes/streamed/text/openai_gpt_5_5.yaml"),
    streamEntry(openai[6], .streamed_text, "cassettes/streamed/text/openai_gpt_5_6_luna.yaml"),
    streamEntry(openai[7], .streamed_text, "cassettes/streamed/text/openai_gpt_5_6_sol.yaml"),
};

pub const anthropic_streamed_text = [_]Entry{
    streamEntry(anthropic[0], .streamed_text, "cassettes/streamed/text/anthropic_claude_haiku_4_5.yaml"),
    streamEntry(anthropic[1], .streamed_text, "cassettes/streamed/text/anthropic_claude_sonnet_4_5.yaml"),
    streamEntry(anthropic[2], .streamed_text, "cassettes/streamed/text/anthropic_claude_opus_4_5.yaml"),
    streamEntry(anthropic[3], .streamed_text, "cassettes/streamed/text/anthropic_claude_sonnet_4_6.yaml"),
    streamEntry(anthropic[4], .streamed_text, "cassettes/streamed/text/anthropic_claude_opus_4_6.yaml"),
    streamEntry(anthropic[5], .streamed_text, "cassettes/streamed/text/anthropic_claude_fable_5.yaml"),
    streamEntry(anthropic[6], .streamed_text, "cassettes/streamed/text/anthropic_claude_sonnet_5.yaml"),
    streamEntry(anthropic[7], .streamed_text, "cassettes/streamed/text/anthropic_claude_opus_5.yaml"),
};

pub const google_streamed_text = [_]Entry{
    streamEntry(google[0], .streamed_text, "cassettes/streamed/text/google_gemini_2_5_flash_lite.yaml"),
    streamEntry(google[1], .streamed_text, "cassettes/streamed/text/google_gemini_2_5_flash.yaml"),
    streamEntry(google[2], .streamed_text, "cassettes/streamed/text/google_gemini_2_5_pro.yaml"),
    streamEntry(google[3], .streamed_text, "cassettes/streamed/text/google_gemini_3_flash_preview.yaml"),
    streamEntry(google[4], .streamed_text, "cassettes/streamed/text/google_gemini_3_1_flash_lite.yaml"),
    streamEntry(google[5], .streamed_text, "cassettes/streamed/text/google_gemini_3_5_flash.yaml"),
    streamEntry(google[6], .streamed_text, "cassettes/streamed/text/google_gemini_3_1_pro_preview.yaml"),
    streamEntry(google[7], .streamed_text, "cassettes/streamed/text/google_gemini_3_7_flash.yaml"),
};

pub const openai_streamed_tools = [_]Entry{
    streamEntry(openai[0], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_4o_mini.yaml"),
    streamEntry(openai[1], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_4_1_mini.yaml"),
    streamEntry(openai[2], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_nano.yaml"),
    streamEntry(openai[3], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_mini.yaml"),
    streamEntry(openai[4], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_4_mini.yaml"),
    streamEntry(openai[5], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_5.yaml"),
    streamEntry(openai[6], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_6_luna.yaml"),
    streamEntry(openai[7], .streamed_function_tool, "cassettes/streamed/tools/openai_gpt_5_6_sol.yaml"),
};

pub const anthropic_streamed_tools = [_]Entry{
    streamEntry(anthropic[0], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_haiku_4_5.yaml"),
    streamEntry(anthropic[1], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_sonnet_4_5.yaml"),
    streamEntry(anthropic[2], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_opus_4_5.yaml"),
    streamEntry(anthropic[3], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_sonnet_4_6.yaml"),
    streamEntry(anthropic[4], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_opus_4_6.yaml"),
    streamEntry(anthropic[5], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_fable_5.yaml"),
    streamEntry(anthropic[6], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_sonnet_5.yaml"),
    streamEntry(anthropic[7], .streamed_function_tool, "cassettes/streamed/tools/anthropic_claude_opus_5.yaml"),
};

pub const google_streamed_tools = [_]Entry{
    streamEntry(google[0], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_2_5_flash_lite.yaml"),
    streamEntry(google[1], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_2_5_flash.yaml"),
    streamEntry(google[2], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_2_5_pro.yaml"),
    streamEntry(google[3], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_3_flash_preview.yaml"),
    streamEntry(google[4], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_3_1_flash_lite.yaml"),
    streamEntry(google[5], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_3_5_flash.yaml"),
    streamEntry(google[6], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_3_1_pro_preview.yaml"),
    streamEntry(google[7], .streamed_function_tool, "cassettes/streamed/tools/google_gemini_3_7_flash.yaml"),
};

pub const first_party_streaming =
    openai_streamed_text ++ anthropic_streamed_text ++ google_streamed_text ++
    openai_streamed_tools ++ anthropic_streamed_tools ++ google_streamed_tools;

pub const openai_capabilities = [_]Entry{
    scenarioEntry("openai/gpt-5.6-sol/structured-output", "openai", "gpt-5.6-sol", .structured_output, "cassettes/structured/openai_gpt_5_6_sol.yaml", .openai, .openai),
    scenarioEntry("openai/gpt-5.6-sol/thinking", "openai", "gpt-5.6-sol", .thinking, "cassettes/thinking/openai_gpt_5_6_sol.yaml", .openai, .openai),
};

pub const anthropic_capabilities = [_]Entry{
    scenarioEntry("anthropic/claude-sonnet-5/structured-output", "anthropic", "claude-sonnet-5", .structured_output, "cassettes/structured/anthropic_claude_sonnet_5.yaml", .anthropic, .anthropic),
    scenarioEntry("anthropic/claude-sonnet-5/thinking", "anthropic", "claude-sonnet-5", .thinking, "cassettes/thinking/anthropic_claude_sonnet_5.yaml", .anthropic, .anthropic),
};

pub const google_capabilities = [_]Entry{
    scenarioEntry("google/gemini-3.7-flash/structured-output", "google", "gemini-3.7-flash", .structured_output, "cassettes/structured/google_gemini_3_7_flash.yaml", .google, .google),
    scenarioEntry("google/gemini-3.7-flash/thinking", "google", "gemini-3.7-flash", .thinking, "cassettes/thinking/google_gemini_3_7_flash.yaml", .google, .google),
};

pub const first_party_capabilities = openai_capabilities ++ anthropic_capabilities ++ google_capabilities;

pub const first_party_errors = [_]Entry{
    deterministicEntry("openai/gpt-5.6-sol/provider-error", "openai", "gpt-5.6-sol", "cassettes/errors/openai.yaml", .openai, .openai),
    deterministicEntry("anthropic/claude-sonnet-5/provider-error", "anthropic", "claude-sonnet-5", "cassettes/errors/anthropic.yaml", .anthropic, .anthropic),
    deterministicEntry("google/gemini-3.7-flash/provider-error", "google", "gemini-3.7-flash", "cassettes/errors/google.yaml", .google, .google),
};

pub const compatible = [_]Entry{
    compatibleEntry("azure-openai/gpt-4o/buffered", "azure-openai", "gpt-4o", "cassettes/providers/azure_openai_gpt_4o.yaml", .azure_openai, "", .azure_openai, true),
    compatibleEntry("bedrock/openai.gpt-oss-20b/buffered", "bedrock", "openai.gpt-oss-20b", "cassettes/providers/bedrock_gpt_oss_20b.yaml", .bedrock, "", .bedrock, false),
    compatibleEntry("cerebras/gpt-oss-120b/buffered", "cerebras", "gpt-oss-120b", "cassettes/providers/cerebras_gpt_oss_120b.yaml", .cerebras, "https://api.cerebras.ai/v1", .fixed, false),
    compatibleEntry("cohere/command-a-plus-05-2026/buffered", "cohere", "command-a-plus-05-2026", "cassettes/providers/cohere_command_a_plus.yaml", .cohere, "https://api.cohere.ai/compatibility/v1", .fixed, false),
    compatibleEntry("deepseek/deepseek-v4-flash/buffered", "deepseek", "deepseek-v4-flash", "cassettes/providers/deepseek_v4_flash.yaml", .deepseek, "https://api.deepseek.com/v1", .fixed, false),
    compatibleEntry("doubleword/openai-gpt-oss-20b/buffered", "doubleword", "openai/gpt-oss-20b", "cassettes/providers/doubleword_gpt_oss_20b.yaml", .doubleword, "https://api.doubleword.ai/v1", .fixed, false),
    compatibleEntry("groq/openai-gpt-oss-20b/buffered", "groq", "openai/gpt-oss-20b", "cassettes/providers/groq_gpt_oss_20b.yaml", .groq, "https://api.groq.com/openai/v1", .fixed, false),
    compatibleEntry("huggingface/command-r7b/buffered", "huggingface", "CohereLabs/c4ai-command-r7b-12-2024", "cassettes/providers/huggingface_command_r7b.yaml", .huggingface, "https://router.huggingface.co/v1", .fixed, false),
    compatibleEntry("mistral/mistral-small-latest/buffered", "mistral", "mistral-small-latest", "cassettes/providers/mistral_small.yaml", .mistral, "https://api.mistral.ai/v1", .fixed, false),
    compatibleEntry("openrouter/openai-gpt-4o-mini/buffered", "openrouter", "openai/gpt-4o-mini", "cassettes/providers/openrouter_gpt_4o_mini.yaml", .openrouter, "https://openrouter.ai/api/v1", .fixed, false),
    compatibleEntry("together/openai-gpt-oss-20b/buffered", "together", "openai/gpt-oss-20b", "cassettes/providers/together_gpt_oss_20b.yaml", .together, "https://api.together.xyz/v1", .fixed, false),
};

pub const compatible_streamed_text = [_]Entry{
    compatibleScenarioEntry(compatible[0], .streamed_text, "cassettes/compatible/streamed/text/azure_openai_gpt_4o.yaml"),
    compatibleScenarioEntry(compatible[1], .streamed_text, "cassettes/compatible/streamed/text/bedrock_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[2], .streamed_text, "cassettes/compatible/streamed/text/cerebras_gpt_oss_120b.yaml"),
    compatibleScenarioEntry(compatible[3], .streamed_text, "cassettes/compatible/streamed/text/cohere_command_a_plus.yaml"),
    compatibleScenarioEntry(compatible[4], .streamed_text, "cassettes/compatible/streamed/text/deepseek_v4_flash.yaml"),
    compatibleScenarioEntry(compatible[5], .streamed_text, "cassettes/compatible/streamed/text/doubleword_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[6], .streamed_text, "cassettes/compatible/streamed/text/groq_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[7], .streamed_text, "cassettes/compatible/streamed/text/huggingface_command_r7b.yaml"),
    compatibleScenarioEntry(compatible[8], .streamed_text, "cassettes/compatible/streamed/text/mistral_small.yaml"),
    compatibleScenarioEntry(compatible[9], .streamed_text, "cassettes/compatible/streamed/text/openrouter_gpt_4o_mini.yaml"),
    compatibleScenarioEntry(compatible[10], .streamed_text, "cassettes/compatible/streamed/text/together_gpt_oss_20b.yaml"),
};

pub const compatible_tools = [_]Entry{
    entryWithId(
        compatibleScenarioEntry(compatible[0], .function_tool, "cassettes/compatible/tools/azure_openai_gpt_4o.yaml"),
        "azure-openai/gpt-4o/chat-function-tool",
    ),
    compatibleScenarioEntry(compatible[1], .function_tool, "cassettes/compatible/tools/bedrock_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[2], .function_tool, "cassettes/compatible/tools/cerebras_gpt_oss_120b.yaml"),
    compatibleScenarioEntry(compatible[3], .function_tool, "cassettes/compatible/tools/cohere_command_a_plus.yaml"),
    compatibleScenarioEntry(compatible[4], .function_tool, "cassettes/compatible/tools/deepseek_v4_flash.yaml"),
    compatibleScenarioEntry(compatible[5], .function_tool, "cassettes/compatible/tools/doubleword_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[6], .function_tool, "cassettes/compatible/tools/groq_gpt_oss_20b.yaml"),
    compatibleScenarioEntry(compatible[7], .function_tool, "cassettes/compatible/tools/huggingface_command_r7b.yaml"),
    compatibleScenarioEntry(compatible[8], .function_tool, "cassettes/compatible/tools/mistral_small.yaml"),
    compatibleScenarioEntry(compatible[9], .function_tool, "cassettes/compatible/tools/openrouter_gpt_4o_mini.yaml"),
    compatibleScenarioEntry(together_tool_model, .function_tool, "cassettes/compatible/tools/together_qwen_2_5_7b.yaml"),
};

pub const compatible_success = compatible ++ compatible_streamed_text ++ compatible_tools;

pub const compatible_errors = [_]Entry{
    compatibleErrorEntry("azure-openai", .azure_openai),
    compatibleErrorEntry("bedrock", .bedrock),
    compatibleErrorEntry("cerebras", .cerebras),
    compatibleErrorEntry("cohere", .cohere),
    compatibleErrorEntry("deepseek", .deepseek),
    compatibleErrorEntry("doubleword", .doubleword),
    compatibleErrorEntry("groq", .groq),
    compatibleErrorEntry("huggingface", .huggingface),
    compatibleErrorEntry("mistral", .mistral),
    compatibleErrorEntry("openrouter", .openrouter),
    compatibleErrorEntry("together", .together),
};

const together_tool_model = compatibleEntry(
    "together/qwen-2.5-7b-instruct-turbo/buffered",
    "together",
    "Qwen/Qwen2.5-7B-Instruct-Turbo",
    "",
    .together,
    "https://api.together.xyz/v1",
    .fixed,
    false,
);

pub const native = [_]Entry{
    scenarioEntry("openai/gpt-5-nano/native-tool", "openai", "gpt-5-nano", .native_tool, "cassettes/native/openai_web_search.yaml", .openai, .openai),
    scenarioEntry("anthropic/claude-sonnet-4-6/native-tool", "anthropic", "claude-sonnet-4-6", .native_tool, "cassettes/native/anthropic_web_search_fetch.yaml", .anthropic, .anthropic),
    scenarioEntry("google/gemini-3.5-flash/native-tool", "google", "gemini-3.5-flash", .native_tool, "cassettes/native/google_web_search_fetch.yaml", .google, .google),
    scenarioEntry("bedrock/claude-sonnet-4-6/function-tool", "bedrock", "us.anthropic.claude-sonnet-4-6", .function_tool, "cassettes/native/bedrock_converse_claude_sonnet_4_6.yaml", .bedrock_converse, .bedrock),
    scenarioEntry("azure-openai/gpt-4o/function-tool", "azure-openai", "gpt-4o", .function_tool, "cassettes/native/azure_responses_gpt_4o.yaml", .azure_responses, .azure_openai),
    scenarioEntry("mistral/mistral-small-latest/native-tool", "mistral", "mistral-small-latest", .native_tool, "cassettes/native/mistral_conversations_web_search.yaml", .mistral_conversations, .mistral),
    scenarioEntry("cohere/command-a-03-2025/function-tool", "cohere", "command-a-03-2025", .function_tool, "cassettes/native/cohere_v2_command_a.yaml", .cohere_chat, .cohere),
};

pub const rich = [_]Entry{
    scenarioEntry("openai/gpt-5-nano/rich-media", "openai", "gpt-5-nano", .rich_media, "cassettes/rich/openai_image.yaml", .openai_rich, .openai),
    scenarioEntry("anthropic/claude-sonnet-4-6/rich-media", "anthropic", "claude-sonnet-4-6", .rich_media, "cassettes/rich/anthropic_image.yaml", .anthropic_rich, .anthropic),
    scenarioEntry("google/gemini-3.5-flash/rich-media", "google", "gemini-3.5-flash", .rich_media, "cassettes/rich/google_image.yaml", .google_rich, .google),
};

pub const files = [_]Entry{
    scenarioEntry("openai/files/file-lifecycle", "openai", "", .file_lifecycle, "cassettes/files/openai.yaml", .openai_files, .openai),
    scenarioEntry("anthropic/files/file-lifecycle", "anthropic", "", .file_lifecycle, "cassettes/files/anthropic.yaml", .anthropic_files, .anthropic),
    scenarioEntry("google/files/file-lifecycle", "google", "", .file_lifecycle, "cassettes/files/google.yaml", .google_files, .google),
};

pub const all = openai ++ anthropic ++ google ++ first_party_buffered ++ first_party_streaming ++ first_party_capabilities ++ first_party_errors ++ compatible_success ++ compatible_errors ++ native ++ rich ++ files;

fn modelEntry(
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    cassette: []const u8,
    route: Route,
    credentials: CredentialSet,
) Entry {
    return scenarioEntry(id, provider, model, .function_tool, cassette, route, credentials);
}

fn bufferedEntry(comptime model_entry: Entry, cassette: []const u8) Entry {
    return .{
        .id = std.fmt.comptimePrint("{s}/{s}/buffered", .{ model_entry.provider, model_entry.model }),
        .provider = model_entry.provider,
        .model = model_entry.model,
        .scenario = .buffered,
        .cassette = cassette,
        .route = model_entry.route,
        .credentials = model_entry.credentials,
    };
}

fn streamEntry(comptime model_entry: Entry, scenario: Scenario, cassette: []const u8) Entry {
    return .{
        .id = std.fmt.comptimePrint("{s}/{s}/{s}", .{ model_entry.provider, model_entry.model, scenario.name() }),
        .provider = model_entry.provider,
        .model = model_entry.model,
        .scenario = scenario,
        .cassette = cassette,
        .route = model_entry.route,
        .credentials = model_entry.credentials,
    };
}

fn compatibleEntry(
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    cassette: []const u8,
    credentials: CredentialSet,
    base_url: []const u8,
    endpoint: CompatibleEndpoint,
    api_key_header: bool,
) Entry {
    return .{
        .id = id,
        .provider = provider,
        .model = model,
        .scenario = .buffered,
        .cassette = cassette,
        .route = .compatible,
        .credentials = credentials,
        .base_url = base_url,
        .endpoint = endpoint,
        .api_key_header = api_key_header,
    };
}

fn compatibleScenarioEntry(comptime entry: Entry, scenario: Scenario, cassette: []const u8) Entry {
    return .{
        .id = std.fmt.comptimePrint("{s}/{s}", .{ entry.id[0 .. entry.id.len - "/buffered".len], scenario.name() }),
        .provider = entry.provider,
        .model = entry.model,
        .scenario = scenario,
        .cassette = cassette,
        .route = entry.route,
        .credentials = entry.credentials,
        .base_url = entry.base_url,
        .endpoint = entry.endpoint,
        .api_key_header = entry.api_key_header,
    };
}

fn entryWithId(comptime entry: Entry, id: []const u8) Entry {
    var renamed = entry;
    renamed.id = id;
    return renamed;
}

fn compatibleErrorEntry(provider: []const u8, credentials: CredentialSet) Entry {
    return .{
        .id = std.fmt.comptimePrint("{s}/chat-contract/provider-error", .{provider}),
        .provider = provider,
        .model = "contract-model",
        .scenario = .provider_error,
        .cassette = "cassettes/errors/openai_compatible.yaml",
        .route = .compatible,
        .credentials = credentials,
        .base_url = "https://compatible.test/v1",
        .source = .deterministic,
    };
}

fn scenarioEntry(
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    scenario: Scenario,
    cassette: []const u8,
    route: Route,
    credentials: CredentialSet,
) Entry {
    return .{
        .id = id,
        .provider = provider,
        .model = model,
        .scenario = scenario,
        .cassette = cassette,
        .route = route,
        .credentials = credentials,
    };
}

fn deterministicEntry(
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    cassette: []const u8,
    route: Route,
    credentials: CredentialSet,
) Entry {
    return .{
        .id = id,
        .provider = provider,
        .model = model,
        .scenario = .provider_error,
        .cassette = cassette,
        .route = route,
        .credentials = credentials,
        .source = .deterministic,
    };
}

pub fn matches(entry: Entry, filter: []const u8) bool {
    if (std.mem.eql(u8, filter, entry.id) or
        std.mem.eql(u8, filter, entry.provider) or
        (entry.model.len > 0 and std.mem.eql(u8, filter, entry.model)) or
        std.mem.eql(u8, filter, entry.scenario.name()))
    {
        return true;
    }
    if (std.mem.eql(u8, filter, "first-party-buffered") and isFirstPartyBuffered(entry)) return true;
    if (std.mem.eql(u8, filter, "first-party-streaming") and isFirstPartyStreaming(entry)) return true;
    if (std.mem.eql(u8, filter, "first-party-capabilities") and isFirstPartyCapability(entry)) return true;
    if (std.mem.eql(u8, filter, "compatible-success") and entry.route == .compatible) return true;
    if (std.mem.eql(u8, filter, "compatible-streaming") and
        entry.route == .compatible and entry.scenario == .streamed_text) return true;
    if (std.mem.eql(u8, filter, "compatible-tools") and
        entry.route == .compatible and entry.scenario == .function_tool) return true;
    if (std.mem.eql(u8, filter, "compatible-errors") and
        entry.route == .compatible and entry.scenario == .provider_error) return true;
    if (isNativeRecording(entry) and
        (std.mem.eql(u8, filter, "native-tools") or matchesNativeProvider(entry, filter)))
    {
        return true;
    }
    return switch (entry.scenario) {
        .native_tool => false,
        .rich_media => std.mem.eql(u8, filter, "rich-content") or prefixedProvider(entry, filter, "rich-"),
        .file_lifecycle => std.mem.eql(u8, filter, "files") or prefixedProvider(entry, filter, "files-"),
        else => false,
    };
}

fn isFirstPartyStreaming(entry: Entry) bool {
    if (entry.scenario != .streamed_text and entry.scenario != .streamed_function_tool) return false;
    return switch (entry.route) {
        .openai, .anthropic, .google => true,
        else => false,
    };
}

fn isFirstPartyBuffered(entry: Entry) bool {
    if (entry.scenario != .buffered) return false;
    return switch (entry.route) {
        .openai, .anthropic, .google => true,
        else => false,
    };
}

fn isFirstPartyCapability(entry: Entry) bool {
    if (entry.scenario != .structured_output and entry.scenario != .thinking) return false;
    return switch (entry.route) {
        .openai, .anthropic, .google => true,
        else => false,
    };
}

fn isNativeRecording(entry: Entry) bool {
    return entry.scenario == .native_tool or switch (entry.route) {
        .bedrock_converse, .azure_responses, .mistral_conversations, .cohere_chat => true,
        else => false,
    };
}

fn matchesNativeProvider(entry: Entry, filter: []const u8) bool {
    const alias = switch (entry.route) {
        .azure_responses => "native-azure",
        else => null,
    };
    return (alias != null and std.mem.eql(u8, filter, alias.?)) or
        prefixedProvider(entry, filter, "native-");
}

fn prefixedProvider(entry: Entry, filter: []const u8, prefix: []const u8) bool {
    return filter.len == prefix.len + entry.provider.len and
        std.mem.startsWith(u8, filter, prefix) and
        std.mem.eql(u8, filter[prefix.len..], entry.provider);
}

pub fn selected(entry: Entry, filters: []const []const u8) bool {
    var has_filter = false;
    for (filters) |filter| {
        if (isControlArgument(filter)) continue;
        has_filter = true;
        if (matches(entry, filter)) return true;
    }
    return !has_filter;
}

pub const FilterError = error{ EmptyFilter, UnknownFilter };

pub fn validateFilters(filters: []const []const u8) FilterError!void {
    for (filters) |filter| {
        if (isControlArgument(filter)) continue;
        if (filter.len == 0) return error.EmptyFilter;
        var known = false;
        for (all) |entry| {
            if (!matches(entry, filter)) continue;
            known = true;
            break;
        }
        if (!known) return error.UnknownFilter;
    }
}

pub fn isControlArgument(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "--list") or
        std.mem.eql(u8, argument, "--list-runnable");
}

test "manifest identifiers and fixture paths are unique" {
    for (all, 0..) |entry, index| {
        try std.testing.expect(entry.id.len > 0);
        try std.testing.expect(entry.provider.len > 0);
        try std.testing.expect(entry.cassette.len > 0);
        try std.testing.expect(credentialRequirements(entry.credentials).len > 0);
        for (all[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
            const shared_contract = entry.source == .deterministic and other.source == .deterministic;
            try std.testing.expect(shared_contract or !std.mem.eql(u8, entry.cassette, other.cassette));
        }
    }
}

test "manifest selection supports stable and compatibility filters" {
    const entry = native[0];
    try std.testing.expect(selected(entry, &.{}));
    try std.testing.expect(selected(entry, &.{"openai/gpt-5-nano/native-tool"}));
    try std.testing.expect(selected(entry, &.{"openai"}));
    try std.testing.expect(selected(entry, &.{"gpt-5-nano"}));
    try std.testing.expect(selected(entry, &.{"native-tool"}));
    try std.testing.expect(selected(entry, &.{"native-tools"}));
    try std.testing.expect(selected(entry, &.{"native-openai"}));
    try std.testing.expect(!selected(entry, &.{"anthropic"}));
    try std.testing.expect(selected(native[3], &.{"native-tools"}));
    try std.testing.expect(selected(native[4], &.{"native-azure"}));
    try std.testing.expect(selected(native[6], &.{"native-cohere"}));
    try std.testing.expect(selected(files[2], &.{"files-google"}));
    try std.testing.expect(selected(rich[1], &.{"rich-content"}));
    try std.testing.expect(selected(openai_buffered[0], &.{"first-party-buffered"}));
    try std.testing.expect(!selected(compatible[0], &.{"first-party-buffered"}));
    try std.testing.expect(selected(openai_streamed_text[0], &.{"first-party-streaming"}));
    try std.testing.expect(selected(google_streamed_tools[7], &.{"streamed-function-tool"}));
    try std.testing.expect(selected(entry, &.{"--list"}));
}

test "manifest filter validation rejects empty and unknown values" {
    try validateFilters(&.{ "openai", "native-tools", "--list-runnable" });
    try std.testing.expectError(error.EmptyFilter, validateFilters(&.{""}));
    try std.testing.expectError(error.UnknownFilter, validateFilters(&.{"not-a-recording"}));
}
