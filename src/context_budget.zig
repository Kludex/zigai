//! Provider-facing context measurement and preflight budget policy.
//!
//! This module borrows request data and allocates nothing. It deliberately
//! separates byte measurement from provider-specific token estimation.

const std = @import("std");
const model = @import("model.zig");

/// Stable failures produced while measuring caller-controlled context.
pub const MeasureError = error{
    /// The aggregate context size cannot be represented as `u64`.
    ContextSizeOverflow,
};

/// Provider-facing request fields used by context measurement and estimators.
pub const Input = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    messages: []const model.Message,
    instructions: []const []const u8 = &.{},
    tools: []const model.ToolDefinition = &.{},
    builtin_tools: []const model.BuiltinTool = &.{},
    output: model.OutputFormat = .text,
    settings: model.ModelSettings = .{},
};

/// Measured request size split by the limits applications commonly control.
pub const ByteUsage = struct {
    prompt: u64 = 0,
    tools: u64 = 0,
    schemas: u64 = 0,
    media: u64 = 0,

    pub fn total(self: ByteUsage) MeasureError!u64 {
        var result = try add(0, self.prompt);
        result = try add(result, self.tools);
        result = try add(result, self.schemas);
        return add(result, self.media);
    }
};

/// Complete preflight estimate supplied to overflow hooks.
pub const Snapshot = struct {
    bytes: ByteUsage,
    estimated_input_tokens: u64,
};

/// Provider-specific token estimator. Inputs are borrowed for the call.
pub const TokenEstimator = struct {
    context: *anyopaque,
    estimateFn: *const fn (context: *anyopaque, input: Input, bytes: ByteUsage) u64,

    pub fn estimate(self: TokenEstimator, input: Input, bytes: ByteUsage) u64 {
        return self.estimateFn(self.context, input, bytes);
    }
};

/// The first configured boundary exceeded by a request.
pub const Overflow = struct {
    kind: Kind,
    actual: u64,
    maximum: u64,

    pub const Kind = enum {
        prompt_bytes,
        tool_bytes,
        schema_bytes,
        media_bytes,
        input_tokens,
    };
};

/// Borrowed context supplied when a request exceeds its preflight budget.
pub const OverflowEvent = struct {
    input: Input,
    snapshot: Snapshot,
    overflow: Overflow,
};

/// One bounded opportunity to compact history or reject the request.
///
/// Returned messages must remain valid for the run. Allocate replacements
/// with `arena`; returning a borrowed subslice of `event.input.messages` is // kcov-ignore
/// also valid.
pub const OverflowHook = struct {
    context: *anyopaque,
    compactFn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        event: OverflowEvent,
    ) anyerror![]const model.Message,

    pub fn compact(self: OverflowHook, arena: std.mem.Allocator, event: OverflowEvent) ![]const model.Message {
        return self.compactFn(self.context, arena, event);
    }
};

/// Per-request context limits. Null fields leave that dimension unbounded.
pub const Budget = struct {
    max_prompt_bytes: ?u64 = null,
    max_tool_bytes: ?u64 = null,
    max_schema_bytes: ?u64 = null,
    max_media_bytes: ?u64 = null,
    max_input_tokens: ?u64 = null,
    /// Combined input and reserved output capacity.
    max_total_tokens: ?u64 = null,
    /// Output capacity removed from `max_total_tokens`. When null, the
    /// resolved model setting `max_tokens` is reserved.
    reserve_output_tokens: ?u64 = null,
    estimator: ?TokenEstimator = null,
    on_overflow: ?OverflowHook = null,

    pub fn isConfigured(self: Budget) bool {
        return self.max_prompt_bytes != null or self.max_tool_bytes != null or
            self.max_schema_bytes != null or self.max_media_bytes != null or
            self.max_input_tokens != null or self.max_total_tokens != null;
    }

    pub fn maximumInputTokens(self: Budget, settings: model.ModelSettings) ?u64 {
        var maximum = self.max_input_tokens;
        if (self.max_total_tokens) |total| {
            const reserve = self.reserve_output_tokens orelse settings.max_tokens orelse 0;
            const after_reserve = total -| reserve;
            maximum = if (maximum) |current| @min(current, after_reserve) else after_reserve;
        }
        return maximum;
    }

    pub fn firstOverflow(self: Budget, settings: model.ModelSettings, snapshot: Snapshot) ?Overflow {
        if (exceeds(snapshot.bytes.prompt, self.max_prompt_bytes)) |overflow| return .{
            .kind = .prompt_bytes,
            .actual = overflow.actual,
            .maximum = overflow.maximum,
        };
        if (exceeds(snapshot.bytes.tools, self.max_tool_bytes)) |overflow| return .{
            .kind = .tool_bytes,
            .actual = overflow.actual,
            .maximum = overflow.maximum,
        };
        if (exceeds(snapshot.bytes.schemas, self.max_schema_bytes)) |overflow| return .{
            .kind = .schema_bytes,
            .actual = overflow.actual,
            .maximum = overflow.maximum,
        };
        if (exceeds(snapshot.bytes.media, self.max_media_bytes)) |overflow| return .{
            .kind = .media_bytes,
            .actual = overflow.actual,
            .maximum = overflow.maximum,
        };
        const maximum = self.maximumInputTokens(settings) orelse return null;
        const reserve_invalid = if (self.max_total_tokens) |total|
            (self.reserve_output_tokens orelse settings.max_tokens orelse 0) > total
        else
            false;
        if (reserve_invalid or snapshot.estimated_input_tokens > maximum) return .{
            .kind = .input_tokens,
            .actual = snapshot.estimated_input_tokens,
            .maximum = maximum,
        };
        return null;
    }
};

const Exceeded = struct { actual: u64, maximum: u64 };

fn exceeds(actual: u64, maximum: ?u64) ?Exceeded {
    const limit = maximum orelse return null;
    if (actual <= limit) return null;
    return .{ .actual = actual, .maximum = limit };
}

/// Measures bytes encoded into the provider request without allocating.
pub fn measure(input: Input) MeasureError!ByteUsage {
    var usage: ByteUsage = .{};
    for (input.instructions) |instruction| try accumulate(&usage.prompt, instruction.len);
    for (input.messages) |message| switch (message) {
        .request => |request| for (request.parts) |part| switch (part) {
            .system_prompt, .retry_prompt => |text| try accumulate(&usage.prompt, text.len),
            .system_prompt_part => |prompt| try accumulate(&usage.prompt, prompt.content.len),
            .user_prompt => |content| try measureUserContent(&usage, content),
            .user_prompt_part => |prompt| try measureUserContent(&usage, prompt.content),
            .speech => |speech| try measureSpeech(&usage, speech),
            .tool_search_return => |result| try measureToolSearchResult(&usage, result),
            .capability_load_return => |result| {
                try accumulate(&usage.tools, result.call_id.len);
                if (result.instructions) |instructions| try accumulate(&usage.prompt, instructions.len);
            },
            .tool_return => |result| {
                try accumulate(&usage.tools, result.call_id.len);
                try accumulate(&usage.tools, result.name.len);
                try accumulate(&usage.tools, result.content.len);
                for (result.files) |file| try measureContent(&usage.media, file);
            },
            .retry_prompt_part => |prompt| try accumulate(&usage.prompt, prompt.content.len),
            .tool_availability_delta => |delta| for (delta.tools_added) |name| try accumulate(&usage.tools, name.len),
        },
        .response => |response| for (response.parts) |part| switch (part) {
            .text => |text| try accumulate(&usage.prompt, text.len),
            .text_part => |text| try accumulate(&usage.prompt, text.content.len),
            .thinking => |thinking| {
                try accumulate(&usage.prompt, thinking.content.len);
                if (thinking.signature) |signature| try accumulate(&usage.prompt, signature.len);
            },
            .tool_call => |call| {
                try accumulate(&usage.tools, call.id.len);
                try accumulate(&usage.tools, call.name.len);
                try accumulate(&usage.tools, call.arguments_json.len);
                if (call.thought_signature) |signature| try accumulate(&usage.tools, signature.len);
            },
            .tool_search_call, .native_tool_search_call => |call| {
                try accumulate(&usage.tools, call.call_id.len);
                for (call.queries) |query| try accumulate(&usage.tools, query.len);
            },
            .capability_load_call => |call| {
                try accumulate(&usage.tools, call.call_id.len);
                try accumulate(&usage.tools, call.capability_id.len);
            },
            .native_tool_call => |call| {
                try accumulate(&usage.tools, call.id.len);
                try accumulate(&usage.tools, call.name.len);
                try accumulate(&usage.tools, call.arguments_json.len);
            },
            .native_tool_search_return => |result| try measureToolSearchResult(&usage, result),
            .native_tool_return => |result| {
                try accumulate(&usage.tools, result.call_id.len);
                try accumulate(&usage.tools, result.name.len);
                try accumulate(&usage.tools, result.content.len);
                for (result.files) |file| try measureContent(&usage.media, file);
            },
            .compaction => |compaction| if (compaction.content) |content|
                try accumulate(&usage.prompt, content.len),
            .image, .audio, .video, .document, .binary => |content| try measureContent(&usage.media, content),
            .speech => |speech| try measureSpeech(&usage, speech),
        },
    };
    for (input.tools) |tool| {
        try accumulate(&usage.tools, tool.name.len);
        try accumulate(&usage.tools, tool.description.len);
        try accumulate(&usage.schemas, tool.parameters_json_schema.len);
        if (tool.return_json_schema) |schema| try accumulate(&usage.schemas, schema.len);
    }
    for (input.builtin_tools) |tool| try accumulate(&usage.tools, @tagName(tool.kind()).len);
    switch (input.output) {
        .text, .json_object => {},
        .json_schema => |schema| {
            try accumulate(&usage.schemas, schema.name.len);
            try accumulate(&usage.schemas, schema.schema.len);
        },
    }
    return usage;
}

/// Conservative provider-neutral estimate used when no tokenizer is supplied.
/// Applications that need exact enforcement should provide `TokenEstimator`.
pub fn defaultEstimate(input: Input, bytes: ByteUsage) MeasureError!u64 {
    const total_bytes = try bytes.total();
    const text_tokens = @divFloor(try add(total_bytes, 3), 4);
    const message_overhead = @as(u64, @intCast(input.messages.len)) * 4;
    const tool_overhead = try add(
        @as(u64, @intCast(input.tools.len)) * 8,
        @as(u64, @intCast(input.builtin_tools.len)) * 8,
    );
    return add(try add(text_tokens, message_overhead), tool_overhead);
}

fn measureUserContent(usage: *ByteUsage, content: model.UserContent) MeasureError!void {
    switch (content) {
        .text => |text| try accumulate(&usage.prompt, text.len),
        .text_content => |text| try accumulate(&usage.prompt, text.content.len),
        .image, .audio, .video, .document, .binary => |media| try measureContent(&usage.media, media),
        .uploaded_file => |file| try measureUploadedFile(&usage.media, file),
        .cache_point => {},
    }
}

fn measureSpeech(usage: *ByteUsage, speech: model.SpeechPart) MeasureError!void {
    if (speech.transcript) |transcript| try accumulate(&usage.prompt, transcript.len);
    if (speech.audio) |audio| try measureContent(&usage.media, audio);
}

fn measureToolSearchResult(usage: *ByteUsage, result: model.ToolSearchResult) MeasureError!void {
    try accumulate(&usage.tools, result.call_id.len);
    for (result.discovered_tools) |tool| try accumulate(&usage.tools, tool.name.len);
    if (result.message) |message| try accumulate(&usage.tools, message.len);
}

fn measureUploadedFile(total: *u64, file: model.UploadedFile) MeasureError!void {
    try accumulate(total, file.id.len);
    try accumulate(total, file.provider_name.len);
    if (file.media_type) |media_type| try accumulate(total, media_type.len);
}

fn measureContent(total: *u64, content: model.Content) MeasureError!void {
    switch (content.source) {
        .bytes => |bytes| try accumulate(total, bytes.len),
        .url => |url| try accumulate(total, url.len),
        .provider_file => |file| {
            try accumulate(total, file.id.len);
            if (file.provider) |provider| try accumulate(total, provider.len);
        },
        .uploaded_file => |file| try measureUploadedFile(total, file),
    }
    try accumulate(total, content.media_type.len);
    if (content.filename) |filename| try accumulate(total, filename.len);
    if (content.identifier) |identifier| try accumulate(total, identifier.len);
    if (content.thought_signature) |signature| try accumulate(total, signature.len);
}

fn accumulate(total: *u64, amount: usize) MeasureError!void {
    total.* = try add(total.*, @intCast(amount));
}

fn add(left: u64, right: u64) MeasureError!u64 {
    return std.math.add(u64, left, right) catch error.ContextSizeOverflow;
}

test "measure classifies prompt tool schema and media bytes" {
    const messages = [_]model.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt = "sys" },
            .{ .retry_prompt = "retry" },
            .{ .user_prompt = .{ .text = "hello" } },
            .{ .user_prompt = .{ .image = .{
                .source = .{ .bytes = "png" },
                .media_type = "image/png",
                .filename = "x.png",
            } } },
            .{ .tool_return = .{ .call_id = "id", .name = "tool", .content = "result" } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text = "answer" },
            .{ .thinking = .{ .content = "think", .signature = "sig" } },
            .{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}", .thought_signature = "ts" } },
            .{ .document = .{
                .source = .{ .provider_file = .{ .id = "file", .provider = "openai" } },
                .media_type = "application/pdf",
                .thought_signature = "media-sig",
            } },
            .{ .audio = .{ .source = .{ .url = "https://a" }, .media_type = "audio/wav" } },
        } } },
    };
    const tools = [_]model.ToolDefinition{.{
        .name = "tool",
        .description = "description",
        .parameters_json_schema = "params",
        .return_json_schema = "returns",
    }};
    const usage = try measure(.{
        .messages = &messages,
        .instructions = &.{"instruction"},
        .tools = &tools,
        .builtin_tools = &.{.{ .web_search = .{} }},
        .output = .{ .json_schema = .{ .name = "output", .schema = "schema" } },
    });
    try std.testing.expectEqual(@as(u64, 38), usage.prompt);
    try std.testing.expectEqual(@as(u64, 49), usage.tools);
    try std.testing.expectEqual(@as(u64, 25), usage.schemas);
    try std.testing.expectEqual(@as(u64, 69), usage.media);
    try std.testing.expectEqual(@as(u64, 181), try usage.total());
}

test "measure covers the complete message vocabulary" {
    const uploaded = model.UploadedFile{
        .id = "file",
        .provider_name = "provider",
        .media_type = "image/png",
    };
    const media = model.Content{
        .source = .{ .uploaded_file = uploaded },
        .media_type = "image/png",
        .identifier = "media",
        .thought_signature = "signature",
    };
    const discovered = [_]model.ToolSearchMatch{.{ .name = "weather" }};
    const messages = [_]model.Message{
        .{ .request = .{ .parts = &.{
            .{ .system_prompt_part = .{ .content = "system" } },
            .{ .user_prompt = .{ .text_content = .{ .content = "text" } } },
            .{ .user_prompt = .{ .audio = media } },
            .{ .user_prompt = .{ .video = media } },
            .{ .user_prompt = .{ .document = media } },
            .{ .user_prompt = .{ .binary = media } },
            .{ .user_prompt = .{ .uploaded_file = uploaded } },
            .{ .user_prompt = .{ .cache_point = .{} } },
            .{ .user_prompt_part = .{ .content = .{ .text = "timestamped" } } },
            .{ .speech = .{ .speaker = .user, .transcript = "spoken", .audio = media } },
            .{ .tool_search_return = .{
                .call_id = "search",
                .discovered_tools = &discovered,
                .message = "found",
            } },
            .{ .capability_load_return = .{ .call_id = "load", .instructions = "instructions" } },
            .{ .tool_return = .{
                .call_id = "tool",
                .name = "weather",
                .content = "result",
                .files = &.{media},
            } },
            .{ .retry_prompt_part = .{ .content = "retry" } },
            .{ .tool_availability_delta = .{ .tools_added = &.{"weather"} } },
        } } },
        .{ .response = .{ .parts = &.{
            .{ .text_part = .{ .content = "answer" } },
            .{ .tool_search_call = .{ .call_id = "search", .queries = &.{"query"} } },
            .{ .native_tool_search_call = .{ .call_id = "native-search", .queries = &.{"query"} } },
            .{ .capability_load_call = .{ .call_id = "load", .capability_id = "maps" } },
            .{ .native_tool_call = .{
                .id = "native",
                .name = "search",
                .arguments_json = "{}",
                .provider = .{},
            } },
            .{ .native_tool_search_return = .{
                .call_id = "native-search",
                .discovered_tools = &discovered,
                .message = "found",
            } },
            .{ .native_tool_return = .{
                .call_id = "native",
                .name = "search",
                .content = "result",
                .files = &.{media},
                .provider = .{},
            } },
            .{ .compaction = .{ .content = "summary" } },
            .{ .image = media },
            .{ .video = media },
            .{ .binary = media },
            .{ .speech = .{ .speaker = .assistant, .transcript = "spoken", .audio = media } },
        } } },
    };

    const usage = try measure(.{ .messages = &messages });
    try std.testing.expect(usage.prompt > 0);
    try std.testing.expect(usage.tools > 0);
    try std.testing.expect(usage.media > 0);
}

test "budget accepts exact boundaries and reports every overflow kind" {
    const snapshot = Snapshot{
        .bytes = .{ .prompt = 1, .tools = 2, .schemas = 3, .media = 4 },
        .estimated_input_tokens = 5,
    };
    const exact = Budget{
        .max_prompt_bytes = 1,
        .max_tool_bytes = 2,
        .max_schema_bytes = 3,
        .max_media_bytes = 4,
        .max_input_tokens = 5,
    };
    try std.testing.expect(exact.isConfigured());
    try std.testing.expect(exact.firstOverflow(.{}, snapshot) == null);
    try std.testing.expectEqual(
        Overflow.Kind.prompt_bytes,
        (Budget{ .max_prompt_bytes = 0 }).firstOverflow(.{}, snapshot).?.kind,
    );
    try std.testing.expectEqual(
        Overflow.Kind.tool_bytes,
        (Budget{ .max_tool_bytes = 1 }).firstOverflow(.{}, snapshot).?.kind,
    );
    try std.testing.expectEqual(
        Overflow.Kind.schema_bytes,
        (Budget{ .max_schema_bytes = 2 }).firstOverflow(.{}, snapshot).?.kind,
    );
    try std.testing.expectEqual(
        Overflow.Kind.media_bytes,
        (Budget{ .max_media_bytes = 3 }).firstOverflow(.{}, snapshot).?.kind,
    );
    try std.testing.expectEqual(
        Overflow.Kind.input_tokens,
        (Budget{ .max_input_tokens = 4 }).firstOverflow(.{}, snapshot).?.kind,
    );
    try std.testing.expect(!(Budget{}).isConfigured());
}

test "total token limits reserve configured or model output" {
    try std.testing.expectEqual(
        @as(?u64, 80),
        (Budget{ .max_total_tokens = 100, .reserve_output_tokens = 20 }).maximumInputTokens(.{}),
    );
    try std.testing.expectEqual(
        @as(?u64, 70),
        (Budget{ .max_total_tokens = 100 }).maximumInputTokens(.{ .max_tokens = 30 }),
    );
    try std.testing.expectEqual(
        @as(?u64, 40),
        (Budget{ .max_input_tokens = 40, .max_total_tokens = 100 }).maximumInputTokens(.{ .max_tokens = 30 }),
    );
    const invalid = (Budget{ .max_total_tokens = 10, .reserve_output_tokens = 11 }).firstOverflow(.{}, .{
        .bytes = .{},
        .estimated_input_tokens = 0,
    }).?;
    try std.testing.expectEqual(Overflow.Kind.input_tokens, invalid.kind);
    try std.testing.expectEqual(@as(u64, 0), invalid.maximum);
}

test "default estimate includes request framing overhead" {
    const input = Input{
        .messages = &.{.{ .request = .{ .parts = &.{} } }},
        .tools = &.{.{ .name = "x", .description = "", .parameters_json_schema = "{}" }},
        .builtin_tools = &.{.{ .web_search = .{} }},
    };
    try std.testing.expectEqual(@as(u64, 23), defaultEstimate(input, .{ .prompt = 9 }));
    try std.testing.expectError(error.ContextSizeOverflow, (ByteUsage{
        .prompt = std.math.maxInt(u64),
        .tools = 1,
    }).total());
    try std.testing.expectError(
        error.ContextSizeOverflow,
        defaultEstimate(.{ .messages = &.{} }, .{ .prompt = std.math.maxInt(u64) }),
    );
}

test "estimator and overflow hook delegate through public contracts" {
    const Callbacks = struct {
        fn estimate(_: *anyopaque, _: Input, _: ByteUsage) u64 {
            return 7; // kcov-ignore
        }

        fn compact(_: *anyopaque, _: std.mem.Allocator, event: OverflowEvent) ![]const model.Message {
            try std.testing.expectEqual(Overflow.Kind.input_tokens, event.overflow.kind);
            return event.input.messages[0..0];
        }
    };
    var state: u8 = 0;
    const input = Input{ .messages = &.{.{ .request = .{ .parts = &.{} } }} };
    const estimator = TokenEstimator{ .context = &state, .estimateFn = Callbacks.estimate }; // kcov-ignore
    try std.testing.expectEqual(@as(u64, 7), estimator.estimate(input, .{}));
    const hook = OverflowHook{ .context = &state, .compactFn = Callbacks.compact };
    try std.testing.expectEqual(@as(usize, 0), (try hook.compact(std.testing.allocator, .{
        .input = input,
        .snapshot = .{ .bytes = .{}, .estimated_input_tokens = 7 },
        .overflow = .{ .kind = .input_tokens, .actual = 7, .maximum = 6 },
    })).len);
}
