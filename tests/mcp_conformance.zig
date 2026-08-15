//! Executable inventory for the MCP 2026-07-28 core protocol surface.
//!
//! This matrix stays in tests because it describes interoperability evidence,
//! not runtime state. Extension methods remain intentionally open-ended.

const std = @import("std");
const zigai = @import("zigai");

const Flow = enum {
    client_request,
    client_notification,
    server_notification,
    mrtr_input_request,
};

const Lifecycle = enum { active, deprecated };

const Capability = enum {
    base,
    completions,
    elicitation,
    logging,
    prompts,
    resources,
    roots,
    sampling,
    subscriptions,
    tools,
};

const Handling = enum {
    typed_client,
    typed_client_and_server,
    generic_event,
    generic_mrtr,
};

const Entry = struct {
    method: []const u8,
    flow: Flow,
    capability: Capability,
    lifecycle: Lifecycle = .active,
    handling: Handling,
};

const messages = [_]Entry{
    .{ .method = zigai.mcp.methods.discover, .flow = .client_request, .capability = .base, .handling = .typed_client_and_server },
    .{ .method = zigai.mcp.methods.complete, .flow = .client_request, .capability = .completions, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.get_prompt, .flow = .client_request, .capability = .prompts, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.list_prompts, .flow = .client_request, .capability = .prompts, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.list_resources, .flow = .client_request, .capability = .resources, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.list_resource_templates, .flow = .client_request, .capability = .resources, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.read_resource, .flow = .client_request, .capability = .resources, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.listen, .flow = .client_request, .capability = .subscriptions, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.call_tool, .flow = .client_request, .capability = .tools, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.list_tools, .flow = .client_request, .capability = .tools, .handling = .typed_client },
    .{ .method = zigai.mcp.methods.cancelled, .flow = .client_notification, .capability = .base, .handling = .typed_client_and_server },
    .{ .method = zigai.mcp.methods.cancelled, .flow = .server_notification, .capability = .subscriptions, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.progress, .flow = .server_notification, .capability = .base, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.logging_message, .flow = .server_notification, .capability = .logging, .lifecycle = .deprecated, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.resource_updated, .flow = .server_notification, .capability = .resources, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.resource_list_changed, .flow = .server_notification, .capability = .resources, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.tool_list_changed, .flow = .server_notification, .capability = .tools, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.prompt_list_changed, .flow = .server_notification, .capability = .prompts, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.subscriptions_acknowledged, .flow = .server_notification, .capability = .subscriptions, .handling = .generic_event },
    .{ .method = zigai.mcp.methods.elicit, .flow = .mrtr_input_request, .capability = .elicitation, .handling = .generic_mrtr },
    .{ .method = zigai.mcp.methods.list_roots, .flow = .mrtr_input_request, .capability = .roots, .lifecycle = .deprecated, .handling = .generic_mrtr },
    .{ .method = zigai.mcp.methods.create_message, .flow = .mrtr_input_request, .capability = .sampling, .lifecycle = .deprecated, .handling = .generic_mrtr },
};

test "MCP core message matrix is complete unique by flow and versioned" {
    try std.testing.expectEqualStrings("2026-07-28", zigai.mcp.protocol_version);
    try std.testing.expectEqual(@as(usize, 22), messages.len);
    for (messages, 0..) |entry, index| {
        try std.testing.expect(std.mem.indexOfScalar(u8, entry.method, '/') != null);
        for (messages[0..index]) |previous| {
            try std.testing.expect(!(entry.flow == previous.flow and std.mem.eql(u8, entry.method, previous.method)));
        }
    }
}

test "MCP deprecated core features remain explicit compatibility paths" {
    var deprecated: usize = 0;
    for (messages) |entry| {
        if (entry.lifecycle == .deprecated) {
            deprecated += 1;
            try std.testing.expect(entry.capability == .logging or entry.capability == .roots or entry.capability == .sampling);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), deprecated);
}

test "MCP matrix separates typed APIs generic events and MRTR inputs" {
    var typed: usize = 0;
    var events: usize = 0;
    var mrtr: usize = 0;
    for (messages) |entry| switch (entry.handling) {
        .typed_client, .typed_client_and_server => typed += 1,
        .generic_event => events += 1,
        .generic_mrtr => mrtr += 1,
    };
    try std.testing.expectEqual(@as(usize, 11), typed);
    try std.testing.expectEqual(@as(usize, 8), events);
    try std.testing.expectEqual(@as(usize, 3), mrtr);
}
