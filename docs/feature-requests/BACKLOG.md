---
title: "Feature-request wishlist (unscoped ideas)"
subtitle: "The ideas that have no SM filing yet. For the status of everything that does, run tools/backlog.pl"
brand: plain
---

# What this file is, and what it stopped being

SM658: this was a hand-maintained status line for every feature request,
last updated 2026-07-10, deriving status "from the CHANGELOG ... not the
per-doc text". That made it a second source of truth about 500+ documents
that each already carry their own `status:` header, and it drifted - which
is the same defect SM654 filed against the hand-kept `unlocks` map.

**The status list is gone.** It is derived now:

```
perl tools/backlog.pl          # open work
perl tools/backlog.pl --all    # everything, including the archive
perl tools/backlog.pl --json   # the same, for tooling, with a relation graph
```

What remains below is the part no filing holds: **raw ideas that have never
been scoped into an SM document.** An idea that graduates gets a filing and
leaves this list.


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
- **Database plugin** - SUPERSEDED by [[SM410]] (typed data layer, audited
  2026-08-19). The sketch's per-visitor schemas (session, profile, basket) are
  what the settled boundary excludes; its TT read/write idea survives as the
  `db:` binding and `writable=` declaration with the trust direction fixed.
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
