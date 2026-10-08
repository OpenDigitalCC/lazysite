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

- SM944 (PENDING) **internal: the content-type cache is the processor's fifth
  part** (S6 of the plan in the filing). `ct_cache_path`, `read_ct`, `write_ct`
  and `write_html` move unchanged to `lazysite-processor/ct-cache.pm`. No
  behaviour change.

- WORK-PLAN-0153 Q14b (PENDING) **the release gate can run from a `git
  worktree`.** It refused one ("no git repo": it looked for a `.git` directory,
  which a worktree has as a file) - and a long gate is safest run from a
  worktree, because the main checkout switches branches during development and
  bash reads a script as it runs. `release.sh` now asks git, and it and
  `gate-main.sh` keep receipts, the coverage store and the lock in the main
  checkout's `tmp/release-gate/` wherever they run from, so build finds them.
  t/tools/101.

- SM944 (PENDING) **internal: content components are the processor's fourth
  part** (S5 of the plan in the filing). `convert_fenced_components` and its
  helpers move unchanged to `lazysite-processor/components.pm`; lints 212 and
  213 read the parts. No behaviour change; across S2-S5 the cache-hit and miss
  render times are unchanged (1.010x and 0.998x, inside each tree's spread).

- SM944 (PENDING) **internal: the URL remapper is the processor's third part**
  (S4 of the plan in the filing). `_remap_parse` (the marked copy of
  Lazysite::Remap's parser), `_remap_redirect` and `_alias_lookup` move
  unchanged to `lazysite-processor/remap.pm`, the first part to read the
  script's shared state, through `our`. No behaviour change.

- SM944 (PENDING) **internal: oEmbed is the processor's second part** (S3 of
  the plan in the filing). The oEmbed converter, with `uri_encode` and
  `strip_tt_directives`, moves unchanged to `lazysite-processor/oembed.pm`. The
  lints that check a property of the whole processor (21, 25, 43, 121) now read
  its parts too. No behaviour change.

- SM944 (PENDING) **internal: the state the processor's parts read is declared
  `our`** (S2 of the plan in the filing). The 27 file-scope variables a planned
  part reads become package variables in place, initialised where they were;
  the other 15 stay `my`. t/lint/215 now fails a part that names one of the
  script's `my` variables, or reads script state from its own file-scope code.
  No behaviour change.

- WORK-PLAN-0153 Q14a (PENDING) **a code count in the bench baseline moves with
  the code that changes it.** The release gate refused main after the last
  landing: `work_users_tool_statements` read 3378 against 3359, the 19
  statements SM962 and SM963 added to the users tool on purpose. That counter
  is about the code, not the host, yet it could only be updated at a cut - so
  under SM971's gate-after-every-landing, every deliberate growth would fail
  every gate until then. `tools/bench.pl --work` now prints the counts read from
  the source alone, and t/lint/216 fails a branch whose code changes one
  without updating the baseline in the same commit. The baseline moves to
  3378. Timings stay host-relative and re-captured at a cut.

- SM944 (PENDING) **internal: the processor's first part** (S1 of the plan in
  the filing). The front-matter parser moves, unchanged, from
  `lazysite-processor.pl` to `lazysite-processor/front-matter.pm`, which the
  script requires by absolute path from beside itself, never through `@INC`, so
  the render path stays free of the `lib/` tree (ADR 0001). The manifest installs
  parts to `{CGIBIN}/lazysite-processor/` and the deb payload carries them; the
  lints that sweep the shipped Perl read them; t/lint/215 keeps each one package
  main, loading nothing, loaded by name and defining no sub twice. No behaviour
  change; cache-hit and miss render times unchanged.

- SM971 (PENDING) **a release is one commit on main, and its gate has already
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

- SM970 (PENDING) **security: a value used as a whole link target can be kept
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

- SM943 stages 2-3 (PENDING) **an action's MCP twin and the twin's hints are
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

- SM906 T3 (PENDING) **an unreadable account store answers `cannot-tell`, not
  "Invalid credentials"** (ruled 2026-10-07). With `lazysite/auth/users`
  unreadable no secret can be checked, and a caller holding a good token was
  told it was invalid (MCP: "reissue the token"). It now gets `cannot-tell` 503
  naming no store and no repair - it has proved nothing yet, and a host fault is
  not a stranger's to map - and is told not to reissue; the operator's log
  names the file. t/integration/107.

- SM950 (2)(3) (PENDING) **the gate runs on main after each landing, and a cut's
  gate reuses coverage instead of spending an hour re-measuring it.**
  `tools/gate-main.sh` gates main's tip for NEXT_VERSION, detached, and prints
  the receipt instead when that commit already passed; before the pre-cut pass
  it rehearses (`release.sh gate --rehearse`, a receipt `build` refuses). Every
  passing coverage run is kept by its inputs digest and offered to the next gate
  with the same digest; the receipt says `coverage=reused` and from which run.
  The digest now leaves out tests that, read with PPI, can start no process,
  load no file and call no sub that does (moved on 9 of 24 commits, was 11).
  t/tools/100-102, t/lint/208.

- SM969 (PENDING) **security: a form outcome was written to the page cache and
  shown to the next visitor.** The outcome banner reads `form=` and `outcome=`
  from the query string, which the cache decision did not count, so a request
  after any page edit baked its banner - the text of the link followed - into
  the cached page for every later visitor. Such a request is now rendered for
  itself only, as a `nocache: true` page is. Found by the SM869 review's second
  pass; t/unit/processor/90.

- SM968 (PENDING) **security: a page that set TAGS let a reflected value run as
  a template.** The form prefill and outcome banner neutralise `[` and `%` in the
  visitor's text, which holds only while the tags are `[% %]`; after
  `[% TAGS {{ }} %]` in a page body, `{{ site_name }}` in a link's query was
  evaluated. A page body's TAGS directive is now a comment, with a warning in the
  log; layouts keep it. Found by the SM869 review's second pass;
  t/unit/processor/90.

- SM967 (PENDING) **security: a value could spell one of the engine's
  placeholders.** The passes that protect script, style, comments, code spans
  and tags restored them by a fixed word, so a value carrying the word was
  restored as the block: a copy of the page's code span, or the page's own
  script moved into a prefilled form field, where its quotes ended the
  attribute. Each placeholder now carries a per-call key the content cannot
  contain. Found by the SM869 review's second pass; t/unit/processor/91,
  t/unit/data/65.

- SM966 (PENDING) **security: a data value could become a link, or break an
  api page's JSON.** A query value or a db: row was HTML-escaped and nothing
  more, so `[text](javascript:...)` in it became an anchor after the template
  pass (on every page listing a visitor-written row), and a backslash or control
  character in it made an `api: true` response invalid JSON. One helper now
  encodes brackets, backslash and control characters as character references in
  every value the author did not write. Found by the SM869 review's second pass;
  t/unit/processor/90 and 91, t/unit/data/65.

- SM965 (PENDING) **security: a reflected form value could become an
  include.** A form's prefill and outcome banner are written into the page
  before the first `::: include` pass, and kept their line breaks - so a link
  carrying a crafted value could spell an include block and pull a file from
  the content root into the page (never `lazysite/`, never `..`). The one helper
  all three use now encodes line breaks as character references, which display
  as typed. Found by the SM869 adversarial review; t/unit/processor/89.

- SM964 (PENDING) **security: a value that reached a page as data could become
  an include.** The processor ran its `::: include` pass a second time over the
  template's output. That never resolved an author's template-path block
  (Markdown had wrapped it, and the docs said such blocks are not resolved), but
  it did resolve a block that arrived as data: a visitor-written row in a public
  table, listed on a public page, could pull an unlisted file - or the body of a
  sign-in-only page - into the output. The second pass is removed; a path from
  a template variable stays unresolved by design. Found by the SM869
  adversarial review; t/unit/data/64.

- SM869 (PENDING) **security: a query value is raw in the engine and escaped
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

- SM906 T3 follow-up (PENDING) **security: an unreadable or corrupt group store
  no longer makes every signed-in user a manager on the page side.** The
  processor keeps its own module-free copy of "does any group grant manager
  access" (ADR 0001), and answered "no - an unsecured site" when
  groups-settings.json existed but could not be opened or did not decode; an
  unsecured site lets any signed-in account into the manager and renders it
  with every capability. It now treats a present-but-unreadable store as
  secured and logs it, as T3 made the API's copy do. Absent still means a site
  with no groups yet. t/integration/108 (both cases fail on the old copy).

- SM906 T3 (PENDING) **an auth store the web server cannot read answers
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

- SM939 SC2 (PENDING) **a WebDAV folder delete that cannot finish says what
  stopped it** (ruled R1, amended). Recursive DELETE works; when a directory
  INSIDE the folder is not writable it stops part way, and answered a bare 500
  "Cannot delete the entry" while skipping the housekeeping for the pages it had
  removed. It now answers 507 naming that directory (relative to the site) and
  how many files were left, cleans up after the pages that are gone, commits
  the partial removal, and KEEPS the access rules on what is left - forgetting
  the folder's rules would unprotect it. Sending the DELETE again once the
  directory is fixed finishes it. t/unit/dav/31.

- SM957 (PENDING) **Submissions is the manager menu's first entry, with an
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

- SM963 (PENDING) **an approval says which groups it could not place the
  account in.** account-approve joined each group flagged for registrations
  inside an eval whose failure was dropped: with a flagged backend group it
  answered "Approved 'alice' into learners." and ok, the other group gone
  unsaid. Each failure now comes back in `unplaced` with its reason - a line
  each on the CLI, the Users API result, both audit trails (`NOT placed in` /
  `not-placed=`), and SM858's approve result and success dialog. The account
  and its link are still made. t/unit/users/49, ten sabotages.

- SM962 (PENDING) **a username is refused by name, never silently rewritten.**
  `account-approve jo+hn` created `john`, then minted its claim for `jo+hn` and
  failed - leaving a credential-less account with no link, under a name that may
  be somebody else's. `add` stripped every character a username cannot hold and
  every caller carried on with the original. It now refuses, naming the
  character and the allowed set (letters, digits, `.`, `_`, `-`), before
  anything is written - for approve, `add`, `setup-sysop` and the Users API
  alike. **A name with other characters that `add` used to shorten is now an
  error.** t/unit/users/48, three sabotages.

- SM961 (PENDING) **a submission arriving during a delete, confirm or approve
  is no longer lost.** Those rewrite the submissions store - read it, write a
  copy, rename it over - and nothing locked that window; the file handler's lock
  was on the store file, which the rename swaps out. A row appended meanwhile
  went into the discarded file, with the visitor already thanked. Both sides now
  take one sidecar lock (`.<store>.lock`, `Lazysite::Util::store_lock`) that the
  rename never moves. t/unit/forms/36 forces each direction by holding the lock;
  either half removed fails it. Found while building SM858.

- SM858 (PENDING) **an operator approves an account from a button on the
  Submissions view.** A form that names its address field in its conf
  (`account_email: email`) gets Approve on each row; it runs `account-approve`
  through the users tool with the address read from the stored row - never the
  request - and the username is the local part, lowercased. Nothing is stripped
  or suffixed: a character a username may not hold, a name taken in any case,
  an address already on another account, a quarantined row or one already
  approved is refused by name and creates nothing. The row records the account
  it became. Needs `manage_users` and `read_submissions`, cookie-only, audited
  with the row and the account. t/unit/manager/200-201, twelve sabotages.

- SM960 (PENDING) **security: a custom auth header name was trusted from
  anyone.** With `auth_header_user` set (the docs' example is `Remote-User`) and
  no `auth_proxy_trusted: true`, a visitor sending `Remote-User: alice` passed a
  page gate as alice - and behind the built-in auth wrapper too, which vouches
  for `X-Remote-*` alone. The trust gate stripped only the fixed `X-Remote-*`
  names; it now strips the configured ones unless a proxy is trusted, and logs
  each. **A site using custom header names must set `auth_proxy_trusted: true`**
  - until it does, those headers are discarded and visitors read as signed out.
  Default-named sites are unaffected. t/integration/106; the auth docs show the
  flag.

- SM857 (PENDING) **a page can show each signed-in viewer their own rows:
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

- SM943 (PENDING) **every per-action fact the manager API keeps is declared
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

- SM959 (PENDING) **a helper that exits before reading no longer kills the
  process writing to it.** Eleven places wrote to a child's stdin with SIGPIPE
  at its default - the form handler's mail, the manager API's plugin and users
  calls, the auth CGI, MCP, OAuth, the installer - so a helper that died on
  start (a missing module, a compile error) killed the caller mid-request with
  nothing logged. Only the processor guarded. Each spawn now runs with SIGPIPE
  ignored and the write fails as a write; lint 211 holds the rule and
  t/unit/lib/199 proves it (signal 13 without the guard). Found as a flaky
  t/unit/forms/24 - 4 failures in 8 parallel runs on main, now 0 in 8.

- SM958 (PENDING) **security: a token-gated action was open to any manager
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

- SM955 (PENDING) **the XMPP test reports a recipient the server refuses, and
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

- SM932 (2) (PENDING) **`lazysite check --sinks` says whether syslog received a
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

- SM913 S2 + S4 (PENDING) **a link shortener holds a submission, and each form
  says whether its quarantine is on** (ruled R2). S2: one link to a shipped list
  of shortener hosts (`bit.ly`, `tinyurl.com`, `brnd.li` from the reported spam,
  and others) is a reason on its own, matched as a link - a scheme, `www.`, or a
  path - so naming one in a sentence is not. S4: the Handlers page shows
  "quarantine on/off" on each form and lists what holds a submission; the
  manager reads the form config through `Lazysite::Handlers`, and
  t/unit/forms/35 posts through the real handler for every spelling of
  `quarantine:` and threshold to hold the two readers together. S5 (a default
  keyword list) is not shipped, as ruled.

- SM912 P4 (PENDING) **recorded: a rule checked against nothing says so.**
  Built in commit e765424f and shipped without a changelog entry, and the filing still read "P4
  remains". An ACL write against an auth store that knows no accounts or groups
  returns `principals_unchecked: 1`, so "accepted, unchecked" is no longer
  reported as "accepted, verified"; t/tools/91 asserts both states. Found while
  starting it as WORK-PLAN-0153 Q1.

- SM956 (PENDING) **a fast run of pages is a bot** - the site owner's rule: "a
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

- SM954 (PENDING) **a quarantined submission shows why, in the table.** The
  reason was stored (`_spam_reason`) and set as the tag's hover title, which a
  touch screen never shows; the owner saw "quarantined" with no reason (0.15.2
  edge walk, R3). It is now drawn as text beside the tag. t/unit/manager/180,
  which runs the viewer's own code against a recording DOM, asserts it.

- SM953 (PENDING) **a missing submission is named by its form, not its file.**
  The single-submission view answered "no submission <id> in
  lazysite/forms/submissions/contact.jsonl"; the owner ruled a message should not
  expose file paths (0.15.2 edge walk, R2). It now says "no submission <id> on the
  form 'contact'", and a missing store "no submissions for the form '<name>'".
  t/unit/forms/34 asserts the form and id are named and no path appears.

- SM952 (PENDING) **a form's rate limit is its own, and only a stored submission
  spends it** (ruled R8). The limiter was keyed on the address alone and recorded
  a time on every post that reached it, before validation: five posts to one form
  refused another form's first, and a visitor who got a field wrong spent their
  allowance correcting it. That was the 0.15.2 edge walk's R8. The check still
  runs early and refuses a flood before any work, but only reads; the time is
  recorded once the submission is stored (quarantined ones included - the form
  kept them), keyed on form and address. Rows of the old key age out within the
  hour. t/unit/forms/16 drives both cases through the handler; each fails with
  the old key or with recording on every post.

- SM951 (PENDING) **the manager bell works.** Its script runs in `<head>` and
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
