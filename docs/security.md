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

## MCP HTTP authorization

MCP authorization is optional. When enabled, ZigAI follows the
[`2026-07-28` authorization profile](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
at the transport boundary:

- `protectedResourceDiscoveryUrls` returns the endpoint-path and root RFC 9728
  URLs in required order; `parseProtectedResourceMetadata` accepts extensions
  but requires the canonical resource, at least one distinct issuer, and the
  Bearer header method;
- `authorizationServerDiscoveryUrls` returns RFC 8414 and OIDC URLs in required
  path-aware order; parsed metadata must match the selected issuer exactly,
  use eligible HTTPS endpoints, and advertise `S256` PKCE;
- `ClientPolicy` binds one canonical resource and authorization-server issuer
  to a `TokenProvider`. The callback receives the RFC 8707 `resource`, method,
  accumulated scopes, and refresh reason. Return tokens with
  `AccessToken.initAlloc` so partial allocation failures are cleaned safely;
- Streamable HTTP adds `Authorization: Bearer ...` to every POST. A valid 401
  challenge can request a bounded refresh; a 403 `insufficient_scope` challenge
  can request a bounded stable-order scope union. Static Authorization headers
  cannot be combined with a token policy;
- `ServerPolicy` passes only the token value, canonical audience, method, and
  params to the application verifier. The verifier must validate signature,
  expiry, issuer, and audience before returning `authorized`. Denials produce
  an owned `WWW-Authenticate` response header; callback descriptions and token
  bytes are never reflected.

Browser and network checks are separate in `DeploymentPolicy`. It rejects
cleartext unless explicitly enabled, requires an exact allowed Origin whenever
the header is present, and can require an exact Host value. Duplicate Origin,
Host, and Authorization headers fail closed. This implements the
[Streamable HTTP Origin requirement](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
before JSON parsing. Bind local servers to loopback; use a reverse proxy or
host framework that supplies truthful `HttpMetadata.is_tls`, preserves response
headers, and validates resolved addresses at the network boundary.

`ServerResponse.headers` is borrowed until `deinit`; an HTTP host must copy or
write those headers first. The standard outbound HTTP transport does not follow
redirects, so Bearer credentials cannot cross origins implicitly. Custom HTTP
transports must preserve that rule and mark Authorization headers sensitive.

## Credentials and diagnostics

Provider clients place API keys only in authentication headers. Standard names
such as `Authorization`, `X-Api-Key`, cookies, and names containing `token`,
`secret`, or ending in `-key` are sensitive even if a caller forgets to mark
them. Custom transports receive raw values because they must send the request;
they are trusted application code. Diagnostic code should use
`Header.redactedValue()`.

Lifecycle, telemetry, and diagnostic events never contain provider
authentication headers or API keys. Prompt and tool content capture remains
disabled by default because application data may itself contain secrets.
Structured diagnostics replace configured sensitive values before truncation;
the application must list any secrets that can occur in captured content.
Treat telemetry exporters and diagnostic sinks as trusted when capture is
enabled.

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
| MCP servers and discovered tools | Untrusted peers | Protocol, capability, schema, pagination, round-trip, and JSON limits apply. Review tool descriptions and requested actions before granting authority. |
| MCP OAuth metadata and challenges | Untrusted network data | Bounded parsers, URL policy, exact issuer/resource binding, PKCE checks, and retry limits apply. Token storage and interactive authorization remain application-owned. |
| MCP HTTP host | Trusted deployment boundary | Must provide truthful headers/TLS state, emit owned response headers before cleanup, bind local services to loopback, and enforce resolver/egress policy. |
| MCP input handlers and extensions | Trusted application policy over untrusted JSON | MRTR requests and responses are schema-checked, but the callback decides whether elicitation, roots, or sampling is authorized. Extension settings remain application-defined. |
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
