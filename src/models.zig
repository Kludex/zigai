//! Provider-neutral model composition.

pub const fallback = @import("models/fallback.zig");
pub const selector = @import("models/selector.zig");

pub const Fallback = fallback.Fallback;
pub const FallbackEvent = fallback.Event;
pub const Selector = selector.Selector;
pub const SelectionContext = selector.Context;

test {
    _ = fallback;
    _ = selector;
}
