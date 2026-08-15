//! Snowflake Cortex client through its OpenAI-compatible Chat Completions API.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const profiles = @import("profiles.zig");

pub const account_env = "SNOWFLAKE_ACCOUNT";
pub const token_env = "SNOWFLAKE_TOKEN";

pub const Error = error{
    InvalidSnowflakeAccount,
};

const defaults: compatible.ClientDefaults = .{
    .base_url = "",
    .provider_name = "snowflake",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.snowflake,
};

pub const Provider = compatible.ProviderWithDefaults(defaults);
pub const Client = compatible.ClientWithDefaults(defaults);

/// Builds the Cortex `/api/v2/cortex/v1` root from a Snowflake account
/// identifier or canonical account hostname. The caller owns the result.
pub fn apiBase(allocator: std.mem.Allocator, account: []const u8) ![]u8 {
    var identifier = std.mem.trimEnd(u8, account, "/");
    if (std.mem.startsWith(u8, identifier, "https://")) identifier = identifier["https://".len..];
    if (std.mem.startsWith(u8, identifier, "http://")) return error.InvalidSnowflakeAccount;
    const suffix = ".snowflakecomputing.com";
    if (std.mem.endsWith(u8, identifier, suffix)) identifier = identifier[0 .. identifier.len - suffix.len];
    try validateAccount(identifier);
    return std.fmt.allocPrint(
        allocator,
        "https://{s}.snowflakecomputing.com/api/v2/cortex/v1",
        .{identifier},
    );
}

fn validateAccount(identifier: []const u8) Error!void {
    if (identifier.len == 0 or identifier.len > 253 or identifier[0] == '.' or
        identifier[identifier.len - 1] == '.' or std.mem.indexOf(u8, identifier, "..") != null)
    {
        return error.InvalidSnowflakeAccount;
    }
    for (identifier) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-')
            return error.InvalidSnowflakeAccount;
    }
}

test "Snowflake API base accepts identifiers and canonical account hosts" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "myorg-myaccount", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "xy12345.us-east-1", .expected = "https://xy12345.us-east-1.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "myorg-myaccount.snowflakecomputing.com", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
        .{ .input = "https://myorg-myaccount.snowflakecomputing.com/", .expected = "https://myorg-myaccount.snowflakecomputing.com/api/v2/cortex/v1" },
    };
    for (cases) |case| {
        const value = try apiBase(std.testing.allocator, case.input);
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(case.expected, value);
    }
}

test "Snowflake API base rejects values that could select another origin" {
    const invalid = [_][]const u8{
        "",
        "http://myorg-myaccount",
        ".myaccount",
        "myaccount.",
        "myorg..myaccount",
        "myaccount/path",
        "myaccount:443",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidSnowflakeAccount, apiBase(std.testing.allocator, value));
    }
    const too_long = [_]u8{'a'} ** 254;
    try std.testing.expectError(error.InvalidSnowflakeAccount, apiBase(std.testing.allocator, &too_long));
}
