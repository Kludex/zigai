const provider = @import("zigai").providers.openai_compatible;

pub const api_base = provider.api_base;
pub const profiles = provider.profiles;
pub const Error = provider.Error;
pub const Client = provider.Client;
pub const encodeRequest = provider.encodeRequest;
pub const encodeStreamingRequest = provider.encodeStreamingRequest;
pub const decodeResponse = provider.decodeResponse;
