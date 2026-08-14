//! First-party provider adapters.
//!
//! Providers own authentication, endpoints, and wire formats. Each client
//! exposes the provider-neutral `Model` consumed by `Agent`.

pub const openai = @import("providers/openai.zig");
pub const openai_compatible = @import("providers/openai_compatible.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const google = @import("providers/google.zig");

test {
    _ = openai;
    _ = openai_compatible;
    _ = anthropic;
    _ = google;
}
