//! Typed, borrowed value objects for MCP capability negotiation.
//!
//! These types encode the standardized capability surface without owning
//! application memory. Raw JSON remains available at the transport boundary
//! for forward-compatible capabilities and extensions.

const std = @import("std");
const json_limits = @import("../json.zig");

pub const Error = error{
    InvalidCapabilities,
    InvalidExtensionIdentifier,
    InvalidInputRequest,
    InvalidInputResponse,
    InvalidNotification,
    InvalidRequest,
};

/// Sampling features a client is prepared to provide through MRTR.
pub const SamplingCapabilities = struct {
    context: bool = false,
    tools: bool = false,
};

/// Elicitation modes a client is prepared to provide through MRTR.
pub const ElicitationCapabilities = struct {
    form: bool = false,
    url: bool = false,
};

/// Standardized client capabilities for one MCP request.
///
/// `experimental_json` and `extensions_json`, when present, must each encode a
/// JSON object. Experimental values and extension settings must be objects.
pub const ClientCapabilities = struct {
    roots: bool = false,
    sampling: ?SamplingCapabilities = null,
    elicitation: ?ElicitationCapabilities = null,
    experimental_json: ?[]const u8 = null,
    extensions_json: ?[]const u8 = null,

    /// Serializes an owned capability document. The caller frees the result.
    pub fn stringifyAlloc(self: ClientCapabilities, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};

        if (self.experimental_json) |source| {
            const experimental = try parseObject(memory, source);
            try validateObjectValues(experimental, error.InvalidCapabilities);
            try object.put(memory, "experimental", .{ .object = experimental });
        }
        if (self.roots) try object.put(memory, "roots", emptyObject());
        if (self.sampling) |sampling| {
            var value: std.json.ObjectMap = .{};
            if (sampling.context) try value.put(memory, "context", emptyObject());
            if (sampling.tools) try value.put(memory, "tools", emptyObject());
            try object.put(memory, "sampling", .{ .object = value });
        }
        if (self.elicitation) |elicitation| {
            var value: std.json.ObjectMap = .{};
            if (elicitation.form) try value.put(memory, "form", emptyObject());
            if (elicitation.url) try value.put(memory, "url", emptyObject());
            try object.put(memory, "elicitation", .{ .object = value });
        }
        if (self.extensions_json) |source| {
            const extensions = try parseObject(memory, source);
            try validateExtensions(extensions);
            try object.put(memory, "extensions", .{ .object = extensions });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

pub const PromptCapabilities = struct {
    list_changed: bool = false,
};

pub const ResourceCapabilities = struct {
    subscribe: bool = false,
    list_changed: bool = false,
};

pub const ToolCapabilities = struct {
    list_changed: bool = false,
};

/// Standardized capabilities advertised by an MCP server.
pub const ServerCapabilities = struct {
    logging: bool = false,
    completions: bool = false,
    prompts: ?PromptCapabilities = null,
    resources: ?ResourceCapabilities = null,
    tools: ?ToolCapabilities = null,
    experimental_json: ?[]const u8 = null,
    extensions_json: ?[]const u8 = null,

    /// Serializes an owned capability document. The caller frees the result.
    pub fn stringifyAlloc(self: ServerCapabilities, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};

        if (self.experimental_json) |source| {
            const experimental = try parseObject(memory, source);
            try validateObjectValues(experimental, error.InvalidCapabilities);
            try object.put(memory, "experimental", .{ .object = experimental });
        }
        if (self.logging) try object.put(memory, "logging", emptyObject());
        if (self.completions) try object.put(memory, "completions", emptyObject());
        if (self.prompts) |prompts| {
            var value: std.json.ObjectMap = .{};
            if (prompts.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "prompts", .{ .object = value });
        }
        if (self.resources) |resources| {
            var value: std.json.ObjectMap = .{};
            if (resources.subscribe) try value.put(memory, "subscribe", .{ .bool = true });
            if (resources.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "resources", .{ .object = value });
        }
        if (self.tools) |tools| {
            var value: std.json.ObjectMap = .{};
            if (tools.list_changed) try value.put(memory, "listChanged", .{ .bool = true });
            try object.put(memory, "tools", .{ .object = value });
        }
        if (self.extensions_json) |source| {
            const extensions = try parseObject(memory, source);
            try validateExtensions(extensions);
            try object.put(memory, "extensions", .{ .object = extensions });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

/// Server notifications selected for one `subscriptions/listen` request.
pub const SubscriptionFilter = struct {
    tools_list_changed: bool = false,
    prompts_list_changed: bool = false,
    resources_list_changed: bool = false,
    resource_subscriptions: []const []const u8 = &.{},

    /// Serializes the filter object expected under the request's
    /// `notifications` field. The caller owns the returned JSON.
    pub fn stringifyAlloc(self: SubscriptionFilter, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const object = try self.toObject(memory);
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }

    fn toObject(self: SubscriptionFilter, allocator: std.mem.Allocator) !std.json.ObjectMap {
        var object: std.json.ObjectMap = .{};
        if (self.tools_list_changed) try object.put(allocator, "toolsListChanged", .{ .bool = true });
        if (self.prompts_list_changed) try object.put(allocator, "promptsListChanged", .{ .bool = true });
        if (self.resources_list_changed) try object.put(allocator, "resourcesListChanged", .{ .bool = true });
        if (self.resource_subscriptions.len > 0) {
            var resources: std.json.Array = .init(allocator);
            for (self.resource_subscriptions) |uri| {
                try resources.append(.{ .string = uri });
            }
            try object.put(allocator, "resourceSubscriptions", .{ .array = resources });
        }
        return object;
    }
};

/// JSON-RPC request and subscription identifiers accepted by MCP.
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,

    fn jsonValue(self: RequestId) std.json.Value {
        return switch (self) {
            .integer => |value| .{ .integer = value },
            .string => |value| .{ .string = value },
        };
    }
};

/// The three input families a server may request through MRTR.
pub const InputKind = enum {
    elicitation,
    roots,
    sampling,

    pub fn fromMethod(method_name: []const u8) Error!InputKind {
        if (std.mem.eql(u8, method_name, "elicitation/create")) return .elicitation;
        if (std.mem.eql(u8, method_name, "roots/list")) return .roots;
        if (std.mem.eql(u8, method_name, "sampling/createMessage")) return .sampling;
        return error.InvalidInputRequest;
    }

    pub fn method(self: InputKind) []const u8 {
        return switch (self) {
            .elicitation => "elicitation/create",
            .roots => "roots/list",
            .sampling => "sampling/createMessage",
        };
    }
};

/// Borrowed, already-validated MRTR input presented to application code.
pub const InputRequest = struct {
    key: []const u8,
    kind: InputKind,
    /// Complete input-request JSON, borrowed for the callback duration.
    request_json: []const u8,
};

pub const ElicitationAction = enum {
    accept,
    decline,
    cancel,
};

pub const ElicitationResponse = struct {
    action: ElicitationAction,
    /// Accepted form values as one bounded JSON object.
    content_json: ?[]const u8 = null,
};

pub const Root = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
};

pub const RootsResponse = struct {
    roots: []const Root,
};

pub const SamplingRole = enum {
    user,
    assistant,
};

pub const SamplingResponse = struct {
    role: SamplingRole,
    /// One content block or an array of blocks encoded as bounded JSON.
    content_json: []const u8,
    model: []const u8,
    stop_reason: ?[]const u8 = null,
};

/// Typed response builders for all MRTR input families.
pub const InputResponse = union(enum) {
    elicitation: ElicitationResponse,
    roots: RootsResponse,
    sampling: SamplingResponse,

    pub fn kind(self: InputResponse) InputKind {
        return switch (self) {
            .elicitation => .elicitation,
            .roots => .roots,
            .sampling => .sampling,
        };
    }

    pub fn stringifyAlloc(self: InputResponse, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};
        switch (self) {
            .elicitation => |response| {
                try object.put(memory, "action", .{ .string = @tagName(response.action) });
                if (response.content_json) |source| {
                    if (response.action != .accept) return error.InvalidInputResponse;
                    const content = try parseInputObject(memory, source);
                    try validateElicitationContent(content);
                    try object.put(memory, "content", .{ .object = content });
                }
            },
            .roots => |response| {
                var roots: std.json.Array = .init(memory);
                for (response.roots) |root| {
                    if (!std.mem.startsWith(u8, root.uri, "file://")) return error.InvalidInputResponse;
                    var value: std.json.ObjectMap = .{};
                    try value.put(memory, "uri", .{ .string = root.uri });
                    if (root.name) |name| try value.put(memory, "name", .{ .string = name });
                    try roots.append(.{ .object = value });
                }
                try object.put(memory, "roots", .{ .array = roots });
            },
            .sampling => |response| {
                const content = try json_limits.parseLeaky(
                    std.json.Value,
                    memory,
                    response.content_json,
                    json_limits.defaults.mcp_message,
                    .{},
                    error.InvalidInputResponse,
                );
                if (content != .object and content != .array) return error.InvalidInputResponse;
                try object.put(memory, "role", .{ .string = @tagName(response.role) });
                try object.put(memory, "content", content);
                try object.put(memory, "model", .{ .string = response.model });
                if (response.stop_reason) |reason| try object.put(memory, "stopReason", .{ .string = reason });
            },
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

/// Parameters for `prompts/get`.
pub const PromptRequest = struct {
    name: []const u8,
    /// Optional argument map encoded as one bounded JSON object.
    arguments_json: ?[]const u8 = null,

    pub fn stringifyAlloc(self: PromptRequest, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var object: std.json.ObjectMap = .{};
        try object.put(memory, "name", .{ .string = self.name });
        if (self.arguments_json) |source| {
            try object.put(memory, "arguments", .{ .object = try parseRequestObject(memory, source) });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

pub const CompletionReference = union(enum) {
    prompt: []const u8,
    resource: []const u8,

    fn toObject(self: CompletionReference, allocator: std.mem.Allocator) !std.json.ObjectMap {
        var object: std.json.ObjectMap = .{};
        switch (self) {
            .prompt => |name| {
                try object.put(allocator, "type", .{ .string = "ref/prompt" });
                try object.put(allocator, "name", .{ .string = name });
            },
            .resource => |uri| {
                try object.put(allocator, "type", .{ .string = "ref/resource" });
                try object.put(allocator, "uri", .{ .string = uri });
            },
        }
        return object;
    }
};

/// Parameters for `completion/complete`.
pub const CompletionRequest = struct {
    reference: CompletionReference,
    argument_name: []const u8,
    argument_value: []const u8,
    /// Optional preceding argument map encoded as one bounded JSON object.
    context_arguments_json: ?[]const u8 = null,

    pub fn stringifyAlloc(self: CompletionRequest, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var argument: std.json.ObjectMap = .{};
        try argument.put(memory, "name", .{ .string = self.argument_name });
        try argument.put(memory, "value", .{ .string = self.argument_value });
        var object: std.json.ObjectMap = .{};
        try object.put(memory, "ref", .{ .object = try self.reference.toObject(memory) });
        try object.put(memory, "argument", .{ .object = argument });
        if (self.context_arguments_json) |source| {
            var context: std.json.ObjectMap = .{};
            try context.put(memory, "arguments", .{ .object = try parseRequestObject(memory, source) });
            try object.put(memory, "context", .{ .object = context });
        }
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    }
};

pub const LoggingLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,
};

pub const CancelledNotification = struct {
    request_id: RequestId,
    reason: ?[]const u8 = null,
};

pub const ProgressNotification = struct {
    progress_token: RequestId,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

pub const LoggingNotification = struct {
    level: LoggingLevel,
    logger: ?[]const u8 = null,
    /// One complete bounded JSON value. It remains borrowed.
    data_json: []const u8,
};

/// One standardized MCP notification. The serializer owns JSON-RPC framing;
/// the caller owns only the returned byte slice.
pub const Notification = union(enum) {
    cancelled: CancelledNotification,
    progress: ProgressNotification,
    logging_message: LoggingNotification,
    resource_updated: []const u8,
    resource_list_changed,
    prompt_list_changed,
    tool_list_changed,
    subscriptions_acknowledged: SubscriptionFilter,

    pub fn stringifyAlloc(
        self: Notification,
        allocator: std.mem.Allocator,
        subscription_id: ?RequestId,
    ) ![]u8 {
        if (self.requiresSubscription() and subscription_id == null) return error.InvalidNotification;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var params: std.json.ObjectMap = .{};
        const method: []const u8 = switch (self) {
            .cancelled => |value| blk: {
                try params.put(memory, "requestId", value.request_id.jsonValue());
                if (value.reason) |reason| try params.put(memory, "reason", .{ .string = reason });
                break :blk "notifications/cancelled";
            },
            .progress => |value| blk: {
                if (!std.math.isFinite(value.progress) or
                    (value.total != null and !std.math.isFinite(value.total.?)))
                {
                    return error.InvalidNotification;
                }
                try params.put(memory, "progressToken", value.progress_token.jsonValue());
                try params.put(memory, "progress", .{ .float = value.progress });
                if (value.total) |total| try params.put(memory, "total", .{ .float = total });
                if (value.message) |message| try params.put(memory, "message", .{ .string = message });
                break :blk "notifications/progress";
            },
            .logging_message => |value| blk: {
                const data = try json_limits.parseLeaky(
                    std.json.Value,
                    memory,
                    value.data_json,
                    json_limits.defaults.mcp_message,
                    .{},
                    error.InvalidNotification,
                );
                try params.put(memory, "level", .{ .string = @tagName(value.level) });
                if (value.logger) |logger| try params.put(memory, "logger", .{ .string = logger });
                try params.put(memory, "data", data);
                break :blk "notifications/message";
            },
            .resource_updated => |uri| blk: {
                try params.put(memory, "uri", .{ .string = uri });
                break :blk "notifications/resources/updated";
            },
            .resource_list_changed => "notifications/resources/list_changed",
            .prompt_list_changed => "notifications/prompts/list_changed",
            .tool_list_changed => "notifications/tools/list_changed",
            .subscriptions_acknowledged => |filter| blk: {
                try params.put(memory, "notifications", .{ .object = try filter.toObject(memory) });
                break :blk "notifications/subscriptions/acknowledged";
            },
        };
        if (subscription_id) |id| {
            var meta: std.json.ObjectMap = .{};
            try meta.put(memory, "io.modelcontextprotocol/subscriptionId", id.jsonValue());
            try params.put(memory, "_meta", .{ .object = meta });
        }
        return std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = std.json.Value{ .object = params },
        }, .{});
    }

    fn requiresSubscription(self: Notification) bool {
        return switch (self) {
            .resource_updated,
            .resource_list_changed,
            .prompt_list_changed,
            .tool_list_changed,
            .subscriptions_acknowledged,
            => true,
            .cancelled, .progress, .logging_message => false,
        };
    }
};

/// MCP extension identifiers use a reverse-DNS prefix and one slash.
pub fn isExtensionIdentifier(value: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (separator == 0 or std.mem.indexOfScalarPos(u8, value, separator + 1, '/') != null) return false;
    var labels = std.mem.splitScalar(u8, value[0..separator], '.');
    while (labels.next()) |label| {
        if (label.len == 0 or !std.ascii.isAlphabetic(label[0]) or
            !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        if (label.len > 2) {
            for (label[1 .. label.len - 1]) |character| {
                if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
            }
        }
    }
    const name = value[separator + 1 ..];
    if (name.len == 0) return true;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    if (name.len > 2) {
        for (name[1 .. name.len - 1]) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '-' and
                character != '_' and character != '.') return false;
        }
    }
    return true;
}

fn emptyObject() std.json.Value {
    return .{ .object = .{} };
}

fn parseObject(allocator: std.mem.Allocator, source: []const u8) !std.json.ObjectMap {
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidCapabilities,
    );
    return switch (value) {
        .object => |object| object,
        else => error.InvalidCapabilities,
    };
}

fn parseRequestObject(allocator: std.mem.Allocator, source: []const u8) !std.json.ObjectMap {
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidRequest,
    );
    return switch (value) {
        .object => |object| object,
        else => error.InvalidRequest,
    };
}

fn parseInputObject(allocator: std.mem.Allocator, source: []const u8) !std.json.ObjectMap {
    const value = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        source,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidInputResponse,
    );
    return switch (value) {
        .object => |object| object,
        else => error.InvalidInputResponse,
    };
}

fn validateElicitationContent(object: std.json.ObjectMap) Error!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| switch (entry.value_ptr.*) {
        .string, .integer, .float, .bool => {},
        .array => |items| for (items.items) |item| if (item != .string) return error.InvalidInputResponse,
        else => return error.InvalidInputResponse,
    };
}

fn validateObjectValues(object: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.* != .object) return invalid_error;
}

fn validateExtensions(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isExtensionIdentifier(entry.key_ptr.*)) return error.InvalidExtensionIdentifier;
        if (entry.value_ptr.* != .object) return error.InvalidCapabilities;
    }
}

test "typed MCP capability documents preserve standardized and extension settings" {
    const client_json = try (ClientCapabilities{
        .roots = true,
        .sampling = .{ .context = true, .tools = true },
        .elicitation = .{ .form = true, .url = true },
        .experimental_json = "{\"preview\":{\"enabled\":true}}",
        .extensions_json = "{\"com.example/feature\":{\"mode\":\"strict\"}}",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(client_json);
    try std.testing.expectEqualStrings(
        "{\"experimental\":{\"preview\":{\"enabled\":true}},\"roots\":{}," ++
            "\"sampling\":{\"context\":{},\"tools\":{}}," ++
            "\"elicitation\":{\"form\":{},\"url\":{}}," ++
            "\"extensions\":{\"com.example/feature\":{\"mode\":\"strict\"}}}",
        client_json,
    );

    const server_json = try (ServerCapabilities{
        .logging = true,
        .completions = true,
        .prompts = .{ .list_changed = true },
        .resources = .{ .subscribe = true, .list_changed = true },
        .tools = .{},
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(server_json);
    try std.testing.expectEqualStrings(
        "{\"logging\":{},\"completions\":{},\"prompts\":{\"listChanged\":true}," ++
            "\"resources\":{\"subscribe\":true,\"listChanged\":true},\"tools\":{}}",
        server_json,
    );
}

test "typed MCP capability documents reject malformed open settings" {
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ClientCapabilities{ .experimental_json = "[]" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ClientCapabilities{ .experimental_json = "{\"preview\":true}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidExtensionIdentifier,
        (ServerCapabilities{ .extensions_json = "{\"unprefixed\":{}}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidCapabilities,
        (ServerCapabilities{ .extensions_json = "{\"com.example/feature\":true}" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expect(isExtensionIdentifier("com.example/feature_name-1"));
    try std.testing.expect(!isExtensionIdentifier("1example/feature"));
    try std.testing.expect(!isExtensionIdentifier("com..example/feature"));
    try std.testing.expect(!isExtensionIdentifier("com.example/two/paths"));
    try std.testing.expect(!isExtensionIdentifier("com.example/-feature"));
}

test "typed MCP subscription filters serialize selected notifications" {
    const source = try (SubscriptionFilter{
        .tools_list_changed = true,
        .resources_list_changed = true,
        .resource_subscriptions = &.{ "file:///a", "https://example.com/resource" },
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        "{\"toolsListChanged\":true,\"resourcesListChanged\":true," ++
            "\"resourceSubscriptions\":[\"file:///a\",\"https://example.com/resource\"]}",
        source,
    );
    const empty = try (SubscriptionFilter{}).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("{}", empty);
}

test "typed MCP input kinds map every MRTR method" {
    const kinds = [_]InputKind{ .elicitation, .roots, .sampling };
    for (kinds) |kind| try std.testing.expectEqual(kind, try InputKind.fromMethod(kind.method()));
    try std.testing.expectError(error.InvalidInputRequest, InputKind.fromMethod("com.example/input"));
}

test "typed MCP input responses serialize elicitation roots and sampling" {
    const responses = [_]struct {
        value: InputResponse,
        kind: InputKind,
        marker: []const u8,
    }{
        .{
            .value = .{ .elicitation = .{
                .action = .accept,
                .content_json = "{\"confirmed\":true,\"tags\":[\"safe\"]}",
            } },
            .kind = .elicitation,
            .marker = "\"action\":\"accept\"",
        },
        .{
            .value = .{ .roots = .{ .roots = &.{
                .{ .uri = "file:///workspace", .name = "workspace" },
                .{ .uri = "file:///tmp" },
            } } },
            .kind = .roots,
            .marker = "file:///workspace",
        },
        .{
            .value = .{ .sampling = .{
                .role = .assistant,
                .content_json = "[{\"type\":\"text\",\"text\":\"done\"}]",
                .model = "example-model",
                .stop_reason = "end_turn",
            } },
            .kind = .sampling,
            .marker = "example-model",
        },
    };
    for (responses) |response| {
        try std.testing.expectEqual(response.kind, response.value.kind());
        const source = try response.value.stringifyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, response.marker) != null);
    }
    const declined = try (InputResponse{ .elicitation = .{ .action = .decline } }).stringifyAlloc(
        std.testing.allocator,
    );
    defer std.testing.allocator.free(declined);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", declined);
}

test "typed MCP input responses reject invalid content and roots" {
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .elicitation = .{
            .action = .cancel,
            .content_json = "{\"value\":true}",
        } }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .elicitation = .{
            .action = .accept,
            .content_json = "{\"value\":{}}",
        } }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .elicitation = .{
            .action = .accept,
            .content_json = "{\"values\":[1]}",
        } }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .roots = .{ .roots = &.{.{ .uri = "https://example.com" }} } }).stringifyAlloc(
            std.testing.allocator,
        ),
    );
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .sampling = .{
            .role = .user,
            .content_json = "\"text\"",
            .model = "example-model",
        } }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidInputResponse,
        (InputResponse{ .sampling = .{
            .role = .user,
            .content_json = "{",
            .model = "example-model",
        } }).stringifyAlloc(std.testing.allocator),
    );
}

test "typed MCP prompt and completion requests preserve arguments" {
    const prompt = try (PromptRequest{
        .name = "review",
        .arguments_json = "{\"language\":\"zig\"}",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "{\"name\":\"review\",\"arguments\":{\"language\":\"zig\"}}",
        prompt,
    );

    const prompt_completion = try (CompletionRequest{
        .reference = .{ .prompt = "review" },
        .argument_name = "language",
        .argument_value = "z",
        .context_arguments_json = "{\"style\":\"brief\"}",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(prompt_completion);
    try std.testing.expectEqualStrings(
        "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"review\"}," ++
            "\"argument\":{\"name\":\"language\",\"value\":\"z\"}," ++
            "\"context\":{\"arguments\":{\"style\":\"brief\"}}}",
        prompt_completion,
    );

    const resource_completion = try (CompletionRequest{
        .reference = .{ .resource = "file:///{path}" },
        .argument_name = "path",
        .argument_value = "src",
    }).stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(resource_completion);
    try std.testing.expect(std.mem.indexOf(u8, resource_completion, "ref/resource") != null);
    try std.testing.expect(std.mem.indexOf(u8, resource_completion, "file:///{path}") != null);
}

test "typed MCP prompt and completion requests reject malformed argument maps" {
    try std.testing.expectError(
        error.InvalidRequest,
        (PromptRequest{ .name = "review", .arguments_json = "[]" }).stringifyAlloc(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        (CompletionRequest{
            .reference = .{ .prompt = "review" },
            .argument_name = "language",
            .argument_value = "z",
            .context_arguments_json = "{",
        }).stringifyAlloc(std.testing.allocator),
    );
}

test "typed MCP notifications serialize every standardized event" {
    const cases = [_]struct {
        value: Notification,
        method: []const u8,
    }{
        .{
            .value = .{ .cancelled = .{ .request_id = .{ .string = "job-1" }, .reason = "done" } },
            .method = "notifications/cancelled",
        },
        .{
            .value = .{ .progress = .{
                .progress_token = .{ .integer = 4 },
                .progress = 0.5,
                .total = 1,
                .message = "working",
            } },
            .method = "notifications/progress",
        },
        .{
            .value = .{ .logging_message = .{
                .level = .warning,
                .logger = "worker",
                .data_json = "{\"attempt\":2}",
            } },
            .method = "notifications/message",
        },
        .{ .value = .{ .resource_updated = "file:///a" }, .method = "notifications/resources/updated" },
        .{ .value = .resource_list_changed, .method = "notifications/resources/list_changed" },
        .{ .value = .prompt_list_changed, .method = "notifications/prompts/list_changed" },
        .{ .value = .tool_list_changed, .method = "notifications/tools/list_changed" },
        .{
            .value = .{ .subscriptions_acknowledged = .{ .tools_list_changed = true } },
            .method = "notifications/subscriptions/acknowledged",
        },
    };
    for (cases) |case| {
        const source = try case.value.stringifyAlloc(std.testing.allocator, .{ .integer = 7 });
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, case.method) != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "io.modelcontextprotocol/subscriptionId") != null);
    }
}

test "typed MCP notifications reject invalid correlation progress and data" {
    try std.testing.expectError(
        error.InvalidNotification,
        (Notification{ .resource_list_changed = {} }).stringifyAlloc(std.testing.allocator, null),
    );
    try std.testing.expectError(
        error.InvalidNotification,
        (Notification{ .progress = .{
            .progress_token = .{ .integer = 1 },
            .progress = std.math.nan(f64),
        } }).stringifyAlloc(std.testing.allocator, null),
    );
    try std.testing.expectError(
        error.InvalidNotification,
        (Notification{ .progress = .{
            .progress_token = .{ .integer = 1 },
            .progress = 1,
            .total = std.math.inf(f64),
        } }).stringifyAlloc(std.testing.allocator, null),
    );
    try std.testing.expectError(
        error.InvalidNotification,
        (Notification{ .logging_message = .{
            .level = .info,
            .data_json = "{",
        } }).stringifyAlloc(std.testing.allocator, null),
    );
}

test "typed MCP capability serialization releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const client = try (ClientCapabilities{
                .roots = true,
                .sampling = .{ .context = true, .tools = true },
                .elicitation = .{ .form = true, .url = true },
                .experimental_json = "{\"preview\":{}}",
                .extensions_json = "{\"com.example/feature\":{}}",
            }).stringifyAlloc(allocator);
            defer allocator.free(client);
            const server = try (ServerCapabilities{
                .logging = true,
                .completions = true,
                .prompts = .{ .list_changed = true },
                .resources = .{ .subscribe = true, .list_changed = true },
                .tools = .{ .list_changed = true },
                .experimental_json = "{\"preview\":{}}",
                .extensions_json = "{\"com.example/feature\":{}}",
            }).stringifyAlloc(allocator);
            defer allocator.free(server);
            const filter = try (SubscriptionFilter{
                .tools_list_changed = true,
                .prompts_list_changed = true,
                .resources_list_changed = true,
                .resource_subscriptions = &.{ "file:///a", "file:///b" },
            }).stringifyAlloc(allocator);
            defer allocator.free(filter);
            const notification = try (Notification{ .logging_message = .{
                .level = .debug,
                .logger = "worker",
                .data_json = "{\"message\":\"ready\"}",
            } }).stringifyAlloc(allocator, .{ .string = "subscription" });
            defer allocator.free(notification);
            const acknowledged = try (Notification{ .subscriptions_acknowledged = .{
                .resource_subscriptions = &.{ "file:///a", "file:///b" },
            } }).stringifyAlloc(allocator, .{ .integer = 1 });
            defer allocator.free(acknowledged);
            const prompt = try (PromptRequest{
                .name = "review",
                .arguments_json = "{\"language\":\"zig\"}",
            }).stringifyAlloc(allocator);
            defer allocator.free(prompt);
            const completion = try (CompletionRequest{
                .reference = .{ .resource = "file:///{path}" },
                .argument_name = "path",
                .argument_value = "src",
                .context_arguments_json = "{\"root\":\"project\"}",
            }).stringifyAlloc(allocator);
            defer allocator.free(completion);
            const elicitation = try (InputResponse{ .elicitation = .{
                .action = .accept,
                .content_json = "{\"confirmed\":true}",
            } }).stringifyAlloc(allocator);
            defer allocator.free(elicitation);
            const roots = try (InputResponse{ .roots = .{ .roots = &.{
                .{ .uri = "file:///workspace", .name = "workspace" },
                .{ .uri = "file:///tmp" },
            } } }).stringifyAlloc(allocator);
            defer allocator.free(roots);
            const sampling = try (InputResponse{ .sampling = .{
                .role = .assistant,
                .content_json = "{\"type\":\"text\",\"text\":\"done\"}",
                .model = "example-model",
                .stop_reason = "end_turn",
            } }).stringifyAlloc(allocator);
            defer allocator.free(sampling);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
