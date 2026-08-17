# Agents

The agent is the core of ZigAI. You give it a model, optionally some tools,
and run it. Everything else - streaming, retries, budgets - is configuration
on the same type.

## The agent loop

```text
prompt -> model -> tool calls -> tool results -> final answer
```

There is no hidden graph. Providers handle wire formats; the agent handles
the conversation.

```zig
var result = try (zigai.Agent{
    .model = client.model(),
    .system_prompt = "Be concise.",
    .io = init.io,
}).run(init.gpa, "Why is the sky blue?");
defer result.deinit();

std.debug.print("{s}\n", .{result.output});
```

The result owns its output and complete message history until `deinit`. This
gives you one clear ownership boundary per run.

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
rendered value is recorded on the run's initial `RequestMessage` for
provenance; a later run still resolves and uses its own configured
instructions.

## Message history

Persist and restore complete conversations with `zigai.history.stringify` and
`zigai.history.parse`. The JSON format is versioned, and parsed history has
one clear `deinit` ownership boundary.

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

### Exchanging messages with Python

PydanticAI JSON is a different persistence contract. Use the dedicated codec
when exchanging message documents with Python:

```zig
var document = try zigai.codecs.pydantic_ai.parse(allocator, pydantic_json);
defer document.deinit();

const encoded = try zigai.codecs.pydantic_ai.stringify(allocator, document.messages);
defer allocator.free(encoded);
```

The codec targets PydanticAI `2.31.0` and returns an owned JSON value graph
so arbitrary metadata, provider details, usage details, and tool content
survive without coercion. It does not add a ZigAI history version envelope.

### History processors

History processors change only the view sent to the provider:

```zig
.history_processors = &.{
    .{ .trim = .{ .max_messages = 24 } },
    .compact,
    .provider_valid,
},
```

Processors run from left to right before each model request. Built-ins
support trimming, text compaction, provider-valid tool history, and
callback-based summaries. Custom processors can inspect current usage,
request count, and the model profile. `result.messages` still contains the
full canonical history.

## Context budgets

Context budgets reject oversized requests before a provider does. This is the
difference between a clear error in your process and a confusing 4xx from the
provider after you already paid for the upload.

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
tokenizer. If a limit is exceeded, `ContextOverflowHook` gets one bounded
chance to return a compacted provider-facing history or reject with an
application error. The compacted view is measured again, while
`result.messages` keeps the complete canonical history.
`RunOptions.context_budget` can replace the policy for one invocation.

## Model routing

Fallbacks and application routing are models themselves, so the agent loop
does not change:

```zig
var fallback = zigai.models.Fallback{
    .models = &.{ primary.model(), backup.model() },
};

const agent = zigai.Agent{ .model = fallback.model() };
```

Fallbacks move in order on transient provider failures and never replay a
stream after visible output. `zigai.models.Selector` calls application code
for each request, which is useful for tenant, cost, or workload routing. A
selector declares the common `ModelProfile` guaranteed by every model it can
return.

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

The portable controls also include `top_k`, presence/frequency penalties, log
probabilities, tool choice, thinking token budgets, service tiers,
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

## Deadlines and cancellation

Set `Agent.run_timeout_ms` for one monotonic deadline across the complete
run. `RunOptions.timeout_ms` can tighten it for one invocation, while
`request_timeout_ms` remains a per-model-attempt ceiling. The remaining run
time is passed through provider HTTP work, streaming, retries, tools, MCP,
and application callbacks. Timed-out or cancelled tasks are drained before
the agent returns, so they cannot write into result state later.

Run deadlines require `Agent.io`; a resumed approval starts a fresh
invocation deadline.

See [the API reference](api.md#run-deadlines-and-cancellation) for the exact
control contract.

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
[Agent specifications](agent-specs.md) for the schema, ownership rules,
interpolation policy, and CLI options.
