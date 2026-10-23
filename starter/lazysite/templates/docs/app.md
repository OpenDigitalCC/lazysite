---
title: Installing a site as an app
subtitle: A site, or one section of it, installs on a phone or tablet as a progressive web app, from a few settings.
register:
  - sitemap.xml
---

## Overview

A site can be installed from the browser's menu and opened from the home screen
in its own window, without an address bar. Lazysite generates the two documents
a browser needs for that - the **web app manifest** and the **service worker** -
from settings in `lazysite.conf`. Nobody writes either one, and nothing is put
under `/lazysite-assets/`.

The app can be the whole site (scope `/`) or one section (a scope under a
path, such as `/portal/`). A domain with its own settings can be its own app.

## Settings

Set `app_name` and the site is an app. Leave it out and there is no manifest,
no worker, and nothing added to any page.

```
app_name: Example Portal
app_short_name: Portal
app_theme_colour: #0a5c36
app_background_colour: #ffffff
app_scope: /portal/
app_start_url: /portal/
app_icon_64: /icons/app-64.png
app_icon_192: /icons/app-192.png
app_icon_512: /icons/app-512.png
app_icon_maskable: /icons/app-maskable.png
app_offline_pages: /portal/, /portal/new
app_update: wait
```

These can also be set without shell access, on the manager's Config page under
"Install as an app" (or by config-set). A value the app would be turned off
for, or an icon the site does not serve, is refused when you save, naming the
setting.

`app_name`
: The name under the icon and in the install prompt. Setting it turns the app
  on.

`app_short_name`
: The name where space is short. The default is `app_name`.

`app_scope`
: The section the app covers, as a path that starts and ends with `/`. The
  default is `/`, the whole site. Pages inside the scope are part of the app;
  a link outside it opens in the browser.

`app_start_url`
: The page the app opens on. It must be inside the scope. The default is the
  scope.

`app_theme_colour`, `app_background_colour`
: `#rgb` or `#rrggbb`. The first colours the window frame, the second the
  splash screen. A value that is not a hex colour is left out.

`app_icon_64`, `app_icon_192`, `app_icon_512`, `app_icon_maskable`
: Paths of image files the site serves (png, webp, svg or jpg). The maskable
  icon should be 512 by 512 with its picture inside the central safe zone. The
  engine does not make icons. An icon whose file is not there is left out of
  the manifest, and `lazysite check` names it.

`app_shell`
: Extra files to keep on the device, as a comma-separated list of site paths.
  Optional; see "What the device keeps".

`app_offline_pages`
: Pages the app keeps so it opens with no connection, as a comma-separated list
  of site paths, each inside the scope, such as `/portal/, /portal/new`. See
  "Pages that open offline". Optional; none by default.

`app_update`
: `now` (the default) or `wait`. See "How an update reaches an installed app".
  Any other value turns the app off.

A scope or start page the engine cannot honour turns the app off instead of
being corrected: a scope of `portal` is not quietly read as `/portal/`.
`lazysite check` names the value.

On a domain declared with `alias_hosts`, each of these can be set per domain as
`alias.<host>.app_name:` and so on.

## What is generated, and where

| Address | What it is |
|---|---|
| `<scope>manifest.webmanifest` | The manifest, served as `application/manifest+json`. |
| `<scope>lazysite-sw.js` | The service worker, served as `text/javascript`. |
| `/assets/lazysite-app.js` | A small shipped script that registers the worker. |

Both documents live inside the scope, which is why no `Service-Worker-Allowed`
header is sent. A page inside the scope gets a `<link rel="manifest">` and the
registration script; a page outside it gets nothing. If a file really exists at
one of those addresses, the file wins.

Pages already rendered are cached by the engine: after turning the app on,
invalidate the page cache so the pages carry the link.

## What the device keeps

The worker keeps the **app shell** - the files every page of the app needs - and
only the pages you list in `app_offline_pages`. Without that list it keeps no
page, and an installed app started with no signal shows the browser's offline
error instead of the app.

Precached at install
: The engine's chrome (`/assets/lazysite-chrome.css`, `lazysite-chrome.js`),
  the registration script, the icons, the stylesheets and scripts the start
  page links (read from its rendered copy), and anything in `app_shell`.

Stale-while-revalidate
: Any other stylesheet or script: the kept copy is used at once and the file is
  fetched again behind it for next time.

Cache-first
: Images: the kept copy is used, and the network only when there is none. An
  image replaced under the same name stays old on a device until the next
  release; give a changed image a new name.

A listed page
: Network first. The person is shown what the network sent, a copy is kept
  behind it, and the copy opens the page when there is no network. See "Pages
  that open offline".

Everything else
: Not touched. Every page that is not listed goes to the server as it would
  without a worker.

The worker **never** handles the Odoo endpoint, the manager, the sign-in and
sign-out paths, the other `lazysite-*.pl` endpoints or the engine tree, and it
reads or stores no cookie, token or answer. It honours the server: a response
sent `Cache-Control: no-store` or `private` is never kept, and a copy kept
earlier of a file that now says so is deleted. There is no offline queue,
background sync or push.

## Pages that open offline

List the pages the app must open with no signal in `app_offline_pages`. A page
qualifies when it is **the same for every visitor**; the worker keeps the page as
a signed-out visitor receives it, so a person's own data belongs in what the page
fetches as it runs, not in the page.

What the engine accepts, and how it tells
: A page that exists inside the scope with none of these. The manager refuses a
  page that has one when you save, naming the page and the reason, and the
  engine leaves it out of the worker even if the file was edited by hand.

  - `auth` other than `none` (or the site's `auth_default`), `auth_groups`,
    `payment`, `addresses` or `addresses_deny`, or an access key the engine
    cannot read: the page is gated.
  - A read list, address list or draft section in the access store that covers
    the page.
  - `odoo-identity:` or `db:...(mine)` in the front matter: the page shows the
    viewer.
  - `nocache: true`, `api: true` or `raw: true`: rendered fresh, or data.
  - A path that is the Odoo endpoint, `/cgi-bin/`, any `lazysite-*.pl`, the
    manager, the sign-in and sign-out paths or `lazysite/`.

A page with an `odoo:` binding
: Qualifies. The engine runs an `odoo:` binding in a page only when it takes no
  visitor key and no Odoo sign-in, so the page is the same for everyone;
  anything personal comes from the Odoo endpoint while the page runs, which the
  worker never touches. A binding of the viewer's own, `odoo-identity:`, is the
  one that makes a page per viewer, and it is refused.

How the worker keeps one
: It fetches the page itself, **without credentials**, and keeps the answer only
  if it is a plain 200 that is not `Cache-Control: no-store` or `private`, not a
  redirect (a protected page sends an anonymous visitor to sign-in) and has no
  `Set-Cookie` that a script can see. The page a signed-in person receives is
  never the one kept. A page that later turns protected deletes its own copy at
  the next visit. A browser hides `Set-Cookie` from a worker, so the guard that
  matters is the request without credentials; a page that sets a cookie for
  everyone is not a candidate and should not be listed.

When there is no copy
: A listed page that was never loaded online is not on the device, and the
  browser shows its offline error. The worker fetches the listed pages when it
  installs, so a page that may be kept is there after the first visit.

A page may carry a form, or a template that asks the visitor's address; the
engine sends those `no-store, private`, and the worker then keeps nothing.

The worker's keeping fetch sends `X-Lazysite-App: keep`, and the visitor log
records it as the app keeping its copy, not as a visitor: it is counted apart as
`app_hits` in a day's figures, and the page is not counted twice. The person's own
visit does not send the header and is counted as ever. Someone who sends the header
by hand only hides their own request from the visitor count.

## How an update reaches an installed app

The worker's cache name is built from the installed release, a fingerprint of
the shell files and the list of offline pages. A deploy that changes any of them
changes the worker's text; the browser notices on its next check and installs
the new worker, and the old cache is deleted.

`app_update: now` (the default)
: The new worker takes over at once (`skipWaiting` and `clients.claim`). Nothing
  is done on the device. This is what the app did before the setting existed.

`app_update: wait`
: The new worker waits. Pages already open keep the old version until the page
  asks, so a form being filled in is not swapped under the person.
  `lazysite-app.js` then fires a `lazysite-app-update` event on `window` when a
  new version is ready; `event.detail.apply()` tells it to take over, and the
  page reloads once. Without a listener the update is applied when every window
  of the app has been closed and the app is opened again.

```
window.addEventListener('lazysite-app-update', function (e) {
  if (confirm('A new version is ready. Reload?')) e.detail.apply();
});
```

A page that adds its listener late reads `window.lazysiteApp.apply`, which is set
while an update waits. Calling it posts `skip-waiting` to the new worker.

## When the app does not install

The worker needs a secure context: https, or `localhost`. A phone on
`http://<lan-ip>:port` never registers it and is never offered the install; that
is the browser's rule, not a setting. To try an app from a dev server, use https
or reach it through `localhost` (for example with a port forward).

`lazysite-app.js` writes a console warning, beginning `lazysite-app:`, when the
worker does not register: a 404 (the app is off, the scope is not the page's
directory, or the page cache predates turning the app on), a script error, or an
insecure origin. A site whose `/assets/lazysite-app.js` is missing, because its
`assets/` predates the feature, cannot warn: the browser reports the missing
script in its network panel.

## Checking it

`lazysite check` reports the app's declaration: a bad scope or start page, a
colour that is not hex, an icon the site does not serve, and an app with no
icons at all. In a browser, the developer tools' Application panel shows the
manifest, the registered worker and the cache.
