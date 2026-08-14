---
title: Front matter
subtitle: The YAML metadata block at the top of every page.
register:
  - sitemap.xml
---

Every page can begin with a **front matter** block - a small piece of YAML between two `---` lines that sets the page's metadata. It is optional, but a `title` is recommended for most pages.

```markdown
---
title: My Page
subtitle: A short description shown under the title
register:
  - sitemap.xml
---

Your content, in Markdown, starts here.
```

Everything below the closing `---` is the page body. All keys are optional unless noted.

## Common keys

`title`
: Page title - used in the `<title>` tag and the page header. Recommended for most pages.

`subtitle`
: Short description shown below the title.

`date`
: Publication date as `YYYY-MM-DD`. Used in feed entries; falls back to the file's modification time if unset.

`tags`
: Tags for page-scan results. A YAML list, comma-separated, or a single value.

`layout`
: A named layout for this page, overriding the site-wide setting. Resolves to `lazysite/layouts/NAME/layout.tt`, or may be a remote URL (see [remote layouts](/docs/features/configuration/remote-layouts)).

`search`
: `true` or `false` to include or exclude the page from the search index. Defaults to the site-wide `search_default`.

`register`
: Registry files this page should appear in - matching template names under `lazysite/templates/registries/` without the `.tt`. Common values: `sitemap.xml`, `llms.txt`, `feed.rss`, `feed.atom`.

`aliases`
: Old or alternate URLs this page should also answer to, as **redirects**. A YAML list of site-local paths (each starting with `/`). A request for an alias returns a `301 Moved Permanently` to the page's real URL - so links to a renamed or moved page keep working. The redirect always targets this page (an alias cannot point elsewhere). Example:

    ---
    title: Pricing
    aliases:
      - /old-pricing
      - /plans
    ---

  A real page always wins over an alias, so an alias only takes effect when nothing else lives at that path. The alias list is kept up to date whenever the page is saved, renamed, moved or copied (manager or WebDAV) and cleared when it is deleted.

`aliases_temp`
: Like `aliases`, but the redirect is a `302 Found` (temporary) instead of a `301 Moved Permanently` - use it while a URL is only provisionally forwarding, so browsers and search engines do not cache the redirect. Same list syntax and same rules; a path listed under both keys is treated as temporary. Example:

    ---
    title: Summer Sale
    aliases_temp:
      - /offer
    ---

  The current alias map (with each entry's redirect type) is shown read-only on the manager Files page.

## Dynamic & data keys

`tt_page_var`
: Page-scoped Template Toolkit variables, available in the body and layout. Each value may be a literal or use a source prefix: `url:` (fetch a remote value), `scan:` (a list of pages), `json:` (decode a local JSON file into a data structure you can loop over), or `${ENV}`. Page variables override site variables of the same name.

`ttl`
: Cache lifetime in seconds - the page regenerates after this interval rather than only on edit. Useful for pages that pull remote data. Example: `ttl: 300`

`nocache`
: `nocache: true` renders the page fresh on every request - never served from or written to the cache. Use it for genuinely per-request content, such as showing the visitor their own IP with `[% client_ip %]`. See [Showing the visitor's IP](/docs/features/authoring/visitor-ip).

`query_params`
: Accepted URL query-parameter names, exposed as `[% query.name %]`. Requests with matching parameters bypass the cache. See [API and raw mode](/docs/api).

`raw`
: `raw: true` outputs the converted body with no layout wrapper (TT still resolves) - good for fragments and partials.

`api`
: `api: true` serves the body as data, with no Markdown pipeline and no layout. Default content type is `application/json`. Combine with `tt_page_var` and `query_params` for dynamic JSON.

`content_type`
: A custom `Content-type` header, used with `raw:` or `api:`, for a data artifact. Example: `content_type: text/csv; charset=utf-8`. Script-capable types (`text/html`, `application/xhtml+xml`, `image/svg+xml`) are not allowed on a raw/api page - they are downgraded to `text/plain` at serve time, because a verbatim, unescaped page served as HTML would be a cross-site-scripting vector. Publish HTML through a layout, or as a static file.

### Choosing between raw, api and a static file

These three are easy to confuse, and `raw:` is the one whose name misleads - it
does not mean "serve this file unchanged".

`raw: true`
: The Markdown pipeline still runs; only the layout wrapper is dropped. Use it
  for a fragment or partial that something else embeds.

`api: true`
: No Markdown pipeline and no layout. Use it for a data artifact - JSON, CSV,
  plain text. Not for HTML.

A static file
: A `.html` (or `.js`, or any asset) with **no `.md` source** is served
  byte-for-byte: no Markdown pipeline, no layout, no theme, no front matter
  involved at all. This is how you publish a self-contained HTML file, a
  single-file application, or a JavaScript library you want served from your own
  origin. `.html` and `.js` are writable over WebDAV, MCP and the manager, so no
  special permission is needed.

If you want an HTML file served exactly as you wrote it, the answer is the static
file - not `raw:`. A raw or api page declaring an HTML content type is refused
when you write it, and downgraded to `text/plain` if one already exists.

## Access keys

`auth`
: Authentication requirement: `required`, `optional`, or `none` (default). See [Authentication](/docs/auth).

`auth_groups`
: Group names; the user must be signed in and in at least one to view the page.

`payment`
: Payment requirement for the x402 flow. See [Payment](/docs/payment).

`form`
: Enables form processing and names the form (alphanumeric, hyphens, underscores). A matching `lazysite/forms/NAME.conf` must exist. See [Forms](/docs/forms).

## A note on YAML

lazysite reads a practical subset of YAML. Use block style for lists and maps (one item per line under the key); quote values that begin with a special character or contain a colon; and write `&`/`#`-leading or ambiguous values in quotes. Folded (`>`) and literal (`|`) block scalars are not supported - keep a long value on one line.

---

See [Authoring](/docs/authoring) to get started, [Advanced authoring](/docs/features) for the how-to by topic, or the full [Reference](/docs/reference) for configuration and template-variable keys.
