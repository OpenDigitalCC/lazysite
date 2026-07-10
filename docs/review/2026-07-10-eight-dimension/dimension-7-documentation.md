---
title: "Dimension 7 - Documentation - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

REFUSE - the taxonomy is now near-complete and most 2026-07-01 findings are closed (ADRs 0001-0006, `docs/SECURITY.md` STRIDE/ASVS threat model, `docs/ACCESSIBILITY.md`, the SM095 currency sweep, CLI POD, the OPERATOR channel section), but two of the framework's named documentation refusal conditions are met at the reviewed tag: the SM138 retirement of `manager_groups` (0.6.5) missed the security-tier documents - root `SECURITY.md`, `docs/architecture/security.md` and the Hestia install runbook still present the retired key as the current operator security control - and `docs/FEATURES.md` carries no entry for the SM136 (notifications/XMPP), SM137 (SMTP validation) or SM140 (first-party analytics) features shipped in 0.6.2-0.6.9. Both are exactly the conditions the framework says refuse a Commercial-regime release; the effort to clear them is small (S-M), and the underlying cause - no doc-currency step in the release flow - is the same systemic failure the 2026-07-01 review named, recurring within eight days of being recorded.

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (verified with `git describe --tags`; working tree clean apart from this review directory). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 7 detail (five-audience taxonomy, expected file map, ADR structure, by-design refusal conditions). Seventeen releases (v0.5.36-v0.6.10) since the prior review. Work performed:

- Prior-finding verification: every 2026-07-01 D7 finding re-checked on disk (fixed / partial / open), with the fixing release identified from CHANGELOG.
- Whole-tree currency grep for `manager_groups` (SM138) across `docs/`, `starter/`, `installers/` and root files, each hit classified current-behaviour-stale vs correctly-historical.
- SM140 / SM137 / SM136 audience-doc currency checks against the shipped behaviour (`starter/docs/manager.md`, `ai-briefing-stats.md`, `forms-smtp.md`, `docs/FEATURES.md`, the generated `docs/reference/capability-map.md`).
- CHANGELOG completeness check against `git tag -l` for the full window, including the 0.6.6/0.6.7 field-fix round.
- Doc drift gates run: `t/lint/01-stale-paths.t`, `t/tools/25-host-deps.t`, `t/tools/26-capability-docs.t`, `t/tools/27-manpages.t` (all pass).
- Release-artefact inspection: `dist/lazysite-0.6.10.tar.gz` listed for man pages and shipped docs; `tools/release.sh` read for documentation steps.
- Suite state cited from the release-round run at `/srv/tmp/sm-test/rel610-suite.log` (162 files, 2504 tests, Result: PASS); heavy gates owned by other dimensions were not re-run.

## Findings

### F7.1 - Prior-findings ledger: eight of ten closed (PASS on the close-out)

```datatable
columns: 2026-07-01 finding | State at v0.6.10 | Evidence
widths: 4.5cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
F7.2/F7.5 SM095 currency rot (ten locations) | fixed | 0.5.37 sweep; FEATURES.md:398 (SM138-aware), starter/docs/configuration.md:75-78 and reference.md:72-75 mark the key "Retired", auth.md:269 and manager.md:43 describe the migration
F7.3 raw-log download still documented | fixed | starter/docs/manager.md:192-193 now states "the raw logs are not downloadable through the manager"; plugins/stats.pl header comment rewritten; ai-briefing-stats.md:22 consistent
F7.4 CHANGELOG keying | still PASS | see F7.6
F7.6 no ADRs | fixed | docs/adr/0001-0006, framework structure (Status/Date/Tags; Context/Decision/Rationale/Consequences), retrospective ones dated and marked; the five recommended ADRs all written (0002-0006) plus 0001 from the D1 finding
docs/SECURITY.md missing | fixed | STRIDE table over five trust boundaries + ASVS L1 status with named open items; cross-references architecture/security.md rather than duplicating it
docs/ACCESSIBILITY.md missing | fixed | WCAG 2.1 AA self-assessment of the manager UI + default theme, honest verified-vs-untested split, operator responsibilities
Man pages absent | partial | CLI POD + tools/gen-manpages.pl + t/tools/27-manpages.t exist (0.5.40), but release.sh never invokes the generator and the 0.6.10 tarball ships no man page (F7.7)
OPERATOR.md lacks channel guidance | fixed | OPERATOR.md:43-53: update_channel, install.pl --channel edge|stable, --force semantics, fleet loop
docs/MONITORS.md missing | open | no file; the nearest artefact is docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md
Taxonomy mapping in a project manifest | open | no project.yml or equivalent; USER.md's deferral to site-served docs and the SM-document SPECIFICATION set remain unrecorded
```

The close-out itself is strong work: the 0.5.36-0.5.40 releases converted most of the prior round's D7 backlog into shipped artefacts within two days of the review.

### F7.2 - SM138 currency: the second rot wave, security tier missed (REFUSE condition)

SM138 (0.6.5, breaking) retired the `manager_groups:` conf key entirely - manager access is groups-carried capabilities only, with an automatic migration that removes the key from `lazysite.conf`. The sweep that accompanied it updated `UPGRADE.md`, `docs/IMPLEMENTOR.md:51`, `docs/FEATURES.md:398` and the four `starter/docs/` pages - but not the security-tier documents, which still teach the retired key as the current control:

```datatable
columns: Location | Stale claim | Reality at v0.6.10
widths: 5cm | X | X
bold: 1
tone: medium
text: 2 * 3
---
SECURITY.md:62-65 (repo root, the security policy of record) | operator hardening step: "Set manager_groups: in lazysite.conf to restrict manager access ... Leaving it empty grants manager access to any authenticated user" | the key is retired; access is the ui capability on a group; the unsecured mode is keyed on "no group grants manager access" (CHANGELOG 0.6.5)
docs/architecture/security.md:139-148 | whole "Manager access" section: "manager_groups: in lazysite.conf names the groups whose members can access /manager/*"; set/empty semantics | same - the section describes a mechanism that no longer exists
docs/architecture/security.md:462 | "the operator (local, no manager_groups) is unrestricted" | the bypass is manage_users, not manager_groups absence
installers/hestia/INSTALL-RUNBOOK.md:214-225 (also :38, :106) | instructs appending "manager_groups: lazysite-admins" to lazysite.conf as a required first-run security gate | following it now triggers a one-off migration and the line is deleted; the documented mental model is wrong for the operator the runbook exists for
starter/manager/config.md:36-38 | comment: the old manager_groups list "remains a backend-only (lazysite.conf) fallback" | true until 0.6.4; retired at 0.6.5
docs/DEVELOPER.md:26 | "Capabilities are per-account settings read per request (webdav, manage_themes/layouts/config, create_sub_users, ui)" | pre-SM095 residue both sweeps missed: capabilities are groups-carried channel x action grants (ADR 0003)
```

The framework's by-design condition applies verbatim: "a stale reference (a doc mentions a symbol that no longer exists) refuses" for Commercial regimes. That the stale instruction sits in the two security documents and the install runbook - the exact documents an operator hardening a site reads - is the aggravating factor. The failure is the same one F7.5 named on 2026-07-01: the docs rot in lockstep because no doc-currency step runs in the release flow; SM095's wave was swept on 02 July and SM138 opened a new wave on 09 July.

### F7.3 - FEATURES.md has rotted again: 0.6.2-0.6.10 features absent (REFUSE condition)

The framework: "a release that ships a new feature without a corresponding entry in `docs/FEATURES.md` refuses for commercial ... regimes - the complete feature reference is part of the release, not an afterthought." At v0.6.10:

```datatable
columns: Shipped feature | Release | FEATURES.md state
widths: 5.5cm | 1.6cm | X
bold: 1
tone: medium
text: 3
---
Notifications capability + manager bell + notify-xmpp XMPP delivery (SM136) | 0.6.2 | absent; the capability table (Part on capabilities, around line 315) omits `notifications`, though the generated capability-map.md:44 carries it - the hand-maintained table has drifted from @CAP_KEYS
SMTP password field + staged connection validation (SM137) | 0.6.2-0.6.4 | absent
First-party analytics - self-recorded access log as the primary stats source (SM140) | 0.6.8-0.6.9 | absent; FEATURES.md:836 still describes the stats plugin as "an awstats/webalizer-style dashboard from the" server access log - the zero-setup first-party model, arguably the feature's whole point, is unmentioned
Version timeline | - | ends at 0.6.1 (FEATURES.md:765); five feature-bearing releases follow
```

The 0.6.2 release itself performed a FEATURES.md sweep "brought current with the 0.5.x-0.6.1 lines" (CHANGELOG 0.6.2) - but did not include the features 0.6.2 itself shipped, and nothing since has. TOOLCHAIN.md names lazysite's FEATURES.md as "the canonical worked example the team has in production"; the exemplar is now three features behind its own product.

### F7.4 - SM140/SM137 doc currency is good; SM136 has no prose documentation (WARN)

SM140 (first-party analytics)
: current and internally consistent. `starter/docs/manager.md:181-193` describes the dashboard as reading "lazysite's own first-party access log" with the server log as fallback and states raw logs are not downloadable; `ai-briefing-stats.md:19-22` matches (export built from the first-party log, tool never sees raw lines). The claim in CHANGELOG 0.6.9 that "docs updated (manager, AI briefing)" is verified true - for the site-served set. The repo-side gap is FEATURES.md (F7.3).

SM137 (SMTP validation + password)
: current. `starter/docs/forms-smtp.md:102-109` documents the Password field vs `password_file:` precedence; `:119-129` documents the staged Validate action with all four failure stages. Matches the shipped 0.6.4 button placement.

SM136 (notifications)
: no prose documentation anywhere. The `notifications` capability appears only in the generated `docs/reference/capability-map.md:44` and the plugin-registry descriptor; nothing in `starter/docs/` or `docs/` explains the manager bell, the capability's seeding on `user-managers`, or how to configure the **notify-xmpp** plugin (JID, password, recipient/room). An operator wanting XMPP delivery has CHANGELOG 0.6.2 as the only instruction.

### F7.5 - UPGRADE.md: the SM138 note is a model; the file lacks version keying (WARN, minor)

The SM138 section (UPGRADE.md:3-20) is exactly what a breaking-change note should be: what changed, that migration is automatic, that effective access is unchanged, what the unsecured mode is now keyed on, and the one command that secures a site. Two gaps:

- Recent sections are keyed by feature ("manager_groups retired (SM138)", "WebDAV publishing (SM070)") with no version numbers, then the file jumps to "0.2.x to 0.3.0". An operator upgrading 0.5.35 to 0.6.10 cannot tell from UPGRADE.md which sections apply to their hop.
- Two operator actions live only in CHANGELOG: the 0.5.39 strict api/mcp channel gating ("verify hand-provisioned token/connector accounts hold the channel cap") and the 0.6.6 ownership-repair remediation for sites upgraded through 0.6.5 (`lazysite-check --fix` as root).

### F7.6 - CHANGELOG discipline (PASS)

All seventeen tags v0.5.36-v0.6.10 present, newest first, dated, keyed by tag per the declared convention (CHANGELOG.md:10-17); Unreleased section empty at the tag, matching the clean tree. The field-fix round is recorded candidly: 0.6.6 names the 0.6.5 regression it repairs and the affected-site remediation; 0.6.7 names the field incident (marriage-morris manager outage) behind the TT-cache fix. Release commits carry per-release gate claims - commit `31ae86b` (0.6.9) records suite size, lint, bench, strict SBOM and an explicit coverage-by-identity argument - which is the contemporaneous-evidence shape Dimension 8 needs.

### F7.7 - Generated-docs drift gates hold; man pages are generated by nothing (WARN)

The generated documentation tier is immune to the rot that hits the hand-maintained tier: `t/tools/25-host-deps.t` and `26-capability-docs.t` (golden tests over `gen-host-deps.pl` / `gen-capability-docs.pl`) pass, and `docs/reference/capability-map.md` already carries the 0.6.2 `notifications` capability that hand-maintained FEATURES.md lacks - a live demonstration that the by-design pattern works where it is applied. `t/lint/01-stale-paths.t` passes but guards only the historical `themes/manager` rename; it is the natural home for a retired-terms list (F7.2's fix-forever).

Man pages: `t/tools/27-manpages.t` proves the POD is valid and `gen-manpages.pl` produces pages, but no caller exists - `tools/release.sh` has no man-page step, the repo has no `man/` directory, and the 0.6.10 tarball (554 entries listed) contains no `.1` page. CHANGELOG 0.5.40's claim that the tool "renders man pages at release" describes an intention, not the release flow. One line in release.sh (plus `--add-file` entries or a tarball-stage copy) closes it.

### F7.8 - ADR currency (WARN, minor)

ADRs 0001-0006 follow the framework structure and read well. One is now stale in a consequence: ADR 0003:24-25 records that "the old `manager_groups` config survives only as a backend fallback" - true when written (2026-07-02), superseded by SM138's clean retirement (0.6.5). The framework's ADR-audit expectation is that the set tracks the codebase; an amendment note on 0003 (or a short 0007 recording the SM138 clean cut and its automatic migration) restores currency. No new unrecorded architecturally-significant divergence was found in the 0.6.x line: first-party analytics and notifications both route through existing patterns (plugin registry, shared `Lazysite::Notify` write path).

### F7.9 - Audience coverage at v0.6.10 (summary)

```datatable
columns: Audience | Artefact | State
widths: 3cm | 5cm | X
bold: 1
tone: medium
text: 3
---
Evaluator | README.md | current (174 lines; refreshed 0.6.2)
User | docs/USER.md -> starter/docs/ | strong; site-served set current on the sampled topics; deferral still unrecorded in a manifest
Developer | docs/DEVELOPER.md + development.md + architecture/ | one stale capability sentence (DEVELOPER.md:26, F7.2); otherwise current incl. module inventory
Implementor | docs/IMPLEMENTOR.md | current (SM138-aware, host-deps reference); its pointer target INSTALL-RUNBOOK.md is stale (F7.2)
Operator | docs/OPERATOR.md | current; channels, backups, bad-URL blocker all present
Security | SECURITY.md + docs/SECURITY.md + architecture/security.md | threat model good; both narrative docs carry SM138 staleness (F7.2)
Accessibility | docs/ACCESSIBILITY.md | present, honest; no declared review cadence, unrevised since 0.5.40 while UI grew (wizard forms, validate button)
Cross-audience | docs/FEATURES.md | three shipped features behind (F7.3)
Operations register | docs/MONITORS.md | absent (F7.1)
```

## Verdict rationale

This round applies the framework's refusal conditions strictly, as charged. Two are met at the reviewed tag: a stale reference to a retired symbol presented as current behaviour (in the security documents and install runbook, F7.2), and shipped features without FEATURES.md entries (F7.3). The 2026-07-01 round graded a larger same-class defect set WARN; the strict reading, plus the fact that the systemic cause was named then and recurred within eight days on the very next breaking change, makes REFUSE the honest verdict. The corpus is otherwise in its best state to date, and recommendations 1-2 alone clear both refusal conditions before the planned 0.7.0 stable cut.

## Recommendations

1. SM138 security-tier currency sweep - rewrite `SECURITY.md:62-65` (grant `ui`/`manage_users` via a group; `lazysite-users.pl setup-manager`), the "Manager access" section of `docs/architecture/security.md` (:139-148, :462), `installers/hestia/INSTALL-RUNBOOK.md` (:38, :106, :214-225), the `starter/manager/config.md:36-38` comment, and `docs/DEVELOPER.md:26`. Effort: S. Gate: clears the stale-reference refusal condition.
2. Bring `docs/FEATURES.md` current - SM136 (notifications capability + bell + notify-xmpp), SM137 (SMTP password + validation), SM140 (first-party analytics as the primary stats source, rewriting :836), add `notifications` to the capability table, extend the version timeline past 0.6.1. Effort: M. Gate: clears the feature-reference refusal condition.
3. Make doc currency mechanical - extend `t/lint/01-stale-paths.t` (or a sibling) with a retired-terms list seeded with `manager_groups`-as-current-config, and add a doc-currency checklist step to the release flow so a breaking change cannot ship without its sweep. Effort: S-M. Gate: prevents the third wave; this is the systemic fix the 07-01 review asked for.
4. Wire `tools/gen-manpages.pl` into `tools/release.sh` and ship the pages in the tarball (git archive `--add-file`, as for sbom.json) - or amend the 0.5.40 claim. Effort: S. Gate: man-page requirement; claim-vs-artefact honesty.
5. Write user/operator documentation for SM136 - the bell, the `notifications` capability, and notify-xmpp configuration - in `starter/docs/` (manager.md section plus a short plugin page). Effort: S. Gate: audience coverage.
6. Add `docs/MONITORS.md`, promoting the pre-launch operational holds and the existing practice (lazysite-check doctor, stats error surface, audit review) into a register with cadence and last-run. Effort: S. Gate: taxonomy; feeds the D5 monitors story.
7. Version-key UPGRADE.md's recent sections and fold in the two CHANGELOG-only operator actions (0.5.39 channel caps; 0.6.6 ownership repair). Effort: S. Gate: upgrade-path usability.
8. Amend ADR 0003 (or add 0007) for the SM138 clean cut. Effort: S. Gate: ADR currency.
9. Record the taxonomy mapping (USER defers to site-served docs; SPECIFICATION is the SM document set) in a project manifest, and declare an ACCESSIBILITY review cadence there. Effort: S. Gate: taxonomy mapping the framework expects the manifest to record.
