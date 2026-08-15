//! Model Context Protocol 2026-07-28 client, server, and transports.
//!
//! The latest MCP revision is stateless: every request carries its protocol
//! version, client identity, and capabilities. The generic request/handler
//! APIs intentionally preserve unknown fields so MCP extensions work without
//! waiting for a ZigAI release.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");
const model = @import("model.zig");
const http = @import("transport.zig");
const json_limits = @import("json.zig");

/// OAuth 2.1 and deployment-security contracts for Streamable HTTP.
pub const auth = @import("mcp/auth.zig");
/// Typed capability value objects for the MCP wire protocol.
pub const primitives = @import("mcp/primitives.zig");
/// Typed contracts for the `io.modelcontextprotocol/tasks` extension.
pub const tasks = @import("mcp/tasks.zig");
/// Durable client state for resumable MCP tasks.
pub const task_store = @import("mcp/task_store.zig");
const security = @import("security.zig");

test {
    _ = tasks;
    _ = task_store;
}

/// Latest stable MCP protocol revision supported by ZigAI.
pub const protocol_version = "2026-07-28";

pub const ClientCapabilities = primitives.ClientCapabilities;
pub const CompletionReference = primitives.CompletionReference;
pub const CompletionRequest = primitives.CompletionRequest;
pub const InputKind = primitives.InputKind;
pub const InputRequest = primitives.InputRequest;
pub const InputResponse = primitives.InputResponse;
pub const LoggingLevel = primitives.LoggingLevel;
pub const Notification = primitives.Notification;
pub const PromptRequest = primitives.PromptRequest;
pub const RequestId = primitives.RequestId;
pub const RequestMetadata = primitives.RequestMetadata;
pub const ServerCapabilities = primitives.ServerCapabilities;
pub const SubscriptionFilter = primitives.SubscriptionFilter;

/// Era detected by the compatibility probes defined in MCP 2026-07-28.
pub const CompatibilityEra = enum { modern, legacy, indeterminate };

/// JSON-RPC and MCP error codes defined by the current specification.
pub const error_codes = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const header_mismatch = -32020;
    pub const missing_required_client_capability = -32021;
    pub const unsupported_protocol_version = -32022;
};

/// Core MCP methods. Extension methods can be passed to `Client.request`.
pub const methods = struct {
    pub const discover = "server/discover";
    pub const complete = "completion/complete";
    pub const create_message = "sampling/createMessage";
    pub const elicit = "elicitation/create";
    pub const get_prompt = "prompts/get";
    pub const list_roots = "roots/list";
    pub const list_prompts = "prompts/list";
    pub const list_resources = "resources/list";
    pub const list_resource_templates = "resources/templates/list";
    pub const read_resource = "resources/read";
    pub const listen = "subscriptions/listen";
    pub const call_tool = "tools/call";
    pub const list_tools = "tools/list";
    pub const cancelled = "notifications/cancelled";
    pub const logging_message = "notifications/message";
    pub const progress = "notifications/progress";
    pub const prompt_list_changed = "notifications/prompts/list_changed";
    pub const resource_list_changed = "notifications/resources/list_changed";
    pub const resource_updated = "notifications/resources/updated";
    pub const subscriptions_acknowledged = "notifications/subscriptions/acknowledged";
    pub const tool_list_changed = "notifications/tools/list_changed";
};

/// Classifies a `server/discover` stdio probe without initiating a legacy session.
pub fn classifyStdioCompatibility(
    allocator: std.mem.Allocator,
    response_json: []const u8,
) !CompatibilityEra {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = parseResponse(arena.allocator(), response_json) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .legacy,
    };
    const object = requiredObject(root) catch return .legacy;
    if (!validJsonRpcResponseObject(object)) return .legacy;
    if (object.get("result")) |result| {
        validateMethodResult(methods.discover, result) catch return .legacy;
        return .modern;
    }
    return if (recognizedModernError(object.get("error") orelse return .legacy)) .modern else .legacy;
}

/// Classifies the first Streamable HTTP response using the 2026-07-28 rules.
pub fn classifyHttpCompatibility(
    allocator: std.mem.Allocator,
    status: u16,
    response_json: []const u8,
) !CompatibilityEra {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = parseResponse(arena.allocator(), response_json) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return if (status >= 400 and status < 500) .legacy else .indeterminate,
    };
    const object = requiredObject(root) catch
        return if (status >= 400 and status < 500) .legacy else .indeterminate;
    if (!validJsonRpcResponseObject(object)) {
        return if (status >= 400 and status < 500) .legacy else .indeterminate;
    }
    if (status >= 200 and status < 300 and object.get("result") != null) return .modern;
    if (status >= 400 and status < 500) {
        return if (recognizedModernError(object.get("error") orelse return .legacy)) .modern else .legacy;
    }
    return .indeterminate;
}

/// Returns owned JSON settings for one advertised extension, or `null`.
pub fn extensionSettings(
    allocator: std.mem.Allocator,
    capabilities_json: []const u8,
    identifier: []const u8,
) !?[]u8 {
    if (!validPrefixedMetaKey(identifier)) return error.InvalidMcpMessage;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const capabilities_value = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        capabilities_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    const capabilities = try capabilityObject(capabilities_value, error.InvalidMcpMessage);
    const extensions_value = capabilities.get("extensions") orelse return null;
    try validateExtensions(extensions_value, error.InvalidMcpMessage);
    const extensions = try capabilityObject(extensions_value, error.InvalidMcpMessage);
    const settings = extensions.get(identifier) orelse return null;
    return try std.json.Stringify.valueAlloc(allocator, settings, .{});
}

/// MCP protocol and transport failures defined by ZigAI.
pub const Error = error{
    /// A typed capability document contains malformed open JSON settings.
    InvalidCapabilities,
    /// An extension capability lacks a valid reverse-DNS prefix.
    InvalidExtensionIdentifier,
    /// An MRTR input method is not elicitation, roots, or sampling.
    InvalidInputRequest,
    /// A typed MRTR response violates its input family's contract.
    InvalidInputResponse,
    /// A typed notification has invalid data or missing stream correlation.
    InvalidNotification,
    /// A typed MCP request contains malformed embedded JSON.
    InvalidRequest,
    /// An OAuth token, response, or metadata document names another issuer.
    InvalidAuthorizationIssuer,
    /// OAuth/OIDC discovery metadata is malformed or unsafe.
    InvalidAuthorizationServerMetadata,
    /// A Bearer challenge is malformed or ambiguous.
    InvalidBearerChallenge,
    /// A Bearer token is malformed, unsafe, or conflicts with token policy.
    InvalidBearerToken,
    /// A browser Origin is malformed or outside deployment policy.
    InvalidOrigin,
    /// RFC 9728 protected-resource metadata is malformed or mismatched.
    InvalidProtectedResourceMetadata,
    /// A required request Host is absent, malformed, or mismatched.
    InvalidRequestHost,
    /// The canonical OAuth resource URI is invalid or differs from the endpoint.
    InvalidResourceUri,
    /// Protected MCP HTTP was attempted over unapproved cleartext.
    InsecureHttpTransport,
    /// RFC 9207 issuer output was required but absent.
    MissingAuthorizationIssuer,
    /// Authorization-server metadata does not advertise S256 PKCE.
    PkceUnsupported,
    /// A stdio transport was configured without a program command.
    EmptyCommand,
    /// An MCP header value does not match its schema annotation.
    HeaderMismatch,
    /// A server requested elicitation input but no handler supplied it.
    InputRequired,
    /// Tool header annotations are malformed or use unsupported schema shapes.
    InvalidMcpHeaderAnnotation,
    /// A received JSON-RPC message is malformed or exceeds structural rules.
    InvalidMcpMessage,
    /// A response result does not match the expected MCP method shape.
    InvalidMcpResponse,
    /// Tool arguments are not one valid bounded JSON object.
    InvalidMcpToolArguments,
    /// Streamable HTTP returned a non-success transport response.
    McpHttpRequestFailed,
    /// An MCP request, response, or event exceeded its configured byte limit.
    McpMessageTooLarge,
    /// A stdio MCP child closed before returning the matching response.
    McpProcessClosed,
    /// A JSON-RPC response ID differs from the outstanding request ID.
    McpResponseIdMismatch,
    /// The peer returned a JSON-RPC error envelope.
    McpRpcError,
    /// A paginated MCP collection repeated an already-seen cursor.
    McpPaginationCursorCycle,
    /// An MCP-backed toolset was used without its client.
    MissingMcpClient,
    /// A Tasks request was attempted without its per-request extension opt-in.
    MissingMcpClientCapability,
    /// Polling a non-terminal task needs an I/O runtime for the next delay.
    TaskPollingRequiresIo,
    /// A durable task snapshot is malformed or has an unsupported version.
    InvalidTaskStore,
    /// A durable task snapshot exceeds its configured byte bound.
    TaskStoreTooLarge,
    /// Durable task resumption was requested without a configured store.
    MissingMcpTaskStore,
    /// An MCP transport concurrency or buffering limit is invalid.
    InvalidMcpTransportConfiguration,
    /// Streamable HTTP did not provide the required SSE response stream.
    MissingMcpSseResponse,
    /// Elicitation exceeded the configured request/response round-trip limit.
    TooManyMcpRoundTrips,
    /// A paginated MCP collection exceeded the configured page limit.
    TooManyMcpPages,
    /// Task polling exceeded its explicit request bound.
    TooManyMcpTaskPolls,
    /// Discovery negotiated a protocol revision ZigAI does not support.
    UnsupportedMcpProtocolVersion,
};

/// Receives JSON-RPC notifications emitted while a request is active.
pub const EventSink = struct {
    context: *anyopaque,
    eventFn: *const fn (context: *anyopaque, message_json: []const u8) anyerror!void,

    pub fn emit(self: EventSink, message_json: []const u8) !void {
        return self.eventFn(self.context, message_json);
    }
};

/// Metadata needed by MCP transports in addition to the JSON-RPC body.
pub const WireRequest = struct {
    message: []const u8,
    method: []const u8,
    expects_response: bool = true,
    routing_name: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    events: ?EventSink = null,
};

/// Pluggable MCP JSON-RPC transport. Returned response bytes are caller-owned.
pub const Transport = struct {
    context: *anyopaque,
    sendFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: WireRequest,
    ) anyerror![]const u8,

    pub fn send(self: Transport, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        return self.sendFn(self.context, allocator, request);
    }
};

/// MCP Streamable HTTP transport for the stateless 2026-07-28 protocol.
pub const StreamableHttpOptions = struct {
    url_policy: security.UrlPolicy = .{},
    authorization: ?auth.ClientPolicy = null,
    /// Maximum requests admitted to the underlying HTTP transport at once.
    max_in_flight: usize = 64,
};

pub const StreamableHttpTransport = struct {
    io: std.Io,
    inner: http.Transport,
    endpoint: []const u8,
    headers: []const http.Header = &.{},
    url_policy: security.UrlPolicy = .{},
    authorization: ?auth.ClientPolicy = null,
    max_in_flight: usize = 64,
    in_flight: std.Io.Semaphore = .{ .permits = 64 },

    pub fn init(io: std.Io, inner: http.Transport, endpoint: []const u8) StreamableHttpTransport {
        return initWithPolicy(io, inner, endpoint, .{});
    }

    /// Initializes Streamable HTTP with an explicit endpoint policy.
    pub fn initWithPolicy(
        io: std.Io,
        inner: http.Transport,
        endpoint: []const u8,
        url_policy: security.UrlPolicy,
    ) StreamableHttpTransport {
        return initWithOptions(io, inner, endpoint, .{ .url_policy = url_policy });
    }

    /// Initializes Streamable HTTP with endpoint and authorization policies.
    pub fn initWithOptions(
        io: std.Io,
        inner: http.Transport,
        endpoint: []const u8,
        options: StreamableHttpOptions,
    ) StreamableHttpTransport {
        return .{
            .io = io,
            .inner = inner,
            .endpoint = endpoint,
            .url_policy = options.url_policy,
            .authorization = options.authorization,
            .max_in_flight = options.max_in_flight,
            .in_flight = .{ .permits = options.max_in_flight },
        };
    }

    pub fn transport(self: *StreamableHttpTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        const self: *StreamableHttpTransport = @ptrCast(@alignCast(context));
        try self.url_policy.validate(self.endpoint);
        if (self.authorization) |authorization| {
            try authorization.validate();
            if (!std.mem.eql(u8, authorization.resource, self.endpoint)) return error.InvalidResourceUri;
        }
        try validateMcpMessage(allocator, request.message);
        if (self.max_in_flight == 0) return error.InvalidMcpTransportConfiguration;
        try self.in_flight.wait(self.io);
        defer self.in_flight.post(self.io);

        var scopes: [][]u8 = &.{};
        defer auth.deinitScopes(allocator, scopes);
        var reason: auth.TokenReason = .initial;
        var refresh_attempts: usize = 0;
        while (true) {
            var token: ?auth.AccessToken = null;
            defer if (token) |value| value.deinit(allocator);
            if (self.authorization) |authorization| {
                token = try authorization.tokens.get(allocator, .{
                    .resource = authorization.resource,
                    .authorization_server = authorization.authorization_server,
                    .method = request.method,
                    .scopes = scopes,
                    .reason = reason,
                });
            }

            const response = try self.sendHttp(allocator, request, token);
            var response_body_owned = true;
            defer if (response_body_owned) allocator.free(response.body);
            if (self.authorization) |authorization| {
                if ((response.status == 401 or response.status == 403) and
                    refresh_attempts < authorization.max_refresh_attempts)
                {
                    const challenge_source = response.metadata.wwwAuthenticate() orelse {
                        response_body_owned = false;
                        return finishHttpResponse(allocator, request, response);
                    };
                    const challenge = auth.parseBearerChallengeAlloc(allocator, challenge_source) catch {
                        response_body_owned = false;
                        return finishHttpResponse(allocator, request, response);
                    };
                    defer challenge.deinit(allocator);
                    const retry_reason: ?auth.TokenReason = if (response.status == 401 and
                        (challenge.error_code == null or challenge.error_code.? == .invalid_token))
                        .invalid_token
                    else if (response.status == 403 and challenge.error_code == .insufficient_scope)
                        .insufficient_scope
                    else
                        null;
                    if (retry_reason) |next_reason| {
                        const next_scopes = try auth.unionScopesAlloc(
                            allocator,
                            if (token) |value| value.scopes else &.{},
                            challenge.scopes,
                        );
                        auth.deinitScopes(allocator, scopes);
                        scopes = next_scopes;
                        reason = next_reason;
                        refresh_attempts += 1;
                        allocator.free(response.body);
                        response_body_owned = false;
                        continue;
                    }
                }
            }
            response_body_owned = false;
            return finishHttpResponse(allocator, request, response);
        }
    }

    fn sendHttp(
        self: *StreamableHttpTransport,
        allocator: std.mem.Allocator,
        request: WireRequest,
        token: ?auth.AccessToken,
    ) !http.Response {
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(allocator);
        try headers.appendSlice(allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json, text/event-stream" },
            .{ .name = "mcp-protocol-version", .value = protocol_version },
            .{ .name = "mcp-method", .value = request.method },
        });
        if (request.routing_name) |name| {
            try headers.append(allocator, .{ .name = "mcp-name", .value = name });
        }
        try headers.appendSlice(allocator, request.headers);
        try headers.appendSlice(allocator, self.headers);
        var authorization_value: ?[]u8 = null;
        defer if (authorization_value) |value| allocator.free(value);
        if (token) |access_token| {
            if (findHeader(headers.items, "authorization") != null) return error.InvalidBearerToken;
            authorization_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token.value});
            try headers.append(allocator, .{
                .name = "authorization",
                .value = authorization_value.?,
                .sensitive = true,
            });
        }

        return self.inner.send(allocator, .{
            .method = .POST,
            .url = self.endpoint,
            .headers = headers.items,
            .body = request.message,
        });
    }
};

fn finishHttpResponse(
    allocator: std.mem.Allocator,
    request: WireRequest,
    response: http.Response,
) ![]const u8 {
    errdefer allocator.free(response.body);
    if (request.expects_response) {
        if (response.status != 200 and response.status != 400) return error.McpHttpRequestFailed;
    } else if (response.status != 200 and response.status != 202 and response.status != 204) {
        return error.McpHttpRequestFailed;
    }
    if (!request.expects_response or response.body.len == 0) return response.body;
    if (response.body[0] == '{' or response.body[0] == '[') {
        try validateMcpResponse(allocator, response.body);
        try validateHttpResponseStatus(allocator, response.status, response.body);
        return response.body;
    }

    const extracted = try extractSseResponse(
        allocator,
        response.body,
        request.message,
        request.method,
        request.events,
    );
    allocator.free(response.body);
    return extracted;
}

/// MCP stdio transport using newline-delimited JSON-RPC messages.
pub const StdioTransport = struct {
    io: std.Io,
    child: std.process.Child,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, argv: []const []const u8) !StdioTransport {
        if (argv.len == 0) return error.EmptyCommand;
        return .{
            .io = io,
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            }),
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        if (self.child.stdin) |stdin| stdin.close(self.io);
        self.child.stdin = null;
        self.child.kill(self.io);
        self.* = undefined;
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        try validateMcpMessage(allocator, request.message);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stdin = self.child.stdin orelse return error.McpProcessClosed;
        try stdin.writeStreamingAll(self.io, request.message);
        try stdin.writeStreamingAll(self.io, "\n");
        if (!request.expects_response) return allocator.alloc(u8, 0);

        const request_id = try JsonRpcId.parse(allocator, request.message);
        defer request_id.deinit(allocator);
        const is_subscription = std.mem.eql(u8, request.method, methods.listen);
        var subscription_acknowledged = !is_subscription;
        while (true) {
            const line = try readLine(allocator, self.io, self.child.stdout orelse return error.McpProcessClosed);
            errdefer allocator.free(line);
            const parsed = try json_limits.parse(
                std.json.Value,
                allocator,
                line,
                json_limits.defaults.mcp_message,
                .{},
                error.InvalidMcpMessage,
            );
            defer parsed.deinit();
            const object = requiredObject(parsed.value) catch {
                allocator.free(line);
                continue;
            };
            if (object.get("method") != null) {
                if (object.get("id") != null) {
                    try rejectLegacyServerRequest(self, allocator, object.get("id").?);
                } else if (request.events) |events| {
                    validateIncomingNotification(
                        parsed.value,
                        is_subscription,
                        error.InvalidMcpMessage,
                    ) catch {
                        allocator.free(line);
                        continue;
                    };
                    if (is_subscription) {
                        validateSubscriptionNotification(allocator, parsed.value, request.message) catch {
                            allocator.free(line);
                            continue;
                        };
                        const event_method = optionalString(object, "method") orelse unreachable;
                        if (std.mem.eql(u8, event_method, methods.subscriptions_acknowledged)) {
                            subscription_acknowledged = true;
                        } else if (!subscription_acknowledged) {
                            allocator.free(line);
                            continue;
                        }
                    }
                    try events.emit(line);
                }
                allocator.free(line);
                continue;
            }
            const response_id = object.get("id") orelse {
                allocator.free(line);
                continue;
            };
            if (request_id.matches(response_id)) return line;
            allocator.free(line);
        }
    }
};

/// Handles an MRTR input request and returns a JSON result object.
pub const InputHandler = struct {
    context: *anyopaque,
    handleFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: InputRequest,
    ) anyerror![]u8,

    pub fn handle(
        self: InputHandler,
        allocator: std.mem.Allocator,
        request: InputRequest,
    ) ![]u8 {
        return self.handleFn(self.context, allocator, request);
    }
};

/// Options for one client request.
pub const RequestOptions = struct {
    routing_name: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    events: ?EventSink = null,
    metadata: RequestMetadata = .{},
};

/// Runtime policy for waiting until a task reaches a terminal state.
pub const TaskWaitOptions = struct {
    /// Runtime used for polling delays. `control.io` takes precedence.
    io: ?std.Io = null,
    poll: tasks.PollPolicy = .{},
    control: model.RunControl = .{},
    status_sink: ?tasks.StatusSink = null,
    /// Signal cooperative cancellation when polling is cancelled, times out,
    /// or exhausts its bound. Cancellation acknowledgement is best effort.
    cancel_on_stop: bool = true,
};

/// Stateless MCP client with generic extension support and ZigAI toolset adaptation.
pub const Client = struct {
    transport: Transport,
    name: []const u8 = "zigai",
    version: []const u8 = "0.1.0",
    capabilities_json: []const u8 = "{}",
    input_handler: ?InputHandler = null,
    /// Optional durable state for tool-created and explicitly waited tasks.
    task_store: ?task_store.Store = null,
    max_round_trips: usize = 16,
    max_pages: usize = 256,
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn toolset(self: *Client) agent.Toolset {
        return .{ .context = self, .prepareFn = prepareTools };
    }

    /// Sends any core or extension request and returns its owned JSON result.
    pub fn request(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        return self.requestWithOptions(allocator, method, params_json, .{});
    }

    /// Sends a request with HTTP routing headers and a notification sink.
    pub fn requestWithOptions(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        options: RequestOptions,
    ) ![]u8 {
        var current_params: []const u8 = params_json;
        var owned_params: ?[]u8 = null;
        defer if (owned_params) |value| allocator.free(value);

        var round_trip: usize = 0;
        while (round_trip < self.max_round_trips) : (round_trip += 1) {
            const result = try self.requestOnce(allocator, method, current_params, options);
            if (!isInputRequired(allocator, result)) return result;
            const retry = answerInputRequests(allocator, current_params, result, self.input_handler) catch |failure| {
                allocator.free(result);
                return failure;
            };
            allocator.free(result);
            if (owned_params) |value| allocator.free(value);
            owned_params = retry;
            current_params = retry;
        }
        return error.TooManyMcpRoundTrips;
    }

    /// Sends a client notification.
    pub fn notify(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) !void {
        const message = try buildNotification(allocator, method, params_json);
        defer allocator.free(message);
        const response = try self.transport.send(allocator, .{
            .message = message,
            .method = method,
            .expects_response = false,
        });
        allocator.free(response);
    }

    /// Discovers server versions, capabilities, and instructions.
    pub fn discover(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return self.request(allocator, methods.discover, "{}");
    }

    pub fn listTools(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_tools, cursor);
    }

    pub fn callTool(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) ![]u8 {
        return self.callToolWithSchema(allocator, name, arguments_json, null);
    }

    pub fn listResources(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_resources, cursor);
    }

    pub fn listResourceTemplates(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_resource_templates, cursor);
    }

    pub fn readResource(self: *Client, allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
        const params = try std.json.Stringify.valueAlloc(allocator, .{ .uri = uri }, .{});
        defer allocator.free(params);
        return self.requestWithOptions(allocator, methods.read_resource, params, .{ .routing_name = uri });
    }

    pub fn listPrompts(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_prompts, cursor);
    }

    pub fn getPrompt(self: *Client, allocator: std.mem.Allocator, prompt: PromptRequest) ![]u8 {
        const params_json = try prompt.stringifyAlloc(allocator);
        defer allocator.free(params_json);
        return self.requestWithOptions(
            allocator,
            methods.get_prompt,
            params_json,
            .{ .routing_name = prompt.name },
        );
    }

    /// Raw JSON escape hatch for prompt fields added by future MCP revisions.
    pub fn getPromptJson(self: *Client, allocator: std.mem.Allocator, params_json: []const u8) ![]u8 {
        const name = try parameterString(allocator, params_json, "name");
        defer allocator.free(name);
        return self.requestWithOptions(allocator, methods.get_prompt, params_json, .{ .routing_name = name });
    }

    pub fn complete(self: *Client, allocator: std.mem.Allocator, completion: CompletionRequest) ![]u8 {
        const params_json = try completion.stringifyAlloc(allocator);
        defer allocator.free(params_json);
        return self.completeJson(allocator, params_json);
    }

    /// Raw JSON escape hatch for completion fields added by future MCP
    /// revisions.
    pub fn completeJson(self: *Client, allocator: std.mem.Allocator, params_json: []const u8) ![]u8 {
        return self.request(allocator, methods.complete, params_json);
    }

    pub fn listen(
        self: *Client,
        allocator: std.mem.Allocator,
        filter: primitives.SubscriptionFilter,
        events: EventSink,
    ) ![]u8 {
        const filter_json = try filter.stringifyAlloc(allocator);
        defer allocator.free(filter_json);
        return self.listenJson(allocator, filter_json, events);
    }

    /// Raw JSON escape hatch for subscription filters added by future MCP
    /// revisions or extensions.
    pub fn listenJson(
        self: *Client,
        allocator: std.mem.Allocator,
        filter_json: []const u8,
        events: EventSink,
    ) ![]u8 {
        const params = try std.fmt.allocPrint(allocator, "{{\"notifications\":{s}}}", .{filter_json});
        defer allocator.free(params);
        return self.requestWithOptions(allocator, methods.listen, params, .{ .events = events });
    }

    pub fn cancel(self: *Client, allocator: std.mem.Allocator, request_id: RequestId, reason: ?[]const u8) !void {
        const message = try (Notification{ .cancelled = .{
            .request_id = request_id,
            .reason = reason,
        } }).stringifyAlloc(allocator, null);
        defer allocator.free(message);
        const response = try self.transport.send(allocator, .{
            .message = message,
            .method = methods.cancelled,
            .expects_response = false,
        });
        allocator.free(response);
    }

    /// Retrieves and parses one owned SEP-2663 task state.
    pub fn getTask(self: *Client, allocator: std.mem.Allocator, task_id: []const u8) !tasks.Owned {
        const params = try (tasks.Request{ .task_id = task_id }).stringifyAlloc(allocator);
        defer allocator.free(params);
        const result = try self.requestWithOptions(
            allocator,
            tasks.methods.get,
            params,
            .{ .routing_name = task_id },
        );
        defer allocator.free(result);
        var owned = try tasks.parseResult(allocator, result);
        errdefer owned.deinit();
        if (owned.value.detailed.status().terminal()) {
            if (self.task_store) |store| try store.remove(allocator, task_id);
        }
        return owned;
    }

    /// Supplies one or more responses to an input-required task.
    pub fn updateTask(self: *Client, allocator: std.mem.Allocator, update: tasks.UpdateRequest) !void {
        const params = try update.stringifyAlloc(allocator);
        defer allocator.free(params);
        const result = try self.requestWithOptions(
            allocator,
            tasks.methods.update,
            params,
            .{ .routing_name = update.task_id },
        );
        allocator.free(result);
    }

    /// Signals cooperative task cancellation and consumes the empty ack.
    pub fn cancelTask(self: *Client, allocator: std.mem.Allocator, task_id: []const u8) !void {
        const params = try (tasks.Request{ .task_id = task_id }).stringifyAlloc(allocator);
        defer allocator.free(params);
        const result = try self.requestWithOptions(
            allocator,
            tasks.methods.cancel,
            params,
            .{ .routing_name = task_id },
        );
        allocator.free(result);
        if (self.task_store) |store| try store.remove(allocator, task_id);
    }

    /// Polls a task to a terminal state, answering validated outstanding input
    /// requests through the client's existing `input_handler` exactly once per
    /// task-local request key.
    pub fn waitTask(
        self: *Client,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        options: TaskWaitOptions,
    ) !tasks.Owned {
        if (task_id.len == 0) return error.InvalidTaskRequest;
        if (options.poll.max_polls == 0) return error.TooManyMcpTaskPolls;
        var resume_state = try TaskResumeState.init(self, allocator, task_id);
        defer resume_state.deinit(allocator);

        var poll_index: usize = 0;
        while (poll_index < options.poll.max_polls) : (poll_index += 1) {
            options.control.check() catch |failure|
                return stopTaskWait(self, allocator, task_id, options.cancel_on_stop, failure);
            var owned = try self.getTask(allocator, task_id);
            var owned_live = true;
            defer if (owned_live) owned.deinit();
            const detailed = switch (owned.value) {
                .detailed => |value| value,
                else => unreachable,
            };
            if (options.status_sink) |sink| try sink.emit(detailed);
            if (detailed.status().terminal()) {
                owned_live = false;
                return owned;
            }

            if (resume_state.pending_input_responses_json != null) {
                try resume_state.replayPending(self, allocator, task_id);
            }

            switch (detailed.state) {
                .input_required => |requests| {
                    if (try answerTaskInputRequests(
                        allocator,
                        requests,
                        &resume_state.answered,
                        self.input_handler,
                    )) |batch| {
                        var responses = batch;
                        defer responses.deinit(allocator);
                        try resume_state.recordPending(self, allocator, responses.json);
                        try self.updateTask(allocator, .{
                            .task_id = task_id,
                            .input_responses_json = responses.json,
                        });
                        try resume_state.confirmPending(self, allocator);
                    }
                },
                else => {},
            }

            const delay_ms = options.poll.interval(detailed.metadata.poll_interval_ms);
            owned.deinit();
            owned_live = false;
            if (poll_index + 1 >= options.poll.max_polls) break;
            waitForTaskPoll(options, delay_ms) catch |failure|
                return stopTaskWait(self, allocator, task_id, options.cancel_on_stop, failure);
        }
        return stopTaskWait(
            self,
            allocator,
            task_id,
            options.cancel_on_stop,
            error.TooManyMcpTaskPolls,
        );
    }

    /// Resumes every task in the configured durable snapshot, returning all
    /// terminal results in snapshot order. Tasks that remain after an error
    /// stay in the store for a later retry.
    pub fn resumeTasks(
        self: *Client,
        allocator: std.mem.Allocator,
        options: TaskWaitOptions,
    ) !tasks.OwnedList {
        const store = self.task_store orelse return error.MissingMcpTaskStore;
        var snapshot = try store.load(allocator);
        defer snapshot.deinit();
        var resumed: std.ArrayList(tasks.Owned) = .empty;
        errdefer {
            for (resumed.items) |*item| item.deinit();
            resumed.deinit(allocator);
        }
        for (snapshot.records) |record| {
            try resumed.append(allocator, try self.waitTask(allocator, record.task_id, options));
        }
        return .{
            .allocator = allocator,
            .items = try resumed.toOwnedSlice(allocator),
        };
    }

    fn requestOnce(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        options: RequestOptions,
    ) ![]u8 {
        var capability_arena = std.heap.ArenaAllocator.init(allocator);
        defer capability_arena.deinit();
        const task_capability_required = if (std.mem.eql(u8, method, methods.listen)) blk: {
            const params_value = try json_limits.parseLeaky(
                std.json.Value,
                capability_arena.allocator(),
                params_json,
                json_limits.defaults.mcp_message,
                .{},
                error.InvalidMcpMessage,
            );
            break :blk requestsTaskNotifications(method, try capabilityObject(params_value, error.InvalidMcpMessage));
        } else isTaskMethod(method);
        if (task_capability_required) {
            const advertised = try json_limits.parseLeaky(
                std.json.Value,
                capability_arena.allocator(),
                self.capabilities_json,
                json_limits.defaults.mcp_message,
                .{},
                error.InvalidMcpMessage,
            );
            const capability_object = try capabilityObject(advertised, error.InvalidMcpMessage);
            if (!hasExtensionCapability(capability_object, tasks.extension_identifier)) {
                return error.MissingMcpClientCapability;
            }
        }
        const id = self.next_id.fetchAdd(1, .monotonic);
        const message = try buildRequestWithMetadata(
            allocator,
            id,
            method,
            params_json,
            self.name,
            self.version,
            self.capabilities_json,
            options.metadata,
        );
        defer allocator.free(message);
        const body = try self.transport.send(allocator, .{
            .message = message,
            .method = method,
            .routing_name = options.routing_name,
            .headers = options.headers,
            .events = options.events,
        });
        defer allocator.free(body);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try responseResult(try parseResponse(arena.allocator(), body), id);
        try validateMethodResult(method, result);
        const client_capabilities = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            self.capabilities_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        try validateInputRequiredCapabilities(result, client_capabilities);
        const result_json = try std.json.Stringify.valueAlloc(allocator, result, .{});
        errdefer allocator.free(result_json);
        if (std.mem.eql(u8, method, methods.call_tool)) {
            if (self.task_store) |store| {
                if (optionalString(try requiredObject(result), "resultType")) |result_type| {
                    if (std.mem.eql(u8, result_type, "task")) {
                        var created = try tasks.parseCreated(allocator, result_json);
                        defer created.deinit();
                        store.save(allocator, .{
                            .task_id = created.value.created.metadata.task_id,
                        }) catch |failure| {
                            cancelTaskBestEffort(
                                self,
                                allocator,
                                created.value.created.metadata.task_id,
                            );
                            return failure;
                        };
                    }
                }
            }
        }
        return result_json;
    }

    fn callToolWithSchema(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
        schema_json: ?[]const u8,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arguments = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            arguments_json,
            json_limits.defaults.tool_payload,
            .{},
            error.InvalidMcpToolArguments,
        );
        if (arguments != .object) return error.InvalidMcpToolArguments;
        const params = try std.json.Stringify.valueAlloc(allocator, .{ .name = name, .arguments = arguments }, .{});
        defer allocator.free(params);
        const headers = if (schema_json) |schema|
            try toolArgumentHeaders(arena.allocator(), schema, arguments)
        else
            &.{};
        return self.requestWithOptions(allocator, methods.call_tool, params, .{
            .routing_name = name,
            .headers = headers,
        });
    }

    fn prepareTools(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: agent.ToolsetContext,
        _: []const model.Tool,
    ) ![]const agent.ToolsetEntry {
        const self: *Client = @ptrCast(@alignCast(context orelse return error.MissingMcpClient));
        var entries: std.ArrayList(agent.ToolsetEntry) = .empty;
        var cursors: std.ArrayList([]u8) = .empty;
        defer {
            for (cursors.items) |owned| allocator.free(owned);
            cursors.deinit(allocator);
        }
        var cursor: ?[]const u8 = null;
        var page_count: usize = 0;
        while (true) {
            if (page_count >= self.max_pages) return error.TooManyMcpPages;
            page_count += 1;
            const result_json = try self.listToolsOwnedParams(allocator, cursor);
            defer allocator.free(result_json);
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const object = try requiredObject(try parseResponse(arena.allocator(), result_json));
            const tools = switch (object.get("tools") orelse return error.InvalidMcpResponse) {
                .array => |value| value,
                else => return error.InvalidMcpResponse,
            };
            for (tools.items) |tool_value| {
                const tool = try requiredObject(tool_value);
                const name = try requiredString(tool, "name");
                const description = optionalString(tool, "description") orelse "";
                const schema_value = tool.get("inputSchema") orelse return error.InvalidMcpResponse;
                if (!validToolHeaderSchema(schema_value)) continue;
                const schema = try std.json.Stringify.valueAlloc(allocator, schema_value, .{});
                const tool_context = try allocator.create(ToolContext);
                tool_context.* = .{
                    .client = self,
                    .name = try allocator.dupe(u8, name),
                    .schema_json = schema,
                };
                try entries.append(allocator, .{ .tool = .{
                    .definition = .{
                        .name = try allocator.dupe(u8, name),
                        .description = try allocator.dupe(u8, description),
                        .parameters_json_schema = try allocator.dupe(u8, schema),
                    },
                    .context = tool_context,
                    .executeFn = executeTool,
                } });
            }
            const next = optionalString(object, "nextCursor") orelse break;
            for (cursors.items) |seen| {
                if (std.mem.eql(u8, seen, next)) return error.McpPaginationCursorCycle;
            }
            const owned = try allocator.dupe(u8, next);
            cursors.append(allocator, owned) catch |failure| {
                allocator.free(owned);
                return failure;
            };
            cursor = owned;
        }
        return entries.toOwnedSlice(allocator);
    }

    fn listToolsOwnedParams(self: *Client, allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
        return self.paginatedRequest(allocator, methods.list_tools, cursor);
    }

    fn paginatedRequest(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        cursor: ?[]const u8,
    ) ![]u8 {
        const params = try paginatedParams(allocator, cursor);
        defer allocator.free(params);
        return self.request(allocator, method, params);
    }
};

fn cancelTaskBestEffort(client: *Client, allocator: std.mem.Allocator, task_id: []const u8) void {
    client.cancelTask(allocator, task_id) catch {};
}

const ToolContext = struct {
    client: *Client,
    name: []const u8,
    schema_json: []const u8,
};

fn executeTool(context: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const tool: *ToolContext = @ptrCast(@alignCast(context));
    const result_json = try tool.client.callToolWithSchema(allocator, tool.name, arguments_json, tool.schema_json);
    defer allocator.free(result_json);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return renderToolResult(allocator, try requiredObject(try parseResponse(arena.allocator(), result_json)));
}

/// HTTP metadata supplied by an MCP server host for header validation.
pub const HttpMetadata = struct {
    headers: []const http.Header,
    /// Whether the host received this request over authenticated TLS.
    is_tls: bool = true,
};

/// Application handler for all core and extension MCP methods.
pub const ServerHandler = struct {
    context: *anyopaque,
    handleFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) anyerror![]u8,

    pub fn handle(
        self: ServerHandler,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        return self.handleFn(self.context, allocator, method, params_json);
    }
};

/// Optional server callback used to validate `Mcp-Param-*` tool headers.
pub const ToolSchemaProvider = struct {
    context: *anyopaque,
    schemaFn: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,

    pub fn schema(self: ToolSchemaProvider, name: []const u8) ?[]const u8 {
        return self.schemaFn(self.context, name);
    }
};

/// Result of dispatching one MCP request in an HTTP or stdio host.
pub const ServerResponse = struct {
    status: u16,
    body: ?[]u8,
    /// HTTP headers the host must copy to its response before deinitializing.
    headers: []const http.Header = &.{},
    owns_headers: bool = false,

    pub fn deinit(self: ServerResponse, allocator: std.mem.Allocator) void {
        if (self.body) |body| allocator.free(body);
        if (self.owns_headers) {
            for (self.headers) |header| allocator.free(header.value);
            allocator.free(self.headers);
        }
    }
};

/// Transport-neutral MCP server dispatcher with discovery and validation.
pub const Server = struct {
    handler: ServerHandler,
    name: []const u8 = "zigai-mcp-server",
    version: []const u8 = "0.1.0",
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    capabilities_json: []const u8 = "{}",
    discovery_ttl_ms: u64 = 60_000,
    discovery_cache_scope: []const u8 = "public",
    tool_schemas: ?ToolSchemaProvider = null,
    /// Browser-origin, Host, and TLS checks for Streamable HTTP deployments.
    deployment: ?auth.DeploymentPolicy = null,
    /// Optional OAuth resource-server policy. It is not applied to stdio.
    authorization: ?auth.ServerPolicy = null,

    /// Validates and dispatches one JSON-RPC message.
    pub fn handle(
        self: *Server,
        allocator: std.mem.Allocator,
        message_json: []const u8,
        metadata: ?HttpMetadata,
    ) !ServerResponse {
        if (self.deployment) |deployment| {
            try deployment.validate();
            const http_metadata = metadata orelse return .{ .status = 403, .body = null };
            const origin = uniqueHeader(http_metadata.headers, "origin") catch
                return .{ .status = 403, .body = null };
            const host = uniqueHeader(http_metadata.headers, "host") catch
                return .{ .status = 403, .body = null };
            deployment.validateRequest(http_metadata.is_tls, origin, host) catch
                return .{ .status = 403, .body = null };
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            message_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.errorResponse(allocator, .null, error_codes.parse_error, "Invalid JSON", 400),
        };
        const object = requiredObject(root) catch
            return self.errorResponse(allocator, .null, error_codes.invalid_request, "Invalid JSON-RPC request", 400);
        const id = object.get("id") orelse .null;
        if (object.get("id")) |request_id| {
            if (request_id != .integer and request_id != .string) {
                return self.errorResponse(allocator, .null, error_codes.invalid_request, "Invalid request ID", 400);
            }
        }
        if (!std.mem.eql(u8, optionalString(object, "jsonrpc") orelse "", "2.0")) {
            return self.errorResponse(allocator, id, error_codes.invalid_request, "Invalid JSON-RPC version", 400);
        }
        const method = optionalString(object, "method") orelse
            return self.errorResponse(allocator, id, error_codes.invalid_request, "Missing method", 400);
        if (std.mem.eql(u8, method, "initialize")) {
            return self.errorResponse(
                allocator,
                id,
                error_codes.method_not_found,
                "This server supports MCP 2026-07-28 via per-request metadata",
                200,
            );
        }
        const is_notification = object.get("id") == null;
        const params_value = object.get("params") orelse std.json.Value{ .object = .{} };
        const params = requiredObject(params_value) catch return if (is_notification)
            .{ .status = 202, .body = null }
        else
            self.errorResponse(allocator, id, error_codes.invalid_params, "Params must be an object", 400);

        var request_client_capabilities: ?std.json.Value = null;
        if (!is_notification) {
            const meta = params.get("_meta") orelse
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Missing request metadata", 400);
            const meta_object = requiredObject(meta) catch
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Invalid request metadata", 400);
            validateRequestMeta(meta_object, error.InvalidMcpMessage) catch
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Invalid request metadata", 400);
            const requested = optionalString(meta_object, "io.modelcontextprotocol/protocolVersion") orelse "";
            if (!std.mem.eql(u8, requested, protocol_version)) {
                return self.unsupportedVersionResponse(allocator, id, requested);
            }
            const client_capabilities = meta_object.get("io.modelcontextprotocol/clientCapabilities") orelse {
                return self.errorResponse(
                    allocator,
                    id,
                    error_codes.invalid_params,
                    "Missing client capabilities",
                    400,
                );
            };
            validateClientCapabilities(client_capabilities, error.InvalidMcpMessage) catch
                return self.errorResponse(
                    allocator,
                    id,
                    error_codes.invalid_params,
                    "Invalid client capabilities",
                    400,
                );
            request_client_capabilities = client_capabilities;
            validateRequestMethodParams(method, params, error.InvalidMcpMessage) catch
                return self.errorResponse(allocator, id, error_codes.invalid_params, "Invalid method params", 400);
        } else {
            validateNotificationMethodParams(method, params, error.InvalidMcpMessage) catch
                return .{ .status = 202, .body = null };
        }
        const params_json = try std.json.Stringify.valueAlloc(allocator, params_value, .{});
        defer allocator.free(params_json);

        if (self.authorization) |authorization| {
            try authorization.validate();
            const http_metadata = metadata orelse
                return self.authorizationResponse(allocator, 401, authorization, authorization.scopes);
            const authorization_header = uniqueHeader(http_metadata.headers, "authorization") catch
                return self.authorizationResponse(allocator, 401, authorization, authorization.scopes);
            const token = if (authorization_header) |value|
                auth.parseBearerAuthorization(value) catch
                    return self.authorizationResponse(allocator, 401, authorization, authorization.scopes)
            else
                return self.authorizationResponse(allocator, 401, authorization, authorization.scopes);
            const decision = try authorization.authorizer.authorize(.{
                .token = token,
                .resource = authorization.resource,
                .method = method,
                .params_json = params_json,
            });
            switch (decision) {
                .authorized => {},
                .unauthorized => return self.authorizationResponse(
                    allocator,
                    401,
                    authorization,
                    authorization.scopes,
                ),
                .insufficient_scope => |denial| return self.authorizationResponse(
                    allocator,
                    403,
                    authorization,
                    denial.required_scopes,
                ),
            }
        }
        if (metadata) |http_metadata| {
            if (!validateStandardHeaders(http_metadata.headers, method, params)) {
                if (is_notification) return .{ .status = 400, .body = null };
                return self.errorResponse(allocator, id, error_codes.header_mismatch, "MCP headers do not match", 400);
            }
            if (self.tool_schemas) |schemas| {
                if (std.mem.eql(u8, method, methods.call_tool)) {
                    const name = optionalString(params, "name") orelse "";
                    if (schemas.schema(name)) |schema| {
                        if (!try validateToolHeaders(arena.allocator(), http_metadata.headers, schema, params)) {
                            return self.errorResponse(
                                allocator,
                                id,
                                error_codes.header_mismatch,
                                "Tool parameter headers do not match",
                                400,
                            );
                        }
                    }
                }
            }
        }

        if (!is_notification) {
            const server_capabilities = try json_limits.parseLeaky(
                std.json.Value,
                arena.allocator(),
                self.capabilities_json,
                json_limits.defaults.mcp_message,
                .{},
                error.InvalidMcpResponse,
            );
            try validateServerCapabilities(server_capabilities, error.InvalidMcpResponse);
            if ((isTaskMethod(method) or requestsTaskNotifications(method, params)) and
                request_client_capabilities != null)
            {
                const requirements = ClientCapabilityRequirements{ .tasks = true };
                if (!clientCapabilitiesSatisfy(request_client_capabilities.?, requirements)) {
                    return self.missingCapabilityResponse(
                        allocator,
                        id,
                        request_client_capabilities.?,
                        requirements,
                    );
                }
            }
            if (!serverSupportsMethod(server_capabilities, method)) {
                return self.errorResponse(allocator, id, error_codes.method_not_found, "Method not advertised", 200);
            }
        }

        if (is_notification) {
            const ignored = self.handler.handle(allocator, method, params_json) catch return .{ .status = 202, .body = null };
            allocator.free(ignored);
            return .{ .status = 202, .body = null };
        }
        const result_json = if (std.mem.eql(u8, method, methods.discover))
            try self.discoveryResult(allocator)
        else
            self.handler.handle(allocator, method, params_json) catch
                return self.errorResponse(allocator, id, error_codes.internal_error, "MCP handler failed", 500);
        defer allocator.free(result_json);
        if (request_client_capabilities) |client_capabilities| {
            const result = try parseResponse(arena.allocator(), result_json);
            const requirements = try inputCapabilityRequirements(result);
            if (!clientCapabilitiesSatisfy(client_capabilities, requirements)) {
                return self.missingCapabilityResponse(allocator, id, client_capabilities, requirements);
            }
        }
        const body = try self.resultResponse(allocator, id, method, result_json);
        return .{ .status = 200, .body = body };
    }

    /// Serves newline-delimited MCP requests until the input closes.
    pub fn serveStdio(
        self: *Server,
        allocator: std.mem.Allocator,
        io: std.Io,
        input: std.Io.File,
        output: std.Io.File,
    ) !void {
        while (true) {
            const line = readLine(allocator, io, input) catch |failure| switch (failure) {
                error.EndOfStream => return,
                else => return failure,
            };
            defer allocator.free(line);
            const response = try self.handle(allocator, line, null);
            defer response.deinit(allocator);
            if (response.body) |body| {
                try output.writeStreamingAll(io, body);
                try output.writeStreamingAll(io, "\n");
            }
        }
    }

    fn discoveryResult(self: *Server, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const capabilities = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            self.capabilities_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        try validateServerCapabilities(capabilities, error.InvalidMcpResponse);
        return std.json.Stringify.valueAlloc(allocator, .{
            .resultType = "complete",
            .ttlMs = self.discovery_ttl_ms,
            .cacheScope = self.discovery_cache_scope,
            .supportedVersions = &.{protocol_version},
            .capabilities = capabilities,
            .instructions = self.instructions,
        }, .{ .emit_null_optional_fields = false });
    }

    fn resultResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        method: []const u8,
        result_json: []const u8,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var result = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            result_json,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpResponse,
        );
        var object = try requiredObject(result);
        const memory = arena.allocator();
        if (object.get("resultType") == null) try object.put(memory, "resultType", .{ .string = "complete" });
        try validateMethodResult(method, .{ .object = object });
        var server_info: std.json.ObjectMap = .{};
        try server_info.put(memory, "name", .{ .string = self.name });
        try server_info.put(memory, "version", .{ .string = self.version });
        if (self.description) |description| try server_info.put(memory, "description", .{ .string = description });
        var meta = if (object.get("_meta")) |existing|
            try requiredObject(existing)
        else
            std.json.ObjectMap{};
        try meta.put(memory, "io.modelcontextprotocol/serverInfo", .{ .object = server_info });
        try object.put(memory, "_meta", .{ .object = meta });
        result = .{ .object = object };
        return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
    }

    fn unsupportedVersionResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        requested: []const u8,
    ) !ServerResponse {
        _ = self;
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{
                .code = error_codes.unsupported_protocol_version,
                .message = "Unsupported MCP protocol version",
                .data = .{ .supported = &.{protocol_version}, .requested = requested },
            },
        }, .{});
        return .{ .status = 400, .body = body };
    }

    fn missingCapabilityResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        client_capabilities: std.json.Value,
        requirements: ClientCapabilityRequirements,
    ) !ServerResponse {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const missing = try missingClientCapabilities(arena.allocator(), client_capabilities, requirements);
        const code: i64 = if (requirements.tasks)
            tasks.error_codes.missing_required_client_capability
        else
            error_codes.missing_required_client_capability;
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{
                .code = code,
                .message = "Required client capability was not advertised",
                .data = .{ .requiredCapabilities = missing },
            },
        }, .{});
        return .{ .status = 400, .body = body };
    }

    fn errorResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        id: std.json.Value,
        code: i32,
        message: []const u8,
        status: u16,
    ) !ServerResponse {
        _ = self;
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = .{ .code = code, .message = message },
        }, .{});
        return .{ .status = status, .body = body };
    }

    fn authorizationResponse(
        self: *Server,
        allocator: std.mem.Allocator,
        status: u16,
        policy: auth.ServerPolicy,
        scopes: []const []const u8,
    ) !ServerResponse {
        _ = self;
        const scope = try std.mem.join(allocator, " ", scopes);
        defer allocator.free(scope);
        const challenge = if (status == 403)
            try std.fmt.allocPrint(
                allocator,
                "Bearer error=\"insufficient_scope\", scope=\"{s}\", resource_metadata=\"{s}\"",
                .{ scope, policy.resource_metadata_url },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "Bearer scope=\"{s}\", resource_metadata=\"{s}\"",
                .{ scope, policy.resource_metadata_url },
            );
        errdefer allocator.free(challenge);
        const headers = try allocator.alloc(http.Header, 1);
        errdefer allocator.free(headers);
        headers[0] = .{ .name = "www-authenticate", .value = challenge };
        return .{ .status = status, .body = null, .headers = headers, .owns_headers = true };
    }
};

fn buildRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: []const u8,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
) ![]u8 {
    return buildRequestWithMetadata(
        allocator,
        id,
        method,
        params_json,
        client_name,
        client_version,
        capabilities_json,
        .{},
    );
}

fn buildRequestWithMetadata(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: []const u8,
    client_name: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
    request_metadata: RequestMetadata,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var params_value = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    var params = try requiredObject(params_value);
    try validateRequestMethodParams(method, params, error.InvalidMcpMessage);
    const capabilities = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        capabilities_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    try validateClientCapabilities(capabilities, error.InvalidMcpMessage);
    const memory = arena.allocator();
    var client_info: std.json.ObjectMap = .{};
    try client_info.put(memory, "name", .{ .string = client_name });
    try client_info.put(memory, "version", .{ .string = client_version });
    var meta = if (params.get("_meta")) |existing|
        try requiredObject(existing)
    else
        std.json.ObjectMap{};
    try meta.put(memory, "io.modelcontextprotocol/protocolVersion", .{ .string = protocol_version });
    try meta.put(memory, "io.modelcontextprotocol/clientInfo", .{ .object = client_info });
    try meta.put(memory, "io.modelcontextprotocol/clientCapabilities", capabilities);
    if (request_metadata.progress_token) |token| try meta.put(memory, "progressToken", token.jsonValue());
    if (request_metadata.log_level) |level| {
        try meta.put(memory, "io.modelcontextprotocol/logLevel", .{ .string = @tagName(level) });
    }
    try validateRequestMeta(meta, error.InvalidMcpMessage);
    try params.put(memory, "_meta", .{ .object = meta });
    params_value = .{ .object = params };
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params_value,
    }, .{});
}

fn buildNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const params = try json_limits.parseLeaky(
        std.json.Value,
        arena.allocator(),
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    const params_object = switch (params) {
        .object => |object| object,
        else => return error.InvalidMcpMessage,
    };
    try validateNotificationMethodParams(method, params_object, error.InvalidMcpMessage);
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = method,
        .params = params,
    }, .{});
}

fn paginatedParams(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
    return if (cursor) |value|
        std.json.Stringify.valueAlloc(allocator, .{ .cursor = value }, .{})
    else
        allocator.dupe(u8, "{}");
}

fn parameterString(allocator: std.mem.Allocator, params_json: []const u8, key: []const u8) ![]const u8 {
    const parsed = try json_limits.parse(
        std.json.Value,
        allocator,
        params_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    defer parsed.deinit();
    return allocator.dupe(u8, try requiredString(try requiredObject(parsed.value), key));
}

fn isInputRequired(allocator: std.mem.Allocator, result_json: []const u8) bool {
    const parsed = json_limits.parse(
        std.json.Value,
        allocator,
        result_json,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpResponse,
    ) catch return false;
    defer parsed.deinit();
    const object = requiredObject(parsed.value) catch return false;
    return std.mem.eql(u8, optionalString(object, "resultType") orelse "complete", "input_required");
}

fn answerInputRequests(
    allocator: std.mem.Allocator,
    params_json: []const u8,
    result_json: []const u8,
    maybe_handler: ?InputHandler,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try requiredObject(try parseResponse(arena.allocator(), result_json));
    const memory = arena.allocator();
    var responses: std.json.ObjectMap = .{};
    if (result.get("inputRequests")) |requests_value| {
        const requests = try requiredObject(requests_value);
        const handler = maybe_handler orelse return error.InputRequired;
        var iterator = requests.iterator();
        while (iterator.next()) |entry| {
            const input_request = try requiredObject(entry.value_ptr.*);
            try validateInputRequest(input_request);
            const input_method = try requiredString(input_request, "method");
            const request_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
            defer allocator.free(request_json);
            const response_json = try handler.handle(allocator, .{
                .key = entry.key_ptr.*,
                .kind = try InputKind.fromMethod(input_method),
                .request_json = request_json,
            });
            defer allocator.free(response_json);
            const response = try parseResponse(arena.allocator(), response_json);
            try validateInputResponse(input_method, response);
            try responses.put(memory, entry.key_ptr.*, response);
        }
    }
    var params_value = try parseResponse(arena.allocator(), params_json);
    var params = try requiredObject(params_value);
    if (responses.count() > 0) try params.put(memory, "inputResponses", .{ .object = responses });
    if (optionalString(result, "requestState")) |state| {
        try params.put(memory, "requestState", .{ .string = state });
    }
    params_value = .{ .object = params };
    return std.json.Stringify.valueAlloc(allocator, params_value, .{});
}

const TaskInputBatch = struct {
    json: []u8,

    fn deinit(self: *TaskInputBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        self.* = undefined;
    }
};

const TaskResumeState = struct {
    task_id: []const u8,
    answered: std.StringHashMapUnmanaged(void) = .{},
    pending_input_responses_json: ?[]u8 = null,

    fn init(client: *Client, allocator: std.mem.Allocator, task_id: []const u8) !TaskResumeState {
        var self = TaskResumeState{ .task_id = task_id };
        errdefer self.deinit(allocator);
        const store = client.task_store orelse return self;
        var snapshot = try store.load(allocator);
        defer snapshot.deinit();
        for (snapshot.records) |record| {
            if (!std.mem.eql(u8, record.task_id, task_id)) continue;
            for (record.answered_input_keys) |key| {
                const owned_key = try allocator.dupe(u8, key);
                self.answered.put(allocator, owned_key, {}) catch |failure| {
                    allocator.free(owned_key);
                    return failure;
                };
            }
            if (record.pending_input_responses_json) |pending| {
                self.pending_input_responses_json = try allocator.dupe(u8, pending);
            }
            return self;
        }
        try store.save(allocator, .{ .task_id = task_id });
        return self;
    }

    fn deinit(self: *TaskResumeState, allocator: std.mem.Allocator) void {
        deinitAnsweredTaskInputs(allocator, &self.answered);
        if (self.pending_input_responses_json) |pending| allocator.free(pending);
        self.* = undefined;
    }

    fn recordPending(
        self: *TaskResumeState,
        client: *Client,
        allocator: std.mem.Allocator,
        responses_json: []const u8,
    ) !void {
        std.debug.assert(self.pending_input_responses_json == null);
        const pending = try allocator.dupe(u8, responses_json);
        errdefer allocator.free(pending);
        try self.persist(client, allocator, pending);
        self.pending_input_responses_json = pending;
    }

    fn replayPending(
        self: *TaskResumeState,
        client: *Client,
        allocator: std.mem.Allocator,
        task_id: []const u8,
    ) !void {
        const pending = self.pending_input_responses_json orelse return;
        try client.updateTask(allocator, .{
            .task_id = task_id,
            .input_responses_json = pending,
        });
        try self.confirmPending(client, allocator);
    }

    fn confirmPending(
        self: *TaskResumeState,
        client: *Client,
        allocator: std.mem.Allocator,
    ) !void {
        const pending = self.pending_input_responses_json orelse return;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const value = try json_limits.parseLeaky(
            std.json.Value,
            arena.allocator(),
            pending,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidTaskStore,
        );
        var iterator = (try requiredObject(value)).iterator();
        while (iterator.next()) |entry| {
            if (self.answered.contains(entry.key_ptr.*)) continue;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            self.answered.put(allocator, key, {}) catch |failure| {
                allocator.free(key);
                return failure;
            };
        }
        try self.persist(client, allocator, null);
        allocator.free(pending);
        self.pending_input_responses_json = null;
    }

    fn persist(
        self: *TaskResumeState,
        client: *Client,
        allocator: std.mem.Allocator,
        pending: ?[]const u8,
    ) !void {
        const store = client.task_store orelse return;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(allocator);
        var iterator = self.answered.keyIterator();
        while (iterator.next()) |key| try keys.append(allocator, key.*);
        try store.save(allocator, .{
            .task_id = self.task_id,
            .answered_input_keys = keys.items,
            .pending_input_responses_json = pending,
        });
    }
};

fn answerTaskInputRequests(
    allocator: std.mem.Allocator,
    requests: std.json.ObjectMap,
    answered: *const std.StringHashMapUnmanaged(void),
    maybe_handler: ?InputHandler,
) !?TaskInputBatch {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var responses: std.json.ObjectMap = .{};
    var iterator = requests.iterator();
    while (iterator.next()) |entry| {
        if (answered.contains(entry.key_ptr.*)) continue;
        const handler = maybe_handler orelse return error.InputRequired;
        const input_request = try requiredObject(entry.value_ptr.*);
        try validateInputRequest(input_request);
        const input_method = try requiredString(input_request, "method");
        const request_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        const response_json = handler.handle(allocator, .{
            .key = entry.key_ptr.*,
            .kind = try InputKind.fromMethod(input_method),
            .request_json = request_json,
        }) catch |failure| {
            allocator.free(request_json);
            return failure;
        };
        allocator.free(request_json);
        const response = parseResponse(memory, response_json) catch |failure| {
            allocator.free(response_json);
            return failure;
        };
        allocator.free(response_json);
        try validateInputResponse(input_method, response);
        try responses.put(memory, entry.key_ptr.*, response);
    }
    if (responses.count() == 0) return null;
    const json = try std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = responses },
        .{},
    );
    errdefer allocator.free(json);
    return .{ .json = json };
}

fn deinitAnsweredTaskInputs(
    allocator: std.mem.Allocator,
    answered: *std.StringHashMapUnmanaged(void),
) void {
    var iterator = answered.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    answered.deinit(allocator);
}

fn waitForTaskPoll(options: TaskWaitOptions, delay_ms: u64) !void {
    if (delay_ms == 0) return;
    const io = options.control.io orelse options.io orelse return error.TaskPollingRequiresIo;
    return options.control.invoke(void, sleepForTaskPoll, .{ io, delay_ms });
}

fn sleepForTaskPoll(io: std.Io, delay_ms: u64) !void {
    const maximum: u64 = @intCast(std.math.maxInt(i64));
    return (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(@intCast(@min(delay_ms, maximum))),
        .clock = .awake,
    } }).sleep(io);
}

fn stopTaskWait(
    client: *Client,
    allocator: std.mem.Allocator,
    task_id: []const u8,
    cancel_on_stop: bool,
    failure: anyerror,
) anyerror {
    if (cancel_on_stop) client.cancelTask(allocator, task_id) catch {};
    return failure;
}

fn extractSseResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    request: []const u8,
    request_method: []const u8,
    events: ?EventSink,
) ![]u8 {
    const request_id = try JsonRpcId.parse(allocator, request);
    defer request_id.deinit(allocator);
    const is_subscription = std.mem.eql(u8, request_method, methods.listen);
    var subscription_acknowledged = !is_subscription;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (data.len == 0) continue;
        validateMcpMessage(allocator, data) catch |failure| switch (failure) {
            error.OutOfMemory, error.McpMessageTooLarge => return failure,
            else => continue,
        };
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const object = requiredObject(parsed.value) catch continue;
        if (object.get("method") != null) {
            validateIncomingNotification(
                parsed.value,
                is_subscription,
                error.InvalidMcpMessage,
            ) catch continue;
            if (is_subscription) {
                validateSubscriptionNotification(allocator, parsed.value, request) catch continue;
                const event_method = optionalString(object, "method") orelse unreachable;
                if (std.mem.eql(u8, event_method, methods.subscriptions_acknowledged)) {
                    subscription_acknowledged = true;
                } else if (!subscription_acknowledged) continue;
            }
            if (events) |sink| try sink.emit(data);
            continue;
        }
        const response_id = object.get("id") orelse continue;
        if (request_id.matches(response_id)) return allocator.dupe(u8, data);
    }
    return error.MissingMcpSseResponse;
}

fn rejectLegacyServerRequest(self: *StdioTransport, allocator: std.mem.Allocator, id: std.json.Value) !void {
    const response = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = error_codes.method_not_found, .message = "Server requests use MRTR in MCP 2026-07-28" },
    }, .{});
    defer allocator.free(response);
    const stdin = self.child.stdin orelse return error.McpProcessClosed;
    try stdin.writeStreamingAll(self.io, response);
    try stdin.writeStreamingAll(self.io, "\n");
}

fn readLine(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        const read = try file.readStreaming(io, &.{byte[0..]});
        if (read == 0) return error.EndOfStream;
        if (byte[0] == '\n') return result.toOwnedSlice(allocator);
        if (byte[0] != '\r') try result.append(allocator, byte[0]);
        if (result.items.len > json_limits.defaults.mcp_message.max_document_bytes) return error.McpMessageTooLarge;
    }
}

const JsonRpcId = union(enum) {
    integer: i64,
    string: []u8,

    fn parse(allocator: std.mem.Allocator, message: []const u8) !JsonRpcId {
        const parsed = try json_limits.parse(
            std.json.Value,
            allocator,
            message,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        defer parsed.deinit();
        const value = (try requiredObject(parsed.value)).get("id") orelse return error.InvalidMcpMessage;
        return switch (value) {
            .integer => |integer| .{ .integer = integer },
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            else => error.InvalidMcpMessage,
        };
    }

    fn deinit(self: JsonRpcId, allocator: std.mem.Allocator) void {
        switch (self) {
            .integer => {},
            .string => |string| allocator.free(string),
        }
    }

    fn matches(self: JsonRpcId, actual: std.json.Value) bool {
        return switch (self) {
            .integer => |value| actual == .integer and actual.integer == value,
            .string => |value| actual == .string and std.mem.eql(u8, actual.string, value),
        };
    }
};

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !std.json.Value {
    return json_limits.parseLeaky(
        std.json.Value,
        allocator,
        body,
        json_limits.defaults.mcp_message,
        .{ .allocate = .alloc_always },
        error.InvalidMcpResponse,
    );
}

fn validateMcpMessage(allocator: std.mem.Allocator, source: []const u8) !void {
    try validateMcpDocument(allocator, source, error.InvalidMcpMessage);
}

fn validateMcpResponse(allocator: std.mem.Allocator, source: []const u8) !void {
    try validateMcpDocument(allocator, source, error.InvalidMcpResponse);
}

fn validateMcpDocument(allocator: std.mem.Allocator, source: []const u8, comptime invalid_error: anytype) !void {
    if (source.len > json_limits.defaults.mcp_message.max_document_bytes) return error.McpMessageTooLarge;
    try json_limits.validateAs(allocator, source, json_limits.defaults.mcp_message, invalid_error);
}

fn responseResult(root: std.json.Value, expected_id: u64) !std.json.Value {
    const object = try requiredObject(root);
    if (!std.mem.eql(u8, optionalString(object, "jsonrpc") orelse "", "2.0")) {
        return error.InvalidMcpResponse;
    }
    const actual = object.get("id") orelse return error.InvalidMcpResponse;
    if (actual != .integer or actual.integer != expected_id) return error.McpResponseIdMismatch;
    const result = object.get("result");
    const rpc_error = object.get("error");
    if ((result == null) == (rpc_error == null)) return error.InvalidMcpResponse;
    if (rpc_error) |value| {
        try validateRpcError(value);
        const rpc_error_object = try requiredObject(value);
        if (rpc_error_object.get("code").?.integer == error_codes.unsupported_protocol_version) {
            return error.UnsupportedMcpProtocolVersion;
        }
        return error.McpRpcError;
    }
    return result.?;
}

fn validJsonRpcResponseObject(object: std.json.ObjectMap) bool {
    if (!std.mem.eql(u8, optionalString(object, "jsonrpc") orelse "", "2.0")) return false;
    const result = object.get("result");
    const rpc_error = object.get("error");
    if ((result == null) == (rpc_error == null)) return false;
    if (result != null) {
        const id = object.get("id") orelse return false;
        if (id != .integer and id != .string) return false;
    }
    return true;
}

fn recognizedModernError(value: std.json.Value) bool {
    validateRpcError(value) catch return false;
    const object = requiredObject(value) catch return false;
    const code = switch (object.get("code") orelse return false) {
        .integer => |integer| integer,
        else => return false,
    };
    return code == error_codes.header_mismatch or
        code == error_codes.missing_required_client_capability or
        code == tasks.error_codes.missing_required_client_capability or
        code == error_codes.unsupported_protocol_version;
}

fn validateRpcError(value: std.json.Value) !void {
    const object = try requiredObject(value);
    const code = switch (object.get("code") orelse return error.InvalidMcpResponse) {
        .integer => |integer| integer,
        else => return error.InvalidMcpResponse,
    };
    _ = try requiredString(object, "message");
    if (code == error_codes.unsupported_protocol_version) {
        const data = try requiredObject(object.get("data") orelse return error.InvalidMcpResponse);
        try requireStringArray(data, "supported", 1, null);
        _ = try requiredString(data, "requested");
    } else if (code == error_codes.missing_required_client_capability or
        code == tasks.error_codes.missing_required_client_capability)
    {
        const data = try requiredObject(object.get("data") orelse return error.InvalidMcpResponse);
        try validateClientCapabilities(
            data.get("requiredCapabilities") orelse return error.InvalidMcpResponse,
            error.InvalidMcpResponse,
        );
    }
}

fn validateHttpResponseStatus(allocator: std.mem.Allocator, status: u16, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try parseResponse(arena.allocator(), source);
    const object = try requiredObject(root);
    if (object.get("result") != null) {
        if (status != 200) return error.InvalidMcpResponse;
        return;
    }
    const rpc_error = try requiredObject(object.get("error") orelse return error.InvalidMcpResponse);
    const code = switch (rpc_error.get("code") orelse return error.InvalidMcpResponse) {
        .integer => |integer| integer,
        else => return error.InvalidMcpResponse,
    };
    if ((code == error_codes.header_mismatch or
        code == error_codes.missing_required_client_capability or
        code == tasks.error_codes.missing_required_client_capability or
        code == error_codes.unsupported_protocol_version) and status != 400)
    {
        return error.InvalidMcpResponse;
    }
}

fn validateMethodResult(method: []const u8, result: std.json.Value) !void {
    const object = try requiredObject(result);
    if (object.get("_meta")) |meta_value| {
        const meta = try requiredObject(meta_value);
        try validateMetaKeys(meta, error.InvalidMcpResponse);
        if (meta.get("io.modelcontextprotocol/serverInfo")) |server_info| {
            try validateImplementation(server_info, error.InvalidMcpResponse);
        }
    }
    const result_type = if (object.get("resultType")) |value|
        switch (value) {
            .string => |string| string,
            else => return error.InvalidMcpResponse,
        }
    else
        "complete";
    if (std.mem.eql(u8, result_type, "input_required")) return validateInputRequiredResult(object);
    if (std.mem.eql(u8, result_type, "task")) {
        if (!std.mem.eql(u8, method, methods.call_tool)) return error.InvalidMcpResponse;
        tasks.validateCreated(result) catch return error.InvalidMcpResponse;
        return;
    }
    if (!std.mem.eql(u8, result_type, "complete")) return error.InvalidMcpResponse;

    if (std.mem.eql(u8, method, tasks.methods.get)) {
        tasks.validateResult(result) catch return error.InvalidMcpResponse;
    } else if (std.mem.eql(u8, method, tasks.methods.update) or
        std.mem.eql(u8, method, tasks.methods.cancel))
    {
        return;
    } else if (std.mem.eql(u8, method, methods.discover)) {
        try requireStringArray(object, "supportedVersions", 1, null);
        try validateServerCapabilities(
            object.get("capabilities") orelse return error.InvalidMcpResponse,
            error.InvalidMcpResponse,
        );
        try validateOptionalResponseString(object, "instructions");
        try validateCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_tools)) {
        for (try responseArray(object, "tools")) |tool| try validateTool(tool);
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_prompts)) {
        for (try responseArray(object, "prompts")) |prompt| try validatePrompt(prompt);
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_resources)) {
        for (try responseArray(object, "resources")) |resource| try validateResource(resource, false);
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.list_resource_templates)) {
        for (try responseArray(object, "resourceTemplates")) |resource| try validateResource(resource, true);
        try validatePaginatedCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.read_resource)) {
        for (try responseArray(object, "contents")) |content| try validateResourceContents(content);
        try validateCacheableResult(object);
    } else if (std.mem.eql(u8, method, methods.get_prompt)) {
        try validateOptionalResponseString(object, "description");
        for (try responseArray(object, "messages")) |message_value| {
            const message = try requiredObject(message_value);
            try validateRole(message.get("role") orelse return error.InvalidMcpResponse);
            try validateContentBlock(message.get("content") orelse return error.InvalidMcpResponse);
        }
    } else if (std.mem.eql(u8, method, methods.call_tool)) {
        for (try responseArray(object, "content")) |content| try validateContentBlock(content);
        if (object.get("isError")) |is_error| if (is_error != .bool) return error.InvalidMcpResponse;
    } else if (std.mem.eql(u8, method, methods.complete)) {
        const completion = try requiredObject(object.get("completion") orelse return error.InvalidMcpResponse);
        try requireStringArray(completion, "values", 0, 100);
        try validateOptionalResponseNumber(completion, "total", false);
        if (completion.get("hasMore")) |has_more| if (has_more != .bool) return error.InvalidMcpResponse;
    } else if (std.mem.eql(u8, method, methods.listen)) {
        const meta = try requiredObject(object.get("_meta") orelse return error.InvalidMcpResponse);
        const subscription_id = meta.get("io.modelcontextprotocol/subscriptionId") orelse
            return error.InvalidMcpResponse;
        if (subscription_id != .integer and subscription_id != .string) return error.InvalidMcpResponse;
    }
}

fn validateRequestMethodParams(
    method: []const u8,
    params: std.json.ObjectMap,
    comptime invalid_error: anytype,
) !void {
    if (std.mem.eql(u8, method, tasks.methods.get) or
        std.mem.eql(u8, method, tasks.methods.cancel) or
        std.mem.eql(u8, method, tasks.methods.update))
    {
        const task_id = try requireCapabilityString(params, "taskId", invalid_error);
        if (task_id.len == 0) return invalid_error;
        if (std.mem.eql(u8, method, tasks.methods.update)) {
            const responses = try capabilityObject(
                params.get("inputResponses") orelse return invalid_error,
                invalid_error,
            );
            var iterator = responses.iterator();
            while (iterator.next()) |entry| if (entry.value_ptr.* != .object) return invalid_error;
        }
    } else if (std.mem.eql(u8, method, methods.list_tools) or
        std.mem.eql(u8, method, methods.list_prompts) or
        std.mem.eql(u8, method, methods.list_resources) or
        std.mem.eql(u8, method, methods.list_resource_templates))
    {
        try validateOptionalString(params, "cursor", invalid_error);
    } else if (std.mem.eql(u8, method, methods.read_resource)) {
        _ = try requireCapabilityString(params, "uri", invalid_error);
        try validateInputResponseParams(params, invalid_error);
    } else if (std.mem.eql(u8, method, methods.get_prompt)) {
        _ = try requireCapabilityString(params, "name", invalid_error);
        if (params.get("arguments")) |arguments| try validateStringMap(arguments, invalid_error);
        try validateInputResponseParams(params, invalid_error);
    } else if (std.mem.eql(u8, method, methods.call_tool)) {
        _ = try requireCapabilityString(params, "name", invalid_error);
        try validateOptionalObject(params, "arguments", invalid_error);
        try validateInputResponseParams(params, invalid_error);
    } else if (std.mem.eql(u8, method, methods.complete)) {
        try validateCompletionParams(params, invalid_error);
    } else if (std.mem.eql(u8, method, methods.listen)) {
        try validateSubscriptionFilter(
            params.get("notifications") orelse return invalid_error,
            invalid_error,
        );
    }
}

fn validateNotificationMethodParams(
    method: []const u8,
    params: std.json.ObjectMap,
    comptime invalid_error: anytype,
) !void {
    if (std.mem.eql(u8, method, methods.cancelled)) {
        try requireRequestId(params, "requestId", invalid_error);
        try validateOptionalString(params, "reason", invalid_error);
    } else if (std.mem.eql(u8, method, methods.progress)) {
        try requireRequestId(params, "progressToken", invalid_error);
        try requireNumber(params, "progress", invalid_error);
        try validateOptionalNumber(params, "total", invalid_error);
        try validateOptionalString(params, "message", invalid_error);
    } else if (std.mem.eql(u8, method, methods.logging_message)) {
        const level = try requireCapabilityString(params, "level", invalid_error);
        if (!validLoggingLevel(level)) return invalid_error;
        try validateOptionalString(params, "logger", invalid_error);
        if (params.get("data") == null) return invalid_error;
    } else if (std.mem.eql(u8, method, methods.resource_updated)) {
        _ = try requireCapabilityString(params, "uri", invalid_error);
    } else if (std.mem.eql(u8, method, methods.subscriptions_acknowledged)) {
        try validateSubscriptionFilter(
            params.get("notifications") orelse return invalid_error,
            invalid_error,
        );
    } else if (std.mem.eql(u8, method, tasks.methods.status_notification)) {
        tasks.validateNotification(.{ .object = params }) catch return invalid_error;
    }
    if (params.get("_meta")) |meta_value| {
        const meta = try capabilityObject(meta_value, invalid_error);
        try validateMetaKeys(meta, invalid_error);
        if (meta.get("io.modelcontextprotocol/subscriptionId")) |id| {
            try validateRequestId(id, invalid_error);
        }
    }
}

fn validateIncomingNotification(
    value: std.json.Value,
    require_subscription_id: bool,
    comptime invalid_error: anytype,
) !void {
    const object = try capabilityObject(value, invalid_error);
    const version = try requireCapabilityString(object, "jsonrpc", invalid_error);
    if (!std.mem.eql(u8, version, "2.0") or object.get("id") != null) return invalid_error;
    const method = try requireCapabilityString(object, "method", invalid_error);
    const params = if (object.get("params")) |params_value|
        try capabilityObject(params_value, invalid_error)
    else
        std.json.ObjectMap{};
    try validateNotificationMethodParams(method, params, invalid_error);
    if (require_subscription_id) {
        const meta = try capabilityObject(params.get("_meta") orelse return invalid_error, invalid_error);
        try validateRequestId(
            meta.get("io.modelcontextprotocol/subscriptionId") orelse return invalid_error,
            invalid_error,
        );
    }
}

fn validateSubscriptionNotification(
    allocator: std.mem.Allocator,
    notification_value: std.json.Value,
    request_json: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_value = parseResponse(arena.allocator(), request_json) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMcpMessage,
    };
    const request = requiredObject(request_value) catch return error.InvalidMcpMessage;
    const request_params = requiredObject(request.get("params") orelse return error.InvalidMcpMessage) catch
        return error.InvalidMcpMessage;
    const filter = requiredObject(request_params.get("notifications") orelse return error.InvalidMcpMessage) catch
        return error.InvalidMcpMessage;
    const notification = requiredObject(notification_value) catch return error.InvalidMcpMessage;
    const method = requiredString(notification, "method") catch return error.InvalidMcpMessage;
    const allowed = if (std.mem.eql(u8, method, methods.subscriptions_acknowledged) or
        std.mem.eql(u8, method, methods.cancelled))
        true
    else if (std.mem.eql(u8, method, methods.tool_list_changed))
        optionalBool(filter, "toolsListChanged") orelse false
    else if (std.mem.eql(u8, method, methods.prompt_list_changed))
        optionalBool(filter, "promptsListChanged") orelse false
    else if (std.mem.eql(u8, method, methods.resource_list_changed))
        optionalBool(filter, "resourcesListChanged") orelse false
    else if (std.mem.eql(u8, method, methods.resource_updated))
        switch (filter.get("resourceSubscriptions") orelse return error.InvalidMcpMessage) {
            .array => |items| items.items.len > 0,
            else => false,
        }
    else if (std.mem.eql(u8, method, tasks.methods.status_notification)) blk: {
        const notification_params = try capabilityObject(
            notification.get("params") orelse return error.InvalidMcpMessage,
            error.InvalidMcpMessage,
        );
        const task_id = optionalString(notification_params, "taskId") orelse
            return error.InvalidMcpMessage;
        break :blk subscriptionContains(filter, "taskIds", task_id);
    } else if (std.mem.eql(u8, method, methods.progress) or
        std.mem.eql(u8, method, methods.logging_message))
        false
    else
        true;
    if (!allowed) return error.InvalidMcpMessage;
}

fn validateInputResponseParams(params: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    try validateOptionalObject(params, "inputResponses", invalid_error);
    try validateOptionalString(params, "requestState", invalid_error);
}

fn validateCompletionParams(params: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    const reference = try capabilityObject(params.get("ref") orelse return invalid_error, invalid_error);
    const reference_type = try requireCapabilityString(reference, "type", invalid_error);
    if (std.mem.eql(u8, reference_type, "ref/prompt")) {
        _ = try requireCapabilityString(reference, "name", invalid_error);
    } else if (std.mem.eql(u8, reference_type, "ref/resource")) {
        _ = try requireCapabilityString(reference, "uri", invalid_error);
    } else return invalid_error;

    const argument = try capabilityObject(params.get("argument") orelse return invalid_error, invalid_error);
    _ = try requireCapabilityString(argument, "name", invalid_error);
    _ = try requireCapabilityString(argument, "value", invalid_error);
    if (params.get("context")) |context_value| {
        const context = try capabilityObject(context_value, invalid_error);
        if (context.get("arguments")) |arguments| try validateStringMap(arguments, invalid_error);
    }
}

fn validateSubscriptionFilter(value: std.json.Value, comptime invalid_error: anytype) !void {
    const filter = try capabilityObject(value, invalid_error);
    try validateOptionalBool(filter, "toolsListChanged", invalid_error);
    try validateOptionalBool(filter, "promptsListChanged", invalid_error);
    try validateOptionalBool(filter, "resourcesListChanged", invalid_error);
    if (filter.get("resourceSubscriptions")) |subscriptions| {
        const values = switch (subscriptions) {
            .array => |array| array,
            else => return invalid_error,
        };
        for (values.items) |uri| if (uri != .string) return invalid_error;
    }
    if (filter.get("taskIds")) |task_ids| {
        const values = switch (task_ids) {
            .array => |array| array,
            else => return invalid_error,
        };
        for (values.items) |task_id| switch (task_id) {
            .string => |identifier| if (identifier.len == 0) return invalid_error,
            else => return invalid_error,
        };
    }
}

fn validateStringMap(value: std.json.Value, comptime invalid_error: anytype) !void {
    const object = try capabilityObject(value, invalid_error);
    var iterator = object.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.* != .string) return invalid_error;
}

fn requireCapabilityString(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) ![]const u8 {
    return switch (object.get(name) orelse return invalid_error) {
        .string => |string| string,
        else => invalid_error,
    };
}

fn validateOptionalString(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    if (object.get(name)) |value| if (value != .string) return invalid_error;
}

fn requireRequestId(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    try validateRequestId(object.get(name) orelse return invalid_error, invalid_error);
}

fn validateRequestId(value: std.json.Value, comptime invalid_error: anytype) !void {
    if (value != .integer and value != .string) return invalid_error;
}

fn requireNumber(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    try validateNumber(object.get(name) orelse return invalid_error, invalid_error);
}

fn validateOptionalNumber(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    if (object.get(name)) |value| try validateNumber(value, invalid_error);
}

fn validateNumber(value: std.json.Value, comptime invalid_error: anytype) !void {
    switch (value) {
        .integer => {},
        .float => |number| if (!std.math.isFinite(number)) return invalid_error,
        else => return invalid_error,
    }
}

fn validLoggingLevel(value: []const u8) bool {
    const levels = [_][]const u8{
        "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency",
    };
    for (levels) |level| if (std.mem.eql(u8, value, level)) return true;
    return false;
}

fn validateRequestMeta(object: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    try validateMetaKeys(object, invalid_error);
    const version = try requireCapabilityString(
        object,
        "io.modelcontextprotocol/protocolVersion",
        invalid_error,
    );
    if (version.len == 0) return invalid_error;
    if (object.get("io.modelcontextprotocol/clientCapabilities")) |capabilities| {
        _ = try capabilityObject(capabilities, invalid_error);
    }
    if (object.get("io.modelcontextprotocol/clientInfo")) |client_info| {
        try validateImplementation(client_info, invalid_error);
    }
    if (object.get("progressToken")) |token| try validateRequestId(token, invalid_error);
    if (object.get("io.modelcontextprotocol/logLevel")) |level_value| {
        const level = switch (level_value) {
            .string => |string| string,
            else => return invalid_error,
        };
        if (!validLoggingLevel(level)) return invalid_error;
    }
}

fn validateImplementation(value: std.json.Value, comptime invalid_error: anytype) !void {
    const implementation = try capabilityObject(value, invalid_error);
    _ = try requireCapabilityString(implementation, "name", invalid_error);
    _ = try requireCapabilityString(implementation, "version", invalid_error);
    try validateOptionalString(implementation, "title", invalid_error);
    try validateOptionalString(implementation, "description", invalid_error);
    try validateOptionalString(implementation, "websiteUrl", invalid_error);
    if (implementation.get("icons")) |icons_value| {
        const icons = switch (icons_value) {
            .array => |array| array,
            else => return invalid_error,
        };
        for (icons.items) |icon_value| {
            const icon = try capabilityObject(icon_value, invalid_error);
            _ = try requireCapabilityString(icon, "src", invalid_error);
            try validateOptionalString(icon, "mimeType", invalid_error);
            if (icon.get("sizes")) |sizes_value| {
                const sizes = switch (sizes_value) {
                    .array => |array| array,
                    else => return invalid_error,
                };
                for (sizes.items) |size| if (size != .string) return invalid_error;
            }
            if (icon.get("theme")) |theme_value| {
                const theme = switch (theme_value) {
                    .string => |string| string,
                    else => return invalid_error,
                };
                if (!std.mem.eql(u8, theme, "light") and !std.mem.eql(u8, theme, "dark")) {
                    return invalid_error;
                }
            }
        }
    }
}

fn validateMetaKeys(object: std.json.ObjectMap, comptime invalid_error: anytype) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| if (!validMetaKey(entry.key_ptr.*, false)) return invalid_error;
}

fn validateClientCapabilities(value: std.json.Value, comptime invalid_error: anytype) !void {
    const capabilities = switch (value) {
        .object => |object| object,
        else => return invalid_error,
    };
    if (capabilities.get("experimental")) |experimental| {
        try validateObjectValues(experimental, invalid_error);
    }
    if (capabilities.get("roots")) |roots| try requireCapabilityObject(roots, invalid_error);
    if (capabilities.get("sampling")) |sampling_value| {
        const sampling = try capabilityObject(sampling_value, invalid_error);
        try validateOptionalObject(sampling, "context", invalid_error);
        try validateOptionalObject(sampling, "tools", invalid_error);
    }
    if (capabilities.get("elicitation")) |elicitation_value| {
        const elicitation = try capabilityObject(elicitation_value, invalid_error);
        try validateOptionalObject(elicitation, "form", invalid_error);
        try validateOptionalObject(elicitation, "url", invalid_error);
    }
    if (capabilities.get("extensions")) |extensions| {
        try validateExtensions(extensions, invalid_error);
    }
}

fn validateServerCapabilities(value: std.json.Value, comptime invalid_error: anytype) !void {
    const capabilities = switch (value) {
        .object => |object| object,
        else => return invalid_error,
    };
    if (capabilities.get("experimental")) |experimental| {
        try validateObjectValues(experimental, invalid_error);
    }
    try validateOptionalObject(capabilities, "logging", invalid_error);
    try validateOptionalObject(capabilities, "completions", invalid_error);
    if (capabilities.get("prompts")) |prompts_value| {
        const prompts = try capabilityObject(prompts_value, invalid_error);
        try validateOptionalBool(prompts, "listChanged", invalid_error);
    }
    if (capabilities.get("resources")) |resources_value| {
        const resources = try capabilityObject(resources_value, invalid_error);
        try validateOptionalBool(resources, "subscribe", invalid_error);
        try validateOptionalBool(resources, "listChanged", invalid_error);
    }
    if (capabilities.get("tools")) |tools_value| {
        const tools = try capabilityObject(tools_value, invalid_error);
        try validateOptionalBool(tools, "listChanged", invalid_error);
    }
    if (capabilities.get("extensions")) |extensions| {
        try validateExtensions(extensions, invalid_error);
    }
}

fn validateExtensions(value: std.json.Value, comptime invalid_error: anytype) !void {
    const extensions = try capabilityObject(value, invalid_error);
    var iterator = extensions.iterator();
    while (iterator.next()) |entry| {
        if (!validPrefixedMetaKey(entry.key_ptr.*)) return invalid_error;
        try requireCapabilityObject(entry.value_ptr.*, invalid_error);
    }
}

fn validateObjectValues(value: std.json.Value, comptime invalid_error: anytype) !void {
    const object = try capabilityObject(value, invalid_error);
    var iterator = object.iterator();
    while (iterator.next()) |entry| try requireCapabilityObject(entry.value_ptr.*, invalid_error);
}

fn validateOptionalObject(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    if (object.get(name)) |value| try requireCapabilityObject(value, invalid_error);
}

fn validateOptionalBool(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime invalid_error: anytype,
) !void {
    if (object.get(name)) |value| if (value != .bool) return invalid_error;
}

fn requireCapabilityObject(value: std.json.Value, comptime invalid_error: anytype) !void {
    _ = try capabilityObject(value, invalid_error);
}

fn capabilityObject(value: std.json.Value, comptime invalid_error: anytype) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => invalid_error,
    };
}

fn validPrefixedMetaKey(key: []const u8) bool {
    return primitives.isExtensionIdentifier(key);
}

fn validMetaKey(key: []const u8, require_prefix: bool) bool {
    const slash = std.mem.indexOfScalar(u8, key, '/');
    const name = if (slash) |separator| blk: {
        if (separator == 0 or std.mem.indexOfScalarPos(u8, key, separator + 1, '/') != null) return false;
        var labels = std.mem.splitScalar(u8, key[0..separator], '.');
        while (labels.next()) |label| {
            if (label.len == 0 or !std.ascii.isAlphabetic(label[0]) or
                !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
            if (label.len > 2) {
                for (label[1 .. label.len - 1]) |character| {
                    if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
                }
            }
        }
        break :blk key[separator + 1 ..];
    } else blk: {
        if (require_prefix) return false;
        break :blk key;
    };
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

fn validateInputRequiredResult(object: std.json.ObjectMap) !void {
    var has_state = false;
    if (object.get("requestState")) |state| {
        if (state != .string) return error.InvalidMcpResponse;
        has_state = true;
    }
    var has_requests = false;
    if (object.get("inputRequests")) |requests_value| {
        const requests = try requiredObject(requests_value);
        var iterator = requests.iterator();
        while (iterator.next()) |entry| {
            has_requests = true;
            const request = try requiredObject(entry.value_ptr.*);
            const method = try requiredString(request, "method");
            if (!std.mem.eql(u8, method, methods.elicit) and
                !std.mem.eql(u8, method, methods.list_roots) and
                !std.mem.eql(u8, method, methods.create_message)) return error.InvalidMcpResponse;
            if (request.get("params")) |params| _ = try requiredObject(params);
            try validateInputRequest(request);
        }
    }
    if (!has_state and !has_requests) return error.InvalidMcpResponse;
}

fn validateInputRequest(request: std.json.ObjectMap) !void {
    const method = try requiredString(request, "method");
    const params = if (request.get("params")) |value| try requiredObject(value) else std.json.ObjectMap{};
    if (std.mem.eql(u8, method, methods.elicit)) {
        try validateElicitationRequest(params);
    } else if (std.mem.eql(u8, method, methods.list_roots)) {
        // Roots has no method-specific parameters; extension metadata remains open.
    } else if (std.mem.eql(u8, method, methods.create_message)) {
        try validateSamplingRequest(params);
    } else return error.InvalidMcpResponse;
}

fn validateInputResponse(method: []const u8, value: std.json.Value) !void {
    const response = try requiredObject(value);
    if (std.mem.eql(u8, method, methods.elicit)) {
        const action = try requiredString(response, "action");
        if (!std.mem.eql(u8, action, "accept") and
            !std.mem.eql(u8, action, "decline") and
            !std.mem.eql(u8, action, "cancel")) return error.InvalidMcpResponse;
        if (response.get("content")) |content_value| {
            if (!std.mem.eql(u8, action, "accept")) return error.InvalidMcpResponse;
            const content = try requiredObject(content_value);
            var iterator = content.iterator();
            while (iterator.next()) |entry| switch (entry.value_ptr.*) {
                .string, .integer, .float, .bool => {},
                .array => |items| for (items.items) |item| if (item != .string) return error.InvalidMcpResponse,
                else => return error.InvalidMcpResponse,
            };
        }
    } else if (std.mem.eql(u8, method, methods.list_roots)) {
        for (try responseArray(response, "roots")) |root_value| {
            const root = try requiredObject(root_value);
            const uri = try requiredString(root, "uri");
            if (!std.mem.startsWith(u8, uri, "file://")) return error.InvalidMcpResponse;
            try validateOptionalResponseString(root, "name");
        }
    } else if (std.mem.eql(u8, method, methods.create_message)) {
        try validateSamplingMessage(response);
        _ = try requiredString(response, "model");
        try validateOptionalResponseString(response, "stopReason");
    } else return error.InvalidMcpResponse;
}

fn validateElicitationRequest(params: std.json.ObjectMap) !void {
    const mode = optionalString(params, "mode") orelse "form";
    _ = try requiredString(params, "message");
    if (std.mem.eql(u8, mode, "url")) {
        _ = try requiredString(params, "url");
        if (params.get("requestedSchema") != null) return error.InvalidMcpResponse;
    } else if (std.mem.eql(u8, mode, "form")) {
        if (params.get("url") != null) return error.InvalidMcpResponse;
        try validateElicitationSchema(params.get("requestedSchema") orelse return error.InvalidMcpResponse);
    } else return error.InvalidMcpResponse;
}

fn validateElicitationSchema(value: std.json.Value) !void {
    const schema = try requiredObject(value);
    if (!std.mem.eql(u8, optionalString(schema, "type") orelse "", "object")) {
        return error.InvalidMcpResponse;
    }
    try validateOptionalResponseString(schema, "$schema");
    const properties = try requiredObject(schema.get("properties") orelse return error.InvalidMcpResponse);
    var iterator = properties.iterator();
    while (iterator.next()) |entry| try validatePrimitiveSchema(entry.value_ptr.*);
    if (schema.get("required")) |required| try validateStringArrayValue(required);
}

fn validatePrimitiveSchema(value: std.json.Value) !void {
    const schema = try requiredObject(value);
    const schema_type = try requiredString(schema, "type");
    try validateOptionalResponseString(schema, "title");
    try validateOptionalResponseString(schema, "description");
    if (std.mem.eql(u8, schema_type, "string")) {
        try validateOptionalResponseNumber(schema, "minLength", true);
        try validateOptionalResponseNumber(schema, "maxLength", true);
        if (optionalString(schema, "format")) |format| {
            if (!std.mem.eql(u8, format, "email") and !std.mem.eql(u8, format, "uri") and
                !std.mem.eql(u8, format, "date") and !std.mem.eql(u8, format, "date-time"))
            {
                return error.InvalidMcpResponse;
            }
        } else if (schema.get("format") != null) return error.InvalidMcpResponse;
        try validateOptionalResponseString(schema, "default");
        try validateOptionalStringEnum(schema);
    } else if (std.mem.eql(u8, schema_type, "number") or std.mem.eql(u8, schema_type, "integer")) {
        try validateOptionalResponseNumber(schema, "minimum", false);
        try validateOptionalResponseNumber(schema, "maximum", false);
        try validateOptionalResponseNumber(schema, "default", false);
    } else if (std.mem.eql(u8, schema_type, "boolean")) {
        if (schema.get("default")) |default| if (default != .bool) return error.InvalidMcpResponse;
    } else if (std.mem.eql(u8, schema_type, "array")) {
        try validateOptionalResponseNumber(schema, "minItems", true);
        try validateOptionalResponseNumber(schema, "maxItems", true);
        const items = try requiredObject(schema.get("items") orelse return error.InvalidMcpResponse);
        if (items.get("enum")) |values| {
            if (!std.mem.eql(u8, optionalString(items, "type") orelse "", "string")) {
                return error.InvalidMcpResponse;
            }
            try validateStringArrayValue(values);
        } else if (items.get("anyOf")) |options| {
            try validateTitledOptions(options);
        } else return error.InvalidMcpResponse;
        if (schema.get("default")) |default| try validateStringArrayValue(default);
    } else return error.InvalidMcpResponse;
}

fn validateOptionalStringEnum(schema: std.json.ObjectMap) !void {
    if (schema.get("enum")) |values| {
        try validateStringArrayValue(values);
        if (schema.get("enumNames")) |names| try validateStringArrayValue(names);
    }
    if (schema.get("oneOf")) |options| try validateTitledOptions(options);
}

fn validateTitledOptions(value: std.json.Value) !void {
    const options = switch (value) {
        .array => |array| array,
        else => return error.InvalidMcpResponse,
    };
    for (options.items) |option_value| {
        const option = try requiredObject(option_value);
        _ = try requiredString(option, "const");
        _ = try requiredString(option, "title");
    }
}

fn validateStringArrayValue(value: std.json.Value) !void {
    const items = switch (value) {
        .array => |array| array,
        else => return error.InvalidMcpResponse,
    };
    for (items.items) |item| if (item != .string) return error.InvalidMcpResponse;
}

fn validateSamplingRequest(params: std.json.ObjectMap) !void {
    const messages = switch (params.get("messages") orelse return error.InvalidMcpResponse) {
        .array => |array| array,
        else => return error.InvalidMcpResponse,
    };
    for (messages.items) |message| try validateSamplingMessage(try requiredObject(message));
    try validateOptionalResponseString(params, "systemPrompt");
    _ = params.get("maxTokens") orelse return error.InvalidMcpResponse;
    try validateOptionalResponseNumber(params, "maxTokens", true);
    try validateOptionalResponseNumber(params, "temperature", false);
    if (optionalString(params, "includeContext")) |context| {
        if (!std.mem.eql(u8, context, "none") and !std.mem.eql(u8, context, "thisServer") and
            !std.mem.eql(u8, context, "allServers")) return error.InvalidMcpResponse;
    } else if (params.get("includeContext") != null) return error.InvalidMcpResponse;
    if (params.get("stopSequences")) |sequences| try validateStringArrayValue(sequences);
    if (params.get("metadata")) |metadata| _ = try requiredObject(metadata);
    if (params.get("tools")) |tools_value| {
        const tools = switch (tools_value) {
            .array => |array| array,
            else => return error.InvalidMcpResponse,
        };
        for (tools.items) |tool| try validateTool(tool);
    }
    if (params.get("toolChoice")) |choice_value| {
        const choice = try requiredObject(choice_value);
        if (optionalString(choice, "mode")) |mode| {
            if (!std.mem.eql(u8, mode, "auto") and !std.mem.eql(u8, mode, "required") and
                !std.mem.eql(u8, mode, "none")) return error.InvalidMcpResponse;
        } else if (choice.get("mode") != null) return error.InvalidMcpResponse;
    }
    if (params.get("modelPreferences")) |preferences_value| try validateModelPreferences(preferences_value);
}

fn validateModelPreferences(value: std.json.Value) !void {
    const preferences = try requiredObject(value);
    for ([_][]const u8{ "costPriority", "speedPriority", "intelligencePriority" }) |name| {
        if (preferences.get(name)) |priority| {
            const number = switch (priority) {
                .integer => |integer| @as(f64, @floatFromInt(integer)),
                .float => |float| float,
                else => return error.InvalidMcpResponse,
            };
            if (!std.math.isFinite(number) or number < 0 or number > 1) return error.InvalidMcpResponse;
        }
    }
    if (preferences.get("hints")) |hints_value| {
        const hints = switch (hints_value) {
            .array => |array| array,
            else => return error.InvalidMcpResponse,
        };
        for (hints.items) |hint_value| {
            const hint = try requiredObject(hint_value);
            try validateOptionalResponseString(hint, "name");
        }
    }
}

fn validateSamplingMessage(message: std.json.ObjectMap) !void {
    try validateRole(message.get("role") orelse return error.InvalidMcpResponse);
    const content = message.get("content") orelse return error.InvalidMcpResponse;
    switch (content) {
        .array => |items| for (items.items) |item| try validateSamplingContent(item),
        else => try validateSamplingContent(content),
    }
}

fn validateSamplingContent(value: std.json.Value) !void {
    const content = try requiredObject(value);
    const content_type = try requiredString(content, "type");
    if (std.mem.eql(u8, content_type, "text") or std.mem.eql(u8, content_type, "image") or
        std.mem.eql(u8, content_type, "audio"))
    {
        try validateContentBlock(value);
    } else if (std.mem.eql(u8, content_type, "tool_use")) {
        _ = try requiredString(content, "id");
        _ = try requiredString(content, "name");
        _ = try requiredObject(content.get("input") orelse return error.InvalidMcpResponse);
    } else if (std.mem.eql(u8, content_type, "tool_result")) {
        _ = try requiredString(content, "toolUseId");
        for (try responseArray(content, "content")) |item| try validateContentBlock(item);
        if (content.get("isError")) |is_error| if (is_error != .bool) return error.InvalidMcpResponse;
    } else return error.InvalidMcpResponse;
    try validateOptionalMeta(content);
}

const ClientCapabilityRequirements = struct {
    elicitation: bool = false,
    elicitation_url: bool = false,
    roots: bool = false,
    sampling: bool = false,
    sampling_context: bool = false,
    sampling_tools: bool = false,
    tasks: bool = false,
};

fn inputCapabilityRequirements(result: std.json.Value) !ClientCapabilityRequirements {
    const object = try requiredObject(result);
    const result_type = optionalString(object, "resultType") orelse "complete";
    if (std.mem.eql(u8, result_type, "task")) return .{ .tasks = true };
    if (!std.mem.eql(u8, result_type, "input_required")) return .{};
    const requests = if (object.get("inputRequests")) |value| try requiredObject(value) else return .{};
    var requirements: ClientCapabilityRequirements = .{};
    var iterator = requests.iterator();
    while (iterator.next()) |entry| {
        const request = try requiredObject(entry.value_ptr.*);
        const method = try requiredString(request, "method");
        const params = if (request.get("params")) |value| try requiredObject(value) else std.json.ObjectMap{};
        if (std.mem.eql(u8, method, methods.elicit)) {
            requirements.elicitation = true;
            if (std.mem.eql(u8, optionalString(params, "mode") orelse "form", "url")) {
                requirements.elicitation_url = true;
            }
        } else if (std.mem.eql(u8, method, methods.list_roots)) {
            requirements.roots = true;
        } else if (std.mem.eql(u8, method, methods.create_message)) {
            requirements.sampling = true;
            if (params.get("tools") != null or params.get("toolChoice") != null) {
                requirements.sampling_tools = true;
            }
            if (optionalString(params, "includeContext")) |context| {
                if (!std.mem.eql(u8, context, "none")) requirements.sampling_context = true;
            }
        }
    }
    return requirements;
}

fn validateInputRequiredCapabilities(result: std.json.Value, client_capabilities: std.json.Value) !void {
    try validateClientCapabilities(client_capabilities, error.InvalidMcpMessage);
    const requirements = try inputCapabilityRequirements(result);
    if (!clientCapabilitiesSatisfy(client_capabilities, requirements)) return error.InvalidMcpResponse;
}

fn clientCapabilitiesSatisfy(
    value: std.json.Value,
    requirements: ClientCapabilityRequirements,
) bool {
    const capabilities = switch (value) {
        .object => |object| object,
        else => return false,
    };
    const elicitation = if (capabilities.get("elicitation")) |item| switch (item) {
        .object => |object| object,
        else => return false,
    } else std.json.ObjectMap{};
    const sampling = if (capabilities.get("sampling")) |item| switch (item) {
        .object => |object| object,
        else => return false,
    } else std.json.ObjectMap{};
    if (requirements.elicitation and capabilities.get("elicitation") == null) return false;
    if (requirements.elicitation_url and elicitation.get("url") == null) return false;
    if (requirements.roots and capabilities.get("roots") == null) return false;
    if (requirements.sampling and capabilities.get("sampling") == null) return false;
    if (requirements.sampling_context and sampling.get("context") == null) return false;
    if (requirements.sampling_tools and sampling.get("tools") == null) return false;
    if (requirements.tasks and !hasExtensionCapability(capabilities, tasks.extension_identifier)) return false;
    return true;
}

fn missingClientCapabilities(
    allocator: std.mem.Allocator,
    current: std.json.Value,
    requirements: ClientCapabilityRequirements,
) !std.json.Value {
    const capabilities = switch (current) {
        .object => |object| object,
        else => std.json.ObjectMap{},
    };
    var missing: std.json.ObjectMap = .{};
    if (requirements.elicitation and capabilities.get("elicitation") == null or requirements.elicitation_url) {
        var elicitation: std.json.ObjectMap = .{};
        if (requirements.elicitation_url) try elicitation.put(allocator, "url", .{ .object = .{} });
        try missing.put(allocator, "elicitation", .{ .object = elicitation }); // kcov-ignore: result assertion covers this source-map artifact
    }
    if (requirements.roots and capabilities.get("roots") == null) {
        try missing.put(allocator, "roots", .{ .object = .{} });
    }
    if (requirements.sampling and capabilities.get("sampling") == null or
        requirements.sampling_context or requirements.sampling_tools)
    {
        var sampling: std.json.ObjectMap = .{};
        if (requirements.sampling_context) try sampling.put(allocator, "context", .{ .object = .{} });
        if (requirements.sampling_tools) try sampling.put(allocator, "tools", .{ .object = .{} });
        try missing.put(allocator, "sampling", .{ .object = sampling });
    }
    if (requirements.tasks and !hasExtensionCapability(capabilities, tasks.extension_identifier)) {
        var extensions: std.json.ObjectMap = .{};
        try extensions.put(allocator, tasks.extension_identifier, .{ .object = .{} });
        try missing.put(allocator, "extensions", .{ .object = extensions });
    }
    return .{ .object = missing };
}

fn hasExtensionCapability(capabilities: std.json.ObjectMap, identifier: []const u8) bool {
    const extensions = switch (capabilities.get("extensions") orelse return false) {
        .object => |object| object,
        else => return false,
    };
    return extensions.get(identifier) != null;
}

fn serverSupportsMethod(capabilities_value: std.json.Value, method: []const u8) bool {
    const capabilities = switch (capabilities_value) {
        .object => |object| object,
        else => return false,
    };
    if (isTaskMethod(method)) {
        return hasExtensionCapability(capabilities, tasks.extension_identifier);
    }
    if (std.mem.eql(u8, method, methods.complete)) return capabilities.get("completions") != null;
    if (std.mem.eql(u8, method, methods.get_prompt) or std.mem.eql(u8, method, methods.list_prompts)) {
        return capabilities.get("prompts") != null;
    }
    if (std.mem.eql(u8, method, methods.list_resources) or
        std.mem.eql(u8, method, methods.list_resource_templates) or
        std.mem.eql(u8, method, methods.read_resource))
    {
        return capabilities.get("resources") != null;
    }
    if (std.mem.eql(u8, method, methods.call_tool) or std.mem.eql(u8, method, methods.list_tools)) {
        return capabilities.get("tools") != null;
    }
    return true;
}

fn validatePaginatedCacheableResult(object: std.json.ObjectMap) !void {
    try validateCacheableResult(object);
    if (object.get("nextCursor")) |cursor| if (cursor != .string) return error.InvalidMcpResponse;
}

fn validateCacheableResult(object: std.json.ObjectMap) !void {
    const ttl = object.get("ttlMs") orelse return error.InvalidMcpResponse;
    const nonnegative = switch (ttl) {
        .integer => |value| value >= 0,
        .float => |value| value >= 0 and std.math.isFinite(value),
        else => false,
    };
    if (!nonnegative) return error.InvalidMcpResponse;
    const scope = try requiredString(object, "cacheScope");
    if (!std.mem.eql(u8, scope, "public") and !std.mem.eql(u8, scope, "private")) {
        return error.InvalidMcpResponse;
    }
}

fn validateTool(value: std.json.Value) !void {
    const tool = try requiredObject(value);
    try validateBaseMetadata(tool);
    try validateOptionalResponseString(tool, "description");
    const input_schema = try requiredObject(tool.get("inputSchema") orelse return error.InvalidMcpResponse);
    if (!std.mem.eql(u8, optionalString(input_schema, "type") orelse "", "object")) {
        return error.InvalidMcpResponse;
    }
    if (tool.get("outputSchema")) |schema| _ = try requiredObject(schema);
    if (tool.get("annotations")) |annotations_value| {
        const annotations = try requiredObject(annotations_value);
        try validateOptionalResponseString(annotations, "title");
        for ([_][]const u8{ "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint" }) |name| {
            if (annotations.get(name)) |hint| if (hint != .bool) return error.InvalidMcpResponse;
        }
    }
}

fn validatePrompt(value: std.json.Value) !void {
    const prompt = try requiredObject(value);
    try validateBaseMetadata(prompt);
    try validateOptionalResponseString(prompt, "description");
    if (prompt.get("arguments")) |arguments_value| {
        const arguments = switch (arguments_value) {
            .array => |array| array,
            else => return error.InvalidMcpResponse,
        };
        for (arguments.items) |argument_value| {
            const argument = try requiredObject(argument_value);
            try validateBaseMetadata(argument);
            try validateOptionalResponseString(argument, "description");
            if (argument.get("required")) |required| if (required != .bool) return error.InvalidMcpResponse;
        }
    }
}

fn validateResource(value: std.json.Value, template: bool) !void {
    const resource = try requiredObject(value);
    try validateBaseMetadata(resource);
    _ = try requiredString(resource, if (template) "uriTemplate" else "uri");
    try validateOptionalResponseString(resource, "description");
    try validateOptionalResponseString(resource, "mimeType");
    if (!template) try validateOptionalResponseNumber(resource, "size", true);
    try validateOptionalAnnotations(resource);
}

fn validateResourceContents(value: std.json.Value) !void {
    const content = try requiredObject(value);
    _ = try requiredString(content, "uri");
    try validateOptionalResponseString(content, "mimeType");
    const text = content.get("text");
    const blob = content.get("blob");
    if (text == null and blob == null) return error.InvalidMcpResponse;
    if (text) |item| if (item != .string) return error.InvalidMcpResponse;
    if (blob) |item| if (item != .string) return error.InvalidMcpResponse;
    try validateOptionalMeta(content);
}

fn validateContentBlock(value: std.json.Value) !void {
    const content = try requiredObject(value);
    const content_type = try requiredString(content, "type");
    if (std.mem.eql(u8, content_type, "text")) {
        _ = try requiredString(content, "text");
    } else if (std.mem.eql(u8, content_type, "image") or std.mem.eql(u8, content_type, "audio")) {
        _ = try requiredString(content, "data");
        _ = try requiredString(content, "mimeType");
    } else if (std.mem.eql(u8, content_type, "resource_link")) {
        try validateResource(value, false);
    } else if (std.mem.eql(u8, content_type, "resource")) {
        try validateResourceContents(content.get("resource") orelse return error.InvalidMcpResponse);
    } else return error.InvalidMcpResponse;
    try validateOptionalAnnotations(content);
    try validateOptionalMeta(content);
}

fn validateBaseMetadata(object: std.json.ObjectMap) !void {
    _ = try requiredString(object, "name");
    try validateOptionalResponseString(object, "title");
    if (object.get("icons")) |icons_value| {
        const icons = switch (icons_value) {
            .array => |array| array,
            else => return error.InvalidMcpResponse,
        };
        for (icons.items) |icon_value| {
            const icon = try requiredObject(icon_value);
            _ = try requiredString(icon, "src");
            try validateOptionalResponseString(icon, "mimeType");
            if (icon.get("sizes")) |sizes| {
                const size_values = switch (sizes) {
                    .array => |array| array,
                    else => return error.InvalidMcpResponse,
                };
                for (size_values.items) |size| if (size != .string) return error.InvalidMcpResponse;
            }
            if (optionalString(icon, "theme")) |theme| {
                if (!std.mem.eql(u8, theme, "light") and !std.mem.eql(u8, theme, "dark")) {
                    return error.InvalidMcpResponse;
                }
            } else if (icon.get("theme") != null) return error.InvalidMcpResponse;
        }
    }
    try validateOptionalMeta(object);
}

fn validateOptionalMeta(object: std.json.ObjectMap) !void {
    const meta_value = object.get("_meta") orelse return;
    const meta = try requiredObject(meta_value);
    try validateMetaKeys(meta, error.InvalidMcpResponse);
}

fn validateOptionalAnnotations(object: std.json.ObjectMap) !void {
    const value = object.get("annotations") orelse return;
    const annotations = try requiredObject(value);
    if (annotations.get("audience")) |audience_value| {
        const audience = switch (audience_value) {
            .array => |array| array,
            else => return error.InvalidMcpResponse,
        };
        for (audience.items) |role| try validateRole(role);
    }
    if (annotations.get("priority")) |priority| {
        const number = switch (priority) {
            .integer => |integer| @as(f64, @floatFromInt(integer)),
            .float => |float| float,
            else => return error.InvalidMcpResponse,
        };
        if (!std.math.isFinite(number) or number < 0 or number > 1) return error.InvalidMcpResponse;
    }
    try validateOptionalResponseString(annotations, "lastModified");
}

fn validateRole(value: std.json.Value) !void {
    const role = switch (value) {
        .string => |string| string,
        else => return error.InvalidMcpResponse,
    };
    if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) {
        return error.InvalidMcpResponse;
    }
}

fn validateOptionalResponseString(object: std.json.ObjectMap, name: []const u8) !void {
    if (object.get(name)) |value| if (value != .string) return error.InvalidMcpResponse;
}

fn validateOptionalResponseNumber(
    object: std.json.ObjectMap,
    name: []const u8,
    nonnegative: bool,
) !void {
    if (object.get(name)) |value| {
        const number = switch (value) {
            .integer => |integer| @as(f64, @floatFromInt(integer)),
            .float => |float| float,
            else => return error.InvalidMcpResponse,
        };
        if (!std.math.isFinite(number) or (nonnegative and number < 0)) return error.InvalidMcpResponse;
    }
}

fn responseArray(object: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return switch (object.get(name) orelse return error.InvalidMcpResponse) {
        .array => |array| array.items,
        else => error.InvalidMcpResponse,
    };
}

fn requireStringArray(
    object: std.json.ObjectMap,
    name: []const u8,
    minimum: usize,
    maximum: ?usize,
) !void {
    const values = switch (object.get(name) orelse return error.InvalidMcpResponse) {
        .array => |array| array,
        else => return error.InvalidMcpResponse,
    };
    if (values.items.len < minimum or if (maximum) |limit| values.items.len > limit else false) {
        return error.InvalidMcpResponse;
    }
    for (values.items) |value| if (value != .string) return error.InvalidMcpResponse;
}

fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidMcpResponse,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return optionalString(object, name) orelse error.InvalidMcpResponse;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn validateStandardHeaders(headers: []const http.Header, method: []const u8, params: std.json.ObjectMap) bool {
    const version = findHeader(headers, "mcp-protocol-version") orelse return false;
    if (!std.mem.eql(u8, version, protocol_version)) return false;
    const routed_method = findHeader(headers, "mcp-method") orelse return false;
    if (!std.mem.eql(u8, routed_method, method)) return false;
    const body_name = routingName(method, params);
    const header_name = findHeader(headers, "mcp-name");
    return if (body_name) |name| header_name != null and std.mem.eql(u8, header_name.?, name) else header_name == null;
}

fn routingName(method: []const u8, params: std.json.ObjectMap) ?[]const u8 {
    if (isTaskMethod(method)) {
        return optionalString(params, "taskId");
    }
    if (std.mem.eql(u8, method, methods.call_tool) or std.mem.eql(u8, method, methods.get_prompt)) {
        return optionalString(params, "name");
    }
    if (std.mem.eql(u8, method, methods.read_resource)) return optionalString(params, "uri");
    return null;
}

fn requestsTaskNotifications(method: []const u8, params: std.json.ObjectMap) bool {
    if (!std.mem.eql(u8, method, methods.listen)) return false;
    const notifications = switch (params.get("notifications") orelse return false) {
        .object => |object| object,
        else => return false,
    };
    return switch (notifications.get("taskIds") orelse return false) {
        .array => |array| array.items.len > 0,
        else => false,
    };
}

fn subscriptionContains(filter: std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const values = switch (filter.get(name) orelse return false) {
        .array => |array| array,
        else => return false,
    };
    for (values.items) |value| switch (value) {
        .string => |string| if (std.mem.eql(u8, string, expected)) return true,
        else => return false,
    };
    return false;
}

fn isTaskMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, tasks.methods.get) or
        std.mem.eql(u8, method, tasks.methods.update) or
        std.mem.eql(u8, method, tasks.methods.cancel);
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn uniqueHeader(headers: []const http.Header, name: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return error.DuplicateHttpHeader;
        found = header.value;
    }
    return found;
}

fn findHttpHeader(headers: []const http.Header, name: []const u8) ?http.Header {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header;
    return null;
}

fn copyTestScopes(allocator: std.mem.Allocator, source: []const []const u8) ![][]u8 {
    var result = try allocator.alloc([]u8, source.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |scope| allocator.free(scope);
    for (source, 0..) |scope, index| {
        result[index] = try allocator.dupe(u8, scope);
        initialized += 1;
    }
    return result;
}

fn validToolHeaderSchema(schema_value: std.json.Value) bool {
    const schema = requiredObject(schema_value) catch return false;
    const properties_value = schema.get("properties") orelse return true;
    const properties = requiredObject(properties_value) catch return false;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        if (!validHeaderAnnotation(annotation)) return false;
        const kind = optionalString(property, "type") orelse return false;
        if (!std.mem.eql(u8, kind, "string") and !std.mem.eql(u8, kind, "integer") and
            !std.mem.eql(u8, kind, "number") and !std.mem.eql(u8, kind, "boolean")) return false;
        var duplicates = properties.iterator();
        while (duplicates.next()) |other_entry| {
            if (std.mem.eql(u8, other_entry.key_ptr.*, entry.key_ptr.*)) continue;
            const other = requiredObject(other_entry.value_ptr.*) catch continue;
            const other_annotation = optionalString(other, "x-mcp-header") orelse continue;
            if (std.ascii.eqlIgnoreCase(other_annotation, annotation)) return false;
        }
    }
    return true;
}

fn validHeaderAnnotation(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e or byte == ':') return false;
    return true;
}

fn toolArgumentHeaders(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    arguments: std.json.Value,
) ![]const http.Header {
    const schema = try json_limits.parseLeaky(
        std.json.Value,
        allocator,
        schema_json,
        json_limits.defaults.schema,
        .{ .allocate = .alloc_always },
        error.InvalidMcpHeaderAnnotation,
    );
    if (!validToolHeaderSchema(schema)) return error.InvalidMcpHeaderAnnotation;
    const properties = switch ((try requiredObject(schema)).get("properties") orelse return &.{}) {
        .object => |value| value,
        else => return error.InvalidMcpHeaderAnnotation,
    };
    const values = try requiredObject(arguments);
    var headers: std.ArrayList(http.Header) = .empty;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        const value = values.get(entry.key_ptr.*) orelse continue;
        const raw = try primitiveHeaderValue(allocator, value);
        const encoded = try encodeHeaderValue(allocator, raw);
        try headers.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "Mcp-Param-{s}", .{annotation}),
            .value = encoded,
        });
    }
    return headers.toOwnedSlice(allocator);
}

fn primitiveHeaderValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        .integer => |integer| if (integer >= -9_007_199_254_740_991 and integer <= 9_007_199_254_740_991)
            std.fmt.allocPrint(allocator, "{d}", .{integer})
        else
            error.InvalidMcpToolArguments,
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .bool => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
        else => error.InvalidMcpToolArguments,
    };
}

fn encodeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var safe = value.len > 0 and value[0] != ' ' and value[value.len - 1] != ' ';
    if (std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=")) safe = false;
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) {
        safe = false;
        break;
    };
    if (safe) return value;
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{encoded});
}

fn validateToolHeaders(
    allocator: std.mem.Allocator,
    headers: []const http.Header,
    schema_json: []const u8,
    params: std.json.ObjectMap,
) !bool {
    const arguments = params.get("arguments") orelse std.json.Value{ .object = .{} };
    const expected = toolArgumentHeaders(allocator, schema_json, arguments) catch return false;
    for (expected) |header| {
        const actual = findHeader(headers, header.name) orelse return false;
        if (!std.mem.eql(u8, actual, header.value)) return false;
    }
    const schema = try parseResponse(allocator, schema_json);
    const properties = switch ((try requiredObject(schema)).get("properties") orelse return true) {
        .object => |value| value,
        else => return false,
    };
    const values = try requiredObject(arguments);
    var iterator = properties.iterator();
    while (iterator.next()) |entry| {
        const property = requiredObject(entry.value_ptr.*) catch continue;
        const annotation = optionalString(property, "x-mcp-header") orelse continue;
        if (values.get(entry.key_ptr.*) == null) {
            const name = try std.fmt.allocPrint(allocator, "Mcp-Param-{s}", .{annotation});
            if (findHeader(headers, name) != null) return false;
        }
    }
    return true;
}

fn renderToolResult(allocator: std.mem.Allocator, result: std.json.ObjectMap) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (result.get("isError")) |is_error| {
        if (is_error == .bool and is_error.bool) try output.writer.writeAll("MCP tool error: ");
    }
    var wrote_content = false;
    if (result.get("content")) |content| switch (content) {
        .array => |items| for (items.items) |item| {
            if (wrote_content) try output.writer.writeAll("\n");
            const object = requiredObject(item) catch {
                try writeJsonValue(&output.writer, item);
                wrote_content = true;
                continue;
            };
            if (optionalString(object, "text")) |text| {
                try output.writer.writeAll(text);
            } else {
                try writeJsonValue(&output.writer, item);
            }
            wrote_content = true;
        },
        else => return error.InvalidMcpResponse,
    };
    if (!wrote_content) if (result.get("structuredContent")) |structured| {
        try writeJsonValue(&output.writer, structured);
    };
    return output.toOwnedSlice();
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}

fn testValidateMethodResult(method: []const u8, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    return validateMethodResult(method, parsed.value);
}

test "method result validation covers every core result family" {
    const valid = [_]struct { []const u8, []const u8 }{
        .{ "extension/custom", "{}" },
        .{ methods.discover, "{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"resultType\":\"complete\",\"tools\":[],\"ttlMs\":1.5,\"cacheScope\":\"private\",\"nextCursor\":\"next\"}" },
        .{ methods.list_prompts, "{\"prompts\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"resources\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"resourceTemplates\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{\"messages\":[]}" },
        .{ methods.call_tool, "{\"content\":[]}" },
        .{ methods.complete, "{\"completion\":{\"values\":[\"one\"]}}" },
        .{ methods.listen, "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"listen-1\"}}" },
        .{ methods.call_tool, "{\"resultType\":\"task\",\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}" },
        .{ tasks.methods.get, "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"result\":{\"content\":[]}}" },
        .{ tasks.methods.update, "{\"resultType\":\"complete\"}" },
        .{ tasks.methods.cancel, "{\"resultType\":\"complete\"}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"requestState\":\"state\"}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Open\",\"url\":\"https://example.test\"}},\"b\":{\"method\":\"roots/list\"},\"c\":{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1}}}}" },
    };
    for (valid) |case| try testValidateMethodResult(case[0], case[1]);
}

test "method result validation rejects every structural boundary" {
    const invalid = [_]struct { []const u8, []const u8 }{
        .{ "extension/custom", "[]" },
        .{ "extension/custom", "{\"resultType\":1}" },
        .{ "extension/custom", "{\"resultType\":\"other\"}" },
        .{ methods.discover, "{\"supportedVersions\":[],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.discover, "{\"supportedVersions\":[1],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.discover, "{\"supportedVersions\":[\"v\"],\"capabilities\":[],\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"tools\":{},\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{}" },
        .{ methods.call_tool, "{}" },
        .{ methods.complete, "{}" },
        .{ methods.complete, "{\"completion\":{\"values\":[1]}}" },
        .{ methods.listen, "{}" },
        .{ methods.listen, "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":true}}" },
        .{ tasks.methods.get, "{\"resultType\":\"task\",\"taskId\":\"a\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}" },
        .{ methods.call_tool, "{\"resultType\":\"task\"}" },
        .{ tasks.methods.get, "{\"resultType\":\"complete\",\"taskId\":\"a\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":0}" },
        .{ methods.list_tools, "{\"tools\":[],\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":\"0\",\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":-1,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":-0.5,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"shared\"}" },
        .{ methods.list_tools, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\",\"nextCursor\":1}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\"}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"requestState\":1}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":[]}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":[]}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{}}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"unknown/input\"}}}" },
        .{ methods.call_tool, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"elicitation/create\",\"params\":[]}}}" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.InvalidMcpResponse, testValidateMethodResult(case[0], case[1]));
    }

    var values: std.json.Array = .init(std.testing.allocator);
    defer values.deinit();
    for (0..101) |_| try values.append(.{ .string = "value" });
    var completion: std.json.ObjectMap = .{};
    defer completion.deinit(std.testing.allocator);
    try completion.put(std.testing.allocator, "values", .{ .array = values });
    var result: std.json.ObjectMap = .{};
    defer result.deinit(std.testing.allocator);
    try result.put(std.testing.allocator, "completion", .{ .object = completion });
    try std.testing.expectError(error.InvalidMcpResponse, validateMethodResult(methods.complete, .{ .object = result }));
}

test "nested MCP result content matches every core schema family" {
    const valid = [_]struct { []const u8, []const u8 }{
        .{ methods.discover, "{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"instructions\":\"Use it\",\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"weather\",\"title\":\"Weather\",\"description\":\"Forecast\",\"icons\":[{\"src\":\"https://example.test/icon.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"light\"}],\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{},\"annotations\":{\"title\":\"Weather\",\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"prompts\":[{\"name\":\"review\",\"description\":\"Review\",\"arguments\":[{\"name\":\"code\",\"title\":\"Code\",\"description\":\"Source\",\"required\":true}]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"resources\":[{\"name\":\"source\",\"uri\":\"file:///a\",\"mimeType\":\"text/plain\",\"size\":1,\"annotations\":{\"audience\":[\"user\",\"assistant\"],\"priority\":0.5,\"lastModified\":\"2026-01-01T00:00:00Z\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"resourceTemplates\":[{\"name\":\"source\",\"uriTemplate\":\"file:///{path}\",\"description\":\"Source\",\"mimeType\":\"text/plain\"}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[{\"uri\":\"file:///a\",\"text\":\"hello\"},{\"uri\":\"file:///b\",\"mimeType\":\"image/png\",\"blob\":\"AA==\"}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{\"description\":\"Prompt\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/png\"}},{\"role\":\"user\",\"content\":{\"type\":\"audio\",\"data\":\"AA==\",\"mimeType\":\"audio/wav\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"resource_link\",\"name\":\"source\",\"uri\":\"file:///a\"}},{\"role\":\"user\",\"content\":{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///a\",\"text\":\"source\"}}}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"done\",\"annotations\":{\"priority\":1},\"_meta\":{\"com.example/source\":true}}],\"isError\":false,\"structuredContent\":{\"ok\":true}}" },
        .{ methods.complete, "{\"completion\":{\"values\":[\"zig\"],\"total\":1.5,\"hasMore\":true}}" },
    };
    for (valid) |case| try testValidateMethodResult(case[0], case[1]);
}

test "nested MCP result content rejects malformed items" {
    const invalid = [_]struct { []const u8, []const u8 }{
        .{ methods.discover, "{\"supportedVersions\":[\"v\"],\"capabilities\":{},\"instructions\":1,\"ttlMs\":0,\"cacheScope\":\"public\"}" },
        .{ methods.list_tools, "{\"tools\":[[]],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"description\":1,\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"inputSchema\":[]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"inputSchema\":{\"type\":\"string\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":[]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":[]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"readOnlyHint\":1}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":{},\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[[]],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[{}],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[{\"src\":\"x\",\"sizes\":{}}],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[{\"src\":\"x\",\"sizes\":[1]}],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[{\"src\":\"x\",\"theme\":\"color\"}],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_tools, "{\"tools\":[{\"name\":\"x\",\"icons\":[{\"src\":\"x\",\"theme\":1}],\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"prompts\":[{\"name\":\"x\",\"arguments\":{}}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"prompts\":[{\"name\":\"x\",\"arguments\":[[]]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_prompts, "{\"prompts\":[{\"name\":\"x\",\"arguments\":[{\"name\":\"a\",\"required\":1}]}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"resources\":[{\"name\":\"x\"}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resources, "{\"resources\":[{\"name\":\"x\",\"uri\":\"x\",\"size\":-1}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.list_resource_templates, "{\"resourceTemplates\":[{\"name\":\"x\"}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[[]],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[{\"uri\":\"x\"}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[{\"uri\":\"x\",\"text\":1}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.read_resource, "{\"contents\":[{\"uri\":\"x\",\"blob\":1}],\"ttlMs\":0,\"cacheScope\":\"private\"}" },
        .{ methods.get_prompt, "{\"description\":1,\"messages\":[]}" },
        .{ methods.get_prompt, "{\"messages\":[[]]}" },
        .{ methods.get_prompt, "{\"messages\":[{\"role\":\"system\",\"content\":{\"type\":\"text\",\"text\":\"x\"}}]}" },
        .{ methods.get_prompt, "{\"messages\":[{\"role\":1,\"content\":{\"type\":\"text\",\"text\":\"x\"}}]}" },
        .{ methods.call_tool, "{\"content\":[[]]}" },
        .{ methods.call_tool, "{\"content\":[{}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"future\"}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\"}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"image\",\"data\":\"x\"}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"resource_link\",\"uri\":\"x\"}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"resource\"}]}" },
        .{ methods.call_tool, "{\"content\":[],\"isError\":1}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"annotations\":[]}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"annotations\":{\"audience\":{}}}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"annotations\":{\"audience\":[\"system\"]}}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"annotations\":{\"priority\":2}}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"annotations\":{\"priority\":true}}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"_meta\":[]}]}" },
        .{ methods.call_tool, "{\"content\":[{\"type\":\"text\",\"text\":\"x\",\"_meta\":{\"bad key\":true}}]}" },
        .{ methods.complete, "{\"completion\":{\"values\":[],\"total\":true}}" },
        .{ methods.complete, "{\"completion\":{\"values\":[],\"hasMore\":1}}" },
    };
    for (invalid) |case| try std.testing.expectError(
        error.InvalidMcpResponse,
        testValidateMethodResult(case[0], case[1]),
    );
}

test "MRTR input requests and callback responses cover all three methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const valid_requests = [_][]const u8{
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Details\",\"requestedSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"email\":{\"type\":\"string\",\"title\":\"Email\",\"description\":\"Address\",\"format\":\"email\",\"minLength\":1,\"maxLength\":100,\"default\":\"a@example.test\",\"enum\":[\"a@example.test\"],\"enumNames\":[\"Primary\"]},\"choice\":{\"type\":\"string\",\"oneOf\":[{\"const\":\"a\",\"title\":\"A\"}]},\"count\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":10,\"default\":1},\"ratio\":{\"type\":\"number\"},\"enabled\":{\"type\":\"boolean\",\"default\":true},\"tags\":{\"type\":\"array\",\"minItems\":0,\"maxItems\":2,\"items\":{\"type\":\"string\",\"enum\":[\"a\"]},\"default\":[\"a\"]},\"titledTags\":{\"type\":\"array\",\"items\":{\"anyOf\":[{\"const\":\"a\",\"title\":\"A\"}]}}},\"required\":[\"email\"]}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Sign in\",\"url\":\"https://example.test/login\"}}",
        "{\"method\":\"roots/list\",\"params\":{}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}},{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/png\"},{\"type\":\"audio\",\"data\":\"AA==\",\"mimeType\":\"audio/wav\"},{\"type\":\"tool_use\",\"id\":\"one\",\"name\":\"weather\",\"input\":{}},{\"type\":\"tool_result\",\"toolUseId\":\"one\",\"content\":[{\"type\":\"text\",\"text\":\"sunny\"}],\"isError\":false}]}],\"modelPreferences\":{\"hints\":[{\"name\":\"small\"}],\"costPriority\":0,\"speedPriority\":0.5,\"intelligencePriority\":1},\"systemPrompt\":\"Help\",\"includeContext\":\"none\",\"temperature\":0.5,\"maxTokens\":100,\"stopSequences\":[\"stop\"],\"metadata\":{},\"tools\":[{\"name\":\"weather\",\"inputSchema\":{\"type\":\"object\"}}],\"toolChoice\":{\"mode\":\"auto\"}}}",
    };
    for (valid_requests) |source| try validateInputRequest(try requiredObject(
        try parseResponse(arena.allocator(), source),
    ));

    const valid_responses = [_]struct { method: []const u8, source: []const u8 }{
        .{ .method = methods.elicit, .source = "{\"action\":\"accept\",\"content\":{\"name\":\"Zig\",\"age\":1,\"ratio\":1.5,\"ok\":true,\"tags\":[\"a\"]}}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"decline\"}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"cancel\"}" },
        .{ .method = methods.list_roots, .source = "{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"workspace\"}]}" },
        .{ .method = methods.create_message, .source = "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"hello\"},\"model\":\"model\",\"stopReason\":\"endTurn\"}" },
    };
    for (valid_responses) |case| try validateInputResponse(
        case.method,
        try parseResponse(arena.allocator(), case.source),
    );
}

test "MRTR rejects malformed request and callback response boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invalid_requests = [_][]const u8{
        "{}",
        "{\"method\":\"future/input\"}",
        "{\"method\":\"elicitation/create\",\"params\":{}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"other\",\"message\":\"x\"}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"x\"}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"x\",\"url\":\"x\",\"requestedSchema\":{}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"url\":\"x\",\"requestedSchema\":{}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":[]}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"array\",\"properties\":{}}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\"}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"x\":[]}}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"future\"}}}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"array\",\"items\":{\"enum\":[\"a\"]}}}}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"array\",\"items\":{}}}}}}",
        "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"x\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{},\"required\":{}}}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":{},\"maxTokens\":1}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[{}],\"maxTokens\":1}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":true}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"includeContext\":\"future\"}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"metadata\":[]}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"tools\":{}}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"toolChoice\":[]}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"toolChoice\":{\"mode\":\"future\"}}}",
        "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":1,\"modelPreferences\":{\"costPriority\":2}}}",
    };
    for (invalid_requests) |source| try std.testing.expectError(
        error.InvalidMcpResponse,
        validateInputRequest(try requiredObject(try parseResponse(arena.allocator(), source))),
    );

    const invalid_responses = [_]struct { method: []const u8, source: []const u8 }{
        .{ .method = "future/input", .source = "{}" },
        .{ .method = methods.elicit, .source = "[]" },
        .{ .method = methods.elicit, .source = "{}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"future\"}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"decline\",\"content\":{}}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"accept\",\"content\":[]}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"accept\",\"content\":{\"x\":{}}}" },
        .{ .method = methods.elicit, .source = "{\"action\":\"accept\",\"content\":{\"x\":[1]}}" },
        .{ .method = methods.list_roots, .source = "{}" },
        .{ .method = methods.list_roots, .source = "{\"roots\":[[]]}" },
        .{ .method = methods.list_roots, .source = "{\"roots\":[{}]}" },
        .{ .method = methods.list_roots, .source = "{\"roots\":[{\"uri\":\"https://example.test\"}]}" },
        .{ .method = methods.list_roots, .source = "{\"roots\":[{\"uri\":\"file:///a\",\"name\":1}]}" },
        .{ .method = methods.create_message, .source = "{}" },
        .{ .method = methods.create_message, .source = "{\"role\":\"assistant\",\"content\":{\"type\":\"tool_use\"},\"model\":\"x\"}" },
        .{ .method = methods.create_message, .source = "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"x\"}}" },
        .{ .method = methods.create_message, .source = "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"x\"},\"model\":\"x\",\"stopReason\":1}" },
    };
    for (invalid_responses) |case| try std.testing.expectError(
        error.InvalidMcpResponse,
        validateInputResponse(case.method, try parseResponse(arena.allocator(), case.source)),
    );
}

test "JSON-RPC response and MCP error envelopes are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try responseResult(
        try parseResponse(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"),
        1,
    );
    try std.testing.expect(result == .object);
    const valid_errors = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"missing\",\"data\":null}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32020,\"message\":\"headers\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"capability\",\"data\":{\"requiredCapabilities\":{\"elicitation\":{}}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32003,\"message\":\"capability\",\"data\":{\"requiredCapabilities\":{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}}}}",
    };
    for (valid_errors) |source| try std.testing.expectError(
        error.McpRpcError,
        responseResult(try parseResponse(arena.allocator(), source), 1),
    );
    try std.testing.expectError(
        error.UnsupportedMcpProtocolVersion,
        responseResult(
            try parseResponse(
                arena.allocator(),
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022," ++
                    "\"message\":\"version\",\"data\":{\"supported\":[\"2026-07-28\"]," ++
                    "\"requested\":\"old\"}}}",
            ),
            1,
        ),
    );

    const invalid = [_][]const u8{
        "[]",
        "{\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"both\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"missing code\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1.5,\"message\":\"float code\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"version\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"version\",\"data\":[]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"version\",\"data\":{\"supported\":[],\"requested\":\"old\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"version\",\"data\":{\"supported\":[1],\"requested\":\"old\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"version\",\"data\":{\"supported\":[\"v\"]}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"capability\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"capability\",\"data\":[]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"capability\",\"data\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"capability\",\"data\":{\"requiredCapabilities\":[]}}}",
    };
    for (invalid) |source| try std.testing.expectError(
        error.InvalidMcpResponse,
        responseResult(try parseResponse(arena.allocator(), source), 1),
    );
    try std.testing.expectError(
        error.McpResponseIdMismatch,
        responseResult(
            try parseResponse(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}"),
            1,
        ),
    );
}

test "HTTP response statuses match MCP result and reserved error envelopes" {
    const success = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    try validateHttpResponseStatus(std.testing.allocator, 200, success);
    try std.testing.expectError(
        error.InvalidMcpResponse,
        validateHttpResponseStatus(std.testing.allocator, 400, success),
    );
    const generic_error = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad\"}}";
    try validateHttpResponseStatus(std.testing.allocator, 200, generic_error);
    const reserved = [_]i32{
        error_codes.header_mismatch,
        error_codes.missing_required_client_capability,
        tasks.error_codes.missing_required_client_capability,
        error_codes.unsupported_protocol_version,
    };
    for (reserved) |code| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{{\"code\":{d},\"message\":\"bad\"}}}}",
            .{code},
        );
        defer std.testing.allocator.free(source);
        try validateHttpResponseStatus(std.testing.allocator, 400, source);
        try std.testing.expectError(
            error.InvalidMcpResponse,
            validateHttpResponseStatus(std.testing.allocator, 200, source),
        );
    }
    const malformed = [_][]const u8{
        "[]",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1.5}}",
    };
    for (malformed) |source| try std.testing.expectError(
        error.InvalidMcpResponse,
        validateHttpResponseStatus(std.testing.allocator, 200, source),
    );
}

test "compatibility classifiers preserve allocation failures" {
    const Check = struct {
        fn stdio(allocator: std.mem.Allocator) !void {
            _ = try classifyStdioCompatibility(
                allocator,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}}",
            );
        }
        fn http(allocator: std.mem.Allocator) !void {
            _ = try classifyHttpCompatibility(
                allocator,
                200,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
            );
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.stdio, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.http, .{});
}

test "capability validation preserves open fields and checks known shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const valid_client = try parseResponse(
        arena.allocator(),
        "{\"experimental\":{\"preview\":{}},\"roots\":{}," ++
            "\"sampling\":{\"context\":{},\"tools\":{},\"future\":true}," ++
            "\"elicitation\":{\"form\":{},\"url\":{}}," ++
            "\"extensions\":{\"io.modelcontextprotocol/oauth-client-credentials\":{}," ++
            "\"com.example/my-name_1.x\":{}},\"futureCapability\":42}",
    );
    try validateClientCapabilities(valid_client, error.InvalidMcpMessage);
    const valid_server = try parseResponse(
        arena.allocator(),
        "{\"experimental\":{\"preview\":{}},\"logging\":{},\"completions\":{}," ++
            "\"prompts\":{\"listChanged\":true}," ++
            "\"resources\":{\"subscribe\":false,\"listChanged\":true}," ++
            "\"tools\":{\"listChanged\":false,\"future\":1}," ++
            "\"extensions\":{\"a/\":{},\"a-b.c9/feature\":{}},\"futureCapability\":[]}",
    );
    try validateServerCapabilities(valid_server, error.InvalidMcpResponse);

    const invalid_clients = [_][]const u8{
        "[]",
        "{\"experimental\":[]}",
        "{\"experimental\":{\"preview\":true}}",
        "{\"roots\":true}",
        "{\"sampling\":[]}",
        "{\"sampling\":{\"context\":true}}",
        "{\"sampling\":{\"tools\":true}}",
        "{\"elicitation\":[]}",
        "{\"elicitation\":{\"form\":true}}",
        "{\"elicitation\":{\"url\":true}}",
        "{\"extensions\":[]}",
        "{\"extensions\":{\"com.example/feature\":true}}",
    };
    for (invalid_clients) |source| {
        try std.testing.expectError(
            error.InvalidMcpMessage,
            validateClientCapabilities(try parseResponse(arena.allocator(), source), error.InvalidMcpMessage),
        );
    }

    const invalid_servers = [_][]const u8{
        "[]",
        "{\"experimental\":{\"preview\":true}}",
        "{\"logging\":true}",
        "{\"completions\":true}",
        "{\"prompts\":[]}",
        "{\"prompts\":{\"listChanged\":1}}",
        "{\"resources\":[]}",
        "{\"resources\":{\"subscribe\":1}}",
        "{\"resources\":{\"listChanged\":1}}",
        "{\"tools\":[]}",
        "{\"tools\":{\"listChanged\":1}}",
    };
    for (invalid_servers) |source| {
        try std.testing.expectError(
            error.InvalidMcpResponse,
            validateServerCapabilities(try parseResponse(arena.allocator(), source), error.InvalidMcpResponse),
        );
    }
}

test "unknown MCP extensions and settings remain lossless" {
    const capabilities =
        "{\"futureCapability\":{\"enabled\":true},\"extensions\":{" ++
        "\"com.example/future\":{\"modes\":[\"one\",2],\"nested\":{\"flag\":true}}}}";
    const settings = (try extensionSettings(
        std.testing.allocator,
        capabilities,
        "com.example/future",
    )).?;
    defer std.testing.allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"modes\":[\"one\",2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"flag\":true") != null);
    try std.testing.expect((try extensionSettings(
        std.testing.allocator,
        capabilities,
        "com.example/missing",
    )) == null);
    try std.testing.expect((try extensionSettings(
        std.testing.allocator,
        "{}",
        "com.example/missing",
    )) == null);
    try std.testing.expectError(
        error.InvalidMcpMessage,
        extensionSettings(std.testing.allocator, capabilities, "unprefixed"),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        extensionSettings(std.testing.allocator, "[]", "com.example/future"),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        extensionSettings(
            std.testing.allocator,
            "{\"extensions\":{\"com.example/future\":true}}",
            "com.example/future",
        ),
    );

    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.message, "\"com.example/future\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "\"clientUnknown\":42") != null);
            if (std.mem.eql(u8, request.method, methods.discover)) return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"," ++
                    "\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{" ++
                    "\"serverUnknown\":{\"value\":42},\"extensions\":{" ++
                    "\"com.example/future\":{\"serverSetting\":[1,true]}}}," ++
                    "\"ttlMs\":0,\"cacheScope\":\"public\",\"futureResult\":{\"kept\":true}}}",
            );
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\"," ++
                    "\"futurePayload\":{\"nested\":[1,\"two\",true]}}}",
            );
        }
    };
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"clientUnknown\":42,\"extensions\":{\"com.example/future\":{\"clientSetting\":true}}}",
    };
    const discovered = try client.discover(std.testing.allocator);
    defer std.testing.allocator.free(discovered);
    try std.testing.expect(std.mem.indexOf(u8, discovered, "\"serverUnknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered, "\"serverSetting\":[1,true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered, "\"futureResult\"") != null);
    const extension = try client.request(
        std.testing.allocator,
        "com.example/futureMethod",
        "{\"futureParam\":{\"kept\":true}}",
    );
    defer std.testing.allocator.free(extension);
    try std.testing.expect(std.mem.indexOf(u8, extension, "\"nested\":[1,\"two\",true]") != null);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "extension capability identifiers follow prefixed metadata syntax" {
    const valid = [_][]const u8{
        "a/",
        "a/x",
        "com.example/feature",
        "a-b.c9/my-name_1.x",
    };
    for (valid) |key| try std.testing.expect(validPrefixedMetaKey(key));
    const invalid = [_][]const u8{
        "feature",
        "/feature",
        "com.example/feature/extra",
        ".example/feature",
        "9example/feature",
        "example-/feature",
        "exam_ple/feature",
        "example/-feature",
        "example/feature_",
        "example/feat@ure",
    };
    for (invalid) |key| try std.testing.expect(!validPrefixedMetaKey(key));

    const valid_unprefixed = [_][]const u8{ "", "progressToken", "name.with_parts-1" };
    for (valid_unprefixed) |key| try std.testing.expect(validMetaKey(key, false));
    try std.testing.expect(!validMetaKey("bad name", false));
}

test "request result and notification metadata follow common MCP rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const valid_meta = try requiredObject(try parseResponse(
        arena.allocator(),
        "{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
            "\"io.modelcontextprotocol/clientCapabilities\":{},\"progressToken\":\"p\"," ++
            "\"io.modelcontextprotocol/logLevel\":\"info\"," ++
            "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"client\",\"version\":\"1\"," ++
            "\"title\":\"Client\",\"description\":\"Test\",\"websiteUrl\":\"https://example.test\"," ++
            "\"icons\":[{\"src\":\"https://example.test/icon.png\",\"mimeType\":\"image/png\"," ++
            "\"sizes\":[\"48x48\"],\"theme\":\"dark\"}]},\"com.example/custom\":true}",
    ));
    try validateRequestMeta(valid_meta, error.InvalidMcpMessage);
    const invalid_meta = [_][]const u8{
        "{}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"\",\"io.modelcontextprotocol/clientCapabilities\":{}}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":[]}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"bad key\":1}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"progressToken\":true}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/logLevel\":\"verbose\"}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"x\"}}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"x\",\"version\":\"1\",\"icons\":{}}}",
        "{\"io.modelcontextprotocol/protocolVersion\":\"v\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"x\",\"version\":\"1\",\"icons\":[{\"src\":\"x\",\"theme\":\"color\"}]}}",
    };
    for (invalid_meta) |source| try std.testing.expectError(
        error.InvalidMcpMessage,
        validateRequestMeta(
            try requiredObject(try parseResponse(arena.allocator(), source)),
            error.InvalidMcpMessage,
        ),
    );

    try std.testing.expectError(
        error.InvalidMcpResponse,
        testValidateMethodResult(
            "extension/custom",
            "{\"_meta\":{\"bad key\":true}}",
        ),
    );
    try std.testing.expectError(
        error.InvalidMcpResponse,
        testValidateMethodResult(
            "extension/custom",
            "{\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"server\"}}}",
        ),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        validateNotificationMethodParams(
            methods.tool_list_changed,
            try requiredObject(try parseResponse(arena.allocator(), "{\"_meta\":{\"bad key\":1}}")),
            error.InvalidMcpMessage,
        ),
    );
}

test "typed request options encode progress and logging metadata" {
    const source = try buildRequestWithMetadata(
        std.testing.allocator,
        1,
        "extension/work",
        "{}",
        "client",
        "1",
        "{}",
        .{
            .progress_token = .{ .string = "progress-1" },
            .log_level = .warning,
        },
    );
    defer std.testing.allocator.free(source);
    var parsed = try json_limits.parse(
        std.json.Value,
        std.testing.allocator,
        source,
        json_limits.defaults.mcp_message,
        .{},
        error.InvalidMcpMessage,
    );
    defer parsed.deinit();
    const root = try requiredObject(parsed.value);
    const params = try requiredObject(root.get("params").?);
    const meta = try requiredObject(params.get("_meta").?);
    try std.testing.expectEqualStrings("progress-1", try requiredString(meta, "progressToken"));
    try std.testing.expectEqualStrings(
        "warning",
        try requiredString(meta, "io.modelcontextprotocol/logLevel"),
    );
}

test "server rejects invalid JSON-RPC request identifiers" {
    const Handler = struct {
        fn handle(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 { // kcov-ignore: rejection must bypass this fixture
            return allocator.dupe(u8, "{}"); // kcov-ignore: rejection must bypass this fixture
        }
    };
    var unused: u8 = 0;
    var server = Server{ .handler = .{ .context = &unused, .handleFn = Handler.handle } };
    const response = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"server/discover\",\"params\":{}}",
        null,
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "Invalid request ID") != null);
}

test "server enforces TLS Origin Host and bearer audience before dispatch" {
    const State = struct {
        handler_calls: usize = 0,
        authorization_calls: usize = 0,

        fn handle(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            method: []const u8,
            _: []const u8,
        ) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.handler_calls += 1;
            try std.testing.expectEqualStrings("extension/secure", method);
            return allocator.dupe(u8, "{}");
        }

        fn authorize(context: *anyopaque, request: auth.ValidationRequest) !auth.Decision {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.authorization_calls += 1;
            try std.testing.expectEqualStrings("https://mcp.example.com/mcp", request.resource);
            try std.testing.expectEqualStrings("extension/secure", request.method);
            try std.testing.expect(std.mem.indexOf(u8, request.params_json, request.token) == null);
            if (std.mem.eql(u8, request.token, "expired")) {
                return .{ .unauthorized = .{ .description = "must not expose expired" } };
            }
            if (std.mem.eql(u8, request.token, "limited")) {
                return .{ .insufficient_scope = .{
                    .required_scopes = &.{ "tools:read", "tools:call" },
                    .description = "must not expose limited",
                } };
            }
            return .authorized;
        }
    };
    var state: State = .{};
    var server = Server{
        .handler = .{ .context = &state, .handleFn = State.handle },
        .deployment = .{
            .allowed_origins = &.{"https://app.example.com"},
            .expected_host = "mcp.example.com",
        },
        .authorization = .{
            .resource = "https://mcp.example.com/mcp",
            .resource_metadata_url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
            .authorizer = .{ .context = &state, .authorizeFn = State.authorize },
            .scopes = &.{"tools:read"},
        },
    };
    const request = try buildRequest(
        std.testing.allocator,
        1,
        "extension/secure",
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(request);

    const base_headers = [_]http.Header{
        .{ .name = "mcp-protocol-version", .value = protocol_version },
        .{ .name = "mcp-method", .value = "extension/secure" },
        .{ .name = "host", .value = "mcp.example.com" },
        .{ .name = "origin", .value = "https://app.example.com" },
    };
    const missing = try server.handle(std.testing.allocator, request, .{ .headers = &base_headers });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 401), missing.status);
    try std.testing.expectEqual(@as(usize, 1), missing.headers.len);
    try std.testing.expect(std.mem.indexOf(u8, missing.headers[0].value, "resource_metadata=") != null);
    try std.testing.expectEqual(@as(usize, 0), state.authorization_calls);

    const expired_headers = base_headers ++ [_]http.Header{.{ .name = "authorization", .value = "Bearer expired" }};
    const expired = try server.handle(std.testing.allocator, request, .{ .headers = &expired_headers });
    defer expired.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 401), expired.status);
    try std.testing.expect(std.mem.indexOf(u8, expired.headers[0].value, "expired") == null);

    const limited_headers = base_headers ++ [_]http.Header{.{ .name = "authorization", .value = "Bearer limited" }};
    const limited = try server.handle(std.testing.allocator, request, .{ .headers = &limited_headers });
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), limited.status);
    try std.testing.expect(std.mem.indexOf(u8, limited.headers[0].value, "insufficient_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, limited.headers[0].value, "tools:read tools:call") != null);
    try std.testing.expect(std.mem.indexOf(u8, limited.headers[0].value, "limited") == null);

    const valid_headers = base_headers ++ [_]http.Header{.{ .name = "authorization", .value = "Bearer valid" }};
    const accepted = try server.handle(std.testing.allocator, request, .{ .headers = &valid_headers });
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), accepted.status);
    try std.testing.expectEqual(@as(usize, 1), state.handler_calls);
    try std.testing.expectEqual(@as(usize, 3), state.authorization_calls);

    const bad_origin_headers = [_]http.Header{
        .{ .name = "origin", .value = "https://evil.example.com" },
        .{ .name = "host", .value = "mcp.example.com" },
    };
    const bad_origin = try server.handle(std.testing.allocator, request, .{ .headers = &bad_origin_headers });
    defer bad_origin.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), bad_origin.status);
    const cleartext = try server.handle(std.testing.allocator, request, .{
        .headers = &base_headers,
        .is_tls = false,
    });
    defer cleartext.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), cleartext.status);

    const no_http_metadata = try server.handle(std.testing.allocator, request, null);
    defer no_http_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), no_http_metadata.status);
    const wrong_host_headers = [_]http.Header{
        .{ .name = "host", .value = "other.example.com" },
    };
    const wrong_host = try server.handle(std.testing.allocator, request, .{ .headers = &wrong_host_headers });
    defer wrong_host.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), wrong_host.status);
    const duplicate_origin_headers = [_]http.Header{
        .{ .name = "origin", .value = "https://app.example.com" },
        .{ .name = "Origin", .value = "https://app.example.com" },
    };
    const duplicate_origin = try server.handle(std.testing.allocator, request, .{
        .headers = &duplicate_origin_headers,
    });
    defer duplicate_origin.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), duplicate_origin.status);

    const bad_scheme_headers = base_headers ++ [_]http.Header{.{ .name = "authorization", .value = "Basic token" }};
    const bad_scheme = try server.handle(std.testing.allocator, request, .{ .headers = &bad_scheme_headers });
    defer bad_scheme.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 401), bad_scheme.status);
    const duplicate_auth_headers = valid_headers ++ [_]http.Header{.{ .name = "Authorization", .value = "Bearer valid" }};
    const duplicate_auth = try server.handle(std.testing.allocator, request, .{ .headers = &duplicate_auth_headers });
    defer duplicate_auth.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 401), duplicate_auth.status);
    try std.testing.expectEqual(@as(usize, 3), state.authorization_calls);
}

test "MCP HTTP authorization releases every partial allocation" {
    const CheckServer = struct {
        fn handle(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            return allocator.dupe(u8, "{}");
        }
        fn authorize(_: *anyopaque, _: auth.ValidationRequest) !auth.Decision {
            return .authorized;
        }
        fn run(allocator: std.mem.Allocator) !void {
            var unused: u8 = 0;
            var server = Server{
                .handler = .{ .context = &unused, .handleFn = handle },
                .authorization = .{
                    .resource = "https://mcp.example.com/mcp",
                    .resource_metadata_url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                    .authorizer = .{ .context = &unused, .authorizeFn = authorize },
                    .scopes = &.{"tools:read"},
                },
            };
            const request = try buildRequest(
                allocator,
                1,
                "extension/check",
                "{}",
                "client",
                "1",
                "{}",
            );
            defer allocator.free(request);
            const response = try server.handle(allocator, request, .{ .headers = &.{} });
            defer response.deinit(allocator);
            try std.testing.expectEqual(@as(u16, 401), response.status);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, CheckServer.run, .{});

    var accepted_context: u8 = 0;
    var server = Server{
        .handler = .{ .context = &accepted_context, .handleFn = CheckServer.handle },
        .authorization = .{
            .resource = "https://mcp.example.com/mcp",
            .resource_metadata_url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
            .authorizer = .{ .context = &accepted_context, .authorizeFn = CheckServer.authorize },
            .scopes = &.{"tools:read"},
        },
    };
    const authorized_request = try buildRequest(
        std.testing.allocator,
        1,
        "extension/check",
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(authorized_request);
    const headers = [_]http.Header{
        .{ .name = "mcp-protocol-version", .value = protocol_version },
        .{ .name = "mcp-method", .value = "extension/check" },
        .{ .name = "authorization", .value = "Bearer token" },
    };
    const accepted = try server.handle(std.testing.allocator, authorized_request, .{ .headers = &headers });
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), accepted.status);

    const CheckScopes = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const scopes = try copyTestScopes(allocator, &.{ "profile", "tools:read" });
            defer auth.deinitScopes(allocator, scopes);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, CheckScopes.run, .{});

    const CheckClient = struct {
        fn token(_: *anyopaque, allocator: std.mem.Allocator, request: auth.TokenRequest) !auth.AccessToken {
            return auth.AccessToken.initAlloc(allocator, "token", request.authorization_server, &.{});
        }
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try std.testing.expectEqualStrings("Bearer token", findHeader(request.headers, "authorization").?);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"),
            };
        }
        fn run(allocator: std.mem.Allocator) !void {
            var unused: u8 = 0;
            var streamable = StreamableHttpTransport.initWithOptions(
                std.testing.io,
                .{ .context = &unused, .sendFn = send },
                "https://mcp.example.com/mcp",
                .{ .authorization = .{
                    .resource = "https://mcp.example.com/mcp",
                    .authorization_server = "https://auth.example.com",
                    .tokens = .{ .context = &unused, .getFn = token },
                } },
            );
            const request = try buildRequest(
                allocator,
                1,
                "extension/check",
                "{}",
                "client",
                "1",
                "{}",
            );
            defer allocator.free(request);
            const response = try streamable.transport().send(allocator, .{
                .message = request,
                .method = "extension/check",
            });
            allocator.free(response);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, CheckClient.run, .{});
}

test "core request params cover every standardized method shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const valid = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = methods.discover, .params = "{}" },
        .{ .method = methods.list_tools, .params = "{\"cursor\":\"next\"}" },
        .{ .method = methods.list_prompts, .params = "{}" },
        .{ .method = methods.list_resources, .params = "{}" },
        .{ .method = methods.list_resource_templates, .params = "{}" },
        .{ .method = methods.read_resource, .params = "{\"uri\":\"file:///a\",\"inputResponses\":{},\"requestState\":\"s\"}" },
        .{ .method = methods.get_prompt, .params = "{\"name\":\"review\",\"arguments\":{\"language\":\"zig\"}}" },
        .{ .method = methods.call_tool, .params = "{\"name\":\"weather\",\"arguments\":{\"city\":\"Madrid\"}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"review\"},\"argument\":{\"name\":\"language\",\"value\":\"z\"},\"context\":{\"arguments\":{\"other\":\"x\"}}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///{path}\"},\"argument\":{\"name\":\"path\",\"value\":\"src\"}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"toolsListChanged\":true,\"promptsListChanged\":false,\"resourcesListChanged\":true,\"resourceSubscriptions\":[\"file:///a\"],\"taskIds\":[\"task-1\"]}}" },
        .{ .method = tasks.methods.get, .params = "{\"taskId\":\"task-1\"}" },
        .{ .method = tasks.methods.cancel, .params = "{\"taskId\":\"task-1\"}" },
        .{ .method = tasks.methods.update, .params = "{\"taskId\":\"task-1\",\"inputResponses\":{\"approval\":{\"action\":\"accept\"}}}" },
        .{ .method = "com.example/future", .params = "{\"anything\":true}" },
    };
    for (valid) |case| try validateRequestMethodParams(
        case.method,
        try capabilityObject(try parseResponse(arena.allocator(), case.params), error.InvalidMcpMessage),
        error.InvalidMcpMessage,
    );

    const invalid = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = methods.list_tools, .params = "{\"cursor\":1}" },
        .{ .method = methods.read_resource, .params = "{}" },
        .{ .method = methods.read_resource, .params = "{\"uri\":1}" },
        .{ .method = methods.read_resource, .params = "{\"uri\":\"x\",\"inputResponses\":[]}" },
        .{ .method = methods.read_resource, .params = "{\"uri\":\"x\",\"requestState\":1}" },
        .{ .method = methods.get_prompt, .params = "{}" },
        .{ .method = methods.get_prompt, .params = "{\"name\":\"x\",\"arguments\":[]}" },
        .{ .method = methods.get_prompt, .params = "{\"name\":\"x\",\"arguments\":{\"a\":1}}" },
        .{ .method = methods.call_tool, .params = "{}" },
        .{ .method = methods.call_tool, .params = "{\"name\":\"x\",\"arguments\":[]}" },
        .{ .method = methods.complete, .params = "{}" },
        .{ .method = methods.complete, .params = "{\"ref\":[],\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{},\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"future\"},\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\"},\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/resource\"},\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":[]}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":{}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":{\"name\":\"a\"}}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":{\"name\":\"a\",\"value\":\"b\"},\"context\":[]}" },
        .{ .method = methods.complete, .params = "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":{\"name\":\"a\",\"value\":\"b\"},\"context\":{\"arguments\":{\"a\":1}}}" },
        .{ .method = methods.listen, .params = "{}" },
        .{ .method = methods.listen, .params = "{\"notifications\":[]}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"toolsListChanged\":1}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"resourceSubscriptions\":{}}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"resourceSubscriptions\":[1]}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"taskIds\":{}}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"taskIds\":[1]}}" },
        .{ .method = methods.listen, .params = "{\"notifications\":{\"taskIds\":[\"\"]}}" },
        .{ .method = tasks.methods.get, .params = "{}" },
        .{ .method = tasks.methods.get, .params = "{\"taskId\":\"\"}" },
        .{ .method = tasks.methods.cancel, .params = "{\"taskId\":1}" },
        .{ .method = tasks.methods.update, .params = "{\"taskId\":\"a\"}" },
        .{ .method = tasks.methods.update, .params = "{\"taskId\":\"a\",\"inputResponses\":[]}" },
        .{ .method = tasks.methods.update, .params = "{\"taskId\":\"a\",\"inputResponses\":{\"x\":true}}" },
    };
    for (invalid) |case| try std.testing.expectError(
        error.InvalidMcpMessage,
        validateRequestMethodParams(
            case.method,
            try capabilityObject(try parseResponse(arena.allocator(), case.params), error.InvalidMcpMessage),
            error.InvalidMcpMessage,
        ),
    );
}

test "core notification params and stream metadata are validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const valid = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = methods.cancelled, .params = "{\"requestId\":1,\"reason\":\"done\"}" },
        .{ .method = methods.cancelled, .params = "{\"requestId\":\"one\"}" },
        .{ .method = methods.progress, .params = "{\"progressToken\":\"p\",\"progress\":1.5,\"total\":2,\"message\":\"working\"}" },
        .{ .method = methods.resource_updated, .params = "{\"uri\":\"file:///a\"}" },
        .{ .method = methods.subscriptions_acknowledged, .params = "{\"notifications\":{}}" },
        .{ .method = tasks.methods.status_notification, .params = "{\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":null}" },
        .{ .method = methods.tool_list_changed, .params = "{}" },
        .{ .method = "com.example/changed", .params = "{\"anything\":true}" },
    };
    for (valid) |case| try validateNotificationMethodParams(
        case.method,
        try capabilityObject(try parseResponse(arena.allocator(), case.params), error.InvalidMcpMessage),
        error.InvalidMcpMessage,
    );
    const levels = [_][]const u8{
        "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency",
    };
    for (levels) |level| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"level\":\"{s}\",\"logger\":\"test\",\"data\":null}}",
            .{level},
        );
        defer std.testing.allocator.free(source);
        try validateNotificationMethodParams(
            methods.logging_message,
            try capabilityObject(try parseResponse(arena.allocator(), source), error.InvalidMcpMessage),
            error.InvalidMcpMessage,
        );
    }

    const invalid = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = methods.cancelled, .params = "{}" },
        .{ .method = methods.cancelled, .params = "{\"requestId\":true}" },
        .{ .method = methods.cancelled, .params = "{\"requestId\":1,\"reason\":1}" },
        .{ .method = methods.progress, .params = "{}" },
        .{ .method = methods.progress, .params = "{\"progressToken\":1}" },
        .{ .method = methods.progress, .params = "{\"progressToken\":1,\"progress\":true}" },
        .{ .method = methods.progress, .params = "{\"progressToken\":1,\"progress\":0,\"total\":true}" },
        .{ .method = methods.progress, .params = "{\"progressToken\":1,\"progress\":0,\"message\":1}" },
        .{ .method = methods.logging_message, .params = "{}" },
        .{ .method = methods.logging_message, .params = "{\"level\":\"verbose\",\"data\":1}" },
        .{ .method = methods.logging_message, .params = "{\"level\":\"info\"}" },
        .{ .method = methods.logging_message, .params = "{\"level\":\"info\",\"logger\":1,\"data\":1}" },
        .{ .method = methods.resource_updated, .params = "{}" },
        .{ .method = methods.subscriptions_acknowledged, .params = "{}" },
        .{ .method = tasks.methods.status_notification, .params = "{\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":null}" },
        .{ .method = methods.tool_list_changed, .params = "{\"_meta\":[]}" },
        .{ .method = methods.tool_list_changed, .params = "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":true}}" },
    };
    for (invalid) |case| try std.testing.expectError(
        error.InvalidMcpMessage,
        validateNotificationMethodParams(
            case.method,
            try capabilityObject(try parseResponse(arena.allocator(), case.params), error.InvalidMcpMessage),
            error.InvalidMcpMessage,
        ),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        validateNumber(.{ .float = std.math.inf(f64) }, error.InvalidMcpMessage),
    );

    const stream_notification = try parseResponse(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
    );
    try validateIncomingNotification(stream_notification, true, error.InvalidMcpMessage);
    const invalid_envelopes = [_][]const u8{
        "[]",
        "{\"method\":\"notifications/tools/list_changed\"}",
        "{\"jsonrpc\":\"1.0\",\"method\":\"notifications/tools/list_changed\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"notifications/tools/list_changed\"}",
        "{\"jsonrpc\":\"2.0\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":[]}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{}}",
    };
    for (invalid_envelopes) |source| try std.testing.expectError(
        error.InvalidMcpMessage,
        validateIncomingNotification(
            try parseResponse(arena.allocator(), source),
            true,
            error.InvalidMcpMessage,
        ),
    );
    try std.testing.expectError(
        error.InvalidMcpResponse,
        testValidateMethodResult(methods.listen, "{\"_meta\":{}}"),
    );
}

test "typed notification output passes the MCP stream validator" {
    const notifications = [_]Notification{
        .{ .progress = .{ .progress_token = .{ .integer = 1 }, .progress = 0.5 } },
        .{ .logging_message = .{ .level = .info, .data_json = "null" } },
        .{ .subscriptions_acknowledged = .{ .tools_list_changed = true } },
    };
    for (notifications) |notification| {
        const source = try notification.stringifyAlloc(std.testing.allocator, .{ .string = "stream-1" });
        defer std.testing.allocator.free(source);
        var parsed = try json_limits.parse(
            std.json.Value,
            std.testing.allocator,
            source,
            json_limits.defaults.mcp_message,
            .{},
            error.InvalidMcpMessage,
        );
        defer parsed.deinit();
        try validateIncomingNotification(parsed.value, true, error.InvalidMcpMessage);
    }
}

test "client and server reject malformed advertised capabilities at boundaries" {
    try std.testing.expectError(error.InvalidMcpMessage, buildRequest(
        std.testing.allocator,
        1,
        methods.discover,
        "{}",
        "client",
        "1",
        "{\"elicitation\":true}",
    ));

    const Handler = struct {
        fn handle(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 { // kcov-ignore: discovery validation must bypass this fixture
            return allocator.dupe(u8, "{}"); // kcov-ignore: discovery validation must bypass this fixture
        }
    };
    var unused: u8 = 0;
    var server = Server{
        .handler = .{ .context = &unused, .handleFn = Handler.handle },
        .capabilities_json = "{\"tools\":true}",
    };
    try std.testing.expectError(error.InvalidMcpResponse, server.discoveryResult(std.testing.allocator));
    const malformed_request =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{" ++
        "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
        "\"io.modelcontextprotocol/clientCapabilities\":{\"sampling\":true}}}}";
    const response = try server.handle(std.testing.allocator, malformed_request, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "Invalid client capabilities") != null);
}

test "server method guards follow its per-request advertised capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all = try parseResponse(
        arena.allocator(),
        "{\"completions\":{},\"prompts\":{},\"resources\":{},\"tools\":{}," ++
            "\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    );
    const guarded = [_][]const u8{
        methods.complete,
        methods.get_prompt,
        methods.list_prompts,
        methods.list_resources,
        methods.list_resource_templates,
        methods.read_resource,
        methods.call_tool,
        methods.list_tools,
    };
    for (guarded) |method| try std.testing.expect(serverSupportsMethod(all, method));
    try std.testing.expect(serverSupportsMethod(all, tasks.methods.get));
    try std.testing.expect(serverSupportsMethod(all, tasks.methods.update));
    try std.testing.expect(serverSupportsMethod(all, tasks.methods.cancel));
    const none = try parseResponse(arena.allocator(), "{}");
    for (guarded) |method| try std.testing.expect(!serverSupportsMethod(none, method));
    try std.testing.expect(!serverSupportsMethod(none, tasks.methods.get));
    try std.testing.expect(serverSupportsMethod(none, methods.discover));
    try std.testing.expect(serverSupportsMethod(none, methods.listen));
    try std.testing.expect(serverSupportsMethod(none, "com.example/future"));
    try std.testing.expect(!serverSupportsMethod(.null, methods.discover));
}

test "server task dispatch requires capability and matching task route" {
    const Handler = struct {
        calls: usize = 0,

        fn handle(context: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (std.mem.eql(u8, method, methods.listen)) return allocator.dupe(
                u8,
                "{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}",
            );
            try std.testing.expectEqualStrings(tasks.methods.get, method);
            try std.testing.expect(std.mem.indexOf(u8, params, "\"taskId\":\"task-1\"") != null);
            return allocator.dupe(
                u8,
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"working\"," ++
                    "\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}",
            );
        }
    };
    var handler: Handler = .{};
    var server = Server{
        .handler = .{ .context = &handler, .handleFn = Handler.handle },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    };
    const missing_request = try buildRequest(
        std.testing.allocator,
        1,
        tasks.methods.get,
        "{\"taskId\":\"task-1\"}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(missing_request);
    const missing = try server.handle(std.testing.allocator, missing_request, null);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body.?, "-32003") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.body.?, tasks.extension_identifier) != null);
    try std.testing.expectEqual(@as(usize, 0), handler.calls);

    const request = try buildRequest(
        std.testing.allocator,
        2,
        tasks.methods.get,
        "{\"taskId\":\"task-1\"}",
        "client",
        "1",
        "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    );
    defer std.testing.allocator.free(request);
    const headers = [_]http.Header{
        .{ .name = "MCP-Protocol-Version", .value = protocol_version },
        .{ .name = "Mcp-Method", .value = tasks.methods.get },
        .{ .name = "Mcp-Name", .value = "task-1" },
    };
    const accepted = try server.handle(std.testing.allocator, request, .{ .headers = &headers });
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), accepted.status);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);

    const wrong_route = [_]http.Header{
        headers[0],
        headers[1],
        .{ .name = "Mcp-Name", .value = "other-task" },
    };
    const rejected = try server.handle(std.testing.allocator, request, .{ .headers = &wrong_route });
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), rejected.status);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);

    const missing_listen = try buildRequest(
        std.testing.allocator,
        3,
        methods.listen,
        "{\"notifications\":{\"taskIds\":[\"task-1\"]}}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(missing_listen);
    const missing_subscription = try server.handle(std.testing.allocator, missing_listen, null);
    defer missing_subscription.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), missing_subscription.status);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);

    const capable_listen = try buildRequest(
        std.testing.allocator,
        4,
        methods.listen,
        "{\"notifications\":{\"taskIds\":[\"task-1\"]}}",
        "client",
        "1",
        "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    );
    defer std.testing.allocator.free(capable_listen);
    const accepted_subscription = try server.handle(std.testing.allocator, capable_listen, null);
    defer accepted_subscription.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), accepted_subscription.status);
    try std.testing.expectEqual(@as(usize, 2), handler.calls);
}

test "MRTR input requirements match the capabilities sent on the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseResponse(
        arena.allocator(),
        "{\"resultType\":\"input_required\",\"inputRequests\":{" ++
            "\"form\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Form\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}," ++
            "\"url\":{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Open\",\"url\":\"https://example.test\"}}," ++
            "\"roots\":{\"method\":\"roots/list\"}," ++
            "\"sampling\":{\"method\":\"sampling/createMessage\",\"params\":{" ++
            "\"messages\":[],\"maxTokens\":1,\"includeContext\":\"thisServer\",\"tools\":[],\"toolChoice\":{}}}}}",
    );
    const requirements = try inputCapabilityRequirements(result);
    try std.testing.expect(requirements.elicitation);
    try std.testing.expect(requirements.elicitation_url);
    try std.testing.expect(requirements.roots);
    try std.testing.expect(requirements.sampling);
    try std.testing.expect(requirements.sampling_context);
    try std.testing.expect(requirements.sampling_tools);
    const full = try parseResponse(
        arena.allocator(),
        "{\"elicitation\":{\"url\":{}},\"roots\":{},\"sampling\":{\"context\":{},\"tools\":{}}}",
    );
    try std.testing.expect(clientCapabilitiesSatisfy(full, requirements));
    try validateInputRequiredCapabilities(result, full);
    const insufficient = try parseResponse(
        arena.allocator(),
        "{\"elicitation\":{},\"sampling\":{}}",
    );
    try std.testing.expect(!clientCapabilitiesSatisfy(insufficient, requirements));
    try std.testing.expectError(
        error.InvalidMcpResponse,
        validateInputRequiredCapabilities(result, insufficient),
    );
    try std.testing.expect(!clientCapabilitiesSatisfy(.null, requirements));

    const missing = try missingClientCapabilities(arena.allocator(), insufficient, requirements);
    const missing_json = try std.json.Stringify.valueAlloc(std.testing.allocator, missing, .{});
    defer std.testing.allocator.free(missing_json);
    try std.testing.expect(std.mem.indexOf(u8, missing_json, "\"url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_json, "\"roots\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_json, "\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_json, "\"tools\"") != null);

    const created = try parseResponse(
        arena.allocator(),
        "{\"resultType\":\"task\",\"taskId\":\"task-1\",\"status\":\"working\"," ++
            "\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}",
    );
    const task_requirements = try inputCapabilityRequirements(created);
    try std.testing.expect(task_requirements.tasks);
    try std.testing.expect(!clientCapabilitiesSatisfy(insufficient, task_requirements));
    const task_capable = try parseResponse(
        arena.allocator(),
        "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    );
    try std.testing.expect(clientCapabilitiesSatisfy(task_capable, task_requirements));
    const missing_tasks = try missingClientCapabilities(arena.allocator(), insufficient, task_requirements);
    const missing_tasks_json = try std.json.Stringify.valueAlloc(std.testing.allocator, missing_tasks, .{});
    defer std.testing.allocator.free(missing_tasks_json);
    try std.testing.expect(std.mem.indexOf(u8, missing_tasks_json, tasks.extension_identifier) != null);
    const invalid_extensions = try parseResponse(arena.allocator(), "{\"extensions\":true}");
    try std.testing.expect(!clientCapabilitiesSatisfy(invalid_extensions, task_requirements));

    const complete = try inputCapabilityRequirements(try parseResponse(arena.allocator(), "{}"));
    try std.testing.expect(clientCapabilitiesSatisfy(try parseResponse(arena.allocator(), "{}"), complete));
    const state_only = try inputCapabilityRequirements(try parseResponse(
        arena.allocator(),
        "{\"resultType\":\"input_required\",\"requestState\":\"later\"}",
    ));
    try std.testing.expect(clientCapabilitiesSatisfy(try parseResponse(arena.allocator(), "{}"), state_only));
    const no_context = try inputCapabilityRequirements(try parseResponse(
        arena.allocator(),
        "{\"resultType\":\"input_required\",\"inputRequests\":{\"sample\":{" ++
            "\"method\":\"sampling/createMessage\",\"params\":{\"includeContext\":\"none\"}}}}",
    ));
    try std.testing.expect(!no_context.sampling_context);
}

test "server returns protocol errors for unadvertised methods and client inputs" {
    const Handler = struct {
        calls: usize = 0,
        fn handle(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return allocator.dupe(
                u8,
                "{\"resultType\":\"input_required\",\"inputRequests\":{\"login\":{" ++
                    "\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Open\",\"url\":\"https://example.test\"}}}}",
            );
        }
    };
    var handler: Handler = .{};
    var server = Server{
        .handler = .{ .context = &handler, .handleFn = Handler.handle },
        .capabilities_json = "{}",
    };
    const request = try buildRequest(
        std.testing.allocator,
        1,
        methods.call_tool,
        "{\"name\":\"login\"}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(request);
    const absent = try server.handle(std.testing.allocator, request, null);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), absent.status);
    try std.testing.expect(std.mem.indexOf(u8, absent.body.?, "-32601") != null);
    try std.testing.expectEqual(@as(usize, 0), handler.calls);

    server.capabilities_json = "{\"tools\":{}}";
    const missing = try server.handle(std.testing.allocator, request, null);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body.?, "-32021") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.body.?, "requiredCapabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.body.?, "\"url\"") != null);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
}

test "state-only MRTR retries without an input handler" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"requestState\":\"retry-later\"}}",
            );
            try std.testing.expect(std.mem.indexOf(u8, request.message, "\"requestState\":\"retry-later\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "inputResponses") == null);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"content\":[]}}",
            );
        }
    };
    var stub = Stub{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    const result = try client.request(std.testing.allocator, methods.call_tool, "{\"name\":\"retry\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "client emits self-describing requests and HTTP routing headers" {
    const Stub = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try std.testing.expectEqualStrings(protocol_version, findHeader(request.headers, "mcp-protocol-version").?);
            try std.testing.expectEqualStrings(methods.call_tool, findHeader(request.headers, "mcp-method").?);
            try std.testing.expectEqualStrings("weather", findHeader(request.headers, "mcp-name").?);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body, .{});
            defer parsed.deinit();
            const params = try requiredObject((try requiredObject(parsed.value)).get("params").?);
            const meta = try requiredObject(params.get("_meta").?);
            try std.testing.expectEqualStrings(
                protocol_version,
                try requiredString(meta, "io.modelcontextprotocol/protocolVersion"),
            );
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"sunny\"}]}}"),
            };
        }
    };
    var unused: u8 = 0;
    var streamable = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &unused, .sendFn = Stub.send },
        "https://example.test/mcp",
    );
    var client = Client{ .transport = streamable.transport() };
    const result = try client.callTool(std.testing.allocator, "weather", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "sunny") != null);
}

test "typed task client helpers route requests and return owned state" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("task-1", request.routing_name.?);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.message, .{});
            defer parsed.deinit();
            const root = try requiredObject(parsed.value);
            const params = try requiredObject(root.get("params").?);
            try std.testing.expectEqualStrings("task-1", try requiredString(params, "taskId"));
            if (std.mem.eql(u8, request.method, tasks.methods.get)) {
                return allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"," ++
                        "\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\"," ++
                        "\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"result\":{\"content\":[]}}}",
                );
            }
            if (std.mem.eql(u8, request.method, tasks.methods.update)) {
                try std.testing.expect(params.get("inputResponses") != null);
                return allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\"}}",
                );
            }
            try std.testing.expectEqualStrings(tasks.methods.cancel, request.method);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resultType\":\"complete\"}}",
            );
        }
    };
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    };
    var task = try client.getTask(std.testing.allocator, "task-1");
    defer task.deinit();
    const detailed = switch (task.value) {
        .detailed => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(tasks.Status.completed, detailed.status());
    try std.testing.expectEqualStrings("then", detailed.metadata.created_at);
    try client.updateTask(std.testing.allocator, .{
        .task_id = "task-1",
        .input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
    });
    try client.cancelTask(std.testing.allocator, "task-1");
    try std.testing.expectEqual(@as(usize, 3), stub.calls);

    var incapable = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    try std.testing.expectError(
        error.MissingMcpClientCapability,
        incapable.getTask(std.testing.allocator, "task-1"),
    );
    try std.testing.expectEqual(@as(usize, 3), stub.calls);
    try std.testing.expectError(
        error.InvalidTaskRequest,
        client.cancelTask(std.testing.allocator, ""),
    );
}

test "task status subscriptions require the extension before transport I/O" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings(methods.listen, request.method);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "\"taskIds\":[\"task-1\"]") != null);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"," ++
                    "\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
            );
        }
        fn event(_: *anyopaque, _: []const u8) !void {}
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    try std.testing.expectError(
        error.MissingMcpClientCapability,
        client.listen(
            std.testing.allocator,
            .{ .task_ids = &.{"task-1"} },
            .{ .context = &stub, .eventFn = Stub.event },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
    client.capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}";
    const result = try client.listen(
        std.testing.allocator,
        .{ .task_ids = &.{"task-1"} },
        .{ .context = &stub, .eventFn = Stub.event },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try Stub.event(&stub, "{}");
}

test "task waiting polls answers input once and returns terminal owned state" {
    const State = struct {
        calls: usize = 0,
        gets: usize = 0,
        updates: usize = 0,
        inputs: usize = 0,
        statuses: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.message, .{});
            defer parsed.deinit();
            const root = try requiredObject(parsed.value);
            const id = root.get("id").?;
            const result_source = if (std.mem.eql(u8, request.method, tasks.methods.get)) get: {
                self.gets += 1;
                break :get switch (self.gets) {
                    1 => "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"one\",\"ttlMs\":1000,\"pollIntervalMs\":0}",
                    2, 3 => "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"input_required\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"two\",\"ttlMs\":1000,\"pollIntervalMs\":0,\"inputRequests\":{\"approval\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}}}",
                    else => "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"done\",\"ttlMs\":1000,\"result\":{\"content\":[]}}",
                };
            } else update: {
                try std.testing.expectEqualStrings(tasks.methods.update, request.method);
                self.updates += 1;
                try std.testing.expect(std.mem.indexOf(u8, request.message, "\"approval\":{\"action\":\"accept\"") != null);
                break :update "{\"resultType\":\"complete\"}";
            };
            const result = try std.json.parseFromSlice(std.json.Value, allocator, result_source, .{});
            defer result.deinit();
            return std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = id,
                .result = result.value,
            }, .{});
        }

        fn input(context: *anyopaque, allocator: std.mem.Allocator, request: InputRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.inputs += 1;
            try std.testing.expectEqualStrings("approval", request.key);
            try std.testing.expectEqual(InputKind.elicitation, request.kind);
            return allocator.dupe(u8, "{\"action\":\"accept\"}");
        }

        fn status(context: *anyopaque, task: tasks.DetailedTask) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.statuses += 1;
            try std.testing.expectEqualStrings("task-1", task.metadata.task_id);
        }
    };
    var state: State = .{};
    var client = Client{
        .transport = .{ .context = &state, .sendFn = State.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .input_handler = .{ .context = &state, .handleFn = State.input },
    };
    var terminal = try client.waitTask(std.testing.allocator, "task-1", .{
        .poll = .{ .default_interval_ms = 0, .minimum_interval_ms = 0, .max_polls = 5 },
        .status_sink = .{ .context = &state, .emitFn = State.status },
    });
    defer terminal.deinit();
    try std.testing.expectEqual(tasks.Status.completed, terminal.value.detailed.status());
    try std.testing.expectEqual(@as(usize, 5), state.calls);
    try std.testing.expectEqual(@as(usize, 4), state.gets);
    try std.testing.expectEqual(@as(usize, 1), state.updates);
    try std.testing.expectEqual(@as(usize, 1), state.inputs);
    try std.testing.expectEqual(@as(usize, 4), state.statuses);

    state.gets = 1;
    client.input_handler = null;
    try std.testing.expectError(
        error.InputRequired,
        client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .default_interval_ms = 0, .max_polls = 1 },
        }),
    );
}

test "task waiting is bounded and cooperatively cancels on local stop" {
    const State = struct {
        calls: usize = 0,
        cancels: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const result = if (std.mem.eql(u8, request.method, tasks.methods.cancel)) cancel: {
                self.cancels += 1;
                break :cancel "{\"resultType\":\"complete\"}";
            } else "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"pollIntervalMs\":1}";
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                .{ self.calls, result },
            );
        }
    };
    var state: State = .{};
    var client = Client{
        .transport = .{ .context = &state, .sendFn = State.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
    };
    try std.testing.expectError(
        error.TooManyMcpTaskPolls,
        client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .max_polls = 1 },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.cancels);

    try std.testing.expectError(
        error.TaskPollingRequiresIo,
        client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .max_polls = 2 },
        }),
    );
    try std.testing.expectEqual(@as(usize, 2), state.cancels);
    try std.testing.expectError(
        error.TooManyMcpTaskPolls,
        client.waitTask(std.testing.allocator, "task-1", .{
            .io = std.testing.io,
            .poll = .{ .max_polls = 2 },
        }),
    );
    try std.testing.expectEqual(@as(usize, 3), state.cancels);

    var cancellation: model.CancellationToken = .{};
    cancellation.cancel();
    try std.testing.expectError(
        error.Cancelled,
        client.waitTask(std.testing.allocator, "task-1", .{
            .control = .{ .cancellation = &cancellation },
        }),
    );
    try std.testing.expectEqual(@as(usize, 4), state.cancels);
    try std.testing.expectError(
        error.TooManyMcpTaskPolls,
        client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .max_polls = 1 },
            .cancel_on_stop = false,
        }),
    );
    try std.testing.expectEqual(@as(usize, 4), state.cancels);
    try std.testing.expectError(
        error.TooManyMcpTaskPolls,
        client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .max_polls = 0 },
        }),
    );
    try std.testing.expectError(
        error.InvalidTaskRequest,
        client.waitTask(std.testing.allocator, "", .{}),
    );
}

test "task waiting releases every partial input and polling allocation" {
    const Check = struct {
        const State = struct { calls: usize = 0 };

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const state: *State = @ptrCast(@alignCast(context));
            state.calls += 1;
            const result = if (std.mem.eql(u8, request.method, tasks.methods.update))
                "{\"resultType\":\"complete\"}"
            else if (state.calls == 1)
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"input_required\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"pollIntervalMs\":0,\"inputRequests\":{\"approval\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}}}"
            else
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"done\",\"ttlMs\":1000,\"result\":{\"content\":[]}}";
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                .{ state.calls, result },
            );
        }

        fn input(_: *anyopaque, allocator: std.mem.Allocator, _: InputRequest) ![]u8 {
            return allocator.dupe(u8, "{\"action\":\"accept\"}");
        }

        fn run(allocator: std.mem.Allocator) !void {
            var state: State = .{};
            var client = Client{
                .transport = .{ .context = &state, .sendFn = send },
                .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
                .input_handler = .{ .context = &state, .handleFn = input },
            };
            var task = try client.waitTask(allocator, "task-1", .{
                .poll = .{ .default_interval_ms = 0, .minimum_interval_ms = 0, .max_polls = 2 },
            });
            defer task.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "tool tasks are tracked and explicit cancellation removes durable state" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const result = if (std.mem.eql(u8, request.method, methods.call_tool))
                "{\"resultType\":\"task\",\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}"
            else
                "{\"resultType\":\"complete\"}";
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                .{ self.calls, result },
            );
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var durable = task_store.FileStore.init(std.testing.io, temporary.dir, "tasks.json");
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .task_store = durable.store(),
    };
    const created = try client.callTool(std.testing.allocator, "slow", "{}");
    defer std.testing.allocator.free(created);
    var tracked = try durable.store().load(std.testing.allocator);
    defer tracked.deinit();
    try std.testing.expectEqual(@as(usize, 1), tracked.records.len);
    try std.testing.expectEqualStrings("task-1", tracked.records[0].task_id);

    try client.cancelTask(std.testing.allocator, "task-1");
    var empty = try durable.store().load(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
}

test "durable task resume replays pending input without invoking its handler" {
    const State = struct {
        phase: enum { interrupt_update, resuming } = .interrupt_update,
        calls: usize = 0,
        updates: usize = 0,
        inputs: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (std.mem.eql(u8, request.method, tasks.methods.update)) {
                self.updates += 1;
                try std.testing.expect(std.mem.indexOf(u8, request.message, "\"approval\":{\"action\":\"accept\"") != null);
                if (self.phase == .interrupt_update) return error.UpdateInterrupted;
                return rpcResultForRequest(allocator, request.message, "{\"resultType\":\"complete\"}");
            }
            try std.testing.expectEqualStrings(tasks.methods.get, request.method);
            const result = if (self.phase == .resuming and self.updates == 2)
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"done\",\"ttlMs\":1000,\"result\":{\"content\":[]}}"
            else
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"input_required\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"pollIntervalMs\":0,\"inputRequests\":{\"approval\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}}}";
            return rpcResultForRequest(allocator, request.message, result);
        }

        fn input(context: *anyopaque, allocator: std.mem.Allocator, _: InputRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.inputs += 1;
            return allocator.dupe(u8, "{\"action\":\"accept\"}");
        }

        fn rpcResultForRequest(allocator: std.mem.Allocator, request_json: []const u8, result: []const u8) ![]u8 {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
            defer parsed.deinit();
            const parsed_result = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
            defer parsed_result.deinit();
            return std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = (try requiredObject(parsed.value)).get("id").?,
                .result = parsed_result.value,
            }, .{});
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var durable = task_store.FileStore.init(std.testing.io, temporary.dir, "tasks.json");
    var state: State = .{};
    var interrupted_client = Client{
        .transport = .{ .context = &state, .sendFn = State.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .input_handler = .{ .context = &state, .handleFn = State.input },
        .task_store = durable.store(),
    };
    try std.testing.expectError(
        error.UpdateInterrupted,
        interrupted_client.waitTask(std.testing.allocator, "task-1", .{
            .poll = .{ .default_interval_ms = 0, .minimum_interval_ms = 0, .max_polls = 2 },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.inputs);
    var pending = try durable.store().load(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expect(pending.records[0].pending_input_responses_json != null);

    state.phase = .resuming;
    var resumed_client = Client{
        .transport = .{ .context = &state, .sendFn = State.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .task_store = durable.store(),
    };
    var resumed = try resumed_client.resumeTasks(std.testing.allocator, .{
        .poll = .{ .default_interval_ms = 0, .minimum_interval_ms = 0, .max_polls = 2 },
    });
    defer resumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), resumed.items.len);
    try std.testing.expectEqual(tasks.Status.completed, resumed.items[0].value.detailed.status());
    try std.testing.expectEqual(@as(usize, 1), state.inputs);
    try std.testing.expectEqual(@as(usize, 2), state.updates);
    var empty = try durable.store().load(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
}

test "durable task resume requires a store" {
    var client = Client{ .transport = undefined };
    try std.testing.expectError(
        error.MissingMcpTaskStore,
        client.resumeTasks(std.testing.allocator, .{}),
    );
}

test "durable task failures preserve response and task ownership" {
    const FailureStore = struct {
        fail_save: bool = false,
        fail_remove: bool = false,

        fn store(self: *@This()) task_store.Store {
            return .{
                .context = self,
                .loadFn = load,
                .saveFn = save,
                .removeFn = remove,
            };
        }

        fn load(_: *anyopaque, allocator: std.mem.Allocator) !task_store.OwnedRecords {
            return .{ .arena = .init(allocator), .records = &.{} };
        }

        fn save(context: *anyopaque, _: std.mem.Allocator, _: task_store.Record) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_save) return error.StoreUnavailable;
        }

        fn remove(context: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_remove) return error.StoreUnavailable;
        }
    };
    const Stub = struct {
        calls: usize = 0,
        cancels: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const result = if (std.mem.eql(u8, request.method, methods.call_tool))
                "{\"resultType\":\"task\",\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}"
            else if (std.mem.eql(u8, request.method, tasks.methods.get))
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"result\":{\"content\":[]}}"
            else cancel: {
                self.cancels += 1;
                break :cancel "{\"resultType\":\"complete\"}";
            };
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                .{ self.calls, result },
            );
        }
    };
    var failures = FailureStore{ .fail_save = true };
    var empty_snapshot = try failures.store().load(std.testing.allocator);
    defer empty_snapshot.deinit();
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .task_store = failures.store(),
    };
    try std.testing.expectError(
        error.StoreUnavailable,
        client.callTool(std.testing.allocator, "slow", "{}"),
    );
    try std.testing.expectEqual(@as(usize, 1), stub.cancels);

    failures.fail_save = false;
    failures.fail_remove = true;
    stub.calls = 0;
    client.next_id = .init(1);
    try std.testing.expectError(
        error.StoreUnavailable,
        client.getTask(std.testing.allocator, "task-1"),
    );
}

test "durable resume releases earlier terminal tasks when a later task fails" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (std.mem.eql(u8, request.routing_name orelse "", "task-2"))
                return error.ResumeInterrupted;
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"now\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"result\":{{\"content\":[]}}}}}}",
                .{self.calls},
            );
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var durable = task_store.FileStore.init(std.testing.io, temporary.dir, "tasks.json");
    try durable.store().save(std.testing.allocator, .{ .task_id = "task-1" });
    try durable.store().save(std.testing.allocator, .{ .task_id = "task-2" });
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        .task_store = durable.store(),
    };
    try std.testing.expectError(
        error.ResumeInterrupted,
        client.resumeTasks(std.testing.allocator, .{}),
    );
    var remaining = try durable.store().load(std.testing.allocator);
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining.records.len);
    try std.testing.expectEqualStrings("task-2", remaining.records[0].task_id);
}

test "durable task waiting releases every partial allocation" {
    const Check = struct {
        const State = struct { calls: usize = 0 };

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const state: *State = @ptrCast(@alignCast(context));
            state.calls += 1;
            const result = if (std.mem.eql(u8, request.method, tasks.methods.update))
                "{\"resultType\":\"complete\"}"
            else if (state.calls == 1)
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"input_required\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"pollIntervalMs\":0,\"inputRequests\":{\"next\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}}}"
            else
                "{\"resultType\":\"complete\",\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\",\"lastUpdatedAt\":\"done\",\"ttlMs\":1000,\"result\":{\"content\":[]}}";
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                .{ state.calls, result },
            );
        }

        fn input(_: *anyopaque, allocator: std.mem.Allocator, _: InputRequest) ![]u8 {
            return allocator.dupe(u8, "{\"action\":\"accept\"}");
        }

        fn run(allocator: std.mem.Allocator) !void {
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            var durable = task_store.FileStore.init(std.testing.io, temporary.dir, "tasks.json");
            try durable.store().save(allocator, .{
                .task_id = "task-1",
                .answered_input_keys = &.{"prior"},
            });
            var state: State = .{};
            var client = Client{
                .transport = .{ .context = &state, .sendFn = send },
                .capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
                .input_handler = .{ .context = &state, .handleFn = input },
                .task_store = durable.store(),
            };
            var task = try client.waitTask(allocator, "task-1", .{
                .poll = .{ .default_interval_ms = 0, .minimum_interval_ms = 0, .max_polls = 2 },
            });
            defer task.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "tool-created tasks require the advertised client extension" {
    const Stub = struct {
        calls: usize = 0,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"task\"," ++
                    "\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"now\"," ++
                    "\"lastUpdatedAt\":\"now\",\"ttlMs\":1000}}}}",
                .{self.calls},
            );
        }
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    try std.testing.expectError(
        error.InvalidMcpResponse,
        client.callTool(std.testing.allocator, "slow", "{}"),
    );
    client.capabilities_json = "{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}";
    const result = try client.callTool(std.testing.allocator, "slow", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"resultType\":\"task\"") != null);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "Streamable HTTP refreshes issuer-bound tokens after a Bearer challenge" {
    const State = struct {
        token_calls: usize = 0,
        http_calls: usize = 0,

        fn token(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: auth.TokenRequest,
        ) !auth.AccessToken {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.token_calls += 1;
            if (self.token_calls == 1) {
                try std.testing.expectEqual(auth.TokenReason.initial, request.reason);
                try std.testing.expectEqual(@as(usize, 0), request.scopes.len);
            } else {
                try std.testing.expectEqual(auth.TokenReason.invalid_token, request.reason);
                try std.testing.expectEqual(@as(usize, 2), request.scopes.len);
                try std.testing.expectEqualStrings("profile", request.scopes[0]);
                try std.testing.expectEqualStrings("tools:read", request.scopes[1]);
            }
            return .{
                .value = try allocator.dupe(u8, if (self.token_calls == 1) "old" else "fresh"),
                .issuer = try allocator.dupe(u8, request.authorization_server),
                .scopes = if (self.token_calls == 1)
                    try copyTestScopes(allocator, &.{"profile"})
                else
                    try copyTestScopes(allocator, request.scopes),
            };
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.http_calls += 1;
            const authorization = findHeader(request.headers, "authorization").?;
            try std.testing.expect(findHttpHeader(request.headers, "authorization").?.isSensitive());
            if (self.http_calls == 1) {
                try std.testing.expectEqualStrings("Bearer old", authorization);
                return .{
                    .status = 401,
                    .body = try allocator.dupe(u8, "unauthorized"),
                    .metadata = .{ .www_authenticate = http.MetadataText.init(
                        "Bearer error=\"invalid_token\", scope=\"tools:read\"",
                    ) },
                };
            }
            try std.testing.expectEqualStrings("Bearer fresh", authorization);
            return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{" ++
                        "\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{}," ++
                        "\"serverInfo\":{\"name\":\"server\",\"version\":\"1\"}," ++
                        "\"ttlMs\":0,\"cacheScope\":\"public\"}}",
                ),
            };
        }
    };
    var state: State = .{};
    var streamable = StreamableHttpTransport.initWithOptions(
        std.testing.io,
        .{ .context = &state, .sendFn = State.send },
        "https://mcp.example.com/mcp",
        .{ .authorization = .{
            .resource = "https://mcp.example.com/mcp",
            .authorization_server = "https://auth.example.com",
            .tokens = .{ .context = &state, .getFn = State.token },
        } },
    );
    var client = Client{ .transport = streamable.transport() };
    const result = try client.discover(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), state.token_calls);
    try std.testing.expectEqual(@as(usize, 2), state.http_calls);
}

test "Streamable HTTP performs one bounded insufficient-scope step-up" {
    const State = struct {
        token_calls: usize = 0,
        http_calls: usize = 0,

        fn token(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: auth.TokenRequest,
        ) !auth.AccessToken {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.token_calls += 1;
            if (self.token_calls == 2) {
                try std.testing.expectEqual(auth.TokenReason.insufficient_scope, request.reason);
                try std.testing.expectEqual(@as(usize, 2), request.scopes.len);
                try std.testing.expectEqualStrings("tools:call", request.scopes[1]);
            }
            return .{
                .value = try allocator.dupe(u8, "token"),
                .issuer = try allocator.dupe(u8, request.authorization_server),
                .scopes = try copyTestScopes(allocator, &.{"profile"}),
            };
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.http_calls += 1;
            if (self.http_calls <= 2) return .{
                .status = 403,
                .body = try allocator.dupe(u8, "forbidden"),
                .metadata = .{ .www_authenticate = http.MetadataText.init(
                    "Bearer error=\"insufficient_scope\", scope=\"tools:call\"",
                ) },
            };
            unreachable;
        }
    };
    var state: State = .{};
    var streamable = StreamableHttpTransport.initWithOptions(
        std.testing.io,
        .{ .context = &state, .sendFn = State.send },
        "https://mcp.example.com/mcp",
        .{ .authorization = .{
            .resource = "https://mcp.example.com/mcp",
            .authorization_server = "https://auth.example.com",
            .tokens = .{ .context = &state, .getFn = State.token },
        } },
    );
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, .{
            .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
            .method = methods.discover,
        }),
    );
    try std.testing.expectEqual(@as(usize, 2), state.token_calls);
    try std.testing.expectEqual(@as(usize, 2), state.http_calls);
}

test "Streamable HTTP authorization fails closed on policy and challenge boundaries" {
    const State = struct {
        calls: usize = 0,
        challenge: ?[]const u8 = null,

        fn token(_: *anyopaque, allocator: std.mem.Allocator, request: auth.TokenRequest) !auth.AccessToken {
            return auth.AccessToken.initAlloc(allocator, "token", request.authorization_server, &.{});
        }
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return .{
                .status = 401,
                .body = try allocator.dupe(u8, "unauthorized"),
                .metadata = .{ .www_authenticate = if (self.challenge) |value|
                    http.MetadataText.init(value)
                else
                    null },
            };
        }
    };
    var state: State = .{};
    var streamable = StreamableHttpTransport.initWithOptions(
        std.testing.io,
        .{ .context = &state, .sendFn = State.send },
        "https://mcp.example.com/mcp",
        .{ .authorization = .{
            .resource = "https://mcp.example.com/mcp",
            .authorization_server = "https://auth.example.com",
            .tokens = .{ .context = &state, .getFn = State.token },
        } },
    );
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
    };
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, request),
    );
    state.challenge = "Basic realm=\"mcp\"";
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, request),
    );
    state.challenge = "Bearer error=\"invalid_request\"";
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, request),
    );
    try std.testing.expectEqual(@as(usize, 3), state.calls);

    streamable.headers = &.{.{ .name = "authorization", .value = "Bearer static" }};
    try std.testing.expectError(
        error.InvalidBearerToken,
        streamable.transport().send(std.testing.allocator, request),
    );
    streamable.headers = &.{};
    streamable.authorization.?.resource = "https://other.example.com/mcp";
    try std.testing.expectError(
        error.InvalidResourceUri,
        streamable.transport().send(std.testing.allocator, request),
    );
    try std.testing.expect(findHttpHeader(&.{}, "authorization") == null);
}

test "Streamable HTTP validates endpoints before transport callbacks" {
    const Stub = struct {
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const called: *bool = @ptrCast(@alignCast(context));
            called.* = true;
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}") };
        }
    };
    var called = false;
    var blocked = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &called, .sendFn = Stub.send },
        "https://127.0.0.1/mcp",
    );
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
    };
    try std.testing.expectError(
        error.LocalNetworkUrlForbidden,
        blocked.transport().send(std.testing.allocator, request),
    );
    try std.testing.expect(!called);

    var allowed = StreamableHttpTransport.initWithPolicy(
        std.testing.io,
        .{ .context = &called, .sendFn = Stub.send },
        "http://127.0.0.1/mcp",
        .{ .allow_http = true, .allow_local_network = true },
    );
    const response = try allowed.transport().send(std.testing.allocator, request);
    defer std.testing.allocator.free(response);
    try std.testing.expect(called);
}

test "client bounds request response and tool-argument JSON before dispatch" {
    const State = struct {
        response: []const u8,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.response);
        }
    };
    const deep_message = "[" ** 65 ++ "0" ++ "]" ** 65;
    var state = State{ .response = deep_message }; // kcov-ignore
    var client = Client{ .transport = .{ .context = &state, .sendFn = State.send } };
    try std.testing.expectError(
        error.InvalidMcpMessage,
        client.request(std.testing.allocator, "extension/test", deep_message),
    );
    try std.testing.expectError(
        error.InvalidMcpResponse,
        client.request(std.testing.allocator, "extension/test", "{}"),
    );
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "tool", deep_message),
    );
}

test "client completes multi round-trip input requests" {
    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"confirm\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Confirm\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}},\"requestState\":\"state\"}}",
            );
            try std.testing.expect(std.mem.indexOf(u8, request.message, "inputResponses") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.message, "requestState") != null);
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"content\":[]}}",
            );
        }
        fn input(_: *anyopaque, allocator: std.mem.Allocator, request: InputRequest) ![]u8 {
            try std.testing.expectEqualStrings("confirm", request.key);
            try std.testing.expectEqual(InputKind.elicitation, request.kind);
            try std.testing.expect(std.mem.indexOf(u8, request.request_json, request.kind.method()) != null);
            return (InputResponse{ .elicitation = .{
                .action = .accept,
                .content_json = "{\"confirmed\":true}",
            } }).stringifyAlloc(allocator);
        }
    };
    var stub: Stub = .{};
    var client = Client{
        .transport = .{ .context = &stub, .sendFn = Stub.send },
        .capabilities_json = "{\"elicitation\":{}}",
        .input_handler = .{ .context = &stub, .handleFn = Stub.input },
    };
    const result = try client.callTool(std.testing.allocator, "delete", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "tool header annotations are mirrored and encoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arguments = try parseResponse(arena.allocator(), "{\"region\":\" eu-west-1 \"}");
    const headers = try toolArgumentHeaders(
        arena.allocator(),
        "{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"}}}",
        arguments,
    );
    try std.testing.expectEqualStrings("Mcp-Param-Region", headers[0].name);
    try std.testing.expect(std.mem.startsWith(u8, headers[0].value, "=?base64?"));
}

test "server discovers capabilities and validates modern envelopes" {
    const Handler = struct {
        fn handle(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, _: []const u8) ![]u8 {
            try std.testing.expectEqualStrings(methods.list_tools, method);
            return allocator.dupe(u8, "{\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}");
        }
    };
    var unused: u8 = 0;
    var server = Server{
        .handler = .{ .context = &unused, .handleFn = Handler.handle },
        .capabilities_json = "{\"tools\":{}}",
        .instructions = "Use the tools carefully.",
    };
    const discover_request = try buildRequest(
        std.testing.allocator,
        1,
        methods.discover,
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(discover_request);
    const response = try server.handle(std.testing.allocator, discover_request, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, protocol_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "serverInfo") != null);

    const list_request = try buildRequest(
        std.testing.allocator,
        2,
        methods.list_tools,
        "{}",
        "client",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(list_request);
    const listed = try server.handle(std.testing.allocator, list_request, null);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), listed.status);

    const invalid = try server.handle(std.testing.allocator, discover_request, .{ .headers = &.{} });
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid.status);
    try std.testing.expect(std.mem.indexOf(u8, invalid.body.?, "-32020") != null);
}

test "server releases partial state on every allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const Handler = struct {
                fn handle(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
                    return gpa.dupe(u8, "{}");
                }
            };
            var unused: u8 = 0;
            var server = Server{ .handler = .{ .context = &unused, .handleFn = Handler.handle } }; // kcov-ignore
            const request = try buildRequest(allocator, 1, "extension/check", "{}", "client", "1", "{}");
            defer allocator.free(request);
            const response = try server.handle(allocator, request, null);
            defer response.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "streamable HTTP emits subscription notifications before the result" {
    const Events = struct {
        seen: bool = false,
        fn emit(context: *anyopaque, message: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen = std.mem.indexOf(u8, message, "subscriptions/acknowledged") != null;
        }
    };
    var events: Events = .{};
    const body =
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\"," ++
        "\"params\":{\"notifications\":{},\"_meta\":{" ++
        "\"io.modelcontextprotocol/subscriptionId\":1}}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}\n";
    const result = try extractSseResponse(
        std.testing.allocator,
        body,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\"," ++
            "\"params\":{\"notifications\":{}}}",
        methods.listen,
        .{ .context = &events, .eventFn = Events.emit },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(events.seen);
}

test "subscription streams enforce acknowledgement order and requested filters" {
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    const meta = "\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}";
    const body =
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{" ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{}," ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\",\"params\":{" ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\",\"params\":{" ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\"," ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":1,\"progress\":0," ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"com.example/changed\",\"params\":{" ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1," ++ meta ++ "}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}\n";
    const request =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\",\"params\":{" ++
        "\"notifications\":{\"toolsListChanged\":true,\"promptsListChanged\":false," ++
        "\"resourcesListChanged\":true,\"resourceSubscriptions\":[\"file:///a\"]}}}";
    var events: Events = .{};
    const result = try extractSseResponse(
        std.testing.allocator,
        body,
        request,
        methods.listen,
        .{ .context = &events, .eventFn = Events.emit },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 5), events.count);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const notification = try parseResponse(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\"}}",
    );
    const invalid_requests = [_][]const u8{
        "{",
        "{}",
        "{\"params\":[]}",
        "{\"params\":{}}",
        "{\"params\":{\"notifications\":[]}}",
        "{\"params\":{\"notifications\":{}}}",
        "{\"params\":{\"notifications\":{\"resourceSubscriptions\":{}}}}",
    };
    for (invalid_requests) |source| try std.testing.expectError(
        error.InvalidMcpMessage,
        validateSubscriptionNotification(
            arena.allocator(),
            notification,
            source,
        ),
    );

    const task_notification = try parseResponse(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tasks\",\"params\":{" ++
            "\"taskId\":\"task-1\",\"status\":\"completed\",\"createdAt\":\"then\"," ++
            "\"lastUpdatedAt\":\"now\",\"ttlMs\":1000,\"result\":{\"content\":[]}}}",
    );
    try validateSubscriptionNotification(
        arena.allocator(),
        task_notification,
        "{\"params\":{\"notifications\":{\"taskIds\":[\"task-1\",\"task-2\"]}}}",
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        validateSubscriptionNotification(
            arena.allocator(),
            task_notification,
            "{\"params\":{\"notifications\":{\"taskIds\":[\"task-2\"]}}}",
        ),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        validateSubscriptionNotification(
            arena.allocator(),
            task_notification,
            "{\"params\":{\"notifications\":{\"taskIds\":[true]}}}",
        ),
    );

    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\"," ++
                    "\"params\":{\"uri\":\"file:///a\"}}",
                .{},
            );
            defer parsed.deinit();
            try validateSubscriptionNotification(
                allocator,
                parsed.value,
                "{\"params\":{\"notifications\":{\"resourceSubscriptions\":[\"file:///a\"]}}}",
            );
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "stdio transport runs a modern MCP tool server child process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"echo","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}' ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"echoed"}]}}' ;;
        \\  esac
        \\done
    ;
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    var client = Client{ .transport = stdio.transport() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try client.toolset().prepare(arena.allocator(), .{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    });
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const result = try tools[0].tool.execute(std.testing.allocator, "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("echoed", result);
}

test "HTTP transport handles SSE, notifications, and status failures" {
    const Stub = struct {
        status: u16 = 200,
        body: []const u8,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
        }
    };
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var stub = Stub{ .body = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
        "\"params\":{\"progressToken\":1,\"progress\":0}}\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n" };
    var events: Events = .{};
    var streamable = StreamableHttpTransport.init(
        std.testing.io,
        .{ .context = &stub, .sendFn = Stub.send },
        "https://example.test/mcp",
    );
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
        .events = .{ .context = &events, .eventFn = Events.emit },
    };
    const response = try streamable.transport().send(std.testing.allocator, request);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), events.count);

    stub.status = 503;
    stub.body = "unavailable";
    try std.testing.expectError(
        error.McpHttpRequestFailed,
        streamable.transport().send(std.testing.allocator, request),
    );
    try std.testing.expectError(error.McpHttpRequestFailed, streamable.transport().send(
        std.testing.allocator,
        .{ .message = "{}", .method = methods.cancelled, .expects_response = false },
    ));
    stub.status = 200;
    stub.body = "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n";
    try std.testing.expectError(
        error.MissingMcpSseResponse,
        streamable.transport().send(std.testing.allocator, request),
    );

    const prefix = "data: ";
    const oversized = try std.testing.allocator.alloc(
        u8,
        prefix.len + json_limits.defaults.mcp_message.max_document_bytes + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memcpy(oversized[0..prefix.len], prefix);
    @memset(oversized[prefix.len..], '0');
    stub.body = oversized;
    try std.testing.expectError(
        error.McpMessageTooLarge,
        streamable.transport().send(std.testing.allocator, request),
    );
}

test "Streamable HTTP bounds concurrent in-flight requests" {
    const Stub = struct {
        io: std.Io,
        active: std.atomic.Value(usize) = .init(0),
        overlapped: std.atomic.Value(bool) = .init(false),

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.active.fetchAdd(1, .seq_cst) > 0) self.overlapped.store(true, .seq_cst);
            defer _ = self.active.fetchSub(1, .seq_cst);
            try sleepForTaskPoll(self.io, 10);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body, .{});
            defer parsed.deinit();
            return .{
                .status = 200,
                .body = try std.json.Stringify.valueAlloc(allocator, .{
                    .jsonrpc = "2.0",
                    .id = (try requiredObject(parsed.value)).get("id").?,
                    .result = .{},
                }, .{}),
            };
        }
    };
    const Worker = struct {
        fn send(transport_value: Transport, allocator: std.mem.Allocator, id: u8) !void {
            const message = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"server/discover\"}}",
                .{id},
            );
            defer allocator.free(message);
            const response = try transport_value.send(allocator, .{
                .message = message,
                .method = methods.discover,
            });
            allocator.free(response);
        }
    };

    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    const allocator = std.heap.smp_allocator;

    var parallel_stub = Stub{ .io = io };
    var parallel = StreamableHttpTransport.initWithOptions(
        io,
        .{ .context = &parallel_stub, .sendFn = Stub.send },
        "https://example.test/mcp",
        .{ .max_in_flight = 2 },
    );
    var first = try io.concurrent(Worker.send, .{ parallel.transport(), allocator, 1 });
    var second = try io.concurrent(Worker.send, .{ parallel.transport(), allocator, 2 });
    try first.await(io);
    try second.await(io);
    try std.testing.expect(parallel_stub.overlapped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), parallel_stub.active.load(.seq_cst));

    var serial_stub = Stub{ .io = io };
    var serial = StreamableHttpTransport.initWithOptions(
        io,
        .{ .context = &serial_stub, .sendFn = Stub.send },
        "https://example.test/mcp",
        .{ .max_in_flight = 1 },
    );
    var third = try io.concurrent(Worker.send, .{ serial.transport(), allocator, 3 });
    var fourth = try io.concurrent(Worker.send, .{ serial.transport(), allocator, 4 });
    try third.await(io);
    try fourth.await(io);
    try std.testing.expect(!serial_stub.overlapped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), serial_stub.active.load(.seq_cst));

    var invalid = StreamableHttpTransport.initWithOptions(
        io,
        .{ .context = &serial_stub, .sendFn = Stub.send },
        "https://example.test/mcp",
        .{ .max_in_flight = 0 },
    );
    try std.testing.expectError(
        error.InvalidMcpTransportConfiguration,
        Worker.send(invalid.transport(), std.testing.allocator, 5),
    );
}

test "generic client helpers cover every core request shape" {
    const Stub = struct {
        calls: usize = 0,
        notifications: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (!request.expects_response) {
                self.notifications += 1;
                return allocator.alloc(u8, 0);
            }
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.message, .{});
            defer parsed.deinit();
            const id = (try requiredObject(parsed.value)).get("id").?;
            const result_source = if (std.mem.eql(u8, request.method, methods.discover))
                "{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":0,\"cacheScope\":\"public\"}"
            else if (std.mem.eql(u8, request.method, methods.list_tools))
                "{\"resultType\":\"complete\",\"tools\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_resources))
                "{\"resultType\":\"complete\",\"resources\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_resource_templates))
                "{\"resultType\":\"complete\",\"resourceTemplates\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.read_resource))
                "{\"resultType\":\"complete\",\"contents\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.list_prompts))
                "{\"resultType\":\"complete\",\"prompts\":[],\"ttlMs\":0,\"cacheScope\":\"private\"}"
            else if (std.mem.eql(u8, request.method, methods.get_prompt))
                "{\"resultType\":\"complete\",\"messages\":[]}"
            else if (std.mem.eql(u8, request.method, methods.complete))
                "{\"resultType\":\"complete\",\"completion\":{\"values\":[]}}"
            else if (std.mem.eql(u8, request.method, methods.listen))
                "{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}"
            else
                "{\"resultType\":\"complete\"}";
            const result = try std.json.parseFromSlice(std.json.Value, allocator, result_source, .{});
            defer result.deinit();
            return std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = id,
                .result = result.value,
            }, .{});
        }
        fn event(_: *anyopaque, _: []const u8) !void {}
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    const calls = [_][]u8{
        try client.discover(std.testing.allocator),
        try client.listTools(std.testing.allocator, "next"),
        try client.listResources(std.testing.allocator, null),
        try client.listResourceTemplates(std.testing.allocator, "next"),
        try client.readResource(std.testing.allocator, "file:///tmp/a"),
        try client.listPrompts(std.testing.allocator, null),
        try client.getPrompt(std.testing.allocator, .{ .name = "review" }),
        try client.complete(
            std.testing.allocator,
            .{
                .reference = .{ .prompt = "review" },
                .argument_name = "language",
                .argument_value = "z",
            },
        ),
        try client.listen(
            std.testing.allocator,
            .{ .tools_list_changed = true },
            .{ .context = &stub, .eventFn = Stub.event },
        ),
    };
    defer for (calls) |value| std.testing.allocator.free(value);
    try client.cancel(std.testing.allocator, .{ .integer = 9 }, "done");
    try client.notify(std.testing.allocator, "com.example/changed", "{}");
    try std.testing.expectEqual(@as(usize, 2), stub.notifications);
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "bad", "[]"),
    );
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        client.callTool(std.testing.allocator, "bad", "{"),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        client.notify(std.testing.allocator, "bad", "{"),
    );
    try std.testing.expectError(
        error.InvalidMcpMessage,
        client.notify(std.testing.allocator, "bad", "[]"),
    );
    try Stub.event(&stub, "{}");

    var no_handler = Client{ .transport = .{ .context = &stub, .sendFn = struct {
        fn send(_: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            return allocator.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"confirm\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Confirm\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}}}}",
            );
        }
    }.send }, .capabilities_json = "{\"elicitation\":{}}" };
    try std.testing.expectError(
        error.InputRequired,
        no_handler.request(std.testing.allocator, methods.call_tool, "{\"name\":\"confirm\"}"),
    );
    no_handler.max_round_trips = 0;
    try std.testing.expectError(
        error.TooManyMcpRoundTrips,
        no_handler.request(std.testing.allocator, methods.call_tool, "{\"name\":\"confirm\"}"), // kcov-ignore
    );
}

test "toolset paginates, mirrors headers, and renders rich results" {
    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return switch (self.calls) {
                1 => allocator.dupe(
                    u8,
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"weather\",\"description\":\"Weather\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"x-mcp-header\":\"City\"}}}}],\"nextCursor\":\"two\",\"ttlMs\":0,\"cacheScope\":\"private\"}}",
                ),
                2 => allocator.dupe(
                    u8,
                    blk: {
                        try std.testing.expect(std.mem.indexOf(u8, request.message, "\"cursor\":\"two\"") != null);
                        break :blk "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"invalid\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"object\",\"x-mcp-header\":\"X\"}}}}],\"ttlMs\":0,\"cacheScope\":\"private\"}}";
                    },
                ),
                3 => blk: {
                    try std.testing.expectEqualStrings("Madrid", findHeader(request.headers, "mcp-param-city").?);
                    break :blk allocator.dupe(
                        u8,
                        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"sunny\"},{\"type\":\"image\",\"data\":\"abc\",\"mimeType\":\"image/png\"}]}}",
                    );
                },
                else => error.InvalidMcpResponse,
            };
        }
    };
    var stub: Stub = .{};
    var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try client.toolset().prepare(arena.allocator(), .{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    });
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const output = try tools[0].tool.execute(std.testing.allocator, "{\"city\":\"Madrid\"}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "sunny") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "image") != null);
}

test "tool pagination rejects cursor cycles and page exhaustion" {
    const Stub = struct {
        calls: usize = 0,
        fn send(context: *anyopaque, allocator: std.mem.Allocator, _: WireRequest) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\"," ++
                    "\"tools\":[],\"nextCursor\":\"same\",\"ttlMs\":0,\"cacheScope\":\"private\"}}}}",
                .{self.calls},
            );
        }
    };
    const context = agent.ToolsetContext{
        .messages = &.{},
        .usage = .{},
        .model_requests = 0,
        .dependencies = null,
    };
    var cycle_stub: Stub = .{};
    var cycle_client = Client{ .transport = .{ .context = &cycle_stub, .sendFn = Stub.send } };
    try std.testing.expectError(
        error.McpPaginationCursorCycle,
        cycle_client.toolset().prepare(std.testing.allocator, context),
    );
    try std.testing.expectEqual(@as(usize, 2), cycle_stub.calls);

    var limited_stub: Stub = .{};
    var limited_client = Client{
        .transport = .{ .context = &limited_stub, .sendFn = Stub.send },
        .max_pages = 1,
    };
    try std.testing.expectError(
        error.TooManyMcpPages,
        limited_client.toolset().prepare(std.testing.allocator, context),
    );
    try std.testing.expectEqual(@as(usize, 1), limited_stub.calls);

    var disabled_stub: Stub = .{};
    var disabled_client = Client{
        .transport = .{ .context = &disabled_stub, .sendFn = Stub.send },
        .max_pages = 0,
    };
    try std.testing.expectError(
        error.TooManyMcpPages,
        disabled_client.toolset().prepare(std.testing.allocator, context),
    );
    try std.testing.expectEqual(@as(usize, 0), disabled_stub.calls);
}

test "tool pagination releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const Stub = struct {
                calls: usize = 0,
                fn send(context: *anyopaque, inner: std.mem.Allocator, _: WireRequest) ![]const u8 {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.calls += 1;
                    return std.fmt.allocPrint(
                        inner,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[],{s}" ++
                            "\"ttlMs\":0,\"cacheScope\":\"private\"}}}}",
                        .{ self.calls, if (self.calls == 1) "\"nextCursor\":\"two\"," else "" },
                    );
                }
            };
            var stub: Stub = .{};
            var client = Client{ .transport = .{ .context = &stub, .sendFn = Stub.send } };
            const tools = try client.toolset().prepare(allocator, .{
                .messages = &.{},
                .usage = .{},
                .model_requests = 0,
                .dependencies = null,
            });
            allocator.free(tools);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "server returns specified errors and validates tool parameter headers" {
    const Handler = struct {
        fail: bool = false,
        fn handle(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.Failed;
            return allocator.dupe(u8, "{\"content\":[]}");
        }
        fn schema(_: *anyopaque, name: []const u8) ?[]const u8 {
            if (!std.mem.eql(u8, name, "weather")) return null;
            return "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"x-mcp-header\":\"City\"}}}";
        }
    };
    var handler: Handler = .{};
    var server = Server{
        .handler = .{ .context = &handler, .handleFn = Handler.handle },
        .capabilities_json = "{\"tools\":{}}",
        .tool_schemas = .{ .context = &handler, .schemaFn = Handler.schema },
    };
    const invalid_json = try server.handle(std.testing.allocator, "{", null);
    defer invalid_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_json.status);
    const invalid_rpc = try server.handle(std.testing.allocator, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}", null);
    defer invalid_rpc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_rpc.status);
    const missing_meta = try server.handle(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{}}", null);
    defer missing_meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), missing_meta.status);
    const invalid_request_params = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":[]}",
        null,
    );
    defer invalid_request_params.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_request_params.status);
    const invalid_meta = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"_meta\":{" ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"bad key\":true}}}",
        null,
    );
    defer invalid_meta.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, invalid_meta.body.?, "Invalid request metadata") != null);
    const missing_capabilities = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"_meta\":{" ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
        null,
    );
    defer missing_capabilities.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, missing_capabilities.body.?, "Missing client capabilities") != null);
    const legacy_initialize = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
        null,
    );
    defer legacy_initialize.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), legacy_initialize.status);
    try std.testing.expect(std.mem.indexOf(u8, legacy_initialize.body.?, protocol_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, legacy_initialize.body.?, "-32601") != null);
    const wrong_version = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"old\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
        null,
    );
    defer wrong_version.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, wrong_version.body.?, "-32022") != null);

    const call = try buildRequest(
        std.testing.allocator,
        1,
        methods.call_tool,
        "{\"name\":\"weather\",\"arguments\":{\"city\":\"Madrid\"}}",
        "test",
        "1",
        "{}",
    );
    defer std.testing.allocator.free(call);
    const headers = [_]http.Header{
        .{ .name = "MCP-Protocol-Version", .value = protocol_version },
        .{ .name = "Mcp-Method", .value = methods.call_tool },
        .{ .name = "Mcp-Name", .value = "weather" },
        .{ .name = "Mcp-Param-City", .value = "Madrid" },
    };
    const ok = try server.handle(std.testing.allocator, call, .{ .headers = &headers });
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    const mismatch = try server.handle(std.testing.allocator, call, .{ .headers = headers[0..3] });
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), mismatch.status);

    const notification =
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}";
    const accepted = try server.handle(std.testing.allocator, notification, null);
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
    const invalid_notification = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}",
        null,
    );
    defer invalid_notification.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), invalid_notification.status);
    try std.testing.expect(invalid_notification.body == null);
    const invalid_notification_params = try server.handle(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":[]}",
        null,
    );
    defer invalid_notification_params.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), invalid_notification_params.status);
    try std.testing.expect(invalid_notification_params.body == null);
    const invalid_notification_headers = try server.handle(
        std.testing.allocator,
        notification,
        .{ .headers = &.{} },
    );
    defer invalid_notification_headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_notification_headers.status);
    try std.testing.expect(invalid_notification_headers.body == null);
    handler.fail = true;
    const ignored_failure = try server.handle(std.testing.allocator, notification, null);
    defer ignored_failure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), ignored_failure.status);
    const failed = try server.handle(std.testing.allocator, call, null);
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 500), failed.status);
}

test "header schemas cover primitives, invalid definitions, and mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invalid_schemas = [_][]const u8{
        "{\"properties\":{\"x\":{\"type\":\"object\",\"x-mcp-header\":\"X\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"bad name\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"X\"},\"y\":{\"type\":\"string\",\"x-mcp-header\":\"x\"}}}",
    };
    for (invalid_schemas) |schema| {
        try std.testing.expect(!validToolHeaderSchema(try parseResponse(arena.allocator(), schema)));
    }
    const schema =
        "{\"properties\":{" ++
        "\"integer\":{\"type\":\"integer\",\"x-mcp-header\":\"Integer\"}," ++
        "\"number\":{\"type\":\"number\",\"x-mcp-header\":\"Number\"}," ++
        "\"boolean\":{\"type\":\"boolean\",\"x-mcp-header\":\"Boolean\"}," ++
        "\"sentinel\":{\"type\":\"string\",\"x-mcp-header\":\"Sentinel\"}}}";
    const arguments = try parseResponse(
        arena.allocator(),
        "{\"integer\":42,\"number\":1.5,\"boolean\":true,\"sentinel\":\"=?base64?x?=\"}",
    );
    const headers = try toolArgumentHeaders(arena.allocator(), schema, arguments);
    try std.testing.expectEqual(@as(usize, 4), headers.len);
    try std.testing.expect(std.mem.startsWith(u8, headers[3].value, "=?base64?"));
    const non_ascii = try encodeHeaderValue(arena.allocator(), "\x7f");
    try std.testing.expect(std.mem.startsWith(u8, non_ascii, "=?base64?"));
    const too_large = std.json.Value{ .integer = 9_007_199_254_740_992 };
    try std.testing.expectError(
        error.InvalidMcpToolArguments,
        primitiveHeaderValue(arena.allocator(), too_large),
    );

    const params = try requiredObject(try parseResponse(
        arena.allocator(),
        "{\"arguments\":{\"integer\":42,\"number\":1.5,\"boolean\":true,\"sentinel\":\"=?base64?x?=\"}}",
    ));
    try std.testing.expect(try validateToolHeaders(arena.allocator(), headers, schema, params));
    try std.testing.expect(!try validateToolHeaders(arena.allocator(), headers[0..3], schema, params));
    const absent_params = try requiredObject(try parseResponse(arena.allocator(), "{\"arguments\":{}}"));
    try std.testing.expect(!try validateToolHeaders(arena.allocator(), headers, schema, absent_params));

    try std.testing.expectEqualStrings("file:///a", routingName(
        methods.read_resource,
        try requiredObject(try parseResponse(arena.allocator(), "{\"uri\":\"file:///a\"}")),
    ).?);
    try std.testing.expect(routingName("custom/method", std.json.ObjectMap{}) == null);
    try std.testing.expect(findHeader(&.{}, "missing") == null);

    try std.testing.expectError(error.InvalidMcpMessage, buildRequest(
        std.testing.allocator,
        1,
        "x",
        "{}",
        "client",
        "1",
        "{",
    ));
}

test "JSON-RPC string ids and tool result variants are preserved" {
    const id = try JsonRpcId.parse(std.testing.allocator, "{\"id\":\"request-1\"}");
    defer id.deinit(std.testing.allocator);
    try std.testing.expect(id.matches(.{ .string = "request-1" }));
    try std.testing.expect(!id.matches(.{ .integer = 1 }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]struct { json: []const u8, expected: []const u8 }{
        .{ .json = "{\"isError\":true,\"content\":[42]}", .expected = "MCP tool error: 42" },
        .{ .json = "{\"structuredContent\":{\"ok\":true}}", .expected = "{\"ok\":true}" },
    };
    for (values) |value| {
        const rendered = try renderToolResult(
            std.testing.allocator,
            try requiredObject(try parseResponse(arena.allocator(), value.json)),
        );
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(value.expected, rendered);
    }
    try std.testing.expectError(error.InvalidMcpResponse, renderToolResult(
        std.testing.allocator,
        try requiredObject(try parseResponse(arena.allocator(), "{\"content\":false}")),
    ));
}

test "stdio transport filters interleaved modern and legacy messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\read -r line
        \\printf '%s\n' '1'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"legacy/request"}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":0}}'
        \\printf '%s\n' '{}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":999,"result":{}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":"request-1","result":{}}'
        \\read -r rejection
    ;
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var events: Events = .{};
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    const response = try stdio.transport().send(std.testing.allocator, .{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":\"request-1\",\"method\":\"server/discover\"}",
        .method = methods.discover,
        .events = .{ .context = &events, .eventFn = Events.emit },
    });
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), events.count);
}

test "stdio subscription filters invalid and pre-acknowledgement events" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\read -r line
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
    ;
    const Events = struct {
        count: usize = 0,
        fn emit(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var events: Events = .{};
    var stdio = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", script });
    defer stdio.deinit();
    const response = try stdio.transport().send(std.testing.allocator, .{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\",\"params\":{" ++
            "\"notifications\":{\"toolsListChanged\":true},\"_meta\":{" ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
            "\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
        .method = methods.listen,
        .events = .{ .context = &events, .eventFn = Events.emit },
    });
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 2), events.count);
}

test "stdio transport releases malformed and partial messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const request = WireRequest{
        .message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        .method = methods.discover,
    };
    const malformed_script =
        \\read -r line
        \\printf '%s\n' 'not-json'
    ;
    var malformed = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", malformed_script });
    defer malformed.deinit();
    try std.testing.expectError(
        error.InvalidMcpMessage,
        malformed.transport().send(std.testing.allocator, request),
    );

    const partial_script =
        \\read -r line
        \\printf 'partial'
    ;
    var partial = try StdioTransport.init(std.testing.io, &.{ "/bin/sh", "-c", partial_script });
    defer partial.deinit();
    try std.testing.expectError(
        error.EndOfStream,
        partial.transport().send(std.testing.allocator, request),
    );
}

fn fuzzSseAndJsonRpcFraming(_: void, smith: *std.testing.Smith) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    const response = extractSseResponse(
        std.testing.allocator,
        value,
        "{\"id\":1}",
        methods.discover,
        null,
    ) catch return;
    std.testing.allocator.free(response);
}

test "fuzz MCP SSE and JSON-RPC framing" {
    try std.testing.fuzz({}, fuzzSseAndJsonRpcFraming, .{ .corpus = &.{
        "\x1e\x00\x00\x00data: {\"jsonrpc\":\"2.0\",\"id\":1}\n",
    } });
}
