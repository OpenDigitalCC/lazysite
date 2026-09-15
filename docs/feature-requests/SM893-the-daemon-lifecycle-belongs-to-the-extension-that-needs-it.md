---
id: SM893
title: "SM893: the daemon's lifecycle belongs to the extension that needs it, not to the operator"
subtitle: "Stated by the release manager, 2026-09-15: install, upgrade and uninstall should manage the unit; no manual step. The runtime exists so an extension can be enabled - a site running a simple lazysite may never enable it and never needs it. The extension is what depends on the daemon, so the extension is what should decide whether the unit runs."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-15
raised-by: release manager
area: installers
status-note: "REQUIREMENT recorded 2026-09-15, verbatim in substance, BEFORE the implementation was mapped; the map was then taken and folded in below. THE INTENT: (1) install / upgrade / uninstall manage the unit lifecycle with no operator intervention; (2) the runtime is REQUIRED ONLY so an extension can be enabled; (3) a plain site may never enable it and never needs it; (4) the EXTENSION is what depends on the daemon. WHAT THE MAP FOUND: (2) and (3) ARE ALREADY IN FORCE - a disabled plugin makes the supervisor exit 0, Restart=on-failure does not restart a clean exit, so `inactive dead` on a site with no extension is CORRECT AND EXPECTED and the unit's own comment says so. That confirms the benign reading of [[SM892]]'s 28 dead units, in code rather than by supposition, and gives the discriminator: exit 0/SUCCESS is a disabled plugin, exit 2 is a real fault. (1) AND (4) ARE NOT IN FORCE, AND IT SPLITS BY INSTALL FLOW: the Hestia/tarball deploy writes the conf and enables the timer for EVERY site on EVERY run regardless of intent, so the host half is automatic there but by pre-arming rather than by following intent; the deb flow arms nothing unless an operator remembered `lazysite-hestia-domain add --daemon`, so a sysop who enables the plugin there gets a runtime that never runs and no report of it. Enabling the extension provisions nothing on either path - the timer's 300s poll is what bridges the two switches, and only where the timer was already enabled. install.pl, the documented tarball upgrade, has ZERO occurrences of systemd/systemctl/lazysited in 2,461 lines. THREE THINGS FOUND ON THE WAY: apt purge leaves the per-site confs behind so a reinstall silently re-arms every instance ever provisioned; `lazysite check` never mentions the daemon at all; there is no uninstall path outside `lazysite-hestia-domain remove`. P1-P4 below are the shape of an answer, for a decision, not built."
---

# The requirement, as stated

> It is not completely clear how it is self managed, and it should not need my
> intervention; the install/upgrade/uninstall should manage the lifecycle and
> not require a manual step. And it is only required to be running so that the
> extension can be enabled; for sites that run a simple lazysite, the daemon may
> never be enabled and never required. The extension is what depends on it.

Four things follow, and they are the shape of the answer rather than a design:

| Ref | Requirement |
| --- | --- |
| I1 | Install, upgrade and uninstall manage the unit's lifecycle. No step in a runbook, no `systemctl` an operator has to remember. |
| I2 | The persistent runtime exists **so an extension can be enabled**. It is not a component of a lazysite site; it is a dependency of something optional. |
| I3 | A plain site may never enable it. Never enabled is a **normal, supported end state** — not an incomplete install. |
| I4 | The **extension** depends on the daemon, so enabling the extension is the event that should cause the unit to run, and disabling it the event that should stop it. |

# Why recording it now matters

This was stated before the implementation was read, and it is written down
before the implementation is read, deliberately. The requirement is a product
decision; what the code currently does is a separate fact, and folding the two
together is how an accident becomes a specification.

# What it would reframe

[[SM892]] records that 28 of 29 `lazysited@` units on the operator's host are
`inactive dead`, and treats the reading as unresolved — either those units ran
and stopped, or they never ran and the 0.14.1 version readings had another
cause.

**Under I2 and I3 there is a third reading, and it is the benign one**: 28 sites
have no extension enabled, so the runtime is not wanted there and `inactive
dead` is exactly right. The unit already contains a comment pointing the same
way — a runtime whose plugin is disabled exits 0 on purpose, precisely so
systemd does not restart it in a loop.

That does **not** settle SM892. It adds a candidate that is at least as likely
as the two already recorded, and it changes which reading the operator's two
`systemctl show` commands are being run to distinguish.

# How it is implemented, as mapped

## Two switches, owned by two different people

The unit says so itself (`installers/systemd/lazysited@.service:30-37`):

> **THERE ARE TWO SWITCHES, AND THAT IS INTENDED.** 1. This unit, enabled by the
> host operator. 2. The `daemon` plugin, enabled by the site's sysop in the
> manager. Both must be on for anything to run.

| | Switch A - the host half | Switch B - the site half |
| --- | --- | --- |
| What | `/etc/lazysite/daemon/<domain>.conf` + `systemctl enable --now lazysited@<domain>.timer` | `plugins/daemon.pl` in `lazysite.conf`'s `plugins:` list |
| Who | root | the site's sysop, in the manager |
| Gate | `ConditionPathExists=` on the conf | `Supervisor::should_run()` |

**The timer is the bridge, and it is the part that already matches the
intent.** `lazysited@.timer` fires `OnUnitInactiveSec=300`, and its own comment
says why: the manager has no root, so the timer *is* the operator. A sysop who
enables the plugin is picked up within five minutes with nobody doing anything.

## I2 and I3 are implemented, and confirm the benign reading

`Supervisor.pm:600-608`:

```perl
unless ( should_run($root) ) {
    log_event( 'INFO', 'daemon', 'not starting: the daemon plugin is disabled' );
    return 0;
```

Exit **0**, and `Restart=on-failure` does not restart a clean exit — so the
service settles at `inactive (dead)` with `status=0/SUCCESS`. The unit's own
comment says this is deliberate: under `Restart=always` it would be a hot loop
on every site with the plugin off, "the common case".

**So `inactive dead` on a site with no extension enabled is correct and
expected.** That is [[SM892]]'s third reading, now confirmed in code rather than
supposed. The discriminator between benign and broken is the exit status:
`0/SUCCESS` is a disabled plugin; status 2 is a real fault (no docroot, unknown
user, failed privilege drop).

## I1 and I4 are NOT implemented, and it differs by install flow

| | Tarball / Hestia | Deb |
| --- | --- | --- |
| Conf written | **every deploy**, unconditionally (`lazysite-hestia-deploy.sh:245-252`) | only if the operator passes `lazysite-hestia-domain add … --daemon` |
| Timer enabled | **every deploy**, unconditionally (`:263`) | only with that same flag |
| Re-asserted on upgrade | yes — the deploy rewrites conf and re-enables each run | no |

So:

- **On the tarball path I1 effectively holds**, but by *pre-arming every site*
  rather than by following intent. The mechanism is on for sites that will never
  use it; the cost is a short-lived process every five minutes per disabled
  site, and the visible artefact is `inactive (dead)` — the state an operator is
  most likely to misread as broken. Which is exactly what happened.
- **On the deb path I1 fails.** A site onboarded without `--daemon` has no conf,
  so `ConditionPathExists` never passes. A sysop who then enables the plugin
  gets a runtime that never runs, and the only diagnosis is the manager's Status
  button.
- **I4 is not implemented on either.** Enabling the extension does not create the
  conf or enable the timer. It works on the tarball path only because the host
  half was armed for everyone in advance.

`install.pl` — the documented tarball upgrade ([[SM892]]) — contains **zero**
occurrences of `systemd`, `systemctl`, `lazysited` or `/etc/lazysite` in 2,461
lines. It is entirely unaware that any of this exists.

## Three things found on the way

| Ref | Finding |
| --- | --- |
| F1 | **`apt purge` leaves the confs behind.** `postrm` runs `daemon-reload` and nothing else; `/etc/lazysite/daemon/*.conf` and `/etc/lazysite/pools/*.conf` survive. Reinstalling the package silently re-arms every instance ever provisioned. |
| F2 | **`lazysite check` is blind to all of it** — zero occurrences of `daemon` or `lazysited`. The one command an operator runs to ask "is this site healthy?" never mentions the runtime, so drift is only visible to someone who presses Status in the manager. |
| F3 | **There is no uninstall path at all** outside `lazysite-hestia-domain remove`. [[SM721]] files it; nothing implements it. |

## What reconciliation exists

One reader, and it lives in the site rather than the operator tooling:
`Supervisor::host_provisioning` (`:268-291`) matches the conf to this site and
probes `is-enabled` on the timer and `is-active` on the service, feeding a
verdict that ends at `inconsistent`. It **reports** and names the remedy; it
does not reconcile, and nothing calls it except the manager's Status button and
`lazysited --status`.

# What has to be established

Not assumed, and the map is being taken:

All four questions below were asked before the map was taken and are now
answered above: Q1 the Hestia deploy and `lazysite-hestia-domain --daemon`; Q2
no; Q3 the tarball deploy re-asserts one-directionally, nothing else; Q4 only
the manager's Status button. Kept as the record of what was asked.

| Ref | Question | Answer |
| --- | --- | --- |
| Q1 | What creates and removes the conf the unit gates on | Deploy script (every run) or `add --daemon`; removed only by `lazysite-hestia-domain remove` |
| Q2 | Does enabling the extension enable and start the unit | **No.** The timer polls and picks it up — but only where the timer was already enabled |
| Q3 | Do install / upgrade / uninstall reconcile want against enabled | Tarball deploy re-asserts the host half every run; deb does nothing; no uninstall |
| Q4 | Does anything notice the disagreement | Only `Supervisor::host_provisioning`, via the manager's Status button |

# What would satisfy the intent

Not a design, and not built — the shape the answer would take, for a decision
rather than for implementation:

| Ref | Change | Which requirement |
| --- | --- | --- |
| P1 | Enabling the extension provisions the host half, or refuses with the reason. The manager has no root, so this means either the timer is armed for every site by construction (the tarball behaviour, made deliberate and documented) or the plugin refuses to enable and says which root command is missing | I4 |
| P2 | The deb per-site onboarding stops depending on a remembered `--daemon` flag | I1 |
| P3 | `lazysite check` reports the daemon's state, so drift is visible where an operator already looks rather than only in the manager | F2, and [[SM890]]'s gap |
| P4 | Purge removes the confs it left, or the units refuse a conf with no registered site | F1 |

P1 carries the only real decision: **arm every site and accept idle units as
normal, or arm on demand and make the extension refuse clearly when it cannot.**
The first is what the tarball path does today by accident; the second is what
the deb path half-does by omission. Choosing deliberately is what turns
`inactive dead` from a thing operators misread into a thing the product says.

# Related

[[SM892]] (the dead units and the upgrade path), [[SM891]] (the unit's own
defects), [[SM890]] (nothing names a site's service template), [[SM757]] (the
persistent runtime), [[N142A]] (which restarts these units on upgrade).
