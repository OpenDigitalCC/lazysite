---
id: SM944
title: "SM944: Split the processor and the manager API into modules by area"
subtitle: "lazysite-processor.pl is 10,378 lines and lazysite-manager-api.pl 5,247; reading any part costs navigating the whole."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: processor
status-note: "Planned 2026-10-08: S1-S34, one area per branch. Built: S1 (n278) front-matter parser, required by path (ADR 0001); S2 (n280) the 27 variables parts read are `our`; S3-S11 (n281-n292) oEmbed, URL remapper, components, content-type cache, payment and preview gates, access log, front door, include and Markdown, forms. Next: S12, output and headers."
---

# Measured

The two largest files are where most fixes land, and every read of either is expensive: 10,378 and 5,247 lines, 38% and 36% comments. `Handlers.pm` and `Manager/*` show the pattern already works - logic in modules, the CGI a thin dispatcher.

# Proposal

Move each area (render pipeline, includes, feeds, cache, auth gate; and the remaining inline manager actions) into its own module with a short index header. One area per branch, behaviour-preserving, each landing with the suite unchanged.

# Done when

Neither script holds logic an area module could; each module starts with an index of what it holds. No behaviour change, proven by the existing suite at every step.

# Why the render path is module-free (ADR 0001)

ADR 0001 records the property; it does not invent it. The reasons are in the documents it points at:

No `@INC` dependency
: `docs/DEVELOPER.md` and `docs/architecture/code-quality.md`: the page-serving hot path runs with no `@INC` dependency. The manifest installs the scripts to `{CGIBIN}` and the module tree to `{DOCROOT}/../lib`, two places whose distance the manifest does not fix; every other CGI finds the tree by searching `$bin/lib`, `$bin/../lib`, `$bin/../../lib`. `classification.json` says it outright: "The processor does not depend on it."

No module load on the hot path
: The processor's own comments (`fetch_url`, `_cannot_read`): a Lazysite module load on the cache-hit path costs every request for a few lines of code, so cold paths load modules lazily through `_lazy_lib` and decisions the render path shares are carried as marked copies, each pinned by a lint.

So a split must keep both: the parts cannot live in the `lib/` tree, and loading them must cost what compiling the same lines inside the script costs.

# The structure chosen

- Each processor area is a **part**: a file under `lazysite-processor/` beside the script, `package main`, with an index header. It is not a module and loads nothing.
- The script requires its parts in one `BEGIN` block, **by absolute path** from its own resolved location (`realpath(__FILE__)`), never through `@INC`. A part that is missing fails the compile loudly.
- A part travels with the script: one manifest rule installs `lazysite-processor/*.pm` to `{CGIBIN}/lazysite-processor/`, the deb payload carries the directory beside the script, and the `.pm` extension installs it 0644 so a web server will not execute it as a CGI.
- Because a part is `package main`, a move is a pure move: callers, tests calling `main::name`, and the subs a part calls back into are unchanged. What a part cannot see is a file-scope `my` variable of the script, which is why S2 below comes before every area that reads one.
- The manager API keeps its dispatch chain (SM943); its handlers move into `lib/Lazysite/Manager/*.pm`, which the CGI already loads.

# Plan

Measured on n277 with `tmp/sm944-map.pl` (sections by the scripts' own `# --- ` headers, calls by sub name, file-scope variables by declaration). Lines include each area's comments. The processor is 10,700 lines (4,146 comment lines), the manager API 5,026.

The processor's order is by risk: S1 proves the mechanism on code that reads no shared state; S2 is the one prerequisite every later area needs; then the areas grow in size and in how much of the request they touch. The manager API rows (S21 onwards) are an independent track and may interleave with the processor's.

```datatable
columns: Ref | Area (target) | Holds | Lines | Calls out to | Called from | Risk
widths: 1cm | 3.5cm | X | 1.2cm | 3cm | 3cm | 2.5cm
bold: 1
tone: medium
---
S1 | front-matter parser (`lazysite-processor/front-matter.pm`) | `parse_yaml_front_matter` and the nested-YAML parser for `sections:` (`_parse_sections`, `_yaml_block`, `_yaml_value`, `_yaml_scalar`, `_yaml_split_flow`, `_yaml_quoted_scalar_line`); 7 subs | 273 | `strip_tt_directives` (oEmbed) | `process_md`, the include path, the registry scan | LOW: pure functions, no shared state; proves the mechanism
S2 | the shared state, `my` to `our` (script) | the file-scope variables the areas share: `$DOCROOT`, `$LAZYSITE_DIR`, `$CONF_FILE`, `$REQUEST_CROOT`, `%ACCESS_REC`, `%AUTH_CONTEXT`, `%PAYMENT_CONTEXT`, `%PREVIEW_CONTEXT`, the cache-dir paths and the rest each later row names | ~40 declarations | - | every later processor row | MEDIUM: one word per line, but every request reads them; `reset_request_state` must still reset each
S3 | oEmbed (`oembed.pm`) | `convert_oembed`, `fetch_oembed`, `find_oembed_endpoint`, `_oembed_providers`; and `uri_encode`, `strip_tt_directives`, which are general text helpers filed here | 120 | `fetch_url`, `log_event` | the render pipeline, front matter, auth, main | LOW
S4 | URL remapper (`remap.pm`) | `_remap_parse`, `_remap_redirect`, `_alias_lookup` (the marked copy of Lazysite::Remap, t/lint/129) | 127 | `_request_host`, `_security_headers`, `_esc_html`, `log_event` | main | LOW; lint 129 reads the copy by path
S5 | content components (`components.pm`) | `convert_fenced_components`, `_render_component`, `_component_exists`, `_md_fragment` | 155 | include filters, `convert_md`, `convert_fenced_divs` | `process_md` | LOW
S6 | content-type cache (`ct-cache.pm`) | `ct_cache_path`, `read_ct`, `write_ct`, `write_html` | 119 | `_path_under`, `_cache_umask` | main, `process_md` | LOW-MEDIUM: on the cache-hit path
S7 | request gates: payment and preview (`gates.pm`) | `peek_payment`, `check_payment`, `serve_402`; the preview cookie (`check_preview`, `read_request_cookie`, `load_preview_secret`, `preview_const_eq`) | 190 | output, `process_md`, `_system_page_md` | main | MEDIUM: security gates; their tests run the CGI
S8 | access log and unit registry (`access-log.pm`) | `_access_record` and its helpers, `_unit_enabled` and the SM222 registry read | 229 | request address, `_cannot_read`, `_json_str` | main, `resolve_db` | LOW-MEDIUM: every request records
S9 | front door relay (`front-door.pm`) | `_front_door`, `_front_route` (the marked copy of Lazysite::FrontDoor, t/lint/42), `_front_relay` and helpers | 366 | `_conf_value`, `_security_headers`, `_lazysite_dir_for` | main | MEDIUM: the pool's routing; lint 42 reads by path
S10 | include and Markdown (`include.pm`) | `convert_fenced_include`, `_resolve_include`, `convert_md`, `convert_fenced_code`, the `markdown`/`json`/`url_safe` filters, link rewriting | 465 | ACL copies, `fetch_url`, `_tt_dep`, `convert_oembed` | `process_md`, components, layout, scan | MEDIUM: SM964-SM970 security fixes live here; lints 212/213 read by path
S11 | forms (`forms.pm`) | `convert_fenced_form`, `_render_form` (562 lines on its own), `_write_form_rules`, `load_form_secret`, `convert_fenced_divs` and the step CSS/script; filed today under the SM071 preview header | 826 | `convert_md`, `_tt_inert`, `_esc_html` | `process_md`, output (`load_form_secret`) | MEDIUM: one 562-line sub; splitting it is a later, separate change
S12 | output and headers (`output.pm`) | `output_page`, `not_found`, `forbidden`, `_security_headers`, `_content_security_policy` (the copy pinned by t/lint/55), `_conf_value` and the conf readers | 567 | `process_md`, `_chrome`, `load_form_secret` | almost every area | MEDIUM-HIGH: every response; lints 55/56 read by path
S13 | request address and host (`request.pm`) | `_request_host`, `_request_address`, the trusted-proxy parser and address-set helpers (lints 203, 205, 206) | 150 | - | remap, scan, access log, main | MEDIUM: an identity fact; three one-definition lints
S14 | sources and site vars (`sources.pm`) | `resolve_tt_vars`, `resolve_json`, `resolve_db` (233), the dependency record (`write_deps`, `deps_fresh`), `parse_nav`, the env allowlist copy (lint 202) | 950 | ACL copies, `fetch_url`, `_lazy_lib`, `resolve_scan` | main, scan | MEDIUM
S15 | scan and registries (`registries.pm`) | `resolve_scan`, `scan_pages`, `_serve_registry`, `_regenerate_registries_once`, the registry cache | 990 | front matter, sources, auth copies | main, sources | MEDIUM
S16 | the template render (`render.pm`) | `render_content` (435), `_tt_render`, `_tt_render_impl`, `_cache_umask` | 480 | layout, sources, filters | `process_md`, layout | HIGH: the TT boundary every page crosses
S17 | layout, theme and injection (`layout.pm`) | `render_template`, `get_layout_path`, `resolve_theme`, `generate_theme_css` (lint 61), the admin bar, `_engine_mtime`, `_lazysite_version` | 1,102 | render, filters, auth | main, `process_md`, scan, forms | HIGH
S18 | the page pipeline (`pipeline.pm`) | `process_md`, `process_url`, `sanitise_uri`, `confine_content_root`, `_serve_content_static` (lint 127), the escapers, `_lazy_lib`, the freshness checks | 936 | nearly every area | main, gates, output | HIGH: the render path itself
S19 | ACL, group and domain copies (`acl.pm`) | `_acl_allows_read` and the ACL family (lint 31), `_groups_grant_cap` (ADR 0001's marked copy), group closure, domain access (lint 125 family) | 640 | `log_event` | auth gate, include, sources, scan | HIGH: security; several marked-copy lints read by path
S20 | auth gate (`auth.pm`) | `peek_auth`, `check_auth`, `_is_manager`, `_site_grants_manager`, `_serve_manager_forbidden`, `serve_403` | 466 | ACL copies, output | main, scan, sources | HIGH: security; last because it is read by most of the others
S21 | manager request context (`Lazysite::Manager::Common`) | the identity and request facts the handlers read as script lexicals - `$auth_user`, `$token_auth`, `%token_caps`, `@REQUEST_SCOPES`, `$IS_OPERATOR`, `$action`, `$path`, `$body` - set once after the auth check, read by the area modules | ~60 | - | every later manager row | MEDIUM: identity facts; a prerequisite like S2
S22 | remap actions (new `Manager/Remap.pm`) | `_remap_list`, `_remap_save`, `_remap_unit_off`, `_remap_scopes`, `_remap_host_in_scope` | 78 | context | dispatch | LOW: proves the manager track
S23 | notices and start page (`Manager/Notices.pm`, `Manager/StartPage.pm`, both existing) | `action_notices`, `action_notices_seen`, `_notices_gate`; `action_start_page`, `action_start_page_set`, `_start_page_subject` | 72 | context | dispatch | LOW
S24 | preview minting (new `Manager/Preview.pm`; Themes.pm is already 2,300 lines) | `action_preview`, `action_preview_grant`, `action_preview_clear`, `_preview_secret` | 147 | `_emit_json` | dispatch | LOW-MEDIUM: mints a signed cookie
S25 | describe and capabilities (new `Manager/Describe.pm`) | `site_capabilities`, `action_describe_capabilities`, `action_actions_list`, `_action_effects`, `_json_bool` | 89 | `%ACTION` (SM943) | dispatch, MCP twins | LOW
S26 | services, version and stats (new `Manager/Services.pm`) | `action_version`, `_service_state`, `action_channel_services`, `action_analyse_visitors`, `_stats_tool_path` | 133 | the stats tool | dispatch | LOW
S27 | domains (`Manager/Domains.pm`, existing; already 1,610) | `action_domain_check`, `action_domains_list`, `_instance_id` | 97 | Domains | dispatch | LOW
S28 | site backup and export (new `Manager/SiteBackup.pm`, the HTTP face over SitePackage and Backups) | `action_site_backup_*` (6), `action_site_export_primary`, `_site_package_path`, `_package_name_refusal`, `_package_*_refusal`, `_root_outside_grant` | 420 | SitePackage, Backups | dispatch | MEDIUM: streams files; grant checks
S29 | page PDF (new `Manager/PagePdf.pm`) | `action_page_pdf` | 84 | the pandoc plugin, the ACL check | dispatch | LOW-MEDIUM
S30 | configuration and language (new `Manager/Config.pm`) | `action_config_read`, `action_config_set` (174), `action_lang_status`, `_language_context`, `_conf_text` | 270 | the conf writer (lint 25) | dispatch | MEDIUM: lint 25 pins one conf writer
S31 | audit trail views (new `Manager/AuditTrail.pm`; `Lazysite::Audit` stays the writer) | `action_audit`, `action_recent_changes`, `_audit_cached_entries`, `_audit_trail_state`, `_audit_implicit_target`, `_audit_plugin_target`, the N13-04 switch | 530 | Audit, context | dispatch | MEDIUM: t/unit/lib/16 classifies audit writes by file
S32 | users and identity (new `Manager/Users.pm`) | `action_whoami` (119), `action_users` (167), `action_principals`, `action_display_names`, `action_rotate_auth_secret`, `users_api`, the users-tool runners, `_user_caps`, `_operator`, `_handler_who` | 500 | the users CLI | dispatch, audit | MEDIUM-HIGH: credentials; t/unit/lib/18 classifies write paths by file
S33 | the inline dispatch branches (into the area modules above) | the logic written inside the `if/elsif` chain (acl-set alone is ~150 lines); the chain stays, each branch becomes one call | ~1,300 | per branch | - | MEDIUM: done per area, after that area's module exists
S34 | CSRF gate (new `Manager/Csrf.pm`) | the M-1 write-action gate, top-level code today | 464 | context | the pipeline before dispatch | HIGH: security; the trust gate and auth check stay in the CGI
```

What stays in `lazysite-processor.pl` at the end: the preamble and configuration (~370 lines), the request entry (`handle_one_request`, `try_serve_cache`, `apply_trust_gate`, `main`, ~1,140) and the utilities every part calls (`log_event`, `read_file`, ~80). `main` is 733 lines on its own; splitting a sub is not a move and is not part of this item.

What stays in `lazysite-manager-api.pl`: the trust gate, the auth check, request parsing, the dispatch chain and the response.

Every row is a pure move in its own branch: the moved block appears in `git diff --color-moved`; anything adapted (a declaration, an import, a re-laid line) is a separate commit after it; tests that read the moved code by path, and the lints that list files, follow it in the same branch.

# Built

S1 (n278)
: the front-matter parser moved to `lazysite-processor/front-matter.pm`; the loader, the manifest rule, the deb payload, the lint scopes and lint 215 (the parts stay module-free and loaded by path) landed with it.

S2 (n280)
: the 27 file-scope variables a planned part reads are `our` in the script, set where they were; 15 stay `my` (read only by the script, or moving into one part with their only reader). Lint 215 rule 5: a part names no script `my`, keeps strict on, and its file-scope code reads no script variable.

S3 (n281)
: the oEmbed section (6 subs, 119 lines) moved to `lazysite-processor/oembed.pm`; lints 21, 25, 43 and 121, which state properties of the whole processor, read its parts.

S4 (n282)
: the URL remapper section (3 subs, 126 lines) moved to `lazysite-processor/remap.pm`, reaching `$LAZYSITE_DIR` and `%ACCESS_REC` through a bare `our` alias.

S5 (n283)
: the content components section (4 subs, 154 lines) moved to `lazysite-processor/components.pm`; lints 212 and 213 read the parts. Measured S2-S5 interleaved (n279-n283, 6 rounds): render_cache_hit_ms 73.5 to 74.2, render_miss_ms 97.5 to 97.3, each inside its tree's 2-4% spread.

S6 (n286)
: the content type cache section (4 subs, 118 lines) moved to `lazysite-processor/ct-cache.pm`, reaching `$CT_CACHE_DIR` and `$DOCROOT` through a bare `our` alias; it has no file-scope state. The move and the loader are separate commits.

S7 (n287)
: the payment subs and the SM071 preview-cookie section (7 subs, 127 + 71 lines, two blocks) moved to `lazysite-processor/gates.pm`. `%PAYMENT_CONTEXT` and `%PREVIEW_CONTEXT` stay declared in the script, where main() sets them and render_content() reads them; the part aliases `%PAYMENT_CONTEXT`, which serve_402 fills.

S8 (n288)
: the access log and unit registry sections (8 subs, 229 lines, the end of the script) moved to `lazysite-processor/access-log.pm`. Its one file-scope state, `my $_UNITS;` in a bare block, has no initialiser, so running the block at load rather than after the request leaves it undef until the first lookup, as before. Lints 159 and 198 read the part; lint 215 ends an indented sub at its own `}`; the two sysopen calls write the Fcntl constants as calls, so the part compiles alone (lint 04).

S9 (n289)
: the front door section (7 subs, 365 lines) moved to `lazysite-processor/front-door.pm`; lint 42 and test 47 lift its subs from the part. Measured S6-S9 interleaved (main = the S5 tree, n286-n289, 6 rounds, beside a coverage run): render_cache_hit_ms 100.0 to 99.2, render_miss_ms 132.6 to 129.7, inside each tree's 6-17% spread; `perl -c` median 97.96 to 98.58 ms. The processor is 9,126 lines.

S10 (n291)
: the Include section (12 subs, 464 lines) moved to `lazysite-processor/include.pm`. Its file-scope state, the url_safe filter's two scheme tables, is a `my` filled in BEGIN as in the script: full before any request either way. Test 71 lifts `_resolve_include` from the part; lints 31 and 36 read the script and every part for the `_acl_denied` rule.

S11 (n292)
: the Forms section (10 subs, 815 lines; `_render_form` whole) moved to `lazysite-processor/forms.pm`; it has no file-scope state. The SM071 header the plan names left with the preview cookie in S7, so `# --- Forms ---` heads the block. Lint 156 reads the banner's sentence map from the part; lint 56 counts inline blocks in the script and every part.
