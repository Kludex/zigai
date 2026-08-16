# Release notes

## Unreleased

- Align agent, model-request, and tool span names with the OpenTelemetry GenAI
  conventions; add explicit parent trace contexts, opt-in raw or callback-
  redacted prompt capture, UTF-8-safe content bounds, exporter attribute
  limits, and fail-open isolation for all telemetry processing failures.
- Add correlated OpenTelemetry lifecycle events for every agent hook signal,
  including retry, stream, deferred, and enqueued-message phases. Split tool
  validation from execution spans and add output-validation spans and metrics.
- Add OpenTelemetry MCP client/server spans and duration metrics with W3C
  `traceparent` propagation in request and notification `_meta`, semantic
  method/protocol/transport/session/target attributes, and bounded task IDs.
- Add a thread-safe bounded telemetry exporter with owned signals, three
  explicit overflow policies, serialized flush and shutdown, fail-open or
  fail-closed downstream handling, and reasoned dropped-signal counters.
- Add an unauthenticated Ollama provider, explicit loopback policy, tagged
  model-family profiles, and a compiled local example.
- Add a named Crusoe Serverless Inference provider with vendor-qualified model
  profiles, structured-output capabilities, and a compiled example.
- Add a Snowflake Cortex provider with validated account-scoped API roots,
  family-specific Chat Completions profiles, and a compiled example.
- Add a named Z.AI provider with GLM profiles, conservative pre-I/O capability
  checks, and a compiled example.
- Add a compiled custom-provider example with explicit endpoint,
  authentication, identity, model-profile, and fail-closed validation rules.
- Add typed Snowflake Cortex Claude reasoning controls for buffered and
  streaming requests, with exclusive effort/token modes and the required
  temperature invariant enforced before I/O.
- Add native Z.AI thinking controls and preserve `reasoning_content` through
  buffered, streaming, and tool-turn history without widening the generic
  OpenAI-compatible surface.
- Add a borrowed, provider-neutral model catalog with exact canonical and
  alias resolution, typed limits and deprecations, trusted capability profiles,
  collision detection, and validated replacement links.
- Add an owned discovery-merge index that canonicalizes aliases while keeping
  provider metadata separate from trusted catalog profiles, limits, and
  deprecations.
- Add a versioned built-in model compatibility snapshot with primary-source
  provenance and an offline deterministic update/check tool enforced by the
  normal build check.
- Replace cassette-recorder filter tables with one typed recording manifest
  shared by replay, add stable recording IDs and scenario filters, resolve only
  selected credentials, and list credential readiness without exposing values.
- Add real buffered text-response cassettes and replay coverage for the full
  24-model OpenAI, Anthropic, and Google first-party matrix.
- Add 48 real streamed-text and streamed-function-tool cassettes for the same
  first-party matrix, backed by shared provider-neutral event invariants and
  JSON-semantic request replay. Preserve OpenAI function identity when argument
  completion omits the name, and accept Gemini role-only terminal chunks.
- Add real native structured-output and high-effort thinking cassettes for one
  representative OpenAI, Anthropic, and Google capability profile. Assert each
  provider's wire controls, typed output, neutral reasoning usage, and
  Anthropic thinking events, signatures, and history. Preserve Anthropic
  `thinking_tokens` in buffered and streamed usage.
- Add deterministic first-party provider-error cassettes with typed fixture
  provenance. OpenAI, Anthropic, and Google now replay rate-limit recovery and
  retry hints, server-error exhaustion, malformed success payloads, and safe
  bounded error observation without attempting to manufacture live failures.
- Make native-tool and rich-media cassette replay semantic. OpenAI now retains
  web-search calls and URL citations, Anthropic retains server-tool calls,
  results, and request counters, Google retains grounding metadata, and the
  native matrix asserts provider details, references, and normalized usage.
  First-party image replay now requires the expected color instead of merely
  accepting non-empty output.
- Add real streamed-text and complete function-tool cassettes for all eleven
  configured OpenAI-compatible providers. Recording and replay use the shared
  typed scenario manifest while retaining provider-specific models, endpoints,
  authentication, and response extensions.
- Replay one deterministic Chat Completions failure contract through all eleven
  named compatible providers, covering rate-limit recovery metadata, retry
  exhaustion, malformed success, bounded observations, and provider identity
  without duplicating protocol-equivalent fixtures.
- Add real buffered and applicable streamed-text recordings for Bedrock
  Converse, Azure Responses, Mistral Conversations, and Cohere v2 Chat, plus a
  complete Mistral Conversations function-tool loop. Stop replaying Mistral's
  provider-generated entry IDs because client inputs cannot specify them.
- Add deterministic failure contracts for Bedrock Converse, Azure Responses,
  Mistral Conversations, and Cohere v2 Chat. Each native request and response
  codec now replays rate-limit recovery, retry exhaustion, malformed success,
  and bounded provider-error observation.
- Add a repository-wide cassette audit to the normal test and check gates. It
  enforces manifest completeness, unique live fixtures and IDs, secret-safe
  headers and values, provider endpoint and multipart normalization, and an
  idempotent Cassetter YAML round trip across every checked-in fixture.
- Add backend-neutral structured diagnostics for agent lifecycle events with
  level filtering, bounded keys/values and attribute counts, fail-open policy,
  opt-in content capture, and exact-value redaction before truncation.
- Add eval execution options with repeated case runs, independent task and
  evaluator retry policies, stable case/repetition/attempt identities, recorded
  attempt counts, retry classification/backoff callbacks, and lifecycle events.
- Add bounded concurrent eval execution through `std.Io`, with stable
  source-order reports, joined failures, shared allocator protection, and an
  explicit thread-safety contract for application callbacks.
- Add report evaluators with arena-owned aggregate assertions and scalar
  analyses, plus report, source-case, and finite-score statistical summaries
  across repeated runs.
- Add span-based evaluators over the production OpenTelemetry shape. Per-case
  exporter tees deep-copy spans into reports, forward application telemetry,
  share evaluator retries, and fail before model work when telemetry is absent.
- Add versioned eval dataset and report documents in strict JSON and readable
  Cassetter-style YAML. Dataset evaluator names resolve through an explicit
  registry, reports retain usage, analyses, and typed spans, and trace IDs use
  stable hexadecimal text.
- Add deterministic baseline/candidate eval comparisons over stable case/run
  identities, evaluator names, report analyses, pass rates, and signed usage
  deltas, with regression classification and versioned CI JSON output.

- Define a borrowed provider operations interface for authenticated requests,
  base URL policy, model discovery, file APIs, model profile lookup, and
  capability overrides, with explicit arena ownership for returned data.
- Add a reusable authenticated HTTP provider that owns credential rendering,
  configured headers, relative endpoint construction, streaming delegation,
  non-inference operation dispatch, and credential-safe provider error
  reporting. Reject malformed credentials, header injection, ambiguous API
  roots, and duplicate header ownership before transport I/O.
- Split OpenAI provider configuration from the Responses API model adapter.
  `openai.Provider` now owns credentials, the API root, configured headers,
  request policy, transport, and profile overrides; `openai.Client` borrows its
  provider and owns only model settings and wire encoding.
- Split Anthropic provider configuration from the Messages API model adapter.
  `anthropic.Provider` owns the API key header and shared HTTP policy, while
  `anthropic.Client` owns the Messages version, conditional Files API beta,
  model limits, and request/response encoding.
- Split Google Generative Language provider configuration from the Gemini
  GenerateContent adapter. `google.Provider` owns the API key header and HTTP
  policy while preserving the established `gcp.gen_ai` history and file-owner
  identity.
- Split OpenAI-compatible provider configuration from the Chat Completions
  adapter. Generic and named compatible modules now expose matching
  provider/client pairs; credentials, API roots, provider identity, headers,
  request policy, transport, authentication style, and profile callbacks stay
  on the provider side of the boundary.
- Add centralized, provider-specific model profiles for every named
  OpenAI-compatible module. Upstream-family resolution uses a fail-closed
  unknown fallback, application lookups take precedence over built-ins, and
  application overrides run last so unsupported tools, settings, and content
  fail before transport.
- Add a native Amazon Bedrock Runtime provider and buffered Converse adapter.
  It supports regional bearer authentication, encoded model identifiers,
  instructions and text history, function-tool loops, JSON Schema output for
  recognized models, common inference settings, service tiers, tagged Bedrock
  extensions, reasoning replay, normalized finish reasons, and cache-aware
  usage. Mantle remains an explicitly named OpenAI-compatible adapter; binary
  ConverseStream support remains separate from line-oriented streaming.
- Add an explicit Azure OpenAI `ResponsesClient` on the existing Azure provider
  state. The GA v1 endpoint reuses the native OpenAI Responses codec while Azure
  retains ownership of its resource API root, `api-key` authentication, and
  deployment profiles; `ChatClient` and the legacy `Client` alias remain for
  Chat Completions deployments.
- Add a first-class xAI Responses provider and client with a separate explicit
  Chat Completions compatibility pair. The Responses dialect models filtered
  web search, X search, code execution, collection search, and keyed remote MCP
  servers as typed provider-managed tools, with bounded configuration checks
  and an isolated `.xai` extension body.
- Add a native Mistral Conversations provider and client while preserving the
  existing Chat Completions aliases. The native adapter supports buffered and
  streamed entries, local functions, managed web search and code execution,
  Mistral-only premium search, image generation, document libraries and
  connectors, structured output, normalized connector usage, and isolated
  `.mistral` extensions. Ordinary models remain stateless; stored start,
  append, native history, and delete live behind an explicit `Session` API.
- Record and replay a redacted real `mistral-small-latest` Conversations web
  search, including native execution details, tool references, and connector
  token counters.
- Add a native Cohere v2 Chat provider and client while preserving the existing
  Compatibility API aliases. The native adapter supports buffered and streamed
  messages, thinking, tool plans and calls, strict tools, structured output,
  normalized usage, citations, log probabilities, and isolated `.cohere`
  extensions. A redacted real Command A tool loop verifies replay and citations.
- Add typed OpenRouter provider routing without forking its Chat Completions
  wire codec. The client supports endpoint ordering and filters, fallback and
  parameter policy, ZDR and data-collection controls, quantization, performance
  sorting and thresholds, price ceilings, isolated `.openrouter` extensions,
  and opt-in structured router metadata for buffered and streamed responses.
- Add a Google Cloud Vertex AI provider that reuses the Gemini GenerateContent
  codec without sharing Google AI Studio credentials, URLs, discovery, or file
  operations. It owns OAuth bearer authentication and validated project,
  location, publisher, and model resource paths, with global or regional API
  roots and buffered or SSE streaming support.
- Record and replay a redacted real Azure OpenAI `gpt-4o` Responses function
  tool loop, normalizing the resource endpoint and omitting authentication.
- Record and replay a redacted real Claude Sonnet 4.6 Converse tool loop. The
  recorder strips authentication, normalizes the AWS region, and verifies both
  the tool request and final response through a real `Agent`.
- Add bounded, arena-owned model discovery for OpenAI, Anthropic, Google, and
  every OpenAI-compatible provider through the provider operations interface.
  Paginated APIs have explicit page and model limits, identifiers are
  normalized for client construction, raw provider metadata is preserved, and
  returned strings never borrow the released HTTP response body.
- Establish the concrete file-lifecycle foundation with authenticated `DELETE`
  transport support, provider-qualified file descriptors, reusable
  `UploadedFile` handles, distinct inspect and download operations, arena-owned
  downloaded bytes, and fail-closed owner validation before and after dispatch.
- Implement authenticated OpenAI and Anthropic file upload, metadata
  inspection, download, and acknowledged deletion in a shared provider-files
  layer. Add collision-safe multipart framing, encoded resource paths,
  provider-specific purpose and beta-header behavior, configurable upload
  limits, bounded response parsing, and exhaustive allocation-failure tests.
- Implement Google resumable file upload, inspection, reuse, and deletion with
  a distinct upload API root, bounded response-header capture, exact-origin
  validation for provider-issued session URLs, URI-backed file handles, and a
  2 GB default upload limit. Download remains explicitly unsupported because
  the Gemini Files API does not expose stored file content.
- Add test-only cassette request normalization and opt-in safe response-header
  capture. Recording and replay now share URL and body filters, multipart file
  content and boundaries can be deterministically redacted, resumable-upload
  URLs can be replaced, and sensitive headers remain impossible to serialize.
- Record redacted real file lifecycles for OpenAI, Anthropic, and Google.
  Provider descriptors now expose Anthropic's `downloadable` flag, fixtures
  exercise only each provider's safe operations, and recorder cleanup deletes
  temporary files even when a later lifecycle operation fails.
- Pin the official MCP `2026-07-28` conformance framework and TypeScript and
  Python reference servers in a validated test-only interoperability matrix.
- Add a test-only Cassetter-style YAML format that replays ordered MCP
  requests, notifications, and responses without adding fixture code to the
  production library.
- Add atomic live transcript recording and deterministic stdio/HTTP replays
  captured from pinned official TypeScript and Python MCP reference servers.
- Add a manually dispatched, immutable-action MCP interoperability workflow
  that rebuilds pinned official SDKs and fails on live transcript drift.
- Run the pinned official MCP `2026-07-28` client requirements through a thin
  test-only ZigAI adapter, with unsupported scenarios tracked by a strict
  expected-failure baseline that rejects stale entries.
- Allow bounded concurrent MCP Streamable HTTP requests with configurable
  in-flight backpressure and request-local authorization retries.
- Add a standalone bounded SSE parser with standard multi-line data framing
  and use it for incremental MCP event delivery, response correlation,
  streamed direct JSON, and subscription validation, with buffered fallback.
- Add opt-in bounded stateless subscription re-establishment with explicit
  failure classification, delay, cancellation, deadline, and at-least-once
  event semantics.
- Add explicit stdio stderr policy, bounded request admission, graceful
  stdin-close shutdown, deadline polling, force-kill escalation, and child
  reaping.
- Add bounded, arena-owned task result parsing, typed client helpers, extension
  negotiation, task-ID routing, validated task status subscriptions, and
  bounded polling with deduplicated input handling and cooperative
  cancellation for the current `io.modelcontextprotocol/tasks` extension.
  Add pluggable durable task state, an atomic owner-only file store,
  crash-safe pending-input replay, automatic task tracking, and ordered restart
  resumption (SEP-2663).
- Start the clean MCP primitives layer with typed, borrowed client and server
  capability documents, validated experimental/extension objects, prefixed
  extension identifiers, typed subscription filters and notifications,
  prompt/completion requests, typed MRTR input dispatch, correlation and
  response builders for elicitation/roots/sampling, correlation and numeric
  guards, integer-or-string cancellation IDs, deterministic serialization, and
  typed progress/log-level request metadata, plus raw JSON escape hatches for
  future protocol fields. Removed 2026 RPCs such as ping and legacy resource
  subscriptions are deliberately not reintroduced.
- Add MCP `2026-07-28` HTTP authorization and deployment security with bounded
  RFC 9728/RFC 8414/OIDC discovery, exact issuer and resource binding, PKCE
  checks, owned token callbacks, bounded refresh and scope step-up, pre-dispatch
  TLS/Origin/Host enforcement, owned challenges, redirect isolation, redaction,
  allocation-failure tests, and fuzzing.
- Complete the MCP `2026-07-28` conformance matrix with strict nested message
  and metadata validation, stateless capability guards, MRTR validation,
  filtered acknowledgement-first subscriptions, bounded cycle-safe tool
  pagination, exact error envelopes, compatibility-era classification, and
  lossless prefixed extensions.
- Add strict, bounded JSON/YAML agent specifications with data-only parsing,
  deny-by-default interpolation and secret references, secret-free provider
  validation, application-owned model and capability resolution, transitive
  capability loading, deterministic cleanup, fuzzing, and a network-free
  validator CLI.
- Add bounded on-demand capability discovery and atomic dependency-first
  loading, conflict diagnostics, history/run-end unload policy, fixed scoped
  composition, callback snapshots, and portable load replay across every
  provider adapter.
- Add a separate ordered tool-policy pipeline with preparation, transforming
  argument and return validation, history-aware approval, call short-circuiting,
  shared per-tool retries, persisted decisions, sequential-only scheduling,
  versioned resolved-call pause state, and opt-in provider-visible return
  schemas.
- Separate agent output strategies from provider wire formats, with native
  structured unions, prompted output with JSON-mode fallback, mandatory local
  validation, bounded preparation, and explicit run-arena ownership.
- Add tool-mediated output unions, scalar-schema wrapping, output functions
  with explicit retry values, selected-choice names, collision checks, and
  early, graceful, or exhaustive end strategies.
- Validate a documented fail-closed JSON Schema Draft 2020-12 subset, including
  local definitions, composition, conditionals, object dependencies, tuple and
  containment arrays, Unicode lengths, numeric assertions, and schema
  preflight before provider requests.
- Add ordered output validators with run context, selected-choice awareness,
  transformation, explicit safe retries, capability composition, controlled
  execution, post-transformation schema checks, and lifecycle events.
- Add accumulated partial-output events for text and structured streams, with
  bounded incomplete-JSON repair, monotonic schema checks, partial-aware output
  functions and validators, tool-output selection, and borrowed snapshots.
- Complete provider-neutral model settings with sampling, penalties,
  log-probabilities, tool and parallel-call policy, thinking budgets, service
  tiers, truncation, safe request headers, profile preflight, and tagged bounded
  provider-extension objects that cannot shadow adapter-owned fields.
- Add normalized request/run usage for caching, reasoning, audio, native
  counters, request/tool counts, latency, exact cost, cost limits, and opt-in
  estimation from an explicit versioned first-party price snapshot.
- Add a thread-safe, one-run pending-message queue with deep-copy ownership,
  deterministic batch ordering, stream events, pause-state persistence, and
  atomic final/cancellation closure.
- Replace flat streaming deltas with stable indexed part start/delta/end
  lifecycles, complete thinking/media/native-tool delta types, streamed
  deferred pause/resume events, and one validated final-result event carrying
  a structured JSON snapshot when applicable.
- Replace provider-detail JSON strings with owned structured JSON objects,
  preserving unknown fields across copies and history serialization while
  making malformed provider JSON unrepresentable.
- Add a separate PydanticAI `2.31.0` stable-v2 JSON codec with bounded parsing,
  lossless arbitrary JSON values and number lexemes, an arena-owned result,
  strict message-role validation, and an upstream-generated golden fixture.
- Complete provider-neutral message vocabulary aligned with PydanticAI,
  including structured instructions, part provenance, video, uploaded files,
  cache points, rich tool outcomes, compaction, speech, native tools, tool
  search, capability loading, and tool-availability changes, with explicit
  rejection of provider-owned data that an adapter cannot replay losslessly.
- Bounded fuzz targets and seed corpora for persisted state, schemas, provider
  decoders, cassette YAML, MCP framing, CLI manifests, and HTTP metadata.
- Cross-platform Debug and ReleaseSafe stress suites for long and parallel tool
  runs, cancellation, reconnects, large histories, partial streams, allocation
  failures, and repeated client lifecycles.
- Separate provider-neutral conversation types into the public `messages`
  module while preserving the existing root and `model` aliases.
- Allocation-free outbound URL policy with HTTPS-by-default validation,
  local-network protection, host allowlists, and conventional header redaction.
- Standard HTTP transport enforcement for outbound URL policy and explicit,
  never-followed redirect handling, with local endpoint opt-in for the CLI.
- Agent, provider, rich-content, and MCP endpoint enforcement of the same URL
  policy, including validation before custom transport callbacks.
- Mandatory suppression of configured API keys from provider-error observer
  bodies, messages, and codes, with an explicit redaction indicator.
- Configurable post-decompression HTTP body and streaming-line limits with
  stable oversized-response errors.
- Shared pre-allocation JSON validation with documented limits for history,
  deferred state, providers, tools, MCP, schemas, and CLI manifests.
- Bounded local tool execution with global and per-tool concurrency, queue,
  timeout, result, follow-up, and cooperative cancellation policies.
- One monotonic run deadline across requests, retries, streaming, callbacks,
  local and MCP tools, and deferred resume, with losing tasks drained.
- Full-jitter retry backoff, cumulative delay budgets, HTTP-date
  `Retry-After`, bounded provider request IDs, stable connection/decode
  categories, request correlation, and opt-in compatible-provider idempotency.
- Preflight context budgets for prompt, tool, schema, media, and estimated
  tokens, with output reservation and controlled history compaction hooks.
- Provider error bodies hidden by default with explicit bounded capture,
  independently capped messages and codes, and end-to-end policy propagation.
- Documented stable error taxonomy across agents, providers, transports, data
  boundaries, and MCP, while preserving application callback errors unchanged.

## 0.1.0 — 2026-08-14

The first ZigAI release provides a provider-neutral agent loop for Zig 0.16.0.

- OpenAI Responses, Anthropic Messages, Google Gemini, and OpenAI-compatible
  provider clients.
- Buffered and streaming runs with tools, typed output, instructions, rich
  content, message history, lifecycle hooks, and reusable capabilities.
- Request/response message envelopes with distinct part types, lossless
  version-2 history, and automatic migration from role-based version 1.
- Dynamic toolsets, MCP clients, deferred approvals, model routing, retries,
  cancellation, limits, and OpenTelemetry integration.
- Dataset evaluations with deterministic and model-graded evaluators.
- A 24-model real-provider cassette matrix plus deterministic CLI, consumer,
  transport, and 100% executable-line coverage gates.

See [Public API and ownership](docs/api.md) for the supported API contract.
