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
```

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

The worker keeps only the **app shell** - the files every page of the app
needs - and never a page.

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

Everything else
: Not touched. Every page, including any with an `odoo:` binding, any page for
  one viewer, and every protected page, goes to the server as it would without
  a worker.

The worker **never** handles the Odoo endpoint, the manager, the sign-in and
sign-out paths, the other `lazysite-*.pl` endpoints or the engine tree, and it
reads or stores no cookie, token or answer. It honours the server: a response
sent `Cache-Control: no-store` or `private` is never kept, and a copy kept
earlier of a file that now says so is deleted. There is no offline queue,
background sync or push.

## How an update reaches an installed app

The worker's cache name is built from the installed release and a fingerprint
of the shell files. A deploy that changes either changes the worker's text; the
browser notices on its next check, installs the new worker, which takes over at
once (`skipWaiting` and `clients.claim`), and the old cache is deleted. Nothing
is done on the device.

## Checking it

`lazysite check` reports the app's declaration: a bad scope or start page, a
colour that is not hex, an icon the site does not serve, and an app with no
icons at all. In a browser, the developer tools' Application panel shows the
manifest, the registered worker and the cache.
