---
title: "SM328 - the release stages onto a bounded filesystem, and only tidies up when it succeeds"
subtitle: "The gate runs in /tmp, and exhausts its INODES rather than its bytes - Devel::Cover writes a directory per instrumented process, and this suite spawns thousands. Every failed run leaves them behind."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11 - release.sh takes --stage-dir (default ${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}), traps EXIT so an interrupted run cleans up, refuses early when the staging filesystem lacks inodes or space, and --keep-stage opts out for inspecting a failure. The host rule is written into docs/development.md. VERIFIED by driving it: /tmp with 1.03M free inodes is refused in seconds with exit 5 having staged nothing, /srv with 3.14M is accepted, and a run killed mid-flight leaves nothing behind. MY OWN FIRST VERSION OF THE CHECK WAS BROKEN in the way this filing is about - `df -i --output=iavail` is refused by coreutils as mutually exclusive, so the variable was empty and the check silently passed. Corrected, and an unreadable reading is now reported rather than skipped. CORRECTED 2026-08-16 - the first version of this filing blamed SIZE and was wrong. The binding constraint is INODES: df -h showed 3% used while df -i showed 1048576/1048576 at 100%, which is why 14G free on / was such a misleading reading. Devel::Cover writes one runs/<id>/ directory per instrumented PROCESS at ~6 files each, and this suite drives real CGI subprocesses rather than mocking them - two integration files alone produce 53 runs. A bigger tmpfs would not have helped; only more inodes or a real filesystem does. FILED 2026-08-16 after a release aborted with ENOSPC on a host reporting 14G free on /. It was not the root filesystem: /tmp is a separate 4.8G tmpfs, and release.sh hardcodes STAGE=/tmp/lazysite-release-$$. The residue looked innocuous - 122MB across the leftovers - because it does not reflect the PEAK, which includes the clone, a full test run and a Devel::Cover database. Two independent faults that compound; both are small."
---

# What happened

A cut of 0.10.11 failed with `ENOSPC: no space left on device` on a host with
**14G free on `/`**. That is not where it was writing:

```
tmpfs           4.8G   ...   /tmp
```

`release.sh` line 48: `STAGE=/tmp/lazysite-release-$$`.

The tooling was blocked hard enough that no command could run at all - the
harness could not create a process's output file - so diagnosis needed a shell
outside the session.

# Two faults, which compound

## 1. The staging directory is on a bounded filesystem, by hard-coding

A release does not merely clone into `$STAGE`. It runs **the entire gate** there:
the full suite, the perf bench, and a Devel::Cover coverage run over 380 test
files. So the peak is the clone plus everything the gate generates.

**IT RUNS OUT OF INODES, NOT BYTES**, and that is why every early reading was
misleading. At the moment of failure:

```
tmpfs           4.8G   139M  4.7G    3%   /tmp     <- bytes: fine
tmpfs        1048576 1048576     0  100%   /tmp     <- inodes: exhausted
```

The host reported **14G free on `/`** and `/tmp` reported 97% of its bytes
available. Nothing in the obvious place to look showed a problem.

The cause is `Devel::Cover`, which writes one `runs/<id>/` directory per
instrumented **process**, roughly six files each. This suite deliberately drives
real CGI subprocesses rather than mocking them, so every one is a separate run:
measured here, **two integration test files alone produce 53 runs**. The gate
runs 380 files.

```datatable
columns: Consumer | Inodes
widths: 8.4cm | X
bold: 1
tone: medium
---
the repo clone, including `.git` | ~9,400
`cover_db`, at ~6 files per instrumented subprocess | the rest of 1,048,576
---
```

The clone is not the problem. **A larger tmpfs would not have helped** - only
more inodes, or a filesystem that does not cap them so tightly.

The leftovers after a failed run measured 122 MB, which is why they looked
harmless in bytes. Byte size was never the constraint.

**The host has a standing rule that build scratch goes on `/srv`, because the
root filesystem is small.** The rule is not written down in this repository, so
nothing could have enforced it - and `release.sh` was written to `/tmp` without
anyone weighing that.

**A sibling tool already does the right thing.** `tools/lazysite-cli.pl` honours
`$TMPDIR` when choosing a scratch directory. The convention exists in the
codebase; the release tool simply does not follow it.

## 2. Cleanup runs only on success

```bash
# --- cleanup ---
rm -rf "$STAGE"
```

That is the last line of the happy path. There is no `trap`, so **any** failure
leaves the whole clone behind: a failing test, a refused gate, an interrupt, a
power cut, or - as here - the disk filling.

The file already documents one instance of exactly this, and did not generalise
it:

> the previous behaviour left the tarball stranded in the staging directory with
> the artefact copy and cleanup unreached, and reported failure for a release
> that had in fact been built and tagged.

That was fixed for one specific step. The pattern was left.

## Why they compound

Either alone is survivable. Together, every failed release permanently consumes
several hundred thousand inodes of a fixed 1,048,576, and nothing reclaims them.
Four cuts in a day - two for 0.10.10, one abandoned, two failed - is enough.

And the failure is total rather than graceful: with inodes exhausted, no process
on the host could create a file in `/tmp`, including the agent harness's own
command-output files. Diagnosis required a shell outside the session.

# The fix

Take the scratch location from the environment
: `--stage-dir DIR`, defaulting to `${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}`, so a
  host with a small `/tmp` can point it at `/srv` once and never think about it
  again. This is what `lazysite-cli.pl` already does for its own scratch.

Clean up on the way out, not on the way past
: `trap 'rm -rf "$STAGE"' EXIT`, set as soon as `$STAGE` exists. A failed run
  then costs nothing but the time. Keep an opt-out - `--keep-stage` - because a
  gate failure is exactly when someone wants to look inside.

Say what it needs before it starts, and check the right thing
: the gate knows it is about to clone and then run coverage. A pre-flight check
  turns an hour-long run that dies mysteriously into a five-second refusal
  naming the directory and the shortfall - but it must check **inodes as well as
  bytes** (`df -i`), because bytes were never what ran out and a size-only check
  would have passed cheerfully both times.

Write the host rule down
: "build scratch goes on `/srv`; the root filesystem is small" exists only in the
  operator's head. A rule nobody can read is one every new tool breaks.

# Why this is worth more than its size

This is the third time this fortnight that a tool worked and its **housekeeping**
did not: SM325 tagged correctly onto a commit no branch contained, SM304's readers
handled a missing manifest and not a corrupt one, and this stages correctly and
tidies up only when nothing goes wrong.

All three share a shape - the success path is complete and the failure path is an
afterthought - and all three cost real time to something that was never the
interesting part of the job.

# Related

SM303 (the same tool conflating two jobs for two parties, and the `--no-fetch`
incident quoted above), SM325 (its tagging guard), SM304 (the manifest reader
that handles absent and not corrupt), and `tools/lazysite-cli.pl`, which honours
`$TMPDIR` and is the precedent.
