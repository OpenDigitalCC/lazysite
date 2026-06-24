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

## First: confirm you can reach the site

Before authenticating, do one cheap unauthenticated request - `GET
https://SITE/.well-known/ai-partner` (it also returns your machine-readable
bootstrap). This proves your environment can egress to the host.

- JSON came back: you are connected - proceed.
- The request was blocked **before reaching the site** - no network, or a proxy
  `403` whose body names an allowlist (`host_not_allowed`, "add this host to your
  egress settings"): **stop and report that immediately.** The block is on your
  side; the host must be added to your network egress allowlist. Do not retry
  blindly, and do not conclude the site is down - you have not reached it yet.
  Note that a pairing key denied at your proxy is **not** consumed (it never
  reached the origin), so it is still live - say so in your report.
- A response that reached the origin but is not the expected JSON (a wrong-host
  page, DNS failure, timeout) is a wrong address, not an egress block.

Report which of these you got before going further, so a human can act on the
right thing.

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

MCP (optional)
: `https://SITE/cgi-bin/lazysite-mcp.pl` - a remote MCP server exposing the
  maintenance operations as tools, for an MCP-capable agent. See
  *Connection modes*.

## Connection modes

Two ways to drive a site - pick by what you are. The credential, capabilities
and per-file ACLs are identical in both; only the transport differs.

API mode (WebDAV + control API)
: Direct HTTP. The full surface, and the right choice for a scripted build or
  bulk file work - WebDAV moves many files (a whole site deploy) efficiently,
  and the control API carries theme/layout/ACL/config. Authenticate with Basic
  auth (partner id + `lzs_` token).

MCP mode
: The MCP server wraps the *maintenance* verbs - `whoami`, list / read / write /
  move / delete files, `set_permissions`, `activate_theme`, `activate_layout` -
  as MCP tools. Best for an MCP-capable conversational agent (e.g. a Claude.ai
  custom connector, or Claude Desktop/Code): add `…/cgi-bin/lazysite-mcp.pl` as
  a remote connector with bearer auth `<partner-id>:<lzs_ token>` (the same
  credential, colon-joined). It writes one file per call, so for a large initial
  build prefer API mode + WebDAV; for ongoing maintenance either works.

Which to use, by client
: **Claude.ai (web / mobile)** reaches a site only through a connector, so it
  uses **MCP mode** - add `…/cgi-bin/lazysite-mcp.pl` as a remote custom
  connector with the bearer credential. **Claude Code / Claude Desktop** can use
  **either**: API mode directly (curl the control API, `PUT`/mount over WebDAV -
  best for a full build or bulk upload), or add the same endpoint as a remote
  (HTTP) MCP server with an `Authorization: Bearer <partner-id>:<lzs_ token>`
  header for guided, tool-shaped maintenance. A scripted or non-AI client uses
  **API mode**. The credential, capabilities and per-file ACLs are identical
  whichever you pick - call `whoami` first to confirm your grant.

## Control API actions

Issue these to the control-API endpoint (`/cgi-bin/lazysite-manager-api.pl`)
with your access token as HTTP Basic auth, the same as WebDAV. Each is a
`?action=<name>` query; parameters are passed in the query string unless noted
as a JSON body, and a token client's POSTs need no CSRF token. Call `whoami`
first to see which your capabilities permit.

`whoami` (GET)
: No parameters. Returns your partner identity, capabilities, groups, effective
  scope, and the plugins/layouts/themes the site offers - confirm your grant
  from the server rather than the brief alone.

`theme-activate` / `layout-activate` (POST)
: `path=<name>` - the theme or layout to make active (an empty `path`
  deactivates). Sets `theme:`/`layout:` in `lazysite.conf` and clears the
  affected cache in one step. Needs `manage_themes` / `manage_layouts`.

`cache-invalidate` (POST)
: `path=<dir-or-page>` - clear generated HTML under that path (use `/` for the
  whole site). Deletes only generated cache (`<page>.html` with a `.md`/`.url`
  source), never your author `.html` partials.

`acl-set` (POST)
: `path=<file>` in the query, plus a JSON body `{ "read": [...], "write": [...] }`
  (an operator may also pass `"owner"`). The first `acl-set` on a file you can
  write records you as owner. Needs `webdav`. See *Own your pages*.

`acl-get` (GET) / `acl-remove` (POST)
: `path=<file>`. `acl-get` returns the entry; `acl-remove` clears it (both
  owner-only, operators aside). Needs `webdav`.

`config-set` (POST)
: `key=<name>` and `value=<…>` (query string or JSON body). Sets one
  allowlisted site-config key in `lazysite.conf` - currently `site_name`,
  `site_url`, `search_default`. Privilege-relevant keys (manager groups,
  plugins, auth) and ones with their own action (layout/theme - use
  `layout-activate`/`theme-activate`) are refused. Needs `manage_config`.

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
tree, assets, the layout/theme files under `lazysite/layouts/`, `lazysite/nav.conf`,
and a form's dispatch config `lazysite/forms/<name>.conf` (the last two with
`manage_config`) are writable within scope. These paths are **denied** and the
server rejects writes to them:

`/cgi-bin/`
: Executable scripts (processor, auth CGI, manager API, plugins). Never writable.

`/lazysite/lazysite.conf`
: Site configuration. Config keys are set through the control API with an
  allowlist, not by overwriting this file.

`/lazysite/auth/`
: User and group credential store.

`/lazysite/forms/smtp.conf`, `/lazysite/forms/handlers.conf`, `/lazysite/forms/submissions/`
: SMTP credentials, handler definitions (addresses, webhook URLs), and the
  submitted entries - secrets and data. But a form's own dispatch config,
  `lazysite/forms/<name>.conf`, **is** writable with `manage_config` (it only
  names handlers) - see *Wiring a form* under Tasks.

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

## If `/dav` does not respond

Read the status before concluding the path is wrong - each one is a specific
gate, not a missing endpoint:

`404` on every method (including `OPTIONS`)
: WebDAV is **disabled site-wide** - not a wrong path. The endpoint returns
  404 by design until the operator enables it (manager Config → *WebDAV
  publishing*, or `webdav_enabled: yes` in `lazysite.conf`). Ask the operator
  to enable it; the path is correct.

`403 "WebDAV not enabled for this account"`
: The site is on, but your account lacks WebDAV. Ask the operator to enable
  WebDAV on your Users-page card.

`403 "HTTPS required"`
: WebDAV refuses Basic auth over plaintext - use `https://`.

`401`
: Normal when unauthenticated - retry with your token as HTTP Basic auth
  (username = your partner id, password = the `lzs_` token).

## Document your intent: `.brief` sidecars

Every file you author should carry a sidecar **`<file>.brief`** beside it -
`index.md.brief` next to `index.md`, `main.css.brief` next to a theme's
`main.css`. The brief records *why* the file exists and *what* each edit
changed, so the next agent (or the operator) understands intent before
touching it.

A brief is a real spec, not a thin note - the richer it is, the better the
owner can steer the page by editing it. Write it in markdown and cover:

- **Purpose** - the page's goal and who it is for.
- **Sections, in order** - what is on the page and why each part is there.
- **Tone & style** - voice and language conventions (e.g. British English, no
  em-dashes, warm but honest).
- **Images & sources** - which images are used, and which source document the
  content came from.
- **Constraints** - anything that must hold: "genuine quotes only, never
  invent", photo-permission rules, a required credit, or a dependency (e.g.
  "the enquiry form needs `forms/enquire.conf`").
- **To change this page…** - a closing line with concrete examples of edits an
  owner might ask for, so they know what they can change.
- **## Log** - append-only `date · action · who · what`, one line per edit.

Maintain it as you work: `PUT` the brief when you create the file; on every
later edit `GET` it, append a log line, and `PUT` it back (append - never
rewrite the history).

```text
# Brief - index.md

## Purpose
The landing page: convince a visitor to enquire within one screen.

## Sections
1. Hero - the doorway photo + a one-line promise.
2. Highlights strip - three short proof points.
3. Contact CTA - links to /enquire.

## Tone & style
Warm rustic-luxury; British English; no em-dashes; honest, never overstated.

## Images & sources
hero: doorway.jpg. Copy drawn from the owner's "Welcome" document.

## To change this page
e.g. "swap the hero to the garden photo", "drop the highlights strip",
"make the CTA say Book a viewing".

## Log
- 2026-06-23 · created · <you> · initial landing page
- 2026-06-24 · edit · <you> · reworded hero, added contact CTA
```

**The brief is a two-way spec, not just a record** - it is how you and the
owner collaborate on a page without hand-editing its markup:

- **Backfill what already exists.** For every page on the site, write a brief
  capturing your best understanding of its purpose and structure. A page with
  no brief is undocumented - give it one, based on what the page currently is.
- **The owner drives changes through the brief.** When they want a change, they
  edit the `.brief` in plain language. On your next pass, read the brief, diff
  it against the page, and **refactor the page to match the brief**, then
  append a log line. The brief is the source of intent; the `.md` is its
  current rendering - so the editable thing is the brief, and the page follows.

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

### Wiring a form

A `::: form` block named e.g. `enquire` needs a dispatch config to receive
submissions. With `manage_config` you deploy this yourself - no operator step
for file storage:

1. `PUT` `/dav/lazysite/forms/<name>.conf` (matching the form's name), listing
   the handlers it dispatches to:

   ```yaml
   targets:
     - handler: local-storage
   ```

2. `local-storage` ships by default and writes submissions to
   `lazysite/forms/submissions/` - nothing else to set up. **Email delivery
   needs the operator:** the SMTP credentials (`smtp.conf`) and the email
   handler in `handlers.conf` are secrets you cannot write - ask the operator
   to configure them, then reference that handler id here.
3. Submit a test entry and confirm it lands.

You may write only the per-form `<name>.conf`; `smtp.conf`, `handlers.conf`,
and the `submissions/` store are denied (secrets and data).

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
