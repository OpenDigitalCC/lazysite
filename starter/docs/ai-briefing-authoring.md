---
title: AI briefing - content authoring
subtitle: Guide for AI assistants helping users write content on a lazysite site.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This document briefs an AI assistant helping a user author content on
a lazysite site. It covers the page format, front matter, Markdown
extensions, and URL conventions. For view/theme authoring, see
[AI briefing - views](/docs/ai-briefing-views). For configuration, see
[AI briefing - configuration](/docs/ai-briefing-configuration).

## Page format

Every page is a plain text file ending in `.md`. Pages begin with a
YAML front matter block delimited by `---`, followed by the page body
in Markdown:

```markdown
---
title: Page Title
subtitle: Optional subtitle shown below title
register:
  - llms.txt
  - sitemap.xml
---

Page content in Markdown.
```

The content body is converted to HTML and inserted into the site's
view template at `[% content %]`. The view wraps it with navigation,
header, and footer.

## Front matter keys

`title`
: Page title. Required for most pages. Used in the `<title>` tag and
  the page `<h1>`.

`subtitle`
: Short description shown below the title. Optional.

`ttl`
: Cache TTL in seconds. The page regenerates after this interval rather
  than on `.md` file edit. Example: `ttl: 300`.

`register`
: List of registry files the page appears in. Values match template
  filenames in `lazysite/templates/registries/` without the `.tt`
  extension. Common values: `llms.txt`, `sitemap.xml`, `feed.rss`,
  `feed.atom`.

`date`
: Publication date in `YYYY-MM-DD` format. Used in feed entries.
  Falls back to file mtime if not set.

`tt_page_var`
: Page-scoped Template Toolkit variables. Supports `url:`, `scan:`, and
  `${ENV}` prefixes. Page variables override site variables.

```yaml
tt_page_var:
  hero_image: /img/landing.jpg
  latest_release: url:https://raw.githubusercontent.com/example/repo/main/VERSION
  blog_posts: scan:/blog/*.md sort=date desc
```

`raw`
: `raw: true` outputs the converted body without the view wrapper.
  Useful for fragments, AJAX partials, or API-style endpoints.

`api`
: `api: true` serves the page as a JSON API endpoint. Default content
  type is `application/json; charset=utf-8`. Combine with
  `tt_page_var` and `query_params` for dynamic JSON.

`content_type`
: Overrides the HTTP Content-type header. Example:
  `content_type: text/html; charset=utf-8`.

`layout`
: Per-page view override. Names a theme under `lazysite/themes/`.

`auth`
: Authentication requirement. `required`, `optional`, or `none`
  (default).

`auth_groups`
: List of group names. User must be in one of them.

`payment`
: Payment requirement for the x402 payment flow. See
  [Payment](/docs/payment).

`query_params`
: List of accepted URL query parameter names. Matched parameters are
  available as `[% query.NAME %]` and bypass the cache.

`tags`
: Tags for page scan results. YAML list, comma-separated, or single
  value.

`search`
: `true` or `false`. Controls whether the page appears in search.
  Defaults to the site's `search_default` setting.

`form`
: Enables form processing for the page and names the form. Requires a
  matching `lazysite/forms/NAME.conf`.

## Markdown elements

### Headings

`# H1` is reserved - the page title is rendered by the view template.
Start content headings at `##`.

### Text, links, lists

Standard Markdown. Internal links should be extensionless:
`[Docs](/docs/authoring)` not `[Docs](/docs/authoring.html)`.

### Tables

Standard GFM pipe tables are supported.

### Code blocks

Fenced code blocks with language identifiers produce highlighted output:

    ```bash
    curl https://example.com/
    ```

Inline code and fenced code blocks are protected from Template Toolkit
processing - `[% tags %]` inside code appear literally.

## Fenced divs

Wrap content in a named CSS class:

    ::: classname
    Content here. Standard Markdown works inside.
    :::

Produces `<div class="classname">...</div>`. Class names must contain
only word characters and hyphens.

Common classes in the default theme:

- `widebox` - full-width coloured band
- `textbox` - 60% width highlighted box
- `marginbox` - pull quote in the margin
- `examplebox` - evidence or example highlight

### oEmbed

    ::: oembed
    https://www.youtube.com/watch?v=abc123
    :::

Works with YouTube, Vimeo, SoundCloud, and any oEmbed provider.

### Content includes

Inline local or remote content at render time:

    ::: include
    partials/note.md
    :::

    ::: include
    https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md
    :::

`.md` files have their front matter stripped. Code files are wrapped in
syntax-highlighted code blocks. `.html` files are inserted bare.

Includes are single-pass - includes inside included files are not
processed.

## Template Toolkit in page content

TT variables are expanded in the page content before Markdown
conversion. Site variables come from `lazysite.conf`, page variables
from `tt_page_var`. Automatic variables (`page_title`, `page_subtitle`,
`content`) are set by the processor.

```markdown
Current version: [% latest_release %]

[% IF beta %]
::: textbox
This feature is in beta.
:::
[% END %]
```

Inline code and fenced code blocks are protected from TT. Put TT tags
outside code blocks if you want them to render.

Markdown link URLs do not reliably resolve TT variables (the Markdown
parser processes links before TT runs). Use HTML `<a>` tags when the
href contains a TT variable:

```html
<a href="[% download_base %]/release-[% version %].tar.gz">Download</a>
```

## URL structure

Page URLs derive from file paths, always without extension:

```
DOCROOT/index.md          ->  /
DOCROOT/about.md          ->  /about
DOCROOT/docs/install.md   ->  /docs/install
DOCROOT/docs/index.md     ->  /docs/
```

Always use extensionless URLs for internal links.

## Remote pages

A `.url` file contains a single URL. The processor fetches the Markdown
from that URL, processes it through the full pipeline, and caches the
result.

    # File: docs/install.url
    https://raw.githubusercontent.com/example/repo/main/docs/INSTALL.md

The remote file should include YAML front matter. Cache TTL defaults to
one hour.

## Page scan

`scan:/path/*.md` returns an array of page metadata. Use in
`lazysite.conf` or `tt_page_var`:

```yaml
tt_page_var:
  blog_posts: scan:/blog/*.md sort=date desc
```

```markdown
[% FOREACH post IN blog_posts %]
## [% post.title %]
[% post.subtitle %] - [% post.date %]
[% post.url %]
[% END %]
```

Each item has `url`, `title`, `subtitle`, `date`, and `path`.

## Search

Pages are searchable by default. Set `search: false` in front matter to
exclude a page from search. The site default is controlled by
`search_default` in `lazysite.conf`.

## Registries

Pages declare which registry files they appear in via `register:`.
Common registries: `sitemap.xml`, `llms.txt`, `feed.rss`, `feed.atom`.

Each name maps to a Template Toolkit template in
`lazysite/templates/registries/`. Registries regenerate after their
TTL expires (default 4 hours).

## Tasks

### Creating a new page

1. Ask the user for: title, URL path, brief description.
2. Create a file at `DOCROOT/PATH.md` (e.g. `/docs/install` becomes
   `DOCROOT/docs/install.md`).
3. Write front matter with `title:` and optionally `subtitle:`.
4. Register in relevant feeds: `sitemap.xml`, `llms.txt`, and
   `feed.rss` or `feed.atom` if it is a dated article.
5. Write the body in Markdown, starting headings at `##`.

### Creating a blog/news index with scan

1. Confirm blog posts live in a single directory, e.g. `/blog/`.
2. Create `DOCROOT/blog/index.md` with `tt_page_var`:

```yaml
---
title: Blog
tt_page_var:
  posts: scan:/blog/*.md sort=date desc
---

[% FOREACH p IN posts %]
## [[% p.title %]]([% p.url %])
[% p.subtitle %] - [% p.date %]
[% END %]
```

### Creating a members-only page

1. Confirm the required group name in `lazysite/auth/groups`.
2. Write the page normally, then set:

```yaml
---
title: Members area
auth: required
auth_groups:
  - members
---
```

Protected pages are never cached.
