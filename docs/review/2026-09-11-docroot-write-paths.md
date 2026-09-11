# Docroot-built write paths against the private store (SM836 review, SM852)

Read-only survey of `lib/**/*.pm`, `tools/*.pl`, `plugins/*.pl` and `lazysite-*.pl`, taken 2026-09-11 from the working tree. Read-only; the S1 and S7 fixes that followed it are recorded in SM852. Every row is a path built from the docroot (`"$DOCROOT/…"`, `"$docroot/…"`, `"$d/…"`, `_docroot(...) . '/…'`, `"$_[0]/lazysite/…"`, a walk rooted at `$DOCROOT`, or `tar`/`git` run with the docroot as their write target) that is then written: open for writing, sysopen, rename, unlink, make_path/mkdir, copy, `rm -rf`/`cp -r`, tar extract, git merge, or a helper that does one of these. I left out pure reads, `-e`/`-f` tests, displayed paths, and chmod/chown-only mode fixes. Closely related lines in one sub share a row. The count comes out well above the lint's "twenty-nine" (t/lint/128:15), mainly because the engine-tree builds are listed one by one.

Classes:

- **OK-ENGINE**: the target is engine or infra territory and can never be a content path.
- **OK-RESOLVED**: the target is content, and the path goes through `Lazysite::Private` or an equivalent.
- **SUSPECT**: the write can put bytes for a protected section into the served docroot.
- **MISS**: a fourth label, used twice. The write resolves nothing, but it can only miss the private copy (a delete or rewrite that never finds it). It cannot create a public copy.

`(reloc)` marks a hard-coded `<docroot>/lazysite/...` path that ignores `Lazysite::Paths::lazysite_dir`. On a migrated site that write recreates a `lazysite/` tree inside the docroot, or does nothing if the parent is missing. Details are under Other findings.

**Why a stray directory matters as much as a stray file.** `Private::resolve_for_write` (Private.pm:153-165) decides that a new path is public as soon as any ancestor exists in the docroot. Protecting a folder works because the folder is moved out, so it no longer exists in the docroot. Any write that `make_path`s a public directory at a protected path therefore does two things. It exposes the file it writes. It also sends every later new file under that folder to the public tree, through the correctly resolved surfaces (manager, MCP, DAV) too. Every SUSPECT row that creates directories has this second effect.

| # | file:line | sub | writes | can be content? | resolves? | class |
|---|---|---|---|---|---|---|
| 1 | lib/Lazysite/Private.pm:410, 462 | move_in / move_out | the mover's own rename/copy/unlink between docroot and store | yes | is the resolver | OK-RESOLVED |
| 2 | lib/Lazysite/Util.pm:373/384, 402-403, 413-416 | unlink_host_copies / unlink_host_page / clear_host_cache | unlink per-host render cache under `lazysite/cache/hosts` | derived cache | n/a | OK-ENGINE (reloc) |
| 3 | lib/Lazysite/Aliases.pm:49-51 → 356-373 | alias_map_path / _update | alias map JSON | no | n/a | OK-ENGINE (reloc: no-op, `-d "$docroot/lazysite"` guard) |
| 4 | lib/Lazysite/Notify.pm:196 | notify | bell-store append in `lazysite/logs` | no | n/a | OK-ENGINE (reloc: `-d` guard, no-op) |
| 5 | lib/Lazysite/BadUrl.pm:73-74, 182-194 | record_and_check / _locked_rmw | bad-URL counters and lock in `lazysite/cache` | no | n/a | OK-ENGINE |
| 6 | lib/Lazysite/Handlers.pm:186 → 1042-1043, 1061-1062, 1084-1091 | store_path → _to_file / _save_uploads | form submissions `.jsonl` and visitor uploads under a file handler's `path` | **yes**: any non-reserved site folder | no | **SUSPECT** |
| 7 | lib/Lazysite/Data/Connect.pm:43 → 54 | store_path / ensure_store | SQLite store directory `lazysite/db` | no | n/a | OK-ENGINE (reloc: make_path) |
| 8 | lib/Lazysite/Data/Tables.pm:527 → 530, 540 | _safety_export | table safety-export JSON in `lazysite/db/rebuilds` | no | n/a | OK-ENGINE (reloc: make_path) |
| 9 | lib/Lazysite/Daemon/Supervisor.pm:127 → 140 (+768, 788) | _state_dir / _ensure_state_dir | daemon pid/state files in `lazysite/daemon` | no | n/a | OK-ENGINE (reloc: make_path) |
| 10 | lib/Lazysite/Daemon/Jobs.pm:195 → 215-220 | _write_schedule_runs | `lazysite/daemon/schedule-runs.json` | no | n/a | OK-ENGINE (reloc: make_path) |
| 11 | lib/Lazysite/Daemon/Service/Scheduler.pm:206 → 274-277 | _write_runs | `lazysite/daemon/scheduler-runs.json` | no | n/a | OK-ENGINE (reloc) |
| 12 | lib/Lazysite/Manager/Common.pm:119 (+231) | validate_path | `full` for every manager file write: save, save-binary, delete, mkdir, move, copy, migrate-to-local, git-restore, and through them MCP write_file/create_page/rename_page and control-API file verbs | yes | yes, resolve_for_write at :249 | OK-RESOLVED |
| 13 | lib/Lazysite/Manager/Upload.pm:236 | action_file_upload | multipart upload target | yes | yes, write_root + validate_path | OK-RESOLVED |
| 14 | lib/Lazysite/Manager/Files.pm:1377-1386 | _invalidate_all_html | unlink every `*.html` under a walk of `$DOCROOT` (nav save) | derived cache (and see Other findings) | no | OK-ENGINE for this question: gated pages are never cached (processor 2650, 2719-2722, 3495) |
| 15 | lib/Lazysite/Manager/Files.pm:1863 | _sync_private_store | unlink the pre-gate public `.html` render after move_in | derived | yes, runs after Private::move_in and deliberately targets the public copy | OK-RESOLVED |
| 16 | lib/Lazysite/Manager/Nav.pm:75 → 309-310 | _nav_conf_info → action_nav_save | nav file at `"$DOCROOT/<nav_file>"` (default `lazysite/nav.conf`) | operator-configured path; can sit under a content root | no | OK-ENGINE (reloc: see Other findings) |
| 17 | lib/Lazysite/Manager/Plugins.pm:751 → 757-758 | action_plugin_save | a plugin's config file (every shipped `config_file` is `lazysite/*.conf`) | no | n/a | OK-ENGINE (reloc) |
| 18 | lib/Lazysite/Manager/Plugins.pm:1007 → 1083-1087 | _submissions_path → _rewrite_store | rewrite of an existing submissions `.jsonl` found through Handlers::store_path | yes (same `path` as #6) | no | MISS |
| 19 | lib/Lazysite/Manager/Themes.pm:1029 → 1058-1071 | _mirror_theme_assets | docroot `lazysite-assets/<layout>/<theme>` mirror (stage + swap) | no; resolve_for_write forces this tree public (Private.pm:133) | n/a | OK-ENGINE |
| 20 | lib/Lazysite/Manager/Themes.pm:1116 → 1121-1122 | _mirror_theme_assets | per-content-root mirror `"$DOCROOT/$cr/lazysite-assets/…"`, make_path + `cp -r` | mirror bytes are not content, but make_path creates the content-root ancestors | no | **SUSPECT** (edge) |
| 21 | lib/Lazysite/Manager/Themes.pm:1575-1577 | action_theme_delete | `rm -rf` of the theme's asset mirror | no | n/a | OK-ENGINE |
| 22 | lib/Lazysite/Manager/Themes.pm:1628-1630 | action_theme_rename | rename of the asset mirror directory | no | n/a | OK-ENGINE |
| 23 | lib/Lazysite/Manager/Themes.pm:1699-1702 | action_theme_copy | `cp -r` of the asset mirror | no | n/a | OK-ENGINE |
| 24 | lib/Lazysite/Manager/Themes.pm:1905-1918 | _install_theme_from_dir | asset mirror stage + swap | no | n/a | OK-ENGINE |
| 25 | lib/Lazysite/Manager/Themes.pm:2143 → 2239 | action_cache_invalidate | unlink `"$DOCROOT$rel".html`, plus the `'*'` walk at 2099-2111 | derived cache | no | OK-ENGINE (gated pages are uncached, as #14) |
| 26 | lib/Lazysite/Manager/Layouts.pm:607-609 | action_layout_delete | `rm -rf` of `lazysite-assets/<layout>` | no | n/a | OK-ENGINE |
| 27 | lib/Lazysite/Manager/Layouts.pm:643 → 657 | action_artifact_backups_delete | `rm -rf` of one layout backup, found by `realpath("$DOCROOT/$rel")` | no | n/a | OK-ENGINE (reloc: refuses on a migrated site) |
| 28 | lib/Lazysite/Manager/SitePackage.pm:652 → 662, 665, 669, 801 | package_apply | package content copied into `"$DOCROOT/<content_root>"`, optional `remove_tree` clean, `nav.conf` | **yes** | no | **SUSPECT** |
| 29 | lib/Lazysite/Manager/Domains.pm:934 → 936, 942 | domain_add | make_path of the new domain's content root, plus a seeded `index.md` | **yes**: operator-supplied content_root | no | **SUSPECT** |
| 30 | lib/Lazysite/Manager/Domains.pm:1147 → 1154 | domain_remove (purge) | `remove_tree` of `"$DOCROOT/<content_root>"` | yes | no | MISS |
| 31 | lib/Lazysite/Manager/Briefs.pm:47-51 | store_entry_move | rename of a brief store entry `lazysite/briefs/<rel>` | engine store keyed by a content rel | n/a | OK-ENGINE (reloc: returns early) |
| 32 | lib/Lazysite/Manager/Briefs.pm:63-65 | store_entry_remove | unlink / remove_tree of a brief entry | engine store | n/a | OK-ENGINE (reloc: no-op) |
| 33 | lib/Lazysite/Manager/Briefs.pm:72 → 174-179, 330-337 | _store_path → action_brief_append / action_briefs_migrate | brief entry append/write | engine store | n/a | OK-ENGINE (reloc: make_path creates `<docroot>/lazysite/briefs`) |
| 34 | lib/Lazysite/Manager/Data.pm:1014 → 1063 | _export_path → safety-export delete | unlink `lazysite/db/rebuilds/<file>` | no | n/a | OK-ENGINE (reloc) |
| 35 | lib/Lazysite/Manager/Backups.pm:810-838 | action_backup_restore | `tar xzf … -C $DOCROOT`: the content members of a backup | **yes** | only for members named `*-lazysite-private` (863-885); docroot members are not redirected | **SUSPECT** (not a string build) |
| 36 | lib/Lazysite/Manager/Backups.pm:891-899 | action_backup_restore | unlink `.html` render caches in a walk of the docroot | derived cache | n/a | OK-ENGINE |
| 37 | lazysite-processor.pl:2430, 2445 | main | page render cache `html_path` | derived | yes, `_private_twin` / `_content_abs` | OK-RESOLVED |
| 38 | lazysite-processor.pl:1362, 1502, 8748 | serve_403 / serve_402 / not_found | `"$croot/40x.html"` system-page renders (process_md, _rewrite_if_changed) | fixed engine names | n/a | OK-ENGINE |
| 39 | lazysite-processor.pl:7314 → 7315-7332 | fetch_remote_layout | remote theme files into `lazysite-assets/<cache_key>` | no | n/a | OK-ENGINE |
| 40 | lazysite-dav.pl:1718, 1725 | resolve_under_docroot | every DAV PUT / MKCOL / DELETE / COPY / MOVE / LOCK target | yes | yes, Private::write_root | OK-RESOLVED |
| 41 | lazysite-dav.pl:809 | do_delete | invalidate_cache (unlink `.html`) for each page md_rels lists | derived | the resolved twin is handled at :793; md_rels walks only the public tree, so this spelling matches its source | OK-RESOLVED |
| 42 | lazysite-dav.pl:891 | _sync_acl_store | unlink the pre-gate public render after move_in | derived | yes, same shape as #15 | OK-RESOLVED |
| 43 | lazysite-data.pl:141, 220 → lib/Lazysite/Auth/Session.pm:118-126 | main → _csrf_secret | `local` engine dirs `"$docroot/lazysite"` handed to Session/Settings; Session can mint `manager/.csrf-secret` | no | n/a | OK-ENGINE (reloc; probably unreachable because verification fails first, not verified) |
| 44 | tools/lazysite-bundle-apply.pl:91 → 103-106 | (file scope) | each bundle file to `"$docroot/$p"`, make_path + open `>` | **yes** | no | **SUSPECT** |
| 45 | tools/lazysite-server.pl:293-311 | (file scope, dev-server seed) | copies into `manager/assets` | no | n/a | OK-ENGINE |
| 46 | tools/lazysite-check.pl:1861 → 1285 | (check) → apply_fixes | moves pre-SM293 registry files out of the docroot root into `lazysite/backups` | engine-generated names | n/a | OK-ENGINE |
| 47 | tools/lazysite-check.pl:2676-2702, 2348-2356, 2379-2388 | run_acl_probe / _acl_probe_cleanup / _acl_probe_sweep | the tool's own `lazysite-acl-probe-*` directory and controls | tool-owned names | n/a | OK-ENGINE |
| 48 | plugins/audit.pl:178-188, 191-196, 306 | run_scan / write_audit_report | `manager/audit-report.md`, its cache, host copies | no | n/a | OK-ENGINE (reloc for the host-copy path) |
| 49 | plugins/form-handler.pl:419-425 | _record_form_event | `lazysite/stats/form-events/<day>.jsonl` | no | n/a | OK-ENGINE (reloc: make_path) |
| 50 | plugins/form-handler.pl:439, 484 | _notify_submission | `lazysite/logs/notices.jsonl` | no | n/a | OK-ENGINE (`-d` guard) |
| 51 | plugins/payment-demo.pl:41-42 → 146, 165 | load_secret | demo auth secret in `lazysite/auth` | no | n/a | OK-ENGINE (reloc: make_path + secret written inside the docroot) |
| 52 | plugins/git-sync.pl:250-252 | _write_askpass | transient askpass helper in `lazysite/git` | no | n/a | OK-ENGINE (reloc: sysopen fails, no create) |
| 53 | plugins/git-sync.pl:410 → Manager/Backups.pm:477, 534, 651 | _snapshot → action_backup_create | pre-pull safety tarball, **which includes the private store**, to `"$docroot/lazysite/backups"` | the payload is protected content | no (reloc) | **SUSPECT** (migrated sites) |
| 54 | plugins/git-sync.pl:608, 646 | do_pull | `git merge` into the docroot worktree | **yes** | no | **SUSPECT** (not a string build) |
| 55 | plugins/git-sync.pl:429-437 | _after_apply | unlink `.html` caches in a walk of the docroot | derived cache | n/a | OK-ENGINE |
| 56 | plugins/pandoc.pl:399-401 | convert | scratch directory `lazysite/cache/pandoc-*` | no | n/a | OK-ENGINE (reloc) |
| 57 | plugins/pandoc.pl:284 → 515-516 | _cache_path → convert | cached PDF `"$docroot/lazysite/cache/pdf/<flat>.pdf"` | derived from content, **including gated parts** | no (reloc) | **SUSPECT** (migrated sites) |
| 58 | plugins/pandoc.pl:570-580 | plugin_init | `lazysite/brands` directory + README | no | n/a | OK-ENGINE (reloc) |
| 59 | plugins/pandoc.pl:637-646 | plugin_clear | unlink cached PDFs | no | n/a | OK-ENGINE |
| 60 | plugins/stats.pl:1279, 1324, 1341, 2148 → 1375-1379, 1603, 2235, 2279, 2609-2623 | _save_export_cache / _persist_durable / _trails_flush / … | stats stores under `lazysite/cache` and `lazysite/stats` | no | n/a | OK-ENGINE (reloc; `-d` guard or plain mkdir, so no create) |

## SUSPECT details

### S1: lib/Lazysite/Handlers.pm:186 (row 6), form submissions into a gated folder

**Surface.** A form bound to a `file` handler: Forms page, MCP `bind_form`, control-API handler-save, or `lazysite-handlers.pl`. The write itself is the anonymous visitor's POST to form-handler.pl.

**Input.** The handler's `path`. `_check_path` (510-521) only refuses reserved areas, and the schema note (96-99) invites "the site's own tree".

**Scenario.** A sysop sets `path: members/submissions`, then puts a read ACL on `members/`. The section moves to `<docroot>-lazysite-private/members`. On the next submission:

```perl
# Handlers.pm:182-186
    if ( $r =~ m{\Alazysite(?:/(.*))?\z} ) {
        my $lz = _lz() // "$DOCROOT/lazysite";
        return defined $1 && length $1 ? "$lz/$1" : $lz;
    }
    return "$DOCROOT/$r";
# Handlers.pm:1042-1043, 1061-1062
    my $dir = store_path( $h->{path} );
    eval { make_path($dir) unless -d $dir; 1 }
    my $path = "$dir/$name.jsonl";
    open my $fh, '>>:utf8', $path or return { ok => 0, why => "cannot open the store: $!" };
```

`make_path` recreates a public `members/` and `members/submissions/`. The JSONL and any uploads (`_save_uploads` 1084-1091) land in the served tree. The directory flip described in the header then applies. The readers use the same resolver (Plugins.pm:895 and :1007), so the manager shows the public store and nothing reports a stray.

**Aside, independent of ACLs (front-end dependent, not verified).** A site-tree store publishes submissions and uploads on its own. With `upload_accept` empty any type is accepted (form-handler.pl:262-276), and `_safe_filename` keeps the extension.

### S2: lib/Lazysite/Manager/SitePackage.pm:652 (row 28), site-package apply

**Surface.** Manager site-package apply, MCP `site_apply`, control API, and `tools/lazysite-site.pl` apply. All go through apply_and_configure → package_apply.

**Scenario.** A domain has content root `sites/acme`, and `sites/acme/members/` is protected. The package being applied carries `content/members/*.md`. That happens when it was built on another instance, or on this site before `members/` was protected: package_create omits only what is in the store at build time (373-374).

```perl
# SitePackage.pm:652, 665, 669
    my $target = "$DOCROOT/$croot";
    make_path($target) unless -d $target;
    push @copy_failed, map { 'content/' . $_ } _copy_tree( "$stage/content", $target )
# _copy_tree:143, 162-163
                my $target = length $rel ? "$dst/$rel" : $dst;
                    make_path( dirname($target) );
                    copy( $p, $target )
```

The result is public copies beside the private ones (`stray_public`). The front end serves the public copies. The engine prefers private, so nothing looks wrong. `clean => 1` (653-663) removes only the public tree. If the whole content root is protected, `make_path($target)` recreates it and every file lands public. Line 801 also copies `nav.conf` into the same target.

### S3: lib/Lazysite/Manager/Domains.pm:934 (row 29), domain_add with seed

**Surface.** Manager or control-API domain-add, and `tools/lazysite-domains.pl` add.

**Scenario.** `members/` is protected. An operator adds `members.example.com` with content root `members` (or `members/portal`) and `seed => 1`:

```perl
# Domains.pm:934-946
    my $dir = "$DOCROOT/$rel";
    unless ( -d $dir ) {
        eval { make_path($dir); 1 }
    ...
    if ( $opts{seed} && !-e "$dir/index.md" ) {
        if ( open my $sf, '>:utf8', "$dir/index.md" ) {
```

`-d` is false because the folder lives in the store. So instead of "adopting an existing tree" (the comment at 932-933), this creates an empty public `members/` and a public seeded `index.md`. After that:

- New files under `members/` resolve public (the directory flip).
- `confine_content_root` (processor 3165-3166) finds the public folder, so the domain serves the seed page instead of the protected content.

### S4: lib/Lazysite/Manager/Backups.pm:810-838 (row 35), restore of a pre-protection backup

This is not a `"$DOCROOT/$rel"` string build, but it is the same failure.

**Surface.** Manager Backups restore, and control-API `backup-restore` (ControlApi/Actions.pm:92).

**Scenario.** A content backup is taken while `members/` is public. `members/` is protected later. The ACL lives in `lazysite/auth/acls.json`, which the restore excludes, so it survives. On restore:

```perl
# Backups.pm:810-811
    my $rc = system(
        'tar',             'xzf', $full, '-C', $DOCROOT,
```

The first pass extracts `./members/*` into the docroot. The store pass (863-885) runs only for archives carrying a `*-lazysite-private` member, and nothing re-syncs the store after the restore (888-917 call no `_sync_private_store`). The result: `members/` exists in both trees, the rule still reads as applied, the engine serves the private copy, and the front end serves the restored public copy.

### S5: tools/lazysite-bundle-apply.pl:91 (row 44), offline bundle

**Surface.** An operator applying an agent's offline bundle from the CLI.

**Scenario.** The bundle contains `members/handbook.md`. The deny list (59-69) covers only `lazysite/…`, `cgi-bin`, `manager` and `*.pl`, and there is no ACL or store check:

```perl
    my $abs = "$docroot/$p";
    my $op  = ( -e $abs ) ? 'overwrite' : 'create';
...
        make_path( dirname( $f->{abs} ) );
        open my $out, '>', $f->{abs} or die "write $f->{path}: $!\n";
```

The dry run reports `create`, because the existing page is in the store. `--apply` then writes a public copy and a public `members/` (the directory flip). The existing private copy is untouched, so the front end serves the new public one.

### S6: plugins/git-sync.pl:608, 646 (row 54), pull merges into a gated folder

This is not a string build either: the worktree is the docroot, and `git merge` writes into it.

**Surface.** The git-sync plugin's Pull.

**Scenario.** A commit on the remote adds a file under a protected folder, for example `members/new.md` from someone editing the repo. Then:

```perl
# git-sync.pl:607-608, 646-648
        my ( $aok, undef, $aerr ) =
            _run_git_capture( $docroot, 'merge', '--ff-only', 'FETCH_HEAD' );
    my ( $cok, undef, $cerr ) = _run_git_capture( $docroot, 'merge', '--no-edit',
        '-X', $strategy, '-m', "apply changes from the remote copy ($label)",
        'FETCH_HEAD' );
```

git creates `$DOCROOT/members/new.md` and a public `members/` (the directory flip). `_after_apply` (425-457) clears caches and reindexes aliases, but never re-syncs the store.

**Not sure.** `_prepare_remote` runs `_capture_worktree` first (503), which commits the gated files as deleted. A remote modification of an existing gated file may therefore become a modify/delete conflict that aborts (650). The add case is unaffected by that.

### S7: plugins/git-sync.pl:410 (row 53), pre-pull snapshot lands inside the docroot on a migrated site

**Surface.** Every git-sync pull that applies (604 and 639).

**Scenario.** The site is migrated, so its engine tree lives at `<docroot>-lazysite`.

```perl
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$docroot/lazysite";
    my $r = eval { Lazysite::Manager::Backups::action_backup_create('prerestore') };
```

`_dir()` becomes `<docroot>/lazysite/backups`, which make_path creates inside the docroot (Backups.pm:534). The unscoped tar (612-617, 651) appends the private store (`@store`). Every protected section therefore ends up in `<docroot>/lazysite/backups/lazysite-prerestore-<stamp>.tar.gz`, in the served tree, and is reachable unless the front end still denies `/lazysite/`. This is the exact case Paths.pm:13-17 cites. On an unmigrated site the path is the real engine tree, and the exposure is the known SM293 class rather than this one.

### S8: plugins/pandoc.pl:284, 515-516 (row 57), PDF cache of gated parts on a migrated site

**Surface.** Branded PDF conversion. The manager passes `docroot => $DOCROOT` (lazysite-manager-api.pl, about line 3524).

**Scenario.** The site is migrated. An authorised reader converts a public page whose `parts` include a gated page. That is allowed after SM738 (340-375).

```perl
    return "$docroot/lazysite/cache/pdf/$flat.pdf";          # 284
    File::Path::make_path("$docroot/lazysite/cache/pdf");    # 515
    if ( File::Copy::copy( $pdf, $cached ) ) {               # 516
```

The PDF, containing the gated part's text, is written inside the docroot at a name predictable from the page path. On an unmigrated site the same file sits in the engine tree, protected only by the deny rule (the SM293 class). Other readers are refused before the cache hit (368 comes before 395), so the engine does not serve the file to the wrong person. Only a front end that serves the docroot directly would.

### S9: lib/Lazysite/Manager/Themes.pm:1116 (row 20), per-content-root mirror recreates a gated content root (edge)

**Surface.** Theme or layout activation, and site-package apply (SitePackage.pm:792).

**Scenario.** A whole content root is protected, for example a folder ACL on `sites/acme/`. Then:

```perl
        my $cdest = "$DOCROOT/$cr/lazysite-assets/$layout/$theme";
            make_path( dirname($cdest) ) unless -d dirname($cdest);
            my $crc = system( 'cp', '-r', $dest, $cstage );
```

This recreates a public `sites/acme/`. `confine_content_root` then succeeds against it, and new pages under `sites/acme/` resolve public. No content bytes are exposed by this row alone, but it breaks the invariant the resolver relies on.

**Not sure** whether a fully gated content root is a supported configuration. The processor already falls back to the docroot root when the content-root directory is missing (3165-3166, 2405-2414), so such a domain is degraded before this write happens.

## Other findings (not the SM418 shape)

**MISS rows.**

- **Row 18.** Once the store folder is gated, `_rewrite_store`, and the reader `action_form_submissions`, find nothing: "No such submissions store" or an empty table.
- **Row 30.** A purge removes only the public half of a content root and reports `purged: 1`. Gated sub-sections stay in the private store, orphaned, with nothing listing them.

**Relocation-blind engine writes** (every `(reloc)` row). These write `<docroot>/lazysite/...` instead of `lazysite_dir`. Where they `make_path`, a migrated site gets a stray `lazysite/` tree inside the docroot, which `Paths::stray_lazysite` then reports as a half-migration. The worst cases:

- The demo payment secret (row 51).
- Brief text (row 33).
- The data store directory (rows 7-8).
- Form-event stats (row 49).
- Nav save (row 16): with no `nav_file` set, it writes `"$DOCROOT/lazysite/nav.conf"`, while the processor reads `"$LAZYSITE_DIR/nav.conf"` (processor 5752-5756). On a migrated site a nav save lands in the stray tree and the live nav does not change. From reading; not reproduced.
- Util host-cache unlinks (row 2): they use `"$docroot/lazysite/cache/hosts"`, but the processor writes host copies under `"$LAZYSITE_DIR/cache/hosts"` (processor 185-189). Alias-host renders are therefore not invalidated after edits on a migrated site.

**Seen while reading.** From source, not reproduced:

1. **Files.pm:1375-1386** `_invalidate_all_html` unlinks every `.html` under the docroot on a nav save. It lacks the `_cache_source_exists` guard that Themes.pm:848 and :2110 have, so legacy static pages and author `.html` partials (SM133 / SM072) are deleted.
2. **lazysite-mcp.pl:3214-3215** `create_page` checks existence with `-e "$DOCROOT/$slug.md"`. For a gated page it proceeds to action_save, which resolves to the existing private file and overwrites it. The "use write_file to overwrite" refusal never fires.
3. **lazysite-dav.pl:713** derives the alias key by stripping `$DOCROOT` from the resolved abs. For a gated page it indexes the absolute private-store path. This is the SM528 fault that Files.pm:714-718 and DAV DELETE (797-803) already fixed.
4. **lazysite-mcp.pl:2926** (audit) reports every ACL key whose content moved to the store as "protects nothing".
5. **pandoc.pl:313-314** refuses a gated primary page as "no such page" before the resolver at 331. Line 394 computes staleness from public paths, so an edit to a gated part does not invalidate its cached PDF.
6. **lazysite-check.pl:2364-2389** `_acl_probe_sweep` removes public probe leftovers and the ACL key, but not a private-store copy left by an interrupted run.

**Could not determine.**

- Whether a fully gated content root is intended to work (S9, and part of S3).
- How often S6's capture commit turns the modify case into an aborting conflict.
- Whether lazysite-data.pl's `_csrf_secret` mint (row 43) is reachable on a migrated site.

## Summary

The survey found 60 docroot-built write sites. **41 are OK-ENGINE**, 23 of them relocation-blind. **8 are OK-RESOLVED**: validate_path, Upload, the two stale-render unlinks, DAV's resolver and delete-cache, the processor page cache, and Private itself. **2 are MISS**: submission-store rewrite and domain purge. **9 are SUSPECT**. Five are direct content writes that never consult Lazysite::Private: Handlers::store_path, package_apply, domain_add, backup restore (`tar -C $DOCROOT`) and lazysite-bundle-apply. One is content through git: git-sync pull. Two are relocation-blind engine writes that carry protected bytes into the docroot on migrated sites: git-sync's pre-pull snapshot and the pandoc PDF cache. One is an edge case: the per-content-root theme mirror. The three central manager, MCP and DAV write paths all resolve correctly. The suspects are the bulk paths (package, restore, bundle, git) and the operator-configured paths (handler store, content root). Every suspect that creates directories also flips `resolve_for_write` to public for all later writes under the gated folder, so the correctly resolved surfaces follow them into the public tree.
