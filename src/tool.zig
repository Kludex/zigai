//! Ordered policy stages for provider-neutral function tools.

const std = @import("std");
const model = @import("model.zig");

/// Immutable run state shared by every policy stage.
pub const RunContext = struct {
    messages: []const model.Message = &.{},
    usage: model.RunUsage = .{},
    model_requests: usize = 0,
    dependencies: ?*anyopaque = null,
    /// Active and on-demand-loaded capability IDs for this model step.
    capabilities: model.CapabilitySnapshot = .{},
    control: model.RunControl = .{},

    pub fn dependency(self: RunContext, comptime T: type) ?*T {
        const pointer = self.dependencies orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
};

/// State available for one model-request tool preparation pass.
pub const Prepare = struct {
    run: RunContext,
    tool: model.Tool,
    enabled: bool = true,
};

/// State shared by validation, approval, call, and return stages.
pub const CallContext = struct {
    run: RunContext,
    call: model.ToolCall,
    tool: model.Tool,
    retry_number: usize = 0,
    approved: bool = false,
};

/// Mutable arguments before approval or execution. A retry message prevents
/// later stages and is returned to the model as a recoverable tool failure.
pub const Arguments = struct {
    context: CallContext,
    arguments_json: []const u8,
    retry_message: ?[]const u8 = null,
};

/// Mutable execution decision evaluated only after arguments are valid.
pub const Approval = struct {
    context: CallContext,
    arguments_json: []const u8,
    execution: model.ToolExecution,
};

/// Mutable state immediately before the executor. Supplying `output` skips
/// the executor and continues through the return stage.
pub const Call = struct {
    context: CallContext,
    arguments_json: []const u8,
    output: ?model.ToolOutput = null,
};

/// Mutable executor output before it is made model-visible. A retry message
/// converts the return into a recoverable, per-tool retry.
pub const Return = struct {
    context: CallContext,
    arguments_json: []const u8,
    output: model.ToolOutput,
    retry_message: ?[]const u8 = null,
};

/// The stable, ordered stages of a function-tool lifecycle.
pub const Event = union(enum) {
    prepare: *Prepare,
    arguments: *Arguments,
    approval: *Approval,
    call: *Call,
    return_value: *Return,
};

/// One composable tool policy. Policies run in registration order. Any slices
/// stored in an event must either outlive the run or use the supplied allocator.
pub const Policy = struct {
    context: *anyopaque,
    applyFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        event: Event,
    ) anyerror!void,

    pub fn apply(self: Policy, allocator: std.mem.Allocator, event: Event) !void {
        return self.applyFn(self.context, allocator, event);
    }
};

/// Applies policies deterministically in slice order.
pub fn applyAll(policies: []const Policy, allocator: std.mem.Allocator, event: Event) !void {
    for (policies) |policy| try policy.apply(allocator, event);
}

test "tool policies compose every lifecycle stage in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_allocator = arena.allocator();
    const Capture = struct {
        sequence: [10]u8 = undefined,
        count: usize = 0,

        fn apply(context: *anyopaque, allocator: std.mem.Allocator, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sequence[self.count] = switch (event) {
                .prepare => |value| prepare: {
                    value.tool.definition.description = try std.mem.concat(
                        allocator,
                        u8,
                        &.{ value.tool.definition.description, "!" },
                    );
                    break :prepare 1;
                },
                .arguments => |value| arguments: {
                    value.arguments_json = try allocator.dupe(u8, "{\"ok\":true}");
                    value.retry_message = "retry arguments";
                    break :arguments 2;
                },
                .approval => |value| approval: {
                    try std.testing.expectEqualStrings("{}", value.arguments_json);
                    value.execution = .requires_approval;
                    break :approval 3;
                },
                .call => |value| call: {
                    value.output = .{ .content = "short circuit" };
                    break :call 4;
                },
                .return_value => |value| returned: {
                    try std.testing.expectEqualStrings("{\"ok\":true}", value.arguments_json);
                    value.output.content = "validated";
                    value.retry_message = "retry result";
                    break :returned 5;
                },
            };
            self.count += 1;
        }
    };
    var first: Capture = .{};
    var second: Capture = .{};
    const policies = [_]Policy{
        .{ .context = &first, .applyFn = Capture.apply },
        .{ .context = &second, .applyFn = Capture.apply },
    };
    var dependency: u32 = 42;
    const run = RunContext{ .dependencies = &dependency };
    try std.testing.expectEqual(@as(u32, 42), run.dependency(u32).?.*);
    try std.testing.expect((RunContext{}).dependency(u32) == null);

    var tool_context: u8 = 0;
    var prepared = Prepare{
        .run = run,
        .tool = .{
            .definition = .{ .name = "demo", .description = "tool", .parameters_json_schema = "{}" },
            .context = &tool_context,
        },
    };
    try applyAll(&policies, test_allocator, .{ .prepare = &prepared });
    try std.testing.expectEqualStrings("tool!!", prepared.tool.definition.description);

    const call_context = CallContext{
        .run = run,
        .call = .{ .id = "call", .name = "demo", .arguments_json = "{}" },
        .tool = prepared.tool,
    };
    var arguments = Arguments{ .context = call_context, .arguments_json = "{}" };
    try applyAll(policies[0..1], test_allocator, .{ .arguments = &arguments });
    try std.testing.expectEqualStrings("retry arguments", arguments.retry_message.?);

    var approval = Approval{ .context = call_context, .arguments_json = "{}", .execution = .immediate };
    try applyAll(policies[0..1], test_allocator, .{ .approval = &approval });
    try std.testing.expectEqual(model.ToolExecution.requires_approval, approval.execution);

    var call = Call{ .context = call_context, .arguments_json = arguments.arguments_json };
    try applyAll(policies[0..1], test_allocator, .{ .call = &call });
    try std.testing.expectEqualStrings("short circuit", call.output.?.content);

    var returned = Return{
        .context = call_context,
        .arguments_json = arguments.arguments_json,
        .output = call.output.?,
    };
    try applyAll(policies[0..1], test_allocator, .{ .return_value = &returned });
    try std.testing.expectEqualStrings("validated", returned.output.content);
    try std.testing.expectEqualStrings("retry result", returned.retry_message.?);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, first.sequence[0..first.count]);
    try std.testing.expectEqualSlices(u8, &.{1}, second.sequence[0..second.count]);
}
