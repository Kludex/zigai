# API

Import the package root as `yaml` and use the public re-exports from
`src/lib.zig`. Files under `src/` are internal unless re-exported there.

```zig
const yaml = @import("yaml");
```

All allocating APIs take a caller-provided `std.mem.Allocator`. Owning return
types have `deinit`; returned output byte slices are caller-owned and must be
freed with the same allocator.

## Events

Use `parseEvents` for an owned event stream or `Parser` for pull-style event
iteration.

```zig
var events = try yaml.parseEvents(allocator, input);
defer events.deinit();

var parser = try yaml.Parser.init(allocator, input, .{});
defer parser.deinit();

while (try parser.next()) |event| {
    _ = event;
}
```

Events represent stream, document, sequence, mapping, scalar, and alias nodes.
Collection and scalar events carry style, anchor, and tag metadata when present.

## Values

Use `load` for one document and `loadStream` for a YAML stream.

```zig
var document = try yaml.load(allocator, input);
defer document.deinit();

var stream = try yaml.loadStream(allocator, input);
defer stream.deinit();
```

Loaded documents are arena-owned node graphs. Public node variants include null,
boolean, integer, float, scalar, sequence, mapping, and alias.

## Typed Values

Use `loadTyped` for one typed document, `loadStreamTyped` for a typed stream,
and `convertNode` when you already have a loaded `Node` graph. Typed wrappers own
all YAML-converted strings, slices, and nested allocations; call `deinit` on the
returned wrapper. Zig default field values keep their normal Zig ownership.

```zig
const Config = struct {
    name: []const u8,
    ports: []const u16,
    enabled: bool = true,
};

var typed = try yaml.loadTyped(Config, allocator,
    \\name: service
    \\ports: [80, 443]
    \\
);
defer typed.deinit();

var stream = try yaml.loadStreamTyped(Config, allocator, input);
defer stream.deinit();

var loaded = try yaml.load(allocator, input);
defer loaded.deinit();

var converted = try yaml.convertNode(Config, allocator, loaded.root, .{});
defer converted.deinit();
```

Typed loading first uses the generic loader, so schema, duplicate-key,
unknown-tag, diagnostic, and safety-limit behavior come from `LoadOptions`.
Conversion options are separate and control typed diagnostics plus explicit field
name transforms. Exact field-name matching is the default.

```zig
var parse_diagnostic: yaml.Diagnostic = .{};
var typed_diagnostic: yaml.TypedDiagnostic = .{};

var typed = try yaml.loadTypedWithOptions(Config, allocator, input, .{
    .load = .{
        .schema = .core,
        .diagnostic = &parse_diagnostic,
    },
    .conversion = .{
        .field_name_transform = .snake_to_kebab,
        .diagnostic = &typed_diagnostic,
    },
});
defer typed.deinit();
```

Conversion supports structs, optional fields, Zig default field values, slices,
arrays, integers, floats, booleans, strings, enums, supported tagged unions, and
nested compositions. Conversion failures return typed errors such as
`error.MissingField`, `error.TypeMismatch`, `error.LengthMismatch`,
`error.AmbiguousField`, or `error.UnsupportedTargetType`.

## Options

`parseEventsWithOptions`, `loadWithOptions`, and `loadStreamWithOptions` accept
limits and diagnostics. Loader options also select schema behavior,
duplicate-key handling, and unknown-tag handling.

```zig
var diagnostic: yaml.Diagnostic = .{};
var document = try yaml.loadWithOptions(allocator, input, .{
    .schema = .core,
    .duplicate_key_behavior = .reject,
    .unknown_tag_behavior = .preserve,
    .max_input_bytes = 1024 * 1024,
    .max_nesting_depth = 128,
    .diagnostic = &diagnostic,
});
defer document.deinit();
```

Supported schemas are `.failsafe`, `.json`, and `.core`. Unknown tags are
preserved by default; set `unknown_tag_behavior = .reject` to reject local or
otherwise unrecognized tags while still accepting standard YAML tags and the
non-specific `!` tag.

Public limits cover input size, token count, event count, scalar size, nesting
depth, alias count, alias expansion, document count, and output size depending
on the API layer.

Diagnostics report byte offset plus 1-based line and column. Diagnostic
messages are library-owned static strings and must not be freed.

## Emission

Use event emission to serialize parser events and dumping to serialize loaded
value graphs. Allocating APIs return caller-owned byte slices. Writer APIs write
to a caller-provided `std.Io.Writer`.

```zig
const emitted = try yaml.emitEvents(allocator, events.events);
defer allocator.free(emitted);

var buffer: [4096]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buffer);
try yaml.emitEventsToWriter(allocator, &writer, events.events);

const dumped = try yaml.dump(allocator, document.root);
defer allocator.free(dumped);

try yaml.emitValueToWriter(allocator, &writer, document.root);

const dumped_stream = try yaml.dumpStream(allocator, stream.documents);
defer allocator.free(dumped_stream);

try yaml.dumpStreamToWriter(allocator, &writer, stream.documents);
```

Emitter and dumper options control collection style preservation, redundant
document-start omission, `%TAG` directive preservation, and output byte limits.
Invalid YAML directive versions, invalid TAG directive handles or prefixes, and
duplicate TAG directive handles in one document are rejected.

## Scanner

The public facade exposes `yaml.scanner.scan` for callers that need scanner
tokens directly.

```zig
var tokens = try yaml.scanner.scan(allocator, input);
defer tokens.deinit();
```

The returned token stream owns its token array and any decoded or normalized
source buffer. Token payload slices remain valid until `TokenStream.deinit`.
