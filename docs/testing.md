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
compiler-backed lint/type-check gate, runs the full suite, and builds the
downstream consumer projects.

`tests/consumers/agent/` resolves ZigAI as a path dependency and runs the
public agent and evaluation APIs. `tests/consumers/providers/` imports the
unified module together with every standalone compatibility package. CI runs
both consumers through `./scripts/check` on Linux and macOS.

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

`tests/cassettes/models/` contains real tool-loop recordings for eight models
from each first-party provider. The matrix spans multiple model generations and
size tiers. It is defined once in
`tests/support/model_matrix.zig` and drives both recording and replay.

`tests/cassettes/native/` contains real provider-managed web-tool recordings:
OpenAI web search, Anthropic web search plus fetch, and Google Search plus URL
Context. These recordings verify the native request shapes and responses.

`tests/cassettes/rich/` contains one real inline-image exchange for each
first-party provider.

Record the complete matrix with real credentials:

```console
zig build record-cassettes
```

Pass a provider or exact model to record only part of it:

```console
zig build record-cassettes -- anthropic
zig build record-cassettes -- gemini-3.5-flash
zig build record-cassettes -- native-tools
zig build record-cassettes -- native-google
zig build record-cassettes -- rich-content
zig build record-cassettes -- rich-anthropic
```

The recorder accepts `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and either
`GOOGLE_API_KEY` or `GEMINI_API_KEY`. It replaces each cassette atomically only
after a successful agent tool loop. Authentication headers are never copied.

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
