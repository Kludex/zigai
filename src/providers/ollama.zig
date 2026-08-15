//! Ollama client through its OpenAI-compatible Chat Completions endpoint.

const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");

pub const api_base = "http://localhost:11434/v1";

/// Deliberate opt-in for Ollama's cleartext loopback endpoint.
pub const local_request_policy: provider_types.RequestPolicy = .{
    .url_policy = .{
        .allow_http = true,
        .allow_local_network = true,
        .allowed_hosts = &.{"localhost"},
    },
};

const defaults: compatible.ClientDefaults = .{
    .base_url = api_base,
    .provider_name = "ollama",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.ollama,
    .authentication = null,
    .request_policy = local_request_policy,
};

const CompatibleProvider = compatible.ProviderWithDefaults(defaults);

/// Unauthenticated provider state for a local Ollama server.
pub const Provider = struct {
    inner: CompatibleProvider,

    pub const Options = CompatibleProvider.Options;

    pub fn init(http_transport: transport.Transport) Provider {
        return .{ .inner = CompatibleProvider.init("", http_transport) };
    }

    pub fn initWithOptions(http_transport: transport.Transport, options: Options) Provider {
        return .{ .inner = CompatibleProvider.initWithOptions("", http_transport, options) };
    }

    pub fn provider(self: *Provider) provider_types.Provider {
        return self.inner.provider();
    }
};

pub const Client = compatible.ClientWithDefaults(defaults);

test "Ollama provider is unauthenticated and local by explicit policy" {
    const std = @import("std");
    const Stub = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, request: transport.Request) !transport.Response {
            try std.testing.expectEqualStrings("http://localhost:11434/v1/models", request.url);
            try std.testing.expectEqual(@as(usize, 0), request.headers.len);
            return error.UnexpectedRequest;
        }
    };
    var marker: u8 = 0;
    var state = Provider.init(.{ .context = &marker, .sendFn = Stub.send });
    const provider = state.provider();
    try provider.validate();
    try std.testing.expectEqualStrings("ollama", provider.name);
    try std.testing.expectError(error.UnexpectedRequest, provider.listModels(std.testing.allocator));
}

test "Ollama options and profiles fail closed before transport" {
    const std = @import("std");
    const agent = @import("../agent.zig");
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.UnexpectedRequest;
        }
    };
    var stub: Stub = .{};
    const counting_transport = transport.Transport{ .context = &stub, .sendFn = Stub.send };
    try std.testing.expectError(error.UnexpectedRequest, counting_transport.send(std.testing.allocator, .{
        .method = .GET,
        .url = api_base,
    }));
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    stub.calls = 0;
    var state = Provider.initWithOptions(counting_transport, .{});
    var known_client = Client{
        .model_name = "gpt-oss:20b",
        .provider = state.provider(),
    };
    try std.testing.expect(known_client.model().profile.supports_tools);

    var unknown_client = Client{
        .model_name = "private-model",
        .provider = state.provider(),
    };
    try std.testing.expectError(agent.Agent.Error.ModelDoesNotSupportTemperature, (agent.Agent{
        .model = unknown_client.model(),
        .model_settings = .{ .temperature = 0.2 },
    }).run(std.testing.allocator, "hello"));
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
}
