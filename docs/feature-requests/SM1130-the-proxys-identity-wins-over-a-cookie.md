---
id: SM1130
title: "SM1130: under proxy trust, the proxy's identity wins over a lazysite cookie"
subtitle: "A valid local cookie overwrote the identity a trusted proxy had sent, so a stale session beat the directory. The cookie is now not consulted when the proxy names a user."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: SM1128 phase 1, P1-4 (ruled by the release manager 2026-10-17)
area: auth
status-note: "SHIPPED on n630 (claude/n630-a-proxy-is-believed-only-from-its-address): lazysite-auth.pl handle_request; t/integration/263."
---

# What happened

SM1128 recorded, under Sessions:

> A header identity has no Sessions-registry entry and no cookie, so it cannot
> be revoked from the Sessions page; it ends at the IdP. If the visitor also
> holds a valid lazysite cookie, the cookie's identity replaces the proxy's - a
> stale local session beats the directory.

and planned it as P1-4:

> Under proxy trust, the proxy's identity wins over a lazysite cookie for the
> same request; a cookie for a different user is ignored, not merged.

In `lazysite-auth.pl`, `handle_request` verified the cookie first and, on
success, set `X-Remote-User` and `X-Remote-Groups` from it, overwriting what the
proxy had sent. A directory that had moved someone out of a group, or a
browser still holding a day-old session for another person, was overridden by
the local session.

# What shipped

When `auth_proxy_trusted` is on **and** the request's proxy headers are
trusted (SM1129: the peer is in `auth_proxy_trusted_from`, answered by
`Lazysite::Util::proxy_identity`) **and** they carry a user (the fixed
`X-Remote-User`, or the configured `auth_header_user` name), the cookie is not
consulted for identity at all: no verification, no merge, no fallback. A DEBUG
line, `auth: proxy identity wins, cookie ignored`, is logged when a cookie was
sent. The wrapper sets no `LAZYSITE_AUTH_TRUSTED` sentinel in that case, so the
processor and manager API believe the proxy's headers through the same function.

When the proxy headers are absent, or the peer is not trusted, today's cookie
behaviour stays: a site may use both, and an untrusted peer's headers are no
identity, so they displace nothing.

# Tests

t/integration/263 runs lazysite-auth.pl in front of the real processor with a
per-file ACL: a trusted proxy naming carol with a valid cookie for alice is
carol (alice's file is refused to her with 403, carol's file is served); the
same without the cookie; no proxy headers with alice's cookie is alice; and
forged headers from an unlisted peer neither displace the visitor's own cookie
nor make anyone of themselves. Checked by putting the `main` wrapper back.
