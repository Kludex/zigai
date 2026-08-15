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
    InvalidBearerChallenge,
    MissingAuthorizationIssuer,
    InvalidBearerToken,
    InvalidOrigin,
    InvalidRequestHost,
    InsecureHttpTransport,
    InvalidProtectedResourceMetadata,
    InvalidResourceUri,
};

/// HTTP deployment checks performed before parsing or dispatching JSON-RPC.
pub const DeploymentPolicy = struct {
    /// Exact serialized origins accepted when an Origin header is present.
    allowed_origins: []const []const u8 = &.{},
    /// Optional exact Host header, including a non-default port when used.
    expected_host: ?[]const u8 = null,
    /// Explicit local-development opt-in. Production MCP endpoints use TLS.
    allow_cleartext: bool = false,

    pub fn validate(self: DeploymentPolicy) !void {
        for (self.allowed_origins) |origin| try validateOrigin(origin);
        if (self.expected_host) |host| try validateHost(host);
    }

    /// Missing Origin is valid for non-browser clients; a present value must
    /// match the explicit allowlist exactly.
    pub fn validateRequest(
        self: DeploymentPolicy,
        is_tls: bool,
        origin: ?[]const u8,
        host: ?[]const u8,
    ) Error!void {
        if (!is_tls and !self.allow_cleartext) return error.InsecureHttpTransport;
        if (origin) |value| {
            try validateOrigin(value);
            for (self.allowed_origins) |allowed| {
                if (std.mem.eql(u8, allowed, value)) break;
            } else return error.InvalidOrigin;
        }
        if (self.expected_host) |expected| {
            const actual = host orelse return error.InvalidRequestHost;
            if (!std.ascii.eqlIgnoreCase(expected, actual)) return error.InvalidRequestHost;
        }
    }
};

pub const ChallengeError = enum {
    invalid_token,
    insufficient_scope,
    other,
};

/// Owned fields parsed from one RFC 6750 Bearer challenge.
pub const BearerChallenge = struct {
    error_code: ?ChallengeError = null,
    resource_metadata: ?[]u8 = null,
    scopes: [][]u8 = &.{},

    pub fn deinit(self: BearerChallenge, allocator: std.mem.Allocator) void {
        if (self.resource_metadata) |value| allocator.free(value);
        deinitScopes(allocator, self.scopes);
    }
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
    /// Required scopes advertised by an initial 401 challenge.
    scopes: []const []const u8 = &.{},

    pub fn validate(self: ServerPolicy) !void {
        try validateCanonicalResource(self.resource, .{});
        try validateCanonicalResource(self.resource_metadata_url, .{});
        for (self.scopes) |scope| try validateScope(scope);
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

/// Parses the challenge fields needed for token refresh and scope step-up.
/// Unknown auth parameters are ignored and sensitive values are never retained.
pub fn parseBearerChallengeAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
) !BearerChallenge {
    var index: usize = 0;
    skipWhitespace(source, &index);
    const scheme_start = index;
    while (index < source.len and source[index] != ' ' and source[index] != '\t') : (index += 1) {}
    if (!std.ascii.eqlIgnoreCase(source[scheme_start..index], "Bearer")) {
        return error.InvalidBearerChallenge;
    }

    var result: BearerChallenge = .{};
    errdefer result.deinit(allocator);
    var scopes: std.ArrayList([]u8) = .empty;
    errdefer {
        for (scopes.items) |scope| allocator.free(scope);
        scopes.deinit(allocator);
    }
    var seen_error = false;
    var seen_resource_metadata = false;
    var seen_scope = false;
    while (true) {
        skipWhitespace(source, &index);
        if (index == source.len) break;
        if (source[index] == ',') {
            index += 1;
            skipWhitespace(source, &index);
        }
        if (index == source.len) return error.InvalidBearerChallenge;

        const name_start = index;
        while (index < source.len and isTokenByte(source[index])) : (index += 1) {}
        if (name_start == index) return error.InvalidBearerChallenge;
        const name = source[name_start..index];
        skipWhitespace(source, &index);
        if (index == source.len or source[index] != '=') return error.InvalidBearerChallenge;
        index += 1;
        skipWhitespace(source, &index);
        const value = try parseChallengeValueAlloc(allocator, source, &index);
        defer allocator.free(value);

        if (std.ascii.eqlIgnoreCase(name, "error")) {
            if (seen_error) return error.InvalidBearerChallenge;
            seen_error = true;
            result.error_code = if (std.mem.eql(u8, value, "invalid_token"))
                .invalid_token
            else if (std.mem.eql(u8, value, "insufficient_scope"))
                .insufficient_scope
            else
                .other;
        } else if (std.ascii.eqlIgnoreCase(name, "resource_metadata")) {
            if (seen_resource_metadata) return error.InvalidBearerChallenge;
            seen_resource_metadata = true;
            result.resource_metadata = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(name, "scope")) {
            if (seen_scope) return error.InvalidBearerChallenge;
            seen_scope = true;
            var iterator = std.mem.tokenizeScalar(u8, value, ' ');
            while (iterator.next()) |scope| {
                validateScope(scope) catch return error.InvalidBearerChallenge;
                try appendScope(allocator, &scopes, scope);
            }
        }
        skipWhitespace(source, &index);
        if (index < source.len and source[index] != ',') return error.InvalidBearerChallenge;
    }
    result.scopes = try scopes.toOwnedSlice(allocator);
    return result;
}

/// Returns the borrowed token from one strict Authorization header.
pub fn parseBearerAuthorization(value: []const u8) Error![]const u8 {
    const separator = std.mem.findScalar(u8, value, ' ') orelse return error.InvalidBearerToken;
    if (!std.ascii.eqlIgnoreCase(value[0..separator], "Bearer")) return error.InvalidBearerToken;
    const token = value[separator + 1 ..];
    if (token.len == 0) return error.InvalidBearerToken;
    for (token) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "-._~+/=", byte) == null) {
            return error.InvalidBearerToken;
        }
    }
    return token;
}

fn appendScope(allocator: std.mem.Allocator, scopes: *std.ArrayList([]u8), scope: []const u8) !void {
    try validateScope(scope);
    for (scopes.items) |existing| if (std.mem.eql(u8, existing, scope)) return;
    const owned = try allocator.dupe(u8, scope);
    errdefer allocator.free(owned);
    try scopes.append(allocator, owned);
}

fn parseChallengeValueAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    index: *usize,
) ![]u8 {
    if (index.* == source.len) return error.InvalidBearerChallenge;
    if (source[index.*] != '"') {
        const start = index.*;
        while (index.* < source.len and source[index.*] != ',' and
            source[index.*] != ' ' and source[index.*] != '\t') : (index.* += 1)
        {}
        if (start == index.*) return error.InvalidBearerChallenge;
        return allocator.dupe(u8, source[start..index.*]);
    }

    index.* += 1;
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    while (index.* < source.len) {
        const byte = source[index.*];
        index.* += 1;
        if (byte == '"') return value.toOwnedSlice(allocator);
        if (byte == '\\') {
            if (index.* == source.len) return error.InvalidBearerChallenge;
            const escaped = source[index.*];
            index.* += 1;
            if (escaped != '"' and escaped != '\\') return error.InvalidBearerChallenge;
            try value.append(allocator, escaped);
        } else {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidBearerChallenge;
            try value.append(allocator, byte);
        }
    }
    return error.InvalidBearerChallenge;
}

fn skipWhitespace(source: []const u8, index: *usize) void {
    while (index.* < source.len and (source[index.*] == ' ' or source[index.*] == '\t')) : (index.* += 1) {}
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
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

fn validateHost(value: []const u8) Error!void {
    if (value.len == 0 or containsInvalidHeaderByte(value) or std.mem.findScalar(u8, value, '/') != null or
        std.mem.findScalar(u8, value, '@') != null)
    {
        return error.InvalidRequestHost;
    }
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

test "deployment policy validates TLS browser origins and request hosts" {
    const Callbacks = struct {
        fn authorize(_: *anyopaque, _: ValidationRequest) !Decision {
            return .authorized;
        }
    };
    var unused: u8 = 0;
    const deployment = DeploymentPolicy{
        .allowed_origins = &.{"https://app.example.com"},
        .expected_host = "mcp.example.com",
    };
    try deployment.validate();
    try deployment.validateRequest(true, null, "mcp.example.com");
    try deployment.validateRequest(true, "https://app.example.com", "MCP.EXAMPLE.COM");
    try std.testing.expectError(
        error.InvalidOrigin,
        deployment.validateRequest(true, "https://evil.example.com", "mcp.example.com"),
    );
    try std.testing.expectError(
        error.InsecureHttpTransport,
        deployment.validateRequest(false, null, "mcp.example.com"),
    );
    try std.testing.expectError(
        error.InvalidRequestHost,
        deployment.validateRequest(true, null, null),
    );
    try (DeploymentPolicy{ .allow_cleartext = true }).validateRequest(false, null, null);
    try std.testing.expectError(error.InvalidOrigin, validateOrigin("https://app.example.com/path"));
    try std.testing.expectError(error.InvalidRequestHost, validateHost("mcp.example.com/path"));

    const policy = ServerPolicy{
        .resource = "https://mcp.example.com/mcp",
        .resource_metadata_url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
        .authorizer = .{ .context = &unused, .authorizeFn = Callbacks.authorize },
        .scopes = &.{"tools:read"},
    };
    try policy.validate();
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

test "Bearer challenges parse bounded refresh and scope fields" {
    const challenge = try parseBearerChallengeAlloc(
        std.testing.allocator,
        "Bearer error=\"insufficient_scope\", scope=\"tools:read tools:call tools:read\", " ++
            "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource/mcp\", ignored=\"x\"",
    );
    defer challenge.deinit(std.testing.allocator);
    try std.testing.expectEqual(ChallengeError.insufficient_scope, challenge.error_code.?);
    try std.testing.expectEqual(@as(usize, 2), challenge.scopes.len);
    try std.testing.expectEqualStrings("tools:call", challenge.scopes[1]);
    try std.testing.expectEqualStrings(
        "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
        challenge.resource_metadata.?,
    );

    const escaped = try parseBearerChallengeAlloc(
        std.testing.allocator,
        "bearer error=invalid_token, error_description=\"expired \\\"token\\\"\"",
    );
    defer escaped.deinit(std.testing.allocator);
    try std.testing.expectEqual(ChallengeError.invalid_token, escaped.error_code.?);
    try std.testing.expectError(
        error.InvalidBearerChallenge,
        parseBearerChallengeAlloc(std.testing.allocator, "Basic realm=\"mcp\""),
    );
    try std.testing.expectError(
        error.InvalidBearerChallenge,
        parseBearerChallengeAlloc(std.testing.allocator, "Bearer error=\"invalid_token\", error=other"),
    );
}

test "Bearer authorization headers reject alternate channels and unsafe values" {
    try std.testing.expectEqualStrings("abc-._~+/=", try parseBearerAuthorization("Bearer abc-._~+/="));
    try std.testing.expectEqualStrings("token", try parseBearerAuthorization("bearer token"));
    try std.testing.expectError(error.InvalidBearerToken, parseBearerAuthorization("Basic token"));
    try std.testing.expectError(error.InvalidBearerToken, parseBearerAuthorization("Bearer "));
    try std.testing.expectError(error.InvalidBearerToken, parseBearerAuthorization("Bearer two tokens"));
}
