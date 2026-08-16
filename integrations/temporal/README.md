# Temporal sidecar

Temporal does not publish a Zig SDK. This sidecar keeps ZigAI's core
dependency-free while using Temporal's official Python SDK for workflow and
activity execution.

Copy `worker.example.toml` to `worker.toml` and register every
`(operation kind, handler ID)` pair used by your agent. Each command receives
one invocation JSON document on standard input and must write one ZigAI durable
record JSON document to standard output.

```console
uv run --project integrations/temporal zigai-temporal-sidecar \
  --config integrations/temporal/worker.toml
```

The sidecar reads `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, and the optional
`TEMPORAL_API_KEY`. Set `ZIGAI_TEMPORAL_SIDECAR_TOKEN` when the HTTP listener is
reachable outside its host, then pass the complete `Bearer ...` value to
`temporal.Options.bearer_token`.

Deploy the gateway and activity worker together. Keep old worker builds on the
task queue until their in-flight workflows finish, and never change the meaning
of a registered handler ID in place. Use a new ID for incompatible worker code.
