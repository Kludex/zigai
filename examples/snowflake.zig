const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const account = init.environ_map.get(zigai.providers.snowflake.account_env) orelse return error.MissingAccount;
    const token = init.environ_map.get(zigai.providers.snowflake.token_env) orelse return error.MissingToken;
    const base_url = try zigai.providers.snowflake.apiBase(init.gpa, account);
    defer init.gpa.free(base_url);
    const model_name = init.environ_map.get("SNOWFLAKE_MODEL") orelse "claude-sonnet-4-5";
    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();
    var provider = zigai.providers.snowflake.Provider.initWithOptions(token, http.transport(), .{
        .base_url = base_url,
    });
    var client = zigai.providers.snowflake.Client{
        .model_name = model_name,
        .provider = provider.provider(),
    };
    var result = try (zigai.Agent{
        .model = client.model(),
        .system_prompt = "Be concise.",
        .io = init.io,
    }).run(init.gpa, "Why is the sky blue?");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.output});
}
