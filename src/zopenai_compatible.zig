const provider = @import("zigai").providers.openai_compatible;

pub const api_base = provider.api_base;
pub const profiles = provider.profiles;
pub const Error = provider.Error;
pub const Authentication = provider.Authentication;
pub const ClientDefaults = provider.ClientDefaults;
pub const ProviderWithDefaults = provider.ProviderWithDefaults;
pub const ClientWithDefaults = provider.ClientWithDefaults;
pub const Provider = provider.Provider;
pub const Client = provider.Client;
pub const encodeRequest = provider.encodeRequest;
pub const encodeStreamingRequest = provider.encodeStreamingRequest;
pub const decodeResponse = provider.decodeResponse;
