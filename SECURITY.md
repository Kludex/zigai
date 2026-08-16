# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub security advisories](https://github.com/Kludex/zigai/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

If you cannot use GitHub, contact the maintainer listed on
<https://github.com/Kludex> through a private channel.

You should receive an acknowledgement within 7 days. Coordinated disclosure is
preferred: keep the report private until a fixed release is available or 90
days have passed, whichever comes first.

## Supported versions

ZigAI is pre-1.0. Only the latest `0.x` release receives security fixes.
A fix ships as a new patch release on the current minor version; older
releases are not patched.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Threat model

The complete boundary-by-boundary model lives in
[`docs/security.md`](docs/security.md). In summary:

- Prompts, message history, tool arguments/results, persisted state, provider
  responses, and MCP peers are **untrusted input**. Every parser on these
  boundaries is bounded, versioned where persisted, and fuzz-tested.
- Provider endpoints and MCP server URLs are **operator configuration**,
  validated by `UrlPolicy` before any socket work. Defaults reject cleartext,
  credentials in URLs, and local-network destinations.
- Tools, hooks, custom transports, and telemetry exporters are **trusted
  application code**; they receive the data their job requires and own further
  disclosure and side-effect policy.
- API keys live only in authentication headers, are never persisted, and are
  redacted from diagnostics, telemetry, error bodies, and cassettes.

Prompt injection is an application-level concern: ZigAI bounds and types what
a model can invoke, but the application decides what authority a tool grants.

## Dependencies

Runtime dependencies are deliberately minimal: the Zig standard library and
one pinned YAML package, locked by content hash in `build.zig.zon`. GitHub
Actions dependencies are updated by Dependabot; a scheduled workflow monitors
the upstream provider APIs the library targets. Every release ships a SPDX
SBOM and build-provenance attestation.

## Advisory response checklist

1. Acknowledge the private report and reproduce the issue.
2. Assess impact and affected releases; request a CVE through the GitHub
   advisory if user action is required.
3. Develop and review the fix privately; add a regression test.
4. Release a patch version through the standard release workflow.
5. Publish the advisory with affected versions, the fixed version, and
   workarounds; credit the reporter unless they decline.
6. Verify downstream consumers can update by running the release smoke test.
