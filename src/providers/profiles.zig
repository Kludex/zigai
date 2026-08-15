//! Provider and model-family capability profiles.
//!
//! This module contains capability knowledge only. Provider state owns lookup
//! precedence, and model adapters own wire encoding.

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
};

test "compatible baselines remain ordered by capability" {
    try @import("std").testing.expect(openai_compatible.full.supports_json_schema_output);
    try @import("std").testing.expect(!openai_compatible.basic.supports_parallel_tool_calls);
    try @import("std").testing.expect(!openai_compatible.minimal.supports_tools);
}
