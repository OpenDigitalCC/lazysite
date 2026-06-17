# SM070 — WebDAV publishing endpoint with per-user access-mechanism controls

Status: **implemented** (2026-06-12) — `lazysite-dav.pl` plus the
settings/token tooling, `ui` enforcement, manager-API lock interop,
routing, manager UI, tests, and docs are all in the working tree. See
`.nonfunctional-report.md` for the close-out audit.
Author: Claude (specification + implementation)
Date: 2026-06-12 (rev 2 — class-2 locking and conditional requests
brought into scope; single-round delivery, no deferred follow-ups)
Target: lazysite ≥ 0.2.19

## 1. Summary

Add a headless, per-file publishing mechanism to lazysite: a WebDAV
**class 1 + 2** endpoint (`/dav/`) implemented as a self-contained CGI
script, authenticated with HTTP Basic over TLS against the existing
user database. Class 2 (LOCK/UNLOCK) ships from the start, backed by
the existing manager lock store, so desktop clients that require
locking — Windows Explorer and macOS Finder mounts — work in this
round. Access is governed by **per-user settings** — each user can
have individual access mechanisms enabled or disabled (`webdav`,
`ui`) and an optional **path scope** restricting where their WebDAV
writes may land. A **credential generator** produces high-entropy
secrets so that automation accounts (and humans who want them) get
healthy credentials.

There is **no separate machine-account class.** A "machine account"
is simply a user with `webdav: on`, `ui: off`, a generated credential,
and a path scope. Control is by function, not by account type.

### Why WebDAV

- Per-file semantics (PUT/DELETE/MKCOL) match content publishing.
- Interoperates with standard clients: `curl -T`, `rclone`, `cadaver`,
  `davfs2`, GNOME/KDE file managers — and, with class-2 locking,
  read-write mounts in Windows Explorer and macOS Finder.
- WebDAV has no token mechanism of its own — every mainstream client
  authenticates with HTTP Basic (over TLS). The industry pattern is
  app-passwords carried in the Basic password field; this feature
  adopts exactly that, backed by lazysite's existing hash store.

### Why not Apache mod_dav

mod_dav_fs writes directly to disk as the web user, bypassing
lazysite's blocked-path policy, locks, audit log, and cache
invalidation — and `lazysite/auth/` (including `.secret` and the user
database) lives *inside* the docroot. Fencing that with hand-kept
Apache config duplicates policy in two places. A native CGI keeps one
auth/policy/audit plane and stays within the no-dependency ethos.

## 2. Scope

**In scope**

1. New script `lazysite-dav.pl` (repo root, deployed to `cgi-bin/`):
   WebDAV class 1 + 2 — `OPTIONS`, `PROPFIND` (Depth 0/1), `GET`,
   `HEAD`, `PUT`, `DELETE`, `MKCOL`, `COPY`, `MOVE`, `LOCK`, `UNLOCK`
   (§3.5), plus `PROPPATCH` as a spec-compliant refusal (see
   exclusion 3 below).
2. Conditional requests: `If-Match` / `If-None-Match` evaluated on
   `PUT` and `DELETE` (412 on mismatch; `If-None-Match: *` gives
   create-only PUT), and the RFC 4918 `If` header for submitting
   lock tokens. ETags are already generated for PROPFIND, and lock
   support requires `If`-header parsing anyway, so conditionals are
   cheap here and close the lost-update gap between two DAV clients.
3. Class-2 locking mapped onto the existing manager lock store
   (`lazysite/manager/locks`), including manager-API awareness of
   DAV-origin locks, so a browser editing session and a DAV client
   cannot silently clobber each other in either direction (§3.5).
4. Per-user settings store `lazysite/auth/user-settings.json` with
   keys `webdav` (default **off**), `ui` (default **on**),
   `dav_scope` (default unset = whole docroot minus denied paths).
5. `tools/lazysite-users.pl` subcommands and API actions for
   settings management and credential generation.
6. Manager UI (Users page): per-user toggles, scope field, and a
   "generate credential" action that displays the secret exactly once.
7. Enforcement of `ui: off` in `lazysite-auth.pl` (login refusal).
8. Site-level gate `webdav_enabled:` in `lazysite.conf` (default off).
9. Routing in the Hestia template, Docker installer, and the dev
   server (`tools/lazysite-server.pl`).
10. Tests per §6.1, docs per §6.5.

**Excluded — permanent decisions, not deferrals**

This feature ships complete in one round; nothing below is "phase 2".
Each exclusion is a decision with a rationale, and the rationale is
what a future revisit would have to overturn.

1. **Digest authentication.** Excluded because it buys nothing here
   and costs real machinery. Digest's value is hiding the credential
   from the transport — TLS already does that, and the endpoint
   refuses credentials over plaintext (§3.4 gate 2). Meanwhile
   classic Digest is MD5-based (an insecure primitive this codebase
   otherwise avoids), its SHA-256 variant (RFC 7616) has negligible
   client support, and it forces server-side nonce state plus
   storing a password-equivalent (`HA1`) that weakens the at-rest
   story compared to the existing salted iterated hashes. Every
   target client speaks Basic. Basic-over-TLS with generated
   high-entropy credentials is the industry norm for DAV
   (Nextcloud, Fastmail app passwords).
2. **Multiple credentials / per-credential scoping.** Excluded
   because the account model already provides it: scope and
   mechanism flags live on the *user*, and users are cheap. Two
   deploy targets with different scopes = two users (`deploy-blog`,
   `deploy-docs`), each with its own generated credential,
   individually revocable via `passwd`/`token` regeneration or
   `remove`. A per-credential layer would duplicate exactly this
   (a second keyed store, lifecycle UI, per-credential settings)
   inside each user for no capability gain. If a future need
   genuinely requires many credentials sharing one identity (e.g.
   audit-attributable CI runners behind a single username), that is
   a new account-model feature, not a WebDAV gap.
3. **Dead-property storage (full `PROPPATCH`).** `PROPPATCH` is
   implemented, but as the spec-compliant refusal: a 207
   multistatus answering 403 per property. What is excluded is a
   *dead-property store* — a sidecar metadata database whose only
   reader would be DAV clients round-tripping arbitrary XML.
   Nothing in lazysite renders, indexes, or queries such
   properties; the store would be pure compliance weight with its
   own locking, quota, and blocked-path questions. Consequences,
   documented for operators: clients that try to preserve
   attributes via PROPPATCH (e.g. Windows Explorer setting
   `Win32LastModifiedTime`) get refusals they tolerate; file mtimes
   on the server reflect upload time, not source mtime; the litmus
   `props` suite reports expected failures (pinned in the test
   harness, §6.1). Live properties (`getcontentlength`,
   `getlastmodified`, etc.) are served read-only via PROPFIND as
   normal.
4. **Shared locks.** Exclusive write locks only; `supportedlock`
   advertises exactly that, which RFC 4918 permits. Shared locks
   model cooperating-writer scenarios that don't exist for a
   single-tree static site, and the desktop clients that motivate
   class 2 request exclusive locks. The manager lock store this
   feature builds on is also exclusive-by-design; supporting shared
   locks would mean reworking it for a use case with no consumer.

## 3. Design

### 3.1 Per-user access-mechanism settings

New file: `lazysite/auth/user-settings.json`, mode `0640`, inside the
existing `auth/` dir (mode `0750`). JSON object keyed by username:

```json
{
  "deploy-bot": { "webdav": true,  "ui": false, "dav_scope": "/content" },
  "stuart":     { "webdav": false, "ui": true }
}
```

Rules:

- **Absent file, absent user, or absent key ⇒ defaults**: `ui: true`
  (existing behaviour preserved for all current users), `webdav:
  false` (new surface is opt-in per user), `dav_scope: null`
  (docroot-wide, still subject to §3.4 denials).
- **Unparseable JSON ⇒ defaults for everyone** — which fails closed
  for WebDAV (off) and fails open for UI (on, matching today's
  behaviour so a corrupt settings file cannot lock the operator out).
  Log a WARN once per request that hits this.
- Written only by `tools/lazysite-users.pl` (single writer, under
  `flock`, write-temp-then-rename like `update_user_hash`). Read by
  `lazysite-auth.pl`, `lazysite-dav.pl`, and the manager API (via the
  users tool's `--api` mode).
- Settings survive `passwd`; `remove` deletes the user's settings
  entry.
- `dav_scope` value: a site-absolute path (`/content`), normalised to
  no trailing slash; `/` means docroot-wide (same as unset). Stored
  verbatim; enforcement is in §3.4.

The username key requirement matches the existing users-file
constraint (no `:` in usernames; the tool already enforces its
username charset — reuse that validation).

### 3.2 Credential generation ("healthy passwords")

New subcommand in `tools/lazysite-users.pl`:

```
lazysite-users.pl --docroot DIR token <username>
```

- Generates 32 bytes from `/dev/urandom` via the existing
  `generate_random_hex` (fail-closed), printed once as
  `lzs_<64 hex chars>`. Never logged, never stored in plaintext.
- Stores it through the normal hash machinery **with `iterations=1`**:
  `sha256iter:<salt>:1:<hash>`. The existing `verify_password` already
  parses the iteration count from the stored row, so **no change to
  any verifier** is needed.
- Rationale for `iterations=1`: iterated hashing exists to slow
  offline brute force of low-entropy human passwords. A 256-bit
  random token is not brute-forceable regardless of iteration count,
  and WebDAV verifies credentials on *every request* — 100 k
  iterations per PUT is pure waste. Human-chosen passwords (`add`,
  `passwd`) keep 100 k iterations unchanged. Only the generator may
  write `iterations=1`.
- API mode: `{"action":"token","username":"deploy-bot"}` returns
  `{"ok":1,"token":"lzs_..."}` exactly once. The manager Users page
  gets a "Generate credential" button per user that shows the value
  in a one-time reveal panel with a copy control and the warning
  "shown once, store it now".
- The same action serves as the "suggest a strong password" function
  for human accounts: generating a token for a `ui: on` user simply
  replaces their password with a strong one.

Settings subcommands (CLI and mirrored `--api` actions
`settings-get` / `settings-set`):

```
lazysite-users.pl --docroot DIR settings <user>                 # show
lazysite-users.pl --docroot DIR set <user> webdav on|off
lazysite-users.pl --docroot DIR set <user> ui on|off
lazysite-users.pl --docroot DIR set <user> dav_scope /content
lazysite-users.pl --docroot DIR set <user> dav_scope ''         # clear
```

Guard: `set <user> ui off` must refuse (with override flag
`--force`) when it would disable UI for the *last* user that has UI
access and membership in a `manager_groups` group — otherwise one
command locks every human out of the manager. API mode returns
`{"ok":0,"error":"would disable last manager-capable UI account"}`.

### 3.3 `ui` flag enforcement (lazysite-auth.pl)

In the login POST handler, **after** `verify_password` succeeds and
before the cookie is issued: load settings; if effective `ui` is
false, reject with the login page error "Interactive login is
disabled for this account" (post-verification, so this leaks nothing
to password guessers — failures before verification keep the existing
generic error and rate-limit behaviour) and log a WARN. No cookie is
ever issued, which also keeps the user out of the manager API and
auth-protected pages — mechanism off means off everywhere the cookie
reaches.

The localhost empty-hash bypass (security.md §Localhost bypass) must
also respect `ui: off`.

### 3.4 The WebDAV endpoint (`lazysite-dav.pl`)

Self-contained CGI per the project policy (no shared modules;
duplicates `log_event`, `const_eq`, `verify_password`,
`generate_random_hex`-style helpers by convention — extend the
duplication-audit list in `docs/architecture/code-quality.md`).
`$LOG_COMPONENT = 'dav'`.

**Routing.** URL namespace `/dav/<site-path>` maps to
`$DOCROOT/<site-path>` via `PATH_INFO`. The endpoint is reached
*directly* — **not** through `lazysite-auth.pl`; it performs its own
Basic auth and never reads cookies or `X-Remote-*` headers (and must
ignore them even if present). Hestia template addition:

```apache
ScriptAlias /dav %home%/%user%/web/%domain%/cgi-bin/lazysite-dav.pl
```

placed before `FallbackResource`. The existing
`SetEnvIf Authorization .+ HTTP_AUTHORIZATION=$0` line in the
template already forwards the Basic header to CGI. The dev server
already passes arbitrary methods through to CGIs; it needs a route:
URI prefix `/dav` → `lazysite-dav.pl`, bypassing the auth wrapper,
preserving `PATH_INFO` and `HTTP_AUTHORIZATION`.

**Request processing order** (every request):

1. **Site gate.** `webdav_enabled:` truthy in `lazysite.conf`, else
   `404 Not Found` (no advertisement of the surface).
2. **Transport gate.** If `$ENV{HTTPS}` is not set and
   `REMOTE_ADDR` is not `127.0.0.1`/`::1`: `403` unless
   `dav_allow_insecure: true` in `lazysite.conf`. Never challenge for
   Basic credentials over plaintext.
3. **Authentication.** Parse `Authorization: Basic` (decode with
   `MIME::Base64`, core; split on first `:`). Missing/malformed ⇒
   `401` + `WWW-Authenticate: Basic realm="lazysite-dav"`. Verify with
   the same `verify_password` semantics as login (constant-time,
   legacy-format tolerated but **no rehash-on-login from this path**
   — rehash stays a login-flow concern).
   - Failed-auth rate limit: per-IP, 5 failures / 5 min window,
     DB_File at `lazysite/auth/.dav-rate.db`, 2 s sleep on failure,
     fail-open on tie failure — mirroring the H-3 login limiter.
     Exceeded ⇒ `429`.
4. **Mechanism gate.** Effective `webdav` setting for the
   authenticated user must be true, else `403` (logged WARN).
5. **Path resolution.** Decode `PATH_INFO`; reject null bytes, `..`
   segments, and control characters (reuse the `sanitise_uri`
   pattern); resolve the **parent** directory via `Cwd::realpath`
   (the leaf may not exist yet for PUT/MKCOL) and require the result
   to start with `$DOCROOT`. Then apply, in order:
   - **Internal-tree denial:** any path whose docroot-relative form
     is `lazysite` or starts with `lazysite/` ⇒ `403`. WebDAV can
     never touch lazysite's internal state (auth, manager, forms,
     cache, conf). This is deliberately stricter than the manager
     API's file-level `@BLOCKED_PATHS`.
   - **Blocked-path rules:** the manager's `is_blocked_path` logic
     (`.pl` rule) plus the configurable `manager_blocked_paths` /
     `manager_upload_blocked_extensions` lists apply to all write
     methods, same semantics as manager upload check 5–6.
   - **User scope:** if `dav_scope` is set, the docroot-relative
     path must equal the scope or live under it, for the request
     path *and* for `Destination` on COPY/MOVE ⇒ otherwise `403`.
6. **Method dispatch.**

| Method | Behaviour | Success | Notable errors |
|---|---|---|---|
| `OPTIONS` | `DAV: 1, 2`, `Allow:` full list | 200 | — |
| `PROPFIND` | Depth `0` (file/dir) or `1` (dir listing). Request body is **not parsed**; respond as `allprop` with: `displayname`, `resourcetype`, `getcontentlength`, `getcontentmtime` → `getlastmodified` (RFC 1123 date), `getcontenttype` (reuse the manager's `%CONTENT_TYPE_MAP`), `getetag` (`"<dev>-<ino>-<mtime>-<size>"` hex), `supportedlock` (exclusive write only), `lockdiscovery` (active lock if any). XML-escape all hrefs/names. | 207 | `Depth: infinity` ⇒ 403; missing ⇒ 404 |
| `GET`/`HEAD` | Stream file bytes with mapped Content-Type. Directories ⇒ 403 (no listing via GET). | 200 | 404 |
| `PUT` | `CONTENT_LENGTH` checked against `manager_upload_max_mb` **before reading** (oversize ⇒ 413); body read in 64 KiB chunks to `<target>.tmp.$$` in the target dir, then `rename()`. Parent dir must exist ⇒ else 409 (RFC 4918 §9.7.1). Lock check per §3.5; conditionals: `If-Match` mismatch ⇒ 412, `If-None-Match: *` on existing target ⇒ 412 (create-only PUT). | 201 created / 204 overwrite | 409, 412, 413, 423 |
| `MKCOL` | Create one directory level. Exists ⇒ 405; parent missing ⇒ 409; request body present ⇒ 415. | 201 | 405, 409, 415 |
| `DELETE` | File: unlink. Directory: recursive delete **only within scope**, using `File::Path::remove_tree` after the same realpath/scope checks. Lock check per §3.5; `If-Match` honoured as for PUT. | 204 | 404, 412, 423 |
| `COPY`/`MOVE` | `Destination` header: must parse to the same host and the `/dav/` prefix; destination passes the full step-5 chain. `Overwrite: F` honoured (412 if destination exists). MOVE = rename() with cross-device fallback (copy+unlink). Lock check on source (MOVE/DELETE side) and destination per §3.5. | 201 / 204 | 403 (scope), 409, 412, 423 |
| `LOCK` | Take/refresh an exclusive write lock (§3.5). | 200 | 403 (depth), 423 |
| `UNLOCK` | Release own lock via `Lock-Token` header (§3.5). | 204 | 400, 403, 409 |
| `PROPPATCH` | Spec-compliant refusal: 207 multistatus, 403 per property (scope §2 exclusion 3). | 207 | — |

7. **Cache invalidation.** After any successful write method, drop
   the rendered-page cache entry/entries for affected paths exactly
   as `action_save`/`action_delete` in the manager API do (same
   helper logic, duplicated per the self-contained policy). A stale
   cache after a deploy would make the feature look broken.
8. **Audit logging.** Every write method logs INFO with
   `user`, `method`, docroot-relative `path` (and `dest` for
   COPY/MOVE), `bytes` for PUT, `status`. Auth failures and gate
   refusals log WARN. Same `log_event` format as the other scripts.

**New `lazysite.conf` keys**

| Key | Default | Meaning |
|---|---|---|
| `webdav_enabled` | `false` | Master switch for the endpoint |
| `dav_allow_insecure` | `false` | Permit Basic auth without `$ENV{HTTPS}` (dev/proxy setups) |

`manager_upload_max_mb`, `manager_blocked_paths`,
`manager_upload_blocked_extensions` are reused, not duplicated.

### 3.5 Locking (class 2)

Class-2 support is built on the manager lock store rather than a new
subsystem, so DAV locks and manager-editor locks are the same locks.

**Store.** Reuse `lazysite/manager/locks` (one entry per resource,
keyed exactly as `acquire_lock`/`release_lock`/`renew_lock` key it
today). Each entry gains optional fields: `token` (DAV lock token),
`origin` (`manager` | `dav`), `timeout` (granted seconds). The
manager API's lock subs are extended to read/write the new fields
and to treat a fresh `dav`-origin lock exactly like another user's
manager lock (refuse acquisition, surface the owner in the editor
UI). Expiry stays lazy-on-access with opportunistic sweep, as today.

**Semantics** (deliberately minimal but RFC-conformant):

- Exclusive write locks only (§2 exclusion 4), `Depth: 0` only —
  `Depth: infinity` lock requests ⇒ 403. Desktop clients lock files,
  not trees.
- **Token:** `opaquelocktoken:` + UUIDv4 formatted from 16
  `/dev/urandom` bytes via the existing fail-closed CSPRNG helper.
- **LOCK on an existing resource:** if unlocked (or own lock
  refresh), grant; respond 200 with `DAV:lockdiscovery` body and
  `Lock-Token` header. If locked by another token, another user, or
  a manager session ⇒ 423.
- **LOCK on an unmapped URL:** create a zero-byte file (after the
  full §3.4 step-5 path chain — gates, blocked paths, scope) and
  lock it (RFC 4918 locked-empty-resource). This is what
  Office/Finder save flows do: LOCK, PUT, UNLOCK.
- **Refresh:** LOCK with no body and an `If` header carrying the
  current token resets the clock; same response shape.
- **Timeout:** granted = `min(requested seconds, 3600)`;
  `Infinite` ⇒ 3600; absent ⇒ 300 (manager parity). Granted value
  reported via the `Timeout: Second-N` response header and in
  `lockdiscovery`.
- **UNLOCK:** requires the `Lock-Token` header. Missing ⇒ 400;
  token mismatch ⇒ 409; token matches but authenticated user is not
  the lock owner ⇒ 403; owner match ⇒ release, 204.
- **Write-method enforcement** (PUT/DELETE/MOVE source/COPY
  destination/MKCOL of a locked name): if the target holds a fresh
  DAV lock, the request must carry the token in an `If` header —
  accept both untagged `(<opaquelocktoken:…>)` and tagged
  `<url> (<token>)` list forms; `Not` groups are ignored. Valid
  token ⇒ proceed; otherwise ⇒ 423. Manager-origin locks have no
  client-known token, so they cannot be overridden via DAV at all —
  423 until the editor releases or the lock expires.
- **Flood control:** at most 100 concurrent DAV locks per user; the
  101st ⇒ 503 with a WARN log. Prevents a leaked credential from
  papering the tree with 3600-second locks.

**LOCK request body:** parsed leniently — the only decision needed
from `lockinfo` is exclusivity (anything else is refused anyway), so
detect `<shared/>` (⇒ 403) and otherwise treat as exclusive write.
`owner` XML, if present, is stored opaquely (truncated to 1 KiB) and
echoed in `lockdiscovery`; it is operator-visible in the manager
lock display, so it is XML-escaped on output.

### 3.6 Manager UI (Users page)

- Per-user rows gain: `UI` toggle, `WebDAV` toggle, `DAV scope` text
  field, `Generate credential` button (one-time reveal).
- All writes go through existing `action=users` POST plumbing (CSRF
  gate applies) to the new `settings-set` / `token` sub-actions.
- The "last manager-capable UI account" guard (§3.2) surfaces as an
  inline error.
- `user-settings.json` must be added to the manager API's
  `@BLOCKED_PATHS` so it cannot be read or edited as a file through
  the editor surfaces.

### 3.7 Client usage (documentation examples)

```bash
# one file
curl -u deploy-bot:lzs_… -T page.md https://site.example/dav/content/page.md
# a tree
rclone sync ./content :webdav:/content \
  --webdav-url https://site.example/dav \
  --webdav-user deploy-bot --webdav-pass "$(rclone obscure lzs_…)"
# mount (Linux)
mount -t davfs https://site.example/dav /mnt/site
```

Plus desktop mounts: Windows Explorer "Map network drive" and macOS
Finder "Connect to Server" (both require the class-2 locking shipped
by this feature).

## 4. Security considerations

Threat model additions and controls, aligned with
`docs/architecture/security.md`:

1. **New unauthenticated surface.** The endpoint pre-auth exposes
   only: the 404 site gate, the 403 transport gate, and the 401
   challenge. No filesystem access happens before authentication.
   Default state (`webdav_enabled` absent) is **off** — zero new
   surface for existing installations after upgrade.
2. **Online credential guessing.** Basic auth is an oracle ⇒ per-IP
   rate limiting + failure sleep, mirroring the login limiter
   (same documented weakness: rotating IPs defeats it; acceptable —
   consistent with the existing threat model).
3. **Credential quality.** The generator produces 256-bit secrets;
   docs steer operators to generated credentials for any
   WebDAV-enabled user. `iterations=1` rows are written *only* by the
   generator (test-pinned), so low-entropy human passwords always
   keep 100 k iterations.
4. **Plaintext credential exposure.** Basic over HTTP is refused
   unless explicitly configured (`dav_allow_insecure`), except
   loopback. The Hestia template is SSL-only already.
5. **Path traversal / symlink escape.** Same realpath-then-prefix
   discipline as the processor and manager API, applied to source
   *and* destination paths, plus `sanitise_uri`-style rejection
   before any filesystem touch. Symlinks that resolve outside the
   docroot are rejected by the realpath check.
6. **Internal-state protection.** Whole-`lazysite/` denial (stricter
   than the manager API) means the auth secret, user DB, settings
   file, rate DBs, and rendered cache are unreachable via DAV even
   with a docroot-wide scope. `user-settings.json` additionally joins
   the manager `@BLOCKED_PATHS`.
7. **Scope as blast-radius control.** A leaked deploy credential
   with `dav_scope: /content` is a content-defacement problem, not a
   site takeover. Docs recommend a scope for every WebDAV-enabled
   user.
8. **No CSRF exposure.** The endpoint never reads cookies, so it
   adds no CSRF surface; conversely it must ignore `X-Remote-*` and
   `LAZYSITE_AUTH_TRUSTED` even if a misconfigured proxy injects
   them (test-pinned).
9. **Concurrent-write integrity.** One shared lock store: DAV writes
   honour manager locks and the manager editor honours DAV locks
   (423 both ways), so a browser session and a deploy cannot
   silently clobber each other. Between two lockless DAV clients,
   `If-Match` conditionals give opt-in lost-update protection;
   plain unconditional PUTs remain last-writer-wins (documented —
   same as any filesystem).
10. **Lock subsystem abuse.**
    - Tokens come from the fail-closed CSPRNG (UUIDv4 from
      `/dev/urandom`) — unguessable, and never logged.
    - UNLOCK requires token match **and** owner match (a second
      user replaying a leaked token gets 403).
    - Manager-origin locks are not overridable from DAV (no token
      exists client-side), so a deploy credential cannot evict an
      operator's editing lock.
    - Lock flooding bounded: 100 concurrent locks per user, 3600 s
      timeout ceiling, lazy expiry + opportunistic sweep — a leaked
      credential cannot permanently freeze the tree.
    - LOCK on an unmapped URL creates a file, so it runs the *full*
      write-path chain (gates, blocked paths, scope) — lock-created
      files cannot land anywhere a PUT couldn't.
    - Client-supplied `owner` XML is stored truncated (1 KiB) and
      XML-escaped wherever echoed (lockdiscovery, manager lock
      display) — no stored-XSS path into the manager UI.
11. **Resource exhaustion.** `CONTENT_LENGTH` gate before body read;
    chunked tempfile writes bound memory; PROPFIND limited to
    Depth 0/1 (no recursive tree walks); recursive DELETE bounded by
    scope. No per-user upload quota in this round — accepted residual
    risk, consistent with the manager API being rate-unlimited for
    authenticated users except uploads; the manager upload-quota
    machinery is the named reuse path if operators report abuse.
12. **`ui: off` containment.** Disabling UI blocks cookie issuance at
    login (including the localhost empty-hash bypass), which gates
    the manager UI, manager API, and auth-protected pages in one
    place.

## 5. Implementation plan (ordered, one commit each, SM063 flow)

Each step ends with `prove -r t/` green and its own
`.commit-message.md` (`SM070a`, `SM070b`, … as commit titles).

1. **SM070a — settings store + users tool.** `user-settings.json`
   read/write in `tools/lazysite-users.pl` (`settings`, `set`,
   `token` CLI + API actions, last-manager guard), `iterations=1`
   token storage. Unit tests `t/unit/users/`.
2. **SM070b — ui-flag enforcement.** `lazysite-auth.pl` login check
   incl. localhost bypass. Unit tests `t/unit/auth/`.
3. **SM070c — lazysite-dav.pl core.** Gates, Basic auth, rate
   limiter, path chain, OPTIONS/PROPFIND/GET/HEAD, PROPPATCH
   refusal. (`OPTIONS` may advertise `DAV: 1` at this commit; the
   `1, 2` value lands with SM070e and the final value is what tests
   pin.) Unit + integration tests.
4. **SM070d — write methods + conditionals.** PUT/DELETE/MKCOL/
   COPY/MOVE, `If-Match`/`If-None-Match`, manager-lock respect,
   cache invalidation, audit logging. Unit + integration tests.
5. **SM070e — class-2 locking.** LOCK/UNLOCK, `If`-header token
   parsing on write methods, lock-store field extensions and
   manager-API interop (manager honours `dav`-origin locks),
   `supportedlock`/`lockdiscovery` in PROPFIND, `DAV: 1, 2`. Unit
   tests `t/unit/dav/06-lock.t`, `07-conditionals.t`.
6. **SM070f — routing + manager UI.** Hestia template, Docker
   installer, dev server route; Users page controls via
   `action=users` sub-actions; `user-settings.json` into
   `@BLOCKED_PATHS`. Journey test `t/journey/05-webdav-publish.t`
   including the LOCK→PUT→UNLOCK cycle.
7. **SM070g — docs + SBOM.** Everything in §6.5; add `MIME::Base64`
   (core) to `dist/config/sbom-deps.json` (it is not currently
   listed; the release SBOM gate is strict).
8. **SM070h — close-out.** Changed-areas five-dimension audit
   (§6 verification), `.nonfunctional-report.md` per
   `rules/nonfunctional-close.md`.

Decisions that look open but are **already made** (do not re-ask):
no machine-account class; settings are per-user not per-credential
(§2 exclusion 2); class 1 + 2 in this round, exclusive write locks
only, Depth 0 only; Basic-over-TLS only (§2 exclusion 1);
request-body-less PROPFIND; PROPPATCH = compliant refusal, no
dead-property store (§2 exclusion 3); locks live in the manager
lock store, not a parallel one; `iterations=1` for generated
secrets only; whole-`lazysite/` DAV denial; defaults `ui=on`,
`webdav=off`, gate off.

## 6. Non-functional requirements (five-part package)

Scope note: this is a feature-level package — requirements here, and
a changed-areas audit at close (step SM070g), per
`rules/nonfunctional-close.md` mid-project scoping.

### 6.1 Test coverage

Target: ≥ 80 % line coverage on new/changed code (rules/tests.md),
measured with `Devel::Cover` at close-out. All tests core-Perl-only,
`File::Temp` docroots, runnable standalone, deterministic (seed rate
DBs directly rather than sleeping — follow
`t/unit/auth/03-login-rate-limit.t`).

| Tier | File | Pins |
|---|---|---|
| unit | `t/unit/users/05-settings.t` | defaults for absent file/user/key; set/get round-trip; corrupt JSON ⇒ defaults + warn; `remove` clears entry; last-manager guard refuses, `--force` overrides; scope normalisation |
| unit | `t/unit/users/06-token.t` | `lzs_` + 64-hex format; stored as `sha256iter:<salt>:1:`; verifies via `verify_password`; two calls differ; plaintext absent from disk after run |
| unit | `t/unit/auth/04-ui-flag.t` | correct password + `ui: off` ⇒ refusal, no Set-Cookie, WARN logged; localhost empty-hash bypass also refused; `ui: on`/absent unchanged |
| unit | `t/unit/dav/01-gates-auth.t` | gate-off ⇒ 404; plaintext ⇒ 403 (loopback + `dav_allow_insecure` exceptions); no/garbled Authorization ⇒ 401 + realm; bad password ⇒ 401; good password + `webdav: off` ⇒ 403; rate DB seeded at limit ⇒ 429; `X-Remote-User`/`LAZYSITE_AUTH_TRUSTED` env ignored |
| unit | `t/unit/dav/02-paths.t` | traversal/null/`%2e%2e` ⇒ 4xx; `lazysite/` subtree ⇒ 403; `.pl` and configured blocked paths ⇒ 403; scope: inside ok, outside 403, boundary cases (`/content` vs `/contentX`); symlink escaping docroot ⇒ 403 |
| unit | `t/unit/dav/03-propfind.t` | depth 0 file and dir; depth 1 listing complete; `Depth: infinity` ⇒ 403; 207 body contains escaped hrefs for awkward names (`a&b.md`, spaces); etag/length/mtime present; `supportedlock` advertises exclusive-write only; `lockdiscovery` empty vs active-lock cases; unknown depth header defaults pinned; PROPPATCH ⇒ 207 with per-property 403 |
| unit | `t/unit/dav/04-put-delete-mkcol.t` | PUT new ⇒ 201, overwrite ⇒ 204; oversize CONTENT_LENGTH ⇒ 413 with no body read; missing parent ⇒ 409; tempfile never left behind on simulated short write; manager lock by other user ⇒ 423, own lock ⇒ allowed; MKCOL 201/405/409/415; DELETE file/dir/404 |
| unit | `t/unit/dav/05-copy-move.t` | Destination host/prefix validation; dest outside scope ⇒ 403; `Overwrite: F` ⇒ 412; MOVE renames; COPY duplicates; cache entries for affected `.md` invalidated |
| unit | `t/unit/dav/06-lock.t` | LOCK ⇒ 200 + `Lock-Token` + lockdiscovery body; token is `opaquelocktoken:` UUID shape; LOCK while locked by other user/token ⇒ 423; refresh via `If` resets clock (seed timestamps); timeout grant = min(requested, 3600), `Infinite` ⇒ 3600, absent ⇒ 300; LOCK unmapped URL creates locked zero-byte file, but ⇒ 403 when target is blocked/out-of-scope; `<shared/>` ⇒ 403; `Depth: infinity` ⇒ 403; UNLOCK: missing header 400 / wrong token 409 / non-owner 403 / owner 204; expired lock auto-clears; 101st concurrent lock ⇒ 503; `owner` XML truncated + escaped on echo |
| unit | `t/unit/dav/07-conditionals.t` | `If-Match` matching etag ⇒ proceed, stale ⇒ 412; `If-None-Match: *` ⇒ 412 on existing, 201 on new; PUT on DAV-locked path without `If` token ⇒ 423, with valid token ⇒ 2xx; tagged and untagged `If` list forms accepted; manager-origin lock not overridable by any `If` ⇒ 423; manager-api `acquire_lock` refuses a path holding a fresh dav-origin lock |
| integration | `t/integration/dav-publish.t` | subprocess end-to-end: PUT `.md` then processor renders it 200; re-PUT changes rendered output (cache invalidated); DELETE ⇒ processor 404 |
| journey | `t/journey/05-webdav-publish.t` | create user via tool → enable webdav + scope → generate token → PUT via DAV with token → page renders → LOCK→PUT(`If`)→UNLOCK cycle succeeds → manager lock blocks DAV PUT and vice versa → `set user webdav off` → next PUT 403 → token regeneration invalidates old credential |
| smoke | extend existing smoke tier | OPTIONS on enabled site returns `DAV: 1, 2`; disabled site returns 404 |
| optional | `t/integration/litmus.t` | runs the `litmus` compliance suite when `LITMUS_BIN` is set; `skip_all` otherwise (rules/tests.md skip pattern). Expectation pinned per suite: `basic`, `copymove`, `locks` pass; `props` reports the expected dead-property failures from §2 exclusion 3 (assert the failure count/class so regressions in *our* behaviour still surface) |

Add a `TestHelper::run_dav($docroot, $method, $path, %env)` fixture
helper modelled on `run_processor`.

### 6.2 Code quality

- Self-contained script policy: `lazysite-dav.pl` shares no modules;
  update the duplication-by-convention list and script inventory in
  `docs/architecture/code-quality.md` (helpers now duplicated:
  `log_event`, `const_eq`, `verify_password`, settings reader,
  blocked-path checks, cache invalidation).
- `perlcritic --severity 3` clean apart from the documented
  deviations table; any new deviation gets a table row, not a
  `## no critic`.
- `use strict; use warnings;`, functional style, no OO, Perl ≥ 5.10
  features only.
- Method dispatch as a flat `elsif` chain matching the manager API's
  idiom (grep-ability over cleverness).
- All new conf keys read via the existing single-pass
  `lazysite.conf` parse pattern; no second config format.

### 6.3 Performance

- CGI baseline is ~44–78 ms/request (architecture/performance.md);
  budget: DAV requests with generated credentials add **< 10 ms**
  over baseline for auth + gates (single-iteration hash ≈ one
  SHA-256). A user-password (100 k iterations) costs ~tens of ms per
  request — documented as the reason to use generated credentials
  for automation.
- PUT memory bounded: 64 KiB chunked copy, never slurp the body.
- PROPFIND depth 1 is O(directory entries), one `stat` each; no
  recursion. Note the measured cost for a 1 000-entry directory in
  the close-out report and add a DAV row to performance.md's
  baseline table.
- Rate-DB opportunistic cleanup mirrors the login limiter (bounded
  growth).
- Lock checks add at most one lock-store lookup per write request
  and per locked resource in a depth-1 PROPFIND; lock files are
  small JSON reads. Desktop-mount traffic (Explorer/Finder) is
  PROPFIND-heavy — note the measured cost of a depth-1 PROPFIND
  with and without active locks in the close-out report.

### 6.4 Security verification (at close, changed-areas scope)

- `perlcritic --theme=security` over changed files.
- Manual audit checklist: every filesystem call in
  `lazysite-dav.pl` is preceded by the §3.4 step-5 chain (including
  the LOCK-creates-file path); no `system`/backticks; no `eval` of
  request data; `Destination` parsing cannot be coerced to another
  host/prefix; UNLOCK enforces token **and** owner; client `owner`
  XML is escaped at every echo point.
- Negative-path tests of §6.1 all green (they are the executable
  form of the §4 controls).
- Secrets scan over the diff (no `lzs_` literals or fixture
  plaintext credentials committed; tests generate at runtime).
- Confirm upgrade posture: a tree upgraded with the feature absent
  from `lazysite.conf` serves 404 on `/dav/` and behaves identically
  elsewhere (journey assertion).

### 6.5 Documentation deliverables and alignment

New:

- `starter/docs/features/configuration/webdav.md` — operator guide:
  enabling, per-user flags, scope, credential generation, client
  examples (§3.7) including Windows Explorer / macOS Finder / davfs2
  mounting, locking behaviour (shared store with the manager
  editor), the PROPPATCH/mtime caveat (§2 exclusion 3),
  troubleshooting table (404/401/403/412/413/423/429/503 meanings).

Updates (bring in line):

- `docs/architecture/security.md` — new "WebDAV endpoint" section
  (§4 content incl. the lock subsystem), settings file in the auth
  storage description, `iterations=1` rationale beside the
  password-storage section, rate-limit table row, `ui` flag in the
  auth flow, manager-lock section updated for the shared DAV/manager
  lock store.
- `docs/architecture/code-quality.md` — script inventory +
  duplication list (§6.2).
- `docs/architecture/performance.md` — DAV baseline row (§6.3).
- `docs/architecture/test-coverage.md` — new test files, tier
  descriptions, updated totals, `run_dav` helper.
- `starter/docs/features/configuration/auth.md` — per-user
  access-mechanism settings cross-reference.
- `starter/docs/features/configuration/lazysite-conf.md` —
  `webdav_enabled`, `dav_allow_insecure`.
- `starter/docs/features/configuration/manager.md` — Users page
  additions.
- `installers/hestia/lazysite.stpl` and `.tpl`, Docker installer —
  `/dav` ScriptAlias. While editing the templates: they do not
  currently carry the `RequestHeader unset X-Remote-*` lines that
  security.md §"Apache config requirement" mandates — pre-existing
  gap, fix in the same commit and note it in the commit message.
- `README.md` feature list; `UPGRADE.md` (off-by-default, how to
  enable).
- `dist/config/sbom-deps.json` — `MIME::Base64`
  (`{"core": true, "license": "Artistic-1.0-Perl", "used_by": "lazysite-dav.pl Basic auth"}`).

Out-of-tree alignment (flag to operator, do not edit from a lazysite
session): the project `CLAUDE.md` "Release contract" section and
`/srv/projects/rules/release-workflow.md` still describe the retired
`.release-notes.md` / `pre-release.sh` contract; the in-tree
authority since SM063 is `docs/development.md`
(`.commit-message.md` + `tools/commit.sh` + `tools/release.sh`).
This spec follows SM063.

## 7. Acceptance criteria

1. Fresh install, defaults: `/dav/` returns 404; nothing else changed.
2. `webdav_enabled: true` + user with `webdav: on` + generated
   credential: `curl -u user:lzs_… -T page.md
   https://host/dav/content/page.md` ⇒ 201, page renders via the
   processor immediately (cache invalidated), audit line logged.
3. Same user with `dav_scope: /content` PUTting to `/dav/index.md`
   ⇒ 403.
4. Same user with `ui: off` cannot obtain a login cookie; manager
   and protected pages unreachable for that user.
5. Any DAV request touching `/dav/lazysite/...` ⇒ 403 regardless of
   scope or flags.
6. `rclone sync` of a content tree against `/dav` completes.
7. `cadaver` LOCK → PUT → UNLOCK cycle succeeds; while the lock is
   held, a second credential's PUT to the same path returns 423; a
   stale-`If-Match` PUT returns 412.
8. A path locked in the manager editor refuses DAV writes (423),
   and a DAV-locked path shows as locked in the editor.
9. `litmus` (when available): `basic`, `copymove`, and `locks`
   suites pass; `props` failures match the pinned expected set.
   Desktop-mount verification (Explorer / Finder read-write) is an
   operator-side acceptance step — record the result in the
   close-out report; davfs2 mount is the CI-side proxy for it.
10. Full suite `prove -r t/` green; new-code coverage ≥ 80 %;
    `.nonfunctional-report.md` produced at close.
