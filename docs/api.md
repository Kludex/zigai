# Public API and ownership

Named framework failures are listed in the [error reference](errors.md).
Application callback, allocator, runtime, and custom transport errors propagate
alongside those named errors without wrapping.

ZigAI's supported API starts at `@import("zigai")`. Prefer its short aliases
for agent and model types, and use the named modules for larger subsystems:

```zig
const zigai = @import("zigai");

const Agent = zigai.Agent;
const Client = zigai.providers.openai.Client;
const Dataset = zigai.evals.Dataset;
```

## Supported surface

The root exposes the agent loop, its configuration and result types, message
and tool types, model settings and usage, streaming events, provider errors,
history helpers, telemetry, MCP, evaluation, and model-routing modules.

Reusable history is typed as `Message`, a union of `RequestMessage` and
`ResponseMessage`. Construct prompts and tool returns with `RequestPart`;
model implementations return `ResponsePart`. `PromptPart` is the short alias
for rich `UserContent` accepted by `RunOptions.prompt_parts`. `Part` remains a
compatibility alias for `ResponsePart`.

The vocabulary follows PydanticAI's message model while staying idiomatic in
Zig:

| Area | Types |
| --- | --- |
| Prompts | system, user, retry, instruction, speech, and tool-availability parts |
| User content | text, tagged text, image, audio, video, document, binary, uploaded file, and cache point |
| Tools | function, provider-native, tool-search, and capability-load calls and returns |
| Model output | text, thinking, compaction, files, speech, and tool parts |

`zigai.tool.Policy` is the orchestration extension point for function tools.
Its typed events cover preparation, argument validation, dynamic approval,
pre-call behavior, and return validation. `Agent.tool_policies` run first;
capability policies follow in capability order. Argument and return policies
may transform values or request a retry from the tool's own budget. Dynamic
approval is evaluated after valid arguments and persisted across pause/resume.
`Tool.sequential` provides scheduler-wide exclusivity. Return schemas are
local unless `return_schema_visibility` opts into provider descriptions.

## Capabilities

`Capability` is a borrowed implementation bundle. It can contribute local and
provider-managed tools, toolsets, instructions, lifecycle hooks, tool policies,
history processors, output validators, model settings, and a model selector.
Anonymous capabilities are eager-only. A capability needs a stable `id` when
it is on demand or declares dependencies or conflicts.

Set `loading = .on_demand` to keep the bundle out of the first provider
request. ZigAI adds a catalog instruction and a sequential `load_capability`
function instead. A successful call resolves dependencies in declaration
order, returns their instructions in dependency-first order, and activates all
contributions together before the next model request. OpenAI Responses,
OpenAI-compatible Chat Completions, Anthropic Messages, and Google Gemini replay
typed capability-load history through their ordinary function-call protocols.

Loads are atomic: a conflict, callback failure, or allocation failure cannot
leave a partial bundle active. Structural errors are detected before the first
model request. `CapabilityRegistry` exposes the same bounded validation and
dependency planning without executing an agent; `LoadResolution` owns its
arena and must be deinitialized.

`CapabilityUnloadPolicy.history` reconstructs successful loads from canonical
history. `.run_end` forgets them between independent invocations while keeping
them active through serialized pause/resume. Unsuccessful load results never
restore state.

Capabilities compose in fixed scope order: inherited, agent, run, nested, then
subagent. Direct `Agent.capabilities` occupy the agent scope and
`RunOptions.capabilities` occupy the run scope. `RunOptions.capability_layers`
adds explicit scopes; declaration order is stable within a scope regardless of
the layer slice order.

`CapabilitySnapshot` is borrowed and exposes active IDs plus the subset loaded
on demand. It is available to dynamic instructions, toolsets, tools, tool
policies, output validators, and model selectors. Nested agents can use the
snapshot to construct an inherited `CapabilityLayer`; ZigAI does not infer
subagent ownership from an opaque dependency pointer.

The short `system_prompt`, `user_prompt`, `retry_prompt`, and `text` variants
are convenient when no part metadata is needed. Their `*_part` counterparts
retain timestamps, IDs, and provider replay data. Provider-bound parts carry a
`ProviderPart`; file IDs carry their owner in `UploadedFile`.

History preserves opaque provider data as `ProviderDetails`, a structured JSON
object separate from application `Metadata`. Current adapters reject
provider-bound part IDs or details they cannot replay, and validate ownership
before encoding uploaded files. They never silently flatten fields.
Create it from a parsed object with `ProviderDetails.fromValue`; nested slices,
arrays, and object maps follow the enclosing owner's lifetime.

All slices are borrowed. `Agent.Result`, `history.Owned`, and other explicitly
owned containers define the lifetime of copied or parsed messages. The message
types themselves never allocate and never store an allocator.

The same types live under `zigai.messages`. The namespace is the canonical home
for durable conversation data; the root aliases keep common application code
short, and `zigai.model` keeps compatibility aliases for model implementers.

Use these namespaces for the rest of the API:

| Namespace | Purpose |
| --- | --- |
| `zigai.messages` | Provider-neutral request/response messages and parts |
| `zigai.capability` | Capability descriptors, scopes, diagnostics, and dependency planning |
| `zigai.agent_spec` | Strict JSON/YAML agent configuration, dry-run validation, and resolution |
| `zigai.settings` | Portable model controls and tagged provider extensions |
| `zigai.usage` | Per-request and aggregate run usage, exact costs, and native counters |
| `zigai.pricing` | Explicit versioned price tables and deterministic estimates |
| `zigai.codecs.pydantic_ai` | Lossless PydanticAI stable-v2 JSON interchange |
| `zigai.security` | Outbound URL validation and diagnostic redaction |
| `zigai.provider` | Provider identity, authenticated operations, policy, discovery, files, and profiles |
| `zigai.providers` | Native and named OpenAI-compatible provider clients |
| `zigai.providers.http` | Reusable authenticated HTTP provider for model adapters |
| `zigai.models` | Fallback and application-selected model routing |
| `zigai.history` | Version-2 ZigAI history serialization, version-1 migration, and processors |
| `zigai.evals` | Datasets, evaluators, reports, and model grading |
| `zigai.eval_io` | Versioned JSON/YAML dataset and report documents |
| `zigai.eval_compare` | Baseline/candidate comparisons and stable CI JSON |
| `zigai.mcp` | MCP 2026 client, server, transports, and explicit durable request identities |
| `zigai.durable` | Versioned durable operations, records, payloads, and runtime bindings |
| `zigai.durable.checkpoint` | Restart-safe stream cursors and approval state stores |
| `zigai.durable_adapters.temporal` | Temporal sidecar adapter, worker registrations, retry policy, and payload limits |
| `zigai.graph` | Typed graph definitions, bounded execution, lifecycle events, and manual iteration |
| `zigai.graph_agent` | Explicit buffered and structured agent-node adapters for typed graphs |
| `zigai.telemetry` | OpenTelemetry-shaped hooks and metrics |
| `zigai.diagnostics` | Backend-neutral structured lifecycle diagnostics |
| `zigai.reflect` | Compile-time tools and JSON Schema derivation |
| `zigai.transport` | Pluggable buffered and line-streaming HTTP transport |
| `zigai.json` | Pre-allocation validation and boundary-specific JSON limits |
| `zigai.testing` | Deterministic scripted models for application tests |

Provider `Client.model()` values borrow their client. Keep the client and its
transport alive for every agent run that uses the model. The same rule applies
to model routers, MCP clients, callback contexts, dependencies, and toolsets.
`Provider` values likewise borrow their concrete provider state. Model and file
discovery results own arenas and must be released with `deinit`.

`zigai.providers.http.Configured` is the standard concrete boundary for an
HTTP-backed provider. Its API root, credential, configured headers, transport,
request policy, and optional profile callbacks are borrowed. `provider()`
returns another borrowed view; keep the `Configured` value at a stable address
until every model and in-flight request using it has finished. Model adapters
receive only relative endpoints and never receive the provider credential.
Provider wrappers can attach discovery and file callbacks through
`Configured.Operations`; those callbacks remain behind the same borrowed
provider interface.

Provider requests may attach a borrowed `ResponseHeaderSink`. The standard
transport invokes it while response-head slices are valid and retains no
headers afterward. Callbacks must copy any selected value into their own
bounded storage; Google uses this mechanism for its resumable upload URL.

OpenAI uses that split directly. Create a stable `openai.Provider`, then pass
its borrowed interface to the Responses API client:

```zig
var provider = zigai.providers.openai.Provider.init(api_key, transport);
var client = zigai.providers.openai.Client{
    .model_name = "gpt-5-mini",
    .provider = provider.provider(),
};
```

Use `Provider.initWithOptions` for a custom API root, configured headers,
provider-wide request policy, or model profile callbacks. The provider and
transport must outlive the client and every in-flight model request.

Anthropic follows the same construction pattern with
`zigai.providers.anthropic.Provider`. Its provider owns the `x-api-key` header;
the client retains `max_tokens` and the Messages API wire behavior.

Google uses `zigai.providers.google.Provider`; it owns `x-goog-api-key` and
keeps the stable `gcp.gen_ai` provider identity. Its client builds model-bound
GenerateContent endpoints and encodes Gemini request and response bodies.

Vertex AI deliberately reuses that Gemini client with a different provider:

```zig
const base_url = try zigai.providers.vertex_ai.regionalApiBase(
    allocator,
    "europe-west1",
);
defer allocator.free(base_url);

var provider = zigai.providers.vertex_ai.Provider.initWithOptions(
    access_token,
    "my-project",
    "europe-west1",
    transport,
    .{ .base_url = base_url },
);
var client = zigai.providers.vertex_ai.Client{
    .model_name = "gemini-2.5-flash",
    .provider = provider.provider(),
};
```

The provider maps the codec's relative model operations onto the Vertex v1
`projects/{project}/locations/{location}/publishers/{publisher}/models/{model}`
resource. It accepts only `generateContent` and SSE `streamGenerateContent`,
validates every resource segment before HTTP, and uses the stable
`gcp.vertex_ai` identity. The default API root is Google's global Vertex
endpoint; `regionalApiBase` returns an owned regional root. The access token is
borrowed, so refresh it by creating a new provider after expiry.

Vertex and Google AI Studio share `.google` extension bodies because the
GenerateContent schema is the same. Credentials, resource paths, discovery,
and file operations remain provider-owned: Vertex does not expose the AI
Studio Files API or send `x-goog-api-key`.

Amazon Bedrock uses a native regional provider and a separate Converse wire
adapter:

```zig
var provider = try zigai.providers.bedrock.Provider.init(
    api_key,
    "eu-west-1",
    transport,
);
var client = zigai.providers.bedrock.Client{
    .model_name = "eu.anthropic.claude-sonnet-4-6",
    .provider = provider.provider(),
};
```

The provider borrows the API key and transport. Its generated regional URL is
bound only when `provider()` is called, so keep the concrete provider at a
stable address until the client and every request are finished. It authenticates
with the Bedrock bearer token, while the client owns model-path encoding and
Converse JSON.

Converse supports instructions, system and text history, function tools and
results, structured output on recognized model profiles, common inference
settings, tagged Bedrock extensions, service tiers, reasoning replay, normalized
finish reasons, and cache-aware usage. Unknown model families use a fail-closed
client profile unless the application supplies a profile lookup or override.
The adapter is buffered: `ConverseStream` uses binary AWS EventStream frames,
which require a chunk-stream transport rather than the line-stream interface.

`bedrock.MantleProvider`, `bedrock.MantleClient`, and `bedrock.mantleApiBase`
remain available for Bedrock's OpenAI-compatible Chat Completions endpoint.

xAI uses a first-class Responses client and keeps compatibility explicit:

```zig
var provider = zigai.providers.xai.Provider.init(api_key, transport);
var client = zigai.providers.xai.Client{
    .model_name = "grok-4.6",
    .provider = provider.provider(),
};
```

The native client accepts typed web and X search configuration, provider-side
code execution, collection search, and multiple remote MCP servers. Remote MCP
servers are keyed by `server_label`; other provider-managed tools are
singletons. Use `xai.ChatProvider` with `xai.ChatClient` only when an existing
Chat Completions integration requires that compatibility protocol. xAI-only
extension JSON uses the `.xai` tag and cannot cross into another adapter.

Mistral keeps Chat Completions and Conversations explicit. `mistral.Provider`
and `mistral.Client` remain compatibility aliases; the native path uses
`ConversationsProvider` and `ConversationsClient`:

```zig
var provider = zigai.providers.mistral.ConversationsProvider.init(
    api_key,
    transport,
);
var client = zigai.providers.mistral.ConversationsClient{
    .model_name = "mistral-small-latest",
    .provider = provider.provider(),
};
```

`client.model()` is stateless. It sends the complete provider-neutral history
with `store: false`, so retries, fallback, and ordinary agent calls never mutate
hidden remote state. Portable web search and code execution map to Mistral's
managed tools. Mistral-only premium search, image generation, document
libraries, and connectors are configured through `client.managed_tools`;
connector authorization remains request-scoped and borrowed. Native extension
JSON uses the `.mistral` tag.

Stored conversations are deliberate:

```zig
const first = try client.start(arena, request);
const session = try zigai.providers.mistral.Session.init(
    provider.provider(),
    first.conversation_id.?,
);

const next = try session.append(arena, append_request);
_ = next;

var history = try session.history(gpa);
defer history.deinit();

try session.delete(gpa);
```

`Client.start` stores the initial conversation. `Session.append` accepts only
new entries and completion settings; instructions and tool declarations belong
to the initial request. The session borrows its provider and ID. `history`
returns an arena-owned native entry list with a typed family and complete
structured `ProviderDetails`, including unknown beta entry types. Call
`deinit` when finished. Conversation IDs are validated before path assembly.

Cohere keeps its existing Compatibility API aliases. Native v2 Chat uses an
explicit provider and client:

```zig
var provider = zigai.providers.cohere.ChatProvider.init(api_key, transport);
var client = zigai.providers.cohere.ChatClient{
    .model_name = "command-a-03-2025",
    .provider = provider.provider(),
};
```

The native adapter supports chronological system, user, assistant, and tool
messages; buffered and streamed text, thinking, tool plans, and parallel tool
calls; structured output; normalized usage; and structured citation and
log-probability details. Cohere-only fields such as `strict_tools`, documents,
citation options, safety mode, and priority use the isolated `.cohere`
extension body. Authentication stays on `ChatProvider`; compatibility clients
continue to use `Provider` and `Client`.

OpenRouter uses Chat Completions as its wire format and keeps router policy on
its own client:

```zig
var provider = zigai.providers.openrouter.Provider.init(api_key, transport);
var client = zigai.providers.openrouter.Client{
    .model_name = "anthropic/claude-sonnet-4.5",
    .provider = provider.provider(),
    .routing = .{
        .order = &.{ "anthropic", "google-vertex" },
        .allow_fallbacks = false,
        .require_parameters = true,
        .data_collection = .deny,
        .zdr = true,
    },
    .include_router_metadata = true,
};
```

`Routing` also supports allowlists, denylists, quantization filters, price,
latency, and throughput preferences, plus simple or cross-model partitioned
sorting. Invalid names, conflicting allow/deny rules, empty percentile or
price objects, and non-finite or negative limits fail before HTTP. Raw
OpenRouter-only fields use the `.openrouter` extension tag and cannot replace
the typed `provider` object. Metadata opt-in follows OpenRouter's
[`X-OpenRouter-Metadata`](https://openrouter.ai/docs/guides/features/router-metadata)
contract; returned `openrouter_metadata` remains structured in
`ModelResponse.provider_details` for buffered and streaming calls.

OpenAI-compatible modules follow the same rule. Each named module exports a
matching `Provider` and `Client` built from shared compile-time defaults. The
provider owns the API root, provider identity, authentication style, headers,
request policy, transport, and profile callbacks. The client owns only the
model name, model settings, Chat Completions behavior, and optional
gateway-specific idempotency header. Use
`openai_compatible.Provider.initWithOptions` when the endpoint or identity is
selected at runtime. Azure OpenAI exposes one provider state with
`ResponsesClient` for its native GA v1 Responses endpoint and `ChatClient` for
Chat Completions; both use `apiBase` and Azure `api-key` authentication. The
Responses client deliberately shares OpenAI's Responses codec because Azure v1
publishes the same wire contract. Bedrock Mantle exposes `mantleApiBase` for
its deployment-specific Chat Completions root.

Named compatible providers resolve model capabilities in four layers:

1. An application `ModelProfiles.lookupFn`, when it recognizes the model.
2. The provider's built-in upstream-family profile.
3. The client's fallback profile when neither lookup recognizes the model.
4. An application `ModelProfiles.overrideFn`, applied to the resolved result.

Named clients use a fail-closed fallback for unknown families. The generic
`openai_compatible.Client` retains its configurable compatibility presets
because an arbitrary endpoint has no provider identity to resolve against.

Ollama has a named compatibility provider with no credential. Its default
`http://localhost:11434/v1` endpoint is accepted only through the exported
`ollama.local_request_policy`; callers must apply that same policy to the
standard HTTP transport. Tagged and namespaced library models resolve through
Ollama-specific family profiles. Unknown model families retain the fail-closed
compatible profile, so unsupported settings and tools are rejected before I/O.

Crusoe's named provider uses bearer authentication from the caller and the
Serverless Inference `/v1` root. Its profile lookup recognizes Crusoe's
vendor-qualified Meta, DeepSeek, Qwen, Google, OpenAI Harmony, Moonshot, and
Z.AI families. Crusoe's guided decoding enables both structured-output modes;
unknown deployment aliases remain fail-closed unless the application supplies
an explicit profile.

Snowflake Cortex has an account-scoped Chat Completions root. Build it with
`snowflake.apiBase`, which accepts a bare account identifier or canonical
Snowflake account hostname and rejects schemes, paths, ports, and malformed
labels before authentication. Cortex profiles distinguish OpenAI, Claude, and
text-only families so ignored or rejected tool and structured-output fields do
not reach the network. Unknown models remain fail-closed.

`snowflake.Client.reasoning` accepts exactly one of `effort` (`low`, `medium`,
or `high`) and `max_tokens`. It is limited to Claude model IDs. When set, the
client supplies Cortex's required temperature `1`, or rejects a conflicting
temperature before I/O. Buffered and streaming requests delegate to the shared
Chat Completions codec after this typed preparation. Snowflake-only raw fields
use `ProviderExtraBody.snowflake`; `reasoning` is reserved to the typed API.

Z.AI's named provider uses the general `/api/paas/v4` Chat Completions root and
native `glm-*` model IDs. `zai.Client` adds typed `thinking` and
`clear_thinking` controls. It decodes buffered and streamed
`reasoning_content` into provider-owned thinking parts and replays that content
unchanged on later tool turns. Unsupported GLM families and lossy thinking
parts fail before transport. `zai.CompatibilityClient` exposes only the
portable Chat Completions surface; Z.AI fields do not enter the generic public
codec or extension tag.

The compiled custom-provider example demonstrates the runtime extension path.
It validates a public HTTPS API root, configures bearer authentication, assigns
a stable provider identity, and supplies an exact application profile lookup.
Its client explicitly selects `profiles.unknown` as the fallback. Applications
should add only capabilities their server contract guarantees; this keeps
unsupported settings, tools, and content out of transport callbacks.

`Provider.listModels` is implemented by OpenAI, Anthropic, Google, and
OpenAI-compatible provider objects. It authenticates through the provider
boundary and returns `OwnedProviderModels`; call `deinit` after consuming its
identifiers and raw metadata. `Provider.Options.discovery_limits` bounds pages
and total models for paginated APIs. Model adapters are not involved in
discovery.

`ModelCatalog.init` validates a borrowed slice of `ModelCatalogEntry` values.
Each entry scopes one canonical ID and its aliases to `provider_name`, and may
carry `ModelCatalogLimits`, `ModelDeprecation`, and a trusted `ModelProfile`.
Resolution is exact and case-sensitive; no allocation, prefix matching, or
implicit provider fallback occurs. Canonical IDs and aliases occupy the same
provider-local namespace, so ambiguous catalogs fail at initialization.

`ModelCatalog.resolve(provider_name, requested_id)` returns a borrowed
`ResolvedModel`. Use `canonicalId()` before constructing a provider client,
`wasAlias()` for diagnostics, and `replacement()` to follow a validated
deprecation target. The catalog and every referenced entry must outlive the
resolution. Live provider metadata remains separate and untrusted; merging it
with catalog records is an explicit API rather than a capability-profile
override.

`mergeModelDiscovery` returns `OwnedDiscoveredCatalog`. Each joined item keeps
the original `ProviderModelDescriptor`, optional catalog entry, and canonical
ID distinct. `trustedProfile()`, `limits()`, and `deprecation()` read only from
the catalog; a profile attached to live discovery is never promoted. Alias and
canonical duplicates in one provider response fail instead of being silently
collapsed. The owned result stores only the joined index, so call `deinit` and
keep both the provider discovery arena and catalog entries alive while using
it.

`builtin_model_catalog` exposes the generated compatibility snapshot alongside
`builtin_model_catalog_version` and `builtin_model_catalog_updated_at`. The
runtime module contains static entries and performs no parsing or allocation.
`data/model_catalog.json` is the reviewable source; `zig build
update-model-catalog` regenerates the Zig module, and `zig build
check-model-catalog` compares it byte-for-byte. The source is sorted and
validated before generation, including aliases, enum sets, HTTPS provenance,
limits, and the core catalog invariants.

Provider file descriptors always include `provider_name`. Their
`uploadedFile()` view is the handle accepted by `inspectFile`, `downloadFile`,
and `deleteFile`, and it can also be passed directly as provider-owned rich
content. The provider validates that handle before dispatch, so a foreign or
empty ID never reaches provider code. Upload, inspection, and download results
are validated again before they are returned.

`uploadFile` and `inspectFile` return `OwnedProviderFile`. `downloadFile`
returns `OwnedProviderFileDownload`, which owns both its descriptor and bytes.
Call `deinit` on either result after use. Providers that cannot safely download
content leave that operation unsupported; applications receive
`UnsupportedProviderOperation` instead of a synthetic URL or a second
unauthenticated fetch.

OpenAI implements upload, inspection, reuse, download, and deletion. It uses
`user_data` when `ProviderFileInput.purpose` is null, while the API permits
content download only for supported purposes such as fine-tuning inputs.
Anthropic implements the same endpoints, but files uploaded by a caller are
marked `downloadable: false`; only files generated by a tool can be downloaded.
`OwnedProviderFile.value.downloadable` exposes that provider result so callers
can choose safely. Anthropic rejects an upload purpose, always sends the Files
API beta header, and both providers percent-encode file IDs before using them
in paths. `ProviderFileLimits` bounds upload bytes and multipart metadata before
transport I/O and is configurable through provider options.

Google implements resumable upload, inspection, reuse, and deletion. Its
returned handle is the authenticated file URI required by Gemini requests.
Upload session URLs are accepted only from the configured upload origin, and
the default Google upload limit matches the documented 2 GB file maximum.
`downloadFile` intentionally remains unsupported because the Gemini Files API
does not permit clients to download stored files.

`agent_spec.Owned` owns parsed configuration in an arena. It is data-only and
does not read secrets or construct clients. `validateResolution` uses
application-supplied provider and capability catalogs without building a
model. `agent_spec.Resolved` owns copied configuration and the model context
allocated through its resolver; its optional cleanup callback runs before the
arena is released. Capability implementations remain borrowed. See
[Agent specifications](agent-specs.md) for the complete contract.

`ModelSettings` also borrows stop strings, tool names, request headers, and
provider-extension JSON. Those values need to live only until the model request
returns; results and reusable history do not retain them. An empty non-null
slice is an explicit override, while null inherits the lower-precedence value.

## Typed graphs

`graph.Graph(State, Deps, Input, Value, Output)` creates a workflow type without
erasing application values. Its `Builder` registers one typed start callback,
one typed end callback, named steps and decisions, and an entry node. A step has
exactly one unconditional route. A decision returns
`DecisionResult { branch, value }` and has one or more named routes registered
with `branch` or `branchFinish`. Duplicate names, invalid node kinds or IDs,
incomplete routing, unreachable nodes, and definition limits fail at build
time.

`Graph.run` executes to completion. `Graph.iter` executes the start adapter and
returns a `Run`; `Run.next` then advances one step and returns either the next
node or the final typed output. A terminal error is latched, so later calls
return the same failure instead of continuing a desynchronized workflow.
`RunOptions.max_steps` may tighten, but never widen, the definition ceiling.
Returning a branch name that was not registered latches `UnmatchedRoute`.

`Builder.addFanOut` registers an explicit parallel node. `FanOutMode.broadcast`
sends the current `Value` to every borrowed `ParallelBranch`.
`FanOutMode.map` invokes a `Map` callback with a bounded `Emitter`, then sends
each emitted value to every branch in item-major, branch-major source order.
The embedded typed `Join` initializes one accumulator even for an empty map and
borrows every successful branch result through `reduce_fn`.

`RunOptions.max_concurrency` defaults to one and is capped by
`Limits.max_concurrency`. A value above one requires `RunOptions.io` only when a
fan-out contains multiple tasks. The scheduler observes completions as they
arrive, cancels sibling tasks on the first failure, and retains results by
source index so reducer order is deterministic. `max_fan_out_items`,
`max_fan_out_tasks`, and `max_parallel_branches` bound every fork before more
work is admitted.

The built graph owns only its node and routing arrays and releases them with
`deinit(gpa)`. Node names, registered branch names, callback contexts, and
definition metadata are borrowed for the graph's lifetime. A branch name returned by a decision is
borrowed only for that synchronous callback, route lookup, and event delivery.
State and dependencies are borrowed for the run's lifetime.
Intermediate and output ownership follows the application-defined `Value` and
`Output` types; callbacks receive the run allocator explicitly and must define
their own cleanup contract for allocations they return.

A fan-out borrows its input, owns values emitted by a map and values returned
by branches, and transfers the final accumulator back to the graph. When
`FanOut.deinit_value_fn` is set, the scheduler calls it for emitted values and
branch outputs after reduction, and for an accumulator abandoned by failure.
When this hook is used, branch outputs must own independent resources: they
must not alias the fan-out input, emitted values, or one another. The
application remains responsible for cleaning the successful accumulator after
a later step or end callback consumes it.

Event sinks are synchronous and infallible. They receive borrowed run/step
start, end, and failure records in execution order. They must copy a node name
or branch name before retaining it. The core supports linear, cyclic, named
conditional, and bounded parallel routing.

### Graph agent nodes

`graph_agent.BufferedNode(Workflow)` and
`graph_agent.TypedNode(Workflow, AgentOutput)` turn an `Agent` invocation into
an ordinary typed `Workflow.Step`. Each adapter borrows its agent, callback
context, observer, name, and metadata for the built graph's lifetime.
`prepare_fn` receives a node-scoped scratch arena, graph context, and borrowed
input. It returns a prompt plus `Agent.RunOptions`; when `dependencies` is
null, the adapter injects the graph's typed dependency pointer. `apply_fn`
receives the completed agent result and must copy anything retained in the
returned `Value` before the callback returns.

Set `stream_sink` to select the streaming agent API. It receives each borrowed
`AgentStreamEvent` synchronously in provider and tool-loop order. After a
successful callback, the node observer receives the matching borrowed `stream`
event. A callback failure emits the `stream` failure phase and aborts before
`apply_fn`, so the graph never commits a transition for a partially delivered
run.

`Control.cancellation` overrides the borrowed agent token for one node.
`Control.timeout_ms` can only tighten the agent and prepared run timeout. A
borrowed graph `RunOptions.io` becomes the agent runtime when `Agent.io` is
null. Cancellation and deadline work is drained by the agent before the node
returns.

`Correlation` supplies a stable graph run ID and optional trace parent. The
adapter derives the node ID, node name, provider request ID, and
`Agent.RunCorrelation`. Hooks and OpenTelemetry therefore share the graph
identity. A durable binding is namespaced with
`graph.<node-id>.step.<step-number>` beneath any existing
`Binding.step_namespace`; replay keeps the same identity, while two
agent nodes cannot collide. A configured correlation run ID must equal the
durable binding run ID.

The adapter's synchronous observer receives borrowed `start`, `stream`, `end`,
and `failure` events. Failure events preserve the original error name and
identify preparation, agent execution, stream delivery, or application. The
graph-facing error remains deliberately narrow: allocator failures stay
`OutOfMemory`, agent cancellation stays `Cancelled`, and other agent failures
become `StepFailed`.

`graph_agent.Conversation` is the reusable state helper for sequential agent
nodes. `init` and `replace` deep-copy the complete canonical message vocabulary
and usage detail names into one arena. `appendRun` replaces history while
adding request, tool, token, latency, detail, and cost counters to cumulative
usage. Its storage must be deinitialized by the application state owner.
Agent adapters produce ordinary graph steps, not fan-out branch callbacks.
They therefore do not execute concurrently unless separate graph runs invoke
them concurrently. In that case, the agent, callbacks, dependencies, stream
sink, and telemetry exporter must be immutable or thread-safe. A shared
`Conversation` still requires application synchronization.

Concurrent fan-out callbacks share `State`, `Deps`, branch contexts, and input
values. The scheduler makes only `Context.gpa` safe for concurrent use.
Applications must synchronize all other shared mutation, use immutable data,
or keep `max_concurrency = 1`.

### Graph snapshots

Graph snapshots are opt-in. Set `Builder.definition_id` to a stable borrowed
identity before `build`; an absent identity keeps `Run.snapshot` and
`Graph.resumeSnapshot` disabled. The identity, node kinds and names, fan-out
mode and branch names, routes, typed graph parameters, entry node, and runtime
ceilings produce one SHA-256 definition fingerprint. Names, branch slices, and
the definition identity must remain immutable for the built graph's lifetime.
Change the identity when callback behavior or types change incompatibly.

`Run.snapshot(gpa, codec)` is valid only while a run is settled and running:
after `iter` returns or between completed `next` calls. It calls the
application's `SnapshotCodec` to produce complete JSON documents for `State`
and the current `Value`, then returns one `gpa`-owned versioned envelope. It
does not serialize `Deps`, callback contexts, event sinks, `std.Io`, or
in-flight fan-out work. A `next` call drains every parallel task before it
returns, so snapshots never contain an ambiguous partial fork.

The version 1 envelope contains `definition_sha256`, `payload_version`, the
next node's index and name, completed step count, original run step ceiling,
and encoded state/value documents. Parsing rejects unknown or duplicate fields,
malformed JSON, mismatched node identity, definition drift, future envelope or
payload versions, and configured byte/depth/collection limits before invoking
decoders. Snapshot limits are controlled by `Limits.max_snapshot_bytes`,
`max_snapshot_payload_bytes`, `max_snapshot_depth`, and
`max_snapshot_collection_items`.

`Graph.resumeSnapshot(gpa, state_out, deps, source, codec, options)` decodes
state and value atomically, injects fresh dependencies and run-only options,
and returns a `Run` positioned at the saved next node without invoking `Start`
or replaying completed nodes. `state_out` must point to uninitialized storage;
it remains untouched on failure and owns the decoded state on success. A
resume emits `run_resume`. `RunOptions.max_steps` may narrow the stored total
ceiling only when it does not fall below the completed step count.

Each codec has a nonzero payload version. To restore an older payload, provide
`SnapshotMigration.run_fn`; it receives both old JSON documents and returns one
`gpa`-owned JSON object with exactly `state_json` and `value_json` string fields
for the codec's current version. The graph validates the migrated documents
before decoding them. If decoded state can own resources, set
`deinit_state_fn` so a later value-decoding failure can release it.

### Graph visualization metadata

`NodeMetadata` attaches optional borrowed `label`, `description`, `group`, and
`SourceLocation` values to start, step, decision, fan-out, and end definitions.
`EdgeMetadata` carries a label, description, and source location. Existing
`connect`, `finish`, `branch`, and `branchFinish` calls keep empty metadata;
their `*WithMetadata` counterparts register it explicitly. Empty or oversized
values fail during definition assembly according to the graph `Limits`.

`Graph.visualization(gpa)` returns an owned `Visualization` with schema
`visualization_format_version`, the definition fingerprint, synthetic start
and end nodes, registered nodes in source order, and deterministic edges. Node
IDs use the tagged `VisualizationNodeId`; decision `branch` identities remain
separate from presentation labels. Only the node and edge arrays are owned by
the result. Every string is borrowed from the graph and the view must be
deinitialized before the graph or its metadata storage is released.

`Graph.renderMermaid(gpa, options)` returns a `gpa`-owned
`stateDiagram-v2` document capped by `Limits.max_visualization_bytes`.
`MermaidOptions` controls an optional title, `MermaidDirection`, and edge-label
visibility. Nodes use definition-order IDs, groups use first-appearance IDs,
decisions and fan-outs retain choice/fork shapes, and descriptions plus source
locations render as notes. Edge labels prefer explicit metadata and otherwise
use the decision branch identity. Newlines, quotes, markup characters, and
control bytes are escaped before borrowed text reaches Mermaid syntax.

## Evaluations

`evals.Dataset.run` executes each case once and propagates task, evaluator,
hook, and allocation errors. `runWithOptions` additionally accepts
`evals.ExecutionOptions`: `repetitions`, independent `task_retry` and
`evaluator_retry` policies, bounded `max_concurrency` with an optional `io`
runtime, and borrowed lifecycle hooks. Zero repetitions, concurrency, or retry
attempts return `evals.Error.InvalidExecutionOptions` before a model is called.
More than one effective concurrent run without `io` returns
`ConcurrentExecutionRequiresIo`.

`RetryPolicy.shouldRetryFn` classifies the error from the completed attempt.
When it returns true, `beforeRetryFn` runs before the next attempt and may
implement sleeping, rate-limit coordination, or test-controlled waiting.
`CaseResult` records the source `case_index`, one-based `repetition`, total
`repetitions`, and `task_attempts`; each `EvaluationResult` records its own
attempt count. Report order is source case first, then repetition.

With `max_concurrency > 1`, the `Model` implementation, evaluators, retry
callbacks, and lifecycle hooks must be thread-safe. ZigAI locks access to the
caller allocator and report arena; application callback state remains outside
that boundary. All admitted work is joined before success or failure returns,
and the lowest source-order task/evaluator failure is propagated.

`Dataset.report_evaluators` run once each after all cases have joined. A
`ReportEvaluator` receives a borrowed `ReportView` and returns an `Analysis`
with optional assertion, scalar value, unit, and reason. Returned strings are
copied into `Report.analyses`. A false analysis assertion participates in
`Report.passed()`; a non-finite value returns `InvalidReportAnalysis`.

`Report.summary()` returns total and passed run counts plus a null-on-empty pass
rate. `caseSummary(case_index)` groups repetitions by their stable source index.
`scoreStatistics(evaluator_name)` ignores absent and non-finite scores and
returns count, minimum, maximum, mean, and population standard deviation.

`Dataset.trace_evaluators` are `TraceEvaluator` callbacks over a
`TraceContext`. They require `Agent.telemetry`; otherwise the run returns
`TraceEvaluationRequiresTelemetry` before calling the model. The per-case
`CaseResult.spans` slice owns a deep copy of every span exported during that
agent run, including typed attributes. The configured exporter still receives
the original spans and all metrics. Trace results follow ordinary evaluator
results and use `ExecutionOptions.evaluator_retry`.

`eval_io.stringifyDatasetJson` and `stringifyDatasetYaml` encode version-1
dataset documents. Files contain cases, metadata, and ordered evaluator names.
`parseDatasetJson` and `parseDatasetYaml` require an `EvaluatorRegistry` and
return an arena-owned runnable dataset. A missing name returns
`UnknownEvaluator`; more than one registry entry with that name returns
`AmbiguousEvaluator`. Names must also be unique across ordinary, trace, and
report evaluator categories.

Dataset serialization accepts only default per-case `RunOptions`. Those options
may contain executable callbacks, pointers, queues, or credentials, so a
non-default value returns `UnsupportedCaseOptions` instead of silently dropping
state.

`eval_io.stringifyReportJson`, `stringifyReportYaml`, `parseReportJson`, and
`parseReportYaml` round-trip complete reports. The version-1 shape includes
case/repetition identities, attempts, output, usage, evaluations, aggregate
analyses, and typed OpenTelemetry spans. Trace and span IDs are lowercase hex.
Parsers are strict, bounded by the CLI-config JSON limits, reject duplicate YAML
keys, and return arena-owned values that must be deinitialized.

`eval_compare.compareReports` matches case runs by stable `(case_index,
repetition)` identity and evaluator or analysis entries by name. Baseline order
is retained, followed by candidate-only entries in candidate order. A reused
identity with a different case name fails with `CaseIdentityMismatch`; duplicate
identities or evaluator names are rejected before comparison.

Each comparison classifies entries as `unchanged`, `improved`, `regressed`,
`added`, or `removed`. Removed assertions and newly failing entries count as
regressions; newly passing entries count as improvements. The report also
contains pass-rate and finite score/value deltas plus signed token, request,
tool, latency, and cost deltas. `regressionFree()` is true only when every
regression category is zero.

`eval_compare.stringifyCiJson` emits stable indented version-1 JSON without
timestamps or environment-specific fields. Its top-level `conclusion` is
`pass` exactly when `regressionFree()` is true, so callers can persist the JSON
as an artifact and map the same predicate to their process exit status.

## Ownership

ZigAI follows one rule for high-level operations: a returned type with a
`deinit` method owns its complete result graph.

| Value | Ownership rule |
| --- | --- |
| `Agent.Result` | Owns output and message history until `deinit` |
| `TypedResult(T)` | Owns the decoded value, JSON, and history until `deinit` |
| `RunOutcome` / `PausedRun` | Owns completed or serialized paused state until `deinit` |
| `OwnedResumeDecisions` | Owns parsed decisions until `deinit` |
| `eval_io.OwnedDataset` | Owns a parsed dataset graph; registry callbacks remain borrowed |
| Parsed `evals.Report` | Owns the complete deserialized report until `deinit` |
| `eval_compare.Report` | Owns the complete comparison graph until `deinit` |
| `history.Owned` | Owns parsed history until `deinit` |
| `codecs.pydantic_ai.Owned` | Owns the complete PydanticAI JSON value graph until `deinit` |
| `capability.LoadResolution` | Owns its dependency plan and diagnostic until `deinit` |
| `evals.Report` | Owns every case and evaluation result until `deinit` |
| `transport.Response` | Caller frees `body` with the allocator passed to `send` |

`ResponseMessage.usage` is `RequestUsage`. `Agent.Result`, `PausedRun`,
`TypedResult`, and `evals.Report` expose `RunUsage`. Cached and modality fields
are inclusive subsets of the input/output totals, so `totalTokens()` is always
`input_tokens + output_tokens`. Result arenas own usage detail names and price
table version strings. `reasoning_tokens` normalizes OpenAI reasoning tokens,
Anthropic thinking tokens, and Google thought tokens for both buffered and
streamed responses.

`UsageCost` stores nano-USD exactly. `PriceTable.estimate` returns null for an
unknown model or any non-empty bucket without a rate. `pricing.builtin` is an
offline snapshot generated from the pinned pydantic/genai-prices v2 data. Its
version, source commit, checksum, and coverage counts are public constants.
Applications may provide a different immutable table through
`Agent.price_table`.

`transport.HttpTransport.init` uses bounded decompressed response defaults:
16 MiB per buffered body and 1 MiB per streaming line. Pass a
`transport.Limits` value to `HttpTransport.initWithLimits` to change them.
The limit excludes the streaming newline. A body or line exactly at its limit
is accepted; the next byte returns `error.ResponseTooLarge` or
`error.StreamLineTooLarge`.

Inputs, callback events, stream events, lifecycle events, and provider error
observer values are borrowed unless their documentation says otherwise. Copy
data inside the callback if it must outlive the call. Functions such as
`history.stringify`, `codecs.pydantic_ai.stringify`,
`stringifyResumeDecisions`, and provider request encoders return a slice owned
by the caller's allocator.

Direct `Model.request`, `Model.stream`, and provider decoder calls build nested
response data with the supplied allocator. Use an arena and release the arena
as one unit. Normal `Agent` calls already provide this ownership boundary.

`Agent.diagnostics` borrows its sink and configured sensitive values. The sink
receives a sanitized event whose strings live only for the callback. Content
capture is opt-in; configured sensitive values are replaced before the value
limit is applied, so truncation cannot expose a secret prefix. `max_attributes`,
`max_key_bytes`, and `max_value_bytes` bound every event before delivery.

## Output strategies

`Agent.output` is an `OutputSpec`, separate from the provider wire
`OutputFormat`. The concise `.json_schema` form accepts one named schema;
`.native` accepts named alternatives and combines them with `anyOf`;
`.prompted` accepts the same alternatives plus an optional template containing
one `{schema}` marker. Prompted output requires system instructions, selects
JSON-object mode when the profile supports it, and otherwise uses text mode.
Its result is always validated locally.

Specification slices are borrowed for the run. Combined schemas and rendered
instructions live in the run arena and follow the result ownership boundary.

`.tool` exposes each choice as a separate function-tool definition and requires
tool support. Non-object schemas receive a provider-facing `{ "value": ... }`
wrapper that the agent removes after local validation. `Result.output_name`
identifies the chosen branch. An `OutputFunction` receives borrowed
`OutputRunContext` state and validated JSON; returned slices must be static or
allocated with its supplied run-arena allocator. Its explicit `.retry` result
is safe to send to the model, while thrown errors stop the run.

`Agent.output_validators` runs ordered `OutputValidator` callbacks after schema
validation and after an output function. Each callback receives the selected
choice name, borrowed `OutputRunContext`, and the previous callback's output.
It returns `.output` to accept or transform the value, or `.retry` with a safe
model-visible correction message. Transformed structured output is checked
against its schema again. A thrown callback error aborts the run. Capabilities
can contribute validators through `Capability.output_validators`; agent-level
validators run first.

`Agent.end_strategy` defaults to `.graceful`: ordinary calls before the first
successful output run, later calls are closed as skipped. `.early` evaluates
output calls first and skips ordinary calls after one succeeds. `.exhaustive`
runs every emitted call and keeps the first successful output by emission
order. Deferred approval or external calls still pause before finalization.

### Local JSON Schema dialect

Every hand-written output schema is checked before the first model request.
ZigAI implements a fail-closed subset of JSON Schema Draft 2020-12: unknown
validation keywords and non-local references are rejected instead of ignored.
`zigai.json_schema.supported_dialect` contains the accepted `$schema` URI, and
`validateSchema` can preflight a schema independently of an agent run.

The supported assertions are:

- `type`, `enum`, `const`, `allOf`, `anyOf`, `oneOf`, `not`, and
  `if`/`then`/`else`;
- `$defs` with `#` or single-segment `#/$defs/...` references, including JSON
  Pointer `~0` and `~1` escapes;
- `properties`, `required`, `additionalProperties`, `propertyNames`,
  `dependentRequired`, and minimum/maximum property counts;
- `items`, `prefixItems`, `contains`, minimum/maximum contains and item counts,
  and `uniqueItems`;
- Unicode-codepoint string lengths; and
- inclusive/exclusive numeric bounds and `multipleOf`.

Standard descriptive annotations such as `title`, `description`, `default`,
`examples`, `format`, and read/write/deprecation flags are accepted but do not
change validation. Regex, remote or general JSON Pointer references, dynamic
references, and unevaluated-value keywords are currently unsupported.
Malformed supported vocabulary returns `InvalidJsonSchema`; unsupported valid
vocabulary returns `UnsupportedJsonSchema`; a valid output that misses an
assertion returns `OutputSchemaValidationFailed`.

`Tool.origin` is `ToolOrigin.application` by default. Tools prepared by an MCP
client use `ToolOrigin.mcp`; deterministic orchestration tools may explicitly
use `ToolOrigin.workflow`. Providers see all three as ordinary function tools.
Durable agents route application and MCP tools through `tool_call` and
`mcp_request` workers, while workflow tools execute inline during replay and
must not perform external side effects. ZigAI's internal `load_capability` tool
uses the workflow origin.

## Streaming events

`ModelStreamEvent` represents provider response parts with `part_start`,
`part_delta`, and `part_end`; every event for a part uses the same `index`.
`ResponsePartDelta` covers text, thinking, function and native tools, native
tool returns, media, speech, and compaction. Usage is reported separately.

`AgentStreamEvent` wraps model events and adds function-tool call/result,
tool-availability, deferred request/result, enqueued-message,
`partial_output`, and `final_result` events. A `partial_output` is the complete
output accumulated so far, not the latest delta. The corresponding raw model
event is delivered first. Text snapshots are accumulated directly. Structured
snapshots are repaired into valid JSON, then checked against present types,
properties/items, forbidden extras, and maximum bounds. Assertions that later
bytes can satisfy or change, such as `required`, minimum bounds, `const`, and
numeric limits, are deferred to final validation.

Wrap a sink with `CheckpointedStreamSink` to resume one deterministic stream
segment after a worker restart. Committed event ordinals are skipped on replay.
Use a new checkpoint ID after an approval resume or whenever event ordering
changes. Delivery is at least once across the small sink-success/store-write
window; use `durable.deliverEvent` for deduplicated business side effects.

Output functions and validators receive every useful partial snapshot with
`OutputRunContext.partial_output = true`; `.retry` suppresses that snapshot and
a thrown error stops the stream. They run again on the final candidate with
`partial_output = false`. Structured transformations are partially checked
again before delivery. Only `final_result` is accepted output and receives full
validation. JSON object and schema events attach a `std.json.Value` snapshot.
All values are borrowed for the callback; copy them before returning if they
must be retained.

`runUntilPauseStream` and `resumeRunStream` preserve the event flow across
approval and external-tool boundaries. Providers restart part indexes for each
model response in a multi-request agent run.

`PendingMessageQueue` is an allocator-owned, thread-safe, one-run FIFO. It
deep-copies `RequestMessage` batches and requires a `std.Io` runtime for its
mutex. Attach it through `RunOptions.pending_messages`; keep it alive until the
run returns, then call `deinit`. Accepted batches enter history only at safe
boundaries: before a model request, after tool results, or after a provisional
final response. Each insertion emits `enqueued_messages` for streaming runs.

If a run pauses, accepted messages are stored separately in the serialized
pause state and inserted immediately after deferred tool results on resume.
Cancellation or another terminal failure closes the queue and discards batches
that did not enter history. Finalization checks and closes the queue under the
same lock, so an enqueue is either accepted for another model step or rejected
with `PendingMessageQueueClosed`; it cannot disappear behind a final result.

## Errors

The public named error categories are:

- `Agent.Error` (also `zigai.AgentError`) for agent validation, limits, and
  lifecycle failures;
- `durable.Error` for invalid durable records, missing worker registrations,
  runtime mismatches, and persisted failure or suspension outcomes;
- `zigai.ProviderRequestError` for normalized rate-limit, server, and other
  non-success provider responses;
- `providers.<name>.Error` for provider encoding and decoding failures plus the
  normalized provider request errors;
- `history.Error`, `codecs.pydantic_ai.Error`, `json_schema.Error`,
  `evals.Error`, `mcp.Error`, and `transport.Error` for their
  subsystem-defined failures.

`transport.Error.ResponseTooLarge` and `transport.Error.StreamLineTooLarge`
are stable policy failures. They apply to decompressed bytes, so compression
cannot bypass the configured allocation boundary.

## Security policy

`zigai.UrlPolicy` is HTTPS-only and public-network-only by default. Agents apply
it to provider endpoints and rich-content URLs. MCP Streamable HTTP and the
standard HTTP transport enforce it independently, so direct and custom-model
use keeps the same boundary.

`HttpTransport.initWithOptions` configures URL, redirect, and response-size
policy together. Redirects are never followed; the explicit choices are reject
or return the 3xx response. See [Security](security.md) for local development,
allowlists, DNS limitations, credential redaction, and trust boundaries.

## JSON limits

`zigai.json.validate` scans one complete document without retaining a value
graph. It checks the encoded document size, decoded string or encoded number
size, container depth, and the number of fields or elements in each collection.
Its stable `ValidationError` distinguishes each limit from malformed JSON.
`json.parse` and `json.parseLeaky` combine that preflight with owned or
arena-owned decoding and map invalid input to a caller-selected stable error.
`json.validateAs` provides the same mapping without building a value graph,
while `json.isValid` is useful for boolean validation such as evals.

ZigAI applies these reviewed defaults before its own decoders allocate:

| Boundary | Document | Value | Depth | Items per collection |
| --- | ---: | ---: | ---: | ---: |
| History | 16 MiB | 1 MiB | 64 | 65,536 |
| Paused state | 32 MiB | 16 MiB | 64 | 65,536 |
| Resume decisions | 4 MiB | 1 MiB | 32 | 16,384 |
| Provider response | 16 MiB | 4 MiB | 128 | 65,536 |
| Tool payload | 1 MiB | 1 MiB | 64 | 4,096 |
| MCP message | 4 MiB | 1 MiB | 64 | 16,384 |
| JSON Schema | 2 MiB | 512 KiB | 64 | 16,384 |
| CLI manifest | 1 MiB | 256 KiB | 32 | 4,096 |

The named profiles live under `zigai.json.defaults`. Applications can use a
custom `json.Limits` value when validating their own untrusted JSON entry
points.

Every `Tool` execution and validation entry point requires `arguments_json` to
contain one complete JSON document within the tool-payload profile. Invalid or
oversized arguments return `error.InvalidToolArguments` before the callback is
invoked.

## Run deadlines and cancellation

`Agent.run_timeout_ms` creates one absolute monotonic deadline for an
invocation. `RunOptions.timeout_ms` may tighten that budget for one buffered,
streaming, pause, or resume call. `Agent.request_timeout_ms` is a separate
per-model-attempt ceiling; each attempt receives the smaller of that value and
the remaining run time, so retries never restart the run budget.

The run control covers model requests and streams, retry waits, dynamic
instructions, capability model selection, history processors, toolset
preparation, argument validation, local and MCP tools, output validators,
lifecycle hooks, stream sinks, and resumed tool decisions. Official HTTP
transports apply the remaining timeout to the complete operation, including
DNS, connect, write, read, and stream consumption. A timed-out or cancelled
task is cancelled and drained before the public call returns.

Deadlines require `Agent.io`. Cancellation remains cooperative without a
runtime; with `Agent.io`, ZigAI also races the token against in-flight work.
Terminal control errors are `RunTimedOut`, `Cancelled`,
`RunControlRequiresIo`, and `RunControlConcurrencyUnavailable`. Callback
contexts expose the shared `RunControl`, and `ToolRunContext` exposes its
absolute `deadline` for nested work.

Preemptive control requires the runtime to schedule the operation and each
active deadline or cancellation watcher concurrently. If it cannot,
`RunControlConcurrencyUnavailable` or `ToolConcurrencyUnavailable` is returned
instead of running a watcher inline and risking a stalled caller.

A paused run ends its invocation. `resumeRunWithOptions` starts a new monotonic
budget because a process-local monotonic timestamp cannot be serialized safely
across restarts.

## Retry policy

Retry decisions classify rate limits, server errors, request timeouts,
connection failures, and provider-response decoding independently. Optional
exponential backoff uses full jitter from the application's `Io`, honors
numeric and HTTP-date `Retry-After`, and remains interruptible. The policy's
`max_total_delay_ms` bounds cumulative backoff across the run. A fallible
before-retry hook observes the planned and cumulative delay, rate-limit values,
and the bounded provider request ID.

The HTTP transport copies provider request IDs into bounded inline storage.
Provider error observers and retry hooks receive borrowed views; copy a value
to retain it. `ProviderConnectionError` and `ProviderResponseDecodeError` are
stable retry categories.

`ProviderError.body` is empty by default. Set
`Agent.provider_error_policy.capture_body` or `ModelRequest.error_policy` to
opt in, and choose `max_body_bytes`; exact-limit bodies are complete and larger
bodies set `body_truncated`. Provider messages and codes have independent caps.
The observer is synchronous and infallible, so none of its borrowed fields may
be retained without copying.

`RunOptions.correlation` supplies a stable orchestration run ID, node ID, and
node name. Lifecycle hooks receive it on `run_start`. OpenTelemetry exports it
as `zigai.run.id`, `zigai.graph.node.id`, and `zigai.graph.node.name` on the run
span and start event. `RunOptions.telemetry_parent` remains the trace parent.

`RunOptions.request_id` supplies provider-facing correlation. OpenAI and
OpenAI-compatible adapters send it as `x-client-request-id`. Generation APIs
do not share a portable idempotency header, so official adapters do not claim
one. A compatible gateway may configure `Client.idempotency_header`; its model
profile then requests a generated key that remains stable across one logical
request's retries. This requires `Agent.io`.

## Context budgets

`Agent.context_budget` measures the provider-facing request after history
processors and dynamic toolsets have run. Separate limits cover prompt text,
tool traffic and definitions, JSON schemas, raw media sources, estimated input
tokens, and combined input/output capacity. `reserve_output_tokens` is removed
from `max_total_tokens`; when it is null, the resolved `ModelSettings.max_tokens`
is reserved instead. Exact boundaries are accepted.

The default estimate is deliberately provider-neutral: four measured bytes per
token plus fixed message and tool framing. `TokenEstimator` receives borrowed
`ContextBudget.Input` and `ByteUsage` values for provider-specific counting.
Estimator and overflow callbacks run under the invocation's deadline and
cancellation control.

On overflow, `ContextOverflowHook` receives the measured snapshot, first failed
boundary, and borrowed request view. It may return a borrowed history subslice
or allocate replacement messages from the supplied arena. ZigAI measures the
result once more; a remaining overflow becomes `ContextPromptTooLarge`,
`ContextToolsTooLarge`, `ContextSchemaTooLarge`, `ContextMediaTooLarge`, or
`ContextTokenLimitExceeded`. Callback rejection errors pass through unchanged.
Only the provider-facing view is compacted; owned result history remains
complete. `RunOptions.context_budget` replaces the agent policy for one run.

## Tool execution limits

`Agent.tool_limits` applies `zigai.ToolLimits` to local calls. The defaults are
eight concurrent calls, a 64-call queue, a 1 MiB result, 16 follow-up messages,
and 1 MiB of aggregate follow-up strings and binary data. `Tool.limits` may
tighten that policy for one tool, including an optional `timeout_ms`; it can
never loosen the agent-wide envelope.

Parallel batches preserve provider call order while the scheduler respects
both the agent-wide and per-tool concurrency and queue limits. `ToolTimedOut`,
`ToolQueueOverflow`, `ToolResultTooLarge`, and `ToolFollowUpOverflow` are
recoverable tool failures by default and are sent to the model through the
normal bounded retry path. Run deadline failures, `ToolIsolationRequiresIo`,
cancellation, allocation failure, and unavailable runtime concurrency remain
fatal. Tools should use `ToolRunContext.io` for blocking I/O and propagate
cancellation errors instead of swallowing them.

Public operations intentionally use inferred error unions. Allocator, network,
process, application callback, tool, hook, exporter, and custom model errors
pass through unchanged, so callers can handle their own errors without ZigAI
erasing them. Match the named errors that matter and propagate the remainder.

## Compatibility imports

`zigai.providers.<name>` is the preferred provider spelling. The original
`zigai.openai`, `zigai.anthropic`, `zigai.google`, and
`zigai.openai_compatible` aliases remain supported for the 0.x series.

The package also exports standalone `zopenai`, `zanthropic`, `zgoogle`, and
`zopenai_compatible` modules. They expose the same provider constants, error
set, client, and public codec functions, and can be imported together with
`zigai` in one executable.

## Versioning

ZigAI follows semantic versioning. During 0.x, a minor release may make a
documented public API change. Patch releases preserve source compatibility for
the supported surface described here. Provider wire behavior may evolve when
an upstream API changes, with real recorded cassettes covering the supported
adapters and model families.
