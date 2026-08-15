//! Amazon Bedrock provider adapters.
//!
//! Mantle exposes Bedrock-hosted models through OpenAI-compatible Chat
//! Completions. Its provider and client names are explicit so native Bedrock
//! Runtime adapters can coexist without sharing wire-protocol assumptions.

const std = @import("std");
const compatible = @import("openai_compatible.zig");
const converse = @import("bedrock/converse.zig");
const http_provider = @import("http.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");
const profiles = @import("profiles.zig");

pub const api_key_env = "AWS_BEARER_TOKEN_BEDROCK";
pub const region_env = "AWS_DEFAULT_REGION";

const defaults: compatible.ClientDefaults = .{
    .base_url = "",
    .provider_name = "bedrock",
    .profile = profiles.openai_compatible.unknown,
    .model_profile_lookup = profiles.bedrock,
};

pub const MantleProvider = compatible.ProviderWithDefaults(defaults);
pub const MantleClient = compatible.ClientWithDefaults(defaults);

pub const Client = converse.Client;
pub const encodeRequest = converse.encodeRequest;
pub const decodeResponse = converse.decodeResponse;

pub const Error = converse.Error;
pub const InitError = std.mem.Allocator.Error || error{InvalidBedrockRegion};

/// Native Bedrock Runtime provider state. The generated regional base URL is
/// rebound when `provider` is called, after this value reaches its stable
/// address. Do not move the state while its borrowed interface is in use.
pub const Provider = struct {
    http: http_provider.Configured,
    regional_base: [128]u8 = undefined,
    regional_base_len: usize = 0,
    custom_base_url: ?[]const u8 = null,
    application_model_profiles: ?http_provider.Configured.ModelProfiles = null,

    pub const Options = struct {
        base_url: ?[]const u8 = null,
        headers: []const transport.Header = &.{},
        request_policy: provider_types.RequestPolicy = .{},
        model_profiles: ?http_provider.Configured.ModelProfiles = null,
    };

    pub fn init(api_key: []const u8, region: []const u8, http_transport: transport.Transport) InitError!Provider {
        return initWithOptions(api_key, region, http_transport, .{});
    }

    pub fn initWithOptions(
        api_key: []const u8,
        region: []const u8,
        http_transport: transport.Transport,
        options: Options,
    ) InitError!Provider {
        try validateRegion(region);
        var result = Provider{
            .http = .{
                .name = "bedrock",
                .base_url = options.base_url orelse "",
                .transport = http_transport,
                .credential = .{ .bearer = api_key },
                .headers = options.headers,
                .request_policy = options.request_policy,
            },
            .custom_base_url = options.base_url,
            .application_model_profiles = options.model_profiles,
        };
        if (options.base_url == null) {
            const rendered = std.fmt.bufPrint(
                &result.regional_base,
                "https://bedrock-runtime.{s}.amazonaws.com",
                .{region},
            ) catch return error.InvalidBedrockRegion;
            result.regional_base_len = rendered.len;
        }
        return result;
    }

    pub fn provider(self: *Provider) provider_types.Provider {
        if (self.custom_base_url == null) self.http.base_url = self.regional_base[0..self.regional_base_len];
        self.http.model_profiles = .{
            .context = self,
            .lookupFn = lookupModelProfile,
            .overrideFn = overrideModelProfile,
        };
        return self.http.provider();
    }

    fn lookupModelProfile(context: *anyopaque, model_name: []const u8) ?@import("../model.zig").ModelProfile {
        const self: *Provider = @ptrCast(@alignCast(context));
        if (self.application_model_profiles) |application| if (application.lookupFn) |lookup| {
            if (lookup(application.context, model_name)) |profile| return profile;
        };
        return profiles.bedrockConverse(model_name);
    }

    fn overrideModelProfile(
        context: *anyopaque,
        model_name: []const u8,
        profile: @import("../model.zig").ModelProfile,
    ) @import("../model.zig").ModelProfile {
        const self: *Provider = @ptrCast(@alignCast(context));
        const application = self.application_model_profiles orelse return profile;
        const apply = application.overrideFn orelse return profile;
        return apply(application.context, model_name, profile);
    }
};

/// Builds the regional native Bedrock Runtime API base.
pub fn apiBase(allocator: std.mem.Allocator, region: []const u8) InitError![]u8 {
    try validateRegion(region);
    return std.fmt.allocPrint(allocator, "https://bedrock-runtime.{s}.amazonaws.com", .{region});
}

/// Builds the regional Bedrock Mantle v1 API base.
pub fn mantleApiBase(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://bedrock-mantle.{s}.api.aws/v1", .{region});
}

fn validateRegion(region: []const u8) error{InvalidBedrockRegion}!void {
    if (region.len == 0 or region.len > 63 or region[0] == '-' or region[region.len - 1] == '-')
        return error.InvalidBedrockRegion;
    for (region) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-')
        return error.InvalidBedrockRegion;
}

test "apiBase validates and includes the native region" {
    const value = try apiBase(std.testing.allocator, "eu-west-1");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://bedrock-runtime.eu-west-1.amazonaws.com", value);
    try std.testing.expectError(error.InvalidBedrockRegion, apiBase(std.testing.allocator, "../bad"));
    try std.testing.expectError(error.InvalidBedrockRegion, apiBase(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidBedrockRegion, apiBase(std.testing.allocator, "-eu-west-1"));
    try std.testing.expectError(error.InvalidBedrockRegion, apiBase(std.testing.allocator, "eu-west-1-"));
    try std.testing.expectError(error.InvalidBedrockRegion, apiBase(std.testing.allocator, "EU-WEST-1"));
}

test "mantleApiBase includes the region" {
    const value = try mantleApiBase(std.testing.allocator, "eu-west-1");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("https://bedrock-mantle.eu-west-1.api.aws/v1", value);
}

test "native provider binds generated and custom API bases" {
    var marker: u8 = 0;
    const unused_transport = transport.Transport{
        .context = &marker,
        .sendFn = struct {
            fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
                return error.UnexpectedRequest;
            }
        }.send,
    };
    var regional = try Provider.init("secret", "us-east-1", unused_transport);
    try std.testing.expectEqualStrings(
        "https://bedrock-runtime.us-east-1.amazonaws.com",
        regional.provider().base_url,
    );
    var custom = try Provider.initWithOptions("secret", "us-east-1", unused_transport, .{
        .base_url = "https://bedrock.test",
    });
    try std.testing.expectEqualStrings("https://bedrock.test", custom.provider().base_url);
}
