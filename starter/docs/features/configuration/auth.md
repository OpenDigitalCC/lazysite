---
title: Authentication
subtitle: Protect pages with login requirements and group-based access control.
tags:
  - configuration
  - authoring
---

## Authentication

Pages can require authentication via the `auth:` front matter key.
The processor reads `X-Remote-*` HTTP headers set by an auth wrapper
or external proxy, enforces access control, and makes auth context
available as TT variables.

### Protecting a page

    ---
    title: Members Area
    auth: required
    ---

Values: `required` (must be logged in), `optional` (read headers if
present), `none` (no check, the default).

### Group-based access

    ---
    title: Admin Dashboard
    auth: required
    auth_groups:
      - admins
      - editors
    ---

User must be in at least one listed group. Wrong group returns 403.

### Site-wide default

Set in `lazysite/lazysite.conf`:

    auth_default: required

Pages without `auth:` inherit this value. The login page is always
accessible regardless of the site-wide default.

### TT variables

Available in page content and the view template:

- `[% authenticated %]` - 1 if logged in, 0 otherwise
- `[% auth_user %]` - username
- `[% auth_name %]` - display name
- `[% auth_email %]` - email address
- `[% auth_groups %]` - array of group names

### Custom 403 page

Create `403.md` with these context variables:

- `[% auth_denied_reason %]` - `insufficient_groups` for group denial
- `[% auth_required_groups %]` - array of required groups
- `[% auth_user %]` - authenticated username

### Notes

- Protected pages are never cached to disk
- Protected responses include `Cache-Control: no-store, private`
- The login page (`auth_redirect` path) is always public
- Works with built-in `lazysite-auth.pl` or any external proxy
  (Authentik, Authelia, etc.) that sets the same headers
- [Authentication guide](/docs/auth) - full setup and configuration
- [Upgrading to external auth](/docs/auth-upgrade) - migration guide
