---
title: "Feature-request backlog (index)"
subtitle: "Status at a glance; see each SMxxx doc for detail"
brand: plain
---

One-line status for every feature request. Updated 2026-07-10. Status derived
from the CHANGELOG (shipped releases) and corroborating code, not the per-doc
text.


## Ideas - not yet scoped

Discrete items expanded from the raw wishlist; each needs its own scoping doc
before work starts.

- **Backward-compatibility freeze (stability point)** *(project decision)* - pick
  a version (e.g. 1.0) after which breaking changes require a documented migration
  path, and drive all *intended* breaking changes in BEFORE that point so the
  freeze starts clean. Breaking changes currently in flight or planned that should
  land pre-freeze: ~~the SM095 capability model (`manager_groups` -> `ui`
  capability, channel gating)~~ *(done - SM138 retired manager_groups with an
  automatic migration, 0.6.5)*, settings/label reorganisation, any auth-store or on-disk-format
  changes, the backups consolidation, and the config-schema unification (SM042).
  Deliverable of the decision: a compatibility policy (what "breaking" means, the
  deprecation window, the migration-note contract) - a good ADR. Until then,
  breaking changes are cheap; after it, they are expensive, so sequence
  accordingly.
- **WebDAV as a plugin (vs core Services)** - WebDAV publishing is currently a
  core feature (now grouped under "Services" in Site settings). Consider whether
  it belongs as an opt-in plugin instead - lazysite-dav.pl is already a separate
  entry point gated by `webdav_enabled` + the `webdav` capability, so the move is
  plausible. Trade-off: a plugin is cleaner separation and lets a headless/API-only
  deployment drop the endpoint entirely, but WebDAV is deeply wired into the
  capability model and the partner-onboarding flow, so "plugin" must not mean
  second-class. Decide: keep as core-under-Services (done), or promote to a
  first-class plugin with the same trust model.
- **Plugin packaging / separation** - split plugins from the core tree so they
  can be added, removed, or uploaded independently: a plugin becomes a
  self-describing unit installed/uploaded like a theme, rather than living in the
  core checkout. Includes documenting the plugin interface so new plugins are
  simple to implement.
- **Status page** - collect monitoring data into JSON files, render it on screen,
  and derive a current-status view (meta information) from it.
- **XMPP notifications - future slices** - SM136 shipped the core (0.6.3);
  remaining ideas: per-user recipient choice and per-event subscriptions.
- **Live-chat plugin (XMPP bot)** - an on-site chat widget backed by an XMPP bot
  (reuses the existing XMPP integration).
- **Calendar-booking plugin** - bookable time slots with availability, producing
  a booking record (ties to the forms + notifications stack).
- **Image optimiser (Files)** - a file-manager tool to resize images or apply
  other transforms (ImageMagick or similar backend).
- **Group-of-groups inheritance** - a group can inherit another group's
  capabilities, with recursion protection.
- **E-commerce via Odoo** - products, prices, and sales sourced from Odoo's
  e-commerce API; an on-site basket creates a sales order through that API. No
  local product/price store - Odoo is the source of truth.
- **Passkey auth extension** - WebAuthn / passkey login delivered as an auth
  plugin.
- **External authentication integration** - authenticate against an external
  identity provider instead of (or alongside) the built-in user store: LDAP /
  Active Directory direct bind, and OAuth 2.0 / OIDC as a *consumer* (SSO login
  where lazysite is the relying party). The driver is customers who **already run
  an auth server** and want their existing staff accounts used rather than
  provisioning separate lazysite users. Covers **both audiences**:
    - **Back-end / manager users** (operators, editors, admins) signing in to
      `/manager` through the client's IdP - so a customer's IT staff manage the
      site with their corporate SSO. This means an external identity CAN hold
      manager access: the external group/claim maps onto a lazysite group, and
      the group's capabilities (including `ui`) decide what they may do. Group
      membership stays the authorisation source of truth (SM095); the IdP just
      supplies identity + group claims.
    - **Front-end users** - site visitors authenticating for auth-protected
      content, mapped to content-only roles.
  Two integration paths, don't conflate them:
    - **Proxy-based SSO is largely already supported.** Access managers that
      front the site as a forward/auth proxy - LemonLDAP::NG, Authentik
      (forward-auth), oauth2-proxy, Authelia - just need to set the trusted
      `X-Remote-User` / `X-Remote-Groups` / `X-Remote-Email` headers that the
      existing auth-proxy trust model already consumes (see the SECURITY threat
      model: the edge must strip client-supplied copies). The work here is
      mostly a documented recipe per product + mapping the IdP's group claim onto
      lazysite groups (which carry the capabilities), not new engine code.
      Confirm the manager (`ui`) path honours proxy-supplied identity, not just
      the content path.
    - **Direct integration is the new build** - an **auth plugin** (same shape as
      the planned Passkey/WebAuthn extension) that lazysite calls itself: an LDAP
      bind against a configured directory, and an OIDC login flow (authorization
      code + PKCE) where lazysite is the client. Reuse the OAuth machinery that
      already exists for the MCP connector *as a provider* (lazysite-oauth.pl),
      but note the direction is reversed (consumer, not provider). Open
      questions: local-account provisioning / just-in-time creation on first
      external login, external-group/claim -> lazysite-group mapping (the hinge
      for both manager and content access), whether built-in and external users
      coexist (mixed mode) or external replaces the local store, and account
      lifecycle when the IdP disables a user.
- **Database plugin** - pluggable storage (JSON file / SQLite / DBI) with a
  "form -> DB" write path. Named schemas (session, profile, basket, log,
  comments, + arbitrary); values readable and writable in TT, enabling
  author-built dynamic content.
- **AI-filter plugin** - send data plus an instruction to an AI vendor
  (selectable vendor + dev key in settings) for form review, moderation, and
  other transform tasks.
- **Search improvements** - feed both the auto-index and a manual index; log
  failed searches to a file for review.
- **A/B (C…) testing for alternative content / themes** - serve variants of a
  page (or the active theme/layout) to different visitors and measure which
  performs better. Needs: a way to define variants (alternative `.md` bodies or
  front-matter, or an alternative theme/layout), a deterministic assignment
  (sticky per visitor - a cookie or a hash of the network-level visitor token so
  a given visitor stays on one variant), an even/weighted split, and outcome
  measurement wired to the existing visitor-stats plugin (per-variant page views,
  and ideally a goal event). Open questions: variant definition (sidecar files vs
  front-matter blocks vs a plugin), how it interacts with the HTML cache (variant
  key must be part of the cache key), and whether goals are just page-reach or
  need form/He conversion events. Content variants and theme/layout variants may
  be two phases of one feature.
- **Unified credential/grant revocation (incl. OAuth)** - "Reset credential"
  revokes an account's static bearer without disabling it, and removing the
  account from a group revokes a capability grant - both already work. Gap: an
  active OAuth-connected MCP session holds its own access token (expires ~hourly,
  refreshes), so revoking the static credential does not immediately kill an OAuth
  connector. Add a single "Revoke all access" that also invalidates the account's
  OAuth grants/refresh tokens, for a clean immediate cut-off.
- **Upstream lazysite relationship (federation)** - a downstream lazysite
  instance holds an account/relationship *on an upstream lazysite* (the project's
  own hosted instance), established once and then reused as a two-way channel.
  This is the substrate two features below share, so scope the relationship first:
  identity + credential for the upstream link, what it is trusted to do, and how
  it is revoked. Distinct from a partner/agent connecting to a site - here one
  lazysite is a client of another.
    - **Feedback cascade (connector -> site -> upstream).** Connectors already
      submit feedback via the MCP `submit_feedback` tool, logged locally under
      `lazysite/feedback/` (see `_submit_feedback`). Extend it into a cascade: a
      manager reviews the accumulated local feedback, packages a selection, and
      forwards it over the upstream relationship to lazysite's own feedback
      endpoint - so feedback flows agent -> site -> project. Needs: a manager
      review/curate UI over the feedback dir, a package/redact step (strip
      site-private detail), and the upstream submit (requires the relationship
      above). Default to manual submit, not automatic.
    - **Onboarding request endpoint (approval-queue plugin, default OFF).**
      Instead of an operator only *issuing* accounts, expose an **unauthenticated
      request endpoint** where an agent or a downstream lazysite can *request*
      onboarding; the request lands in a **queue** for a holder of the
      user-management capability to approve or reject. A separate api/mcp endpoint
      that serves ONLY onboarding requests (nothing else reachable pre-approval),
      shipped as an **onboarding plugin switched on/off, default off**. At
      approval the manager selects the **group** the new account joins (which
      decides its capabilities, SM095) and, for a lazysite requester, establishes
      the relationship above - after which the same channel can deliver **update
      notices** downstream (reuse the notices store). Heavy on security and
      controls: strong rate limiting + abuse protection on an anonymous endpoint,
      captcha/proof-of-work or invite token option, request expiry, a hard cap on
      the queue, no information leak about existing accounts, full audit of every
      request/approve/reject, and a clear default-off posture. Relates to the
      existing pairing-key onboarding (SM124) and multi-tenant work (SM075).


## Open - actionable

- **apt-repo publication (SM139 residue)** - the debs exist
  (/srv/projects/packages/); publishing them from an apt repo (candidate:
  the Forgejo instance; suites stable/edge, signing key management) turns
  the dpkg step into `apt upgrade`. Scope when Forgejo is ready.
- **2026-07-10 review - deferred items** *(tracked in
  docs/review/2026-07-10-eight-dimension/01-resolution.md)* - (a) BOOK THE
  PENTEST ENGAGEMENT before the ADR 0007 waiver expires 2026-12-31 (hard
  date); (b) docs/MONITORS.md register + the dev-server operational exemplar
  (D5); (c) release signing (.sig + release.sh step), VEX, OpenChain
  5230/18974, CRA Annex VII technical file (D8 beyond the unconditional
  items); (d) bench breadth: manager-API users-page op, DAV PROPFIND/PUT op,
  scan-heavy render variant (D4); (e) a test pinning the 0.6.6 install.pl
  ownership repair (D3); (f) threat-model currency rows for the 0.6.x
  surface (D6 residual); (g) repeat a timed restore rehearsal each stable
  cycle (RELIABILITY.md commitment).
- **Eight-dimension review follow-up (2026-07-01, v0.5.35)** - full review at
  `docs/review/2026-07-01-eight-dimension/` (verdicts: D1-D4 + D7-D8 WARN,
  D5 + D6 REFUSE). Application-side actions proceed in the current cycle;
  **operational items are HELD for pre-launch** and documented with owners and
  triggers in `docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`
  (SLO/RTO/RPO declaration, snapshot crons, logrotate, monitoring/alerting,
  debsecan + gitleaks installs, pentest gate + engagement, support period,
  signing/DoC/VEX/technical-file set). **Ownership (2026-07-04):** the operational
  review is a HOSTING concern owned **per implementation** - each operator runs it
  for their own deployment; the project ships the mechanism + a worked dev-server
  exemplar (`tools/lazysite-server.pl`), not a one-time central sign-off. See the
  Status section of the holds doc.
- **SM085** Git backend / changesets *(design)* - `begin -> diff -> commit ->
  rollback` on a git-versioned docroot. Biggest remaining lever; adds the
  rollback safety net. Headline ask from both AI-partner reviews.
- **Remote-layout content components** *(DEFERRED 2026-07-03 - speculative)* -
  `install_layout` + fenced/sections components are local-layout only; remote
  (URL) layouts fetch just `layout.tt`, so their `components/` are not fetched or
  resolved. Current behaviour degrades gracefully (a `:::name` in content rendered
  with a remote layout falls through to a generic fenced div - no error). A real
  fix needs a design fork (on-demand guarded fetch of `<base>/components/<name>.tt`
  with per-component caching, vs a declared component bundle/manifest) and is a
  sizeable, SSRF-touching build - disproportionate until remote layouts are
  actually used with components. Revisit then.
- **Visitor statistics - performance** *(largely superseded by SM140,
  2026-07-10)* - visualisations shipped 2026-07-03; the performance concern is
  mostly gone: the page scan now reads dated first-party day files (bounded by
  the window, not the log's lifetime) and the AI export is incremental via
  per-file byte offsets. Residual: a very-high-traffic site might want
  scan_stats given per-file offsets too; revisit only if a real site's window
  scan bites.

## Done

- **SM070** WebDAV publishing endpoint + per-user ACLs.
- **SM071** WebDAV theme/layout management; self-service activation.
- **SM072** Self-service credentials + MFA-ready auth.
- **SM073** Per-file `.brief` sidecars.
- **SM074** Per-file ownership + ACLs.
- **SM076** MCP server for site management + OAuth (Claude.ai / ChatGPT / Code).
- **SM077** File-manager UI overhaul (permissions, rename/move, rights editor).
- **SM078** Audit trail records the target + origin.
- **SM079** Modular refactor (standalone processor + `Lazysite::*` modules); **SM079a** action-handler decomposition.
- **SM080** Reconcile partner docs with field reports (+ activation asset mirror).
- **SM081** Form targets: mixed handler/type read fixed (single-pass parse).
- **SM082** Content vs theme/layout write capability (`manage_content`).
- **SM083** Access-log stats plugin (domain-qualified auto-detect, autoconfig);
  v2 (0.4.62) adds a traffic classifier (people / AI assistants / bots / noise /
  logged-in operator), internal/external/direct referrer split, and log-path
  privacy. Later hardened: headless/agent UA detection + self-identify marker
  (0.5.23); the error surface is synthesised and the raw log download removed
  (0.5.29).
- **SM084** Non-destructive overlay install + content backups; in-manager
  restore (overlay semantics, prerestore safety snapshot, cache clear) shipped
  2026-07-02 with the eight-dimension follow-up.
- **SM087** Connector editing ergonomics - full tool set (patch edit, search, preview, validate, `set_nav`, copy, permissions, audit, manifest, error kinds, nav-cache).
- **SM088** Form-to-transport binding (`list_form_handlers` / `bind_form`).
- **SM091** Dev-server auto-index (`tools/lazysite-server.pl --auto-index`).
- **SM093** One-command manager bootstrap.
- **SM094** Users-page permission clarity.
- **SM095** Group-based capabilities - a channel × action model resolved through
  one central resolver that every surface consults (manager UI / control API /
  MCP / WebDAV). Manager-UI access and operator status became the `ui` /
  `manage_users` capabilities (manager_groups retired to a non-breaking fallback);
  capabilities incl. `create_sub_users` are explicit per-group grants; audit split
  into its own `audit` capability. Shipped 0.5.15-0.5.25.
- **SM097** Nav-editor page autocomplete.
- **SM099** Client-side auth button (`data-ls-auth-*` sync before `</body>`).
- **SM100** One-connect flow (connector onboarding).
- **SM101** Agent stop-retrying signal.
- **SM102** Agent feedback endpoint.
- **SM104** Top-level vs sub-user clarity.
- **SM105** Per-section `nav` own-capability; **SM106** `forms` own-capability.
- **SM107** Manager access-groups picker (delivered under SM114).
- **SM108** AI form-building docs.
- **SM109** Manager UI modernization (shell + sidebar, palette, toasts, dark mode).
- **SM111** Files list sortable + paginated.
- **SM112** Generated-site `<meta name="generator">`.
- **SM113** Operator notifications + submission alerts.
- **SM114** Manager UI polish round 2 (incl. access-groups picker).
- **SM115** Submissions UX + safety (append-only data read-only).
- **SM116** Dark editor colour scheme (WCAG-tuned CodeMirror).
- **SM117** Audit install/upgrade events.
- **SM118** Settings unsaved-changes reminder.
- **SM119** Audit filter dropdowns + date-range search.
- **SM120** Per-page `theme:` override.
- **SM121** WebDAV provisioning.
- **SM122** Token config self-service.
- **SM123** Theme discovery.
- **SM124** Connector onboarding alignment.
- **SM125** Scan front-matter passthrough.
- **SM133** Static-HTML migration fallback - a clean URL with no Markdown source
  but a static sibling is served (processor verbatim; Hestia vhost prefers `.shtml`
  so SSI still expands), until the page is converted to Markdown (0.5.26).
- **SM134** Page alias redirects - a page's `aliases:` front matter (old/alternate
  URLs) 301s to its canonical URL; map maintained in `lazysite/aliases.json` by
  `Lazysite::Aliases` on manager/WebDAV save+delete; processor enforces on the 404
  path only; target is always the page's own URL (not an open redirect) (0.6.1).
- **SM134 follow-ups** - `aliases_temp:` front matter for per-alias 302s
  (map schema stays backward compatible: string = 301, `{target, code}` = 302);
  manager move/copy/migrate + WebDAV MOVE/COPY reindex the affected page(s) so a
  rename re-keys aliases without a save; read-only Aliases card on the Files page
  backed by the `aliases-list` action (`manage_content` for token clients)
  (2026-07-10).
- **SM096** "Migrate to local" - a `.url` page fetched (guarded `Lazysite::Fetch`)
  and written as a sibling `.md` (2026-07-03).
- **SM098** Multi-page / wizard forms - `--- step ---` delimiters render linear
  wizard steps; delivery unchanged (2026-07-04).
- **SM103** Recent-change markers, Phase 1 - `recent-changes` from the audit tail;
  dots on Files/Users rows (0.6.1). Phases 2-3 (SSE, presence) remain a separate
  real-time programme.
- **SM126** Partner-agent onboarding & capability discoverability - the
  machine-parseable capability map (`describe_capabilities` MCP tool +
  control-API action), quickstarts, generated capability docs with drift test,
  transport gating, unified denial language, host-deps list (2026-07-04).
- **SM128** Bad-URL auto-blocker plugin (default on) - probe detection + rolling
  per-IP threshold, enforced in the auth wrapper; blocked-IP view/unblock on the
  Stats page. Known limitation: a no-auth basic site is not covered (2026-07-03).
- **SM136** notify-xmpp plugin - operator notices (form fills, reset requests,
  agent feedback) over XMPP; one client config per site, individual or room
  recipient (0.6.3).
- **SM138** manager_groups retired - manager access granted by groups only
  (`ui` / `manage_users`); automatic conf migration (0.6.5).
- **SM110** Domain aliases - alias_hosts + whitelisted per-host overrides
  (site_name/theme/layout/nav/search), host-keyed cache slots with exhaustive
  invalidation; security keys never vary by Host (0.7.3).
- **SM141** Sessions - live-session listing + per-session/per-user revocation
  on signed cookies (registry + revocation list, single enforcement point);
  legacy cookies honoured until expiry (0.7.3).
- **SM139** Packaged distribution - lazysite-common.deb (engine payload,
  lazysite CLI with no-root provisioning, FCGI pool unit, site registry) +
  lazysite-hestia.deb (one-command domain onboarding, cgi/fcgi vhost
  templates); fleet upgrade --all with channel/policy + --force-security;
  hardened lazysite-check (post-fix re-report, CGI-identity checks) (0.7.2).
- **SM142** Persistent runtime - dual-mode FastCGI accept loop, prefork
  pools, 147x on cache hits (62.2ms -> 0.4ms); plain CGI unchanged (0.7.1).
- **SM140** First-party analytics - the processor records its own traffic
  (anonymised at write, daily rotation, retention prune); the stats page AND the
  analyse_visitors AI export read it first, so analytics work with zero
  web-server setup; server log demoted to fallback/tier-2 diagnostics
  (0.6.8-0.6.9).
- **Manager UX / ops small items** (2026-07-03/04) - manager log-out control
  (with SM109), audit local-time timestamps, Files "Duplicate…", backups
  consolidated into one typed tab (+ cross-domain `--restore-full --domain`
  migration; per-section capability gating waits on external-auth),
  theme_assets default-theme fallback, audit in-page view on the incremental
  cache (was already present), `install.pl --channel`, manager-api branch
  coverage floor 55 -> 60.

## Candidates - research / future

- **SM075** Wildcard multi-tenant hosting.
- **SM086** Pandoc-wrapper construct renderers (datatable, charts, `:::` boxes,
  citations) - one source → branded PDF + web.
- **SM090** Social syndication / POSSE (ActivityPub + AT Proto, Slice 1).
- **SM092** Gopher and Gemini services - stays here: a protocol *transport* over
  the shared content core (like WebDAV / MCP), not a visual layout.

*(SM089 3D-rendered layout moved to `lazysite-layouts` - it is a layout/theme
category. Proposal now at `lazysite-layouts/docs/proposals/3d-layout.md`.)*

## Notes

- **Managers-create-sub-users gotcha** (was "Open"): resolved by SM095's explicit
  model - `create_sub_users` is a per-group capability, granted deliberately, not
  implied by manager membership. The Users/Groups UI makes it visible.
- The `manager_groups` config field was removed from the Config page (0.5.31):
  Manager-UI access is the `ui` channel capability on a group, and only
  `lazysite-admins` (which already has `ui`) needs it across sites. `manager_groups`
  remains a backend-only fallback in `lazysite.conf` (preserved on config save;
  set it there if ever needed) - it is just no longer edited in the UI.
- Every issue from the live Claude.ai / ChatGPT connector reviews (UTF-8,
  front-matter quotes, multi-word `select:`, fenced-div Markdown, tool discovery,
  in-channel verify, etc.) is closed as of 0.4.16.
- 0.4.54-0.4.57 (not SM-tracked): `?v=<version>` asset cache-buster; blank-editor
  fix (auth-sync injected before the real `</body>`, with regression test); nginx
  reload on deploy made opt-in (`LAZYSITE_RELOAD_NGINX`).
- 0.4.58-0.4.67 (not SM-tracked): **Appearance page** (manager "Themes" renamed;
  active layout/theme switcher moved off Config; manager nav/title naming
  standardised); **per-layout install/delete** from a manifest catalogue over the
  UI, control API and MCP (`layout-install`/`layout-delete`/`layouts-manifest`,
  `install_layout(update:true)`); **stats v2** (see SM083); **content components
  (D035)** - layout-owned `components/*.tt` invoked from Markdown via fenced
  `::: name` blocks or front-matter `sections:`, plus a `markdown` TT filter
  (bundled into the layout zip and installed on a site).
- 0.5.26-0.5.28 (not SM-tracked): the manager admin bar sits in normal flow (no
  longer overlaps a theme's sticky header); the login form is theme-token adaptive.
- New partner-build reports land in `lazysite-sites/reports/` and refresh SM080.
