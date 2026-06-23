---
title: AI briefing - publishing
subtitle: Guide for an automated partner publishing content to a lazysite site over WebDAV.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an automated publishing partner - an AI agent that writes
content to a lazysite site. It covers the grant model, authentication,
the WebDAV endpoint, what may and may not be written, and the offline
bundle path for environments with no network egress.

For the page format and front matter, see
[AI briefing - authoring](/docs/ai-briefing-authoring). For site
configuration, see
[AI briefing - configuration](/docs/ai-briefing-configuration). For
themes and layouts, see [AI briefing - layouts](/docs/ai-briefing-layouts).

This page is the write/discovery counterpart to `/llms.txt` (the
read/discovery index).

## The grant model

Three things are kept separate, and you must respect the separation:

- the **bootstrap** (your onboarding brief) *describes* the grant;
- the **token** *is* the grant;
- the **server** *enforces* the grant.

Never rely on prose to limit yourself. The scope and capabilities in
your brief are documentation of what the server will allow; the server
resolves the real limits from your token and rejects anything outside
them. If a write you believe is in scope returns `403`, the grant - not
the documentation - is authoritative.

Your brief does exactly four jobs: identify which partner you are and
which site you are bound to, tell you how to authorise, locate the
endpoints, and point you at the documentation (these briefings and
`/llms.txt`). Everything substantive is fetched from the site, not
carried in the brief.

## Authentication

Two credentials, in sequence:

`lzp_` pairing key
: The bootstrap credential in your brief. Single-use and short-lived.
  Its only power is to be exchanged for an access token (like an OAuth
  authorisation code). Sensitive before exchange; near-worthless after.

`lzs_` access token
: The working credential. Presented as HTTP Basic auth on every request,
  carries an expiry, and is rotatable.

Present the token as Basic auth with **username = your partner id** and
**password = the `lzs_` token** - not the token as the username. This gives
per-partner attribution in the server logs and lets the operator scope and
revoke you individually.

Your partner id is the **exact id from your onboarding brief** (the `# Automated
partner: <id>` heading, and the bootstrap `partner:` field). It is often **not**
a bare name like `claude` - e.g. `claude-dhcf`. Use that exact string; the wrong
username returns `401` even with a valid token.

There is exactly **one live credential per account**: minting or rotating
a token replaces the previous one. A new session that obtains a fresh
token invalidates the old.

### Check your access first

Before publishing, confirm the token is live with a cheap, side-effect-free
probe - a `PROPFIND` of the WebDAV root:

```
PROPFIND /dav/   Depth: 0   Authorization: Basic base64(<partner-id>:<lzs_ token>)
-> 207 means authenticated; 401 means the username or token is wrong.
```

### Exchange and rotation

Exchange your single-use pairing key for an access token by POSTing it to
the token endpoint:

```
POST /cgi-bin/lazysite-auth.pl?action=exchange
body: username=<you>&pairing_key=<lzp_...>
-> { "ok": true, "token": "lzs_...", "expires_at": <epoch> }
```

Rotate before expiry by presenting your CURRENT token as HTTP Basic auth
(no body needed):

```
POST /cgi-bin/lazysite-auth.pl?action=rotate
Authorization: Basic base64(<you>:<lzs_ current token>)
-> { "ok": true, "token": "lzs_...", "expires_at": <epoch> }
```

Each exchange or rotation invalidates the previous token (one live
credential per account). An expired token returns `401`: recover by
rotating while you still hold a valid token, otherwise ask the operator
to re-pair. `expires_at` lets you rotate deterministically rather than
guessing from `401`s. Both endpoints are HTTPS-only and rate-limited.

## Endpoints

```
/dav/                                         WebDAV - content, assets, layout/theme files, nav.conf
/cgi-bin/lazysite-auth.pl?action=exchange     pairing key -> access token (live)
/cgi-bin/lazysite-auth.pl?action=rotate       rotate the access token (live)
/control/                                     config, activation, cache (control-API release)
```

## What you may write, and what you may not

WebDAV is for **content, assets, and layout/theme files**. It maps 1:1
to the docroot: `/dav/about.md` is the file behind the `/about` page.

The site navigation, **`lazysite/nav.conf`**, is also editable when your
account holds `manage_config` - it is benign structure (label `|` URL lines,
indented for sub-items), no more powerful than the content you can already
publish, so update it when you add or remove pages.

A `nav.conf` change is **config-class**: it does NOT retro-invalidate pages
already in the HTML cache. Pages you re-render after the edit show the new nav;
older cached pages keep the old nav until each is re-PUT (a content PUT bumps
the mtime and self-invalidates that page). To roll a nav change across the
site, **re-PUT the affected pages** - this stays inside the content scope and
needs no operator cache clear.

**Themes and layouts have their own capabilities, and the live ones are
read-only.** Theme files (`lazysite/layouts/<layout>/themes/<theme>/…`) need
**`manage_themes`**; the layout structure and its shared wrapper
(`layout.tt`) need **`manage_layouts`** - a *separate* capability, so a grant
with `manage_themes` alone gets `403` on `layout.tt`. And the **active**
layout and theme are **read-only over WebDAV** by design: you cannot PUT the
live `layout.tt`. To re-skin globally, edit an **inactive** layout/theme and
**activate** it through the control API - that gives a safe back-out and never
serves a half-edited site. (A per-page `raw: true` page that embeds its own
chrome is an escape hatch, not the intended path.)

The following paths are **write-denied by the server**, whatever your
scope says. Do not attempt to write them; treat a denial as correct:

`lazysite/auth/`
: the credential store - writing here is privilege escalation.

`lazysite/forms/.smtp-password` (and form secrets)
: the SMTP secret.

`lazysite.conf`
: carries privilege-escalation keys (`plugins`, `auth_default`,
  `manager_groups`). Config is set through the control API with a key
  allowlist, never by overwriting this file.

`lazysite/manager/`, `lazysite/cache/`, `lazysite/logs/`
: manager UI, generated cache, and logs.

Config-key changes and theme/layout **activation** (and the HTML-cache
clear they require) are **control-API actions**, not file writes. They
arrive with the control-API release; until then the operator performs
them through the manager UI. You may write layout/theme *files* over
WebDAV within the `lazysite/layouts/` scope, but you cannot *activate* a
theme or clear the cache from WebDAV alone.

## Publishing content over WebDAV

### A single page edit

1. `PROPFIND` the target to check existence and the current etag.
2. `PUT` the modified `.md` to its docroot-mapped path
   (`/dav/about.md` for the `/about` page).

Content pages regenerate when the `.md` mtime changes, and a `PUT`
updates the mtime, so **a content edit self-invalidates its HTML cache** -
no separate cache-bust is needed.

### A whole-site publish

1. Walk the local tree.
2. `MKCOL` each parent collection first - WebDAV does **not** create
   intermediate collections for you.
3. `PUT` each file. Ideally `PROPFIND`-diff first and skip unchanged
   files; a naive put-everything is acceptable for an initial deploy.

The asymmetry to design around: content edits self-invalidate, but
theme, layout, and config changes need an **explicit cache clear**, which
is a control-API action (above).

### Verify your publish

Don't assume a `2xx` means the page is right. After publishing, confirm:

- **Fetch the page** (`GET` its public URL) and expect `200`.
- **No leaked Template Toolkit** - the body must not contain a literal
  `[%` … `%]` (that means a variable or directive did not resolve).
- **The nav bar reflects your `nav.conf`** on every affected page (re-PUT any
  that still show the old nav - see the config-class caveat above).
- For a **form** page, the form's action URL must be reachable: `GET` it and
  expect anything other than `404`. The receiver is a server-side CGI
  (`/cgi-bin/form-handler.pl`) the operator must have installed and made
  executable; it is outside your WebDAV scope, so if it `404`s, report it to
  the operator rather than trying to fix it.

## The offline bundle

For an environment with no egress, no token, or a locked-down runner:
assemble the exact file set you would have `PUT`, but serialise it
instead of pushing it.

- The archive is **docroot-relative**, so the operator applies it with
  `tar xf bundle.tgz -C DOCROOT` - every file lands in its correct place
  with no path rewriting.
- It contains **only in-scope files** - never `auth/`, never `cache/`.
- It ships a **manifest** listing every file, its target path, the
  intended operation (create vs overwrite), and any required post-extract
  action - notably "clear HTML cache" if a theme or config file changed.
  Optionally a checksum file.
- The apply step stays with the operator: a manifest they audit before
  committing, not a script that auto-runs.

Build it from the same source of truth as a live publish: one function
assembles the in-scope file set, one transports it over WebDAV, one
writes it to a bundle plus manifest. Same file set, two transports.

## The machine-readable bootstrap

Two parseable sources exist - parse identity, scope, and endpoints from
these, never from prose:

- **Your onboarding brief** carries a per-partner YAML block (under a
  `## Machine-readable` heading) with your `partner:` id, `pairing_key:`,
  capabilities, and scope.
- **`[% site_url %]/.well-known/ai-partner`** is a partner-agnostic JSON
  document (endpoints, auth scheme, capabilities, deny list, docs) a cold
  agent can fetch from the site URL alone, before it has any credential.

The shape (YAML form shown; the well-known serves the same data as JSON):

```yaml
partner: claude
site: https://example.org
endpoints:
  webdav: /dav/
  control: /control/          # with the control-API release
auth:
  pairing_key: lzp_...        # single-use, short-lived
  token_prefix: lzs_
  scheme: basic               # username = partner id, password = token
capabilities:
  - publish-content
  - manage-layouts
  - manage-themes             # activation via control API
  - set-config-allowlisted    # via control API
scope:
  allow: ["/"]
  deny: ["/lazysite/auth", "/lazysite/cache", "/lazysite/logs",
         "/lazysite/forms/.smtp-password", "/lazysite/manager",
         "/lazysite.conf"]
docs:
  - /docs/ai-briefing-authoring
  - /docs/ai-briefing-configuration
  - /docs/ai-briefing-layouts
  - /docs/ai-briefing-publishing
  - /llms.txt
```

## Tasks

### Edit a single page

1. Confirm the page's URL and its docroot path (`/about` is
   `DOCROOT/about.md`, so `/dav/about.md`).
2. `PROPFIND` it to read the current content and etag.
3. Edit the Markdown per [AI briefing - authoring](/docs/ai-briefing-authoring).
4. `PUT` it back to the same `/dav/` path. The page regenerates on next
   request.

### Publish a whole site

1. Assemble the in-scope file set locally (exclude anything under the
   deny list).
2. `MKCOL` parent collections, deepest paths last.
3. `PROPFIND`-diff and `PUT` only changed files.
4. If you changed a theme, layout, or config, request a cache clear
   through the control API (or ask the operator to clear it) - a content
   `PUT` alone will not refresh those.

### Build an offline bundle

1. Assemble the same in-scope file set.
2. Write a docroot-relative archive plus a manifest (path, operation,
   post-extract action per file).
3. Hand both to the operator. They audit the manifest, then
   `tar xf bundle.tgz -C DOCROOT` and run any post-extract actions.
