---
title: "Dimension 7 - Documentation - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

WARN - the five-audience core exists and `docs/FEATURES.md` is the framework's own canonical worked example, but the SM095 group-capability rewrite (0.5.12-0.5.31) landed in code and CHANGELOG without a documentation sweep: six locations across repo docs and four across the site-served docs still describe the retired per-account/`manager_groups` model, the raw log download removed in 0.5.29 is still documented, and the ADR set, man pages, `docs/SECURITY.md`, `MONITORS.md` and `ACCESSIBILITY.md` are absent.

## Method

Assessed at tag `v0.5.35`, commit `de12238` (verified with `git describe --tags`; working tree clean apart from this review directory). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 7 detail (five-audience taxonomy, expected file map, ADR structure and ADR-worthiness test). Work performed:

- File-by-file audit of the expected taxonomy map against the repo (`ls`, targeted reads).
- Currency spot-checks: five claims across `FEATURES.md` / `IMPLEMENTOR.md` / `USER.md` / `OPERATOR.md` compared with the code at v0.5.35 (`lib/Lazysite/Auth/Settings.pm`, `lazysite-auth.pl`, `lazysite-manager-api.pl`, `plugins/stats.pl`) and with CHANGELOG entries 0.5.20-0.5.35.
- CHANGELOG keying check and release-presence check for 0.5.22-0.5.35.
- Contradiction sampling of three topics that overlap between `docs/` and the site-served `starter/docs/` set.
- `--help` run against `tools/lazysite-users.pl`, `tools/lazysite-check.pl` and `install.pl` (man-page interim assessment).

## Findings

### F7.1 - Taxonomy file map (WARN)

```datatable
columns: Expected artefact | State | Evidence
widths: 5cm | 2.5cm | X
bold: 1
tone: medium
text: 3
---
README.md | present | 169 lines; evaluator quickstart + feature list
docs/FEATURES.md | present | 759 lines; named in TOOLCHAIN.md as "the canonical worked example the team has in production"
docs/USER.md | present | 53 lines; pointer document deferring to the site-served docs (see F7.7)
docs/DEVELOPER.md | present | 51 lines; thin
docs/IMPLEMENTOR.md | present | 56 lines; currency defect (F7.2)
docs/OPERATOR.md | present | 74 lines; runbook; no release-channel guidance (F7.7)
docs/POLICY.md | present | 54 lines; assessed under Dimension 8
SECURITY.md (root) | present | CVD policy; not the threat-model home the framework expects at docs/SECURITY.md
UPGRADE.md | present | 212 lines
CHANGELOG.md | present | keyed and complete (F7.4)
docs/SECURITY.md | missing | no STRIDE threat model or ASVS record; docs/architecture/security.md is a security-model description, not a threat analysis
docs/ACCESSIBILITY.md | missing | no conformance statement for the manager UI or shipped themes
docs/MONITORS.md | missing | no operational-monitors register
docs/SPECIFICATION.md | missing | per-feature specs live in docs/feature-requests/SM*.md; no merged spec, and DEVELOPER.md (51 lines) does not absorb it as the small-project collapse would
docs/traceability.csv | n/a | framework marks it commercial-regulated; regime is Commercial
docs/adr/ | missing | directory does not exist (F7.6)
man/<bin>.1 | missing | no man/ directory (F7.8)
```

Classification: WARN for each missing row that applies to the Commercial regime. `docs/development.md` also duplicates the developer audience alongside `DEVELOPER.md` (minor; merge or cross-reference).

### F7.2 - Currency: repo docs still describe the pre-SM095 permission model (WARN)

The current model, verified in code: capabilities are channel caps plus action caps (`lib/Lazysite/Auth/Settings.pm:21-26` - `@CAP_KEYS` is `ui webdav api mcp manage_content manage_nav manage_forms manage_themes manage_layouts manage_config manage_users analytics audit create_sub_users delegate_sub_user_creation`), resolved from the account's groups only (`Settings.pm:91-96`, "SM095 clean cut ... no per-user grants"), stored in `groups-settings.json` and edited on the Groups page (CHANGELOG 0.5.13, 0.5.20, 0.5.24). `manager_groups` survives only as a non-breaking fallback (`lazysite-auth.pl:917-921`), and its Config-page field was retired in 0.5.31. Stale statements:

```datatable
columns: Location | Stale claim | Reality at v0.5.35
widths: 4.5cm | X | X
bold: 1
tone: medium
text: 2 * 3
---
docs/FEATURES.md:281-282 | "Per-user boolean grants in user-settings.json" | groups-only union from groups-settings.json (0.5.20 clean cut)
docs/FEATURES.md:284-292 | capability table lists 8 capabilities | code carries 15; api, mcp, manage_nav, manage_forms, manage_users, analytics and audit (0.5.25) are absent from the table
docs/FEATURES.md:363-364 | manager UI access "requires ... membership in a manager_groups group" | requires the ui capability (0.5.22); manager_groups is a fallback only
docs/FEATURES.md:385 | Users page has "per-account capability toggles" | capabilities are edited per group on the Groups page (0.5.13/0.5.24)
docs/FEATURES.md:630 | operator obligation: "set manager_groups (empty = any authenticated user is a manager)" | the obligation is now group/capability assignment; the empty-fallback caveat needs restating against the ui capability
docs/IMPLEMENTOR.md:45 | first-run: set "manager_groups:" in lazysite.conf "or the manager Config page" | the Config-page field was retired in 0.5.31 (CHANGELOG:60)
```

Classification: WARN - `FEATURES.md` is the auditor's map of the territory per the framework; a wrong authorisation model in it misleads exactly the procurement/audit audience it serves.

### F7.3 - Currency: removed raw log download still documented (WARN)

CHANGELOG 0.5.29 (line 77): "Synthesised error surface; raw log download removed". Verified in code: `lazysite-manager-api.pl` has no log-download action (only `file-download`, `backup-download`, `file-zip-download` at lines 465-476). Yet `starter/docs/manager.md:180` still states the stats dashboard "offers an operator-only raw access-log download". A stale code comment also survives at `plugins/stats.pl:16` (references the retired download endpoint). `starter/docs/ai-briefing-stats.md:20` is already correct ("the tool [never sees] the raw log"), so `starter/docs` contradicts itself on this topic.

### F7.4 - CHANGELOG keying and completeness (PASS)

`CHANGELOG.md:14-17` declares the convention: released versions keyed by tag, unreleased entries keyed by SM number and short commit ref - conforming to the commit-ref-keyed house convention. Verified all of 0.5.22 through 0.5.35 present (lines 21-168), newest first, each entry high-level with a dated heading. One source of truth for "what changed" holds.

### F7.5 - starter/docs vs repo docs: contradiction sample (WARN)

Three overlapping topics sampled:

```datatable
columns: Topic | starter/docs says | docs/ says | Contradiction?
widths: 3cm | X | X | 3cm
bold: 1
tone: medium
text: 2 * 3
---
Manager access control | manager_groups is the mechanism (auth.md:260-266, configuration.md:75, manager.md:223-225) | manager_groups group membership (FEATURES.md:364) | no - but both contradict the code (ui capability)
Where capabilities are edited | per-account on the Users page (manager.md:136); Groups page described as membership-only (manager.md:139-143) | per-account toggles on Users page (FEATURES.md:385) | no - both stale the same way
Visitor stats raw log | download exists (manager.md:180) vs never exposed (ai-briefing-stats.md:20) | FEATURES.md makes no download claim | yes - internal to starter/docs
```

The two doc sets do not diverge from each other; they rotted in lockstep because the SM095 and 0.5.29 changes updated neither. The failure is systemic (no doc-currency step in the release flow), not a fork between the sets. The `starter/docs` set is otherwise strong - the AI briefings (including `ai-briefing-building-sites.md`, added 0.5.23) are current on the topics sampled.

### F7.6 - No ADRs; five standing decisions are unrecorded (WARN)

`docs/adr/` does not exist. The framework's warning applies directly here: dimension 1's review already found an unrecorded divergence around the SM095 resolver. The five most ADR-worthy standing decisions, each verified on disk and each a concrete ADR to write:

```datatable
columns: ADR | Decision | Evidence on disk
widths: 4.5cm | X | X
bold: 1
tone: medium
text: 2 * 3
---
0001-uncommitted-tree-release-contract | releases cut from an uncommitted working tree the operator reviews and commits; diverges from the vcs-review default | CLAUDE.md:12-17; docs/development.md:6-15
0002-channel-action-capabilities-groups-only | authorisation is channel caps x action caps, resolved from groups only, one resolver for all four surfaces | lib/Lazysite/Auth/Settings.pm:18-26,91-96; SM095
0003-two-bucket-install-classification | every shipped file is code (always overwritten) or seed (operator content, preserved); provenance stamp distinguishes lazysite content from operator content | dist/config/classification.json; 0.5.33 preservation fix; 0.5.35 provenance stamp
0004-edge-stable-release-channels | every release defaults to edge; --final marks stable; per-site update_channel selects | tools/release.sh:41-54; starter/docs/features/configuration/update-channel.md
0005-raw-mode-self-contained-artifacts | api: true serves the body as data, bypassing Markdown pipeline and layout entirely | starter/docs/api.md; starter/docs/frontmatter.md:62
```

All five are retrospective ADRs (valid per the framework). ADRs 0002 and 0003 are the most urgent: both were nearly violated recently (the four parallel capability readers found by dimension 1; the 0.5.33 upgrade data-loss bug in the seed model).

### F7.7 - Audience-doc depth and gaps (WARN, minor)

`USER.md` (53 lines) is a deliberate pointer to the site-served docs - defensible, since `starter/docs/` ships inside every installation and is the canonical user reference, but the deferral should be recorded in the project manifest as the taxonomy mapping the framework allows. `OPERATOR.md` carries no mention of the edge/stable release channels or `update_channel` (grep: no hits), although the operator is exactly who chooses a channel; the only channel documentation is site-served (`starter/docs/features/configuration/update-channel.md`).

### F7.8 - Man pages absent; --help is a reasonable interim (WARN, minor)

No `man/` directory. The three operator CLIs were run with `--help`: `tools/lazysite-users.pl` (full command table including the SM095 `permissions` grid), `tools/lazysite-check.pl` (all options, exit-status contract) and `install.pl` (install/upgrade semantics, `--dry-run`) all produce complete usage text. That satisfies the day-to-day need but not the framework's `man/<bin>.1|.8` per shipped binary; `lazysite-users.pl` is installed to the target host (classification.json), so the requirement applies.

## Recommendations

1. SM095 currency sweep - correct the six repo-doc locations in F7.2 and the four starter-doc locations in F7.5 (capability table regenerated from `@CAP_KEYS`, `manager_groups` re-described as legacy fallback, Groups page documented as the capability editor). Where: `docs/FEATURES.md`, `docs/IMPLEMENTOR.md`, `starter/docs/{manager,auth,configuration}.md`. Effort: M. Gate: Dimension 7 currency.
2. Remove the raw-download claim at `starter/docs/manager.md:180` and the stale comment at `plugins/stats.pl:16`. Effort: S. Gate: Dimension 7 currency.
3. Create `docs/adr/` with the five retrospective ADRs of F7.6, framework structure (Status/Date/Tags, Context/Decision/Rationale/Consequences). Effort: M. Gate: Dimension 7 ADR set; also closes dimension 1's unrecorded-divergence finding for 0002.
4. Write `docs/SECURITY.md` as the threat-model home (STRIDE over the four write surfaces, ASVS verification record), promoting and cross-referencing `docs/architecture/security.md` rather than duplicating it. Effort: L. Gate: Dimension 7 taxonomy; feeds the Dimension 8 technical file.
5. Add `docs/MONITORS.md` - register the monitors that already exist in practice (stats plugin error surface, `lazysite-check.pl` health doctor, audit log review) with cadence and last-run. Effort: S. Gate: Dimension 7 taxonomy.
6. Add a release-channel section to `docs/OPERATOR.md` (edge vs stable, `update_channel`, when to `--final`). Effort: S. Gate: Dimension 7 currency/audience fit.
7. Generate man pages for `lazysite-users.pl`, `lazysite-check.pl` and `install.pl` (POD in-script, `pod2man` at release; the --help text is 80% of the content already). Effort: M. Gate: Dimension 7 man-page requirement.
8. Write `docs/ACCESSIBILITY.md` - a conformance statement for the manager UI and default theme against a declared WCAG target (the `docs/reference/manager-colour-contrast.md` work is a starting point). Effort: M. Gate: Dimension 7 taxonomy.
9. Record the taxonomy mapping in the project manifest: USER defers to site-served docs; SPECIFICATION is the per-feature SM document set. Effort: S. Gate: Dimension 7 taxonomy (the mapping the framework says "the project's manifest records").
