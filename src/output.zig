//! Agent-level output strategies translated into the smaller model wire
//! contract. Specifications borrow their schemas and templates for one run;
//! prepared schemas and prompted instructions are allocated in the run arena.

const std = @import("std");
const json_limits = @import("json.zig");
const model_types = @import("model.zig");

/// One named structured-output alternative.
pub const Choice = struct {
    name: []const u8,
    description: []const u8 = "",
    schema: []const u8,
    strict: bool = true,
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

/// Agent-level output contract. `json_schema` remains the concise single-schema
/// native form; `native` supports named unions and `prompted` works everywhere
/// the model accepts instructions.
pub const Spec = union(enum) {
    text,
    json_object,
    json_schema: model_types.OutputFormat.JsonSchema,
    native: Structured,
    prompted: Prompted,
};

/// Output settings resolved for one model request.
pub const Prepared = struct {
    model_format: model_types.OutputFormat,
    validation_format: model_types.OutputFormat,
    prompted_instruction: ?[]const u8 = null,
    validation_required: bool = false,
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

fn validateChoice(choice: Choice) Error!void {
    if (choice.name.len == 0 or choice.schema.len == 0) return error.InvalidOutputSpec;
}

fn validateSchema(arena: std.mem.Allocator, source: []const u8) (Error || error{OutOfMemory})!void {
    const parsed = json_limits.parse(
        std.json.Value,
        arena,
        source,
        json_limits.defaults.schema,
        .{},
        error.InvalidOutputSpec,
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutputSpec,
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .bool, .object => {},
        else => return error.InvalidOutputSpec,
    }
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
    const invalid = [_]Spec{
        .{ .native = .{ .choices = &.{} } },
        .{ .native = .{ .choices = &.{.{ .name = "", .schema = "{}" }} } },
        .{ .native = .{ .choices = &.{.{ .name = "answer", .schema = "[]" }} } },
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
