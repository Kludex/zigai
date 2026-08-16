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

`tests/fixtures/pydantic_ai/` contains cross-language message golden files.
Regenerate the pinned v2 fixture with the official upstream adapter:

```console
uv run --with pydantic-ai-slim==2.31.0 \
  python scripts/generate-pydantic-ai-messages-fixture.py \
  tests/fixtures/pydantic_ai/messages-v2.31.0.json
```

The generator checks the installed package version before writing the fixture.

`tests/cassettes/models/` contains real tool-loop recordings for eight models
from each first-party provider. The matrix spans multiple model generations and
size tiers. Every recording is defined once in the typed
`tests/support/cassette_manifest.zig` manifest. Recording and replay share its
stable ID, provider, model, scenario, fixture path, execution route, and
credential requirements. Its source field distinguishes live recordings from
deterministic failure injections.

`tests/cassettes/buffered/` contains a separate minimal text response for the
same 24-model first-party matrix. These fixtures isolate ordinary request
encoding, response decoding, usage, and terminal-state handling from tools.

`tests/cassettes/streamed/text/` and `tests/cassettes/streamed/tools/` contain
48 real streams for that matrix. Text fixtures require decoded deltas, usage,
one final result, and exact `pong` output. Tool fixtures additionally require
one completed function call, one local result, final text containing the
returned temperature, and complete two-request replay.

`tests/cassettes/providers/` and `tests/cassettes/compatible/` cover the eleven
configured Chat Completions providers. Every provider has a real buffered and
streamed-text response plus a complete function-tool loop. Scenario models may
differ when a provider's text model does not expose tools; for example,
Together text uses GPT-OSS while its tool row uses the serverless Qwen model
from Together's function-calling example.

`tests/cassettes/structured/` and `tests/cassettes/thinking/` contain one real
recording per first-party capability profile. Structured fixtures validate the
native OpenAI `text.format`, Anthropic `output_config.format`, and Google
`responseJsonSchema` request shapes through a provider-neutral typed result.
Thinking fixtures validate each provider's high-effort wire control and
normalized reasoning usage. Anthropic additionally proves streamed thinking
parts, deltas, opaque signatures, and durable message history; OpenAI and
Google keep provider-hidden reasoning out of neutral content parts.

`tests/cassettes/errors/` contains deterministic OpenAI, Anthropic, and Google
failure sequences. Each one covers a 429 recovery with retry hints and rate
metadata, retry exhaustion after two 503 responses, malformed-success
classification, and a non-retryable 400 observed through strict message, code,
and body bounds. These fixtures use provider-realistic wire envelopes but are
not live recordings: manufacturing upstream failures would be unsafe and
nondeterministic. One shared Chat Completions contract fixture runs through all
eleven named compatible providers, proving their provider identities without
duplicating identical protocol YAML.

`tests/cassettes/native/` contains real provider-native recordings: OpenAI web
search, Anthropic web search plus fetch, Google Search plus URL Context, a
complete Amazon Bedrock Converse function-tool loop, and an Azure OpenAI v1
Responses function-tool loop. It also contains a Mistral Conversations web
search with native execution entries, references, and connector-token usage,
plus a Cohere v2 strict function-tool loop with citations. These recordings
verify the native request shapes and responses. Replay also proves the neutral
evidence boundary: OpenAI URL citations, Anthropic server-tool calls and
results, Google grounding chunks and supports, and Mistral tool references are
retained as structured provider details alongside normalized usage counters.

`tests/cassettes/specialized/` completes the ordinary success matrix for the
specialized native routes. It contains buffered Bedrock Converse; buffered and
streamed Azure Responses; buffered, streamed, and function-tool Mistral
Conversations; and buffered and streamed Cohere v2 Chat. The existing native
fixtures supply the Bedrock, Azure, and Cohere function-tool loops. Bedrock
streaming is excluded because its current adapter is buffered-only.

`tests/cassettes/rich/` contains one real inline-image exchange for each
first-party provider. Replay checks the semantic answer (`red`) rather than
accepting any non-empty model output.

`tests/cassettes/files/` contains a real lifecycle for each first-party
provider. OpenAI covers a downloadable fine-tuning input; Anthropic records the
safe upload, inspect, reuse, and delete path for a non-downloadable uploaded
file; Google covers resumable upload, inspect, reuse, and delete.

Record the complete matrix with real credentials:

```console
zig build record-cassettes
```

Inspect the manifest without making a request or exposing credential values.
The first command reports readiness for every recording; the second prints only
recordings whose complete credential set is present:

```console
zig build record-cassettes -- --list
zig build record-cassettes -- --list-runnable
```

Pass a stable manifest ID, provider, exact model, or scenario to record only
part of it:

```console
zig build record-cassettes -- anthropic
zig build record-cassettes -- gemini-3.5-flash
zig build record-cassettes -- openai/gpt-5-nano/native-tool
zig build record-cassettes -- function-tool
zig build record-cassettes -- first-party-buffered
zig build record-cassettes -- first-party-streaming
zig build record-cassettes -- first-party-capabilities
zig build record-cassettes -- streamed-text
zig build record-cassettes -- streamed-function-tool
zig build record-cassettes -- structured-output
zig build record-cassettes -- thinking
zig build record-cassettes -- provider-error
zig build record-cassettes -- native-tools
zig build record-cassettes -- native-google
zig build record-cassettes -- native-bedrock
zig build record-cassettes -- native-azure
zig build record-cassettes -- native-cohere
zig build record-cassettes -- specialized-success
zig build record-cassettes -- mistral
zig build record-cassettes -- rich-content
zig build record-cassettes -- rich-anthropic
zig build record-cassettes -- files
zig build record-cassettes -- files-google
```

Unknown and empty filters fail before network I/O. Credentials are resolved
only after selection, so recording one provider never requires unrelated keys.
Deterministic fixtures are reported as `fixture` by `--list`, omitted by
`--list-runnable`, and explicitly skipped by the recorder without resolving a
credential or making a request.

The recorder accepts `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and either
`GOOGLE_API_KEY` or `GEMINI_API_KEY`. Native Bedrock recording additionally
uses `AWS_BEARER_TOKEN_BEDROCK` and `AWS_DEFAULT_REGION`; native Azure recording
uses `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_ENDPOINT`; native Mistral uses
`MISTRAL_API_KEY`; native Cohere uses `CO_API_KEY`. It replaces each cassette
atomically only after a successful agent tool loop. Authentication headers are
never copied; provider-specific URL filters replace the real Bedrock region and
Azure resource endpoint.

The files follow Cassetter v1 YAML. JSON bodies are nested YAML values, streamed
responses use literal text blocks, and binary bodies are explicit. Headers are
omitted by default. Review request and response content before committing a new
cassette. Replay compares JSON request bodies structurally, so harmless object
whitespace and key formatting introduced by YAML serialization do not cause a
mismatch; non-JSON bodies remain byte-exact.

File recordings use the same request filters during recording and replay.
Multipart boundaries are normalized, uploaded bytes are replaced with an
explicit redaction marker, and provider-issued upload URLs are mapped to stable
fixture URLs. Response headers remain opt-in: an allowlist can retain a safe
value or replace it, while sensitive header names are rejected even when a rule
selects them. The live caller still receives the original provider header; only
the recorded copy is sanitized.

## Coverage policy

The gate is 100% line coverage for every executable Zig line under `src/`,
excluding Zig's standard library, generated files, two type-declaration lines,
and the timeout sleep expression that LLVM/kcov cannot trace inside Zig's
concurrent I/O task. Alias-only standalone provider modules have no executable
lines; the downstream consumer builds compile those instead. Coverage comes
primarily from public, high-level behavior; a line-only unit test should exist
only when a high-level scenario would obscure the behavior being tested.

Run `./scripts/coverage` on Linux. It compiles with LLVM debug information,
runs unit, cassette, agent, real-transport, CLI-success, and CLI-error paths,
merges their reports, checks that every source file is represented, and fails
unless the final line rate is exactly 100%. CI runs the same command. macOS
`kcov` requires extra debugger signing, so coverage remains a Linux-only gate.

`tests/mcp_conformance.zig` keeps the MCP `2026-07-28` method and compatibility
inventories executable. The `src/mcp.zig` tests cover nested schemas, malformed
envelopes, allocation failures, stdio/SSE ordering, capability guards,
pagination cycles, and lossless extension JSON. The human-readable companion is
[MCP conformance](mcp-conformance.md).

Official interoperability inputs are test assets, never production modules.
`tests/mcp/upstreams.yaml` pins the official conformance framework and reference
servers by commit. The matrix deliberately includes both stdio and Streamable
HTTP and is validated by the ordinary test suite before live jobs consume it.
Recorded wire evidence uses the Cassetter-style YAML codec in
`tests/mcp/transcripts.zig`. One interaction preserves a JSON-RPC request, the
ordered notifications observed while it was active, and its response. Replay
is transport-neutral; the transcript metadata records whether the evidence was
captured from stdio or HTTP.

`zig build mcp-interop` is the opt-in recorder. It expects an official server
checkout at the revision named in `tests/mcp/upstreams.yaml` and atomically
replaces the requested fixture only after discovery and the tool, resource,
and prompt inventories all succeed:

```console
zig build mcp-interop -- stdio <server> <revision> <fixture.yaml> <command> [args...]
zig build mcp-interop -- http <server> <revision> <fixture.yaml> <endpoint>
```

The committed TypeScript todos recordings prove identical behavior over stdio
and HTTP. The Python everything-server recording adds a second official SDK
and a much broader schema surface. Ordinary CI replays all three without a
network connection or upstream toolchain.

`./scripts/mcp-interop typescript <checkout>` and
`./scripts/mcp-interop python <checkout>` verify that a prepared checkout is at
the manifest pin, exercise its live server, and compare fresh transcripts with
the committed fixtures. `.github/workflows/mcp-interop.yml` runs those checks
only through `workflow_dispatch`; normal CI remains deterministic and
network-free beyond dependency installation.

The same manual workflow checks out the pinned official conformance framework
and runs its complete `2026-07-28` client requirements against
`zigai-mcp-conformance-client`. This adapter is test-only and deliberately
thin: it translates runner scenarios into public ZigAI calls instead of adding
conformance hooks to the library. `tests/mcp/conformance-baseline.yaml` names
every scenario that is not supported yet. The runner fails for a new
regression, an unlisted failure, or a stale baseline entry that has started to
pass, so the file doubles as an executable interoperability backlog.

## Fuzzing

ZigAI fuzzes every untrusted parser family: history and deferred state, JSON
Schema output, JSON/YAML agent specifications, buffered and streaming provider
responses, Cassetter YAML, MCP JSON-RPC and SSE framing, CLI tool manifests,
and HTTP retry metadata.

Run a bounded local campaign with an iteration limit:

```console
./scripts/fuzz 1000
```

Use a larger suffix for longer runs, for example `10K` or `1M`. Each target
also carries a small valid corpus, so the ordinary test suite executes stable
parser smoke cases without fuzz instrumentation. Inputs are capped at 16 KiB;
the production parsers apply their stricter documented limits after that.

The pinned Zig 0.16.0 test runner requires error-return tracing to be disabled
in fuzz mode. The script applies that workaround only to the fuzz compilation;
normal checks retain the default tracing behavior. CI runs a 1,000-iteration
bounded campaign on macOS for every push and pull request. Zig 0.16.0 currently
emits an empty fuzzer coverage record on Linux before the targets start, while
the same targets run normally on macOS; Linux still runs the corpus smoke tests
and the 100% line-coverage gate.

## Stress and allocation failures

The bounded stress suite exercises the public API under sustained load:

- 128-step tool loops and 32-call parallel tool batches;
- cancellation racing an active model request, with work drained before return;
- repeated provider connection failures followed by successful retries;
- 1,024-message histories and 2,048 streaming deltas;
- every allocation failure in an agent tool loop;
- 512 HTTP client init/deinit cycles; and
- 128 real HTTP requests through one client while the fixture closes every
  connection, forcing connection recovery.

Run both safety-oriented build modes locally:

```console
./scripts/stress
```

Run only one mode while iterating:

```console
./scripts/stress Debug
./scripts/stress ReleaseSafe
```

The suite is deliberately bounded and deterministic, so it is suitable for
every push. CI runs it in both modes on Linux and macOS. Longer fuzz campaigns
and live-provider tests remain opt-in because their duration or external state
is not deterministic.

## Pricing snapshots

`zigai.pricing.builtin_version` identifies the checked-in standard-price
snapshot. Before changing it, verify every edited row against the provider URLs
in `pricing.builtin_sources`, update the version date, and keep a focused unit
test for each first-party provider. Pricing tests never call a live billing API.

## Model compatibility snapshot

`data/model_catalog.json` is the only hand-edited model snapshot source.
`src/model_catalog_snapshot.zig` is generated and must never be edited by hand.

For each update:

1. Verify IDs, aliases, limits, lifecycle, and capabilities against the linked
   primary provider page. Record only capabilities supported by both the model
   and ZigAI's adapter.
2. Keep providers, model IDs, aliases, and enum lists in deterministic order;
   advance `updated_at` without changing `version` unless the source schema
   changes.
3. Run `zig build update-model-catalog` and review both the JSON source and
   generated Zig diff.
4. Run `zig build check-model-catalog`, `zig build test`, and exact coverage.

The normal `zig build check` target runs the drift checker. It parses the
source with unknown fields rejected, validates the provider-neutral catalog,
and compares generated bytes, so CI cannot accept a stale or hand-edited
snapshot.

## Provider extension settings

Provider request tests inspect every portable setting at the wire boundary.
Extra-body fixtures must be small inline JSON objects without credentials.
Tests cover provider-tag mismatches, malformed or non-object JSON, attempts to
shadow adapter-owned fields, reserved headers, and CR/LF injection.
