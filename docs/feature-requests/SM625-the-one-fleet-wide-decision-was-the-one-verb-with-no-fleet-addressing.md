---
title: "SM625/SM626/SM627: a fleet of 26 healthy sites reported as 26 needing a human, and the one action left could only be done in a shell loop"
subtitle: "From the 0.11.1 fleet repair. Every site: 43 ok, 0 failures. Summary: '0 clean, 0 repaired, 26 need a human'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26). THREE DEFECTS ONE FLEET RUN MADE VISIBLE AT ONCE. SM626: `repair` counted a pending DECISION as an unfixed DEFECT - the sites' only outstanding item was that a group seeded before this release has not been told what to do about capabilities the release added, which CANNOT be repaired and clears when a human decides. Bucketing it with genuine failures put 26 healthy sites in the worst bucket, made the tally unable to ever improve, and exited non-zero, so a scheduled fleet run goes red permanently and stops being read. Split into 'awaiting your decision' and 'need a human', by the doctor's own [ FAIL ] marker rather than by matching the capability sentence, which would rot the next time that wording changes; exit status follows failures only. SM625: the verb that SETTLES that decision was the one verb with no fleet addressing. SM321 gave --domain/--all to `check` and `acl`; `repair`, `probe` and `migrate-engine-tree` have it; `users` was left a pure pass-through - so the one action needed across 26 sites was the only one that required a shell loop, which is exactly what the operator wrote. SM627: the second warning, generated registries left in the document root, was reported and never repairable, so it too pinned every site. The file must not stay - the front end resolves it BEFORE the engine, so a sitemap frozen on upgrade day is served for good - but the action is NOT 'delete': the engine deliberately yields to an operator's own sitemap or llms.txt and NOTHING ON DISK SAYS WHICH IT IS, because the shipped templates emit no generator marker. So --fix MOVES it to lazysite/backups/stale-registries/ with the time it was moved. The stale file stops being served, the engine serves a current one, and an operator's own file is recoverable by name - the recoverable-vs-irreversible line SM587/SM591 drew for data, applied to a file: this tier may act BECAUSE what it does can be undone. MY OWN TEST CAUGHT A HOLE IN MY OWN SAFETY MECHANISM: the stamp has one-second resolution, so two repairs inside the same second landed on the same name and move() would OVERWRITE - destroying the copy the whole design exists to keep. It never overwrites now. And two of my assertions were blind under sabotage: one extracted the `users` block by 'up to the next closing brace' and, when the block was collapsed to a one-liner, read on into `acl` - which does have the addressing - so it passed by testing a different verb; the other checked that 'FAIL' appeared somewhere in cmd_repair, which it does several times, so removing the split entirely still passed. Both now pin the specific line."
---

# What the run said, and what was true

| Reported | Actual |
|---|---|
| `0 clean, 0 repaired, 26 need a human` | 26 sites, 43 ok, **0 failures** each |

# The two warnings, and why neither could clear

| Warning | Why it stood |
|---|---|
| capabilities undecided | only a human can decide - and the verb to apply it had no `--all` |
| generated files in the docroot | reported, never repairable |
