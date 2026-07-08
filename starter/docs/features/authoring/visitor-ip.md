---
title: Showing the visitor's IP
subtitle: A live [% client_ip %] variable and the nocache flag, cache-safely.
---

## Showing the visitor's IP

A page can show a visitor their own IP address. Two things make this work:

`[% client_ip %]`
: a Template Toolkit variable holding the visitor's IP. It is the first hop of the
  `X-Forwarded-For` header (the real client when the site is behind a reverse
  proxy) if present, otherwise the direct connection address `REMOTE_ADDR`.

`nocache: true`
: the IP is different for every visitor, so the page must render fresh each time.
  `nocache: true` in the front matter renders on every request and never caches, so
  each visitor sees their own IP (a cached page would show whoever loaded it first).

### Simplest: show it directly

A whole page that renders the IP live:

    ---
    title: Your IP
    nocache: true
    ---

    Your IP address is **[% client_ip %]**.

### Keep a page cached, fetch the IP with JavaScript

To show the IP on a page you want to keep cached (fast), put the IP behind a small
live endpoint and fetch it client-side. The endpoint is a `nocache` API page that
returns JSON; the display page stays cacheable and only the IP is fetched live.

The endpoint - save as `whatismyip.md` (served at `/whatismyip`):

    ---
    api: true
    nocache: true
    content_type: application/json
    ---
    {"ip": "[% client_ip %]"}

The display page (or any theme/layout) fetches and renders it:

    <p>Your IP address is <span id="your-ip">…</span>.</p>
    <script>
    fetch('/whatismyip')
      .then(function (r) { return r.json(); })
      .then(function (d) { document.getElementById('your-ip').textContent = d.ip; })
      .catch(function () { document.getElementById('your-ip').textContent = 'unavailable'; });
    </script>

### Behind a reverse proxy

`client_ip` prefers `X-Forwarded-For` so a proxied site reports the real visitor,
not the proxy. That header is only trustworthy if your edge (Apache / nginx) sets
it from the real connection and strips any client-supplied copy - the same
requirement as the `X-Remote-*` trust headers. If the site is served directly (no
proxy), `client_ip` is the connection address and needs no configuration. The value
is sanitised to IP characters before rendering, so a spoofed header cannot inject
markup into the page.
