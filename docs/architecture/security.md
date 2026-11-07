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
   script (processor, manager-api, or another extension). The wrapper
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
"Known constraints" below. Since SM1040 a changed credential - any password
set by `passwd`, a redeemed claim, a 2FA disable - writes the account's
`not_before` first (a failure changes nothing) and names the session that
made the change in `kept`, beside that `not_before`: the verifier admits the
kept sid only while that `not_before` stands, so the next sign-out-everywhere
ends it as well. The manager API takes the session to keep from the verified
cookie, and only when the account is the caller's own; a request body cannot
name one. Writes to `revoked.json` are serialised by `revoked.json.lock`.

An Odoo-minted session (SM1160, `odoo_site_signin: on`) is the same cookie and the
same registry, with the user field `odoo=<login, percent-encoded>` and an empty
group field; its groups, its freshness (`checked`, against `odoo_identity_ttl`) and
its user live in the registry record, which the verifier's `odoo=` branch treats as
the authority (no record, or one for another user, is no session). It is refused on
an unsecured site, when the opt-in is off, and past the freshness bound until the
Odoo endpoint's `?csrf=1` asks Odoo and renews the record. See
docs/feature-requests/SM1160 for the full account, including what each credential
gets.

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

**SM929 did not change this, deliberately.** The engine now has one
definition of "the request address" that *can* read `X-Forwarded-For`
from a trusted proxy, and this decision keeps reading `REMOTE_ADDR`
instead - along with the plaintext-transport gates in
`lazysite-auth.pl` and `lazysite-dav.pl`. Those ask whether the
**peer** is this machine, which is a fact about the connection; the
request address answers *who the visitor is*, which is a different
question. A forwarded address that could unlock a passwordless login,
or make the engine accept Basic credentials in clear, would be the
worst place in the system to start trusting one.
`t/lint/206-a-peer-question-is-not-a-visitor-question.t` holds the
ledger of every remaining `REMOTE_ADDR` read and the reason for each,
so neither a new bare read nor the "unification" of one of these
passes unnoticed.

### Login rate limiting

5 failed login attempts per IP per 5-minute window trigger a
reject. A 2-second sleep is added to every failed login response.
State is persisted in `lazysite/auth/.login-rate.db` (DB_File), created
0660 in the auth directory's group under any umask, so the serving group can
open it whoever made it (SM1240, 0.16.1). A limiter that cannot open its
counter allows the attempt, says so in the auth log, and `lazysite check`
reports it (SM798).

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
`tools/lazysite-users.pl` (`setup-sysop` seeds a fully-granted
sysop group).

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
intended first-run flow is `setup-sysop` from the CLI, which
creates the first sysop account and ends the window; see
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
`extensions/payment-demo.pl`.

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
   opts in by setting `auth_proxy_trusted: true` in `lazysite.conf`
   **and** naming the proxy in `auth_proxy_trusted_from` (SM1129): a
   comma-separated list of addresses and CIDR ranges, IPv4 or IPv6,
   matched against the TCP peer (`REMOTE_ADDR`, never
   `X-Forwarded-For`). The identity headers are believed only from a
   listed peer; from any other they are stripped as if the flag were
   off, and a WARN names the address. With the flag on and no list,
   nobody is believed - the list fails closed. It is a separate
   setting from `trusted_proxies`, which says whose `X-Forwarded-For`
   to believe about a visitor's address. The proxy must still strip any
   client-supplied `X-Remote-*` headers before setting its own, and when
   the proxy sends a user its identity wins over a lazysite cookie
   (SM1130); `lazysite check` warns while the flag is on.
   A group the proxy names gives page and file access by name; it grants a
   manager capability, or operator status, only if its record carries
   `directory_grants` (SM1135), which only the operator sets
   (`Auth::Settings::request_cap_groups`). A cookie identity is unfiltered.

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
Since 0.16.3 the check is `Lazysite::Util::sanitise_next`, the one
function behind `/login` and the Odoo sign-in page `/odoo-signin`
(SM1299), and it also refuses a `//` anywhere in the path; anything
it refuses goes to `/`.

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
   `manager_upload_blocked_paths` in SM019c; the old key is not
   read from 0.13.13, and the upgrade renames it) and
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
`theme-list`, `extension-list`, `nav-read`, `handler-list`,
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

Emitted by the processor since SM352, on every response the engine
answers:

- `Content-Security-Policy` (or `-Report-Only`) - on HTML only, since a
  stylesheet has no script to govern. The policy is strict where
  injection happens and permissive where author content lives:
  `script-src` carries a **hash of every inline script in the response**
  rather than `unsafe-inline`, because 22 of the 23 shipped layouts
  inline one; `object-src`, `base-uri`, `form-action` and
  `frame-ancestors` are locked down; `img-src`, `media-src` and
  `frame-src` allow `https:` so an author referencing an image on
  another host is not treated as an incident. `style-src` still permits
  inline, recorded rather than dressed up: a hash cannot cover a
  `style=""` attribute and author content produces those.
- The **mode** is `csp: enforce | report-only | off` in `lazysite.conf`,
  defaulting to **report-only**. A hash does not cover an inline
  event-handler attribute, and the manager's own pages use `onclick=`,
  so an enforcing default would stop an operator's controls firing. An
  unrecognised value reads as report-only, never off.
- `Strict-Transport-Security` - emitted only over TLS, `max-age=300`
  deliberately short, with neither `includeSubDomains` nor `preload`.
- `Permissions-Policy` - every feature in `@DENIED_FEATURES`
  (`Lazysite::SecurityHeaders`) is denied (`feature=()`). A page may ask for
  one with `<feature>: self` in its front matter (SM1174 for the camera,
  SM1266 for every feature, 0.16.1): the value `self` and nothing else, that
  page alone, honoured over https only, kept per page through the cache.
  `payment` and `browsing-topics` cannot be asked for, and a page that asks
  for nothing sends the header it always sent. There is no site-level allow
  list yet.

The paragraph this replaced said both belonged at web server level
because the policy is site-specific. SM286 settled that the other way:
"belongs in the vhost config" is the reasoning that produced SM248,
SM268 H17 and SM283 - correct engine, front end never told.

The earlier text also noted that HSTS "should only be set over HTTPS,
and the operator controls whether HTTPS is in use". That reasoning is
intact and is exactly what the engine now does - it reads the same
`HTTPS` environment variable the session cookie uses for its Secure
flag, so a front end that does not set it simply gets no HSTS, which is
the safe direction to fail.

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
  chain. Grants add (SM1332): the primary has a row of its own, the bare
  `allowed_groups:` line, whose grant adds the scope `/` (the docroot, read
  as the primary only by the domain rule); an account granted nothing keeps
  the primary; only a lock removes the other domains - a domain's
  `locked_users` for an account, its `locked_groups` for a group's members
  (SM1334). The per-account and per-group `dav_scope` settings that
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

**The zip upload and the served asset mirror (SM1303, SM1304, 0.16.2).** The
manager's Upload Theme (`theme-upload`, cookie-only, `manage_themes`) copies a
theme's `assets/` into `/lazysite-assets/LAYOUT/THEME/` in the document root.
Until 0.16.2 a symbolic link in the zip was copied there as a link, so a public
URL served any file the web server can read - the session-signing secret
`lazysite/auth/.secret` among them, from which an operator's session could be
minted. Every entry is now checked before any is extracted, and a link, a file
type the web server runs (`@DANGEROUS_EXT`) or an archive over the site's upload
limit refuses the whole archive, as WebDAV and MCP `upload_file` already refused
under a theme. A link planted before 0.16.2 is not removed by the upgrade:
`lazysite check` warns for every symbolic link under `lazysite-assets/`, naming
it and its target, and the operator removes it and rotates the secret (the
Sessions page's "Log out all users"). The check never deletes one, and
`lazysite repair` counts such a site as needing a human.

**The zip upload over MCP (SM1291, SM1290, 0.16.3).** MCP `install_theme`
(`manage_themes`) takes a theme zip as base64 and calls the same
`action_theme_upload`, so the upload is reachable with a token for the first time,
with every check above: no symbolic link, no file type the web server runs, the
site's upload limit, no absolute or `..` entry. Nothing is activated; the audit
row is `theme-upload`'s, and `delete_theme` takes away only a theme the caller
installed (SM262). The control API's `theme-upload` stays cookie-only. MCP
`preview_page` takes `theme` (`manage_themes` or `manage_layouts`, with
`manage_content`) and renders with an installed theme that is not active,
activating, caching and writing nothing.

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
keep `auth_proxy_trusted_from` to the proxy's own address (SM1129).

## The request address (SM929)

Separate from the trust headers above, and with its own mechanism: **who the
engine believes the visitor is**.

Everything that records or decides on a visitor's address - the `_ip` stored on a
form submission, the audit trail's actor column, the login and form rate limits,
the bad-URL auto-blocker, the daily visitor hash, and `[% client_ip %]` - goes
through one definition, `Lazysite::Util::request_address` (and its pinned copy in
the render path, which ADR 0001 keeps module-free; `t/lint/205` holds the two
identical).

The rule:

1. if `REMOTE_ADDR` is **not** in `trusted_proxies`, that is the address, and
   `X-Forwarded-For` is ignored entirely;
2. if it **is**, walk the forwarded chain **from the right** and take the first
   address that is not itself a trusted proxy;
3. if that leaves nothing usable - including a hop that will not parse - fall back
   to `REMOTE_ADDR`.

`trusted_proxies` is a site setting (Config page, or `lazysite.conf`): addresses or
CIDR ranges, comma separated. **Absent or empty means the private ranges**
`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`; `none` ignores forwarded headers
altogether. A `/0` range is refused, because a trust set matching every caller is
the same as no check at all. Loopback is **not** in the default: a front end on the
same machine must be named.

**Why the right-hand walk rather than the first hop.** A proxy *appends* to
`X-Forwarded-For` (`$proxy_add_x_forwarded_for` in the shipped nginx templates), so
a caller who sends their own header has it preserved *in front of* the address the
proxy adds. Reading the first hop therefore reads whatever the visitor chose -
measured on a live site on 2026-10-01, where `X-Forwarded-For: 203.0.113.7` made
`client_ip` render `203.0.113.7`. Reading from the right reads what the trusted
proxy itself contributed.

**Why this is not the `X-Remote-*` problem in another coat.** The trust basis is
`REMOTE_ADDR`, which comes from the server's own `accept()`. There is no sentinel a
client could forge and nothing for a trust source to clear, so the
produce-or-clear requirement above does not apply to it.

**A site behind a proxy needs the proxy to send the header.** The shipped nginx
proxy templates do (`lazysite-proxy.tpl` / `.stpl`, template revision
`2026-10-01`); an older installed template does not, and until it is reinstalled
such a site keeps recording the proxy's address. Where the key is absent (the private-range default) or lists the front end it is worse than that: the client's own header is passed through, so the visitor chooses their address (SM1194). The Hestia rollout reports an older vhost as a failure on every site not set to `none`, and `lazysite-check` warns whenever the trust set is not empty. `lazysite-check` reports a
`trusted_proxies` entry it could not parse, because a trust list with a typo in it
is a declaration the code ignores.

## Who a request is, decided once (SM1181, 0.15.12)

Until 0.15.12 a signed-in request met two programs on the one-rule pool: the auth
wrapper verified the cookie and set the identity headers, and a second program
read them. The identity is now a value produced in one place and handed to the
surface that needs it.

- **One function.** `Lazysite::Auth::Session::request_session` returns the
  identity (`user`, `groups`, `name`, `email`, `sid`, `no_password`, `odoo`,
  `stale`, `source` of `cookie` or `proxy`) or the reason there is none. The
  wrapper and the pool's front door both call it, so the CGI path and the pool
  give one answer. A listed proxy's user still wins over a cookie (SM1130); the
  groups pass through the same address filter the reader applies (SM1140).
- **The pool renders a signed-in page in the worker.** The front door runs the
  bad-URL guard (`Lazysite::BadUrl::guard`, SM128) for every request it does not
  hand to the wrapper, calls `request_session` once, holds the value in
  `$REQUEST_IDENT` and returns to `main()`. No `exec`, no identity header.
  `request_identity` takes the value (`identity =>`) and reads no environment.
- **The sentinel is never believed in the pool.** In a worker
  `LAZYSITE_AUTH_TRUSTED` and `LAZYSITE_AUTH_SID` from `%ENV` count for nothing;
  the held value is the only trusted producer of an identity. When a value is
  held, `apply_trust_gate` deletes every fixed and custom identity and payment
  header whatever the sentinel says, so a client's `X-Remote-User` cannot be read
  even by mistake. t/lint/38, 13 and 268 still hold the gates and the single
  reader (268 now reads the front door and `Session.pm` as well).
- **The manager API is one program.** The front door relays to it directly and
  writes the wrapper's exact header contract from the value, after deleting the
  sentinel, `LAZYSITE_AUTH_SID`, `LAZYSITE_AUTH_NO_PASSWORD` and the six trust
  headers from what the parameters carried. The worker's own `%ENV` is never
  written.
- **A pooled worker carries nothing about a person between requests.**
  `$REQUEST_IDENT` and `$Lazysite::Auth::Session::STORE_FAULT` are cleared by
  `reset_request_state` at the start of a request and `$REQUEST_IDENT` again at
  its end, so a request that dies leaves nothing for the next one. `auth/.secret`
  is read per call into a lexical and never cached. t/lint/269 classifies every
  file-scope variable of the resident modules.
- **The dev server** (`tools/lazysite-server.pl`) runs the four surfaces that verify
  their own caller (Odoo, data, MCP, OAuth) direct, as every shipped front end
  does, and runs the same bad-URL guard for them.
- **Unchanged by decision (R8).** The split FastCGI templates (`vhost-fcgi`) keep
  their session carve-out to the CGI wrapper, so SM1181 is the one-rule pool's.
  Credential-bearing surfaces (MCP, DAV, OAuth, the wrapper's own actions) are not
  moved: no worker reads their stores.

The filing (docs/feature-requests/SM1181-identity-in-process.md, section 3) holds
the fourteen threats and the test that holds each: identity served to the next
visitor (T1, T7), a forged header or parameter read as identity (T2, T3), proxy
and cookie disagreeing (T4), a check the wrapper made and a surface lost (T5), the
worker's privilege and secrets (T6), the Odoo session record (T8), tokens reaching
the worker (T9), the two paths deciding differently (T10), logging (T11), caches
keyed on identity (T12), the bad-URL blocker missing unwrapped requests (T13, closed
by running the guard on every request) and a new reader slipping past the lints
(T14).

## Trusted proxies, forwarded addresses and the front end's template (SM1129-SM1131, SM1189, SM1194, SM1196)

Two settings decide what a proxy is believed about, and they are kept apart.
`auth_proxy_trusted_from` names the peers whose identity headers are believed
(matched against the TCP peer, SM1129, see "Auth proxy trust model").
`trusted_proxies` names the peers whose `X-Forwarded-For` is believed about a
visitor's address (SM929, "The request address"). The 0.15.10 and 0.15.11 changes:

- **The configured header names are read by every reader** (SM1131).
  `Lazysite::Auth::Identity::request_identity` is the only code that reads identity
  out of the environment; the processor, the manager API, the ACL code, the layout
  and both `sources.pm` readers call it. A client can never make a configured name
  count: unless `proxy_identity` trusts the request's peer, the names are not read.
  t/lint/268 holds the arrangement and t/lint/267 holds the reader to asking
  `proxy_identity`.
- **A trusted proxy's user wins over a cookie** (SM1130); the cookie is not consulted
  for identity at all when the proxy names a user.
- **An old front end with a trusted proxy is a failure** (SM1194). A vhost rendered
  from the pre-SM929 proxy template passes the client's `X-Forwarded-For` through,
  so every address-keyed control (the sign-in rate limit, the bad-URL blocker, the
  form handler's rate limit, every address rule) takes the visitor's word. Because
  an absent or empty `trusted_proxies` means the private ranges, such a vhost is
  spoofable on every site not set to `none`. The Hestia rollout reports it as a
  failure and exits 2; `lazysite check` warns whenever the trust set is not empty.
- **Hestia's copy of the template follows the release** (SM1196). Hestia renders a
  vhost from its own copy of lazysite's templates, and nothing refreshed that copy.
  The rollout now compares each installed template with the release's, replaces one
  that differs (keeping the old as `NAME.EXT.bak-TIMESTAMP`), names the domains that
  need a rebuild, and the domain tool reports a stale copy.
- **An address rule is checked for the form and kind it needs** (SM1189). A value
  that is not a list, or a list of the wrong kind in either slot, is named by the
  validator, refused on save and warned by `lazysite check`; at request time it
  denies (`wrong-kind`), where a wrong-kind name in the deny slot used to be skipped
  and so failed open.

## Address rules (SM1134, 0.15.10)

Access can be limited by the visitor's address. It narrows what the existing rules
grant and never widens it.

- **Profiles** (SM1138; SM1343, 0.16.5): named sets of addresses and CIDR ranges in
  `lazysite/auth/address-profiles.json`, written only by the users tool and audited.
  A profile has no kind: each rule that names one allows it (`addresses`) or denies
  it (`addresses_deny`). `Lazysite::Auth::AddressProfiles::decide` is the one module
  that answers: deny wins, a profile allowed means only those addresses, an
  unreadable store (or the address lists of an earlier release the upgrade has not converted, SM1345) denies
  whenever a rule names a profile (SM1024's rule), an address that cannot be worked
  out denies, and a name the store does not hold in an allow slot admits nobody. Matching is
  `trusted_proxies`' matcher, so an address means the same everywhere; a prefix of 0
  is refused; an IPv4-mapped IPv6 address is an IPv6 address.
- **Pages, files and folders** (SM1139): `addresses` and `addresses_deny` in front
  matter and in `acls.json`. Every layer that names a profile must admit (AND across
  layers, OR within one), so an inner rule cannot open what an outer one limits. The
  address is asked first, before the who-may-read rule, so `auth: none` on a page
  cannot lift it. Enforced in the processor, WebDAV, the manager API and MCP.
  The refusal says the page is not available from this address and names no profile.
- **Groups** (SM1140): a group naming a profile does not count for a request from a
  refused address - not its capabilities, page access or operator status, nor
  anything reached through it by nesting. The account stays signed in with its other
  groups. The limit is applied in `Auth::Settings::_group_closure`, the processor's
  marked copy, and `request_identity`; machine doors cut the caller's settings back
  with `narrow_caps_to_request`, which only removes. Outside a web request (the users
  tool, scheduler) the rules do not apply.
- **The template test** (SM1141): `visitor.in_profile` and `visitor.in_any_profile` expose profile
  membership only, never the address; a render that asked is the visitor's own and
  never cached. `lazysite check` warns when rules exist and `trusted_proxies` trusts
  no front end, or leaves the default behind a front end it does not cover.
- **Depends on the address being right.** Every address rule is only as good as
  `Lazysite::Util::request_address`; see SM1194 above.

## The Odoo extension (SM747, 0.15.5; SM1160, 0.15.10)

The Odoo extension (`extensions/odoo.pl`, born disabled) lets a lazysite page use an
Odoo as a connection user or as the signed-in person. The Odoo URL is the
operator's, so the SSRF guard that governs content-chosen URLs is not the rule that
applies; SM579's invocation-mode policy is (ruled X4, 2026-09-28).

- **Connection and transport.** `https://` to any host, `http://` to loopback only;
  a user or password in the URL is refused. The connection user's key is one file
  per account under `lazysite/odoo/keys/`, written under a 077 umask and renamed into
  place, never returned or logged. The Odoo kinds map to `{ok:0, kind, error}`; the
  text is logged, never returned.
- **Who may cause a call.** `Lazysite::Egress::may_invoke` gates every call by mode
  (public, authenticated, scheduled), the extension switch, OOM's presence and
  version, and the connection. A public or scheduled binding may apply a write
  unattended only when it declares `apply: immediate` (ruled Q1, 2026-10-12), and is
  bounded by the connection user's Odoo rights and the operations the page binds.
  Controls on every public apply: per-visitor and per-binding hourly caps (a count
  that cannot be taken refuses), a CSRF token bound to the visitor key, input checked
  against the operation's declared parameters (only the parameters the binding maps
  can come from input; `fixed:` and the visitor parameter cannot be overridden), a
  256-bit server-minted visitor key (`HttpOnly; SameSite=Strict`, signed) through
  which a plan belongs to the visitor that made it, and an audit record naming a hash
  of the visitor key and the IP.
- **A person's own Odoo session** (slices B, C, D). The password goes to OOM's
  session transport in one POST and is in no URL, cookie, log or record. The
  credential cookie `lzs_odoo_session` is a signed session id (HttpOnly,
  SameSite=Strict, scoped to the endpoint's path, 12 hours); the identity cookie
  `lzs_odoo_identity` is for presentation only, signed under a label of its own, and
  authorises nothing. A session binding never falls back to the connection user. Sign-in
  attempts share the site's limiter (five in five minutes, per address and per login).
  Two-factor accounts were refused until SM1157 added Odoo's own code to the dialog.
- **Odoo sign-in as the site sign-in** (SM1160, `odoo_site_signin: on`, default off).
  The identity is `odoo:<login>`; no lazysite account exists. The session is the
  wrapper's own cookie and registry (`auth/sessions.jsonl`), with the user field
  `odoo=<login>` percent-encoded, an empty groups field, and the mapped groups held in
  the server-side record, never in the cookie (SEC-2026-07 M5). `odoo_group_map` maps
  Odoo groups, asked of Odoo as the person (`core.has_groups`), to lazysite groups; a
  target that carries any capability is refused at save and at load, by name, so this
  door never grants manager rights. The record is the authority: no record, or one for
  another user, is no session; it grants nothing once `checked` is `odoo_identity_ttl`
  old (default 900 s) until the Odoo endpoint's `?csrf=1` asks Odoo and renews it.
  Sign-out ends both sessions and each ends the other. An unsecured site refuses it.
  Idle time-out is not built (as ruled).
- **Plans and approval.** Plans live in `lazysite/odoo/plans/<128-bit id>/`; a plan is
  confirmed only by the account or visitor that made it, within an hour. OOM's
  approval gate stays on: a confirm is the approval of the plan's owner and
  `apply: immediate` is the operator's standing approval, recorded with
  `approve_plan`; lazysite never sets `approval = none`.
- **Rendering.** A page render never runs a write, never renders a binding that works
  on a visitor's key (the render is shared and cached), and escapes every scalar.
  A page that binds `odoo-identity:` is per-viewer and never cached.
  `extensions/odoo/assets/lazysite-odoo.js` fills regions as text only.
- **The boundary.** t/lint/240 keeps all Odoo knowledge (RPC methods, models, field
  types) out of lazysite; the mapper is OOM's, vendored as a pinned snapshot checked
  by t/lint/261.

### oomd, the resident OOM (SM1164, SM1207, 0.15.10 and 0.15.14)

With `odoo_daemon` set to `on` or `required` (default `off`), lazysited supervises
one `oomd` per site and the extension sends its calls through it.

- **Nothing starts on a guess.** The supervisor lists oomd only while the Odoo
  extension is enabled, a connection loads, `odoo_daemon` is on, and oomd is
  installed; with any gate closed no process exists. A leftover oomd of the same
  socket is told to stop before a new one starts.
- **The config and the socket.** `lazysite/odoo/oomd.conf` is written 0600 through a
  temporary file under umask 077; credentials appear as labels naming key files, and
  no key is ever in it. The socket is `lazysite/run/oomd.sock` when that path is under
  104 bytes, otherwise under `/tmp/oomd-<uid>/`, the directory created 0700. The
  daemon runs as the user lazysited runs as (SM760), the supervisor's unchanged
  arrangement.
- **The call path.** The person's session id is in the request to the daemon and in
  no file. The daemon's client is always `fallback => 0`; `on` falls back to
  lazysite's own in-process path when the daemon is absent, `required` refuses with
  `daemon-down`. Each call record carries `via` (`daemon` or `in-process`).
- **Sign-in stays in-process**: oomd's protocol has no sign-in verb.
- **Site packs** (SM1207, SM1248): oomd's config names the site's `odoo_packs`
  (`namespaces`, OOM 0.39 and later) and `pack_dirs`, so a pack's custom change
  applies through it; t/unit/odoo/79 holds it. The service starts oomd with
  `ODOO_OPS_NAMESPACES` removed from its environment, so the config is the whole
  list and a pack taken out of `odoo_packs` is gone from the daemon. A change is
  taken by oomd's `reload` verb, with the socket kept (t/unit/odoo/103). An OOM
  before 0.39 still reads the list from its environment, at its start.

### The warm-forked endpoint (SM1226, 0.16.1)

On a site with a pool conf and the Odoo extension on, lazysited supervises the
`odoo-endpoint` service: a parent that has compiled `lazysite-odoo.pl` and forks a
fresh child for each request. Never on a plain-CGI site.

- **The parent holds code and nothing else.** It reads no configuration or key and
  never reads a request; t/lint/272 classifies what it keeps and t/integration/325
  reads its memory after signed-in requests and finds no secret, key, cookie
  signature, token or visitor parameter. It starts by exec, never as a fork of the
  supervisor, and exits when its code changes on disk or it is re-parented.
- **The socket.** `lazysite/run/odoo-endpoint.sock`, 0600 in the site's 0700
  `lazysite/run/`. Only the one-rule pool connects to it; the web server reaches the
  pool's socket as before, so the parent's socket stays the request-path user's
  (SM760). With no parent listening the pool runs the CGI; a request the parent has
  taken is never re-run.
- **The child.** Its environment is the request's parameters less the sentinel, sid,
  flag and every trust header; the endpoint verifies the cookie itself, as the CGI
  does, so a forged `X-Remote-User` is nobody. It seeds its own random numbers and
  exits after one request.
- **Templates.** The split FastCGI templates (nginx and Apache `vhost-fcgi`, Hestia's
  fcgi templates) send `/cgi-bin/lazysite-odoo.pl` to the pool; a vhost made from an
  older template keeps running the CGI until it is regenerated.

### Odoo calls: idempotency, declared sizes, downloads (SM1223-SM1225, 0.16.1)

- **Idempotency** (SM1223): a page's `Idempotency-Key` (8 to 128 characters) is hashed
  with the binding and the caller into OOM's `idem`, so one caller cannot collide with
  or replay another's write; a repeat answers the first plan or result.
- **Declared sizes** (SM1224): a rows key with its own declared `max` is capped there
  (up to 1,048,576 characters); every other value keeps 1,000. A JSON body over 64 KB
  names its binding and is held to that binding's budget, 20 MB at most.
- **Downloads** (SM1225): `answer: download` returns a report's document with OOM's
  content type, a safe file name, `Cache-Control: private, no-store` and a cap
  (`download_max_kb`, default 10 MB) over which it is refused, never cut short. The
  binding's gate, callers and rate caps are the call's own.
- **OOM's version** (SM1244): `lazysite check` names the OOM a site loads and warns
  below 0.38, which can send a write again when its answer timed out.

### A write whose answer never came (SM1275-SM1280, 0.16.3)

- **Read back first** (SM1275): a run that ended with a change unknown names its run,
  and a resume has OOM read each unknown change back before anything is sent; a change
  found made is never sent again. Only a change no read can tell is refused
  `unknown-outcome` until a person says.
- **Who says** (SM1276): the run's own maker, or a holder of `settle_odoo_writes`, a
  capability the Odoo extension declares, so it is grantable only where the extension is
  installed; every operator group holds it. A visitor never resumes a public binding's
  run. Each decision is one call record and one audit line naming the run.
- **Kept until closed** (SM1279, SM1278): an open unknown run, its journal and the bytes
  of a change it may send again, is outside the plan store's expiry until it is settled
  or dismissed. A dismissal (`settle_odoo_writes`) sends nothing to Odoo and records who,
  when and why.
- **The caller's address as one bit** (SM1280): a binding's `address_profile` gives its
  operation 1 or 0, whether the request's address (behind `trusted_proxies`) is in the
  named address profile; a page cannot set it, and the address itself never reaches Odoo.

## Raw pages and the ADR 0006 downgrade (SM1213, 0.15.15)

A page that declares `api:` or `raw:` is served verbatim, and ADR 0006's mechanical
boundary downgrades a declared `text/html`, XHTML or SVG content type to `text/plain`.
The render parse and the downgrade's peek read the front matter differently, so
`api:` above `true`, `api: "true"`, and a quoted `"text/html"` were served verbatim
as `text/html` past the downgrade. The empty-key reading shared by both is fixed:
the renderer, the manager's `page_form` and `raw_html_page_refusal` read a value from
its own line, and the downgrade reads `api:` and `raw:` as the render does. No gated
page opened: every reader that decides who gets a page reads the front matter line by
line (t/integration/305).

## Planned, not built: sign-in through an identity provider (SM1128)

Phase 1 of SM1128 (the trusted-header route made safe: SM1129, SM1130, SM1131 above)
shipped in 0.15.10. Phases 2 and 3 - a native OIDC relying party (a JWT/JWKS verifier,
authorisation code with PKCE, `state` and `nonce`, an `id_token` checked against the
issuer's keys) and directory groups as a source - have no code. Phase 2 fires the
new-authentication-method trigger and, with its JWT verifier (ruling R5, a packaged
`Crypt::JWT`), the new-dependency one; it is assessed in the significant-change
register when it is built.

## Accounts in the visitor log, and maintenance (SM1219, SM1118, 0.16.1)

Held out of the 0.16.0 stable, both are in 0.16.1.

- **The visitor log names the signed-in account** (SM1219). The access record
  gains `u`, the account the engine verified (source `cookie`, including the pool
  front door's value, or `proxy`), never the raw `X-Remote-User`; an anonymous visit
  has none. It is read with the `analytics` capability, a domain-confined caller sees
  only its own domains' accounts, and the log keeps it for `retention_days`. The log
  is personal data once it holds account names.
- **A site can be put into maintenance** (SM1118). `maintenance: on` sends page
  requests by 302 to a page that answers 503; the new capability `maintenance_access`
  (held by the operator group, assignable to any group) gets through. MCP, the
  control API, WebDAV, the data endpoint and posted forms follow the same capability
  and are refused 503 without it; the check sits in the processor's `main()`
  (`_maintenance_gate`) so it holds on CGI, the split templates and the pool.
- **Shipped bundles reach existing sites** (SM1241, SM1262). Every bundle in the
  shipped nesting (`cap-maintenance` among them) is adopted on the next use of the
  users tool, only when absent, only for the shipped roles a site has, never
  rewriting an edited group, and only on a site that has the bundle layer. The
  bundles a site has had are recorded in `auth/bundles-adopted.json`, so a bundle an
  operator deleted is never adopted again; an unreadable record adopts nothing.

## The Docker Compose package (SM1233, 0.16.1)

`installers/docker/` runs nginx, the one-rule FastCGI pool and lazysited in one
container, as `www-data`, with all capabilities dropped and the port published on
loopback by default. The vhost is made from
`installers/nginx/vhost-one-rule-pool.conf.example`, so the trust-header blanking is
the template's. The docroot, `lazysite/` and the private store are three volumes; the
private store is the docroot's sibling, outside the served tree, as on any install.
The container serves plain HTTP on 8080: TLS is the front end's, and HSTS is sent
only over TLS. No Odoo is in it.

## A confined grant's walks, and a rule inside another (SM1308, SM1309, SM1311-SM1313, 0.16.3)

- **A confined grant walks only its scope** (SM1308, ruling 47). A grant confined to
  a scope had its path arguments checked, and a tool given no path skipped the check
  and walked the docroot. A missing or empty path is now the grant's scope roots
  (`_walk_roots`; `Files::action_list_scope_roots` on the manager API), for MCP
  `list_files`, `list_pages`, `search_files`, `delete_page`'s reference list and
  `rename_page`'s link rewrite, and the manager API's `list` and `pages`. A search
  asks each file read_file's question (`Acl::_acl_denied`) before it quotes a line.
  `audit_site` audits the scope and lists a link outside it as outside, never broken
  (SM1311, ruling 59); `list_pages` asks a page's rule before it lists its title
  (SM1312, ruling 60).
- **A rule inside another may narrow it; only its owner may widen it** (SM1309,
  rulings 46 and 64). Longest match decides a mode's list, so a subfolder's rule
  replaces the enclosing rule there. Writing a rule that admits, to read or write,
  anyone the enclosing rule does not is refused (`widens-enclosing-rule`) unless the
  operator or the enclosing rule's owner writes it: `Acl::widening_refusal`, asked by
  `Files::action_acl_set`, which every rule writer calls. A move that would carry such
  a rule inside an area is refused the same way (`Acl::move_widening_refusal`, in
  `Files::action_move` and WebDAV MOVE). A site package restore (`site_apply`) is an
  operator's act and is not checked (ruling 62).
- **Rules written before 0.16.3** stay in force. `lazysite check` names each stored
  rule wider than its enclosing rule whose owner is neither the operator nor that
  rule's owner, as a WARN with the command that removes it, and changes nothing;
  `lazysite repair` leaves it to a person (SM1313, ruling 61).

## The engine's /docs manual and pages beside a moved tree (SM1283-SM1286, 0.16.3)

- **The manual is the engine's** (SM1284, rulings 27, 32, 34, 35). It ships in
  `{LAZYSITE}/templates/docs/`, outside the docroot on an SM293 layout and
  DAV-blocklisted with the rest of the engine tree, and serves at `/docs/` only where
  the site has no page of its own. It is named by the path it serves at, so an access
  rule, address profile, draft section or section theme over `docs/` governs it as it
  would a site page. Its renders cache under the engine's cache, not in the docroot.
  It is out of the site's search, sitemap, feeds and `llms.txt` unless
  `engine_docs_public: true`.
- **The upgrade removes only what it installed.** A docroot `docs/` copy whose
  checksum still matches the install state is removed with its cached renders; an
  edited one is kept and named, and `lazysite check` warns that it shadows the
  engine's page.
- **A page beside a moved engine tree** (SM1283). The render path's content-root
  confinement accepts a source outside the docroot only when the system-page fallback
  chose it and its real path (`realpath`) is under one of the engine's page trees.
- **Starter pages** (SM1285, SM1286). A new site has none unless `--starter` asks.
  `lazysite starter --remove-unmodified` removes, by provenance and checksum, only the
  unmodified ones, never an edited page or one the site needs; it runs as the site
  user, refuses root and is audited.

## Extensions on disk, and the step that moves a site to them (SM1142, 0.16.4)

- **One directory, one key, one resolver.** Extensions live in `extensions/` beside
  the docroot (deb: `/usr/share/lazysite/extensions`), outside the served tree as the
  old directory was. A site's `lazysite.conf` lists the enabled ones as
  `- extensions/<file>.pl` under `extensions:`, the only spelling a reader accepts, and
  every lookup of an extension's script asks `Lazysite::Extensions::locate`
  (t/lint/306).
- **The upgrade converts each site once** (`install.pl`, `extensions-rename`). It runs
  only when its directories resolve to the old directory's name and `.../extensions`, skips an old
  directory that is a symbolic link, moves each entry with `rename` (a link moves as a
  link), never overwrites (an edited copy of a shipped file is kept as
  `<file>` with a suffix naming the old directory; a name taken twice is left and
  named), re-points only a cgi-bin link whose target is a file in the old directory at a
  regular file in `extensions/`, and writes
  `lazysite.conf` and the start-page store by temporary file and rename. It is recorded
  as done only when it ran without a warning. On HestiaCP the root-run deploy makes
  `extensions/` and hands it to the site user before the install, and removes the
  emptied old directory with `rmdir` after it.
- **Which extensions run** is the converted list, the login rate limiter among them.
  `lazysite check` names an old-spelling list or entry by line and an old directory
  left beside the docroot, and says when the limiter is not in force (SM798).
- **The wire.** The old action spelling, the old parameter and whoami's old switch are
  refused before authentication, naming the new spelling and nothing about the site.
  The responses name `extensions` and `capability_extension` (ruling 95), and the
  audit records the extension actions as `extension-*`.

## Protected history, the read audit, served theme copies and the sign-in check (0.16.5)

- **A protected folder's history is an opt-in second store** (SM1324). A folder rule's
  `history: true` keeps its versions in a repository whose work tree is the private
  store, at `<store>/lazysite/git` (02770), never the public repository a git-sync
  remote receives. Every history reader resolves its target through the file's read
  rule and a restore through its write rule. Nested rules inherit unless one says
  `history: false`; only the operator purges, with `lazysite acl purge-history`,
  audited.
- **Agents' reads can be audited** (SM1325). `audit_reads: on` writes each successful
  MCP read and a token's `git-show` to `logs/audit-reads.log`, beside the trail, rotated
  and forwarded as it is, shown on the Audit page's own view; switching it needs
  `manage_config` and `audit_switch` together.
- **A theme's served copies follow its source, and only the source is written**
  (SM1335, SM1336, SM1339). Every write to a theme's source, on any surface, re-mirrors
  it to each host's `/lazysite-assets/` copy through `_mirror_theme_assets`, the one
  writer, which refuses to switch in a copy holding a symbolic link or a server-run file
  (SM1303's checks). A served copy is refused to every writer, the operator included
  (`served_artifact_refusal`), and the theme and layout a secondary domain serves are
  read-only as the primary's are (`active_artifact_refusal`).
- **The bad-URL blocker spares real files and loopback** (SM1321). A path that resolves,
  by plain segments with no link on the way, to a regular file under the docroot is
  never counted; loopback is always exempt unless `bad_url_exempt: none`, and the key
  names address profiles whose members are exempt too. The address is the one
  `request_address` gives under `trusted_proxies` (SM929), so behind a front end on the
  same host that the setting does not cover (the default trusts the private ranges, not
  loopback), every visitor is loopback and the blocker counts nothing.
- **The sign-in page asks the server** (SM1322). `lazysite-auth.pl?action=session`
  answers one bit, whether the request's own cookie is honoured, from the verdict every
  surface asks; it is uncached, and a no clears only the display marker.
- **A refusal by a read list is the site's 403** (SM1365). A page refused by an
  `auth/acls.json` read list is served the site's 403, naming the list's groups and
  never a user on it; a file keeps the short 403.
- **Connect an AI assistant is public** (SM1341). The page that says how a client
  connects and authenticates carries placeholders only (t/lint/311); the tools
  reference, with the capabilities and denied paths, stays signed-in.

## Extension hooks, agent roles and the primary's reach (0.16.6)

- **An extension's code can be loaded into a core process** (SM1369 X0, X1; trust
  boundary 15). An extension's `owns` may declare `hooks` and `requires`;
  `Lazysite::Extensions::Hooks` validates them, the manager writes
  `lazysite/extensions.index.json` from the enabled extensions on enable, disable and
  save, and the upgrade rebuilds it as the site user. `call_hook` runs only a function the
  index names, from a module that is a regular file in the extension's own payload lib
  (`extensions/<stem>/lib`, a real directory, appended to `@INC`, never prepended) and
  found nowhere else on `@INC`, while the extension and every extension it requires are
  on in `lazysite.conf`, read at the call. A hook that dies is a failure, never an
  exception into core. In 0.16.6 nothing calls the loader and every hook kind is refused,
  naming the slice that builds it. In process a hook is a contract, not a sandbox: trust
  is what is installed (ADR 0009). `t/lint/321` holds core's lines that name Odoo to an
  allow-list that only shrinks.
- **A token's grant is its account's at each request** (SM1370). Every token door
  resolves capabilities through `caps_for` per request (WebDAV once per CGI process), so
  a grant removed at the account is refused on every token at once, and nothing is fixed
  into a credential; both whoamis say so in a `grant` block.
- **Agent roles and a form's config** (SM1371). Four assignable groups ship with no
  members (`content-agent`, `data-agent`, `forms-reader`, `analytics-agent`), each one
  job over MCP and none carrying `ui`, `api`, `webdav`, design, settings, people, audit
  or purge; an existing site adopts them once. `manage_forms` reads and writes
  `lazysite/forms/<name>.conf` over MCP and the manager's editor, as over WebDAV, under
  WebDAV's binding rules; `smtp.conf`, `handlers.conf` and `schedule.conf` stay closed.
  Ticking a grant whose extension is off offers the enable as a separate, audited
  `extension-enable`, which needs `manage_config`.
- **The primary's content leaves out the other domains' roots** (SM1372, rulings 126 and
  137). An account that reaches the primary - granted nothing, or granted its row - is
  refused every secondary domain's content root under the docroot, and does not see it
  listed, on the manager API, MCP and WebDAV
  (`Lazysite::Auth::DomainAccess::foreign_root_of`). The operator group and an account
  granted the domain keep it.
- **A form's owner mail and acknowledgement** (SM1362). `owner_contact` in
  `lazysite/notify.conf` mails each form's notice to one configured address, the fields
  only on `notify: full` (retired in 0.16.8, SM1412: the key is ignored, and a form
  mails people only through a notify handler it names, SM1413). A form that opts in
  sends its own fixed words, never the visitor's, to the address in its `acknowledge_field`, within 3 an hour per address and
  60 per site shared with the smtp handler.
- **What is answered, narrowed** (SM1373, SM1374, SM1377). `extension-read`, a cookie
  action needing `manage_config`, answers only the keys the extension declares, never
  the rest of `lazysite.conf`. An Odoo plan's failure shows the visitor Odoo's text only
  for a validation or user error, and a plain sentence otherwise. The data endpoint and
  `data-rows` refuse a query parameter they do not read (400, `unknown-parameter`)
  instead of answering every row.
- **Who acted, on an Odoo call** (SM1366). A call under a person's Odoo session is
  recorded under the site account the request is signed in as, with the session's hash
  beside it; the session id is never written.
- **The 403 page lists groups as HTML, escaped** (SM1375, ruling 141). The group names
  come from a page's front matter, shape-checked by `Lazysite::Validate`, or a read list,
  which is not; `auth_required_groups` is escaped where the stash is built, as SM709
  escapes the other auth values, and `%AUTH_CONTEXT` stays raw for access control.

## Odoo's payload lib, the renewal step, the cookie contract and group deletion (0.16.7)

- **Odoo's modules load from the extension's payload lib** (SM1369 X7 part one, ruling
  135; trust boundary 12). `Lazysite::Odoo`, the twelve `Lazysite::Odoo::*` modules and
  the two Odoo-only daemon services live in `extensions/odoo/lib/`, beside the
  descriptor, with their names unchanged. Core loads them only through
  `Lazysite::Extensions::require_payload`, which puts the payload lib beside core's own
  lib on `@INC` (appended, the X1 rule) and loads a module only as a regular file in
  exactly one payload lib that resolves nowhere else on `@INC`: a stale copy an earlier
  release left in core's lib, a module in two payloads or a linked payload is refused by
  name and nothing loads. The upgrade removes the old copies; an edited one is kept as a
  named orphan and refused until removed. The rule gates nothing: whether Odoo is on
  stays each caller's question. The tests and the OOM snapshot stay in `t/`, and the
  separate package is 0.16.9.
- **A stale site session is renewed through the endpoint** (SM1381). A session the Odoo
  sign-in minted and idle past `odoo_identity_ttl` is sent by the page gate to
  `GET /cgi-bin/lazysite-odoo.pl?renew=1&next=`, a tokenless step that runs the renewal
  `?csrf=1` runs, once: renewed, back to `next`; ended by Odoo, both sessions end and
  the visitor goes to the site's sign-in page (`auth_redirect`, held to a same-site
  path, else `/login`) with `next`. Nothing is renewed or ended without the
  `lzs_odoo_session` cookie (`SameSite=Strict`, scoped to the endpoint), `next` passes
  `sanitise_next`, core accepts the renewal path only as a same-site path with a query,
  and `lzs_renewed` (60 seconds) bounds the round trips to one a minute. The auth CGI's
  `?action=session` goes through the same step. The refusal is logged at INFO.
- **The session cookie is an external contract** (SM1383, ruling 146).
  `docs/architecture/session-cookie-contract.md` states the `lazysite_auth` format an
  outside process on the same host verifies read-only: the payload shapes, the key as
  text, constant-time comparison, expiry, `revoked.json` and fresh groups. The key is
  symmetric, so a process that can verify can mint: such a process is trusted as far as
  the web server is. The format changes only versioned, reader before writer;
  `t/unit/auth/75` holds the agreement between the document and the engine.
- **One signed value means one thing** (SM1390, ruling 147). The session verifier
  refuses a payload beginning with the preview cookie's marker `v1`, and a timestamp or
  `seen` time more than 300 seconds ahead of its clock; the preview verifier refuses a
  payload without exactly five fields; the payload is split to five fields so the sliding
  shape is read as itself (nothing issues it). No account may be named `v1` on any door
  that creates or renames one, and `lazysite check` names one that exists.
- **A group is deleted on every door, once nothing uses it** (SM1387). Control API
  `group-delete`, MCP `delete_group` and the Groups page go through the users tool, the
  store's one writer, which refuses the operator group, a group with a member and a group
  anything names - `Lazysite::Auth::GroupRefs` walks pages' `auth_groups`, `acls.json`,
  the domain rows and `auth_group_map` in `lazysite.conf`, tables' `writable_by`, Odoo
  bindings' and connectors' `callers`, and `odoo_group_map` - naming each; a confined
  caller deletes only a group it created with `group-set`; audited as `@group`.
- **The roles reach a site the mark never reached** (SM1393). Both adoptions in the users
  tool run on any bootstrapped site; what counts as shipped is read from the manager
  group, which no adoption writes. A role is adopted with no member; a bundle is nested
  only into roles present under their shipped names; each once, through
  `bundles-adopted.json`.
- **A form's conf in the editor and over MCP** (SM1392). The editor's client-side
  reservation exempts `lazysite/forms/<name>.conf`, so the server's gate (`manage_forms`,
  SM1371) decides; MCP `read_file` and `write_file` on that path ask `manage_forms`, the
  path's own capability, as a layout path asks the design capabilities. `smtp.conf`,
  `handlers.conf` and `schedule.conf` stay closed to every grant.
- **Smaller** (SM1385, SM1389, SM1391). A theme is deleted by its path under any layout,
  with the same refusals as by name (the active theme, a theme a domain serves, another
  account's theme, a path into a served copy). `lazysite check`'s stray-copy walk prunes
  the protected-history repository and nothing else. A schedule entry under the
  300-second floor is recorded as refused once and named by the check.

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
  operator); the actions also honour the full deny-set. MCP's
  `remove_permissions` is `acl-remove`'s twin: the same function, capability
  (`manage_content`), owner refusal and audit action (SM1263, 0.16.1).
- **A page's stem rule goes with the page** (SM1242, SM1257, SM1258, 0.16.1). A
  rule set on `/about` is stored as `about` and governs `about.md`. Every mover
  (the manager, MCP `move_file` and `rename_page`, the control API, WebDAV MOVE)
  and every delete calls `Acl::fold_page_stem`, which folds the stem rule into
  the page's own key, or drops it, while no folder of that name exists; before
  0.16.1 a moved draft left its rule behind and was published, its bytes synced
  back into the document root.
- **Forms:** a per-form dispatch config `lazysite/forms/<name>.conf` is
  agent-writable with `manage_forms`, and a PUT is shape-checked - its targets
  name existing handlers and nothing else (SM842). Handlers and the schedule
  are made through the handler actions, where the handler's destination
  decides the capability; `smtp.conf`, `handlers.conf`, `schedule.conf`,
  `.smtp-password` and the submissions store stay denied over WebDAV.

The agent-facing deny set (the dav enforcement, `/.well-known/ai-partner`, the
onboarding brief, and `whoami`) is held identical by
`t/integration/06-deny-consistency.t`, so the advertised and enforced sets
cannot drift.
