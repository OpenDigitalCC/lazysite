---
title: "Eight-dimension review - resolution"
subtitle: "0.8.0-stable candidate, 2026-07-18 - findings actioned before the cut"
brand: plain
standard-margins: true
---

## Purpose

The 2026-07-18 review is the gate for 0.8.0 stable. This records what was fixed
in response, so the cut proceeds only once every refusal condition is cleared.

## D6 Security - the refusal, cleared

F6.10 (serious) - stored XSS / response-header injection via front-matter `lang:`
: A page's front-matter `lang:` flowed UNESCAPED into `<html lang="[% page_lang %]">`
  and the `Content-Language` header; a content-only partner (`manage_content`)
  could inject a live `<script>` into every visitor's page or a header line via
  CR/LF. Fixed in `lazysite-processor.pl` - `page_lang`/`site_lang` are sanitised
  at the render point to a bare tag (`s/[^A-Za-z-]//g`). Regression:
  `t/integration/26-lang-injection.t` (script attempt neutralised, CR/LF cannot
  add a header, a valid `pt-BR` tag preserved). Commit `21bcdbb`.

F6.11 (WARN) - `domain-add` CRLF gap
: `domain_add` wrote override values without the CR/LF guard `domain_set` has;
  a `manage_domains` value could smuggle a second conf directive. Fixed - a CR/LF
  in any value is now rejected; regression in `t/unit/manager/33-domains-api.t`.

F6.2 - significant-change register stale
: The register in `docs/SECURITY.md` had no entry for SM165/SM175/SM179. Written -
  three dated assessments (domain access model, rename-following history,
  multilingual + engine i18n), each verdict *accepted*; SM179's is explicitly
  contingent on the F6.10 fix shipped here.

## D3 - test-isolation false failure

`perl t/run-all.t` failed three files that pass under `prove` because the
aggregate runner invoked children without `-Ilib` (the certifying `prove -l`
adds the repo `lib/`). Not a product regression. Fixed - `t/run-all.t` now runs
children with `-Ilib`, so the aggregate mirrors the gate.

## D7 / D8 - documentation and policy stable-gate items

FEATURES.md currency (D7)
: The version-history timeline stopped at 0.7.2; promoting to stable would
  re-form the exact D7 refusal cleared at 0.7.0. Swept to 0.7.28 (SM179, SM165,
  SM175, cache correctness, engine i18n, alias-entity retirement).

DoC 0.8.0 stamp (D8)
: `docs/DECLARATION-OF-CONFORMITY.md` release-identity finalised to 0.8.0 (the
  support-period anchor stays at the first stable, 0.7.0). The physical
  signature and place/date remain the responsible person's action at the cut -
  the one item still open by design.

## Deferred (WARN-level, not stable-gating)

- ADR 0001 "one recorded copy" vs two marked processor copies; a couple of stale
  counts in `architecture/*.md` and orphaned-sub/legacy comments (D1/D2, S).
- `docs/MONITORS.md` and a capacity test absent; a 0.7.28 restore rehearsal not
  yet recorded (D5, not Commercial refusal conditions).
- `lang_status`'s content walk unbenchmarked; retain a release-suite log before
  the cut (D3/D4).

These are tracked and do not block the 0.8.0 signoff.
