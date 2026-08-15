# Agent specifications

Agent specifications are strict, versioned data. Parsing them does not read the
environment, construct a provider client, load executable code, or make a
network request.

```yaml
version: 1
name: support
provider:
  name: openai
  model: ${MODEL}
  api_key:
    env: OPENAI_API_KEY
system_prompt: Help the user.
instructions:
  - Be concise.
capabilities:
  - id: search
    loading: on_demand
    unload_policy: history
```

The same shape works as JSON. Unknown fields, duplicate YAML keys, unknown
tags, literal API keys, duplicate capability IDs, invalid identifiers, empty
required values, excessive nesting, and oversized documents are rejected.
Version 1 allows at most 64 instructions and 256 declared capabilities.

## Parse, validate, resolve

`agent_spec.parseJson` and `parseYaml` return `agent_spec.Owned`. Its arena owns
the source and every nested parsed slice until `deinit`.

Resolution is a separate application boundary:

1. `validateResolution` expands only explicitly enabled fields, checks secret
   presence, validates the provider and model through `ProviderResolver`, and
   resolves capability implementations through `CapabilityResolver`.
2. `resolve` repeats those local checks, calls the provider `buildFn`, and
   returns an arena-owned `Resolved` containing a ready `Agent`.
3. `Resolved.deinit` runs optional model cleanup before releasing its arena.

The provider validator receives `ProviderValidationInput`, which says whether
a key is present but never exposes its bytes. It must remain local and
side-effect free. Only `buildFn` receives `ProviderInput.api_key`. The allocator
passed to `buildFn` belongs to `Resolved`, so a client context may be allocated
there. Use `ModelHandle.cleanupFn` for resources that need explicit shutdown.

Capability callbacks return borrowed implementations whose callback contexts
must outlive `Resolved`. Per-spec loading and unload-policy values override the
registered implementation. Missing transitive dependencies are fetched from
the same catalog, then the complete registry is checked for duplicate IDs,
cycles, missing references, and conflicts before model construction.

## Environment policy

Environment access is deny-by-default.

- `EnvironmentPolicy.secret_names` permits named `api_key.env` references.
- `interpolation_names` permits `${NAME}` only in fields enabled by
  `InterpolationFields`.
- Model, base URL, system prompt, and instruction interpolation are controlled
  independently and are disabled by default.
- `$${NAME}` produces the literal `${NAME}` when interpolation is enabled.
- Missing variables, empty secrets, malformed placeholders, and names outside
  the allowlist fail validation.

Provider names and capability IDs are never interpolated. This keeps resolver
selection deterministic even when the document is untrusted.

## Dry-run CLI

Install the command with `zig build` or `zig build install`, then validate a
document without contacting a provider:

```console
zigai-agent-spec validate agent.yaml \
  --interpolate \
  --allow-env MODEL \
  --allow-env OPENAI_API_KEY \
  --capability search
```

`--allow-env` grants a name for structured secret references and, when
`--interpolate` is present, placeholders. Each capability used by the document
must be declared with `--capability`; the standalone CLI has no application
capability catalog.

The CLI recognizes the provider keys exported by `zigai.providers`, validates
custom endpoints as credential-free HTTP(S) URLs, and requires a non-empty
model ID. Exact model discovery and aliases belong to the application resolver
until ZigAI ships the independent model-discovery snapshot on the roadmap.
