---
title: "lazysite - release gate record"
subtitle: "Which commit each release was validated at, newest last. Appended by tools/release.sh."
brand: plain
standard-margins: true
---

# Why this file exists

A promotion review could establish which VERSION was being proposed and not
which COMMIT had been validated: the gate summary went to a terminal and to
`tmp/gate-result.txt`, which is gitignored. "The build that would go to beta is
not the build that was validated" was a reasonable conclusion and nothing cheap
could disprove it.

Every row is written by `tools/release.sh` after its gate passed and before it
tagged, so a row exists only for a build that was actually gated. The same facts
travel inside the artefact, in `release-manifest.json` under `validated`.

| Version | Channel | Commit | Files | Tests | Gated (UTC) |
|---|---|---|---|---|---|
| 0.10.16 | edge | `06566c426ac35c0a33b863bff10e034cd20f3fe1` | 462 | 8415 | 2026-08-19 16:52 |
