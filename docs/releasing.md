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
7. Create a signed annotated tag on `main` as `vMAJOR.MINOR.PATCH` with
   `git tag -s vX.Y.Z -m "zigai X.Y.Z"` and push it. Do not move or delete an
   existing tag; a bad release gets a new patch version instead.
8. The `Release` workflow then runs automatically. It rebuilds the source
   archive twice with `scripts/release-archive` and proves both are
   byte-identical, generates a SPDX SBOM, attests build provenance through
   GitHub artifact attestations, verifies the checksum and runs
   `scripts/release-smoke` consumer builds against the extracted archive on
   Linux, macOS, and Windows, and publishes the GitHub release with the
   matching `CHANGELOG.md` section as its notes.
9. Confirm the published release lists the archive, its `.sha256` checksum,
   and the SBOM, and that `gh attestation verify` accepts the archive.

## Reproducible archives

`scripts/release-archive <tag> <output-directory>` is the only supported way
to produce a release archive. It validates the tag format, requires the tagged
`build.zig.zon` version to match, and pipes `git archive` through `gzip -n` so
the bytes depend only on the tagged commit. Anyone can rebuild the archive
from the tag and compare checksums.

`scripts/release-smoke <archive.tar.gz>` extracts the archive into a temporary
workspace and builds and runs both consumer packages against it, proving the
published package contents are sufficient for downstream builds.

No release is considered stable while the README labels the project
experimental.
