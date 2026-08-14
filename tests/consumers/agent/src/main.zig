const std = @import("std");
const zigai = @import("zigai");

pub fn main(init: std.process.Init) !void {
    const parts = [_]zigai.Part{.{ .text = "ZigAI consumer works." }};
    var scripted = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    var result = try (zigai.Agent{ .model = scripted.model() }).run(init.gpa, "Check the package.");
    defer result.deinit();
    if (!std.mem.eql(u8, result.output, "ZigAI consumer works.")) return error.UnexpectedOutput;

    const evaluators = [_]zigai.evals.Evaluator{zigai.evals.exactMatch()};
    var evaluation_model = zigai.testing.ScriptedModel{ .responses = &.{.{ .parts = &parts }} };
    var report = try (zigai.evals.Dataset{
        .cases = &.{.{
            .name = "package",
            .prompt = "Check the package.",
            .expected_output = "ZigAI consumer works.",
        }},
        .evaluators = &evaluators,
    }).run(init.gpa, .{ .model = evaluation_model.model() });
    defer report.deinit();
    if (!report.passed()) return error.EvaluationFailed;
}
