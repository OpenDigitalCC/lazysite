---
title: "SM516: the shape after the changes"
subtitle: "Ten read-only structural reviews on 2026-08-25 measured the engine file by file and came back with two kinds of finding: defects a probe proved, and cleanups whose equivalence is visible on the diff. This is the one plan that orders both for the 0.10.33 edge cycle."
brand: plain
standard-margins: true
status: candidate
status-note: "PLANNED FOR 0.10.33 EDGE on the operator's instruction 2026-08-25; consolidates ten read-only reviews; nothing here is built yet; behaviour findings are listed separately from cleanups because they are defects, not tidying, and each will get its own SM when picked. The one exception already on main is SM515 (the MCP cap-less brief tools), landed before the 0.10.32 beta build and kept in the defect table for completeness only."
---

# The reports

Each finding below keeps its report's own ref. Where two reports share a prefix (`NR-`, `N-`) the report tag is prepended.

| Tag | Report | Refs |
|---|---|---|
| processor | `/srv/projects/lazysite/tmp/processor-review-2026-08-25.md` | PR-, PO-, one finding |
| manager-api | `/srv/projects/lazysite/tmp/review-manager-api-2026-08-25.md` | MA-, MO-, N-1..3 |
| mcp | `/srv/projects/lazysite/tmp/review-mcp-2026-08-25.md` | MC-, MCO-, P1..P6 |
| frontdoor | `/srv/projects/lazysite/tmp/review-frontdoor-cgis-2026-08-25.md` | FD-, FDO-, NR-1..3 |
| path-core | `/srv/projects/lazysite/tmp/review-path-core-2026-08-25.md` | PC-, PCO-, NR-1..6 |
| themes | `/srv/projects/lazysite/tmp/review-themes-layouts-domains-plugins-2026-08-25.md` | TL-, TLO-, N-1..6 |
| backups | `/srv/projects/lazysite/tmp/review-backups-package-upload-data-git-2026-08-25.md` | BP-, BPO-, N1..N6 |
| data-auth | `/srv/projects/lazysite/tmp/review-data-auth-capabilities-2026-08-25.md` | DA-, DAO-, one finding |
| tools | `/srv/projects/lazysite/tmp/review-tools-installer-2026-08-25.md` | TO-, TOM-, NR-1..7 |
| plugins | `/srv/projects/lazysite/tmp/review-plugins-2026-08-25.md` | PL-, PLO-, NR-1..9 |

# Defects found by the reviews (not cleanups)

Only rows a probe under `tmp/` reproduced, with the `.out` kept beside it. `**` marks the rows where an authenticated but under-privileged party reads or changes something they should not, or where anonymous exposure occurs; each carries a sentence on why. Ranked security-confidentiality first, then integrity, correctness, operability. Every row becomes its own SM when picked; the proving test lands first.

| SM | Ref | Area / file | What | Class | Proving test (named by the report) | Timing |
|---|---|---|---|---|---|---|
| SM517 | ** manager-api N-1 | lazysite-manager-api.pl `%file_surface` 978-1004; Upload zip | `file-download` and `file-zip-download` bypass the SM268 H4 carve-out: a manage_content+ui account reads `forms/submissions/*.jsonl` and `nav.conf` that `read` refuses. Confidentiality: the carve-out exists to keep submission bodies from accounts without read_submissions, and two verbs hand them over. | security-confidentiality | extend unit/manager/62-carveout-caps with both verbs (body lacks SUBMISSION-BODY-MARKER, NAV-BODY-MARKER); security register entry | BEFORE-BETA-PUBLISH |
| SM518 | ** path-core NR-6 | Manager/Files.pm 913-918 `action_move` | A folder move through the manager or MCP re-keys only the exact source key; `docs/team/a.md` under `read: [alice]` becomes `archive/team/a.md` with no rule and no report. Confidentiality: gated content silently becomes public after a rename. | security-confidentiality | unit/manager/66-the-rule-goes-with-the-content: "a manager move of a folder carries every rule beneath it" | BEFORE-BETA-PUBLISH |
| SM519 | ** data-auth YAML bool | Data/Descriptor.pm 264, 313, 314; `_check_field` 101-103 | `public: no` (and `off`, `No`) is a YAML 1.2 string and reads as TRUE: the table is exposed to anonymous visitors through Access.pm; `required: no` refuses writes; `unique: off` builds a unique index. Confidentiality: the natural spelling of "not public" publishes the rows. | security-confidentiality | new assertion in unit/data/01 or 09: `_bool` accepts 1/0/true/false only and refuses `no` with the promised message | BEFORE-BETA-PUBLISH |
| SM520 | ** themes N-3 | Manager/Domains.pm `domain_preview` 528 | Strips only `HTTP_X_REMOTE_*`/`LAZYSITE_AUTH_*`; forwards the operator's `HTTP_COOKIE` and `HTTP_AUTHORIZATION` to the processor, so a draft or gated section previews as visible under the domain check. Confidentiality: a preview meant to show the anonymous view renders as the operator. | security-confidentiality | NEW t/unit/manager/101-a-domain-preview-is-anonymous.t: `unlike($d->{html}, qr/lzs_session=/)` | BEFORE-BETA-PUBLISH |
| SM521 | ** mcp P4 | lazysite-mcp.pl 3252-3254 | Anonymous `tools/call` answers -32602 "Unknown tool" for a bogus name and 401 for a real one: a tool-name oracle that undoes SM210's hidden vocabulary. Confidentiality: unauthenticated enumeration of the tool surface, one probe at a time. | security-confidentiality | swap the two statements (auth first); unit/mcp/01 "unknown tool -> invalid params" already authenticates and is unaffected; add an anonymous-probe assertion | BEFORE-BETA-PUBLISH |
| SM515 | ** mcp P1 (SM515) | lazysite-mcp.pl `list_briefs`, `delete_brief` | `schema` key and no `cap`: a manage_themes-only partner reached `delete_brief`; arguments never validated. Integrity: a capability gate the descriptor promises never fired. FIXED on main today (commit 6aa354f, t/lint/85, unit/mcp/01); listed so the count is honest. | security-integrity | t/lint/85 (every tool declares inputSchema and cap); unit/mcp/01 refusal for a webdav-only bearer | done (on main) |
| SM522 | ** processor FRONT_MATTER_RESERVED | lazysite-processor.pl 5343 | `our %FRONT_MATTER_RESERVED` sits below the dispatch, so under CGI/FastCGI it is empty at request time: `auth`, `layout`, `register`, `search` reach the stash as `page_<key>` and scan records carry them as custom keys. Integrity: front matter overrides values the engine reserves, and a listing can expose a gated page's `auth` setting. | security-integrity | `_front_matter_reserved()` sub; widen t/lint/39 to `our`; real assertion in t/unit/processor/60 (`tmp/proc-probe-reserved.t` is the model) | BEFORE-BETA-PUBLISH |
| SM523 | ** plugins NR-3 | plugins/form-handler.pl `parse_post`, 202-206 | A visitor posting `_quarantined=1&_spam_reason=...` mutes their own notification and skews the blocked/quarantined counts. Integrity: a client controls engine-owned flags on the stored record. | security-integrity | NEW t/unit/forms/11-a-visitor-cannot-flag-themselves.t: `ok(!exists $row->{_quarantined})`, `is($notices, 1)` | BEFORE-BETA-PUBLISH |
| SM524 | ** plugins NR-4 | plugins/form-smtp.pl 320, 462, 511 | `auth: 1` / `auth: yes` silently skip SMTP authentication (`/^true$/i`), and `tls: false` still lists `tls` as checked. Integrity: the operator believes auth and TLS were verified when neither was. | security-integrity | extend t/unit/forms/05 mock-server block: `is($r->{stage}, 'auth')` for `auth: 1`; no `tls` in `checked` when tls is false | BEFORE-BETA-PUBLISH |
| SM525 | mcp P6 | lazysite-mcp.pl `_tool_names` | `whoami.tools` echoes every tool name to any authenticated caller while `tools/list` filters by caps (SM196) | security-confidentiality (low) | derive from `tool_list($caps)`; assertion in unit/mcp/01 | 0.10.33 |
| SM526 | themes N-1 | Manager/Domains.pm `_ip_is_public` 1140-1156 vs `_ip_is_public` 1019-1042 | Two "is this address public" answers disagree on 8 of 15 inputs; `instance_public_ips` can offer a mapped loopback or CGNAT address as "this server" to `domain_check` | correctness | NEW t/unit/manager/99-one-answer-to-is-this-address-public.t | 0.10.33 |
| SM527 | path-core NR-1 | Manager/Files.pm lock key (7 sites) | Lock key is the request spelling: a lock taken as `content/p.md` is not seen by a save of `/content/p.md`; MCP and API already mint different keys | correctness | unit/manager/08-lock-interop: "a lock taken as content/p.md refuses a save spelled /content/p.md" | 0.10.33 |
| SM528 | path-core NR-2 | Manager/Files.pm 536, 811 | Alias on a page in the private store indexes `/old-x -> /-lazysite-private/members/x` and can never be de-indexed | correctness | unit/manager/71-acl-moves-content: "an alias on a gated page targets its public URL" | 0.10.33 |
| SM529 | path-core NR-3 | Manager/Files.pm 1400-1408 | `action_acl_set('/')` and write-only rules return `content_moved => 1` with the moved note while moving nothing | correctness | unit/manager/67-root-acl-writer: "the site-wide reply does not claim content moved" | 0.10.33 |
| SM530 | path-core NR-4 | Manager/Files.pm 850 (+411, 523, 896, 985) | `make_path ... or return` never reaches the `or`: mkdir into an unwritable parent dies with no refusal and no audit line | operability | NEW unit/manager test: "a mkdir into an unwritable parent returns a refusal" | 0.10.33 |
| SM531 | themes N-2 | Manager/Themes.pm 811, 1628-1632, 1697-1698, 1762 | Four cache walks disagree on whether `<page>.url` is a source; `cache_invalidate('*')` keeps its render | correctness | NEW t/unit/manager/100-a-url-page-is-a-cache-source.t | 0.10.33 |
| SM532 | themes N-4 | Manager/Themes.pm `action_theme_rename` 1359-1383 | Renaming the active or in-use theme succeeds and strands the site with no theme mirror | operability | NEW t/unit/manager/102-renaming-the-active-theme-keeps-the-site-styled.t | 0.10.33 |
| SM533 | themes N-6 | Manager/Layouts.pm 397-400, 1007 | Every manifest install leaks `/tmp/lazysite-layout-install-$$` (the cleaner's regex names a different prefix) | operability | NEW t/unit/manager/104-a-layout-install-cleans-up-after-itself.t | 0.10.33 |
| SM534 | frontdoor NR-1 | lazysite-dav.pl `do_copy_move` 741-899 | DAV MOVE/COPY never invalidate the registries; sitemap lists the old URL and misses the new one | correctness | two subtests in t/integration/74: cache gone, new URL listed | 0.10.33 |
| SM535 | frontdoor NR-2 | lazysite-dav.pl `do_delete` 647-655 | Collection DELETE leaves registries and the alias map pointing at removed pages (a 301 to a 404) | correctness | NEW t/unit/dav/23-a-collection-delete-cleans-up.t: alias lookup undef after DELETE | 0.10.33 |
| SM536 | frontdoor NR-3 | lazysite-dav.pl `do_put` 537; processor `try_serve_cache` 1980-2012 | nav.conf written over DAV leaves every cached page on the old navigation; the manager's `nav-<site>.conf` misses too. Prefer the processor-side fix (nav mtime in the cache key) | correctness | NEW t/integration/75-a-nav-write-reaches-every-cached-page.t | 0.10.33 |
| SM537 | mcp P1c-h | lazysite-mcp.pl `%ANNOTATE` 3010 | 22 tools fall to `[0,0,1]`: reads advertised as open-world writes, `drop_data_table`/`delete_theme` as non-destructive; clients drive approval from these | correctness | `annotate` key per entry; t/lint/23 asserts presence; `%READ` derived | 0.10.33 |
| SM538 | mcp P5 | lazysite-mcp.pl `_each_page` 1842 | Hard-skips `docs/` and `quotes/`: on lazysite.io thirty documentation pages are absent from `list_pages`, `audit_site`, `rename_page update_links` | correctness | test that a page under `docs/` is listed; use `Common::path_is_reserved` | 0.10.33 |
| SM539 | plugins NR-2 | plugins/form-handler.pl 926 vs 943-950 | A repeated key survives urlencoded but a multipart POST keeps only the last value: forms with an upload lose checkbox ticks | correctness | NEW t/unit/forms/10-a-multi-answer-survives-a-multipart-post.t | 0.10.33 |
| SM540 | plugins NR-1 | form-handler, form-smtp, audit, payment-demo `log_event` | Plugin diagnostics never reach syslog: private `log_event` copies predate `forward_line` | operability | NEW t/unit/forms/12-a-handler-error-is-forwarded.t | 0.10.33 |
| SM541 | plugins NR-5 | plugins/stats.pl 2427-2444 | Reach-back reversal replays events with no `device`/`term`, so devices and search terms drift on every late scanner promotion | correctness | NEW t/unit/plugins/29-a-promotion-reverses-the-device.t | 0.10.33 |
| SM542 | plugins NR-6 | plugins/stats.pl `scan_first_party` 970-986 | `--scan` finalises a day with `forms:{}` and a later `--export` never rewrites it | correctness | NEW t/unit/plugins/30-the-page-refresh-keeps-form-outcomes.t | 0.10.33 |
| SM543 | plugins NR-7 | plugins/stats.pl 604, 638, 2586 | `--recount --apply` reclassifies under the built-in rules, ignoring `classifiers.json`, and counts its own misclassification as a repair | correctness | NEW t/unit/plugins/31-a-recount-uses-the-loaded-ruleset.t | 0.10.33 |
| SM544 | backups N1 | Manager/Backups.pm `_archive_scope` 307-337 | A restore's safety snapshot skips bare top-level members and never deepens past `sites/`: no rollback copy of what the restore overwrites | correctness | `bp-probe-archive-scope.t` as a unit test: the safety tarball carries `./index.md` | 0.10.33 |
| SM545 | backups N2 | Manager/SitePackage.pm 204-206, 392 | Two site packages in one second are one file; the O_EXCL claim of 03-F9 was never carried across | correctness | `bp-probe-package-name.t` as a test: two creates, two files | 0.10.33 |
| SM546 | backups N3 | Manager/SitePackage.pm 599 | `package_apply` dies with `Undefined subroutine` unless something else loaded Backups | operability | NEW single assertion: `package_apply` from a fresh process returns a hash | 0.10.33 |
| SM547 | backups N5 | Manager/Backups.pm 212-229; SitePackage | Site packages have no retention: the 03-F11 disk-filling loop on the artefact an agent produces most | operability | NEW single assertion: `backup_retention: 1` leaves one site package | 0.10.33 |
| SM548 | backups N6 | lazysite-manager-api.pl 2433; Upload 63-64 | `check_upload_rate($DOCROOT)` where the signature is `($username, $len)`: one shared package-upload budget per instance and an inert byte limit | operability | `bp-probe-rate-key.t` as a test: key carries the user, byte limit fires | 0.10.33 |
| SM549 | tools NR-4 | tools/lazysite-users.pl 1538 vs five inline blocks | `actor: local` is exempt for passwd/rename/claim/create and refused by `_authorise_manage` for disable/enable/reassign | correctness | NEW t/unit/users/32-local-is-one-actor.t; SM268 C1 decides whether local is honoured | 0.10.33 |
| SM550 | tools NR-5 | tools/lazysite-check.pl 1788 | SM315's standing check never runs: `conf_value('layout')` opens a file named `layout` | operability | NEW t/tools/62-check-reports-an-unmirrored-theme.t | 0.10.33 |
| SM551 | tools NR-6 | tools/lazysite-check.pl `report_group_acl_reach`, `_acls_file` | Builds `$docroot/lazysite/auth/acls.json` instead of `model_path`: on a migrated site the @group reach is silent | correctness | t/tools/38-migrate-engine-tree: NEW assertion `like /\@agents is granted by/` | 0.10.33 |
| SM552 | tools NR-2 | tools/release.sh 572-600 | Coverage verdict block is dead under `set -e`: neither "below the floor" line nor COV_LOG location ever prints | operability | t/tools/58: add `set -e` to the generated run.sh (fails today) | 0.10.33 |
| SM553 | manager-api N-2 | lazysite-manager-api.pl `_audit_implicit_target` | `theme-activate&theme=sky` audits target `/`, not `sky` | operability | t/unit/manager/56: audit line target is the name | 0.10.33 |
| SM554 | manager-api N-3 | lazysite-manager-api.pl `%skip` 1745 | `POST action=notices` / `layouts-manifest` write an `ok` audit row | operability | NEW t/unit/manager/98-a-posted-read-is-not-audited.t | later |
| SM555 | path-core NR-5 | Manager/Common.pm 350-368 | Listing `/lazysite` writes one `blocked lazysite tree` WARN per hidden entry - reads as an attack in a log review | operability | new assertion counting log lines for one listing | later |
| SM556 | themes N-5 | Themes 1334, Plugins 958, Themes 1746 vs Layouts 636, Domains 971 | Under a symlinked docroot three modules refuse and two succeed; fix at the two dispatchers (canonicalise once) | correctness | NEW t/unit/manager/103-a-symlinked-docroot-is-one-docroot.t | later |
| SM557 | plugins NR-1a | plugins/form-handler.pl | Every POST writes two `used only once` warnings; t/lint/04 checks the exit code only | operability | t/lint/04: `unlike($out, qr/used only once/)` | later |
| SM558 | plugins NR-8 | plugins/audit.pl 150-158, 370-377 | A link to `/index` or `/index.html` is always reported broken | correctness | NEW t/unit/plugins/32-the-link-audit-sees-the-root-page.t | later |
| SM559 | backups N4 | Manager/SitePackage.pm 41, 240, 354-355 | An unreadable layout dir is reported as unreadable content (layout-relative path, no prefix); `@COPY_FAILED` is never drained | correctness | `bp-probe-copy-failed-layout.t` as a test: the walker returns its failures, the caller labels them | later |
| SM560 | tools NR-1 | tools/release.sh 343 vs thirteen abort paths | Prints `staging dir retained` and the EXIT trap removes it | operability | NEW t/tools/61-an-abort-keeps-what-it-says-it-kept.t | later |
| SM561 | tools NR-3 | tools/release.sh 648-652 | The "produced no pages" refusal cannot fire (`--prefix` appended before the emptiness test) | operability | t/tools/27-manpages: lift 641-652 against an empty dir, expect exit 1 | later |
| SM562 | tools NR-7 | tools/lazysite-cli.pl `run_tool_per_site` 360 | Any non-zero child is "with findings"; a check that could not check is a site finding | operability | NEW t/tools/63-a-refusal-is-not-a-finding.t | later |

Each row is filed individually as SM515, SM517-SM562; SM516 remains the plan and the register.

Reading-level only, not tabled (no runtime probe; file to the security register before the batch that touches them): plugins NR-9 (form-smtp legacy CGI mode has no caller and no gates); tools A1/A2/A7 (install.pl symlink walk skipped on an existing tree, `cmd_restore` copies through a dangling link as root, predictable `/tmp/lazysite-manifest-$$.json`); data-auth OAuth `chmod 0660` vs `secure_write_perms` and `may_read` on a comma-string `groups`; processor `$ACL_MAP_CACHE` / `_scan_identity` / `%PAYMENT_CONTEXT` not reset under FastCGI; manager-api `action_save` uninitialized-`$content` warning; themes layout-activate discarding the mirror count.

# Cleanups, batched

Every row is a no-behaviour-change refactor as its report states; risk L is diff-visible equivalence, M crosses a gate, loop, lint pin or file boundary. Rows sit in the batch their report chose, in that report's value-for-risk order.

## Batch 1: trivial, dead, dedupe (one commit each; run the owning suite and t/lint once)

| Ref | File | What | Risk | Proving test |
|---|---|---|---|---|
| PR-2 | processor | Six no-op `require JSON::PP` inside subs | L | unit/processor/08, integration/06, 39 |
| PR-14 | processor | Redundant `sort @files` at 5479 | L | unit/processor/03 |
| PR-15 | processor | Stale comments: P-2 call count, resolve_db past-tense bug, F7 note | L | none |
| PR-3 | processor | `peek_search_default` becomes a one-line wrapper of `peek_conf_key` | L | unit/processor/03, 04, 10 |
| PR-12 | processor | `_registry_stale($path)` for the twice-written TTL test | L | unit/processor/46, unit/manager/55 |
| PR-1 | processor | `_lazy_lib($module)` for the three verbatim `@INC` bootstraps | L | unit/processor/16, 41; unit/lib/19; integration/64 |
| PR-8 | processor | `_emit_json_nostore($body)` for the two identical header stacks | L | unit/manager/33, unit/mcp/14, lint/55 |
| PR-13 | processor | Section markers for the three unmarked stretches; `_chrome*` beside the site helpers | L | lint/39 after any move |
| MA-1 | manager-api | Delete ~230 lines of orphaned section headers and moved-sub commentary | L | lint/04, lint/06 |
| MA-7 | manager-api | The SM465 comment pasted twice | L | lint/06 |
| MA-13 | manager-api | No-op `require Lazysite::Util` and dead `->can('clear_host_cache')` guard | L | unit/manager/58, 59 |
| MA-15 | manager-api | Dead `%skip` entries `preview-grant`, `preview-clear` | L | unit/manager/09, 19 |
| MA-16 | manager-api | `my $body` shadow in data-export; rename `$bytes` | L | integration/53 |
| MA-11 | manager-api | `_json_bool` for the `$bool` closure defined twice | L | unit/manager/36, integration/69 |
| MA-8 | manager-api | `action_site_backup_apply` uses `_site_package_path` instead of re-inlining the regex | L | unit/manager/46, 60 |
| MC-3 | mcp | Second `%introspection` literal replaced by `%INTROSPECTION_TOOLS` | L | unit/mcp/02 |
| MC-5 | mcp | `_page_status` calls `_public_url` | L | unit/mcp/01 |
| MC-14 | mcp | Stale `.brief` sidecar tests, dead scalar-window branch, doubled `LAZYSITE_DIR` set | L | unit/mcp/01; unit/manager/71 |
| MC-15 | mcp | Capture the bearer once in `send_401` | L | unit/mcp/01, unit/oauth/02 |
| MC-13 | mcp | Delete the SM087 nav stub, retitle 2189, move `_mcp_language_note` and `%ANNOTATE` | L | lint/39, lint/23 |
| MC-1 | mcp | Set `Data::DOCROOT` in `setup_context`; delete 13+4+2 redundant `local` lines | L | unit/mcp/09, 12; unit/manager/58 |
| FD-1 | dav | Delete uncalled `manage_config_for` | L | unit/dav/08, lint/68 |
| FD-2 | dav | Unreachable `return @warnings if $path eq ''` | L | unit/dav/05 |
| FD-3 | dav | Unused imports `sha256_hex`, `dirname basename`, `const_eq` | L | unit/dav/09, 01 |
| FD-4 | dav | Stale header/duplication comments and empty Logging section | L | none |
| FD-15 | dav | `send_status` as an alias of `send_response` | L | unit/dav/* |
| FD-16 | auth | Delete `_session_user`, `read_cookie`, `uri_decode_simple` | L | unit/auth/14, 02 |
| FD-17 | auth | Unused imports `sha256_hex`, `const_eq`, `strftime` | L | unit/auth/02 |
| FD-18 | auth | Four orphaned comment blocks over gaps | L | none |
| FD-27 | data | Reuse `@groups` from the session; hoist the second `require Tables` | L | integration/60, unit/data/16 |
| FD-28 | data | Align the BEGIN bootstrap candidates with dav/auth/processor | L | lint/59 (widened) |
| PC-7 | Files | Dead requires, unused imports, unused `$real` parameter | L | perl -c; t/lint |
| PC-11 | Common | Redundant second `local $_` | L | lint/66 |
| PC-12 | Common | Move the SM268 H4 comment back above `carveout_requirement` | L | none |
| PC-15 | Files | Stale header and `.brief` sidecar comments | L | none |
| PC-16 | Files | Section markers; registries section below delete/move/copy | L | perl -c; t/unit/manager |
| PC-6 | Files | `_present_root_key` from `keys %ROOT_SPELLING` | L | unit/manager/74, 67 |
| PC-10 | Common | `_conf_list($v)` for the two split/grep/strip blocks | L | unit/manager/02 |
| PC-4 | Files | `_drop_render_cache($full)` for the three unlink+host-copies sites | L | unit/manager/21; unit/lib/09 |
| TL-1 | Themes, Layouts, Domains, Plugins | Twelve unused imports | L | unit/lib/18, lint/25 |
| TL-3 | Themes | `_default_theme_for_layout` calls `_read_layout_json` | L | unit/manager/76; unit/lib/10 |
| TL-15 | Domains | Dead second regex and repeated env deletes in `_rendered_presentation`/`preview_public` | L | unit/manager/92, 87; integration/59 |
| TL-16 | Domains | Redundant `require File::Path`; hoist the `$layout eq` test | L | unit/manager/32, 37 |
| TL-23 | Themes, Layouts | Sixteen litter blank lines and two "moved from" markers | L | none |
| TL-12 | Layouts | `unless (open)...else` to the `or do {}` shape | L | unit/manager/06 |
| TL-4 | Themes, Layouts | Export and use `_usage()` for the three inline Domains bridges | L | unit/manager/37, 08, 50 |
| TL-22 | Themes | `_backup_dirs` for the readdir+grep in two places | L | unit/manager/11, 13 |
| TL-14 | Domains | One `_effective(...)` for the three `$eff` closures | L | unit/manager/50, 37, 51 |
| TL-11 | Layouts | `_copy_rel_files` for the twin cp loops | L | unit/manager/10, 11, 78 |
| TL-10 | Layouts, Themes | `_valid_repo` (5 copies) and `_have_azip` (4 copies) | L | unit/manager/06, 07, 09; unit/lib/18 |
| BP-11 | Data | Reorder actions so the three displaced comment blocks land | L | lint/57, 77 after the move |
| BP-12 | Data | `use` lines above `our`; drop core `require File::Path` | L | unit/data/15 |
| BP-13 | Git | `path_at` uses `_valid_sha`; one empty-summary literal | L | unit/lib/20; unit/manager/25 |
| BP-14 (marker) | Upload | Stale "moved from" marker | L | integration/05 |
| BP-15 | Backups, Upload | `open ... or return` shape | L | unit/manager/60; unit/lib/08 |
| BP-8 | Data | `_valid_table_name` for the twice-written regex and message | L | integration/55; unit/manager/96 |
| BP-9 | Data | `_schema_pending($dbh, $name)` for the two observed_schema derivations | L | unit/manager/94; integration/53 |
| BP-10 | Data | `_export_path($file)` for the SM512/SM514 name preamble; retires the bare `$1` at 572 | L | unit/data/25 |
| BP-4 | SitePackage | `Export::to_json` for the canonical-pretty chain at 294 and 382 | L | unit/data/13; unit/manager/35 |
| DA-1 | Tables | Dead second `return $d` | L | unit/data/10 |
| DA-4 | Tables | Dead `require SQLite`; import `drop_table_sql`; unqualified `read_handle` | L | unit/data/20, 25 |
| DA-5 | Tables | One `use JSON::PP ()` / `use Time::HiRes ()` for five in-sub requires | L | unit/data/25, integration/62 |
| DA-10 | Connect | Hoist `busy_timeout` out of both readonly arms | L | unit/data/03, 11 |
| DA-11 | Query | `use Lazysite::Data::SQLite ()` instead of a per-call require in `ROW_CAP` | L | unit/data/17 |
| DA-12 | Schema | `%want_index` built and never read | L | unit/data/06 |
| DA-13 | Schema | Dead `require Value`; unqualified `coerce_field` | L | unit/data/22 |
| DA-21 | Settings, Session | Six `require JSON::PP` become one `use` per file | L | unit/lib/03, unit/auth/12 |
| DA-28 | Capabilities | `require Util` out of the per-capability loop | L | unit/lib/05, 26 |
| DA-29 | DomainAccess | `_blank_domain()` for the literal written twice | L | unit/lib/20 |
| DA-30 | Export | Add `to_json` to `@EXPORT_OK` | L | unit/manager (site-export) |
| DA-16 | Descriptor | `@EXPORT_OK` names `load_all`, `validate_row` which do not exist | L | NEW t/lint: every Data `@EXPORT_OK` name is `can`-able |
| TO-4 | users | `_urlenc` and `_uri_escape` are one function | L | t/unit/users/12, 14 |
| TO-5 | users | Dead `normalise_scope`, `_has_settings_entry`; alias `read_manager_groups` | L | t/unit/users/05, t/lint/04 |
| TO-6 | users | Orphaned comment blocks and headers above the wrong sub | L | none |
| TO-8 | users | No-op `require JSON::PP` x2; repeated `require Settings` + `local $AUTH_DIR` | L | t/unit/users/02, 05, 30 |
| TO-12 | check | Hoist ten in-sub `require JSON::PP` and `require File::Find` | L | t/lint/04, t/tools/04 |
| TO-18 | cli | Compile-time BEGIN inside `cmd_migrate_engine_tree` replaced by one `unshift @INC` | L | t/tools/38, t/lint/59 |
| TO-19 | cli | Dead `$how`, `$would`, `$s->{url}`, "--url overrides" text | L | t/tools/42, 38 |
| TO-26 | install | Backup glob x3, `lazysite.conf` path x6, `sha256:` prefix x4, `abs_path // $x` x5, double sort, redundant `-e || -l` | L | t/tools/03 |
| TO-29 | release | Duplicate `rm -rf "$STAGE"`, contradicted `NO_FETCH` comment, `release:` prefix | L | t/tools/47, t/lint/07 |
| TO-3 | users | `_site_base_url` for the four base-URL expansions | L | t/unit/users/12, 15, 13 |
| TO-23 | install | One `audit_install($action, %detail)` for six one-line wrappers | L | t/tools/03 |
| TO-14 | check | Comment blocks back beside their subs; 8c-8i call order | L | t/unit/tools/40, t/lint/39 |
| PL-1 | four CGI plugins | In-sub `use POSIX`/`require POSIX`/`require JSON::PP` already loaded at top | L | t/lint/04; unit/forms/04 |
| PL-6 | form-handler | Unreachable `return unless $ip`; stale SM402 sentence | L | unit/forms/08 |
| PL-11 | stats | Two inline `$top` closures replaced by `_topn` | L | unit/plugins/02, 27 |
| PL-14 | stats | `_batch_record(%fields)` for both ingesters; dead `$EVENT_CAP`/`$IP_CAP`, unused `$cfg` params | L | unit/plugins/07, 16 |
| PL-15 | stats | `by_day` from `@CLASSES`; stale record-shape comment and usage string | L | NEW t/unit/plugins/28-by-day-carries-every-class.t |
| PL-17 (header, dead branch) | audit | `canonical`'s unreachable `.html` branch; header lines 2 and 5 | L | NEW t/unit/plugins/30-the-link-audit-report-is-stable.t |
| PL-21 | briefs, data, form-smtp | Contract tidy: positional `--describe`, usage exit 1, one DOCROOT expression per file | L | integration/61; unit/lib/08; unit/manager/62 |

## Batch 2: shared helpers within a file (run the named tests after each)

| Ref | File | What | Risk | Proving test |
|---|---|---|---|---|
| PR-5 | processor | `_page_date`, `_page_url` shared by resolve_scan and scan_pages | L | unit/processor/03, 46; integration/37, 39 |
| PR-4 | processor | `_render_fallback_layout` from the two identical TT blocks | L | unit/processor/19; integration/03, 57 |
| PR-9 | processor | `_auth_context_from($result, %extra)` for the two `%AUTH_CONTEXT` literals | L | unit/processor/08; integration/03; journey/02 |
| PR-11 | processor | `_esc_attr` for six inline entity pairs; fold with `_form_attr` | L | unit/processor/07, 17, 20; lint/56 |
| MA-2 (+MO-2) | manager-api | `_json_body()`: one memoised decode for 42 sites | L | unit/manager/43, 85; integration/53 |
| MA-3 | manager-api | `_refuse` and `_bail` for the audit+respond+exit triples | L | unit/manager/29, 10, 39, 62; integration/06 |
| MA-4 | manager-api | `users_api` / `_users_tool_call` become one | L | unit/manager/24, 10, 48 |
| MA-5 | manager-api | Delete uncalled `_user_audit`; fold two one-line cap readers | L | unit/manager/24, 23, 35 |
| MA-6 | manager-api | `_briefs()` for five verbatim require/DOCROOT/auth_user triples | L | integration/72; lint/77 |
| MA-9 | manager-api | `_package_within_scope($pkg)` for three inspect-then-scope blocks | L | unit/manager/46, 31 |
| MA-12 | manager-api | `_conf_text()` for the two raw slurps of lazysite.conf | L | unit/manager/35, 36 |
| MA-17 | manager-api | `_emit_json` for three hand-printed JSON responses | L | lint/21; unit/manager/13, 09 |
| MA-18 | manager-api | `_tool_path($env_key, $rel)` for the two four-candidate ladders | L | unit/manager/10; NEW t/unit/manager/98-tool-paths-resolve.t |
| MC-2 | mcp | `_briefs()` for the four brief tools | L | NEW t/unit/mcp/22-briefs-over-mcp.t |
| MC-4 | mcp | `_sibling_tool(@candidates)` and `_run_json_tool` | L | unit/mcp/01, 14 |
| MC-6 | mcp | `_norm_slug($path)` for six spellings of the chain | L | unit/mcp/01 |
| MC-7 | mcp | `_domain_row` + `_croot_outside_scope` for site_backup/site_apply | L | unit/mcp/04 |
| MC-9 | mcp | `_fm_line_offset($fm)` computed twice | L | unit/mcp/11, 12 |
| MC-12 (+MCO-3) | mcp | `_read_conf_text()` for three opens of lazysite.conf | L | unit/mcp/06, 16, 19 |
| MC-16 | mcp | Derive the `_submit_feedback` capability roster instead of hard-coding it | L | unit/mcp/01 + NEW assertion: saved list holds every granted cap |
| FD-5 | dav | do_put: drop the second require; merge the two `.md` blocks; `_invalidate_registries_as($user)` (the seam frontdoor NR-1 needs) | L | unit/dav/04; integration/74; unit/manager/49 |
| FD-14 | dav | `_scope_names($scope)`; every `_deny` string byte-identical | L | unit/dav/22; lint/16, 68 |
| FD-20 | auth | `_login_refused(...)` for the WARN+audit+sleep+redirect stanza | L | unit/auth/01, 03, 07, 09 |
| FD-21 | auth | `_clean_username` (five sites) | L | unit/auth/05, 06 |
| FD-22 | auth | `_reject_page($title_key, $body_key)` | L | unit/auth/04, 05 |
| FD-23 | auth | `_pipe_json(\@cmd, $payload)` for two open2 pipes | L | unit/auth/05, 08 |
| FD-24 | auth | `_emit_session_cookies($value, $max_age)` | L | unit/auth/02, 13; integration/03 |
| FD-9 | dav, auth | `Util::secure_transport()` for the HTTPS-or-loopback gate written four times | L | unit/dav/01; unit/auth/05, 06 |
| FD-10 | dav, auth | Share dav's `parse_basic_auth` | L | unit/auth/06; unit/dav/01 |
| PC-1 + PC-2 | Files | `_lock_file($rel)` (seven key derivations - keeps the raw path until path-core NR-1) and `_foreign_live_lock` | L | unit/manager/08 |
| PC-5 | Files | `_with_domains(sub {...})` for the require/local/eval bracket | L | unit/manager/55, 88 |
| PC-9 | Common | `_norm_rel($rel)` for the identical collapse in two subs | L | unit/manager/61, 66 |
| PC-3 | Files | `_gated_path($rel)` for the six two-message prologues; leave the six one-message sites | M | unit/manager/28, 42; lint/15 |
| PC-13 | Files, Common | `write_file_checked({ binary => 1 })` replaces the inline temp/rename | M | unit/manager/52, 05 |
| TL-5 | Themes | `_themes_under(...)` for the twin listing loops | L | unit/manager/50, 06 |
| TL-6 | Themes, Domains | `_mirror_warning($mirror, $what)` | L | unit/manager/77, 51 |
| TL-2 | Themes, Layouts | `_read_theme_json_file` for eight decoders | L | unit/manager/06, 07, 76, 78; unit/lib/18 |
| TL-18 | Plugins | `_describe($full)` for six `--describe` sites; listing keeps the alarm | L | unit/manager/27, 62, 93; unit/lib/07 |
| TL-19 | Plugins | `_read_kv_lines`, `_slurp_or_empty` | L | unit/manager/62, 27; unit/lib/18 |
| TL-20 | Plugins | `_rewrite_store($abs, $keep)` for three read-filter-rename bodies | M | unit/lib/07; lint/15 |
| TL-9 | Layouts | `_fetch_release_zip($tag)` from the two verbatim zipball bodies; keep both error sets | M | unit/manager/06; lint/15; unit/lib/18 |
| BP-7 | Data | `_table_action($table)` for the twelve two-line preambles | L | integration/53; unit/manager/94; lint/77 |
| BP-3 | SitePackage | `_stage_extract($pkg, $label)` for inspect and apply | L | unit/manager/60 |
| BP-2 | Backups, SitePackage | `safety_snapshot_or_refuse($verb, $root)` for the SM378 block written twice | L | unit/manager/80, 61, 59; integration/75 |
| BP-5 | SitePackage, Data | `Export::read_export_file($path)` | L | unit/data/13, 25 |
| BP-16 (+BPO-1) | Backups | List-form `_archive_members($path)` replacing `qx(tar -tzf)` and backticks | L | integration/75; unit/manager/69; NEW t/unit/manager/83: metachar member lists identically |
| DA-2 | Tables | `_safety_export(...)` for the block duplicated in drop and rebuild | L | unit/data/20, 25, 14 |
| DA-3 | Tables | `_writer($docroot, $name)` for five write-handle-or-error pairs | L | unit/data/03, 10, 11 |
| DA-6 | SQLite | `_ident` as `'"' . _raw_ident . '"'` | L | unit/data/02 |
| DA-7 | SQLite | One `_where($d, $filter, $caller)` for count_sql and select_sql | L | unit/data/24, 05 |
| DA-8 | SQLite | `_loaded($d, $name)` for fifteen identical guards | L | unit/data/02, 05 |
| DA-14 | Schema | `_first_duplicate($dbh, $d, $f)` | L | unit/data/06, 22 |
| DA-25 | Session | First branch of `_csrf_secret` is `_auth_secret_read()` | L | unit/auth/02, 14 |
| DA-26 | OAuth | `_token_rec($access)` for three lookups | L | oauth/02, 03, 04 |
| DA-27 | Credential | `_iterate($salt, $plain, $iters)`; `verify_secret` uses `const_eq` | L | unit/auth/01; unit/lib/02 |
| DA-19 | Acl | `_settings_dir()` + top-level `use Settings ()`; keep the lint/35 literals | L | unit/lib/04; unit/users/18; lint/35, 36 |
| DA-20 | Settings | Keep one name each for `effective_groups`/`group_closure` | L | lint/35; unit/users/21 |
| TO-2 | users | `_take_flags(\@argv, {...})` for nine wrapper loops | L | t/unit/users/08, 11, 13, 22 |
| TO-11 | check | `_read_json($path)` for seven slurp-and-decode blocks | L | t/tools/59, 36, 53; t/unit/tools/41 |
| TO-13 | check | `_curl(\@flags, $url)` behind `_probe_get`/`_probe_head` | L | t/integration/43, 58; t/tools/41, 53 |
| TO-16 | cli | `_install_argv($site, %flag)` | L | t/tools/28, 29, 38 |
| TO-21 | cli | `_fleet_summary($verb, ...)` for three "no sites" and two summaries | L | t/tools/29, 28 |
| TO-24 | install | `cmd_set_channel`/`cmd_set_policy` and the two upgrade-gate branches | L | t/tools/03, 43 |
| TO-28 | release | `abort_build "<why>"` for thirteen identical abort blocks (what the line says is tools NR-1) | L | t/tools/34, 45, 58, 47; t/lint/07, 50 |
| TO-7 + TO-20 + TO-27 | users, cli, install | usage()/POD drift, one commit with the new lint | L | NEW t/lint/85-usage-names-every-dispatched-command.t (three files); t/tools/28 |
| PL-2 | form-handler | `_locate_lib()` for three runtime `@INC` locators; never a `use lib` | L | unit/forms/08; integration/63 |
| PL-3 | form-handler | `_visible_fields($form)`; unit/forms/07 rewritten in the same commit | L | unit/forms/07 (rewritten), 03 |
| PL-4 (+PLO-2) | form-handler | `load_form_conf` returns `notify_off`; one conf read | L | NEW t/unit/forms/10-notify-off-writes-no-notice.t |
| PL-5 | form-handler | `_targets_from`, `_upload_rules` | L | unit/forms/02, 04 |
| PL-7 | form-smtp | `load_smtp_conf` as defaults over `load_smtp_conf_from`; one DOCROOT | L | unit/forms/05, 03 |
| PL-10 | stats | `_month_series`, `_forms_fold` | L | unit/plugins/02 |
| PL-12 | stats | `_ref_host_kind`; one page-exclusion constant | L | unit/plugins/02, 13 |
| PL-16 | audit | `_rel_of($name)`, `_edit_url($page_md)` | L | NEW t/unit/plugins/30 (golden report over a fixture docroot) |

## Batch 3: seams, splits, reorders, cross-file folds (full `t/run-all.t` per commit)

| Ref | File | What | Risk | Proving test |
|---|---|---|---|---|
| PR-6 | processor | Split resolve_scan into parse/collect/record/filter/sort | M | unit/processor/03, 04, 61; integration/37, 39; lint/48 |
| PR-10 | processor | Split `_render_form` into parse/field-html/assemble | M | unit/processor/07, 48; unit/forms/01; journey/03 |
| PR-7 | processor | Split main into seven named gates; ordering comments move with the code; last | M | integration/06, 13, 14, 15, 50, 53, 66; journey/02, 03; unit/processor/18, 26; lint/42, 55 |
| MA-14 | manager-api | One `--- Action tables ---` section in request order, every table above 1022 | L | lint/22, 14, 58, 39 |
| MA-10 | manager-api | `action_domains_list` body becomes `Manager::Domains::domains_list()` | M | unit/manager/23, 33; lint/29 |
| MA-19 | manager-api | The chain as `%DISPATCH`; lint/22, 58, 14 rewritten to read the table; last | M | lint/22, 58, 14; unit/manager/43, 29, 10; integration/53; journey/02 |
| MC-8 | mcp | Hoist `_create_form`, `_upload_file`, `_site_apply` out of the table (after mcp P1c-h so the `annotate` key arrives on a uniform table) | L | unit/mcp/05, 14, 04 |
| MC-10 | mcp | Split `_validate_page` into seven `_check_*` | M | unit/mcp/01, 05, 10, 11, 12, 13, 15 |
| MC-11 | mcp | Split `_audit_site` into six `_audit_*` | M | unit/mcp/01, 14, 16, 17, 19; integration/33 |
| FD-8 | dav, auth | `Auth::Credential::load_users($dir)` for the verbatim pair | L | unit/dav/01; unit/auth/01; lint/66 |
| FD-19 | auth | Four hand-rolled user-settings.json readers become `read_settings()` lookups | L | unit/auth/04, 06, 07, 11; unit/users/27 |
| FD-7 | dav, Files | Lock record read/write exported from Files.pm (or Manager::Locks) | M | unit/dav/06; unit/manager/08 |
| FD-6 / PC-8 | dav, Files | dav `_sync_acl_store` folded onto `Files::_sync_private_store`; AFTER path-core NR-6 so both converge on the corrected shape once | M | unit/manager/66, 73; integration/47; unit/dav/05; lint/17 |
| FD-11 | dav | `_remove_entry`, `_move_bytes` in do_copy_move | M | unit/dav/05, 12; integration/41 |
| FD-12 | dav | `_stream_body`, `_after_put` so the guard order reads on one screen | M | unit/dav/04; integration/67, 74; unit/lib/18 |
| FD-13 | dav | `_authenticate($ip)`; main keeps the numbered pipeline comments | M | unit/dav/01, 10; integration/dav-publish |
| FD-25 | auth | Split handle_login into verify/gates/mint | M | unit/auth/01, 04, 06, 07, 10, 12; integration/03; journey/02 |
| FD-26 | data | Split main into params/identity/write/read | M | integration/59, 60, 55; unit/data/16 |
| PC-14 | Private | `_copy_then_remove(...)` with the two strings passed unchanged | M | unit/lib/20; unit/manager/75 |
| TL-21 | all four | One `Common::write_conf_as($docroot, $user, ...)` for four writer bridges | L | unit/lib/18; lint/25; unit/manager/06 |
| TL-7 | Themes, Layouts, Domains | `Common::conf_set_line(\$c, $key, $value)` | M | unit/manager/07, 32, 53, 56; unit/mcp/12; lint/25 |
| TL-8 | Themes, Layouts, Plugins | `Common::read_conf_key($key)` for six single-key scanners | M | unit/manager/06, 07, 11, 38, 62 |
| TL-13 | Themes, Layouts | One `_cleanup_tmp` with a prefix parameter; AFTER themes N-6 | L | unit/manager/06; lint/15 |
| TL-24 | Themes | Shared declared-tokens reader that does not sort | M | unit/manager/50; NEW t/unit/manager/98-theme-tokens-keeps-declared-order.t |
| BP-1 | SitePackage | One `_copy_tree` walker replaces `_copy_base_content` | M | unit/manager/35, 61, 64 |
| BP-6 | Upload, Backups, manager-api | `Common::stream_attachment(...)` for four header+sysread stacks; last | M | unit/lib/08; integration/05; unit/manager/20 |
| BP-14 (interface) | Upload | `collect_zip_paths` takes the list as an argument | M | integration/05 |
| DA-9 | Schema, SQLite | Export `index_name` from SQLite; delete Schema's copy | L | unit/data/06 |
| DA-18 | Query, Schema, SQLite, Descriptor, Value | `Descriptor::is_column($d, $f)` and exported `RESERVED` for six copies | M | unit/data/17, 18, 06, 22 |
| DA-22 | Settings, Session, Acl, OAuth | `Util::read_json_file($path)` for six slurp-decode copies | M | unit/lib/03, 04; unit/auth/12; oauth/02 |
| DA-23 | Settings, Acl, OAuth | One write-tmp-then-rename; only after the OAuth chmod question is ruled | M | unit/auth/15; unit/lib/03; oauth/03 |
| DA-24 | Settings, Session | One groups-file parser | M | unit/auth/13; lint/35 |
| DA-15 | Schema | Split plan_rebuild into columns/steps/blockers | M | unit/data/22, 14, 23 |
| DA-17 | Descriptor | Split load_descriptor into four `_check_*` | L | unit/data/01, 09 |
| TO-10 | check | `@CHECKS` list drives every `_check_*` and `report_*` | M | t/tools/04, 36, 59; t/unit/tools/41; t/unit/lib/16; t/lint/39 |
| TO-1 | users | `%API_ACTION` / `%CLI_COMMAND` tables; handlers stay named `cmd_*` | M | t/unit/users/01, 02, 05, 08, 13, 20; t/unit/lib/16 |
| TO-17 | cli | One child-invocation style (list `system`) | M | t/tools/42, 41 |
| TO-22 | install | One of `set_conf_line`/`_set_conf_key`, one return convention; extend lint/25 | M | t/tools/03; t/lint/25 |
| TO-25 | install | `_ensure_declared_dir` for three walks; AFTER tools A1/A2 are filed | M | t/tools/34, 35, 36 |
| TO-30 | release | `gate_step` wrapper, one step per commit; last | M | t/tools/34, 45, 47, 51, 58 |
| TO-9 | users | Unify the five actor-confinement blocks; ONLY after tools NR-4 is decided | M | t/unit/users/08, 19, 23 |
| PL-9 | stats | `_promote_scanners`, `_reach_back`, `_tally_record` out of `_tally_batch` | M | unit/plugins/02, 12, 05 |
| PL-13 | stats | `_sum_window($days, $from)` for the twin 12-accumulator walks | M | unit/plugins/02, 08 |
| PL-8 | form-smtp | Split `validate_smtp` into five stages | M | unit/forms/05 |
| PL-18 | git-sync | `_prepare_remote($docroot, $user)` | M | unit/plugins/03 |
| PL-19 | git-sync | Split `do_pull`; reword the "before fetching" messages | M | NEW t/unit/plugins/31-a-pull-fast-forwards-and-combines.t; 03 |
| PL-20 | shape-B plugins, audit | `log_event` and `unlink_host_copies` onto `Lazysite::Util`; last, and only after plugins NR-1 is decided | M | unit/plugins/03; NEW assertion in PL-16's test |
| PL-17 (split) | audit | Split `write_audit_report` into four builders | L | NEW t/unit/plugins/30 |
| TO-15 | check | `report('ok')` lowercase at three sites (a one-word fix, batched here because t/unit/tools/40 changes with it) | L | t/unit/tools/40: add `[  ok  ]` to the ON-state assertion |

# Optimisations

Only rows the reports marked equivalence-clear (one-sentence argument; no output byte changes). Per-visitor rows are flagged; the rest run per manager action, per submission or per operator view.

| Ref | File | What | Per-visitor | Risk | Proving test |
|---|---|---|---|---|---|
| PO-1 | processor | Hoist `_private_twin` and the `%reserved` copy out of the resolve_scan loop | yes | L | unit/processor/03, 61; integration/39 |
| PO-2 | processor | `_site_vars_ref` for main's five call sites | yes | L | unit/processor/13, 43; integration/17 |
| PO-3 | processor | Memoise `_declared_content_roots` on conf mtime | yes | L | integration/17; unit/manager/33 |
| PO-4 | processor | Stat `acls.json` once per request | yes | L | lint/31; integration/06, 39; unit/processor/43 |
| PO-5 | processor | `_language_set` fed from the resolve_site_vars memo; pairs with PO-2 | yes | M | unit/processor/28; integration/17 |
| DAO-1 | Tables | One descriptor load per binding (`_read_rows_loaded`) beneath the SM476 die | yes | L | unit/data/24, 16; integration/62, 55 |
| DAO-2 | Tables | Memoise load_table on (path, mtime, size) with the one-second guard | yes | M | unit/data/09 + NEW: an edited descriptor is seen on the next load |
| DAO-3 | Tables | `count_sql` only when a total is wanted (`.field` mode skips it) | yes | L | unit/data/24, 17 |
| DAO-4 | Acl | Memoise load_acls on (path, mtime, size) | yes | M | unit/lib/04 + NEW: save then `_acl_allows` in one process sees the rule |
| DAO-5 | Tables | plan_rebuild preflight below the no-op check | no | L | unit/data/23 |
| DAO-6 | Settings | Memo `_groups_membership` on mtime | no | M | unit/users/18; lint/35 |
| PLO-1 | form-handler | Purge stale rate-limit hours once per hour | per submission | L | unit/forms/08 |
| PLO-2 | form-handler | One conf read per submission (PL-4) | per submission | L | as PL-4 |
| PLO-3 | stats | `_site_domain()` once per run | no | L | unit/plugins/19, 02 |
| PLO-4 | stats | `_visitor_token(_anon_ip($ip))` once per line | no | L | unit/plugins/10 |
| PLO-5 | stats | Pass `$is_asset` into `_apply_event` | no | L | unit/plugins/05 |
| PLO-6 | stats | `_basis_of` once per day in `_day_rollup` | no | L | unit/plugins/07 |
| MO-1 | manager-api | Memoise `_user_caps` per request (whoami forks the users tool three times) | no | L | unit/manager/29, 62, 24, 35; NEW t/unit/manager/99-one-settings-read-per-request.t |
| MO-2 | manager-api | Decode the body once (with MA-2) | no | L | unit/manager/19 |
| MO-3 | manager-api | `$IS_OPERATOR` read once after auth | no | L | unit/manager/16, 40, 51 |
| MO-4 | manager-api | Hoist `%skip`/`%uskip` to file scope (with MA-14) | no | L | unit/manager/19; lint/39 |
| MCO-1 | mcp | Hoist `%READ`, `%TRANSIENT` to file scope | no | L | unit/mcp/01, 03 |
| MCO-2 | mcp | `require Data::Tables` out of the per-binding loop | no | L | unit/mcp/10 |
| MCO-3 | mcp | One lazysite.conf slurp (MC-12) | no | L | as MC-12 |
| MCO-4 | mcp | `_delete_page` passes `$SEARCH_LIMIT_MAX` to `_mcp_search` | no | L | unit/mcp/01 |
| FDO-1 | dav | Memoise `caps_for($user)` per process (COPY/MOVE calls it up to eight times) | no | L | unit/dav/08, 12; unit/users/27 |
| FDO-2 | auth | One first-match pass over lazysite.conf per request | no | L | unit/auth/10; integration/14 |
| PCO-1 | Files | Hoist `private_root($DOCROOT)` out of the action_list loop | no | L | unit/manager/71, 14 |
| PCO-2 | Files | Read lock records only when `-d $LOCK_DIR` | no | L | unit/manager/08, 14 |
| PCO-3 | Files | `_invalidate_registries` accepts the root list | no | L | unit/manager/83, 55 |
| PCO-4 | Files | `action_protected_sections` resolves each key once | no | L | unit/manager/72, 91 |
| PCO-5 | Common | `validate_path` computes private_root once; ONLY inside a change already in the do-not-touch block | no | M | unit/manager/90, 67, 28 |
| TLO-1 | Plugins | Describe once in `action_plugin_enable`; never cache the registry | no | L | unit/manager/93, 62; unit/lib/07 |
| TLO-2 | Layouts | Two conf scans, not four, in `action_layout_install` | no | L | unit/lib/18; unit/manager/09 |
| TLO-3 | Themes | `domain_usage` returns the base pair | no | L | unit/manager/50 |
| TLO-4 | Themes | `_lz()` hoisted out of the per-layout loops | no | L | unit/manager/78, 06 |
| TLO-5 | Domains | Parse the slurped text in add/set/remove | no | L | unit/manager/32, 86 |
| BPO-1 | Backups | List the archive once per restore (BP-16) | no | L | unit/manager/22, 69 |
| BPO-2 | Git | Memoise `git_available()` keyed on `$ENV{PATH}` | no | L | unit/lib/15, 20 |
| BPO-3 | Data | One gate in `action_data_safety_export_restore` | no | L | unit/data/25 |
| BPO-4 | SitePackage | Pass `domains_list()` from `package_create` | no | L | unit/manager/35 |
| BPO-5 | Backups | Read the sidecar once; stat once per name in retention sort | no | L | unit/manager/60 |

# Do not touch

Line ranges whose SHAPE is the security property. A cleanup may move a comment with its code, never reorder a gate or merge two tests into one.

- lazysite-processor.pl: `lazysite_dir`/private-root derivations 85-96, 683-698 (lint/37, ADR 0001); the four bare blocks (`_peek_md`, `resolve_site_vars`, `_scan_identity`, `update_registries` - integration/15, lint/43); main's ordering comments (SM268, SM181, SM293); `$FORM_TS_PLACEHOLDER` BEGIN 37-42 (SM252); `_serve_content_static`, `_security_headers`, `_content_security_policy`, `_inline_script_hashes` (lint/55, 56; unit/processor/40-45); `resolve_db` identity block 4845-4857 (SM476).
- lazysite-manager-api.pl: trust gate 136-155 (lint/13, 38); the pipeline order OPTIONS to audit (SM230, SM268 H9, SM475, SM127, SM126, H4; lint/14, 21; unit/manager/43); acl-set field reads 1116-1131 (lint/58); every table above line 1022 (lint/39); `LAZYSITE_API_LOAD_ONLY` at 121; `sleep 1` on a bad token, 0660 chmods, `_rate_ok`'s shared bucket.
- lazysite-mcp.pl: `send_json`/`send_401` header stacks, `binmode STDOUT`, `utf8::decode` at 3449 (unit/mcp/01 mojibake contract); the five dispatch gates and their order (SM127, 126, 082, 268 H4, 155); `$out->{ok}` coercion and `retryable`/`hint` (lint/57); the tool table's textual shape and single-quoted descriptions (lint/23, 49, 52, 71); `validate_args` boolean rule (SM291) and the killswitch before any parse.
- lazysite-dav.pl: `authorise`/`authorise_layout` deny strings 1290-1425 (lint/68, 16); main's gate order 125-232 (SM071, SM163, P3.6); `resolve_under_docroot`, `sanitise_path`, `destination_rel`, `read_conf`'s nav_file check (SM286, SM443); do_put's shape, `_write_failure`, Retry-After rule (SM189, SM504; unit/dav/12; integration/41).
- lazysite-auth.pl: handle_login gate order, H7 self-exec guard 831-845, `sanitise_next`, `load_auth_secret` 0660, `update_user_hash` lock, trusted-header block 765-782 (lint/13, 38), the `--describe` block 35-62.
- lazysite-data.pl: identity block 112-149 (SM411, SM402), writable_by narrowing 192-224, binding grammar check 258-271, shared 404 wording 292-298 (SM476). All three CGIs: BEGIN bootstrap, `*_LOAD_ONLY`, `exit main() if !caller`, every `local $_` (SM420; lint/66).
- Manager/Common.pm: `validate_path` 96-252 in full (F1, SM510, H3, SM458, SM286; unit/manager/28, 42, 61, 63, 67, 90); `path_is_reserved` 55-83 (SM268 C2); carve-outs and `is_blocked_path` 313-372 (SM421, SM509); `carveout_requirement`/`carveout_refusal` 404-489 (SM268 H4, SM422); `write_file_checked` 508-536 and `_write_conf` 900-940 (lint/25; unit/manager/05, 47).
- Manager/Files.pm: `action_list` 132-171, 186-200 (tree first, H3, 04-F5); `action_acl_set` 1553-1571 (`save_acls` before the mover); `_sync_private_store` 1388-1469 returns warnings, never failure (SM313). Private.pm 32-35, 66-72, 119-166, 288-294, 367-448 (SM296, SM438, `_within` on realpaths, move guard order; lint/51).
- Manager/Plugins.pm `plugin_registry`/`resolve_plugin_script` 67-153 (SEC-2026-07 RCE boundary; unit/manager/27 - scan per call, key-only lookup); `_gate_execution` and the ungated `_run_plugin_hook` 134-143, 338-362 (ADR 0009). Manager/Themes.pm `_write_theme_tokens` 850-883 (lint/61 byte-pins it against `generate_theme_css`); the locked eval-release shape in both activates 519-590, 1108-1169. Manager/Domains.pm `_valid_host` and the SM436 pair 51-61, 247-274. Action sub names and `@EXPORT_OK` in all four (lint/15, 23).
- Manager/Backups.pm 548-575, 584-618, 708-736, 760-778 (SM381 child STDERR, tar verdict, SM268 C3 excludes, private-store pass); `_claim_name`, `write_sha256` 192-210, 58-90 (03-F9/F10). SitePackage `_extract_package` 441-476, clean guard 621-632, the `my ... if` note 327-330 (M-TAR). Upload `action_file_upload` 261-285 (SM418; unit/manager/63); `parse_multipart_body` (unit/manager/01 byte-pinned). Data.pm `_gate` 61-67 and the thin-wrapper rule (SM469; lint/77). Git.pm `@EXCLUDE` 143-159, `chmod 0664` lines, `file_log`'s walk (SM175).
- Data/Tables.pm: `read_rows` dies without `as` 139-141 (SM476); the "same answer as a missing table" branches 150-153, 388-391; `count_sql` before the limit and the single `MAX_ROWS` ceiling (SM502, SM511). Access.pm in full. Auth/Acl.pm `_acl_entry_for`/`_acl_allows` text (lint/36, 31). Auth/Settings.pm `read_settings` bare block 316-358 (unit/users/27). Capabilities.pm `%ACTION_INFO`, `@TASKS`, `@ENGINE_OWNED` 63-352 (lint/71, 76): prose edits only. Credential legacy `[0-9a-f]{64}` branch and the iteration cap. `Session::verify_session_cookie` payload split (unit/auth/14; lint/13).
- plugins/: form-handler and form-smtp stay module-free (SM425, SM136) - PL-2 dedupes the locator and must not become a `use lib`; the `next if $k =~ /^_/` loops (unit/forms/07 - PL-3 rewrites the test in the same commit); form-handler's dispatch order and the `$@` block 236-250 (SM216-2); stats `%BUILT_IN`, `$COUNTING_BASIS`, caps 500-503, SM330 `@CLASSES`, per-file byte offsets and the `final` marker; git-sync `_gate` and `_write_askpass` (lint/13, 77); the audit writer/reader pair (integration/73, unit/lib/16).
- tools/release.sh gate contract: VERSION/NEXT_VERSION stamped before every reader; compliance to GATE-LOG order; `prove | tee` under pipefail; COV_LOG beside the stage; the debian/control awk; no remote command outside publish; the literal `--no-fetch is still accepted and ignored` (t/tools/34, 45, 47, 51, 58). lazysite-users.pl audit registry 219-299, 3169-3189, `%STORE_READONLY`, `%ACTOR_FORBIDDEN`, `_reserved_username`, `_may_confer`/`_exceeds_authority` (unit/lib/16; unit/users/19, 20, 23, 30). lazysite-check.pl `$PROBE_DIR`/`$PROBE_KEY` at 36-37 and the END block (SM285; lint/39), `ACL PROBE SKIPPED:`, the local `@CAPS` copy (lint/81), `cgi_can` arithmetic. install.pl `lazysite_dir_for`, `_private_store_for`, `audit_append`, `write_backup_sha256`, the symlink/tar-extract bodies and the `--no-same-owner --no-same-permissions` literal (lint/37, 51; t/tools/36); every sub t/tools/34-36 extract by regex keeps ending on a bare `}` line. lazysite-cli.pl `$worst`/`exit $worst`, `_discover_hestia_sites`, refuse_root's strings (t/tools/42, 28).

# The 0.10.33 plan, and the freeze after it

Set by the operator 2026-08-25. **0.10.33 is the last cut that adds
features before beta.** After it lands, the only work that goes in is
SECURITY and FIXES TO THE FEATURES IN IT, until a beta is reached - so
anything not listed here waits, however small.

## In 0.10.33

| Tier | SMs |
|---|---|
| Security and silent failure | SM578 (confinement by the action; empty scope stops meaning unconfined), SM589 (`_script`/`_enabled` at the floor), SM577 (instance-wide backup store), SM581 (a nav-shaped file that reports success and does nothing), SM583 (two conf parsers disagreeing), SM582 (two DAV write paths nothing exercises) |
| Capability and roles | SM576 parts 1 and 3 only - `manage_briefs`, and roles from groups with the assignable flag |
| Mechanisms | SM573 (brief generated from the grant), SM574 (field practice shipped into the served briefings), SM580 (the sessions page names its principals), SM575 (two-principal ownership tests), SM590 (table delivery is handler-only, in writing) |
| Already landed for it | SM584, SM585, SM586, plus the nine cleanup branches |

## Held back deliberately

- **SM591** (lateral housekeeping tiers) - blocked on SM587's rule; a
  tier boundary drawn before the rule would be redrawn after it.
- **SM579** (API connectors) - a subsystem with an SSRF surface; it
  wants a cut of its own, not a ride on a large one.
- **The refused cleanup rows** - the batch-3 seams needing judgement,
  the two ladder-to-table conversions, and the cross-file folds that
  needed a file another agent owned.

## One pairing that is not optional

**SM569 and SM586 ship together.** Until SM586 lands, `public: false` is
refused, so a table receiving form submissions can only be a public one -
anonymously readable. SM586 is already in 0.10.33, so this holds provided
SM569 is not moved backwards.

# Method

- Defects first, test-first. Each defect row is its own SM; its proving test is written and seen to fail before the fix, on a `claude/<sm-slug>` branch off the integration branch. The nine `**` rows are cut before any beta publish (SM515 already is). Ordering constraints the reports set: path-core NR-6 before FD-6/PC-8; themes N-6 before TL-13; tools NR-4 before TO-9; plugins NR-1 before PL-20; mcp P1c-h before MC-8; tools A1/A2/A7 filed before TO-25.
- One `claude/<area>-tidy` branch per report per batch (`claude/processor-tidy`, `claude/manager-api-tidy`, `claude/mcp-tidy`, `claude/frontdoor-tidy`, `claude/path-core-tidy`, `claude/manager-tidy`, `claude/backups-package-tidy`, `claude/data-auth-tidy`, `claude/tools-tidy`, `claude/plugins-tidy`), one logical change per commit, landed through vcs-review; nothing merges to main here.
- Every row is sabotage-verified: the named proving test is run before the change, the change is made, the test is run again, and then the change is deliberately broken once to see the test fail. A row whose test does not fail under sabotage gets a better test before it lands.
- No behaviour change in a cleanup batch. If a cleanup row turns out to need one (PC-3's one-message sites, DA-23's chmod, TL-24's sort), the row stops and the difference is filed as a defect.
- Gate per batch as the reports state: batch 1 runs the owning suite and t/lint once at the end; batch 2 runs the named tests after each commit; batch 3 runs the full `t/run-all.t` per commit. `perltidy` per the tidy gate on every touched sub, wholesale on new files.
- The patch-anchor lesson: exact-string edit anchors break where perltidy reshapes hash literals (a `key => value,` list re-flowed to a different column, or a one-line hash spread over three). Anchor scripted edits on a unique marker line (a comment or a sub name), never on the interior of a hash literal, and verify the file after writing; the tool-table cleanups (MC-1, MC-8, MC-13) and the manager-api table moves (MA-14, MA-19) are where this bites.

# Message consistency (tools)

Same condition, different wording or channel across the five operator tools. One shared phrasing per row, not a shared module (install.pl and check.pl are core-Perl by design). Lands with batch 2 of the tools branch, one commit per row.

| Ref | Condition | Sites (from the report) |
|---|---|---|
| TOM-1 | unknown option / verb | users `Unknown command: X` exit 1; check `unknown option: X` exit 2; cli `unknown verb 'X'` exit 2; release `unknown flag: X` exit 2; install Getopt's own text exit 1 |
| TOM-2 | required argument missing | users `Error: --docroot is required` exit 1; install die exit 255; check exit 2; cli three phrasings; release `publish needs a version` |
| TOM-3 | program-name prefix and progress voice | `lazysite-check:` / `lazysite:` / `release.sh:` and `release:` / users `Error:` / install none; `==>` vs `== name` vs `[  ok  ]` vs `info` to STDERR |
| TOM-4 | needs root / refuses root | check two phrasings; cli two templates plus `needs root`; install has no root message at all |
| TOM-5 | thing not found | users `User 'x' not found` vs `Group 'x' not found` vs `group 'x' does not exist`; cli, install, release, check each their own |
| TOM-6 | required-argument phrasing within users; `die` vs `{ ok => 0 }` | `Username required` (20) / `username required` / `group required` / `Usage:` lines / `Creator (--by USERNAME) required`; the CLI prints only the die |
| TOM-7 | fleet exit semantics | cli "with findings" for any non-zero (tools NR-7); check 1 FAIL / 2 could not check; release 1/2/4/5; install 0/1/2/3/255; the finding-vs-failure split lives only in the Hestia updater |
| TOM-8 | same tar failure, two sentences | install `Restore extraction failed (tar rc=$rc)` vs `tar -x failed (rc=$rc)`, both printing the raw wait status |

# Task list, graded

Every filing SM515-SM575 and every defect row above, graded for complexity: S is one sub or one table edit plus a test; M is a few subs across one to three files, or a new action pair with the parity registries; L is a subsystem, a new tool, or a design decision before any code. Status is the filing's own header on 2026-08-25.

## Shipped this cut (0.10.32 edge)

| SM | Title | Status | Class | Complexity | Reason |
|---|---|---|---|---|---|
| SM515 | every MCP tool declares its gate | shipped | security-integrity | S | two table entries, one lint |
| SM517 | downloads honour the carve-out | shipped | security-confidentiality | S | two verbs on the surface map |
| SM518 | the rules move with the folder | shipped | security-confidentiality | M | move re-keys and syncs store |
| SM519 | no means no | shipped | security-confidentiality | S | one bool normaliser, one test |
| SM520 | a domain preview is anonymous | shipped | security-confidentiality | S | one shared env-stripping helper |
| SM567 | the ceiling control names what it governs | shipped | usability | S | relabel one row and message |
| SM570 | a channel is not an authority | shipped | security-integrity | M | three gates, registry, new lint |
| SM571 | the history summary walks once | shipped | operability | M | one-pass rewrite of lineage walk |

Totals: 8 shipped - 5 S, 3 M, 0 L.

## Security defects still open

| SM | Title | Status | Class | Complexity | Reason |
|---|---|---|---|---|---|
| SM521 | anonymous tools/call is a tool-name oracle | candidate | security-confidentiality | S | swap two statements, add assertion |
| SM522 | FRONT_MATTER_RESERVED is empty at request time | candidate | security-integrity | S | one accessor sub, widen lint |
| SM523 | a visitor cannot flag themselves | candidate | security-integrity | S | drop client underscore keys, test |
| SM524 | SMTP auth and TLS are what the conf says | candidate | security-integrity | S | reuse truthy, fix checked list |
| SM525 | whoami.tools echoes every tool name | candidate | security-confidentiality (low) | S | derive names from filtered list |
| SM565 | whoami tells a stranger the shape of the site | candidate | security-confidentiality | L | operator rules on disclosure first |

Totals: 6 open - 5 S, 0 M, 1 L; the four `**` rows (SM521-SM524) were recommended before any beta publish.

## Correctness and operability defects open, by area

| SM | Title | Status | Class | Complexity | Reason |
|---|---|---|---|---|---|
| **Manager path core** | | | | | |
| SM527 | a lock is keyed by the canonical path | candidate | correctness | M | seven lock sites, one key |
| SM528 | an alias on a gated page targets its public URL | candidate | correctness | S | alias rel from public path |
| SM529 | the site-wide reply does not claim content moved | candidate | correctness | S | root branch drops moved flag |
| SM530 | a mkdir into an unwritable parent returns a refusal | candidate | operability | S | eval around make_path, audit |
| SM555 | listing the engine tree logs once | candidate | operability | S | log once per listing call |
| SM556 | a symlinked docroot is one docroot | candidate | correctness | M | canonicalise once at two dispatchers |
| **Themes, layouts, domains** | | | | | |
| SM526 | one answer to is-this-address-public | candidate | correctness | S | delete one classifier twin |
| SM531 | a url page is a cache source | candidate | correctness | M | four cache walks agree on .url |
| SM532 | renaming the active theme keeps the site styled | candidate | operability | S | rename refuses like delete does |
| SM533 | a layout install cleans up after itself | candidate | operability | S | cleaner prefix matches install dir |
| **Front door (DAV)** | | | | | |
| SM534 | a DAV move reaches the registries | candidate | correctness | S | call invalidate in copy-move |
| SM535 | a collection delete cleans up | candidate | correctness | M | walk pages, registries, alias map |
| SM536 | a nav write reaches every cached page | candidate | correctness | M | nav mtime joins cache key |
| **MCP** | | | | | |
| SM537 | twenty-two tools carry the default annotation | candidate | correctness | M | annotate every entry, derive READ |
| SM538 | _each_page hard-skips docs and quotes | candidate | correctness | S | use path_is_reserved, one test |
| **Forms and plugins** | | | | | |
| SM539 | a multi-answer survives a multipart post | candidate | correctness | S | accumulate in multipart branch too |
| SM540 | a handler error is forwarded | candidate | operability | M | four plugins onto forward_line |
| SM541 | a promotion reverses the device | candidate | correctness | M | ring events carry device, term |
| SM542 | the page refresh keeps form outcomes | candidate | correctness | S | scan ingests form events too |
| SM543 | a recount uses the loaded ruleset | candidate | correctness | S | compile rules before recount dispatch |
| SM557 | a post writes no used-only-once warnings | candidate | operability | S | require before local, lint assertion |
| SM558 | the link audit sees the root page | candidate | correctness | S | bare index case in canonical |
| **Backups and site packages** | | | | | |
| SM544 | the safety snapshot covers what the restore overwrites | candidate | correctness | M | archive scope walks every member |
| SM545 | two site packages in one second are two files | candidate | correctness | S | carry O_EXCL claim across |
| SM546 | package_apply loads what it calls | candidate | operability | S | require Backups on that path |
| SM547 | site packages have retention | candidate | operability | S | package_create calls apply_retention |
| SM548 | the package upload budget is per user | candidate | operability | S | pass user and length correctly |
| SM559 | the walker returns its failures | candidate | correctness | M | walker returns list, caller labels |
| **Manager API audit** | | | | | |
| SM553 | the alias spelling keeps the audit target | candidate | operability | S | theme and layout target branch |
| SM554 | a posted read is not audited | candidate | operability | S | two names on the skip list |
| **Operator tools** | | | | | |
| SM549 | actor local is one actor | candidate | correctness | L | SM268 C1 ruling decides first |
| SM550 | the theme-mirror check never runs | candidate | operability | S | conf_value gets its file argument |
| SM551 | group reach is silent on a migrated site | candidate | correctness | S | build path through model_path |
| SM552 | the coverage verdict is dead under set -e | candidate | operability | S | scope set +e around coverage |
| SM560 | an abort keeps what it says it kept | candidate | operability | S | abort paths honour the retention |
| SM561 | the no-pages refusal cannot fire | candidate | operability | S | test emptiness before appending prefix |
| SM562 | a refusal is not a finding | candidate | operability | S | map exit 2 to could-not-check |

Totals: 36 open - 26 S, 9 M, 1 L; path core 6, themes 4, DAV 3, MCP 2, forms and plugins 7, backups 6, audit 2, tools 6.

## New capabilities and mechanisms (SM563-SM575)

| SM | Title | Status | Class | Complexity | Reason |
|---|---|---|---|---|---|
| SM563 | the four surfaces agree on every operation | candidate | security-integrity | L | DAV verb map needs a registry |
| SM564 | a group is judged by its reach | candidate | security-integrity | L | new group-reach report tool |
| SM566 | manage_data offers less over MCP than over the API | candidate | correctness | M | two MCP twins plus parity registries |
| SM568 | reads are weaker on one channel | candidate | correctness | S | two registry gates, one lint row |
| SM569 | a form can land in a data table | candidate | capability | L | new handler type across two plugins |
| SM572 | the engine describes its own side effects | candidate | operability | M | expose MUTATING on describe-capabilities, MCP |
| SM573 | the brief is checked against the grant | candidate | security-integrity | M | brief generator plus check warning |
| SM574 | the field practice ships with every site | candidate | capability | M | import script, starter doc, lint |
| SM575 | ownership is a pattern, or it is two cases | candidate | security-integrity | S / M | two-principal tests; M if ownership added |

Totals: 9 candidates - 2 S (one rising to M), 4 M, 3 L. SM516 itself stays the plan and register, ungraded.

## The cleanup batches

| Batch | Rows | Risk mix | Complexity | Reason |
|---|---|---|---|---|
| Batch 1: trivial, dead, dedupe | 90 | 90 L | S | one commit each, diff-visible equivalence |
| Batch 2: shared helpers within a file | 73 | 69 L, 4 M | M | helpers cross subs, named tests each |
| Batch 3: seams, splits, reorders, cross-file folds | 49 | 10 L, 39 M | L | splits and cross-file folds, full run-all |

Totals: 212 cleanup rows across the three batches - one S batch, one M batch, one L batch; every row a no-behaviour-change refactor with its proving test named. The 42 optimisation rows (M overall: memoisation with freshness tests) and the 8 message-consistency rows (S: one phrasing per row) sit outside the three batches and land with the tools branch and the per-area tidy branches.
