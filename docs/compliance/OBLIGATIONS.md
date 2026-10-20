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
reviewed_at_version: 0.15.15
content_sha:         4cdf45b8ae085a8b
reviewed_on:         2026-10-20
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
Declaration of Conformity finalised and signed | at the certified cut (ADR 0010) | certified cut | OPEN | docs/DECLARATION-OF-CONFORMITY.md - draft restamped to 0.15.15 on 20 Oct 2026 and unsigned; the release manager signs it at the certified cut
Significant-change register entry per triggering release | at each release | 0.15.15 | STARTED | docs/SECURITY.md - nine entries dated 20 Oct 2026 cover 0.15.3 to 0.15.15 (Odoo extension, Odoo sign-in, oomd, trusted proxies, address rules, identity in-process, member credentials, notification rules, SM1213) and a tenth the held SM1219 and SM1118; each is a developer-agent draft until the release manager confirms. Previous 6 Oct 2026 for SM924-SM938
Threat model current with the architecture | at each release | 0.15.15 | met | docs/SECURITY.md trust boundaries 9-13 and six STRIDE rows, and docs/architecture/security.md (identity in the pool, trusted proxies, address rules, the Odoo extension and oomd, the ADR 0006 downgrade), added 20 Oct 2026; boundary 8 (the scheduled actor) 5 Sep 2026
SBOM regenerated and shipped | at each release | every release | met | strict gate, tools/manifest-to-sbom.pl --strict - run 20 Oct 2026 on the 0.15.15 tree: exit 0, 444 components
Annex VII technical file kept current | continuous; complete before CE marking | 2027-12-11 | STARTED | docs/compliance/TECHNICAL-FILE.md - index form, walked to 0.15.15 on 20 Oct 2026
Signed releases (Sigstore/cosign) | before CE marking; cannot be applied retroactively | 2027-12-11 | OPEN | docs/POLICY.md - every unsigned release is permanently unattestable; stays for the certified release (release manager, 20 Oct 2026)
OpenChain 5230 + 18974 written policies | before CE marking | 2027-12-11 | OPEN | docs/POLICY.md
Bench baseline re-captured | at each stable cut | next stable | OPEN | dist/config/bench-baseline.json - captured 2026-09-30; re-capture on a quiet host at the stable cut (stable-gate plan P8)
Restore rehearsal recorded | at least once per stable cycle | next stable | OPEN | docs/RELIABILITY.md - last recorded 2026-08-26, before the last stable cut (2026-09-22); the rehearsal on a scratch copy of a real site at the candidate version is the operator's (stable-gate plan P6)
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
Significant-change assessment on each fired trigger | continuous | drafted to 0.15.15 | docs/adr/0007-pentest-deferral.md - the register is what keeps the waiver valid; the 20 Oct 2026 entries await the release manager's confirmation
Vulnerability handling in operation (intake, triage, advisory, VEX) | continuous | PARTIAL | SECURITY.md declares CVD intake; the dated remediation register against the ADR 0007 SLAs stays for the certified release (release manager, 20 Oct 2026)
CE marking applied | 2027-12-11 | OPEN | docs/POLICY.md
Support period ends | 2031-07-10 | running | docs/POLICY.md - five years from 0.7.0, cut 2026-07-10. The absolute date is written here so the commitment does not depend on anyone recalling which release was first stable
```

# Walked to 0.15.15: what a person must confirm

Walked on 2026-10-20 by the developer agent for the stable candidate 0.15.15
(release manager, 2026-10-20: "0.15.15, after its walk"). Every row above was read
against the tree; the rows below hold what only a person can close.

- The ten significant-change entries dated 2026-10-20 in `docs/SECURITY.md` are
  drafts, each marked "assessment drafted by the developer agent; the release manager
  confirms", with the verdict stated as proposed. The Odoo extension entry asks whether
  the assessment, without a third party, holds until the ADR 0007 engagement.
- Whether the changes in 0.15.3 to 0.15.7 that tightened existing gates (SM975, SM976,
  SM979-SM982, SM991-SM993, SM1057, SM1092 and the rest of the CHANGELOG's security
  lines) fired a trigger. The drafts treat them as fixes that added no interface,
  method, dependency or data.
- The threat model rows in `docs/SECURITY.md` and `docs/architecture/security.md`: read
  from the filings, not from a fresh review of the code.
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
