# Testing

The testing strategy starts at the behavior users depend on.

High-level cassette tests run a real `Agent`, a real provider adapter, and a
real tool. They verify request JSON, response decoding, message history, usage
accounting, and termination. Small unit tests cover errors and helpers that are
difficult to reach clearly through a provider conversation.

## Local checks

```console
./scripts/check
```

The command enforces `zig fmt --check`, uses `zig build check` as the Zig
compiler-backed lint/type-check gate, and runs the full suite.

`./scripts/test-cli` adds a deterministic process-level test. It starts a local
HTTP fixture and sends all three binaries through the real standard-library
network transport, including authentication, provider decoding, streaming,
manifest loading, external tool execution, and the follow-up model request.

When `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are available, run the opt-in live
smoke tests with `./scripts/test-live`. It makes one minimal request to both;
when `GEMINI_API_KEY` is also present, it checks Google too. Live requests
complement cassettes; they never replace deterministic tests.

Provider cassettes live in `tests/cassettes/`. Their codec, recorder, replay
transport, and body filters live in `tests/support/`; none are exported by the
library or compiled into the command-line clients.

The files follow Cassetter v1 YAML. JSON bodies are nested YAML values, streamed
responses use literal text blocks, and binary bodies are explicit. Headers are
omitted by default. Review request and response content before committing a new
cassette.

## Coverage policy

The gate is 100% line coverage for every Zig file under `src/`, excluding Zig's
standard library, generated files, two type-declaration lines, and the timeout
sleep expression that LLVM/kcov cannot trace inside Zig's concurrent I/O task.
Coverage comes primarily from public, high-level behavior; a line-only unit test
should exist only when a high-level scenario would obscure the behavior being
tested.

Run `./scripts/coverage` on Linux. It compiles with LLVM debug information,
runs unit, cassette, agent, real-transport, CLI-success, and CLI-error paths,
merges their reports, checks that every source file is represented, and fails
unless the final line rate is exactly 100%. CI runs the same command. macOS
`kcov` requires extra debugger signing, so coverage remains a Linux-only gate.

Current verified baseline: 2077 of 2077 executable lines (100.00%).
