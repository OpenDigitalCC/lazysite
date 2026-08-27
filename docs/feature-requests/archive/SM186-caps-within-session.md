---
title: "SM186 - Capabilities apply within the session + capability discoverability"
subtitle: "Fix: a manager page was cached, so a just-granted capability didn't reflect until re-login; plus a grant-to-enable hint for gated areas"
brand: plain
status: shipped
status-note: "v1 built on claude/manager-cache-and-discoverability (auth: manager pages never cached; a Domains grant-to-enable nav hint). The FOLLOW-UP - generalise the grant-to-enable hint beyond Domains - was delivered by SM191: starter/lazysite/manager/layout.tt now shows a muted locked hint (linking to Groups, with an enable-it tooltip) for EVERY capability-gated nav area a grant-capable operator lacks - Files (manage_content), Navigation (manage_nav), Appearance (manage_themes/manage_layouts), Domains (manage_domains) and Audit log (audit); the processor surfaces all those caps in manager_caps. Covered by t/unit/processor/28-domains-nav.t (locked Files/Navigation/Appearance/Audit hints + the non-granting user sees none). Nothing outstanding."
---

# SM186 - Capabilities apply within the session

## The bug

An operator granted `manage_domains` to their group but the **Domains** nav entry
never appeared - it seemed to need a re-login. Groups are re-resolved per request
(SEC-2026-07 M5) and capabilities are read live from `groups-settings.json`, so a
grant *should* take effect immediately. It did not, because:

A page with `auth: manager` was **not flagged protected** for caching. The cache
guard only marked a page protected when `auth_level eq 'required'`, but a manager
page's level is `manager`. So the manager page's **server-rendered shell was
written to, and served from, the shared `.html` cache**. That shell embeds the
per-user, capability-gated nav (the Domains link is gated on
`manager_caps.manage_domains`), so:

- the cached menu ignored a just-granted capability until the cache was busted
  (the "re-login" symptom - the AJAX-loaded content was always live, only the
  server-rendered menu was stale); and
- worse, the cache is **global**, so one user's capability-gated menu could be
  served to another (a UI capability-leak; the API still enforced).

## The fix

Treat **every** non-public auth level as protected, not only `required`:

```perl
$auth_protected = 1
    if $auth_level ne 'none'
    || ( $auth_peek->{groups} && @{ $auth_peek->{groups} } );
```

A protected page is never written to nor served from the `.html` cache, so a
manager page re-renders every request - the menu reflects the current capability
set immediately, within the session, no re-login. Public (`auth: none`) pages
still cache. Covered by `t/integration/16-manager-page-nocache.t` (a manager page
leaves no `.html`; a public page still does).

## The discoverability hint

The same episode showed a discoverability gap: a gated area is simply *absent*
from the nav, with no clue it exists or how to enable it. When a user **can grant
capabilities** (`manage_users`) but lacks `manage_domains`, the nav now shows a
muted, locked **"Domains &#128274;"** entry that links to the **Groups** page with
a tooltip: *"Serve additional domains from this instance. To enable it, grant
'Domains & site packages' to a group on the Groups page."* A user who cannot grant
capabilities sees nothing (the hint would be pointless). `manager_caps` now also
surfaces `manage_users` so the nav can gate the hint. Covered by
`t/unit/processor/28-domains-nav.t`.

## Follow-up (delivered by SM191)

The grant-to-enable hint is no longer Domains-specific. `manager_caps` surfaces
`manage_content`, `manage_nav`, `manage_themes`, `manage_layouts`,
`manage_domains` and `audit`, and `starter/lazysite/manager/layout.tt` renders a
muted, locked entry - linking to the Groups page with an "how to enable it"
tooltip - for every one of those areas a grant-capable operator (`manage_users`)
currently lacks. A user who cannot grant capabilities still sees nothing. So any
area a grant-capable operator could unlock is discoverable rather than silently
missing. Covered by `t/unit/processor/28-domains-nav.t`.
