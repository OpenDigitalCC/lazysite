---
title: "SM400: a release records which commit it validated"
subtitle: "The gate's summary went to a terminal and to a gitignored file, so nothing durable said which commit had been validated. A promotion review reached 'the build that would go to beta is not the build that was validated' and nothing cheap could disprove it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19. Two records of the same fact for two different readers: the ARTEFACT attests its own gate, in release-manifest.json under `validated` (commit, files, tests), and the REPO carries docs/releases/GATE-LOG.md for whoever has the checkout rather than the tarball - which is who asks later. release.sh reads prove's own summary rather than recomputing it, and REFUSES to release if it cannot read it, because a blank row is worse than no row. The sharpest part is the pipe: capturing prove's output means piping through tee, and `if ! ( ... | tee f )` tests TEE's status - which would have made the release gate itself a control that reports success without checking. Asserted against a failing stand-in, with a control proving the same construct without pipefail does report success."
---

# What the review could not establish

A promotion review of 0.10.14 found that the only record of the last green gate
was `tmp/gate-result.txt`, which is gitignored. It could establish which
**version** was being proposed and not which **commit** had been validated, and
had to reconstruct the answer from commit dates.

Its conclusion - *the build that would go to beta is not the build that was
validated* - was reasonable on the evidence available, and nothing cheap could
confirm or refute it.

# Two records, because two different people ask

The artefact
: `release-manifest.json` gains a `validated` block: the commit, and the file
  and test counts from the gate that passed. Anyone holding the tarball can now
  answer the question from the tarball.

The repo
: `docs/releases/GATE-LOG.md`, one row per release. This is the copy that
  answers the question **without** the artefact, which is the situation the
  review was actually in.

# Three decisions

There is no `result` field
: release.sh exits before the manifest is built if the gate fails, so the only
  value it could ever hold is PASS. A field that can only say one thing reads as
  evidence while carrying none.

It refuses rather than recording a blank
: If the gate summary cannot be read from prove's output, the release stops. A
  row with empty counts is worse than no row, because it looks like a record.

The log is appended, never committed
: `release.sh` does not commit and does not push (SM303), and a release is the
  worst moment to start churning git. The operator lands it; the reminder is
  deliberately the last thing printed, after the summary, so it is not scrolled
  past.

# The pipe, which is the part that could have gone quietly wrong

Capturing prove's output means piping it through `tee`. But:

::: widebox
`if ! ( ... | tee f )` tests **tee's** exit status, and tee succeeds whatever
prove did. Written that way, the release gate becomes a control that reports
success without checking - the exact defect class this repo keeps finding, one
layer up, in the thing that is supposed to catch it.
:::

`set -o pipefail` inside the subshell fixes it. The test asserts a failing
stand-in is refused, **and** carries a control showing that the same construct
without `pipefail` reports success - because without that control the first
assertion proves nothing.

# Verification

`t/tools/34-a-release-records-what-it-gated.t`, 22 assertions: the manifest
carries no `validated` block without the facts and a complete one with them,
partial facts produce no half-attestation, the counts are numeric, release.sh
passes the commit it actually checked out, and the pipe refuses a failed gate
while its control confirms the naive form would not.
