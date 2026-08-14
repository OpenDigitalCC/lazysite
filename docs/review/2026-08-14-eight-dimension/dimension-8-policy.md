# Dimension 8 - Policy compliance - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial (CRA Article 13 manufacturer duties)
- Prior verdict: WARN (2026-07-18)

## Verdict

**REFUSE**. The Declaration of Conformity is still drafted, unsigned, and
stamped **0.8.0**, while the project has since shipped **three further stable
releases** - 0.9.4, 0.9.10 and 0.10.0 (F8.1). Under the declared Commercial
regime, a stable release is the artefact the declaration attaches to. Three have
gone out without one.

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

## Evidence

- `docs/DECLARATION-OF-CONFORMITY.md:3`, `:9-15`, `:26-27`, `:103-104`.
- `CHANGELOG.md` - stable cuts at 0.9.4, 0.9.10, 0.10.0.
- `docs/POLICY.md:29-45` - the Article 13 obligations table.
- `docs/adr/0007-pentest-deferral.md:53-58` - the waiver expiry.
- `tools/manifest-to-sbom.pl --strict` on a clean worktree - `rc=2`, cannot read `release-manifest.json`.
