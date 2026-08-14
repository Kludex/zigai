//! Provider-neutral building blocks for tool-using LLM agents.

pub const model = @import("model.zig");
pub const agent = @import("agent.zig");
pub const testing = @import("testing.zig");
pub const transport = @import("transport.zig");
pub const vcr = @import("vcr.zig");
pub const json_schema = @import("json_schema.zig");
pub const reflect = @import("reflect.zig");
pub const providers = @import("providers.zig");
// Compatibility aliases for the original top-level provider imports.
pub const openai = providers.openai;
pub const openai_compatible = providers.openai_compatible;
pub const anthropic = providers.anthropic;
pub const google = providers.google;

pub const Agent = agent.Agent;
pub const CancellationToken = agent.CancellationToken;
pub const AgentStreamEvent = agent.AgentStreamEvent;
pub const AgentStreamSink = agent.AgentStreamSink;
pub const Instruction = agent.Instruction;
pub const InstructionContext = agent.InstructionContext;
pub const RunOptions = agent.RunOptions;
pub const Model = model.Model;
pub const ModelProfile = model.ModelProfile;
pub const Tool = model.Tool;
pub const ToolRunContext = model.ToolRunContext;
pub const ModelStreamEvent = model.ModelStreamEvent;
pub const ModelStreamSink = model.ModelStreamSink;

test {
    _ = @import("agent.zig");
    _ = @import("model.zig");
    _ = @import("testing.zig");
    _ = @import("transport.zig");
    _ = @import("vcr.zig");
    _ = @import("json_schema.zig");
    _ = @import("reflect.zig");
    _ = @import("providers.zig");
}
