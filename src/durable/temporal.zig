//! Temporal adapter backed by the ZigAI Temporal sidecar protocol.
//!
//! Temporal has no official Zig SDK. This adapter therefore talks to a small
//! sidecar built on the official Temporal SDK. The sidecar owns workflow and
//! activity registration; this module remains dependency-free and implements
//! the ordinary `durable.Runtime` boundary.

const std = @import("std");
const durable = @import("../durable.zig");
const transport = @import("../transport.zig");

pub const protocol_version: u8 = 1;
pub const execute_path = "/v1/execute";
pub const workflow_name = "zigai.operation.v1";
pub const activity_name = "zigai.execute.v1";
pub const default_max_input_bytes: usize = 1024 * 1024;

pub const Error = error{
    InvalidConfiguration,
    MissingRegistration,
    InputTooLarge,
    RequestTooLarge,
    ResponseTooLarge,
    GatewayRejected,
};

/// One handler that must be registered by the Temporal activity worker.
pub const Registration = struct {
    kind: durable.OperationKind,
    handler_id: []const u8,
};

/// Temporal activity retry settings. Millesimal coefficients avoid floating-
/// point values in persisted workflow input (`2000` means `2.0`).
pub const RetryPolicy = struct {
    initial_interval_ms: u64 = 1_000,
    backoff_coefficient_milli: u32 = 2_000,
    maximum_interval_ms: u64 = 60_000,
    maximum_attempts: u32 = 5,

    pub fn validate(self: RetryPolicy) Error!void {
        if (self.initial_interval_ms == 0 or
            self.backoff_coefficient_milli < 1_000 or
            self.maximum_interval_ms < self.initial_interval_ms or
            self.maximum_attempts == 0)
            return Error.InvalidConfiguration;
    }
};

/// Borrowed deployment configuration. The sidecar token is sent only as a
/// sensitive HTTP header and is never included in Temporal workflow input.
pub const Options = struct {
    endpoint: []const u8,
    namespace: []const u8 = "default",
    task_queue: []const u8,
    registrations: []const Registration,
    bearer_token: ?[]const u8 = null,
    start_to_close_timeout_ms: u64 = 300_000,
    schedule_to_close_timeout_ms: u64 = 900_000,
    heartbeat_timeout_ms: ?u64 = null,
    retry: RetryPolicy = .{},
    max_input_bytes: usize = default_max_input_bytes,
    request_timeout_ms: u64 = 920_000,

    pub fn validate(self: Options, allocator: std.mem.Allocator) !void {
        if (self.endpoint.len == 0 or
            !validName(self.namespace) or
            !validName(self.task_queue) or
            self.registrations.len == 0 or
            (self.bearer_token != null and self.bearer_token.?.len == 0) or
            self.max_input_bytes == 0 or
            self.max_input_bytes > durable.max_payload_bytes or
            self.start_to_close_timeout_ms == 0 or
            self.schedule_to_close_timeout_ms < self.start_to_close_timeout_ms or
            self.request_timeout_ms < self.schedule_to_close_timeout_ms or
            (self.heartbeat_timeout_ms != null and
                (self.heartbeat_timeout_ms.? == 0 or
                    self.heartbeat_timeout_ms.? > self.start_to_close_timeout_ms)))
            return Error.InvalidConfiguration;
        try self.retry.validate();
        for (self.registrations, 0..) |registration, index| {
            try validateRegistration(allocator, registration);
            for (self.registrations[0..index]) |previous| {
                if (previous.kind == registration.kind and
                    std.mem.eql(u8, previous.handler_id, registration.handler_id))
                    return Error.InvalidConfiguration;
            }
        }
    }

    fn contains(self: Options, invocation: durable.Invocation) bool {
        for (self.registrations) |registration| {
            if (registration.kind == invocation.kind and
                std.mem.eql(u8, registration.handler_id, invocation.handler_id))
                return true;
        }
        return false;
    }
};

/// Concrete `durable.Runtime` implementation for the Temporal sidecar.
/// Keep this value alive for as long as the returned runtime is in use.
pub const Adapter = struct {
    http: transport.Transport,
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        http: transport.Transport,
        options: Options,
    ) !Adapter {
        try options.validate(allocator);
        return .{ .http = http, .options = options };
    }

    pub fn runtime(self: *Adapter) durable.Runtime {
        return .{ .context = self, .executeFn = execute };
    }

    fn execute(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        invocation: durable.Invocation,
    ) !durable.OwnedRecord {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (!self.options.contains(invocation)) return Error.MissingRegistration;
        if (invocation.input_json.len > self.options.max_input_bytes)
            return Error.InputTooLarge;

        const url = try joinEndpoint(allocator, self.options.endpoint);
        defer allocator.free(url);
        const body = try stringifyRequest(allocator, self.options, invocation);
        defer allocator.free(body);
        if (body.len > durable.max_payload_bytes) return Error.RequestTooLarge;

        var headers: [3]transport.Header = undefined;
        var header_count: usize = 2;
        headers[0] = .{ .name = "content-type", .value = "application/json" };
        headers[1] = .{ .name = "accept", .value = "application/json" };
        if (self.options.bearer_token) |token| {
            headers[2] = .{
                .name = "authorization",
                .value = token,
                .sensitive = true,
            };
            header_count += 1;
        }
        const response = try self.http.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = headers[0..header_count],
            .body = body,
            .timeout_ms = self.options.request_timeout_ms,
        });
        defer allocator.free(response.body);
        if (response.status != 200) return Error.GatewayRejected;
        if (response.body.len > durable.max_record_bytes) return Error.ResponseTooLarge;
        return durable.parseRecord(allocator, response.body);
    }
};

fn validateRegistration(
    allocator: std.mem.Allocator,
    registration: Registration,
) !void {
    try (durable.Invocation{
        .run_id = "registration",
        .step_id = "registration",
        .sequence = 0,
        .kind = registration.kind,
        .handler_id = registration.handler_id,
        .input_json = "{}",
    }).validate(allocator);
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > durable.max_identifier_bytes) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or
        byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}

fn joinEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, endpoint, execute_path))
        return allocator.dupe(u8, endpoint);
    if (std.mem.endsWith(u8, endpoint, "/"))
        return std.fmt.allocPrint(allocator, "{s}{s}", .{
            endpoint[0 .. endpoint.len - 1],
            execute_path,
        });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ endpoint, execute_path });
}

fn stringifyRequest(
    allocator: std.mem.Allocator,
    options: Options,
    invocation: durable.Invocation,
) ![]u8 {
    const stable_key = try invocation.stableKey(allocator);
    defer allocator.free(stable_key);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(protocol_version);
    try json.objectField("namespace");
    try json.write(options.namespace);
    try json.objectField("task_queue");
    try json.write(options.task_queue);
    try json.objectField("workflow_name");
    try json.write(workflow_name);
    try json.objectField("activity_name");
    try json.write(activity_name);
    try json.objectField("workflow_id");
    try json.write(stable_key);
    try json.objectField("invocation");
    try json.beginObject();
    try json.objectField("run_id");
    try json.write(invocation.run_id);
    try json.objectField("step_id");
    try json.write(invocation.step_id);
    try json.objectField("sequence");
    try json.write(invocation.sequence);
    try json.objectField("kind");
    try json.write(@tagName(invocation.kind));
    try json.objectField("handler_id");
    try json.write(invocation.handler_id);
    try json.objectField("input_json");
    try json.write(invocation.input_json);
    try json.endObject();
    try json.objectField("activity");
    try json.beginObject();
    try json.objectField("start_to_close_timeout_ms");
    try json.write(options.start_to_close_timeout_ms);
    try json.objectField("schedule_to_close_timeout_ms");
    try json.write(options.schedule_to_close_timeout_ms);
    try json.objectField("heartbeat_timeout_ms");
    try json.write(options.heartbeat_timeout_ms);
    try json.objectField("retry");
    try json.beginObject();
    try json.objectField("initial_interval_ms");
    try json.write(options.retry.initial_interval_ms);
    try json.objectField("backoff_coefficient_milli");
    try json.write(options.retry.backoff_coefficient_milli);
    try json.objectField("maximum_interval_ms");
    try json.write(options.retry.maximum_interval_ms);
    try json.objectField("maximum_attempts");
    try json.write(options.retry.maximum_attempts);
    try json.endObject();
    try json.endObject();
    try json.endObject();
    return output.toOwnedSlice();
}

const TestGateway = struct {
    expected: durable.Invocation,
    status: u16 = 200,
    malformed: bool = false,
    calls: usize = 0,

    fn send(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: transport.Request,
    ) !transport.Response {
        const self: *TestGateway = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqual(transport.Method.POST, request.method);
        try std.testing.expectEqualStrings("https://temporal.example/v1/execute", request.url);
        try std.testing.expectEqual(@as(?u64, 920_000), request.timeout_ms);
        try std.testing.expect(request.headers.len == 2 or request.headers.len == 3);
        if (request.headers.len == 3) {
            try std.testing.expect(request.headers[2].isSensitive());
            try std.testing.expectEqualStrings("[REDACTED]", request.headers[2].redactedValue());
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "durable/model.request/7",
            parsed.value.object.get("workflow_id").?.string,
        );
        try std.testing.expectEqualStrings(
            workflow_name,
            parsed.value.object.get("workflow_name").?.string,
        );
        try std.testing.expectEqualStrings(
            self.expected.input_json,
            parsed.value.object.get("invocation").?.object.get("input_json").?.string,
        );
        if (self.malformed)
            return .{ .status = self.status, .body = try allocator.dupe(u8, "{}") };
        return .{
            .status = self.status,
            .body = try durable.stringifyRecord(
                allocator,
                durable.Record.init(self.expected, .{ .success = "{\"ok\":true}" }),
            ),
        };
    }
};

test "Temporal adapter sends registered invocations through its sidecar" {
    const invocation = durable.Invocation{
        .run_id = "durable",
        .step_id = "model.request",
        .sequence = 7,
        .kind = .model_request,
        .handler_id = "support-model",
        .input_json = "{\"prompt\":\"hello\"}",
    };
    var gateway = TestGateway{ .expected = invocation };
    var adapter = try Adapter.init(std.testing.allocator, .{
        .context = &gateway,
        .sendFn = TestGateway.send,
    }, .{
        .endpoint = "https://temporal.example/",
        .task_queue = "zigai-agents",
        .registrations = &.{.{
            .kind = .model_request,
            .handler_id = "support-model",
        }},
        .bearer_token = "Bearer secret",
    });
    var record = try adapter.runtime().execute(std.testing.allocator, invocation);
    defer record.deinit();
    try std.testing.expectEqualStrings(
        "{\"ok\":true}",
        try durable.successPayload(&record),
    );
    try std.testing.expectEqual(@as(usize, 1), gateway.calls);
}

test "Temporal adapter validates deployment policy before transport" {
    const registration = Registration{
        .kind = .tool_call,
        .handler_id = "tool-worker",
    };
    const valid = Options{
        .endpoint = "https://temporal.example/v1/execute",
        .task_queue = "zigai",
        .registrations = &.{registration},
    };
    try valid.validate(std.testing.allocator);
    try (RetryPolicy{}).validate();

    var invalid = valid;
    invalid.endpoint = "";
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.namespace = "bad/name";
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.task_queue = "";
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.registrations = &.{};
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.bearer_token = "";
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.max_input_bytes = 0;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.max_input_bytes = durable.max_payload_bytes + 1;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.start_to_close_timeout_ms = 0;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.schedule_to_close_timeout_ms = 1;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.request_timeout_ms = 1;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.heartbeat_timeout_ms = 0;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.heartbeat_timeout_ms = invalid.start_to_close_timeout_ms + 1;
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.registrations = &.{ registration, registration };
    try std.testing.expectError(Error.InvalidConfiguration, invalid.validate(std.testing.allocator));
    invalid = valid;
    invalid.registrations = &.{.{ .kind = .tool_call, .handler_id = "bad/id" }};
    try std.testing.expectError(durable.Error.InvalidInvocation, invalid.validate(std.testing.allocator));

    var retry = RetryPolicy{ .initial_interval_ms = 0 };
    try std.testing.expectError(Error.InvalidConfiguration, retry.validate());
    retry = .{ .backoff_coefficient_milli = 999 };
    try std.testing.expectError(Error.InvalidConfiguration, retry.validate());
    retry = .{ .initial_interval_ms = 2, .maximum_interval_ms = 1 };
    try std.testing.expectError(Error.InvalidConfiguration, retry.validate());
    retry = .{ .maximum_attempts = 0 };
    try std.testing.expectError(Error.InvalidConfiguration, retry.validate());
}

test "Temporal adapter rejects missing routes, large inputs, and bad responses" {
    const invocation = durable.Invocation{
        .run_id = "durable",
        .step_id = "model.request",
        .sequence = 7,
        .kind = .model_request,
        .handler_id = "support-model",
        .input_json = "{}",
    };
    var gateway = TestGateway{ .expected = invocation };
    const http = transport.Transport{ .context = &gateway, .sendFn = TestGateway.send };
    var adapter = try Adapter.init(std.testing.allocator, http, .{
        .endpoint = "https://temporal.example",
        .task_queue = "zigai",
        .registrations = &.{.{ .kind = .tool_call, .handler_id = "tools" }},
    });
    try std.testing.expectError(
        Error.MissingRegistration,
        adapter.runtime().execute(std.testing.allocator, invocation),
    );
    adapter.options.registrations = &.{.{ .kind = .model_request, .handler_id = "support-model" }};
    adapter.options.max_input_bytes = 1;
    try std.testing.expectError(
        Error.InputTooLarge,
        adapter.runtime().execute(std.testing.allocator, invocation),
    );
    adapter.options.max_input_bytes = default_max_input_bytes;
    gateway.status = 503;
    try std.testing.expectError(
        Error.GatewayRejected,
        adapter.runtime().execute(std.testing.allocator, invocation),
    );
    gateway.status = 200;
    gateway.malformed = true;
    try std.testing.expectError(
        durable.Error.InvalidRecord,
        adapter.runtime().execute(std.testing.allocator, invocation),
    );
}

test "Temporal endpoint joining accepts full, base, and slash forms" {
    const values = [_]struct { []const u8, []const u8 }{
        .{ "https://one.example/v1/execute", "https://one.example/v1/execute" },
        .{ "https://two.example", "https://two.example/v1/execute" },
        .{ "https://three.example/", "https://three.example/v1/execute" },
    };
    for (values) |value| {
        const joined = try joinEndpoint(std.testing.allocator, value[0]);
        defer std.testing.allocator.free(joined);
        try std.testing.expectEqualStrings(value[1], joined);
    }
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("bad/name"));
    try std.testing.expect(validName("good-name_1.example"));
}

test "Temporal adapter enforces complete request and response limits" {
    const OversizedGateway = struct {
        fn send(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: transport.Request,
        ) !transport.Response {
            const body = try allocator.alloc(u8, durable.max_record_bytes + 1);
            @memset(body, ' ');
            return .{ .status = 200, .body = body };
        }
    };
    var unused: u8 = 0;
    const registration = Registration{
        .kind = .model_request,
        .handler_id = "model",
    };
    var adapter = try Adapter.init(std.testing.allocator, .{
        .context = &unused,
        .sendFn = OversizedGateway.send,
    }, .{
        .endpoint = "https://temporal.example",
        .task_queue = "zigai",
        .registrations = &.{registration},
        .max_input_bytes = durable.max_payload_bytes,
    });
    const ordinary = durable.Invocation{
        .run_id = "run",
        .step_id = "model",
        .sequence = 1,
        .kind = .model_request,
        .handler_id = "model",
        .input_json = "{}",
    };
    try std.testing.expectError(
        Error.ResponseTooLarge,
        adapter.runtime().execute(std.testing.allocator, ordinary),
    );

    const input_len = 1_100_002;
    const input = try std.testing.allocator.alloc(u8, input_len);
    defer std.testing.allocator.free(input);
    input[0] = '"';
    input[input.len - 1] = '"';
    var index: usize = 1;
    while (index < input.len - 1) : (index += 2) {
        input[index] = '\\';
        input[index + 1] = '\\';
    }
    var large = ordinary;
    large.input_json = input;
    try std.testing.expectError(
        Error.RequestTooLarge,
        adapter.runtime().execute(std.testing.allocator, large),
    );
}
