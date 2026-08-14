# Releasing ZigAI

ZigAI follows semantic versioning. Until 1.0, a minor version may contain a
documented public API change; patch versions remain backward compatible.

## Checklist

1. Make `TODO.local.md` and the README status describe the shipped scope.
2. Run `./scripts/check`, `./scripts/test-cli`, and `./scripts/coverage`.
3. Run `./scripts/test-live` with every available provider key and record any
   provider intentionally skipped.
4. Review every changed cassette for prompts, responses, and accidental
   secrets. Authentication headers must never appear.
5. Set the version in `build.zig.zon`, update release notes, and commit those
   changes before tagging.
6. Tag the verified commit as `vMAJOR.MINOR.PATCH` and publish the matching
   source archive. Do not move an existing tag.
7. Re-run a clean consumer build against the tag on Linux and macOS.

No release is considered stable while the README labels the project
experimental.
