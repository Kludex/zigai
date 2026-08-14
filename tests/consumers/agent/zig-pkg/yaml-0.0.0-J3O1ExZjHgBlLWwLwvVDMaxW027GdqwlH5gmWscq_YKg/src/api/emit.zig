//! Purpose: Public YAML emission and dumping API facade.
//! Owns: Stable re-exports for event emission and value dumping entry points.
//! Does not own: Event layout, scalar formatting, node traversal, or writer implementation.
//! Depends on: emitter/emitter.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance emitter tests.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const impl = @import("../emitter/emitter.zig");
const options_api = @import("options.zig");
const event_types = @import("../parser/event.zig");
const value_model = @import("../value/value.zig");

const DumpOptions = options_api.DumpOptions;
const EmitOptions = options_api.EmitOptions;
const Error = common.Error;
const Event = event_types.Event;
const Node = value_model.Node;
const WriteError = common.WriteError;

pub const emitEvents = impl.emitEvents;
pub fn emitEventsWithOptions(allocator: std.mem.Allocator, events: []const Event, options: EmitOptions) Error![]u8 {
    return impl.emitEventsWithOptions(allocator, events, toImplEmitOptions(options));
}
pub const emitEventsToWriter = impl.emitEventsToWriter;
pub fn emitEventsToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    events: []const Event,
    options: EmitOptions,
) WriteError!void {
    return impl.emitEventsToWriterWithOptions(allocator, writer, events, toImplEmitOptions(options));
}
pub const emitValue = impl.emitValue;
pub fn emitValueWithOptions(allocator: std.mem.Allocator, root: *const Node, options: DumpOptions) Error![]u8 {
    return impl.emitValueWithOptions(allocator, root, toImplDumpOptions(options));
}
pub const emitValueToWriter = impl.emitValueToWriter;
pub fn emitValueToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: *const Node,
    options: DumpOptions,
) WriteError!void {
    return impl.emitValueToWriterWithOptions(allocator, writer, root, toImplDumpOptions(options));
}
pub const dump = impl.dump;
pub fn dumpWithOptions(allocator: std.mem.Allocator, root: *const Node, options: DumpOptions) Error![]u8 {
    return impl.dumpWithOptions(allocator, root, toImplDumpOptions(options));
}
pub const dumpToWriter = impl.dumpToWriter;
pub fn dumpToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: *const Node,
    options: DumpOptions,
) WriteError!void {
    return impl.dumpToWriterWithOptions(allocator, writer, root, toImplDumpOptions(options));
}
pub const dumpStream = impl.dumpStream;
pub fn dumpStreamWithOptions(allocator: std.mem.Allocator, documents: []const *const Node, options: DumpOptions) Error![]u8 {
    return impl.dumpStreamWithOptions(allocator, documents, toImplDumpOptions(options));
}
pub const dumpStreamToWriter = impl.dumpStreamToWriter;
pub fn dumpStreamToWriterWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    documents: []const *const Node,
    options: DumpOptions,
) WriteError!void {
    return impl.dumpStreamToWriterWithOptions(allocator, writer, documents, toImplDumpOptions(options));
}

fn toImplEmitOptions(options: EmitOptions) impl.EmitOptions {
    return .{
        .preserve_top_level_flow_mapping_style = options.preserve_top_level_flow_mapping_style,
        .preserve_block_sequence_flow_mapping_style = options.preserve_block_sequence_flow_mapping_style,
        .preserve_collection_style = options.preserve_collection_style,
        .preserve_unused_tag_directives = options.preserve_unused_tag_directives,
        .omit_redundant_document_start = options.omit_redundant_document_start,
        .max_output_bytes = options.max_output_bytes,
    };
}

fn toImplDumpOptions(options: DumpOptions) impl.DumpOptions {
    return .{
        .preserve_top_level_flow_mapping_style = options.preserve_top_level_flow_mapping_style,
        .preserve_block_sequence_flow_mapping_style = options.preserve_block_sequence_flow_mapping_style,
        .preserve_collection_style = options.preserve_collection_style,
        .omit_redundant_document_start = options.omit_redundant_document_start,
        .max_output_bytes = options.max_output_bytes,
    };
}

test {
    std.testing.refAllDecls(@This());
}
