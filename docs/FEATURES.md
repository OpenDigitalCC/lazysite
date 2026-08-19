---
title: "Lazysite - Complete Feature Reference"
subtitle: "Everything lazysite has and does, and why - as of v0.9.14"
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
trail, theming with self-service activation (including one-call theme scaffolding
and an external-design ingestion path), first-class multi-site and multilingual
content, forms with pluggable delivery, the x402 payment protocol, and a
supply-chain-aware release pipeline.

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
- **`::: qr data="…"`** renders a QR code for the given value (a link, a payment
  URL, a wifi string, …), with an optional `size="N"` in pixels. It is a built-in
  content component - available on any layout - drawn client-side from the shared,
  self-contained `/assets/qrcode.js` (bundled qrcode-generator, MIT; in the SBOM).
  The value is only ever computed into a matrix, never inserted as markup, so there
  is no injection surface. Pass the value in `data="…"` (not the fence body, which
  Markdown would reflow).

Built-in content components live under `lazysite/templates/components/` and are the
fallback for the `::: name` component syntax: a `::: name` fence resolves against the
active layout's `components/NAME.tt` first, then the built-in dir - so a layout can
override a built-in, and built-ins (like `qr`) work everywhere.

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

## Multilingual language sets (SM179)

A site can carry several **sibling per-language content roots** - one docroot
subtree per language - bound together by a shared `lang_group` (settable per site
in `lazysite.conf`, on a domain via `domain-set`, on the CLI, and on the Domains
Add + Configure forms). Each root declares its own `lang` (`en`, `fr`, `th`, …),
which the processor threads through the response: `<html lang="…">`, a
`Content-Language` header, `hreflang` alternates plus an `x-default` (emitted in
both the layout `<head>` and `sitemap.xml`), and an engine-supplied
`[% languages %]` switcher structure a layout renders into a language menu (the
current language flagged, each sibling's URL resolved). A `lang:` value is
sanitised to a bare language tag before it reaches `<html lang>` or the header - the
0.8.0 review fixed a stored-XSS / response-header-injection path where an
unsanitised front-matter `lang:` from a content-only partner reached both
unescaped.

Chrome is localised too. Layout template strings resolve through `[% t %]` (a
per-language string table), `json:` site variables resolve **content-root-first**
(so a per-language data file overrides a shared one), and the engine's own emitted
pages - the bare 404, the no-`403.md` fallback, and the auth reject pages - are
localised from a built-in English table overlaid by `lazysite/i18n/<lang>.json`
(fail-closed: a missing string falls back to English; the 404 fallback escapes the
request URI). A `lang-status` action (gated `manage_content`) reports per-language
coverage, and `whoami` / the MCP discovery surface report a configured language set
even when `lang_group` is declared only on the domain aliases. A **conf-only change
now invalidates the page cache**, so a language or chrome edit is never served
stale under any process model, and per-host caches are listed and cleared per host
on the Cache page (SM179 P8).

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
- **Script-capable `content_type` downgrade** (ADR 0006, 0.8.0): a `raw:`/`api:`
  page may not serve a script-capable type - `text/html`, XHTML or SVG is
  downgraded to `text/plain` at serve time, closing a stored-XSS path a
  content-only delegate could otherwise reach. 0.9.12 extended the same rule to the
  **write path**: the manager save and WebDAV PUT refuse such a page outright (415),
  so raw content stays themed and on the no-CDN policy rather than being caught only
  at render.
- **SSRF defence**: every outbound fetch (remote pages, includes, oEmbed, `url:`
  vars, remote layouts) is screened against loopback/private/link-local/metadata
  addresses before any network I/O.
- **Header spoof defence (the trust gate)**: the processor deletes client-supplied
  `X-Remote-*`/`X-Payment-*` headers unless a trusted source set them (see Auth).
- **Baseline response headers**: `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`,
  and `Vary: Cookie`; protected pages are `no-store, private` and never cached.

## Engine-served system pages (SM201)

The engine's own pages - login, the credential-**claim** page, and the `402`/`403`/
`404` responses - are served from a protected **`lazysite/templates/system/`** tree
rather than depending on a copy inside the served content. Each route resolves
through a **three-tier fallback**: a content-root copy (so a site or a
content-rooted sub-domain may still override the look), then a docroot-root copy,
then the protected default. A deleted or never-seeded copy therefore **self-heals**
- a missing `/claim` page no longer 404s - and `lazysite-check` verifies each route
resolves.

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
  escalation). An operator can **promote a sub-user to top level** (an
  operator-only clear of `managed_by`) and can separately set an explicit
  `scope_independent` flag that lifts the `created_by` scope ceiling; the
  provenance stamp is never rewritten (SM194). In the manager this is the
  **Content access** control - "Set by its own grants alone" - which also shows
  the chain of ancestors currently capping the account, so an operator can see
  whether the toggle would change anything (SM233).

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
| `manage_domains` | The multi-domain admin and portable site packages (split out of `manage_config`, SM160) |
| `manage_users` | User/group administration; the unrestricted operator bypass |
| `analytics` | Visitor-stats analysis (`analyse_visitors`) |
| `audit` | The audit trail (its own capability, split from analytics) |
| `notifications` | The manager notices bell - operator notifications such as form submissions and requests awaiting a response (SM136; seeded on `user-managers`) |
| `read_submissions` | Least-privilege read of stored form submissions, without the broader `manage_forms` (SM187) |
| `feedback` | Agent feedback over MCP (`submit_feedback`); off by default (0.9.0) |
| `create_sub_users` / `delegate_sub_user_creation` | Sub-account creation and onward delegation |

The per-account `ui` flag in `user-settings.json` survives only as the
human-vs-token account type (interactive login on/off), not as a capability.

Each MCP tool and control-API action declares its required capability; a token
client is confined to the control-API subset regardless of the cookie-manager
surface, and unknown actions are refused.

## Cross-plane consistency and service killswitches (0.9.0)

A surface-exposure audit across the four planes (cookie manager, control API, MCP,
WebDAV) drove two hardening changes that make authorisation uniform and explicit:

- **Cross-plane capability consistency.** The same resource was in places gated by
  different capabilities per plane. WebDAV nav/form editing now uses the
  fine-grained `manage_nav` / `manage_forms` (was `manage_config`), matching the
  API/MCP planes and the central `Capabilities` map. A drift-guard test pins the
  WebDAV `@DANGEROUS_EXT` list to its canonical source, and the capability-gate
  guarantee test fails the build if a capability-gated cookie mutator is ever left
  off the CSRF force-list (`site-backup-*` were capability-gated but not
  POST-forced - now closed). The grants resolved but not surfaced to the
  cookie-manager gate (`manage_domains` / `feedback` / `read_submissions`) all now
  take effect, pinned by a parity test.
- **Service killswitches.** Only WebDAV had the intended dual control (a conf
  killswitch plus a capability). The MCP server, OAuth server, control-API token
  path, and auth token-exchange were always-on and invisible. Each now has a conf
  killswitch (`mcp_enabled` / `oauth_enabled` / `control_api_enabled` /
  `token_exchange_enabled`), **default off**, read through one shared helper so the
  gates cannot drift, and surfaced as a toggle in the manager's **Services** section.
  A disabled surface refuses **before doing any work and discloses nothing** -
  MCP/OAuth refuse pre-auth including discovery; the control API refuses before
  verifying a token; a switched-off service answers `200 {ok:0,
  code:"service_disabled"}` rather than a misleading 404. This is the one BREAKING
  posture change of the 0.9 line: after upgrade an operator enables the surfaces it
  uses in Settings → Services; nothing is auto-migrated by design.

## Capability clarity in the manager

Several 0.9.x changes make the capability model legible rather than silent:

- **Grant-to-enable hints** (SM191): a capability-gated area a user cannot yet reach
  shows a hint telling an operator which capability to grant, rather than simply
  being absent.
- **Channel-surface ticks** (SM197): the permissions grid ticks only where a
  capability actually has a channel surface, so an impossible combination is never
  shown as available.
- **Inert-group warning** (SM198): a group carrying capabilities but no members is
  flagged as inert (it grants nothing until someone joins).
- **Dormant-capability indicators** (SM180): the Groups and Users capability grids
  flag a channel capability granted while its site service is switched off (a
  dormant grant that silently does nothing) - indicate, never block.

## Limiting who can see content

A site can restrict **a page, a file, a folder, or the whole site**, and the
restriction applies to visitors as well as to authors. The full reference,
including the resolution order and the per-channel table, is
`docs/architecture/access-control-model.md`.

There are two mechanisms, answering two questions:

Who may read a **page**
: `auth:` and `groups:` in the page's front matter, with `auth_default` in
  `lazysite.conf` as the site default.

Who may read or write a **path**
: the ACL store, `lazysite/auth/acls.json` - a file, a folder (covering
  everything beneath it), or `/` for the whole site including its assets.

**Protection is opt-in.** A file nobody has mentioned is public, and a site that
has never protected anything behaves exactly as it always did - which is what
made this safe to extend to existing sites. Note the corollary: `auth_default:
required` closes the **pages** and does not reach static files, so a wholly
private site wants a root ACL entry rather than the site default alone.

Two policies, differing in what a visitor gets:

- **Gated** - anonymous visitors are sent to sign in; the response is never
  stored by a shared cache.
- **Draft** - a 404, and absent from the sitemap, the feeds and search. Held-back
  content should not answer at guessable URLs, because a login form confirms the
  page exists.

Set it from the manager (Files -> a folder's actions, or the per-file
permissions editor), over MCP (`set_permissions`), or over the control API
(`acl-set`). One writer, so a section and a file are governed by the same store
and the same rules.

**Protected content is moved out of the document root**, into a private store
beside it, and moved back when the restriction is lifted. This is what makes the
restriction hold: there is nothing left in the served directory for a web server
to hand out, so no front-end rule is needed and none can be got wrong. A page's
notes travel with it, and any cached copy of the page is dropped.

A rule that names only who may **edit** leaves the content published - it
restricts authoring, not reading, and taking a public page offline to express
that would be the wrong answer.

The one exception is the **whole-site** rule, which cannot move anything: the
document root cannot be moved out of itself. It is enforced by the engine, and
the manager says so when you set one.

Backups include protected content, because a backup is how content is recovered.
Site packages and the content history do not - a package travels to another
organisation without the rules that govern the content, and a history can be
pushed to a remote. Both **report what they left behind** rather than leaving it
to be discovered.

**Verify it from outside**, because the front end decides whether a request ever
reaches the engine: `lazysite check --check-acl https://example.test` gates a
probe, fetches it anonymously under several file extensions, and fails if any
bytes come back. A plain `lazysite check` also fails if any protected file is
found sitting in the document root as well.

## Per-path ACLs: the model

The store maps a docroot-relative path to `{ owner, read:[…], write:[…] }`.
**No entry means allowed** (the account's namespace scope governs), the owner is
always allowed, and list entries may be a username or `@group` - matched
case-insensitively, with nested groups expanded. ACLs only ever *narrow* access,
and they bind identically across the manager, the control API, MCP and WebDAV
through one shared check, plus a module-free copy in the processor for the
public read path (ADR 0001; `t/lint/31` pins the pair).

The **two auth domains** differ in one respect: a cookie **operator** inside the
manager bypasses ACLs, but a **token/WebDAV/MCP partner is never an operator**
and is bound by per-file ownership like any external author - the linchpin that
stops external partners escalating. That bypass applies to the authoring
surfaces only, never to the anonymous read path. A partner's `@group`
memberships resolve from its account on every channel (SM288).

## The deny-list

A hard, exact-path deny set is never readable or writable through the content
tools: the HMAC secret, the user/group/settings files, and **any `*.pl` script**.
A config-driven layer adds blocked directories and extensions. The WebDAV
authoriser denies the whole `lazysite/` subtree **except** three gated carve-outs:
`nav.conf` (with `manage_nav` since 0.9.0), per-form `lazysite/forms/<name>.conf`
(with `manage_forms` since 0.9.0, but never `smtp.conf`/`handlers.conf` which hold
credentials), and
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
(token), `dav`, `mcp`, `cli` (the users tool run from the shell, attributed to the
invoking OS identity), and `install`; `save` is recorded as `create` or `edit`;
failures record the reason. One entry per operation: each web surface audits its
own requests, and the users tool audits only when NOT driven through `--api`
(where the calling surface has already recorded the actor). Shell user management
(setup-manager, add/remove/rename, credential and claim issue, group and
capability changes) is fully on the trail - secrets themselves never are. This is
deliberately **non-overlapping with the access log** - it answers *who changed
what, to what, when, from where, and the outcome*. The manager audit viewer
paginates (50/page), filters by user and by target (one file's history), links a
page target to its editor, and shows the failure reason on failed events.

The writer is failure-loud: the log is created umask-proof at `0664` (so the CLI
and the www-data CGI can always append to the same file via the setgid logs dir),
an owned file that lost its group-write bit self-heals on the next append, and a
write that still fails emits a WARN naming the lost action instead of vanishing.
The **Logging & forwarding** plugin can additionally forward each audit entry
(and, separately, application diagnostics) to syslog (`forward_audit` /
`forward_diagnostics` / `syslog_facility`) for an external collector -
best-effort, never blocking, with the on-disk log as the record.

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
  `--describe` descriptor), active layout/theme dropdowns, a plugin registry
  (tick to enable/disable discovered plugins), and - since 0.9.0 - a **Services**
  section whose toggles enable the remote surfaces (MCP / OAuth / control API /
  token exchange), each **off by default** (see Part III). The whole page now loads
  through `config-read` and saves each key through the audited, per-key `config-set`
  (SM042), retiring the legacy pseudo-plugin save path that silently dropped keys
  outside its schema - a parity guarantee test fails the build if the page's keys
  ever drift from the API's read/write sets.
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
  actor's own subtree; an operator can **promote a sub-user to top level**
  (clearing `managed_by`) and, separately, set an explicit `scope_independent`
  flag that lifts the `created_by` scope ceiling - the provenance stamp itself is
  never rewritten (SM194). A group change that would strip an account's last
  manager-access group raises a warning before it applies.
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
  content restore in-app and full-system restore via the CLI; plus a **Site
  packages** panel (list / download / upload / apply / delete) for portable
  per-domain packages (see Domains and multi-site).
- **Domains** - the multi-domain admin (gated on `manage_domains`): add / configure
  / remove the ADDITIONAL first-class domains that share the instance, each with its
  own content root, per-domain SEO and language (`lang`/`lang_group`), and access
  control; per-domain **preview** (pre-DNS, server-side render), a **Check**
  (public-IP, cert SANs, proxy-aware, SSRF-guarded), and per-domain **Export site**
  to a portable package (see Domains and multi-site). The primary/default site
  lives in Site settings; the Domains page lists only the additional domains.

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
Theme install no longer auto-activates (SM176) - installing lands the candidate,
activation stays a separate deliberate step.

The **layout catalogue** (`list_layout_catalogue` / the control-API
`layouts-manifest` action) lists every layout in the configured layouts repo,
installed or not, each with `name` / `version` / `default_theme` / `themes[]` /
`installed` and - since SM206 - a one-line `description` and optional style/audience
`tags`, so an author (or an agent) can choose a base layout by purpose without
installing and inspecting it. Absent description/tags degrade to empty, never an
error. See **Theme authoring and external-design ingestion** below for the
one-call theme scaffold, token-vocabulary discovery, and the Figma bridge that
build on this surface.

## Theme authoring and external-design ingestion (0.9.14)

Restyling a site, building a bespoke theme, or bringing a design in from an
external tool used to mean path-knowledge plus a five-step `write_file` sequence
with several documented sharp edges. 0.9.14 turns theme authoring into a first-class,
validated, discoverable workflow across the MCP connector, and adds a documented
method for ingesting an external design (Figma) with **no lazysite-side fetcher and
no stored third-party credentials**. Everything here is gated by the existing
`manage_themes` capability - no new capability, no new transport.

### The token contract, made explicit (SM203)

A layout's reference CSS consumes a small, regular set of CSS custom properties -
`var(--theme-colours-primary, …)`, `var(--theme-fonts-body, …)` and friends - which
a theme supplies through its `theme.json` `config` block (the processor turns each
`config` entry into a `--theme-GROUP-KEY` declaration in a `:root { … }` block,
stripping `;{}<>` from every value as it emits). Historically the *vocabulary* a
layout expects was discoverable only by reading an existing theme's `main.css` and
grepping for `var(--theme-`.

`layout.json` now carries an **optional, declarative `tokens` block** naming the
custom properties the layout's reference CSS consumes, grouped as the config is:

```json
"tokens": {
  "colours": ["primary", "text", "heading", "background", "border", "accent"],
  "fonts":   ["body", "heading", "code"]
}
```

It is **documentation-as-data, never enforced at render**: the `var(--theme-*,
<fallback>)` chain is unchanged, a theme may supply extra tokens or omit declared
ones, and the fallback covers any gap. A theme that mis-supplies the declared
tokens at activation logs a **non-fatal warning** (comparing declared vs supplied
sets) - the loose coupling is a designed property, so a mismatch is surfaced, never
rejected. The shipped layouts (the `lazysite-layouts` repo) carry these blocks.

### `theme_tokens` - token-vocabulary discovery (SM204)

A new MCP **read** tool (`manage_themes`, not audited) answers the first question
any restyling task asks - *what is the token vocabulary, and what do exemplar values
look like?* - in one call:

- given a **theme**, it returns that theme's parsed `config` (groups, keys, values)
  plus `name` / `version` / `layouts` from its `theme.json`;
- given a **layout** (no theme), it returns the layout's **declared** `tokens`
  block plus the layout's default theme `config` as exemplar values; if no block is
  declared it derives the vocabulary from the default theme and marks the result
  `derived: true`;
- given neither, it defaults to the active layout + active theme.

It reuses the existing theme readers and adds only the `theme.json` `config` parse
that `list_themes` does not do. It works standalone via the derived mode and is
richer once a layout declares its tokens.

### `create_theme` - one validated call to scaffold a theme (SM205)

A new MCP **write** tool (`manage_themes`, audited) collapses the whole scaffold
into a single validated call, retiring every sharp edge the old sequence carried
(nested directories, validation only at activation, assets that must live under
`assets/`). It validates **eagerly, before writing anything**:

- `name` sanitised to `[A-Za-z0-9_-]`;
- `config` values are ASCII strings free of `;{}<>` - **the same characters the
  render-time emitter strips** - so the author is told up front about a value that
  would otherwise be silently altered at render (a clarity safeguard, not a new
  security boundary - the render-time strip remains the enforcement);
- the target `layout` exists and is installed.

On failure it returns the existing `{ ok: 0, error, kind }` model with
`kind: "validation"` naming the failing rule, so an agent can fix without
re-reading docs. On success it scaffolds
`lazysite/layouts/LAYOUT/themes/NAME/` with a `theme.json` (`layouts: [LAYOUT]`,
`author` from the partner identity, default `version` `1.0.0`) and
`assets/main.css`. **When `css` is omitted it copies the layout's default theme
`main.css`** as the starting point - encoding *copy-nearest-and-adapt*: the
`config` tokens restyle the copy immediately through the `var(--theme-*)` chain,
and CSS craft can follow. An optional `activate: true` runs the existing
activate/mirror/cache-clear path. If the layout declares `tokens`, a coverage check
is returned as **warnings** (declared tokens the theme omits, with the fallback
values that will apply; supplied undeclared ones) - warn, never reject. The tool
returns created paths, warnings, and preview guidance (the source-CSS preview URL
before activation, the mirror URL after).

A folded-in fix removes the old *fix-then-must-reactivate* trap: a `theme.json`
written through the general `write_file` path now runs the **same theme validator
eagerly** and returns warnings, exactly as `write_file` already validates a page -
no need to reactivate a theme just to learn a value was rejected.

### `layout.tt` is readable text (SM202)

The binary/text decision is extension-based, and `.tt` was missing from the
editable-text allowlist, so `read_file` / the history View / WebDAV refused a
Template Toolkit `layout.tt` as binary. That blocked the sanctioned
**copy-nearest-layout-then-adapt** workflow (the active layout is write-locked, so
an author copies a sibling `layout.tt` and edits it - which requires reading it).
`.tt` is now an allowlisted text extension across all three read paths at once; a
genuine binary (`.png`, `.pdf`) is unaffected. The 23 shipped `layout.tt` files
were audited as clean UTF-8 - this was an allowlist gap, not file corruption.

### The `/docs/integrations/` namespace and the Figma helper (SM208)

A new **`/docs/integrations/`** documentation namespace (index + per-tool helper,
each registered for `llms.txt` and `sitemap.xml`, cross-linked from the
building-sites and layouts briefings and the AI-agent onboarding) documents how an
agent brings an **external source** into lazysite through the sanctioned channels.
Its first entry, **`/docs/integrations/figma`**, documents the **dual-MCP method**,
a locked design decision:

- The agent connects the **Figma MCP server** (source) and the **lazysite** MCP
  connection (destination) in one session and bridges them. Figma's
  `get_variable_defs` extracts the design's variables and styles and is **free on
  all Figma plans**, where the Variables REST API is Enterprise-gated -
  `get_metadata` / `get_screenshot` orient the work and check fidelity. There is
  therefore **no lazysite-side Figma fetcher, no stored Figma credentials, and no
  new transport** - the deliverable is documentation that makes the bridge reliable.
- The translation is deliberately **semantic, not pixel-repro** (an explicit
  anti-goal). *Identity* - palette, fonts, corner radius, content widths - transfers
  as tokens near-mechanically (role-named variables map straight onto the layout
  vocabulary via `theme_tokens`; value-named ones need a role assigned from the
  screenshots); fonts resolve to **bundled** faces, never a CDN; *rhythm and
  type-scale* are **rebuilt in authored CSS** (there are no theme slots for them by
  design); *structure* adapts the nearest layout (copy-and-stage); *content*
  becomes pages.
- Deployment points at both the MCP path
  (`create_theme` / `write_file` / `activate_theme` / `activate_layout`) and the
  WebDAV + control-API staging sequence, without duplicating the staging mechanics.

A **`build-from-figma`** recipe is registered in `describe_capabilities`, so the
method is discoverable from the connector itself.

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

**The channel (SM231).** A notice declares a **type**, and the type decides how
it is rendered and where it goes. `lazysite/notify.conf` carries two keys per
type and one global:

```
route.submission:    bell,xmpp     # which endpoints this type reaches
emit.submission:     off           # silence a type without touching its caller
base_url:            https://...   # how a link is made absolute
```

The **bell is always written and is always the record** - a route that omits it
still gets it, because a notice nothing wrote down is not a notice. Types with no
entry follow their own default, so a site that never writes this file behaves
exactly as it did before.

A **link is now delivered.** A notice has always carried a `url` and it was
stored and dropped, so an operator was told that something happened and never
where to go. The body of each notice comes from a template, per type and per
endpoint, and the built-in one renders the site name, the message and an absolute
link. Override any of them by dropping a file at
`lazysite/notify-templates/<type>.<endpoint>.tt` - full Template Toolkit, with
`message`, `type`, `target`, `url`, `site` and `base` in scope. A template that
fails to render falls back to the plain message: a bad template must not silence
an alert.

**Emission is per caller.** A form that should announce itself does; the rest stay
quiet. Set `notify: off` in a form's own `.conf` to silence that form alone, or
`emit.submission: off` in `notify.conf` to silence the type site-wide. Both
default to on. This exists because volume is real - a three-day programme of 46
form steps across 15 participants is 690 notices where five were wanted - and
because the alternative (accumulate and send a digest) needs pending state and a
timer, which lazysite deliberately does not have.

The registered types are `submission`, `feedback`, `reset-request`,
`credential-expiring`, `backup-outcome`, `audit-finding` and `service-degraded`.
The last four are a declared vocabulary with no emitter yet - the platform learns
those things and has nowhere to say them. An **unregistered** type is still
delivered, on the generic template, with a warning in the log: refusing it would
lose an event because a caller arrived before a registry entry.

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

**Durable per-day store + trends** (SM213, 0.9.16+): the aggregates are stored
long-term as one small JSON file per day under `lazysite/stats/` (outside the
clearable cache), with monthly rollups and an index - so the data is durable,
per-day addressable and downloadable, with **no cap to hit and nothing for an
operator to configure**. The export distinguishes its two horizons explicitly so
the complete aggregates are never mistaken for the bounded recent event sample:
`data_from` states how far the aggregates reach, and `sample: {from, to, count}`
states what the raw event sample covers. `analyse_visitors` gains selectors -
`index` (the days + months index), `day=YYYY-MM-DD`, `month=YYYY-MM` - and the
Stats page shows a **month-on-month** trend. The raw event ring is now just a
recent-activity sample, not a limit on analysis. Classification is **visitor-level**:
a token that probes a non-existent path is marked a `scanner` and its whole session
(including a spoofed referrer) is pulled out of the people/referrer figures, not just
the probe; 404s split into plausible missing pages (kept by path) vs a junk
scanner-chorus count.

**Visitor trails** (SM393): the aggregates above answer *how many* took each step
but cannot answer *in what order* - and order is the one fact that cannot be
recomputed later, because once the bounded event ring rolls it is gone for good.
So the ordered sequence is now recorded per visit, per day, in its own files under
`lazysite/stats/trails/YYYY-MM-DD.json`: entry page, exit page, distinct-page
depth, the per-step gap (the dwell on the page being left), and the visitor class
as it was at the time. **This reverses an earlier deliberate design choice** and is
documented as a reversal, not an addition - the sequence aggregates were built
precisely so a flow could be reconstructed without retaining anybody's path.
The limits ship with the recording rather than after it: 40 steps per visitor, 2000
visitors per day, a stated retention (`trails_retention_days`, default 30) enforced
on **every** export including the ones with nothing new to write, and `trails: off`
to disable. Crawlers never open a visit and so leave no trail at all.

**Privacy commitment.** lazysite **installs no trackers**: no analytics
JavaScript, no beacons, no analytics cookies, no fingerprinting, no third-party
requests. Analytics are derived only from data the server already receives while
serving a page, aggregated and IP-anonymised at write. The durable **day** files
hold aggregates only; the separate **trail** files above are the one per-visit
record the platform keeps, and they are pseudonymous, capped and expiring by
default rather than as an option. Visitor keys are daily-salted
so they cannot become long-term identifiers (returning-visitor signal exists only
within a salt period - the accepted cost). The scope of the assurance is precise:
lazysite ships nothing that instruments a visitor; a site owner remains free to add
their own scripts to their own pages, which lazysite cannot and does not control.

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
in-app restore / download) and **Full-system**; its intro distinguishes the roles -
backups are disaster recovery (the full-system kind includes secrets), while
day-to-day content versioning lives in the Content history plugin, and theme/layout
version snapshots are managed on the Appearance page. A **full-system** backup captures the whole
site *including* the `lazysite/` infra (config, auth, forms, nav, themes/layouts) -
only the backups dir and regenerable caches are excluded. Because it carries the
auth secrets, in-app restore refuses a full backup; a system user restores it with
`install.pl --restore-full <file> --docroot X [--domain Y]`, where `--domain`
rewrites the site domain on restore - the **cross-domain migration** path (build on
a temporary domain, then move content, config and accounts to the final one).

## Domains and multi-site (SM151 family)

One lazysite instance hosts **many first-class domains**, not one site with
subsites. The multi-site plane (SM151) gives each domain its own content root under
the docroot, with per-host confinement, per-host caching (listed and cleared per
host on the Cache page), and per-host SEO and language. A **bare docroot** with no
matching domain root is excluded rather than served (SM151 §7). Sub-domains are
first-class peers, so theme/layout delete-safety and the language machinery account
for every domain (SM177).

- **Domains admin** (SM154, gated `manage_domains` - split out of `manage_config`
  by SM160). Add / configure / remove additional domains from the manager Domains
  page or the CLI; each domain carries its content root, `lang`/`lang_group`, SEO,
  and access control. A `domain-preview` renders a domain server-side **before DNS
  points at it**, and a `domain-check` runs a **proxy-aware, SSRF-guarded** health
  probe (public-IP match, certificate SANs, a distinct verdict for a coverage gap
  vs an unreachable host); `domain-check` refuses any probe whose resolved address
  is not public (blocking loopback, RFC1918, the metadata endpoint, CGNAT, IPv6
  ULA/link-local), closing DNS-rebinding and IP-literal paths.
- **Group-level domain binding** (SM155): a group can be delegated a domain, with
  first-class **aliases** and the pre-DNS preview, so an agency team manages its own
  domains without operator involvement. The "alias" concept on Add-domain is a
  *Copy settings from* pre-fill.
- **Domain access-control model** (SM165): a domain-owned access model with per-user
  locks - who may see and edit a given domain - layered on the capability + ACL core.
- **Portable site packages** (SM158, and the migration completeness work
  SM183/SM185/SM193). A single per-domain **package** captures a domain's content
  and presentation (excluding `lazysite/` infra, secrets, and every other domain's
  content) into a portable artefact - the interface for an **agency demo → client
  hand-off**. It is symmetric across surfaces: a package built by MCP is applied by
  a human and vice versa. In the manager, Domains gains **Export site** per domain
  and Backups gains the **Site packages** panel (list / download / upload / apply /
  delete) with an apply **preview** and a confirmation naming the target and the
  presentation keys it rewrites. Two read actions - `site-backup-inspect` (read the
  manifest without applying) and `site-backup-delete` - are `manage_domains` +
  scope-confined to the `lazysite-site-` namespace, so a full/content backup or a
  traversal path is unreachable. **Apply keeps the target's identity by default**
  (`site_url` / `site_name`), with an `adopt_identity` opt-in to take the source's;
  it **mirrors the layout's theme assets** so an applied site is styled immediately;
  and language (`lang`/`lang_group`) travels in the package. A token-client
  `site-backup-download` (`manage_domains`, namespace + scope confined) completes the
  create / download / upload / apply loop over MCP.

## Content history (git, SM085)

Opt-in per-file version history for the site content. ONE switch enables it:
ticking the **Content history plugin** on Plugin Manager runs its `on_enable`
hook (conf key `git_history: enabled` + the initial snapshot), and unticking
runs `on_disable` (recording paused, every version kept). The `git-init`
control-API action (gated on `manage_config`) and the plugin's Status /
Enable / Pause actions on Plugin Config drive the same `Lazysite::Git`
machinery - the config page is the inspection/recovery surface, not a second
required step. Enabling puts the docroot under git: the
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

**Recording-health hardening (0.7.8, field defect dito.tech).** The repo is
initialised `--shared=group` (`core.sharedRepository=group`), so git itself keeps
every object dir and ref group-accessible regardless of the process umask - the
canonical shared-repo setting for the split www-data/site-user identity; the
in-place-rewritten scratch files (`COMMIT_EDITMSG`, an unwritable one is fatal to
a commit) are kept 0664 by the hook. Because a failed commit deliberately never
breaks the save, failure is made visible instead of silent: the engine touches
`lazysite/git/COMMIT_FAILED` on any commit failure (an add failing for an
*existing* path counts - that is repo trouble, not the tolerated
unmatched-pathspec case) and removes it on the next successful commit. Three
surfaces read the state: the content-history plugin's **status** action says
"recording is failing", the Files page's empty history panel suspects a failure
instead of pretending the file is new, and `lazysite-check` FAILs on any repo
path the CGI cannot use ("new file versions are silently not recorded"), WARNs
on the breadcrumb and on a missing `core.sharedRepository`, and `--fix` repairs
the modes and sets the config. The guarantee suite
(t/unit/lib/18-git-guarantee.t) pins a write-path registry (every manager/DAV
write action classified hooked-or-exempt), the shared-permissions promise, and
the full failure->recovery lifecycle across all surfaces.

Each file row on the Files page gains a **History** panel: the commit list (when /
who / what), a read-only **View** of any version, a unified **Diff** against the
current file, and **Restore** - which writes the old content back *through the
normal save path* (cache invalidation incl. host copies, alias reindexing, audit),
so the restore is itself the newest version and nothing is ever lost. Reads are
`git-history` / `git-show` / `git-status` (token: `manage_content`, audit-skipped);
`git-restore` shares the content grant and is audited. Full-system backups remain
the DR mechanism - they carry exactly what the history deliberately excludes.
History follows a rename and never leaks across a delete/recreate (SM175).

The content-history **status** is a genuine health probe (0.9.13), not a boolean:
it reports **enabled-and-healthy** vs **half-enabled/inconsistent** (config says on
but the repo or a hook is wrong) vs **degraded/paused**, so an operator can tell a
working history from one that is silently not recording.

**File list + revision statistics** (SM199). Beyond a single file's panel, a
**git-history-summary** action (and a `list_content_history` MCP tool) drive a
Files-page **History overview**: per-file **revision count**, **first/last commit
dates**, **last author**, and site totals across the tracked tree - a
who-changed-what-and-how-often view of the whole site. It is rename-aware and
leak-safe by the same rules as the per-file history.

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

The tools, by group (unauthenticated `tools/list` is filtered to the invocable
subset - see connector reliability below):

| Group | Tools |
|---|---|
| Identity | `whoami` (id, capabilities, active layout/theme, full tool manifest, auth method + expiry), `describe_capabilities` (the capability map + task recipes, incl. `build-from-figma`) |
| Read | `list_files`, `read_file` (reads a Template Toolkit `layout.tt` as text since SM202), `read_page` (parsed front matter + body), `list_pages`, `page_status` (will my edit reach visitors?), `search_files`, `preview_page` (server-side public render), `validate_page`, `audit_site`, `get_permissions`, `list_form_handlers`, `read_nav`, `list_layout_catalogue` (name/version/default_theme/`themes[]`/installed + description + tags, SM206), `theme_tokens` (token vocabulary + exemplar values, SM204), `read_form_submissions` (least-privilege submission read, `read_submissions`, SM187), `list_content_history` (per-file revision statistics, SM199) |
| Write | `write_file` (validates on write; a `theme.json` runs the theme validator eagerly, SM205), `create_page`, `delete_page` (removes `.brief`, reports dangling refs), `rename_page` (`update_links`), `replace_text` (no silent clobber), `copy_file`, `move_file`, `delete_file`, `set_permissions`, `bind_form`, `set_nav`, `create_theme` (one-call validated theme scaffold, SM205) |
| Site ops | `activate_theme`, `activate_layout`, `invalidate_cache` |
| Domains | `site_backup` (package a domain) and `site_apply` (apply a package - the migration step), both `manage_domains`-gated (SM158/SM193). The fuller transport (inspect / download / upload) and the domain admin itself (`domain-add`/`-set`/`-preview`/`-remove`) are control-API only |

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
(`bind_form`) but never set a destination or credential, and it can *read* form
submissions through the least-privilege `read_submissions` capability
(`read_form_submissions`) without holding the broader `manage_forms`.

**Connector reliability** (0.9.13). `tools/list` is now **capability-aware**: an
authenticated caller sees only the tools it can actually invoke (SM196), and
connected-detection flips at authorise time so a paired connector reports itself
connected. A `401` carries a distinct `data.reason` -
`sign-in-incomplete` / `credential-invalid` / `token-expired` / `token-invalid` -
so a client can tell "finish signing in" from "re-pair"; a rotated **expired** token
returns `reason=expired` with guidance to re-exchange a pairing key (the expired
signal is given only after the secret verifies, so it leaks nothing to a wrong
token). The operator **connect code** is valid for 30 minutes (was 15) with its
expiry surfaced, the onboarding copy is agent-neutral, and a `lazysite-check` probe
flags a remote service that is enabled but has a bad or absent `site_url` (the
broken-discovery-endpoint class). Since the 0.9.0 killswitches, the MCP surface is
**off by default** and refuses pre-auth (including discovery) when disabled,
disclosing nothing.

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

**Submissions viewer** (SM182, v2 SM187). Stored `file`-handler submissions live at
`lazysite/forms/submissions/<form>.jsonl` in the reserved `lazysite/` tree the file
editor refuses to open, so the data was unreachable from the UI. The plugin-config
**View submissions** button now opens the store in a scrollable **modal** table. A
`form-submissions` read action parses the store server-side (docroot-confined,
`.jsonl` only, no traversal), unions keys into columns, caps at the most-recent 500
rows, and returns values verbatim; the client **escapes every cell**, so a hostile
submission renders as inert text. A handled row can be **deleted**
(`manage_forms`, UI, audited, atomic rewrite keyed on a stable per-row id). A new
least-privilege **`read_submissions`** capability plus the `read_form_submissions`
MCP tool let an agent read submissions over API/MCP without the broader
`manage_forms`; both channels gate `form-submissions` on `manage_forms` **OR**
`read_submissions` at parity.

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

Further flags: `--channel edge|beta|stable` sets a site's `update_channel` (a standalone,
audited maintenance op); `--force` upgrades a site past its channel policy
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
(the `edge < beta < stable` ladder: the minimum release maturity it accepts)
and `update_policy` (`auto`/`manual`, default `manual`) in
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
serves in 0.4 ms pooled (155x)** - the CGI figure is almost entirely process
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
- **Manager access is interactive-only** (SM127). An account that can ACTUALLY use
  the interactive UI (holds the group-granted manager `ui` capability AND has
  interactive login enabled) is refused on the API and MCP transports, and a group
  may not combine `ui` with a remote (`api`/`mcp`) channel - so a leaked or
  misissued token on a manager account cannot drive the site remotely. The 0.9.0
  patch fixed a token-path regression in this gate: it no longer blocks
  **introspection** (`whoami` / `describe-capabilities` stay open per SM126/SM072),
  and no longer refuses a deliberate **agent account** that holds the capability but
  has interactive login DISABLED (`ui:false`) - the gate keys on genuine interactive
  usability, not the capability alone. A control-API token is also pinned as a
  per-site credential that cannot authenticate against another site's docroot.
- **Bad-URL auto-blocker** (SM128, on by default). `Lazysite::BadUrl` counts
  scanner-probe hits (`wp-login.php`, `.env`, `.git`, `*.php` on a Markdown site, …)
  per source IP in a rolling window and blocks at a threshold (default 10 / 3600s);
  enforced in the auth wrapper (403), blocked IPs listed + unblockable on the Stats
  page, auto-blocks audited.
- **SSRF guard** (`Lazysite::Fetch`). Every outbound fetch (`.url` pages,
  migrate-to-local, remote layouts) rejects loopback, RFC1918, link-local/metadata,
  IPv6 loopback/link-local, multicast and CGNAT targets. The `domain-check` probe
  (0.9.0) applies the same guard to a caller-influenced host, requiring every
  RESOLVED address to be public.
- **Manager file-path confinement** (F1, 0.9.9). The file-editor path blocklist is
  matched against the **canonical resolved path**, closing a traversal by which a
  content-authoring account could reach engine-owned files under `lazysite/`.
- **Download read-ACL / scope** (F2, 0.9.9). `file-download` / `file-zip-download`
  now enforce the same per-file read ACL and `dav_scope` confinement as `read`, so a
  delegated editor cannot pull a file restricted away from them; and the
  account/group roster (`principals`) is capability-gated
  (`manage_content` or `manage_domains`) so a user with no grant-related capability
  cannot enumerate every account and group.
- **Dormant-grant fix** (F3, 0.9.9). `manage_domains` / `feedback` /
  `read_submissions` were resolved but not surfaced to the cookie-manager
  capability gate, so a non-operator grant silently did nothing; all three now take
  effect, pinned by a parity test.
- **Atomic config + auth-store writes** (0.9.9, data-loss class). Concurrent config
  saves could truncate `lazysite.conf` to a single line, and the same
  truncate-before-lock race existed in the auth store. `write_file_checked` is now
  atomic (temp + rename, never unlinking the real file), `_write_conf_key` holds a
  lock across its read-modify-write, and every auth-store mutation
  (`write_users`/`write_groups`/`update_user_hash`/the MCP form-bind/the bad-URL
  caches) writes atomically and serialises on a store lock, so a reader never sees a
  truncated credential store and two concurrent edits cannot lose an update. Reads
  stay lock-free.
- **Manager trust gate** (0.8.0). The manager-API applies the same in-app trust gate
  as the processor, so client-supplied `X-Remote-*` identity headers are ignored
  unless the auth wrapper vouched for them - a backstop for an edge that fails to
  strip them (guarantee test `t/lint/13`, adversarial test
  `t/unit/manager/39-forged-identity.t`).
- **Backup-restore control-tree exclusion** (0.8.0). Backup restore excludes the
  `lazysite/` control tree on extraction, so a crafted content tarball cannot
  overwrite the auth/config namespace to escalate - defence-in-depth on top of the
  create-time exclude and the full-backup restore refusal.

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

- **0.10.9** (2026-08-14, EDGE) - **The sweep that finishes the 0.10.8 move.**
  `lazysite acl reapply` (SM296/SM286) re-issues every stored access rule so its
  content actually leaves the document root - the upgrade action no package can
  perform, because protecting content moves it only on the ACT of protecting.
  Fixes a crash that left content stored-as-protected and still served
  (SM296: `File::Path::make_path` croaks, so the guard after it was
  unreachable). The FastCGI pool worker can now BE the front door (SM294),
  answering the hot path in-process (137x) and forking for the rest. `meta_desc`
  and `meta_title` front matter (SM300) separate a page's description from its
  visible subheading; `llms.txt` index-page links resolve (SM299);
  `regenerate-registries` reaches the control API (SM301); bundled docs stop
  crowding a site's own `llms.txt`. Plus the release compliance gate,
  `docs/compliance/`, and the fourth eight-dimension review.
- **0.10.8** (2026-08-13, EDGE) - **The front end stops making decisions.**
  Protecting content MOVES it out of the document root into a private store
  (SM286); the engine tree can move out too (SM293 step 2); the registries are
  generated on request rather than written to disk (step 3); the trust-header
  gate becomes an enforced application control rather than a front-end
  configuration requirement (step 4); and a front end can be ONE RULE, with
  `Lazysite::FrontDoor::route()` making every decision the vhost templates used
  to (step 5). SM248, SM268 H17 and SM283 were all the same cause - security
  living in configuration lazysite ships as a template, cannot test where it is
  installed, and mostly cannot see.
- **0.10.7** (2026-08-11, EDGE) - SM283's remedy: the missing Hestia **nginx
  proxy template**, which hands a static request back to the origin whenever an
  ACL store exists, with an `X-Lazysite-Front` observable checkable by curl with
  no credentials. Also `lazysite check --check-acl` (SM285), which lets a site
  prove its own gating from outside, and the access-control programme SM287-SM292
  - a root ACL entry that protects the whole site, real partner groups resolved
  on MCP and the control API, and one way to express access on every surface
  including a CLI verb.
- **0.10.5 / 0.10.6** (2026-08-10 / 2026-08-11, EDGE) - what an adversarial
  security review found and what it cost to prove, then the release that told an
  operator to do something it had not made safe.
- **0.10.1 - 0.10.4** (2026-07-27 - 2026-08-09, EDGE) - form spam controls and
  submissions tooling; what the platform knew and did not say; MCP surface parity
  with instructions no longer accepted quietly (SM239); and success reported for
  work that did not happen - the recurring defect class this line is named for.
- **0.10.0** (2026-07-27, STABLE) - promotes the 0.9.11-0.9.17 beta line to
  stable: durable stats store and trends, token-lifetime control, live-config AI
  discovery, sudo-safe permissions and repair, manager-UI polish.
- **0.9.15 - 0.9.17** (2026-07-25 - 2026-07-27, BETA) - manager UI polish
  (domains configure-modal, promote-in-dropdown, hints), token-lifetime control
  plus live-config AI discovery, and a durable stats store with trends.
- **0.9.14** (2026-07-24, EDGE) - **Theme authoring + external-design (Figma)
  ingestion**, plus operator features. `theme_tokens` (SM204) reads a layout/theme
  token vocabulary in one call; `create_theme` (SM205) is a validated one-call theme
  scaffold (copy-nearest-and-adapt when `css` is omitted) with eager `theme.json`
  validation on the `write_file` path; `layout.json` gains an optional declarative
  `tokens` block with a non-fatal activation warning (SM203); the layout catalogue
  carries description + tags (SM206); `layout.tt` reads as text (SM202); and a new
  `/docs/integrations/` namespace ships a **Figma dual-MCP helper** (SM208) - bridge
  the Figma MCP source and the lazysite MCP destination, transfer identity as tokens,
  rebuild rhythm in CSS, no lazysite-side Figma fetcher and no stored credentials,
  with a `build-from-figma` recipe in `describe_capabilities`. Operator features:
  promote a sub-user to top level + `scope_independent` (SM194); content-history
  file list + revision statistics (`git-history-summary` / `list_content_history` /
  a Files-page History overview, SM199). Fixes: the discovery check accepts the
  dynamic `${REQUEST_SCHEME}://${SERVER_NAME}` `site_url`; a passwordless/token-only
  account can be removed; a no-`ui` account at `/manager/` gets a clear terminal
  message instead of a login loop; a group change warns before removing an account's
  last manager-access group.
- **0.9.13** (2026-07-23, BETA) - Site integrity, capability clarity + connector
  reliability. Engine-served system pages (login/claim/40x moved to the protected
  `lazysite/templates/system/` tree, content-root → docroot → default fallback,
  self-healing, SM201); site-package migration completeness (token-client
  site-backup-download, identity-keep-on-apply with `adopt_identity` opt-in, theme
  asset mirror on apply, SM193); connector reliability (distinct 401 `data.reason`,
  30-minute connect code with surfaced expiry, fresh-chat guidance, SM200; connected
  detection + capability-aware `tools/list`, SM196); capability clarity
  (grant-to-enable hints SM191, channel-surface grid ticks SM197, inert-group
  warning SM198); and content-history status as a real health probe.
- **0.9.10 / 0.9.12** (2026-07-21 / 2026-07-23) - 0.9.10 STABLE promotes the hardened
  0.9.x line (carrying the 0.9.9 data-loss + security hardening) to stable; 0.9.12
  (superseding the withdrawn/burned 0.9.11) folds in field fixes - the `lzs_session`
  JS-marker login-loop cleared at both bounce points (SM188), the write path refusing
  a raw-mode script-capable content page on save/PUT (415, SM189, ADR 0006 extended),
  and `.well-known/oauth-*` returning 404 when OAuth is off (SM190 partial).
- **0.9.9** (2026-07-21, BETA) - **Data-loss + security hardening.** Atomic config +
  auth-store writes with store-lock serialisation (never a truncated
  `lazysite.conf`/credential store); manager file-path confinement against the
  canonical resolved path (F1 traversal); `file-download`/`file-zip-download` enforce
  read-ACL + `dav_scope` (F2); `principals` capability-gated; the dormant
  `manage_domains`/`feedback`/`read_submissions` grants surfaced (F3); a switched-off
  service answers `200 {ok:0, service_disabled}`; dormant-capability indicators
  (SM180). See the private advisory.
- **0.9.5-0.9.8** (2026-07-19 to 2026-07-20, BETA) - The **form-submissions viewer**:
  an in-manager escaped table (SM182), then v2 - a scrollable modal, per-row delete
  (`manage_forms`, audited), and agent read via the least-privilege `read_submissions`
  capability + `read_form_submissions` MCP tool (SM187). **Site-package migration in
  the UI** (SM183): Export-site per domain and a Backups Site-packages panel
  (list/download/upload/apply/delete) with an apply preview; language travels in a
  package and the default site is exportable (SM185). Plus the caps-within-session
  fix (a granted capability reflects without re-login).
- **0.9.4** (2026-07-19, STABLE) - Certifies the 0.9.x security-hardening line:
  cross-plane capability consistency; default-off service killswitches with a
  Services panel; the SM042 config-save migration onto `config-set`; the SM127
  token-path fix; the `domain-check` SSRF guard; tenant-token isolation; the
  capability-grid grantability fix; the form-targets data-loss fix; the nav-read
  path-leak fix; WebDAV PUT RFC-4918 409 compliance; and expired-token rotation
  guidance (0.9.2/0.9.3).
- **0.9.0** (2026-07-19, EDGE) - Cross-plane permission consistency + service
  killswitches. Every remote surface (MCP / OAuth / control API / token exchange) is
  now **off by default** behind a conf killswitch surfaced in Settings → Services
  (BREAKING, operator-recoverable); WebDAV nav/form editing needs
  `manage_nav`/`manage_forms`; the Config page saves each key through the audited
  `config-set` (SM042); plus the token-path regression fix, the `domain-check` SSRF
  guard and tenant-token isolation.
- **0.8.0** (2026-07-18, STABLE) - **Second stable release**, cut from 0.7.28 on the
  2026-07-18 eight-dimension review. Promotes the whole 0.7.x line to stable:
  first-class multi-site (SM151), the domain access-control model (SM165), content
  history that follows renames and never leaks across delete/recreate (SM175), and
  the complete multilingual language-set feature (SM179 P1-P8). Fixes the serious
  stored-XSS / response-header-injection path where a front-matter `lang:` reached
  `<html lang>`/`Content-Language` unescaped (now a bare language tag), a
  `domain-add` CRLF gap, the raw/api script-capable `content_type` downgrade, and
  the manager-API trust gate; a breadth security-testing pass added structural
  guarantee tests and negative tests (privilege-escalation confinement,
  path-traversal sweep, login-rate-limit fail-open). DoC signed at the cut.
- **0.7.28** (2026-07-18, BETA) - Multilingual completion + cache correctness +
  domains/manager UX. Engine-emitted chrome is localised (SM179 P8: the bare 404,
  the no-403.md fallback and the auth reject pages, via a built-in English table
  overlaid by `lazysite/i18n/<lang>.json`, fail-closed; the 404 fallback escapes
  the request URI). Language config is first-class - `lang`/`lang_group` settable
  via `domain-set`, the CLI and the Domains Add + Configure forms;
  `whoami`/`lang-status` detect a set even when `lang_group` is only on aliases;
  `lang-status` gated on `manage_content`. A conf-only change now invalidates the
  page cache (no more stale `Content-Language`/chrome under any process model);
  per-host caches are listed and cleared per host on the Cache page; the manager
  preview UTF-8 double-encode is fixed. The domain "alias" concept is retired for a
  "Copy settings from" pre-fill on Add domain. Manager UX consistency (token
  picker, Edit/Delete verbs, primary Save) and editor fixes (exit-to-folder,
  reserved-file warning). ADR 0008 records the stable compatibility-freeze scope.
- **0.7.27** (2026-07-18) - Multilingual language sets (SM179 P1-P7): sibling
  per-language content roots linked by a shared `lang_group`, with engine-supplied
  `[% languages %]` switcher data, `hreflang`/`x-default` (layout + sitemap),
  `<html lang>`/`Content-Language`, content-root-first `json:`, layout chrome
  strings (`[% t %]`), a `lang-status` coverage report, and whoami/MCP
  discoverability. Theme/layout delete-safety accounts for every domain
  (sub-domains as first-class peers, SM177); an audit-log domain target no longer
  opens in Files (SM178).
- **0.7.26** (2026-07-18) - Content history follows renames and never leaks across
  delete/recreate (SM175); a domain-owned access-control model with per-user locks
  (SM165); compound groups (group-of-groups, SM121); and a manager batch - theme
  install no longer auto-activates (SM176), nav-refresh signalling (SM168), the
  nav editor names its file (SM169), sub-user audit view (SM173).
- **0.7.24-0.7.25** (2026-07-18) - Site packages + `manage_domains` + nav
  domain-awareness (SM139 family); forms discoverability for agents (SM161); and a
  run of manager UI / key / WebDAV fixes (SM162-172).
- **0.7.18-0.7.23** (2026-07-16) - Group-level domain delegation (SM155) with a
  pre-DNS domain preview and first-class aliases; the domain config check +
  domains panel (public-IP, cert SANs, proxy-aware); Files breadcrumb fix.
- **0.7.3-0.7.17** (2026-07-10 to 2026-07-16) - First-class multi-site: many
  domains on one instance with per-host content roots and confinement (SM110 /
  SM151); WebDAV theme/layout authoring (SM071); session registry + revocation
  (SM141); and the run of edge fixes across auth, WebDAV, themes and the manager.
- **0.7.2** (2026-07-10) - Packaged distribution (SM139): the
  `lazysite-common` + `lazysite-hestia` debs, the `lazysite` CLI
  (provision/upgrade/sites, root-refusal by design, the site registry), fleet
  `update_policy` + `--force-security` (honoured only for manifests declaring
  `security_critical`), one-command Hestia onboarding
  (`lazysite-hestia-domain`, CGI + FastCGI templates), and the hardened
  `lazysite-check` (post-fix re-report, CGI-identity evaluation).
- **0.7.1** (2026-07-10) - Persistent runtime (SM142): the dual-mode FastCGI
  accept loop - per-site worker pools, modules compile once; measured
  cache-hit 62.2 ms CGI → 0.4 ms FCGI (155x); plain CGI byte-identical.
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
documentation set, the `docs/feature-requests/` record, and the CHANGELOG, current
to v0.10.9 (the EDGE line in which the front end stopped making content
decisions: protected content moved out of the document root, the routing table
moved inside the engine, and the upgrade sweep that completes it shipped). For the authoritative detail
of any feature, read the cited script or doc; for the "why", read the corresponding
`SMxxx` feature-request.*
