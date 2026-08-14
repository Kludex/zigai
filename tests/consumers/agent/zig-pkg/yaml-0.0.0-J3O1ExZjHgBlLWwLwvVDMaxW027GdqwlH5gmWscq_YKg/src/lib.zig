//! Purpose: Public YAML library facade.
//! Owns: Stable public re-exports for parsing, loading, event emission, dumping, scanner access, and value types.
//! Does not own: Heavy parser, loader, scanner, schema, or emitter implementation.
//! Depends on: api modules, emitter module, scanner/scanner.zig, parser/event.zig, value/value.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance/stress tests.

const std = @import("std");
const diagnostics = @import("api/diagnostics.zig");
const emit_api = @import("api/emit.zig");
const event = @import("parser/event.zig");
const load_api = @import("api/load.zig");
const options = @import("api/options.zig");
const parse_api = @import("api/parse.zig");
const typed_api = @import("api/typed.zig");
const value = @import("value/value.zig");

/// YAML scanner/tokenizer namespace.
pub const scanner = @import("scanner/scanner.zig");

pub const Event = event.Event;
pub const DocumentStart = event.DocumentStart;
pub const DocumentEnd = event.DocumentEnd;
pub const TagDirective = event.TagDirective;
pub const CollectionStart = event.CollectionStart;
pub const CollectionStyle = event.CollectionStyle;
pub const ScalarStyle = event.ScalarStyle;
pub const Scalar = event.Scalar;
pub const ParseError = diagnostics.ParseError;
pub const Error = diagnostics.Error;
pub const WriteError = diagnostics.WriteError;
pub const Diagnostic = diagnostics.Diagnostic;
pub const ParseOptions = options.ParseOptions;
pub const EventStream = event.EventStream;
pub const Parser = parse_api.Parser;
pub const ScalarNode = value.ScalarNode;
pub const NullNode = value.NullNode;
pub const BoolNode = value.BoolNode;
pub const IntNode = value.IntNode;
pub const FloatNode = value.FloatNode;
pub const MappingPair = value.MappingPair;
pub const SequenceNode = value.SequenceNode;
pub const MappingNode = value.MappingNode;
pub const Node = value.Node;
pub const Schema = options.Schema;
pub const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
pub const UnknownTagBehavior = options.UnknownTagBehavior;
pub const LoadOptions = options.LoadOptions;
pub const FieldNameTransform = typed_api.FieldNameTransform;
pub const TypedConversionError = typed_api.TypedConversionError;
pub const TypedError = typed_api.TypedError;
pub const TypedDiagnostic = typed_api.TypedDiagnostic;
pub const TypedConversionOptions = typed_api.TypedConversionOptions;
pub const TypedLoadOptions = typed_api.TypedLoadOptions;
pub const EmitOptions = options.EmitOptions;
pub const DumpOptions = options.DumpOptions;
pub const LoadedDocument = value.LoadedDocument;
pub const LoadedStream = value.LoadedStream;
pub const TypedValue = typed_api.TypedValue;
pub const TypedDocument = typed_api.TypedDocument;
pub const TypedStream = typed_api.TypedStream;

pub const parseEvents = parse_api.parseEvents;
pub const parseEventsWithOptions = parse_api.parseEventsWithOptions;
pub const load = load_api.load;
pub const loadWithOptions = load_api.loadWithOptions;
pub const loadStream = load_api.loadStream;
pub const loadStreamWithOptions = load_api.loadStreamWithOptions;
pub const convertNode = typed_api.convertNode;
pub const loadTyped = typed_api.loadTyped;
pub const loadTypedWithOptions = typed_api.loadTypedWithOptions;
pub const loadStreamTyped = typed_api.loadStreamTyped;
pub const loadStreamTypedWithOptions = typed_api.loadStreamTypedWithOptions;
pub const emitEvents = emit_api.emitEvents;
pub const emitEventsWithOptions = emit_api.emitEventsWithOptions;
pub const emitEventsToWriter = emit_api.emitEventsToWriter;
pub const emitEventsToWriterWithOptions = emit_api.emitEventsToWriterWithOptions;
pub const emitValue = emit_api.emitValue;
pub const emitValueWithOptions = emit_api.emitValueWithOptions;
pub const emitValueToWriter = emit_api.emitValueToWriter;
pub const emitValueToWriterWithOptions = emit_api.emitValueToWriterWithOptions;
pub const dump = emit_api.dump;
pub const dumpWithOptions = emit_api.dumpWithOptions;
pub const dumpToWriter = emit_api.dumpToWriter;
pub const dumpToWriterWithOptions = emit_api.dumpToWriterWithOptions;
pub const dumpStream = emit_api.dumpStream;
pub const dumpStreamWithOptions = emit_api.dumpStreamWithOptions;
pub const dumpStreamToWriter = emit_api.dumpStreamToWriter;
pub const dumpStreamToWriterWithOptions = emit_api.dumpStreamToWriterWithOptions;

test {
    std.testing.refAllDecls(@This());
}
