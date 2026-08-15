# MCP 2026-07-28 conformance

This matrix follows the authoritative
[MCP 2026-07-28 schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts)
and [release notes](https://modelcontextprotocol.io/specification/2026-07-28/changelog).
The executable inventory lives in `tests/mcp_conformance.zig`.

## Message surface

| Flow | Methods | ZigAI path |
| --- | --- | --- |
| Client requests | `server/discover`, `completion/complete`, `prompts/get`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`, `subscriptions/listen`, `tools/call`, `tools/list` | Typed client helpers; generic `Client.request` remains available for extensions. |
| Client notifications | `notifications/cancelled` | Typed `Client.cancel` plus generic `Client.notify`. |
| Server notifications | `notifications/cancelled`, `notifications/progress`, `notifications/message`, `notifications/resources/updated`, list-changed notifications for resources, tools, and prompts, and `notifications/subscriptions/acknowledged` | Borrowed JSON through request or subscription `EventSink`. |
| MRTR input requests | `elicitation/create`, deprecated `roots/list`, deprecated `sampling/createMessage` | Generic `InputHandler`; responses are inserted into a retry of the original request. |

Roots, Sampling, and Logging remain compatibility paths but are deprecated in
this protocol revision. New ZigAI APIs should not make them more prominent.

## Capability surface

| Side | Active capabilities | Deprecated capabilities | Open namespaces |
| --- | --- | --- | --- |
| Client | elicitation form/URL modes | roots, sampling context/tools | `experimental`, `extensions` |
| Server | completions, prompts/list-changed, resources/subscription/list-changed, tools/list-changed | logging | `experimental`, `extensions` |

Client and server capability objects are open by specification. ZigAI must
preserve unknown prefixed extensions while validating every capability it
advertises and every method-specific result it consumes or emits.

## Remaining executable matrix

Implemented rows:

- common `complete` and `input_required` result validation, with legacy
  omission interpreted as `complete`;
- required `ttlMs` and `cacheScope` validation on every cacheable core result;
- top-level method-specific result shapes for every typed client helper; and
- state-only and input-request MRTR retries.

The following rows are intentionally not marked complete yet:

- complete nested request, result, and notification shapes;
- pagination cursors for tools, prompts, resources, and resource templates;
- all JSON-RPC and MCP error envelopes and HTTP status mappings;
- unknown extension preservation and prefixed extension negotiation;
- modern, legacy, and dual-era compatibility outcomes for stdio and HTTP; and
- advertised-capability guards for requests, MRTR input, and notifications.

Each row will become an executable conformance case before this checklist item
is complete.
