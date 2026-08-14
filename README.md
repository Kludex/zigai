# ZigAI

Build agents in Zig. Bring the model you want.

ZigAI is a provider-independent agent framework with first-party clients for
OpenAI, Anthropic, and Google Gemini.

It gives you one small agent loop:

```text
prompt -> model -> tool calls -> tool results -> final answer
```

There is no hidden graph. Providers handle wire formats; the agent handles the
conversation.

> [!NOTE]
> ZigAI is experimental. The planned pre-release scope is implemented, but the
> public API may still change.

## What you get

- One agent API across supported providers.
- Buffered and streaming responses.
- Tool calls, including parallel calls and typed Zig functions.
- Static and per-step dynamic toolsets with namespaces and metadata.
- Static, dynamic, and run-specific instructions.
- Typed output plus JSON-object and JSON Schema modes.
- Preserved finish reasons with distinct truncation, filtering, and incomplete-call errors.
- Timeouts, cancellation, retries, backoff, and usage limits.
- Readable YAML cassettes for deterministic provider tests.
- Small command-line clients for every first-party provider.

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

## Providers

The agent and tools stay the same when the provider changes.

| Provider | API |
| --- | --- |
| `zigai.providers.openai` | OpenAI Responses |
| `zigai.providers.anthropic` | Anthropic Messages |
| `zigai.providers.google` | Gemini GenerateContent |
| `zigai.providers.openai_compatible` | Chat Completions-compatible servers |

```zig
var client = zigai.providers.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .api_key = anthropic_api_key,
    .transport = http.transport(),
};
```

Each model exposes a `ModelProfile`. The profile tells the agent which
capabilities are supported before it sends a paid request.

The original top-level imports and standalone `zopenai`, `zanthropic`,
`zgoogle`, and `zopenai_compatible` packages remain available.

See [Architecture](docs/architecture.md) for the provider contract and direct
loop design.

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
run. Instructions are sent again for every model request in that run, but are
not stored in `result.messages`. This makes the result safe to reuse as message
history without carrying instructions from an earlier run.

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

A capability can contribute tools, instructions, hooks, model settings, and a
model selector. Multiple capabilities apply from left to right. Duplicate tool
names fail before the first model request.

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

## Lifecycle hooks

`Agent.hooks` and capability hooks receive the same ordered event stream. It
covers run boundaries, model requests, tool validation and execution, output
validation, errors, retries, and stream events before and after delivery.

Hook values are borrowed and callbacks run synchronously. Copy only what you
need to retain. A hook error stops the run and is reported through `run_error`.

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

- cooperative cancellation;
- per-request deadlines;
- bounded retries and exponential backoff;
- `Retry-After` and rate-limit metadata;
- request and token budgets.

A stream is never retried after it exposes visible output. This prevents
duplicated text and repeated tool actions.

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
