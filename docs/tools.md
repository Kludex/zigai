# Tools

A tool is a Zig function the model can call. ZigAI derives the JSON Schema
from your types, decodes the model's arguments, calls the function, and
encodes the result. You write ordinary Zig; the wire format is not your
problem.

## Typed tools

```zig
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

const tools = [_]zigai.Tool{
    zigai.reflect.tool(
        "weather",
        "Get the current weather for a city.",
        weather,
    ),
};

const agent = zigai.Agent{
    .model = client.model(),
    .tools = &tools,
    .io = init.io,
};
```

You can also build tools manually when you need complete control. Invalid
arguments and recoverable failures are returned to the model as error
results, bounded independently for each tool by `Tool.max_retries` or the
agent's `max_tool_retries` default. Parallel calls run concurrently through
`Agent.io`, keep the model's original result order, and count toward
`limits.max_tool_calls` across the full run.

Reflected tools also expose the return type as
`ToolDefinition.return_json_schema`. It stays local by default. Set
`return_schema_visibility = .model_description` to include it in the portable
provider-visible description.

## Execution limits

Local tools use bounded execution defaults: at most eight calls run at once,
64 may wait, and one result or all follow-up data may use at most 1 MiB. Set
`Agent.tool_limits` for the run; `Tool.limits` may tighten it for one tool.
Set `Tool.sequential` when a call must not overlap any other local tool.
Timeouts require `Agent.io`.

!!! note "Overflow is recoverable"
    Timeout, queue, result-size, and follow-up-size failures become ordinary
    error tool results, so the model can recover without replaying a
    successful call.

## Follow-up messages

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

## Toolsets

Toolsets group tools that belong together:

```zig
const database = zigai.Toolset{
    .tools = &.{ search, fetch },
    .namespace = "db",
};

const agent = zigai.Agent{
    .model = model,
    .toolsets = &.{database},
};
```

The model sees `db__search` and `db__fetch`. A `prepareFn` can enable or
disable tools before each model step using the current messages, usage,
request count, and typed dependencies. Tool, toolset, and prepared-entry
metadata is available to lifecycle hooks, but is not sent to the provider.

## Tool policies

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

## Approval and deferred tools

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

## Provider-managed tools

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
before the request.

!!! warning "Requests fail locally, not silently"
    OpenAI does not currently expose standalone web fetch, so an agent
    requesting it fails locally instead of silently changing behavior. This
    is the general rule: a capability the profile does not support is
    rejected before any paid request.
