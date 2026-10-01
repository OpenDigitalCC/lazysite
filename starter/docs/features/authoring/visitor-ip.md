---
title: Showing the visitor's IP
subtitle: A live [% client_ip %] variable and the nocache flag, cache-safely.
---

## Showing the visitor's IP

A page can show a visitor their own IP address. Two things make this work:

`[% client_ip %]`
: a Template Toolkit variable holding the visitor's IP - the address the connection
  came from, unless that address is a reverse proxy you have named as trusted, in
  which case it is the visitor the proxy reports. A visitor cannot choose this
  value: see [Behind a reverse proxy](#behind-a-reverse-proxy) below.

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

`X-Forwarded-For` is written by whoever sends the request, so the engine reads it
only when the request arrives **from an address you have named as a proxy** -
`trusted_proxies` on the Config page, which defaults to the private ranges
`10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`. From anywhere else the header is
ignored completely and `client_ip` is the connection address.

When the peer *is* trusted, the engine takes the **last** address in the chain that
is not itself one of your trusted proxies. That is deliberate and it is what stops a
visitor choosing their own: a proxy *appends* to the header rather than replacing
it, so a caller who sends `X-Forwarded-For: 203.0.113.7` ends up with their own
value in front of the one the proxy added, and the engine reads the proxy's.

Three consequences worth knowing:

- a site served **directly** needs no configuration, and a visitor who sends the
  header gains nothing;
- if your front end runs on the **same machine**, add its address - `127.0.0.1` is
  not trusted unless you name it;
- `trusted_proxies: none` ignores forwarded headers entirely.

The value is also sanitised to IP characters before rendering, which is a second
line rather than the first: it stops markup reaching the page, and the trust rule
above is what makes the address itself worth printing.
