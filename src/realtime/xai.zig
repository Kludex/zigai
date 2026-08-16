//! xAI Grok Voice connector over the shared OpenAI realtime protocol.

const std = @import("std");
const openai = @import("openai.zig");
const wire = @import("wire.zig");

pub const Connector = openai.Connector;

/// Creates an xAI realtime connector with native reconnect state restoration.
pub fn init(dialer: wire.Dialer, model_name: []const u8) Connector {
    return .{
        .dialer = dialer,
        .dialect = .xai,
        .model_name = model_name,
    };
}

test "xAI constructor selects native resumption dialect" {
    var marker: u8 = 0;
    const connector = init(.{ .context = &marker, .open_fn = undefined }, "grok-voice");
    try std.testing.expectEqual(openai.Dialect.xai, connector.dialect);
}
