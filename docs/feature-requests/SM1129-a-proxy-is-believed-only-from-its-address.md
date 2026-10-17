---
id: SM1129
title: "SM1129: a proxy's identity headers are believed only from the proxy's address"
subtitle: "auth_proxy_trusted: true believed X-Remote-User from anyone who could reach the CGI. auth_proxy_trusted_from names the peers that may send it, and an empty list believes nobody."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: SM1128 phase 1, P1-1 (ruled by the release manager 2026-10-17); the hop check SM794 proposed and never built
area: auth, security
status-note: "SHIPPED on n630 (claude/n630-a-proxy-is-believed-only-from-its-address): Lazysite::Util::proxy_identity and the processor's pinned _proxy_identity; t/integration/262, t/unit/processor/131, t/unit/tools/81, t/lint/265."
---

# What happened

SM1128 (sign-in through an identity provider) found, in its list of what the
code does today:

> **No hop check (SM794).** With the flag on, any request carrying the
> headers is believed; nothing checks it came from the proxy. SM794 proposed
> `auth_proxy_trusted_from` (a CIDR list against `REMOTE_ADDR`); it was never
> built. On the cluster only network isolation (Caddy on a private Docker
> network) stands between a client and naming itself an operator.

and SM794 had recorded the same gap and left it for the release manager:

> **`auth_proxy_trusted: true` has no hop check.** With the flag on, the gate
> returns early for every request and authz is read from the header with no
> cross-check, so a raw client naming a manager group is sufficient. That is
> the flag's designed meaning, and an `auth_proxy_trusted_from` CIDR allowlist
> checked against `REMOTE_ADDR` is a change to the flag's contract.

The release manager ruled phase 1 as proposed on 2026-10-17: "rulings as
proposed. auth_proxy_trusted has not been enabled anywhere." So the contract
of the flag changes now, while nobody depends on the old one.

# What shipped

`auth_proxy_trusted_from:` in `lazysite.conf`, a comma- or space-separated list
of addresses and CIDR ranges, IPv4 and IPv6. With `auth_proxy_trusted: true`:

- The identity headers (the fixed `X-Remote-*` names, the configured
  `auth_header_*` names, and the payment headers, as they were all believed
  together before) are believed only when `REMOTE_ADDR` is in the list.
  `REMOTE_ADDR` is the TCP peer. `X-Forwarded-For` is never consulted: it is
  what a client sets.
- From any other peer they are stripped exactly as when the flag is off, and the
  request is anonymous on the page gate, the per-file ACL and the manager API.
  One WARN per request names the address and the setting.
- **The list fails closed.** Absent, empty, `none`, or holding nothing parseable
  (a typo, a `/0`): nobody is believed, and the WARN says the list is empty.
  SM794 does not rule on an empty list (it calls the question a change to the
  flag's contract), and the safe reading of a security flag with no stated
  peers is to trust none. This differs deliberately from `trusted_proxies`,
  where an empty value means a default private range.
- It is a separate setting from `trusted_proxies` (SM929): that one says whose
  `X-Forwarded-For` to believe about a visitor's address, this one whose identity
  headers to believe about a visitor's account. The two sets are parsed by the
  same CIDR code and need not name the same hosts.
- A cookie session vouched for by the auth wrapper (`LAZYSITE_AUTH_TRUSTED=1`)
  is untouched by the list.

**One function.** `Lazysite::Util::proxy_identity` answers "is this request's
identity header trustworthy" and returns the flag, the list, the state (`off`,
`no-list`, `not-listed`, `listed`) and the peer. The processor's gate
(`apply_trust_gate`) carries its pinned copy `_proxy_identity` (ADR 0001 keeps
the render path module-free; t/unit/processor/131 holds the two to the same
answers over a table). The manager API's gate and the auth wrapper call the
module's. Before this the processor read the flag from its parsed conf and the
manager API grepped the file; `lazysite-auth.pl` has no proxy branch of its own.
t/lint/265 holds that no other code names the setting as a key, and that the
three deciding surfaces call the function.

`lazysite check` warns whenever the flag is on, naming the list, says plainly
when the list is empty (proxy sign-in is refused for everyone), and names any
list entry that is not an address or range. The Config page does not show
`auth_proxy_trusted`, so no setting was added there.

Existing tests that turned the flag on now also name their stand-in proxy
(`auth_proxy_trusted_from: 127.0.0.1`); `run_processor` supplies that peer only
for a site whose conf has the list.

# Tests

t/integration/262 drives the real processor (page gate, configured header names,
a per-file ACL on a static file) and the real manager API: a listed CIDR member
and a listed host are believed; an unlisted peer, a v4 peer against a v6 range
and a peer that names a listed address in `X-Forwarded-For` are anonymous; the
list absent, empty, `none`, a typo or `/0` believes nobody; the flag off ignores
the list; the log names the address. Each was checked by putting the matching
`main` file back and seeing the test fail.
