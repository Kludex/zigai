//! Security policy primitives shared by outbound protocol boundaries.
//!
//! This module performs allocation-free validation and redaction decisions. It
//! does not open sockets, resolve DNS, follow redirects, or retain credentials.

const std = @import("std");

/// Stable failures returned while validating an outbound URL.
pub const ValidateUrlError = error{
    /// The value is not a syntactically valid absolute URI.
    InvalidUrl,
    /// The URI has no network host.
    UrlMissingHost,
    /// The URI scheme is not permitted by policy.
    UrlSchemeNotAllowed,
    /// User information or a password was embedded in the URI.
    UrlCredentialsForbidden,
    /// The host is a local name or non-public IP address forbidden by policy.
    LocalNetworkUrlForbidden,
    /// The host is absent from a non-empty explicit allowlist.
    UrlHostNotAllowed,
};

pub const ValidateSameOriginError = ValidateUrlError || error{
    /// A provider-directed URL does not share the configured API origin.
    UrlOriginNotAllowed,
};

/// Validates a provider-directed URL and requires the same scheme, host, and
/// effective port as the configured API root.
pub fn validateSameOrigin(policy: UrlPolicy, base_url: []const u8, target_url: []const u8) ValidateSameOriginError!void {
    try policy.validate(target_url);
    const base = std.Uri.parse(base_url) catch return error.InvalidUrl;
    const target = std.Uri.parse(target_url) catch return error.InvalidUrl;
    var base_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var target_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const base_host = (base.getHost(&base_host_buffer) catch return error.UrlMissingHost).bytes;
    const target_host = (target.getHost(&target_host_buffer) catch return error.UrlMissingHost).bytes;
    if (!std.ascii.eqlIgnoreCase(base.scheme, target.scheme) or
        !std.ascii.eqlIgnoreCase(base_host, target_host) or
        effectivePort(base) != effectivePort(target)) return error.UrlOriginNotAllowed;
}

fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

/// Policy for URLs that ZigAI or a remote provider may fetch.
pub const UrlPolicy = struct {
    /// Permit cleartext HTTP in addition to HTTPS.
    allow_http: bool = false,
    /// Permit loopback, private, link-local, multicast, and local-name hosts.
    allow_local_network: bool = false,
    /// Exact case-insensitive host allowlist. Empty permits every eligible host.
    allowed_hosts: []const []const u8 = &.{},

    /// Validates one absolute URL without resolving or opening it.
    pub fn validate(self: UrlPolicy, value: []const u8) ValidateUrlError!void {
        const uri = std.Uri.parse(value) catch return error.InvalidUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and
            !(self.allow_http and std.ascii.eqlIgnoreCase(uri.scheme, "http")))
        {
            return error.UrlSchemeNotAllowed;
        }
        if (uri.user != null or uri.password != null) return error.UrlCredentialsForbidden;

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.getHost(&host_buffer) catch return error.UrlMissingHost).bytes;
        if (host.len == 0) return error.UrlMissingHost;
        const normalized_host = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
            host[1 .. host.len - 1]
        else
            host;
        if (!self.allow_local_network and isLocalHost(normalized_host)) return error.LocalNetworkUrlForbidden;
        if (self.allowed_hosts.len > 0 and !containsHost(self.allowed_hosts, normalized_host)) {
            return error.UrlHostNotAllowed;
        }
    }
};

/// Replacement shown instead of credentials in diagnostic views.
pub const redacted_value = "[REDACTED]";

/// Returns whether a header name conventionally carries credentials or secrets.
pub fn isSensitiveHeaderName(name: []const u8) bool {
    const exact = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
    };
    for (exact) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return containsIgnoreCase(name, "secret") or
        containsIgnoreCase(name, "token") or
        endsWithIgnoreCase(name, "-key");
}

/// Returns a safe borrowed header value for callbacks, logs, and telemetry.
pub fn redactedHeaderValue(name: []const u8, value: []const u8, marked_sensitive: bool) []const u8 {
    if (marked_sensitive or isSensitiveHeaderName(name)) return redacted_value;
    return value;
}

fn containsHost(allowed_hosts: []const []const u8, host: []const u8) bool {
    for (allowed_hosts) |allowed| if (std.ascii.eqlIgnoreCase(allowed, host)) return true;
    return false;
}

fn isLocalHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        endsWithIgnoreCase(host, ".localhost") or
        endsWithIgnoreCase(host, ".local") or
        endsWithIgnoreCase(host, ".internal") or
        endsWithIgnoreCase(host, ".home.arpa") or
        std.mem.findScalar(u8, host, '.') == null and std.mem.findScalar(u8, host, ':') == null)
    {
        return true;
    }

    const address = std.Io.net.IpAddress.parse(host, 0) catch return false;
    return switch (address) {
        .ip4 => |ip4| isNonPublicIp4(ip4.bytes),
        .ip6 => |ip6| isNonPublicIp6(ip6.bytes),
    };
}

fn isNonPublicIp4(bytes: [4]u8) bool {
    return bytes[0] == 0 or
        bytes[0] == 10 or
        (bytes[0] == 100 and bytes[1] >= 64 and bytes[1] <= 127) or
        bytes[0] == 127 or
        (bytes[0] == 169 and bytes[1] == 254) or
        (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) or
        (bytes[0] == 192 and bytes[1] == 0 and bytes[2] == 0) or
        (bytes[0] == 192 and bytes[1] == 168) or
        (bytes[0] == 198 and (bytes[1] == 18 or bytes[1] == 19)) or
        bytes[0] >= 224;
}

fn isNonPublicIp6(bytes: [16]u8) bool {
    const unspecified = std.mem.allEqual(u8, &bytes, 0);
    const loopback = std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1;
    const unique_local = bytes[0] & 0xfe == 0xfc;
    const link_local = bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80;
    const site_local = bytes[0] == 0xfe and bytes[1] & 0xc0 == 0xc0;
    const multicast = bytes[0] == 0xff;
    if (unspecified or loopback or unique_local or link_local or site_local or multicast) return true;

    const mapped_ip4 = std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff;
    if (mapped_ip4) return isNonPublicIp4(bytes[12..16].*);
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "URL policy permits public HTTPS and exact allowlisted hosts" {
    try (UrlPolicy{}).validate("https://api.example.com/v1");
    try (UrlPolicy{ .allowed_hosts = &.{"API.EXAMPLE.COM"} }).validate("https://api.example.com/v1");
    try std.testing.expectError(
        error.UrlHostNotAllowed,
        (UrlPolicy{ .allowed_hosts = &.{"other.example"} }).validate("https://api.example.com/v1"),
    );
}

test "provider-directed URLs require the same effective origin" {
    try validateSameOrigin(UrlPolicy{}, "https://api.example.com/v1", "https://API.EXAMPLE.COM:443/upload/one");
    try std.testing.expectError(
        error.UrlOriginNotAllowed,
        validateSameOrigin(UrlPolicy{}, "https://api.example.com/v1", "https://upload.example.com/one"),
    );
    try std.testing.expectError(
        error.UrlOriginNotAllowed,
        validateSameOrigin(UrlPolicy{ .allow_http = true }, "https://api.example.com/v1", "http://api.example.com/one"),
    );
    try std.testing.expectError(
        error.UrlOriginNotAllowed,
        validateSameOrigin(UrlPolicy{}, "https://api.example.com:444/v1", "https://api.example.com/one"),
    );
}

test "URL policy rejects invalid schemes hosts and credentials" {
    try std.testing.expectError(error.InvalidUrl, (UrlPolicy{}).validate(":"));
    try std.testing.expectError(error.UrlSchemeNotAllowed, (UrlPolicy{}).validate("ftp://example.com/file"));
    try std.testing.expectError(error.UrlSchemeNotAllowed, (UrlPolicy{}).validate("http://example.com/file"));
    try std.testing.expectError(error.UrlMissingHost, (UrlPolicy{ .allow_http = true }).validate("http:/file"));
    try std.testing.expectError(
        error.UrlCredentialsForbidden,
        (UrlPolicy{}).validate("https://user:password@example.com/file"),
    );
    try (UrlPolicy{ .allow_http = true }).validate("http://example.com/file");
}

test "URL policy blocks local names and non-public addresses" {
    const blocked = [_][]const u8{
        "https://localhost/x",
        "https://service.local/x",
        "https://metadata.google.internal/x",
        "https://router/x",
        "https://0.0.0.0/x",
        "https://10.0.0.1/x",
        "https://100.64.0.1/x",
        "https://127.0.0.1/x",
        "https://169.254.169.254/x",
        "https://172.16.0.1/x",
        "https://192.0.0.1/x",
        "https://192.168.1.1/x",
        "https://198.18.0.1/x",
        "https://224.0.0.1/x",
        "https://[::]/x",
        "https://[::1]/x",
        "https://[fc00::1]/x",
        "https://[fe80::1]/x",
        "https://[fec0::1]/x",
        "https://[ff02::1]/x",
        "https://[::ffff:127.0.0.1]/x",
    };
    for (blocked) |value| {
        try std.testing.expectError(error.LocalNetworkUrlForbidden, (UrlPolicy{}).validate(value));
    }
    try (UrlPolicy{ .allow_local_network = true }).validate("https://127.0.0.1/x");
    try (UrlPolicy{}).validate("https://8.8.8.8/x");
    try (UrlPolicy{}).validate("https://[2001:4860:4860::8888]/x");
    try (UrlPolicy{}).validate("https://[::ffff:8.8.8.8]/x");
}

test "header redaction recognizes explicit and conventional secrets" {
    try std.testing.expectEqualStrings(redacted_value, redactedHeaderValue("authorization", "Bearer secret", false));
    try std.testing.expectEqualStrings(redacted_value, redactedHeaderValue("X-Custom-Token", "secret", false));
    try std.testing.expectEqualStrings(redacted_value, redactedHeaderValue("X-Client-Key", "secret", false));
    try std.testing.expectEqualStrings(redacted_value, redactedHeaderValue("x-secret-name", "secret", false));
    try std.testing.expectEqualStrings(redacted_value, redactedHeaderValue("x-custom", "secret", true));
    try std.testing.expectEqualStrings("visible", redactedHeaderValue("content-type", "visible", false));
    try std.testing.expect(!isSensitiveHeaderName("x"));
}
