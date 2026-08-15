//! Provider-owned configuration and operations shared by model wire adapters.
//!
//! A provider owns credentials, its base URL, configured headers, request
//! policy, and non-inference APIs. A model adapter owns request and response
//! encoding. `Provider` is borrowed; operation results state their ownership.

const std = @import("std");
const model = @import("model.zig");
const security = @import("security.zig");
const transport = @import("transport.zig");

pub const Error = error{
    InvalidProviderFileInput,
    InvalidProviderPolicy,
    InvalidProviderFileReference,
    InvalidProviderFileOwner,
    ProviderFileTooLarge,
    UnsupportedProviderOperation,
};

/// Provider-wide outbound defaults. A model request may tighten the timeout
/// and URL policy, but it cannot bypass these defaults.
pub const RequestPolicy = struct {
    url_policy: security.UrlPolicy = .{},
    default_timeout_ms: ?u64 = null,

    pub fn validate(self: RequestPolicy, base_url: []const u8) !void {
        if (self.default_timeout_ms == 0) return error.InvalidProviderPolicy;
        try self.url_policy.validate(base_url);
    }

    pub fn timeoutMilliseconds(self: RequestPolicy, requested: ?u64) ?u64 {
        if (self.default_timeout_ms) |provider_timeout| {
            if (requested) |request_timeout| return @min(provider_timeout, request_timeout);
            return provider_timeout;
        }
        return requested;
    }
};

/// Borrowed provider request. `endpoint` is relative to `Provider.base_url`;
/// the provider authenticates it, adds configured headers, and sends it.
pub const Request = struct {
    method: transport.Method,
    endpoint: []const u8,
    headers: []const transport.Header = &.{},
    body: []const u8 = "",
    timeout_ms: ?u64 = null,
    cancellation: ?*const model.CancellationToken = null,
    response_header_sink: ?transport.ResponseHeaderSink = null,
    /// Run-scoped policy that may further restrict the provider base URL.
    url_policy: security.UrlPolicy = .{},
};

pub const ModelDescriptor = struct {
    id: []const u8,
    profile: ?model.ModelProfile = null,
    /// Provider-specific discovery data retained without interpreting it.
    metadata_json: ?[]const u8 = null,
};

/// Arena-owned model discovery result.
pub const OwnedModels = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ModelDescriptor,

    pub fn deinit(self: *OwnedModels) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FileInput = struct {
    filename: []const u8,
    media_type: []const u8,
    bytes: []const u8,
    purpose: ?[]const u8 = null,
};

pub const FileLimits = struct {
    max_upload_bytes: usize = 512 * 1024 * 1024,
    max_filename_bytes: usize = 1024,
    max_media_type_bytes: usize = 255,
    max_purpose_bytes: usize = 128,

    pub fn validate(self: FileLimits) !void {
        if (self.max_upload_bytes == 0 or self.max_filename_bytes == 0 or
            self.max_media_type_bytes == 0 or self.max_purpose_bytes == 0)
            return error.InvalidProviderPolicy;
    }

    pub fn validateInput(self: FileLimits, input: FileInput) !void {
        if (input.bytes.len > self.max_upload_bytes) return error.ProviderFileTooLarge;
        try validateText(input.filename, self.max_filename_bytes);
        try validateText(input.media_type, self.max_media_type_bytes);
        if (input.purpose) |purpose| try validateText(purpose, self.max_purpose_bytes);
    }

    fn validateText(value: []const u8, maximum: usize) !void {
        if (value.len == 0 or value.len > maximum or std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
            return error.InvalidProviderFileInput;
    }
};

pub const FileDescriptor = struct {
    id: []const u8,
    provider_name: []const u8,
    filename: ?[]const u8 = null,
    media_type: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
    size_bytes: ?u64 = null,
    metadata_json: ?[]const u8 = null,

    /// Views this provider-owned record as reusable rich-content input.
    pub fn uploadedFile(self: FileDescriptor) model.UploadedFile {
        return .{
            .id = self.id,
            .provider_name = self.provider_name,
            .media_type = self.media_type,
        };
    }
};

/// Arena-owned provider file result.
pub const OwnedFile = struct {
    arena: std.heap.ArenaAllocator,
    value: FileDescriptor,

    pub fn deinit(self: *OwnedFile) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FileDownload = struct {
    descriptor: FileDescriptor,
    bytes: []const u8,
};

/// Arena-owned downloaded file. Both metadata and bytes remain valid until
/// `deinit` is called.
pub const OwnedFileDownload = struct {
    arena: std.heap.ArenaAllocator,
    value: FileDownload,

    pub fn deinit(self: *OwnedFileDownload) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrowed provider interface. Concrete providers retain all state and must
/// outlive every `Provider`, `Model`, and in-flight operation built from it.
pub const Provider = struct {
    context: *anyopaque,
    /// Stable identity written to message history and telemetry.
    name: []const u8,
    /// Borrowed API root used for diagnostics and policy validation.
    base_url: []const u8,
    request_policy: RequestPolicy = .{},
    file_limits: FileLimits = .{},
    requestFn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!transport.Response,
    streamLinesFn: ?*const fn (*anyopaque, std.mem.Allocator, Request, transport.LineSink) anyerror!transport.StreamResponse = null,
    modelProfileFn: ?*const fn (*anyopaque, []const u8) ?model.ModelProfile = null,
    overrideProfileFn: ?*const fn (*anyopaque, []const u8, model.ModelProfile) model.ModelProfile = null,
    observeErrorFn: ?*const fn (*anyopaque, std.mem.Allocator, u16, []const u8, transport.ResponseMetadata, ?model.ProviderErrorObserver, model.ProviderErrorPolicy) void = null,
    listModelsFn: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!OwnedModels = null,
    uploadFileFn: ?*const fn (*anyopaque, std.mem.Allocator, FileInput) anyerror!OwnedFile = null,
    inspectFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!OwnedFile = null,
    downloadFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!OwnedFileDownload = null,
    deleteFileFn: ?*const fn (*anyopaque, std.mem.Allocator, model.UploadedFile) anyerror!void = null,

    pub fn validate(self: Provider) !void {
        if (self.name.len == 0 or self.base_url.len == 0) return error.InvalidProviderPolicy;
        try self.request_policy.validate(self.base_url);
        try self.file_limits.validate();
    }

    pub fn request(self: Provider, allocator: std.mem.Allocator, value: Request) !transport.Response {
        try self.validate();
        try value.url_policy.validate(self.base_url);
        var bounded = value;
        bounded.timeout_ms = self.request_policy.timeoutMilliseconds(value.timeout_ms);
        return self.requestFn(self.context, allocator, bounded);
    }

    pub fn streamLines(self: Provider, allocator: std.mem.Allocator, value: Request, sink: transport.LineSink) !transport.StreamResponse {
        const stream = self.streamLinesFn orelse return error.UnsupportedProviderOperation;
        try self.validate();
        try value.url_policy.validate(self.base_url);
        var bounded = value;
        bounded.timeout_ms = self.request_policy.timeoutMilliseconds(value.timeout_ms);
        return stream(self.context, allocator, bounded, sink);
    }

    /// Applies provider model lookup first, then application capability
    /// overrides. `fallback` is used when discovery has no model-specific data.
    pub fn modelProfile(self: Provider, model_name: []const u8, fallback: model.ModelProfile) model.ModelProfile {
        const discovered = if (self.modelProfileFn) |lookup|
            lookup(self.context, model_name) orelse fallback
        else
            fallback;
        if (self.overrideProfileFn) |apply| return apply(self.context, model_name, discovered);
        return discovered;
    }

    /// Reports a provider error without exposing credentials to the model
    /// adapter. Concrete providers own parsing and secret redaction.
    pub fn observeError(
        self: Provider,
        allocator: std.mem.Allocator,
        status: u16,
        body: []const u8,
        metadata: transport.ResponseMetadata,
        observer: ?model.ProviderErrorObserver,
        policy: model.ProviderErrorPolicy,
    ) void {
        const observe = self.observeErrorFn orelse return;
        observe(self.context, allocator, status, body, metadata, observer, policy);
    }

    pub fn listModels(self: Provider, allocator: std.mem.Allocator) !OwnedModels {
        try self.validate();
        const list = self.listModelsFn orelse return error.UnsupportedProviderOperation;
        return list(self.context, allocator);
    }

    pub fn uploadFile(self: Provider, allocator: std.mem.Allocator, input: FileInput) !OwnedFile {
        try self.validate();
        try self.file_limits.validateInput(input);
        const upload = self.uploadFileFn orelse return error.UnsupportedProviderOperation;
        var result = try upload(self.context, allocator, input);
        errdefer result.deinit();
        try self.validateFileDescriptor(result.value, null);
        return result;
    }

    pub fn inspectFile(self: Provider, allocator: std.mem.Allocator, file: model.UploadedFile) !OwnedFile {
        try self.validate();
        try self.validateFileReference(file);
        const inspect = self.inspectFileFn orelse return error.UnsupportedProviderOperation;
        var result = try inspect(self.context, allocator, file);
        errdefer result.deinit();
        try self.validateFileDescriptor(result.value, file.id);
        return result;
    }

    pub fn downloadFile(self: Provider, allocator: std.mem.Allocator, file: model.UploadedFile) !OwnedFileDownload {
        try self.validate();
        try self.validateFileReference(file);
        const download = self.downloadFileFn orelse return error.UnsupportedProviderOperation;
        var result = try download(self.context, allocator, file);
        errdefer result.deinit();
        try self.validateFileDescriptor(result.value.descriptor, file.id);
        return result;
    }

    pub fn deleteFile(self: Provider, allocator: std.mem.Allocator, file: model.UploadedFile) !void {
        try self.validate();
        try self.validateFileReference(file);
        const delete = self.deleteFileFn orelse return error.UnsupportedProviderOperation;
        return delete(self.context, allocator, file);
    }

    fn validateFileReference(self: Provider, file: model.UploadedFile) !void {
        if (!std.mem.eql(u8, file.provider_name, self.name)) return error.InvalidProviderFileOwner;
        if (file.id.len == 0) return error.InvalidProviderFileReference;
    }

    fn validateFileDescriptor(self: Provider, descriptor: FileDescriptor, expected_id: ?[]const u8) !void {
        if (!std.mem.eql(u8, descriptor.provider_name, self.name)) return error.InvalidProviderFileOwner;
        if (descriptor.id.len == 0) return error.InvalidProviderFileReference;
        if (expected_id) |id| if (!std.mem.eql(u8, descriptor.id, id)) return error.InvalidProviderFileReference;
    }
};

test "provider owns policy profiles and optional operations" {
    const State = struct {
        deleted: bool = false,

        fn request(context: *anyopaque, allocator: std.mem.Allocator, value: Request) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(!self.deleted);
            try std.testing.expectEqualStrings("/responses", value.endpoint);
            try std.testing.expectEqual(@as(?u64, 50), value.timeout_ms);
            return .{ .status = 200, .body = try allocator.dupe(u8, "{}") };
        }

        fn stream(context: *anyopaque, _: std.mem.Allocator, value: Request, sink: transport.LineSink) !transport.StreamResponse {
            _ = context;
            try std.testing.expectEqual(@as(?u64, 25), value.timeout_ms);
            try sink.start(.{ .status = 200 });
            try sink.line("data: done");
            return .{ .status = 200 };
        }

        fn profile(_: *anyopaque, name: []const u8) ?model.ModelProfile {
            if (!std.mem.eql(u8, name, "known")) return null;
            return .{ .supports_streaming = true };
        }

        fn override(_: *anyopaque, _: []const u8, value: model.ModelProfile) model.ModelProfile {
            var result = value;
            result.supports_tools = false;
            return result;
        }

        fn observe(_: *anyopaque, _: std.mem.Allocator, status: u16, body: []const u8, _: transport.ResponseMetadata, observer: ?model.ProviderErrorObserver, _: model.ProviderErrorPolicy) void {
            const target = observer orelse return;
            target.observe(.{ .provider = "openai", .status = status, .message = body, .body = "" });
        }

        fn models(_: *anyopaque, allocator: std.mem.Allocator) !OwnedModels {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const items = try arena.allocator().alloc(ModelDescriptor, 1);
            items[0] = .{ .id = try arena.allocator().dupe(u8, "known") };
            return .{ .arena = arena, .items = items };
        }

        fn checkModelsAllocation(allocator: std.mem.Allocator) !void {
            var result = try models(undefined, allocator);
            result.deinit();
        }

        fn file(_: *anyopaque, allocator: std.mem.Allocator, handle: model.UploadedFile) !OwnedFile {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const owned_id = try arena.allocator().dupe(u8, handle.id);
            return .{ .arena = arena, .value = .{ .id = owned_id, .provider_name = "openai" } };
        }

        fn checkFileAllocation(allocator: std.mem.Allocator) !void {
            var result = try file(undefined, allocator, .{ .id = "file-1", .provider_name = "openai" });
            result.deinit();
        }

        fn download(_: *anyopaque, allocator: std.mem.Allocator, handle: model.UploadedFile) !OwnedFileDownload {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const memory = arena.allocator();
            const owned_id = try memory.dupe(u8, handle.id);
            const bytes = try memory.dupe(u8, "downloaded");
            return .{
                .arena = arena,
                .value = .{
                    .descriptor = .{
                        .id = owned_id,
                        .provider_name = "openai",
                        .media_type = "text/plain",
                    },
                    .bytes = bytes,
                },
            };
        }

        fn checkDownloadAllocation(allocator: std.mem.Allocator) !void {
            var result = try download(undefined, allocator, .{ .id = "file-1", .provider_name = "openai" });
            result.deinit();
        }

        fn upload(context: *anyopaque, allocator: std.mem.Allocator, input: FileInput) !OwnedFile {
            try std.testing.expectEqualStrings("text/plain", input.media_type);
            try std.testing.expectEqualStrings("user_data", input.purpose.?);
            return file(context, allocator, .{ .id = input.filename, .provider_name = "openai" });
        }

        fn delete(context: *anyopaque, _: std.mem.Allocator, handle: model.UploadedFile) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("file-1", handle.id);
            self.deleted = true;
        }
    };
    const Sink = struct {
        started: bool = false,
        line_value: ?[]const u8 = null,

        fn start(context: *anyopaque, response: transport.StreamResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(u16, 200), response.status);
            self.started = true;
        }

        fn line(context: *anyopaque, value: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.line_value = value;
        }
    };

    var state: State = .{};
    const provider = Provider{
        .context = &state,
        .name = "openai",
        .base_url = "https://api.openai.com/v1",
        .request_policy = .{ .default_timeout_ms = 50 },
        .requestFn = State.request,
        .streamLinesFn = State.stream,
        .modelProfileFn = State.profile,
        .overrideProfileFn = State.override,
        .observeErrorFn = State.observe,
        .listModelsFn = State.models,
        .uploadFileFn = State.upload,
        .inspectFileFn = State.file,
        .downloadFileFn = State.download,
        .deleteFileFn = State.delete,
    };
    const response = try provider.request(std.testing.allocator, .{ .method = .POST, .endpoint = "/responses", .timeout_ms = 100 });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);

    var sink_state: Sink = .{};
    const stream = try provider.streamLines(std.testing.allocator, .{ .method = .POST, .endpoint = "/responses", .timeout_ms = 25 }, .{
        .context = &sink_state,
        .startFn = Sink.start,
        .lineFn = Sink.line,
    });
    try std.testing.expectEqual(@as(u16, 200), stream.status);
    try std.testing.expect(sink_state.started);
    try std.testing.expectEqualStrings("data: done", sink_state.line_value.?);

    try std.testing.expect(!provider.modelProfile("known", .{}).supports_tools);
    try std.testing.expect(provider.modelProfile("known", .{}).supports_streaming);
    try std.testing.expect(!provider.modelProfile("unknown", .{}).supports_tools);
    const ErrorState = struct {
        observed: bool = false,
        fn observe(context: *anyopaque, value: model.ProviderError) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.observed = value.status == 401 and std.mem.eql(u8, value.message, "denied");
        }
    };
    var error_state: ErrorState = .{};
    provider.observeError(std.testing.allocator, 401, "denied", .{}, .{ .context = &error_state, .observeFn = ErrorState.observe }, .{});
    try std.testing.expect(error_state.observed);

    var models = try provider.listModels(std.testing.allocator);
    defer models.deinit();
    try std.testing.expectEqualStrings("known", models.items[0].id);
    var uploaded = try provider.uploadFile(std.testing.allocator, .{
        .filename = "file-1",
        .media_type = "text/plain",
        .bytes = "hi",
        .purpose = "user_data",
    });
    defer uploaded.deinit();
    try std.testing.expectEqualStrings("file-1", uploaded.value.id);
    try std.testing.expectEqualStrings("openai", uploaded.value.uploadedFile().provider_name);
    const file = uploaded.value.uploadedFile();
    var fetched = try provider.inspectFile(std.testing.allocator, file);
    defer fetched.deinit();
    try std.testing.expectEqualStrings("file-1", fetched.value.id);
    var downloaded = try provider.downloadFile(std.testing.allocator, file);
    defer downloaded.deinit();
    try std.testing.expectEqualStrings("downloaded", downloaded.value.bytes);
    try provider.deleteFile(std.testing.allocator, file);
    try std.testing.expect(state.deleted);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkModelsAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkFileAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, State.checkDownloadAllocation, .{});
}

test "provider rejects invalid policy and absent optional operations" {
    const Stub = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: Request) !transport.Response {
            return error.UnexpectedRequest;
        }
    };
    var state: u8 = 0;
    const invalid = Provider{ .context = &state, .name = "", .base_url = "", .requestFn = Stub.request };
    try std.testing.expectError(error.InvalidProviderPolicy, invalid.validate());
    const zero_timeout = Provider{
        .context = &state,
        .name = "test",
        .base_url = "https://example.com",
        .request_policy = .{ .default_timeout_ms = 0 },
        .requestFn = Stub.request,
    };
    try std.testing.expectError(error.InvalidProviderPolicy, zero_timeout.validate());
    const zero_file_limit = Provider{
        .context = &state,
        .name = "test",
        .base_url = "https://example.com",
        .file_limits = .{ .max_upload_bytes = 0 },
        .requestFn = Stub.request,
    };
    try std.testing.expectError(error.InvalidProviderPolicy, zero_file_limit.validate());
    const provider = Provider{ .context = &state, .name = "test", .base_url = "https://example.com", .requestFn = Stub.request };
    try std.testing.expectEqual(@as(?u64, 10), (RequestPolicy{}).timeoutMilliseconds(10));
    try std.testing.expectEqual(@as(?u64, 50), (RequestPolicy{ .default_timeout_ms = 50 }).timeoutMilliseconds(null));
    try std.testing.expect(provider.modelProfile("model", .{}).supports_tools);
    provider.observeError(std.testing.allocator, 500, "ignored", .{}, null, .{});
    try std.testing.expectError(error.UrlHostNotAllowed, provider.request(std.testing.allocator, .{
        .method = .GET,
        .endpoint = "/",
        .url_policy = .{ .allowed_hosts = &.{"elsewhere.example"} },
    }));
    try std.testing.expectError(error.UnexpectedRequest, provider.request(std.testing.allocator, .{ .method = .GET, .endpoint = "/" }));
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.streamLines(std.testing.allocator, .{ .method = .GET, .endpoint = "/" }, undefined));
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.listModels(std.testing.allocator));
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.uploadFile(std.testing.allocator, .{ .filename = "x", .media_type = "text/plain", .bytes = "" }));
    const unsupported_file = model.UploadedFile{ .id = "x", .provider_name = "test" };
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.inspectFile(std.testing.allocator, unsupported_file));
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.downloadFile(std.testing.allocator, unsupported_file));
    try std.testing.expectError(error.UnsupportedProviderOperation, provider.deleteFile(std.testing.allocator, unsupported_file));

    const WrongOwner = struct {
        fn file(_: *anyopaque, allocator: std.mem.Allocator, _: model.UploadedFile) !OwnedFile {
            return .{
                .arena = .init(allocator),
                .value = .{ .id = "file", .provider_name = "other" },
            };
        }
        fn upload(context: *anyopaque, allocator: std.mem.Allocator, _: FileInput) !OwnedFile {
            return file(context, allocator, .{ .id = "file", .provider_name = "test" });
        }

        fn download(_: *anyopaque, allocator: std.mem.Allocator, _: model.UploadedFile) !OwnedFileDownload {
            return .{
                .arena = .init(allocator),
                .value = .{
                    .descriptor = .{ .id = "file", .provider_name = "other" },
                    .bytes = "",
                },
            };
        }

        fn delete(_: *anyopaque, _: std.mem.Allocator, _: model.UploadedFile) !void {
            return error.UnexpectedRequest;
        }
    };
    const wrong_owner = Provider{
        .context = &state,
        .name = "test",
        .base_url = "https://example.com",
        .requestFn = Stub.request,
        .uploadFileFn = WrongOwner.upload,
        .inspectFileFn = WrongOwner.file,
        .downloadFileFn = WrongOwner.download,
        .deleteFileFn = WrongOwner.delete,
    };
    try std.testing.expectError(error.InvalidProviderFileOwner, wrong_owner.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text/plain",
        .bytes = "",
    }));
    const owned = model.UploadedFile{ .id = "file", .provider_name = "test" };
    try std.testing.expectError(error.InvalidProviderFileOwner, wrong_owner.inspectFile(std.testing.allocator, owned));
    try std.testing.expectError(error.InvalidProviderFileOwner, wrong_owner.downloadFile(std.testing.allocator, owned));
    try std.testing.expectError(error.InvalidProviderFileOwner, wrong_owner.inspectFile(std.testing.allocator, .{ .id = "file", .provider_name = "other" }));
    try std.testing.expectError(error.InvalidProviderFileReference, wrong_owner.inspectFile(std.testing.allocator, .{ .id = "", .provider_name = "test" }));
    try std.testing.expectError(error.InvalidProviderFileOwner, wrong_owner.deleteFile(std.testing.allocator, .{ .id = "file", .provider_name = "other" }));
    try std.testing.expectError(error.InvalidProviderFileReference, wrong_owner.deleteFile(std.testing.allocator, .{ .id = "", .provider_name = "test" }));
    try std.testing.expectError(error.UnexpectedRequest, wrong_owner.deleteFile(std.testing.allocator, owned));

    const WrongReference = struct {
        fn file(_: *anyopaque, allocator: std.mem.Allocator, _: model.UploadedFile) !OwnedFile {
            return .{
                .arena = .init(allocator),
                .value = .{ .id = "different", .provider_name = "test" },
            };
        }

        fn upload(_: *anyopaque, allocator: std.mem.Allocator, _: FileInput) !OwnedFile {
            return .{
                .arena = .init(allocator),
                .value = .{ .id = "", .provider_name = "test" },
            };
        }

        fn download(_: *anyopaque, allocator: std.mem.Allocator, _: model.UploadedFile) !OwnedFileDownload {
            return .{
                .arena = .init(allocator),
                .value = .{
                    .descriptor = .{ .id = "different", .provider_name = "test" },
                    .bytes = "",
                },
            };
        }
    };
    const wrong_reference = Provider{
        .context = &state,
        .name = "test",
        .base_url = "https://example.com",
        .requestFn = Stub.request,
        .uploadFileFn = WrongReference.upload,
        .inspectFileFn = WrongReference.file,
        .downloadFileFn = WrongReference.download,
    };
    try std.testing.expectError(error.InvalidProviderFileReference, wrong_reference.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text/plain",
        .bytes = "",
    }));
    try std.testing.expectError(error.InvalidProviderFileReference, wrong_reference.inspectFile(std.testing.allocator, owned));
    try std.testing.expectError(error.InvalidProviderFileReference, wrong_reference.downloadFile(std.testing.allocator, owned));

    const bounded_upload = Provider{
        .context = &state,
        .name = "test",
        .base_url = "https://example.com",
        .file_limits = .{ .max_upload_bytes = 1, .max_filename_bytes = 4, .max_media_type_bytes = 10, .max_purpose_bytes = 3 },
        .requestFn = Stub.request,
        .uploadFileFn = WrongReference.upload,
    };
    try std.testing.expectError(error.ProviderFileTooLarge, bounded_upload.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text/plain",
        .bytes = "xx",
    }));
    try std.testing.expectError(error.InvalidProviderFileInput, bounded_upload.uploadFile(std.testing.allocator, .{
        .filename = "",
        .media_type = "text/plain",
        .bytes = "",
    }));
    try std.testing.expectError(error.InvalidProviderFileInput, bounded_upload.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text\nplain",
        .bytes = "",
    }));
    try std.testing.expectError(error.InvalidProviderFileInput, bounded_upload.uploadFile(std.testing.allocator, .{
        .filename = "file",
        .media_type = "text/plain",
        .bytes = "",
        .purpose = "long",
    }));
}
