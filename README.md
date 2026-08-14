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
- Static, dynamic, and run-specific instructions.
- JSON-object and JSON Schema output modes.
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
    }).run(init.gpa, "What is the weather in Madrid?");
    defer result.deinit();

    std.debug.print("{s}\n", .{result.output});
}
```

`reflect.tool` derives the JSON Schema, decodes the model's arguments, calls
the Zig function, and encodes its result. You can also build tools manually
when you need complete control.

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

## Structured output

Request a strict schema without changing the agent loop:

```zig
.output = .{ .json_schema = .{
    .name = "weather_answer",
    .schema =
        \\{"type":"object","properties":{"temperature_c":{"type":"number"}},"required":["temperature_c"],"additionalProperties":false}
    ,
} },
.validate_output_locally = true,
```

Providers use their native constrained-output formats. Optional local
validation adds a final provider-independent check.

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
