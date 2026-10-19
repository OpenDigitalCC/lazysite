---
id: SM1194
title: "SM1194: an old front end with a trusted proxy is a failure"
subtitle: "A site that trusts X-Forwarded-For behind a pre-SM929 vhost lets any visitor choose their address; the rollout and the check now say so."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-test-plan-01510-results.md, finding F-6
area: security
status-note: "SHIPPED on n683: installers/hestia/lazysite-hestia-update-all.sh (vhost_xff_state, xff_exposure), tools/lazysite-check.pl; t/tools/185."
---

# What happened

The 0.15.10 test plan, finding F-6 (security):

> After the walk, the owner set `trusted_proxies: 10.2.30.177` on edge. A probe
> then showed the front end (`X-Lazysite-Front: hestia-proxy/acl`) passing the
> client's own `X-Forwarded-For` through unchanged, without adding the real
> client address. A request sent with no header is still seen as 10.2.30.177. A
> request sent with `X-Forwarded-For: 192.0.2.55` is seen as 192.0.2.55.

Every address-keyed control takes the visitor's word: the sign-in rate limit,
the bad-URL blocker, the form handler's rate limit, and every address rule.

The cause: edge's vhost was rendered from the proxy template before SM929
(d93390469, first shipped in v0.15.2). That template set no `X-Forwarded-For`
(`git show d93390469^:installers/hestia/lazysite-proxy.tpl` has only `Host`), so
nginx passed the client's header through. Since SM929 both proxy templates set
`proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. The rollout had
said only "1 site(s) render an older template". `auth_proxy_trusted_from` is not
affected: it matches the TCP peer, never the forwarded address (SM1129).

# What shipped

- The Hestia rollout tells a pre-SM929 rendering from the revision marker: it
  reads the rendered nginx file for an uncommented `X-Forwarded-For` line that
  appends (`$proxy_add_x_forwarded_for`) or sets the peer (`$remote_addr`); none,
  or `$http_x_forwarded_for`, is a pass-through. When the site's `lazysite.conf`
  also sets `trusted_proxies` (not `none`) it is a FAILURE: a findings line naming
  the site, the reason ("the front end passes the client's X-Forwarded-For
  through, so trusted_proxies lets any visitor choose their address") and the fix
  (rebuild the vhost, then probe), a summary line counting them, and exit status 2.
  Without `trusted_proxies` the existing note stands.
- `lazysite check` cannot read the nginx config, so it warns whenever
  `trusted_proxies` is set, with the probe to run.
- Documented in the configuration reference, the visitor-address page and the
  security architecture note.
