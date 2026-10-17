---
id: SM1118
title: "SM1118: a site can be put into maintenance"
subtitle: "One switch sends every visitor's page request, by temporary redirect, to a maintenance page; the page's address can be set, and defaults to a page the site ships."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: release manager, 2026-10-17
area: core
status-note: "CANDIDATE, filed 2026-10-17. Core, not an extension (see 'Core or extension'). Five questions for a ruling before it is built."
---

# The request

The release manager, 2026-10-17: "site maintenance page - this runs temp
redirects on all pages to a pre-set maintenance page. the url can be set,
defaulted to internal page, and it can be an extension, or core site
depending on which is simpler."

# Core or extension

**Core is the simpler of the two.** An extension can declare config, actions,
endpoints and on_enable/on_disable hooks, but nothing an extension declares
runs on every request: there is no request hook. A maintenance extension
would first need one, which is a new mechanism for one feature, and every
request would then pay for asking whether any extension wants it.

Every page request already passes `lazysite-auth.pl`, where the bad-URL guard
(SM128) refuses a blocked address before anything else runs. A maintenance
check sits beside it: one read of a key from lazysite.conf (already read once
per request there), and a redirect. That is the whole engine change, plus a
shipped page and a Config page control.

# What it would do

- **Settings** in lazysite.conf, shown on the Config page:
  - `maintenance: on|off` (default off).
  - `maintenance_page:` the address visitors are sent to. Default
    `/maintenance`, a system page the site ships (`starter/maintenance.md`,
    resolved through the system-page fallback chain like /login, SM201), so
    a site can restyle it in its own layout. Any path on the site, or an
    absolute `https://` address elsewhere.
  - `maintenance_until:` optional, a time. Shown on the page and sent as
    `Retry-After`.
- **Every page request** from a visitor, while it is on, is answered with a
  temporary redirect (302, `Cache-Control: no-store`) to the maintenance page,
  carrying the original address so the page can link back afterwards. Nothing
  is cached: the redirect and the page are no-store, so turning it off takes
  effect at once.
- **Always reachable**, so the site can be repaired and switched back:
  the maintenance page itself, the sign-in pages, `/manager/`, the manager
  API, theme and site assets (`/lazysite-assets/`, so the page is styled),
  `/.well-known/`, `robots.txt`.
- **A signed-in operator** (the operator group) browses the site as normal,
  with a banner saying the site is in maintenance, so they can check a fix
  before reopening.
- **Audit**: switching it on or off is a `config-set` row naming the key, as
  every config change is. The health check (`lazysite check`) warns while it
  is on, so it is not forgotten.

# Questions for a ruling

1. **302 or 503?** The request says temporary redirects, and a 302 is what a
   visitor's browser follows. Search engines treat a 302 to one page as the
   site having moved; the convention for maintenance is the page served with
   `503` and `Retry-After`, which they treat as "come back later". Proposed:
   redirect (302) to the page, and the page itself answers 503 with
   Retry-After. Or a plain 302 and 200, as asked.
2. **Machine doors** (MCP, the control API, WebDAV): keep working during
   maintenance (an agent may be the one doing the work), or refuse with 503?
   Proposed: they keep working; only visitor page requests are redirected.
3. **Signed-in members** who are not operators: redirected like everyone
   else (proposed), or let through?
4. **Per domain** on a multi-domain instance: one switch for the instance, or
   one per domain? Proposed: per domain, with the instance switch covering
   all of them, because maintenance on one site of nine should not close the
   other eight.
5. **Forms**: a form posted during maintenance is refused with the
   maintenance message (proposed), not stored for later.

# Size

Medium: the check in the auth wrapper (and the processor, for a front that
reaches it directly), the shipped page, three Config fields, the health-check
warning, the bypass list, tests through the real wrapper. Per-domain (question
4) adds the domain lookup the wrapper already makes for other per-domain
settings.
