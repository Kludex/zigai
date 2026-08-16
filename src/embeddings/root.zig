//! Provider-neutral embedding execution and provider wire adapters.

pub const base = @import("base.zig");
pub const openai = @import("openai.zig");
pub const google = @import("google.zig");

pub const cosineSimilarity = base.cosineSimilarity;
pub const BatchResult = base.BatchResult;
pub const Embedder = base.Embedder;
pub const Error = base.Error;
pub const InputType = base.InputType;
pub const Limits = base.Limits;
pub const Model = base.Model;
pub const Options = base.Options;
pub const Request = base.Request;
pub const Result = base.Result;
pub const RetryEvent = base.RetryEvent;
pub const RetryHook = base.RetryHook;
pub const RetryPolicy = base.RetryPolicy;

test {
    _ = base;
    _ = openai;
    _ = google;
}
