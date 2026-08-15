//! Google Cloud Vertex AI provider for the shared Gemini GenerateContent codec.
//!
//! This module owns OAuth bearer authentication, the Vertex API root, and
//! publisher-model resource paths. Request and response encoding stays in the
//! Google Gemini adapter; Vertex does not maintain a second wire codec.

const std = @import("std");
const model_types = @import("../model.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");
const http_provider = @import("http.zig");
const google = @import("google.zig");

pub const api_base = "https://aiplatform.googleapis.com";
pub const access_token_env = "GOOGLE_CLOUD_ACCESS_TOKEN";
pub const project_env = "GOOGLE_CLOUD_PROJECT";
pub const location_env = "GOOGLE_CLOUD_LOCATION";

pub const Error = error{
    /// A project, location, publisher, or model is not a safe resource segment.
    InvalidVertexResource,
    /// The model adapter requested an operation outside Vertex GenerateContent.
    UnsupportedVertexOperation,
};

/// Gemini GenerateContent codec reused with Vertex-owned transport policy.
pub const Client = google.Client;

/// Google Cloud Vertex AI provider state.
///
/// The access token is borrowed and must remain valid for every in-flight
/// request. Recreate the provider after refreshing the token.
pub const Provider = struct {
    http: http_provider.Configured,
    project_id: []const u8,
    location: []const u8,
    publisher: []const u8,
    model_profiles: ?http_provider.Configured.ModelProfiles,

    pub const Options = struct {
        base_url: []const u8 = api_base,
        publisher: []const u8 = "google",
        headers: []const transport.Header = &.{},
        request_policy: provider_types.RequestPolicy = .{},
        model_profiles: ?http_provider.Configured.ModelProfiles = null,
    };

    pub fn init(
        access_token: []const u8,
        project_id: []const u8,
        location: []const u8,
        http_transport: transport.Transport,
    ) Provider {
        return initWithOptions(access_token, project_id, location, http_transport, .{});
    }

    pub fn initWithOptions(
        access_token: []const u8,
        project_id: []const u8,
        location: []const u8,
        http_transport: transport.Transport,
        options: Options,
    ) Provider {
        return .{
            .http = .{
                .name = "gcp.vertex_ai",
                .base_url = options.base_url,
                .transport = http_transport,
                .credential = .{ .bearer = access_token },
                .headers = options.headers,
                .request_policy = options.request_policy,
            },
            .project_id = project_id,
            .location = location,
            .publisher = options.publisher,
            .model_profiles = options.model_profiles,
        };
    }

    pub fn provider(self: *Provider) provider_types.Provider {
        return .{
            .context = self,
            .name = self.http.name,
            .base_url = self.http.base_url,
            .request_policy = self.http.request_policy,
            .file_limits = self.http.file_limits,
            .requestFn = request,
            .streamLinesFn = streamLines,
            .modelProfileFn = if (self.model_profiles != null) modelProfile else null,
            .overrideProfileFn = if (self.model_profiles != null) overrideProfile else null,
            .observeErrorFn = observeError,
        };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: provider_types.Request,
    ) !transport.Response {
        const self: *Provider = @ptrCast(@alignCast(context));
        const endpoint = try self.vertexEndpoint(allocator, value.endpoint);
        defer allocator.free(endpoint);
        var translated = value;
        translated.endpoint = endpoint;
        return self.http.provider().request(allocator, translated);
    }

    fn streamLines(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: provider_types.Request,
        sink: transport.LineSink,
    ) !transport.StreamResponse {
        const self: *Provider = @ptrCast(@alignCast(context));
        const endpoint = try self.vertexEndpoint(allocator, value.endpoint);
        defer allocator.free(endpoint);
        var translated = value;
        translated.endpoint = endpoint;
        return self.http.provider().streamLines(allocator, translated, sink);
    }

    fn modelProfile(context: *anyopaque, model_name: []const u8) ?model_types.ModelProfile {
        const self: *Provider = @ptrCast(@alignCast(context));
        const profiles = self.model_profiles orelse return null;
        const lookup = profiles.lookupFn orelse return null;
        return lookup(profiles.context, model_name);
    }

    fn overrideProfile(
        context: *anyopaque,
        model_name: []const u8,
        profile: model_types.ModelProfile,
    ) model_types.ModelProfile {
        const self: *Provider = @ptrCast(@alignCast(context));
        const profiles = self.model_profiles orelse return profile;
        const apply = profiles.overrideFn orelse return profile;
        return apply(profiles.context, model_name, profile);
    }

    fn observeError(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        status: u16,
        body: []const u8,
        metadata: transport.ResponseMetadata,
        observer: ?model_types.ProviderErrorObserver,
        policy: model_types.ProviderErrorPolicy,
    ) void {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.http.provider().observeError(allocator, status, body, metadata, observer, policy);
    }

    fn vertexEndpoint(self: *const Provider, allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
        try validateResourceSegment(self.project_id);
        try validateResourceSegment(self.location);
        try validateResourceSegment(self.publisher);

        const model_prefix = "/models/";
        if (!std.mem.startsWith(u8, endpoint, model_prefix)) return error.UnsupportedVertexOperation;
        const remainder = endpoint[model_prefix.len..];
        const separator = std.mem.indexOfScalar(u8, remainder, ':') orelse return error.UnsupportedVertexOperation;
        const model_name = remainder[0..separator];
        try validateResourceSegment(model_name);
        const operation = remainder[separator..];
        if (!std.mem.eql(u8, operation, ":generateContent") and
            !std.mem.eql(u8, operation, ":streamGenerateContent?alt=sse"))
            return error.UnsupportedVertexOperation;

        return std.fmt.allocPrint(
            allocator,
            "/v1/projects/{s}/locations/{s}/publishers/{s}/models/{s}{s}",
            .{ self.project_id, self.location, self.publisher, model_name, operation },
        );
    }
};

/// Allocates the regional Vertex API root for `Provider.Options.base_url`.
/// The caller owns the returned slice.
pub fn regionalApiBase(allocator: std.mem.Allocator, location: []const u8) ![]u8 {
    try validateResourceSegment(location);
    if (std.mem.eql(u8, location, "global")) return allocator.dupe(u8, api_base);
    return std.fmt.allocPrint(allocator, "https://{s}-aiplatform.googleapis.com", .{location});
}

fn validateResourceSegment(value: []const u8) error{InvalidVertexResource}!void {
    if (value.len == 0 or value.len > 128) return error.InvalidVertexResource;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
            return error.InvalidVertexResource;
    }
}

test "Vertex provider maps Gemini requests to regional publisher resources" {
    const State = struct {
        buffered: bool = false,
        streamed: bool = false,

        fn authorized(headers: []const transport.Header) bool {
            for (headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization") and
                    std.mem.eql(u8, header.value, "Bearer token"))
                    return header.sensitive;
            }
            return false;
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request_value: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.buffered = true;
            try std.testing.expectEqualStrings(
                "https://europe-west1-aiplatform.googleapis.com/v1/projects/my-project/locations/europe-west1/publishers/google/models/gemini-2.5-flash:generateContent",
                request_value.url,
            );
            try std.testing.expect(authorized(request_value.headers));
            try std.testing.expect(std.mem.indexOf(u8, request_value.body, "\"text\":\"ping\"") != null);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"pong\"}]},\"finishReason\":\"STOP\"}]}"),
            };
        }

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            request_value: transport.Request,
            sink: transport.LineSink,
        ) !transport.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.streamed = true;
            try std.testing.expectEqualStrings(
                "https://europe-west1-aiplatform.googleapis.com/v1/projects/my-project/locations/europe-west1/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
                request_value.url,
            );
            try std.testing.expect(authorized(request_value.headers));
            try sink.start(.{ .status = 200 });
            try sink.line("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"streamed\"}]},\"finishReason\":\"STOP\"}]}");
            return .{ .status = 200 };
        }
    };
    const Sink = struct {
        events: usize = 0,
        fn emit(context: *anyopaque, _: model_types.ModelStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
        }
    };

    const base_url = try regionalApiBase(std.testing.allocator, "europe-west1");
    defer std.testing.allocator.free(base_url);
    var state: State = .{};
    var provider_state = Provider.initWithOptions(
        "token",
        "my-project",
        "europe-west1",
        .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream },
        .{ .base_url = base_url },
    );
    var client = Client{
        .model_name = "gemini-2.5-flash",
        .provider = provider_state.provider(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try client.model().request(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "ping" } }} } }},
    });
    try std.testing.expectEqualStrings("pong", response.parts[0].text);
    try std.testing.expectEqualStrings("gcp.vertex_ai", response.provider_name.?);

    var sink: Sink = .{};
    const streamed = try client.model().stream(arena.allocator(), .{ .messages = &.{} }, .{
        .context = &sink,
        .eventFn = Sink.emit,
    });
    try std.testing.expectEqualStrings("streamed", streamed.parts[0].text);
    try std.testing.expectEqual(@as(usize, 3), sink.events);
    try std.testing.expect(state.buffered);
    try std.testing.expect(state.streamed);
}

test "Vertex provider rejects unsafe resources and unsupported operations" {
    var marker: u8 = 0;
    const http_transport = transport.Transport{
        .context = &marker,
        .sendFn = struct {
            fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
                return error.UnexpectedRequest;
            }
        }.send,
    };
    var provider_state = Provider.init("token", "project", "global", http_transport);
    const provider = provider_state.provider();
    try std.testing.expectError(error.UnsupportedVertexOperation, provider.request(std.testing.allocator, .{
        .method = .GET,
        .endpoint = "/models",
    }));
    try std.testing.expectError(error.UnsupportedVertexOperation, provider.request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/models/gemini:countTokens",
    }));
    try std.testing.expectError(error.InvalidVertexResource, provider.request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/models/bad/model:generateContent",
    }));

    var invalid_project = Provider.init("token", "bad/project", "global", http_transport);
    try std.testing.expectError(error.InvalidVertexResource, invalid_project.provider().request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/models/gemini:generateContent",
    }));
    var invalid_location = Provider.init("token", "project", "", http_transport);
    try std.testing.expectError(error.InvalidVertexResource, invalid_location.provider().request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/models/gemini:generateContent",
    }));
    var invalid_publisher = Provider.initWithOptions("token", "project", "global", http_transport, .{
        .publisher = "bad publisher",
    });
    try std.testing.expectError(error.InvalidVertexResource, invalid_publisher.provider().request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/models/gemini:generateContent",
    }));
    try std.testing.expectError(error.InvalidVertexResource, regionalApiBase(std.testing.allocator, "bad/location"));
    const global = try regionalApiBase(std.testing.allocator, "global");
    defer std.testing.allocator.free(global);
    try std.testing.expectEqualStrings(api_base, global);
}

test "Vertex provider composes application model profiles" {
    const Profiles = struct {
        fn lookup(_: *anyopaque, model_name: []const u8) ?model_types.ModelProfile {
            if (std.mem.eql(u8, model_name, "known")) return .{ .supports_tools = true };
            return null;
        }

        fn apply(_: *anyopaque, _: []const u8, profile: model_types.ModelProfile) model_types.ModelProfile {
            var adjusted = profile;
            adjusted.supports_temperature = false;
            return adjusted;
        }
    };
    var marker: u8 = 0;
    var provider_state = Provider.initWithOptions("token", "project", "global", .{
        .context = &marker,
        .sendFn = struct {
            fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
                return error.UnexpectedRequest;
            }
        }.send,
    }, .{ .model_profiles = .{
        .context = &marker,
        .lookupFn = Profiles.lookup,
        .overrideFn = Profiles.apply,
    } });
    const provider = provider_state.provider();
    const known = provider.modelProfile("known", .{});
    try std.testing.expect(known.supports_tools);
    try std.testing.expect(!known.supports_temperature);
    const unknown = provider.modelProfile("unknown", .{ .supports_temperature = true });
    try std.testing.expect(!unknown.supports_temperature);
}
