# Dimension 7 - Documentation - lazysite eight-dimension review

---
title: "Dimension 7 - Documentation - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 2026-07-18, Commercial regime, 0.8.0-stable candidate"
brand: plain
---

## Verdict

WARN - both 2026-07-10 refusal conditions are cleared. The SM138 security-tier
rot is gone: root `SECURITY.md:64-73`, `docs/architecture/security.md:176` and
the Hestia `INSTALL-RUNBOOK.md` now teach group-carried `ui`/`manage_users`
access and present the retired `manager_groups` key as retired, and the
systemic fix the last two rounds asked for has landed - `t/lint/08-retired-terms.t`
makes the sweep unskippable (seeded with `manager_groups`, passing). And
`docs/FEATURES.md` has caught up: the version timeline runs to 0.7.2 and SM136
(notifications), SM137 (SMTP validation) and SM140 (first-party analytics) all
now carry entries (FEATURES.md:1069, :1074, :1081-1084). Neither by-design
refusal condition is met at this tree. What holds the dimension at WARN rather
than PASS is a *new* currency lag of exactly the same shape as the cleared one,
one release-generation later: `docs/FEATURES.md` stops at 0.7.2 (subtitle line
3, timeline ends FEATURES.md:1050) while this candidate is the 0.7.28 tree, so
the entire current cycle's headline work - SM179 multilingual (P1-P8), SM165
domain-owned access, SM175 content-history-follows-renames, the cache-correctness
run, engine i18n and the alias-entity retirement - has no entry in the canonical
feature reference. That is not (yet) a shipped-feature-without-an-entry refusal
because these are edge-line features not in a stable release; but promoting them
to the 0.8.0 stable **is** the event the framework's refusal condition names, so
the FEATURES.md sweep must land in the same cut. The site-served authoring tier
(`starter/docs/`) and the generated tier (capability-map) *are* current for the
new work; the repo-side cross-audience reference is the one that lags.

## Method

Assessed at tag `v0.7.28`, commit `6780878` (`git describe --tags` = v0.7.28;
working tree clean apart from this review directory). Framework:
`/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 7 detail (five-audience
taxonomy, expected file map, ADR structure, by-design refusal conditions).
Eighteen edge releases (v0.7.3-v0.7.28) since the reviewed 0.6.10 tag; the 0.7.0
first-stable cut and the 0.7.1/0.7.2 releases fall inside the gap the prior round
had not yet seen. Work performed:

- Prior-finding verification: each 2026-07-10 D7 refusal condition and WARN
  re-checked on disk against the fixing release identified from CHANGELOG.
- Whole-tree retired-terms grep (`manager_groups`, and the retired alias-entity
  concept) across `docs/`, `starter/`, `installers/`, `SECURITY.md`, `README.md`,
  each hit classified current-behaviour-stale vs correctly-historical vs
  feature-request-archive.
- New-cycle currency check: SM179 / SM165 / SM175 / cache / engine-i18n /
  alias-entity retirement against `docs/FEATURES.md`, `docs/OPERATOR.md`,
  `docs/IMPLEMENTOR.md`, `starter/docs/configuration.md`,
  `starter/docs/ai-briefing-configuration.md`, and the generated
  `docs/reference/capability-map.md`.
- CHANGELOG completeness spot-check against HEAD (0.7.28 entry present and
  dated; keying convention declared at CHANGELOG.md:8-17).
- Doc-drift gates run: `t/lint/08-retired-terms.t`,
  `t/lint/09-feature-request-status.t`, `t/tools/26-capability-docs.t`,
  `t/lint/11-web-assets-sbom.t` - all PASS.
- Suite state: full run `prove -lr t/` at this tree, 232 files / 4179 tests,
  Result: PASS (`/tmp/fullsuite.log`).

## Findings

### F7.1 - Prior D7 refusal conditions: both cleared (PASS on the close-out)

```datatable
columns: 2026-07-10 refusal condition | State at v0.7.28 | Evidence
widths: 4.5cm | 2cm | X
bold: 1
tone: medium
text: 3
---
F7.2 SM138 security-tier rot (stale retired symbol taught as current in the security docs + runbook) | cleared | SECURITY.md:64-73 teaches group-carried ui/manage_users + `lazysite-users.pl setup-manager`, manager_groups marked retired; architecture/security.md:170-178 describes "no group grants manager access" as the unsecured mode and notes the key "was retired in 0.6.5, SM138"; INSTALL-RUNBOOK.md carries no manager_groups instruction (grep clean), uses setup-manager (:96-98)
F7.3 FEATURES.md three features behind (SM136/137/140 + timeline stalled at 0.6.1) | cleared | timeline now runs to 0.7.2; SM136 at FEATURES.md:1081-1084, SM137 at :1084, SM140 at :1069; the stats section rewrite reached first-party framing
Systemic cause (no mechanical doc-currency step; rot recurred each breaking change) | fixed | `t/lint/08-retired-terms.t` fails the build if a retired term is taught as current outside the historical allowlist (CHANGELOG/UPGRADE/adr/review/feature-requests excluded); seeded `manager_groups => SM138`; passes
```

The close-out is thorough: the security tier, the exemplar feature reference and
the mechanical guard the last two rounds all asked for are in place, and the
guard demonstrably works (it is green with `manager_groups` seeded and every
current-behaviour doc reads it as retired).

### F7.4 - New: FEATURES.md lags the current cycle by ~26 releases (WARN, the near-refusal)

`docs/FEATURES.md` is stamped "as of v0.7.2" (line 3) and its Part XIII feature
timeline ends at **0.7.2** (2026-07-10, FEATURES.md:1050). This candidate is the
0.7.28 tree. The headline work of the whole cycle is therefore absent from the
canonical cross-audience reference:

```datatable
columns: Cycle feature | Release band | FEATURES.md state
widths: 5cm | 1.9cm | X
bold: 1
tone: medium
text: 3
---
SM179 multilingual language sets (P1-P8: keys, switcher, hreflang, content-root data, coverage, agent discovery, localised engine chrome) | 0.7.x edge | no timeline entry, no Part; `lang`/`lang_group` appear only as capability-map/config-doc facts
SM165 domain-owned access model | 0.7.x edge | no entry; `manage_domains` capability present in the generated map (capability-map.md:40) but no prose feature entry
SM175 content history follows renames | 0.7.x edge | Content-history Part (FEATURES.md:604) predates the SM175 rename-following behaviour; not called out
Cache-correctness run (per-host/lang cache keying, conf-edit invalidation) | 0.7.x edge | absent
Engine i18n (localised 404/403/auth chrome, escaped request URI) | 0.7.28 | absent
Alias entity retired in favour of clone | 0.7.x edge | not reflected (see F7.5)
```

This is not a met refusal condition at *this* tree: the framework's condition is
"a release that ships a new feature without a corresponding FEATURES.md entry",
and these are edge-channel features, not a stable release. But this is the
0.8.0-**stable** candidate, and the stable cut is precisely the release the
condition governs. The identical lag (timeline ~2 minor lines behind, headline
features unmentioned) is what earned the 2026-07-10 REFUSE; it has re-formed one
release-generation on, which confirms the mechanical guard (F7.1) covers *retired
terms* but not *missing-feature currency* - FEATURES.md completeness is still
hand-maintained and still drifts. Recommendation 1 clears it and must land in
the same cut as 0.8.0-stable.

### F7.5 - Alias-entity retirement: the mechanism docs are correct; the entity concept is only lightly swept (WARN, minor)

CHANGELOG (0.7.x, "Domains: the 'alias' concept is retired in favour of clone",
CHANGELOG.md:54-59) retired the separate *alias entity* and the "alias of X"
grouping in the Domains list - a cloned domain is now just an independent row -
while explicitly keeping the underlying multi-host `alias_hosts` /
`alias.<host>.<key>` mechanism unchanged. The distinction matters for the sweep:

- Correct and current: `starter/docs/configuration.md:162-196` "Domain aliases"
  documents the surviving `alias_hosts` / `alias.<host>.` mechanism; the
  multilingual example keys (`alias.fr.example.com.lang_group`,
  configuration.md:213-216; ai-briefing-configuration.md:241) use the same live
  mechanism. These are not stale.
- Lightly swept: `docs/FEATURES.md:521-522` still describes a read-only "Aliases
  card (alias -> target)" and the "alias of X" model in the Domains manager - the
  presentation the retirement removed. This is not a retired *symbol* (so the F7.1
  lint does not catch it, and it is not a refusal condition), but it is a doc that
  presents a retired UI concept as current. Fold it into the F7.4 FEATURES.md sweep.

The retired-terms lint (F7.1) is seeded only with `manager_groups`; the alias
entity is a second retirement this cycle that is not seeded. Adding it (as a
phrase, e.g. "alias of" as a Domains-list grouping) would extend the mechanical
guard to this cycle's retirement as well.

### F7.6 - Site-served (authoring) tier is current for the new work (PASS)

The multilingual work is well documented at the tier operators and agents
actually read:

- `starter/docs/configuration.md:200-216` "Multilingual language sets": a set is
  hosts sharing a `lang_group`, each a first-class domain with its own content
  root; the `lang`/`lang_group` keys are settable via conf, `domain-set` and CLI
  (:177, :191-192). Coherent with the shipped model.
- `starter/docs/ai-briefing-configuration.md:226-258` "Multilingual sites
  (language sets)": the AI-agent framing - the `lang_group` plane must exist
  before it can be populated, and the layout emits the switcher and `hreflang`
  automatically so agents must not hand-build them. This section (added this
  cycle) is internally consistent and matches the engine behaviour. Verified.

### F7.7 - Generated tier is in sync (PASS)

`t/tools/26-capability-docs.t` (golden test over the capability-map generator
against `lib/Lazysite/Capabilities.pm`) passes, so `docs/reference/capability-map.md`
tracks the code: it already carries the new-cycle `manage_domains` capability
(capability-map.md:40, with the domain-add/set/remove/preview/check actions and
the site-backup pair) and the content-history versioning actions on
`manage_content` (:35, `list_versions`/`view_version`/`restore_version`). The
by-design pattern continues to hold where it is applied; it is the
hand-maintained FEATURES.md (F7.4) that lags.

### F7.8 - Repo-side operator/implementor currency for new-cycle config (WARN, minor)

`docs/OPERATOR.md` and `docs/IMPLEMENTOR.md` are current for the packaging/FastCGI
operator surface (per-domain pools, `lazysite-hestia-domain`, restore-with-domain-rewrite,
OPERATOR.md:88-97/:157-161; IMPLEMENTOR.md:44-58) but neither references the
new domain-owned access delegation (SM165) or multilingual operation (SM179) at
the operator/implementor tier - those live only in the authoring tier
(`starter/docs/`) and the generated map. For an operator standing up a
language-set or delegating domain access, the repo-side operator docs point at
nothing. Effort to close is small; not a refusal condition.

### F7.9 - CHANGELOG discipline (PASS)

CHANGELOG.md is current through the 0.7.28 entry (dated 2026-07-18, CHANGELOG.md:19),
newest first, keyed per the declared convention (released versions by tag,
unreleased by SM number + ref, CHANGELOG.md:8-17). The current-cycle work is
recorded candidly - the alias retirement (CHANGELOG.md:54-59), the cache-correctness
invalidation change (:41), the SM179 P8 engine-chrome i18n with its reflected-markup
escape fix (0.7.28 entry) - which is the contemporaneous-evidence shape Dimension 8
needs, and (F7.4 notwithstanding) means the *release history* is current even where
the *feature reference* is not.

### F7.10 - Audience coverage at v0.7.28 (summary)

```datatable
columns: Audience | Artefact | State
widths: 3cm | 5cm | X
bold: 1
tone: medium
text: 3
---
User | docs/USER.md -> starter/docs/ | current, incl. new multilingual authoring (F7.6)
Developer | docs/DEVELOPER.md + architecture/ | current; SM138 residue cleared (security.md:176)
Implementor | docs/IMPLEMENTOR.md | current for packaging; no SM165/SM179 pointer (F7.8, minor)
Operator | docs/OPERATOR.md | current for pools/restore; no domain-access/multilingual section (F7.8, minor)
Security | SECURITY.md + docs/SECURITY.md + architecture/security.md | SM138 rot cleared (F7.1); threat model intact
AI agent | starter/docs/ai-briefing-*.md | current incl. new multilingual briefing (F7.6)
Cross-audience | docs/FEATURES.md | ~26 releases behind for the current cycle (F7.4) - the one lagging artefact
Generated | docs/reference/capability-map.md | in sync with Capabilities.pm (F7.7)
```

## Verdict rationale

The two by-design refusal conditions that made 2026-07-10 a REFUSE are both
cleared on disk, and the systemic guard the last two rounds demanded is now
mechanical and green. That closes the charge. The dimension does not reach PASS
because the *same failure mode* - hand-maintained FEATURES.md drifting behind
the shipped line - has re-formed one release-generation on (F7.4): the canonical
feature reference stops at 0.7.2 while this is the 0.7.28 tree, so the whole
cycle's headline work is unrecorded there. At an edge tree that is a WARN, not a
refusal, because the condition is scoped to shipped (stable) releases; but this
*is* the 0.8.0-stable candidate, and promoting the cut with FEATURES.md at 0.7.2
would convert the WARN into the very refusal condition just cleared. Recommendation
1 is therefore not optional polish - it is a gate on the stable cut.

## Recommendations

1. Bring `docs/FEATURES.md` current to 0.7.28 before the 0.8.0-stable cut - add
   the SM179 multilingual Part (language sets, `lang`/`lang_group`, switcher,
   `hreflang`, per-language content roots, localised engine chrome), SM165
   domain-owned access, SM175 rename-following content history, the
   cache-correctness behaviour, and extend the Part XIII timeline past 0.7.2;
   update the subtitle stamp. Effort: M. Gate: prevents the cleared refusal
   condition re-forming at the stable cut. **Blocks 0.8.0-stable.**
2. Sweep the alias-entity retirement out of `docs/FEATURES.md:521-522` (the
   read-only Aliases card / "alias of X" model) and seed the alias-entity phrase
   into `t/lint/08-retired-terms.t` so this cycle's second retirement is guarded
   the way `manager_groups` is. Effort: S. Gate: retired-concept currency +
   extends the mechanical guard.
3. Add a domain-access (SM165) and multilingual (SM179) operator/implementor
   section to `docs/OPERATOR.md` / `docs/IMPLEMENTOR.md` (or a cross-reference to
   the authoring-tier docs), so the repo-side operator tier is not silent on the
   cycle's config surface. Effort: S. Gate: audience coverage.
4. Extend the doc-currency guard beyond retired-terms to a *missing-feature*
   check - a release-flow step (or lint) that fails a stable cut if the newest
   FEATURES.md timeline version trails `VERSION`. This is the mechanical fix for
   F7.4's recurring class, the same way `08-retired-terms.t` fixed F7.1's. Effort:
   S-M. Gate: makes the systemic fix cover both drift modes.
