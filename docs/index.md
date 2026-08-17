# ZigAI

Build agents in Zig. Bring the model you want.

ZigAI is a provider-independent agent framework with native and
OpenAI-compatible provider clients. It gives you one small agent loop:

```text
prompt -> model -> tool calls -> tool results -> final answer
```

There is no hidden graph. Providers handle wire formats; the agent handles
the conversation.

## Key features

- **Typed**: tools, output, workflows, and settings are Zig types. Schemas
  are derived from your structs; invalid data fails before network I/O.
- **Provider-independent**: one agent API across OpenAI, Anthropic, Google,
  and twenty more providers. Change the provider; keep the agent and tools.
- **Explicit**: every allocation takes an allocator, every result has one
  `deinit`, every limit has a name. No hidden control flow, no ambient state.
- **Bounded**: untrusted JSON, HTTP bodies, tool results, retries, context,
  and queues all have reviewed limits. Overflow is an error, not an OOM.
- **Complete**: streaming, MCP, durable execution, typed graphs, multi-agent,
  evaluations, OpenTelemetry, and a production CLI - all under one policy for
  ownership, cancellation, and security.

## Requirements

Zig 0.16.0. Linux x86_64, Apple Silicon macOS, and Windows x86_64 are the
supported targets. See the [compatibility policy](compatibility.md).

## Installation

```console
zig fetch --save git+https://github.com/Kludex/zigai
```

## Example

A complete agent with a typed tool:

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

`reflect.tool` derives the JSON Schema from `WeatherArgs`, decodes the
model's arguments, calls the function, and encodes the result. The model
retries invalid arguments; you never parse them yourself.

Want typed output instead of text? Ask for it:

```zig
var result = try agent.runTyped(Weather, allocator, "Weather in Madrid?");
defer result.deinit();

std.debug.print("{d} C\n", .{result.output.temperature_c});
```

Want a different provider? Change two lines:

```zig
var provider = zigai.providers.anthropic.Provider.init(key, http.transport());
var client = zigai.providers.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .provider = provider.provider(),
};
```

The agent, tools, and everything else stay the same.

## Where to go next

- [Agents](agents.md) - the loop, instructions, history, context budgets,
  model routing and settings, deadlines
- [Tools](tools.md) - typed tools, toolsets, policies, approval,
  provider-managed tools
- [Providers](providers.md) - all 23 providers, discovery, catalogs,
  profiles, rich content
- [Typed output and streaming](output-and-streaming.md) - structured output,
  streaming events, retries and resilience
- [Production guide](production.md) - running agents in real services

## License

ZigAI is licensed under the MIT License.
