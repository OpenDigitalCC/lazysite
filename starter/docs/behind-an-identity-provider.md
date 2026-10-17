---
title: Behind an identity provider
subtitle: Let a proxy in front of the site sign visitors in, and say who may do what with the groups it sends.
register:
  - sitemap.xml
---

## Overview

A site can leave sign-in to an identity provider (Authentik, Authelia and the
like). A reverse proxy in front of lazysite asks the provider who the visitor is
and passes the answer to lazysite in request headers: a user name, and the groups
the provider puts the visitor in. This is the **trusted-header route**. Every
part of the site reads the same answer: the page gate (`auth:` and
`auth_groups:`), per-file access rules, the manager, the data endpoint and the
layout's variables such as `[% auth_user %]`.

The route is off until the operator turns it on, and it believes the headers only
from the proxy the operator names. The rest of this page is the settings, what a
directory group is allowed to do, the conditions that make the route safe, and a
worked example.

## The settings

All of them go in `lazysite/lazysite.conf`.

`auth_proxy_trusted`
: `true` turns the route on. Without it the identity headers are discarded
  before anything reads them.

`auth_proxy_trusted_from`
: The proxy's address: a comma- or space-separated list of addresses and CIDR
  ranges, IPv4 or IPv6, such as `172.18.0.2` or `10.0.0.0/8`. It is matched
  against the address of the connection that reached lazysite
  (`REMOTE_ADDR`), and never against `X-Forwarded-For`. The headers are
  believed from a listed address and from nowhere else; from any other peer they
  are stripped as if the route were off, and the log names the address. An empty
  list, `none`, or a list with no usable address believes nobody: every request
  is treated as anonymous until the list names the proxy. `lazysite check` warns
  about a site that has the route on and no usable list.

`auth_header_user`, `auth_header_name`, `auth_header_email`, `auth_header_groups`
: The names of the headers the proxy sends. The defaults are `X-Remote-User`,
  `X-Remote-Name`, `X-Remote-Email` and `X-Remote-Groups`. Set these to the
  names the proxy already uses, or make the proxy send the defaults. Every reader
  honours the names you set.

`auth_header_groups_separator`
: What separates the groups in the groups header. The default is `,`; Authentik
  sends `|`. Each part is trimmed and an empty part is dropped.

`auth_group_map`
: Directory group names are often not valid lazysite group names (`Site Editors`
  has a space). A name with no entry is normalised: lowercase, and any run of
  other characters becomes one hyphen, so `Site Editors` becomes `site-editors`.
  An entry maps a directory name to a name of your choosing, and wins over the
  normalised form:
  `auth_group_map: Site Editors = editors, Platform Admins = sysops`.
  See [Configuration](/docs/configuration) for the full rule.

## What the provider's groups may do

A group that arrives in the groups header gives **page and file access by
name**. A page with `auth_groups: [site-editors]` and a file rule naming
`@site-editors` are open to a visitor the provider put in `Site Editors`. Nothing
needs to exist on the site for that: the visitor needs no account in the site's
user list and no entry in any group file.

A group gives **manager capabilities** (the `ui` permission to enter the manager,
`manage_content`, and the rest) only when the operator has marked the group:

1. Create a group with the lazysite name (`site-editors`) on the Groups page and
   tick the capabilities it should grant.
2. Tick **Groups sent by an identity provider grant this group's capabilities**
   on the same group. Only the operator sees and can set this tick. A holder of
   `manage_users` cannot, because the mark decides what everyone the provider
   puts in the group may do. The change is audited. From a shell it is
   `group-set site-editors directory_grants on` on the users tool.

An unmarked group of that name gives pages and files and nothing in the
manager. The operator status is a capability of this kind: a directory group makes
its members operators only when the operator group (the one carrying the manager
flag) is marked as well. A visitor who signs in with the site's own cookie
login is unaffected by the mark; the mark governs only groups that came from the
proxy.

The data endpoint a page's JavaScript calls reads the same identity, so a table
whose read rule names a group opens to the provider's members of that group. A
write through it needs `manage_data` or `write_data` held by an account or by a
marked group.

The MCP connector, the control API and WebDAV authenticate with tokens and never
read these headers.

## Sign-in and sign-out

The provider decides who the visitor is on every request. A visitor the proxy
names a user for is that user; any lazysite cookie they also hold is set aside for
that request. A request that arrives with no user in the headers behaves as it
does on a site without the route: the cookie login is used if the visitor has
one. Sign-out belongs to the provider, because the site holds no session for a
proxy identity. The Sessions page lists cookie sessions only.

## The conditions that make it safe

The route trusts a header. Three conditions keep the header honest:

1. **lazysite is reachable only from the proxy.** Put them on a private network,
   or firewall the web server to accept connections from the proxy alone.
2. **`auth_proxy_trusted_from` names the proxy and only the proxy.** Use the
   address (or the small range) of the proxy as lazysite sees the connection. A
   wide range lets any host inside it send its own headers.
3. **Every path to lazysite goes through the provider's check.** The proxy must
   overwrite or remove the identity headers on each request it forwards. A route
   that reaches lazysite without the check lets a visitor send the headers
   themselves.

## Worked example: Caddy and Authentik's proxy outpost

Caddy asks Authentik's outpost about each request (forward auth). On success
Caddy copies the outpost's response headers onto the request it passes to
lazysite. The example uses the names Authentik sends, so lazysite is told those
names; the host names are placeholders.

The Caddyfile:

```caddy
example.org {
    # The outpost's own endpoints (sign-in, callbacks), answered by the outpost.
    reverse_proxy /outpost.goauthentik.io/* http://authentik-outpost:9000

    # Every other path is checked first, then passed to lazysite.
    forward_auth http://authentik-outpost:9000 {
        uri /outpost.goauthentik.io/auth/caddy
        copy_headers X-Authentik-Username X-Authentik-Name X-Authentik-Email X-Authentik-Groups
        trusted_proxies private_ranges
    }

    reverse_proxy http://lazysite:8080
}
```

`lazysite/lazysite.conf`, where `172.18.0.2` is the address of the Caddy
container on the private network it shares with lazysite:

```
auth_proxy_trusted: true
auth_proxy_trusted_from: 172.18.0.2
auth_header_user: X-Authentik-Username
auth_header_name: X-Authentik-Name
auth_header_email: X-Authentik-Email
auth_header_groups: X-Authentik-Groups
auth_header_groups_separator: |
auth_group_map: Site Editors = editors
```

Authentik's groups header looks like `Site Editors|Members`. With the settings
above, lazysite reads two groups, `editors` and `members`. A page with
`auth_groups: [editors]` opens for that visitor. If the group `editors` also
carries `ui` and `manage_content` and the operator has ticked the directory mark
on it, the same visitor enters the manager.

To confirm it before relying on it, request a gated page with the headers set by
hand from a host outside `auth_proxy_trusted_from` and see the 302 or 403, then
request it through the proxy signed in and see the page.

## Further reading

- [Authentication](/docs/auth)
- [Configuration](/docs/configuration)
- [Upgrading to external auth](/docs/auth-upgrade)
