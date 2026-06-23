---
title: AI briefing - publishing
subtitle: Guide for an automated partner publishing to a lazysite site over WebDAV and the control API.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an automated publishing partner - an AI agent that holds write
access to the docroot over WebDAV. It covers connecting, authenticating, the
path mapping, scope, the WebDAV operations, the control API, and cache
behaviour.

For content rules (front matter, Markdown, URLs) see
[AI briefing - content authoring](/docs/ai-briefing-authoring). For layouts and
themes see [AI briefing - layouts](/docs/ai-briefing-layouts). For configuration
see [AI briefing - configuration](/docs/ai-briefing-configuration). For keys,
variables, and file locations see [Reference](/docs/reference).

## How onboarding works

You are given one document out of band: an **onboarding brief**. Everything
else is discoverable from it. The brief carries a machine-readable block
(under a `## Machine-readable` heading) - parse your identity, scope, and
endpoints from that block, not from prose. A partner-agnostic copy is published
at `/.well-known/ai-partner`.

The brief *describes* the grant; the token *is* the grant; the server
*enforces* it. Treat the scope in the brief as advisory about what to attempt;
the server is authoritative and rejects anything outside it. If an in-scope
write returns `403`, the grant - not the documentation - is right.

## Authentication

You hold a single-use, short-lived pairing key (prefix `lzp_`). You exchange it
once for a working access token (prefix `lzs_`).

Exchange
: `POST` the pairing key to the exchange endpoint. The JSON response carries
  the token and its expiry as an epoch timestamp.

Present
: Send the access token as HTTP Basic auth on every request - **username is
  your partner id, password is the token**. The partner id gives per-partner
  attribution and scoping; it is the exact id from your brief (often not a bare
  name - e.g. `claude-dhcf`), and the wrong username returns `401`.

Rotate
: Before the token expires, present your current token as Basic auth to the
  rotate endpoint with no body; you get a fresh token and a new expiry. There
  is one live credential per account - the old token dies on rotation.

Recover
: On an unexpected `401`, rotate if you still hold a recently valid token;
  otherwise the operator must re-issue the pairing.

```bash
# Exchange the pairing key for an access token
curl -s -X POST "https://SITE/cgi-bin/lazysite-auth.pl?action=exchange" \
  --data "username=PARTNER&pairing_key=lzp_..."
# -> { "ok": true, "token": "lzs_...", "expires_at": 1750000000 }

# Rotate before expiry (current token as Basic auth, no body)
curl -s -X POST -u "PARTNER:lzs_..." \
  "https://SITE/cgi-bin/lazysite-auth.pl?action=rotate"
```

Read `expires_at` from the exchange and rotate responses so you rotate on
schedule rather than waiting for a `401`. Both endpoints are HTTPS-only and
rate-limited.

### Check your access, and your grant

A cheap, side-effect-free probe that the token is live:

```
PROPFIND /dav/  Depth: 0  Authorization: Basic base64(PARTNER:lzs_...)
-> 207 = authenticated; 401 = wrong username or token.
```

For your **full grant** - capabilities, groups, scope, and the plugins,
layouts, and themes the site offers (with active flags) - introspect over the
control API rather than assuming from the bootstrap:

```
GET /cgi-bin/lazysite-manager-api.pl?action=whoami
Authorization: Basic base64(PARTNER:lzs_...)
-> { partner, capabilities, groups, scope, layouts, themes, plugins, site_capabilities }
```

## Endpoints

WebDAV
: `https://SITE/dav/` - content, assets, layout/theme files, and `nav.conf`.

Exchange / Rotate
: `https://SITE/cgi-bin/lazysite-auth.pl?action=exchange` and `?action=rotate`.

Control API
: `https://SITE/cgi-bin/lazysite-manager-api.pl` - token-authenticated (the
  same Basic auth). Carries the operations that are not file-shaped. Each is
  gated by the matching capability from your grant.

## Control API actions

Issue these to the control-API endpoint with your access token as HTTP Basic
auth, the same as WebDAV. Each is a `?action=<name>` on that endpoint with the
action's own parameters (e.g. `path`, `theme`); call `whoami` to see which
actions your capabilities permit.

`whoami`
: Your partner identity, capabilities, groups, and effective scope, plus the
  plugins/layouts/themes the site offers. Call it first to confirm your grant
  from the server rather than the brief alone.

`theme-activate` / `layout-activate`
: Set `theme:` / `layout:` in `lazysite.conf` and clear the affected cache in
  one step. Needs `manage_themes` / `manage_layouts`.

`config-set`
: Set an allowlisted site config key. Needs `manage_config`; keys outside the
  allowlist are rejected.

`cache-invalidate`
: Clear cached HTML so a structural change takes effect. (It deletes only
  generated cache - `<page>.html` with a `.md`/`.url` source - not your author
  `.html` partials.)

`acl-set` / `acl-get` / `acl-remove`
: Own a file you publish so co-authors on the same scope cannot overwrite it -
  see *Own your pages* below. Needs `webdav`.

## Path mapping

The WebDAV root maps one to one onto the docroot. You address the source `.md`
file, not the published URL. The `page_source` value (see
[Reference](/docs/reference)) is exactly the WebDAV path for a page.

```
Published URL        Source file (WebDAV path under /dav/)
/                    /index.md
/about               /about.md
/docs/install        /docs/install.md
/docs/               /docs/index.md
```

Published URLs are extensionless on the read side; on the write side you always
address the `.md` (or `.url`) file.

## Scope and denied paths

Your capabilities and path scope come from the brief (and `whoami`). The content
tree, assets, the layout/theme files under `lazysite/layouts/`, and
`lazysite/nav.conf` (with `manage_config`) are writable within scope. These
paths are **denied** and the server rejects writes to them:

`/cgi-bin/`
: Executable scripts (processor, auth CGI, manager API, plugins). Never writable.

`/lazysite/lazysite.conf`
: Site configuration. Config keys are set through the control API with an
  allowlist, not by overwriting this file.

`/lazysite/auth/`
: User and group credential store.

`/lazysite/forms/`
: Form target and SMTP configuration (`smtp.conf`, `handlers.conf`) - secrets.

`/lazysite/manager/`
: Manager UI internals.

`/lazysite/cache/` and `/lazysite/logs/`
: Generated cache and log files.

`/lazysite/templates/`
: Registry templates that generate `llms.txt`, `sitemap.xml`, and feeds.

## WebDAV operations

`PROPFIND`
: Inspect a collection or check a resource exists before writing.

`GET`
: Read the current source file before editing.

`PUT`
: Create or overwrite a source file.

`MKCOL`
: Create a collection. WebDAV does not create intermediate collections -
  create parents first, top down.

`DELETE`, `MOVE`, `COPY`
: Remove, rename, or duplicate resources within scope.

## Document your intent: `.brief` sidecars

Every file you author should carry a sidecar **`<file>.brief`** beside it -
`index.md.brief` next to `index.md`, `main.css.brief` next to a theme's
`main.css`. The brief records *why* the file exists and *what* each edit
changed, so the next agent (or the operator) understands intent before
touching it. Maintain it as you work:

- On create, `PUT` a brief next to the file with a one-line `intent:` and a
  first `## Log` entry.
- On every later edit, `GET` the brief, append one log line
  (`date · action · who · what`), and `PUT` it back. Append - do not rewrite.

```text
# Brief - index.md

intent: the site landing page; hero + three feature cards + contact CTA.

## Log

- 2026-06-23 · created · <you> · initial landing page
- 2026-06-24 · edit · <you> · reworded hero, added contact CTA
```

Briefs are **private**: they are denied to public visitors at every layer and
never appear in `sitemap.xml` or `llms.txt`. They are reachable only to you
over WebDAV and to the operator in the manager. A `.brief` is not a blocked
extension, so it writes through your normal content (and theme/layout) scope
exactly like the file it accompanies. Briefs are encouraged, not enforced - a
publish without one still succeeds, but the Files page flags what is missing.

## Own your pages: ACLs

On a shared scope where several authors write, you can **own** a file so others
cannot overwrite it. Ownership and permissions are *not* files in the content
tree - they live in a central store and are set through the control API:

```
POST .../lazysite-manager-api.pl?action=acl-set&path=/content/about.md
{ "write": ["your-partner-id"], "read": ["your-partner-id"] }
```

- The first `acl-set` on a file you can write records **you** as its `owner`.
- `write` - an allowlist; if present, only the owner and these users may
  `PUT`/`DELETE`/`MOVE` the file. Omit to leave writes open (scope still
  applies).
- `read` - an allowlist for `GET` over WebDAV. Omit to leave reads open. (This
  governs WebDAV/manager access only - the public still sees the rendered
  page.)

`acl-get` returns the current entry; `acl-remove` clears it (owner only - so no
one can take over a file you own). Without an entry, access is just your
account's scope, exactly as before. Usernames only for now (no groups).

## Cache behaviour

The processor serves a cached `.html` only when it is newer than its `.md`
source, and regenerates when the cache is missing or stale.

Content edits self-invalidate
: A `PUT` updates the source's mtime, so the page regenerates on its next
  request. No separate cache action for ordinary content.

Protected pages are never cached
: Pages with `auth:` or `payment:` render per request.

Structural changes need a cache clear
: Editing `nav.conf`, activating a theme/layout, or changing a config key does
  not retro-invalidate pages whose cache is already warm. For content scope,
  re-PUT the affected pages (a content PUT self-invalidates). For
  theme/layout/config, clear the cache via the control API (`cache-invalidate`)
  or ask the operator.

## Themes and layouts have their own gates

Theme files (`lazysite/layouts/<layout>/themes/<theme>/…`) need `manage_themes`;
layout structure and the shared wrapper (`layout.tt`) need `manage_layouts` (a
*separate* capability). And the **active** layout and theme are **read-only over
WebDAV** by design - a `PUT` to the live `layout.tt` returns `403` regardless of
capability. To re-skin globally:

1. **Stage a NEW layout dir** beside the active one - `MKCOL`
   `lazysite/layouts/<new>` and `…/themes/<theme>` (a fresh path returns `409`
   until its collections exist), then `PUT` the files.
2. **Preview** by setting `layout: <new>` in one page's front matter; the theme
   SOURCE css is web-served at `/lazysite/layouts/<new>/themes/<theme>/main.css`
   (the `/lazysite-assets/` mirror is `404` until activation).
3. **Activate** via the control API (`layout-activate` / `theme-activate`, which
   set `lazysite.conf` and clear the cache atomically) - or hand off to the
   operator. Then drop the per-page overrides.

Capabilities are read from your account on every request (the token does not
encode them), so a grant is effective immediately - you do not need a new token.

## Verify your publish

A `2xx` is not proof the page is right. After publishing, confirm:

- **Fetch the page** and expect `200`.
- **No leaked Template Toolkit** - the body must contain no literal `[%` … `%]`.
- **The nav reflects `nav.conf`** on every affected page (re-PUT any still
  showing the old nav).
- For a **form** page, `GET` the form's action URL and expect anything but
  `404`; the receiver is a server CGI (`/cgi-bin/form-handler.pl`) the operator
  installs - if it `404`s, report it rather than trying to fix it.

## Tasks

### Connecting

1. Parse the machine-readable block from the onboarding brief.
2. `POST` the pairing key to the exchange endpoint; store the token + expiry.
3. `PROPFIND /dav/` to confirm, and `whoami` to read your real grant.
4. Fetch the briefings and [Reference](/docs/reference) for the content,
   layout, and configuration rules.

### Publishing a single page

1. `PROPFIND` or `GET` the target to check current state.
2. Prepare the `.md` with valid front matter (see
   [authoring](/docs/ai-briefing-authoring)).
3. `MKCOL` any missing parent collections, top down.
4. `PUT` to its docroot-relative path under `/dav/`. The page regenerates on
   next request.

### Publishing a whole site

1. `PROPFIND` the tree to learn what exists.
2. `MKCOL` collections parent-first; `PUT` each file (diff against the
   `PROPFIND` and skip unchanged).
3. Verify with `PROPFIND`/`GET` on a sample, per the checklist above.

### Editing navigation

1. `GET` `/dav/lazysite/nav.conf`, edit, `PUT` it back.
2. Re-PUT affected pages (or clear the cache) so the new nav appears on warm
   pages.

### Rotating your token

1. Before `expires_at`, `POST` to rotate with your current token as Basic auth.
2. Replace your stored token + expiry with the response.

## Offline fallback - drop-in bundle

When you cannot reach `/dav/` - no egress, no token, or a locked-down runner -
emit the file set you *would* have published as a single **JSON bundle** the
operator applies. Same content, no network.

```json
{
  "lazysite_bundle": 1,
  "post": ["clear-cache"],
  "files": [
    { "path": "about.md", "content": "---\ntitle: About\n---\nAbout us.\n" },
    { "path": "lazysite/layouts/dhcf/layout.tt", "content": "…[% content %]…" }
  ]
}
```

- `path` is **docroot-relative** - the same path you would use under `/dav/`.
- `content` is the full file body (JSON-escaped - no delimiters to collide with).
- Include **only in-scope files** - never the denied paths above.
- `post` lists post-extract actions; use `"clear-cache"` when the bundle changes
  a theme, layout, `nav.conf`, or config file (content pages self-invalidate).

The operator applies it (auditing first - a manifest, not an auto-run script):

```bash
perl tools/lazysite-bundle-apply.pl --docroot DOCROOT bundle.json          # dry run
perl tools/lazysite-bundle-apply.pl --docroot DOCROOT --apply bundle.json  # write
```

The tool validates every path against the deny list, confines writes to the
docroot, reports create-vs-overwrite per file, and prints the post-extract
commands. The file set is identical to a live publish - only the transport
differs.
