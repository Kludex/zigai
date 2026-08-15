//! Explicit lifecycle for stored Mistral conversations.
//!
//! A session borrows its provider and conversation ID. Appended model input is
//! distinct from the stateless `Model` adapter, so retries cannot mutate
//! remote history unless the caller deliberately invokes this API.

const std = @import("std");
const common = @import("../common.zig");
const conversations = @import("conversations.zig");
const json_limits = @import("../../json.zig");
const model_types = @import("../../model.zig");
const provider_types = @import("../../provider.zig");
const transport = @import("../../transport.zig");

pub const Error = model_types.ProviderRequestError || error{
    /// The conversation ID is empty, oversized, or unsafe in a URL path.
    InvalidConversationId,
    /// A successful lifecycle response does not match Conversations.
    InvalidProviderResponse,
};

/// Stable entry families in Mistral conversation history.
pub const EntryKind = enum {
    message_input,
    message_output,
    function_call,
    function_result,
    tool_execution,
    agent_handoff,
    unknown,
};

/// One native history entry with its complete structured representation.
pub const Entry = struct {
    kind: EntryKind,
    id: ?[]const u8,
    details: model_types.ProviderDetails,
};

/// Arena-owned native conversation history.
pub const History = struct {
    arena: std.heap.ArenaAllocator,
    conversation_id: []const u8,
    entries: []const Entry,

    pub fn deinit(self: *History) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrowed handle for one stored Mistral conversation.
pub const Session = struct {
    provider: provider_types.Provider,
    conversation_id: []const u8,

    /// Creates a session after validating that its ID is safe in endpoint paths.
    pub fn init(provider: provider_types.Provider, conversation_id: []const u8) error{InvalidConversationId}!Session {
        try validateConversationId(conversation_id);
        return .{ .provider = provider, .conversation_id = conversation_id };
    }

    /// Appends new entries and runs the next stored completion.
    pub fn append(
        self: Session,
        allocator: std.mem.Allocator,
        request: model_types.ModelRequest,
    ) !model_types.ModelResponse {
        const body = try conversations.encodeAppendRequest(allocator, request);
        defer allocator.free(body);
        const request_path = try self.endpoint(allocator, "");
        defer allocator.free(request_path);
        var headers: std.ArrayList(transport.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
        if (request.request_id) |request_id|
            try headers.append(allocator, .{ .name = "x-client-request-id", .value = request_id });
        try common.appendRequestHeaders(allocator, &headers, request.settings.extra_headers);
        const response = self.provider.request(allocator, .{
            .method = .POST,
            .endpoint = request_path,
            .headers = headers.items,
            .body = body,
            .timeout_ms = request.timeout_ms,
            .cancellation = request.cancellation,
            .url_policy = request.url_policy,
        }) catch |failure| return common.transportError(failure);
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            self.provider.observeError(
                allocator,
                response.status,
                response.body,
                response.metadata,
                request.error_observer,
                request.error_policy,
            );
            return common.statusError(response.status);
        }
        const result = conversations.decodeResponse(allocator, response.body) catch |failure|
            return common.responseDecodeError(failure);
        if (!std.mem.eql(u8, result.conversation_id orelse "", self.conversation_id))
            return error.ProviderResponseDecodeError;
        return result;
    }

    /// Retrieves every native entry in append order.
    pub fn history(self: Session, gpa: std.mem.Allocator) !History {
        const request_path = try self.endpoint(gpa, "/history");
        defer gpa.free(request_path);
        const response = self.provider.request(gpa, .{ .method = .GET, .endpoint = request_path }) catch |failure|
            return common.transportError(failure);
        defer gpa.free(response.body);
        if (response.status < 200 or response.status >= 300) return common.statusError(response.status);

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const root = try json_limits.parseLeaky(
            std.json.Value,
            allocator,
            response.body,
            json_limits.defaults.provider_response,
            .{},
            error.InvalidProviderResponse,
        );
        const object = switch (root) {
            .object => |value| value,
            else => return error.InvalidProviderResponse,
        };
        const conversation_id = try common.objectString(object, "conversation_id");
        if (!std.mem.eql(u8, conversation_id, self.conversation_id)) return error.InvalidProviderResponse;
        const values = try common.requiredArray(root, "entries");
        const entries = try allocator.alloc(Entry, values.items.len);
        for (values.items, entries) |value, *entry| {
            const entry_object = switch (value) {
                .object => |item| item,
                else => return error.InvalidProviderResponse,
            };
            entry.* = .{
                .kind = entryKind(try common.objectString(entry_object, "type")),
                .id = try common.optionalObjectString(entry_object, "id"),
                .details = try model_types.ProviderDetails.fromValue(value),
            };
        }
        return .{ .arena = arena, .conversation_id = conversation_id, .entries = entries };
    }

    /// Permanently deletes the stored conversation from Mistral.
    pub fn delete(self: Session, allocator: std.mem.Allocator) !void {
        const request_path = try self.endpoint(allocator, "");
        defer allocator.free(request_path);
        const response = self.provider.request(allocator, .{ .method = .DELETE, .endpoint = request_path }) catch |failure|
            return common.transportError(failure);
        defer allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) return common.statusError(response.status);
    }

    fn endpoint(self: Session, allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
        try validateConversationId(self.conversation_id);
        return std.fmt.allocPrint(allocator, "/conversations/{s}{s}", .{ self.conversation_id, suffix });
    }
};

fn validateConversationId(value: []const u8) error{InvalidConversationId}!void {
    if (value.len == 0 or value.len > 128) return error.InvalidConversationId;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
        return error.InvalidConversationId;
}

fn entryKind(value: []const u8) EntryKind {
    if (std.mem.eql(u8, value, "message.input")) return .message_input;
    if (std.mem.eql(u8, value, "message.output")) return .message_output;
    if (std.mem.eql(u8, value, "function.call")) return .function_call;
    if (std.mem.eql(u8, value, "function.result")) return .function_result;
    if (std.mem.eql(u8, value, "tool.execution")) return .tool_execution;
    if (std.mem.eql(u8, value, "agent.handoff")) return .agent_handoff;
    return .unknown;
}

test "session appends inspects and deletes one stored conversation" {
    const State = struct {
        step: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            const body = switch (self.step) {
                0 => blk: {
                    try std.testing.expectEqual(transport.Method.POST, request.method);
                    try std.testing.expectEqualStrings("https://api.mistral.ai/v1/conversations/conv_1", request.url);
                    try std.testing.expect(std.mem.indexOf(u8, request.body, "\"store\":true") != null);
                    break :blk "{\"conversation_id\":\"conv_1\",\"outputs\":[{\"type\":\"message.output\",\"content\":\"next\"}],\"usage\":{}}";
                },
                1 => blk: {
                    try std.testing.expectEqual(transport.Method.GET, request.method);
                    try std.testing.expectEqualStrings("https://api.mistral.ai/v1/conversations/conv_1/history", request.url);
                    break :blk "{\"conversation_id\":\"conv_1\",\"entries\":[{\"object\":\"entry\",\"type\":\"message.input\",\"id\":\"entry_1\",\"role\":\"user\",\"content\":\"hello\"},{\"object\":\"entry\",\"type\":\"future.entry\"}]}";
                },
                2 => blk: {
                    try std.testing.expectEqual(transport.Method.DELETE, request.method);
                    try std.testing.expectEqualStrings("https://api.mistral.ai/v1/conversations/conv_1", request.url);
                    break :blk "";
                },
                else => return error.UnexpectedRequest,
            };
            self.step += 1;
            return .{ .status = if (self.step == 3) 204 else 200, .body = try allocator.dupe(u8, body) };
        }
    };
    var state: State = .{};
    var provider = conversations.Provider.init("secret", .{ .context = &state, .sendFn = State.send });
    const session = try Session.init(provider.provider(), "conv_1");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try session.append(arena.allocator(), .{
        .messages = &.{.{ .request = .{ .parts = &.{.{ .user_prompt = .{ .text = "next" } }} } }},
    });
    try std.testing.expectEqualStrings("next", response.parts[0].text);
    var history = try session.history(std.testing.allocator);
    defer history.deinit();
    try std.testing.expectEqual(EntryKind.message_input, history.entries[0].kind);
    try std.testing.expectEqualStrings("entry_1", history.entries[0].id.?);
    try std.testing.expectEqual(EntryKind.unknown, history.entries[1].kind);
    try session.delete(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), state.step);
}

test "session rejects unsafe conversation identifiers" {
    var marker: u8 = 0;
    const provider = provider_types.Provider{
        .context = &marker,
        .name = "mistral",
        .base_url = conversations.api_base,
        .requestFn = struct {
            fn send(_: *anyopaque, _: std.mem.Allocator, _: provider_types.Request) !transport.Response {
                return error.UnexpectedRequest;
            }
        }.send,
    };
    try std.testing.expectError(error.InvalidConversationId, Session.init(provider, ""));
    try std.testing.expectError(error.InvalidConversationId, Session.init(provider, "../other"));
    try std.testing.expectError(error.InvalidConversationId, Session.init(provider, "a" ** 129));
}
