# Dimension 8 - Policy compliance - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial (CRA Article 13 manufacturer duties)
- Prior verdict: WARN (2026-07-18)

## Verdict

**REFUSE**, on two conditions.

The Declaration of Conformity is still drafted, unsigned, and stamped **0.8.0**,
while the project has since shipped **three further stable releases** - 0.9.4,
0.9.10 and 0.10.0 (F8.1). Under the declared Commercial regime, a stable release
is the artefact the declaration attaches to. Three have gone out without one.

Second, and with a nearer date: the posture of record addresses CRA **Article
13** in detail and **Article 14 not at all** (F8.6). There is no reference
anywhere in the tree to the incident and actively-exploited-vulnerability
reporting duties, no named accountable person for them, and no runbook. The
project has already had one live exposure this period, so this is not a
theoretical gap.

This is a paperwork refusal rather than an engineering one, and the distinction
is worth stating: nothing here says the product is unsafe. It says the project
is shipping stable releases faster than it is executing the compliance
procedure it wrote for itself, and D8 is the dimension whose entire job is to
notice that.

The supply-chain half of this dimension is in reasonable order: the licence
position is clean, the support-period commitment is declared, and the strict
SBOM gate is the right mechanism - though it cannot be run from the tag it
attests (D6 F6.6).

## Method

- Read `docs/DECLARATION-OF-CONFORMITY.md` for its version stamp and signature
  state.
- Compared that against the stable releases in `CHANGELOG.md`.
- Walked the CRA Article 13 obligations table in `docs/POLICY.md` item by item
  and checked each claim against the tree.
- Ran the strict SBOM gate.

## Findings

### F8.1 - Three stable releases have shipped against an unsigned 0.8.0 declaration (REFUSE)

`docs/DECLARATION-OF-CONFORMITY.md`:

| Field | Value in the tree |
|---|---|
| Subtitle | "draft for the 0.8.0 stable release" |
| Version | "0.8.0 - placeholder, to be finalised at the 0.8.0 stable cut" |
| Unique identification | git tag `v0.8.0`, tarball `lazysite-0.8.0.tar.gz` |
| Place and date of issue | "To be completed at the 0.8.0 stable cut" |
| Signature | "(unsigned draft)" |

Stable releases since: **0.9.4** (2026-07-19, changelog says "certified"),
**0.9.10** (2026-07-21), **0.10.0** (2026-07-27).

The 2026-07-18 review recorded this as "DoC stamped 0.8.0 - signature is the
operator action at the cut", which was correct then: the cut had not happened.
It has since happened three times over, and the declaration was neither advanced
nor signed. Two of those three changelog entries describe themselves as
certified, which the declaration does not support.

Remedy is the responsible person's action, not an engineering one: finalise and
sign a declaration for the current stable (0.10.0), and make advancing it part
of the stable-cut procedure so it cannot be missed again. Note that the
changelog's own convention already distinguishes stable promotions clearly, so
the trigger is unambiguous.

### F8.2 - The obligations table is itself out of date (WARN, cross-referenced to D7 F7.2)

`docs/POLICY.md:34` describes the quality-and-documentation-floors obligation as
partial, citing the **2026-07-01** review's WARNs as in progress. Those were
resolved in July across two subsequent reviews. The posture-of-record document
therefore under-reports the project's actual position on the one obligation
where it has made most progress, while over-reporting nothing.

### F8.3 - The pentest waiver expiry is approaching and is a policy commitment (WARN)

ADR 0007 defers the first third-party engagement with a hard expiry: **the first
engagement by 2026-12-31, or the first GA marketing, whichever comes first**.
That is four and a half months out. After expiry, an absent report is a refusal
condition rather than a deferral.

Two things follow. First, procurement lead time for a CREST-CRT/OSCP/GIAC-GPEN
third-party engagement is not short, so the engagement needs booking well before
the date. Second, the waiver's ongoing validity depends on the significant-change
register being kept, and it is not being kept (D6 F6.2) - so the waiver is
currently weaker than the ADR intends.

### F8.4 - Supply chain and licensing (PASS)

- **Strict SBOM gate**: the right mechanism form of the obligation. A release
  fails if the code imports a module not declared in
  `dist/config/sbom-deps.json`, so the SBOM cannot silently drift during a
  build. It could not be executed on the audited tree, because it needs a
  gitignored build artefact - so the claim holds at release time and is not
  reproducible from the tag afterwards (D6 F6.6).
- **Licence** MIT, with `LICENSE`, `COPYRIGHT` and `THIRD-PARTY-NOTICES.md`
  present and consistent.
- **SBOM** generated per release in CycloneDX and shipped in the tarball.
- **Support period** declared: five years from the first stable release (0.7.0),
  security fixes on the stable channel.
- **Coordinated vulnerability disclosure** in place via `SECURITY.md`.

### F8.5 - Obligations still open, unchanged since July (noted, not new)

| Obligation | Status |
|---|---|
| Annex VII technical file | pending |
| Signed releases (Sigstore/cosign) | pending |
| OpenChain 5230 + 18974 written policies | pending |
| CE marking | due 11 Dec 2027, noted, not applied |

None is a refusal condition today. The Annex VII file and signed releases both
become materially harder the longer the release history grows, which is the
retrofit asymmetry this framework is built around - they are cheap now and
expensive later.

## Maintaining compliance

Everything above is remediation - fix these stale records. This section is the
other half, and it is the half that decides whether the same review has to be
written again in six weeks: the machinery for *keeping* compliance rather than
restoring it.

### F8.6 - CRA Article 14 (reporting) is absent from the posture of record (REFUSE)

`docs/POLICY.md` walks Article 13 manufacturer duties obligation by obligation.
Article 14 - reporting actively exploited vulnerabilities and severe incidents -
appears nowhere in the repository:

```
$ grep -in "article 14\|reporting\|ENISA\|CSIRT\|24 hour\|72 hour" docs/POLICY.md
(no matches)
```

The CRA phases its obligations. My understanding is that the Article 14
reporting duties apply from **11 September 2026** - four weeks from this review -
while the bulk of the regulation applies from 11 December 2027, which is the
date `docs/POLICY.md` already records for CE marking. **Both the date and the
scope judgement need confirming by the legal review the DoC already says is
required**; this finding is raised because the obligation with the *nearer* date
is the one that is missing entirely, not because the interpretation is settled.

Three things follow, and none of them is a document:

- **A named accountable person.** The DoC names a function ("Responsible person,
  Open Digital CC") and no individual for reporting. A 24-hour clock is met by
  someone reachable who knows the procedure, or it is not met.
- **A runbook.** There is no incident or reporting runbook in the tree at all -
  no `docs/` file matching *incident* or *runbook*. The path from "we have
  discovered a live exposure" to "notify whom, by when, with what evidence" is
  currently unwritten.
- **A rehearsal.** The same argument D5 makes about restore rehearsals applies
  with more force here: an untested reporting procedure under a 24-hour clock is
  a plan, not a capability.

SM283 is the worked example and the reason this is not hypothetical. Gated
static files were served anonymously across a fleet for weeks. Nothing suggests
it was exploited - but had it been, the obligation would have been an early
warning within 24 hours, and there was no mechanism to produce one.

### F8.7 - The declared remediation SLAs have no evidence (WARN)

ADR 0007 declares remediation SLAs as part of the pentest posture: critical 72h,
high 30d, medium 90d, low 180d, with retest required for critical and high.

Nothing records whether any of them has been met. There is no vulnerability
register - no dated list of what was found, when, its severity, when it was
fixed, and when it was retested. SM283's remediation was in fact fast, and that
cannot be demonstrated from the repository.

A declared SLA with no record is an assertion. One dated register turns the
existing good behaviour into evidence, which is what an auditor, a customer
questionnaire or an Annex VII file will each ask for. It is also the natural
place for the Article 14 decisions to be recorded ("assessed, not actively
exploited, no notification required" is itself a finding worth dating).

### F8.8 - Dated obligations are scattered, and one is written relatively (WARN)

Every dated commitment lives in a different document, and no single view exists:

| Obligation | Date | Recorded in |
|---|---|---|
| CRA Article 14 reporting applies | 2026-09-11 (to confirm) | nowhere |
| Pentest waiver expiry | 2026-12-31 | `docs/adr/0007-pentest-deferral.md` |
| CE marking | 2027-12-11 | `docs/POLICY.md` |
| Support period ends | **2031-07-10** | `docs/POLICY.md`, relatively |

The support period is written as "five years from the first stable release
(0.7.0)". 0.7.0 was cut 2026-07-10, so the commitment runs to **2031-07-10** -
but a relative date decays the moment a reader has to work out which release was
first stable, and this project has already renumbered its stable line three
times since. Write the absolute date beside the rule.

One dated obligations register, with an owner per row, is the artefact. It is
also the natural thing to gate: a release-gate check that fails when a listed
date is inside its lead time is the same mechanism this review recommends for
the records, applied to the calendar.

### F8.9 - Annex VII and signed releases get monotonically more expensive (WARN)

Both are listed pending (F8.5), and both have the property that deferring costs
more than doing:

- **The Annex VII technical file is mostly assembly, not authorship.** Four
  eight-dimension reviews, the SBOMs, the ADRs, the DoC, the coverage and bench
  records and the test results already exist. Started now as an *index* over
  those artefacts, it is a short document that stays current as a by-product of
  work already happening. Started in 2027 it is an archaeology exercise across
  three release lines.
- **Signed releases cannot be applied retroactively.** Every release cut without
  Sigstore/cosign attestation is permanently unattestable. The cost of delay is
  strictly monotonic, and unlike most of this list it can never be paid down.

This is the retrofit asymmetry the framework is explicitly built around, and
these are the two clearest instances of it in the project.

### F8.10 - There is no per-project implementation document (WARN)

The framework expects each project to author its own implementation document
from `IMPLEMENTATION-TEMPLATE.md` - regime assignment, posture, monitors,
migration plan - and keep it inside the project. `find` returns nothing matching
*IMPLEMENTATION* in the tree.

`docs/POLICY.md` covers part of the ground, which is probably why the absence
has not been noticed across four reviews. But the template's monitors and
migration-plan sections are exactly the two things this review found missing
elsewhere (D5 F5.2's absent `MONITORS.md`, and the operator steps that package
upgrades do not deliver). Authoring the implementation document would have
surfaced both without a review.

## Evidence

- `docs/DECLARATION-OF-CONFORMITY.md:3`, `:9-15`, `:26-27`, `:103-104`.
- `grep -in "article 14|reporting|ENISA|CSIRT" docs/POLICY.md` - no matches.
- `CHANGELOG.md:2393` - 0.7.0 first stable, 2026-07-10.
- `docs/adr/0007-pentest-deferral.md` - the declared remediation SLAs.
- `CHANGELOG.md` - stable cuts at 0.9.4, 0.9.10, 0.10.0.
- `docs/POLICY.md:29-45` - the Article 13 obligations table.
- `docs/adr/0007-pentest-deferral.md:53-58` - the waiver expiry.
- `tools/manifest-to-sbom.pl --strict` on a clean worktree - `rc=2`, cannot read `release-manifest.json`.
