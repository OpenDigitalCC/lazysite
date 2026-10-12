---
id: SM960
title: "SM960: A custom auth header name was trusted from anyone"
subtitle: "With auth_header_user set (the docs' example: Remote-User), a header any visitor sent passed a page gate - the trust gate stripped only the fixed X-Remote-* names."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, found while building SM857's read half
area: security
status-note: "SHIPPED (0.15.3): the trust gate strips the configured auth_header_* names unless auth_proxy_trusted: true - including behind the built-in auth wrapper, which vouches for X-Remote-* only. t/integration/106: a visitor's Remote-User opened a gate before, and does not now. Docs say the flag is required."
---

# What was wrong

`check_auth` (`lazysite-processor.pl`) reads the identity from the header named
by `auth_header_user` (and `_name`, `_email`, `_groups`), defaulting to
`X-Remote-User`. `apply_trust_gate` decides whether those headers may be
believed, and it deleted only the fixed names `X-Remote-User/Groups/Name/Email`:

- **No `auth_proxy_trusted`, custom name configured:** a visitor sending
  `Remote-User: alice` and `Remote-Groups: admins` was signed in as alice in the
  admins group for page gates. The docs' "Custom header names" and
  auth-upgrade examples showed the custom names without the trust flag.
- **Behind the built-in auth wrapper** (`LAZYSITE_AUTH_TRUSTED=1`): the gate
  returned before stripping anything, and the wrapper vouches for `X-Remote-*`
  only - so the same spoof worked there on a site with a custom name.

Sites using the default names were not affected. Exposure needs a custom
`auth_header_*` setting, so it is limited to sites configured for a proxy.

# The fix

The gate builds the list of configured custom names and deletes them unless
`auth_proxy_trusted: true`, logging each discarded one - both when nothing is
trusted and behind the wrapper. A trusted proxy is unchanged.

**Behaviour change:** a site that set custom names and relied on them without
`auth_proxy_trusted: true` now has those headers discarded and its visitors
treated as signed out until the flag is set. That is the safe direction and the
changelog says so. The docs now show the flag in both examples.

# Evidence

t/integration/106: a visitor's `Remote-User` with no trusted proxy is redirected
to sign in; behind the wrapper it does not open an admins page; with
`auth_proxy_trusted: true` it does. Against the previous gate the first two
fail. The integration and processor suites pass.

# Related

[[SM857]] (whose agent found it), [[SM958]].
