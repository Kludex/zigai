# yaml

[![CI](https://github.com/ncode/yaml/actions/workflows/ci.yml/badge.svg)](https://github.com/ncode/yaml/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/ncode/yaml/graph/badge.svg?token=97Q2MPTNBJ)](https://codecov.io/gh/ncode/yaml)

Native Zig YAML 1.2.2 library.

## Why This Library

- Pure Zig.
- Passes the full official [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite) at the pinned released tag, with **zero skips** (enforced by the build).
- Caller-allocated and leak-free. Every owning type has a `deinit`; allocation failure is propagated, not hidden.
- Memory-safe on malformed input: no panics, no `unreachable`, no UB. Limits return `error.Unsupported` with a diagnostic.
- Structured diagnostics with byte offset and 1-based line/column for parser, loader, emitter, and typed-conversion failures.
- Configurable schemas (failsafe, JSON, core), duplicate-key handling, unknown-tag handling, and safety limits across the pipeline.

## Status

- Requires **Zig 0.16.0** or newer (enforced at build time).
- **YAML 1.2.2 compliant.** The library passes every case in the vendored `yaml-test-suite` at the pinned released tag (currently `data-2022-01-17`, see `vendor/yaml-test-suite.PIN`). The skip list in `tests/conformance/skips.zig` is empty, and the build refuses to accept new skips against the pinned suite.
- Run `zig build conformance-report` for current parser, loader, expected-error, and emitter coverage counts.
- Pre-1.0: the public API may still change before a tagged release.

## Install

Add the library as a dependency:

```sh
zig fetch --save git+https://github.com/ncode/yaml
```

Wire it into your `build.zig`:

```zig
const yaml = b.dependency("yaml", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("yaml", yaml.module("yaml"));
```

Then import it from your Zig source:

```zig
const yaml = @import("yaml");
```

## Quick Start

```zig
const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var document = try yaml.load(allocator, "name: yaml\nactive: true\n");
    defer document.deinit();

    const output = try yaml.dump(allocator, document.root);
    defer allocator.free(output);

    std.debug.print("{s}", .{output});
}
```

## API Tour

The public surface lives in `src/lib.zig`. Files below it are internal.

### Events

Pull-style with `Parser`, or bulk with `parseEvents`:

```zig
var parser = try yaml.Parser.init(allocator, input, .{});
defer parser.deinit();

while (try parser.next()) |event| {
    _ = event;
}

var events = try yaml.parseEvents(allocator, input);
defer events.deinit();
```

Events carry style, anchor, and tag metadata for stream, document, sequence, mapping, scalar, and alias nodes.

### Documents

```zig
var document = try yaml.load(allocator, input);
defer document.deinit();

var stream = try yaml.loadStream(allocator, input);
defer stream.deinit();
```

Loaded documents are arena-owned node graphs. Node variants include null, boolean, integer, float, scalar, sequence, mapping, and alias.

### Typed Loading

Load directly into Zig structs, slices, enums, scalars, optionals, and supported tagged unions:

```zig
const Config = struct {
    name: []const u8,
    ports: []const u16,
    enabled: bool = true,
};

var typed = try yaml.loadTyped(Config, allocator, input);
defer typed.deinit();
```

Use `loadTypedWithOptions` to pass parser and conversion options together:

```zig
var parse_diagnostic: yaml.Diagnostic = .{};
var typed_diagnostic: yaml.TypedDiagnostic = .{};

var typed = try yaml.loadTypedWithOptions(Config, allocator, input, .{
    .load = .{
        .schema = .core,
        .duplicate_key_behavior = .reject,
        .diagnostic = &parse_diagnostic,
    },
    .conversion = .{
        .field_name_transform = .snake_to_kebab,
        .diagnostic = &typed_diagnostic,
    },
});
defer typed.deinit();
```

`load` options control schema, duplicate keys, unknown tags, limits, and parser diagnostics. `conversion` options control typed-conversion behavior and diagnostics. `loadStreamTyped` covers multi-document inputs. `convertNode` converts an already-loaded `Node` graph:

```zig
var loaded = try yaml.load(allocator, input);
defer loaded.deinit();

var converted = try yaml.convertNode(Config, allocator, loaded.root, .{});
defer converted.deinit();
```

Conversion failures return typed errors such as `error.MissingField`, `error.TypeMismatch`, `error.LengthMismatch`, `error.AmbiguousField`, and `error.UnsupportedTargetType`.

### Emission

Allocating and writer-based variants for both events and value graphs:

```zig
const dumped = try yaml.dump(allocator, document.root);
defer allocator.free(dumped);

var buffer: [4096]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buffer);
try yaml.dumpToWriter(allocator, &writer, document.root);

const emitted = try yaml.emitEvents(allocator, events.events);
defer allocator.free(emitted);
```

`dumpStream` and `dumpStreamToWriter` serialize a `LoadedStream`; `emitValue` and `emitValueToWriter` are lower-level node-graph variants alongside `dump`. Every emit and dump function has a `*WithOptions` form.

Emitter and dumper options control collection style preservation, `%TAG` directive preservation, redundant document-start omission, and output size limits.

### Options And Diagnostics

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

Schemas: `.failsafe`, `.json`, `.core`. Limits cover input size, token count, event count, scalar size, nesting depth, alias count, alias expansion, document count, and output size depending on the API layer. Diagnostic messages are library-owned static strings; do not free them.

### Scanner

```zig
var tokens = try yaml.scanner.scan(allocator, input);
defer tokens.deinit();
```

The token stream owns its token array and any decoded or normalized source buffer.

## Build And Test

Primary commands:

```sh
zig build
zig build test
```

Focused targets:

```sh
zig build test-unit
zig build test-conformance
zig build test-direct-conformance
zig build test-structure
zig build test-schema
zig build test-stress
zig build test-allocation
zig build test-leaks
zig build test-valgrind
zig build coverage
zig build docs
```

Tools:

```sh
zig build bench                # parser/loader micro-benchmarks
zig build conformance-report   # current yaml-test-suite coverage counts
zig build libfyaml-compare     # cross-check suite behavior against libfyaml fy-tool
```

`libfyaml-compare` requires `python3` and an `fy-tool` executable; supply one with `-Dlibfyaml-fy-tool=/path/to/fy-tool` or have `fy-tool` on `PATH`.

## Conformance

The conformance harness validates behavior against the vendored pinned `yaml/yaml-test-suite` release under `vendor/yaml-test-suite/`. The exact repository, tag, and commit are recorded in `vendor/yaml-test-suite.PIN`.

`zig build conformance-report` is the source of truth for current parser, loader, expected-error, and emitter coverage. The README intentionally does not copy snapshot counts.

To run conformance against a different generated suite data directory without replacing the vendored pin:

```sh
zig build test-conformance -Dyaml-test-suite-dir=/path/to/yaml-test-suite-data
```

## Documentation

- `docs/api.md`: public API examples, options, diagnostics, and ownership details.
- `docs/architecture.md`: processing pipeline and dependency direction.
- `docs/memory.md`: allocator, borrowing, cleanup, error, and limit contracts.
- `AGENTS.md`: contributor-facing project rules, file-size targets, and TDD workflow.

The package root is `src/lib.zig`; files below it are internal unless re-exported there.

## Scope And Non-Goals

- Native Zig implementation only.
- Library API only; no command-line YAML tool.
- Correctness and memory safety take priority over performance shortcuts.
- YAML 1.2.2 conformance is tracked through the pinned test suite, not README status snapshots.

## License

MIT. See [LICENSE](LICENSE).
