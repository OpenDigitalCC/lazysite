---
title: AI connector - tools reference
auth: manager
search: false
---

The full reference for the lazysite MCP connector: how it authenticates, the
capability model, and every tool it exposes. For *setting up* a connector (adding
it in Claude.ai / ChatGPT / Claude Code) see [Connect an AI assistant](/docs/ai-connector-setup).

::: widebox
The connector is **supervised, not autonomous**: an AI drafts and edits through
these tools, but it is bound by the partner's capabilities and per-file ACLs, the
deny-list (it can never read or write delivery secrets), and - for write actions -
the AI client's own per-call approval. Reads are not audited; writes are recorded
as material events.
:::

## Endpoint and protocol

The connector is a single MCP endpoint, Streamable HTTP / JSON-RPC:

    https://YOUR-SITE/cgi-bin/lazysite-mcp.pl

`initialize` and `tools/list` are open (discovery); a `tools/call` requires
authentication. An unauthenticated tool call returns HTTP 401 with a
`WWW-Authenticate` challenge so an OAuth client starts the sign-in flow.

## Authentication

Two credential shapes, same capability + ACL enforcement:

OAuth (Claude.ai, ChatGPT web)
: The client registers itself, the operator's one-time **connect code** is entered
  at the consent screen, and an opaque access token is issued (expires hourly,
  refreshed transparently).

Static bearer (Claude Code, Desktop, scripts)
: `Authorization: Bearer <partner-id>:<lzs_ token>` - the token comes from
  *Generate credential* on the Users page.

`whoami` returns an `auth` block - `{ method: "oauth"|"bearer", expires_at }` - so
the agent can see how the session is authenticated and when it lapses.

## Capabilities

A partner's grant (visible in `whoami.capabilities`) gates the tools:

- `manage_content` - read/write content pages and use the file tools (most tools).
  Defaults to the `webdav` grant; set off for a theme-only partner.
- `manage_themes` - activate themes.
- `manage_layouts` - activate layouts.
- `webdav` - the WebDAV transport / file-API mechanism flag.
- `manage_config` - site configuration (control API, not exposed as MCP tools).
- `analytics` - read the visitor-log analysis. Off by default; an explicit grant,
  since it exposes (aggregated, IP-anonymised, path-free) log data. Visitor analysis
  is available both as the MCP `analyse_visitors` tool AND as the control-API
  `analyse_visitors` action (`?action=analyse_visitors&window=N`), so an API-channel
  client gets it too.
- `audit` - read the audit trail (the in-page Audit view plus the control-API
  `audit` action). A separate capability from `analytics`; off by default.

Per-file ACLs (owner + read/write lists, with `@groups`) bind a token client
exactly as over WebDAV - a tool call is refused if the partner lacks access to the
target, regardless of capability.

## What is walled off

The connector deliberately cannot reach operator-only surfaces. Attempts return a
machine-readable `kind`:

- `lazysite/forms/*.conf` and other config - `blocked-config` (delivery settings +
  SMTP credentials are operator-only; use `bind_form` to reference a handler, never
  to set one).
- `lazysite/auth/*`, `.pl` scripts, the manager - `blocked`.
- User administration, secrets, credential minting - not exposed at all.

## Tools

37 tools. **Reads** are not audited; **writes** are recorded in the audit log as
material events and may trigger the AI client's per-call approval. All file tools
need `manage_content` unless noted.

### Identity

whoami
: Partner identity, capabilities, active layout/theme, the full `tools` manifest,
  and the `auth` block (method + expiry). No capability required. Call it first.

describe_capabilities
: The full capability map: every capability and what it unlocks (MCP tools,
  control-API actions, WebDAV paths), task recipes for common jobs, the
  engine-owned paths you must not write, and - under `holds` - what THIS account
  currently has. No capability required. The task recipes are the sanctioned
  sequences: follow them (e.g. `switch-layout`, `restore-from-history`) rather
  than improvising an order.

### Reading and inspecting (reads - not audited)

list_files `{ path }`
: Files and folders under a directory (default `/`) with size, mtime, ext,
  has_brief, generated, is_brief.

read_file `{ path }`
: A text file's contents. Refuses binary (`kind: binary`) and files over 512 KB
  (`kind: too-large`).

read_page `{ path }`
: A page as structured data - parsed front matter, Markdown body, has_brief,
  public_url.

list_pages
: Every page with title, registries (sitemap/llms/feed) and public URL.

page_status `{ path }`
: Whether the source exists + last-modified, whether the render is pending (cache
  dropped after an edit, re-renders next visit), and the public URL. Confirm an
  edit will reach visitors without a web fetch.

search_files `{ query, path }`
: Case-insensitive content grep across text files, returning path + line snippets.
  Excludes the lazysite/ infra; file- and match-capped.

preview_page `{ path }`
: Render a page server-side, fresh (no cache), and return its HTML + status -
  in-channel verification of layout / nav / form output. Public view; a protected
  page shows the auth gate.

validate_page `{ path | content }`
: Pre-publish checks: unterminated front matter, missing title, invalid form-field
  rules, and a **public-data warning** (Wi-Fi passwords, postcodes/addresses, phone
  numbers).

audit_site
: Whole-site audit: broken internal links, orphan pages, missing titles, stale
  generated HTML, duplicate content blocks.

analyse_visitors `{ window }`
: Sanitised visitor-log analysis for trend reporting (needs the `analytics`
  capability). Returns per-day totals, a people/AI-assistant/bot/noise breakdown,
  top pages, referrers, status codes, and a capped recent event stream over the
  last `window` days (1-365, default 30). Never the raw log, any filesystem path,
  or a visitor IP. Read `/docs/ai-briefing-stats` for how to interpret it and what
  may/may not be reported.

get_permissions `{ path }`
: The ACL for a path (owner + read/write grants) - call before `set_permissions`.

list_form_handlers
: The configured form delivery handlers (id, type, name). No destinations or
  credentials are returned.

read_nav
: The site navigation as a structured list (items + children) plus the raw
  nav.conf. Read before set_nav.

list_themes
: The themes installed across all layouts, with which is active. Needs
  `manage_themes`.

list_layout_catalogue
: The layouts available in the configured layouts repo (name, version, default
  theme, themes), annotated with what is already installed - discover what
  `install_layout` can pull without downloading anything. Needs `manage_layouts`.

### Version history (needs the site's Content history plugin)

When the operator has enabled the **Content history** plugin, every save
(manager, WebDAV, or this connector) is recorded as a version, and these tools
let you inspect and undo content changes. If `list_versions` returns
`enabled: false`, versions are not being recorded - ask the operator to enable
the plugin; do not try to build your own history. All three need
`manage_content`.

list_versions `{ path, limit }`
: A file's recorded versions, newest first: version id, author, date, message.
  Not audited (a read).

view_version `{ path, version }`
: One version's full content plus a unified diff against the current file.
  Not audited (a read).

restore_version `{ path, version }`
: Restore the file to that version. The historic content is written back
  through the normal save path (page cache refreshed) and the restore itself
  becomes the newest recorded version - nothing is lost by restoring. Audited.

Remote sync of the history (push/pull to a git host) is **operator-only** by
design - it is configured and driven from the manager UI (Remote sync plugin)
and is not exposed over the connector or the control API.

### Writing and editing (writes - audited)

write_file `{ path, content }`
: Create or overwrite a text file. Returns `created` (1 new / 0 overwrite) and runs
  `validate_page` on the content, returning any `warnings`/`issues`. Audited as
  `create` or `edit`.

create_page `{ slug, title, subtitle, body, register }`
: Create a new page from front-matter fields + body; errors if it already exists.

delete_page `{ slug }`
: Delete a page and its `.brief`, and report `still_referenced_in` (nav, other
  pages) for cleanup; generated indexes refresh automatically.

rename_page `{ old, new, update_links }`
: Rename / move a page (carries `.brief` + ACL); with `update_links`, rewrites
  internal links to the old path across pages (nav.conf is not rewritten).

replace_text `{ path, old, new }`
: Replace exact text without rewriting the whole file - safer for a small change.
  Errors if `old` is absent (no silent clobber); reports the replacement count.

copy_file `{ from, to }`
: Copy a text file to a new path (templating). Destination starts with a fresh ACL.

move_file `{ from, to }`
: Rename / move a file; carries its `.brief` and re-keys its ACL.

delete_file `{ path }`
: Delete a file. Audited as `delete`.

set_permissions `{ path, read, write }`
: Set the per-file ACL - owner plus comma-separated read/write lists (users or
  `@groups`).

bind_form `{ form, handler }`
: Wire a form to delivery by referencing an existing handler from
  `list_form_handlers`. The connector never sets a destination or credential.

set_nav `{ items }`
: Replace the site navigation - `items` is an ordered list of `{ label, url }`
  (a `children` list becomes a sub-menu; an item with no url is a section header).
  Writes nav.conf and rebuilds the cache.

### Site operations

activate_theme `{ theme }`
: Activate a theme for the current layout (clears the HTML cache).
  Needs `manage_themes`.

activate_layout `{ layout, theme }`
: Activate a layout, optionally naming a compatible theme. Needs `manage_layouts`.

install_layout `{ layout, theme, all, update, activate }`
: Install a layout and its theme(s) from the configured repo and activate it
  (default). Needs `manage_layouts`. **To switch the site to a different
  layout, this one call is the whole switch** - it installs AND activates.
  Only delete the old layout afterwards, if at all. Use
  `list_layout_catalogue` first to see names.

delete_layout `{ layout }`
: Delete an installed layout and its themes. **The ACTIVE layout is always
  refused** - when switching, install/activate the replacement first, then
  delete the old one. Never delete first: the right order is
  `list_layout_catalogue` -> `install_layout` -> (optionally) `delete_layout`.
  A recovery snapshot is kept. Needs `manage_layouts`.

submit_feedback `{ summary, good, bad, rating, context }`
: Report what worked and what got in the way while building through the
  connector - this is how the operators improve the tools. Use it freely; your
  identity and context are recorded automatically. No capability required.

invalidate_cache `{ path }`
: Drop a page's cached HTML so it re-renders (`"*"` for all). A normal write
  already clears its own page; use this for pages that embed another.

## Error model

A failed tool result is `{ ok: 0, error, kind }`. The `kind` lets an agent tell
causes apart: `blocked`, `blocked-config`, `not-found`, `permission`, `binary`,
`too-large`, `invalid-path`. A 401 carries `error.data.reason` -
`sign-in-incomplete` (no credential reached the server - re-authorise the
connector) vs `credential-invalid` (expired/revoked - reconnect).

## A reliable edit loop

1. `whoami` - confirm identity, capabilities, and that tools are loaded.
2. `list_files` / `list_pages` / `read_page` - orient; read before you edit.
3. `validate_page` (with `content`) - catch front-matter / form / public-data
   issues before writing.
4. `write_file` or `replace_text` - make one change at a time.
5. `preview_page` - confirm the render in-channel (not a web fetch). `page_status`
   confirms it will reach visitors.
6. `audit_site` after a set of changes - catch broken links / orphans / duplicates.

Pages are Markdown files served at their path (`about.md` → `/about`); a page that
registers in a feed lists it in front matter (`register: [sitemap, llms]`).
