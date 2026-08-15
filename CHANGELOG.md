# Release notes

## Unreleased

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
- Add bounded, arena-owned model discovery for OpenAI, Anthropic, Google, and
  every OpenAI-compatible provider through the provider operations interface.
  Paginated APIs have explicit page and model limits, identifiers are
  normalized for client construction, and raw provider metadata is preserved.
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
