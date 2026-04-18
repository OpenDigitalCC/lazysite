---
title: Upgrading to external auth
subtitle: Replace built-in auth with Authentik, Authelia, or another proxy.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

The built-in auth (`lazysite-auth.pl`) and external auth proxies use
the same mechanism: HTTP headers. The processor reads `X-Remote-User`
and `X-Remote-Groups` regardless of what sets them. Upgrading from
built-in to external requires no changes to pages or the processor.

## Steps

1. Set up your auth proxy (Authentik, Authelia, etc.) with your domain
2. Configure the proxy to forward `X-Remote-User` and `X-Remote-Groups`
   headers to the backend
3. If your proxy uses different header names, update `lazysite.conf`:

```yaml
auth_header_user: Remote-User
auth_header_groups: Remote-Groups
```

4. Change the Apache `FallbackResource` from `lazysite-auth.pl` back
   to `lazysite-processor.pl`:

```apache
FallbackResource /cgi-bin/lazysite-processor.pl
```

5. Replace `login.md` with a redirect to your proxy's login page
6. Test:

```bash
curl -H "X-Remote-User: alice" -H "X-Remote-Groups: admins" \
  https://example.com/protected-page
```

## What stays the same

After upgrading, these all work identically:

- `auth: required` and `auth: optional` in front matter
- `auth_groups:` access restrictions
- `[% authenticated %]`, `[% auth_user %]` and other TT variables
- Custom `403.md` with context variables
- Cache behaviour (protected pages never cached)

## What changes

- Login is handled by the external proxy, not `login.md`
- `lazysite-auth.pl` is no longer in the request path
- User management moves from `lazysite-users-lite.pl` to the proxy's
  admin interface
- Cookie-based sessions are replaced by the proxy's session mechanism
