# ZigAI

Build agents in Zig. Bring the model you want.

ZigAI is a provider-independent agent framework with native and
OpenAI-compatible provider clients.

It gives you one small agent loop:

```text
prompt -> model -> tool calls -> tool results -> final answer
```

There is no hidden graph. Providers handle wire formats; the agent handles the
conversation.

## What you get

- One agent API across supported providers.
- Buffered and streaming responses.
- Tool calls, including parallel calls and typed Zig functions.
- Provider-managed search, fetch, code execution, file search, and remote MCP.
- Images, audio, documents, binary data, and provider file references.
- Static and per-step dynamic toolsets with namespaces and metadata.
- Eager and on-demand capability bundles with dependencies and scoped composition.
- MCP toolsets over Streamable HTTP and stdio.
- Serializable approval and deferred-tool pauses.
- Static, dynamic, and run-specific instructions.
- Strict JSON/YAML agent specifications with explicit environment policy.
- Typed output plus JSON-object and JSON Schema modes.
- Preserved finish reasons with distinct truncation, filtering, and incomplete-call errors.
- Timeouts, cancellation, retries, backoff, and usage limits.
- Readable YAML cassettes, including a real-model compatibility matrix.
- Dataset evaluations with deterministic and optional model-graded checks.
- Small command-line clients for OpenAI, Anthropic, and Google.
- A network-free agent-spec validator.

## Quick start

ZigAI targets Zig 0.16.0.

```console
zig build
```

Here is a complete OpenAI agent with a typed tool:

```zig
const std = @import("std");
const zigai = @import("zigai");

const WeatherArgs = struct {
    city: []const u8,
};

const Weather = struct {
    temperature_c: i32,
};

fn weather(args: WeatherArgs) !Weather {
    _ = args;
    return .{ .temperature_c = 31 };
}

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("OPENAI_API_KEY") orelse
        return error.MissingApiKey;

    var http = zigai.transport.HttpTransport.init(init.gpa, init.io);
    defer http.deinit();

    var provider = zigai.providers.openai.Provider.init(key, http.transport());
    var client = zigai.providers.openai.Client{
        .model_name = "gpt-5-mini",
        .provider = provider.provider(),
    };

    const tools = [_]zigai.Tool{
        zigai.reflect.tool(
            "weather",
            "Get the current weather for a city.",
            weather,
        ),
    };

    var result = try (zigai.Agent{
        .model = client.model(),
        .tools = &tools,
        .system_prompt = "Be concise.",
        .io = init.io,
    }).run(init.gpa, "What is the weather in Madrid?");
    defer result.deinit();

    std.debug.print("{s}\n", .{result.output});
}
```

`reflect.tool` derives the JSON Schema, decodes the model's arguments, calls
the Zig function, and encodes its result. You can also build tools manually
when you need complete control. Invalid arguments and recoverable failures are
returned to the model as error results, bounded independently for each tool by
`Tool.max_retries` or the agent's `max_tool_retries` default. Parallel calls
run concurrently through `Agent.io`, keep the model's original result order,
and count toward `limits.max_tool_calls` across the full run.

Local tools use bounded execution defaults: at most eight calls run at once,
64 may wait, and one result or all follow-up data may use at most 1 MiB. Set
`Agent.tool_limits` for the run; `Tool.limits` may tighten it for one tool.
Set `Tool.sequential` when a call must not overlap any other local tool.
Timeouts require `Agent.io`. Timeout, queue, result-size, and follow-up-size
failures become ordinary error tool results so the model can recover without
replaying a successful call.

Set `Agent.run_timeout_ms` for one monotonic deadline across the complete run.
`RunOptions.timeout_ms` can tighten it for one invocation, while
`request_timeout_ms` remains a per-model-attempt ceiling. The remaining run
time is passed through provider HTTP work, streaming, retries, tools, MCP, and
application callbacks. Timed-out or cancelled tasks are drained before the
agent returns, so they cannot write into result state later. Run deadlines
require `Agent.io`; a resumed approval starts a fresh invocation deadline.

Reflected tools also expose the return type as
`ToolDefinition.return_json_schema`. It stays local by default. Set
`return_schema_visibility = .model_description` to include it in the portable
provider-visible description.

To add context for the next model step, return `ToolReturn(T)`:

```zig
fn lookup(args: LookupArgs) !zigai.ToolReturn(Weather) {
    return .{
        .value = .{ .temperature_c = 31 },
        .follow_up_messages = &.{.{
            .parts = &.{.{ .user_prompt = .{ .text = "The reading came from the roof sensor." } }},
        }},
    };
}
```

The typed value becomes the normal tool result. Follow-up requests are copied
after it, in tool-call order, and checked before the next model request. They
can contain only `user_prompt` parts. Manual tools can return the same shape
through `Tool.executeOutputFn`.

## Agent specifications

Agent configuration can live in strict JSON or YAML without coupling parsing
to provider clients or application code. Secrets use explicit environment
references; interpolation and environment names are denied until the
application allows them.

```console
zigai-agent-spec validate agent.yaml --allow-env OPENAI_API_KEY
```

Validation performs no network requests. Applications provide the provider,
model, and capability resolvers used to build the final `Agent`. See
[Agent specifications](docs/agent-specs.md) for the schema, ownership rules,
interpolation policy, and CLI options.

## Providers

The agent and tools stay the same when the provider changes.

The clean provider boundary is `zigai.Provider`: it owns authenticated HTTP,
the API root, request policy, model discovery, file operations, and profile
overrides. Model adapters own only their wire format and borrow the provider
state for every request. `zigai.providers.http.Configured` supplies the shared
HTTP implementation, including credential-safe error reporting. Discovery and
file results are explicitly arena-owned.

Every module in the table exposes the same split: keep its `Provider` at a
stable address, then give `provider.provider()` to the corresponding `Client`.
Use `Provider.initWithOptions` for custom API roots, headers, request policy,
authentication style, or model profile overrides.

| Provider | API |
| --- | --- |
| `zigai.providers.openai` | OpenAI Responses |
| `zigai.providers.anthropic` | Anthropic Messages |
| `zigai.providers.google` | Gemini GenerateContent |
| `zigai.providers.vertex_ai` | Gemini GenerateContent on Google Cloud Vertex AI |
| `zigai.providers.azure_openai` | Azure OpenAI v1 Responses and Chat Completions |
| `zigai.providers.bedrock` | Amazon Bedrock Converse; Mantle Chat Completions |
| `zigai.providers.xai` | xAI Responses; explicit Chat Completions compatibility |
| `zigai.providers.zai` | Z.AI GLM Chat Completions |
| `zigai.providers.cerebras` | Cerebras Inference |
| `zigai.providers.cohere` | Cohere v2 Chat; explicit Compatibility API |
| `zigai.providers.crusoe` | Crusoe Serverless Inference |
| `zigai.providers.deepseek` | DeepSeek |
| `zigai.providers.doubleword` | Doubleword |
| `zigai.providers.groq` | Groq |
| `zigai.providers.huggingface` | Hugging Face Inference Providers |
| `zigai.providers.mistral` | Mistral Conversations; explicit Chat Completions compatibility |
| `zigai.providers.ollama` | Local Ollama through OpenAI-compatible Chat Completions |
| `zigai.providers.openrouter` | OpenRouter |
| `zigai.providers.ovhcloud` | OVHcloud AI Endpoints |
| `zigai.providers.pydantic_gateway` | Pydantic AI Gateway |
| `zigai.providers.snowflake` | Snowflake Cortex Chat Completions |
| `zigai.providers.together` | Together AI |
| `zigai.providers.openai_compatible` | Chat Completions-compatible servers |

```zig
var anthropic_provider = zigai.providers.anthropic.Provider.init(
    anthropic_api_key,
    http.transport(),
);
var client = zigai.providers.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .provider = anthropic_provider.provider(),
};
```

OpenAI-compatible APIs use the same provider/model split. Named providers such
as Azure OpenAI and Bedrock Mantle also expose API-base helpers because their
endpoints depend on the resource or region:

```zig
const base_url = try zigai.providers.azure_openai.apiBase(
    allocator,
    azure_endpoint,
);
defer allocator.free(base_url);

var azure_provider = zigai.providers.azure_openai.Provider.initWithOptions(
    azure_api_key,
    http.transport(),
    .{ .base_url = base_url },
);
var client = zigai.providers.azure_openai.ResponsesClient{
    .model_name = "gpt-4.1-nano",
    .provider = azure_provider.provider(),
};
```

Ollama is unauthenticated and local, so its provider makes that trust boundary
explicit. The HTTP transport must opt into the same loopback policy:

```zig
var http = zigai.transport.HttpTransport.initWithOptions(allocator, io, .{
    .url_policy = zigai.providers.ollama.local_request_policy.url_policy,
});
var provider = zigai.providers.ollama.Provider.init(http.transport());
var client = zigai.providers.ollama.Client{
    .model_name = "gpt-oss:20b",
    .provider = provider.provider(),
};
var result = try (zigai.Agent{
    .model = client.model(),
    .url_policy = zigai.providers.ollama.local_request_policy.url_policy,
}).run(allocator, "Why is the sky blue?");
```

Crusoe uses the same client boundary with bearer authentication. Set
`CRUSOE_API_KEY`; `CRUSOE_MODEL` optionally selects a vendor-qualified model or
deployment alias. The compiled example is available as `examples/crusoe.zig`.

Snowflake Cortex derives its API root from `SNOWFLAKE_ACCOUNT` and authenticates
with `SNOWFLAKE_TOKEN`. Use `snowflake.apiBase` rather than assembling an
account hostname manually; it validates the identifier before the token can be
sent. `SNOWFLAKE_MODEL` optionally selects the Cortex model.

Claude reasoning stays typed on `snowflake.Client`:

```zig
var client = zigai.providers.snowflake.Client{
    .model_name = "claude-sonnet-4-5",
    .provider = provider.provider(),
    .reasoning = .{ .effort = .high },
};
```

Choose either `effort` or `max_tokens`. Cortex requires temperature `1` for
Claude reasoning; ZigAI supplies it when absent and rejects conflicting values
before transport. Raw Snowflake extensions use the isolated `.snowflake` tag
and cannot replace the typed `reasoning` object.

Z.AI uses bearer authentication from `ZAI_API_KEY` and defaults the compiled
example to `glm-5.1`. Its client types deep-thinking controls and preserves
`reasoning_content` across buffered, streamed, and tool-turn messages:

```zig
var client = zigai.providers.zai.Client{
    .model_name = "glm-5.1",
    .provider = provider.provider(),
    .thinking = .{},
    .clear_thinking = false,
};
```

Unknown model IDs remain fail-closed. Use `CompatibilityClient` only when the
portable Chat Completions surface is sufficient.

For another Chat Completions-compatible server, start from
`examples/custom_provider.zig`. It keeps the runtime endpoint, authentication
header, provider identity, and exact model profile visible. The example uses a
fail-closed fallback, so a model outside the declared contract cannot silently
inherit the generic full-capability preset.

Use `azure_openai.ChatClient` (or its backwards-compatible `Client` alias) only
when a deployment requires Chat Completions.

Bedrock's primary `Provider` and `Client` use the native Converse API. Construct
the provider with an API key and region; use `MantleProvider`, `MantleClient`,
and `mantleApiBase` only for the OpenAI-compatible Mantle endpoint.

Mistral keeps its compatibility aliases stable: `Provider` and `Client` use
Chat Completions. Use `ConversationsProvider` and `ConversationsClient` for
native entries, managed tools, streaming, and explicit stored sessions.

Cohere follows the same compatibility rule. `Provider` and `Client` keep the
existing Compatibility API; use `ChatProvider` and `ChatClient` for native v2
messages, tool plans, strict tools, thinking, citations, and streaming.

OpenRouter keeps the Chat Completions wire format, but its routing policy is
typed on `openrouter.Client.routing`. Provider order, fallbacks, data policy,
performance preferences, and price limits never leak into the generic
compatible client. Set `include_router_metadata` to preserve the selected
route as structured provider details.

Vertex AI reuses the Gemini client instead of copying its codec. Its provider
owns the Google Cloud project, location, publisher path, regional API root, and
OAuth bearer token; Google AI Studio keeps its API-key and Files API behavior.

Every first-party and OpenAI-compatible provider can discover the models
visible to the configured credential:

```zig
var models = try openai_provider.provider().listModels(allocator);
defer models.deinit();

for (models.items) |model| {
    std.debug.print("{s}\n", .{model.id});
}
```

Discovery owns an arena so identifiers and raw provider metadata stay valid
until `deinit`. Paginated providers enforce configurable page and model limits.

Use `ModelCatalog` for trusted application metadata and aliases:

```zig
const catalog = try zigai.ModelCatalog.init(&.{.{
    .provider_name = "custom",
    .id = "chat-v2",
    .aliases = &.{"default"},
    .limits = .{ .context_window_tokens = 32_000, .max_output_tokens = 8_000 },
    .profile = .{ .supports_streaming = true },
}});
const selected = catalog.resolve("custom", "default") orelse
    return error.UnknownModel;
```

The catalog borrows its entries and returns borrowed resolutions. Validation
rejects ambiguous IDs, invalid limits, and broken replacement links.

`mergeModelDiscovery` joins a live provider list to that catalog. Its result
owns only the joined index; keep both inputs alive. Provider metadata remains
available, but only catalog profiles are exposed as trusted capabilities.

`builtin_model_catalog` is the checked-in compatibility snapshot. Update its
reviewed JSON source with `zig build update-model-catalog`; CI runs
`zig build check-model-catalog` to reject generated drift.

Each model exposes a `ModelProfile`. The profile tells the agent which
capabilities are supported before it sends a paid request.

Named OpenAI-compatible providers resolve profiles by provider and upstream
model family. Unknown families use a fail-closed profile; application lookups
can replace built-ins, and application overrides run last.

Provider-managed tools use the same agent API:

```zig
const web = [_]zigai.BuiltinTool{
    .{ .web_search = .{} },
    .{ .web_fetch = .{} },
};

const agent = zigai.Agent{
    .model = model,
    .builtin_tools = &web,
};
```

ZigAI maps these to OpenAI web search, Anthropic web search and fetch, and
Gemini Google Search and URL Context. The selected model's profile is checked
before the request. OpenAI does not currently expose standalone web fetch, so
an agent requesting it fails locally instead of silently changing behavior.

### Rich content

Add media to the current user message with `RunOptions.prompt_parts`:

```zig
const image = zigai.PromptPart{ .image = .{
    .source = .{ .bytes = image_bytes },
    .media_type = "image/png",
} };

var result = try agent.runWithOptions(
    allocator,
    "What is in this image?",
    .{ .prompt_parts = &.{image} },
);
```

A content source can be raw bytes, a URL, or a provider file ID or URI. Prefer
`UploadedFile`, which requires the owning provider. `ProviderFile` remains as a
compatibility type. Use the model's provider name: `openai`, `anthropic`, or
`gcp.gen_ai`. Message and content metadata stay in ZigAI history and are not
sent to providers.

| Provider | Rich input |
| --- | --- |
| OpenAI | Images, documents, binary files |
| Anthropic | Images, documents |
| Google | Images, audio, video, documents, binary files |

Anthropic and Google thinking parts, opaque signatures, and Gemini media
signatures are preserved across history and follow-up turns. Unsupported
content fails before the first request. Provider-owned file IDs are checked at
both the agent and adapter boundaries. Opaque provider part data is never
silently flattened by an adapter that cannot replay it.

Gemini tool schemas are converted to its supported JSON Schema subset. Thinking
models' encrypted tool-call signatures are preserved automatically across
follow-up requests and serialized message history.

The original top-level imports and standalone `zopenai`, `zanthropic`,
`zgoogle`, and `zopenai_compatible` packages remain available and can coexist
with the unified `zigai` import.

See [Architecture](docs/architecture.md) for the provider contract and direct
loop design, and [Error reference](docs/errors.md) for every stable named error.

## Model routing

Fallbacks and application routing are models themselves, so the agent loop does
not change:

```zig
var fallback = zigai.models.Fallback{
    .models = &.{primary.model(), backup.model()},
};

const agent = zigai.Agent{ .model = fallback.model() };
```

Fallbacks move in order on transient provider failures and never replay a
stream after visible output. `zigai.models.Selector` calls application code for
each request, which is useful for tenant, cost, or workload routing. A selector
declares the common `ModelProfile` guaranteed by every model it can return.

## Instructions

Instructions describe how the agent should handle the current run.

```zig
const instructions = [_]zigai.Instruction{
    .{ .text = "Answer in plain language." },
};

var result = try (zigai.Agent{
    .model = client.model(),
    .instructions = &instructions,
}).runWithOptions(allocator, "Explain allocators.", .{
    .instructions = &.{"Use one short example."},
    .message_history = previous_messages,
});
```

Dynamic instructions can read typed dependencies and are evaluated once per
run. Instructions are sent again for every model request in that run. Their
rendered value is recorded on the run's initial `RequestMessage` for provenance;
a later run still resolves and uses its own configured instructions.

## Message history

Persist and restore complete conversations with `zigai.history.stringify` and
`zigai.history.parse`. The JSON format is versioned, and parsed history has one
clear `deinit` ownership boundary.

History cannot represent invalid role/part combinations. `Message` is a tagged
union of `RequestMessage` and `ResponseMessage`. Requests use `RequestPart`
for prompts and tool results; responses use `ResponsePart` for model output.
The vocabulary includes multimodal content, uploaded files, cache points,
speech, compaction, native tools, tool search, capability loading, and
provider replay metadata. These durable types live in `zigai.messages`; common
types also have short root aliases.

Version 2 preserves the complete vocabulary, request and response state,
instructions, usage, finish reason, and provider provenance. The parser also
migrates version-1 role-based ZigAI histories.

PydanticAI JSON is a different persistence contract. Use the dedicated codec
when exchanging message documents with Python:

```zig
var document = try zigai.codecs.pydantic_ai.parse(allocator, pydantic_json);
defer document.deinit();

const encoded = try zigai.codecs.pydantic_ai.stringify(allocator, document.messages);
defer allocator.free(encoded);
```

The codec targets PydanticAI `2.31.0` and returns an owned JSON value graph so
arbitrary metadata, provider details, usage details, and tool content survive
without coercion. It does not add a ZigAI history version envelope.

History processors change only the view sent to the provider:

```zig
.history_processors = &.{
    .{ .trim = .{ .max_messages = 24 } },
    .compact,
    .provider_valid,
},
```

Processors run from left to right before each model request. Built-ins support
trimming, text compaction, provider-valid tool history, and callback-based
summaries. Custom processors can inspect current usage, request count, and the
model profile. `result.messages` still contains the full canonical history.

## Context budgets

Context budgets reject oversized requests before a provider does:

```zig
const agent = zigai.Agent{
    .model = client.model(),
    .context_budget = .{
        .max_total_tokens = 128_000,
        .reserve_output_tokens = 8_000,
        .max_prompt_bytes = 2 * 1024 * 1024,
        .max_tool_bytes = 256 * 1024,
        .max_schema_bytes = 256 * 1024,
        .max_media_bytes = 16 * 1024 * 1024,
    },
};
```

The provider-neutral estimate uses four bytes per token plus message and tool
framing. Supply `TokenEstimator` when a deployment needs its provider's exact
tokenizer. If a limit is exceeded, `ContextOverflowHook` gets one bounded chance
to return a compacted provider-facing history or reject with an application
error. The compacted view is measured again, while `result.messages` keeps the
complete canonical history. `RunOptions.context_budget` can replace the policy
for one invocation.

## Capabilities

Capabilities keep one feature together: its instructions, tools, policies,
hooks, settings, and optional model selection.

```zig
const research = zigai.Capability{
    .id = "research",
    .description = "Search the knowledge base and cite its sources.",
    .loading = .on_demand,
    .tools = &.{search_tool},
    .instructions = &.{.{ .text = "Cite every knowledge-base result." }},
};

const agent = zigai.Agent{
    .model = model,
    .capabilities = &.{research},
};
```

At first, the model sees only the capability catalog and a
`load_capability` tool. Loading `research` activates its complete bundle on the
next model request. Its instructions are returned by the load call, so they
remain in normal message history.

Capabilities may depend on other capability IDs. Dependencies load first and
the whole change is atomic. Conflicts, missing dependencies, cycles, duplicate
IDs, and malformed declarations fail deterministically.

Use `.unload_policy = .history` to restore a successful load in later runs that
receive the same history. Use `.run_end` for a capability that should survive a
paused-run continuation but disappear from a new run.

Composition always follows this order:

1. inherited
2. agent
3. run
4. nested
5. subagent

`RunOptions.capabilities` adds run-scoped bundles. `CapabilityLayer` supplies
the other scopes explicitly. Declaration order is stable within each scope;
the order of the layer slice cannot change scope precedence.

## Toolsets

Toolsets group tools that belong together:

```zig
const database = zigai.Toolset{
    .tools = &.{search, fetch},
    .namespace = "db",
};

const agent = zigai.Agent{
    .model = model,
    .toolsets = &.{database},
};
```

The model sees `db__search` and `db__fetch`. A `prepareFn` can enable or disable
tools before each model step using the current messages, usage, request count,
and typed dependencies. Tool, toolset, and prepared-entry metadata is available
to lifecycle hooks, but is not sent to the provider.

### Tool policies

Use `ToolPolicy` when behavior belongs to the agent, not to one executor. A
policy receives ordered, typed stages for preparation, arguments, approval,
the call, and its return value.

Preparation policies run after toolsets. They can change or hide a tool for
one model step, with the current messages, usage, request count, and
dependencies available through `ToolPolicyRunContext`.

Argument and return stages can transform their value or set `retry_message`.
Approval runs only after valid arguments and may select `requires_approval`
from the current dependencies and message history. The resolved arguments and
decision are persisted when the agent pauses.

### MCP toolsets

An MCP server is a normal toolset:

```zig
var mcp_http = zigai.mcp.StreamableHttpTransport.init(
    init.io,
    http.transport(),
    "https://example.com/mcp",
);
var mcp_client = zigai.mcp.Client{ .transport = mcp_http.transport() };
const remote_tools = mcp_client.toolset();

const agent = zigai.Agent{
    .model = model,
    .toolsets = &.{remote_tools},
    .io = init.io,
};
```

Streamable HTTP admits up to 64 requests at once. Set
`StreamableHttpOptions.max_in_flight` with `initWithOptions` to match the
upstream server's capacity; excess requests wait at the transport boundary.
Request-scoped SSE uses bounded, standard multi-line `data:` framing. Event
callbacks run as each complete event arrives; the final correlated response is
returned normally. Event IDs and retry hints are ignored because MCP
2026-07-28 has no session resume. HTTP transports without line streaming fall
back to the same bounded buffered parser.

For a local server, start it over stdio and use the same client:

```zig
var stdio = try zigai.mcp.StdioTransport.init(
    init.io,
    &.{ "my-mcp-server", "--config", "server.json" },
);
defer stdio.deinit();

var mcp_client = zigai.mcp.Client{ .transport = stdio.transport() };
```

Use `initWithOptions` to discard child diagnostics, change the graceful
shutdown window, or tighten the pending-request bound. Stdio is serialized;
calls beyond that bound fail with `McpStdioBackpressure` instead of growing an
unbounded queue. Closing the transport closes stdin first, then force-kills and
reaps a child that does not exit within the grace period.

ZigAI implements MCP `2026-07-28`. Requests are stateless and self-describing;
there is no initialize handshake or protocol session. The client handles
discovery, every core request, pagination, SSE subscriptions, cancellation,
and multi-round-trip sampling, roots, and elicitation through an `InputHandler`.
Its borrowed `InputRequest` carries a typed kind, key, and validated request
JSON, so handlers do not dispatch on method strings. `InputResponse` builds
validated elicitation, roots, or sampling JSON while preserving the callback's
explicit caller-owned byte lifetime.
Tool arguments marked with `x-mcp-header` are mirrored for Streamable HTTP.

Optional client behavior must be advertised on every request. Build the
standard fields with `ClientCapabilities`; the returned JSON is owned by the
caller and stays borrowed by the client:

```zig
const capabilities_json = try (zigai.mcp.ClientCapabilities{
    .roots = true,
    .sampling = .{ .context = true, .tools = true },
    .elicitation = .{ .form = true },
}).stringifyAlloc(allocator);
defer allocator.free(capabilities_json);

mcp_client.capabilities_json = capabilities_json;
```

The raw `capabilities_json` field remains the forward-compatible escape hatch.
MRTR input that was not advertised is rejected. `max_round_trips` and
`max_pages` bound retries and tool discovery.

The typed helpers cover tools, prompts, resources, completion, discovery, and
subscriptions; `SubscriptionFilter` selects list and resource updates without
hand-written JSON, while `PromptRequest` and `CompletionRequest` model their
standardized parameters. Cancellation accepts the protocol's integer-or-string
`RequestId`; `RequestOptions.metadata` adds a progress token and per-request
logging opt-in. `listenWithRecovery` can reissue a fresh stateless subscription
after a classified transport interruption. Its retry count, delay, deadline,
and cancellation are explicit; event callbacks may observe duplicates across
attempts. Tasks have typed helpers; capability negotiation and the
`Mcp-Name` task route are applied automatically:

```zig
var task = try mcp_client.getTask(allocator, "task-1");
defer task.deinit();

try mcp_client.updateTask(allocator, .{
    .task_id = "task-1",
    .input_responses_json = "{\"approval\":{\"action\":\"accept\"}}",
});
try mcp_client.cancelTask(allocator, "task-1");

var terminal = try mcp_client.waitTask(allocator, "task-1", .{ .io = io });
defer terminal.deinit();
```

Task results own a single arena. `waitTask` follows server polling hints,
handles input, and cooperatively cancels when its deadline or poll budget ends.
Task subscriptions use `SubscriptionFilter.task_ids` and
`mcp.tasks.parseNotification`.

Add a store when tasks must survive a process restart:

```zig
var task_file = zigai.mcp.task_store.FileStore.init(
    io,
    std.Io.Dir.cwd(),
    ".zigai/mcp-tasks.json",
);
mcp_client.task_store = task_file.store();

var resumed = try mcp_client.resumeTasks(allocator, .{ .io = io });
defer resumed.deinit();
```

Tool-created tasks are tracked automatically. Pending input is saved before it
is sent, so recovery replays the response instead of asking twice. The file is
atomically replaced and owner-only on POSIX; use a custom `task_store.Store`
when responses need encrypted storage. If initial persistence fails, ZigAI
attempts to cancel the newly created remote task.

Extension settings stay as owned JSON:

```zig
const settings = try zigai.mcp.extensionSettings(
    allocator,
    capabilities_json,
    "io.modelcontextprotocol/tasks",
);
defer if (settings) |json| allocator.free(json);
```

`zigai.mcp.Server` provides the matching transport-neutral server dispatcher,
automatic `server/discover`, protocol and HTTP header validation, extension
dispatch, result metadata, and a stdio serving loop. HTTP hosts pass their
request headers and TLS state to `Server.handle`. Protected endpoints use
`mcp.auth.ClientPolicy` and `mcp.auth.ServerPolicy`; browser-facing hosts add a
separate `mcp.auth.DeploymentPolicy` for exact Origin and Host checks. Bearer
tokens never enter MCP JSON or handler parameters, and refresh/step-up retries
are bounded. Core handlers run only when the matching capability appears in
the server's `capabilities_json`. `mcp.Notification` produces validated,
caller-owned JSON-RPC for server progress, cancellation, logging, updates, and
subscription acknowledgements.

See the [MCP conformance matrix](docs/mcp-conformance.md) for message coverage,
compatibility boundaries, validation, and ownership. The [security guide](docs/security.md#mcp-http-authorization)
covers OAuth discovery, token callbacks, response headers, and deployment.

### Approval and deferred tools

Mark a tool that must stop before execution:

```zig
var publish = zigai.reflect.tool(
    "publish",
    "Publish a message.",
    publishMessage,
);
publish.execution = .requires_approval;
```

Use `runUntilPause` when the agent includes one of these tools. It returns
either the final result or a pause with the pending calls and versioned JSON
state:

```zig
var outcome = try agent.runUntilPause(allocator, "Publish the update.");
defer outcome.deinit();

switch (outcome) {
    .complete => |result| useResult(result),
    .paused => |paused| persist(paused.state_json),
}
```

Resume later without repeating the model request:

```zig
var resumed = try agent.resumeRun(allocator, state_json, &.{.{
    .call_id = call_id,
    .action = .approve,
}});
defer resumed.deinit();
```

Use `.deny` with a reason to reject a call. Tools marked `.external` never
execute inside ZigAI; resume them with `.result` and the externally produced
content. `stringifyResumeDecisions` and `resumeRunJson` provide a JSON-only
handoff for queues, databases, and approval services.

## Lifecycle hooks

`Agent.hooks` and capability hooks receive the same ordered event stream. It
covers run boundaries, model requests, tool validation and execution, output
validation, errors, retries, and stream events before and after delivery.

Hook values are borrowed and callbacks run synchronously. Copy only what you
need to retain. A hook error stops the run and is reported through `run_error`.

## Structured diagnostics

`Agent.diagnostics` maps lifecycle activity to structured, leveled events. It
does not depend on a logging package; provide a `DiagnosticSink` callback that
bridges to the backend used by the application.

```zig
.diagnostics = .{
    .sink = my_diagnostic_sink,
    .minimum_level = .info,
    .sensitive_values = &.{api_token},
},
```

Prompt, output, tool arguments, and tool results are omitted unless
`capture_content = true`. String values are redacted before truncation, and
attribute counts, keys, and values have explicit byte limits. Sink failures are
fail-open by default; set `fail_open = false` when diagnostics are required for
the run to proceed. Events and attributes are borrowed for the callback only.

## Usage and cost

Every provider response has `RequestUsage`. Agent results have `RunUsage`,
which also includes request attempts, tool calls, provider latency, and total
run duration.

Cached and audio tokens are subsets of the input or output totals. Reasoning
tokens are a subset of output tokens. Provider counters without a portable
field stay available through `usage.details`.

Cost estimation is opt-in:

```zig
var result = try (zigai.Agent{
    .model = model,
    .price_table = zigai.pricing.builtin,
}).run(allocator, "Hello");
defer result.deinit();

if (result.usage.cost) |cost| {
    std.debug.print("estimated cost: ${d:.6}\n", .{cost.usd()});
}
```

`pricing.builtin` is a checked-in snapshot, not a live price feed. Its version
is available as `pricing.builtin_version`; unknown models and unpriced token
buckets produce no estimate. Pass your own `PriceTable` when you need other
models, contracts, regions, or service tiers. Money is stored as integer
nano-USD.

## OpenTelemetry

Configure `Agent.telemetry` to export OpenTelemetry-shaped spans and metrics:

```zig
.telemetry = .{
    .io = init.io,
    .exporter = my_otel_exporter,
    .cost_estimator = my_cost_estimator,
},
```

Each run has one trace with child model-request and tool-call spans. Metrics
cover latency, request and tool counts, retries, cached/reasoning/audio token
usage, and optional cost. `cost_estimator` is a telemetry-only fallback when
the agent has no provider-reported or price-table cost. The exporter is a small synchronous bridge to your
OpenTelemetry SDK or OTLP pipeline.

Prompt capture is disabled by default. Set `content.prompts` to `.raw` or
`.redacted` only when the destination and data policy are ready. Redacted mode
uses an application callback, and both modes enforce configured content and
attribute-size bounds before exporter callbacks run. Pass
`RunOptions.telemetry_parent` to continue an upstream trace.
Exporter failures are fail-open by default, so telemetry does not break an
agent run.

## Model settings

Generation settings use one provider-neutral type:

```zig
.model_settings = .{
    .temperature = 0.2,
    .max_tokens = 1_000,
    .top_p = 0.9,
    .stop_sequences = &.{"END"},
    .reasoning_effort = .medium,
    .parallel_tool_calls = false,
},
```

Defaults on `Model.settings` are overridden by `Agent.model_settings`, then by
`RunOptions.model_settings`. The model profile rejects unsupported settings
before network I/O; providers never silently discard a requested control.

The portable controls also include `top_k`, presence/frequency penalties,
log probabilities, tool choice, thinking token budgets, service tiers,
truncation, seeds, and request headers. Slices are borrowed for the request.

Provider-only request fields use a tagged, bounded JSON object:

```zig
.model_settings = .{
    .extra_body = .{ .openai = "{\"store\":false}" },
},
```

The tag must match the selected adapter. Extension objects cannot replace
fields ZigAI owns, and request headers cannot replace credentials or HTTP
framing. Prefer portable fields whenever one exists.

## Typed output

Define the result you want as a Zig type. ZigAI derives its strict JSON Schema,
asks the provider for matching JSON, and decodes the answer:

```zig
const Weather = struct {
    city: []const u8,
    temperature_c: f64,
};

var result = try agent.runTyped(Weather, allocator, "Weather in Madrid?");
defer result.deinit();

std.debug.print("{s}: {d} C\n", .{
    result.output.city,
    result.output.temperature_c,
});
```

The decoded value, original JSON in `result.output_json`, and message history
share one result arena. Keep them only until `result.deinit()`. Use
`runTypedWithOptions`, `runTypedStream`, or `runTypedStreamWithOptions` for the
corresponding run modes. Invalid output is returned to the model for up to
`max_output_retries` correction attempts.

For hand-written schemas, configure `Agent.output` with an `OutputSpec`:

```zig
const choices = [_]zigai.OutputChoice{
    .{ .name = "answer", .schema = answer_schema },
    .{ .name = "refusal", .schema = refusal_schema },
};

const agent = zigai.Agent{
    .model = model,
    .output = .{ .native = .{ .name = "result", .choices = &choices } },
};
```

`.native` sends one strict schema to a capable provider. `.prompted` appends a
schema instruction and uses JSON-object mode when available, otherwise text.
Prompted results are always checked locally and retried when invalid. Schemas,
choices, and custom prompt templates are borrowed for the run; prepared data
lives in the result arena.

Local validation uses a documented, fail-closed Draft 2020-12 subset. Invalid
or unsupported schemas fail before network I/O; see the
[API reference](docs/api.md#local-json-schema-dialect) for the exact vocabulary.

`.tool` exposes one output tool per choice, so unions stay as small independent
schemas and `result.output_name` identifies the selected branch. Scalar schemas
are wrapped for provider tool contracts and unwrapped before returning. A
choice can attach an `OutputFunction`; it receives validated arguments and may
return a final value or a safe retry message. `Agent.end_strategy` controls
ordinary calls emitted beside output: `.early` skips them, `.graceful` runs
calls before the selected output, and `.exhaustive` runs every call.

Add ordered `OutputValidator` callbacks for semantic or I/O-backed checks.
Validators can transform output, request a bounded model retry with a safe
message, and inspect dependencies, history, usage, and the selected choice.
Output functions and validators run for each useful streamed snapshot with
`OutputRunContext.partial_output = true`, and once for the final candidate with
it set to false. Keep side effects in the final branch.

## Streaming and resilience

Use `Agent.runStream` with an `AgentStreamSink`. Model output arrives as an
indexed part lifecycle:

- `part_start` — initial part snapshot;
- `part_delta` — text, thinking, tool, native-tool, media, speech, or
  compaction fragment;
- `part_end` — complete part;
- `usage` — provider token totals.

Agent events add function-tool calls/results, deferred work, tool-availability
changes, enqueued messages, accumulated `partial_output` snapshots, and one
`final_result`. Raw model deltas arrive before their derived snapshot. Partial
structured JSON is repaired into a valid prefix snapshot and checked against
every assertion that cannot become valid through later bytes; final validation
still applies the complete schema. A validator retry suppresses only that
partial snapshot. `final_result` is emitted only after output validation
succeeds. Structured partial and final events include a borrowed parsed JSON
value.

Use `runUntilPauseStream` and `resumeRunStream` when approval or externally
executed tools must remain in the same event flow.

To add user work while a run is active, pass a one-run
`PendingMessageQueue` in `RunOptions`:

```zig
var pending = zigai.PendingMessageQueue.init(allocator, io);
defer pending.deinit();

try pending.enqueue(&.{.{
    .parts = &.{.{ .user_prompt = .{ .text = "Also compare Madrid." } }},
}});

var result = try agent.runStreamWithOptions(
    allocator,
    "Compare Lisbon.",
    .{ .pending_messages = &pending },
    sink,
);
defer result.deinit();
```

The queue copies each batch and applies batches FIFO between model/tool steps.
Messages accepted during a final response trigger another model step. A pause
stores them for resume; cancellation discards them. The queue closes atomically
before a final result or pause, so late submissions fail explicitly.

The same loop supports:

- cancellation with drained in-flight work;
- one run deadline plus optional per-request ceilings;
- bounded retries with full-jitter exponential backoff;
- numeric or HTTP-date `Retry-After`, rate limits, and provider request IDs;
- request and token budgets.

A stream is never retried after it exposes visible output. This prevents
duplicated text and repeated tool actions.

`Agent.retry_policy` classifies rate limits, server errors, timeouts,
connections, and malformed provider responses separately. Its cumulative
delay budget defaults to 30 seconds. Backoff is optional and requires `io`;
server-directed delays are not jittered. `RunOptions.request_id` is forwarded
by OpenAI-style providers for tracing. OpenAI-compatible gateways can name an
`idempotency_header`; ZigAI then generates one key per logical request and
reuses it for that request's retries.

Provider error observers receive parsed, bounded messages and correlation
metadata. Raw response bodies are hidden by default. Enable
`provider_error_policy.capture_body` with an explicit `max_body_bytes` only
when an application needs bounded provider diagnostics.

HTTP response allocations are bounded after decompression. The defaults accept
up to 16 MiB for a buffered body and 1 MiB for one streaming line. Use tighter
limits for a specific deployment:

```zig
var http = zigai.transport.HttpTransport.initWithLimits(init.gpa, init.io, .{
    .max_response_body_bytes = 2 * 1024 * 1024,
    .max_stream_line_bytes = 256 * 1024,
});
defer http.deinit();
```

Oversized input returns `error.ResponseTooLarge` or
`error.StreamLineTooLarge` before it can grow the response allocation further.

Untrusted JSON is also preflighted before decoding. History, deferred state,
provider responses, tools, MCP, schemas, and CLI manifests each use a reviewed
`zigai.json.Limits` profile for document size, value size, nesting, and
collection length.

## Command-line clients

`zig build` installs three small clients:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai "Why is the sky blue?"
ANTHROPIC_API_KEY=... zig-out/bin/zigai-anthropic "Why is the sky blue?"
GEMINI_API_KEY=... zig-out/bin/zigai-google "Why is the sky blue?"
```

Add `--stream` for incremental output:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai --stream "Why is the sky blue?"
```

CLIs can also expose local commands as provider-requested tools:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai \
  --tools tools.json "Use my local weather tool"
```

Commands are executed directly, without a shell. The model's arguments JSON is
appended as the final argument, and stdout becomes the tool result.

## Evaluations

Run a dataset through the same agent used by your application:

```zig
const evaluators = [_]zigai.evals.Evaluator{
    zigai.evals.containsExpected(),
};

var report = try (zigai.evals.Dataset{
    .cases = &.{.{
        .name = "weather",
        .prompt = "What is the weather in Madrid?",
        .expected_output = "sunny",
    }},
    .evaluators = &evaluators,
}).run(allocator, agent);
defer report.deinit();
```

Built-ins cover exact matches, substring checks, and valid JSON. `Evaluator`
is a small callback interface for application-specific deterministic checks.
`ModelGrader` wraps another agent, requests a typed pass/score/reason result,
and validates that its score is between zero and one.

Use `runWithOptions` when an experiment needs repeated runs or retries:

```zig
var report = try dataset.runWithOptions(allocator, agent, .{
    .repetitions = 3,
    .max_concurrency = 4,
    .io = io,
    .task_retry = .{ .max_attempts = 3 },
    .evaluator_retry = .{ .max_attempts = 2 },
    .hooks = hooks,
});
defer report.deinit();
```

Task and evaluator retry budgets are independent. A retry classifier can limit
which errors are transient, while `beforeRetryFn` can apply application-owned
backoff. Lifecycle hooks receive stable zero-based case indices, one-based
repetition and attempt numbers, and every start, error, retry outcome, and end.
The plain `run` method remains a single-run, single-attempt evaluation.
When `max_concurrency` is greater than one, ZigAI admits at most that many case
runs through the supplied `std.Io` runtime, writes them into stable source-order
slots, and aggregates usage after all work is joined. The model, evaluators,
retry callbacks, and lifecycle hooks must be thread-safe in this mode. ZigAI
serializes access to the caller allocator and the report arena.

Dataset-level `report_evaluators` run after every case and repetition has
finished. They receive a read-only `ReportView` and append named scalar
analyses with an optional assertion, unit, and reason. `Report.summary`,
`caseSummary`, and `scoreStatistics` expose pass rates plus finite-score
minimum, maximum, mean, and population standard deviation. A failed aggregate
assertion makes `Report.passed()` false.

`trace_evaluators` inspect the same `telemetry.Span` values sent to the
application exporter. Enabling them requires `Agent.telemetry`. ZigAI installs
a per-case exporter tee, deep-copies span names, attributes, IDs, timing, and
status into `CaseResult.spans`, and forwards spans and metrics unchanged. Trace
evaluators use the ordinary evaluator retry policy and add results to the same
ordered evaluation list after output evaluators.

Persist portable datasets and complete reports with `zigai.eval_io`:

```zig
const yaml = try zigai.eval_io.stringifyDatasetYaml(allocator, dataset);
defer allocator.free(yaml);

var loaded = try zigai.eval_io.parseDatasetYaml(allocator, yaml, registry);
defer loaded.deinit();
```

Dataset files store cases and evaluator names. Loading binds those names through
an explicit `EvaluatorRegistry`; callbacks and non-default per-case `RunOptions`
are never serialized. JSON and readable YAML report files retain usage,
evaluations, analyses, and telemetry spans.

Compare a candidate report with a baseline using `zigai.eval_compare`.
Comparisons preserve stable case/repetition order, classify evaluator and
aggregate-analysis changes, calculate signed usage deltas, and expose
`regressionFree()` for gating. `stringifyCiJson` emits deterministic,
versioned JSON with a `pass` or `fail` conclusion for CI artifacts.

## Security

Hosted endpoints use HTTPS-only URL validation by default. Local names,
non-public literal IPs, embedded URL credentials, and redirects are rejected
unless the application opts in. The same policy covers provider endpoints,
MCP Streamable HTTP, and rich-content URLs.

Authentication headers are marked and recognized as sensitive. Telemetry does
not receive them, and provider error observers suppress configured API keys
even when bounded raw-body capture is enabled.

Read [Security](docs/security.md) for URL allowlists, local development,
custom-transport responsibilities, and the complete trust-boundary table.

## Testing

Run the local quality gates with:

```console
./scripts/check
./scripts/test-cli
```

On Linux, enforce the coverage contract with:

```console
./scripts/coverage
```

The coverage gate is **100% of executable lines**.

Provider tests replay checked-in HTTP cassettes. They exercise the real agent,
provider adapter, tool loop, usage accounting, and error paths without calling
paid APIs. Cassettes use Cassetter-compatible YAML and stay under `tests/`;
they are not part of the library or command-line clients. The normal quality
gate audits every fixture for manifest coverage, secret safety, and stable
normalization.

Read [Testing](docs/testing.md) for coverage and cassette details.

## More documentation

- [Architecture](docs/architecture.md)
- [Public API and ownership](docs/api.md)
- [Security](docs/security.md)
- [Release notes](CHANGELOG.md)
- [Testing](docs/testing.md)
- [Releasing](docs/releasing.md)
- API reference: `zig build docs`
- Runnable examples: `zig build examples`

## Agentic maintenance

Four GitHub Agentic Workflows watch CI, documentation, provider APIs, and test
quality. Their agent jobs are read-only. The only repository write they can
request is one file-scoped pull request for maintainer review.

Recompile workflow lock files after changing their frontmatter:

```console
gh aw compile --strict --validate
```

## License

ZigAI is licensed under the MIT License.
