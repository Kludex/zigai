//! Deterministic baseline/candidate evaluation report comparison and CI output.

const std = @import("std");
const evals = @import("evals.zig");
const model_types = @import("model.zig");

/// Stable machine-readable comparison document version.
pub const format_version: u8 = 1;

/// Structural failures that make two reports unsafe to compare.
pub const Error = error{
    InvalidLabel,
    InvalidReport,
    DuplicateCaseIdentity,
    DuplicateEvaluator,
    CaseIdentityMismatch,
};

/// How one baseline item changed in the candidate report.
pub const Change = enum {
    unchanged,
    improved,
    regressed,
    added,
    removed,
};

/// Immutable pass summary copied into a comparison report.
pub const Summary = struct {
    /// Total case runs.
    runs: usize,
    /// Passing case runs.
    passed_runs: usize,
    /// Null for an empty report.
    pass_rate: ?f64,
};

/// Signed candidate-minus-baseline aggregate usage changes.
pub const UsageDelta = struct {
    /// Input-token change.
    input_tokens: i128,
    /// Cache-write-token change.
    cache_write_tokens: i128,
    /// Cache-read-token change.
    cache_read_tokens: i128,
    /// Output-token change.
    output_tokens: i128,
    /// Reasoning-token change.
    reasoning_tokens: i128,
    /// Input-audio-token change.
    input_audio_tokens: i128,
    /// Cached-audio-read-token change.
    cache_audio_read_tokens: i128,
    /// Output-audio-token change.
    output_audio_tokens: i128,
    /// Provider-request-count change.
    requests: i128,
    /// Function-tool-call-count change.
    tool_calls: i128,
    /// Aggregate provider-request-latency change.
    request_duration_ms: i128,
    /// Aggregate agent-run-latency change.
    run_duration_ms: i128,
    /// Null only when neither report contains cost data.
    cost_nano_usd: ?i128,
};

/// One evaluator comparison within a stable case/run identity.
pub const EvaluationComparison = struct {
    /// Stable evaluator name.
    evaluator: []const u8,
    /// Classified candidate change.
    change: Change,
    /// Baseline assertion, or null for candidate-only entries.
    baseline_passed: ?bool,
    /// Candidate assertion, or null for removed entries.
    candidate_passed: ?bool,
    /// Optional baseline score.
    baseline_score: ?f64,
    /// Optional candidate score.
    candidate_score: ?f64,
    /// Candidate minus baseline when both finite scores exist.
    score_delta: ?f64,
};

/// One source-case repetition comparison.
pub const CaseComparison = struct {
    /// Stable source case name.
    name: []const u8,
    /// Zero-based source case index.
    case_index: usize,
    /// One-based repetition index.
    repetition: usize,
    /// Classified candidate change.
    change: Change,
    /// Baseline run assertion, or null for candidate-only entries.
    baseline_passed: ?bool,
    /// Candidate run assertion, or null for removed entries.
    candidate_passed: ?bool,
    /// Ordered evaluator comparisons.
    evaluations: []const EvaluationComparison,
};

/// One report-level analysis comparison.
pub const AnalysisComparison = struct {
    /// Stable report evaluator name.
    evaluator: []const u8,
    /// Classified candidate change.
    change: Change,
    /// Optional baseline assertion.
    baseline_passed: ?bool,
    /// Optional candidate assertion.
    candidate_passed: ?bool,
    /// Optional baseline scalar.
    baseline_value: ?f64,
    /// Optional candidate scalar.
    candidate_value: ?f64,
    /// Candidate minus baseline when both finite values exist.
    value_delta: ?f64,
    /// Optional baseline unit.
    baseline_unit: ?[]const u8,
    /// Optional candidate unit.
    candidate_unit: ?[]const u8,
};

/// Labels copied into the comparison and its CI document.
pub const Options = struct {
    /// Human-readable baseline label retained in output.
    baseline_name: []const u8 = "baseline",
    /// Human-readable candidate label retained in output.
    candidate_name: []const u8 = "candidate",
};

/// Arena-owned deterministic comparison.
pub const Report = struct {
    /// Storage backing the complete comparison graph.
    arena: std.heap.ArenaAllocator,
    /// Owned baseline label.
    baseline_name: []const u8,
    /// Owned candidate label.
    candidate_name: []const u8,
    /// Baseline pass summary.
    baseline: Summary,
    /// Candidate pass summary.
    candidate: Summary,
    /// Candidate-minus-baseline pass-rate change when both rates exist.
    pass_rate_delta: ?f64,
    /// Signed aggregate usage changes.
    usage_delta: UsageDelta,
    /// Stable ordered case/run comparisons.
    cases: []const CaseComparison,
    /// Stable ordered report-analysis comparisons.
    analyses: []const AnalysisComparison,
    /// Regressed, removed, or newly failing case count.
    case_regressions: usize,
    /// Regressed, removed, or newly failing evaluator count.
    evaluation_regressions: usize,
    /// Regressed, removed, or newly failing analysis count.
    analysis_regressions: usize,
    /// Improved or newly passing case count.
    case_improvements: usize,
    /// Improved or newly passing evaluator count.
    evaluation_improvements: usize,
    /// Improved or newly passing analysis count.
    analysis_improvements: usize,

    /// Releases the complete comparison graph.
    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Total regression entries across cases, evaluators, and analyses.
    pub fn regressions(self: Report) usize {
        return self.case_regressions + self.evaluation_regressions + self.analysis_regressions;
    }

    /// Total improvement entries across cases, evaluators, and analyses.
    pub fn improvements(self: Report) usize {
        return self.case_improvements + self.evaluation_improvements + self.analysis_improvements;
    }

    /// True when no candidate regression or removed assertion was detected.
    pub fn regressionFree(self: Report) bool {
        return self.regressions() == 0;
    }
};

/// Compares reports by stable `(case_index, repetition)` identities and
/// evaluator names. Baseline order is preserved; candidate-only entries follow
/// in candidate order.
pub fn compare(
    allocator: std.mem.Allocator,
    baseline: evals.ReportView,
    candidate: evals.ReportView,
    baseline_analyses: []const evals.AnalysisResult,
    candidate_analyses: []const evals.AnalysisResult,
    options: Options,
) !Report {
    if (options.baseline_name.len == 0 or options.candidate_name.len == 0) return Error.InvalidLabel;
    try validateReport(baseline, baseline_analyses);
    try validateReport(candidate, candidate_analyses);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    var case_results: std.ArrayList(CaseComparison) = .empty;
    const candidate_seen = try memory.alloc(bool, candidate.cases.len);
    @memset(candidate_seen, false);
    var counts = Counts{};

    for (baseline.cases) |baseline_case| {
        const candidate_index = findCase(candidate.cases, baseline_case.case_index, baseline_case.repetition);
        const candidate_case = if (candidate_index) |index| blk: {
            candidate_seen[index] = true;
            break :blk candidate.cases[index];
        } else null;
        try case_results.append(memory, try compareCase(memory, baseline_case, candidate_case, &counts));
    }
    for (candidate.cases, 0..) |candidate_case, index| {
        if (candidate_seen[index]) continue;
        try case_results.append(memory, try compareCase(memory, null, candidate_case, &counts));
    }

    const analyses = try compareAnalyses(memory, baseline_analyses, candidate_analyses, &counts);
    const baseline_summary = summary(baseline);
    const candidate_summary = summary(candidate);
    const baseline_name = try memory.dupe(u8, options.baseline_name);
    const candidate_name = try memory.dupe(u8, options.candidate_name);
    const cases = try case_results.toOwnedSlice(memory);
    return .{
        .arena = arena,
        .baseline_name = baseline_name,
        .candidate_name = candidate_name,
        .baseline = baseline_summary,
        .candidate = candidate_summary,
        .pass_rate_delta = optionalDelta(baseline_summary.pass_rate, candidate_summary.pass_rate),
        .usage_delta = usageDelta(baseline.usage, candidate.usage),
        .cases = cases,
        .analyses = analyses,
        .case_regressions = counts.case_regressions,
        .evaluation_regressions = counts.evaluation_regressions,
        .analysis_regressions = counts.analysis_regressions,
        .case_improvements = counts.case_improvements,
        .evaluation_improvements = counts.evaluation_improvements,
        .analysis_improvements = counts.analysis_improvements,
    };
}

/// Convenience wrapper for complete arena-owned eval reports.
pub fn compareReports(
    allocator: std.mem.Allocator,
    baseline: evals.Report,
    candidate: evals.Report,
    options: Options,
) !Report {
    return compare(
        allocator,
        baseline.view(),
        candidate.view(),
        baseline.analyses,
        candidate.analyses,
        options,
    );
}

/// Emits stable indented JSON suitable for CI artifacts and regression gates.
/// The conclusion is `pass` exactly when `comparison.regressionFree()` is true.
pub fn stringifyCiJson(allocator: std.mem.Allocator, comparison: Report) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("version") catch return error.OutOfMemory;
    json.write(format_version) catch return error.OutOfMemory;
    json.objectField("conclusion") catch return error.OutOfMemory;
    json.write(if (comparison.regressionFree()) "pass" else "fail") catch return error.OutOfMemory;
    inline for (.{
        "baseline_name",
        "candidate_name",
        "baseline",
        "candidate",
        "pass_rate_delta",
        "usage_delta",
        "case_regressions",
        "evaluation_regressions",
        "analysis_regressions",
        "case_improvements",
        "evaluation_improvements",
        "analysis_improvements",
        "cases",
        "analyses",
    }) |field_name| {
        json.objectField(field_name) catch return error.OutOfMemory;
        json.write(@field(comparison, field_name)) catch return error.OutOfMemory;
    }
    json.endObject() catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

const Counts = struct {
    case_regressions: usize = 0,
    evaluation_regressions: usize = 0,
    analysis_regressions: usize = 0,
    case_improvements: usize = 0,
    evaluation_improvements: usize = 0,
    analysis_improvements: usize = 0,
};

fn compareCase(
    allocator: std.mem.Allocator,
    baseline: ?evals.CaseResult,
    candidate: ?evals.CaseResult,
    counts: *Counts,
) !CaseComparison {
    if (baseline != null and candidate != null and !std.mem.eql(u8, baseline.?.name, candidate.?.name))
        return Error.CaseIdentityMismatch;
    const change: Change = if (baseline == null)
        .added
    else if (candidate == null)
        .removed
    else if (!baseline.?.passed() and candidate.?.passed())
        .improved
    else if (baseline.?.passed() and !candidate.?.passed())
        .regressed
    else
        .unchanged;
    const regression = change == .removed or change == .regressed or
        (change == .added and !candidate.?.passed());
    const improvement = change == .improved or (change == .added and candidate.?.passed());
    if (regression) counts.case_regressions += 1;
    if (improvement) counts.case_improvements += 1;
    const source = baseline orelse candidate.?;
    return .{
        .name = try allocator.dupe(u8, source.name),
        .case_index = source.case_index,
        .repetition = source.repetition,
        .change = change,
        .baseline_passed = if (baseline) |value| value.passed() else null,
        .candidate_passed = if (candidate) |value| value.passed() else null,
        .evaluations = try compareEvaluations(
            allocator,
            if (baseline) |value| value.evaluations else &.{},
            if (candidate) |value| value.evaluations else &.{},
            counts,
        ),
    };
}

fn compareEvaluations(
    allocator: std.mem.Allocator,
    baseline: []const evals.EvaluationResult,
    candidate: []const evals.EvaluationResult,
    counts: *Counts,
) ![]const EvaluationComparison {
    var results: std.ArrayList(EvaluationComparison) = .empty;
    const candidate_seen = try allocator.alloc(bool, candidate.len);
    @memset(candidate_seen, false);
    for (baseline) |baseline_evaluation| {
        const candidate_index = findEvaluation(candidate, baseline_evaluation.evaluator);
        const candidate_evaluation = if (candidate_index) |index| blk: {
            candidate_seen[index] = true;
            break :blk candidate[index];
        } else null;
        try results.append(allocator, try compareEvaluation(allocator, baseline_evaluation, candidate_evaluation, counts));
    }
    for (candidate, 0..) |candidate_evaluation, index| {
        if (candidate_seen[index]) continue;
        try results.append(allocator, try compareEvaluation(allocator, null, candidate_evaluation, counts));
    }
    return results.toOwnedSlice(allocator);
}

fn compareEvaluation(
    allocator: std.mem.Allocator,
    baseline: ?evals.EvaluationResult,
    candidate: ?evals.EvaluationResult,
    counts: *Counts,
) !EvaluationComparison {
    const change: Change = if (baseline == null)
        .added
    else if (candidate == null)
        .removed
    else if (!baseline.?.passed and candidate.?.passed)
        .improved
    else if (baseline.?.passed and !candidate.?.passed)
        .regressed
    else
        .unchanged;
    const regression = change == .removed or change == .regressed or
        (change == .added and !candidate.?.passed);
    const improvement = change == .improved or (change == .added and candidate.?.passed);
    if (regression) counts.evaluation_regressions += 1;
    if (improvement) counts.evaluation_improvements += 1;
    const source = baseline orelse candidate.?;
    return .{
        .evaluator = try allocator.dupe(u8, source.evaluator),
        .change = change,
        .baseline_passed = if (baseline) |value| value.passed else null,
        .candidate_passed = if (candidate) |value| value.passed else null,
        .baseline_score = if (baseline) |value| value.score else null,
        .candidate_score = if (candidate) |value| value.score else null,
        .score_delta = optionalDelta(
            if (baseline) |value| value.score else null,
            if (candidate) |value| value.score else null,
        ),
    };
}

fn compareAnalyses(
    allocator: std.mem.Allocator,
    baseline: []const evals.AnalysisResult,
    candidate: []const evals.AnalysisResult,
    counts: *Counts,
) ![]const AnalysisComparison {
    var results: std.ArrayList(AnalysisComparison) = .empty;
    const candidate_seen = try allocator.alloc(bool, candidate.len);
    @memset(candidate_seen, false);
    for (baseline) |baseline_analysis| {
        const candidate_index = findAnalysis(candidate, baseline_analysis.evaluator);
        const candidate_analysis = if (candidate_index) |index| blk: {
            candidate_seen[index] = true;
            break :blk candidate[index];
        } else null;
        try results.append(allocator, try compareAnalysis(allocator, baseline_analysis, candidate_analysis, counts));
    }
    for (candidate, 0..) |candidate_analysis, index| {
        if (candidate_seen[index]) continue;
        try results.append(allocator, try compareAnalysis(allocator, null, candidate_analysis, counts));
    }
    return results.toOwnedSlice(allocator);
}

fn compareAnalysis(
    allocator: std.mem.Allocator,
    baseline: ?evals.AnalysisResult,
    candidate: ?evals.AnalysisResult,
    counts: *Counts,
) !AnalysisComparison {
    const change: Change = if (baseline == null)
        .added
    else if (candidate == null)
        .removed
    else
        assertionChange(baseline.?.passed, candidate.?.passed);
    const regression = change == .removed or change == .regressed or
        (change == .added and candidate.?.passed == false);
    const improvement = change == .improved or (change == .added and candidate.?.passed == true);
    if (regression) counts.analysis_regressions += 1;
    if (improvement) counts.analysis_improvements += 1;
    const source = baseline orelse candidate.?;
    return .{
        .evaluator = try allocator.dupe(u8, source.evaluator),
        .change = change,
        .baseline_passed = if (baseline) |value| value.passed else null,
        .candidate_passed = if (candidate) |value| value.passed else null,
        .baseline_value = if (baseline) |value| value.value else null,
        .candidate_value = if (candidate) |value| value.value else null,
        .value_delta = optionalDelta(
            if (baseline) |value| value.value else null,
            if (candidate) |value| value.value else null,
        ),
        .baseline_unit = if (baseline) |value| if (value.unit) |unit| try allocator.dupe(u8, unit) else null else null,
        .candidate_unit = if (candidate) |value| if (value.unit) |unit| try allocator.dupe(u8, unit) else null else null,
    };
}

fn assertionChange(baseline: ?bool, candidate: ?bool) Change {
    const baseline_rank = assertionRank(baseline);
    const candidate_rank = assertionRank(candidate);
    if (candidate_rank > baseline_rank) return .improved;
    if (candidate_rank < baseline_rank) return .regressed;
    return .unchanged;
}

fn assertionRank(value: ?bool) i2 {
    if (value) |passed| return if (passed) 1 else -1;
    return 0;
}

fn validateReport(report: evals.ReportView, analyses: []const evals.AnalysisResult) !void {
    for (report.cases, 0..) |case, index| {
        if (case.name.len == 0 or case.repetition == 0 or case.repetitions == 0 or
            case.repetition > case.repetitions)
            return Error.InvalidReport;
        for (report.cases[0..index]) |previous| {
            if (previous.case_index == case.case_index and previous.repetition == case.repetition)
                return Error.DuplicateCaseIdentity;
        }
        try validateEvaluations(case.evaluations);
    }
    try validateAnalyses(analyses);
}

fn validateEvaluations(values: []const evals.EvaluationResult) !void {
    for (values, 0..) |value, index| {
        if (value.evaluator.len == 0) return Error.InvalidReport;
        if (value.score) |score| if (!std.math.isFinite(score)) return Error.InvalidReport;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous.evaluator, value.evaluator))
            return Error.DuplicateEvaluator;
    }
}

fn validateAnalyses(values: []const evals.AnalysisResult) !void {
    for (values, 0..) |value, index| {
        if (value.evaluator.len == 0) return Error.InvalidReport;
        if (value.value) |scalar| if (!std.math.isFinite(scalar)) return Error.InvalidReport;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous.evaluator, value.evaluator))
            return Error.DuplicateEvaluator;
    }
}

fn findCase(cases: []const evals.CaseResult, case_index: usize, repetition: usize) ?usize {
    for (cases, 0..) |case, index| if (case.case_index == case_index and case.repetition == repetition) return index;
    return null;
}

fn findEvaluation(values: []const evals.EvaluationResult, evaluator: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, value.evaluator, evaluator)) return index;
    return null;
}

fn findAnalysis(values: []const evals.AnalysisResult, evaluator: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, value.evaluator, evaluator)) return index;
    return null;
}

fn summary(report: evals.ReportView) Summary {
    const value = report.summary();
    return .{ .runs = value.runs, .passed_runs = value.passed_runs, .pass_rate = value.pass_rate };
}

fn optionalDelta(baseline: ?f64, candidate: ?f64) ?f64 {
    if (baseline == null or candidate == null) return null;
    return candidate.? - baseline.?;
}

fn usageDelta(baseline: model_types.RunUsage, candidate: model_types.RunUsage) UsageDelta {
    return .{
        .input_tokens = difference(candidate.input_tokens, baseline.input_tokens),
        .cache_write_tokens = difference(candidate.cache_write_tokens, baseline.cache_write_tokens),
        .cache_read_tokens = difference(candidate.cache_read_tokens, baseline.cache_read_tokens),
        .output_tokens = difference(candidate.output_tokens, baseline.output_tokens),
        .reasoning_tokens = difference(candidate.reasoning_tokens, baseline.reasoning_tokens),
        .input_audio_tokens = difference(candidate.input_audio_tokens, baseline.input_audio_tokens),
        .cache_audio_read_tokens = difference(candidate.cache_audio_read_tokens, baseline.cache_audio_read_tokens),
        .output_audio_tokens = difference(candidate.output_audio_tokens, baseline.output_audio_tokens),
        .requests = difference(candidate.requests, baseline.requests),
        .tool_calls = difference(candidate.tool_calls, baseline.tool_calls),
        .request_duration_ms = difference(candidate.request_duration_ms, baseline.request_duration_ms),
        .run_duration_ms = difference(candidate.run_duration_ms, baseline.run_duration_ms),
        .cost_nano_usd = if (baseline.cost == null and candidate.cost == null)
            null
        else
            difference(
                if (candidate.cost) |cost| cost.nano_usd else 0,
                if (baseline.cost) |cost| cost.nano_usd else 0,
            ),
    };
}

fn difference(candidate: anytype, baseline: @TypeOf(candidate)) i128 {
    return @as(i128, @intCast(candidate)) - @as(i128, @intCast(baseline));
}

fn evaluation(name: []const u8, passed: bool, score: ?f64) evals.EvaluationResult {
    return .{ .evaluator = name, .passed = passed, .score = score, .reason = null };
}

fn caseResult(
    name: []const u8,
    case_index: usize,
    passed_evaluations: []const evals.EvaluationResult,
) evals.CaseResult {
    return .{
        .name = name,
        .case_index = case_index,
        .output = "output",
        .usage = .{},
        .evaluations = passed_evaluations,
    };
}

test "comparison reports preserve stable order and classify every change" {
    const baseline_zero = [_]evals.EvaluationResult{
        evaluation("exact", true, 0.8),
        evaluation("removed", true, null),
    };
    const baseline_one = [_]evals.EvaluationResult{evaluation("quality", false, 0.4)};
    const baseline_two = [_]evals.EvaluationResult{evaluation("present", true, 1)};
    const baseline_four = [_]evals.EvaluationResult{evaluation("unchanged", false, null)};
    const baseline_cases = [_]evals.CaseResult{
        caseResult("zero", 0, &baseline_zero),
        caseResult("one", 1, &baseline_one),
        caseResult("two", 2, &baseline_two),
        caseResult("four", 4, &baseline_four),
    };
    const candidate_zero = [_]evals.EvaluationResult{
        evaluation("exact", false, 0.6),
        evaluation("added-bad", false, null),
    };
    const candidate_one = [_]evals.EvaluationResult{
        evaluation("quality", true, 0.9),
        evaluation("added-good", true, null),
    };
    const candidate_three = [_]evals.EvaluationResult{evaluation("new-good", true, 1)};
    const candidate_four = [_]evals.EvaluationResult{evaluation("unchanged", false, null)};
    const candidate_five = [_]evals.EvaluationResult{evaluation("new-bad", false, 0)};
    const candidate_cases = [_]evals.CaseResult{
        caseResult("four", 4, &candidate_four),
        caseResult("zero", 0, &candidate_zero),
        caseResult("one", 1, &candidate_one),
        caseResult("three", 3, &candidate_three),
        caseResult("five", 5, &candidate_five),
    };
    const baseline_analyses = [_]evals.AnalysisResult{
        .{ .evaluator = "gate", .passed = true, .value = 0.8, .unit = "ratio", .reason = null },
        .{ .evaluator = "recovered", .passed = false, .value = 0.2, .unit = null, .reason = null },
        .{ .evaluator = "removed", .passed = true, .value = null, .unit = null, .reason = null },
        .{ .evaluator = "neutral", .passed = null, .value = null, .unit = null, .reason = null },
    };
    const candidate_analyses = [_]evals.AnalysisResult{
        .{ .evaluator = "gate", .passed = false, .value = 0.5, .unit = "ratio", .reason = null },
        .{ .evaluator = "recovered", .passed = true, .value = 0.7, .unit = "ratio", .reason = null },
        .{ .evaluator = "neutral", .passed = null, .value = null, .unit = null, .reason = null },
        .{ .evaluator = "added-bad", .passed = false, .value = null, .unit = null, .reason = null },
        .{ .evaluator = "added-good", .passed = true, .value = null, .unit = null, .reason = null },
    };
    const baseline = evals.ReportView{
        .cases = &baseline_cases,
        .usage = .{
            .input_tokens = 10,
            .output_tokens = 8,
            .requests = 4,
            .tool_calls = 2,
            .request_duration_ms = 20,
            .run_duration_ms = 30,
            .cost = .{ .nano_usd = 100 },
        },
    };
    const candidate = evals.ReportView{
        .cases = &candidate_cases,
        .usage = .{
            .input_tokens = 12,
            .cache_write_tokens = 1,
            .cache_read_tokens = 2,
            .output_tokens = 7,
            .reasoning_tokens = 3,
            .input_audio_tokens = 4,
            .cache_audio_read_tokens = 5,
            .output_audio_tokens = 6,
            .requests = 5,
            .tool_calls = 1,
            .request_duration_ms = 25,
            .run_duration_ms = 28,
        },
    };

    var comparison = try compare(
        std.testing.allocator,
        baseline,
        candidate,
        &baseline_analyses,
        &candidate_analyses,
        .{ .baseline_name = "main", .candidate_name = "change" },
    );
    defer comparison.deinit();
    try std.testing.expectEqualStrings("main", comparison.baseline_name);
    try std.testing.expectEqualStrings("change", comparison.candidate_name);
    try std.testing.expectEqual(@as(usize, 6), comparison.cases.len);
    try std.testing.expectEqualStrings("zero", comparison.cases[0].name);
    try std.testing.expectEqualStrings("four", comparison.cases[3].name);
    try std.testing.expectEqualStrings("three", comparison.cases[4].name);
    try std.testing.expectEqual(Change.regressed, comparison.cases[0].change);
    try std.testing.expectEqual(Change.improved, comparison.cases[1].change);
    try std.testing.expectEqual(Change.removed, comparison.cases[2].change);
    try std.testing.expectEqual(Change.unchanged, comparison.cases[3].change);
    try std.testing.expectEqual(Change.added, comparison.cases[4].change);
    try std.testing.expectEqual(@as(usize, 3), comparison.case_regressions);
    try std.testing.expectEqual(@as(usize, 2), comparison.case_improvements);
    try std.testing.expectEqual(@as(usize, 5), comparison.evaluation_regressions);
    try std.testing.expectEqual(@as(usize, 3), comparison.evaluation_improvements);
    try std.testing.expectEqual(@as(usize, 3), comparison.analysis_regressions);
    try std.testing.expectEqual(@as(usize, 2), comparison.analysis_improvements);
    try std.testing.expectEqual(@as(usize, 11), comparison.regressions());
    try std.testing.expectEqual(@as(usize, 7), comparison.improvements());
    try std.testing.expect(!comparison.regressionFree());
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), comparison.pass_rate_delta.?, 0.0000001);
    try std.testing.expectEqual(@as(i128, 2), comparison.usage_delta.input_tokens);
    try std.testing.expectEqual(@as(i128, -1), comparison.usage_delta.output_tokens);
    try std.testing.expectEqual(@as(i128, -2), comparison.usage_delta.run_duration_ms);
    try std.testing.expectEqual(@as(?i128, -100), comparison.usage_delta.cost_nano_usd);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.2),
        comparison.cases[0].evaluations[0].score_delta.?,
        0.0000001,
    );
    try std.testing.expectApproxEqAbs(@as(f64, -0.3), comparison.analyses[0].value_delta.?, 0.0000001);
    try std.testing.expectEqualStrings("ratio", comparison.analyses[0].baseline_unit.?);
    try std.testing.expectEqualStrings("ratio", comparison.analyses[1].candidate_unit.?);

    const ci_json = try stringifyCiJson(std.testing.allocator, comparison);
    defer std.testing.allocator.free(ci_json);
    try std.testing.expect(std.mem.endsWith(u8, ci_json, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, ci_json, "\"version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_json, "\"conclusion\": \"fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_json, "\"case_regressions\": 3") != null);
}

test "comparison wrappers produce passing stable CI output" {
    const evaluations = [_]evals.EvaluationResult{evaluation("exact", true, null)};
    const cases = [_]evals.CaseResult{caseResult("case", 0, &evaluations)};
    const analyses = [_]evals.AnalysisResult{.{
        .evaluator = "gate",
        .passed = true,
        .value = null,
        .unit = null,
        .reason = null,
    }};
    const baseline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var baseline = evals.Report{ .arena = baseline_arena, .cases = &cases, .usage = .{}, .analyses = &analyses };
    defer baseline.deinit();
    const candidate_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var candidate = evals.Report{ .arena = candidate_arena, .cases = &cases, .usage = .{}, .analyses = &analyses };
    defer candidate.deinit();
    var comparison = try compareReports(std.testing.allocator, baseline, candidate, .{});
    defer comparison.deinit();
    try std.testing.expect(comparison.regressionFree());
    try std.testing.expectEqual(@as(?i128, null), comparison.usage_delta.cost_nano_usd);
    try std.testing.expectEqual(@as(?f64, 0), comparison.pass_rate_delta);
    try std.testing.expectEqual(@as(?f64, null), comparison.cases[0].evaluations[0].score_delta);
    const ci_json = try stringifyCiJson(std.testing.allocator, comparison);
    defer std.testing.allocator.free(ci_json);
    try std.testing.expect(std.mem.indexOf(u8, ci_json, "\"conclusion\": \"pass\"") != null);

    var empty = try compare(std.testing.allocator, .{ .cases = &.{}, .usage = .{} }, .{
        .cases = &.{},
        .usage = .{},
    }, &.{}, &.{}, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(?f64, null), empty.pass_rate_delta);
}

test "comparison validation rejects unstable identities and invalid values" {
    const valid_case = caseResult("case", 0, &.{});
    try std.testing.expectError(Error.InvalidLabel, compare(
        std.testing.allocator,
        .{ .cases = &.{valid_case}, .usage = .{} },
        .{ .cases = &.{valid_case}, .usage = .{} },
        &.{},
        &.{},
        .{ .baseline_name = "" },
    ));
    const invalid_case = evals.CaseResult{
        .name = "",
        .output = "",
        .usage = .{},
        .evaluations = &.{},
    };
    try std.testing.expectError(Error.InvalidReport, compare(
        std.testing.allocator,
        .{ .cases = &.{invalid_case}, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &.{},
        &.{},
        .{},
    ));
    try std.testing.expectError(Error.DuplicateCaseIdentity, compare(
        std.testing.allocator,
        .{ .cases = &.{ valid_case, valid_case }, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &.{},
        &.{},
        .{},
    ));
    const renamed = caseResult("renamed", 0, &.{});
    try std.testing.expectError(Error.CaseIdentityMismatch, compare(
        std.testing.allocator,
        .{ .cases = &.{valid_case}, .usage = .{} },
        .{ .cases = &.{renamed}, .usage = .{} },
        &.{},
        &.{},
        .{},
    ));
    const duplicate_evaluations = [_]evals.EvaluationResult{
        evaluation("same", true, null),
        evaluation("same", true, null),
    };
    const duplicate_case = caseResult("case", 0, &duplicate_evaluations);
    try std.testing.expectError(Error.DuplicateEvaluator, compare(
        std.testing.allocator,
        .{ .cases = &.{duplicate_case}, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &.{},
        &.{},
        .{},
    ));
    const invalid_evaluation = [_]evals.EvaluationResult{evaluation("score", true, std.math.nan(f64))};
    const invalid_evaluation_case = caseResult("case", 0, &invalid_evaluation);
    try std.testing.expectError(Error.InvalidReport, compare(
        std.testing.allocator,
        .{ .cases = &.{invalid_evaluation_case}, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &.{},
        &.{},
        .{},
    ));
    const duplicate_analyses = [_]evals.AnalysisResult{
        .{ .evaluator = "same", .passed = null, .value = null, .unit = null, .reason = null },
        .{ .evaluator = "same", .passed = null, .value = null, .unit = null, .reason = null },
    };
    try std.testing.expectError(Error.DuplicateEvaluator, compare(
        std.testing.allocator,
        .{ .cases = &.{}, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &duplicate_analyses,
        &.{},
        .{},
    ));
    try std.testing.expectError(Error.InvalidReport, compare(
        std.testing.allocator,
        .{ .cases = &.{}, .usage = .{} },
        .{ .cases = &.{}, .usage = .{} },
        &.{.{ .evaluator = "value", .passed = null, .value = std.math.inf(f64), .unit = null, .reason = null }},
        &.{},
        .{},
    ));
}

fn checkComparisonAllocationFailure(allocator: std.mem.Allocator) !void {
    const baseline_evaluations = [_]evals.EvaluationResult{evaluation("exact", true, 1)};
    const candidate_evaluations = [_]evals.EvaluationResult{evaluation("exact", false, 0)};
    const baseline_case = caseResult("case", 0, &baseline_evaluations);
    const candidate_case = caseResult("case", 0, &candidate_evaluations);
    var comparison = try compare(
        allocator,
        .{ .cases = &.{baseline_case}, .usage = .{} },
        .{ .cases = &.{candidate_case}, .usage = .{} },
        &.{.{ .evaluator = "gate", .passed = true, .value = 1, .unit = "ratio", .reason = null }},
        &.{.{ .evaluator = "gate", .passed = false, .value = 0, .unit = "ratio", .reason = null }},
        .{},
    );
    defer comparison.deinit();
    const json = try stringifyCiJson(allocator, comparison);
    defer allocator.free(json);
}

test "comparison reports release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkComparisonAllocationFailure, .{});
}
