---
title: WebDAV publishing
subtitle: Publish content over WebDAV with per-user credentials and access controls.
tags:
  - configuration
---

## WebDAV publishing

lazysite can expose a WebDAV endpoint at `/dav` for headless,
per-file content publishing — deploy from `curl`, `rclone`, a CI job,
or a mounted drive without SSH or FTP. It is **off by default** and
opt-in per user.

The endpoint authenticates with HTTP Basic over TLS against the same
user database as the rest of lazysite, performs its own authentication
(it does not use the browser session cookie), and writes through the
same blocked-path, locking, audit-log, and cache-invalidation logic as
the manager — so a deploy can never reach lazysite's internal state or
collide with someone editing in the browser.

### Enabling the endpoint

Set in `lazysite/lazysite.conf`:

```
webdav_enabled: true
```

| Key | Default | Meaning |
|---|---|---|
| `webdav_enabled` | `false` | Master switch for the `/dav` endpoint. While off, `/dav` returns 404. |
| `dav_allow_insecure` | `false` | Permit Basic auth without HTTPS (for a TLS-terminating proxy or a trusted LAN). Leave off in normal deployments. |

Credentials are never accepted over plaintext HTTP unless
`dav_allow_insecure` is set; loopback (`127.0.0.1`) is always allowed
for local testing.

### Per-user access mechanisms

Each user has independent access-mechanism settings, managed from the
manager **Users** page or with `tools/lazysite-users.pl`:

| Setting | Default | Meaning |
|---|---|---|
| `webdav` | `off` | Whether this account may use the WebDAV endpoint. |
| `ui` | `on` | Whether this account may log in through the browser. |
| `dav_scope` | unset | If set (e.g. `/content`), confines this account's WebDAV access to that subtree. |

There is no separate "machine account" type — a deploy identity is
simply a user with `webdav: on`, `ui: off`, a generated credential,
and usually a scope:

```
tools/lazysite-users.pl --docroot DIR add deploy-bot <placeholder>
tools/lazysite-users.pl --docroot DIR set deploy-bot ui off
tools/lazysite-users.pl --docroot DIR set deploy-bot webdav on
tools/lazysite-users.pl --docroot DIR set deploy-bot dav_scope /content
tools/lazysite-users.pl --docroot DIR token deploy-bot      # prints the credential once
```

Disabling `ui` blocks the browser login entirely (no session cookie is
ever issued), so a `ui: off` account cannot reach the manager or any
auth-protected page. Setting `ui off` on the last manager-capable
account is refused unless you pass `--force`.

### Credentials

`token` (the manager's **Generate credential** button) issues a
256-bit random credential of the form `lzs_…`, shown **once**. Use it
as the password for any WebDAV-capable account, including human
accounts that want a strong machine credential. Generating a new
credential immediately invalidates the previous password/credential.

Prefer a generated credential for any WebDAV account: it is
high-entropy and verified with a single hash per request, where a
human-chosen password is stretched with 100,000 iterations on every
request.

### Clients

```bash
# publish one file
curl -u deploy-bot:lzs_… -T page.md https://site.example/dav/content/page.md

# sync a whole tree
rclone sync ./content :webdav:/content \
  --webdav-url https://site.example/dav \
  --webdav-user deploy-bot --webdav-pass "$(rclone obscure lzs_…)"

# mount on Linux
mount -t davfs https://site.example/dav /mnt/site
```

The endpoint implements WebDAV class 1 **and** class 2 (locking), so
read-write mounts work in Windows Explorer ("Map network drive") and
macOS Finder ("Connect to Server") as well as in command-line clients.

### Locking and the manager editor

WebDAV locks and the manager editor's locks share one store: a file
locked in the browser editor refuses DAV writes (and vice versa), so a
deploy and a person editing the same file cannot silently overwrite
each other. Locks are exclusive write locks; the server grants a
timeout of up to one hour.

Between two lockless WebDAV clients, plain `PUT` is last-writer-wins
(as with any filesystem). Clients that send `If-Match` get
conditional, lost-update-safe writes.

### Limitations

- **Properties are read-only.** `PROPFIND` reports live properties
  (size, type, modification time, etag, lock state). `PROPPATCH` is
  refused — lazysite stores no custom WebDAV "dead" properties. A
  practical consequence: clients that try to preserve a file's
  original modification time (e.g. Windows Explorer) cannot; the
  server file's modification time reflects upload time.
- **The whole `lazysite/` internal tree is unreachable** over WebDAV,
  regardless of scope — auth data, the manager, the cache, and config
  are never exposed or writable through `/dav`.
- `.pl`/`.cgi` files and the configured `manager_blocked_paths` are
  refused for writes, exactly as in the manager uploader.

### Troubleshooting

| Status | Meaning |
|---|---|
| 404 on `/dav` | `webdav_enabled` is not set, or the endpoint is not routed. |
| 401 | Missing or wrong credentials. |
| 403 | Account lacks `webdav`, the path is outside the account's `dav_scope`, the path is internal/blocked, or credentials arrived over plaintext without `dav_allow_insecure`. |
| 412 | An `If-Match` / `If-None-Match` precondition failed. |
| 413 | Upload exceeds `manager_upload_max_mb`. |
| 423 | The target is locked (by another DAV client or the manager editor). Carries `Retry-After`. |
| 429 | Too many failed auth attempts from this IP, or the per-token write throttle is exhausted. Carries `Retry-After`. |
| 503 | This account holds too many concurrent locks. |

### Control API and the retry contract

Theme and layout *management* (not file publishing) is driven through the
control API - the manager API reached with the same token as
`Authorization: Basic <user>:<lzs_ token>`. It is capability-gated and
CSRF-exempt for token requests. See
[Theme and layout publishing](/docs/features/configuration/theme-publishing).

Writes are throttled per token (a token bucket shared with this endpoint).
When throttled (`429`) or blocked by a lock (`423`), the response carries a
`Retry-After` header: honour it, backing off with a little jitter rather
than hammering.
