//! Versioned provider-neutral wire documents used by durable workers.

pub const model = @import("model.zig");
pub const mcp = @import("mcp.zig");
pub const tool = @import("tool.zig");

test {
    _ = model;
    _ = mcp;
    _ = tool;
}
