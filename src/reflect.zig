//! Comptime tool derivation: turn a plain Zig function into a `Tool`, deriving
//! its JSON Schema from the parameter struct and its argument decoding from the
//! same type. This module owns no runtime state; every schema string is built
//! at comptime and lives in the binary's constant data.

const std = @import("std");
const model_types = @import("model.zig");

const Tool = model_types.Tool;
const ToolRunContext = model_types.ToolRunContext;

/// Derive a `Tool` from `func`, whose first parameter is a struct describing the
/// arguments and whose second (optional) parameter is a `ToolRunContext`.
pub fn tool(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime func: anytype,
) Tool {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    if (info.params.len == 0) @compileError("tool " ++ name ++ " needs an arguments struct parameter");
    const Args = info.params[0].type.?;
    const Return = info.return_type orelse @compileError("tool " ++ name ++ " must have a return type");
    const ReturnValue = switch (@typeInfo(Return)) {
        .error_union => |value| value.payload,
        else => Return,
    };
    const SchemaValue = toolReturnValueType(ReturnValue);

    const Wrapper = struct {
        var placeholder: u8 = 0;

        fn execute(_: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) anyerror![]const u8 {
            return (try invokeOutput(allocator, .{}, arguments_json)).content;
        }

        fn executeOutput(_: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!model_types.ToolOutput {
            return invokeOutput(allocator, .{}, arguments_json);
        }

        fn validate(_: *anyopaque, allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!void {
            _ = std.json.parseFromSliceLeaky(Args, allocator, arguments_json, .{
                .ignore_unknown_fields = true,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidToolArguments,
            };
        }

        fn executeWithContext(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: ToolRunContext,
            arguments_json: []const u8,
        ) anyerror![]const u8 {
            return (try invokeOutput(allocator, run_context, arguments_json)).content;
        }

        fn executeOutputWithContext(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run_context: ToolRunContext,
            arguments_json: []const u8,
        ) anyerror!model_types.ToolOutput {
            return invokeOutput(allocator, run_context, arguments_json);
        }

        fn invokeOutput(
            allocator: std.mem.Allocator,
            run_context: ToolRunContext,
            arguments_json: []const u8,
        ) anyerror!model_types.ToolOutput {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const args = std.json.parseFromSliceLeaky(Args, arena.allocator(), arguments_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidToolArguments;
            const result = if (info.params.len == 1) try func(args) else try func(args, run_context);
            if (comptime isToolReturn(@TypeOf(result))) return .{
                .content = try encode(allocator, result.value), // kcov-ignore
                .follow_up_messages = try copyMessages(allocator, result.follow_up_messages),
            };
            return .{ .content = try encode(allocator, result) };
        }

        fn encode(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
            const T = @TypeOf(value);
            if (T == []const u8 or T == []u8) return allocator.dupe(u8, value);
            return std.json.Stringify.valueAlloc(allocator, value, .{});
        }
    };

    return .{
        .definition = .{
            .name = name,
            .description = description,
            .parameters_json_schema = schemaOf(Args),
            .return_json_schema = schemaOf(SchemaValue),
        },
        .context = &Wrapper.placeholder,
        .validateFn = Wrapper.validate,
        .executeFn = Wrapper.execute,
        .executeWithContextFn = if (info.params.len > 1) Wrapper.executeWithContext else null,
        .executeOutputFn = Wrapper.executeOutput,
        .executeOutputWithContextFn = if (info.params.len > 1) Wrapper.executeOutputWithContext else null,
    };
}

fn isToolReturn(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zigai_tool_return");
}

fn toolReturnValueType(comptime T: type) type {
    if (isToolReturn(T)) return T.ValueType;
    return T;
}

fn copyMessages(
    allocator: std.mem.Allocator,
    source: []const model_types.RequestMessage,
) ![]const model_types.RequestMessage {
    const messages = try allocator.alloc(model_types.RequestMessage, source.len);
    for (source, messages) |message, *copy| {
        const parts = try allocator.alloc(model_types.RequestPart, message.parts.len);
        for (message.parts, parts) |part, *part_copy| {
            part_copy.* = try model_types.dupeRequestPart(allocator, part);
        }
        const instruction_parts = try allocator.alloc(model_types.InstructionPart, message.instruction_parts.len);
        for (message.instruction_parts, instruction_parts) |part, *part_copy| part_copy.* = .{
            .content = try allocator.dupe(u8, part.content),
            .dynamic = part.dynamic,
        };
        copy.* = .{
            .parts = parts,
            .timestamp_unix_ms = message.timestamp_unix_ms,
            .instruction_parts = instruction_parts,
            .instructions = if (message.instructions) |value| try allocator.dupe(u8, value) else null,
            .run_id = if (message.run_id) |value| try allocator.dupe(u8, value) else null,
            .conversation_id = if (message.conversation_id) |value| try allocator.dupe(u8, value) else null,
            .metadata = try copyMetadata(allocator, message.metadata),
            .state = message.state,
        };
    }
    return messages;
}

fn copyUserContent(allocator: std.mem.Allocator, part: model_types.UserContent) !model_types.UserContent {
    return model_types.dupeUserContent(allocator, part);
}

fn copyContent(allocator: std.mem.Allocator, value: model_types.Content) !model_types.Content {
    return model_types.dupeContent(allocator, value);
}

fn copyMetadata(allocator: std.mem.Allocator, source: []const model_types.Metadata) ![]const model_types.Metadata {
    return model_types.dupeMetadata(allocator, source);
}

/// Derive one `Tool` per public function of `Namespace`. A function named `foo`
/// takes its description from `pub const foo_description`.
pub fn toolsOf(comptime Namespace: type) []const Tool {
    const derived = struct {
        const items = build: {
            var list: []const Tool = &.{};
            for (@typeInfo(Namespace).@"struct".decls) |decl| {
                const value = @field(Namespace, decl.name);
                if (@typeInfo(@TypeOf(value)) != .@"fn") continue;
                if (!@hasDecl(Namespace, decl.name ++ "_description")) {
                    @compileError("missing `pub const " ++ decl.name ++ "_description` for tool " ++ decl.name);
                }
                const description = @field(Namespace, decl.name ++ "_description");
                list = list ++ &[_]Tool{tool(decl.name, description, value)};
            }
            break :build list[0..list.len].*;
        };
    };
    return &derived.items;
}

/// JSON Schema for `T`, built entirely at comptime and stored as static data.
pub fn schemaOf(comptime T: type) []const u8 {
    const derived = struct {
        const text: []const u8 = buildSchema(T);
    };
    return derived.text;
}

fn buildSchema(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "{\"type\":\"boolean\"}",
        .void => "{\"type\":\"null\"}",
        .int, .comptime_int => "{\"type\":\"integer\"}",
        .float, .comptime_float => "{\"type\":\"number\"}",
        .optional => |optional| "{\"anyOf\":[" ++ buildSchema(optional.child) ++ ",{\"type\":\"null\"}]}",
        .@"enum" => |enumeration| blk: {
            var variants: []const u8 = "";
            for (enumeration.fields, 0..) |field, index| {
                variants = variants ++ (if (index == 0) "" else ",") ++ "\"" ++ field.name ++ "\"";
            }
            break :blk "{\"type\":\"string\",\"enum\":[" ++ variants ++ "]}";
        },
        .pointer => |pointer| if (pointer.size == .slice)
            (if (pointer.child == u8)
                "{\"type\":\"string\"}"
            else
                "{\"type\":\"array\",\"items\":" ++ buildSchema(pointer.child) ++ "}")
        else
            @compileError("unsupported tool parameter type: " ++ @typeName(T)),
        .@"struct" => |structure| blk: {
            var properties: []const u8 = "";
            var required: []const u8 = "";
            for (structure.fields) |field| {
                if (properties.len != 0) properties = properties ++ ",";
                properties = properties ++ "\"" ++ field.name ++ "\":" ++ buildSchema(field.type);
                if (field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
                    if (required.len != 0) required = required ++ ",";
                    required = required ++ "\"" ++ field.name ++ "\"";
                }
            }
            break :blk "{\"type\":\"object\",\"properties\":{" ++ properties ++
                "},\"required\":[" ++ required ++ "],\"additionalProperties\":false}";
        },
        else => @compileError("unsupported tool parameter type: " ++ @typeName(T)),
    };
}

const Unit = enum { celsius, fahrenheit };

fn weather(args: struct { city: []const u8, unit: Unit = .celsius, days: ?u8 = null }) ![]const u8 {
    _ = args.days;
    return switch (args.unit) {
        .celsius => "31",
        .fahrenheit => "88",
    };
}

test "derives a schema from the arguments struct" {
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"city":{"type":"string"},"unit":{"type":"string","enum":["celsius","fahrenheit"]},"days":{"anyOf":[{"type":"integer"},{"type":"null"}]}},"required":["city"],"additionalProperties":false}
    , schemaOf(@typeInfo(@TypeOf(weather)).@"fn".params[0].type.?));
}

test "decodes arguments and runs the function" {
    const derived = tool("weather", "Get the current weather for a city.", weather);
    try std.testing.expectEqualStrings("weather", derived.definition.name);

    const celsius = try derived.execute(std.testing.allocator, "{\"city\":\"Lisbon\"}");
    defer std.testing.allocator.free(celsius);
    try std.testing.expectEqualStrings("31", celsius);

    const fahrenheit = try derived.execute(std.testing.allocator, "{\"city\":\"Lisbon\",\"unit\":\"fahrenheit\"}");
    defer std.testing.allocator.free(fahrenheit);
    try std.testing.expectEqualStrings("88", fahrenheit);

    try std.testing.expectError(error.InvalidToolArguments, derived.execute(std.testing.allocator, "{}"));
}

test "serializes non-string return values as JSON" {
    const Point = struct { x: i32, y: i32 };
    const origin = struct {
        fn call(args: struct { scale: i32 }) !Point {
            return .{ .x = args.scale, .y = args.scale * 2 };
        }
    }.call;
    const derived = tool("origin", "Scale the origin.", origin);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"}},\"required\":[\"x\",\"y\"],\"additionalProperties\":false}",
        derived.definition.return_json_schema.?,
    );
    const encoded = try derived.execute(std.testing.allocator, "{\"scale\":3}");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"x\":3,\"y\":6}", encoded);
}

test "typed tool returns carry schema and copied follow-up messages" {
    const Answer = struct { count: usize };
    const count = struct {
        fn call(args: struct { items: usize }, run_context: ToolRunContext) !model_types.ToolReturn(Answer) {
            return .{
                .value = .{ .count = args.items + run_context.model_requests }, // kcov-ignore
                .follow_up_messages = &.{.{
                    .parts = &.{
                        .{ .user_prompt = .{ .text = "Use this additional context." } },
                        .{ .user_prompt = .{ .image = .{
                            .source = .{ .bytes = "pixels" },
                            .media_type = "image/png",
                            .filename = "image.png",
                            .thought_signature = "image-signature",
                            .metadata = &.{.{ .key = "quality", .value = "high" }},
                        } } },
                        .{ .user_prompt = .{ .audio = .{ .source = .{ .url = "https://example.test/audio" }, .media_type = "audio/mpeg" } } },
                        .{ .user_prompt = .{ .document = .{
                            .source = .{ .provider_file = .{ .id = "file-1", .provider = "provider" } },
                            .media_type = "application/pdf",
                        } } },
                        .{ .user_prompt = .{ .binary = .{ .source = .{ .bytes = "bytes" }, .media_type = "application/octet-stream" } } },
                    },
                    .instruction_parts = &.{.{ .content = "Structured instruction.", .dynamic = true }},
                    .metadata = &.{.{ .key = "source", .value = "tool" }},
                }},
            };
        }
    }.call;
    const derived = tool("count", "Count items.", count);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = try derived.executeOutputWithContext(
        arena.allocator(),
        .{ .model_requests = 2 },
        "{\"items\":3}",
    );
    try std.testing.expectEqualStrings("{\"count\":5}", output.content);
    try std.testing.expectEqualStrings("Use this additional context.", output.follow_up_messages[0].parts[0].user_prompt.text);
    try std.testing.expectEqualStrings("pixels", output.follow_up_messages[0].parts[1].user_prompt.image.source.bytes);
    try std.testing.expectEqualStrings("https://example.test/audio", output.follow_up_messages[0].parts[2].user_prompt.audio.source.url);
    try std.testing.expectEqualStrings("file-1", output.follow_up_messages[0].parts[3].user_prompt.document.source.provider_file.id);
    try std.testing.expectEqualStrings("bytes", output.follow_up_messages[0].parts[4].user_prompt.binary.source.bytes);
    try std.testing.expectEqualStrings("Structured instruction.", output.follow_up_messages[0].instruction_parts[0].content);
    try std.testing.expect(output.follow_up_messages[0].instruction_parts[0].dynamic);
    try std.testing.expectEqualStrings("tool", output.follow_up_messages[0].metadata[0].value);
    try std.testing.expect(std.mem.indexOf(u8, derived.definition.return_json_schema.?, "\"count\":{\"type\":\"integer\"}") != null);
}

test "request follow-up copies preserve every request field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try copyMessages(arena.allocator(), &.{.{
        .parts = &.{
            .{ .system_prompt = "system" },
            .{ .retry_prompt = "retry" },
            .{ .tool_return = .{ .call_id = "call", .name = "tool", .content = "result", .is_error = true } },
        },
        .timestamp_unix_ms = 10,
        .instruction_parts = &.{.{ .content = "structured", .dynamic = true }},
        .instructions = "instructions",
        .run_id = "run",
        .conversation_id = "conversation",
        .metadata = &.{.{ .key = "key", .value = "value" }},
        .state = .interrupted,
    }});
    try std.testing.expectEqualStrings("system", copied[0].parts[0].system_prompt);
    try std.testing.expectEqualStrings("retry", copied[0].parts[1].retry_prompt);
    try std.testing.expect(copied[0].parts[2].tool_return.is_error);
    try std.testing.expectEqual(@as(?i64, 10), copied[0].timestamp_unix_ms);
    try std.testing.expectEqualStrings("structured", copied[0].instruction_parts[0].content);
    try std.testing.expect(copied[0].instruction_parts[0].dynamic);
    try std.testing.expectEqual(model_types.RequestState.interrupted, copied[0].state);
}

test "derives every public function of a namespace" {
    const tools = toolsOf(struct {
        pub const add_description = "Add two numbers.";
        pub fn add(args: struct { a: i64, b: i64 }) !i64 {
            return args.a + args.b;
        }

        pub const echo_description = "Echo the run's model request count.";
        pub fn echo(args: struct { text: []const u8 }, run_context: ToolRunContext) ![]const u8 {
            _ = args;
            _ = run_context;
            return "ok";
        }
    });
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("add", tools[0].definition.name);
    try std.testing.expectEqualStrings("Add two numbers.", tools[0].definition.description);
    try std.testing.expect(tools[0].executeWithContextFn == null);
    try std.testing.expect(tools[1].executeWithContextFn != null);

    const sum = try tools[0].execute(std.testing.allocator, "{\"a\":2,\"b\":40}");
    defer std.testing.allocator.free(sum);
    try std.testing.expectEqualStrings("42", sum);
    const echoed = try tools[1].executeWithContext(std.testing.allocator, .{ .model_requests = 3 }, "{\"text\":\"hello\"}");
    defer std.testing.allocator.free(echoed);
    try std.testing.expectEqualStrings("ok", echoed);
}
