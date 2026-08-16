//! Azure OpenAI Realtime connector over the shared OpenAI protocol.

const std = @import("std");
const openai = @import("openai.zig");
const wire = @import("wire.zig");

pub const Connector = openai.Connector;

/// Creates an Azure OpenAI realtime connector for an authenticated raw channel.
pub fn init(dialer: wire.Dialer, deployment: []const u8) Connector {
    return .{
        .dialer = dialer,
        .dialect = .azure,
        .model_name = deployment,
    };
}

test "Azure constructor selects the shared protocol dialect" {
    var marker: u8 = 0;
    const connector = init(.{ .context = &marker, .open_fn = undefined }, "deployment");
    try std.testing.expectEqual(openai.Dialect.azure, connector.dialect);
}
