# Command-line clients

`zig build` installs one unified production client and three
provider-specific smoke clients.

## Quick usage

```console
OPENAI_API_KEY=... zig-out/bin/zigai --provider openai --model gpt-5-mini \
  "Why is the sky blue?"
OPENAI_API_KEY=... zig-out/bin/zigai-openai "Why is the sky blue?"
ANTHROPIC_API_KEY=... zig-out/bin/zigai-anthropic "Why is the sky blue?"
GEMINI_API_KEY=... zig-out/bin/zigai-google "Why is the sky blue?"
```

Add `--stream` for incremental output:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai --stream "Why is the sky blue?"
```

## Local tools

CLIs can expose local commands as provider-requested tools:

```console
OPENAI_API_KEY=... zig-out/bin/zigai-openai \
  --tools tools.json "Use my local weather tool"
```

Commands are executed directly, without a shell. The model's arguments JSON
is appended as the final argument, and stdout becomes the tool result.

## The unified client

The unified `zigai` client adds strict JSON configuration, stdin (`-`),
atomic conversation history, multiple MCP stdio servers, resumable approval
files, text/JSON/AG-UI event output, stable exit codes, and bash/zsh/fish
completion:

```console
printf 'Summarize this input\n' | OPENAI_API_KEY=... \
  zig-out/bin/zigai --config zigai.json --events -
zig-out/bin/zigai completion zsh
```

## Tool approval

When a tool requires approval, the CLI writes `.zigai-paused.json` and exits
with status `10`. Review the emitted call, then resume explicitly:

```console
OPENAI_API_KEY=... zig-out/bin/zigai --resume --approval approve
```

!!! warning "Credentials are named, never selected"
    Browser-controlled or model-controlled data never selects credential
    values. Configuration names only the environment variable that contains a
    credential.

## Agent-spec validation

`zigai-agent-spec` validates JSON/YAML agent specifications without any
network access:

```console
zigai-agent-spec validate agent.yaml --allow-env OPENAI_API_KEY
```

See [Agent specifications](agent-specs.md) for the schema and policy.
