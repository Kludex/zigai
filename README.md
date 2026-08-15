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
- Provider-managed web search and fetch behind model capability checks.
- Images, audio, documents, binary data, and provider file references.
- Static and per-step dynamic toolsets with namespaces and metadata.
- MCP toolsets over Streamable HTTP and stdio.
- Serializable approval and deferred-tool pauses.
- Static, dynamic, and run-specific instructions.
- Typed output plus JSON-object and JSON Schema modes.
- Preserved finish reasons with distinct truncation, filtering, and incomplete-call errors.
- Timeouts, cancellation, retries, backoff, and usage limits.
- Readable YAML cassettes, including a real-model compatibility matrix.
- Dataset evaluations with deterministic and optional model-graded checks.
- Small command-line clients for OpenAI, Anthropic, and Google.

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

    var client = zigai.providers.openai.Client{
        .model_name = "gpt-5-mini",
        .api_key = key,
        .transport = http.transport(),
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
`ToolDefinition.return_json_schema`. To add context for the next model step,
return `ToolReturn(T)`:

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

## Providers

The agent and tools stay the same when the provider changes.

| Provider | API |
| --- | --- |
| `zigai.providers.openai` | OpenAI Responses |
| `zigai.providers.anthropic` | Anthropic Messages |
| `zigai.providers.google` | Gemini GenerateContent |
| `zigai.providers.azure_openai` | Azure OpenAI v1 |
| `zigai.providers.bedrock` | Amazon Bedrock Mantle |
| `zigai.providers.cerebras` | Cerebras Inference |
| `zigai.providers.cohere` | Cohere Compatibility API |
| `zigai.providers.deepseek` | DeepSeek |
| `zigai.providers.doubleword` | Doubleword |
| `zigai.providers.groq` | Groq |
| `zigai.providers.huggingface` | Hugging Face Inference Providers |
| `zigai.providers.mistral` | Mistral AI |
| `zigai.providers.openrouter` | OpenRouter |
| `zigai.providers.ovhcloud` | OVHcloud AI Endpoints |
| `zigai.providers.pydantic_gateway` | Pydantic AI Gateway |
| `zigai.providers.together` | Together AI |
| `zigai.providers.openai_compatible` | Chat Completions-compatible servers |

```zig
var client = zigai.providers.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .api_key = anthropic_api_key,
    .transport = http.transport(),
};
```

Compatible providers use the same three fields. Azure and Bedrock also expose
`apiBase` helpers because their endpoints depend on the resource or region:

```zig
const base_url = try zigai.providers.azure_openai.apiBase(
    allocator,
    azure_endpoint,
);
defer allocator.free(base_url);

var client = zigai.providers.azure_openai.Client{
    .model_name = "gpt-4o",
    .api_key = azure_api_key,
    .transport = http.transport(),
    .base_url = base_url,
};
```

Each model exposes a `ModelProfile`. The profile tells the agent which
capabilities are supported before it sends a paid request.

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

A content source can be raw bytes, a URL, or a provider file ID or URI. Set
`ProviderFile.provider` to guard a stored file against use with the wrong
provider. Use the model's provider name: `openai`, `anthropic`, or
`gcp.gen_ai`. Message and content metadata stay in ZigAI history and are not
sent to providers.

| Provider | Rich input |
| --- | --- |
| OpenAI | Images, documents, binary files |
| Anthropic | Images, documents |
| Google | Images, audio, documents, binary files |

Anthropic and Google thinking parts, opaque signatures, and Gemini media
signatures are preserved across history and follow-up turns. Unsupported
content fails before the first request.

Gemini tool schemas are converted to its supported JSON Schema subset. Thinking
models' encrypted tool-call signatures are preserved automatically across
follow-up requests and serialized message history.

The original top-level imports and standalone `zopenai`, `zanthropic`,
`zgoogle`, and `zopenai_compatible` packages remain available and can coexist
with the unified `zigai` import.

See [Architecture](docs/architecture.md) for the provider contract and direct
loop design.

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
(`system_prompt`, `user_prompt`, `tool_return`, or `retry_prompt`), while
responses use `ResponsePart` for text, thinking, files, and tool calls.

Version 2 preserves request state and instructions plus response usage, finish
reason, provider identity, response ID, and raw provider details. The parser
also migrates version-1 role-based ZigAI histories.

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

## Capabilities

Capabilities package one reusable agent feature:

```zig
const capability = zigai.Capability{
    .tools = &tools,
    .instructions = &.{.{ .text = "Use the knowledge base." }},
    .model_settings = .{ .reasoning_effort = .medium },
};

const agent = zigai.Agent{
    .model = model,
    .capabilities = &.{capability},
};
```

A capability can contribute tools, provider-managed tools, toolsets,
instructions, history processors, hooks, model settings, and a model selector.
Multiple capabilities apply from left to right. Duplicate tool names or
provider-managed tools fail before the first model request.

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

For a local server, start it over stdio and use the same client:

```zig
var stdio = try zigai.mcp.StdioTransport.init(
    init.io,
    &.{ "my-mcp-server", "--config", "server.json" },
);
defer stdio.deinit();

var mcp_client = zigai.mcp.Client{ .transport = stdio.transport() };
```

ZigAI implements MCP `2026-07-28`. Requests are stateless and self-describing;
there is no initialize handshake or protocol session. The client handles
discovery, every core request, pagination, SSE subscriptions, cancellation,
and multi-round-trip sampling, roots, and elicitation through an `InputHandler`.
Tool arguments marked with `x-mcp-header` are mirrored for Streamable HTTP.

The typed helpers cover tools, prompts, resources, completion, discovery, and
subscriptions. Use `Client.request` for extensions such as Tasks:

```zig
const result_json = try mcp_client.request(
    allocator,
    "tasks/get",
    "{\"taskId\":\"task-1\"}",
);
defer allocator.free(result_json);
```

`zigai.mcp.Server` provides the matching transport-neutral server dispatcher,
automatic `server/discover`, protocol and HTTP header validation, extension
dispatch, result metadata, and a stdio serving loop. HTTP hosts pass their
request headers to `Server.handle`; authorization remains an HTTP concern and
can be configured with `mcp_http.headers`.

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
cover latency, request and tool counts, retries, input and output tokens, and
optional estimated cost. The exporter is a small synchronous bridge to your
OpenTelemetry SDK or OTLP pipeline.

Prompt capture is disabled by default. Set `capture_prompts = true` only when
the destination and data policy are ready for potentially sensitive content.
Exporter failures are fail-open by default, so telemetry does not break an
agent run.

## Model settings

Generation settings use one provider-neutral type:

```zig
.model_settings = .{
    .temperature = 0.2,
    .max_tokens = 1_000,
    .stop_sequences = &.{"END"},
    .seed = 42,
    .reasoning_effort = .medium,
},
```

Defaults on `Model.settings` are overridden by `Agent.model_settings`, then by
`RunOptions.model_settings`. The model profile rejects unsupported settings
before network I/O; providers never silently discard a requested control.

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

## Streaming and resilience

Use `Agent.runStream` with an `AgentStreamSink` to receive text, tool calls,
tool results, usage, and the final output.

The same loop supports:

- cancellation with drained in-flight work;
- one run deadline plus optional per-request ceilings;
- bounded retries and exponential backoff;
- `Retry-After` and rate-limit metadata;
- request and token budgets.

A stream is never retried after it exposes visible output. This prevents
duplicated text and repeated tool actions.

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
they are not part of the library or command-line clients.

Read [Testing](docs/testing.md) for coverage and cassette details.

## More documentation

- [Architecture](docs/architecture.md)
- [Public API and ownership](docs/api.md)
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
