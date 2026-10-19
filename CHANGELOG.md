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

- SM1178 (PENDING) **a binding may name a pack operation with a hyphen.** A
  binding to an operation of an OOM pack such as `crm-page` (`crm-page.leads`)
  was refused at save ("not an operation name"), so a pack could be installed
  and listed but never bound; an operation name's parts may now hold a hyphen
  between characters, as OOM names packs, and a leading, trailing or doubled
  hyphen is still refused. t/unit/odoo/71.
- SM1162 (PENDING) **a binding takes a file.** An Odoo binding may map a request
  file field to a parameter the operation declares as a file or a list of files
  (or a `set.<field>` of a binary field) with `file_params`; `file_max_kb` is
  required with it (never above the operation's `max_bytes` or the endpoint's
  20 MB ceiling) and `file_types` may limit the types. The endpoint takes
  `multipart/form-data` with `?binding=ID`, refuses a body larger than the
  binding allows with `413 too-large` before reading it, reads the type from the
  file's bytes and refuses one the binding does not accept or the browser
  misclaims; the operation is given the file in the process and through oomd,
  and the bytes are in no answer, record or log (OOM Lab L-9). The browser
  helper sends a `File` as form data. A planned write's file bytes are removed
  once the plan is applied, withdrawn or refused as no longer applicable, and the
  maker of an unapplied plan can now withdraw it (`{plan, withdraw: true}`).
  t/unit/odoo/66, 67, 68, 69, 70.
- SM1177 (PENDING) **internal: lazysite's vendored OOM is 0.34.** The pinned
  snapshot in `t/vendor/oom` moves from 0.33 to OOM 0.34 (03b703e), which adds
  file parameters; lazysite uses those (SM1162), not 0.34's data cache or fast
  JSON. t/lint/207, 261, 262.
- SM1174 (PENDING) **a page may open the camera.** Every page sent
  `Permissions-Policy: camera=()`, so no page could open a live camera
  viewfinder even on https (OOM Lab L-16). A page whose front matter says
  `camera: self` now sends `camera=(self)` over https, decided per response on
  the fresh and cached paths; every other page, and that page over http, keeps
  `camera=()`, and no other directive moves. The validator names any other
  value, `page_status` reports it, and the editor's status bar says the page
  opens the camera. t/unit/processor/143, t/unit/mcp/33, t/unit/manager/364.
- SM1173 (PENDING) **a read has room for a scanner.** An Odoo read binding's
  default caps were the write caps, 20 per caller and 200 per binding an hour,
  which stopped a scanning app within minutes (OOM Lab L-14); reads now default
  to 2,000 per caller and 20,000 per binding, writes keep 20 / 200, and a
  binding may still set its own caps either way. The manager form no longer
  saves 20 / 200 into a binding, and `lazysite check` names a read binding
  that a save there left at exactly those numbers, changing nothing.
  t/unit/odoo/65, t/tools/181.
- SM1160 (PENDING) **on an Odoo app site, the person's Odoo login is the site
  sign-in.** With `odoo_site_signin: on` (default off) a successful Odoo
  sign-in, two-factor step included, also signs the person in to the site as
  `odoo:<login>`: one login. `odoo_group_map` maps Odoo groups to site groups,
  asked as the person through OOM 0.33's `core.has_groups`, held server-side in
  the session record and refreshed by `?csrf=1` at most every
  `odoo_identity_ttl`; a site group that carries a capability is refused by
  name, so an Odoo group never gives manager rights. Sign-out, or any end of
  the Odoo session, ends both; the default layout shows "Signed in as" and a
  sign-out (`odoo_signin_banner`), and `lazysite check` names a refused or
  unknown mapping. t/unit/odoo/63, 64.
- SM1175 (PENDING) **internal: lazysite's vendored OOM is 0.33, with oomd.** The
  pinned snapshot in `t/vendor/oom` moves from 0.32 to OOM 0.33 (4bca049),
  which adds `core.has_groups`, and now carries `bin/oomd`, the one file taken
  from OOM's `bin/`, so SM1164's tests start the real daemon from the
  repository, never from the host (lint 262). `tools/vendor-oom.sh` checks
  `bin/oomd` against the `odoo-oom-tools` deb. t/lint/207, 261, t/tools/155.
- SM1176 (PENDING) **a coverage run no longer refuses itself.** The group's
  `cover_db-<group>-cover-stderr.txt`, left at the tree root, made the next
  group's manifest build refuse an unclassified file (2026-10-18 run); every
  root file named `cover_db-*` is now excluded. t/tools/182.
- SM1172 (PENDING) **saving the Odoo config keeps what an overlapping save
  wrote.** Two saves of `lazysite/odoo.conf` that overlapped both read the old
  file, so the second dropped the first's keys, an app's `odoo_packs`
  namespace among them (its operations answered 404 for a few seconds); the
  read, change and write now run under one lock (OOM Lab L-15). A client that
  rewrites the whole list itself can still race. t/unit/odoo/59.
- SM1166 (PENDING) **a binding takes a declared list of rows.** A parameter the
  operation declares as `rows` (OOM 0.32, with a `max`) takes a JSON array of
  flat objects from a request, such as a quotation's lines; each row is checked
  against the declaration and the plain-value rule before Odoo is asked, and a
  failure names the row and key. `rows_max` lowers the cap for one binding; a
  `rows` parameter with no `max` or no known keys can only be fixed (OOM Lab
  L-11; R1, R2 ruled 2026-10-18). t/unit/odoo/57.
- SM1170 (PENDING) **a custom change of a site's own pack applies.** An apply
  of a site pack's `custom` change ended `apply-incomplete` ("no operation"),
  because OOM's apply looked the operation up without the site's namespaces;
  planning and both apply paths now run with the site's operations, packs and
  cache set for that call only, never process-wide (OOM Lab L-12).
  t/unit/odoo/56.
- SM1161 (PENDING) **a scheduled binding may run as an Odoo login of its own.**
  `odoo-secret-set` / `odoo-secret-clear` (control API and MCP) take
  `scheduled` (a binding id); its run uses that login's key, is recorded and
  audited as `scheduled:<binding>` with the login it ran as, and a configured
  binding without its key is refused rather than run as the connection user.
  `odoo-status` lists each scheduled key and its expiry, and `lazysite check`
  warns within 14 days of it. t/unit/odoo/58, t/tools/180.
- SM1169 (PENDING) **security: a pooled worker no longer carries one visitor's
  data to the next.** A worker of the persistent pool kept a visitor's payment
  context (the previous payer reached later pages' template stash), their scan
  identity (the first visitor's user and groups filtered every later `scan:`)
  and their response language into the next visitor's requests; all three are
  now reset per request. The pool's parent also loads the engine modules before
  it forks, so a respawned worker starts warm (a first-request page-cache miss
  fell from about 110-120 ms to 38-51 ms on the shared host), and a lint reads
  every file-scope variable of the resident code. t/lint/269,
  t/integration/288.
- SM1159 (PENDING) **security: sign-in can be limited by address.**
  `signin_addresses` and `signin_addresses_deny` name address lists that
  lazysite's login and the Odoo endpoint's sign-in and code steps must admit; a
  refusal comes before the token, the password and the rate counter, with its own
  reason and audit row ("Sign-in is not available from your address."). A
  session binding's own lists narrow the site's on that binding's calls, ahead of
  its sign-in question (SM1168). t/unit/auth/67, t/unit/odoo/54.
- SM1168 (PENDING) **a session binding with no Odoo session asks for sign-in,
  not a token.** A POST for a `credential: session` binding from a visitor with
  no Odoo session answered 403 `csrf`, so the helper never opened its sign-in
  prompt; it now answers 401 `signin-required` before the token check, alone and
  inside a batch. With a session the token is still required. t/unit/odoo/53, 42.
- SM1171 (PENDING) **a write through the Odoo endpoint says why a change was
  held.** A plan's changes carry `reason`, and an applied write answers
  `result.changes`: each change's bucket, action, model, id and outcome, the
  `reason` for one held or skipped, and a custom change's `returned` value
  (capped at 4 KB, marked when cut), read from OOM's journal; no values or
  before-images (OOM Lab L-13). t/unit/odoo/52.
- SM1165 (PENDING) **a write through the Odoo endpoint says which records it
  made.** An immediate apply or a confirmed plan now answers `created` and
  `written` (model to ids, this plan's own changes) beside the counts, so a page
  can learn the new record's id (OOM Lab L-10). t/unit/odoo/51.
- SM1167 (PENDING) **internal: lazysite's vendored OOM is 0.32.** The pinned
  snapshot in `t/vendor/oom` moves from 0.27 to OOM 0.32 (bd9610e); no lazysite
  code needed to change, and nothing uses rows, inline reports, repeat-safe
  requests or oomd yet. `tools/vendor-oom.sh` takes a second `--deb`, since
  `odoo-oom-tools` now ships `Odoo/Accounts.pm` and `Odoo/Tools/`. t/lint/207, 261.
- SM1163 (PENDING) **internal: a rate test stays in one window.** The sign-in limiter
  counts in fixed windows, and a test whose guesses ran across a five-minute
  boundary saw the count restart (2026-10-17 integration). One helper,
  `t/lib/RateWindow.pm`, now begins the counted attempts where they fit one
  window; the limiter itself is unchanged.
- SM1143 (PENDING) **internal: the note-on-focus test waits for what it checks.**
  Under heavy parallel load
  the browser in the SM1104 test could return no document and the test read an
  empty result, failing its two focus assertions; it now reruns the browser until
  the page reports it finished and polls for the note up to a deadline. No CSS
  change. t/unit/manager/349.
- SM1141 (PENDING) **a template can test the visitor's address.**
  `visitor.in_list('name')` answers whether the address is in a list, never
  the address itself, and a page using it is not cached. `lazysite check`
  warns when address rules cannot work, and a list still in use is not
  deleted without force (SM1134, slice D). t/unit/processor/133.

- SM1140 (PENDING) **security: a group is limited by address.** A group may be
  limited to addresses; from outside, the group and everything it grants
  (capabilities, page access, operator status, domain reach) drop out for
  that request, for cookies and tokens. An account confined by its grants is
  confined to nothing when none apply, never unconfined. `manager_addresses`
  limits the manager and its API (SM1134, slice C). t/integration/285, 286.

- SM1139 (PENDING) **a page or folder is limited by address.** Front matter and
  per-file rules take `addresses` and `addresses_deny`; every layer must
  admit the visitor's address and deny wins, on pages, statics, WebDAV and
  the manager. A refused visitor sees "This page is not available from your
  address."; ruled pages are never cached (SM1134, slice B).
  t/integration/280, 281.

- SM1138 (PENDING) **address lists are a store.** Named allow and deny lists
  of addresses and ranges, managed on Access -> Address lists by the operator
  and audited, with one module that answers whether an address is allowed
  (SM1134, slice A). t/unit/auth/63, t/integration/266.

- SM1135 (PENDING) **a directory group grants capabilities only when marked.**
  Under a trusted proxy, header groups gave page and file access, and only
  some gates also read them for capabilities. One rule now serves every gate:
  a group's capabilities, and operator status, come from the directory only
  for a group the operator marks `directory_grants` (release manager,
  2026-10-17, R1). t/integration/271.
- SM1136 (PENDING) **a guide to running behind an identity provider.** A docs
  page covers the trusted-header settings, the security conditions and a
  worked Caddy and Authentik example.
- SM1137 (PENDING) **the data endpoint honours a trusted proxy.** It used its
  own session even when a trusted proxy named the user; the proxy's identity
  now wins there too. t/integration/272.
- SM1145 (PENDING) **a page shows who is signed in to Odoo without calling Odoo.**
  `?csrf=1` answers `identity: {name}` from the identity cookie the
  endpoint already verifies, and nothing else about the person; the helper fills
  `data-ls-odoo-name` on load. The cookie stays HttpOnly and carries no
  login. t/unit/odoo/41, 44.
- SM1146 (PENDING) **a batch call on the Odoo endpoint.** `POST {calls: [...]}`
  runs up to ten calls in one request and answers each in order with its own
  status; each is checked, authorised, rate-counted, recorded and audited as a
  single call, and one failing does not stop the others. The helper has `batch`.
  t/unit/odoo/42, 44.
- SM1147 (PENDING) **the Odoo endpoint's cold path loads only what it answers
  with.** `?csrf=1` and requests refused before Odoo no longer load the engine or
  OOM; measured about 4 ms of 86 ms CPU per `?csrf=1`, the rest being modules the
  request needs. t/unit/odoo/43.
- SM1148 (PENDING) **a form whose Odoo change applied with a warning is
  delivered.** An apply OOM reports as `apply-incomplete` after the record was made
  is no longer `outcome=undelivered`; the warning is in the call record and the
  audit. t/unit/odoo/45.
- SM1149 (PENDING) **the Odoo connection can trust its own CA.** `odoo_ca_file`
  is the CA bundle for the connection to Odoo only, passed to OOM as `ssl_ca_file`
  for every client lazysite builds for it, never `SSL_CERT_FILE`. t/unit/odoo/46.
- SM1150 (PENDING) **`credential: session` is documented.** The Odoo guide
  describes a person signing in and running bindings as themselves, as the code
  does, and no longer lists it as not available. t/unit/odoo/47.
- SM1157 (PENDING) **Odoo's own two-factor code in the Odoo sign-in dialog.** A
  person whose Odoo account has two-factor authentication was refused
  (`two-factor`); with OOM 0.27 the dialog now asks for the 6-digit code after
  the password. The half-open sign-in travels in its own signed, HttpOnly
  cookie (five minutes, never a session); a wrong code can be tried again within
  Odoo's own limit. "Remember this device" is a new setting, `odoo_remember_device`,
  off unless said and offered only over HTTPS; Odoo's device value is kept in one
  HttpOnly, Secure, SameSite=Strict cookie, never in a store. The code, the
  password and the device value are in no record or log. An older OOM still
  refuses the account by name. t/unit/odoo/48, 49.

- SM1156 (PENDING) **lazysite adopts OOM 0.27.** The pinned snapshot moves from
  0.24 (`t/vendor/oom`, SM747's filed spec re-filed with it). 0.27 answers a
  two-factor account's right password as a pending sign-in rather than a
  fault, and renames its category; lazysite took that answer for a sign-in and
  would have set a cookie for a session that runs nothing. It is refused by
  name (`two-factor`) and the half-open session is ended at Odoo. The
  dependency floor is unchanged. t/unit/odoo/25.

- SM1155 (PENDING) **a site, or a section of it, installs as an app.** Setting
  `app_name` (with `app_scope`, `app_start_url`, colours and icon files) makes the
  engine generate the web app manifest and a service worker; nothing is authored
  under `/lazysite-assets/`. The worker keeps the app shell (stylesheets and
  scripts stale-while-revalidate, images cache-first), never answers a page, the
  Odoo endpoint, the manager or the auth paths, never stores a `no-store` or
  `private` response, and updates on a deploy. `lazysite check` names a bad scope
  or a missing icon. t/unit/processor/134, 142, t/unit/tools/84.
- SM1144 (PENDING) **internal: a request says where its time went.** SM1082 track T0.
  Every surface the engine answers (pages and statics, the manager API, MCP, the
  data and Odoo endpoints, WebDAV, and the auth wrapper's hand-over) reports its
  phases - config, identity, load, render, call, write, only those that happened -
  in a `Server-Timing` header, shown to a verified operator or when lazysite.conf
  says `server_timing: on` and to no anonymous visitor otherwise; the processor's
  access log gains a `tm` object. `tools/bench-surfaces.sh` reports the median and
  p90 of each phase per surface under CGI and, with `--with-pool`, a one-worker
  pool, pinned to one CPU at nice 19 and never parallel. `lazysite check` reports
  `pool: yes, N workers` or `pool: no (plain CGI)`. t/unit/lib/204,
  t/integration/287, t/unit/odoo/50, t/tools/170, t/tools/171.
- SM1131 (PENDING) **every reader honours the configured header names.** Only the
  page gate read `auth_header_*`; one reader, `Lazysite::Auth::Identity`, now
  serves the page gate, the file rules, the manager and the API, and takes its
  trust decision from SM1129's check. t/integration/265.
- SM1132 (PENDING) **one rule splits a groups header.** The page gate split on
  commas and the manager on commas or spaces; `auth_header_groups_separator`
  (default comma; Authentik sends `|`) is now the one rule. t/unit/auth/62.
- SM1133 (PENDING) **a directory group name is mapped.** A directory's group
  names (spaces, capitals) are normalised to lazysite names, with an optional
  `auth_group_map` that wins (release manager, 2026-10-17). t/unit/auth/62.
- SM1151 (PENDING) **the dev server answers connections side by side.** One
  accept loop made a page's parallel requests queue, so the lab's timings
  measured the queue; each connection is now a forked child, up to eight at
  once. Dev only. t/unit/tools/83.
- SM1152 (PENDING) **a stale registry is rebuilt after the request, not inside
  it.** A request that finds a registry stale serves the one it has and starts a
  detached rebuild under one lock (1.5-3 s on an 1,800-rule fixture); a content
  write starts it when its request is over; a missing registry is still built on
  first need. t/unit/processor/141, t/unit/manager/363.
- SM1153 (PENDING) **the extension-list cache follows the extensions
  directory.** The cached list kept an empty answer after `plugins/` appeared
  (oom-lab L-5); it now records what it was built from, and an empty list for a
  missing directory is not kept. t/unit/lib/203.
- SM1154 (PENDING) **the add path names setup-sysop on a site with no
  operator.** `add` (first account) and `group-add` (a non-operator group)
  print a note naming `setup-sysop` and the manager's Users page; the help and
  the manager guide say it too (oom-lab L-8). t/unit/users/55.

- SM1129 (PENDING) **security: a proxy is believed only from its address.** With
  `auth_proxy_trusted` on, any request carrying the identity headers was
  believed (SM794's open gap; SM1128 phase 1). `auth_proxy_trusted_from` lists
  the proxy's addresses, matched against the TCP peer only; from anywhere else
  the headers are stripped, and an empty list believes nobody. One function
  answers the question for every surface; `lazysite check` warns while the
  flag is on. t/integration/264.
- SM1130 (PENDING) **a trusted proxy's identity wins over a lazysite cookie.**
  A stale local session replaced the directory's identity; under a trusted
  proxy the proxy's user now wins, and with no proxy user the cookie works as
  before. t/integration/263.

- SM1127 (PENDING) **internal: a short PUT through Apache leaves nothing.** The
  0.15.9 walk could not reach the engine with a short body from outside. A test
  now drives one through a real Apache: a cut-off and a stalled body both leave
  no file and no temp. t/integration/262.

- SM1125 (PENDING) **internal: nothing shipped calls a deprecated action name.**
  Three manager comments still named `plugin-*` actions; they name the
  `extension-*` ones, and t/lint/266 keeps shipped pages, assets and skills on
  the current names. The old names still work.

- SM1124 (PENDING) **security: a form's outcome is a code, not text.** The page
  printed any text placed in the `outcome=` parameter, so a link could make a
  site's own page show someone else's words (0.15.9 walk, F-3). The redirect
  now carries a short code, and the page shows only the engine's sentence for
  a known code; anything else gets one generic sentence. t/unit/forms/67.

- SM1122 (PENDING) **the outbox list keeps what it sent.** A sent entry vanished
  from the list and the lookup by id (0.15.9 walk, X3): SM1105 covered only an
  entry whose file could not be removed. Sent entries are now listed from the
  ledger for its 8 days, with recipient counts per channel and no addresses
  (release manager, 2026-10-17). t/unit/notify/09.
- SM1123 (PENDING) **a retry names what it retried.** The retry audit row's
  target was "/"; it is now the rule or entry id, with the counts.
  t/integration/260.

- SM1121 (PENDING) **a missing path is named, for the operator too.** The 0.15.9
  walk (X1) found a save with no path, or with the path in the body, refused
  as "'/' is a folder". SM1103's refusal ran only for accounts below the
  operator, and the tester was the operator. It now runs for every caller:
  no path says it is required in the query, and a body path is named.
  t/unit/manager/348.

- SM1120 (PENDING) **an engine-served static says when it changed.** Every
  200, 206, 304 and 416 from a static carries `Last-Modified`,
  `If-Modified-Since` is answered with a 304 when no `If-None-Match` is sent,
  and an `If-Range` carrying the exact date of a file at least a second old is
  honoured as a range. t/unit/processor/131.

- SM1116 (PENDING) **internal: everything a coverage run writes is classified.**
  The overnight coverage run of 2026-10-17 stopped in its first group: the
  manifest refused the run's own `cover_db-processor-suite.log`, which no
  exclude rule named. Group suite logs are now excluded, and t/tools/169 checks
  every name the coverage tools write.

- SM1117 (PENDING) **lazysite adopts OOM 0.24.** The pinned snapshot moves from
  0.09 to 0.24, the version the host's deb carries. The one gap was a
  two-factor Odoo account refused as an internal error: OOM 0.24 gives it its
  own category (`second_factor`, `is_no_session`), which lazysite now reads,
  keeping the message test for an older OOM. SM747's filed spec is re-filed.
  t/unit/odoo/25, 27.

- SM1119 (PENDING) **internal: a required argument agrees across the two
  surfaces.** t/lint/23 pinned that the control API and MCP expose the same
  actions and nothing compared what each requires. Thirty-odd paired actions
  marked an argument required on one side only; the API side now requires them
  (nav-save with no `items` had saved an empty menu), and eight differences are
  recorded with their reasons. A missing required parameter now leaves an audit
  row. t/lint/265, 206.

## 0.15.9 - EDGE: mail sends from a real address, and video plays everywhere (2026-10-17)

- SM1114 (e01b7471) **a failed WebDAV PUT leaves nothing behind.** A failed PUT
  could leave its `.tmp` file in the tree (xisl.com, 2026-10-16), and a body
  shorter than its declared length was stored as the whole file. Every
  failure removes the temp file; a short body answers 400 and stores nothing;
  a full disk or quota answers 507 naming the cause; PROPFIND hides temp
  files. t/unit/dav/33.

- SM1112 (f058d4ec) **media is served as media.** `.mp4`, `.webm` and other
  video, audio and caption files were served as `application/octet-stream`
  (xisl.com, 2026-10-16). Every content-type map the engine has now carries
  them, and gives each extension one answer; t/lint/264 keeps the maps in
  step.
- SM1113 (f058d4ec) **an engine-served file answers a byte range.** On a site
  with access rules every static passes through the engine, which ignored
  `Range`, so Safari and iOS would not play video. It now answers 206, 416 and
  `Accept-Ranges: bytes`, uncompressed, after the access check.
  t/unit/processor/130, t/integration/261.

- SM1108 (5c81fe24) **a blank password field keeps the stored password.** Saving
  Form SMTP with its password left blank cleared the stored one, though the
  field said "leave blank to keep". A blank `type: password` value is now
  unchanged on every extension. t/unit/manager/351.
- SM1109 (5c81fe24) **mail is sent from a real address.** The fallback sender was
  `webforms@localhost`, which real servers refuse. Form SMTP gains a From
  address; when it is empty the sender is `no-reply@` the site_url's host
  (release manager, 2026-10-16). A refused recipient names the sender used.
  t/unit/forms/63.
- SM1110 (5c81fe24) **a failed STARTTLS says why.** "STARTTLS failed" now names
  the hosts the certificate is for and the host connected to.
  t/unit/forms/64.
- SM1111 (5c81fe24) **a failed sendmail says how it failed.** "exit 256" is now
  the exit code or signal with sendmail's own error lines; an account import
  says its claim links were "handed to the mail transport". t/unit/forms/65.

- SM1105 (b066a4de) **the outbox list says what was sent.** Sent entries were
  still listed as queued (row R2 of the 0.15.6 walk). The ledger records each
  entry's event, and a sent entry is listed as sent whatever became of its
  file; a failed removal is logged. t/unit/notify/07.
- SM1106 (b066a4de) **a repeat unsubscribe says already stopped.** A second POST
  showed "Unsubscribed" again (row R3); it now shows the "Already stopped" page
  and writes nothing. t/integration/248.
- SM1107 (b066a4de) **an operator can retry an outbox entry now.** A waiting entry
  sat in backoff after a transport fix. `notify-outbox-retry` (control API and
  MCP, manage_notifications) and a "Retry now" button on the Handlers page make
  waiting entries due at the next run; the cap and held messages still apply.
  t/unit/notify/08, t/integration/260, t/unit/manager/350.

- SM1104 (5f00497c) **an info mark shows its note on keyboard focus.** Focus only
  recoloured the mark, so a sighted keyboard user never saw the note (row N4 of
  the 0.15.6 walk). The note is drawn beside the mark on hover and on
  focus-visible, in all three manager styles, without being read twice by a
  screen reader. t/unit/manager/349.

- SM1103 (22425c61) **a write with no path is refused by name.** The edge test
  walk's "manager saves fail" was a client sending `path` in the JSON body:
  `save` reads it from the query, so it ran with no path and tried to create
  a file beside the docroot. A path sent only in the body, or a content write
  with no path, now answers `missing-parameter` saying where the path goes; a
  save onto a folder or the site root is refused; a refused create names the
  file, the process's user and the folder's owner and mode.
  t/unit/manager/348.
- SM1115 (3e7299e1) **a rate-limited visitor is told so, and the operator can see
  it.** Past the per-form, per-address limit a visitor saw "An error occurred -
  please try again." and nothing was audited (0.15.8 edge walk). The refusal
  now says too many were sent from this address and when to try again, and the
  first refusal in an hour writes a `submit <form> fail` row naming the rate
  limit. t/unit/forms/66.

## 0.15.8 - EDGE: Mark all read is kept, and the site has one address (2026-10-16)

- SM1102 (f85634c5) **the site has one address: base_url is removed.**
  notify.conf's `base_url` overrode `site_url` for the links a notice carries,
  and the outbox told operators to set it. With the Site URL now pinnable from
  the Config page (SM1101), the release manager removed it (2026-10-16): links
  use `site_url` alone, and a `base_url` line left in notify.conf is not read.
  t/unit/lib/25, t/unit/notify/03.

- SM1100 (048c9bec) **Mark all read is kept, or the bell says it was not.** On
  edge, Mark all read cleared the bell and the notices came back unread on the
  next page (release manager, 2026-10-16). The read marker was written with a
  bare open that failed where the file belonged to another account, and the
  action answered ok regardless. It is now written by renaming a new file over
  the old one, and a write that fails is an error the bell shows.
  t/unit/lib/202.
- SM1101 (5fc8954c) **the Site URL field offers "Use this address".** The
  default site_url is worked out per request, so a notice sent by the
  scheduler or the command line had no address for its links. A button beside
  the field fills in the address the page is open at; Save writes it (release
  manager, 2026-10-16). t/unit/manager/347.

## 0.15.7 - EDGE: a folder delete deletes, and a signed-out visit is not an event (2026-10-16)

- SM1098 (0f8444a7) **a declared lazysite-agent is counted as a bot, not a
  scanner.** The 0.15.5 test walk's probes of missing draft pages put the
  testing agent in the scanner class. A request declaring
  `lazysite-agent/...` was classed bot, then promoted to scanner by the
  five-404s rule, which never looked at the user agent. A declared agent is
  no longer promoted; every other client is. t/unit/plugins/49.

- SM1096 (825da8c3) **a submission shows each field as a name and a value.** The
  submission view ran a field's name and value together ("messagezz55 F9
  event 2"). Each field is now its name as a label above its value, and a
  multi-line value keeps its newlines. t/unit/manager/346.
- SM1097 (825da8c3) **the bell is the one submission indicator.** The menu's
  submission bubble showed the same events as the bell without saying which
  form; the release manager ruled "bell stays" (2026-10-16). The bubble is
  removed; the bell is unchanged. t/unit/manager/202, 204.

- SM1094 (0ad82caf) **an unreadable auth_groups message quotes what it read.**
  `auth_groups: [` gave "write [[] or a '- [' line below it" (row S9 of the
  0.15.5 test walk): the raw value was spliced into the example. The message
  now quotes the value and shows the two correct forms on their own.
  t/unit/lib/201.
- SM1095 (0ad82caf) **a refusal to a token with no scope says what is true of
  it.** Such a token was told it "reaches only the domains whose content lies
  inside no scope: (default)". It is now told it is not confined to a
  domain's content, which domains it reaches, and that a domain with a
  content root of its own needs a scope covering that root.
  t/unit/manager/345.

- SM1093 (74891fb2) **a deleted notify rule takes its queued notifications with
  it.** Deleting a rule left its queued entries in the outbox (0.15.5 test
  walk). The delete now removes the rule's queued, retrying and held entries
  and says how many (`outbox_removed`, also in the audit detail); sent history
  is kept. Entries already stranded by an earlier delete are given up at the
  start of the outbox job and never sent. t/unit/notify/06.

- SM1092 (d5510903) **security: a WebDAV folder DELETE removes the folder or
  refuses, naming why.** The 0.15.5 test walk saw a folder DELETE answer 204
  and leave the folder and its pages. Removing a page's rule moves the page
  back from the private store but leaves its folder there empty, and DELETE
  removed only that private copy. It now removes the path from both trees and
  answers 204 only when neither holds it. Every member is checked first, as
  the request path is: a member the caller may not delete refuses the whole
  DELETE (403, nothing removed, the member named; release manager,
  2026-10-16). Before, members were not checked at all. t/unit/dav/32.

- SM1090 (2136f95d) **a failed save is audited as the save that failed.** The
  0.15.5 test walk on edge found manager saves failing with "Permission
  denied" and no save in the audit trail. A failed save was recorded as
  `edit`, from a flag only a successful save carries; it now keeps the action
  `save`, with `fail` and the write's reason. A save that left no row at all
  was not reproduced here. t/unit/manager/343.
- SM1091 (2136f95d) **an acl-set audit row records the rule it wrote.** Every
  acl-set row recorded the new rule as "no restriction" (row F7 of the 0.15.5
  test walk): the after-state was built from the request, whose lists may be
  strings. It now records the rule as stored, single and list form alike; the
  list form targets `/path`, a refused list names the paths it asked about,
  and the list result carries the read-without-write warning.
  t/unit/manager/344.
- SM1099 (bf6d6270) **an anonymous request does not fill the web server's error
  log.** The Apache error log filled with hundreds of MB of `[INFO] [auth]
  [/] auth: no cookie` (release manager, 2026-10-16): the auth wrapper logged
  one INFO line per request and never read `log_level`. "No cookie" and
  "cookie valid" are now DEBUG, and the wrapper honours `log_level` from
  lazysite.conf; `LAZYSITE_LOG_LEVEL` still wins. t/unit/auth/61.

## 0.15.6 - EDGE: an operator can add an operator, and a refused switch says why (2026-10-16)

- SM1088 (d3090a84) **internal: the swap margin guards the coverage stage
  only.** The 0.15.6 edge gate was refused on 2,521 MB of stale swap with
  6,665 MB available, over the 5 GB threshold. `tools/preflight.sh SUITE` has
  no swap rule, and `tools/gate-main.sh` uses it unless coverage will run
  (stable, certified, `LAZYSITE_COVER_FORCE=1`). t/tools/156, t/tools/168.

- SM1087 (83eb55e9) **internal: a stack whose branch name has a slash is
  prechecked.** The integration run named its precheck log from the branch
  name as-is, so a `claude/...` branch pointed the log into a missing
  directory and was reported "precheck failed" with no precheck run
  (2026-10-16). The name is flattened for the file. t/tools/167.

- SM1084 (6b7a0c38) **a refused extension toggle says why at the row.** "the
  toggle just springs back - it should explain why it wont enable" (release
  manager, 2026-10-16, enabling Odoo without the OOM package). The reason went
  only to the muted status line at the top of the Extensions page. It now
  appears under the extension's own row as an alert, and the status line is
  styled as an error. t/unit/manager/341.
- SM1085 (6b7a0c38) **an extension config field shows its note.** The Configure
  form never drew a field's `note`, on any extension. Each note is now an info
  mark beside its label. Odoo's timeout gained one, and "Extra operation packs"
  says what a pack is and when to leave it blank. t/unit/manager/342.
- SM1086 (4fe2cdec) **an operator may add someone to the operator group.** A
  sysops member was refused "it grants 'manager', which you may not confer"
  (release manager on edge, 2026-10-16). The operator flag is not one of the
  capabilities `caps_for` reports, so no signed-in account could ever be shown
  to hold it. An operator now counts as holding it; a `manage_users` holder
  outside the operator group is still refused (SM991). t/unit/users/51.

## 0.15.5 - EDGE: a signed-in account reaches only what its grants allow (2026-10-16)

- SM1083 (4f01c464) **internal: coverage for stable only.** "coverage run for
  stable only" (release manager, 2026-10-16): an edge or beta gate is the
  suite, the bench and the release material checks, and its receipt says
  `coverage=not run (channel edge; stable only, SM1083 ruling 2026-10-16)`;
  build accepts that for edge and beta and refuses it for stable and
  certified. The coverage stage runs for `--final` and `--certified`, with
  `LAZYSITE_COVER_FORCE=1` on any channel, or on demand via
  `tools/coverage.sh`.

- SM1081 (e2cb1175) **internal: each commit of a stack is cherry-picked once.**
  The overnight run picked a lower branch's commit again for every branch
  above it when the first pick had auto-merged (its patch-id moved on main);
  the third copy collided and the stack was reported CONFLICT with main
  (n566/n567/n568, 2026-10-15). Each branch now picks only the branch below
  it to its own tip, the lowest from main.
  t/tools/166.
- SM1083 (e10dfde4) **internal: coverage in parts.** The measured files fall
  into nine groups read from the area map (tools/coverage-groups.pl), each
  with its own inputs digest, cover DB, floor lines and recorded pass under
  tmp/release-gate/coverage-passes/GROUP/. `tools/coverage.sh --check`
  measures only the groups whose digest has no recorded pass and reuses the
  rest (`--all` measures every group, `--groups` lists their state); the gate
  needs every group matched. Floors start as the whole-suite values marked
  pre-rebaseline, so the first per-group run reports movement instead of
  failing on it; one re-baseline commit follows.

- SM1083 (3232ca6d) **internal: a release gate that guards itself.** A gate of
  three to five hours that failed for five different reasons in a week is
  replaced by a process that refuses to start where it cannot finish.
  `tools/preflight.sh HEAVY` checks memory, swap, stage disk, inodes and the
  heavy lock (exit 3 is a skip, not a failure); one heavy lock keeps the
  gate, coverage and the suite apart; the gate stages on disk
  (/var/tmp/lazysite-stage); coverage jobs follow free memory and a killed
  `cover` is reported as KILLED, not as a failure; t/tools/104 no longer
  trips on a RAM-backed /tmp or on Devel::Cover's stderr;
  `tools/failure-digest.pl` gives a failure in 20 lines; the overnight run
  skips unchanged code. Coverage runs on demand, not nightly.

- SM1080 (80e0fb9f) **internal: the overnight run prechecks a stack where it
  lands.** `tools/integration.pl` prechecked each stack's own tree, so a stack
  based on an older main failed on faults main had already fixed (n568, n575
  and n584 on 2026-10-14, Odoo tests n585 fixed) and was reported NOT READY
  though it would have landed green. The precheck now runs after the stack's
  commits are cherry-picked onto the integration tree, branch by branch against
  the tree before them; a failure leaves the stack out and rebuilds the tree
  without it. The results file records each stack's base: `stack base is older
  than main by N commits`. t/tools/151-153.
- SM1073 (a7e72221) **one click stops one rule writing to one recipient.** A
  notification rule's unsubscribe link and `List-Unsubscribe` header pointed
  at a page the operator had to write, and nothing recorded a refusal, so the
  daemon kept writing to whoever asked to stop. Every email of a rule now
  carries the engine's own link, signed for that rule and that recipient, and
  the `List-Unsubscribe-Post` header (RFC 8058): opening it asks to confirm and
  changes nothing; the button, or a mail client's one-click request, records
  the stop, without a sign-in. Asking again changes nothing; a link changed to
  name another rule or recipient is refused. A stopped recipient gets nothing
  more from that rule, on any channel, including what the per-recipient cap
  was holding; other rules are not affected. Every stop, repeat and refused
  link is audited by rule and a hash of the recipient, never an address. A
  rule's `unsubscribe_path` is now optional, linked beside it as the page to
  manage subscriptions (SM1010 R4). t/unit/lib/94, t/integration/248.

- SM1072 (80e96f47) **a notification rule says what its queue holds, and the
  outbox is shown in the manager.** A rule whose daemon was not running queued
  events nobody would send while its row on the Handlers page said "on". The
  row now shows the rule's queue (queued, retrying, held by the cap, failed),
  what its last run did with the last failure and when, and **waiting for the
  scheduler** with the reason when the `notify-outbox` job is refused, has
  never run or last ran long ago (SM1010 Q5, as ruled). A new Notification
  outbox card - `notify-outbox-list`, and `read_notify_outbox` over MCP -
  lists the queued, held and failed events and, for one event, who it
  resolves to and what was decided for each. It shows recipients, so it needs
  `manage_notifications` alone, and an account confined to some domains sees
  only their rules. t/unit/manager/340, t/integration/247.

- SM1071 (91a9db24) **a notice over the cap is folded into the next message.**
  A notification rule's `per_recipient_hour` refused the events past it, so a
  member following a busy thread heard of the first comments each hour and
  never of the rest. Past the cap an event is now held, and so is every later
  one while something is held; when the hour moves on the recipient gets ONE
  message carrying them all, in order, each part as the rule's template
  renders it and the subject saying how many more are folded in - counted
  against the cap like any other message. The bell folds the same way. A held
  event is an audit row of its own (`held`); a held message carries at most
  50 events; a cap of 0 still sends nothing (SM1010 R1, Q7 as ruled).
  t/unit/lib/93.
- SM1053 (bdaef5c2) **a new account in an import never joins an operator or a
  registration group.** The rule an update has had since it was built now holds
  for creation: an account an import creates joins the named groups that exist
  except an operator group (the manager flag, nesting included) and a registration
  group. The dry run shows each refused group and why; a row naming only such
  groups still creates the account, in none. t/integration/258.

- SM1075 (215837d2) **a rewrite into a held folder is repaired by reapply - a
  test, no change.** Files written again into a folder already held as a draft
  left the private copy in place and `acl reapply` refused ("the private store
  already holds this path"). Reproduced on main: SM981 already fixed it - the
  repair merges, keeps the private copy of a page both trees hold, moves the
  other to `lazysite/displaced/` and names it. t/integration/257 holds it, and
  fails on the tree before SM981.

- SM1053 (a2a73d94) **an account import can be staged over MCP.** The MCP tool
  `stage_accounts` is the twin of `accounts-import-stage`, declared on the
  action: the same rows or CSV, never a password, `manage_users`, audited, and
  nothing created. Listing, planning and applying an import stay the
  operator's, in the manager, with no MCP tool. t/integration/256.

- SM1053 (8e6ace8f) **an account import updates the existing accounts the
  operator ticks.** A staged row for an account that already exists is no
  longer only skipped: the dry run lists each change it would make - the
  address, a group to join, a group to leave (a row's `groups` is the set the
  account should have; a row without `groups` changes none) - and the apply
  makes only the changes the operator ticks (`updates`, the change ids). Never a
  password. Groups are those that exist and never an operator group or a
  registration group, in either direction, and an operator's own account is not
  changed by an import. Leaving a group ends no session: groups are read on
  every request, so the account loses that group's access at once. Each change
  is audited (`accounts-import-update`), naming no address. t/integration/255.

- SM1053 (bd3e093c) **a staged account import can be removed.**
  `accounts-import-remove` (and Remove on the Account import page) deletes a
  staged import: the account that staged it may remove it, by token or in the
  manager, and the operator may remove any. Another holder of `manage_users`
  may not. Accounts an applied import created stay. Each removal, and each
  refusal, is audited naming the import. t/integration/254.

- SM1053 (afb21fbc) **an account import mails the claim links when the
  operator chooses.** `accounts-import-apply` takes `mail` (the Account import
  page's checkbox), off unless sent: each new account is mailed its own claim
  link at the address its row carries, through the site's mail (the Form SMTP
  extension) and within its per-hour bound, `mail.per_hour` in notify.conf,
  which notices already share. A send that fails or that the bound refuses is
  reported on its row, with the link still shown to the operator, and never
  stops the apply; each send asked for is audited (`accounts-import-mail`,
  naming the account, not the address). t/integration/253.

- SM1069 (3b159190) **a `.url` page under a read rule is no-store, and a rule
  is found by its path's ancestors.** The `.url` output path never passed the
  protected flag: a `.url` page under a read rule or draft was answered
  cacheable to its reader, and its render was read from and written to the
  cache beside its source - in the document root for a source there. It now
  takes the `.md` page's treatment: `no-store, private`, cache neither read nor
  written. Every other output path was checked; none had the gap. A rule is
  now looked up through its path's ancestors instead of a walk over every key,
  so a registry rebuild costs pages, not pages x rules: on 1,800 per-post rules
  the first render after a stale registry went from 5.3 to 1.6 CPU seconds.
  t/integration/240-241, t/unit/processor/128-129.

- SM1065 (baa96ae2) **a preview renders a page where its site serves it.** The
  manager's `preview-public` and `preview`, and MCP `preview_public_page`,
  sent a domain's page to its Host under the docroot path, so
  `/sites/mine/index` answered 404 under `mine.test`; and a primary page asked
  while the request carried a domain's Host came back as the domain's page of
  the same name. Every single-page preview now takes the Host and the URL from
  one helper, `Domains::served_at`, which MCP `preview_page` (SM1031 (c)) now
  shares; a primary page renders with no Host. `preview_public` names a primary
  render `(default)`. `domain-preview` had no mismatch. t/integration/226.
- SM1066 (9ccdb087) **one lookup finds the processor for every preview.** MCP
  `preview_page` looked beside lazysite-mcp.pl, and `preview_public_page` and
  `preview_domain` read `LAZYSITE_PROCESSOR` or the docroot's `../cgi-bin` -
  so where the cgi-bin is elsewhere (install.pl's `--cgibin /usr/lib/cgi-bin`)
  and MCP is not handed the variable (the nginx and Hestia wiring), those two
  shelled a processor that was not there. `Lazysite::Paths::find_processor`
  now serves every preview: `LAZYSITE_PROCESSOR`'s directory, beside the
  running CGI, the docroot's `../cgi-bin`. Every packaged layout that found the
  processor finds the same file. `preview_public_page` now answers a page that
  is not UTF-8 as one it cannot read whatever the render returned (SM976 Q15j),
  which its test met only because its rig had no processor.
  t/integration/227, t/unit/lib/90, t/lint/258.
- SM1078 (2e9b02f1) **every CGI finds the engine's modules wherever the cgi-bin
  is.** install.pl puts the modules at `{docroot}/../lib`; the CGIs looked only
  beside themselves, so on install.pl's own example (`--docroot /var/www/html
  --cgibin /usr/lib/cgi-bin`) every CGI but the linked form handler died
  "Can't locate Lazysite/Util.pm" (the processor rendered, and failed the
  features it loads modules for), and the install's health check passed it.
  Every script a cgi-bin runs, and the processor's lazy lookup, now follow one
  rule: beside itself, its parent, its grandparent, then the docroot's
  `../lib`. Every layout that worked resolves to the same directory: probed by
  installing each documented layout and running each CGI, 59 working cases
  unchanged, 31 fixed. Docs: install.md's hand-copy Apache section (the
  processor alone) is replaced by `provision` plus the vhost tool, OPERATOR.md's
  layout shows where the cgi-bin, lib, plugins and tools go, and the README no
  longer points at an empty Docker directory.
  t/integration/259, t/unit/lib/97, t/lint/263.
- SM1068 (02c590bd) **a write-only rule leaves a page cacheable, and the rule
  store is decoded once per change.** Ruled "Read/draft only": only a `read`
  list or `draft` governs a page. A write-only rule (an owner, a `write` list)
  no longer makes a page per-viewer: it is cached, answers without `no-store`,
  and is listed in the sitemap, feeds and llms.txt; a static under one takes the
  public revalidation default. Read lists and drafts behave as before, and an
  undecodable or unreadable `acls.json` still fails closed. An `::: include` is
  confined by the same audience rule. The processor reads `acls.json` through
  one reader, keeping the decoded store across requests keyed on the file's
  mtime, size, inode and ctime (a persistent worker decodes once per change; a
  CGI request once), where it decoded it per request and once more per draft
  check. The shared page cache now takes only a render made for no viewer: a
  layout printing `auth_user` had handed the first signed-in viewer's name to
  every later visitor of any public page. Measured on 1,800 per-post write
  rules plus `/`: a post 0.46 s to 0.20 s (CGI) and 0.34 s to 0.004 s (pooled),
  `Cache-Control` `no-store, private` to `no-cache, must-revalidate`.
  t/integration/236-239, t/integration/74, t/unit/processor/127, t/lint/259.
- SM1070 (9703d552) **a removed account's session ends with it.** Security.
  Removing an account wrote no revocation, and the cookie verifier never asked
  whether the account existed, so a removed account's cookie still counted as
  that account until it expired: on main it reached the members' pages,
  /account, the bell, a data CSRF token, and a form post that skipped the rate
  limit and wrote a personal row in the removed name; on 0.15.4 and earlier it
  also wrote content through the manager (the SM1057 hole). The verifier now
  refuses an account that is not in `lazysite/auth/users` (`no-account`; an
  unreadable store refuses every session as cannot-tell), and `remove` and
  `rename` sign the account's sessions out by name before changing anything,
  so an account created later under the name inherits none. Disabled accounts
  were already refused on every cookie door. The wrapper's passwordless flag
  now comes from the same read, so a request reads the account store once.
  t/unit/auth/55-56, t/integration/243.

- SM1064 (36bf553a) **a preview is no visit, on every door.** MCP
  `preview_public_page` and `preview_domain`, and the manager's `preview`,
  `preview-public` and `domain-preview`, each wrote a visit to the first-party
  access log. They now set `LAZYSITE_PREVIEW`, which the log leaves out, as
  SM1031 does for `preview_page`. Measured in one rig that names the processor
  (`LAZYSITE_PROCESSOR`), which SM1031's probe lacked. t/integration/225.

- SM1053 (80c18383) **a partner stages accounts, and the operator applies
  them.** `accounts-import-stage` takes a list of accounts - usernames,
  addresses, groups, never a password - and creates nothing. The operator
  reviews the dry run on the new Account import page (linked from Users) and
  applies it: each account is created without a password, in the named groups
  that exist, with a claim link, and each is audited. Mailing the links is not
  built yet; the recorded address lets a member use "forgot password".
  t/integration/212.

- SM1052 (5e09ff0e) **one rule for many paths, and an import by the table's
  writers.** `acl-set` takes `"paths": [...]` with one rule: every path is
  scope-checked and validated before any is written, one refusal changes
  nothing, and the trail records one row per path. `data-import` now follows a
  table's `writable_by` as a row save does - an account the list does not name
  is refused, whatever it holds - and the table's owner (the owner of its access
  rule) may import past it, so a bulk load no longer needs the list cleared.
  t/integration/211.

- SM1051 (fee70911) **a handler may belong to a domain.** A handler carries
  `domain:`, and a partner confined to that domain creates, changes and deletes
  it, sees it in `handler-list`, and binds its forms to it or to an instance
  handler. A handler with no domain is the instance's and stays out of a
  confined caller's reach; another domain's handlers are neither shown nor
  bindable. t/integration/210.
- SM1057 (1fddc26a) **security: the first access rule on a page needs
  `manage_content`.** Ruled 2026-10-12 ("Require manage_content"). In the
  manager, an acl-set that creates the first rule on a content path that has
  none needs `manage_content` from a non-operator, as the control API and MCP
  already require. Before, an account with `ui` alone could claim any unruled
  page - or the whole site - with a rule only it could write. The owner of an
  existing rule still changes it; paths in the engine's tree are exempt.
  t/integration/223.

- SM1057 (b2c8d84b) **security: a content write in the manager needs
  `manage_content`.** Ruled 2026-10-12 ("Require manage_content"). On the
  manager API's cookie door save, delete, move, copy, file-upload, mkdir,
  migrate-to-local and the edit locks need `manage_content`, as WebDAV and MCP
  already require; the file's rule still applies on top, so a rule naming an
  account no longer lets it write without the capability. An account with `ui`
  alone is read-only in the manager. Paths in the engine's tree keep their own
  capabilities (nav.conf's `manage_nav`); operators and unsecured sites are
  unaffected. t/integration/222.

- SM1057 (cc74c21e) **security: the manager API's cookie door needs manager
  access (`ui`).** A signed-in account in no group - a member login holding no
  capability - could send `save` (and delete, mkdir, move, copy, file-upload,
  lock, acl-set on an unruled path) to the manager API with its cookie and
  CSRF token, and write any path no access rule governs: the content writes
  self-authorise against the file's rule on this channel, and the door never
  asked for the `ui` capability the /manager/ pages require. Paths are
  docroot-relative on every host, so on a domain the writes landed in the
  primary site's tree. A non-operator cookie session now needs `ui` (from its
  account or its session's groups), as a token needs `api`; an unsecured site
  is unchanged. Affects v0.14.4 and every v0.15.x. t/integration/220, 221.

- SM1061 (d4e0ed28) **internal: the handoff is the precheck, and one whole suite
  runs at a time.** Ruled by the release manager 2026-10-12. `tools/handoff.sh`
  runs the precheck on each branch and no whole suite unless `--full` or
  `--release` asks for one. `tools/suite.sh` is the one way to run the whole
  plain suite, behind a host-wide lock in the common git dir (a second run waits
  and says who holds it). The precheck also runs the tests of each area a change
  touches (`tools/precheck-areas.pl`; t/lint/255 keeps the map complete).
  `tools/overnight.sh` runs queued handoffs and then `tools/suite.sh --nightly`
  on main, filing a failure in the inbox.
- SM1062 (18a79e91) **internal: the overnight run tests what is about to land.**
  Ruled by the release manager 2026-10-12. `tools/overnight.sh` hands the queue
  to `tools/integration.pl`: it detaches every queued worktree at main,
  prechecks each stack, cherry-picks the stacks onto main in queue order as
  `review/assess/integration` (a conflict is reported and left out), and runs
  one whole suite there (`tools/suite.sh --tree`). Green prints `LAND IN THIS
  ORDER:` and READY FOR REVIEW lines; red names each failing file's cause -
  main, a stack, or two stacks together - and only those stacks are NOT READY.
  An empty queue runs the plain nightly on main. t/tools/145-149.
- SM1063 (0ec4daa9) **a connector sweep that expires nothing counts zero.** The
  sweep declared its counters after the kept list in one list assignment, so
  the list took the zeros: a sweep that expired nothing reported `expired:
  null` (and `unanswered: null` with no stuck calls) in the daemon's run record,
  and a sweep that expired something wrote `00` in front of the first record it
  kept, which then no longer read. The counters are declared first.
  `t/lint/257` refuses a scalar after an array or hash in a `my`/`our`/`state`
  list with an assignment; no other instance in the tree. t/unit/manager/335,
  t/lint/257.
- SM1081 (ee160471) **OOM's changes no longer gate a lazysite build.** The release gate failed
  three times on 2026-10-13 and 14 for changes in OOM's working tree and in whichever OOM the
  host had. The Odoo extension's tests now run on a pinned snapshot of OOM 0.09 held in
  `t/vendor/oom` (library, test doubles, data, specification; held to a MANIFEST by
  `t/lint/261`), `t/lint/207` compares SM747's filed specification with the vendored copy and
  has no skip, and `t/lint/262` fails any test, library or tool that names OOM's tree or the
  host's perl5 directory. `tools/vendor-oom.sh` adopts a newer OOM as one commit that also
  updates the filing. `tools/ext-compat.sh` runs the same tests against the installed deb and
  OOM's tree as an advisory tier from the overnight run: it always exits 0 and files an inbox
  note on a failure. The lazysite packages do not depend on OOM. t/tools/154-155.
- odoo-extension (4c932a62) **applying an Odoo plan works with OOM's approval gate (SM747).**
  OOM's runner now refuses to apply a plan nobody approved. A confirm is recorded as
  its maker's approval, and an `apply: immediate` binding as the binding's, each against
  the plan's fingerprint, immediately before the apply; OOM's gate is left on. Without
  this every apply was refused against an OOM that has the gate. t/unit/odoo/40.
- odoo-extension (6256d111) **one browser module talks to the Odoo endpoint (SM747 D).**
  `/assets/lazysite-odoo.js` fetches the tokens, retries a stale one once, asks a person to
  sign in when the endpoint says to and retries the call once, signs in and out, and fills
  `data-ls-odoo` regions from a binding as text, only for the fields the server drew. The
  password is read, the box is cleared before the answer arrives, and it is in one POST body
  and nowhere else; nothing is stored in the browser. Injected only on a page whose markup
  uses it, on both render paths, and served on every domain. t/unit/odoo/31, t/integration/174.
- odoo-extension (c494bd13) **a page can greet a person signed in to Odoo (SM747 C).** `tt_page_var:
  me: odoo-identity:` gives `me.name`, `me.lang`, `me.tz`, `me.company_id`, `me.company_ids` and
  `me.groups` (empty until OOM offers a groups read) from a second signed cookie, short-lived
  (`odoo_identity_ttl`, default 15 minutes) and refreshed from the person's session on the next
  call after it ends. It is for presentation only; a tampered or ended cookie renders as nobody
  signed in; and the page is never read from or written to the shared page cache. t/unit/odoo/28-30.
- odoo-extension (14994a23) **a person can sign in to Odoo through a page and run bindings as
  themselves (SM747 B).** A binding with `credential: session` runs on the signed-in person's
  own Odoo session, over OOM's session transport (OOM 0.03, now the declared minimum), and as
  nobody else: with no sign-in, or once Odoo has ended the session, it is refused and never run
  as the connection user. The Odoo endpoint signs a person in (`signin`) and out (`signout`);
  the password goes to Odoo through OOM and is kept nowhere, the session id lives only in a
  signed, 12-hour, HttpOnly, SameSite=Strict cookie scoped to the endpoint, and sign-in attempts
  share the site's login rate limiter. Two-factor accounts are refused by name. A session
  binding is not offered over the control API or MCP, and not run by a form, the schedule or a
  page render. t/unit/odoo/24-27.
- odoo-extension (c89e75dc) **an Odoo report's fields are drawn, or refused by name (SM747
  R wiring).** When an operation returns `rows` beside `fields` (OOM 0.02), `odoo_run`
  and the page endpoint answer `fields` (each held to the data extension's descriptor
  check) and `refused` (each field lazysite could not draw, with why) beside the
  report; the `odoo:` page binding gives the page those, with the rows cut to the drawn
  columns. A report without descriptors is unchanged. t/unit/odoo/23.
- odoo-extension (fc78ef91) **the Odoo extension is documented (SM747 F1).**
  `/docs/odoo` describes what the extension needs, the connection, the
  connection user's key, bindings and where each runs, the anonymous write
  path and its caps, a grant's own Odoo account, domains, the call record
  and the refusals. SECURITY.md carries four operator entries for it, and
  FEATURES.md a section.
- odoo-extension (c77df5f5) **a binding that belongs to a domain runs only for
  that domain (SM747 E-Q1).** A binding with `domain:` answers the page
  endpoint, the `odoo:` page binding and a form only on its own host, and the
  control API's `odoo-run` and MCP's `odoo_run` only for a caller that reaches
  the domain; anywhere else it is refused as `wrong-domain` (403) and recorded.
  The schedule runs it. `odoo-bindings` lists only what the caller may run. A
  binding without `domain:` is the instance's, as before.
  t/unit/odoo/19-20, t/integration/172.
- odoo-extension (6b33ebe6) **every Odoo action is an MCP tool, and an agent runs
  a bound operation as its grant's own Odoo account (SM747 slice E).**
  `odoo_status`, `odoo_calls`, `odoo_secret_set` and `odoo_secret_clear` are the
  twins of the control-API actions; `odoo-bindings`, `odoo-run` and
  `odoo-confirm` (and their twins) list and run the bindings a signed-in caller
  may use, under the binding's own callers, modes and caps - never as a visitor.
  An operator can give a grant its own Odoo login and key (`grant`, `login` on
  `odoo-secret-set`); its MCP calls then run as that account, otherwise as the
  connection user. t/unit/odoo/17-18, t/integration/171.

- SM1012 (a5a9af14) **internal: `render_content` is split at its seams.** The
  Template object for a content pass is built by `_tt_engine`; what the manager
  UI needs to know about the user (capabilities, scopes) comes from
  `_render_manager_facts`; the site's and the page's language from
  `_render_lang`; the page body's template variables from `_render_stash`, still
  the one point every escaped family enters; and the body goes through the
  template with its code protected in `_tt_process_protected`. `render_content`
  is 63 lines, from 435. Each step changes no other sub (tools/deparse-subs.pl),
  each block deparses as the sub it became where it has one exit
  (tools/deparse-block.pl), and t/unit/processor/113 passes unchanged. No
  behaviour change.

- SM1012 (197879c2) **internal: what the content renderer produces is
  recorded.** t/unit/processor/113 renders 34 written cases through
  `render_content` - the stash under five request contexts and two hosts, the
  code-block protection, the TAGS guard, a template error, the before_render
  hook - and compares the body, the stash, the response language, the log
  lines, any die and the umask it leaves with a committed record. It is the
  gate for splitting `render_content`. No behaviour change. It records one
  finding: when the template compile directory cannot be made, the umask the
  render widened is not put back (SM1012).

- SM1012 (537d7281) **internal: `_render_form` is split at its seams.** A field's
  rules are tokenised by `_form_rule_tokens` and read into the field's rules by
  `_form_rules_from_tokens`; its value, the literal or the declared prefill,
  comes from `_form_field_value`; the rule the server holds it to (SM934) from
  `_form_server_rule`; its markup from one renderer per field kind (file,
  textarea, select, radio, checklist, input), chosen by a table in the order the
  old chain tested them; and the outcome banner from `_form_outcome_banner`.
  `_render_form` is 210 lines, from 562. Each step changes no other sub
  (tools/deparse-subs.pl), each block deparses as the sub it became where it has
  one exit (tools/deparse-block.pl), and t/unit/processor/112 passes unchanged.
  No behaviour change.

- SM1012 (2c86550e) **internal: what the form renderer produces is recorded.**
  t/unit/processor/112 renders every `:::form` block in the starter, the docs,
  the website and the test fixtures (plain, prefilled with a hostile value, and
  under each outcome) and 73 written cases - every rule, every field kind, and
  each branch the 0.15.5 coverage left unreached - and compares the HTML, the
  rules sidecar, the log lines and the warnings with a committed record. It is
  the gate for splitting `_render_form`. No behaviour change.

- SM1012 (56550bca) **internal: the deparse comparisons a split is proved with
  are in tools/.** `tools/deparse-subs.pl` deparses every processor sub and
  compares two trees (or a tree and a saved listing), naming the subs that
  differ and passing only when exactly the expected set does;
  `tools/deparse-block.pl` compares a block of an old file, wrapped as a sub,
  with the sub extracted from it. They were untracked scripts under tmp/, so a
  reviewer could not rerun the proof. Development only, not shipped.
  t/unit/processor/111.
- SM1010 R5 (3eec2e43) **`manage_notifications` reaches the Handlers page on its
  own.** A group holding only the capability that writes notification rules
  could not open the page they are written on: the handler actions asked for
  manage_forms, manage_data or manage_connectors. It now opens handler-list,
  handler-save and handler-delete on both doors, and is shown, and may write or
  delete, only notify handlers - not the site's other handlers, their settings
  or the form bindings. The schedule actions and binding are unchanged.
  t/integration/195.

- SM1042 (3fe14ea1) **a member sets up their own two-factor; a manager can only
  reset it.** `/account` gains "Two-factor sign-in": set up with the current
  password, confirm with a code from the app, turn off or make new recovery
  codes with the password and a current code (turning it off signs the other
  sessions out). The secret and recovery codes are shown only to the account
  they protect. The Users page no longer sets up anybody's two-factor and never
  shows a secret or a code: it offers Reset 2FA, and the manager API refuses
  the enrolment verbs. t/unit/account/04.

- SM1044 (5e3de77f) **a member reads the notices addressed to them.** `/account`
  gains "Your notices": the notices a notification rule addressed to the
  signed-in account, with read, dismiss and mark-all-read, over new actions
  `me-notices` and `me-notices-seen`. Never a broadcast and never another
  account's; the account keeps its own last 100 however busy the site's store
  is. No capability is needed (SM1010 R2). t/unit/account/03.

- SM1043 (522c0c1e) **a member has an account page, `/account`, in the site's
  own theme.** A signed-in account with no manager access can see who it is
  signed in as, change its password (with the current one; the others are
  signed out), see where it is signed in, end one of those sessions or sign out
  everywhere. It is a system page (a site's own copy wins; a deleted one comes
  back) built from `::: account-*` components a layout can restyle, over new
  control-API actions `me`, `me-password`, `me-sessions`, `me-session-revoke`
  and `me-sign-out-everywhere`, which act only on the signed-in account, need
  no manager (`ui`) access, refuse an access key, are CSRF-gated and audited;
  password checks count against the sign-in rate limiter. `account_page:
  disabled` in lazysite.conf turns it off. t/unit/account/01, 02, 05; lint 246.

- SM1041 (12b275bc) **a password has a minimum length, 12 unless the operator
  says otherwise.** `password_min_length` in lazysite.conf (8 to 128; default
  12) applies to every way a password is set - the users tool's add, passwd
  and account-create, setup-sysop, and a setup or reset link. A password set
  before it keeps working until it is changed. A setup link given a password
  that is too short is not used up: the page says how long one must be and
  offers the form again. t/unit/auth/41.

- SM1040 (3d273e89) **a changed credential signs the account's other sessions
  out.** SECURITY. A password change wrote the new password and nothing else,
  so a session stolen before it stayed signed in. Now any password change -
  the account's own, an operator's `passwd`, a redeemed setup or reset link -
  and turning 2FA off end every other session of that account, legacy cookies
  included; the session that made the change stays signed in, and a later
  "Sign out everywhere" ends it too. The session kept is taken from the
  verified cookie and only for the caller's own account, never from a request.
  A revocation that cannot be written refuses the change. t/unit/auth/40.

- SM1020 (89a839a1) **notification rules are sent, once each, by the daemon.** A
  new engine job, `notify-outbox`, sends what `notify` handlers queued: it
  resolves the recipients, leaves out whoever caused the event (unless the
  rule says `notify_actor: true`), applies the rule's per-recipient cap,
  renders the rule's template and mails each recipient once - a retry after a
  transport failure reaches only those not yet sent to. Each message carries
  an unsubscribe link and a `List-Unsubscribe` header unless the rule turns it
  off, and a non-ASCII Subject is encoded (RFC 2047). One audit row per
  recipient names the account or address. The job account needs
  `manage_notifications`. A rule may also ring the site bell for each account
  it names, and a notice addressed to one account is now shown to that account
  only - the bell showed every notice to every holder (SM1010 F3). Compliance
  with privacy and consent rules is the operator's responsibility (docs/forms).
  t/unit/notify/03-05.

- SM1019 (b36a89f0) **a `notify` handler: a notification rule over a form
  event.** A new handler type, bound as a form's second target (or a schedule
  entry), whose recipients come from accounts, the owners of matching rows,
  addresses held in a table, fixed addresses or the submitter. Saving one
  needs the new `manage_notifications` capability - off by default, held by
  the sysop (manager) groups. Delivering it queues the event for the daemon
  and returns, so the visitor never waits on the sends; a quarantined
  submission queues nothing. t/unit/notify/01, 02.

- SM1018 (9b6f584f) **a signed-in member's form post names the member.** The
  form handler verified the session cookie only to waive the rate limit and
  delivered every submission with no actor, so a table handler declaring
  `row_policy: personal` wrote rows that belonged to nobody even for a member.
  The account a VERIFIED session names is now the delivery's actor (SM1010 Q1):
  the row is the member's, and the audit trail names them. The stored
  submission carries no name, a forged cookie or `X-Remote-User` header names
  nobody, and anonymous posts are unchanged. t/unit/forms/07, 08, 62.

- SM1017 (25c7f06f) **a quarantined submission is not acknowledged, and a mail
  header names exactly one address.** SECURITY. A form whose email handler
  acknowledges the submitter (`mail_the_submitter_field`) mailed the address a
  QUARANTINED submission gave: the check read a flag the form handler strips
  before delivery (SM1010 F1, reproduced through form-handler.pl). And the
  address could name two recipients - `root,victim@example.org` passed the
  shape check and reached `sendmail -t` whole, and `x<b@example.org>` was
  repaired into a different address (F2). An address the site puts in a mail
  header is now exactly one address - no `, ; < >`, no line break - refused
  otherwise, by the handler, the header writer (every message), a handler's
  own `to`/`from`, and an account's address. A hand-written `to:` naming two
  addresses now fails at send and says why. t/unit/forms/60, 61.
- SM1024 (375c8fe8) **an undecodable groups-settings.json makes nobody a
  manager.** Ruled 2026-10-12 ("Fail closed everywhere"). A store that opened
  and did not decode read as "no groups" in Auth::Settings - the unsecured
  mode, in which every signed-in account is a manager and an ACL operator -
  while pages already treated it as secured. It now sets the same state as a
  store that will not open: the manager API, MCP and sign-in refuse with
  `cannot-tell` (503) naming the file and saying it does not decode, until it
  is repaired; groups are not offered as assignable; the users tool refuses to
  write over it. On the render path an acls.json that does not decode is a
  failed load for every reader: it could be cached as "no rules" and let a
  later check in the same request allow every path, and registry builds list
  governed pages. The MCP audit flags it and the scheduler names it.
  t/integration/185, 186; t/unit/mcp/19; t/unit/daemon/10; t/tools/126.
  Then ruled "Close all three" for the three stores that failed open on both
  a failed open and a failed decode: a broken acls.json refuses a
  non-operator's per-file check in the manager, WebDAV and data tables with
  `cannot-tell` (503) naming the file, while the operator works on and can
  repair the rule; a broken revoked.json or user-settings.json refuses sign-in
  (the page says sign-in is unavailable and the log names the file) and every
  existing session, and the Sessions page refuses rather than writing over
  it. An absent store is still a fresh site. `lazysite check --docroot` FAILs
  on either session store when it does not decode, naming it.
  t/unit/auth/52; t/integration/187, 188.

- SM1023 (372aef0f) **`lazysite check` tells an auth store it cannot read from
  one that is absent.** Seen on sites.lazysite.io after the 0.15.4 upgrade: run
  as an account outside the site group, the check said "no group grants manager
  access - the manager is unconfigured"; as root it said "manager
  bootstrapped". groups-settings.json was read with `|| {}`. Now an absent store
  is the unconfigured manager; one this run cannot open is a WARN naming the
  file and the user, saying the manager state is unknown and to run as root or
  the site user; one that does not decode is a FAIL naming the file. The same
  rule now covers the manager-account verdict (auth/users, auth/groups),
  `manager: enabled` (lazysite.conf) and acls.json (unreadable: WARN;
  undecodable: FAIL, the renderer refuses every page it checks against the
  ACL). `--check-acl` no longer starts from an acls.json it cannot read or
  decode, which it would have rewritten from an empty map. t/tools/126.

- SM1016 (9f8de4cb) **a domain names only groups and accounts that exist.**
  Ruled 2026-10-12 ("lazysite-domains.pl should reject invalid groups").
  `domain_set` refuses a NEW name in `allowed_groups` that is not a group on
  the site (the groups file or groups-settings.json), or in `locked_users`
  that is not an account, naming every unknown one and writing nothing; a
  store that cannot be read refuses the write. It is in `domain_set`, so the
  Domains page, the control API's `domain-set`, MCP `domain_set` and every
  `lazysite-domains.pl` command get it. A name the list already holds is not
  asked about, so a group deleted after it was allowed can still be taken out.
  The Domains page now shows a refused save's reason; it used to carry on and
  say "Saved". t/unit/manager/284, t/tools/121, t/integration/150.

- SM1015 (2d403e12) **`lazysite-domains.pl group-add` and `group-remove`.**
  Ruled 2026-10-12 ("lets have cli command to add the domain group").
  `lazysite-domains.pl --docroot DIR group-add --host H --group G` adds one
  group to a domain's `allowed_groups` and keeps the others; `group-remove`
  takes one out; `user-add` and `user-remove` do the same for `locked_users`.
  `G` may be `@name` or `name`. The list is written through `domain_set`, so
  validation, the content-history commit and the log line are the ones every
  surface gets. Adding a name already there, or removing one that is not,
  says so and exits 0. A group or account the site does not have is refused,
  naming it, because a misspelt group admits nobody; a store that cannot be
  read refuses the add. The tool gains `--help`. t/tools/120.

- SM1014 (76a6c505) **a group is `@name` wherever one is picked or shown
  beside people.** Ruled 2026-10-12 ("groups should be prefixed with something
  say @ ... consistent anywhere a group is picked"). Files and Data already
  offered `@staff`; the Groups members picker, the Domains access picker, the
  add-user group picker, Connectors' caller groups, the Users page's group
  ticks and capability grid, the Settings "Granted by" note and the approval
  message named it `staff`. All now show `@staff`, through one layout helper;
  the shared picker's `groupPrefix` option, which let a page name groups
  plainly, is retired and lint 230 keeps it so. On the Groups page the `@` is
  what decides nest-or-add, so a person who shares a group's name can now be
  added. A group is accepted with or without its `@`; **storage is unchanged**:
  ACL rules keep `@staff`, while `allowed_groups`, a group's member list, a
  connector's callers and group-add keep `staff` (`domain_set` now takes
  `@staff` in `allowed_groups` on every surface and stores `staff`).
  `lazysite-users.pl groups` lists a nested group as `@staff`. Docs: manager
  guide (Groups, Users, Domains). t/unit/manager/282, 283; t/lint/230.

- SM1013 (ee93c190) **a group or user added to a domain's Access section is
  saved.** On the Domains page, adding a group to `allowed_groups` (or a user
  to `locked_users`) and pressing Save said "Nothing had changed." and kept
  nothing: the dirty check recognised the picker by a class it was never
  drawn with, so it read as empty before and after. Adding or removing a pill
  now marks the field changed, the unsaved count says so, and Save posts
  `domain-set` with the new list. t/unit/manager/280. Checking every page for
  a picker its save does not read found one more: a connector's **caller
  groups** were drawn as checkboxes and read back from a text box that is only
  drawn when the group list cannot be read, so every save on a site whose groups
  could be read dropped them (the connector then refused every signed-in
  caller) and said "Saved". The ticked boxes are now what is saved.
  t/unit/manager/281.
- SM887 (285c0a6c) **the claude.ai skill renders a pulled theme styled.** With
  a site's layout and theme pulled into the skill's local tree, every
  stylesheet link 404'd: `/lazysite-assets/<layout>/<theme>/` is written when a
  theme is activated, and nothing activates one there. `serve.sh start` now
  runs the skill's `mirror.pl`, which calls the engine's own mirror step, so
  the assets, `theme-tokens.css` and the fingerprint are in place.
  `site-context.md` gains the nav.conf format note it pointed to and lists the
  conf keys the reconstructed conf leaves out, with how to learn them;
  `setup.sh` says the skill folder may be read-only or writable. Found in the
  release manager's real-session test of 2026-10-12, recorded in SM887.
  t/tools/83, 130, 131.
- odoo-extension (2d8081d4) **Odoo's field descriptors in the data extension's
  terms, by portable type (SM747 slice R, the interface).** A field is drawn as
  one of the data extension's seven types only from the portable type OOM hands
  over, and checked by the data extension's own descriptor rules; a field
  without one, or one those rules refuse, is refused by name rather than
  guessed. A binding's parameter form lists exactly the fields a request may
  set, typed from the operation's declaration. Drawing reports with it waits on
  where a report carries its descriptors (recorded in SM747, filed to OOM).
  t/unit/odoo/16.

- odoo-extension (8511cda1) **a page uses Odoo: the endpoint, the `odoo:` page
  binding and the connection user's key actions (SM747 slice CU, the
  surfaces).** `lazysite-odoo.pl` lets a page's own script run a binding: it
  hands out a visitor token (and the session one for a signed-in account), runs
  a read on a GET, and runs or confirms a write on a POST that carries the
  matching token - the visitor's cookie is HttpOnly and SameSite=Strict, so a
  cross-site post cannot use it. `tt_page_var: x: odoo:ID` renders a read
  binding's report, escaped, and never runs a write or a visitor's binding.
  New actions (manage_connectors): `odoo-status`, `odoo-secret-set`,
  `odoo-secret-clear`, `odoo-calls`; the key is never returned.
  t/integration/170, t/unit/odoo/14-15.

- odoo-extension (4d2e8e69) **an Odoo operation runs as the site's connection
  user, and a visitor reaches only their own basket (SM747 slice CU, the
  engine).** The connection user's API key is stored alone, 0600, and never
  shown. A handler of type `odoo` binds a named operation: which request
  fields feed which parameters (plain values only - a domain, a list or a file
  path can only be fixed by the operator), who may run it, and its caps per
  visitor and per binding. A read returns its report; a write returns its plan
  for its maker to confirm, or, with `apply: immediate`, applies it at once - the
  ruled basket case. A visitor's key is minted and signed by the server and
  reaches the operation only through the binding. A form or the schedule can
  run a binding. t/unit/odoo/06-13.

- odoo-extension (a3c86e97) **the Odoo extension's skeleton: its declaration,
  the connection and every refusal before a call (SM747 slice A).** `plugins/odoo.pl`
  declares `Odoo::Ops (libodoo-oom-perl >= 0.02)`; a dependency may now name its
  package and oldest version, and enabling an extension whose module is missing
  or older names that package. The connection (`odoo_url`, `odoo_db`,
  `odoo_login`, timeout, answer cap, writes switch) is checked once: https:// to
  any host, http:// to loopback only, never to a private address. Odoo's faults
  become named kinds with their text kept in the log; every call and refusal is
  one fixed-field record. Nothing calls Odoo yet. t/unit/odoo/01-05, lint 240
  (lazysite holds no Odoo knowledge).
- SM1046 (ebaa8269) **a token's new domain may adopt an existing folder.** Ruled
  2026-10-12, "Allow adoption": a domain a token gives to its own group may use
  an existing folder as its content root when the folder lies outside every
  domain. A protected folder - in the private store, or touched by any access
  rule - is still refused, because adopting it would show the group its rule
  and, with an empty write list, let the group write it. t/integration/200.

- SM1046 (8f654c69) **a token creates a domain for its own group.** A
  `manage_domains` token with no scope was refused `domain-add`, because it
  reached no domain until a domain named its group. Ruled 2026-10-12, "Allow,
  own group only": it may now add a domain whose `allowed_groups` names groups
  its account is in, with a new content root outside every existing domain;
  it then reaches that domain and no other. A group it is not in is refused,
  naming none is refused with a message saying to name one, and the audit row
  names the group. t/integration/200, t/unit/auth/51.

- SM1045 (ad361042) **a group with no members is a group.** `acl-set` reported a
  group created on the Groups page as unknown until someone was in it, and
  refused a list naming only such groups, because the known groups were read
  from membership alone. They are now the groups in either store; a name in
  neither is still unknown. t/unit/auth/50, t/unit/manager/300.
- SM1035 (b4897d85) **a template engine that cannot be built leaves the umask
  as it found it.** When the TT compile directory could not be made, the
  content renderer and the registries widened the umask to 0002 for it and
  then died inside `Template->new` - which dies rather than returning false -
  past the line that restored it, so a persistent process wrote what came next
  group-writable. Both now build the engine under `eval`, restore the umask and
  re-throw the same failure. t/unit/processor/126.

- filing-ids (5d025a4e) **a filing the release step stamps carries its id.**
  The release step stamps a filing's "SHIPPED (PENDING)" by its `id:`, and 35
  such filings had none - SM842 and 34 under `docs/feature-requests/archive/`.
  Each now carries the id its file name gives it, and lint 244 holds every
  PENDING filing to an id that matches its name.

- SM1037 (74651ae2) **the nav docs describe the format the parser reads.** The
  configuration doc and the agent briefing on configuration said the nav file
  is YAML (`- label:`, `url:`, `children:`); the engine reads `Label | /url`
  lines, so a nav written from the doc rendered as labels with no links. Both
  now give the line format and its rules - a bare label is a heading, an
  indented line a child (one level), `#` at the start a comment. Docs only.
  t/tools/140.

- SM1036 (d4ec4ff4) **a restored site package keeps its rows' keys, policies
  and times.** A package could not restore a table whose key the store assigns
  (the import refused the key the export carried, and the table was skipped),
  brought a personal row back shared - so any writer the table admitted could
  amend it - and dated every row at the restore. A restore now keeps each row's
  auto key (the next row continues after the highest), its `row_policy` (a
  personal row is personal again, to the same owner) and its `created_at` and
  `updated_at` as exported; the log line and `data_restored` count what was
  kept (`keys_kept`, `times_kept`, `policies_kept`, beside `authors_kept`) and
  name the applier. A package without the new fields restores as before; an
  auto-key table in one is now restored at its keys. `insert_row` takes
  `auto_key =>` and `times =>` beside `authors =>`, each refused without an
  actor and, by lint 137, from anything but the restore. t/unit/data/73.

- filing-stamps (c2a25a00) **a release says which release shipped a filing.**
  A filing is written "SHIPPED (PENDING)" because its release is not known on
  its branch, and nothing ever replaced that: 31 filings still said PENDING
  after theirs shipped. `tools/release-material.pl`, which the gate and the
  build run, now stamps the status-note of every filing whose id has an entry
  in the section being released "SHIPPED (X.Y.Z)", and `docs/feature-requests/`
  joins the release-material allowlist (lints 09 and 207 join the build's
  checks). The 31 are stamped with the release whose section names them:
  29 from 0.15.3 and 0.15.4 by a sweep, SM858 (0.15.3) and SM976 (0.15.3,
  0.15.4) by hand. t/tools/111.

- coverage-parts (6fb617e6) **the coverage gate holds every file the CGIs were
  split into.** `tools/coverage.sh --check` named the eight CGIs only, so the
  processor's parts and the manager modules SM944 moved out of the CGIs had no
  floor. Each `lazysite-processor/*.pm` and `lib/Lazysite/Manager/*.pm` is now
  checked against the floors on its own (read from the tree, so a new part is
  gated when it lands), and `dist/config/coverage-floor` gains `floor[FILE]=`
  beside `branch_floor[FILE]=`, used for the four files that measured below
  75/62 at the last gate. t/tools/110.

- SM1003 (459074b3) **`(mine)` shows a viewer their own rows of a table they may
  not otherwise read.** A member could be shown their own follow list only if
  members could read the table, which let every member read every row. A
  `(mine)` binding in a page now returns the rows whose `created_by` is the
  signed-in viewer even when the table's read rule excludes them - only those
  rows: its count, total and a row by key are counted over them alone. A
  binding without `(mine)`, an anonymous viewer, the data endpoint, the
  manager, the API and MCP still follow the table's rule. A table's row
  condition (`where:`, SM982) applies to the own-rows read as to every other
  binding, so a row a moderator has hidden is hidden from its author too, and
  is neither counted nor reached by key (ruled 2026-10-12, "Apply where: too";
  t/unit/data/72 runs once SM982 is in the tree). t/unit/data/71.

- SM1002 (64b50259) **a site can allow its own external hosts in the CSP.** A
  site embedding one legitimate external script (a banner whose script then
  fetches from its host) had no setting to permit it under `csp: enforce`.
  `csp_script_src`, `csp_connect_src`, `csp_img_src` and `csp_frame_src` in
  lazysite.conf, each a list of https origins (`https://host`,
  `https://host:port`, `https://*.host`), are appended to the default for
  their directive; `alias.<host>.csp_script_src` (and the others) gives a
  domain its own list. An entry that is not an origin - a bare `*`, a path,
  `'unsafe-inline'` or any other keyword - is left out and logged, and
  `lazysite check` names it. The manager's pages carry none of them. The
  default policy is unchanged when no list is set. t/unit/processor/103,
  lints 55 and 225.

- SM1001 (5afe5399) **visitor traffic is read per domain, and a confined caller
  reads only its own.** Each visitor-log event already carried the request's
  host (SM151); nothing read it. `analyse_visitors` (control API and MCP) now
  takes `host` - one domain's traffic, counted from the raw log by the domain
  that served each request (an `alias_hosts` host by its own name, any other
  host by the primary, `(default)`) - and `by_host`, requests and visitor-days
  per domain with a stated basis. A caller confined to some domains (SM976)
  sees only their traffic, with or without `host`, and is refused the index,
  day and month rollups and trails, which are the instance's and are not split
  by domain. Previously every caller with `analytics` read every domain's
  traffic. On a one-domain instance nothing changes. t/integration/134.

- SM1000 (3d19b097) **an alias renders from its canonical domain.** A host
  registered as an alias (sharing another domain's content folder, as
  `domain-alias-add` registers it) named itself as canonical, so one site
  answered as two. Its pages' `<link rel="canonical">`, and the addresses in
  the sitemap, `llms.txt` and the feeds of the shared folder, are now the
  canonical domain's `site_url`; the alias still serves under its own name and
  its own `site_url`. A new TT variable, `canonical_url`, carries the address.
  The canonical domain is the one the Domains list names (the first serving
  that folder, the primary first), so a host with no folder of its own is an
  alias of the primary and names the primary as canonical (ruled 2026-10-12,
  "Keep"). t/unit/processor/102, lint 224.

- SM999 (9f529b64) **a YAML list is a list, and a registry carries the page's
  front matter.** A list key other than `tags` - `categories:` with `- item`
  lines, or `keywords: [a, b]` - arrived as raw text. Any flow or block list of
  scalars is now a list in a `scan:` object, a registry object and the page's
  own `page_<key>` (each item escaped). Registry objects (sitemap, feeds,
  `llms.txt`, a site's own JSON index) now carry the page's other front matter
  and its `tags`, as a scan object does, less the engine-private keys
  (`auth_groups`, `payment`, `form`, `query_params`, `sections`,
  `tt_page_var`, `api`, `raw`, `content_type`, `ttl`, `redirect`, and any
  `tt_*`/`_*`). The engine's own keys keep their own readings.
  t/unit/processor/101.

- SM998 (4de84e87) **a failed account read and a crashed handler are audited.**
  Under SM943's rule (refusals and errors are audited): the control API's
  `users` read sub-actions - `users-detail`, `verify-credential` and the
  other reads - now write an audit row (`user-<sub>`, `fail`) when they fail,
  recording the failure's class and never its text. A handler that crashes
  writes one failure row naming the action, on the control API and on MCP,
  "crashed: the handler failed - the error is in the error log"; the error
  itself stays in the error log. t/integration/133.

- SM997 (42b545e0) **a nav address cannot run script.** The nav parser stored a
  `javascript:` address as written, and every layout puts a nav address in an
  href. A nav entry's address must now be a path, an `http`/`https` address,
  `mailto:` or `tel:` - the rule `| url_safe` applies (SM970). The Navigation
  editor, `nav-save`, `set_nav`, a WebDAV PUT of a nav file (422) and a nav
  file saved through the file editor refuse anything else and write nothing.
  An entry already in a nav file renders as `#` and is logged;
  `lazysite validate nav.conf` and `lazysite check` name it.
  t/integration/132, t/unit/processor/100, lint 223.

- SM996 (7b55ca34) **rows restored from a site package keep their authors.**
  SM989 recorded every restored row as the account that applied the package,
  which replaced who really wrote it. A package now carries each row's
  `created_by` and `updated_by` (tables with `timestamps: true`), and the
  restore keeps them; the applier is named in the log line "table rows
  restored" and the action's audit row, and `data_restored` gains
  `authors_kept`. A package built before this carries none, and its rows are
  the applier's. t/unit/data/70, lint 137.
- SM993 (26958a46) **security: `auth_groups` means signed in, and `auth: manager`
  stays in the manager** (ruled 2026-10-12, "Fix both as recommended"). A page
  naming `auth_groups` with `auth: none` (the default) or `optional` was served
  to anonymous visitors - with `none`, to everyone - and listed; a content page
  saying `auth: manager` was served to anyone. **Behaviour change:** a page
  naming `auth_groups` sends an anonymous visitor to sign in and refuses a
  non-member, whatever its `auth:` says, and leaves anonymous scans and the
  registries; a paid page keeps the list as its payment bypass. `auth: manager`
  outside the manager path answers 403 to everyone, logged, in no listing, and
  `lazysite validate` reports it. Three shipped docs pages (`ai-connector-setup`,
  `ai-connector-tools`, `onboarding-brief-template`) said `auth: manager` and
  now say `auth: required`. t/integration/130.

- SM992 (c37798ad) **security: an edit lock needs write access** (ruled
  2026-10-12, "Lock needs write access"). `lock` asked no file rule, so any
  manager account could lock any file and block its writers until the lock
  expired, and `unlock` released anybody's lock. **Behaviour change:** the
  manager's `lock`, `renew-lock` and `unlock` refuse (403) a caller the path's
  rule does not let write, and WebDAV's `UNLOCK` is authorised as a write, as
  `LOCK` already was. The operator's release of another's lock is unchanged;
  a file no rule governs locks as before. The editor says why it cannot edit
  such a file. t/integration/129.

- SM991 (e62da548) **security: the operator is the operator group, and
  `manage_users` is user and group management** (ruled 2026-10-12, "Operators
  bypass, others bound"). A session holding only `manage_users` passed every
  capability gate on the manager (`config-set` answered 200). **Behaviour
  change:** the operator is a member of the group carrying the `manager` flag -
  the group `setup-sysop` makes (`sysops`, "Site operator"), which an existing
  site already has, so nothing migrates; its members pass every capability gate
  and every file rule on the manager, as `local` and an unsecured site do; a
  token never does. `manage_users` (the `user-managers` role included) passes no
  other gate, is bound by file and table rules, and can no longer change the
  operator's account (password, setup link, credential, settings, removal) or
  the operator group (its members, flag or nesting); it still manages every
  other account. `group-reach` names the operator group and says what
  `manage_users` grants. t/integration/128.

- SM991 (eec4b595) **security: only the operator revokes the operator's sessions
  and access keys** (ruled 2026-10-12, "Yes, protect operator sessions too").
  **Behaviour change:** the Sessions page's `session-revoke`, `user-revoke` and
  `key-revoke` refuse a caller who is not the operator when the account they
  reach is the operator, by the same rule as the users tool's verbs; a
  `manage_users` holder still revokes every other account's. A session id the
  session registry does not hold is the operator's alone to revoke.
  t/integration/131.
- SM1050 (e356926b) **a partner lists and creates groups within its grant.**
  `groups-list` and `group-set` on the control API, `list_groups` and
  `set_group` on MCP, behind `manage_users`. A domain-confined caller sees the
  groups its domains name, the groups it is in and the groups it created, and
  changes only the ones it created. A capability is granted only if the caller
  holds it; the operator flag is never set this way; each change is audited
  with what it granted and revoked. Membership is still managed in the manager.
  t/integration/209.

- SM1049 (f748ff2a) **a write-only rule that moves nothing says ok.** A
  write-only rule on a folder holding a gated subfolder - a domain root, as
  reported - answered `ok:false`, kind `partial`, "content could not be moved",
  although the rule was in force and nothing needed moving. A move back into
  the document root is now due only when the private store holds something no
  other rule keeps there; otherwise the reply is `ok:true` with
  `content_moved: 0`. A due move that fails is still `partial`, and says which
  way it could not move. t/integration/208.

- SM1048 (ef8c6834) **a domain without sign-in pages uses the engine's.** On a
  domain whose content root had no copy, `/forgot` - the login page's own
  link - and `/logout`, where signing out lands, answered 404. Both join
  SM201's system pages: the domain's copy, then the primary's, then a protected
  default under `lazysite/templates/system/`. `/login` and `/claim` already fell
  back on main; `lazysite check` now probes all four. t/integration/207.

- SM1047 (2975f26f) **a scope check reads the path the handler writes.**
  `acl-set` checked a confined caller's scope against the query's path, '/'
  when absent, and refused a path sent in the body, so a partner following the
  reference (`path` in query or body) was told "Path '/' is outside your
  assigned scope". The path is now resolved once, before the check, from either
  place; two different paths are refused and nothing is written. The sweep of
  every action found two cross-domain reads of the same shape, both fixed: a
  confined caller read another domain's form submissions with
  `form=<its own form>&file=<the other's store>`, and read and appended to
  another domain's page brief with `type=table&table=<its own table>`.
  t/integration/205, 206.
- SM1031 (d87b98f1) **a text save writes UTF-8, and a saved-page preview is no
  visit under the owning domain.** Ruled 2026-10-12 ("Fix all three"; found
  working SM1030). The control API's save and MCP `write_file`,
  `replace_text`, `copy_file`, `create_page` and `create_form` refuse content
  that would not be written as valid UTF-8 - a lone surrogate or a code point
  past U+10FFFF in the JSON body, an overlong form in a page read from disk -
  as `page-encoding-refused`, naming the offset and writing nothing, as every
  raw door already did (Q15h). A saved-page `preview_page` no longer records an
  access-log visit, and renders under the Host of the domain that owns the
  path (naming it as `rendered_as_host`), as `preview_public_page` and a draft
  preview do; it inherited the MCP request's Host, so a domain's page was shown
  in another site's layout and theme. t/unit/mcp/50.

- SM1030 (028622af) **MCP `preview_page` renders a draft and writes nothing.**
  `preview_page { path, content }` renders `content` at `path` in place of the
  saved page - as a public visitor, under the Host of the domain that owns the
  path, so with that site's layout, theme, navigation and access rules - and
  answers with `draft: true`. Nothing is written: no file, no cache, no content
  history, no access-log row, no form rules, no compile cache. A draft is
  refused for anything a save of it at that path would be refused for (not
  UTF-8, a form the caller does not reach, a template that does not parse, raw
  HTML, the path's write rules) and over 512 KiB; `path` is required. Without
  `content` the tool is unchanged. Ruled 2026-10-12; recorded in SM887.

- SM995 (b5ab1ce4) **a scan directive pages its own list: `limit=` and
  `offset=`.** `scan:/post/*.md sort=date desc offset=10 limit=10` lists the
  second ten of the sorted, filtered result. `scan_limit` in lazysite.conf
  stays the site's ceiling: `limit=` cannot exceed it, and `offset=` counts
  into the pages the scan read. `NAME_total` is unchanged. A value that is not
  a whole number is ignored and logged. t/unit/processor/99.

- SM990 (ed416939) **a page a scan cannot open is left out, not fatal.** A page
  the serving user may not read (a file copied in by root with mode 0600) made
  every page whose `scan:` reached it, and the sitemap, answer 500. The scan
  and the registries now leave it out and log it by its path with the reason,
  as they do for a page that is not UTF-8. t/unit/processor/98.

- SM989 (1615ac72) **rows restored from a site package record who restored
  them.** Applying a package that carried table data inserted every row with
  no actor, so `created_by` read as written anonymously. They now record the
  account that applied the package, as an import does. Found by lint 137,
  which now holds every row-writing call in the modules, not only the
  top-level scripts, to naming its actor.

- install-plan (4d187eb5) **a dry run prints no uninitialised-value warnings.**
  `lazysite provision` and `install.pl --dry-run` printed "Use of uninitialized
  value" three times (install.pl ~1223): the plan prints each runtime path's
  `purpose`, and three entries in classification.json carry `why` instead. The
  plan prints `why` when there is no `purpose`. t/tools/109.

- SM988 (035822f0) **a scan says how many pages it matched, and its cap is the
  site's.** `scan:` read at most 200 pages, the first by file name, and nothing
  said so: a 1,745-post listing rendered 200 and looked complete. `scan_limit:`
  in lazysite.conf now sets the cap (default 200, still the same pages on every
  render), `NAME_total` beside the list counts the pages matched that the
  reader may see, and a capped scan logs a warning. t/unit/processor/97.

- SM987 (c9874e31) **the development server receives a form post.** Native
  forms post to `/cgi-bin/form-handler.pl`, and `tools/lazysite-server.pl`
  routed only the `lazysite-*` scripts, so every form on a staged site answered
  404. The server now runs the form handler for it, as an installed site does.
  t/unit/tools/80.

- SM986 (800c0874) **a setup link refused over plain HTTP says so.** The claim
  page answered a password set over http from another machine with "That
  setup link is invalid or has expired", the answer for a bad or used link, so
  the person asked for another link, which failed the same way. The refusal
  now has its own answer: a password can only be set over HTTPS, and the link
  has not been used. It says nothing about whether the account or link exists.
  t/unit/auth/26.

- SM985 (4f8ade64) **a code block can show `:::` syntax.** The `:::` passes
  (components, boxes, include, forms, oembed) ran before code blocks were
  converted, so a ``` block showing how a component is written rendered the
  component inside the code block. Fenced code is now held out of those
  passes; a code block inside a box is still a code block.
  t/unit/processor/96.

- SM984 (140baad1) **`&&`, `||` and `<` work in a template tag in a page body.**
  The body is converted from Markdown before the template pass, and the
  converter escaped the tags as prose: `[% IF a && b %]` reached the template
  as `[% IF a &amp;&amp; b %]`, failed to parse, and the page showed its own
  source. Each tag now passes the converter as written; prose is escaped as
  before, and a tag shown in code is still shown, not run.
  t/unit/processor/95.

- SM983 (c1f332f1) **approving an account request reads one field, not every
  account.** The approval's "is this name or address taken" check asked for
  every account's full settings, each derived afresh: 43 s for 695 accounts,
  so the browser gave up first. It now asks `users-detail` for
  `fields: ["email"]`, answered from the settings store in one read (0.27 s for
  700 generated accounts, from 26.7 s), and refuses on an unreadable store.
  t/unit/users/50, t/unit/manager/240.
- mcp-domain-attribution (2bcc4a7a) **a domain change made over MCP names the
  account that made it** (ruled 2026-10-12: "Close Q16 + MCP attribution"). An
  MCP `domain_set` - and a theme or layout activated for a domain, which writes
  through it - logged `[domain-set] domain key set ... user=` with nobody named,
  and its lazysite.conf change was committed to content history as `unknown`. It now logs `user=<account>` and is committed with that account
  as the author, as the manager API and the domains CLI already did. A log
  change taken on purpose; nothing else an MCP account can do changes, and the
  handlers that refuse when no manager request is asking still refuse in the
  MCP process. t/unit/manager/270.

- upload-budget (3cf4d320) **security: a forged upload no longer spends the
  account's hourly upload budget** (SM944 S34 finding F-1, built for review
  2026-10-11). The file-upload rate check reserves a slot as it checks, and it
  ran before the CSRF gate, so a cross-site POST from a signed-in manager's
  browser was refused 403 and still spent one: 60 such POSTs locked the account
  out of uploads for the rest of the hour. The check now runs after every gate,
  so a refused request spends nothing. The limit for genuine uploads is
  unchanged: the 61st in an hour is refused 429 with the same message. The size
  check still refuses an oversize upload before the body is read; an upload over
  the hourly budget is now read (at most that size) before it is refused.
  t/unit/manager/228; test 226 now finds no write from a forged upload.

- csrf-audit (c16151ea) **a write refused for its CSRF token is recorded in the
  audit trail** (ruled 2026-10-11: "Audit refusals"). A POST from a signed-in
  manager session without a valid CSRF token - what a cross-site page sends - was
  refused and left no audit line, and at the default log level no log line
  either, so an operator could not see it had been tried. Each refusal now writes
  one audit row, as the other gates' refusals do: the account, the action, the
  path, `fail`, `ui` and `denied: csrf`. The token is never recorded, nor any
  part of it. The answer is unchanged (403, "Invalid or missing CSRF token").
  t/unit/manager/227.

- SM944 (30f30cb3) **internal: the CSRF gate is Manager::Csrf's** (S34 of the
  plan in the filing, ruled 2026-10-11). `csrf_refusal($method)` returns the
  refusal and the manager API ends the request on it, at the gate's old place;
  the module never exits. No answer changes. Tests 43, 205 and 226.

- SM944 (6454e568) **security hardening: the CSRF gate refuses when no account
  is asking** (S34 of the plan in the filing, ruled 2026-10-11). The gate
  exempts a token client, and the request context's reset leaves one with
  nobody asking, so the gate run outside a request passed a POST for nobody.
  It now refuses an empty account first. Inside a request the auth check has
  already refused one on both channels, so no answer changes.

- SM944 (f12eaec3) **internal: every mutating action is proven refused, and not
  landed, without a CSRF token** (S34 of the plan in the filing, ruled
  2026-10-11). t/unit/manager/226 POSTs every action the declaration marks
  mutating, and `users`, from a signed-in session with no token: each must be
  refused 403 and change no file of the site and write no audit row, while the
  same request with a token does what it was refused. Test 43 sampled 19, and
  a gate moved after the dispatch let a forged write land behind its 403.
- SM982 (140d5870) **security: a table's own rule binds a `manage_data` holder,
  and a published table can hold rows back** (ruled 2026-10-11, "Table ACLs bind
  it + row filter"). A member holding `manage_data` wrote rows in tables whose
  write rule did not list them and read, through the control API, a table whose
  read rule excluded them: every row action treated a `manage_data` holder as
  the operator, and nothing read a table's write list at all. **Behaviour
  change:** a table's read rule now decides who reads its rows (data-rows,
  downloads, safety-export reads) and its write rule who changes them (row save
  and delete, import, restore, rebuild, drop) for a `manage_data` or `write_data`
  holder on the manager, the API, MCP and the data endpoint; the operator
  (`local`, a `manage_users` session) is unaffected. New descriptor key
  `where: field = value` or `where: field != value`: the rows a published table
  shows through page bindings and the data endpoint, counts included; the
  manager, API and MCP still see every row. Docs: data-tables. t/integration/127.

- SM981 (a6106bec) **security: a file that arrives in a held-back folder lands in
  the private store, however it arrives** (ruled 2026-10-11, "Land where save
  would"). A post carrying a rule of its own (an owner-only rule, which every copy
  gets) moved into a draft or read-gated folder was moved back OUT of the store
  into the document root, because the move judged placement by the file's own
  rule; in a draft folder with no read list it was then served to anonymous
  visitors, the owner-only rule also hiding the folder's draft flag; and the
  stray folder made every later save into it public too. Placement is now decided
  by every rule that governs a path - the manager's move, copy, upload, acl-set
  and acl-remove, MCP `move_file`/`copy_file`/`upload_file`, WebDAV
  `MOVE`/`COPY`/`PUT` - and the draft check asks only rules carrying `draft`.
  **Behaviour change:** `acl reapply --apply` repairs a folder found in both trees
  instead of refusing: the store's copy of a file both hold is kept and the public
  one is moved to `lazysite/displaced/<time>/`, named in the output, never deleted.
  t/integration/126.

- SM980 (904aca3f) **security: an inline `auth_groups: [a, b]` restricts the page,
  and an access key the engine cannot read refuses it** (ruled 2026-10-11, "Parse
  it + fail closed"). The gate read `auth_groups` only as a block list, so the flow
  list - ordinary YAML - was not read at all and the page was served, data rows
  included, to every signed-in user; `auth: "required"` and `payment: "required"`
  (quoted or capitalised) were not read either and served the page to anyone, or
  free. `auth`, `auth_groups` and `payment` now have one reading (the gate, the
  render parse, the scan and registry gates) that takes a flow or block list, one
  level of quotes, any case and a trailing comment. **Behaviour change:** a value
  that still cannot be read - a single bare name (`auth_groups: admins`), an empty
  list, an unclosed `[`, an `auth:` other than required/optional/none, a
  `payment:` other than required/none - answers 403 to everyone, signed in or not,
  is in no listing, and logs a line naming the key; `lazysite validate` reports it.
  Found and reported for a ruling: `auth_groups` binds only a signed-in request
  unless `auth: required` (an anonymous visitor gets what a non-member is
  refused), and `auth: manager` enforces nothing outside the manager path.
  t/integration/125, t/lint/220.

- SM979 (30861240) **security: manage_users no longer passes a file's rule, and
  approving an account request is a grant of its own** (ruled 2026-10-11, "New
  approve capability"). A group holding only `manage_users` - made to approve
  account requests - saved a page at the site root and overwrote another
  author's post past rules naming neither (200 both), read a members-only file,
  and rewrote another owner's rule: the per-file bypass was the operator test,
  which is true for any `manage_users` holder. **Behaviour change:** a file's
  rule now binds a `manage_users` holder, a sysop group included, like anyone -
  read, write, move, delete, and changing or removing somebody else's rule; a
  sysop reaches a file by being named in its rule (the starter's rules name
  `@sysops`) or by the CLI as `local`, which alone may name a rule's owner. A
  move or copy now asks the TARGET's write rule, and `mkdir` and the multipart
  upload ask the path's rule (all three asked none, or only the source's). New
  capability `approve_accounts` (off by default, manager UI only): approve an
  account request and read the submissions of the forms that declare
  `account_email:`, and no other form's; `manage_users` still approves.
  `lazysite-users.pl group-reach` now says that `manage_users` passes every
  capability gate on the manager, and which file rules name each group.
  Reported, not changed: `manage_users` passing the manager's capability gates
  (e.g. `config-set`), and `lock` asking no file rule. t/integration/124.

- lazysite-check (41967751) **a check that cannot read part of the site says
  so.** Run as a user that cannot read a directory - the private store, on the
  0.15.4 rollout - three of `lazysite check`'s walks printed Perl's raw
  "Can't opendir(...): Permission denied" and reported as if they had looked
  everywhere. Every walk in the tool now reports each check's unread
  directories as one warning: which directories, which check could not cover
  them, and to run the check as root or as the site's own user.
  t/tools/108.

- rollout (6dc09ada) **a site that upgraded and is not serviceable is reported
  as one, not as a channel skip.** install.pl exits 4 for "installed, and the
  site is not serviceable"; the Hestia deploy script exits 4 for "skipped by
  the update channel" and passed install.pl's 4 straight through, so the fleet
  updater listed such a site as "SKIPPED (stable site, edge release not
  installed)", counted 0 failed, left it out of the check summary, exited 0,
  and the deploy watcher printed "deployed" (the 0.15.4 edge rollout). The
  deploy script now finishes a not-serviceable install - the permission pass
  and the repair still run - and exits 5 if the health check still fails after
  them (a failure left by its repair used to be an echo and exit 0); the
  updater gives 5 its own column, NOT SERVICEABLE, checks those sites, and
  exits 2, which the watcher reports as findings that need a human.
  t/tools/107.

- release-dist (cdbd9ada) **a release built from a git worktree leaves its packages
  in the main checkout's dist/** (ruled 2026-10-11: "queue the dist fix").
  `tools/release.sh build` copied the tarball, debs and skill zip into the
  dist/ of the tree it ran from, so a build run from a worktree left them where
  the deploy monitor, which watches the main checkout's dist/, never looked
  (0.15.3 and 0.15.4 were copied across by hand). They go to the main
  checkout, where the gate's receipts already are. t/tools/104.

- pdf-tests (607690f1) **internal: the PDF tests no longer fail on a loaded host.**
  t/unit/plugins/40 and 41 assert that a render succeeds, and under a host
  load of about 17-23 a render outlasted the plugin's 20 s ceiling and was
  killed. They widen the ceiling for themselves (the plugin's
  `$TIMEOUT_SECONDS` is now a package variable; production keeps 20 s), and
  40 asserts the ceiling itself with a converter that never finishes.

- bad-url-blocker (09ab29d7) **the "Block this address" field is there when no address is
  blocked** (ruled 2026-10-11: "Always show the field"). On the bad-URL
  blocker's card, Blocked addresses, the field to block an address by hand was
  drawn only when the list already held one, so a site with none had no way to
  block the first from the manager (found running TEST-PLAN-0154 R14). It is
  drawn either way; an empty list still says "No addresses are currently
  blocked." t/unit/manager/225.

- SM944 (76ebb1bd) **internal: theme-delete tells a token client by the request
  context** (S33 of the plan in the filing, a held branch approved on
  2026-10-11). It reads `$token_auth`, Manager::Common's request fact, in place
  of a flag set at the end of the token branch - the two proven equal in every
  request. No answer changes: a token client deletes only the themes it
  created (SM262), now pinned by t/unit/manager/224.

- SM944 (76df249f) **security hardening: the session and access-key actions
  refuse when no account is asking, and are Manager::Sessions' handler** (S33
  of the plan in the filing, a held branch approved on 2026-10-11). The
  dispatch branch for sessions-list, session-revoke, user-revoke, keys-list
  and key-revoke passes a token client through its cookie gate, and the
  request context's reset leaves one: moved as it was, it listed the access
  keys and revoked an account's sessions with nobody asking. It refuses an
  empty account first, then moves to `dispatch_sessions_keys` in
  Manager::Sessions; the users-tool runner it calls moves to Manager::Users.
  Inside a request nothing changes. Test 205.

## 0.15.4 - EDGE: a confined caller writes only what its own domains serve (2026-10-11)

- SM944 (92b283ca) **internal: acl-set's dispatch branch is Manager::Files'
  handler** (S33 of the plan in the filing, a held branch approved on
  2026-10-11). `dispatch_acl_set` holds the branch's refusals and the change,
  and hands back the rule before and after for the audit entry; it reads the
  request's path and account from Manager::Common's context, never Files' own
  log copy, and refuses when no account is asking. No answer in a request
  changes. Test 205.

- SM944 (060b39ef) **internal: start-page-set's and audit's dispatch branches
  are handlers in their area modules** (S33 of the plan in the filing, the
  first group after S33a). Each branch's statements move unchanged into
  `dispatch_start_page_set` in Manager::StartPage and `dispatch_audit` in
  Manager::AuditTrail, reading the request's body and parameters from
  Manager::Common's context; no answer changes. Lint 217 reads a declaration
  by the fact's own sigil. Test 205.

- SM944 (176a322d) **internal: the request's parameters and its body join the
  manager request context** (S33a of the plan in the filing, as the release
  manager ruled on 2026-10-11, "Yes, S33a then groups"). `%params` and the
  body memo behind `_json_body` move from the manager API's file scope into
  `Lazysite::Manager::Common`, emptied by its reset so a long-lived process
  cannot hand one request's parameters or body to the next; `_json_body` moves
  with them unchanged. Lint 217 holds them as context facts; lints 58 and 52
  read a dispatch branch with the handlers it calls, so a branch body can move
  into its area module. No answer changes. Test 205.

- SM944 (f0c91de8) **internal: four listing branches of the manager API's
  dispatch are handlers in their area modules** (S33 of the plan in the
  filing, which inventories the 78 branches holding logic). themes-list-all,
  form-list, briefs-list and backup-list - each a listing filtered by the
  caller's reach - move with their statements unchanged into
  `dispatch_<action>` handlers in Manager::Themes, Manager::Plugins,
  Manager::Briefs and Manager::SiteBackup; no answer changes. Lint 218 reads
  the caller checks with the subs a branch calls, and now holds
  themes-list-all's acts_on; the content-history write-path registry scans
  the handlers. Test 205.

- SM944 (a1d6ea61) **security hardening: the auth secret is rotated only for the
  account that is asking** (WORK-PLAN-0153 Q14, ruled 2026-10-11, "Yes, same as
  whoami", scope ruled "manage_config may rotate"). The earlier fix refused an
  empty account and trusted any other `action_rotate_auth_secret` was handed,
  so a caller outside a request that named an account still signed every
  session out. It now acts only when the account is non-empty and is the
  request's own signed-in account; anything else is refused before
  /dev/urandom is opened. Inside a request nothing changes: the dispatcher
  passes the signed-in account, and a manager its gate lets through
  (`manage_config`) rotates as before. t/unit/manager/220.

- SM944 (de41aac4) **internal: the users and identity actions are
  Manager::Users', and whoami answers only for the account asking** (S32 of the
  plan in the filing, as the release manager ruled on 2026-10-10, "Yes, all
  four"). `_operator` moves into `Lazysite::Manager::Common` beside the caps
  memo, the one sub that fills the operator memo. Before the move whoami
  answers only when its account is the request's own, and users, principals
  and display-names refuse when no account is asking; inside a request none of
  this changes an answer (the dispatcher passes the authenticated account and
  has refused an empty one first), while outside one whoami answered for
  account '' or any account it was handed and the other three listed every
  account or resolved names. They, rotate-auth-secret and the handlers'
  who-is-asking move to the new `Lazysite::Manager::Users` unchanged. Test 205,
  t/unit/manager/222, 223.

- SM944 (f3ebd7c4) **internal: the audit trail's views and switch are
  Manager::AuditTrail's, and the trail is read only for an account** (S31 of
  the plan in the filing, as the release manager ruled on 2026-10-10, "(c)
  request IP into Common"). The request address and its per-request cache move
  into `Lazysite::Manager::Common` as part of the request context, emptied by
  its reset, so a long-lived process cannot record one request's visitor
  against the next. Before the move `audit` and `recent-changes` refuse when no
  account is asking, which inside a request never happens (the dispatcher has
  refused an empty account first); outside one they answered with the whole
  trail and who last changed each target. They, the trail's state and cache,
  the two audit-target derivers and the N13-04 switch move to the new
  `Lazysite::Manager::AuditTrail` unchanged; the store catalogue lists it as
  the reader of the `logs` store, so t/lint/121 still checks the trail's
  reader. Test 205, t/unit/manager/221.

- SM944 (5bc2736e) **security: the auth secret is rotated only for an account**
  (ruled 2026-10-10, "SECURITY first", found by the probe ahead of S31 and
  S32). `action_rotate_auth_secret` - the "sign everyone out" lever - rotated
  the site's auth secret when it was handed no account, so anything that
  reached it outside a request (a module, a daemon, a test harness; the
  request context's reset leaves nobody) signed every session out with nobody
  asking. It now refuses an empty account before it opens /dev/urandom, and
  the secret and the CSRF secret stay as they are. Inside a request nothing
  changes: the dispatcher has refused an empty account before the action
  runs. Its argument is named `$user` rather than shadowing the request's
  `$auth_user`. t/unit/manager/220.

- SM944 (21d5fa85) **internal: page-pdf is Manager::PagePdf's, and a page is
  rendered to PDF only for an account** (S29 of the plan in the filing, as the
  release manager ruled on 2026-10-10, "(a) load in main"). Before the move
  page-pdf refuses when no account is asking, which inside a request never
  happens (the dispatcher has refused an empty account and required
  `manage_content` first); outside one it loaded the pandoc plugin and
  converted a public page. The action moves to the new
  `Lazysite::Manager::PagePdf` with one line changed: the plugin is loaded in
  package main, where its converter is looked for. Test 205,
  t/unit/manager/219.

- SM978 (d901e623) **security: a PDF is made only of pages the caller may read**
  (ruled 2026-10-10, "Scope it + composed parts", WORK-PLAN-0153 Q16b).
  `page-pdf` took no account of the caller's scope, so a manager confined to one
  domain got another domain's page as a PDF; a composed document's parts were
  asked the content ACL and not the scope; and the page itself was asked
  neither, so any manage_content account got a page whose read rule named
  somebody else. page-pdf is now path-scoped, as preview is: a page outside the
  scope is refused before the plugin loads, the page's read rule is asked as
  `read` asks it, and a part outside the scope refuses the whole document,
  naming the part (fail closed, as the plugin already refuses a part the ACL
  denies). Lint 218 counts a call to a sub that asks the domain rule, no longer
  any word that names one: page-pdf had passed it on the `main` in
  `main->can('convert')`. t/integration/122.

- WORK-PLAN-0153 Q16b (efdafc03) **a download ends where its Content-Length
  says, and is on the audit trail** (ruled 2026-10-10, "Keep audit, print
  nothing"). After streaming a PDF, page-pdf printed a second header block and
  `{"ok":true,"streamed":1}` past the PDF's Content-Length, so a client reading
  to the end got a PDF with JSON after it. The other streaming downloads -
  file-download, file-zip-download, backup-download, site-backup-download and
  data-export - exited before the audit block, so none was ever recorded, even
  POSTed or refused, though each is declared audited; a refused backup-download
  answered nothing at all. All six now share one streamed path: the body is the
  whole response, and the download is audited by the trail's rule (every POST;
  a GET when it is refused or fails). A file that cannot be opened is refused
  before any header goes out. t/integration/123.

- SM944 (3f4154fb) **internal: config-read, config-set and lang-status are
  Manager::Config's, and the site configuration is set only for an account**
  (S30 of the plan in the filing; the established fail-closed pattern the
  release manager ruled for S23-S28). The three actions, the conf reader the
  language verbs share and the language context whoami reports move to the new
  `Lazysite::Manager::Config`. Before the move config-set refuses when no
  account is asking, which inside a request never happens (the dispatcher has
  refused an empty account and required `manage_config` first); outside one it
  wrote the key into lazysite.conf. config-read, lang-status and the language
  context are unchanged. Test 205, t/unit/manager/218.

- WORK-PLAN-0153 Q16a (098bbc4d) **a handoff run in a git worktree says READY
  when it is**. `tools/handoff.sh` ended by checking the base branch out; in a
  linked worktree, with the base checked out in the main one, git refused, and a
  run whose every gate passed said NOT READY (n308, n332). In a linked worktree
  it now detaches at the base, which frees the branch as well; in the main
  checkout it returns to the base branch as before. A stack branch landed or
  deleted while the suite ran is named as such instead of a READY line with no
  SHA after git's "fatal: Needed a single revision", and is not offered.
  t/tools/106.

- SM944 (ba41fcd3) **internal: domain-check and domains-list are
  Manager::Domains', and a domain check runs only for an account** (S27 of the
  plan in the filing, as the release manager ruled on 2026-10-10, "Read Common's
  value"). The two actions and the install's marker move to the existing
  `Lazysite::Manager::Domains`. Before the move domain-check refuses when no
  account is asking, which inside a request never happens (the dispatcher has
  refused an empty account and asked the domain rule first); outside one it ran
  its outbound DNS/TLS probe of a configured host. The account it reads is
  Manager::Common's, which the request context's reset empties - never Domains'
  own log copy of the acting user, which nothing resets. domains-list is
  unchanged. Test 205, t/unit/manager/217.

- SM944 (1eae8342) **internal: the site backup and export verbs are
  Manager::SiteBackup's, and a package is uploaded only for an account** (S28 of
  the plan in the filing; the established fail-closed pattern the release
  manager ruled for S23-S26). The seven site-package verbs and the grant checks
  they share move to the new `Lazysite::Manager::SiteBackup`, and the no-scope
  token rule they and the domain verbs ask to `Lazysite::Manager::Common`.
  Before the move site-backup-upload refuses when no account is asking, which
  inside a request never happens (the dispatcher has refused an empty account
  and required `manage_domains` first); outside one it stored a package. The
  other verbs already refused there. Test 205, t/unit/manager/216.

- SM944 (e53aef1f) **internal: channel-services, version and analyse_visitors are
  Manager::Services', and the visitor analysis runs only for an account** (S26 of
  the plan in the filing, as the release manager ruled on 2026-10-10). The three
  actions, the transports' state whoami reads and the stats tool's path move to
  the new `Lazysite::Manager::Services`. Before the move analyse_visitors refuses
  when no account is asking, which inside a request never happens (the
  dispatcher has refused an empty account and required `analytics` first);
  outside one it ran the stats plugin and returned its export. The site facts -
  version, the transports' state, channel-services - are unchanged. Test 205,
  t/unit/manager/215.

- SM944 (5b5a3857) **internal: describe-capabilities and actions-list are
  Manager::Describe's, and answer only for an account** (S25 of the plan in the
  filing, as the release manager ruled on 2026-10-10). The two introspection
  actions, `site_capabilities`, `_json_bool` and `_action_effects` move to the
  new `Lazysite::Manager::Describe`. Before the move both actions refuse when no
  account is asking, which inside a request never happens (the dispatcher has
  refused an empty account first); outside one - a handler loaded where no
  request was set up - they answered for account '' with the capability map,
  the site's documentation index and the actions a grant of nothing may call.
  Test 205, t/unit/manager/214.

- SM976 (8fdb20dd) **A restore and the nav read refuse bytes that are not UTF-8**
  (ruled 2026-10-10, "Fix both", Q15k). MCP `restore_version` and the control
  API's `git-restore` wrote a recorded version that is not valid UTF-8 back as
  it was; they now refuse it with the encoding error (kind
  `page-encoding-refused`, the first invalid byte's offset, how to fix it) and
  leave the file as it is. MCP `read_nav` answered "Tool error" and the control
  API's `nav-read` no body on a `nav.conf` that is not UTF-8; both now answer the
  encoding error naming the file. t/integration/121.

- SM976 (4c15f8cc) **MCP answers a page that is not UTF-8, and says when a page
  walk stops at 1,000 pages** (ruled 2026-10-10, "Fix both"). A page whose
  bytes are not valid UTF-8 (put there by git, SSH or a restore) left MCP
  `read_page`, `read_file`, `view_version`, `read_brief` and `preview_page`
  with no JSON-RPC body, and `validate_page` and `create_form` with a bare
  "Tool error". Each, and `preview_public_page`, now answers as for a page it
  cannot read: kind `page-encoding-refused`, the first invalid byte's offset
  and how to fix it. `list_pages`, `audit_site` and `rename_page` (with
  `update_links`) walk at most 1,000 pages and now answer `truncated`, with
  `page_cap` when they stopped there; before, a site of more pages was
  counted, audited and link-rewritten as if it had 1,000. Their descriptions
  say so. t/unit/mcp/31, t/unit/mcp/32.

- SM944 (b224f9fb) **internal: the preview verbs are Manager::Preview's, and act
  only for an account** (S23b and S24 of the plan in the filing, as the release
  manager ruled on 2026-10-09). The manager API's JSON printer for the
  responses that need their own headers moves to `Lazysite::Manager::Common`,
  and preview-grant, preview-clear and preview move to the new
  `Lazysite::Manager::Preview`. Before the move preview-grant and preview
  refuse when no account is asking, which inside a request never happens (the
  dispatcher has authenticated a manager); outside one - a handler loaded
  where no request was set up - the grant minted a signed preview cookie for
  account '' and created a missing auth secret, and preview shelled the
  processor. Test 205, t/unit/manager/213.

- SM976 (e6ecbaa5) **a page that is not UTF-8 no longer stops search, a scan or
  the validator** (ruled 2026-10-09, "Same rule"). MCP `search_files` answered
  with no body when a file in its base was not valid UTF-8; it now leaves the
  file out, logs it, and answers for the rest (`delete_page`'s
  `still_referenced_in` with it). A page whose front matter is UTF-8 and whose
  body is not made every page listing a `scan:` source over it answer 500; it
  is now left out and logged, as for its front matter. `lazysite-validate` over
  many pages died on one such file and printed nothing; the file is now
  reported as one it could not read, with the first invalid byte, and every
  other file is checked. Every other page walk was probed and answers
  (SM976). t/unit/mcp/29, t/unit/processor/93, t/tools/82.

- SM976 (995a921b) **security: a page written as raw bytes must be valid UTF-8,
  and a page that cannot be read binds no form** (ruled 2026-10-09, "Refuse +
  walker skips"). The processor reads a page through a lax UTF-8 layer, so a
  page that is not UTF-8 renders nothing or reads front matter other than what
  the form-binding check saw. A grant scoped to one domain uploaded such a page
  and so bound, and reached, the primary's form. **Behaviour change:** a `.md`
  page arriving as raw bytes - MCP `upload_file`, the multipart upload, WebDAV
  PUT, a site package applied with `site-backup-apply` or `site_apply` - is
  refused unless it is valid UTF-8, for every caller (415, kind
  `page-encoding-refused`); the refusal names the first invalid byte and says
  to save the file as UTF-8. A page that is not UTF-8 and reaches the disk
  another way (git, SSH) no longer stops anything: the form rule, the
  processor's `scan:` sources and registries, and MCP `list_pages`,
  `audit_site` and `form_list` leave it out and log it. Before, one such page
  made every form verb fail for confined callers, and on a site with a `scan:`
  source every page answered 500. t/integration/120, t/unit/manager/212,
  t/unit/processor/93, t/unit/mcp/29.

- SM977 (a0b7d0bb) **MCP `copy_file` refuses an existing destination** (ruled
  2026-10-09, "Refuse existing target"). Its description says "to a new path"
  and the manager's copy refuses an existing target, but `copy_file` overwrote
  one. **Behaviour change:** a copy onto an existing file is refused (`exists`);
  `write_file` replaces a file. t/unit/mcp/30.

- SM944 (73a98907) **internal: the notices gate and the start-page actions are
  their modules'** (S23 of the plan in the filing, with the three changes the
  release manager ruled on 2026-10-09). The manager API's notices gate moves to
  `Lazysite::Manager::Notices` and its start-page actions to
  `Lazysite::Manager::StartPage`. Loaded outside a request they refuse (test
  205). Before the move the gate answers a token from its own `notifications`
  grant, which the dispatcher already required. The start page refuses an
  empty account, and the dispatcher calls the notice readers directly. One
  answer narrows: an account name that sanitises to nothing (`!!!`) no longer
  reads the start page of account '' for a caller holding `manage_users`.

- SM977 (efe3e366) **MCP `create_form` adds the form to the page it names, and
  replaces no page.** Called the way its schema describes (`/about`), it read
  `/about`, found nothing, and wrote a fresh scaffold over `/about.md`, so the
  page's text was lost. A page with text and no front matter was replaced
  whatever the spelling. It now reads the file it writes (`/about` and
  `/about.md` are both `/about.md`). It appends the block, and adds a front
  matter block when the page has none. A page it cannot read is refused, and
  an edit made after the read is not overwritten. t/integration/119.

- SM944 (699e2d1f) **internal: the users-tool client and the account caps memo
  are `Lazysite::Manager::Common`'s** (S22b, a row the release manager added
  before S23 on 2026-10-09). `users_api` and the subs behind it, and
  `_user_caps` with its memo, move unchanged so S23's handlers can call them.
  The memo joins the request context: the manager API empties it before each
  request's auth check, and outside a request it holds nothing (lint 217,
  test 205). No behaviour change.
- SM976 (3d13ff91) **MCP: each tool declares which arguments are content paths**
  (ruled 2026-10-09, "Fix: per-tool path args"). One list of path argument names
  for every tool (SM661) made `replace_text`'s `old` and `new` paths, so a grant
  confined to some content was refused ordinary text as "outside your assigned
  scope". **Behaviour change:** a scoped grant can use `replace_text` inside its
  scope; `old` and `new` are text, and are no longer asked the scope or the
  carve-out (`nav.conf`, the submission stores) - its `path` still is. Every
  other tool checks exactly what it checked: `rename_page`'s `old`/`new`,
  `create_page`'s `slug`, `copy_file`/`move_file`'s `to`/`from` and every
  `path`. Each tool declares `path_args` in the tool table; lint 91 holds every
  argument of every tool to a declaration. t/integration/118.

- SM976 (515701d3) **security: a page binds the form the processor renders, on
  every rule** (ruled 2026-10-09, "One reading, processor's"). The form rule
  found a page's form with its own reading - the first plain `form: NAME` line
  in the first 16 KB - so another domain's page with the name on the next line
  rendered and received a form the rule did not count, and a caller scoped to a
  domain also binding it reached the other site's submissions. **Behaviour
  change:** the form rule (`form_bindings`, `form-list`/`form_list`, every form
  verb's reach), the content-write rule, MCP `create_form`, `validate_page` and
  `audit_site` read the form as the processor renders it: the last `form:` key,
  a value on the next line, TT markers and other characters removed, the whole
  front matter. A confined caller no longer reaches a form another domain's page
  binds in such a shape; a form its own pages bind in such a shape is now its
  own; a `form:` line the processor does not render (the first of two, one
  followed by `form: ''`, one an earlier empty key swallows) binds nothing. The
  manager's reading is a marked copy of the processor's, pinned by lint 219.
  t/unit/manager/211.

- SM976 (72cd4242) **security: a confined caller binds no form it does not
  reach** (ruled 2026-10-09, "Refuse new binding"). A form is reached through
  the pages that bind it, so a cookie manager scoped to one domain could save a
  page of its own naming the primary's form and then read that form's
  submissions. **Behaviour change:** a confined caller (a scoped token, MCP
  grant, WebDAV account or cookie manager) is refused, before anything is
  written, a page that newly names in its front matter (`form: NAME`) a form it
  does not reach - judged on the form's bindings as they stand - on every
  content write: the file editor's save, move and copy, `migrate-to-local`,
  `git-restore`, the multipart upload, `site-backup-apply`; MCP `write_file`,
  `create_page`, `replace_text`, `upload_file`, `move_file`, `copy_file`,
  `rename_page`, `restore_version`, `create_form` and `site_apply`; WebDAV PUT,
  COPY and MOVE. A move, a rename or a copy of a binding page is a new binding
  where it lands. The form is read as the processor renders it and as the form
  rule finds it, so a second `form:` line or a value on the next line is caught.
  A form that exists nowhere (no registration, no submissions, no page) is a
  new form and the page's own, so `create_form` with a new name still works.
  Editing a page that already binds the form, and removing a binding, are
  unchanged; so are the operator, an unbound cookie manager and an unbound
  token, grant or account (they reach every form). 403, kind
  `form-bind-refused`. Lint 218 section 8, lint 114. t/integration/117,
  t/unit/manager/210.

- SM976 (9afb657b) **security: the three Q15c findings, ruled** (2026-10-09). F1
  "Yes, any served artifact": a theme or layout a site serves is that site's.
  **Behaviour change:** a confined caller (a scoped token, MCP grant, WebDAV
  account or cookie manager, and an unbound token, grant or account for every
  domain with a content root of its own) writes into a theme or layout only if
  no site serves it or only its own domains do - on the file editor, the
  control API, MCP `write_file` and its siblings, WebDAV and the multipart
  upload; it copies another site's theme, edits the copy and binds the copy to
  its own domain. The multipart upload (`file-upload`) also asks SM749's rule
  now: it replaced files in the instance's active theme for everyone. F2
  "Confine both": **Behaviour change:** a confined caller reaches a form only
  when every page binding it (`form: NAME`) lies inside its scope - a form no
  page binds is the primary's - on every form verb of the control API and MCP
  and on the form's conf over WebDAV; `form-list`/`form_list` show only those;
  MCP `create_form` naming an existing form asks the same. It reaches a brief
  only of a page inside its scope or of a row of a table it reaches;
  `briefs-list`/`list_briefs` show only those. An unbound token or grant keeps
  every page's form and brief (its scope is the whole content, R3). F3 "Record
  domain": a safety export written by a drop or a rebuild records its table's
  domain and is confined as the table was. **Behaviour change:** an export
  written before this records none and is the primary's: a scoped caller no
  longer reaches it, even of its own table, and an unbound token or grant now
  does, of any table (restoring still needs the live table's reach). F4
  "Activate on its domain": `theme-activate` and `layout-activate` take `host`
  on the control API, as their MCP twins do, binding that domain only and
  asking the domain rule, with no `manage_domains`; `themes-list-all` names a
  confined caller's domains as `acts_on`, and the Appearance page of a scoped
  manager activates there (asking which when it has several) and offers no
  Deactivate. **Behaviour change:** a `host` sent to either action was ignored
  and the instance changed; it now addresses the domain, and a token naming no
  scope is refused it (SM975). The operator and an unbound cookie manager are
  unchanged throughout. Lint 218 sections 6 and 7. t/integration/116,
  t/unit/manager/208, 209, t/unit/data/67, 68.

## 0.15.3 - EDGE: a confined caller reaches only its own domains (2026-10-09)

- SM976 (5a8bb72c) **security: the four rulings on domain confinement**
  (2026-10-09). R1 "Confined = no instance-wide": a token, MCP grant or cookie
  manager whose scope binds some domains no longer changes what the whole
  instance reads. **Behaviour change:** it is refused `config-set`,
  `theme-activate`, `layout-activate`, the layouts library and repo
  (`layout-install`, `layouts-install`, `layout-delete`, `layouts-repo-set`),
  the extensions (`plugin-enable`/`-disable`/`-save`/`-action`),
  `audit-trail-set`, `git-init`, the IP blocklist, `rotate-auth-secret`, the
  instance backups (`backup-create`/`-restore`/`-delete`, and it is shown and
  sent none), `artifact-backups-delete`, the connector, handler and schedule
  registries and `briefs-migrate`; over MCP `activate_theme`/`activate_layout`
  without a `host`, `install_layout`, `delete_layout`, the handler and schedule
  tools and `create_theme` with `activate`; and a confined cookie manager
  deletes only themes it created. It changes its own domains through the
  `host` forms. The operator, a cookie manager bound to no domain, and a token
  or grant naming no scope (which reaches the primary, R3) are unchanged.
  R2/R4: the data surface asks the shared domain rule. **Behaviour change:** a
  cookie manager bound to no domain now reaches every data table, as it does
  every other domain object; an unbound token or grant reaches the tables of a
  domain that serves the primary's content; a scoped caller no longer reaches
  the tables of a domain enclosing its own, nor any other domain's table
  access rule or safety exports (those verbs asked nothing). Lint 218 holds
  every mutating action to the instance-wide list. t/integration/114, 115,
  t/unit/data/67.

- bad-url-block (fb695d7a) **blocking an address by hand never ran.** SM704's
  `bad-url-block` called `block()`, which the manager API never imported, so
  every call died and answered nothing; the automatic blocker was unaffected.
  It blocks now. t/integration/114.

- SM943 ruling 2 (a50a57e6) **the structured nav read needs no capability**
  (ruled 2026-10-09: "As nav is public, do we need a cap to be able to read
  it? ... Surfaces should be consistent"). `nav-read` on the control API and
  `read_nav` over MCP need only the surface's base access, and read only the
  caller's own domains (SM976). **Behaviour change:** a token or MCP grant
  without `manage_nav` or `manage_content` now reads the navigation of its own
  domains; `manage_content` no longer opens anything nav-specific. Writing
  (`nav-save`, `set_nav`) and the raw `nav.conf` (WebDAV GET) stay
  `manage_nav`. t/integration/113.

- SM976 (44526d39) **security: a confined caller reached other domains on every
  surface.** A token, MCP grant, WebDAV account or cookie manager confined to
  one domain could add a domain at any content root, alias or remove any
  domain, repoint its own domain at another's content, write another domain's
  access groups over MCP (without `manage_users`), build, download and delete
  another domain's site package (cookie), bind a data table to another domain,
  and read and replace any domain's navigation, including over WebDAV. Ruled
  2026-10-09, "One rule, fix all": every action addressed by a host or a
  content root asks one predicate, `caller_may_reach_domain`, on the control
  API, MCP and WebDAV (lint 218). **Behaviour change:** a confined caller is
  refused on any domain whose content is not inside its scope, on the primary
  if it is scoped, and on hosts the instance does not serve; domain listings
  show it its own domains only; an unbound token, MCP grant or WebDAV account
  reaches no domain's navigation, and writes the primary's only when no domain
  with its own content root inherits it. The operator, an unbound cookie
  manager and single-site instances are unchanged. t/integration/112.

- SM975 (8b8f2515) **security: a token with no scope wrote every domain.** A
  `manage_domains` token whose group no domain names could set, add, alias,
  remove and overwrite (site-backup-apply) any domain on the instance, and
  write remap rules for any host, including hosts the instance does not serve.
  Ruled 2026-10-09: no scope means no domain. **Behaviour change:** an existing
  unscoped token is now refused on `domain-set`, `domain-add`,
  `domain-alias-add`, `domain-remove`, `remap-save`, `site-backup-apply` and
  MCP `domain_set`, and `remap-list` shows it no rules. It gets those writes
  back once it is given a scope: name the token account's group in the
  domain's `allowed_groups` (Domains page). Scoped tokens and the operator's
  own session are unchanged, and content reach is unchanged.
  t/integration/111.

- SM944 (c57b9dc8) **internal: the URL remapper's two manager actions are a
  module** (S22 of the plan in the filing). remap-list and remap-save, with
  the scope check they share, move unchanged to `Lazysite::Manager::Remap`,
  which reads the request context from `Lazysite::Manager::Common`; loaded
  outside a request they refuse every host. No behaviour change.
- SM943 ruling 1 (9a6b574b) **a read is not audited on either door unless it is
  refused or fails** (ruled 2026-10-09: "Surfaces should be consistent. Drop all
  17."). MCP stops recording the seventeen reads whose control-API twins were
  never recorded (`read_form_submissions`, `read_data_rows`, `read_notices`,
  `describe_capabilities` and the rest); its skip set is the read-only tools
  with none named. A read that is refused or errors is now recorded on both:
  MCP wrote no row for a read its handler refused, and the control API wrote
  none for any refused read over GET, which is how a token client reads. Writes
  are unchanged. t/lint/23 holds the two trails to one declaration;
  t/unit/mcp/28 and t/unit/manager/206 drive both doors.

- SM944 (3b68b1ba) **internal: the manager API's request context is shared,
  and refuses until a request sets it** (S21 of the plan in the filing, as
  the release manager ruled on 2026-10-09). Who is asking, through which
  door, how far the request reaches, whether it is the operator and what it
  asked for are `Lazysite::Manager::Common`'s, imported by the manager API in
  place of its own variables, so a handler can move into a module unchanged.
  Until a request sets them they describe nobody with no capability, confined
  to no path: a handler loaded by the daemon, MCP, WebDAV or a test refuses
  rather than inheriting the operator's reach. Only the manager API sets them
  (lint 217). No behaviour change for a request.

- SM944 (6d5ab3aa) **internal: the auth gate is the processor's nineteenth
  part, the last of the processor's rows** (S20 of the plan in the filing).
  `check_auth`, `peek_auth` with the front-matter peek and its per-request
  memo, `_is_manager`, `_site_grants_manager`, `_serve_manager_forbidden`
  and `serve_403` move unchanged to `lazysite-processor/auth.pm`. The trust
  gate stays in the script's request entry, where lints 13 and 38 look for
  it. No check read the moved code's text from the script, so none changed;
  the checks that guard the gate were each seen to fail with a violation
  placed in the part. No behaviour change; the render times are unchanged.

- SM973 (b94809d5) **security: a pooled worker kept serving a file after it was
  protected.** The processor read `acls.json` once and, under the FastCGI
  pool, kept that answer until the worker restarted (500 requests by default).
  A file protected after that was still served to anonymous visitors, and a
  reader removed from a list kept access. The store is now read again for
  every request, as its declaration always said. Found while moving the ACL
  copies (SM944 S19); t/integration/110.

- SM944 (5aa23486) **internal: the ACL, group and domain copies are the
  processor's eighteenth part** (S19 of the plan in the filing).
  `_acl_allows_read` and the ACL family, the private-store copies,
  `_groups_grant_cap` (ADR 0001's marked copy), the group closure, the
  display-name copy and the domain-access copy move unchanged to
  `lazysite-processor/acl.pm`. Lint 31 and test processor/70 follow their
  copies into the part and still compare them with the shared
  implementations; lint 31 also requires the read-decision copy to be
  defined once in the whole processor. Lint 13 now looks for the trust gate
  in code rather than comments and accepts a `delete @ENV{...}` spanning
  lines: it had been passing the manager API on a comment. No behaviour
  change; the render times are unchanged.

- SM944 (59d3ad80) **internal: the page pipeline is the processor's
  seventeenth part** (S18 of the plan in the filing). `process_md`,
  `process_url`, `sanitise_uri`, `confine_content_root`, the static serve,
  the escapers, the source alternate and the freshness checks move unchanged
  to `lazysite-processor/pipeline.pm`. Two pieces stay in the script because
  moving them would change behaviour: `_lazy_lib` (it finds the module tree
  from its own file's location) and the declared-content-roots memo (its
  initialisers would run before the request rather than after). Lint 204
  finds a copy of the reserved-character list in any processor part; lint 13
  asks whether the processor reads the identity header of the script and its
  parts, and still looks for the gate in the script. No behaviour change;
  the render times are unchanged.

- SM944 (bfa54c26) **internal: layout, theme and injection are the processor's
  sixteenth part** (S17 of the plan in the filing). `render_template`, the
  layout and theme resolution, `generate_theme_css`, the injectors and the
  admin bar move unchanged to `lazysite-processor/layout.pm`, with the
  per-process memos of the engine version and install time (shown to keep
  the same answers). Lint 56 finds the processor's inline blocks in every
  part. No behaviour change; across S16-S17 the render times are unchanged.

- SM944 (3f169712) **internal: the template render is the processor's
  fifteenth part** (S16 of the plan in the filing). `render_content`, the
  TT-render-with-retry pair and `_cache_umask` move unchanged to
  `lazysite-processor/render.pm`. Seven source checks of the stash's
  construction (the escaped families, the manager caps, page_source, the
  `_raw` contract) read the part. No behaviour change: every sub deparses
  identically, and across S16-S17 the render times are unchanged.

- SM944 (0f4c3d2b) **internal: scan and registries are the processor's
  fourteenth part** (S15 of the plan in the filing). `resolve_scan`,
  `scan_pages`, the registry regenerator and its serving path move unchanged
  to `lazysite-processor/registries.pm`, the lock constants written as calls
  so the part compiles alone. Lints 39 and 45 now read every part: late script
  state read by a part's sub, and front-matter keys read only in a part. No
  behaviour change; across S13-S15 the render times are unchanged (the order
  of the trees in the bench decides which looks faster).

- SM944 (4e9f2bb5) **internal: sources and site vars are the processor's
  thirteenth part** (S14 of the plan in the filing). The tt-var sources
  (`json:`, `db:`, env interpolation), the dependency record, nav, the conf
  peeks and the scan's visibility tests move unchanged to
  `lazysite-processor/sources.pm`. The site-vars memo stays in the script:
  its initialisers would run earlier in a part, which is a change, not a move.
  No behaviour change.

- SM974 (8779e337) **a stats day is a UTC day, so a day's last hours east of
  UTC reach its durable file.** Every first-party day bucket is a UTC day, but
  the stats plugin judged "today" and "closed" on the local calendar. East of
  UTC it closed and finalised the current day at local midnight, and views
  after that never reached the day file: the last hour of every day under BST,
  the last fourteen under UTC+14. Today, closed, the window and retention are
  now UTC days. The server-log reader now reads each stamp's own offset, and
  the form handler records outcomes under the UTC day. **A server-log site on
  a host not set to UTC now gets UTC days instead of the log's local dates;**
  the day of the upgrade can be split across two buckets. Nineteen stats tests
  assumed the local calendar and are fixed (WORK-PLAN-0153 Q14g: three failed
  on main between midnight and 01:00 BST); t/unit/plugins/48.

- SM944 (acf2d082) **internal: the request address and host are the processor's
  twelfth part** (S13 of the plan in the filing). `_request_host`,
  `_request_address` and the trusted-proxy readers move unchanged to
  `lazysite-processor/request.pm`, the Socket constants written as calls so
  the part compiles alone. Lint 206's REMOTE_ADDR ledger now counts the script
  and all its parts. No behaviour change.

- WORK-PLAN-0153 Q14d (b297af18) **the release gate names a failed suite as a
  failed suite, not a coverage shortfall.** The gate of main on 2026-10-08 said
  "coverage below the declared floor" when the instrumented suite had failed
  and no floor was checked: it searched the whole coverage log for the marker,
  and the log's source listing quotes the tests that name it - the SM444
  misdiagnosis that block exists to prevent. Both markers are now matched as
  coverage.sh prints them (t/tools/58 covers the quoted case). The suite
  failure itself was t/tools/106 reading Devel::Cover's stderr notice as part
  of a branch name; its git helper now compares stdout only. Lint 38 reads the
  processor and its parts as one unit, ahead of the auth gate's own move.

- SM944 (193d7c42) **internal: output and headers are the processor's eleventh
  part** (S12 of the plan in the filing). `output_page`, the 403/404 paths, the
  security-header and CSP copy, the conf readers and the ai-partner document
  move unchanged to `lazysite-processor/output.pm`. Lints 55, 56 and 57 now
  sweep every status line, header and redirect in the script and all its
  parts. No behaviour change; across S10-S12 the cache-hit and miss render
  times are unchanged (0.980x and 0.992x, inside each tree's spread).

- SM944 (3f1962f8) **internal: forms are the processor's tenth part** (S11 of
  the plan in the filing). `convert_fenced_form`, `_render_form` (whole, 562
  lines), the SM934 rules sidecar, the form secret and `convert_fenced_divs`
  move unchanged to `lazysite-processor/forms.pm`; lint 156 reads the banner
  there, and lint 56 counts inline blocks in the script and every part. No
  behaviour change.

- SM944 (a4b2455a) **internal: include and Markdown are the processor's ninth
  part** (S10 of the plan in the filing). The `::: include` resolver,
  `convert_md`, the code-fence pass, the `markdown`/`json`/`url_safe` filters
  and the link passes move unchanged to `lazysite-processor/include.pm`; test
  71 reads the include path there, and lints 31 and 36 hold their
  never-`_acl_denied` rule over the script and every part. No behaviour change.

- SM972 (ed165133) **security: a custom payment header name was trusted from
  anyone.** With `payment_header_verified` set to a custom name and no
  `auth_proxy_trusted: true`, a visitor sending that header was served paid
  content - the trust gate stripped only the fixed `X-Payment-*` names (SM960
  fixed the same for auth headers, not payment). It now strips configured
  payment names too. **A site using custom payment header names must set
  `auth_proxy_trusted: true`.** Found while moving the payment gate (SM944 S7);
  t/integration/109.

- SM944 (bfc5e664) **internal: the front door is the processor's eighth part**
  (S9 of the plan in the filing). `_front_door`, `_front_route` (the copy of
  Lazysite::FrontDoor::route) and the relay move unchanged to
  `lazysite-processor/front-door.pm`; lint 42 and test 47 read them there. No
  behaviour change; across S6-S9 the cache-hit and miss render times are
  unchanged (0.993x and 0.978x, inside each tree's spread).

- SM944 (e8b5e07e) **internal: the access log and the unit registry are the
  processor's seventh part** (S8 of the plan in the filing). The SM140 access
  recorder and the SM222 `plugins:` read move unchanged to
  `lazysite-processor/access-log.pm`; lints 159 and 198 read them there, and
  lint 215 reads a sub inside a part's bare block as a sub. No behaviour change.

- SM944 (a7b5c8f9) **internal: the payment and preview gates are the
  processor's sixth part** (S7 of the plan in the filing). `peek_payment`,
  `check_payment`, `serve_402` and the SM071 preview-cookie check move
  unchanged to `lazysite-processor/gates.pm`; the two contexts they fill stay
  declared in the script. No behaviour change.

- SM944 (c3a36c98) **internal: the content-type cache is the processor's fifth
  part** (S6 of the plan in the filing). `ct_cache_path`, `read_ct`, `write_ct`
  and `write_html` move unchanged to `lazysite-processor/ct-cache.pm`. No
  behaviour change.

- WORK-PLAN-0153 Q14b (b4b9891c) **the release gate can run from a `git
  worktree`.** It refused one ("no git repo": it looked for a `.git` directory,
  which a worktree has as a file) - and a long gate is safest run from a
  worktree, because the main checkout switches branches during development and
  bash reads a script as it runs. `release.sh` now asks git, and it and
  `gate-main.sh` keep receipts, the coverage store and the lock in the main
  checkout's `tmp/release-gate/` wherever they run from, so build finds them.
  t/tools/101.

- SM944 (18310443) **internal: content components are the processor's fourth
  part** (S5 of the plan in the filing). `convert_fenced_components` and its
  helpers move unchanged to `lazysite-processor/components.pm`; lints 212 and
  213 read the parts. No behaviour change; across S2-S5 the cache-hit and miss
  render times are unchanged (1.010x and 0.998x, inside each tree's spread).

- SM944 (2a0213c3) **internal: the URL remapper is the processor's third part**
  (S4 of the plan in the filing). `_remap_parse` (the marked copy of
  Lazysite::Remap's parser), `_remap_redirect` and `_alias_lookup` move
  unchanged to `lazysite-processor/remap.pm`, the first part to read the
  script's shared state, through `our`. No behaviour change.

- SM944 (da1d5329) **internal: oEmbed is the processor's second part** (S3 of
  the plan in the filing). The oEmbed converter, with `uri_encode` and
  `strip_tt_directives`, moves unchanged to `lazysite-processor/oembed.pm`. The
  lints that check a property of the whole processor (21, 25, 43, 121) now read
  its parts too. No behaviour change.

- SM944 (89dd2944) **internal: the state the processor's parts read is declared
  `our`** (S2 of the plan in the filing). The 27 file-scope variables a planned
  part reads become package variables in place, initialised where they were;
  the other 15 stay `my`. t/lint/215 now fails a part that names one of the
  script's `my` variables, or reads script state from its own file-scope code.
  No behaviour change.

- WORK-PLAN-0153 Q14a (0e03edc4) **a code count in the bench baseline moves with
  the code that changes it.** The release gate refused main after the last
  landing: `work_users_tool_statements` read 3378 against 3359, the 19
  statements SM962 and SM963 added to the users tool on purpose. That counter
  is about the code, not the host, yet it could only be updated at a cut - so
  under SM971's gate-after-every-landing, every deliberate growth would fail
  every gate until then. `tools/bench.pl --work` now prints the counts read from
  the source alone, and t/lint/216 fails a branch whose code changes one
  without updating the baseline in the same commit. The baseline moves to
  3378. Timings stay host-relative and re-captured at a cut.

- SM944 (07143256) **internal: the processor's first part** (S1 of the plan in
  the filing). The front-matter parser moves, unchanged, from
  `lazysite-processor.pl` to `lazysite-processor/front-matter.pm`, which the
  script requires by absolute path from beside itself, never through `@INC`, so
  the render path stays free of the `lib/` tree (ADR 0001). The manifest installs
  parts to `{CGIBIN}/lazysite-processor/` and the deb payload carries them; the
  lints that sweep the shipped Perl read them; t/lint/215 keeps each one package
  main, loading nothing, loaded by name and defining no sub twice. No behaviour
  change; cache-hit and miss render times unchanged.

- SM971 (35e02539) **a release is one commit on main, and its gate has already
  run** (release manager, 2026-10-08). `tools/release-material.pl` writes the
  CHANGELOG section, every PENDING ref's landed SHA (the commit that added that
  line, or a refusal naming the entry), the FEATURES entry, `VERSION` and
  `NEXT_VERSION`, the briefing, the index and, at a new minor, the archive move.
  `release.sh gate` runs it in its stage, so main can pass at any moment - the
  pre-cut landing and `--rehearse` are gone. `release.sh build X --notes FILE`
  makes one release commit on main with the GATE-LOG row and coverage record,
  refuses one that touches anything else or fails the lints reading it, packages
  and tags it, and leaves main untouched on any failure; the post-release record
  is gone. `publish` pushes main and the tag atomically, refusing a
  non-fast-forward main or a tag already on origin. `handoff.sh --stack BASE`
  runs one suite per stack. Coverage at -j4 measured per file against serial:
  one file differs (filed). t/tools/103-106, t/lint/214.

- SM970 (4dc68058) **security: a value used as a whole link target can be kept
  to a safe scheme with `| url_safe`.** The stash escapes a query or db value so
  it cannot leave its attribute, but `javascript:` written as a whole `href`
  stayed a script link. The new filter, on every page, layout, component and
  registry render, passes a value with no scheme (a path, `?query`, `#fragment`,
  `//host`) or an `http:`, `https:`, `mailto:` or `tel:` one unchanged - no
  second escape - and turns anything else into `#`, reading the scheme through
  character references, percent-encoding, case and leading controls. The
  built-in fallback layout's nav links use it; the authoring docs for query
  parameters, data tables, auth values, navigation and layouts say where to;
  t/lint/213 holds every whole-value `href`/`src`/`action` in the shipped pages,
  templates and fallback layout to it, exempting by name only the engine-built
  language alternates and `site_url`. Ruled 2026-10-07: option 1 with 3.

- SM943 stages 2-3 (4c7c87dd) **an action's MCP twin and the twin's hints are
  declared on the action, and the lints that kept the copies in step check the
  declaration instead.** `mcp => 'tool'` on an `%ACTION` entry names the twin
  (60 of them). The twin's readOnly, destructive and changesAccess hints are
  derived from the action's `mutates`, `destructive` and `changes_access`; only
  openWorld is declared, as `mcp_open_world`. `lazysite-mcp.pl` builds
  `%ANNOTATE` from these plus its own rows for the 24 tools with no API twin, and
  the audit's skip list from readOnly less 17 named reads it has always
  recorded. tools/list is byte-identical and no audit row changes. The unlocks
  map no longer claims `save_data_row` and `delete_data_row` for `write_data`
  (both are gated on `manage_data`, and neither applies its allow-list) or
  `read_nav` for `manage_content` (it is `manage_nav`'s since SM421); t/lint/90
  now checks that direction. Lints 14, 22, 23, 58 and t/unit/lib/16 lose the
  assertions that compared a value with itself or repeated another file's, and
  one completeness check of every declaration replaces them
  (t/unit/lib/200).

- SM906 T3 (a5c9632d) **an unreadable account store answers `cannot-tell`, not
  "Invalid credentials"** (ruled 2026-10-07). With `lazysite/auth/users`
  unreadable no secret can be checked, and a caller holding a good token was
  told it was invalid (MCP: "reissue the token"). It now gets `cannot-tell` 503
  naming no store and no repair - it has proved nothing yet, and a host fault is
  not a stranger's to map - and is told not to reissue; the operator's log
  names the file. t/integration/107.

- SM950 (2)(3) (0fb8c870) **the gate runs on main after each landing, and a cut's
  gate reuses coverage instead of spending an hour re-measuring it.**
  `tools/gate-main.sh` gates main's tip for NEXT_VERSION, detached, and prints
  the receipt instead when that commit already passed; before the pre-cut pass
  it rehearses (`release.sh gate --rehearse`, a receipt `build` refuses). Every
  passing coverage run is kept by its inputs digest and offered to the next gate
  with the same digest; the receipt says `coverage=reused` and from which run.
  The digest now leaves out tests that, read with PPI, can start no process,
  load no file and call no sub that does (moved on 9 of 24 commits, was 11).
  t/tools/100-102, t/lint/208.

- SM969 (e4b8b74e) **security: a form outcome was written to the page cache and
  shown to the next visitor.** The outcome banner reads `form=` and `outcome=`
  from the query string, which the cache decision did not count, so a request
  after any page edit baked its banner - the text of the link followed - into
  the cached page for every later visitor. Such a request is now rendered for
  itself only, as a `nocache: true` page is. Found by the SM869 review's second
  pass; t/unit/processor/90.

- SM968 (b3c9181a) **security: a page that set TAGS let a reflected value run as
  a template.** The form prefill and outcome banner neutralise `[` and `%` in the
  visitor's text, which holds only while the tags are `[% %]`; after
  `[% TAGS {{ }} %]` in a page body, `{{ site_name }}` in a link's query was
  evaluated. A page body's TAGS directive is now a comment, with a warning in the
  log; layouts keep it. Found by the SM869 review's second pass;
  t/unit/processor/90.

- SM967 (1b28cf5a) **security: a value could spell one of the engine's
  placeholders.** The passes that protect script, style, comments, code spans
  and tags restored them by a fixed word, so a value carrying the word was
  restored as the block: a copy of the page's code span, or the page's own
  script moved into a prefilled form field, where its quotes ended the
  attribute. Each placeholder now carries a per-call key the content cannot
  contain. Found by the SM869 review's second pass; t/unit/processor/91,
  t/unit/data/65.

- SM966 (7894a882) **security: a data value could become a link, or break an
  api page's JSON.** A query value or a db: row was HTML-escaped and nothing
  more, so `[text](javascript:...)` in it became an anchor after the template
  pass (on every page listing a visitor-written row), and a backslash or control
  character in it made an `api: true` response invalid JSON. One helper now
  encodes brackets, backslash and control characters as character references in
  every value the author did not write. Found by the SM869 review's second pass;
  t/unit/processor/90 and 91, t/unit/data/65.

- SM965 (fd858c00) **security: a reflected form value could become an
  include.** A form's prefill and outcome banner are written into the page
  before the first `::: include` pass, and kept their line breaks - so a link
  carrying a crafted value could spell an include block and pull a file from
  the content root into the page (never `lazysite/`, never `..`). The one helper
  all three use now encodes line breaks as character references, which display
  as typed. Found by the SM869 adversarial review; t/unit/processor/89.

- SM964 (6a167a55) **security: a value that reached a page as data could become
  an include.** The processor ran its `::: include` pass a second time over the
  template's output. That never resolved an author's template-path block
  (Markdown had wrapped it, and the docs said such blocks are not resolved), but
  it did resolve a block that arrived as data: a visitor-written row in a public
  table, listed on a public page, could pull an unlisted file - or the body of a
  sign-in-only page - into the output. The second pass is removed; a path from
  a template variable stays unresolved by design. Found by the SM869
  adversarial review; t/unit/data/64.

- SM869 (d836836e) **security: a query value is raw in the engine and escaped
  once where it is emitted; a visitor's `[% ... %]` and `::: include` no longer
  run.** parse_query_string returns raw values; the stash escapes its own copy
  of `query.*`/`params.*` (line breaks as `&#10;` too); the form prefill sink
  and the outcome banner escape unconditionally and make `[%` inert. Measured
  before: `?x=[% site_name %]` prefilled the site's value, an outcome banner
  ran the same, and a declared value carrying a `::: include` fence pulled a
  content-root file into the page. **Authoring change:** `query.*` was and is
  escaped, so `| html` on it escapes twice - the shipped login and claim pages
  dropped theirs (`next=` with `&` posted back as `&amp;`); remove it from your
  own pages and layouts. A `[%` in a form `value:` is now shown, not run.
  t/unit/processor/88. Adversarial review pending.

- SM906 T3 follow-up (47f167e8) **security: an unreadable or corrupt group store
  no longer makes every signed-in user a manager on the page side.** The
  processor keeps its own module-free copy of "does any group grant manager
  access" (ADR 0001), and answered "no - an unsecured site" when
  groups-settings.json existed but could not be opened or did not decode; an
  unsecured site lets any signed-in account into the manager and renders it
  with every capability. It now treats a present-but-unreadable store as
  secured and logs it, as T3 made the API's copy do. Absent still means a site
  with no groups yet. t/integration/108 (both cases fail on the old copy).

- SM906 T3 (2a84406e) **an auth store the web server cannot read answers
  `cannot-tell`, not an empty grant** (ruled 2026-09-29). With
  `groups-settings.json` unreadable, `whoami` reported 0 of 29 capabilities
  and a gated call told an account holding `api` to ask for it; MCP said the
  same. Now the control API answers kind `cannot-tell`, HTTP 503, naming the
  store (docroot-relative) and the repair (`lazysite check --docroot <docroot>
  --fix`), on the token and cookie channels; MCP answers -32003 with the same
  fields. It covers `groups`, `user-settings.json` and `users` too. Two
  fail-opens closed on the way: an unreadable group store read as an unsecured
  site, making every signed-in account an operator, and an unreadable
  `user-settings.json` let a disabled account's token through.
  t/integration/107.

- SM939 SC2 (9e6e8d72) **a WebDAV folder delete that cannot finish says what
  stopped it** (ruled R1, amended). Recursive DELETE works; when a directory
  INSIDE the folder is not writable it stops part way, and answered a bare 500
  "Cannot delete the entry" while skipping the housekeeping for the pages it had
  removed. It now answers 507 naming that directory (relative to the site) and
  how many files were left, cleans up after the pages that are gone, commits
  the partial removal, and KEEPS the access rules on what is left - forgetting
  the folder's rules would unprotect it. Sending the DELETE again once the
  directory is fixed finishes it. t/unit/dav/31.

- SM957 (368fb6a6) **Submissions is the manager menu's first entry, with an
  unread count.** The menu is four groups: Site (Submissions, Files, Navigation,
  Visitor statistics), Setup (Appearance, Extensions, Connectors, Data tables,
  Domains), Access and System; locked entries keep their padlock and reason.
  `/manager/submissions` lists every form and shows its rows newest first with the
  quarantine filter, each opening `/manager/submission`; the viewer moved there
  from Extension Config, whose `?submissions=` now redirects. Extension Manager
  and Extension Config are one entry, "Extensions". Handlers left the menu and is
  reached from each form and from Extensions. The count is the bell's own read
  state for submission notices (`notices` returns `unread_by_type`). Found on the
  way: the bell sent its read marks as GETs, which the API refuses, so none was
  kept; they are POSTs now. t/unit/manager/202-204, 28 sabotages.

- SM963 (133e6aba) **an approval says which groups it could not place the
  account in.** account-approve joined each group flagged for registrations
  inside an eval whose failure was dropped: with a flagged backend group it
  answered "Approved 'alice' into learners." and ok, the other group gone
  unsaid. Each failure now comes back in `unplaced` with its reason - a line
  each on the CLI, the Users API result, both audit trails (`NOT placed in` /
  `not-placed=`), and SM858's approve result and success dialog. The account
  and its link are still made. t/unit/users/49, ten sabotages.

- SM962 (7fde49f8) **a username is refused by name, never silently rewritten.**
  `account-approve jo+hn` created `john`, then minted its claim for `jo+hn` and
  failed - leaving a credential-less account with no link, under a name that may
  be somebody else's. `add` stripped every character a username cannot hold and
  every caller carried on with the original. It now refuses, naming the
  character and the allowed set (letters, digits, `.`, `_`, `-`), before
  anything is written - for approve, `add`, `setup-sysop` and the Users API
  alike. **A name with other characters that `add` used to shorten is now an
  error.** t/unit/users/48, three sabotages.

- SM961 (a940e873) **a submission arriving during a delete, confirm or approve
  is no longer lost.** Those rewrite the submissions store - read it, write a
  copy, rename it over - and nothing locked that window; the file handler's lock
  was on the store file, which the rename swaps out. A row appended meanwhile
  went into the discarded file, with the visitor already thanked. Both sides now
  take one sidecar lock (`.<store>.lock`, `Lazysite::Util::store_lock`) that the
  rename never moves. t/unit/forms/36 forces each direction by holding the lock;
  either half removed fails it. Found while building SM858.

- SM858 (33660970) **an operator approves an account from a button on the
  Submissions view.** A form that names its address field in its conf
  (`account_email: email`) gets Approve on each row; it runs `account-approve`
  through the users tool with the address read from the stored row - never the
  request - and the username is the local part, lowercased. Nothing is stripped
  or suffixed: a character a username may not hold, a name taken in any case,
  an address already on another account, a quarantined row or one already
  approved is refused by name and creates nothing. The row records the account
  it became. Needs `manage_users` and `read_submissions`, cookie-only, audited
  with the row and the account. t/unit/manager/200-201, twelve sabotages.

- SM960 (5208b395) **security: a custom auth header name was trusted from
  anyone.** With `auth_header_user` set (the docs' example is `Remote-User`) and
  no `auth_proxy_trusted: true`, a visitor sending `Remote-User: alice` passed a
  page gate as alice - and behind the built-in auth wrapper too, which vouches
  for `X-Remote-*` alone. The trust gate stripped only the fixed `X-Remote-*`
  names; it now strips the configured ones unless a proxy is trusted, and logs
  each. **A site using custom header names must set `auth_proxy_trusted: true`**
  - until it does, those headers are discarded and visitors read as signed out.
  Default-named sites are unaffected. t/integration/106; the auth docs show the
  flag.

- SM857 (05454ed6) **a page can show each signed-in viewer their own rows:
  `db:<table>(mine)`.** No filter in the engine was written by the server, so a
  page rendered the same rows for everybody. `mine` makes the engine add
  `created_by = <viewer>` from the trust-gated identity; the page and request
  never supply it, and it ANDs with the other filters, `.count` and `.field`. An
  anonymous viewer gets no rows (never all, never an error); rows with an empty
  created_by belong to nobody. A table without `timestamps: true` is refused by
  name, logged and reported by `validate_page`. A `(mine)` page takes the gated
  page's cache treatment, and a `(mine)` binding the page did not declare is
  refused. t/unit/data/63 renders as ann, then bob, then signed out, on a
  `ttl:` page; removing the bypass served ann's rows to both.

- SM943 (df6d9406) **every per-action fact the manager API keeps is declared
  once, on the action's entry in `Lazysite::ControlApi::Actions`.** Ten tables
  in `lazysite-manager-api.pl` were hand-kept copies: the known set, mutating,
  destructive, changes-access, dav-scoped, the file-surface mode, the cookie
  capability, the self-gating and cookie-only reasons, and the audit skip list.
  Each is now a field on `%ACTION`, written only where it differs from its
  default. Audit's default is "audited when it mutates", which leaves 14
  exceptions. The CGI builds every table from it. A test proved all ten
  derived tables equal to the literals before those were removed. Ten lints and
  tests now read the declaration, and a misspelt field is refused at load. No
  behaviour changes. This was stage 1; stages 2-3 are the entry above.

- SM959 (7d1234f8) **a helper that exits before reading no longer kills the
  process writing to it.** Eleven places wrote to a child's stdin with SIGPIPE
  at its default - the form handler's mail, the manager API's plugin and users
  calls, the auth CGI, MCP, OAuth, the installer - so a helper that died on
  start (a missing module, a compile error) killed the caller mid-request with
  nothing logged. Only the processor guarded. Each spawn now runs with SIGPIPE
  ignored and the write fails as a write; lint 211 holds the rule and
  t/unit/lib/199 proves it (signal 13 without the guard). Found as a flaky
  t/unit/forms/24 - 4 failures in 8 parallel runs on main, now 0 in 8.

- SM958 (181fa14a) **security: a token-gated action was open to any manager
  account.** On the manager channel a non-operator was capability-checked only
  for actions in `%COOKIE_CAP`; an action with a token gate and no line there
  was unchecked. Fifteen were, three of them writes: `form-uploads-save`
  (0.15.x) and `form-notify-save` (0.15.2) let a manager without `manage_forms`
  turn file uploads on for a public form or change its notices, and
  `regenerate-registries` needed no `manage_content`. Token clients were never
  affected. The token gate now applies on the manager channel wherever
  `%COOKIE_CAP` is silent, so a new action is gated on both by its one `%GATE`
  line; four actions that decide for themselves are named with reasons. Lints
  14 and 87 now read `a+b` values and `_` names - they had dropped five
  entries. Found by the SM943 survey; t/unit/manager/138.

- SM955 (eaf23857) **the XMPP test reports a recipient the server refuses, and
  every delivery failure is audited** (ruled R9). A server accepts a message to
  a JID it cannot deliver to and bounces it a moment later; the test
  disconnected straight after sending and said "sent" (the 0.15.2 edge walk,
  R4). It now waits up to three seconds for an error stanza about that
  recipient and fails at a new `delivery` stage with the server's condition -
  `item-not-found: no such user`. A real notice does not wait (it is sent while
  a form submission waits for its reply). Every failure, test or real, is in
  the audit log as `notify ... failed` with its cause. t/unit/lib/62 drives a
  stand-in client that bounces; t/unit/lib/14 asserts the real-notice audit
  line. Three sabotages, three named failures.

- SM932 (2) (e5b1c92e) **`lazysite check --sinks` says whether syslog received a
  line** (ruled R6). It sends one marked line through the engine's own
  `forward_line` - the path every `log_event` takes - at `err`, so any
  configured threshold forwards it, then looks for it in the journal, then
  /var/log/syslog or /var/log/messages: received (ok), sent and not there
  within 3 s (FAIL, naming the facility), could not be sent (FAIL), cannot
  read the log to tell (warn, saying why), or forwarding off (warn). Opt-in,
  because it writes to the host's log. `forward_line` now returns whether it
  sent. t/tools/99 uses the engine's dump redirect and a stand-in journalctl,
  so the suite writes nothing to the host log; three sabotages, three
  failures. The web server's error log is not probed from the command line.

- SM913 S2 + S4 (2b75d122) **a link shortener holds a submission, and each form
  says whether its quarantine is on** (ruled R2). S2: one link to a shipped list
  of shortener hosts (`bit.ly`, `tinyurl.com`, `brnd.li` from the reported spam,
  and others) is a reason on its own, matched as a link - a scheme, `www.`, or a
  path - so naming one in a sentence is not. S4: the Handlers page shows
  "quarantine on/off" on each form and lists what holds a submission; the
  manager reads the form config through `Lazysite::Handlers`, and
  t/unit/forms/35 posts through the real handler for every spelling of
  `quarantine:` and threshold to hold the two readers together. S5 (a default
  keyword list) is not shipped, as ruled.

- SM912 P4 (d58a2376) **recorded: a rule checked against nothing says so.**
  Built in commit e765424f and shipped without a changelog entry, and the filing still read "P4
  remains". An ACL write against an auth store that knows no accounts or groups
  returns `principals_unchecked: 1`, so "accepted, unchecked" is no longer
  reported as "accepted, verified"; t/tools/91 asserts both states. Found while
  starting it as WORK-PLAN-0153 Q1.

- SM956 (a25f5760) **a fast run of pages is a bot** - the site owner's rule: "a
  visit with more than five pages at under ten-second gaps is not a person". A
  sixth page view from one source inside ten seconds of the fifth, each inside
  ten of the one before, moves that source from `unattributed` to `bot`,
  including the earlier views (the same reach-back the scanner rule uses). One
  or two requests never move, a gap of ten seconds or more restarts the count,
  and assets are not page views. **Counting basis 5: `unattributed` steps down**
  on upgrade; the day rollup's `bot_paced` counts what moved. A source is the
  token and user-agent, so identical browsers behind one network clicking fast
  together can read as one - the scanner rule's limit too. Three test fixtures
  that modelled a "person" as a page a second now read at a person's pace.

- SM954 (37f02c18) **a quarantined submission shows why, in the table.** The
  reason was stored (`_spam_reason`) and set as the tag's hover title, which a
  touch screen never shows; the owner saw "quarantined" with no reason (0.15.2
  edge walk, R3). It is now drawn as text beside the tag. t/unit/manager/180,
  which runs the viewer's own code against a recording DOM, asserts it.

- SM953 (290fa182) **a missing submission is named by its form, not its file.**
  The single-submission view answered "no submission <id> in
  lazysite/forms/submissions/contact.jsonl"; the owner ruled a message should not
  expose file paths (0.15.2 edge walk, R2). It now says "no submission <id> on the
  form 'contact'", and a missing store "no submissions for the form '<name>'".
  t/unit/forms/34 asserts the form and id are named and no path appears.

- SM952 (8aa93327) **a form's rate limit is its own, and only a stored submission
  spends it** (ruled R8). The limiter was keyed on the address alone and recorded
  a time on every post that reached it, before validation: five posts to one form
  refused another form's first, and a visitor who got a field wrong spent their
  allowance correcting it. That was the 0.15.2 edge walk's R8. The check still
  runs early and refuses a flood before any work, but only reads; the time is
  recorded once the submission is stored (quarantined ones included - the form
  kept them), keyed on form and address. Rows of the old key age out within the
  hour. t/unit/forms/16 drives both cases through the handler; each fails with
  the old key or with recording on every post.

- SM951 (68a21c22) **the manager bell works.** Its script runs in `<head>` and
  looked for the bell at once, before `<body>` was parsed, so it never found it
  and set nothing up: no badge, no panel, and a click threw "mgToggleNotif is not
  defined" - on every manager page since at least 0.10.0. Found by the 0.15.2
  edge walk (R1) in the owner's browser. The block now runs when the document is
  ready. The existing tests read the template's text and passed throughout;
  t/unit/lib/198 loads the layout's own head script and bell in headless
  Chromium and asserts the handler exists and opens the panel, and it fails on
  the 0.15.2 layout.

## 0.15.2 - EDGE: an install says whether the site works, the bell can be acted on, and a submission is shown as it was typed (2026-10-06)

- SBOM (d0ddee56) **`Net::DNS` is declared in the SBOM, and an undeclared module
  fails the handoff that adds it.** SM925 X2 (the XMPP endpoint from the domain's
  SRV record) added `require Net::DNS` without an entry in
  `dist/config/sbom-deps.json`. The strict SBOM check refuses exactly that, but it
  ran only in the release build - after the gate had passed, in the release
  manager's terminal - so the 0.15.2 build was the first thing to notice. Lint 209
  runs the same strict check against the real tree on every handoff, and the
  release gate now runs the manifest, SBOM and man-page checks too, before it
  writes its receipt: the build that follows should refuse nothing the gate could
  have found.

- Gate (0c4f025d) **the release gate runs apart from the build, and cannot prompt for a
  password.** The 0.15.2 build stopped in the release manager's terminal on a
  polkit prompt: t/tools/81 ran the package's postrm against a fake root that
  redirected `/etc/lazysite` and nothing else, so the host's own `systemctl
  daemon-reload` ran. The test now gives the fake root its own systemd directory
  and a stand-in `systemctl` that records the call, and checks the reload reaches
  the stand-in. Structurally: `release.sh gate` runs the suite, bench and
  coverage with no controlling terminal (`setsid -w`, stdin from /dev/null) and
  writes a receipt for the exact SHA, version and channel with every log beside
  it; `release.sh build` needs that receipt (or `--run-gate`) and does only the
  short packaging and tagging. Lint 208 holds both: every gate step is detached,
  and the release script and gate tools call no sudo, systemctl or pkexec.

- SM938 D5 (a5f431ea) **a submission notice links to the submission** (ruled
  R18; closes SM938 B-1). The operator's words: the bell "should show link to
  the thing that happened". A notice linked to the Handlers page, and no manager
  page addressed one submission - SM928 defect 4 had recorded why it stopped
  there: a deep link needs the store, which only the handler that wrote the row
  knows. The file handler now reports the row it wrote (store and id), and the
  notice links to **/manager/submission**, a new page showing that one
  submission as text. A form with no file handler still links to the Handlers
  page.

  The read is `form-submission` (control API) and `read_form_submission` (MCP),
  gated `read_submissions` like the table and confined to the same stores. A row
  deleted since the notice was sent is not-found, in words saying so. The row id
  now has ONE definition (`Lazysite::Handlers::submission_row_id`), used by the
  file handler when it writes and by every submissions reader, so the link and
  the table cannot name the same row differently.

- SM904 (b29b765c) **a submission with a non-ASCII character is shown, and can be
  acted on** - SM904's read half, found while building SM938 D5. SM904 made sure
  a value is STORED as the visitor typed it; nothing checked that it could be
  read back, and the submissions readers the manager table, the control API and
  MCP share were wrong three ways. The store is read as characters and was
  decoded as bytes, so **every row holding an accented letter or any other
  non-ASCII character was counted "malformed" and left out of the table** - a
  visitor called Herve-with-an-accent submitted and nobody saw it. The row id
  hashed the character string, which dies on a character above U+00FF, so such a
  row could not be deleted or confirmed. And confirming a quarantined row wrote
  bytes through a UTF-8 layer, encoding its text twice. All three read and write
  characters now, and the id is the hash of the line as it is on disk.

- SM938 D4 (8e1e5ec0) **a form's `notify:` is set from the manager** (ruled R17).
  D2 made the Handlers page say where a form's notice goes and what stops it; the
  form's own `notify:` was still edited as text over WebDAV. The expanded form now
  has **This form's notice** - Off, On, or Full (the notice carries the
  submission) - written into the form's conf when Save is pressed and only if it
  changed, so saving the handlers never rewrites a line nobody touched.

  The same write is `form-notify-save` on the control API (gated `manage_forms`,
  as `form-uploads-save` is for the same file) and `set_form_notify` over MCP.
  Only `off`, `on` and `full` are accepted: the reader treats an unknown value as
  `on`, so writing one would look like it took and change nothing. Every existing
  `notify:` line is replaced by one, because the reader takes the first. The
  reply carries `announces`, D2's report computed from the conf as written.

- SM933 A5 (5a3b2a82) **`check --fix` may correct what the installer itself left**
  (ruled R3, scheduled R16). SM274 holds `--fix` to the group-write bit on a
  declared directory, because the install state recorded only the DECLARED mode
  and could not tell drift from a sysop's deliberate choice - so an install
  whose own output came out wrong could not reach a clean report. The install
  state now also records the mode the installer actually LEFT on each directory
  it created (`dirs_left`). A directory still at exactly that mode is the
  installer's output, untouched since, and `--fix` sets the declared mode,
  setgid included. One whose mode has moved since stays the sysop's, under
  SM274's rule.

  Recorded only on creation and carried forward by later runs, so a directory
  that was there before the install is never claimed. How the installer leaves
  the wrong mode in the field: a chmod by an account outside the directory's
  group drops setgid silently - the case where A2's regroup could not apply.
  Existing sites have no record until a run creates something, so for them
  `--fix` behaves as before.

- SM938 D3 (1b3cdce4) **the bell's read state is said, not inferred.** Opening
  the panel used to mark every notice read, below the fold included, so the badge
  counted panel openings rather than outstanding work. Opening no longer marks
  anything. Following a notice's link marks THAT notice read; "Mark all read" marks
  the lot; "Dismiss" takes one out of the panel. Dismissal is a second marker and
  the store keeps every line, as the report asked ("the bell store is the record
  and should stay one").

  Each notice now carries a stable `id` (12 hex characters, from its stored line).
  `notices-seen` takes `id` (mark one read) and `id` + `dismiss` (dismiss one), and
  with neither marks all read as before. An unknown or malformed id is refused as
  `not-found`, naming it. `notices` reports `read` on each notice, plus `unread`
  and `dismissed` counts. A marker written before this (principal => epoch) still
  reads, so an upgrade loses nobody's position. State is per principal, and ids
  that have aged out of the notice window are pruned on the next write.

- SM938 D2 (1b3cdce4) **the Handlers page says where each form is announced, and
  if not, what says no.** Whether a submission reaches XMPP is decided in three
  places - the form's `notify:`, `lazysite/notify.conf` (`emit.submission`,
  `route.submission`), and the extension plus its account - and only the last had
  any interface. Each form row now shows "announces to bell, xmpp" (or "announced
  nowhere"), and the expanded form shows each endpoint it will not reach with the
  one reason: the FIRST no, in the order delivery meets them, because a later
  reason sends somebody to fix something that is not the cause.

  Read-only, by choice: the filing records no ruling, and its condition is that
  the text stays the source of truth. The report is built from the SAME checks
  delivery uses (`_emits`, `_route`, the XMPP account check), not from a
  description of them, and the test runs a real delivery beside each case to show
  the two agree. The XMPP account check is split so the report does not log: it
  returns its WARN as a closure the delivery path runs. The `notify:` parse moved
  from the form handler into `Lazysite::Notify::form_notify_mode`, so the page and
  the handler cannot read `notify: fll` differently; the handler still logs the
  unrecognised value.

- SM939 E2 (d0ba81b2) **`--no-starter`: a fresh site without lazysite's own
  pages** (ruled 2026-10-03, R15 - the default is unchanged). A fresh install
  ships the demo pages and ~70 pages of `/docs/` onto the owner's domain,
  publicly served and in the sitemap; removing them afterwards is seventy-odd
  deletes to undo something the install did on purpose. `lazysite provision
  --no-starter` (and `install.pl --no-starter`) leaves them out and keeps the
  pages a site needs: forgot, logout, assets, `.well-known`, the manager.

  What counts as starter content is declared once, in `classification.json`'s
  `starter_content`, and carried into the manifest as a `starter` flag on each
  entry - the installer never sees the classification. **The choice is recorded
  in the install state**, because `docs/` is bucket `code` and every untracked
  docs file would otherwise be planned as a fresh install on the next run: the
  opt-out would have lasted exactly until the first upgrade. Only untracked files
  are skipped, so the flag cannot delete content a site already has.

  The test's first version proved the opposite of what it claimed for that half:
  it used `upgrade --force` to the version already installed, which is a no-op,
  and a sabotage that stopped the state being read still passed. It re-lays with
  `reinstall` now, which plans every file.

- SM933 A2 (371606be) **everything provision creates takes the docroot's group**
  (ruled 2026-10-03, R13). Measured first (PR0): the installer set no group on
  anything it wrote, so all 202 created paths took whatever the kernel handed
  out - the process's primary group under a non-setgid docroot - and one path was
  wrong under EVERY docroot mode: the private store, created beside the docroot
  where its setgid bit cannot reach, took the site root's group. On Hestia that
  is `<user>:<user>`, a store the www-data CGI cannot write.

  Each path is regrouped at the moment the installer creates it - declared
  directories, installed files, runtime paths including the private store - and
  **never an existing one**, so an upgrade cannot undo a sysop's choice. Re-run
  against the measurement fixture: 202 of 202 paths in the docroot's group, the
  field-shape run passes its own health check where it failed on the private
  store, and the non-setgid run goes from 16 failures to the one the fixture set
  on purpose. A path the installer could not regroup (it is not a member of that
  group) is counted in the install summary, as one fact rather than N check
  failures. This also closes SM939's permissions half: `docs/features/` was
  always group-writable, in the wrong group.

- SM936 (afe87085) **an access rule does not outlive the thing it governed** -
  and measuring the filing's four steps against this tree gave three different
  answers, so three different things were done.

  The report, from a live site at 0.14.4: draft a page, delete it, write a
  DIFFERENT page at the same path, and the new page is born governed by a rule
  nobody set. It failed safe there - `draft` withholds - and the argument for
  building it was the reporter's own: **the direction of the accident is not a
  property of the mechanism.**

  **Pages: already fixed, and it does not reproduce.** `action_delete` has taken
  the rule with the content since CF-2, whose comment tells this exact story.
  Measured: the rule goes, and a new page at the path is `open`. Pinned by a test
  anyway, because nothing asserted it from the delete side.

  **Moves: already correct.** The rule re-keys with the content - the opposite
  failure and just as bad, since a move that dropped the rule would publish a
  private page by relocating it.

  **Tables: REPRODUCED, in the direction that grants.** Table rules live in the
  same store, keyed `lazysite/db/tables/<name>`, and `drop_table` never touched
  it. Measured: set `read: ["@volunteers"]`, drop the table, recreate it as
  somebody else, and the new table answers `read=@volunteers` with an owner who
  did not make it - **a read granted to a group nobody granted it to.** The drop
  now forgets the rule and says how many it removed, in `drop_table` rather than
  in one caller, for CF-2's own reason: a fix in one caller is a fix one surface
  wide.

  **Creates: the remaining silence, and it is by design rather than a leak.** A
  rule on an ANCESTOR governs a page created under it, which is correct - and the
  create said nothing, so an author publishes a page meant to be public, it 404s
  to the world, and the reply that caused it reported four fields none of which
  was the reason. A create into a gated path now names **which key** gates it and
  that it is inherited. Only on a create, and only when something actually gates
  the path.

  The resolver's scope walk - exact key, extensionless stem, longest ancestor,
  then the site-wide spellings - now answers "which key won" as well as "which
  rule", because a second walk would have been a second definition of
  precedence. `t/lint/36` caught the move: it was reading the old name and its
  ordering assertions had started matching a four-line wrapper.

- SM934 (8318f489) **a form's declared field rules are enforced on the server, and
  a breach is refused naming the field and the rule** (ruled 2026-10-02, R1; the
  contract's home ruled 2026-10-02).

  `required`, `email`, `max:N` and `pattern:` were rendered as HTML attributes and
  checked by the browser **alone**. Measured in the handler: it performed exactly
  two content checks - uploads, and "not entirely blank" - and nothing between
  them. So the rules held for a visitor using a form and not at all for a direct
  POST, which is the traffic that needs them. A scanner put `' OR '1'='1'-- -`
  into a field declared `email` and it was stored; not an injection (the storage
  path escapes correctly) but **a declaration the engine ignored**.

  **The rules arrive from the render, not from the submission.** A form's fields
  live in the page's `:::form` block and the handler had never seen them - the
  form's `.conf` carries targets and upload limits, not fields. Three ways to
  close that were weighed and the hazard decided it:

  - storing the rules in the `.conf` lets a hand-edited block **drift** from it,
    so the server would enforce a rule the browser never showed - SM921's hazard
    in its original direction;
  - having the handler parse the page named by `_page` is **bypassable**: that
    field is visitor-supplied and tied to nothing, so a submitter could name a
    page with no rules;
  - so the rules are **derived at render** into a sidecar beside the form's conf,
    keyed on the same `_form` that already selects it. What the server enforces is
    what the visitor was served, and drift is impossible by construction.

  **A form not rendered since the upgrade enforces nothing**, which is the safe
  direction and the same answer FV2 gives for an uncompilable pattern. Refusing
  until a render happened would take working forms off live sites.

  **A pattern the browser would ignore is ignored here too.** A browser compiles
  `pattern` as `^(?:p)$` with the `v` flag and the specification's answer to one
  that will not compile is to ignore the attribute **in full**. The browser's own
  judgement is asked by name, from `Lazysite::Validate::html_pattern_problem` -
  lint 204 holds that it exists exactly once - so a rule the page never applied
  cannot refuse a visitor, and "cannot compile" never becomes "nothing matches",
  which would turn a form from accepting everything into accepting nobody on one
  bad character. The match is **anchored**, as the browser anchors it.

  **`max` carries its meaning, not just its number**: the render gives a number
  field `max=` (a value bound) and everything else `maxlength=` (a length bound),
  so the sidecar records which - and an undeclared max records the 1000 the render
  applies, because that is what the browser was told.

  **A VALIDATION REFUSAL IS NOT AN ANTI-SPAM BLOCK.** It gets its own outcome and
  its own counter (`invalid`, by rule, beside `blocked`). `blocked` is published as
  "controls stopped N"; a visitor who mistyped their address met no control, and
  folding the two together would be the two-populations-in-one-counter fault
  SM941 removed from the visitor report in this same release.

  An existing gate caught that conflation - and then caught something worse: the
  roll-call in `t/unit/forms/16`, whose whole purpose is "an uncounted control is
  invisible to the sysop", was **blind to the new channel**, because it enumerated
  `reject` / `reject_user` and the new codes are raised through `reject_invalid`.
  It now follows the channel rather than the spelling.

- SM941 (e4036dbc) **a visitor report whose numbers agree with each other - and
  no field that claims to have counted people** (ruled 2026-10-02, R8-R12).
  **COUNTING BASIS 4, `schema_version` 3: counts DROP SHARPLY on upgrade.**

  Four defects, established from source plus one day of live user-agent data the
  release manager supplied, all visible in a single call's output:

  1. the two published totals differed by exactly `asset_hits`, which **no
     projection published** - so there was nothing in the report to reconcile
     them with (15,979 against 18,849 on the instrument);
  2. `human_visits` counted 404s as visits - **8,023 of 15,979**, so half the
     headline was requests for pages that do not exist;
  3. `unique_visitors` summed EVERY class while sitting beside a one-class
     figure, publishing 4,359 unique visitors across 4,241 visits - which a
     unique visitor cannot do;
  4. `classify()` ended `return 'human'` and **never consulted the
     `_is_browser` it had computed**, so 4,227 requests with no user-agent were
     counted as people; 43% of the sampled class was empty-UA or self-declared
     automation, including our own `lzs-fetch`.

  **`human` becomes `unattributed`**, because it was never a measurement. We
  cannot know a request came from a person; we can know when it did not. The
  class is what no rule could exclude, it is named for that, and `notes` says
  where an operator reads it that the group is an **upper bound** on people. An
  absent user-agent is its own class, `no_agent`, counted outside the visit
  counters by construction - it returns before the split rather than being
  subtracted by a second rule.

  **The counters sum, and the report publishes all three** so the identity is
  checkable from the output rather than taken on trust:

      pageviews + asset_hits + error_hits == traffic_classes.unattributed.visits

  `unique_visitors` reads the same class `pageviews` does, as the manager page
  already did. Every counter **names its population** in a `populations` map -
  writing the invariant test found that `status_codes` counts one class and the
  report said so nowhere - and `window_scoped` says which fields the window
  governs. The month series is not window-scoped on purpose and now declares it:
  the one reported finding that was correct behaviour reading as broken.

  **Also measured false and retracted.** The first draft of the filing parked the
  rename on the claim that it would break every reader, dashboard and layout.
  That was an assertion: it is 8 usages in ONE file, none in `lib/`, `tools/`,
  templates or the front end. And a comment written during this build claimed
  `schema_version` 3 would discard the stale cache - the cache gate knows nothing
  about class names, so the old buckets are **migrated** on load instead; without
  that, their traffic would have vanished from every breakdown while staying
  inside `hits`, in the release whose purpose is sums that add up.

  **The invariant test found a defect in three fixtures of its own.** They wrote
  the user-agent as `u` where the ingester reads `ua`, so every line they
  produced reached the classifier with an EMPTY user-agent and the old `human`
  fall-through swallowed it: those tests asserted a class they were not
  exercising. Fixed, and the manager stats-bar test now derives its class list
  from `@CLASSES` rather than holding a copy, which is the mistake its own header
  warns about.

  The manager Stats page stops saying "human" in four places, and gains a **Not
  found** tile so the halved headline has its subtraction visible on the page -
  SM329's precedent, applied to the same kind of drop.

- SM824 (27e41c5e) **a layout can emit JSON-LD from front matter that already
  exists** (ruled 2026-10-02: expose a raw copy and ship a filter, rather than
  walk-and-escape `sections`).

  Three obstacles, measured by the sites agent and offered as input to this filing
  rather than as a defect report: the head meta variables reach a layout already
  HTML-escaped by a single escape point **with no inverse**, so a layout could not
  recover the author's text; there was no `json` filter reachable from a layout, so
  the alternative was hand-rolled quoting in a template; and `sections` already
  reached the layout raw, against the stated invariant.

  Each escaped value gains a `_raw` twin, and `| json` encodes one. **The exception
  is documented where the invariant is stated** rather than only in a plan - and it
  names an exception that already existed rather than introducing one.

  **The filter escapes `<`, `>` and `&` as well as the JSON control characters**,
  because a `</script>` inside a JSON-LD block ends the script element and
  everything after it is parsed as markup. Valid JSON that cannot break out of the
  element it sits in; asserted by round-tripping a close-script payload through a
  real render.

  Registered in BOTH `%tt_opts` blocks - the page render and the component render -
  because a filter present in one is a filter a component cannot use.

  **A `_raw` value is not safe in HTML**, and that contract is written beside the
  code and in FEATURES: the escaped name is for markup, the raw name only for
  `| json`. Not an escalation, and the reporter graded it so first - only the page
  author can write front matter, and that same author can already put raw HTML in
  the page body.

- SM935 (2cd7aaa1) **the form rate limit is a rolling hour, so a limit of five no
  longer permits ten.** The counter bucketed on `int(time/3600)` with the key
  `"$ip:$hour"`, so the window reset on the clock rather than on the submitter:
  five submissions at 10:59:59 and five at 11:00:00 is ten in one second, inside
  the rules, and reachable by anyone who notices the clock.

  The stored value is now the submission TIMES and the window is the hour before
  now. The row stays bounded at the limit, because a decision only needs to know
  whether there are that many inside the window.

  The key is the address ALONE, which removes an ambiguity the old scheme carried:
  `"$ip:$hour"` put a colon-separated number after an IPv6 address that already
  contains colons, and the purge had to parse it back out.

  **Counters start from zero on upgrade.** A row left by the old scheme is a bare
  count, which is not a timestamp inside the window, so the first purge clears it.
  That is the safe direction and it is asserted.

- SM937 (2cd7aaa1) **`acl-set` stops calling a draft rule unrestricted.** A rule
  carrying `draft: true` 404s its pages to the public - a stronger restriction than
  gating, not a weaker one - and the reply said `reads_unrestricted: 1` with "anyone
  may still fetch these pages" about pages nobody could fetch.

  The sites agent named the shape: the defect that makes a correct operator do the
  wrong thing. A reader either adds a read list the rule does not need, or concludes
  the draft never took and goes looking for a fault that is not there.

  The cause was two rules for one question. This reply tested the read LIST;
  `_acl_gates_public` - SM286's definition - answers the read OUTCOME and already
  counted draft, with the reasoning written beside it. It now asks that one, and the
  caveat still fires on the owner-only rule it was written for.

- SM940 (448bc121) **a quoted scalar in a block sequence under `sections:` is a
  string again.** `- 'https://github.com/x'` parsed to
  `{ "'https" => "//github.com/x'" }`: the sequence branch strips the `- ` and
  recurses, and the recursion reached the mapping test - which splits on the first
  colon - before anything consulted the quotes. A quote is exactly what an author
  adds to protect a value containing a colon.

  Silent, which is why it survived: no warning and no render error. The layout got
  single-key hashes where it expected strings, so a `FOREACH` emitted empty cells
  and the page merely looked wrong. The sites agent found it by diffing a live
  page's front matter against `YAML::XS`, and reported it against 0.14.4 - it
  reproduced against the current tree, which is the part that decided it was
  scheduled rather than closed.

  **The obvious fix would have introduced a second defect.** "Treat a wholly quoted
  line as a scalar" also describes `'a': 'b'`, a legitimate quoted-KEY mapping. The
  discriminator is whether the OPENING quote closes at the end of the line, and that
  case is asserted: `'a': 'b'` stays a pair.

  The flow form was always correct, because `_yaml_split_flow` tracks quote state.
  The two spellings now agree, which is what the report was actually about.

- SM942 (8d981c71) **the generated feeds list items newest first, and the item count
  is bounded.** Reported from xisl.com: 59 pages, every `pubDate` correct, and the
  items in FILENAME order - so an aggregator taking "the latest 10" of a large feed
  got ten articles chosen by path, and a human opening the feed URL saw the oldest
  article in second position.

  **Sorted in the engine, not in the template**, for the reason already written
  beside the date formatting it sits next to: registry templates install under
  bucket `seed`, so an upgrade never replaces them. A template-side sort would have
  fixed new sites and left every feed that HAS a subscriber in filename order.

  **And sorted on the raw date, before formatting.** By the time a template sees
  `page.date` it is the RFC 822 string, so sorting that orders by weekday name -
  wrong in a way that still looks sorted, which would be worse than the fault being
  fixed because it would look deliberate.

  **A `date:` the engine cannot parse sorts LAST.** Prose like "last Tuesday" is
  passed through to the feed verbatim rather than invented, so it reaches the sort as
  a bare string - and a bare string sorts above every real date, which would put the
  one page nobody dated properly at the top of every reader. Only an ISO-looking
  value is a sort key. This was caught by the existing feed-date test, which failed
  the first time the sort was written without the guard.

  `feed_items` caps the count (default **50**, `0` for all of them), and the shipped
  templates gain `<lastBuildDate>` and Atom's feed-level `<updated>` from a new
  `feed_updated` variable. An existing site keeps its own template and gains the
  ORDER and the CAP without those two elements - the variable is passed regardless,
  so adding them is a one-line edit.

  A page with no `date:` was already dated from its file mtime rather than left
  undated, and that is now pinned: the sort depends on it, and a change making the
  fallback "now" would push every dateless page to the top of every reader.

- SM933 (31321799) **an install now says whether the site is healthy, and names its
  own fault when it is not.** A fresh provision on a Hestia domain printed
  `Installed: 265`, `Overwrote: 0` and four Next steps, and every request answered
  500. The engine compiled; the fault was ownership and modes that provision itself
  had just written. `lazysite-check.pl` could see all of it, and it was the one
  thing nobody had run - separately, from memory, after the install said it was done.

  The installer now ends by running the check it already ships with (PR1). The
  wiring is the whole change; the diagnosis already existed.

  **It exits 4, not 0 and not 1.** The files DID install, so treating it as a failed
  command would be wrong in the other direction - SM899's rule is that a refusal is
  not a failed command. 4 means "installed, and the site is not serviceable", which
  a wrapper script can act on separately from a copy that broke (1) or a usage error
  (2). Deliberately not 3: `--channel-check` already means "this upgrade would be
  skipped by the site's channel", and two meanings on one code in one tool is how a
  deploy script comes to read an unhealthy site as a routine skip.

  `--serving-group` is new on `provision`, `upgrade` and `reinstall`, because the
  check compares the tree against the group the web server runs as and its default
  (www-data, where that group exists) is right on the platform this ships for and
  wrong elsewhere - and a wrong guess would now turn a healthy install into a failed
  one.

  **`upgrade --all` gains a fourth outcome rather than folding it into one of the
  three.** A site that upgraded and then failed its health check is not `done` -
  "upgraded 26 sites" while one serves 500s is the reported defect at fleet scale -
  and it is not `failed` either, because the files landed and the site needs repair
  rather than a re-run. It is reported as NOT SERVICEABLE, by name, and the run
  exits 4. Same lesson as SM626: a bucket mixing two states an operator must
  respond to differently cannot be acted on.

  **WIRING IT IN FOUND A DEFECT IMMEDIATELY, which is the argument for PR1 in one
  line.** A fresh install laid down `lazysite/forms/smtp.conf` world-readable
  (0644) and the shipped check calls that a failure - "a secret must not be". The
  installer makes that file itself, by copying the 0640 template, and the mode rule
  was anchored on `.example$` so the live copy - the one that gets the password -
  missed it. SM907 AT5's own comment had said the concern was "what
  `cp smtp.conf.example smtp.conf` produces"; the installer was doing the copying.
  A fresh install now reaches 0 failures on its own output.

  Also: Next steps names the vhost-rebuild hazard and how to re-check after one
  (PR5), and a repair line records the mode that was there - `chmod 2775 (was
  0755)` - so the evidence of a fault survives its fix (PR6).

  NOT in this change: PR0's fixture measurement, and PR2/PR3, which depend on which
  of three candidate mechanisms the measurement names. PR4 (`--fix` may set the bits
  it created itself) is ruled and not built - it needs the install state to record
  the mode the installer ACTUALLY left, which is a separate change.

- SM931 (e1f7cf73) **a protected code span in a loop no longer publishes the engine's
  own placeholder.** A page rendering 27 rows from a `json:` file published the
  literal string `CODEBLOCK_0_END` in 22 customer-facing cells. Code is protected
  from Template Toolkit before the render - correctly, so a documented example is
  never executed as a template - but the body is protected ONCE and TT then
  multiplies the placeholder per iteration, while the restore was a substitution
  without `/g`. Exactly one copy came back; the other 22 were internal.

  **The repair is not the one the report proposed.** `/g` fixes the leak and
  corrupts a case the present code survives: each iteration rescans text earlier
  iterations inserted, so a protected block whose own text contains a later
  placeholder - realistically, this project's own documentation of this mechanism -
  gets that text substituted too. One pass with a callback fixes both, because the
  regex engine resumes after inserted text rather than over it. A placeholder with
  no block is left alone rather than replaced with the empty string, so an author
  who writes the marker in prose keeps it and a genuine leak stays visible.

  **And the engine now says when it happens.** A WARN names the block and the number
  of copies, because the alternative is finding it by reading rendered HTML, which
  is how it was found the first time ([[SM932]] forwards WARN to syslog by default,
  so the line has a sink that does not depend on where a CGI's STDERR goes).

  What this does NOT fix, and the honest position: inside a loop a code span cannot
  be both protected from TT and expanded by it. Protecting it is the right default,
  so the author now sees their own unrendered `[% ... %]` - which they can act on -
  and the engine's internals never reach the page. Documented beside the two
  `[%`-in-`<script>` traps in the field-practice notes, which share its root.
  `json:` was also missing from the `tt_page_var` sources in FEATURES.

- SM930 (e1f7cf73) **a sender on the site's own domain is a forgery signal, off by
  default.** The site owner noticed what the agent had not: of six spam submissions
  to their site, one gave its sender address as someone@<that site's own domain>.
  Nobody outside an organisation legitimately fills in its public enquiry form as
  one of its own people. Simulated against the nine stored submissions before being
  proposed: 6 of 6 junk quarantined, 3 of 3 genuine delivered, and this was the only
  signal that caught number four on its own.

  `spam_own_domain` sits beside the other three quarantine heuristics and is **off
  by default**, which the other three are not: they are about what a message says,
  this one is about who it claims to be from, and a form that genuinely IS for
  internal use would start quarantining its real traffic on upgrade. The filing
  conditioned the rule on the submission being unauthenticated and **the engine
  cannot tell** - a stored submission carries no actor at all, deliberately (SM402,
  re-measured by SM924) - so it also catches a staff member testing the form from
  their own desk, which is a second reason the default is off. Quarantine, never
  refusal.

  **Two false positives it refuses to cause.** It matches the WHOLE field value, not
  an address mentioned inside one: "I wrote to info@<this site> and heard nothing" is
  a genuine enquiry and the shape a frustrated customer writes. And it matches on a
  label boundary, so `notexample.com` is not `example.com` - the trap
  [[feedback_substring_matching_false_positives]] exists for. It never strips beyond
  `www.`, because the registrable domain needs a public-suffix list this engine does
  not ship and a naive strip would make every site on `github.io` match its
  neighbours; a site on a subdomain therefore does not flag the bare domain, a miss
  chosen over that class of false positive.

- SM922 (018b634f) **the link audit reports links, and stops reading its own report.**
  An operator ran it on a live site and got ten broken internal links. Two were
  real. Every other entry traced to a fault in the audit, and the count moved
  10 -> 8 -> 10 -> 7 across four runs **with no change to the site** - because each
  run read the previous run's report, which the plugin had written into the docroot
  as a page.

  Measured before and after on the shipped docs corpus plus the shapes the filing
  names: **eleven broken links became zero**, with the one gated target reported in
  its own section. A deliberately dead prose link added afterwards is still
  reported, which is the check that matters on a change like this - a quieter audit
  and a blind one look identical from the count.

  Six faults, each a different kind of mistake:

  - **extraction now reads prose.** Fenced blocks, `<script>`, `<style>`, indented
    examples and inline code spans come out before anything is matched. The docs the
    engine ships into every docroot are precisely the pages full of example markup,
    so `body.innerHTML = BUILD[listId](key);` was being reported as a broken link to
    `/key` on every site that ran the plugin.
  - **a relative link resolves against the page it is on.** `key` on
    `/manager/handlers` is `manager/key`, not `/key` - a path nobody ever wrote.
  - **a system page goes through the fallback chain.** `/login` is not broken when
    the engine default exists; the shipped check asserts it answers 200, and the
    audit was contradicting it on the same site at the same moment.
  - **withheld is its own state, not a broken link** (ruled 2026-09-30). A target
    found in the private store is reported separately, and the section says the audit
    **declined to judge** it. The audit stays anonymous deliberately: resolving as
    the operator would put the paths of pages a reader cannot see into a report that
    reader can fetch.
  - **the report is a store, not a page.** `lazysite/audit/link-report.json`, under
    the directory the page walks already skip, so the audit cannot find it however
    the extractor changes. The findings come back in the action's own result.
  - **and it opens in a modal with a Refresh**, replacing a static card that was
    filled by fetching a URL and had no way to re-run the audit from where you were
    reading it. The page every site already has is deleted on the next run.

  Also fixed: the two genuinely dead `/docs/views` links the filing found in shipped
  documentation, and the third in `views.md`'s own see-also list that the audit did
  not report. One of them read "Layouts and themes" and pointed somewhere else
  entirely.

- SM920 (018b634f) **one name for the thing being activated.** `theme-activate` and
  `layout-activate` each declared two parameters for the same argument, and `path`
  **took precedence over** `theme`/`layout`. A live site sent
  `path=odcc&theme=odcc-b`, was answered `ok:true`, and went on serving the old
  theme - because the generic parameter named the directory and the specific one
  named the theme. Sending both is the natural thing to do when a reference lists
  both.

  Ruled 2026-09-30 on the prior question - *"why do we have the option of both?"* -
  and there was no reason: SM261 added the specific spelling and never retired the
  generic one, so the pair was residue. **`path` is retired for these two actions**,
  with no deprecation window, as SM903 did for `theme-rename` four days earlier; the
  channel ladder is the mitigation. Breaking for a token client that sends `path=`.

  Everything in the measured scope moved with it, including **our own Appearance
  page**, which was a `path=` caller in three places. The SM247 refusal for an empty
  name said *"the theme name goes in the `path` parameter"* - it names `theme` now,
  because a refusal that sends a caller back to the retired parameter is worse than
  no refusal. `layout-delete` is untouched: its pair has the opposite precedence and
  is its own question.
- SM924 (80cec083) **deleting a submission is a grant of its own, off by default.** A
  partner account could read every submission on a site and delete none of them:
  submission delete was interactive-only, so the rows an agent's own test
  submissions left behind could be cleared only by a person.

  **The filing's own recommendation was measured false before anything was built.**
  It said the row "already records enough to know" who created a submission. It does
  not: a stored submission carries **no actor at all**, deliberately - a forged
  `_auth_user` had been reaching the actor column of the audit trail - and `_ip` is
  the front proxy's address, identical on every row of every site behind it
  ([[SM929]]). So "delete rows the caller created" has nothing to key on.

  `delete_submissions` therefore gates on the grant, and **is named for what it
  permits: deleting ANY submission on the site.** The title, the grants line and the
  Groups grid all say so, because an operator who grants it on the softer reading has
  granted the harder thing. It is off by default - no group holds it after an
  upgrade, and the interactive path is unchanged. SM214's argument against exposing
  the delete now sets that default rather than closing the door.

  No MCP twin, recorded as a decision rather than left as a gap: the ruling asked for
  a grant, not a second surface for deleting personal data. The gate ledger moves
  from 104/54 to 106/52 - the first change that takes actions **out** of the
  cookie-only set.

- SM923 (80cec083) **a 31-field form can reach a data table without abbreviating its
  column names.** The table handler's field map was capped at 500 characters, the
  generic bound every handler conf value carries. At 31 fields that is about sixteen
  characters per `field=column` pair, so the column names had to be shortened until
  they stopped matching the field names on the form - and whoever read the table
  later had to hold the mapping in their head.

  The cap is **per field** now (`max_len`, default 500) and the map's is 4,000, which
  carries any realistic form while still bounding the conf value. The refusal names
  the limit it actually applied; it said 500 while a different number was in force.

  **THE RULING OF 2026-09-30 WAS AMENDED ON MEASUREMENT.** It was to default the map
  to identity, which makes it optional. Measuring what reaches a handler showed why
  that cannot be: `_visible_fields` strips only `_`-prefixed keys, so every other key
  a visitor posts arrives - including keys the form never declared - and the map is
  what drops them. Under an identity default, a posted key matching any column of the
  bound table would write it. The schema note says in those words that the map is
  "what keeps a visitor from choosing where their data goes", and that is literally
  true, so the cap gave way instead. What the amendment does not deliver, plainly: a
  short form's map is not empty, because the map is still required.

  The filing's other half - a **section construct** for a long form - is still filed
  and still not built. A grammar rule is documented, tested and supported forever,
  and none of the three candidate shapes should be chosen on one report.
- SM929 (d9339046) **one definition of the request address, and the one reader that
  consulted the forwarded header stops believing it.** Behind a front proxy every
  address the engine recorded was the PROXY's - the same value for every visitor a
  site would ever have. That is how this was found: nine stored enquiries on a
  customer site, from six unrelated spam campaigns and two organisations, every one
  recording `10.2.30.177`.

  **Forty-four reads across nine files**, surveyed rather than assumed: ten drove a
  decision and thirty-three went on the record. The two rate limits (login, form)
  shared one bucket between every visitor; the **bad-URL auto-blocker**, enabled by
  default at ten bad URLs an hour, wrote that shared address into its block list,
  after which it denied every request from everybody to that site. The daily
  "distinct visitors" count hashed the proxy once a day however many people called.

  **And `client_ip` was forgeable, which was measured before anything was built.** A
  probe page on a live site rendered this caller's real public address on an ordinary
  request - and `203.0.113.7` when the same request carried
  `X-Forwarded-For: 203.0.113.7`. A visitor chose what the engine believed, so
  unifying removed an untrusted read as well as adding a trusted one.

  **THE FILING'S OWN RECOMMENDATION WAS CORRECTED BY THAT MEASUREMENT.** It asked for
  the FIRST hop of `X-Forwarded-For`, which is right for a proxy that *replaces* the
  header and wrong for one that *appends*: a caller-supplied value then arrives ahead
  of the true one, and the first hop is the forged one. The rule built instead:
  `REMOTE_ADDR` unless it is a trusted proxy, and then the **rightmost** hop that a
  trusted peer did not contribute; a hop that will not parse ends the walk rather
  than being stepped over, because stepping over it moves further into the part of
  the chain the caller controls.

  The trust basis is `trusted_proxies`, a named list in site settings on the Config
  page - **not** `auth_proxy_trusted`, which was read before it was ruled out: that
  is a boolean about `X-Remote-*` auth headers with no hop check at all ([[SM794]]),
  and making it mean "and also believe this address" would put two unrelated trust
  decisions behind one switch. Absent or empty means the private ranges, because the
  field ships empty and pressing Save writes empty - reading that as "trust nothing"
  would have disabled the feature for anyone who merely saved the page. `none` is the
  way to say no. A `/0` range is refused: a trust set matching every caller is the
  fault being fixed.

  **With no forwarded header every one of the forty-four reads returns exactly what
  it returned before**, which is what made a change in forty-four places safe to make
  at once. Five reads deliberately stay on `REMOTE_ADDR` - the no-password account
  gate and the four plaintext-transport gates - because they ask whether the PEER is
  this machine, not who the visitor is; `t/lint/206` holds the ledger of all five
  with the reason for each, and asserts the peer value is what the peer question is
  asked of, after a sabotage showed that counting the reads alone let the DAV gate
  change meaning unnoticed.

  The shipped nginx proxy templates now send `X-Forwarded-For` (they set only `Host`
  before, so a correctly-fronted site had nothing for the engine to read) and every
  Hestia template's revision moves to `2026-10-01`, which is how the rollout table
  reports a site that still needs its vhost rebuilt. `lazysite-check` names a
  `trusted_proxies` entry it cannot parse. UPGRADE.md states both operator steps and
  says plainly that a site behind a proxy will start recording real visitor
  addresses where it recorded one private constant before.

  ADR 0001 keeps the render path module-free, so the processor carries a pinned copy
  and `t/lint/205` holds the two identical, clause by clause. `t/lint/39` caught the
  first version of that copy: the private-range default was a file-scoped `our`
  BELOW the main body, which is empty when a request is served - it is a sub in both.
  Thirteen sabotages, thirteen refusals.

- SM921 (28a90671) **a `tel` field validates something now, and a pattern a browser
  cannot compile is refused where an author will see it.** BEHAVIOUR CHANGE WORTH
  READING BEFORE UPGRADING: the shipped default pattern for a `tel` field becomes
  `[0-9\s\(\)\+\.\-]{6,30}`, and on a site whose visitors have been typing free text
  into a phone field that field will start rejecting letters. That is the intent -
  the previous default rejected nothing at all - but it is a change on a live form
  rather than purely a silent repair, so it is named here rather than left to be
  discovered.

  An owner typed the single letter **S** into their phone field and was allowed.
  `[\d\s()+.-]{6,20}` is a valid Perl regex and an invalid HTML pattern: a browser
  compiles the attribute as `new RegExp("^(?:"+pattern+")$","v")`, and under the `v`
  flag a bare `(`, `)` or a hyphen at the end of a character class is a syntax error.
  The specification's answer to a pattern that will not compile is to **ignore the
  attribute in full** - so the field was not loosely validated, it was unvalidated,
  and nothing reached the author to say so. Re-measured here against node 20's own
  `v` flag rather than taken from the report: the old default is uncompilable, the
  new one compiles, rejects "S" and accepts `+33 (0) 1 89 48 00 40` - 21 characters,
  which is also why the bound moved from 20 to 30.

  **An author's own `pattern:` now takes the rest of the line**, as `select:`,
  `radio:` and `checklist:` do, so put it last among a field's rules. It was
  tokenised on whitespace, so `pattern:[0-9 ()+.-]{6,30}` rendered `pattern="[0-9"` -
  a valid regex, so nothing was ignored and nothing was reported, and the field
  refused almost every value. Measured before changing it: of the 16 form-field lines
  carrying a `pattern:` rule in the shipped tree and the live sites repo, none has
  another rule after it. The quoted form `pattern:"…"` is unchanged and is what to
  use when a pattern cannot go last.

  **An uncompilable pattern is now refused where somebody is looking.**
  `Lazysite::Validate::html_pattern_problem` is the one definition of which shapes
  the `v` flag refuses; `validate_page` turns it into an ISSUE, so a page carrying
  one is invalid while the author is writing it, and `lazysite check` reports the
  ones already published - which includes every site with a `tel` field, since the
  engine's own default was one of them. `t/lint/204` holds the character list to a
  single file and asserts both callers reach it; `t/unit/lib/63` cross-checks all 43
  verdicts against node where node is present, because the list cannot be derived by
  reading the specification carefully enough - the filing's own list missed `/` and
  `|`, and `~ ! # &` look equally reserved and compile fine. **The render path is
  unchanged**, deliberately: a render-time refusal would put an error where a form
  used to be, on upgrade, on exactly the sites this is about.

- SM928 (4d270ff3) **a submission notice can carry the submission, and only if the
  form asks.** Defects 2 and 3, which closes the filing.

  Defect 2: the notifier received the form's NAME and nothing else, so the
  documented override at `lazysite/notify-templates/submission.xmpp.tt` could
  restyle seven variables that did not include a single submitted field - a real
  extension point, reached, that could not express the one thing an operator wanted
  from it. The fields cross the call now as STRUCTURE (`[{ name, label, value,
  truncated }]`), not as a formatted block, because the formatting belongs in a
  template and that is the whole reason they have to arrive as values.
  `Lazysite::Notify` derives `fields_text` from them for the built-in renderer,
  which has no loop, and a site template gets real Template Toolkit and can
  `[% FOREACH f IN fields %]`.

  Defect 3: a multi-line default body, now that defect 1 made one possible and
  defect 2 gave it something to say.

  `notify:` BECOMES THREE STATES - `on` (the default, and absent), `full`, `off` -
  and `full` is the opt-in the ruling requires. A form that has not asked emits
  **byte-for-byte** what it emitted before, which the first assertion in
  `t/unit/lib/59` pins as a negative rather than inferring from the positive
  passing. An unrecognised value is NAMED in the log rather than silently treated
  as `on`, because `notify: fll` failing quietly to the old behaviour is how an
  operator concludes a feature does not work.

  Field handling, per the filing: an empty optional field is omitted rather than
  printed with nothing after it; a long value is truncated with a `[...]` marker and
  the link carries the rest; an uploaded file contributes its NAME, never its bytes;
  labels are not padded into columns, because most chat clients set text
  proportionally and padding arrives ragged.

  THE LABELS ARE HUMANISED FIELD NAMES AND THAT IS A RECORDED COMPROMISE. The form
  DEFINITION holds `Your name *` and lives in the page's `:::form` block, which the
  processor parses and the handler never sees - a form's `.conf` carries targets and
  upload limits, not fields. So `name` becomes `Name`. Real labels need the handler
  to read the form definition, which is its own piece of work.

  TWO THINGS FOUND WHILE BUILDING IT. `_template`'s per-site override loop had
  always looked for `<type>.<endpoint>` before `default.<endpoint>`, but the
  BUILT-IN fallback only ever read `default.<endpoint>` - so a built-in per-type
  template could be added and silently never used. Nobody had noticed because every
  key in that hash was a `default.*` one. And a sabotage pass proved the newline
  strip is NOT load-bearing for the store's format: `encode_json` escapes a newline
  as `\n`, so the file stays one record per line with or without it. The strip stays
  (removing it would change what every site writes, which is a separate decision),
  the comment claiming it protected the format is corrected, and the test that looks
  like it gates the strip now says that it does not.

  Six sabotages: four refused, and two that were not were MY sabotage being
  imprecise - `'' || join(...)` is a no-op, and removing `$type.$endpoint` while
  leaving `$type.$endpoint.full` removed nothing that was used. Both refused once
  corrected.
- SM927 (555ac60e) **the XMPP configuration can be tested before anything real
  happens, and the test says which stage it reached.** `form-smtp` declares a
  `validate` action and the config page shows a "Validate SMTP connection" button.
  `notify-xmpp` declared no actions at all, so an operator who had just typed eight
  fields including a password had no way to learn whether any of it worked until an
  event fired - and this plugin's whole failure mode is that when one does fire,
  nothing tells them: a chat notice that never arrives looks exactly like a site
  where nothing has happened. On the site this was found on, nine enquiries
  accumulated over sixteen days with no delivery configured at all.

  THE STEP-BY-STEP IS THE POINT, not the pass/fail. The staging lives in
  `Lazysite::Notify` with the delivery it tests - `_xmpp_send` takes an optional
  collector and records `library`, `jid`, `endpoint`, `connect`, `auth`, `join` and
  `send` as it passes each - so the test exercises the delivery path itself rather
  than a second implementation that agrees with it until the release where it stops.
  A bare failure sends an operator back through all eight fields; a named stage
  sends them to one of them.

  THE THREE DEFECTS FILED ON 2026-09-30 ARE EACH NOW ONE PRESS. [[SM925]] X1
  (`Net::XMPP` not installed) is a `library` stage naming the Debian package rather
  than Perl's `@INC` paragraph. X2 (port 5222 asserted over an SRV record giving
  47594) is an `endpoint` stage that says WHERE the endpoint came from: *as
  configured*, *from the domain's SRV record*, or *nothing else was published* for a
  defaulted 5222 - the distinction the operator could not see. [[SM926]] (a body
  carrying `${REQUEST_SCHEME}://${SERVER_NAME}`) because the rendered body is
  returned and SHOWN, through the same template path a real notice uses, so a site's
  own `default.xmpp` override is tested too. That defect was invisible for a whole
  afternoon and became obvious the moment a human read a payload.

  WHAT THE TEST DOES NOT DO: write a bell row. The reporter's only available test was
  a real form submission, which left a stored row only a person can delete
  ([[SM924]]) and only exercised this path at all if it escaped the spam quarantine
  ([[SM216]]). The body announces itself as a **test** and says nothing needs doing,
  because the recipient is often a room a team shares and a test that reads like an
  alert teaches people to ignore alerts. A group chat join is reported as *sent, not
  confirmed*: this path sends a join presence and reads nothing back, so a room that
  refuses one answers nowhere this code looks, and calling that a success would be
  the four-state fault in miniature.

  X3's four config states now reach the OPERATOR as well as the log. `_xmpp_conf`
  became `_xmpp_conf_or_why`, returning the config and the reason there is none -
  renamed deliberately, because `return ( undef, $why )` in scalar context yields
  the reason, which is true, so a call site left un-updated would have sent with it;
  a rename makes that a compile failure instead.

  Also fixed here, found while building: X2's SRV lookup had made
  `t/unit/lib/26` issue five REAL DNS queries per run from the unit suite. The
  resolver is stubbed there now - which also makes "the port defaults to 5222" a fact
  about this code rather than about the public DNS - and a new case asserts the
  resolved endpoint reaches `Connect`, not only `_xmpp_endpoint`. Twelve sabotages,
  twelve refusals.

  Docs: `starter/docs/forms.md` gains the test section and corrects the `port`
  line X2 made wrong (blank now means the SRV record, not 5222);
  `docs/MANUAL-CHECKS.md` puts the button before the submission pass in the delivery
  check; `docs/FEATURES.md` names the action. The filing's wider question - whether
  ANY plugin holding credentials for a remote endpoint should be REQUIRED to declare
  a test action, which would make the absence a lint - stays open, because the
  population has not been counted.

- SM925 (29c7432a) **X2: the XMPP endpoint comes from the domain's SRV record, which
  closes the filing.** An operator configured a valid account on a live site and
  could not connect: the port had defaulted to 5222 while the account's own domain
  answered `10 0 47594 xmpp.project.im.` - a different host AND a different port,
  neither unusual, since SRV exists so a client endpoint need not be the JID's
  domain. They ran that lookup by hand and transcribed two values the code could
  have resolved itself.

  IT IS A REGRESSION, NOT A MISSING FEATURE, which is why it is twenty lines rather
  than a design. `notify-xmpp`'s own header says delivery is *"based on the xmpp-lite
  connector"*. `XMPP::Lite` resolves SRV and tracks whether the port was explicit;
  this flow was derived from it **without those two clauses**. Measured 2026-10-01
  against the live record: `XMPP::Lite::_resolve_srv` returns
  `xmpp.project.im 47594`, `dig` agrees, and the notification hook on this host has
  been delivering through that path all along. The question the filing left open -
  whether `Net::XMPP` resolves SRV itself - turned out not to need answering: the
  behaviour already existed in this project's own library and had been dropped in
  the copy.

  THE RULE IS THE OPERATOR'S AND IT IS STRICTER THAN `XMPP::Lite`'s: *"either let SRV
  do its job or specify"*. SRV is consulted only when NEITHER host nor port is
  given; a conf naming either is obeyed exactly and nothing is looked up.
  `XMPP::Lite` tracks only whether the PORT was explicit, so it will replace a host
  the operator did set - and a host somebody typed is a specification. A blank or
  non-numeric port is not one.

  Two things this does that `XMPP::Lite` does not, both cheap: a **tight resolver
  timeout**, because this runs in a CGI and the 15-second alarm around the send is
  the whole budget for DNS and the connection - so the lookup sits INSIDE that
  window rather than before it; and an SRV target of `.` is **refused**, because RFC
  2782 says that means the service is decidedly not available at this domain, and
  treating it as a hostname turns an explicit "no" into a connection attempt against
  nonsense.

  THE DESCRIPTOR LOSES `default => '5222'`. The form pre-filled it, so an operator
  who never touched the field had silently asserted a port - and asserted it wrongly
  for every server publishing something else. Both notes now say that blank means
  "use the SRV record". `Net::DNS` is declared alongside `Net::XMPP`, because X2's
  own repair landing without its dependency declared would be X1 happening a second
  time inside the same filing.

  THE ENDPOINT DECISION GOT A NAME, and the test is why. The first version of
  `t/unit/lib/61` could only observe the choice by attempting a connection and
  reading the host out of the failure message - which reached the real server and
  failed at auth. A unit test making a live network call is a defect in the code's
  shape, not the test's: `_xmpp_endpoint` exists now, and the test calls it with
  `$SRV_RESOLVER` swapped, the way `$XMPP_SENDER` already was.

  Seven sabotages. Six refused; the seventh exposed a real limit in `t/lint/201`,
  which requires a plugin naming a Debian package to declare SOMETHING and cannot
  know WHICH modules it needs - so removing `Net::DNS` left `Net::XMPP` and passed.
  The assertion that notices now sits in `t/unit/lib/61` beside the code that made
  the dependency load-bearing, and it refuses that sabotage.
- SM926 (a43cab2d) **one definition of the host a request is for, so a page and a
  notification cannot disagree about what host the site is on.** The ruling of
  2026-10-01: the presented host is the host - a division of responsibility rather
  than a trust level. The engine uses the hostname it was given, restricting what
  may be presented is the front end's job, and a site that wants it fixed pins it.

  There were TWO definitions. `_request_host()` read `HTTP_HOST` and chose which
  alias host's config a request got; interpolation read whatever
  `$ENV{SERVER_NAME}` held - which under Apache's `UseCanonicalName` default of
  **Off** is the Host header and under **On** is the configured `ServerName`. So the
  engine's own idea of its address was conditional on a vhost setting none of the
  four shipped examples sets, and the two could differ on the same request.
  `${SERVER_NAME}` now resolves through the request host in both copies, falling
  back to `$ENV{SERVER_NAME}` only when no usable Host header was presented - a CLI
  run, or a client that sent something that is not a hostname.

  VALIDATION IS HYGIENE, NOT TRUST, and the distinction is the reason it stays: this
  value reaches the per-host page cache's FILENAMES as well as URLs, so only a
  lowercased, port-stripped, dot-stripped, DNS-shaped name of at most 253 bytes is
  accepted and anything else reads as absent. `t/unit/lib/60` drives five malformed
  hosts through it, including a traversal attempt, and asserts the configured name
  stands in each case.

  `env_interpolation_complete` had to move to the same resolver, which is a bug this
  change would otherwise have introduced: with a Host header and no `SERVER_NAME`,
  interpolation succeeds, so a completeness check reading `%ENV` directly would have
  called it unresolvable and SM926's own "no request context" branch would have
  fired on a request that had one - emitting a relative path where the absolute one
  was available.

  NO NEW CONFIG KEY, because the pin already existed: a literal
  `site_url: https://example.com` has no `${...}` to expand and is left alone, which
  `t/unit/lib/58` already asserted before this ruling was taken. What still does not
  exist is pinning the HOST while leaving the scheme dynamic - a smaller question,
  not assumed here. `UseCanonicalName On` was declined: it would fix `SERVER_NAME`
  to the primary `ServerName`, so an alias host not overriding `site_url` would put
  the PRIMARY host into its own links, breaking the multi-host and language-set
  sites the alias mechanism exists for.

  ADR 0001 keeps the render path module-free, so the processor carries its own copy
  of both subs and `t/lint/203` pins them equivalent BODY FOR BODY, not merely
  clause by clause - the arrangement lint 198 makes for `_cannot_read` and 202 for
  the allowlist. Eight sabotages, eight refusals. SM110's whitelist of what a Host
  header may select is unchanged: a security-relevant key still may not vary per
  host.

- SM932 (b1556284) **a diagnostic now reaches a second sink, because the first one
  was never verifiable.** `log_event`'s only unconditional sink was
  `print STDERR`, and whether a CGI's STDERR reaches a log anybody can read is
  the web server's decision rather than the engine's. On an nginx -> Apache ->
  `proxy_fcgi` install it reaches nothing: an operator debugging a live site
  grepped `error_log` through four failing submissions and found no line, while
  the same code from a terminal printed the cause immediately. An hour went into
  eliminating six gates on the strength of an absence that meant nothing. That
  lands on what 0.15.0 and 0.15.1 were largely about - SM906, SM907, SM917 and
  SM918 all deliver through a WARN - so the diagnostic half of two releases was
  being written to a place the operator might not have.

  Ruled 2026-09-30: **`forward_diagnostics` is on by default, at WARN and above.**
  It becomes a LEVEL rather than a boolean - blank (the default) forwards WARN and
  above, `off` forwards nothing, a level name forwards that level and above, and
  `on` forwards every level, which is exactly what an install that already set it
  was getting. So no configured site changes behaviour; only a site that never
  found the key moves, and it moves from nothing to WARN and above.

  WARN is the threshold because it was measured rather than preferred:
  `cannot_read` logs at WARN, so WARN-and-above carries every repair the
  four-state work produced, and forwarding nothing new at INFO means no install's
  syslog volume changes on upgrade. The threshold lives in `forward_line`, not in
  `log_event`, because four plugins carry their own `log_event` copy and call
  straight into it - one gate, five callers.

  The second half is the defect in the forwarding path itself: `_forward_conf`
  read `lazysite.conf` with no else branch, so a conf the process could not open
  silently left forwarding off - the four-state shape SM917 swept out of the store
  readers, in the one place it could not be fixed the same way, because
  `cannot_read` reports through `log_event` and `log_event` arrives here. It now
  captures `$!` and reports after `%FWD` is built, behind its own
  once-per-process latch. An unrecognised value is named too, rather than
  silently coerced.

  The `forward_diagnostics` descriptor loses its `default` key: a pre-filled value
  makes the form assert a setting the operator never chose, which is the SM925 X2
  trap where `default => '5222'` overruled the SRV record on every site whose
  operator left the field alone. `forward_audit` is untouched - a plain on/off,
  still off by default, since it copies an access record rather than a diagnostic.

  WHAT THIS DOES NOT DO, and it is deliberate: syslog is the host operator's log,
  not the site's. The manager still shows nothing and an agent still cannot read
  the engine's diagnostics, which was the actual gap. The engine-owned diagnostic
  log is deferred rather than refused, and the fleet measurement (OP-29) is what
  should decide whether it is still wanted now there are two sinks. A
  `lazysite check` that verifies reachability is worth MORE after this, not less -
  two sinks means two things that can each fail quietly - and is not built.

  `t/unit/lib/56` pins all seven states, `t/unit/forms/12` gains the case where a
  conf that says nothing still forwards a plugin's ERROR, and its old "forwarding
  off" case now spells `off` explicitly instead of relying on absence. Seven
  sabotages, seven refusals.
- SM915 (64fd8795) **enabling one extension no longer writes a second list, and the
  manager nav stops hiding extensions that are enabled.** SM817 renamed this list
  from `plugins:` to `extensions:` and said in the comment that has stood ever
  since that both spellings open the SAME list, so "a site cannot end up with two
  lists that disagree about what is enabled". Six places in the tree match a list
  header. Four honoured that. Two did not.

  THE WRITER WAS THE SERIOUS ONE. `_update_plugins_conf` matched `plugins:` alone,
  so on a site using the newer name the header and every one of its entries fell
  through to the preserved lines, `@plugins` came out empty, and the rebuild
  emitted a SECOND list under the old spelling carrying only the script just
  added. Enabling one extension gave the conf two lists; the reader that merges
  both then saw everything while the others saw one block and read the rest as
  disabled. Disable was worse in a quieter way - the entry was not in a list the
  writer could see, so `grep` removed nothing, the conf was rewritten unchanged,
  and the result was reported `ok`. Reproduced before the fix in
  `tmp/sm915-repro.pl`: on an `extensions:` site, enable produced 2 lists and
  disable answered ok=1 having removed nothing.

  Ruled 2026-09-29: **write back the header the site already uses, and refuse when
  both are present, naming the file.** The writer now records which spelling it
  found and rebuilds under that one. A conf carrying both is handed back with the
  path and what to do about it, and nothing is written - merging would edit a list
  the operator did not ask to be edited in that call, which is the same shape as
  the defect, and leaving it silent is the state that was reported. A site with no
  list at all gets `extensions:`, the current name, rather than reviving the
  retired spelling on a site that never had it.

  THE READER was `_enabled_plugins` in the processor, which feeds the conditional
  manager nav - so on an `extensions:` site the nav hid entries for extensions
  that were in fact enabled. Its sibling in the same file, `_unit_enabled`, had it
  right all along, which is the clearest statement of what this defect is: not one
  bug but one judgement written down six times and drifting.

  `t/lint/200` is the gate against a seventh copy: every regex anchored on a list
  header must name both spellings, with a floor so a census that finds nothing
  cannot pass. `t/unit/manager/198` holds the writer's behaviour on BOTH spellings,
  because a `plugins:` site worked all along and a test exercising only the broken
  one cannot tell a fix from a swap of which spelling is broken. Seven sabotages,
  seven refusals.

  ONE ASSERTION CHANGED RATHER THAN BEING WORKED AROUND: `t/unit/lib/07` expected a
  new list under `plugins:`, which was right only while the writer hardcoded it.
  Its fixture has no list, so it now expects `extensions:` and asserts the old
  spelling is absent, so it cannot pass on either indifferently.

  WHAT WAS ALREADY KNOWN AND IS NOW MEASURED: the filing's own table listed four
  sites and its status-note said three readers remained. Both were wrong. The
  population is six - `install.pl:945` and the processor's `_unit_enabled` were
  never in the table and were always correct - and what remained was one reader
  and the writer. The count is in the filing now.

  THE LIVE CONSEQUENCE THIS CLOSES: XMPP notice delivery had been silently off on
  every site using the newer spelling since SM817. The `Notify` half of that
  shipped in 0.15.1 under SM485, because the email endpoint could not be reached
  without it; this is the rest.
- SM925 (c32f96ed) **X1 and X3: the notification path refuses to enable without the
  module it needs, and says why it sent nothing.** An operator enabled
  `notify-xmpp` on a live site, configured eight fields including a password, and
  got nothing for four submissions. Three faults composed; two are fixed here and
  X2 is not (see below).

  X1: the plugin declared no `owns` block at all, so `_missing_deps` - which the
  enable path has called since ADR 0009, and which two sibling plugins use -
  returned before checking anything. It now declares `Net::XMPP`. The fact had been
  written down nine lines above, in prose, where the machinery could not see it.

  X3: `plugins/form-handler.pl` wrapped the notify call in an `eval` and never read
  `$@`. The `require` is inside that eval, so X1's error - `Can't locate
  Net/XMPP.pm in @INC` - was raised on every submission and dropped: the one
  sentence that would have ended the afternoon in its first minute was produced and
  thrown away, and the fall-through to the bell made the failure look like success.
  It now reports and still falls through, because a notice must never be lost to a
  broken delivery path. And `Lazysite::Notify::_xmpp_conf` returned `undef` for FOUR
  distinct causes in silence - the extension off, no conf, a conf that will not
  open, a conf missing a required key. Only the first is a deliberate state; the
  other three now say which, and the missing-key case names the key. That is the
  four-state rule SM906, SM907 and SM917 applied to the stores, arriving on the
  notification path.

  TWO DETECTORS WERE BUILT FOR THE AUDIT THE REPORT ASKED FOR AND BOTH WERE WRONG,
  which is why the gate that shipped is narrow. A sweep of `plugins/` for an
  undeclared `require` flagged two other plugins and MISSED notify-xmpp entirely -
  the `require Net::XMPP` is not in the plugin at all, it is in
  `Lazysite::Notify:585`, and the plugin is a descriptor. A second version flagged
  any `Foo::Bar` name in prose and failed 12 of 16 plugins on `Cwd::abs_path`,
  `JSON::PP::true` and `Digest::SHA::sha256_hex` - fully-qualified CALLS - and on a
  comment this very filing had just added. `t/lint/201` keeps only the signature
  that is never incidental: a Debian Perl package name (`libnet-xmpp-perl`) appears
  when somebody is telling an operator what to install, which is exactly when the
  enable path should have been told too. Two plugins carry one; before this build,
  one of the two declared nothing.

  The audit's real finding is recorded rather than acted on: 10 of 16 plugins have
  no `owns` block, and of the modules they reach for, `form-smtp`'s `Net::SMTP` is
  loaded only when `method=smtp` (declaring it would wrongly refuse a sendmail-only
  site) and `form-handler`'s `DB_File` is a top-level `use`, so the plugin cannot
  compile without it and `--describe` fails before any dep check can run. Neither is
  a missing declaration; the second is a hole in the mechanism and is named in the
  filing.

  X2 IS NOT BUILT. The port defaulting to 5222 over an SRV record giving 47594 needs
  one thing established first: whether `Net::XMPP` already resolves SRV when handed
  a bare domain. If it does, the repair is to stop overriding it rather than to add
  a resolver - and if it does not, `Net::DNS` is not core, so X2's own fix needs a
  dependency declaration, which is X1's mechanism. `t/unit/lib/57` and
  `t/unit/manager/…` cover what shipped; seven sabotages, seven refusals.
- SM926 + SM928 (924c520b) **a notification's link is a link, and its body keeps its
  newlines.** These land together because the link is built from the variable the
  other defect flattened.

  SM926: `site_url` holds `${REQUEST_SCHEME}://${SERVER_NAME}` on every site
  `install.pl` or `TestHelper` creates - one config that works on any domain, and a
  value that means nothing until somebody expands it. THREE pieces of the engine
  read that key. The processor expanded it against a reviewed allowlist;
  `tools/lazysite-users.pl` hand-rolled two of the same variables with a comment
  explaining why it had to; `Lazysite::Notify` had a seven-line reader that returned
  the raw line - so the first XMPP notification to reach a live site carried
  `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins` as its link. The allowlist
  now lives in `Lazysite::Util`, Notify uses it, and `t/lint/202` pins the
  processor's own copy identical variable-for-variable (the render path is
  module-free, ADR 0001, so it keeps a copy - the arrangement lint 198 makes for
  `_cannot_read`).

  A NOTIFICATION HAS A CASE NEITHER OTHER READER HAS: no request context at all. A
  cron- or CLI-driven notice has no `SERVER_NAME`, so interpolation correctly yields
  `://` - and emitting that is worse than emitting nothing, because it looks like a
  link. When the expansion cannot complete the base is empty and the template's
  `[% base %]/manager/...` degrades to an absolute PATH, which a reader can still
  use. `base_url` remains the deliberate override and is NOT the fix, ruled
  2026-09-30: `site_url` is the single source of truth and a second place to write
  the site's own address goes stale in silence.

  `_conf_value` also stopped collapsing "no lazysite.conf" and "a lazysite.conf that
  will not open" into `''` - the second now reports through `cannot_read`.

  SM928 defect 1: the newline strip before the `notices.jsonl` append also fed
  `%vars`, so a multi-line body was flattened for EVERY endpoint and template. The
  strip was right about the store - `encode_json` escapes a newline as `\n`, so the
  format was never at risk, but one record per line is the store's contract - and
  wrong about the templates. `%vars` is built from the original now; the stored copy
  is still flattened, and `t/unit/lib/58` asserts both.

  SM928 defect 4: `url` pointed at `/manager/plugins`, the Extension Manager, which
  has nothing to do with a submission. The Submissions buttons are on the Handlers
  page, so that is where it points. A deep link to THIS form's store needs the store
  path, which only the handler that stored it knows, so it waits for defect 2.

  AN OPEN QUESTION THIS BUILD ADVANCED AND DID NOT CLOSE. SM926 asked whether
  `_site_base_url`'s `HTTP_HOST` fallback is reachable, because consolidating the
  three readers has to pick one answer about which host variable is trusted. Half is
  settled: `_claim_url` IS reachable from a CGI-invoked `--api` action
  (`account-approve`, and `users_tool_api` inherits `%ENV`). The other half is worse
  than the filing supposed - the processor's comment says HTTP_HOST is excluded
  because it is request-supplied and SERVER_NAME should be used instead, but
  Apache's `UseCanonicalName` defaults to **Off**, under which SERVER_NAME is taken
  from the Host header, and NONE of the four shipped vhost examples sets it On. So
  excluding one while permitting the other buys nothing on a default install. That
  needs a ruling (a vhost default, or a policy) and `tools/lazysite-users.pl` is
  deliberately left alone until it has one. Seven sabotages, seven refusals.

## 0.15.1 - EDGE: a file that will not open stops reading as one with nothing in it, and a row's controls stay with the row (2026-09-30)

- SM919 (98fccca0) **a row's tick box and its Delete button no longer sit at
  opposite ends of the data.** Reported from the live manager. A submissions table
  has one column per form field, so it scrolls sideways - and the tick box was the
  FIRST cell with Delete the LAST, every data column between them, so an operator
  could reach one or the other and selecting a row then deleting it meant crossing
  the table and coming back. Both are PINNED now: tick box to the left edge,
  actions to the right, data scrolling between them. Pinned rather than moved out
  of the table on purpose - an actions strip rendered alongside has to keep its own
  row heights in step with cells that wrap, and a drift of one row aims Delete at
  the wrong submission; pinning leaves the browser's own row association intact.
  Pure CSS in all three manager themes, added by one script so they cannot drift,
  and hover is deliberately not restated because the existing rule out-specifies
  these and still wins. **The window is 90vw by 90vh FIXED**, replacing
  `width:92%; max-width:1000px; max-height:86vh` - the cap wasted a wide screen and
  created scrolling that need not have existed, and a max-height with no height
  sized the box to its contents so every form opened differently and the scroll
  region moved between visits. **AND THE STYLE GUIDE CAN SHOW IT NOW:** its
  `mg-submissions-table` demo was a table with ONE CELL, so the class was
  registered, `t/lint/96` passed, and the only state that matters - wide enough to
  scroll, with pinned ends - was absent from the page whose whole purpose is to
  show what a diff cannot. It has eight columns and two rows of test content now,
  one quarantined.

- SM917 step 3 (f6bccc25) **a read that names a store obeys the store rule wherever
  it lives - and G2 was two readers, not twenty.** `t/lint/121` gains a check that
  asks about the PATH rather than the file: any read-open whose path names a store
  directory must report, in every file, not only in ones a modules list happens to
  name. It needed the three spellings of the engine directory normalised first -
  it is written `"$LAZYSITE_DIR/auth/..."` or `_lz($DOCROOT) . "/logs/..."`, almost
  never the literal `lazysite/`, and the first version looked for the literal and
  matched NOTHING. A check that matches nothing passes for ever, which is this
  filing's own subject, so the count is asserted and not merely used. **THE
  PER-FILE LIST DOES NOT SCALE, measured and withdrawn the same day:** listing
  lazysite-processor.pl under `auth` put 61 read-opens under the store rule, of
  which ONE was an auth read and 23 were markdown, template and theme reads -
  ~38 `# not a store` markers in the render path to satisfy a rule about the auth
  store, and a marker that appears everywhere stops being a signal. The two checks
  now divide the work by what each can observe: the literal check for a read that
  NAMES a store, the modules list for one that reaches it through a helper, which
  is the case Connectors.pm proves is still needed. **AND THE SECOND CORRECTION TO
  MY OWN MEASUREMENT:** "20 (store, file) pairs unread in any idiom" counted files
  that MENTION a store directory - comments, error strings, paths built for writing
  - not unreported store reads. The real number is TWO, and both were the audit
  paths step 1 had already repaired. The first correction made this filing bigger;
  this one makes it smaller. Steps 4 and 5 of the ruled five are therefore EMPTY
  and deliberately not performed: `forms` and `logs` have no unreported store reads
  to triage, and two commits to match a plan would be theatre.

- SM917 step 2 (f551b6ce) **the store-reader lint sees the other idiom now, and
  twelve readers were triaged behind it.** `t/lint/121` gained the third shape:
  `if ( open ... ) { ... }` with no else, where the failure branch is the MISSING
  else and nothing runs when the open fails. Two decisions in the matcher are
  worth knowing. It accepts a following `unless ( $!{ENOENT} )` as the report,
  because that is the SM907 idiom the audit-trail reader already uses and a
  matcher demanding an `else` would have called correct code a defect. And it
  skips comments when looking for that branch, so writing the REASON between the
  brace and the else is not punished. **The twelve:** the site conf read five ways
  (an unreadable conf showed defaults as though they were the site's settings, and
  left `auth_proxy_trusted` reading false - which fails closed, but silently); the
  preview secret and the manager CSRF secret, where minting a second secret
  because the first would not open invalidates every token issued against it; the
  stats conf and the site-domain read, which decide whose log is whose; the
  pairing-key TTL; and three `-f` stat guards removed, which is subtest 3's rule
  as much as subtest 2's. **Two were losing data, not just information.** The
  visitor-trail export reads the day it is appending to, and an unreadable day
  left that list empty so the atomic write REPLACED the day with only the new rows
  - it now reports and skips the day, because the new rows can be re-collected and
  the history cannot. And `_ensure_conf_key`'s read is what makes the write
  idempotent, so an unreadable conf meant it could not see the key was already
  there and appended a second one - SM915's shape, one file over; it refuses now.
  ONE marker, on the audit-trail tail cursor: a derived cache where absent and
  unreadable both correctly mean recompute. Four sabotages, four caught.

- SM917 step 1 (0fe5b190) **two checks that reported a clean bill for a store they
  could not open.** The first of five commits under SM917's ruling (widen and fix
  all, no baseline, `auth` first). **MCP's `audit_site`** reported ACL keys that
  match nothing at the docroot, and an unreadable `auth/acls.json` left that list
  EMPTY - which renders as "your access rules are fine". It now carries
  `acl_keys_unreadable` naming the errno and saying in words that the empty list
  above means nothing was checked, not that nothing is wrong; absent still stays
  quiet, because a site with no ACLs has no unmatched keys either. **The
  processor's `_visitor_key`** fell back to a minted salt when `auth/.secret` was
  empty, which is correct for a secret-less site and was ALSO what happened when
  the secret existed and could not be read - so an unreadable secret silently
  re-keyed every visitor token, and the only symptom was returning visitors
  counting as new ones, which looks like traffic rather than a fault. ADR 0001
  keeps the render path module-free, so the processor gains its own `_cannot_read`
  rather than calling Util's, and `t/lint/198` holds the two copies to one
  decision: ENOENT returns before anything is logged, every return is undef, the
  path/errno/unix-user are all logged, the errno is captured before `getpwuid` can
  reset `$!`, and both log the same sentence. Ten sabotages across two scripts,
  ten caught - and two of them only after a first attempt failed to apply, which
  is why the scripts say so rather than reporting a pass.

- SM918 (0062449a) **an agent can read the bell, through the same reader the manager
  uses.** The notice store had a control-API read surface and no MCP twin, which
  `t/lint/23` carried as "undecided - an MCP twin wants per-notice addressing
  first". That addressing shipped with SM485, and the ruling was FULL PARITY WITH
  THE CAPABILITY AS THE GATE: `read_notices` over MCP takes the same
  `notifications` capability the control API's `notices` takes, so the two doors
  cannot disagree about who may read the bell. It deliberately does NOT filter by
  `to` - the control API does not either, and a stricter policy on one channel is
  two doors disagreeing about one capability, which is the defect SM652 fixed for
  submissions. ONE READER, not two: `Lazysite::Manager::Notices`, because SM915 is
  a week old and its lesson was four readers of one registry with one of them
  right. THE MOVE CARRIED A FOUR-STATE REPAIR - the old reader was `if ( open ...
  )` with no else, so a store that exists and cannot be opened read as an empty
  bell; it now reports `store_unreadable` and logs through `cannot_read`, and the
  seen-marker write refuses rather than rewriting a marker it could not read and
  discarding every other operator's position. `notices-seen` has no twin on
  purpose: a per-principal read cursor exists for a human's unread badge, an agent
  has no badge, and a cursor per partner is the first half of an inbox - notices
  stay simple, and machine-to-machine is SM646's XMPP connectors.
- SM917 (d556eca9) **filed, not built: the store-reader lint cannot see the other
  way to swallow a failed open, and does not read half the files.** `t/lint/121`
  refuses a reader that turns an unopenable store into an empty answer and has
  caught that three times, and TWO gaps let the defect SM918 repaired sit in front
  of it while it passed. **The idiom:** its matcher requires `or` on the open line,
  so `if ( open my $fh, '<', $path ) { ... }` with no else is invisible - 14 such
  read-opens against 42 it sees. **The modules list, which is the bigger one:**
  subtest 2 reads a file only if a store NAMES it in a hand-kept `modules` list, so
  20 (store, file) pairs are unread in any idiom, seven of them files that read
  `auth`. SM768's own "a lint that names the stores it protects protects the stores
  somebody remembered" applies one level down, and nobody had turned it there.
  Closing both brings 96 read-opens into scope needing a decision, 38 of them in
  the processor and 9 in the DAV path. FILED FIRST WITH THE WRONG NUMBERS, against
  subtest 1's file set instead of subtest 2's, and corrected the same day in the
  commit this row names - the correction made the finding larger, which is why it
  is recorded rather than quietly edited. Ruled: widen and fix all of it with no
  baseline, `auth` first, one store per commit.
- SM916 (55a9e7fc) **the perf gate's work counter was measuring the clock, and it
  refused a release for it.** `bench.pl` reports `work_cold_log_bytes` - the bytes
  the stats ingest reads from a fixture of thirty days of visitor logs - and
  treats any change as WORK, on the stated grounds that "a count is
  host-independent, so this is not a slow machine". The fixture's timestamps came
  from `Time::HiRes`, so they were FLOATS, and JSON renders a float to as many
  digits as it needs: the fixture's SIZE therefore depended on the wall clock, at
  exactly 4500 bytes per decimal digit across 4500 lines that all share one
  timestamp. The 0.15.0 baseline records 519892 and the commit it says it was
  captured at reproduces 524392, stably, twice - so the recorded number was never
  a property of that tree, and the gate was refusing roughly nine cuts in ten for
  a reason belonging to neither the code nor the host. The engine has always
  written an integer (`_access_record` builds `'{"t":' . time()` and the processor
  does not import `Time::HiRes`), so the fixture was not merely unstable but
  UNLIKE the log it stands in for - 5.4% of it was timestamp width rather than
  traffic. Fixed with `int()`, not with a tolerance, because `work_*` is the half
  of the gate that is meant to be exact. `t/lint/159` pins both halves of the
  agreement so neither side can drift alone.
- Four rulings recorded (63e5348e) **taken 2026-09-29, each written into the thing
  it decides rather than left in a conversation - and one of them did not survive
  its own condition.** **T3** (SM906): the control API gets a distinct *cannot
  tell* state, not an empty capability list, because the caller on that channel is
  a program and "I hold nothing" and "I could not read the store" must be
  different values - the four-state rule the engine already applies to its stores.
  The manager's wording goes in the message too. **SM915**: the extension-list
  writer writes back under the header the site already uses, and REFUSES when both
  are present, naming the file. Between those two rules nothing is silently wrong:
  an ordinary site keeps its spelling, and a damaged conf is handed to an operator
  rather than repaired behind their back. **SM276**: English only. Owning a
  translation set means owning its staleness and the question of a language nobody
  translated, which is the standing obligation this filing deferred for - and the
  per-site override makes it unnecessary. **TIER A - and this is the one worth
  reading.** The ruling was to retire A1 steps 5-7 and A2 *if* B4/B5 already
  covered that ground, since SM635's removal was followed through for them in the
  same document and A1/A2 look like leftovers. **Checked before deleting anything,
  and they do not.** B4 and B5 cover the DATA PATH - a draft section 404s and is
  absent from the sitemap; a scoped manager sees only sections in scope, whose
  filter is suite-covered. A1 and A2 are the only cover for the two TRANSITIONS,
  Publish and Remove protection, and Tier A exists for exactly that: *"each a
  control that writes or destroys where the data path is tested and the button
  wiring is not"*. Retiring them would have dropped the only check on two buttons
  that change who may read content. So they are REWRITTEN instead, against the
  furniture SM635 actually left - the controls moved onto the folder's own row and
  only onto the row that OWNS the rule, because an inherited rule cannot be
  removed from the row it covers. The rewrite is from the source rather than from
  a walk, and says so: its first run is also its first verification.
- SM217 (ee5f1973) **the Add form can make a domain a second name for an existing
  site, which closes the filing.** The engine half shipped `domain-alias-add` and
  the Domains list marks the result, but nothing on the page could invoke it - the
  action was reachable only over the API, which is not where an operator adds a
  domain. **It is an option, not a button.** A separate "Add alias" control would
  have been a second door to the same room: the Add form already asks where this
  domain's content lives, and "the same content as `<host>`" is one more answer to
  that question, so it sits in the picker that asks it, under *Share an existing
  site*. One form, two actions, chosen by that answer - every other field is the
  same on both paths, because the appearance and language of a second name are
  still that name's own. **Three things the form must not offer**, each enforced
  by the engine and each therefore a refusal rather than a visible bug if the page
  drifted: an alias sends no `content_root` (the action refuses one outright,
  rather than dropping it); an alias never offers `seed`, because seeding would
  write a starter page into the canonical domain's own content, and a checkbox
  that cannot do what it says is worse than none; and only a domain with a NAMED
  folder is offerable, since a rootless host serves the default site, which is
  already the first option in the same select - the same narrowing the row marker
  got, for the same reason. The preview names the folder being shared and says
  plainly that no folder is created and nothing is copied, and the success line
  says which of the two things happened rather than "Configured" for both.
  `t/lint/158`, five sabotages - **the first found a hole in the test itself**: it
  asserted `aliasOptionsHtml()`, which the function's own definition satisfies, so
  deleting the line that puts the options into the select changed nothing the test
  could see. It now asserts the call site. `t/lint/70` widened one pattern to
  match the new body shape, with its rule unchanged and still biting.
- SM914 (b8b6864e) **a test number is a label, not an identifier - written down,
  and the ambiguous set stops growing.** Measured: 107 numbers name two or more
  test files, one names four, and 1,294 bare-number citations point at those 107.
  `t/integration/13` is two different tests and is written that way 61 times.
  Nothing is broken - the harness globs filenames and both files run - but this
  project cites evidence by test number constantly, and a citation that reaches
  two tests has stopped identifying anything. **Ruled: write the convention down
  and gate new ones, not renumber** - a rename invalidates every citation that
  names the file in FULL as well as every bare-number one, so the cure is larger
  than the disease for a property no code depends on. The convention is in
  `docs/architecture/test-coverage.md`: cite the file, and give a new test a
  number nothing else in its directory uses (leading zeros are not part of the
  number - `06-preview.t` and `6-deny.t` collide). **The gate records the SET, not
  a count**, and that distinction is the whole design: a ceiling of 107 would let
  one collision be traded for another while the tree is no better. `t/lint/157`
  holds the 107 as a named baseline in its own `__DATA__`, fails on a collision
  that is not in it, and **also fails on a baseline entry that has stopped
  colliding**, so the list cannot drift out of step with the tree it describes.
  Four sabotages, and the third is the one that earned the design: resolve one
  collision, add another, total unchanged - both assertions fire. Also confirmed
  and worth saying because the claim needs its own measurement: none of the four
  tests added earlier in this release made the set worse.
- Door settled, nothing built (f30ae01f) **SM276's write door is answered by
  measurement, and the scope is smaller than filed.** The ruling left one thing to
  the build: `lazysite/templates/system/` is protected, so a site's own translation
  file needs either a validating action or somewhere else to live, "and that is the
  first thing to settle, because it decides what the extraction produces". Three
  measurements from a running engine. **The protected tree really is closed** -
  `lazysite-dav.pl` refuses in its own words, "only `lazysite/layouts/` is writable
  over WebDAV; the rest of `lazysite/` is protected". **Somewhere else already
  works**: `_system_page_md` resolves a system page through the domain's content
  root, the docroot, then the engine default, and driven through the real request
  path with all three present, **all three tiers fire** - a content-rooted French
  host gets its own copy. So a language site already overrides a system page by
  writing ordinary content, with no action and no door. **And a `.conf` in content
  space is writable but never servable**, because `conf` sits on SM797's static
  denylist. So the site file is `<content root>/lazysite-strings.<lang>.conf` and
  the engine's default is `<lazysite>/templates/system/strings.<lang>.conf` - one
  mechanism, shared with the pages, no second answer to where a site's wording
  lives. **The scope shrinks in the half that matters:** the five system pages are
  already localisable today by that override, so they want documentation and a
  decision about translated defaults, not code; the extraction is about the
  strings compiled into Perl, at least 38 of them and that is a floor - 15 in the
  form handler, 12 in the processor, 11 in the auth CGI. **The measurement took
  three attempts and every wrong one returned a UNIFORM answer**, which is
  indistinguishable from "no difference": the fixture ships its own `404.md` so
  tier 2 always won, the rendered `404.html` is cached so a rewritten source was
  not re-read, and an alias content root only applies when the host is named in
  `alias_hosts:` - which `t/unit/processor/41`'s own header warns about. A
  sequencing note is recorded too: two of the 38 shipped today in SM579's banner
  map, which `t/lint/156` pins against a second copy in the processor because ADR
  0001 keeps the render path module-free, so the extraction should start on the
  auth CGI's eleven messages rather than fight both at once.
- SM485 (e6fd5b7f) **a notice can name a person, and reach them by mail if they
  asked for it.** Measured before building: `notify()` built its record from a
  fixed key list, so a `to` passed by a caller was **dropped silently** - every
  notice was a site-wide broadcast, and the bell was the only endpoint reachable
  without a chat server. A notice now carries an optional `to`, and `email` joins
  `bell` and `xmpp` as an endpoint on the mechanism that already existed, so there
  is no second place to say where a notice goes. **`to` names an ACCOUNT, never an
  address** - the address is read at delivery from the account's own record - so
  nothing a caller passes can point the site at a stranger, and that is why this
  needs only the per-site hourly bound and not the per-recipient cap SM877 built
  for form acknowledgements, whose addresses a visitor types. **Both switches are
  real and neither implies the other:** the site says which types may leave by
  mail, the person says whether they want mail. No type is routed to email by
  default, so an upgrade cannot start a site writing to anybody. **A broadcast
  reaches nobody by mail** - it is a bell item, and mailing everyone would mean
  assembling the address list this filing declined to build. The transport is the
  Form SMTP extension, because there is one mail configuration on a site and
  SM842 spent a release removing the second; when it cannot send, the reason names
  which of three things is wrong rather than saying "mail failed". A notice that
  did not become an email is an ordinary outcome and does not fail the call - the
  bell already has the record. The opt-in is the **second** setting to pass
  SM724's test for self-service (grants nothing, confines nothing, audits
  nothing), which is what turned that hardcoded single-key carve-out into a named
  list with the test written beside it; a third key has to argue the same three
  things. It is a **boolean**, and deliberately not an address: the only thing a
  person can change is whether mail goes where their account already points.
  `t/unit/lib/55`, ten subtests, five sabotages - one of which earned an extra
  assertion, because removing the broadcast guard changed no behaviour (the
  recipient lookup refuses an empty login anyway) but did change the reason a
  sysop reads, so the test now pins the reason and not just the silence.
  **AND IT WALKED INTO A LIVE DEFECT**, fixed here because the endpoint cannot be
  reached without it and filed as SM915 for the rest: SM817 renamed the extension
  list to `extensions:` and said both spellings open the same one, and
  `Lazysite::Notify` accepted only the old name - so on a site using the new
  spelling it reported every extension disabled, which means **XMPP notice
  delivery has been silently off on those sites since the rename.**
- SM915 (e6fd5b7f) **filed, not built: one registry spelled two ways is read four
  ways, and the one that WRITES it appends a second list.** Found while SM485
  looked for a predicate for "is the SMTP extension enabled". Of the four places
  that read the extension list, one accepts both spellings and three do not - and
  `Lazysite::Manager::Plugins`' writer, on a site whose header is `extensions:`,
  preserves that block and then emits a fresh `plugins:` one, so enabling a single
  extension leaves the site with two lists that disagree. `disable` is quieter and
  worse: the entry is not in the list it parsed, nothing is removed, and it reports
  success. Only the Notify reader is fixed, in SM485; the writer needs a ruling
  first, because a site that has enabled an extension through the manager since
  the rename already has both headers and the fix has to decide whether to write
  back under the header the site uses, merge them, or refuse and name the file.
  The measurement that found it is also a lesson in its own right: the first probe
  wrote to a `plugins.conf` that does not exist, got `0` from both readers in both
  spellings, and would have been read as agreement.
- SM579 (3d0a5164) **a submission that went to a service says so, instead of
  claiming a message was sent to somebody.** There was one success sentence -
  "Thank you - your message has been sent." - and a form whose only target is a
  connector sends a message to nobody: it hands the submission to a service to be
  processed. The sentence was false on every such form, and the only alternative
  the code had was `form-status-error` with `role="alert"`, which would have shown
  a working submission to the visitor as a failure. So a second engine-authored
  success state, ruled and worded by the release manager: **"Thank you - your
  submission has been received and sent for processing."** It is true whether or
  not the connector keeps an answer, and promises neither a reply nor a page,
  because only the author knows whether the site shows the answer anywhere. The
  handler picks it when a delivery came back as a connector's - read from the
  delivery's own answer, not by reading the conf a second time - and a form with
  both a store and a service gets it, because the onward leg is the part the
  visitor could not otherwise know about. **Author copy was refused**, and for a
  measured reason rather than a preference: the no-JavaScript path answers by
  redirecting to `?form=X&outcome=...`, and a query string is writable by whoever
  composes the link, so text travelling in it would let a crafted URL put anything
  on the page in the SUCCESS style - a materially better phishing aid than the
  error banner already is. What travels is a **token**; each side holds a closed
  `token => sentence` map and looks the sentence up, and a token neither side
  holds falls back to `ok` rather than being printed. The two maps are two copies
  because ADR 0001 keeps the render path module-free and they cannot share code,
  so `t/lint/156` holds them equal token for token - the shape `_acl_allows_read`
  and its lint already use for the ACL decision. Nothing else would ever fail if
  they drifted: a visitor would simply be told one thing with JavaScript and
  another without, and nobody is looking at both. `t/unit/forms/27` drives the
  real CGI against a **real** connector on a loopback listener rather than a mock,
  for the reason the uploads test learnt the hard way - a mock more permissive
  than the thing it stands for certifies the mock - and the store and connector
  cases are asserted as a discriminating pair, so a build that said "sent for
  processing" everywhere fails as loudly as one that never said it. Sabotaging
  the lint found a defect in the lint: its key pattern silently dropped a token it
  could not parse, which would have let two equally-incomplete maps agree, so it
  now counts what it read against what the file declares.
- SM857 (0f3490ea) **a form handler says what its rows are, which is the piece the
  expo depends on.** The ruling that gave a row a policy also said the time to set
  one is at WRITE - "whatever is creating the row gets to say the policy" - and a
  form handler was a writer with nothing to say it with. So on a table declaring
  `row_policy: true`, measured before this was built: `row_policy=NULL` on every
  row, and Bob amending Ann's application on the table whose declaration exists to
  stop exactly that. A `table` handler takes **`row_policy: personal`** now and each
  row belongs to the account that submitted it. Declaring nothing writes SHARED
  rows, so no existing handler changes behaviour. The value is checked at save
  against **the store's own vocabulary** rather than a second copy of it, and
  `personal` on a table with no policy column is refused there too - for SM807's
  reason, that a visitor's submission is the worst place to find out. **And the
  combination worth naming out loud:** `personal` with no signed-in submitter is a
  public form, so `created_by` is empty and the row belongs to **nobody** - safe,
  being more locked down rather than less, and almost certainly not what was asked
  for. The row is still stored, because refusing it would lose a submission over a
  configuration the visitor cannot see, and the delivery's audit line says what
  happened. `t/unit/forms/26`, three sabotages - one escaped first time because
  `Data::Value` normalises an empty policy to NULL, so the test had to reach a
  table with **no** policy column to see the difference, which is also the case
  the guard actually protects.

- SM825 (4e9dce51) **the markdown beside the rendered page, which llms.txt has
  been linking to since SM299 and getting HTML from.** SM299 spent its effort
  getting the shape of those URLs right - an index page's URL already ends in a
  slash, so appending `.md` gave `<dir>/.md` - and measured before this was
  built, the URLs are right and every one of them answers with the page's HTML,
  byte-for-byte identical to the rendering. The one registry whose whole purpose
  is to hand a machine the prose without markup around it pointed every client at
  markup. Appending `.md` to a page URL now serves its Markdown as
  `text/markdown`. **The audit's recommendation was right and its sizing was
  pessimistic, for a reason worth recording.** It said: build an emitter on the
  render path rather than an exception to the denylist, so the gate is the page's
  own by construction - which is what this is. But it sized the gate as work to
  be done, because it reasoned about `_serve_content_static`, whose gate is the
  per-path ACL and never reads the page. A `.md` request never reaches that
  branch: `sanitise_uri` removes the extension before the branch is chosen, so
  the request has always gone down the render path and has always been gated by
  the page's own `auth:`. Measured: a gated page's `.md` answers 302 to the
  sign-in. There was no gate to build, only an emitter to place after the
  existing ones, and SM797's denylist is untouched - `md` stays on it, and the
  alternate is not a static file. **The front matter is BUILT, not filtered** -
  an allowlist of `title`, `subtitle` and `description`, the three keys the
  rendering already publishes, so the alternate discloses nothing new.
  Constructing the output from a fixed list is what makes that an allowlist in
  fact rather than in intent: a key added next year is withheld with nobody
  deciding to withhold it, where a filter that strips known-bad keys would expose
  it. Withheld today: `auth` on 27 of the 64 shipped pages, plus `auth_groups`,
  `query_params`, `tt_page_var`, `payment_address`, `form` and `api`. A TT
  directive inside an allowlisted value is stripped through the same helper the
  `register:` list uses, because one shipped page carries `[% client_ip %]` in its
  subtitle. **Before the cache, not after,** and that is load-bearing rather than
  tidy: the render cache is keyed on the collapsed path, so `/page` and `/page.md`
  share one slot, and a markdown body written there would afterwards be served as
  the page to everyone until it expired. Exactly one `.md` counts; a doubled
  extension is the probe SM797 closed and still gets the rendering.
  `t/unit/processor/81`, nine subtests and five sabotages - one of which found
  that the allowlist is enforced twice and only the emission loop is
  load-bearing, now said where a refactorer would read it. This also changes an
  assertion in SM797's own test, deliberately and with the reason written in
  beside it: the `draft: true` in that fixture's front matter never gated
  anything, because a draft is an `acls.json` entry, and a real one is refused
  before the emitter runs.
- Audit, nothing built (c974440d) **SM825's markdown alternate is not near-free,
  and the audit was there to find out.** The filing marked it VERIFY-THEN-EXPOSE
  and said the ordering was the whole point. Four questions, each answered from
  source. **The `.md` is not reachable**, and not by accident: `md` is the first
  entry on SM797's static-serve denylist, by a **ruling of 2026-09-09**, enforced
  on the request extension and again on the canonical resolved path. **The static
  serve does gate** - `_acl_refused`, SM223's work - **but only on the per-path ACL
  store**; it never reads the page, and a page declares its access in FRONT MATTER
  with `auth:`. So dropping `md` from the denylist gives the SM460 shape exactly: a
  page gated as a rendering and world-readable as a source, and `auth:` is on **27
  of the 64 pages the engine ships**. `draft:` is the same mechanism and the same
  answer. What a verbatim `.md` would publish first, measured: `auth` on 27 pages,
  `query_params` on 5, `tt_page_var` on 2, **`payment_address` on 2**, and `form`,
  `api` and `auth_groups` on one each. **One correction to the filing**: it says
  front matter carries `read:` lists, and it does not - there is no such page key
  and no shipped page has one; per-path reader lists live in `acls.json`. Smaller
  than filed, still an access-control fact on 42% of pages. The recommendation is
  to build it as an **emitter on the render path** rather than an exception to the
  denylist, so the gate is the page's own by construction and SM797 needs no
  reconciling - and to rule which front-matter keys a source alternate may carry,
  as an allowlist, because a denylist exposes the next key somebody adds.

- SM912 (91c3ed31, 9132a17f, e81117c4) **P1, P2 and P3: the exposure probe can
  protect its own fixture
  again, and a probe that could not run no longer reads as a clean one.** SM901
  began refusing a read list where every name is unknown to the store - right,
  for a rule somebody is authoring - and the SM283 probe's read list is a
  sentinel chosen precisely because nobody has it, which is how it proves a
  protected file is withheld. So from 0.15.0 the probe could not establish its own
  precondition on any site that has accounts, and the fleet run reported SKIPPED
  while the summary counted it in the **clean** column. **P1:** the probe does not
  need "nobody", it needs "not the anonymous visitor" - the measurement is an
  anonymous fetch - so it names the first account the store knows and keeps the
  sentinel only where the store knows none. **P2:** the verb exits **3** for
  "nothing exposed and nothing measured"; 1 stays exposure only, so no caller
  reading non-zero as exposure becomes wrong, and the fleet summary grew a third
  column that says "could not run" in words. The tool had been saying SKIPPED in
  its own output all along - what it could not do was say it to a program.
  **P3:** a re-apply whose list is identical to the stored one reports `unknown`
  and proceeds, because re-sending what is already on disk is not an authorship
  and refusing it cannot prevent a mistake already made - while it did stop
  `--reapply-acls`, the repair for content sitting unprotected, at the first rule
  naming an account that had since gone. A **new** list of unknowns is still
  refused, and the test says so. **Two of this work's own assumptions were
  measured false**: the first version of the gate passed vacuously (it asserted
  the absence of one skip reason, which any other skip satisfies - the sentinel
  sabotage proved it), and a claim that a site with **no accounts** cannot be probed
  at all - written up from a synthetic fixture that would not move content, and
  disproved by `t/integration/43`, which protects successfully against two real
  front ends with no accounts at all. A test that agrees with one docroot and not
  another is testing the docroot, so that path is left to the integration test and
  asserted nowhere else. **The costliest mistake was neither of those:**
  `our $PROBE_NOBODY = '...'` sat BELOW the main flow in a script that runs its main
  flow at the top, so the assignment had not happened when the probe ran and the
  read list became the **empty string** - ten assertions failed for a name that was
  never wrong, only unset. It is a sub now, which has no order to get wrong. A
  `Name used only once` warning from the same edit printed INTO the probe's own
  output, where the integration test reads it as the probe's answer.
- Withdrawn before release, and recorded rather than deleted: the schema.org
  JSON-LD build for SM824 was written and then reverted the same day
  (`f9fdc02e`, reverted by `15a32dd1`; the filing carries the withdrawal in
  `b8b672b9`), because that filing's own last section says the extensions
  batch comes first and this was built ahead of it. **The audit stands and
  the reasoning below is why it is worth keeping** - it is what the work will
  look like when it is ruled. What it says: **every page says what it is, in
  schema.org JSON-LD, and no
  author had to type anything.** The load-bearing constraint was no new authoring
  burden, so every value comes from front matter and site config that already
  exist: the title, the site name, the site URL, and a description that is
  `meta_desc` or the subtitle. **Nothing is asserted that the site does not have**
  - author and dates are commonly absent, and a block claiming an author a page
  never carried publishes a false statement about that page. **`Article` is never
  inferred**: a page with a date *and* an author is still a `WebPage`, because
  guessing the type from a date is inference published as fact; `schema_type:` in
  front matter is the only way to get another type, it lands as a **second** type
  rather than replacing `WebPage`, and anything that is not one bounded word is
  ignored rather than emitted. Injected beside SM112's generator meta and SM151's
  canonical link, on both the real-layout and the no-layout paths, so a site
  running its own layout is not a site without structured data - and a layout that
  emits its own block keeps it. **The escaping boundary had two halves and both
  bite:** `</script>` inside a JSON string ends the block in a browser however
  well-formed the JSON is, so every `</` is written `<\/`; and these values arrive
  HTML-escaped for the `<title>` tag, which would put `&amp;` inside a JSON string
  where an ampersand means nothing, so they are decoded by the exact inverse
  first. `_canonical_path` was factored out of the canonical-link injector rather
  than copied - two answers to "which URL is this page" is how a canonical link
  and a JSON-LD `url` come to disagree about the same page. `t/unit/render/71`,
  four sabotages; twice while writing it I picked the wrong node out of the graph
  and got the `WebSite` where I meant the page, which let a sabotage pass until one
  helper made every subtest ask the same way.
- SM217 (1e2f2a8b, 3d2c6360) **a host can be an alias of another, and the list says so.**
  The engine has always served several hosts from one content root - a host with
  no `content_root` of its own mirrors the primary, and two hosts may point at the
  same folder - but there was no way to SAY that. An operator added a second
  domain and typed the shared path themselves, and the Domains list then showed
  the two as unrelated peers: the relationship was real and invisible. **And the
  hand-copying does not fail when it goes wrong**, which is why this is an action
  rather than a note - measured first: a one-character typo in the shared path is
  accepted, the new host is provisioned and seeded with its own empty folder, and
  it serves a different site under a name that says it is the same one.
  `domain-alias-add` takes `host` and `alias_of` and **reads** the canonical
  domain's content root; it takes no `content_root` and refuses one, because a
  caller that could supply it could supply the wrong one. An empty canonical root
  is a valid answer rather than a missing one (both hosts then serve the default
  site, which IS the relationship). `domains-list` marks each row `alias_of` the
  first host carrying its content root - **derived, never stored**, so it cannot
  disagree with what actually decides what is served, and a rootless host reads as
  an alias of `(default)` rather than of whichever alias was registered first.
  Presentation overrides still pass through, so an alias may look different while
  sharing content; `seed` does not, because the content is there by definition and
  seeding would write a page into the canonical domain's own folder. Serving is
  untouched: this is a convenience over a mechanism that already worked.
  `t/unit/manager/191`, three sabotages - one of which found that a supplied
  `content_root` was being silently dropped rather than refused, which honours
  the rule by accident. **And the list marks it** (7f33cc63): a row whose content
  root is shared reads `alias of <host>`, and **only where that root is a named
  folder**. The `(default)` case is deliberately left out, because this page had
  already REMOVED an alias chip and recorded why - it meant "no content folder of
  its own", the Content folder column already said "default site", and being a
  chip it looked pressable and did nothing. What no column says is that two
  domains pointing at the same named folder are one site. `t/lint/155` pins the
  narrowing and names that earlier decision beside it, because it is one `!==` a
  tidy would delete. **Not in this**: the "Add alias" control. The action exists
  and the list marks its result; invoking it from the page belongs in the Add
  form rather than in another domain's config sheet, and that is a change to that
  form's shape.

- SM857 (22a8da4a) **a row can belong to the account that wrote it.** Measured
  before this was built, on a table with `timestamps` and two accounts holding
  `write_data`: Bob rewrote Ann's row and then deleted it, and `delete_row`'s
  signature had nowhere to say who was asking. `write_data` is documented as "the
  grant for an app's own users", and it was a grant over every row in the table -
  ten applicants on one applications table could each edit the other nine's.
  **Why not a select**, which is how every other system does this: no filter in
  this engine is written by the server. A page binding cannot name the viewer
  ([[SM856]] keeps it that way deliberately) and the endpoint's filter comes from
  the caller, so adding "scope by select" would mean introducing a
  caller-controlled filter and then trying to constrain it. The primitive is the
  engine refusing a **key** the caller named, tested against `created_by` - the
  one field in a row a caller cannot forge. `row_policy: true` gives each row an
  **explicit** disposition (`personal`, `shared`, or absent meaning shared), set
  by whatever creates the row at the moment of writing, per the ruling of
  2026-09-12. Nothing is inferred from `created_by`, because an empty one already
  means "written anonymously by a public form" and a personal row owned by nobody
  is amendable by an operator alone - the deliberate reading for every row
  written before [[SM860]], and what makes them safe rather than ambiguous. The
  anti-capture rule is the asymmetry: **a writer may give their own row away and
  never take someone else's**, so naming the policy on a row you did not create
  is refused whatever that row's policy is, and taking a shared row private needs
  `manage_data`. `row_policy` needs `timestamps: true`, refused by name at load.
  `update_row` and `delete_row` now **require** `as` and die without it, as
  `read_rows` has since SM476: there is one caller, so a default would be a third
  state in a write gate. `t/lint/153` refuses a surface that asks which table a
  caller may write without also asking whose row - which is [[SM682]] round 2's
  defect exactly, on the same two surfaces. `lazysite-check` reports, per table,
  how many rows carry no policy, because confinement protects nothing that
  already exists and that is invisible. `t/unit/data/62`, four sabotages.
  **Not in this**: `(mine)` on a page binding, which needs the per-viewer cache
  treatment, and a form handler declaring the policy it writes rows with - the
  filing names the second as the piece the expo depends on.

- Pre-stable debt (410982fa) **the columns the data extension owns are named
  once.** `created_at`, `updated_at`, `created_by` and `updated_by` were written
  out **fifteen times** across eight modules - twice as a `%RESERVED` hash, once
  as a list to create, once as column definitions, once as CSV headers, once
  inside a sysop-facing message, and nine times as the alternation
  `/\A(?:created_at|updated_at|created_by|updated_by)\z/`. Nothing had gone
  wrong; what makes it worth fixing now is that [[SM857]]'s ruling adds a policy
  column the engine owns the same way, and a set spelt in fifteen places grows by
  being spelt in fifteen more. A column added to fourteen of them would be
  created by the migration and refused from writers, and then reported by the
  fifteenth - the drift check - as an undeclared extra to remove.
  `Lazysite::Data::Owned` holds the list and answers **two different questions**
  that were previously tangled: `reserved_column` is unconditional (no descriptor
  may declare one, whether or not that table sets `timestamps`, because the flag
  can be turned on afterwards) and `is_owned`/`owned_columns` are per-table (the
  columns actually present). `t/lint/152` refuses a second spelling anywhere in
  the engine, and found the fifteenth - a message that would have recommended
  `timestamps: true` while naming four of five columns. No behaviour changes: the
  generated DDL is byte-for-byte what it was, deliberately, including the
  unquoted column names.

- SM905 (d1cb29ac) **U4: the row an operator works from reaches the photograph.** A
  table handler with `keep_copy` stored a visitor's uploads under the submissions
  tree and named them in the submissions record; the row in the table had
  nothing, measured as `files=NULL` beside a photograph on disk two directories
  away. That is the expo case the filing came from: a business card photographed
  at a stand, and a lead worked the next morning from a table that did not know
  the picture existed. `files_column:` on the handler names a column of the same
  table to receive them, as site-relative paths, comma separated, one per file -
  a path somebody can paste into the Files page rather than a folder to go
  looking in. The filing called this "a small design question about descriptors
  rather than a small change", and the design is that the column is **declared
  and checked against the table's own descriptor at save**, with `keep_copy`, for
  SM807's reason: finding out at a visitor's submission is the worst of the two
  places. The key is reported as the key rather than as a column that does not
  exist, which is the mistake `Data::Value` documents about its own message. A
  submission with no attachment leaves the column **alone** - not an empty
  string, because a column nothing was written to is what "attached nothing" is.
  Two smaller things fell out of writing it: the uploads are now saved **once**,
  before the row, so the copy and the row cannot name two differently stamped
  directories; and a file that could not be written is **named** on the record
  and in the delivery's audit line instead of being dropped in silence, so two
  files arriving and none landing no longer reads as a visitor who attached
  nothing - and an uploads directory that cannot be created no longer takes the
  whole submission down with it, losing the fields as well as the files.
  `t/unit/forms/25`, four sabotages.

- SM905 + SM913 (baaec983, ba8215d6, 5313e813) **U5, and the question SM913 left
  open: an upload form can be finished over the API, and a
  quarantined submission is never answered.** The form handler refuses every upload
  until a form's own conf carries one of `upload_max_kb`, `upload_max_files` or
  `upload_accept` - so a form never accepts files by accident - and the only writer
  was `form-targets-save`, which writes `targets:` and nothing else. So an agent
  could create the handler, bind the form, render the file input, and then watch
  every submission refused with "this form does not accept file uploads" with no
  action to fix it; the 0.15.0 edge walk confirmed that from outside and
  hand-wrote the conf over WebDAV to finish the job. `form-uploads-save` writes
  them now. **A JSON client sends a JSON boolean**, and it is taken as one - the
  walk lost time to `handler-save` refusing `true` for `attach_files` while wanting
  the string, and a new action does not get to repeat that. Turning uploads off
  removes **every** upload key rather than the ones named, because a stale key the
  reader still honours is uploads still on after being switched off. And `accept`
  refuses a media type while **naming the difference**: the page grammar's
  `accept:` rule is the media-type one, `upload_accept` is an extension list, and
  the two sit one page apart in the same job - which is the confusion the walk
  reported, answered where somebody meets it. **SM913's open question is answered
  in the same place:** a **quarantined** submission gets no acknowledgement. The
  spam controls hold a suspect submission back from the notification bell, and
  writing to the address it supplied is the louder act - on the form that produced
  SM913, four of four genuine-looking submissions were spam. The flag was already
  on the fields, so nothing had to be plumbed to ask. `t/unit/forms/24`, four
  sabotages.

- SM913 (2a85e85e) **S1 and S3: the quarantine sees the spam that actually arrives.**
  Four of four genuine-looking submissions on a live contact form were spam, read
  one by one, each from a different source range - so nothing about addresses
  would have caught any of them. SM216's content quarantine was built for exactly
  this and did not fire, and the reason was one line: `m{https?://}gi` wanted a
  **scheme**, and all three sales pitches wrote their opt-out host as
  `brnd .li/delist`, with a space inserted to defeat link filters. **Widening the
  count was necessary and not sufficient**, which only showed up once the real
  message was used as the fixture: both of its links are the SAME host, and the
  counter deduplicates by host deliberately - a person naming one site three ways
  is not three links - so the pitch scored one link against a threshold of two
  and would still have got through. So **the disguise is its own reason**: a host
  with a space before its top-level domain and a path after it quarantines on one
  occurrence. The path is what makes that safe - without it `the shop .Then I
  left`, which sloppy typing does produce, would match, and there is a test that
  says so. S1 also counts a `www.` host and a host with a path, and normalises
  `www.` out of the dedup key, which the sabotage pass exposed as a real defect:
  without it, one site named twice - once with the prefix, once without - reached
  the threshold on its own. **S3** catches the fourth: every field reducing to the
  same text, or one run of five or more digits in every field, on a form with
  three or more filled in - which is a bot checking whether the form delivers, not
  a message anybody wrote. `t/unit/forms/23` drives the real CGI with real
  multipart posts, and **half of it is honest submissions** on purpose - an
  enquiry naming its own `logo.png`, one quoting a single page of ours, a
  developer writing about `Node.js` and version `1.2.3`, a reference number in two
  fields of three - because a quarantine only costs nothing while it is wrong
  rarely. Six sabotages, each caught by the subtest whose property it breaks. The
  stored reason keeps the word "urls" though the counting widened: it is read back
  by the Submissions page, and a rename would leave the store holding two
  spellings of one fact.

- SM905 + SM579 (aab03248) **U1 works in the field now: the uploaded photograph
  reaches the service,
  and the test that said it already did has been fixed too.** 0.15.0 claimed a
  connector could carry an uploaded file and it could not: the handler built
  `$payload{files}` as an array reference and `Connectors::call` refused any
  payload value that was a reference - *"a payload carries text values only -
  never a file or a structure"* - so the photograph reached the connector layer
  and stopped. The edge walk of TEST-PLAN-0150 found it with a control: same
  form, same handler, same connector, one field's difference, no file answered
  and with a file refused. **Both halves were correct on their own terms and had
  never been run against each other**, which is the class of gap that plan exists
  to find. **The gate was worse than absent - it was misleading.**
  `t/unit/forms/20` replaced `Connectors::call` with a stub accepting any
  payload, so it certified for a whole release a shape the real code rejects: a
  mock more permissive than the thing it stands for tests the mock. The real
  coderef is kept before the replacement now, and the last subtest hands it
  exactly what the handler built - verified by restoring the old rule and
  watching that subtest fail. **The ruling (release manager, 2026-09-28) is an
  exception, not a flattening:** `files` is the one key that may hold a structure
  - a list of filename, type, size and data, the shape the email handler has
  always sent - because the flat rule exists to stop an ACCIDENTAL structure
  reaching a destination expecting text, and a declared, capped, opt-in
  attachment list is not accidental. Every other reference is refused in the
  words it always used. Three refusals arrive with it: a malformed attachment; a
  **GET** connector, because a base64 photograph in a query string is a secret in
  every access log between here and the destination; and a **slack-format**
  connector, whose payload is lines of text and which would otherwise send the
  word ARRAY. The call record gains `files` and `file_bytes`, so an operator can
  see that a photograph left rather than a form field, and still holds no part of
  the payload. This amends one of SM579's five decisions of 2026-09-07 and the
  module header says so where a reader will find it.

- SM877 (65f5c830) **a form can answer the person who filled it in, and the cap is
  the feature.** The email handler's `to` is fixed at configuration time, so a
  site could notify its owner and could not acknowledge the visitor - every
  receipt, booking confirmation and copy-of-what-you-signed needs the other
  direction. Set `mail_the_submitter_field` to a form field holding an address and
  the site sends a **second, separate** message to whatever it contains; leave it
  blank and nothing changes. **The requester's proposed mitigation did not hold,
  and the filing had already measured why:** the form rate limiter is keyed per
  source IP, so it bounds how often one sender submits and says nothing about how
  many destinations the site will write to - and the party being harmed is the
  recipient, who that limit does not protect. So the axes are **per recipient**
  (3/hour) and **per site** (60/hour). The site default sits deliberately above a
  real burst rather than at it: one lead form took 18 in an hour at an expo, so a
  cap of 20 would have refused a good day. **Four refusals that are all the same
  rule.** An absent field, an empty one and a malformed address each refuse
  instead of guessing; and a counter that cannot be READ refuses too, because a
  cap honoured only while its record is readable is not a cap - the same reading
  this release is named for. **The operator's copy always goes**, the submission is
  never failed for a capped courtesy, and the reason is not silent: it travels into
  the delivery's audit record, whose state stays `ok` because the delivery did
  happen, in the detail field that was empty until now. The record holds a hash of
  the recipient and never the address, so the counter cannot become a mailing list.
  Not a separate handler type - the filing's worry that `to_field:` hides what it
  switches on is answered by the key's name, because SM842 spent a release removing
  types that duplicated a delivery path. `t/unit/forms/22`, five sabotages; one of
  them escaped first time round and was a duplicate hash key that changed nothing,
  which is worth knowing: a sabotage has to be checked for having had an effect.

- SM579 (3c660780, ef2e669d, ed91dbc2) **SM747's X4 is ruled, and who may make
  this site send something outward is
  one policy, and it is no longer the connector's private business.** The three
  invocation modes were ruled in September and described from the start as the
  outbound policy for the whole programme, then written inside
  `Lazysite::Manager::Connectors`, where the first caller lived. So anything else
  wanting to send outward had two choices: reach into a manager module for a
  package variable, or keep its own copy of a security decision - which is the
  shape SM662 had just spent a release removing from the control API's capability
  gate. X4, ruled 2026-09-28, is what forced it out: the Odoo extension's
  per-user proxy leg must sit "as mode 2 **inside** SM579's policy, not beside
  it", and there was no inside to sit in. `Lazysite::Egress` now owns the
  vocabulary, the decision and the refusal wording; the connector keeps what is
  genuinely its own - which modes it permits, which groups it names, and that
  `manage_connectors` is **its** override rather than a master key over every
  future callee. **Proved to change nothing:** the old body was reproduced
  verbatim and both were run over 960 combinations of mode, permission,
  named groups, held groups and override, comparing the verdict AND the refusal
  text, with zero disagreements. Two latent faults went with the move: the
  message listing the legal modes had them hardcoded, so a fourth mode would
  have shipped invisible, and it now derives them; and the refusal noun is the
  caller's to supply, so a proxy refusing a call does not call itself a
  connector. `t/unit/lib/54` holds all of it, four sabotages between them -
  including one that checks the connector POINTS at the mode list rather than
  holding a copy that happens to be equal today.

## 0.15.0 - EDGE: an unreadable store stops speaking for the site, and one table decides (2026-09-28)

- SM905 U1 + U3 (d6829a04) **an uploaded file can reach a service, and a form can
  ask for the camera.** A visitor's photograph could be stored and could not be
  processed. The connector handler passed the visible text fields and never read
  `$ctx->{files}`, though `$ctx` was used on the line above for origin, actor and
  trigger - so the one governed way out of the site, with its vetted destination,
  its credential in the reserved tree, its declared modes, its rate cap and its
  audit record per call, could deliver anything except the photograph. The email
  handler had been attaching files for releases, a few lines up the same file, so
  this follows that template exactly: same key, same payload shape of filename,
  type, size and base64 data, same default of false. **The ceiling refuses rather
  than truncating.** `attach_max_kb` defaults to 1024, which is deliberately below
  a phone photograph, and a request over it is refused with the size, the ceiling
  and the setting that raises it - sending part of a photograph is worse than
  sending none, because the destination cannot tell. A malformed ceiling falls
  back to the default rather than to no limit, which a sabotage caught: asserting
  only that the refusal happened passed with the validation removed, because a
  non-numeric ceiling reads as zero and refuses everything. **U3:** the form
  grammar rendered `accept`, `multiple` and `required` on a file input and had no
  way to ask for the camera, so an author wanting a photograph had to hand-write
  the input, which the forms contract does not allow for content. `capture` is
  rendered now, bare or as `capture:user` / `capture:environment`; any other value
  is dropped rather than emitted as an attribute no browser honours. Inline was
  chosen over a signed URL on the filing's own recommendation, because a
  by-reference payload would need the destination to reach back into this host and
  the connector's whole design is that traffic goes outward only.

- SM662 (f00e48bf) **the table that decides is the table that is published.** The
  control API's capability gate was declared twice: `%need_caps` inside a sub in
  `lazysite-manager-api.pl`, which decides, and `Lazysite::ControlApi::Actions`,
  which publishes and was documented as an extraction of it. Two copies of one
  fact is the shape that made SM687 need nine registration points to add one
  action, and that made every one of the last five omissions surface as a failing
  gate rather than as something a reader could see. The gate now lives in the
  module as `%GATE`, moved verbatim with all 87 of its comment lines and 22
  trailing notes, because the reasoning per entry is the most valuable thing in
  it; the register's capabilities are **derived** from it at load, and the CGI
  builds its predicates by asking for it. **Proved to change nothing:** the two
  tables were captured before the move and agreed exactly - 102 actions reachable
  with a token, 54 cookie-only, no disagreement - and all 156 resolve identically
  afterwards, which is what SM662 asked for in its own words about a
  security-critical table. A gate entry for an action nothing publishes now dies
  at load instead of being dropped quietly, because over-claiming is
  self-correcting and silence is not. `t/lint/98` changed from comparing the two
  copies to holding the property that replaced them: one table, the CGI declaring
  none of its own, and the resolved gate matching what it was before. Two more
  checks stopped scraping the module's source and read the loaded table instead,
  which is what the move makes possible - and `TestHelper::gate_caps` now DIES on
  an empty table rather than returning nothing, because six lint suites read the
  gate through it and an empty answer makes every one of them pass on nothing.
  One test read the gate out of the script's text and was repointed at the table
  in a follow-up (84a0513d), which is worth knowing because it was the fourth to
  do so and the suite is what found it. Still open, and still its own work: the
  150-branch dispatch chain, which is why `params` is the one thing here that
  remains a hand-kept copy.

- SM888 C1 + C2 (9e898351) **the no-CDN rule has a gate at last, and it looks
  where the breach hides.** Five live sites fetched fonts from a third-party
  origin on every page view and survived repeated engine upgrades unreported, and
  the reporter's framing is the finding: months of silence is the defect and the
  fonts are the symptom. Nothing in the repository checked the rule. `t/lint/151`
  checks everything lazysite SHIPS - starter themes, layouts, manager pages and
  styles - for a reference to another origin inside an `@import` or a `url()`, so
  a fresh site cannot start in breach and an upgrade cannot introduce one. The
  shape matters: the live breach was line 1 of a theme stylesheet, which a scan of
  the rendered PAGE certifies as compliant, so the test carries that exact import
  as a case it must catch, along with a protocol-relative origin, and asserts that
  a site-relative import and an inline data URI are not flagged. Verified by
  sabotage: a font import added to a shipped stylesheet fails the gate by file and
  line. The live half - sweeping what each site actually serves, including themes
  an operator installed - still needs a rendered page from a real host and is
  named in the filing.

- SM888 P2 (9e898351) **an asset is something somebody put there.** The Files
  panel counted everything that was not a `.md` as an asset, including the
  engine's own rendered `.html`, so a folder holding six uploads reported eight
  and the number moved when a page was RENDERED rather than when anybody uploaded
  anything. A rendered page sits beside its source, so an `.html` with a matching
  `.md` beside it is output and is not counted; an `.html` with no source was
  authored and still is. Measured on the reported shape: nine before, seven after,
  the seventh being a hand-written page with no source.

- SM910 (c21298c8) **the partner brief and the site's published copy answer
  different questions, and now say so.** A brief told its agent to confirm the
  brief's claims against `/.well-known/ai-partner`. That document is
  partner-agnostic, so its capability list is about the SITE, and on the reported
  host the two differed in both directions, five of nine. The partner then
  exchanged its key and settled it: `whoami` returned exactly the nine the brief
  named, with `manage_config` **false** - which the endpoint advertised and the
  account did not hold. So the brief was right and the check it asked for was the
  one check that could not say so. The brief now says the published copy confirms
  the site, the endpoints and the deny list, and that **only `whoami` confirms a
  grant**; the document carries a note saying the same about its own list. Three
  published statements also disagreed about one WebDAV write: the brief's body
  said a PUT to `lazysite/nav.conf` is accepted with `manage_nav`, its Notes said
  the same PUT is refused, and the site document said it needs `manage_config`.
  The endpoint enforces `manage_nav`, so the body was right; both others are
  corrected, and `t/tools/89` reads the capability out of the WebDAV endpoint and
  requires the two documents to name it, so the disagreement cannot re-open. The
  Notes also claimed `lazysite/` is not writable over WebDAV, which would have
  sent a partner holding `manage_layouts` to ask a sysop for something it can do
  itself - the endpoint's own refusal says `lazysite/layouts/` is the part that
  is writable. `endpoints` and `modes` were reported as never filled; measured,
  they populate whenever the service is enabled, so the real fault was that an
  empty object could not be told from an unfinished document. The document now
  publishes `services` as explicit booleans, in the vocabulary `whoami` already
  uses.

- SM911 (c21298c8) **the layout check stops punishing the pattern the
  documentation teaches.** Activating a layout reported nav 0, meta_title 0 and
  meta_desc 0 and warned that `nav.conf` would have no effect - for a layout
  whose served page in that same activation carried five nav items from
  `nav.conf`, a resolved title and a resolved description. The detector required
  the variable to OPEN the directive, so it missed `[% FOREACH item IN nav %]`,
  which is the only way to render a multi-item navigation, and it missed
  `head_title = page_meta_title || page_title`, which the layouts briefing's own
  `<head>` contract tells authors to write. It now matches the variable anywhere
  inside one directive, and still refuses `navbar`, a TT comment and a layout
  that mentions none of it. Also: `layout-delete` read only the dispatcher's
  generic `path` parameter, so a partner who tried eight spellings of "layout
  name" concluded the action was unreachable and deleted the directory over
  WebDAV instead. It takes `layout=` now, like its siblings, and the refusal
  names the spelling - with the declared action table naming the parameter too
  (36d1873b), which is what publishes it, and which the suite caught as missing.
  And the layouts briefing described the theme tokens as an
  inline `<style>` block; since SM352 the variable emits a stylesheet link, so an
  author following the old wording nested a link inside a style element.

- SM907 AT4, AT5, AT6 (c21298c8) **the tail of the audit-trail filing, which
  closes it.** The check now names what each unwritable file costs: the audit
  log's line says events are being lost as they happen, rather than that the
  manager cannot save it, which no manager does. The installer gives a forms
  `.example` 0640, because `smtp.conf.example` shipped 0644 and the copy an
  operator fills in with an SMTP password was world-readable - the second failure
  the field check reported. And the visitor-log readers were brought under the
  same rule as the trail, which narrowed the claim: measured, the MAIN
  access-log read already refuses and names the fault, so the headline count was
  never the lie. The secondary readers - a log tail, the rotated logs, the
  form-event files - each skipped in silence, shortening counts with nothing
  looking wrong. They report now, and the export names which logs would not open,
  so a short count is distinguishable from a quiet site.

- SM906 remainder (8e0bcfb0) **the other two symptoms of the field report, which
  the first pass left alive.** With the group store unreadable, two more answers
  were computed without asking whether it could be read. `group_is_assignable`
  had two documented fallbacks that both mean "the store does not say", and an
  unreadable store took the first of them - no record, so assignable - which is
  how the reported host offered `cap-content` and `ch-ui` in the Add User picker,
  the backend groups the flag exists to keep OUT of it, while the store saying
  they are not roles sat there unreadable. Unknown is not yes: nothing is offered
  as a role while nothing can be read, guarded on an empty answer as well as the
  flag so a caller passing its own view is unaffected. And the group name is all
  the label there is when the store holds none, so the users tool now says
  `store_unreadable` on both the calls that carry the view - including
  `users-page`, the ONE call that page makes - and the page states it rather than
  presenting `cap-content` as somebody's chosen label. Reproduced first, with the
  store readable and then at mode 000: every group flipped to assignable and every
  label fell back at once. `t/tools/88` gains both, sabotaged both ways.

- SM908 (8e0bcfb0) **a suite failure that could not be diagnosed, and the two
  causes it did not have.** One test in 14,833 failed a gate run reporting
  `apache would not start with its guard block: ` with nothing after the colon, so
  the twelve-minute gate was paid twice and the cause went with the overwritten
  log. Two hypotheses were offered and both measure FALSE: the port helper's
  window between closing its probe socket and the server's bind produced no
  collision in forty rounds of four simultaneous askers, and the loop's reuse of
  one port across eight apache restarts released the port within 0.1s four times
  out of four. What IS demonstrated is the silence - the test ran apache through a
  bare `system()` and reported the ErrorLog, and apache refusing a configuration
  says so on STDERR and never opens that log. `ApacheHarness::start_apache_conf`
  captures what apache said, for a test that needs its own configuration; the
  test prints it, takes a port per iteration, and says in a comment that this is
  not a fix for a named cause. Proved by sabotage: a deliberately broken conf now
  reports `module unixd_module is built-in and can't be loaded` where it reported
  an empty string.

- SM909 (8e0bcfb0) **the authoring briefing stated the render order backwards**,
  in the sentence that opens the section teaching it, against six statements
  elsewhere saying the opposite. Reported by the sites agent on weight of
  evidence, with the reporter saying plainly they had not read the processor;
  verified here in the code, which converts the body to HTML at
  `lazysite-processor.pl:3729` and hands that to the renderer where TT runs. So
  the six were right. It reads "the page body is converted to HTML first; TT runs
  second, over the rendered HTML" now, which is the corpus's own formulation, and
  the image, fence and link rules downstream of it stop reading as three
  unrelated exceptions to a rule stated backwards.

- SM907 AT2 (a6d62db0) **an audit trail that cannot be written no longer reads as
  a site where nothing happened.** From the field: an agent deployed a site and
  the trail showed nothing of it. The six events it did show had all been written
  by a root shell, and `lazysite/logs/audit.log` was group-owned so that the web
  server could read it and not append to it - so the page rendered a short,
  healthy-looking list while every event since the install was lost. The
  operator's own login was missing from it, which is what identified the cause.
  A short page had **six** possible meanings and one rendering: recording;
  readable but not appendable; existing and unopenable; switched off; never
  written with no way to start; and never written on a new site, which is the
  only one of the six where an empty list is the truth. The audit action now
  answers which, in a sentence composed once on the server so the manager and the
  control API say the same thing, and the page shows it above the table - and
  before the empty-list shortcut, the case that matters most. A trail that exists
  and will not open is now a refusal (`store-uninspectable`, a 500, SM873's kind)
  rather than `ok` with nothing in it. `lazysite/logs` is **a store** in
  `Lazysite::Stores` now, which puts lint 121 in front of it; the entry it
  replaces argued that an unreadable append-only log may show an empty page
  because "the writer says so in its own log", and the writer does, through
  standard error, which for a CGI is the web server's error log. Following that
  lint found two more silences in the same file and fixed them. `t/unit/manager/196`
  covers all six states, and what it asserts is that they differ. The visitor log
  in that directory has the same property and is not covered yet: AT6 on SM907.

- SM906 (16fd58e7) **an unreadable auth store no longer reads as an account that
  holds nothing.** Reported from a new install: the capability grid empty, group
  names showing as `cap-analytics` and `ch-ui`, and `account-create` refusing
  with *"Creator 'sjm' lacks create_sub_users permission"* about an account whose
  own permissions dump listed that capability. **One cause.** The CGI user could
  not read `lazysite/auth/groups-settings.json`, the file recording what each
  group grants, so `caps_for` resolved to zero for everybody — and the engine
  reported that as facts about the account. Reproduced both ways: the store
  provably correct and the CLI working, then the same site with that one file
  unreadable, which reproduces the operator's sentence verbatim.

  **Four fixes.** The permission model now declares that file (76bc2420), which
  is what makes a **fresh install** set it correctly rather than only explaining
  it afterwards — the installer sets group-write from that model, and this was
  the one auth store missing from it. `lazysite check` lists it too, in both the
  CGI-readable and CGI-writable sets, beside the `user-settings.json` that has
  been there since SM141: the check already looked at `users`, `groups` and
  `acls.json` in the same directory for this exact fault and omitted the one that
  decides capabilities. The refusal names the file, the fault class and the
  repair instead of blaming the account, while an ordinary refusal is unchanged
  and asserted to be. And the manager group carries the label **Site operator**
  rather than its own name, healed on upgrade as well as on creation, which was
  the only half of the report that was ever about naming.

  The operator's host was repaired by the permission alone, which confirms the
  cause. `t/tools/88` covers the lot, and `t/lint/30` is what caught the missing
  model entry.

- SM888 A5 (849539a6) **a required checklist of one box has to be ticked.** The
  renderer left `required` off checkbox groups entirely, which is right for a
  multi-select — the browser reads it as "this box", so marking them all would
  demand every option — and wrong for a group of one, where "this box" and "one
  of the group" are the same box. A field the author had marked required
  submitted empty, and the single-box case is most often a consent tick, so the
  case where it matters most was the one least enforced. `t/unit/forms/19`
  covers all four directions, and its multi-box subtest holds the reason rather
  than the result.

- SM881 (e3e57b99) **a pull no longer publishes a file that belongs in a
  protected folder, and the engine now answers "is this path gated?" for any
  extension that asks.** `git merge` writes the worktree and the worktree is the
  docroot, so a remote commit adding a file under a gated folder put that file
  straight into the public tree, with a successful pull as the operator's only
  signal. **Reproduced against a real remote first** (`t/unit/plugins/05`), as
  the ruling required. The obvious fix does not work and the filing had already
  shown why: `resolve_for_write` answers *public* for the pulled file, correctly,
  because an ancestor existing in the docroot settles it and the merge has just
  created that ancestor. So the question goes to the ACL store, which a merge
  does not touch, through a new exported `Acl::gating_for` — a promotion of the
  precedence ladder `_acl_entry_for` has carried since SM287, not a new
  subsystem. **Its answer has three states, and that is load-bearing:** an
  absent or empty store is *open*, only a store that exists and will not parse
  is *unknown*, and the sync treats *unknown* as stop-and-report — because
  treating it as gated would relocate every changed file and silently unpublish
  a site on the next pull, which is worse than the exposure. A second-order
  effect was found and fixed on the way: the alias reindex asked whether the
  file was in the docroot, so a relocation would have deindexed the page and
  broken every link to it. Three sabotages, one of which bit nothing and proved
  the unknown guard is load-bearing by itself.

- SM871 (572b2e6e) **a quoted form rule may contain a quote, written `\"`.** The
  tokeniser matched `name:"([^"]*)"`, which cannot hold a quote at all, so
  `value:"the \"Old Barn\" room"` truncated at the first inner quote — and the
  remainder went back through the same loop as further rules. That second half
  is the one that bit: a leftover chunk still matches the **valued** rules,
  which are compared by an unanchored regex, so `value:"a \" max:5"` silently
  capped the field at five characters. **One of the filing's own claims is
  corrected here:** it could never switch on `required`, because the flags are
  compared with `eq` and `required"` matches nothing. Only `\"` is unescaped,
  never every backslash, so a `pattern:` keeps its `\d` — asserted as its own
  subtest, because getting that wrong would break every pattern in the tree. An
  unclosed quote now logs a WARN naming the field and the rule and otherwise
  behaves exactly as before: dropping the rest of the line would let a
  `required` written after a malformed value become optional, which is worse
  than the fault. `starter/docs/forms.md` documents the escape;
  `t/unit/forms/18` was proved against the old regex.

- SM873 (bb282a55) **a refusal names a fault at this end with a 500, and a kind
  is never assembled at run time.** `Data::Tables` built
  `kind => 'store_' . $why->{reason}`, so one line emitted a family of kinds —
  one per reason the store diagnosis can return — and every member missed
  `%REFUSAL_STATUS` and answered **400 Bad Request**. A caller was told its
  request was malformed when what had failed was this host reading its own data
  store, and a client retrying a 400 sends the same request again. All five
  reasons are the same class, so the family bought nothing: the kind is now the
  single literal `store-uninspectable`, mapped to 500, with the specific fault
  carried in `reason` beside it for a caller that wants to branch. The 404 this
  filing wondered about does not arise — an absent store is answered as
  `pending_schema`, an ordinary state, before the diagnosis is reached.
  `t/lint/139`'s exemption for the `store_` stem is gone rather than replaced,
  and `t/lint/150` refuses the four assembly shapes for good while still
  allowing a pass-through parameter and the unrelated `kind` a backup, a layout
  and a snapshot each carry. Both gates were proved by restoring the old line.

- SM904 (6d9f595c) **a form value with a non-ASCII character is stored as
  typed.** Found on a live expo form: a name ending *Hervé* was stored as
  *HervÃ©* — UTF-8's two bytes read as two Latin-1 characters and encoded
  again — and reproduced on edge by a percent-encoded XHR and by the
  browser's own submit alike. `parse_post` handed every field on as bytes,
  and every destination (the table, the submissions file, the mail payload,
  the thank-you page) encoded them a second time. One decode at the parse,
  in both the urlencoded and the multipart branch, with a body that is not
  UTF-8 left as it was. `t/unit/forms/17` posts to the CGI both ways. Rows
  already stored mangled are not repaired by this.

- SM903 (18652829) **`theme-rename` is retired.** SM749 made the served theme
  read-only and put **Copy** on Appearance in Rename's place; the control-API
  action outlived the button, reachable only by a caller who read the
  actions list, and could rename a non-active theme in place. Ruled and
  removed: a client that called `theme-rename` gets the unknown-action
  refusal. The one way to change a theme is copy, edit, activate
  (`theme-copy` stays). **Breaking for API clients that called it; none in
  the tree, the manager or the skill did.**

- SM902 (f93cf14c) **the manager guide says what its pages do.** The X6 walk
  of every page against a live 0.14.4 manager found twelve sentences in
  `starter/docs/manager.md` describing controls the pages do not have: a
  layout/theme line on Site settings that is not there (and eight controls
  that are, unnamed), Enable/Pause buttons for content history (the tick on
  Extension Manager is the control), a preview that is on save rather than
  live, inline nav editing and a heading toggle (a dialog, and a blank URL),
  on Appearance a card name, a `layouts_ref` control that does not exist and
  a per-theme Rename that went with SM749 (Copy is the way), a Users tree
  with an identity banner and a Configure button (one line per account and
  Edit), a Groups "first member" that is no longer needed, and a restore line
  without the `--domain` the page prints. Docs only; `theme-rename`'s future
  as an API action is a register question.

- SM901 (d1d68672) **a read or write list is checked against the store: a
  name nobody has is reported, and a list that names nobody is refused.**
  From the 0.14.4 W5b re-walk: `{"read":["agent-ai","edge-testing"]}` — two
  group names without the `@` — was accepted with `ok:true` and no remark,
  and a member of the group got Forbidden; the stored rule read to nobody but
  the owner. `acl-set` now resolves every name (a bare name against the
  accounts, `@name` against the groups). A name the store does not know is
  **stored as written** — a login that will exist tomorrow is a legitimate
  thing to write today — and reported in `unknown` on the result and in the
  warnings the CLI prints. A non-empty list that resolves to **no** known
  principal is refused (`unknown-principals`, naming the names and how a
  group is spelt), because a rule that reads to nobody can only be a
  mistake. A site with no accounts and no groups checks nothing, so a rule
  can still be written before the first account. The manager's picker was
  never affected (SM305); the control API, MCP `set_permissions` and
  `lazysite acl set` are. `t/unit/manager/194` covers each branch.

- SM900 (2a8f4fa1) **a template parse error is reported at the file line, on
  every surface.** Found by the 0.14.4 W11 walk: `validate` said line 7 for
  an unclosed `[% IF %]` on file line 11, while the unclosed fence on the same
  page was reported at 8, correctly. The fence check adds the front-matter
  offset back; the template check handed the parser a body with the front
  matter *and* every code-block line removed and reported the parser's line
  as it stood — and the write-path refusal a manager save or an MCP
  `write_file` gets carried the same number. The parser's line is now mapped
  back through the kept lines and the offset, so it is the line the editor
  shows; `t/unit/manager/193` holds a page with both a front matter and a
  code block above the fault, on both surfaces.

- SM899 (c94e847a) **a refusal names a command the host has, and is not
  reported as a failed command.** The 0.14.3 field walk, run by the operator
  from an unpacked tarball: every SM892 refusal was correct and every one
  told them to type `lazysite upgrade …` — "command not found" on that host,
  where the verb was reached as `perl /tmp/lazysite-0.14.3/tools/lazysite-cli.pl`
  — and then ended `command failed (exit 2): /usr/bin/perl …/install.pl
  --docroot … --mode provision`, which reads as "you ran something wrong" and
  points at a file nobody typed. The CLI now tells the installer how it was
  reached (`--invoked-as`; `lazysite` when typed as that, `perl <absolute
  path>` otherwise) and every hint is spelt with it; a refusal (exit 2) or a
  channel skip (exit 3) is passed through as it stands, with its own exit
  code and nothing appended, while a crash still reads `command failed`.
  `starter/docs/install.md` and `UPGRADE.md` say when `--cgibin` is needed
  (a site with no registry entry) rather than leaving the verb to say it.
  And the operator's ask: `--installdir DIR` on `provision`, `upgrade` and
  `reinstall` stands for `--docroot DIR/public_html --cgibin DIR/cgi-bin`,
  the HestiaCP layout, and is refused alongside either option it stands for.
  `t/tools/85` covers each.

- SM894 (39d463ee) **a test that edits a tracked file puts it back, and a run
  that could not is noticed by name.** Three tests write `VERSION`, the
  sign-off switch, the reliability record and the practice briefing for real
  — the tool under test reads them — and each restored them its own way: two
  in `END` blocks, which a signal skips, one inline, which a `die` skips. A
  run killed mid-test left `VERSION` at `99.0.0`, which failed the version
  lint on every later run on a tree nobody had edited. `preserve_tracked` in
  the test helper is now the one owner: backup under the repo's own `tmp/`
  (never `/tmp`), a marker naming the test, restore on scope exit, on exit
  and on INT/TERM/HUP; and `tools/tracked-tree-check.pl`, run by the handoff
  gate after the suite, names any tracked file left changed and the test
  whose backup outlived it — the SIGKILL case no handler can cover.

- SM895 (e22e00dc) **a failed cut keeps its stage, and the next cut removes
  it.** G1 and G2 shipped in 0.14.4; this is G3, the one deliberately left
  and now reconciled with SM328 rather than overruling it. The first 0.14.3
  attempt ran the instrumented suite for two hours and then deleted the
  database the report step had failed on, so the second attempt was launched
  blind. Now a gate failure keeps the stage and the abort line says so and
  says when it goes; success removes it; `--keep-stage` keeps a successful
  one too (the success path used to remove regardless, so the flag never did
  what its name said); and every run starts by removing the stages of dead
  runs under the stage base — a live run's is never touched, and the logs
  kept beside a stage survive it. `t/tools/87` drives the three functions in
  a scratch base; `t/tools/61` expects "retained" on every abort.
