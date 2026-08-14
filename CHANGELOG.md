# Release notes

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
