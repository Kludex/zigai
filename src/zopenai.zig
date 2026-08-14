const provider = @import("zigai").providers.openai;

pub const api_base = provider.api_base;
pub const Error = provider.Error;
pub const Client = provider.Client;
pub const encodeRequest = provider.encodeRequest;
pub const encodeStreamingRequest = provider.encodeStreamingRequest;
pub const decodeResponse = provider.decodeResponse;
