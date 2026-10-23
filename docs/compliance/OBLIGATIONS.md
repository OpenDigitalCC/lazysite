---
title: "lazysite - dated obligations register"
subtitle: "Every obligation with a date or a version anchor, in one place. Reviewed at every release."
brand: plain
standard-margins: true
---

# What this file is

The single register of every lazysite obligation that has **a date, a version
anchor, or both**. It exists because those obligations were previously spread
across four documents with no combined view, and one of them was written
relatively ("five years from the first stable release") - which decays the
moment a reader has to work out which release that was.

Nothing here is new policy. Each row points at the document that *is* the
policy; this file is the calendar over them.

::: widebox
**This file is reviewed at every release.** The release gate runs
`tools/lazysite-compliance.pl --check`, which fails when a row's date has
entered its lead time with the row still `open`, or when `reviewed_at_version`
is behind the version being cut. Updating this file is therefore part of
cutting a release, not something to remember afterwards.
:::

```yaml
reviewed_at_version: 0.16.2
content_sha:         c8547d3d824105d1
reviewed_on:         2026-10-23
next_review:         at the next release, whichever channel
owner:               release manager
```

# Build-side obligations

Discharged by the development team, in the repository, as part of making a
release. Each has a version anchor: the release that must carry it.

```datatable
columns: Obligation | Due | Version anchor | State | Source
widths: 4.2cm | 2.4cm | 2.4cm | 1.8cm | X
bold: 1
tone: medium
text: 5
---
Declaration of Conformity finalised and signed | at the certified cut (ADR 0010) | certified cut | OPEN | docs/DECLARATION-OF-CONFORMITY.md - draft restamped to 0.16.0 on 20 Oct 2026 and unsigned; the release manager signs it at the certified cut
Significant-change register entry per triggering release | at each release | 0.16.2 | STARTED | docs/SECURITY.md - one entry dated 23 Oct 2026 covers 0.16.2, a security release: a theme archive's symbolic link reached the served asset mirror and could serve the session-signing secret (SM1303, with SM1304's planted-link warning); no trigger fired, recorded as a bypass of boundary 6 as SM1213 and SM1257 were; a developer-agent draft until the release manager confirms. SM1305 (release.sh --security-critical) and SM1307 (the Hestia updater's --force-security) are release and rollout tooling and touch no boundary. Five entries dated 23 Oct 2026 cover 0.16.1: the warm-forked Odoo endpoint (SM1226, a new local interface), a page's stem rule on move and delete (SM1257, SM1242, SM1258), the Odoo extension's options and OOM 0.42 (SM1223-SM1225, SM1244, SM1247, SM1248, SM1261), the Docker Compose package (SM1233), and the access, rollout and channel changes with no trigger; each is a developer-agent draft until the release manager confirms. SM1219 and SM1118, accepted on 21 Oct 2026, are recorded as landed in 0.16.1. Previous 20-21 Oct 2026 for 0.15.3 to 0.16.0, confirmed by the release manager on 21 Oct 2026
Threat model current with the architecture | at each release | 0.16.2 | met | docs/SECURITY.md a STRIDE row for the theme archive's link (SM1303, SM1304) and docs/architecture/security.md (the zip upload and the served asset mirror), added 23 Oct 2026; for 0.16.1, trust boundary 14 (the warm-fork parent) and two STRIDE rows (the stem rule, the parent), and docs/architecture/security.md (the warm-forked endpoint, Odoo idempotency, sizes and downloads, the stem rule, MCP remove_permissions, bundle adoption, Permissions-Policy, the rate counter, the Docker package), added 23 Oct 2026; boundaries 9-13 20 Oct 2026
SBOM regenerated and shipped | at each release | every release | met | strict gate, tools/manifest-to-sbom.pl --strict - run 23 Oct 2026 on the 0.16.2 tree (main d167c6d28 (0.16.1) plus SM1303-SM1305 and SM1307, manifest built --security-critical): exit 0, 455 components
Annex VII technical file kept current | continuous; complete before CE marking | 2027-12-11 | STARTED | docs/compliance/TECHNICAL-FILE.md - index form, walked to 0.16.2 on 23 Oct 2026
Signed releases (Sigstore/cosign) | before CE marking; cannot be applied retroactively | 2027-12-11 | OPEN | docs/POLICY.md - every unsigned release is permanently unattestable; stays for the certified release (release manager, 20 Oct 2026)
OpenChain 5230 + 18974 written policies | before CE marking | 2027-12-11 | OPEN | docs/POLICY.md
Bench baseline re-captured | at each stable cut | next stable | OPEN | dist/config/bench-baseline.json - captured 2026-09-30; re-capture on a quiet host at the stable cut (stable-gate plan P8)
Restore rehearsal recorded | at least once per stable cycle | next stable | OPEN | docs/RELIABILITY.md - last recorded 2026-08-26, before the last stable cut (0.16.0, 2026-10-22); the rehearsal on a scratch copy of a real site at the candidate version is the operator's (stable-gate plan P6)
```

# Operate-side obligations

Discharged by whoever **runs** a lazysite instance. On this project that is
sometimes the same people and sometimes not, and the lifecycles differ: a build
obligation is met by cutting a release, an operate obligation is met by a
person doing something on a running service, on a calendar that has nothing to
do with the release cadence.

An operator records their own instance's state in their filled-in copy of
`docs/compliance/OPERATIONS-TEMPLATE.md`; the rows below are the obligations
that copy must account for.

```datatable
columns: Obligation | Due | State | Source
widths: 4.6cm | 3cm | 1.8cm | X
bold: 1
tone: medium
text: 4
---
CRA Article 14 reporting path rehearsed before the clock is live | 2026-09-11 | OPEN | toolchain OPERATIONS-GUIDE.md #report-path-rehearsal; named triage owner + deputy, platform access verified, 24h/72h/14d cascade walked as a tabletop
Named security triage owner and deputy | 2026-09-11 | OPEN | as above - the DoC names a function, not an individual
First third-party penetration test | 2026-12-31, or first GA marketing, whichever first | OPEN | docs/adr/0007-pentest-deferral.md - after expiry an absent report is a refusal condition, not a deferral
Significant-change assessment on each fired trigger | continuous | drafted to 0.16.2 | docs/adr/0007-pentest-deferral.md - the register is what keeps the waiver valid; the 20 Oct 2026 entries were confirmed by the release manager on 21 Oct 2026; of the 23 Oct 2026 entries, the five for 0.16.1 and the SM1303 entry for 0.16.2 await the release manager's confirmation
Vulnerability handling in operation (intake, triage, advisory, VEX) | continuous | PARTIAL | SECURITY.md declares CVD intake; the dated remediation register against the ADR 0007 SLAs stays for the certified release (release manager, 20 Oct 2026). 0.16.2 is cut as a security release for SM1303 (ruling 41 as revised, 41b): its manifest declares security_critical (SM1305) and it is pushed with `lazysite upgrade --all --force-security`, or on a Hestia host the updater's `--force-security` (SM1307); the fix is in the register, its dated remediation record with the rest at certified
People who sign in told that the visitor log records their account | on running 0.16.1 or later with the visitor log on | OPEN | docs/OPERATOR.md "The visitor log names signed-in accounts" (SM1219) - account names are personal data; the site's privacy notice says so, or the log is turned off or its retention shortened. The engine publishes no notice (SM1010)
A symbolic link planted in the served asset mirror removed, and the session secret rotated | on upgrading to 0.16.2, where `lazysite check` names each link | OPEN | docs/OPERATOR.md "A symbolic link in the asset mirror is left for you" (SM1304) - before 0.16.2 a theme upload could plant one, serving what it points at, `lazysite/auth/.secret` included; the engine warns and never deletes, so the operator removes the link and rotates the secret (the manager's Sessions page, "Log out all users")
CE marking applied | 2027-12-11 | OPEN | docs/POLICY.md
Support period ends | 2031-07-10 | running | docs/POLICY.md - five years from 0.7.0, cut 2026-07-10. The absolute date is written here so the commitment does not depend on anyone recalling which release was first stable
```

# Walked for 0.16.2: what a person must confirm

Walked on 2026-10-23 by the developer agent for 0.16.2, a security release cut from main
straight after 0.16.1 (ruling 41 as revised and 41b): every row above was read against
the CHANGELOG's `## Unreleased` section and `git log d167c6d28..` on the n738 branch,
which carries SM1303, SM1304, SM1305 and SM1307 and nothing else. The rows below hold
what only a person can close. The 0.16.1 walk's items are carried where they still
stand; the confirmation of its five register entries is recorded in those entries.

- The SM1303 entry dated 2026-10-23 in `docs/SECURITY.md` is a draft, marked
  "assessment drafted by the developer agent for the release manager's confirmation",
  with the verdict stated as pending. It finds no ADR 0007 trigger fired and records the
  exposure as a bypass of boundary 6, as the SM1213 and SM1257 entries did.
- Ruled, not open: SM1303 has no known exploitation, so there is no CRA Article 14
  notification and no advisory; its register entry and the release notes record it
  (ruling 44, 2026-10-23). The dated remediation register is left for the certified
  release by ruling.
- The operate-side row for SM1304 (remove a planted link, rotate the secret), added at
  this walk.
- The threat model rows in `docs/SECURITY.md` and `docs/architecture/security.md`: read
  from the filings, not from a fresh review of the code.
- The operate-side row for SM1219 (telling the people who sign in), added at the 0.16.1
  walk.
- The Declaration of Conformity (restamped, unsigned).
- Operate-side rows the developer agent cannot observe: the CRA Article 14 reporting
  path rehearsal and the named triage owner and deputy (both dated 2026-09-11, still
  OPEN), the first third-party penetration test (2026-12-31, or first GA marketing), OpenChain
  5230 and 18974 (pending in `docs/POLICY.md`), CE marking, and the support period
  (`docs/POLICY.md`, ending 2031-07-10).
- The restore rehearsal (operator, root) and the SM296 re-apply sweep on each production
  site (operator): stable-gate plan P6 and P7.
- Left open for the certified release by ruling: signed releases and the vulnerability
  register.

# How a row is discharged

open
: the obligation has not been met and its date has not passed.

met
: met for the version named in the version anchor. A row that is `met` for
  0.10.8 is **not** met for 0.10.9 - obligations with a per-release cadence
  return to `open` when a new release is cut. That is what the release gate
  checks.

started
: partially discharged, with the artefact existing and incomplete. Used where
  completing early is cheaper than completing late - the technical file is the
  case in point.

running
: a continuing commitment with an end date rather than a due date.

# Why this file is anchored on versions as well as dates

A compliance claim is always a claim about **a version**. "The threat model is
current" is meaningless without saying current as of what; "the SBOM matches
the code" is a statement about one tarball. The eight-dimension review that
prompted this file made the same point about itself - a verdict belongs to the
tree it was measured on.

So every build-side row carries the release that must satisfy it, and
`reviewed_at_version` at the head of this file records the last release at
which the whole register was walked. If that value is behind the version being
cut, the register has not been reviewed for this release and the gate fails.

# References

- `docs/POLICY.md` - the regulatory posture and the CRA Article 13 table.
- `docs/DECLARATION-OF-CONFORMITY.md` - the declaration these obligations
  support.
- `docs/adr/0007-pentest-deferral.md` - the waiver, its expiry and its triggers.
- `docs/compliance/TECHNICAL-FILE.md` - the Annex VII index.
- `docs/compliance/OPERATIONS-TEMPLATE.md` - what an operator fills in.
- `/srv/projects/toolchain-development/OPERATIONS-GUIDE.md` - the operate-half
  items this register's operate section is drawn from.
