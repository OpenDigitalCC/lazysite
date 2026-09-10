---
title: "SM835: the engine log has no reader, so messages designed to be read cannot be"
subtitle: "Sites agent, 1311E-01 and 1311E-06, 2026-09-10: two deliberately-worded log messages went unverified in one run, because nobody outside the host can read them"
brand: plain
standard-margins: true
status: candidate
---

# What happened twice in one run

Two refs asked a tester to quote a log line. Both failed for the same reason:

- **1311E-01**, [[SM786]]'s double-escape warning - the message that names the
  table, the column and the remedy, written specifically so an author who did
  not write the code could act on it.
- **1311E-06**, [[SM817]]'s deprecation INFO - the message that names the new
  spelling.

Reported: no shell on the host, `/lazysite/` denied to a partner token over
`file-download`, and the manager exposes no log action - `log-tail`, `logs`,
`log-read`, `error-log` and `audit-log` are all unknown actions. The audit log,
which IS reachable, carries neither message, because neither is an audited act.

# The pattern worth naming

**We keep designing log messages for an audience that cannot reach them.**

Both of those messages exist because someone reasoned carefully about who would
read them and what they would need to do next. SM786's is explicitly aimed at a
site author with a `| html` filter in a template. SM817's is aimed at an
operator deciding when the old spelling can go. Neither reader has a route.

That makes the care that went into the wording unverifiable - which is how
1311E-01 and 1311E-06 both closed with a caveat rather than a result - and it
means the message quality is never tested by its actual audience.

# The shape, and the reason to be careful

An engine-log reader on the manager is the obvious answer and it is a genuine
disclosure surface: the log carries paths, account names, config keys, and the
internals of failures. So it is not a `cat` behind a button.

Constraints that fall out of the two cases above:

- **A capability of its own**, not carried by `manage_config`. Reading the
  engine's log is a different authority from configuring a site - the shape
  [[SM579]] settled for connector destinations and [[SM222]]'s design pass
  applies to the audit trail's switch.
- **Tail and filter, not download.** The cases here are "show me the last N
  lines" and "show me lines matching this", which is what a tester or an author
  needs and is much narrower than handing over the file.
- **Read-only, and audited.** Reading the log is itself an act worth recording,
  by the same argument that governs the audit trail's own switch.

Whether it belongs on the manager, the control API, or both is open. The
tester's request was specific and modest: "say how to reach it and I will" -
so even a documented, capability-gated path would close the immediate gap.

# Related

[[SM786]] and [[SM817]] (the two unverified messages), [[SM831]] (the audit log
cannot answer the retirement question either - the same blindness one layer
over), [[SM222]] (status reporting, and where a unit's evidence should surface).
