//! Pinned official implementations exercised by the MCP interoperability suite.

const std = @import("std");
const yaml = @import("yaml");

pub const Transport = enum { stdio, http };

pub const Source = struct {
    repository: []const u8,
    revision: []const u8,
};

pub const Conformance = struct {
    repository: []const u8,
    revision: []const u8,
    requirements: []const u8,
};

pub const Server = struct {
    id: []const u8,
    sdk: []const u8,
    repository: []const u8,
    revision: []const u8,
    directory: []const u8,
    transports: []const Transport,
};

pub const Manifest = struct {
    version: u8,
    protocol_version: []const u8,
    conformance: Conformance,
    servers: []const Server,
};

pub const Owned = struct {
    document: yaml.TypedDocument(Manifest),

    pub fn deinit(self: *Owned) void {
        self.document.deinit();
        self.* = undefined;
    }

    pub fn value(self: *const Owned) *const Manifest {
        return &self.document.value;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Owned {
    var document = try yaml.loadTypedWithOptions(Manifest, allocator, source, .{
        .load = .{
            .schema = .core,
            .duplicate_key_behavior = .reject,
            .unknown_tag_behavior = .reject,
            .max_input_bytes = 64 * 1024,
            .max_nesting_depth = 16,
        },
    });
    errdefer document.deinit();
    try validate(document.value);
    return .{ .document = document };
}

fn validate(manifest: Manifest) !void {
    if (manifest.version != 1) return error.UnsupportedManifestVersion;
    if (!std.mem.eql(u8, manifest.protocol_version, "2026-07-28")) return error.UnsupportedProtocolVersion;
    try validateSource(.{
        .repository = manifest.conformance.repository,
        .revision = manifest.conformance.revision,
    });
    if (!std.mem.eql(u8, manifest.conformance.requirements, manifest.protocol_version)) {
        return error.RequirementsVersionMismatch;
    }
    if (manifest.servers.len == 0) return error.EmptyServerMatrix;
    for (manifest.servers, 0..) |server, index| {
        if (server.id.len == 0 or server.sdk.len == 0 or server.directory.len == 0) return error.InvalidServer;
        try validateSource(.{ .repository = server.repository, .revision = server.revision });
        if (server.transports.len == 0) return error.EmptyTransportMatrix;
        for (server.transports, 0..) |transport, transport_index| {
            for (server.transports[0..transport_index]) |previous| {
                if (transport == previous) return error.DuplicateTransport;
            }
        }
        for (manifest.servers[0..index]) |previous| {
            if (std.mem.eql(u8, server.id, previous.id)) return error.DuplicateServer;
        }
    }
}

fn validateSource(source: Source) !void {
    if (!std.mem.startsWith(u8, source.repository, "https://github.com/modelcontextprotocol/") or
        !std.mem.endsWith(u8, source.repository, ".git"))
    {
        return error.UnofficialUpstream;
    }
    if (source.revision.len != 40) return error.UnpinnedUpstream;
    for (source.revision) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
        return error.UnpinnedUpstream;
    };
}

test "official MCP upstream manifest is pinned and covers both transports" {
    var manifest = try parse(std.testing.allocator, @embedFile("upstreams.yaml"));
    defer manifest.deinit();

    try std.testing.expectEqualStrings("2026-07-28", manifest.value().protocol_version);
    try std.testing.expectEqual(@as(usize, 2), manifest.value().servers.len);
    var has_stdio = false;
    var has_http = false;
    for (manifest.value().servers) |server| for (server.transports) |transport| switch (transport) {
        .stdio => has_stdio = true,
        .http => has_http = true,
    };
    try std.testing.expect(has_stdio);
    try std.testing.expect(has_http);
}

test "official MCP upstream manifest rejects moving and malformed references" {
    const prefix =
        \\version: 1
        \\protocol_version: "2026-07-28"
        \\conformance:
        \\  repository: https://github.com/modelcontextprotocol/conformance.git
        \\  revision: c321dd32035556e6769d3724a8ee97d87c3faaac
        \\  requirements: "2026-07-28"
        \\servers:
        \\- id: reference
        \\  sdk: test
        \\  repository: https://github.com/modelcontextprotocol/test.git
    ;
    try std.testing.expectError(error.UnpinnedUpstream, parse(
        std.testing.allocator,
        prefix ++ "\n" ++
            \\  revision: main
            \\  directory: examples
            \\  transports: [http]
        ,
    ));
    const unofficial = try std.mem.replaceOwned(u8, std.testing.allocator, prefix ++ "\n" ++
        \\  revision: 0123456789abcdef0123456789abcdef01234567
        \\  directory: examples
        \\  transports: [http]
    , "modelcontextprotocol/test", "example/test");
    defer std.testing.allocator.free(unofficial);
    try std.testing.expectError(error.UnofficialUpstream, parse(std.testing.allocator, unofficial));
}
