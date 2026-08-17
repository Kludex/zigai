# Providers

The agent and tools stay the same when the provider changes. The provider
boundary is `zigai.Provider`: it owns authenticated HTTP, the API root,
request policy, model discovery, file operations, and profile overrides.
Model adapters own only their wire format and borrow the provider state for
every request.

Every module in the table exposes the same split: keep its `Provider` at a
stable address, then give `provider.provider()` to the corresponding
`Client`. Use `Provider.initWithOptions` for custom API roots, headers,
request policy, authentication style, or model profile overrides.

## Supported providers

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

## Basic usage

```zig
var anthropic_provider = zigai.providers.anthropic.Provider.init(
    anthropic_api_key,
    http.transport(),
);
var client = zigai.providers.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .provider = anthropic_provider.provider(),
};

const agent = zigai.Agent{ .model = client.model() };
```

## Providers with derived endpoints

Named providers such as Azure OpenAI and Bedrock Mantle expose API-base
helpers because their endpoints depend on the resource or region:

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

Snowflake Cortex derives its API root from `SNOWFLAKE_ACCOUNT` and
authenticates with `SNOWFLAKE_TOKEN`. Use `snowflake.apiBase` rather than
assembling an account hostname manually; it validates the identifier before
the token can be sent.

## Local providers

Ollama is unauthenticated and local, so its provider makes that trust
boundary explicit. The HTTP transport must opt into the same loopback policy:

```zig
var http = zigai.transport.HttpTransport.initWithOptions(allocator, io, .{
    .url_policy = zigai.providers.ollama.local_request_policy.url_policy,
});
var provider = zigai.providers.ollama.Provider.init(http.transport());
var client = zigai.providers.ollama.Client{
    .model_name = "gpt-oss:20b",
    .provider = provider.provider(),
};
```

## Native vs compatibility clients

Several providers offer both a native wire format and a Chat
Completions-compatible one. The rule is always the same: the existing
`Provider`/`Client` names keep their original behavior, and the native
adapter gets an explicit name.

- **Bedrock**: `Provider` and `Client` use the native Converse API. Use
  `MantleProvider`, `MantleClient`, and `mantleApiBase` for the
  OpenAI-compatible Mantle endpoint.
- **Mistral**: `Provider` and `Client` use Chat Completions. Use
  `ConversationsProvider` and `ConversationsClient` for native entries,
  managed tools, streaming, and explicit stored sessions.
- **Cohere**: `Provider` and `Client` keep the Compatibility API. Use
  `ChatProvider` and `ChatClient` for native v2 messages, tool plans, strict
  tools, thinking, citations, and streaming.
- **Azure OpenAI**: use `ChatClient` (or its backwards-compatible `Client`
  alias) only when a deployment requires Chat Completions.

## Provider-specific typed controls

Provider extensions stay typed on that provider's client instead of leaking
into the generic compatible surface.

Snowflake Cortex Claude reasoning:

```zig
var client = zigai.providers.snowflake.Client{
    .model_name = "claude-sonnet-4-5",
    .provider = provider.provider(),
    .reasoning = .{ .effort = .high },
};
```

Choose either `effort` or `max_tokens`. Cortex requires temperature `1` for
Claude reasoning; ZigAI supplies it when absent and rejects conflicting
values before transport.

Z.AI deep thinking:

```zig
var client = zigai.providers.zai.Client{
    .model_name = "glm-5.1",
    .provider = provider.provider(),
    .thinking = .{},
    .clear_thinking = false,
};
```

Its client preserves `reasoning_content` across buffered, streamed, and
tool-turn messages.

OpenRouter routing policy is typed on `openrouter.Client.routing`. Provider
order, fallbacks, data policy, performance preferences, and price limits
never leak into the generic compatible client. Set `include_router_metadata`
to preserve the selected route as structured provider details.

Vertex AI reuses the Gemini client instead of copying its codec. Its provider
owns the Google Cloud project, location, publisher path, regional API root,
and OAuth bearer token; Google AI Studio keeps its API-key and Files API
behavior.

## Custom providers

For another Chat Completions-compatible server, start from
`examples/custom_provider.zig`. It keeps the runtime endpoint, authentication
header, provider identity, and exact model profile visible.

!!! warning "Unknown models fail closed"
    The example uses a fail-closed fallback, so a model outside the declared
    contract cannot silently inherit the generic full-capability preset. Use
    `CompatibilityClient` only when the portable Chat Completions surface is
    sufficient.

## Model discovery and catalogs

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
until `deinit`. Paginated providers enforce configurable page and model
limits.

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

## Model profiles

Each model exposes a `ModelProfile`. The profile tells the agent which
capabilities are supported before it sends a paid request.

Named OpenAI-compatible providers resolve profiles by provider and upstream
model family. Unknown families use a fail-closed profile; application lookups
can replace built-ins, and application overrides run last.

## Rich content

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

A content source can be raw bytes, a URL, or a provider file ID or URI.
Prefer `UploadedFile`, which requires the owning provider. Use the model's
provider name: `openai`, `anthropic`, or `gcp.gen_ai`. Message and content
metadata stay in ZigAI history and are not sent to providers.

| Provider | Rich input |
| --- | --- |
| OpenAI | Images, documents, binary files |
| Anthropic | Images, documents |
| Google | Images, audio, video, documents, binary files |

Anthropic and Google thinking parts, opaque signatures, and Gemini media
signatures are preserved across history and follow-up turns. Unsupported
content fails before the first request. Provider-owned file IDs are checked
at both the agent and adapter boundaries. Opaque provider part data is never
silently flattened by an adapter that cannot replay it.

## Compatibility imports

The original top-level imports and standalone `zopenai`, `zanthropic`,
`zgoogle`, and `zopenai_compatible` packages remain available and can coexist
with the unified `zigai` import.
