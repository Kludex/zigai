//! Browser UI stream adapters for AG-UI and Vercel AI SDK UI message streams.

pub const base = @import("base.zig");
pub const ag_ui = @import("ag_ui.zig");
pub const vercel = @import("vercel.zig");

pub const ApprovalDecision = base.ApprovalDecision;
pub const Bridge = base.Bridge;
pub const Event = base.Event;
pub const Limits = base.Limits;
pub const OwnedApprovalDecision = base.OwnedApprovalDecision;
pub const ReplayBuffer = base.ReplayBuffer;
pub const ReplaySink = base.ReplaySink;
pub const SanitizePolicy = base.SanitizePolicy;
pub const SanitizedMessages = base.SanitizedMessages;
pub const Sink = base.Sink;
pub const customValue = base.customValue;
pub const sanitizeMessages = base.sanitizeMessages;

test {
    _ = base;
    _ = ag_ui;
    _ = vercel;
}
