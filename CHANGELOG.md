---
title: "lazysite - Changelog"
subtitle: "Release history, newest first. Tags are the stable identifiers."
brand: plain
standard-margins: true
---

## About this changelog

Versioning
: Releases are git tags (`vX.Y.Z`). Since SM063, `main` is unstable and
  carries unreleased work. Since SM971 a release is ONE commit on `main` -
  this file's section, the FEATURES entry, `VERSION`/`NEXT_VERSION`, the
  briefing, the index and the gate record, written by
  `tools/release-material.pl` - and the tag names that commit.

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

  While the work is on a branch, write `(PENDING)`. The release commit
  replaces it with the landed SHA - the commit that added that exact line -
  and the build refuses an entry whose commit it cannot tell (SM971).
  `t/lint/53-changelog-commit-refs-exist.t` ignores `(PENDING)` and fails on any
  ref that no branch contains, so the placeholder is safe and a stale ref is
  not. SM354's own entry went stale in its own landing, which is how this
  paragraph came to be written.

Archive
: This file holds the current minor release line and Unreleased. Earlier
  releases are in `docs/releases/CHANGELOG-archive.md` (SM946), moved there
  unchanged by the release commit of a new minor; the lints that check history
  read both.

## Unreleased

- SM1263 (PENDING) **MCP can remove an access rule.** `remove_permissions { path }` is the
  twin of the control API's `acl-remove` and `lazysite acl remove`: the same function, so the
  same `manage_content` capability, owner refusal, site-wide `/` and audit action
  (`acl-remove`). `set_permissions` with empty lists only clears a rule's lists. The MCP tool
  requires its path; the control API's `acl-remove` keeps SM306's default (no path removes the
  site-wide rule, so recovery stays easy).
- SM1262 (PENDING) **a bundle is adopted once, and a deleted one stays deleted.** Bundle
  adoption could not tell a bundle a site never had from one an operator deleted, so a
  deleted bundle (a `ch-files` taken out to deny WebDAV) came back on the next use of the
  users tool. The bundles a site has had - present at the first run, seeded, or adopted - are
  recorded in `auth/bundles-adopted.json`, and a recorded bundle is never adopted again. An
  unreadable record adopts nothing.
- SM1258 (PENDING) **a WebDAV delete takes a page's stem rule with it.** WebDAV DELETE
  dropped only the page's own rule, so a rule keyed by its stem waited for the next page
  written there. It now drops it under SM1242's rule (the exact stem key, only while no
  folder of that name exists), and the manager's delete and WebDAV call one shared function.
- SM1257 (PENDING) **a page drafted through its stem stays a draft when it moves.** A rule
  set on `/about` is stored as `about` and holds `about.md` back; every mover re-keyed only
  the page's own key, so a moved page left its draft behind and was published at its new
  path, its bytes back in the document root. The stem rule now moves with the page through
  one shared function (`Acl::fold_page_stem`), in the manager's move, MCP `move_file` and
  `rename_page`, the control API's move and WebDAV MOVE, while no folder of that name exists.
- SM1244 (PENDING) **lazysite check warns of an OOM that can resend a write.** OOM 0.37 and
  earlier can send a write again when its answer timed out, so a change can be made twice in
  Odoo. While the Odoo extension is on, the check names the OOM the site loads (version and
  file) and warns below 0.38, with the fix: install OOM 0.38 or later. A running oomd that
  reports an older OOM gets the same warning.
- SM1243 (PENDING) **the offline pages refusal says the list takes commas.** An
  `app_offline_pages` value of paths separated by spaces was refused as one path that is not
  plain, without saying the list is separated by commas. The refusal now says so and shows
  the list written that way.
- SM1242 (PENDING) **a draft is called a draft, and a page's rule goes with it.**
  set_permissions (acl-set) judged only the page's own record, so a page inside a draft
  folder, or under a folder's read list, was told "anyone may still fetch these pages". The
  reply now asks the rules that decide, after the save, and a draft with no read list carries
  `draft_note`: 404 to the public, a preview for any signed-in account. Deleting a page
  (delete_page, the control API, the manager) also drops a rule keyed by its stem, while no
  folder of that name exists.
- SM1241 (PENDING) **every shipped bundle reaches an existing site.** Bundles were seeded
  only when groups-settings.json was absent, so cap-tidy, cap-services and any later bundle
  reached new installs only; SM1118 adopted cap-maintenance alone. Every bundle in the shipped
  nesting is adopted now, on the next use of the users tool: only when it is absent, only for
  the shipped roles present, never rewriting an edited group, and only on a site that already
  has the bundle layer, so a site whose roles predate the bundles is left as it is.
- SM1240 (PENDING) **the sign-in rate counter is made for the serving group.** The login
  rate limiter created `auth/.login-rate.db` 0600, so only its creator could open it; the
  0.16.0 rollout found it owned by the site user on two sites, where the www-data CGI could
  not open it and allowed every attempt. It is now created 0660 under any umask, in the auth
  directory's group, and a counter the process owns that lost group access gets it back. The
  limiter still fails open when it cannot open the counter.
- SM1261 (PENDING) **a confirm whose daemon run is gone says to make the plan again.**
  oomd finds a confirm's plan by its run folder. When that folder or its plan file was
  gone, the page was told "the Odoo connection is not configured correctly" (`config`,
  503). It now answers `not-found` (404), "this plan is no longer held by the Odoo
  daemon - make the plan again", naming no path, on the page endpoint, the control API
  and MCP alike. t/unit/odoo/104.
- SM1248 (PENDING) **a change of `odoo_packs` reloads oomd with no gap.** oomd used to
  read the site's packs from its environment at its start, so the service restarted it
  when `odoo_packs` changed. While it restarted, a call was refused as `daemon-down`
  (`odoo_daemon: required`) or ran in-process (`on`). oomd's config now names the
  packs (`namespaces`, OOM 0.39 and later). On a config save the service asks oomd's
  `reload` verb, which swaps in new workers with the socket kept, and logs the answer
  or why it was refused. A call made meanwhile waits and is answered by the daemon.
  The restart for a changed `odoo_packs` is gone. An OOM before 0.39 keeps reading the
  packs at its start, and the service logs that a change waits for it.
  t/unit/odoo/103, t/unit/daemon/14.
- SM1247 (PENDING) **internal: lazysite's vendored OOM is 0.42.** The pinned
  snapshot in `t/vendor/oom` moves from 0.38 to OOM 0.42 (b91d5e2), skipping 0.39
  to 0.41. Each change of 0.39 to 0.42 was checked against lazysite. Only oomd's
  config `namespaces` and its `reload` verb reach it, and SM1248 adopts them.
  Every Odoo test passes on the new snapshot unchanged. SM747's spec is re-filed.
  t/lint/207, 261.
- SM1265 (PENDING) **`--rebuild-exposed` rebuilds only the sites in the X-Forwarded-For failure.**
  A site whose front end passes the client's X-Forwarded-For through to a site that trusts
  forwarded addresses lets any visitor choose their address (SM1194). The Hestia updater's
  new opt-in `--rebuild-exposed` rebuilds those in-scope sites and no others, after the
  template refresh and before the deploy, so the permission pass and the repair follow
  (SM270). Each is logged as auto-rebuilt. Without the flag the FAILURE line names it. It is
  refused with `--list` (#379, ruled option B).
- SM1249 (PENDING) **the Hestia site list sees every lazysite template.** `lazysite-hestia-list.sh`
  matched only the lazysite-app web template, so a host whose sites use lazysite-cgi or
  lazysite-fcgi behind lazysite-proxy listed 0 sites. It now lists every domain on a lazysite web
  template (lazysite, -app, -cgi, -fcgi) or on the lazysite-proxy proxy template, reads each field
  by name, and shows the template. `--tpl NAME` narrows the list to one. The batch updater still
  deploys only lazysite-app domains (#379).
- SM1239 (PENDING) **NOT SERVICEABLE is the verdict of the check after the repair.** The 0.16.0
  rollout reported two sites NOT SERVICEABLE and, in the same run, "repair: 32 clean". The verdict
  was the deploy's own final check, run straight after the install; the repair runs later on
  every site. A site whose repair passes is now `updated (repaired)`, with a finding saying the
  deploy's check failed first. One whose repair does not pass stays NOT SERVICEABLE.
- SM1238 (PENDING) **the ACL dry run names what has not moved, and the Hestia updater runs it.**
  The 0.16.0 notes tell the operator to run `lazysite-acl.pl reapply` without `--apply` on each site
  and report each `NOT MOVED: <path>` line. The dry run never printed one: it listed every rule.
  It now names each read-listed or draft rule whose files are still in the document root (the
  SM296 state), moving nothing; `--json` carries `not_moved`. `lazysite-hestia-update-all.sh
  --reapply-acls-dry-run` runs it on every site that upgraded, as the site's own user, reports
  each line as a finding and exits 2 if there is one (#378).
- SM1237 (PENDING) **a probe that could not run says why.** The 0.16.0 rollout ended "probe: 16
  clean, 0 exposed, 16 could not run" with no reason given. `lazysite probe` now prints a reason
  for every site it could not confirm: the skip's cause, the probe's own no-answer verdict, or
  that the check gave no verdict, with its last line. The old guess ("run lazysite repair") is
  gone. The rollout reports each reason as a finding, grouped with its sites, and counts a probe
  command that did not finish as could-not-run rather than exposed. A half-applied probe rule
  names its cause. A root `--fix` creates the private store where the engine cannot (the Hestia
  domain folder is 0551), so the probe can run on a site that never protected anything.
- SM1236 (PENDING) **the rollout names a command this host runs, and the repair after a rebuild.**
  The 0.16.0 rollout said `lazysite check --domain D` on hosts deployed from the tarball, which
  puts no `lazysite` on PATH. Every hint in the updater, the deploy, the CLI and the check, acl
  and hestia-domain tools now names `lazysite` when it is on PATH and `perl <stage>/tools/lazysite-cli.pl`
  otherwise (passed down as `LAZYSITE_CLI`), and offers `repair --domain D` rather than
  `check --fix`. A hint naming `v-rebuild-web-domain` names the repair after it, because a
  rebuild resets the docroot to 2751 (SM270). `--rebuild` already repairs the sites it manages;
  a domain it rebuilds and does not manage is now told the repair command.
- SM1235 (PENDING) **the rollout reports a message that differs only by a path once.** On the
  0.16.0 rollout one site's findings held about seventy "both trees held 'docs/X.md' ... moved
  to <dir>/docs/X.md" lines, one per file, and the report could no longer be copied. The quiet
  report now normalises paths before grouping: such lines are one finding with the count, the
  directory the paths are under per site (the displaced directory), three examples and a file
  with the full list (`LAZYSITE_FINDINGS_DIR`, default `$TMPDIR`). This covers every per-path
  finding. A message with no path reads as before.
- SM1233 (PENDING) **a Docker Compose package.** `installers/docker/` is no longer a
  placeholder: nginx, the one-rule FastCGI pool and `lazysited` in one container,
  the engine in the image and the site in three volumes (the docroot, `lazysite/`,
  the private store), built locally from the unpacked release tarball with
  `docker compose build` - no registry image, and no Odoo. The first start runs
  `install.pl` into the empty volumes; later starts leave their data alone and a new
  image upgrades the site in place. The first account is `setup-sysop`, as at the end
  of any install. The package ships in the tarball (the placeholder's export
  exclusion is gone and the manifest lists it), documented in
  `installers/docker/README.md` and `docs/IMPLEMENTOR.md`; t/tools/210 holds it
  without Docker.
- SM1219 (PENDING) **the visitor log names the signed-in account.** A visit made while signed in is
  recorded with the account the engine verified (never a header a client sent; an anonymous
  visit has none), kept as long as the rest of the log. analyse_visitors takes `by_account`
  (analytics; a domain-confined caller sees only its own domains' accounts) and the manager
  Stats page lists the visits per account. The analytics capability's text no longer says it
  cannot identify a visitor. Account names are personal data: telling members is the operator's
  duty (operator guide).
- SM1118 (PENDING) **a site can be put into maintenance.** `maintenance: on` (Config page; per
  domain on the Domains page, `alias.<host>.maintenance: on`, with the instance switch covering
  all) sends every page request by 302 to `maintenance_page` (default `/maintenance`, a shipped
  system page); the page answers 503 with Retry-After (`maintenance_until`, UTC). A new
  capability, `maintenance_access` (Access during maintenance), is what gets an account through:
  the operator group and the site-admins role hold it, on upgrade too (an upgrade adds the
  `cap-maintenance` bundle to an existing site), and any group can be given it. A posted form is
  refused and not stored, and MCP, the control API, WebDAV and the data endpoint answer 503 to an
  account without it. The check is in the processor, so it holds behind the wrapper, on the
  split templates and in the one-rule pool. `lazysite check` warns while it is on.
- SM1220 (PENDING) **the Hestia deploy no longer lists four "could not read ... Permission denied" warnings.** They came from install.pl's own health check, which the deploy runs as the site user, who cannot open the web server group's private store. The deploy passes install.pl `--health-check-by-caller`; its final check already runs as root, after the permission pass, and is the one verdict. No group change.
- SM1222 (PENDING) **the dev server takes extension directories.** `tools/lazysite-server.pl
  --extensions DIR` (repeatable) adds directories to look for extensions in, so an app's
  extensions need not be copied beside the docroot. They are searched in the order given,
  before the docroot's `plugins/`; a name in two is served from the first, and the startup
  lines say so. A symlinked directory stops the server; a symlinked script is skipped. The
  dev server only: an installed engine's lookup is unchanged.
- SM1221 (PENDING) **a signed-out call to the manager API answers 401, not 400.**
  A request with no sign-in answered `400 {ok:false, error:"Authentication required"}`, the
  status for a malformed request. It answers 401 with the same body, now with kind
  `unauthenticated`, and no `WWW-Authenticate` (the session is a cookie). A site with no
  manager account yet answers 503 (`not-set-up`) in its own wording: nothing to sign in to.
- SM1223 (PENDING) **a binding passes the caller's idempotency key to OOM.** A page that queues its
  writes offline sends an `Idempotency-Key` header per item (8 to 128 characters); it is hashed with the
  binding and who sent it into OOM's `idem`, so nobody collides with or replays another person, and a
  repeat answers the first plan or result (`repeat: true`) instead of writing twice, in process and
  through oomd, for an immediate apply and for plan and confirm. The call record has `idem` and `repeat`.
  The browser helper takes `{ idempotencyKey }`.
- SM1224 (PENDING) **a rows key's declared max raises its cap.** lazysite held every request value to
  1,000 characters, so a rows key an operation declares with its own `max` (OOM 0.38, up to
  1,048,576) was refused past 1,000 though OOM accepts it. That `max` is now the key's cap;
  an undeclared key keeps 1,000. A JSON body over 64 KB names its binding in the query and is
  held to that binding's budget (20 MB at most), so a declared large value is not refused
  by the body cap first.
- SM1225 (PENDING) **a report is a download.** A binding with `answer: download` is answered to
  a GET with the document its report holds (OOM `core.report` with `inline=1`) instead of base64
  in JSON: OOM's content type, a safe file name, `Content-Length`, `Cache-Control: private,
  no-store`, and a size cap (`download_max_kb`, default 10 MB) over which it is refused, never
  cut short. The binding's gate, callers, rate caps and both paths (in-process, oomd) are the
  call's own; a binding without the option answers JSON as before.
- SM1226 (PENDING) **security, performance: the Odoo endpoint runs warm-forked.** Every
  Odoo call used to start a perl and compile the endpoint. A parent per site, supervised
  by lazysited (the `odoo-endpoint` service, on a site with a pool conf and the Odoo
  extension on; never on a plain-CGI site), now holds the compiled endpoint and nothing
  else: no configuration, no key, no request. It forks a fresh child for each request,
  and the child runs the endpoint as the CGI does and exits. The one-rule pool hands it
  the endpoint; the split FastCGI templates (nginx and Apache `vhost-fcgi`, Hestia's
  fcgi templates) now send `/cgi-bin/lazysite-odoo.pl` to the pool, which hands it on.
  With no parent listening the pool runs the CGI. It restarts when the engine changes on
  disk. An Odoo read through the pool went from 116 ms to 17 ms on the dev host.
  Regenerate a split-template vhost to take the new location.
- SM1164 (PENDING) **internal: the surface bench measures an Odoo call through oomd.**
  `tools/bench-surfaces.sh --surface odoo-oomd` (D5) times a read binding end to end
  against the vendored oomd and OOM's fake Odoo. It splits each call into the program
  start, the endpoint's own work and the call. `--with-warm-fork` adds SM1226's parent.
- SM1228 (PENDING) **the practice copies take the extension-* action names.** The served
  field-practice briefing and its source docs/practice/app-practice.md taught `plugin-list`,
  `plugin-action`, `plugin-read` and `plugin-save`; they name the `extension-*` actions now (the
  old names are still served, audited as deprecated). t/lint/266 scans the briefing too.
- SM1229 (PENDING) **an address list a binding names is not deleted by accident.** The delete
  guard read pages, access rules, groups and lazysite.conf but not a session binding's own
  `signin_addresses` / `signin_addresses_deny`, so such a list could be deleted and the binding
  then refused every call. The manager and the control API now refuse it, naming each binding
  (with `force` as before).
- SM1250 (PENDING) **a multi-step form no longer restyles a themed page.** A page with a
  `--- step ---` form links `/assets/lazysite-chrome.css` for its step rules, under any layout, and
  the file's fallback page rules were bare element selectors: on a themed site every such page took
  the system font, an 800px column, 2rem margins and #333 text, since the link comes after the
  theme's stylesheet. The fallback template's `<body>` now carries `class="lazysite-fallback"` and
  every page rule in the file is scoped to it, so a layout's page gets the form rules only. A theme
  that worked around it (`html body { ... }`) can drop the workaround. t/unit/processor/148.
- SM1251 (PENDING) **the starter contact page no longer overrides the theme's form styles.** The
  shipped `/contact.md` opened with a `<style>` block (blue buttons, a two-column label grid) that
  came after the theme's stylesheet and beat its form rules on that page. The block is gone; the
  same rules are in `/assets/lazysite-chrome.css` under the fallback template's body class, so a
  site with no layout looks as before and a themed site gets its theme. An upgrade replaces an
  unmodified copy of the page and keeps a customised one (t/tools/211 runs it). `validate_page`
  already warns on a `<style>` in page content (`style-block-in-page`).
- SM1252 (PENDING) **a stepped form no longer leaves empty paragraphs inside itself.** A
  multi-step form's output began with its stylesheet `<link>`, which the Markdown pass does not take
  for block HTML, so the head of the form was wrapped: `<p><link><form>` ... `</p>` and
  `<p></form>`, and every stepped form had stray spacing. The link is emitted inside the form, after
  the opening tag, so the form passes through as a single-step one does. t/unit/processor/149.

## 0.16.0 - STABLE: the stable release of the 0.15 line (2026-10-22)

- SM1230 (902e2784) **coverage fits around the night's other work.** The 01:30 cover-once was refused on
  2,904 MB of swap in use with 7,075 MB available (the host carries swap all day). Swap in use no longer
  refuses a heavy job (a note, as in the gate); only MemAvailable under 5 GB, disk, inodes or the lock do.
  A stand-alone `tools/coverage.sh` runs under `nice -n 19 ionice -c3` with 2 jobs (`LAZYSITE_COVER_JOBS`),
  has no time limit, resumes from the groups already recorded, and a second start exits 2.

- SM1231 (d5739370) **docs: the stable gate's records are walked for the 0.16.0 stable.** The
  threat model (`docs/architecture/security.md`, `docs/SECURITY.md`) takes in the trust
  changes since 0.11; the held SM1219 and SM1118 are held for 0.16.1, not in the 0.16.0
  stable. The significant-change register has ten drafted entries for the release manager
  to confirm; SM747's (the Odoo extension) is accepted. OBLIGATIONS.md and TECHNICAL-FILE.md
  are walked row by row against the code of 0.15.15 (which is 0.16.0's) and stamped 0.16.0,
  with what a person must confirm, and the Declaration of Conformity is an unsigned draft
  for 0.16.0, saying so at its top. Docs only; nothing is signed.
