---
title: "Eight-dimension non-functional review - the lazysite daemon service, before 0.13.1"
subtitle: "main at 53df9a44, 2026-09-05, Commercial regime - a scoped review of one new component, run at the release manager's instruction before its first edge cut with real work"
brand: plain
standard-margins: true
---

# Current state, in one line

**The daemon service refuses two dimensions of eight at the audited commit, and
both are cleared on one branch with the reproductions as tests.** The refusals
are the same defect seen twice: the supervisor's restart path did the opposite
of what its own description promised, and nothing had ever run it enabled.

```barchart
caption: Dimension verdicts at 53df9a44 (before the fix branch)
axis: H
style: full
---
PASS: 2
WARN: 4
REFUSE: 2
```

```datatable
columns: # | Dimension | At 53df9a44 | With claude/sm755 landed | Material finding
widths: 0.7cm | 2.6cm | 1.6cm | 2.2cm | X
bold: 2
tone: medium
text: 5
---
1 | Correctness | REFUSE | PASS | a dying service restarted for ever, uncounted, reported on (F1.1); the gate read once (F1.2)
2 | Code quality | PASS | PASS | mechanical gates clean; a fourth atomic writer and a fourth conf parser, repository-wide condition
3 | Test coverage | WARN | WARN, improved | Supervisor at 45.7% statement, the run loop at zero; 06 and 07 now run it enabled
4 | Performance | WARN | WARN | ~10.6 MB PSS per instance, two processes; rollup 0.56 s warm hourly; idle rename fixed
5 | Reliability | REFUSE | WARN | five of six experiments wrong: duplicate schedulers, off not off, pid as proof, no stop deadline, silent torn record - all fixed; never run on a real host
6 | Security | PASS | PASS | no interface, no egress, drop follows the pool; the register lacks an entry (D7/D8)
7 | Documentation | WARN | WARN | operator guide, developer guide, security register and an architecture sentence do not know it exists
8 | Policy | WARN | WARN | significant-change entry expected by precedent and absent; the deb has no postinst
```

# What this is

A scoped eight-dimension review of **one component**: the persistent runtime
SM666 phase 1 shipped in 0.13.0 and 0.13.1 completed with real jobs and a
provisioning flag. It was run because the release manager asked for it ("this
new service must be tested against the 8 dimensions") between the build and the
cut, and because the service had - at the time of review - never run anywhere
but under `prove`.

Scope: `lib/Lazysite/Daemon/**` (Supervisor, Scheduler, Jobs),
`lib/Lazysite/Lifecycle.pm`, `tools/lazysited.pl`, `plugins/daemon.pl`,
`debian/lazysited@.service`, `lazysite-hestia-domain add --daemon`,
`Lazysite::Manager::Sessions::sweep_expired`, and the tests that hold them. The
repository-level verdicts (the unsigned declaration, the stale obligations
anchors) are noted where met and not re-assessed.

Audited from a clean worktree at `53df9a44`, the commit at which the five
0.13.1 Tier 1/2 branches had landed. Run in signoff order. The reviewer wrote
most of the code under review in the preceding two days, which the method
treated as a reason to measure rather than read.

# The finding that matters

`plugins/daemon.pl` tells a sysop: *"A service that keeps dying is reported as
FAILED rather than restarted forever."* At the audited commit a service that
died at once was forked again every two seconds indefinitely, with no failure
counted, no WARN written, no backoff, no ceiling, and `status()` reporting `on`
because `kill 0` succeeds on a zombie. Twelve seconds, backoff base 2:

```
status while running: verdict=on service=on
'service started' lines: 7
'service exited' lines:  0
```

The cause is the order of two loops (the reap forgot the child before the
failure branch could see it) and the reason it shipped is that
`t/unit/daemon/01-05` prove the *disabled* path with care and never start the
supervisor enabled - Supervisor.pm at 45.7% statement coverage, the run loop at
zero. D5's experiments then found the same absence five more ways: two
supervisors on one docroot run two schedulers; the plugin disabled underneath a
running daemon changes nothing; any live pid in the pid file reads as a running
service; a stop has no deadline; a torn record is silently "everything due".

All of it is fixed on **`claude/sm755-supervisor-restart-path`** (filed as
SM755), with `t/unit/daemon/06` reproducing the crash loop against the pre-fix
code (mutation-checked) and `07` holding the lock, the orphan adoption, the
pid-is-not-proof rule and the torn-record WARN. The branch also closes D1 F1.3
(a mistyped job account refused as a typo) and D4's idle rename.

# What holds, and is worth saying

- **Disabled means no process**, asserted on the filesystem, and now honoured
  *after* start as well as before.
- **The identity gate fails closed in every direction**, a refusal does not
  consume the slot, and `needs` is read from the manager API's own gate table so
  a job cannot need less than the manager charges.
- **The stats rollup runs the real plugin** under the job and closes yesterday
  with nobody reading the statistics - SM343's failure made impossible by a
  clock, and measured at 0.56 s warm.
- **No interface, no egress, no shell, no string-loaded code**; the drop is the
  pool's, verbatim.
- **The design record is complete** (SM666) and the Hestia README is the model
  operator text; the gaps are in the documents *other* audiences read.

# What this review could not do

Run the service as a host runs it. Every measurement here is unprivileged,
without the unit, without the sandbox directives, without `--daemon` having
written a conf on a real `/etc/lazysite/daemon/`. D5 F5.8 and D4 F4.4 say what
to measure on the first provisioned instance; until then the reliability
verdict is WARN by construction, whatever the tests say.

# Recommendations, ranked, with owner and trigger

```datatable
columns: # | Action | Owner | Trigger | Dimension
widths: 0.7cm | X | 2.2cm | 3.4cm | 1.6cm
bold: 1
tone: medium
text: 2
---
1 | Land claude/sm755-supervisor-restart-path | release manager | before the 0.13.1 cut | D1, D5, D4
2 | Significant-change entry + trust-boundary line in docs/SECURITY.md; OPERATOR.md daemon subsection; recast the performance.md sentence | dev agent | pre-cut pass, 0.13.1 | D7, D8
3 | Memory figure into the Hestia README's cost paragraph | dev agent | pre-cut pass, 0.13.1 | D4
4 | Provision one real instance on edge with --daemon; run the D5 shapes by hand; record | release manager + dev agent | after 0.13.1 deploys to edge | D5, D6
5 | Establish why lazysite-common ships no postinst; fix for both units | dev agent | 0.13.2 | D8, D5
6 | DEVELOPER.md paragraph; ADR 0011 from SM666's decisions | dev agent | 0.13.2 | D7
7 | Shared atomic-JSON writer and plugin-conf reader; daemon adopts first | dev agent | filing, unscheduled | D2, D1
```

Items 1-3 are scheduled: they are the pre-cut pass. Item 4 has a trigger and
two owners. Items 5-7 are named for a release or marked unscheduled, so the
next review can hold this one to what it said rather than to what it hoped.

# Files

- `dimension-1-correctness.md` .. `dimension-8-policy.md` - method, findings,
  recommendations per dimension
- `findings.json` - the mechanically checkable half, `verify` exits 0 when fixed
- `tmp/review-0131/` (untracked, project scratch) - every script that produced a
  number here
