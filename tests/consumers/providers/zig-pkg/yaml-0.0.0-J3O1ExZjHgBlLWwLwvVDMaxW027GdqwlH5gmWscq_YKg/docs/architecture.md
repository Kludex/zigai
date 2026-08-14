# Architecture

This project is a native Zig YAML 1.2.2 library. The package root is
`src/lib.zig`; it stays small and re-exports the stable public API.

## Pipeline

```text
input bytes
  -> reader    source preparation, encoding detection, line normalization
  -> scanner   tokens
  -> parser    events
  -> composer  representation graph, anchors, aliases
  -> schema    tag resolution
  -> loader    public value graph

events / values
  -> emitter   YAML bytes
```

The implementation follows the classic YAML processing model. Public API modules
coordinate the layers; test-suite harness code and build tooling stay outside the
library pipeline.

## Dependency Direction

Dependencies must point downward through the pipeline:

```text
api -> {loader, parser, emitter, value}
loader -> composer -> parser -> scanner -> reader -> common
schema -> common
emitter -> {parser events, value, common}
```

Internal layers are imported directly by their consumers. The codebase should not
add facade modules, circular imports, or upward dependencies to make a layer reach
back into a caller.
