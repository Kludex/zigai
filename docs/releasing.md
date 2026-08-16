# Releasing ZigAI

ZigAI follows the [`0.x` compatibility policy](compatibility.md). Patch
releases preserve documented public APIs. A minor release can remove an API
only after the required deprecation window; persisted formats follow their
separate migration guarantees.

## Checklist

1. Make `TODO.local.md` and the README status describe the shipped scope.
2. Complete the public API review checklist in `compatibility.md` and verify
   every removed declaration reached its `removal_no_earlier_than` release.
3. Run `./scripts/check`, `./scripts/test-cli`, and `./scripts/coverage`.
4. Run `./scripts/test-live` with every available provider key and record any
   provider intentionally skipped.
5. Review every changed cassette for prompts, responses, and accidental
   secrets. Authentication headers must never appear.
6. Set the version in `build.zig.zon`, update release notes, and commit those
   changes before tagging.
7. Tag the verified commit as `vMAJOR.MINOR.PATCH` and publish the matching
   source archive. Do not move an existing tag.
8. Re-run a clean consumer build against the tag on Linux and macOS.

No release is considered stable while the README labels the project
experimental.
