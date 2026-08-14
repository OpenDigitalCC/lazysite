---
title: "Compliance maintenance schedule - <operator legal name>"
subtitle: "The recurring half of operating a lazysite deployment compliantly. Authored from COMPLIANCE-MAINTENANCE-TEMPLATE; kept by the operator."
brand: plain
standard-margins: true

# ---------------------------------------------------------------------------
# OPERATOR: fill in this block, then keep the registers below up to date.
# ---------------------------------------------------------------------------
operator_legal_name:   "<registered company or individual name>"
service_name:          "<what you call this deployment>"
schedule_owner:        "<named individual who owns this schedule>"
review_cadence:        "<e.g. quarterly>"
last_reviewed:         "<YYYY-MM-DD>"
next_review_due:       "<YYYY-MM-DD>"
---

# Why this is separate from the operations declaration

`OPERATIONS-TEMPLATE.md` records **what your deployment is** - its shape, its
people, its declared targets. It changes rarely.

This file records **what you keep doing**, and it is never finished. The two
were separated because they have different lifecycles and, in most
organisations, different owners: the declaration is signed once and revisited
when something structural changes; the schedule is worked continuously and is
the thing that decays silently when nobody is looking at it.

The distinction matters for a practical reason. Every compliance failure this
project has observed in its own records - and it has observed several - was a
*maintenance* failure rather than a *declaration* failure. The declarations
were written and correct. The recurring work stopped, and nothing said so.

# The schedule

```datatable
columns: Activity | Cadence | Evidence to record | Why
widths: 4.4cm | 2.4cm | 4cm | X
bold: 1
tone: medium
text: 4
---
Restore rehearsal | per upgrade, and at least annually | date, measured recovery time, what was restored onto what | An RTO backed by a mechanism rather than a timed run is an estimate
Reporting-path rehearsal | before the obligation applies, then on any change of platform or people | date, participants, findings | An untested reporting path fails while the clock runs
Verify named people are current | per review cycle | who holds each role, confirmed reachable | People leave; obligations do not
Apply security updates | as released on your channel | version installed, date | The support period only helps if you take the fixes
Review access and credentials | per review cycle | accounts, tokens, partner grants; anything unused removed | Partner tokens outlive the projects that needed them
Run `lazysite check` | per upgrade, and per review cycle | output, and any FAIL resolved or accepted with a reason | It reports configuration drift the service will not tell you about
Confirm gating actually gates | per upgrade | `lazysite check --check-acl` output against the live front end | A protected section can be gated for pages and public for files - measured from outside, not assumed
Review monitors and alerts | per review cycle | that an alert was received by a person recently | A monitor nobody receives is not a monitor
Re-read this schedule | per review cycle | date, and what changed | The schedule itself is the thing that rots
```

# Upgrade-time obligations

Some obligations attach to the act of upgrading rather than to the calendar.
The project's release notes state these per release; the recurring ones:

- **Read the release notes before deploying.** lazysite states plainly when a
  release requires operator action that a package upgrade does not perform. It
  has shipped at least one such release.
- **Content protected before an upgrade may need re-applying.** From 0.10.8,
  protecting content moves it out of the served tree - but only on the act of
  protecting. Sections protected on an earlier version stay where they were
  until their rule is re-applied. Verify with `lazysite check --check-acl`.
- **Run a restore rehearsal after a significant upgrade**, not only on a
  calendar. The upgrade is when the restore path most plausibly broke.

# Registers

Keep these three. They are short, and they are what turns "we do this" into
evidence that you did.

## Rehearsal register

```datatable
columns: Date | Rehearsal | Result | Notes
widths: 2.4cm | 4cm | 3cm | X
bold: 1
tone: light
text: 4
---
<YYYY-MM-DD> | <restore / reporting path / other> | <measured time or outcome> | <who took part, what was learned>
```

## Vulnerability register

One row per report received or vulnerability identified, whether or not it
turned out to be real. The rows that say "assessed, not exploitable, no action"
are as valuable as the others - they are what demonstrates that intake works.

```datatable
columns: Date | Source | Severity | Fixed on | Notified? | Notes
widths: 2.2cm | 2.6cm | 2cm | 2.4cm | 2cm | X
bold: 1
tone: light
text: 6
---
<YYYY-MM-DD> | <reporter / scan / upstream advisory> | <critical..low> | <version, date> | <yes/no + why> | <retest result>
```

The "Notified?" column is the Article 14 decision, recorded at the time. "No -
assessed as not actively exploited" is a legitimate and auditable answer; the
absence of any answer is not.

## Deployment record

```datatable
columns: Date | Version | Channel | Who | Notes
widths: 2.2cm | 2.2cm | 2cm | 3cm | X
bold: 1
tone: light
text: 5
---
<YYYY-MM-DD> | <version> | <stable/beta/edge> | <named person> | <release-note actions performed>
```

# References

- `docs/compliance/OPERATIONS-TEMPLATE.md` - the declaration this schedule
  keeps true.
- `docs/compliance/OBLIGATIONS.md` - the project's dated obligations register.
- `docs/RELIABILITY.md` - the reference posture and the project's own rehearsal
  register, as a worked example of the format.
- `docs/MANUAL-CHECKS.md` - the checks that need a person rather than a test.
