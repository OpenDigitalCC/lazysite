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

- SM1280 (PENDING) **An Odoo operation is told whether the call came from an address list.**
  Ruling 3 (the OOM Lab's office-network clock-in): a binding names an `address_profile` and an
  `address_param` (a yes/no parameter), and its operation receives only 1 or 0 - never the
  address. The server decides it from the request's address behind `trusted_proxies`, and a page
  cannot set or override it. No address, an unknown list or an unreadable store is 0. The list
  counts as in use, so it is not deleted while the binding names it. The key is `address_profile`
  (ruling 58, ahead of address lists becoming address profiles); for now it names an address list.
- SM1277 (PENDING) **The page shows an Odoo write whose answer never came.** Ruling 10b: the
  browser helper draws what a `write()` or `confirm()` left unknown into the page's
  `data-ls-odoo-unknown` element, as text, with Check again, and It was made / It was not made
  for each change only when the answer says the person may say. `LazysiteOdoo.resume` and
  `showUnknown` are there for a page that draws it itself.
- SM1278 (PENDING) **The manager lists, settles and dismisses an unknown Odoo run.** Rulings 10b
  and 10c: the Odoo extension's row on the Extensions page has Unknown Odoo writes, each open run
  with the changes still unknown, It was made / It was not made for a change, and Check again and
  Close run (a dismissal) for the run. Listing and dismissing need `settle_odoo_writes`; a dismissal sends
  nothing to Odoo, keeps who, when and why, and is one call record and one audit line. The
  control API and MCP have `odoo-unknown-runs`, `odoo-resume` and `odoo-dismiss` (and their
  twins).
- SM1279 (PENDING) **An unknown Odoo run is kept until it is settled or dismissed.** Ruling 10c:
  no expiry. The plan store's seven days, the daemon run folders' schedule and SM1162's purge
  of a spent plan's file bytes no longer reach a run left unknown and still open, since a resume
  reads its plan, its journal and the bytes of a change it sends again. Settled or dismissed, it
  goes on the ordinary schedule and its bytes go at once.
- SM1275 (PENDING) **An Odoo run that ended unknown is read back and settled.** Rulings 10a and
  10b, with OOM 0.42's resume: an apply that left a change unknown now names its run (`run`,
  the plan id; no path), and `POST {run, resume: true}` resumes it. OOM reads each unknown
  change back first (found made: done, never sent again; found not made: carried), then the
  rest of the run applies through the path a first apply takes, in-process or through oomd.
  A change no read can tell is refused `unknown-outcome` (409), naming it, until its maker or a
  holder of `settle_odoo_writes` says it was made (`assume_done`) or was not
  (`assume_not_done`). Anyone the binding admits may check again. A visitor never resumes a
  public binding's run. A confirm's token rule, the write caps, one call record and one audit
  line naming the run and the decision.
- SM1276 (PENDING) **A capability settles an Odoo write whose answer never came.** Ruling 10a:
  where OOM cannot read a change back, the run's own maker or a holder of a new capability
  says whether it was made. `settle_odoo_writes` is declared by the Odoo extension, so it is
  grantable only where the extension is installed, and every operator group holds it: a new
  site's at once, an older site's by the SM645 top-up. A declined 0 stays declined.
- SM1291 (PENDING) **a theme installs from a zip over MCP, its fonts with it.** MCP
  `install_theme` (manage_themes) takes a theme's zip as base64 and installs it through the
  function the manager's Upload Theme uses, so the checks and refusals are the same ones -
  0.16.2's among them (SM1303): the site's upload limit, and no symbolic link or file type
  the web server runs. The audit row is theme-upload's, and the caller can `delete_theme`
  what it installed. From the lazysite.io site agent (K-5).

- SM1290 (PENDING) **a page previews in a theme that is not active.** MCP `preview_page` takes
  `theme`: the page, or a draft, renders with that installed theme in place of the site's,
  the section's and the page's own, so a theme can be checked on real pages before it is
  activated. Nothing is activated, cached or written, and a theme not installed for the
  layout the page renders with is refused. It needs `manage_themes` or `manage_layouts` as
  well as `manage_content`, as the manager's theme preview does; the manager's page preview
  takes the same `theme`. From the lazysite.io site agent (K-4).

- SM1289 (PENDING) **a form under any theme has base styles, and the theme overrides them.**
  Under a theme with no form rules (lumen, edge observation O-4) a stepped form's fields and
  buttons were the browser's own. `lazysite-chrome.css` now carries small base rules for the
  engine's forms - field spacing, full-width inputs, buttons in the page's font, the step
  fieldsets, the error line - each inside `:where()`, so its specificity is zero, and with no
  colour beyond `currentColor` and `inherit`. Any page with a form links them, with or without
  a layout; under a layout the link goes first in the head, so any theme rule about the same
  element wins. Ruling 30.

- SM1288 (PENDING) **the sign-in and search pages no longer override the theme.** The starter
  `/forgot.md` and `/search-results.md`, and the engine's login, forgot and claim pages, each
  opened with a `<style>` block that came after the theme's stylesheet, so on a themed site
  those pages wore the engine's buttons and grid. The blocks are gone and the same rules are in
  `lazysite-chrome.css` under `.lazysite-fallback`, as SM1251 did for the contact page: a site
  with no layout sees the same pages, and a themed site sees its theme. An upgrade refreshes a
  starter copy the site never changed and keeps one it did. Ruling 12.
- SM1299 (PENDING) **the Odoo sign-in page returns the visitor where they were going, and
  /login offers it.** Once signed in, `/odoo-signin` goes to its `?next=` when that is a
  path on this site, and to `/` otherwise: the endpoint decides, through the check
  `/login`'s own return uses (now one function, which also refuses a `//` anywhere in the
  path, for `/login` too). On a site opted in to Odoo sign-in, `/login` shows a "Sign in
  with Odoo" link to it, carrying any `next`, beside the local form. `/odoo-signin` stays
  reachable while the site is in maintenance, as `/login` does. Ruled 2026-10-23
  (rulings 36-39).

- SM1295 (PENDING) **a ready-made sign-in page for a site whose sign-in is the Odoo
  login.** While `odoo_site_signin` is on, `/odoo-signin` is a sign-in page in the site's
  own layout: a "Sign in with your Odoo login" button that opens the sign-in dialog, and,
  once signed in, who is signed in and a sign-out. Set `auth_redirect: /odoo-signin` to
  send visitors there. It is a system page like `/login`, so a site's own `odoo-signin.md`
  replaces it, and with the switch off it is not found. The button is the `::: odoo-signin`
  component, which a layout may restyle; the page carries no inline style. SM1160's
  follow-up (#340).

- SM1296 (PENDING) **get_permissions on a page's stem answers the rule that governs the
  page.** On edge, `/zz76/b` answered `acl: null` while `/zz76/b.md` was a draft, because a
  move had folded the draft into the page's own key (SM1257). A stem that names a page, and
  the page itself, now answer the page's rule as the engine reads it, with `key` naming
  the key that holds it (and `keys` when the page and its stem each hold part). On MCP
  `get_permissions`, the control API `acl-get` and `lazysite acl show`. A folder of that
  name keeps its own rule. Edge walk of 0.16.1, O-3.

- SM1297 (PENDING) **the maintenance switch can be cleared back to unset.** Switched on
  and off through config-set, lazysite.conf read `maintenance: off` where it had been
  empty, and config-set refused an empty value. Empty is now accepted and means off, as
  an absent key does; the Config page's switch sends it when turned off, so the key is
  cleared. Edge walk of 0.16.1, O-1.

- SM1298 (PENDING) **every form's unknown-rule warning says which form, in one
  wording.** The first form's warning for a `key:value` the renderer ignores had no
  "form 1:" and was worded differently from a later form's ("form 2: unknown form rule
  ..."). Every form's warning now reads "form N: unknown form rule '<rule>' on field
  '<field>': it is not one the form reads, so it does nothing when the form renders",
  for a bare word and a `key:value` alike. What blocks a save is unchanged. Edge walk
  of 0.16.1, O-2.

- SM1294 (PENDING) **a site may set a ceiling on the browser features its pages ask
  for.** `permissions_policy_allow` in lazysite.conf is optional. Absent or empty, a page
  asks for any denied feature as SM1266 made it. Set, a page's `<feature>: self` grants
  only a listed feature: an unlisted one keeps `=()`, and validate warns naming the key.
  `none` lets no page ask. payment and browsing-topics can never be listed: config-set
  refuses them by name, a hand-written one grants nothing, and `lazysite check` names it.
  On the Config page under Browser features; the site's for every domain, never set per
  domain alias. Page status shows what the response sends. Ruled 2026-10-23 (ruling 29).
- SM1283 (PENDING) **The sign-in and error pages serve when the engine tree is beside the
  docroot.** On a site that had moved its engine tree to `<docroot>-lazysite` (SM293), the
  engine's own `/claim` and `/login` (SM201) answered 404 whenever the docroot had no copy
  of its own, which a fresh install never seeds. The fallback chose the engine's file and
  the content-root check then refused it, because its real path is outside the docroot. A
  source the fallback chose is now accepted when it sits under the engine's page tree.
  Every other source is confined as before.

- SM1274 (PENDING) **Dismiss all empties the notices panel.** "Mark all read" marked every
  notice read and left them all in the panel. Now called Dismiss all, it also takes them out:
  the panel is empty and the count 0, on screen and on the next page, and the notices stay in
  the store, as a single Dismiss leaves them. A notice that arrives afterwards is unread. The
  manager offers it whenever the panel holds a notice; a member's own bell does the same.
  Ruled 2026-10-23 (ruling 26).

- SM1273 (PENDING) **lazysite repair gives a manager group the capabilities a release
  added.** A site whose only warning was a manager group's not-yet-held capability was left
  "awaiting your decision", though there was nothing to decide. Before it checks again,
  repair now runs the users tool's top-up (`group-reach` for each manager group, as the
  site's owner when run as root), so the site ends repaired. A declined capability stays
  declined. `--dry-run` names the commands and runs none, and a failed call is reported
  and the repair goes on. The check's warning names `repair --domain DOMAIN` as the
  simplest fix.

- SM1272 (PENDING) **the check says a manager group is granted a new capability on the next
  use, not that it must decide.** After an upgrade, `lazysite check` told an operator that
  sysops had "not decided" on a capability the release added (on edge, `maintenance_access`)
  and asked them to grant or dismiss it on the Groups page. The SM645 top-up grants a manager
  group every capability it has no decision on, on the next use of the users tool, so the
  warning now says that and names the use: opening the Users, Groups or Config page, or a
  `lazysite-users.pl` command such as `group-reach`. A declined capability stays declined. A
  gap the top-up does not fill keeps the Groups page wording. This corrects the 0.16.1 line
  for SM1118, "on upgrade too (an upgrade adds the `cap-maintenance` bundle)": nothing is
  granted at upgrade. The operator group and site-admins get `maintenance_access` on the
  next use of the users tool after the upgrade (SM685, kept by the release manager on
  2026-10-23).

- SM1270 (PENDING) **acl-remove needs a path.** The control API's `acl-remove` with no path,
  or an empty one, removed the site-wide rule and published everything it held back (the
  dispatcher's `/` default, which SM306 kept for recovery). It is refused now, on every
  channel and before the scope check, with a message saying the site-wide rule is removed
  with `path=/`; `Files::action_acl_remove` refuses it for the CLI and MCP too. The action
  declares `path` required, as MCP `remove_permissions` does. `/`, `.` and `./` still remove
  the site-wide rule. Ruled 2026-10-23 (ruling 17), replacing SM306's no-path default.

## 0.16.2 - EDGE: a security release: a theme archive cannot plant a link in the served asset mirror (2026-10-23)

- SM1307 (a33a0406) **security: a security release reaches the stable sites of a Hestia
  fleet.** `lazysite upgrade --all --force-security` reaches registered sites, and a Hestia
  host registers none, while its updater scoped by `update_channel` alone.
  `lazysite-hestia-update-all.sh --force-security` deploys a release whose manifest declares
  `security_critical` to the sites whose channel refuses it (`install.pl --force-security`,
  through the per-site deploy), names each one in the table, the findings and the summary,
  and audits it as `upgrade-forced`; excluded sites stay excluded. Both refuse the flag for a
  release that does not declare it. `upgrade --all` on such a host names the updater
  instead of reporting nothing to do (ruling 41b).

- SM1306 (6bbe2fe6) **docs: the compliance records cover 0.16.2.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against this security release's changes (SM1303-SM1305) and
  stamped 0.16.2: the SM1303 register entry, the SBOM on the 0.16.2 tree, 0.16.2 as the first
  release cut security-critical, and an operator row for SM1304's planted links. Docs only;
  nothing is signed.

- SM1305 (c8f8d554) **release: `tools/release.sh` cuts a security release.**
  `--security-critical` is passed to `build-manifest.pl`, so the shipped manifest carries
  `"security_critical": true`, the declaration `lazysite upgrade --all --force-security`
  needs before it overrides every site's channel and policy. A build without the flag
  carries no such key. OPERATOR.md and docs/development.md say how (ruling 41b).

- SM1304 (6d23dfaf) **security: `lazysite check` names a symbolic link in the served asset
  mirror.** A link a theme upload planted before 0.16.2 (SM1303) stays after the upgrade,
  still serving what it points at. The check now warns for every symbolic link under
  `lazysite-assets/`, naming it and its target, and the line says to remove it and rotate
  `lazysite/auth/.secret` (the manager's Sessions page, "Log out all users"). It never
  deletes one, and `lazysite repair` counts such a site as needing a human, not as repaired
  (ruling 42).

- SM1303 (dac205ff) **security: a theme archive cannot plant a link in the served asset
  mirror.** The manager's Upload Theme (`theme-upload`, `manage_themes`) extracted a zip's
  symbolic link and copied it into `/lazysite-assets/` as a link, so a public URL served any
  file the web server can read - `lazysite/auth/.secret`, the session-signing secret, among
  them, from which an operator's session could be forged. Every release up to 0.16.1 is
  affected. Every entry is now checked before any is extracted: a symbolic link, a file type
  the web server runs (`.php` and the rest) or an archive over the site's upload limit
  refuses the whole archive. `docs/SECURITY.md` records it, drafted for the release manager.

## 0.16.1 - EDGE: the first batch on the 0.16 line: a moved draft stays a draft, and maintenance mode (2026-10-23)

- SM1269 (b81c128e) **docs: the compliance records cover 0.16.1.** The 0.16.1 edge gate
  refused with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.0. Both are walked against
  this release's changes and stamped 0.16.1. The significant-change register in
  `docs/SECURITY.md` has five drafted entries for the release manager to confirm: the
  warm-forked Odoo endpoint (SM1226, a new local socket), the stem-rule fix (SM1257), the
  Odoo options and OOM 0.42, the Docker Compose package, and the changes that fired no
  trigger. The threat model gains the warm-fork parent as a trust boundary, and
  OBLIGATIONS.md an operator row for SM1219's account names. Docs only; nothing is signed.
- SM1263 (c9499210) **MCP can remove an access rule.** `remove_permissions { path }` is the
  twin of the control API's `acl-remove` and `lazysite acl remove`: the same function, so the
  same `manage_content` capability, owner refusal, site-wide `/` and audit action
  (`acl-remove`). `set_permissions` with empty lists only clears a rule's lists. The MCP tool
  requires its path; the control API's `acl-remove` keeps SM306's default (no path removes the
  site-wide rule, so recovery stays easy).
- SM1262 (53a69904) **a bundle is adopted once, and a deleted one stays deleted.** Bundle
  adoption could not tell a bundle a site never had from one an operator deleted, so a
  deleted bundle (a `ch-files` taken out to deny WebDAV) came back on the next use of the
  users tool. The bundles a site has had - present at the first run, seeded, or adopted - are
  recorded in `auth/bundles-adopted.json`, and a recorded bundle is never adopted again. An
  unreadable record adopts nothing.
- SM1258 (c3e4a750) **a WebDAV delete takes a page's stem rule with it.** WebDAV DELETE
  dropped only the page's own rule, so a rule keyed by its stem waited for the next page
  written there. It now drops it under SM1242's rule (the exact stem key, only while no
  folder of that name exists), and the manager's delete and WebDAV call one shared function.
- SM1257 (09684d7a) **a page drafted through its stem stays a draft when it moves.** A rule
  set on `/about` is stored as `about` and holds `about.md` back; every mover re-keyed only
  the page's own key, so a moved page left its draft behind and was published at its new
  path, its bytes back in the document root. The stem rule now moves with the page through
  one shared function (`Acl::fold_page_stem`), in the manager's move, MCP `move_file` and
  `rename_page`, the control API's move and WebDAV MOVE, while no folder of that name exists.
- SM1244 (269ff00c) **lazysite check warns of an OOM that can resend a write.** OOM 0.37 and
  earlier can send a write again when its answer timed out, so a change can be made twice in
  Odoo. While the Odoo extension is on, the check names the OOM the site loads (version and
  file) and warns below 0.38, with the fix: install OOM 0.38 or later. A running oomd that
  reports an older OOM gets the same warning.
- SM1243 (4db4d2fb) **the offline pages refusal says the list takes commas.** An
  `app_offline_pages` value of paths separated by spaces was refused as one path that is not
  plain, without saying the list is separated by commas. The refusal now says so and shows
  the list written that way.
- SM1242 (27b0769b) **a draft is called a draft, and a page's rule goes with it.**
  set_permissions (acl-set) judged only the page's own record, so a page inside a draft
  folder, or under a folder's read list, was told "anyone may still fetch these pages". The
  reply now asks the rules that decide, after the save, and a draft with no read list carries
  `draft_note`: 404 to the public, a preview for any signed-in account. Deleting a page
  (delete_page, the control API, the manager) also drops a rule keyed by its stem, while no
  folder of that name exists.
- SM1241 (a854ba6f) **every shipped bundle reaches an existing site.** Bundles were seeded
  only when groups-settings.json was absent, so cap-tidy, cap-services and any later bundle
  reached new installs only; SM1118 adopted cap-maintenance alone. Every bundle in the shipped
  nesting is adopted now, on the next use of the users tool: only when it is absent, only for
  the shipped roles present, never rewriting an edited group, and only on a site that already
  has the bundle layer, so a site whose roles predate the bundles is left as it is.
- SM1240 (896ab776) **the sign-in rate counter is made for the serving group.** The login
  rate limiter created `auth/.login-rate.db` 0600, so only its creator could open it; the
  0.16.0 rollout found it owned by the site user on two sites, where the www-data CGI could
  not open it and allowed every attempt. It is now created 0660 under any umask, in the auth
  directory's group, and a counter the process owns that lost group access gets it back. The
  limiter still fails open when it cannot open the counter.
- SM1261 (510802aa) **a confirm whose daemon run is gone says to make the plan again.**
  oomd finds a confirm's plan by its run folder. When that folder or its plan file was
  gone, the page was told "the Odoo connection is not configured correctly" (`config`,
  503). It now answers `not-found` (404), "this plan is no longer held by the Odoo
  daemon - make the plan again", naming no path, on the page endpoint, the control API
  and MCP alike. t/unit/odoo/104.
- SM1248 (4ea417dd) **a change of `odoo_packs` reloads oomd with no gap.** oomd used to
  read the site's packs from its environment at its start, so the service restarted it
  when `odoo_packs` changed. While it restarted, a call was refused as `daemon-down`
  (`odoo_daemon: required`) or ran in-process (`on`). oomd's config now names the
  packs (`namespaces`, OOM 0.39 and later). On a config save the service asks oomd's
  `reload` verb, which swaps in new workers with the socket kept, and logs the answer
  or why it was refused. A call made meanwhile waits and is answered by the daemon.
  The restart for a changed `odoo_packs` is gone. An OOM before 0.39 keeps reading the
  packs at its start, and the service logs that a change waits for it.
  t/unit/odoo/103, t/unit/daemon/14.
- SM1247 (36a3434f) **internal: lazysite's vendored OOM is 0.42.** The pinned
  snapshot in `t/vendor/oom` moves from 0.38 to OOM 0.42 (b91d5e2), skipping 0.39
  to 0.41. Each change of 0.39 to 0.42 was checked against lazysite. Only oomd's
  config `namespaces` and its `reload` verb reach it, and SM1248 adopts them.
  Every Odoo test passes on the new snapshot unchanged. SM747's spec is re-filed.
  t/lint/207, 261.
- SM1265 (ce3eb088) **`--rebuild-exposed` rebuilds only the sites in the X-Forwarded-For failure.**
  A site whose front end passes the client's X-Forwarded-For through to a site that trusts
  forwarded addresses lets any visitor choose their address (SM1194). The Hestia updater's
  new opt-in `--rebuild-exposed` rebuilds those in-scope sites and no others, after the
  template refresh and before the deploy, so the permission pass and the repair follow
  (SM270). Each is logged as auto-rebuilt. Without the flag the FAILURE line names it. It is
  refused with `--list` (#379, ruled option B).
- SM1249 (f0a4772b) **the Hestia site list sees every lazysite template.** `lazysite-hestia-list.sh`
  matched only the lazysite-app web template, so a host whose sites use lazysite-cgi or
  lazysite-fcgi behind lazysite-proxy listed 0 sites. It now lists every domain on a lazysite web
  template (lazysite, -app, -cgi, -fcgi) or on the lazysite-proxy proxy template, reads each field
  by name, and shows the template. `--tpl NAME` narrows the list to one. The batch updater still
  deploys only lazysite-app domains (#379).
- SM1239 (5a60a9e1) **NOT SERVICEABLE is the verdict of the check after the repair.** The 0.16.0
  rollout reported two sites NOT SERVICEABLE and, in the same run, "repair: 32 clean". The verdict
  was the deploy's own final check, run straight after the install; the repair runs later on
  every site. A site whose repair passes is now `updated (repaired)`, with a finding saying the
  deploy's check failed first. One whose repair does not pass stays NOT SERVICEABLE.
- SM1238 (05d8831c) **the ACL dry run names what has not moved, and the Hestia updater runs it.**
  The 0.16.0 notes tell the operator to run `lazysite-acl.pl reapply` without `--apply` on each site
  and report each `NOT MOVED: <path>` line. The dry run never printed one: it listed every rule.
  It now names each read-listed or draft rule whose files are still in the document root (the
  SM296 state), moving nothing; `--json` carries `not_moved`. `lazysite-hestia-update-all.sh
  --reapply-acls-dry-run` runs it on every site that upgraded, as the site's own user, reports
  each line as a finding and exits 2 if there is one (#378).
- SM1237 (e9330fee) **a probe that could not run says why.** The 0.16.0 rollout ended "probe: 16
  clean, 0 exposed, 16 could not run" with no reason given. `lazysite probe` now prints a reason
  for every site it could not confirm: the skip's cause, the probe's own no-answer verdict, or
  that the check gave no verdict, with its last line. The old guess ("run lazysite repair") is
  gone. The rollout reports each reason as a finding, grouped with its sites, and counts a probe
  command that did not finish as could-not-run rather than exposed. A half-applied probe rule
  names its cause. A root `--fix` creates the private store where the engine cannot (the Hestia
  domain folder is 0551), so the probe can run on a site that never protected anything.
- SM1236 (1289daa1) **the rollout names a command this host runs, and the repair after a rebuild.**
  The 0.16.0 rollout said `lazysite check --domain D` on hosts deployed from the tarball, which
  puts no `lazysite` on PATH. Every hint in the updater, the deploy, the CLI and the check, acl
  and hestia-domain tools now names `lazysite` when it is on PATH and `perl <stage>/tools/lazysite-cli.pl`
  otherwise (passed down as `LAZYSITE_CLI`), and offers `repair --domain D` rather than
  `check --fix`. A hint naming `v-rebuild-web-domain` names the repair after it, because a
  rebuild resets the docroot to 2751 (SM270). `--rebuild` already repairs the sites it manages;
  a domain it rebuilds and does not manage is now told the repair command.
- SM1235 (2091a8a5) **the rollout reports a message that differs only by a path once.** On the
  0.16.0 rollout one site's findings held about seventy "both trees held 'docs/X.md' ... moved
  to <dir>/docs/X.md" lines, one per file, and the report could no longer be copied. The quiet
  report now normalises paths before grouping: such lines are one finding with the count, the
  directory the paths are under per site (the displaced directory), three examples and a file
  with the full list (`LAZYSITE_FINDINGS_DIR`, default `$TMPDIR`). This covers every per-path
  finding. A message with no path reads as before.
- SM1266 (6d322cff) **a page may ask for any browser feature the platform denies.**
  SM1174 let a page say `camera: self`; the same key now works for every feature in the
  Permissions-Policy denied list - `geolocation: self`, `microphone: self` - on the
  camera's terms: that page alone, over https only, front matter only, kept per page
  through the cache. A page that asks for nothing sends exactly the header it sent
  before, and the camera behaves as it did. The validator reports a value other than
  `self` or `none` (`permission-unreadable`) and a `<key>: self` that names no such
  feature (`permission-unknown`, a warning); page_status and the editor's status bar list what a
  page allows. `payment` (the paid-page key) and `browsing-topics` (no trackers) cannot be asked for.
  The site-level allow list is later.
- SM1267 (bc6a26a4) **the briefings name the denied browser features.** The authoring and
  layouts briefings list every feature Permissions-Policy denies and say how a page asks
  for one, so an author learns a microphone or location feature needs the page key
  before a visitor reports that it does not work (SM710).
- SM1245 (834e04a8) **internal: a test child never deadlocks on its pipes, and never hangs
  the suite.** t/unit/dav/33 sat 95 minutes in the 2026-10-20 14:30 suite run: run_dav read
  the child's stdout to EOF before its stderr, with no limit, and 232 files under t/ had
  their own copies of that block, 381 in all. TestHelper::run_child writes stdin while it
  reads stdout and stderr, and a child still running after five minutes (twenty under
  Devel::Cover) is killed and the test fails naming itself, the child and the wait. The
  helpers and the copies run through it; t/unit/lib/207 hangs on the old run_dav.
- SM1246 (70b2272a) **internal: a test runs its children through run_child.** t/lint/273
  fails a test that calls open2 or open3 itself, unless it says it drives the child itself
  (signals it, or reads it while it runs).
- SM1233 (f712a7f7) **a Docker Compose package.** `installers/docker/` is no longer a
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
- SM1219 (b8ed6fbc) **the visitor log names the signed-in account.** A visit made while signed in is
  recorded with the account the engine verified (never a header a client sent; an anonymous
  visit has none), kept as long as the rest of the log. analyse_visitors takes `by_account`
  (analytics; a domain-confined caller sees only its own domains' accounts) and the manager
  Stats page lists the visits per account. The analytics capability's text no longer says it
  cannot identify a visitor. Account names are personal data: telling members is the operator's
  duty (operator guide).
- SM1118 (735eec5f) **a site can be put into maintenance.** `maintenance: on` (Config page; per
  domain on the Domains page, `alias.<host>.maintenance: on`, with the instance switch covering
  all) sends every page request by 302 to `maintenance_page` (default `/maintenance`, a shipped
  system page); the page answers 503 with Retry-After (`maintenance_until`, UTC). A new
  capability, `maintenance_access` (Access during maintenance), is what gets an account through:
  the operator group and the site-admins role hold it, on upgrade too (an upgrade adds the
  `cap-maintenance` bundle to an existing site), and any group can be given it. A posted form is
  refused and not stored, and MCP, the control API, WebDAV and the data endpoint answer 503 to an
  account without it. The check is in the processor, so it holds behind the wrapper, on the
  split templates and in the one-rule pool. `lazysite check` warns while it is on.
- SM1220 (f45dacda) **the Hestia deploy no longer lists four "could not read ... Permission denied" warnings.** They came from install.pl's own health check, which the deploy runs as the site user, who cannot open the web server group's private store. The deploy passes install.pl `--health-check-by-caller`; its final check already runs as root, after the permission pass, and is the one verdict. No group change.
- SM1222 (fea99edd) **the dev server takes extension directories.** `tools/lazysite-server.pl
  --extensions DIR` (repeatable) adds directories to look for extensions in, so an app's
  extensions need not be copied beside the docroot. They are searched in the order given,
  before the docroot's `plugins/`; a name in two is served from the first, and the startup
  lines say so. A symlinked directory stops the server; a symlinked script is skipped. The
  dev server only: an installed engine's lookup is unchanged.
- SM1221 (fb2e5c3a) **a signed-out call to the manager API answers 401, not 400.**
  A request with no sign-in answered `400 {ok:false, error:"Authentication required"}`, the
  status for a malformed request. It answers 401 with the same body, now with kind
  `unauthenticated`, and no `WWW-Authenticate` (the session is a cookie). A site with no
  manager account yet answers 503 (`not-set-up`) in its own wording: nothing to sign in to.
- SM1223 (58890621) **a binding passes the caller's idempotency key to OOM.** A page that queues its
  writes offline sends an `Idempotency-Key` header per item (8 to 128 characters); it is hashed with the
  binding and who sent it into OOM's `idem`, so nobody collides with or replays another person, and a
  repeat answers the first plan or result (`repeat: true`) instead of writing twice, in process and
  through oomd, for an immediate apply and for plan and confirm. The call record has `idem` and `repeat`.
  The browser helper takes `{ idempotencyKey }`.
- SM1224 (65c229f7) **a rows key's declared max raises its cap.** lazysite held every request value to
  1,000 characters, so a rows key an operation declares with its own `max` (OOM 0.38, up to
  1,048,576) was refused past 1,000 though OOM accepts it. That `max` is now the key's cap;
  an undeclared key keeps 1,000. A JSON body over 64 KB names its binding in the query and is
  held to that binding's budget (20 MB at most), so a declared large value is not refused
  by the body cap first.
- SM1225 (2dc27941) **a report is a download.** A binding with `answer: download` is answered to
  a GET with the document its report holds (OOM `core.report` with `inline=1`) instead of base64
  in JSON: OOM's content type, a safe file name, `Content-Length`, `Cache-Control: private,
  no-store`, and a size cap (`download_max_kb`, default 10 MB) over which it is refused, never
  cut short. The binding's gate, callers, rate caps and both paths (in-process, oomd) are the
  call's own; a binding without the option answers JSON as before.
- SM1226 (9b8dee47) **security, performance: the Odoo endpoint runs warm-forked.** Every
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
- SM1164 (d9d729fb) **internal: the surface bench measures an Odoo call through oomd.**
  `tools/bench-surfaces.sh --surface odoo-oomd` (D5) times a read binding end to end
  against the vendored oomd and OOM's fake Odoo. It splits each call into the program
  start, the endpoint's own work and the call. `--with-warm-fork` adds SM1226's parent.
- SM1228 (81539a35) **the practice copies take the extension-* action names.** The served
  field-practice briefing and its source docs/practice/app-practice.md taught `plugin-list`,
  `plugin-action`, `plugin-read` and `plugin-save`; they name the `extension-*` actions now (the
  old names are still served, audited as deprecated). t/lint/266 scans the briefing too.
- SM1229 (1f80f332) **an address list a binding names is not deleted by accident.** The delete
  guard read pages, access rules, groups and lazysite.conf but not a session binding's own
  `signin_addresses` / `signin_addresses_deny`, so such a list could be deleted and the binding
  then refused every call. The manager and the control API now refuse it, naming each binding
  (with `force` as before).
- SM1250 (08066592) **a multi-step form no longer restyles a themed page.** A page with a
  `--- step ---` form links `/assets/lazysite-chrome.css` for its step rules, under any layout, and
  the file's fallback page rules were bare element selectors: on a themed site every such page took
  the system font, an 800px column, 2rem margins and #333 text, since the link comes after the
  theme's stylesheet. The fallback template's `<body>` now carries `class="lazysite-fallback"` and
  every page rule in the file is scoped to it, so a layout's page gets the form rules only. A theme
  that worked around it (`html body { ... }`) can drop the workaround. t/unit/processor/148.
- SM1251 (fe75f66a) **the starter contact page no longer overrides the theme's form styles.** The
  shipped `/contact.md` opened with a `<style>` block (blue buttons, a two-column label grid) that
  came after the theme's stylesheet and beat its form rules on that page. The block is gone; the
  same rules are in `/assets/lazysite-chrome.css` under the fallback template's body class, so a
  site with no layout looks as before and a themed site gets its theme. An upgrade replaces an
  unmodified copy of the page and keeps a customised one (t/tools/211 runs it). `validate_page`
  already warns on a `<style>` in page content (`style-block-in-page`).
- SM1252 (7866e16f) **a stepped form no longer leaves empty paragraphs inside itself.** A
  multi-step form's output began with its stylesheet `<link>`, which the Markdown pass does not take
  for block HTML, so the head of the form was wrapped: `<p><link><form>` ... `</p>` and
  `<p></form>`, and every stepped form had stray spacing. The link is emitted inside the form, after
  the opening tag, so the form passes through as a single-step one does. t/unit/processor/149.
- SM1253 (fb97b34e) **validate_page no longer reports valid form rules as unknown.** The form check
  split a field's rules on whitespace and knew ten words, so a radio or checklist option with a
  space, a quoted `placeholder:"Your full name"`, and the `file`, `multiple` and `capture` rules
  were each an `invalid-form-rule` issue, failing a page that renders correctly. The validator cuts
  the rules with a marked copy of the renderer's tokeniser and knows every rule word the renderer
  takes. t/lint/276 runs both: it takes the renderer's accepted words from the renderer itself and
  compares the two cuts over every form line in the tree and a generated set.
- SM1254 (f94da757) **a quoted page variable reaches the layout without its quotes.** A
  `tt_page_var:` entry kept its quote marks, so `hero_cards: "a,b,c"` reached the layout as
  `"a,b,c"` and a split gave `"a` and `c"`. One matched pair of quotes is taken off, as it is for
  a top-level front-matter key; an unquoted value is unchanged. A quoted source
  (`x: "json:/d.json"`) now binds as the unquoted one does. t/unit/processor/150.
- SM1255 (86a3c29f) **docs: the shipped docs say what the engine does.** From the lazysite.io
  content check: the pre-layouts Views page (`view.tt`) is removed and its links point at Layouts,
  and the per-page layout override page describes `lazysite/layouts/NAME/layout.tt` and the
  built-in fallback; the per-host key list has all 29 keys (and the env allowlist `REQUEST_URI`);
  the session registry prunes at `session_lifetime`, not a fixed 24 hours; the connect code lasts
  30 minutes; the CSP shipped report-only by default (FEATURES.md said enforcing); the bad-URL
  block list is on the plugin's own page; and a cached page is served by the processor, not the
  web server. t/lint/274 asks the code for each fact.
- SM1256 (2266ca2b) **the Hestia integrator takes the certified channel.** `lazysite-hestia-domain
  add --channel certified` was refused ("must be 'edge', 'beta' or 'stable'") although ADR 0010
  added the rung and `lazysite provision`, which the integrator passes the value to, accepts it.
  The check, the usage and the POD take all four. t/tools/212.
- SM1259 (0e667758) **a certified cut gets past the manifest build.** `release.sh --certified`
  passes `--channel certified` to `build-manifest.pl`, which accepted only edge, beta and stable and
  died, so the first certified cut would have stopped there. It takes the fourth rung (ADR 0010);
  an unknown channel is still refused. t/tools/213.
- SM1260 (585f16bf) **a site can be put on the certified channel from the manager.** config-set
  (the Config page and the control API) refused `update_channel: certified`, and the page did not
  offer it, though ADR 0010 says a site that requires certification sets exactly that and the
  installer honours it. Both take it now. Every other channel validator in the tree was checked:
  install.pl and the CLI already took it (now pinned), and SM1256 and SM1259 fixed the Hestia
  integrator and the manifest build. t/unit/manager/17, t/tools/215.
- SM1264 (f0c55990) **validate_page warns on a form rule the renderer ignores, in every form.** An
  unknown `key:value` (`maxx:5`, `capture:front`) was passed silently, and only a page's first
  `::: form` block was read. Both are reported now as warnings that never block a save
  (`unknown-form-rule`, `pattern-will-not-compile`, a later block's messages naming its number);
  `invalid-form-rule` and `uncompilable-pattern` still block exactly what they blocked. The
  valued rules are read by a marked copy of the renderer's, held to it by t/lint/276.
  t/unit/lib/206, t/unit/mcp/01.

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
