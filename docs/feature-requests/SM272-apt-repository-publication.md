---
title: "SM272 - Apt repository publication and signing-key custody"
subtitle: "The debs are built and shipped by hand. Publishing them as a signed apt repository is a hosting and key-custody problem, not a packaging one."
brand: plain
status: candidate
status-note: "SPLIT from SM139 on 2026-08-11. SM139's increments 1-6 (the deb family, site-user provisioning, per-site channels) reached the field across 0.6.10-0.7.5 and are in the field on 17 production sites; carrying this last item there made a shipped feature read as unfinished for months. Not started."
---

# SM272 - apt repository publication

## Why this is separate from SM139

SM139 delivered the packaging: four `.deb`s built reproducibly by
`tools/build-deb.sh`, site-user provisioning, and per-site update
channels. That works and is deployed.

What it did not deliver is *distribution*. The debs are copied to `dist/`
and installed by path. An apt repository would let a host do
`apt install lazysite` and take updates the way it takes every other
package - but the work is hosting, key custody and revocation policy,
not packaging, and it does not belong in a filing about building debs.

## What it needs

**A repository host.** The Forgejo instance is the candidate - it already
serves as an OCI registry for the toolchain container target, and putting
the apt repo beside it keeps one thing to back up and one thing to secure.

**A signing key, and a decision about who holds it.** This is the part
that makes it a different kind of work. An apt repo is only as good as the
key; the questions are where the private key lives, who can sign a
release, what happens when that person is unavailable, and how a
compromised key is revoked and re-trusted across every deployed host.
None of that is answerable by the packaging code.

**A publication step in the release flow.** Today Phase B builds debs into
`dist/`. Publication would add: sign, push to the repo, update the
`Packages`/`Release` indices. It should be a separate, explicitly-invoked
step rather than part of the build, so a build never publishes by
accident.

**Channel mapping.** lazysite already has edge/beta/stable as a per-site
`update_channel`. An apt repo expresses that as suites or components, and
the mapping needs to be deliberate so a stable host cannot be moved to
edge by an apt config error.

## Open questions for the operator

- Forgejo, or a plain static repo behind the existing web server?
- Who holds the signing key, and what is the recovery story?
- Does publication happen per release, or per promoted channel?

## Related

SM139 (the packaging this completes), the Forgejo registry work.
