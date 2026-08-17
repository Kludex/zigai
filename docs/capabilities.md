# Capabilities

Capabilities keep one feature together: its instructions, tools, policies,
hooks, settings, and optional model selection. Instead of scattering a
feature across agent fields, you declare it once and compose it.

## Declaring a capability

```zig
const research = zigai.Capability{
    .id = "research",
    .description = "Search the knowledge base and cite its sources.",
    .loading = .on_demand,
    .tools = &.{search_tool},
    .instructions = &.{.{ .text = "Cite every knowledge-base result." }},
};

const agent = zigai.Agent{
    .model = model,
    .capabilities = &.{research},
};
```

## On-demand loading

With `.loading = .on_demand`, the model at first sees only the capability
catalog and a `load_capability` tool. Loading `research` activates its
complete bundle on the next model request. Its instructions are returned by
the load call, so they remain in normal message history.

This keeps the prompt small: the model pays for a capability's tools and
instructions only after deciding it needs them.

## Dependencies

Capabilities may depend on other capability IDs. Dependencies load first and
the whole change is atomic. Conflicts, missing dependencies, cycles,
duplicate IDs, and malformed declarations fail deterministically.

## Unload policy

- `.unload_policy = .history` restores a successful load in later runs that
  receive the same history.
- `.run_end` makes a capability survive a paused-run continuation but
  disappear from a new run.

## Composition order

Composition always follows this order:

1. inherited
2. agent
3. run
4. nested
5. subagent

`RunOptions.capabilities` adds run-scoped bundles. `CapabilityLayer` supplies
the other scopes explicitly. Declaration order is stable within each scope;
the order of the layer slice cannot change scope precedence.

## Built-in capability catalog

`zigai.builtin_capabilities.Catalog` provides reviewed `web_search`,
`web_fetch`, `browser`, `image_generation`, `skills`, and
`repository_context` bundles. Native web tools stay provider-managed.
Optional browser/image/skill/repository backends are structural interfaces,
keep vendor SDKs outside the core, and enforce the same URL, content, root,
and output policies as ordinary tools.

# Agent harness

`zigai.harness.Harness` layers reusable coder, researcher, or custom
instructions and typed capability selections over any provider-neutral
`Agent`. One absolute deadline bounds the agent and artifact producers.
Results own both the normal agent result and bounded copied artifacts. The
same API accepts an agent assembled from a strict `agent_spec` resolution.

# Execution environments

`zigai.execution.Environment` is the common filesystem/shell boundary for
local rooted workspaces and remote sandboxes. Local paths reject traversal
and use rooted, non-following, resolve-beneath opens. Command policy controls
executables, network requirements, environment secrets, output sizes,
cancellation, audits, and disposable workspace cleanup.

# Memory

`zigai.memory.Store` is the durable conversation/semantic-memory boundary.
Records are always tenant-qualified, conversations reuse canonical messages,
and search returns owned citations. Retention, deletion, deterministic
compaction, semantic vectors, pluggable persistent stores, and an
allocation-checked in-memory backend share one bounded contract.

# Planning

`zigai.planning` provides immutable bounded plan revisions, advisory
callbacks, per-step approval gates, dependency-ordered dynamic execution,
nested multi-agent scope propagation, aggregate usage, one deadline, and
trace-linked lifecycle events. `CapabilityAdapter` exposes an approved plan
as an ordinary agent capability and function tool.

# Runtime services

`zigai.runtime_services` defines local interfaces for optimistic step
persistence, tenant-owned media/artifact blobs, versioned managed prompts,
and bounded structured-concurrency tasks. Deterministic in-memory stores and
a source-ordered executor are included; hosted services remain optional
application implementations behind the same vtables.
