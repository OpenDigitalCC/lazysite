---
id: SM1197
title: "SM1197: an installed app opens without a connection"
subtitle: "App pages named in app_offline_pages are kept for offline use, a new version can wait for the page, and lazysite-app.js says why a registration failed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-an-installed-app-cannot-open-offline.md (OOM Lab agent)
area: front end
status-note: "SHIPPED (0.15.13) on n689: lazysite-processor/app.pm, starter/assets/lazysite-app.js, lib/Lazysite/Manager/Config.pm, starter/manager/config.md, starter/docs/app.md; t/unit/processor/145, t/unit/manager/368."
---

# What happened

The OOM Lab agent, making the lab's expense section an installable app on the
settings of SM1155, filed (19 October 2026):

> The generated worker keeps the app shell and never a page, as `docs/app.md`
> says it is designed to. So an installed app started with no signal shows the
> browser's offline error instead of the app. Every script and stylesheet is on
> the device, but the page that loads them is not. The design system the owner
> uses for these apps makes "the app always opens, even offline" its first rule.

and asked for three things:

> - **An opt-in for pages that are the same for every visitor**, for example
>   `app_offline_pages: /portal/, /portal/new`. The worker would keep those pages
>   network-first with a kept fallback, under the rules the worker already holds:
>   never `no-store` or `private`, never a protected page, never the endpoints. A
>   page with an `odoo:` binding qualifies when, like this one, all personal data
>   comes from the endpoint at run time.
> - **An update that waits for the page.** Today the generated worker takes over
>   at once (`skipWaiting`, `clients.claim`). Installed-app guidance is to offer
>   "Reload" and never reload over unsaved input. A setting, or a `skip-waiting`
>   message as here, would let a page hold the update until its form is saved.
> - **`lazysite-app.js` should not stay silent on failure.** It ends with
>   `.catch(function () {})`, so a registration that fails (a 404, a script error,
>   an insecure origin) leaves no trace even in the console. [...] A
>   `console.warn` with the reason would be enough.

and noted that "a phone on the LAN at `http://<host>:8090` never registers one",
which `docs/app.md` could say next to the settings.

# What shipped

`app_offline_pages`
: A comma-separated list of site paths, in `lazysite.conf`, on the Config page and
  in the config-set allow list. The worker keeps each network first and opens the
  kept copy with no signal. Each path must be inside `app_scope` and a real
  Markdown page. A path that is not is refused at save, naming the path and the
  reason; the engine leaves it out of the worker as well, so a hand edit cannot
  list it.

What decides that a page is the same for every visitor
: The engine's own readers. `app.pm` (`_app_page_fault`) asks `_peek_md`, the
  gate's front-matter reader, and `_acl_governed`, the render path's answer for
  the access store; the manager restates the rules (`_app_offline_page_fault`,
  because it loads nothing from the processor) and t/unit/manager/368 runs the
  same pages through both. A page is refused when it has `auth` other than `none`
  (or the site's `auth_default` is not `none`), `auth_groups`, `payment`,
  `addresses`, an access key the engine cannot read, `odoo-identity:` or
  `db:...(mine)`, `nocache: true`, `api: true` or `raw: true`; or a read list, an
  address list or a draft section in the access store covers it; or the path is
  the Odoo endpoint, `/cgi-bin/`, a `lazysite-*.pl`, the manager, the sign-in or
  sign-out path, or `lazysite/`.

A page with an `odoo:` binding
: Qualifies, and the engine can tell why. `resolve_odoo` runs a binding in a page
  only when it permits public and takes no visitor key and no Odoo sign-in
  (sources.pm); what it puts in the page is the same for every visitor and is
  already cached as one shared render. What is personal reaches the page from the
  Odoo endpoint at run time, which the worker never touches. The one binding that
  makes a page per viewer, `odoo-identity:`, is on the refuse list. The source
  text cannot show whether a page's script reads personal data from the endpoint,
  so that part stays the author's: the rule is that personal data comes from the
  endpoint, and the docs say so.

How the worker keeps a page, and why a signed-in visit cannot leak into it
: The worker fetches the page itself, without credentials, and keeps the answer
  only if it is a plain 200 that is not `no-store` or `private`, not a redirect
  and without a visible `Set-Cookie`. What the person is shown is what the
  network sent them; what is kept is the anonymous fetch, so it cannot hold
  anything a signed-in request received. A redirect (what a gated page sends an
  anonymous visitor) is never kept, and a page that later turns protected deletes
  its copy at the next visit. The engine marks per-viewer responses itself:
  gated, form and per-viewer pages go out `no-store, private`, and the worker
  honours it. A browser does not let a worker read `Set-Cookie`, so the check is
  made where it can be (the header is read when a runtime shows it) and the
  request without credentials is the guard that matters. The path table that keeps
  the endpoint, `/cgi-bin/`, the manager, `lazysite/`, WebDAV and anything but GET
  out of the worker is checked before the page list, so a list that named them
  would still not be answered (t/unit/processor/145 edits the generated list to
  prove it). The kept pages are part of the cache name, so a page taken off the
  list loses its copy.

`app_update`
: `now` or `wait`. The default stays `now`, today's behaviour: an installed app
  built on SM1155 keeps taking over at once, and `wait` without a page that
  listens would hold an update until every window is closed, which is a change an
  existing app should choose. With `wait` the worker no longer calls `skipWaiting`
  at install, listens for a `skip-waiting` message, and `lazysite-app.js`
  dispatches `lazysite-app-update` on `window` when a new worker is waiting
  (`detail.apply()` posts the message; the page reloads once, and only for a swap
  it asked for). Any other value turns the app off, as a wrong scope does.

`lazysite-app.js`
: Warns in the console, beginning `lazysite-app:`, when the registration fails (a
  404, a script error, an insecure origin, named from the browser's message) and
  when the browser offers no service worker (naming the secure-context rule when
  the origin is insecure). A registration that works stays silent.

Docs
: starter/docs/app.md covers all of it, including that the worker needs a secure
  context (https or localhost) and that a phone on `http://<lan-ip>:port` never
  registers it.

Not done
: `lazysite check` does not yet report the two new settings. Per-domain override
  is supported (`alias.<host>.app_offline_pages`).
