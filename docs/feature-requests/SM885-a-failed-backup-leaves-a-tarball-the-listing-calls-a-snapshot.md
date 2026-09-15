---
id: SM885
title: "SM885: a failed backup leaves a 20-byte tarball that the listing shows as a snapshot"
subtitle: "t/unit/manager/64 already asserts this must not happen, and the assertion is right - the refusal path unlinks the file it claimed. It is beaten by a process nobody waits for: `tar -z` forks gzip, tar exits, we reap TAR, and the orphaned gzip recreates the name we just removed. Measured, with the compressor isolated as the writer by a control arm."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-15: tar writes into a staging directory and the finished archive is renamed into the claimed name, so the pipeline the engine cannot wait for never holds a path the listing reads. Removal is RENAME-THEN-DELETE, which the first attempt was not - see 'The fix that was not enough' below, where measurement caught an incomplete fix that had already passed its own test. t/unit/manager/192 drives it deterministically with a fake tar that forks a punctual orphan, and fails without the fix naming the resurrected tarball. Verified against the original symptom too: 60 of 60 runs of t/unit/manager/64 at concurrency 8, and 480 rounds of the naming probe under load with no residue of any kind. REPRODUCED 2026-09-14, not graded from reading. Surfaced as an intermittent failure of t/unit/manager/64 under the handoff's -j4 run (7 of 40 runs at concurrency 8; 0 of 300 serially - it needs load). The subtest's directory is a per-process tempdir, so no sibling test can write into it: whatever is in there was put there by the code under test. Instrumented, the refusal path behaves CORRECTLY - waitpid reaps the right child, status 2, and the unlink succeeds - and the file reappears 400ms later at 20 bytes, the size of an empty gzip stream. Control arm isolates the writer: the same doomed tar run with `czf` resurrected the name 12 times, with `cf` 0 times in 360. It is the compressor, which tar forks and this code never waits for. NOT a test-isolation problem and NOT a regression; the window is old. Also a nuisance to the release loop, because the suite it fails is the one that gates a cut."
---

# What an operator would see

A backup that failed sits in the Backups listing as a snapshot. It is 20 bytes
— an empty gzip stream — and restoring it restores nothing.

The refusal is reported correctly at the time. The artefact appears afterwards,
so the listing and the refusal disagree, and the listing is what somebody reads
three weeks later when they need the backup.

# Why the existing guard does not hold

`Manager::Backups::action_backup_create` claims its filename atomically
(`_claim_name`, `lib/Lazysite/Manager/Backups.pm:212`) and, on any failure,
removes it — with the reason written next to it
(`Backups.pm:689`):

> ```
> # Drop the placeholder we claimed, or a failed snapshot sits in the
> # listing as a zero-byte tarball that reads as a usable one.
> unlink $out;
> ```

That is exactly right, and `t/unit/manager/64` asserts it. Both are correct. The
problem is that `unlink` is not the last write to that name.

**`tar czf` forks `gzip`.** We fork tar and `waitpid` on tar. When tar fails
early — a `-C` it cannot enter — it exits and we reap it, while gzip is still
alive, orphaned to init, and holding the job of producing the output. It then
recreates the name we removed.

So the code waits for the process it started and not for the process that does
the writing.

# Measured, not reasoned

Instrumenting a replica of the fork/exec/waitpid block
(`Backups.pm:647-659`) at the point the module gives no seam to observe:

```
round=26 waitpid_returned=975323 expected=975323 status=2 \
         child_still_alive=0 unlink_worked=1 size_after_400ms=20
```

Every fact about our own handling is clean — right child, real status, the
unlink *worked* — and the file is back 400ms later. Nothing about the refusal
path is wrong.

**The control arm names the writer.** The same doomed tar, twice, differing only
in whether tar forks a compressor:

| command | name came back |
|---|---|
| `tar czf …` (forks gzip) | 12 |
| `tar cf …` (no helper)   | 0 of 360 |

Without that arm this would have been filed against the refusal path, which is
not at fault.

# Why it showed up now

It did not; it showed up *at all*. The window needs tar to fail early enough
that gzip is still running when tar's status is collected, which needs the host
under load. 7 of 40 at concurrency 8, and 0 of 300 run serially.

That also makes it a **release-loop nuisance**: the suite this intermittently
fails is the one that gates a cut, so it can refuse a build for a reason that
has nothing to do with the build. A gate that fails at random is a gate people
learn to re-run rather than read.

# The fix, as built

**Take the doomed pipeline off the final name.** tar writes to a staging path;
on success it is `rename`d into the claimed name. On failure, the claimed
placeholder and the staging file are both removed.

An orphaned gzip can then only recreate the *staging* name, which is never a
`.tar.gz`, never enters the listing, and is swept on the next run. The backups
directory holds finished artefacts only — a better invariant than "we tidy up
afterwards", because it does not depend on winning a race.

`_claim_name` is untouched: the atomic reservation still does its job, and
nothing else can take the name between the claim and the rename.

# The fix that was not enough, and how that surfaced

The staging fix above was built, its new test passed, and the original flaky
test passed 40 of 40 under load. On that evidence it was done.

Re-running the **naming probe** — which reports what is left rather than only
whether a test passed — said otherwise: the tarball was gone, and in 4 of 300
rounds a `.stage-<pid>-<time>` **directory** survived instead.

`remove_tree` unlinks the staged file and then rmdirs the directory. An orphan
that recreates its file between those two steps makes the rmdir fail on a
non-empty directory. The archive was gone, so the defect an operator sees was
genuinely closed — but `backups/` still had an intermittent entry, which is the
same flaky assertion one layer down. The fix would have moved the flake rather
than removed it, and `t/unit/manager/64` would have gone on failing
occasionally for a new reason.

**Rename first, then delete** (`_drop_staging`). A rename is atomic and takes
the whole subtree out of reach in one step: from that instant the path the
orphan holds has no parent, so its open fails and nothing new can appear;
anything it had already created moves with the directory and is removed with
it. Both interleavings end empty, with no timing assumption and no retry.

After it: 480 rounds under load with no residue of any kind, and 60 of 60 runs
of the original test at concurrency 8.

The lesson worth keeping is not about tar. **A passing test is not a
measurement.** The test asserts the thing I thought to assert; the probe
reports what is actually there, and that is what caught a fix I had already
concluded was complete.

## Considered and not chosen

- **Waiting for the compressor.** Correct in principle, and it would mean owning
  both halves — `tar cf -` piped into a `gzip` we fork ourselves, then reaping
  both. It is the more thorough answer and it gives tar's status separately from
  gzip's. It is also open-heart surgery on a block carrying the reasoning of
  SM378, SM381 and SM769, for a race the staging fix closes structurally. Worth
  revisiting if a second symptom appears from the same cause.
- **Unlinking again, later.** Loses to the same race it is trying to win.
- **Tolerating it in the test.** The test is right. The 20-byte file is the
  defect, not the assertion.

# Related

[[SM378]] (say why a backup failed), [[SM381]] (tar exit 1 is a warning; the
STDERR-redirect hazard in a persistent worker), [[SM769]] (reaching the private
store without opening its parent).
