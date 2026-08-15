const std = @import("std");
const zigai = @import("zigai");

const ProfileState = struct {
    model_name: []const u8,

    fn lookup(context: *anyopaque, model_name: []const u8) ?zigai.ModelProfile {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, self.model_name, model_name)) return null;
        return .{
            .supports_system_messages = true,
            .supports_streaming = true,
            .supports_temperature = true,
            .supports_max_tokens = true,
            .supports_request_headers = true,
            .extra_body_kind = .openai_compatible,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const base_url = init.environ_map.get("CUSTOM_PROVIDER_BASE_URL") orelse return error.MissingBaseUrl;
    const api_key = init.environ_map.get("CUSTOM_PROVIDER_API_KEY") orelse return error.MissingApiKey;
    const model_name = init.environ_map.get("CUSTOM_PROVIDER_MODEL") orelse return error.MissingModel;
    if (base_url.len == 0) return error.MissingBaseUrl;
    if (api_key.len == 0) return error.MissingApiKey;
    if (model_name.len == 0) return error.MissingModel;

    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var profiles = ProfileState{ .model_name = model_name };
    var provider = zigai.providers.openai_compatible.Provider.initWithOptions(api_key, http.transport(), .{
        .base_url = base_url,
        .provider_name = "custom-provider",
        .authentication = .{ .header = "authorization", .prefix = "Bearer " },
        .model_profiles = .{
            .context = &profiles,
            .lookupFn = ProfileState.lookup,
        },
    });
    const provider_boundary = provider.provider();
    try provider_boundary.validate();
    var client = zigai.providers.openai_compatible.Client{
        .model_name = model_name,
        .provider = provider_boundary,
        .profile = zigai.providers.openai_compatible.profiles.unknown,
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .system_prompt = "Be concise.",
        .io = init.io,
    }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
