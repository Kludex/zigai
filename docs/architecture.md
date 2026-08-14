# Architecture

ZigAI has four layers, and each one has one job.

## Model contract

`Model` is a small vtable: context, capabilities, and one request function. It
accepts provider-neutral messages and returns text or tool calls. A new
provider does not need to modify the agent.

`ModelProfile` is resolved before the agent runs. It describes model behavior
independently from the transport: tools, parallel calls, system messages,
structured JSON, and thinking. The agent rejects unsupported requested
features before sending a paid request.

Structured output is provider neutral at the agent boundary. JSON-object mode
and named, strict JSON Schema mode are encoded as `text.format` for OpenAI and
`output_config.format` for Anthropic, and `generationConfig` for Google. A
profile mismatch fails before network I/O.

Applications can opt into local structured-output validation at the final
agent boundary. It validates JSON-object mode and the documented JSON Schema
subset, regardless of whether the provider also constrains decoding. Buffered
and streaming runs share this check. Streaming deltas remain provisional, and
the agent emits `final_output` only after local validation succeeds.

Provider failures keep two layers separate. Stable error categories drive agent
retry policy, while an optional synchronous observer receives the provider
name, HTTP status, parsed code/message, and raw body. The view is borrowed;
applications copy only the detail they need to retain.

## Agent loop

`Agent.run` owns the conversation in an arena:

1. Add the system and user messages.
2. Request a model response.
3. Return its text if there are no tool calls.
4. Otherwise execute every requested tool and append the results.
5. Repeat until the model answers or the configured request limit is reached.

An agent may carry an opaque per-run dependency pointer. Contextual tools use
`ToolRunContext.dependency(T)` to recover their application type and can also
inspect cumulative token usage and model-request count. Existing simple tool
callbacks remain context-free.

Cancellation is checked at loop boundaries and propagated through the model
request so the standard HTTP transport can interrupt in-flight buffered and
streaming work. Per-request deadlines use the same runtime contract. Retry
decisions include timeouts. Optional exponential backoff uses the
application's `Io`, honors numeric `Retry-After`, and remains interruptible; a
fallible before-retry hook observes each planned delay and provider metadata.

The HTTP transport parses allocation-free response metadata for numeric
`Retry-After` and provider remaining-request/token headers. Provider error
observers and retry hooks receive those values without exposing transport
header storage or changing stable error categories.

There is intentionally no graph. Applications can build orchestration on top
of this loop without paying for an abstraction when they do not need one.

`Agent.runStream` uses that exact loop rather than a parallel orchestration
implementation. It forwards borrowed model deltas, completed calls, usage,
tool results, and final output synchronously. Once visible stream output has
been emitted, a failed request is never retried, preventing duplicated text or
tool events.

## Provider packages

`zopenai` maps the neutral contract to the OpenAI Responses API.
`zanthropic` maps it to the Anthropic Messages API. `zgoogle` maps it to the
Gemini GenerateContent API. All three accept the same `Transport`, so their
encoding and parsing can be tested without a socket.

`zopenai_compatible` maps the same contract to Chat Completions. Its explicit
base URL, provider label, conservative profile presets, and stream-usage toggle
cover gateways and local servers without assuming every compatible model has
the same capabilities.

The default `HttpTransport` uses only Zig's standard library.

## Cassettes

`ReplayTransport` implements the same transport interface. It loads a versioned
JSON cassette, matches requests in order, and returns recorded responses.
Authentication headers are deliberately outside the cassette schema.

`RecordingTransport` wraps a live transport and captures successful request and
response bodies. It does not copy headers at all, which is stronger and easier
to audit than maintaining a list of sensitive header names.

Optional body filters run only on recorded copies. The built-in JSON field
filter recursively omits configured volatile keys; custom filters support
other formats.

Strict body matching is a feature. A provider wire-format change should be an
intentional cassette update, not an invisible test success.
