---
title: "lazysite - webserver wiring"
subtitle: "One reference for fronting lazysite from any web server"
brand: plain
standard-margins: true
---

How a web server puts a lazysite site on the network: the two runtime
patterns explained once, then per-server sections with copy-paste-able
config. Apache and nginx have packaged glue (`lazysite-apache` /
`lazysite-nginx`: shipped vhost templates plus a render command) - use
that instead of hand-copying the snippets; the snippets here are the
reference for what the glue produces and the starting point for every
other server. To try lazysite with **no** web server at all, run
`lazysite demo` - it provisions a scratch site and serves it on the
built-in dev server.

Throughout, the example site is `example.com` with
`DOCROOT=/srv/www/example.com/public_html` and
`CGIBIN=/srv/www/example.com/cgi-bin` - the layout
`lazysite provision` produces (provision first, **as the site user**;
see `lazysite(1)`).

## The two patterns

Plain CGI
: Static files are served directly; any URL that maps to **no file**
  is handed to the lazysite processor *via the CGI auth wrapper*
  (`lazysite-auth.pl`), which validates the session cookie, sets
  `X-Remote-User`, and execs the processor. Zero extra moving parts;
  every page render forks a CGI (~60 ms on a cache hit).

FastCGI pool
: The production shape (SM142). A persistent per-site worker pool -
  `systemctl enable --now lazysite@example.com`, identity in
  `/etc/lazysite/pools/example.com.conf` - listens on
  `/run/lazysite/example.com.sock`; **anonymous** page traffic speaks
  FastCGI to that socket (~0.4 ms on a cache hit, ~150x). The pool is
  anonymous *by design*: a request carrying the `lazysite_auth`
  session cookie must be carved out to the CGI auth wrapper (that is
  what makes `/manager/` and the logged-in admin bar work), and
  `/cgi-bin`, `/dav` stay CGI too. See
  `docs/architecture/performance.md`.

## The one-rule option (SM293 step 5)

Everything in this section describes what a front end must do when it is making
the routing decisions itself. **It no longer has to.**

`installers/apache/vhost-one-rule.conf.example` and its nginx counterpart
forward every request to `lazysite-front.pl`, which routes it -
`Lazysite::FrontDoor::route()`, asserted in `t/unit/lib/21` and driven through
real Apache in `t/integration/49`. There is nothing to get wrong in the config
because there is nothing in it.

The cost is a process start per request, including for assets on a site that
protects nothing. So the contract below still matters: **the fuller templates
are performance options whose absence costs speed and never correctness.** Read
on if you want the speed, or if you are writing a config for a server not
covered here.

## The front-end contract (any server)

Whatever the server, a correct front end does exactly this:

1. **Serve existing files directly** (assets, static pages). Do NOT
   treat `index.html` as a directory index - it is lazysite's own
   homepage cache; serving it directly bypasses the processor and the
   admin bar never appears on `/`. (`index.htm`/`index.shtml` are fine
   as indexes - they only exist on overlaid static sites.)
2. **Send page misses to the processor** - every URL that maps to no
   file - either as CGI *via the auth wrapper* (`lazysite-auth.pl`,
   never the processor directly, or logins silently never take
   effect), or as FastCGI to the pool socket (anonymous traffic only;
   session-cookie-bearing requests go via the auth wrapper).
3. **Run `/cgi-bin/*.pl` as CGI**, with `lazysite-processor.pl` and
   `lazysite-manager-api.pl` *fronted by the auth wrapper*
   (`LAZYSITE_PROCESSOR` env names the real target), and `/dav` mapped
   to `lazysite-dav.pl` (its own Basic auth - pass the `Authorization`
   header through).
4. **Recommended hardening - strip the client-supplied trust headers**
   before anything downstream: `X-Remote-User`, `X-Remote-Groups`,
   `X-Remote-Name`, `X-Remote-Email`, `X-Payment-Verified`,
   `X-Payment-Payer` (`docs/architecture/security.md`).

   Recommended, **not required**, and the distinction is deliberate.
   The control is in the engine: a trust header is honoured only when
   the auth wrapper vouched for the request
   (`LAZYSITE_AUTH_TRUSTED=1`) or the operator opted into a trusted
   reverse proxy (`auth_proxy_trusted: true`). Otherwise every one of
   them is deleted from the environment and the attempt logged. A
   forged header therefore fails on a front end that strips nothing.

   `t/lint/38` pins that: every surface that READS a trust header must
   also gate it, so a new surface cannot start believing one. This
   entry used to be listed as a front-end requirement, which put a
   security control in configuration lazysite ships as a template,
   cannot test where it is installed, and mostly cannot see - the
   pattern behind SM248, SM268 H17 and SM283. Strip them anyway if you
   can: defence in depth is worth having, and it keeps the headers out
   of logs upstream.
5. **Deny `/lazysite/` and `*.brief`** at the origin (engine
   internals; authoring sidecars).
6. Give the CGIs `DOCUMENT_ROOT` and the originally-requested path
   (Apache sets `REDIRECT_URL`; synthesise it elsewhere - the
   processor also falls back to `REQUEST_URI`).

Two additions apply only when the instance serves **more than one domain**, and
both come from the same generator - see *Multi-domain statics* below.

## Multi-domain statics

On a multi-domain instance, item 1 above ("serve existing files directly") is
not enough on its own: the file that exists at the docroot root belongs to the
**primary** site, so every other domain gets the primary's copy. That is one
root cause behind three reported defects, and it needs two rules per domain:

```bash
lazysite-apache-vhost rewrites --docroot /path/to/public_html
lazysite-nginx-vhost  rewrites --docroot /path/to/public_html
```

The command reads `alias_hosts` + `alias.<host>.content_root` from the site's
own `lazysite.conf` and prints config text - it writes nothing and needs no
root. Paste the output into the `<VirtualHost>` (Apache) or the `http{}` block
and content location (nginx). Regenerate it whenever a domain is added or its
content root changes.

What the generated block does:

- **serves each domain's own statics** from its content root, so
  `harmony2050.org/logo.png` comes from that domain's subtree rather than the
  primary's;
- **refuses to inherit the site identity** - `favicon.ico`, `favicon.svg`, the
  apple-touch icons and `site.webmanifest`. A domain with its own icon serves
  it; a domain with none gets a 404 rather than the primary's file. That is
  deliberate: a missing favicon is unremarkable and browsers handle it, whereas
  another organisation's emblem in the browser tab is a claim about whose site
  this is, and a false one.

A host with **no content root of its own** is untouched by both and keeps
inheriting the primary's files - that is the chrome-only alias case and it is
correct.

The registries (`sitemap.xml`, `llms.txt`, `robots.txt`, the feeds) are handled
separately and need no action: the shipped templates route them to the engine
unconditionally, because crawlers fetch them rarely and the CGI cost does not
matter. Icons are fetched by every visitor, so they stay on the static path.

## Apache

Install the **`lazysite-apache`** deb: templates for both patterns at
`/usr/share/lazysite-apache/`, rendered per domain by

```sh
lazysite-apache-vhost add example.com --docroot /srv/www/example.com/public_html          # CGI
lazysite-apache-vhost add example.com --fcgi --docroot /srv/www/example.com/public_html   # pool
# then the printed steps: a2enmod cgid headers rewrite [proxy proxy_fcgi],
# a2ensite example.com, systemctl reload apache2, certbot --apache -d example.com
```

The load-bearing directives, in miniature (the shipped templates carry
the complete, commented vhosts):

```apache
# Trust-strip (mod_headers) - contract item 4.
RequestHeader unset X-Remote-User
# ... and the other five headers.
ScriptAlias /cgi-bin/ /srv/www/example.com/cgi-bin/
ScriptAlias /dav /srv/www/example.com/cgi-bin/lazysite-dav.pl
# Front the real endpoints with the auth wrapper (contract item 3).
RewriteEngine On
RewriteRule ^/cgi-bin/(lazysite-(?:processor|manager-api)\.pl)$ /cgi-bin/lazysite-auth.pl [E=LAZYSITE_PROCESSOR:/srv/www/example.com/cgi-bin/$1,PT]
# CGI pattern - page misses via the auth wrapper (contract item 2):
FallbackResource /cgi-bin/lazysite-auth.pl
# FCGI pattern instead: session cookie carve-out to the wrapper, then
# anonymous misses to the pool socket (mod_proxy_fcgi):
#   RewriteCond %{HTTP_COOKIE} lazysite_auth=
#   RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} !-f
#   RewriteCond %{REQUEST_URI} !^/(?:cgi-bin|dav)(?:/|$)
#   RewriteRule ^ /cgi-bin/lazysite-auth.pl [PT,L]
#   FallbackResource /lazysite-pool
#   <Location "/lazysite-pool">
#       SetHandler "proxy:unix:/run/lazysite/example.com.sock|fcgi://localhost/"
#   </Location>
```

## nginx

Install the **`lazysite-nginx`** deb: templates for both patterns at
`/usr/share/lazysite-nginx/`, rendered per domain by
`lazysite-nginx-vhost add ...` (same verbs as the Apache command).
nginx has no CGI engine, so both patterns need **fcgiwrap** (Debian
socket `/run/fcgiwrap.socket`); and it has no `FallbackResource`, so
`try_files $uri @lazysite` plus a named location is the equivalent. On
nginx **prefer the pool pattern** - the CGI pattern pays a double fork
(fcgiwrap + CGI) per page render.

```nginx
# The CGIs read the requested path from REDIRECT_URL (what Apache
# sets); synthesise it, minus the query string. http scope - top of the
# sites-enabled file is fine.
map $request_uri $lazysite_request_path { ~^(?<path>[^?]*) $path; }

server {
    listen 80;
    server_name example.com;
    root /srv/www/example.com/public_html;
    index index.htm index.shtml;        # NOT index.html (contract item 1)
    location ^~ /lazysite/ { deny all; }          # contract item 5
    location ~ \.brief$    { deny all; }
    location / { try_files $uri @lazysite; }      # contract items 1+2
    location @lazysite {
        # FCGI pattern: carve session-bearing misses out to the CGI
        # auth wrapper (rewrite-only `if` - the documented-safe form).
        if ($cookie_lazysite_auth) { rewrite ^ /lazysite-session-carveout last; }
        include fastcgi_params;
        fastcgi_param HTTP_X_REMOTE_USER "";      # contract item 4
        # ... and the other five headers.
        fastcgi_param REDIRECT_URL $lazysite_request_path;
        fastcgi_pass unix:/run/lazysite/example.com.sock;
        # CGI pattern instead: drop the `if`, and fastcgi_pass
        # unix:/run/fcgiwrap.socket with
        #   fastcgi_param SCRIPT_FILENAME /srv/www/example.com/cgi-bin/lazysite-auth.pl;
    }
    # /cgi-bin/*, /dav and the session carve-out all go via fcgiwrap
    # with SCRIPT_FILENAME set to the target script - the shipped
    # templates carry the complete, commented set.
}
```

The session-cookie carve-out **is** expressible in pure nginx config:
the file-existence test happens first in `try_files` (so a logged-in
user's static assets never pay the CGI fork - the same order as
Apache's `!-f` RewriteCond), then a rewrite-module-only `if` inside the
named location redirects cookie-bearing misses to an `internal`
location that runs the auth wrapper through fcgiwrap. `$request_uri`
survives the rewrite, so no path information is lost.

## Caddy

No packaged glue; the pool pattern maps naturally onto Caddy's
FastCGI transport. Run the pool (`lazysite-common`), then:

```caddy
example.com {
    root * /srv/www/example.com/public_html
    # Contract item 4: never forward client trust headers.
    request_header -X-Remote-User
    request_header -X-Remote-Groups
    request_header -X-Remote-Name
    request_header -X-Remote-Email
    request_header -X-Payment-Verified
    request_header -X-Payment-Payer
    # Contract item 5.
    respond /lazysite/* 403
    @brief path *.brief
    respond @brief 403
    # Contract items 1+2: existing files directly, page misses to the
    # anonymous pool socket over FastCGI.
    @miss not file
    reverse_proxy @miss unix//run/lazysite/example.com.sock {
        transport fastcgi {
            root /srv/www/example.com/public_html
            # env REDIRECT_URL is synthesised from the request by the
            # processor's REQUEST_URI fallback.
        }
    }
    file_server
}
```

Limitation, stated honestly: Caddy has no CGI engine in core, so the
CGI path (`/manager` login sessions, `/cgi-bin/*`, `/dav`) needs a
plugin (e.g. the third-party `caddy-cgi` module) wired per contract
item 3, or those endpoints proxied to a small Apache/nginx listener.
Without it you have a fast anonymous site but no manager UI - fine for
a published-from-elsewhere site, not for interactive editing.

## lighttpd

Both patterns are expressible. CGI pattern with `mod_cgi` +
`mod_setenv` (lighttpd's 404-handler is the FallbackResource
equivalent, and it reaches the CGI with the original URL in
`REQUEST_URI`):

```lighttpd
server.modules += ("mod_cgi", "mod_setenv", "mod_alias")
$HTTP["host"] == "example.com" {
    server.document-root = "/srv/www/example.com/public_html"
    index-file.names = ("index.htm", "index.shtml")   # NOT index.html
    # Contract item 4.
    setenv.set-request-header = ("X-Remote-User" => "", "X-Remote-Groups" => "",
        "X-Remote-Name" => "", "X-Remote-Email" => "",
        "X-Payment-Verified" => "", "X-Payment-Payer" => "")
    # Contract item 5.
    $HTTP["url"] =~ "^/lazysite/|\.brief$" { url.access-deny = ("") }
    # Contract item 3: the cgi-bin, with .pl handed to the CGI engine.
    alias.url += ("/cgi-bin/" => "/srv/www/example.com/cgi-bin/")
    $HTTP["url"] =~ "^/cgi-bin/" { cgi.assign = (".pl" => "") }
    # Contract item 2: page misses to the auth wrapper (server.error-handler
    # preserves the original request URL for the CGI).
    server.error-handler-404 = "/cgi-bin/lazysite-auth.pl"
}
```

Pool pattern: replace the 404 handler with `mod_fastcgi` pointing at
the pool socket for anonymous traffic:

```lighttpd
server.modules += ("mod_fastcgi")
# Anonymous page misses to the pool (lighttpd cannot branch on a
# cookie inside the 404 handler: route ALL misses to the pool only on
# sites managed from elsewhere, or keep the CGI 404 handler above -
# the honest lighttpd trade-off).
server.error-handler-404 = "/lazysite-pool"
fastcgi.server = ("/lazysite-pool" => ((
    "socket" => "/run/lazysite/example.com.sock",
    "check-local" => "disable",
    "docroot" => "/srv/www/example.com/public_html",
)))
```

Limitation, stated honestly: lighttpd's config cannot make the
existence-then-cookie routing decision Apache/nginx make, so with the
pool pattern the session-bearing page requests would ALSO reach the
anonymous pool (logged-in state never shows). Use the CGI pattern on
lighttpd when the manager is used through it, or front the manager
paths separately.

## Any other server

Implement the six contract items above. The minimum viable wiring is
the CGI pattern: run `CGIBIN/lazysite-auth.pl` as a CGI for every URL
that maps to no file (with `DOCUMENT_ROOT`, the original URL in
`REDIRECT_URL` or `REQUEST_URI`, and the trust headers stripped), plus
`/cgi-bin/` and `/dav` per item 3. If the server can speak FastCGI to a
unix socket, add the pool for anonymous traffic - but only route
session-cookie-less requests there, or accept that logged-in features
degrade. When in doubt, compare against the shipped Apache templates
(`/usr/share/lazysite-apache/`) - they are the reference
implementation, and `t/tools/31-webserver-glue.t` pins their contract.
