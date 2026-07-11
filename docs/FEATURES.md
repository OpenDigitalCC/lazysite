---
title: "Lazysite - Complete Feature Reference"
subtitle: "Everything lazysite has and does, and why - as of v0.7.2"
brand: plain
---

# What lazysite is

Lazysite is a Markdown-driven website engine and lightweight CMS written in
near-core Perl. You drop a `.md` file into a document root; on the first request
the processor renders it to HTML through a layout/theme, caches the result as a
sibling `.html`, and the web server serves that cache directly thereafter. There
is **no build step, no database, and no application server** - just CGI scripts, a
tree of Markdown, and a flat-file configuration. (For production speed the same
processor can run as a persistent per-site FastCGI pool - see Part IX - but
plain CGI remains the default and the baseline.)

Around that core sits a full publishing and management stack: a browser-based
manager UI, a JSON control API, a WebDAV endpoint, an AI connector that speaks the
Model Context Protocol (MCP), built-in cookie authentication with OAuth 2.1 for
machine partners, per-file ownership and access control, an append-only audit
trail, theming with self-service activation, forms with pluggable delivery, the
x402 payment protocol, and a supply-chain-aware release pipeline.

## The single architectural idea

One sentence explains the shape of almost everything below:

> **One enforced core, many thin transports.**

Content is plain Markdown with YAML-ish front matter. The HTTP processor, WebDAV,
the MCP connector, the control API (and the proposed Gopher/Gemini servers) are all
**thin front-ends that translate a protocol into calls on the same shared action
handlers**. Every rule - capability checks, per-file ACLs, the deny-list, path
sanitisation, audit logging, cache invalidation - lives once, server-side, in that
core. A new access surface adds *no authority of its own*; it inherits correctness
for free. This is why the MCP connector's first version was ~300 lines, and why a
lock taken over WebDAV blocks a save in the manager UI, an ACL set in the UI gates
an MCP write, and every material change across all four doors lands in one audit
log tagged with its origin.

A second through-line: **publishing by AI partners is a first-class use case.** Many
features were driven by, and validated against, real Claude.ai and ChatGPT
connector sessions building real sites.

## Design constraints

- **Near-core Perl, minimal CPAN.** The processor runs on Text::MultiMarkdown +
  Template Toolkit + LWP + JSON::PP + Digest::SHA, all packaged by Debian. The only
  non-core *hard* extra is `Archive::Zip` (theme/zip handling); `DB_File` (rate
  limiting) and `Template::Plugin::JSON::Escape` (search index) are the other
  notable ones. The page processor (`lazysite-processor.pl`) is deliberately
  **self-contained** - it takes no project modules on its render path so it can be
  deployed as a single file.
- **Run-in-place or packaged.** The same code runs straight from a git checkout via
  the dev server, or installs into `cgi-bin/` + docroot via a manifest-driven,
  upgrade-aware installer.
- **Fail-closed on secrets, fail-open on availability.** Crypto/CSPRNG paths die
  rather than weaken; read-only settings consumers (is-this-account-disabled, rate
  stores) fail open so a corrupt file can't lock the operator out.

---

# Part I - The content model and processor

The processor (`lazysite-processor.pl`) is the heart: a single CGI that maps a URL
to a `.md`/`.url`/cached `.html` under the docroot, applies access control, renders,
caches, and emits the response.

## The request lifecycle

On each request the processor: localises `%ENV` (so per-request state can't leak
under a persistent interpreter); resolves the URL; denies the `lazysite/` system
directory outright; runs the **trust gate** (below); checks the manager-path gate;
sanitises the URI against traversal; runs the auth check, then the payment check,
then a preview-cookie check; serves from cache on the fast path; otherwise renders
the source. Managers bypass the cache so the injected admin bar is never baked into
anonymous HTML.

## Authoring: front matter

Front matter is the block between a leading `---` and the next `---`, parsed by a
deliberately minimal hand-rolled YAML-subset parser (zero non-core dependency, and
every value passes through a Template-Toolkit-directive stripper for safety). One
level of matching surrounding quotes is removed (`title: "Welcome"` → `Welcome`,
YAML semantics). Recognised keys:

| Key | Effect |
|---|---|
| `title`, `subtitle` | Page title/subtitle → `<title>`, `<h1>`, meta description, TT vars |
| `ttl` | Per-page cache lifetime in seconds; emits `Cache-Control: public, max-age=N` |
| `register` | List of registries this page joins (sitemap.xml, llms.txt, feeds, custom) |
| `tags` | Page tags, surfaced in `scan:`/registry objects |
| `date` | `YYYY-MM-DD` publication date for feeds and `scan:` sort (mtime fallback) |
| `tt_page_var` | Page-scoped Template-Toolkit variables (literal / `url:` / `scan:` / `${ENV}`) |
| `layout`, `theme` | Per-page layout/theme override (name or remote URL) |
| `raw` | Run the Markdown pipeline but emit **no layout wrapper** (default `text/plain`) |
| `api` | Body is **pure TT, no Markdown, no layout** - for clean JSON endpoints |
| `content_type` | Explicit `Content-type` header (with `raw`/`api`) |
| `query_params` | Allowlist of URL query params exposed as `[% query.x %]`; bypasses cache |
| `auth` | `required` / `optional` / `none` |
| `auth_groups` | Required group membership (also doubles as payment bypass groups) |
| `payment` + `payment_*` | x402 payment gating and its parameters |
| `search` | Include in the search index (defaults to the site `search_default`) |
| `form` | Names and enables a form on the page (must match `forms/NAME.conf`) |
| `aliases` | YAML list of old/alternate site-local URLs the page also answers to (301 → canonical) |
| `aliases_temp` | Same list syntax, but the redirect is a temporary 302 (SM134 follow-ups) |
| `nocache` | `true` renders the page fresh on every request, never served from or written to cache |

A single-pass memoised "peek" reads the front matter **once per request** (keyed by
`path:mtime`) - historically the same file was opened five times.

## Authoring: the Markdown pipeline and fenced constructs

Custom fenced blocks are expanded to HTML *before* Text::MultiMarkdown runs, in a
fixed order: forms → `:::` divs → includes → code fences → oEmbed → MultiMarkdown →
Template Toolkit + layout → link fix-ups. Inline `<script>` blocks are protected
from the Markdown engine and restored afterward, and spurious `<p>` wrappers that
MultiMarkdown puts around top-level block HTML (`<p><section>…`) are stripped.

- **`::: classname` boxes** → `<div class="classname">…</div>`. Class names are
  allow-list-validated; the box body is itself run through Markdown so headings and
  lists inside a box render properly. The default layout's CSS provides `widebox`,
  `textbox`, `marginbox`, `examplebox`.
- **`::: include`** pulls another local file or remote URL inline, with extension-
  aware handling (`.md` → recursively rendered, code files → syntax-fenced, others →
  escaped). A `ttl=N` modifier lets a remote include drive page cache lifetime, and
  TT-variable source paths are resolved in a second pass. No recursion (loop-safe).
- **` ```lang ` code fences** → escaped `<pre><code class="language-LANG">`.
- **`::: oembed`** embeds YouTube/Vimeo/PeerTube/Twitter/SoundCloud (with endpoint
  autodiscovery) and **bakes the result into the cached page** - no client-side API
  calls.
- **`::: form`** renders an accessible HTML form from a compact `name | label | rules`
  grammar. Field types: text, `email`, `tel`, `date`, `time`, `number` (with
  `min`/`max`), `url`, `password`, `textarea`, and `select:a,b,c` (multi-word options
  supported); plus `required`/`optional`, `max:N`, `pattern:"…"`, `placeholder:"…"`.
  Each form carries an HMAC time-token, a honeypot field, and an inline `fetch`-based
  submit handler that swaps to a success message - wired to a delivery handler (see
  Forms).

## Layouts and themes (decision D013)

Layouts and themes are split. A layout (`lazysite/layouts/NAME/layout.tt`) is the
structural HTML/Template-Toolkit skeleton; themes nest beneath it
(`layouts/NAME/themes/THEME/`) and supply CSS custom properties generated from
`theme.json` into a `:root { --theme-… }` block. A theme declares which layouts it is
compatible with and is **ignored (with a warning) against an incompatible layout**  - 
a broken theme is cosmetic, a broken layout breaks every page, so they are governed
by separate capabilities. Layouts and themes can be local or fetched from a remote
URL (cached, sandboxed, assets bundled). If no layout is installed at all, an
**embedded fallback layout** renders a complete, self-styled page - the site always
renders. The manager has its own dedicated, non-themeable layout.

## Generated outputs: registries, scan, search

Pages opt into **registries** via `register:`; each registry is a Template-Toolkit
template (`templates/registries/NAME.tt`) rendered to an output file  - 
`sitemap.xml`, `llms.txt`, `feed.rss`, `feed.atom`, or any custom one you drop in. A
recursive page scan collects registered pages; regeneration is TTL-gated (4h) and
only happens on a real render. The **`scan:` directive** turns
`scan:/path/**/*.md filter=… sort=…` into an array of page objects (url, title,
date, tags, excerpt, searchable) usable in any template - the basis for blog
indexes, card grids, and the search index.

## Remote content and dynamic data

A `.url` file contains a single URL; the processor fetches it, renders the remote
body through the full pipeline, and caches it - with a TTL so the refetch happens on
the *next* request after expiry, never blocking the current visitor. Site variables
in `lazysite.conf` can likewise be `url:` (fetched JSON usable via TT) or `scan:`
(directory scans). Allow-listed CGI environment variables interpolate into config
(`${SERVER_NAME}` etc.; the untrusted `HTTP_HOST` is deliberately excluded). Query
parameters declared by a page are exposed as `[% query.x %]` and make that response
uncacheable. The visitor's own IP is available as `[% client_ip %]` - the first hop
of `X-Forwarded-For` (the real client behind a reverse proxy) if present, else the
direct peer `REMOTE_ADDR`, sanitised to IP characters; because it is per-request it
is used on a `nocache: true` page (or a small `nocache` JSON endpoint fetched by
client-side script so the display page stays cached) (SM135).

## Caching

Rendered HTML is cached as a sibling `.html`, served when newer than its source (or
within a page `ttl`). Writes are **atomic** (temp-then-rename), **refuse zero-byte
output** (an empty cache file would permanently shadow regeneration), and are
**realpath-guarded** against symlink escapes. A separate content-type cache
preserves custom headers across cache hits, and Template Toolkit keeps an on-disk
compiled-template cache - an unwritable compile cache cannot break rendering: the
render retries once without it, a failed manager-layout render shows a loud error
banner naming the TT error (public pages keep the silent fallback chrome), and
`lazysite-check` probes `cache/tt` writability (`--fix` clears the tree - it is a
pure cache). The whole cache base can be relocated off the docroot via
`LAZYSITE_CACHE_DIR` (used by the dev server's browse mode so it writes nothing into
a tree it is merely viewing). `LAZYSITE_NOCACHE=1` forces a one-off uncached render.

Cache is bypassed for: `nocache: true` pages (rendered fresh every request, for
genuinely per-request content such as `[% client_ip %]`), query-param requests,
auth/payment-protected pages, and previews. **Alias redirects** are resolved on the
no-source-found path only, so a cached real page always takes precedence over an
alias (`aliases:` for 301s, `aliases_temp:` for 302s - SM134 + follow-ups).

## Render-time security

- **Path traversal**: URI sanitisation rejects null bytes, `..`, and dangerous
  characters; every read and write realpath-checks that the target stays inside the
  docroot.
- **No directory listing**: a directory resolves only if it contains `index.md`,
  else 404 - there is no autoindex anywhere in the processor.
- **System-dir & sidecar deny**: `/lazysite/*` → 403; `*.brief` authoring sidecars →
  404 (and excluded from scans/registries).
- **Template-injection defence**: front-matter values and resolved variables are
  stripped of `[%`/`%]`; every Template instance runs with `EVAL_PERL => 0`.
- **SSRF defence**: every outbound fetch (remote pages, includes, oEmbed, `url:`
  vars, remote layouts) is screened against loopback/private/link-local/metadata
  addresses before any network I/O.
- **Header spoof defence (the trust gate)**: the processor deletes client-supplied
  `X-Remote-*`/`X-Payment-*` headers unless a trusted source set them (see Auth).
- **Baseline response headers**: `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`,
  and `Vary: Cookie`; protected pages are `no-store, private` and never cached.

---

# Part II - Authentication and identity

Authentication is provided by a thin wrapper CGI (`lazysite-auth.pl`) that sits in
front of the processor and manager: Apache routes everything through it
(`FallbackResource`), it validates a signed cookie, sets the trusted `X-Remote-*`
headers, then `exec`s the real target. The processor itself contains no auth code  - 
it only consumes the header contract.

## The session model

- **Signed cookies, no server-side session store on the request path.** The
  cookie carries an HMAC-signed `username:timestamp:sid:groups` payload - a
  stateless, tamper-evident session token with a short random session id
  (legacy 3-field cookies remain valid until natural expiry), `HttpOnly;
  SameSite=Lax`, `Secure` under HTTPS, 24-hour expiry, compared constant-time.
- **Sessions are visible and revocable** (SM141). Login appends one line (sid,
  user, time, IP, sanitised UA) to `lazysite/auth/sessions.jsonl` (24-hour
  self-pruning, loss-tolerant - a registry failure never blocks login), and
  cookie verification checks `lazysite/auth/revoked.json` (revoked sids +
  per-user `not_before`, which also kills pre-sid legacy cookies; an absent
  file costs one stat, a corrupt file fails open with a loud warning, never a
  lockout). The manager **Sessions** page lists live sessions and offers
  per-session Sign out and per-user Sign out everywhere; rotating the HMAC
  secret stays as the everyone-at-once lever.
- **Trusted headers + the trust gate.** Identity reaches the processor only as
  `X-Remote-User`/`-Groups`/`-Name`/`-Email` (names configurable). These are trusted
  *only* when a trusted source set them: the wrapper sets a one-shot trust signal
  after validating the cookie, and the processor's trust gate strips the headers
  otherwise. This two-signal model lets the built-in auth and an external auth proxy
  (Authentik/Authelia) share one header contract while staying spoof-proof; the edge
  web server is also expected to `RequestHeader unset` them (defence in depth).
- **CSRF.** Manager writes require an HMAC-over-(user, hour-bucket) token, accepted
  via header, JSON body, or query param, with a one-hour grace. The gate is keyed on
  **HTTP method** (every POST is a write) rather than an action allowlist, so a new
  write action can't be left unprotected. Static-token (API) clients are *exempt*
  (no cookie ⇒ no ambient authority ⇒ no CSRF vector), and combining cookie + token
  auth is refused so the exemption can't ride a browser session.

## Credentials

- **Store.** Flat files: `auth/users` (`username:hash`), `auth/groups`, and
  `auth/user-settings.json` (capabilities, expiry, TOTP, provenance). Editable by
  hand, the manager Users page, or `tools/lazysite-users.pl`.
- **Password hashing.** Salted iterated SHA-256 (100 000 iterations), constant-time
  verify, with transparent auto-rehash of any legacy unsalted hash on next login.
- **Machine tokens.** High-entropy `lzs_` bearer tokens (256-bit) used as the
  WebDAV/API/MCP password; stored hashed (single iteration suffices for a random
  secret, and avoids a 100k-iteration KDF on *every* WebDAV request), shown once,
  with a 24-hour default expiry.
- **Single-use secrets.** Setup/reset **claim** links and partner **pairing keys**
  are single-use, short-lived, hashed, and redeemed under a lock (no replay/races).
  The credential *holder* sets their own secret - the operator never sees it.
- **MFA (TOTP).** Optional RFC 6238 second factor (self-contained, no CPAN) plus
  recovery codes, with a replay-aware verification window.
- **Forgot-password.** Emails a setup link (gated on the SMTP plugin), always
  returning a generic response - no account/email enumeration.
- **Sub-user delegation.** A partner holding `create_sub_users` can mint scoped
  sub-accounts; onward delegation requires holding the capability itself (no
  escalation).

Every gate runs *after* credential verification, so disabled/expired/MFA states
never act as an oracle for valid usernames or passwords. All randomness is CSPRNG
(`/dev/urandom`) and **fails closed**.

## OAuth 2.1 - the AI web path

Claude.ai's **web** connectors are OAuth-only (no static-bearer field), so
`lazysite-oauth.pl` + `Lazysite::Auth::OAuth` implement a minimal OAuth 2.1
authorization server: RFC 9728 + RFC 8414 discovery metadata, RFC 7591 dynamic
client registration, mandatory PKCE (S256), and access/refresh tokens. The consent
model reuses lazysite's one-time-code pattern: the operator mints a single-use
**connect code** from the Users page, the human pastes it at the consent screen to
prove they may act as that partner, and the issued token resolves to **the same
partner grant** (capabilities + ACLs) as a static bearer would. No secret is ever
typed into the third party. Tokens are stored hashed, short-lived, and
garbage-collected; the MCP server accepts either an OAuth access token or a
`partner:lzs_` static bearer and converges both on one enforcement path.

---

# Part III - Authorization: capabilities, ACLs, and the deny-list

Authorization is two layers - coarse per-actor **capabilities** and fine per-object
**ACLs** - both enforced in the shared core, plus a hard **deny-list**.

## Capabilities

Channel x action grants carried by **groups** (`groups-settings.json`, edited on
the manager Groups page); an account's rights are the union across its groups
(SM095, see `docs/adr/0003`). There are no per-account grants and no
inheritance - every grant is explicit. All four surfaces (manager UI, control
API, MCP, WebDAV) resolve through the one resolver
(`Lazysite::Auth::Settings::caps_for`); `whoami` reports the caller's full
effective set.

**Channels** (where you may operate):

| Capability | Gates |
|---|---|
| `ui` | The manager UI: login landing, the `/manager` gate, operator pages |
| `webdav` | The WebDAV publishing endpoint |
| `api` | The token control API |
| `mcp` | The MCP connector |

**Actions** (what you may do - you need a channel AND the action):

| Capability | Gates |
|---|---|
| `manage_content` | Content read/write (pages, assets) |
| `manage_nav` | Navigation read/save |
| `manage_forms` | Form configs and bindings |
| `manage_themes` | Theme activation and authoring under `lazysite/layouts/**` |
| `manage_layouts` | Layout activation and structure authoring |
| `manage_config` | `config-set`; site configuration + plugin registry |
| `manage_users` | User/group administration; the unrestricted operator bypass |
| `analytics` | Visitor-stats analysis (`analyse_visitors`) |
| `audit` | The audit trail (its own capability, split from analytics) |
| `notifications` | The manager notices bell - operator notifications such as form submissions and requests awaiting a response (SM136; seeded on `user-managers`) |
| `create_sub_users` / `delegate_sub_user_creation` | Sub-account creation and onward delegation |

The per-account `ui` flag in `user-settings.json` survives only as the
human-vs-token account type (interactive login on/off), not as a capability.

Each MCP tool and control-API action declares its required capability; a token
client is confined to the control-API subset regardless of the cookie-manager
surface, and unknown actions are refused.

## Per-file ACLs

A central store (`lazysite/auth/acls.json`) optionally maps a docroot-relative path
to `{ owner, read:[…], write:[…] }`. The model: **no entry means allowed** (the
account's namespace scope governs), the owner is always allowed, and list entries
may be a username or `@group`. ACLs only ever *narrow* access. They bind identically
across WebDAV, the manager, and MCP via one shared check. Crucially, the **two auth
domains** differ: a cookie **operator** inside the manager bypasses ACLs (edits
anything), but a **token/WebDAV/MCP partner is never an operator** and is bound by
per-file ownership exactly like any external author - the linchpin that stops
external partners escalating. `@group` entries match a cookie user's groups; a token
client carries none, so `@group` never matches it (the safe default).

## The deny-list

A hard, exact-path deny set is never readable or writable through the content
tools: the HMAC secret, the user/group/settings files, and **any `*.pl` script**.
A config-driven layer adds blocked directories and extensions. The WebDAV
authoriser denies the whole `lazysite/` subtree **except** three gated carve-outs:
`nav.conf` (with `manage_config`), per-form `lazysite/forms/<name>.conf` (with
`manage_config`, but never `smtp.conf`/`handlers.conf` which hold credentials), and
theme/layout authoring under `lazysite/layouts/**` (with the theme/layout
capabilities). `lazysite.conf` itself is never WebDAV-writable. The blocklist
applies on **reads too**, so script source can't be fetched. Failures return a
machine-readable `kind`: `blocked`, `blocked-config`, `not-found`, `permission`,
`binary`, `too-large`, `invalid-path`, or `exists`.

## Audit trail

A single append-only writer (`Lazysite::Audit`) records **material events only**  - 
state changes and security grants, never browsing - to `lazysite/logs/audit.log`,
used by every state-changing entry point. Each line is `ts | user | action | target
| ip | status | origin [| detail]`; `origin` distinguishes `ui` (cookie), `api`
(token), `dav`, and `mcp`; `save` is recorded as `create` or `edit`; failures record
the reason. This is deliberately **non-overlapping with the access log** - it
answers *who changed what, to what, when, from where, and the outcome*. The manager
audit viewer paginates (50/page), filters by user and by target (one file's
history), links a page target to its editor, and shows the failure reason on failed
events.

---

# Part IV - Payment (x402)

A page marked `payment: required` is gated behind the **x402** HTTP payment
protocol. Verification follows the same trusted-header pattern as auth: an upstream
payment proxy sets `X-Payment-Verified: 1` (stripped by the same trust gate unless
trusted). Unpaid requests get `402 Payment Required` with an `X-Payment-Response`
JSON header describing the terms (amount converted to the asset's smallest unit,
USDC on Base by default), rendering a custom `402.md` if present. Authenticated
members of a page's `auth_groups` bypass payment entirely - membership substitutes
for per-article payment, reusing the auth-group machinery. A working demo ships
(`payment-demo.pl`).

---

# Part V - Publishing and management surfaces

The manager UI, control API, WebDAV, and MCP connector are four front-ends over the
same action handlers (`lib/Lazysite/Manager/*`), the same lock store, the same ACL
store, and the same audit log.

## The manager UI

A set of ordinary lazysite pages under a dedicated manager theme, calling the
control API over `fetch`. Access requires authentication plus the `ui`
capability granted through a group (SM138: the legacy `manager_groups` conf key
is retired - migrated groups received their capabilities explicitly). The pages:

- **Config** - schema-driven site settings (driven by the processor's own
  `--describe` descriptor), active layout/theme dropdowns, and a plugin registry
  (tick to enable/disable discovered plugins).
- **Files** - a browser over the docroot with per-row metadata, create/upload/delete,
  a type filter, bulk select with zip download and bulk delete, an inline
  **permissions editor** (owner select + per-principal r/w chips drawn from a
  user/group picker), lock glyphs, and `.brief` sidecar controls.
- **Editor** - front-matter form + raw-YAML toggle + body editor + live preview,
  with a **collaborative edit lock** (auto-renewing, 5-minute timeout), **stale-lock
  take-over** (which refuses to clear a live WebDAV lock), and **mtime conflict
  detection**.
- **Nav editor** - drag-and-drop reorder, indent/outdent nesting, link-vs-heading
  toggle; saving rebuilds the all-pages cache (nav is on every page).
- **Plugins** - per-plugin config forms (password fields never returned), action
  buttons, and the **form handlers** + **form targets** UI.
- **Themes** - installed-themes panel (activate/deactivate/rename/delete),
  **preview** any theme in your session via a signed cookie, **upload** a theme zip,
  and **install from GitHub Releases** of the configured layouts repo.
- **Users** - add/remove/rename, set/clear passwords, group membership, a
  read-only **capability grid** (channel x action, derived from groups; edited
  on the Groups page), **2FA**, **Generate credential** (a one-shot `lzs_`
  token), WebDAV scope, and the **AI partner onboarding** flows (connect code
  for the web OAuth flow; pairing-key brief for Claude Code / scripts), plus
  account disable/enable/reassign. Sub-user management is scoped to the
  actor's own subtree.
- **Groups** - the capability editor: each group carries its channel + action
  grants and a description; members inherit the union.
- **Sessions** - the live-session list (SM141): user, signed in, IP, device,
  a "this session" marker; per-session **Sign out** and per-user **Sign out
  everywhere**, plus secret rotation as the everyone-at-once option.
- **Cache** - list cached pages (with orphan badges), invalidate one or all.
- **Stats** - the visitor-statistics dashboard, reading lazysite's own
  first-party access log as the primary source (SM140; the server log is the
  fallback tier), plus the bad-URL blocker's blocked-IP list with unblock.
- **Audit** - the paginated, filterable audit viewer, timestamps in the viewer's
  local timezone.
- **Backups** - typed sections (Content / Full-system); create/download, with
  content restore in-app and full-system restore via the CLI.

**Recent-change markers** (SM103): the Files and Users pages show a small dot on a
row changed within the last day (a `recent-changes` action reads the audit-log
tail), with a when / who / what tooltip. When the manager is enabled, the processor
injects a compact **admin bar** on site pages for managers (Manage, Edit-this-page,
Sign out, a no-password warning).

## The control API

A single CGI (`lazysite-manager-api.pl`), action by `?action=`, JSON responses. Two
mutually exclusive auth shapes (cookie/manager via the wrapper, or
`Authorization: Basic user:lzs_token`); the method-keyed CSRF gate; per-token
capability gating; and a per-token rate limit (token-bucket, burst 200 / refill
20·s⁻¹, HTTP 429 + `Retry-After`). The verbs cover file CRUD + lock/preview/upload/
download/zip, ACL get/set/remove, cache list/invalidate, allow-listed `config-set`,
the full theme/layout management set, artifact manifest/validate, users/principals
(proxied to the users tool), plugins/handlers/form-targets, nav read/save, backups,
SM071 preview grant/clear, `whoami`, `version`, `audit`, the session controls
(`sessions-list` / `session-revoke` / `user-revoke`, `manage_users`-gated and
not reachable by token clients), and `rotate-auth-secret` (the mass-logout
lever - rewrites the install HMAC secret, invalidating every session at once).

## File operations, locking, ACLs

The shared `Manager::Files` handlers underpin every surface: `list` (with size,
type, lock, ACL, and sidecar flags), `read` (refuses binary), `save` (lock + mtime-
conflict + ACL checks, cache + registry invalidation; a `nav.conf` save clears all
HTML), `delete` (no recursive delete), `mkdir`, and `move` (which carries the
`.brief` sidecar + generated `.html` and **re-keys the ACL**). A single lock store
(`manager/locks/`) is shared with WebDAV - a manager save respects a live WebDAV
lock and vice-versa - and theme/layout activation takes an artifact-level lock
across validate→snapshot→flip. Two more (SM096): `copy` **duplicates** a page (and
its `.brief`, the copy owned by its creator), and `migrate-to-local` turns a `.url`
remote page into a local `.md` by fetching the body through the shared,
SSRF-guarded `Lazysite::Fetch`. Saving or deleting a page maintains its
alias-redirect entries (`aliases:` 301 / `aliases_temp:` 302, SM134 + follow-ups),
and so do `move`, `copy`, migrate-to-local and WebDAV MOVE/COPY - a rename re-keys
the map without waiting for the next save. The Files page shows the current map in
a read-only Aliases card (alias → target with a 301/302 badge), backed by the
`aliases-list` read action (token clients: `manage_content`).

## Themes and layouts management

Activation is a careful, reversible operation: take a lock, **validate** the
candidate (theme.json present + non-empty compatible `layouts[]`; layout.tt
compiles), optional **optimistic-concurrency** check against a content-hash digest,
**snapshot** the outgoing version (with retention pruning), flip the pointer,
**invalidate only generated HTML**, and **mirror theme assets** to the public path.
Layout activation additionally enforces a compatible (layout, theme) pair. Themes
can be deleted/renamed/uploaded (zip, with zip-slip protection and strict
`theme.json` validation), or installed from **GitHub Releases** of a configurable
`layouts_repo` (with a lazy per-release content preview). The content-hash
**manifest** doubles as the optimistic-concurrency token and a drift detector.

## Plugins and form handlers

Plugins are discovered by probing scripts that answer `--describe` (a JSON
descriptor of config schema, actions, and provided capabilities), enabled via the
`plugins:` config block, configured through generated forms (password fields never
returned on read), and invoked via action buttons. **Form handlers** (`handlers.conf`)
define named delivery targets - `smtp` (envelope here, connection in `smtp.conf`,
delivered by `plugins/form-smtp.pl`), `file`, or `webhook` (JSON or Slack format)  - 
and a form is wired to one or more handlers by its `<form>.conf`. The credentials
and destinations live in operator-only config; an agent can *reference* a handler
but never see or set a destination.

## Notifications

Operator notifications (SM136) ride a shared write path (`Lazysite::Notify`):
every notice is appended to the manager bell store and - when the **notify-xmpp**
plugin is enabled - also delivered over **XMPP**, with one client config per site
like SMTP (sender JID + password + a recipient JID, an individual or a group-chat
room; best-effort and time-boxed, so delivery can never block or fail the
triggering action). The manager-header **bell** is gated by the `notifications`
capability (seeded on the `user-managers` group): the notices actions refuse
without it and the bell hides itself; it renders greyscale when nothing is unread
and coloured with an unread badge otherwise. Notices cover the
human-awaiting-a-response events: form submissions, a password-reset request when
no SMTP is configured (previously a silent dead-end), and agent feedback
submissions.

## Visitor analytics

**First-party analytics** (SM140): lazysite records its own traffic, so visitor
statistics work out of the box - no web-server log access, no ACLs, no vhost
changes, and no nginx-in-front-of-Apache undercount. The processor appends one
compact JSON line per request to `lazysite/logs/access-YYYYMMDD.jsonl`,
**anonymised at write**: a daily-salted visitor key, never the IP;
attacker-controlled fields sanitised against log injection; O_APPEND-atomic
appends; daily files pruned by retention (default 90 days); `first_party: off`
in `stats.conf` disables. The manager **Stats** page reads this log as the
primary source, and the AI analytics export (`analyse_visitors`, gated by the
`analytics` capability) ingests the same log - the tool never sees raw log
lines. The server-log parser remains the second tier - fallback and operator
diagnostics/enrichment - with a `source` field saying which tier answered, and
an existing-but-unreadable server log reported as exactly that rather than
"not found".

## Backups and overlay install

The manager Backups page (and the installer) take `tar.gz` snapshots of served
content (excluding the infra dir) tagged `preinstall` vs `manual`, with strict
name validation on download. This is the safety net for the **non-destructive
overlay install**: lazysite can be laid over a live HTML/SSI site without losing
content - the processor serves existing `.html`/`.shtml` directly and only renders a
`<page>.md` when present, so migration is page-by-page, and the one dangerous delete
(a shadowing `index.html`) fires only when it was the regenerable cache of a
pre-existing `index.md`.

The Backups page is organised into typed sections: **Content** (create / list /
in-app restore / download) and **Full-system**, plus a pointer to the Appearance
page for theme/layout version snapshots. A **full-system** backup captures the whole
site *including* the `lazysite/` infra (config, auth, forms, nav, themes/layouts) -
only the backups dir and regenerable caches are excluded. Because it carries the
auth secrets, in-app restore refuses a full backup; a system user restores it with
`install.pl --restore-full <file> --docroot X [--domain Y]`, where `--domain`
rewrites the site domain on restore - the **cross-domain migration** path (build on
a temporary domain, then move content, config and accounts to the final one).

## Content history (git, SM085)

Opt-in per-file version history for the site content. Enabling it (conf key
`git_history: enabled` + the Enable button on the Backups page, or the `git-init`
control-API action, gated on `manage_config`) puts the docroot under git: the
repository lives at `lazysite/git/` (inside the never-served infra tree - no `.git`
under the docroot for a web server to leak) with the docroot as the work tree, and
the enabling act takes an **adoption commit** of the current site. From then on
every content write - manager save/delete/move/copy/migrate, upload, WebDAV
PUT/DELETE/MOVE/COPY, MCP writes (they route through the same handlers), nav and
site-config saves, and a content-backup restore - is an automatic commit with the
acting user as author (`user <user@lazysite>`) and the action as message ("edit
about.md", "move a.md -> b.md"); a batched operation is one commit. A git failure
never breaks the write (WARN + proceed), and a host without git degrades cleanly.

What is versioned: the content tree plus the two operator-authored config files
(`lazysite/lazysite.conf`, `lazysite/nav.conf`). Never versioned (written to
`GIT_DIR/info/exclude` at init): `lazysite/auth/`, `lazysite/forms/`,
`notify-xmpp.conf`, cache/logs/backups/locks, the repo itself, generated `*.html`
and `lazysite-assets/` mirrors - the exclude list is the security boundary that
makes the history safe to sync to a private remote later (the git-sync plugin
follow-up builds on the same `Lazysite::Git` core). `lazysite-check` probes the
repo permissions and FAILs if `lazysite/auth` is not excluded.

Each file row on the Files page gains a **History** panel: the commit list (when /
who / what), a read-only **View** of any version, a unified **Diff** against the
current file, and **Restore** - which writes the old content back *through the
normal save path* (cache invalidation incl. host copies, alias reindexing, audit),
so the restore is itself the newest version and nothing is ever lost. Reads are
`git-history` / `git-show` / `git-status` (token: `manage_content`, audit-skipped);
`git-restore` shares the content grant and is audited. Full-system backups remain
the DR mechanism - they carry exactly what the history deliberately excludes.

**Remote sync (the git-sync plugin, opt-in).** With content history enabled, the
`git-sync` plugin syncs it with a private remote repository (a Forgejo/Gitea/etc.
project): configure the remote address (`https://host/path`, `git@host:path` or
`ssh://` - nothing else is accepted), branch and access token (password-typed, so
`lazysite/git-sync.conf` is 0660 and itself excluded from the versioned set) on
Plugin Config, then use the on-demand actions - **Test connection** (ls-remote:
reachable / signed-in / content-present in plain language), **Push** ("Pushed N
new changes"; refuses cleanly when the remote is ahead - never forces) and
**Pull** (a fast-forward just applies; when both sides changed, the operator sees
"These pages changed in both places: ..." and chooses **Keep mine** or **Take
theirs**, `merge -X ours/theirs` under the hood). Every apply is preceded by a
prerestore safety snapshot, invalidates the render caches (sibling `.html` +
host copies, wholesale - a pulled change can affect every page) and reindexes
aliases for the changed pages; outcomes are audited as `plugin-action git-sync
(push|pull ...)`. The https token is fed to git through a transient 0700
`GIT_ASKPASS` helper reading an environment variable - it never appears on a
command line, in the stored remote URL, in git config or in the helper file.
Operator-facing strings use no git vocabulary - changes, your copy, the remote
copy.

## Upload and download

Multipart upload (multiple files, size-capped and rate-limited *before* the body is
read, with per-file deny checks and atomic writes), streamed download (deny-checked,
`Content-Disposition: attachment`), and multi-file **zip download**. A content-type
table and an editable-text extension set decide what the editor treats as text vs a
binary download panel (`.htaccess` is intentionally binary).

---

# Part VI - WebDAV publishing

A self-contained CGI (`lazysite-dav.pl`) at `/dav`, reached directly (not through
the cookie wrapper - it does its own HTTP Basic auth), advertising **DAV class 1 +
2**. It is off by default (`webdav_enabled`), refuses Basic credentials over
plaintext unless HTTPS/loopback/explicitly allowed, authenticates against the user
DB with a per-IP failed-attempt limiter and brute-force delay, and enforces account
state, the `webdav` mechanism flag, the deny-list (on reads too), `dav_scope`, and
per-file ACLs (resolving the user's groups from the group file). It implements
`OPTIONS`/`PROPFIND` (Depth 0/1, ETags, a `lzs:sha256` live property computed only
when requested and only under layouts)/`PROPPATCH`/`GET`/`HEAD`/`PUT` (with
`If-Match`/`If-None-Match` conditionals)/`MKCOL`/`DELETE`/`COPY`/`MOVE`, and class-2
**locking** (exclusive, Depth-0, refreshable, per-user flood-guarded) on the lock
store shared with the manager. Throttled writes and locked resources always carry a
`Retry-After` (the documented retry contract). Standard clients work: `curl`,
`rclone`, davfs2, GNOME/KDE, and - because class-2 LOCK shipped from the start  - 
Windows Explorer and macOS Finder. There is no machine-account *type*; a bot is just
a user with `webdav:on, ui:off` and a scope.

---

# Part VII - The MCP AI connector

`lazysite-mcp.pl` exposes site maintenance as MCP tools an AI client can call.
Transport is **Streamable HTTP / JSON-RPC 2.0** (POST = request + JSON response; GET
→ 405; protocol `2025-11-25`); `initialize`/`tools/list` are open for discovery and
`tools/call` requires auth. It accepts the dual bearer shapes (static `partner:lzs_`
or OAuth access token), challenges unauthenticated calls with a `401` +
`WWW-Authenticate` pointing at the OAuth metadata, and **disambiguates** "sign-in
incomplete" vs "credential expired/revoked". A token client is never an operator, so
per-file ACLs bind it as over WebDAV; each tool declares a required capability;
reads are not audited, writes are recorded as material events.

The **27 tools**:

| Group | Tools |
|---|---|
| Identity | `whoami` (id, capabilities, active layout/theme, full tool manifest, auth method + expiry) |
| Read | `list_files`, `read_file`, `read_page` (parsed front matter + body), `list_pages`, `page_status` (will my edit reach visitors?), `search_files`, `preview_page` (server-side public render), `validate_page`, `audit_site`, `get_permissions`, `list_form_handlers`, `read_nav` |
| Write | `write_file` (validates on write), `create_page`, `delete_page` (removes `.brief`, reports dangling refs), `rename_page` (`update_links`), `replace_text` (no silent clobber), `copy_file`, `move_file`, `delete_file`, `set_permissions`, `bind_form`, `set_nav` |
| Site ops | `activate_theme`, `activate_layout`, `invalidate_cache` |

`validate_page` runs pre-publish checks including a **public-data warning** (Wi-Fi
passwords, postcodes, phone numbers); `audit_site` finds broken links, orphans,
missing titles, stale HTML, and duplicate blocks; `preview_page` renders fresh **as a
public visitor** so verification stays in-channel. Each tool carries MCP
`readOnlyHint`/`destructiveHint`/`openWorldHint` annotations so clients drive
per-call approval (ChatGPT Plus/Pro = read-only; Business/Enterprise get writes with
an approval card). The connector is **supervised, not autonomous**: bound by
capabilities, ACLs, the deny-list, and the client's own approval. It is walled off
by construction - form/SMTP configs, auth files, scripts, and the manager are
denied with a machine-readable `kind`; user administration, secrets, and credential
minting are **not exposed at all**. An agent can *wire* a form to a vetted handler
(`bind_form`) but never set a destination or credential.

---

# Part VIII - Forms and delivery

A `:::form` on a page (named by the `form:` front-matter key) renders to an
accessible, CSRF-token-and-honeypot-protected HTML form that submits via `fetch` to
a handler CGI and swaps to a success message. Delivery is configured by the
operator: the form's `<form>.conf` references one or more named handlers in
`handlers.conf`, each of type `smtp` (with shared connection config in `smtp.conf`  - 
sendmail or authenticated SMTP with TLS), `file` (stored submissions), or `webhook`
(custom JSON or Slack-formatted). The forms docs cover the field grammar, the
webhook JSON contract, and SMTP setup. Credentials and destinations are
operator-only and deny-listed from every publishing surface.

**SMTP credentials and validation** (SM137): the connection config carries a
**password** field - typed once into the Plugin Config form or the handler wizard,
stored in the operator-only `smtp.conf`, never shown back; `password_file:` remains
as the alternative and is used only when no password is set. A **Validate SMTP
connection** action in the wizard's connection section runs a staged check against
the SAVED settings and names the failing stage - host (DNS), port (TCP reach, with
a plain probe first so a closed port is never mistaken for TLS), TLS (STARTTLS vs
implicit vs none, suggesting the mode to try), or auth (rejected with the server
code, or no password set). It never sends an email and is time-boxed.

**Multi-step (wizard) forms** (SM098): a `--- step ---` line (optionally titled,
`--- step: Title ---`) inside a `:::form` splits it into wizard steps rendered as
`<fieldset>`s with a Back/Next nav and per-step validation (the native constraint
API before advancing). The form still posts **once** with the same token and
honeypot - the steps are client-side presentation over one submission. Progressive
enhancement: with no JavaScript every step shows and the form still submits.

---

# Part IX - Installation, deployment, and operations

## The installer

`install.sh` is a thin shim over `install.pl`, a ~960-line manifest-driven,
upgrade-aware, core-Perl installer. It reads a `release-manifest.json` (built from a
**classification** ruleset that decides where each file lands) and tracks installed
state in `lazysite/.install-state.json` (a SHA map). On upgrade, **code files are
always overwritten**, but **seed files are preserved if the operator edited them**
(detected by SHA), files dropped from the new manifest are removed if untouched, and
**a backup is taken before any change** (with configurable retention). `--dry-run`
previews the plan with zero filesystem changes; `--restore` rolls back to a backup
and invalidates the cache; runtime state (auth, logs, locks) is never touched.
Imperative post-steps create cgi-bin symlinks for plugin endpoints, mirror the
manager CSS, and seed fresh installs. Run as root, the installer also repairs
ownership - scoped to **root-owned files only**, aligned to the docroot owner and
the web-server group; it never re-owns CGI runtime files or operator content
(0.6.5/0.6.6; `lazysite-check --fix` performs the same scoped repair on a live
site).

Further flags: `--channel edge|stable` sets a site's `update_channel` (a standalone,
audited maintenance op); `--force` upgrades a `stable` site past its channel policy
for a specific out-of-channel build (audited as `upgrade-forced`); and
`--restore-full <file> [--domain NAME]` restores a full-system backup, optionally
rewriting the site domain - the cross-domain migration path.

## Packaged distribution (SM139)

Four Debian packages built from the same source (`debian/`, via
`tools/build-deb.sh`), replacing per-site sudo tarball installs:

- **`lazysite-common`** - the engine payload at `/usr/share/lazysite`, the
  **`lazysite` CLI** at `/usr/bin/lazysite`, man pages, the `lazysite@`
  FastCGI pool unit + `/etc/lazysite/pools/`, and the **site registry**
  (`/etc/lazysite/sites.d/`, one key=value file per site). Installing or
  upgrading the deb only refreshes the host payload - it never touches a
  site tree.
- **`lazysite-hestia`** - the HestiaCP integration: Apache web domain
  templates for both runtime patterns (`lazysite-cgi` and `lazysite-fcgi`)
  plus **`lazysite-hestia-domain`** (`add`/`remove`/`list`), the root-run
  panel integrator that prepares the 0551-locked domain layout as root, then
  **drops to the panel user** for `lazysite provision`, registers the site,
  and with `--fcgi` writes the pool config and enables `lazysite@<domain>` -
  one-command domain onboarding.
- **`lazysite-apache`** / **`lazysite-nginx`** - the plain-host webserver
  glue: commented vhost examples for both runtime patterns on each server
  (`vhost-cgi` = page misses through the CGI auth wrapper - Apache
  `FallbackResource`, nginx `try_files` + fcgiwrap; `vhost-fcgi` = anonymous
  pages to the per-site pool socket with the session-cookie carve-out to the
  CGI wrapper) plus **`lazysite-apache-vhost`** / **`lazysite-nginx-vhost`**
  (`add`/`remove`): root-run commands that render a domain's vhost into
  `sites-available/` - never touching site content, printing (never
  running) the enable/reload steps. Both ship
  [docs/reference/webserver-wiring.md](reference/webserver-wiring.md), the
  one wiring reference that also covers Caddy, lighttpd and the generic
  front-end contract for any other server.

The CLI enforces the load-bearing SM139 principle: **no root writes into site
trees**. `provision` and single-site `upgrade` refuse to run as root; only
`upgrade --all` may run as root, because it drops to each site's owner
(`sudo -u`) per site - ownership correct by construction, no chown-after
repair pass. Verbs: `provision`, `upgrade [--all]`, `sites`, `check`, `users`,
`dev`, `demo`, `version`. **`lazysite demo`** is the zero-argument try-it
path: it fresh-installs a scratch site (default `~/lazysite-demo`) as the
current user and serves it on the built-in dev server - no web server, no
configuration, removable with one `rm -rf`.

**Fleet channels and policy.** Each site carries `update_channel`
(`edge`/`stable`) and `update_policy` (`auto`/`manual`, default `manual`) in
`lazysite.conf`; `upgrade --all` skips `manual` sites and lets the installer's
channel gate decide `auto` sites. `--force` overrides both gates;
`--force-security` also overrides both fleet-wide but is honoured **only**
when the payload's release manifest declares `"security_critical": true`
(stamped with `build-manifest.pl --security-critical`) - the fleet answer to
"a security fix must reach every site now". `lazysite sites` lists the
registry with live channel/policy and installed versions.

## Persistent runtime: FastCGI worker pools (SM142)

The processor is **dual-mode**: invoked as plain CGI it behaves byte-identically
to before, but spawned with a FastCGI listen socket on fd 0 (the spawn-fcgi
convention; the SM139 pool unit) it services requests from a persistent accept
loop - modules compile once, per-request state resets inside the loop, and both
paths share one `handle_one_request`. Prefork is via FCGI::ProcManager
(`LAZYSITE_FCGI_WORKERS`) with worker recycling
(`LAZYSITE_FCGI_MAX_REQUESTS`, default 500); FCGI.pm is lazy-required, so the
CGI path gains no new dependency. **Measured: a cache-hit at 62.2 ms as CGI
serves in 0.4 ms pooled (147x)** - the CGI figure is almost entirely process
start, which the loop amortises away. One pool per site
(`tools/lazysite-pool.pl` binds `/run/lazysite/<site>.sock`, drops privileges,
execs the processor). The auth wrapper stays CGI (its exec design), so pooling
covers the anonymous visitor-facing hot path; see
`docs/architecture/performance.md`.

## Hestia deployment

A two-layer model: a Hestia Apache **web template** owns the vhost (survives
rebuilds), and `install.pl` owns the code/seed deploy. The vhost wires
`DirectoryIndex` → cached HTML, `FallbackResource` → the auth wrapper (not the
processor directly - that would break login), a rewrite that fronts the real cgi-bin
scripts with the wrapper, the **`RequestHeader unset X-Remote-*`/`X-Payment-*`
trust-strip**, the `/dav` ScriptAlias, a `Require all denied` on `/lazysite/`, a
`.brief` deny, and **`Options -Indexes`** (no directory listing). Since 0.7.2
the packaged flow (`lazysite-hestia` above: shipped templates +
`lazysite-hestia-domain`) is the install path -
`installers/hestia/INSTALL-RUNBOOK.md` is written around it; the hand-run
deploy/fleet-update scripts of the tarball era remain in-tree only for
existing deployments. On plain (non-panel) hosts the same two-layer model is
served by the `lazysite-apache`/`lazysite-nginx` glue packages above; for
Caddy, lighttpd or anything else,
[docs/reference/webserver-wiring.md](reference/webserver-wiring.md) states the
front-end contract with copy-paste snippets. (A Docker target is a
placeholder, not yet implemented.)

## The dev server

`tools/lazysite-server.pl` is a single-threaded HTTP host for local development. It
**defaults to no-cache** (edits show immediately), takes `--docroot`/`--port`/
`--processor`, routes auth/manager/WebDAV exactly as Apache does, forwards all
headers, and serves static files. Its **`--auto-index`** mode (SM091) turns *any*
tree of Markdown into a browsable site **writing nothing**: it generates a directory
index (folders + pages, labels from front-matter titles, README linked) for
directories lacking an `index.md`, injects a breadcrumb nav into every page, relocates
the processor cache to `/tmp`, and suppresses scaffolding seeding (also forced off by
`--no-seed`, and never done in a non-lazysite tree). It cleans up on `Ctrl-C`/kill.
Crucially, auto-index is **dev-only and off by default** - the production path never
lists a directory (processor 404 + Apache `-Indexes`), pinned by a test.

## Static site generation

`tools/build-static.sh <scheme://host> [out]` renders every page with the correct
base URL into a static tree (sources stripped from the output), suitable for GitHub
Pages, Netlify, or Cloudflare Pages.

---

# Part X - Tooling, packaging, and supply chain

- **Release manifest** (`build-manifest.pl`) - deterministic classification of every
  shipped file with SHA + size + bucket; dies on unmatched files or path collisions;
  `--check` verifies a manifest against disk.
- **SBOM** (`manifest-to-sbom.pl`) - a CycloneDX 1.6 software bill of materials with a
  component per shipped file and per curated dependency (with Debian/RHEL/Alpine
  package names and licences). The **`--strict` drift gate** scans every script for
  `use`/`require` and **fails the release** if a dependency isn't declared - so a new
  dependency can't ship unaccounted-for. The product licence is **MIT**;
  dependencies carry their own declared licences, overwhelmingly Perl-core.
- **Release pipeline** (`release.sh`) - never touches `main`: clones fresh, checks
  out a commit, runs the **full test suite**, builds the manifest, runs the strict
  SBOM gate, builds a reproducible tarball via `git archive` (man pages included
  under `man/man1/`), records a SHA sidecar, and tags + pushes `vX.Y.Z`. Tags are
  the only stable identifiers; since the 0.4.x line, `main` is unstable and
  carries unreleased work with no per-release bump commit. Builds are **`edge`**
  by default; `--final` stamps `channel: stable` into the manifest - the
  certified releases that `stable`-channel sites accept. **0.7.0 is the first
  stable release**, opening the declared five-year support period
  (`docs/POLICY.md`).
- **Debian packaging** (`tools/build-deb.sh` + `debian/`) - builds
  `lazysite-common`, `lazysite-hestia`, `lazysite-apache` and `lazysite-nginx`
  (Part IX); lintian-clean, smoke-tested from the extracted deb,
  template/packaging invariants pinned by `t/tools/30-hestia-pkg.t` and
  `t/tools/31-webserver-glue.t`.
- **Permissions doctor** (`lazysite-check.pl`) - the health/permissions checker
  (`lazysite check`): probes conf readability, cgi-bin executability, secrets
  modes (incl. the session registry/revocation files), manager layout presence,
  and group-execute traversal - all **evaluated as the CGI identity**
  (ownership+mode arithmetic, so a root run cannot pass files www-data cannot
  use); `--fix` re-runs every check afterwards and prints the **post-fix**
  report, with queued chmods on one path composing additively.
- **Versioning** (`bump-version.pl`) - promotes `NEXT_VERSION` into `VERSION` and
  advances the next, once per release.
- **User admin** (`lazysite-users.pl`) - the full credential/account/MFA/claim/
  pairing lifecycle as a CLI and a JSON `--api` (used by the manager Users page).
- **Offline bundle apply** (`lazysite-bundle-apply.pl`) - applies a network-less
  agent's single-JSON publishing bundle, deny-list-validated, dry-run by default.
- **Coverage** (`coverage.sh`) - measures the CGIs even though tests run them as
  subprocesses, enforcing declared floors: **75% statements / 62% branches**
  across the eight gated CGIs (three documented per-file branch overrides at
  60); an unmeasured gated CGI fails the gate rather than silently skipping.
- **Benchmark** (`bench.pl`) - a host-relative gate on the hot paths (render, token
  verify, password verify), failing only on a gross regression.

The test suite is large (thousands of tests across unit, integration, journey,
smoke, lint, and tools tiers) and is a release gate, alongside the `perlcritic`
(severity-3 + security) gate, the changed-code `perltidy` gate, a
`shellcheck -S error` gate, a secrets gate (every pattern self-tested against a
planted fixture), the **retired-terms lint** (a retired mechanism taught as
current anywhere in the docs fails the build), the coverage floors, and the
SBOM gate; `release.sh` refuses to run when the lint tools are absent.

---

# Part XI - The security model in one place

- **Header trust model.** The central threat is auth/payment header spoofing; the
  defence is the two-signal trust gate plus edge stripping. Headers are the universal
  contract so built-in and proxy auth interoperate without trusting the client.
- **Operator obligations (by design).** Strip client trust headers at the edge;
  grant the `ui` capability only to groups that should reach the manager (when
  NO group grants manager access at all, an unsecured/dev site treats any
  authenticated user as a manager); set a password for every
  non-localhost account (empty-password accounts work only from loopback); use
  HTTPS.
- **Two auth domains.** Cookie operators bypass ACLs inside the manager; token/
  WebDAV/MCP partners never do - they are bound by per-file ownership.
- **Secrets are operator-only on every surface.** SMTP/handler configs, the HMAC
  secret, user/group files, and all `.pl` are denied everywhere; forms can be *wired*
  but never *credentialed* by an agent.
- **No-leak invariants.** Credential check precedes all state gates; generic
  responses on forgot/claim/exchange; single-use + locked redemption; hashed-at-rest
  secrets shown once; constant-time compares throughout; atomic, zero-byte-refusing,
  symlink-guarded writes.
- **Session revocation** (SM141). The Sessions page revokes a single session
  (by sid) or all of a user's sessions (a per-user `not_before`, which also
  kills legacy pre-sid cookies); rotating the install HMAC secret remains the
  invalidate-everything-at-once lever. Enforcement is in the auth wrapper's
  cookie verification - the single enforcement point.
- **No directory listing in production**, ever (processor 404 + `Options -Indexes`),
  tested.
- **Manager access is interactive-only** (SM127). An account holding the
  group-granted `ui` capability is refused on the API and MCP transports, and a
  group may not combine `ui` with a remote (`api`/`mcp`) channel - so a leaked or
  misissued token on a manager account cannot drive the site remotely.
- **Bad-URL auto-blocker** (SM128, on by default). `Lazysite::BadUrl` counts
  scanner-probe hits (`wp-login.php`, `.env`, `.git`, `*.php` on a Markdown site, …)
  per source IP in a rolling window and blocks at a threshold (default 10 / 3600s);
  enforced in the auth wrapper (403), blocked IPs listed + unblockable on the Stats
  page, auto-blocks audited.
- **SSRF guard** (`Lazysite::Fetch`). Every outbound fetch (`.url` pages,
  migrate-to-local, remote layouts) rejects loopback, RFC1918, link-local/metadata,
  IPv6 loopback/link-local, multicast and CGNAT targets.

---

# Part XII - Why it is built this way

The recurring design principles, drawn from the feature-request record:

- **One enforced core, many thin transports.** Every front-end translates; nothing
  re-implements policy. This is the reason a third or fourth surface is cheap and
  consistent, and it is the explicit justification for the modular refactor (SM079)
  that made the MCP connector a thin layer.
- **Control by function, not account type.** There is no "bot account" - a partner
  is a user with capabilities, a scope, and ACLs. Capabilities grew from *real*
  needs (e.g. `manage_content` appeared when a partner needed themes-but-not-content).
- **Drafts, live, and backups are the same object** distinguished by a pointer - so
  "roll back a theme" is just "activate a backup", no new verbs.
- **Reference, don't read, for secrets** - agents operate on credentials they must
  never see (`bind_form`).
- **Safe by default, no mode to remember** - e.g. the overlay install narrowed a
  dangerous delete instead of adding an `--overlay` flag that could be forgotten;
  auto-index is dev-only so production can never accidentally list files.
- **The AI client is a fuzzer for the whole stack** - live partner sessions drove the
  ergonomics roadmap and surfaced latent processor bugs (block-Markdown in boxes,
  multi-word `select:`, the UTF-8 double-encode) that ordinary use had routed around.
- **Permanent decisions, not just deferrals** - the specs record *why* alternatives
  were rejected (Digest auth, `mod_dav_fs`, admin-chosen passwords, dead-property
  stores), so a future revisit must overturn a reason rather than rediscover it.

---

# Part XIII - Version history (feature timeline)

Newest first; releases are git tags.

- **Unreleased** - Session registry + revocation (SM141 phase 1): the cookie
  payload gains a session id, live sessions are listed on the new manager
  **Sessions** page, and single sessions or all of a user's sessions can be
  signed out via `lazysite/auth/revoked.json` - enforced in the auth wrapper.
- **0.7.2** (2026-07-10) - Packaged distribution (SM139): the
  `lazysite-common` + `lazysite-hestia` debs, the `lazysite` CLI
  (provision/upgrade/sites, root-refusal by design, the site registry), fleet
  `update_policy` + `--force-security` (honoured only for manifests declaring
  `security_critical`), one-command Hestia onboarding
  (`lazysite-hestia-domain`, CGI + FastCGI templates), and the hardened
  `lazysite-check` (post-fix re-report, CGI-identity evaluation).
- **0.7.1** (2026-07-10) - Persistent runtime (SM142): the dual-mode FastCGI
  accept loop - per-site worker pools, modules compile once; measured
  cache-hit 62.2 ms CGI → 0.4 ms FCGI (147x); plain CGI byte-identical.
- **0.7.0** (2026-07-10) - **First stable release**, cut on completion of the
  2026-07-10 eight-dimension review resolution: seven refusal-level code
  fixes, the RELIABILITY.md SLO/RTO/RPO declarations, the pentest-gate ADR +
  significant-change register, the five-year support period + Declaration of
  Conformity, coverage floors ratcheted to 75/62 across eight gated CGIs, and
  the retired-terms/shellcheck lint gates.
- **0.6.10** (2026-07-10) - Backlog housekeeping: thirteen shipped items closed;
  SM139 (packaged distribution) promoted to next up; SM141 (session registry +
  revocation) scoped.
- **0.6.8-0.6.9** (2026-07-10) - First-party analytics (SM140): lazysite records
  its own anonymised access log and the Stats page reads it as the primary source
  (zero web-server setup); the AI analytics export (`analyse_visitors`) ingests
  the same log; the server log stays as the fallback/diagnostics tier; unhandled
  processor errors now answer a clean 500.
- **0.6.5-0.6.7** (2026-07-09) - **Breaking:** manager access granted by groups
  only - `ui` / `manage_users` capabilities; the legacy `manager_groups` conf key
  retired with an automatic migration (SM138). Robustness round: installer
  ownership repair scoped to root-owned files (0.6.6); TT compile-cache immunity
  with a loud manager-layout failure banner and a `lazysite-check` cache/tt probe
  (0.6.7); fresh-install self-heal (`setup-manager` guarantees the admin group's
  capabilities) and manager UI field fixes (autofill, bell states).
- **0.6.2-0.6.4** (2026-07-08) - Notifications (SM136): the `notifications`
  capability, the manager bell, XMPP delivery via the notify-xmpp plugin, and
  human-event notices; SMTP password field + staged connection validation
  (SM137, Validate button placement fixed in 0.6.4).
- **0.6.1** (2026-07-07) - Multi-step (wizard) forms (SM098); full-system backup +
  cross-domain migration (`install.pl --restore-full --domain`) + a consolidated
  Backups page; page alias redirects (`aliases:`, SM134); recent-change markers on
  the Files/Users pages (SM103); the visitor's IP as `[% client_ip %]` with a
  `nocache:` flag (SM135).
- **0.6.0** (2026-07-04) - Stability milestone following the eight-dimension
  non-functional review; no code change from 0.5.41.
- **0.5.0-0.5.41** (2026-05 - 2026-07) - The 0.5.x line: WebDAV theme/layout
  authoring, group-based capabilities (SM095, channel × action), the MCP capability
  map + quickstarts (SM126), the STRIDE threat model and ADRs, the perlcritic
  severity-3 + perltidy gates, manager/remote separation (SM127), the bad-URL
  auto-blocker (SM128), migrate-to-local (SM096), and install channel controls.
  See `CHANGELOG.md` for the full per-release detail.
- **0.4.17** (2026-06-26) - Dev-server `--auto-index`: browse any tree of Markdown
  with zero writes; production never lists a directory, now test-locked.
- **0.4.16** (2026-06-25) - UTF-8 corruption fully fixed (the second encoding layer);
  `read_nav`/`set_nav` complete the page API.
- **0.4.15** - UTF-8 fix in JSON responders; front-matter quote stripping; page-aware
  MCP verbs (`create_page`/`delete_page`/`rename_page`); validate-on-write; MCP tools
  reference doc.
- **0.4.14** - Multi-word `select:` options; stale-lock take-over; file size in Files.
- **0.4.13** - Block Markdown inside `:::` boxes; `whoami` auth lifetime; audit
  targets link to the editor.
- **0.4.12** - Connector tools `preview_page`, full tool manifest in `whoami`,
  `copy_file`, `get_permissions`, `list_form_handlers`/`bind_form` (SM088); clearer
  401s + `kind`; nav-save clears all caches; audit-log usability.
- **0.4.11** - More form field types; safer connector tools (`replace_text`,
  `search_files`, `page_status`, `read_page`, `list_pages`, `validate_page` with the
  public-data warning, `audit_site`); generated-index refresh; audit pagination.
- **0.4.10** - Non-destructive overlay install; content backups + Backups page.
- **0.4.9** - Audit records material events only; `invalidate_cache`; reliability with
  slower assistants (512 KB read cap).
- **0.4.8** - Client-neutral connector (Claude.ai + ChatGPT; hints + output schemas);
  block-HTML `<p>` unwrap; `manage_content` capability.
- **0.4.7** - OAuth 2.1 authorization server for the connector.
- **0.4.6** - One-click Claude.ai setup; injection-resistant onboarding briefs.
- **0.4.5** - Users/Groups page layout fix.
- **0.4.4** - Audit WebDAV reads (quietable); MCP-vs-API onboarding docs.
- **0.4.3** - Files unified rights editor; `@group` ACLs over WebDAV; WebDAV + MCP
  writes in the audit trail (shared modules).
- **0.4.2** - Files-manager UI v2; richer audit (origin/target); Hestia `lib/` fix;
  **MCP server v1**.
- **0.4.1** - Files-manager overhaul; field-report fixes (theme-asset mirror, mixed
  form targets, audit target).
- **0.4.0** - Modular refactor (SM079) + security hardening + conformance milestone
  (perlcritic gate, SBOM gate, bench/secrets gates, `bump-version.pl`, five-audience
  docs, coverage instrumentation, fleet updater).
- **SM070–SM074** (rolled into the 0.4 line) - WebDAV publishing + per-user ACLs;
  WebDAV theme/layout management with self-service activation; self-service
  credentials + claims + TOTP + account expiry; per-file `.brief` sidecars; per-file
  ownership + ACLs.
- **0.3.0** (2026-04-23) - Release tooling split; SBOM/manifest generated per release;
  first upgrade-aware installer.
- **0.2.0–0.2.19** (2026-04) - Hardening + manager maturation: structured logging,
  the Config and Files apps, method-keyed CSRF, mass-logout, login rate limiting, the
  D013 layouts/themes reshape.
- **0.1.0** (2026-04-21) - Initial release: the Markdown→HTML processor with TT
  layouts/themes and scan/include/oembed; built-in + reverse-proxy auth; forms with
  an SMTP helper; the web manager; the x402 demo; the dev server; the test suite.

---

# Part XIV - Roadmap

**Actionable now:**

- **SM085 - Git backend / changesets** - phase 1 SHIPPED (content history + the
  git-sync remote plugin, see Part V). What remains is phase 2: the transactional
  agent-changeset workflow (begin -> diff -> commit -> rollback) on the same core.
- **SM084-restore** - the in-manager "restore this snapshot" action (list/create/
  download already ship).
- **SM075 - Wildcard multi-tenant hosting** - many ephemeral sites under one wildcard
  vhost, auto-provisioned, with promote-to-permanent.

**Candidates / research:**

- **SM086 - Pandoc-construct renderers** - datatables, charts, boxes, definition
  lists, citations rendered for the web from the same source that makes a branded PDF.
- **SM089 - 3D-rendered layout** - a WebGL layout category, proving the rendering
  substrate itself is pluggable.
- **SM090 - Social syndication / POSSE** - ActivityPub + AT Proto, lazysite as the
  canonical store (publishing-format slice first).
- **SM092 - Gopher + Gemini services** - read-only public front-ends over the same
  content tree, the natural next "thin transports."

---

*This reference was synthesised from the lazysite source, the `starter/docs/`
documentation set, the `docs/feature-requests/` record, and the CHANGELOG, at
v0.7.2 (including the unreleased SM141 session registry on `main`). For the
authoritative detail of any feature, read the cited script or doc; for the
"why", read the corresponding `SMxxx` feature-request.*
