---
title: "SM374: the SSL proxy template reaches the wrong vhost, or none"
subtitle: "lazysite-proxy.stpl proxies to Apache over TLS by IP and sends no SNI. On a host with more than one TLS vhost that is 421 on every request; on a front end that sets no proxy defaults it is worse - 200, serving another site's pages."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-08-18 on claude/proxy-stpl-sni and NOT IN 0.10.14 - that release was already being cut when this arrived, so the fix awaits the next one and edge stays on the STOCK proxy template until then. Three directives in the .stpl (proxy_ssl_server_name on, proxy_ssl_name %domain_idn%, proxy_set_header Host $host) and one in the .tpl. Proven against a REAL nginx in front of a REAL Apache with TWO TLS vhosts - t/integration/45 - which is the only configuration that can show it, and t/lint/33 carries the cheap tripwire for hosts without both servers installed. THE FIELD REPORT'S MECHANISM WAS CORRECTED BY MEASURING: a missing Host does not produce the 421, it produces a silent 200 from the default vhost. The 421 requires Host to be RIGHT and SNI to be missing, so on edge the front end was already setting Host globally and SNI alone was absent. Both rows are failures, only one announces itself, and the fix closes both."
---

# What happened

The operator applied `lazysite-proxy` to edge on 2026-08-18, following
`installers/hestia/INSTALL-RUNBOOK.md`. The template took effect -
`x-lazysite-front: hestia-proxy/acl` was present - and **every request to
the domain returned 421 Misdirected Request**: pages, MCP, WebDAV and the
control API alike, on HTTP/2, on forced HTTP/1.1 and on a fresh
`--no-alpn` connection. Rolled back to the stock template, the site
recovered completely.

Reported by the site agent, measured from outside with no host access.

# The cause

The SSL template sends every request to Apache over TLS, addressed by IP:

```nginx
proxy_pass https://%ip%:%web_ssl_port%;
```

nginx defaults `proxy_ssl_server_name` to **off**, so that handshake
carries no SNI and Apache answers from its default TLS vhost.

# What measuring changed

The field report named the missing `Host` header as part of the cause.
Driven against a real Apache with two TLS vhosts, that is not what
produces a 421 - it produces something quieter:

```datatable
columns: Condition | Result
widths: 7.0cm | X
bold: 1
tone: medium
---
`Host` absent, so nginx sends the backend's IP | **200**, serving the WRONG SITE
`Host` present, SNI absent | **421**
Both present | 200, the right site
---
```

So on edge the `Host` header was already being set - by the front end's
own global configuration - and SNI alone was missing.

::: widebox
**The quiet row is the dangerous one.** A 421 takes the site down
visibly and gets rolled back within the hour. A 200 from the default
vhost leaves the site *up*, serving another site's pages, with nothing
in the response to say so. A test asserting only on the status code
would call that a pass.
:::

# The fix

Three directives in the `.stpl`, at server level so every `location`
inherits them, and one in the `.tpl`:

```nginx
proxy_ssl_server_name on;
proxy_ssl_name        %domain_idn%;
proxy_set_header      Host $host;
```

`Host` is set explicitly in both templates rather than inherited. Some
front ends set it in their global `http` block and would paper over the
absence - and that is exactly the dependency [[SM286]] says a lazysite
template must not have.

# Why it shipped

**A host with one TLS vhost cannot show any of this**, because the
default vhost is also the right one. Everything the template was tested
against had one. `t/integration/45` therefore builds a **second** vhost
it never requests, and asserts against the one that is not the default -
the position every real site is in except one.

That is the same shape as SM268 H17 and SM283 itself: a front-end defect
invisible to everything except driving the real server, and invisible
even to that unless the fixture has two vhosts.

# The fix is inert until the host's template copy is refreshed

Verified on edge 2026-08-19, and the **first application failed with the
same 421 on three domains at once** - because an older copy of the
template was still in Hestia's directory.

::: widebox
**A package upgrade does not deliver a Hestia template.** SM283 says
that about INSTALLING one and it is equally true of UPDATING one. So
this fix ships in the package, changes nothing until the operator
re-applies the template, and **the failure while it is stale is
identical to the bug** - the same 421, on every surface.
:::

Anyone applying this fix should confirm the template on the host is the
new one before concluding anything from a 421.

# Verified on edge

Four vhosts, each asserted **on the body** rather than the status,
because a missing Host serves the default vhost with a 200 and the code
cannot say which site answered:

```datatable
columns: Host | Served
widths: 6.0cm | X
bold: 1
tone: medium
---
edge.explore | its own EDGE test site
edge2.explore | Kestrel, Porto
providers.explore | lazysite Studio
th.providers.explore | lazysite Studio (Thai)
---
```

`X-Lazysite-Front: hestia-proxy/acl` on all four, 421 on none, across
HTTP/2, forced HTTP/1.1 and a fresh no-ALPN connection.

# Verification

- `t/integration/45` drives real nginx in front of real Apache, two TLS
  vhosts, under two front-end conditions: one setting no proxy defaults
  and one setting `Host` globally. Both must reach the lazysite domain's
  own docroot.
- The fixture proves Apache discriminates before asserting anything
  through the proxy - otherwise every assertion would pass while
  testing nothing.
- Reverting the template reproduces both documented failures: 200 from
  the wrong vhost on a bare front end, 421 on one setting `Host`.
- `t/lint/33` pins all four directives for hosts without both servers.

# Related

[[SM283]] (the template and the argument for it, unaffected), [[SM286]]
(the template states what it needs rather than inheriting it), and
`inbox/2026-08-18-lazysite-proxy-template-takes-the-site-down.md`.
