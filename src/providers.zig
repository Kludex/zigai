//! First-party provider adapters.
//!
//! Providers own authentication, endpoints, policy, and provider operations.
//! Model clients own wire encoding and expose the provider-neutral `Model`
//! consumed by `Agent`.

const std = @import("std");
const agent = @import("agent.zig");
const model = @import("model.zig");
const transport = @import("transport.zig");

pub const openai = @import("providers/openai.zig");
pub const http = @import("providers/http.zig");
pub const profiles = @import("providers/profiles.zig");
pub const openai_compatible = @import("providers/openai_compatible.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const azure_openai = @import("providers/azure_openai.zig");
pub const bedrock = @import("providers/bedrock.zig");
pub const cerebras = @import("providers/cerebras.zig");
pub const cohere = @import("providers/cohere/root.zig");
pub const crusoe = @import("providers/crusoe.zig");
pub const deepseek = @import("providers/deepseek.zig");
pub const doubleword = @import("providers/doubleword.zig");
pub const google = @import("providers/google.zig");
pub const groq = @import("providers/groq.zig");
pub const huggingface = @import("providers/huggingface.zig");
pub const mistral = @import("providers/mistral/root.zig");
pub const ollama = @import("providers/ollama.zig");
pub const openrouter = @import("providers/openrouter.zig");
pub const ovhcloud = @import("providers/ovhcloud.zig");
pub const pydantic_gateway = @import("providers/pydantic_gateway.zig");
pub const snowflake = @import("providers/snowflake.zig");
pub const together = @import("providers/together.zig");
pub const vertex_ai = @import("providers/vertex_ai.zig");
pub const xai = @import("providers/xai.zig");

const TestTransport = struct {
    calls: usize = 0,

    fn send(context: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.UnexpectedRequest;
    }
};

test {
    _ = openai;
    _ = http;
    _ = profiles;
    _ = openai_compatible;
    _ = anthropic;
    _ = azure_openai;
    _ = bedrock;
    _ = cerebras;
    _ = cohere;
    _ = crusoe;
    _ = deepseek;
    _ = doubleword;
    _ = google;
    _ = groq;
    _ = huggingface;
    _ = mistral;
    _ = ollama;
    _ = openrouter;
    _ = ovhcloud;
    _ = pydantic_gateway;
    _ = snowflake;
    _ = together;
    _ = vertex_ai;
    _ = xai;
}

fn namedCompatibleProfile(comptime ProviderType: type, comptime ClientType: type, model_name: []const u8) model.ModelProfile {
    var transport_state: TestTransport = .{};
    var provider_state = ProviderType.init("unused", .{ .context = &transport_state, .sendFn = TestTransport.send });
    var client = ClientType{
        .model_name = model_name,
        .provider = provider_state.provider(),
    };
    return client.model().profile;
}

test "named compatible clients use their provider model profiles" {
    try std.testing.expect(namedCompatibleProfile(azure_openai.Provider, azure_openai.Client, "gpt-4o").supports_json_schema_output);
    try std.testing.expect(namedCompatibleProfile(bedrock.MantleProvider, bedrock.MantleClient, "openai.gpt-oss-20b").supportsReasoningEffort(.medium));
    try std.testing.expect(!namedCompatibleProfile(cerebras.Provider, cerebras.Client, "gpt-oss-120b").supports_parallel_tool_calls);
    try std.testing.expect(namedCompatibleProfile(cohere.Provider, cohere.Client, "command-a-plus").supports_tools);
    try std.testing.expect(namedCompatibleProfile(crusoe.Provider, crusoe.Client, "openai/gpt-oss-120b").supportsReasoningEffort(.high));
    try std.testing.expect(!namedCompatibleProfile(deepseek.Provider, deepseek.Client, "deepseek-v4-flash").supports_temperature);
    try std.testing.expect(namedCompatibleProfile(doubleword.Provider, doubleword.Client, "openai/gpt-oss-20b").supportsReasoningEffort(.high));
    try std.testing.expect(!namedCompatibleProfile(groq.Provider, groq.Client, "openai/gpt-oss-20b").supports_logprobs);
    try std.testing.expect(namedCompatibleProfile(huggingface.Provider, huggingface.Client, "CohereLabs/c4ai-command-r7b").supports_tools);
    try std.testing.expect(namedCompatibleProfile(mistral.Provider, mistral.Client, "mistral-small-latest").supports_tools);
    try std.testing.expect(namedCompatibleProfile(openrouter.Provider, openrouter.Client, "openai/gpt-4o-mini").supports_json_schema_output);
    try std.testing.expect(namedCompatibleProfile(ovhcloud.Provider, ovhcloud.Client, "qwen-3").supports_tools);
    try std.testing.expect(namedCompatibleProfile(pydantic_gateway.Provider, pydantic_gateway.Client, "openai:gpt-4o").supports_json_object_output);
    try std.testing.expect(namedCompatibleProfile(snowflake.Provider, snowflake.Client, "claude-sonnet-4-5").supports_json_schema_output);
    try std.testing.expect(namedCompatibleProfile(together.Provider, together.Client, "openai/gpt-oss-20b").supportsReasoningEffort(.low));
    try std.testing.expect(namedCompatibleProfile(xai.ChatProvider, xai.ChatClient, "grok-4.6").supports_tools);

    const unknown = namedCompatibleProfile(groq.Provider, groq.Client, "future-model");
    try std.testing.expect(!unknown.supports_tools);
    try std.testing.expect(!unknown.supports_temperature);
}

test "named compatible profiles reject unsupported requests before transport" {
    const Tool = struct {
        fn execute(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            return allocator.dupe(u8, "ok");
        }
    };

    var transport_state: TestTransport = .{};
    const counting_transport = transport.Transport{ .context = &transport_state, .sendFn = TestTransport.send };
    try std.testing.expectError(error.UnexpectedRequest, counting_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = "https://example.test",
    }));
    try std.testing.expectEqual(@as(usize, 1), transport_state.calls);
    transport_state.calls = 0;
    var deepseek_provider = deepseek.Provider.init("unused", counting_transport);
    var deepseek_client = deepseek.Client{
        .model_name = "deepseek-v4-flash",
        .provider = deepseek_provider.provider(),
    };
    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportTemperature, (agent.Agent{
        .model = deepseek_client.model(),
        .model_settings = .{ .temperature = 0.2 },
    }).run(std.testing.allocator, "hello"));

    var crusoe_provider = crusoe.Provider.init("unused", counting_transport);
    var crusoe_client = crusoe.Client{
        .model_name = "private/deployment",
        .provider = crusoe_provider.provider(),
    };
    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportTemperature, (agent.Agent{
        .model = crusoe_client.model(),
        .model_settings = .{ .temperature = 0.2 },
    }).run(std.testing.allocator, "hello"));

    var groq_provider = groq.Provider.init("unused", counting_transport);
    var groq_client = groq.Client{
        .model_name = "future-model",
        .provider = groq_provider.provider(),
    };
    var tool_marker: u8 = 0;
    const tool = model.Tool{
        .definition = .{
            .name = "lookup",
            .description = "Look up a value.",
            .parameters_json_schema = "{\"type\":\"object\"}",
        },
        .context = &tool_marker,
        .executeFn = Tool.execute,
    };
    const tool_output = try tool.execute(std.testing.allocator, "{}");
    defer std.testing.allocator.free(tool_output);
    try std.testing.expectEqualStrings("ok", tool_output);

    var snowflake_provider = snowflake.Provider.initWithOptions("unused", counting_transport, .{
        .base_url = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1",
    });
    var snowflake_client = snowflake.Client{
        .model_name = "private-model",
        .provider = snowflake_provider.provider(),
    };
    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportTools, (agent.Agent{
        .model = snowflake_client.model(),
        .tools = &.{tool},
    }).run(std.testing.allocator, "hello"));

    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportTools, (agent.Agent{
        .model = groq_client.model(),
        .tools = &.{tool},
    }).run(std.testing.allocator, "hello"));

    var azure_provider = azure_openai.Provider.init("unused", counting_transport);
    var azure_client = azure_openai.Client{
        .model_name = "gpt-4o",
        .provider = azure_provider.provider(),
    };
    const image = model.PromptPart{ .image = .{
        .source = .{ .bytes = "not-an-image" },
        .media_type = "image/png",
    } };
    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportImages, (agent.Agent{
        .model = azure_client.model(),
    }).runWithOptions(std.testing.allocator, "hello", .{ .prompt_parts = &.{image} }));
    try std.testing.expectEqual(@as(usize, 0), transport_state.calls);
}
