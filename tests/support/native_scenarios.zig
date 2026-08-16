const std = @import("std");
const zigai = @import("zigai");

pub const Evidence = enum {
    openai_web_search,
    anthropic_web_fetch,
    google_grounding,
    mistral_web_search,
};

pub fn expect(messages: []const zigai.Message, usage: zigai.RunUsage, evidence: Evidence) !void {
    const response = lastResponse(messages) orelse return error.MissingModelResponse;
    return switch (evidence) {
        .openai_web_search => expectOpenAI(response, usage),
        .anthropic_web_fetch => expectAnthropic(response, usage),
        .google_grounding => expectGoogle(response, usage),
        .mistral_web_search => expectMistral(response, usage),
    };
}

fn expectOpenAI(response: zigai.ResponseMessage, usage: zigai.RunUsage) !void {
    var found_call = false;
    var found_citation = false;
    for (response.parts) |part| switch (part) {
        .native_tool_call => |call| {
            try std.testing.expectEqualStrings("web_search", call.name);
            try expectProvider(call.provider, "openai");
            const details = call.provider.provider_details.?.value.object;
            try std.testing.expectEqualStrings("web_search_call", details.get("type").?.string);
            try std.testing.expect(details.get("action") != null);
            found_call = true;
        },
        .text_part => |value| {
            try expectProvider(value.provider, "openai");
            const annotations = value.provider.provider_details.?.value.object.get("annotations").?.array;
            try std.testing.expect(annotations.items.len > 0);
            try std.testing.expectEqualStrings("url_citation", annotations.items[0].object.get("type").?.string);
            found_citation = true;
        },
        else => {},
    };
    try std.testing.expect(found_call);
    try std.testing.expect(found_citation);
    try std.testing.expectEqual(@as(?u64, 0), usage.detail("web_search_requests"));
    try std.testing.expect(usage.reasoning_tokens > 0);
}

fn expectAnthropic(response: zigai.ResponseMessage, usage: zigai.RunUsage) !void {
    var call_id: ?[]const u8 = null;
    var found_return = false;
    for (response.parts) |part| switch (part) {
        .native_tool_call => |call| {
            try std.testing.expectEqualStrings("web_fetch", call.name);
            try expectProvider(call.provider, "anthropic");
            try std.testing.expectEqualStrings("server_tool_use", call.provider.provider_details.?.value.object.get("type").?.string);
            call_id = call.id;
        },
        .native_tool_return => |result| {
            try std.testing.expectEqualStrings("web_fetch", result.name);
            try expectProvider(result.provider, "anthropic");
            try std.testing.expectEqualStrings("web_fetch_tool_result", result.provider.provider_details.?.value.object.get("type").?.string);
            if (call_id) |id| try std.testing.expectEqualStrings(id, result.call_id);
            try std.testing.expect(std.mem.indexOf(u8, result.content, "ziglang.org") != null);
            found_return = true;
        },
        else => {},
    };
    try std.testing.expect(call_id != null);
    try std.testing.expect(found_return);
    try std.testing.expectEqual(@as(?u64, 0), usage.detail("web_search_requests"));
    try std.testing.expectEqual(@as(?u64, 1), usage.detail("web_fetch_requests"));
}

fn expectGoogle(response: zigai.ResponseMessage, usage: zigai.RunUsage) !void {
    var found_grounding = false;
    for (response.parts) |part| switch (part) {
        .text_part => |value| {
            try expectProvider(value.provider, "gcp.gen_ai");
            const details = value.provider.provider_details.?.value.object;
            try std.testing.expect(details.get("groundingChunks").?.array.items.len > 0);
            try std.testing.expect(details.get("groundingSupports").?.array.items.len > 0);
            try std.testing.expect(details.get("webSearchQueries").?.array.items.len > 0);
            found_grounding = true;
        },
        else => {},
    };
    try std.testing.expect(found_grounding);
    try std.testing.expect(usage.reasoning_tokens > 0);
    try std.testing.expect(usage.cache_read_tokens > 0);
    try std.testing.expectEqual(@as(?u64, 844), usage.detail("total_tokens"));
}

fn expectMistral(response: zigai.ResponseMessage, usage: zigai.RunUsage) !void {
    var call_id: ?[]const u8 = null;
    var found_return = false;
    var found_reference = false;
    for (response.parts) |part| switch (part) {
        .native_tool_call => |call| {
            try std.testing.expectEqualStrings("web_search", call.name);
            try std.testing.expectEqualStrings("mistral", call.provider.provider_name.?);
            call_id = call.id;
        },
        .native_tool_return => |result| {
            try std.testing.expectEqualStrings("web_search", result.name);
            try expectProvider(result.provider, "mistral");
            if (call_id) |id| try std.testing.expectEqualStrings(id, result.call_id);
            try std.testing.expect(std.mem.indexOf(u8, result.content, "ziglang.org") != null);
            found_return = true;
        },
        .text_part => |value| if (value.provider.provider_details) |details| {
            const object = details.value.object;
            if (object.get("type")) |kind| if (std.mem.eql(u8, kind.string, "tool_reference")) {
                try std.testing.expectEqualStrings("mistral", value.provider.provider_name.?);
                try std.testing.expectEqualStrings("web_search", object.get("tool").?.string);
                try std.testing.expect(std.mem.startsWith(u8, object.get("url").?.string, "https://"));
                found_reference = true;
            };
        },
        else => {},
    };
    try std.testing.expect(call_id != null);
    try std.testing.expect(found_return);
    try std.testing.expect(found_reference);
    try std.testing.expect(usage.detail("connector_tokens").? > 0);
    try std.testing.expectEqual(@as(?u64, 1), usage.detail("connector.web_search.tokens"));
}

fn expectProvider(provider: zigai.ProviderPart, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, provider.provider_name.?);
    try std.testing.expect(provider.provider_details != null);
}

fn lastResponse(messages: []const zigai.Message) ?zigai.ResponseMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .response => |response| return response,
            .request => {},
        }
    }
    return null;
}
