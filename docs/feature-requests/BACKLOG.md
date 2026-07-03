---
title: "Feature-request backlog (index)"
subtitle: "Status at a glance; see each SMxxx doc for detail"
brand: plain
---

One-line status for every feature request. Updated 2026-07-03. Status derived
from the CHANGELOG (shipped releases) and corroborating code, not the per-doc
text.


## Ideas - not yet scoped

Discrete items expanded from the raw wishlist; each needs its own scoping doc
before work starts.

- **Plugin packaging / separation** - split plugins from the core tree so they
  can be added, removed, or uploaded independently: a plugin becomes a
  self-describing unit installed/uploaded like a theme, rather than living in the
  core checkout. Includes documenting the plugin interface so new plugins are
  simple to implement.
- **Status page** - collect monitoring data into JSON files, render it on screen,
  and derive a current-status view (meta information) from it.
- **Form-fill notifications over XMPP** - notify about form submissions (and
  similar events) through an XMPP bot (the same integration Claude Code uses),
  wired to the notification system; per-user / per-system, with the user choosing
  the target. Extends the SM113 notification stack.
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

- **Eight-dimension review follow-up (2026-07-01, v0.5.35)** - full review at
  `docs/review/2026-07-01-eight-dimension/` (verdicts: D1-D4 + D7-D8 WARN,
  D5 + D6 REFUSE). Application-side actions proceed in the current cycle;
  **operational items are HELD for pre-launch** and documented with owners and
  triggers in `docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`
  (SLO/RTO/RPO declaration, snapshot crons, logrotate, monitoring/alerting,
  debsecan + gitleaks installs, pentest gate + engagement, support period,
  signing/DoC/VEX/technical-file set).
- **~~manager-api branch coverage to 60~~** *(done 2026-07-03)* -
  `t/unit/manager/23-manager-read-actions.t` added coverage for five
  previously-untested actions (pages, config-read, principals, notices,
  notices-seen); the branch measurement rose to 80.7% and the floor override was
  raised 55 -> 60 (the review target). Residual subprocess-merge variance remains
  (backlog: subprocess-coverage stability); the override carries a dial-back note
  if a gate ever flakes near 60.
- **SM126** Partner-agent onboarding & capability discoverability *(scoped -
  see `SM126-agent-capability-discovery.md`; prompted by real partner-agent
  feedback 2026-07-02)* - a connecting agent currently has to reverse-engineer
  what it is allowed to do and how; one agent spent a long time discovering by
  trial and error that it installs themes over WebDAV, because the push failed
  without telling it why. The failure-message half is done (RI-002); the scoping
  doc phases the rest (capability-map endpoint derived from `@CAP_KEYS`/`%need`/
  `%TOOLS`, quickstarts, private-file boundary, host-OS dependency list) and
  flags three ground-truth findings to fold in (whoami cap-list drift, hard-coded
  grid arrays, api/mcp not gated at transport). Four threads:
    - **Host-OS dependency list** - publish an explicit, agent/operator-readable
      list of the host packages lazysite needs (Debian package names), derived
      from `dist/config/sbom-deps.json` (which already carries the data) and from
      the dev server's own module-check apt hints, so "what must I install" is a
      document, not a discovery exercise. Surface it in IMPLEMENTOR.md and,
      ideally, via an API/CLI `dependencies` query.
    - **Machine-parseable capability map** - the biggest ask. Expose the full
      channel x action model (what each capability unlocks, which endpoint / MCP
      tool / DAV path serves it, and what an account currently holds) as a
      hierarchy an agent can fetch and traverse - e.g. a `capabilities`
      introspection action / MCP tool returning the grant graph, plus a rendered
      flowchart/hierarchy in the docs. Pair it with **actionable failure
      messages**: when a WebDAV or API write is refused for a missing capability,
      say which capability is needed and where it is granted, rather than a bare
      403/failure (the theme-install trial-and-error was this gap).
    - **Theme & layout quickstarts** - short, task-focused onboarding guides that
      put an agent on the sanctioned path (WebDAV / API / MCP) fast: "install a
      theme", "author a layout", "activate it" - each a copy-pasteable sequence,
      not prose scattered across SECURITY/FEATURES/IMPLEMENTOR.
    - **Sanctioned-surface guardrail** - steer agents away from editing the
      processor or other engine files as workarounds and toward MCP/DAV/API. Make
      the boundary legible: prefix private/engine files and folders with `_`
      (an underscore convention that reads as "do not touch"), and document the
      supported surface explicitly. Connects to the capability map + clear
      failures above - agents hack around the engine when the sanctioned path
      fails opaquely.
- **Bad-URL auto-blocker plugin (default on)** - a plugin that recognises the
  steady stream of vulnerability-scanner probes (`/wp-login.php`, `/.env`,
  `/config.env`, `/actuator/health`, `/server-status`, `/.git/`, `*.php` on a
  markdown site, etc. - all already classed as "noise" by the stats classifier)
  and auto-blocks the source IP after N hits in a window. Maintains the bad-URL
  pattern list (built-in + operator additions), records every block (IP, pattern,
  count, time) for review, and exposes a small manager panel (current blocks +
  unblock). Enabled by default. Reuse the stats noise-path heuristics as the seed
  list. (Prompted by scanner traffic hitting a fresh site within minutes of going
  live.)
- **SM085** Git backend / changesets *(design)* - `begin -> diff -> commit ->
  rollback` on a git-versioned docroot. Biggest remaining lever; adds the
  rollback safety net. Headline ask from both AI-partner reviews.
- **SM096** "Migrate to local" - one click to fetch a `.url` page's body and
  take local ownership as `.md`.
- **SM098** Multi-page / wizard forms (Next / Back, per-step validation).
- **SM103** Recent-change markers - "changed recently" dots on nav/users/files;
  the visible tip of a streaming audit-trail layer.
- **SM110** Domain aliases - an additional host serving the same site with its
  own theme / nav / name.
- **Sessions page - list + control active sessions** - the Sessions page exposes
  only "log out everyone" (rotate the auth secret). List active sessions of all
  types with detail (who / where / when / last seen), a per-session log-out
  button, and a disable-account action, each linking to the user and to the audit
  log. Individual sessions should be visible and ideally revocable.
- **Manager log-out control** - a Sign out control in the manager UI shell (the
  admin bar carries one, but the manager chrome itself should too).
- **Audit timestamps in local time** - show audit times in the detected local
  timezone, falling back to UTC.
- **~~Files: duplicate a page~~** *(done 2026-07-03)* - a "Duplicate…" action on
  the files list; `action_copy` copies the file + `.brief` (not the `.html`
  cache), the duplicate is owned by its creator.
- **theme_assets fallback on no active theme** - when a layout is previewed or
  set per-page with no compatible active theme, `theme_assets`/`theme_css` are
  empty and the page renders unstyled. Fall `theme_assets` back to the layout's
  `default_theme` mirror (if installed) so preview looks right without every
  layout needing its own `[% ELSE %]` fallback link.
- **Remote-layout content components** - `install_layout` + fenced/sections
  components are local-layout only; remote (URL) layouts fetch just `layout.tt`,
  so their `components/` are not fetched or resolved. Bundle + resolve components
  for remote layouts if remote layouts get more use.
- **Visitor statistics - performance + visualisations** - the in-page stats scan
  is still synchronous and re-reads the whole log each load (the *AI export* path
  now has an incremental per-day-bucket cache - reuse it for the page). Remaining:
  point the manager Stats page at the cache, and add visualisations (charts for
  the per-day trend, the class breakdown, referrers).
- **AI audit export - point the in-page view at a cache** - the audit trail is
  already exposed as sanitised JSON via the control-API `audit` action (gated on
  its own `audit` capability since 0.5.25). Remaining: give it the same
  append-only incremental cache the visitor-stats export uses, and point the
  in-page Audit view at it.
- **install.pl: set/override the update channel** - `install.pl` already *reads*
  the site's `update_channel` (via `--channel-check`, ADR 0005) but cannot set
  it. Add `--channel edge|stable` to write/override `update_channel:` in
  `lazysite.conf` at install or upgrade time, so a deployment can be pinned to
  stable (or moved back to edge) from the installer without hand-editing the
  conf. Small: reuse `read_update_channel` + the seed/conf-write path; validate
  the value; record the change. Pairs with the release-channel model.


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
