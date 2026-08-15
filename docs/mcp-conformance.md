# MCP 2026-07-28 conformance

ZigAI implements the modern, stateless MCP `2026-07-28` core protocol. The
matrix follows the authoritative
[schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts),
[release notes](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
and [versioning rules](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).
The executable method inventory lives in `tests/mcp_conformance.zig`.

## Messages

| Flow | Methods | ZigAI API |
| --- | --- | --- |
| Client requests | `server/discover`, completion, prompts, resources, subscriptions, and tools | Typed request values and `Client` helpers, plus JSON escape hatches for extensions |
| Client notifications | `notifications/cancelled` | `cancel` or `notify` |
| Server notifications | cancellation, progress, logging, resource updates, list changes, and subscription acknowledgement | Typed `Notification` encoding; borrowed JSON through `EventSink` |
| MRTR input | elicitation, roots, and sampling | Typed `InputRequest` and `InputResponse` builders through `InputHandler`, followed by a validated retry |

Roots, Sampling, and Logging are deprecated compatibility paths in this
revision. They remain supported without being promoted into the main agent
API.

## Validation matrix

| Area | Enforced behavior |
| --- | --- |
| JSON-RPC | Version, request IDs, matching response IDs, result/error exclusivity, error shape, notification no-response behavior |
| Request metadata | Per-request protocol version, client identity, capabilities, progress token, log level, and `_meta` key grammar |
| Capabilities | Every known client and server shape; unknown fields remain intact |
| Results | `complete` and `input_required`, every core nested result, cache metadata, content blocks, icons, and annotations |
| MRTR | Elicitation schemas/results, roots, sampling messages/tools, declared client capabilities, and bounded retries |
| Pagination | Cursor encoding for all list methods; tool discovery rejects cursor cycles and honors `max_pages` |
| Subscriptions | Typed filters, correlation IDs, acknowledgement-first ordering, requested updates, SSE, stdio, cancellation, and bounded stateless re-establishment |
| HTTP | Incremental bounded request-scoped SSE, buffered fallback, concurrent requests, routing and tool-argument headers, reserved MCP error status mappings, response limits, URL policy, OAuth discovery, bounded Bearer refresh/step-up, and server deployment guards |
| Stdio | Bounded newline framing, serialized admission, explicit stderr policy, graceful EOF shutdown, forced escalation, reap, and modern server-request rejection |
| Extensions | Mandatory prefixed identifiers, object settings, lossless unknown JSON, generic methods, and `extensionSettings` |
| Compatibility | Modern/legacy classification for stdio and HTTP; actionable rejection of legacy `initialize` |

Capability sets are open by specification. ZigAI validates standardized fields
and preserves everything else. Applications decide an extension's semantics
and fallback policy.

## Compatibility boundary

ZigAI is a modern-only implementation. It never silently opens an initialization
session or falls back to deprecated HTTP+SSE.

`classifyStdioCompatibility` and `classifyHttpCompatibility` implement the
official era probes for applications that want to build a dual-era adapter.
They return `modern`, `legacy`, or `indeterminate`; they do not mutate client
state or initiate fallback.

The current [authoritative schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts)
removes `ping`, `logging/setLevel`, and `resources/subscribe`/`unsubscribe`.
ZigAI therefore does not expose those RPCs in the modern method inventory.
Typed `RequestOptions.metadata.log_level` implements the per-request logging
opt-in, and `SubscriptionFilter` plus `subscriptions/listen` implement resource
and list updates. Roots, Sampling, and Logging remain deprecated compatibility
capabilities exactly where the schema retains them.

## Limits and ownership

- Returned request, discovery, result, and extension-setting JSON is owned by
  the caller.
- Event JSON is borrowed for the duration of the callback.
- `max_round_trips` bounds MRTR retries; `max_pages` bounds tool discovery.
- MCP documents use the shared bounded JSON parser and message byte limit.
- Optional HTTP authorization follows the `2026-07-28` OAuth profile: RFC 9728
  protected-resource discovery, RFC 8414/OIDC issuer discovery, exact RFC 9207
  issuer checks, `S256` PKCE capability, RFC 8707 resource indicators, and
  bounded 401/403 retries. OAuth remains disabled unless policy callbacks are
  configured; stdio credentials remain an environment/application concern.
- Protected HTTP servers can reject cleartext, duplicate or untrusted Origin
  headers, and Host mismatches before parsing JSON-RPC. Bearer validators receive
  the token, canonical audience, method, and params; MCP handlers never receive
  the credential.
