---
title: Authentication
subtitle: Protect pages with built-in auth or an external proxy.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

lazysite ships with built-in cookie-based authentication as the default
path. The same mechanism supports drop-in replacement by any external
auth proxy that sets `X-Remote-*` headers (Authentik, Authelia, etc.).

The processor reads the same auth headers regardless of which model is
in use. Protected pages, group checks, and TT variables behave identically.

## Built-in auth

### How it works

`lazysite-auth.pl` authenticates users against a flat-file user
database, sets a signed HMAC cookie on success, and translates that
cookie into `X-Remote-User`/`X-Remote-Groups` headers for the
processor on subsequent requests.

On localhost, a user entry with no password hash allows password-less
sign-in. This is a development convenience; in production, every
account must have a password.

### Apache setup

Configure Apache to route requests through the auth wrapper before the
processor:

```apache
FallbackResource /cgi-bin/lazysite-auth.pl
```

The auth wrapper reads the cookie, populates auth headers, and hands
off to `lazysite-processor.pl` if the request is authenticated (or
public).

### User management

Use the manager Users page, or the `lazysite-users.pl` CLI:

```bash
perl tools/lazysite-users.pl --docroot /path/to/public_html \
  add alice secretpassword
```

```bash
perl tools/lazysite-users.pl --docroot /path/to/public_html \
  group-add alice admins
```

### User management commands

```
add USERNAME PASSWORD       Add a new user
passwd USERNAME NEWPASSWORD Change password
remove USERNAME             Remove user and group memberships
list                        List all users
group-add USERNAME GROUP    Add user to group
group-remove USERNAME GROUP Remove user from group
groups                      List all groups and members
```

### File formats

Users (`lazysite/auth/users`):

```
alice:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
bob:5994471abb01112afcc18159f6cc74b4f511b99806da59b3caf5a9c173cacfc5
```

Each line is `username:sha256hex`. Lines starting with `#` are comments.
A user line with no hash (just `username:`) allows passwordless sign-in
on localhost only.

Groups (`lazysite/auth/groups`):

```
admins: alice
lazysite-admins: alice
editors: alice, bob
members: alice, bob, carol
```

Each line is `groupname: user1, user2, ...`.

### Managing users without the script

The users file is plain text with SHA256 hex hashes. Generate a password
hash:

```bash
echo -n 'mypassword' | sha256sum | cut -d' ' -f1
```

Add a user by appending to the file:

```bash
echo "alice:$(echo -n 'mypassword' | sha256sum | cut -d' ' -f1)" \
  >> lazysite/auth/users
```

Or with Perl (if `sha256sum` is not available):

```bash
perl -MDigest::SHA=sha256_hex -e 'print sha256_hex("mypassword")'
```

Groups are plain text too - edit `lazysite/auth/groups` in any text
editor. Set permissions after editing:

```bash
chmod 640 lazysite/auth/users
chmod 644 lazysite/auth/groups
```

### Login and logout

The starter includes `login.md` and `logout.md`. The login form POSTs
to `/login` and logout is at `/logout`. On successful login a signed
cookie is set and the user is redirected to the original page (via the
`next` parameter).

### Cookie security

- HttpOnly (not accessible via JavaScript)
- SameSite=Lax
- Secure flag when HTTPS is active
- HMAC-SHA256 signed with an auto-generated secret
- 24-hour expiry

The HMAC secret lives at `lazysite/auth/.secret` (chmod 0600).

### Dev server

The dev server auto-detects built-in auth when `lazysite/auth/users`
exists and uses the auth wrapper automatically.

## Protecting pages

### Per-page auth

Set `auth:` in front matter:

```yaml
---
title: Members Area
auth: required
---
```

Values:

- `required` - user must be authenticated. Unauthenticated requests
  redirect to the login page.
- `optional` - auth headers are read if present but access is not
  restricted. Use for pages that show different content to logged-in
  users.
- `none` - no auth check. This is the default.

### Group restrictions

```yaml
---
title: Admin Dashboard
auth: required
auth_groups:
  - admins
  - editors
---
```

The user must be authenticated AND in at least one listed group.
Users in the wrong group see the 403 page.

### Site-wide default

Set `auth_default:` in `lazysite/lazysite.conf`:

```yaml
auth_default: required
```

Pages without `auth:` in front matter inherit this value. Default
is `none` when not set. The login page is always accessible
regardless of the site-wide default.

### Manager access

The manager at `/manager` uses the same auth mechanism. The
`manager_groups` setting in `lazysite.conf` lists the groups allowed
into the manager:

```yaml
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
```

## TT variables

These variables are available in page content and the view template:

- `[% authenticated %]` - `1` if user is logged in, `0` otherwise
- `[% auth_user %]` - username
- `[% auth_name %]` - display name (from users file or proxy header)
- `[% auth_email %]` - email (from proxy header)
- `[% auth_groups %]` - array of group names

Example in a view template:

```
[% IF authenticated %]
  <span>Signed in as [% auth_user %]</span>
  <a href="/logout">Sign out</a>
[% ELSE %]
  <a href="/login">Sign in</a>
[% END %]
```

## Custom 403 page

Create `403.md` in the docroot. These context variables are available:

- `[% auth_denied_reason %]` - `insufficient_groups` when group check fails
- `[% auth_required_groups %]` - array of required group names
- `[% auth_user %]` - the authenticated username
- `[% auth_name %]` - display name

The 403 page is never cached.

## External auth proxy

Any reverse proxy that sets HTTP headers works with lazysite. The
processor reads these headers by default:

- `X-Remote-User` - username
- `X-Remote-Name` - display name
- `X-Remote-Email` - email address
- `X-Remote-Groups` - comma-separated group list

### Custom header names

If your proxy uses different header names, configure them in
`lazysite/lazysite.conf`:

```yaml
auth_header_user: Remote-User
auth_header_name: Remote-Name
auth_header_email: Remote-Email
auth_header_groups: Remote-Groups
```

### Authentik

```
# In Authentik proxy provider - forwarded headers:
# X-Remote-User: %(username)s
# X-Remote-Name: %(name)s
# X-Remote-Email: %(email)s
# X-Remote-Groups: %(groups|join(","))s
```

Apache with Authentik:

```apache
<Location />
    RequestHeader set X-Remote-User "%{AUTHENTIK_USERNAME}e"
    RequestHeader set X-Remote-Groups "%{AUTHENTIK_GROUPS}e"
</Location>
```

### Authelia

Configure header names in `lazysite.conf` to match Authelia:

```yaml
auth_header_user: Remote-User
auth_header_name: Remote-Name
auth_header_email: Remote-Email
auth_header_groups: Remote-Groups
```

nginx with Authelia:

```nginx
location / {
    auth_request /authelia;
    auth_request_set $remote_user $upstream_http_remote_user;
    auth_request_set $remote_groups $upstream_http_remote_groups;
    proxy_set_header X-Remote-User $remote_user;
    proxy_set_header X-Remote-Groups $remote_groups;
}
```

## Cache behaviour

Protected pages (`auth: required` or with `auth_groups:`) are never
cached to disk and always include `Cache-Control: no-store, private`
in the response. This prevents authenticated content from being
served to unauthenticated users.

## Further reading

- [Upgrading to external auth](/docs/auth-upgrade)
- [Auth feature reference](/docs/features/configuration/auth)
