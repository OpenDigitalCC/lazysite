---
id: SM1131
title: "SM1131: every reader honours the configured header names"
subtitle: "The request's identity is read in one place, so a proxy that sends its own header names opens the manager and the ACLs as it opens a page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: united/platform project, planned in SM1128 (P1-2), ruled 2026-10-17 "rulings as proposed"
area: auth
status-note: "SHIPPED on n631 (claude/n631-every-reader-reads-the-proxy-the-same-way): lib/Lazysite/Auth/Identity.pm; t/unit/auth/62, t/integration/265, t/lint/268."
---

# What happened

SM1128, "What the code does today", item 2:

> **Header names (SM960).** `auth_header_user`, `_name`, `_email`, `_groups` are
> honoured by the page gate only. The manager API, the manager entry, the ACL
> code and several processor readers use the fixed `X-Remote-*` names.

and the plan, P1-2:

> Every reader honours the configured header names (one accessor, a lint that
> nothing reads `HTTP_X_REMOTE_*` directly).

united/platform will put Authentik in front of lazysite and copy its headers to
whatever names lazysite reads. A page gated on a directory group opened; the
manager and a per-file ACL for the same person did not, because they read
`HTTP_X_REMOTE_USER` and `HTTP_X_REMOTE_GROUPS` and the proxy had sent
`X-Authentik-Username` and `X-Authentik-Groups`.

The readers were the page gate (`check_auth`, configured names), the manager
entry (`lazysite-processor.pl`), the layout's admin bar, the two data readers in
`sources.pm`, the manager API (five places) and `Auth::Acl::_is_operator`.

# What shipped

`Lazysite::Auth::Identity::request_identity` returns
`{ user, name, email, groups => [..], source }` and is the only code that reads
the identity out of the environment. The processor (through `_request_identity`
in `lazysite-processor/auth.pm`, which loads it lazily so the render path still
loads no `Lazysite::` module up front), the manager API, the ACL code, the
layout and both `sources.pm` readers all call it. `lazysite-data.pl`, which
verifies its own session, sets the fixed names and the trusted flag and reads
its groups back through the accessor.

The rule for which headers, one rule in three states:

- **The auth wrapper vouched** (`LAZYSITE_AUTH_TRUSTED=1`, set after it verified
  the signed cookie): the fixed `X-Remote-*` names it set. `source` is `cookie`.
- **Otherwise, the proxy is trusted for this request**: the configured
  `auth_header_user|_name|_email|_groups`. `source` is `proxy`. "Trusted" is
  `Lazysite::Util::proxy_identity`'s answer (SM1129): `auth_proxy_trusted: true`
  AND the TCP peer in `auth_proxy_trusted_from`. The reader asks it, or takes
  the answer its caller already holds for the request (the processor's pinned
  `_proxy_identity`, the auth wrapper's own ask); it never reads the flag.
- **Otherwise**: the fixed names, which the trust gates strip from any real
  request, so the answer is empty in service. `source` is `direct`.

The wrapper does not also set the configured names. The cookie path is the fixed
names whatever the proxy is called, so a site that renamed its proxy headers keeps
a working cookie login on every reader; before, the page gate read the configured
name behind the wrapper and saw nobody. And a client can never make the
configured names count: unless `proxy_identity` trusts the request's peer they
are not read, whether or not a gate stripped them (the manager API's gate strips
only the fixed names).

The hop check (`auth_proxy_trusted_from`, P1-1, SM1129) decides it. The two were
built side by side and joined when stacked: the reader first read
`auth_proxy_trusted` itself, which behind the processor's gate changed nothing
(an unlisted peer's headers were already stripped) but in the manager API let a
renamed header from an unlisted peer through, since that gate strips only the
fixed names. One answer now decides both what survives the gates and which names
the reader reads. The auth wrapper (SM1130) finds the proxy's user through the
reader as well, so the user that wins over a cookie is the one every reader then
sees; with no proxy user the cookie path sets the fixed names and
`LAZYSITE_AUTH_TRUSTED`, which the reader reads as the cookie's identity.

Lint t/lint/268 holds the arrangement: no file outside the accessor, the two
producers (`lazysite-auth.pl`, `lazysite-data.pl`) and the two trust-gate regions
names `HTTP_X_REMOTE_USER|NAME|EMAIL|GROUPS` or reads an `auth_header_*` setting,
and each reader above calls the accessor.

Tests: t/unit/auth/62 (the accessor); t/integration/265 (the real processor and
manager API: a page gate, a per-file ACL read, the manager entry and the ACL
operator test accepting `X-Authentik-Groups`, the same headers refused without
`auth_proxy_trusted` and from a peer outside `auth_proxy_trusted_from`, and the
cookie path with renamed proxy headers); t/integration/263 (the wrapper reads a
renamed proxy header the readers' way). t/lint/267 holds the reader to asking
`proxy_identity`. t/unit/processor/08 now gives the site `auth_proxy_trusted`
and a trust list where it renames a header, as t/integration/106 already
required.
