# Security

## Security model

lazysite's security model has three layers. Each depends on the one
above it.

1. **The web server (Apache, nginx, or equivalent).** Terminates TLS
   and forwards requests. It is operator-configured, and **since 0.10.8
   it no longer needs to make content decisions** - see "The front door"
   and "Content outside the served tree" below. That change is the
   response to SM248, SM268 H17 and SM283, which were one cause: security
   living in front-end configuration that lazysite ships as a template,
   cannot test where it is installed, and on most deployments cannot see.
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

## Content outside the served tree (SM286)

Until 0.10.7, protecting a path left its bytes in the document root and
relied on an access decision the engine made per request. That is safe
only while every request actually reaches the engine - and three separate
incidents were exactly the case where one did not.

Since 0.10.8, **protecting content moves it out of the document root**,
into a private store beside it:

    dirname(<docroot>)/basename(<docroot>)-lazysite-private

The store is **derived, never configured**, and is named for the docroot,
so two sites under one parent can never share one. `Lazysite::Private`
holds the invariant that content is in exactly one tree at any moment: the
failure direction is "not moved", never "in both". `resolve_for_write`
checks the public ancestor first, so a store container directory cannot
itself be mistaken for a gate.

What this changes in threat terms: a front end that serves a file without
consulting the engine can no longer serve *protected* content, because the
bytes are not in the tree it serves. This is structural rather than
configurational - it does not depend on the operator having applied a
template correctly.

Two properties an assessor should know:

- **The move happens on the act of protecting.** A section protected
  before 0.10.8 stays in the document root until its rule is re-applied.
  This is an operator action that no package upgrade performs.
- **A failed move does not refuse the rule.** The ACL is stored and
  honoured, so the site is no worse off than before the store existed -
  but the response says so, because both outcomes look identical to the
  operator otherwise. (SM296 is the defect where that warning could not be
  reached; see `docs/feature-requests/SM296-*`.)

The store is created by the CGI identity, so it must be able to write the
directory beside the docroot. `lazysite check` reports whether the store
exists and is writable, naming the directory, its owner and its mode, and
speaks only on a site that actually protects something.

## The front door (SM293)

`lazysite-front.pl` is a CGI surface a front end can be pointed at so that
the front end's whole job becomes "forward everything". Every routing
decision the vhost templates used to make - which URLs reach which
surface, which are wrapped by the auth wrapper, when an existing static
file must be handed to the engine instead of served, what is refused
outright - is made by `Lazysite::FrontDoor::route()`.

`route()` is a **pure function**: it takes the request and the site's
shape and returns a decision, opening no sockets, exec'ing nothing and
printing nothing. That is what makes the whole routing table directly
testable (`t/unit/lib/21`), which the vhost templates never were, because
testing those means installing them on the web server the operator
actually runs. `t/lint/39` asserts the module and the shipped templates
agree, so the migration cannot change behaviour while claiming to preserve
it, and `t/integration/49` drives the shape through real Apache.

The trade is stated rather than hidden: with one rule, a request for an
image on a site that protects nothing costs a process start the web server
would not have charged. The fuller templates therefore remain as
**performance** options whose absence costs speed and never correctness.
SM294 adds a pooled path where the hot path is answered in-process.

Two consequences for the threat model:

- **The routing table is now a single point of correctness.** If it is
  wrong it is wrong for every request rather than for one rule. That is
  the reason it is a pure function with a direct unit test and a lint
  pinning it against the shipped templates.
- **Trust headers are gated in the application** (SM293 step 4). The
  engine refuses `X-Remote-*` unless the auth wrapper vouched for the
  request or the operator opted into a trusted proxy, enforced by
  `t/lint/38`. Stripping them at the front end remains recommended
  hardening; it is no longer the only thing standing between a client and
  a forged identity. See "Hard deployment requirement" below, which is now
  defence in depth rather than the sole control.

## Authentication

### Cookie format

```
<username>:<timestamp>:<sid>:<groups_csv>:<hmac_sha256>
```

The payload is `username:timestamp:sid:groups_csv`, URL-encoded. The
HMAC is computed over the payload with a per-installation secret.
`sid` (SM141) is a random 16-hex session id minted at login so the
session can be listed and revoked individually; legacy 3-field
payloads (`username:timestamp:groups_csv`, from cookies issued before
SM141) verify identically and stay valid until natural expiry - the
sid's fixed shape disambiguates the two forms.

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
`/dev/urandom` (32 bytes, hex-encoded). The file is mode `0660` -
owner + group, never world: on a group-shared docroot either identity
(the site user's CLI context or the `www-data` CGI, joined by the
setgid `auth/` dir's group) may mint it first, and an owner-only file
would 500 the other side's cookie verification (field 2026-07-11).
The `auth/` directory is mode `02770`. The code fails closed if
`/dev/urandom` is not readable - there is no weaker fallback.

### Password storage

Salted iterated SHA-256 using only `Digest::SHA` (core).

Storage format:

```
<username>:sha256iter:<32-hex-salt>:<iterations>:<64-hex-hash>
```

Current parameters: 100,000 iterations, 16-byte random salt.

**Generated credentials (SM070).** `tools/lazysite-users.pl token`
issues a 256-bit random credential (`lzs_<64 hex>`) and stores it in
the same format but with **iterations=1**. A 256-bit random secret is
not brute-forceable, so the iteration stretching that protects
low-entropy human passwords buys nothing, while WebDAV verifies the
credential on every request — one SHA-256 versus 100,000. Only the
`token` path writes iterations=1; `add`/`passwd` keep 100,000.
`verify_password` reads the iteration count from the stored row, so no
verifier change was needed.

Legacy unsalted SHA-256 hashes (from earlier releases) are still
accepted on login. On successful authentication against a legacy
hash, the user's row is rewritten in the new format transparently.

Password verification uses constant-time comparison to defeat
timing attacks against the hash prefix.

### Session duration and revocation

Cookies expire after 24 hours (via `Max-Age=86400`). There is no
server-side session store on the request path; logout sets an expired
cookie on the client. Since SM141 sessions are individually revocable:
login appends an advisory line ({sid, user, t, ip, ua}) to
`lazysite/auth/sessions.jsonl` (24-hour self-pruning; a registry
failure never blocks login), and cookie verification in the auth
wrapper - the single enforcement point - checks
`lazysite/auth/revoked.json`: revoked sids, plus a per-user
`not_before` timestamp that invalidates every cookie issued before it
(including pre-sid legacy cookies, which carry `ts`). An absent file
costs one `stat`; an unreadable or corrupt file fails open with a loud
warning (no session revoked) rather than locking everyone out. The
manager Sessions page drives both (`manage_users`-gated, audited);
rotating the HMAC secret remains the invalidate-everything lever - see
"Known constraints" below.

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

Manager access is carried by **groups**. A group in
`lazysite/auth/groups-settings.json` grants the `ui` capability
(access to `/manager/*` and the manager API) and, for the operator
powers, `manage_users`; an account holds the union of its groups'
grants. Grants are edited on the manager Groups page or with
`tools/lazysite-users.pl` (`setup-manager` seeds a fully-granted
admin group).

If a group granting manager access exists: only members of such a
group pass. Any other authenticated user gets redirected to
`/login`.

If **no** group grants manager access, the site is in unsecured/dev
mode. A DEBUG-level log line is emitted when this condition is
encountered, to surface the "open manager" configuration to the
operator without flooding INFO-level logs on every request.

**Corrected 2026-08-10.** This paragraph used to say "any
authenticated user has manager access". That understates it. The
manager API skips the authentication check entirely in this mode and
assigns the `local` operator sentinel
(`lazysite-manager-api.pl:287-291`), so an unsecured site is
reachable **with no credential at all**, as the operator. The
intended first-run flow is `setup-manager` from the CLI, which
creates the first manager account and ends the window; see
`docs/architecture/permissions-and-secrets.md` for the whole model
and for what a site can be pushed back into this state by.

(The legacy `manager_groups:` conf key was retired in 0.6.5, SM138,
with an automatic migration that grants its groups explicitly and
removes the conf line - see `UPGRADE.md`.)

### Payment

`payment: required` in front matter integrates with x402. The
processor looks for `HTTP_X_PAYMENT_VERIFIED=1` as the signal that
an upstream payment proxy has validated the payment. If absent, the
processor emits a 402 response with an `X-Payment-Response` header
in the x402 shape. Demo mode is handled by
`plugins/payment-demo.pl`.

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

### Upload validation

The manager `file-upload` action layers seven checks:

1. `CONTENT_LENGTH` is compared against `manager_upload_max_mb`
   before the request body is read, so an oversize request never
   allocates a buffer.
2. Per-user hourly rate limit (count + total bytes) via
   `lazysite/manager/.upload-rate.db`. Budget is reserved
   up-front from `CONTENT_LENGTH`, which slightly over-counts -
   the safe direction. Fails open on DB tie failure.
3. Target directory is resolved via `realpath()` and rejected
   unless it lies under `$DOCROOT`.
4. Each filename is reduced to its basename, stripped of null
   bytes and control characters, and rejected if it is empty,
   `.`, or `..`.
5. Each target path is checked against the built-in
   `@BLOCKED_PATHS` list plus the `.pl` rule (`is_blocked_path`).
6. Each target path is checked against the configurable
   `manager_blocked_paths` (renamed from
   `manager_upload_blocked_paths` in SM019c; the old key is
   still accepted with a deprecation log) and
   `manager_upload_blocked_extensions` lists
   (`is_blocked_config`). The path list also gates
   `action_save`, `action_delete`, `action_mkdir`,
   `action_file_download`, and `action_file_zip_download`,
   so a manager cannot siphon or overwrite protected
   directories through any of those surfaces. The extension
   list stays upload-only.
7. Writes go to a per-pid tempfile then `rename()` to the final
   name. Short-write failures surface as per-file errors; a
   partial file is never left in place.

The editor additionally suppresses binary files: `action_read`
returns `{ok: 0, binary: 1}` for any extension not in
`%TEXT_EXTENSIONS`, and the editor shows a download panel
instead of a CodeMirror instance. The file browser duplicates
the same extension set so binary files render without an edit
link but remain downloadable. `.pm` and `.sh` are in the
editable set (so an operator can edit an existing script) but
are not in the default upload blocklist beyond what an operator
chooses to configure - `manager_upload_blocked_extensions`
defaults to `pl,cgi`. Dotfiles such as `.htaccess` have their
"extension" (the suffix after the last dot) captured as
`htaccess` which is not listed in `%TEXT_EXTENSIONS`, so they
are treated as binary in the editor.

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
`pagehide` handler in `edit.md` (edit-lock release) uses
`navigator.sendBeacon`, which cannot set headers, so it appends
the token as a query parameter instead.

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
| Manager upload (per user) | 60 requests + 500 MB / hour (configurable) | `lazysite/manager/.upload-rate.db` (DB_File) |
| WebDAV auth (per IP) | 5 failed attempts / 5 min | `lazysite/auth/.dav-rate.db` (DB_File) |
| Manager API (other) | no rate limit | - |

The form handler also checks a honeypot field (`_hp`) and a
timestamp token (`_ts`, `_tk`) for spam detection. The manager API
is otherwise rate-unlimited by design: it requires
authentication, and authenticated operators are expected to be
trusted. Upload is the exception because per-request cost is
bounded by a file-size cap but an attacker who compromises a
manager account could still write a large volume of data.

## WebDAV endpoint (SM070)

`lazysite-dav.pl` is a self-contained CGI mounted at `/dav` that
exposes content over WebDAV (class 1 + 2). It is reached **directly**,
not through `lazysite-auth.pl`: it performs its own HTTP Basic
authentication and never reads cookies or `X-Remote-*` headers (and
ignores them if a misconfigured proxy injects them). Off by default
(`webdav_enabled` absent → 404, zero new surface on upgrade).

### Per-user access mechanisms

`lazysite/auth/user-settings.json` (mode 0640, written only by
`tools/lazysite-users.pl`, single-writer with temp-then-rename) holds
per-user flags:

- `webdav` (default **off**) — may this account use `/dav`.
- `ui` (default **on**) — may this account log in through the browser.
  Enforced in `lazysite-auth.pl` *after* password verification, so it
  leaks nothing to a guesser; a `ui:off` account is never issued a
  cookie, which gates the manager UI, the manager API, and
  auth-protected pages in one place. The localhost no-password bypass
  respects it too.
- `dav_scope` — **not an account field.** Confinement is resolved from
  the DOMAIN model (SM165, 0.7.26): each domain names `allowed_groups`
  and `locked_users`, and an account's scopes are the content roots of
  the domains its groups may manage, intersected up the `created_by`
  chain. The per-account and per-group `dav_scope` settings that
  preceded it are retired (SM279) and refused by the tooling; the
  resolved scopes still travel under the name `dav_scopes` everywhere
  they are enforced.

A corrupt settings file fails safe: `webdav` defaults off (closed) and
`ui` defaults on (open, matching pre-SM070 behaviour so a damaged file
cannot lock the operator out), with a WARN. `user-settings.json` is in
the manager API's `@BLOCKED_PATHS`, so it is not readable or writable
through the manager file surfaces.

### Request gate chain

Every request runs, in order: site gate (`webdav_enabled`, else 404) →
transport gate (HTTPS or loopback or `dav_allow_insecure`, else 403,
never challenging over plaintext) → Basic auth with a per-IP
failed-attempt limiter (5 / 5 min → 429; a missing credential just
gets a 401 challenge with no penalty) → mechanism gate (`webdav` on) →
path chain. No filesystem access happens before authentication.

### Path protection

The path chain rejects null bytes, control characters, and `..`
segments (PATH_INFO arrives server-decoded and is **not** decoded
again — double-decoding would re-open traversal), resolves the parent
via `realpath` and confirms it under `$DOCROOT` (catching symlink
escapes), then applies: whole-`lazysite/` denial (stricter than the
manager's file-level blocklist — auth data, manager, cache, and config
are unreachable over DAV), the manager's blocked-path / blocked-
extension rules on writes, and the per-user `dav_scope`. The COPY/MOVE
`Destination` is url-decoded and passes the same chain.

### Locking

WebDAV locks live in the **same store** as manager-editor locks
(`lazysite/manager/locks`), now JSON records carrying `origin`
(`dav`/`manager`), `token`, `timeout`, and an opaque `owner`. The
manager and DAV honour each other's locks (423 both ways); a legacy
single-line lock is read as `origin: manager`. Lock tokens come from
the fail-closed CSPRNG; UNLOCK requires both token **and** owner match;
manager-origin locks cannot be overridden from DAV (no client-known
token); per-user lock count is capped at 100; client `owner` XML is
truncated to 1 KiB and XML-escaped wherever echoed (no stored-XSS into
the manager lock display).

### Residual risk

No per-user WebDAV upload quota in this release (consistent with the
manager API being rate-unlimited for authenticated users except
uploads). A `dav_scope` turns a leaked deploy credential into a
content-defacement problem rather than a site takeover, so a scope is
recommended for every WebDAV-enabled account.

## Theme and layout management (SM071)

**Delegated sub-users.** Authority is two delegable permissions
(`create_sub_users`, `delegate_sub_user_creation` - the right to pass
the right on) plus a `created_by`/`managed_by` provenance tree. Account
management (disable/enable/cascade/reassign) authorises on **ancestry**:
the actor must be an ancestor of the target via `managed_by`. The
manager API injects `actor=$auth_user` for these actions, so a manager
can never manage accounts outside its own sub-tree; the operator (the
local CLI, or an account whose groups grant `manage_users`) is
unrestricted.

**Disabled and token expiry** are enforced in both `lazysite-auth.pl`
(login refused, cookie rejected) and `lazysite-dav.pl` (403 / 401),
ahead of the mechanism gate. Both fail open on a missing/corrupt
settings file (matching `ui`), so a damaged file cannot lock the
operator out.

**Token lifecycle (model A).** A single-use, short-lived pairing key is
exchanged for a short-lived access token that rotates. A leaked token
self-expires; a spent pairing key is dead.

**Control API.** The manager API accepts `Authorization: Basic
<user>:<lzs_ token>`. Token requests are CSRF-exempt (no cookie, no
ambient authority), are refused if they also carry a session cookie, and
are confined to the control-API action set, each gated by capability
(`manage_themes` / `manage_layouts` / `manage_config`). `config-set`
writes an allowlist that excludes every access-widening key.

**Per-object authoring.** Over WebDAV the active theme and active layout
are read-only; only inactive artifacts are writable. Activation is the
single validated, locked, backed-up transition; `dav_scope` does not gate
theme/layout access.

**Rate limiting.** A per-token volume bucket spans WebDAV and the control
API; 429 (throttle) and 423 (locked) responses carry `Retry-After`.

## Known constraints

**Session revocation.** No server-side session store on the request
path. Individual logout invalidates the cookie on the client only;
the HMAC remains cryptographically valid until its `Max-Age` passes
*unless revoked*. A cookie stolen via XSS, browser exfiltration, or a
compromised device would otherwise remain valid for up to 24 hours.

Mitigations:
- Short session lifetime (24 hours).
- `HttpOnly` cookie attribute.
- Installation-specific HMAC secret in `lazysite/auth/.secret`.
- **Per-session and per-user revocation** (SM141): the manager
  Sessions page signs out a single session (sid) or all of a user's
  sessions (`not_before`, which also covers pre-SM141 cookies),
  enforced at cookie verification via `lazysite/auth/revoked.json` -
  the targeted response to a stolen cookie.
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

## Hard deployment requirement: strip client trust headers

The auth model is two-layer. lazysite-auth.pl validates the session cookie and
sets `X-Remote-User` / `X-Remote-Groups` for downstream CGIs; the processor's
trust gate keeps those headers only when `LAZYSITE_AUTH_TRUSTED=1` (set
internally) or `auth_proxy_trusted: true`. **The integrity of this depends on
the web server stripping any client-supplied `X-Remote-*` / `X-Payment-*`
before a trusted component runs.** Every shipped vhost template emits
`RequestHeader unset X-Remote-User/Groups/Name/Email` and the payment headers
(needs `mod_headers`).

This is a **hard requirement, not advisory**: a single missing `RequestHeader
unset` line (e.g. on a hand-rolled vhost, or a separate API vhost) lets a client
inject its own group membership and become an operator. Defence in depth in the
code: the **token (control-API) path never consults `X-Remote-Groups` and is
never an operator** (`_is_operator` returns 0 under token auth), so a publishing
partner cannot escalate even if the strip is misconfigured; but the *cookie*
operator distinction still relies on the strip. If you front lazysite with
anything other than the shipped templates, replicate the unset directives, and
prefer a trusted-proxy IP allowlist over `auth_proxy_trusted: true`.

## Credential lifecycle and MFA (SM072)

- **One live credential per account.** A password, an `lzs_` access token, a
  pairing-key exchange, or a claim redemption each *replaces* the previous
  secret - there is never more than one active credential.
- **Single-use secrets** - claims (`lzc_`), pairing keys (`lzp_`), recovery
  codes - are stored only as `sha256iter` hashes, are short-lived (TTL'd), and
  are consumed under an exclusive `flock` (`_consume_lock`) so the
  read-verify-delete-write cycle cannot be raced into a double-redeem.
- **No enumeration.** `/claim`, `/forgot`, `/exchange`, `/rotate` return one
  generic result; login checks (disabled / expired / ui / MFA) run only *after*
  credential verification, so none leaks account existence.
- **TOTP MFA** (RFC 6238) verifies in constant time, with **replay protection**
  (a per-user `totp_last_step` rejects a re-presented code) and hashed,
  single-use recovery codes. *Accepted risk:* the TOTP seed is stored at rest in
  `user-settings.json` (group-readable by the www-data verifier); hiding it from
  the web tier would break verification, so a full web-tier compromise exposes
  per-site seeds. A separate-privilege verifier is the deferred mitigation.

## Per-file ACLs and forms (SM074)

- **ACLs** are an opt-in central store (`lazysite/auth/acls.json`, inside the
  write-denied tree) of `{owner, read[], write[]}` per content path, enforced by
  the dav (`authorise`) and the manager API. No entry = the account's `dav_scope`
  only. The store is set through the `acl-*` control-API actions, never a raw
  PUT. A token client is bound by ownership like any partner (it is not an
  operator); the actions also honour the full deny-set.
- **Forms:** a per-form dispatch config `lazysite/forms/<name>.conf` is
  agent-writable with `manage_config` (it only names operator-defined handlers);
  the secret files (`smtp.conf`, `handlers.conf`, `.smtp-password`) and the
  submissions store stay denied to agents.

The agent-facing deny set (the dav enforcement, `/.well-known/ai-partner`, the
onboarding brief, and `whoami`) is held identical by
`t/integration/06-deny-consistency.t`, so the advertised and enforced sets
cannot drift.
