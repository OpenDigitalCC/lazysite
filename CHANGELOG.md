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
