---
title: "SM079a - Action-handler decomposition plan"
subtitle: "Taking lazysite-manager-api.pl from a 3967-line script to a dispatcher over Manager::* modules"
brand: plain
---

::: widebox
The SM079 foundation is done (Util, Auth::{Credential,Settings,Acl,Session},
Manager::Common). This plans the remaining, largest piece: moving the ~2500
lines of action handlers into `Manager::{Upload,Plugins,Files,Layouts,Themes}`,
leaving `lazysite-manager-api.pl` as a ~700-line front-controller. The analysis
below shows the context-threading is bounded, so the work is a sequence of
disciplined, suite-guarded moves.
:::

## Current state

`lazysite-manager-api.pl`: 3967 lines, ~95 subs. The dispatch table already
passes per-request context to handlers explicitly (`action_read($path,
$auth_user)`, `action_theme_activate($path, \%params)`), so most handlers are
already half-decoupled.

## The context-threading surface (why this is tractable)

| Global | Refs | Nature | Handling |
|---|---:|---|---|
| `$DOCROOT` | 64 | **set once** | module package var, set once by dispatcher (as `Acl::DOCROOT` already is) |
| `$LAZYSITE_DIR` | 22 | set once | module package var |
| `$LOCK_DIR` | 6 | set once | Files package var |
| `$action` | 75 | dispatch + log ctx | dispatch stays; log ctx already in `Common::$action` |
| `$auth_user` | 61 | **passed as param** to handlers | keep passing; handlers use the param |
| `$token_auth`, `%token_caps`, `$manager_groups_conf` | 6/3/6 | auth state, **only** in `_is_operator` + `%need` gate | both **stay in the dispatcher** |

So the only real coupling is `_is_operator` (6 call sites) and `_acl_denied`
(3) - resolved by passing a computed `$is_operator` flag into the handlers that
need it, instead of calling the dispatcher-bound sub.

## What STAYS in lazysite-manager-api.pl (the front-controller, ~700 lines)

- Request setup: `$DOCROOT`/auth/`$auth_user`/`$token_auth`/`%params`/`$body`.
- The `%need` capability gate (255-268) and the `if/elsif` dispatch table.
- `_is_operator`, `_acl_denied` (auth-state glue), `_rate_ok`.
- `users_api` / `_users_tool_path` (the users-tool bridge).
- The small site handlers (initially): `whoami`, `version`, `audit`/`audit_log`,
  `config-set`/`_write_conf_key`, `rotate-auth-secret`, `nav-read`/`nav-save`,
  `artifact-*`, `preview-*`. (~400 lines; a `Manager::Site` module is optional
  later.)

## The five modules

```datatable
columns: Module | Subs (primary) | ~lines | Key deps
widths: 3cm | X | 1.6cm | 4.2cm
bold: 1
tone: medium
---
Manager::Upload | file-upload/download/zip, check_upload_rate, parse_multipart_body, sanitise_upload_filename, detect_content_type, is_editable_text, collect_zip_paths, %CONTENT_TYPE_MAP, %TEXT_EXTENSIONS | ~600 | Common (validate_path, is_blocked_upload_target, respond); self-contained tables
Manager::Plugins | plugin-list/enable/disable/read/save/action, _update_plugins_conf, resolve_plugin_script, handler-list/save/delete, _parse/_write_handlers_conf, form-targets-read/save | ~600 | Common (validate_path, is_blocked_*, write_file_checked, respond)
Manager::Files | list, read, save, delete, mkdir, cache-list/invalidate, locks (acquire/release/renew/_lock_record/_lock_fresh/_get_lock_info), acl-get/set/remove | ~500 | Common; _is_operator via passed flag; _invalidate_html_cache (hoist)
Manager::Layouts | layouts-releases/install(304)/release-contents(129)/available/themes-for-layout/repo-get/repo-set, _layouts_repo, _slurp_bytes, _cleanup_tmp_layouts | ~600 | Common; _read_active_layout_and_theme; _install_layout_from_dir
Manager::Themes | theme-list/themes-list-all/activate/delete/rename/upload, layout-activate, _set_theme/layout_pointer, _validate_theme/layout_dir, _snapshot_artifact, _prune_backups, _backup_retention, _read_active_layout_and_theme, _install_theme_from_dir, _theme_declares_layout, _invalidate_html_cache | ~900 | Common; most entangled (pointers, cache, snapshots) - LAST
```

### Shared helpers to hoist (decide home before moving)

- `_invalidate_html_cache` (2 sites: Themes + cache-invalidate) -> **Common**.
- `_read_active_layout_and_theme` (8 sites: Themes + Layouts + whoami) ->
  **Common** (a small active-pointer read).
- `_snapshot_artifact` / `_prune_backups` / `_backup_retention` (Themes-only) ->
  stay in **Themes**.

## Extraction order (lowest risk first)

1. **Upload** - most self-contained; proves the action-module pattern.
2. **Plugins** - config-file CRUD; no pointer/cache entanglement.
3. **Files** - CRUD + locks + ACL actions; introduces the `$is_operator`-flag
   refactor (small, localised).
4. **Layouts** - large handlers but mostly self-contained reads/installs.
5. **Themes** - most entangled (pointers, cache, snapshots); last, on top of a
   proven pattern.

After each, `manager-api.pl` shrinks visibly: Upload -600, Plugins -600,
Files -500, Layouts -600, Themes -900 -> dispatcher ~700.

## Per-module recipe (disciplined, suite-guarded)

1. Create `lib/Lazysite/Manager/<Name>.pm` with `our` context vars
   (`$DOCROOT`, `$LAZYSITE_DIR`, …) + `use` deps (Common, Util) + `@EXPORT_OK`.
2. Move the subs **verbatim** (one-liners removed by exact line, multi-line by
   block-strip; move shared helpers deliberately, not ad hoc).
3. Refactor any `_is_operator()` call in moved code to a passed `$is_operator`.
4. In the dispatcher: add `use` + import; set the module's stable context vars
   once (after `$DOCROOT` etc.); keep passing per-request params in the dispatch
   exactly as today.
5. `perl -c` the module (`-Ilib`) and the script; run the module's focused
   tests; **run the FULL suite**; add an in-process unit test; perlcritic the
   module; **verify the test passes before committing**; commit.

## Risks and mitigations

- **Context mistakes** - verbatim moves + package-var context; the full suite is
  the ratchet, run *before* every commit (lesson from the step-3b test slip,
  where a missing import was hidden by an in-memory STDERR capture).
- **`_is_operator` coupling** - explicit `$is_operator` param; 6 sites, localised.
- **Hidden runtime errors passing `perl -c`** - confirm every called sub is
  imported/defined; perlcritic + full suite catch the rest.
- **Big handlers** (layouts-install 304, release-contents 129, file-zip 101) -
  move verbatim; size is fine inside a module.

## End state

`lazysite-manager-api.pl` ~700 lines (gate + dispatch + auth + glue); 11
`Lazysite::*` modules; each Manager module unit-tested in-process, so manager
coverage is measured per-module and climbs toward the 75% target - closing the
D2 work too. The processor remains a standalone single file throughout.

## Done (2026-06-24)

All five modules extracted (Upload, Plugins, Files, Themes - the last combining
layouts + the artifact-manifest chain, since themes/layouts are deeply coupled).
`lazysite-manager-api.pl`: **4286 -> 1238 lines** (-71%), now a front-controller
(request setup + %need gate + dispatch table + auth + the small site handlers:
whoami/users/audit/version/nav/config-set/rotate/preview). 10 `Lazysite::*`
modules; the processor stayed a standalone single file throughout; suite 1342
green at every commit; all modules perlcritic-clean. The full-suite-before-commit
discipline caught several missing-import slips (subs the dispatcher called
directly, not only via handlers) before they landed.

Remaining polish (optional): `Manager::Themes` is 1414 lines - a cohesive
theming subsystem, but could be split into Themes / Layouts / Artifact later.
Re-run `tools/coverage.sh` to capture the new per-module coverage (the logic is
now in-process-testable) and raise the floor toward 75%.
