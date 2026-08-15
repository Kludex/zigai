# Security

ZigAI keeps policy close to each boundary. Defaults protect ordinary hosted
provider use. Local services and unusual networks require an explicit opt-in.

## Outbound URLs

`UrlPolicy` applies to provider endpoints, MCP Streamable HTTP endpoints, and
rich-content URLs a provider may fetch. By default it:

- accepts HTTPS only;
- rejects embedded usernames and passwords;
- rejects local names, single-label hosts, and non-public literal IPs;
- permits any remaining host.

Use an exact host allowlist when the destination set is known:

```zig
const policy = zigai.UrlPolicy{
    .allowed_hosts = &.{ "api.openai.com", "files.example.com" },
};

var http = zigai.transport.HttpTransport.initWithOptions(allocator, io, .{
    .url_policy = policy,
});
defer http.deinit();

const agent = zigai.Agent{
    .model = client.model(),
    .url_policy = policy,
};
```

For a deliberate local development endpoint, set both `allow_http` and
`allow_local_network`. Provider CLIs do this only when an operator supplies a
custom base URL.

The standard HTTP transport never follows redirects. Its default rejects 3xx;
`.return_response` lets an application inspect the response without contacting
the `Location` target. This prevents authentication headers from crossing to a
different origin implicitly.

URL validation happens before DNS. It blocks accidental local literals and
names, but it cannot prevent a hostile public hostname from resolving to a
private address. For hostile inputs, combine an exact host allowlist with
network egress controls or a transport whose resolver validates every resolved
address.

## Credentials and diagnostics

Provider clients place API keys only in authentication headers. Standard names
such as `Authorization`, `X-Api-Key`, cookies, and names containing `token`,
`secret`, or ending in `-key` are sensitive even if a caller forgets to mark
them. Custom transports receive raw values because they must send the request;
they are trusted application code. Diagnostic code should use
`Header.redactedValue()`.

Lifecycle and telemetry events never contain provider authentication headers
or API keys. Prompt capture remains disabled by default because prompts and
tool data may themselves contain secrets. Treat a telemetry exporter as a
trusted sink when capture is enabled.

Provider error bodies are hidden by default and bounded when enabled. Native
and compatible adapters always suppress their configured API key if a provider
echoes it in a body, parsed message, or code. `ProviderError.sensitive_data_redacted`
reports that suppression.

## Trust boundaries

| Boundary | Treat as | Protection and responsibility |
| --- | --- | --- |
| Prompts and history | Untrusted data | JSON and context limits apply. They never execute directly. Prompt injection remains an application concern. |
| Tool arguments and results | Untrusted data | JSON, size, timeout, queue, and concurrency limits apply. Tool implementations are trusted code and must authorize side effects. |
| Provider and MCP endpoints | Operator configuration | URL policy runs before callbacks and socket work. Prefer exact host allowlists. |
| MCP servers and discovered tools | Untrusted peers | Protocol and JSON limits apply. Review tool descriptions, schemas, and requested actions before granting authority. |
| Provider-managed files | Provider-scoped handles | A provider guard is checked before network I/O; do not reuse opaque handles across providers. |
| Persisted history and paused state | Untrusted input | Versioned parsers and allocation limits apply. Store it with application-appropriate access control and retention. |
| Custom transports, hooks, tools, and exporters | Trusted application code | They receive the data required for their job and are responsible for further disclosure and side-effect policy. |

ZigAI does not persist API keys. Applications should keep credentials outside
message history, metadata, tool results, paused state, and cassette fixtures.

Agent specifications cannot contain literal API keys. A structured
`api_key.env` reference is read only when its name appears in
`EnvironmentPolicy.secret_names`, and an empty or missing value is rejected.
String interpolation is separate, field-specific, disabled by default, and
restricted to `interpolation_names`. Dry-run provider callbacks receive only a
`has_api_key` bit; credential bytes are passed exclusively to model
construction. Treat the specification CLI's `--allow-env` flags as explicit
authority to read those process variables.
