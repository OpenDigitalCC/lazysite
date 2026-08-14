---
title: Authentication
subtitle: Protect pages with built-in auth or an external proxy.
register:
  - sitemap.xml
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

The HMAC secret lives at `lazysite/auth/.secret` (chmod 0660 -
owner + group, never world, so the site user's CLI tools and the
web-server CGI can both use it whichever minted it first).

### Sessions

A session is the signed cookie itself - there is no server-side session
store on the request path. Two small side files make sessions visible and
revocable: at login the cookie payload carries a random session id and one
line (who / when / IP / device) is appended to
`lazysite/auth/sessions.jsonl` (self-pruned after 24 h), and cookie
verification consults `lazysite/auth/revoked.json` when it exists. The
manager **Sessions** page lists the live sessions and can sign out a single
session, all of one user's sessions ("Sign out everywhere"), or - by
rotating the signing secret - everyone at once. Losing the registry only
degrades the listing; cookies minted before this feature cannot be listed
but are still killable per-user or by rotation.

### Dev server

The dev server auto-detects built-in auth when `lazysite/auth/users`
exists and uses the auth wrapper automatically.

## Self-service credentials and two-factor

The operator creates an account and sets its parameters; the **user provisions
their own secret**. The operator never sets or handles a password. One primitive
underlies every flow: a single-use, short-lived, hashed **claim token**.

### Setup links (the user sets their own password)

On the Users page, an account card has **Generate setup link** next to *Generate
credential*. It mints a claim and shows a one-time URL (`…/claim?u=<user>&c=<code>`)
to hand over by any channel. The user opens it and the `/claim` page presents a
**set-a-password** form (interactive account) or a **mint-and-reveal-token** action
(machine account). The claim is consumed on success and expires after 24 h.

- **Reset credential** mints a fresh claim *and revokes the current credential*, so
  the account cannot authenticate until the new claim is redeemed - the forced
  reset for a lost or compromised secret. A plain setup link is additive (the old
  credential keeps working until redeemed).
- Disabled accounts and token-only (`ui` off) accounts cannot redeem a
  set-password claim.

### Forgot password (email, when SMTP is configured)

Where the SMTP plugin is configured and the account has an `email`, `/login` shows
a **Forgot password?** link → `/forgot` takes a username or email and mails a
set-password claim. The response is identical whether or not an account matched -
it never reveals whether an account or email exists. The reset email is recorded
in the audit trail (action `forgot`) against the matched account.

### Two-factor (TOTP)

An interactive account can enrol TOTP two-factor (RFC 6238). Enrolment shows a
shared secret + an `otpauth://` URI (QR) and issues one-time **recovery codes**;
after enrolment, login requires a valid 6-digit code (or a recovery code) before
the cookie is issued. Two-factor applies to interactive (password → cookie) login
only - token / WebDAV / connector auth is unchanged, since the token is already
the strong factor there.

    # enrol from the CLI (or via the Users page card action)
    perl tools/lazysite-users.pl --docroot /path/to/public_html mfa-enroll alice

The shared secret lives in `user-settings.json` under the same `0640`/`2770`
protection as other credentials (the auth dir is off the web and group-restricted;
no at-rest encryption - an accepted tradeoff for self-hosting).

### Account expiry

An account may carry `expires_at` (an epoch); after it, **all** authentication for
that account fails - time-boxed access for a contractor or a temporary partner.
Distinct from token expiry.

### Security model

- Claims, connect codes, and recovery codes are 256-bit random, **hashed at rest**,
  **single-use**, short-TTL, and rate-limited per IP and per account.
- **Generic responses** everywhere - `/forgot`, `/claim`, and the partner exchange
  never reveal whether an account, email, or claim is valid beyond success/failure.
- **HTTPS only**; plaintext is refused (as for `/dav`).
- Material events are audited: `claim-redeem`, `forgot`, `token-exchange`,
  `token-rotate`, `user-claim-create`, `user-mfa-enroll`, and the OAuth events
  (`oauth-register`, `oauth-authorize`, `oauth-refresh`, `connect`).

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

**It applies to pages, not to files.** A `.html` with no Markdown source, a PDF,
an image or a downloadable archive is not a page - it has no front matter, so
there is nothing for this setting to inherit into. `auth_default: required` will
bounce every page to the login form and still serve those files to anyone who
knows the path. Protecting them is the next section, and it is a separate,
explicit act.

### Protecting static files

A file with no page source is protected by giving it an entry in
`lazysite/auth/acls.json` - the same per-file access list the manager, WebDAV and
the MCP connector already use. A `read` list is what protects it:

```json
{
  "private/brief.pdf": { "read": ["alice", "@staff"] },
  "private":           { "read": ["@staff"] }
}
```

- A **path** entry governs that file.
- A **folder** entry governs everything beneath it. The longest match wins, so a
  tighter rule on a file beats a broader one on the folder above it.
- Names are users; `@name` is a group.

Three behaviours worth knowing before you rely on it:

- **No entry means served.** Files you have said nothing about are public, exactly
  as before. Nothing changes on a site that has not written an ACL.
- **An entry with only an `owner` does not protect anything.** Ownership is not a
  read restriction here, and it is not one in the manager either. You need a
  `read` list.
- An anonymous request for a protected file is sent to the login page; a signed-in
  user who is not permitted gets `403`. Protected files are never stored by a
  shared cache.

To see what is already restricted, and what has actually been refused, see
*Auditing access* below.

#### Protecting a whole section

The same folder entry gates the section's **pages**, not only its files. To hold
back an unfinished area, write one entry:

```json
{ "upcoming": { "read": ["@editors"] } }
```

Every page under `/upcoming/` now requires an editor, and so does every image and
PDF in it - one rule, one place. No page in the section needs `auth:` front
matter, and a page that carries `auth: none` does **not** escape the section
gate: a section you can hold back only if every page inside it agrees is not a
section gate at all.

**Publishing is deleting the entry.** Remove it and the whole subtree goes public
in one act - no per-page edits, no partially-released section.

A page under a gated prefix is never written to the shared HTML cache, so a
render for a permitted user cannot leak to the next anonymous visitor.

#### Holding a section back before launch

A protected section answers with a login redirect, which tells anyone who tries
the URL that it exists. For a section that is not ready to be *known about* -
an unlaunched product, a client area before announcement - add `draft`:

```json
{ "upcoming": { "read": ["@editors"], "draft": true } }
```

That changes two things:

- **the refusal becomes a 404.** Nothing about the URL is disclosed - not to the
  public, and not to a signed-in user outside the list either, since a 403 gives
  the section away just as effectively.
- **the section disappears from every listing** - `sitemap.xml`, `llms.txt`, the
  feeds, and any `scan:` page list. That is unconditional: a registry file is
  generated once and then served to everyone from disk, so a draft page listed in
  it is published no matter what the page itself answers.

Editors on the `read` list preview it normally by signing in. With **no** `read`
list, any signed-in user may preview it and the public still cannot - `draft`
deliberately breaks the usual "no read list means anyone" rule, because a draft
that was public would not be a draft.

**Publishing is removing `draft`** - or removing the entry entirely, which also
drops the access gate. The section goes live and enters the sitemap on the next
render.

#### Your web server has to co-operate

This is the part that catches people. A web server answers a request for an
existing file from disk without consulting anything - that is what web servers
are for. When it does, lazysite never sees the request and **no ACL can apply.**

So the front end has to be told: *when this site has an ACL store, hand existing
files to lazysite instead of serving them.* The shipped Apache and nginx
templates and the built-in dev server already do this, and there is nothing to
configure - install or regenerate the vhost and it is in place.

If you run **any other web server** - Caddy, lighttpd, a CDN or a reverse proxy
in front - you must add the equivalent rule yourself, or ACLs on static files
will silently do nothing. The rule is:

> If `<docroot>/lazysite/auth/acls.json` exists, route a request for an existing
> file to `/cgi-bin/lazysite-auth.pl` instead of serving it from disk.

Two details that are easy to get wrong:

- **Route at `lazysite-auth.pl`, not at the processor.** The auth wrapper
  validates the session cookie and passes a trusted identity through. Pointing
  straight at `lazysite-processor.pl` gives it no usable identity, so every
  protected file bounces to the login page for *everyone* - including the people
  entitled to read it.
- **Test for the ACL file, not for a path prefix.** Gating on the file's
  existence is what keeps this free: a site with no ACLs never enters the branch
  and keeps direct static serving at full speed, and adding a protected path
  later needs no configuration change and no reload. The cost, stated plainly: on
  a site that *does* have an ACL, every static request goes through lazysite.

Verify it before trusting it. With an ACL in place, request a protected file
while signed out:

```bash
curl -sSI https://example.com/private/brief.pdf
```

A `302` to the login page (or a `403`) means the rule works. A `200` means your
web server is still answering from disk and the ACL is being ignored.

### Auditing access

Two questions, two answers.

**What is restricted right now** - read the store directly:

```bash
jq -r 'to_entries[] | select(.value.read != null and (.value.read | length) > 0)
       | "\(.key)\t\(.value.read | join(","))"' lazysite/auth/acls.json
```

Anything listed is refused to everyone outside its list. This matters after an
upgrade: an entry originally written to keep other *editors* out of a file now
also keeps anonymous visitors out of it, which is usually the intention and
occasionally is not.

**What has actually been refused** - the access log flags an access refusal with
`"ar":1`, because no status code can express it (the anonymous case is a `302` to
the login page, identical to any other redirect):

```bash
grep -h '"ar":1' lazysite/logs/access-*.jsonl | jq -r .p | sort | uniq -c | sort -rn
```

The same data appears as `auth_refused` in the `analyse_visitors` report, so an
AI assistant with the analytics capability can answer this without shell access.
A path there that you believe is public is the signal to check its ACL entry.

### Who may grant what

A capability is conferred by turning it on for a group. Two rules govern who may
do that:

- an **operator** may confer anything;
- a **delegate** (someone with `manage_users` but not operator) may confer a
  capability only if they **hold** it, or if an operator has put it in one of
  their groups' **grant authority**.

Removing a capability is always allowed - that is de-escalation and needs no
authority.

**Grant authority** exists so a delegate does not have to hold a capability
merely to hand it to someone else. An agency sub-admin who manages an AI agent
should be able to grant the agent `mcp` without carrying `mcp` on their own
account, which would enlarge their surface for a purely administrative act:

```bash
# operator only
perl tools/lazysite-users.pl --docroot /path/to/public_html \
  group-set client-admins grantable mcp,api
```

Members of `client-admins` may now confer `mcp` and `api` on the groups they
manage, and still do not hold either themselves.

Setting `grantable` is **operator-only**, and that is what makes it safe: grant
authority is conferred from above and never self-assumed. A delegate that could
widen its own grant authority would have no ceiling at all. Making a group a
manager group (`manager`) is operator-only for the same reason.

**Upgrading from before 0.10.5:** there was no ceiling - `manage_users` alone
allowed conferring any capability, including on a group the delegate belonged to.
If your delegates rely on that, give them explicit grant authority for the
capabilities they legitimately hand out; otherwise those grants now refuse, and
the refusal names the command that fixes it.

### Manager access

The manager at `/manager` uses the same auth mechanism. Access is the
**`ui` capability**, granted through a group on the manager Groups page
(the seeded `lazysite-admins` group carries it):

```yaml
manager: enabled
manager_path: /manager
```

Capabilities on groups are the mechanism of record. (The legacy
`manager_groups:` conf key is retired: on upgrade any group it named receives
its capabilities explicitly and the conf line is removed.)

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
