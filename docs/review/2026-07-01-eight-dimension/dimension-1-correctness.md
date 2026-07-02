---
title: "Dimension 1 - Correctness and groundedness - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

WARN - all 36 production Perl files compile cleanly and three sampled feature areas are grounded in their documented claims, but the SM095 capability check exists as four separate implementations against a spec that promises "one implementation, one source of truth", and no ADR records the divergence; the framework treats an unrecorded parallel path as a `divergent-implementation` finding, and there is no automated compile gate in the test suite.

## Method

Assessed at tag `v0.5.35`, commit `de12238` (clean working tree, tag verified with `git describe --tags`). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 1 detail (failure-mode catalogue and the three divergent-implementation review questions). Commands run:

- `perl -Ilib -c` over every `*.pl` at the repo root, `tools/*.pl`, `plugins/*.pl` and every `lib/Lazysite/**/*.pm` (36 files, scripted sweep).
- `grep` sweeps of `t/`, `Makefile` and `tools/release.sh` for any compile gate.
- Groundedness sampling of three recently changed areas against CHANGELOG/spec: the SM095 capability resolver, the SM133 static-HTML fallback (0.5.26) and the stats error classifier (0.5.29), plus the 0.5.35 provenance stamp.
- `perl <plugin> --describe` run against all six `plugins/*.pl` with the output JSON-decoded and key-compared (plugin interface uniformity question).
- Three test files read in full for the invalid-test check: `t/unit/plugins/01-stats-classify.t`, `t/integration/01-page-render.t`, `t/unit/manager/12-layout-activate.t`.

## Findings

### F1.1 - Compile sweep clean (PASS)

`perl -Ilib -c` over all 36 production files: `checked: 36  failures: 0`. No `hallucinated-symbol` or `hallucinated-package` at the mechanical level.

### F1.2 - No compile gate in the suite (WARN)

The framework names `perl -c` as the mechanical by-design prevention for this dimension ("`perl -c` failure ... refuses the build"). `t/lint/` carries stale-paths, perlcritic and secrets gates but nothing runs `perl -c`; neither does `Makefile` nor `tools/release.sh` (grep sweeps found no hit - the two test-file matches for "compile" are the Template Toolkit layout-compile gate in `t/unit/manager/12-layout-activate.t`, unrelated). A hallucinated import in a rarely exercised script would today be caught only by whichever test happens to load it. Classification: WARN - the check passes when run by hand, but the regime expects it to be unskippable.

### F1.3 - Four implementations of the group-capability read (WARN, divergent-implementation)

`docs/feature-requests/SM095-group-based-capabilities.md` states: "`Lazysite::Auth::Settings::caps_for($user)` ... Every surface consults it ... One implementation, one source of truth", and `lib/Lazysite/Auth/Settings.pm:91-96` repeats the claim ("every surface ... consults this and only this"). In fact `groups-settings.json` has four capability readers:

```datatable
columns: Site | Sub | Notes
widths: 5.5cm | X | X
bold: 1
tone: medium
text: 3
---
lib/Lazysite/Auth/Settings.pm:97 | caps_for | Canonical; membership resolved from the groups file; file read with a :utf8 layer
lazysite-processor.pl:444 | _groups_grant_cap | Copy; groups from the auth subrequest string; raw byte read
lazysite-auth.pl:929 | _login_groups_grant_cap | Copy; groups from the login session; raw byte read
lib/Lazysite/Auth/Acl.pm:98 | _groups_grant_cap | Copy; groups from X-Remote-Groups; raw byte read; lives in the SAME lib tree as the canonical resolver
```

Applying the framework's three review questions: (1) a shared helper exists (`caps_for` / `read_group_settings`) and three sites reinvent adjacent to it; (2) the copies differ materially from the canonical path - they take group membership from request context rather than the groups file, and they read the JSON as raw bytes where `Settings.pm` layers `:utf8` before `JSON::PP::decode_json` (which expects octets), so non-ASCII group names would behave differently on the two paths - an `unstated-assumption` (ASCII-only group names) hiding inside the divergence; (3) no ADR or design note records the parallel paths. The processor copy has a defensible reason (the processor is deliberately module-free on the render path, per `docs/FEATURES.md:51`), but that reason is not recorded against this duplication, and it cannot cover `lazysite-auth.pl` (which already imports three `Lazysite::*` modules) or `Acl.pm` (same lib tree as the canonical resolver). Per the framework, "unrecorded parallel paths are treated by the signoff as `divergent-implementation` findings". Classification: WARN - each site is individually correct today and the copies are textually in sync; the finding is the undocumented divergence, which under the Commercial regime must be either routed through the shared implementation or recorded in an ADR before the next signoff.

### F1.4 - Architecture docs contradict the code (WARN, spec-drift in documentation of record)

`docs/DEVELOPER.md:9` ("self-contained Perl CGI scripts - no shared modules") and `docs/architecture/code-quality.md` ("**No shared modules** between scripts") describe a policy the code left behind: `lib/Lazysite/` holds 15 shared modules and four of the six CGIs import them (e.g. `lazysite-manager-api.pl:26-50`). `docs/FEATURES.md:51` carries the accurate, narrower claim (only the processor's render path is module-free). A reviewer or agent grounding decisions in DEVELOPER.md would reproduce the retired architecture. Classification: WARN - shared with the Dimension 7 assessor; raised here because groundedness includes the code matching its own documentation of record.

### F1.5 - Groundedness samples match their claims (PASS)

SM133 static-HTML fallback (0.5.26)
: `lazysite-processor.pl:1048-1064` implements exactly the CHANGELOG claim - fallback only when no `.md`/`.url` source exists, verbatim serve, docroot realpath containment, and the `.md`-wins ordering; the Hestia vhost half exists at `installers/hestia/lazysite-app.stpl:58-59` (`.shtml` preferred so Apache expands SSI). Pinned end-to-end by `t/integration/01-page-render.t:69-89`.

Stats error classifier (0.5.29)
: `plugins/stats.pl:249-257` (`_classify_error`) reduces each error line to an AH-code/module bucket; the export block (`plugins/stats.pl:378-398`) emits categories and counts only - no raw lines, IPs or paths - and grep confirms `stats-log` and `offer_log_download` are gone from the codebase, matching the CHANGELOG's removal claim.

Provenance stamp (0.5.35)
: all `starter/*.md` seed pages carry `provenance: lazysite-starter`; `tools/lazysite-check.pl:339-397` implements the three-way classification the CHANGELOG describes; pinned by `t/tools/04-check.t`.

### F1.6 - Plugin --describe contract: one deviating plugin (WARN, interface uniformity)

Five of six plugins answer `--describe` with JSON sharing the core key set (`id`, `name`, `description`, `version`, `config_file`, `config_schema`, `actions`). `plugins/payment-demo.pl` does not implement `--describe` at all - invoked that way it dies (`DOCUMENT_ROOT not set`, rc 255) after printing a compile-time warning ("Statement unlikely to be reached at ... line 109"). The deviation is acknowledged only in a code comment (`lib/Lazysite/Manager/Plugins.pm:81` - "payment-demo has no --describe support so it's not listed here"), yet the discovery loop still globs it as a candidate; under a real CGI environment (DOCUMENT_ROOT set) the `--describe` probe falls through to `handle_request()` and `exec`s the full page processor, burning a render (bounded by the 2 s alarm) on every plugin-list call before the non-JSON output is dropped. Classification: WARN - a code comment is not the ADR-level record the framework requires for a deliberate interface deviation, and the fallthrough has a measurable cost.

### F1.7 - Dead capability reader from the pre-clean-cut model (WARN, low)

`lazysite-manager-api.pl:1201` (`_user_analytics`) is defined and never called anywhere in the repo (repo-wide grep; superseded by the `%need` token gate at line 304 and the audit split). It encodes the retired per-user `$s->{analytics}` read that SM095's clean cut removed. Its live sibling `_user_audit` (line 1209, used at line 436) is grounded - `settings-get` resolves through `effective_settings` which calls `caps_for` (`tools/lazysite-users.pl:704-709`). Classification: WARN - dead code carrying retired semantics is exactly the residue that misleads a future change; trivially removable.

### F1.8 - Invalid-test sample: none found (PASS)

All three sampled tests pin real behaviour against real processes: `01-stats-classify.t` feeds a 15-line fixture access log through the actual plugin and asserts exact per-class hit/visitor counts plus the privacy property (log path absent from the export); `01-page-render.t` runs the real processor CGI and asserts both the fallback serve and the `.md`-wins flip with file mtimes; `12-layout-activate.t` drives the real manager API over `open3` with a real token and asserts refusals, on-disk `lazysite.conf` state and the cache-clear sparing author partials. No tautologies, no mock-only assertions.

## Recommendations

1. Add a compile gate `t/lint/04-compile.t` that runs `perl -Ilib -c` over the same glob set as `t/lint/02-perlcritic.t` and fails on any non-zero exit. Effort S. Satisfies the framework's mechanical by-design prevention for Dimension 1 (F1.2).
2. Resolve the four-way capability read (F1.3): route `lazysite-auth.pl` and `Acl.pm` through `Lazysite::Auth::Settings` (they already sit on, or import from, the lib tree), and record the processor's self-contained copy in a short ADR (`docs/architecture/` decision note) referencing the module-free render-path rule - or, if all three copies stay, record that instead. While there, settle the octets-versus-`:utf8` JSON read one way across all readers. Effort M. Clears the standing `divergent-implementation` finding the Commercial signoff would otherwise refuse on.
3. Correct `docs/DEVELOPER.md` and `docs/architecture/code-quality.md` to the actual architecture (15 shared modules; only the processor render path is self-contained). Effort S. Restores groundedness of the documentation of record (F1.4) and feeds Dimension 7.
4. Give `plugins/payment-demo.pl` a minimal `--describe` handler (id/name/description/version, `demo: true`) before the DOCUMENT_ROOT die, or exclude it from the discovery glob explicitly; either way record the decision. Effort S. Closes the interface-uniformity deviation and stops the wasted processor exec on plugin-list (F1.6).
5. Delete `_user_analytics` from `lazysite-manager-api.pl`. Effort S. Removes retired-semantics dead code (F1.7).
