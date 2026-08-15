//! Agent-level output strategies translated into the smaller model wire
//! contract. Specifications borrow their schemas and templates for one run;
//! prepared schemas and prompted instructions are allocated in the run arena.

const std = @import("std");
const json_limits = @import("json.zig");
const json_schema = @import("json_schema.zig");
const model_types = @import("model.zig");

/// How ordinary function tools are handled when a response also contains a
/// valid final output.
pub const EndStrategy = enum {
    /// The first valid output wins and ordinary tools are skipped.
    early,
    /// Calls run in emission order until the first valid output succeeds.
    graceful,
    /// Every emitted call runs; the first valid output remains the result.
    exhaustive,
};

/// State borrowed by an output function for one invocation.
pub const RunContext = struct {
    dependencies: ?*anyopaque = null,
    messages: []const model_types.Message,
    usage: model_types.RunUsage = .{},
    model_requests: usize = 0,
    partial_output: bool = false,
    control: model_types.RunControl = .{},

    pub fn dependency(self: RunContext, comptime T: type) ?*T {
        const pointer = self.dependencies orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
};

/// A completed output function either returns the agent result or asks the
/// model to retry with a safe, application-provided message.
pub const FunctionResult = union(enum) {
    output: []const u8,
    retry: []const u8,
};

/// Processes validated arguments from one output tool. Returned slices must be
/// static or allocated with the supplied run-arena allocator.
pub const Function = struct {
    context: *anyopaque,
    callFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_context: RunContext,
        arguments_json: []const u8,
    ) anyerror!FunctionResult,

    pub fn call(
        self: Function,
        allocator: std.mem.Allocator,
        run_context: RunContext,
        arguments_json: []const u8,
    ) !FunctionResult {
        return self.callFn(self.context, allocator, run_context, arguments_json);
    }
};

/// A validator either accepts (and may transform) an output or asks the model
/// for another attempt with a safe, application-provided message.
pub const ValidatorResult = union(enum) {
    output: []const u8,
    retry: []const u8,
};

/// Processes agent output after schema validation. Returned slices must be
/// static or allocated with the supplied allocator. A thrown error aborts the
/// run; return `.retry` for a recoverable validation failure.
pub const Validator = struct {
    context: *anyopaque,
    validateFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        run_context: RunContext,
        output_name: ?[]const u8,
        output_json: []const u8,
    ) anyerror!ValidatorResult,

    pub fn validate(
        self: Validator,
        allocator: std.mem.Allocator,
        run_context: RunContext,
        output_name: ?[]const u8,
        output_json: []const u8,
    ) !ValidatorResult {
        return self.validateFn(self.context, allocator, run_context, output_name, output_json);
    }
};

/// One named structured-output alternative.
pub const Choice = struct {
    name: []const u8,
    description: []const u8 = "",
    schema: []const u8,
    strict: bool = true,
    function: ?Function = null,
};

/// One or more structured-output alternatives.
///
/// Native and prompted modes combine multiple choices with `anyOf`. Tool mode
/// will expose them separately so the selected tool identifies the choice.
pub const Structured = struct {
    choices: []const Choice,
    name: []const u8 = "response",
    description: []const u8 = "",
};

/// Structured output requested through instructions and, where available,
/// provider JSON-object mode. A custom template must contain `{schema}` once.
pub const Prompted = struct {
    output: Structured,
    template: ?[]const u8 = null,
};

/// Structured output requested as one provider function tool per choice.
pub const Tool = struct {
    output: Structured,
};

/// Agent-level output contract. `json_schema` remains the concise single-schema
/// native form; `native` supports named unions and `prompted` works everywhere
/// the model accepts instructions.
pub const Spec = union(enum) {
    text,
    json_object,
    json_schema: model_types.OutputFormat.JsonSchema,
    native: Structured,
    prompted: Prompted,
    tool: Tool,
};

/// One prepared tool-output choice. `arguments_schema` may wrap a scalar
/// schema in `{ "value": ... }` to satisfy provider function-tool contracts.
pub const PreparedChoice = struct {
    choice: Choice,
    arguments_schema: []const u8,
    wrapped: bool = false,
};

/// Output settings resolved for one model request.
pub const Prepared = struct {
    model_format: model_types.OutputFormat,
    validation_format: model_types.OutputFormat,
    prompted_instruction: ?[]const u8 = null,
    validation_required: bool = false,
    tool_definitions: []const model_types.ToolDefinition = &.{},
    tool_choices: []const PreparedChoice = &.{},
    requires_tool_output: bool = false,

    pub fn findToolChoice(self: Prepared, name: []const u8) ?PreparedChoice {
        for (self.tool_choices) |choice| {
            if (std.mem.eql(u8, choice.choice.name, name)) return choice;
        }
        return null;
    }
};

pub const Error = error{
    /// An output name, schema list, schema document, or prompt template is invalid.
    InvalidOutputSpec,
    /// The selected model profile has no native JSON-object output mode.
    JsonObjectOutputNotSupported,
    /// The selected model profile has no native JSON-Schema output mode.
    NativeOutputNotSupported,
    /// Prompted output requires a model capable of receiving instructions.
    PromptedOutputNotSupported,
    /// Tool output requires provider function-tool support.
    ToolOutputNotSupported,
};

/// Translates an agent output strategy into provider wire and local-validation
/// formats. Returned allocated slices live until `arena` is released.
pub fn prepare(
    arena: std.mem.Allocator,
    spec: Spec,
    profile: model_types.ModelProfile,
) (Error || error{OutOfMemory})!Prepared {
    return switch (spec) {
        .text => .{ .model_format = .text, .validation_format = .text },
        .json_object => {
            if (!profile.supports_json_object_output) return error.JsonObjectOutputNotSupported;
            return .{
                .model_format = .json_object,
                .validation_format = .json_object,
            };
        },
        .json_schema => |format| {
            if (!profile.supports_json_schema_output) return error.NativeOutputNotSupported;
            try validateChoice(.{
                .name = format.name,
                .schema = format.schema,
                .strict = format.strict,
            });
            try validateSchema(arena, format.schema);
            return .{
                .model_format = .{ .json_schema = format },
                .validation_format = .{ .json_schema = format },
            };
        },
        .native => |structured| {
            if (!profile.supports_json_schema_output) return error.NativeOutputNotSupported;
            const format = try combinedFormat(arena, structured);
            return .{
                .model_format = .{ .json_schema = format },
                .validation_format = .{ .json_schema = format },
            };
        },
        .prompted => |prompted| {
            if (!profile.supports_system_messages) return error.PromptedOutputNotSupported;
            const format = try combinedFormat(arena, prompted.output);
            const instruction = try renderPrompt(arena, prompted, format.schema);
            return .{
                .model_format = if (profile.supports_json_object_output) .json_object else .text,
                .validation_format = .{ .json_schema = format },
                .prompted_instruction = instruction,
                .validation_required = true,
            };
        },
        .tool => |tool| {
            if (!profile.supports_tools) return error.ToolOutputNotSupported;
            const choices = try prepareToolChoices(arena, tool.output);
            const definitions = try arena.alloc(model_types.ToolDefinition, choices.len);
            for (choices, definitions) |choice, *definition| definition.* = .{
                .name = choice.choice.name,
                .description = if (choice.choice.description.len > 0)
                    choice.choice.description
                else
                    tool.output.description,
                .parameters_json_schema = choice.arguments_schema,
            };
            return .{
                .model_format = .text,
                .validation_format = .text,
                .tool_definitions = definitions,
                .tool_choices = choices,
                .requires_tool_output = true,
            };
        },
    };
}

fn combinedFormat(
    arena: std.mem.Allocator,
    structured: Structured,
) (Error || error{OutOfMemory})!model_types.OutputFormat.JsonSchema {
    if (structured.name.len == 0 or structured.choices.len == 0) return error.InvalidOutputSpec;
    var strict = true;
    for (structured.choices, 0..) |choice, index| {
        try validateChoice(choice);
        if (choice.function != null) return error.InvalidOutputSpec;
        try validateSchema(arena, choice.schema);
        strict = strict and choice.strict;
        for (structured.choices[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, choice.name)) return error.InvalidOutputSpec;
        }
    }
    const schema = if (structured.choices.len == 1)
        structured.choices[0].schema
    else
        try combineSchemas(arena, structured.choices);
    return .{ .name = structured.name, .schema = schema, .strict = strict };
}

fn prepareToolChoices(
    arena: std.mem.Allocator,
    structured: Structured,
) (Error || error{OutOfMemory})![]const PreparedChoice {
    if (structured.choices.len == 0) return error.InvalidOutputSpec;
    const prepared = try arena.alloc(PreparedChoice, structured.choices.len);
    for (structured.choices, prepared, 0..) |choice, *target, index| {
        try validateChoice(choice);
        try validateSchema(arena, choice.schema);
        for (structured.choices[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, choice.name)) return error.InvalidOutputSpec;
        }
        const is_object = try schemaAcceptsObject(arena, choice.schema);
        target.* = .{
            .choice = choice,
            .arguments_schema = if (is_object) choice.schema else try wrapSchema(arena, choice.schema),
            .wrapped = !is_object,
        };
    }
    return prepared;
}

fn schemaAcceptsObject(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}!bool {
    const parsed = json_limits.parse(
        std.json.Value,
        arena,
        source,
        json_limits.defaults.schema,
        .{},
        error.InvalidOutputSpec,
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const schema_type = object.get("type") orelse return false;
    return switch (schema_type) {
        .string => |name| std.mem.eql(u8, name, "object"),
        .array => |names| for (names.items) |name| {
            if (name == .string and std.mem.eql(u8, name.string, "object")) break true;
        } else false,
        else => false,
    };
}

fn wrapSchema(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.concat(arena, u8, &.{
        "{\"type\":\"object\",\"properties\":{\"value\":",
        source,
        "},\"required\":[\"value\"],\"additionalProperties\":false}",
    });
}

/// Validates provider tool arguments and removes the scalar wrapper when one
/// was needed. Returned allocated JSON lives in `arena`.
pub fn decodeToolArguments(
    arena: std.mem.Allocator,
    prepared: PreparedChoice,
    arguments_json: []const u8,
) ![]const u8 {
    try json_schema.validate(arena, .{ .json_schema = .{
        .name = prepared.choice.name,
        .schema = prepared.arguments_schema,
        .strict = prepared.choice.strict,
    } }, arguments_json);
    if (!prepared.wrapped) return arguments_json;
    const parsed = try json_limits.parse(
        std.json.Value,
        arena,
        arguments_json,
        json_limits.defaults.tool_payload,
        .{},
        json_schema.Error.InvalidJsonOutput,
    );
    defer parsed.deinit();
    const value = parsed.value.object.get("value") orelse return json_schema.Error.OutputSchemaValidationFailed;
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

/// Repairs and partially validates accumulated provider tool arguments. The
/// returned JSON lives in `arena`; null means the current prefix cannot yet
/// produce a useful snapshot.
pub fn decodePartialToolArguments(
    arena: std.mem.Allocator,
    prepared: PreparedChoice,
    arguments_prefix: []const u8,
) !?[]const u8 {
    const partial = try json_schema.validatePartial(arena, .{ .json_schema = .{
        .name = prepared.choice.name,
        .schema = prepared.arguments_schema,
        .strict = prepared.choice.strict,
    } }, arguments_prefix) orelse return null;
    if (!prepared.wrapped) return partial.json;
    const value = partial.value.object.get("value") orelse return null;
    return try std.json.Stringify.valueAlloc(arena, value, .{});
}

fn validateChoice(choice: Choice) Error!void {
    if (choice.name.len == 0 or choice.schema.len == 0) return error.InvalidOutputSpec;
}

fn validateSchema(arena: std.mem.Allocator, source: []const u8) (Error || error{OutOfMemory})!void {
    json_schema.validateSchema(arena, source) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutputSpec,
    };
}

fn combineSchemas(
    arena: std.mem.Allocator,
    choices: []const Choice,
) (Error || error{OutOfMemory})![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("anyOf") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (choices) |choice| {
        const parsed = json_limits.parse(
            std.json.Value,
            arena,
            choice.schema,
            json_limits.defaults.schema,
            .{},
            error.InvalidOutputSpec,
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidOutputSpec,
        };
        defer parsed.deinit();
        json.write(parsed.value) catch return error.OutOfMemory;
    }
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn renderPrompt(
    arena: std.mem.Allocator,
    prompted: Prompted,
    schema: []const u8,
) (Error || error{OutOfMemory})![]const u8 {
    if (prompted.template) |template| {
        const marker = "{schema}";
        const index = std.mem.indexOf(u8, template, marker) orelse return error.InvalidOutputSpec;
        if (std.mem.indexOf(u8, template[index + marker.len ..], marker) != null) {
            return error.InvalidOutputSpec;
        }
        return std.mem.concat(arena, u8, &.{ template[0..index], schema, template[index + marker.len ..] });
    }
    return std.fmt.allocPrint(
        arena,
        "Return only one JSON value matching the {s} schema. Do not use Markdown fences or add commentary.\n" ++
            "Description: {s}\nJSON Schema: {s}",
        .{ prompted.output.name, prompted.output.description, schema },
    );
}

test "native output combines named alternatives without owning borrowed schemas" {
    const choices = [_]Choice{
        .{ .name = "success", .schema = "{\"type\":\"object\",\"required\":[\"value\"]}" },
        .{ .name = "failure", .schema = "{\"type\":\"object\",\"required\":[\"error\"]}", .strict = false },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prepared = try prepare(arena.allocator(), .{ .native = .{ .choices = &choices } }, .{
        .supports_json_schema_output = true,
    });
    const format = prepared.model_format.json_schema;
    try std.testing.expectEqualStrings("response", format.name);
    try std.testing.expect(!format.strict);
    try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"anyOf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, format.schema, "\"error\"") != null);
    try std.testing.expect(!prepared.validation_required);

    const single = try prepare(arena.allocator(), .{ .native = .{ .choices = choices[0..1] } }, .{
        .supports_json_schema_output = true,
    });
    try std.testing.expectEqualStrings(choices[0].schema, single.model_format.json_schema.schema);
}

test "prompted output uses JSON mode when available and text otherwise" {
    const choice = [_]Choice{.{ .name = "answer", .schema = "{\"type\":\"object\"}" }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_mode = try prepare(arena.allocator(), .{ .prompted = .{
        .output = .{ .choices = &choice, .name = "answer", .description = "A final answer." },
    } }, .{
        .supports_system_messages = true,
        .supports_json_object_output = true,
    });
    try std.testing.expectEqual(model_types.OutputFormat.json_object, json_mode.model_format);
    try std.testing.expect(json_mode.validation_required);
    try std.testing.expect(std.mem.indexOf(u8, json_mode.prompted_instruction.?, "A final answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_mode.prompted_instruction.?, choice[0].schema) != null);

    const text_mode = try prepare(arena.allocator(), .{ .prompted = .{
        .output = .{ .choices = &choice },
        .template = "Schema follows:\n{schema}",
    } }, .{ .supports_system_messages = true });
    try std.testing.expectEqual(model_types.OutputFormat.text, text_mode.model_format);
    try std.testing.expectEqualStrings("Schema follows:\n{\"type\":\"object\"}", text_mode.prompted_instruction.?);
}

test "tool output exposes alternatives and wraps scalar schemas" {
    const choices = [_]Choice{
        .{ .name = "object", .description = "Return an object.", .schema = "{\"type\":\"object\"}" },
        .{ .name = "number", .schema = "{\"type\":\"integer\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prepared = try prepare(arena.allocator(), .{ .tool = .{ .output = .{
        .choices = &choices,
        .description = "Return a result.",
    } } }, .{ .supports_tools = true });
    try std.testing.expect(prepared.requires_tool_output);
    try std.testing.expectEqual(@as(usize, 2), prepared.tool_definitions.len);
    try std.testing.expectEqualStrings("Return an object.", prepared.tool_definitions[0].description);
    try std.testing.expectEqualStrings("Return a result.", prepared.tool_definitions[1].description);
    try std.testing.expect(!prepared.tool_choices[0].wrapped);
    try std.testing.expect(prepared.tool_choices[1].wrapped);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prepared.tool_definitions[1].parameters_json_schema,
        "\"value\":{\"type\":\"integer\"}",
    ) != null);
    try std.testing.expectEqualStrings(
        "42",
        try decodeToolArguments(arena.allocator(), prepared.tool_choices[1], "{\"value\":42}"),
    );
    try std.testing.expectEqualStrings(
        "4",
        (try decodePartialToolArguments(
            arena.allocator(),
            prepared.tool_choices[1],
            "{\"value\":4",
        )).?,
    );
    try std.testing.expectError(
        json_schema.Error.OutputSchemaValidationFailed,
        decodeToolArguments(arena.allocator(), prepared.tool_choices[1], "{\"value\":\"no\"}"),
    );
    try std.testing.expect(prepared.findToolChoice("missing") == null);

    const object_or_null = [_]Choice{.{
        .name = "nullable_object",
        .schema = "{\"type\":[\"object\",\"null\"]}",
    }};
    const array_type = try prepare(arena.allocator(), .{ .tool = .{ .output = .{
        .choices = &object_or_null,
    } } }, .{ .supports_tools = true });
    try std.testing.expect(!array_type.tool_choices[0].wrapped);
}

test "output preparation rejects unsupported modes and malformed specifications" {
    const choice = [_]Choice{.{ .name = "answer", .schema = "{}" }};
    try std.testing.expectError(error.JsonObjectOutputNotSupported, prepare(
        std.testing.allocator,
        .json_object,
        .{},
    ));
    try std.testing.expectError(error.NativeOutputNotSupported, prepare(
        std.testing.allocator,
        .{ .native = .{ .choices = &choice } },
        .{},
    ));
    try std.testing.expectError(error.PromptedOutputNotSupported, prepare(
        std.testing.allocator,
        .{ .prompted = .{ .output = .{ .choices = &choice } } },
        .{ .supports_system_messages = false },
    ));
    try std.testing.expectError(error.ToolOutputNotSupported, prepare(
        std.testing.allocator,
        .{ .tool = .{ .output = .{ .choices = &choice } } },
        .{ .supports_tools = false },
    ));
    const invalid = [_]Spec{
        .{ .native = .{ .choices = &.{} } },
        .{ .native = .{ .choices = &.{.{ .name = "", .schema = "{}" }} } },
        .{ .native = .{ .choices = &.{.{ .name = "answer", .schema = "[]" }} } },
        .{ .native = .{ .choices = &.{.{ .name = "answer", .schema = "{\"pattern\":\"x\"}" }} } },
        .{ .native = .{ .choices = &.{
            .{ .name = "answer", .schema = "{}" },
            .{ .name = "answer", .schema = "{}" },
        } } },
        .{ .prompted = .{
            .output = .{ .choices = &choice },
            .template = "missing marker",
        } },
        .{ .prompted = .{
            .output = .{ .choices = &choice },
            .template = "{schema} twice {schema}",
        } },
        .{ .native = .{ .choices = &.{.{
            .name = "answer",
            .schema = "{}",
            .function = .{ .context = undefined, .callFn = undefined },
        }} } },
    };
    for (invalid) |spec| {
        try std.testing.expectError(error.InvalidOutputSpec, prepare(std.testing.allocator, spec, .{
            .supports_json_schema_output = true,
            .supports_system_messages = true,
        }));
    }
    try std.testing.expectError(error.InvalidOutputSpec, prepare(
        std.testing.allocator,
        .{ .json_schema = .{ .name = "answer", .schema = "{" } },
        .{ .supports_json_schema_output = true },
    ));
}

fn checkPrepareAllocationFailure(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const choices = [_]Choice{
        .{ .name = "success", .schema = "{\"type\":\"object\"}" },
        .{ .name = "failure", .schema = "{\"type\":\"null\"}" },
    };
    _ = try prepare(arena.allocator(), .{ .prompted = .{
        .output = .{ .choices = &choices },
    } }, .{
        .supports_system_messages = true,
        .supports_json_object_output = true,
    });
}

test "output preparation releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPrepareAllocationFailure, .{});
}
