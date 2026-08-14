# Memory Behavior

This document defines the public allocator, ownership, borrowing, and cleanup
contracts for the YAML API.

## Allocators

All public APIs that allocate take a caller-provided `std.mem.Allocator`. The
library does not use hidden global allocators or global mutable allocation
state.

The following APIs return owning values with internal storage:

- `yaml.scanner.scan` returns `scanner.TokenStream`.
- `yaml.parseEvents` and `yaml.parseEventsWithOptions` return `EventStream`.
- `yaml.Parser.init` returns `Parser`.
- `yaml.load` and `yaml.loadWithOptions` return `LoadedDocument`.
- `yaml.loadStream` and `yaml.loadStreamWithOptions` return `LoadedStream`.
- `yaml.loadTyped` and `yaml.loadTypedWithOptions` return `TypedDocument(T)`.
- `yaml.loadStreamTyped` and `yaml.loadStreamTypedWithOptions` return
  `TypedStream(T)`.
- `yaml.convertNode` returns `TypedValue(T)`.

The following APIs return caller-owned byte slices:

- `yaml.emitEvents` and `yaml.emitEventsWithOptions`
- `yaml.emitValue` and `yaml.emitValueWithOptions`
- `yaml.dump` and `yaml.dumpWithOptions`
- `yaml.dumpStream` and `yaml.dumpStreamWithOptions`

Free returned byte slices with `allocator.free(output)` using the same allocator
passed to the call.

Writer emission APIs take both the caller allocator and a `*std.Io.Writer`:

- `yaml.emitEventsToWriter` and `yaml.emitEventsToWriterWithOptions`
- `yaml.emitValueToWriter` and `yaml.emitValueToWriterWithOptions`
- `yaml.dumpToWriter` and `yaml.dumpToWriterWithOptions`
- `yaml.dumpStreamToWriter` and `yaml.dumpStreamToWriterWithOptions`

Writer APIs borrow the writer only for the duration of the call.

## Borrowing

`scanner.TokenStream.source` is decoded UTF-8 after YAML line-break
normalization. For UTF-16 or UTF-32 input, or UTF-8 input that needs line-break
normalization, the source bytes are copied into token-stream storage. For UTF-8
input that does not need normalization, `source` and token payloads may borrow
from the caller-provided input. Keep that input alive until
`TokenStream.deinit`.

`parseEvents` borrows caller input only during the call. Returned event payload
slices are owned by the returned `EventStream` and remain valid until
`EventStream.deinit`.

`Parser.init` borrows caller input only during initialization. Events returned by
`Parser.next` borrow from parser-owned storage and remain valid until
`Parser.deinit`.

`load` and `loadStream` borrow caller input only during the call. Returned nodes,
scalar values, collection slices, anchors, tags, and stream document slices are
owned by the returned loaded document or stream.

Typed loading also borrows caller input only during the call. Typed wrappers own
YAML-converted strings, slices, nested allocations, and stream value slices in
their own arena, so typed values remain valid after any intermediate
`LoadedDocument` or `LoadedStream` used during conversion is deinitialized. Zig
default field values keep their normal Zig ownership.

Emission and dumping APIs borrow caller-provided event slices, node graphs, and
writers only during the call.

## Cleanup

Every owning return type has deterministic cleanup:

- `scanner.TokenStream.deinit()` releases scanner tokens and any owned decoded or
  normalized source bytes.
- `EventStream.deinit()` releases parser events and event payload data.
- `Parser.deinit()` releases parser-owned events and payload data.
- `LoadedDocument.deinit()` releases the loaded document graph.
- `LoadedStream.deinit()` releases all loaded document graphs in the stream.
- `TypedValue(T).deinit()` releases conversion allocations from `convertNode`.
- `TypedDocument(T).deinit()` releases conversion allocations from `loadTyped`.
- `TypedStream(T).deinit()` releases all converted stream values.

Caller-owned output slices from emit and dump APIs are not wrapped in a struct;
free them directly with the caller allocator.

## Errors

Public parse, load, emit, and dump APIs return `yaml.Error`; writer APIs may also
return writer errors. Allocation failure is propagated to the caller.

Typed loading APIs return parser and loader errors unchanged, plus typed
conversion errors for missing fields, type mismatches, length mismatches,
ambiguous field matches, unsupported target types, and allocation failure.
`TypedConversionOptions.diagnostic` is caller-owned; when node source locations
are unavailable, typed diagnostics report the YAML path and target type without
fabricating byte offsets or line/column values.

Malformed YAML returns an error, not a panic. Diagnostics supplied through
`ParseOptions.diagnostic` or `LoadOptions.diagnostic` are caller-owned.
Diagnostic messages are static library strings and do not need to be freed.

On failure, partially built scanner streams, event streams, loaded graphs, and
temporary emission buffers release their owned memory before returning the error.

## Limits

Configured limits return `error.Unsupported` when exceeded. Public options expose
limits for input size, token count, event count, nesting depth, scalar size,
alias count, alias expansion, document count, and output size depending on API
layer.

Duplicate mapping keys are rejected by default after schema resolution and can be
preserved with `LoadOptions.duplicate_key_behavior = .allow`.

When diagnostics are supplied, parser-stage limit failures report a byte offset
and 1-based line/column in the input. Loader-stage failures such as duplicate
mapping keys, unknown tags, invalid standard tags, alias limits, document count
limits, and single-document load count mismatches use the same diagnostic
ownership contract.
