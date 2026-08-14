# ZigAI

Build agents in Zig. Bring the model you want.

ZigAI is a small, provider-independent agent framework with first-party API
clients. There is no hidden graph and no framework inside the framework. An
agent sends messages to a model, executes requested tools, returns their
results, and stops when the model has an answer.

It is early, but that complete loop already works with the OpenAI Responses
API, Anthropic Messages API, and Google Gemini GenerateContent API.

## Why ZigAI?

LLM APIs look similar until they don't. OpenAI returns a `function_call` item.
Anthropic returns a `tool_use` content block. Their authentication, message
history, structured output, and model capabilities are different too.

ZigAI keeps those differences at the edge:

```text
your application -> Agent -> Model -> zopenai, zanthropic, or zgoogle -> HTTP
                         -> Tool
```

The `ModelProfile` describes what a model supports before a request is sent.
This idea is inspired by PydanticAI's model profiles: capabilities belong to a
model, while encoding and transport belong to a provider. ZigAI deliberately
uses a direct loop instead of an internal graph abstraction.

## A complete agent

```zig
const std = @import("std");
const zigai = @import("zigai");

fn weather(_: *anyopaque, allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    // Validate `arguments` in a real application.
    _ = arguments;
    return allocator.dupe(u8, "{\"temperature_c\":31}");
}

// Create an HttpTransport with the allocator and Io supplied by your program,
// then pass http.transport() here.
var openai = zigai.openai.Client{
    .model_name = "gpt-5",
    .api_key = openai_api_key,
    .transport = transport,
};
var unused: u8 = 0;
const get_weather = zigai.Tool{
    .definition = .{
        .name = "weather",
        .description = "Get the current weather for a city.",
        .parameters_json_schema =
            \\{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
        ,
    },
    .context = &unused,
    .executeFn = weather,
};

var result = try (zigai.Agent{
    .model = openai.model(),
    .tools = &.{get_weather},
    .system_prompt = "Be concise.",
}).run(allocator, "What is the weather in Madrid?");
defer result.deinit();

std.debug.print("{s}\n", .{result.output});
```

Simple tools use `executeFn` as above. A tool that sets
`executeWithContextFn` also receives `ToolRunContext`; its `dependency(T)`
helper recovers the run's typed dependency pointer and it exposes cumulative
usage plus the current model-request count.

For a typed tool, define a plain Zig function whose first argument is a struct
and derive the tool at comptime:

```zig
fn weatherTyped(args: struct { city: []const u8, days: ?u8 = null }) !struct { temperature_c: i32 } {
    _ = args;
    return .{ .temperature_c = 31 };
}

const get_weather_typed = zigai.reflect.tool(
    "weather",
    "Get the current weather for a city.",
    weatherTyped,
);
```

`reflect.tool` decodes JSON arguments, encodes non-string results as JSON, and
derives the parameter schema from the argument type. `reflect.toolsOf` derives
all public functions in a namespace; `reflect.schemaOf` exposes schema
generation independently.

`CancellationToken` provides cooperative loop checks and interrupts in-flight
buffered or streaming HTTP requests. `request_timeout_ms` applies the same
deadline to either request mode. Transient provider failures and timeouts can
use opt-in exponential backoff by setting `RetryPolicy.backoff` and supplying
the agent's `io`; numeric `Retry-After` is honored and capped by the configured
maximum. `RetryPolicy.before_retry` remains available as a fallible hook and
receives the computed delay plus provider rate-limit metadata.

Switching providers changes the client, not the agent or its tools:

```zig
var anthropic = zigai.anthropic.Client{
    .model_name = "claude-sonnet-4-5",
    .api_key = anthropic_api_key,
    .transport = transport,
};

var google = zigai.google.Client{
    .model_name = "gemini-2.5-flash-lite",
    .api_key = gemini_api_key,
    .transport = transport,
};
```

Gateways and local servers that implement Chat Completions use
`zigai.openai_compatible.Client` (or `zopenai_compatible`). It targets
`<base_url>/chat/completions` and includes `full`, `basic`, and `minimal`
capability profiles, configurable provider labels, structured output, complete
tool history, streaming tool fragments, and optional stream-usage collection.

Ask either provider for a strict schema without changing the loop:

```zig
.output = .{ .json_schema = .{
    .name = "weather_answer",
    .schema = "{\"type\":\"object\",\"properties\":{\"temperature_c\":{\"type\":\"number\"}},\"required\":[\"temperature_c\"],\"additionalProperties\":false}",
} },
.validate_output_locally = true,
```

The agent checks the model profile before making the request. OpenAI receives
`text.format`, Anthropic receives `output_config.format`, and Gemini receives
`generationConfig.responseJsonSchema`. Optional local validation accepts JSON
object mode plus a practical schema subset: `type`, `enum`, `anyOf`, `oneOf`,
object properties/required/additional properties, array items, length/item
bounds, and numeric bounds. Invalid JSON, invalid schema JSON, and schema
mismatches are distinct errors. In streaming mode deltas are untrusted; only a
successfully validated response receives `final_output`.

## Tests that do not call the internet

Provider tests replay checked-in HTTP cassettes. They cover the public agent
behavior—from prompt to provider JSON to tool execution and back—without
spending tokens or exposing API keys. Replay is strict: changing the wire
request breaks the test and makes the API change visible. A recording transport
can wrap the live HTTP transport and serialize the successful interactions;
headers are never recorded, so API keys are excluded by construction.
Recorders can also apply a `JsonFieldFilter` recursively to recorded request or
response bodies—for example, to omit volatile `id` and `created` fields—without
changing the live body. Custom body filters cover formats such as SSE.

Set `ZIGAI_CASSETTE_PATH` on any provider CLI to atomically capture its live
interaction after a successful run:

```console
ZIGAI_CASSETTE_PATH=tests/cassettes/openai_smoke.json \
  OPENAI_API_KEY=... zig-out/bin/zigai-openai "Reply with exactly: pong"
```

The destination is replaced only after the complete JSON file is flushed and
synced. Review recorded bodies before committing because prompts and model
responses are intentionally preserved.

Run every local gate with:

```console
./scripts/check
```

This checks formatting, compiles all public modules as the Zig linter/type
checker, and runs unit plus high-level cassette tests. The project targets Zig
0.16.0.

`./scripts/test-cli` drives all three binaries through the real HTTP transport
against a deterministic local provider fixture. On Linux, `./scripts/coverage`
enforces 100% line coverage and verifies that every Zig file under `src/` is
present in the report.

## Command-line clients

Install the small provider clients with `zig build`. They read credentials
from the environment and print only the final model response to stdout:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai "Why is the sky blue?"
ANTHROPIC_API_KEY=... zig-out/bin/zigai-anthropic "Why is the sky blue?"
GEMINI_API_KEY=... zig-out/bin/zigai-google "Why is the sky blue?"
```

Add `--stream` before the prompt to write text deltas as the provider sends
them:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai --stream "Why is the sky blue?"
```

Each CLI can run provider-requested tools from an explicit manifest:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai \
  --tools tools.json "Use my local weather tool"
```

The manifest is a JSON array of `name`, `description`, `parameters`, and
`command` entries. `command` is an argv array; ZigAI launches it directly (no
shell expansion), appends the model's arguments JSON as the final argument,
and uses stdout as the tool result. Non-zero exits fail the run. The same
manifest works with the Anthropic and Google CLIs and with `--stream`.

Library users call `Agent.runStream` with an `AgentStreamSink`. The sink also
receives model tool-call deltas, completed calls, usage snapshots, executed
tool results, and the final output. Events are borrowed and synchronous. A
stream that has exposed any event is never retried, preventing duplicate text
or tool actions.

Set `OPENAI_MODEL`, `ANTHROPIC_MODEL`, or `GEMINI_MODEL` to override the
documented defaults. The matching `*_BASE_URL` variables support gateways and
local fixtures. `./scripts/test-live` requires OpenAI and Anthropic keys and
also checks Google when `GEMINI_API_KEY` is set.

`zig build examples` compiles one small program per provider from `examples/`.
They use the same environment keys and show the client-to-agent setup without
CLI argument handling.

Generate the API reference with `zig build docs` (or `./scripts/docs`). Zig's
autodoc output is written to `zig-out/docs/index.html`.

## Agentic maintenance

The repository includes four GitHub Agentic Workflows for failed-CI diagnosis,
documentation drift, provider/dependency compatibility, and incremental test
improvements. Their Markdown sources and generated `.lock.yml` files live in
`.github/workflows/`. Recompile them after frontmatter changes with:

```console
gh aw compile --strict --validate
```

The Codex engine reads `CODEX_API_KEY` or `OPENAI_API_KEY` from GitHub Actions
secrets. Agent jobs have read-only repository permissions. They cannot create
issues, comments, or merges; a change can leave the workflow only as one
file-scoped, non-draft pull request produced by gh-aw's safe-output job.
Protected files retain the `request_review` policy, and every PR must be
reviewed and merged by a maintainer.

## Status

The planned pre-release framework scope is implemented and verified, including
100% measured line coverage. ZigAI remains experimental rather than a stable
release, so the public API may still change. See [the roadmap](TODO.local.md)
for the exact implementation record and the release checklist in
[`docs/releasing.md`](docs/releasing.md) before publishing a version.

Release mechanics and required verification are documented in
[`docs/releasing.md`](docs/releasing.md).

## License

ZigAI is licensed under the MIT License.
