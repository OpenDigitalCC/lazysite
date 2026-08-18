---
title: "SM303 - release.sh should be two commands, not one command with credential flags"
subtitle: "Building a release needs no remote access. Publishing one needs nothing else. Conflating them cost two flags, a stranded artefact, and a run that reported failure for a release that had succeeded."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18. `release.sh build VERSION` and `release.sh publish VERSION`. Build gates, packages and tags LOCALLY and touches the remote nowhere - not "skips when asked", never - so it runs on the host with the toolchain, which is not the host with the credentials. Publish confirms the tag exists locally (it cannot invent one), re-applies SM325 (a tag on no branch must not be pushed), checks origin, and pushes. The bare single-command form REFUSES and names the two commands rather than guessing which half was meant: its failure modes are the reason the split exists, so a silent fallback would preserve them. --no-fetch is accepted and inert, because the invocations carrying it are the ones that were working around the defect. t/tools/47 asserts the property rather than the text: no fetch, push or ls-remote anywhere outside the publish block. FILED 2026-08-15 out of the 0.10.9 cut. Nothing started. The two flags added that day (--no-fetch, and its extension to skip the push) work and are tested, but they are a symptom: the tool models one operation where there are two, performed by different parties with different capabilities."
---

# SM303 - one command doing two jobs for two parties

## What happened

The build host has no remote credentials by design: development work and the
gate run there, review and push are done by a person elsewhere. `release.sh`
opened with `git fetch --tags origin` under `set -e`, so on that host it aborted
at line 159 - before a single gate step ran.

The immediate consequence was backwards: the one person who *could* reach the
remote was being asked to supervise a fifty-minute test run that needs no
credentials at all.

The repair was `--no-fetch`, which skips the two origin checks. That worked, and
then the run died at the *last* step instead, on `git push`, because `--no-fetch`
had not been taken to mean "this host cannot reach the remote at all". Under
`set -e` that killed the artefact copy and cleanup, so a release that had been
fully gated, built and tagged reported **exit 128** and left its 2.8MB tarball
in the staging directory for someone to find by hand.

Both are now fixed. Both were symptoms.

## The actual shape

The command performs two operations that share nothing but a version number:

```datatable
columns: Operation | Needs | Who
widths: 4cm | X | 3.4cm
bold: 1
tone: medium
text: 2
---
BUILD | the tree, the toolchain, CPU. Gate, manifest, SBOM, man pages, tarball, LOCAL tag | anyone with a checkout
PUBLISH | remote credentials, and the judgement that this tag should exist upstream | the person who pushes
```

Split them:

```bash
release.sh build   0.10.9 --commit HEAD     # gate, tarball, local tag
release.sh publish 0.10.9                   # confirm upstream, push
```

## What that buys

- **`--no-fetch` disappears.** The question "can this host reach the remote"
  stops being a flag and becomes which subcommand you ran.
- **The exit code means something.** `build` exits 0 when the release is built.
  Today a successful build can exit 128 for reasons that have nothing to do with
  whether it built.
- **The upstream collision check lands where it can be acted on.** Checking that
  `vX.Y.Z` is not already on origin is only useful to whoever is about to push;
  `publish` is where it belongs and where it can block.
- **It matches how the work is actually divided**, which is the general point.
  A tool that assumes one actor with all capabilities will grow a flag for every
  capability that actor turns out to lack.

## Care needed

- **`publish` must re-verify, not trust.** It should confirm the tag it is
  pushing points at the commit the build recorded, so a tree that moved between
  build and publish cannot be published silently.
- **`build` must keep saying the tag is local.** The single most important line
  of output today is the one warning that the upstream check was not performed.
- **Do not lose the retained-staging-on-failure behaviour**, which is what made
  the stranded tarball recoverable and what made the gate's own defect
  diagnosable.

## Related

[[SM064]] (the release procedure), `tools/release.sh`,
`docs/review/2026-08-14-eight-dimension-0.10.9/` (which records the gate defect
found during the same cut).
