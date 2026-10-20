---
id: SM1118
title: "SM1118: a site can be put into maintenance"
subtitle: "One switch sends every visitor's page request, by temporary redirect, to a maintenance page that answers 503; an account holding the new access-during-maintenance capability gets through, and the machine doors and posted forms follow the same capability."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17
area: core
status-note: "SHIPPED (PENDING) on n706: maintenance / maintenance_page / maintenance_until, per domain or instance, in the processor gate; capability maintenance_access (operator group and site-admins, upgrade adds the bundle); MCP, API, WebDAV, data, forms follow it."
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

# Rulings

The release manager ruled on 2026-10-20 (rulings-2026-10-20, "#338"):

> - Q1 **302 to the page, the page answers 503 with Retry-After** (as proposed).
> - Q2/Q3 **"Operators get through, add capability - access when in maintenance,
>   which can be assigned as desired, add to sysops."** A new capability (access
>   during maintenance), assignable to any group, granted to sysops by default.
>   Without it a request is sent to the maintenance page. The machine doors (MCP,
>   control API, WebDAV) were NOT ticked to stay open: they follow the same
>   capability (a caller without it is refused 503), unless the RM says otherwise.
> - 0.15.16 open point 1 (rulings-2026-10-20): **"site-admins also gets the maintenance
  capability: yes"** - so the role holds it as well as the operator group; see the
  capability bullet below.
- Q4/Q5 **Per domain (an instance switch covers all); a form posted during
>   maintenance is refused** with the maintenance message, not stored.

# What shipped

- **Settings** in lazysite.conf, on the Config page (group Maintenance):
  `maintenance: on|off` (anything but `on` reads as off; the Config page stores
  only `on` or `off`); `maintenance_page:` a path on the site or an `https://`
  address (default `/maintenance`; a value that is neither is not redirected to
  and the default is used); `maintenance_until:` a UTC time (`2026-11-01 18:30`),
  shown to visitors and turned into `Retry-After` (an hour when unset or past).
- **The page** `/maintenance` is a system page in the SM201 fallback chain
  (`lazysite/templates/system/maintenance.md`, shipped; a site restyles it by
  writing its own `maintenance.md`, which wins), so a deleted copy heals.
- **Every page request** from anyone who does not hold the capability is a 302
  (`Cache-Control: no-store`) to the page, with `?from=<address>` so a page of the
  site's own can link back. The maintenance page answers **503 with Retry-After**
  and no-store, however it was reached (fresh render or cache hit). A request that
  is not a GET or HEAD is refused 503 with the message, not redirected.
- **The capability** `maintenance_access` ("Access during maintenance") is in
  `@CAP_KEYS`, the capability map, the Groups and Users grids, and `lazysite
  check`'s list. A manager (operator) group is topped up with every capability, so
  the operator group holds it on a new site and, by the SM645 top-up, on an
  upgraded one; an explicit decline (0) stays declined. Any group can be given it.
  **Who holds it by default** (ruled 2026-10-20, 0.15.16 open point 1: "site-admins
  also gets the maintenance capability: yes"): the operator group, and the
  `site-admins` role through a `cap-maintenance` bundle (assignable 0,
  `maintenance_access` 1) that site-admins draws on, as it draws on `cap-tidy`; no
  other shipped role. A fresh site is seeded with the bundle. Bundles were written
  only when a site's group settings were first created, so a bundle added later
  reached new installs only; `_adopt_added_bundles` (tools/lazysite-users.pl, run by
  `_ensure_groups_seeded`, i.e. the next ordinary use of the users tool or a manager
  read) now adds `cap-maintenance` and its nesting to an existing site that has
  site-admins as a shipped group. It adds only when the bundle is absent, never
  rewrites a group, and writes the nesting only with the record, so an operator who
  takes site-admins out of the bundle keeps it out. A site with no shipped
  site-admins gets no bundle.
  A request that holds it browses as normal under a banner saying the site is in
  maintenance (injected per request, never cached).
- **The machine doors follow it** (ruling): MCP answers HTTP 503 with Retry-After
  and a JSON-RPC error `-32004` (kind `maintenance`); the manager / control API,
  for a token or a cookie, a JSON 503 `{ok:false, kind:"maintenance", error,
  retry_after}`; WebDAV a plain 503 for every method, OPTIONS included. The
  credential is asked first (a wrong password is still a 401). Discovery
  (`initialize`, `tools/list`) acts on nothing and stays open.
- **Forms** (ruling): the form handler refuses a post with the maintenance
  message ahead of the rate limiter, uploads and every delivery, and stores
  nothing; the no-JavaScript redirect carries the code `maintenance`, the page
  prints the sentence from its closed table. A verified session holding the
  capability posts as before. The data endpoint answers 503 JSON like the other
  doors.
- **Reachable always**: the maintenance page, `/login /logout /forgot /claim` and
  the configured sign-in address, `/lazysite-assets/`, presentation assets
  (css, js, images, fonts), `/.well-known/`, `robots.txt`, `favicon.ico`, and the
  wrapper's own `?action=` requests (sign in, sign out), so an operator can sign
  in to get through.
- **Per domain, instance switch covers all** (ruling): `maintenance: on` puts
  every host in maintenance; `alias.<host>.maintenance: on` puts one declared host
  in (with `alias.<host>.maintenance_page` and `.maintenance_until` of its own);
  an alias line cannot take its host out of the instance switch. Set on the
  Domains page (a Maintenance section in the editor, not offered on the create
  sheet) or `domain-set`.
- **No self-lockout**: switching maintenance on (Config page or a domain) needs
  the capability on the account doing it, or the next request would be refused and
  only the host could undo it. Off needs nothing more.
- **Audit and the health check**: a switch change is a `config-set` row naming the
  key, as every config change is. `lazysite check` warns while it is on, naming
  the instance or the domains and the time it is expected back, and names a value
  the engine would read as off and a maintenance page that does not resolve.

# Placement (departs from the filing as first written)

The first draft put the check beside the bad-URL guard in lazysite-auth.pl. SM1181
moved identity into the pool worker: a signed-in page there is rendered in the
worker as a value and an anonymous page never meets the wrapper, and the split
FastCGI templates send a visitor with no cookie straight to the processor. A check
in the wrapper would be skipped by all of those. It sits in the processor's
`main()` (`_maintenance_gate`, lazysite-processor/gates.pm), after the trust gate
and asked of the one identity reader every other gate asks, so it holds on plain
CGI behind the wrapper, on the split templates and in the one-rule pool. The
decision itself - on or off for this host, the page, the time, what stays
reachable - is `Lazysite::Maintenance`, one function every door and `lazysite
check` ask.

# Tests

t/unit/auth/71 (the decision), t/unit/auth/72 (the capability, fresh, upgraded,
declined, assignable), t/integration/315 (page requests through the real wrapper
and straight to the processor), 316 (a real FastCGI worker with the front door
on), 317 (control API, cookie and token), 318 (MCP), 319 (WebDAV), 320 (a posted
form, the data endpoint), t/unit/manager/385 (Config and Domains pages and the
lockout guard), t/unit/tools/87 (the health check), t/integration/321 (a site-admins
member gets through and a content-editors member does not, on a fresh site and on an
existing one after the upgrade step; an edited group and an operator's removal are
kept; a site without the role layer gets no bundle), t/integration/128 (the upgraded
fixture gains the bundle).

# Not done

- A file the web server serves by name (an image or a cached page asked for by its
  `.html` name, a legacy static page) is not a page request and never reaches the
  engine; it is not redirected. The same limit every access rule outside an ACL
  store has.
- The OAuth endpoints and the Odoo endpoint are not gated; they are sign-in
  flows and a connector's own transport, not content doors.
- A site with no accounts has nobody who can hold the capability: maintenance
  there closes it to everyone until the switch is turned off in the file.
