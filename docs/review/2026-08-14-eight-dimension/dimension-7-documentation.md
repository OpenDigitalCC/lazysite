# Dimension 7 - Documentation - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: WARN (2026-07-18, at 0.7.28)

## Verdict

**WARN**, close to refusal on one item. The five-audience taxonomy is present and
the reference documentation is in unusually good health - several documents are
now *generated* or *lint-pinned to the code*, which is the strongest form this
dimension can take. What fails is currency of the narrative documents: the
feature timeline stops eight releases back (F7.1), and the policy document cites
a review two generations old as the current one (F7.2).

F7.1 is the same item this dimension raised and cleared at the 0.8.0 gate. A
documentation item that regresses within four weeks of being fixed is a process
finding, not a writing finding, and is treated as such in the recommendations.

## Method

- Checked the five-audience taxonomy for presence and for currency separately -
  presence has never been the problem here.
- Compared every narrative document's newest referenced version against the
  audited tree's version.
- Checked which documents are mechanically defended (generated, or pinned by a
  lint) versus maintained by hand.

## Findings

### F7.1 - The feature timeline stops at 0.9.14; the whole 0.10.x line is missing (WARN, regression)

`docs/FEATURES.md` Part XIII is the feature timeline, and its most recent entry
is **0.9.14 (2026-07-24)**. Its closing summary states the document covers the
project "to v0.9.14". The audited tree is **0.10.8**.

Absent from it:

- **0.10.0 STABLE** (2026-07-27) - a stable promotion, the kind of release an
  operator reads this document to understand;
- the 0.10.1-0.10.6 line;
- **0.10.7 and 0.10.8** - which include SM283's remedy and the SM285-SM293
  programme, described in the changelog itself as "the largest structural change
  in the 0.10 line".

The 2026-07-18 review recorded "FEATURES.md timeline swept to 0.7.28" as the D7
stable-gate item and cleared it. Four weeks later the same document is eight
releases behind. The pattern says the sweep is being done as review remediation
rather than as part of cutting a release, so it will keep regressing until it
moves into the release procedure or is generated.

### F7.2 - `docs/POLICY.md` cites the 2026-07-01 review as the current one (WARN)

`docs/POLICY.md:34`, in the CRA Article 13 obligations table - the project's
stated posture of record:

> the 2026-07-01 eight-dimension review found WARN on several dimensions and its
> follow-up actions are in progress (see `docs/review/2026-07-01-eight-dimension/`)

Two further full reviews have happened since (2026-07-10 and 2026-07-18), and
this is the fourth. The 2026-07-01 findings it describes as "in progress" were
resolved in July. A compliance document that points a reader at a superseded
assessment misrepresents the project's posture in the conservative direction,
which is the less harmful direction but is still wrong. `docs/POLICY.md:64`
carries the same stale pointer.

### F7.3 - ADR 0001's text no longer describes its own arrangement (WARN, carried from D1)

ADR 0001 speaks of "one recorded copy" of the module-free logic the render path
carries. The audited tree has several, each now pinned by a lint that compares
*answers* rather than text (`t/lint/35`, `t/lint/37`, and on the pending SM294
branch `t/lint/42`). The engineering is sound and arguably stronger than the ADR
describes; the ADR simply has not been rewritten to say so. Carried forward from
the 2026-07-18 deferred list, where it was also not done.

### F7.4 - The mechanically-defended documentation is the strong part (PASS, noted)

Worth recording because it is where this project has moved ahead of its own
framework:

- `docs/reference/capability-map.md` is **generated**, and regeneration is
  required after any `Capabilities.pm` edit.
- `docs/architecture/access-control-model.md` is **pinned to the code** by
  `t/lint/36`, so the access model cannot drift from what is enforced.
- The **manager UI guide** is lint-enforced against the actual navigation
  (`t/lint/32`).
- `t/lint/27` asserts that documentation references real paths, and `t/lint/26`
  ties backlog status to the changelog, so a filing cannot claim to have shipped
  something a release does not mention.
- The **CHANGELOG** is exceptionally strong: each release explains the cause,
  not just the change, and several entries state plainly what an operator must
  do that a package upgrade will not do for them.

The distinction that matters for the recommendations: **every document in this
list is defended by a mechanism, and every document in F7.1-F7.3 is maintained
by hand.** The hand-maintained ones are the ones that rotted. That is the same
finding this project has now made four times about hand-maintained *lists* in
tests, applied to documents.

## Evidence

- `docs/FEATURES.md:1572` (newest timeline entry), `:1808` (the "to v0.9.14"
  statement).
- `docs/POLICY.md:34`, `:64`.
- `docs/review/2026-07-18-eight-dimension/00-overview.md` - the D7 item cleared
  at the 0.8.0 gate.
