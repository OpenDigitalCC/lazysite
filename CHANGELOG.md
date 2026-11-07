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

- SM1369 (PENDING) **X2: an extension declares its capabilities and its control-API
  and MCP actions, and core carries them from the index (H-7, H-9; rulings 71, 135).**
  `owns.hooks` gains three live kinds: `capability_info` (each owned capability's
  section, grid label, title, grant sentence, UI unlocks and what tops it up),
  `api_actions` (one row per action in `%ACTION`'s shape, with its gate, its MCP twin's
  description and input schema, and the handler in the payload lib) and
  `refusal_kinds`. The extension index gains a `declared` view, built from every
  installed extension's descriptor by the same validation, and a fresh install builds
  the index as the upgrade does (ruling 166) (a row without a gate, an
  ALWAYS row without its reason, a name not prefixed by the extension's id, a core
  name shadowed, an owned capability nobody describes, a twin requiring what the
  action does not: each refused by name, and the extension is not enabled). One
  mirror fills `@CAP_KEYS`, the capability map, `%GATE`/`%ACTION` and the refusal
  statuses from it, once per process; the manager API and MCP dispatch a declared
  action through one table-driven branch to the extension's handler, through the X1
  loader, so an extension that is off answers "this extension is off" and the tool
  listing does not change with the toggle. Odoo's ten actions, its refusal kinds and
  its two capabilities are its own declaration now; the wire is held to a 0.16.7
  capture (t/unit/odoo/136). Ruling 71: `manage_odoo` is the extension's admin
  capability (status, calls, the keys; the binding override); every group holding
  manage_connectors is topped up with it by the upgrade (ruling 167: one line naming
  the groups, a 0 an operator set stays; `lazysite-users.pl capability-top-up`) and on
  next use. The parity lints read the merged
  table; the Groups and Users grids draw a declared capability from served labels;
  `lazysite check` reads the index's capabilities and reports a failed build or an
  enabled extension whose hooks are not indexed. Lint 321's allow-list falls from 42
  files to 34.
- SM1369 (PENDING) **Page sources and delivery handler types are declared by the
  extension (X3: H-2, H-3).** An enabled extension's `owns.hooks.page_sources` gives a page
  variable a prefix that core resolves by calling the extension's own code from its payload
  lib through the hook index; `per_viewer` marks such a page as never cached for another
  viewer (it replaces the three `odoo-identity:` peeks), `live` sets the live-source flag
  as `url:` does, `check` adds issues at the page's save. Core hands a source no session
  credential unless it declared `per_viewer`, makes every value inert, and renders a
  source that dies or answers nothing as the empty string with one WARN line. An
  extension's `owns.hooks.handler_types` puts a type in the handler catalogue with its
  label, cap, schema and `origins`; core runs its `parse` and `on_save` at save,
  `on_delete` at delete and `deliver` from a form or the timer, and keeps handlers.conf,
  the schema check, the cap gate, the schedule and the delivery record; a delivery from an
  origin the type did not list is refused by core. The `address_profiles` schema field type
  lets the address-profile check find the profiles a handler names by the field's type
  and slot, whichever type carries them. Odoo's `odoo:` and `odoo-identity:` sources and
  its handler type move onto the hooks (`Lazysite::Odoo::Hooks`); its bindings, page
  variables, refusals and handlers.conf rows are unchanged, and lint 321's allow-list
  loses seven files. The hook index is rebuilt on every upgrade, so a site using Odoo
  gets its hooks indexed by the upgrade; `odoo-identity:` needs the Odoo extension on, as
  `odoo:` always did. Tests: t/unit/extensions/79, 73. Register entry drafted.
- SM1369 (PENDING) **An extension declares its assets, components and template
  variables (X5, the asset part of H-10).** Three hook kinds go live in
  `Lazysite::Extensions::Hooks`: `assets` (a file in the payload, served at
  `/assets/<id>-<file>` and at a declared alias on every domain, injected into a page
  whose markup carries the attribute `inject_when` names, with the data attributes an
  `attrs` function answers), `components` (a `::: name` component in the payload's
  `templates/components`) and `template_vars` (a layout variable rendered by the
  extension's function when a template names it). The index build refuses a file not in
  the payload; a new processor part, `lazysite-processor/extensions.pm`, reads the
  index module-free and the enabled list again. Odoo declares its helper (alias
  `/assets/lazysite-odoo.js`, the display name on the tag), `odoo-signin.tt`,
  `odoo_signin_banner` and `odoo_display_name`; the helper and the component move into
  `extensions/odoo/` and the four core lines that knew them leave (lint 321: 39 files).
  With the extension off, the helper is neither injected nor served. New:
  t/unit/extensions/76; t/integration/174, 171 and 172 build the index as the manager
  would.

- SM1396 (PENDING) **The offline kit is an engine extension, `app-offline`.** Ruling 53,
  built on the asset hooks as their second consumer (ruling 74): one declared script
  (`/assets/app-offline-kit.js`) and one variable, `[% app_offline_kit %]`, the tag while
  the extension is on and nothing otherwise; `requires: odoo`. The kit wraps the Odoo
  helper: a connection banner, kept reads (the last good answer, given when a read fails
  for want of a network), a write guard and queue (a change made offline or cut off is
  queued and sent once with its `Idempotency-Key`, so a resend never writes twice),
  install and update status, and sign-out. What the browser keeps is owned by login:
  `?csrf=1` answers `owner`, a label of the login, and an item with no owner is dropped.
  The kit needs the Odoo site sign-in (`odoo_site_signin: on`): `owner` comes from the
  site session's `odoo:<login>`, the identity cookie carries no label of the login, and
  on a default Odoo site the kit keeps nothing (rulings 161, 163). Slots
  `data-ls-app-banner`, `-show-out`, `-show-in`, `-status`; docs under /docs/app and in
  the layouts briefing. New: t/unit/extensions/77, 78 (a 127.0.0.1 endpoint stand-in);
  t/unit/odoo/28, 41, 63.

- SM1397 (PENDING) **A site with no favicon answers with the engine's.** `/favicon.ico`
  and `/favicon.svg` that reach the engine on a site with no such file are answered with
  a small neutral mark (an SVG, and a real 16x16 ICO), cacheable for an hour; a file the
  site has wins. t/unit/processor/181.

- SM1398 (PENDING) **`page_url_raw`, the raw twin of `page_url`** for JSON-LD through
  `| json`, under the SM824 contract. t/unit/processor/144.

- Docs: SM1399 (the engine's template filters testable from outside a checkout) recorded
  as a candidate.
- SM1404 (PENDING) **A listing carries no entry named after a rule's address profile (triage
  T-93).** On 0.16.6 an operator's `list_files /zz78-addr` showed, beside the page, an entry
  named after the folder rule's address profile with no type. Reproduced on a scratch site:
  what wrote it is SM1139's `address_profiles` (the permissions editor's picker choices, a
  list of `{ name }`), which `Manager::Files::action_list` returned on every listing answer,
  so over MCP it sat next to `entries`. The choices now ride on the manager API's listing
  only (`pickers`, the Files page being their one reader); MCP `list_files` asks without
  them. `acl-get` carries them as before. `t/unit/manager/477`.

- SM1400 (PENDING) **A layout's backup snapshot is not a layout (triage T-87).** `delete_layout`
  (and an activate) keeps `<name>-backup-<stamp>` beside the layouts, and the listing every
  door draws installed layouts and themes from (`themes-list-all`: the Appearance page, MCP
  `list_themes`, the control API) walked every directory under `layouts/`, so the snapshot
  came back as a layout of its own with the deleted layout's theme under it, and a second
  delete removed it. The listing now leaves every snapshot out of `themes` and lists it under
  `backups` (`artifact`, `layout`, `name`, `path`, the path `artifact-backups-delete` takes); the
  Appearance page's Backups panel draws that list. `layouts-available` and the catalogue
  annotation already left snapshots out. `t/unit/manager/476`.

## 0.16.7 - EDGE: Odoo's modules move into the extension's own lib, a stale Odoo session is renewed, and a group is deleted on every door (2026-11-07)

- SM1394 (def213ea) **docs: the compliance records cover 0.16.7.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against the 0.16.7 stack and stamped 0.16.7. The seven
  register entries the branches wrote are walked against the code, each gaining a "walked"
  note: SM1383 is confirmed (ruling 146); SM1381's new-external-interface (the renewal
  step, a tokenless GET on the Odoo endpoint) is confirmed contained (ruling 150) and
  the five with no trigger are confirmed (ruling 149; SM1387's new action on an existing
  door is not a new interface, ruling 151; SM1392's listing, ruling 152), SM1390 a
  hardening by ruling 147, so 0.16.7 is edge and not security-critical (ruling 149).
  Written at the walk and confirmed by the release manager (ruling 149): an entry for
  SM1385, SM1389 and SM1391, trust boundary 12 restated for Odoo's payload lib and the
  renewal step and four STRIDE rows, with four operate-side rows. UPGRADE.md's 0.16.7 notes are one section. Docs
  only; nothing is signed.

- SM1369 (525674a3) **Odoo's modules move out of core's lib into the extension's own (X7,
  part one).** Ruling 135: a hook may name only a module in its extension's payload lib, so
  `Lazysite::Odoo`, its twelve `Lazysite::Odoo::*` modules and the oomd and warm-endpoint
  services move from `lib/` to `extensions/odoo/lib/` before X2. Their names do not change.
  They still ship in the same package and install, and every URL, cgi-bin link, asset,
  conf key, store, cookie, action, MCP tool, capability and the oomd socket stay as they
  are. Core reaches them through `Lazysite::Extensions::require_payload`, which loads the
  copy beside core's own lib by the X1 rule and refuses one found anywhere else. An
  upgrade lays the payload out, removes the old copies and the directories they emptied,
  and rebuilds the hook index. Lint 321's allow-list is 42 files. The tests and the OOM
  snapshot stay in `t/` until 0.16.9. New: t/lint/335, t/unit/extensions/75, and the
  upgrade journey t/tools/335.

- SM1381 (525674a3) **A site session that is only stale is renewed on the way to the
  page.** A person signed in through Odoo and idle past `odoo_identity_ttl` was sent to
  `/login` by every protected page, and `/login`'s `?action=session` said they were signed
  out, although their Odoo session was still good. The page gate now sends such a session
  to a renewal step on the Odoo endpoint (`?renew=1&next=`). The step asks Odoo once and
  returns the person to the page. If Odoo has ended the session, it sends them to `/login`
  with `next` kept (a site's own `auth_redirect` page where one is set). `?action=session` goes through the same step. A cookie,
  `lzs_renewed`, guards against a loop: one renewal a minute, then the sign-in. The
  refusal is logged at INFO. t/unit/odoo/135.

- SM1382 (3ba0fc2e) **docs: live data is a scheduled connector answer in a table row
  (ruling 132, B).** A spike, `t/integration/360`, proves the chain the docs claim on a
  scratch site against a JSON source on 127.0.0.1: schedule, connector handler, remote, a
  data-table row, a page or the data endpoint. The "Live data" section of
  `/docs/ai-briefing-building-sites` is the sanctioned recipe, with the limits the spike
  measured: a 300-second floor (an interval rounds up to a multiple of 300), fixed fields,
  one row per poll with the answer as text, `ttl:` the only freshness bound, `mode=live`
  inert, and the endpoint's unknown-parameter refusal. The `client` row of the data-tables
  binding modes is corrected: such a binding still reads rows at render. Filed beside it,
  as a candidate: SM1384, a connector cannot express a multi-step job protocol.

- SM1383 (3ba0fc2e) **docs: the session cookie is an external contract (ruling 132, E).**
  `docs/architecture/session-cookie-contract.md` states the `lazysite_auth` format an outside
  process on the same host verifies read-only: the signed `username:timestamp:sid:groups`
  payload and the legacy three-field variant, the key and how it is used, constant-time
  comparison, expiry, `revoked.json`, and fresh groups. `t/unit/auth/75` mints a cookie
  through the real sign-in and verifies it as the document says, agreeing with the engine.
  The format does not change silently. A `docs/SECURITY.md` entry is drafted; it records,
  for ruling, that the preview cookie's value verifies as a session for an account named
  `v1`; confirmed as contained (ruling 146).

- SM1390 (f333e366) **auth: another signed value is not a session, a future timestamp is
  refused, and the sliding reader is reachable (ruling 147).** Three gaps found at the
  SM1383 walk, closed as hardening. The session verifier refuses a payload whose first
  field is the preview cookie's marker `v1`, and the preview verifier refuses a payload
  without exactly five fields, so a value signed for one purpose no longer reads as the
  other. A session whose timestamp (or `seen` time) is more than 300 seconds ahead of the
  clock is refused; the contract document states the allowance. The payload is split to
  five fields, so the five-field sliding shape the reader was written for - unreachable
  behind a limit-4 split - is read as itself; nothing issues it. No account can be named
  by the marker: `lazysite-users.pl add`, `rename` and `account-create` (the manager's
  Users add and an import's approval go through add) and an import's `stage_accounts`
  refuse the name, saying why, from the verifier's constant; `lazysite check` names an
  account that already carries it. `t/unit/auth/76`, `t/integration/361`,
  `t/unit/users/71`, `t/tools/333`; a `docs/SECURITY.md` entry is drafted, confirmed
  (ruling 149).

- SM1391 (f333e366) **daemon: a schedule entry under the floor is recorded as refused,
  once (ruling 148).** A hand-written `every:` below 300 seconds in `schedule.conf` was
  passed over in silence. The first tick that meets it records a refusal against the
  entry in `lazysite/daemon/schedule-runs.json`, naming the value and the floor, and logs
  it; later ticks write nothing for it; raised to the floor it runs. `lazysite check`
  names each such entry with its value and the remedy. `t/unit/daemon/17`, `t/tools/332`.

- SM1389 (c8e13a54) **`lazysite check` no longer reports the protected-history repository as
  stray public copies.** The stray-copy walk read the whole private store, so the SM1324
  history repository (`<store>/lazysite/git`) matched the docroot's content-history repository
  at `lazysite/git` file for file (HEAD, config, refs, identical objects) and the 0.16.6 edge
  deploy reported the site NOT SERVICEABLE. The walk now skips that repository, found by
  `ProtectedHistory`'s own path helper. Only the repository: a layout a rule moved into the
  store's `lazysite/layouts` is content, and a copy beside it is still reported.

- SM1387 (4c81d959) **A group is deleted once nothing uses it, on every door.** No token or
  MCP surface deleted a group. `group-delete` (control API), `delete_group` (MCP) and the
  manager's Groups page (which now calls `group-delete`) need `manage_users`, are audited
  (`@group`), and are refused while the group holds a member or anything names it - an access
  rule's `@group`, a page's `auth_groups`, a domain's `allowed_groups` or `locked_groups`
  (primary or alias), `auth_group_map`, a data table's `writable_by`, an Odoo binding's or a
  connector's `callers`, `odoo_group_map` - the refusal naming each (`kind: in-use`, with
  `members` or `references`). The walk is `Lazysite::Auth::GroupRefs`, asked by the users tool
  for every caller. The operator group is never deleted, the only one or not; an empty agent
  role (SM1371) or shipped role may be (`reset-groups` restores a shipped one). A
  domain-confined caller deletes only a group it created with `group-set`.

- SM1388 (6675f612) **A folder rule's history needs the folder to exist, and says so.** A rule
  with `history: true` (SM1324) is refused until its folder exists in the document root or the
  private store. The refusal said "'X' is not a folder", which read as a file; for a folder not
  there yet it now says it does not exist and to create it first. The protected-history docs
  (OPERATOR.md, the access-control model) say so.

- SM1386 (0db996a7) **A theme install warns when its stylesheets are outside assets/.** Only a
  theme's `assets/` is served, so a zip with `main.css` at its root beside `theme.json`
  installed and previewed with no CSS. Every install door - `theme-upload` (the manager's
  Upload Theme), MCP `install_theme`, and the layout installs (`layouts-install`,
  `layout-install`, MCP `install_layout`) - now installs such a theme with a warning naming
  each stylesheet and where it belongs (`warnings`; `theme_warnings` for `layout-install`).
  Warned, never refused. The themes doc's on-disk picture put `main.css` beside
  `theme.json`; it now shows it in `assets/`.

- SM1385 (51cd54d4) **A theme is deleted by its path, under any layout.** `delete_theme`
  (MCP), `theme-delete` (control API) and the manager's Themes page found a theme only under
  the active layout (D013), so one under any other layout was removable only file by file.
  Each now takes `lazysite/layouts/<layout>/themes/<name>` as `theme-copy` does (SM1339); the
  bare name still means the active layout's theme. The active theme, a theme any domain
  serves, and a theme another account made (over MCP or a token) are refused by path as by
  name; a path into a served copy is refused naming its source. The Themes page offers
  Delete under every layout.

- SM1393 (29586984) **The agent roles and the shipped bundles reach a site the `seeded` mark
  never reached.** SM1371's four agent roles, and the bundles SM1241 and SM1262 adopt on an
  existing site, were adopted only where some group record carried `seeded`. A site
  bootstrapped before SM608 wrote the mark, or whose manager group the conf migration wrote
  without it, carries it on no record and adopted nothing from any release, for ever: the
  0.16.6 edge site had loaded its Users page many times and had neither. Now a bootstrapped
  site (a manager group is there) adopts once, on the next Users or Groups page load or any
  other use of the users tool that reads the group store; the CLI `groups` listing does not.
  Whether the store carries the mark is read from the manager group, which no adoption
  touches: where it does, an unmarked record is operator-made as SM608 reads it; where it
  does not, a group present under its shipped name is what the store can say. SM1262's record
  keeps the rest: a deleted role or bundle never returns, an unreadable record adopts nothing.

- SM1392 (1f018409) **The manager's editor opens a form's own conf to `manage_forms`, and every
  door names that capability for it.** SM1371 opened `lazysite/forms/<name>.conf` to
  `manage_forms` over MCP, WebDAV and the control API's read and save, but the editor page
  marked every `lazysite/` path "system file (read-only)" before asking the server. The editor
  now exempts a form's own conf (never `smtp.conf`, `handlers.conf` or `schedule.conf`); the
  server's gate decides, and a manager without `manage_forms` sees its refusal naming the
  capability. Over MCP, `read_file` and `write_file` on that path ask `manage_forms`, the
  path's own capability, in place of `manage_content` - as a layout path asks the design
  capabilities - so a caller without it is told what it needs, and one holding `manage_forms`
  alone reaches the file as it has over WebDAV since 0.8.1. Every other path keeps the tool's
  capability. Ruling 152: such a grant is also OFFERED the two tools, each saying it reaches a
  form's own configuration and nothing else - the tools declare it (`cap_path`), and the gate,
  the listing, whoami's `tools_by_reach` (now with `path_only_reach`) and the capability map
  read that one declaration; no other tool or path shape is offered to a path grant.

## 0.16.6 - EDGE: the primary site's content leaves out the other domains, agents hold roles, and extensions can declare hooks (2026-11-07)

- SM1380 (0e503772) **docs: the compliance records cover 0.16.6.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against the 0.16.6 stack and stamped 0.16.6. The ten register
  entries the branches wrote, each confirmed by the release manager (rulings 134, 140), are
  walked against the code; SM1369's new-external-interface and SM1362's
  new-processing-of-restricted-data are their triggers' assessments, contained. Written at
  the walk and confirmed by the release manager (ruling 142): an entry for SM1375 and
  SM1378, trust boundary 15 (an extension's code in a core process) and three STRIDE rows,
  with four operate-side rows. 0.16.6 is edge, not security-critical (ruling 142). Found at the walk: the 403 page's group names were not escaped by the
  stash; escaped in 0.16.6 under SM1375 (ruling 141). SM1373, SM1374 and SM1375 gain their filings;
  UPGRADE.md's 0.16.6 notes are one section. Nothing is signed. One fix found at the walk,
  from the 0.16.5 edge deploy: the upgrade's template-call rename (SM1345) walked the private
  store with a plain File::Find, so a directory it could not read printed a raw "Can't
  opendir(...): Permission denied" and its old `visitor.in_list` / `visitor.in_any` calls
  were left unrenamed with nothing in the summary. `install.pl` now collects the walk's
  warnings, as `lazysite check` does (Q16g), and says once, under ADDRESS PROFILES, which
  directories it could not read, that any old call below them was not renamed, and to run the
  upgrade again as root or the site's owner; the step is then not recorded, so the next
  upgrade tries again.

- SM1379 (94fc2820) **A form's quarantine leaves email fields out of the repetition rule and
  quarantines a probe in one.** Ruling 133: "every field holds the same value" (SM913)
  counted the email field, so a random address defeated it; email fields (named so, or
  holding only an address) are now left out. An email field holding quotes, an
  SQL comment or SQL-shaped text quarantines the submission, the reason naming the field;
  one apostrophe in an address's local part (`o'brien@example.org`) passes (ruling 138).
  Quarantined, never refused. Register entry confirmed (ruling 140).

- SM1378 (e38805a8) **A layout says the engine it needs, and installing or activating it on an
  older one warns.** Ruling 133: `requires.lazysite` in `layout.json`, which the layouts
  catalogue writes in every layout, was read nowhere. Installing a layout, activating it, or
  binding it to a domain now compares it with the site's engine version and, when the engine
  is older, answers with `requires` and a `warning` naming both versions - as SM337 does for
  a layout with no `[% nav %]`. It goes ahead either way.

- SM1377 (478aafdb) **The data endpoint refuses a query parameter it does not read.** Ruling
  131: `/cgi-bin/lazysite-data.pl` named an unknown parameter (`ignored`, a warning) and
  still answered every row, so `?table=t&chunk=AAA` looked like a filtered answer. It now
  answers 400 with `kind: unknown-parameter`, naming the parameter and the four it reads
  (`order_by`, `order`, `limit`, `offset`). `_`, a cache-buster, is accepted and unread;
  `table` and `csrf` are unchanged. The `ignored` field is gone. Supersedes SM606 in part.
  Ruling 139: the control API's `data-rows` refuses an unknown parameter the same way
  (it reads `table`, `order_by`, `order`, `limit`, `offset`; `_` and `csrf_token` are
  accepted). UPGRADE.md says who is affected. Register entry confirmed (ruling 140).

- SM1372 (7fdd5ade) **The primary site's content leaves out the other domains' folders.** Ruling
  126: an account given nothing, or granted the primary's row, read the whole document root
  as its content, and so reached every secondary domain's folder (`sites/...`) through it.
  Now the primary's content is the document root less the other domains' content roots, on
  WebDAV, MCP, the control API and the manager's Files, and the refusal names the folder and
  how to grant it. Ruling 137: a listing (the manager's Files, MCP `list_files`, WebDAV
  PROPFIND) leaves those folders out too, for a caller refused them. The operator (a member of the operator group) and an account granted a domain keep that
  reach. UPGRADE.md says how to give an account the domain it relied on. Register entry confirmed (ruling 140).

- SM1362 (a467caee) **A form tells the site's owner by email, and can answer the submitter.**
  Ruling 123 re-scoped the filing: a bare form already saves (the shipped local-storage
  handler). `owner_contact:` in `lazysite/notify.conf` names one address, and each form's
  notice is also mailed there through the existing notice mail (the Form SMTP extension,
  `mail.per_hour`); it follows the notice (not on `notify: off`, not for a quarantined
  submission, the fields only on `notify: full`). A form's conf can opt in to an
  acknowledgement with `acknowledge_field` and `acknowledge_message` (and
  `acknowledge_subject`): the form's own words, never the visitor's text, mailed to the
  address in that field under the email handler's caps (3 an hour per address, 60 per
  site, counted together). Register entry confirmed (ruling 140): the owner notice under `notify: full` fires ADR 0007's new-processing-of-restricted-data, contained.

- SM1366 (75447078) **An Odoo call's record names the signed-in account.** A call made under a
  person's Odoo session was recorded, and written to the audit log, as `session:<hash>`
  alone, so an operator could not tell who acted. Where the request is signed in to the site
  (a local account, or `odoo:<login>`), the record's `actor` and the audit line name that
  account, and the hash is kept beside it (`session` on the record, `session=` on the audit
  row). With no site identity the hash is the actor, as before. Who owns a plan is unchanged,
  a refused sign-in keeps its login hash, and no session id or typed login is written.

- SM1374 (50da6727) **A plan Odoo refused tells the visitor why, in Odoo's words or plainly.** An
  Odoo plan that failed at Odoo answered "the plan did not apply completely - see the
  counts", an operator's sentence. When Odoo refused the data (a validation or user error)
  the answer's `error` is now Odoo's own message, without the "Odoo Server Error:" prefix,
  and the change says `validation: 1`; any other failure answers "The change was not saved.
  Try again, or tell the site's operator." and its text is withheld from the change too,
  since an access error or a missing record names models, groups and ids. A refusal the
  operation itself raises keeps its sentence. The counts stay in the result, the journal
  and a log line for the operator. A change whose answer never came is unchanged.

- SM1373 (2e379ccf) **An extension's settings read answers only its own keys.** `extension-read`
  for an extension kept in `lazysite.conf` (bad-url-blocker, log) answered every key in the
  site's main config, and one with its own file any key its schema does not name; only its
  own password fields were dropped. It now answers the keys the extension's `config_schema`
  or `config_keys` names, whatever its file. The action is reachable by a manager session
  with `manage_config` only (no token reaches it). Register entry confirmed (ruling 140).

- SM1375 (b9add76d) **The 403 page lists the groups a page needs.** The shipped `403.md` named
  them as "- reviewers" lines run into one paragraph, on a front-matter group gate and on an
  ACL read-list refusal alike: Markdown reads the page before Template Toolkit fills it, and
  the loop's directive line kept the list from starting. The template writes the list as
  HTML, so the groups render as a list. A site with its own `403.md` is unchanged. Ruling
  141: the group names are HTML-escaped where the stash is built, as SM709 escapes the other
  auth values; a read list naming a group with markup rendered it as markup on the page.
  A hardening (only an account that can write a page's markup writes a read list's names).
  Register entry confirmed (ruling 141).

- SM1370 (68c433d3) **A token follows its account's grant (ruling 121).** Measured first: no
  token door fixes a capability into a credential - an lzs_ token verifies through
  `verify_credential` and `caps_for` at each request, an OAuth token resolves its partner
  through `partner-caps` at each call, WebDAV asks once per CGI process. So a grant added at
  the account reaches an existing token on its next request, one removed is refused at once,
  and a token confined to a domain stays confined when the account widens; t/unit/manager/460
  now holds that on the control API, MCP bearer and MCP OAuth. Both whoamis carry a `grant`
  block saying so, with the remedy for a client whose tool list predates the grant (list the
  tools again; no new pairing key). The layouts briefing stops advising a token rotation.

- SM1371 (7e0906da) **Agent accounts hold roles (ruling 122).** Four agent roles ship as
  assignable groups (ADR 0003): `content-agent`, `data-agent`, `forms-reader` and
  `analytics-agent`, each one job over MCP, and an existing site adopts them once, with no
  members. `whoami` (both doors) and the Users page name the roles an account holds and any
  capability beyond them (`Auth::Settings::role_summary`). Ticking a grant whose extension is
  off offers the enable in the same step, through the audited `extension-enable`.
  `manage_forms` now reads and writes a form's own `lazysite/forms/<name>.conf` through MCP
  `read_file`/`write_file` and the manager's file editor, as WebDAV has since 0.8.1, with
  WebDAV's binding rules; `smtp.conf`, `handlers.conf` and `schedule.conf` stay closed.

- SM1369 (767cc0fc) **Extension hooks, slices X0 and X1 (ruling 55): core names no extension,
  and finds an extension's hooks in an index.** X0: `t/lint/321` fails a new core line that
  names Odoo (odoo, OOM, oomd; ruling 136 counts Odoo's names only); the 43 files that do today
  are an allow-list that may only shrink, and X7 empties it. X1: an extension's `owns` may declare `hooks` and
  `requires`, validated by the new `Lazysite::Extensions::Hooks` before anything is indexed. The
  manager writes `lazysite/extensions.index.json` from the enabled extensions on enable,
  disable and save, and the upgrade rebuilds it. `Hooks::call_hook` runs an indexed function
  from the extension's own payload lib (`extensions/<stem>/lib`), only while the extension and
  what it requires are on. Enabling an extension whose `requires` names one that is off is
  refused by name. No hook kind is live yet: a declaration of one is refused, naming the slice
  that builds it (X2 to X8 are to come). A site whose extensions declare no hooks has no index
  and behaves as before.

## 0.16.5 - EDGE: address lists become address profiles, a theme's copies follow its source, and protected folders may keep a history (2026-11-06)

- SM1368 (e88a6e54) **docs: the compliance records cover 0.16.5.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against the 0.16.5 stack's ten branches and stamped 0.16.5. The
  four register entries the branches wrote are walked, and two of them (SM1324's protected
  history, SM1325's read audit) are found to fire ADR 0007's new-processing-of-restricted-data
  trigger, which each entry now records as that trigger's assessment. Two entries are drafted
  at the walk (a theme's served copies; the rest of 0.16.5), with two STRIDE rows (a theme's
  source re-mirrored on every write; the bad-URL blocker's loopback exemption behind a front
  end `trusted_proxies` does not cover), the architecture notes, two operate-side rows and
  UPGRADE.md's 0.16.5 entry. All six entries are for the release manager's confirmation.
  Docs only; nothing is signed.

- SM1365 (f07f1559) **A page refused by an ACL read list gets the site's 403.** A signed-in
  visitor outside an `auth/acls.json` read list who opened a page in the governed directory
  got a bare 103-byte 403 with no layout or theme. They now get the site's 403 page, which
  says who is signed in and names the list's groups (never a user on it), as a front-matter
  group gate does. An image, a PDF or a download keeps the short 403, with the security
  headers. A draft section is still 404 and an anonymous visitor is still sent to sign in.

- SM1339 (c377650a) **A served copy of a theme says so, and is not written.** Ruling 81: a write
  into a host's `/lazysite-assets/<layout>/<theme>/` (the docroot's or a domain's own) is
  refused on every surface - the manager, the control API, MCP `write_file`, `upload_file`,
  `move_file`, `delete_file`, and WebDAV PUT, MKCOL, DELETE, MOVE and a COPY's destination -
  for the operator too, naming the source path to write instead, since the copy is replaced
  whole at the source's next write and reaches no other host. Reading a copy, copying out of
  one and removing the copy of a theme no longer installed are not refused. `list_files` and
  the Files page mark each copy `served_copy`, with its `source` and the hosts that serve it
  (`served_by`, each with `theme_active`). Ruling 109: the theme a secondary domain serves as
  its own is read-only on every surface as the primary's is, the refusal naming the domain and
  copy, edit, activate with `host`; ruling 120: and so is the layout it serves as its own, a
  layout only pages pin staying writable. `theme-copy` and `copy_theme` take the theme by its path,
  `lazysite/layouts/<layout>/themes/<theme>`, as well as by its name.

- SM1336 (b9e9a3eb) **Every served copy of a theme carries its tokens and its version.** Ruling
  81: an installed theme (Upload Theme, `install_theme`) and a copied theme (`theme-copy`,
  `copy_theme`) had their copy built by hand, with no `theme-tokens.css`, no fingerprint (SM830)
  and no copy on a secondary domain. Both now write it the one way every copy is written.

- SM1335 (0a090fb9) **A theme's copies follow its source.** Ruling 81: a write to a theme's
  source, on any surface, re-mirrors that theme to every host's copy (the docroot's and each
  content root's) and drops the cached pages that use it, a page pinning it by `theme:`
  included; a write to a layout's own files drops the pages that use the layout. An edit to an
  inactive theme reaches the pages that pin it with no activation, and a secondary domain's
  copy is no longer the one written at the theme's creation; a host whose copy is missing gets
  it at the next write (ruling 111). One theme per write, never the
  site's; a link or a server-run file in a theme's `assets/` is not copied into any copy.

- SM1342 (b0ea8aa0) **A /docs anchor lands on its heading.** The manual wrote its section
  links as GitHub writes them (`#the-docs-manual`), and the engine's converter ids a
  heading with no hyphens for spaces (`#thedocsmanual`), so eight links in the shipped
  manual landed at the top of their page. They are written in the engine's form, and
  t/lint/310 holds every anchor in a /docs link to a heading of the page it names.

- SM1341 (48ff1a2e) **Each AI doc says it once, and says who it is for.** An owner following
  the docs met the connect steps on two shipped pages, authentication, endpoints and the
  grant model on two more, and the layouts machinery on two that did not link each other.
  Each now has one home: the client steps, endpoints, connection modes and authentication
  in Connect an AI assistant, which is now public so a client can read it before it holds
  a credential (Onboard links it); capabilities and denied paths in the signed-in tools
  reference (the publishing briefing points at each, and `.well-known/ai-partner` lists
  the setup page among its docs); the layouts model, installing and
  switching in /docs/layouts and what an agent needs to change them in the layouts
  briefing, linked both ways. Every page of the set opens with "Who this is for", and the
  docs index is by reader (operator, agent, developer), then theme, and lists the Figma
  integration. Facts moved, none dropped. Rulings 80, 113, 115.

- SM1340 (0ec7149b) **The layouts docs point at the site's design guide.** The engine's
  `/docs/layouts` and `/docs/ai-briefing-layouts` are the same on every site, so they could
  not name the guide a site publishes for whoever designs for it, and an agent starting from
  the docs never found it. `design_guide: /path` in `lazysite.conf` makes both pages open
  with a "This site's design guide" line linking it; unset, they carry nothing. Only a
  same-site path counts, under the rule `?next=` is held to; a full URL or anything
  malformed is ignored. A domain names its own with `alias.<host>.design_guide`, which
  overrides the site's for that host; without one it uses the site's, except a domain
  with its own content root, which shows no line. Rulings 79, 114.

- SM1322 (9de880fb) **/login asks the server whether the session is honoured.** It judged
  "signed in" from the `lzs_session` display marker alone, which outlives a revoked or
  expired session and an Odoo session gone stale, so it told a visitor the site had just
  refused "You are already signed in" and hid the form. The panel now carries
  `data-ls-auth-check`, and the chrome script asks the new
  `/cgi-bin/lazysite-auth.pl?action=session` (yes or no, uncached, from the verdict every
  surface uses). A no clears the marker and shows the sign-in; no answer leaves the page as
  it was. A session it does honour is offered "Sign in as someone else": the sign-out with
  `then=signin`, which revokes the session and lands back on the form with the page's
  `?next=`. A site with its own `login.md` adds both to its panel. Ruled 2026-11-04 (ruling
  49) and 2026-11-05 (ruling 85).

- SM1321 (a4bb88f4) **The bad-URL blocker spares the site's own files and exempt addresses.**
  `vendor/` is a probe pattern and also where a theme keeps its scripts. The blocker counted a
  site's own assets, and behind a front proxy every visitor was 127.0.0.1, so everyone got 403
  for 1 h 44 min. A path that resolves to a regular file under the docroot is never counted now
  (plain segments only: no `..`, no symbolic link on the way, no dot name, not the engine
  tree). Loopback (127.0.0.0/8, ::1) is always exempt: never counted or refused, a block on
  file included. The new `bad_url_exempt` key names address profiles (SM1343) whose addresses are
  exempt too, in addition to loopback; only the value `none` removes loopback. It takes
  profile names only: the Config page refuses an address or a profile that does not exist,
  `lazysite check` warns about one, and a profile it names counts as in use. Ruled 2026-11-04 (ruling 48) and
  2026-11-05 (rulings 83, 84).

- SM1345 (d597045c) **The upgrade turns each address list into an address profile, and no
  site changes behaviour.** The request's A-4: once, install.pl converts
  `lazysite/auth/address-lists.json` to `address-profiles.json`, the same names and entries
  with no kind, keeps the old file as `address-lists.json.converted` and says what it
  converted. No rule is rewritten: every use already named its list in the slot the list's
  kind meant, so an allow list's uses are Allow uses and a deny list's Deny uses. A profile
  store already there is never overwritten, and an old store that will not decode is left for
  the operator, with every rule that names a profile refused until it is converted. The same
  step renames the site's `visitor.in_list` / `visitor.in_any` calls (pages, layouts, themes,
  templates, the private store) to `visitor.in_profile` / `visitor.in_any_profile`, naming each
  file. `lazysite check` names any old call left, and every rule whose slot is not its old
  list's kind (a hand edit only; it refused everyone before and now applies in its slot): run
  it after upgrading.

- SM1344 (8b2f4fb1) **The Files page limits a rule by address profile, each chosen Allow or
  Deny.** The request's A-3: the permissions card's "Limited by address" becomes "Limited by
  address profile", one row per profile with Not used, Allow or Deny, in place of the two
  pickers that offered only allow lists or only deny lists. A name the rule carries that the
  store does not hold keeps its choice and is marked, so saving the card does not drop it.
  The Groups page limits a group by address profile with the same picker, saved as one request
  (`address_limit`, both lists, one write), so a profile moved from Deny to Allow is never in
  neither list.

- SM1343 (06f14ed2) **Address lists are address profiles, allowed or denied where they are
  used.** The release manager's request (24 October 2026; rulings 56-58): a profile is a named
  set of IPv4 and IPv6 addresses and ranges with notes, and has no allow or deny kind. Each rule
  that names one chooses: `addresses` allows it and `addresses_deny` denies it, on a page, a file
  or folder rule, a group, the manager's and sign-in's keys and a session binding, so one office
  range can be allowed on one page and denied on another. Deny still wins, and a folder's and a
  page's rules must both admit. Renamed outright, with no aliases: the store is
  `auth/address-profiles.json`, the page Access, Address profiles, the actions
  `address-profiles`, `address-profile-set` and `address-profile-delete`, the MCP tool
  `list_address_profiles` and the users tool's commands the same; an old name is refused naming
  the new one, and a `kind` sent is refused by name. The template test is
  `visitor.in_profile` / `visitor.in_any_profile`; the old names are gone. A profile a rule names is still not deleted
  without a second confirmation. A site whose lists were never converted refuses every rule that
  names a profile, rather than letting its deny rules block nobody.

- SM1334 (2b713de4) **A group can pin its members to a domain.** Ruling 78: only a pin removes the
  other domains, for an account or a group. An account's pin is a domain's `locked_users`; a
  domain's new `locked_groups` pins every member of the groups it names the same way: they reach
  only the domains that lock them, of the ones they are granted. Set it on the Domains sheet
  (Groups locked to this domain, the primary's row included), with `domain-set`, MCP
  `domain_set` or `lazysite-domains.pl pin-add`/`pin-remove`; it needs `manage_users`, as the
  other access keys do. A pin on the primary confines to the primary. A group a request's address
  leaves out can no longer lift a pin: the request's domains are held inside the account's.

- SM1333 (51e65e01) **The primary is a row on every domain surface.** Ruling 78: the Domains page
  lists the primary as `(default)` with an Access sheet (groups allowed, users locked), and
  `domain-set` on the control API, MCP `domain_set` and `lazysite-domains.pl` (`--host '(default)'
  group-add` and the rest) take the host `(default)` for those two keys, writing the primary's
  bare lines; any other key on it is refused, naming Config. A secondary row no longer shows the
  primary's access as inherited, on either listing: a row's access is its own, as it always was
  where it is enforced. A group named only on the primary's row reaches the primary only, as on
  any row.

- SM1332 (e3ba5522) **A domain grant adds, and the primary can be granted.** Ruling 78: naming an
  account's group on a secondary domain took the primary site away from it, because the primary
  was reached only by having no scope at all, and there was no primary row to grant it back on.
  The primary's row now carries `allowed_groups` (the bare `allowed_groups:` line), and a grant
  there adds the primary (`dav_scopes` holds `/`) to the domains the account already has. An
  account granted nothing keeps the primary; only a lock removes the others. The one domain rule
  reads `/` as the primary only, never as the other domains' folders; WebDAV, MCP and the manager
  read it as the whole site, as for an unbound account; the refusal names the primary's row.
  Nothing changes at upgrade: an account scoped today keeps exactly its reach.

- SM1328 (a1c2adcd) **Odoo is shown by the name the site gives it.** Every dialog label and
  error text a visitor or a manager reads said "Odoo", with no way for a site to call its
  back office what its people call it. One setting, `odoo_display_name` in the Odoo
  extension's settings (default `Odoo`), is now said by the sign-in dialog, `/odoo-signin`
  and its button, `/login`'s link to it, the browser helper's messages, the errors the page
  endpoint answers and the Unknown Odoo writes panel. Empty, they name nothing, and each
  text is written to read whole without it ("Sign in", "That sign-in was not accepted").
  The extension's own name, its page, its daemon, its settings and the logs keep "Odoo".
  The setting has one reader, `Lazysite::Odoo::Name`. Ruled 2026-11-04 (ruling 52).

- SM1327 (60e395f4) **A write names the version it replaces.** MCP `write_file` saved with
  no modification time, which skips the save's conflict check, so an agent writing back a
  file it had read replaced whatever another writer saved in between. It takes an optional
  `base_mtime`, the `mtime` `read_file` answers (`read_page`'s `modified`): given and stale,
  nothing is written and the answer is a conflict (`kind: conflict`) naming the file's
  current `mtime`; a base for a file that no longer exists is refused the same way; absent,
  the write is what it was. `rename_page`'s alias and its link rewrite, which read a page
  and write it back, now save with the time they read, as `replace_text` does. The
  building-sites briefing says to write back with the version read. Ruled 2026-11-04
  (ruling 51, part (b)).

- SM1325 (1d94a533) **A site can audit the AI reads of its pages and files.** Ruling 50 (T-17):
  a successful read is kept off the audit trail (SM943). `audit_reads: on` in lazysite.conf
  records each successful MCP `read_file`, `read_page`, `view_version` and `preview_page`, and a
  token's control-API `git-show`, with the account, the path and the time, in a file of its
  own beside the trail, `logs/audit-reads.log` (ruling 97): rotated and forwarded as the trail
  is, and shown on the Audit page under Show: AI reads, so reads never push a change off the
  change view. Off by default, and a value other than on is off. A signed-in person's reads
  are not recorded. The Config page switches it (Record AI reads; `config-set`), and only for
  an account or token holding Site config AND the audit trail switch permission, the trail's
  own gate (ruling 96).

- SM1324 (9712a81b) **A protected folder can keep a history, by choice.** Ruling 50 (T-16):
  protected content is kept out of the content history, which may be pushed to a remote. A
  folder rule may now carry `history: true` (the manager's Keep history, `history` on the
  control API's `acl-set` and MCP `set_permissions`, `lazysite acl set --history`; whoever may
  set the rule may set it). The folder's versions are kept in a second repository whose work
  tree is the private store (`<store>/lazysite/git`, 02770), never the public one. Its first
  version is taken when it is set, and it records while the site's content history is on
  (ruling 98). It covers the rules nested in the folder unless one says `history: false`;
  a rule that says nothing inherits (ruling 100). Clearing it, or removing the rule, keeps
  what was recorded; `lazysite acl purge-history PATH --actor USER` deletes a folder's
  history from the repository and its object store, for the operator only, audited as
  `history-purge` (ruling 99). Every history read
  (`list_versions`, `view_version`, `restore_version`, `list_content_history` and the
  manager's history view) applies the file's read rule, and a restore its write rule. Off by
  default: a site that does not set it changes nothing and gets no repository. MCP
  `list_content_history` now passes the caller to the read rule, so it lists a protected
  file to its readers.

- SM1346 (1d2ed2c6) **lazysite is tested on OOM 0.44.** The pinned snapshot in
  `t/vendor/oom` moves from 0.42 to OOM 0.44 (f32c444), skipping 0.43, checked against
  the 0.44 debs. No lazysite code changes, and every Odoo test passes on it. For an
  operator on OOM 0.44: a binding may name the new operations (`core.user delete`, the
  Discuss pack) and `quiet` on `core.make`, `core.set` and `core.action`; what a page
  is told of a write Odoo did not keep, and of a refused record, is SM1347; the OOM deb
  needs libdatetime-perl and libdatetime-timezone-perl. SM747's spec is re-filed.
  t/lint/207, 261.
- SM1347 (2bb2d781) **A page is told what Odoo did not keep, and why a record was refused.**
  From OOM 0.44 a write whose value Odoo dropped or reset is still `done`; its entry in
  `result.changes` now names the fields (`not_kept`) and says so (`note`), never the
  values asked or found, and `result.not_verified` is passed (ruling 103). The browser
  helper draws each note into `<div data-ls-odoo-not-kept>`. The same for an immediate
  apply, a confirm and a resumed run's carried changes. A record the account may not
  read (`refused/access`) and one that is gone (`refused/missing`) each have their own
  sentence, where both said "refused before Odoo answered" (ruling 104); the kind stays
  `refused`. t/unit/odoo/122, 123, 124.
- SM1330 (34cbdace) **tests: the compatibility tier tests the OOM it names.**
  `tools/ext-compat.sh` failed every night on the installed deb and on OOM's tree for
  reasons in lazysite's harness: under `LAZYSITE_OOM_LIB` the host's `shop` pack claimed the
  suite's `shop.basket` (52 files), t/unit/odoo/78 expected the snapshot's data root, and the
  daemon tests started the snapshot's oomd, which loads the snapshot's OOM first. Each
  target now runs alone - its library, its oomd (`LAZYSITE_OOMD`), its own data and the
  suite's own operations, never the host's packs - and the FAIL line and the inbox note name
  the failing files, which prove's absolute paths had hidden. The gate is unchanged.

## 0.16.4 - EDGE: plugins become extensions, on disk, in lazysite.conf, in the manager and on the wire (2026-11-06)

- SM1367 (7db1a9a5) **docs: the compliance records cover 0.16.4.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against SM1142, the release's one change, and stamped 0.16.4.
  The register has a drafted entry for the rename, for the release manager's confirmation:
  the upgrade step that moves a site to `extensions/` and converts which extensions are on,
  and the wire's old spelling refused and its response keys renamed (ruling 95); no trigger
  fired. A STRIDE row, the architecture notes and an operate-side row for the references the
  upgrade cannot see, among them an audit filter on the old action names: the audit records
  the extension actions as `extension-*` from 0.16.4. Docs only; nothing is signed.

- SM1142 (95f3ab81) **A site from before the rename upgrades in place and behaves the same, and
  the docs say extension.** Slice S4. The docs, the `/docs` manual and briefings, the README
  and the skill say `extensions/`, `extensions:` and the new manager addresses; UPGRADE.md has
  the entry, with the hand-made references the upgrade cannot see (a crontab running
  `plugins/stats.pl`, a pipe to `plugins/form-smtp.pl`, a bookmark, a script on the old
  action spelling). The tests moved with the code (`t/unit/extensions/` and every test whose
  name said the old word). A journey test (t/journey/06) upgrades a pre-rename site and asks
  each deciding reader - the sign-in CGI's rate limiter, the data gate, the runtime's start
  gate, the notifier and the render path's registry and manager nav - what it sees: the same as
  before. History keeps its words (CHANGELOG, filings, reviews, FEATURES.md's timeline).

- SM1142 (4b35348f) **On Hestia the root-run scripts make `extensions/`, and clear the old
  directory.** Slice S3 (R4: no separate installer release ahead - the root-run deploy runs
  before the user-run install anyway). The domain root is mode 0551, so the site user cannot
  create a sibling of the docroot: the deploy now makes `extensions/` and hands it to the site
  user on every run, before the install, and after the install removes the old directory the
  upgrade emptied - only when empty, with rmdir. The lazysite-app template's hook and
  `lazysite-hestia-domain.pl` make `extensions/` for a new site. The deb ships
  `/usr/share/lazysite/extensions`; the installers' and packaging's words follow.

- SM1142 (739f693e) **The code says extension, and the old action spelling is answered with the
  new one.** Slice S2 (R5: "so that the namespace of plugin is fully free"). The modules are
  `Lazysite::Manager::Extensions` and `Lazysite::Extensions::Owns`, and the functions, the
  template variable (`enabled_extensions`), the manager's own scripts and styles and the
  internal action names follow. The wire's old spelling is removed: an old-spelling action
  answers unknown action naming its `extension-*` spelling, and the old `?<id>` parameter on
  extension-read, -save and -action and whoami's old catalogue switch are refused naming
  `extension` and `extensions`; the list's response key is `extensions` and groups-read's is
  `capability_extension`. The audit writes an extension action's row as `extension-*` from
  0.16.4 (earlier rows stay `plugin-*`), SM831's `spelling=deprecated` flag is gone with the
  old spelling, and a disabled extension's refusal logs as `extension-gate` (was
  `plugin-gate`): a filter or report on the old names matches nothing new. t/lint/307 holds the word to history, third-party names and the few
  places that must name the old spelling to convert or refuse it. ON UPGRADE: a script calling
  the old spelling must move to `extension-*` (SM1125's note); the sites agent has been told.

- SM1142 (f2f0749a) **The upgrade moves a site to `extensions/`, and nothing reads the old name
  after it.** Slice S1 of the rename (ruled 2026-10-17, R1 and R3: "fixup on upgrade, then its
  done"). The engine's extensions ship in `extensions/` (deb: `/usr/share/lazysite/extensions`)
  and a site's lazysite.conf lists them as `extensions/<file>.pl` under `extensions:`, the one
  header every reader and the writer now accept. A one-time upgrade step (`extensions-rename`)
  converts each site in place: it moves what is left in the old directory beside the docroot
  into `extensions/` (an edited copy of a shipped one is kept as `<file>.from-plugins` beside
  the release's), rewrites the list and its entries so every extension that was on stays on -
  login rate limiting among them - re-points a hand-made cgi-bin link, moves a start page on
  the Extensions page to its new address, removes the empty old directory, and says what it did
  in the upgrade summary. The manager pages are `/manager/extensions` and
  `/manager/extension-config`; the old addresses are not kept (R2). Eleven script lookups ask
  one resolver, `Lazysite::Extensions` (t/lint/306 refuses a twelfth), and `lazysite check`
  names a list or entry written back under the old name, by line. ON UPGRADE: check anything
  of your own that names the old directory - a crontab running `plugins/stats.pl`, a pipe to
  `plugins/form-smtp.pl`: they are `extensions/stats.pl` and `extensions/form-smtp.pl` now
  (UPGRADE.md lists them).

## 0.16.3 - EDGE: a confined agent stays in its scope, a rule inside another cannot widen it, and the /docs manual is the engine's (2026-11-06)

- SM1337 (2c3b663a) **docs: the compliance records cover 0.16.3.** OBLIGATIONS.md and
  TECHNICAL-FILE.md are walked against the 0.16.3 batch and stamped 0.16.3. The register
  records the release manager's acceptance of the SM1303, SM1308 and SM1309 entries
  (ruling 65), and one entry for the rest of 0.16.3 that moves a control, accepted too
  (ruling 93); SM1308 and SM1309 owe no Article 14 notice or advisory (ruling 94). The
  architecture notes and OPERATOR.md cover the confined walks, the widening refusal and
  SM1313's warning, the engine's /docs manual, the theme upload over MCP and the Odoo
  settle capability. Docs only; nothing is signed.

- SM1280 (9e591e18) **An Odoo operation is told whether the call came from an address list.**
  Ruling 3 (the OOM Lab's office-network clock-in): a binding names an `address_profile` and an
  `address_param` (a yes/no parameter), and its operation receives only 1 or 0 - never the
  address. The server decides it from the request's address behind `trusted_proxies`, and a page
  cannot set or override it. No address, an unknown list or an unreadable store is 0. The list
  counts as in use, so it is not deleted while the binding names it. The key is `address_profile`
  (ruling 58, ahead of address lists becoming address profiles); for now it names an address list.
- SM1277 (af65be3a) **The page shows an Odoo write whose answer never came.** Ruling 10b: the
  browser helper draws what a `write()` or `confirm()` left unknown into the page's
  `data-ls-odoo-unknown` element, as text, with Check again, and It was made / It was not made
  for each change only when the answer says the person may say. `LazysiteOdoo.resume` and
  `showUnknown` are there for a page that draws it itself.
- SM1278 (6ebdf225) **The manager lists, settles and dismisses an unknown Odoo run.** Rulings 10b
  and 10c: the Odoo extension's row on the Extensions page has Unknown Odoo writes, each open run
  with the changes still unknown, It was made / It was not made for a change, and Check again and
  Close run (a dismissal) for the run. Listing and dismissing need `settle_odoo_writes`; a dismissal sends
  nothing to Odoo, keeps who, when and why, and is one call record and one audit line. The
  control API and MCP have `odoo-unknown-runs`, `odoo-resume` and `odoo-dismiss` (and their
  twins).
- SM1279 (7ee5a892) **An unknown Odoo run is kept until it is settled or dismissed.** Ruling 10c:
  no expiry. The plan store's seven days, the daemon run folders' schedule and SM1162's purge
  of a spent plan's file bytes no longer reach a run left unknown and still open, since a resume
  reads its plan, its journal and the bytes of a change it sends again. Settled or dismissed, it
  goes on the ordinary schedule and its bytes go at once.
- SM1275 (fae8b33a) **An Odoo run that ended unknown is read back and settled.** Rulings 10a and
  10b, with OOM 0.42's resume: an apply that left a change unknown now names its run (`run`,
  the plan id; no path), and `POST {run, resume: true}` resumes it. OOM reads each unknown
  change back first (found made: done, never sent again; found not made: carried), then the
  rest of the run applies through the path a first apply takes, in-process or through oomd.
  A change no read can tell is refused `unknown-outcome` (409), naming it, until its maker or a
  holder of `settle_odoo_writes` says it was made (`assume_done`) or was not
  (`assume_not_done`). Anyone the binding admits may check again. A visitor never resumes a
  public binding's run. A confirm's token rule, the write caps, one call record and one audit
  line naming the run and the decision.
- SM1276 (e7e8bec7) **A capability settles an Odoo write whose answer never came.** Ruling 10a:
  where OOM cannot read a change back, the run's own maker or a holder of a new capability
  says whether it was made. `settle_odoo_writes` is declared by the Odoo extension, so it is
  grantable only where the extension is installed, and every operator group holds it: a new
  site's at once, an older site's by the SM645 top-up. A declined 0 stays declined.
- SM1291 (7a27f58f) **a theme installs from a zip over MCP, its fonts with it.** MCP
  `install_theme` (manage_themes) takes a theme's zip as base64 and installs it through the
  function the manager's Upload Theme uses, so the checks and refusals are the same ones -
  0.16.2's among them (SM1303): the site's upload limit, and no symbolic link or file type
  the web server runs. The audit row is theme-upload's, and the caller can `delete_theme`
  what it installed. From the lazysite.io site agent (K-5).

- SM1290 (6b7f53a3) **a page previews in a theme that is not active.** MCP `preview_page` takes
  `theme`: the page, or a draft, renders with that installed theme in place of the site's,
  the section's and the page's own, so a theme can be checked on real pages before it is
  activated. Nothing is activated, cached or written, and a theme not installed for the
  layout the page renders with is refused. It needs `manage_themes` or `manage_layouts` as
  well as `manage_content`, as the manager's theme preview does; the manager's page preview
  takes the same `theme`. From the lazysite.io site agent (K-4).

- SM1289 (f78375f8) **a form under any theme has base styles, and the theme overrides them.**
  Under a theme with no form rules (lumen, edge observation O-4) a stepped form's fields and
  buttons were the browser's own. `lazysite-chrome.css` now carries small base rules for the
  engine's forms - field spacing, full-width inputs, buttons in the page's font, the step
  fieldsets, the error line - each inside `:where()`, so its specificity is zero, and with no
  colour beyond `currentColor` and `inherit`. Any page with a form links them, with or without
  a layout; under a layout the link goes first in the head, so any theme rule about the same
  element wins. Ruling 30.

- SM1288 (ce8aa783) **the sign-in and search pages no longer override the theme.** The starter
  `/forgot.md` and `/search-results.md`, and the engine's login, forgot and claim pages, each
  opened with a `<style>` block that came after the theme's stylesheet, so on a themed site
  those pages wore the engine's buttons and grid. The blocks are gone and the same rules are in
  `lazysite-chrome.css` under `.lazysite-fallback`, as SM1251 did for the contact page: a site
  with no layout sees the same pages, and a themed site sees its theme. An upgrade refreshes a
  starter copy the site never changed and keeps one it did. Ruling 12.
- SM1299 (bd7d2da4) **the Odoo sign-in page returns the visitor where they were going, and
  /login offers it.** Once signed in, `/odoo-signin` goes to its `?next=` when that is a
  path on this site, and to `/` otherwise: the endpoint decides, through the check
  `/login`'s own return uses (now one function, which also refuses a `//` anywhere in the
  path, for `/login` too). On a site opted in to Odoo sign-in, `/login` shows a "Sign in
  with Odoo" link to it, carrying any `next`, beside the local form. `/odoo-signin` stays
  reachable while the site is in maintenance, as `/login` does. Ruled 2026-10-23
  (rulings 36-39).

- SM1295 (ace93456) **a ready-made sign-in page for a site whose sign-in is the Odoo
  login.** While `odoo_site_signin` is on, `/odoo-signin` is a sign-in page in the site's
  own layout: a "Sign in with your Odoo login" button that opens the sign-in dialog, and,
  once signed in, who is signed in and a sign-out. Set `auth_redirect: /odoo-signin` to
  send visitors there. It is a system page like `/login`, so a site's own `odoo-signin.md`
  replaces it, and with the switch off it is not found. The button is the `::: odoo-signin`
  component, which a layout may restyle; the page carries no inline style. SM1160's
  follow-up (#340).

- SM1296 (85885cd3) **get_permissions on a page's stem answers the rule that governs the
  page.** On edge, `/zz76/b` answered `acl: null` while `/zz76/b.md` was a draft, because a
  move had folded the draft into the page's own key (SM1257). A stem that names a page, and
  the page itself, now answer the page's rule as the engine reads it, with `key` naming
  the key that holds it (and `keys` when the page and its stem each hold part). On MCP
  `get_permissions`, the control API `acl-get` and `lazysite acl show`. A folder of that
  name keeps its own rule. Edge walk of 0.16.1, O-3.

- SM1297 (f220dc78) **the maintenance switch can be cleared back to unset.** Switched on
  and off through config-set, lazysite.conf read `maintenance: off` where it had been
  empty, and config-set refused an empty value. Empty is now accepted and means off, as
  an absent key does; the Config page's switch sends it when turned off, so the key is
  cleared. Edge walk of 0.16.1, O-1.

- SM1298 (cd2c496e) **every form's unknown-rule warning says which form, in one
  wording.** The first form's warning for a `key:value` the renderer ignores had no
  "form 1:" and was worded differently from a later form's ("form 2: unknown form rule
  ..."). Every form's warning now reads "form N: unknown form rule '<rule>' on field
  '<field>': it is not one the form reads, so it does nothing when the form renders",
  for a bare word and a `key:value` alike. What blocks a save is unchanged. Edge walk
  of 0.16.1, O-2.

- SM1294 (127e53bd) **a site may set a ceiling on the browser features its pages ask
  for.** `permissions_policy_allow` in lazysite.conf is optional. Absent or empty, a page
  asks for any denied feature as SM1266 made it. Set, a page's `<feature>: self` grants
  only a listed feature: an unlisted one keeps `=()`, and validate warns naming the key.
  `none` lets no page ask. payment and browsing-topics can never be listed: config-set
  refuses them by name, a hand-written one grants nothing, and `lazysite check` names it.
  On the Config page under Browser features; the site's for every domain, never set per
  domain alias. Page status shows what the response sends. Ruled 2026-10-23 (ruling 29).
- SM1286 (5e12820a) **`lazysite starter` clears out the starter pages a site never
  edited.** A site keeps the starter pages it has when the default changes (SM1285), and
  removing them was file-by-file work. `lazysite starter --docroot D --list` names each
  as unmodified or edited, by provenance: the `provenance: lazysite-starter` stamp, and
  the checksum the install recorded or the one shipped. `--remove-unmodified` removes the
  unmodified ones with their cached renders, and `--dry-run` says what it would remove.
  An edited page is never removed, nor the pages a site needs (forgot, logout, the search
  pages). It runs as the site user, refuses root, is audited, and names a menu entry left
  linking a removed page. Ruling 34.

- SM1285 (b30b3796) **A new site arrives without the starter pages.** Provisioning laid
  lazysite's demo, sample contact and members pages and its welcome page on every site, for
  the owner to delete before launch. A new site now has the system pages, the site search,
  the engine's `/docs` manual (SM1284) and a minimal home page. The engine serves that home
  at `/` until the site writes its own `index.md`, and an access rule at `/` governs it.
  `--starter` adds the starter pages and is remembered for upgrades. `--no-starter` is
  accepted and means the default. A site that already has starter pages keeps them. The
  seeded menu no longer links pages the site has not got. `lazysite demo` keeps its
  demos. `lazysite-hestia-domain add --starter` and `LAZYSITE_STARTER=1` (Hestia deploy,
  Docker) opt in. Ruling 33.

- SM1284 (26f7b150) **The /docs manual is the engine's.** The agent briefings and the
  manual they link into were starter content in each site's docroot. So cleaning a site
  up for launch put at risk the pages the partner brief, `.well-known/ai-partner` and the
  MCP instructions send agents to: theunited.community kept 30 of 70 pages by hand. The
  whole manual now ships in the engine tree (`lazysite/templates/docs/`), every upgrade
  refreshes it, and it serves at `/docs/` on every site, `--no-starter` ones included,
  whenever the site has no page of its own there. A site's own page at the path wins,
  and `lazysite check` warns that it shadows a newer version of the engine's. Access
  rules over `docs/` govern the engine's pages too. The manual stays out of the site's
  search, sitemap, feeds and `llms.txt` unless `engine_docs_public: true` puts it in.
  The upgrade removes each unmodified `docs/` copy and keeps an edited one, naming it.
  A recursive scan no longer lists pages from the `lazysite/` management tree.
  Rulings 4, 27, 32, 34 and 35.

- SM1283 (b1fafdef) **The sign-in and error pages serve when the engine tree is beside the
  docroot.** On a site that had moved its engine tree to `<docroot>-lazysite` (SM293), the
  engine's own `/claim` and `/login` (SM201) answered 404 whenever the docroot had no copy
  of its own, which a fresh install never seeds. The fallback chose the engine's file and
  the content-root check then refused it, because its real path is outside the docroot. A
  source the fallback chose is now accepted when it sits under the engine's page tree.
  Every other source is confined as before.
- SM1302 (2fb0c7ff) **internal: a test opens no pipe to a child itself.** t/lint/284, t/lint/273's
  sibling, fails a test that opens a pipe to or from a child (`'-|'`, `'|-'`, the forking open,
  `'cmd |'`) itself, unless it says it drives the child itself or the text is fixture text.

- SM1301 (c9535430) **internal: a one-way pipe in a test has a timeout too.** SM1245 bounded the
  two-way spawns under t/ and left 58 one-way pipe opens in 54 files, mostly git, find, tar and
  the tools under test, with no limit: a child that never exits hung its test with nothing to
  name it. They run through TestHelper::run_child now, which fails the test naming itself and
  the child after `child_timeout()`.
- SM1313 (a4924496) **lazysite check names a rule wider than its enclosing rule.** 0.16.3
  refuses such a rule unless the operator or the enclosing rule's owner writes it (SM1309),
  and keeps the ones already stored. The check now names each stored one whose owner is
  neither, as a WARN naming the path, the enclosing rule and whom it admits beyond it, and
  asks the operator to review it. It changes nothing, and `lazysite repair` leaves it to a
  person. Ruled 2026-11-04 (ruling 61).

- SM1312 (6fa4fb0a) **list_pages leaves out a page the caller may not read.** It read every
  page's title without asking the page's rule, so a gated page still in the document root
  (protected before 0.10.8, or under a rule with only address lists) had its title listed.
  Ruled 2026-11-04 (ruling 60).

- SM1311 (b9542a81) **a confined audit is of its scope.** `audit_site` walked the whole site
  for a grant confined to a scope. It now audits the scope (`scope_roots`). A link to a page
  outside it is listed in `outside_scope_links`, never as broken, and its target is not
  looked up; a path on the domain the scope root serves is read there. An unconfined
  audit is unchanged. Ruled 2026-11-04 (ruling 59).

- SM1310 (c364fdcb) **replace_text refuses a page changed under it.** It saved without the
  modification time it read, which skips the save's conflict check, so of two agents
  replacing text on one page at once both answered `replacements: 1` and one change was
  lost. It saves with that time now: a page another writer saved in between is refused as a
  conflict (`kind: conflict`), nothing written, and the agent is told to run it again. The
  check's resolution is one second. Ruled 2026-11-04 (ruling 51, part (a); `write_file`'s
  base version is 0.16.4).

- SM1309 (643e4e02) **a rule inside another may narrow it; only the operator or the
  enclosing rule's owner may widen it.** A subfolder's rule replaces its parent's for a mode
  (longest match), and anyone who may write a path may write its first rule, so a member of
  a protected area, or the member's agent, opened a subfolder to a non-member with one
  `set_permissions` call. Writing a rule that admits, to read or to write, anyone the
  enclosing rule does not is now refused (`kind: widens-enclosing-rule`, naming the
  enclosing rule) unless the operator or that rule's owner writes it, on the manager, the
  control API, MCP and `lazysite acl set`. A move that would carry such a rule inside the
  area is refused the same way, on the manager, MCP and WebDAV. Longest match stays, so an
  operator's carve-out still works, and an existing carve-out can be re-applied by its
  owner. Ruled 2026-11-04 (ruling 46).

- SM1308 (630b5735) **a confined agent lists and searches only its scope.** An MCP grant
  confined to a scope was answered `list_pages`, `list_files` and `search_files` from the
  whole docroot when it named no path, because the scope check skips an argument that is not
  given; and the search printed lines of files whose rule the caller does not pass. A
  missing or empty path is now the grant's scope roots, the walks stay inside them (as do
  `delete_page`'s reference list and `rename_page`'s link rewrite, which wrote pages outside
  the scope), and each search hit is a file the caller may read. The manager API's `list`
  with no or an empty path, and `pages`, answer a confined caller the same way. Ruled
  2026-11-04 (ruling 47).

- SM1274 (adf2903a) **Dismiss all empties the notices panel.** "Mark all read" marked every
  notice read and left them all in the panel. Now called Dismiss all, it also takes them out:
  the panel is empty and the count 0, on screen and on the next page, and the notices stay in
  the store, as a single Dismiss leaves them. A notice that arrives afterwards is unread. The
  manager offers it whenever the panel holds a notice; a member's own bell does the same.
  Ruled 2026-10-23 (ruling 26).

- SM1273 (a28ef0d0) **lazysite repair gives a manager group the capabilities a release
  added.** A site whose only warning was a manager group's not-yet-held capability was left
  "awaiting your decision", though there was nothing to decide. Before it checks again,
  repair now runs the users tool's top-up (`group-reach` for each manager group, as the
  site's owner when run as root), so the site ends repaired. A declined capability stays
  declined. `--dry-run` names the commands and runs none, and a failed call is reported
  and the repair goes on. The check's warning names `repair --domain DOMAIN` as the
  simplest fix.

- SM1272 (15c2c6a1) **the check says a manager group is granted a new capability on the next
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

- SM1270 (b7be28de) **acl-remove needs a path.** The control API's `acl-remove` with no path,
  or an empty one, removed the site-wide rule and published everything it held back (the
  dispatcher's `/` default, which SM306 kept for recovery). It is refused now, on every
  channel and before the scope check, with a message saying the site-wide rule is removed
  with `path=/`; `Files::action_acl_remove` refuses it for the CLI and MCP too. The action
  declares `path` required, as MCP `remove_permissions` does. `/`, `.` and `./` still remove
  the site-wide rule. Ruled 2026-10-23 (ruling 17), replacing SM306's no-path default.
- SM1316 (c093a5e8) **docs: the Hestia updater is given its stage once.**
  `lazysite-hestia-update-all.sh` defaults its stage to the release it runs from, and every
  command that told an operator to run it named the stage twice
  (`bash STAGE/installers/hestia/lazysite-hestia-update-all.sh --force-security STAGE`).
  OPERATOR.md, UPGRADE.md, the hint `lazysite upgrade --all` prints on a Hestia host and the
  deploy hook's own command drop the second one, and the updater's usage says it need not be
  given. t/lint/292 refuses the doubled form anywhere outside the release history (ruling
  45).

- SM1315 (83bab8b6) **release: the deploy hook passes `--force-security` itself.** A
  release whose manifest declares `"security_critical": true` was deployed by
  `tools/lazysite-deploy.sh` with its usual flags, so the Hestia updater scoped it by each
  site's `update_channel` and the operator pushed it to the rest by hand. The hook now reads
  `release-manifest.json` from the tarball it deploys and adds `--force-security` to the
  updater's flags when the key is true; a missing or false key adds nothing, and a manifest
  it cannot read adds nothing and says so. It still deploys only a strictly higher version
  (ruling 45).

- SM1314 (28b0d2eb) **release: a security release is cut on stable.** 0.16.2 was cut
  `--security-critical` on edge, so the standard deploy reached only the edge sites and the
  rest were pushed by hand with the Hestia updater's `--force-security`.
  `tools/release.sh build X --security-critical` now refuses (exit 2) unless `--final` (or
  `--certified`) is given too, before a receipt is read, saying a security release is cut on
  stable so the standard deploy reaches every site. OPERATOR.md, UPGRADE.md and
  docs/development.md give the stable form (ruling 45).

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
