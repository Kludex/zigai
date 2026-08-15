//! Transport-level authorization contracts for MCP over HTTP.
//!
//! This module owns no sockets, browser flow, credential store, or token
//! validator. Applications provide those through the callback interfaces below;
//! ZigAI enforces resource/issuer binding and keeps credentials out of MCP JSON.

const std = @import("std");
const security = @import("../security.zig");

/// Stable authorization failures raised before an MCP request is dispatched.
pub const Error = error{
    InvalidAuthorizationIssuer,
    MissingAuthorizationIssuer,
    InvalidBearerToken,
    InvalidOrigin,
    InvalidProtectedResourceMetadata,
    InvalidResourceUri,
};

/// Why a client is requesting a bearer token from its credential owner.
pub const TokenReason = enum {
    initial,
    invalid_token,
    insufficient_scope,
};

/// Input to a client-owned token provider.
pub const TokenRequest = struct {
    /// Canonical RFC 8707 resource indicator for the MCP endpoint.
    resource: []const u8,
    /// Authorization-server issuer selected through protected-resource discovery.
    authorization_server: []const u8,
    /// MCP method about to be sent.
    method: []const u8,
    /// Previously granted scopes followed by scopes from the latest challenge.
    scopes: []const []const u8 = &.{},
    reason: TokenReason = .initial,
};

/// One client-owned access token. Every slice is owned by `allocator`.
pub const AccessToken = struct {
    value: []u8,
    /// Issuer that minted this token. It must exactly match `TokenRequest.authorization_server`.
    issuer: []u8,
    scopes: [][]u8 = &.{},

    pub fn deinit(self: AccessToken, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.issuer);
        for (self.scopes) |scope| allocator.free(scope);
        allocator.free(self.scopes);
    }

    pub fn validate(self: AccessToken, request: TokenRequest) Error!void {
        if (self.value.len == 0 or containsInvalidHeaderByte(self.value)) return error.InvalidBearerToken;
        if (!std.mem.eql(u8, self.issuer, request.authorization_server)) {
            return error.InvalidAuthorizationIssuer;
        }
    }
};

/// Credential callback used by Streamable HTTP. Returned token data is owned.
pub const TokenProvider = struct {
    context: *anyopaque,
    getFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: TokenRequest,
    ) anyerror!AccessToken,

    pub fn get(
        self: TokenProvider,
        allocator: std.mem.Allocator,
        request: TokenRequest,
    ) !AccessToken {
        const token = try self.getFn(self.context, allocator, request);
        errdefer token.deinit(allocator);
        try token.validate(request);
        return token;
    }
};

/// Client authorization policy for one canonical MCP resource and issuer.
pub const ClientPolicy = struct {
    resource: []const u8,
    authorization_server: []const u8,
    tokens: TokenProvider,
    /// Bounds 401/403 refresh and step-up retries for one MCP request.
    max_refresh_attempts: usize = 1,

    pub fn validate(self: ClientPolicy) !void {
        try validateCanonicalResource(self.resource, .{});
        try validateIssuerUrl(self.authorization_server, .{});
    }
};

/// Data presented to a server-owned bearer-token validator.
pub const ValidationRequest = struct {
    token: []const u8,
    /// Canonical audience/resource the token must target.
    resource: []const u8,
    method: []const u8,
    params_json: []const u8,
};

pub const Denial = struct {
    description: ?[]const u8 = null,
};

pub const ScopeDenial = struct {
    required_scopes: []const []const u8,
    description: ?[]const u8 = null,
};

/// A validator must return `authorized` only after validating token integrity,
/// expiry, issuer, and that its audience contains `ValidationRequest.resource`.
pub const Decision = union(enum) {
    authorized,
    unauthorized: Denial,
    insufficient_scope: ScopeDenial,
};

/// Server callback that owns token verification and application permissions.
pub const Authorizer = struct {
    context: *anyopaque,
    authorizeFn: *const fn (context: *anyopaque, request: ValidationRequest) anyerror!Decision,

    pub fn authorize(self: Authorizer, request: ValidationRequest) !Decision {
        return self.authorizeFn(self.context, request);
    }
};

/// Borrowed RFC 9728 protected-resource metadata served by an HTTP host.
pub const ProtectedResourceMetadata = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8 = &.{},
    bearer_methods_supported: []const []const u8 = &.{"header"},

    pub fn validate(self: ProtectedResourceMetadata, url_policy: security.UrlPolicy) !void {
        try validateCanonicalResource(self.resource, url_policy);
        if (self.authorization_servers.len == 0) return error.InvalidProtectedResourceMetadata;
        for (self.authorization_servers) |issuer| try validateIssuerUrl(issuer, url_policy);
        for (self.scopes_supported) |scope| try validateScope(scope);
        var has_header = false;
        for (self.bearer_methods_supported) |method| {
            if (std.mem.eql(u8, method, "header")) has_header = true;
        }
        if (!has_header) return error.InvalidProtectedResourceMetadata;
    }

    /// Serializes a standards-shaped metadata document. The caller owns it.
    pub fn stringifyAlloc(self: ProtectedResourceMetadata, allocator: std.mem.Allocator) ![]u8 {
        try self.validate(.{});
        return std.json.Stringify.valueAlloc(allocator, .{
            .resource = self.resource,
            .authorization_servers = self.authorization_servers,
            .scopes_supported = self.scopes_supported,
            .bearer_methods_supported = self.bearer_methods_supported,
        }, .{});
    }
};

/// Server authorization and browser-origin policy for one MCP endpoint.
pub const ServerPolicy = struct {
    resource: []const u8,
    resource_metadata_url: []const u8,
    authorizer: Authorizer,
    /// Exact serialized origins accepted when an Origin header is present.
    allowed_origins: []const []const u8 = &.{},
    /// Required scopes advertised by an initial 401 challenge.
    scopes: []const []const u8 = &.{},

    pub fn validate(self: ServerPolicy) !void {
        try validateCanonicalResource(self.resource, .{});
        try validateCanonicalResource(self.resource_metadata_url, .{});
        for (self.allowed_origins) |origin| try validateOrigin(origin);
        for (self.scopes) |scope| try validateScope(scope);
    }

    /// Missing Origin is valid for non-browser clients; a present value must
    /// match the explicit allowlist exactly.
    pub fn permitsOrigin(self: ServerPolicy, origin: ?[]const u8) bool {
        const value = origin orelse return true;
        if (validateOrigin(value)) |_| {} else |_| return false;
        for (self.allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, value)) return true;
        }
        return false;
    }
};

/// Applies RFC 9207 issuer validation using simple string comparison.
pub fn validateAuthorizationResponseIssuer(
    expected: []const u8,
    issuer_parameter_supported: bool,
    received: ?[]const u8,
) Error!void {
    if (received) |issuer| {
        if (!std.mem.eql(u8, expected, issuer)) return error.InvalidAuthorizationIssuer;
    } else if (issuer_parameter_supported) {
        return error.MissingAuthorizationIssuer;
    }
}

/// Returns an owned, stable-order union used for step-up authorization.
pub fn unionScopesAlloc(
    allocator: std.mem.Allocator,
    granted: []const []const u8,
    required: []const []const u8,
) ![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |scope| allocator.free(scope);
        result.deinit(allocator);
    }
    for (granted) |scope| try appendScope(allocator, &result, scope);
    for (required) |scope| try appendScope(allocator, &result, scope);
    return result.toOwnedSlice(allocator);
}

pub fn deinitScopes(allocator: std.mem.Allocator, scopes: [][]u8) void {
    for (scopes) |scope| allocator.free(scope);
    allocator.free(scopes);
}

fn appendScope(allocator: std.mem.Allocator, scopes: *std.ArrayList([]u8), scope: []const u8) !void {
    try validateScope(scope);
    for (scopes.items) |existing| if (std.mem.eql(u8, existing, scope)) return;
    try scopes.append(allocator, try allocator.dupe(u8, scope));
}

fn validateCanonicalResource(value: []const u8, policy: security.UrlPolicy) !void {
    policy.validate(value) catch return error.InvalidResourceUri;
    const uri = std.Uri.parse(value) catch return error.InvalidResourceUri;
    if (uri.fragment != null) return error.InvalidResourceUri;
}

fn validateIssuerUrl(value: []const u8, policy: security.UrlPolicy) !void {
    try validateCanonicalResource(value, policy);
    const uri = std.Uri.parse(value) catch return error.InvalidAuthorizationIssuer;
    if (uri.query != null or uri.fragment != null) return error.InvalidAuthorizationIssuer;
}

fn validateOrigin(value: []const u8) Error!void {
    if (value.len == 0 or std.mem.eql(u8, value, "null") or containsInvalidHeaderByte(value)) {
        return error.InvalidOrigin;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidOrigin;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.path.percent_encoded.len != 0 or
        uri.query != null or uri.fragment != null or uri.user != null or uri.password != null)
    {
        return error.InvalidOrigin;
    }
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return error.InvalidOrigin;
    if (host.bytes.len == 0) return error.InvalidOrigin;
}

fn validateScope(scope: []const u8) Error!void {
    if (scope.len == 0) return error.InvalidProtectedResourceMetadata;
    for (scope) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '"' or byte == '\\') {
            return error.InvalidProtectedResourceMetadata;
        }
    }
}

fn containsInvalidHeaderByte(value: []const u8) bool {
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return true;
    return false;
}

test "access tokens are issuer-bound and reject unsafe header bytes" {
    const Callbacks = struct {
        fn get(_: *anyopaque, allocator: std.mem.Allocator, request: TokenRequest) !AccessToken {
            return .{
                .value = try allocator.dupe(u8, "secret"),
                .issuer = try allocator.dupe(u8, request.authorization_server),
            };
        }
    };
    var unused: u8 = 0;
    const provider = TokenProvider{ .context = &unused, .getFn = Callbacks.get };
    const request = TokenRequest{
        .resource = "https://mcp.example.com/mcp",
        .authorization_server = "https://auth.example.com",
        .method = "tools/list",
    };
    const token = try provider.get(std.testing.allocator, request);
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("secret", token.value);

    var wrong = AccessToken{
        .value = try std.testing.allocator.dupe(u8, "secret"),
        .issuer = try std.testing.allocator.dupe(u8, "https://other.example.com"),
    };
    defer wrong.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidAuthorizationIssuer, wrong.validate(request));
    std.testing.allocator.free(wrong.value);
    wrong.value = try std.testing.allocator.dupe(u8, "bad\nvalue");
    try std.testing.expectError(error.InvalidBearerToken, wrong.validate(.{
        .resource = request.resource,
        .authorization_server = wrong.issuer,
        .method = request.method,
    }));
}

test "protected resource metadata validates and serializes" {
    const metadata = ProtectedResourceMetadata{
        .resource = "https://mcp.example.com/mcp",
        .authorization_servers = &.{"https://auth.example.com/tenant"},
        .scopes_supported = &.{ "tools:read", "tools:call" },
    };
    const json = try metadata.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "authorization_servers") != null);
    try std.testing.expectError(
        error.InvalidProtectedResourceMetadata,
        (ProtectedResourceMetadata{
            .resource = metadata.resource,
            .authorization_servers = &.{},
        }).validate(.{}),
    );
    try std.testing.expectError(
        error.InvalidProtectedResourceMetadata,
        (ProtectedResourceMetadata{
            .resource = metadata.resource,
            .authorization_servers = metadata.authorization_servers,
            .bearer_methods_supported = &.{"body"},
        }).validate(.{}),
    );
}

test "server policy validates exact browser origins" {
    const Callbacks = struct {
        fn authorize(_: *anyopaque, _: ValidationRequest) !Decision {
            return .authorized;
        }
    };
    var unused: u8 = 0;
    const policy = ServerPolicy{
        .resource = "https://mcp.example.com/mcp",
        .resource_metadata_url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
        .authorizer = .{ .context = &unused, .authorizeFn = Callbacks.authorize },
        .allowed_origins = &.{"https://app.example.com"},
        .scopes = &.{"tools:read"},
    };
    try policy.validate();
    try std.testing.expect(policy.permitsOrigin(null));
    try std.testing.expect(policy.permitsOrigin("https://app.example.com"));
    try std.testing.expect(!policy.permitsOrigin("https://evil.example.com"));
    try std.testing.expect(!policy.permitsOrigin("null"));
    try std.testing.expectError(error.InvalidOrigin, validateOrigin("https://app.example.com/path"));
}

test "authorization response issuer and scope union follow exact rules" {
    try validateAuthorizationResponseIssuer("https://auth.example.com", true, "https://auth.example.com");
    try validateAuthorizationResponseIssuer("https://auth.example.com", false, null);
    try std.testing.expectError(
        error.MissingAuthorizationIssuer,
        validateAuthorizationResponseIssuer("https://auth.example.com", true, null),
    );
    try std.testing.expectError(
        error.InvalidAuthorizationIssuer,
        validateAuthorizationResponseIssuer("https://auth.example.com", false, "https://AUTH.example.com"),
    );

    const scopes = try unionScopesAlloc(
        std.testing.allocator,
        &.{ "tools:read", "profile" },
        &.{ "tools:call", "tools:read" },
    );
    defer deinitScopes(std.testing.allocator, scopes);
    try std.testing.expectEqual(@as(usize, 3), scopes.len);
    try std.testing.expectEqualStrings("tools:call", scopes[2]);
}
