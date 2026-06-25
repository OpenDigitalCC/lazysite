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

22 tools. **Reads** are not audited; **writes** are recorded in the audit log as
material events and may trigger the AI client's per-call approval. All file tools
need `manage_content` unless noted.

### Identity

whoami
: Partner identity, capabilities, active layout/theme, the full `tools` manifest,
  and the `auth` block (method + expiry). No capability required. Call it first.

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

get_permissions `{ path }`
: The ACL for a path (owner + read/write grants) - call before `set_permissions`.

list_form_handlers
: The configured form delivery handlers (id, type, name). No destinations or
  credentials are returned.

### Writing and editing (writes - audited)

write_file `{ path, content }`
: Create or overwrite a text file. Returns `created` (1 new / 0 overwrite). Audited
  as `create` or `edit`.

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

### Site operations

activate_theme `{ theme }`
: Activate a theme for the current layout (clears the HTML cache).
  Needs `manage_themes`.

activate_layout `{ layout, theme }`
: Activate a layout, optionally naming a compatible theme. Needs `manage_layouts`.

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
