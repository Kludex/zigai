//! Versioned, provider-neutral evaluation dataset and report documents.
//!
//! Dataset files contain data and evaluator names only. Loading resolves those
//! names through an application-owned registry; callback pointers and run-local
//! state are never serialized.

const std = @import("std");
const yaml = @import("yaml");
const evals = @import("evals.zig");
const json_limits = @import("json.zig");
const model_types = @import("model.zig");
const telemetry_types = @import("telemetry.zig");

/// Current dataset and report document version.
pub const format_version: u8 = 1;

/// Stable validation and evaluator-resolution failures for eval documents.
pub const Error = error{
    InvalidDataset,
    UnsupportedDatasetVersion,
    UnsupportedCaseOptions,
    UnknownEvaluator,
    AmbiguousEvaluator,
    InvalidReport,
    UnsupportedReportVersion,
};

/// Portable case fields retained by a dataset document.
pub const DatasetCase = struct {
    /// Stable case name, unique within one dataset.
    name: []const u8,
    /// Text prompt passed to the agent.
    prompt: []const u8,
    /// Optional expected output consumed by deterministic evaluators.
    expected_output: ?[]const u8 = null,
    /// Application metadata retained without interpretation.
    metadata: []const model_types.Metadata = &.{},
};

/// Versioned data-only dataset shape used by both JSON and YAML.
pub const DatasetDocument = struct {
    /// Must equal `format_version`.
    version: u8,
    /// Ordered source cases.
    cases: []const DatasetCase,
    /// Ordered ordinary evaluator registry names.
    evaluators: []const []const u8 = &.{},
    /// Ordered trace evaluator registry names.
    trace_evaluators: []const []const u8 = &.{},
    /// Ordered report evaluator registry names.
    report_evaluators: []const []const u8 = &.{},
};

/// Application-owned callbacks available while loading a dataset document.
pub const EvaluatorRegistry = struct {
    /// Ordinary output evaluators addressable by name.
    evaluators: []const evals.Evaluator = &.{},
    /// Trace evaluators addressable by name.
    trace_evaluators: []const evals.TraceEvaluator = &.{},
    /// Aggregate report evaluators addressable by name.
    report_evaluators: []const evals.ReportEvaluator = &.{},
};

/// Arena-owned runnable dataset loaded from a portable document.
pub const OwnedDataset = struct {
    /// Storage backing `value`.
    arena: std.heap.ArenaAllocator,
    /// Resolved runnable dataset.
    value: evals.Dataset,

    /// Releases the complete parsed and resolved graph.
    pub fn deinit(self: *OwnedDataset) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// YAML/JSON span shape with hexadecimal trace and span identifiers.
pub const SpanDocument = struct {
    /// OpenTelemetry span name.
    name: []const u8,
    /// OpenTelemetry span kind.
    kind: telemetry_types.Span.Kind,
    /// Lowercase 32-character hexadecimal trace ID.
    trace_id: []const u8,
    /// Lowercase 16-character hexadecimal span ID.
    span_id: []const u8,
    /// Optional lowercase 16-character hexadecimal parent span ID.
    parent_span_id: ?[]const u8 = null,
    /// Unix epoch start time in nanoseconds.
    start_time_unix_nano: i128,
    /// Unix epoch end time in nanoseconds.
    end_time_unix_nano: i128,
    /// Non-negative finite duration in seconds.
    duration_seconds: f64,
    /// Terminal span status.
    status: telemetry_types.Span.Status,
    /// Typed OpenTelemetry attributes.
    attributes: []const telemetry_types.Attribute,
};

/// One durable case-run result in a report document.
pub const ReportCase = struct {
    /// Source case name.
    name: []const u8,
    /// Zero-based source case index.
    case_index: usize,
    /// One-based repetition index.
    repetition: usize,
    /// Total repetitions configured for the source case.
    repetitions: usize,
    /// Number of task attempts consumed.
    task_attempts: usize,
    /// Final agent output.
    output: []const u8,
    /// Usage accumulated by this case run.
    usage: model_types.RunUsage,
    /// Ordered ordinary and trace evaluation results.
    evaluations: []const evals.EvaluationResult,
    /// Ordered spans captured for this case run.
    spans: []const SpanDocument = &.{},
};

/// Versioned complete report shape used by both JSON and YAML.
pub const ReportDocument = struct {
    /// Must equal `format_version`.
    version: u8,
    /// Ordered case/repetition results.
    cases: []const ReportCase,
    /// Usage aggregated across all cases.
    usage: model_types.RunUsage,
    /// Ordered report-level evaluator results.
    analyses: []const evals.AnalysisResult = &.{},
};

/// Serializes a dataset as stable, indented JSON. Case `RunOptions` must be
/// default because they can contain callbacks, pointers, queues, and secrets.
pub fn stringifyDatasetJson(allocator: std.mem.Allocator, dataset: evals.Dataset) ![]u8 {
    try validatePortableDataset(dataset);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try writeDataset(&json, dataset);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

/// Serializes a dataset as deterministic, indentation-based YAML.
pub fn stringifyDatasetYaml(allocator: std.mem.Allocator, dataset: evals.Dataset) ![]u8 {
    const json = try stringifyDatasetJson(allocator, dataset);
    defer allocator.free(json);
    return jsonToYaml(allocator, json);
}

/// Parses strict JSON and resolves evaluator names into an owned dataset.
pub fn parseDatasetJson(
    allocator: std.mem.Allocator,
    source: []const u8,
    registry: EvaluatorRegistry,
) !OwnedDataset {
    try json_limits.validate(allocator, source, json_limits.defaults.cli_config);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const document = std.json.parseFromSliceLeaky(DatasetDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidDataset,
    };
    try validateDatasetDocument(document);
    const cases = try memory.alloc(evals.Case, document.cases.len);
    for (document.cases, cases) |case, *resolved| resolved.* = .{
        .name = case.name,
        .prompt = case.prompt,
        .expected_output = case.expected_output,
        .metadata = case.metadata,
    };
    const evaluators = try resolveEvaluators(evals.Evaluator, memory, document.evaluators, registry.evaluators);
    const trace_evaluators = try resolveEvaluators(
        evals.TraceEvaluator,
        memory,
        document.trace_evaluators,
        registry.trace_evaluators,
    );
    const report_evaluators = try resolveEvaluators(
        evals.ReportEvaluator,
        memory,
        document.report_evaluators,
        registry.report_evaluators,
    );
    return .{ .arena = arena, .value = .{
        .cases = cases,
        .evaluators = evaluators,
        .trace_evaluators = trace_evaluators,
        .report_evaluators = report_evaluators,
    } };
}

/// Parses strict YAML and resolves evaluator names into an owned dataset.
pub fn parseDatasetYaml(
    allocator: std.mem.Allocator,
    source: []const u8,
    registry: EvaluatorRegistry,
) !OwnedDataset {
    const json = try yamlToJson(allocator, source, Error.InvalidDataset);
    defer allocator.free(json);
    return parseDatasetJson(allocator, json, registry);
}

/// Serializes a complete report as stable, indented JSON.
pub fn stringifyReportJson(allocator: std.mem.Allocator, report: evals.Report) ![]u8 {
    try validateReport(report);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try writeReport(&json, report);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

/// Serializes a complete report as deterministic, indentation-based YAML.
pub fn stringifyReportYaml(allocator: std.mem.Allocator, report: evals.Report) ![]u8 {
    const json = try stringifyReportJson(allocator, report);
    defer allocator.free(json);
    return jsonToYaml(allocator, json);
}

/// Parses strict JSON into an arena-owned complete report.
pub fn parseReportJson(allocator: std.mem.Allocator, source: []const u8) !evals.Report {
    try json_limits.validate(allocator, source, json_limits.defaults.cli_config);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const document = std.json.parseFromSliceLeaky(ReportDocument, memory, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidReport,
    };
    try validateReportDocument(document);
    const cases = try memory.alloc(evals.CaseResult, document.cases.len);
    for (document.cases, cases) |case, *resolved| {
        const spans = try memory.alloc(telemetry_types.Span, case.spans.len);
        for (case.spans, spans) |span, *resolved_span| resolved_span.* = .{
            .name = span.name,
            .kind = span.kind,
            .trace_id = try parseId(16, span.trace_id),
            .span_id = try parseId(8, span.span_id),
            .parent_span_id = if (span.parent_span_id) |id| try parseId(8, id) else null,
            .start_time_unix_nano = span.start_time_unix_nano,
            .end_time_unix_nano = span.end_time_unix_nano,
            .duration_seconds = span.duration_seconds,
            .status = span.status,
            .attributes = span.attributes,
        };
        resolved.* = .{
            .name = case.name,
            .case_index = case.case_index,
            .repetition = case.repetition,
            .repetitions = case.repetitions,
            .task_attempts = case.task_attempts,
            .output = case.output,
            .usage = case.usage,
            .evaluations = case.evaluations,
            .spans = spans,
        };
    }
    return .{
        .arena = arena,
        .cases = cases,
        .usage = document.usage,
        .analyses = document.analyses,
    };
}

/// Parses strict YAML into an arena-owned complete report.
pub fn parseReportYaml(allocator: std.mem.Allocator, source: []const u8) !evals.Report {
    const json = try yamlToJson(allocator, source, Error.InvalidReport);
    defer allocator.free(json);
    return parseReportJson(allocator, json);
}

fn writeDataset(json: *std.json.Stringify, dataset: evals.Dataset) !void {
    try json.beginObject();
    try json.objectField("version");
    try json.write(format_version);
    try json.objectField("cases");
    try json.beginArray();
    for (dataset.cases) |case| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(case.name);
        try json.objectField("prompt");
        try json.write(case.prompt);
        if (case.expected_output) |expected| {
            try json.objectField("expected_output");
            try json.write(expected);
        }
        if (case.metadata.len != 0) {
            try json.objectField("metadata");
            try json.write(case.metadata);
        }
        try json.endObject();
    }
    try json.endArray();
    try writeEvaluatorNames(evals.Evaluator, json, "evaluators", dataset.evaluators);
    try writeEvaluatorNames(evals.TraceEvaluator, json, "trace_evaluators", dataset.trace_evaluators);
    try writeEvaluatorNames(evals.ReportEvaluator, json, "report_evaluators", dataset.report_evaluators);
    try json.endObject();
}

fn writeEvaluatorNames(comptime T: type, json: *std.json.Stringify, field_name: []const u8, values: []const T) !void {
    if (values.len == 0) return;
    try json.objectField(field_name);
    try json.beginArray();
    for (values) |value| try json.write(value.name);
    try json.endArray();
}

fn writeReport(json: *std.json.Stringify, report: evals.Report) !void {
    try json.beginObject();
    try json.objectField("version");
    try json.write(format_version);
    try json.objectField("cases");
    try json.beginArray();
    for (report.cases) |case| {
        try json.beginObject();
        inline for (.{ "name", "case_index", "repetition", "repetitions", "task_attempts", "output", "usage", "evaluations" }) |field_name| {
            try json.objectField(field_name);
            try json.write(@field(case, field_name));
        }
        if (case.spans.len != 0) {
            try json.objectField("spans");
            try json.beginArray();
            for (case.spans) |span| try writeSpan(json, span);
            try json.endArray();
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("usage");
    try json.write(report.usage);
    if (report.analyses.len != 0) {
        try json.objectField("analyses");
        try json.write(report.analyses);
    }
    try json.endObject();
}

fn writeSpan(json: *std.json.Stringify, span: telemetry_types.Span) !void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(span.name);
    try json.objectField("kind");
    try json.write(span.kind);
    try json.objectField("trace_id");
    try json.write(&std.fmt.bytesToHex(span.trace_id, .lower));
    try json.objectField("span_id");
    try json.write(&std.fmt.bytesToHex(span.span_id, .lower));
    if (span.parent_span_id) |parent| {
        try json.objectField("parent_span_id");
        try json.write(&std.fmt.bytesToHex(parent, .lower));
    }
    inline for (.{ "start_time_unix_nano", "end_time_unix_nano", "duration_seconds", "status", "attributes" }) |field_name| {
        try json.objectField(field_name);
        try json.write(@field(span, field_name));
    }
    try json.endObject();
}

fn validatePortableDataset(dataset: evals.Dataset) !void {
    for (dataset.cases) |case| if (!portableOptions(case.options)) return Error.UnsupportedCaseOptions;
    try validateLiveDataset(dataset);
}

fn validateLiveDataset(dataset: evals.Dataset) !void {
    for (dataset.cases, 0..) |case, index| {
        if (case.name.len == 0) return Error.InvalidDataset;
        for (dataset.cases[0..index]) |previous| if (std.mem.eql(u8, previous.name, case.name))
            return Error.InvalidDataset;
        try validateMetadata(case.metadata);
    }
    try validateLiveEvaluatorNames(evals.Evaluator, dataset.evaluators);
    try validateLiveEvaluatorNames(evals.TraceEvaluator, dataset.trace_evaluators);
    try validateLiveEvaluatorNames(evals.ReportEvaluator, dataset.report_evaluators);
    for (dataset.evaluators) |ordinary| {
        for (dataset.trace_evaluators) |trace| if (std.mem.eql(u8, ordinary.name, trace.name)) return Error.InvalidDataset;
        for (dataset.report_evaluators) |report| if (std.mem.eql(u8, ordinary.name, report.name)) return Error.InvalidDataset;
    }
    for (dataset.trace_evaluators) |trace| for (dataset.report_evaluators) |report|
        if (std.mem.eql(u8, trace.name, report.name)) return Error.InvalidDataset;
}

fn validateDatasetDocument(document: DatasetDocument) !void {
    if (document.version != format_version) return Error.UnsupportedDatasetVersion;
    for (document.cases, 0..) |case, index| {
        if (case.name.len == 0) return Error.InvalidDataset;
        for (document.cases[0..index]) |previous| if (std.mem.eql(u8, previous.name, case.name))
            return Error.InvalidDataset;
        try validateMetadata(case.metadata);
    }
    try validateDocumentNames(document.evaluators, &.{}, &.{});
    try validateDocumentNames(document.trace_evaluators, document.evaluators, &.{});
    try validateDocumentNames(document.report_evaluators, document.evaluators, document.trace_evaluators);
}

fn validateMetadata(metadata: []const model_types.Metadata) !void {
    for (metadata, 0..) |item, index| {
        if (item.key.len == 0) return Error.InvalidDataset;
        for (metadata[0..index]) |previous| if (std.mem.eql(u8, previous.key, item.key))
            return Error.InvalidDataset;
    }
}

fn validateLiveEvaluatorNames(comptime T: type, values: []const T) !void {
    for (values, 0..) |value, index| {
        if (value.name.len == 0) return Error.InvalidDataset;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous.name, value.name))
            return Error.InvalidDataset;
    }
}

fn validateDocumentNames(names: []const []const u8, first: []const []const u8, second: []const []const u8) !void {
    for (names, 0..) |name, index| {
        if (name.len == 0) return Error.InvalidDataset;
        for (names[0..index]) |previous| if (std.mem.eql(u8, previous, name)) return Error.InvalidDataset;
        for (first) |previous| if (std.mem.eql(u8, previous, name)) return Error.InvalidDataset;
        for (second) |previous| if (std.mem.eql(u8, previous, name)) return Error.InvalidDataset;
    }
}

fn portableOptions(options: @import("agent.zig").RunOptions) bool {
    return options.message_history.len == 0 and
        options.prompt_parts.len == 0 and
        options.instructions.len == 0 and
        options.capabilities.len == 0 and
        options.capability_layers.len == 0 and
        options.dependencies == null and
        emptyModelSettings(options.model_settings) and
        options.history_processors.len == 0 and
        options.context_budget == null and
        options.request_id == null and
        options.timeout_ms == null and
        options.pending_messages == null;
}

fn emptyModelSettings(settings: model_types.ModelSettings) bool {
    inline for (@typeInfo(model_types.ModelSettings).@"struct".fields) |field| {
        if (@field(settings, field.name) != null) return false;
    }
    return true;
}

fn resolveEvaluators(
    comptime T: type,
    allocator: std.mem.Allocator,
    names: []const []const u8,
    registry: []const T,
) ![]const T {
    const resolved = try allocator.alloc(T, names.len);
    for (names, resolved) |name, *target| {
        var match: ?T = null;
        for (registry) |candidate| {
            if (!std.mem.eql(u8, candidate.name, name)) continue;
            if (match != null) return Error.AmbiguousEvaluator;
            match = candidate;
        }
        target.* = match orelse return Error.UnknownEvaluator;
    }
    return resolved;
}

fn validateReport(report: evals.Report) !void {
    for (report.cases) |case| {
        if (case.name.len == 0 or case.repetition == 0 or case.repetitions == 0 or
            case.repetition > case.repetitions or case.task_attempts == 0)
            return Error.InvalidReport;
        try validateUsage(case.usage);
        try validateEvaluations(case.evaluations);
        for (case.spans) |span| try validateTelemetrySpan(span);
    }
    try validateUsage(report.usage);
    try validateAnalyses(report.analyses);
}

fn validateReportDocument(document: ReportDocument) !void {
    if (document.version != format_version) return Error.UnsupportedReportVersion;
    for (document.cases) |case| {
        if (case.name.len == 0 or case.repetition == 0 or case.repetitions == 0 or
            case.repetition > case.repetitions or case.task_attempts == 0)
            return Error.InvalidReport;
        try validateUsage(case.usage);
        try validateEvaluations(case.evaluations);
        for (case.spans) |span| {
            _ = parseId(16, span.trace_id) catch return Error.InvalidReport;
            _ = parseId(8, span.span_id) catch return Error.InvalidReport;
            if (span.parent_span_id) |id| _ = parseId(8, id) catch return Error.InvalidReport;
            if (span.name.len == 0 or !std.math.isFinite(span.duration_seconds) or span.duration_seconds < 0 or
                span.end_time_unix_nano < span.start_time_unix_nano)
                return Error.InvalidReport;
            try validateAttributes(span.attributes);
        }
    }
    try validateUsage(document.usage);
    try validateAnalyses(document.analyses);
}

fn validateUsage(value: model_types.RunUsage) !void {
    if (value.cost == null and (value.cost_source != null or value.cost_table_version != null)) return Error.InvalidReport;
    for (value.details, 0..) |detail, index| {
        if (detail.name.len == 0) return Error.InvalidReport;
        for (value.details[0..index]) |previous| if (std.mem.eql(u8, previous.name, detail.name))
            return Error.InvalidReport;
    }
}

fn validateEvaluations(values: []const evals.EvaluationResult) !void {
    for (values, 0..) |value, index| {
        if (value.evaluator.len == 0 or value.attempts == 0) return Error.InvalidReport;
        if (value.score) |score| if (!std.math.isFinite(score)) return Error.InvalidReport;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous.evaluator, value.evaluator))
            return Error.InvalidReport;
    }
}

fn validateAnalyses(values: []const evals.AnalysisResult) !void {
    for (values, 0..) |value, index| {
        if (value.evaluator.len == 0) return Error.InvalidReport;
        if (value.value) |scalar| if (!std.math.isFinite(scalar)) return Error.InvalidReport;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous.evaluator, value.evaluator))
            return Error.InvalidReport;
    }
}

fn validateTelemetrySpan(span: telemetry_types.Span) !void {
    if (span.name.len == 0 or !std.math.isFinite(span.duration_seconds) or span.duration_seconds < 0 or
        span.end_time_unix_nano < span.start_time_unix_nano)
        return Error.InvalidReport;
    try validateAttributes(span.attributes);
}

fn validateAttributes(attributes: []const telemetry_types.Attribute) !void {
    for (attributes) |attribute| {
        if (attribute.key.len == 0) return Error.InvalidReport;
        switch (attribute.value) {
            .float => |value| if (!std.math.isFinite(value)) return Error.InvalidReport,
            else => {},
        }
    }
}

fn parseId(comptime length: usize, source: []const u8) ![length]u8 {
    if (source.len != length * 2) return Error.InvalidReport;
    var output: [length]u8 = undefined;
    _ = std.fmt.hexToBytes(&output, source) catch return Error.InvalidReport;
    return output;
}

fn yamlToJson(allocator: std.mem.Allocator, source: []const u8, invalid: anyerror) ![]u8 {
    if (source.len > json_limits.defaults.cli_config.max_document_bytes) return error.DocumentTooLarge;
    var document = yaml.loadWithOptions(allocator, source, .{
        .schema = .core,
        .duplicate_key_behavior = .reject,
        .unknown_tag_behavior = .reject,
        .max_input_bytes = json_limits.defaults.cli_config.max_document_bytes,
        .max_nesting_depth = json_limits.defaults.cli_config.max_depth,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid,
    };
    defer document.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    writeJsonNode(&json, document.root) catch |failure| return switch (failure) {
        error.WriteFailed => error.OutOfMemory,
        error.InvalidYaml => invalid,
    };
    return output.toOwnedSlice();
}

const JsonNodeError = error{ WriteFailed, InvalidYaml };

fn writeJsonNode(json: *std.json.Stringify, node: *const yaml.Node) JsonNodeError!void {
    switch (node.*) {
        .null_value => try json.write(null),
        .bool_value => |value| try json.write(value.value),
        .int_value => |value| try json.write(value.value),
        .float_value => |value| try json.write(value.value),
        .scalar => |value| try json.write(value.value),
        .sequence => |sequence| {
            try json.beginArray();
            for (sequence.items) |item| try writeJsonNode(json, item);
            try json.endArray();
        },
        .mapping => |mapping| {
            try json.beginObject();
            for (mapping.pairs) |pair| {
                const key = switch (pair.key.*) {
                    .scalar => |value| value.value,
                    else => return error.InvalidYaml,
                };
                try json.objectField(key);
                try writeJsonNode(json, pair.value);
            }
            try json.endObject();
        },
        .alias => unreachable,
    }
}

fn jsonToYaml(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeYamlValue(&output.writer, parsed.value, 0, false);
    return output.toOwnedSlice();
}

fn writeYamlValue(
    writer: *std.Io.Writer,
    value: std.json.Value,
    indent: usize,
    inline_value: bool,
) std.Io.Writer.Error!void {
    switch (value) {
        .object => |object| try writeYamlObject(writer, object, indent),
        .array => |array| try writeYamlArray(writer, array.items, indent),
        else => {
            if (!inline_value) try writeIndent(writer, indent);
            try writeYamlScalar(writer, value);
            try writer.writeByte('\n');
        },
    }
}

fn writeYamlObject(writer: *std.Io.Writer, object: std.json.ObjectMap, indent: usize) std.Io.Writer.Error!void {
    if (object.count() == 0) {
        try writeIndent(writer, indent);
        return writer.writeAll("{}\n");
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try writeIndent(writer, indent);
        try writeYamlKey(writer, entry.key_ptr.*);
        try writer.writeByte(':');
        if (isCompound(entry.value_ptr.*)) {
            if (isEmptyCompound(entry.value_ptr.*)) {
                try writer.writeByte(' ');
                try writeYamlScalar(writer, entry.value_ptr.*);
                try writer.writeByte('\n');
            } else {
                try writer.writeByte('\n');
                const child_indent = if (entry.value_ptr.* == .array) indent else indent + 2;
                try writeYamlValue(writer, entry.value_ptr.*, child_indent, false);
            }
        } else {
            try writer.writeByte(' ');
            try writeYamlScalar(writer, entry.value_ptr.*);
            try writer.writeByte('\n');
        }
    }
}

fn writeYamlArray(writer: *std.Io.Writer, values: []const std.json.Value, indent: usize) std.Io.Writer.Error!void {
    if (values.len == 0) {
        try writeIndent(writer, indent);
        return writer.writeAll("[]\n");
    }
    for (values) |value| {
        try writeIndent(writer, indent);
        try writer.writeByte('-');
        if (value == .object and value.object.count() != 0) {
            var iterator = value.object.iterator();
            const first = iterator.next().?;
            try writer.writeByte(' ');
            try writeYamlKey(writer, first.key_ptr.*);
            try writer.writeByte(':');
            if (isCompound(first.value_ptr.*) and !isEmptyCompound(first.value_ptr.*)) {
                try writer.writeByte('\n');
                try writeYamlValue(writer, first.value_ptr.*, indent + 2, false);
            } else {
                try writer.writeByte(' ');
                try writeYamlScalar(writer, first.value_ptr.*);
                try writer.writeByte('\n');
            }
            while (iterator.next()) |entry| {
                try writeIndent(writer, indent + 2);
                try writeYamlKey(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                if (isCompound(entry.value_ptr.*) and !isEmptyCompound(entry.value_ptr.*)) {
                    try writer.writeByte('\n');
                    const child_indent = if (entry.value_ptr.* == .array) indent + 2 else indent + 4;
                    try writeYamlValue(writer, entry.value_ptr.*, child_indent, false);
                } else {
                    try writer.writeByte(' ');
                    try writeYamlScalar(writer, entry.value_ptr.*);
                    try writer.writeByte('\n');
                }
            }
        } else if (isCompound(value) and !isEmptyCompound(value)) {
            try writer.writeByte('\n');
            try writeYamlValue(writer, value, indent + 2, false);
        } else {
            try writer.writeByte(' ');
            try writeYamlScalar(writer, value);
            try writer.writeByte('\n');
        }
    }
}

fn writeYamlScalar(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| try writeYamlString(writer, string),
        .array => |array| if (array.items.len == 0) try writer.writeAll("[]") else unreachable,
        .object => |object| if (object.count() == 0) try writer.writeAll("{}") else unreachable,
    }
}

fn writeYamlString(writer: *std.Io.Writer, value: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(value);
}

fn writeYamlKey(writer: *std.Io.Writer, value: []const u8) !void {
    if (value.len != 0) {
        for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-'))
            return writeYamlString(writer, value);
        return writer.writeAll(value);
    }
    return writeYamlString(writer, value);
}

fn writeIndent(writer: *std.Io.Writer, count: usize) !void {
    try writer.splatByteAll(' ', count);
}

fn isCompound(value: std.json.Value) bool {
    return value == .array or value == .object;
}

fn isEmptyCompound(value: std.json.Value) bool {
    return switch (value) {
        .array => |array| array.items.len == 0,
        .object => |object| object.count() == 0,
        else => false,
    };
}

var test_context: u8 = 0;

fn testEvaluator(_: *anyopaque, _: std.mem.Allocator, run: evals.Context) !evals.Evaluation {
    return .{ .passed = std.mem.eql(u8, run.output, "ok"), .score = 1 };
}

fn testTraceEvaluator(_: *anyopaque, _: std.mem.Allocator, trace: evals.TraceContext) !evals.Evaluation {
    return .{ .passed = trace.spans.len != 0 };
}

fn testReportEvaluator(_: *anyopaque, _: std.mem.Allocator, report: evals.ReportView) !evals.Analysis {
    return .{ .passed = report.cases.len != 0, .value = 1, .unit = "ratio" };
}

const test_evaluator = evals.Evaluator{
    .name = "exact",
    .context = &test_context,
    .evaluateFn = testEvaluator,
};

const test_trace_evaluator = evals.TraceEvaluator{
    .name = "trace-shape",
    .context = &test_context,
    .evaluateFn = testTraceEvaluator,
};

const test_report_evaluator = evals.ReportEvaluator{
    .name = "pass-rate",
    .context = &test_context,
    .evaluateFn = testReportEvaluator,
};

const test_registry = EvaluatorRegistry{
    .evaluators = &.{test_evaluator},
    .trace_evaluators = &.{test_trace_evaluator},
    .report_evaluators = &.{test_report_evaluator},
};

test "dataset JSON and readable YAML round trip through an explicit registry" {
    const metadata = [_]model_types.Metadata{.{ .key = "suite", .value = "smoke" }};
    const cases = [_]evals.Case{.{
        .name = "greeting",
        .prompt = "Say: ok",
        .expected_output = "ok",
        .metadata = &metadata,
    }};
    const dataset = evals.Dataset{
        .cases = &cases,
        .evaluators = &.{test_evaluator},
        .trace_evaluators = &.{test_trace_evaluator},
        .report_evaluators = &.{test_report_evaluator},
    };

    const json = try stringifyDatasetJson(std.testing.allocator, dataset);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.endsWith(u8, json, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": 1") != null);
    var from_json = try parseDatasetJson(std.testing.allocator, json, test_registry);
    defer from_json.deinit();
    try std.testing.expectEqualStrings("greeting", from_json.value.cases[0].name);
    try std.testing.expectEqualStrings("smoke", from_json.value.cases[0].metadata[0].value);
    try std.testing.expectEqualStrings("exact", from_json.value.evaluators[0].name);
    try std.testing.expectEqualStrings("trace-shape", from_json.value.trace_evaluators[0].name);
    try std.testing.expectEqualStrings("pass-rate", from_json.value.report_evaluators[0].name);

    const yaml_source = try stringifyDatasetYaml(std.testing.allocator, dataset);
    defer std.testing.allocator.free(yaml_source);
    try std.testing.expect(std.mem.startsWith(u8, yaml_source, "version: 1\ncases:\n- name:"));
    var from_yaml = try parseDatasetYaml(std.testing.allocator, yaml_source, test_registry);
    defer from_yaml.deinit();
    try std.testing.expectEqualStrings("ok", from_yaml.value.cases[0].expected_output.?);
}

test "dataset documents reject non-portable options and invalid evaluator resolution" {
    const with_options = evals.Dataset{
        .cases = &.{.{ .name = "case", .prompt = "prompt", .options = .{ .timeout_ms = 10 } }},
        .evaluators = &.{},
    };
    try std.testing.expectError(Error.UnsupportedCaseOptions, stringifyDatasetJson(std.testing.allocator, with_options));
    try std.testing.expectError(Error.UnsupportedDatasetVersion, parseDatasetJson(
        std.testing.allocator,
        "{\"version\":2,\"cases\":[]}",
        .{},
    ));
    try std.testing.expectError(Error.UnknownEvaluator, parseDatasetJson(
        std.testing.allocator,
        "{\"version\":1,\"cases\":[],\"evaluators\":[\"missing\"]}",
        .{},
    ));
    try std.testing.expectError(Error.AmbiguousEvaluator, parseDatasetJson(
        std.testing.allocator,
        "{\"version\":1,\"cases\":[],\"evaluators\":[\"exact\"]}",
        .{ .evaluators = &.{ test_evaluator, test_evaluator } },
    ));
    const invalid_documents = [_][]const u8{
        "{\"version\":1,\"cases\":[{\"name\":\"\",\"prompt\":\"p\"}]}",
        "{\"version\":1,\"cases\":[{\"name\":\"same\",\"prompt\":\"p\"},{\"name\":\"same\",\"prompt\":\"p\"}]}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"prompt\":\"p\",\"metadata\":[{\"key\":\"\",\"value\":\"v\"}]}]}",
        "{\"version\":1,\"cases\":[],\"evaluators\":[\"same\",\"same\"]}",
        "{\"version\":1,\"cases\":[],\"evaluators\":[\"same\"],\"trace_evaluators\":[\"same\"]}",
        "{\"version\":1,\"cases\":[],\"trace_evaluators\":[\"same\"],\"report_evaluators\":[\"same\"]}",
        "{\"version\":1,\"cases\":[],\"unknown\":true}",
    };
    for (invalid_documents) |source| try std.testing.expectError(
        Error.InvalidDataset,
        parseDatasetJson(std.testing.allocator, source, test_registry),
    );
    try std.testing.expectError(Error.InvalidDataset, parseDatasetYaml(
        std.testing.allocator,
        "version: 1\nversion: 1\ncases: []\n",
        .{},
    ));
}

test "live dataset validation rejects lossy and ambiguous documents" {
    const EmptyEvaluator = evals.Evaluator{
        .name = "",
        .context = &test_context,
        .evaluateFn = testEvaluator,
    };
    const SameEvaluator = evals.Evaluator{
        .name = "same",
        .context = &test_context,
        .evaluateFn = testEvaluator,
    };
    const SameTrace = evals.TraceEvaluator{
        .name = "same",
        .context = &test_context,
        .evaluateFn = testTraceEvaluator,
    };
    const SameReport = evals.ReportEvaluator{
        .name = "same",
        .context = &test_context,
        .evaluateFn = testReportEvaluator,
    };
    const invalid = [_]evals.Dataset{
        .{ .cases = &.{.{ .name = "", .prompt = "p" }}, .evaluators = &.{} },
        .{ .cases = &.{ .{ .name = "same", .prompt = "p" }, .{ .name = "same", .prompt = "p" } }, .evaluators = &.{} },
        .{ .cases = &.{.{ .name = "case", .prompt = "p", .metadata = &.{ .{ .key = "same", .value = "1" }, .{ .key = "same", .value = "2" } } }}, .evaluators = &.{} },
        .{ .cases = &.{}, .evaluators = &.{EmptyEvaluator} },
        .{ .cases = &.{}, .evaluators = &.{ SameEvaluator, SameEvaluator } },
        .{ .cases = &.{}, .evaluators = &.{SameEvaluator}, .trace_evaluators = &.{SameTrace} },
        .{ .cases = &.{}, .evaluators = &.{SameEvaluator}, .report_evaluators = &.{SameReport} },
        .{ .cases = &.{}, .evaluators = &.{}, .trace_evaluators = &.{SameTrace}, .report_evaluators = &.{SameReport} },
    };
    for (invalid) |dataset| try std.testing.expectError(
        Error.InvalidDataset,
        stringifyDatasetJson(std.testing.allocator, dataset),
    );
    try std.testing.expectError(Error.UnsupportedCaseOptions, stringifyDatasetJson(std.testing.allocator, .{
        .cases = &.{.{ .name = "case", .prompt = "p", .options = .{
            .model_settings = .{ .temperature = 0.5 },
        } }},
        .evaluators = &.{},
    }));
    try std.testing.expectError(Error.InvalidDataset, parseDatasetJson(
        std.testing.allocator,
        "{\"version\":1,\"cases\":[],\"evaluators\":[\"\"]}",
        .{},
    ));
    try std.testing.expectError(Error.InvalidDataset, parseDatasetJson(
        std.testing.allocator,
        "{\"version\":1,\"cases\":[],\"report_evaluators\":[\"same\",\"same\"]}",
        .{},
    ));
}

test "report JSON and YAML preserve usage analyses and hex telemetry IDs" {
    const attributes = [_]telemetry_types.Attribute{
        .{ .key = "text", .value = .{ .string = "hello" } },
        .{ .key = "count", .value = .{ .integer = 2 } },
        .{ .key = "ratio", .value = .{ .float = 0.5 } },
        .{ .key = "cached", .value = .{ .boolean = true } },
    };
    const span = telemetry_types.Span{
        .name = "gen_ai.invoke_agent",
        .trace_id = [_]u8{0x11} ** 16,
        .span_id = [_]u8{0x22} ** 8,
        .parent_span_id = [_]u8{0x33} ** 8,
        .start_time_unix_nano = 10,
        .end_time_unix_nano = 20,
        .duration_seconds = 0.00000001,
        .status = .ok,
        .attributes = &attributes,
    };
    const details = [_]model_types.UsageDetail{.{ .name = "accepted_prediction_tokens", .value = 3 }};
    const usage = model_types.RunUsage{
        .input_tokens = 7,
        .output_tokens = 2,
        .details = &details,
        .cost = .{ .nano_usd = 42 },
        .cost_source = .provider,
        .requests = 1,
        .run_duration_ms = 4,
    };
    const evaluations = [_]evals.EvaluationResult{.{
        .evaluator = "exact",
        .passed = true,
        .score = 1,
        .reason = "matched",
        .attempts = 2,
    }};
    const cases = [_]evals.CaseResult{.{
        .name = "greeting",
        .output = "ok",
        .usage = usage,
        .evaluations = &evaluations,
        .spans = &.{span},
    }};
    const analyses = [_]evals.AnalysisResult{.{
        .evaluator = "pass-rate",
        .passed = true,
        .value = 1,
        .unit = "ratio",
        .reason = null,
    }};
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var report = evals.Report{ .arena = arena, .cases = &cases, .usage = usage, .analyses = &analyses };
    defer report.deinit();

    const json = try stringifyReportJson(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "11111111111111111111111111111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2222222222222222") != null);
    var from_json = try parseReportJson(std.testing.allocator, json);
    defer from_json.deinit();
    try std.testing.expectEqual(@as(u64, 7), from_json.usage.input_tokens);
    try std.testing.expectEqual(@as(u8, 0x11), from_json.cases[0].spans[0].trace_id[0]);
    try std.testing.expectEqual(@as(u8, 0x33), from_json.cases[0].spans[0].parent_span_id.?[0]);
    try std.testing.expectEqualStrings("ratio", from_json.analyses[0].unit.?);
    try std.testing.expectEqual(telemetry_types.Attribute.Value{ .boolean = true }, from_json.cases[0].spans[0].attributes[3].value);

    const yaml_source = try stringifyReportYaml(std.testing.allocator, report);
    defer std.testing.allocator.free(yaml_source);
    try std.testing.expect(std.mem.indexOf(u8, yaml_source, "trace_id: \"11111111111111111111111111111111\"") != null);
    var from_yaml = try parseReportYaml(std.testing.allocator, yaml_source);
    defer from_yaml.deinit();
    try std.testing.expectEqualStrings("matched", from_yaml.cases[0].evaluations[0].reason.?);
    try std.testing.expectEqual(@as(u64, 42), from_yaml.usage.cost.?.nano_usd);
}

test "report documents reject invalid versions identities numbers and structure" {
    try std.testing.expectError(Error.UnsupportedReportVersion, parseReportJson(
        std.testing.allocator,
        "{\"version\":2,\"cases\":[],\"usage\":{}}",
    ));
    const invalid_reports = [_][]const u8{
        "{\"version\":1,\"cases\":[],\"usage\":{},\"unknown\":true}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"case_index\":0,\"repetition\":0,\"repetitions\":1,\"task_attempts\":1,\"output\":\"\",\"usage\":{},\"evaluations\":[]}],\"usage\":{}}",
        "{\"version\":1,\"cases\":[],\"usage\":{\"cost_source\":\"provider\"}}",
        "{\"version\":1,\"cases\":[],\"usage\":{\"details\":[{\"name\":\"same\",\"value\":1},{\"name\":\"same\",\"value\":2}]}}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"case_index\":0,\"repetition\":1,\"repetitions\":1,\"task_attempts\":1,\"output\":\"\",\"usage\":{},\"evaluations\":[{\"evaluator\":\"\",\"passed\":true,\"score\":null,\"reason\":null,\"attempts\":1}]}],\"usage\":{}}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"case_index\":0,\"repetition\":1,\"repetitions\":1,\"task_attempts\":1,\"output\":\"\",\"usage\":{},\"evaluations\":[],\"spans\":[{\"name\":\"span\",\"kind\":\"internal\",\"trace_id\":\"bad\",\"span_id\":\"2222222222222222\",\"start_time_unix_nano\":2,\"end_time_unix_nano\":1,\"duration_seconds\":1,\"status\":\"ok\",\"attributes\":[]}]}],\"usage\":{}}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"case_index\":0,\"repetition\":1,\"repetitions\":1,\"task_attempts\":1,\"output\":\"\",\"usage\":{},\"evaluations\":[],\"spans\":[{\"name\":\"span\",\"kind\":\"internal\",\"trace_id\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\",\"span_id\":\"2222222222222222\",\"start_time_unix_nano\":1,\"end_time_unix_nano\":2,\"duration_seconds\":1,\"status\":\"ok\",\"attributes\":[]}]}],\"usage\":{}}",
        "{\"version\":1,\"cases\":[{\"name\":\"case\",\"case_index\":0,\"repetition\":1,\"repetitions\":1,\"task_attempts\":1,\"output\":\"\",\"usage\":{},\"evaluations\":[],\"spans\":[{\"name\":\"\",\"kind\":\"internal\",\"trace_id\":\"11111111111111111111111111111111\",\"span_id\":\"2222222222222222\",\"start_time_unix_nano\":1,\"end_time_unix_nano\":2,\"duration_seconds\":-1,\"status\":\"ok\",\"attributes\":[]}]}],\"usage\":{}}",
        "{\"version\":1,\"cases\":[],\"usage\":{},\"analyses\":[{\"evaluator\":\"\",\"passed\":null,\"value\":null,\"unit\":null,\"reason\":null}]}",
    };
    for (invalid_reports) |source| try std.testing.expectError(
        Error.InvalidReport,
        parseReportJson(std.testing.allocator, source),
    );
    try std.testing.expectError(Error.InvalidReport, parseReportYaml(
        std.testing.allocator,
        "version: 1\nversion: 1\ncases: []\nusage: {}\n",
    ));
}

test "report validation rejects invalid live values" {
    try std.testing.expectError(Error.InvalidReport, validateUsage(.{
        .details = &.{.{ .name = "", .value = 1 }},
    }));
    try std.testing.expectError(Error.InvalidReport, validateEvaluations(&.{.{
        .evaluator = "score",
        .passed = false,
        .score = std.math.nan(f64),
        .reason = null,
    }}));
    try std.testing.expectError(Error.InvalidReport, validateEvaluations(&.{
        .{ .evaluator = "same", .passed = true, .score = null, .reason = null },
        .{ .evaluator = "same", .passed = true, .score = null, .reason = null },
    }));
    try std.testing.expectError(Error.InvalidReport, validateAnalyses(&.{.{
        .evaluator = "value",
        .passed = null,
        .value = std.math.inf(f64),
        .unit = null,
        .reason = null,
    }}));
    try std.testing.expectError(Error.InvalidReport, validateAnalyses(&.{
        .{ .evaluator = "same", .passed = null, .value = null, .unit = null, .reason = null },
        .{ .evaluator = "same", .passed = null, .value = null, .unit = null, .reason = null },
    }));
    try std.testing.expectError(Error.InvalidReport, validateAttributes(&.{.{
        .key = "",
        .value = .{ .string = "value" },
    }}));
    try std.testing.expectError(Error.InvalidReport, validateAttributes(&.{.{
        .key = "value",
        .value = .{ .float = std.math.nan(f64) },
    }}));
    try std.testing.expectError(Error.InvalidReport, validateTelemetrySpan(.{
        .name = "",
        .trace_id = [_]u8{0} ** 16,
        .span_id = [_]u8{0} ** 8,
        .start_time_unix_nano = 1,
        .end_time_unix_nano = 2,
        .duration_seconds = 1,
        .status = .ok,
        .attributes = &.{},
    }));

    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var report = evals.Report{
        .arena = arena,
        .cases = &.{.{
            .name = "case",
            .repetition = 2,
            .repetitions = 1,
            .output = "",
            .usage = .{},
            .evaluations = &.{},
        }},
        .usage = .{},
    };
    defer report.deinit();
    try std.testing.expectError(Error.InvalidReport, stringifyReportJson(std.testing.allocator, report));
}

test "YAML rendering covers scalar and nested collection forms" {
    const yaml_source = try jsonToYaml(
        std.testing.allocator,
        "{\"null\":null,\"false\":false,\"number\":123456789012345678901,\"empty_object\":{},\"nested\":[[1,2],[],{}],\"objects\":[{\"nested\":{\"value\":1}}],\"space key\":{\"child\":[true]},\"\":0}",
    );
    defer std.testing.allocator.free(yaml_source);
    try std.testing.expect(std.mem.indexOf(u8, yaml_source, "null: null") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_source, "123456789012345678901") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_source, "empty_object: {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_source, "\"space key\":") != null);

    const scalar = try jsonToYaml(std.testing.allocator, "true");
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("true\n", scalar);
    const empty_object = try jsonToYaml(std.testing.allocator, "{}");
    defer std.testing.allocator.free(empty_object);
    try std.testing.expectEqualStrings("{}\n", empty_object);
    const empty_array = try jsonToYaml(std.testing.allocator, "[]");
    defer std.testing.allocator.free(empty_array);
    try std.testing.expectEqualStrings("[]\n", empty_array);
}

test "serialized evaluator registries retain executable callbacks" {
    const ordinary = try test_evaluator.evaluate(std.testing.allocator, .{
        .case = .{ .name = "case", .prompt = "prompt" },
        .output = "ok",
        .usage = .{},
    });
    try std.testing.expect(ordinary.passed);
    const span = telemetry_types.Span{
        .name = "span",
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
        .start_time_unix_nano = 1,
        .end_time_unix_nano = 2,
        .duration_seconds = 0.1,
        .status = .ok,
        .attributes = &.{},
    };
    const traced = try test_trace_evaluator.evaluate(std.testing.allocator, .{
        .run = .{
            .case = .{ .name = "case", .prompt = "prompt" },
            .output = "ok",
            .usage = .{},
        },
        .spans = &.{span},
    });
    try std.testing.expect(traced.passed);
    const case = evals.CaseResult{
        .name = "case",
        .output = "ok",
        .usage = .{},
        .evaluations = &.{},
    };
    const analyzed = try test_report_evaluator.evaluate(std.testing.allocator, .{
        .cases = &.{case},
        .usage = .{},
    });
    try std.testing.expect(analyzed.passed.?);
}

test "evaluation YAML parsers enforce the document byte limit" {
    const source = try std.testing.allocator.alloc(
        u8,
        json_limits.defaults.cli_config.max_document_bytes + 1,
    );
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    try std.testing.expectError(error.DocumentTooLarge, parseDatasetYaml(std.testing.allocator, source, .{}));
    try std.testing.expectError(error.DocumentTooLarge, parseReportYaml(std.testing.allocator, source));
}

fn checkDatasetAllocationFailure(allocator: std.mem.Allocator) !void {
    var dataset = try parseDatasetYaml(
        allocator,
        "version: 1\ncases:\n- name: case\n  prompt: prompt\nevaluators:\n- exact\n",
        test_registry,
    );
    dataset.deinit();
}

fn checkReportAllocationFailure(allocator: std.mem.Allocator) !void {
    var report = try parseReportYaml(
        allocator,
        "version: 1\ncases: []\nusage: {}\n",
    );
    report.deinit();
}

test "evaluation document parsing releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkDatasetAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkReportAllocationFailure, .{});
}
