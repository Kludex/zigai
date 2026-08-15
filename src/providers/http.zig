//! Authenticated HTTP provider shared by model wire adapters.

const std = @import("std");
const model = @import("../model.zig");
const provider_types = @import("../provider.zig");
const transport = @import("../transport.zig");
const common = @import("common.zig");

pub const Error = error{
    InvalidProviderCredential,
    InvalidProviderEndpoint,
    InvalidProviderHeader,
    ProviderHeaderConflict,
};

pub const Credential = union(enum) {
    none,
    bearer: []const u8,
    header: Header,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
        prefix: []const u8 = "",
    };

    fn secret(self: Credential) ?[]const u8 {
        return switch (self) {
            .none => null,
            .bearer => |value| value,
            .header => |value| value.value,
        };
    }
};

/// Borrowed authenticated HTTP provider. It never copies credentials and must
/// outlive every interface or model created from it.
pub const Configured = struct {
    name: []const u8,
    base_url: []const u8,
    transport: transport.Transport,
    credential: Credential = .none,
    headers: []const transport.Header = &.{},
    request_policy: provider_types.RequestPolicy = .{},
    file_limits: provider_types.FileLimits = .{},
    model_profiles: ?ModelProfiles = null,
    operations: ?Operations = null,

    pub const ModelProfiles = struct {
        context: *anyopaque,
        lookupFn: ?*const fn (*anyopaque, []const u8) ?model.ModelProfile = null,
        overrideFn: ?*const fn (*anyopaque, []const u8, model.ModelProfile) model.ModelProfile = null,
    };

    /// Provider-specific non-inference operations. The authenticated HTTP
    /// provider forwards these callbacks without exposing credentials to them.
    pub const Operations = struct {
        context: *anyopaque,
        listModelsFn: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!provider_types.OwnedModels = null,
        uploadFileFn: ?*const fn (*anyopaque, std.mem.Allocator, provider_types.FileInput) anyerror!provider_types.OwnedFile = null,
        inspectFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!provider_types.OwnedFile = null,
        downloadFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!provider_types.OwnedFileDownload = null,
        deleteFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!void = null,
    };

    pub fn provider(self: *Configured) provider_types.Provider {
        return .{
            .context = self,
            .name = self.name,
            .base_url = self.base_url,
            .request_policy = self.request_policy,
            .file_limits = self.file_limits,
            .requestFn = request,
            .streamLinesFn = streamLines,
            .modelProfileFn = if (self.model_profiles != null) modelProfile else null,
            .overrideProfileFn = if (self.model_profiles != null) overrideProfile else null,
            .observeErrorFn = observeError,
            .listModelsFn = if (hasOperation(self, .list_models)) listModels else null,
            .uploadFileFn = if (hasOperation(self, .upload_file)) uploadFile else null,
            .inspectFileFn = if (hasOperation(self, .inspect_file)) inspectFile else null,
            .downloadFileFn = if (hasOperation(self, .download_file)) downloadFile else null,
            .deleteFileFn = if (hasOperation(self, .delete_file)) deleteFile else null,
        };
    }

    const Operation = enum { list_models, upload_file, inspect_file, download_file, delete_file };

    fn hasOperation(self: *const Configured, operation: Operation) bool {
        const operations = self.operations orelse return false;
        return switch (operation) {
            .list_models => operations.listModelsFn != null,
            .upload_file => operations.uploadFileFn != null,
            .inspect_file => operations.inspectFileFn != null,
            .download_file => operations.downloadFileFn != null,
            .delete_file => operations.deleteFileFn != null,
        };
    }

    fn listModels(context: *anyopaque, allocator: std.mem.Allocator) !provider_types.OwnedModels {
        const self: *Configured = @ptrCast(@alignCast(context));
        const operations = self.operations orelse return error.UnsupportedProviderOperation;
        const list = operations.listModelsFn orelse return error.UnsupportedProviderOperation;
        return list(operations.context, allocator);
    }

    fn uploadFile(context: *anyopaque, allocator: std.mem.Allocator, input: provider_types.FileInput) !provider_types.OwnedFile {
        const self: *Configured = @ptrCast(@alignCast(context));
        const operations = self.operations orelse return error.UnsupportedProviderOperation;
        const upload = operations.uploadFileFn orelse return error.UnsupportedProviderOperation;
        return upload(operations.context, allocator, input);
    }

    fn inspectFile(context: *anyopaque, allocator: std.mem.Allocator, file: model.UploadedFile) !provider_types.OwnedFile {
        const self: *Configured = @ptrCast(@alignCast(context));
        const operations = self.operations orelse return error.UnsupportedProviderOperation;
        const inspect = operations.inspectFileFn orelse return error.UnsupportedProviderOperation;
        return inspect(operations.context, allocator, file);
    }

    fn downloadFile(context: *anyopaque, allocator: std.mem.Allocator, file: model.UploadedFile) !provider_types.OwnedFileDownload {
        const self: *Configured = @ptrCast(@alignCast(context));
        const operations = self.operations orelse return error.UnsupportedProviderOperation;
        const download = operations.downloadFileFn orelse return error.UnsupportedProviderOperation;
        return download(operations.context, allocator, file);
    }

    fn deleteFile(context: *anyopaque, allocator: std.mem.Allocator, file: model.UploadedFile) !void {
        const self: *Configured = @ptrCast(@alignCast(context));
        const operations = self.operations orelse return error.UnsupportedProviderOperation;
        const delete = operations.deleteFileFn orelse return error.UnsupportedProviderOperation;
        return delete(operations.context, allocator, file);
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: provider_types.Request) !transport.Response {
        const self: *Configured = @ptrCast(@alignCast(context));
        const prepared = try self.prepare(allocator, value);
        defer prepared.deinit(allocator);
        return self.transport.send(allocator, prepared.request);
    }

    fn streamLines(context: *anyopaque, allocator: std.mem.Allocator, value: provider_types.Request, sink: transport.LineSink) !transport.StreamResponse {
        const self: *Configured = @ptrCast(@alignCast(context));
        const prepared = try self.prepare(allocator, value);
        defer prepared.deinit(allocator);
        return self.transport.streamLines(allocator, prepared.request, sink);
    }

    fn modelProfile(context: *anyopaque, name: []const u8) ?model.ModelProfile {
        const self: *Configured = @ptrCast(@alignCast(context));
        const profiles = self.model_profiles orelse return null;
        const lookup = profiles.lookupFn orelse return null;
        return lookup(profiles.context, name);
    }

    fn overrideProfile(context: *anyopaque, name: []const u8, profile: model.ModelProfile) model.ModelProfile {
        const self: *Configured = @ptrCast(@alignCast(context));
        const profiles = self.model_profiles orelse return profile;
        const apply = profiles.overrideFn orelse return profile;
        return apply(profiles.context, name, profile);
    }

    fn observeError(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        status: u16,
        body: []const u8,
        metadata: transport.ResponseMetadata,
        observer: ?model.ProviderErrorObserver,
        policy: model.ProviderErrorPolicy,
    ) void {
        const self: *Configured = @ptrCast(@alignCast(context));
        const secret = self.credential.secret();
        const sensitive_values: []const []const u8 = if (secret) |value| &.{value} else &.{};
        common.notifyProviderError(allocator, observer, self.name, status, body, metadata, policy, sensitive_values);
    }

    const Prepared = struct {
        request: transport.Request,
        url: []u8,
        headers: []transport.Header,
        credential_value: ?[]u8,

        fn deinit(self: Prepared, allocator: std.mem.Allocator) void {
            if (self.credential_value) |value| allocator.free(value);
            allocator.free(self.headers);
            allocator.free(self.url);
        }
    };

    fn prepare(self: *Configured, allocator: std.mem.Allocator, value: provider_types.Request) !Prepared {
        if (std.mem.indexOfAny(u8, self.base_url, "?#") != null) return error.InvalidProviderEndpoint;
        if (value.endpoint.len == 0 or value.endpoint[0] != '/' or std.mem.indexOf(u8, value.endpoint, "://") != null)
            return error.InvalidProviderEndpoint;
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, self.base_url, "/"), value.endpoint });
        errdefer allocator.free(url);
        var headers: std.ArrayList(transport.Header) = .empty;
        errdefer headers.deinit(allocator);
        var credential_value: ?[]u8 = null;
        errdefer if (credential_value) |owned| allocator.free(owned);
        switch (self.credential) {
            .none => {},
            .bearer => |secret| {
                if (secret.len == 0 or !validHeaderValue(secret)) return error.InvalidProviderCredential;
                credential_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret});
                try headers.append(allocator, .{ .name = "authorization", .value = credential_value.?, .sensitive = true });
            },
            .header => |credential| {
                if (!validHeaderName(credential.name) or credential.value.len == 0 or
                    !validHeaderValue(credential.prefix) or !validHeaderValue(credential.value))
                    return error.InvalidProviderCredential;
                const rendered = if (credential.prefix.len == 0)
                    credential.value
                else rendered: {
                    credential_value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ credential.prefix, credential.value });
                    break :rendered credential_value.?;
                };
                try headers.append(allocator, .{ .name = credential.name, .value = rendered, .sensitive = true });
            },
        }
        try appendDistinct(allocator, &headers, self.headers);
        try appendDistinct(allocator, &headers, value.headers);
        const owned_headers = try headers.toOwnedSlice(allocator);
        return .{
            .request = .{
                .method = value.method,
                .url = url,
                .headers = owned_headers,
                .body = value.body,
                .timeout_ms = value.timeout_ms,
                .cancellation = value.cancellation,
                .response_header_sink = value.response_header_sink,
            },
            .url = url,
            .headers = owned_headers,
            .credential_value = credential_value,
        };
    }
};

fn appendDistinct(allocator: std.mem.Allocator, target: *std.ArrayList(transport.Header), values: []const transport.Header) !void {
    for (values) |header| {
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) return error.InvalidProviderHeader;
        for (target.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, header.name)) return error.ProviderHeaderConflict;
        }
        try target.append(allocator, header);
    }
}

fn validHeaderName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return false;
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| if (byte == '\r' or byte == '\n' or byte == 0) return false;
    return true;
}

test "configured HTTP provider owns authentication headers policy and streaming" {
    const State = struct {
        sent: bool = false,
        streamed: bool = false,

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: transport.Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("https://api.example.test/v1/responses", request.url);
            try std.testing.expectEqual(@as(?u64, 25), request.timeout_ms);
            try std.testing.expectEqual(@as(usize, 3), request.headers.len);
            try std.testing.expectEqualStrings("Bearer secret", request.headers[0].value);
            try std.testing.expect(request.headers[0].isSensitive());
            try std.testing.expectEqualStrings("configured", request.headers[1].name);
            try std.testing.expectEqualStrings("content-type", request.headers[2].name);
            self.sent = true;
            return .{ .status = 200, .body = try allocator.dupe(u8, "{}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, request: transport.Request, sink: transport.LineSink) !transport.StreamResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("payload", request.body);
            try sink.start(.{ .status = 200 });
            try sink.line("data: ok");
            self.streamed = true;
            return .{ .status = 200 };
        }
    };
    const Sink = struct {
        starts: usize = 0,
        lines: usize = 0,
        fn start(context: *anyopaque, _: transport.StreamResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.starts += 1;
        }
        fn line(context: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.lines += 1;
        }
    };
    var state: State = .{};
    var configured = Configured{
        .name = "example",
        .base_url = "https://api.example.test/v1/",
        .transport = .{ .context = &state, .sendFn = State.send, .streamLinesFn = State.stream },
        .credential = .{ .bearer = "secret" },
        .headers = &.{.{ .name = "configured", .value = "yes" }},
        .request_policy = .{ .default_timeout_ms = 25 },
    };
    const provider = configured.provider();
    const response = try provider.request(std.testing.allocator, .{
        .method = .POST,
        .endpoint = "/responses",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .timeout_ms = 100,
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(state.sent);
    var sink: Sink = .{};
    _ = try provider.streamLines(std.testing.allocator, .{ .method = .POST, .endpoint = "/responses", .body = "payload" }, .{
        .context = &sink,
        .startFn = Sink.start,
        .lineFn = Sink.line,
    });
    try std.testing.expect(state.streamed);
    try std.testing.expectEqual(@as(usize, 1), sink.starts);
    try std.testing.expectEqual(@as(usize, 1), sink.lines);
}

test "configured HTTP provider forwards non-inference operations" {
    const State = struct {
        deleted: bool = false,

        fn models(_: *anyopaque, allocator: std.mem.Allocator) !provider_types.OwnedModels {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const items = try arena.allocator().alloc(provider_types.ModelDescriptor, 1);
            items[0] = .{ .id = try arena.allocator().dupe(u8, "model") };
            return .{ .arena = arena, .items = items };
        }

        fn checkModelsAllocation(allocator: std.mem.Allocator) !void {
            var result = try models(undefined, allocator);
            result.deinit();
        }

        fn file(_: *anyopaque, allocator: std.mem.Allocator, handle: model.UploadedFile) !provider_types.OwnedFile {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const owned_id = try arena.allocator().dupe(u8, handle.id);
            return .{ .arena = arena, .value = .{ .id = owned_id, .provider_name = "example" } };
        }

        fn checkFileAllocation(allocator: std.mem.Allocator) !void {
            var result = try file(undefined, allocator, .{ .id = "file", .provider_name = "example" });
            result.deinit();
        }

        fn download(_: *anyopaque, allocator: std.mem.Allocator, handle: model.UploadedFile) !provider_types.OwnedFileDownload {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const memory = arena.allocator();
            const owned_id = try memory.dupe(u8, handle.id);
            const bytes = try memory.dupe(u8, "content");
            return .{
                .arena = arena,
                .value = .{
                    .descriptor = .{ .id = owned_id, .provider_name = "example" },
                    .bytes = bytes,
                },
            };
        }

        fn checkDownloadAllocation(allocator: std.mem.Allocator) !void {
            var result = try download(undefined, allocator, .{ .id = "file", .provider_name = "example" });
            result.deinit();
        }

        fn upload(context: *anyopaque, allocator: std.mem.Allocator, input: provider_types.FileInput) !provider_types.OwnedFile {
            try std.testing.expectEqualStrings("text/plain", input.media_type);
            return file(context, allocator, .{ .id = input.filename, .provider_name = "example" });
        }

        fn delete(context: *anyopaque, _: std.mem.Allocator, handle: model.UploadedFile) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("file", handle.id);
            self.deleted = true;
        }
    };
    var state: State = .{};
    var configured = Configured{
        .name = "example",
        .base_url = "https://api.example.test/v1",
        .transport = .{ .context = &state, .sendFn = undefined },
        .operations = .{
            .context = &state,
            .listModelsFn = State.models,
            .uploadFileFn = State.upload,
            .inspectFileFn = State.file,
            .downloadFileFn = State.download,
            .deleteFileFn = State.delete,
        },
    };
    const provider = configured.provider();
    var models = try provider.listModels(std.testing.allocator);
    defer models.deinit();
    try std.testing.expectEqualStrings("model", models.items[0].id);
    var uploaded = try provider.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text/plain",
        .bytes = "content",
    });
    defer uploaded.deinit();
    try std.testing.expectEqualStrings("file", uploaded.value.id);
    const file = uploaded.value.uploadedFile();
    var fetched = try provider.inspectFile(std.testing.allocator, file);
    defer fetched.deinit();
    try std.testing.expectEqualStrings("file", fetched.value.id);
    var downloaded = try provider.downloadFile(std.testing.allocator, file);
    defer downloaded.deinit();
    try std.testing.expectEqualStrings("content", downloaded.value.bytes);
    try provider.deleteFile(std.testing.allocator, file);
    try std.testing.expect(state.deleted);

    configured.operations = .{ .context = &state };
    const unsupported = configured.provider();
    try std.testing.expectError(error.UnsupportedProviderOperation, unsupported.listModels(std.testing.allocator));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkModelsAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkFileAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkDownloadAllocation, .{});
}

test "configured HTTP provider profiles redact credentials and reject conflicts" {
    const Profiles = struct {
        fn lookup(_: *anyopaque, name: []const u8) ?model.ModelProfile {
            if (!std.mem.eql(u8, name, "known")) return null;
            return .{ .supports_streaming = true };
        }
        fn override(_: *anyopaque, _: []const u8, profile: model.ModelProfile) model.ModelProfile {
            var result = profile;
            result.supports_tools = false;
            return result;
        }
    };
    const Observer = struct {
        redacted: bool = false,
        fn observe(context: *anyopaque, value: model.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.redacted = value.sensitive_data_redacted and std.mem.eql(u8, value.message, "[REDACTED]");
        }
    };
    const Stub = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) !transport.Response {
            return error.UnexpectedRequest;
        }
    };
    var marker: u8 = 0;
    var configured = Configured{
        .name = "example",
        .base_url = "https://api.example.test/v1",
        .transport = .{ .context = &marker, .sendFn = Stub.send },
        .credential = .{ .header = .{ .name = "x-api-key", .value = "secret", .prefix = "Key " } },
        .headers = &.{.{ .name = "x-tenant", .value = "one" }},
        .model_profiles = .{ .context = &marker, .lookupFn = Profiles.lookup, .overrideFn = Profiles.override },
    };
    const provider = configured.provider();
    try std.testing.expectError(error.UnexpectedRequest, provider.request(std.testing.allocator, .{ .method = .GET, .endpoint = "/models" }));
    const profile = provider.modelProfile("known", .{});
    try std.testing.expect(profile.supports_streaming);
    try std.testing.expect(!profile.supports_tools);
    try std.testing.expect(!provider.modelProfile("unknown", .{}).supports_tools);
    var observer: Observer = .{};
    provider.observeError(std.testing.allocator, 401, "{\"error\":{\"message\":\"secret\"}}", .{}, .{
        .context = &observer,
        .observeFn = Observer.observe,
    }, .{ .capture_body = true });
    try std.testing.expect(observer.redacted);
    observer.redacted = false;
    configured.credential = .{ .bearer = "secret" };
    configured.provider().observeError(std.testing.allocator, 401, "{\"error\":{\"message\":\"secret\"}}", .{}, .{
        .context = &observer,
        .observeFn = Observer.observe,
    }, .{});
    try std.testing.expect(observer.redacted);
    configured.credential = .{ .header = .{ .name = "x-api-key", .value = "secret" } };
    try std.testing.expectError(error.UnexpectedRequest, configured.provider().request(std.testing.allocator, .{ .method = .GET, .endpoint = "/models" }));
    try std.testing.expectError(error.InvalidProviderEndpoint, provider.request(std.testing.allocator, .{ .method = .GET, .endpoint = "https://other.test" }));
    try std.testing.expectError(error.ProviderHeaderConflict, provider.request(std.testing.allocator, .{
        .method = .GET,
        .endpoint = "/models",
        .headers = &.{.{ .name = "X-Tenant", .value = "two" }},
    }));
    try std.testing.expectError(error.InvalidProviderHeader, provider.request(std.testing.allocator, .{
        .method = .GET,
        .endpoint = "/models",
        .headers = &.{.{ .name = "bad header", .value = "value" }},
    }));

    configured.credential = .none;
    configured.model_profiles = .{ .context = &marker };
    const plain = configured.provider();
    try std.testing.expect(plain.modelProfile("unknown", .{}).supports_tools);
    plain.observeError(std.testing.allocator, 500, "failure", .{}, null, .{});
    configured.credential = .{ .bearer = "" };
    try std.testing.expectError(error.InvalidProviderCredential, configured.provider().request(std.testing.allocator, .{ .method = .GET, .endpoint = "/models" }));
    configured.credential = .{ .header = .{ .name = "x-api-key", .value = "bad\nvalue" } };
    try std.testing.expectError(error.InvalidProviderCredential, configured.provider().request(std.testing.allocator, .{ .method = .GET, .endpoint = "/models" }));
    configured.base_url = "https://api.example.test/v1?tenant=one";
    try std.testing.expectError(error.InvalidProviderEndpoint, configured.provider().request(std.testing.allocator, .{ .method = .GET, .endpoint = "/models" }));
    try std.testing.expect(validHeaderName("x-valid_header"));
    try std.testing.expect(!validHeaderName(""));
    try std.testing.expect(!validHeaderValue("bad\x00value"));
}

test "configured HTTP request preparation releases every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var marker: u8 = 0;
            var configured = Configured{
                .name = "example",
                .base_url = "https://api.example.test/v1",
                .transport = .{ .context = &marker, .sendFn = undefined },
                .credential = .{ .bearer = "secret" },
                .headers = &.{.{ .name = "x-tenant", .value = "one" }},
            };
            const prepared = try configured.prepare(allocator, .{
                .method = .POST,
                .endpoint = "/responses",
                .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            prepared.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
