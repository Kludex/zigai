# AGENTS.md

## Mission

A native Zig library implementing YAML 1.2.2 (https://yaml.org/spec/1.2.2/), verified against the official `yaml/yaml-test-suite`. Not a libyaml wrapper. Not a CLI. Not test-suite-shaped — a real, reusable library with a clean Zig API.

## Non-negotiables

- Native Zig. No wrapping libyaml or any other YAML implementation.
- 100% of YAML 1.2.2, validated against a pinned `yaml-test-suite` tag.
- Memory-safe: no leaks, no UB, no panics on malformed input. All allocation goes through caller-provided `std.mem.Allocator`.
- Correctness > performance. No optimization that costs correctness.
- Reasonable file sizes. See "Repository sanity" below — the goal is a codebase a human can hold in their head, not maximally fine-grained modularity.

## Public API

The package root is `src/lib.zig`. It re-exports the stable public surface and stays small. Everything below it is internal unless explicitly exposed. The public API supports:

- Loading a single YAML document (`load`) and a YAML stream (`loadStream`).
- Pull-style event parsing (`Parser`) and bulk event parsing (`parseEvents`).
- Emission from values (`dump`, `dumpStream`, `emitValue`) and from events (`emitEvents`), each with both allocating and writer-based variants.
- Configurable schema (`failsafe`, `json`, `core`), duplicate-key handling, unknown-tag handling, and safety limits (input size, depth, scalar size, alias count, alias expansion, document count, output size).
- Diagnostics with byte offset and 1-based line/column for every parser and loader failure.

The public API does not leak internal modules, does not use global allocators, and does not panic on user input. Public-facing types document their `deinit` contract. Caller-owned slices document the allocator they must be freed with.

## Architecture

The pipeline is the classic YAML processing model. Each layer is a single module unless there's a real cohesion reason to split it:

```
input bytes
  -> reader      (encoding detection, line-break normalization, source preparation)
  -> scanner     (tokens)
  -> parser      (events, from tokens)
  -> composer    (representation graph, anchors, aliases)
  -> schema      (tag resolution: failsafe / json / core)
  -> loader      (constructed value graph)
  -> value       (public node model)

events / values
  -> emitter     (YAML bytes, allocating or writer-based)
```

Allowed dependency direction is strictly downward: `api -> {loader, parser, emitter, value} -> compose -> parser -> scanner -> reader -> common`. `schema` depends only on `common`. No upward edges, no circular imports.

## Repository sanity

This project has had a history of over-fragmentation. The following rules push back against that.

**File size targets:**
- Aim for 400-1200 lines for implementation files.
- 1500 is the threshold where splitting needs justification.
- Split based on *cohesion*, not line count. A 1000-line module that owns one concept is correct. Seven 200-line modules that together own one concept are wrong.

**Anti-fragmentation rules:**
- No `<thing>_a.zig` / `<thing>_b.zig` / `<thing>_common.zig` family splits unless each file is genuinely independently usable. Block mapping parsing is one concept; it lives in one file.
- No "facade re-exporting from another facade" indirection. If `foo.zig` exists only to re-export from `foo/api.zig`, delete one of them.
- No public layer-API facades unless the layer is exposed to external consumers. Internal layers are imported directly.
- A new file needs a one-sentence answer to "what would I lose by inlining this into its parent?" If the answer is "nothing," don't create it.

**What does *not* belong in source files:**
- Long YAML examples (use `tests/fixtures/` or the vendored suite).
- Generated tables that are large enough to obscure handwritten logic — separate them.

**Tests** mirror source layout but follow the same anti-fragmentation rules. One test file per module is the default. Split a test file only when it crosses ~600 lines or covers genuinely different feature areas.

## TDD workflow

1. Pick one small behavior.
2. Add a failing test. Confirm it fails for the *expected* reason.
3. Implement the smallest correct change.
4. Run focused tests, then the layer, then the full suite.
5. Refactor only with green tests.
6. Keep commits focused. No drive-by cleanup in feature commits.

For conformance work: enable a small group of suite cases, fix one feature, expand. Never bulk-enable many cases and ship one giant patch. Skipped cases must be tracked in `tests/conformance/skips.zig` with a reason and a feature area; the goal is zero undocumented skips.

## Memory rules

- All allocation is caller-provided. No hidden globals.
- Every owning type has a `deinit`. Every allocation has a clear owner.
- `errdefer` cleans up on partial failure. Allocation-failure paths are tested.
- Prefer slices into the original input where safe; copy only when escaping/normalization/lifetime requires it.
- Arenas are appropriate for document-owned data. Streaming APIs are available for callers who don't want to allocate the whole document.
- Configurable limits exist for input size, nesting depth, alias count, alias expansion, scalar size, document count, and output size. Exceeding a limit returns `error.Unsupported` with a diagnostic, never UB or recursion overflow.

## Errors and diagnostics

Malformed YAML is normal input for a YAML library, not an exception. Errors are structured, carry byte offset and 1-based line/column, and clean up allocations. The library never panics, never asserts on user-controlled input, and never uses `unreachable` for malformed YAML — `unreachable` is reserved for true post-validation impossibilities.

## yaml-test-suite

Pinned to a specific released tag (currently `data-2022-01-17`), recorded in `vendor/yaml-test-suite.PIN`. The mutable `data` branch is not used as the gate. Vendored under `vendor/yaml-test-suite/`.

The harness validates:
- Parser events against `test.event`.
- Loaded values against `in.json`.
- Expected failures against `error`.
- Emitter output against `emit.yaml` and `out.yaml` where applicable.

The harness lives in `tests/conformance/` and does not contaminate library API design. Suite-specific behavior never leaks into `src/`.

## Build and verification

Standard Zig commands:

```sh
zig build              # build
zig build test         # all tests, including conformance
zig build coverage     # kcov, fails below threshold
```

Additional steps that should exist and stay simple: `test-unit`, `test-conformance`, `test-stress`, `test-allocation`, `test-leaks`, `test-valgrind`, `conformance-report`. CI runs formatting, all test variants, coverage, and Valgrind.

`README.md` is the public entry point for current validation context. `vendor/yaml-test-suite.PIN` records the exact pinned suite repository, tag, and commit. Use `zig build conformance-report` for current generated conformance counts instead of copying status snapshots into docs.

`docs/api.md`, `docs/architecture.md`, and `docs/memory.md` describe stable contracts and stay short. They are not progress logs.

## Style

- `zig fmt` clean.
- Idiomatic Zig: explicit allocation, explicit ownership, meaningful error sets.
- Simple state machines beat clever abstractions in parsers.
- No global mutable state.
- Catch-all error handling is a smell.

## Agent behavior

- Read this file first. Look at `README.md` and `vendor/yaml-test-suite.PIN` for current validation context.
- Small, focused, test-first changes.
- Don't change public API casually.
- Don't bulk-enable conformance cases to chase a number.
- Don't add files when an existing module is the natural home.
- Don't paste a verification log into docs. Git history and CI are the log.
- When in doubt about scope, narrow it.

The goal is a correct, maintainable, memory-safe YAML 1.2.2 library a real human can read end-to-end — not a maximally subdivided artifact.
