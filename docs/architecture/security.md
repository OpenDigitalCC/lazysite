# Security

## Security model

lazysite's security model has three layers. Each depends on the one
above it.

1. **The web server (Apache, nginx, or equivalent).** Terminates TLS,
   strips or rewrites untrusted headers, routes requests to the
   correct CGI script, and enforces file-system permissions. This
   layer is operator-configured; lazysite provides config templates
   but cannot enforce policy here.
2. **The auth wrapper (`lazysite-auth.pl`).** Validates the signed
   session cookie, sets `HTTP_X_REMOTE_USER` and
   `HTTP_X_REMOTE_GROUPS` from the cookie payload, sets the
   `LAZYSITE_AUTH_TRUSTED=1` sentinel, and `exec`s the target CGI
   script (processor, manager-api, or another plugin). The wrapper
   is the single point where a browser's auth cookie becomes
   lazysite's notion of "who is logged in".
3. **Per-page access control.** Each Markdown page may declare
   `auth: required`, `auth_groups: [...]`, or `payment: required`
   in its front matter. The processor enforces these before
   rendering.

## Authentication

### Cookie format

```
<username>:<timestamp>:<groups_csv>:<hmac_sha256>
```

The payload is `username:timestamp:groups_csv`, URL-encoded. The
HMAC is computed over the payload with a per-installation secret.

### Cookie attributes

Set on every successful login:

```
HttpOnly; SameSite=Lax; Path=/; Max-Age=86400; Secure (HTTPS only)
```

`Secure` is added when `$ENV{HTTPS}` is set. On HTTP the cookie is
still `HttpOnly` and `SameSite=Lax`. The 24-hour `Max-Age` is the
session ceiling.

### HMAC secret

Stored in `lazysite/auth/.secret`. Generated on first need from
`/dev/urandom` (32 bytes, hex-encoded). The file is mode `0600` and
the `auth/` directory is mode `0750`. The code fails closed if
`/dev/urandom` is not readable - there is no weaker fallback.

### Password storage

Salted iterated SHA-256 using only `Digest::SHA` (core).

Storage format:

```
<username>:sha256iter:<32-hex-salt>:<iterations>:<64-hex-hash>
```

Current parameters: 100,000 iterations, 16-byte random salt.

Legacy unsalted SHA-256 hashes (from earlier releases) are still
accepted on login. On successful authentication against a legacy
hash, the user's row is rewritten in the new format transparently.

Password verification uses constant-time comparison to defeat
timing attacks against the hash prefix.

### Session duration and revocation

Cookies expire after 24 hours (via `Max-Age=86400`). There is no
server-side session store. Logout sets an expired cookie on the
client; the HMAC remains cryptographically valid until the 24-hour
window passes. This is the trade-off for a stateless auth model -
see "Known constraints" below.

### Localhost bypass

When `$ENV{REMOTE_ADDR}` is exactly `127.0.0.1` or `::1`, a user
whose `lazysite/auth/users` row has an empty password hash can log
in without supplying one. The manager admin bar shows a visible
warning in that state.

`X-Forwarded-For`, `X-Real-IP`, and other proxy headers are **not**
consulted for this decision. Only the connection's immediate
remote address matters. This means a reverse proxy that terminates
on localhost still has to go through the real auth flow for non-
proxy-origin users.

### Login rate limiting

5 failed login attempts per IP per 5-minute window trigger a
reject. A 2-second sleep is added to every failed login response.
State is persisted in `lazysite/auth/.login-rate.db` (DB_File).

This is per-IP, so an attacker rotating IPs can defeat it. It
raises the cost meaningfully for drive-by brute force.

## Authorisation

### Per-page auth

Declared in front matter:

```yaml
auth: required       # any authenticated user
auth_groups:         # authenticated AND in any listed group
  - editors
  - admins
```

`auth: none` (the default) bypasses all checks.

Unauthenticated requests to `auth: required` pages are redirected
to `/login?next=<encoded-uri>`. `sanitise_next()` guarantees the
redirect target is a local path.

Forbidden requests (authenticated but wrong group) return 403 via
the `serve_403` handler, which renders `403.md` if present and a
minimal HTML page otherwise.

### Manager access

`manager_groups:` in `lazysite.conf` names the groups whose members
can access `/manager/*` and the manager API.

If `manager_groups:` is set: only users in one of the listed groups
pass. Any other authenticated user gets redirected to `/login`.

If `manager_groups:` is empty: any authenticated user has manager
access. A DEBUG-level log line is emitted when this condition is
encountered, to surface the "open manager" configuration to the
operator without flooding INFO-level logs on every request.

### Payment

`payment: required` in front matter integrates with x402. The
processor looks for `HTTP_X_PAYMENT_VERIFIED=1` as the signal that
an upstream payment proxy has validated the payment. If absent, the
processor emits a 402 response with an `X-Payment-Response` header
in the x402 shape. Demo mode is handled by
`lazysite-payment-demo.pl`.

Payment bypass via group membership is supported:
`auth_groups: [members]` on a `payment:` page allows authenticated
members through without the payment header.

## Auth proxy trust model

The processor reads `HTTP_X_REMOTE_USER` to identify authenticated
users. That header must only come from a trusted source. If a
client can set it directly, authentication is trivially bypassed.

Two trust paths are supported:

1. **Built-in auth wrapper** (`lazysite-auth.pl`). The wrapper
   validates the cookie HMAC, sets `HTTP_X_REMOTE_USER` and
   `HTTP_X_REMOTE_GROUPS` from the validated cookie, sets
   `LAZYSITE_AUTH_TRUSTED=1`, then `exec`s the target. The processor
   trusts the headers because the sentinel is set.
2. **External proxy** (mod_auth_mellon, Authelia, oauth2-proxy,
   nginx `auth_request`, HTTP Basic via Apache, etc.). The operator
   opts in by setting `auth_proxy_trusted: true` in `lazysite.conf`.
   The operator is responsible for ensuring the proxy strips any
   client-supplied `X-Remote-*` headers before setting its own.

Default (`auth_proxy_trusted: false` or absent): if
`HTTP_X_REMOTE_USER` arrives without the `LAZYSITE_AUTH_TRUSTED=1`
sentinel, the processor logs a WARN and **ignores** the header.
This is the correct behaviour for the no-proxy configuration.

### Apache config requirement

When lazysite is deployed behind Apache (including the shipped
Hestia template), strip client-supplied headers at the vhost level:

```apache
RequestHeader unset X-Remote-User
RequestHeader unset X-Remote-Groups
RequestHeader unset X-Remote-Name
RequestHeader unset X-Remote-Email
RequestHeader unset X-Payment-Verified
RequestHeader unset X-Payment-Payer
```

Put these near the top of the vhost, before any component that
legitimately sets them. The auth wrapper and your trusted upstream
are the only things that should be able to populate these vars.

## Input handling

### Path validation

Every path derived from request input passes `Cwd::realpath()` and
is verified to start with `$DOCROOT` before any file operation.
The checks are applied at every ingress point:

- Processor: `process_md`, `process_url`, `_resolve_include`,
  `resolve_scan`, `write_html`, `is_fresh_ttl`.
- Manager API: every action that touches the file system
  (`action_list`, `action_read`, `action_save`, `action_delete`,
  theme operations).

`sanitise_uri()` additionally rejects null bytes, path-traversal
sequences (`..` segments), and suspicious characters (`<>"'`)
before any file operation is attempted.

### SSRF prevention

`fetch_url()` resolves the target hostname via `Socket::inet_aton`
and rejects the result if it lies in any of:

- Loopback (`127.0.0.0/8`, `::1`)
- RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- Link-local (`169.254.0.0/16`, IPv6 `fe80::/10`)
- Multicast (`224.0.0.0/4`)
- Carrier-grade NAT (`100.64.0.0/10`)
- `0.0.0.0`

Applied to every outbound fetch path: `:::include`, `url:` TT
variables, remote theme fetching, and oEmbed endpoint discovery.
DNS rebinding is not addressed - the `inet_aton` result at fetch
time is what is checked. Operators who expose lazysite to the
public internet and who rely on blocking access to an internal
network should not depend on the SSRF guard alone.

### Header injection (SMTP)

Form-handler `sanitise_header()` strips `\r\n` from every form
field value before it is used to construct email headers. This
prevents CR/LF injection into `From`, `To`, `Subject`, and extra
headers.

### Open redirect

`sanitise_next()` in `lazysite-auth.pl` accepts only paths matching
`\A/[\w/.\-]*\z` and explicitly rejects inputs starting with `//`
or `\`. This closes the `?next=//evil.com` vector that would
otherwise turn a successful login into an off-site redirect.

### Template injection

`Template->new()` is invoked with `EVAL_PERL => 0` at every call
site. `[% PERL %]` blocks are refused by the Template engine.
Front-matter values are passed through `strip_tt_directives()`
before being made available as TT variables, so a page author
cannot smuggle directives into their own `title` or `subtitle`.

### CSRF protection

The manager API requires an `X-CSRF-Token` header on every
`POST` request. The token is
`HMAC-SHA256("csrf:<user>:<hour>", secret)`, rotated hourly. The
server accepts the current hour and the previous hour so token
freshness does not race the rollover.

GET requests (read-only actions: `list`, `read`, `cache-list`,
`theme-list`, `plugin-list`, `nav-read`, `handler-list`,
`form-targets-read`, `csrf-token` itself) pass without a token.

The manager view template installs a `window.fetch` wrapper in
`<head>` that automatically attaches the token to every POST
destined for the manager API. The token is fetched once per page
load via `GET ?action=csrf-token`. Any body type (JSON,
`FormData`, `ArrayBuffer` for theme upload) works, because the
token travels in the header rather than the body. The
`beforeunload` handler in `edit.md` uses `navigator.sendBeacon`,
which cannot set headers, so it appends the token as a query
parameter instead.

## HTTP response headers

Emitted by the processor on every response via `output_page`:

```
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
Referrer-Policy: strict-origin-when-cross-origin
Cache-Control: <varies>
Vary: Cookie
```

`Cache-Control` varies by page type:

- `no-store, private` on auth- or payment-protected pages and on
  the login/logout surface.
- `public, max-age=N` when the page declares a front-matter
  `ttl: N`.
- `no-cache, must-revalidate` as the default for rendered pages.

Not emitted by the processor (set at web server level, because the
policy depends on site-specific and deployment-specific factors):

- `Content-Security-Policy` - site-specific (depends on which
  external resources pages load; embedded oEmbed, fonts, analytics
  etc.).
- `Strict-Transport-Security` - should only be set over HTTPS, and
  the operator controls whether HTTPS is in use.

## Rate limiting

| Surface | Limit | Backing store |
|---|---|---|
| Login (per IP) | 5 attempts / 5 min | `lazysite/auth/.login-rate.db` (DB_File) |
| Form submission (per IP) | 5 submissions / hour | `lazysite/forms/.rate-limit.db` (DB_File) |
| Manager API | no rate limit | - |

The form handler also checks a honeypot field (`_hp`) and a
timestamp token (`_ts`, `_tk`) for spam detection. The manager API
is rate-unlimited by design: it requires authentication, and
authenticated operators are expected to be trusted.

## Known constraints

**Session revocation.** No server-side session store. Individual
logout invalidates the cookie on the client only; the HMAC
remains cryptographically valid until its `Max-Age` passes. A
cookie stolen via XSS, browser exfiltration, or a compromised
device would otherwise remain valid for up to 24 hours.

Mitigations:
- Short session lifetime (24 hours).
- `HttpOnly` cookie attribute.
- Installation-specific HMAC secret in `lazysite/auth/.secret`.
- **"Log out all users"** action on the manager Users page
  (`action=rotate-auth-secret`). Generates a fresh secret from
  `/dev/urandom`, writes it atomically, and invalidates every
  outstanding cookie in one step (the operator's own included).
  The manager UI redirects the caller to `/login` on success. Use
  this on suspected secret compromise, before decommissioning an
  installation, or routinely at operator's discretion.

**Password algorithm.** Salted iterated SHA-256 rather than
bcrypt or argon2. Chosen because only `Digest::SHA` is core; no
external dependency is required. 100k iterations provide
meaningful brute-force resistance for the threat model. When
`Crypt::Argon2` is available on the host, the same verify/rehash
machinery supports a drop-in upgrade path.

**Zip extraction dependency.** Theme uploads require
`Archive::Zip`. Install via `libarchive-zip-perl` on Debian
derivatives. The install script warns if the module is missing;
the feature gracefully returns an error at upload time rather
than crashing.

**Dev server parity.** The development server
(`tools/lazysite-server.pl`) and production Apache use the same
auth-wrapper routing: every `/cgi-bin/*.pl` request (except
those targeting `lazysite-auth.pl` itself) passes through the
auth wrapper before reaching its target CGI. Behaviour matches
production for auth, CSRF, header forwarding, and security-
relevant response headers. The dev server is still clearly
marked as development-only - it is single-threaded and does not
handle TLS, concurrent long-running requests, or graceful
restarts.

**No server-side CSRF for static assets.** CSRF protection
applies only to the manager API. The payment and form handlers
have their own protections (HMAC timestamp tokens, honeypot,
rate limits) appropriate to their flows.
