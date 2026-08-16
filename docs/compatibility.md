# Compatibility policy

```zig
const std = @import("std");
const zigai = @import("zigai");

pub fn main() !void {
    const history = zigai.compatibility.migrationGuarantee("history").?;
    try std.testing.expectEqual(@as(u32, 2), history.current);

    const usage = zigai.compatibility.deprecation("zigai.Usage").?;
    try std.testing.expectEqualStrings("zigai.RequestUsage", usage.replacement);
}
```

Use `zigai.compatibility` when tooling needs machine-readable deprecation or
persisted-format support. The tables are part of the public API and change only
through the review process below.

## `0.x` public API policy

ZigAI uses semantic versioning with the following pre-1.0 rules:

- Patch releases preserve source compatibility for documented public APIs.
- Minor releases may remove a public API only after it appears in
  `compatibility.deprecations` for at least one shipped minor release.
- A deprecation names its replacement and earliest removal release.
- Security fixes may reject inputs that were previously accepted when accepting
  them would cross a documented trust boundary.
- Provider behavior can change upstream. ZigAI preserves its typed request,
  error, ownership, and capability contracts and documents wire-level changes.
- Declarations described as experimental in API documentation can change in a
  minor release, but persisted formats still follow their migration guarantee.
- Private declarations and test helpers have no compatibility guarantee.

`zigai.Usage` is the first registered compatibility alias. Use
`zigai.RequestUsage` in new code. The alias cannot be removed before `1.0.0`.

## Deprecation mechanism

A deprecation entry contains:

| Field | Meaning |
| --- | --- |
| `symbol` | Fully qualified public declaration. |
| `replacement` | Supported migration target. |
| `deprecated_since` | First release that documents the deprecation. |
| `removal_no_earlier_than` | Earliest release that may remove the declaration. |

Zig has no stable compile-warning primitive. ZigAI therefore keeps deprecated
aliases functional, publishes metadata through `compatibility.deprecation`,
and calls them out in release notes and API docs. Removal requires an API
review proving the release threshold has been reached.

## Persisted state guarantees

| Format | Current | Oldest readable | Migration |
| --- | ---: | ---: | --- |
| History | 2 | 1 | Built in. |
| Paused agent run | 2 | 2 | Exact version only. |
| Durable record | 1 | 1 | Exact version only. |
| Durable checkpoint | 2 | 1 | Built in. |
| Graph snapshot envelope | 1 | 1 | Application callback for payload versions. |
| Eval dataset | 1 | 1 | Exact version only. |
| Eval report | 1 | 1 | Exact version only. |

Readers reject future envelope versions. A built-in migration is deterministic
and preserves canonical message/usage fields. Application graph migrations run
before decoded state is published and must return a complete bounded payload.
ZigAI never silently guesses how to migrate an unknown version.

Removing support for an old persisted version requires a major release unless
the format was explicitly documented as ephemeral. Security-invalid documents
can be rejected in any release.

## Supported toolchain and targets

| Surface | Version or target | Status |
| --- | --- | --- |
| Zig | `0.16.0` | Minimum and CI-pinned version. |
| Linux | `x86_64` GNU/Linux | Verified by CI. |
| macOS | Apple Silicon | Verified by CI. |
| Windows | `x86_64` MSVC ABI | Verified by CI checks; a small set of process-spawning tests is skipped on Windows runners. |
| Debug | Linux, macOS, and Windows | Verified by checks; Linux and macOS additionally run fuzz smoke and stress smoke. |
| ReleaseSafe | Linux, macOS, and Windows | Verified by checks; Linux and macOS additionally run stress smoke. |
| Cross-compile targets | `x86_64-windows`, `aarch64-linux`, `x86_64-macos` | Compile-checked from Linux CI in ReleaseSafe. |
| Other cross targets | Best effort | No compatibility claim until added to CI. |

Distributed artifacts must use a baseline CPU model. A target becomes supported
only after clean archive consumer tests run in CI. Every push also builds and
tests a clean `git archive` extraction so the package never depends on
untracked files.

## Public API review checklist

Every new or changed public declaration must answer all items before merge:

1. **Purpose** - Does it expose a stable user task rather than an internal seam?
2. **Naming** - Does it follow Zig naming and avoid provider terminology in a
   provider-neutral layer?
3. **Typing** - Are closed states typed, callback errors narrow, and ownership
   visible in the type name or documentation?
4. **Allocation** - Does every allocating call take an allocator, and does every
   owned result have one clear `deinit`?
5. **Borrowing** - Are borrowed slices and invalidation points documented?
6. **Bounds** - Is every peer, provider, browser, file, or callback-controlled
   growth path bounded before allocation?
7. **Control** - Do cancellation and deadlines propagate and drain losing work?
8. **Concurrency** - Is thread safety explicit, and are allocators safe at every
   concurrent boundary?
9. **Security** - Are URL, path, credential, secret, approval, and tenant trust
   boundaries reused rather than bypassed?
10. **Errors** - Can callers discriminate meaningful failures without matching
    strings?
11. **Persistence** - Is a new format versioned, bounded, migration-documented,
    and covered by malformed/future-version tests?
12. **Observability** - Are correlation and redaction preserved without making
    telemetry a correctness dependency?
13. **Compatibility** - Is a breaking change deferred to an allowed release and
    entered in the deprecation table first?
14. **Verification** - Do public-API tests cover success, failure, cancellation,
    ownership, limits, allocation failures, docs, and downstream consumers?

A reviewer records deliberate exceptions in the source or API documentation.
A checklist item cannot be waived only because the implementation is difficult
to test.
