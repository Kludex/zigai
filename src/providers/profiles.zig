//! Provider and model-family capability profiles.
//!
//! This module contains capability knowledge only. Provider state owns lookup
//! precedence, and model adapters own wire encoding.

const std = @import("std");
const model = @import("../model.zig");

/// Baseline profiles for arbitrary OpenAI-compatible endpoints. Named
/// providers should use provider-specific lookup functions instead.
pub const openai_compatible = struct {
    pub const full: model.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = true,
        .supports_json_schema_output = true,
        .supports_json_object_output = true,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
        .supports_top_p = true,
        .supports_presence_penalty = true,
        .supports_frequency_penalty = true,
        .supports_logprobs = true,
        .supports_tool_choice = true,
        .supports_parallel_tool_call_setting = true,
        .supports_request_headers = true,
        .extra_body_kind = .openai_compatible,
        .reasoning_efforts = model.ModelProfile.ReasoningEffortSet.initFull(),
        .service_tiers = model.ModelProfile.ServiceTierSet.initFull(),
    };
    pub const basic: model.ModelProfile = .{
        .supports_tools = true,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
        .supports_top_p = true,
        .supports_presence_penalty = true,
        .supports_frequency_penalty = true,
        .supports_tool_choice = true,
        .supports_parallel_tool_call_setting = true,
        .supports_request_headers = true,
        .extra_body_kind = .openai_compatible,
    };
    pub const minimal: model.ModelProfile = .{
        .supports_tools = false,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_temperature = true,
        .supports_max_tokens = true,
        .supports_stop_sequences = true,
        .supports_seed = true,
        .supports_top_p = true,
        .supports_presence_penalty = true,
        .supports_frequency_penalty = true,
        .supports_request_headers = true,
        .extra_body_kind = .openai_compatible,
    };

    /// Fail-closed fallback for a model family the named provider does not
    /// recognize. Applications can replace it through `Client.profile`.
    pub const unknown: model.ModelProfile = .{
        .supports_tools = false,
        .supports_parallel_tool_calls = false,
        .supports_system_messages = true,
        .supports_streaming = true,
        .supports_max_tokens = true,
        .supports_request_headers = true,
        .extra_body_kind = .openai_compatible,
    };
};

const Family = enum {
    amazon,
    anthropic,
    cohere,
    deepseek,
    google,
    grok,
    harmony,
    meta,
    mistral,
    moonshot,
    openai,
    qwen,
    zai,
};

const Route = struct {
    prefix: []const u8,
    family: Family,
};

const hosted_routes = [_]Route{
    .{ .prefix = "amazon", .family = .amazon },
    .{ .prefix = "anthropic", .family = .anthropic },
    .{ .prefix = "cohere", .family = .cohere },
    .{ .prefix = "coherelabs", .family = .cohere },
    .{ .prefix = "deepseek", .family = .deepseek },
    .{ .prefix = "deepseek-ai", .family = .deepseek },
    .{ .prefix = "google", .family = .google },
    .{ .prefix = "meta-llama", .family = .meta },
    .{ .prefix = "mistralai", .family = .mistral },
    .{ .prefix = "moonshotai", .family = .moonshot },
    .{ .prefix = "openai", .family = .openai },
    .{ .prefix = "qwen", .family = .qwen },
    .{ .prefix = "x-ai", .family = .grok },
};

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn reasoningEfforts() model.ModelProfile.ReasoningEffortSet {
    return model.ModelProfile.ReasoningEffortSet.initMany(&.{ .low, .medium, .high });
}

fn familyProfile(family: Family, model_name: []const u8) model.ModelProfile {
    var profile = openai_compatible.full;
    profile.reasoning_efforts = model.ModelProfile.ReasoningEffortSet.initEmpty();
    profile.service_tiers = model.ModelProfile.ServiceTierSet.initEmpty();
    switch (family) {
        .openai => {
            if (startsWith(model_name, "o1") or startsWith(model_name, "o3") or
                startsWith(model_name, "o4") or startsWith(model_name, "gpt-5"))
            {
                profile.supports_temperature = false;
                profile.supports_stop_sequences = false;
                profile.supports_seed = false;
                profile.supports_top_p = false;
                profile.supports_presence_penalty = false;
                profile.supports_frequency_penalty = false;
                profile.supports_logprobs = false;
                profile.reasoning_efforts = reasoningEfforts();
            }
        },
        .harmony => {
            profile.supports_temperature = false;
            profile.supports_stop_sequences = false;
            profile.supports_seed = false;
            profile.supports_top_p = false;
            profile.supports_presence_penalty = false;
            profile.supports_frequency_penalty = false;
            profile.supports_logprobs = false;
            profile.reasoning_efforts = reasoningEfforts();
        },
        .anthropic => {
            profile.supports_seed = false;
            profile.supports_presence_penalty = false;
            profile.supports_frequency_penalty = false;
            profile.supports_logprobs = false;
        },
        .cohere => {
            profile.supports_seed = false;
            profile.supports_logprobs = false;
        },
        .deepseek => {
            profile.supports_json_schema_output = false;
            profile.supports_seed = false;
            profile.supports_logprobs = false;
            if (startsWith(model_name, "deepseek-r1") or
                std.ascii.eqlIgnoreCase(model_name, "deepseek-reasoner") or
                startsWith(model_name, "deepseek-v4-"))
            {
                profile.supports_temperature = false;
                profile.supports_stop_sequences = false;
                profile.supports_top_p = false;
                profile.supports_presence_penalty = false;
                profile.supports_frequency_penalty = false;
                profile.supports_tool_choice = false;
            }
        },
        .google => {
            profile.supports_presence_penalty = false;
            profile.supports_frequency_penalty = false;
            profile.supports_logprobs = false;
        },
        .meta, .qwen, .zai => {
            profile.supports_json_schema_output = false;
            profile.supports_seed = false;
            profile.supports_logprobs = false;
        },
        .mistral => {
            profile.supports_logprobs = false;
        },
        .amazon, .grok, .moonshot => {
            profile.supports_seed = false;
            profile.supports_presence_penalty = false;
            profile.supports_frequency_penalty = false;
            profile.supports_logprobs = false;
        },
    }
    return profile;
}

fn routedProfile(model_name: []const u8, separator: u8) ?model.ModelProfile {
    const split = std.mem.indexOfScalar(u8, model_name, separator) orelse return null;
    const raw_provider_name = model_name[0..split];
    const provider_name = if (startsWith(raw_provider_name, "~")) raw_provider_name[1..] else raw_provider_name;
    var family_name = model_name[split + 1 ..];
    if (std.mem.indexOfScalar(u8, family_name, ':')) |tag| family_name = family_name[0..tag];
    for (hosted_routes) |route| {
        if (std.ascii.eqlIgnoreCase(provider_name, route.prefix))
            return familyProfile(route.family, family_name);
    }
    return null;
}

/// Azure OpenAI and Foundry model families served through Chat Completions.
pub fn azureOpenAI(model_name: []const u8) ?model.ModelProfile {
    if (startsWith(model_name, "llama") or startsWith(model_name, "meta-")) return familyProfile(.meta, model_name);
    if (startsWith(model_name, "deepseek")) return familyProfile(.deepseek, model_name);
    if (startsWith(model_name, "mistral") or startsWith(model_name, "ministral") or startsWith(model_name, "magistral"))
        return familyProfile(.mistral, model_name);
    if (startsWith(model_name, "cohere-")) return familyProfile(.cohere, model_name);
    if (startsWith(model_name, "grok")) return familyProfile(.grok, model_name);
    if (startsWith(model_name, "gpt-") or startsWith(model_name, "chatgpt-") or
        startsWith(model_name, "o1") or startsWith(model_name, "o3") or startsWith(model_name, "o4"))
        return familyProfile(.openai, model_name);
    return null;
}

/// xAI language models served through the native Responses API.
pub fn xAIResponses(model_name: []const u8) ?model.ModelProfile {
    if (!startsWith(model_name, "grok") and !std.ascii.eqlIgnoreCase(model_name, "latest")) return null;
    var profile = familyProfile(.grok, model_name);
    profile.supports_json_schema_output = true;
    profile.supports_json_object_output = true;
    profile.supports_thinking = true;
    profile.supports_truncation = true;
    profile.extra_body_kind = .xai;
    profile.reasoning_efforts = reasoningEfforts();
    if (std.mem.indexOf(u8, model_name, "multi-agent") != null) profile.reasoning_efforts.insert(.xhigh);
    profile.builtin_tools = model.ModelProfile.BuiltinToolSet.initMany(&.{
        .web_search,
        .x_search,
        .code_execution,
        .file_search,
        .remote_mcp,
    });
    profile.content_types = model.ModelProfile.ContentTypeSet.initMany(&.{.image});
    return profile;
}

/// xAI language models served through OpenAI-compatible Chat Completions.
pub fn xAIChat(model_name: []const u8) ?model.ModelProfile {
    var profile = xAIResponses(model_name) orelse return null;
    profile.supports_truncation = false;
    profile.supports_thinking = false;
    profile.extra_body_kind = .openai_compatible;
    profile.builtin_tools = model.ModelProfile.BuiltinToolSet.initEmpty();
    return profile;
}

/// OpenAI model IDs exposed by Amazon Bedrock Mantle.
pub fn bedrock(model_name: []const u8) ?model.ModelProfile {
    if (!startsWith(model_name, "openai.")) return null;
    const family_name = model_name["openai.".len..];
    if (startsWith(family_name, "gpt-oss")) return familyProfile(.harmony, family_name);
    return familyProfile(.openai, family_name);
}

/// Model families exposed through the native Amazon Bedrock Converse API.
/// Converse normalizes a deliberately smaller setting surface than Chat
/// Completions; model-specific extensions belong in the Bedrock extra body.
pub fn bedrockConverse(model_name: []const u8) ?model.ModelProfile {
    const family: Family = if (std.mem.indexOf(u8, model_name, "anthropic.") != null)
        .anthropic
    else if (std.mem.indexOf(u8, model_name, "amazon.") != null)
        .amazon
    else if (std.mem.indexOf(u8, model_name, "cohere.") != null)
        .cohere
    else if (std.mem.indexOf(u8, model_name, "deepseek.") != null)
        .deepseek
    else if (std.mem.indexOf(u8, model_name, "meta.") != null or
        std.mem.indexOf(u8, model_name, "meta-llama.") != null)
        .meta
    else if (std.mem.indexOf(u8, model_name, "mistral.") != null or
        std.mem.indexOf(u8, model_name, "mistralai.") != null)
        .mistral
    else
        return null;
    var profile = familyProfile(family, model_name);
    profile.supports_json_schema_output = false;
    profile.supports_json_object_output = false;
    profile.supports_streaming = false;
    profile.supports_seed = false;
    profile.supports_top_k = false;
    profile.supports_presence_penalty = false;
    profile.supports_frequency_penalty = false;
    profile.supports_logprobs = false;
    profile.supports_parallel_tool_call_setting = false;
    profile.supports_thinking_budget = false;
    profile.supports_request_headers = true;
    profile.extra_body_kind = .bedrock;
    profile.reasoning_efforts = model.ModelProfile.ReasoningEffortSet.initEmpty();
    profile.service_tiers = model.ModelProfile.ServiceTierSet.initMany(&.{ .auto, .default });
    profile.content_types = model.ModelProfile.ContentTypeSet.initEmpty();
    if (family == .anthropic and (std.mem.indexOf(u8, model_name, "claude-sonnet-4-5") != null or
        std.mem.indexOf(u8, model_name, "claude-sonnet-4-6") != null or
        std.mem.indexOf(u8, model_name, "claude-haiku-4-5") != null or
        std.mem.indexOf(u8, model_name, "claude-opus-4-5") != null or
        std.mem.indexOf(u8, model_name, "claude-opus-4-6") != null))
    {
        profile.supports_json_schema_output = true;
    }
    if (family == .anthropic and std.mem.indexOf(u8, model_name, "claude-sonnet-4-6") != null) {
        profile.service_tiers.insert(.priority);
    }
    if (family == .meta or family == .mistral or family == .deepseek) {
        profile.supports_tools = false;
        profile.supports_parallel_tool_calls = false;
        profile.supports_tool_choice = false;
    }
    return profile;
}

pub fn cerebras(model_name: []const u8) ?model.ModelProfile {
    const family: Family = if (startsWith(model_name, "llama"))
        .meta
    else if (startsWith(model_name, "qwen"))
        .qwen
    else if (startsWith(model_name, "gpt-oss"))
        .harmony
    else if (startsWith(model_name, "zai"))
        .zai
    else
        return null;
    var profile = familyProfile(family, model_name);
    profile.supports_parallel_tool_calls = false;
    profile.supports_parallel_tool_call_setting = false;
    profile.supports_presence_penalty = false;
    profile.supports_frequency_penalty = false;
    return profile;
}

pub fn cohere(model_name: []const u8) ?model.ModelProfile {
    if (!startsWith(model_name, "command") and !startsWith(model_name, "c4ai-command")) return null;
    return familyProfile(.cohere, model_name);
}

pub fn deepseek(model_name: []const u8) ?model.ModelProfile {
    if (!startsWith(model_name, "deepseek-")) return null;
    return familyProfile(.deepseek, model_name);
}

pub fn doubleword(model_name: []const u8) ?model.ModelProfile {
    const routed = routedProfile(model_name, '/') orelse return null;
    if (startsWith(model_name, "openai/gpt-oss")) return familyProfile(.harmony, model_name["openai/".len..]);
    return routed;
}

pub fn groq(model_name: []const u8) ?model.ModelProfile {
    var profile = if (routedProfile(model_name, '/')) |routed|
        if (startsWith(model_name, "openai/gpt-oss")) familyProfile(.harmony, model_name["openai/".len..]) else routed
    else if (startsWith(model_name, "llama") or startsWith(model_name, "meta-llama"))
        familyProfile(.meta, model_name)
    else if (startsWith(model_name, "gemma"))
        familyProfile(.google, model_name)
    else if (startsWith(model_name, "qwen"))
        familyProfile(.qwen, model_name)
    else if (startsWith(model_name, "deepseek"))
        familyProfile(.deepseek, model_name)
    else if (startsWith(model_name, "mistral"))
        familyProfile(.mistral, model_name)
    else if (startsWith(model_name, "compound-") or startsWith(model_name, "groq/compound"))
        openai_compatible.basic
    else
        return null;
    profile.supports_presence_penalty = false;
    profile.supports_frequency_penalty = false;
    profile.supports_logprobs = false;
    return profile;
}

pub fn huggingFace(model_name: []const u8) ?model.ModelProfile {
    return routedProfile(model_name, '/');
}

pub fn mistral(model_name: []const u8) ?model.ModelProfile {
    if (!startsWith(model_name, "mistral") and !startsWith(model_name, "ministral") and
        !startsWith(model_name, "magistral") and !startsWith(model_name, "codestral")) return null;
    return familyProfile(.mistral, model_name);
}

/// Mistral language models served through the native Conversations API.
pub fn mistralConversations(model_name: []const u8) ?model.ModelProfile {
    var profile = mistral(model_name) orelse return null;
    profile.supports_parallel_tool_calls = false;
    profile.supports_streaming = true;
    profile.supports_logprobs = false;
    profile.supports_parallel_tool_call_setting = false;
    profile.supports_top_k = false;
    profile.supports_thinking_budget = false;
    profile.supports_truncation = false;
    profile.supports_request_headers = true;
    profile.extra_body_kind = .mistral;
    profile.reasoning_efforts = model.ModelProfile.ReasoningEffortSet.initMany(&.{
        .none,
        .minimal,
        .low,
        .medium,
        .high,
        .xhigh,
    });
    profile.builtin_tools = model.ModelProfile.BuiltinToolSet.initMany(&.{ .web_search, .code_execution });
    return profile;
}

pub fn openRouter(model_name: []const u8) ?model.ModelProfile {
    return routedProfile(model_name, '/');
}

/// Model families commonly installed from the Ollama library. Tags and
/// namespaces select artifacts, not capability families.
pub fn ollama(model_name: []const u8) ?model.ModelProfile {
    var family_name = model_name;
    if (std.mem.lastIndexOfScalar(u8, family_name, '/')) |separator| family_name = family_name[separator + 1 ..];
    if (std.mem.indexOfScalar(u8, family_name, ':')) |tag| family_name = family_name[0..tag];
    var profile = if (startsWith(family_name, "gpt-oss"))
        familyProfile(.harmony, family_name)
    else if (startsWith(family_name, "llama") or startsWith(family_name, "meta-llama"))
        familyProfile(.meta, family_name)
    else if (startsWith(family_name, "gemma"))
        familyProfile(.google, family_name)
    else if (startsWith(family_name, "qwen"))
        familyProfile(.qwen, family_name)
    else if (startsWith(family_name, "deepseek"))
        familyProfile(.deepseek, family_name)
    else if (startsWith(family_name, "mistral") or startsWith(family_name, "ministral"))
        familyProfile(.mistral, family_name)
    else if (startsWith(family_name, "command") or startsWith(family_name, "c4ai-command"))
        familyProfile(.cohere, family_name)
    else
        return null;
    profile.supports_json_schema_output = true;
    profile.supports_json_object_output = true;
    profile.supports_parallel_tool_calls = false;
    profile.supports_parallel_tool_call_setting = false;
    return profile;
}

pub fn ovhcloud(model_name: []const u8) ?model.ModelProfile {
    if (startsWith(model_name, "llama") or startsWith(model_name, "meta-")) return familyProfile(.meta, model_name);
    if (startsWith(model_name, "deepseek")) return familyProfile(.deepseek, model_name);
    if (startsWith(model_name, "mistral")) return familyProfile(.mistral, model_name);
    if (startsWith(model_name, "gpt-oss")) return familyProfile(.harmony, model_name);
    if (startsWith(model_name, "qwen")) return familyProfile(.qwen, model_name);
    return null;
}

pub fn pydanticGateway(model_name: []const u8) ?model.ModelProfile {
    return routedProfile(model_name, ':') orelse routedProfile(model_name, '/');
}

pub fn together(model_name: []const u8) ?model.ModelProfile {
    const routed = routedProfile(model_name, '/') orelse return null;
    if (startsWith(model_name, "openai/gpt-oss")) return familyProfile(.harmony, model_name["openai/".len..]);
    return routed;
}

test "compatible baselines remain ordered by capability" {
    try std.testing.expect(openai_compatible.full.supports_json_schema_output);
    try std.testing.expect(!openai_compatible.basic.supports_parallel_tool_calls);
    try std.testing.expect(!openai_compatible.minimal.supports_tools);
    try std.testing.expect(!openai_compatible.unknown.supports_temperature);
}

test "named compatible providers resolve known families and reject unknown ones" {
    try std.testing.expect(azureOpenAI("gpt-4o").?.supports_json_schema_output);
    try std.testing.expect(!azureOpenAI("o3").?.supports_temperature);
    try std.testing.expect(!azureOpenAI("DeepSeek-V4-Flash").?.supports_tool_choice);
    try std.testing.expect(azureOpenAI("mistral-small").?.supports_tools);
    try std.testing.expect(azureOpenAI("cohere-command").?.supports_tools);
    try std.testing.expect(!azureOpenAI("grok-4").?.supports_seed);
    try std.testing.expect(azureOpenAI("meta-llama").?.supports_tools);
    try std.testing.expect(azureOpenAI("unknown") == null);
    try std.testing.expect(xAIResponses("grok-4.6").?.supportsBuiltinTool(.x_search));
    try std.testing.expect(xAIResponses("grok-4.20-multi-agent").?.supportsReasoningEffort(.xhigh));
    try std.testing.expectEqual(model.ExtraBodyKind.xai, xAIResponses("latest").?.extra_body_kind.?);
    try std.testing.expectEqual(model.ExtraBodyKind.openai_compatible, xAIChat("grok-4.6").?.extra_body_kind.?);
    try std.testing.expect(!xAIChat("grok-4.6").?.supportsBuiltinTool(.remote_mcp));
    try std.testing.expect(xAIResponses("not-grok") == null);

    try std.testing.expect(ollama("gpt-oss:20b").?.supportsReasoningEffort(.medium));
    try std.testing.expect(ollama("library/llama3.2:latest").?.supports_json_schema_output);
    try std.testing.expect(ollama("gemma3").?.supports_json_object_output);
    try std.testing.expect(!ollama("qwen3").?.supports_parallel_tool_calls);
    try std.testing.expect(!ollama("deepseek-r1").?.supports_temperature);
    try std.testing.expect(ollama("mistral-small").?.supports_tools);
    try std.testing.expect(ollama("ministral-3").?.supports_tools);
    try std.testing.expect(ollama("command-r").?.supports_tools);
    try std.testing.expect(ollama("c4ai-command-r7b").?.supports_tools);
    try std.testing.expect(ollama("unknown") == null);

    try std.testing.expect(bedrock("openai.gpt-oss-20b").?.supportsReasoningEffort(.medium));
    try std.testing.expect(bedrock("openai.gpt-5.4").?.supportsReasoningEffort(.high));
    try std.testing.expect(bedrock("anthropic.claude") == null);
    try std.testing.expect(bedrockConverse("us.anthropic.claude-sonnet-4-6").?.supports_tools);
    try std.testing.expect(!bedrockConverse("amazon.nova-pro-v1:0").?.supports_json_schema_output);
    try std.testing.expect(bedrockConverse("global.anthropic.claude-opus-4-6").?.supports_json_schema_output);
    try std.testing.expect(bedrockConverse("us.anthropic.claude-sonnet-4-6").?.supportsServiceTier(.priority));
    try std.testing.expect(!bedrockConverse("meta.llama3-3-70b-instruct-v1:0").?.supports_streaming);
    try std.testing.expect(!bedrockConverse("meta.llama3-3-70b-instruct-v1:0").?.supports_tools);
    try std.testing.expect(bedrockConverse("unknown.model") == null);

    try std.testing.expect(!cerebras("gpt-oss-120b").?.supports_parallel_tool_call_setting);
    try std.testing.expect(cerebras("llama-3.3").?.supports_tools);
    try std.testing.expect(cerebras("qwen-3").?.supports_tools);
    try std.testing.expect(cerebras("zai-glm").?.supports_tools);
    try std.testing.expect(cerebras("unknown") == null);
    try std.testing.expect(cohere("command-a").?.supports_tools);
    try std.testing.expect(cohere("unknown") == null);
    try std.testing.expect(!deepseek("deepseek-reasoner").?.supports_temperature);
    try std.testing.expect(deepseek("other") == null);

    try std.testing.expect(doubleword("openai/gpt-oss-20b").?.supportsReasoningEffort(.low));
    try std.testing.expect(doubleword("anthropic/claude-sonnet-4").?.supports_tools);
    try std.testing.expect(doubleword("unknown/model") == null);
    try std.testing.expect(!groq("openai/gpt-oss-20b").?.supports_logprobs);
    try std.testing.expect(groq("llama-3.3").?.supports_tools);
    try std.testing.expect(groq("gemma2").?.supports_tools);
    try std.testing.expect(groq("qwen-3").?.supports_tools);
    try std.testing.expect(groq("deepseek-r1").?.supports_tools);
    try std.testing.expect(groq("mistral-small").?.supports_tools);
    try std.testing.expect(groq("compound-beta").?.supports_tools);
    try std.testing.expect(groq("unknown") == null);

    try std.testing.expect(huggingFace("CohereLabs/c4ai-command-r7b").?.supports_tools);
    try std.testing.expect(huggingFace("unknown/model") == null);
    try std.testing.expect(mistral("codestral-latest").?.supports_tools);
    try std.testing.expect(mistral("unknown") == null);
    try std.testing.expect(openRouter("~anthropic/claude-sonnet-4:free").?.supports_tools);
    try std.testing.expect(openRouter("google/gemini-2.5-pro").?.supports_tools);
    try std.testing.expect(openRouter("unknown/model") == null);

    try std.testing.expect(ovhcloud("gpt-oss-120b").?.supportsReasoningEffort(.high));
    try std.testing.expect(ovhcloud("llama-3").?.supports_tools);
    try std.testing.expect(ovhcloud("deepseek-r1").?.supports_tools);
    try std.testing.expect(ovhcloud("mistral-small").?.supports_tools);
    try std.testing.expect(ovhcloud("qwen-3").?.supports_tools);
    try std.testing.expect(ovhcloud("unknown") == null);
    try std.testing.expect(pydanticGateway("openai:gpt-4o").?.supports_json_schema_output);
    try std.testing.expect(pydanticGateway("anthropic/claude-sonnet-4").?.supports_tools);
    try std.testing.expect(pydanticGateway("unknown") == null);
    try std.testing.expect(together("openai/gpt-oss-20b").?.supportsReasoningEffort(.medium));
    try std.testing.expect(together("meta-llama/Llama-3.3").?.supports_tools);
    try std.testing.expect(together("unknown/model") == null);
}
