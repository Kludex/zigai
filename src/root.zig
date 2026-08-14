//! Provider-neutral building blocks for tool-using LLM agents.

pub const model = @import("model.zig");
pub const agent = @import("agent.zig");
pub const testing = @import("testing.zig");
pub const transport = @import("transport.zig");
pub const json_schema = @import("json_schema.zig");
pub const reflect = @import("reflect.zig");
pub const history = @import("history.zig");
pub const providers = @import("providers.zig");
pub const models = @import("models.zig");
pub const telemetry = @import("telemetry.zig");
pub const mcp = @import("mcp.zig");
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
pub const TypedResult = agent.TypedResult;
pub const Capability = agent.Capability;
pub const CapabilityContext = agent.CapabilityContext;
pub const LifecycleEvent = agent.LifecycleEvent;
pub const LifecycleHook = agent.LifecycleHook;
pub const HistoryProcessor = history.Processor;
pub const HistoryContext = history.Context;
pub const OwnedHistory = history.Owned;
pub const OpenTelemetry = telemetry.OpenTelemetry;
pub const TelemetryExporter = telemetry.Exporter;
pub const TelemetrySpan = telemetry.Span;
pub const TelemetryMetric = telemetry.Metric;
pub const Toolset = agent.Toolset;
pub const ToolsetContext = agent.ToolsetContext;
pub const ToolsetEntry = agent.ToolsetEntry;
pub const Model = model.Model;
pub const ModelProfile = model.ModelProfile;
pub const ModelSettings = model.ModelSettings;
pub const ReasoningEffort = model.ReasoningEffort;
pub const FinishReason = model.FinishReason;
pub const Tool = model.Tool;
pub const ToolMetadata = model.ToolMetadata;
pub const ToolRunContext = model.ToolRunContext;
pub const ModelStreamEvent = model.ModelStreamEvent;
pub const ModelStreamSink = model.ModelStreamSink;

test {
    _ = @import("agent.zig");
    _ = @import("model.zig");
    _ = @import("testing.zig");
    _ = @import("transport.zig");
    _ = @import("json_schema.zig");
    _ = @import("reflect.zig");
    _ = @import("history.zig");
    _ = @import("providers.zig");
    _ = @import("models.zig");
    _ = @import("telemetry.zig");
    _ = @import("mcp.zig");
}
