# Dimension 5 - Reliability and resilience - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-07-18); REFUSE at 2026-07-10, cleared by
  `docs/RELIABILITY.md`

## Verdict

**WARN**. The declaration that cleared this dimension in July is intact and
still accurate, and the mechanisms behind it work. What has lapsed is the
evidence the declaration itself demands: the restore-rehearsal cadence stopped
four stable releases ago (F5.1), and the monitor document that the SLOs assume
somebody is keeping has never been written (F5.2). Neither is a Commercial
refusal condition, but a declared commitment that quietly stopped being met is
exactly the failure this dimension exists to notice - and it is the second
review in a row to note the monitor gap.

One in-period defect belongs here as well as under D1: a failure mode the design
had explicitly planned for was **unreachable in practice** (F5.3).

## Method

- Read `docs/RELIABILITY.md` against what has actually shipped since it was
  written, rather than against itself.
- Checked the rehearsal register's cadence claim against the release history in
  `CHANGELOG.md`.
- Checked the deferred items the 2026-07-18 review left on this dimension.

## Findings

### F5.1 - The restore-rehearsal commitment has lapsed for four stable cycles (WARN)

`docs/RELIABILITY.md` states the rule itself:

> Rehearsals are repeated **at least once per stable release cycle**.

The register's last entry is **2026-07-12** (the 0.7.13 stable cycle). Since
then the project has cut four stable releases:

| Stable release | Date | Rehearsal recorded |
|---|---|---|
| 0.8.0 | 2026-07-18 | none |
| 0.9.4 | 2026-07-19 | none |
| 0.9.10 | 2026-07-21 | none |
| 0.10.0 | 2026-07-27 | none |

This is not a claim that restore is broken - the mechanism is covered by the
failure-mode suite, and the last six rehearsals all completed in under a second
of mechanical restore. It is that the RTO of 4 hours and the RPO values are
declared to be *backed by timed rehearsals*, and for the four most recent stable
releases they are backed by the declaration alone. The 2026-07-18 review already
flagged "a 0.7.28 restore rehearsal not yet recorded" as deferred; it was
deferred rather than done, and three more cycles have passed.

Remedy: run one rehearsal against the current stable tarball and record it, then
either hold the per-cycle cadence or amend the declared cadence to one the
project will actually meet. A commitment that is quietly not met is worse than a
looser commitment that is.

### F5.2 - `docs/MONITORS.md` still does not exist (WARN, carried)

The SLO section assumes an operator-side monitor "that measures availability",
and the 2026-07-18 review recorded the absent monitor document and capacity test
as deferred. Neither has appeared. The file is referenced as an intended
artefact and is absent from the tree:

```
$ ls docs/MONITORS.md
ls: cannot access 'docs/MONITORS.md': No such file or directory
```

Because reliability ownership is explicitly **per implementation** (the
2026-07-04 decision, restated at `docs/RELIABILITY.md:16-25`), this is not a
refusal: the project ships the mechanism and each operator declares their own
targets. But an operator taking the reference posture as their posture of record
has no shipped guidance on what to monitor to know whether they are meeting it,
which makes the reference posture undeliverable as written for exactly the
operators who most need it.

### F5.3 - A planned-for failure mode was unreachable, so the system failed hard where it was designed to degrade (WARN, cross-referenced to D1 F1.1)

The private-store design anticipated an unmovable store and specified the
behaviour precisely:

> A failed move does not refuse the rule. The ACL is stored and the engine
> honours it, so the site is no worse off than before the store existed - but
> the response says so, because both outcomes look identical to the operator
> otherwise.

The warning text existed and was correct. It could not be reached, because the
guard preceding it sat after a croaking call (D1 F1.1). So the designed
graceful degradation became a 500 and an absent audit line.

The resilience lesson is narrower than the bug: **a declared failure mode with
no test that exercises it is a comment**. The remedy branch adds one
(`t/unit/manager/73`) which blocks the store deterministically with a file where
its directory must be - no `chmod`, so it behaves identically for an
unprivileged user and for root - and asserts the warning, the stored rule and
the untouched content together, because the fix is only correct if all three
hold at once.

### F5.4 - What is genuinely solid here (PASS, noted)

- The RPO-zero-for-code claim remains true and is structural rather than
  aspirational: every release is an immutable git tag (ADR 0002).
- `lazysite check` gained a store-usability report on the remedy branch, which
  is the right shape - it answers the operator's question on the affected host
  and stays quiet on sites that have never protected anything.
- The pool's `MAX_REQUESTS` recycle and the SM294 relay timeout (on the pending
  branch) both address the same class: a single bad request must not be able to
  take a worker, and therefore a site, down.

## Evidence

- `docs/RELIABILITY.md:116-140` - the cadence rule and the rehearsal register.
- `CHANGELOG.md` - stable cuts at 0.8.0, 0.9.4, 0.9.10, 0.10.0.
- `docs/review/2026-07-18-eight-dimension/01-resolution.md:55-63` - the deferred
  items, both still open.
