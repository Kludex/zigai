//! Versioned provider-neutral wire documents used by durable workers.

pub const event = @import("event.zig");
pub const model = @import("model.zig");
pub const mcp = @import("mcp.zig");
pub const tool = @import("tool.zig");

test {
    _ = event;
    _ = model;
    _ = mcp;
    _ = tool;
}
