# 0002 - Releases are tags cut from main; the working tree is unstable

Status: Accepted
Date: 2026-07-02 (retrospective; practice since SM063, 2026-06)
Tags: release, process, versioning

## Context

Early releases carried a per-release version-bump commit and treated the
working tree as the shippable artefact, which made "what is released" ambiguous
and let untested trees leak into deploys. The 2026 review of the release
process (SM063-SM065) needed a stable identifier for every shipped build and a
way to keep day-to-day work unconstrained.

## Decision

`main` is unstable and carries unreleased work. A release is a **git tag**
(`vX.Y.Z`) cut from a commit on main, packaged by `tools/release.sh` (or the
equivalent manual ritual) from a **clean checkout of the tag** - never from the
working tree. `VERSION`/`NEXT_VERSION` roll via `tools/bump-version.pl` after
the tag. The release pipeline gates the tag: full suite, benchmark check,
coverage floors, strict SBOM; the tarball embeds `release-manifest.json` +
`sbom.json`.

## Rationale

Tags are immutable, auditable identifiers; building from `git archive` of the
tag guarantees the shipped bytes match the tagged commit (no working-tree
leakage). Keeping main unstable removes the pressure to batch work into
release-shaped commits.

## Consequences

- "What is deployed" is always answerable: the tag in `.install-state.json`.
- Anything not tagged is by definition not shipped, however green.
- The CHANGELOG is keyed by tag for releases and by short commit ref for
  unreleased entries.
