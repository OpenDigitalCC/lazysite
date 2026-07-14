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

## Unreleased

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
