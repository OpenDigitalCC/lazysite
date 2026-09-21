---
id: SM894
title: "SM894: three tests edit tracked files in the working tree, and a run that does not finish leaves them edited"
subtitle: "VERSION, SIGNOFF.md, RELIABILITY.md and the practice briefing are written by the suite and restored on the way out. Reproduced: kill the run mid-test and VERSION stays at 99.0.0, which then fails t/lint/63 on every later run - including the one somebody starts to find out what is wrong. Nothing in the suite notices."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-21
raised-by: engine agent
area: testing
status-note: "REPRODUCED, not inferred: `perl t/tools/52-...t`, SIGKILLed once VERSION had changed, leaves `VERSION` reading 99.0.0 as a modified tracked file, and leaves its own backup behind in /tmp. Three test files write tracked repo files - t/tools/52 (VERSION, docs/compliance/SIGNOFF.md), t/tools/57 (docs/compliance/SIGNOFF.md, docs/RELIABILITY.md), t/unit/tools/71 (starter/docs/ai-briefing-practice.md). Two restore in an END block, which covers a die and does not cover a signal; the third restores INLINE, so an ordinary die leaves the briefing edited. All three keep their backup in /tmp, against the standing rule that test rigs live under the project's own tmp/ - and /tmp is shared with every other job on the host. THE COST IS DELAYED AND MISATTRIBUTED: the damage shows up later as t/lint/63 failing on a tree nobody edited, so the next person debugs the lint. That is how this was met. The mutation itself is the right design and this filing does not propose mocking - the switch is a real file the tool really reads. What is missing is one owner for the idiom and a gate that notices."
---

# What happens

Three test files write files that are tracked in git:

| File | Tracked files it writes | Restored by |
| --- | --- | --- |
| `t/tools/52-human-signoff-is-masked-not-removed.t` | `VERSION`, `docs/compliance/SIGNOFF.md` | an `END` block |
| `t/tools/57-the-conformity-gate-attaches-to-certified.t` | `docs/compliance/SIGNOFF.md`, `docs/RELIABILITY.md` | two `END` blocks |
| `t/unit/tools/71-the-briefing-states-its-engine-version-once.t` | `starter/docs/ai-briefing-practice.md` | an inline `copy()` near the end of the file |

**The mutation is not the defect.** Each of these needs the real file because
the tool under test really reads it, and `t/tools/57` says so in its own
comment: *"A test that needs the project to be broken cannot be run on a
healthy project."* Mocking the switch would test the mock. This filing proposes
nothing about that.

# The reproduction

Fork the test, poll `VERSION` until it changes, then `SIGKILL` — which is what
an interrupted `prove`, a gate timeout or an OOM kill looks like from the
test's point of view. `END` blocks do not run.

```perl
my $before = read_version();
my $pid = fork() or exec $^X, 't/tools/52-human-signoff-is-masked-not-removed.t';
for ( 1 .. 4000 ) {
    last if read_version() ne $before;
    select undef, undef, undef, 0.002;
}
kill 'KILL', $pid;
waitpid $pid, 0;
print 'VERSION after: ' . read_version() . "\n";
```

```text
VERSION before: 0.14.2
mutated to: 99.0.0, then SIGKILLed
VERSION after: 99.0.0

$ git status --porcelain VERSION
 M VERSION
```

A softer version of the same thing also leaves the backups behind:

```text
$ kill -INT <pid>      # Ctrl-C on a prove run
$ ls /tmp/lazysite-signoff-*
/tmp/lazysite-signoff-switch-4024604
/tmp/lazysite-signoff-version-4024604
```

Those files are the evidence the `END` block did not run — it unlinks them.

# Why the cost is worse than the mutation

`VERSION` at `99.0.0` fails `t/lint/63-the-version-file-is-not-behind-the-newest-tag.t`.
So after an interrupted run:

- the whole suite is red on a tree where nothing was edited;
- the failure names a file and a tag, neither of which anyone touched;
- and the next run — the one somebody starts *to find out what is wrong* — is
  red for the same reason.

That is how this was found: a broken intermediate state of my own left
`VERSION` at `99.0.0`, and the visible symptom was a version lint nobody had
been anywhere near.

# Three separate faults, and they want different fixes

| Ref | Fault | What would close it |
| --- | --- | --- |
| M1 | The restore is per-file, written three times, and one of the three does not use `END` at all — so an ordinary `die` in `t/unit/tools/71` leaves the practice briefing edited. | One owner in `t/lib/TestHelper.pm`: something like `preserve_tracked($path)` that copies the file, registers the restore, and is the only way this is done. Three hand-written copies of one lifecycle is the drift shape [[SM304]] and [[SM269]] were both about. |
| M2 | The backups live in `/tmp/<name>-$$`. The project's rule is that test rigs live under the project's own `tmp/`, and `/tmp` is shared with every other job on this host. | The same helper, writing under the repo's `tmp/`. |
| M3 | **Nothing notices.** No gate asks whether the suite left a tracked file modified, so the answer arrives later, attributed to something else. | A check that compares the tracked working tree before and after a run and fails naming the file and the test that last had it open. This is the one worth having even after M1 and M2 - it catches the fourth test nobody has written yet. |

M3 is the one that matters. M1 and M2 make the current three safe; M3 is what
makes the next one safe, and the pattern this project keeps closing is the one
where a fix lands wherever the author was looking and survives everywhere else
([[SM864]], [[SM872]], [[SM892]]).

# What is NOT claimed

- **No evidence this has cost anything in the field.** It is a developer- and
  gate-facing fault: the files involved are read by `tools/lazysite-compliance.pl`
  and the version lint, not by a site.
- **The `END`-block pair is not broken for the ordinary case.** A test that
  fails an assertion, or dies, restores correctly. Only a signal or a kill gets
  past it, and `t/unit/tools/71` is the one that does not need even that.
- **No frequency measure.** One occurrence, mine, on 2026-09-21. The
  reproduction above says the mechanism is real; it says nothing about how
  often anybody hits it.

# Related

[[SM304]] (one owner for the release-manifest lifecycle — the same shape, for
the same reason), [[SM269]] (the shared repo-root manifest, and what a
hand-kept lifecycle per test cost there), [[SM892]] (found during its
documentation sweep).
