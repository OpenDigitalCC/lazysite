---
title: "SM328 - the release stages onto a bounded filesystem, and only tidies up when it succeeds"
subtitle: "A full repo clone plus the whole gate runs in /tmp, which on this host is a 4.8G tmpfs; every failed run leaves the clone behind, and four runs in a day filled it"
brand: plain
status: candidate
status-note: "FILED 2026-08-16 after a release aborted with ENOSPC on a host reporting 14G free on /. It was not the root filesystem: /tmp is a separate 4.8G tmpfs, and release.sh hardcodes STAGE=/tmp/lazysite-release-$$. The residue looked innocuous - 122MB across the leftovers - because it does not reflect the PEAK, which includes the clone, a full test run and a Devel::Cover database. Two independent faults that compound; both are small."
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

```datatable
columns: What lands in the staging directory | Size
widths: 8.4cm | X
bold: 1
tone: medium
---
the working tree | 235 MB
its `.git` | 66 MB
the coverage database, test temp dirs, the built tarball | the rest
---
```

The leftovers after a failed run measured 122 MB, which is why they looked
harmless. That is the residue, not the peak.

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
~300 MB of a 4.8 GB filesystem, and nothing reclaims it. Four cuts in a day - two
for 0.10.10, one abandoned, one failed - is enough.

# The fix

Take the scratch location from the environment
: `--stage-dir DIR`, defaulting to `${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}`, so a
  host with a small `/tmp` can point it at `/srv` once and never think about it
  again. This is what `lazysite-cli.pl` already does for its own scratch.

Clean up on the way out, not on the way past
: `trap 'rm -rf "$STAGE"' EXIT`, set as soon as `$STAGE` exists. A failed run
  then costs nothing but the time. Keep an opt-out - `--keep-stage` - because a
  gate failure is exactly when someone wants to look inside.

Say what it needs before it starts
: the gate knows it is about to clone ~300 MB and run coverage. Checking free
  space at the staging location first, and refusing with a clear message, turns
  an hour-long run that dies mysteriously into a five-second refusal that names
  the directory and the shortfall.

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
