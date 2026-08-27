---
title: "SM496: a capability added by a release asks the administrator, in the UI"
subtitle: "Consent-at-upgrade: the Groups page offers each release-added capability as a one-decision banner to a manage_users holder. No SSH, no CLI, no silent widening."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29 as decided, one refinement forced by the store: off used to DELETE the key, so the store could not represent decided-no at all - now off writes an explicit 0, absent means undecided, and the seed stamp the sketch proposed is unnecessary (pending derives from absence alone, D2-clean). Grant/Dismiss on the Groups banner are plain group-settings-set on/off, so the SM195 ceiling, the lockout guards and the audit trail apply unchanged and no new action exists. lazysite-check warns only on undecided, names the Groups page before the CLI, and reports declined as decisions. One honest one-time cost, recorded in the walkthrough: a capability an operator deleted-off BEFORE this release is indistinguishable from never-decided, so it pends once and is dismissed once - the store genuinely did not know. Browser half is Task 6, NOT WALKED. ORIGINAL NOTE: FILED 2026-08-24 from the release manager's direction after the 0.10.28 deploy. THE REQUIREMENT, stated by the operator: capability upkeep must be manageable via the UI - sysadmins shouldn't be required for app support after first implementation. THE PROBLEM: SM471 decided (correctly) that an upgrade never grants - so every capability added after a site was seeded produces a permanent lazysite-check warning whose only remedy is a CLI command on the box, at fleet scale (17 prod sites x every new cap), and warning fatigue is how a real warning gets ignored. THE SHAPE CHOSEN from six options (table inside): G4 consent-at-upgrade - the upgrade queues 'capabilities new since this group was seeded', the Groups page shows a one-decision-per-cap banner (grant/dismiss, the capability's own description in front of the decider) to any manage_users holder, every decision recorded in the audit trail. Rejected: G1 wildcard-all and G2 well-known operators group (both grant FUTURE capabilities sight unseen - the trade SM471 was decided against, and channel caps could never be inside 'all' per SM127, so 'all' degenerates into a profile anyway); G3 release-declared profiles (moves the security decision from operator to release author); G5 auto-grant-to-untouched-seeds (unexplainable freeze semantics); G6 status quo (the CLI remedy violates the stated requirement). OPTIONAL G3-LITE LATER: a capability may declare 'recommended for admin groups' so the banner pre-ticks it - a recommendation, never an auto-grant. SIZE M: per-group seed/decision stamp, pending-caps derivation, one Groups-page banner, audit line, and the check's remedy text changes to name the UI. Dismiss must be durable (a dismissed cap stops warning) and reversible (the banner's decisions are reviewable on the same page). SUPERSEDED FOR MANAGER GROUPS BY SM645 (2026-08-27): `pending` is computed for manager groups ONLY, and SM645 now fills a manager group's never-decided capabilities automatically at the release manager's direction - so that population has nothing left to decide and this banner is inert for it. The MECHANISM is unchanged and its other properties still hold: off is a decision rather than a deletion, and a dismissal is not a lock. If a decision surface is wanted again, the natural population is DELEGATE groups, which have never had one. Recorded here rather than left for a reader to infer from a test that stopped asserting it."
---

# The requirement

Capability upkeep is app support, and app support happens in the manager UI.
After first implementation, no step of "this release added a capability -
decide whether your admin group gets it" may require a shell on the box.

# The problem it resolves

SM471 decided an upgrade never grants, and that stands: silently widening an
admin group's powers on upgrade is a security decision made by nobody. But
the cost surfaced on every deploy since: a permanent check warning per new
capability per site, remedied only by

    perl tools/lazysite-users.pl --docroot ... group-set lazysite-admins feedback on

which is exactly the sysadmin call-out the requirement forbids. Warning
fatigue is the failure mode: the fleet report says NEEDS A HUMAN about
something routine, until the day it says it about something that is not.

# The option table, as decided

```datatable
columns: Ref | Option | Why not / why
widths: 1.2cm | 5cm | X
bold: 1
tone: medium
---
G1 | Wildcard "all" permission at first setup | Grants FUTURE capabilities sight unseen; every who-can-do-what surface must expand it or lie; channel caps (api/mcp, SM127) can never be inside it, so it degenerates into a profile
G2 | Well-known "operators" group, first user a member | Same semantics as G1 with better legibility, same future-risk problem
G3 | Release-declared capability profiles | Moves the security decision from the operator to the release author - SM471's objection relocated, not answered
G4 | CONSENT-AT-UPGRADE (chosen) | Every grant stays an explicit, per-capability, recorded human decision - made in the UI where the admin already is
G5 | Auto-grant only to never-hand-edited groups | Unexplainable freeze semantics
G6 | Status quo: check warning + CLI command | Violates the requirement; stays only as the backstop for sites nobody logs into
```

# The mechanism (sketch, for the build)

- **Seed stamp.** Each managed group records which capability set it was
  seeded against (or last reviewed against). Existing groups without a stamp
  are treated as seeded at the version that introduces this, so the first
  banner after upgrade shows exactly the capabilities the check warns about
  today - the migration is the feature working.
- **Pending derivation.** Pending = @CAP_KEYS minus channel caps minus
  already-granted minus already-decided. Derived, never stored as a second
  truth (D2: the store is the state).
- **The banner.** Groups page, visible to manage_users holders: one row per
  pending capability per manager group - the capability's own description,
  grant / not now / dismiss. Grant writes the same store group-set writes.
  Dismiss is durable (the warning stops) and reviewable (decisions are
  listed on the same page, reversible).
- **Audit.** Every decision is an audit entry: who, when, group, capability,
  verdict - the same trail acl-set uses (SM465 shape: record the content).
- **The check.** The warning stays as the backstop but its remedy line names
  the Groups page first and the CLI second, and a DISMISSED capability is
  reported as a decision, not a warning.
- **G3-lite, later and optional.** A capability may declare "recommended for
  admin groups"; the banner pre-ticks it. A recommendation, never a grant.

# What this deliberately does not do

No capability is ever granted without a named human clicking grant. The
operator sentinel, _is_operator, SM127's channel-cap exclusions, and SM471's
never-grant-on-upgrade all stand unchanged.
