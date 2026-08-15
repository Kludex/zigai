# Release notes

## Unreleased

- Separate provider-neutral conversation types into the public `messages`
  module while preserving the existing root and `model` aliases.
- Allocation-free outbound URL policy with HTTPS-by-default validation,
  local-network protection, host allowlists, and conventional header redaction.
- Standard HTTP transport enforcement for outbound URL policy and explicit,
  never-followed redirect handling, with local endpoint opt-in for the CLI.
- Agent, provider, rich-content, and MCP endpoint enforcement of the same URL
  policy, including validation before custom transport callbacks.
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
