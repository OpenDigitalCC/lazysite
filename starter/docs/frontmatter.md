---
title: Front matter
subtitle: The YAML metadata block at the top of every page.
register:
  - sitemap.xml
  - llms.txt
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

## Dynamic & data keys

`tt_page_var`
: Page-scoped Template Toolkit variables, available in the body and layout. Each value may be a literal or use a source prefix: `url:` (fetch a remote value), `scan:` (a list of pages), `json:` (decode a local JSON file into a data structure you can loop over), or `${ENV}`. Page variables override site variables of the same name.

`ttl`
: Cache lifetime in seconds - the page regenerates after this interval rather than only on edit. Useful for pages that pull remote data. Example: `ttl: 300`

`query_params`
: Accepted URL query-parameter names, exposed as `[% query.name %]`. Requests with matching parameters bypass the cache. See [API and raw mode](/docs/api).

`raw`
: `raw: true` outputs the converted body with no layout wrapper (TT still resolves) - good for fragments and partials.

`api`
: `api: true` serves the body as data, with no Markdown pipeline and no layout. Default content type is `application/json`. Combine with `tt_page_var` and `query_params` for dynamic JSON.

`content_type`
: A custom `Content-type` header, used with `raw:` or `api:`. Example: `content_type: text/html; charset=utf-8`.

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
