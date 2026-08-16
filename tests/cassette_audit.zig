//! Repository-wide cassette completeness, safety, and normalization gate.

const std = @import("std");
const format = @import("support/cassettes/format.zig");
const manifest = @import("support/cassette_manifest.zig");

const max_cassette_bytes = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    try auditRepository(init.gpa, init.io);
}

fn auditRepository(allocator: std.mem.Allocator, io: std.Io) !void {
    try auditManifest(allocator, io);

    var directory = try std.Io.Dir.cwd().openDir(io, "tests/cassettes", .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var fixture_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".yaml")) continue;
        fixture_count += 1;
        const cassette_path = try std.fmt.allocPrint(allocator, "cassettes/{s}", .{entry.path});
        defer allocator.free(cassette_path);
        if (!manifestContains(cassette_path)) {
            std.log.err("cassette is not declared in the manifest: {s}", .{cassette_path});
            return error.OrphanedCassette;
        }
        const repository_path = try std.fmt.allocPrint(allocator, "tests/{s}", .{cassette_path});
        defer allocator.free(repository_path);
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            repository_path,
            allocator,
            .limited(max_cassette_bytes),
        );
        defer allocator.free(source);
        auditFixture(allocator, cassette_path, source) catch |failure| {
            std.log.err("cassette audit failed for {s}: {s}", .{ cassette_path, @errorName(failure) });
            return failure;
        };
    }
    if (fixture_count != uniqueManifestCassetteCount()) return error.CassetteManifestIncomplete;
}

fn auditManifest(allocator: std.mem.Allocator, io: std.Io) !void {
    for (manifest.all, 0..) |entry, index| {
        if (entry.id.len == 0 or !std.mem.startsWith(u8, entry.cassette, "cassettes/") or
            !std.mem.endsWith(u8, entry.cassette, ".yaml") or std.mem.indexOf(u8, entry.cassette, "..") != null)
            return error.InvalidCassetteManifest;
        for (manifest.all[0..index]) |previous| {
            if (std.mem.eql(u8, entry.id, previous.id)) return error.DuplicateCassetteId;
            if (std.mem.eql(u8, entry.cassette, previous.cassette) and
                (entry.source != .deterministic or previous.source != .deterministic))
                return error.DuplicateLiveCassette;
        }
        const path = try std.fmt.allocPrint(allocator, "tests/{s}", .{entry.cassette});
        defer allocator.free(path);
        std.Io.Dir.cwd().access(io, path, .{ .read = true }) catch |failure| {
            std.log.err("manifest cassette is missing: {s}", .{entry.cassette});
            return failure;
        };
    }
}

fn auditFixture(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    if (hasCredentialShape(source)) return error.CredentialShapedValue;

    var parsed = try format.parse(allocator, source);
    defer parsed.deinit();
    try auditRequestHeaders(source, parsed.value.interactions.len);
    for (parsed.value.interactions) |interaction| {
        try auditUrl(interaction.request.url);
        try auditBodyNormalization(interaction.request.body);
        try auditBodyNormalization(interaction.response.body);
    }

    const canonical = try format.stringify(allocator, parsed.value);
    defer allocator.free(canonical);
    var reparsed = try format.parse(allocator, canonical);
    defer reparsed.deinit();
    const canonical_again = try format.stringify(allocator, reparsed.value);
    defer allocator.free(canonical_again);
    if (!std.mem.eql(u8, canonical, canonical_again)) {
        std.log.err("cassette normalization is not idempotent: {s}", .{path});
        return error.UnstableCassetteNormalization;
    }
}

fn auditRequestHeaders(source: []const u8, interaction_count: usize) !void {
    var in_request = false;
    var header_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- request:")) {
            in_request = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "  response:")) {
            in_request = false;
            continue;
        }
        if (in_request and std.mem.startsWith(u8, line, "    headers:")) {
            header_count += 1;
            if (!std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "headers: {}"))
                return error.RecordedRequestHeaders;
        }
    }
    if (header_count != interaction_count) return error.MissingRequestHeaderBoundary;
}

fn auditUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.UnsafeCassetteUrl;
    if ((std.mem.indexOf(u8, url, "bedrock-runtime.") != null or
        std.mem.indexOf(u8, url, "bedrock-mantle.") != null) and
        std.mem.indexOf(u8, url, "example-region") == null)
        return error.UnnormalizedBedrockUrl;
    if (std.mem.indexOf(u8, url, ".openai.azure.com") != null and
        std.mem.indexOf(u8, url, "example.openai.azure.com") == null)
        return error.UnnormalizedAzureUrl;
}

fn auditBodyNormalization(body: []const u8) !void {
    if (std.mem.indexOf(u8, body, "Content-Disposition: form-data") != null and
        (std.mem.indexOf(u8, body, "zigai-redacted-boundary") == null or
            std.mem.indexOf(u8, body, "[REDACTED FILE CONTENT]") == null))
        return error.UnnormalizedMultipartBody;
}

fn hasCredentialShape(source: []const u8) bool {
    const patterns = [_][]const u8{
        "\"sk-",
        "\"sk-ant-",
        "\"AIza",
        "\"hf_",
        "\"AKIA",
        "\"ASIA",
        "bearer ",
        "authorization:",
        "proxy-authorization:",
        "x-api-key:",
        "api-key:",
        "x-goog-api-key:",
        "cookie:",
        "set-cookie:",
    };
    for (patterns) |pattern| if (containsIgnoreCase(source, pattern)) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn manifestContains(path: []const u8) bool {
    for (manifest.all) |entry| if (std.mem.eql(u8, entry.cassette, path)) return true;
    return false;
}

fn uniqueManifestCassetteCount() usize {
    var count: usize = 0;
    for (manifest.all, 0..) |entry, index| {
        var duplicate = false;
        for (manifest.all[0..index]) |previous| {
            if (std.mem.eql(u8, entry.cassette, previous.cassette)) duplicate = true;
        }
        if (!duplicate) count += 1;
    }
    return count;
}

test "audit rejects credential shapes and recorded request headers" {
    try std.testing.expect(hasCredentialShape("Authorization: Bearer secret"));
    try std.testing.expect(hasCredentialShape("value: \"sk-ant-example\""));
    try std.testing.expect(!hasCredentialShape("id: resp_example"));
    try std.testing.expectError(
        error.RecordedRequestHeaders,
        auditRequestHeaders("- request:\n    headers:\n      authorization: secret\n  response:\n", 1),
    );
    try auditRequestHeaders("- request:\n    headers: {}\n  response:\n", 1);
}

test "audit requires normalized provider URLs and multipart bodies" {
    try auditUrl("https://bedrock-runtime.example-region.amazonaws.com/model/test/converse");
    try std.testing.expectError(
        error.UnnormalizedBedrockUrl,
        auditUrl("https://bedrock-runtime.eu-west-1.amazonaws.com/model/test/converse"),
    );
    try std.testing.expectError(
        error.UnnormalizedAzureUrl,
        auditUrl("https://private-resource.openai.azure.com/openai/v1/responses"),
    );
    try std.testing.expectError(error.UnsafeCassetteUrl, auditUrl("http://example.test"));
    try std.testing.expectError(
        error.UnnormalizedMultipartBody,
        auditBodyNormalization("Content-Disposition: form-data; payload"),
    );
    try auditBodyNormalization("Content-Disposition: form-data; zigai-redacted-boundary [REDACTED FILE CONTENT]");
}
