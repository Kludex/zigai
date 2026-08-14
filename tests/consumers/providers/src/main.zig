const std = @import("std");
const zigai = @import("zigai");
const openai = @import("zopenai");
const anthropic = @import("zanthropic");
const google = @import("zgoogle");
const openai_compatible = @import("zopenai_compatible");

pub fn main() !void {
    if (!std.mem.eql(u8, openai.api_base, zigai.providers.openai.api_base)) return error.OpenAIAliasMismatch;
    if (!std.mem.eql(u8, anthropic.api_base, zigai.providers.anthropic.api_base)) return error.AnthropicAliasMismatch;
    if (!std.mem.eql(u8, google.api_base, zigai.providers.google.api_base)) return error.GoogleAliasMismatch;
    _ = openai_compatible.Client;
}
