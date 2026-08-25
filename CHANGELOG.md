---
title: "lazysite - Changelog"
subtitle: "Release history, newest first. Tags are the stable identifiers."
brand: plain
standard-margins: true
---

## About this changelog

Versioning
: Releases are git tags (`vX.Y.Z`). Since SM063, `main` is unstable and
  carries unreleased work; a release is a tag cut from a commit on `main`,
  with no per-release version-bump commit.

Keying
: Entries are high-level. Released versions are keyed by tag; unreleased
  entries are keyed by SM number and short commit ref.

Shipped versus mentioned
: An item that SHIPPED in a release **begins its own bullet and names the commit
  that implemented it** - `- SM238 (37e7c37) per-domain tools over MCP`. The
  commit ref is what marks it as built rather than merely written down, so a
  bullet like `- SM184 (publish pages by email) recorded as a candidate proposal`
  is a filing, not a ship. An SM number appearing anywhere else in an entry, such
  as inside a `Docs:` bullet, is likewise a reference: newly filed backlog items
  are routinely listed that way while still open.
  `t/lint/26-backlog-status-matches-changelog.t` relies on this distinction to
  check that everything a release claims to have shipped is marked accordingly
  in `docs/feature-requests/`, so the two cannot drift apart unnoticed.

Naming the commit: AFTER it lands, never before
: vcs-review lands a branch onto `main` **by rebase**, which gives every commit
  a new SHA. So a ref written while the work is still on a branch is stale the
  moment it lands - and the old object lingers in the reflog just long enough
  for a spot check to pass ([[SM354]], where seventeen entries were wrong and
  seven named commits that no longer existed).

  While the work is on a branch, write `(PENDING)`. Once it is on `main`,
  replace that with the landed SHA.
  `t/lint/53-changelog-commit-refs-exist.t` ignores `(PENDING)` and fails on any
  ref that no branch contains, so the placeholder is safe and a stale ref is
  not. SM354's own entry went stale in its own landing, which is how this
  paragraph came to be written.

## Unreleased

- SM563 resolved (PENDING) **the four surfaces agree on every operation.**
  lint 14 compared cookie-vs-token, lint 86 token-vs-registry, lint 23
  API-vs-MCP; the DAV verb map was compared to nothing. NEW t/lint/87
  reads, per logical operation, the capability set from all four tables
  (%COOKIE_CAP, %need, the MCP tool caps, and the capabilities the DAV
  deny strings themselves name) and fails on any disagreement; deliberate
  absences are exempted with their reasons, and a channel capability in
  any column fails on sight - the SM570 shape, structurally refused.

- SM572 resolved (PENDING) **the engine describes its own side effects.**
  A systematic caller of the control API could not ask whether an
  action writes, so a read-shaped sweep rebuilt a live table and cleared
  five roots. actions-list rows and a describe-capabilities `actions`
  block now carry `mutating` (read from %MUTATING, the POST/CSRF gate,
  never restated) and `destructive` for the drop/delete/rebuild family.
  MCP's %ANNOTATE remains the tool-name spelling of the same fact and
  t/lint/23 keeps the two equal through its twin map - which found four
  MCP tools (delete_theme, drop_data_table, rebuild_data_table,
  delete_data_row) with no destructive hint; they carry it now.
  t/unit/manager/10 proves both directions on both surfaces.

- SM565 resolved (PENDING) **whoami tells a stranger only its own shape.**
  At the capability floor, whoami disclosed every manager group name,
  every plugin with its configuration schema and the full theme
  inventory. Each is now returned only to a caller holding a capability
  that governs it: manager_groups to manage_users, plugin config schemas
  to manage_config, themes to manage_themes or manage_layouts. The
  caller's own capabilities, reachability and scope denies are
  unchanged. t/unit/manager/10 pins the floor and each governing grant.

- SM554 resolved (PENDING) **a posted read is not audited.** POST
  action=notices and POST action=layouts-manifest each wrote an ok audit
  row with target "/" - the only live read-shaped actions missing from
  the audit skip list. Both are now skipped, so the trail records
  changes, never looks. NEW t/unit/manager/98 pins it with a real write
  as the control.

- SM553 resolved (PENDING) **the alias spelling keeps the audit target.**
  theme-activate&theme=sky and layout-activate&layout=grid (the SM261
  alias spellings) audited target "/" because the alias resolution lived
  only in the dispatch branch. _audit_implicit_target now names the
  theme or layout whichever spelling was used. t/unit/manager/56 runs
  the dispatcher for both spellings and pins the audit target.

- SM564 resolved (PENDING) **a group is judged by its reach, not its record.**
  NEW `Lazysite::Capabilities::reach_for(\%caps)`: the effective callable
  set per channel ({held, unlocked, callable}) from the same `unlocks`
  tables describe() publishes - a door alone unlocks nothing, an action
  without its door reaches nothing. NEW `group-reach [GROUP]` in
  lazysite-users.pl (read-only) reports it per group through the nesting
  closure. NEW t/unit/users/33-a-group-is-judged-by-its-reach.t. The
  starter's seeded groups were reviewed with it; the findings are a section
  in the SM564 filing (agent-ai/mcp-ai drifted - SM431 handed them the ACL
  verbs; `members` has no reach at all).

- SM562 resolved (PENDING) **a refusal is a refusal, a finding is a finding.**
  `lazysite check --all` labelled every non-zero child exit "with findings",
  so a site the check could not examine (no engine tree) was reported as a
  site finding. Exit 2 now lands in a "could not check" bucket of its own,
  named beside "findings on:"; the worst-status exit contract is untouched.
  NEW t/tools/63-a-refusal-is-not-a-finding.t.

- SM561 resolved (PENDING) **the produced-no-pages refusal can fire.**
  release.sh appended the trailing `--prefix` to `MAN_ADD` before testing
  it for emptiness, so a manpage generator that produced nothing passed the
  gate and shipped a package with no manual pages. The test now comes
  first. t/tools/27-manpages.t lifts the block and runs it against an empty
  man directory, expecting the refusal and exit 1.

- SM560 resolved (PENDING) **an abort says what became of the stage,
  truthfully.** release.sh printed "staging dir retained: PATH" on eleven
  abort paths while the SM328 EXIT trap removed it unless `--keep-stage` was
  given. The trap stays; every abort now reports through one
  `stage_disposition` helper that says "retained" only under `--keep-stage`
  and otherwise "removed (re-run with --keep-stage to inspect)". The header
  and the SM444 comment agree. NEW
  t/tools/61-an-abort-keeps-what-it-says-it-kept.t: the printed path
  exists, or the line says it was removed and how to keep it.

- SM552 resolved (PENDING) **the coverage verdict is reachable under set -e.**
  A non-zero coverage.sh exited release.sh on the line that ran it, before
  `COV_STATUS` was read, so neither "below the declared floor" nor "FAILED
  WITHOUT reaching the floor comparison" nor the COV_LOG location ever
  printed. The status is now captured on the same line
  (`|| COV_STATUS=$?`). t/tools/58 lifts the real block from release.sh and
  runs it under `set -e`, so a harness can no longer pass a script that dies.

- SM551 resolved (PENDING) **group ACL reach reports on a migrated site.**
  lazysite-check.pl's `report_group_acl_reach` and `_acls_file` built
  `$docroot/lazysite/auth/acls.json` by hand, so on an SM293 migrated site
  the @group section was silent and the ACL probe's sweep looked at a store
  that was never there. Both now resolve through `Lazysite::Paths::lazysite_dir`
  as `run_checks` does. t/tools/38-migrate-engine-tree.t gains the assertion:
  an @agents rule written by the real ACL writer on the migrated site is
  reported as "@agents is granted by".

- SM550 resolved (PENDING) **the theme-mirror check runs.**
  `report_theme_assets_mirrored` in lazysite-check.pl called
  `conf_value('layout')` with one argument to a `($file, $key)` function, so
  SM315's standing check opened a file named `layout` and returned before
  looking - it had never run. It now reads the conf file. NEW
  t/tools/62-check-reports-an-unmirrored-theme.t: a theme with its CSS beside
  theme.json and no mirror produces the "no mirrored assets" line naming the
  misplaced file.

- SM549 resolved (PENDING) **actor local is one actor in the users tool.**
  `_authorise_manage` refused `actor: local` for account-disable,
  account-enable and account-reassign while passwd, rename, claim and
  account-create exempted it. SM268 C1 settled that `local` is the operator
  sentinel, so the gate now reads it as the five inline blocks do. NEW
  t/unit/users/32-local-is-one-actor.t: every actor-taking verb gives the
  same verdict with actor local as with no actor.

- SM559 resolved (PENDING) **the walker returns its failures.** One
  file-scoped @COPY_FAILED was fed by every _copy_tree, so an unreadable
  LAYOUT directory was reported as unreadable site content under a
  layout-relative path and counted in manifest.unreadable_omitted, and
  package_apply's copy failures - never drained - surfaced in the next
  package_create of a long-lived process. Found by the backups structural
  review (N4), proven by probe. Both walkers now return their failures and
  the caller labels them: `unreadable` and its manifest count stay as
  SM484 shipped them (content only), `unreadable_layout` carries the
  layout's under lazysite/layouts/<layout>/ with a manifest count, and an
  apply reports `copy_failed` by tree. t/unit/manager/110 pins all three.

- SM548 resolved (PENDING) **the package upload budget is per user.**
  action_site_backup_upload called check_upload_rate($DOCROOT) where the
  signature is ($username, $content_length), so every user of an instance
  shared one package-upload budget keyed on the docroot path and the byte
  limit compared against an undefined length and never fired. Found by
  the backups structural review (N6), proven by probe. The call now passes
  the user and the body length, as the file upload does; t/unit/manager/109
  drives a package over the hourly byte budget to a rate refusal.

- SM547 resolved (PENDING) **site packages have retention.**
  backup_retention (SM268 03-F11) bounded manual and prerestore snapshots
  and the helper's comment listed site packages too, but package_create
  never called it - so the artefact an agent produces most, one per
  site_backup call, accumulated without limit. Found by the backups
  structural review (N5), proven by probe. package_create now applies the
  same retention per host (kind site-<host>), so packaging one domain
  never expires another domain's packages on a shared instance.
  t/unit/manager/108 pins backup_retention: 1 leaving the newest package
  per host and 0 meaning unlimited.

- SM545 resolved (PENDING) **two site packages in one second are two
  files.** package_create named the package host + a one-second stamp and
  wrote it with an overwriting tar; the O_EXCL claim SM268 03-F9 gave
  manual snapshots was never carried across, so an agent looping
  site_backup got two successes, one file, and a sidecar describing
  whichever write won. Found by the backups structural review (N2), proven
  by probe. The package name is now claimed through the same _claim_name
  (a collision takes the -2 suffix) and a failure after the claim removes
  the placeholder. t/unit/manager/106 pins two creates in one second as
  two files with their own content and sidecars.

- SM546 resolved (PENDING) **package_apply loads what it calls.**
  SitePackage::package_apply called Backups::verify_sha256 without ever
  loading Backups - only package_create and the snapshot branch of
  apply_and_configure did - so a fresh process calling package_apply, or
  apply_and_configure(snapshot => 0), died with Undefined subroutine. The
  MCP and lazysite-site.pl were shielded only because they never pass
  snapshot => 0. Found by the backups structural review (N3), proven by
  probe. SitePackage now loads Backups at the top; t/unit/manager/107 uses
  SitePackage alone and asserts both applies return a result.

- SM544 resolved (PENDING) **the safety snapshot covers what the restore
  overwrites.** Backups::_archive_scope skipped bare top-level members and
  its deepening loop stopped at tar's own directory entry for the prefix,
  so an archive carrying ./index.md and ./sites/edge/page.md scoped the
  prerestore snapshot to sites/ and the restore overwrote index.md with no
  rollback copy. Found by the backups structural review (N1), proven by
  probe. A bare file at any level now widens the scope to its parent (the
  root for a top-level file), and directory entries are skipped while
  deepening, so an unscoped archive of one subtree scopes to that subtree
  as the comment promised. t/unit/manager/105 restores a mixed archive and
  asserts the safety tarball carries the pre-restore ./index.md.

- SM568 resolved (PENDING) **nav-read and pages accept manage_content or
  manage_nav.** The SM567 twin-capability check found both under
  manage_nav on the API while read_nav and list_pages sat under
  manage_content over MCP - a content partner could read the navigation
  on one channel and be refused on the other. Decided: they are content
  reads a nav editor needs too, so the API accepts either; the twins leave
  t/lint/23 %TWIN_DIFFERS and its set rule passes.

- SM566 resolved (PENDING) **the migration safety step is on both
  channels.** The control API had data-migrate-plan and data-table-source;
  MCP had neither, so an agent could migrate a table without previewing
  what the migration would refuse, and could not read-modify-write a
  descriptor as text. plan_data_migration and read_data_table_source now
  sit under manage_data beside their siblings; t/lint/23 pairs them and
  t/unit/mcp/09 drives the plan against a refused type change.

- SM538 resolved (PENDING) **pages under docs/ and quotes/ are part of the
  site again.** _each_page hard-skipped both names - the first site's
  folder names, carried since SM087 - so on lazysite.io thirty
  documentation pages were absent from list_pages, unaudited by audit_site
  and untouched by rename_page update_links. The walk now asks
  Manager::Common::path_is_reserved what is engine territory and skips
  nothing else. t/unit/mcp/01 pins a page under docs/.

- SM537 resolved (PENDING) **every MCP tool carries its own annotation.**
  22 of 69 tools fell to the default [0,0,1], so reads such as
  list_domains, read_data_rows and read_form_submissions advertised as
  open-world writes and drop_data_table, delete_data_row, site_apply and
  delete_theme as non-destructive - and clients drive per-call approval
  from these hints. Each now has an explicit entry; t/lint/85 refuses a
  tool that falls to the default.

- SM525 resolved (PENDING) **whoami names only the tools the session may
  call.** whoami.tools echoed every tool in the table to any authenticated
  caller while tools/list filtered by capability (SM196) - two answers to
  "what can I call". whoami now reads the same filtered list. t/unit/mcp/01
  pins a content-only session: whoami.tools equals tools/list.

- SM521 resolved (PENDING) **an anonymous tools/call no longer tells known
  tool names from unknown ones.** With no bearer, a bogus name answered
  -32602 "Unknown tool" and a real one 401, because the lookup ran before
  verify_bearer - the vocabulary SM210 hides from an anonymous tools/list,
  read back one probe at a time. Authentication now runs first.
  t/unit/mcp/01 pins the anonymous probe.

- SM536 resolved (PENDING) **a nav write reaches every cached page.**
  lazysite/nav.conf written over WebDAV left every cached page on the old
  navigation: the manager's save sweeps the generated .html files
  (SM087), a DAV PUT's per-page invalidation is a no-op for a non-.md
  path, and the processor judged a cached render fresh on the .md and
  lazysite.conf mtimes alone - never on the nav file it baked in. A
  per-domain nav-<site>.conf (SM443) missed through every writer. Found
  by the front-door review (NR-3), proven by probe. Fixed in the
  processor, where it covers every writer at once: the nav file a
  request resolves to is one definition shared by resolve_site_vars and
  try_serve_cache, and a render older than it is stale. NEW
  t/integration/75 pins the rendered nav after a DAV PUT of nav.conf,
  after a DAV PUT of a per-domain nav file (the primary untouched), and
  after the manager's save.

- SM535 resolved (PENDING) **a collection delete cleans up.** A WebDAV
  DELETE of a folder removed every page under it but keyed its alias and
  registry housekeeping on the request path ending in .md, which a
  directory never does: the sitemap kept listing the removed pages and
  an alias kept answering with one - a 301 to a 404. The single-file
  DELETE was right, and the manager refuses a non-empty directory, so
  this surface was the only one that could get it wrong. Found by the
  front-door review (NR-2), proven by probe. do_delete now lists the
  pages an entry covers before the removal (Aliases::md_rels, the walker
  reindex_move already used) and deindexes each, drops its per-host
  render copies and invalidates the registries afterwards. NEW
  t/unit/dav/23 pins the alias undef, the cache gone and the sitemap
  clean after a collection DELETE.

- SM534 resolved (PENDING) **a DAV move reaches the registries.** A WebDAV
  MOVE or COPY never invalidated the generated registries (SM483 reached
  PUT and DELETE only), so a page renamed over DAV stayed in the sitemap
  at a URL that now 404s and off it at its new one until the TTL; a copy
  was absent. The manager's action_move and action_copy clear the cache
  on the same fixture. Found by the front-door review (NR-1), proven by
  probe. The require + local DOCROOT + eval pair do_put and do_delete
  each typed is now one helper, and do_copy_move calls it after the
  alias reindex. Two subtests in t/integration/74 pin the cache gone and
  the sitemap listing the new URL, not the old. Seen in passing and left
  for its own filing: a copy is born with an owner-only ACL entry and the
  processor treats ANY entry as governed, so a copied page is absent from
  every registry through the manager too.

- SM556 resolved (PENDING) **a symlinked docroot is one docroot.** Every
  manager module confines a target against the docroot the dispatcher
  hands it, assuming that docroot is canonical; neither dispatcher made
  it so. Under a symlinked DOCUMENT_ROOT theme delete, cache invalidate
  and the submissions reader refused ("Invalid theme path", blocked,
  "Invalid submissions file") while layout delete and the domain purge,
  which resolve both sides, succeeded. Found by the themes structural
  review (N-5), proven by probe. Both dispatchers now take their docroot
  through Paths::canonical_docroot, which resolves it only when both
  spellings find the same engine tree and keeps the given spelling for a
  migrated tree found by one spelling only, so the engine tree never
  moves out from under the front end. t/unit/manager/103
  drives the control API and the MCP under a symlinked docroot.

- SM532 resolved (PENDING) **renaming the active theme keeps the site
  styled.** action_theme_delete refuses the active theme and any theme a
  configured domain resolves to; action_theme_rename checked neither,
  answered ok:1 and left lazysite.conf naming a theme directory that no
  longer existed, so every page rendered with no theme mirror and the
  reply gave no hint. Found by the themes structural review (N-4), proven
  by probe. Rename now applies delete's two guards with delete's wording
  (refuse, rather than repoint: an operator activates another theme
  first, as before a delete) and reports a failed directory rename as a
  failure. t/unit/manager/102 pins both refusals, the untouched site and
  that a free theme still renames with its mirror.

- SM531 resolved (PENDING) **a url page is a cache source.** The processor
  renders <page>.url as it renders <page>.md, but Manager/Themes.pm held
  four opinions about the .html beside a .url: the activation sweep dropped
  it, invalidate('*') kept it, the cache listing said has_source: 0, and
  invalidating it by path refused it as not-a-cache. An operator who
  cleared everything was served the stale .url page and told it had no
  source. Found by the themes structural review (N-2), proven by probe.
  One _cache_source_exists($base) now answers for every walk; an .html
  with neither sibling is still legacy content and is never touched
  (SM133). t/unit/manager/100 drives a .md, a .url and an orphan .html
  through all four walks and pins the single definition.

- SM533 resolved (PENDING) **a layout install cleans up after itself.**
  Manager/Layouts.pm's one temporary-directory cleaner only removed
  /tmp/lazysite-layouts-<pid>, the catalogue actions' directory; the
  manifest install works in /tmp/lazysite-layout-install-<pid> and handed
  that to the same cleaner on every exit, which matched nothing. Every
  install_layout call over the API or MCP left its downloaded packages in
  /tmp and reported success as though it had tidied. Found by the themes
  structural review (N-6), proven by probe. The guard now names both
  prefixes the module mints. t/unit/manager/104 drives a mocked manifest
  install to its end and asserts the working directory is gone.

- SM526 resolved (PENDING) **one answer to is-this-address-public.**
  Manager/Domains.pm carried two address classifiers: the SSRF guard
  domain_check applies to every resolved address, and a second filter
  instance_public_ips used to decide which addresses are "this server".
  They disagreed on 8 of 15 inputs - CGNAT, multicast, 240/4, a malformed
  octet, `::`, fe90::/10 and the IPv4-mapped loopback and RFC1918 forms
  were all public to the second - so a mapped loopback or a proxy's CGNAT
  address could be offered to the points-to-this-server check as an
  address of this install. Found by the themes structural review (N-1),
  proven by probe. The second classifier is deleted and the self-address
  filter is the guard. t/unit/manager/99 drives the eight inputs through
  instance_public_ips and pins that one sub remains.

- SM555 resolved (PENDING) **listing the engine tree logs once.** Opening
  /lazysite in the file browser wrote one "blocked lazysite tree" WARN per
  hidden entry - six per open, reading as a traversal attempt in a log
  review. Found by the path-core review (NR-5), proven by probe. The
  listing sweep now runs the two blocklist tests quietly and writes one
  INFO line per listing with the count; a direct touch of a blocked path
  still warns. t/unit/manager/99 counts the log lines for one listing.

- SM530 resolved (PENDING) **a mkdir into an unwritable parent returns a
  refusal.** `make_path ... or return` never reached its `or` - File::Path
  croaks - so a mkdir, save, binary save, move or copy into an unwritable
  parent killed the CGI with no refusal and no audit line. Found by the
  path-core review (NR-4), proven by probe. One checked helper (the
  Private::_mkpath shape) and the five sites return a refusal hash.
  t/unit/manager/98 drives all five into a read-only parent.

- SM529 resolved (PENDING) **the reply says content moved only when it
  did.** action_acl_set('/') and any write-only rule returned
  content_moved:1 with the "moved out of the document root" note while
  moving nothing - beside the warning saying a site-wide rule moves no
  files, or beside reads_unrestricted:1. Found by the path-core review
  (NR-3), proven by probe. The store sync now clears the flag on the
  site-wide branch and when the source side holds nothing, and the note
  is worded by direction. t/unit/manager/67 pins all three shapes.

- SM528 resolved (PENDING) **an alias on a gated page targets its public
  URL.** A page saved with `aliases:` into a gated section indexed its
  alias against the private-store path (/old-x -> /-lazysite-private/...),
  a promise leading nowhere that delete, deriving the same path, could
  never remove. Found by the path-core review (NR-2), proven by probe.
  Save and delete now key the alias map by validate_path's rel.
  t/unit/manager/71 pins the public target and the de-index.

- SM527 resolved (PENDING) **a lock is keyed by the canonical path.** The
  manager's lock key was the request spelling, so a lock taken as
  content/p.md was invisible to a save of /content/p.md, ./content/p.md or
  content//p.md, and MCP (/slug.md) and the API (path as typed) never saw
  each other's locks. Found by the path-core review (NR-1), proven by
  probe. Every site now derives the key from validate_path's rel through
  one helper; acquire, release and lock-info validate first. t/unit/manager/08
  pins the four spellings against one lock and the listing glyph.

- SM522 resolved (PENDING) **the front-matter reserved list is populated at
  request time.** `our %FRONT_MATTER_RESERVED` sat below the dispatch, so
  under CGI and FastCGI it was empty when a request was served: a page's
  `auth:` and `layout:` reached the stash as page_auth / page_layout and
  scan records carried auth, layout, register and search as custom keys
  (the SM293 shape with `our`, which t/lint/39 only looked for as `my`).
  Found by the processor structural review, proven by probe. The list is
  now the sub `_front_matter_reserved()`, read by the scan and the stash;
  t/lint/39 now catches a file-scoped `our` below the main body, and
  t/unit/processor/60 renders a page that sets both keys and asserts
  neither reaches the stash.

- SM571 resolved (PENDING) **the history summary walks the history once.**
  `git-history-summary` / `list_content_history` always 504'd on edge: the
  summary ran the per-file lineage walk (several git processes, following
  renames) for EVERY tracked path, O(files x history), and `limit` changed
  nothing because the action has never taken one. It now reads the history
  in ONE `git log --name-status` pass, newest first, keeping the SM175
  rules by construction - an incarnation ends at its add commit, a recorded
  move continues into the source path's older commits, 200 revisions per
  path as before. Same output shape and sort. t/unit/lib/20 pins 40 files
  x 3 commits in at most 3 git invocations (124 before, 2 after). Found by
  the site agent's capability sweep, 2026-08-25.
- SM558 resolved (PENDING) **the link audit sees the root page.** A link
  written as `/index` or `/index.html` was always reported broken: the
  check stripped only a trailing `/index`, so `/docs/index` resolved
  while the bare root spelling never did. The check now maps a bare
  `index` target to the root page as canonical() maps index.md.
  t/unit/plugins/32 audits a fixture docroot and reads exactly the one
  genuinely broken link.

- SM557 resolved (PENDING) **a post writes no used-only-once warnings.**
  Every form POST wrote two `Name "Lazysite::...::X" used only once:
  possible typo` lines to the error log - `local $Pkg::VAR` on packages
  only require'd at runtime - and the compile lint checked only the exit
  code. The seven warning sites (form-handler and six siblings) now carry
  a scoped `no warnings 'once'`, and t/lint/04 reads the output and
  refuses the warning across the sweep.

- SM543 resolved (PENDING) **a recount uses the loaded ruleset.**
  `--recount --apply` was dispatched before the SM391 ruleset load and
  re-entered the export in-process, so the repair tool reclassified
  history under the built-in rules the operator had replaced with
  classifiers.json - and reported `changed=1` for the damage. The recount
  dispatch now compiles the ruleset first. t/unit/plugins/31 recounts a
  day classified under a loaded rule and reads the same version and
  verdicts back.

- SM542 resolved (PENDING) **the page refresh keeps form outcomes.** A
  closed day first reached by the manager Stats page's refresh (`--scan`)
  was persisted and finalised with `forms:{}` - only the export path
  folded form-events in, and the final marker stopped every later export
  from rewriting the file. The scan path now makes the same fold before
  the day is persisted, so both entry points write the same durable
  record. t/unit/plugins/30 reaches a day scan-first and reads its stored
  and blocked outcomes from the day file.

- SM541 resolved (PENDING) **a promotion reverses the device.** The event
  ring stored no device and no search term, so a late scanner promotion
  reaching back decremented `devices{unknown}` while the original hit had
  gone to `devices{desktop}`, and a term the visitor had pushed over the
  floor stayed counted. The ring now carries the device and the term's
  hash (never the words - the ring is on disk), and the reversal undoes
  what the hit did. t/unit/plugins/29 promotes a desktop visitor in a
  second batch and reads zero desktop, zero human and no term.

- SM540 resolved (PENDING) **a handler error is forwarded.** With
  `forward_diagnostics: true` an ERROR from a form submission stayed on
  STDERR: the four plugin copies of log_event (form-handler, form-smtp,
  audit, payment-demo) predated Lazysite::Util's forward_line. Each copy
  now hands its line to a best-effort forwarder that eval-requires Util
  through the runtime locator - the plugins stay module-free, the one
  forwarding implementation stays in Util, and a missing lib costs a
  syslog copy, never a submission. t/unit/forms/12 drives three of the
  plugins through the syslog dump seam.

- SM539 resolved (PENDING) **a multi-answer survives a multipart post.** SM401
  taught the urlencoded branch of the form parser that a repeated field
  name is a multi-select, but the multipart branch still overwrote - so a
  form with an upload and a checkbox group kept only the last tick. Both
  branches now feed one accumulator. t/unit/forms/10 posts the same
  repeated key both ways through the real handler and reads `red; blue`
  from both stored rows.

- SM524 resolved (PENDING) **SMTP auth and TLS are what the conf says.**
  `auth: 1` and `auth: yes` used to skip SMTP authentication silently
  (the read was `/^true$/i`), and `tls: false` was listed among the
  checked stages because the string was truthy. Both keys now go through
  one reader each under the SM519 discipline (1/true/yes/on and
  0/false/no/off, plus `starttls` for tls); any other spelling is refused
  at the config stage by the validator and before the socket opens on a
  send. starter/docs/forms-smtp.md states the accepted spellings;
  t/unit/forms/05 pins the stages against the mock server.

- SM523 resolved (PENDING) **a visitor cannot flag themselves.** A
  submission carrying `_quarantined=1&_spam_reason=...` used to be stored
  with both keys, skip the notification bell and count as quarantined -
  the visitor decided what the engine's spam gate should have. parse_post
  now keeps only the protocol keys the renderer emits (`_form _page _hp
  _ts _tk`) and drops every other client underscore key, so the status
  meta on a stored record is engine-owned. t/unit/forms/11 pins it.

- SM567 resolved (PENDING) **the scope-ceiling control is named for what it
  governs.** "Content access - set by its own grants alone" governs whether
  an account's REACH is capped by its creator's reach (SM194), on every
  channel; it is relabelled "Scope ceiling" / "None - its own domain grants
  alone decide its reach". t/lint/23 now pins that API/MCP twins sit under
  the same capability. SM570 and SM515 filings carry the floor-row proofs.

- SM518 resolved (PENDING) **the rules move with the folder.** A directory
  move through the manager (and so MCP move_file) re-keyed only the exact
  source ACL key, so every per-file rule beneath a renamed folder stayed
  at the old path: gated content silently public after a rename, ok:1,
  nothing reported. Found by the path-core review (NR-6), proven by probe.
  action_move now re-keys through Acl::rekey_path (the definition DAV
  already used) and runs the SM286 store sync for every re-keyed key; a
  folder present in both trees is renamed in each tree rather than having
  its store half dragged into the public destination. t/unit/manager/66
  pins the rule at the new key, a visitor refused, and no public copy.

- SM517 resolved (PENDING) **downloads honour the carve-out.** SM268 H4
  gates nav.conf (manage_nav) and the submission store (read_submissions)
  on every file verb in %file_surface; file-download and file-zip-download
  were never in it, and the zip parses `paths=` itself so no gate saw its
  list. On a secured site a manage_content-only account was refused `read`
  of a submission file and then downloaded it, alone or zipped with
  nav.conf. Found by the manager-api structural review and proven by
  probe. Both verbs are now gated as reads, the zip over every requested
  path - one governed path refuses the whole zip, naming the path and the
  capability. t/unit/manager/62 drives both verbs; t/lint/14 asserts every
  path-bearing action is in %file_surface.

- SM520 resolved (PENDING) **a domain preview is anonymous.** domain_preview
  shelled the processor with the operator's HTTP_COOKIE and
  HTTP_AUTHORIZATION still set (only HTTP_X_REMOTE_* and LAZYSITE_AUTH_*
  were stripped), so the domain check rendered as the operator and showed a
  gated section as visible. preview_public already stripped the full set;
  both now call one _anonymous_env() so the lists cannot drift. Found by
  the structural review (N-3); t/unit/manager/101 drives both previews
  through a stub processor and asserts neither the session nor the gated
  body reaches the answer.

- SM519 resolved (PENDING) **no means no.** YAML 1.2, which YAML::PP
  implements, spells `no`, `off`, `yes` and `on` as strings, and the
  descriptor loader tested them with Perl truth: `public: no` published the
  table to anonymous visitors, `required: no` refused writes and `unique:
  off` built a unique index. One `_bool` normaliser now serves every flag
  (public, timestamps, required, unique): 1/0, true/false, yes/no, on/off
  case-insensitively and JSON::PP booleans; anything else is refused at
  load with `<key> must be true or false`. Found by the data/auth
  structural review; proven by probe; t/unit/data/01 asserts every
  spelling.

- SM570 resolved (PENDING) **a channel is not an authority.** acl-get,
  acl-set and acl-remove answered a token holding only api, manage_themes
  and webdav: the gate was `webdav || manage_content` and the registry
  agreed. A webdav-only grant cannot write content, so it must not govern
  it - the three gate on manage_content alone, and t/lint/86 forbids any
  channel capability (webdav, api, mcp, ui) from every token gate.

- SM515 resolved (PENDING) **every MCP tool declares its gate.** list_briefs
  and delete_brief (SM508) shipped with no cap and the key `schema` instead
  of `inputSchema`; a cap-less tool is channel-only to the dispatcher, so
  any authenticated partner could delete a brief and no argument
  validation ran. Both gated on manage_content now, and t/lint/85 asserts
  every tool declares both keys.

- SM514 resolved (PENDING) **a safety export can be read, judged from the
  listing, and offered back.** SM512 shipped list and delete; an export
  could only be listed and destroyed. The listing now carries row count
  and a key sample; data-safety-export-read / read_data_safety_export
  opens one; data-safety-export-restore / restore_data_safety_export
  offers the rows back (plan, then apply), restoring the columns the
  table still has and reporting the ones it no longer does.

## 0.10.31 - EDGE, beta candidate: the editors are modal, and the tidy tools (2026-08-24)

- SM513 resolved (2b406c7) **delete_page takes a path as well as a slug.**
  read_page took path and delete_page only slug - two page tools, two
  identifiers. Either works now, and the refusal names both.

- SM512 resolved (1b83041, 509f4e0) **a safety export can be listed and cleared.**
  Every drop and lossy rebuild writes one under lazysite/db/rebuilds/ -
  correctly, and until now permanently. data-safety-exports /
  list_data_safety_exports lists them (table, kind, stamp, size);
  data-safety-export-delete / delete_data_safety_export clears one by its
  exact minted name, audited. The SM508 pattern, for tables.

- SM502 partly resolved (a9d6efb, 0655926) **the editors are modal.** The operator's
  Task-5 finding, asked for twice: adding or editing a row and editing a
  table's fields opened inline below the fold. Both open in a modal now,
  the submissions viewer's shape, with click-outside and Escape as Cancel.
  The Cancel/Close convention (Cancel discards edits; Close dismisses a
  viewer) is stated in the manager UI guide and swept here. U-4 ships in
  full too: the fields modal opens on a FORM built from the parsed
  descriptor, with the stored YAML as a tab; saving from the form
  regenerates the text, the same loader validates both. All six Task-5
  findings are now shipped.

## 0.10.30 - EDGE: the briefs ring, the cap that reached the page, and the queue before the cut (2026-08-24)

- SM511 resolved (d5b03ad) **the cap reaches the page, and the page can
  say so.** A db: binding with no limit rendered 200 of 250 looking
  complete, .count agreeing; an over-cap limit rendered ZERO rows with no
  signal. One ceiling now (500, stated once - the API's 501-1000 range is
  gone); over-cap clamps with a logged warning; every list binding gets
  <var>_total; capped renders log N-of-M naming the page; .count is the
  true count before the limit.

- SM502 partly resolved (87dafc9) **the data manager after its walk: three
  of six.** U-1: data-rows always carried a silent 200-row server cap - the
  reply now returns the total behind the page and the panel pages honestly
  (rows X-Y of N). U-5: the tables page can declare a table (name prompt +
  starter descriptor through the same save/validate/plan path). U-6: the
  migrate panel states the apply-vs-rebuild contract where the deciding
  happens. U-2/U-3/U-4 (modals, label sweep, structured descriptor) remain
  queued.

- SM510 resolved (c38ad35, 940d1ee) **a new path may be deep.** validate_path
  anchored realpath at the immediate parent, so /a/b.md validated while
  /a/b/c.md was "Invalid path" - while the writers behind it create parent
  directories anyway. The anchor now walks to the nearest existing
  ancestor (both trees); the `..` rejection, symlink collapse and H3
  containment are pinned unchanged.

- SM509 resolved (de49b2a) **the manager sees the submissions the store
  holds.** The panel said "No submissions yet" for a store the API read
  five rows from: its directory-listing probe hit the carve-out's prefix
  test, which matched only paths UNDER the store - the directory itself
  was denied and the refusal drawn as an empty state. The store directory
  now joins its own carve-out (boundary-safe) and answers to the same
  capability as its files.

- SM506 resolved (e47c40c) **the briefings teach the store.** The documents
  every connecting agent reads before authoring still taught the retired
  .brief sidecar - including the promise ("not a blocked extension, writes
  through your normal content scope") that SM504 inverts in this same cut.
  The publishing brief section is rewritten for the store, authoring step 6
  repointed, the connector-tools carriage claims match SM507, and the dead
  createBrief() is gone from the Files panel source.

- SM508 resolved (1c09956) **a brief can be listed, and an orphan can be
  cleared.** The store had read, append and migrate - no list, no delete,
  so an orphaned entry was undiscoverable (the field produced three as
  proof). briefs-list / list_briefs returns every entry with an orphan
  flag; brief-delete / delete_brief removes one, audited, with the
  explicit-path guard. The delete keys on the store, not validate_path -
  an orphan's content path may no longer validate.

- SM507 resolved (e4820dd) **the store entry follows its file.** SM245's
  recorded interim - a moved file's brief staying under its old key "until
  a reconcile adopts it" - met the field first: rename_page silently split
  a page from its record of intent and delete_page left an unlistable
  orphan. Move now carries the store entry and delete removes it, on the
  manager, MCP and DAV surfaces alike; a COPY starts unbriefed, as it
  starts with a fresh ACL. read_page's has_brief consults the store.

- SM505 resolved (6aea28c) **a row action's audit entry names the row.**
  Raised by the site agent building the SM503 retest: "someone edited that
  table" is half an answer when the question a trail gets asked is which
  row. data-row-save and data-row-delete entries now carry row=<key> in the
  audit detail field, read from the handler's result - the authoritative
  key, so an ADD names the row it created. Row keys land in the audit log:
  the SM465 trade, accepted again.

- SM504 resolved (1af3758) **a sidecar write refuses once the store owns
  the record.** The operator's instruction: on a site whose briefs plugin
  is enabled, a .brief write fails on every channel with the replacement
  named (append_brief / brief-append) - never lands as an inert note
  nobody reads. Gated on the plugin per site, never the version: a
  half-migrated estate is the normal state, a site on sidecars keeps
  working indefinitely, and reads stay untouched.

- SM484 resolved (c9ecb79) **the two snapshot paths agree.** The restore's
  safety snapshot scopes to the archive's own blast radius (derived from
  its members - nothing else records it), so a partner who can back up can
  roll back; the site package reports what its staging copy could not read
  - unreadable directories collected at the find level, where the silent
  omission actually happened - as site-relative names in the result and a
  count in the travelling manifest; and tar's ./-relative member names
  survive the path scrub whole.

- SM500 resolved (9db1d4a) **shadowed_by_files stays site-relative.** The
  report of a file shadowing a generated registry carried the absolute
  server path for any non-docroot content root - over MCP, exactly where
  multi-domain registry conditions get debugged. Every root's report is
  now docroot-relative, asserted inside the SM483 regression's
  symlinked-root scenario.

- SM483 resolved (d125af6) **the registry reaches every writer.** All three
  reproduced conditions fixed: the invalidator keys on realpaths exactly as
  the processor does (a symlink no longer splits the cache pair and
  regenerate clears what was cached); the reader accepts flow-style
  register lists - healing every MCP-created page already in the field -
  while the MCP writer emits block style with names normalised against the
  real registries and an honest schema example; and DAV writes and deletes
  invalidate the registries beside the alias map, so a page published over
  WebDAV reaches the sitemap now rather than at the TTL.

## 0.10.29 - EDGE: the consent banner, briefs out of band, and the twins agreeing (2026-08-24)

- SM468 resolved (9480c16) **the store remembers what its shape was.** An
  internal _schema_history table - undeclarable by construction, invisible
  to every operator surface, travelling with the data through
  backup/restore - gains one row per apply, rebuild and drop: when, who
  (threaded from all three surfaces), and what happened, including lost
  columns and the safety-export receipt. Never fatal: a broken record logs
  and the change proceeds. Surfaced as `history` on the data-table
  response across manager, API and MCP.

- SM425 resolved (3901541) **a member is not the traffic the rate limit
  stops.** A submission carrying a session cookie the shared verifier
  (SM411) accepts cryptographically bypasses the anonymous IP rate limit;
  anonymous traffic keeps it unchanged, and a forged signature is anonymous
  traffic. The verified identity is a boolean for the limiter only - the
  submission stays actor-less and the audit column stays empty, exactly the
  SM402 line, now held by behaviour as well as source. The exemption
  degrades to anonymous if the session module cannot load (the resolve_db
  lesson - a broken exemption must never cost anybody a form). The brief's
  second item was already built: radio/checklist/checklist-qty/quoted
  options (SM401) and number min:/max: value bounds all pre-exist; the
  filing records it.

- SM503 resolved (01608c2) **a data action's audit entry names the table.**
  Observed by the operator in their own trail: every data-* row targeted
  "/" - the dispatcher's path default, which no data action uses. The audit
  block now consults the query's table and then the body's, so the trail
  answers which table was migrated, imported into, row-edited or dropped.

- SM245 resolved (6ed2aca) **briefs move out of band.** The record stays;
  the sidecar file goes. A contract plugin owns a store at
  lazysite/briefs/<content-path>; brief-read/brief-append (API) and
  read_brief/append_brief (MCP) under manage_content; an idempotent
  migration imports every sidecar and never removes one it did not import.
  The engine forgets briefs exist - listing metadata, move/copy/convert
  carriage, private-store companionship and the DAV sync all gone - while
  the extension-level DENIES deliberately stay as legacy-file protection
  (a stray sidecar on a deployed site still answers 404; the filing
  records the deviation and its reason).

- SM431 resolved (d612308) **the permissions twins agree about who reaches
  them.** The control API has had acl actions since SM074 - the filed
  "nothing" was wrong - but they needed the webdav channel while their MCP
  twins sat under manage_content, so a token that could create gated
  content met refusals on one door and working tools on the other. The acl
  actions join manage_content's unlocks (describe_capabilities and
  reachable now say so), the gate becomes webdav OR manage_content, lint
  23's channel-gated exemption is removed, and the twins are recorded in
  its pair table. Per-file ownership rules are untouched.

- SM415 resolved (d22b396, 7604b3d) **a form post without JavaScript lands on the
  page, not on raw JSON.** The chrome JS declares Accept: application/json
  and keeps today's reply byte-for-byte; a native browser post is answered
  the way login answers - 303 back to the form's own page (named by a
  validated _page hidden field the renderer embeds; same-site absolute
  paths only, absent means JSON) with the outcome riding the query string,
  which the :::form renderer shows as a banner. Refusals redirect too,
  carrying the user-safe text; typed values are not re-presented in this
  cut (recorded in the filing, with SM501 pointing at it).

- SM476 docs (9834167) **the `public:` key reaches the data briefing.** The
  one flag that decides whether a data-backed page shows anything to a
  visitor was absent from /docs/ai-briefing-data - reported by the site
  agent, who lost an afternoon to exactly that silence before SM476 was
  explained to them. The Reading-on-a-page section now states the
  publication gate, the signed-in behaviour, the ACL read list, and the
  gated-application composition.

- SM499 resolved (1ede8ba) **the Keys page offered a revoke it would always
  refuse.** SM439 lists interactive accounts that hold a machine channel so
  no access is hidden, and its guard refuses to revoke a login password -
  both by design - but the page rendered the Revoke key button on those
  rows anyway, so the operator met the refusal instead of the design. The
  row already carried `interactive: true`; the page now consumes it: an
  interactive row says "interactive - manage on the Users page" where the
  button would be. The refusal guard is untouched. Observed by the operator
  on 0.10.28.

- SM429 resolved (e882d59) **cross-origin-opener-policy is emitted, and the
  authorize page joins the header set.** same-origin-allow-popups on HTML
  responses, beside the CSP, in both copies of the set - the strict value
  would break the two popup behaviours the filing names (the manager's
  open-in-new-tab, the OAuth flow handing its result back). Following the
  filing's advice to test the real authorize page found the bigger gap: the
  OAuth consent page - an authorisation surface - hand-printed its response
  and carried no security headers at all. It now emits the full html set;
  t/integration/70 drives the real page via the script's own client
  registration, and t/integration/44 asserts COOP on pages and not on
  stylesheets.

- SM498 resolved (b4dbda5, df4fea9) **the GS12 gallery example could not work.** Field
  report from the 0.10.28 verification: published verbatim, every image
  rendered as a literal `!` and a link - Markdown image syntax cannot carry
  a template expression, because the body becomes HTML first and TT runs
  second, which the doc stated backwards. The example now uses the raw
  `<img>` form the field agent tested, the limitation and the real pipeline
  order are stated beside it, and t/integration/68 renders the documented
  shape executably so a worked example can no longer ship unrendered. Also
  from the same report: the layouts briefing's `--theme-colors-accent` is
  now `--theme-colours-accent`, matching the engine's emission (the names
  mirror the theme.json's own keys) and the document's own schema examples.
  Follow-up from the same reporter: the briefing also states the bound the
  ordering implies - a loop cannot compute a fence's name or emit one
  conditionally, because the fence is gone before TT runs.
- SM491 completed (7d93c9e) **the control-API whoami carries `reachable`
  after all.** The 0.10.28 field verification found it on MCP and absent on
  the API - the edit existed in the SM491 worktree and was not in its
  commit; the landing lost the API half and no test noticed, because the
  test pinned the derivation and neither surface's emission. Restored, and
  t/integration/69 now drives BOTH whoamis and requires the block on each -
  a surface cannot silently lose it again. The remaining field gap ("a
  control-API-first client cannot see reachable at all") closes with this.

- SM496 resolved (2f7a3c0) **a capability added by a release asks the
  administrator, in the UI.** SM471 stands - an upgrade never grants - but
  its warning's only remedy was a CLI command on the box, and the operator's
  requirement is that app support needs no sysadmin after first setup. The
  store can now record a decision: turning a capability off writes an
  explicit 0 (declined) instead of deleting the key, so ABSENT means
  undecided. Each manager group's card on the Groups page opens with a
  banner of undecided capabilities - Grant / Dismiss, one click, through the
  same group-settings-set path as every toggle (SM195 ceiling and audit
  trail unchanged). lazysite-check warns only about undecided capabilities,
  names the Groups page first and the CLI second, and counts declined ones
  as decisions rather than re-warning about them.

## 0.10.28 - EDGE: the field reports answered - menu, status, mirror, and the audit read (2026-08-23)

- SM491 resolved (539df5b) **whoami says which of the grant's doors can reach
  each capability.** An agent with analytics:true and mcp:false tried an
  action name guessed from the capability, was refused namelessly, and
  concluded the capability had no surface - while the API route existed as
  analyse_visitors the whole time. Both whoamis (API and MCP, one shared
  derivation) now carry `reachable`: per held capability, the channels of
  THIS grant that reach it and the channels that would but are off - derived
  from the unlocks map, so a capability that gains or loses a surface changes
  the answer without anybody remembering to.

- SM438 resolved (5a692fc) **updating a mirrored theme asset over WebDAV was a
  silent no-op.** Filed deliberately without a cause; the settling test the
  filing specified was run and it is outcome (a): the write was REDIRECTED.
  resolve_for_write's "existing content keeps its home" sent an update of any
  mirror file with a private-store copy to the private store - 204, fresh
  mtime, bytes where nothing serves them - while the public mirror kept
  serving the old content. Create worked because no private copy existed to
  win. The mirror is engine-owned derived output and its canonical writer
  (activation's cp -r) is public-only, so writes to lazysite-assets/ now
  resolve public unconditionally, and a PUT that finds a stale private copy
  there removes it and says so in the log - the field site heals on its next
  publish instead of needing delete-then-create.
- SM464 resolved (c02346b) **an administrator can audit a permission they did
  not set.** Filed as a question; the answer splits the two acts the filing
  said to split: reading a rule is the audit half and follows manage_users -
  an operator, a cookie-session admin, or a token whose OWN grant carries
  manage_users may read any rule - while modifying stays owner-only for
  everyone. The token override keys on the grant the operator wrote for that
  partner, never on group membership (SM127). The filing's asymmetry note is
  stale: SM465 already records before/after rule content in the acl-set
  audit entry.

- SM495 resolved (3e5c1d1) **the data plugin's Status button said "Done."**
  The plugin returned modules, store and table list; the Plugin Manager
  shows `message` or the literal `Done.`, so the structured answer went
  unread. Status now carries a one-line message - worst news first: missing
  modules, then a store that does not exist yet, then the table count and
  names with the store size. Reported from the field on 0.10.27.

- SM494 resolved (6ff6499) **the menu could not see a Data grant.** The
  processor resolves a hand-written list of nav-gating capabilities into
  `manager_caps`; `manage_data` was never added to it, so the menu showed
  "Data tables" padlocked no matter what a group granted, and the DM-1 nav
  test could not notice - it hands `manager_caps` to the template, testing
  the layout but never the derivation. The capability is in the list, and a
  new lint requires every `manager_caps.X` the manager layout references to
  appear in the processor's derivation, so the next capability cannot be
  forgotten the same way. Reported from the field on 0.10.27.

- SM492 shipped in part (GS9, GS11, GS12; 7589ede) **the component mechanism
  is documented, and an unclosed fence is named.** An estate survey found the
  same hero panel hand-built twice because nothing told either author that
  `::: component` existed. `ai-briefing-layouts` gains "Components: a
  layout's reusable pieces" - `attrs`/`content`/`slots`, a worked `hero.tt`,
  built-ins, the fenced-div fallback - and the `sections:` shape, stated
  honestly: no shipped layout reads `sections` yet. `ai-briefing-authoring`
  gains a `json:` gallery worked end to end, with the `db:` pointer. A
  `::: name` fence that is never closed is logged as a build `WARN` naming
  the component and body line, and `validate_page` reports
  `component-fence-unmatched` at the file line (``` code blocks skipped); a
  stray closing `:::` is `fence-close-unmatched`. GS7+GS8+GS10 refiled as
  SM493.

- SM488 resolved (b35bf33) **validate_page flagged ISO dates as phone
  numbers, and reported every line short by the front matter.** The phone
  pattern matched `2026-08-22` - ten characters of digits and hyphens - so a
  page with three dates produced three warnings, two of them filenames of
  this project's own filings. And the scan counted from zero over the body,
  so every line was short by the front matter plus its two fences: reported
  15/58/59, actual 24/67/68. Dates are stripped before the pattern runs, and
  the counter starts where the body does.

- SM489 resolved (5c59f09) **a rebuild with nothing to do dropped and
  recreated the table anyway.** Found by the site agent pointing
  `data-rebuild` at a live table with no pending change: it built the copy,
  copied the rows, dropped the original and renamed into place - with no
  prompt, because nothing was lost and so nothing was confirmed. Now a no-op
  when the shapes already agree, the way `data-migrate` was. `data-table`
  also reports `public` and `pending_schema`, as the listing does.

- Task 5 (c1f30b7) **the data-tables walk says which half is the agent's and
  which is the operator's.** The site agent corrected the premise: a
  manager-UI walk is a cookie session, which a partner token is excluded from
  by design. The agent declares the table and does the server-side checks;
  the operator's run starts at step 3. The register row records the split.
  Landed after 0.10.27's pre-cut pass, so it is the first item of the next
  cut rather than a late addition to this one.

## 0.10.27 - EDGE: the data manager, and a table that can finally be removed (2026-08-23)

The manager half of the typed-data plan. An operator can now see a table, read
and download it, edit its rows, import a spreadsheet back into it, edit its
descriptor, and see what a migration would do before doing it. The intended
v1 scope - DP-1..4 plus DM-1..4 - is complete, and DM-5 and DM-7 with it.
DM-6 (in-grid ergonomics) is deferred by decision: the brief's own test for it
is whether the CSV round trip proves insufficient in use, and nothing has been
used yet.

Three of the field agent's findings from 0.10.26 are fixed here, and one of
them - a read list silently discarded with every signal saying protected - is
the reason this cut should go to edge promptly. The third, the table that could
not be removed, is the one that was holding up their testing.

- DM-7 (b466fbd) **the operator docs pass, and the walk that cannot be run
  from here.** `MANUAL-CHECKS.md` says why the Data tables page is out of the
  gate's reach, and the walkthrough gains Task 5 - ten steps from an undeclared
  table to a spreadsheet round trip, a blocked rebuild with its row count, and
  a drop. The register row says **not walked**: the manager has no browser
  harness, and the register's own rule is that a pass nobody took is not
  recorded as one. It needs this build deployed.

- DM-5 (676523c) **an operator can edit a descriptor and see what migrating
  would do.** Edited as text, deliberately - a form regenerating the file would
  save one the operator did not write, comments and all, so the source
  round-trips byte for byte. `data-migrate` planned and applied in one call; a
  new `data-migrate-plan` applies nothing, and when a step is blocked it asks
  the rebuild pre-flight too, so SM487's *"1 row has no 'when'"* is read at
  decision time rather than as a rollback after confirming.

- SM487 resolved (88f7c78) **the rebuild pre-flight named a risk that was not
  the one that bit.** The prompt warned about losing `note`; the operator
  confirmed; the rebuild failed on a row with no `when`, with a driver string
  naming an internal table and no row. The pre-flight only considered dropped
  columns. It now counts NULLs against a new `required`, names a repeated value
  against a new `unique`, and runs stored values through `Value.pm` for a
  narrowed type - because only `Value.pm` knows that `"ten"` is not an integer.
  A blocked rebuild is refused **before** confirmation is asked for, since no
  confirmation can fix data.

- DM-4 (924be05) **a CSV import validates everything, shows the plan, then
  commits - or nothing.** One bad row refuses the whole file, naming the row
  as the spreadsheet numbers it. An empty cell means *not sent*, so a stored
  value survives a blank. The export-import round trip is asserted
  byte-identical, and the formula guard comes off on the way in so it cannot
  accumulate.

- DM-3 (0f68603) **an operator can add, edit and delete a row - and a re-key is
  refused.** The editor is built from the descriptor and decides nothing about
  validity: it sends what was typed and points at the field the server names.
  It found a defect: an update carrying a new key returned `ok:1` and silently
  discarded the key while applying the rest. Now refused, naming the field and
  saying how to move a row.

- SM486 resolved (faec722) **a feature-test page put itself in customers'
  sitemaps.** Four of nine live sites served `/lazysite-demo` publicly, one
  under the client's own name and offered to search engines - it declared
  `register: [llms.txt, sitemap.xml]` and did as told. Demonstration pages no
  longer register themselves, every starter page declares `starter_role`, and
  the separable-folder proposal stays open on its own merits because a folder
  marked deletable would invite deleting the file that switches search on.

- Register hygiene (939bd71) **every partial closed.** Seven filings carried
  `status: partial`; four were stale and are shipped, three were real and are
  refiled as SM483, SM484 and SM485 so each has an owner.

- SM482 resolved (75352b6) **an alias redirect kept the path and threw away
  the parameters.** On cloudient.net the query string *was* the payload - the
  affected customer's URL - and the alias discarded it while fixing the 404.
  Every redirect now carries the query through, joined with `&` to any the
  alias target already has, CR/LF stripped.

- SM481 resolved (1a5ec58) **the engine knew why the page was empty, and told
  nobody who could read it.** SM476's "not published" diagnostic fired - to
  stderr, the web server's error log, which an agent over MCP cannot reach. It
  is now answered in `validate_page`, where the author is already looking,
  with the sentence that would have saved the afternoon: *the API and the
  manager still read it, so the page looks broken and the data looks fine.*

- SM479 resolved (2eeb695) **acl-set discarded a read list and reported
  success.** A `read` sent in the query string was dropped silently while a
  `path` in the body had been refused since SM306 - one direction guarded, the
  other not. The reply said `ok:1` and *content moved out of the document
  root*; the page stayed public. All four lists in the query are now refused,
  and a rule with no read list says plainly that anyone may still fetch the
  pages.

- DM-2 (602e135) **the table as a file, in the format that fits the job.**
  Typed JSON is exact and goes back in; CSV is for a spreadsheet, and cells a
  spreadsheet would run as formulas are prefixed and counted, because since
  DP-4 rows can arrive from a public form.

- DM-1 (20066da) **an operator can see a table.** The listing answers the two
  questions somebody actually has - can anyone see it, is it real yet - and
  the nav gates on plugin-enabled *and* capability, which mean different
  things.

- SM480 resolved (c3674f8) **a table could be declared from three surfaces
  and removed from none.** Found by a field agent tidying up after a testing
  session: no API action, no MCP tool, and the descriptor lives under
  `lazysite/` where every write channel refuses - so a table made by mistake
  or for one afternoon was permanent. `data-table-drop` / `drop_data_table`
  take everything and ask first, confirmed by typing the table's name. The
  safety export comes first, and if it cannot be written nothing is dropped;
  the descriptor goes last so a partial failure leaves the recoverable state.
  `safety_export` no longer returns an absolute server path - it handed over
  the hosting account name and the filesystem layout.

## 0.10.26 - EDGE: the data plugin becomes usable, and its second door gets a lock (2026-08-22)

- DP-3b (c3d6c5b) **the helper that makes `mode=live` and `mode=client` mean
  something.** A region declares the binding and a `<template>` says what one
  row looks like; the shipped script fills it from the data endpoint. Values go
  in as TEXT, always - rows can arrive from a public form, so a helper that
  treated them as markup would turn a contact form into a way to run script on
  every visitor's page. A failed refresh leaves what is on the page, regions
  load on view, and nothing polls unless the author asks. Injected only into
  pages that actually carry a region.

- The coverage gate (c1c2feb) **cannot report what it did not measure.**
  `coverage.sh` discarded the suite's output and swallowed its exit code, so a
  run that died partway produced a report indistinguishable from a healthy one,
  only with lower numbers. A 2-job re-baseline reported 38.6% for a file whose
  recorded baseline is 82.1%, and those numbers were one commit from being
  written in as the new floor - which would have ratcheted the floors DOWN. The
  giveaway was the clock rather than the numbers: 465 seconds against 270 for
  the same suite uninstrumented. `--check` now refuses to compare an unmeasured
  suite to the floors (exit 3), rather than blaming coverage for something that
  is not coverage - SM444 one layer further in.

- DP-4 (9d18c55) **a form submission becomes a row.** The anonymous write path,
  and the only one: the data endpoint refuses an anonymous POST and says a form
  is how you collect data from visitors. The operator's handler decides the
  table and the column names; the visitor decides only values, and a form field
  nobody mapped is DROPPED - so a form gaining a field cannot start writing a
  column, and a submission naming a real column cannot reach it. Values go
  through the same coercion as any other write, and a refused value fails the
  delivery rather than storing something wrong.

- F-1/F-4/F-5 (091617b) **three things a real site could not say.** From the
  field agent's attempt to describe a painting gallery: `default_order` names
  the sequence a table is in, so a bare binding stops returning rows in
  whatever order the store hands back; `unique: true` says no two rows share a
  value without making it the key, and adding it to a field that already has
  duplicates is reported - naming the value - rather than attempted; and a
  widget on a non-text field is refused instead of silently becoming an editor
  hint nothing can honour.

- DP-2 (a058dd3) **an unindexed filter or order is diagnosed, not refused.**
  The grammar refused one on the reasoning that a scan "works on twelve test
  rows and stops working at fifty thousand" - asserted, not measured. Measured
  at 100,000 rows: an unindexed `order by ... limit 10` costs 5.6ms against
  0.03ms indexed, and a filter on a common value costs nothing either way
  because the limit stops the scan early. Five milliseconds is noise beside
  forking a CGI, and refusing would have made every author of a thirty-row
  table declare an index and run a migration to sort by name. **A table big
  enough to hurt has outgrown SQLite rather than outgrown the query**, and
  DP-7 is where that goes. What survives is the diagnosis: a read that actually
  exceeds the threshold logs the page, the binding, the elapsed time and the
  field to index. The data endpoint now uses the **same parser** as a page
  binding - it built its own options and applied different rules, which is
  SM476's shape on a second door.

- DP-2 (b26b4d1) **the generated-query grammar, and snapshot as the default.**
  Filters, ordering, paging, `.count()` and `.field()` scalars, and the three
  modes. Every `db:` binding used to mark its page LIVE - rendered per request,
  never cached - which made a price list on a home page cost a database read
  per visitor, a performance cliff nobody opted into. Snapshot is now the
  default and `mode=live` is the opt-in. A snapshot registers no dependency,
  because there is nothing to depend on: the store is written through WAL, so a
  row can change without the database file's timestamp moving, and a dependency
  that cannot detect a change reports a freshness it never established.

- SM476 resolved (e9517b3) **every declared table was readable by anyone.**
  A page bound to a table inherits the page's gate; the data endpoint is
  reached by its own URL and inherited nothing, so it was a second door to the
  same rows with no lock on it. An operator who put a table behind a gated
  section had tested the page, watched it refuse, and reasonably concluded the
  data was protected. Two controls now: `public:` in the descriptor decides
  whether an anonymous visitor sees rows and **defaults to false**, and an
  `acls.json` read list decides which accounts and groups do, in a file ACL's
  own shape and store. The enforcement is structural - `read_rows` will not
  answer without being told who is asking - because "each surface remembers to
  check" is exactly how this went wrong.

- SM477 resolved (bc2a650) **a plugin declared an action it could not serve.**
  Clicking Status in the Plugin Manager returned a usage string, addressed to
  whoever typed the command; nobody typed one. The manager invokes an action as
  `--scan` unless it declares `run => 'action'`, and the data plugin declared
  neither while implementing only the latter. No test saw it because nothing
  had ever invoked a plugin **the way the manager does** - the one path an
  operator uses was the one path never exercised.

- DP-3 write half (211b514) **a write needs an account, and `writable_by`
  finally means something.** It had been in the descriptor since DP-1 -
  validated, exported, named in the MCP tool's documentation - and read by no
  code at all, so an operator writing `writable_by: [editors]` was given a
  promise nobody kept. It narrows only: widening would make a YAML file a grant
  of capability, and that file can be written over MCP.

- SM473 resolved (f7ec238) **a `db:` page variable rendered nothing, silently.**
  The API returned three rows and the same table on a page returned none. The
  processor is module-free by design and carries no global `@INC` bootstrap -
  every other lazy-loading site in it finds the module tree first, and
  `resolve_db` did not. **Every test passed because `prove -l` puts `lib/` on
  `@INC`**, so the require succeeded in every test and failed on every real
  install; a harness that supplies something production does not is a harness
  testing itself. The failure was caught and logged, so a visitor simply got an
  empty list - the silence was the defect rather than the require. A table
  declared and never migrated now logs too: `pending_schema` renders
  identically to an empty table, and nothing rendering is the hardest failure to
  notice on a live site.

- SM474 resolved (f7ec238) **a JSON boolean was refused, and misdescribed.**
  `{"live": false}` answered *"a value cannot be a list or mapping"* because
  `ref $v` is true for a `JSON::PP::Boolean`. Strings, integers and even `"yes"`
  were all accepted, so the one representation a JSON client naturally sends -
  which is to say what every agent sends - was the only one rejected. Unwrapped
  before anything else looks at it, so a boolean sent to a text field is now a
  type error with the right message rather than a shape error with the wrong one.

- SM475 resolved (f7ec238) **a token client could change state with a GET.** The
  POST requirement lived inside the cookie branch, whose comment explains it in
  CSRF terms - true, and particular to browsers, which made the rule particular
  to browsers too. An authenticated GET of `data-migrate` returned 200 and ran.
  CSRF is not the only reason: a state-changing action reachable by GET is
  prefetchable, retried by intermediaries that believe GET is safe, and lands in
  logs and history as a URL that travels. Hoisted above the channel split, and
  `t/lint/14` now asserts it sits there.

- SM472 resolved (c118e40) **an unmet dependency said so, instead of answering
  500 - and enabling a plugin now checks.** Reported from edge: every descriptor
  save returned HTTP 500. The cause was `YAML::PP` absent on the host, and the
  symptoms were three honest answers that together said the wrong thing -
  `list_data_tables` fine (it globs filenames and never reached the parser), a
  call with no descriptor answering correctly (the parameter check runs before
  the `require`), and everything else a die, which in a CGI is a 500. Nothing
  anywhere said the module's name. Now every `require` of a declared module is
  checked and reports the module **and a package that provides it** - including
  on the read path, which the render path calls, so a die there was a
  visitor-facing 500. **And enabling a plugin verifies its declared
  dependencies**, refusing if any are absent: ADR 0009 already has a plugin
  declare what it needs and the SBOM gate already reads that list, but nothing
  read it at the moment an operator asks *can this work here*. Refused rather
  than warned, because a warning leaves a plugin that is on and does not work.
  The check reads the plugin's own declaration, never a list in the manager,
  which would go stale the first time a plugin gained a dependency.

- SM471 reporting half (65f5e14) **a capability added after a site was created
  never reaches it.** Reported from edge: *you cannot grant `manage_data` - you
  do not hold it*. The manager group is seeded **once**, with the capabilities
  that existed that day, and `_ensure_manager_group_caps` returns early when the
  group already has an entry - so no later release backfills, and every
  capability added since is absent from every site created before it,
  permanently. `manage_data` is simply the first new capability since the seed
  was written. **`lazysite-check` now names them, says why they are absent, and
  gives the exact command.** Reported rather than repaired on purpose: the code
  cannot tell *this did not exist when the group was made* from *an operator
  turned it off*, and re-granting something somebody removed is worse than
  telling them about something they are missing. `api` and `mcp` are excluded -
  SM127 keeps manager groups off the remote channels, so their absence is the
  design and flagging them would cry wolf on every site.

- DP-8 (0cd0162) **the data plugin is documented** - `/docs/data-tables` for
  operators and `/docs/ai-briefing-data` for assistants, both linked from the
  docs index. Two audiences, two documents, because they need different things:
  an operator needs to know what a refusal means and where the store lives, and
  an agent needs to know which call to make and what will be refused before it
  makes it. **`t/lint/80` checks the names, not the prose** - whether an
  explanation is good is a judgement a test cannot make, but whether
  `save_data_table` is a real tool is not, and that is what goes stale first: a
  rename lands, the gate stays green, and the docs describe a door that no
  longer opens. It checks both directions, since a tool nobody documents is one
  an agent does not know it has - SM457's under-claiming defect wearing prose.

- DP-3 read half (2b1f7a8) **a page's own JavaScript can read a table**, through
  an endpoint that **verifies its own caller**. The front door routes
  `lazysite-*.pl` but wraps only the processor and manager-api, so a direct-CGI
  plugin sees `X-Remote-User` exactly as the client sent it - trusting it would
  be SM402's defect reintroduced *by specification*, which is why SM411
  extracted the session verifier. So the endpoint deletes every `X-Remote-*`
  that arrives, verifies the session cookie itself, and sets the identity from
  what it verified; a disabled account or a revoked session is anonymous, not
  its former self, because a cookie outlives both. **A missing table and a
  forbidden one answer identically** - distinguishing them tells an anonymous
  caller which tables exist. `no-store`, because what a visitor may see depends
  on who they are. **GET only**: a read endpoint that accepts POST invites a
  write to be added later without the CSRF question being asked, and the
  `writable=` half is deliberately not in this cut.

- DP-5 (63001d3) **a refused schema change can be made to happen, confirmed by
  name.** `migrate_data_table` refuses a type change, a tightening to required,
  and a dropped column - right as a default and wrong as a permanent state,
  because a refusal with no path through is a dead end and an operator who meets
  one edits the store by hand, which is what the refusal existed to prevent.
  SQLite cannot alter a column, so all three are one operation: build the new
  shape, copy what carries over, drop, rename. **The confirmation names each
  column whose data will be lost**, never a boolean - agreeing to lose one
  column you read about must not agree to a second you did not notice, and
  confirming the wrong name is not confirmation. **A safety export of every row
  is written before anything is dropped**, and its path is returned, including
  on failure. The steps run in a transaction, because half of *drop the old
  table, rename the new one into place* is a site with no table at all. It is a
  **separate action** from migrate rather than a flag on it: migrating is
  routine after a descriptor edit, rewriting a table is not, and one name would
  make the routine call carry the dangerous capability every time.

- SM466 resolved / SM456 partly (edbbad2) **a preview says which layout and
  theme the visitor actually got.** Nothing could confirm that a public page
  renders its own layout: `preview_page` renders through the manager,
  `read_page` returns source, `page_status` reports metadata, and per-Host
  routing is what makes those different questions rather than three views of one
  - the layout is chosen from the Host, so a docroot-shaped tool cannot report
  it. **Not a new mechanism:** `preview_public` already rendered as an anonymous
  visitor under the owning Host (SM441); it had the answer and did not say it.
  It now reports `rendered_layout` and `rendered_theme`, **read from the
  response and never from the configuration** - SM441 was precisely a case where
  the two disagreed and every configuration-consulting tool sided with the
  configuration. An unstyled page reports no layout *and says why*, because a
  missing field reads as "the check did not look". Exposed over MCP as
  `preview_public_page`, so the field can confirm a fix from inside the grant
  rather than by fetching the page - which is egress outside the grant model and
  cannot be attributed to any capability.

- SM461 bug half (797aaff) **an overview that cannot load says what happened,
  instead of blaming the data.** The all-files history overview showed
  *JSON.parse: unexpected character at line 1 column 1* while the data behind it
  was fine - `git-history-summary` returns valid JSON over the API. It parsed
  every response with `r.json()` and no status or content-type check, so a 500,
  a die or a proxy timeout page became a parse error attributed to the content.
  SM445 fixed the 401 case in the shared wrapper; the rest of the class had not
  gone away. **`window.mgJson`** now checks both and reports the status and what
  came back, and the overview is shown again. **The placement half is untouched
  and still open**: seeing it requires the Files app, which is full read and
  write over content, and an auditor who needs to know what changed should not
  need permission to change it - a capability decision.

- SM455 resolved (6e6bf93) **setting up an AI is one flow on one page.** The
  connector card appeared only once an account already held `api` or `mcp`, and
  that comes from group membership set on *another* page - so the job was: go to
  Groups, add the account, come back, find this page showing what it loaded
  before the change, reload, then pick a client. Doing something correct and
  seeing no effect is indistinguishable from it having failed. The picker is now
  shown first, and **the client determines the channel** - web and desktop
  assistants speak MCP, a script speaks the API - so one choice can grant the
  right group. **The grant stays a decision**: the confirmation names the
  account and the group, says what the group grants, says it is the same change
  as ticking it on the Groups page, and goes through the same `group-add`
  action, so the audit entry is identical whichever page was used. A role group
  that does not exist is reported rather than substituted - granting some other
  group that happens to carry the capability would be choosing a permission on
  the operator's behalf. SM100's card is unchanged; it is shown earlier.

- SM465 resolved (80ce0dd) **an `acl-set` records what the rule became, and
  what it stopped being.** The trail recorded that a permission changed, who
  changed it and on what path - and not what it changed to, so the one question
  an audit of a permission change exists to answer was the one it could not. It
  matters more than an ordinary omission because **a rule is not versioned the
  way content is**: the store holds one value, the latest, so the rule in force
  between two changes exists nowhere once the second lands - and that interval
  is what an audit is asked about. **Names are included**, the release manager's
  decision with the trade stated and accepted: account and group names land in
  the audit log, which may carry different retention from the account store; the
  alternative leaves an auditor unable to tell whether the *right* people were
  named. An empty list records as `(unrestricted)` rather than being omitted -
  SM462, where an empty write list means no restriction, so recording it as
  absent would make the trail disagree with enforcement about the most misread
  rule in the system.

- DP-6 (0000e35) **a site package can carry a table's data, opt-in.** Content
  backups exclude `./lazysite` and a package copies content, nav and layout
  only, so a migrated site arrived **without its database and nothing said so**
  (SM410 finding B). Now: `data_tables` names the tables to carry, each exported
  as typed JSON that restores into a fresh database on any engine. **Named
  rather than a boolean, and that came out of the build:** the store is
  instance-wide, so *this domain's data* does not exist, and a flag would have
  swept another domain's tables into the one artefact that travels between
  organisations. **What is left behind is reported** - `data_omitted` counts
  declared tables the package does not carry, the same shape and the same
  reasoning as SM286's `private_omitted`, because a silent omission means the
  receiving operator never learns the instance has tables at all. On apply, a
  table that **already holds rows is refused**, not overwritten: restoring over
  a live product list replaces it with a snapshot from whenever the package was
  built. A named table that cannot be exported **fails the build**, since an
  operator who asked for three tables and silently got two would hand over a
  package they believe is complete.

- SM431 (4ae8d2a, filing only) **permissions are the one part of
  manage_content with a single route.** `get_permissions` and
  `set_permissions` exist on MCP and nowhere else - no control-API action, no
  WebDAV route - so a token grant can create gated content and then have no
  way to inspect the rule governing it. Filed by the field-test account after
  CF-2 shipped, on finding it could not verify the change in either
  direction; its observation that it could not have captured a 0.10.18
  baseline either is the useful half, since it forecloses a before/after
  comparison somebody would otherwise schedule. Explicitly not a request for
  more access: it is four-surface parity work, a fifteenth item of SM430's
  kind. Two ways to close it, and the filing is straight about the trade -
  control-API actions put permissions on the same footing as the rest of the
  capability and carry a real blast radius; an MCP server for that one host is
  the cheap answer and leaves the gap in place. DECISION HELD.

- SM430 provenance (4ae8d2a, correction) **the common-functions survey is
  UNATTRIBUTED.** The brief carries no author line. It names SM422's parity
  map as its evidence base and so descends from it, but the map's author has
  confirmed the survey, CF-2 and the two-write-stacks framing are not theirs
  and checked their own filing to establish it. I credited them in
  correspondence and was wrong; the filing and commit message never carried
  the claim, and the status-note now records "unattributed" explicitly rather
  than leaving a gap that would default to the nearest known author.

## 0.10.25 - EDGE: a table can actually be declared (2026-08-22)

0.10.24 shipped the data plugin complete, and it could not be started. The
descriptor that declares a table lives under `lazysite/`, which every write
channel refuses on purpose, so declaring one needed a shell on the host.

Found while checking the 0.10.24 deployment before handing the feature to a
tester, and worth recording as a testing lesson rather than only a fix: every
fixture had hand-written the descriptor with `open`, so the end-to-end proved
*load and read* and never proved *declare*. The one step with no path was the
one step nothing exercised.

The reserved root is unchanged. What was added is a named door.


- SM470 resolved (b355ae0) **there was no way to declare a table.** The
  descriptor lives at `lazysite/db/tables/<name>.yaml`, and `lazysite` is a
  reserved root: the manager's content paths refuse it, WebDAV allows only
  `lazysite/layouts/`, and no action or tool wrote one. A table could therefore
  be declared only by somebody with a shell on the host, which is nobody this
  feature is for. **Every fixture had hand-written the descriptor with `open`**,
  modelling exactly that operator - so the end-to-end proved load-then-read and
  never proved *declare*, and the one step with no path was the one step nothing
  exercised. A fixture that gives itself access the product does not have is not
  testing the product. Shipped as `data-table-save` and `save_data_table`: a
  named door, capability-gated, writing one kind of file to one place. **The
  reserved root is not loosened** - it holds the account store, the session
  secret and the ACLs. It validates before writing, which a generic file write
  could never have done, and it does not migrate: writing a descriptor and
  changing the stored table are two decisions. Also removes `manage_data`'s
  claim to a WebDAV path the front door denies - SM435's defect, on the plane
  `t/lint/68` guards.

## 0.10.24 - EDGE: DP-1 completes, and the plugin can be turned off (2026-08-21)

Two things 0.10.23 was missing, cut the same evening because neither is worth
waiting on.

**The MCP tool set**, which makes the data plugin usable the way it was
designed: an agent populating a table is its primary use, and 0.10.23 gave
agents only the control API. All six tools route through the same module the
control API calls, so the two channels cannot drift apart.

**SM469** shipped in 0.10.23 and is worth repeating here because it changes a
default: the data plugin is now a *contract* plugin, so it is **born disabled**
and an operator enables it on the Plugin Manager page. That is the right
default for something that holds a site's data.


- SM447 (cfdda13) **the data tables over MCP** - `list_data_tables`,
  `describe_data_table`, `read_data_rows`, `migrate_data_table`,
  `save_data_row`, `delete_data_row`. An agent populating a table is the
  primary use of this plugin, so an API-only surface would have defeated it;
  `t/lint/23`'s temporary one-sided entries are gone and each action is now
  pinned to its tool. All six route through `Lazysite::Manager::Data`, the same
  module the control API calls, so **three surfaces share one implementation**
  - which is also why SM469's enabled gate applies to MCP without any tool
  remembering to ask. The tools are advertised only to a holder of
  `manage_data`: an agent shown a tool it cannot use will call it and read the
  refusal as a fault. DP-1 is complete.

## 0.10.23 - EDGE: the data plugin, end to end (2026-08-21)

The typed data core, its capability, its control-API surface, and a page
binding that reads a table - which together are the minimal end-to-end the
release manager set for this cut: **load data through a channel, see it
rendered**. `t/integration/55` is that sentence as a test: a row goes in over
the control API, and a visitor in a separate process holding a read-only
handle sees it on the page.

Cut as EDGE deliberately. The descriptor format has not met a real site, and
that is what edge is for.

**Not in this cut: the MCP tool set.** Loading works over the control API with
a token, so an agent can populate a table today - it uses actions rather than
tools. The gap is recorded in `t/lint/23` as the one entry whose reason is a
schedule rather than a decision.

Nineteen decisions are recorded in the SM447 filing, D1-D19. Three of them came
from defects the tests found rather than from design: identifiers were
interpolated unquoted so an ordinary column called `table` made a table
uncreatable; `sqlite_see_if_its_a_number` converted stored `"120.00"` back to
`"120.0"` on every read; and a `read_rows` fallback turned a real store error
into "the table has not been created yet".


- SM469 resolved (f113b19, a7e0150) **off means off for a plugin's own control-API
  actions.** ADR 0009's first clause is *off means off - every dispatch path
  consults the enabled state*, and SM409 built that gate. What it covers is
  plugin SCRIPT execution, the `plugin-action` path. The six data actions
  dispatch straight into `Lazysite::Manager::Data` and never consult it, so
  disabling the data plugin changes nothing about them. A second, narrower gap
  in the same function: it treats a plugin as ungated unless its descriptor
  carries a `contract` key, and `plugins/data.pl` declares `owns` per the ADR
  and no `contract`. Found while writing the edge test brief rather than by a
  test, which is the finding: nothing asserts the property the ADR states. The
  durable half of the fix is a lint, and that is what shipped: `t/lint/77`
  discovers which capabilities a plugin owns and asserts that the module
  answering for them consults the enabled state - so the NEXT plugin to own
  actions cannot reintroduce this silently. `plugins/data.pl` now declares
  `contract`, the opt-in the gate reads. **A contract plugin is born disabled**,
  so the data plugin must be enabled on the Plugin Manager page before any data
  action answers - which is the right default for a plugin that holds a site's
  data and has not met a real site yet. Reads are gated as well as writes: a
  read opens the store and runs a query, and *disabled but still answering* is
  the state SM409 exists to remove.

- SM447 (c089348) **a page can read a data table**, which closes the minimal
  end-to-end: load data through a channel, see it rendered. `tt_page_var:
  items: db:products sort=name asc limit=20` resolves through the same
  `Lazysite::Data::Tables` the control API uses, on the handle that cannot
  write. The data modules are required LAZILY, so a site that never writes
  `db:` keeps the processor's module-free property (ADR 0001) - a hand-rolled
  module-free reader would have meant two readers of one store disagreeing
  about what a decimal is. Such a page is marked LIVE and never cached: it has
  no file whose mtime proves it current, because the store is written through
  WAL. **A defect the end-to-end found on its first run:** `Connect` set
  `sqlite_see_if_its_a_number`, which converts stored TEXT `"120.00"` back to a
  number - `"120.0"` - so every decimal lost a trailing zero on every read.
  `"9.99"` survives a round trip through a number, so only a trailing zero
  exposes it, and every unit test had built its own DBI handle rather than
  going through `Connect`. It took a price of 120.00 rendered on a page.

- SM447 (c902386) **the data tables are reachable over the control API**, and
  a reserved word is a legal column name. Six actions - `data-tables`,
  `data-table`, `data-rows`, `data-migrate`, `data-row-save`,
  `data-row-delete` - gated on `manage_data`, with the three writers POST-forced
  and audited and the three reads enrolled as reviewed reads. The row travels
  **nested under `row` in the POST body**, never flattened: a descriptor may
  declare a field called `table` or `key`, and flattening would let a site's own
  data overwrite the action's parameters - silently redirecting a save to
  another table. **A defect found while proving that:** the adapter interpolated
  identifiers unquoted, on the header's claim that its narrow name pattern
  needed no quoting in any dialect. That is true of every character and false of
  `table`, `key`, `order`, `group` and `index`, so an ordinary column made a
  table uncreatable with a raw SQL parse error. Not a security fault, which is
  why every test looking for injection missed it. Identifiers are now quoted in
  the adapter, where dialect belongs.

- SM447 (f210c94) **`manage_data` exists, is grantable, and claims nothing it
  cannot do.** ADR 0009 says a plugin's capability should be discovered rather
  than known by name, and that conformance removes entries from core lists
  rather than adding to them. The runtime cannot follow that literally:
  `caps_for()` is consulted on every request through every channel, and
  discovering capabilities by running each plugin's `--describe` would put ten
  subprocesses on the request path. So the runtime keeps a static mirror and
  **`t/lint/76` does the discovering** - which is the ADR's other sentence read
  exactly, *the contract does not exempt a plugin from the lints, it makes the
  lints discover the plugin's entries*. The lint refuses a mirror no plugin
  claims (grantable in the UI, unlocks nothing, reads to an operator as a
  broken permission), a capability claimed by two plugins, and a declaration
  with no mirror (ungrantable, so the plugin's actions are unreachable).
  **Its `unlocks` lists are empty and that is accurate** - nothing routes to
  the data plugin yet, so granting it admits an account to nothing. Claiming
  actions that do not exist is SM457's defect pointed the other way.

- SM468 (3bf0a30, filing only) **a record of what the schema used to be.**
  Filed alongside the decision that SM447's schema state is DERIVED from the
  database rather than held in a state file. Derivation is a complete account
  of *now* and no account at all of *before*: it cannot say what the shape was
  last week, when a column appeared, or who applied the migration. Nobody has
  asked for that yet, and it becomes a real question the first time a migration
  is blamed for something. Recorded so the question is not rediscovered - and
  recorded with its answer's shape: a TABLE in the store, never a file beside
  it, because a table travels with the rows it describes and a file can be
  restored out of step with them.

- Backlog hygiene (cd6974d) **t/lint/26 could not see most of the changelog,
  and three shipped items had no filing.** Its bullet pattern required the
  commit ref to follow the SM number immediately, so every bullet written as
  *SM442 resolved (...)*, *SM443 partial (...)* or *SM440 follow-up (...)* was
  invisible - 89 of 265, and the house style for anything that is not a plain
  ship. It hid exactly what the test is for: SM442's own status-note opens
  "PARTIALLY SHIPPED" while its status field said `candidate`, uncaught since
  0.10.20. Widened, it also reported that this release claimed SM458, SM459 and
  SM463 with no feature-request doc at all - each fixed straight from a field
  report without the filing being written. All three are backfilled, SM442 is
  `partial`, and the qualifier is word-shaped rather than `.*?` so prose that
  happens to reach a parenthetical still does not read as a claim.

## 0.10.22 - BETA: the second beta, built from what the first one found (2026-08-21)

The point of a beta is that problems found in it get handled rather than
carried, so everything the field reported against 0.10.21 that could be fixed
safely is here. The database plugin is deliberately NOT: it is a major feature
and this release is for stabilising what the estate is already running.

Six of these are one fault in different clothes. Gating MOVES content out of
the docroot (SM286), and every surface that turns an absolute path back into a
key had to learn the second tree. Where one did not, the failure was never an
error - a folder that could not be created, a link carrying
`-lazysite-private/` in it, an index that listed nothing and rendered fine.
SM286's own header warned that resolution and key derivation must change
together; SM460 found two more places where they had not, one of them while
proving the fix rather than by report.

**The changelog itself was wrong and is corrected here.** Ten entries were
sitting under `## Unreleased` describing work that had already shipped: four
copied into their release section with the original left behind, six never
moved at all. So the 0.10.21 section described four fixes while its tag
contained twelve, and this release would have claimed all of them. The entries
are now in the sections whose tags contain them, both earlier sections say so,
and `t/lint/75` refuses both states - a duplicate, and an entry for work a tag
already carries. Neither was visible to t/lint/53 (which ignores `(PENDING)` by
design) or to t/lint/65 (which pins SHA-carrying entries and treats
`## Unreleased` as not a released section).

**And then the correction made the other mistake.** The remaining entries were
stamped with their commits before the branches landed - deliberately, since the
post-release pass is what had missed six of them - but vcs-review lands BY
REBASE, so every one of those SHAs changed on landing. Four entries cited
commits that were nowhere on main. Both of t/lint/53's existing checks passed:
the commits existed, and they were still "on a branch", because the pre-landing
`claude/*` branches had not been deleted. It would have stayed invisible until
somebody deleted them, at which point a published section holds dangling refs.
t/lint/53 now also requires every cited commit to be reachable from `main` -
`(PENDING)` is the spelling for work still on a branch, and that check is what
makes the distinction mean anything. The rule this test's own header states -
stamp AFTER the branch lands - is now enforced rather than described.


- SM467 resolved (f84c550) **a manager group may now CONFER api and mcp,
  while still being unable to use either.** Reported from a new site: the
  setup-manager admin - the only account that existed - could not add anyone to
  `agent-ai`, because joining a group acquires its capabilities and the admin
  group deliberately holds neither channel. It could not repair that itself:
  `grantable` is operator-only to set, correctly, since a delegate able to
  widen its own grant authority has no ceiling at all. Every refusal was right
  and together they left no path. **Holding and conferring are different
  questions and SM127 only bounds the first** - it makes manager groups
  interactive-only so a stolen manager session cannot become a remote channel,
  which is about USE. `grantable` (SM195) is the mechanism for exactly that
  split, so manager groups are now seeded with grant authority for the two
  channels they deliberately withhold. `caps_for()` builds from `@CAP_KEYS`
  alone and never reads `grantable`, so this confers no ability to use either -
  asserted through the resolver every consumer actually consults, because if
  that leaked it would hand every manager group the access SM127 exists to
  deny. Existing installs are NOT repaired: seeding authority into a deployed
  site would widen it silently. Instead the refusals in `group-add`, `token`
  and `claim-create` now name the remedy, matching what `group-settings-set`
  has said since SM195.

- SM467 (2e11e03, filing only) **a `setup-manager` admin cannot grant API or
  MCP access, and the refusal does not say how.** `_ensure_manager_group_caps`
  seeds the admin group with every capability except `api` and `mcp`, and no
  grant authority, so the only account on a fresh site cannot add anyone to a
  group granting either - including the AI-agent group the documentation points
  at. It cannot fix that from the UI either: `grantable` is operator-only to
  set, deliberately and correctly. Reproduced on a scratch install, and the
  remedy verified there: `group-set <admins> grantable api,mcp` from the CLI.
  Two separable questions - whether the seed should include that authority
  (release manager's call), and the refusal naming the capability but not the
  remedy, which is a defect either way.

- SM462 follow-up (d94de3b) **adding a principal now grants read AND write.**
  It defaulted to read-on/write-off, and an empty write list means NO
  restriction - so the ordinary way of restricting a file produced a rule that
  locked reads and left writes open, and an operator was shown *rw* while the
  stored rule was read-only. Read+write **fails safe**: too few people able to
  write is a nuisance, too many is what the feature exists to prevent. The
  per-chip toggles are untouched, so narrowing it back is one visible click.
  **This changes what a click means, not what a rule means** - enforcement and
  every existing stored rule are unaffected.

- SM461 (d94de3b) **the all-files History OVERVIEW is hidden for this release.**
  It fails with a JSON parse error while its data is fine - `git-history-summary`
  returns valid JSON over the API - so the fault is in the page's request or
  handling, and diagnosing it needs a browser. Hidden rather than removed: one
  line, reversible, and the code stays for the edge fix. **The per-file History
  panel is unaffected** and still appears beside each file; that one is a file
  operation and works.

- SM464 filed **an administrator cannot audit a permission they did not set.**
  `acl-get` refuses on ownership and no capability overrides it, so the person
  accountable for an estate's access control cannot read most of it. Left
  unchanged for this beta by decision, with the reasoning recorded - including
  that the workarounds (take ownership, or read the store off disk) are worse
  than the question, and that `acl-set` is audited without the rule's content,
  so the two gaps compound.
- SM463 resolved (a426d1b) **the Edit link carries the docroot key, never a
  server path.** `page_source` stripped `$DOCROOT` off the source path with no
  boundary - and the private store is `<docroot>-lazysite-private`, so for a
  GATED page the docroot matched as a bare string prefix and left
  `-lazysite-private/intranet/tasks/index.md`. The admin bar put that into
  `/manager/edit?path=...`, so a **server filesystem path travelled into
  browser history, bookmarks, Referer headers and screenshots**. The same
  spelling also fails `validate_path`, which joins it back onto `$DOCROOT` - so
  the link opened a **blank editor**. One fault, two symptoms, one fix: it now
  uses `_content_rel`, which requires `$DOCROOT/` WITH the slash before falling
  back to the private root. This is the SEC-2026-07 (H3) superset-sibling shape
  again, with one difference worth noting - there the colliding name depended
  on somebody creating `public_html.bak`; here **the software creates the
  colliding name itself**, so the bad case exists on every site that gates
  anything.
- SM446 resolved (d14b34d) **adding a domain now says TLS is not part of the
  step, and checks.** The add flow provisions a content folder, seeds a page
  and reports success, so every signal said *ready* - and the first thing that
  disagreed was a visitor's browser, on a host whose certificate covered a
  different domain entirely. lazysite does not issue certificates and should
  not; the gap was that nothing said so when it mattered. A successful add now
  states plainly that DNS and TLS are not configured by this step, runs the
  existing `domain-check`, and reports **the check's own wording** rather than
  a restatement. Three things it deliberately does not do: report a failed
  CHECK as a failed ADD (the domain was added), stay silent when the domain is
  fine (silence after a check is indistinguishable from no check), or restate
  a diagnosis that is already better than anything written here.

- SM462 (c99bfdc) **a rule that locks reads and leaves writes open now says
  so**, and **Protected sections describes the folder you are in**. From an
  operator walkthrough of a gated section. They set access on a file, were
  shown *rw*, and the stored rule was `read: ["@agent-ai"], write: []` - then
  found they could SAVE a file they could not PREVIEW. Enforcement was right in
  both directions: an empty list means NO restriction, so a named read list is
  a real gate while an empty write list is none, and the file ended up
  **readable by fewer people than can write it**. The manager's *add a
  principal* control defaults to read on, write off, so the ordinary way of
  restricting a file produces exactly that shape. `acl-set` now warns when
  reads are restricted and writes are not, explaining the empty-list semantics
  that cause it. **Warned rather than corrected**: changing what an empty write
  list MEANS would alter enforcement for every existing rule on every site, and
  whether naming a read list should default writes to the same audience is a
  decision, recorded as one. Separately, the Protected sections panel listed
  every rule on the site; it now shows the folder's own rules **and any rule
  covering it** - hiding the parent would answer *is this protected?* with
  silence when the answer is yes.
- SM460 resolved (029807c) **a `scan:` list can see content in a gated section - and
  still cannot see what the requester may not read.** Gating MOVES content out
  of the docroot (SM286), so a scan inside a protected section found nothing
  and rendered a page that listed nothing, successfully: no error, no warning,
  and an author who reasonably concluded their pattern was wrong. It removed
  scan-driven indexes - blog listings, feature indexes, library pages - from
  protected areas entirely. The ACL filter in `resolve_scan` was already
  written for private entries and had never received one; finding them was the
  missing half. Two faults were found while proving it: the result URL was
  derived by stripping the scan root off the front, and the private root begins
  with the scan root, so a page found there came back as
  `-lazysite-private/...` - SM463's fault in a second place, and the reason
  SM286 warns that resolution and key derivation must change together. The
  file cap also truncated an unordered hash, so a capped listing held a
  different 200 pages each render. Private wins on a collision, so a stray
  public twin lists once, as the governed copy.

- SM459 resolved (5664bfb) **a page can read its own front matter.** A custom
  top-level key was visible to a SCAN of the page and invisible to the page's
  own template: the scan passes non-reserved keys through, the stash took only
  `tt_page_var` plus an explicit list. So the same key was readable by every
  page *except the one that declared it*, and an author wanting one fact in an
  index and in their own layout wrote it twice - top-level for the scan, again
  inside `tt_page_var` - with the copies drifting silently. Custom keys now
  reach the stash as `page_<key>`. **Prefixed and escaped deliberately**:
  SEC-2026-07 (H5) escapes author-controllable front matter at the single point
  it enters the stash, so every layout - including ones we do not ship and
  cannot edit - emits it safely without a `| html` filter, and a bare key could
  collide with a site variable and change what an author already depends on.
  Scalars only. The reserved list is now declared **once** and shared by the
  scan and the stash; two copies would drift, which is the same defect one level
  up and the third time this week (SM435, SM457).

- SM458 resolved (05b0f3b) **the manager can create a subfolder inside a gated
  section again.** An operator could not create `filestore/research` inside a
  gated `/intranet/`: *"Invalid path"*. The same folder went in over WebDAV
  immediately afterwards, so the path was legal and the account could write
  there. Gating **moves** a section out of the document root into the private
  store, and `validate_path` resolves `"$DOCROOT/$rel"`, falls back to
  `dirname()` for a path being created, and `realpath`s that - undef once the
  docroot parent is gone. **The existing containment test is untouched**: it
  carries two CVE-class fixes and the code's own comment warns that widening it
  to span two trees is how a fix gets undone, so this adds a SECOND, separate
  check against the private root - each strict and boundary-safe in its own
  tree. Reproduced here, then confirmed by the operator's two-click test
  (ungated succeeds, gated fails). **It covers FILES as well as folders**,
  though the failure there differed and the difference is worth knowing:
  `realpath` tolerates ONE missing trailing component, so a file directly
  inside the gated root saved even before the fix, while a file one level
  deeper got past validation and failed at the write with *"Cannot write file:
  Permission denied ... run lazysite check --fix"* - a worse message than
  *"Invalid path"*, because it names a cause that is not true and prescribes a
  repair that cannot help. The message was the expensive part either way:
  *"Invalid path"* reads as *you typed it wrong*, so an operator tries other
  spellings of a path that was correct.

- **The ACL warning no longer recommends a remedy that cannot work.** It ended
  *"Name those accounts individually if they need access"*, and that does
  nothing. Measured in the field, then confirmed in the source: a rendered page
  takes its identity from `HTTP_X_REMOTE_USER`, set by the auth wrapper after
  verifying an `lzs_session` cookie, so a partner presenting Basic with an
  `lzs_` token **is not a signed-in user on that path at all** - `$user` is
  empty, and no read-list entry matches it: not a `@group`, not the account's
  own name, not even being the rule's owner. Following the advice cost a round
  of work, produced no error, and left the page still redirecting to `/login` -
  worse than saying nothing, because it ends with the agent doubting its own
  reading rather than the advice. The warning now states the fact, **fires when
  only accounts are named** (it fired on `@group`s alone, so an agent that took
  the advice saw the identical message and could not tell it had been applied),
  and says what still WORKS: the partner reads the same files over WebDAV and
  the control API throughout - only the rendered, signed-in view is gated, and
  if the rule exists to keep the page from public visitors it is doing its job.

- SM457 resolved (c29e749) **a capability that hid its own API.** Reported by a
  third party's agent, working against a live site: holding `manage_forms` and
  looking for submissions, it tried `describe_capabilities`,
  `list_form_handlers`, `forms`, `form_submissions`, `list_submissions` and
  `submissions` - six names, **none of them control-API actions**. The real
  answers are `actions-list` and `form-submissions`. `form-submissions` is
  gated on `[manage_forms, read_submissions]`, either admits it,
  `read_submissions` advertised it correctly, and `manage_forms` carried **no
  `api` list at all** - so a partner was admitted by enforcement and told
  nothing by the descriptor. **This is SM435 inverted**: there the descriptor
  claimed a path enforcement refused, which at least says *no*; under-claiming
  is silent, so the only symptom is the agent's own failure to guess. New
  `t/lint/71` checks every capability's `api` list against the gate and found
  **two more on its first run** - `manage_layouts` and `manage_themes` each
  omitted actions gated on the pair. All three fixed. The lint **fails rather
  than skips** if it cannot find the action table: its first version named it
  `%ACTIONS` instead of `%ACTION` and skipped itself green, which is the same
  defect one layer up.

- **A protected folder says so in its own expansion.** The protection appeared
  only in the "Protected sections" card at the foot of the Files page, so
  answering *is THIS folder protected, and how?* meant scrolling to a different
  card and matching paths by eye. The folder's own expansion now shows the
  policy, who can read it, and what it contains. **The card stays** - it
  answers a different question, *what is protected on this site*. Two things
  the block gets right on purpose: an otherwise-unprotected folder covered by a
  **site-wide rule** says so rather than staying silent, because silence there
  reads as "this folder is open" - a confident wrong answer about whether
  visitors can see something; and the policy is **explained, not just named**,
  since *draft* (hidden outright, 404, absent from sitemap and feeds) and
  *gated* (not-listed visitors are sent to sign in) are the two words an
  operator is most likely to have the wrong way round.

- **The Files page's alias card describes the folder it is under.** It listed
  every alias on the site regardless of where the operator was standing, so a
  site with a hundred redirects answered "which of these belong to the folder
  I am looking at?" by making them read all hundred - and it loaded once at
  page load, so after the first click it described somewhere they had left.
  `aliases-list` takes a `path` and filters to it; the card refreshes on
  navigation and its empty state now says *No aliases point into /x* rather
  than implying the site has none. **The filter is server-side deliberately**:
  the folder-to-URL translation needs the CONTENT ROOT - a page at
  `sites/alpha/blog/post.md` answers to `/blog/post` - which is exactly the
  mapping SM440 got wrong, and a second copy of it in JavaScript could drift
  from this one without anything failing. Containment is boundary-safe, so
  `/blog` does not claim `/blogroll`.

- SM440 follow-up (d01ce58) **a pre-fix alias entry is now cleared, and could
  not be before.** Before the fix, a page under a content root wrote into the
  SHARED map with a docroot-relative target; after it, the same page writes
  into its own domain's map with a site-relative one. Different file *and*
  different key - so nothing the page did touched the old entry. **Measured:
  re-saving left it, and deleting left it.** The shared map is still read for
  the docroot, which is the DEFAULT host, so a stale entry kept answering
  there and serving another site's page under the default domain - and an
  upgrade would have frozen every pre-existing leak in that state, unreachable
  by any content operation. `index_page` and `deindex_page` now also drop the
  one shared-map entry matching that page's old derivation. **Precise, not a
  sweep**: the primary's own aliases live in that file legitimately, and
  clearing more would delete the default site's redirects as a side effect of
  editing another domain's page. Corrects a claim in SM440's own status note,
  which said re-saving would clear these; it would not have.

- **A multi-domain test fixture, because a single-site one cannot fail the way
  this software fails.** Ten defects surfaced in one week of real multi-site
  use with every suite green throughout, and each needed two sites on one
  instance to appear - SM436 needs a domain that is not the default, SM440 a
  neighbour to leak onto, SM441 a domain whose presentation differs from the
  primary's, SM443 one domain that inherits its nav and one that does not. On a
  single site the docroot IS the content root, the Host always matches, and
  "the primary" and "this domain" are the same thing, so the faults are
  unreachable and the tests pass truthfully while describing a shape the estate
  no longer has. `TestHelper::setup_multi_domain_site` builds a primary, three
  domains (one nested inside another's root) and **an unregistered prefix
  sibling** - the last because a registered one proves nothing: longest-match
  picks it whether containment is boundary-safe or not, which let the same
  sabotage pass three separate times here before the fixtures were corrected.
  Verified by re-introducing three of the real defects and confirming the
  fixture fails on each.

- **"Configure domain", not "register domain."** The manager said *register*
  throughout - the button, the sheet subtitle, the confirmations, the API
  errors (`Not a registered domain`), the log lines (`domain registered`) and
  the guides. It reads as domain registration in the ordinary sense - buying a
  name from a registrar - which is not what any of it does: the instance is
  being told to serve a name somebody already owns. Renamed across the UI, the
  API messages, the logs and the docs. `register:` page front matter and the
  generated registries are untouched - a different word doing a different job.

- SM465 (824985b, filing only) **an `acl-set` is audited without saying what
  the rule became.** The trail records that a permission changed, who changed
  it and on what path - and not what it changed to. A permission change is the
  one operation whose effect cannot be recovered from the current state plus
  the log: content has a version history, a rule has only its latest value, so
  the rule in force between two changes exists nowhere afterwards. That
  interval is what an audit asks about. Related to but separate from SM464,
  which is about being unable to READ a rule; this is about not RECORDING one.

- SM466 (824985b, filing only) **no supported way to verify that a public page
  renders its own layout.** SM441's fix is in and tested, and the field cannot
  confirm it on a live instance: `preview_page` renders through the manager,
  `read_page` returns source, `page_status` reports metadata, and none of them
  answers what a visitor to a given Host receives. Per-Host routing is exactly
  what makes those different questions - the layout is chosen from the Host, so
  a docroot-shaped tool cannot report it. Fetching the page directly works and
  proves nothing about the grant: it is egress outside the grant model, and a
  result obtained that way cannot be attributed to any capability. `domain-check`
  is the precedent for answering an outside-world question from inside.

- SM455 (833c869, filing only) **setting up an AI takes two pages, a manual
  refresh, and a choice nobody explained.** Filed from the field: the flow
  spans the Users page and the Integrations page, the second does not show the
  account created on the first until the browser is reloaded, and the operator
  is asked to pick between the `api` and `mcp` channels with nothing on screen
  saying what either means or which their tool needs. Related to SM467, which
  removed the refusal that stopped the flow completing at all.

- SM456 (2053992, filing only) **the field agent's own tooling blocks
  verifications the grant permits.** Filed by the field-test account: several
  checks it is authorised to make cannot be made, because the tools available
  answer a different question from the one the grant allows. SM466 is the
  specific case that keeps recurring - confirming what a visitor to a given
  Host actually receives.


## 0.10.21 - BETA: the multi-site fixes, pulled forward because edge could not test them (2026-08-21)

The four fixes the release manager moved ahead of their edge soak, on the
reasoning that settled it: multi-site behaviour is only exercisable where
multiple sites exist, so soaking them on a single-site edge would have proved
nothing about them. Two of them repair faults that were serving the wrong
site's content to real visitors.

Also carries the release gate learning to say WHICH failure it hit, which paid
for itself within the hour by naming a manifest fault as a manifest fault
rather than as a coverage shortfall.

**The four are what the cut was FOR; they are not all it shipped.** A release
builds from `main`, so this tag also carried the edge work sitting there at the
time - SM434, SM437, SM439 and SM445 below. Their entries were written on their
branches and never moved out of `## Unreleased` by the post-release pass, so
for a day this section described four fixes and the tarball contained twelve.
They were moved here on 2026-08-21 and stamped with their real commits.
`t/lint/75` now refuses the state that allowed it.

- SM439 resolved (f1043c0) **revoking an access key now stops the OAuth grant,
  and the Keys page stops hiding people.** Two halves, both confirmed by
  measurement rather than by reading - the filing recorded them as unexercised
  and said so. **Revocation**: `cmd_key_revoke` blanked the credential in the
  users file and stopped there, and nothing on the OAuth path consults that
  file - `validate_token` and `refresh_access` read
  `lazysite/auth/oauth.json` and an expiry. A probe issued a token, blanked
  the credential exactly as the revoke does, and watched the access token
  still resolve **and the refresh token still mint a replacement**. So
  "revoke" left access running for up to an hour and renewable for thirty
  days. New `OAuth::revoke_partner` drops both halves of every grant for that
  partner and `key-revoke` reports how many. **Listing**: `keys-list` skipped
  interactive accounts, so a human holding `webdav` - HTTP Basic, replaying
  their password per request, creating no session - appeared on the Keys page
  never and on Sessions only while a cookie was live. They are listed now,
  flagged `interactive` with their channels; the `interactive` field already
  existed in the row and was unreachable behind the skip. **Note for
  operators**: a manager in `manager_groups` holds `webdav`, so managers now
  appear here. That is the intent - the page is meant to show everyone who can
  reach the site - not a side effect. Revocation is unchanged and still
  refuses an interactive account: listing is not offering.

- SM437 resolved (09066ae) **the domain's content folder is picked, not typed.**
  The create sheet now offers a drop-down of folders that EXIST, defaulting to
  `sites/`, and names the child folder from the host - so the operator chooses
  a parent and types nothing that can be misspelled. The derived path is shown
  and follows the host field as it is typed, because a surprise at submit time
  is too late. `domain_add` already creates-or-adopts, so nothing new was
  needed underneath. **The failure it removes is quiet**: any clean relative
  path is valid and gets provisioned, so a typo produced a domain pointing at a
  new empty directory - the site served, with nothing in it, and the intended
  content sat one directory away under the name that was meant. A
  "Somewhere else…" option keeps the text box reachable, because the picker is
  a default rather than a cage.

- SM434 resolved (009f0f7) **something finally reports the RUNNING version.**
  `/.well-known/lazysite-instance.json` now carries `version`, read from the
  install state - what the installer actually wrote, rather than a VERSION file
  in a source tree that may not be the one serving. Nothing served reported
  this, and two agents in a row reached for `<meta name="generator">` instead,
  which answers a different question and answers it **correctly**: that meta is
  baked in at RENDER time and cached with the page, so it reports the build
  that produced the artefact. A page rendered under an older build and still
  cached is not stale - it is describing itself accurately. The misreading was
  durable because an upgrade re-renders every shipped page while preserving the
  operator's own `index.md`, so the one page keeping an old render is the
  homepage - the first page anyone checks after an upgrade. This endpoint is
  never cached, so it can answer honestly.

- SM445 resolved (300ed27) **an expired session says so, instead of the button
  doing nothing.** Reported from the field: *"the submit button did nothing. i
  refreshed and discovered session expired. i had no information to say that,
  it just felt like it has failed."* It did nothing because every manager page
  posts through `fetch(...).then(function (r) { return r.json(); })` with no
  status check and no `.catch()`; a 401's non-JSON body makes `r.json()`
  **reject**, the rejection is unhandled, and neither the success nor the error
  branch runs. The pages have an error branch for this and it was unreachable,
  because the failure happened before the branch was chosen. The shared layout
  `fetch` wrapper - which every page already goes through for CSRF - now
  notices a 401 and shows a persistent banner with a **Refresh now** button, on
  GET as well as POST, since a page that loads its list after the session
  lapsed was just as silent as one that submits. Fixed in the wrapper rather
  than in 96 call sites across 12 pages: a fix in one place cannot be
  half-applied. **403 is deliberately untouched** - a refusal with a real JSON
  body that the pages already report, where "sign in again" would be wrong
  advice.

- SM436 completed (da03302) **the diagnostics half: an unmatched Host leaves a
  trace, and a preview names the Host it used.** The validation shipped earlier
  prevents new instances; this is the half that would have made the existing
  one findable, and that is where the afternoon actually went - all three
  diagnostics agreed the configuration was fine. The processor now logs one
  line when a Host matches no configured domain and the default answers, on
  instances that declare `alias_hosts` at all, so a single-site install stays
  quiet. `preview_public` returns `rendered_as_host`; `domain_preview` returns
  it too **and says what it therefore cannot tell you** - it feeds the STORED
  key back in as the Host, so it agrees with the configuration by construction
  and cannot detect a name no real request carries. Naming the Host does not
  fix that blind spot, and nothing at preview scope can; it stops the answer
  being read as one it did not give.

- SM444 resolved (6ed7ead) **a failed coverage gate says WHICH failure.**
  `release.sh` mapped every non-zero exit from `coverage.sh` onto one sentence,
  "coverage below the declared floor". The 0.10.20 build failed that way and
  coverage was never the problem: `coverage.sh` had exited before reaching the
  floor comparison, so neither its per-file table nor its `COVERAGE BELOW
  FLOOR` marker appeared, and the message named a cause nobody had
  established. It cost a 45-minute instrumented re-run and then a second full
  build to find all eight files comfortably above their floors. The gate now
  captures the child's output, keys on that marker, and reports a **floor
  breach** and a **run that did not finish** as the different problems they
  are - the second saying so explicitly and quoting the tail of the run.
  Output is captured to a file rather than through `tee`, whose exit status
  hides the child's; `t/tools/34` asserts that trap and this must not
  reintroduce it. New `t/tools/58` covers both stand-ins, including exit 137 -
  SIGKILL, the OOM case that is the leading candidate for what actually
  happened to 0.10.20. **The captured log lives BESIDE the staged tree, not
  inside it**: the first attempt wrote it to `$STAGE/` and the next step
  refused, because `build-manifest.pl` classifies every file in the stage and
  will not ship an unclassified one - so the honest-reporting change broke the
  build it existed to make diagnosable, and the new message is precisely what
  said so ("manifest build failed", naming the file). `t/tools/58` guards it.

- SM443 resolved (6b3e978) **a nav save cannot fall back to the shared file.**
  The destructive half of SM443, held from the last cut and pulled forward
  because multi-site behaviour is only exercisable where multiple sites exist.
  An operator set a domain's `nav_file`, confirmed it with `nav-read`, called
  `nav-save` naming that host and **replaced a neighbouring site's
  navigation** - a site handed to another party that morning. The host had
  travelled in the query string while `nav-save` read it from the body, so
  `$host` arrived empty and `_nav_conf_path('')` resolved to the shared
  `lazysite/nav.conf`. **The audit trail corroborated the mistake rather than
  catching it**: `_audit_implicit_target` already read the query host, so the
  log recorded `nav (<the domain>)` for a write that went to the primary's
  file. Two changes. The dispatcher now takes `host` from either place
  (`query_or_body`, as `acl-set` already did), so it cannot go missing in
  transit. And an absent or unusable host no longer means "the shared file":
  a host that **inherits** its nav is refused with the fix named, an
  **unregistered** host is refused rather than falling through, and no host at
  all still edits the primary deliberately. Sabotaged four ways, including
  restoring the body-only read.

- SM436 resolved (b9dd1fb) **a domain cannot be registered under a name no
  request can carry.** A domain registered as `dhcf`, with `site_url`
  `https://dhcf.sites.lazysite.io`, never matched: the processor compares the
  FULL `Host` header with `eq`, so no alias overlay applied and every request
  fell through to the primary - **serving a different organisation's site
  under that name**. Every diagnostic agreed the configuration was fine.
  `domain-preview` renders correctly because it feeds the STORED key back as
  the Host; `domains-list` shows a complete record; `domain-check` blamed DNS
  because it faithfully resolved the literal string. `domain_add` now refuses
  a single-label host, and refuses a host that disagrees with the hostname in
  its **own `site_url`** - both halves of the answer were already in the row,
  and comparing them costs one regex. `domain_set` applies the agreement check
  to `site_url` edits but **not** the dot check: an existing dotless row cannot
  be corrected (`host` is not in `@DOMAIN_KEYS` and there is no rename verb),
  so removal is the only route and `domain_remove` must keep working on
  exactly those rows. For the same reason the checks are NOT folded into the
  shared `_valid_host`, which would have stranded every existing bad row.
  Sabotaged four ways; the placeholder case initially passed against its own
  sabotage and the fixture was corrected before it was trusted.

- SM440 resolved (3cf1048) **an alias belongs to the site that declared it.**
  Two defects that compounded. `index_page` took a DOCROOT-relative path and
  handed it to `canonical_url_for`, so a page under a content root produced a
  target carrying the prefix the vhost strips at request time; and the map was
  one file per INSTANCE, so whatever it produced answered on every domain.
  **Field-confirmed, and the combination was worse than either half**: on its
  own host `/thesis` 301'd into a 404 - making the alias worse than none - and
  on the default host, an unrelated site, the same 301 returned **200 and
  served that site's page under a neighbour's domain**, because the default's
  content root IS the docroot so the leaked path resolved. It matters more
  than the page count suggests: the standing conversion rule gives every
  retired URL an alias on its successor, so every site converted onto a
  content root carried aliases redirecting into 404s - exactly the URLs
  inbound links use. Targets are now derived relative to the serving site, and
  each content root gets its own map at `lazysite/aliases/<key>.json`. **The
  docroot keeps `lazysite/aliases.json` unchanged**, so a single-site instance
  reads and writes the file it always did and nothing migrates. The processor
  reads the map for the host being served; `aliases-list` takes a `host`.
  Sabotaged three ways - fixing either half alone fails.

## 0.10.20 - EDGE: what a week of real multi-site use turned up (2026-08-21)

The first cut after the beta promotion, and every fix in it was found by
running actual sites rather than by a test. Ten filings and four fixes, and
the pattern across them is one cause in different clothes: the manager reasons
in DOCROOT terms while the site is served in per-HOST terms. Each was found by
a different symptom, by a different person, within hours of the estate growing
past one site per instance - while every suite stayed green.

Cut as EDGE. The channel flag was omitted from the build invocation; the
release manager elected to keep it rather than rebuild, and the beta follows.

Two entries below - SM432 and SM433 - were written on their branches and never
moved out of `## Unreleased` by the post-release pass, so this section
under-reported what the tag contained. Moved here and stamped on 2026-08-21.

- SM433 (c7736ae) **regenerate-registries cleared a path the server stopped
  reading.** SM293 step 3 moved the generated registries out of the document
  root into `lazysite/cache/registries/`; the invalidator was not moved with
  them and went on deleting `<root>/<name>`. So the control reported
  `cleared_roots`, cleared nothing a visitor sees, and the artefact stayed
  stale for its full four-hour TTL - measured in the field as two regenerate
  calls with no change to the served sitemap, which they could not diagnose
  from outside and which turned out to be neither of their two hypotheses.
  **The second defect is worse and nobody had filed it**: since SM293 the
  server returns early when `<root>/<name>` exists, because an operator may
  write their own sitemap as content - so the path being deleted had become a
  supported home for operator content, and a routine regenerate would have
  destroyed a hand-written registry with no warning. Fixing the first without
  noticing the second would have left data loss behind a newly-working
  control. Now: cache artefacts cleared, the in-docroot file never touched,
  and any shadowing file reported by name with a note explaining why
  regenerating cannot change what is served while it wins. **Three tests had
  agreed with the code about the wrong place** - t/unit/manager/21,
  t/unit/manager/55 and t/unit/mcp/18 each seeded a registry at the docroot
  path and asserted its removal - which is why this survived from SM293 to a
  field report: each was written beside the code it tested and inherited its
  assumption, so the suite confirmed the invalidator did exactly what it did,
  to a file nobody serves. All three now seed and assert the served location,
  with every property they existed to prove left intact.

- SM432 resolved (6e29f15) **/docs/features serves again, by becoming an
  index.** `starter/docs/features.md` moves to `starter/docs/features/index.md`.
  The page was an index of the directory shadowing it, and `canonical_url_for`
  maps `foo/index.md` to `/foo`, so the published URL is unchanged - no alias,
  no redirect chain, no front-matter edit (the three `tt_page_var` scans are
  absolute and target subdirectories, so the index cannot list itself).
  **Chosen over rename-plus-alias for a reason the deploy supplied rather than
  taste**: when 0.10.19 reinstalled `features.md` onto the edge host mid-edit -
  the code-bucket overwrite the original filing predicted, confirmed within the
  hour - the reinstated file came back shadowed by a directory that now has an
  index, so it was inert and the site kept working. Under rename-plus-alias the
  same reinstall restores the 404, because the alias lives on a page the
  installer does not know about. t/lint/67's exclusion list is now empty, and
  its own guard fired for real: it refuses an exclusion naming a collision that
  no longer exists, so removing the entry was part of this change rather than a
  follow-up. **Severity amended in the filing and worth reading here**:
  `starter/lazysite/nav.conf` line 9 ships `All features | /docs/features`, so
  this was a broken DEFAULT NAV ITEM in the chrome of every page of every fresh
  install - not, as first filed, one row in a sitemap. Confirmed independently
  on a fresh 0.10.19 starter install. The acceptance test is now "install
  fresh, follow the nav link, land on a page".

- SM435 resolved (1300e7e) **manage_config no longer advertises two files it
  cannot write.** 0.8.1 moved `lazysite/nav.conf` to `manage_nav` and
  `lazysite/forms/<name>.conf` to `manage_forms` over WebDAV, wrote both new
  descriptor entries, and never trimmed the old one - so the descriptor
  promised a partner holding `manage_config` alone a write `authorise()` would
  refuse. **Nothing was over-permitted**: enforcement was always the strict
  side. The cost is that the descriptor is the ONE per-capability account of
  the boundary readable from outside the code - a partner cannot determine
  which capability grants an access by experiment, because the only instrument
  available reports the union of everything they hold - so a wrong descriptor
  sent an agent to a 403 and then to trial and error, which is what RI-002's
  deny reasons exist to end. New `t/lint/68` checks the two sides against each
  other in the one place a partner meets both: every WebDAV denial names its
  capability, so the deny reason is enforcement's own statement of the rule.
  **It asserts SET EQUALITY deliberately** - a membership check passes against
  this exact defect, because `manage_nav` does list `nav.conf` and the surplus
  entry is invisible to it. Sabotaged both ways before being trusted: an extra
  claim and a missing claim each fail it.

- SM442 resolved (9f94a45) **regenerate-registries reports what it CLEARED, and
  MCP stops answering differently.** `cleared_roots` was built from
  `_registry_roots()` - the roots CONSIDERED - so a call that removed four files
  and a call that removed none returned the same thing, and every early return
  in the invalidator was invisible to the caller. The response now carries
  `cleared_files` and `cleared_count` from the actual unlinks. **This is the
  report that turned a diagnosable condition into an afternoon**: zero files
  against seven roots is a finding, visible in the first response. Separately,
  MCP's `regenerate_registries` called the invalidator and composed its own
  answer, so it reported no `cleared_files` and - worse - no
  `shadowed_by_files` at all, SM433 having added that warning to the control
  API only. It now routes through the shared `action_regenerate_registries`,
  the same one-implementation reasoning SM301 and SM318 settled for other
  pairs. Sabotaged before being trusted: restoring the roots-based count fails
  three of the new subtests.

- SM443 partial (5b006df) **a per-domain nav file is writable over WebDAV.**
  The carve-out tested `$rel eq 'lazysite/nav.conf'` - an exact match on one
  filename - so a domain whose `nav_file` was set to `lazysite/nav-<site>.conf`
  had a navigation file NO surface could populate: `nav-save` writes the shared
  file, and WebDAV fell through to the blanket `lazysite/` denial. `domain-set`
  accepted the setting anyway, and because layouts guard on `[% IF nav.size %]`
  the visible result was a site with **no navigation** rather than an error.
  WebDAV now admits any path lazysite.conf declares as a `nav_file`, base or
  per-domain, still gated on `manage_nav`. **Bounded by configuration, not by
  pattern alone**: the value must have the nav-file shape
  (`lazysite/<name>.conf`, no traversal, no subdirectory) *and* be declared by
  the operator - this branch returns ALLOWED before the scope, blocklist and
  ACL gates run, so the shape check is a boundary rather than a tidy-up.
  `lazysite/lazysite.conf` is excluded explicitly, or setting `nav_file` would
  become an escalation. Sabotaged three ways before being trusted; dropping the
  exclusion lets the test overwrite `lazysite.conf`, which is the point of it.
  **The destructive-default half of SM443 is NOT fixed here** - an absent host
  on `nav-save` still silently means the shared file.

- SM441 resolved (42f6e3c) **a page preview knows which site it is previewing.**
  Both page-scope previews - `action_preview` (Files/editor) and
  `preview_public` (SM282, "as a visitor") - shelled the processor without
  setting `HTTP_HOST`, so SM151's per-Host routing never fired and a domain's
  page rendered with the BASE layout, theme and nav. The content was right and
  the presentation was another site's, which reads as a page given the wrong
  theme rather than as a preview that has not been told which site it is. An
  operator who happened to open the manager on the domain's own host saw a
  correct preview, which is what made it intermittent. `domain_preview` (SM238)
  always did set it - its own comment describes shelling "exactly like ...
  `action_preview`, but with `HTTP_HOST` set" - so the difference was
  understood and applied at domain scope only. New
  `Domains::host_for_path` resolves the owning domain, **longest content root
  wins**, with boundary-safe containment so `sites/one` cannot claim
  `sites/one-archive`. Two domains on one content root are **not** silently
  resolved: the tie is reported so a caller can offer a host selector, and the
  pick is deterministic meanwhile. Sabotaged four ways; the containment case
  initially passed against a bare-prefix sabotage and the fixture was made
  adversarial before it was trusted.

- SM432 (e031a7d, filing only) **/docs/features is published in the sitemap
  and 404s.** A page and a directory share a name: `features.md` serves, the
  leaf pages under `features/` serve, and the canonical extensionless URL -
  the only one sitemap.xml advertises - is shadowed by the directory and lands
  on a 404. **It ships**: both sides exist in the tracked starter payload, so
  every site installing the docs inherits it. The 301 carries
  `charset=iso-8859-1`, so the front end is answering and no engine-level test
  can see it - the same blind spot the outside-in probe exists for. Found when
  the reporter wrote a sweep tool, ran it against their own earlier filing and
  was contradicted by it: they had measured the redirect and assumed its
  target, taking the version from the rendered error page. They corrected the
  promotion record before it was quoted, which is why SM413's wording now
  says 33 of 34 without a gloss. Nothing changed: renaming either side moves a
  published documentation URL and needs an alias on whichever name loses,
  which is a release decision rather than a drive-by fix. A sweep of the whole
  shipped payload found this is the ONLY such collision, so it is one decision
  rather than a class - and t/lint/67 now fails on a second one, listing this
  one by name with its reason so the exclusion is a deliberate act rather than
  a silence. The lint also fails if the known collision is resolved and left
  in the list, because an exclusion for something that no longer exists is how
  a list stops describing the tree.

- SM434 (e031a7d, filing only) **nothing reports the running engine version -
  and SM413's premise was wrong.** The `<meta name="generator">` version is
  read from the install state and baked into the HTML AT RENDER TIME, so a
  cached page reports the version that produced it. That is correct: honest
  metadata about the artefact, not a symptom. A homepage rendered under
  0.10.18 and still cached on a 0.10.19 host is accurately describing itself.
  The durable part of the misreading: a render is served while its html mtime
  exceeds its source's, an upgrade OVERWRITES every shipped page so those
  re-render by themselves, and the operator's own index.md is PRESERVED
  precisely because it is operator-edited - so the one page that keeps an old
  render is the homepage, which is also the first page anyone checks after an
  upgrade. **The real gap**: `/.well-known/lazysite-instance.json` returns
  instance and host and no version, and nothing else served reports one - so
  "did the upgrade take" has no honest answer, and two agents independently
  reached for a number that answers a different question correctly. Suggested
  fix is one field on that endpoint. A second, larger render-invalidation
  change built on the wrong premise was stopped before it landed; the 0.10.18
  one stands on its own merits and its filing now says which.

## 0.10.19 - BETA: the promotion, and the fixes the field drove into it (2026-08-20)

The first build promoted off the edge line. It carries a confidentiality fix
found by a code survey rather than by a failure - moving protected content to
an ungated path relocated the bytes into the public docroot with no rule
following them - plus the ACL store that locked the manager out once per
deploy, and the certified channel wired end to end after a corpus review found
it could pass its own compliance gate and then die at manifest build.

Tier A moved to gating STABLE rather than beta in the release before this, so
this promotion rests on field evidence: whole-sitemap render sweeps, an
upload check from outside, and a scoped-grant history probe, each run by the
account that could actually reach the surface in question.

- SM430 (e53bf03, filing only) **common functions across the four surfaces.**
  A four-track code survey, filed as fourteen independent packages (CF-1 to
  CF-14) with per-package tests and dependencies. The structural finding:
  there are **two write stacks, not four** - the manager UI, control API and
  MCP already share `lib/Lazysite/Manager/*`, while WebDAV re-implements the
  chain inline under a header comment claiming a "no-shared-modules policy"
  that the architecture docs no longer contain. Current policy is the
  opposite, so the fork is maintained by a comment rather than by a decision,
  which is why every parity defect this week has had a WebDAV side.
  **CF-2 carries a confidentiality consequence and should not wait for the
  structural work**: verified here rather than taken on report - DAV resolves
  gated paths into the private store, and its move handler contains no ACL
  code at all, so moving protected content to an ungated destination
  relocates the file into the public docroot with no rule following it.
  Accidental publication through an ordinary operation, and the exact inverse
  of SM286's rule that protecting content moves it. The mirror defect is in
  the same package: the manager's delete has no ACL cleanup while DAV's does,
  so a comment claiming "the manager's delete has always done this" is
  factually wrong and SM212's stale-rule fix never reached three surfaces.

- SM413 (e53bf03, filing closure) **confirmed from outside, and closed.** The field
  verified the render fix across the whole public sitemap on the deployed
  0.10.18: 34 pages fetched cold, 33 reporting the current build, with no hand
  invalidation. (The 34th was CORRECTED by the reporter before it reached a
  promotion record - it redirects to a page that 404s, not to one reporting
  the version; see SM432. The substance is unaffected, and the 404 page
  itself rendering as 0.10.18 arguably strengthens it.) The homepage that
  survived four deployments on a 0.10.13 render now reports the current build
  on its own, and the asset busting tokens moved with it.
- CF-2 / SM430 (158625c) **the rule goes with the content, on every surface.**
  Deleting content must drop its rules and moving it must carry them; both
  were true on ONE surface each, in opposite directions. DAV's DELETE dropped
  ACL entries under a comment saying "the manager's delete has always done
  this" - it never did, so SM212's fix reached one surface out of four and an
  entry outlived the file it governed, meaning a file created later at the
  same path was born governed by a rule nobody set. **The move half carried a
  confidentiality consequence**: WebDAV resolves a gated path into the private
  store, so a MOVE to an ungated destination physically relocated the bytes
  into the public docroot - and with no re-key, no rule followed them.
  Protected content became public through an ordinary operation, silently, and
  that is the exact inverse of SM286's rule that protecting content moves it.
  One definition now (`forget_path`, `rekey_path`), with the store sync left
  to the caller because where the bytes go is a store decision with its own
  companions; DAV re-keys THEN syncs, in that order, because the destination
  tree was chosen before the rule moved. Four sabotages bite - including one
  that only failed once the fixture grew a sibling key whose name merely
  STARTS with the deleted one, the same boundary trap validate_path documents.

- SM429 (5d6fcca, filing only) **cross-origin-opener-policy has never been
  emitted.** The one line that survived the field's 0.10.18 header pass - its
  CSP half was retracted after re-measurement, the policy being served
  correctly under the report-only name on HTML pages and correctly absent on
  non-HTML paths. COOP is a gap rather than a regression: the string appears
  nowhere in the tree, on any path or version. Filed with the two interactions
  that make it a decision rather than a default - the manager opens the site
  in a new tab in two places, and the instance is an OAuth authorisation
  server whose connector flows are popup-shaped and depend on the opener
  relationship. Recommendation if wanted: `same-origin-allow-popups` on HTML
  responses, which isolates the document from whatever opened it while leaving
  windows it opens able to reply - paired with a test that opens the real
  authorize page, since the failure mode is a partner's browser flow breaking
  and no processor-level test can see that.

- SM428 (a888a3e) **the ACL store locked the manager out, once per deploy.**
  `save_acls` wrote 0640 while `lazysite-check` requires the file to be
  group-writable - the store is written by two identities on a group-shared
  docroot (the site user via `acl reapply`, the www-data CGI via the manager's
  permissions UI), so 0640 left it readable but not writable by whichever one
  had not just written it. The deploy's ACL re-apply dropped the mode and the
  health pass repaired it, **so the only trace was a repair that ran every
  single time** - visible in the 0.10.17 and 0.10.18 deploy logs alike, and
  read as housekeeping rather than as a writer disagreeing with its own
  checker on a schedule. Between the two steps an operator's permission change
  silently failed to save, and an operator running an ACL verb without a
  following health run stays in that state. Now 0660, matching the sibling
  auth files in the same group-writable list and the 2770 directory they live
  in; no world bits either way. The test asserts group-write and no-world
  rather than a literal mode, and pins that the checker still lists the file -
  the two drifting apart is the defect itself.

## 0.10.18 - EDGE: the round the reviews drove (2026-08-20)

Almost every item here came from outside this session: a security-review
agent's round-3 pass, a field-test agent's beta-readiness measurements, a
method-corpus review of the day's own ADR, and an operator's deploy log. The
CRITICAL is SM418 - a file upload confined on the request string rather than
the path, which overwrote the cookie-signing secret and reported success.

Three of the fixes uncovered further defects while being built, all of the
same family: a rule enforced in one place and not its twin. And three of the
findings were in work landed hours earlier in this same session, caught by
gates rather than by review - the certified channel that could not cut, a lint
blind to the entries it did not pin, and a config key that reached the page but
not the reader.

- Tier A (2b2f343) **the four manual checks gate STABLE, not beta.** They gated

- Tier A (2b2f343) **the four manual checks gate STABLE, not beta.** They gated
  beta for one day; the amendment is a judgement about what each channel means
  rather than a relaxation. Beta is bedded in by people who know they are
  running a beta - the operator's own sites and partner instances - and holding
  it on a manual walk delays the exercise that makes the walk worth doing.
  Stable is where a build reaches sites that did not choose to be early, and
  that is the promise these four stand behind. The work is unchanged and still
  owed; what moved is which promotion waits for it. `MANUAL-CHECKS.md` and the
  register both say so, and the register still records each round against the
  version walked so a stable cut can point at the walk that cleared it.

- SM423 (687dc43) **the certified channel is wired end to end.** ADR 0010
  wired every place that CONSUMES a channel and missed the two that PRODUCE an
  artefact carrying one, so `release.sh --certified` would have died at
  manifest build - after passing the compliance gate it exists to run, which
  is the most expensive place to fail. `build-manifest.pl` and
  `build-apt-repo.sh` now accept the rung; both starter docs teach four
  maturities (including the Manager UI string on the Config page); and
  t/tools/43's exhaustive matrix covers certified as both a site channel and a
  release channel, so it is exhaustive again rather than reading as though it
  were. **The reporting gap became its own fix**: t/lint/65 now refuses any
  `(PENDING)` entry inside a released section. It pinned only SHA-carrying
  entries, and t/lint/53 ignores PENDING by design, so a misfiled pending
  entry - claiming a release contains work that has not shipped - was
  invisible to both. The new check found two real ones on its first run.
  Alongside: **SM416 was incomplete and a parity lint said so** -
  `asset_max_age` reached the Config page's schema and config-set's write gate
  but not config-read, so the page could not display the value it was offering
  to change. t/lint/18 exists for exactly that asymmetry and caught it in this
  run.

- ADR 0010 (bff8861) **a certified channel above stable, and the conformity
  gates attach there.** The ladder becomes edge < beta < stable < certified
  (%CHANNEL_RANK 0/1/2/3, release.sh --certified, update_channel accepts it).
  "Stable" had carried two meanings - release.sh itself described it as "the
  certified customer-rollout channel" while the first stable line shipped with
  a pentest waiver and an unsigned declaration, so the label was already
  untrue in practice. Now stable means SUPPORTED SOFTWARE and certified means
  the compliance records were WALKED: the declaration, restore-rehearsal and
  register gates block a certified cut and are advisory everywhere below - so
  future stable cuts stop being hostage to paperwork on its own timeline,
  which gives the deferred-but-tracked compliance work a home with a name.
  One implication implemented rather than left implicit: **a certified cut
  forces signoff_required on** - the channel IS the statement that the
  records were walked, and a switch left at 'no' must not mask the findings
  the label claims (the switch keeps its voluntary meaning below certified).
  The dated obligations are unmoved: 2026-09-11 and 2026-12-31 bind the
  project, not a channel. t/tools/57 proves the MOVE in both directions
  against the tree's real records - a stable cut passing under the documented
  protocol where it used to block, certified refusing despite the switch -
  with three biting sabotages, one of which caught the test itself asserting
  the rehearsal's TEXT where it had to assert the FAIL line.

- SM426, SM422 store gate (bba73d4) **the probe runs itself, and a store is a
  store wherever it is configured.** The outside-in ACL probe refuses as root -
  correctly (SM377: protecting content there leaves root-owned files in the
  site tree) - but that refusal ended every root deploy with "run the probe as
  the site user", so the one check measuring gating the way a visitor meets it
  is the one an automated deploy never got, and SM366 records it has never run
  from the field at all. It now drops to the site's registered owner with
  `sudo -n`, exactly as `upgrade --all` already does: the same mechanism, on
  the one command that declined to use it. Only when root and the owner
  differs; `-n` never prompts, so a missing sudoers entry fails loudly instead
  of hanging a deploy, and the probe's own skip reason survives where the drop
  is unavailable. Separately, the submission read gate keyed on the fixed
  `lazysite/forms/submissions/` prefix while the control API resolved through
  the configured-store allowlist - so with a handler storing under the content
  tree, a manage_content-only grant was refused the default store and SERVED
  the configured one. One definition now, failing safe to the default prefix
  if the handler config cannot be read, because a store that cannot be
  enumerated must not become a store that is ungated.
- SM421 (f4fe95f) **the surfaces agree: permission is the control.**
  `manage_forms` could already name a delivery destination directly over
  WebDAV and through the control API's form-targets-save (which explicitly
  accepts and preserves inline targets) - only MCP's `bind_form` was
  handler-only, so the same grant was strictly weaker on one surface and an
  agent delegated form-building had to ask an operator for something its own
  capability could do elsewhere. Per the release manager's ruling - permission
  decides whether the functionality is available, and where granted every
  surface delivers it in full - `bind_form` gains an optional `target`
  ({type: webhook|api, url} or {type: file, path}), mutually exclusive with
  `handler`, which stays preferred and is still described that way because it
  is operator-vetted and holds credentials. Validated for SHAPE, not
  destination: unknown types, missing or non-http URLs, traversing paths and
  newline injection into the config are refused, while which URL a form may
  deliver to is the operator's decision - expressed by whether they granted
  the capability. `smtp` is deliberately not offered inline: it needs a
  credential the legacy parser cannot carry, so it would be a target that
  silently fails to deliver. **SM427 is FILED, not shipped**, and follows from
  the ruling: if the grant is the only decision point, the grant screen has to
  say what a capability reaches - facts, not warnings.

- SM423, SM424, SM425 (8512f54, filings only) **three inbox briefs assigned
  refs.** SM423: the certified channel is HALF-WIRED - ADR 0010 wired every
  place that consumes a channel and missed the two that produce an artefact
  carrying one, so `build-manifest.pl` and `build-apt-repo.sh` both still
  reject the fourth rung and the first `--certified` cut would die at manifest
  build, AFTER the compliance gate it exists to run has passed. Found by a
  method-corpus review hours after that work landed. It also caught a gap in
  t/lint/65, written in this same session for this same class: it pins entries
  carrying a SHA and says nothing about `(PENDING)` ones, so a misfiled PENDING
  entry is invisible to it and to t/lint/53 alike. SM424: the visitor stats
  page renders every block at once, and the auto-blocker belongs in Plugin
  Config rather than on the stats page where its evidence happens to appear.
  SM425: exempt signed-in users from the anonymous submission rate limit
  (unblocked by SM411, since the handler can now obtain a verified identity)
  and extend the `:::form` field rules SM401 started.
- SM426 (c884de3, filing only) **the ACL probe refuses as root, and the tool
  already knows how not to be.** A routine root deploy ends `NOT CONFIRMED ...
  run the probe as the site user`, so the one check that establishes gating
  from OUTSIDE is the one an automated deploy never gets. The skip itself is
  right and stays (SM377: protecting content as root leaves root-owned files in
  the site tree). What is missing is that `lazysite-cli.pl` already records
  `owner=` per site and already drops to it with `sudo -n -u` for `upgrade
  --all`, under a comment calling that "the only place root is allowed" - so
  the probe is the one command asking an operator to do by hand what its
  sibling does for itself, and an instruction printed at the end of an
  automated deploy is a step that does not happen.

- SM413 located (2fa1aaf, filing update only) **the homepage was a durable
  render-cache entry, four releases stale.** Field-diagnosed on edge: / served
  a 0.10.13 render through the 0.10.14, .15, .16 AND .17 deployments, with
  headers correctly forbidding intermediaries to serve stale - the engine
  re-served its own artefact - until a manual index invalidation brought every
  page to 0.10.17. What remains is a decision, not a mystery: does an upgrade
  invalidate rendered pages, and if deliberately not, where is the operator
  told to do it? Beta-gating, with the release manager. The site agent's
  0.10.14-0.10.16 homepage-dependent validation conclusions are flagged
  unconfirmed and being re-run; their three-page version probe (written after
  the FIRST stale-render incident) is what caught it.
- SM416 (4b8c3b6) **the asset cache lifetime is the operator's dial.** The
  lazysite front end revalidates every asset on every page view - deliberate
  (SM387: protection must reach already-fetched copies) but sized by the field
  at ~6 engine round trips per view, a real multiplier on contended hosting,
  and the layouts briefing still taught the stock template's ten-year/?v=
  advice as if it were universal. `asset_max_age` (site setting, seconds)
  trades a BOUNDED staleness window for browser caching; the DEFAULT is
  unchanged, because the revalidation posture was chosen, not accidental, and
  the operator picks the number knowingly with the cost spelled out in the
  setting's note. ACL-governed assets stay no-store whatever the dial says -
  and the sabotage matrix caught the test proving that against the WRONG
  emission site (the anonymous refusal path) until it made an authorised
  request. The layouts briefing now names which front end each piece of
  caching advice applies to, per the field filing's own suggestion.
- SM418 (777321f) **CRITICAL: a file upload escaped the content area into the
  auth store.** `action_file_upload` confined on the request string rather than
  the path - the one file-write handler that never called `validate_path` - so
  `..` survived to the write while the blocklist string-matched a spelling that
  could not match it. Reproduced against the real handler: an upload overwrote
  `lazysite/auth/.secret`, the cookie-signing key, and returned `ok:1`. An
  authenticated UNSCOPED `manage_content` editor could mint operator sessions
  from it; token partners, MCP and scoped accounts were never able to reach it.
  Reported with a working reproduction against the real handler by the SECURITY-REVIEW agent's round-3 pass.
  Three fixes: uploads route each accepted filename through `validate_path`
  (which also closes an unfiled second exposure - uploads always wrote
  publicly, so an upload into a gated section half-published it past SM286);
  the `%file_surface` carve-out gate was keyed `upload` while the dispatched
  action is `file-upload`, so it had never run for a single upload; and
  `t/lint/15` - the parity lint that exists to catch precisely this - listed
  five handlers in Files.pm by hand and knew nothing of Upload.pm, so it now
  DISCOVERS every file-writing handler and fails until each is classified
  guarded or exempt-with-a-reason - which was the reporter's own third
  suggested fix, not an addition of ours. The lint is proven to catch the pre-SM418
  world in both its shapes.
- SM417 (8a86b71) **a visit is one actor, not one address.** The visitor token
  is hmac(ymd|ip), so every agent on a shared host - and every person behind
  one NAT - shared a single visit: the field measured a deliberate four-page
  walk arriving merged into one 22-step trail. Sessions now key per source
  (token + user-agent), the same separation SM392 gave the promotion key.
  COUNTING IS UNCHANGED: unique_visitors stays on the bare token, because one
  person with two browsers must not become two visitors. Counting basis bumps
  to 3 (SM338) - visit counts RISE on shared-address traffic and the day file
  says it counts the new way, so the step in the series is attributable to
  rules rather than traffic. **A latent gap fell out of it**: SM392 added
  `pkey` to the first-party ingester only, and every consumer falls back to
  the bare token when it is absent - so per-source promotion had silently
  never happened on any site whose stats come from the web server's own log.
  Only the sabotage matrix found it, because until the test grew a server-log
  fixture, deleting `pkey` from that record broke nothing. **And a second of
  the same family**: `scanner_by` is written under the promotion key and was
  read under the counting token, so on every first-party site since SM392 that
  lookup missed and `scanner_inferred` was silently 0 - an operator could not
  tell a behavioural promotion from a signature match, which is the only thing
  that field is for. Both hid in the same blind spot: the sweep test drives
  the server-log ingester and the trail tests drive the first-party one, so a
  defect in either was invisible from the other.
- SM413 fix (4fb7a36) **an upgrade invalidates rendered pages.** A cached page
  regenerates when its SOURCE changes and an upgrade changes no source, so a
  page nobody edits kept its pre-upgrade render indefinitely - the field
  measured a homepage serving a 0.10.13 render through FOUR deployments,
  corrected only by a manual invalidation. The installer already knew the
  rule: its ROLLBACK path dropped rendered HTML for exactly this reason and
  the UPGRADE path did not, so one helper now serves both. Deliberately
  narrow - only rendered `.html`, never the cache tree, because the per-host
  mirrors and other cache state have their own lifecycles and this is a
  re-render trigger rather than a reset; pages re-render on next request, so
  the cost is one render per page actually visited. Same-version reinstalls
  are excluded on purpose: those renders already came from that code.
- SM419 (78f0d23) **the content-history summary ignored scope - and the fix's
  own grep ate its first element.** Every per-file history operation resolves
  through `_git_target`, which blocklists and scope-confines; their site-level
  summary did neither, so a partner refused one tenant's history was handed
  that tenant's filenames, revision counts, dates and last authors by the
  overview beside it, plus engine paths a direct read refuses. Metadata only,
  and benign on a single-tenant site. Fixed on both channels with the totals
  RECOUNTED - a count that disagrees with its own list tells a scoped caller
  how many files it is not being shown - and an unscoped operator unchanged.
  **The sharper find is the one it uncovered**: `is_blocked_config` ->
  `upload_limits` -> `load_upload_limits` reads its config with `while
  (<$fh>)`, assigning the GLOBAL `$_`, so calling it inside a grep destroys
  the element under test. `upload_limits` memoises, so only the FIRST call in
  a process clobbers - the first element of the first such grep comes back
  empty and every later one is fine, a corruption a second run hides. `local
  $_` fixes it and the test asserts the predicates against a plain grep,
  because any caller can hit it. A survey found 19 more subs of the same shape
  across the tree; filed separately, none proven live, and the difference
  between latent and live is one caller.
- SM420 (b80376e) **twenty subs that ate their caller's `$_`.** `while
  (<$fh>)` assigns the GLOBAL `$_`, so a sub reading a file destroys the
  element under test when called from inside a `grep` or `map`. SM419 hit one
  of them and lost the first path of a filtered list; a survey of lib/, the
  root scripts and plugins/ found twenty in total, all now carrying `local
  $_;`. **Nineteen are not proven live** - each needs a caller reaching it
  from inside a grep, and none was traced - and they are fixed anyway because
  the difference between latent and live is one caller and the fix is a line
  that cannot break a caller who was not using `$_`. What makes the class
  worth a lint rather than a note is the memoisation: only the FIRST call in a
  process clobbers, so the symptom appears once and never reproduces - a
  corruption nobody debugs, because a second run passes. t/lint/66 bans the
  shape outright.
- SM421, SM422 (139fdf3) **the cross-surface parity map: two fixed, one real,
  three held.** From the security-review agent's round-3 mapping pass over the
  control API, MCP and WebDAV. FIXED: MCP's nav READ was gated on
  manage_content while WebDAV, the API and MCP's own set_nav all require
  manage_nav - the tool was declared path_aware but passes no path, so the
  carve-out gate never reached the capability that owns nav.conf; and the
  vestigial `lazysite/themes/` carve-out is REMOVED: it exempted a store no
  engine code has ever resolved (88f16b4 added it in one batch with layouts/
  and nav.conf on the assumption it was a third real area), so it was an
  under-gated write path waiting for the first feature to use the name. The
  existing test asserting the carve-out is inverted - it was written in that
  same commit and encoded the same assumption - and the code names the check
  an operator can run: `ls -la <docroot>/lazysite/themes/`. **SM421 is the one that was
  more than cosmetic**: WebDAV accepts a raw write of a form config on the
  stated grounds that it "only names which operator-defined handlers a form
  dispatches to" - but the parser still accepts a legacy inline format
  declaring a delivery target directly, so a manage_forms holder can point a
  form's submissions at an arbitrary webhook, which the structured verbs on the
  other surfaces do not permit. Verified by driving the real parser and
  dispatcher; the three ways to close it differ in compatibility cost and one
  can break a live site, so the decision is held. F3, F5 and F6 stay open with
  the verification each needs recorded, because acting on an unverified parity
  claim is how a consistency fix becomes an outage. Alongside: the agent-facing
  deny list now QUALIFIES the submission store instead of listing it flat -
  WebDAV refuses it for everyone, but MCP and the control API treat it as a
  capability-gated carve-out reachable to read_submissions or manage_forms, so
  an operator reading the list (or testing it by listing the directory, which
  is refused) concluded the store was unreachable to partners when it is not.
  The entry stays because WebDAV enforces it; the note beside it makes the list
  true, and t/integration/06 now pins the two rendered qualifiers word-for-word
  as it already pinned the lists - a note that drifts is the defect it was
  written to fix, one level down.

## 0.10.17 - EDGE: the beta candidate, built from the field's own findings (2026-08-19)

Cut the same evening its contents landed, from an overnight round driven
almost entirely by a partner agent's field passes: the multi-domain apply that
refused (SM412), the classifier that could not be asked (SM392), the two
features that silently require JavaScript (SM414/SM415, filed with decisions
held), the publish-flow trap (set_permissions), and the quantified stale-render
data (SM413). The landing was rehearsed before it happened - all ten branches
merged in a scratch worktree with a full gate over the result - and the
rehearsal caught four integration defects no per-branch test could see,
recorded in their own entries. Gate: 467 files, 8,470 tests; the manifest's
`validated` block names b03bece.

- SM414, SM415 (1cac06b, filings only) **two of the three interactive features
  require JavaScript, and the third proves they need not.** From the site
  agent's beta-readiness field pass on 0.10.16. Search: a results page is
  byte-identical for a real query and a nonsense one - ?q= is never read
  server-side, a 73KB index filters in the browser, no noscript - so search
  results are invisible to crawlers and to no-JS visitors, silently. Forms: the
  handler answers application/json with HTTP 200 for BOTH outcomes and the form
  carries a native action/method, so a no-JS post lands on raw JSON as a page.
  Login is the in-product counter-example - 302s, next preserved, no cookie on
  failure - which is why both read as fixable rather than inherent. Decisions
  HELD: the cache posture a server-side ?q= needs, where a native form post
  lands, and whether either gates beta. Neither is a regression; both were
  measured for the first time. The agent's method note is preserved in SM414:
  its first assertion PASSED on the word "Authoring" in the navigation menu -
  an expectation-based body check passing on chrome while the feature did
  nothing; a differential comparison of the two bodies told the truth.

- SM414, SM415 (1cac06b, filings only) **two of the three interactive features
- Docs (36abb3f) **set_permissions names the publish flow.** A field agent set
  a read list on a draft section and it kept 404ing: the tool is a PARTIAL
  update - omitted fields keep their value - so granting access does not clear
  draft, and the API equivalent of the Publish button is `{"draft": false}`
  alongside the grants. The semantics were already documented on the `draft`
  parameter and were right; what was missing is the composite named where the
  trap springs. Tool description + ai-connector-tools.md; behaviour unchanged,
  deliberately - auto-clearing draft on a grant would be the tool guessing an
  intent it was not given.

- SM407, SM408 (c810e38, a9f7093; filings only) **three records stopped in the same
- SM413 (2880069, 0de5231; filing only) **the homepage reports a version three releases
  old.** On edge.explore, `/` reports 0.10.13 while every other page reports
  the current build, surviving releases and cache clears - counted by the site
  agent across three releases, cause not established. Possibly the same
  mechanism as SM371's cache-clear-surviving canonical. Filed with the
  assembled observations, a suspects list from the cache work's prior art
  (marked as prior art, NOT evidence), and the three read-only questions that
  discriminate between suspects. Investigation owned by the release manager;
  the beta promotion record carries either its explanation or an explicit
  waiver citing this ref.
- SM409 (fc13d40) **disabled means off - for plugins that opt in.** The
  plugins: list used to drive only the Plugin Manager listing (its parse lived
  inline in action_plugin_list, consumed by nothing on any execution path), so
  an operator who disabled a plugin changed a page, not the site. Per the
  release manager's ruling: plugins declaring the ADR 0009 `contract` are
  gated and BORN DISABLED; legacy plugins are untouched until each one's
  migration SM replicates its current effective state, so nothing in the
  field changes behaviour on upgrade. plugin_enabled() is exported for
  direct-CGI plugins to self-check at entry - the data plugin is the intended
  first caller. Config read/save stay open on a disabled plugin (an operator
  configures before enabling), and hooks are deliberately ungated: on_disable
  runs right after the conf loses the entry - the plugin's sanctioned last
  run, its one chance to stop what it started - and a hook gate would have
  refused exactly that cleanup (caught during implementation). Driven by two
  real fixture plugins whose action writes a witness file, so ran/refused are
  facts on disk; three sabotages bite.
- SM412 (7d9d67d) **the apply's safety snapshot scopes to the target.** On a
  multi-domain instance, site_apply to a content-rooted domain snapshotted the
  WHOLE docroot - including the primary domain's tree, which the calling
  account could not read and the apply would never touch - so the apply was
  refused with permission denied while site_backup of the same domain
  succeeded 26 seconds later, because site_backup scopes and the snapshot did
  not. Field-diagnosed by the partner agent it blocked (edge2.explore);
  SM378's carried detail is what made the diagnosis possible from outside.
  action_backup_create gains an optional docroot-relative root, the apply
  passes its target content_root, and the snapshot now covers exactly the
  blast radius of the operation it guards; the primary keeps the whole-content
  snapshot and 'full' refuses a scope by definition. The scope validates like
  any path input - and the test's first version asserted bare refusal of
  traversal, which a DELETED validation also produces (tar fails on a missing
  dir); the case that matters is traversal to an EXISTING outside directory,
  which without validation succeeds and archives foreign content into a
  self-service-downloadable backup. The sabotage matrix caught it; the test
  forces that case and asserts the refusal comes from validation.
- SM371 close-out (6f1989b, test only) **the 402 fix stops shipping untested.**
  The 0.10.14 validation found `/402.html` carrying a visitor-supplied query
  string in its canonical, pointing at the payment-gated page the visitor had
  just been refused - and the changelog admitted the fix shipped untested,
  which the pre-beta review flagged. t/integration/57 already proved the
  sanitiser on 404 and 403; it now drives the FIELD case itself: a
  payment-gated page requested with a poisoned query string, asserting no
  canonical in the served body OR the cached 402.html - and the sharper
  property underneath, that request-controlled bytes never persist into the
  shared cache file every later visitor receives (the cache-poisoning shape,
  not an SEO nit). Sabotage-verified against the pre-SM371 state: with the
  sanitiser call removed from serve_402, the subtest fails.
- SM392 follow-through (070b29a) **the classifier is askable.** Testing the
  `ai` class from outside needs a clean visitor token, and an agent that has
  done ANY probing cannot get one until its token rolls at UTC midnight - the
  partner agent doing the field validation measured that as one clean run per
  day, and it invalidated an eleven-agent classification test. `--classify
  --path PATH [--ua UA] [--status N] --docroot DIR` answers from the same
  classify(), the same compiled rules and the same stats.conf overrides,
  writing no log line and NO STATE - the test drives that with a recursive
  before/after listing on a fresh docroot, after its first version snapshotted
  a fixture other subtests had already polluted and a write-on-every-call
  sabotage passed. Line-level only, and the output says so: `scanner` is a
  visitor-level promotion computed over a day of traffic, and a tool implying
  a verdict it never computed would be the SM377 class. The status-gated SM192
  rule (SPA-manifest probe is noise only on 404) is asserted in both
  directions, and operator overrides are proven honoured by sabotage.
- SM407 (8e1ba22, docs only) **the feature timeline catches up.** FEATURES.md's
  Part XIII gains the seven missing release entries, 0.10.10 through 0.10.16 -
  the compliance gate had been warning `newest release entry is 0.10.9` since
  the 0.10.16 cut, and the content was current while the per-release framing
  was not, so a reader could not tell whether the file described the build they
  were running. The synthesis anchor at the foot moves to v0.10.16. NOTE FOR
  LANDING ORDER: t/lint/62 and t/lint/63 are red on main because v0.10.16 is
  tagged while its changelog section and version bump sit on the post-release
  branch - land claude/0-10-16-post-release first and the tier goes green.
- SM411 (b03bece) **one verification chain, in one module.** Session-cookie
  verification moves from lazysite-auth.pl into Lazysite::Auth::Session
  (beside the CSRF tokens it shares a secret with), and the wrapper delegates.
  Extracted because SM410's audit found the data endpoint would repeat SM402's
  defect by spec - routed by the front door but NOT wrapped, trusting
  X-Remote-User as the client sent it - and self-validation beats wrapping
  because wrapping needs fleet template edits, whose staleness SM374 measured.
  THE RISK OF EXTRACTION WAS QUIET WEAKENING: auth.pl carried TWO verifiers,
  the full chain in the wrapper and a SUBSET in _session_identity that skipped
  the disabled-account and revoked-session checks; packaging the subset would
  have handed every future caller the gap. The module carries the FULL chain -
  parse, HMAC, both SM141 payload shapes, expiry, SM071 disabled, SM141
  revoked (sid and not_before), and SEC-2026-07 M5's fresh group resolution -
  and _session_identity now delegates, making logout STRICTER: a disabled
  account's logout is the unauthenticated no-op path (the cookie still
  clears), and a revoked session cannot re-revoke itself. Verification is
  READ-ONLY - it never mints the secret; minting stays with login. One
  incidental honesty fix: the wrapper's "cookie valid" log line used to show
  the cookie-baked groups while the header carried the fresh set; it now logs
  what is granted. t/unit/auth/14 drives every stage with real state files
  and three sabotages confirmed to bite: the subset packaged, groups from the
  cookie, and a verify that mints.

- SM409, SM410, ADR 0009 (c216586; planning only - no engine code) **the typed
  data layer is audited and mapped, and the plugin contract has a direction.**
  The two inbox briefs (data plugin + full-screen data manager, 1,089 lines)
  audited against the tree with every "CC confirms" marker resolved. Two spec
  claims corrected before they could become rework: "site_backup already
  captures the SQLite store" is true only for FULL backups - content backups
  exclude ./lazysite and site packages copy content/nav/layout only, so a
  migrated site would silently arrive without its database; and the endpoint's
  "CSRF per the manager-api pattern" assumed an identity it would not have -
  lazysite-data.pl would be routed but NOT wrapped, the SM402 defect
  reintroduced by spec, resolved by extracting Lazysite::Auth::Session (SM411,
  closing SM402's open item) so the endpoint self-validates. ADR 0009 records
  the sequencing decision: plugins declare what they own and disabled means
  off, with the data plugin built as the contract's first conforming
  implementation and existing plugins migrating post-stable - a contract
  extracted from one demanding plugin beats one designed in the abstract and
  retrofitted seven times. SM409 files the fix pulled forward: **a disabled
  plugin still runs** - the plugins: list drives the listing, not execution -
  which is the recurring reports-one-thing-does-another class applied to the
  plugin system. Briefs archived; BACKLOG's database-plugin sketch superseded
  (its per-visitor schemas are exactly what the settled boundary excludes).

## 0.10.16 - EDGE: the build says which commit it validated (2026-08-19)

The first cut to carry SM400's provenance: `release-manifest.json` holds
`validated: {commit, files, tests}` naming the exact gated commit, and
`docs/releases/GATE-LOG.md` gained its first real row. It took two cuts: the
first failed its gate in a subtest named for a race it never forced (SM406,
fixed in this release), and the cause of that one failure is recorded as
unproven rather than assumed. Alongside: three writers that renamed torn files
over good ones, an identity the form handler recorded but could not verify,
form rules for structured answers, and six standing decisions recorded where
they belong.

This section was written after the tag rather than before it - the 0.10.15
prep pattern was missed at cut time, and a partner agent reading the deployed
changelog noticed the gap before we did.

- SM406 (06566c4) **a subtest named for a race it never forced.** The 0.10.16
  edge cut FAILED its gate in `t/unit/manager/60`, subtest 5, and `release.sh`
  correctly refused to release - nothing tagged, nothing built. That subtest,
  *"backups taken in the same second"*, took two backups back to back and hoped
  they landed in the same second: `_claim_name` stamps from `gmtime` at call
  time and each call tars a fixture tree, so a pair straddling a second boundary
  gets a fresh stamp, no `-N` suffix, and a correct engine fails the assertion.
  It never ESTABLISHED the condition its own name describes - the same class as
  a fixture whose non-ASCII string was secretly ASCII. The collision is now
  constructed: the subtest occupies the filename this second would produce, then
  asserts the next free suffix is claimed, with a bounded retry for the clock
  ticking mid-claim. The two properties are separated because they need
  different setup - names never collide however the clock falls; the suffix
  needs a real collision.
  **The cause of the gate failure is NOT established, and this entry does not
  claim it.** A full serial re-run, exactly as `release.sh` invokes it, PASSED
  against the unmodified test, so the failure is intermittent and seen once. The
  diagnostics were lost because the release was piped through `tail -40` - my
  error on a 70-minute run, and the process fix (capture to a file, tail the
  file) matters more than the test fix.

- SM404 (9bd8093) **three writers renamed a torn file over a good one.**
  `_write_json_atomic` was atomic in the rename and not in the write: it checked
  neither the print nor the close, so a write that ran out of space produced a
  TRUNCATED temp file, the rename promoted it over a good one, and the function
  returned 1. The processor's page-cache writer has had checked print AND checked
  close since SM020 - the pre-beta review praised it for exactly this - and the
  three stats writers never gained it. **Worst for the durable store**: day files
  are written once and never rewritten, so a torn day file is permanent where a
  torn cache merely rebuilds. One of the three was added by SM393 days earlier,
  written to match the local style, which is how a defect becomes the house
  pattern. Now one checked writer and one rename in the file, with the count
  asserted. `t/unit/plugins/17` drives a REAL failed write via `ulimit -f` and
  asserts what is left on disk; its first version used `/dev/full`, failed at
  OPEN rather than at the write, and **both check-removing sabotages passed
  against it**. It carries a second case sized to fail only at the FLUSH, because
  with a large payload print fails first and a writer checking print but not
  close would otherwise pass.

- Decisions (a3cfc7f) **six standing questions answered, and one stale count.**
  SM405 files the visitor-class model as DECIDED and not built - seven classes
  rather than five, because an assistant fetching a page for a person is a visit
  and a training crawler is not, and today both land in `ai`; and where a
  DECLARED identity disagrees with observed behaviour, **behaviour wins**, or
  `agent-declared` becomes an opt-out for attackers. SM272 is CLOSED: the
  operator holds the signing key and publication stays manual, so no publishing
  credential reaches the build host. SM281's last open question is answered - a
  notice gains an optional `to`, and one without it stays broadcast, so nothing
  that emits a notice today has to change. `docs/compliance/SIGNOFF.md` records
  keeping `signoff_required: no` for the beta promotion as a **decision rather
  than an inherited switch**, and notes that the two CRA obligations falling due
  2026-09-11 are unaffected by it either way. The manual-check register records
  that all four tier-A checks run before promotion - and `MANUAL-CHECKS.md` said
  "Three checks" while listing four, having never been updated when A4 arrived
  with the 0.10.10 pickers, so a reader counting them would have stopped one
  short of the one with access-control consequence.

- SM402 (4b5fe69) **the form handler recorded an identity it could not verify -
  and the filing had the exposure in the wrong place.** `form-handler.pl` is not
  behind the auth wrapper, so `HTTP_X_REMOTE_USER` reaches it exactly as the
  client sent it. SM402 said an operator would see a spoofable name in a
  submissions list. **They would not**: every delivery target - file, SMTP,
  webhook, and the separate form-smtp plugin - skips `_`-prefixed keys, so
  `_auth_user` never reached a stored record, an email or a webhook. It was
  DEAD. Checking that found the live one, which the filing missed: the same
  unverified header went into the **actor column of `lazysite/logs/audit.log`**,
  the shared trail that manager-api, dav, mcp, oauth and the users tool write to
  with an identity they HAVE verified - a forged name sitting indistinguishably
  beside real ones, in the one artefact whose purpose is to say who did
  something. So dropping only the dead field would have looked like the fix and
  left the live one in place. The handler now reads **no** identity from the
  request: a public submission has no verified actor and is recorded as having
  none, while the submitting address is still audited because that is the fact
  actually known. Nothing is lost - `auth_proxy_trusted` is consulted by the
  PROCESSOR, on the request the processor handles, so there was no configuration
  under which this script could have trusted the header. `t/unit/forms/07`
  asserts the header is not read, the audit entry carries no actor, the address
  is still recorded, and the delivery targets still skip `_`-prefixed keys - the
  property that made the dead field harmless.

- SM400 (93bdcb3) **a release records which commit it validated.** The gate's
  summary went to a terminal and to `tmp/gate-result.txt`, which is gitignored,
  so nothing durable said what had been gated - a promotion review reached "the
  build that would go to beta is not the build that was validated" and nothing
  cheap could disprove it. Two records now: `release-manifest.json` gains a
  `validated` block (commit, files, tests) so the ARTEFACT attests its own gate,
  and `docs/releases/GATE-LOG.md` answers the same question for whoever has the
  repo rather than the tarball. release.sh reads prove's own summary and
  **refuses to release if it cannot**, because a blank row looks like a record.
  No `result` field: release.sh exits before that line on failure, so it could
  only ever say PASS. The sharp part is the pipe - `if ! ( ... | tee f )` tests
  TEE's status, which would have made the release gate a control that reports
  success without checking; `set -o pipefail` fixes it and `t/tools/34` asserts a
  failing stand-in is refused **with a control** showing the naive form would
  have passed.

- SM401 (340d6f3) **form rules for structured answers, and two silent losses.**
  From an inbox filing: an office team answering ~300 structured questions whose
  shape - "which of these, and how many of each" - the field vocabulary could not
  express, so it went in a free-text box. Adds `radio:`, `checklist:` and
  `checklist-qty:` (submitting `A=60; B=40`, with the quantity carried in the
  field NAME so the handler needs no schema). Two defects found while building,
  **both of which produced a form that worked and quietly held different data
  from what was entered**: an option containing a comma split in two
  (`select:"Smith, John","Jones"` offered three choices, two wrong), and
  `parse_post` OVERWROTE a repeated field name, so any multi-select would have
  kept only the last tick. `required` is deliberately not applied to a checkbox
  group - the browser reads it as *this box*, so it would demand every option.
  Two of the filing's asks were **already implemented** and are reported back
  rather than rebuilt: quoted labels with spaces or brackets, and `number` with
  `min:`/`max:`. The rate-limit exemption was NOT built as asked - see below - and
  a per-form `rate_limit:` ships instead. Docs: both form references.

- SM402 (340d6f3, filing only) **the form handler tags submissions with a header
  nobody verified.** Found while scoping SM401's rate-limit exemption, which
  would have trusted the same header for a security decision. `form-handler.pl`
  is not behind the auth wrapper - the templates front only the processor and
  the manager API - so `HTTP_X_REMOTE_USER` arrives as the client sent it, and
  `_auth_user` on a stored submission can be set by the submitter. It grants
  nothing (every capability gate is on a wrapped surface), so this is a false
  ATTRIBUTION rather than an escalation, but a field that can be set by the
  person it names is worse than an absent one. Filed rather than fixed: the three
  candidate fixes have different blast radii and one of them touches the auth
  spine, which is a release-manager call.

- SM399 (c1f48db) **the operator can see the journeys.** SM393 recorded the
  ordered trails and SM394 gave an agent a way to read them; the operator - the
  person the manager exists for - still could not see them at all. A **Visitor
  journeys** panel on the Stats page, fed by a new parameterised plugin action.
  The day is a declared CHOICE built from the trail files that EXIST, which is
  what `action_plugin_action` requires (nothing request-controlled reaches the
  command line) and is the right shape anyway: only a day that is really there
  can be asked for, and an expired day stops being offered the moment its file
  goes. It shows the ORDER and nothing else - `SM363` already renders entry, exit
  and depth from the aggregates over every visit, and trails are capped at 2000 a
  day and expire, so a second differently-scoped copy would disagree on a busy
  site with nothing to say which was wrong. **Route counts cover the whole day
  even when the visit list is capped**, and the page says which is which. It adds
  **no inline event handlers**: those attributes are the entire thing that breaks
  the manager under an enforcing CSP, so new UI binds with `addEventListener`
  rather than growing the ~250 sites the conversion has to pay down.
  `t/unit/plugins/27` asserts it against six sabotages - including one hole it
  found in itself, a CSS-class check that scanned only the script and missed a
  bad class on the card markup.

- SM394 (37442e4) **the trails have a reader.** SM393 recorded the ordered trails
  and nothing could read them: the agent that asked has no host access and sees
  only what `analyse_visitors` returns, so the data accumulated for nobody.
  `analyse_visitors` gains `trails=YYYY-MM-DD` on both channels (MCP tool and
  control API), validated to a strict shape and passed as an exec argument like
  the SM213 selectors, and `index` gains `trail_days`. That list is read from the
  DIRECTORY rather than the index file, because trails expire where the rollups
  do not and an index entry would outlive the file it names. The reply is capped
  at 200 visits and **states the size of the day as well as the size of the
  answer**, so a partial sample cannot pass for a whole one; a day with no trails
  says whether it was never recorded or has expired instead of falling through to
  the rollups' generic "no stats for that day/month". `t/lint/58` failed on the
  `Actions.pm` parameter list without being asked to, which is the SM350 pin
  working. Docs: the agent briefing gains a trails section and **amends its
  "no time-on-page" claim** - a step gap is a lower bound on the dwell for the
  page being LEFT, absent for the exit page, and must never be reported as
  reading time. `t/unit/plugins/15` asserts it against six sabotages. Open: the
  manager Stats page still has no trails view.
- SM389 close-out (a4c0950) **the four second-order findings, closed.** Each with
  a test confirmed to fail against the unfixed code.
  **Registry regeneration was a stampede**: TTL expiry happens at an instant, so
  every request arriving after it ran a full site scan concurrently - measured at
  12 of 12. A non-blocking lock picks one; the rest serve the file stale, which is
  what a TTL cache is for, and only a cold start with nothing to serve makes them
  wait. Registry hits also **recorded nothing at all** - the one served path that
  did not - so a crawler fetching `/sitemap.xml` was invisible; they now log on
  their own channel and are counted BESIDE `pageviews`, never inside it, for the
  SM329 reason.
  **The front-door relay held whatever a client sent**: a declared
  `CONTENT_LENGTH` was trusted whatever it said, and with no `CONTENT_LENGTH` at
  all - chunked encoding, which the client chooses - the body was slurped whole.
  Either sizes a persistent FastCGI worker permanently. Now bounded both ways,
  capped at 64 MiB, following `manager_upload_max_mb` **up** so raising the upload
  limit still works (`front_max_body_mb` overrides), and refusing an oversize
  declared length before allocating.
  **The Apache templates carried no body cap** while every nginx template capped
  at 64m; they gain `LimitRequestBody`, and real Apache parses them in the test,
  because a misspelled directive looks like protection and refuses to start the
  server. Recorded rather than glossed: SM286 wants these files shorter, and a
  byte ceiling is a resource guard rather than a routing decision.
  **The security register recorded round 1 only**, for a month - so every area
  read `last_covered: round-1` when two later rounds had both looked at them. It
  gains round 2 (2026-07-21, fixed in 0.9.9) and round 3 (SM268, fixed in 0.10.5),
  and `t/lint/64` now DERIVES `last_covered` and `never_covered` from the rounds
  so the file cannot claim coverage it has not got. The four never-covered classes
  the derivation produces match the four the review counted independently. Work
  done outside a round is recorded as not being coverage.
  Tests: `t/unit/processor/46` (12-of-12 stampede vs exactly 1, forked and
  counted), `t/unit/processor/47`, `t/unit/plugins/16`, `t/tools/33`, `t/lint/64`.
  One latent fault in the SUITE fell out of this: `t/unit/processor/14` asserted
  "the process count did not balloon" by counting **every perl process on the
  host**, so it measured the machine rather than the manager-api's own children.
  It survived only because nothing else on the box ran perl - until a sibling
  test that forks a dozen workers ran beside it under `prove -j` and it failed
  for something another test was doing. It now walks the process tree from its
  own pid: verified immune to 30 stray perl processes, and still failing on a
  real leak of 8 children.

- SM393 (e9b7e0c) **the ordered trail is recorded, and it expires.** SM336
  deliberately kept sequence as aggregates - "a flow reconstructed without
  retaining anybody's path". That is reversed on purpose: aggregates can be
  recomputed from retained logs whenever the analysis improves, **order cannot**,
  and once the event ring rolls it is gone for good. The ring is also shortest
  where it matters most - its retention is a function of volume, not time, so the
  busiest sites keep the least history. Per closed visit, per day, in
  `lazysite/stats/trails/YYYY-MM-DD.json`: ordered path sequence, entry, exit,
  distinct-page depth, per-step gap (the dwell on the page being left) and the
  class as it was at the time. Day files stay aggregates only. The deletion ships
  WITH the recording rather than after it - 40 steps per visitor, 2000 visitors
  per day, `trails_retention_days` default 30, `trails: off` to disable - because
  a retention that arrives later is a retention nobody has. Crawlers open no visit
  and leave no trail. Three defects were found building it: the flush was absent
  from the path `--export` actually takes; its `mkdir` used `File::Path`, which
  this plugin never loads, so it died inside an `eval` and the directory was never
  created; and `cmd_recount` would have written every visit in the window twice,
  because trail files are appended to rather than summed. A fourth came out of
  sabotaging the test - expiry sat below the "nothing new to write" return, so a
  site whose traffic stopped would have kept everything for ever; it now runs
  first and unconditionally. `t/unit/plugins/13` asserts all of it against seven
  sabotages, and `t/unit/plugins/14` the configuration surface against four more. Docs: `FEATURES.md` gains the feature and **amends the privacy
  commitment**, which said the store held "aggregates only, never per-visitor
  records" and had stopped being true.

- SM385 (a17a6c9) **the NOT CONFIRMED summary overwrote the stated reason with a
  guess.** In the real 0.10.15 deploy the probe declined and said why - running
  as root, where protecting content would leave root-owned files in the site
  tree - and three lines later the summary recommended `lazysite repair`, which
  fixes nothing there. SM377 added that skip and left the summary printing its
  one fixed sentence. **The summary is the part a deploy log reader sees**, so a
  wrong cause there is worse than in a detail line. It now prints the reason the
  probe gave, keeping the repair advice only for the case where no reason was
  given - which is real, and dropping it would trade one wrong summary for
  another.
- SM386 (8192654) **the path scrub removed the one thing a caller could act on.**
  SM378 made the snapshot refusal say why; a partner agent then hit it for real
  and got `tar: <path>: Cannot open: Permission denied`, which names nothing -
  they could not tell the private store from the render cache from a lock file.
  **The guard did not cover its own output:** the docroot was replaced with
  `<site>` and a generic absolute-path rule then matched the relative remainder,
  because its lookbehind excluded `<` and not `>`. Now relative always, absolute
  never - `<site>/lazysite/cache/x` and `<private>/upcoming/a.pdf` keep their
  shape, a path outside the site keeps only its tail. Nothing is disclosed that
  a caller cannot already list.
- SM381 correction (8192654) **the tar exit-1 fix did not explain the field
  failure, and the claim is withdrawn.** The fix is real and stands - a busy site
  genuinely could not be snapshotted, 3 of 3 refusals before and 0 of 3 after.
  But retried on 0.10.15 the refusal names **exit 2, Permission denied**, not
  exit 1. The exit-1 story fitted every reported symptom, which is exactly why
  both the review and I believed it. The field failure is still open, and is now
  a demonstrated permission difference between the two snapshot paths rather
  than an inference: `site_backup` succeeded at 09:24:01Z and 09:24:38Z with the
  apply's internal snapshot failing between them, same host, same account.
- SM387 (2e48fe4) **engine-served statics revalidate, and that is a choice.**
  After the SM283 proxy template went on edge, `/lazysite-assets/...`,
  `/favicon.ico` and `/assets/lazysite-chrome.js` all moved from
  `max-age=315360000` to `no-cache, must-revalidate` - reported from the field
  as a possible regression, and right to be. It stays: a static served by the
  engine is public *now* and can be protected at any moment, so a ten-year copy
  in a visitor's browser would outlive the protection, in a cache nothing can
  reach. **SM331 was this in the front end's descriptor cache and took three
  filings to understand.** The reasoning now sits at the decision rather than
  being inferable from its absence, and the ten-year cache is recorded as a
  property of the front-end fast path rather than of lazysite.
- SM374 note (2e48fe4) **the proxy fix is inert until the host's template copy is
  refreshed** - and while it is stale the failure is identical to the bug. The
  first application on edge failed with the same 421 on three domains because an
  older template was still in Hestia's directory. A package upgrade does not
  deliver a Hestia template. Now verified on four vhosts, asserted on the BODY
  rather than the status.

- Operator docs (5976c14) **the upgrade notes stopped at 0.10.10, and the
  channel default was documented backwards.** `UPGRADE.md` gains a 0.10.15
  section carrying the four things a package cannot do - re-apply access rules
  AFTER the upgrade, the proxy template (where **a stale copy fails identically
  to the bug**), the root-created private store, and outside-in verification as
  the site user rather than root. And `OPERATOR.md` said the `update_channel`
  default was `edge`: SM356 made it **stable**, so a site with no
  `update_channel` line REFUSES a beta or edge build. Anyone sizing a
  pre-release rollout from that paragraph would have overestimated its reach.
  The beta rung is documented for the first time.
- SM388 (c7e048b) **a comment claiming a capability that did not exist, and a
  skip that fired when it was most needed.** `lazysite-front.pl` justified not
  reimplementing the static path on the grounds that the engine "already gets
  right" byte ranges, conditional GETs and content types - and `Range`, `ETag`,
  `If-None-Match` and `Last-Modified` appeared **zero times** in the processor.
  A justification resting on a capability that is not there stops the next
  reader looking. **Fixed rather than withdrawn**, because SM387 made every
  engine-served static revalidate and without a validator each revalidation was
  a full re-download: weak ETag from mtime and size, `If-None-Match` answered
  with a 304 carrying no body and the full security header set. Byte ranges
  remain absent and the comment now says so. Separately, `t/lint/42`'s
  `skip_all` fired precisely when the processor's structure changed - the
  condition that makes front-door route parity most worth checking - so the
  check turned itself off exactly when it mattered, on the serving path. It is a
  failure now.

- SM288 follow-through (33f7207) **the widening now has its release note and its
  pre-report.** `@group` entries were silently inert on MCP and the control API
  before SM288, so honouring them widens effective access on live sites -
  intended, and still a permission change an operator should see rather than
  meet. `UPGRADE.md` carries it under its own heading, and
  `lazysite acl group-reach` lists each entry, the paths granting it, and every
  account it reaches **including through nested groups**. It lives in the ACL
  tool rather than `lazysite-check` because resolving membership there would be
  a fourth answer to "which groups is this account in" - the defect SM288
  removes - and reporting DIRECT membership only would be worse than silence: it
  would tell an operator somebody does not gain access when they do.
- SM389 (33f7207) **a static was read whole into a persistent worker.** One
  request for a large upload sized that worker to the file and kept it there,
  with nothing capping it - WebDAV accepts 64m bodies and an operator publishing
  video has no reason to think fetching their own file is a memory event. Now
  read in 64 KiB blocks, so the footprint is a constant rather than a function
  of what anyone published. A cap was the other option and is worse: refusing to
  serve a file the operator legitimately published trades an availability defect
  for a resource one. **Also checked rather than assumed:** the two commits whose
  subject lines say "NOT READY TO LAND" and "NOT YET PROVEN END TO END" are in
  the release, and the two tests the first left failing on purpose now pass -
  with neither file touched since, so they were resolved by the follow-up's CODE
  and not by rewriting the tests to agree. One command settles it.

- SM390 (406b75d) **the agent opt-out promised exclusion and delivers
  classification.** The MCP connector tells every partner that setting
  `lazysite-agent/<partner-id>` keeps their hits "out of the visitor
  analytics". It keeps them out of the **human** class; they are still counted,
  as `bot`. A partner followed the instruction, found its own traffic in the
  export, and reasonably concluded the opt-out was broken. **The behaviour is
  better than the promise** - dropping agent traffic entirely would leave an
  operator unable to see what their own tooling did - so the sentence is
  corrected rather than the code. Two related field symptoms are recorded as
  NOT understood: agent-UA requests appearing as `human`, and an SM332 sweep
  that did not promote. Neither reproduces - the sweep gives `human 0, scanner
  21` in a clean fixture on both ingest paths - so the trigger logic is not the
  defect and the remaining variable is state carried between export runs.
- SM391 (8e3af55) **the visitor classifiers are data, not code.** Every pattern
  in the stats plugin is a signature list and signature lists date - SM332 is
  what that costs, where `/wp-login.php` was caught and its modern replacement
  `/wp-json/batch/v1` was caught by nothing, because changing a pattern meant
  releasing the engine. Eight rule sets now load from
  `lazysite/stats/classifiers.json`, and the ruleset in force is stamped into
  the export beside `counting_basis`. Three failure directions are tested: a
  broken file falls back to the built-ins **entirely**, one bad pattern costs
  that rule alone, and - the design the test corrected - a ruleset **extends**
  rather than replaces, because replacing meant an operator adding one crawler
  signature would silently lose `curl`, `wget` and the rest, showing up as a
  quiet rise in the human count rather than an error.
- SM392 (dfb30f6) **one sweep behind a shared address reclassified everyone
  behind it.** `_visitor_key` is `hmac(ymd|ip)` - date and address, no actor -
  so the unit being promoted to `scanner` was AN ADDRESS. Eleven AI user-agents
  on real 200 pages, **Googlebot included as a control**, all came back scanner.
  It lands hardest on the traffic an operator most wants separated: AI
  assistants fetch from provider address pools shared by every user of that
  assistant, and corporate NAT is the same shape for people. The two identities
  now separate - counting stays on the visitor token, the sweep and promotion
  key on token+user-agent. A sweep, Googlebot and a person behind one address
  give scanner 6 / bot 1 / human 1, where before they gave scanner 8 / bot 0 /
  human 0. **Two worse fixes are asserted against:** weakening the promotion,
  and putting the user-agent in the COUNTING token, which would make one person
  with two browsers into two visitors.
- SM392 note (dfb30f6) originally filed as: **a promoted visitor token masks every later
  classification from that source.** Eleven AI user-agents, including Googlebot
  on a 200, all came back `scanner` because the token had been promoted earlier.
  SM213 classifies per visitor deliberately, and the same stickiness means a
  token that once looked sweep-shaped classifies everything from that source as
  scanner afterwards - and on a real site that token is any shared egress: a
  corporate NAT, a cloud region, an assistant's fetcher pool. Also recorded:
  there is no way to ask the classifier directly, so testing the `ai` class from
  outside needs a clean token that a probing agent cannot get.

## 0.10.15 - EDGE: the security header set stops being a claim (2026-08-19)

Cut after a pre-beta promotion review read the whole line read-only and
filed what it found. Most of this release is that review's list, and the
theme running through it is a **claim that had stopped being true**.

The comment on `_security_headers` said "every response path here calls
this". It had been wrong for longer than the defect it described - five
refusals, five redirects, the 500, the registry outputs and two
cross-origin-readable endpoints each printed their own. Two documents
said the engine deliberately emits no CSP; both were false the moment it
started emitting one. The CSP itself shipped enforcing with no way to
turn it down, and would have silently disabled the manager's own
controls in a browser, where nothing in the suite looks.

**The safety snapshot is the one to take if you run a busy site.** It
refused on any site with traffic, because tar exits 1 for "a file
changed while I read it" and that was treated as fatal - so the thing
that makes an apply reversible failed precisely on the sites where
reversibility matters.

Two entries below - SM383 and SM384 - shipped in this release but sat in the
Unreleased section until the 0.10.16 post-release pass: they landed between
this release's prep commit and its tag, so the prep could not have carried
them. Moved here so the section says what the release contains.

- SM383 (07879d3) **the release stage stamped one half of a pair.** SM375 taught
  `release.sh` to stamp `VERSION` and left `NEXT_VERSION` alone, so a stage
  cutting 0.10.15 carried `VERSION=0.10.15` **and** `NEXT_VERSION=0.10.15` - and
  the next release would have proposed a version already cut, which SM064 says
  is never reused. `t/lint/63` caught it by failing the release gate, which is
  the gate working; the defect was stamping one half of a pair **in the very
  change that existed because the pair had drifted**. Both now move together, as
  `tools/bump-version.pl` has always done. The test runs the real derivation
  line from a FILE rather than backticks, because it contains awk's `$1`/`$2`/`$3`
  and Perl ate them as capture variables - producing an empty result that looked
  exactly like the shell failing.

- SM384 (a19ca72) **the CSP hash died on any non-ASCII character in an inline
  script.** `Digest::SHA` operates on bytes and dies on a wide character; a
  TT-rendered response is a CHARACTER string. So one non-ASCII character inside
  an inline `<script>` aborted the response mid-headers and the browser got a
  **200 with an empty body** - and because the manager's own scripts carry
  non-ASCII and report-only is the DEFAULT, the manager was down in every mode
  except `csp: off`. The quieter tier: U+0080-U+00FF does not die, it hashes the
  latin-1 byte where the browser hashes two UTF-8 bytes, so the script is
  silently refused. **No test saw it** because nothing renders a manager page end
  to end through the real layout and every fixture's inline script was ASCII -
  the shipped catalogue was clean by luck, not design. Found by driving a real
  browser against a real manager, while the 0.10.15 cut was running; the cut was
  stopped before tagging and no version was burned.

- SM382 (2162d75) **the engine's chrome 404s on a content-rooted secondary
  domain.** SM352 moved the engine's own script and stylesheet into `/assets/`,
  which ship into the docroot; static resolution is content-root scoped, so a
  secondary domain looks under its own root and 404s. **Nothing reports it** -
  the frame suppression, the SM099 auth-control sync and the form handling do
  not fail, they never load, and the site otherwise renders perfectly. Measured
  on a two-root fixture: 200 primary, 404 secondary. Engine-owned assets now
  resolve from the docroot by an EXPLICIT LIST of paths rather than a prefix,
  because a general fallback would be a way out of the SM151 confinement - the
  test asserts a non-engine file is still refused, and widening the list to a
  prefix fails it.

- SM379 (93a2e52) **the deploy watcher exits after a deploy, with the SUCCESS
  code.** `set -e` is a shell option, not a function-local one: `deploy()` ended
  `set +e; ssh ...; rc=$?; set -e; return "$rc"`, and that final `set -e` took
  effect immediately - so the function returned non-zero with `-e` freshly
  re-enabled and the caller's own `set +e` undone from underneath it. The failing
  command was then the CALL, and the watcher exited. **It exited with the
  updater's own status, which is what hid it:** status 2 is SM344's "rollout
  succeeded, the fleet has findings", so the watcher deployed, printed the
  success text, and died. Measured against the real function with the transport
  stubbed - original survives only a clean deploy (exits on 2 and on 9), fixed
  survives all three. **This is why 0.10.14 sat in `dist/` unnoticed**, and it
  retracts the baseline-swallow hypothesis: the watcher was not mis-computing a
  baseline, it was not running. A failure arm reading "skipping (bump again to
  retry)" turns out to have been unreachable for the same reason - a message
  reassuring an operator the watcher is still going could only be printed by a
  watcher that was not.

- SM374 (81bef5b) **the SSL proxy template reaches the wrong vhost, or none.**
  Applied to edge as the runbook documents, `lazysite-proxy` returned **421 on
  every request** - pages, MCP, WebDAV and the control API - until it was rolled
  back. The hop to Apache is TLS addressed by IP, and nginx defaults
  `proxy_ssl_server_name` to OFF, so the handshake carried no SNI and Apache
  answered from its default vhost. **Measuring corrected the mechanism the field
  report proposed:** a missing `Host` does not cause the 421, it causes a silent
  **200 serving another site's pages**; the 421 needs `Host` right and SNI
  missing. Both are failures and the fix closes both, but only one announces
  itself - and a test asserting on the status code alone would call the quiet one
  a pass. Why it shipped: **a host with one TLS vhost cannot show any of it**,
  because the default vhost is also the right one. `t/integration/45` therefore
  drives real nginx in front of real Apache and builds a SECOND vhost it never
  requests, under two front-end conditions - one setting no proxy defaults, one
  setting `Host` globally - because a template that only works behind a
  particular front end's globals is the dependency SM286 exists to remove.
- SM375 (1cbd5ce) **VERSION sat five releases behind, and the compliance gate
  believed it.** The file read `0.10.9` while 0.10.10 through 0.10.14 shipped.
  `tools/bump-version.pl` exists for exactly this defect - its header records the
  2026 review that found the same file stuck at 0.2.18 during the 0.3.x releases -
  and says the release process should call it after a tag is cut. **Nothing ever
  called it**, so a written, committed fix sat inert and the defect recurred
  identically five releases later. `release.sh` now STAMPS VERSION in the stage,
  before the four things that read it, exactly as SM372 did for
  `debian/changelog` four days earlier in the neighbouring file. **The stale
  value is not the serious part:** `lazysite-compliance.pl` compares compliance
  records against VERSION, so for five releases the release gate asked whether
  records were current as of 0.10.9 - a question they passed by standing still.
  Corrected, it goes from 0 blocking to 2, and neither can be closed by editing a
  version marker: that would record a review that did not happen. `t/lint/63`
  fails when VERSION falls behind the newest tag; `t/tools/51` asserts the
  stamp's ORDERING - a stamp after any reader leaves the same wrong answers while
  looking right in a diff - and runs the stamp line extracted from release.sh
  rather than a copy of it.
- SM376 (775ec90) **a promoted account is still drawn under its creator, with no
  control to move it.** Reported from the manager UI on 0.10.14: a user "still
  doesn't have the option to move to top level" - and both halves of that were
  true at once. `account-promote` clears `managed_by` to the EMPTY STRING;
  `created_by` is immutable and never clears; and `s.managed_by || s.created_by`
  reads a cleared parent as an absent one, because "" is falsy in JavaScript. So
  the tree drew the account under a creator that no longer managed it, while the
  "top level (no parent)" control was hidden - correctly by its own lights,
  since by the API's reckoning the account already WAS top level. **The control
  was never missing**; it was hidden by a condition that was right, about an
  account the tree was drawing wrongly. The expression appeared SIX times and
  all six were wrong the same way, so the question now has one owner and
  `top_level` is treated as the answer rather than a hint. The test EXTRACTS the
  function from the shipped page and runs it under node against the four states
  the CLI actually writes - including a reassigned account, because a fix that
  collapsed into "always use created_by" would pass the promoted case and
  silently stop showing reassignment.
- SM377 (683a862, f82c5cc, 222c3d9) **the ACL probe now establishes the state it measures.** It
  gated by writing `acls.json` and nothing else; the engine protects by MOVING
  content into the private store, so the probe's files stayed in the document
  root, a front end serving statics by extension served them CORRECTLY - nothing
  had protected them - and the probe reported the site's protected content as
  reachable. On edge it returned FAIL in the same run where another check in the
  same tool reported "protected content is held outside the document root". Two
  checks, one run, contradicting each other. It now protects through the
  engine's own call and **asserts `content_moved`** before measuring anything,
  and the never-fetched file is written into the **private store** - writing it
  to the old path would put an unprotected file back in the docroot, the same
  defect one step along. **The confirmation line changed**, because "the front
  end respects the ACL" was false about a front end that passes by having
  nothing left to serve; it is a designated marker that `lazysite-cli.pl`
  matches to derive a pass, so the two moved together. Two consequences are
  recorded rather than buried: this probe can no longer detect a front end that
  BYPASSES the engine (nothing is left for one to serve - open in SM377), and
  `t/integration/58`'s cache stub was found to record that it had served and
  then re-read from disk, which models nothing - it now holds the BYTES, which
  is what `open_file_cache` does and why residue exists in the field.
- SM378 (541465a) **a refused snapshot now says why.** `site_apply` stopped with
  "Refusing to apply: safety snapshot failed" - no path, no errno, no detail -
  while `site_backup` on the SAME host succeeded in both directions minutes
  later, including after the apply had failed. **The cause was not missing, it
  was discarded**, at two levels: `action_backup_create` threw away tar's exit
  status, its stderr and which of three conditions fired in favour of "Backup
  failed", and three call sites then threw away even that. The three conditions
  are now told apart - tar exited N, tar wrote no archive, tar wrote an EMPTY
  archive - and tar's own message is carried as `detail`, scrubbed of
  filesystem paths, since tar names them in nearly everything it emits. The
  refusal itself is unchanged and correct: an apply overwrites content and the
  only thing worse than being unable to roll back is believing you can. This
  does not diagnose the field failure; it makes the next attempt diagnosable.
  **A near miss is recorded in the filing:** the first draft used `${@:3}` to get
  a shell redirect, a bashism `dash` does not understand, which would have
  broken every backup on the platform this ships to - in the code whose whole
  job is making things recoverable.

- SM352 follow-up (b4c02de, 98c6c60) **the CSP test that step 5 left failing, and the
  routing check that replaces what SM377 cost us.** Step 5 landed with
  `t/integration/44` red: it asserted "no enforcing CSP, because the engine would
  violate it", which was correct until the engine stopped inlining. **It was
  missed because that branch was gated on `t/lint` and `t/unit` only** - the
  argument for running the whole suite before a landing rather than the suites
  that look relevant. And SM377's fix cost the ACL probe its ability to see a
  bypassing front end, because protecting properly leaves nothing for one to
  serve. A different question answers it with no protected content at all: since
  SM352 every response the engine writes carries its header set, so their ABSENCE
  on a static is the signature of something else having answered it. Two GETs,
  no ACL, no fixtures. **The page request is load-bearing** - without it "no
  headers on a static" cannot be told from an engine setting no headers anywhere,
  and `t/integration/59` includes a plain static server precisely so that
  deleting the control fails a test. It reports ROUTING, not access: protected
  content has left the served tree, so what such a front end serves is public and
  served correctly, and overstating that is how the original probe misled an
  operator.

- SM380 (3439f33, ec4a492) **the CSP shipped enforcing, with no way to turn it down.**
  Step 5 emitted one enforcing policy on every HTML response, no config key, no
  report-only mode. **A CSP hash covers a `<script>` BLOCK and not an inline
  event-handler ATTRIBUTE**, and the manager's own pages are built on `onclick=`
  - cache, audit, sessions, plugins - so the shipped policy silently stopped an
  operator's controls firing. No test could have caught it: the failure is a
  browser declining to run a handler, on a page the suite renders and never
  executes. Now `csp: enforce | report-only | off` in `lazysite.conf`,
  defaulting to **report-only**, with the policy identical in either mode so a
  site that flips to enforce gets what it was already reporting. An unrecognised
  value reads as report-only, never off. Converting the manager to
  `addEventListener` remains before a manager surface can be enforced.
- SM381 follow-up (ec4a492) **and every other path that answered without them.**
  The audit did not stop at 402/403: five redirects, the 500, the registry
  outputs and two cross-origin-readable `.well-known` endpoints also printed
  their own status line and no header set. The comment claiming "every response
  path here calls this" had been wrong for longer than the defect it described -
  a comment asserting completeness is a claim like any other, and this one went
  unchecked because it read like a description of the code beneath it.
  `t/lint/55` now proves it mechanically, skipping comments because the
  corrected comment quotes the string the check searches for. Also: a tracked
  `docs/gate-register.md`, because the only evidence of the last green full gate
  was a gitignored scratch file, and the manager is held at report-only under
  `csp: enforce` - its pages carry 186 inline handlers, 127 of them generated
  inside JS strings, and converting those without a browser in the loop risks
  the silent dead button this whole item is about.
- SM381 (3439f33) **five refusal paths carried no security headers, two wrote
  into the wrong docroot, and the safety snapshot failed because the site was
  live.** `serve_402`, `serve_403`, the ACL static refusal, the manager-access
  refusal and `forbidden()` all printed their own headers - so the responses a
  scanner is most likely to reach were the ones without nosniff, frame options,
  HSTS or CSP, while the comment on `_security_headers` claimed every path called
  it. 402 and 403 also resolved no content root, so on a multi-domain instance
  **domain B's refusal page was rendered into domain A's docroot and served to
  both** - the defect SM253 fixed for the 404, never carried to its neighbours.
  The error-page writer gained the checked write and umask the main cache writer
  has documented since SM020. **And the field snapshot failure is explained
  rather than merely diagnosable:** tar exits 1 for "some files differ" and the
  snapshot treated that as fatal, so one visitor triggering a render during the
  tar refused the whole apply - 3 of 3 refusals with the old behaviour, 0 of 3
  with the fix, which predicts every reported symptom including why a quiet-moment
  manual backup always worked.

## 0.10.14 - EDGE: a cache clear that deleted pages, and the second copies (2026-08-18)

**Anyone running 0.10.13 or earlier on a migrated site should take this one.**
`invalidate_cache("/")` DELETED the homepage rather than clearing it, and the
defect repaired its own symptom: the next render put the page back, so the loss
was invisible unless the source was gone too. It was found on a live site, not
in the suite.

The rest of the release is the other half of the same lesson. Where a fact has
to exist twice - the manifest generators, the theme token generators, the
security headers - the copies are now pinned to each other BY VALUE, because
every one of them was discovered to have drifted while both halves looked
correct in isolation. And six tools could not load the modules they declare,
which no test noticed because no test ran them the way an operator does.

- SM352 step 4 (12faa2e) **the site side stops inlining altogether** - the theme
  custom properties, the last inline block a visitor received, are written into
  the theme's asset mirror as `theme-tokens.css` and linked. **The flash of
  unstyled content this was expected to cost does not happen:** a `<link>` in
  `<head>` is render-blocking, so nothing paints before it arrives. That worry
  belonged to the manager's *script* prelude, which runs after paint, and
  carrying it across to a stylesheet is what made a solved problem look like it
  needed a nonce. The generator stays as the fallback for a site whose mirror
  predates the change - an upgrade does not refresh what it does not touch, the
  lesson SM365 cost - so the fact now exists twice and `t/lint/61` pins the two
  copies by value, escaping and key filter included, because the file is read
  only by a browser and nothing else in the suite would compare them. The
  inventory still lists the site entry, deliberately: the *source* emits the
  block, a refreshed *site* does not receive it, and collapsing those two
  questions is how an inventory starts lying. The site-side count is 0 for a
  rewritten mirror and 1 for a stale one, which makes the remaining site-side
  work operational rather than code.
- SM352 steps 1-3 (ac05a51, 9d8edcc, c57147a) **the engine stops inlining its own chrome** - ten
  inline `<script>`/`<style>` blocks down to **two**, and step 3's more useful
  half was splitting the inventory by **audience**. The public site's policy
  does not depend on the manager's inline script at all - they are different
  responses to different people - and counting them together invited exactly
  the wrong plan: emptying the manager to reach a site policy it has no bearing
  on. One entry each remains, and the manager's is a 349-line head script whose
  theme prelude and fetch wrapper are *ordering* constraints an external file
  cannot satisfy, so it wants a hash rather than a move. Step 2 took the two form
  scripts, and the reason they could join is the useful part: **neither ever
  needed the form name.** Both used it only to *select* the form, and
  `data-form` is already on the element - so iterating `.lazysite-form` does the
  same job for one form or five. An interpolated script is exactly the case that
  would otherwise need a nonce; this one turned out not to be interpolated in
  any way that mattered. The fallback page chrome and
  the multi-step form rules are `/assets/lazysite-chrome.css`; the frame
  suppressor, the auth-control sync and the admin bar's frame hiding are
  `/assets/lazysite-chrome.js`. **Two files, not seven**: a rule that only
  matters on a page with a multi-step form costs nothing to carry, while a
  second request costs a round trip on every page that has one. The script
  bundle is self-contained - each behaviour looks for its own elements and does
  nothing when they are absent - so one reference serves three callers, injected
  once and deferred. `t/lint/56`'s count going down is the progress, and
  `t/integration/60` asserts a rendered page carries nothing inline, which a
  count in a source file cannot.

- SM280 (219045c) **the coverage run is sharded, and the gate moves at last.**
  SM269 attributed the eighty minutes with strace: coverage is 92% of it. Of
  the three candidate shapes, sharding is the only one that keeps the gate's
  *meaning* - the other two trade coverage of this commit for speed - and it
  needed no merging machinery, because Devel::Cover already merges per-process
  runs from one shared database. Measured before changing anything, on
  `t/unit/mcp`: **serial 467s at 52.2%/27.2%, `-j4` 182s at 52.2%/27.2%.** The
  identical numbers are the half that matters; a faster run reporting different
  coverage would be a faster run measuring something else.
- SM327 (219045c) **the perf tolerance is 1.25, and a baseline cannot bury a
  regression.** Every operation had drifted 9-26% slower than the 2026-07-02
  baseline and a 2x tolerance passed all of it on every release. The drift
  arrives as accretion, so 2x can never catch it. The larger half: `--baseline`
  now **refuses** to re-capture over a regression, naming each op and its ratio
  - because re-capturing was the queued housekeeping task, and doing it would
  have cleared a warning and made the regression the new definition of correct.
  `--accept-regression` proceeds; the flag exists so somebody states the numbers
  are *right* rather than merely current.
- SM302 (219045c) **a review finding carries the command that checks it.**
  Thirty-odd one-line greps, reinvented each review, written down nowhere.
  `tools/lazysite-review-verify.pl` re-runs them from a `findings.json`, and
  reports **three** states: fixed, still-open, and *could not be checked* - the
  last never counted as either, and failing the run, because a review whose
  checks cannot run has told the next reviewer nothing.
- SM303 (219045c) **release.sh is two commands.** `build` gates, packages and
  tags locally and touches the remote nowhere; `publish` confirms upstream and
  pushes. Conflating them cost a run that aborted before any gate step on the
  host with no credentials, and then - after `--no-fetch` - one that died at the
  last step on `git push`, stranding a fully built and tagged release with
  exit 128. The bare form now refuses and names both commands rather than
  guessing which half was meant.
- SM298 (f869ae0) **a compliance record says whether it actually changed.**
  `reviewed_at_version` catches a record nobody updated; it cannot catch one
  whose version was bumped without anybody re-reading the document - the same
  failure one level down. The records now carry a `content_sha` of their own
  body, so the version stops being a promise and becomes an observation. It
  advises rather than blocks, because a register can legitimately be unchanged
  and the reviewer decides; what it removes is claiming a re-read that did not
  happen without the claim being visible. The hash excludes the stamped fields
  **including itself** - the first version hashed its own field, so stamping a
  value changed the value.
- SM282 (f869ae0) **preview a path as the public sees it.** A draft section is
  invisible to the public and visible to a signed-in editor, which is why the
  editor is the one person who cannot check it. `preview-public` renders any
  path anonymously and reports the verdict in the operator's terms, saying that
  a refusal is the *expected* result for a draft and is the check succeeding.
  The safety property is the identity strip, and the test asserts it against an
  ACL that names the operator - so a leaked identity would show the page.
- SM281 (f869ae0) **the notice store is readable remotely.** `notifications`
  unlocked a manager page and had no remote surface at all - the bell read the
  store and neither MCP nor the control API could. Read only; writing is
  emission. **Item 3 of three:** the SMTP endpoint, per-user addressing and the
  retention decision remain, and an MCP twin waits on addressing or every agent
  reads every operator notice.

- SM364 (4dcfbb1, 54a0262, a753821) **reproduced at the fourth attempt, and disproved.** In the
  state the report describes, the dot-prefixed entry is listed, **read (200)
  and deleted (204)** - the engine has no dot-prefix policy in that subtree and
  the listing agrees with its verbs. The obvious fix would have hidden an
  addressable entry. What three attempts missed: `HTTPS=on`, or the transport
  gate refuses everything, and `manage_themes` + `manage_layouts`, or the
  layouts authorisation refuses the subtree before any path logic runs - both
  invisible behind a 403. What the reporter saw is a **front end** refusing
  dot-prefixed paths while the engine lists them, consistent with their 404
  body already being their own error page. **Confirmed from outside:** the same
  path deleted through MCP, where it travels in a JSON body and never appears
  in the request URI, succeeds - same engine, same credentials, opposite
  outcome. `t/integration/58` pins the state and the behaviour, so the one-line
  filter cannot be added later without deleting the subtest that says why it is
  wrong.

- SM363 (c9aa6f7) **the Stats page shows what the stats record.** Sessions,
  journeys, devices and search terms were all computed and stored per day while
  the manager rendered none of them - so an operator who read the search-terms
  setting, weighed the privacy question, decided to accept it and switched it on
  saw nothing happen. The page now shows devices, terms, the visit count, the
  depth histogram and where visits started and ended; `sessions`, `entry`,
  `exit` and `depth` joined the window projection to get there. The terms block
  is **absent rather than empty** when the setting is off, states the frequency
  floor beside the list, and escapes every term without putting it in an href -
  a search term is the first field this page renders whose content a stranger
  chooses, and it is not a URL.

- SM370 (1d83322) **a byte-comparison test asserted what the payload cannot
  satisfy.** The durable day files are compared byte for byte, because SM339
  needs a repair to be diffable - and SM341 later added a `generated` timestamp
  to the payload, so two writes a second apart differ in the one field whose
  purpose is to change. It passed 39 runs in 40. The comparison now normalises
  that field out and separately asserts it is present, so the normalisation
  cannot mask its disappearance. **I filed this as something else first**: a
  gate summary said `Failed test: 5`, I counted subtests to map the number,
  landed on the recount dry run, and reasoned from there to a much more alarming
  hypothesis. Reproducing it - 1 failure in 40 runs - was the only thing that
  would have corrected it.
- SM371 follow-up (1d83322) **and now it is tested.** Four earlier fixtures
  failed to reach `serve_403`, one of them passing with the fix removed, because
  the front-matter key is `auth_groups:` as an indented block and not `groups:`.
  Named in the test so the next person does not rediscover it.
- SM372 (1402d03) **a release builds its packages.** `dist/` holds a `.deb` set
  for every release through 0.10.8 and none for the five since - because
  `release.sh` succeeded without them, and a step outside a process that already
  succeeds eventually stops happening. Worse, `dpkg` reads the version from
  `debian/changelog`, which sat at `0.10.8-1`, so building by hand today would
  have produced a package labelled 0.10.8 from 0.10.13 source - which apt
  declines to upgrade to and `dpkg -l` reports as fact. The set is now built
  from the same staging clone as the tarball, with the changelog entry
  **stamped from the release version in that stage**, so the package version
  cannot disagree with the tag. Built before the tag so a failure burns no
  version, and checked per-package by name at that version, because an exit
  status is not a package.
- SM373 (1402d03) **the catalogue listing passes `kind` through.** The layouts
  catalogue marks a demonstration layout `kind: demonstration` so a caller can
  filter gallery chrome out before installing it - the half SM337 could not
  supply, given SM349 measured 1 of 23 layouts rendering the site's navigation.
  A hand-written allowlist that predated the key dropped it on all 23. The test
  asserts the general property rather than the field: every scalar the manifest
  declares survives the passthrough, which is the guard SM330 needed.
- SM364 **not fixed, for the third time, and now with the reason written down.**
  A third fixture failed to reproduce the state the report describes: staging
  the layouts subtree directly refused *everything*, including the ordinary
  file that was supposed to be the working comparison. Three premises have now
  failed in this area - that the HTML 404 was ours, that the dot rule is
  general, and that the subtree can be staged as tried - each reasonable and
  each wrong somewhere different. The common factor is skipping the one
  instruction the filing has carried since its first rewrite: establish the
  refusal before reasoning about the listing. Recorded there rather than
  guessed at, because a wrong guess on a listing predicate widens what is
  visible.

- SM304 (6cd1de7) **the two manifest generators cannot drift apart** - and they
  already had. `install.pl` and `tools/manifest-to-sbom.pl` each carry
  `_generate_manifest_to_tmp`, added the same day by the same change, and by
  the time this was looked at they derived their root differently. One owner is
  not available: the installer is core-Perl-only by design, so it cannot load a
  shared module. `t/lint/60` compares what each copy *does* - run against a
  fake builder that records how it was called - and separately asserts the one
  difference that must stay, that they write to different temp paths so a
  release running both cannot have one clobber the other.
- SM308 / SM362 **are one defect, filed twice.** SM362 is marked superseded and
  its live item - the double-escape, where every layout applies `| html` to an
  already-escaped `page_subtitle` so copy reaches search engines
  double-escaped - has moved into SM308. Two open filings for one defect let
  each party believe the other is carrying it.

- SM272 (94c91f9) **an apt repository the packages can be installed from.**
  The `.deb` family has existed since 0.6.10 with nowhere to install it from,
  so 17 sites take a tarball. `tools/build-apt-repo.sh` builds the pool and the
  per-suite indices; it deliberately does **not** publish and does **not** hold
  a key, because publication is egress and key custody is the question SM272
  exists to ask. Unsigned output says it is unsigned and that apt will refuse
  it. The **channel is required and never inferred** - a suite chosen by
  default is how an edge build reaches a stable host - and the index is checked
  against the pooled count, because `apt-ftparchive` aimed at the wrong
  directory exits 0 and writes an empty `Packages` that installs nothing.

- SM368 (6411fa1) **the ACL probe asks which cause, instead of naming one.**
  When some file types serve past an ACL and others refuse, there are two
  candidates - a front end serving statics by extension (SM283, an operator
  task) and a front end still holding descriptors for files fetched while the
  folder was public (SM331, which clears itself). The probe reported the first,
  in the same sentence and the same voice as the measurement, and was wrong in
  the field: a correct measurement became a false operator work item and was
  relayed onward as one, twice. The discriminator is **one request** - a file
  written after the gate and never fetched cannot be in any cache - and the
  probe already created the cached population itself. The cache case is now a
  WARN saying *no action*, not a FAIL telling somebody to change a template.

- SM371 (0d0e10e) **an error page has no canonical, and only the 404 knew.**
  SM355's reasoning was never 404-specific, but its helper was only ever called
  from `not_found()`, so `serve_402` and `serve_403` rendered into the served
  tree carrying whatever canonical the layout emitted. Found on edge: a 402
  whose canonical pointed at the **payment-gated page the visitor had just been
  refused**. Both now strip it, mark the page `noindex`, and rewrite the cache
  file the front end serves. **Not covered by a test** - four fixtures failed to
  reach the right branch and one of them passed with the fix removed, so it was
  removed rather than approximated; what would cover it is written into the test
  file.

- SM367 (bc21f42, bc23864, 0d0e10e) **`invalidate_cache("/")` clears the homepage.** It became
  `$DOCROOT/.html` - a file that has never existed - so the unlink found
  nothing and `ok:1` was returned anyway, while `/index`, `/index.md` and
  `/index.html` all worked. Found during the 0.10.13 validation, after it had
  cost two wrong diagnoses rather than two errors: once a stale `index.html`
  believed to be shadowing the homepage, once a 0.10.12 render on a 0.10.13
  instance read as a failed upgrade. Digging reshaped it: validation existed and
  tested the **parent directory**, so `/nope.md` answered `ok:true` while
  `/nope/deeper.md` answered `ok:false` - two pages that do not exist, differing
  on something the caller never asked about. `ok` now means the page exists and
  was acted on, the response reports how many renders it `cleared`, and a path
  with no page is refused with a reason. **And it deleted pages:** a bare
  `.html` with no `.md` sibling is legacy static content served by the migration
  fallback, which SM133 taught the `*` sweep and never taught this branch - so
  on a migrated site invalidating one unlinked the page and reported `cleared:1`.
  Refused now, with the page left alone.
- SM358 follow-up (a00aac2) **the `hidden_by_script` finding names the template
  that applies the class**, not the layout that contains it. On the reporting
  instance both `reveal` references in `layout.tt` were JavaScript and four of
  six *components* applied it in markup, so `layout:lumen` sent an operator to
  six files when one was implicated. **And a component now counts only when a
  page invokes it** - via a `::: name` fence or a front-matter `sections:`
  block, both already visible in the source the audit walks. So the check is
  silent where nothing renders the component and speaks the moment a page
  starts using one, which is the moment an operator can act. No second warning
  surface was needed: the question of what to do about a latent hazard rested
  on the check being unable to tell, and it can.

- SM366 (6f4de4c) **six tools can find the modules they load.** The 0.10.13
  rollout printed `Can't locate Lazysite/Paths.pm` from `lazysite-check.pl` and
  then reported it as *"some checks could not be auto-repaired"* - a script that
  could not start, described as checks that could not be fixed. The health tool
  never ran, and an operator reading that would conclude their site had
  unfixable problems. `lazysite-users.pl` has always carried a `BEGIN`
  bootstrap; six tools that load Lazysite modules never got one, so they work
  from the repo and die on tarball and Hestia installs - which is how the fleet
  runs. It fails *inconsistently*, because the deploy script sets `PERL5LIB` for
  some invocations and not others, which is why no gate caught it and a deploy
  log did.

## 0.10.13 - EDGE: the control reported success, and had not done the work (2026-08-17)

Cut from a four-surface validation of a live instance. The release is keyed
here after the fact - it was tagged without its own changelog section, which is
the same class of omission as an unwritten commit ref and is recorded rather
than quietly corrected.

Most of what follows is one defect wearing different clothes: a control that
answered "done" without having done it. An update that left the site on the old
theme, a channel check that failed OPEN, an audit finding that named a file the
operator could not act on, a search that stopped at a limit it would not name.
None of them reported an error, which is why they needed a live instance to
find.

- SM365 (723eeed) **a layout update no longer leaves the site on the old
  theme.** Measured on edge after `lumen` went to catalogue 1.1.0: the template
  was the new one and `/lazysite-assets/lumen/lumen/main.css` was
  byte-identical to a copy taken that morning, missing every `.nav-toggle` rule
  the release added - so below 900px the stale CSS hid the nav with no rule to
  reveal the toggle, and the declared favicon 404'd. Every surface reported
  success. The cause was an asymmetry: `_install_layout_from_dir` has always
  taken an update flag and written in place, while the theme installer had none
  and treated an existing theme as a **collision**, installing the new one as
  `20260817-lumen` beside the one the site actually serves. So
  `themes_installed` named a real theme truthfully and the instance ran half of
  each. An update now replaces the theme in use, snapshotting first so an
  operator's edits survive - and a same-named theme that is *not* an update
  still steps aside, which is what the rename was for.

- SM359 (624dbf2) **search_files says which limit stopped it, and can be paged
  past.** The filing asked for paging first; measuring what is actually being
  paged inverted that. This is a walk of a few hundred small text files - 181
  on lazysite.io, 442 on dito.tech - against a 2,000-file budget and a
  200-match cap, so the file budget never fires on a real site and the match
  cap fires constantly. A caller who hits truncation nearly always has too
  broad a *query*, not too small a page, and both limits set the same bare
  boolean. `truncated_reason` now says `match_limit` (page on, or narrow the
  query) or `file_budget` (narrow the base). `limit` and `offset` page the
  rest, `truncated` means *there is more after this page* rather than *this
  page is full*, and `count` is documented as matches returned. **No total and
  no cursor**, both deliberately: the scan stops at the cap, so a total means
  reading every file - the cost the cap avoids - and offset paging's re-walk is
  milliseconds here, so a cursor would mean inventing a stable index the
  traversal does not have. Its weakness is stated in the schema instead.
- SM358 (4289f71) **an audit finding that names something the operator can
  act on.** `hidden_by_script` reported a stylesheet that *defines* a
  script-revealed class, whether or not anything used one - so an instance
  where no page used it still carried an item that could not be cleared, since
  the theme is shipped and an edit is overwritten on upgrade. The finding now
  requires a USE: the classes doing the hiding are extracted from the rules,
  and reported only when a page's content or a **layout template** puts one on
  the page, naming the class and where it is used. The layout half is not
  incidental - SM250 was a layout emitting the class on every section while the
  hero sat outside the pattern, so a check reading page content alone would
  have missed the case it exists for. **Declined:** crediting a
  `prefers-reduced-motion` reset. It reaches only visitors who asked for
  reduced motion, and reading it as a neutraliser is what caused SM250.
  **Partial after field validation:** the finding still fires where no page
  uses the class, because the layout's *components* apply it in markup even
  when nothing renders them - the same mechanism-versus-use distinction, one
  layer down.
- SM353 (3476550) **one answer per question, whichever channel asked.**
  `ok` is now a JSON boolean on both surfaces, coerced at the single point each
  one serialises through rather than at the ~130 places that set it - so no
  handler decides and none can drift. **This is a deliberate compatibility
  break**, taken before the freeze: a caller testing `ok === 1` will change
  behaviour, and `true` is the side to stand on because it is what the schema
  declares. The filing framed it as the API disagreeing with MCP, which
  understated it - MCP disagreed with itself, `describe_capabilities` emitting
  `true` where `validate_page` emitted `1`. The capability map now carries
  `groups` on MCP as well, the resolution SM288 already reached one layer down
  for the same account. And every 30x the engine writes states its content
  type: the filing found the gating bounce declaring `text/x-perl`, and
  sweeping for the shape rather than fixing the instance found seven, three of
  them in the auth wrapper. The helper-script contract in
  `starter/docs/forms-helpers.md` is deliberately untouched - that is what an
  operator's own script sends to lazysite, and the engine reads it for truth.
- SM352 (0a32147) **the security header set, in one place, and honest about
  what it leaves out.** Three headers were emitted and a field probe reported
  all three correct - on one of the engine's four response paths. Every
  stylesheet, script, SVG and image the processor served carried nosniff alone,
  a drift invisible to anyone measuring the homepage. All four paths now emit
  one set from `Lazysite::SecurityHeaders`, with HSTS added at a deliberately
  short `max-age=300`, no `includeSubDomains`, no `preload`, and only when the
  connection is actually secure - the same test the session cookie already uses
  for its Secure flag, so a front end that says nothing simply gets no HSTS.
  Permissions-Policy denies the capabilities the platform never uses, including
  the Topics API, while leaving autoplay and fullscreen to the author. **This
  reaches every response the ENGINE answers** - on a stock proxy template every
  static is answered by the front end, so on most of the fleet that means pages
  only, and no deployed instance we can reach has ever shown these headers on a
  stylesheet (SM369). The engine emits all of it, so nothing is asked of the
  proxy: the earlier comment
  saying HSTS and CSP "belong in the Apache vhost config" is the reasoning
  SM286 overturned, and it is quoted in the module rather than quietly removed.
  **CSP is deliberately still absent**, and `t/lint/56` records why as an
  inventory of the ten places the engine inlines `<script>` or `<style>` -
  which is what a report-only collector would have had to discover from live
  traffic, for a fact the source already stated. COOP waits for CSP.
- SM350 (b246c2c) **the control API publishes an action reference.** MCP has
  `tools/list` with a schema per tool; the other enforced channel had no
  equivalent and no documentation page - a search for its action names across
  23 reference docs and 7 briefings returned one incidental mention.
  `action=actions-list` now answers with every action the calling account may
  use, its parameters and where each is read from, subset by grant the way
  `tools/list` already is (SM210). `docs/reference/control-api-actions.md` is
  generated from the same source. The useful part is the three-state capability
  model it makes visible - any-one-of-these, any-authenticated, and
  **cookie-only**, which covers 59 of the 111 actions and is the state a caller
  could discover no other way. The filing asked for this to be generated from
  the dispatch table; there is no dispatch table, so the declaration was
  **extracted** from the 108-branch chain and `t/lint/58` re-extracts it on
  every run and fails on any difference. Replacing the chain remains its own
  work.
- SM336 (9bfc52c) **items 6 and 7: device class and internal search terms** -
  the two the sessions release left open. Device is three counters from the
  user-agent both ingesters already had and both discarded, counted on page
  views only, with tablet tested before mobile because every Android tablet
  says *Android* and only a phone also says *Mobile*. Search terms ship
  **off**, on their own switch, top-20, behind a frequency floor of 3 - and the
  floor is a privacy property rather than a reporting filter: below it only a
  *hash* of the term is counted, so a term one visitor typed once exists on
  disk as twelve hex characters and nothing else. On a site that never enabled
  it the field is absent rather than empty, because an empty list reads as
  "nobody searched" when the truth is "nobody was asked". **And a defect found
  on the way:** the server-log parser captured the request target - query
  string included - and nothing stripped it, so `?q=widgets` and `?q=prices`
  were separate entries in `top_pages` and every distinct search diluted the
  page it was searching from. Totals are unchanged, so this is not a
  counting-basis change; a site with a busy search box will simply see its real
  pages rise. Both fields reach **both** window
  payloads - the one behind the operator's Stats page and the agent-facing
  export - so neither channel answers the question differently. The Stats page
  does not yet *render* either of them, nor the sessions and journeys from the
  previous release; that gap is [[SM363]].

- SM335 (9b3bc1f) **one class vocabulary: the manager Stats page and the export
- SM336 (dec9558) **a session has a boundary, and sequence is recorded.**
  Everything durable was a marginal count - nothing paired one dimension with
  another and nothing recorded order - so the question a site owner asks first,
  how people move through the site and where they give up, was answerable only
  from a rolling sample and never for any period already past. A visit is now
  bounded by thirty minutes of inactivity **or a day change**, and each day
  carries `transitions`, `entry`, `exit`, `depth`, `dwell`, `landing` and
  `not_found_from`. All aggregates: a hundred visitors going
  `/ -> /products -> /contact` is one counter of 100 on each edge, never a
  hundred stored journeys, and no visitor's path reaches the durable store.
  Sessions close on **silence** as well as on a following event, or the last
  visit of every day would never record its exit. Only human page views open one
  - a scanner has no journey, and an image is not a step in one - which makes
  SM332 and SM329 prerequisites rather than adjacent work. **Partial:** device
  class needs the user-agent threaded through both ingesters, and internal
  search terms need a privacy decision, a frequency floor and their own toggle.
- SM347 / SM348 / SM351 / SM360 / SM361 (8c13544) **five surfaces that said
  something not quite true**, from the partner agent's four-surface pass.
  **SM347**: `read_page` and `validate_page` rejected a bare path that four
  other tools accept, so create-then-read failed on a page serving 200 - one
  resolver now, conservative, and an exact path that exists is never
  re-pointed. **SM348**: `describe_capabilities` still told agents
  `install_layout` "installs AND activates in one step" on both surfaces, which
  SM314 had already corrected in the tool itself - the document read FIRST
  contradicted the tool it described. **SM351**: `content_moved:1` is true of
  the engine and, for up to a minute, false about what a visitor gets; a
  `content_moved_note` says so, in its own field rather than `warnings`, because
  a caller filtering on warnings would read a caveat as a failure. **SM360**:
  `governed_by` names the ACL key in effect, so a listing can distinguish
  "private because its folder is gated" from "private because of its own stale
  rule" without a call per file. **SM361**: `starter/forgot.md` says it is a
  system page and why native forms cannot serve it, and the MCP instruction
  states the rule's boundary rather than leaving an absolute its own shipped
  example contradicts.

- SM335 (9b3bc1f) **one class vocabulary: the manager Stats page and the export
  now count the same way.** The page carried its own counting implementation
  with a vocabulary of its own - human / logged_in / ai / bot / noise, and no
  `scanner`, because `scanner` is a visitor-level promotion only `_tally_batch`
  computed. So the page an operator actually opens could not show the largest
  class of traffic on their site: 71.7% of events on the instrument, sitting in
  `noise` and `human` instead. Its arithmetic was never wrong on its own terms;
  the total was right and the attribution was not, which is harder to notice.
  Both readers now drive the same ingest and project the day buckets into the
  page's shape - a projection rather than a second pass, because promotion needs
  the probe tokens known before counting and a streaming reader would have to
  read the logs twice, which SM342's counters would report as the code doing
  more than it did. **`anonymise_ip` is RETIRED** (the shared tally always
  truncates to /24 and hashes, as the export always did); a conf still carrying
  the line is inert and `lazysite-check` says so. **The second counting
  implementation is gone**, which is the durable win - two implementations of
  one count is how SM329 came to be fixed in two places and missed in a third.

- SM362 (3b11b8f) filed: **the engine resolves two meta values that no real site
  ever renders.** `page_meta_title` and `page_meta_desc` are resolved and frozen
  before a layout runs, and all 23 catalogue layouts overwrite both - so an
  author setting `meta_title` in front matter changes nothing on any site using
  a shipped layout, and nothing says so. SM300 fixed the engine half and
  correctly defers to a layout that emits its own tag; the qualification in its
  status note is now measured, and it is not "some layouts" but all of them. The
  same survey found every layout applying `| html` to an already-escaped
  `page_subtitle`, so ordinary copy reaches search engines double-escaped -
  which is actively wrong rather than merely inert, and is the half worth fixing
  first. Same shape as SM337 for navigation: the engine is right and
  unreachable.

- SM342 (5cdef3b) **the perf gate measures work, not only the clock, and reports
- SM337 (695972b) **activating a layout now says what it bound.** Installing a
  layout, activating it, saving a navigation and fetching the page all returned
  success while the site's own menu was never rendered - 22 of 23 catalogue
  layouts carry hard-coded links belonging to the gallery they were built for,
  and one renders a fictional company name on whatever site activates it. The
  only way to find out was to install, bind, render and look, which nobody
  inserts after four consecutive `ok:1`s. The validator already had the template
  open, so the check cost a regex: activation reports `renders` for nav, content
  and the resolved meta values, and warns when there is no `[% nav %]` - naming
  the consequence rather than the missing directive. **It does not refuse**,
  because activating a showcase is a legitimate choice and a tool that refuses
  legitimate choices gets worked around. Catalogue half is SM349; SM362 rides
  the same read.

- SM343 / SM341 / SM339 (ffb4204) **the durable day store: made complete, dated,
  and repairable.** Three filings, one artefact, done together because each
  blocked the others. SM343: a closed day file was frozen at the last export
  call made DURING that day - today's file was refreshed every call and a closed
  day written only if absent - so a file created at 14:00 on Tuesday WAS
  Tuesday's permanent record. A day file was complete only if nobody looked at
  the statistics that day; measured in the field, one day frozen at 19:23 with
  838 scanner hits absent because a validation agent read the store during it.
  **Reading the statistics damaged the statistics.** A closed day is now written
  once more when it closes, which also repairs history automatically on upgrade:
  an existing site's short files are rewritten from buckets that are complete.
  SM341: `generated` on the day and month payloads, so two rollups can be
  ordered from the artefacts rather than from the notes of whoever fetched them.
  SM339: `--recount`, **dry run by default** because it writes over the only
  durable record a site has, bounded by the retained logs because that is all it
  can honestly rebuild, and reporting per-day before/after because "it ran" is
  not a result. Durable files are written canonically now, so a repair is
  checkable with `diff`.

- SM356 (992122d) **the update channel failed open, and a typo granted more than
  the word it misspelled.** `update_channel: stabel` did not fail, did not warn,
  and did not mean stable - it meant `all`, accept every build including edge,
  because an unrecognised value fell through to the most permissive rung in
  silence. Three fall-open paths in `read_update_channel` (unreadable conf, no
  line, unrecognised value) and two more in `channel_refuses`, where
  `$CHANNEL_RANK{$x} // 0` is `edge`. A comparison whose unknown case is the
  permissive one is not a gate. Now: `all` is a declared rung rather than a
  fall-through, anything unrecognised falls to **stable** - the most restrictive
  rung - and is REPORTED as well as corrected, and both sides fail closed on an
  unknown value. The fleet updater prints each site's channel so the policy is
  legible rather than inferable. **Behaviour change:** a site with no
  `update_channel` line stops accepting edge and beta builds, which is the
  intended direction; provisioning already writes `stable`, so only older sites
  are affected. The other half of SM345.

- SM354 (274be4b) **seventeen changelog entries cited commits that no branch
- SM355 (deb1efd) **every 404 on a site declared somebody else's URL as its
  canonical, and a stranger could choose which.** Measured on edge: every missing
  URL emitted `canonical -> /feed.xml`, and `/feed.xml` itself 404s there - so
  the page served for missing documents pointed crawlers at a missing document.
  The rendered 404 is cached as a file, and the render injects a canonical taken
  from `REDIRECT_URL`, so the FIRST request to any missing URL baked its own path
  into the file every later 404 is served from. An anonymous visitor who is first
  to miss after a cache clear therefore decides what every 404 on that site
  canonicalises to - same-origin, so not a redirect, but every missing page then
  names a URL a stranger picked. **Demonstrated on the live instance from
  outside**, by clearing the cached 404 and requesting a chosen path first: an
  unrelated missing page then carried it. The check could have failed, which is
  what makes it evidence. A 404 now carries no canonical at all, because a
  missing page has none. The cache file is rewritten too, since the front end
  answers `/404.html` directly with 200 and never consults the engine, and that
  response carries `noindex` - the only instruction that reaches an indexable
  soft 404 the engine never sees. Found by the partner agent's four-surface pass;
  the mechanism is not the one it looked like from outside.
- SM357 (e846971) **a pre-commit hook refusing commits on `main`.** The contract
  already said work happens on a `claude/<feature>` branch that vcs-review
  lands; roughly thirty commits went straight onto main in one session and the
  first anyone saw of them was a release - including two defects discoverable
  from a diff that cost a release cycle each instead. The rule was not missing;
  the moment was, since nothing about committing to main asks anything of you.
  Committed to `githooks/` rather than `.git/hooks` so the rule is reviewable
  and survives a clone (`scripts/install-hooks.sh` sets `core.hooksPath`).
  Deliberately bypassable - a guard that cannot be got past in an emergency is
  uninstalled rather than obeyed - and it allows an in-progress rebase, merge,
  cherry-pick or bisect, because vcs-review lands onto main BY rebase and a
  guard that blocked the sanctioned route would be removed within the hour. Its
  own test found a fail-open path in it: `rev-parse --abbrev-ref HEAD` fails on
  a branch with no commits, so the branch resolved empty and the commit was
  allowed.

- SM345 (1ab6098) **a release touched every site on the host, not the ones it
  was for.** The per-site install was channel-gated; every other phase was not.
  An edge rollout refreshed the shared web template, rebuilt every vhost, and
  ran `repair --all` and `probe --all` across sites sitting on beta and stable -
  and `repair` WRITES, so an edge release made changes to sites running older
  code. Scope is now computed once, before any phase acts, by asking
  `install.sh --channel-check` (the same code the deploy obeys - not a second
  copy in bash); every phase iterates only the in-scope set, and out-of-scope
  sites are named once as untouched. `repair` and `probe` run `--domain` per
  in-scope site. The shared Hestia template is the one thing that cannot be
  scoped - it now says how many out-of-scope sites it reaches - and the deploy
  watcher no longer passes `--rebuild` on every deploy, which was the immediate
  cause. **An edge release touches edge sites; only a stable promotion touches
  stable sites.**
- SM346 (1ab6098) **the Users page hid every operator-only control from every
  human.** It gates promote-to-top-level and the scope-independence toggle on
  `amOperator`, computed by looking for itself in the groups granting
  `manage_users` - and `users-page` never told it who it was, because that call
  consolidated three earlier ones and carried forward the data of two and the
  identity of neither. So the username searched for was empty, no membership
  test could match, and no human qualified including a full operator. Reported
  as agents being able to do something humans could not: agents drive the
  control API and MCP, which have no UI gate. Nothing was wrongly permitted -
  the API enforced correctly throughout - a capability was silently withheld.
- SM344 (d533882) a successful rollout reported failure and asked for a version
  bump. The 0.10.12 edge rollout installed and verified on every site that could
  accept it, and was independently confirmed serving from outside - then exited
  1 because the fleet-wide probe found 22 exposed sites on an OLDER line. The
  deploy watcher read that as a failed deployment and printed `bump again to
  retry`, which would burn a version number to re-run a deploy that had worked,
  against a condition no deploy can address. `update-all` now separates the two
  facts one bit was carrying: **1 = the rollout failed and a retry is
  meaningful; 2 = the rollout succeeded and the fleet has findings that need a
  human**. SM317's requirement is untouched - an exposure is still non-zero, so
  a caller reading only `$?` cannot miss one; it can now tell which kind it has.
  The watcher is the operator's own script; the corresponding change there is to
  treat 2 as deployed-with-findings.

## 0.10.12 - EDGE: the numbers say what they mean (2026-08-16)

A statistics release, out of a partner-agent review of a live instance's own
traffic. Every item here is a number that was being reported confidently and was
describing something other than what its name said.

**The headline number on the Stats page will FALL, and that is the fix.** It had
been counting every image and stylesheet on a page as a page view. The tile is
now labelled `Page views`, and the assets it used to include are shown beside it
as `Images and files`, so the drop is explained on the page rather than
discovered.

- SM329 (329786d, 6c0ddbd) an image was counted as a page. Two images sat SECOND
  and THIRD in `top_pages` on the instrument at 124 hits each, and 524 of 5,000
  sampled events were `.jpg`, `.png`, `.css` or `.js`. `top_pages` keeps a fixed
  number of entries, so assets crowded out content by construction rather than
  by accident - one article with four images generates four asset hits per human
  page view - and every derived metric inherited it: "visitors who saw more than
  one page" was 41% against data that gives 5% once an image is not a page and a
  session has a boundary. One predicate now, applied at all THREE counting
  sites. Recording is unchanged: an asset stays in the event stream where it
  still feeds the browser-versus-bot signal, and is counted as `asset_hits` so
  the exclusion is auditable rather than invisible.
- SM330 (329786d) the statistics index omitted `scanner`, which is 71.7% of
  events on the instrument against 17.2% human - so the front page showed a
  breakdown summing to a small fraction of the traffic, with nothing to say a
  part was missing. The class list had been written out by hand in four places
  and the shortest copy was the one people saw first; it is now declared once
  and every view derives from it.
- SM332 (6c0ddbd) a WordPress path sweep ran as `human`. Every trigger promoting
  a visitor to `scanner` was a signature, and signatures date: `/wp-login.php`
  is caught by the `.php` rule and its modern replacement `/wp-json/batch/v1` was
  caught by nothing. Small by volume - 27 events, 4% of human-class events - and
  it would have been the top journey on the site the moment trail metrics
  existed. A visitor asking for five or more DISTINCT missing paths inside five
  minutes is now a scanner whatever the paths are, both numbers are settings with
  stated defaults, and the rollups carry `scanner_inferred` so an operator can
  judge the threshold against their own traffic. A reader following stale
  bookmarks keeps their `plausible` 404s, which are the more useful signal of
  the two.
- SM331 (bf3e933, 01fa828) **closed by measurement.** A static file fetched while
  public kept serving for up to a minute after the folder was protected. The
  engine was cleared first - no copy is left in the document root, and every
  file reaches the private store - and the partner agent then measured it on the
  host with the front end untouched: the fetched files gated at 60 seconds, a
  never-fetched control gated immediately. That is a descriptor cache ageing out
  on `open_file_cache_valid`, so the severity is a bounded sub-minute transient
  rather than a silent failure. `check --check-acl` now fetches its probe folder
  WHILE PUBLIC before gating it, which is the only version of the probe that can
  construct the case at all, and the bound is asserted on every run instead of
  believed.
- SM340 (755690f) the statistics export cache was written on every run and
  **never read**. The loader accepted version 1; the first-party ingester -
  which is the default path - writes version 2, so the load returned undef and
  the cache was discarded every call. The per-file byte offsets, the entire
  point of the incremental design, had never once been used. Consequences, in
  order of sharpness: a day whose log had rolled off **disappeared from the
  index** while its durable file sat on disk reachable by nothing; every day was
  re-tallied under the current basis on every call, which is what defeated
  SM338 rather than merely failing to help it; and every export re-read every
  retained log, measured in the field at 3 to 3.5 seconds per call with
  `window=1` costing what `window=365` cost.

  Found by sabotage rather than by reading the version numbers, which is how it
  survived. The first attempt at the fix reproduced the bug for a completely
  different reason - a package hash assigned below the dispatch that reads it -
  which this file already carries three comments warning about.

  The cache fix alone would have degraded classification, and passed the whole
  suite while doing it: with the cache honoured, a scanner promoted in a later
  batch could no longer reclassify the requests it made earlier, which is
  exactly the homepage hit SM213 classifies per visitor to remove. So the
  per-event tally is now one reversible function, and a promotion reaches back
  through the event ring to move the aggregates, not merely the labels.

  Measured 630.7 to 424.9 ms per call on a 30-day fixture. That figure is from
  a development host with a fast uncontended disk and does not predict the
  field: the operation is I/O-bound, real sites sit on contended shared storage,
  and the instrument's own measurement came over a remote surface as well. The
  direction transfers and the numbers do not.

  The export also stopped publishing its internal event ring verbatim - the
  reach-back needs each event's referrer, and a ring handed out whole would have
  published one attached to a visitor token as a side effect of a performance
  fix.
- SM338 (0c6d1de) a change in what a number MEANS is now visible in the data.
  SM329 changes what a page view IS, and a closed day file is written once and
  never rewritten - so the series steps at whatever date each instance upgrades,
  which is per-site and recorded nowhere. Worse, the current month's rollup is
  refreshed every call, so in the month an instance upgrades it sums days
  counted both ways into one total, and the month-on-month delta built from it
  is the first number anybody looks at. Every day, month and index row now
  carries its `counting_basis`, and says when it is mixed. A day rolled up
  before this release reads as basis 1 rather than as unknown, because it was
  definitely counted somehow. Raised by the partner agent while this release was
  in the gate, and it held the cut: written at the time it costs one integer per
  day, and written later it cannot be written at all.
- SM334 (c4af05f) `read_settings` was re-parsed on every token verification -
  1.37 ms of JSON parsing per authenticated request, in a call its own comment
  described as one cheap read. Memoised per process on the file's (mtime, size)
  rather than on a clock, because this decides who may do what and a stale entry
  is an access-control answer from the past. 1.3727 ms to 0.0045 ms.
- SM333 (128fbe4) the fleet addressing did not reach the deployment it was built
  for.

Gate: `tools/bench.pl` gains `stats_export_ms`, with a fixture carrying thirty
days of first-party logs - the stats path had no performance coverage at all,
which is why a per-call cost of that size went unmeasured, and an op pointed at
an empty fixture would report a fast, stable, meaningless number. The check was
hiding a gap of its own: an op with no baseline figure was skipped **silently**,
so adding an op looked like coverage while being compared to nothing. It now
names what it did not check. The new op has a first baseline figure and every
other op is untouched, because SM327 records that re-capturing those would bake
in the measured drift.

Docs: the access-control model now states that protection takes effect within
the front end's cache validity, and names `open_file_cache_valid` as the setting
that decides the window - nothing is asked of the front end and no default
changes, but an operator who has raised it should know what they have
lengthened. SM327's perf drift is attributed (one step above the noise floor,
the rest accretion, and the 2x tolerance is why nothing caught it); SM335 (the
Stats page and the export use different class vocabularies) is filed as a
candidate, as are SM343 (a closed day file is frozen at the last export call
made during that day, so it is short by everything after it - a day file is
complete only if nobody looked at the statistics that day; pre-existing, the
recomputed views have always been right, and it makes SM339 a repair rather
than a re-basing), SM342 (every benchmark figure this project holds was taken on
a development host with a fast uncontended disk, while real sites are on
contended shared storage and the operations that matter are I/O-bound - the
third member of the family with SM327's loose tolerance and SM340's missing
coverage), SM341 (a day or month payload cannot say when it was produced), SM339 (recompute the day rollups from the retained raw logs,
so the series is continuous AND correct - deliberately not bundled here, because
a recompute writes over the durable store and belongs in a release where it is
the thing being tested) and SM337 (activating a layout that cannot render the
site's navigation returns ok:1 four times over, and the engine knows at
activation whether it can).

## 0.10.11 - EDGE: protecting content works from the surfaces built to do it (2026-08-16)

The 0.10.10 field pass confirmed **SM283 closed on the instrument, measured
anonymously from outside for the first time** - all 31 extensions gating, 31 of
31 files in the private store. It also found that only the OPERATOR could get a
site into that state. This release is mostly that, plus the structural change
that stops it recurring.

**No operator action is required, and one becomes unnecessary.** From this
release the installer provisions the private store, so a site never reaches the
state where protecting content half-works.

- SM323 (a1a564d) protecting content had become an operator-only
  operation. Two code paths created the private store - `Private::_mkpath` with a
  bare `make_path`, and `check --fix` with an explicit owner and mode - and
  whichever ran first decided. The operator sweep runs as the SITE USER and gets
  there first on any site being repaired, so the store ended up owned by the site
  user with no group write and the CGI was locked out. Measured on edge: `acl
  reapply` moved content successfully while the control API returned
  `content_moved:0` and `Permission denied` on the same instance, with 8 of 10
  extensions still served anonymously under an active read rule. Store
  directories now carry the DOCROOT's identity at every level, and `check --fix`
  REPAIRS an existing store rather than only creating a missing one.
- SM321 (40bb221, 3a10175) **partial** - the operator
  should decide, not orchestrate. The private store was the only runtime
  directory nobody declared, and that one omission produced the whole chain
  above. It is now in `runtime_paths` like every other directory, so install
  provisions it, upgrade repairs it, and no code path has to decide who owns it.
  Separately, `lazysite check` and `lazysite acl` take `--domain NAME` or
  `--all`, resolved through the registry that has held each site's docroot and
  cgibin all along - so nobody reconstructs `/home/<user>/web/<domain>/...` by
  hand. And `run_tool` now passes `-I`, without which the documented repair
  command failed with `Can't locate Lazysite/Paths.pm` **even when typed
  correctly**. Remaining: moving the ACL probe and repair sweep out of the Hestia
  script into CLI verbs, and the three-section deploy output.
- SM322 (a1a564d) the theme-asset mirror count never reached the
  per-domain path. SM315 gave activation an `assets_mirrored` count because zero
  is the whole point; with a `host`, MCP routes through `domain_set`, which ran
  the mirror and discarded the result. So on the path a MULTI-DOMAIN instance
  uses - the one whose failure SM315 was written about - an agent got `ok:1` and
  no indication whether anything was published.
- SM324 (a1a564d) `--reapply-acls` has been sweeping the sites it
  was written to skip. `in_list` was defined below three callers; bash resolves
  at call time, so it was `command not found`, which returns 127, so
  `in_list ... && continue` never continued. Sites held back by their update
  channel and sites that FAILED to upgrade were swept anyway. `t/lint/50` holds
  the class.
- SM325 (8bd2642) `release.sh` refuses to tag a commit on no branch.
  0.10.10 was cut twice: the first tag named a branch tip, vcs-review then landed
  that branch with new SHAs, and the tag was left pointing at a commit no branch
  contained. A re-cut is a full gate run; `git branch --contains` is a second.
- SM304 (8bd2642) **partial** - a manifest that is present but
  UNPARSEABLE is now treated as absent and regenerated. A power cut left
  `release-manifest.json` as 66,505 bytes of nulls; it is gitignored, so
  `git status` reported the tree clean, and both readers died differently while
  neither considered regenerating a file it knows how to regenerate. The
  duplication that made it two failures is untouched.
- SM326 (9061fe5) an argument required on one surface must be
  required on the other, or the difference recorded. `t/lint/52` pairs MCP's
  required-argument lists against the control API's dispatcher defaults - the
  gap that let `acl-set` take a live site off the air (SM306) while MCP had
  always refused the same call. It converts `git-history`, `git-show` and
  `git-restore` from safe-by-accident to safe-on-record.
- Three new lints (50, 51, 52) and three new test files, each shown to fail on
  0.10.10 as shipped.

**One finding is recorded rather than fixed.** The perf baseline is six weeks
stale and re-capturing it was the queued task; measuring first showed every
operation running 9-26% slower than it on the same host, same Perl and low load,
with `verify_token_ms` at +26%. The gate's 2x tolerance passes all of it.
Re-capturing would have made the regression the new definition of correct, so it
is filed with the measurements instead - see `SM327` - and the baseline stands
until the drift is attributed.

## 0.10.10 - EDGE: what the engine reports, and what a visitor actually receives (2026-08-15)

Field-test follow-ups from the 0.10.9 pass on edge, plus one defect found while
proving another fix had not broken anything. Nothing here changes a rule or a
stored format; the risk profile is deliberately low.

**No operator action is required.** The 0.10.9 sweep and the docroot repair it
depends on are still outstanding wherever they have not been run - see 0.10.9
below and `UPGRADE.md`. What changes here is that the rollout now repairs a
non-writable docroot itself rather than only reporting it.

- SM305 (158b828) one way to name a principal, on every manager surface. Five
  different controls had grown for one job: a real `<select>` on the per-file
  card, a bare text box on the section sheet, and `<input list=...>` datalists
  on Groups, Users and Domains. The strictness ran backwards - the loosest of
  them, offering no suggestions and validating nothing, governed who may READ
  protected content, where a mistyped name granted the section to nobody and
  reported success. On Domains the same typo left a domain nobody could manage.
  All five now use one shared `<select>`, built from one source, because a
  `<select>` cannot express a principal that does not exist. A datalist is not
  sufficient: it suggests known names and still accepts anything typed over it,
  so it looks constrained and is not. Server-side validation is unchanged and
  still authoritative.
- SM310 (0d5e95b) a site-wide rule was enforced, listed, and unreadable. SM287
  taught both ACL writers and the sections panel that `/` means the whole site
  and left `action_acl_get` behind, so asking what rule governs the site root
  answered `acl: null` while the rule was in force on every request. Bounded:
  the rule was enforced correctly and remained removable, and the sections panel
  was right throughout - which is why nobody noticed. Found by a control subtest
  written to prove the SM306 fix had not broken site-wide rules.
- SM306 (4e2ab69) `acl-set` with no path took the whole site private. The
  control API derives its target once for every action, defaulting to `/` - right
  for `list`, harmless for `acl-get` and `acl-remove`, and inherited by the one
  action that can take a site off the air. Inert before SM287; hazardous since.
  An explicit path is now required, and a `path` key in the JSON body is refused
  by name rather than discarded in silence. `acl-remove` keeps its default: its
  direction of failure is recovery, and a safety change must not make a site
  harder to rescue than to break. The same operation over MCP always required a
  path.
- SM307 (eb8dc7c) the private-store move named a cause it never checked. It
  reported "cannot move a folder across filesystems" for any failed `rename` on
  a directory, without consulting `$!` - so a permissions fault sent an operator
  to inspect mounts when the fix was a `chown`, and contradicted the `lazysite
  check` report that shipped beside it in 0.10.9. Both directions now share one
  reporter: a genuine cross-device directory move still refuses (a recursive
  copy would reopen the window `rename` exists to close) and names both ends;
  anything else says what `$!` says and points at the check that diagnoses it.
- SM309 (c12cfec) front-door mode is a yes/no value, and `lazysite check` says
  which it is. `FRONT_DOOR=false` switched it ON - any non-empty value except
  `0` did - and nothing anywhere reported whether the mode was active, since the
  only observable lives in a proxy template that is not installed where it
  matters. The pool now accepts `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`
  and refuses anything else by name, checked before it creates anything; and
  `lazysite check` reports ON, OFF or a bad value, read from the pool conf and
  matched on DOCROOT rather than the instance name.
- SM308 (45868c1) the `<head>` contract, stated. `meta_title` and `meta_desc`
  shipped in 0.10.9 and reach no real page: all 23 catalogue layouts write their
  own `<title>` and description, none consult the resolved values, and 22 derive
  the description from `page_subtitle`. The engine is right - it defers to a
  layout that writes its own head - and the layouts are not at fault, because
  the worked example in this project's own briefing showed it that way. The
  briefing now carries the contract and `t/lint/48` stops the examples teaching
  otherwise. **The 23 layouts are a separate repository and are NOT fixed by
  this release**; until they are, both fields remain inert.
- Rollout (eb850d2) the health summary repairs what it finds, then checks again.
  SM270 recurred on edge three releases after the ordering fix, because a vhost
  rebuild driven through the control panel never reaches the update script. A
  non-writable docroot is not cosmetic: the private store is its sibling, so
  `acl reapply` fails on every folder and protected content stays served. The
  summary now runs `--fix` and re-checks, printing the outcome rather than the
  action; anything still dirty is named under NEEDS A HUMAN.
- SM313 (9e91807) repairing the docroot never reached the private store. The
  store is a SIBLING of the document root, so creating it needs write access on
  the docroot's PARENT - a different directory, which SM270's repair does not
  touch. Measured on a live instance AFTER a complete docroot repair: 11 of 11
  entries still public and eight of ten probed extensions serving 200
  anonymously under an active read rule. `check --fix` now CREATES the store
  rather than widening its parent - that parent also holds `cgi-bin`, and write
  permission on a directory is permission to rename its entries. Separately,
  `acl reapply` counted a move that never happened as a re-apply, so a sweep
  that left every byte in place reported success and exited 0; it now counts
  `moved nothing` separately and exits non-zero.
- SM314 (47d633e) `install_layout` documented an activation it never performs.
  Four statements describing behaviour SM176 deliberately removed, published
  through `tools/list` to every agent, one of which routed agents into an
  always-refused delete. `t/lint/49` now checks every documented default against
  what the handler applies - nine descriptions state one and none was verified.
- SM315 (0eeaaa6) theme assets one directory out served an unstyled site with
  every signal saying it worked: `ok:1`, 200, no stylesheet. Activation now
  reports how many assets it mirrored, names a misplaced one specifically, and
  `lazysite check` carries the standing version.
- SM316 (ee44916) every URL a generated registry advertises is now fetched and
  asserted to resolve. Verified against SM299 itself: reintroducing the old
  expression makes it fail with `/docs/.md -> 404`.
- SM317 / SM319 (92e5117, 5e3307e) the rollout now asks the FRONT END, not just
  the engine, whether an ACL is honoured - `check --check-acl` per site, which
  existed and which nothing ran. Reviewed by the site agent within the hour: the
  first version derived a pass from the ABSENCE of failure, so a probe that
  fetched nothing reported success. That is the defect the probe itself shipped
  with (SM285). The pass now requires a positive confirmation, so all four
  non-passing outcomes - and any added later - fall to `not confirmed`.
- SM318 (feff4b8) the MCP nav tools could not address a domain, and had their own
  implementation missing the SM168 cache invalidation - so an MCP nav edit
  returned `ok:1` and the site served the old menu. One implementation now serves
  both surfaces, per SM301's precedent, and both take `host`.
- SM320 (31981c4) a layout is now rendered and its output asserted - nav with
  children, page body, resolved meta, and escaped exactly once. It was the only
  major component with no behavioural test.
- Five new lints and tests (47, 48, 49, plus t/tools/41 and t/integration/53-55),
  each shown to fail on the unfixed tree before being trusted.

## 0.10.9 - EDGE: the sweep that finishes the 0.10.8 move (2026-08-14)

**Operator action is required, and no package upgrade performs it.** From
0.10.8 protecting content moves it out of the document root - but only on the
ACT of protecting. Every section protected on an earlier version still has its
FILES in the served tree, with its rule honoured for pages and its files
public; measured on a real upgraded site, 19 of 25 extensions were still served
byte-identically to an anonymous request. On 0.10.8 the SM296 crash could leave
the same state on a site that DID protect something.

Both are repaired by the same sweep, which this release adds and which changes
no rule:

```
lazysite acl reapply --docroot D --actor local --apply      # one site
lazysite-hestia-update-all.sh --rebuild --reapply-acls      # a fleet
```

Order matters: upgrade first, then sweep - the re-apply is the operation SM296
broke. Verify from OUTSIDE with `lazysite check --check-acl URL`; the engine's
report and the front end's behaviour are different claims, and SM283 was the
case where they disagreed. Full detail in `UPGRADE.md`.

- SM296 (50991b7) protecting content crashed and left it served.
  `File::Path::make_path` CROAKS rather than returning false, so the guard on
  the next line was unreachable and a protect call died after storing the ACL
  and before moving the content or writing the audit line - leaving content
  stored-as-protected, still served, and absent from the trail. The mechanism
  built to make SM283 structurally impossible was failing into SM283.
- SM294 (7fe8ad9) the front door runs inside the FastCGI pool. Dispatch ended
  in `exec()`, which replaces the worker, so the pool could not run the
  one-rule front door at all. The worker now consults the same routing table
  and splits by what it can be: a page, a miss, a content static and a denial
  are answered in-process, while another surface or anything needing the auth
  wrapper is relayed to a forked child with a timeout. Measured like for like,
  an anonymous page goes 71.9 ms to 0.53 ms (137x) and a signed-in page
  107.3 ms to 96.9 ms - never slower. `FRONT_DOOR=1` in the pool conf; an
  existing pool is byte-identical without it.
- SM294 pooled one-rule vhost templates for Apache and nginx. The nginx one
  loses the session carve-out, the ACL-store conditional and `try_files`
  outright - the worker makes all three decisions.
- SM299 (7ad34f9) every site's `llms.txt` opened with a dead link. The template
  appended `.md` to a page URL; an index page's URL already ends in a slash, so
  the homepage entry was `/.md`. It was the first line of the file and the
  entry an AI client is most likely to follow.
- SM300 (7ad34f9) `meta_desc` and `meta_title`. `subtitle` was doing three jobs
  - visible subheading, meta description, and llms.txt description - so a page
  with a designed hero had to choose between a subheading it did not want and
  NO description at all. Both fields were already named in ADR 0008's
  compatibility freeze and neither existed. They override and fall back, so
  every existing page renders unchanged.
- SM301 (9bd14e9) `regenerate-registries` on the control API. It had been
  MCP-only since SM264, so an account holding `manage_content` on a WebDAV +
  control-API grant could not call the action its own capability grants.
- llms.txt defaults (9bd14e9): bundled documentation no longer registers for
  `llms.txt`, and starter content now does. A customer site's llms.txt listed
  ~30 lazysite doc pages and none of its own content; on upgrade it shrinks to
  the site's own pages.

Compliance and release machinery:

- `tools/lazysite-compliance.pl` (a8ff277) runs first in the release gate and
  refuses a cut when a compliance record is behind the version being cut.
  Blocking differs by channel - a Declaration of Conformity behind the version
  is advisory on edge and blocking on stable.
- `docs/compliance/` (a8ff277): one dated obligations register anchored on dates
  AND versions, the Annex VII technical file as an index, and two operator
  templates plus a handover document, all packaged so an operator installing
  from the deb receives them.
- The fourth eight-dimension review, at `docs/review/2026-08-14-eight-dimension/`.

Fixes to the tree itself:

- `release-manifest.json` (b4cb029) is derived when absent, so a clean checkout
  of a tag passes its own tests and can run its own SBOM gate. Fifteen test
  files and a CRA control needed a gitignored build artefact.
- The "intermittent" install-test failure (4794ba2) was deterministic: a stale
  manifest in the working copy. `repo_manifest_guard` now guarantees a manifest
  that DESCRIBES THIS TREE, and `t/lib/FlakeLog.pm` records outcomes so the
  next one accumulates evidence instead of an anecdote.

Tests:

- `t/lint/42` drives both copies of the routing table and compares answers.
- `t/lint/43` pins a trap worth naming: FCGI.pm replaces the request
  environment on every request, so a pool setting read inside the loop is
  silently always-off in the one deployment it exists for.
- `t/lint/44` asserts the operator templates substitute cleanly in both
  directions.
- `t/lint/45` asserts every front-matter field ADR 0008 freezes actually exists
  - the class that produced SM300.
- `t/lint/34` now globs the nginx configs it parses; it was green on a config
  it had never parsed, the fourth hand-maintained list in this repo to fail
  that way.

## 0.10.8 - EDGE: the front end stops making decisions (2026-08-13)

One theme, and it is the largest structural change in the 0.10 line. SM248,
SM268 H17 and SM283 were all the same cause: security living in front-end
configuration that lazysite ships as a template, cannot test where it is
installed, and on most deployments cannot even see. SM283 ran live across a
fleet for weeks. Every fix before this had been "put the rule in one more config
file"; this release is the other answer.

**Nothing changes on an existing site until you ask for it** - and that has a
consequence worth stating outright, because "no operator action required" is
true of stability and not of exposure: **every section protected BEFORE 0.10.8
stays in the document root, and therefore stays exposed on any front end that
serves statics by extension, until its rule is re-applied.** Measured on a
0.10.8 site after upgrading: 19 of 25 extensions still served byte-identically
to an anonymous request. The action is a re-apply sweep. (SM296: on 0.10.8 that sweep
crashes - fix pending.) Every move in this release is opt-in and reversible:
protecting content moves it out of the document root (new behaviour, on the act
of protecting); the engine tree moves only when you run
`lazysite migrate-engine-tree --apply`; the one-rule vhost is an option beside
the existing templates, which keep working unchanged.

Two things to know before deploying:

- **The generated registries stop being written into the document root.** They
  are produced on request and cached instead. Any `sitemap.xml`, `llms.txt` or
  feed left over from before will keep being served by the front end and will
  never refresh - `lazysite check` names them, and you should delete the ones
  you did not write yourself.
- **Protecting content now moves it.** A read list or `draft` takes the content
  out of the document root; removing the rule brings it back. Backups cover the
  new location; site packages and the content history deliberately do not, and
  say what they left behind.

What shipped:

- SM285 (d0428a6) a site can prove its own gating works from outside, whatever
  is in front of it - `lazysite check --check-acl URL` gates a probe folder and
  fetches it anonymously under six extensions, because SM283 leaked `.png`,
  `.pdf` and `.txt` while gating `.dat`, so a one-extension probe reports a
  leaking site healthy
- SM287 (a522f5d) "this whole site is private" is now something that can be
  said. A root entry was inert under every spelling, so a wholly-private site
  had to enumerate its top-level folders - a workaround that fails OPEN as
  content grows
- SM288 (1fa933b) one account, one set of groups, whichever channel it arrives
  on. MCP and the control API discarded a partner's groups while WebDAV
  resolved them, so an `@group` rule applied on one channel and silently to
  nobody on the others
- SM290 (63a1efc) the access-control reference, and `t/lint/36` asserting its
  factual tables against the source - this document had twice stated the
  opposite of the behaviour and been believed
- SM291 (912c345) a malformed boolean published a hidden section and reported
  success: `draft: "yes-please"` cleared the flag, turning a folder that
  answered 404 into one that bounced to login
- SM286 (4e89ebc, 79c3fec, 08ce4bc, 703e839, 9f63a76, 00665cb, 33ef773,
  5ea70af) **protecting content now moves it out of the document root**, into a
  private store beside it, and moves it back when the rule is lifted. If the
  bytes are not in a directory any front end serves, no front-end rule is needed
  and none can be got wrong - SM283 becomes structurally impossible rather than
  fixed once per deployment shape. Backups cover the store; site packages and
  the content history cannot carry it and now report what they left behind. The
  site-root rule is the exception and says so
- SM292 (5ea70af) the "held back" panel was empty for everyone who used the
  manager, MCP or the control API - it filtered on a trailing slash and the
  writer stores keys without one, so it listed hand-edited entries and nothing
  else. Exactly the failure SM267 built that screen to prevent

- SM289 (abd2d5b, bb3dfce) access can now be set from a shell: `lazysite acl
  list|show|set|remove`, calling the same writer as the manager, the control API
  and MCP - so a rule set from a shell is the same object, and gets the same move
  into the private store. `--actor` is mandatory for a write and carries exactly
  the authority that account has in the manager; there is no session behind a
  shell, so a tool that defaulted to an operator identity would be a way round
  every check the other surfaces make. `acl-set` and `set_permissions` are
  deliberately NOT renamed - both are in live partner use and the mapping is
  documented instead

- SM295 (9d7e8cb) three repeat traps become checks, after the operator asked
  whether they could be structural rather than remembered. `t/lint/39` fails on
  file-scoped state initialised below the main body - and found a THIRD live
  instance on its first run (`%OEMBED_PROVIDERS`, shipped for months, leaving a
  documented SSRF mitigation inert because every oEmbed fell through to
  autodiscovery). `t/lint/40` fails on a list interpolated into a shell command
  string, the trap that made two working tools look completely broken in one
  day; `TestHelper::run_cmd` is the one correct way and four call sites are
  converted. `tools/coverage.sh` gains an flock and a live-writer check, so two
  runs cannot corrupt each other and an orphaned `prove` is named rather than
  silently poisoning the database
- SM293 step 5 (b87e008) **a front end can now be ONE RULE.**
  `Lazysite::FrontDoor::route()` makes every routing decision the vhost
  templates used to make, and `lazysite-front.pl` executes it; reference configs
  ship for Apache and nginx. The value is testability: route() is a pure
  function, so the whole routing table is asserted directly, and t/integration/49
  drives the one-rule shape through REAL Apache - the templates could never be
  tested, which is how SM248, SM268 H17 and SM283 each happened. The nginx config
  matters most: nginx has no CGI, so every other nginx template answers statics
  from a per-extension list, and deciding by suffix is exactly what SM283 was.
  The trade is stated rather than hidden - one rule costs a process per request,
  so the fuller templates remain as PERFORMANCE options whose absence costs speed
  and never correctness. SM294 files the remaining gap (the front door under the
  FastCGI pool, which needs in-process dispatch and a change to the auth
  wrapper's exec-based design)
- SM293 steps 2b + 3 (0f5ec80, e305232) **the engine tree can be moved out of the
  document root**, with `lazysite migrate-engine-tree --docroot D | --all` -
  dry-run by default, `--back` to reverse, `--min-version` so a fleet follows a
  release through its channels, and as root it drops to each site's owner. A
  half-migrated site is refused rather than repaired. install.pl and
  lazysite-check both had to learn the resolver first, or the next upgrade would
  have recreated the tree inside the docroot and the health check would have
  verified nothing on a migrated site. And the generated registries
  (sitemap.xml, llms.txt, the feeds) are **no longer written into the content
  root at all** - generated on request and cached outside it, one render per TTL
  rather than one per crawler hit, with an operator's own sitemap.xml still
  winning and `lazysite check` naming any leftover file from before the change
- SM293 steps 2a + 4 (6dadcd9, 85b48d2) the engine now ASKS where its own tree lives
  (`Lazysite::Paths`) instead of computing `<docroot>/lazysite`, so a site can
  migrate it out of the served tree by MOVING the directory - no config key, no
  flag day, both layouts on one code path, and `lazysite check` FAILs on the
  half-migrated state. Nothing moves yet: the migration touches live credentials
  on every site and is a release-manager decision. `t/lint/37` pins the
  processor's module-free copy against the module and forbids any surface
  rebuilding the path for itself - which found thirteen call sites, plus the
  health tool refusing to look at a migrated site and the users tool creating a
  second account store on one. Separately, the front-end trust-header strip is
  demoted from a requirement to recommended hardening, after `t/lint/38` was
  written to make the in-app gate an enforced control rather than a claim

Docs: `docs/architecture/access-control-model.md` gains the private-store
section and a setting-access-by-surface table; `docs/FEATURES.md` explains the ways access can be limited. SM286 is
closed on step 1, its substance; SM293 carries forward the rest of the direction
(taking `lazysite/`, the generated registries and the sidecars out of the served
tree). SM289 (one way to express access on every surface, including a CLI verb)
remains open.

## 0.10.7 - EDGE: a protected section was protecting its pages and publishing its files (2026-08-11)

An edge build on 0.10.6, and the reason to take it is SM283: on Hestia, every
site with a protected section has been serving that section's images, PDFs, text
and archives to anyone who knew the path. The pages gated correctly throughout,
which is why nobody saw it.

**OPERATOR ACTION - this fix is NOT delivered by upgrading the packages.** The
layer at fault is nginx, and lazysite has never shipped a Hestia nginx template,
so the new one has to be installed and each domain moved onto it. Same shape as
SM248: correct engine code made unreachable by the layer in front of it, and
therefore fixed by deployment configuration rather than by code in the payload.

```bash
cp /usr/share/lazysite-hestia/templates/lazysite-proxy.* \
   /usr/local/hestia/data/templates/web/nginx/
lazysite-hestia-list.sh                 # who is affected
lazysite-hestia-update-all.sh --proxy   # stage + apply, rebuilds vhosts
```

Then confirm from outside, with no credentials:
`curl -sI https://<domain>/ | grep -i x-lazysite-front` should answer
`X-Lazysite-Front: hestia-proxy/acl`. No header means the domain is still on a
stock proxy template.

- SM283 (a910219, 44dec16) **the front end served what the ACL refused.** On
  Hestia the request path is nginx to Apache. Everything lazysite enforces lives
  in the Apache half, and all four shipped Hestia templates were Apache; Hestia's
  own nginx proxy answers a fixed list of static EXTENSIONS straight off the
  docroot, so those requests never reached the rules. Measured on a live site,
  not inferred: the same bytes uploaded into one ACL'd folder under five
  extensions, four served anonymously and byte-identical, only `.dat` gated -
  because `.dat` was the one extension absent from the list. Deciding this by
  extension cannot be made safe: any such list is a list of the types that happen
  to be protected. The new `lazysite-proxy` template hands a static request back
  to Apache whenever the site has an ACL store, and changes nothing for a site
  without one, so protecting a path stays a pure content action - no vhost
  regeneration and no reload.

  Three further protections came with it, none of them reported, all of them
  invisible for the same reason: **when a layer is missing, every protection at
  that layer is missing.** The engine directory is denied at the proxy too (a
  stock proxy serves `lazysite/backups/preinstall-*.tar.gz` - a complete snapshot
  of the site taken at install - wherever `gz` is on the extension list); so are
  `.brief` sidecars; the SM248 per-domain registries are routed to the engine;
  and the WebDAV body cap is raised so large uploads reach the origin.

  There is now an **observable**, which the filing correctly identified as its
  own finding: three rebuilds and a template install had all produced
  byte-identical responses, so an operator following the release note had no way
  to tell whether anything had changed. `t/lint/33` binds the header to the ACL
  branch, so a template cannot claim it without carrying the rule.
  `lazysite-hestia-list.sh` flags an affected domain as
  `ACL-BYPASSED-BY-PROXY(SM283)`, and `lazysite-hestia-update-all.sh` reports on
  every run whether the front end was checked - including when it was not.
- SM284 (57756f8) **the other four WebDAV verbs explain themselves.** SM235 made
  a PUT into an unwritable directory answer 507 with the condition named and a
  server fault distinguished from a permission decision. DELETE, MOVE, COPY and
  MKCOL met the identical condition and answered "Delete failed", "Operation
  failed", or a 409 worded almost exactly like the one MKCOL returns for a
  genuinely missing parent - and retry, ask and give up are all consistent with
  those. All five now share one helper, which names WHICH directory failed
  (MOVE writes two, and can fail with the destination perfectly writable), and
  MKCOL's two 409s are two answers. Building the fixture found two defects
  nobody had filed: a MOVE could silently become a COPY, because the
  copy-then-remove fallback never checked the removal and answered 201 with both
  copies live; and once that was fixed, a failed MOVE left the copy behind.
- SM266 / SM267 / SM277 (5e508f9, 0a63273) the manager UI batch. Protected
  sections are listed with policy, read list and recursive counts, scope-filtered
  so a confined manager cannot learn that content exists outside their scope; a
  folder can now be protected from its own actions card, with the policy offered
  as a choice of two worded for what each DOES; Publish clears the draft flag and
  keeps the read list, while Remove protection deletes the entry, because those
  are different decisions. Shipped first with the panel able to LIST protected
  sections and not create one - the operator found it, and it is recorded here
  because a half-built feature that reports itself complete is worse than an
  absent one. Preview-as-public is split out as SM282, not rushed in behind the
  correction.
- SM278 (5e508f9) **a security setting reported success and did nothing.** The
  ACL writer silently dropped `draft`, so `set_permissions` with `draft:true`
  returned `ok:1` and stored an entry without it. Found by a site agent
  re-testing 0.10.6. The report named one tool; the mechanism reached all of
  them, because all 51 MCP tools published an `inputSchema` that nothing
  enforced - an unknown argument was accepted and ignored. Both halves fixed:
  the writer honours the flag, and `tools/call` validates against the schema it
  publishes.
- SM279 (587f30e, 861cd9d) the group `dav_scope` is retired, by decision rather
  than repair. It has been accepted, stored and enforced nowhere since 0.7.26,
  when domain-owned access replaced it. The writers now refuse it with a message
  naming the model that does confine; the dead resolvers are deleted, because a
  resolver nothing calls is a second answer to a question that must have one; and
  `lazysite-check` reports a group still carrying the field as a FAIL. **`--fix`
  deliberately does not clear it**: there is no repair here, only a decision, and
  the stale value is the only remaining evidence that somebody relied on it.
  **Any site that set a group `dav_scope` between 0.7.26 and now has an account
  that is not confined as intended** - this release detects that rather than
  repairing it.
- SM231 (0ff239b) notification becomes a channel rather than a function: a
  registry of types, templates that finally deliver the `url` they always
  documented, routing with a bell that cannot be turned off, and emission control
  per type and per form. `Notify.pm` was the least-verified module in the tree at
  56.7%; it is now 89.6%.
- SM153 (2bd02c8) a menu-complete manager walkthrough in `docs/manager-ui-guide/`,
  written for three readers - someone reviewing the product, an agent being
  onboarded, and whoever is owed a tutorial. Every entry carries a **Negative**
  row, which is where an unenforced capability hides. `t/lint/32` checks it
  against the manager's own nav in both directions, so a new menu item cannot
  ship undocumented and a removed one cannot leave a stale page.
- SM274 (c71812c) `check --fix` restores group write on content directories, and
  nothing else. The narrow answer on purpose: widening modes on a live site is
  not a repair a tool should decide.
- SM269 phase 2 (16a5da1) the tier ladder - `make tier-dev`, `tier-review`,
  `tier-release` - so there is one answer per situation instead of a judgement
  call about which subset to run.
- Testing: **lazysite can now run a real front end.** `t/lint/34` puts every
  shipped nginx config through `nginx -t`, and
  `t/integration/42` starts nginx against the Hestia proxy template and
  reproduces SM283's measurement. Both skip where nginx is absent. This is the
  second time a defect has been found in a config the suite could only text-match
  (SM268 H17 was the first), and this time running the server also **falsified an
  explanation this release had written into three separate files** - the
  protection was real, the stated reason for it was wrong, and no text match
  would ever have disagreed.
- Docs: `docs/MANUAL-CHECKS.md` is split into tiers by risk with a register of
  what was actually walked, and tier A is corrected to gate **promotion** rather
  than the cut - a manual pass over new UI cannot block the release that
  introduces it, which is what the previous wording asked for. New filings:
  SM278-SM284.

## 0.10.6 - EDGE: the release that told you to do something it had not made safe (2026-08-11)

An edge build on 0.10.5, and it exists because of a live upgrade. 0.10.5's
release notes instruct every operator to re-render their vhosts for the SM268
H17 `PT` fix. On Hestia, re-rendering resets the docroot permissions - and
nothing in 0.10.5 repairs that afterwards. The operator who followed the
instruction found `public_html` at `drwxr-s--x` and the manager unable to save.

- SM270 (4070fb5) a vhost rebuild no longer leaves the site unwritable. Three
  parts, because the defect had three causes and fixing one would have looked
  like fixing it. `lazysite-hestia-update-all.sh --rebuild` refreshes the
  template, rebuilds each vhost and THEN deploys, so the permission sweep is the
  last thing to touch the tree - previously the rebuild was a manual step
  performed after the deploy, which is the wrong end. `lazysite-check` reports a
  docroot the CGI cannot write as a FAIL and repairs it under `--fix`; a docroot
  that is writable but missing setgid is a WARN, because that works today and a
  hand-made development docroot is 0775, and failing on all of those teaches the
  reader to skip the line that matters. And the upgrade instructions now say
  what a re-render costs.
- SM271 (21e3028, 8777ea4) a transient dotfile at the repo root no longer
  refuses the build. `build-manifest.pl` rejects any file matching no
  classification rule, which is right for content and wrong for the repo root -
  which is where per-run tooling state conventionally goes. Three tools tripped
  it in one session (`prove --state=save`, a test lockfile, and yath's per-job
  file), each breaking every test that builds a manifest, and each presenting as
  something else: twice as parallel-safety failures, once as harness
  incompatibility. A root DOTFILE is now excluded; an unclassified ordinary file
  still refuses, which is the case the gate exists for. The refusal message
  leads with the offending file rather than the manifest it was writing.
- SM269 phase 0 + 1 (fdedc45, ac9889c, 83aa65e) the test cycle, measured and
  then made parallel-safe. The two perlcritic sweeps are sharded across forks
  (41.3s to 15.5s, 31.7s to 12.9s; same files, same profile, same severity, both
  verified still failing on a real violation) and the shared repo-root manifest
  has one owner instead of six copies of its lifecycle, so `prove -j4` is green:
  122s against 330s. Reported honestly: this improves the developer loop and
  does NOT move the release gate, because coverage is 92% of the gate's
  wall-clock and the compile tax lives in CGI subprocesses no harness can
  preload.

Backlog: every `partial` filing is now closed or split, so nothing in the queue
is half-done, and a second sweep found three more deferred halves hiding inside
SHIPPED filings - a worse hiding place, because the status says done and nobody
reads on. Six successors carry what the closures released (SM272-SM277). See
`docs/feature-requests/WORK-PLAN-2026-08.md` for the boundary and the order.

## 0.10.5 - EDGE: what the security review found, and what it cost to prove (2026-08-10)

An edge build dominated by SM268 - four adversarial reviews run against 0.10.4
as a pre-release gate, which reproduced 26 defects and blocked the release. All
of them are closed, plus two more found while proving the fixes. **Existing
vhosts must be re-rendered**: every SM223 Apache routing rule gained the `PT`
flag, without which the ACL routing never reached the auth wrapper at all on the
layout the Hestia templates produce. **And a re-render resets the docroot
permissions** - Hestia's `v-rebuild-web-domain` puts `public_html` back to its
own default (2751: setgid, no group write), which leaves the CGI unable to save
anything. Run `lazysite-check --fix` after any rebuild, or use
`lazysite-hestia-update-all.sh --rebuild`, which orders the refresh, the rebuild
and the deploy so the permission sweep runs last (SM270).

The theme, if there is one, is two surfaces disagreeing about the same question.
A capability the control API enforced and MCP did not; a ceiling applied when
DECLARING a capability but not when ACQUIRING one; a gate on serving a page with
nothing on listing it; a routing rule in ten templates but not in the generator
that writes the eleventh. Each fix states the rule once and pins it, rather than
fixing the instance.

- SM268 (40f4976, ac2a3ae, 4473bcf, ac4b365, 0c57737, 4ab6444, ba8a135, 3971940,
  95e6936, e9e829f, bee4623, 218befd, 3c4dd3d) the adversarial security review,
  closed in full. Three criticals: a site package could be made to carry the auth
  store and the session HMAC secret (`content_root: ./lazysite` normalised past a
  literal comparison); a tar member without `./` bypassed the restore exclusion
  and replaced the account store; an account named `local` became the operator
  from any starting privilege. Then the highs: `form-submissions&file=` returned
  any `.jsonl` under the docroot including the session store; folder ACL scope
  existed only in the processor's copy, so a "protected section" was fully
  writable over the manager, MCP and WebDAV; the installer followed symlinks on
  every write and every mode change; the SM195 ceiling guarded one verb while
  `group-add`, `group-nest`, `token` and `claim-create` reached the same
  escalation; stripping `ui` from every group flipped a live site to unsecured,
  where an anonymous caller was the operator. Gated page content leaked through
  `scan:` listings and the shipped `/search-index`, cached `public, max-age=3600`.
  Every fix carries a regression test that was confirmed failing on the unfixed
  tree.
- SM268 H17 (ba8a135) **every SM223 Apache rule lacked `PT`**, so mod_rewrite
  prefixed DocumentRoot and the target resolved to
  `<docroot>/cgi-bin/lazysite-auth.pl`. Where cgi-bin is a SIBLING of the docroot
  - which is what the Hestia templates produce - that file does not exist and
  EVERY static file 404s once an ACL store is present. Fail-closed, so not a
  disclosure, but SM223 was inert and the site's assets were broken. Found by
  driving real Apache 2.4.67 rather than by reading the rules: the text was right
  and the behaviour was not. `t/integration/40` now drives a real server.
- SM223 (04ae232, 20dd86b, cc5b445, 21e65fb) static files come under access control through the
  ACL, with folder scope as an entry in the same store. A file the web server
  hands over directly was reachable by anyone who knew its path, and no auth
  decision lazysite made could reach it.
- SM181 (dacf24e, cabc969) a folder ACL entry gates a whole SECTION - its pages
  and its assets together - and `draft: true` makes the refusal a 404 rather than
  a login bounce, removing the section from every listing. A login form at
  `/upcoming/pricing` confirms that `/upcoming/pricing` exists, and the URL is the
  thing being held back.
- SM183 (2d7bc62, ff702b7, 3c4dd3d) applying a site package snapshots on every
  surface, the snapshot restores, and the artefact carries an integrity digest
  that is now VERIFIED rather than displayed. Nothing had ever recomputed it: an
  operator read a digest beside a package as "verified" when it meant "a digest
  was written at some point". `package_apply` refuses a mismatch; the listing
  reports verified, mismatch or absent.
- SM195 (c3d8e1a, 3f3cfc6, ac4b365) a delegate cannot confer a capability it does
  not hold, on any of the five verbs that reach conferral. The ceiling is computed
  from what the actor HOLDS, through the group nesting closure, so an inherited
  capability counts.
- SM249 (688db58) theme variables resolve in a page body, not only in a layout.
- SM246 (bee4623) `check` verifies the whole declared directory model rather than
  eleven hand-written paths, so a site already carrying the 0.6.5 incident is
  reported instead of called healthy. Reported, not repaired: an operator who
  tightened a content directory deliberately should not have it widened by a tool
  they ran to ask a question.
- Filed as candidates rather than shipped: SM265 (50c7cfb) the browser-session
  surface, SM266 (ff702b7) apply-confidence UI, SM267 (cabc969) the
  protected-sections panel, and SM269 (f081b95) a commissioned research project
  on the test cycle. The three UI filings are manager JavaScript, which the suite
  cannot reach; SM269 is a whole-project piece of work deliberately not bundled
  into a release cycle.

Docs: `docs/architecture/permissions-and-secrets.md` is new and describes the
whole model - identities, capability resolution, the five planes and what
enforces what, ACL semantics, a secret inventory with the consequence of each
disclosure, and the first-run flow. It also records a documentation defect it
found: `security.md` said unsecured mode meant "any authenticated user has
manager access", while the implementation skipped authentication entirely and
assigned the operator sentinel. Both now say the same accurate thing, and the
behaviour itself is fixed.

## 0.10.4 - EDGE: success reported for work that did not happen (2026-08-09)

An edge build on 0.10.3, and mostly one theme: an operation answered ok, the
caller believed it, and the thing asked for had not happened. **BREAKING**:
`list_versions` returns `versions` rather than `entries`, with no deprecation
window. Existing vhosts need regenerating to pick up the registry routing.

- SM261 (96934c5) a list response names its contents: `list_versions` returns
  `versions`. A reporting agent read `entries` as zero versions and began writing
  it up as a defect - a wrong key and an empty result are indistinguishable, so
  the failure is a confident wrong conclusion rather than an error.
  `theme-activate` / `layout-activate` also accept `theme=` / `layout=`, the
  spelling everyone tries first, so SM247's trap is no longer reachable. Plus the
  three documentation gaps the same report named.
- SM252 (bc0b00c) the form timing token is minted per response, not per render.
  It was baked into the cached page, so every visitor shared one timestamp:
  measured live, three fetches two seconds apart returned the same token, already
  363 seconds stale, and a submission with no dwell was accepted. A page carrying
  a form is no longer publicly cacheable.
- SM248 (30d509d) the per-domain registries route to the engine in all four vhost
  templates. Every other routing rule is conditioned on the request mapping to no
  file, which is right for pages and wrong here - the primary's sitemap.xml
  exists, so it answered for every host. NEEDS AN OPERATOR ACTION on existing
  sites: templates apply at install time.
- SM253 (d0bf6a9) a 404 belongs to the domain that was asked - it resolved
  against the primary's docroot, so a mistyped URL on a secondary domain showed
  the primary's branding - and now carries the baseline security headers, which
  the one response most likely to meet a scanner was previously served without.
- SM251 (42786e4) deleting a page clears the registries for every content root.
  It cleared the docroot's only, so a domain's own sitemap kept the deleted URL
  until its TTL expired - which read as slow convergence and was a refresh aimed
  at the wrong file.
- SM260 (be619d9) audit_site no longer returns the server's filesystem path
  (including the hosting account name) to token and MCP clients. The same line
  meant the stale-HTML audit had NEVER run: it reported one finding, always the
  docroot it was supposed to start scanning from. A new sweep checks the whole
  read-only partner surface for paths.
- SM256 (1910088) add_alias creates the front matter it needs instead of silently
  doing nothing, and says whether it wrote, found it already there, or could not.
- SM257 (e9df3c8) preview_domain verifies the render instead of assuming it -
  exit status and stderr are read, and a dead processor, an empty render and a
  blank page are now three distinct answers rather than one `ok`.
- SM262 (f5d8017) an agent may delete the themes it created and nothing else, so
  it can clear its own experiments; the active-theme and in-use protections come
  first, unchanged.
- SM223 (69b0e49) audit_site reports static files a protected site serves to
  anyone. Detection only: enforcement would start refusing assets on live sites
  and that decision is not taken.
- SM259 (2e8af67) the Domains page describes a domain once - Add uses the
  Configure sheet. The create-only parts (clone-from, seed, live URL derivation)
  survived the move, and the add form's better field help came with it.
- SM249 (a4653a3) validate_page warns when a page body uses a layout-scope theme
  variable, which resolves to the empty string and cost an agent a handover.
  Exposing the variable needs a render-path restructure and is not done.
- SM246 (349cbd4) analysis: install_file creates directories with a bare
  make_path and no mode, so they take the umask default (0755 under root, no
  group write) and nothing corrects the ones outside runtime_paths. Explanation
  only - no code change, per report-before-repair.
- SM263 (0950d43) the docs-drift judgement calls: SM179 gains an as-built note
  rather than being edited, site_apply's adopt_identity reaches MCP and the CLI,
  and site-backup-download is recorded as deliberate. One row was WITHDRAWN as
  wrong: a build channel and a site update_channel answer different questions.
- SM254 (4412cdc) a lint fails when the docs name a path or script the tree does
  not contain.
- SM258 (6f0e629) a lint fails when a released CHANGELOG entry claims an SM the
  backlog still calls open - it found SM247 had shipped with no filing at all.
- Docs: SM236 decided - the icon link belongs in the layout catalogue, not the
  engine. Nothing changes in lazysite core; the work moves to the catalogue.
- Docs (de6c978) MANUAL-CHECKS.md: the nine areas the suite cannot reach and the
  manual pass for each, because "all tests passed" reads like "it works".
- Fix (65ea0b9) the docs-path lint no longer depends on where the repo sits. It
  excluded paths by matching the ABSOLUTE name, so running from a worktree under
  /srv/tmp excluded every file in the tree and reported release.sh, install.sh
  and coverage.sh as dead references in a checkout containing all three. Also
  fixed: a $1 clobbered by a later match, and runtime state under
  starter/lazysite/ that exists only in a working checkout, so the lint passed
  in place and failed anywhere clean.
- Docs (5f92518) SM251, SM252, SM253, SM256, SM257, SM260, SM261 and SM262
  marked shipped. Caught by t/lint/26 AT the release commit rather than by hand a
  release later, which is what that guard was built for.

## 0.10.3 - EDGE: MCP surface parity, and instructions that are no longer accepted quietly (2026-08-08)

An edge build on 0.10.2. The MCP surface gains the actions a token client already
had, and a lint now holds the two surfaces together. Three changes close cases
where lazysite accepted a wrong instruction and reported success. No BREAKING
change and no migration; installing a layout now appears in content history, as a
consequence of every write to the site config being recorded.

- SM238 (37e7c37) per-domain tools over MCP: `list_domains`, `domain_set` and
  `preview_domain`, plus a `host` parameter on `activate_theme` and
  `activate_layout` that scopes the instance-wide call to one domain. A partner
  previously needed an API token issued purely to reach `domain-set`.
- SM239 (0dd587f) MCP/control-API action parity, enforced: every API action is
  mapped to its MCP tool, with 24 API-only and 13 MCP-only entries each carrying
  a reason, and stale entries failing too. Running it found 13 API actions absent
  from the capability model's `unlocks`, so `describe_capabilities` had been
  under-reporting what every one of those capabilities grants.
- SM240 (1a51f26) `upload_file` writes binary content over MCP through the same
  locks, content history and ACL checks as every other write. Replacing a logo or
  favicon no longer requires falling back to WebDAV with a separate credential.
- SM247 (1b8834a) a missing parameter is no longer read as a destructive
  instruction: `theme-activate` with the name in the wrong parameter sanitised to
  the empty string, which meant DEACTIVATE, and returned ok:1 after stripping a
  live site's theme. An empty name is now an error naming the right parameter;
  deactivation requires `deactivate=1`.
- SM243 (5615e62) warnings arrive where the mistake is made, not only in the
  briefing: page bodies carrying a full HTML document, a `<style>` block or baked
  chrome; themes hiding layout chrome or setting content transparent by default;
  and an `@group` ACL, which matches manager users only - token, MCP and WebDAV
  partners carry no groups. All warn, none refuse. A rename also reports the
  alias its retired URL needs, and writes it on request with `add_alias`.
- SM244 (5615e62) `audit_site` reports the starter pages still present and how
  many are in the sitemap, reading a provenance marker nothing had ever read.
- SM255 (fc03cd5, e73c65b) one write path for `lazysite.conf`: SEVEN write sites
  across five modules wrote the same file by their own mechanisms and only one
  recorded the write, so a config change appeared in content history while a
  domain registration, a plugin toggle, a theme activation, a `layouts_repo`
  change and a `setup-manager` run did not. Two were unsafe as well as
  unrecorded: the theme and layout pointer setters wrote the live `layout:` and
  `theme:` keys with a non-atomic, unlocked write, which a lock-free reader can
  observe truncated. All seven now go through the one writer - locked, atomic,
  recorded - so installing a layout, activating a theme or layout, setting
  `layouts_repo`, toggling or configuring a plugin and `setup-manager` all gain
  content-history entries; a site-package apply records one entry rather than
  none. Commits raised from a plugin hook were authored `unknown` (the hook runs
  as a subprocess, where the acting user is in the environment, not the request)
  and are now attributed. `Manager::Domains` joins the git-guarantee scan and
  three actions move from exempt to hooked - `action_layouts_repo_set`'s
  exemption had read "conf write without a commit", a defect recorded in a
  registry as an accepted fact. New lint `t/lint/25-one-conf-writer.t` asserts
  the property instead of a commit message claiming it; it found two of the seven
  on its first run.
- (070d00a) an `appearance` page shipped with a literal NUL byte, making git treat
  it as binary - no reviewable diff, and no grep would match inside it. Removed,
  with a lint test barring control characters in shipped pages; the "in use"
  marker on that page is stated once rather than twice.
- Tests (c2870f8) behaviour coverage for the tools this release adds to the MCP
  surface. SM238, SM240, SM243 and SM244 each shipped with tests that read the
  source - a warning string is present, a tool is declared, a parameter exists -
  which execute none of the code, so `lazysite-mcp.pl` branch coverage fell to
  58.5% against its 60% floor and the release gate refused the build. The new
  test drives the tools through the real JSON-RPC entry point over a real
  docroot and asserts what changed on disk: 62.6% branch, 88.6% statement.
- Docs: SM224 analyses the two access-control models; SM231, SM245, SM246 and
  SM248-SM254 recorded in the backlog, plus SM256 and SM257 - two cases of an
  operation reporting success for work it did not do, found by the coverage work
  above and filed rather than fixed here (`add_alias` on a page with no front
  matter; `preview_domain` on a render that produced nothing).

## 0.10.2 - EDGE: what the platform knew and did not say (2026-08-08)

An edge build on 0.10.1. Every change closes a gap between what lazysite knows
about itself and what it tells the person or agent asking. No BREAKING change and
no migration; `form-list` gains `row_count` with `rows` kept one release as a
deprecated alias.

- SM241 (9a0adf2) domain-set publishes theme assets: binding a layout/theme to a
  domain wrote the binding and mirrored nothing, so a secondary domain served a
  404 stylesheet - the layout applied and rendered its chrome correctly, so an
  unstyled page read as "no layout". Now mirrors under the domain's OWN layout
  (the failing case) and leaves the primary site's presentation untouched.
- SM242 (3df26b3) layouts briefing covers multi-domain instances: "re-activate to
  rebuild the mirror" is right for one site and switches the primary site's theme
  otherwise. Scopes that advice, names the correct action, makes the WebDAV
  fallback actionable, and records the ten-year asset cache.
- SM235 (8e10865) an unwritable WebDAV target answers 507 with the condition
  named, not a bare 500 indistinguishable from a scope refusal.
- SM237 (c447b79) an unrecognised control-API action is no longer reported as a
  capability refusal; %KNOWN_ACTION is pinned to the dispatch chain.
- SM225 (c8852c2) documentation index in describe_capabilities, derived from what
  the site publishes, plus a /docs/ index page.
- SM226 (53556f0) the capability map states its own scope: a false means "not
  granted to this account", and a granted channel whose service is off says so.
- SM227 (fb328a1) the submission store no longer reads as write-only. `rows`
  meant a count here and an array in its sibling; `row_count` is now canonical.
- SM228 (fc55d63) the raw-page downgrade names the static-file alternative, and
  existing affected pages are reported by validate_page and audit_site.
- SM229 (1a5bc2d) submission notification documented - it exists, and nothing
  said so, so integrators designed polling.
- SM230 (86711bb) stated position on browser-origin calls, with the preflight
  refused explicitly instead of failing opaquely.
- SM233 (5859d61) the scope-independence control is now "Content access" and
  shows which accounts currently cap this one.
- SM234 (931330c) a theme or layout used by a sub-domain is marked in use and
  names the domains, instead of offering a Delete the server refuses. Layouts had
  the same gap and are fixed with it.
- SM239 (075c799) first cut: a baseline guard on the MCP/control-API surface
  shape, with each one-sided capability carrying a recorded reason.
- SM220 (ee18e06) a lapsed renew-on-use token no longer shows as "in use".
- Backlog integrity (2b8fc19): 25 items were marked open while their own notes
  recorded them as shipped; open items drop from 40 to 24, and t/lint/09 now
  fails a status that contradicts its note. SM209 merged into SM222.
- Backlog captured, no code: SM236-SM245 (an MCP binary write, per-domain MCP
  tools, surface parity, write-time guardrails, audit_site reporting what the
  site already knows, and briefs moving out of band into a plugin).

## 0.10.1 - EDGE: form spam controls, submissions tooling, and fixes (2026-07-27)

An edge build on 0.10.0 stable - operator-facing form/submissions features, an
agent-facing read action, a recent-change marker, and one fix. No BREAKING change,
no migration (the form-event log and quarantine flags are created on demand). Edge
sites take it next update; beta/stable stay put until it promotes.

- **SM216 - form spam controls (quarantine, not sharper reject).** The form
  handler scores each submission server-side at accept time (URLs over a per-form
  threshold, default 2; an optional per-form keyword list) and QUARANTINES a
  suspect one: it is stored but flagged, held out of the notification bell, and
  shown under a Quarantine filter in the Submissions viewer with one-click Confirm
  (un-quarantine) / Delete. A false positive still arrives, just unannounced - so
  the heuristics are safe on by default. Holds the published stance in full (no
  third-party anti-spam/CAPTCHA, no fingerprinting, no JS requirement, no
  accessibility regression). Part 2: every outcome (delivered / quarantined /
  blocked by honeypot / token / too-fast / expired / rate) is counted into the
  durable per-day stats store (SM213) so the report shows blocked-vs-stored -
  counts only, no submission content, no IPs. Parts 3-5 remain roadmap.
- **SM187 - submissions viewer bulk cleanup + export.** Row checkboxes + select-all
  + Delete-selected (one atomic server rewrite, operator-only, audited), and a
  client-side Download CSV of the loaded rows.
- **SM214 - form discovery for agents.** A `form-list` control-API action and a
  `form_list` MCP tool return a site's forms (names, handler types, has-store, row
  counts) under `read_submissions` - least-privilege, PII-free.
- **SM103 - recent-change marker on the Groups page.** The dot (already on Files /
  Users) now marks a group whose settings or capabilities changed in the window.
- **Fix (SM212 follow-up):** extending an access-token lifetime routes through the
  correct control-API action, so it applies instead of an "Unknown action" audit
  fail.
- Housekeeping: SM185 and SM186 marked shipped (follow-ups already delivered);
  SM217 (first-class domain aliases) captured as a candidate. No code change.

## 0.10.0 - STABLE: promotes the 0.9.11-0.9.17 beta line to stable (2026-07-27)

Pure channel/version promotion of the bedded-in beta line - the same code as 0.9.17,
certified for the stable channel, superseding 0.9.10. No new functional change, no
BREAKING change, no migration. A stable build is accepted by every channel, so it
rolls out fleet-wide.

Carries everything accrued since 0.9.10 stable:
- 0.9.11-0.9.13: login-loop fixes, raw-mode write guard, engine-served system pages
  with a self-healing fallback (SM201 - clears the "system page missing" warnings on
  0.9.10 sites), site-integrity + connector reliability, and the 0.9.x F1 security
  hardening.
- 0.9.14-0.9.15: theme-authoring API + Figma ingestion, sub-user promotion,
  content-history stats, Domains configure-modal + manager-UI polish.
- 0.9.16-0.9.17: operator-set token lifetime with sliding renewal, code-served
  AI-partner discovery, tools/list hygiene; the durable per-day stats store with
  month-on-month trends + scanner class + 404 split + codified privacy commitment;
  and sudo-safe permissions with the lazysite-check --fix / lazysite-fix-perms repair
  tool (run once on any drifted 0.9.10 site).

## 0.9.17 - BETA: durable stats store + trends, sudo-safe permissions + repair (2026-07-27)

Two features on top of 0.9.16. No BREAKING change, no migration (the stats store
rebuilds from existing data on first run).

- SM213: durable per-day visitor-stats store under lazysite/stats/ (aggregates only,
  outside the clearable cache) with monthly rollups + an index; self-describing
  horizon fields (data_from, sample:{from,to,count}) retire the misleading
  events_capped flag; analyse_visitors gains index/day/month selectors + a
  month-on-month series (control API + MCP), surfaced on the Stats page; visitor-level
  scanner classification (a probe marks the whole session scanner, excluding a spoofed
  referrer) + a 404 plausible/junk split; privacy commitment codified in FEATURES
  ("lazysite installs no trackers"; day files hold aggregates only; daily-salted keys).
  No cap, no operator knob.
- SM215: sudo-safe permissions. secure_write_perms makes a just-written file inherit
  its dir's owner+group and, as root, set the owner too (never leaves a root-owned
  file the CGI cannot access) - applied across the credential/settings/groups writers
  and install.pl's config-replace (updater) path. lazysite-check --fix is the
  canonical repairer (now also covering lazysite/stats/); lazysite-fix-perms is a
  dry-run-by-default front-end to it (--apply to repair).
- Backlog docs (not shipped): SM214 (form-list read action), SM216 (form spam
  controls).

## 0.9.16 - BETA: token-lifetime control + live-config AI discovery + discovery hygiene (2026-07-26)

A small, focused release on top of 0.9.15. No BREAKING change, no migration; secure
defaults unchanged.

- SM212: operator-set access-token lifetime with renew-on-use. A per-account
  `token_ttl` (hard 30-day ceiling, 1h floor) governs the lzs_ machine token; an
  account that carries one also gets sliding renewal (an in-use token never lapses,
  only a full idle window expires it). Default is unchanged - no token_ttl means the
  hard 24h-from-issue window and no sliding. Set from the Sessions & keys page
  (per-key Lifetime: 24h/7d/30d) or `set <user> token_ttl 30d`. Shared TTL policy +
  resolver in Lazysite::Auth::Settings; sliding folded into the throttled
  touch_credential.
- SM190 (final part): `.well-known/ai-partner` is code-served from the live config -
  it advertises only the endpoints whose service killswitch is on and is served
  no-store, so it cannot drift or name a disabled endpoint. Shadows the legacy static
  page (now a registration stub).
- SM210: `tools/list` returns only the introspection subset to an unidentified caller
  (anonymous or an unrecognised/revoked token), not the full tool vocabulary.
  Enforcement unchanged; discovery hygiene.
- SM207 closed out as superseded by SM208.

## 0.9.15 - BETA: manager UI polish (domains configure-modal, promote-in-dropdown, hints) + docs (2026-07-25)

A low-risk manager-UI and documentation release on top of the 0.9.14 edge line. No
engine change, no BREAKING change and no migration; UI, copy and documentation only.

- Domains page: one Configure modal per domain (the account-configuration sheet),
  replacing the per-row Actions dropdown + inline edit panel; controls grouped as
  Identity / Presentation / Access / Language with a Tools footer (Preview, Check,
  Export) and a separated Delete. The Add-domain content-folder placeholder drops the
  stale `sites/` prefix.
- Users page: promote-to-top-level is now a choice in the Parent "move under"
  dropdown (operator-only, when not already top-level), not a standalone button; the
  scope_independent toggle is unchanged. The WebDAV password hint reads correctly for
  an AI (no-password) account, pointing at the access token under "Connect an AI
  assistant".
- Docs: docs/FEATURES.md brought current to 0.9.14 (theme-authoring + Figma, the
  whole 0.8/0.9 line, version timeline) - the source the public feature page is
  summarised from. Backlog SM210 (tools/list unauth discovery subset) logged; SM211
  (WebDAV lazysite/ write-guard) investigated and parked - the guard is correct.

## 0.9.14 - EDGE: theme-authoring API + Figma design ingestion, operator features (2026-07-24)

A large feature release on top of 0.9.13. No BREAKING change, no migration; beta
and stable sites are unaffected until it promotes.

- Theme authoring + Figma ingestion: theme_tokens (SM204) MCP read tool for token
  vocabulary discovery; create_theme (SM205) MCP write tool - a validated one-call
  theme scaffold + eager theme.json validation on the write_file path; SM203
  optional layout.json tokens block + a non-fatal activation warning; SM206 layout
  catalogue description/tags; SM202 read_file / history / WebDAV read layout.tt as
  text; SM208 a /docs/integrations namespace + a Figma dual-MCP helper (registered
  for llms.txt/sitemap, cross-linked, with a build-from-figma recipe).
- Operator features: SM194 promote a sub-user to top level (operator-only clear of
  managed_by) + a separate explicit scope_independent lift of the created_by
  ceiling, with Users-page controls; SM199 content-history file list + revision
  statistics (a git-history-summary action + a list_content_history MCP tool + a
  Files-page History overview), rename-aware and leak-safe.
- Manager + connector fixes: the discovery check accepts the dynamic
  ${REQUEST_SCHEME}://${SERVER_NAME} site_url (ends the fleet-wide false not-https
  warning); a passwordless / token-only account can be removed; an authenticated
  no-ui account at /manager/ gets a clear terminal message instead of a login loop,
  and the Users page warns before a group change removes an account's last
  manager-access group.

## 0.9.13 - BETA: site integrity, capability clarity + connector reliability (2026-07-23)

A broad reliability + clarity beta on top of 0.9.12. No BREAKING change, no
migration; stable-channel sites are unaffected until promotion.

- SM201: engine-served system pages - login/claim/402/403/404 moved to the
  protected lazysite/templates/system/ tree and served with a three-tier fallback
  (content root -> docroot root -> protected default). A deleted or never-seeded
  copy self-heals (no /claim 404); content-rooted subdomains resolve; a content
  copy still overrides. lazysite-check verifies each route resolves.
- SM193: site-package migration completeness - a token-client site-backup-download
  (manage_domains, namespace + scope confined) completes the create/download/
  upload/apply loop; apply KEEPS the target's site_url/site_name by default
  (adopt_identity opts into the source's); apply mirrors the layout's theme assets
  so an applied site is styled immediately.
- SM200: connector reliability - distinct 401 data.reason (sign-in-incomplete /
  credential-invalid / token-expired / token-invalid); connect code valid 30 min
  (was 15) with its expiry surfaced; fresh-chat onboarding guidance; and a
  lazysite-check probe that flags a remote service enabled with a bad/absent
  site_url (the broken-discovery-endpoint class). SM190 shares the probe.
- SM196: connector connected-detection flips at authorise time; agent-neutral
  onboarding copy; an authenticated tools/list filtered to invocable tools.
- SM197 permissions grid ticks only where a capability has a channel surface;
  SM198 flags a capabilities-but-no-members group as inert; SM191 shows
  grant-to-enable hints on capability-gated areas.
- Content-history status is a real health probe (enabled/healthy vs inconsistent
  vs degraded/paused). SM192 stats classifier drops SPA/secret-probe noise +
  referrer spam.
- build: exclude inbox/ from the release manifest.

## 0.9.12 - BETA: field-issue fixes; supersedes the withdrawn 0.9.11 (2026-07-23)

Renumbered supersession of the withdrawn 0.9.11 beta - identical code, retired
unused because the version number was consumed in handling (0.9.11 is burned and
will not be reused). Reliability and correctness fixes on the 0.9.x line from field
reports, on top of 0.9.10 STABLE. No BREAKING change, no migration; stable-channel
sites are unaffected until promotion.

- FIX (login loop): the JS session marker (`lzs_session`) could outlive the real
  signed session (e.g. after an auth-secret rotation), so `/login` reported
  "already signed in" and hid the form while every page re-bounced. Both bounce
  points now clear the marker (`Set-Cookie ... Max-Age=0`). (SM188, ddf6f45)
- HARDENING (content integrity): the write path refuses raw-mode content pages
  (front matter forcing an HTML/XHTML/SVG `content_type` via `api:`/`raw:`) on the
  manager save and WebDAV PUT (415) - keeping content pages themed and on the
  no-CDN policy; defence in depth (the sniffing vector was already contained).
  Extends ADR 0006 to the write path. (SM189, 7f6409c)
- FIX (discovery): `.well-known/oauth-*` return 404 when `oauth_enabled` is off
  (not advertised, not render-cached) and serve normally when on. (SM190 partial,
  0a300ff)

## 0.9.11 - BETA [WITHDRAWN - superseded by 0.9.12, never deployed] (2026-07-22)

Reliability and correctness fixes on the 0.9.x line from field reports, on top of
0.9.10 STABLE. No BREAKING change, no migration; stable-channel sites are
unaffected until promotion.

- FIX (login loop): the JS session marker (`lzs_session`) could outlive the real
  signed session (e.g. after an auth-secret rotation), so `/login` reported
  "already signed in" and hid the form while every page re-bounced. Both bounce
  points now clear the marker (`Set-Cookie ... Max-Age=0`). (SM188, ddf6f45)
- HARDENING (content integrity): the write path refuses raw-mode content pages
  (front matter forcing an HTML/XHTML/SVG `content_type` via `api:`/`raw:`) on the
  manager save and WebDAV PUT (415) - keeping content pages themed and on the
  no-CDN policy; defence in depth (the sniffing vector was already contained).
  Extends ADR 0006 to the write path. (SM189, 7f6409c)
- FIX (discovery): `.well-known/oauth-*` return 404 when `oauth_enabled` is off
  (not advertised, not render-cached) and serve normally when on. (SM190 partial,
  0a300ff)

## 0.9.10 - STABLE: promotes the hardened 0.9.x line to stable (2026-07-21)

A channel promotion of the bedded-in 0.9.9 beta - the SAME code, certified for
the stable customer-rollout channel. Supersedes 0.9.4 as STABLE. No new
functional change at the stable step; no BREAKING change and no migration from
the 0.9.x betas.

Carries forward 0.9.5-0.9.9, most importantly 0.9.9's data-loss hardening (atomic
config + auth-store writes, every auth-store mutation serialised on a store lock)
and security hardening (manager file-path confinement, download read-ACL/scope,
principals capability-gating, dormant-capability resolution - see the private
advisory). Operators on 0.9.4-0.9.8 should upgrade. From 0.9.4 STABLE the 0.9.0
posture is unchanged (remote surfaces off by default; enable in Settings ->
Services).

## 0.9.9 - BETA: data-loss + security hardening, disabled-service messaging, dormant-capability hints (2026-07-21)

Reliability and security hardening on the 0.9.x beta line, plus a manager-UI
improvement. No BREAKING changes, no migration. Operators should upgrade.

- FIX (data loss): concurrent config saves could truncate `lazysite.conf` to a
  single line (a non-atomic truncate-before-lock writer racing the Services
  page's parallel saves). `write_file_checked` is now atomic (temp + rename,
  never unlinking the real file) and `_write_conf_key` holds a lock across its
  read-modify-write.
- FIX (data loss): the same class in the AUTH STORE - `write_users`,
  `write_groups`, `update_user_hash`, the MCP form-bind, and the bad-URL caches
  now write atomically, and every auth-store mutation serialises on a store lock
  held across the whole read-modify-write, so a reader never sees a truncated
  credential store and two concurrent edits cannot lose an update. Reads stay
  lock-free.
- SECURITY: manager file-path confinement - the file-editor path blocklist is
  now matched against the canonical resolved path, closing a traversal by which
  a content-authoring account could reach engine-owned files under `lazysite/`.
  Reported privately (advisory to follow); operators should upgrade.
- SECURITY: `file-download` / `file-zip-download` now enforce the same per-file
  read ACL and `dav_scope` confinement as `read` (previously neither), so a
  delegated editor cannot pull a file restricted away from them.
- SECURITY: the account/group roster (`principals`) is now capability-gated
  (`manage_content` or `manage_domains`) - a user with no grant-related
  capability can no longer enumerate every account and group.
- FIX: `manage_domains` / `feedback` / `read_submissions` grants were resolved
  but not surfaced to the cookie-manager capability gate, so a non-operator
  grant of any silently did nothing (`read_submissions` shipped inert in 0.9.8).
  All three now take effect; a parity test pins the capability set.
- FIX: a switched-off service (token exchange) answered HTTP 404 - read as
  "endpoint not deployed", misdirecting diagnosis. It now answers 200 with
  `{ok:0, code:"service_disabled"}`, matching the control API.
- SM180: dormant-capability indicators. The Groups and Users capability grids
  flag a channel capability granted while its site service is switched off, so a
  dormant grant is visible rather than silently doing nothing. Indicate, don't
  block - no migration.

## 0.9.8 - BETA: caps-within-session fix + submissions viewer v2 + grid polish (2026-07-20)

Fixes and manager-UI improvements on the 0.9.x beta line. No BREAKING changes,
no migration.

- FIX (SM186): a granted capability did not appear until re-login. A page with
  `auth: manager` was not flagged protected, so its server-rendered shell - which
  embeds the capability-gated nav - was cached and served stale (also a latent
  cross-user capability-leak via the shared cache). Any non-public auth level is
  now protected: manager pages never cache, so a grant reflects within the
  session, no re-login. Plus a "Domains" grant-to-enable nav hint for users who
  can grant capabilities.
- SM187 - submissions viewer v2: the form-submissions table opens in a scrollable
  modal; a handled row can be deleted (manage_forms, UI, audited, atomic rewrite
  by a stable per-row id); and a new least-privilege `read_submissions` capability
  plus a `read_form_submissions` MCP tool let an agent read submissions over
  API/MCP without the broader manage_forms. form-submissions is gated
  manage_forms OR read_submissions on both channels.
- FIX: the Groups capability toggles are laid out in an aligned CSS grid instead
  of a ragged flex-wrap.

## 0.9.7 - BETA: submissions-button fix + domains/site-package UX pass (2026-07-20)

A bug fix plus a UX polish pass on the 0.9.5/0.9.6 beta line. No BREAKING
changes, no migration.

- FIX (regression from 0.9.5): the plugin-config "View submissions" button did
  nothing and logged a SyntaxError. Its onclick was built as a double-quoted
  attribute with a raw JSON.stringify inside, so the double quotes terminated the
  attribute early and the handler became a broken fragment. Rebuilt on the file's
  safe single-quoted-attribute pattern.
- SM185 - domains + site-package UX pass:
  - Language (lang/lang_group, SM179) now travels in a site package and is written
    to the target on apply.
  - The DEFAULT/primary site is exportable without the domains feature: a new
    Backups > Site packages "Export this site" (manage_content) packages the
    docroot-root content, excluding lazysite/ infra + secrets and every other
    domain's content.
  - The Domains page lists only ADDITIONAL domains (the default site lives in Site
    settings); per-row actions are folded into an Actions dropdown; intro copy
    reframed.
  - Site settings: the service killswitch toggles sit under a single "Services"
    heading instead of one per toggle.
- SM184 (publish pages by email) recorded as a candidate proposal (doc only).

Note: the Domains area is gated on the manage_domains capability (split out of
manage_config by SM160); if it is missing from the menu, grant manage_domains to
the group on the Groups page.

## 0.9.6 - BETA: site-package migration in the manager UI (SM183) (2026-07-20)

A UI-only feature increment on the 0.9.5 beta line. It exposes SM158's portable
per-domain site packages in the manager UI, so a human holding manage_domains can
perform the agency demo -> client hand-off without MCP or the CLI. No BREAKING
changes, no migration.

- SM183 (v1) - site-package migration in the UI. Domains gains an "Export site"
  button per domain; Backups gains a "Site packages" panel (list / download /
  upload / apply / delete) with an apply preview + a confirmation naming the
  target and the presentation keys it rewrites. Two new actions -
  site-backup-inspect (read the manifest without applying) and
  site-backup-delete - both manage_domains + scope and confined to the
  lazysite-site- namespace (a full/content backup or a traversal path is
  unreachable). The package file is the interface: a package created by MCP is
  applied by a human and vice versa. Also fixes a mis-bucketing that dropped
  site packages into the content-backups list with a wrong Restore button.

Deferred to a later release (SM183 is partial): dry-run content diff, one-click
rollback + MCP site_apply snapshot parity, a target-readiness (domain Check) step
in apply, an integrity sha, and the presentation-key remap override.

## 0.9.5 - BETA: in-manager form-submissions viewer (SM182) (2026-07-19)

A small, low-risk feature increment on the 0.9.4 stable security line. One
functional change plus two recorded proposals; no BREAKING changes, no migration.
Cut to beta to bed in ahead of a stable promotion.

- SM182 - in-manager form-submissions viewer. Submissions live at
  lazysite/forms/submissions/<form>.jsonl, in the reserved lazysite/ tree the
  file editor refuses to open, so the data was unreachable from the UI. The
  plugin-config "View submissions" button now renders an inline, escaped table.
  A new read action form-submissions (manage_forms) parses the store server-side
  (docroot-confined, .jsonl only, no traversal), unions keys into columns, caps
  at the most-recent 500 rows, and returns values verbatim; the client escapes
  every cell, so a hostile submission renders as inert text. Gated at parity on
  both channels and covered by the audit-skip, write-path, capability-gate and
  cookie-read drift guards, plus a backend parse/confinement test.

Recorded proposals (feature-request docs only, not yet built):

- SM180 - dormant-capability indicators: warn (never block) when a granted
  channel capability cannot work because its site service is off.
- SM181 - folder / URL-prefix protection: put a whole folder/URL-prefix behind
  auth or hold it as a draft, beyond today's per-page control.

## 0.9.4 - STABLE: security-hardening line, certified (2026-07-19)

Promotes the 0.9.x security-hardening line to stable. This is a channel promotion
of the bedded-in 0.9.3 beta - the SAME code, validated on edge (0.9.0/0.9.1) and
beta (0.9.2/0.9.3) with a full partner-surface sweep by a live site agent; no new
functional change enters at the stable step. Full gate: suite + bench + coverage
(every production CGI above floors).

The 0.9.x line delivers: cross-plane capability consistency; default-off service
killswitches (MCP / OAuth / control-API / token exchange) with an operator
Services panel; the SM042 Config-page save migration off the legacy pseudo-plugin
onto config-set (with a parity guard); the SM127 token-path fix; the domain-check
SSRF guard; tenant-token isolation; the capability-grid grantability fix (feedback
/ notifications) with a parity guard; the form-targets data-loss fix; the nav-read
path-leak fix; WebDAV PUT RFC-4918 409 compliance; and expired-token rotation
guidance. See the 0.9.0-0.9.3 stanzas below for detail.

BREAKING (unchanged from 0.9.x; operator-recoverable, documented): remote surfaces
are OFF by default - enable in Settings -> Services; WebDAV nav/form editing needs
manage_nav / manage_forms; MCP feedback needs the `feedback` capability. An
existing site restores each from the manager UI; nothing is auto-migrated by
design.

## 0.9.3 - BETA: WebDAV RFC-compliance + token-rotation guidance (2026-07-19)

Two partner-site-agent findings resolved on the 0.9.x beta line, ahead of the
stable promotion:

- **WebDAV PUT to a missing parent restores the RFC 4918 409** (MKCOL first).
  0.9.x's SM166 auto-created the parent chain and returned 201 - convenient, but
  it silently broke both the standard and the publishing brief (which teaches
  MKCOL-parents-first). The server now matches the brief again; strict WebDAV
  clients interoperate and a typo'd parent is a 409, not a silent create.
- **Expired-token rotation gives actionable guidance.** Rotating an expired token
  returned a bare "Invalid token"; it now returns reason=expired plus a message
  telling the agent to re-exchange a pairing key. A wrong token stays a generic
  invalid (the expired signal is only given once the secret has verified, so it
  leaks nothing).

## 0.9.2 - BETA: manager-UI grantability + data-loss + info-leak fixes (2026-07-19)

The beta candidate for the 0.9.x security-hardening line, promoting the work
validated on edge (0.9.0/0.9.1). 0.9.1 (edge) fixed the Config-page save bug
(SM042: the service-killswitch toggles now persist). 0.9.2 adds three fixes a
validation sweep + a partner site agent surfaced, before the stable promotion:

- **Capabilities were enforced but ungrantable in the UI** (same drift class as
  the config-save bug): `feedback` (gates MCP submit_feedback) and
  `notifications` were missing from the Groups capability grid, so no operator
  could grant them from the manager UI. Both grids (Groups + Users) now list the
  full capability set, and a parity test (t/lint/19) fails the build if either
  ever drifts from @CAP_KEYS (it immediately caught a stale `manage_domains`).
- **Form "Edit targets" silently erased legacy inline targets** (data loss): the
  panel only represents handler targets and dropped hand/WebDAV-authored inline
  targets on save. The save now preserves them (backend-enforced).
- **nav-read leaked the server-absolute path** (filesystem layout + system
  username) to api/MCP token clients; it now returns the docroot-relative path.

Deferred to a 0.9.2 iteration / stable-window decision (from the site-agent
sweep): the WebDAV PUT auto-mkcol vs RFC-4918 409 behaviour (deliberate call +
doc), and a JSON guidance body on expired-token rotation (currently a bare 401).

## 0.9.0 - EDGE: cross-plane permission consistency + service killswitches (2026-07-19)

A security-hardening release building on 0.8.0. It fixes a reported token-path
regression, aligns capability enforcement across all access planes, and puts
every remote surface behind an operator killswitch (default off). Cut to the
EDGE channel first: it carries BREAKING changes (below) and a manager-UI
migration that must bed in on edge/beta before promotion to stable.

Config page save migrated to the control API (SM042)
: the site-settings page previously persisted through a legacy "processor as a
  pseudo-plugin" path (plugin-save), which silently dropped any key not in that
  plugin's schema - the reason the new service-killswitch toggles rendered but
  never saved. The whole page now loads via config-read and saves each key via
  config-set (validated + audited per key), the pseudo-plugin schema is retired,
  and a parity guarantee test fails the build if the page's keys ever drift from
  the API's read/write sets again.

BREAKING - opt-in required after upgrade
: Every network surface beyond the public page render is now OFF by default and
  must be enabled in Site settings -> Services (or in lazysite.conf). Set
  `mcp_enabled`, `oauth_enabled`, `control_api_enabled`, `token_exchange_enabled`
  to `enabled` for the surfaces you use (WebDAV was already opt-in). And WebDAV
  nav/form-config editing now needs the fine-grained `manage_nav` / `manage_forms`
  capability (matching the API/MCP planes), not `manage_config`; grant those to
  any account that edited nav/forms over WebDAV. Agent feedback over MCP is now a
  `feedback` capability (off by default). The manager UI, page render, and
  existing content/theme/layout grants are unaffected.

Service killswitches
: a surface-exposure audit found only WebDAV had the intended dual control (a
  conf killswitch, default off, plus a capability). The MCP server, OAuth server,
  control-API token path, and auth token-exchange were always-on and invisible,
  gated by a capability only. Each now has a conf killswitch (default off), read
  through one shared helper so the gates cannot drift, and surfaced as a toggle in
  the Services section of the config page (the manager landing page). A disabled
  surface refuses before doing any work and discloses nothing (MCP/OAuth refuse
  pre-auth incl. discovery; the control API refuses before verifying a token).
  Verified on every build by t/integration/28-service-killswitches.t.

Cross-plane capability consistency
: an audit of the cookie / control-API / MCP / WebDAV planes found the same
  resource gated by different capabilities per plane. WebDAV now uses `manage_nav`
  for nav.conf and `manage_forms` for form configs (was `manage_config`), matching
  the other planes and Capabilities.pm. `site-backup-create/upload/apply` were
  capability-gated but not POST-forced (a CSRF-free-GET gap) - now in %MUTATING.
  A drift-guard test pins the WebDAV @DANGEROUS_EXT copy to its canonical source,
  and the users tool now self-defends its group/capability-mutating verbs against
  a non-operator actor. The capability-gate guarantee test additionally fails the
  build if a capability-gated cookie mutator is ever left off the CSRF force-list.

A security and correctness patch on 0.8.0. Stable customers should upgrade.

Token-path regression fixed (reported on 0.8.0)
: the SM127 "manager accounts are interactive-only" gate wrongly refused two
  things on the control-API and MCP token paths. (1) Introspection - whoami and
  describe-capabilities were refused for any manager-linked account, because the
  gate ran ahead of the introspection exemption (contradicting the SM126/SM072
  contract that introspection stays open). (2) Agent accounts - it keyed on the
  group-granted `ui` capability alone, so an account with that capability but its
  interactive login DISABLED (`ui:false`) - a deliberate agent account - was
  refused despite holding api/mcp + the relevant action capability. The gate now
  blocks only accounts that can ACTUALLY use the interactive UI (`manager_ui` AND
  login enabled) and never blocks introspection, restoring the documented
  capability-based token contract. A normal interactive manager is still refused
  on the remote channels.

SSRF guard on domain-check
: `domain-check` (manage_domains) opens outbound TLS + HTTPS probes to a
  caller-influenced host; it now refuses them unless every RESOLVED address is
  public - blocking loopback, RFC1918, the cloud metadata endpoint
  (169.254.169.254), CGNAT, and IPv6 ULA/link-local, and closing the
  DNS-rebinding and IP-literal/localhost paths. `domain-preview` was unaffected
  (it renders server-side, no outbound request).

Tenant-token isolation
: pinned by test - a control-API token is a per-site credential and cannot
  authenticate against another site's docroot.

## 0.8.0 - STABLE: multilingual + domain access + cache correctness, certified (2026-07-18)

The second stable release, cut from the 0.7.28 beta on completion of the
2026-07-18 eight-dimension non-functional review (`docs/review/2026-07-18-eight-dimension/`).
It promotes the whole 0.7.x line to the stable channel: first-class multi-site
(many domains, one instance, per-host content roots and confinement), a
domain-owned access-control model with per-user locks (SM165), content history
that follows renames and never leaks across delete/recreate (SM175), the
complete multilingual language-set feature (SM179 P1-P8: switcher, hreflang,
per-language roots, layout strings, engine-chrome i18n, coverage, agent
discoverability), and conf-aware cache correctness.

Certification and the security fix it surfaced
: All eight dimensions clear a Commercial signoff (every 2026-07-10 refusal -
  reliability SLOs, the pentest gate, documentation currency, the DoC and SBOM
  licence - verified still cleared). The review caught and this release fixes a
  **serious stored-XSS / response-header-injection** path: a page's front-matter
  `lang:` reached `<html lang>` and the `Content-Language` header unescaped, so a
  content-only partner could execute script in every visitor's browser - now
  sanitised to a bare language tag (regression: t/integration/26-lang-injection.t).
  A `domain-add` CRLF gap was closed the same way. Two further hardening fixes
  landed in the same cut: the manager-API now applies the same in-app trust gate
  as the processor, so client-supplied `X-Remote-*` identity headers are ignored
  unless the auth wrapper vouched for them (a backstop for an edge that fails to
  strip them; guarantee test t/lint/13-trust-gate-guarantee.t, adversarial test
  t/unit/manager/39-forged-identity.t); and a raw/api page may no longer declare a
  script-capable `content_type` (`text/html`, XHTML, SVG) - such a type is
  downgraded to `text/plain` at serve time, closing a stored-XSS path a
  content-only delegate could otherwise reach (regression:
  t/integration/27-raw-content-type.t). Operators on 0.7.27/0.7.28 should upgrade
  for these fixes.

Adversarial security-testing breadth pass
: Before certifying the stable line, the manager / MCP / control-API / WebDAV
  attack surface was swept for the gaps that per-action coverage leaves. Two more
  hardening fixes landed: backup restore now excludes the `lazysite/` control tree
  on extraction (a crafted content tarball can no longer overwrite the auth/config
  namespace to escalate - defence-in-depth on top of the create-time exclude and
  the full-backup refusal); and `session-revoke` / `user-revoke` / `key-revoke`
  are forced to POST so the method-keyed CSRF gate covers them by construction.
  New structural guarantee tests fail the build if a dispatched action ships
  ungated, if the cookie and token capability maps diverge, if a file-write
  channel bypasses the path guard, or if any channel drops dav_scope confinement;
  new negative tests pin sub-user privilege-escalation confinement, a
  path-traversal sweep across every path-taking action, and login-rate-limit
  fail-open (a broken limiter must not lock everyone out).

Everything in 0.7.28 (below) is included. The Declaration of Conformity is
finalised for 0.8.0 and signed at the cut.

## 0.7.28 - BETA: multilingual completion + cache correctness + domains/manager UX (2026-07-18)

Engine-emitted chrome is localised (SM179 P8)
: The bare 404, the no-403.md fallback and the auth reject pages now render in the
  host's language via a new i18n layer (a built-in English table overlaid by an
  optional `lazysite/i18n/<lang>.json`), fail-closed to English on any miss. The
  404 fallback also HTML-escapes the request URI (a reflected-markup fix). With
  P1-P8 in, a language set is complete: language keys, switcher, hreflang,
  content-root data, layout strings, coverage, agent discoverability, and chrome.

Multilingual configuration is first-class, not conf-only
: `lang` / `lang_group` are settable through `domain-set`, the CLI, and the
  Domains **Add** + **Configure** forms (validated, failing closed) - previously
  they were honoured by the render but could only be hand-edited into the conf.
  `whoami` and `lang-status` now detect a set even when `lang_group` is declared
  only on alias hosts (not the base), and `lang-status` is gated on
  `manage_content` (the capability a translation agent holds), not
  `manage_domains`. New docs cover language config and the operator + DNS steps
  to add a language.

Cache correctness under a conf change (and any process model)
: A cached page render also bakes in the conf (site name, theme, nav, per-host
  language/alias overrides), so a conf-only edit now invalidates the page cache -
  previously a stale render (e.g. `Content-Language: en` on a host the conf had
  since switched) survived until the source changed. Keyed on file mtimes, so it
  holds under one-shot CGI and a persistent FastCGI worker alike;
  `resolve_site_vars` is self-invalidating on (conf mtime, host) as a backstop.

Per-host caches are visible and clearable in the manager
: Sub-domain renders live under `lazysite/cache/hosts/<host>/` and were invisible
  on the Cache page (and not deletable via Files, correctly). They are now listed
  with their host and can be cleared per host (or wholesale). The manager preview
  no longer double-encodes UTF-8 (French/Thai mojibake); the live render was
  already clean.

Domains: the "alias" concept is retired in favour of clone
: A domain alias was only ever a domain created as a copy of another, then an
  independent domain - so the separate alias entity and the "alias of X" grouping
  are gone. **Add domain** gains a "Copy settings from" pre-fill (the same
  outcome, as a normal domain you can then edit); every domain is a flat,
  independent row. The underlying multi-host `alias_hosts` mechanism is unchanged.

Manager UX consistency and editor fixes
: One group/user picker everywhere (the token picker), one verb for opening
  settings (Edit), one word for destroying a resource (Delete), and Save buttons
  are consistently primary. The editor returns to the file's own folder on exit
  (not the root), and a reserved control-area file shows a clear read-only warning
  instead of a blank editor. Compatibility-freeze scope for the stable line is
  recorded in ADR 0008.

## 0.7.27 - EDGE: multilingual language sets (SM179) + subdomain delete-safety + domains UX (2026-07-18)

Multilingual sites: language sets over the multi-site plane (SM179)
: A set of sibling domains - one per language, each its own content root - can be
  linked as one language set (a shared `lang_group`). The engine knows the
  siblings, so every layout receives ready-made switcher data in `[% languages %]`
  (each language's URL for the current page, the current one flagged, and whether
  that translation exists); the built-in layout renders a switcher plus
  `<link rel="alternate" hreflang>` alternates and an `x-default`, and per-domain
  sitemaps gain `xhtml:link` hreflang alternates for pages whose counterparts
  exist. A page's language is declared with `lang:` (site-wide or per host),
  overridable in front matter, and surfaces as `<html lang>` and a
  `Content-Language` header. A `json:` source resolves against the content root
  first - so a translated page reads its own root's data - then the docroot.
  Layouts localise their own chrome via `layouts/<layout>/strings/<lang>.json`
  loaded into `[% t %]`, with per-key English fallback. A read-only `lang-status`
  control-API action and a Domains "Language coverage" panel report each sibling
  root's current / stale / missing pages (mtime-based, or exact via a
  `translated_from` content hash) so a translator re-does exactly what changed;
  `whoami` and the MCP connector announcement tell an agent the set exists, where
  each language's files live, and the rule (translate values, never keys, paths or
  structure; never hand-build a switcher or hreflang). Engine-chrome localisation
  (login, validation, 404) is deferred. Gate: t/unit/lib/40-lang.t,
  t/integration/19..23-*, t/unit/manager/35,36-*, t/unit/mcp/06-lang-note.t.

Theme/layout deletion accounts for every domain, not just the primary (SM177)
: Delete-safety previously considered only the primary's active theme/layout, so a
  theme or layout a sub-domain depended on could be deleted out from under it.
  Deletion now scans every registered domain (base plus aliases/sub-domains),
  resolving each host's effective layout/theme the way the engine serves it, and
  refuses - naming the domains - while any of them use the artifact. Sub-domains
  are first-class peers of the primary here. Gate:
  t/unit/manager/37-theme-delete-domains.t and a case in 08-layout-delete.t.

Audit log: a domain target no longer opens in the file editor (SM178)
: A domain action's target is a host, not a file - and a host ending in a
  dot-suffix (`.io`, `.com`) was mistaken for a filename, so clicking it tried to
  open the host in Files. Domain and language actions now link to the Domains page
  instead.

Domains: access lists are picked, not typed, and the edit panel is organised
: "Groups allowed to manage" and "Users locked to this domain" are now tick-lists
  of the site's real groups and accounts (previously free text, easy to mistype a
  name that never matches); the domains list surfaces both so they pre-tick. The
  domain edit panel is grouped into aligned Identity / Presentation / Access
  sections rather than one ragged row. The "Domain access - set on the Domains
  page" pointer is removed from the group editor.

## 0.7.26 - EDGE: content history + domain access model + manager batch (2026-07-18)

Content history follows renames, and a delete ends the thread (SM175)
: Moving a file now carries its version history to the new path, and a delete
  ends that file's history: a later file created at the same path starts clean
  and never inherits the deleted one's past (previously a moved file's history
  looked lost, while a recreated path leaked the old file's timeline - because
  the log was keyed on the pathname). Renames are recorded as first-class moves
  (a Lazysite-Renamed-From trailer) across every channel - the manager Move, the
  MCP rename_page, and WebDAV MOVE - so the Files "History" panel lists the full
  lineage and can view, diff and restore even pre-rename versions. Agent tool
  guidance now steers connectors to rename_page / move_file rather than
  recreating-and-deleting (which would break the history). Gate:
  t/unit/lib/19-git-rename-history.t, plus move-history cases in
  t/unit/manager/25-git-actions.t and t/unit/dav/05-copy-move.t.

Themes: install no longer auto-activates, and an unedited theme is not backed up (SM176)
: Installing a layout or theme from the catalogue no longer switches the live
  site to it - install and activate are separate steps (use the theme's Activate
  button), so installing several themes in a row no longer keeps flipping the
  active one. And switching away from a theme now snapshots it only when you have
  actually edited it since install; a pristine, never-edited theme is not backed
  up (previously the first switch always copied it, cluttering the backups).
  Gate: t/unit/manager/13-theme-pristine-backup.t.

Nav editor shows which file it edits, so an inactive override is obvious (SM169)
: When editing a domain's menu, the nav editor now always states the exact file
  it is editing and whether it is the domain's own nav or the shared default -
  e.g. "Editing this domain's own menu: lazysite/nav-2.conf" versus "shares the
  default site's menu (lazysite/nav.conf)". A domain whose nav_file override is
  not actually in effect (so the editor is really editing the base file) is now
  visible instead of a silent surprise. The underlying resolve/read/write path is
  confirmed correct end to end (a per-domain override is read from its own file;
  an empty override shows an empty menu, never the base menu). Note: a theme that
  hard-codes its own navigation instead of rendering the standard [% nav %] menu
  bypasses this system - that is a theme fix, not a core one. Gate:
  t/unit/manager/34-domain-nav-override.t.

Audit trail: a sub-user manager sees their team's activity (SM173)
: A user who manages sub-users (the create_sub_users permission) but does not
  hold the full Audit-trail permission now gets a scoped audit view - their own
  actions plus those of the accounts beneath them in the managed_by / created_by
  tree - instead of being denied entirely. The user filter lists only that team,
  and the view is labelled "Showing your team's activity". A full Audit-trail
  holder still sees the whole log. Gate: t/unit/manager/35-audit-subusers.t.

Saving the navigation now publishes it immediately (SM168)
: The menu is baked into every page's rendered HTML, so a nav change used to sit
  invisible behind stale page caches until each page happened to re-render -
  saved, but not live. A nav save now refreshes the page cache the same way a
  theme or layout change does, and the editor confirms "Navigation saved and
  published (N pages refreshed)" so it is clear the change is live, not just
  written to the file. Gate: t/unit/manager/34-domain-nav-override.t.

Compound groups: a group can contain another group (SM121)
: Groups can now nest. Adding a group as a member of another group means that
  sub-group's members inherit the parent group's capabilities and domain scope -
  so an operator can compose roles (put "clienta-editors" inside "all-editors")
  instead of re-granting the same capabilities on many groups. The capability and
  scope resolvers expand membership transitively - and cycle-safely - on every
  channel (manager, control API, MCP, WebDAV and the render path). On the Groups
  page, typing a group's name into a group's member box nests it (nested groups
  are tagged); from the CLI/API use group-nest, and group-remove to un-nest.
  Nesting requires full user-management rights. Gate: t/unit/lib/11-caps-resolver.t,
  t/unit/users/18-group-nest.t.

Domain access control: domains own who may manage them, with per-user locks (SM165)
: Access now lives ON the domain. Each domain names the GROUPS allowed to manage
  it (allowed_groups) and the USERS locked to it (locked_users), edited on the
  Domains page - the single place a domain's access is set. A delegated editor is
  confined to the content roots of the domains their groups allow; a lock narrows
  them to just that domain; a domain with no allowed groups is operator-only. A
  created sub-user (e.g. a delegated MCP agent) can never out-reach its creator:
  its scope is intersected up the created_by chain at resolve time, and it cannot
  hold a capability the creator lacks. The same resolution feeds every channel
  (manager UI, control-API token, MCP, WebDAV), so a lock holds identically
  everywhere; this replaces the per-group dav_scope of SM155 (whose binding fields
  leave the Groups page). Compound groups (SM121) expand before the allow-check,
  so a group-of-groups grants domain access too. Gate: t/unit/lib/20-domain-access.t
  (resolver + sub-user ceiling, including the deny-all edge where a lock narrows to
  nothing) and t/unit/manager/31-domain-confinement.t (end-to-end, every channel).

## 0.7.25 - EDGE: forms discoverability + manager UI/key/WebDAV fixes (2026-07-18)

Forms: native forms are discoverable where an agent acts (SM161)
: Agents hand-wrote dead `<form>` HTML instead of the native `:::form` + bind_form
  flow, because the good docs lived on bind_form (the finish line). The
  create_page/write_file tool descriptions and the MCP initialize instructions now
  say "never hand-write a form; use create_form or a :::form + bind_form"; a new
  create_form tool scaffolds a native form and points at bind_form; validate_page
  warns on hand-authored/`mailto:`/third-party forms (the last a data-governance
  leak) and on unbound `:::form`s; audit_site gains a broken_forms category. Also
  fixes the fence bug where `:::form` (no space, as the docs wrote it) rendered as
  literal text. Gate: `t/unit/mcp/05-forms.t`,
  `t/unit/processor/07-convert-fenced-form.t`.

Keys: a machine key records use over the API and WebDAV (SM163)
: A key showed "not used yet" while actively reading over WebDAV, because use was
  stamped only on the MCP connector path. Every credential path (control-API
  token, WebDAV Basic auth, MCP) now records use, throttled to at most one write
  per window. Gate: `t/unit/users/17-keys.t`.

WebDAV: PUT auto-creates the missing parent chain (SM166)
: A PUT under a missing collection returned 409 (one level) or a confusing 502
  (several). It now mkdir -p's the parent chain, confined to the docroot and
  refused for a traversal path, so a deep PUT just works. Gate:
  `t/unit/dav/04-put-delete-mkcol.t`.

Manager: UI fixes from 0.7.24 testing
: The file editor no longer false-warns "unsaved changes" on load (SM170); the
  Sessions/Keys tables scroll within their box on narrow screens (SM171); the
  audit page gains an auto-refresh (10s) checkbox (SM172); the Domains form uses
  one "Layout / theme" selector instead of two (so you can't pick a theme without
  a layout) (SM167); folders get an actions dropdown (rename/move, delete) like
  files (SM162); and the Domains edit row now exposes every per-domain field the
  add form does - content_root is editable (repoint a domain, with a hint that it
  does not move files) and searchable-by-default is a true/false select rather
  than a free-text box (SM174).

## 0.7.24 - EDGE: site packages, manage_domains, nav domain-awareness (2026-07-18)

Capabilities: a `manage_domains` capability, carved out of `manage_config` (SM160)
: `manage_config` was a grab-bag. Domain management and the portable site-package
  family now have their own `manage_domains` capability, so a delegated domain/
  site operator no longer needs the broad `manage_config` (which also covers
  auth-secret rotation, the bad-URL blocker, backups and plugins). It unlocks
  `domains-list`, `domain-add/set/remove/alias-add/preview/check` and
  `site-backup-create/upload/apply` (API) + `site_backup`/`site_apply` (MCP); the
  Domains nav and Groups editor reflect it. Edge-only, so no migration - new
  installs' manager groups get it automatically. Gate:
  `t/unit/lib/05-capabilities.t`.

Users: the account name expands the row; Configure opens the editor
: Clicking an account name opened the configure modal (confusing next to the
  disclosure triangle). The name now expands/collapses the row like the triangle;
  the Configure button is the only way into the editor sheet.

Sites: portable per-domain site packages - create / export / import / apply (SM158)
: An agency demo can be handed to a client's own instance, or a site moved
  between domains/instances, without the whole-docroot backup (which carries
  every client and the auth secrets, so it is system-user only). A package holds
  ONE domain's site - its content root, its nav override, the referenced layout
  pruned to its one theme, and a manifest of the presentation keys - and
  deliberately excludes plugins, instance settings and secrets, so it is
  self-service. Apply extracts to an isolated staging dir (M-TAR hardening, drops
  symlinks, rejects path escapes), safety-snapshots the target first, copies the
  content into the target content root, installs the theme/layout only if
  missing, places the nav, and writes the target domain's keys. Surfaces:
  control-API `site-backup-create/upload/apply`, MCP `site_backup` / `site_apply`,
  CLI `lazysite-site backup|apply` - all manage_domains + scope. `site-backup-upload`
  is the first backup upload (backups were server-only). Gate:
  `t/unit/manager/35-site-package.t`.

Nav: domain-aware editor + a clearer "add menu item" affordance (SM159)
: The nav editor is now domain-aware - a picker chooses which domain's nav to
  edit (its `nav_file` override, or the shared base with an "inherits" note); the
  add-item inputs move behind an "+ Add menu item" button that expands a labelled
  box. `nav-read`/`nav-save` take a host. Gate:
  `t/unit/manager/10-control-api.t`.

Backups: every artefact carries a `lazysite-` prefix
: Backup files are now `lazysite-<kind>-<UTCstamp>.tar.gz` (site packages
  `lazysite-site-<host>-...`), so they sort together and are unmistakably ours.

Audit: path-less actions record a meaningful target
: The audit trail named a bare `/` for actions that act on something other than
  a file. Now domain-*/site-backup-* record the host, `config-set` the key that
  changed, `backup-create` the kind, and login/logout the site host. Gate:
  `t/unit/manager/19-audit-target.t`.

## 0.7.23 - EDGE: Files breadcrumb root icon fix (2026-07-16)

Manager: the Files breadcrumb root shows its folder icon again
: The site-root breadcrumb rendered its markup as literal text ("<span
  ...>[folder]</span>") instead of the folder icon. The breadcrumb link callback
  escaped every label - correct for path segments (directory names, an XSS
  guard) but wrong for the root item's trusted icon HTML. The root label is now
  passed through un-escaped (its title is already escaped where the span is
  built); segment labels stay escaped. Regression since the 0.7.16 XSS hardening.

## 0.7.22 - EDGE: domains panel backlog (public-IP field, cert SANs, switcher) (2026-07-16)

Domains: set this server's public IP from the panel (canonical_ip)
: The domain check's proxy/NAT fallback (`canonical_ip`) is now a field on the
  Domains panel - view/set the server's public IP(s) without the CLI. It may be
  cleared (empty = auto-detect); IP-literal validation stays. `config-read` now
  surfaces it. `t/unit/manager/17-config-set.t`.

Domains: the cert-coverage-gap detail names what the certificate covers
: When a served certificate doesn't cover the checked host, the check now lists
  the cert's SANs (dNSName), so the operator sees exactly which names are covered
  and that this one is missing - "a certificate is served (covers *.example.com)
  but not this host". `t/unit/manager/34-domain-check.t`.

Domains: a multi-domain switcher in the file browser (SM157)
: An editor scoped to several domains (member of multiple scoped groups) now gets
  a "Domain:" switcher in the Files page to pick which content root to browse,
  instead of an empty root that the server then denied outside the union. Single-
  domain editors and operators are unchanged; union confinement holds regardless.
  `t/unit/processor/28-domains-nav.t`.

Manager: create-user group membership - regression test
: The 2026-07-13 "new-user group dropped on submit" report was already fixed in
  v0.7.14 (the create form flushes a group typed but not staged as a pill). A
  regression test now locks the backend contract (`users-page` returns the
  group's members after a create-time group-add). `t/unit/users/02-api-mode.t`.

## 0.7.21 - EDGE: domain check distinguishes a certificate coverage gap (2026-07-16)

Domains: the check tells a certificate coverage gap from no HTTPS
: When full TLS verification fails, the check probes again verifying the
  certificate CHAIN but not the hostname. A trusted certificate that does not
  cover the host - a SAN/coverage gap, e.g. Hestia did not add the sub-domain to
  the certificate - is now reported as "a certificate is served (for X) but does
  not cover this host - add this host to the certificate (e.g. via Hestia SSL)",
  distinct from "no trusted HTTPS" (an expired, self-signed or absent cert). It
  points the operator at the cert fix; lazysite still never touches certificates
  itself. `t/unit/manager/34-domain-check.t`.

## 0.7.20 - EDGE: proxy-aware domain check + graceful degradation (2026-07-16)

Domains: the "points to this server" check works behind a proxy / NAT
: The check compared the domain's public IP against `SERVER_ADDR`, which behind
  a reverse proxy is the private inbound address - a permanent false failure.
  It now self-discovers the server's PUBLIC address: an operator `canonical_ip`
  config key (comma-separated, settable via the manager), else resolving the
  install's own domain (its `site_url` host), else a public `SERVER_ADDR`. When
  none is known the check is INDETERMINATE (not failed) and points the operator
  at `canonical_ip` - the "Serves this lazysite" check remains the authoritative
  reachability signal. `t/unit/manager/34-domain-check.t`.

Domains: the check degrades gracefully when TLS/HTTP modules are absent
: `domain_check` lazy-requires IO::Socket::SSL / HTTP::Tiny; a box without them
  now reports "TLS/HTTPS check unavailable" instead of crashing the request.
  `t/unit/manager/34-domain-check.t`.

Domains: the edit form's Layout is a picker of installed layouts
: Layout is now a dropdown of installed layouts with "inherit the default"
  (matching the Theme picker), not a free-text field.

## 0.7.19 - EDGE: domain config check + domains panel fixes (2026-07-16)

Domains: preview no longer fails on a live (wrapped) deployment
: The Preview shelled `$LAZYSITE_PROCESSOR`, but the Apache/Hestia rewrite (and
  the dev server) set that env var to the ORIGINALLY requested CGI - the
  manager-api itself when a preview runs - so the preview re-entered manager-api
  with auth stripped and showed `{"error":"Authentication required"}` instead of
  the page. Both previews (page and domain) now resolve `lazysite-processor.pl`
  by name in that cgi-bin, never trusting the wrapper's target. A regression
  test drives the wrapped case (`LAZYSITE_PROCESSOR` pointing at manager-api).
  `t/unit/manager/33-domains-api.t`.

Domains: an alias mirrors its canonical's presentation (title fix)
: Aliasing a sub-domain showed the DEFAULT site's title, because
  `domain_add_alias` copied only `content_root` + `site_url`. An alias now copies
  every per-host override the canonical set (site title, theme, layout, nav,
  search), so it presents identically to the domain it aliases.
  `t/unit/manager/33-domains-api.t`.

Domains: content folder is optional; reserved paths defined once
: A domain with no content folder now registers and serves the DEFAULT site
  (the engine already treated an empty content root as the docroot root). The
  "not the lazysite/ tree" guidance is replaced by an actual server-side block,
  driven by a single `Lazysite::Manager::Common::path_is_reserved` /
  `@RESERVED_ROOTS` definition (the "system"-owned areas), which
  `_clean_content_root` now calls instead of restating the rule.
  `t/unit/manager/33-domains-api.t`.

Domains: a `domain` template variable for per-host content
: The render stash exposes `domain` - the sanitised host being served (primary
  OR alias) - so a single content folder can branch per domain,
  `[% IF domain == 'clienta.com' %]...[% END %]`. Complements the existing
  `alias_host` (empty on the primary); cached per host, DNS-alphabet-only so it
  can never carry markup. `t/integration/16-domain-aliases.t`.

Domains: add/edit panel usability (live-testing feedback)
: The add panel is full width and table-styled (was a half-width card); Site
  address auto-derives `https://<host>` as you type the domain; fields carry
  friendly labels and FQDN guidance instead of raw conf-key names. The domains
  table shows a curated column set and scrolls inside its own box, so a new
  domain's action buttons no longer run off the page. The inline edit row is a
  styled panel with friendly labels that pre-fills each field's current value
  (inherited values shown as a greyed placeholder).

Domains: check a domain's live configuration (SM156)
: A Check button (and `lazysite-domains check <host>` / a `domain-check`
  control-API action) reports whether a registered domain is configured to serve
  THIS install live, in four ordered steps: DNS resolves, points to this server
  (the resolved IP is our own), a trusted HTTPS certificate terminates for the
  host, and an HTTPS request lands on this instance (a new public,
  CORS-open `/.well-known/lazysite-instance.json` marker echoes a stable
  per-install id). The server side does the DNS/IP/TLS/marker work a browser
  cannot; the panel then adds a browser-side probe for the visitor's-eye view.
  The outbound probe is bound to registered hosts (no SSRF) and manage_config-
  gated - which also tightened `domain-preview`, whose registered-host check had
  been a no-op (it matched the ever-present default row). Gates:
  `t/unit/manager/{33-domains-api,34-domain-check}.t`,
  `t/integration/16-domain-aliases.t`.

Domains: preview gains an "Open live site" link
: The preview keeps its in-session server-side render (works pre-DNS) and adds a
  link that opens the real domain in a new tab, for once it is live.

Hestia: `update-all` discovers by template, not the marker union
: `lazysite-hestia-update-all.sh` used the lister's default (template UNION
  install-marker) output, so a domain that had an install marker but had been
  moved OFF the `lazysite-app` template was still updated. It now uses
  `lazysite-hestia-list.sh --template-only` (new flag) - the Hestia web template
  is the sole authority - and reports any marker-only domains it deliberately
  excluded so the operator can reconcile them. `t/tools/33-hestia-list.t`.

## 0.7.18 - EDGE: group-level domain delegation (SM155) + preview + aliases (2026-07-16)

Domains: the delegation binding moves from the account to the group (SM155)
: SM154 confined a delegated editor to a domain via a per-account `dav_scope`;
  live-testing wanted a *team* to manage a sub-domain in one step. The binding
  (`dav_scope` content root + `home_domain`) is now a GROUP setting: adding a
  member to a scoped group both grants editing and confines them to that domain.
  A member of several scoped groups gets the UNION of their content roots
  (consistent with how capabilities union across groups), enforced on every
  channel - manager UI, control API, MCP and WebDAV. The per-account binding is
  dropped (single-source); set it on the Groups page > Domain binding, or
  `group-set <group> dav_scope <root>`. Gates:
  `t/unit/manager/{30-dav-scope,31-domain-confinement}.t`,
  `t/unit/mcp/02-dav-scope.t`, `t/unit/users/05-settings.t`.

Domains: preview a domain before DNS/TLS is live (SM155)
: The Domains panel gains a Preview that renders a domain's home page as a
  public visitor sees it under its own Host - server-side, so an operator can
  prepare and debug a new domain before pointing DNS at it. New `domain-preview`
  control-API action (manage_config). `t/unit/manager/33-domains-api.t`.

Domains: first-class aliases (SM155)
: A host can serve the same content as an existing domain (`clienta.com` +
  `www.clienta.com`). `domain_add_alias` / a `domain-alias-add` action / a
  `lazysite-domains alias` CLI verb register an alias host sharing the canonical
  content root and site_url; the Domains list groups aliases under their
  canonical with an "alias of X" tag. `t/integration/18-domains-served.t`.

Domains: add-form and theme picker polish
: The add-domain form is grouped into Identity and Presentation, and the theme
  field (add form + inline edit) is a dropdown of installed themes rather than a
  free-text box.

## 0.7.17 - EDGE: domains admin (agency multi-domain management, SM154) (2026-07-15)

Domains admin: the agency multi-domain management plane (SM154)
: SM151 lets one instance serve many first-class domains; SM154 adds the admin
  plane to manage and delegate them without shell access, staying strictly on
  the lazysite side of a hard line - DNS, the web-server domain alias and TLS
  are a precondition (operator/Hestia/an external orchestrator), never touched
  by lazysite. Model B (domain-scoped delegation): an account is bound to a
  domain via `home_domain` + `dav_scope` and confined to its `content_root` on
  every channel; the agency super-admin sees all. Delivered in three parts.
  Gates: `t/unit/manager/{31-domain-confinement,32-domains-engine,33-domains-api}.t`,
  `t/integration/18-domains-served.t`, `t/unit/processor/28-domains-nav.t`.

Domains: a bound editor is confined on the interactive channel too (P1)
: The scope confinement built for tokens/MCP (M2) is now applied on the cookie/
  manager channel for a `dav_scope`-bound user, through one shared helper across
  WebDAV, token/MCP and cookie - so a delegated domain editor cannot read, list
  or write another domain's content through the manager UI. Operators are
  unconfined.

Domains: register/configure/remove from the UI and CLI (P2)
: A single engine (`Lazysite::Manager::Domains`) registers a domain as
  `alias_hosts` + `alias.<host>.<key>` in `lazysite.conf` plus a content-root
  directory (optionally seeded), with strict host + content-root validation (no
  traversal, no `lazysite/` tree) and in-place conf writes that preserve a
  site-user's mode/group. Exposed identically through the manager `domain-add`/
  `-set`/`-remove` control-API actions (manage_config, POST-only) and a
  scriptable `lazysite-domains` CLI (`list`/`add`/`set`/`remove`, `--json`),
  so an external control panel can drive the lazysite side of a deploy. A domain
  registered this way is served by the SM151 processor under its Host header.

Domains: management panel + gated nav + auto-scoping (P3)
: The Domains page is now a full CRUD panel over the P2 actions. The Domains nav
  entry shows only to a user who may manage domains. A bound editor's file
  browser (and breadcrumb) roots at their own `content_root` - the processor
  stashes `manager_caps`/`scope_root`/`home_domain` and the layout exposes the
  latter as JS globals. `home_domain` is a settable, hostname-validated account
  key surfaced in `settings-get`.

## 0.7.16 - EDGE: security hardening round 1 (SEC-2026-07) (2026-07-15)

Security round 1 (SEC-2026-07): this release is a dedicated security-hardening
pass. An 11-agent review (static across every surface plus black-box probers on
a live multi-account, multi-site instance, then a focused RCE/OS-access
follow-up) was run against 0.7.15; every critical, high and medium finding is
fixed here and covered by a regression test. The durable register of what the
round covered - so future rounds extend rather than repeat it - is
`security/audit-register.json`. Exploit-level detail is kept out of the repo by
policy; the entries below describe the defect and the fix.

Critical: plugin runner no longer executes an arbitrary on-disk file (RCE-1)
: The manager plugin runner resolved a caller-supplied `script` name with no
  confinement, so any account with manager-UI access could write Perl into a
  file and have the runner execute it as the web user. Plugins are now resolved
  through a canonical `plugin_registry()` (core scripts + the `plugins/`
  directory, symlinks refused) - the first step of the plugins-vs-core
  formalisation (SM152) - and `resolve_plugin_script` returns only a registry
  entry. `t/unit/manager/27-plugin-registry-rce.t`.

Critical: account-takeover via password reset is closed (C1)
: The cookie/manager path reached the account-management action ungated, so a
  content-only account could reset any password, including an administrator's.
  The `users` action now requires a user-management capability
  (`manage_users`, or a delegated `create_sub_users` /
  `delegate_sub_user_creation`), and `cmd_passwd` takes an actor and refuses to
  reset an account outside the actor's own delegated sub-tree.
  `t/unit/manager/29-cookie-authz.t`.

Critical: content includes can no longer read the secrets tree (C2)
: A `::: include` (and the `json:` reader) was confined only to the docroot and
  never excluded the `lazysite/` management tree, so a content author could
  include `lazysite/auth/.secret` and leak the cookie-signing secret (and
  password hashes) into a public page. Includes are now confined to the
  request's content root and refuse any path resolving under `lazysite/`.
  `t/unit/processor/06-convert-fenced-include.t`.

High: cookie/manager path is capability-gated, POST-only, docroot-confined (H1-H4)
: The capability model existed only for token clients (`%need`); the cookie
  (manager-UI) channel was treated as a trusted operator, so a low-privilege
  interactive account could config-set, run backups, list users, and more (H1).
  The same per-action model now applies to the cookie path, and state-changing
  actions must be POST so a GET cannot bypass the CSRF gate (H2). The manager
  file layer's containment check had a sibling-prefix escape
  (`index($real,$DOCROOT)` with no trailing slash - `public_html.bak` passed for
  `public_html`); it is now boundary-safe (H3). The generic file editor is
  denied the sensitive `lazysite/` subtrees - auth store, logs, backups,
  templates, manager chrome, form-config secrets - while the capability-gated
  authoring areas (`layouts/`, `themes/`, `nav.conf`) stay reachable (H4).
  `t/unit/manager/{28-file-editor-confinement,29-cookie-authz}.t`.

High: SSI #exec and .htaccess handler-injection RCE removed from the templates (H-SSI, H-HTACCESS)
: The shipped Apache/Hestia vhost templates enabled `Options +Includes` (SSI
  `#exec`) and `AllowOverride All` (`.htaccess`) on the writable docroot, so a
  `manage_content` author could publish `evil.shtml` or a handler-injecting
  `.htaccess` and gain execution. Templates now ship `+IncludesNOEXEC` and
  `AllowOverride None`, and active-content / server-config extensions
  (`.pl .cgi .php .shtml .phtml .htaccess .htpasswd` ...) are refused on save,
  upload and WebDAV write. `t/lint/12-vhost-hardening.t`.

High: front-matter and the manager breadcrumb are XSS-escaped (H5)
: A page's front-matter `title`/`subtitle`/`author` were emitted unescaped in
  every layout, and the manager breadcrumb built an `onclick` from an unescaped
  path/label (a directory can be named with a payload). Front-matter is now
  HTML-escaped at the single point it enters the template stash - protecting
  every layout, including third-party ones - and the breadcrumb escapes both the
  JS-string and HTML contexts. `t/integration/17-frontmatter-xss.t`.

High: the remote fetch re-validates redirect targets (H6)
: The SSRF guard checked only the initial URL; LWP then followed up to seven
  redirects unchecked, so a public URL that 302'd to `169.254.169.254` or
  `127.0.0.1` reached internal targets. Redirects are now followed manually with
  the guard re-run on every hop, plus a response-size cap.
  `t/unit/lib/19-fetch-ssrf.t`.

High: the dev server is confined and no longer wedges (H7, L-DEVBIND)
: `tools/lazysite-server.pl` served any existing file - including
  `lazysite/auth/users` and `../../etc/passwd` - unauthenticated, and bound
  `0.0.0.0`. Its static/auto-index handlers now realpath-confine to the docroot
  and deny the `lazysite/` tree, dotfiles and traversal; it binds `127.0.0.1` by
  default (`--host` opts into a LAN bind). A bare POST to `lazysite-auth.pl`
  with no `?action` self-exec'd in a loop and wedged the single-threaded server;
  the wrapper now refuses to exec itself. `t/unit/tools/02-dev-server-confinement.t`.

Medium: token/partner scope, session lifecycle and backup restore hardened (M1-M5, M-TAR)
: Cross-domain includes are confined to the content root (M1, same fix as C2).
  `dav_scope` is now enforced on the MCP and control-API channels, not only over
  WebDAV, so a scoped partner credential that also holds `api`/`mcp` can no
  longer reach the whole content namespace (M2). Logout now invalidates the
  session server-side (revokes the sid) rather than only clearing the browser
  cookie, so a captured cookie stops working immediately (M4). Group membership
  is re-resolved from the live groups file each request rather than trusted from
  the 24h cookie, so a demotion takes effect at once (M5). Backup restore
  extracts with `--no-same-permissions` so a hostile archive cannot restore
  setuid/world-writable modes (M-TAR). `t/unit/manager/30-dav-scope.t`,
  `t/unit/mcp/02-dav-scope.t`, `t/unit/auth/13-logout-and-groups.t`,
  `t/unit/manager/22-backup-restore.t`.

Low/info hardening
: The manager plugin list and the alias-redirect body now escape their output
  (attribute-safe), the FastCGI pool unit gains `NoNewPrivileges`,
  `ProtectSystem=full`, `PrivateTmp`, `RestrictSUIDSGID` and related sandboxing,
  and the CSRF-token-survives-logout window is closed in practice by the M4
  logout revocation. A per-account login throttle and the OAuth register
  rate-limit are deferred (recorded in the register), and the secret-file
  `chmod` TOCTOU is accepted as shielded by the `02770` auth directory.

## 0.7.15 - EDGE: multi-site bare-docroot exclusion (SM151 §7) (2026-07-14)

Multi-site: bare-docroot scan excludes other domains' content roots (SM151 §7)
: A primary/default host with no `content_root` scanned the whole docroot, so
  its sitemap and search enumerated every client subtree's pages. The page
  scanner (`scan_pages` for registries, `resolve_scan` for search) now skips
  any directory that is a declared content root - the base `content_root:` or
  any `alias.<host>.content_root:` (`_declared_content_roots()`) - so a
  bare/default host lists only its own docroot-root content, and no domain
  lists a nested sub-domain's pages. Non-domain directories stay part of the
  bare host's content. Single-site installs (no content roots declared) are
  unchanged. Gate: `t/integration/17-multisite-content-root.t`.

## 0.7.14 - EDGE: multi-site (SM151) + Hestia fleet discovery + field fixes (2026-07-14)

Fix: conf writes preserve mode/group; create-user keeps its picked groups
: Two field reports from the beta-channel sweep and live testing. (1)
  `install.pl --channel` / `--policy` (any `set_conf_line` write) replaced
  `lazysite.conf` via temp+rename WITHOUT preserving the original's mode and
  group - a site-user CLI run turned a `siteuser:www-data 0664` conf into
  `siteuser:siteuser 0644`, and the manager (web-server user, no-suexec)
  could no longer save settings. The atomic replace now restores the mode
  and (best-effort) group; `lazysite check --fix` repairs anything left.
  (2) On the Users page, a group picked in the create-user input but not
  committed with Enter / the picker's Add was silently dropped when "Add
  user" was clicked - the account was created with no groups. The create
  flow now flushes the pending selection first and refuses an unresolvable
  group name instead of dropping it.

Multi-site: many first-class domains under one instance (SM151)
: First-class multi-site under one instance - an alias host can be rooted at
  its own content subtree with `alias.<host>.content_root`, so one docroot,
  one auth store and one AI/MCP endpoint serve many domains that each present
  as an independent site. `content_root` and `site_url` join the SM110 alias
  override whitelist. The served path is confined under the domain's content
  root (`confine_content_root()` + tightened realpath checks): a root can never
  escape the docroot or reach the `lazysite/` management tree, and a bad or
  missing root degrades that host to the docroot root with a WARN rather than
  failing. Each domain also emits its own `<link rel="canonical">` in the head,
  driven by the resolved per-host `site_url` (a declared value, never the
  request Host), injected regardless of layout and deferring to a layout that
  already emits one. Registries (sitemap, feeds, llms.txt) are generated
  per content root: a domain with its own `content_root` gets a first-class
  sitemap/feeds written into its subtree, listing just its own pages with
  content-root-relative URLs and its own `site_url`; the page scanner no
  longer follows symlinked directories (no cycles, no cross-domain leak) and
  never indexes the `lazysite/` tree. Search (`scan:` directives) is boxed
  to the requesting domain's content root, so a search on one domain never
  returns another's pages and result URLs are domain-relative; the scan
  root is published per request and the scanner shares the same symlink
  safety and realpath confinement. A read-only **Domains** manager view
  (System nav) lists the configured domains and their per-host keys
  (`domains-list` control-API action, `manage_config`-gated for token
  clients), and each first-party access-log line now records the requesting
  Host so per-domain visitor stats are possible later. Aliases stay operator
  conf-file territory (the manager displays, never edits, them). Static files
  under a content root (sitemap, feeds, robots, images, css, downloads) are
  served by the processor from that subtree with a content-type by extension
  (binary-safe, confined) - so each domain's own SEO artefacts and assets
  serve at its URL, not just its rendered pages. For production, the
  apache/nginx vhost tools gain a `rewrites --docroot D` verb
  (`Lazysite::DomainRewrites`) that generates a per-Host rewrite from
  lazysite.conf so each alias domain's static files serve directly from its
  content root, skipping the app - clean page URLs and /lazysite, /cgi-bin,
  /manager still reach the processor. Adversarial gate:
  `t/integration/17-multisite-content-root.t`; API gate:
  `t/unit/manager/23-manager-read-actions.t`; rewrite generator:
  `t/tools/32-domain-rewrites.t`.

Hestia: authoritative site discovery + reusable lister (SM139 follow-up)
: New `installers/hestia/lazysite-hestia-list.sh` lists every lazysite site
  on a Hestia host from Hestia's OWN registry - a domain whose web template
  is `lazysite-app` - unioned with the install markers as a cross-check, so
  a lost marker or a marker-without-template is flagged instead of silently
  skipped. `--plain` emits `user<TAB>domain<TAB>docroot` for bulk operations
  (channel sweeps, bulk updates). `lazysite-hestia-update-all.sh` now
  discovers via the lister (marker-glob fallback for an older STAGE) - the
  unreliable `/home/*` glob is no longer the primary discovery. Also fixes
  `ver_of` printing nothing instead of its placeholder on a missing state
  file (perl -ne exits 0 on a missing file), and the manifest classification
  now excludes `.git` as a file as well as a directory (a git WORKTREE has a
  `.git` file, which broke build-manifest - and with it several tool tests -
  when run from a worktree). Test: `t/tools/33-hestia-list.t`.

## 0.7.13 - STABLE: public QR component + manager polish from the demo review (2026-07-12)

Manager polish: click-to-configure names, no group-edit reloads, clearer wording (SM150)
: Users tree: clicking an account NAME opens its editor (consistent for
  top-level and sub-accounts - a leaf name did nothing before), and the accent
  disclosure triangle is the obvious control to expand a sub-tree; the explicit
  Configure button stays, de-emphasised. Groups: editing a group no longer
  reloads the list - a capability toggle or member change updates just that
  group's summary/pills in place (the full renderGroups() reload on every
  capability toggle was the jolt). Permission-denied messages say "an
  administrator can grant it on the Groups page" instead of "an operator"
  (clearer to the person reading it) - audit, sessions & keys, notifications.

QR codes on public pages: a shared asset + a built-in ::: qr component (SM147)
: The bundled QR library is promoted to a shared PUBLIC asset at
  `/assets/qrcode.js` (served from the docroot, no auth) - the manager 2FA QR
  loads it there now, and so does a new built-in **`::: qr data="…"`** content
  component that renders a QR (link, payment URL, wifi string, ...) on any
  Markdown page, with an optional `size`. The processor gained a
  built-in-component fallback: `::: name` resolves against the active layout's
  `components/` first, then `lazysite/templates/components/`, so a built-in
  works on any layout and a layout can override it. The QR is drawn
  client-side from the matrix (the value is never inserted as markup - no
  injection surface). Guarded by t/unit/processor/17-component-qr.t.

## 0.7.12 - STABLE: manager UX overhaul from live field review (2026-07-12)

Plugin surface + Users/Groups polish from the demo review (SM149)
: Plugin Manager rows redesigned - the enable toggle with Configure stacked
  beneath it (no more column-jump on enable), the script path replaced by an
  info tooltip, and the core badge on the info side. Plugins can mark an action
  `hidden` (lifecycle hooks driven by the toggle - so Content history never
  shows "Enable" while enabled; the Stats "refresh" is programmatic only) or
  `unlisted` (ships and works but off the Plugin Manager - the payment demo,
  hidden until real payments exist, and Logging & forwarding, an operator/CLI
  concern). Remote sync's "Test connection" is gated behind a configured
  remote. On the Users editor: a **General** card (Type, Note, Email) leads,
  then Credentials, Groups, Capabilities, Account configuration; "Move under"
  shows the account hierarchy indented; the open account is carried in the URL
  so a full refresh reopens its editor. Group members and the add-user group
  picker are now the **same** "pick none-or-many" pill control (was a
  select-box vs pills), and adding/removing a member updates in place instead
  of reloading the page. Delete group is refused (UI + backend) while it has
  members. Appearance: trying a theme on/off only snapshots when something
  actually changed, so exploring stops spawning identical backups.

2FA setup can't lock you out, and the manager UI is more consistent (SM148)
: Two-step 2FA enrolment: setting up generates the secret/QR/recovery codes but
  leaves 2FA **pending** - not enforced at login - until a code from the app
  **confirms** it (Confirm & enable); a never-confirmed setup enforces nothing,
  so exploring the control cannot lock anyone out. Confirming your own account
  signs you straight out to sign back in with 2FA. Consistency pass from the
  same review: every manager **button** now has a low background that lifts on
  hover (was transparent-until-hover, looking like text); the account
  **hierarchy** bar is the accent colour; **Add user** and **Add group** are
  their own cards; the nav item is **Sessions & keys**; usernames on the
  Sessions/keys tables and group member chips link to the account; and the
  **Groups** page is restyled to match the Users one-line conventions it had
  drifted from.

Users page: the account tree and the account editor are now two surfaces (SM144)
: Field feedback: sub-accounts work, but operators could not tell whether they
  were editing a main account or a sub-account - a nested parent and child
  showed two identical settings stacks with nothing marking whose was whose -
  and each level of nesting made the edit panel narrower. Now the account list
  is a pure tree browser: **one line per account** (name, human/AI, a "(+N)"
  sub-user count, and its Configure button, all on the row - no expand-to-reveal
  step), sub-users nested (collapsed by default; the indent alone shows
  hierarchy). Editing opens in a single full-width **editor sheet** - a centred,
  fixed-width overlay with a solid accent-coloured header naming the account -
  the same size and position however deep the account sits, so nesting never
  shrinks it and whose settings are on screen is unmistakable (Esc / × /
  backdrop-click close it; a save refreshes it in place). In the sheet, the
  disable/delete actions move to their own **Danger zone** box at the end, and
  the credential control offers **Cancel setup link** to clear an outstanding
  setup link. Users-page markup only (render split into tree +
  accountSettingsHtml + an editor-sheet controller; new claim-cancel action);
  guarded by t/lint/10-users-select-configure.t.

Sessions page: see and revoke active access keys (SM145)
: The Sessions page gains an **Active keys** card listing every non-interactive
  account that holds a live machine credential (AI connector / API / WebDAV) -
  its channels, when issued, whether used, any expiry - each with **Revoke
  key**, which stops the credential on the next request while leaving the
  account intact. Interactive (human) accounts are excluded and refused: their
  credential is a login password, managed on the Users page, not a key.
  manage_users-gated like sessions; key-revoke is audited. Guarded by
  t/unit/users/17-keys.t.

2FA enrolment: a QR to scan, the secret to copy, and recovery codes (SM146)
: The two-factor control now shows state - **Set up 2FA** when off, an `enabled`
  tag + **Disable 2FA** when on. Setting up reveals a **QR code**, the copyable
  **secret** beneath it (manual entry when a QR can't be scanned), and the
  **recovery codes** behind a disclosure. The QR is drawn client-side from the
  account's otpauth URI by a newly bundled, self-contained QR library - no CDN,
  no host dependency (see below); the library only computes the matrix and
  lazysite draws the SVG, so the URI is never inserted as markup.

Bundled web assets are in the SBOM now, and stay there (SM147)
: The release SBOM was Perl-module focused; bundled third-party JS/CSS
  (CodeMirror, and the new qrcode-generator 1.4.4, MIT) appeared only in
  THIRD-PARTY-NOTICES. sbom-deps.json gains a `web_assets` channel, both are
  declared (with a NOTICES entry for the QR library), manifest-to-sbom.pl emits
  them as CycloneDX components, and t/lint/11-web-assets-sbom.t scans the tree
  and fails the build if a vendored bundle is undeclared.

## 0.7.11 - STABLE: the ladder reaches Site settings + a machine-readable backlog (2026-07-11)

The backlog is now machine-readable (status headers on every feature request)
: Every docs/feature-requests/SM*.md carries `status:` (shipped | partial |
  parked | candidate | superseded) and, where not shipped, a `status-note:`
  saying what remains or what replaced it - statuses derived from the
  CHANGELOG cross-reference and the session record. `tools/backlog.pl`
  lists the open work (--all for everything); a new lint gate
  (t/lint/09-feature-request-status.t) refuses any SM doc without a valid
  status, so the backlog cannot drift back to inferred. SM107 closed as
  superseded (SM138 retired the manager_groups key it asked a picker
  for); SM089 gets an honest candidate stub (filed 0.4.13, never
  spec'd).

Channel ladder reaches the Site settings page (field finding on 0.7.10)
: The manager UI's Update channel selector and the control API's
  config-set validator still offered only all/stable - the one surface
  most operators set the channel from could not select beta. The
  selector now offers all / beta / stable with the ladder explained in
  its note; the API accepts all|edge|beta|stable ('edge' as the CLI's
  synonym of 'all'); the site-facing docs (update-channel feature page,
  reference, configuration, FEATURES) teach the three-rung ladder; and
  the config-set test pins every accepted value plus a refused junk one.

## 0.7.10 - BETA: channel ladder, one-switch history, MCP version tools (2026-07-11)

Content history reaches MCP agents; layout switching taught everywhere it matters
: Closing the exposure audit: the MCP connector gains list_versions /
  view_version / restore_version (same manage_content gate and engine
  actions as the API's git-history/show/restore; reads audit-skipped,
  restore audited), so a connector agent can inspect and undo content
  changes. Discovery fixed at every layer: the capability map lists the
  new tools and gains two task recipes (restore-from-history, and
  switch-layout - install/activate FIRST, delete after), the onboarding
  brief mentions version history under the content grant, and
  ai-connector-tools.md - found missing six other live tools
  (describe_capabilities, list_themes, list_layout_catalogue,
  install_layout, delete_layout, submit_feedback) - is brought current
  (37 tools) with a Version history section and an explicit note that
  git-sync remote push/pull is operator-only by design. Field trigger:
  an audited failed delete-before-switch; the active-layout delete
  refusal now says what to do instead, and install_layout/delete_layout
  descriptions teach the order. End-to-end MCP test drives the real CGI
  dispatch: honest enabled:false, connector writes become versions,
  view returns exact content + diff, restore lands as the newest
  version, capability gate holds.

Release channel ladder: edge < beta < stable
: Owner request: a middle rung between early testing and the slow customer
  channel. A build now declares one of three maturities (build-manifest
  `--channel beta`, `release.sh --beta`; stable stays `--final`) and a
  site's `update_channel` is the minimum maturity it accepts - beta sites
  take beta+stable, stable sites take stable only, edge/unset takes
  everything. One ordering (`%CHANNEL_RANK`) drives the installer gate,
  `--channel-check`, the maintenance op and every CLI validator; the
  skip/force audit entries now name the site's actual channel. Ladder
  covered end-to-end in the installer suite.

Content history: one switch, and a conf-corruption fix underneath it
: Field feedback: enabling the feature took two enables (plugin tick, then
  Enable on Plugin Config). Plugins may now declare on_enable/on_disable
  lifecycle hooks (run with the Plugin-Manager toggle, descriptor literals
  only, failure surfaced on the page and never undoing the toggle);
  content-history declares both - ticking records the initial snapshot,
  unticking pauses recording with every version kept, Plugin Config stays
  as the inspection/recovery surface (Status / Enable / Pause). The hook
  work exposed a latent defect: removing a site's LAST plugin glued the
  neighbouring lazysite.conf lines into one corrupt line ("site_name:
  Tgit_history: enabled"); the rebuild is now line-wise, with a regression
  test.

## 0.7.9 - permissions say what they mean: SM095 leftover sweep (2026-07-11)

SM095 leftovers swept: per-account capability language and the missing group-set verb
: Field finding (audit trail, 2026-07-11): creating an AI account from the
  Users page still issued the pre-SM095 per-account `webdav on` call - the
  backend rightly refused it, but the page reported success anyway. The
  creation flow now relies on group capabilities alone and surfaces any
  failed follow-up step; the dead per-account toggle helpers are removed.
  A full sweep then cleared every other leftover: the CLI's `set` usage,
  help and error text no longer offer capability keys, the unreachable
  per-account webdav branch is gone, and the guidance in `webdav.md`,
  `theme-publishing.md` and the README teaches the group route
  (`partner-create` for AI partners). One real gap surfaced: the
  `group-set` verb that every refusal points at existed only in `--api`
  mode - it is now a shell command too, with a regression test proving
  the refusal's advice works verbatim.

## 0.7.8 - STABLE: version recording guaranteed + Content history as a plugin (2026-07-11)

Content history presents as a plugin; the Backups page is backups only (field feedback)
: Field feedback: the Content history controls were lost on the Backups
  page - and content history is not a backup, it is the enabling of change
  logging. The enable/status surface moves to a new `content-history`
  plugin (enable on Plugin Manager; Status / Enable actions on Plugin
  Config), coherent with its sibling Remote sync (`git-sync`), whose
  description now points at the plugin instead of the Backups page. The
  engine is untouched: same conf key, same `Lazysite::Git` machinery, same
  manager-api `git-*` actions, Files-page History unchanged. The Backups
  page drops the Content history card and the info-only Themes & layouts
  pointer card, and gains one intro line distinguishing the roles (backups
  = disaster recovery incl. secrets; versioning = the plugin; theme/layout
  snapshots = Appearance).

Content history can no longer fail silently (field defect, dito.tech)
: A pre-0.7.7 doctor chown left 0755 object dirs under lazysite/git, so
  every post-init commit failed while saves succeeded - silent version
  loss. Fixed at three layers: (1) the repo is initialised
  `--shared=group` (core.sharedRepository=group), so git keeps everything
  it creates group-accessible umask-independently, and the hook keeps the
  in-place-rewritten COMMIT_EDITMSG 0664 (an unwritable one is fatal to a
  commit); (2) lazysite-check gains repo-internals probes - FAIL naming
  the symptom on any repo path the CGI cannot use, WARN on a missing
  sharedRepository and on the failure breadcrumb, `--fix` repairs modes
  and sets the config; (3) failure is visible without log-diving: a
  COMMIT_FAILED breadcrumb (touched on failure, cleared by the next
  successful commit) is read by the plugin's status action and the
  doctor, and the Files page's empty history panel now suspects a
  recording failure instead of pretending the file is new. A guarantee
  suite (t/unit/lib/18-git-guarantee.t, the 16-audit-guarantee tier) pins
  a write-path registry (every manager/DAV write action classified
  hooked-or-exempt), the shared-permissions promise incl. a gc cycle, and
  the failure->recovery lifecycle across all four surfaces.

## 0.7.7 - STABLE: the field-validation round, cured at source (2026-07-11)

Audit completeness - CLI events, loud failures, umask-proof modes (defect round)
: a fresh 0.7.5 field provision showed only the `installed` audit event.
  Two root causes fixed: (1) the audit writer opened with `or return`
  (silent) and created `audit.log` at umask-default 0644, so a
  CLI/installer-created file rejected every www-data CGI append forever -
  the writer now creates 0664 umask-proof, self-heals an owned 0644 file,
  and WARNs (once per process) naming the lost action on any failure;
  install.pl's inline writer matches. (2) the users tool performed all its
  mutations with no audit calls - every state-mutating command now writes
  one entry (origin `cli`, invoking OS identity, manager-api action
  vocabulary), suppressed under `--api` where the calling surface already
  audits (one entry per operation from either path); `setup-manager`
  records its two events (group setup + credential issue). Fresh installs
  record the seeded update channel in the install event. A guarantee suite
  (t/unit/lib/16-audit-guarantee.t) pins failure-visibility and
  structurally forbids unclassified (unaudited-by-omission) actions in
  both the manager API and the users tool.

Logging & forwarding - audit/diagnostics to syslog
: the logging plugin (renamed "Logging & forwarding") gains
  `forward_audit`, `forward_diagnostics` and `syslog_facility`: best-effort
  syslog copies of the audit trail (pipe format, INFO) and application
  diagnostics (mapped priority) via core Sys::Syslog, eval-guarded so
  forwarding failure never breaks a request (WARN once).

CGI-writable file modes - umask-proof install (nav-save field defect)
: install.pl seeded `nav.conf` 0644 and the auth store 0640, locking the
  www-data CGI out of files it must write in place ("Cannot write nav:
  Permission denied" in the field). Seeds are now 0664/0660 and a
  generalised post-install sweep adds the group-write bit across the same
  CGI-writable list lazysite-check's 4b probe verifies. Permission-denied
  write errors from the manager now append an actionable hint (run:
  lazysite check --fix) when the errno is EACCES/EPERM.

lazysite-check --fix - the chown pass broke what it had just verified
: field root cause (dito.tech): the root `chown -R` pass hands every
  CGI-owned (www-data) runtime file to the site user - so a 0600
  `.secret` the CGI had minted, which run 1 verified accessible VIA
  OWNERSHIP, came out of the same `--fix` run as site-user-owned 0600
  (a 500 on every cookie verification); the post-fix re-check reported
  the new damage but the single apply pass never repaired it. Fixed
  twice over: the chown pass now replicates a CGI-owned path's owner
  bits onto the group before the handover (`handover_mode`: 0600 to
  0660, 0755 to 0775), and `--fix` iterates apply+recollect until
  stable (bounded at 3 passes) - one run converges, and a second run
  reports 0 failures for every mode-fixable category (group-ownership
  repairs still need root and stay explicitly reported, never dropped).

Split-identity invariant - secret mints 0660, compile cache umask-scoped
: every secret/salt mint (auth/.secret, forms/.secret, .csrf-secret,
  oauth.json, .access-salt, payment demo) now creates at 0660 -
  owner+group, never world - so a CLI-context mint no longer locks the
  www-data CGI out of cookie/secret verification (and vice versa). The
  processor scopes umask 0002 around the TT compile-cache surfaces (TT
  mkdirs its mirror dirs with the process umask) and the page-cache
  writes, so whichever identity renders first leaves cache/tt and
  cached .html group-writable; page refreshes were never blocked (the
  atomic rename needs only the setgid dir), the compile cache and
  check-tool noise were.

Fix - unsaved-changes warning on every explicit-save manager page (field report)
: the Nav editor lost unsaved reorder/label work silently on navigation. The
  SM118 settings pattern is lifted into a shared `mgDirtyGuard` helper in the
  manager layout; Nav (every mutation path), the Plugin Config surfaces
  (per-plugin forms, handler add/edit forms, form targets) and the Appearance
  layouts-repo field now show the "Unsaved changes" note and warn on leaving,
  cleared on save. The editor's lock release moved from `beforeunload` to
  `pagehide`, so cancelling the leave prompt no longer drops the edit lock.
  Immediate-apply pages (users, groups, sessions, cache, backups, plugins)
  deliberately stay guard-free.

## 0.7.6 - Licensing audit: notices + self-hosted theme fonts (2026-07-11)

Licensing - third-party notices + self-hosted theme fonts (audit round)
: the 2026-07-11 input-licence audit (for the AGPL + commercial-waiver
  evaluation) found one gap and one policy breach, both fixed: (1) bundled
  CodeMirror 5.65.16 ships minified with its MIT headers stripped -
  THIRD-PARTY-NOTICES.md now reproduces the licence and ships in the
  install set, with the DEP-5 stanza in debian/copyright; (2) the theme
  library carried fonts.googleapis.com links in 22 layouts - the
  lazysite-layouts release packs now BUNDLE all 16 font families (SIL OFL
  1.1, licences shipped per family, ~1MB deduplicated variable fonts),
  served first-party via generated fonts.css, with a check-no-cdn gate
  blocking any future external resource load at packaging time. Standing
  rule: no CDN anywhere in lazysite or its themes.

## 0.7.5 - Webserver glue debs + lazysite demo (2026-07-11)

Feature - webserver glue packages: lazysite-apache + lazysite-nginx (SM139 increment 6)
: Two new Debian packages wire lazysite into plain (non-panel) hosts. Each
  ships commented vhost examples for both runtime patterns - plain CGI
  (page misses through the CGI auth wrapper: Apache `FallbackResource`,
  nginx `try_files` + fcgiwrap) and the per-site FastCGI pool (anonymous
  pages to `/run/lazysite/<domain>.sock`, session-cookie-bearing requests
  carved out to the CGI auth wrapper on both servers) - plus a root-run
  render command (`lazysite-apache-vhost` / `lazysite-nginx-vhost`,
  `add`/`remove`) writing `sites-available/<domain>.conf`: it never
  touches site content, refuses to overwrite without `--force`, and
  prints - never runs - the enable/reload steps. A single reference,
  `docs/reference/webserver-wiring.md` (shipped in both packages), states
  the front-end contract once with copy-paste snippets for Apache, nginx,
  Caddy, lighttpd and any other server. Tests:
  t/tools/31-webserver-glue.t.

Feature - `lazysite demo`: the zero-argument try-it path (SM139 increment 6)
: `lazysite demo [--port N] [--dir PATH]` fresh-installs a scratch site
  (default `~/lazysite-demo`) from the host payload as the current user -
  root is refused, like every site-tree write - and serves it on the
  built-in dev server, printing the URL, where the site lives and the one
  `rm -rf` that removes it. Re-running reuses the site. No web server, no
  configuration; the deb README leads with it.

## 0.7.4 - Content history: the git backend (2026-07-11)

Feature - remote sync: push/pull the content history to a private remote (SM085 phase 1, sync half)
: The `git-sync` plugin (opt-in; needs content history enabled) syncs the
  site's history with an operator-configured remote repository. Configure
  the remote address (`https://host/path`, `git@host:path` or `ssh://` only
  - `javascript:`/`file:`/arbitrary schemes and embedded credentials are
  refused), branch and access token on Plugin Config; the token lives in
  the 0660, never-versioned `lazysite/git-sync.conf` and reaches git only
  through a transient `GIT_ASKPASS` helper reading an environment variable
  - never on a command line, in the stored remote URL or in git config.
  Actions: Test connection (ls-remote, plain-language verdict), Push
  ("Pushed N new changes"; refuses cleanly when the remote is ahead, never
  forces) and Pull (fast-forward applies; when both sides changed, the
  operator sees "These pages changed in both places: ..." and chooses Keep
  mine or Take theirs). Every apply takes a prerestore safety snapshot
  first, then invalidates render caches (sibling + host copies, wholesale)
  and reindexes aliases; outcomes are logged and audited with the action
  named ("git-sync (pull keep_mine)"). Plugin actions gained the minimal
  parameter extension (`run: 'action'` + declared `choices` rendered as
  buttons on a `needs_choice` reply); `lazysite-check` FAILs when an
  existing `git-sync.conf` is not excluded from the repo. No git
  vocabulary anywhere an operator reads. Tests:
  t/unit/plugins/03-git-sync.t (local bare-repo remotes, no network).

Feature - content history: per-file git versioning with view/diff/restore (SM085 phase 1 core)
: Opt-in version history for the site content. `git-init` (the Enable button
  on the Backups page's new Content history card, or the control-API action,
  gated on `manage_config`) sets `git_history: enabled` and adopts the
  current site into a repo at `lazysite/git/` (never web-reachable; the
  docroot is the work tree). Every content write then auto-commits with the
  acting user as author and the action as message - manager save / delete /
  move / copy / migrate-to-local, uploads, WebDAV PUT/DELETE/MOVE/COPY, MCP
  writes, nav and site-config saves, and content-backup restores; a batched
  operation is one commit, and a git failure never breaks the write. The
  never-versioned exclude list (auth store, forms, notify-xmpp.conf, logs,
  caches, backups, the repo itself, generated HTML, asset mirrors) is
  written at init and keeps the history safe to push to a private remote
  later; `lazysite-check` gains probes for the git binary, repo permissions,
  and a SECURITY FAIL when `lazysite/auth` is not excluded. Files-page file
  cards gain a History panel (per-version View / Diff / Restore; restore
  routes through the normal save path, so it is cache-invalidated, audited
  and itself the newest version). New control-API actions `git-init` /
  `git-status` / `git-history` / `git-show` / `git-restore` (reads
  audit-skipped; token gating manage_content, init manage_config); the
  capability map and host-dependencies docs are regenerated, with git
  recorded as an optional host binary in the SBOM environment section. The
  new module `Lazysite::Git` (list-form git exec only; sha/path validation
  before any git call) is the seam the git-sync remote plugin (follow-up)
  builds on. Tests: t/unit/lib/15-git.t, t/unit/manager/25-git-actions.t,
  and a commit-on-PUT block in t/unit/dav/04-put-delete-mkcol.t.

## 0.7.3 - Sessions, domain aliases, documentation currency (2026-07-10)

Feature - alias redirects: 302 override, reindex on move/copy, manager visibility (SM134 follow-ups)
: A page may declare `aliases_temp:` alongside `aliases:` (same list syntax);
  its entries redirect `302 Found` instead of the default `301 Moved
  Permanently`. The map schema stays backward compatible - a plain string
  value is a 301 target exactly as in 0.6.1; only 302 entries become
  `{ target, code }` (old maps need no migration; unknown codes read as
  301). Manager `move`/`copy`/migrate-to-local and WebDAV MOVE/COPY now
  reindex the affected page(s) - directories per page beneath them - so a
  rename re-keys its aliases immediately instead of on the next save. The
  Files page gains a read-only Aliases card (alias → target with a 301/302
  badge) backed by the new `aliases-list` read action (cookie: any manager;
  token: `manage_content`; audit-skipped as a read). The redirect target is
  still always the declaring page's own URL. Tests extended across
  t/unit/lib/13-aliases.t, t/unit/processor/26-alias-redirect.t,
  t/unit/lib/09-files-handlers.t, t/unit/dav/05-copy-move.t and the manager
  API suites.

Feature - Domain aliases: extra hosts serve the same site with their own chrome (SM110 phases 1+2)
: `lazysite.conf` gains `alias_hosts:` (comma-separated extra hostnames)
  and `alias.<host>.<key>:` per-host overrides, whitelisted to the
  presentation keys `site_name`, `theme`, `layout`, `nav_file`,
  `search_default` - security-relevant keys (`manager`, `auth_*`,
  `webdav_*`) can never vary by the request-supplied Host header and are
  ignored with a WARN. The processor sanitises the Host header (lowercase,
  port stripped, hostname alphabet) and overlays the matching alias's
  overrides in `resolve_site_vars`; the primary host, undeclared hosts,
  and malformed Host headers keep the base conf unchanged. The page cache
  is host-keyed (phase 2): the primary keeps its `.html` siblings exactly
  as before, while each alias host caches renders in its own slot under
  `lazysite/cache/hosts/<host>/` with identical caching rules - a themed
  render can never cross hosts. Every cache-invalidation surface (editor
  save/delete/move/upload, WebDAV writes, manager and MCP
  cache-invalidate incl. Clear All, theme/layout activation, nav-change
  sweep, backup restore, installer removals, audit report) also drops the
  per-host copies (`Lazysite::Util::unlink_host_copies` /
  `clear_host_cache`); shared registry regeneration is still skipped on
  alias requests. New `alias_host` TT variable (empty on the primary)
  lets layouts branch per host or mark canonical links. Conf-file only -
  not exposed through the manager UI or control API. Scoping doc:
  `docs/feature-requests/SM110-domain-aliases.md`. Tests:
  `t/integration/16-domain-aliases.t`.

Feature - Sessions page lists and revokes live sessions (SM141 phase 1)
: Signed cookies stay the source of truth; the payload gains a short random
  session id (`user:ts:sid:groups` - legacy 3-field cookies remain valid
  until natural expiry). Login appends `{sid, user, t, ip, ua}` to
  `lazysite/auth/sessions.jsonl` (sanitised UA, 24h self-pruning,
  loss-tolerant - a registry failure never blocks login), and cookie
  verification in the auth wrapper - the single enforcement point; the
  processor trusts the wrapper's X-Remote-* headers - gains a revocation
  check against `lazysite/auth/revoked.json` (revoked sids + per-user
  not_before, which also kills pre-sid legacy cookies; absent file = one
  `-f` stat; corrupt file = fail open with a loud WARN, never a lockout).
  Manager API: `sessions-list` / `session-revoke` / `user-revoke`
  (manage_users-gated, revokes audited with sid-prefix/username targets;
  not reachable by token clients). The Sessions page now lists live
  sessions (user, signed in, IP, device, "this session") with per-session
  Sign out and per-user Sign out everywhere; secret rotation stays as the
  nuclear option. lazysite-check probes the two new files alongside the
  secrets. Tests: t/unit/auth/12-session-registry.t,
  t/unit/manager/24-sessions.t.

## 0.7.2 - Packaged distribution: the SM139 arc (2026-07-10)

Feature - lazysite-hestia.deb: packaged HestiaCP integration (SM139 increment 4)
: Second binary package from the same source (Architecture: all; Depends:
  lazysite-common (= source version), sudo). Ships Apache web domain
  templates for both runtime patterns at
  /usr/share/lazysite-hestia/templates - `lazysite-cgi` (FallbackResource
  through the CGI auth wrapper, the proven lazysite-app wiring) and
  `lazysite-fcgi` (visitor pages proxied to the per-domain pool socket
  `/run/lazysite/<domain>.sock` via mod_proxy_fcgi; session-cookie
  requests, the auth wrapper and all cgi-bin/dav endpoints stay CGI - the
  wrapper is not pooled) - plus /usr/bin/lazysite-hestia-domain
  (add/remove/list): the hook-shaped, root-run panel integrator that
  prepares the 0551-locked domain root and docroot group/setgid as root,
  then DROPS to the panel user for `lazysite provision`, registers the
  site, and with `--fcgi` writes `/etc/lazysite/pools/<domain>.conf` and
  enables `lazysite@<domain>`. Decision recorded: hook script now; a
  panel-native Hestia app, if ever, wraps the same command. The deb
  supersedes the hand-run installers/hestia scripts (kept in-tree for
  existing deployments); INSTALL-RUNBOOK.md rewritten around the packages.
  lazysite-pool.pl now honours the `SOCKET=` pool-conf key it documented.
  Tests: t/tools/30-hestia-pkg.t (template invariants incl. the
  FallbackResource-to-auth contract and the socket convention
  cross-checked against the unit/launcher, CLI edge behaviour, pool-conf
  key schema vs the launcher's consumption, debian/ relations).

Feature - lazysite-check evaluates as the CGI + post-fix report (SM139 increment 5)
: Three field-driven hardenings of the permissions doctor. `--fix` now
  re-runs every check after applying fixes, so the printed report reflects
  the post-fix state (the `fixed:` action lines stay first; the report is
  marked as post-fix) - previously it showed the pre-fix snapshot, which
  read as "the fix did nothing". New manager-layout probe: when the manager
  is enabled, lazysite/manager/layout.tt must exist and be readable by the
  CGI identity, else FAIL naming the symptom (manager renders in the
  built-in fallback layout, stuck at "Loading..."). Effective-access checks
  (lazysite.conf readability, cgi-bin executability, the new checks) are
  evaluated via ownership+mode arithmetic against the expected uid/gid
  instead of -r/-x, so a root run can no longer pass files the www-data CGI
  cannot use; plus a group-execute traversal check on lazysite/,
  lazysite/manager/ and lazysite/auth/. Queued chmod fixes on the same path
  now compose (additive bits applied against the live mode) instead of the
  last chmod clobbering earlier ones. Tests: t/tools/04-check.t (post-fix
  re-report, layout probe, traversal).

Feature - fleet upgrade channels and policy (SM139 increment 3)
: Per-site `update_policy: auto|manual` in lazysite.conf (default manual;
  setter install.pl --policy, audited as policy-set; cached as policy= in
  the site registry, seeded by `lazysite provision --policy`). `lazysite
  upgrade --all` skips manual-policy sites with a per-site log line and
  lets install.pl's existing exit-3 channel gate decide auto-policy sites
  (channel skips now counted as skips, not failures); --force overrides
  both gates. New --force-security overrides channel AND policy fleet-wide
  but is honoured only when the payload release-manifest.json declares
  "security_critical": true (new build-manifest.pl --security-critical
  flag) - refused with a clear message otherwise. New `lazysite sites`
  verb lists the registry with live conf channel/policy and each site's
  installed version. Tests: t/tools/29-cli-fleet.t (policy x channel
  matrix, force/force-security, sites listing).

Feature - lazysite-common.deb + the lazysite CLI (SM139 increments 1-2)
: debian/ packaging builds lazysite-common (engine payload at
  /usr/share/lazysite, /usr/bin/lazysite, man pages, the lazysite@ FastCGI
  pool unit + /etc/lazysite/pools, the site registry /etc/lazysite/sites.d)
  via tools/build-deb.sh into the repo dist/ (relocated 2026-07-11; was /srv/projects/packages/). The CLI enforces the
  load-bearing principle - provision/upgrade REFUSE to run as root (upgrade
  --all drops to each site owner); verbs: provision, upgrade [--all], check,
  users, dev, version. tools/lazysite-pool.pl launches per-site FCGI pools
  (binds /run/lazysite/<site>.sock, drops privileges, execs the processor).
  Lintian-clean; smoke-tested from the extracted deb.

## 0.7.1 - Persistent runtime: FastCGI worker pools (2026-07-10)

Fix - man pages land under man/man1/ in the release tarball
: `git archive --add-file` stores only the basename, so the pages the 0.7.0
  batch-2 change added were shipping at the tarball root; release.sh now
  interleaves a per-page `--prefix` to place them under `man/man1/`. The
  shipped 0.7.0 tarball was rebuilt from the tag with the corrected paths.

Feature - persistent runtime: dual-mode FastCGI accept loop (SM142)
: spawned with a FastCGI listen socket on fd 0 (spawn-fcgi / the SM139 pool
  unit), the processor services requests from an accept loop - modules
  compile once, per-request state resets inside the loop
  (reset_request_state + the SM140 access record + the die-guard, now shared
  by both paths as handle_one_request). Invoked as plain CGI it is
  byte-identical to before; FCGI.pm is lazy-required (no new hard
  dependency). Prefork via FCGI::ProcManager (LAZYSITE_FCGI_WORKERS) with
  worker recycling (LAZYSITE_FCGI_MAX_REQUESTS, default 500). Measured:
  cache-hit 62.2ms CGI -> 0.4ms FCGI (147x). Tested over the real FCGI
  protocol via a minimal in-tree client (t/lib/MiniFcgi.pm) - state
  isolation across consecutive requests pinned. Packaging (systemd units,
  vhost config) ships with SM139; the auth wrapper stays CGI for now (its
  exec design), so pooling covers the visitor-facing hot path.

## 0.7.0 - First stable release (2026-07-10)

The first stable-channel release, cut on completion of the 2026-07-10
eight-dimension review resolution cycle (docs/review/2026-07-10-eight-dimension/,
see 01-resolution.md). The batch entries below are that cycle.

Tests - 2026-07-10 review batch 3 (coverage scope + floors)
: lazysite-oauth.pl gains 51 branch-focused behavioural tests (79.0/58.9 ->
  99.3/94.6 stmt/branch); lazysite-mcp.pl and lazysite-oauth.pl join the
  coverage gate (eight CGIs gated); floors ratcheted to 75% statements / 62%
  branches - the Commercial regime floor is now the enforced floor. Three
  documented per-file branch overrides at 60 (manager-api, auth, mcp - each
  within subprocess merge variance of 62, none weaker than the previous
  floor, each with a dial-back note).

Docs - 2026-07-10 review batch 2 (declarations + currency)
: RELIABILITY.md declares the reference SLO/RTO/RPO + error budget mapped to
  the existing failure-mode evidence (clears the D5 refusal); ADR 0007
  declares the pentest gate with a dated deferral waiver (clears the D6
  pentest condition); SECURITY.md gains the significant-change assessment
  register (SM070-072/128/136/137/140); the support period is declared (five
  years from 0.7.0, stable channel) and a draft Declaration of Conformity is
  in docs/ for signing at the 0.7.0 cut (clears the D8 conditions). The SM138
  manager_groups doc rot is swept from every security-tier and starter doc,
  FEATURES.md is current to 0.6.10, a retired-terms lint makes future sweeps
  unskippable, release.sh ships man pages in the tarball, and the Hestia
  deploy first-run sentinel no longer greps the retired key.

Fix - 2026-07-10 review batch 1 (seven code fixes)
: (1) six `:utf8` readers of user-settings.json in the auth wrapper made
  account_disabled/token_expired/account_expired/mfa_enrolled FAIL OPEN on any
  non-ASCII byte - now `:raw` with a red-green regression test; (2) plugin
  configs carrying a password field are chmod 0660 on save and
  notify-xmpp.conf/smtp.conf joined the lazysite-check secrets probe; (3) the
  SBOM declares the product licence as MIT (was Artistic-1.0-Perl on 211
  components); (4) the SM140 visitor key mints a persistent random salt on
  secret-less sites (was IPv4-brute-forceable); (5) an unmeasured gated CGI
  now FAILS the coverage gate instead of silently skipping; (6) the secrets
  lint uses `git grep -e` (the private-key check was vacuous) and every
  pattern has a planted-fixture self-test; (7) shellcheck -S error is a lint
  gate and release.sh refuses when perlcritic/perltidy/shellcheck are absent.

## 0.6.10 - Backlog housekeeping + SM141 sessions scoping (2026-07-10)

Docs - backlog housekeeping + SM141 scoping
: thirteen shipped items moved to Done; SM139 promoted to NEXT UP; SM141
  (session registry + revocation list - list and control active sessions)
  scoped and sequenced after the review and 0.7.0 stable.

## 0.6.9 - AI visitor analytics reads the first-party log (2026-07-10)

Feature - AI visitor analytics reads the first-party log (SM140 i3+i4)
: `analyse_visitors`/the stats export now ingests the first-party access log
  (per-day-file byte offsets into the same incremental day-bucket cache;
  `source` field in the export), so the AI connector analytics also work with
  zero web-server setup. The server log remains the fallback. Docs updated
  (manager, AI briefing); form/dav channel tags deferred until a consumer
  exists (the format already accommodates them).

## 0.6.8 - First-party analytics: stats work out of the box (2026-07-10)

Feature - first-party analytics: lazysite records its own traffic (SM140 i1+i2)
: the processor writes one anonymised JSON line per request to
  `lazysite/logs/access-YYYYMMDD.jsonl` (daily-salted visitor key - never the
  IP; injection-sanitised; O_APPEND-atomic; daily files, retention-pruned,
  default 90 days; `first_party: off` in stats.conf disables). Visitor
  Statistics reads it as the primary source - working out of the box with NO
  web-server log access, no ACLs, no vhost changes, and no nginx-vs-apache
  undercount. The server-log parser remains the fallback/enrichment
  (`source` field says which). Bonus: an unhandled processor error now
  answers a clean 500 (and is recorded) instead of a headerless crash.
  analyse_visitors (AI export) converts in a later increment.

Fix - visitor stats says when the log exists but is unreadable
: on a panel host (Hestia) the domain log exists at an auto-detect candidate
  path but www-data cannot read it; the page said "No access log found",
  hiding the actionable fix. find_log now returns an existing-but-unreadable
  candidate as a last resort so the page reports "exists but is not readable
  by the web-server user" and points the owner at --resolve-log.

## 0.6.7 - Fix: TT compile cache can no longer break rendering (2026-07-09)

Fix - layout renders survive an unwritable TT compile cache
: the field incident behind the marriage-morris manager outage: dirs under
  `lazysite/cache/tt` the CGI cannot write made Template Toolkit fail every
  layout render (TT 2.x: fatal `.ttc` write error -> silent fallback chrome;
  TT 3.x: dies in Provider -> 500). Rendering now retries once without the
  on-disk compile cache; a manager-layout failure shows a loud `ls-layout-error`
  banner naming the TT error (manager pages are auth-gated; public pages keep
  the silent fallback). `lazysite-check` gains a cache/tt writability probe;
  `--fix` removes the tree (a pure cache - it regenerates).

Fix - Users page recent-changes call (audit noise)
: users.md tunnelled `recent-changes` through `action=users`, which rejects it
  ("Unknown action" audit failures); it now calls the top-level action like the
  Files page, and the recent-change dots load.

Fix - plugin-save audit names the keys that actually changed
: a site-title edit logged "lazysite (8 settings)" because the UI posts the
  whole form; the save now diffs against the existing conf and the audit
  records just the changed keys (or "(no changes)").

## 0.6.6 - Fix: installer ownership repair scoped to root-owned files (2026-07-09)

Fix - 0.6.5 upgrade regression
: the align-ownership pass chowned everything under `lazysite/` to the docroot
  owner AND group, stripping the www-data CGI's access on a site whose docroot
  group was not www-data (auth wrapper 500). Now repairs ONLY root-owned paths,
  never re-owns CGI runtime files or operator content, and uses the web-server
  group (www-data when present). Affected sites: `lazysite-check --fix` as root.

## 0.6.5 - manager_groups retired + fresh-install robustness (2026-07-09)

Breaking - manager_groups retired (SM138)
: manager access is granted by GROUPS only: the `ui` capability (manager UI) and
  `manage_users` (operator powers), managed on the Groups page. The legacy
  `manager_groups:` conf key is retired with an AUTOMATIC migration: on the first
  settings read, any group it named receives the full manager grant explicitly
  (all capabilities except the remote api/mcp channels, SM127) and the conf line
  is removed - effective access is unchanged. The unsecured/dev mode is now keyed
  on "no group grants manager access" (was: "manager_groups unset"). whoami's
  manager_groups and lazysite-check derive from group settings; the processor's
  config descriptor no longer lists the key. See UPGRADE.md.

Fix - fresh-install robustness (field reports)
: `setup-manager` guarantees the admin group's capabilities and a conf-declared
  manager group with no capability entry self-heals on any settings read (the
  fresh-0.6.3 trap: the new manager could not add a user). `install.pl` sets
  `lazysite.conf` to 0664 and, run as root, aligns `lazysite/` ownership to the
  docroot owner ("Cannot write lazysite.conf: Permission denied").

Fix - manager UI field reports
: browser autofill no longer fills the Users-page Rename/username inputs or
  plugin credential fields with the operator's saved login
  (`autocomplete=off`/`new-password`); the notification bell is greyscale when
  nothing is unread, coloured with the unread badge; notify-xmpp's recipient
  field is labelled "Recipient JID" and the sender nickname defaults to the
  sanitised site name.

## 0.6.4 - Fix: the SMTP Validate button placement (2026-07-08)

Fix - the SMTP Validate button is reachable
: the 0.6.3 Validate action rendered only on the form-smtp plugin card, which is
  hidden whenever form-handler is enabled (any site using forms) - so the button
  was effectively invisible. It now lives in the SMTP connection section of the
  handler wizard / edit form on Plugin Config, with the staged verdict shown
  inline. It checks the SAVED settings (save first, then validate).

## 0.6.3 - SMTP connection validation (2026-07-08)

Feature - SMTP connection validation (SM137)
: a **Validate SMTP connection** action on the Plugin Config page runs a staged
  check against the saved `smtp.conf` and names the failing stage - host (DNS),
  port (TCP reach; a plain probe runs first so a closed port is never mistaken
  for TLS), TLS (STARTTLS vs implicit vs none, with the mode to try), or auth
  (rejected with the server code, or no password set). Never sends an email;
  time-boxed. `resolve_password()` shared by delivery and validation.

Fix - typed SMTP password reaches delivery
: the 0.6.2 `password` field was stored but omitted from the `--pipe` delivery
  merge, so authenticated sending failed despite a correct password. Now merged.

## 0.6.2 - Notifications: capability, XMPP delivery, human-event notices (2026-07-08)

Feature - notifications capability + XMPP delivery + human-event notices (SM136)
: a new `notifications` capability (seeded on the `user-managers` group) gates the
  manager bell - the notices actions refuse without it and the bell hides itself.
  A shared write path (`Lazysite::Notify`) appends to the bell store and, when the
  new **notify-xmpp** plugin is enabled, also delivers each notice over XMPP - one
  client config per site like SMTP (JID + password + recipient: an individual or a
  group-chat room; based on the xmpp-lite connector, `Net::XMPP`, best-effort and
  time-boxed). New human-awaiting-a-response notices: a password-reset request when
  no SMTP is configured (previously a silent dead-end), and agent feedback
  submissions - alongside the existing form-submission notices.

Feature - SMTP password field
: the SMTP delivery config (Plugin Config form and the handler wizard) now has a
  **password** field - typed once, stored in the operator-only `smtp.conf`, never
  shown back. `password_file:` remains as an alternative and is used only when no
  password is set.

Docs
: FEATURES.md brought current with the 0.5.x-0.6.1 lines (front-matter keys,
  caching, manager UI, backups + migration, forms, installer flags, the security
  model, the version timeline); OPERATOR.md and README refreshed to match;
  host-dependencies and capability docs regenerated.

## 0.6.1 - Content tools, backups, and change awareness (2026-07-07)

Feature - multi-step (wizard) forms (SM098)
: a `--- step ---` line (optionally titled) inside a `:::form` splits it into
  wizard steps with Back / Next and per-step validation; the form still posts once
  to the handler, and without JavaScript every step shows and it still submits.

Feature - page alias redirects (SM134)
: a page may declare `aliases:` in its front matter - old or alternate URLs it
  should also answer to. Those are maintained in `lazysite/aliases.json`
  (`Lazysite::Aliases`, updated on save/delete from the manager and WebDAV) and the
  processor issues a `301` to the canonical page when a requested path is a known
  alias and nothing else matched. The redirect target is always the declaring
  page's own URL (not an open redirect); a real page always wins over an alias.

Feature - full-system backups and cross-domain migration
: alongside content backups, `action_backup_create('full')` captures the whole
  site including the `lazysite/` infra (config, auth, forms, nav, themes/layouts).
  A full backup carries the auth secrets, so in-app restore refuses it and
  `install.pl --restore-full <file> --docroot X [--domain Y]` restores it from the
  shell, optionally rewriting the site domain - the temp -> final domain migration
  path. The Backups page is consolidated into typed sections (Content / Full-system
  / Themes & layouts).

Feature - show the visitor's IP (SM135)
: a `[% client_ip %]` Template Toolkit variable (the `X-Forwarded-For` first hop
  behind a proxy, else `REMOTE_ADDR`, sanitised) and a `nocache: true` front-matter
  flag that renders a page fresh on every request. Together they show each visitor
  their own IP - inline, or via a small `nocache` JSON endpoint fetched by script.

Feature - recent-change markers (SM103, phase 1)
: a `recent-changes` control-API action returns `{ target -> { ts, user, action } }`
  for changes within a window (default 24h), aggregated latest-per-target from the
  audit-log tail. The Files and Users pages show a small dot next to a
  recently-changed row, with a when / who / what tooltip.

Docs
: an objective eight-dimension measures-and-achievements summary
  (`docs/review/2026-07-01-eight-dimension/measures-and-achievements.md`); the
  operational-review items recorded as per-implementation hosting responsibilities
  with a dev-server exemplar.

## 0.6.0 - Stability milestone (2026-07-04)

Milestone marker - no code changes from 0.5.41
: this tag rolls the minor version to mark a mature, well-tested feature set and a
  stability point reached following the eight-dimension review. The 0.5.x line has
  settled: the groups-only capability model (channel x action), the manager UI, the
  WebDAV / control-API / MCP partner surfaces, the security posture (STRIDE threat
  model, manager/remote separation SM127, the bad-URL auto-blocker SM128), and the
  release + install tooling are all in place and exercised. Same tree as 0.5.41;
  all gates green (154 files, 2335 tests; perlcritic sev-3; security lint; compile;
  tidy; bench; coverage; strict SBOM). Not a breaking release - the
  backward-compatibility freeze stays a separate, tracked decision. Channel: edge.

## 0.5.41 - Manager security, content tools, settings clarity (2026-07-03)

Security - bad-URL auto-blocker (SM128, default on)
: `Lazysite::BadUrl` detects scanner probes (mirrors the stats noise set), counts
  them per source IP in a rolling window, and blocks at a threshold - enforced in
  the auth wrapper (a blocked IP gets 403). Configured via the `bad-url-blocker`
  plugin; blocked-IP list + unblock on the Stats page (`bad-url-blocks` /
  `bad-url-unblock`, gated on `manage_config`). Auto-blocks are audited. Covers
  auth-wrapped sites.

Security - manager accounts are interactive-only (SM127)
: an account with group-granted manager UI access (`ui`) is refused on the api and
  mcp transports; a group may not combine `ui` with `api`/`mcp`; the "Connect an AI
  assistant" panel shows only for accounts holding a remote channel. Closes the
  accidental "manager account connected as an agent" vector. `manager_ui` (the
  group-granted ui) added to effective_settings to drive the gates.

Feature - content tools
: **Duplicate a page** - `action_copy` + a "Duplicate…" Files action (copy owned by
  its creator). **Migrate to local** (SM096) - `action_migrate_to_local` fetches a
  `.url` page's remote body via the new shared `Lazysite::Fetch` (the SSRF guard,
  extracted from the processor; loaded lazily so the hot render path stays
  module-free) and writes it as a local `.md`.

Feature - theme_assets fallback
: a previewed/per-page layout with no compatible active theme falls back to the
  layout's declared `default_theme` mirror if installed, instead of unstyled.

Feature - manager UI clarity
: Site settings reorganised - "Enable the manager UI" toggle with a headless-CMS
  note, WebDAV under "Services", the duplicate Appearance entry removed, per-field
  notes now render. Audit timestamps shown in local time (UTC tooltip). Stats page
  audience-split bar.

Feature - install.pl channel controls
: `--channel edge|stable` sets a site's `update_channel` (standalone, atomic,
  audited `channel-set`); `--force` installs an out-of-channel build over the
  policy (audited `upgrade-forced`). No central site registry, so a fleet is a
  shell loop over docroots (documented).

Test/chore
: coverage for manager read actions (pages/config-read/principals/notices),
  manager-api branch floor 55 -> 60; audit + capability-drift docs; a batch of
  recorded feature requests (external auth, feedback cascade, onboarding endpoint,
  backups consolidation, A/B testing) and design decisions (backward-compat
  freeze, chunk-4 scoping).

## 0.5.40 - Code-quality gates + documentation debt (2026-07-02)

Feature - Perl::Critic severity 3 (review D2)
: the gate (`t/lint/02-perlcritic.t`) now enforces severity 3 with zero
  violations. The move fixed genuine findings - unchecked `open`s folded into
  their `-f` guards, unused capture groups made non-capturing - which keep their
  policies enabled. `RequireExtendedFormatting` is enabled with a 60-char
  complexity threshold (only complex patterns need `/x`; the access-log parser
  and a few others now carry a readable `/x` form). Remaining deviations are
  documented house conventions in `.perlcriticrc`.

Feature - perltidy tidy gate, changed-code-only (review D2)
: `.perltidyrc` is calibrated to the hand-written house style (newlines frozen);
  `tools/tidy-check.pl` / `t/lint/06-tidy.t` flag only lines a change touched
  (since the last release) that are not tidy. New/edited code is tidy without
  reformatting the legacy tree.

Docs - accessibility + man pages (review D7)
: `docs/ACCESSIBILITY.md` is a WCAG 2.1 AA self-assessment of the manager UI and
  default theme, honest about verified vs untested. The CLI tools carry POD, so
  `perldoc` works and `tools/gen-manpages.pl` renders man pages at release.

Chore - coverage-floor honesty
: the manager-api branch measurement has settled at ~57% across recent runs; the
  per-file override reflects the true figure (reaching 60 needs targeted
  dispatch-branch tests, backlogged).

## 0.5.39 - Agent capability discovery + strict api/mcp channel gating (2026-07-02)

Feature - capability map (SM126 A/B)
: a connecting agent can fetch the whole permission model in one call - the MCP
  tool `describe_capabilities` or the control-API `describe-capabilities` action.
  It returns the four channels (all enforced), each capability's title and what
  it unlocks (MCP tools, control-API actions, WebDAV paths), task recipes for
  common jobs, the engine-owned paths not to write, and the caller's own grant
  under `holds`. Built by `Lazysite::Capabilities` from `@CAP_KEYS` (one source of
  truth) and drift-checked against the live tool/action maps. Both endpoints are
  introspection - open to any authenticated caller. The human-facing
  `docs/reference/capability-map.md` and `quickstarts.md` are generated from the
  same builder (golden-tested), and the engine-owned vs private-author-file
  boundary (incl. the `_`-prefix convention) is documented for developers.

Feature - unified denial next-step (SM126 E)
: MCP `-32002` and control-API capability denials now point a refused agent at
  `describe_capabilities`, so it can see its grant instead of retrying blindly
  (the WebDAV denials already name the capability and where it is granted).

Feature - host dependencies (SM126 D)
: `tools/gen-host-deps.pl` generates `docs/reference/host-dependencies.md` (Debian
  packages + purpose) from `dist/config/sbom-deps.json`, with a golden test that
  fails on drift; `lazysite-check.pl --dependencies` reports present-vs-missing on
  a host and the install line for anything absent.

Security - strict api/mcp channel gating (SM126 A)
: the `api` and `mcp` channel capabilities were modelled but not enforced at the
  transport. A control-API token must now hold `api` and an MCP session `mcp`,
  enforced ahead of the per-action check - matching the ui/webdav gates.
  Introspection (whoami, describe-capabilities) stays open so a capless agent can
  self-diagnose; the manager UI (cookie = ui channel) is unaffected. OPERATOR
  ACTION: the standard onboarding and seed groups already grant these, so normal
  partners are unaffected; verify hand-provisioned token/connector accounts hold
  the channel cap.

Fix - capability drift
: the control-API `whoami` and the manager permissions grid now derive their
  capability list from `@CAP_KEYS` instead of hand-maintained arrays - `whoami`
  had dropped `delegate_sub_user_creation`.

## 0.5.38 - Reported-issue fixes: dev-server cookies + WebDAV denial reasons (2026-07-02)

Fix - dev server drops a repeated response header (RI-001)
: the dev server parsed CGI response headers into a name-keyed hash, so a header
  name that repeats collapsed to its last value. lazysite-auth.pl sends two
  Set-Cookie headers on login and logout (the session cookie + the SM099 display
  marker); the marker overwrote the real cookie, so dev-server login never
  established a session and logout left one live. Production Apache/nginx were
  never affected. `parse_cgi_headers` now returns an ordered [name, value] list
  and every header is forwarded in CGI order (the old `sort keys` is gone);
  extracted behind a modulino `caller` guard and covered by
  `t/unit/tools/01-dev-server-headers.t`.

Fix - WebDAV denials name their reason (RI-002)
: `authorise`/`authorise_layout` returned a bare 403 with a generic "Forbidden"
  body, so a partner refused for a missing capability, a wrong path, or the
  active-theme/layout read-only rule had nothing to act on - the reported
  theme-install trial-and-error. Each denial now records a reason, surfaced as
  `Forbidden: <reason>` and a machine-parseable `X-Lazysite-Deny-Reason` header,
  and logged. Authorisation is unchanged. Covered by
  `t/unit/dav/22-deny-reason.t`. The wider discoverability asks (capability map,
  quickstarts, private-file guardrail) are recorded in the feature-request
  backlog.

## 0.5.37 - Eight-dimension review: application actions 6-9 (2026-07-02)

Feature - fail-closed writes + failure-mode tests (review D5)
: the processor cache write and the form-handler append now fail closed - on a
  short write or a failed flush the tempfile is dropped and the event logged,
  instead of a torn page being renamed into place. New `t/integration/13-write-
  failure.t` injects disk-full (via `ulimit -f` + an `XFSZ`-ignoring harness, no
  root needed) and concurrent-PUT races to prove the behaviour. A weekly
  `logrotate` snippet ships under `installers/hestia/` (deployment held for
  pre-launch, per the operational holds doc).

Feature - in-manager backup restore (review D5, SM084)
: the Appearance backups panel gains a Restore button; `action_backup_restore`
  takes a safety snapshot first (aborting if it fails), overlays the archive
  (matching `install.pl --restore` semantics), and clears only cached `.html`
  that has a `.md` sibling - legacy static pages are preserved (SM133). 14-
  assertion round-trip test added.

Docs - decision records + currency sweep + threat model (review D6/D7/D8)
: ADRs 0002-0006 record the uncommitted-tree release contract, the channel x
  action capability model, install classification/provenance, the edge/stable
  channels, and raw-mode-for-artifacts-only. The doc set is brought current with
  the SM095 capability model (manager access is the `ui` capability on a group;
  `manager_groups` demoted to a legacy fallback) across `starter/docs/` and the
  developer guides, and the shared-module reality replaces the old "no shared
  modules" text. New `docs/SECURITY.md` is a STRIDE threat model with OWASP ASVS
  L1 control mapping (clearing half the D6 refusal); `docs/POLICY.md` corrects
  the CRA citation to Reg. (EU) 2024/2847. `reported-issues.md` records RI-001
  (dev server drops the second `Set-Cookie`; fix queued).

## 0.5.36 - Eight-dimension review: application actions 1-5 (2026-07-02)

Refactor - capability resolution (review D1)
: one shared `groups_grant_cap` helper in Auth::Settings; the login landing and
  the ACL operator bypass route through it (private copies deleted); the
  processor keeps its module-free copy, recorded in `docs/adr/0001` (first ADR).
  Encoding settled: JSON auth files are read as raw octets everywhere - the old
  `:utf8`-layer read silently wiped the whole read on any non-ASCII content
  (group description, user email). Regression test added.

Feature - by-design gates (review D1/D3/D4/D6)
: new lint gates `perl -c` (compile sweep) and security-themed perlcritic at
  severity 1; `release.sh` now runs `bench.pl --check` and the instrumented
  `coverage.sh --check` before the SBOM gate - a benchmark regression or a
  coverage-floor breach is unshippable.

Feature - coverage hardening (review D3)
: branch floor (60%) alongside the statement floor; `lazysite-auth.pl` joins the
  gate (82%/61%). Root cause of "not measured" CGIs fixed: %ENV-rebuilding tests
  dropped PERL5OPT, so instrumentation never reached the child - new
  `TestHelper::env_passthrough()` in all 12 sites, which also repaired the
  Plugins.pm (21->66%) and Upload.pm (37->82%) under-measurement artifact.
  manager-api's noisy branch measurement carries a documented per-file override
  (backlog: stabilise, ratchet back). Login rate-limit test de-flaked (window
  rollover). Baselines re-measured and recorded.

Feature - benchmark honesty (review D4)
: the render op measured only the CACHE-HIT path; split into
  `render_cache_hit_ms` and `render_miss_ms` (real render: 84 ms vs 60 ms hit).
  Baseline records host/perl/date provenance; `--check` warns on host mismatch;
  tolerance tightened 3x -> 2x (measured spread ~3%) with per-op overrides.

Fix - plugins (review D1)
: `payment-demo.pl` answers `--describe` (uniform interface; it now appears in
  the plugin list marked DEMO ONLY, and the discovery probe no longer burns a
  full page render); its long-standing compile warning fixed. Dead
  `_user_analytics` removed from the manager API.

## 0.5.35 - Content provenance stamp + "is it ours?" checker (2026-07-01)

Feature - content provenance
: shipped seed pages now carry a `provenance: lazysite-starter` front-matter stamp,
  so lazysite content can be told apart from operator content without relying on the
  install-state file. `lazysite-check.pl` gains a content-provenance report that
  classifies each `.md` page as lazysite-unmodified, lazysite-customised (stamped but
  edited), or operator-authored - the "is this likely ours?" audit behind the
  upgrade-safety work. The installer's 0.5.33 preservation behaviour is unchanged.

## 0.5.34 - Appearance backups listed newest-first (2026-07-01)

Chore
: the layout/theme backups panel on the Appearance page now lists snapshots
  newest-first (by their timestamp), instead of layout-then-alphabetical order.

## 0.5.33 - Fix: upgrade could overwrite an untracked homepage with boilerplate (2026-07-01)

Fix - upgrade data-loss
: the installer overwrote a seed file (e.g. `index.md`) that existed on disk but
  was not tracked in `.install-state.json` - planning it as a fresh install and
  copying the shipped boilerplate over the operator's content. The edited-vs-shipped
  guard only covered already-tracked files, so a homepage authored via the manager /
  WebDAV, seeded by a different install path, or written before it became
  manifest-tracked had no protection. Now an untracked seed file that already exists
  on disk is preserved (adopted into state), never clobbered; only an absent
  destination or a code file is written. Regression test added. Preview any upgrade
  with `install.pl --dry-run` to see the install/overwrite/preserve plan.

## 0.5.32 - Fix manager-bar links unclickable over themed headers (2026-07-01)

Fix - manager admin bar
: after moving the bar into normal flow (0.5.28) it lost its stacking context, so
  a theme's positioned header (sticky/fixed with a z-index, e.g. the explorer
  theme) painted over the bar where they meet and swallowed its clicks - the Manage
  / Edit / Sign out links stopped working. The bar now carries `position:relative`
  plus a max z-index: still in normal flow (scrolls away, no overlap), but with its
  own stacking context on top so its links stay clickable.

## 0.5.31 - Retire the Config-page "Manager access groups" field (2026-07-01)

Feature - SM095 tidy-up
: the "Manager access groups" (`manager_groups`) picker is removed from the Config
  page. Manager-UI access is the `ui` channel capability granted through a group
  (Groups page); only lazysite-admins needs it and it already has `ui`. The
  `manager_groups` value stays a backend-only fallback in lazysite.conf - config
  saves preserve it and the engine still honours it - it is just no longer edited
  in the UI.

## 0.5.30 - Stats caption tidy; backlog reorganised (2026-07-01)

Chore
: remove the redundant caption under the synthesised error panel on the stats
  page; reorganise the feature-request backlog (integrate new notes, de-duplicate,
  refresh shipped status).

## 0.5.29 - Synthesised error surface; raw log download removed (2026-07-01)

Security/privacy - Visitor Stats
: the "Recent server errors" panel showed the last 40 RAW error-log lines (client
  IPs, referer URLs, file paths, script names). It is now synthesised - each recent
  error is reduced to its Apache code/module with a friendly label and a count; no
  raw lines, addresses or paths are surfaced. The raw access-log download is removed
  entirely (the stats-log action, the offer_log_download config, and the download
  link), so the underlying logs are no longer downloadable through the manager.

## 0.5.28 - Manager bar no longer overlaps themed headers (2026-07-01)

Fix - manager admin bar
: the bar was `position:fixed` at the top and collided with a theme's own
  sticky/fixed header (e.g. the explorer theme) - on scroll the header slid under
  it. It now sits in normal document flow at the top of the page and scrolls away
  with it, so it never overlaps any theme, with no per-theme cooperation. Trade-off:
  it is no longer always on screen (scroll to the top for Edit / Manage / Sign out).
  Gating is unchanged and confirmed: anonymous visitors and logged-in members with
  no Manager-UI access see no bar (now covered by a regression test).

## 0.5.27 - Theme-adaptive login form (2026-07-01)

Fix - login styling on custom themes
: the login form drove its colours from fixed values, so it looked out of place on
  a polished custom theme. It now takes its accent, border and surface colours from
  the standard theme tokens (with the old values as fallbacks), adopting whatever
  theme is active and unchanged on the no-theme fallback layout.

## 0.5.26 - Migration: show legacy static HTML until Markdown lands (2026-07-01)

Feature - SM133 static-HTML migration fallback
: enabling lazysite on an existing static site no longer 404s the old pages. A
  clean URL with no Markdown source but a sibling static `<base>.html` is served
  (processor: verbatim; Hestia vhost: via a rewrite that prefers `.shtml` so
  Apache expands SSI). A `.md` always wins, so each page flips to lazysite the
  moment its Markdown lands. Auto-detected, no setting.

## 0.5.25 - Login page styling fix; audit is its own capability (2026-07-01)

Fix - login page styling
: `convert_md` protected `<script>` but not `<style>`, so inline CSS went through
  the Markdown emphasis pass - `*/ ... /*` between two CSS comments paired into
  `<em>` tags and swallowed the rules between them. The login page's form styles
  regressed exactly this way. `<style>` is now protected alongside `<script>`, so
  CSS/JS is never Markdown-processed. Affects any page with a multi-line `<style>`.

Feature - audit is a separate capability
: the audit trail was gated on the `analytics` capability; it is now its own
  `audit` capability, granted independently of visitor analytics. Seeded to the
  admins group on NEW sites. EXISTING sites are untouched - grant `audit` to
  whoever should see the trail (on the Groups page; the operator needs
  `manage_users` to do it, not `audit`, so no lock-out).

## 0.5.24 - Faster Users page, one capabilities view, safe "move under" (2026-07-01)

Performance - Users page
: the page loads in ONE request now (a users-page endpoint returning accounts +
  resolved caps + the group view + the operator identity), replacing three
  separate CGI calls. On a plain-CGI host that removes several Perl cold starts
  (whoami alone spawned two extra subprocesses) - the fix for slow load even with
  one user.

Feature - Users page
: the duplicate capability chip list is gone; the channel x capability grid is the
  single read-only "Capabilities" view. The "Move under" dropdown no longer lists a
  user's own sub-tree (or itself), which would form a cycle the server rejects.

## 0.5.23 - Live permissions grid, honest analytics, the building-sites briefing (2026-07-01)

Feature - permissions viewer
: the Users-page derived grid re-fetches on every open and gains a Recheck button;
  a new `lazysite-users.pl permissions USERNAME` CLI prints the channel x
  capability grid (from groups) for debugging access from the shell; the add-user
  group picker shows what each group is for. Plus retirement tidy-up of dead
  manager-group code left from c2.

Feature - analytics classifier
: headless/automation user-agents (HeadlessChrome, selenium, puppeteer, playwright,
  ...) and the self-identifying `lazysite-agent/<id>` (legacy `claude-code-agent`)
  opt-out marker are classified as bot, not human; infrastructure fetches (favicon,
  robots, sitemap, llms.txt, /.well-known/, feeds) count as noise. The `human`
  figure stops folding in the operator's own tooling.

Docs - AI agent pack
: a new "building sites" briefing (/docs/ai-briefing-building-sites) teaches the
  content/layout/theme separation and names raw mode (`api: true` / `raw: true`) as
  the root cause of monolith pages. Wired into the partner manifest, the MCP
  initialize instructions, the WebDAV onboarding brief, and the sibling briefings,
  so MCP and WebDAV agents both receive it.

## 0.5.22 - Retire the manager group: Manager-UI is the `ui` capability (2026-06-30)

Feature - SM095 (c2)
: Manager-UI access and operator status are now explicit capabilities resolved
  through groups, not a special "manager" group. A group's `ui` channel capability
  grants Manager-UI access (processor gate + login landing); the manage_users
  action is the unrestricted account-management operator bypass. manager_groups
  stays as a non-breaking fallback so no site is locked out. The Groups page drops
  the transitional "Manager group" toggle.

## 0.5.21 - Group descriptions, audited group changes, sub-user ordering (2026-06-30)

Feature - groups polish
: groups gain a description field; group capability/membership changes are audited
  with the group as the target; sub-users render at the top of the owning card.

## 0.5.20 - Clean cut: capabilities from groups only (2026-06-30)

Feature - SM095 (c1)
: capabilities resolve from group membership ONLY - per-account grants are no
  longer honoured or settable. Partner/sub-user creation grants via a role group;
  whoami reports the full capability set; the Users page capability toggles are
  replaced by a read-only summary + the Groups page.

## 0.5.19 - Analytics over the control API (2026-06-30)

Feature - analytics on the API channel
: visitor analysis (analyse_visitors) is now a control-API action as well as an
  MCP tool, gated on the analytics capability - so an API/WebDAV-partner agent can
  read the sanitised visitor stats, not only an MCP connector.

## 0.5.18 - Fix Users page failing to list (null username) (2026-06-30)

Fix - users page
: the batched users-detail load could return a null username (a clobbered map
  $_), crashing the Users page with a localeCompare error. Capture the name first
  and harden the front end.

## 0.5.17 - Route all capability checks through the resolver (2026-06-30)

Refactor - SM095 (c0)
: the sub-user gate and the onboarding briefs now consult the central resolver
  (caps_for/effective_settings) instead of reading per-account settings, so group
  grants apply to them. Non-breaking; sets up the groups-only clean cut.

## 0.5.16 - Users page: all groups, faster load, grid headers (2026-06-30)

Fix - users page
: the group list now shows every group (incl. seeded roles with no members);
  accounts + settings load in one batched call (was one subprocess per user); the
  permission-grid channel headers are centred.

## 0.5.15 - Channel capabilities + permission viewer (2026-06-30)

Feature - SM095 channel model + viewer
: added channel capabilities (ui/api/mcp) and manage_users; reseeded six role
  groups; the Groups page splits Channels from Actions; each user card gains a
  read-only channel x capability grid showing which group grants what. Additive.

## 0.5.14 - Central capability resolver (2026-06-30)

Refactor - one permission resolver
: capabilities now resolve through a single function (Auth::Settings::caps_for)
  that the manager UI, control API, MCP AND the WebDAV endpoint all consult, so a
  group grant applies identically across every channel. Behaviour unchanged.

## 0.5.13 - Group-based capabilities, Phase 2: Groups page (2026-06-30)

Feature - SM095 Groups UI
: the Groups page now edits per-group capabilities + a manager-group switch, and
  manages membership member-first (who is in, type-to-add, remove) instead of an
  all-users checkbox list.

## 0.5.12 - Group-based capabilities, Phase 1 (2026-06-30)

Feature - SM095 group capabilities (backend)
: capabilities can be carried by a group; members inherit the union. Seeds four
  role groups + flags manager_groups (lazysite-admins) as a full-capability manager
  group. Non-breaking - legacy per-user grants still apply this phase.

## 0.5.11 - Grant analytics from the UI + docs (2026-06-30)

Fix - analytics permission UX
: the Analytics capability is now a toggle on the Users page (was CLI-only), whoami
  advertises it, the audit denial points to the UI, and the AI/MCP docs cover the
  analyse_visitors tool + the capability.

## 0.5.10 - One layout/theme switcher (2026-06-30)

Feature - single appearance control
: the active layout/theme is now switched in ONE place (Appearance > Installed
  layouts & themes); the redundant Settings dropdowns and the Appearance select
  widget were removed.

## 0.5.9 - Backups collapse panel + batch delete (2026-06-30)

Feature - appearance backups
: layout/theme backup snapshots fold into one collapsed "Backups (N)" panel with
  per-item delete and a "delete all"; the installed list shows only real artifacts.

## 0.5.8 - Layout switch + backup proliferation fixes (2026-06-30)

Fix - layout/theme management
: a layout switch falls back to the new layout default theme instead of refusing
  when the live theme is not declared for it; backup snapshots no longer chain
  (-backup-...-backup-...); deleting a backup no longer spawns a replacement.

## 0.5.7 - AI visitor-log analysis Phase 2: audit (2026-06-30)

Feature - audit analytics
: the audit trail is now gated on the analytics capability (managers must be
  granted it) and read through an append-only cache (only newly-appended lines are
  parsed, not the whole log each load).

## 0.5.6 - AI visitor-log analysis (Phase 1) (2026-06-30)

Feature - AI visitor analytics
: new analytics capability + cached, incremental visitor-stats export (aggregates
  + sanitised event stream; no raw log, paths or IPs) + analyse_visitors MCP tool
  + /docs/ai-briefing-stats. The AI can analyse visitor trends on the operator's
  direction without ever seeing the raw access log.

## 0.5.5 - STABLE: fix skipped-site corruption + submissions viewing (2026-06-30)

Stable release
: repairs sites that were channel-skipped and left half-configured (manager 500s)
  - they upgrade and run the full deploy permission pass. The deploy now runs a
  --channel-check FIRST, so a skip touches nothing. Includes the submissions-
  readable fix (0.5.4) and the form delivery/blank-submit guards (0.5.2/0.5.3).

## 0.5.4 - Manager can view form submissions (2026-06-30)

Fix - submissions unreadable in the manager
: form submissions (lazysite/forms/submissions/*.jsonl) were blocked by the
  lazysite/forms config block, so the file editor showed them empty even though the
  records were saved. The submissions subtree is now readable; form configs stay blocked.

## 0.5.3 - Reject contentless form submissions (2026-06-30)

Fix - empty form submission
: a submission with every field blank and no file now errors instead of saving a
  contentless record behind a "thank you".

## 0.5.2 - Forms fail loudly when nothing accepts the submission (2026-06-30)

Fix - no false form success
: a form submission now errors (and logs) when every delivery target is disabled,
  unknown, or fails, instead of showing a "thank you" while saving nothing.

## 0.5.1 - New-site fixes: login layout, self-service link, webdav gate, logout audit (2026-06-30)

Fixes
: login form stacks correctly (password was beside 2FA); setup-manager --link
  prints a self-service password URL; per-user WebDAV errors when WebDAV is off
  site-wide; an unauthenticated /logout no longer writes audit noise.

## 0.5.0 - Stable consolidation release (2026-06-29)

Stable milestone
: first release cut on the STABLE channel. Consolidates everything since 0.4.78 -
  the manager-bar/cache fixes (incl. the homepage bar), json: UTF-8 fix, search-
  index + visitor-stats hardening, the update channel, form binary uploads + SMTP
  attachments. Stable-channel sites will install this (edge releases were skipped).

## 0.4.86 - Manager bar on the homepage (2026-06-29)

Fix - admin bar on "/"
: the Apache template served the cached index.html for "/" directly (DirectoryIndex),
  bypassing the processor, so the manager bar never appeared on the homepage. The
  lazysite-app template now routes a lazysite home through the processor. Existing
  vhosts must be rebuilt to pick up the template change.

## 0.4.85 - Batch update reports channel-skipped sites (2026-06-29)

Fix - update-all reporting
: the batch updater now reports stable sites that skipped an edge release as
  "skipped" (not "updated") and prints a final per-site version + channel summary.
  update_channel is also settable via the control API.

## 0.4.84 - Stable default for new sites; SMTP form attachments (2026-06-29)

Change - new-site default
: a fresh install seeds update_channel: stable, so new sites are protected from
  edge upgrades by default (existing sites without the key stay "all").

Feature - SMTP form attachments
: the email form handler can attach uploaded files (attach_files, default off) and
  lists them with sizes below the message.

## 0.4.83 - Form binary uploads (2026-06-29)

Feature - file uploads on forms
: forms accept binary uploads (images, PDFs) via a `file` field; per-form limits
  (count, size, accepted types) in FORMNAME.conf; files stored in a per-submission
  subdir next to the .jsonl with names recorded in the submission JSON.

## 0.4.82 - Update channel (stable vs edge) (2026-06-29)

Feature - per-site update channel
: a site can be set to the "stable" update channel (Manager -> Site settings) to
  refuse non-stable (edge) upgrades; the deploy is skipped and logged. Releases are
  cut stable with release.sh --final. Keeps the existing operator deploy process.

## 0.4.81 - Security: search-index + visitor-stats hardening (2026-06-29)

Security - search index
: the public /search-index no longer leaks absolute server paths (now docroot-
  relative) or inline <style>/<script> content in excerpts.

Security - visitor stats log path
: the access/error log path is owner-set (LAZYSITE_ACCESS_LOG env) or auto-detected
  only; a site manager can no longer point the reader at an arbitrary file.

## 0.4.80 - Fix manager-page corruption; link-audit restyle (2026-06-29)

Fix - manager UI corruption (regression)
: the admin bar (0.4.79) was injected into manager pages - behind the auth wrapper
  REDIRECT_URL is unset - and into a <body> in the head comment, corrupting the
  page. Resolve the path via REQUEST_URI too, and anchor the bar after </head>.

Style - link audit report
: the orphaned/broken-link report uses the modern mg-table / stat-tile styling.

## 0.4.79 - Admin bar out of cache; json: UTF-8 fix (2026-06-29)

Fix - admin bar vs cache
: the manager admin bar is injected per-request at output time, never baked into
  the shared page cache (so it can't leak to anonymous visitors or vanish for a
  manager served from cache); managers use the page cache again.

Fix - json: non-ASCII
: a json: source containing non-ASCII (em dashes, curly quotes) no longer resolves
  to empty - the file is read as raw bytes so decode_json handles the UTF-8.

## 0.4.78 - Revert build-stamped version (restore generator) (2026-06-29)

Revert
: 0.4.77's build-stamped [% lazysite_version %] only helped tarball installs and
  blanked the generator version on branch deploys; reverted to the install-state
  read. install --verify (0.4.76) remains the deploy-gap detector.

## 0.4.77 - Version reflects running code; login niceties (2026-06-29)

Change - trustworthy version + login UX
: [% lazysite_version %] now reports the running code's own stamped version (not
  the install-state side-car), so a stale deploy shows its real version. Login
  page tells an already-signed-in visitor and drops the demo credentials.

## 0.4.76 - install --verify: deploy-gap detector (2026-06-29)

Feature - trust the reported version
: install.pl --verify checks the installed code files against the release manifest
  (sha256), so a partial deploy that leaves stale code is caught instead of
  reporting the new version with old code. Install + the Hestia deploy run it.

## 0.4.75 - Cache-safe sign in/out for themes (2026-06-29)

Feature - [% auth_control %]
: themes get a ready-made, cache-safe Sign in/Sign out control (both links
  hidden, revealed client-side from the lzs_session cookie), fixing themes that
  showed "Sign in" while logged in by using a server-side [% IF authenticated %].

## 0.4.74 - Audit names the changed setting on plugin-save (2026-06-29)

Fix - audit detail
: a config save now records which setting changed (e.g. "lazysite (site_name)")
  instead of just the plugin name; keys only, capped for whole-form saves.

## 0.4.73 - json: page-var source (data-driven pages from JSON) (2026-06-29)

Feature - load a JSON file as TT data
: tt_page_var gains a json: source - json:/path.json decodes a docroot JSON file
  into a data structure the page body can loop ([% FOREACH %]). The documented
  [% USE JSON %] path needed an unbundled CPAN plugin; json: is the built-in way.

## 0.4.72 - Manager-aware login landing (2026-06-28)

Change - login
: a recognised manager who logs in without a specific next lands in the manager
  UI instead of the public home page (an explicit next is still honoured;
  non-managers are unaffected).

## 0.4.71 - Gate password-reset link on SMTP (2026-06-28)

Fix - login page
: the "Forgot password?" link now shows only when SMTP is configured
  (lazysite/forms/smtp.conf), since the emailed reset cannot be delivered
  otherwise.

## 0.4.70 - Metadata editor + users owner fix (2026-06-28)

Change - editor + users
: the editor front-matter box becomes a first-class, resizable "Metadata" editor
  stacked over Content (for YAML-heavy pages); adding a user now offers "Managed
  by you" so it can be owned by the manager at creation instead of top-level then
  reassign.

## 0.4.69 - Groups/Sessions pages, nested components, stats errors (2026-06-28)

Change - manager + components + stats
: Groups and Sessions move to their own pages under Access; content components
  gain nested components and includes-inside-components (and a flow-style YAML
  parser fix); the Appearance catalogue stops showing Install on installed items
  (offers Update); the stats plugin can surface recent server errors.

## 0.4.68 - Documentation sweep (2026-06-28)

Docs - bring the shipped docs current
: Appearance rename and per-layout install/delete, Visitor statistics classifier,
  and content components are now documented in the authoring guides, manager doc,
  layout-authoring guide and backlog. No code change since 0.4.67.

## 0.4.67 - Content components deployable via install_layout (2026-06-28)

Fix - install the layout components subtree
: layout-install now copies a layout components/ subtree to the site (it had
  skipped subdirectories), so fenced and sections content components reach a site
  through the catalogue. Pairs with the layouts repo bundling components/ into the
  layout zip.

## 0.4.66 - Data-driven sections (content components phase 3) (2026-06-28)

Feature - front-matter sections:
: a page can describe itself as a list of sections in front matter; the layout
  dispatches each to its component. Completes content components - authors compose
  expressive pages as Markdown plus a little structured data, with all HTML in
  layout-owned components.

## 0.4.65 - Fenced content components (2026-06-28)

Feature - author components from Markdown
: a ::: name fence whose name matches a component in the active layout is rendered
  through it - inner Markdown becomes content, key="value" become attrs, nested
  ::: slot fences become named slots. Authors write Markdown; the layout supplies
  the HTML scaffolding.

## 0.4.64 - Content components phase 1 (2026-06-28)

Feature - layout-local components + markdown filter
: the layout template engine now resolves [% INCLUDE 'components/NAME.tt' %]
  against the active layout directory and exposes a `markdown` filter, so layouts
  can frame Markdown in reusable partials. Foundation for authoring expressive
  pages as plain Markdown.

## 0.4.63 - Fix: stats nav hidden while enabled (2026-06-28)

Fix - Visitor statistics nav gate
: the conditional nav item could stay hidden even with the stats plugin enabled;
  enabled-plugin detection now resolves the plugin id from any lazysite.conf
  entry form. Locked by a layout-render regression test.

## 0.4.62 - Visitor statistics: traffic classifier + privacy (2026-06-28)

Feature - classified visitor statistics
: the stats plugin now separates real people from AI assistants, bots, probe
  noise and the logged-in operator (log-only heuristics), splits referrers into
  external/internal/direct, links top pages, hides the nav item when the plugin
  is disabled, stops exposing the log file path, and offers an operator-only raw
  log download.

## 0.4.61 - Manager UI consistency (titles, naming, audit UX) (2026-06-28)

Change - consistent manager pages
: every manager page now shows its title the same way (rendered once by the
  layout from front-matter), nav labels and page titles match (Site settings,
  Visitor statistics, Audit log, Cache, Users), and the audit failure reason
  expands on its own row with the date filter on its own line.

## 0.4.60 - Redeploy a changed layout (install update flag) (2026-06-28)

Feature - update an installed layout
: layout-install / the MCP install_layout tool accept update:true to overwrite an
  already-installed layout that has changed (snapshots the old, keeps its themes),
  so a layout fix can be pushed to a live site. A plain install still refuses to
  overwrite a differing layout.

## 0.4.59 - Layout management over API + MCP (2026-06-28)

Feature - programmatic layout management
: the per-layout install/delete/catalogue actions are now available to token and
  MCP connector clients (gated by manage_layouts), so an AI partner can browse the
  repo, install a layout + its theme(s), and remove a layout - not just the
  operator UI. New MCP tools: list_layout_catalogue, install_layout, delete_layout.

## 0.4.58 - Appearance page + per-layout install/delete (2026-06-28)

Feature - manage layouts as well as themes
: the manager Themes page becomes Appearance. Install a single layout and its
  theme(s) on demand from the layouts repo manifest; delete a layout (with its
  themes, when not active); the active layout/theme switcher moves here. Cross-
  layout theme preview now loads the right CSS. (lazysite-layouts ships the
  matching manifest.json + per-layout packaging.)

## 0.4.57 - nginx reload on deploy is now opt-in (2026-06-28)

Change - deploy no longer reloads nginx by default
: the post-upgrade nginx reload (0.4.55) is now gated behind LAZYSITE_RELOAD_NGINX=1.
  It addressed an unconfirmed open_file_cache edge case; an unconditional root-level
  reload on every deploy was unjustified. The ?v=<version> asset cache-buster is
  unaffected and still applies.

## 0.4.56 - Fix blank manager editor (auth-sync injection) (2026-06-27)

Fix - editor no longer blank
: the client-side auth-sync script is now injected before the document's real
  closing </body>, not a literal </body> inside a JS string (the editor's iframe
  srcdoc). The previous first-match splice closed the editor's own inline script
  early ("SyntaxError: literal not terminated"), so CodeMirror never mounted.

## 0.4.55 - Deploy reloads nginx for fresh static assets (2026-06-27)

Fix - nginx serves refreshed assets after upgrade
: the deploy reloads nginx after updating files, so its open_file_cache picks up the
  new manager.css / CodeMirror assets immediately (a stale cache had been serving a
  truncated stylesheet, leaving the editor unstyled). Pairs with the 0.4.54 cache-buster.

## 0.4.54 - Cache-buster on manager assets (2026-06-27)

Feature - versioned manager assets
: the manager.css and CodeMirror asset URLs carry ?v=<version>, so a release forces
  browsers and CDNs to fetch the new files instead of a stale cached copy (the cause of
  a deployed editor staying blank while the files on disk were already current).

## 0.4.53 - Manager CSS refreshes on upgrade (editor fix) (2026-06-27)

Fix - stale manager.css
: the manager stylesheet is now shipped to the web-served /manager/assets/ directly by
  the manifest (code bucket), so every upgrade refreshes it. A deployed site had been
  serving a pre-SM109 manager.css - which left the editor (and the rest of the manager)
  unstyled. The old install.pl copy-to-assets step that could go stale is removed.

## 0.4.52 - Upgrades leave the Hestia template untouched (2026-06-27)

Fix - upgrade no longer changes Hestia template state
: the per-site deploy applies the lazysite-app web template on first-time setup only
  (no install marker); an upgrade refreshes code/content/perms and leaves the domain's
  web template assignment alone, so a deliberately-changed template is not reverted.
  Force a re-apply with LAZYSITE_APPLY_TEMPLATE=1.

## 0.4.51 - Editor survives a stale manager.css (2026-06-27)

Fix - editor no longer collapses to nothing
: the critical editor layout (fixed overlay + sized panes) is now inlined in the edit
  page, so the editor stays usable even if the external manager.css copy is stale,
  missing, or unreadable - the cause of "the page ends at extra, no edit box".

## 0.4.50 - Editor always shows the edit box (2026-06-27)

Fix - editor no longer blank
: loadFile() builds the editor unconditionally and first, so the edit box always
  renders; with no file selected it shows a placeholder instead of a blank overlay.

## 0.4.49 - Editor robustness + back button; stats log auto-detect (2026-06-27)

Fix - editor always shows the edit box
: the editor builds first so a later setup hiccup cannot leave the full-screen overlay
  empty; a "<- Files" back link and Esc-to-exit make the menu reachable again.

Fix - Visitor Stats finds this site's access log
: auto-detect checks common locations but only matches a log qualified by the site's
  domain (never another site's), uses + persists it (autoconfig), or asks if none found.

## 0.4.48 - Deploy hang fix; SSI overlay support (2026-06-27)

Fix - permissions sweep no longer hangs
: the Hestia deploy pruned the regenerable compiled-template cache and batches its chmod
  pass, so a large site is set in seconds, not a multi-minute apparent hang.

Fix - lazysite-app overlays static SSI sites
: the template enables Server-Side Includes (Options +Includes + AddOutputFilter
  INCLUDES .shtml, needs a2enmod include) and serves an existing index.shtml homepage,
  so overlaying lazysite on a static SSI site no longer shows lazysite over every page.

## 0.4.47 - Audit search/targets + plugin discovery + page split (2026-06-27)

Fix - audit targets
: nav-save and plugin-enable/disable now name what they touched (nav, the plugin) instead
  of a bare /.

Feature - audit date-range search
: the Audit page gains From / To date filters.

Fix - plugins discovered dynamically
: a new plugins/*.pl (e.g. Visitor Stats) now appears in the manager without editing a
  hard-coded list.

Change - Plugin Manager vs Plugin Config
: plugin enable/disable moves to its own Plugin Manager page (/manager/plugins); the
  per-plugin settings UI is the Plugin Config page (/manager/plugin-config).

## 0.4.46 - scan: custom front-matter passthrough (SM125) (2026-06-27)

Feature - self-describing scan: cards
: scanned page objects now expose any custom front-matter key ([% t.kind %],
  [% t.accent %], [% t.demo %]) alongside the built-ins, with surrounding quotes
  stripped; sort=<custom-key> works and is numeric-aware (sort=order: 2 before 10);
  recursive ** globs are documented. Registry/gallery cards no longer smuggle data
  through tags and filenames.

## 0.4.45 - Auth audit completeness + self-service/OAuth docs (2026-06-27)

Verified - self-service credentials / TOTP MFA (SM072) and OAuth 2.1 (SM076)
: both confirmed fully built, tested, and audited; stale doc statuses corrected.

Fix - audit names the plugin
: plugin-enable/disable/save now record WHICH plugin (was '/'); /forgot records a
  `forgot` event when a reset link is emailed.

Docs - self-service credentials and two-factor
: starter/docs/auth.md documents setup links, reset, forgot-password, TOTP, and expiry.

## 0.4.44 - Operator notifications (SM113) (2026-06-27)

Feature - operator notifications (SM113)
: the manager header gains a notification bell with an unread badge and a dropdown.
  A small append-only store (logs/notices.jsonl) plus a per-operator last-seen marker
  backs it; the form-handler is the first producer (a new submission raises a notice).
  Poll-based for v1; a plugin-facing API and SSE push are noted for later.

## 0.4.43 - Path-aware MCP gating; nav URL autocomplete (2026-06-27)

Feature - finer connector capability by path (SM082)
: the MCP file tools are path-aware like WebDAV - a theme/layout path is authorised by
  manage_themes/manage_layouts, content by manage_content - so a theme-only partner can
  edit theme files but not content pages.

Feature - nav URL autocomplete (SM097)
: the navigation editor suggests the site's existing page URLs (a new pages action +
  a datalist); free text stays allowed for external links and anchors.

## 0.4.42 - Visitor-stats plugin + dashboard (SM083) (2026-06-27)

Feature - visitor statistics from the access log (SM083)
: a read-only, opt-in plugin (Visitor Stats) parses the web server access log into
  on-site analytics - hits, unique visitors, top pages, referrers, status codes and
  per-day counts over a configurable window, with bot filtering and IP anonymisation.
  A new manager Stats page renders the dashboard (tiles, a per-day bar chart, top
  tables). It complements the audit trail, which records material actions only.

## 0.4.41 - WebDAV route health check (SM121) (2026-06-27)

Feature - WebDAV /dav/ health check
: `lazysite-check --check-dav URL` probes `URL/dav/` unauthenticated and reports OK
  (401 - routed), FAIL (404 - the web server/proxy is not forwarding /dav/ to Apache;
  a route/provisioning problem, not auth), or WARN. The 404-vs-401 distinction is the
  fast way to tell a missing route from an auth/scope issue. The Hestia runbook
  documents the requirement and the fix.

## 0.4.40 - Per-page theme override; config + theme self-service; brief CLI (2026-06-27)

Feature - per-page theme: override (SM120)
: a page can pin a theme in front matter (`theme:`), preview-only and sanitised like
  `layout:`, falling back to the active theme. A theme explorer or single-page theme
  preview is now a one-line change, not a bespoke layout.

Feature - config self-service for tokens (SM122)
: a `config-read` action lets a manage_config token read a safe subset (layout, theme,
  webdav_enabled, ...) to self-diagnose, and `config-set` accepts an injection-checked
  safe subset (webdav_enabled, layout, theme, nav_file).

Feature - theme discovery (SM123)
: token clients can list installed themes/layouts, and a new MCP `list_themes` tool
  returns the themes installed across all layouts - no more activating each to discover.

Feature - brief CLI + access-plane note (SM124)
: `lazysite-users.pl brief USERNAME` prints the agent onboarding brief, and the brief
  now states that token capabilities are independent of manager-group/operator status.

## 0.4.39 - Audit filter dropdowns; read-only data files (2026-06-27)

Feature - audit filters are value dropdowns (SM119)
: the Audit page User and Target filters are dropdowns of the values actually present
  in the log (with "(all)" and a "(none)" option for blank-valued entries), instead of
  free text.

Feature - the editor opens append-only data read-only (SM115)
: form submissions and .jsonl files open read-only by default with an explicit "Edit
  anyway", so editing the whole file cannot clobber records appended concurrently
  (over and above the existing mtime conflict guard).

## 0.4.38 - Form-build flow, client-side auth control, submission + denied audit (2026-06-27)

Feature - agents can build a form natively (SM108)
: the bind_form tool description now spells out the full flow (front-matter form: NAME
  + a :::form block with field rules, then list_form_handlers, then bind_form) with an
  inline example, and the brief lists /docs/forms.

Feature - client-side sign-in/out control (SM099)
: the site auth control is now resolved client-side from a non-HttpOnly lzs_session
  marker cookie, so a shared cached page never shows the wrong state. Any layout opts
  in with data-ls-auth-in / data-ls-auth-out.

Feature - form submissions are audited (SM115)
: a submission writes a `submit` audit event (origin form, user blank for the public).
  Concurrent-edit loss is already prevented by the editor mtime guard.

Fix - capability-denied attempts are audited
: a denied MCP tool / control-API action now writes a `fail` audit event before
  refusing (it was silent before - why blocked theme activity seemed unlogged).

Change - settings form flags unsaved changes (SM118)
: the Config form shows a reminder and warns on leaving while dirty, cleared on save.

## 0.4.37 - Fix hidden capability toggles for operators; audit deploys; settings groups (2026-06-27)

Fix - capability toggles are shown for operator accounts (SM094)
: hiding the per-account capability toggles for manager-group (operator) accounts was
  wrong - operator status only bypasses the cookie/UI path, so an operator account
  that also connects with a token is still gated by these flags on the WebDAV /
  control-API / MCP path. They are now always settable (with a note that they govern
  the token/connector path), so a manager-group connector can be granted
  manage_themes/manage_layouts.

Feature - deploys are audited (SM117)
: install.pl records an `installed` / `upgraded` (from -> to) event in the audit trail.

Feature - a delete button on the file expand card; settings groups (SM114)
: the per-file card gains a Delete button (single-file delete with confirm); site
  settings are grouped under Identity / Appearance / Content / Access headers, and the
  Files breadcrumb root is the same folder icon as the editor.

## 0.4.36 - WCAG contrast pass; setup-manager URL; README first-run (2026-06-27)

Fix - colour contrast brought to WCAG (light and dark)
: audited the main text tokens against WCAG and fixed the one real failure -
  `--mg-text-light` was 2.5:1 in light / ~3:1 in dark (the "feint, hard to read"
  text); now 4.7:1 / 5.0:1 (AA). The dark editor syntax palette is brighter - every
  token clears AAA except the dimmed comment/markers (AA). A standard is documented in
  docs/reference/manager-colour-contrast.md.

Fix - setup-manager prints a usable URL
: it showed the literal `${REQUEST_SCHEME}://${SERVER_NAME}` on the CLI (those resolve
  only in the CGI env); now expanded where possible, else a relative `/manager/`.

Docs - README first-run section
: go to `/manager` directly (some hosts seed an index.html that shadows the homepage),
  and get the first password with `setup-manager`.

## 0.4.35 - Dark editor palette; manager-groups picker (2026-06-27)

Feature - readable dark editor colours (SM116)
: the CodeMirror Markdown/YAML editor gets a dark colour scheme - headings in a light
  green (were a vivid blue, unreadable on dark), bright bold, accent links, and
  softened red/orange tokens. Light mode keeps the bundled theme.

Feature - Manager access groups is a picker (SM114)
: the field is now checkboxes of existing groups (a hidden input carries the
  comma-separated value the backend expects) rather than free text, with a
  "create one on Users" note when none exist.

Change - sorting a file column keeps your page
: clicking a column header re-sorts in place and stays on the current page instead of
  jumping back to page 1.

## 0.4.34 - Files sortable+paginated; generator meta; config toggles; dark polish (2026-06-27)

Feature - file manager sortable columns + pagination (SM111)
: Name / Access / Modified headers sort on click (with a direction indicator), and
  directories with many entries paginate at 50 per page. Filter, sort and paging now
  compose (the list is rendered data-driven instead of hiding DOM rows).

Feature - generator meta on generated pages (SM112)
: every rendered page gets `<meta name="generator" content="lazysite X.Y.Z">` (plus
  author/description from front matter when present), injected into the head so it
  works with any layout. Opt out with `meta_generator: false`.

Change - config booleans are switches; disabling the manager warns (SM114)
: Manager / WebDAV publishing / searchable-by-default render as switches rather than
  dropdowns, and saving with the manager set to disabled now confirms first. The
  editor breadcrumb root is a files icon instead of "/".

Fix - dark-mode polish
: brighter text in dark mode for contrast, and a baseline so every form control
  (including unstyled ones like the theme browse) inverts with the theme.

## 0.4.33 - Dark-mode contrast fixes; plugin toggle safety (2026-06-27)

Fix - dark-mode readability (live review of 0.4.32)
: most "doesn't invert" reports traced to page styles using `var(--mg-bg-alt, #f6f6f6)`
  with no such token defined - aliasing the legacy names to real tokens repairs the
  Users instruction pane, Backups panel, file-row expand box, onboarding cards and
  chips in dark mode. Links are now tokenised (were browser blue/purple, unreadable on
  dark, esp. visited); sidebar group titles are stronger than their items; ghost
  buttons (download / add brief) are no longer feint; r/w flags are bolder; chips,
  badge/editor greens, the footer and the code box are tokenised; and the CodeMirror
  editors ("extra" + content) get a dark variant.

Fix - plugins toggle no longer flips by accident
: the plugin row was a `<label>`, so a click anywhere toggled enable/disable. It is
  now a `<div>` - only the switch toggles.

## 0.4.32 - Manager UI: side-nav, command palette, dark mode (SM109 phases 4-6) (2026-06-26)

Feature - grouped left sidebar
: the nine-item top nav becomes a grouped left sidebar (Content / Access / System) in
  a flex shell; the header keeps the brand + tools and gains a palette trigger. The
  active link is tinted with the accent; the sidebar wraps on narrow screens.

Feature - command palette
: Ctrl/Cmd-K opens a palette to jump to any manager page or run a command (view site,
  toggle dark mode, sign out) - type to filter, arrow keys + Enter, Escape to close.

Feature - dark mode
: a `[data-theme="dark"]` token block reskins the whole manager (every component
  inherits the reassigned vars). A header toggle flips and persists the choice; the
  theme is set before first paint from the saved choice or the OS preference, so no
  flash. Completes the SM109 manager-UI modernization.

## 0.4.31 - Manager UI: no more native dialogs (SM109 phase 2b) (2026-06-26)

Feature - the remaining native dialogs become the styled modal
: the last 17 `confirm()` / `prompt()` / `alert()` call sites across files, nav,
  themes, plugins, cache and edit now use the promise-based `mgConfirm` / `mgPrompt`
  modal (with danger styling on destructive actions). No browser-native dialog
  remains anywhere in the manager - rename, delete, activate, upload-overwrite, clear
  cache and take-over-lock are all styled and consistent.

## 0.4.30 - Manager UI: shared style system (SM109 phase 3) (2026-06-26)

Feature - per-page styles consolidated onto the shared system
: the manager pages reinvented components in inline `<style>` blocks; these are now
  in manager.css, token-driven and de-duplicated. users.md's ~57-line component
  block (.mg-acc / .mg-box / .mg-line / .mg-tag / .mg-chk / .mg-inp / .mg-cred-*),
  audit.md's .audit-table, and config.md's .mg-plugin-row are shared. Hard-coded
  colours (#c33 / #666 / #eee / #e5e5e5) are gone, and the token bug Phase 1 exposed
  (white surfaces used --mg-bg, now #fafafa) is fixed to --mg-surface. edit.md, which
  reuses these classes, now picks up the consistent styling for free.

## 0.4.29 - Manager UI: switches, toasts, modal dialogs (SM109 phase 2a) (2026-06-26)

Feature - toggle switches
: capability and plugin on/off toggles render as switches instead of bare checkboxes
  (pure CSS), so state reads at a glance - the Claude/ChatGPT settings idiom.

Feature - toast notifications
: a global toast replaces the warning bar and per-page status line; `mgShowWarning`
  and the pages' `showStatus` route to it, so feedback is consistent with no
  call-site churn.

Feature - styled confirm/prompt modal
: a promise-based `mgConfirm` / `mgPrompt` modal replaces the browser-native
  `confirm()` / `prompt()` (the strongest "unpolished" tell). All six Users-page
  dialogs use it, with danger styling on destructive actions. The remaining pages'
  dialogs (files/nav/themes/plugins/cache/edit) convert in phase 2b.

## 0.4.28 - Manager UI reskin, phase 1 (2026-06-26)

Feature - manager UI visual refresh (SM109 phase 1)
: a stylesheet-only reskin of the manager (no app-logic change). A new token set in
  manager.css - warmer neutral surfaces, a single indigo accent off the Bootstrap
  blue, desaturated status colours, softer radii, a real elevation scale, a focus
  ring, and a disciplined 15px type scale - reskins every page at once because they
  all consume the `--mg-*` variables. Cards gain soft elevation; primary buttons are
  now solid and applied one-per-view (Add user / Add group / Config Save). Phases
  2+ (switches, toasts, confirm modals, side-nav, dark mode) are tracked in SM109.

## 0.4.27 - Nav for token partners; feedback endpoint; do-not-retry (2026-06-26)

Fix - WebDAV/control-API partners can manage the navigation
: `nav-read` / `nav-save` are now token-client control-API actions gated by
  `manage_nav` (which inherits `manage_content` then `webdav`). Capabilities are read
  live per request, so a grant applies immediately - no new pairing key. The
  control-API `whoami` now also reports the effective content/nav/forms grants, and
  the agent brief gained a "Managing the navigation" section (use nav-save, not a
  WebDAV PUT to `lazysite/`, not MCP) with a stale claim removed.

Feature - agent feedback endpoint (SM102)
: a `submit_feedback` MCP tool writes an identity-stamped report (user/method/ip/
  site/version/capabilities stamped server-side; agent supplies summary/good/bad/
  rating/context) to `lazysite/feedback/`, audited as `feedback`.

Feature - permanent tool failures tell the agent not to retry (SM101)
: MCP tool errors carry `retryable: false` for permanent kinds (permission, blocked,
  bad path, exists, ...) with an imperative hint; only transient kinds are retryable.

Fix - doctor no longer flags www-data runtime files
: locks / cache / generated html / audit.log are legitimately owned by the www-data
  CGI; only a truly foreign owner (root, another user) is now a fault.

## 0.4.26 - Fix AI-account Credentials; nav/forms capabilities; editable parent (2026-06-26)

Fix - AI account no longer shows "Credentials: undefined" (regression from 0.4.25)
: the Credentials section was emitted outside its `if (ui)` guard, so an AI/backend
  account rendered an undefined section. It is now shown only for human accounts.

Feature - navigation and forms are their own capabilities (SM105/SM106)
: `manage_nav` gates nav editing and `manage_forms` gates form binding, each
  inheriting from `manage_content` (which inherits the WebDAV grant) unless set
  explicitly - so existing content editors keep nav/forms, and either can be granted
  on its own (e.g. a navigation/chrome editor without page-content write). Both appear
  as toggles in Publishing access.

Feature - the account hierarchy is editable (SM104)
: the Parent/Move control is shown for every account, so a top-level account can be
  placed under another (it sets managed_by); a sub-user heading shows whose account it
  is under.

## 0.4.25 - One Connect flow; sub-user count badge (2026-06-26)

Feature - one "Connect an AI assistant" flow per account (SM100)
: the three parallel connector-credential controls (standalone Token, Connect an AI
  assistant, Generate agent brief) are replaced by a single Connect section - pick the
  client (Claude.ai/ChatGPT web, Claude Desktop, or Claude Code/script) and get the one
  credential that works, with the reason shown inline. No more choosing the wrong one.
  The Credentials section is now interactive-login only (password / setup link / 2FA),
  for human accounts.

Change - sub-user count in the heading
: a parent account shows "(+N)" when it has sub-users. The Add-user parent default is
  reworded to "(top-level account - no parent; managed by you)".

## 0.4.24 - Users-page UX; fleet health summary (2026-06-26)

Feature - Users page reads as the hierarchy and roles it is
: sub-users nest under their parent account (collapse with it); capability toggles
  are hidden for manager-group (operator) accounts - overridden by the role - and the
  capability section is relabelled "Publishing access (WebDAV / control API / AI
  connector)"; interactive-login credentials (password / setup link / 2FA) are hidden
  for AI/backend accounts, leaving the token they actually use; the Add-group first
  member is a dropdown of existing accounts.

Feature - fleet updater health summary
: `lazysite-hestia-update-all.sh` prints a consolidated list of the doctor's warnings
  and failures grouped by site at the end of a run, so outstanding items are visible
  in one place instead of buried in each site's block.

Change - agent brief steers off a co-discovered MCP
: the WebDAV/API onboarding brief now tells an implementation agent to use only that
  path and not a separately-detected MCP connector for the same account (a real
  Claude Code confusion).

## 0.4.23 - Audit static-bearer connect; deploy chowns all install targets (2026-06-26)

Feature - audit a connector connecting with a static bearer
: Claude Code / Desktop / scripts authenticate with the static `lzs_` bearer, whose
  verify path audited nothing - so an active connector showed its writes but never
  its connection. The MCP now audits a `connect` (origin mcp) on the FIRST use of a
  credential since issuance, recording the connection once without flooding.

Fix - deploy normalises ownership of every install target
: the deploy chowned the docroot + cgi-bin but not the sibling `lib/` `plugins/`
  `tools/` trees install.pl also writes, so a site whose `lib/` was left root-owned
  still failed the upgrade ("Failed to copy lib/Lazysite/Audit.pm: Permission
  denied"). It now chowns all install targets first.

## 0.4.22 - Audit the connector lifecycle; audit.log writability (2026-06-26)

Feature - full OAuth/connector lifecycle in the audit trail
: previously only the access-token issue was audited. Now a Claude.ai / ChatGPT
  connector's whole connection shows: `oauth-register` (client registered),
  `oauth-authorize` (connect code redeemed / consent, incl. the failed case),
  `connect` (token issued), and `oauth-refresh` (token renewed - the "still active"
  beat). Tool *writes* were already audited; *reads* remain unaudited by design.

Fix - doctor checks audit.log is writable
: a `lazysite/logs/audit.log` that is not group-writable by the www-data CGI makes
  every audit append silently fail - so *nothing* appears in the audit log. This is
  the real cause behind "the connector/login isn't audited" on a site whose
  permissions were not fully applied. `lazysite-check` now flags it and `--fix`
  repairs it.

## 0.4.21 - Audit logins; .url editable; doctor checks writable config (2026-06-26)

Feature - login/logout recorded in the audit trail
: the auth wrapper now writes audit events for every material authentication action -
  login success and login failure (with a reason: invalid-credentials, rate-limited,
  account-disabled, credential-expired, account-expired, ui-disabled, mfa,
  no-password-remote), logout, claim-redeem, and token exchange/rotate. Previously
  these went only to the application log, so a login did not appear in the manager
  Audit viewer.

Fix - .url files are editable
: `.url` files (a single remote-content URL) were treated as binary and the manager
  editor refused them. They now open as text.

Fix - doctor flags config files the CGI cannot write
: `lazysite-check` now checks that the files the manager overwrites in place -
  `nav.conf`, `lazysite.conf`, `auth/users`, `auth/groups`, `auth/acls.json` - are
  group-writable by the www-data CGI (the cause of "nav cannot be written" /
  "lazysite.conf required chmod g+w" after a deploy whose permission pass did not
  run). `--fix` adds group-write.

Change - groups "first member" is a dropdown
: the Add-group first-member field is now a dropdown of existing accounts.

## 0.4.20 - Deploy ownership + secret-perm hardening (2026-06-26)

Fix - deploy normalises ownership when run as root (SM093)
: the Hestia deploy ran `install.pl` as the domain user, which failed with
  "Permission denied" if the docroot/cgi-bin had been left owned by root (from an
  earlier `install.pl` run directly as root) - the upgrade aborted. The deploy now
  chowns the docroot + cgi-bin to `<user>:www-data` **before** running install.pl,
  so the user-run install can always overwrite.

Fix - secrets are no longer world-readable after deploy (SM093)
: the deploy's blanket `chmod 664` left `auth/.secret`, `forms/.secret`,
  `oauth.json` and `user-settings.json` world-readable. It now tightens those to
  `660`, and the final verify step runs `lazysite-check --fix` (as root) to
  auto-repair anything still off.

Fix - lazysite-check flags secrets the CGI cannot read (SM093)
: a secret that is not world-accessible but is also not readable by the www-data
  CGI (e.g. `0600` owned by a non-www-data user) is now a FAIL - that is the exact
  cause of an "End of script output before headers" 500 once a session cookie is
  present. The doctor also defaults the expected group to `www-data` (not the
  docroot's group), so `--fix` can never strip the CGI's group access.

## 0.4.19 - Install/permissions doctor (2026-06-26)

Feature - install/permissions doctor (SM093)
: `lazysite-check.pl --docroot DOC` verifies an install is healthy: nothing under
  `lazysite/` is foreign-owned (the root-owned-tree trap that breaks the www-data
  CGI), the dirs the CGI must write (cache/logs/locks/auth/forms/assets) are
  group-writable + setgid, secrets are not world-accessible, the cgi-bin scripts
  and config are present, and the manager is bootstrapped. Reports OK/WARN/FAIL
  per check with a remediation hint and a non-zero exit on failure; `--fix` applies
  the chmod (and, as root, chown) repairs. The Hestia deploy runs it as a final
  verification step.

## 0.4.18 - One-command manager bootstrap (2026-06-26)

Feature - one-command manager bootstrap (SM093)
: `lazysite-users.pl setup-manager [PASSWORD]` does the whole first-run manager
  setup in one idempotent command: create the `manager` account, set (or generate
  and print) its password, create the admin group with the user in it, and ensure
  `manager: enabled` + `manager_groups` in `lazysite.conf`. The Hestia deploy
  (`lazysite-hestia-deploy.sh`) now runs it automatically on a fresh install, so a
  brand-new site is manager-ready from the single deploy command - no follow-up
  password/group/conf steps.

Fix - dev server cleans up on Ctrl-C / kill (SM091)
: the dev server now traps SIGINT/SIGTERM and exits cleanly so its END block runs,
  removing the temporary browse cache (`/tmp/lazysite-browse-<pid>`) and the error
  file. Previously a signal terminated the process without running END, leaving the
  cache directory behind.

## 0.4.17 - Dev-server auto-index: browse any tree (2026-06-26)

Feature - dev-server auto-index, browse any tree (SM091)
: `tools/lazysite-server.pl --docroot <tree> --auto-index` turns the dev server
  into a zero-install Markdown browser for any folder (no cache, no theme, no index
  files): it generates a directory index (sub-folders and pages as links, labels
  from front-matter `title`, `README` linked as overview) for any directory lacking
  an `index.md`, and injects a breadcrumb nav into every rendered page. It writes
  nothing into the tree - seeding is suppressed and the processor's compile/layout
  cache is relocated off the docroot. Documented in the README quick-start, the
  dev-server doc, and `--help`.

Change - no scaffolding seeded into a non-lazysite docroot
: the dev server now only seeds auth/forms/conf scaffolding into a real lazysite
  docroot (one with a `lazysite/` dir or `lazysite.conf.example`); pointed at an
  arbitrary tree it leaves it untouched. New `--no-seed` forces seeding off
  anywhere. New processor env `LAZYSITE_CACHE_DIR` relocates the cache base
  (inert unless set, so production and tests are unchanged).

Security - production never lists a directory (unchanged, now tested)
: auto-index is dev-server-only and off by default. The full-install request path
  still never reveals a file list - the processor returns 404 for a directory with
  no `index.md`, and the Apache config ships `Options -Indexes`. Locked by
  `t/unit/processor/23-no-directory-listing.t` (404 + no filename leak) so it
  cannot regress.

## 0.4.16 - UTF-8 corruption fully fixed + set_nav (2026-06-25)

Fix - non-ASCII corruption through the connector (the real root cause)
: 0.4.15 fixed one encoding layer (`send_json`); a second remained. A tool result
  puts `$out` in both `structuredContent` (fine) and
  `content[0].text => encode_json($out)` - and that inner `encode_json` emits
  UTF-8 bytes which the outer `encode_json` re-encoded, double-encoding non-ASCII
  in the text part the client reads. Now the inner JSON is decoded so the outer
  layer encodes once. The page-walk / search / preview / nav helpers also read
  `:utf8`, and STDIN is binmoded raw so `decode_json` owns the decode. So `±`,
  `£`, `é`, en-dashes and curly quotes round-trip cleanly (verified on file bytes
  + the raw response, not just a round-trip that would cancel the error).

Feature - read_nav / set_nav (completes the SM087 page API)
: `read_nav` returns the navigation as a structured list (items + children) plus
  raw nav.conf; `set_nav { items }` replaces it from an ordered
  `{ label, url[, children] }` list, written via `action_save` so it audits and
  rebuilds the cache.

## 0.4.15 - UTF-8 fix, page-aware verbs, MCP docs (2026-06-25)

Fix - non-ASCII corruption in JSON responses (important)
: `send_json` (MCP), `respond` (control API), `respond_json` (OAuth) and the
  manager-api error/preview responders printed `encode_json`'s already-UTF-8
  output under a `:utf8` STDOUT layer, re-encoding it - so non-ASCII (`±`, `£`,
  `é`, en-dashes, curly quotes) came back as mojibake on read / preview. The write
  path was correct; the read response was corrupting. They now print the bytes
  raw; HTML/XML responders correctly keep `:utf8`. Found by the live Claude.ai
  review.

Fix - front-matter quotes kept as content
: `title: "Welcome"` yielded a literal `"Welcome"` (which a template then
  double-quoted - the doubled review quotes). The front-matter parser now strips
  one matched pair of surrounding quotes (YAML semantics).

Feature - page-aware verbs (SM087)
: `create_page` (front-matter fields + body; errors if it exists), `delete_page`
  (removes the page + its `.brief`, reports remaining references), and
  `rename_page` (carries `.brief` + ACL; `update_links` rewrites internal links
  across pages). `write_file` now validates on write, returning warnings/issues.

Change - audit error reason is a popup
: The fail reason is a click-to-reveal popup on the (i) rather than always inline.

Docs - full MCP connector tools reference at `/docs/ai-connector-tools` (endpoint,
  auth, capability/ACL model, all tools, error kinds, edit loop).

## 0.4.14 - Multi-word select options + lock take-over (2026-06-25)

Fix - multi-word `select:` form options
: `select:` options containing spaces were truncated at the first space, and
  quoting didn't help (neither the renderer nor the validator honoured it). The
  rule parser now treats `select:` as taking the rest of the rule line, so
  `select:No,Yes - one small dog` renders both options whole, no quotes needed
  (quotes are still tolerated). The validator drops the `select:` clause before
  checking, so it no longer flags option words. Put `select:` last among a
  field's rules.

Feature - take over a stale editor lock
: A file shown as "Locked by …" in the editor now offers a Take over button that
  clears the (non-WebDAV) lock and re-acquires it - so a lock orphaned by an
  editor left open across a restart no longer means waiting out the 5-minute TTL.

Change - file size in the Files list
: The Modified column now shows the file size after the date.

## 0.4.13 - Fenced-div Markdown fix + connector review follow-ups (2026-06-25)

Fix - block Markdown inside ::: boxes
: A heading or list inside a `:::` fenced div leaked literal Markdown (`## Heading`)
  because Text::MultiMarkdown treats `<div>` content as verbatim. The box body is
  now rendered (block + inline); a top-level `<style>` block is also no longer
  paragraph-wrapped. Found via the live Claude.ai connector review.

Feature - auth lifetime in whoami
: `whoami` returns an `auth` block - `{ method: oauth|bearer, expires_at }` - so an
  agent sees how its session is authenticated and when it lapses. For OAuth this is
  the access-token expiry (previously opaque; `token_expires_at` only reflected the
  static credential).

Change - audit target links to the editor
: A file target in the audit log opens in the manager editor (covers `.md`,
  `.conf`, `.brief` and other editable files), not only public pages.

Docs - new feature-request candidates filed: SM089 (3D-rendered layout) and SM090
  (social syndication / POSSE).

## 0.4.12 - Connector polish, in-channel preview, form binding (2026-06-25)

Feature - more connector tools (from live Claude.ai / ChatGPT use)
: `preview_page` renders a page server-side (fresh, no-cache) and returns its
  HTML, so an agent can verify layout/nav/form output without a public fetch.
  `whoami` now echoes the full `tools` manifest (one-call discovery).
  `copy_file` templates a new page from an existing one; `get_permissions` reads
  a path's ACL before changing it. `list_form_handlers` + `bind_form` (SM088)
  let an agent wire a form to an operator-vetted delivery handler without ever
  seeing a destination or credential.

Fix - clearer connector errors + cache correctness
: A `401` now distinguishes *sign-in incomplete* from *credential invalid/expired*
  (with `error.data.reason`). Error responses carry a machine-readable `kind`.
  A `nav.conf` save clears all page caches (nav shows on every page) and flags
  `cache_rebuilt`.

Feature - audit log usability
: Failure reasons are recorded and shown (ⓘ tooltip + inline note); the page
  gains a Target filter and a Refresh button; clicking a user opens the Users
  page with that account expanded, and a page target opens the rendered page.

Change - Generate credential clarified
: The affordance now states it is for Claude Code / Desktop / scripts (static
  bearer), not Claude.ai / ChatGPT web (OAuth-only - use Connect an AI assistant),
  and that the account needs the relevant capability.

## 0.4.11 - Form field types + connector editing tools (SM087) (2026-06-25)

Feature - more form field types
: The form syntax gains `tel` (with a default validation pattern), `date`, `time`,
  `number` (with `min:`/`max:` value bounds), `url`, and `password`, plus
  `pattern:REGEX` for custom validation and a `placeholder:` rule. Values that
  need spaces are quoted: `placeholder:"Your full name"`.

Feature - safer, higher-level connector tools (from live ChatGPT use)
: New MCP tools make AI-driven editing safer and page-aware:
  `replace_text` (patch a file by exact text instead of rewriting it - errors if
  the text is absent), `search_files` (content grep), `page_status` (is an edit
  rendered/live + public URL), `read_page` / `list_pages` (page-level view with
  parsed front matter), `validate_page` (front-matter / form-rule checks + a
  **public-data warning** for Wi-Fi passwords / addresses / phone numbers), and
  `audit_site` (broken links, orphans, missing titles, stale HTML, duplicate
  content blocks). Error responses now carry a machine-readable `kind`.

Fix - generated indexes refresh on change
: A content delete/save/move now refreshes the generated `sitemap.xml`,
  `llms.txt` and feeds, so a deleted page no longer lingers in them (they
  previously only refreshed on a 4-hour TTL).

Change - audit log pagination
: The audit page shows 50 material events per page with Prev/Next; the reader
  takes `page`/`per_page`.

## 0.4.10 - Overlay onto an existing site + content backups (SM084) (2026-06-25)

Fix - non-destructive install (overlay onto a live HTML/SSI site)
: lazysite can now be installed over an existing static site without losing the
  homepage. The installer deletes `index.html` ONLY when `index.md` already
  existed (so it was the cache rendered from it); a freshly-seeded `index.md` or
  a static-site overlay leaves an existing `index.html` untouched, and `deploy.sh`
  no longer deletes it. Existing `.html`/`.shtml`/SSI pages keep serving until a
  `.md` replaces them - migrate page by page.

Feature - docroot content backups
: Tarball snapshots of the site content (excluding the `lazysite/` infra, so no
  secrets) under `lazysite/backups/`, which is never served. A one-time
  pre-install snapshot is taken the first time lazysite is installed over existing
  content, so a migration is always recoverable. A new manager **Backups** page
  lists snapshots, takes manual ones on demand, and downloads them (manager-only;
  strict name validation on download).

## 0.4.9 - Material audit trail + connector robustness (2026-06-25)

Change - the audit trail records MATERIAL events only
: It was behaving like an access log. Now it records state changes and security
  grants - not browsing - so it does not overlap the web server access log (whose
  analytics belong in a future stats plugin, SM083). WebDAV reads are no longer
  audited; the control API audits only material POSTs (user management is logged
  as `user-add` / `user-settings-set` / ... with the target username, its reads
  skipped); and an OAuth token issue records a `connect` event - the "X connected"
  signal that a read-only connector session was missing. File writes now read as
  the actual event: **create** / **edit** / **delete** / **move** / **mkdir**
  across the control API, MCP tools and WebDAV.

Feature - invalidate_cache MCP tool
: A normal write already drops the saved page's HTML cache, but the AI can now
  force a re-render (a page, or `"*"` for all) - useful for pages that embed
  another.

Fix - connector reliability with slower assistants (ChatGPT)
: The task prompt now tells the assistant to confirm a write with `read_file`
  through the connector and NOT to fetch the rendered page (a separate slow
  request that could stall - the apparent "hang after the first edit"). `read_file`
  also refuses a file over 512 KB rather than returning a slow/oversized reply
  that could trip a client timeout.

Change - manager UI polish
: The open file rights-editor is bracketed top and bottom by an accent rule with
  the expander turning accent-blue while open; the `@group` indicator sits beside
  the owner; and the Users page explains the two access domains (file management
  vs site access) that share one account set.

## 0.4.8 - Multi-client AI connector, processor fix, theme-only partners (2026-06-25)

Feature - the AI connector is client-neutral (SM076)
: Validated live on both Claude.ai and ChatGPT (developer mode), the OAuth + MCP
  server now serves any MCP client on one implementation. Every tool declares the
  `readOnlyHint`/`destructiveHint`/`openWorldHint` annotations + an output schema
  (ChatGPT's requirement). The Users-page button is "Connect an AI assistant"
  (was "Set up Claude.ai") with a styled Step-1 card (URL + connect code, a
  per-app pointer, expiry path), and a new operator guide at
  `/docs/ai-connector-setup` covers Claude.ai, ChatGPT, and the static-bearer
  path for Desktop/Code/scripts.

Fix - processor paragraph-wrapped block HTML
: `Text::MultiMarkdown` wrapped top-level block HTML (e.g. a hero `<section>`)
  into invalid `<p><section>...</section></p>` - found by an AI partner reviewing
  a live site. `convert_md` now unwraps the spurious `<p>`/`</p>` around
  block-level elements; ordinary paragraphs are untouched.

Feature - content vs theme capability (SM082)
: A new `manage_content` capability governs the content namespace, defaulting to
  the `webdav` grant when unset (existing partners unchanged). Turning it off
  (a new Users-page toggle) makes a theme-only partner: content reads/writes
  refused while theme/layout work still functions - enforced in both the MCP
  tools and raw WebDAV.

## 0.4.7 - OAuth for Claude.ai web connectors (SM076) (2026-06-24)

Feature - OAuth 2.1 authorization server for the MCP connector
: Claude.ai **web** custom connectors are OAuth-only (no static bearer field), so
  the MCP server now speaks OAuth. New `lazysite-oauth.pl` + `Lazysite::Auth::OAuth`
  implement discovery (RFC 9728/8414), dynamic client registration (RFC 7591),
  an authorize endpoint (a consent page taking the operator's single-use
  **connect code**, PKCE S256), and a token endpoint (authorization_code +
  refresh). The MCP server challenges an unauthenticated tool call with
  `401 WWW-Authenticate` and accepts either the opaque OAuth access token (web)
  or the existing `partner:lzs_` static bearer (Claude Code / Desktop). Access
  tokens map to the partner's grant - identical capability + ACL enforcement.

Feature - two-step "Set up Claude.ai"
: The Users-page connector setup is a guided two-step flow: add the connector by
  URL + enter a connect code, then - once the manager detects the connection has
  authenticated - it reveals the no-secret task prompt. The connector is named by
  the site domain; the assistant prompt steers Claude to the native connector
  tools (not raw HTTP).

## 0.4.6 - Claude.ai connector onboarding + injection-resistant briefs (2026-06-24)

Feature - one-click Claude.ai connector setup (SM076)
: The Users page now offers two onboarding paths matched to the audience.
  **Set up Claude.ai** (new) mints a credential for the MCP connector's settings
  (never chat) and steps the operator through adding the connector, confirming
  with `whoami`, and a no-secret task prompt - the robust path for the web app /
  ongoing tweaks. **Generate agent brief** is the existing pairing-key + API/
  WebDAV flow for Claude Code or a script (key delivered out of band).

Security - injection-resistant onboarding briefs
: After a Claude.ai partner correctly declined a brief that embedded a secret,
  asked an assistant to autonomously handle credentials, and read like a prompt
  injection: the generated brief is reframed as operator-issued data to *verify*
  (against `/.well-known/ai-partner`), not commands to obey, and carries explicit
  secret-handling guidance (out-of-band delivery to a supervised agent; connector
  settings for a chat assistant; a key seen in a transcript is spent). The Users
  panel warns the same, and gained a Close button + a "supersedes the previous
  key" note.

Docs - partner onboarding
: A "First: confirm you can reach the site" egress preflight (detect a blocked
  egress / wildcard-depth / stale sandbox and report early rather than retry),
  and an operator onboarding-brief template documenting who-runs-which-part.

## 0.4.5 - Fix Users/Groups page layout regression (2026-06-24)

Fix - Users/Groups management page was scrambled
: The SM077 file Access badges (0.4.2) added a `.mg-acc` CSS rule that collided
  with the Users/Groups accordion `<details class="mg-acc">`, collapsing every
  row into a 1.1em inline box (rows overlapping). The file access flags are
  renamed to `mg-rwflag*`, so the accordion returns to its normal layout.

## 0.4.4 - Audit WebDAV reads; document MCP + per-client connection modes (2026-06-24)

Feature - audit WebDAV reads; document MCP vs API onboarding modes
: WebDAV reads (GET/PROPFIND) are now recorded in the audit trail too (origin
  dav), so a partner's authenticated browse/read activity is visible - not only
  writes. Default-on; a busy site can quiet it with `audit_reads: false` in
  `lazysite.conf`. The partner onboarding (`ai-briefing-publishing` +
  `.well-known/ai-partner`) now documents both connection modes - API
  (WebDAV + control API) and MCP (the `lazysite-mcp.pl` connector) - so a
  partner can pick the best for its capabilities.

## 0.4.3 - Complete audit trail, @group over WebDAV, Files rights editor (2026-06-24)

Feature - Files config card: unified rights editor (SM077)
: The card's two native multi-selects are replaced by one "People & groups with
  access" list - each principal is a chip with r / w toggles and a remove
  control, added via a typeahead; read[]/write[] are derived on save. The audit
  "History" link moves into the card (off the Modified date), and the card is
  roomier.

Fix - @group ACLs now enforced over WebDAV
: `lazysite-dav.pl` had a private `acl_allows` predating SM077 that ignored
  `@group` entries, so a group grant set in the UI was silently dropped over
  WebDAV. It now delegates to the shared `Lazysite::Auth::Acl` (resolving the
  user's groups from `lazysite/auth/groups`), so the manager, MCP and WebDAV all
  enforce the same rules. Pinned by `dav-publish.t`.

Fix - WebDAV + MCP writes now appear in the audit trail
: The audit trail only covered the manager control API, so a partner's WebDAV
  writes (PUT/DELETE/MOVE/COPY/MKCOL) and MCP tool calls were invisible.
  `audit_log` is now a shared `Lazysite::Audit` module called by all three
  writers, with origin `dav` and `mcp` joining `ui`/`api`. WebDAV writes record
  the method, path (and destination for MOVE/COPY) and outcome; MCP records the
  state-changing tools. Pinned by `dav-publish.t`.

## 0.4.2 - MCP server, Files-UI v2, Hestia lib/ fix (2026-06-24)

Feature - Files-manager UI v2 + richer audit (SM077)
: The Files page is redesigned for clarity: icon + name on the left; an Access
  column (owner + colour-coded r/w, g for a group; green = open, red = restricted),
  a Modified column (relative, absolute on hover, linking to that file's audit
  history), a right-side selection checkbox + select-all, and a chevron opening a
  per-file config card (one open at a time) holding the permissions editor
  (Owner + Read/Write as native multi-selects), Download, Add/Edit brief, Move
  and Save. New `principals` action lists assignable users + `@groups` for the
  pickers. The audit trail gains an **origin** column (ui = cookie manager,
  api = control-API token) and a **target** filter; the reader stays
  backward-compatible with older 5- and 6-field lines.

Fix - Hestia upgrade to 0.4.x creates the lib/ module dir
: The Hestia template hook (`lazysite-app.sh`) pre-creates the site-root
  siblings install.pl needs (the domain root is mode 0551, not user-writable),
  but the SM079 `lib/` was never added - so `install.pl` failed with
  `mkdir .../lib: Permission denied` on a domain whose root is not user-writable.
  The hook now creates `lib/` alongside `plugins/` and `tools/`. `install.pl`
  also turns that bare mkdir failure into an actionable message pointing at the
  template hook. Operators on 0.4.x must re-apply the template before upgrading.

Feature - MCP server v1 (SM076)
: `lazysite-mcp.pl` - a remote MCP server (Streamable-HTTP JSON-RPC) that lets an
  AI client (Claude.ai custom connector, Claude Desktop/Code) call site
  MAINTENANCE tools. Reuses the shared `Lazysite::*` action handlers; static
  bearer auth (`<partner-id>:<lzs_ token>`) verified by the same credential path
  as the control API, so capabilities + per-file ACLs bind identically. Tools:
  whoami, list/read/write/move/delete files, set_permissions, activate_theme,
  activate_layout. OAuth + SSE + set_config deferred. Pinned by
  `t/unit/mcp/01-protocol.t`.

## 0.4.1 - Files-UI overhaul + field-report fixes (2026-06-24)

Feature - Files-manager UI overhaul (SM077)
: The manager Files page gains an editable **permissions** panel (the owner chip
  expands in place to inline read/write editors -> `acl-set`/`acl-remove`),
  inline **rename/move** (a new cookie-only `move` action that re-keys the ACL
  and carries the `.brief` + generated cache), a **lock indicator** glyph, and
  **`@group` ACLs** (`Auth::Acl` matches a `@group` entry against the requester's
  X-Remote-Groups; token partners carry none, so it never matches them). The
  listing now returns each file's read/write lists + lock state. Tests: 04-acl,
  09-files-handlers, 15-acl.

Fixes - field-report + review bugs (SM080 / SM081 / SM078)
: **SM080** - the theme-asset mirror (`/lazysite-assets/LAYOUT/THEME/`) is now
  built on theme/layout **activation**, not only on a repo install, so
  `theme_assets` resolves for a copied-then-activated layout (copy-then-activate
  is zero-edit; no more hardcoded CSS paths). **SM081** - `form-targets` read now
  parses mixed `handler:`/`type:` configs in document order (it used to drop the
  `type:` targets when any handler existed). **SM078** - the audit trail records
  the **target** of each action (path, or config key), with a backward-compatible
  reader and a Target column in the manager Audit page. Tests:
  `10-theme-mirror.t`, the `07-plugins-handlers.t` mixed-format assertion,
  `19-audit-target.t`.

## 0.4.0 - Modular refactor, security hardening & conformance (QC review 2026-06-24)

Quality-control close-out audit for this milestone: **1416 tests green**;
`perlcritic` clean across every script and the new `Lazysite::*` modules; the
**strict SBOM gate passes** (180 components, `Exporter` declared for the new
modules); secrets gate clean; `tools/bench.pl --check` and
`tools/coverage.sh --check` floors hold.

- **Security** - seven-dimension review items 1-6 fixed: the control-API token
  path is no longer a manager operator (ACL-ownership bypass), the WebDAV
  blocklist applies to reads, `action_read`/`acl-*` enforce the full deny-set,
  account-create/add use `exists`, TOTP is replay-guarded, and single-use
  redemption is serialised by a consume lock.
- **Architecture (SM079)** - `lazysite-manager-api.pl` decomposed from 4286
  lines to a ~1240-line front-controller over 10 `Lazysite::*` modules
  (`Util`, `Auth::{Credential,Settings,Acl,Session}`,
  `Manager::{Common,Upload,Plugins,Files,Themes,Layouts,Artifact}`). The
  processor stays a standalone single file you can run against a folder.
- **Conformance** - curated `.perlcriticrc` gate, performance benchmark +
  baseline, committed secrets gate, five-audience docs taxonomy, `COPYRIGHT`,
  `bump-version.pl`; coverage is now measurable per-module (in-process module
  tests). `runtime_paths` perms corrected so a plain `install.pl` install is
  group-writable for www-data.

The detailed per-step log follows.

Refactor (SM079 step 2a) - Lazysite::Auth::Credential
: The credential primitives - the `/dev/urandom` CSPRNG, password and token
  hashing + verification, single-use secret verification, and token minting -
  move to `Lazysite::Auth::Credential`, removing the copies from `auth`, `dav`
  and the users tool. Unit-tested in-process (`t/unit/lib/02-credential.t`).

Refactor (SM079 step 1) - shared-module bootstrap + Lazysite::Util
: The modular scripts (auth, dav, manager-api, the users tool) now load shared
  helpers from `lib/Lazysite/` via a relative `use lib` bootstrap that resolves
  the module tree next to the script (run-in-place, tar, package and Hestia all
  just work, with the system `@INC` as the package fallback). The first module,
  `Lazysite::Util`, holds `log_event`, `const_eq` and the JSON log escaper -
  removing those copies from all four scripts. `lazysite-processor.pl` stays
  self-contained and depends on no module. `Util` is unit-tested in-process
  (`t/unit/lib/01-util.t`); it installs to `{DOCROOT}/../lib`.

Conformance (item 7, WP-2 / D2) - coverage instrumentation + regression floor
: The tests run the CGIs as subprocesses, which defeated `Devel::Cover` (it saw
  only the parent `prove` and reported `n/a`). `tools/coverage.sh` now
  instruments the children by exporting `PERL5OPT=-MDevel::Cover` so every
  spawned `perl` writes to one shared `cover_db` - a real coverage number for
  the first time. Measured: the core CGIs clear the 75% statement target
  (`dav` 92%, `users` 90%, `bundle-apply` 90%, `processor` 81%);
  `lazysite-manager-api.pl` is the gap at 60% (its 4273 lines - the same file
  flagged for a D1 split). A regression floor of 60% per cleanly-measured CGI
  is enforced by `tools/coverage.sh --check` (`dist/config/coverage-floor`),
  with 75% as the Commercial target. `auth.pl`/`install.pl`/plugins are split
  across tempdir copies (a measurement limitation, documented).

Fix - runtime directories were not group-writable on a plain install.pl install
: `install.pl` created `lazysite/auth` (and `cache`/`logs`/`manager/locks`/
  `layouts`/`lazysite-assets`) at non-group-writable modes on a fresh install:
  the file-install pass makes the directories first, so `create_runtime_paths`
  skipped them (its "don't touch an existing dir" guard, meant for upgrades). A
  plain (non-Hestia) install therefore reproduced the "add user: Permission
  denied" bug that the Hestia deploy only worked around by chmod-ing afterwards.
  The declared runtime modes (`auth` 2770, the rest 2775 - setgid +
  group-writable for the www-data CGI) are now applied on a **fresh** install
  even when the directory pre-exists; an **upgrade** still leaves an
  operator-tightened directory alone. Pinned by a new `03-install-pl.t` subtest.

Docs - five-audience documentation taxonomy + security-model refresh (item 7, WP-4)
: Adds the framework's audience entry points - `docs/USER.md`, `DEVELOPER.md`,
  `IMPLEMENTOR.md`, `OPERATOR.md`, `POLICY.md` - plus `COPYRIGHT`, and refreshes
  `docs/architecture/security.md` for the SM072-074 surfaces (claim/TOTP
  lifecycle, per-file ACLs, the forms carve-out), stating the Apache
  `X-Remote-*` trust-strip as a **hard** deployment requirement. `POLICY.md`
  records the Commercial regime and the CRA Art. 13 obligation status.

Conformance (seven-dimension review, item 7) - code quality, perf, hygiene
: D1: a curated Perl::Critic profile (`.perlcriticrc`, severity 4) enforced by
  `t/lint/02-perlcritic.t` with zero violations; the `return undef` convention
  is decided + documented and one real comma-statement was fixed. D3:
  `tools/bench.pl` - a host-relative benchmark (page render, token/password
  verify) with a committed baseline + a gross-regression gate (`--check`).
  D5/process: a committed secrets gate (`t/lint/03-secrets.t`);
  `tools/bump-version.pl` to roll the stale `VERSION`/`NEXT_VERSION`.

Security - review items 5 & 6 (TOTP/consume hardening + supply chain)
: TOTP codes are now **replay-protected** - a per-user `totp_last_step`
  rejects a code whose time-step was already accepted. Single-use redemption
  (claim / pairing key / recovery code / TOTP step) is **serialised by a
  scope-held flock** (`_consume_lock`), closing the read-verify-consume-write
  TOCTOU so the same secret can't be consumed twice under concurrency. The
  strict **SBOM gate passes** again (`Time::Local` was undeclared), and the
  stale `VERSION`/`NEXT_VERSION` (0.2.18) are bumped to the current line. The
  TOTP **seed-at-rest** item is accepted-risk (the verifier is the web tier),
  documented in the review.

Security - review fixes (priority 1-4 of the 2026-06-23 seven-dimension review)
: 1. The control-API **token path is no longer treated as a manager operator**
     (`_is_operator` returns 0 under token auth), so a `webdav` partner can no
     longer rewrite or clear another author's ACL ownership, and the token path
     never consults the client-influenceable `X-Remote-Groups`.
  2. The WebDAV blocklist now applies to **reads** as well as writes - an
     unscoped account can no longer `GET` `cgi-bin/*.pl` source.
  3. `action_read` and the `acl-*` actions enforce the full deny-set
     (`is_blocked_config`), so a manager can no longer read `forms/smtp.conf`'s
     plaintext password and ACLs cannot be set on system files.
  4. `account-create` / `add` use `exists`, not truthiness, so they can no
     longer clobber an existing passwordless account.
  Tests: `18-security-fixes.t` + F2 in `12-acl.t`. Full report in
  `docs/review/2026-06-23-seven-dimension-review.md`.

Ops - update every lazysite site at once
: A new `installers/hestia/lazysite-hestia-update-all.sh` discovers all
  lazysite sites on a Hestia host (by the `lazysite/.install-state.json`
  marker, so it never touches non-lazysite domains) and runs the per-site
  deploy on each from one release - `--list` previews, `--templates` also
  refreshes the shared vhost template. No more per-domain deploys.

Fix - the `.brief` deny was missing from the DEPLOYED vhost template
: The `.brief` `FilesMatch` deny had been added only to `lazysite.tpl` (the
  basic, no-auth variant), not `lazysite-app.tpl`/`.stpl` which the deploy
  actually applies - so on real sites `.brief` sidecars were still served raw
  by Apache (the processor 404 only covers non-existent paths). Added the deny
  to all four shipped templates, and `05-brief-sidecar.t` now checks every one,
  not just `lazysite.tpl`. Re-apply the template (deploy with `--templates`) to
  pick it up on existing sites. Also corrected the runbook, which told you to
  install the basic template as `lazysite-app`.

Docs - authoring guides updated from a real build (partner feedback)
: The layouts briefing now states the deploy model plainly - **activate the
  theme globally, keep pages layout-agnostic**, and a per-page `layout:` is a
  preview tool you remove after activating - and corrects activation to
  **self-serve** (`theme-activate` / `layout-activate` over the control API),
  not an operator hand-off. The authoring briefing gains the embedded-HTML
  rules (4-space indent becomes a code block; blank lines wrap in `<p>`; keep
  HTML flush and contiguous, or use a `.md` partial) and the
  multi-line-include requirement.

Forms - an agent can wire a form over WebDAV
: A per-form dispatch config `lazysite/forms/<name>.conf` is now agent-editable
  over WebDAV with `manage_config` - it only names operator-defined handlers,
  no secrets. So a publishing agent deploys an enquiry/contact form to file
  storage itself (`local-storage` ships by default), with no operator step.
  The secret files (`smtp.conf`, `handlers.conf`) and the `submissions/` store
  stay denied, and email delivery still needs operator-configured SMTP. The
  canonical deny list (dav, well-known, brief, whoami) now names those specific
  files instead of all of `lazysite/forms/`, pinned by `06-deny-consistency.t`;
  the publishing brief gains a "Wiring a form" task.

Docs - `.brief` guidance is now a full spec template
: The publishing briefing spells out what a good brief contains (purpose,
  sections in order, tone & style, images & sources, constraints, a "To
  change this page…" line, and the append-only log), with a worked example;
  the authoring briefing's page-creation steps now include writing the brief
  and point to it. So any agent produces briefs rich enough for the
  edit-the-brief → refactor-the-page loop.

Fix - `whoami` reported a stale `scope.deny`
: `whoami` listed only `/lazysite/forms/.smtp-password` as denied while the
  dav denies all of `/lazysite/forms/` (and `/cgi-bin/`, `/manager/`,
  templates) - so an agent trusting `whoami` thought it could write form
  configs it cannot. `whoami` now reports the canonical deny set, and
  `06-deny-consistency.t` pins it alongside the well-known and brief.

Control API - `config-set` wired
: A token client with `manage_config` can now set an allowlisted site-config
  key (`site_name`, `site_url`, `search_default`) in `lazysite.conf` over the
  control API - previously the action was in the capability allowlist but had
  no dispatch handler ("not available to token clients"). Privilege-relevant
  keys (manager groups, plugins, auth) and ones with dedicated actions
  (layout/theme) are refused. So a publishing agent can set its own site name
  without operator hand-editing.

Fix - operator could not manage accounts it did not personally create
: "Generate setup link" (and the other account actions) failed with "Not
  authorised to manage 'X'" for a manager-group operator: every named actor
  was confined to its own `managed_by` sub-tree, and a top-level account is
  created with `add`, which stamps no sub-tree at all. A manager-group
  operator (like `local`) is now unrestricted and may manage any account; a
  delegated sub-manager stays confined to its own tree.

Manager Users card
: The Add-user form drops the optional password box - accounts are created
  with no password and credentials are set afterward from the card (Generate
  setup link, or Generate credential), removing the duplication.

Manager - WebDAV publishing toggle
: `webdav_enabled` is now a first-class Config-page setting (WebDAV
  publishing: enabled / disabled) and a documented commented entry in the
  shipped `lazysite.conf`, instead of an undocumented hand-edit-only key.
  (The dav still 404s every method until it is on - that is its deliberate
  "feature off = the endpoint does not exist" gate.) The publishing briefing
  gains an "If `/dav` does not respond" section so an agent reads that 404 as
  "WebDAV disabled", not "wrong path", and knows the next 403/401 gates.

Fix - www-data manager could not write the auth store
: The auth files the CLI tool and the web manager both manage (`users`,
  `groups`, `user-settings.json`) were written `0640`/`0644` - owner-write
  only - so after a CLI write (e.g. the post-deploy `passwd manager`) the
  www-data CGI (no suexec) could not edit them: "Permission denied" on
  add-user. Now written `0660` (group-writable; the auth dir is `02770`, so
  no world access), and the users tool creates the auth dir `02770` to match
  what the deploy sets.

Manager Users card
: The Access section's lone "Interactive login" checkbox is now a Human / AI
  type switch (the `ui` setting), matching the Add-user form; the "Create
  under" default option is relabelled to make clear it creates the account
  directly under you, the manager.

Docs + consistency follow-ups
: The publishing briefing's control-API section now documents each action's
  exact parameters. A new `06-deny-consistency.t` pins the
  `.well-known` and onboarding-brief deny lists to one canonical set and
  checks the dav backs them, so the three can no longer drift apart.

SM074 - Per-file ownership and ACLs
: An opt-in entry in a central store (`lazysite/auth/acls.json`: `owner` +
  `read`/`write` allowlists) narrows access within a shared WebDAV scope -
  others can no longer overwrite a page you own, and a `read` list hides the
  source from other authors. ACLs are metadata, not content, so they live in
  one file (no per-file sidecars cluttering the tree) and are managed through
  `acl-set` / `acl-get` / `acl-remove` (manager + token control API, the
  latter gated on `webdav`). Enforced in `lazysite-dav.pl` (read + write) and
  the manager API (operators bypass; owners pass). The store sits in the
  write-denied `lazysite/` tree, so a raw `PUT` can never touch it. No entry
  means unchanged scope-only behaviour. The Files page shows a file's owner.
  Usernames only in v1 (groups deferred).

Lock propagation fix
: A WebDAV lock (or another manager user's lock) now blocks a manager
  *save*, not just opening the editor - `action_save` was parsing the shared
  lock record with the legacy line format and silently ignoring JSON/DAV
  locks.

SM073 - Per-file `.brief` sidecars
: Every authored file gets a sibling `<file>.brief` recording its intent and
  an append-only edit log. Briefs are writable over WebDAV and editable in
  the manager, but never served publicly (Apache `FilesMatch`, the dev
  server, and the processor all deny them) and never indexed in `sitemap.xml`
  / `llms.txt`. Encouraged, not enforced. The manager Files page flags each
  file's brief (present / missing, with one-click create) and is editable
  there.

Files page - list by type (SM072 §13 roadmap)
: The manager Files page gains a type filter - by extension, by folder, or
  "Generated HTML" (an `.html` with a `.md`/`.url` source beside it) - so an
  operator can quickly isolate and selectively delete stale cached pages
  after content moves or theme changes. `action=list` now returns per-file
  `ext`, `generated`, `has_brief` / `is_brief` metadata.

SM072 - Self-service credentials, claim links, and account expiry
: The operator sets account parameters; the user provisions their own
  secret. Batch 1: the claim-token primitive - a single-use, short-lived,
  hashed claim the holder redeems to set their own password or mint their
  own token (the operator never sees it). `Generate setup link` and
  `Reset credential` (revoke + fresh claim) on the Users card; a public
  `/claim` page (`auth.pl`, rate-limited, HTTPS-only, one generic error
  with no account enumeration). Plus per-account `expires_at` for
  time-boxed access ("one day, then auto-expire"), enforced at login and
  on credential verification. Also a fourth AI briefing,
  `ai-briefing-publishing`, documenting the agreed WebDAV-for-files /
  control-API-for-config publishing model. Design of record: SM072 spec.
  Batch 3: the token lifecycle over HTTP - `?action=exchange` (pairing key
  -> access token) and `?action=rotate`, both returning `{token,
  expires_at}` (one live credential). Batch 4: TOTP MFA (RFC 6238,
  self-contained) - enrol on the card (secret + otpauth URI + 8 single-use
  recovery codes), a login second factor, gated per account. Also: account
  Type (Human/AI) at creation with the type shown in the list; account
  rename across all stores; agent-editable `lazysite/nav.conf` over WebDAV
  (manage_config). Also shipped from the roadmap: the machine-readable
  bootstrap (per-partner brief block + `/.well-known/ai-partner`); manager
  version display; agent introspection (`whoami` over the control API -
  capabilities, groups, scope, plugins, layouts/themes, site capabilities);
  plugins publish `provides` (form-smtp -> email-send) for detection; email
  set-password / forgot-password (gated on SMTP + the email capability,
  generic responses); and an audit-log UI (state-changing POSTs to
  `lazysite/logs/audit.log`, a `/manager/audit` page with a per-user
  filter). The contact-form 404 (stale `lazysite-form-handler.pl` action
  name) is fixed. Still roadmap: editor<->WebDAV lock propagation and the
  offline publish bundle.

SM071 - WebDAV theme and layout management
: Staged authoring of themes and layouts with a safe back-out, in three
  phases. Phase 1: session-scoped, signed-cookie preview of an inactive
  layout/theme (never cached, never leaked). Phase 2: a delegated sub-user
  account model - provenance (`created_by`/`managed_by`), the
  `create_sub_users` / `delegate_sub_user_creation` permissions,
  disable/enable/cascade/reassign on ancestry, the `manage_themes` /
  `manage_layouts` / `manage_config` capabilities, a pairing-key → rotating
  access-token lifecycle, and `partner-create` with an onboarding brief.
  Phase 3: per-object WebDAV authoring of `lazysite/layouts/**` (active
  read-only), an `lzs:sha256` content-hash manifest, a token-authenticated
  control API (capability-gated, CSRF-exempt), activate-with-backup
  (validation, base-manifest 409, artifact lock, retention) for themes and
  layouts, and a per-token rate limit with a `Retry-After` retry contract.
  See `docs/feature-requests/SM071-webdav-theme-layout-management.md`.

SM070 - WebDAV publishing endpoint (`8687562`)
: RFC 4918 class 1 + 2 `/dav` endpoint, authenticated with HTTP Basic over
  TLS against the existing user database, with per-user access mechanisms,
  generated credentials, and a lock store shared with the manager editor.

## Releases

```datatable
columns: Version | Date | Highlights
widths: 2.6cm | 2.6cm | X
bold: 1
tone: medium
---
0.3.1 | 2026-06-12 | Maintenance tag; no source changes over 0.3.0.
0.3.0 | 2026-04-23 | Release tooling split into commit.sh + release.sh (SM063) with next-patch proposal (SM064); SBOM and manifest no longer tracked, generated fresh per release (SM065); manager UI polish (SM066); theme-install flow coherence (SM068); admin-bar theme switcher removed (SM069).
0.2.0 – 0.2.19 | 2026-04-22 – 2026-04-23 | Hardening and manager maturation across nineteen point releases: structured logging, the manager Config and Files apps, CSRF gate keyed by HTTP method, rotate-auth-secret for mass logout, login rate limiting, the journey test tier, and the D013 layouts/themes directory reshape.
0.1.0 | 2026-04-21 | Initial release: the Markdown-to-HTML processor (Template Toolkit layouts, themes, and the scan / include / oembed directives), built-in and reverse-proxy authentication, forms with an SMTP helper, the web manager (file browser, editor, plugins), an x402 payment-protocol demo, the local dev server, and the Test::More suite.
```
