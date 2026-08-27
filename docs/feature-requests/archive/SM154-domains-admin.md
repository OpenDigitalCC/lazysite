---
title: "SM154 - Domains admin: agency multi-domain management plane"
subtitle: "Register/configure/delegate the domains one instance serves, from the UI and CLI"
brand: plain
status: shipped
status-note: "delivered 2026-07-15 in 0.7.17 (P1-P3); builds the admin plane on the SM151 serving plane"
---

# SM154 - Domains admin

Model B (domain-scoped delegation) on top of SM151. One lazysite instance serves
many first-class domains; SM154 adds the admin plane to manage and delegate them
without shell access - while staying strictly on the lazysite side of a hard
line.

## The hard line (scope)

lazysite owns ONLY the lazysite side: registering a domain
(`alias.<host>.content_root` + presentation overrides in `lazysite.conf`) and
its content-root directory. DNS, the web-server domain alias and TLS are a
**precondition** handled by the operator / Hestia / an external orchestrator -
lazysite never touches them. This keeps lazysite from reaching into Hestia; a
future external control panel drives both (Hestia CLI + lazysite CLI) in one
deploy.

## Decisions

Admin-plane model
: **B - domain-scoped delegation.** A client account is bound to a domain and
  confined to it; the agency super-admin sees all. (A - config-only - and C -
  full per-domain pool isolation - were rejected for .17.)

Binding mechanism
: **Account attribute reusing dav_scope.** `dav_scope` = the domain's
  content_root (the confinement, enforced on every channel), `home_domain` = the
  host (the UI pointer). One confinement primitive (`path_out_of_scope`) across
  WebDAV, token/MCP and cookie.

Plugin vs core
: **Core.** The engine + CLI + confinement must be core (the CLI is needed for
  orchestration; confinement is a security control), and the Domains panel + nav
  entry already shipped read-only in SM151, so a plugin extraction would churn
  working code. Kept core; the panel is nav-gated to operators so single-site /
  non-config installs never see it.

Provisioning
: **lazysite side only.** No Hestia API, no vhost, no cert issuance from
  lazysite (explicitly out of scope - the earlier draft that reached into Hestia
  was wrong).

## Phases (all shipped in 0.7.17)

P1 - confinement spine (core)
: A domain-bound (`dav_scope`) cookie user is confined to their content_root on
  the interactive manager channel too, via the shared `_confine_scope` helper
  (the M2 primitive, now used by every channel). Operators are unconfined.

P2 - domain engine + CLI + control-API (core)
: `Lazysite::Manager::Domains` (add/list/set/remove; strict host + content-root
  validation; conf written in place to preserve site-user mode/group; remove
  keeps content unless `--purge`). `tools/lazysite-domains.pl` (scriptable CLI,
  `--json`, exit codes). Manager `domain-add`/`-set`/`-remove` actions,
  manage_config-gated and POST-only. End-to-end: a domain registered via the
  engine is served by the SM151 processor under its Host header.

P3 - panel + gated nav + auto-scoping (core)
: The Domains page becomes a full CRUD panel. The nav entry is gated on
  `manager_caps.manage_config`. A bound editor's `dav_scope`/`home_domain` are
  stashed by the processor and exposed as JS globals so the file browser roots
  at their own content_root. `home_domain` is a settable account key.

## Deferred (future rounds)

- Per-domain theme/layout/nav/forms authoring surfaces and per-domain
  analytics/audit views.
- A Users-page control to bind an account to a domain (currently the CLI /
  settings-set); pairing home_domain + dav_scope in one action.
- The manager-UI test guide (SM153) gains a `Domains` chunk.
- Full per-domain isolation (model C) if a hard tenant boundary is ever needed.
