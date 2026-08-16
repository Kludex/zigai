//! Provider-neutral realtime sessions and provider protocol adapters.

pub const base = @import("base.zig");

pub const AudioRetention = base.AudioRetention;
pub const CodecEvent = base.CodecEvent;
pub const Connection = base.Connection;
pub const Connector = base.Connector;
pub const Event = base.Event;
pub const Input = base.Input;
pub const Limits = base.Limits;
pub const Options = base.Options;
pub const OwnedCodecEvent = base.OwnedCodecEvent;
pub const OwnedEvent = base.OwnedEvent;
pub const OwnedHistory = base.OwnedHistory;
pub const Profile = base.Profile;
pub const ReconnectPolicy = base.ReconnectPolicy;
pub const Session = base.Session;
pub const ToolHandler = base.ToolHandler;
pub const ToolResult = base.ToolResult;
pub const TransportKind = base.TransportKind;

test {
    _ = base;
}
