---
id: SM792
title: "SM792: the daemon hardening residue"
subtitle: "Security review, 0.13.8. The items below the four filed daemon findings, kept together because none of them is a live escalation and each is a small decision: an env override that can name any script, a forged-state kill path, an unbounded post-KILL wait, an unchecked gid drop, and what Status discloses while disabled."
brand: plain
standard-margins: true
status: candidate
---

# What this holds

Seven notes from the 0.13.8 daemon review that are genuine and lower priority.
They sit on the same-uid or systemd-controlled boundaries: the runtime runs as
the dropped site user, and every file under `lazysite/daemon/` is writable by
that user, so an actor who could exploit these could already signal those
processes and write those files.

- **The stats-tool env override.** `Jobs.pm` returns `$ENV{LAZYSITE_STATS_TOOL}`
  first and unconditionally, and runs it. Not reachable today - the environment
  is the root systemd unit's and `_spawn` adds nothing site-controlled - so this
  is a lever only for something that already owns the daemon's environment. The
  direction is the one used elsewhere: gate the override behind a test-only
  sentinel so the production path can only run the deploy's own plugin.
- **The forged-state kill path.** The pid file and the state file are
  same-uid-writable and `/proc` is world-readable, so a pid and a start time can
  be copied in and the adopt-by-stopping block will TERM then KILL that pid.
  Confined: the supervisor has dropped privilege, so the worst effect is
  signalling a same-uid process the actor could signal itself. Compounds with
  SM788. The direction is to check `/proc/<pid>` ownership before adopting,
  rather than re-deriving trust from a file the actor can write.
- **The post-KILL wait is unbounded.** A blocking `waitpid` after `kill 'KILL'`
  hangs the supervisor's own shutdown if the child is in uninterruptible sleep.
  A short bounded poll, as `_wait_gone` already does, and log-and-move-on.
- **The gid drop is unchecked.** `$)` and `$(` are assigned without verifying
  the result, while the uid drop is checked twice. Defensive only; add the
  matching assertion for symmetry.
- **Status discloses own-site host metadata while disabled**, gated on
  `manage_config` and scoped to the caller's own site. A decision about what
  Status is for, not a leak across a boundary.
- **Unit sandboxing** additions, and the `daemon_job_user` delegation for the
  threat-model document.

# What is asked

Nothing urgent. Each is independently actionable and the release manager
decides which, if any, ride a release. They are recorded here so that the next
daemon pass starts from what this one found rather than rediscovering it.

# Provenance

`inbox/2026-09-08-daemon-security-review-hardening-notes.md`, with the index at
`inbox/2026-09-08-daemon-0.13.8-security-review.md`, which also re-verified the
designed invariants as holding: a job is engine code, the identity gate is
fail-closed in every direction, there is no new remote surface, and the
privilege drop is correct.
